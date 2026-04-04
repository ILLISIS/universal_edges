local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")
local util = require("modules/universal_edges/util")
local edge_util = require("modules/universal_edges/edge/util")
local universal_serializer = require("modules/universal_edges/universal_serializer/universal_serializer")
local train_box = require("modules/universal_edges/edge/train/train_box")

-- Normalize Factorio positions which can be either {x=, y=} or {[1], [2]} format
local function get_position_components(position)
	local x = position.x or position[1]
	local y = position.y or position[2]
	return x, y
end

-- Calculate distance between the first two carriages to determine spacing for train placement
local function calculate_carriage_spacing(carriages)
	if #carriages < 2 then return nil end
	local ax, ay = get_position_components(carriages[1].position)
	local bx, by = get_position_components(carriages[2].position)
	local dx = ax - bx
	local dy = ay - by
	return math.sqrt(dx * dx + dy * dy)
end

-- Snap a continuous orientation value to the nearest cardinal direction (N/E/S/W)
local function snap_orientation(orientation)
	if orientation == nil then
		return nil
	end
	local snapped = math.floor((orientation + 0.125) / 0.25) * 0.25
	snapped = snapped % 1
	if snapped < 0 then
		snapped = snapped + 1
	end
	return snapped
end

-- Convert a snapped orientation (0, 0.25, 0.5, 0.75) to a Factorio defines.direction
local function orientation_to_direction(orientation)
	if orientation == 0 then return defines.direction.north end
	if orientation == 0.25 then return defines.direction.east end
	if orientation == 0.5 then return defines.direction.south end
	if orientation == 0.75 then return defines.direction.west end
	return nil
end

-- Remove a link whose signal entity has become invalid (e.g. destroyed by editor or mod conflict)
local function cleanup_invalid_link(offset, link, edge)
	if link.is_input then
		train_box.remove_source(offset, edge)
	else
		train_box.remove_destination(offset, edge)
	end
end

-- Draw debug text at the input link showing flow status ("Destination blocked" or debug info)
local function update_input_debug_visu(offset, link, edge)
	if link.debug_visu then
		for _, visu in pairs(link.debug_visu) do
			if visu.valid then visu.destroy() end
		end
	end
	link.debug_visu = {}

	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]
	local pos = edge_util.edge_pos_to_world({ edge_x, 0 }, edge)

	if link.set_flow == false then
		link.debug_visu[1] = rendering.draw_text {
			text = "Destination blocked",
			surface = surface,
			target = pos,
			color = { r = 1, g = 1, b = 1 },
			scale = 1.5,
		}
	elseif link.set_flow == nil then
		link.debug_visu[1] = rendering.draw_text {
			text = "offset: " .. offset .. " signal: " .. link.signal.signal_state .. " flow: nil",
			surface = surface,
			target = pos,
			color = { r = 1, g = 1, b = 1 },
			scale = 1.5,
		}
	end
end

-- Check if conditions are met to capture a train: flow must be enabled and the signal must have
-- just turned red (train arrived) or flow just re-opened while a train is already waiting
local function should_capture_train(link, signal_state)
	if not link.set_flow then return false end
	if signal_state ~= defines.signal_state.closed then return false end
	-- Signal just turned red, or flow just re-enabled while signal is red
	return signal_state ~= link.previous_signal_state
		or link.previous_flow_state == false
end

