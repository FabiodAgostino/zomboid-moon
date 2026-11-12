-- AutoPilot (Moon): automations for the Moon server.

-- Gardener (Moon): clears the ground of an area with the game's own actions ("Pulisci il terreno").
-- Since phase C (11/11/2026; ANALISI-WorkOrders.md 4.4, 6 row 8, spec UX-AUTOPILOT.md 2.2, 5) on the stencil, with
-- the kinds of the menu: grass ("Solo erba"), bushes ("Solo cespugli"), stumps ("Ceppi"), stones and twigs ("Pietre
-- e rametti"), boulders ("Massi"), grass and bushes, everything ("Tutto"). Only what the game lets a player do by hand,
-- with the game's own functions (W-S1, W-S2 of Work Orders: never our own actions, never our own yields):
-- - grass: ISWorldObjectContextMenu.doRemoveGrass; bushes: doRemovePlant with a CUT_PLANT tool;
-- - stones, twigs, branches, logs lying as ground cover (the game's GroundCoverItems, and the flat rock):
--   ISWorldObjectContextMenu.onPickupGroundCoverItem (ISPickUpGroundCoverItem: the item to the inventory, or at the
--   feet when it does not fit, as by hand);
-- - stumps: onRemoveGroundCoverItemStump (a REMOVE_STUMP tool equipped, ISPickAxeGroundCoverItem: unusable wood on the
--   ground, the tool's wear);
-- - boulders: only the ones the game's menu lets you remove ("Rimuovi deposito minerario": iron and copper ore, flint
--   and limestone boulders), onRemoveGroundCoverItemHammerOrPickAxe with a pickaxe, stone maul, sledgehammer or club
--   hammer (the game's yields on the ground, Masonry experience). Other big rocks stay: the game does not remove them.
-- - Kinds whose tool the character lacks at the start are left out with a note ("Tutto" without a pickaxe still clears
--   the rest); a tool that breaks during the job, with that kind still to do, stops the job with "you need ...".
-- - A square with nothing left to do is dropped at once, never waited on (B9); grass gives 2-3 tufts each: the job stops
--   before the player would carry more than the weight allowed (N-S5, N-A8); never in a protected zone.
-- - In a chain ("Pulisci e raccogli") what a pick-up brought into the inventory is noted (ctx.run.gardenerPicked, by
--   id): the next phase carries it to the destination with what lies on the ground.

require "05_AP_Config";
require "55_AP_Stencil";

local A = AutoPilotMoon.Automation;

AutoPilotMoon.Gardener = AutoPilotMoon.Gardener or {};

local Gardener = AutoPilotMoon.Gardener;

-- weight one square of grass may add (3 tufts of 0.1, rounded up)
A.gardenerWeightPerSquare = 0.5;

Gardener.maxSteps = 8;           -- actions on the same square before it is left (grass, bush, stones, stump, boulder...)
Gardener.pickNoteMs = 3000;      -- how long a pick-up's item may take to show up in the inventory (MP)

A:addJobStateField("gardenerKinds");   -- the kinds of the running job (a set)
A:addJobStateField("gardenerPick");    -- { before = id set, at, run }: a pick-up whose item is still to be noted

-- the kinds and what each needs, in the order they are done on a square
Gardener.kindOrder = { "grass", "bushes", "stones", "stumps", "boulders" };

Gardener.presets = {
	grassBushes = { grass = true, bushes = true },
	grass = { grass = true },
	bushes = { bushes = true },
	stumps = { stumps = true },
	stonesTwigs = { stones = true },
	boulders = { boulders = true },
	all = { grass = true, bushes = true, stones = true, stumps = true, boulders = true },
};

-- the boulders the game's menu offers to remove (ISWorldObjectContextMenuLogic.fetchPickupItems of 42.22)
local function isRemovableBoulder(name)
	if name == nil
	then
		return false;
	end

	return string.find(name, "ironOre", 1, true) ~= nil or string.find(name, "copperOre", 1, true) ~= nil
		or name == "FlintBoulder" or name == "LimestoneBoulder";
end

local function notBroken(item)
	return item ~= nil and not item:isBroken();
end

-- the tool of each kind (nil: the kind needs none), as the game's menu checks it
Gardener.tools = {
	bushes = {
		needKey = "IGUI_AutoPilot_T_NeedCutTool",
		skipKey = "IGUI_AutoPilot_A_Skip_BushesNoTool",
		find = function(player)
			return AutoPilotMoon.Item:getPlantCuttingTool(player);
		end,
	},
	stumps = {
		needKey = "IGUI_AutoPilot_T_NeedStumpTool",
		skipKey = "IGUI_AutoPilot_A_Skip_StumpsNoTool",
		find = function(player)
			return player:getInventory():getFirstEvalRecurse(function(item)
				return notBroken(item) and item:hasTag(ItemTag.REMOVE_STUMP);
			end);
		end,
	},
	boulders = {
		needKey = "IGUI_AutoPilot_T_NeedPickaxe",
		skipKey = "IGUI_AutoPilot_A_Skip_BouldersNoTool",
		find = function(player)
			return player:getInventory():getFirstEvalRecurse(function(item)
				return notBroken(item) and (item:hasTag(ItemTag.PICK_AXE) or item:hasTag(ItemTag.STONE_MAUL)
					or item:hasTag(ItemTag.SLEDGEHAMMER) or item:hasTag(ItemTag.CLUB_HAMMER));
			end);
		end,
	},
};

-- what lies on a square

-- the ground cover a player picks up by hand: the game's GroundCoverItems (stones, twigs, branches, logs...) and the
-- flat rock (ISPickUpGroundCoverItem); never furniture, never a container
function Gardener:getPickup(square)
	local table_ = rawget(_G, "GroundCoverItems");
	local objects = square:getObjects();

	for i = 0, objects:size() - 1
	do
		local object = objects:get(i);
		local sprite = object and object:getSprite();
		local props = sprite and sprite:getProperties();

		if props and not instanceof(object, "IsoWorldInventoryObject") and object:getContainerCount() == 0
			and not props:has("IsMoveAble")
		then
			local name = props:get("CustomName");

			if (name and table_ and table_[name]) or sprite:getName() == "d_generic_1_23"
			then
				return object;
			end
		end
	end

	return nil;
end

function Gardener:getStump(square)
	return square:getStump();
end

function Gardener:getBoulder(square)
	local ore = square:getOre();

	if ore and isRemovableBoulder(ore:getProperty("CustomName"))
	then
		return ore;
	end

	return nil;
end

-- the first kind of the job still present on the square, or nil
function Gardener:nextKind(square, kinds)
	for i, kind in ipairs(Gardener.kindOrder)
	do
		if kinds[kind] and Gardener:hasKind(square, kind)
		then
			return kind;
		end
	end

	return nil;
end

function Gardener:hasKind(square, kind)
	if kind == "grass"
	then
		return AutoPilotMoon.Square:getGrass(square) ~= nil;
	elseif kind == "bushes"
	then
		return AutoPilotMoon.Square:getPlant(square) ~= nil;
	elseif kind == "stones"
	then
		return Gardener:getPickup(square) ~= nil;
	elseif kind == "stumps"
	then
		return Gardener:getStump(square) ~= nil;
	elseif kind == "boulders"
	then
		return Gardener:getBoulder(square) ~= nil;
	end

	return false;
end

-- the kinds of a start: ctx.params.kinds (a set), a preset name (ctx.params.preset), or the phase-B params
-- { removeGrass, cutPlants }; default everything
function Gardener:kindsOf(ctx)
	local params = ctx and ctx.params or {};

	if params.kinds
	then
		return params.kinds;
	end

	if params.removeGrass ~= nil or params.cutPlants ~= nil
	then
		return { grass = params.removeGrass ~= false, bushes = params.cutPlants ~= false };
	end

	return Gardener.presets[params.preset or "all"] or Gardener.presets.all;
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_Gardener");
end

local function kindsOfRunningJob(ctx)
	return A.gardenerKinds or Gardener:kindsOf(ctx);
end

-- notes what the last pick-up brought into the main inventory (for the chain's next phase), once it shows up
local function noteLastPick(player)
	local pick = A.gardenerPick;

	if pick == nil
	then
		return;
	end

	local items = player:getInventory():getItems();
	local found = false;

	for i = 0, items:size() - 1
	do
		local item = items:get(i);
		local id = item:getID();

		if not pick.before[id]
		then
			pick.run.gardenerPicked[id] = true;
			found = true;
		end
	end

	if found or getTimestampMs() - pick.at >= Gardener.pickNoteMs
	then
		A.gardenerPick = nil;
	end
end

local function rememberPick(player, ctx)
	if ctx == nil or ctx.run == nil
	then
		return;
	end

	ctx.run.gardenerPicked = ctx.run.gardenerPicked or {};

	local before = {};
	local items = player:getInventory():getItems();

	for i = 0, items:size() - 1
	do
		before[items:get(i):getID()] = true;
	end

	A.gardenerPick = { before = before, at = getTimestampMs(), run = ctx.run };
end

AutoPilotMoon.Stencil:define("gardener", {
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
	counterKey = "IGUI_AutoPilot_P_C_Cleared",
	activityKey = "IGUI_AutoPilot_P_Now_Clearing",
	maxSteps = Gardener.maxSteps,
	needsEndurance = true,
	hasWork = function(square, player, ctx)
		return Gardener:nextKind(square, kindsOfRunningJob(ctx)) ~= nil;
	end,
	idle = function(square, player, ctx)
		noteLastPick(player);

		return nil;
	end,
	check = function(square, player, ctx)
		local kind = Gardener:nextKind(square, kindsOfRunningJob(ctx));
		local tool = Gardener.tools[kind];

		if kind == "grass" and player:getInventoryWeight() + A.gardenerWeightPerSquare > player:getMaxWeight()
		then
			A:finishEarly(getText("IGUI_AutoPilot_A_TooHeavy", title()));

			return "skip";
		end

		if tool and tool.find(player) == nil
		then
			-- the tool broke (it was there at the start): every square after this one would fail the same way
			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText(tool.needKey)));

			return "skip";
		end

		return nil;
	end,
	act = function(square, player, ctx)
		local kind = Gardener:nextKind(square, kindsOfRunningJob(ctx));
		local playerNum = player:getPlayerNum();

		if kind == "grass"
		then
			ISWorldObjectContextMenu.doRemoveGrass(player, square);
		elseif kind == "bushes"
		then
			ISWorldObjectContextMenu.doRemovePlant(player, square);
		elseif kind == "stones"
		then
			rememberPick(player, ctx);
			ISWorldObjectContextMenu.onPickupGroundCoverItem(nil, playerNum, Gardener:getPickup(square));
		elseif kind == "stumps"
		then
			ISWorldObjectContextMenu.onRemoveGroundCoverItemStump(nil, playerNum, Gardener:getStump(square));
		elseif kind == "boulders"
		then
			ISWorldObjectContextMenu.onRemoveGroundCoverItemHammerOrPickAxe(nil, playerNum, Gardener:getBoulder(square));
		else
			return false;
		end

		return true;
	end,
});

local stencilStart = A.startGardener;

-- Starts the Gardener: (player, squares, startSquare, ctx) with ctx.params.kinds / preset (the menu, a chain), or the
-- old (player, squares, cutPlants, removeGrass). The kinds whose tool the character lacks are left out, with a note per
-- kind and how many squares had it; none left that the character can do: not started, with the tool that is missing.
function AutoPilotMoon.Automation.startGardener(player, squares, startSquare, ctx)
	if type(startSquare) == "boolean" or type(ctx) == "boolean"
	then
		ctx = { params = { cutPlants = startSquare == true, removeGrass = ctx == true } };
		startSquare = nil;
	end

	local asked = Gardener:kindsOf(ctx);
	local kinds = {};
	local dropped = {};
	local any = false;

	for i, kind in ipairs(Gardener.kindOrder)
	do
		if asked[kind]
		then
			local tool = Gardener.tools[kind];

			if tool and tool.find(player) == nil
			then
				table.insert(dropped, { kind = kind, tool = tool, count = 0 });
			else
				kinds[kind] = true;
				any = true;
			end
		end
	end

	if not any and #dropped > 0
	then
		A.lastStartRefusal = "notool";
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", title(),
			getText("IGUI_AutoPilot_A_Reason_NeedTool", getText(dropped[1].tool.needKey))), player);

		return false;
	end

	local runCtx = {};

	for k, v in pairs(ctx or {})
	do
		runCtx[k] = v;
	end

	runCtx.params = { kinds = kinds };

	-- the squares that had a kind left out, counted with the area (only when something was left out)
	local list = squares;

	if #dropped > 0
	then
		list = function()
			local all = squares;

			if AutoPilotMoon:isFunction(all)
			then
				all = all();
			end

			for i, square in ipairs(all or {})
			do
				for j, entry in ipairs(dropped)
				do
					if Gardener:hasKind(square, entry.kind)
					then
						entry.count = entry.count + 1;
					end
				end
			end

			return all;
		end;
	end

	local started = stencilStart(player, list, startSquare, runCtx);

	if started
	then
		A.gardenerKinds = kinds;

		for i, entry in ipairs(dropped)
		do
			if entry.count > 0
			then
				AutoPilotMoon.Progress:warn(entry.tool.skipKey, entry.count);
			end
		end
	end

	return started;
