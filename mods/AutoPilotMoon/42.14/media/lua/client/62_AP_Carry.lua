-- AutoPilot (Moon): automations for the Moon server.

-- Carrying what the character holds to a destination (11/11/2026, ANALISI-WorkOrders.md 6 point 3 and 7.2 point 9,
-- spec UX-AUTOPILOT.md 3.5): the shared trip of the Gatherer, the Sawyer, the chains.
-- A trip is a small state machine driven one step at a time by the automation, from its check function, only while
-- the character is idle (return "busy" to the engine while Carry:step says "busy"):
--   check    the destination still exists, is not locked, the vehicle has not moved (spec 3.5: before every trip);
--            not there yet -> walk (the game's walk, or the path to the vehicle's part), at most Carry.maxWalks times
--   deposit  a closed (not locked) trunk is opened with the game's own action, as by hand (then the trunk awaited open,
--            not "locked" at once); a container never opened is asked for and what it holds awaited (its room is
--            known only then); then one transfer action of the game per item (the server checks each, spec 7.4.5),
--            into the first container with room; a full destination -> the ground next to it (where the character
--            stands); no room there either -> stop "the destination is full"
--   confirm  only what really arrived counts (spec 7.4.1), BY ID (1.2.1, "wait for the object": in multiplayer the
--            item in the crate is a new object with the same id, contains(old object) never saw it: "Portati 0" and
--            the server's GathererItemsPerJob never stopped the Gatherer). The engine's AutoPilotMoon.Wait looks with
--            the character idle, "aspetta il server: gli oggetti in Cassa (2 su 3)"; a refusal of the server is seen
--            at once (the whole queue emptied): the refused item counts a failed try and that container is not tried
--            again for it in this trip (the floor is the last choice), the items cancelled after it are tried again
--            without a failed try; not arrived after Wait.timeoutMs: a failed try; after Carry.maxTries the item is
--            left with the warning "the server does not accept the move"
-- Limits (technical, spec 8.4): perTrip items per trip and perJob items per job (default: the server's
-- GathererItemsPerTrip and GathererItemsPerJob).
-- Never carried: favourites, equipped or worn items (the rule: what is blocked by hand).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Carry = AutoPilotMoon.Carry or {};

local Carry = AutoPilotMoon.Carry;

Carry.maxWalks = 3;          -- walks to the destination that do not get there before it counts as unreachable
Carry.maxTries = 3;          -- transfers of the same item that do not happen before it is left
Carry.nearDistance = 1.5;    -- next to a container
Carry.adjacentAxis = 1.6;    -- or as near as the game's walkAdj stops walking (each axis, square reachable)
Carry.loadRatio = 1.0;       -- of the character's maximum weight: more and the trip starts before picking up more

AutoPilotMoon.Automation:addJobStateField("carryCarried");     -- items carried in this job (confirmed)

-- limits

function AutoPilotMoon.Carry:getPerTrip(opts)
	return (opts and opts.perTrip) or AutoPilotMoon.Sandbox:getInteger("GathererItemsPerTrip");
end

function AutoPilotMoon.Carry:getPerJob(opts)
	return (opts and opts.perJob) or AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob");
end

-- items carried in this job (confirmed)
function AutoPilotMoon.Carry:getCarried()
	return AutoPilotMoon.Automation:getJobCount("carryCarried");
end

-- the per-job limit is reached: the job is finished (Automation:finishDone)
function AutoPilotMoon.Carry:isJobCapReached(opts)
	return Carry:getCarried() >= Carry:getPerJob(opts);
end

-- weight forecast (spec: "peso previsto"): picking up an item of this weight keeps the character within its
-- load, and the trip's count is below the limit; when false, it is time for a trip
function AutoPilotMoon.Carry:canPickMore(player, weight, countThisTrip, opts)
	if countThisTrip >= Carry:getPerTrip(opts)
	then
		return false;
	end

	return player:getInventoryWeight() + (weight or 0) <= player:getMaxWeight() * Carry.loadRatio;
end

-- an item the character may carry away: in its inventory (bags included), not a favourite, not equipped or worn
function AutoPilotMoon.Carry:isCarriable(item, player)
	if item == nil or item:isFavorite() or item:isEquipped() or player:isEquipped(item)
	then
		return false;
	end

	local container = item:getContainer();

	return container ~= nil and container:isInCharacterInventory(player);
end

-- the items of the inventory (bags included) that match predicate(item) and may be carried
function AutoPilotMoon.Carry:collectCargo(player, predicate)
	local result = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return predicate(item) and Carry:isCarriable(item, player);
	end);

	for i = 0, items:size() - 1
	do
		table.insert(result, items:get(i));
	end

	return result;
end

-- trips

