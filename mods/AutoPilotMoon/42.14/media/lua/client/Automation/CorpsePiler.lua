-- AutoPilot (Moon): automations for the Moon server.

-- Corpse piler (Moon): carries the corpses of an area, one at a time, to the square where the player stood when
-- giving the order (the pile), with the game's own grab and drop.
-- - No placeholder in the queue any more: the queue holds only the squares with corpses, never the pile (B10); the
--   job ends when the queue is empty, wherever a square was postponed (the old placeholder stopped the job before the
--   squares sent back after it, and never dropped the last corpse of a second pass: N-A9).
-- - Carrying and dropping are the engine's "busy" answer, with their own limits (walks, drops, time), so a corpse that
--   takes a moment to land never gets its square discarded; a corpse that cannot be taken is tried twice, then left.
-- - Only dead bodies of zombies and people, players' bodies too (phase C: the rule "as by hand", the game lets you drag
--   them); never an animal (the game's "Grab corpse" leaves them out: handleGrabCorpseSubmenu of 42.22), nothing on a
--   burning square (B11); never from or to a protected zone; at most CorpsesPerJob corpses per job (N-S6).
-- Phase C (11/11/2026; ANALISI-WorkOrders.md 4.7, 6 row 7, spec 3.5 and 5):
-- - the pile is chosen after the area (the picker starts on the character's square: one click there is the old
--   behaviour); the area can be the whole building, every floor and the cellar (Grid:getAllSquaresInBuilding), capped by
--   MaxSquaresPerJob (the nearest to the pile);
-- - stuck while dragging (the character has not moved for Automation.corpseStuckMs): the corpse is left there, the job
--   goes on with the next one and the panel says it (W-B11 of Work Orders: never a grab "assumed" failed, never the
--   wrong corpse dragged);
-- - the grab is released whenever the job ends, whatever the reason (W-B8: no corpse left in the arms, no leftover
--   watcher), with the game's own release (ISWorldObjectContextMenu.handleGrabWorldItem_onDropCorpse);
-- - a corpse counts as moved (the panel's "Cadaveri spostati") when it is down on the pile.

require "05_AP_Config";
require "50_AP_Automation";

-- config

AutoPilotMoon.CorpsePiler = AutoPilotMoon.CorpsePiler or {};

local CP = AutoPilotMoon.CorpsePiler;

AutoPilotMoon.Automation:register("corpsePiler", {
	squareFilter = function(square, player)
		return #AutoPilotMoon.Square:getValidCorpses(square) > 0;
	end,
});

AutoPilotMoon.Automation:addJobStateField("corpseMoved");      -- corpses grabbed in this job
AutoPilotMoon.Automation:addJobStateField("corpseAttempts");   -- corpse -> grabs tried
AutoPilotMoon.Automation:addJobStateField("corpseCarry");      -- { walks, dropAt, drops }: the corpse being carried
AutoPilotMoon.Automation:addJobStateField("corpseGrab");       -- { corpse, at }: the grab just queued (at: first idle frame)
AutoPilotMoon.Automation:addJobStateField("corpsePlan");       -- what this step's square function does
AutoPilotMoon.Automation:addJobStateField("corpseStuck");      -- { x, y, since }: where the dragging character stands
AutoPilotMoon.Automation:addJobStateField("corpseLeftAt");     -- "x,y,z" -> true: a corpse left there, stuck

AutoPilotMoon.Automation.corpseMaxGrabs = 2;        -- grabs of the same corpse before it is left where it is
AutoPilotMoon.Automation.corpseMaxWalks = 3;        -- walks towards the pile before giving up
AutoPilotMoon.Automation.corpseDropWaitMs = 3000;   -- time for a corpse to land before dropping again
AutoPilotMoon.Automation.corpseMaxDrops = 3;        -- drops tried before giving up
AutoPilotMoon.Automation.corpseGrabWaitMs = 2000;   -- time for a grab to turn into dragging
AutoPilotMoon.Automation.corpseStuckMs = 2000;      -- not moving for this long while dragging: the corpse is left there
AutoPilotMoon.Automation.corpseStuckDistance = 0.1; -- what counts as not moving

-- filters

function AutoPilotMoon.Automation:getCorpsePilerTiles(squares, startSquare)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		return square ~= startSquare and #AutoPilotMoon.Square:getValidCorpses(square) > 0;
	end);
end

-- methods

function AutoPilotMoon.Automation.startCorpsePiler(player, squares, startSquare)
	startSquare = startSquare or AutoPilotMoon.Square:getCurrent(player);

	-- the pile itself is touched: never in a protected zone
	if startSquare == nil or AutoPilotMoon.Zones:isProtected(startSquare, player)
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", getText("IGUI_AutoPilot_O_Context_CorpsePiler"), getText("IGUI_AutoPilot_A_Reason_Protected")), player);

		return false;
	end

	return AutoPilotMoon.Automation:startJob("corpsePiler", player, squares, startSquare, function(list)
		return AutoPilotMoon.Automation:getCorpsePilerTiles(list, startSquare);
	end);
end

-- W-B8: the grab is released at every end of the job (done, stopped, zombies...), with the game's own release; only a
-- dead character keeps nothing to release
function AutoPilotMoon.Automation:stopCorpsePiler()
	local job = AutoPilotMoon.Automation.job;
	local player = job and job.player;

	AutoPilotMoon.Automation:stopSquareProcessingQueue("corpsePilerWorking");

	if player and not player:isDead() and player:isDraggingCorpse()
	then
		ISWorldObjectContextMenu.handleGrabWorldItem_onDropCorpse(player);
	end
end

local function squareKey(square)
	return square:getX() .. "," .. square:getY() .. "," .. square:getZ();
end

-- Every frame of the job, also while the character walks: dragging without moving for corpseStuckMs (a door, a
-- fence, another corpse in the way) leaves the corpse where the character is and the job goes on (Work Orders'
-- "stuck 2 seconds", W-B11). Returns true when it left one.
function AutoPilotMoon.CorpsePiler:watchDrag(player)
	local A = AutoPilotMoon.Automation;

	if not player:isDraggingCorpse() or not ISTimedActionQueue.isPlayerDoingAction(player)
	then
		A.corpseStuck = nil;

		return false;
	end

	local now = getTimestampMs();
	local x, y = player:getX(), player:getY();
	local stuck = A.corpseStuck;

	if stuck == nil or math.abs(x - stuck.x) > A.corpseStuckDistance or math.abs(y - stuck.y) > A.corpseStuckDistance
	then
		A.corpseStuck = { x = x, y = y, since = now };

		return false;
	end

	if now - stuck.since < A.corpseStuckMs
	then
		return false;
	end

	A.corpseStuck = nil;
	A.corpseCarry = nil;
	ISTimedActionQueue.clear(player);
	ISWorldObjectContextMenu.handleGrabWorldItem_onDropCorpse(player);

	local square = player:getSquare();

	if square
	then
		A:getJobSet("corpseLeftAt")[squareKey(square)] = true;
	end

	-- said in the panel (spec 5: "posa li' e lo dice nel registro"), not over the head
	AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_CorpseLeftStuck");

	return true;
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_CorpsePiler");
end

local function summary(key)
	return getText(key, title(), AutoPilotMoon.Automation:getJobCount("corpseMoved"));
end

-- carrying a corpse: to the pile, then drop it there (walks and drops limited)
local function carry(player, pile)
	local A = AutoPilotMoon.Automation;
	local carryState = A.corpseCarry;

	if carryState == nil
	then
		carryState = { walks = 0, drops = 0, dropAt = nil };
		A.corpseCarry = carryState;
	end

	-- the pile became protected during the job (a safehouse claimed on it): stop; the corpse is not carried into it,
	-- the job's end releases the grab where the character stands (W-B8)
	if AutoPilotMoon.Zones:isProtected(pile, player)
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_JobStoppedBecause", title(), getText("IGUI_AutoPilot_A_Reason_Protected")));

		return;
	end

	if player:getSquare() ~= pile
	then
		if carryState.walks >= A.corpseMaxWalks
		then
			-- the pile cannot be reached: leave the corpse here and stop
			ISWorldObjectContextMenu.handleGrabWorldItem_onDropCorpse(player);
			A:finishEarly(getText("IGUI_AutoPilot_A_CorpsePileUnreachable", title()));

			return;
		end

		carryState.walks = carryState.walks + 1;
		AutoPilotMoon.Square:walkTo(player, pile, true, false);

		return;
	end

	local now = getTimestampMs();

	if carryState.dropAt == nil or now - carryState.dropAt >= A.corpseDropWaitMs
	then
		if carryState.drops >= A.corpseMaxDrops
		then
			A:finishEarly(getText("IGUI_AutoPilot_A_CorpseNotDropped", title()));

			return;
		end

		carryState.drops = carryState.drops + 1;
		carryState.dropAt = now;
		ISWorldObjectContextMenu.handleGrabWorldItem_onDropCorpse(player);
	end
end

-- one step on a square: decide (removeCheckFunction), then the square function carries the plan out
function AutoPilotMoon.Automation:checkCorpsePilerSquare(square, player)
	local A = AutoPilotMoon.Automation;
	local pile = A.squareQueueStartSquare;

	A.corpsePlan = nil;

	-- a corpse in the arms: to the pile first, whatever the square at the head of the queue ("busy": the carry has its
	-- own limits, the engine's watchdog must not discard the square meanwhile)
	if player:isDraggingCorpse()
	then
		A.corpseGrab = nil;
		carry(player, pile);

		return "busy";
	end

	-- the corpse carried until now is down: on the pile it counts (spec 7.4.1: only what really happened)
	local carried = A.corpseCarry;

	if carried and carried.drops > 0 and player:getSquare() == pile
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Corpses");
	end

	A.corpseCarry = nil;

	-- a grab queued a moment ago: give the game time to start dragging
	local grab = A.corpseGrab;

	if grab
	then
		-- the wait starts at the first idle frame after the grab, not when it was queued: the walk to the corpse takes
		-- longer than the wait, and in multiplayer the dragging starts with the server's answer
		grab.at = grab.at or getTimestampMs();

		if getTimestampMs() - grab.at < A.corpseGrabWaitMs
		then
			return "busy";
		end
	end

	A.corpseGrab = nil;

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	if A:getJobSet("corpseLeftAt")[squareKey(square)]
	then
		-- a corpse was left here because the way was blocked: not tried again
		return "discard";
	end

	if A:getJobCount("corpseMoved") >= AutoPilotMoon.Sandbox:getInteger("CorpsesPerJob")
	then
		A:finishEarly(summary("IGUI_AutoPilot_A_CorpseCapReached"));

		return "discard";
	end

	local attempts = A:getJobSet("corpseAttempts");

	for i, corpse in ipairs(AutoPilotMoon.Square:getValidCorpses(square))
	do
		if (attempts[corpse] or 0) < A.corpseMaxGrabs
		then
			A.corpsePlan = { kind = "grab", square = square, corpse = corpse };

			return false;
		end
	end

	-- no corpse left that can be taken: the square is done
	return true;
end

function AutoPilotMoon.Automation:workCorpsePilerSquare(square, player)
	local A = AutoPilotMoon.Automation;
	local plan = A.corpsePlan;

	A.corpsePlan = nil;

	if plan == nil or plan.square ~= square
	then
		return;
	end

	if plan.kind == "grab"
	then
		local corpse = plan.corpse;
		local attempts = A:getJobSet("corpseAttempts");

		if AutoPilotMoon.Zones:isProtected(square, player) or corpse:getSquare() ~= square
		then
			return;
		end

		attempts[corpse] = (attempts[corpse] or 0) + 1;

		if attempts[corpse] == 1
		then
			A:addJobCount("corpseMoved");
		end

		A.corpseGrab = { corpse = corpse, at = nil };
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Dragging");
		ISWorldObjectContextMenu.onGrabCorpseItem(nil, corpse, player:getPlayerNum());
	end
end

function AutoPilotMoon.Automation:checkCorpsePilerQueue(player)
	CP:watchDrag(player);

	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "corpsePilerWorking",
		squareFunction = {
			fn = function(square, who)
				AutoPilotMoon.Automation:workCorpsePilerSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return AutoPilotMoon.Automation:checkCorpsePilerSquare(square, who);
		end,
		stopFunction = function()
			AutoPilotMoon.Automation:stopCorpsePiler();
		end,
	});
end

-- the pile (the second step after the area, spec 3.5): a square of ground the character can stand on

function AutoPilotMoon.CorpsePiler:inspectPile(square, player)
	local info = { ok = true, kind = "pile", x = square:getX(), y = square:getY(), z = square:getZ(),
		count = square:getDeadBodys():size() };

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Protected";
	elseif square:isWaterSquare()
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Water";
	elseif not square:TreatAsSolidFloor() or square:isSolid() or square:isSolidTrans()
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Unreachable";
	end

	return info;
end

function AutoPilotMoon.CorpsePiler:pileStep()
	return {
		whatKey = "IGUI_AutoPilot_D_TitlePile",
		howKey = "IGUI_AutoPilot_D_HowPile",
		startAtPlayer = true,
		noRemember = true,
		inspect = function(square, player)
			return CP:inspectPile(square, player);
		end,
		describe = function(info)
			return getText("IGUI_AutoPilot_D_PileCount", info.count);
		end,
		toDest = function(info)
			return { kind = "pile", x = info.x, y = info.y, z = info.z };
		end,
	};
end

-- the menu entry "Ammucchia i cadaveri" (client/75_AP_JobMenu.lua): the area (also this room, this building), then the
-- pile

AutoPilotMoon.JobMenu:define("pileCorpses", {
	group = "house",
	labelKey = "IGUI_AutoPilot_M_PileCorpses",
	job = "corpsePiler",
	descKey = "IGUI_AutoPilot_T_Desc_PileCorpses",
	rooms = true,
	here = true,
	notes = function(player)
		return { { text = getText("IGUI_AutoPilot_T_PlayerCorpses") }, { text = getText("IGUI_AutoPilot_T_CorpseStuck") } };
	end,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", getText("IGUI_AutoPilot_O_Context_CorpsePiler"),
			getText("IGUI_AutoPilot_T_Limit_Corpses", AutoPilotMoon.Sandbox:getInteger("CorpsesPerJob"))) };
	end,
	second = function(params)
		return CP:pileStep();
	end,
	start = function(player, region, dest, params)
		local pile = dest and getCell():getGridSquare(dest.x, dest.y, dest.z);

		if pile == nil
		then
			return false;
		end

		return AutoPilotMoon.Automation.startCorpsePiler(player, AutoPilotMoon.JobMenu:squaresOf(region), pile);
	end,
});
