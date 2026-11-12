-- AutoPilot (Moon): automations for the Moon server.

-- Woodcutter (Spaccalegna, "Fai legna da ardere", 11/11/2026, phase B; ANALISI-WorkOrders.md 6 point 9 and 8.1 e,
-- spec UX-AUTOPILOT.md 5): turns the logs and large branches of an area into firewood with the game's own recipes,
-- ChopLog (a log: 6 firewood and splinters) and ChopLargeBranch (a large branch: 4 firewood and splinters), and
-- carries the firewood to the destination.
-- - Where it chops: the game's recipes are "any surface" crafts: they need a work surface (a table, a counter...) within
--   2 squares of the character, and an axe that is not dull. A wood has no table, so the job picks up the logs, carries
--   them to the destination and chops them there, on the surface next to it; then the firewood (and the splinters)
--   goes into the destination. A destination without a work surface within 2 squares is refused at the start, with
--   the game's own word ("una superficie di lavoro").
-- - which logs: on the ground in the area, and the ones the character already carries; never from containers.
-- - stops with the reason: no axe, too dark (the game does not chop in the dark), too tired, no surface, the game
--   refusing the recipe, the destination gone / full / locked / unreachable.
-- - FirewoodLogsPerJob logs (and large branches) per job (server).

require "05_AP_Config";
require "50_AP_Automation";

local A = AutoPilotMoon.Automation;
local Haul = AutoPilotMoon.Haul;
local Craft = AutoPilotMoon.Craft;

AutoPilotMoon.Firewood = AutoPilotMoon.Firewood or {};

local Firewood = AutoPilotMoon.Firewood;

-- the game's recipe for each kind of input
Firewood.recipes = {
	["Base.Log"] = "ChopLog",
	["Base.LargeBranch"] = "ChopLargeBranch",
};
Firewood.outputs = { ["Base.Firewood"] = true, ["Base.Splinters"] = true };
Firewood.firewoodType = "Base.Firewood";
Firewood.maxTries = 3;           -- recipes started on the same log that do not chop it before it is left
Firewood.maxWalks = 3;           -- walks to the destination that do not get there before it counts as unreachable
Firewood.nearDestination = 2;    -- the character chops within this distance of the destination
Firewood.carryPerJob = 100000;   -- the firewood carried is bounded by the logs per job

function Firewood.isChoppable(item)
	return Firewood.recipes[item:getFullType()] ~= nil;
end

function Firewood:getLimit()
	return AutoPilotMoon.Sandbox:getInteger("FirewoodLogsPerJob");
end

A:register("firewood", {
	squareFilter = function(square, player)
		return Haul:squareHas(square, Firewood.isChoppable, nil);
	end,
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
});

A:addJobStateField("firewoodState");

local function title()
	return getText("IGUI_AutoPilot_O_Context_Firewood");
end

local function destinationSquare(dest)
	local cell = getCell();

	return dest and cell and cell:getGridSquare(dest.x, dest.y, dest.z);
end

-- the destination has a work surface within reach (nil when its square is not loaded: checked again there)
function Firewood:hasSurfaceAt(dest)
	local square = destinationSquare(dest);

	if square == nil
	then
		return nil;
	end

	return Craft:hasSurfaceNear(square, Craft.surfaceRange);
end

-- the logs the character carries that may be chopped
local function carriedChoppable(player, skip)
	return AutoPilotMoon.Carry:collectCargo(player, function(item)
		return Firewood.isChoppable(item) and not (skip and skip[item:getID()]);
	end);
end

