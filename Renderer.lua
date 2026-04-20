--- Image rendering for Stream Deck buttons.
-- Creates images from text or canvas elements using a shared canvas.
-- Delegates caching to the bundled image_cache module.
-- @module Renderer

-- _require is injected by init.lua before loading this module
local _require = _hs_streamdeck_require

local M = {}

local Config = _require("Config.lua")
local image_cache = _require("image_cache.lua")

local sharedCanvas = hs.canvas.new({ w = Config.BUTTON_SIZE, h = Config.BUTTON_SIZE })

--- Create an image from canvas elements.
-- @param elements table Array of canvas element tables
-- @param volatile boolean If true, use volatile cache pool
-- @return hs.image
function M.fromCanvas(elements, volatile)
  local key = image_cache.key_for_canvas(elements)
  return image_cache.get_or_create(key, function()
    sharedCanvas:replaceElements(elements)
    return sharedCanvas:imageFromCanvas()
  end, volatile)
end

--- Create a text image for a button.
-- @param text string Text to render
-- @param opts table Options: textColor, backgroundColor, font, fontSize, volatile
-- @return hs.image
function M.fromText(text, opts)
  opts = opts or {}
  local volatile = opts.volatile or false
  local textColor = opts.textColor or { hex = "#FFFFFF" }
  local backgroundColor = opts.backgroundColor or { hex = "#000000" }
  local font = opts.font or ".AppleSystemUIFont"
  local fontSize = opts.fontSize or 40

  local key
  if volatile then
    key = image_cache.key_for_volatile_text(text, opts)
  else
    key = image_cache.key_for_text(text, opts)
  end

  local size = Config.BUTTON_SIZE
  return image_cache.get_or_create(key, function()
    local elements = {
      {
        action = "fill",
        frame = { x = 0, y = 0, w = size, h = size },
        fillColor = backgroundColor,
        type = "rectangle",
      },
      {
        frame = { x = 0, y = 0, w = size, h = size },
        text = hs.styledtext.new(text, {
          font = { name = font, size = fontSize },
          paragraphStyle = { alignment = "center" },
          color = textColor,
        }),
        type = "text",
      },
    }
    sharedCanvas:replaceElements(elements)
    return sharedCanvas:imageFromCanvas()
  end, volatile)
end

-- Singleton black image, created once
local _blackImage = nil

--- Return a solid black image (cached singleton).
-- @return hs.image
function M.black()
  if _blackImage then return _blackImage end
  local size = Config.BUTTON_SIZE
  local canvas = hs.canvas.new({ w = size, h = size })
  canvas:appendElements({
    action = "fill",
    frame = { x = 0, y = 0, w = size, h = size },
    fillColor = { hex = "#000000" },
    type = "rectangle",
  })
  _blackImage = canvas:imageFromCanvas()
  canvas:delete()
  return _blackImage
end

--- Clean up the shared canvas.
function M.cleanup()
  if sharedCanvas then
    sharedCanvas:delete()
    sharedCanvas = nil
  end
  _blackImage = nil
end

return M
