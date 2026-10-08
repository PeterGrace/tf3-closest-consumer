local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local cargo_react_util = ug_require "::/gui/main/cargo_react_util.tl" as CargoReactUtil
local cargo_util = ug_require "::/gui/main/cargo_util.tl" as CargoUtil
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow
local nearest = ug_require "pgrace_closest_consumer::/gui/closest_consumer/nearest.tl" as ClosestConsumerNearest
local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

debugPrint("[closest_consumer] script loaded")

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors

local RESULT_LIMIT = 3
local FLOW_ACTION_KEY = "closest_consumer_flow"
local CAMERA_DISTANCE_FACTOR = 1.2
local CAMERA_MIN_DISTANCE = 500

local record ListParams
	entityId : Engine.Entity
	isWarehouse : boolean
	gameCtx : GameContext
end

-- The consumer whose flow arrow is shown; nil when none is.
local record Selection
	consumer : Engine.Entity
	cargoType : CargoTypeId
end

local record FlowParams
	gameCtx : GameContext
	source : Engine.Entity
	selection : Selection
end

-- setActiveOwner exists on the renderer API (gui/main/builtin.lua calls it) but is missing from the type definitions.
local record ActiveOwnerApi
	setActiveOwner : function(ReactRefWrap)
end

local record FlowCache
	key : string
	action : function() : TreeNodeId
end

local record ListState
	results : {ClosestConsumerNearest.CargoResult}
	failed : boolean
end

local function computeState(entity : Engine.Entity) : ListState
	local ok, resultsOrError = pcall(nearest.findNearestConsumers, entity, RESULT_LIMIT)
	if ok then
		return { results = resultsOrError as {ClosestConsumerNearest.CargoResult}, failed = false }
	end
	debugPrint("[closest_consumer] error for entity " .. tostring(entity) .. ": " .. tostring(resultsOrError))
	return { results = {}, failed = true }
end

local function makeHint(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-annotation" }, text = text }
end

local function makeFlowLayerConfig(from : Vec3f, to : Vec3f, cargoType : CargoTypeId) : LayerConfig
	local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
	flow.from = from
	flow.to = to
	flow.speed = 40.0
	flow.arrowColors = color_util.toArray4(layerColors.CargoFlow.Consumers3D.Actual)
	flow.cargoIconAlpha = 1.0
	flow.cargoTypes = { cargoType }
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = { flow }
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local dx = to.x - from.x
	local dy = to.y - from.y
	local gap = math.sqrt(dx * dx + dy * dy)
	local distance = math.max(CAMERA_MIN_DISTANCE, gap * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	debugPrint("[closest_consumer] camera gap=" .. tostring(gap) .. " distance=" .. tostring(distance))
	api.gui.camera.focusPosition(midpoint, distance)
end

-- Binds a map action that draws one flow arrow and makes it the renderer's active owner.
-- Unmounting unbinds it, which should hand the map back to the industry window's own action.
local FlowAction = react.RegisterRecipe("ClosestConsumerFlowAction", function(params : FlowParams) : TreeNodeId
	local key = tostring(params.source) .. ">" .. tostring(params.selection.consumer) .. ":" .. tostring(params.selection.cargoType)
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = nearest.getPosition3(params.source)
		local to = nearest.getPosition3(params.selection.consumer)
		local action : function() : TreeNodeId = nil
		if from ~= nil and to ~= nil then
			action = selector_react_util.makeDefaultSelectorAction(params.gameCtx, makeFlowLayerConfig(from, to, params.selection.cargoType))
			frameCamera(from, to)
		else
			debugPrint("[closest_consumer] flow: no position for " .. key)
		end
		cacheRef:set({ key = key, action = action })
	end

	local selfRef = react.useAction(params.gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY)

	local function activate()
		local rc = params.gameCtx.rendererComponent:get()
		if rc ~= nil and rc:getIdentity() then
			(rc:getApi() as any as ActiveOwnerApi).setActiveOwner(selfRef)
			debugPrint("[closest_consumer] flow on " .. key)
		end
	end

	react.onMount(activate)
	if changed and cacheRef:get().action ~= nil and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		debugPrint("[closest_consumer] flow off " .. key)
	end)

	return builtin.BoxLayout{ children = {} }
end)

local function makeConsumerRow(consumer : ClosestConsumerRank.Ranked, cargoType : CargoTypeId, selectionState : ReactStateT<Selection>) : TreeNodeId
	local label = consumer.name
	if consumer.isTown then
		label = label .. " " .. _("(town)")
	end
	local current = selectionState:old()
	local isSelected = current ~= nil and current.consumer == consumer.entity and current.cargoType == cargoType
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = consumer.entity },
			builtin.ToggleButton{
				meta = { tooltip = _("Show this flow on the map") },
				content = builtin.ImageView{
					path = "::/gui/component/slim_arrow_right.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				value = isSelected and 1 or 0,
				onValueChange = function(value : integer)
					if value == 1 then
						selectionState:set({ consumer = consumer.entity, cargoType = cargoType })
					else
						selectionState:set(nil)
					end
				end,
			},
			line_react_util.makeEntityWindowButton(label, consumer.entity),
			builtin.TextView{ text = rank.formatDistance(consumer.distance) },
		},
	}
