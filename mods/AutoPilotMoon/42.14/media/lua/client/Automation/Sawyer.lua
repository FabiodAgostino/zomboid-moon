-- AutoPilot (Moon): automations for the Moon server.

-- Sawyer (Segantino, 11/11/2026, phase B; ANALISI-WorkOrders.md 6 point 2, spec UX-AUTOPILOT.md 5): saws the logs of an
-- area into planks with the game's own recipe (SawLogs), as by hand:
-- - which logs: the logs lying on the ground in the area (Base.Log), and the logs the character already carries (they
--   are sawn first, where the character stands). Logs in containers (crates, trunks) are left alone: picking from a
--   container is the Unloader's business.
-- - how (owner's test of 12/11/2026: no more picking the log up into the bag first): a log on the ground is sawn where it
--   lies, the way the game does it by hand: the character walks next to it (the game's walk to a free square next to
--   it, AdjacentFreeTileFinder, as luautils.walkAdj), then the recipe is chosen on the log in the loot window's floor
--   (ISInventoryPaneContextMenu.OnNewCraft with the world item: SawLogs is CanBeDoneFromFloor in 42.22, so the game
--   moves nothing and the ISHandcraftAction consumes the log from the ground; client/64_AP_Craft.lua). A log the
--   character carries is sawn in the inventory, where the character stands. The planks go into the inventory as by
--   hand (the game drops them at the character's feet when they do not fit). The heavy log is never carried.
-- - a log it cannot get next to (no free square around it, or still out of the loot window's reach after
--   Sawyer.maxWalks walks: a wall) is left with the warning "unreachable".
-- - the planks: carried to the destination (AutoPilotMoon.Haul) when the character could not take the planks of another
--   log (its load, the server's items per trip: the log's weight as the measure, as before), and at the end.
-- - "Sul posto" ("On the spot", the first choice of the destination picker since 12/11/2026) and the chain "Taglia e
--   sega" (user's decision of 12/11/2026): no destination, the planks stay ON THE GROUND next to the sawn log, never
--   carried away: right after each recipe they are put down with the game's own "place item"
--   (ISDropWorldItemAction with isPlaceItem, as the cursor ISPlace3DItemCursor does), on the log's square or, when the
--   game would refuse it there (more than Sawyer.floorLimit of weight on it, not next to the character, blocked by a
--   wall), on the nearest square next to the character that it accepts. Only what really left the inventory counts
--   ("Planks left on the ground"); what the server refuses three times stays in the bag with the warning. No square
--   around takes them: stop "no room on the ground next to the log".
-- - stops with the reason: no saw ("you need a saw"), too dark (the game does not saw in the dark: it says so and stops,
--   no rule of ours), too tired, the game refusing the recipe, the destination gone / full / locked.
-- - SawyerLogsPerJob logs per job (server); reached, the planks are delivered and the job ends as finished (a chain goes
--   on with its next phase).
-- Never walks to a log it could not saw (W-B3): the saw, the light and the endurance are checked before each walk.

require "05_AP_Config";
require "50_AP_Automation";

local A = AutoPilotMoon.Automation;
local Haul = AutoPilotMoon.Haul;
local Craft = AutoPilotMoon.Craft;

AutoPilotMoon.Sawyer = AutoPilotMoon.Sawyer or {};

local Sawyer = AutoPilotMoon.Sawyer;

Sawyer.recipeName = "SawLogs";
Sawyer.logType = "Base.Log";
Sawyer.outputs = { ["Base.Plank"] = true };
Sawyer.maxTries = 3;          -- recipes started on the same log that do not saw it before it is left
Sawyer.carryPerJob = 100000;  -- the planks carried are bounded by the logs per job, not by the Gatherer's limit
Sawyer.floorLimit = 50;       -- ISDropWorldItemAction:isValid of 42.22: no more than 50 of weight on the square
Sawyer.dropGraceMs = 1500;    -- the drops ended and a plank is still in the inventory: the server may still answer
Sawyer.maxDropTries = 3;      -- drops of the same plank that do not happen before it is left in the bag
Sawyer.maxWalks = 3;          -- walks towards the same log that do not bring it within reach before it is left

function Sawyer.isLog(item)
	return item:getFullType() == Sawyer.logType;
end

function Sawyer:getLimit()
	return AutoPilotMoon.Sandbox:getInteger("SawyerLogsPerJob");
end

A:register("sawyer", {
	squareFilter = function(square, player)
		return Haul:squareHas(square, Sawyer.isLog, nil);
	end,
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
});

A:addJobStateField("sawyerState");

local function title()
	return getText("IGUI_AutoPilot_O_Context_Sawyer");
end

-- the logs the character carries that may be sawn (not favourites, not equipped)
function Sawyer:getCarriedLogs(player, skip)
	return AutoPilotMoon.Carry:collectCargo(player, function(item)
		return Sawyer.isLog(item) and not (skip and skip[item:getID()]);
	end);
end

-- Starts the Sawyer for the player on the squares (a list or a function). ctx (optional): destination (where the
-- planks go; none, "Sul posto": they stay on the ground next to each log), run (a chain's ctx: what an earlier phase
-- delivered is never picked up again).
function AutoPilotMoon.Automation.startSawyer(player, squares, startSquare, ctx)
	local dest = ctx and ctx.destination;
	local logs = 0;

	local started = A:startJob("sawyer", player, squares, startSquare, function(list, who)
		local kept = AutoPilotMoon.Grid:filterSquaresBy(list, function(square)
			return Haul:squareHas(square, Sawyer.isLog, dest);
		end);

		logs = Haul:countOn(kept, Sawyer.isLog, dest);

		local carried = #Sawyer:getCarriedLogs(who);

		if carried > 0
		then
			logs = logs + carried;

			if #kept == 0
			then
				-- only the logs it carries: sawn where the character stands
				table.insert(kept, who:getSquare());
			end
		end

		return kept;
	end);

	if started
	then
		A.sawyerState = {
			hauler = Haul:new(player, dest, { perJob = Sawyer.carryPerJob, shared = ctx and ctx.run }),
			sawn = 0,
			craft = nil,
			tries = {},
			unsawn = {},
			leave = dest == nil,   -- no destination: the planks stay on the ground next to the log
			logFrom = {},          -- log id -> { x, y, z } of the square where it lay (sawn there)
			walks = {},            -- log id -> walks towards it
			drop = nil,            -- the planks being put down: { from, entries = { item, id, done }, idleSince }
			dropTries = {},        -- plank id -> drops that did not happen
		};

		local limit = Sawyer:getLimit();

		if logs > limit
		then
			logs = limit;
		end

		AutoPilotMoon.Progress:setUnits(logs, "IGUI_AutoPilot_S_Unit_Logs");
	end

	return started;
end

function AutoPilotMoon.Automation:stopSawyer()
	A:stopSquareProcessingQueue("sawyerWorking");
end

-- why the character cannot saw now (and the job stops), checked before every walk and every recipe (W-B3)
local function refusal(player, recipe)
	if recipe == nil
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_GameRefused", Sawyer.recipeName));

		return true;
	end

	if not AutoPilotMoon.Item:getSaw(player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedSaw")));

		return true;
	end

	if not recipe:canBeDoneInDark() and player:tooDarkToRead()
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_TooDark"));

		return true;
	end

	if not player:isEnduranceSufficientForAction()
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_TooTired", title()));

		return true;
	end

	return false;
end

-- the limit reached: the planks are delivered, then the job ends as finished
local function finishAtLimit(S)
	if Haul:deliver(S.hauler)
	then
		return "busy";
	end

	A:finishDone(getText("IGUI_AutoPilot_A_LimitReached", title(), getText("IGUI_AutoPilot_T_Limit_Logs", Sawyer:getLimit())));

	return "discard";
end

-- the recipe on one log: in the inventory, or on the ground within reach (the loot window's floor)
local function saw(S, player, recipe, log)
	local reason = Craft:check(player, recipe, log);

	if reason == "dark"
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_TooDark"));

		return "discard";
	elseif reason
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_GameRefused", Craft:getRecipeName(recipe)));

		return "discard";
	end

	local pending = Craft:start(player, recipe, log, Sawyer.outputs);

	if pending == nil
	then
		local id = log:getID();

		S.tries[id] = (S.tries[id] or 0) + 1;

		if S.tries[id] >= Sawyer.maxTries
		then
			S.unsawn[id] = true;
			AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_GameRefused");
		end

		return "busy";
	end

	S.craft = pending;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Sawing", S.sawn + 1);

	return "busy";
end

-- leaving the planks on the ground (no destination)

local function floorSquare(x, y, z)
	local cell = getCell();

	return cell and cell:getGridSquare(x, y, z) or nil;
end

-- the squares the game lets the character put an item on, nearest to the log first (the log's own square, then its
-- neighbours; ties: the character's square, then the others in a fixed order): next to the character (or its own
-- square), not blocked by a wall, a floor to put it on, not water, not a protected zone
local function dropTargets(player, from)
	local here = player:getSquare();
	local targets = {};

	if here == nil
	then
		return targets;
	end

	local hx, hy, hz = here:getX(), here:getY(), here:getZ();
	local fx, fy = hx, hy;

	if from and from.z == hz
	then
		fx, fy = from.x, from.y;
	end

	for dx = -1, 1
	do
		for dy = -1, 1
		do
			local square = floorSquare(hx + dx, hy + dy, hz);

			if square and square:TreatAsSolidFloor() and not square:isSolid() and not square:isSolidTrans()
				and not square:isWaterSquare() and (square == here or not square:isBlockedTo(here))
				and not AutoPilotMoon.Zones:isProtected(square, player)
			then
				local ex, ey = square:getX() - fx, square:getY() - fy;

				table.insert(targets, {
					square = square,
					distance = ex * ex + ey * ey,
					own = square == here and 0 or 1,
					order = (dx + 1) * 3 + dy + 1,
					weight = square:getTotalWeightOfItemsOnFloor(),
				});
			end
		end
	end

	table.sort(targets, function(a, b)
		if a.distance ~= b.distance
		then
			return a.distance < b.distance;
		end

		if a.own ~= b.own
		then
			return a.own < b.own;
		end

		return a.order < b.order;
	end);

	return targets;
end

-- the planks (items still in the inventory) put down with the game's "place item", each on the nearest square that
-- takes its weight; false when no square takes any
local function startDrop(S, player, items, from)
	local targets = dropTargets(player, from);
	local entries = {};

	for i, item in ipairs(items)
	do
		local weight = item:getUnequippedWeight();

		for j, target in ipairs(targets)
		do
			if target.weight + weight <= Sawyer.floorLimit
			then
				local n = #entries;
				local action = ISDropWorldItemAction:new(player, item, target.square, 0.3 + 0.2 * (n % 3),
					0.3 + 0.2 * (math.floor(n / 3) % 3), 0, (n * 37) % 360, #items > 1);

				action.isPlaceItem = true;
				ISTimedActionQueue.add(action);
				target.weight = target.weight + weight;
				table.insert(entries, { item = item, id = item:getID(), done = false });

				break;
			end
		end
	end

	if #entries == 0
	then
		return false;
	end

	S.drop = { from = from, entries = entries, idleSince = nil };
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_LeavingPlanks", #entries);

	return true;
end

-- the drop's outcome once the character is idle again: "busy" (waiting, or a new try queued), "stop" (nowhere to put
-- them), nil (done: counted, or left in the bag after Sawyer.maxDropTries)
local function confirmDrop(S, player)
	local drop = S.drop;
	local inventory = player:getInventory();
	local now = getTimestampMs();
	local waiting = false;

	for i, entry in ipairs(drop.entries)
	do
		if not entry.done
		then
			if inventory:getItemWithIDRecursiv(entry.id) == nil
			then
				entry.done = true;
				AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_PlanksLeft");
			else
				waiting = true;
			end
		end
	end

	drop.idleSince = drop.idleSince or now;

	if waiting and now - drop.idleSince < Sawyer.dropGraceMs
	then
		AutoPilotMoon.Progress:setWaiting(true);

		return "busy";
	end

	AutoPilotMoon.Progress:setWaiting(false);
	S.drop = nil;

	local again = {};

	for i, entry in ipairs(drop.entries)
	do
		if not entry.done
		then
			S.dropTries[entry.id] = (S.dropTries[entry.id] or 0) + 1;

			if S.dropTries[entry.id] >= Sawyer.maxDropTries
			then
				AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Reason_ServerRefused");
			else
				table.insert(again, entry.item);
			end
		end
	end

	if #again > 0
	then
		if startDrop(S, player, again, drop.from)
		then
			return "busy";
		end

		return "stop";
	end

	return nil;
end

-- what a finished recipe did: the log gone (sawn, counted), the planks made (cargo, or put down next to the log)
local function confirmSaw(S, player)
	local result, consumed, outputs = Craft:confirm(S.craft, player);

	if result == "busy"
	then
		return "busy";
	end

	local id = S.craft.itemId;

	S.craft = nil;

	if not S.leave
	then
		for i, item in ipairs(outputs)
		do
			Haul:addCargo(S.hauler, item);
		end
	end

	if consumed
	then
		S.sawn = S.sawn + 1;
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_LogsSawn");
		AutoPilotMoon.Progress:addUnitsDone(1);
	else
		S.tries[id] = (S.tries[id] or 0) + 1;

		if S.tries[id] >= Sawyer.maxTries
		then
			-- left as it is, where it is (on the ground, or in the bag when the character carried it)
			S.unsawn[id] = true;
			AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_GameRefused");
		end
	end

	if S.leave and #outputs > 0
	then
		if startDrop(S, player, outputs, S.logFrom[id])
		then
			return "busy";
		end

		return "stop";
	end

	return nil;
end

-- The log is out of reach (the loot window's floor does not list it): the game's walk to a free square next to it
-- (AdjacentFreeTileFinder and ISWalkToTimedAction, as luautils.walkAdj). "busy" while walking; after Sawyer.maxWalks
-- walks, or with no free square next to it, the log is left with the warning "unreachable" and the next decision goes
-- on with the next log.
local function approach(S, player, square, log)
	local id = log:getID();

	S.walks[id] = (S.walks[id] or 0) + 1;

	local adjacent = nil;

	if S.walks[id] <= Sawyer.maxWalks
	then
		adjacent = AdjacentFreeTileFinder.Find(square, player);
	end

	if adjacent == nil
	then
		S.unsawn[id] = true;
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Unreachable");

		return "busy";
	end

	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Sawing", S.sawn + 1);
	ISTimedActionQueue.add(ISWalkToTimedAction:new(player, adjacent));

	return "busy";
end

-- One decision while the character is idle (the engine's removeCheckFunction). "busy" while the job does something of
-- its own (a walk, a recipe, a trip: their own limits), true when the square is done.
function AutoPilotMoon.Automation:checkSawyerSquare(square, player)
	local S = A.sawyerState;

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

	if S.drop
	then
		local dropped = confirmDrop(S, player);

		if dropped == "busy"
		then
			return "busy";
		elseif dropped == "stop"
		then
			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NoRoomForPlanks"));

			return "discard";
		end
	end

	if S.craft
	then
		local sawn = confirmSaw(S, player);

		if sawn == "busy"
		then
			return "busy";
		elseif sawn == "stop"
		then
			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NoRoomForPlanks"));

			return "discard";
		end
	end

	if S.sawn >= Sawyer:getLimit()
	then
		return finishAtLimit(S);
	end

	local recipe = Craft:getRecipe(Sawyer.recipeName);

	-- a log in the inventory first: picked up by this job, or the character's own
	local carried = Sawyer:getCarriedLogs(player, S.unsawn);

	if #carried > 0
	then
		if refusal(player, recipe)
		then
			return "discard";
		end

		return saw(S, player, recipe, carried[1]);
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	local entries = Haul:findOnSquare(h, square, function(item)
		return Sawyer.isLog(item) and not S.unsawn[item:getID()];
	end, true);

	if #entries == 0
	then
		-- nothing left here; before the last square ends, the planks go to the destination
		if Haul:isLastSquare() and Haul:deliver(h)
		then
			return "busy";
		end

		return true;
	end

	if refusal(player, recipe)
	then
		return "discard";
	end

	local log = entries[1].item;

	-- with a destination: room for the planks of this log (the log's weight as the measure), else a trip first
	if not S.leave and not Haul:canPick(h, log:getUnequippedWeight())
	then
		if Haul:deliver(h)
		then
			return "busy";
		end

		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_BagFull"));

		return "discard";
	end

	-- sawn where it lies: first next to it, within the loot window's reach
	if not Craft:canReach(player, log)
	then
		return approach(S, player, square, log);
	end

	S.logFrom[log:getID()] = { x = square:getX(), y = square:getY(), z = square:getZ() };

	return saw(S, player, recipe, log);
end

function AutoPilotMoon.Automation:checkSawyerQueue(player)
	A:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "sawyerWorking",
		squareFunction = {
			fn = function() end,
		},
		removeCheckFunction = function(square, who)
			return A:checkSawyerSquare(square, who);
		end,
		stopFunction = function()
			A:stopSawyer();
		end,
	});
end

-- the menu entry (client/75_AP_JobMenu.lua)

local function sawRequirement(player)
	return AutoPilotMoon.JobMenu:sawRequirement(player);
end

Sawyer.sawRequirement = sawRequirement;

AutoPilotMoon.JobMenu:define("sawLogs", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_SawLogs",
	job = "sawyer",
	descKey = "IGUI_AutoPilot_T_Desc_SawLogs",
	whatKey = "IGUI_AutoPilot_D_TitlePlanks",
	onSpot = "IGUI_AutoPilot_D_OnSpotPlanks",   -- "Sul posto" first in the picker (12/11/2026)
	here = true,
	icon = "Base.Saw",
	requirements = function(player)
		return { sawRequirement(player) };
	end,
	notes = function(player)
		local notes = { { text = getText("IGUI_AutoPilot_T_AlsoCarriedLogs") } };

		-- not grey: the light can come (spec 5)
		if player:tooDarkToRead()
		then
			table.insert(notes, 1, { text = getText("IGUI_AutoPilot_T_TooDarkToSaw"), bad = true });
		end

		return notes;
	end,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", title(), getText("IGUI_AutoPilot_T_Limit_Logs", Sawyer:getLimit())) };
	end,
	start = function(player, rect, dest)
		return A.startSawyer(player, AutoPilotMoon.Area:squares(rect), nil, { destination = dest, area = rect });
	end,
});
