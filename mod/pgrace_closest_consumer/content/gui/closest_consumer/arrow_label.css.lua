local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data

	-- The arrow label's floating layout fills the screen, so the label can be placed anywhere on it (as the game's
	-- "R::CalloutContainer FloatingLayout" rule does for callouts). Without it the layout shrinks to the label and sits
	-- at the left edge.
	a("R::ClosestConsumerArrowLabelLayer FloatingLayout", {
		gravity = { -1.0, -1.0 },
	})

	-- A light blue box with dark text, easier to spot on the map than the default dark callout. Scoped to our layer;
	-- other callouts keep the game's look (callout_container.css.lua).
	a("R::ClosestConsumerArrowLabelLayer R::DefaultCalloutWrapper R::Component!callout-content", {
		backgroundColor1 = colorDefault.AccentLight,
	})
	a("R::ClosestConsumerArrowLabelLayer R::DefaultCalloutWrapper ImageView!callout-arrow", {
		color = colorDefault.AccentLight,
		gravity = { 0.5, 0 },
	})
	a("R::ClosestConsumerArrowLabelLayer R::ClosestConsumerArrowLabel TextView", {
		color = colorDefault.NeutralDarkest,
	})

	return result
end