-- A trip of items (list of InventoryItem of the character) to dest (AutoPilotMoon.Destination). opts (optional):
-- perTrip, perJob, counterKey (default "IGUI_AutoPilot_P_C_Carried"), activityKey (default
-- "IGUI_AutoPilot_P_Now_Carrying"), onCarried(id) (called once per item arrived, with its id).
-- trip.items holds the ids (never the game's objects: they are found again in the inventory at every step).
function AutoPilotMoon.Carry:newTrip(player, dest, items, opts)
	opts = opts or {};

	local trip = {
		player = player,
		dest = dest,
		items = {},
		opts = opts,
		state = "check",
		walks = 0,
		doorTried = false,
		doorWait = nil,
		loadWait = nil,
		pending = nil,
		wait = nil,
		failures = {},
		refused = {},
		carried = 0,
		floorPlanned = 0,
	};
	local limit = Carry:getPerTrip(opts);
	local left = Carry:getPerJob(opts) - Carry:getCarried();

	if left < limit
	then
		limit = left;
	end

	for i, item in ipairs(items)
	do
		if #trip.items >= limit
		then
			break;
		end

		if Carry:isCarriable(item, player)
		then
			table.insert(trip.items, item:getID());
		end
	end

	return trip;
end

local function isAt(trip, resolved)
	local player = trip.player;
	local dest = trip.dest;

	if dest.kind == "vehicle"
	then
		return resolved.vehicle:isInArea(resolved.part:getArea(), player);
	end

	if math.floor(player:getZ()) ~= dest.z
	then
		return false;
	end

	if dest.kind == "ground"
	then
		return math.floor(player:getX()) == dest.x and math.floor(player:getY()) == dest.y;
	end

	local dx = player:getX() - (dest.x + 0.5);
	local dy = player:getY() - (dest.y + 0.5);

	if math.sqrt(dx * dx + dy * dy) <= Carry.nearDistance
	then
		return true;
	end

	-- the game's walkAdj queues no walk when the character is within 1.6 squares on each axis and can reach the square
	-- (luautils.lua 42.22): the same rule here, or the trip would stop "unreachable" standing next to the container
	local square = luautils.getCorrectSquareForWall(player, resolved.square);
	local here = player:getSquare();

	return square ~= nil and here ~= nil
		and math.abs(square:getX() + 0.5 - player:getX()) <= Carry.adjacentAxis
		and math.abs(square:getY() + 0.5 - player:getY()) <= Carry.adjacentAxis
		and here:canReachTo(square);
end

local function walk(trip, resolved)
	local player = trip.player;
	local dest = trip.dest;

	if dest.kind == "vehicle"
	then
		ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, resolved.vehicle, resolved.part:getArea()));
	elseif dest.kind == "ground"
	then
		luautils.walk(player, resolved.square, true);
	else
		luautils.walkAdj(player, resolved.square, true);
	end
end

local function destinationName(trip)
	if trip.dest.kind == "ground"
	then
		return getText("IGUI_AutoPilot_D_GroundName");
	end

	return trip.dest.nameText or "";
end

-- the items not arrived yet and not given up (found again by id in the inventory), at most the trip's limit
local function itemsToCarry(trip)
	local result = {};
	local inventory = trip.player:getInventory();

	for i, id in ipairs(trip.items)
	do
		local item = inventory:getItemWithIDRecursiv(id);

		if item and (trip.failures[id] or 0) < Carry.maxTries and Carry:isCarriable(item, trip.player)
		then
			table.insert(result, item);
		end
	end

	return result;
end

-- the deposit's outcome (the wait is over): what arrived counted once, by id; the refused item a failed try and its
-- container skipped for it; what the game cancelled after a refusal tried again; what never arrived a failed try
local function settle(trip, info)
	local wait = trip.wait;

	for i, entry in ipairs(trip.pending)
	do
		if info.ids[entry.id]
		then
			trip.carried = trip.carried + 1;
			AutoPilotMoon.Automation:addJobCount("carryCarried");
			AutoPilotMoon.Progress:count(trip.opts.counterKey or "IGUI_AutoPilot_P_C_Carried");

			if trip.opts.onCarried
			then
				trip.opts.onCarried(entry.id);
			end
		elseif not wait:wasCancelled(entry.action)
		then
			trip.failures[entry.id] = (trip.failures[entry.id] or 0) + 1;

			if not entry.floor and wait:wasStopped(entry.action)
			then
				trip.refused[entry.id] = trip.refused[entry.id] or {};
				trip.refused[entry.id][entry.target] = true;
			end

			if trip.failures[entry.id] >= Carry.maxTries
			then
				-- the notifications: the item refused (a1)
				AutoPilotMoon.Notify:warnArgs("IGUI_AutoPilot_A_Reason_ServerRefused", entry.name);
				AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Reason_ServerRefused");
			end
		end
	end

	trip.pending = nil;
	trip.wait = nil;
	trip.state = "check";
end

-- the destination's containers: what they hold arrived from the server (their room is known only then); false: wait
local function contentsLoaded(trip, resolved)
	local player = trip.player;

	if trip.loadWait == nil
	then
		local wait = nil;

		for i, container in ipairs(resolved.containers)
		do
			AutoPilotMoon.Wait:explore(container, player);

			if AutoPilotMoon.Wait:loadState(container) ~= "loaded"
			then
				wait = wait or AutoPilotMoon.Wait:new(player, { label = destinationName(trip), waitingAfterMs = 0 });
				wait:expectLoaded(container);
			end
		end

		if wait == nil
		then
			return true;
		end

		trip.loadWait = wait;
	end

	if trip.loadWait:check() == "busy"
	then
		return false;
	end

	trip.loadWait = nil;

	return true;