end

-- the menu entry "Pulisci il terreno > Erba e cespugli / Solo erba / ... / Tutto" (client/75_AP_JobMenu.lua)

local function variant(labelKey, preset)
	return { labelKey = labelKey, params = { preset = preset } };
end

Gardener.menuVariants = {
	variant("IGUI_AutoPilot_M_ClearGrassBushes", "grassBushes"),
	variant("IGUI_AutoPilot_M_ClearGrass", "grass"),
	variant("IGUI_AutoPilot_M_ClearBushes", "bushes"),
	variant("IGUI_AutoPilot_M_ClearStumps", "stumps"),
	variant("IGUI_AutoPilot_M_ClearStonesTwigs", "stonesTwigs"),
	variant("IGUI_AutoPilot_M_ClearBoulders", "boulders"),
	variant("IGUI_AutoPilot_M_ClearAll", "all"),
};

-- the tools of a preset: a variant of one kind needs its tool (grey without it); "Erba e cespugli" and "Tutto" do what
-- they can and say in the tooltip what they will leave
local function toolRequirements(player, params)
	local preset = params and params.preset;
	local kinds = Gardener.presets[preset or "all"] or Gardener.presets.all;
	local requirements = {};

	for i, kind in ipairs(Gardener.kindOrder)
	do
		local tool = Gardener.tools[kind];

		if kinds[kind] and tool
		then
			local item = tool.find(player);
			local required = preset ~= nil and preset ~= "all" and preset ~= "grassBushes";

			if item or required
			then
				table.insert(requirements, { ok = item ~= nil, needKey = tool.needKey, haveText = item and item:getDisplayName() or nil });
			end
		end
	end

	return requirements;
