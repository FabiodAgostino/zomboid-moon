-- AutoPilot (Moon): automations for the Moon server.

-- Gatherer (Raccoglitore, 11/11/2026, phase B; ANALISI-WorkOrders.md 6 point 3, spec UX-AUTOPILOT.md 2.2, 3.5, 5):
-- picks up what lies on the ground in an area and carries it to a destination (a container, stacked crates, a vehicle's
-- trunk, a square of ground), a trip when the character is loaded.
-- - what: logs, planks, firewood, stones, twigs and branches, all the wood, full sacks (Gatherer.kinds; the chains add
--   "stonesTwigs"); only items lying on the ground, never in containers, never the character's own things.
-- - full sacks ("Sacchi pieni", 13/11/2026): the sacks of dirt, sand, gravel or clay the game's shovelling makes
--   (AutoPilotMoon.Item:isSoilBag: the four full types of ISShovelGround, the game's data, never a name); never an empty
--   sack, never another sack (wheat, seeds: other types). The Soil bagger's "Sul posto" leaves them on the ground.
-- - picking up: the game's grab (walk next to the square, one transfer per item the server checks); as many items of
--   the square as fit (weight forecast: Haul:canPick, the server's items per trip), the first always when the game has
--   room; only what arrived counts.
-- - carrying: AutoPilotMoon.Carry (the destination checked again before every trip; full -> the next container of the
--   stack -> the ground next to it -> stop "the destination is full"); GathererItemsPerTrip items per trip,
--   GathererItemsPerJob per job (server): reached, the job ends as finished (a chain goes on).
-- - never loops (W-B5 of Work Orders): nothing is picked up from the destination and the squares next to it, nor what
--   this job or an earlier phase of its chain delivered; an item the server refuses three times is left; a square with
--   20 or more items ends when they are all delivered; the last load is delivered before the job ends.

require "05_AP_Config";
require "50_AP_Automation";

local A = AutoPilotMoon.Automation;
local Haul = AutoPilotMoon.Haul;

AutoPilotMoon.Gatherer = AutoPilotMoon.Gatherer or {};

local Gatherer = AutoPilotMoon.Gatherer;

local function byType(list)
	local set = {};

	for i, fullType in ipairs(list)
	do
		set[fullType] = true;
	end

	return set;
end

local logs = { "Base.Log" };
local planks = { "Base.Plank" };
local firewood = { "Base.Firewood" };
local twigs = { "Base.Twigs", "Base.TreeBranch2", "Base.LargeBranch" };
local allWood = { "Base.Log", "Base.Plank", "Base.Firewood", "Base.Twigs", "Base.TreeBranch2", "Base.LargeBranch", "Base.Splinters" };
-- what clearing the ground leaves (phase C): the yields of the game's stump and boulder removal
-- (ISPickAxeGroundCoverItem) and of its ground cover pick-ups (GroundCoverItems), with twigs and branches
local clearingYields = { "Base.Twigs", "Base.TreeBranch2", "Base.LargeBranch", "Base.UnusableWood", "Base.FlintNodule",
	"Base.SharpedStone", "Base.Limestone", "Base.IronOre", "Base.CopperOre", "Base.LargeStone", "Base.FlatStone",
	"Base.Stone2" };

-- what each kind picks up: full types, and the stones by the game's tag (base:stone: stones, flint, limestone)
Gatherer.kinds = {
	logs = { types = byType(logs), labelKey = "IGUI_AutoPilot_M_GatherLogs" },
	planks = { types = byType(planks), labelKey = "IGUI_AutoPilot_M_GatherPlanks" },
	firewood = { types = byType(firewood), labelKey = "IGUI_AutoPilot_M_GatherFirewood" },
	stones = { types = {}, stones = true, labelKey = "IGUI_AutoPilot_M_GatherStones" },
	twigs = { types = byType(twigs), labelKey = "IGUI_AutoPilot_M_GatherTwigs" },
	allWood = { types = byType(allWood), labelKey = "IGUI_AutoPilot_M_GatherAllWood" },
	stonesTwigs = { types = byType(clearingYields), stones = true },
	fullSacks = { types = byType(AutoPilotMoon.Item.soilBagTypes), labelKey = "IGUI_AutoPilot_M_GatherFullSacks" },
};

-- the kinds of the menu, in the spec's order (2.2)
Gatherer.menuKinds = { "logs", "planks", "firewood", "stones", "twigs", "allWood", "fullSacks" };

-- the filter of a kind (nil kind: all the wood)
function Gatherer:matcher(kindName)
	local kind = Gatherer.kinds[kindName or "allWood"] or Gatherer.kinds.allWood;

	return function(item)
		if kind.types[item:getFullType()]
		then
			return true;
		end

		return kind.stones == true and item:hasTag(ItemTag.STONE);
	end;
end

A:register("gatherer", {
	squareFilter = function(square, player)
		return Haul:squareHas(square, Gatherer:matcher(nil), nil);
	end,
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
	limit = function()
		return AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob");
	end,
});

A:addJobStateField("gathererState");

local function title()
	return getText("IGUI_AutoPilot_O_Context_Gatherer");
end

-- the kind from the start's ctx: ctx.params.what (a chain's phase, the menu)
local function kindOf(ctx)
	return ctx and ctx.params and ctx.params.what or "allWood";
end

-- Starts the Gatherer for the player on the squares (a list or a function). ctx: destination (required: where things
-- go), params.what (the kind, default all the wood), run (a chain's ctx).
function AutoPilotMoon.Automation.startGatherer(player, squares, startSquare, ctx)
	local dest = ctx and ctx.destination;
	local match = Gatherer:matcher(kindOf(ctx));
	local total = 0;

	if dest == nil
	then
		-- nowhere to carry: nothing would end in the right place
		A.lastStartRefusal = "nodestination";
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", title(), getText("IGUI_AutoPilot_A_Reason_NoDestination")), player);

		return false;
	end

	-- in a chain, what an earlier phase brought into the inventory (the Gardener's pick-ups, by id) is carried too
	local picked = ctx and ctx.run and ctx.run.gardenerPicked;
	local cargo = {};

	if picked
	then
		cargo = AutoPilotMoon.Carry:collectCargo(player, function(item)
			return picked[item:getID()] == true;
		end);
	end

	local started = A:startJob("gatherer", player, squares, startSquare, function(list)
		local kept = AutoPilotMoon.Grid:filterSquaresBy(list, function(square)
			return Haul:squareHas(square, match, dest);
		end);

		total = Haul:countOn(kept, match, dest) + #cargo;

		if #kept == 0 and #cargo > 0 and player:getSquare()
		then
			-- nothing on the ground, only the cargo: the character's square, where the last load is delivered
			kept = { player:getSquare() };
		end

		return kept;
	end);

	if started
	then
		A.gathererState = {
			match = match,
			hauler = Haul:new(player, dest, { shared = ctx and ctx.run }),
		};

		for i, item in ipairs(cargo)
		do
			Haul:addCargo(A.gathererState.hauler, item);
		end

		local perJob = AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob");

		if total > perJob
		then
			total = perJob;
		end

		AutoPilotMoon.Progress:setUnits(total, "IGUI_AutoPilot_S_Unit_Items");
	end

	return started;
end

function AutoPilotMoon.Automation:stopGatherer()
	A:stopSquareProcessingQueue("gathererWorking");
end

-- items still allowed in this job (the server's limit, minus what was delivered and what is on the way)
local function leftInJob(h)
	return AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob") - AutoPilotMoon.Carry:getCarried() - Haul:countCargo(h);
end

-- One decision while the character is idle (the engine's removeCheckFunction): "busy" while picking up or carrying,
-- true when nothing is left to pick up on the square.
function AutoPilotMoon.Automation:checkGathererSquare(square, player)
	local S = A.gathererState;

	if S == nil
	then
		return "discard";
	end

	local h = S.hauler;
	local before = h.delivered;
	local pending, reasonKey = Haul:update(h);

	if h.delivered > before
	then
		-- the panel's bar: items delivered out of the items found at the start
		AutoPilotMoon.Progress:addUnitsDone(h.delivered - before);
	end

	if pending == "busy"
	then
		return "busy";
	elseif pending == "failed"
	then
		A:stopBecause(getText(reasonKey));

		return "discard";
	end

	local left = leftInJob(h);

	if left <= 0
	then
		if Haul:deliver(h)
		then
			return "busy";
		end

		A:finishDone(getText("IGUI_AutoPilot_A_LimitReached", title(),
			getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob"))));

		return "discard";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	local entries = Haul:findOnSquare(h, square, S.match);

	if #entries == 0
	then
		-- nothing left here; before the last square ends, the last load goes to the destination
		if Haul:isLastSquare() and Haul:deliver(h)
		then
			return "busy";
		end

		return true;
	end

	local chosen = Haul:choose(h, entries, left);

	if #chosen == 0
	then
		-- loaded: a trip, then back here
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

function AutoPilotMoon.Automation:checkGathererQueue(player)
	A:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "gathererWorking",
		squareFunction = {
			fn = function() end,
		},
		removeCheckFunction = function(square, who)
			return A:checkGathererSquare(square, who);
		end,
		stopFunction = function()
			A:stopGatherer();
		end,
	});
end

-- the menu entry (client/75_AP_JobMenu.lua): Raccogli > Tronchi / Assi / ... > area

local variants = {};

for i, kindName in ipairs(Gatherer.menuKinds)
do
	table.insert(variants, { labelKey = Gatherer.kinds[kindName].labelKey, params = { what = kindName } });
end

AutoPilotMoon.JobMenu:define("gather", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_Gather",
	job = "gatherer",
	descKey = "IGUI_AutoPilot_T_Desc_Gather",
	whatKey = "IGUI_AutoPilot_D_TitleItems",
	variants = variants,
	-- "Qui" (spec 2.2 rule 6): something of any kind of the menu lies on the clicked square
	here = function(square, player)
		for i, kindName in ipairs(Gatherer.menuKinds)
		do
			if Haul:squareHas(square, Gatherer:matcher(kindName), nil)
			then
				return true;
			end
		end

		return false;
	end,
	icon = "Base.Log",
	countFn = function(params)
		local match = Gatherer:matcher(params and params.what);

		return function(square)
			return Haul:squareHas(square, match, nil);
		end;
	end,
	limits = function()
		return {
			getText("IGUI_AutoPilot_T_JobLimit", title(), getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob"))),
			getText("IGUI_AutoPilot_T_PerTrip", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerTrip")),
		};
	end,
	start = function(player, rect, dest, params)
		return A.startGatherer(player, AutoPilotMoon.Area:squares(rect), nil, { destination = dest, area = rect, params = params });
	end,
});
