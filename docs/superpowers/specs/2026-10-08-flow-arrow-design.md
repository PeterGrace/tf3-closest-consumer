# Flow Arrow — Design

**Date:** 2026-10-08
**Builds on:** `2026-10-08-closest-consumer-design.md`
**Status:** Approved. The spike comes first.

## Goal

From the "Nearest consumers" card, the player can show **one** cargo-flow arrow
on the map, from the producer to a chosen consumer. The base game can only show
arrows to *every* consumer at once, which happens when the Output stocks section
is expanded.

## Decisions

| Question | Decision |
|---|---|
| Trigger | A new arrow toggle button on each consumer row, between Locate and the name. The name still opens the consumer's window. |
| How many at once | One. Selecting another row switches to it; clicking the active toggle hides it. |
| Camera | When toggled on, frame both ends: focus on the midpoint, with camera distance proportional to the gap. |
| Arrow style | The base game's cargo-flow arrow and colours: animated "actual" if cargo already flows there, otherwise static and faint "potential". |

## How map drawing works in TF3 (from base-game source)

- All map overlays (`builtin.LayerConfig`, `MissionArrowRenderable`, ...) are
  children of an **action**: a `function(): TreeNodeId` that returns a
  `builtin.ActionDescriptor`.
- An action is bound to the map renderer with
  `react.useAction(gameCtx.rendererComponent, actionFn, key2)`
  (`gui/main/react.lua`). The renderer holds several bound actions and one
  **active owner**, set with `rendererComponent:get():getApi().setActiveOwner(selfRef)`.
  `setActiveOwner` isn't in the type definitions, but `gui/main/builtin.lua`
  calls it.
- The industry window binds its own action through `params.setActionFn`. It
  holds the catchment circle and, when Output is expanded, arrows to all
  consumers. Plugins don't receive `setActionFn`.
- `selector_react_util.makeDefaultSelectorAction(gameCtx, layerConfig)` builds a
  complete default action that keeps map selection, HUD icons and tooltips, plus
  a custom `LayerConfig`.
- An arrow is a `LayerConfig.CargoFlowRenderableConfig.FlowData`
  `{from, to: Vec3f, speed, arrowColors: {Vec4f}, cargoIconAlpha, cargoTypes}`.
  The colours come from `layerColors.CargoFlow.Consumers3D.{Actual,Potential}`.

## Design

### Binding

- When a flow is selected, the card renders a child recipe `FlowAction`.
- On mount it calls `react.useAction(gameCtx.rendererComponent, actionFn, "closest_consumer_flow")`
  and then `setActiveOwner(selfRef)`.
- `actionFn` is `makeDefaultSelectorAction(gameCtx, layerConfig)`, with a
  single-arrow `layerConfig`.
- Deselecting, or closing the window, unmounts `FlowAction`. `useAction`
  unbinds on unmount.
- **Expected:** the renderer falls back to the industry window's action. The
  spike verifies this.
- While our arrow is shown, it replaces the industry window's overlay
  (catchment circle, all-consumer arrows). That's intended.

### Data

- `nearest.tl` exports `getPosition3(entity) : Vec3f`: the bounding-box centre
  in x and y, and the box top for z, the same as base `industry.tl`.
- Positions are looked up when a flow is toggled on, not stored in the ranking
  results.

### Camera

- `api.gui.camera.focusPosition(midpoint, max(MIN_DISTANCE, gap * FACTOR))`.
- The spike starts with `FACTOR = 1.2` and `MIN_DISTANCE = 500` and logs the
  values, so they can be tuned in-game.

### UI

- A `builtin.ToggleButton` with the icon `::/gui/component/slim_arrow_right.tga`.
- `value` is 1 for the selected row.
- `onValueChange` sets or clears the selection in the card's state.

## Spike (first build)

The spike is the full mechanism, with these simplifications:

- Arrow colour is always "actual". The colour choice comes in the full version.
- Debug logging on bind, unbind and camera framing:
  `[closest_consumer] flow on/off ...`.

In-game checks for the user:

1. Toggling a row shows exactly one arrow, from the producer to that consumer.
2. While it's shown, clicking map entities still selects or opens them.
3. Toggling off brings back the normal industry overlay (the catchment circle
   and, if Output is expanded, the all-consumer arrows).
4. Closing the window with an arrow showing leaves no arrow behind, and the map
   behaves normally.
5. The camera framing feels right, or the factor needs tuning.

## Fallbacks if the spike fails

- **(3) fails.** Re-include the base catchment circle in our own `layerConfig`
  (`CatchmentAreaRenderableConfig` for the producer), so that losing the
  industry overlay matters less. Then investigate re-activating the window's
  action.
- **(1) fails** (our action never becomes active). Try `setActiveOwner` on
  every render, not only on mount, as `builtin.ActionContext` does for the top
  context.

## Full version (after a successful spike)

- Actual vs potential colour and speed from `cargo_util.getCargoFlowCount`.
- Tuned camera constants.
- README checklist additions.
- Remove debug logs, or downgrade them to a single line on error.

## Out of scope

- Several arrows at once.
- Arrows for suppliers (inputs).
- Persisting the selection after the window closes.