end

local function makeCargoSection(result : ClosestConsumerNearest.CargoResult, selectionState : ReactStateT<Selection>) : TreeNodeId
	local children : {TreeNodeId} = {
		builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				cargo_react_util.makeCargoIcon(result.cargoType),
				builtin.TextView{ text = cargo_util.getCargoNameById(result.cargoType) },
			},
		},
	}
	if #result.consumers == 0 then
		children[#children + 1] = makeHint(_("No consumers on this map"))
	else
		for _, consumer in ipairs(result.consumers) do
			children[#children + 1] = makeConsumerRow(consumer, result.cargoType, selectionState)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local NearestConsumersList = react.RegisterRecipe("ClosestConsumerList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params.entityId)
	end)
	local current = state:old()
	local selectionState = react.useStateLazy(function() : Selection
		return nil
	end)

	local children : {TreeNodeId} = {}
	if current.failed then
		children[1] = makeHint(_("Closest consumer: error (see log)"))
	elseif #current.results == 0 then
		children[1] = makeHint(params.isWarehouse and _("No cargo assigned") or _("No outputs"))
	else
		for _, result in ipairs(current.results) do
			children[#children + 1] = makeCargoSection(result, selectionState)
		end
	end
	if selectionState:old() ~= nil then
		children[#children + 1] = FlowAction{
			gameCtx = params.gameCtx,
			source = params.entityId,
			selection = selectionState:old(),
		}
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end)

local function makeCard(entityId : Engine.Entity, isWarehouse : boolean, gameCtx : GameContext, showOnRightSide : boolean) : TreeNodeId
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("Nearest consumers"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(NearestConsumersList, {
				entityId = entityId,
				isWarehouse = isWarehouse,
				gameCtx = gameCtx,
			} as ListParams),
			gameCtx = gameCtx,
			showOnRightSide = showOnRightSide,
		},
	}
end

local IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "ClosestConsumerIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return makeCard(params.entityId, false, params.gameCtx, params.showCalloutOnRightSide)
end)

local WarehousePlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "ClosestConsumerWarehousePlugin", function(params : WarehouseEow.WarehouseWidgetPluginParams) : TreeNodeId
	return makeCard(params.entityId, true, params.gameCtx, params.showCalloutOnRightSide)
end)

-- Hides the card for industries that produce nothing (e.g. pure consumers).
-- On error it returns true, so that the card can show the error hint.
local function hasOutputs(params : IndustryEow.IndustryWidgetPluginParams) : boolean
	local ok, cargoTypes = pcall(nearest.getSourceCargoTypes, params.entityId)
	return not ok or #(cargoTypes as {CargoTypeId}) > 0
end

return {
	IndustryPlugin = IndustryPlugin,
	WarehousePlugin = WarehousePlugin,
	hasOutputs = hasOutputs,
}
