# Clean a Business — Technical Specification

Reference doc for AI agents working on the codebase. Concise and technical.
Split into **what exists today** and **the design vision** it's building toward.

## Overview

Simulator-style Roblox game. Players clean businesses with tools (broom, pressure
washer) and continuously unlock more content — tools, businesses, upgrades, plot
expansions — as they progress.

- **6 players per server** (target), each with their own **plot** (a personal
  home/spawn base, assigned on join). Set by `CleaningConfig.PlotCount`.
- Businesses are **shared buildings** in the world, not owned. Players take **jobs**
  from a job board: accepting a job teleports them to that business and lets them
  clean it. Cleaning is **per-session** — nothing about cleaned state is saved.
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
timing and completion**. The gate on every clean is the player's **active job** —
`JobService.getActiveJob(player)` must equal the `businessId` of the surface/stain they
report, so a player can only ever clean the one business they've accepted. Concretely:
- The broom's **UseTime timer runs on the server** (`DecalCleaningService`), not the
  client. The client only sends "I clicked this stain" and animates a progress bar; it
  cannot shortcut the timer or assert completion. The server also checks active job,
  hierarchy, broom-equipped, one-clean-at-a-time, and a per-session **already-cleaned
  set** so a stain can't pay out twice for the same player.
- Stains are **shared server instances**, so the server does **not** destroy a cleaned
  stain (that would remove it for everyone). It rewards the player and tells **their**
  client (`DecalCleaned` remote) to destroy the model locally; other players still see
  and can clean it independently.
- **The one exception is the wall EditableImage pixel-erasing**, which is inherently
  client-side (the overlay is built and erased entirely on the client and never
  replicated — see Replication model). Walls grant only the per-second **wash reward**
  (`CleanProgress`), which the server re-validates against the active job and throttles
  per a cooldown — so it can't be farmed off a job the player doesn't hold.
- **Completion is server-authoritative.** The player's `JobServer` counts the building's
  cleanables and only counts cleans the cleaning services have already validated (deduped),
  so the job completes — and pays its `BaseReward` (Cash) + `XpReward` (XP) bonus — exactly
  once, when every wall and stain is genuinely done.
- **Finishing early is a deliberate client/server hybrid.** The prorated finish-early payout
  needs the *partial* completion %, but wall pixel-erasing is client-only (unverifiable), so
  walls are **client-reported**: the client pushes its wall completion (`WallCompletion`
  remote, ~1/s while changing, plus a fresh value with `FinishEarly`) and the server trusts
  it, clamped to `[server-verified full walls, totalWalls]`. Stains stay server-authoritative
  (`cleanedDecalCount`). So finish-early reward = `(reportedWalls + cleanedStains) / total ×
  bonus`, and it does **not** count as a completion. This is intentionally exploitable on the
  wall fraction — accepted so the payout can track the live % shown to the player. **Full**
  completion is unaffected: it still gates on the authoritative deduped counts only.
- **Nothing about cleaning is saved.** Jobs are per-session; the only persisted business
  data is the `Unlocked` flag (gates accepting a job) and the lifetime `Completions` tally
  (drives **job mastery** — see below).

### Surfaces
- A cleanable surface is any `BasePart` placed in a business's `CleanableWalls`
  folder, at this exact hierarchy:
  `Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableWalls.<part>`.
  - `businessId` is the **business folder's name** (e.g. `"mcDonalds"`).
  - `surfaceId` is the **wall part's name** (e.g. `"CleanableWall1"`), unique within
    the business.
  - `SurfaceResolver` (SharedModules) walks this hierarchy to derive the identity;
    no tags or attributes are needed. Anything outside this exact structure is ignored.
- The surface's part shows its normal "clean" look. A **dirt overlay** is layered on the
  face of the part's own **`Texture`** (whichever side the map author textured; falls back to
  the **Left** face if the part has no Texture) as a `Decal` whose `TextureContent` references a
  client-built `EditableImage`. Cleaning erases overlay pixels to reveal the part. The face's
  (u,v) pixel mapping and the brush-radius scaling both follow that same face choice.
