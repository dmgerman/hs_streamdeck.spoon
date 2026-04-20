--- Per-deck state machine for Stream Deck devices.
-- Handles navigation stack, scrolling, button rendering, timers, and press/hold.
-- @module Deck

local M = {}
M.__index = M

-- _require is injected by init.lua before loading this module
local _require = _hs_streamdeck_require

local Config = _require("Config.lua")
local Renderer = _require("Renderer.lua")
local Icon = _require("Icon.lua")

--- Deep-compare two tables for equality.
local function equals(o1, o2)
  if o1 == o2 then return true end
  if type(o1) ~= "table" or type(o2) ~= "table" then return false end
  for k, v in pairs(o1) do
    if not equals(v, o2[k]) then return false end
  end
  for k in pairs(o2) do
    if o1[k] == nil then return false end
  end
  return true
end

--- Shallow-clone a table.
local function clone(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- Stop a timer if non-nil.
local function stopTimer(timer)
  if timer then timer:stop() end
end

--- Preload static icons for a button (icon, image, app fields).
-- Skips buttons with imageProvider (dynamic).
local function preloadButtonImage(button)
  if not button or button.imageProvider then return end
  if button._resolvedImage then return end

  if button.image then
    if type(button.image) == "string" then
      button._resolvedImage = Icon.fromPath(button.image)
    else
      button._resolvedImage = button.image
    end
    if button._resolvedImage then return end
  end

  if button.icon then
    if type(button.icon) == "string" then
      button._resolvedImage = Icon.fromPath(button.icon)
    else
      button._resolvedImage = button.icon
    end
    if button._resolvedImage then return end
  end

  if button.app then
    button._resolvedImage = Icon.fromBundle(button.app)
    if button._resolvedImage then return end
  end

  if button.label then
    button._resolvedImage = Renderer.fromText(button.label, { fontSize = 30 })
  end
end

--- Preload all static icons for a list of buttons.
local function preloadButtons(buttons)
  for _, button in ipairs(buttons) do
    preloadButtonImage(button)
  end
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

--- Create a new Deck state machine for a connected Stream Deck.
-- @param device hs.streamdeck The hardware device
-- @param menuDef table Array of button definitions (the root menu)
-- @param menuName string Name for the root menu
-- @return Deck instance
function M.new(device, menuDef, menuName)
  local self = setmetatable({}, M)
  self.device = device
  self.serial = device:serialNumber()
  self.columns, self.rows = device:buttonLayout()
  self.totalButtons = self.columns * self.rows
  self.asleep = false
  self.isOn = false

  -- Navigation stack: array of {name, buttons, scrollOffset}
  self.stack = {}
  -- Current state
  self.state = { name = menuName or "Root", buttons = menuDef or {}, scrollOffset = 0 }
  -- Update timers for visible buttons
  self.updateTimers = {}
  -- Cache for visible buttons computation
  self._visibleCache = nil
  self._visibleCacheValid = false

  -- Preload static icons for root menu buttons
  preloadButtons(self.state.buttons)

  return self
end

--------------------------------------------------------------------------------
-- Visible Buttons Computation
--------------------------------------------------------------------------------

--- Invalidate the visible buttons cache.
function M:invalidateCache()
  self._visibleCacheValid = false
end

--- Build the back button for submenu navigation.
local function backButton(deck)
  return {
    label = "Back",
    _resolvedImage = Icon.fromPath(hs.spoons.resourcePath("icons/back.png")),
    onClick = function() deck:pop() end,
  }
end

--- Build a scroll-up button.
local function scrollUpButton(deck)
  local pageRows = math.floor((deck.totalButtons - 4) / (deck.columns - 1))
  return {
    label = "Up",
    _resolvedImage = Renderer.fromText("Up"),
    onClick = function() deck:scrollBy(-pageRows) end,
    onLongPress = function() deck:scrollToTop() end,
  }
end

--- Build a scroll-down button.
local function scrollDownButton(deck)
  local pageRows = math.floor((deck.totalButtons - 4) / (deck.columns - 1))
  return {
    label = "Down",
    _resolvedImage = Renderer.fromText("Down"),
    onClick = function() deck:scrollBy(pageRows) end,
  }
end

--- Build a black filler button (no action).
local function fillerButton()
  return {
    label = "Filler",
    _resolvedImage = Renderer.black(),
    _isFiller = true,
  }
end

--- Build the toggle on/off button.
local function toggleButton(deck)
  return {
    label = "Toggle",
    _resolvedImage = Icon.fromPath(hs.spoons.resourcePath("icons/toggle.png")),
    onClick = function() deck:toggle() end,
  }
end

--- Compute the currently visible buttons for this deck.
-- Applies scrolling, inserts back/scroll/toggle/filler buttons.
-- Layout:
--   Position 1: toggle (root) or back (submenu)
--   Last position: toggle
--   When scrolling: scroll-up at row 2 col 1, scroll-down at last row col 1
-- @return table Array of button definitions, exactly totalButtons in length
function M:visibleButtons()
  if self._visibleCacheValid then return self._visibleCache end

  local provided = self.state.buttons or {}
  local nProvided = #provided
  local offset = self.state.scrollOffset or 0
  local cols = self.columns
  local rows = self.rows
  local total = self.totalButtons

  -- Reserved slots: position 1 (toggle/back) and last position (toggle)
  -- If scrolling: also scroll-up (row 2, col 1) and scroll-down (last row, col 1)
  local slotsWithoutScroll = total - 2
  local slotsWithScroll = total - 4
  local needsScroll = nProvided > slotsWithoutScroll

  local perScrollStep = cols - 1
  local skipCount = offset * perScrollStep

  local userSlots = needsScroll and slotsWithScroll or slotsWithoutScroll
  local userButtons = {}
  for i = skipCount + 1, math.min(skipCount + userSlots, nProvided) do
    userButtons[#userButtons + 1] = provided[i]
  end

  local buttons = {}
  local idx = 1  -- index into userButtons

  for r = 1, rows do
    for c = 1, cols do
      local isFirst = (r == 1 and c == 1)
      local isLast = (r == rows and c == cols)

      if isFirst then
        -- Position 1: toggle or back
        if #self.stack > 0 then
          buttons[#buttons + 1] = backButton(self)
        else
          buttons[#buttons + 1] = toggleButton(self)
        end
      elseif isLast then
        -- Last position: toggle
        buttons[#buttons + 1] = toggleButton(self)
      elseif needsScroll and c == 1 and r == 2 then
        -- Scroll up
        buttons[#buttons + 1] = scrollUpButton(self)
      elseif needsScroll and c == 1 and r == rows then
        -- Scroll down (or filler if nothing below)
        local moreBelow = (skipCount + userSlots) < nProvided
        buttons[#buttons + 1] = moreBelow and scrollDownButton(self) or fillerButton()
      else
        -- User button or filler
        buttons[#buttons + 1] = userButtons[idx] or fillerButton()
        idx = idx + 1
      end
    end
  end

  self._visibleCache = buttons
  self._visibleCacheValid = true
  return buttons
end

--------------------------------------------------------------------------------
-- Button Update
--------------------------------------------------------------------------------

--- Build a context table for a button at a given index.
local function contextForIndex(deck, i)
  local idx = i - 1
  return {
    location = { x = idx % deck.columns, y = math.floor(idx / deck.columns) },
    size = { w = deck.columns, h = deck.rows },
    isPressed = false,
    deck = deck,
  }
end

--- Resolve the image for a button, handling static vs dynamic.
-- @param button table Button definition
-- @param context table Context with location, size, isPressed
local function resolveButtonImage(button, context)
  if not button then return nil end

  -- Already resolved (filler, back, scroll, toggle)
  if button._resolvedImage and not button.imageProvider then
    return button._resolvedImage
  end

  -- Static image field
  if button.image then
    if type(button.image) == "string" then
      local img = Icon.fromPath(button.image)
      if img then
        button._resolvedImage = img
        return img
      end
      -- Path not found, fall through to label
    else
      button._resolvedImage = button.image
      return button._resolvedImage
    end
  end

  -- Static icon field
  if button.icon and not button.imageProvider then
    if type(button.icon) == "string" then
      local img = Icon.fromPath(button.icon)
      if img then
        button._resolvedImage = img
        return img
      end
      -- Path not found, fall through to label
    else
      button._resolvedImage = button.icon
      return button._resolvedImage
    end
  end

  -- App bundle shorthand
  if button.app and not button.imageProvider then
    button._resolvedImage = Icon.fromBundle(button.app)
    return button._resolvedImage
  end

  -- Dynamic: use stateProvider + imageProvider
  if button.imageProvider then
    local dirty = true
    if button.stateProvider then
      local newState = button.stateProvider() or {}
      local lastState = button._lastState or {}
      dirty = not equals(newState, lastState)
      button._lastState = newState
      context.state = newState
    end
    if dirty or not button._lastImage then
      -- Release previous image to allow GC
      button._lastImage = nil
      button._lastImage = button.imageProvider(context)
    end
    return button._lastImage
  end

  -- Fallback: generate from label
  if button.label then
    button._resolvedImage = Renderer.fromText(button.label, { fontSize = 30 })
    return button._resolvedImage
  end

  return Renderer.black()
end

--- Update a single button on the hardware.
-- @param i number Button index (1-based)
-- @param pressed boolean Whether the button is pressed
function M:updateButton(i, pressed)
  if not self.device then return end
  local button = self:visibleButtons()[i]
  if not button then return end

  local ctx = contextForIndex(self, i)
  if pressed ~= nil then ctx.isPressed = pressed end

  local image = resolveButtonImage(button, ctx)
  if image then
    self.device:setButtonImage(i, image)
  end
end

--- Update all buttons on the hardware.
function M:updateAllButtons()
  if not self.device then return end
  if self.asleep then return end

  for i = 1, self.totalButtons do
    self:updateButton(i)
  end
  self:setupTimers()
end

--------------------------------------------------------------------------------
-- Timer Management
--------------------------------------------------------------------------------

--- Stop all update timers.
function M:stopTimers()
  for _, timer in ipairs(self.updateTimers) do
    stopTimer(timer)
  end
  self.updateTimers = {}

  -- Stop hold timers on all reachable buttons
  local allStates = { self.state }
  for _, s in ipairs(self.stack) do allStates[#allStates + 1] = s end
  for _, s in ipairs(allStates) do
    for _, button in ipairs(s.buttons or {}) do
      stopTimer(button._holdTimer)
      button._holdTimer = nil
    end
  end
end

--- Set up update timers for visible buttons.
function M:setupTimers()
  self:stopTimers()
  if self.asleep then return end

  local visible = self:visibleButtons()
  for i, button in ipairs(visible) do
    if button.updateInterval then
      local timer = hs.timer.new(button.updateInterval, function()
        self:invalidateCache()
        self:updateButton(i)
      end)
      timer:start()
      self.updateTimers[#self.updateTimers + 1] = timer
    end
  end
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

--- Push a new menu onto the navigation stack.
-- @param newMenu table Array of button definitions
-- @param name string Menu name
function M:push(newMenu, name)
  -- Save current state
  self.stack[#self.stack + 1] = {
    name = self.state.name,
    buttons = self.state.buttons,
    scrollOffset = self.state.scrollOffset,
  }
  self.state = { name = name or "Submenu", buttons = newMenu, scrollOffset = 0 }
  preloadButtons(self.state.buttons)
  self:invalidateCache()
  self:updateAllButtons()
end

--- Pop back to the previous menu.
function M:pop()
  if #self.stack == 0 then return end
  self:toggle(true) -- pop turns deck on

  self.state = table.remove(self.stack)
  self:invalidateCache()
  self:updateAllButtons()
end

--- Scroll by a number of rows.
-- @param amount number Rows to scroll (positive = down, negative = up)
function M:scrollBy(amount)
  local nProvided = #(self.state.buttons or {})
  local perStep = self.columns - 1
  local maxOffset = math.max(0, math.ceil(nProvided / perStep) - 1)
  local offset = (self.state.scrollOffset or 0) + amount
  self.state.scrollOffset = math.max(0, math.min(offset, maxOffset))
  self:invalidateCache()
  self:updateAllButtons()
end

--- Scroll to the top.
function M:scrollToTop()
  self.state.scrollOffset = 0
  self:invalidateCache()
  self:updateAllButtons()
end

--------------------------------------------------------------------------------
-- Button Press / Hold
--------------------------------------------------------------------------------

--- Handle a button press or release from the hardware callback.
-- @param buttonID number Button index (1-based)
-- @param pressed boolean True if pressed, false if released
function M:handleButton(buttonID, pressed)
  if self.asleep then return end

  local button = self:visibleButtons()[buttonID]
  if not button then
    self:updateButton(buttonID, pressed)
    return
  end

  local click = button.onClick or function() end
  local hold = button.onLongPress or function() end

  if pressed then
    self:updateButton(buttonID, true)
    button._holdTimer = hs.timer.new(Config.HOLD_DELAY, function()
      hold(true)
      button._isHolding = true
      stopTimer(button._holdTimer)
    end)
    button._holdTimer:start()
  else
    self:updateButton(buttonID, false)
    if button._isHolding then
      hold(false)
    else
      local ctx = contextForIndex(self, buttonID)
      click(ctx)
      -- Check for children (submenu)
      local children = button.children
      if children then
        local childButtons
        if type(children) == "function" then
          childButtons = children(ctx)
        else
          childButtons = children
        end
        if childButtons then
          self:push(childButtons, button.label or button.name or "Submenu")
        end
      end
    end
    stopTimer(button._holdTimer)
    button._isHolding = nil
  end
end

--------------------------------------------------------------------------------
-- Sleep / Wake / Toggle / Brightness
--------------------------------------------------------------------------------

--- Put the deck to sleep (stop timers, keep connected).
function M:sleep()
  self.asleep = true
  self:stopTimers()
end

--- Wake the deck up.
function M:wake()
  if not self.device then return end
  self.asleep = false
  self:invalidateCache()
  self.device:setBrightness(Config.BRIGHTNESS_WAKE)
  self:updateAllButtons()
end

--- Toggle the deck on or off.
-- @param forceOn boolean If true, force the deck on
function M:toggle(forceOn)
  if not self.device then return end

  if self.isOn and not forceOn then
    self.device:setBrightness(0)
    self.isOn = false
  else
    self.isOn = true
    local hour = hs.timer.localTime() / 3600
    local brightness
    if hour > Config.DAY_START_HOUR and hour < Config.DAY_END_HOUR then
      brightness = Config.BRIGHTNESS_DAY
    else
      brightness = Config.BRIGHTNESS_NIGHT
    end
    self.device:setBrightness(brightness)
  end
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

--- Release all resources for this deck.
-- Clears all hardware buttons to black before releasing the device.
function M:cleanup()
  self:stopTimers()

  -- Clear all hardware buttons to black
  if self.device then
    local black = Renderer.black()
    for i = 1, self.totalButtons do
      pcall(function() self.device:setButtonImage(i, black) end)
    end
    pcall(function() self.device:setBrightness(0) end)
  end

  -- Release cached images from dynamic buttons
  local allStates = { self.state }
  for _, s in ipairs(self.stack) do allStates[#allStates + 1] = s end
  for _, s in ipairs(allStates) do
    for _, button in ipairs(s.buttons or {}) do
      button._lastImage = nil
      button._resolvedImage = nil
      button._lastState = nil
    end
  end
  self._visibleCache = nil
  self.device = nil
end

return M