-- Return carriages ordered front-to-back. Factorio's carriage order isn't guaranteed to
-- start from front_stock, so reverse if needed to ensure consistent serialization
local function order_carriages(luaTrain)
	local carriages = luaTrain.carriages
	if luaTrain.front_stock and carriages[1] ~= luaTrain.front_stock then
		local reversed = {}
		for i = #carriages, 1, -1 do
			reversed[#reversed + 1] = carriages[i]
		end
		return reversed
	end
	return carriages
end

-- Find a train in the parking area, serialize it with edge-relative coordinates, and return
-- a transfer payload ready to send to the partner instance
---@param offset number
---@param link table
---@param edge UniversalEdge
---@return table|nil
local function capture_train(offset, link, edge)
	local edge_x = edge_util.offset_to_edge_x(offset, edge)
	local surface = game.surfaces[edge_util.edge_get_local_target(edge).surface]

	-- Find area filtered requires left_top to actually be in the left top.
	-- This means we have to handle rotations properly
	local area = util.realign_area(
		edge_util.edge_pos_to_world({
			edge_x + 1,
			0,
		}, edge),
		edge_util.edge_pos_to_world({
			edge_x - 1,
			1 - link.parking_area_size * 2
		}, edge)
	)

	rendering.draw_rectangle {
		left_top = area.left_top,
		right_bottom = area.right_bottom,
		surface = surface,
		color = { r = 1, g = 0.5, b = 0, a = 0.4 },
		filled = true,
		time_to_live = 120,
	}

	local entities = surface.find_entities_filtered {
		area = area,
		type = {
			"cargo-wagon",
			"locomotive",
			"fluid-wagon",
			"artillery-wagon",
		},
	}

	if #entities == 0 then return nil end

	local luaTrain = entities[1].train
	if not luaTrain then return nil end

	local ordered_carriages = order_carriages(luaTrain)
	local carriage_spacing = calculate_carriage_spacing(ordered_carriages)

	-- Serialize train
	local train = universal_serializer.LuaTrainComplete.serialize(luaTrain, ordered_carriages, edge, offset)
	train.carriage_spacing = carriage_spacing
	if train.train and ordered_carriages[1] then
		train.train.front_direction = ordered_carriages[1].direction
		train.train.front_orientation = ordered_carriages[1].orientation
	end

	-- Translate carriage positions to be relative to edge
	for _, carriage in ipairs(train.carriages) do
		local edge_position = edge_util.world_to_edge_pos(carriage.position, edge)
		-- Compensate for edge direction
		edge_position[1] = edge.length - edge_position[1]
		carriage.position = edge_position
	end

	return {
		offset = offset,
		train = train,
		train_id = luaTrain.id, -- Used to delete train after successful spawning
	}
end

-- Poll a source (input) link: update debug visualization, check if a train should be captured,
-- and update signal/flow state tracking for the next tick
---@param offset number
---@param link table
---@param edge UniversalEdge
---@return table|nil
local function poll_input_link(offset, link, edge)
	local signal_state = link.signal.signal_state
	update_input_debug_visu(offset, link, edge)

	local transfer
	if should_capture_train(link, signal_state) then
		transfer = capture_train(offset, link, edge)
	end

	link.previous_signal_state = signal_state
	link.previous_flow_state = link.set_flow
	return transfer
end

-- Poll a destination (output) link: detect signal state changes and report flow status
-- back to the source so it knows whether it's safe to send trains
---@param offset number
---@param link table
---@return table|nil
local function poll_output_link(offset, link)
	local signal_state = link.signal.signal_state
	local transfer
	if signal_state ~= link.previous_signal_state then
		transfer = {
			offset = offset,
			set_flow = signal_state == defines.signal_state.open,
		}
	end
	link.previous_signal_state = signal_state
	link.previous_flow_state = link.set_flow
	return transfer
end

-- Main polling loop: iterates linked trains for an edge using partial_pairs (spread across
-- multiple ticks), dispatches to input/output handlers, and sends any resulting transfers
---@param edge_id string
---@param edge UniversalEdge
---@param ticks_left number
local function poll_links(edge_id, edge, ticks_left)
	if not edge.linked_trains then
		return
	end

	if not edge.linked_trains_state then
		edge.linked_trains_state = {}
	end

	local train_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_trains, edge.linked_trains_state, ticks_left
	) do
		if not link.signal or not link.signal.valid then
			cleanup_invalid_link(offset, link, edge)
		elseif link.is_input then
			local transfer = poll_input_link(offset, link, edge)
			if transfer then train_transfers[#train_transfers + 1] = transfer end
		else
			local transfer = poll_output_link(offset, link)
			if transfer then train_transfers[#train_transfers + 1] = transfer end
		end
	end

	if #train_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = edge_id,
			train_transfers = train_transfers,
		})
	end
end

-- Spawn a received train at the destination box. Snaps orientation to cardinal, positions
-- carriages along the rail with correct spacing, and converts edge coords to world coords.
-- Returns false if the destination signal is not open (area blocked).
---@param edge UniversalEdge
---@param offset number
---@param link table
---@param train table
---@return boolean
local function push_train_link(edge, offset, link, train)
	-- Check if the spawn location is free using link signal
	if not link.signal.valid then
		log("push_train_link offset " .. offset .. ": signal entity is invalid")
		return false
	end
	if link.signal.signal_state ~= defines.signal_state.open then
		log("push_train_link offset " .. offset .. ": signal not open, state=" .. link.signal.signal_state)
		return false
	end

	local train_start_position = -4
	local edge_x = edge_util.offset_to_edge_x(offset, edge)

	local spacing = train.carriage_spacing or calculate_carriage_spacing(train.carriages)
	if spacing == nil or spacing == 0 then
		spacing = 7
	end

	local front_orientation = train.train and train.train.front_orientation or train.carriages[1].orientation
	local snapped_orientation = snap_orientation(front_orientation)
	local snapped_direction = train.train and train.train.front_direction
	if snapped_orientation ~= nil then
		snapped_direction = orientation_to_direction(snapped_orientation)
	end

	for index, carriage in ipairs(train.carriages) do
		local carriage_index = index - 1
		carriage.position = { edge_x, train_start_position - carriage_index * spacing }
		if snapped_orientation ~= nil then
			carriage.orientation = snapped_orientation
		end
		if snapped_direction ~= nil then
			carriage.direction = snapped_direction
		end
	end

	for _, carriage in ipairs(train.carriages) do
		local world_pos = edge_util.edge_pos_to_world(carriage.position, edge)
		carriage.position = world_pos
	end

	local luaTrain = universal_serializer.LuaTrainComplete.deserialize(train)

	if luaTrain == nil then
		log("push_train_link offset " .. offset .. ": deserialization returned nil")
	end
	return luaTrain ~= nil
