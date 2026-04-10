local LuaEntity_serialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_serialize")
local LuaTrain_serialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_serialize")
local hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Serializes a complete LuaTrain object, including rolling stock
---@param LuaTrain LuaTrain
---@param carriages table<number, LuaEntity>
---@param edge UniversalEdge
---@return table
local function LuaTrainComplete_serialize(LuaTrain, carriages, edge, offset)
	local context = { LuaTrain = LuaTrain, carriages = carriages, edge = edge, offset = offset }
	hooks.run("LuaTrainComplete", "pre_serialize", {}, context)
	local train_data = {
		train = LuaTrain_serialize(LuaTrain, edge, offset), -- metadata
		carriages = {}, -- entities
	}

	local ordered_carriages = carriages or LuaTrain.carriages
	for _, carriage in ipairs(ordered_carriages) do
		local serialized_carriage = LuaEntity_serialize(carriage)
		-- Add passenger data
		if carriage.get_driver() and carriage.get_driver().player then
			serialized_carriage.driver_name = carriage.get_driver().player.name
		end
		train_data.carriages[#train_data.carriages + 1] = serialized_carriage
	end

	-- check for and stitch together any delayed carriages that have not been deserialized yet
	local unit_number = LuaTrain.front_stock.unit_number
	local delayed = storage.universal_edges.delayed_entities[unit_number]
	if delayed then
		for _, delayed_entity in ipairs(delayed.entities) do
			delayed_entity.front_stock = nil
			delayed_entity.front_stock_origin = nil
			train_data.carriages[#train_data.carriages + 1] = delayed_entity
		end
		storage.universal_edges.delayed_entities[unit_number] = nil
	end

	train_data = hooks.run("LuaTrainComplete", "post_serialize", train_data, context)

	return train_data
end

return LuaTrainComplete_serialize
