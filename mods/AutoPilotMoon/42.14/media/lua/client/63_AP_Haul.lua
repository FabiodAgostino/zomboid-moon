-- AutoPilot (Moon): automations for the Moon server.

-- Picking things up from the ground and carrying them to a destination (11/11/2026, phase B): the shared part of the
-- Gatherer, the Sawyer and the Woodcutter (ANALISI-WorkOrders.md 6 points 2, 3, 9 and 7.2 point 9).
-- A "hauler" is the per-job state, driven one decision at a time by the automation's check function while the
-- character is idle:
--   pick up   the game's own grab (ISWorldObjectContextMenu.onGrabAllWItems: the walk next to the square, then one
--             grab per item, a transfer the server checks in MP); only what really arrived in the inventory counts
--             (spec 7.4.1): an item still on the ground waits Haul.confirmGraceMs ("waiting for the server..."), then
--             counts as a failed try; after Haul.maxTries it is left with the warning "the server does not accept the
--             move"; an item gone from the ground and not in the inventory was taken by someone else.
--   cargo     the items this job picked up or made (by id): only these are ever carried, never the player's own
--             things (Carry also leaves favourites, equipped and worn items alone).
--   deliver   Carry trips to the destination until the cargo is delivered (more trips in one visit when the cargo is
--             more than the server's items per trip); what the server refuses three times stays in the inventory and
--             is not tried again.
-- W-B5 of Work Orders (a gathering that never ends): nothing is ever picked up from the destination or the squares
-- next to it (where a full destination puts things down), nor an item this job (or an earlier phase of its chain)
-- delivered; every item is picked up at most Haul.maxTries times; a square ends when nothing is left to pick there.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Haul = AutoPilotMoon.Haul or {};

local Haul = AutoPilotMoon.Haul;

Haul.maxTries = 3;            -- grabs of the same item that do not happen before it is left
Haul.confirmGraceMs = 1500;   -- the grab ended and the item is not in the inventory yet: the server may still answer
Haul.destinationMargin = 1;   -- squares around the destination never picked from (where a full destination puts down)

-- a new hauler for a job. opts (optional): perTrip, perJob (the Carry limits; default the server's Gatherer
-- limits), counterKey (what a delivered item counts as; default "carried"), activityKey (the panel's "Ora" line while
-- carrying; default Carry's), shared (a table that lives as long as the
-- chain, ctx.run: the items delivered by an earlier phase are never picked up again)
function AutoPilotMoon.Haul:new(player, dest, opts)
	opts = opts or {};

	local shared = opts.shared;
	local deposited = nil;

	if shared
	then
		shared.haulDeposited = shared.haulDeposited or {};
		deposited = shared.haulDeposited;
	end

	return {
		player = player,
		dest = dest,
		opts = opts,
		cargo = {},              -- id -> true: picked up or made by this job, still to deliver
		givenUp = {},            -- id -> true: never tried again
		tries = {},              -- id -> failed grabs
		deposited = deposited or {}, -- id -> true: delivered
		grab = nil,
		trip = nil,
		delivering = false,
		delivered = 0,
	};
end

-- squares

-- the destination or a square next to it (same floor): never picked from
function AutoPilotMoon.Haul:isNearDestination(dest, square)
	if dest == nil or square == nil or square:getZ() ~= dest.z
	then
		return false;
	end

	return math.abs(square:getX() - dest.x) <= Haul.destinationMargin and math.abs(square:getY() - dest.y) <= Haul.destinationMargin;
end

-- the items lying on the square that match predicate(item) and may be picked up by this hauler (nil: any hauler),
-- as a list of { worldObject, item, id }; first = true stops at the first one
function AutoPilotMoon.Haul:findOnSquare(h, square, predicate, first)
	local result = {};

	if square == nil or (h and Haul:isNearDestination(h.dest, square))
	then
		return result;
	end

	local objects = square:getWorldObjects();

	if objects == nil
	then
		return result;
	end

	for i = 0, objects:size() - 1
	do
		local worldObject = objects:get(i);
		local item = worldObject and worldObject:getItem();

		if item and predicate(item)
		then
			local id = item:getID();

			if h == nil or not (h.givenUp[id] or h.deposited[id] or h.cargo[id])
			then
				table.insert(result, { worldObject = worldObject, item = item, id = id });

				if first
				then
					return result;
				end
			end
		end
	end

	return result;
end

-- the square has something to pick up for a job carrying to dest (the start's filter, the area tool's count)
function AutoPilotMoon.Haul:squareHas(square, predicate, dest)
	if Haul:isNearDestination(dest, square)
	then
		return false;
	end

	return #Haul:findOnSquare(nil, square, predicate, true) > 0;
end

-- how many items on the squares match (the total shown in the panel at the start)
function AutoPilotMoon.Haul:countOn(squares, predicate, dest)
	local total = 0;

	for i, square in ipairs(squares)
	do
		if not Haul:isNearDestination(dest, square)
		then
			total = total + #Haul:findOnSquare(nil, square, predicate);
		end
	end

	return total;
end

-- picking up

-- the game's own grab of these entries (findOnSquare), all on the same square: the walk next to it, then one grab each
function AutoPilotMoon.Haul:grab(h, square, entries)
	local list = {};

	for i, entry in ipairs(entries)
	do
		table.insert(list, entry.worldObject);
	end

	h.grab = {
		x = square:getX(),
		y = square:getY(),
		z = square:getZ(),
		entries = entries,
		idleSince = nil,
	};

	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Gathering", #entries);
	ISWorldObjectContextMenu.onGrabAllWItems(nil, list, h.player:getPlayerNum());
end

local function isStillOnGround(grab, entry)
	local cell = getCell();
	local square = cell and cell:getGridSquare(grab.x, grab.y, grab.z);
	local objects = square and square:getWorldObjects();

	return objects ~= nil and objects:contains(entry.worldObject);
end

-- the grab's outcome, once the character is idle again: "busy" while waiting for the server, else nil (the picked items
-- are cargo, the others counted as a try or as taken by someone else)
function AutoPilotMoon.Haul:confirmGrab(h)
	local grab = h.grab;
	local now = getTimestampMs();
	local inventory = h.player:getInventory();
	local waiting = false;

	if grab.idleSince == nil
	then
		grab.idleSince = now;
	end

	for i, entry in ipairs(grab.entries)
	do
		if not entry.resolved
		then
			if inventory:getItemWithIDRecursiv(entry.id)
			then
				entry.resolved = true;
				h.cargo[entry.id] = true;
			elseif isStillOnGround(grab, entry)
			then
				waiting = true;
			else
				-- gone from the ground and not here: someone else took it (spec 7.4.3, not an error)
				entry.resolved = true;
				AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_ByOthers");
			end
		end
	end

	if waiting and now - grab.idleSince < Haul.confirmGraceMs
	then
		AutoPilotMoon.Progress:setWaiting(true);

		return "busy";
	end

	AutoPilotMoon.Progress:setWaiting(false);

	for i, entry in ipairs(grab.entries)
	do
		if not entry.resolved
		then
			h.tries[entry.id] = (h.tries[entry.id] or 0) + 1;

			if h.tries[entry.id] >= Haul.maxTries
			then
				h.givenUp[entry.id] = true;
				AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Reason_ServerRefused");
			end
		end
	end

	h.grab = nil;

	return nil;