- Businesses are authored **in the Studio place**, not in code (Workspace isn't
  Rojo-mounted) — a single shared `Workspace.Businesses` folder holds one building per
  `businessId`. The buildings are **shared by everyone**; the overlays layered on their
  walls are per-client.

### Plots & the job board
- **Plots** are the player's home base only. Each plot is a Folder (`Plot1..PlotN`) under
  the `Plots` folder in Workspace, with a `spawnPart`. `PlotService` (server) assigns each joining player a free plot,
  publishes its name via the `Plot` player attribute, spawns the character on the
  `spawnPart` (on assignment and **every** respawn), and frees it on leave. Plots no
  longer hold businesses.
- **Jobs** are how cleaning happens, modelled as a class on each side — one instance per
  active job. The job board UI (`JobUiController`) fires the `AcceptJob` remote with a
  `businessId`:
  - `JobService` (server manager) checks the player has `Unlocked` that business **and meets
    its `RequiredLevel`** (`BusinessConfig.RequiredLevel`, default 1), ends any job they're
    already on, creates a fresh **`JobServer`**, publishes the `businessId` on the
    **`ActiveJob`** player attribute, and teleports the character onto the building's
    **`TeleportPart`**. One job at a time. Exposes `getActiveJob`/`getJob` for the cleaning
    services to authorize + report cleans. The level gate is enforced here (server authority),
    not just by the hidden client button.
  - **`JobServer`** (class) is the authority on progress: it counts the business's
    cleanables from the shared building, records validated cleans (`markWallCleaned` /
    `markDecalCleaned`, deduped), and exposes `getCompletion`/`isComplete`. When every wall
    and stain is done it tallies a `Completions` and pays the `BaseReward` (Cash) + `XpReward`
    (XP) **completion bonus**, then calls back to `JobService` to end the job (clearing
    `ActiveJob`, which ends the state on the client). `finishEarly` instead pays a **prorated**
    share of that bonus for the fraction cleaned and ends the job **without** counting a
    completion — its wall fraction comes from `reportWallProgress` (client-reported, clamped),
    its stain count from the authoritative server total (see the hybrid note above).
  - **Job mastery boost.** Both payouts scale their **XP** by the business's mastery
    multiplier (`Mastery.xpMultiplier`), read from the lifetime `Completions` **before** this
    run is tallied — so crossing a milestone rewards the *next* job, matching the boost the
    board already showed. Cash is unaffected. See *Job mastery* below.
  - **`JobClient`** (class), spun up by `JobController` when `ActiveJob` is set, builds the
    per-client wall **EditableImage overlays** (via the `SurfaceManager` engine) and tracks
    local completion for the UI. Completion is **smooth** — it sums each wall's live erased
    fraction (`SurfaceManager.getCleanedWallAmount`), so the bar moves mid-wall — and is
    pushed to listeners via `JobController.onProgressChanged` on every stroke.
  - **`JobCompletionController`** (client) drives the completion HUD
    (`ScreenGui.JobCompletion`): a progress bar + `PercentageLabel` that fill from
    `JobClient`'s live completion, a `CurrentReward` label showing the Cash you'd bank by
    finishing now (`BaseReward × completion`, floored to match the server payout), and a
    **FinishEarly** button (mirrored by the **H** key) that fires the `FinishEarly` remote.
    Shown only while a job is active (off `ActiveJob`) — the counterpart to the board, which
    hides during a job.
  - **Stain visibility** is owned by **`DecalVisibility`** (client), driven by
    `JobController` off the same `ActiveJob` attribute. Stains are shared server instances,
    so this **hides every stain by default** (reparented off-world) and shows a business's
    stains **only while it's the active job** — a player never sees another business's (or
    an un-accepted business's) stains.
- **Completion ends the job; re-accepting reloads it (redo).** Because nothing is saved,
  accepting the same business again creates a brand-new `JobServer` (progress reset) and a
  new `JobClient` that rebuilds the overlays, and `DecalVisibility` **un-hides** every stain
  (including ones cleaned last run) — a fresh clean.
- The shared buildings and their `Cleanables` (`CleanableWalls` + `CleanableDecals`) are
  authored in the Workspace and already replicated, so accepting a job spawns nothing
  server-side. The only per-job "loading" is the client's overlays + stain restore.

### Business unlocking (implemented)
Businesses live in the **`BusinessConfig`** catalog and are **unlocked per player**, resolved
server-side by **`BusinessService`**:
- Every business starts **locked** (`DataTemplate.BusinessList` seeds all with `Unlocked =
  false`). DataService reconcile only fills template-defined keys, so the template lists **one
  entry per catalog business** to keep them all present on every profile.
- On join (after `waitForData`), `BusinessService.resolve()` seeds any still-missing catalog
  business into the profile (locked) and then **grants** any whose requirements are met.
  **Requirements today = `RequiredLevel`** (`meetsRequirements`), the single spot to extend for
  future gates (e.g. an owned tool). Resolution is **one-way — it only ever unlocks, never
  revokes** — so a business stays unlocked forever once earned.
- Resolution **re-runs on every `Level` change**, so reaching a business's `RequiredLevel`
  unlocks it live; the client board refreshes off the `BusinessList` changed signal.
- The job board row (`JobUiController`) shows the **`WashButton`** only when the business is
  `Unlocked` **and** the player meets `RequiredLevel`, otherwise the **`LockedButton`**. Its
  **`Requirements`** label reads `REQUIRED: Level N` and turns **green** once the level is met
  (red-orange while short).

### Job mastery (implemented)
Per-business progression driven off the lifetime `Completions`, shared by client + server via
the **`Mastery`** module so payout and display can't drift:
- **Stars (0→5).** One star per milestone. Tier N asks for `STEP × N` completions **within its
  tier** (`STEP = 5`), so the cumulative thresholds are **5, 15, 30, 50, 75**. The board shows
  progress relative to the current tier (it "resets" to `(0/req)` after each star); the real
  `Completions` count never resets.
- **XP boost (linear).** Each star adds a flat 5% of the base to the completion's XP:
  multiplier `1 + BOOST*stars` (`BOOST = 0.05`) → +5%, +10%, +15%, +20%, +25%. Applied to full
  completions **and** finish-early payouts (see `JobServer`). Cash is never boosted.
- **Board display** (`JobUiController` per row): `StarAmount` = one ⭐ per star; the `Rewards`
  line's XP figure is rewritten to the boosted value; `MasteryRequirements` shows the next
  star's completion goal, tier progress, and the **total** boost that star grants (cumulative,
  e.g. the 2nd star reads `+10%`): `Achieve 100% N times to Unlock: +X% EXP (progress/N)`, and
  hides once all 5 stars are earned.

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
- **Completion:** when erased fraction ≥ the surface's threshold, it marks itself cleaned,
  destroys the decal, and fires its `onCleaned` callback. The threshold defaults to
  `CompletionThreshold` (0.975) but a wall can override it with a numeric **`Percentage`**
  attribute (a 0–1 fraction like `0.9`, or a 0–100 percentage like `90`; values > 1 are read as
  a percentage) — resolved per-surface at construct time. It also fires `onProgress` on any
  stroke that erased pixels, so the completion bar tracks the wash live rather than only stepping
  when a whole wall finishes.