end

-- One step of the trip, called while the character is idle: "busy" (actions queued or waiting), "done" (every item
-- arrived or given up; trip.carried says how many arrived), or "failed" and the reason key of the stop.
function AutoPilotMoon.Carry:step(trip)
	local player = trip.player;
	local now = getTimestampMs();

	if trip.state == "confirm"
	then
		local answer, why, info = trip.wait:check();

		if answer == "busy"
		then
			return "busy";
		end

		settle(trip, info);
	end

	local todo = itemsToCarry(trip);

	if #todo == 0
	then
		return "done";
	end

	local ok, reasonKey, resolved = AutoPilotMoon.Destination:validate(trip.dest, player);

	if not ok
	then
		return "failed", reasonKey;
	end

	if not isAt(trip, resolved)
	then
		if trip.walks >= Carry.maxWalks
		then
			return "failed", "IGUI_AutoPilot_A_Reason_DestUnreachable";
		end

		trip.walks = trip.walks + 1;
		walk(trip, resolved);
		AutoPilotMoon.Progress:setActivity(trip.opts.activityKey or "IGUI_AutoPilot_P_Now_Carrying", #todo, destinationName(trip));

		return "busy";
	end

	if trip.doorWait
	then
		-- the trunk opened as by hand: open only when the vehicle says so (its state comes from the server)
		if trip.doorWait:check() == "busy"
		then
			return "busy";
		end

		trip.doorWait = nil;
	end

	if trip.dest.kind == "vehicle" and not resolved.vehicle:canAccessContainer(resolved.partIndex, player)
	then
		local door = AutoPilotMoon.Destination:getClosedDoor(resolved.vehicle, resolved.part);

		if door and not trip.doorTried
		then
			-- a closed trunk is opened as by hand
			local action = ISOpenVehicleDoor:new(player, resolved.vehicle, door);
			local dest = trip.dest;
			local wait = AutoPilotMoon.Wait:new(player, { label = destinationName(trip) });

			trip.doorTried = true;
			ISTimedActionQueue.add(action);
			wait:watch(action);
			wait:expectTrue(function()
				local now = AutoPilotMoon.Destination:resolve(dest, player);

				return now ~= nil and now.vehicle ~= nil and now.vehicle:canAccessContainer(now.partIndex, player);
			end);
			trip.doorWait = wait;

			return "busy";
		end

		return "failed", "IGUI_AutoPilot_A_Reason_DestLocked";
	end

	if not contentsLoaded(trip, resolved)
	then
		return "busy";
	end

	-- the deposit: the first container with room, else the floor where the character stands
	local floor = ISInventoryPage.GetFloorContainer(player:getPlayerNum());
	local floorRoom = AutoPilotMoon.Item:getFloorRoom(player:getSquare(), player);
	local pending = {};
	local planned = {};
	local wait = AutoPilotMoon.Wait:new(player, { label = getText("IGUI_AutoPilot_W_Carry", destinationName(trip)) });

	for i, item in ipairs(todo)
	do
		-- a container that refused this item in this trip is not tried again for it: the next one, the floor last
		local target = AutoPilotMoon.Destination:findRoom(resolved, player, item, planned, trip.refused[item:getID()]);
		local onFloor = false;

		if target == nil
		then
			local weight = item:getUnequippedWeight();

			if floor and floorRoom - trip.floorPlanned >= weight
			then
				target = floor;
				onFloor = true;
				trip.floorPlanned = trip.floorPlanned + weight;
			end
		end

		if target
		then
			local action = ISInventoryTransferUtil.newInventoryTransferAction(player, item, item:getContainer(), target);

			ISTimedActionQueue.add(action);
			wait:watch(action);

			if onFloor
			then
				-- on the floor: it left the inventory (the game lays it on the 3x3, another object)
				wait:expectOut(item, "inventory");
			else
				wait:expectIn(item, target);
			end

			table.insert(pending, { id = item:getID(), name = item:getDisplayName(), action = action, target = target,
				floor = onFloor });
		end
	end

	trip.floorPlanned = 0;

	if #pending == 0
	then
		return "failed", "IGUI_AutoPilot_A_Reason_DestFull";
	end

	trip.pending = pending;
	trip.wait = wait;
	trip.state = "confirm";
	AutoPilotMoon.Progress:setActivity(trip.opts.activityKey or "IGUI_AutoPilot_P_Now_Carrying", #pending, destinationName(trip));

	return "busy";
end

-- next to a destination as a trip counts it (the macros' places, 19/11/2026: take, put, walk_to): the same rule as the
-- game's walkAdj for a container, standing on it for the ground
function AutoPilotMoon.Carry:isNear(player, dest, resolved)
	return isAt({ player = player, dest = dest }, resolved);
end
