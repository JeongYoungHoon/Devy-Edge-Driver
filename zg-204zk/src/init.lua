local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local generic_body = require "st.zigbee.generic_body"
local log = require "log"

local TUYA_CLUSTER = 0xEF00
local DP_TYPE_BOOL  = 0x01
local DP_TYPE_VALUE = 0x02

------------------------------------------------------------------------
-- Tuya DP Write
------------------------------------------------------------------------

local function int_to_bytes(n, len)
  local t = {}
  for i = len, 1, -1 do
    t[i] = n % 256
    n = math.floor(n / 256)
  end
  return string.char(table.unpack(t))
end

local function send_tuya_dp(device, dp, data_type, value)
  local seq = ((device:get_field("tuya_seq") or 0) + 1) % 65536
  device:set_field("tuya_seq", seq)

  local payload_bytes
  if data_type == DP_TYPE_BOOL then
    payload_bytes = string.char(value and 1 or 0)
  elseif data_type == DP_TYPE_VALUE then
    payload_bytes = int_to_bytes(value, 4)
  end

  local body = int_to_bytes(seq, 2)
    .. string.char(dp, data_type)
    .. int_to_bytes(#payload_bytes, 2)
    .. payload_bytes

  local cluster_obj = {ID = TUYA_CLUSTER}
  local gb = generic_body.GenericBody(body)
  local cmd = setmetatable({ID = 0x00}, {__index = gb})
  device:send(cluster_base.build_cluster_specific_command(cluster_obj, device, cmd))
end

------------------------------------------------------------------------
-- Priority Matcher
------------------------------------------------------------------------

local function can_handle_hobeian(opts, driver, device, ...)
  return device:get_manufacturer() == "HOBEIAN" and device:get_model() == "ZG-204ZK"
end

------------------------------------------------------------------------
-- Handlers
------------------------------------------------------------------------

local function battery_perc_handler(driver, device, value, zb_rx)
  local percentage = math.min(100, math.floor(value.value / 2))
  log.info(string.format("[%s] Battery (ZCL): %d%%", device.label, percentage))
  device:emit_event(capabilities.battery.battery(percentage))
end

local function tuya_main_handler(driver, device, zb_rx)
  local payload = zb_rx.body.zcl_body.body_bytes
  if #payload < 7 then return end

  local dp  = payload:byte(3)
  local len = (payload:byte(5) * 256) + payload:byte(6)

  local value = 0
  if len == 1 then
    value = payload:byte(7)
  elseif len == 4 and #payload >= 10 then
    value = (payload:byte(7) * 16777216) + (payload:byte(8) * 65536)
          + (payload:byte(9) * 256) + payload:byte(10)
  end

  log.info(string.format("[%s] Tuya DP %d: %d", device.label, dp, value))

  if dp == 0x01 then
    if value == 1 then
      device:emit_event(capabilities.presenceSensor.presence.present())
      device:emit_event(capabilities.motionSensor.motion.active())
    else
      device:emit_event(capabilities.presenceSensor.presence.not_present())
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end
  elseif dp == 121 then
    -- Battery via Tuya DP (raw %)
    local pct = math.min(100, math.max(0, value))
    log.info(string.format("[%s] Battery (DP 121): %d%%", device.label, pct))
    device:emit_event(capabilities.battery.battery(pct))
  end
end

------------------------------------------------------------------------
-- Preferences
------------------------------------------------------------------------

local function apply_all_preferences(device)
  local p = device.preferences
  if not p then return end
  send_tuya_dp(device, 102, DP_TYPE_VALUE, p.fadingTime or 30)
  send_tuya_dp(device, 4,   DP_TYPE_VALUE, math.floor((p.detectionDistance or 3.0) * 100))
  send_tuya_dp(device, 2,   DP_TYPE_VALUE, p.staticSensitivity or 5)
  send_tuya_dp(device, 123, DP_TYPE_VALUE, p.motionSensitivity or 5)
  send_tuya_dp(device, 107, DP_TYPE_BOOL,  p.indicator ~= false)
  send_tuya_dp(device, 122, DP_TYPE_BOOL,  p.antiInterference == true)
end

local function apply_changed_preferences(device, old_prefs)
  local p = device.preferences
  if not p then return end

  if p.fadingTime ~= old_prefs.fadingTime then
    send_tuya_dp(device, 102, DP_TYPE_VALUE, p.fadingTime)
  end
  if p.detectionDistance ~= old_prefs.detectionDistance then
    send_tuya_dp(device, 4, DP_TYPE_VALUE, math.floor(p.detectionDistance * 100))
  end
  if p.staticSensitivity ~= old_prefs.staticSensitivity then
    send_tuya_dp(device, 2, DP_TYPE_VALUE, p.staticSensitivity)
  end
  if p.motionSensitivity ~= old_prefs.motionSensitivity then
    send_tuya_dp(device, 123, DP_TYPE_VALUE, p.motionSensitivity)
  end
  if p.indicator ~= old_prefs.indicator then
    send_tuya_dp(device, 107, DP_TYPE_BOOL, p.indicator ~= false)
  end
  if p.antiInterference ~= old_prefs.antiInterference then
    send_tuya_dp(device, 122, DP_TYPE_BOOL, p.antiInterference == true)
  end
end

------------------------------------------------------------------------
-- Driver Definition
------------------------------------------------------------------------

local hobeian_driver = ZigbeeDriver("hobeian-zg204zk-mmwave", {
  supported_capabilities = {
    capabilities.presenceSensor,
    capabilities.motionSensor,
    capabilities.battery,
    capabilities.refresh
  },
  health_check = false,
  lifecycle_handlers = {
    init = function(driver, device)
      log.info(string.format("[%s] Driver Loaded", device.label))
    end,
    added = function(driver, device)
      log.info(string.format("[%s] Device Added", device.label))
      device:emit_event(capabilities.presenceSensor.presence.not_present())
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end,
    doConfigure = function(driver, device)
      log.info(string.format("[%s] Configuring", device.label))
      device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
      -- Wait briefly for device to be ready before sending config
      device.thread:call_with_delay(2, function()
        apply_all_preferences(device)
      end)
    end,
    infoChanged = function(driver, device, event, args)
      log.info(string.format("[%s] Preferences changed", device.label))
      apply_changed_preferences(device, args.old_st_store.preferences)
    end
  },
  zigbee_handlers = {
    cluster = {
      [TUYA_CLUSTER] = {
        [0x01] = tuya_main_handler,
        [0x02] = tuya_main_handler
      }
    },
    attr = {
      [clusters.PowerConfiguration.ID] = {
        [clusters.PowerConfiguration.attributes.BatteryPercentageRemaining.ID] = battery_perc_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      refresh = function(driver, device)
        log.info(string.format("[%s] Manual Refresh", device.label))
        device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
      end
    }
  },
  can_handle = can_handle_hobeian
})

log.info("!!! HOBEIAN ZG-204ZK DRIVER READY !!!")
hobeian_driver:run()
