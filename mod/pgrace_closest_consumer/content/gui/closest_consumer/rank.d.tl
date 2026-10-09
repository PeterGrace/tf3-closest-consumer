global record ClosestConsumerRank
	record Candidate
		entity : Engine.Entity
		name : string
		isTown : boolean
		x : number
		y : number
	end

	record Ranked
		entity : Engine.Entity
		name : string
		isTown : boolean
		distance : number
	end

	-- Sorts candidates by straight-line (x, y) distance to the source; returns at most `limit`.
	nearest : function(sourceX : number, sourceY : number, candidates : {Candidate}, limit : integer) : {Ranked}
	-- A sorted copy of `items`, nearest first by `distanceOf`; items without a distance (nil) go last. Ties keep input order.
	orderByNearest : function<T>(items : {T}, distanceOf : function(T) : number) : {T}
	-- "850 m" below one kilometre, otherwise "4.2 km".
	formatDistance : function(metres : number) : string
end
