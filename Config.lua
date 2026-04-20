--- Default configuration constants for hs_streamdeck.
-- @module Config

local M = {}

M.HOLD_DELAY = 0.5            -- seconds before long-press triggers
M.AUTO_OFF_TIMEOUT = 30 * 60  -- seconds of idle before turning off
M.BRIGHTNESS_DAY = 60
M.BRIGHTNESS_NIGHT = 25
M.BRIGHTNESS_WAKE = 30
M.DAY_START_HOUR = 8
M.DAY_END_HOUR = 18
M.BUTTON_SIZE = 96

return M