- **`setGlow(enabled)`** toggles the reveal glow **on the wall's own dirt decal** (no second
  decal — two coplanar decals z-fought and rendered unreliably). On enable it recolors the
  still-dirty pixels toward neon yellow into a `glowBuffer` (the real dirt in `self.pixels` is
  left untouched) and uploads that; `stamp` zeros its alpha in step with the dirt so the glow
  shrinks with the wash at no extra per-stroke cost. On disable, on wall completion, and in
  `destroy` the plain dirt is re-uploaded and the buffer dropped (see *Reveal remaining
  cleanables*).

### `PressureWasherController` (client)
- Detects the tool via the `ToolId` attribute and binds its `Equipped` / `Activated`
  (hold to fire) / `Deactivated` / `Unequipped` events. **No ammo** — firing is
  unrestricted while held.
- **Mobile (touch-only devices):** holding to fire while dragging to look is impossible, so
  on mobile the washer fires **continuously the whole time it's equipped** (`Activated` /
  `Deactivated` are ignored; only `Unequipped` stops it). Desktop and console (gamepad) keep
  the normal hold-to-fire. `IS_MOBILE` = `TouchEnabled and not Keyboard/Mouse/Gamepad`.
- Each `Heartbeat` while firing: raycasts and, if it hits a cleanable part **on its overlay
  face** (the hit normal must match the surface's own face within `> 0.99`), tells that surface
  to clean. The ray also **ignores each business's `Interior` and `CleanableDecals` folders** (so
  props/windows and stain hitboxes in front of a wall don't block the wash). Tracks the last hit
  so consecutive frames bridge into one stroke. The aim point is the **mouse** on desktop
  but the **center of the screen** (`ViewportSize/2`, the crosshair) on mobile — since the
  mobile washer fires from the crosshair, not from wherever the player last tapped.

### `SurfaceManager` (client) — wall-overlay engine
- A driven engine, not a decision-maker: `JobClient` calls `buildWalls(wallsFolder,
  onCleaned, onProgress?)` to start tracking the current job's walls and `clear()` to tear
  them down. It builds/destroys one `CleanableSurface` per wall (handling walls that
  stream/replicate in via `ChildAdded`).
- **Budgeted building:** walls are queued (after a cheap resolve check) and a long-lived
  drainer builds them under a per-frame time budget (`FRAME_BUDGET`, ~2ms), so a job with
  many walls never stalls a frame. `removeSurface`/`clear` cancel still-queued walls.
- Exposes `getSurface(part)` for `PressureWasherController` and `getCleanedWallAmount()`
  (summed live wall fractions, in whole-wall units) for the completion bar. On completion it
  plays the pop VFX + sound and invokes the `onCleaned` callback (which `JobClient` uses to
  fire `WallCleaned`); every dirt-removing stroke invokes `onProgress`, which drives the bar.
- `setWallsGlow(enabled)` fans the reveal glow out to every built wall (calls each surface's
  `setGlow`), used by `MissingHighlightController` (see *Reveal remaining cleanables*). The flip
  is **budgeted across frames** by a `processGlow` drainer (like the build queue) — toggling the
  glow is a full-image recolor + upload per wall, so applying it to a whole job at once hitched;
  now a few walls flip per frame (`GLOW_FRAME_BUDGET`) in a fast wave.

### Persistence
**Cleaning is not persisted.** Jobs are per-session: accepting a job is always a fresh
clean, and nothing about cleaned walls/stains is written to DataService. The business data
saved per player is the **`Unlocked`** flag (gates accepting a job, resolved by
`BusinessService`) and the lifetime **`Completions`** tally (drives job mastery).

### `CleaningConfig` (shared)
Single source of truth for cleaning tunables, consumed by client and server:
the folder names `BusinessesFolderName`/`CleanablesFolderName`/`WallsFolderName`/
`DecalsFolderName`/`InteriorFolderName` (props/windows the cleaning ray ignores),
`HitboxName`/`SurfaceIdAttribute`, `PlotCount`/`PlotAttribute`/
`PlotSpawnPartName`, `ActiveJobAttribute`, `TeleportPartName`/`TeleportOffset`,
`DirtAsset`, `ImageSize`, `BrushWorldRadius`, `MaxBridgeWorldDistance`,
`CompletionThreshold`, brown fallback, and `FlipU`/`FlipV` (flip if the cleaned spot
appears mirrored from where you aim).

### Stain cleaning (broom, implemented)
- A cleanable **stain** is a `Model` in a business's `CleanableDecals` folder, at:
  `Workspace.<BusinessesFolderName>.<businessId>.Cleanables.CleanableDecals.<model>`.
  - The model has a child `BasePart` named **`Hitbox`** (what the player clicks) and a
    **`surfaceId`** attribute whose value is the stain's id (unique within the business).
  - `DecalResolver` (SharedModules) walks this hierarchy + reads the attribute to derive
    `{ businessId, surfaceId, model }`; anything else is ignored.
- **Flow:** `BroomController` (client) raycasts on click, and on a valid Hitbox (for the
  business whose job it holds) fires `CleanDecal` and shows a cosmetic billboard progress
  bar. `DecalCleaningService` (server) validates (active job / equipped / one-at-a-time /
  not-already-cleaned-on-this-job), then **runs the UseTime timer itself**, re-validates,
  rewards the player, records the stain in the player's **`JobServer`** (which may complete
  the job), and fires `DecalCleaned` back to **that** client. The stain model is **shared
  and left intact server-side**; the cleaning player's client **hides** its copy via
  `DecalVisibility` (which already keeps stains hidden unless you're on the job), and
  re-accepting restores it for the redo. **UseTime** comes from the broom Item in
  `ToolConfig`; both sides read the same source so the bar mirrors the server timer.
- **Cleaned-stain tracking lives in the `JobServer`**, so it resets on each accept — the
  player can redo the job and earn the rewards again.

### Reveal remaining cleanables (implemented)
A client-only assist that flashes a neon-yellow glow over everything the player still has left
to clean on their active job. **Purely cosmetic** — it reads existing client state and touches
no server state or remotes.
- **Trigger:** the **R** key **or** the on-screen **`ScreenGui.HighlightButton`** (an
  `ImageButton`), both routed through `MissingHighlightController`. The button is shown **only
  while a job is active** (off `ActiveJob`, like the rest of the HUD) and re-binds on each
  respawn.
- **Walls glow per-pixel.** `SurfaceManager.setWallsGlow(true)` calls `CleanableSurface.setGlow`
  on every built wall. `setGlow` recolors the still-dirty pixels of the wall's **own dirt image**
  toward neon yellow (blend `0.85`) and uploads that to the existing dirt decal — **no second
  decal**, so nothing z-fights (two coplanar decals used to render unreliably: some walls showed
  no glow, others lit up whole). The real dirt (`self.pixels`) is untouched; the recolored
  `glowBuffer` has its alpha erased in lockstep with the dirt inside `stamp`, so the glow
  **shrinks live as the player cleans**, and disabling it (or finishing the wall) re-uploads the
  plain dirt. Only the not-yet-cleaned pixels light up.
- **Stains glow whole.** Stains have no partial state, so `MissingHighlightController` switches
  each visible stain part (from `DecalVisibility.getActiveVisibleStains`, skipping the invisible
  `Hitbox`) to `Material = Neon`, neon yellow, **0.55 transparency**, snapshotting and restoring
  each part's original material/color/transparency exactly.
- **Duration + cooldown.** The glow lingers `REVEAL_DURATION` (**8s**) then clears itself (a
  `revealToken` disarms superseded expiry timers). Re-triggering is gated by the **same
  duration** — a new reveal is ignored until the current one runs out — since each reveal
  rebuilds every wall's glow overlay (new `EditableImage`s) and spamming it would churn them and
  hitch the game. The cooldown resets on job change so a fresh job is immediately ready. Ending
  or switching a job drops the glow.

### Tool
- The **Pressure Washer** and **Broom** `Tool`s live in **`ReplicatedStorage.Items`**
  (authored in Studio; `StarterPack` is empty). Each has a `Handle` and a `ToolId`
  attribute (`"pressureWasher"` / `"startingBroom"`) that ties it to its inventory Item
  (`UniqueID`) and is used to bind its controller.
- **`ToolService`** (server) grants tools: on each spawn it clones every owned + `Unlocked`
  inventory item's `Tool` into the player's Backpack (matched by `ToolId`), idempotently,
  and re-grants when the inventory gains a new item.
- **`InventoryController`** (client) is the custom hotbar, replacing Roblox's default
  Backpack UI (which it disables via `SetCoreGuiEnabled`). The HUD `ScreenGui.Inventory`
  frame holds `ImageButton1..5`; a button is shown only if the player owns an item whose
  `SlotNumber` matches it. Clicking a button — or pressing that number key — equips that
  slot's Tool with `Humanoid:EquipTool`. It only ever equips (never `UnequipTools`), so a
  slot press **never unequips**: the already-equipped slot is a no-op.
- **Tied to the job lifecycle** (off the `ActiveJob` attribute, like the rest of the HUD):
  the inventory is **hidden unless the player holds a job**. On job **start** the frame
  appears and **slot 1 is auto-equipped**; on job **end** the frame hides and any held tool
  is unequipped (`Humanoid:UnequipTools`). Re-binds to the fresh `Inventory` frame on each
  respawn, like the other HUD controllers.

## Implemented files

```
ReplicatedStorage/SharedModules/
  DataTemplate.luau     saved-data shape + defaults
  ToolConfig.luau       tool definitions catalog
  BusinessConfig.luau   business definitions catalog (BaseReward/XpReward/RequiredLevel/DecalWeight)
  CleaningConfig.luau   cleaning tunables (shared by client + server)
  Mastery.luau          job-mastery rules: stars from Completions, linear +5%/star XP multiplier
  NumberFormat.luau     number -> display string (abbreviate "2.5k"; commas "2,500")
  SurfaceResolver.luau  wall part -> identity (walls)
  DecalResolver.luau    stain Hitbox/model -> identity (broom stains)
  UiAnimations.luau     shared GUI motion: Panel open/close, DropIn, hover grow (hoverGrow; hoverGrowInGrid pushes grid neighbours + left-edge padding; hoverGrowCluster wires a whole cluster frame; spreadStackOnHover pushes a stack of frames apart around the hovered one)
ReplicatedStorage/Remotes/
  AcceptJob             RemoteEvent (client → server: accept a job for a businessId)
  FinishEarly           RemoteEvent (client → server: end the active job now for a prorated reward; carries wall %)
  WallCompletion        RemoteEvent (client → server: live wall completion, ~1/s; trusted for finish-early reward)
  CleanProgress         RemoteEvent (client → server: actively washing a wall; wash reward)
  WallCleaned           RemoteEvent (client → server: a wall is fully erased; job progress)
  CleanDecal            RemoteEvent (client → server: stain-click intent)
  DecalCleaned          RemoteEvent (server → client: hide your local copy of a cleaned stain)
  RewardPopup           RemoteEvent (server → client: show floating +XP/+Cash)

ServerScriptService/
  Main.server.luau      inits DataService (useMock) + Plot/Business/Job/Cleaning/DecalCleaning/Tool services
  Modules/BusinessService.luau       seeds the catalog into each profile + resolves unlocks (level now, permanent, re-runs on level change)
  Modules/JobService.luau            job board manager: owns per-player JobServer, AcceptJob/FinishEarly, teleport, endJob; gates accept on Unlocked + RequiredLevel
  Modules/JobServer.luau             one active job (class): counts cleanables, tracks progress, completion + finish-early reward (XP scaled by mastery)
  Modules/CleaningService.luau       wall wash reward + WallCleaned→job, gated by active job (no saving)
  Modules/DecalCleaningService.luau  server-authoritative broom timer; reports to job; per-client hide via DecalCleaned
  Modules/PlotService.luau           plot (home base) assignment + spawn
  Modules/ProgressionService.luau    awards Cash/XP + reward popups
  Modules/ToolService.luau           grants owned+Unlocked items as Backpack Tools (clones from ReplicatedStorage.Items by ToolId), per spawn + on inventory change
  Modules/InventoryManager.luau      present but NOT yet wired into Main

StarterPlayer/StarterPlayerScripts/
  Main.client.luau                 inits DataService client + SurfaceManager + JobController + PressureWasher/Broom + UI + MissingHighlight + UiPreloader
  Modules/JobController.luau       watches ActiveJob, owns the JobClient, routes DecalCleaned→hide, onProgressChanged signal
  Modules/JobClient.luau           one active job (class): loads overlays, restores stains, smooth local completion %
  Modules/CashUiController.luau    cash HUD: writes Cash into CashDisplay.MoneyAmt as a "$"-prefixed abbreviated number (e.g. "$1.1k"), re-renders on Cash change
  Modules/JobUiController.luau     job board UI: toggle (Buttons.JobButton/B key), per-business rows, AcceptJob; gates Wash/Locked on Unlocked + RequiredLevel (green Requirements when met); draws mastery stars/boost + boosted Rewards; hides the whole Buttons frame while on a job; wires the Buttons-frame hover polish
  Modules/UiSoundController.luau   plays shared UI SFX: click on every GuiButton, hover on buttons under the Buttons frame
  Modules/JobCompletionController.luau  completion HUD: live progress bar + %, FinishEarly button/H key
  Modules/SurfaceManager.luau      wall-overlay engine, driven by JobClient (buildWalls/clear)
  Modules/DecalVisibility.luau     stain visibility: hidden unless on the job; per-client clean + redo
  Modules/CleanableSurface.luau    dirt-overlay OOP class
  Modules/PressureWasherController.luau   tool input + raycast + cleaning
  Modules/BroomController.luau     broom input + raycast + cosmetic bar (clicks gated to the active job)
  Modules/InventoryController.luau custom hotbar: shows ImageButton{N} per owned SlotNumber, equips on click/number key (never unequips), disables default Backpack CoreGui
  Modules/MissingHighlightController.luau  reveal remaining cleanables: R key / ScreenGui.HighlightButton -> neon-yellow glow (walls per-pixel via setGlow, stains via Neon parts), 8s + cooldown
  Modules/UiPreloader.luau         warms StarterGui image assets in the background so HUD doesn't first render blurry
```

Studio-authored (not Rojo): `ReplicatedStorage.Items.Pressure Washer` /
`ReplicatedStorage.Items.Broom` (each with a `ToolId` attribute; `StarterPack` is empty),
and the shared `Workspace.Businesses` buildings — each with a `TeleportPart` and a
`Cleanables` folder (`CleanableWalls` + `CleanableDecals`) authored right in the building.
The **HUD `ScreenGui`** is also Studio-authored (not Rojo): a `Buttons` frame holding the
main HUD buttons (`JobButton` opens the board; `UpgradesButton` is a placeholder, no click
wired yet), laid out side by side by a `UIGridLayout`; plus `JobFrame` (board),
`JobCompletion` (progress bar + `FinishEarly`), `XpBar`, `CashDisplay` (the `MoneyAmt`
label showing the player's live Cash), `Inventory` (the custom hotbar:
`ImageButton1..5`), and `HighlightButton` (an `ImageButton` that triggers the reveal glow,
shown only during a job). The client controllers bind to these instances by name and re-bind
on each respawn (the `ScreenGui` is re-cloned).

Every button in the HUD cluster frames (`Button1` + `Buttons2`) shares the same polish, wired
in `JobUiController.bind` via `UiAnimations.hoverGrowCluster` per frame: a center hover-grow
(`UiAnimations.hoverGrowInGrid`) that, because a `UIGridLayout` can't reflow on its own, also
widens the grid's `CellPadding` by exactly how far the grown edge reaches so the row-neighbour
is pushed aside and the gap stays constant; the left-edge button additionally tweens the frame's
`UIPadding.PaddingLeft` so it grows *into* that new room rather than off the screen edge. The
stacked clusters (`Button1` / `Buttons2` / `Buttons3`) open up via `UiAnimations.spreadStackOnHover`:
hovering a button in one pushes the others away from it -- clusters above slide up, those below
slide down, the hovered one holds -- so they don't crowd. Click/hover SFX come from `UiSoundController` (click on any
`GuiButton`, hover on anything under a cluster frame). `JobUiController` hides the whole
`Button1` frame — not just `JobButton` — while a job is active, so no HUD buttons show mid-job. `UiPreloader` warms these assets' images up
front (via `ContentProvider:PreloadAsync` on the `StarterGui` templates, in a background task)
so they don't first render blurry.

