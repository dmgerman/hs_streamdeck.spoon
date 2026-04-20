# hs_streamdeck.spoon

Stream Deck management spoon for Hammerspoon. Provides stack-based menu navigation, scrolling, dynamic button updates, and multi-deck support with per-device layouts.

## Architecture

```
init.lua        → Spoon lifecycle, device discovery, menu registration API
Deck.lua        → Per-deck state machine (nav stack, scroll, timers, press/hold, sleep/wake)
Renderer.lua    → Image generation (text→image, canvas→image, black filler singleton)
Icon.lua        → Icon loading with cache (fromPath, fromBundle, fromText)
Config.lua      → Named constants (brightness, timeouts, hold delay, button size)
image_cache.lua → LRU image cache with volatile pool (prevents IOSurface leaks)
icons/          → Bundled navigation icons (back.png, toggle.png)
```

### Data Flow

1. `sd:start()` → registers `hs.streamdeck.init()` discovery callback
2. Device connects → `Deck.new()` created, keyed by serial number
3. `Deck:updateAllButtons()` → `visibleButtons()` computes layout → `resolveButtonImage()` per button
4. Button press → `Deck:handleButton()` → hold timer or click dispatch → optional submenu push
5. Dynamic buttons (`imageProvider` + `updateInterval`) update via per-button timers

### Module Loading

Uses `_require()` with global cache (`_hs_streamdeck_modules`), same pattern as hs_grid_hammer. Cleared naturally on `hs.reload()`.

### Button Resolution Order

`resolveButtonImage()` tries these in order, stopping at the first non-nil result:
1. `_resolvedImage` (already cached — filler, back, scroll, toggle)
2. `image` field (string path or hs.image)
3. `icon` field (string path or hs.image)
4. `app` field (bundle ID → `Icon.fromBundle`)
5. `imageProvider(context)` (dynamic, with dirty-checking via `stateProvider`)
6. `label` field → `Renderer.fromText(label)`
7. `Renderer.black()` (final fallback)

If a string path fails `Icon.fromPath()` (returns nil), it falls through to the next option. This is intentional — text labels like "on 100" that aren't file paths get rendered as text.

### Visible Buttons Layout

`Deck:visibleButtons()` builds the hardware layout from user-provided buttons:
1. Apply scroll offset (drop rows from start)
2. Insert toggle button at position 1 (root) or back button (submenu)
3. Pad with black fillers to fill the deck
4. Insert scroll up/down if buttons exceed deck capacity
5. Insert toggle button near bottom-right
6. Trim to exact deck size

### State Per Deck (keyed by serial number)

- `state` — current menu: `{name, buttons, scrollOffset}`
- `stack` — array of previous states (push/pop navigation)
- `updateTimers` — active per-button timers (recreated on state change)
- `asleep`, `isOn` — power state
- `_visibleCache` / `_visibleCacheValid` — computed layout cache

## Key Behaviors

- **Press/hold**: 0.5s threshold (`Config.HOLD_DELAY`). Press starts a timer; if held past threshold, `onLongPress(true)` fires. On release: `onLongPress(false)` if held, `onClick(ctx)` if not.
- **Children**: After `onClick`, if button has `children` (table or function), the result is pushed as a submenu.
- **Timers**: All timers are stopped and recreated on every state change (push, pop, scroll, updateAllButtons).
- **Toggle**: Brightness set by time of day (day: 60, night: 25, configurable in Config.lua).
- **Auto-off**: `Config.AUTO_OFF_TIMEOUT` (30min default) turns off all decks.
- **Lock/unlock**: Screen lock turns decks off, unlock turns them on.
- **Cache invalidation**: Any state mutation calls `invalidateCache()`. `visibleButtons()` recomputes only when invalid.

## Development Notes

- The spoon is fully self-contained — no external dependencies. `image_cache.lua` and navigation icons are bundled.
- All modules share a single `image_cache` instance via `_require()` (exposed as `_hs_streamdeck_require`).
- `Renderer.black()` returns a singleton — safe to call frequently.
- `Renderer.fromCanvas()` and `Renderer.fromText()` delegate to `image_cache.get_or_create()` — cache keys are content-addressed.
- **Preloading**: Static icons are preloaded eagerly at `Deck.new()` (root menu) and `Deck:push()` (submenus) via `preloadButtons()`. Dynamic buttons (`imageProvider`) are skipped.
- **Volatile images**: Dynamic buttons that produce unique content each update should pass `volatile = true` to `Renderer.fromCanvas/fromText`. This routes them through the volatile cache pool (max 60) with aggressive eviction, preventing IOSurface leaks.
- **Image disposal**: `resolveButtonImage()` nils `_lastImage` before replacement to allow GC. `Deck:cleanup()` clears all hardware buttons to black and nils all cached images.
- Timer references from `hs.timer.doAfter` must be saved to globals (not locals) to prevent GC before firing.
- Load the spoon deferred (`hs.timer.doAfter(0.1, ...)`) to avoid blocking Hammerspoon startup. Save the timer to a global variable.
- Lock watcher and auto-off timer are only started once (guarded by running-state check).
- Auto-off timer guards against nil device with pcall.

## Config File Pattern

User configuration goes in a separate file (e.g., `dmg_streamdeck.lua`), following the same pattern as `dmg-grid.lua` for hs_grid_hammer:
- Load spoon: `local sd = hs.loadSpoon("hs_streamdeck")`
- Define helper factories and menus
- Register menus: `sd:setMenu(serial_or_size, buttons)`
- Start: `sd:start()`
