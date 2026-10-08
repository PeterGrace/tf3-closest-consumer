global record ClosestConsumerNearest
	record CargoResult
		cargoType : CargoTypeId
		consumers : {ClosestConsumerRank.Ranked}
	end

	-- Bounding-box centre (x, y) at the box top (z), as the base industry window computes flow endpoints; nil if unknown.
	getPosition3 : function(entity : Engine.Entity) : Vec3f
	-- Cargo types the entity sends out: industry rule outputs; for a warehouse, what it stores now, or if empty what its stocks accept.
	getSourceCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
	-- For each source cargo type (sorted by id), the nearest `limit` consumers. Warehouses and the source are never consumers.
	findNearestConsumers : function(entity : Engine.Entity, limit : integer) : {CargoResult}
end
