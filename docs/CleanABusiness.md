# Clean a Business — Technical Specification

Reference doc for AI agents working on the codebase. Concise and technical.
Split into **what exists today** and **the design vision** it's building toward.

## Overview

Simulator-style Roblox game. Players clean businesses with tools (broom, pressure
washer) and continuously unlock more content — tools, businesses, upgrades, plot
expansions — as they progress.

- **8 players per server** (target), each with their own plot.
- Each plot **grows** as the owner completes more businesses.
- Players clean **only their own plot**.
- Server is authoritative; clients read replicated data and send validated requests.

**Design imperative:** the set of unlockables (tools, businesses, upgrades) grows
indefinitely over the game's life. Every system must be data-driven and additive —
adding a new tool/business/unlockable should require new data + config, not rewrites.

---

# Current Implementation

What is actually built and running right now. The only complete gameplay system is
the **pressure washer cleaning loop**.

## Cleaning system (implemented)

### Verification policy (server-authoritative)
**No gameplay verification happens on the client.** Clients send *intent* (a click, a
target) and show *cosmetic* feedback; the **server validates everything and owns all
timing and completion**. Concretely:
- The broom's **UseTime timer runs on the server** (`DecalCleaningService`), not the
  client. The client only sends "I clicked this stain" and animates a progress bar; it
  cannot shortcut the timer or assert completion. The server also checks ownership,
  plot, hierarchy, broom-equipped, and one-clean-at-a-time.
- **The one exception is the wall EditableImage pixel-erasing**, which is inherently
  client-side (the overlay is built and erased entirely on the client and never
  replicated — see Replication model). Because of that, completion of a *wall* is still
  client-asserted; the server validates everything it *can* (resolve, plot, ownership)
  and guards the saved flag (below), but it cannot witness the pixels.
- **Cleaned state is MONOTONIC.** The saved completion boolean
  (`CleanedParts[id]` / `CleanedStains[id]`) can only ever be driven to `true` by the
  server, and once `true` the server ignores further reports for that id. A client can
  **never** set a surface/stain back to `false` (un-clean) by replaying, forging, or
  spamming a remote — the server intervenes and refuses any non-`true` transition.

### Surfaces
- A cleanable surface is any `BasePart` placed in a business's `CleanableWalls`
  folder, at this exact hierarchy:
  `Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableWalls.<part>`.
  - `businessId` is the **business folder's name** (e.g. `"mcDonalds"`).
  - `surfaceId` is the **wall part's name** (e.g. `"CleanableWall1"`), unique within
    the business.
  - `SurfaceResolver` (SharedModules) walks this hierarchy to derive the identity;
    no tags or attributes are needed. Anything outside this exact structure is ignored.
- The surface's part shows its normal "clean" look. A **dirt overlay** is layered on
  the part's **LEFT face only** as a `Decal` whose `TextureContent` references a
  client-built `EditableImage`. Cleaning erases overlay pixels to reveal the part.
- Surfaces are authored **in the Studio place**, not in code (Workspace isn't
  Rojo-mounted). The workspace holds 8 plots (`Plot1`..`Plot8`); each joining player
  is assigned one by `PlotService` and may only clean the walls within it.

### Plots & business spawning
- Each plot is a Folder under Workspace holding two Folders — `Businesses` (empty at
  start) and `BusinessSpawns` (invisible parts named `<businessId>Spawn` marking
  where each business sits) — plus a `spawnPart` the owner spawns on.
- `PlotService` (server) assigns each joining player a free plot, publishes its name
  via the `Plot` player attribute, teleports the player's character onto the plot's
  `spawnPart` (on assignment and every respawn), and frees it on leave.
- `BusinessSpawner` (server) then reads the player's owned businesses (entries in
  `BusinessList` with `Unlocked == true`) and, for each, clones the template Model
  from `ReplicatedStorage.Businesses.<businessId>` into the plot's `Businesses` folder
  and translates it so the template's `BasePart` lands on the matching
  `<businessId>Spawn` part (orientation kept as authored).
- The client's `SurfaceManager` watches its plot's `Businesses` folder, so walls in a
  spawned business become cleanable as soon as the Model replicates in.

### `CleanableSurface` (client OOP class)
One instance per cleanable part. Owns the dirt overlay and the erase logic.
- **Shared dirt template:** the initial dirt image is identical for every surface, so
  it's drawn + read back + pixel-counted **exactly once** (`getTemplate`, lazily on the
  first surface; the dirt asset downloads on that call). Each surface then just
  **`buffer.copy`s** that template into its own working buffer and does **one**
  `WritePixelsBuffer` to seed its `EditableImage`. No per-surface `DrawImage`,
  `ReadPixelsBuffer`, or counting loop.
