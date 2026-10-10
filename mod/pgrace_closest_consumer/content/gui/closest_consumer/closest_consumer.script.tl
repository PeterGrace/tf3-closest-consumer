local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local cargo_react_util = ug_require "::/gui/main/cargo_react_util.tl" as CargoReactUtil
local cargo_util = ug_require "::/gui/main/cargo_util.tl" as CargoUtil
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local callout_react_util = ug_require "::/gui/main/callout_react_util.tl" as CalloutReactUtil
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow
local nearest = ug_require "pgrace_closest_consumer::/gui/closest_consumer/nearest.tl" as ClosestConsumerNearest
local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data as GResTransparency

local RESULT_LIMIT = 3
local FLOW_ACTION_KEY = "closest_consumer_flow"
local CAMERA_DISTANCE_FACTOR = 1.2
local CAMERA_MIN_DISTANCE = 500
-- focusPosition caps the distance at the game's maximum zoom-out (about 4,055 m in testing).
local CAMERA_MAX_DISTANCE = 4000
-- How far to move the view toward screen-right, as a fraction of the camera distance, so the arrow is centred
-- in the map area left of the entity window (about the right quarter of a 16:9 screen).
local CAMERA_WINDOW_SHIFT = 0.27
-- The cargo-flow arrow is drawn as an arc this high (as a share of its length); the distance label sits on its top.
-- Measured by eye in Commuter Compass; it matched both short and long arrows.
local ARROW_ARC_HEIGHT = 0.06

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

-- Distance of the closest entry across the given (already sorted) lists; nil when all are empty.
local function nearestOf(lists : {{ClosestConsumerRank.Ranked}}) : number
	local best : number = nil
	for _, list in ipairs(lists) do
		local first = list[1]
		if first ~= nil and (best == nil or first.distance < best) then
			best = first.distance
		end
	end
	return best
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
	-- Nearest cargo first, so long lists (warehouses) lead with the closest options.
	state.suppliers = rank.orderByNearest(state.suppliers, function(result : ClosestConsumerNearest.SupplyResult) : number
		return nearestOf({ result.producers, result.warehouses })
	end)
	state.consumers = rank.orderByNearest(state.consumers, function(result : ClosestConsumerNearest.CargoResult) : number
		return nearestOf({ result.consumers })
	end)
	return state
end

local function makeHint(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text }
end

local function makeLabel(text : string, class : string) : TreeNodeId
	return builtin.TextView{ meta = { class = class }, text = text }
end

-- Styled like the base industry window's consumer arrows.
local function planarDistance(a : Vec3f, b : Vec3f) : number
	local dx, dy = b.x - a.x, b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
end

local record ArrowLabelParams is IRecipeParamWithMeta
	text : string
end

local ArrowLabel = react.RegisterRecipe("ClosestConsumerArrowLabel", function(params : ArrowLabelParams) : TreeNodeId
	return builtin.BoxLayout{
		children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = params.text } },
	}
end)

local record ArrowLabelLayerParams
	from : Vec3f
	to : Vec3f
	text : string
end

