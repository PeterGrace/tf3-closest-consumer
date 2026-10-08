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

-- stock.cargoType is only set for pinned slots, so ask the engine per stock like the base warehouse window
-- (cargo_util.forEachCargoInStock). Prefer what is stored now; an empty warehouse falls back to what it accepts.
local function getWarehouseCargoTypes(entity : Engine.Entity, warehouse : Engine.Component.Warehouse, stockList : Engine.Component.StockList) : {CargoTypeId}
	local accepted : {CargoTypeId} = {}
	local stored : {CargoTypeId} = {}
	for i = 1, #stockList.stocks do
		local stockId = (i - 1) as StockId
		local counts : {string} = {}
		for _, cargoType in ipairs(api.engine.util.stock.getStockCargoTypes(warehouse.stockList, stockId)) do
			local count = api.engine.system.simEntityAtStockSystem.getStockCountForCargoType(warehouse.stockList, stockId, cargoType)
			counts[#counts + 1] = tostring(cargoType) .. "=" .. tostring(count)
			accepted[#accepted + 1] = cargoType
			if count > 0 then
				stored[#stored + 1] = cargoType
			end
		end
		debugPrint("[closest_consumer] debug warehouse " .. tostring(entity) .. " stock " .. tostring(stockId)
			.. " pinned=" .. tostring(stockList.stocks[i].cargoType) .. " types={" .. table.concat(counts, ",") .. "}")
	end
	return uniqueSorted(#stored > 0 and stored or accepted)
end

function nearest.getSourceCargoTypes(entity : Engine.Entity) : {CargoTypeId}
	local stockList = getStockList(entity)
	if stockList == nil then
		return {}
	end
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		return getWarehouseCargoTypes(entity, warehouse, stockList)
	end
	local outputs : {CargoTypeId} = {}
	for _, rule in ipairs(stockList.rules) do
		for cargoType, _ in pairs(rule.output) do
			outputs[#outputs + 1] = cargoType
		end
	end
	return uniqueSorted(outputs)
end

-- The engine's cargo logs are keyed by stock list entity. An industry is its own stock list entity,
-- but a warehouse's stock list is a separate entity (Warehouse.stockList).
local function getStockListEntity(entity : Engine.Entity) : Engine.Entity
	local warehouse = getWarehouse(entity)
	if warehouse ~= nil then
		return warehouse.stockList
	end
	return entity
end

-- TEMPORARY: identify an entity by its components and name.
local function describeEntity(entity : Engine.Entity) : string
	local kinds : {string} = {}
	local types : {{string, Engine.ComponentType}} = {
		{ "industry", api.type.ComponentType.INDUSTRY },
		{ "warehouse", api.type.ComponentType.WAREHOUSE },
		{ "station", api.type.ComponentType.STATION },
		{ "stationGroup", api.type.ComponentType.STATION_GROUP },
		{ "town", api.type.ComponentType.TOWN },
		{ "townBuilding", api.type.ComponentType.TOWN_BUILDING },
		{ "construction", api.type.ComponentType.CONSTRUCTION },
		{ "stockList", api.type.ComponentType.STOCK_LIST },
	}
	for _, kind in ipairs(types) do
		if api.engine.getComponent(entity, kind[2]) ~= nil then
			kinds[#kinds + 1] = kind[1]
		end
	end
	return tostring(entity) .. "[" .. table.concat(kinds, "/") .. " '" .. tostring(api.engine.util.getEntityName(entity)) .. "']"
end

-- TEMPORARY: dump a log book's own log names and each related entity with its log names.
local function dumpLogBook(label : string, entity : Engine.Entity)
	local ok, result = pcall(function() : string
		local logBook : Engine.Component.LogBook = api.engine.getComponent(entity, api.type.ComponentType.LOG_BOOK)
		if logBook == nil then
			return describeEntity(entity) .. " has no LOG_BOOK"
		end
		local names : {string} = {}
		for name, _ in pairs(logBook.name2log_native:asTable()) do
			names[#names + 1] = name
		end
		table.sort(names)
		local refs : {string} = {}
		for ref, name2log in pairs(logBook.refEntity2name2log) do
			local refNames : {string} = {}
			for name, _ in pairs(name2log) do
				refNames[#refNames + 1] = name
			end
			table.sort(refNames)
			refs[#refs + 1] = describeEntity(ref) .. "{" .. table.concat(refNames, ",") .. "}"
		end
		return describeEntity(entity) .. " names={" .. table.concat(names, ",") .. "} refs=" .. tostring(#refs) .. " " .. table.concat(refs, " ")
	end)
	debugPrint("[closest_consumer] debug logbook " .. label .. (ok and " " or " failed: ") .. tostring(result))
end

-- TEMPORARY: logs every way of reading a warehouse's flow so the in-game log shows which ids the engine uses.
local function probeWarehouseFlow(source : Engine.Entity, consumer : Engine.Entity, cargoType : CargoTypeId, consumerIsTown : boolean)
	local stockListEntity = getStockListEntity(source)
	local stock = api.engine.util.stock
	local function targets(from : Engine.Entity) : string
		local seen : {string} = {}
		stock.getCargoLogPerYearForTargetFilter(from, function(target : Engine.Entity) : boolean
			seen[#seen + 1] = tostring(target)
			return true
		end, "itemsTransported", cargoType)
		return table.concat(seen, ",")
	end
	local line = "[closest_consumer] debug flow warehouse=" .. tostring(source) .. " stockList=" .. tostring(stockListEntity)
		.. " consumer=" .. tostring(consumer) .. " isTown=" .. tostring(consumerIsTown) .. " cargo=" .. tostring(cargoType)
		.. " fwd(warehouse)=" .. tostring(stock.getCargoLogPerYearForTarget(source, consumer, "itemsTransported", cargoType))
		.. " fwd(stockList)=" .. tostring(stock.getCargoLogPerYearForTarget(stockListEntity, consumer, "itemsTransported", cargoType))
		.. " targets(stockList)={" .. targets(stockListEntity) .. "}"
		.. " shipped(stockList)=" .. tostring(stock.getCargoTypeShippedPerYear(stockListEntity, cargoType))
		.. " delivered(stockList)=" .. tostring(stock.getCargoTypeDeliveredPerYear(stockListEntity, cargoType))
	if consumerIsTown then
		line = line .. " town(warehouse)=" .. tostring(stock.getCargoLogPerYearForTarget(consumer, source, "itemsTransported", cargoType))
			.. " town(stockList)=" .. tostring(stock.getCargoLogPerYearForTarget(consumer, stockListEntity, "itemsTransported", cargoType))
			.. " townSources={" .. targets(consumer) .. "}"
	end
	debugPrint(line)
	dumpLogBook("source", source)
	dumpLogBook("consumer", consumer)
end

-- Mirrors cargo_util.getCargoFlowCount, but resolves the source to its stock list entity so warehouses work.
function nearest.getFlowCount(source : Engine.Entity, consumer : Engine.Entity, cargoType : CargoTypeId, consumerIsTown : boolean) : integer
	if getWarehouse(source) ~= nil then
		probeWarehouseFlow(source, consumer, cargoType, consumerIsTown)
	end
	local from = getStockListEntity(source)
	if consumerIsTown then
		return api.engine.util.stock.getCargoLogPerYearForTarget(consumer, from, "itemsTransported", cargoType)
	end
	return api.engine.util.stock.getCargoLogPerYearForTarget(from, consumer, "itemsTransported", cargoType)
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