- **Performance contract (the whole reason past attempts went choppy):** the pixels
  live in **one persistent `buffer`** per surface. Erasing mutates that buffer **in
  place** and does a **single `WritePixelsBuffer` per frame**. There is **zero
  per-frame heap allocation**, so there's no GC churn that builds up over time —
  cleaning cost is constant, not growing. Do **not** reintroduce per-frame
  `ReadPixelsBuffer`/buffer allocation.
- `clean(worldPos, fromWorldPos?)`: maps the world hit point to a pixel coord on the
  left face, erases a **circular stamp** (a world-space circle → ellipse in pixel
  space on non-square parts), and **interpolates stamps along the segment** from the
  previous point so fast strokes leave no gaps.
- **Completion:** when erased fraction ≥ `CompletionThreshold` (0.95), the surface
  marks itself cleaned, destroys the decal, and fires its `onCleaned` callback.

### `PressureWasherController` (client)
- Detects the tool via the `ToolId` attribute and binds its `Equipped` / `Activated`
  (hold to fire) / `Deactivated` / `Unequipped` events. **No ammo** — firing is
  unrestricted while held.
- Each `Heartbeat` while firing: raycasts from the mouse (`ViewportPointToRay`), and if
  it hits a cleanable part **on its left face** (`Normal·(-RightVector) > 0.99`), tells that
  surface to clean. Tracks the last hit so consecutive frames bridge into one stroke.

### `SurfaceManager` (client)
- Builds/destroys `CleanableSurface` instances for the walls in the local player's plot
  (handles walls/businesses that spawn in later via `ChildAdded`).
- **Budgeted building:** walls are queued (after cheap resolve/already-cleaned checks)
  and a long-lived drainer builds them under a per-frame time budget (`FRAME_BUDGET`,
  ~2ms), so a business spawning a burst of walls never stalls a frame. `removeSurface`
  cancels a still-queued wall.
- On build, checks saved data — if the wall is **already cleaned** in a prior session,
  it **skips the overlay entirely** (part renders bare, no EditableImage created).
- Exposes `getSurface(part)` for the controller, and fires the `CleanSurface` remote on
  completion.

### Persistence (implemented)
- Saved per player at `BusinessList[BusinessId].CleanedParts[SurfaceId] = true`.
- Flow: client completes a surface → fires `CleanSurface` remote → server validates
  (`SurfaceResolver` resolves the wall, the wall is on the player's `PlotService`-assigned
  plot, business exists in the player's data) → `DataService:set(...)`. On rejoin, the
  client reads `CleanedParts` and skips overlays for already-cleaned surfaces.
- **Per-player only.** Each player has their own cleaned state; players do **not** see
  each other's in-progress or completed cleaning yet (see Planned).
- **Monotonic guard:** the server refuses to process a `CleanSurface` report for a wall
  already saved as cleaned, so the flag can only go `false → true`, never back (see
  Verification policy).
- ⚠️ **Known exploit gap (walls only):** because wall pixel-erasing is client-side, *wall*
  completion is still client-asserted — the server validates the part/business/plot and
  guards the saved flag, but can't witness the actual erasing. Fine while nothing is
  rewarded; if walls ever grant Cash/XP, add rate-limit/timing/proximity checks. (The
  **broom is not affected** — its timer and completion are fully server-authoritative.)


### `CleaningConfig` (shared)
Single source of truth for cleaning tunables, consumed by client and server:
`ToolId`, the folder names `BusinessesFolderName`/`CleanablesFolderName`/`WallsFolderName`,
`PlotCount`/`PlotAttribute`, `DirtAsset`, `ImageSize`, `BrushWorldRadius`,
`CompletionThreshold`, `Range`, brown fallback, and `FlipU`/`FlipV` (flip if the
cleaned spot appears mirrored from where you aim).

### Stain cleaning (broom, implemented)
- A cleanable **stain** is a `Model` in a business's `CleanableDecals` folder, at:
  `Workspace.<Plot>.Businesses.<businessId>.Cleanables.CleanableDecals.<model>`.
  - The model has a child `BasePart` named **`Hitbox`** (what the player clicks) and a
    **`surfaceId`** attribute whose value is the stain's id (unique within the business).
  - `DecalResolver` (SharedModules) walks this hierarchy + reads the attribute to derive
    `{ plot, businessId, surfaceId, model }`; anything else is ignored.
- **Flow:** `BroomController` (client) raycasts on click, and on a valid Hitbox fires
  `CleanDecal` and shows a cosmetic billboard progress bar. `DecalCleaningService`
  (server) validates (plot/ownership/equipped/one-at-a-time), then **runs the UseTime
  timer itself**, re-validates, deletes the model, and saves
  `CleanedStains[surfaceId] = true`. **UseTime** comes from the broom Item in
  `ToolConfig` (falls back to `CleaningConfig.BroomUseTime`); both sides read the same
  source so the bar mirrors the server timer.
- **Persistence:** on spawn, `BusinessSpawner` prunes stain models whose `surfaceId` is
  already in the player's `CleanedStains`, so cleaned stains never reappear. (Unlike
  walls, a cleaned stain is fully removed — there is no overlay to skip.)