-- The arrow's distance, drawn at the top of its arc. A full-screen layer of the arrow's own map action (as the town
-- window draws its layer legend), so it comes and goes with the arrow and other popups can't displace it.
local ArrowLabelLayer = react.RegisterRecipe("ClosestConsumerArrowLabelLayer", function(params : ArrowLabelLayerParams) : TreeNodeId
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local a, b = params.from, params.to
	local lift = ARROW_ARC_HEIGHT * planarDistance(a, b)
	local top = api.type.Vec3f.new(0.5 * (a.x + b.x), 0.5 * (a.y + b.y), 0.5 * (a.z + b.z) + lift)
	-- Where the label goes, in fractions of the screen; nil while unknown or behind the camera.
	local positionState : ReactStateT<Vec2f> = react.useState(nil)
	react.onStep(function()
		-- world2Screen is restricted during the react step ("API is currently restricted"), so it runs in a join on
		-- the main thread, as the base mission task list does with api.gui.byId.
		react.enqueueJoin(function()
			local ok, point = pcall(api.gui.camera.world2Screen, top)
			local sizeOk, size = pcall(api.gui.camera.getSize)
			if not ok or not sizeOk or point == nil or size == nil then
				return
			end
			local pixel, viewport = point as Vec2i, size as Vec2i
			if viewport.x <= 0 or viewport.y <= 0 then
				return
			end
			-- world2Screen gives viewport pixels; the floating layout places things in fractions of the screen.
			local h, v = pixel.x / viewport.x, pixel.y / viewport.y
			local old = positionState:old()
			if old == nil or old.x ~= h or old.y ~= v then
				positionState:set(api.type.Vec2f.new(h, v))
			end
		end, "ClosestConsumerArrowLabelLayer")
	end)
	local position = positionState:old()
	if position == nil or position.x < 0 or position.x > 1 or position.y < 0 or position.y > 1 then
		return builtin.FloatingLayout{ children = {} }
	end
	-- arrow_label.css.lua makes this floating layout fill the screen (gravity -1, -1), as the game's stylesheet does
	-- for the callout container; then h and v place the label anywhere on it.
	return builtin.FloatingLayout{
		children = {
			builtin.FloatingLayoutChild{
				h = position.x,
				v = position.y,
				-- Keeps the label on screen near the edges, as the callout container does. (The tealdef types this field
				-- as boolean, but the game passes the enum.)
				overflowMode = builtin.type.FloatingLayoutOverflowMode.KeepInside as any as boolean,
				item = callout_react_util.DefaultCalloutWrapper{
					meta = { styleSheet = styleutil.makeStyle{ anchorPoint = api.type.Vec2f.new(0.5, 0.5) } },
					recipe = ArrowLabel,
					recipeParam = { text = params.text } as ArrowLabelParams,
				},
			},
		},
	}
end)

local function makeFlowLayerConfig(from : Vec3f, to : Vec3f, cargoType : CargoTypeId, style : FlowStyle) : LayerConfig
	local colors = layerColors.CargoFlow.Consumers3D
	local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
	flow.from = from
	flow.to = to
	flow.speed = style == "Actual" and 40.0 or 0.0
	flow.arrowColors = style == "Potential"
		and color_util.toArray4WithTransparency(colors.Potential, transparency.VeryLow)
		or color_util.toArray4(colors.Actual)
	flow.cargoIconAlpha = style == "Potential" and 0.6 or 1.0
	flow.cargoTypes = { cargoType }
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = { flow }
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

