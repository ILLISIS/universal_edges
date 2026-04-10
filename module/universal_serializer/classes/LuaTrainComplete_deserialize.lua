local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local LuaTrain_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaTrain_deserialize")
local hooks = require("modules/universal_edges/universal_serializer/hooks")

-- Deserializes a complete LuaTrain object, including rolling stock
---@param train_data table
---@return LuaEntity | nil
local function LuaTrainComplete_deserialize(train_data)
	local context = {}
	train_data = hooks.run("LuaTrainComplete", "pre_deserialize", train_data, context)

	local MAX_SPAWN = 12
	local spawn_count = 0
	local first_locomotive
	local front_stock -- tracks the first successfully spawned rolling stock, used as a reference for delayed carriages
	local front_stock_origin -- snapshot of front_stock position at creation time, used as fixed reference for distance clamping
	for _, carriage in ipairs(train_data.carriages) do
		local entity
		if spawn_count < MAX_SPAWN then
			entity = LuaEntity_deserialize(carriage)
		end

		if not entity then
			if not front_stock then
				game.print("[FATAL] train was able to spawn and has therefre been lost")
				return
			end
			-- Entity could not be created (no room or spawn limit reached), delay for on_tick retry
			carriage.front_stock = front_stock
			carriage.front_stock_origin = front_stock_origin
			local unit_number = front_stock.unit_number
			if not storage.universal_edges.delayed_entities[unit_number] then
				storage.universal_edges.delayed_entities[unit_number] = {
					front_stock = front_stock,
					entities = {}
				}
			end
			table.insert(storage.universal_edges.delayed_entities[unit_number].entities, carriage)
		else
			spawn_count = spawn_count + 1
			if not front_stock then
				front_stock = entity
				front_stock_origin = {x = entity.position.x, y = entity.position.y}
			end

			-- Store vehicle entity under player name to re-seat after cross-instance teleport
			if carriage.driver_name then
				storage.universal_edges.vehicle_drivers[carriage.driver_name] = entity
			end

			if entity.type == "locomotive" and not first_locomotive then
				first_locomotive = entity
			end
		end
	end

	-- Set train state once after all immediate spawns complete
	if first_locomotive then
		LuaTrain_deserialize(first_locomotive, train_data.train)
	end

	context.first_locomotive = first_locomotive
	context.front_stock = front_stock
	hooks.run("LuaTrainComplete", "post_deserialize", train_data, context)

	return first_locomotive
end

return LuaTrainComplete_deserialize
