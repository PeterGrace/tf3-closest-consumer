local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local cargo_react_util = ug_require "::/gui/main/cargo_react_util.tl" as CargoReactUtil
local cargo_util = ug_require "::/gui/main/cargo_util.tl" as CargoUtil
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow
local nearest = ug_require "pgrace_closest_consumer::/gui/closest_consumer/nearest.tl" as ClosestConsumerNearest
local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

debugPrint("[closest_consumer] script loaded")

local RESULT_LIMIT = 3

local record ListParams
	entityId : Engine.Entity
	isWarehouse : boolean
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

local function makeConsumerRow(consumer : ClosestConsumerRank.Ranked) : TreeNodeId
	local label = consumer.name
	if consumer.isTown then
		label = label .. " " .. _("(town)")
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			line_react_util.LocateButton{ entity = consumer.entity },
			line_react_util.makeEntityWindowButton(label, consumer.entity),
			builtin.TextView{ text = rank.formatDistance(consumer.distance) },
		},
	}
end

local function makeCargoSection(result : ClosestConsumerNearest.CargoResult) : TreeNodeId
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
			children[#children + 1] = makeConsumerRow(consumer)
		end
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
end

local NearestConsumersList = react.RegisterRecipe("ClosestConsumerList", function(params : ListParams) : TreeNodeId
	local state = react.useStateLazy(function() : ListState
		return computeState(params.entityId)
	end)
	local current = state:old()

	local children : {TreeNodeId} = {}
	if current.failed then
		children[1] = makeHint(_("Closest consumer: error (see log)"))
	elseif #current.results == 0 then
		children[1] = makeHint(params.isWarehouse and _("No cargo assigned") or _("No outputs"))
	else
		for _, result in ipairs(current.results) do
			children[#children + 1] = makeCargoSection(result)
		end
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
