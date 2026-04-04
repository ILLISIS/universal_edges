local itertools = {}

---@param tbl table
---@param state LinkedPowerState|LinkedFluidState|LinkedBeltState|PollConnectorsState|TrainLinkState
---@param ticks_left number
---@return function
---@return table
---@return nil
function itertools.partial_pairs(tbl, state, ticks_left)
	if not tbl or type(tbl) ~= "table" then
		return function() return nil end, {}, nil
	end

	if ticks_left == 0 then
		local index = state and state.index
		if state then
			state.index = nil
			state.pos = 0
		end
		return next, tbl, index
	end

	local function iterator(itstate, index)
		if itstate.pos >= itstate.endpoint then
			itstate.index = index
			return nil, nil
		elseif itstate.pos > 0 and index == nil then
			return nil, nil
		end

		itstate.pos = itstate.pos + 1

		local ok, nextIndex = pcall(next, tbl, index)
		if not ok or nextIndex == nil then
			return nil, nil
		end

		itstate.index = nextIndex
		return itstate.index, tbl[itstate.index]
	end

	state = state or {}
	state.pos = state.pos or 0

	local size = table_size(tbl)
	state.endpoint = state.pos + math.max(0, math.ceil((size - state.pos) / (ticks_left + 1)))
	return iterator, state, state.index
end

return itertools
