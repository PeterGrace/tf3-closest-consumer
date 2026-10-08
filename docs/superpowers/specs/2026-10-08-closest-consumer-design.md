# Closest Consumer — Design

**Date:** 2026-10-08
**Game:** Transport Fever 3 (native Linux build)
**Status:** Approved

## Goal

When the player opens the info window of an industry (producer) or a warehouse,
show the nearest places that can consume each cargo it sends out, with
straight-line distances.

The base game already shows a "Consumers" table under an industry's output
stocks (`ConsumersWidget` in `gui/entity_window/industry/industry_eow.script.tl`).
It lists every cargo-matched consumer on the map, but has no distance column and
cannot be sorted by distance. This mod adds that missing piece as its own card.

## Decisions

| Question | Decision |
|---|---|
| What counts as a consumer | Cargo-matched: industries with an input stock for the cargo, and towns whose `cargoNeeds` include it |
| Distance metric | Straight line on the map plane (x, y), ignoring height |
| Results shown | Top 3 per output cargo |
| Warehouses as consumers | No. Warehouses get the card, but never appear as results |
| Integration approach | Own plugin card in the entity windows (no base-file overrides) |

## Architecture

Mod ID: `pgrace_closest_consumer`

```
mod/pgrace_closest_consumer/
├── mod.json                          # modId, revision 1, cosmetic: true
├── _metadata/modinfo.json            # mod browser name/summary
└── content/gui/closest_consumer/
    ├── industry_plugin.res.lua       # react-plugin ::IndustryEowExtensionPoint
    ├── warehouse_plugin.res.lua      # react-plugin ::WarehouseEowExtensionPoint
    ├── closest_consumer.script.tl    # UI plugins (rendering only)
    └── nearest.tl                    # logic: gather + rank
```

### Plugin registration

TF3 adds sections to entity windows through React extension points. A
`*.res.lua` resource declares the plugin:

```lua
function data()
	return {
		type = "react-plugin ::IndustryEowExtensionPoint",
		data = {
			filePath = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@IndustryPlugin",
			condition = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@hasOutputs",
			order = 35,
		}
	}
end
```

The script registers the recipe with
`react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "...", fn)`
and returns it in the module table. Base-game references:
`gui/entity_window/industry/industry_eow_*.res.lua` and
`gui/game_bar/game_bar_display_transported_plugin/`.

### Module responsibilities

- **`closest_consumer.script.tl`**: two plugin recipes (industry, warehouse) and
  the condition function. It gets `params.entityId`, calls `nearest.tl`, and
  renders the results. It contains no matching or ranking logic.
- **`nearest.tl`** has two layers:
  - Gathering, which reads the game API: source cargo types, candidate
    consumers, positions, and names.
  - Pure functions with no game API access: `rank(sourcePos, candidates, n)`
    and `formatDistance(metres)`. These are unit-tested outside the game.

## Data flow

1. **Source cargo types**
   - Industry: the union of `stockList.rules[i].output` keys.
   - Warehouse: the `cargoType` of each stock in its stock list. Unassigned
     stocks (cargo type < 0) are ignored, and so are the `cargoTypes` sets of
     mixed stocks.
2. **Candidates per cargo**
   - Industries: every entity with an `INDUSTRY` component whose stock list has
     a stock with that `cargoType` and `type == InputStock`. The source entity
     itself is excluded.
   - Towns: every entity with a `TOWN` component where some
     `cargoNeeds[*][*][1] == cargoType`. Each cargo is evaluated independently,
     so a town can appear under several cargos.
3. **Position**: the bounding-volume centre (`BOUNDING_VOLUME` bbox midpoint),
   the same calculation the base industry window uses. Entities without a
   bounding volume are skipped.
4. **Distance**: `sqrt(dx² + dy²)` in metres.
5. **Ranking**: sort ascending by distance and keep the first 3 per cargo. On
   ties, sort by name to keep the order stable.
6. **Timing**: computed once when the window opens (`react.useStateLazy`).
   Reopen the window to refresh.

## UI

The plugin adds a `ContentCard` titled "Nearest consumers". For each source
cargo it shows:

- A header row with the cargo icon and the cargo name.
- Up to 3 rows, each with a `LineReactUtil.LocateButton`, a clickable name from
  `LineReactUtil.makeEntityWindowButton`, a "(town)" suffix for towns, and the
  distance.
- Distance format: `< 1000 m` is shown as `"850 m"`, otherwise as km with one
  decimal (`"4.2 km"`).

Empty states:

- A cargo with no candidates shows "No consumers on this map".
- A warehouse with no assigned cargo shows "No cargo assigned".
- An industry with no outputs gets no card: the condition function returns
  false.

## Error handling

- Missing components cause the candidate to be skipped. An empty name falls back
  to "Unnamed".
- Gathering and ranking run in `pcall`. On failure the card shows
  "Closest consumer: error (see log)" and the error is printed. The base window
  must never break because of this mod.

## Testing

1. **Type check**: run `tl check` against the game's `api/tealdef` and
   `base/tealdef`, configured through a repo `tlconfig.lua` that mirrors the
   game's `vscode-template`.
2. **Unit tests** cover the pure functions (`rank`, `formatDistance`, grouping).
   They run as plain Lua with fake data.
3. **In-game checklist** (manual):
   - The hello-world plugin appears. This proves the plumbing and is done
     first.
   - A coal mine lists its nearest coal consumers with distances.
   - A town appears with "(town)".
   - The Locate button moves the camera, and clicking a name opens that window.
   - A warehouse with assigned cargo lists consumers.
   - A warehouse with nothing assigned shows "No cargo assigned".
   - A pure consumer (no outputs) shows no card.

## Install for development

Symlink `mod/pgrace_closest_consumer` into TF3's local mods directory (the exact
path is determined during implementation), then restart the game to pick up
changes.

## Open risks

- Whether a mod needs a `_content.json` (present in official mods) or whether
  the game generates it. The hello-world step resolves this.
- Whether the `::IndustryEowExtensionPoint` id resolves for a non-base mod. Base
  registers it with `getOwningModId()` = `""`, so `::` should be correct.
- Whether Teal is compiled from source in mod folders. Official mods ship
  `.tl`, so it should be.

## Out of scope

- Road or rail network distance.
- Map overlays and lines.
- Changing the base Consumers table.
- Configurable result count.
