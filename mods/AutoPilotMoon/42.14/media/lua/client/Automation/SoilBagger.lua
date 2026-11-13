-- AutoPilot (Moon): automations for the Moon server.

-- Soil bagger (Moon): fills bags with the dirt, sand, gravel or clay of an area, with the game's own shovelling.
-- - The bag is the game's own choice (ISShovelGroundCursor.GetEmptyItem): a bag of that soil not full yet, else any
--   empty bag with the HOLD_DIRT tag (N-A16); clay goes into Base.Claybag as in the game (B13).
-- - One shovelful per square, as the game's cursor (ISShovelGroundCursor:create): the walk next to the square, the
--   sack into the main inventory, the shovel in the hands, ISShovelGround. The square counts when its soil is gone (the
--   game marks it shovelled); a shovelful that does not happen is tried SoilBagger.maxTries times, then left.
-- - The full bags (13/11/2026, owner's request, the same destination step as the Sawyer, UX-AUTOPILOT.md 3.5 and 9):
--   * "Sul posto" (the first choice of the picker; also a job started without a destination): every bag this job
--     filled is put down on the ground as soon as it is full, next to the square it was filled from, with the game's
--     own "Drop" (ISInventoryPaneContextMenu.dropItem: a transfer action to the floor container, which the server
--     checks). Only what really left the inventory counts ("Sacchi lasciati a terra").
--   * a container, a vehicle's trunk or a square of ground: the full bags are cargo (AutoPilotMoon.Haul) carried there
--     with the game's transfers; meanwhile they go into a worn bag with room (D1). A trip starts before a NEW sack is
--     started when one more full bag would not fit (the character's maximum weight, the room of its inventory, the
--     server's items per trip: Haul:canPick with the weight of a full bag of that soil, often one or two sand or clay
--     bags per trip), when no empty sack is left and there are full ones to deliver, and before the last square ends.
--     A partly filled bag is always finished (it is in the hands' plan already).
--   * refill (owner's decision of 13/11/2026): at a container or a trunk, after the full bags are put there, empty
--     sacks found IN that destination are taken back with the game's transfer action (the game's own rule: HOLD_DIRT
--     and empty; never a favourite, never what the container does not let go), as many as the character can fill and
--     carry on the next round (at least one), then the job goes on. "Sul posto" and the ground take nothing back.
-- - The bags the character had full before the job are its own: never dropped, never carried. The last bag, when the
--   area ends before it is full, stays in the inventory (it is still a sack to fill).
-- - Stops with the reason: no shovel, no empty sack left ("Metti dei sacchi vuoti nella destinazione per continuare";
--   without a container destination it says that only a crate gives them back), no room on the ground (Sul posto), the
--   destination gone / full / locked. Never in a protected zone (start and every square). MaxSquaresPerJob squares.

require "05_AP_Config";
require "50_AP_Automation";

local A = AutoPilotMoon.Automation;
local Haul = AutoPilotMoon.Haul;

AutoPilotMoon.SoilBagger = AutoPilotMoon.SoilBagger or {};

local SoilBagger = AutoPilotMoon.SoilBagger;

SoilBagger.maxTries = 3;            -- shovelfuls queued on the same square that do not dig it before it is left
SoilBagger.maxSteps = 6;            -- decisions on the same square (engine's maxStepsPerSquare: a walk that fails)
SoilBagger.dropGraceMs = 1500;      -- the drops ended and a bag is still in the inventory: the server may still answer
SoilBagger.maxDropTries = 3;        -- drops of the same bag that do not happen before it is left in the inventory
SoilBagger.refillGraceMs = 1500;    -- the empty sacks taken from the destination: the server may still answer
SoilBagger.carryPerJob = 100000;    -- the bags carried are bounded by the squares (MaxSquaresPerJob), not the Gatherer's
SoilBagger.fullWeightFallback = 2;  -- a full soil bag in 42.22 (the script's Weight) when the script cannot be read
SoilBagger.fullWeights = {};        -- full type -> weight of a full bag (read once)

-- config

A:register("soilBagger");

A:addJobStateField("baggerSoilType");   -- the soil of the running job
A:addJobStateField("baggerState");      -- the running job's own state

-- filters

function AutoPilotMoon.Automation:getSoilBaggerTiles(squares, soilType)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		return AutoPilotMoon.Square:getSoilType(square) == soilType;
	end);
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_SoilBagger");
end

local function soilName(soilType)
	return getText("IGUI_AutoPilot_A_Soil" .. AutoPilotMoon:ucFirst(soilType or "dirt"));
end

-- the weight of a full bag of that type: the item script's (a full drainable weighs its script weight, 42.22
-- DrainableComboItem.updateWeight), read once
function SoilBagger:getFullWeight(fullType)
	local weight = SoilBagger.fullWeights[fullType];

	if weight
	then
		return weight;
	end

	local script = fullType and getScriptManager():FindItem(fullType) or nil;

	if script
	then
		local ok, value = pcall(function()
			return script:getActualWeight();
		end);

		if ok and type(value) == "number" and value > 0
		then
			weight = value;
		end
	end

	weight = weight or SoilBagger.fullWeightFallback;

	if fullType
	then
		SoilBagger.fullWeights[fullType] = weight;
	end

	return weight;
end

local function squareKey(square)
	return square:getX() .. "," .. square:getY() .. "," .. square:getZ();
end

local function fullSoilBags(player)
	return player:getInventory():getAllEvalRecurse(function(item)
		return AutoPilotMoon.Item:isSoilBag(item) and AutoPilotMoon.Item:isFullSoilBag(item);
	end);
end

-- methods

-- Starts the Soil bagger for the player on the squares (a list or a function) of that soil. ctx (optional):
-- destination (where the full bags go; none: "Sul posto", left on the ground next to where they were filled).
function AutoPilotMoon.Automation.startSoilBagger(player, squares, startSquare, soilType, ctx)
	local dest = ctx and ctx.destination;
	local started = A:startJob("soilBagger", player, squares, startSquare, function(list)
		return A:getSoilBaggerTiles(list, soilType);
	end);

	if started
	then
		local own = {};
		local bags = fullSoilBags(player);

		for i = 0, bags:size() - 1
		do
			own[bags:get(i):getID()] = true;
		end

		A.baggerSoilType = soilType;
		A.baggerState = {
			soil = soilType,
			dest = dest,
			leave = dest == nil,      -- "Sul posto": the full bags stay on the ground
			refillable = dest ~= nil and (dest.kind == "container" or dest.kind == "vehicle"),
			hauler = Haul:new(player, dest, {
				perJob = SoilBagger.carryPerJob,
				counterKey = "IGUI_AutoPilot_P_C_BagsCarried",
				activityKey = "IGUI_AutoPilot_P_Now_CarryingBags",
			}),
			own = own,                -- bag id -> true: full before the job (the character's own)
			seen = {},                -- bag id -> true: counted full ("Sacchi riempiti")
			queued = {},              -- square key -> true: a shovelful queued there
			tries = {},               -- square key -> shovelfuls that did not dig it
			dropTries = {},           -- bag id -> drops that did not happen
			drop = nil,               -- the bags being put down: { entries = { item, id, done }, idleSince }
			refill = nil,             -- the empty sacks being taken back: { entries, idleSince }
			tripOpen = false,         -- a delivery is under way (counted as a trip when it ends)
			finalTrip = false,        -- the last delivery of the area: no refill after it
		};
	end

	return started;
end

function AutoPilotMoon.Automation:stopSoilBagger()
	A:stopSquareProcessingQueue("soilBaggerWorking");
end

-- the bags this job filled, newly full: counted once, and cargo (carried, or put down on the spot)
local function collectFilled(S, player)
	local bags = fullSoilBags(player);

	for i = 0, bags:size() - 1
	do
		local bag = bags:get(i);
		local id = bag:getID();

		if not S.own[id] and not S.seen[id]
		then
			S.seen[id] = true;
			AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Bags", 1);
			Haul:addCargo(S.hauler, bag);
		end
	end
end

-- "Sul posto": the bags put down with the game's "Drop" (a transfer to the floor container), as many as the floor
-- around the character takes; false when it takes none
local function startDrop(S, player, bags)
	local here = player:getSquare();
	local floor = ISInventoryPage.GetFloorContainer(player:getPlayerNum());

	if here == nil or floor == nil or AutoPilotMoon.Zones:isProtected(here, player)
	then
		return false;
	end

	local room = AutoPilotMoon.Item:getFloorRoom(here, player);
	local weight = 0;
	local entries = {};

	for i, bag in ipairs(bags)
	do
		local bagWeight = bag:getUnequippedWeight();

		if weight + bagWeight <= room
		then
			weight = weight + bagWeight;
			ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, bag, bag:getContainer(), floor));
			table.insert(entries, { item = bag, id = bag:getID(), done = false });
		end
	end

	if #entries == 0
	then
		return false;
	end

	S.drop = { entries = entries, idleSince = nil };
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_LeavingBags", #entries);

	return true;
end

local function isOut(item, player)
	local container = item:getContainer();

	return container == nil or not container:isInCharacterInventory(player);
end

-- the drop's outcome once the character is idle: "busy" while waiting for the server, else nil (counted; a bag the
-- server refused SoilBagger.maxDropTries times stays in the inventory with the warning)
local function confirmDrop(S, player)
	local drop = S.drop;
	local now = getTimestampMs();
	local waiting = false;

	for i, entry in ipairs(drop.entries)
	do
		if not entry.done
		then
			if isOut(entry.item, player)
			then
				entry.done = true;
				AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_BagsLeft");
			else
				waiting = true;
			end
		end
	end

	drop.idleSince = drop.idleSince or now;

	if waiting and now - drop.idleSince < SoilBagger.dropGraceMs
	then
		AutoPilotMoon.Progress:setWaiting(true);

		return "busy";
	end

	AutoPilotMoon.Progress:setWaiting(false);
	S.drop = nil;

	for i, entry in ipairs(drop.entries)
	do
		if not entry.done
		then
			S.dropTries[entry.id] = (S.dropTries[entry.id] or 0) + 1;

			if S.dropTries[entry.id] >= SoilBagger.maxDropTries
			then
				S.hauler.givenUp[entry.id] = true;
				AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Reason_ServerRefused");
			end
		end
	end

	return nil;