## Not yet implemented / planned

- **Progression** — **business unlocking by Level is now implemented** (`BusinessService`,
  permanent once earned via `RequiredLevel`); still planned are **Cash-priced** business
  unlocks, **tool** unlock requirements (the next `meetsRequirements` gate), and **plot
  growth**. Rewards are wired: per-clean Cash/XP, a completion bonus (`BaseReward` +
  `XpReward`, XP boosted by job mastery), and a prorated finish-early payout.
  `InventoryManager` exists but isn't initialized or used yet.
- **StreamingEnabled** handling — the tag-added signal already builds surfaces on
  stream-in and applies saved state correctly, but the broader streaming model below is
  a target, not a guarantee.

---

# Design Vision & Principles

Forward-looking guidance. Still authoritative for *how* new systems should be built,
even where the feature itself isn't implemented yet.

## Gameplay loop (target)

1. Player spawns on their own plot (home base) with starting tools.
2. Player accepts a job from the job board → teleported to that shared business.
3. On job start the hotbar appears with slot 1 auto-equipped; the player swaps tools
   (button / number key) and cleans the business's surfaces / stains, earning Cash + XP
   per clean (per-session — nothing is saved). The hotbar hides again when the job ends.
4. Player reaches Levels to **unlock** more businesses (implemented, permanent — via each
   business's `RequiredLevel`), and spends Cash to unlock tools/upgrades (planned), which
   makes their jobs available on the board.
5. Repeat against a steadily expanding catalog of businesses and tools.

## Replication model (target)

- **Pixel erasing stays client-only, visual, never saved or replicated.**
- Cleaning is **per-session**: leaving (or switching jobs) loses all cleaning progress.
  Nothing about cleaned walls/stains is saved — only the business `Unlocked` flag is.

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
  `BaseReward`, `XpReward`, `Unlocked`, `Name`, `UniqueID`, `Completions`, and optional
  catalog-only `DecalWeight?` / `RequiredLevel?`. **`Unlocked`** gates whether the player may
  accept that business's job (resolved per player by `BusinessService`); **`RequiredLevel`**
  (catalog, `BusinessConfig`) is the level needed to unlock/accept it; `Completions` is a
  lifetime tally bumped on each full completion, which also drives **job mastery** (stars + a
  linear XP boost, +5% of base per star). Per-clean *surface* state is **not** stored (jobs are per-session).
- `Inventory: { [string]: Item }` keyed by `UniqueID`. Each `Item`: `Name`, `Equipped`,
  `Unlocked`, `Cost`, `UniqueID`, and optional `Range?` (max cleaning distance, studs),
  `Power?`, `UseTime?` (broom seconds-per-stain), `Radius?` (washer brush radius), and
  `SlotNumber?`. **`SlotNumber`** places the item in the custom hotbar: it maps to
  `Inventory.ImageButton{N}` and the matching number key (see `InventoryController`).
  **`Power`** is a tool tier that will gate **which floor/surface types a tool can clean**
  (a tool cleans a surface only if its `Power` ≥ the surface's required power) — defined in
  `ToolConfig` now, not yet enforced in cleaning logic.

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
  `nil`. (`SurfaceManager`'s `ChildAdded` watch + budgeted queue already cover stream-in.)
- A player only cleans the **shared business of their active job**, which they were just
  teleported into, so it's reliably streamed in.

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
- **Workspace, ReplicatedStorage.Items, and StarterGui are not Rojo-mounted** — physical
  instances (cleanable parts, the `Tool`s, the HUD `ScreenGui`) are authored directly in the
  Studio place. `StarterPack` is empty; tools are granted from `ReplicatedStorage.Items` by
  `ToolService`.
- Client/server boundaries communicate via `ReplicatedStorage/Remotes`; all state
  mutation requests are server-validated.