end

-- the cargo

-- an item made by the job (planks, firewood) is cargo too
function AutoPilotMoon.Haul:addCargo(h, item)
	h.cargo[item:getID()] = true;
end

-- the cargo still in the inventory, as InventoryItem (only what may be carried: Carry:isCarriable)
function AutoPilotMoon.Haul:getCargo(h)
	return AutoPilotMoon.Carry:collectCargo(h.player, function(item)
		local id = item:getID();

		return h.cargo[id] == true and not h.givenUp[id];
	end);
end

function AutoPilotMoon.Haul:countCargo(h)
	return #Haul:getCargo(h);
end

-- Picking up an item of this weight (extraCount items already chosen in this pick-up): the game must have room for
-- it (ItemContainer.hasRoomFor of the inventory, the check of the game's own grab); with nothing to deliver yet one item
-- is always allowed (a log weighs more than many characters' comfortable load: as by hand, one at a time); else the
-- load and the trip stay within Carry's limits (the character's maximum weight, the server's items per trip).
function AutoPilotMoon.Haul:canPick(h, weight, extraCount)
	local player = h.player;
	local count = Haul:countCargo(h) + (extraCount or 0);
	local planned = h.plannedWeight or 0;

	if not player:getInventory():hasRoomFor(player, planned + (weight or 0))
	then
		return false;
	end

	if count == 0
	then
		return true;
	end

	return AutoPilotMoon.Carry:canPickMore(player, planned + (weight or 0), count, h.opts);
end

-- the entries (findOnSquare) to pick up in one go, in their order, while they fit (canPick with the weight of the ones
-- already chosen; maxCount: a limit of the job); stops at the first one that does not fit
function AutoPilotMoon.Haul:choose(h, entries, maxCount)
	local chosen = {};

	h.plannedWeight = 0;

	for i, entry in ipairs(entries)
	do
		if maxCount and #chosen >= maxCount
		then
			break;
		end

		local weight = entry.item:getUnequippedWeight();

		if not Haul:canPick(h, weight, #chosen)
		then
			break;
		end

		table.insert(chosen, entry);
		h.plannedWeight = h.plannedWeight + weight;
	end

	h.plannedWeight = 0;

	return chosen;
end

-- delivering

local function newTrip(h)
	if h.dest == nil
	then
		return false;
	end

	local items = Haul:getCargo(h);

	if #items == 0
	then
		return false;
	end

	local trip = AutoPilotMoon.Carry:newTrip(h.player, h.dest, items, {
		perTrip = h.opts.perTrip,
		perJob = h.opts.perJob,
		counterKey = h.opts.counterKey,
		activityKey = h.opts.activityKey,
		onCarried = function(item)
			local id = item:getID();

			h.cargo[id] = nil;
			h.deposited[id] = true;
			h.delivered = h.delivered + 1;
		end,
	});

	if #trip.items == 0
	then
		-- the job's limit of carried items is reached
		return false;
	end

	h.trip = trip;

	return true;
end

-- starts delivering the cargo (as many trips as the server's items per trip ask, in one visit); false when there is
-- nothing to deliver, no destination or the job's limit of carried items is reached
function AutoPilotMoon.Haul:deliver(h)
	h.delivering = newTrip(h);

	return h.delivering;
end

-- What is under way: a trip, then a grab to confirm. Returns "busy" (answer "busy" to the engine), "failed" and the
-- reason key of the stop (the destination is gone, full, locked...), or nil (nothing pending: the automation decides).
function AutoPilotMoon.Haul:update(h)
	if h.trip
	then
		local result, reasonKey = AutoPilotMoon.Carry:step(h.trip);

		if result == "busy"
		then
			return "busy";
		end

		local trip = h.trip;

		h.trip = nil;

		if result == "failed"
		then
			h.delivering = false;

			return "failed", reasonKey;
		end

		-- what the server refused three times stays in the inventory and is not carried again
		for i, item in ipairs(trip.items)
		do
			local id = item:getID();

			if h.cargo[id] and not h.deposited[id]
			then
				h.givenUp[id] = true;
			end
		end

		if h.delivering and newTrip(h)
		then
			return "busy";
		end

		h.delivering = false;
	end

	if h.grab
	then
		return Haul:confirmGrab(h);
	end

	return nil;
end

-- the job's square is the last one of its queue (the cargo is delivered before the job ends: W-B5, never an
-- undelivered load left in the bag)
function AutoPilotMoon.Haul:isLastSquare()
	local job = AutoPilotMoon.Automation.job;

	return job ~= nil and #job.entries <= 1;
end