end

-- refill (13/11/2026): how many empty sacks to take for the next round: as many full bags as the character can still
-- carry (the ones it has count as the soil they will hold), within the items per trip; at least one when it has none
local function refillCount(S, player)
	local fullType = AutoPilotMoon.Item:getBagForSoil(player, S.soil);
	local full = SoilBagger:getFullWeight(fullType);
	local free = player:getMaxWeight() * AutoPilotMoon.Carry.loadRatio - player:getInventoryWeight();
	local have = player:getInventory():getAllEvalRecurse(function(item)
		return AutoPilotMoon.Item:isEmptySoilSack(item);
	end);

	for i = 0, have:size() - 1
	do
		local grows = full - have:get(i):getUnequippedWeight();

		if grows > 0
		then
			free = free - grows;
		end
	end

	local count = 0;

	if free > 0
	then
		count = math.floor(free / full);
	end

	local perTrip = AutoPilotMoon.Carry:getPerTrip(S.hauler.opts);

	if count > perTrip - have:size()
	then
		count = perTrip - have:size();
	end

	if have:size() == 0 and count < 1
	then
		count = 1;
	end

	return count;
end

-- at the destination, after the full bags are put there: the empty sacks it holds taken back with the game's transfer
-- action; false when there is nothing to take (or the destination cannot be used now)
local function startRefill(S, player)
	local ok, reasonKey, resolved = AutoPilotMoon.Destination:validate(S.dest, player);

	if not ok
	then
		return false;
	end

	if S.dest.kind == "vehicle" and not resolved.vehicle:canAccessContainer(resolved.partIndex, player)
	then
		return false;
	end

	local wanted = refillCount(S, player);
	local inventory = player:getInventory();
	local planned = 0;
	local entries = {};

	for i, container in ipairs(resolved.containers)
	do
		AutoPilotMoon.Item:explore(container, player);

		local items = container:getItems();

		for j = 0, items:size() - 1
		do
			local item = items:get(j);

			if #entries < wanted and AutoPilotMoon.Item:isEmptySoilSack(item) and not item:isFavorite()
				and not item:isEquipped() and container:isRemoveItemAllowed(item)
			then
				local weight = item:getUnequippedWeight();

				if inventory:hasRoomFor(player, planned + weight)
				then
					planned = planned + weight;
					ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, container, inventory));
					table.insert(entries, { item = item, id = item:getID(), done = false });
				end
			end
		end
	end

	if #entries == 0
	then
		return false;
	end

	S.refill = { entries = entries, idleSince = nil };
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_TakingBags", #entries);

	return true;
