local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
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
  else
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
-- Preferences
------------------------------------------------------------------------

local function apply_all_preferences(device)
  local p = device.preferences
  if not p then return end
  send_tuya_dp(device, 102, DP_TYPE_VALUE, p.fadingTime or 30)
  send_tuya_dp(device, 4,   DP_TYPE_VALUE, math.floor((p.detectionDistance or 5.0) * 100))
  send_tuya_dp(device, 2,   DP_TYPE_VALUE, p.staticSensitivity or 8)
  send_tuya_dp(device, 123, DP_TYPE_VALUE, p.motionSensitivity or 8)
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
-- Priority Matcher
------------------------------------------------------------------------

local function can_handle(opts, driver, device, ...)
  return device:get_manufacturer() == "_TZE200_ka8l86iu" and device:get_model() == "TS0601"
end

------------------------------------------------------------------------
-- Handlers
------------------------------------------------------------------------

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

  log.info(string.format("[%s] Tuya DP %d = %d (len=%d)", device.label, dp, value, len))

  if dp == 0x01 then
    -- DP 1: motion/presence. 0=inactive, 1=active (most common Tuya convention)
    if value == 1 then
      device:emit_event(capabilities.motionSensor.motion.active())
      device:emit_event(capabilities.presenceSensor.presence.present())
    else
      device:emit_event(capabilities.motionSensor.motion.inactive())
      device:emit_event(capabilities.presenceSensor.presence.not_present())
    end
  elseif dp == 121 then
    -- DP 121: battery percentage (confirmed from logs)
    local pct = math.min(100, math.max(0, value))
    log.info(string.format("[%s] Battery (DP %d): %d%%", device.label, dp, pct))
    device:emit_event(capabilities.battery.battery(pct))
  end
end

------------------------------------------------------------------------
-- IASZone Enrollment
------------------------------------------------------------------------

local function ias_enroll(driver, device)
  local hub_eui = driver.environment_info and driver.environment_info.hub_zigbee_eui
  if not hub_eui then
    log.warn(string.format("[%s] hub_zigbee_eui nil - skipping IASZone enrollment", device.label))
    return
  end
  device:send(clusters.IASZone.attributes.IASCIEAddress:write(device, data_types.IeeeAddress(hub_eui)))
  log.info(string.format("[%s] IASZone CIE Address written", device.label))
end

-- Zone Enroll Request (0x01, device → hub): 허브가 CIE Address 쓴 후 기기가 보내는 등록 요청
local function zone_enroll_request_handler(driver, device, zb_rx)
  log.info(string.format("[%s] IASZone Enroll Request - sending response", device.label))
  -- Zone Enroll Response payload: Enroll Response Code(0x00=Success) | Zone ID(0x01)
  local enroll_rsp = string.char(0x00, 0x01)
  local cluster_obj = {ID = clusters.IASZone.ID}
  local gb = generic_body.GenericBody(enroll_rsp)
  local cmd = setmetatable({ID = 0x00}, {__index = gb})
  device:send(cluster_base.build_cluster_specific_command(cluster_obj, device, cmd))
end

-- IASZone Zone Status Change Notification (cluster command 0x00 — device → hub)
-- SDK parses this into structured zcl_body fields (not body_bytes)
local function ias_zone_notification_handler(driver, device, zb_rx)
  local zone_status = zb_rx.body.zcl_body.zone_status.value
  local alarm1 = zone_status & 0x01
  log.info(string.format("[%s] IASZone Notification: 0x%04X (alarm1=%d)", device.label, zone_status, alarm1))
  if alarm1 == 1 then
    device:emit_event(capabilities.motionSensor.motion.active())
    device:emit_event(capabilities.presenceSensor.presence.present())
  else
    device:emit_event(capabilities.motionSensor.motion.inactive())
    device:emit_event(capabilities.presenceSensor.presence.not_present())
  end
end

-- IASZone ZoneStatus attribute report (backup)
local function ias_zone_status_handler(driver, device, zone_status, zb_rx)
  local alarm1 = zone_status.value & 0x01
  log.info(string.format("[%s] IASZone AttrReport: 0x%04X (alarm1=%d)", device.label, zone_status.value, alarm1))
  if alarm1 == 1 then
    device:emit_event(capabilities.motionSensor.motion.active())
    device:emit_event(capabilities.presenceSensor.presence.present())
  else
    device:emit_event(capabilities.motionSensor.motion.inactive())
    device:emit_event(capabilities.presenceSensor.presence.not_present())
  end
end

------------------------------------------------------------------------
-- Driver Definition
------------------------------------------------------------------------

local contact_driver = ZigbeeDriver("tuya-tz-motion-sensor", {
  supported_capabilities = {
    capabilities.motionSensor,
    capabilities.presenceSensor,
    capabilities.battery,
    capabilities.refresh
  },
  health_check = false,
  lifecycle_handlers = {
    init = function(driver, device)
      log.info(string.format("[%s] Driver Loaded", device.label))
      driver:call_with_delay(2, function(d) ias_enroll(d, device) end)
    end,
    added = function(driver, device)
      log.info(string.format("[%s] Device Added", device.label))
      device:emit_event(capabilities.motionSensor.motion.inactive())
      device:emit_event(capabilities.presenceSensor.presence.not_present())
    end,
    doConfigure = function(driver, device)
      log.info(string.format("[%s] Configuring", device.label))
      ias_enroll(driver, device)
      device:send(clusters.IASZone.attributes.ZoneStatus:read(device))
      device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
      device.thread:call_with_delay(2, function()
        apply_all_preferences(device)
      end)
    end,
    infoChanged = function(driver, device, event, args)
      log.info(string.format("[%s] Preferences changed", device.label))
      apply_changed_preferences(device, args.old_st_store.preferences)
    end,
    driverSwitched = function(driver, device)
      log.info(string.format("[%s] Driver Switched - re-enrolling IASZone", device.label))
      ias_enroll(driver, device)
    end,
  },
  zigbee_handlers = {
    cluster = {
      [clusters.IASZone.ID] = {
        [0x00] = ias_zone_notification_handler,
        [0x01] = zone_enroll_request_handler
      },
      [TUYA_CLUSTER] = {
        [0x01] = tuya_main_handler,
        [0x02] = tuya_main_handler
      }
    },
    attr = {
      [clusters.IASZone.ID] = {
        [clusters.IASZone.attributes.ZoneStatus.ID] = ias_zone_status_handler
      },
      [clusters.PowerConfiguration.ID] = {
        [clusters.PowerConfiguration.attributes.BatteryPercentageRemaining.ID] = function(driver, device, value, zb_rx)
          local pct = math.min(100, math.floor(value.value / 2))
          log.info(string.format("[%s] Battery (ZCL): %d%%", device.label, pct))
          device:emit_event(capabilities.battery.battery(pct))
        end
      }
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      refresh = function(driver, device)
        log.info(string.format("[%s] Manual Refresh", device.label))
        device:send(clusters.IASZone.attributes.ZoneStatus:read(device))
        device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
      end
    }
  },
  can_handle = can_handle
})

log.info("!!! TUYA TZE200_ka8l86iu MOTION SENSOR DRIVER READY !!!")
contact_driver:run()
