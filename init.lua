--- === hs_streamdeck ===
---
--- Stream Deck management spoon for Hammerspoon.
--- Provides button navigation with stacks, scrolling, and timer-based updates.
--- Separates generic deck management from user configuration.
---
--- ## Quick Start
---
--- ```lua
--- local sd = hs.loadSpoon("hs_streamdeck")
---
--- sd:setMenu("large", {
---   {label = "Apps", icon = "icons/apps.png", children = appsMenu},
---   {label = "Chrome", app = "com.google.Chrome"},
---   {label = "Clock", imageProvider = clockFn, updateInterval = 60, volatile = true},
--- })
---
--- sd:start()
--- ```
---
--- ## Button Definition
---
--- Buttons are plain tables with these fields:
---  * `label` (string) - Text shown on button (also used as fallback image)
---  * `icon` (string|hs.image) - Path to image file or pre-loaded image
---  * `app` (string) - Bundle ID: auto-generates icon, launches on click
---  * `url` (string) - URL to open on click
---  * `onClick` (function(ctx)) - Click handler
---  * `onLongPress` (function(pressed)) - Hold handler
---  * `children` (table|function(ctx)) - Submenu buttons
---  * `imageProvider` (function(ctx) -> hs.image) - Dynamic image generator
---  * `stateProvider` (function() -> any) - State for dirty-checking
---  * `updateInterval` (number) - Seconds between refreshes
---  * `volatile` (boolean) - Use volatile cache pool

--- Module cache (cleared on hs.reload)
_hs_streamdeck_modules = _hs_streamdeck_modules or {}
local function _require(name)
  if not _hs_streamdeck_modules[name] then
    _hs_streamdeck_modules[name] = dofile(hs.spoons.resourcePath(name))
  end
  return _hs_streamdeck_modules[name]
end

local M = {}

M.name = "hs_streamdeck"
M.version = "0.1.0"
M.author = "Daniel German <dmg@turingmachine.org>"
M.license = "MIT"

--------------------------------------------------------------------------------
-- Public Modules
--------------------------------------------------------------------------------

--- hs_streamdeck.Deck
--- Variable
--- Per-device state machine (navigation, scrolling, timers, press/hold).
M.Deck = _require("Deck.lua")

--- hs_streamdeck.Renderer
--- Variable
--- Image rendering (text, canvas, black filler).
M.Renderer = _require("Renderer.lua")

--- hs_streamdeck.Icon
--- Variable
--- Icon loading and generation (fromPath, fromBundle, fromText, black).
M.Icon = _require("Icon.lua")

--- hs_streamdeck.Config
--- Variable
--- Default constants (brightness, timeouts, hold delay, button size).
M.Config = _require("Config.lua")

--------------------------------------------------------------------------------
-- Internal State
--------------------------------------------------------------------------------

local decks = {}         -- serial -> Deck instance
local menus = {}         -- key -> {name, buttons} (key is serial or "large"/"small")
local defaultMenu = nil  -- fallback menu if no specific one matches
local lockWatcher = nil
local autoOffTimer = nil
local logger = hs.logger.new("streamdeck", "info")

--------------------------------------------------------------------------------
-- Menu Registration
--------------------------------------------------------------------------------

--- Register a menu for a specific deck (by serial number or size "large"/"small").
-- @param key string Serial number, or "large" (5x3+), or "small" (3x2)
-- @param buttons table Array of button definitions
-- @param name string Optional menu name
function M:setMenu(key, buttons, name)
  menus[key] = { name = name or "Root", buttons = buttons }
  return self
end

--- Set a default menu used when no serial/size match is found.
-- @param buttons table Array of button definitions
-- @param name string Optional menu name
function M:setDefaultMenu(buttons, name)
  defaultMenu = { name = name or "Root", buttons = buttons }
  return self
end

--------------------------------------------------------------------------------
-- Menu Lookup
--------------------------------------------------------------------------------

local function menuForDeck(device)
  local serial = device:serialNumber()
  if menus[serial] then return menus[serial] end

  local cols, rows = device:buttonLayout()
  local total = cols * rows
  if total >= 15 and menus["large"] then return menus["large"] end
  if total < 15 and menus["small"] then return menus["small"] end

  return defaultMenu or { name = "Empty", buttons = {} }
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

local function onDiscovery(connected, device)
  local serial = device:serialNumber()

  if connected then
    logger.i("Deck connected: " .. serial)
    local menu = menuForDeck(device)
    local deck = M.Deck.new(device, menu.buttons, menu.name)
    decks[serial] = deck

    device:buttonCallback(function(_, buttonID, pressed)
      deck:handleButton(buttonID, pressed)
    end)
    device:reset()
    deck:toggle(true)
    deck:updateAllButtons()

    if lockWatcher then lockWatcher:start() end
    if autoOffTimer then autoOffTimer:start() end
  else
    logger.i("Deck disconnected: " .. serial)
    local deck = decks[serial]
    if deck then
      deck:cleanup()
      decks[serial] = nil
    end
    if not next(decks) then
      if lockWatcher then lockWatcher:stop() end
      if autoOffTimer then autoOffTimer:stop() end
    end
  end
end

--------------------------------------------------------------------------------
-- All-Decks Operations
--------------------------------------------------------------------------------

local function forAllDecks(fn)
  for _, deck in pairs(decks) do fn(deck) end
end

--------------------------------------------------------------------------------
-- Spoon Lifecycle
--------------------------------------------------------------------------------

--- Initialize the spoon.
function M:init()
  return self
end

--- Start the spoon: begin listening for Stream Deck connections.
function M:start()
  -- Lock/unlock watcher
  lockWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidLock then
      forAllDecks(function(d) d:toggle(false) end)
    elseif event == hs.caffeinate.watcher.screensDidUnlock then
      forAllDecks(function(d) d:toggle(true) end)
    end
  end)

  -- Auto-off timer
  autoOffTimer = hs.timer.doEvery(M.Config.AUTO_OFF_TIMEOUT, function()
    forAllDecks(function(d)
      d.device:setBrightness(0)
      d.isOn = false
    end)
  end)

  -- Start discovery
  hs.streamdeck.init(onDiscovery)

  -- Enable image caching after startup
  local image_cache = dofile(hs.spoons.resourcePath("image_cache.lua"))
  image_cache.enable()
  logger.i("Started")

  return self
end

--- Stop the spoon: disconnect all decks, clean up resources.
function M:stop()
  forAllDecks(function(d) d:cleanup() end)
  decks = {}
  if lockWatcher then lockWatcher:stop(); lockWatcher = nil end
  if autoOffTimer then autoOffTimer:stop(); autoOffTimer = nil end
  M.Renderer.cleanup()
  logger.i("Stopped")
  return self
end

--- Clean up before Hammerspoon reload.
function M.cleanup()
  for _, deck in pairs(decks) do
    pcall(function() deck:cleanup() end)
  end
  decks = {}
  pcall(function()
    if lockWatcher then lockWatcher:stop() end
    if autoOffTimer then autoOffTimer:stop() end
    M.Renderer.cleanup()
  end)
end

--- Get a connected deck by serial number.
-- @param serial string Serial number
-- @return Deck instance or nil
function M:getDeck(serial)
  return decks[serial]
end

--- Get all connected decks.
-- @return table serial -> Deck
function M:getDecks()
  return decks
end

return M
