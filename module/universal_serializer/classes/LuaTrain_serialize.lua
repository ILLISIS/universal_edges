local hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Remove schedule records that reference a rail entity (temporary waypoints)
-- since rail entities can't be transferred across servers.
local function filter_rail_records(schedule)
	if not schedule or not schedule.records then return schedule end
	local filtered = {}
	for _, record in pairs(schedule.records) do
		if not record.rail then
			filtered[#filtered + 1] = record
		end
	end
	if #filtered == 0 then return {} end
	schedule.records = filtered
	-- Clamp current index to new bounds
	if schedule.current > #filtered then
		schedule.current = 1
	end
	return schedule
end

-- Serializes a LuaTrain object.
---@param train LuaTrain
---@return table
local function LuaTrain_serialize(train, edge, offset)
	local context = { train = train, edge = edge, offset = offset }
	hooks.run("LuaTrain", "pre_serialize", {}, context)

	local train_schedule = train.get_schedule()
	local train_data = {
		manual_mode = train.manual_mode,
		speed = train.speed,
		schedule = filter_rail_records(train.schedule),
		interrupts = train_schedule.get_interrupts()
	}

	train_data = hooks.run("LuaTrain", "post_serialize", train_data, context)

	return train_data
end

return LuaTrain_serialize