-- Moves the camera's look-at point toward screen-right, so the midpoint lands in the middle of the map area
-- left of the entity window. Screen-right comes from the camera's eye and centre; world2Screen confirms the sign.
local function shiftClearOfWindow(midpoint : Vec3f, distance : number) : Vec3f
	local camera = api.gui.camera
	local eye = camera.getEye()
	local center = camera.getCenter()
	local fx, fy = center.x - eye.x, center.y - eye.y
	local length = math.sqrt(fx * fx + fy * fy)
	if length < 1e-3 then
		return midpoint
	end
	local rx, ry = fy / length, -fx / length
	local probe = api.type.Vec3f.new(center.x + 100 * rx, center.y + 100 * ry, center.z)
	if camera.world2Screen(probe).x < camera.world2Screen(center).x then
		rx, ry = -rx, -ry
	end
	local shift = CAMERA_WINDOW_SHIFT * math.min(distance, CAMERA_MAX_DISTANCE)
	return api.type.Vec3f.new(midpoint.x + shift * rx, midpoint.y + shift * ry, midpoint.z)
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local dx = to.x - from.x
	local dy = to.y - from.y
	local gap = math.sqrt(dx * dx + dy * dy)
	local distance = math.max(CAMERA_MIN_DISTANCE, gap * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	local ok, target = pcall(shiftClearOfWindow, midpoint, distance)
	if not ok then
		debugPrint("[closest_consumer] camera shift failed: " .. tostring(target))
		target = midpoint
	end
	api.gui.camera.focusPosition(target as Vec3f, distance)
end

-- Binds a map action that draws one flow arrow and makes it the renderer's active owner override.
-- Unmounting clears the override and unbinds the action, handing the map back to the industry window's own action.
local FlowAction = react.RegisterRecipe("ClosestConsumerFlowAction", function(params : FlowParams) : TreeNodeId
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
			if not selection.viaWarehouse then
				local count = cargo_util.getCargoFlowCount(selection.from, selection.to, selection.cargoType, selection.toIsTown)
				style = count > 0 and "Actual" or "Potential"
			end
			local text = rank.formatDistance(planarDistance(from, to))
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, selection.cargoType, style),
				nil, function() : TreeNodeId
					return builtin.FullScreenComponent{
						recipe = ArrowLabelLayer,
						param = { from = from, to = to, text = text } as ArrowLabelLayerParams,
					}
				end)
			frameCamera(from, to)
		else
			debugPrint("[closest_consumer] flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end

	-- One action key per arrow: switching arrows while bound under a single key kept the old arrow on screen
	-- (the renderer only picked the new one up after a fresh mount).
	local selfRef = react.useAction(params.gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY .. ":" .. key)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		if params.gameCtx.rendererComponent:hasExpired() then
			return false
		end
		local rc = params.gameCtx.rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		-- Not part of the documented API: degrade to "no arrow" rather than erroring if a game update removes it.
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	local function activate()
		setOverride(selfRef)
	end

	react.onMount(activate)
	if changed and cacheRef:get().action ~= nil and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

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
					path = "::/gui/entity_window/icons/symbol_arrow_up.tga",
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

-- Expand/collapse state of one cargo block, and how to flip it.
local record Fold
	expanded : boolean
	toggle : function()
end

-- Clickable cargo header with the game's combobox arrows (as in collapsible_checkbox_list); shows the nearest
-- distance so collapsed blocks are still useful.
local function makeCargoHeader(cargoType : CargoTypeId, nearestDistance : number, fold : Fold) : TreeNodeId
	return builtin.Button{
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.ImageView{
					path = fold.expanded and "::/gui/builtin/combobox/arrow_down.tga" or "::/gui/builtin/combobox/arrow_right.tga",
				},
				cargo_react_util.makeCargoIcon(cargoType),
				builtin.TextView{ text = cargo_util.getCargoNameById(cargoType) },
				nearestDistance ~= nil and builtin.TextView{ text = rank.formatDistance(nearestDistance) } or nil,
			},
		},
		onClick = fold.toggle,
	}
end

local function makeConsumerSection(result : ClosestConsumerNearest.CargoResult, params : ListParams, selectionState : ReactStateT<Selection>, fold : Fold) : TreeNodeId
	local header = makeCargoHeader(result.cargoType, nearestOf({ result.consumers }), fold)
	if not fold.expanded then
		return header
	end
	local children : {TreeNodeId} = { header }
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

local function makeSupplierSection(result : ClosestConsumerNearest.SupplyResult, params : ListParams, selectionState : ReactStateT<Selection>, fold : Fold) : TreeNodeId
	local header = makeCargoHeader(result.cargoType, nearestOf({ result.producers, result.warehouses }), fold)
	if not fold.expanded then
		return header
	end
	local children : {TreeNodeId} = { header }
	-- The sub-list labels only matter when both lists show.
	local hasWarehouses = #result.warehouses > 0
	if hasWarehouses then
		children[#children + 1] = makeLabel(_("Producers"), "font-scale-annotation")
	end
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
	if hasWarehouses then
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
	-- Cargo blocks the player opened, keyed "s<cargo>" / "c<cargo>"; every block starts collapsed.
	local foldState = react.useStateLazy(function() : {string : boolean}
		return {}
	end)
	local function makeFold(key : string) : Fold
		local expanded = foldState:old()[key] == true
		return {
			expanded = expanded,
			toggle = function()
				local next : {string : boolean} = {}
				for k, v in pairs(foldState:old()) do
					next[k] = v
				end
				next[key] = not expanded
				foldState:set(next)
			end,
		}
	end

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
					add(makeSupplierSection(result, params, selectionState, makeFold("s" .. tostring(result.cargoType))))
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
					add(makeConsumerSection(result, params, selectionState, makeFold("c" .. tostring(result.cargoType))))
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