end

-- the refill's outcome once the character is idle: "busy" while waiting for the server, else nil (what arrived counts;
-- what did not is left with the warning, the job goes on with what it has)
local function confirmRefill(S, player)
	local refill = S.refill;
	local inventory = player:getInventory();
	local now = getTimestampMs();
	local waiting = false;

	for i, entry in ipairs(refill.entries)
	do
		if not entry.done and inventory:getItemWithIDRecursiv(entry.id) ~= nil
		then
			entry.done = true;
			AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_BagsTaken");
		elseif not entry.done
		then
			waiting = true;
		end
	end

	refill.idleSince = refill.idleSince or now;

	if waiting and now - refill.idleSince < SoilBagger.refillGraceMs
	then
		AutoPilotMoon.Progress:setWaiting(true);

		return "busy";
	end

	AutoPilotMoon.Progress:setWaiting(false);
	S.refill = nil;

	if waiting
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Reason_ServerRefused");
	end

	return nil;
end

-- a delivery of the full bags (with a destination); true when it started
local function deliver(S)
	if S.leave or not Haul:deliver(S.hauler)
	then
		return false;
	end

	S.tripOpen = true;

	return true;
end

-- a square is over (dug, left, not ours): before the last one ends, the last full bags go to the destination
local function finishSquare(S, result)
	if not S.leave and Haul:isLastSquare() and Haul:countCargo(S.hauler) > 0
	then
		S.finalTrip = true;

		if deliver(S)
		then
			return "busy";
		end
	end

	return result;
