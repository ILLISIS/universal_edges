local clusterio_api = require("modules/clusterio/api")
local itertools = require("modules/universal_edges/itertools")

local fluid_box = require("modules/universal_edges/edge/fluid_box")

--- Read the fluid name and total amount from a pipe's fluid segment.
--- Uses segment totals instead of fluidbox values for accurate amounts in Factorio 2.0.
---@param pipe LuaEntity
---@return string|nil name
---@return number amount
local function read_segment(pipe)
	local segment = pipe.fluidbox.get_fluid_segment_contents(1)
	if not segment then return nil, 0 end
	local name, amount = next(segment)
	if not name then return nil, 0 end
	return name, amount --[[@as number]]
end

-- Send fluid level to partner for balancing
---@param edge_id string
---@param edge UniversalEdge
---@param ticks_left number
local function poll_links(edge_id, edge, ticks_left)
	if not edge.linked_fluids then
		return
	end

	if not edge.linked_fluids_state then
		edge.linked_fluids_state = {}
	end

	local fluid_transfers = {}
	for offset, link in itertools.partial_pairs(
		edge.linked_fluids, edge.linked_fluids_state, ticks_left
	) do
		if link.pipe == nil or link.pipe.valid == false then
			-- Pipe was destroyed, remove it from the list
			fluid_box.remove(offset, edge, nil)
			goto continue
		end
		local fluid_name, amount = read_segment(link.pipe)
		if fluid_name and amount > 10 then
			local fluidbox_fluid = link.pipe.fluidbox[1]
			fluid_transfers[#fluid_transfers + 1] = {
				offset = offset,
				name = fluid_name,
				amount = amount,
				temperature = fluidbox_fluid and fluidbox_fluid.temperature or 15,
			}
		end
		::continue::
	end

	if #fluid_transfers > 0 then
		clusterio_api.send_json("universal_edges:transfer", {
			edge_id = edge_id,
			fluid_transfers = fluid_transfers,
		})
	end
end

---@param edge UniversalEdge
---@param fluid_transfers unknown
---@return table
local function receive_transfers(edge, fluid_transfers)
	if fluid_transfers == nil then
		return {}
	end
	local fluid_response_transfers = {}
	for _offset, fluid_transfer in ipairs(fluid_transfers) do
		local link = (edge.linked_fluids or {})[fluid_transfer.offset]
		if not link then
			log("FATAL: received fluids for non-existant link at offset " .. fluid_transfer.offset)
			goto continue
		end

		if not link.pipe then
			log("FATAL: received fluids for a link that does not have a pipe " .. fluid_transfer.offset)
			goto continue
		end

		if fluid_transfer.amount ~= nil
			and fluid_transfer.name ~= nil
			and fluid_transfer.temperature ~= nil
		then
			local local_name, local_amount = read_segment(link.pipe)

			-- Skip if local pipe has a different fluid type
			if local_name and local_name ~= fluid_transfer.name then
				goto continue
			end

			local average = (fluid_transfer.amount + local_amount) / 2
			-- Only transfer balance in one direction - the partner will handle balancing the other way
			if average > local_amount then
				local transfer_amount = average - local_amount
				local inserted = link.pipe.insert_fluid {
					name = fluid_transfer.name,
					amount = transfer_amount,
					temperature = fluid_transfer.temperature,
				}
				if inserted > 0 then
					fluid_response_transfers[#fluid_response_transfers + 1] = {
						offset = fluid_transfer.offset,
						name = fluid_transfer.name,
						amount_balanced = inserted,
					}
				end
			end
		end
		if fluid_transfer.name and fluid_transfer.amount_balanced then
			-- The partner instance took some fluid to maintain balance, subtract that from the local storage
			link.pipe.remove_fluid {
				name = fluid_transfer.name,
				amount = fluid_transfer.amount_balanced,
			}
		end
		::continue::
	end
	return fluid_response_transfers
end

return {
	poll_links = poll_links,
	receive_transfers = receive_transfers,
}