### Tool
- The **Pressure Washer** and **Broom** `Tool`s live in **`StarterPack`** (authored in
  Studio, so they auto-give to every player). Each has a `Handle` and a `ToolId`
  attribute (`"pressureWasher"` / `"startingBroom"`) used to bind its controller. There
  is no server-side tool-giving code.

## Implemented files

```
ReplicatedStorage/SharedModules/
  DataTemplate.luau     saved-data shape + defaults
  ToolConfig.luau       tool definitions catalog
  BusinessConfig.luau   business definitions catalog
  CleaningConfig.luau   cleaning tunables (shared by client + server)
  SurfaceResolver.luau  wall part -> identity (walls)
  DecalResolver.luau    stain Hitbox/model -> identity (broom stains)
ReplicatedStorage/Remotes/
  CleanSurface          RemoteEvent (client → server wall completion report)
  CleanDecal            RemoteEvent (client → server stain-click intent)

ServerScriptService/
  Main.server.luau      inits DataService (useMock) + CleaningService + DecalCleaningService
  Modules/CleaningService.luau       validates + saves cleaned walls (monotonic guard)
  Modules/DecalCleaningService.luau  server-authoritative broom timer + stain delete/save
  Modules/BusinessSpawner.luau       clones owned businesses; prunes already-cleaned stains
  Modules/PlotService.luau           plot assignment
  Modules/InventoryManager.luau      present but NOT yet wired into Main

StarterPlayer/StarterPlayerScripts/
  Main.client.luau                 inits DataService client + SurfaceManager + PressureWasherController + BroomController
  Modules/SurfaceManager.luau      owns surface lifetime + persistence checks + remote
  Modules/CleanableSurface.luau    dirt-overlay OOP class
  Modules/PressureWasherController.luau   tool input + raycast + cleaning
  Modules/BroomController.luau     broom input + raycast + cosmetic progress bar (no verification)
```

Studio-authored (not Rojo): `StarterPack.Pressure Washer`, `StarterPack.Broom`,
`Workspace` plots (cleanable walls + stains live inside the business templates in
`ReplicatedStorage.Businesses`).

## Not yet implemented / planned

- **Rewards & progression** — completing a business awarding Cash/XP, unlock flow,
  plot growth. `InventoryManager` exists but isn't initialized or used yet.
- **StreamingEnabled** handling — the tag-added signal already builds surfaces on
  stream-in and applies saved state correctly, but the broader streaming model below is
  a target, not a guarantee.

---

# Design Vision & Principles

Forward-looking guidance. Still authoritative for *how* new systems should be built,
even where the feature itself isn't implemented yet.

## Gameplay loop (target)

1. Player spawns on their own plot with a starting business and starting tools.
2. Player equips a tool and cleans surfaces / stains in the active business.
3. Completing a business awards Cash + XP and unlocks new content (next business,
   tools, upgrades, plot expansion).
4. Player spends Cash / reaches Levels to unlock the next tier of content.
5. Repeat against a steadily expanding catalog of businesses and tools.

## Replication model (target)

- **Pixel erasing stays client-only, visual, never saved or replicated.**
- Leaving mid-surface **loses in-progress** erasing (nothing persists until completion).
- Only the **completion boolean** is saved/replicated — never pixel data. 

## Data / Persistence — DataService

The game uses the **DataService** package (`leifstout/dataservice`) for **all player
data**, paired with the `DataTemplate` module which defines the saved-data shape.

**Rules:**
- Route **all player data changes through DataService**; prefer its methods
  (get/set/update, array ops, change signals) over hand-rolled handling.
- Let DataService's **built-in replication** keep clients in sync — no parallel path.
- **Server-authoritative:** clients send validated requests; the server validates
  before writing.

### Saved-data shape (`DataTemplate`)
`src/ReplicatedStorage/SharedModules/DataTemplate.luau`:

- `Cash: number`
- `Level: { CurrentLevel: number, XP: number }` — XP-to-next-level via a formula (TBD).
- `BusinessList: { [string]: Business }` keyed by `UniqueID`. Each `Business`:
  `BaseRate`, `Unlocked`, `Cleaned`, `Name`, `UniqueID`,
  `CleanedParts: {[string]: boolean}?` (per-surface completion for the pressure washer),
  `CleanedStains: {[string]: boolean}?` (per-stain completion for the broom).