end

-- no empty sack left: the reason, with what to do to go on
local function noSackReason(S)
	if S.refillable
	then
		return getText("IGUI_AutoPilot_A_Reason_NoEmptySacksRefill");
	end

	return getText("IGUI_AutoPilot_A_Reason_NoEmptySacksNoRefill");
end

-- One decision while the character is idle (the engine's removeCheckFunction): "busy" while dropping, carrying or
-- taking sacks back; false while the square still has its soil (the work function shovels it); true when it is dug.
function AutoPilotMoon.Automation:checkSoilBaggerSquare(square, player)
	local S = A.baggerState;

	if S == nil
	then
		return "discard";
	end

	local h = S.hauler;
	local pending, reasonKey = Haul:update(h);

	if pending == "busy"
	then
		return "busy";
	elseif pending == "failed"
	then
		A:stopBecause(getText(reasonKey));

		return "discard";
	end

	if S.tripOpen and not h.delivering
	then
		-- a delivery has ended: one trip; at a container, the empty sacks it holds are taken back
		S.tripOpen = false;
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Trips");

		if S.refillable and not S.finalTrip and startRefill(S, player)
		then
			return "busy";
		end
	end

	if S.refill and confirmRefill(S, player) == "busy"
	then
		return "busy";
	end

	if S.drop and confirmDrop(S, player) == "busy"
	then
		return "busy";
	end

	collectFilled(S, player);

	if S.leave
	then
		local bags = Haul:getCargo(h);

		if #bags > 0
		then
			if startDrop(S, player, bags)
			then
				return "busy";
			end

			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NoRoomForBags"));

			return "discard";
		end
	end

	local key = squareKey(square);
	local soilType = AutoPilotMoon.Square:getSoilType(square);

	if S.queued[key]
	then
		if soilType ~= S.soil
		then
			-- dug: the game marked it shovelled
			return finishSquare(S, true);
		end

		S.queued[key] = nil;
		S.tries[key] = (S.tries[key] or 0) + 1;

		if S.tries[key] >= SoilBagger.maxTries
		then
			AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_GameRefused");

			return finishSquare(S, "discard");
		end
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return finishSquare(S, "discard");
	end

	if soilType ~= S.soil
	then
		-- shovelled meanwhile by someone else, or something else now: nothing to do here
		return finishSquare(S, "discard");
	end

	if not AutoPilotMoon.Item:getShovel(player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedShovel")));

		return "discard";
	end

	local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

	if bag == nil
	then
		-- no empty sack: the full bags go to the destination first (then, at a container, empty ones come back)
		if deliver(S)
		then
			return "busy";
		end

		A:stopBecause(noSackReason(S));

		return "discard";
	end

	if not S.leave and bag:getFullType() ~= bagType and Haul:countCargo(h) > 0
	then
		-- a new sack: one more full bag must fit, else a trip first
		local extra = SoilBagger:getFullWeight(bagType) - bag:getUnequippedWeight();

		if extra < 0
		then
			extra = 0;
		end

		if not Haul:canPick(h, extra, 0)
		then
			if deliver(S)
			then
				return "busy";
			end

			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_BagFull"));

			return "discard";
		end
	end

	return false;
end

function AutoPilotMoon.Automation:workSoilBaggerSquare(square, player)
	local S = A.baggerState;

	if S == nil or AutoPilotMoon.Zones:isProtected(square, player)
	then
		return;
	end

	local key = squareKey(square);
	local soilType, soilTile = AutoPilotMoon.Square:getSoilType(square);

	if S.queued[key] or soilType ~= S.soil
	then
		return;
	end

	local shovel = AutoPilotMoon.Item:getShovel(player);
	local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

	if shovel == nil or bag == nil
	then
		return;
	end

	-- with a destination, the bags filled by the previous steps into a worn bag first (D1)
	if not S.leave
	then
		AutoPilotMoon.Item:stashFullSoilBags(player, function(full)
			return S.seen[full:getID()] == true;
		end);
	end

	-- as the game's own cursor (ISShovelGroundCursor:create)
	if AutoPilotMoon.Square:walkTo(player, square, true)
	then
		ISWorldObjectContextMenu.transferIfNeeded(player, bag);
		ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), shovel, true, true);
		ISTimedActionQueue.add(ISShovelGround:new(player, bag, soilTile, "blends_natural_01_64", bagType));
		S.queued[key] = true;
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Bagging", soilName(soilType));
	end
