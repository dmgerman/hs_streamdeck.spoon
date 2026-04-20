--- Icon loading and generation for Stream Deck buttons.
-- Wraps hs.image with caching via the bundled image_cache module.
-- @module Icon

-- _require is injected by init.lua before loading this module
local _require = _hs_streamdeck_require

local M = {}

local image_cache = _require("image_cache.lua")
local Renderer -- lazy-loaded to avoid circular requires

local function renderer()
  if not Renderer then
    Renderer = _require("Renderer.lua")
  end
  return Renderer
end

--- Load an icon from a file path (cached).
-- @param path string Path to image file
-- @return hs.image or nil
function M.fromPath(path)
  local key = image_cache.key_for_path(path)
  return image_cache.get_or_create(key, function()
    return hs.image.imageFromPath(path)
  end)
end

--- Load an icon from an application bundle ID (cached).
-- @param bundleID string Application bundle identifier
-- @return hs.image or nil
function M.fromBundle(bundleID)
  local key = image_cache.key_for_bundle(bundleID)
  return image_cache.get_or_create(key, function()
    return hs.image.imageFromAppBundle(bundleID)
  end)
end

--- Generate a text-based icon.
-- @param label string Text to display
-- @param opts table Options passed to Renderer.fromText
-- @return hs.image
function M.fromText(label, opts)
  return renderer().fromText(label, opts)
end

--- Return a solid black icon (singleton).
-- @return hs.image
function M.black()
  return renderer().black()
end

return M