end

-- Process incoming train transfers from partner instance. Handles three cases:
-- 1. .train: attempt to spawn train, respond with success (train_id) or failure (set_flow=false)
-- 2. .set_flow: update flow control state on the link
-- 3. .train_id (no .train): confirmation that spawn succeeded, destroy the original train
---@param edge UniversalEdge
---@param train_transfers unknown
---@return table
local function receive_transfers(edge, train_transfers)
	if train_transfers == nil then
		return {}
	end
	local train_response_transfers = {}
	for _, train_transfer in ipairs(train_transfers) do
		local link = (edge.linked_trains or {})[train_transfer.offset]
		if not link then
			log("FATAL: Received train for non-existent link at offset " .. train_transfer.offset)
			goto continue
		end

		if train_transfer.set_flow ~= nil then
			link.set_flow = train_transfer.set_flow
			link.previous_flow_state = not train_transfer.set_flow
		end

		if train_transfer.train then
			-- Attempt to spawn train in world
			local result = push_train_link(edge, train_transfer.offset, link, train_transfer.train)

			-- If successful, return train_id without a train
			if result then
				-- Force previous_signal_state mismatch so poll_output_link is guaranteed to
				-- detect when the arrival signal reopens, even if the train clears the area
				-- between two poll cycles (race condition where open->closed->open goes unseen).
				link.previous_signal_state = defines.signal_state.closed
				-- Sending a transfer with a `train_id` and no `train` will delete train on destination
				train_response_transfers[#train_response_transfers + 1] = {
					offset = train_transfer.offset,
					-- Delete origin train (when provided without `train`)
					train_id = train_transfer.train_id,
					-- Prevent immediately sending another before this one has cleared the station
					set_flow = link.signal.signal_state == defines.signal_state.open,
				}
			else
				-- Station was blocked, disable flow.
				-- Force previous_signal_state mismatch so poll_output_link recovers with
				-- the real signal state on the next poll, unblocking the source if the
				-- destination signal is actually open (spawn failed for another reason).
				link.previous_signal_state = defines.signal_state.closed
				train_response_transfers[#train_response_transfers + 1] = {
					offset = train_transfer.offset,
					set_flow = false,
				}
			end
		elseif train_transfer.train_id ~= nil then
			-- The train was successfully spawned in on partner - delete the local train
			local train = game.train_manager.get_train_by_id(train_transfer.train_id)
			if train then
				log("Transfer successful, deleting local train " .. train_transfer.train_id)
				for _, carriage in ipairs(train.carriages) do
					-- Remove driver from train and ask them to teleport
					local driver = carriage.get_driver()
					if driver then
						-- Teleport player to the other side of the edge
						local player = driver.player
						if player ~= nil then
							-- Check if both sides of the edge are on the same instanceId
							if edge.source.instanceId == edge.target.instanceId then
								local new_carriage = storage.universal_edges.vehicle_drivers[player.name]
								if new_carriage ~= nil and new_carriage.valid then
									new_carriage.set_driver(player)
								else
									player.print("Carriage not found, did you miss your train?")
								end
								storage.universal_edges.vehicle_drivers[player.name] = nil
							else
								-- Cross server train rides need talking to the controller to figure out where to go
								clusterio_api.send_json("universal_edges:teleport_player_to_server", {
									player_name = player.name,
									edge_id = edge.id,
									offset = train_transfer.offset, -- Might want to use player position instead
								})
							end
						end
					end
					carriage.destroy()
				end
			else
				log("FATAL: Train teleported successfully but origin train disappeared (train_id=" .. train_transfer.train_id .. ")")
			end
		end
		::continue::
	end
	return train_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
