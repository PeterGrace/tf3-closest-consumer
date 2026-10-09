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

local function getBoundingVolume(entity : Engine.Entity) : Engine.Component.BoundingVolume
	local bv : Engine.Component.BoundingVolume = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if bv == nil then
		local warehouse = getWarehouse(entity)
		if warehouse ~= nil then
			bv = api.engine.getComponent(warehouse.construction, api.type.ComponentType.BOUNDING_VOLUME)
		end
	end
	return bv
end

-- Centre of the bounding volume on the map plane, as the base industry window computes it.
local function getPosition(entity : Engine.Entity) : number, number
	local bv = getBoundingVolume(entity)
	if bv == nil then
		return nil, nil
	end
	return 0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y)
end

function nearest.getPosition3(entity : Engine.Entity) : Vec3f
	local bv = getBoundingVolume(entity)
	if bv == nil then
		return nil
	end
	return api.type.Vec3f.new(0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y), bv.bbox.max.z)
end

local function getName(entity : Engine.Entity) : string
	local name = api.engine.util.getEntityName(entity)
	if name == nil or name == "" then
		return _("Unnamed")
	end
	return name
end

-- Sorted, de-duplicated cargo type ids, ignoring the "none" marker (-1).
local function uniqueSorted(cargoTypes : {CargoTypeId}) : {CargoTypeId}
	local seen : {CargoTypeId : boolean} = {}
	local result : {CargoTypeId} = {}
	for _, cargoType in ipairs(cargoTypes) do
		if cargoType >= 0 and not seen[cargoType] then
			seen[cargoType] = true
			result[#result + 1] = cargoType
		end
	end
	table.sort(result)
	return result
end

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

function nearest.getSourceCargoTypes(entity : Engine.Entity) : {CargoTypeId}
	local stockList = getStockList(entity)
	if stockList == nil then
		return {}
	end
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		return getWarehouseCargoTypes(warehouse, stockList)
	end
	local outputs : {CargoTypeId} = {}
	for _, rule in ipairs(stockList.rules) do
		for cargoType, _ in pairs(rule.output) do
			outputs[#outputs + 1] = cargoType
		end
	end
	return uniqueSorted(outputs)
end

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

local function collectCandidates(sourceEntity : Engine.Entity, cargoTypes : {CargoTypeId}) : {CargoTypeId : {ClosestConsumerRank.Candidate}}
	local byCargo = newByCargo(cargoTypes)

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
				addCandidate(byCargo, entity, cargoType, false)
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
					addCandidate(byCargo, townEntity, cargoType, true)
				end
			end
		end
	end, api.type.ComponentType.TOWN)

	return byCargo
end

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

return nearest
