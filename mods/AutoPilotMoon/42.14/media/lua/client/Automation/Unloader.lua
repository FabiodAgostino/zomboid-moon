-- AutoPilot (Moon): automations for the Moon server.

-- Unloader (Moon): drops what the world's containers hold onto the floor next to them, with the game's own
-- transfer actions (the server checks each one), within the server's limits (L2):
-- - at most UnloaderItemsPerStep items per step and UnloaderItemsPerJob per job, then the job ends with a summary;
-- - every container of a square, one after the other (B14), each tried once per job;
-- - never a container locked for the character (N-A3) nor a ZomBOT gravestone (N-M3), nothing in a protected zone (a
--   safehouse the player may not use, checked at the start and before each container); jukeboxes and coffins are
--   emptied like any container (what a player can do by hand, the mod can do);
-- - favourites, equipped or worn items and furniture packed as items stay inside (N-S10); keys go out like any loot;
-- - a container never opened is opened first, as the loot window does, and its content awaited from the arrival next
--   to it with the engine's wait (1.2.1: never isExplored(), which the game sets before the items come; 1.2.0 waited a
--   fixed 1.5 s from the request, made before the walk);
-- - what went out is counted by id once the server's answer is there (1.2.1: never what was queued), a refusal seen at
--   once: the container is left with "unable to empty" when nothing went out;
-- - nothing is dropped when the floor around has no room left (the square is skipped, with a message): the room is
--   the 3x3 around the character, where the game lays what is dropped.

require "05_AP_Config";
require "50_AP_Automation";

-- config

-- squareFilter: a container with something to take out (the area tool's count, the "Qui" block)
AutoPilotMoon.Automation:register("unloader", {
	squareFilter = function(square, player)
		return #AutoPilotMoon.Automation:getUnloaderTiles({ square }, player) > 0;
	end,
});

AutoPilotMoon.Automation:addJobStateField("unloaderTried");     -- containers done or given up in this job
AutoPilotMoon.Automation:addJobStateField("unloaderMoved");     -- items that really went out to the floor in this job
AutoPilotMoon.Automation:addJobStateField("unloaderWait");      -- { kind = "load" | "drop", container, wait }
AutoPilotMoon.Automation:addJobStateField("unloaderPlan");      -- what this step's square function does

-- filters

-- the containers of a square the player may unload, in the order of the square's objects
function AutoPilotMoon.Automation:getUnloaderContainers(square, player)
	local result = {};
	local objects = square:getObjects();

	for i = 0, objects:size() - 1
	do
		local object = objects:get(i);

		for j, container in ipairs(AutoPilotMoon.Item:getUnloadableContainers(object, player))
		do
			table.insert(result, { object = object, container = container });
		end
	end

	return result;
end

-- something to take out, or a content still unknown
local function hasWork(container)
	if not container:isExplored()
	then
		return true;
	end

	local items = AutoPilotMoon.Item:getUnloadableItems(container);

	return #items > 0;
end

function AutoPilotMoon.Automation:getUnloaderTiles(squares, player)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		for i, entry in ipairs(AutoPilotMoon.Automation:getUnloaderContainers(square, player))
		do
			if hasWork(entry.container)
			then
				return true;
			end
		end

		return false;
	end);
end

-- methods

function AutoPilotMoon.Automation.startUnloader(player, squares, startSquare)
	return AutoPilotMoon.Automation:startJob("unloader", player, squares, startSquare, function(list, who)
		return AutoPilotMoon.Automation:getUnloaderTiles(list, who);
	end);
end

-- the items that really went out (spec 7.4.1: only what happened counts in "Oggetti lasciati a terra")
local function countDropped(arrived)
	if arrived > 0
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Dropped", arrived);
		AutoPilotMoon.Automation:addJobCount("unloaderMoved", arrived);
	end
end

-- the last step's wait (a container's content, or the items sent to the floor): "busy", or nil once over
local function settleWait()
	local A = AutoPilotMoon.Automation;
	local pending = A.unloaderWait;

	if pending == nil
	then
		return nil;
	end

	local answer, why, info = pending.wait:check();

	if answer == "busy"
	then
		return "busy";
	end

	A.unloaderWait = nil;

	if pending.kind == "drop"
	then
		countDropped(info.arrived);

		if info.arrived == 0
		then
			-- nothing went out: the server refused the transfers
			A:getJobSet("unloaderTried")[pending.container] = true;
			AutoPilotMoon:message(getText("IGUI_AutoPilot_A_UnableToEmptyContainer"));
		end
	end

	return nil;
end

function AutoPilotMoon.Automation:stopUnloader()
	local pending = AutoPilotMoon.Automation.unloaderWait;

	if pending and pending.kind == "drop"
	then
		countDropped(pending.wait:settle());
	end

	AutoPilotMoon.Automation.unloaderWait = nil;
	AutoPilotMoon.Automation:stopSquareProcessingQueue("unloaderWorking");
end

local function summary(key)
	return getText(key, getText("IGUI_AutoPilot_O_Context_Unloader"), AutoPilotMoon.Automation:getJobCount("unloaderMoved"));
end

