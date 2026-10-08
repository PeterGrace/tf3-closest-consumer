local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local industry_eow = ug_require "::/gui/entity_window/industry/industry_eow.script.tl" as IndustryEow
local warehouse_eow = ug_require "::/gui/entity_window/warehouse/warehouse_eow.script.tl" as WarehouseEow

debugPrint("[closest_consumer] script loaded")

local IndustryPlugin = react.RegisterPluginRecipe(industry_eow.IndustryEowExtensionPoint, "ClosestConsumerIndustryPlugin", function(params : IndustryEow.IndustryWidgetPluginParams) : TreeNodeId
	return builtin.TextView{ text = "Closest consumer: hello (industry " .. tostring(params.entityId) .. ")" }
end)

local WarehousePlugin = react.RegisterPluginRecipe(warehouse_eow.WarehouseEowExtensionPoint, "ClosestConsumerWarehousePlugin", function(params : WarehouseEow.WarehouseWidgetPluginParams) : TreeNodeId
	return builtin.TextView{ text = "Closest consumer: hello (warehouse " .. tostring(params.entityId) .. ")" }
end)

return {
	IndustryPlugin = IndustryPlugin,
	WarehousePlugin = WarehousePlugin,
}