end

local function leftOutNotes(player, params)
	local preset = params and params.preset;
	local notes = {};

	if preset == "all" or preset == "grassBushes" or preset == nil
	then
		local kinds = Gardener.presets[preset or "all"];

		for i, kind in ipairs(Gardener.kindOrder)
		do
			local tool = Gardener.tools[kind];

			if kinds[kind] and tool and tool.find(player) == nil
			then
				table.insert(notes, { text = getText(tool.skipKey), bad = true });
			end
		end
	end

	if preset == "boulders"
	then
		table.insert(notes, { text = getText("IGUI_AutoPilot_T_OnlyGameBoulders") });
	end

	return notes;
end

AutoPilotMoon.JobMenu:define("clear", {
	group = "ground",
	labelKey = "IGUI_AutoPilot_M_Clear",
	job = "gardener",
	descKey = "IGUI_AutoPilot_T_Desc_Clear",
	rooms = true,
	variants = Gardener.menuVariants,
	here = true,
	icon = "Base.Scythe",
	countFn = function(params)
		local kinds = Gardener.presets[params and params.preset or "all"] or Gardener.presets.all;

		return function(square)
			return Gardener:nextKind(square, kinds) ~= nil;
		end;
	end,
	requirements = function(player, params)
		return toolRequirements(player, params);
	end,
	notes = leftOutNotes,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", title(),
			getText("IGUI_AutoPilot_T_Limit_Squares", AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob"))) };
	end,
	start = function(player, region, dest, params)
		return A.startGardener(player, AutoPilotMoon.JobMenu:squaresOf(region), nil, { area = region, params = params });
	end,
});
