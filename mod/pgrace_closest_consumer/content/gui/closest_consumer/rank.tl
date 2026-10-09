local rank : ClosestConsumerRank = {}

function rank.nearest(sourceX : number, sourceY : number, candidates : {ClosestConsumerRank.Candidate}, limit : integer) : {ClosestConsumerRank.Ranked}
	local all : {ClosestConsumerRank.Ranked} = {}
	for _, candidate in ipairs(candidates) do
		local dx = candidate.x - sourceX
		local dy = candidate.y - sourceY
		all[#all + 1] = {
			entity = candidate.entity,
			name = candidate.name,
			isTown = candidate.isTown,
			distance = math.sqrt(dx * dx + dy * dy),
		}
	end
	table.sort(all, function(a : ClosestConsumerRank.Ranked, b : ClosestConsumerRank.Ranked) : boolean
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.name < b.name
	end)
	local result : {ClosestConsumerRank.Ranked} = {}
	for i = 1, math.min(limit, #all) do
		result[i] = all[i]
	end
	return result
end

function rank.orderByNearest<T>(items : {T}, distanceOf : function(T) : number) : {T}
	local record Keyed
		item : T
		distance : number
		index : integer
	end
	local keyed : {Keyed} = {}
	for i, item in ipairs(items) do
		keyed[i] = { item = item, distance = distanceOf(item), index = i }
	end
	table.sort(keyed, function(a : Keyed, b : Keyed) : boolean
		if a.distance ~= b.distance then
			if a.distance == nil or b.distance == nil then
				return b.distance == nil
			end
			return a.distance < b.distance
		end
		return a.index < b.index
	end)
	local result : {T} = {}
	for i, entry in ipairs(keyed) do
		result[i] = entry.item
	end
	return result
end

function rank.formatDistance(metres : number) : string
	local rounded = math.floor(metres + 0.5)
	if rounded < 1000 then
		return string.format("%d m", rounded)
	end
	return string.format("%.1f km", metres / 1000)
end

return rank
