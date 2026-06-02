local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters = require "st.zigbee.zcl.clusters"
local log = require "log"

-- Constants
local TUYA_CLUSTER = 0xEF00

-- Priority Matcher
local function can_handle_hobeian(opts, driver, device, ...)
  return device:get_manufacturer() == "HOBEIAN" and device:get_model() == "ZG-204ZK"
end

------------------------------------------------------------------------
-- Handlers
------------------------------------------------------------------------

-- 1. Battery Handler
local function battery_perc_handler(driver, device, value, zb_rx)
  -- Tuya reports often send double the value (0xC8 = 200 -> 100%)
  local percentage = math.min(100, math.floor(value.value / 2))
  log.info(string.format("[%s] Battery Level: %d%%", device.label, percentage))
  device:emit_event(capabilities.battery.battery(percentage))
end

-- 2. Tuya Cluster (0xEF00) Handler
local function tuya_main_handler(driver, device, zb_rx)
  local payload = zb_rx.body.zcl_body.body_bytes
  if #payload < 6 then return end

  local dp = payload:byte(3)
  local value = 0
  local len = (payload:byte(5) * 256) + payload:byte(6)
  
  if len == 1 then
    value = payload:byte(7)
  elseif len == 4 then
    value = (payload:byte(7) * 16777216) + (payload:byte(8) * 65536) + (payload:byte(9) * 256) + payload:byte(10)
  end

  -- Detailed Logging for Insight
  log.info(string.format("[%s] Tuya DP %d: %d", device.label, dp, value))

  if dp == 0x01 or dp == 101 then
    if value == 1 then
      device:emit_event(capabilities.presenceSensor.presence.present())
      device:emit_event(capabilities.motionSensor.motion.active())
    else
      device:emit_event(capabilities.presenceSensor.presence.not_present())
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end
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
  lifecycle_handlers = {
    init = function(driver, device)
      log.info(string.format("[%s] Driver Loaded", device.label))
    end,
    added = function(driver, device)
      log.info(string.format("[%s] Device Added", device.label))
      -- Set initial UI state
      device:emit_event(capabilities.presenceSensor.presence.not_present())
      device:emit_event(capabilities.motionSensor.motion.inactive())
    end,
    doConfigure = function(driver, device)
      log.info(string.format("[%s] Configuring", device.label))
      -- Standard reporting requests
      device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
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

log.info("!!! HOBEIAN ZG-204ZK FINAL DRIVER READY !!!")
hobeian_driver:run()
