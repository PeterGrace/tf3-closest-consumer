local t = ...
local rank = t.requireTl("gui/closest_consumer/rank.tl")

local function c(entity, name, x, y, isTown)
	return { entity = entity, name = name, x = x, y = y, isTown = isTown or false }
end

t.test("formatDistance: metres below 1 km", function()
	t.eq(rank.formatDistance(0), "0 m")
	t.eq(rank.formatDistance(850.4), "850 m")
	t.eq(rank.formatDistance(999.4), "999 m")
end)

t.test("formatDistance: kilometres with one decimal", function()
	t.eq(rank.formatDistance(999.6), "1.0 km")
	t.eq(rank.formatDistance(4210), "4.2 km")
	t.eq(rank.formatDistance(11349), "11.3 km")
end)

t.test("nearest: sorts ascending by planar distance", function()
	local r = rank.nearest(0, 0, { c(1, "far", 300, 400), c(2, "near", 3, 4), c(3, "mid", 30, 40) }, 3)
	t.eq(#r, 3)
	t.eq(r[1].entity, 2)
	t.eq(r[1].distance, 5)
	t.eq(r[2].entity, 3)
	t.eq(r[3].entity, 1)
	t.eq(r[3].distance, 500)
end)

t.test("nearest: measures from the source position", function()
	local r = rank.nearest(100, 100, { c(1, "a", 0, 0), c(2, "b", 103, 104) }, 3)
	t.eq(r[1].entity, 2)
	t.eq(r[1].distance, 5)
end)

t.test("nearest: limits the result count", function()
	local r = rank.nearest(0, 0, { c(1, "a", 1, 0), c(2, "b", 2, 0), c(3, "c", 3, 0), c(4, "d", 4, 0) }, 3)
	t.eq(#r, 3)
	t.eq(r[3].entity, 3)
end)

t.test("nearest: fewer candidates than limit returns all", function()
	t.eq(#rank.nearest(0, 0, { c(1, "a", 1, 0) }, 3), 1)
	t.eq(#rank.nearest(0, 0, {}, 3), 0)
end)

t.test("nearest: ties broken by name", function()
	local r = rank.nearest(0, 0, { c(1, "Zeta", 0, 10), c(2, "Alpha", 10, 0) }, 3)
	t.eq(r[1].name, "Alpha")
	t.eq(r[2].name, "Zeta")
end)

t.test("nearest: carries town flag and name through", function()
	local r = rank.nearest(0, 0, { c(7, "Esslingen", 1, 0, true) }, 3)
	t.eq(r[1].isTown, true)
	t.eq(r[1].name, "Esslingen")
	t.eq(r[1].entity, 7)
end)