-- one step on a square: decide (removeCheckFunction), then the square function carries the plan out
function AutoPilotMoon.Automation:checkUnloaderSquare(square, player)
	local A = AutoPilotMoon.Automation;

	A.unloaderPlan = nil;

	if settleWait() == "busy"
	then
		return "busy";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return "discard";
	end

	local jobCap = AutoPilotMoon.Sandbox:getInteger("UnloaderItemsPerJob");
	local moved = A:getJobCount("unloaderMoved");

	if moved >= jobCap
	then
		A:finishEarly(summary("IGUI_AutoPilot_A_UnloaderCapReached"));

		return "discard";
	end

	if A:relocateIfNeeded(square, player)
	then
		return "wait";
	end

	local tried = A:getJobSet("unloaderTried");

	for i, entry in ipairs(A:getUnloaderContainers(square, player))
	do
		local container = entry.container;

		if not tried[container]
		then
			local state = AutoPilotMoon.Wait:loadState(container);

			if state == "unknown"
			then
				A.unloaderPlan = { kind = "explore", square = square, object = entry.object, container = container };

				return false;
			end

			if state == "loading"
			then
				-- asked for before the walk: its answer awaited from the arrival next to it (never a fixed time)
				local wait = AutoPilotMoon.Wait:new(player, { label = AutoPilotMoon.Destination:getContainerName(container),
					waitingAfterMs = 0 });

				AutoPilotMoon.Wait:restartLoad(container);
				wait:expectLoaded(container);
				A.unloaderWait = { kind = "load", container = container, wait = wait };

				return "busy";
			end

			local items = AutoPilotMoon.Item:getUnloadableItems(container);

			if #items == 0
			then
				tried[container] = true;
			else
				-- the game lays what is dropped on the 3x3 around the character (next to the container once there)
				local here = player:getSquare();
				local near = here and math.abs(here:getX() - square:getX()) <= 1 and math.abs(here:getY() - square:getY()) <= 1;
				local room = AutoPilotMoon.Item:getFloorRoom(near and here or square, player);
				local max = AutoPilotMoon.Sandbox:getInteger("UnloaderItemsPerStep");

				if jobCap - moved < max
				then
					max = jobCap - moved;
				end

				local step = AutoPilotMoon.Item:takeFitting(items, max, room);

				if #step == 0
				then
					AutoPilotMoon:message(getText("IGUI_AutoPilot_A_FloorFull"));

					return "discard";
				end

				-- unloaderLast is written when the transfers are queued (workUnloaderSquare): a step the engine
				-- does not carry out (no free tile next to the square) must not look like a refusal next time
				A.unloaderPlan = { kind = "unload", square = square, object = entry.object, container = container, items = step,
					count = #items };

				return false;
			end
		end
	end

	-- every container of the square done
	return true;
end

-- the square function: carries out the step's plan, after checking the zone and the object once more
function AutoPilotMoon.Automation:workUnloaderSquare(square, player)
	local A = AutoPilotMoon.Automation;
	local plan = A.unloaderPlan;

	A.unloaderPlan = nil;

	if plan == nil or plan.square ~= square
	then
		return;
	end

	if AutoPilotMoon.Zones:isProtected(square, player) or AutoPilotMoon.Zones:isProtectedObject(plan.object)
		or AutoPilotMoon.Item:isLockedFor(plan.object, plan.container, player)
	then
		A:getJobSet("unloaderTried")[plan.container] = true;

		return;
	end

	if not AutoPilotMoon.Square:walkTo(player, square, true)
	then
		A:getJobSet("unloaderTried")[plan.container] = true;

		return;
	end

	if plan.kind == "explore"
	then
		AutoPilotMoon.Item:explore(plan.container, player);

		if not plan.container:isExplored()
		then
			A:getJobSet("unloaderTried")[plan.container] = true;
		end

		return;
	end

	local wait = AutoPilotMoon.Wait:new(player, { label = getText("IGUI_AutoPilot_W_Dropped") });

	AutoPilotMoon.Item:queueDropToFloor(player, plan.container, plan.items, wait);
	A.unloaderWait = { kind = "drop", container = plan.container, wait = wait };
end

function AutoPilotMoon.Automation:checkUnloaderQueue(player)
	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "unloaderWorking",
		squareFunction = {
			fn = function(square, who)
				AutoPilotMoon.Automation:workUnloaderSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return AutoPilotMoon.Automation:checkUnloaderSquare(square, who);
		end,
		stopFunction = function()
			AutoPilotMoon.Automation:stopUnloader();
		end,
	});
end

-- the menu entry "Svuota i contenitori" (client/75_AP_JobMenu.lua): every area mode (spec 5)

AutoPilotMoon.JobMenu:define("unload", {
	group = "house",
	labelKey = "IGUI_AutoPilot_M_Unload",
	job = "unloader",
	descKey = "IGUI_AutoPilot_T_Desc_Unload",
	rooms = true,
	here = true,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", getText("IGUI_AutoPilot_O_Context_Unloader"),
			getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("UnloaderItemsPerJob"))) };
	end,
	start = function(player, region)
		return AutoPilotMoon.Automation.startUnloader(player, AutoPilotMoon.JobMenu:squaresOf(region), player:getSquare());
	end,
});
