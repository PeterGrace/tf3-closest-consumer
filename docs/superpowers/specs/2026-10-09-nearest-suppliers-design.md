# Nearest Suppliers and the Cargo Compass Rename: Design

**Date:** 2026-10-09
**Status:** Draft, awaiting review
**Builds on:** [closest consumer](2026-10-08-closest-consumer-design.md), [flow arrow](2026-10-08-flow-arrow-design.md)

## Goal

A mod user asked for the reverse of the existing feature. When the player opens an industry that
takes inputs, show the nearest places that can supply each input. When they open a warehouse,
show the nearest places that can fill it. The mod is renamed **Cargo Compass**, because it now
works in both directions.

## Decisions

| Question | Decision |
|---|---|
| Supplier kinds | Producers (industries whose rules output the cargo) and warehouses that hold the cargo, shown in separate sub-lists |
| Warehouse suppliers | Listed only when they currently store more than 0 of the cargo. A warehouse never lists itself |
| Towns as suppliers | No, because towns don't produce freight |
| Results shown | Top 3 producers and top 3 warehouses per input cargo |
| Inputs of a warehouse | Every cargo type its slots accept, not only what is stored now |
| Alternative or combined recipes | Ignored. One block per input cargo, with no recipe logic |
| Arrows | One at a time per window, from supplier to the clicked building |
| Display name | "Cargo Compass". The `modId`, folder and mod.io entry stay `pgrace_closest_consumer` / 6435673 |

## Card layout

Each window still gets **one** card from this mod. Its title depends on what the building has:

| Building | Title | Sections |
|---|---|---|
| Industry with inputs and outputs | Nearest suppliers & consumers | Suppliers, then Consumers |
| Industry with inputs only | Nearest suppliers | Suppliers |
| Industry with outputs only | Nearest consumers | Consumers (as today) |
| Warehouse | Nearest suppliers & consumers | Suppliers, then Consumers |

The card is hidden on industries that have neither inputs nor outputs.

**Why one card instead of two:** the arrow selection lives in the card's list component. With two
cards, each would hold its own selection, so both could show an arrow and fight over the map's
active owner override. One list component gives one selection, and so at most one arrow. The
order (suppliers first) follows the cargo, coming in and then going out.

Supplier block per input cargo:

```
Suppliers
  [icon] Grain
    Producers
      [⌖][➚] Westfield Farm        1.2 km
      ...
    Warehouses (in stock)
      [⌖][➚] Riverside Warehouse   0.9 km
      ...
```

- If there are no producers, the block shows the hint "No producers on this map".
- The Warehouses sub-list is left out when no other warehouse holds the cargo.
  The "Producers" label then goes too, so the block looks like a consumer block.
- When there are no inputs at all, the hints are "No inputs" for an industry and "No cargo
  accepted" for a warehouse. They only show when the other section exists, since otherwise the
  card is hidden.
- The Consumers section is unchanged.

**Collapsible cargo blocks** (added after the first in-game test, when a warehouse listed every cargo):

- Each cargo header is a button with the game's combobox arrows (`arrow_right` / `arrow_down`), as in
  `collapsible_checkbox_list.tl`. It shows the nearest distance in that block, so a collapsed list is still useful.
- Every cargo block starts collapsed, in every card. (A first version opened sections with up to 3 cargo types;
  the user preferred one consistent rule.)
- What the player opens is remembered only while the window stays open.
- Collapsing a cargo keeps its arrow on, if one is shown.

## Logic (`nearest.tl`)

### Inputs of the clicked building

- **Industry:** the `cargoType` of each stock with `type == InputStock`. This is the same
  data the consumer search already uses to decide whether an industry accepts a cargo, so the
  two directions agree. `Rule.input` is `{{integer}}` (amounts per stock slot), not cargo IDs,
  so we don't use it.
- **Warehouse:** every cargo type from `api.engine.util.stock.getStockCargoTypes` over all
  slots, de-duplicated and sorted. This is the "accepted" half of the existing
  `getWarehouseCargoTypes`, so that helper gets split in two.

### Supplier candidates

- **Producers:** every `INDUSTRY` entity, except the clicked building and warehouses, that has
  a rule whose `output` contains the cargo.
- **Warehouses:** every `WAREHOUSE` entity except the clicked building, for which
  `simEntityAtStockSystem.getStockCountForCargoType(warehouse.stockList, stockId, cargo) > 0`
  holds on some slot. Positions use the existing warehouse-to-construction bounding-volume
  fallback.
- Ranking reuses `rank.nearest` unchanged, once per sub-list.

### New API

```teal
record SupplyResult
	cargoType : CargoTypeId
	producers : {ClosestConsumerRank.Ranked}
	warehouses : {ClosestConsumerRank.Ranked}
end
getInputCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
findNearestSuppliers : function(entity : Engine.Entity, limit : integer) : {SupplyResult}
```

`getSourceCargoTypes` and `findNearestConsumers` keep their current behaviour.

## Arrows

- The selection gets a direction. The arrow is drawn `from` the supplier `to` the clicked
  building for supplier rows, and the other way for consumer rows. `FlowAction` takes explicit
  `from` and `to` entities instead of `source` and `consumer`.
- **Style:**
  - Producer → clicked industry:
    `cargo_util.getCargoFlowCount(supplier, clickedIndustry, cargo, false)` decides between
    Actual (animated) and Potential (faint, static). This is the same industry-to-industry log
    the consumer card reads.
  - Either end is a warehouse: Unknown (bright, static), as today. Deliveries are credited to the
    original producer and the delivering line, never to the warehouse. A quick log probe will
    confirm this for deliveries into a warehouse too. If the probe shows a usable log, we use it.
- The camera framing and the override handling stay as they are.

## Rename to Cargo Compass

- `modinfo.json`: name "Cargo Compass". The summary is rewritten to cover both directions and
  stays at most 100 characters.
- `description.html`:
  - The first line says "(formerly Closest Consumer)".
  - The features, how-to and good-to-know sections cover suppliers.
  - New good-to-know line: warehouse stock is read when the window opens, so reopen the window
    to refresh.
- README title and text are updated.
- The tags stay as they are.
- The GitHub repo name, internal file and module names (`closest_consumer.*`), and log prefixes
  stay unchanged. Renaming them would only cause churn. If the repo is renamed later, the
  `modinfo.json` URL needs updating.

## Revision

This ships as revision 2: `just bump`, then `just release`, upload, then `just mark-uploaded`.

## Testing

- **Unit tests:** `rank.tl` is unchanged and keeps its tests. The new code is engine queries
  only (stocks, rules, stock counts), so it has no pure logic worth unit testing beyond what
  `rank` already covers.
- **Type-check:** `just check` against the game's definitions.
- **In-game checklist:**
  1. A processing industry (for example a food plant) shows suppliers and consumers. Producer
     rows match the industries the base game lists for that input.
  2. A raw producer (a farm) shows only consumers, with the title "Nearest consumers".
  3. A pure consumer industry, if the map has one, shows only suppliers.
  4. A warehouse holding cargo X appears under another building's X suppliers. Once it is
     emptied and the window reopened, it no longer appears.
  5. The clicked warehouse never lists itself.
  6. The arrow on a producer row that already delivers is animated. One that doesn't deliver
     is faint. Warehouse rows are bright and static.
  7. Selecting a supplier arrow and then a consumer arrow leaves only one arrow on screen.
     Toggling it off brings the window's normal overlay back.
  8. Mod Hub shows "Cargo Compass", and the upload updates the existing entry.
