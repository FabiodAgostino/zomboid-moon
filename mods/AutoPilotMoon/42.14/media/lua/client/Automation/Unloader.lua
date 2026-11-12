-- AutoPilot (Moon): automations for the Moon server.

-- Unloader (Moon): drops what the world's containers hold onto the floor next to them, with the game's own
-- transfer actions (the server checks each one), within the server's limits (L2):
-- - at most UnloaderItemsPerStep items per step and UnloaderItemsPerJob per job, then the job ends with a summary;
-- - every container of a square, one after the other (B14), each tried once per job;
-- - never a container locked for the character (N-A3) nor a ZomBOT gravestone (N-M3), nothing in a protected zone (a
--   safehouse the player may not use, checked at the start and before each container); jukeboxes and coffins are
--   emptied like any container (what a player can do by hand, the mod can do);
-- - favourites, equipped or worn items and furniture packed as items stay inside (N-S10); keys go out like any loot;
-- - a container never opened is opened first, as the loot window does, and its content awaited a moment (N-A4);
-- - nothing is dropped when the floor around has no room left (the square is skipped, with a message).

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
AutoPilotMoon.Automation:addJobStateField("unloaderMoved");     -- items queued for the floor in this job
AutoPilotMoon.Automation:addJobStateField("unloaderLast");      -- { container, count }: the container of the last step
AutoPilotMoon.Automation:addJobStateField("unloaderExplored");  -- container -> when it was first opened
AutoPilotMoon.Automation:addJobStateField("unloaderPlan");      -- what this step's square function does

AutoPilotMoon.Automation.unloaderExploreMs = 1500;

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

-- the items that really went out of the last container since they were sent (spec 7.4.1: only what happened counts in
-- "Oggetti lasciati a terra"); called at every step and at the end
local function confirmDropped()
	local last = AutoPilotMoon.Automation.unloaderLast;

	if last == nil or last.seen == nil
	then
		return;
	end

	local left = #AutoPilotMoon.Item:getUnloadableItems(last.container);

	if left < last.seen
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Dropped", last.seen - left);
		last.seen = left;
	end
end

function AutoPilotMoon.Automation:stopUnloader()
	confirmDropped();
	AutoPilotMoon.Automation:stopSquareProcessingQueue("unloaderWorking");
end

local function summary(key)
	return getText(key, getText("IGUI_AutoPilot_O_Context_Unloader"), AutoPilotMoon.Automation:getJobCount("unloaderMoved"));
end

-- one step on a square: decide (removeCheckFunction), then the square function carries the plan out
function AutoPilotMoon.Automation:checkUnloaderSquare(square, player)
	local A = AutoPilotMoon.Automation;

	A.unloaderPlan = nil;
	confirmDropped();

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
	local explored = A:getJobSet("unloaderExplored");
	local now = getTimestampMs();

	for i, entry in ipairs(A:getUnloaderContainers(square, player))
	do
		local container = entry.container;

		if not tried[container]
		then
			if not container:isExplored()
			then
				A.unloaderPlan = { kind = "explore", square = square, object = entry.object, container = container };

				return false;
			end

			local items = AutoPilotMoon.Item:getUnloadableItems(container);

			if #items == 0 and explored[container] and now - explored[container] < A.unloaderExploreMs
			then
				-- opened a moment ago: the server's items may still be on their way
				return false;
			end

			local last = A.unloaderLast;

			if #items == 0
			then
				tried[container] = true;
			elseif last and last.container == container and #items >= last.count
			then
				-- nothing went out since the last step: the server refused the transfers
				tried[container] = true;
				AutoPilotMoon:message(getText("IGUI_AutoPilot_A_UnableToEmptyContainer"));
			else
				local room = AutoPilotMoon.Item:getFloorRoom(square, player);
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
		A:getJobSet("unloaderExplored")[plan.container] = getTimestampMs();

		if not plan.container:isExplored()
		then
			A:getJobSet("unloaderTried")[plan.container] = true;
		end

		return;
	end

	A:addJobCount("unloaderMoved", AutoPilotMoon.Item:queueDropToFloor(player, plan.container, plan.items));
	A.unloaderLast = { container = plan.container, count = plan.count, seen = plan.count };
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
