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
