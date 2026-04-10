local LuaEntity_deserialize = require("modules/universal_edges/universal_serializer/classes/LuaEntity_deserialize")
local constants = require("modules/universal_edges/constants")

local TRAIN_TYPES = {
	["cargo-wagon"] = true,
	["locomotive"] = true,
	["artillery-wagon"] = true,
	["fluid-wagon"] = true
}

-- called from control.lua on_tick handler every 15 ticks
local function spawn_delayed_entities()
	local delayed_entities = storage.universal_edges.delayed_entities
	for unit_number, train_entry in pairs(delayed_entities) do
		local front_stock = train_entry.front_stock
		if not (front_stock and front_stock.valid) then
			-- Train no longer exists, discard all its delayed entities
			delayed_entities[unit_number] = nil
		else
			local entities = train_entry.entities
			local i = 1
			while i <= #entities do
				local delayed_entity = entities[i]
				if not TRAIN_TYPES[delayed_entity.type] then
					log("universal_edges: undefined delayed entity type: " .. delayed_entity.type)
					table.remove(entities, i)
				else
					-- Save train state before connecting a new carriage resets it
					local manual_mode = front_stock.train.manual_mode
					local speed = front_stock.train.speed
					local schedule = front_stock.train.schedule

					delayed_entity.position = get_position_behind_train(front_stock, 7)

					-- Clamp: don't spawn if target is too deep into the parking area (prevents bridging to proxy trains)
					if delayed_entity.front_stock_origin and delayed_entity.position then
						local MAX_DEPTH = constants.MAX_TRAIN_LENGTH * 7
						local origin = delayed_entity.front_stock_origin
						local pos = delayed_entity.position
						local distance = math.sqrt((pos.x - origin.x)^2 + (pos.y - origin.y)^2)
						if distance > MAX_DEPTH then
							break -- Stop this train, continue to next train
						end
					end

					local created_entity = LuaEntity_deserialize(delayed_entity)
					if created_entity then
						front_stock.train.manual_mode = manual_mode
						front_stock.train.schedule = schedule
						front_stock.train.speed = speed
						-- Re-seat driver if this carriage had one
						if delayed_entity.driver_name then
							storage.universal_edges.vehicle_drivers[delayed_entity.driver_name] = created_entity
						end
						table.remove(entities, i)
					else
						break -- No space yet for this train, continue to next train
					end
				end
			end
			-- If all entities spawned, remove the train entry
			if #entities == 0 then
				delayed_entities[unit_number] = nil
			end
		end
	end
end

---@param entity LuaEntity
---@param spacing number|nil -- optional, defaults to 7
---@return MapPosition|nil
function get_position_behind_train(entity, spacing)
    if not entity then return nil end
    if not entity.train.back_stock then return nil end

    local back_stock = entity.train.back_stock ---@cast back_stock -nil
    spacing = spacing or 7

    -- Convert orientation → unit vector
    local orientation = back_stock.orientation
    local angle = orientation * 2 * math.pi

    local dx = math.sin(angle)
    local dy = -math.cos(angle)

    -- Offset behind the last rolling stock
    local pos = {
        x = back_stock.position.x - dx * spacing,
        y = back_stock.position.y - dy * spacing
    }

    return pos
end


return spawn_delayed_entities
