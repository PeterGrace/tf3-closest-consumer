global record ClosestConsumerNearest
	record CargoResult
		cargoType : CargoTypeId
		consumers : {ClosestConsumerRank.Ranked}
	end

	-- Cargo types the entity sends out: industry rule outputs, or a warehouse's assigned stock cargo types.
	getSourceCargoTypes : function(entity : Engine.Entity) : {CargoTypeId}
	-- For each source cargo type (sorted by id), the nearest `limit` consumers. Warehouses and the source are never consumers.
	findNearestConsumers : function(entity : Engine.Entity, limit : integer) : {CargoResult}
end
