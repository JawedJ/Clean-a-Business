# Clean a Business — Technical Specification

Reference doc for AI agents writing the codebase. Concise and technical.

## Overview

Simulator-style Roblox game. Players clean businesses with tools (broom, pressure
washer) and continuously unlock more content — tools, businesses, upgrades, plot
expansions — as they progress.

- **8 players per server**, each with their own plot.
- Each plot **grows** as the owner completes more businesses.
- Players clean **only their own plot**.
- Server is authoritative; clients read replicated data and send validated requests.

**Design imperative:** the set of unlockables (tools, businesses, upgrades) grows
indefinitely over the game's life. Every system must be data-driven and additive —
adding a new tool/business/unlockable must require new data + config, not rewrites.

## Gameplay Loop

1. Player spawns on their own plot with a starting business and starting tools.
2. Player equips a tool and cleans cleanable surfaces / stains in the active business.
3. Completing a business awards Cash + XP and unlocks new content (next business,
   tools, upgrades, plot expansion).
4. Player spends Cash / reaches Levels to unlock the next tier of content.
5. Repeat against a steadily expanding catalog of businesses and tools.

## Tools

Tools are inventory items (see `DataTemplate.Item`): `Name`, `Equipped`, `Unlocked`,
`Cost`, `UniqueID`. New tools are added as data + a behavior handler keyed by `UniqueID`.

### Broom
- Cleans **stain decals** (tracked per-business in `Business.CleanedStains`).
- Activates **on tool use** when the player is near a stain.
- Discrete: one activation clears a nearby stain (validate proximity server-side).

### Pressure Washer
- **Continuous-fire** cleaning tool with an **ammo/water limit**.
- Operates on **EditableImage dirt overlays** (full mechanic below).
- Firing consumes ammo per frame/tick; cleaning is gated on remaining ammo.

## Cleaning System Architecture

### Cleanable surfaces
- Each cleanable surface renders its **normal clean look** plus a **dirt overlay** as
  an `EditableImage`. Cleaning erases overlay pixels to reveal the clean surface.
- **Keep surfaces flat.** UV-mapping a 3D hit point to a 2D pixel is hard on complex
  geometry — flat surfaces keep the mapping tractable.

### Per-frame firing loop (client)
While the pressure washer is firing:
1. **Raycast** from the nozzle.
2. Map the **3D hit point → 2D pixel coordinate** on the surface's EditableImage (UV).
3. Erase a **brush circle** via `EditableImage:DrawCircle`.
4. **Gate on ammo** — stop when depleted.

### Coverage & completion
- Track **coverage** (fraction of overlay erased).
- At **90% coverage**, **snap the whole surface fully clean** (erase remaining dirt in
  one step).
- The client then **requests completion from the server**.
- The server **validates** the request and writes a **per-surface completion boolean**
  via DataService.

### Replication model
- **Pixel erasing is client-only, visual, never saved or replicated.**
- Leaving mid-surface **loses in-progress** erasing (nothing persisted until the
  completion boolean is written).
- Other players see only the **binary result**: a surface is fully dirty or fully clean.
  The 90% snap makes this a single **dirty → clean flip**; in-progress erasing is never
  visible to others.
- Only the **completion boolean** is saved/replicated — never pixel data.

## Data / Persistence — DataService

The game uses the **DataService** package (`leifstout/dataservice`) for **all player
data**. It pairs with the existing `DataTemplate` module, which defines the saved-data
shape and is the foundation the rest builds on.

**Rules:**
- Route **all player data changes through DataService**. Prefer its own methods
  (get/set/update, array operations, change signals, etc.) over hand-rolled handling.
- Let DataService's **built-in replication** keep clients in sync — don't build a
  parallel replication path.
- **Server-authoritative:** clients read replicated data and send validated requests for
  any change. The server validates before writing.

### Saved-data shape (`DataTemplate`)
Located at `src/ReplicatedStorage/SharedModules/DataTemplate.luau`. Current fields:

- `Cash: number`
- `Level: { CurrentLevel: number, XP: number }` — XP-to-next-level computed by a formula
  (function TBD).
- `BusinessList: { [string]: Business }` — keyed by `UniqueID`. Each `Business`:
  `BaseRate`, `Unlocked`, `Cleaned`, `Name`, `UniqueID`, `CleanedParts: {[string]: boolean}?`
  (per-surface completion booleans for pressure-washer surfaces),
  `CleanedStains: {[string]: boolean}?` (per-stain booleans for broom).
- `Inventory: { [string]: Item }` — keyed by `UniqueID`. Each `Item`: `Name`, `Equipped`,
  `Unlocked`, `Cost`, `UniqueID`.

Per-surface completion writes from the cleaning system land in `CleanedParts`;
broom stain completions land in `CleanedStains`. Both are the only cleaning state
persisted.

## EditableImage Constraints

Document and respect these limits:

- **Max 1024×1024**, and **not resizable** after creation.
- **Only one EditableImage updates per frame per client** — prefer **fewer/larger**
  surfaces over many small ones.
