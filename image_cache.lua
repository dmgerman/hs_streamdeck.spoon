--- Image cache system to prevent IOSurface leaks.
-- Implements content-addressed caching with LRU eviction.
-- Supports volatile entries (e.g., clock) with separate pool limit.
-- Uses lazy initialization - caching disabled during startup for performance.
--
-- @module image_cache

local module = {}

-- Cache configuration
local MAX_CACHE_SIZE = 200
local MAX_VOLATILE_SIZE = 60  -- ~1 hour of clock updates
local MAX_IOSURFACE_COUNT = 250
local EVICTION_COUNT = 50
local VOLATILE_EVICTION_COUNT = 20

-- Lazy initialization - caching disabled during startup
local caching_enabled = false
local STARTUP_DELAY = 3  -- seconds before enabling cache

-- Cache storage
-- cache[key] = {image = hs.image, hits = number, last_used = timestamp, volatile = boolean}
local cache = {}
local cache_size = 0
local volatile_count = 0

-- Statistics
local stats = {
  hits = 0,
  misses = 0,
  evictions = 0,
  creates = 0,
  volatile_hits = 0,
  volatile_misses = 0,
  volatile_evictions = 0
}

--- Generate cache key from table (fast version).
-- Uses simple string concatenation for common cases.
--
-- @param data (table): Data to hash
-- @return (string): Cache key
local function hash_table(data)
  -- Fast path: build key from known fields for small tables
  if type(data) == "table" then
    local parts = {}
    for k, v in pairs(data) do
      if type(v) == "table" and v.hex then
        -- Color table with hex
        parts[#parts + 1] = k .. "=" .. tostring(v.hex)
      elseif type(v) == "table" then
        -- Nested table - use inspect but only for this value
        parts[#parts + 1] = k .. "=" .. hs.inspect(v)
      else
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
    end
    table.sort(parts)  -- Ensure consistent ordering
    return table.concat(parts, ";")
  end
  return tostring(data)
end

--- Get current timestamp.
-- @return (number): Seconds since epoch
local function timestamp()
  return os.time()
end

--- Evict least recently used entries.
-- @param volatile_only (boolean): If true, only evict volatile entries
-- @param count (number): Number of entries to evict
local function evict_lru(volatile_only, count)
  local evict_count = count or EVICTION_COUNT

  -- Build array of {key, last_used, volatile}
  local entries = {}
  for key, entry in pairs(cache) do
    if not volatile_only or entry.volatile then
      table.insert(entries, {key = key, last_used = entry.last_used, volatile = entry.volatile})
    end
  end

  -- Sort by last_used (oldest first)
  table.sort(entries, function(a, b)
    return a.last_used < b.last_used
  end)

  -- Evict oldest entries
  local evicted = 0
  local volatile_evicted = 0
  for i = 1, math.min(evict_count, #entries) do
    local key = entries[i].key
    local was_volatile = cache[key].volatile
    cache[key] = nil
    cache_size = cache_size - 1
    evicted = evicted + 1
    if was_volatile then
      volatile_count = volatile_count - 1
      volatile_evicted = volatile_evicted + 1
    end
  end

  stats.evictions = stats.evictions + evicted
  stats.volatile_evictions = stats.volatile_evictions + volatile_evicted

  print(string.format("[Image Cache] Evicted %d entries (%d volatile), cache size: %d, volatile: %d",
    evicted, volatile_evicted, cache_size, volatile_count))
end

--- Check if cache needs eviction.
-- @param is_volatile (boolean): Whether the entry being added is volatile
-- Evicts if cache is full or IOSurface count is high.
local function check_eviction(is_volatile)
  -- Check volatile limit first
  if is_volatile and volatile_count >= MAX_VOLATILE_SIZE then
    evict_lru(true, VOLATILE_EVICTION_COUNT)  -- evict only volatile entries
  end

  -- Check overall cache limit
  if cache_size >= MAX_CACHE_SIZE then
    evict_lru(false, EVICTION_COUNT)  -- evict any entries
    return
  end

  -- Check IOSurface count if monitoring is available
  local has_monitor, monitor = pcall(require, "dmg-iosurface-monitor")
  if has_monitor and monitor.get_iosurface_count then
    local ok, count = pcall(monitor.get_iosurface_count)
    if ok and count and count > MAX_IOSURFACE_COUNT then
      print(string.format("[Image Cache] IOSurface count high (%d), evicting cache",
        count))
      evict_lru(false, EVICTION_COUNT)
    end
  end
end

--- Get image from cache.
--
-- @param key (string): Cache key
-- @return (hs.image or nil): Cached image or nil if not found
function module.get(key)
  local entry = cache[key]
  if entry then
    entry.hits = entry.hits + 1
    entry.last_used = timestamp()
    if entry.volatile then
      stats.volatile_hits = stats.volatile_hits + 1
    else
      stats.hits = stats.hits + 1
    end
    return entry.image
  end

  stats.misses = stats.misses + 1
  return nil
end

--- Store image in cache.
--
-- @param key (string): Cache key
-- @param image (hs.image): Image to cache
-- @param volatile (boolean): Whether this is a volatile entry (e.g., clock)
function module.put(key, image, volatile)
  local is_volatile = volatile or false
  check_eviction(is_volatile)

  -- Track if we're replacing an existing entry
  local existing = cache[key]
  if existing then
    if existing.volatile then
      volatile_count = volatile_count - 1
    end
  else
    cache_size = cache_size + 1
  end

  cache[key] = {
    image = image,
    hits = 0,
    last_used = timestamp(),
    volatile = is_volatile
  }

  if is_volatile then
    volatile_count = volatile_count + 1
  end

  stats.creates = stats.creates + 1
end

--- Get or create image with caching.
-- If image exists in cache, returns it. Otherwise creates it and caches.
-- During startup (before caching is enabled), bypasses cache entirely.
--
-- @param key (string): Cache key
-- @param create_fn (function): Function that creates the image
-- @param volatile (boolean): Whether this is a volatile entry
-- @return (hs.image): Cached or newly created image
function module.get_or_create(key, create_fn, volatile)
  -- Bypass cache during startup for performance
  if not caching_enabled then
    return create_fn()
  end

  local cached = module.get(key)
  if cached then
    return cached
  end

  if volatile then
    stats.volatile_misses = stats.volatile_misses + 1
  end

  local image = create_fn()
  if image then
    module.put(key, image, volatile)
  end

  return image
end

--- Check if caching is currently enabled.
-- @return (boolean): true if caching is active
function module.is_enabled()
  return caching_enabled
end

--- Enable caching manually.
function module.enable()
  if not caching_enabled then
    caching_enabled = true
    print("[Image Cache] Caching enabled")
  end
end

--- Disable caching (for testing).
function module.disable()
  caching_enabled = false
  print("[Image Cache] Caching disabled")
end

--- Schedule caching to be enabled after startup delay.
-- Call this at the end of streamdeck initialization.
function module.enable_after_startup()
  hs.timer.doAfter(STARTUP_DELAY, function()
    module.enable()
  end)
  print(string.format("[Image Cache] Will enable in %d seconds", STARTUP_DELAY))
end

--- Clear entire cache.
function module.clear()
  cache = {}
  cache_size = 0
  volatile_count = 0
  print("[Image Cache] Cleared all entries")
end

--- Get cache statistics.
-- @return (table): Full statistics including volatile tracking
function module.get_stats()
  local total_requests = stats.hits + stats.misses
  local hit_rate = total_requests > 0 and (stats.hits / total_requests * 100) or 0
  local volatile_total = stats.volatile_hits + stats.volatile_misses
  local volatile_hit_rate = volatile_total > 0 and (stats.volatile_hits / volatile_total * 100) or 0

  return {
    enabled = caching_enabled,
    hits = stats.hits,
    misses = stats.misses,
    size = cache_size,
    hit_rate = hit_rate,
    creates = stats.creates,
    evictions = stats.evictions,
    volatile_count = volatile_count,
    volatile_hits = stats.volatile_hits,
    volatile_misses = stats.volatile_misses,
    volatile_hit_rate = volatile_hit_rate,
    volatile_evictions = stats.volatile_evictions,
    max_size = MAX_CACHE_SIZE,
    max_volatile = MAX_VOLATILE_SIZE
  }
end

--- Print cache statistics to console.
function module.print_stats()
  local s = module.get_stats()
  print(string.format([[
[Image Cache Statistics]
  Status: %s
  Regular Cache:
    Size: %d / %d
    Hits: %d | Misses: %d | Hit Rate: %.1f%%
    Creates: %d | Evictions: %d
  Volatile Cache:
    Size: %d / %d
    Hits: %d | Misses: %d | Hit Rate: %.1f%%
    Evictions: %d
  ]], s.enabled and "ENABLED" or "DISABLED (startup)",
      s.size, s.max_size, s.hits, s.misses, s.hit_rate, s.creates, s.evictions,
      s.volatile_count, s.max_volatile, s.volatile_hits, s.volatile_misses,
      s.volatile_hit_rate, s.volatile_evictions))
end

--- Generate key for canvas content.
-- @param contents (table): Canvas elements table
-- @return (string): Cache key
function module.key_for_canvas(contents)
  -- For canvas arrays, use hs.inspect but avoid SHA256
  -- This is still needed for complex nested structures
  return "canvas:" .. hs.inspect(contents, {depth = 3, newline = "", indent = ""})
end

--- Generate key for text image.
-- @param text (string): Text content
-- @param options (table): Options table
-- @return (string): Cache key
function module.key_for_text(text, options)
  local opt_hash = options and hash_table(options) or "default"
  return string.format("text:%s:%s", text, opt_hash)
end

--- Generate key for file path image.
-- @param path (string): File path
-- @return (string): Cache key
function module.key_for_path(path)
  -- Include file mtime to invalidate cache when file changes
  local attrs = hs.fs.attributes(path)
  local mtime = attrs and attrs.modification or "0"
  return string.format("path:%s:%s", path, mtime)
end

--- Generate key for bundle ID image.
-- @param bundleID (string): Application bundle ID
-- @return (string): Cache key
function module.key_for_bundle(bundleID)
  return "bundle:" .. bundleID
end

--- Generate key for volatile text (e.g., clock).
-- @param text (string): Text content
-- @param options (table): Options table
-- @return (string): Cache key with volatile prefix
function module.key_for_volatile_text(text, options)
  local opt_hash = options and hash_table(options) or "default"
  return string.format("volatile:text:%s:%s", text, opt_hash)
end

--- Get configuration values (for testing).
-- @return (table): Configuration constants
function module.get_config()
  return {
    MAX_CACHE_SIZE = MAX_CACHE_SIZE,
    MAX_VOLATILE_SIZE = MAX_VOLATILE_SIZE,
    EVICTION_COUNT = EVICTION_COUNT,
    VOLATILE_EVICTION_COUNT = VOLATILE_EVICTION_COUNT
  }
end

--- Reset statistics (for testing).
function module.reset_stats()
  stats = {
    hits = 0,
    misses = 0,
    evictions = 0,
    creates = 0,
    volatile_hits = 0,
    volatile_misses = 0,
    volatile_evictions = 0
  }
end

return module