end

function AutoPilotMoon.Automation:checkSoilBaggerQueue(player)
	A:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "soilBaggerWorking",
		maxStepsPerSquare = SoilBagger.maxSteps,
		squareFunction = {
			fn = function(square, who)
				A:workSoilBaggerSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return A:checkSoilBaggerSquare(square, who);
		end,
		stopFunction = function()
			A:stopSoilBagger();
		end,
	});
end

-- the menu entry "Insacca: sabbia" (client/75_AP_JobMenu.lua): the soil of the clicked square, as the game's own
-- "Take some sand" (ISInventoryBuildMenu: the squares the player clicked), else the one the character stands on (spec
-- 2.2); a shovel and an empty sack for it; the squares of that soil in the area; then where the full bags go ("Sul
-- posto" first, or a crate, a trunk, the ground)

local function currentSoil(player)
	local square = player and AutoPilotMoon.Square:getCurrent(player);

	return square, square and AutoPilotMoon.Square:getSoilType(square) or nil;
end

-- the soil of the entry: given by the menu (params.soil), else the clicked square's while the menu is built, else the
-- one under the character's feet
function SoilBagger:getMenuSoil(player, params)
	if params and params.soil
	then
		return params.soil;
	end

	local clicked = AutoPilotMoon.JobMenu.clickedSquare;
	local soilType = clicked and AutoPilotMoon.Square:getSoilType(clicked) or nil;

	if soilType
	then
		return soilType;
	end

	local square, under = currentSoil(player);

	return under;
end

AutoPilotMoon.JobMenu:define("bagSoil", {
	group = "ground",
	job = "soilBagger",
	labelKey = "IGUI_AutoPilot_M_BagSoil",
	label = function(player, params)
		return getText("IGUI_AutoPilot_M_BagSoil", soilName(SoilBagger:getMenuSoil(player, params)));
	end,
	menuParams = function(player)
		local soilType = SoilBagger:getMenuSoil(player, nil);

		return soilType and { soil = soilType } or nil;
	end,
	descKey = "IGUI_AutoPilot_T_Desc_BagSoil",
	whatKey = "IGUI_AutoPilot_D_TitleBags",
	onSpot = "IGUI_AutoPilot_D_OnSpotBags",   -- "Sul posto" first in the picker (13/11/2026)
	icon = "Base.Shovel",
	-- dirt, sand, gravel or clay on the clicked square (spec 2.2 rule 6)
	here = function(square, player)
		return AutoPilotMoon.Square:getSoilType(square) ~= nil;
	end,
	requirements = function(player, params)
		local soilType = SoilBagger:getMenuSoil(player, params);
		local requirements = {
			{ ok = soilType ~= nil, reasonKey = "IGUI_AutoPilot_A_WrongSoil" },
			AutoPilotMoon.JobMenu:shovelRequirement(player),
		};

		if soilType
		then
			local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

			table.insert(requirements, { ok = bag ~= nil, needKey = "IGUI_AutoPilot_T_NeedBag", haveText = bag and bag:getDisplayName() or nil });
		end

		return requirements;
	end,
	notes = function(player)
		return { { text = getText("IGUI_AutoPilot_T_BagsRefill") } };
	end,
	-- the squares of the entry's soil
	countFn = function(params)
		local soilType = SoilBagger:getMenuSoil(AutoPilotMoon:getPlayer(), params);

		return function(other)
			return soilType ~= nil and AutoPilotMoon.Square:getSoilType(other) == soilType;
		end;
	end,
	limits = function()
		return {
			getText("IGUI_AutoPilot_T_JobLimit", title(),
				getText("IGUI_AutoPilot_T_Limit_Squares", AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob"))),
			getText("IGUI_AutoPilot_T_PerTrip", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerTrip")),
		};
	end,
	start = function(player, rect, dest, params)
		local soilType = SoilBagger:getMenuSoil(player, params);

		if soilType == nil
		then
			return false;
		end

		local startSquare = nil;

		if dest == nil
		then
			startSquare = AutoPilotMoon.Square:getCurrent(player);
		end

		return A.startSoilBagger(player, AutoPilotMoon.Area:squares(rect), startSquare, soilType, { destination = dest, area = rect });
	end,
});