- **Memory-expensive:** only the **active business** holds live editable images.
  Completed/distant businesses use **static textures**.
- **Requires creator ID / age verification** to ship — account for this in release reqs.

## StreamingEnabled

The game uses **StreamingEnabled**.

- Cleaning code **must not assume surfaces are loaded** — wait for instances to stream
  in and **handle `nil`**.
- Players clean only their **own nearby plot**, so the **active business is reliably
  streamed in**.
- **Saved completion data replicates regardless of streaming**, so surfaces render to
  the correct state when they load (read the completion boolean on stream-in and set
  dirty/clean accordingly).

## Architecture — Entry Points & Service Modules

The entire game runs from **exactly two executing scripts**:

- **One server entry point** — `ServerScriptService/Main.server.luau`.
- **One client entry point** — a single `LocalScript` in `StarterPlayerScripts`.

**No other Script or LocalScript runs anything on its own.** Everything else in the game
is a **ModuleScript**. The two Main scripts do nothing but **require and initialize the
service modules** in the correct order.

### Service modules
- Treat every system as a **service**: a self-contained module owning one domain
  (e.g. `InventoryManager`, `CleaningService`, `BusinessManager`, `ToolService`,
  `UnlockManager`).
- Each service exposes an **`Init` function** that wires it up (connect events, build
  state, cache references). The relevant Main script calls each service's `Init` once,
  in dependency order, at startup. A service does nothing until `Init` runs.
- Services expose a clear **public API** (named functions) and keep internals private.
  Example: `InventoryManager.Init()`, then `InventoryManager.EquipTool(...)`,
  `InventoryManager.UnlockItem(...)`, etc., called by other services or by request
  handlers — never by a second loose script.
- Server services and client services are separate modules behind their respective Main
  scripts; shared logic/types/config live in `SharedModules`.

```
Main.server.luau                 (the only server Script)
  └── requires + Init()s:  DataService, InventoryManager, BusinessManager, CleaningService, ...

Main client LocalScript          (the only client Script)
  └── requires + Init()s:  InventoryController, CleaningController, ToolController, UI, ...
```

### Build reusable systems
This is a priority, not a nicety. The catalog of tools, businesses, and unlockables grows
continuously, so systems must be **generic and reusable rather than special-cased**:

- A service handles a **whole category** (all tools, all businesses), driven by data —
  not one hardcoded instance. Adding a new tool/business/unlockable = new data + config
  (and a behavior handler keyed by `UniqueID` if needed), with **no new top-level
  scripts and no edits to the Main files** beyond a possible single new `Init` call.
- Prefer composition and shared helpers over duplicated logic. If two systems need the
  same behavior, extract a shared module.
- Keep services decoupled: communicate through public APIs / signals, not by reaching
  into another service's internals.

## Code Standards

Clean, performant, well-structured code is a priority. The catalog of tools, businesses,
and unlockables grows continuously — structure code to **scale additively**.

- **Typing:** strict Luau (`--!strict`) throughout. Strong use of types everywhere.
- **Structure by shape of data:**
  - **Classes** (OOP, metatables) for **many-instance stateful objects** (e.g. a
    cleanable surface, an equipped tool instance).
  - **Modules/singletons** for systems that exist once (e.g. cleaning controller,
    unlock manager).
  - **Plain typed tables** for pure data (templates, configs).
- **Extensibility:** adding a tool/business/unlockable = new data + config + (if needed)
  a behavior handler keyed by `UniqueID`. No core rewrites.
- **Naming (Luau conventions):**
  - `PascalCase` — types, classes, modules.
  - `camelCase` — variables, functions, parameters.
  - Match existing `DataTemplate` style (PascalCase data fields as defined there).

## Rojo / Project Structure

The codebase uses **Rojo**; sync map is in `default.project.json`.

```
src/
  ReplicatedStorage/
    SharedModules/      -> ReplicatedStorage.SharedModules   (DataTemplate, shared types/configs)
    Remotes/            -> ReplicatedStorage.Remotes         (RemoteEvents/Functions)
  ServerScriptService/
    Main.server.luau    -> ServerScriptService.Main          (server entry point)
    Modules/            -> ServerScriptService.Modules        (server systems)
  StarterPlayer/
    StarterPlayerScripts/      -> client controllers
    StarterCharacterScripts/   -> per-character client scripts
Packages/               -> ReplicatedStorage.Packages         (Wally deps, incl. DataService)
```

- **Wally** manages dependencies (`wally.toml`); `DataService` lives in `Packages`.
- **All server module scripts live in `ServerScriptService/Modules`** (e.g.
  `InventoryManager`). The only server Script outside it is `Main.server.luau`.
- Shared types/configs go in `SharedModules` so client and server consume one source of
  truth (as `DataTemplate` already does).
- Client/server boundaries communicate via `ReplicatedStorage/Remotes`; all state
  mutation requests are server-validated.