-- Starts the Woodcutter. ctx: destination (required: where it chops and where the firewood goes), run (a chain's ctx).
function AutoPilotMoon.Automation.startFirewood(player, squares, startSquare, ctx)
	local dest = ctx and ctx.destination;
	local reasonKey = nil;

	if dest == nil
	then
		reasonKey = "IGUI_AutoPilot_A_Reason_NoDestination";
	elseif Firewood:hasSurfaceAt(dest) == false
	then
		reasonKey = "IGUI_AutoPilot_A_Reason_NoSurface";
	end

	if reasonKey
	then
		A.lastStartRefusal = "nosurface";
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", title(), getText(reasonKey)), player);

		return false;
	end

	local logs = 0;
	local started = A:startJob("firewood", player, squares, startSquare, function(list, who)
		local kept = AutoPilotMoon.Grid:filterSquaresBy(list, function(square)
			return Haul:squareHas(square, Firewood.isChoppable, dest);
		end);

		logs = Haul:countOn(kept, Firewood.isChoppable, dest);

		local carried = #carriedChoppable(who);

		if carried > 0
		then
			logs = logs + carried;

			if #kept == 0
			then
				table.insert(kept, who:getSquare());
			end
		end

		return kept;
	end);

	if started
	then
		local h = Haul:new(player, dest, { perJob = Firewood.carryPerJob, shared = ctx and ctx.run });

		-- the logs the character already carries are chopped with the others
		for i, item in ipairs(carriedChoppable(player))
		do
			Haul:addCargo(h, item);
		end

		A.firewoodState = {
			hauler = h,
			chopped = 0,
			chopping = false,
			walks = 0,
			craft = nil,
			tries = {},
			unchopped = {},
		};

		local limit = Firewood:getLimit();

		if logs > limit
		then
			logs = limit;
		end

		AutoPilotMoon.Progress:setUnits(logs, "IGUI_AutoPilot_S_Unit_Logs");
	end

	return started;
end

function AutoPilotMoon.Automation:stopFirewood()
	A:stopSquareProcessingQueue("firewoodWorking");
end

-- the logs this job carries and has not chopped yet
local function cargoLogs(S)
	local h = S.hauler;

	return AutoPilotMoon.Carry:collectCargo(h.player, function(item)
		local id = item:getID();

		return h.cargo[id] == true and not h.givenUp[id] and not S.unchopped[id] and Firewood.isChoppable(item);
	end);
end

-- no axe, too tired: the job stops (checked before picking up and before chopping, W-B3)
local function refusal(player)
	if not AutoPilotMoon.Item:getBestWoodChoppingAxe(player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedAxe")));

		return true;
	end

	if not player:isEnduranceSufficientForAction()
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_TooTired", title()));

		return true;
	end

	return false;
end

local function isNearDestination(player, dest)
	if math.floor(player:getZ()) ~= dest.z
	then
		return false;
	end

	local dx = player:getX() - (dest.x + 0.5);
	local dy = player:getY() - (dest.y + 0.5);

	return math.sqrt(dx * dx + dy * dy) <= Firewood.nearDestination + 0.5;
end

-- the chopping round at the destination: the next log, then the firewood is delivered
local function chopNext(S, player)
	local h = S.hauler;
	local dest = h.dest;
	local list = cargoLogs(S);

	if #list == 0
	then
		S.chopping = false;
		S.walks = 0;

		if Haul:deliver(h)
		then
			return "busy";
		end

		return nil;
	end

	if not isNearDestination(player, dest)
	then
		local square = destinationSquare(dest);

		if square == nil or S.walks >= Firewood.maxWalks
		then
			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_DestUnreachable"));

			return "discard";
		end

		S.walks = S.walks + 1;
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Walking", dest.nameText or getText("IGUI_AutoPilot_D_GroundName"));
		luautils.walkAdj(player, square, true);

		return "busy";
	end

	S.walks = 0;

	if refusal(player)
	then
		return "discard";
	end

	local log = list[1];
	local recipe = Craft:getRecipe(Firewood.recipes[log:getFullType()]);

	if recipe == nil
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_GameRefused", Firewood.recipes[log:getFullType()]));

		return "discard";
	end

	local reason = Craft:check(player, recipe, log);

	if reason == "dark"
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_TooDarkChop"));

		return "discard";
	elseif reason == "surface"
	then
		-- the surface is next to the destination but out of the character's reach: once, next to the surface
		local surface = not S.walkedToSurface and Craft:findSurfaceNear(destinationSquare(dest), Craft.surfaceRange);

		if surface
		then
			S.walkedToSurface = true;
			luautils.walkAdj(player, surface:getSquare(), true);

			return "busy";
		end

		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NoSurface"));

		return "discard";
	elseif reason
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_GameRefused", Craft:getRecipeName(recipe)));

		return "discard";
	end

	local pending = Craft:start(player, recipe, log, Firewood.outputs);
	local id = log:getID();

	if pending == nil
	then
		S.tries[id] = (S.tries[id] or 0) + 1;

		if S.tries[id] >= Firewood.maxTries
		then
			S.unchopped[id] = true;
			AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_GameRefused");
		end

		return "busy";
	end

	S.craft = pending;
	S.walkedToSurface = false;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Splitting", S.chopped + 1);

	return "busy";
end

local function confirmChop(S, player)
	local result, consumed, outputs = Craft:confirm(S.craft, player);

	if result == "busy"
	then
		return "busy";
	end

	local id = S.craft.itemId;
	local pieces = 0;

	S.craft = nil;

	for i, item in ipairs(outputs)
	do
		Haul:addCargo(S.hauler, item);

		if item:getFullType() == Firewood.firewoodType
		then
			pieces = pieces + 1;
		end
	end

	if pieces > 0
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Firewood", pieces);
	end

	if consumed
	then
		S.chopped = S.chopped + 1;
		S.hauler.cargo[id] = nil;
		AutoPilotMoon.Progress:addUnitsDone(1);
	else
		S.tries[id] = (S.tries[id] or 0) + 1;

		if S.tries[id] >= Firewood.maxTries
		then
			-- delivered as it is
			S.unchopped[id] = true;
			AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_GameRefused");
		end
	end

	return nil;
end

-- One decision while the character is idle (the engine's removeCheckFunction).
function AutoPilotMoon.Automation:checkFirewoodSquare(square, player)
	local S = A.firewoodState;

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

	if S.craft and confirmChop(S, player) == "busy"
	then
		return "busy";
	end

	if S.chopping
	then
		local result = chopNext(S, player);

		if result
		then
			return result;
		end
	end

	local limit = Firewood:getLimit();
	local carried = #cargoLogs(S);

	if S.chopped >= limit or (carried > 0 and S.chopped + carried >= limit)
	then
		if carried > 0
		then
			S.chopping = true;

			return "busy";
		end

		if Haul:deliver(h)
		then
			return "busy";
		end

		A:finishDone(getText("IGUI_AutoPilot_A_LimitReached", title(), getText("IGUI_AutoPilot_T_Limit_Logs", limit)));

		return "discard";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	local entries = Haul:findOnSquare(h, square, Firewood.isChoppable);

	if #entries == 0
	then
		if Haul:isLastSquare()
		then
			if carried > 0
			then
				S.chopping = true;

				return "busy";
			end

			if Haul:deliver(h)
			then
				return "busy";
			end
		end

		return true;
	end

	if refusal(player)
	then
		return "discard";
	end

	local chosen = Haul:choose(h, entries, limit - S.chopped - carried);

	if #chosen == 0
	then
		-- loaded: to the destination, chop there, deliver, then back
		if carried > 0
		then
			S.chopping = true;

			return "busy";
		end

		if Haul:deliver(h)
		then
			return "busy";
		end

		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_BagFull"));

		return "discard";
	end

	Haul:grab(h, square, chosen);

	return "busy";
end

function AutoPilotMoon.Automation:checkFirewoodQueue(player)
	A:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "firewoodWorking",
		squareFunction = {
			fn = function() end,
		},
		removeCheckFunction = function(square, who)
			return A:checkFirewoodSquare(square, who);
		end,
		stopFunction = function()
			A:stopFirewood();
		end,
	});
end

-- the menu entry (client/75_AP_JobMenu.lua)

AutoPilotMoon.JobMenu:define("firewood", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_Firewood",
	job = "firewood",
	descKey = "IGUI_AutoPilot_T_Desc_Firewood",
	whatKey = "IGUI_AutoPilot_D_TitleFirewood",
	icon = "Base.Axe",
	requirements = function(player)
		return { AutoPilotMoon.JobMenu:axeRequirement(player) };
	end,
	notes = function(player)
		local notes = { { text = getText("IGUI_AutoPilot_T_NeedSurface") } };

		if player:tooDarkToRead()
		then
			table.insert(notes, 1, { text = getText("IGUI_AutoPilot_T_TooDarkToChop"), bad = true });
		end

		return notes;
	end,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", title(), getText("IGUI_AutoPilot_T_Limit_Logs", Firewood:getLimit())) };
	end,
	start = function(player, rect, dest)
		return A.startFirewood(player, AutoPilotMoon.Area:squares(rect), nil, { destination = dest, area = rect });
	end,
});
