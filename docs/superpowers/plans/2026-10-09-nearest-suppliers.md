# Nearest Suppliers and the Cargo Compass Rename: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Suppliers" section (producers plus warehouses that have the cargo in stock) next to the existing "Consumers" section in the mod's industry and warehouse card, and rename the mod to Cargo Compass as revision 2.

**Architecture:**
- `nearest.tl` gains a supplier search that mirrors the consumer search, and returns producers and in-stock warehouses per input cargo.
- The card script renders both directions in **one** list component, so a single selection state allows at most one flow arrow.
- Selections carry an explicit direction (`from` → `to`).
- Display metadata is renamed. The `modId` and file names stay.

**Tech Stack:** Teal 0.24.8 (type-checked against the game's `tealdef`), the TF3 React GUI API, Lua 5.5 for unit tests, `just`.

**Spec:** `docs/superpowers/specs/2026-10-09-nearest-suppliers-design.md`

---

## Conventions for every task

- **Repo root:** `/home/pgrace/repos/tf3_mods/closest_consumer`.
- **Mod folder:** `M = mod/pgrace_closest_consumer`.
- **Type definitions:** the canonical `.d.tl` files live in `M/tealdef/`. `tools/build.py` (run by `just check`) copies them into `M/content/`. **Never edit `M/content/**/*.d.tl` by hand.**
- **Branch:** work on `feature/nearest-suppliers` in the main checkout, not a worktree, because the staging-area symlink points at this checkout's mod folder. Create it with `git checkout -b feature/nearest-suppliers`.
- **Verification:** `just check` must print no errors, and `just test` must report 8 passing tests.

## File map

| File | Change |
|---|---|
| `M/tealdef/gui/closest_consumer/nearest.d.tl` | Add `SupplyResult`, `getInputCargoTypes` and `findNearestSuppliers` |
| `M/content/gui/closest_consumer/nearest.tl` | Supplier search. Shared helpers are factored out of the consumer search |
| `M/content/gui/closest_consumer/closest_consumer.script.tl` | One card with Suppliers and Consumers sections, directional selection, and a temporary warehouse log probe |
| `M/content/gui/closest_consumer/industry_plugin.res.lua` | The condition becomes `hasCargo` |
| `M/_metadata/modinfo.json`, `M/_metadata/description.html` | Rename to Cargo Compass and describe suppliers |
| `README.md` | Rename and update the checklist |
| `M/mod.json` | Revision 2 (`just bump`) |

---

### Task 1: Supplier search in `nearest`

**Files:**
- Modify: `M/tealdef/gui/closest_consumer/nearest.d.tl`
- Modify: `M/content/gui/closest_consumer/nearest.tl`

- [ ] **Step 1: Extend the type definitions**

Replace `M/tealdef/gui/closest_consumer/nearest.d.tl` with:

```teal
global record ClosestConsumerNearest
	record CargoResult
		cargoType : CargoTypeId
		consumers : {ClosestConsumerRank.Ranked}
	end

	record SupplyResult
		cargoType : CargoTypeId
		producers : {ClosestConsumerRank.Ranked}
		warehouses : {ClosestConsumerRank.Ranked}
	end

	-- Bounding-box centre (x, y) at the box top (z), as the base industry window computes flow endpoints; nil if unknown.
	getPosition3 : function(entity : Engine.Entity) : Vec3f
	-- Cargo types the entity sends out: industry rule outputs; for a warehouse, what it stores now, or if empty what its stocks accept.
	getSourceCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
	-- Cargo types the entity takes in: industry input stocks; for a warehouse, every cargo type its stocks accept.
	getInputCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
	-- For each source cargo type (sorted by id), the nearest `limit` consumers. Warehouses and the source are never consumers.
	findNearestConsumers : function(entity : Engine.Entity, limit : integer) : {CargoResult}
	-- For each input cargo type (sorted by id), the nearest `limit` producers (industries whose rules output it)
	-- and the nearest `limit` other warehouses that hold some of it now.
	findNearestSuppliers : function(entity : Engine.Entity, limit : integer) : {SupplyResult}
end
```

- [ ] **Step 2: Replace the warehouse cargo helper with a per-slot iterator**

In `M/content/gui/closest_consumer/nearest.tl`, replace the whole `getWarehouseCargoTypes` function and the comment above it with:

```teal
-- Calls fn for every cargo type each warehouse slot accepts. stock.cargoType is only set for pinned slots, so ask the
-- engine per stock like the base warehouse window (cargo_util.forEachCargoInStock).
local function forEachWarehouseSlotCargo(warehouse : Engine.Component.Warehouse, stockList : Engine.Component.StockList, fn : function(StockId, CargoTypeId))
	for i = 1, #stockList.stocks do
		local stockId = (i - 1) as StockId
		for _, cargoType in ipairs(api.engine.util.stock.getStockCargoTypes(warehouse.stockList, stockId)) do
			fn(stockId, cargoType)
		end
	end
end

local function hasStored(warehouse : Engine.Component.Warehouse, stockId : StockId, cargoType : CargoTypeId) : boolean
	return api.engine.system.simEntityAtStockSystem.getStockCountForCargoType(warehouse.stockList, stockId, cargoType) > 0
end

-- Prefer what is stored now; an empty warehouse falls back to what it accepts.
local function getWarehouseCargoTypes(warehouse : Engine.Component.Warehouse, stockList : Engine.Component.StockList) : {CargoTypeId}
	local accepted : {CargoTypeId} = {}
	local stored : {CargoTypeId} = {}
	forEachWarehouseSlotCargo(warehouse, stockList, function(stockId : StockId, cargoType : CargoTypeId)
		accepted[#accepted + 1] = cargoType
		if hasStored(warehouse, stockId, cargoType) then
			stored[#stored + 1] = cargoType
		end
	end)
	return uniqueSorted(#stored > 0 and stored or accepted)
end
```

- [ ] **Step 3: Add `getInputCargoTypes` after `getSourceCargoTypes`**

```teal
function nearest.getInputCargoTypes(entity : Engine.Entity) : {CargoTypeId}
	local stockList = getStockList(entity)
	if stockList == nil then
		return {}
	end
	local inputs : {CargoTypeId} = {}
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		forEachWarehouseSlotCargo(warehouse, stockList, function(_stockId : StockId, cargoType : CargoTypeId)
			inputs[#inputs + 1] = cargoType
		end)
		return uniqueSorted(inputs)
	end
	-- Rule.input holds amounts per stock slot, not cargo ids, so read the input stocks (as collectCandidates does).
	local inputStock = api.type["enum"].StockListType.InputStock
	for _, stock in ipairs(stockList.stocks) do
		if stock.type == inputStock then
			inputs[#inputs + 1] = stock.cargoType
		end
	end
	return uniqueSorted(inputs)
end
```

- [ ] **Step 4: Factor the candidate helpers out of `collectCandidates`**

Add these two functions directly above `collectCandidates`:

```teal
local function newByCargo(cargoTypes : {CargoTypeId}) : {CargoTypeId : {ClosestConsumerRank.Candidate}}
	local byCargo : {CargoTypeId : {ClosestConsumerRank.Candidate}} = {}
	for _, cargoType in ipairs(cargoTypes) do
		byCargo[cargoType] = {}
	end
	return byCargo
end

local function addCandidate(byCargo : {CargoTypeId : {ClosestConsumerRank.Candidate}}, entity : Engine.Entity, cargoType : CargoTypeId, isTown : boolean)
	local x, y = getPosition(entity)
	if x == nil then
		return
	end
	local list = byCargo[cargoType]
	list[#list + 1] = { entity = entity, name = getName(entity), isTown = isTown, x = x, y = y }
end
```

In `collectCandidates`:
- Replace the opening `local byCargo ... end` block (the declaration plus the `for` loop) with `local byCargo = newByCargo(cargoTypes)`.
- Delete the local `add` function.
- Replace `add(entity, cargoType, false)` with `addCandidate(byCargo, entity, cargoType, false)`.
- Replace `add(townEntity, cargoType, true)` with `addCandidate(byCargo, townEntity, cargoType, true)`.

- [ ] **Step 5: Add the supplier collection and search**

Add `collectSuppliers` after `collectCandidates`, and `findNearestSuppliers` after `findNearestConsumers` (before `return nearest`):

```teal
-- Producers: industries (not warehouses, not the target) with a rule that outputs the cargo.
-- Warehouses: other warehouses holding some of the cargo now.
local function collectSuppliers(targetEntity : Engine.Entity, cargoTypes : {CargoTypeId}) : {CargoTypeId : {ClosestConsumerRank.Candidate}}, {CargoTypeId : {ClosestConsumerRank.Candidate}}
	local producers = newByCargo(cargoTypes)
	local warehouses = newByCargo(cargoTypes)

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if entity == targetEntity or getWarehouse(entity) ~= nil then
			return
		end
		local stockList : Engine.Component.StockList = api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
		if stockList == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		for _, rule in ipairs(stockList.rules) do
			for cargoType, _ in pairs(rule.output) do
				if producers[cargoType] ~= nil and not added[cargoType] then
					added[cargoType] = true
					addCandidate(producers, entity, cargoType, false)
				end
			end
		end
	end, api.type.ComponentType.INDUSTRY)

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if entity == targetEntity then
			return
		end
		local warehouse = getWarehouse(entity)
		local stockList = getStockList(entity)
		if warehouse == nil or stockList == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		forEachWarehouseSlotCargo(warehouse, stockList, function(stockId : StockId, cargoType : CargoTypeId)
			if warehouses[cargoType] ~= nil and not added[cargoType] and hasStored(warehouse, stockId, cargoType) then
				added[cargoType] = true
				addCandidate(warehouses, entity, cargoType, false)
			end
		end)
	end, api.type.ComponentType.WAREHOUSE)

	return producers, warehouses
end
```

```teal
function nearest.findNearestSuppliers(entity : Engine.Entity, limit : integer) : {ClosestConsumerNearest.SupplyResult}
	local cargoTypes = nearest.getInputCargoTypes(entity)
	if #cargoTypes == 0 then
		return {}
	end
	local targetX, targetY = getPosition(entity)
	if targetX == nil then
		error("no position for entity " .. tostring(entity))
	end
	local producers, warehouses = collectSuppliers(entity, cargoTypes)
	local results : {ClosestConsumerNearest.SupplyResult} = {}
	for _, cargoType in ipairs(cargoTypes) do
		results[#results + 1] = {
			cargoType = cargoType,
			producers = rank.nearest(targetX, targetY, producers[cargoType], limit),
			warehouses = rank.nearest(targetX, targetY, warehouses[cargoType], limit),
		}
	end
	return results
end
```

- [ ] **Step 6: Type-check and test**

Run: `just check && just test`
Expected: no type errors, and 8 tests passing. The script still compiles, because the old API is unchanged.

- [ ] **Step 7: Commit**

```bash
git add mod/pgrace_closest_consumer
git commit -m "feat: find nearest producers and in-stock warehouses per input cargo"
```

---

### Task 2: One card with Suppliers and Consumers sections

**Files:**
- Modify: `M/content/gui/closest_consumer/closest_consumer.script.tl`
- Modify: `M/content/gui/closest_consumer/industry_plugin.res.lua`

- [ ] **Step 1: Replace the records and the state computation**

Replace everything from `local record ListParams` up to (but not including) `local function makeHint` with:

```teal
local record ListParams
	entityId : Engine.Entity
	isWarehouse : boolean
	showSuppliers : boolean
	showConsumers : boolean
	gameCtx : GameContext
end

-- The flow whose arrow is shown; nil when none is. `from` sends the cargo, `to` receives it.
local record Selection
	from : Engine.Entity
	to : Engine.Entity
	cargoType : CargoTypeId
	toIsTown : boolean
	-- Either end is a warehouse, whose deliveries the cargo logs don't record.
	viaWarehouse : boolean
end

local record FlowParams
	gameCtx : GameContext
	selection : Selection
end

-- "Actual" (animated) when cargo already flows there, "Potential" (static, faint) when not.
-- "Unknown" when either end is a warehouse: the engine credits warehouse deliveries to the original producer and the
-- delivering line, never to the warehouse, so we can't tell. Bright like Actual, but static so it claims no flow.
local enum FlowStyle
	"Actual"
	"Potential"
	"Unknown"
end

-- The renderer API (gui/main/builtin.lua) also has these, but they are missing from the type definitions.
-- The override takes precedence over the regular active owner (set by the tool stack's top entry) without
-- replacing it, so clearing the override with `false` hands the map straight back to the window's own action.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

local record FlowCache
	key : string
	action : function() : TreeNodeId
end

local record ListState
	suppliers : {ClosestConsumerNearest.SupplyResult}
	consumers : {ClosestConsumerNearest.CargoResult}
	failed : boolean
end

local function computeState(params : ListParams) : ListState
	local state : ListState = { suppliers = {}, consumers = {}, failed = false }
	if params.showSuppliers then
		local ok, resultsOrError = pcall(nearest.findNearestSuppliers, params.entityId, RESULT_LIMIT)
		if ok then
			state.suppliers = resultsOrError as {ClosestConsumerNearest.SupplyResult}
		else
			debugPrint("[closest_consumer] error (suppliers) for entity " .. tostring(params.entityId) .. ": " .. tostring(resultsOrError))
			state.failed = true
		end
	end
	if params.showConsumers then
		local ok, resultsOrError = pcall(nearest.findNearestConsumers, params.entityId, RESULT_LIMIT)
		if ok then
			state.consumers = resultsOrError as {ClosestConsumerNearest.CargoResult}
		else
			debugPrint("[closest_consumer] error (consumers) for entity " .. tostring(params.entityId) .. ": " .. tostring(resultsOrError))
			state.failed = true
		end
	end
	return state
end
```

- [ ] **Step 2: Add a label helper after `makeHint`**

```teal
local function makeLabel(text : string, class : string) : TreeNodeId
	return builtin.TextView{ meta = { class = class }, text = text }
end
```

- [ ] **Step 3: Make `FlowAction` directional and add the temporary probe**

In the `FlowAction` recipe body, replace everything from the `local key = ...` line through the end of the `if changed then ... end` block with:

```teal
	local selection = params.selection
	local key = tostring(selection.from) .. ">" .. tostring(selection.to) .. ":" .. tostring(selection.cargoType)
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = nearest.getPosition3(selection.from)
		local to = nearest.getPosition3(selection.to)
		local action : function() : TreeNodeId = nil
		if from ~= nil and to ~= nil then
			local style : FlowStyle = "Unknown"
			if selection.viaWarehouse then
				-- PROBE (remove before release): does either log direction record warehouse deliveries?
				debugPrint(string.format("[closest_consumer] probe %s itemsTransported fwd=%d rev=%d", key,
					api.engine.util.stock.getCargoLogPerYearForTarget(selection.from, selection.to, "itemsTransported", selection.cargoType),
					api.engine.util.stock.getCargoLogPerYearForTarget(selection.to, selection.from, "itemsTransported", selection.cargoType)))
			else
				local count = cargo_util.getCargoFlowCount(selection.from, selection.to, selection.cargoType, selection.toIsTown)
				style = count > 0 and "Actual" or "Potential"
			end
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.cargoType, style))
			frameCamera(from, to)
		else
			debugPrint("[closest_consumer] flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end
```

The rest of `FlowAction` (`useAction`, `setOverride`, mount and unmount) stays as it is.

- [ ] **Step 4: Replace the row, section, list and card builders**

Replace everything from `local function makeConsumerRow` through the end of the file with:

```teal
-- One row: locate, flow toggle, name (opens its window), distance. `flow` is the selection the toggle sets.
local function makeFlowRow(entry : ClosestConsumerRank.Ranked, flow : Selection, selectionState : ReactStateT<Selection>) : TreeNodeId
	local label = entry.name
	if entry.isTown then
		label = label .. " " .. _("(town)")
	end
	local current = selectionState:old()
	local isSelected = current ~= nil and current.from == flow.from and current.to == flow.to and current.cargoType == flow.cargoType
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = entry.entity },
			builtin.ToggleButton{
				meta = { tooltip = _("Show this flow on the map") },
				content = builtin.ImageView{
					path = "::/gui/component/slim_arrow_right.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				value = isSelected and 1 or 0,
				onValueChange = function(value : integer)
					if value == 1 then
						selectionState:set(flow)
					else
						selectionState:set(nil)
					end
				end,
			},
			line_react_util.makeEntityWindowButton(label, entry.entity),
			builtin.TextView{ text = rank.formatDistance(entry.distance) },
		},
	}
end

local function makeCargoHeader(cargoType : CargoTypeId) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			cargo_react_util.makeCargoIcon(cargoType),
			builtin.TextView{ text = cargo_util.getCargoNameById(cargoType) },
		},
	}
end

local function makeConsumerSection(result : ClosestConsumerNearest.CargoResult, params : ListParams, selectionState : ReactStateT<Selection>) : TreeNodeId
	local children : {TreeNodeId} = { makeCargoHeader(result.cargoType) }
	if #result.consumers == 0 then
		children[#children + 1] = makeHint(_("No consumers on this map"))
	else
		for _, consumer in ipairs(result.consumers) do
			children[#children + 1] = makeFlowRow(consumer, {
				from = params.entityId,
				to = consumer.entity,
				cargoType = result.cargoType,
				toIsTown = consumer.isTown,
				viaWarehouse = params.isWarehouse,
			}, selectionState)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local function makeSupplierSection(result : ClosestConsumerNearest.SupplyResult, params : ListParams, selectionState : ReactStateT<Selection>) : TreeNodeId
	local children : {TreeNodeId} = {
		makeCargoHeader(result.cargoType),
		makeLabel(_("Producers"), "font-scale-annotation"),
	}
	if #result.producers == 0 then
		children[#children + 1] = makeHint(_("No producers on this map"))
	else
		for _, producer in ipairs(result.producers) do
			children[#children + 1] = makeFlowRow(producer, {
				from = producer.entity,
				to = params.entityId,
				cargoType = result.cargoType,
				toIsTown = false,
				viaWarehouse = params.isWarehouse,
			}, selectionState)
		end
	end
	if #result.warehouses > 0 then
		children[#children + 1] = makeLabel(_("Warehouses (in stock)"), "font-scale-annotation")
		for _, warehouse in ipairs(result.warehouses) do
			children[#children + 1] = makeFlowRow(warehouse, {
				from = warehouse.entity,
				to = params.entityId,
				cargoType = result.cargoType,
				toIsTown = false,
				viaWarehouse = true,
			}, selectionState)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

-- Both directions live in one list so that one selection state allows at most one flow arrow per window.
local NearestList = react.RegisterRecipe("ClosestConsumerList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params)
	end)
	local current = state:old()
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		children[#children + 1] = node
	end
	-- Headings only when both sections show; otherwise the card title says it all.
	local both = params.showSuppliers and params.showConsumers
	if current.failed then
		add(makeHint(_("Cargo Compass: error (see log)")))
	else
		if params.showSuppliers then
			if both then
				add(makeLabel(_("Suppliers"), "font-scale-title-4"))
			end
			if #current.suppliers == 0 then
				add(makeHint(params.isWarehouse and _("No cargo accepted") or _("No inputs")))
			else
				for _, result in ipairs(current.suppliers) do
					add(makeSupplierSection(result, params, selectionState))
				end
			end
		end
		if params.showConsumers then
			if both then
				add(makeLabel(_("Consumers"), "font-scale-title-4"))
			end
			if #current.consumers == 0 then
				add(makeHint(params.isWarehouse and _("No cargo stored or accepted") or _("No outputs")))
			else
				for _, result in ipairs(current.consumers) do
					add(makeConsumerSection(result, params, selectionState))
				end
			end
		end
	end
	if selectionState:old() ~= nil then
		add(FlowAction{ gameCtx = params.gameCtx, selection = selectionState:old() })
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local function makeCard(params : ListParams, showOnRightSide : boolean) : TreeNodeId
	local title = _("Nearest consumers")
	if params.showSuppliers and params.showConsumers then
		title = _("Nearest suppliers & consumers")
	elseif params.showSuppliers then
		title = _("Nearest suppliers")
	end
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = title,
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(NearestList, params),
			gameCtx = params.gameCtx,
			showOnRightSide = showOnRightSide,
		},
	}
end

-- Which sections an industry gets. On error, both show so the card can report it.
local function getIndustryParams(entityId : Engine.Entity, gameCtx : GameContext) : ListParams
	local okInputs, inputs = pcall(nearest.getInputCargoTypes, entityId)
	local okOutputs, outputs = pcall(nearest.getSourceCargoTypes, entityId)
	return {
		entityId = entityId,
		isWarehouse = false,
		showSuppliers = not okInputs or #(inputs as {CargoTypeId}) > 0,
		showConsumers = not okOutputs or #(outputs as {CargoTypeId}) > 0,
		gameCtx = gameCtx,
	}
end

local IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "ClosestConsumerIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return makeCard(getIndustryParams(params.entityId, params.gameCtx), params.showCalloutOnRightSide)
end)

local WarehousePlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "ClosestConsumerWarehousePlugin", function(params : WarehouseEow.WarehouseWidgetPluginParams) : TreeNodeId
	return makeCard({
		entityId = params.entityId,
		isWarehouse = true,
		showSuppliers = true,
		showConsumers = true,
		gameCtx = params.gameCtx,
	}, params.showCalloutOnRightSide)
end)

-- Hides the card for industries with neither inputs nor outputs.
local function hasCargo(params : IndustryEow.IndustryWidgetPluginParams) : boolean
	local listParams = getIndustryParams(params.entityId, params.gameCtx)
	return listParams.showSuppliers or listParams.showConsumers
end

return {
	IndustryPlugin = IndustryPlugin,
	WarehousePlugin = WarehousePlugin,
	hasCargo = hasCargo,
}
```

- [ ] **Step 5: Point the industry plugin condition at `hasCargo`**

In `M/content/gui/closest_consumer/industry_plugin.res.lua`, change `...closest_consumer.script@hasOutputs` to `...closest_consumer.script@hasCargo`.

- [ ] **Step 6: Type-check and test**

Run: `just check && just test`
Expected: no type errors, and 8 tests passing. If Teal rejects the `{ from = ..., ... }` literals as `Selection` arguments, annotate them: `local flow : Selection = { ... }`.

- [ ] **Step 7: Commit**

```bash
git add mod/pgrace_closest_consumer
git commit -m "feat: nearest suppliers section with directional flow arrows"
```

---

### Task 3: In-game test and warehouse log probe (needs the user)

- [ ] **Step 1: Ask the user to restart TF3 and run the spec's in-game checklist**

The checklist is in `docs/superpowers/specs/2026-10-09-nearest-suppliers-design.md` under Testing, items 1–7. For item 6, ask the user to click the arrow on several warehouse rows where cargo really is delivered, in both directions:
- a warehouse row under an industry's suppliers;
- a producer row under a warehouse's suppliers.

- [ ] **Step 2: Read the probe output**

Run:
```bash
grep -h "closest_consumer" ~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt | tail -40
```
- If every `probe` line shows `fwd=0 rev=0` even for known deliveries, warehouse arrows stay "Unknown", as the spec says.
- If a direction is non-zero and tracks real deliveries, stop and report to the user before using it.

- [ ] **Step 3: Remove the probe**

In `FlowAction`, replace the `if selection.viaWarehouse then <probe> else` block with:

```teal
			if not selection.viaWarehouse then
				local count = cargo_util.getCargoFlowCount(selection.from, selection.to, selection.cargoType, selection.toIsTown)
				style = count > 0 and "Actual" or "Potential"
			end
```

Run `just check`, then commit with `git commit -am "chore: remove warehouse log probe"`.

---

### Task 4: Rename to Cargo Compass

**Files:**
- Modify: `M/_metadata/modinfo.json`
- Modify: `M/_metadata/description.html`
- Modify: `README.md`

- [ ] **Step 1: `modinfo.json`**

Set:
- `"name": "Cargo Compass"`
- `"summary": "Lists the nearest suppliers and consumers for each cargo, and shows a single flow arrow on the map."` (99 characters)
- `"description"` to:

```
(Formerly Closest Consumer.) Click any industry or warehouse, and Cargo Compass adds a card to its window that shows where each cargo can come from and where it can go.\n\n- Suppliers: for each input cargo, the three closest industries that produce it, plus the three closest warehouses that have it in stock.\n- Consumers: for each cargo the building sends out, the three closest industries and towns that use it.\n- The arrow button on a row draws one cargo-flow arrow on the map and moves the camera so both ends are in view. The arrow is animated if that flow already runs, and faint if it doesn't yet. Arrows to or from a warehouse are always bright and static, because the game doesn't record which flows go through a warehouse.\n- The locate button moves the camera to a building, and clicking its name opens that building's window.\n\nDistances are measured in a straight line. Lists are worked out when the window opens. Cosmetic mod: achievements stay available, and you can add it to or remove it from existing saves.
```

- [ ] **Step 2: Replace `description.html`**

```html
<h2>Find where your cargo comes from and where it can go</h2>
<p><i>Formerly Closest Consumer.</i></p>
<p>Click any industry or warehouse, and Cargo Compass adds a card to its window. It lists the nearest <b>suppliers</b> for each cargo the building takes in, and the nearest <b>consumers</b> for each cargo it sends out, with the distance to each.</p>
<hr>
<h3>Features</h3>
<ul>
<li><b>Nearest suppliers per input</b>: the three closest industries that produce the cargo, plus the three closest warehouses that have it in stock, shown as separate lists.</li>
<li><b>Nearest consumers per output</b>: the three closest industries or towns that accept the cargo, sorted by distance.</li>
<li><b>Show a single flow</b>: the arrow button on a row draws one cargo-flow arrow on the map and moves the camera so both ends are in view. The arrow is animated if that flow already runs, and faint if it doesn't yet.</li>
<li><b>Warehouses too</b>: a warehouse shows suppliers for every cargo its slots accept, and consumers for the cargo it stores (or, when empty, accepts).</li>
<li><b>Quick navigation</b>: the locate button moves the camera to a building, and clicking its name opens that building's window.</li>
</ul>
<h3>How to use</h3>
<ol>
<li>Open the window of an industry or a warehouse.</li>
<li>Find the <b>Nearest suppliers &amp; consumers</b> card below the stocks. Industries with only inputs or only outputs show just that half.</li>
<li>Click the arrow button on a row to show that flow on the map. Click it again, or close the window, to go back to the normal view.</li>
</ol>
<h3>Good to know</h3>
<ul>
<li>Distances are measured in a straight line, not along roads or tracks.</li>
<li>Towns never appear as suppliers, because they don't produce freight. Warehouses never appear as consumers.</li>
<li>Lists, including which warehouses have stock, are worked out when the window opens. Reopen the window to refresh them.</li>
<li>Only one flow arrow shows at a time. While it's shown, it replaces the window's usual map overlay (catchment area and the arrows to all consumers).</li>
<li>Arrows to or from a warehouse are always bright and static. The game credits cargo moved through a warehouse to the industry that originally produced it, so the mod can't tell whether that flow already runs.</li>
<li>This is a cosmetic mod. It doesn't change the simulation, so achievements stay available, and you can add it to or remove it from existing saves.</li>
</ul>
```

- [ ] **Step 3: Update `README.md`**

- Title: `# Cargo Compass (Transport Fever 3 mod)`.
- Replace the first two paragraphs (up to the `- Mod ID:` list) with:

  > Formerly **Closest Consumer**. Adds a card to the industry and warehouse info windows. For each cargo the building takes in, it lists the three closest producing industries and the three closest warehouses that have the cargo in stock. For each cargo it sends out, it lists the three closest industries or towns that consume it. Distances are straight-line. Each row has the game's Locate button, and the name opens that building's window.
  >
  > Each row also has a **flow arrow toggle**. It shows a single cargo-flow arrow on the map, from supplier to receiver, and frames the camera on both ends. The arrow is animated if cargo already flows there; otherwise it's faint and static. Arrows to or from a warehouse are always bright and static. Only one arrow shows at a time. Toggling it off, or closing the window, gives the map back to the window's normal overlay.

- Under `- Design:` add `- Supplier design: [docs/superpowers/specs/2026-10-09-nearest-suppliers-design.md](docs/superpowers/specs/2026-10-09-nearest-suppliers-design.md)`.
- Layout comments: industry plugin "registers the card in the industry window", unchanged; `nearest.tl` becomes "reads game state: cargo, suppliers, consumers, positions".
- In the In-game test, step 1: enable **Cargo Compass**.
- In the In-game test checklist:
  - Change "A pure consumer (e.g. a power plant) shows no card." to "A pure consumer (e.g. a power plant) shows only **Nearest suppliers**."
  - Change "For a warehouse, the arrow is always bright and static." to "Arrows to or from a warehouse are always bright and static."
  - Append:
    - `- [ ] A processing industry shows **Nearest suppliers & consumers**, with Suppliers first.`
    - `- [ ] A raw producer (e.g. a farm) shows only **Nearest consumers**, as before.`
    - `- [ ] A warehouse holding cargo X appears under another building's X suppliers, and disappears after it is emptied and the window reopened.`
    - `- [ ] A warehouse never lists itself.`
    - `- [ ] Selecting a supplier arrow and then a consumer arrow leaves exactly one arrow.`
- Known limitations, first bullet: change "Warehouse arrows can't show actual vs potential." to "Arrows to or from a warehouse can't show actual vs potential."

- [ ] **Step 4: Verify and commit**

Run: `just release-check`
Expected: OK, with no problems.

```bash
git add README.md mod/pgrace_closest_consumer/_metadata
git commit -m "docs: rename to Cargo Compass and describe suppliers"
```

---

### Task 5: Revision 2 and merge

- [ ] **Step 1: Bump**

Run: `just bump`
Expected: `revision -> 2`, with a one-line diff in `mod.json`.

```bash
git commit -am "chore: revision 2"
```

- [ ] **Step 2: Full gate**

Run: `just release`
Expected: "revision 2 is new (last uploaded: 1)", then the check, the tests (8 passed) and the release-check all OK, ending with "Ready: upload from Mod Hub...".

- [ ] **Step 3: Hand off**

Use superpowers:finishing-a-development-branch to merge into `main` locally. The upload (Mod Hub > My Mods) and `just mark-uploaded` are done by the user. Remind them to check that Mod Hub shows "Cargo Compass" and says "The existing mod on mod.io will be updated".
