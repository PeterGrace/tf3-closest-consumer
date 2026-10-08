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

function rank.formatDistance(metres : number) : string
	local rounded = math.floor(metres + 0.5)
	if rounded < 1000 then
		return string.format("%d m", rounded)
	end
	return string.format("%.1f km", metres / 1000)
end

return rank