- `Inventory: { [string]: Item }` keyed by `UniqueID`. Each `Item`: `Name`, `Equipped`,
  `Unlocked`, `Cost`, `UniqueID`, optional `Range?` (max cleaning distance, studs) and
  optional `Power?`. **`Power`** is a tool tier that will gate **which floor/surface
  types a tool can clean** (a tool cleans a surface only if its `Power` ≥ the surface's
  required power) — defined in `ToolConfig` now, not yet enforced in cleaning logic.
  (The pressure-washer entry still carries vestigial ammo fields from before ammo was
  removed — unused.)

**Why string-id maps, not Instance refs:** saved data is JSON-only (no Instances), and
an Instance is a new object every session anyway. A stable `SurfaceId` string survives
save/load and a `{[id]: true}` map gives O(1) membership, dedupe, and clean per-key
writes via DataService's path API.

## EditableImage constraints

- **Max 1024×1024**, **not resizable** after creation (current overlays are 512×512).
- **One EditableImage update per frame per client** — prefer **fewer/larger** surfaces.
- **Memory-expensive:** only the **active business** should hold live editable images;
  completed/distant businesses should use static textures.

## StreamingEnabled (target)

- Cleaning code **must not assume surfaces are loaded** — wait for instances and handle
  `nil`. (The tag-added signal already covers stream-in.)
- Players clean only their **own nearby plot**, so the active business is reliably
  streamed in.
- **Saved completion data replicates regardless of streaming**, so surfaces render to
  the correct state on load.

## Architecture — entry points & service modules

The entire game runs from **exactly two executing scripts**:

- **One server entry point** — `ServerScriptService/Main.server.luau`.
- **One client entry point** — `StarterPlayerScripts/Main.client.luau`.

**No other Script or LocalScript runs on its own.** Everything else is a ModuleScript.
The two Main scripts do nothing but **require and initialize service modules** in order.

### Service modules
- Treat every system as a **service**: a self-contained module owning one domain
  (e.g. `CleaningService`, `SurfaceManager`, `InventoryManager`, future
  `BusinessManager`, `UnlockManager`).
- Each exposes an **`init` function** that wires it up (connect events, build state,
  cache refs). The relevant Main calls each `init` once, in dependency order. A service
  does nothing until `init` runs.
- Services expose a clear **public API** and keep internals private. Server and client
  services are separate modules; shared logic/types/config live in `SharedModules`.

```
Main.server.luau         requires + init: DataService, CleaningService, (later) InventoryManager, ...
Main.client.luau         requires + init: DataService, SurfaceManager, PressureWasherController, (later) UI, ...
```

### Build reusable systems
A priority, not a nicety — the catalog grows continuously:
- A service handles a **whole category** (all tools, all businesses), data-driven — not
  one hardcoded instance. Adding content = new data + config (+ a behavior handler keyed
  by `UniqueID` if needed), with no new top-level scripts and minimal Main edits.
- Prefer composition and shared helpers over duplication.
- Keep services decoupled: communicate through public APIs / signals, not internals.

## Code standards

- **Typing:** strict Luau (`--!strict`) throughout. (`CleanableSurface` is `--!nonstrict`
  on purpose — the EditableImage/Content APIs aren't fully covered by the type solver.)
- **Structure by shape of data:**
  - **Classes** (OOP, metatables) for many-instance stateful objects (a cleanable
    surface, an equipped tool instance).
  - **Modules/singletons** for systems that exist once (controllers, managers).
  - **Plain typed tables** for pure data (templates, configs).
- **Extensibility:** new content = new data + config + (if needed) a behavior handler
  keyed by `UniqueID`. No core rewrites.
- **Naming:** `PascalCase` for types/classes/modules; `camelCase` for
  variables/functions/params; match existing `DataTemplate` field style.

## Rojo / project structure

Sync map is in `default.project.json`.

```
src/
  ReplicatedStorage/
    SharedModules/   -> ReplicatedStorage.SharedModules   (DataTemplate, configs, shared types)
    Remotes/         -> ReplicatedStorage.Remotes         (RemoteEvents/Functions)
  ServerScriptService/
    Main.server.luau -> ServerScriptService.Main          (server entry point)
    Modules/         -> ServerScriptService.Modules        (server systems)
  StarterPlayer/
    StarterPlayerScripts/      -> client entry point + client modules
    StarterCharacterScripts/   -> per-character client scripts
Packages/            -> ReplicatedStorage.Packages         (Wally deps, incl. DataService)
```

- **Wally** manages dependencies (`wally.toml`); `DataService` lives in `Packages`.
- **All server module scripts live in `ServerScriptService/Modules`**; the only server
  Script outside it is `Main.server.luau`.
- Shared types/configs go in `SharedModules` (one source of truth for client + server).
- **Workspace and StarterPack are not Rojo-mounted** — physical instances (cleanable
  parts, the tool) are authored directly in the Studio place.
- Client/server boundaries communicate via `ReplicatedStorage/Remotes`; all state
  mutation requests are server-validated.
