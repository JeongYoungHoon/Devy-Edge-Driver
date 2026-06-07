local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local generic_body = require "st.zigbee.generic_body"
local log = require "log"

local TUYA_CLUSTER = 0xEF00
local DP_TYPE_BOOL  = 0x01

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
-- Priority Matcher
------------------------------------------------------------------------

local function can_handle(opts, driver, device, ...)
  return device:get_manufacturer() == "_TZE200_ko8l86iu" and device:get_model() == "TS0601"
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
    else
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end
  elseif dp == 0x02 or dp == 0x03 or dp == 12 or dp == 101 then
    -- Battery percentage (various DPs depending on firmware)
    local pct = math.min(100, math.max(0, value))
    log.info(string.format("[%s] Battery (DP %d): %d%%", device.label, dp, pct))
    device:emit_event(capabilities.battery.battery(pct))
  end
end

-- IASZone ZoneStatus handler (backup path — Tuya TS0601 may not actually use this)
local function ias_zone_status_handler(driver, device, zone_status, zb_rx)
  local alarm1 = zone_status.value & 0x01
  log.info(string.format("[%s] IASZone ZoneStatus: 0x%04X (alarm1=%d)", device.label, zone_status.value, alarm1))
  if alarm1 == 1 then
    device:emit_event(capabilities.motionSensor.motion.active())
  else
    device:emit_event(capabilities.motionSensor.motion.inactive())
  end
end

------------------------------------------------------------------------
-- Driver Definition
------------------------------------------------------------------------

local contact_driver = ZigbeeDriver("tuya-tz-motion-sensor", {
  supported_capabilities = {
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
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end,
    doConfigure = function(driver, device)
      log.info(string.format("[%s] Configuring", device.label))
      device:send(clusters.IASZone.attributes.ZoneStatus:read(device))
      device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
    end,
  },
  zigbee_handlers = {
    cluster = {
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

log.info("!!! TUYA TZE200_ko8l86iu MOTION SENSOR DRIVER READY !!!")
contact_driver:run()
