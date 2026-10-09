function data()
	return {
		type = "react-plugin ::IndustryEowExtensionPoint",
		data = {
			filePath = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@IndustryPlugin",
			condition = "pgrace_closest_consumer::/gui/closest_consumer/closest_consumer.script@hasCargo",
			order = 35,
		}
	}
end
