local rank = ug_require "pgrace_closest_consumer::/gui/closest_consumer/rank.tl" as ClosestConsumerRank

local nearest : ClosestConsumerNearest = {}

local function getWarehouse(entity : Engine.Entity) : Engine.Component.Warehouse
	return api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
end

local function getStockList(entity : Engine.Entity) : Engine.Component.StockList
	local stockList : Engine.Component.StockList = api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
	if stockList ~= nil then
		return stockList
	end
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		return api.engine.getComponent(warehouse.stockList, api.type.ComponentType.STOCK_LIST)
	end
	return nil
end

-- Centre of the bounding volume on the map plane, as the base industry window computes it.
local function getPosition(entity : Engine.Entity) : number, number
	local bv : Engine.Component.BoundingVolume = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if bv == nil then
		local warehouse = getWarehouse(entity)
		if warehouse ~= nil then
			bv = api.engine.getComponent(warehouse.construction, api.type.ComponentType.BOUNDING_VOLUME)
		end
	end
	if bv == nil then
		return nil, nil
	end
	return 0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y)
end

local function getName(entity : Engine.Entity) : string
	local name = api.engine.util.getEntityName(entity)
	if name == nil or name == "" then
		return _("Unnamed")
	end
	return name
end

function nearest.getSourceCargoTypes(entity : Engine.Entity) : {CargoTypeId}
	local stockList = getStockList(entity)
	if stockList == nil then
		return {}
	end
	local seen : {CargoTypeId : boolean} = {}
	local result : {CargoTypeId} = {}
	local function add(cargoType : CargoTypeId)
		if cargoType >= 0 and not seen[cargoType] then
			seen[cargoType] = true
			result[#result + 1] = cargoType
		end
	end
	if getWarehouse(entity) ~= nil then
		for _, stock in ipairs(stockList.stocks) do
			add(stock.cargoType)
		end
	else
		for _, rule in ipairs(stockList.rules) do
			for cargoType, _ in pairs(rule.output) do
				add(cargoType)
			end
		end
	end
	table.sort(result)
	return result
end

local function collectCandidates(sourceEntity : Engine.Entity, cargoTypes : {CargoTypeId}) : {CargoTypeId : {ClosestConsumerRank.Candidate}}
	local byCargo : {CargoTypeId : {ClosestConsumerRank.Candidate}} = {}
	for _, cargoType in ipairs(cargoTypes) do
		byCargo[cargoType] = {}
	end

	local function add(entity : Engine.Entity, cargoType : CargoTypeId, isTown : boolean)
		local x, y = getPosition(entity)
		if x == nil then
			return
		end
		local list = byCargo[cargoType]
		list[#list + 1] = { entity = entity, name = getName(entity), isTown = isTown, x = x, y = y }
	end

	local inputStock = api.type["enum"].StockListType.InputStock
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if entity == sourceEntity or getWarehouse(entity) ~= nil then
			return
		end
		local stockList : Engine.Component.StockList = api.engine.getComponent(entity, api.type.ComponentType.STOCK_LIST)
		if stockList == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		for _, stock in ipairs(stockList.stocks) do
			local cargoType = stock.cargoType
			if byCargo[cargoType] ~= nil and not added[cargoType] and stock.type == inputStock then
				added[cargoType] = true
				add(entity, cargoType, false)
			end
		end
	end, api.type.ComponentType.INDUSTRY)

	api.engine.forEachEntityWithComponent(function(townEntity : Engine.Entity)
		local town : Engine.Component.Town = api.engine.getComponent(townEntity, api.type.ComponentType.TOWN)
		if town == nil then
			return
		end
		local added : {CargoTypeId : boolean} = {}
		for _, needs in ipairs(town.cargoNeeds) do
			for _, cargoAndLevel in ipairs(needs) do
				local cargoType = cargoAndLevel[1]
				if byCargo[cargoType] ~= nil and not added[cargoType] then
					added[cargoType] = true
					add(townEntity, cargoType, true)
				end
			end
		end
	end, api.type.ComponentType.TOWN)

	return byCargo
end

function nearest.findNearestConsumers(entity : Engine.Entity, limit : integer) : {ClosestConsumerNearest.CargoResult}
	local cargoTypes = nearest.getSourceCargoTypes(entity)
	if #cargoTypes == 0 then
		return {}
	end
	local sourceX, sourceY = getPosition(entity)
	if sourceX == nil then
		error("no position for entity " .. tostring(entity))
	end
	local byCargo = collectCandidates(entity, cargoTypes)
	local results : {ClosestConsumerNearest.CargoResult} = {}
	for _, cargoType in ipairs(cargoTypes) do
		results[#results + 1] = {
			cargoType = cargoType,
			consumers = rank.nearest(sourceX, sourceY, byCargo[cargoType], limit),
		}
	end
	return results
end

return nearest
