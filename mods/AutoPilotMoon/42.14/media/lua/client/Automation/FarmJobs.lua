-- AutoPilot (Moon): automations for the Moon server.

-- The Farmer's other jobs (11/11/2026, phase C; ANALISI-WorkOrders.md 4.8 and 6 row 4, spec UX-AUTOPILOT.md 2.2, 5):
-- what a player does by hand in the garden, one plant (or furrow) at a time, with the game's own actions and the same
-- order the game's menu uses (client/Farming/ISUI/ISFarmingMenu.lua of 42.22). Each is a small automation on the
-- stencil (client/55_AP_Stencil.lua), registered under the Farmer: same server switch EnableFarmer, same tick in "Jobs
-- in the menu", same title "Contadino" (spec 2.5). Watering is Automation/Farmer.lua.
-- - farmDig ("Scava solchi"): every square the game lets you dig (ISFarmingMenu.canDigHereSquare), ISPlowAction with
--   the DIG_PLOW tool, or bare hands when there is none and the hands are not hurt (as the game's "Scava con le mani":
--   twice the time, it may scratch the hands); hurt hands and no tool: the job stops with the reason.
-- - farmSow ("Semina > Carote (24)"): the empty furrows, with the loose seeds of the type chosen in the menu (the
--   game's seed rule: whole, fresh cuttings, not rotten; never a favourite). W-B6 of Work Orders: the walk first, then
--   the seed into the main inventory, then ISSeedActionNew (the game's own order), never the other way round.
-- - farmFertilize ("Fertilizza > Fertilizzante / Compost"): ISFertilizeAction on the living plants; a plant that
--   already had that fertilizer is left out with a note (W-B10: a second dose costs it 25 health; compost brings nothing
--   twice). The game's choice of item: the FERTILIZER (COMPOST) tag with uses left.
-- - farmTreat ("Tratta le piante"): each problem the plant has (mildew, flies, slugs, aphids) with the game's own
--   remedy for it (GardeningSprayMilk, GardeningSprayCigarettes, SlugRepellent, GardeningSprayAphids), as many uses
--   as the problem needs (at most 10 and what the remedy has); a problem without its remedy: left with a note.
-- - farmHarvest ("Raccogli il raccolto"): ISHarvestPlantAction on the ready plants; stops with "your bag is full".
-- - farmRemove ("Togli le piante"): ISShovelAction with the DIG_PLOW tool on every plant, ready or not, dead or alive
--   (not the empty furrows).
-- Everything else (the walk next to the plant, the time, the experience, the server's checks) is the game's.

require "05_AP_Config";
require "55_AP_Stencil";

local A = AutoPilotMoon.Automation;
local Farm = AutoPilotMoon.Farm;
local Stencil = AutoPilotMoon.Stencil;

Farm.maxCureUses = 10;   -- uses of a remedy in one action (the game's aphids menu offers up to 10)

-- the remedies of the game, by problem (ISFarmingMenu.doFarmingMenu2 of 42.22), in the order they are tried
Farm.cures = {
	{ field = "mildewLvl", cure = "Mildew", itemType = "GardeningSprayMilk", nameKey = "Farming_Mildew" },
	{ field = "fliesLvl", cure = "Flies", itemType = "GardeningSprayCigarettes", nameKey = "Farming_Pest_Flies" },
	{ field = "slugsLvl", cure = "Slugs", itemType = "SlugRepellent", nameKey = "Farming_Slugs" },
	{ field = "aphidLvl", cure = "Aphids", itemType = "GardeningSprayAphids", nameKey = "Farming_Aphids" },
};

-- the fertilizers: the game's tags (ISFarmingMenu.doFarmingMenu2 and CFarming_Interact of 42.22)
Farm.fertilizers = {
	fertilizer = { tag = "FERTILIZER", itemType = "Fertilizer", labelKey = "IGUI_AutoPilot_M_FertFertilizer",
		needKey = "IGUI_AutoPilot_T_NeedFertilizer" },
	compost = { tag = "COMPOST", itemType = "CompostBag", labelKey = "IGUI_AutoPilot_M_FertCompost",
		needKey = "IGUI_AutoPilot_T_NeedCompost" },
};

-- tools and items

-- the game's predicate of a seed (ISFarmingMenu.lua, predicateGoodSeed): anything that is not food, else not rotten,
-- cooked or burnt, a cutting only fresh, and a whole one
function AutoPilotMoon.Farm:isGoodSeed(item)
	if item == nil or item:isFavorite()
	then
		return false;
	end

	if not instanceof(item, "Food")
	then
		return true;
	end

	if item:isRotten() or item:isCooked() or item:isBurnt()
	then
		return false;
	end

	if item:hasTag(ItemTag.IS_CUTTING) and not item:isFresh()
	then
		return false;
	end

	local baseHunger = math.abs(item:getBaseHunger());
	local hungerChange = math.abs(item:getHungerChange());

	if item:isFresh() and hungerChange < baseHunger
	then
		return false;
	end

	if not item:isFresh() and hungerChange < (baseHunger * 0.75)
	then
		return false;
	end

	return true;
end

-- full type of a seed -> the plant it grows (farming_vegetableconf.props: seedTypes or seedName), built once
function AutoPilotMoon.Farm:getSeedIndex()
	if Farm.seedIndex
	then
		return Farm.seedIndex;
	end

	local index = {};
	local conf = rawget(_G, "farming_vegetableconf");

	if conf == nil or conf.props == nil
	then
		return index;
	end

	for typeOfSeed, props in pairs(conf.props)
	do
		local seedTypes = props.seedTypes or { props.seedName };

		for i, seedName in ipairs(seedTypes)
		do
			if seedName
			then
				index[seedName] = typeOfSeed;
			end
		end
	end

	Farm.seedIndex = index;

	return index;
end

-- the loose seeds the character has, by type, in one look at the inventory (the menu): list of
-- { seedName, typeOfSeed, count, nameText }, sorted by name
function AutoPilotMoon.Farm:getLooseSeeds(player)
	local index = Farm:getSeedIndex();
	local byType = {};
	local result = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return index[item:getFullType()] ~= nil and Farm:isGoodSeed(item);
	end);

	for i = 0, items:size() - 1
	do
		local item = items:get(i);
		local fullType = item:getFullType();
		local entry = byType[fullType];

		if entry == nil
		then
			entry = { seedName = fullType, typeOfSeed = index[fullType], count = 0, nameText = item:getDisplayName() };
			byType[fullType] = entry;
			table.insert(result, entry);
		end

		entry.count = entry.count + 1;
	end

	table.sort(result, function(a, b) return a.nameText < b.nameText end);

	return result;
end

-- a loose seed of that type, or nil
function AutoPilotMoon.Farm:getSeed(player, seedName)
	if seedName == nil
	then
		return nil;
	end

	return player:getInventory():getFirstEvalRecurse(function(item)
		return item:getFullType() == seedName and Farm:isGoodSeed(item);
	end);
end

-- the digging tool (ISFarmingMenu.getShovel: the DIG_PLOW tag, the one in hand first), or nil
function AutoPilotMoon.Farm:getShovel(player)
	return ISFarmingMenu.getShovel(player);
end

-- the hands may dig (the game's farmingPlot:isValid: no injury on either hand)
function AutoPilotMoon.Farm:handsCanDig(player)
	local body = player:getBodyDamage();

	return not body:getBodyPart(BodyPartType.Hand_L):HasInjury() and not body:getBodyPart(BodyPartType.Hand_R):HasInjury();
end

local function hasUses(item)
	return item ~= nil and not item:isFavorite() and item:getCurrentUses() > 0;
end

-- a fertilizer of the kind ("fertilizer" / "compost") with uses left, the one in hand first, or nil
function AutoPilotMoon.Farm:getFertilizer(player, kind)
	local spec = Farm.fertilizers[kind or "fertilizer"];

	if spec == nil
	then
		return nil;
	end

	local function matches(item)
		return (item:hasTag(ItemTag[spec.tag]) or item:getType() == spec.itemType) and hasUses(item);
	end

	local hand = player:getPrimaryHandItem();

	if hand and matches(hand)
	then
		return hand;
	end

	return player:getInventory():getFirstEvalRecurse(matches);
end

-- the remedy of a problem with a use left, the one in hand first (as the game's menu), or nil
function AutoPilotMoon.Farm:getCure(player, cure)
	local hand = player:getPrimaryHandItem();

	if hand and hand:getType() == cure.itemType and hasUses(hand)
	then
		return hand;
	end

	return player:getInventory():getFirstEvalRecurse(function(item)
		return item:getType() == cure.itemType and hasUses(item);
	end);
end

-- plants

-- a living plant that is not an empty furrow
local function livingPlant(square)
	local plant = Farm:getPlant(square);

	if plant and plant.state ~= "plow" and Farm:isAlive(plant)
	then
		return plant;
	end

	return nil;
end

local function level(plant, field)
	return tonumber(plant[field]) or 0;
end

-- already given this fertilizer (the server's SPlantGlobalObject:fertilize / compostPlant)
function AutoPilotMoon.Farm:isFertilized(plant, kind)
	if kind == "compost"
	then
		return Farm:isTrue(plant.compost);
	end

	return level(plant, "fertilizer") > 0;
end

-- the first problem of the plant, and its remedy if the character has it
local function firstProblem(plant, player)
	local untreatable = nil;

	for i, cure in ipairs(Farm.cures)
	do
		if level(plant, cure.field) > 0
		then
			local item = Farm:getCure(player, cure);

			if item
			then
				return cure, item;
			end

			untreatable = untreatable or cure;
		end
	end

	return untreatable, nil;
end

local function hasProblem(plant)
	for i, cure in ipairs(Farm.cures)
	do
		if level(plant, cure.field) > 0
		then
			return true;
		end
	end

	return false;
end

local function farmingLevel(player)
	return player:getPerkLevel(Perks.Farming);
end

-- equips an item in the primary hand as the game's menu does (ISWorldObjectContextMenu.equip), returns it; twoHands
-- for the digging tool, as the game's farmingPlot (equipWeapon with isTwoHandWeapon)
local function equip(player, item, twoHands)
	return ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), item, true, twoHands) or item;
end

local function limitPerJob()
	return AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob");
end

-- the jobs

Stencil:define("farmDig", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
	counterKey = "IGUI_AutoPilot_P_C_Furrows",
	activityKey = "IGUI_AutoPilot_P_Now_Digging",
	needsEndurance = true,
	hasWork = function(square, player, ctx)
		return ISFarmingMenu.canDigHereSquare(square) == true;
	end,
	-- the tool, false for bare hands (the game allows it), nil when the hands are hurt and there is no tool
	tool = function(player, ctx)
		local shovel = Farm:getShovel(player);

		if shovel
		then
			return shovel;
		end

		if Farm:handsCanDig(player)
		then
			return false;
		end

		return nil;
	end,
	toolKey = "IGUI_AutoPilot_T_NeedShovelHurtHands",
	act = function(square, player, ctx, tool)
		if not luautils.walkAdj(player, square, true)
		then
			return false;
		end

		if tool
		then
			equip(player, tool, tool:isTwoHandWeapon());
		end

		ISTimedActionQueue.add(ISPlowAction:new(player, square, tool or nil));

		return true;
	end,
});

Stencil:define("farmSow", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Squares",
	counterKey = "IGUI_AutoPilot_P_C_Sown",
	activityKey = "IGUI_AutoPilot_P_Now_Sowing",
	hasWork = function(square, player, ctx)
		local plant = Farm:getPlant(square);

		return plant ~= nil and plant.state == "plow";
	end,
	tool = function(player, ctx)
		return Farm:getSeed(player, ctx and ctx.params and ctx.params.seedName);
	end,
	toolKey = "IGUI_AutoPilot_T_NeedSeeds",
	act = function(square, player, ctx, seed)
		local plant = Farm:getPlant(square);

		-- W-B6: the walk first (ISFarmingMenu.walkToPlant queues it), then the seed into the main inventory, then sow
		if plant == nil or not ISFarmingMenu.walkToPlant(player, square)
		then
			return false;
		end

		ISInventoryPaneContextMenu.transferIfNeeded(player, seed);
		ISTimedActionQueue.add(ISSeedActionNew:new(player, seed, ctx.params.typeOfSeed, plant));

		return true;
	end,
});

AutoPilotMoon.Progress:addEndWarning("IGUI_AutoPilot_A_Skip_AlreadyFertilized", "IGUI_AutoPilot_A_FertilizedSkipped");

Stencil:define("farmFertilize", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Plants",
	counterKey = "IGUI_AutoPilot_P_C_Fertilized",
	activityKey = "IGUI_AutoPilot_P_Now_Fertilizing",
	hasWork = function(square, player, ctx)
		local plant = livingPlant(square);

		return plant ~= nil and not Farm:isFertilized(plant, ctx and ctx.params and ctx.params.kind);
	end,
	-- W-B10: a plant that already had it is left out with a note in the panel and, at the end of the job, a sentence
	-- with the count over the head (user's decision of 12/11/2026: skip and tell; A_FertilizedSkipped below)
	startSkip = function(square, player, ctx)
		if livingPlant(square)
		then
			return "IGUI_AutoPilot_A_Skip_AlreadyFertilized";
		end

		return nil;
	end,
	tool = function(player, ctx)
		return Farm:getFertilizer(player, ctx and ctx.params and ctx.params.kind);
	end,
	toolText = function(player, ctx)
		local spec = Farm.fertilizers[ctx and ctx.params and ctx.params.kind or "fertilizer"] or Farm.fertilizers.fertilizer;

		return getText(spec.needKey);
	end,
	act = function(square, player, ctx, item)
		local plant = livingPlant(square);

		if plant == nil or not ISFarmingMenu.walkToPlant(player, square)
		then
			return false;
		end

		item = equip(player, item);
		ISTimedActionQueue.add(ISFertilizeAction:new(player, item, plant, 100));

		return true;
	end,
});

Stencil:define("farmTreat", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Plants",
	counterKey = "IGUI_AutoPilot_P_C_Treated",
	activityKey = "IGUI_AutoPilot_P_Now_Treating",
	maxSteps = 8,
	hasWork = function(square, player, ctx)
		local plant = livingPlant(square);

		return plant ~= nil and plant.state == "seeded" and hasProblem(plant);
	end,
	-- a problem whose remedy the character does not have: the plant is left with a note (spec 5)
	check = function(square, player, ctx)
		local plant = livingPlant(square);
		local cure, item = firstProblem(plant, player);

		if cure and item == nil
		then
			return "skip", "IGUI_AutoPilot_A_Skip_NoCure";
		end

		return nil;
	end,
	act = function(square, player, ctx)
		local plant = livingPlant(square);
		local cure, item = nil, nil;

		if plant
		then
			cure, item = firstProblem(plant, player);
		end

		if item == nil or not ISFarmingMenu.walkToPlant(player, square)
		then
			return false;
		end

		-- each use takes 10 + the farming level off the problem (SPlantGlobalObject:cureMildew...)
		local uses = math.ceil(level(plant, cure.field) / (10 + farmingLevel(player)));
		local available = item:getCurrentUses();

		if uses > Farm.maxCureUses
		then
			uses = Farm.maxCureUses;
		end

		if uses > available
		then
			uses = available;
		end

		if uses < 1
		then
			uses = 1;
		end

		item = equip(player, item);
		ISTimedActionQueue.add(ISCurePlantAction:new(player, item, uses, plant, 10 * (uses * 10), cure.cure));

		return true;
	end,
});

Stencil:define("farmHarvest", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Plants",
	counterKey = "IGUI_AutoPilot_P_C_Harvested",
	activityKey = "IGUI_AutoPilot_P_Now_Harvesting",
	needsEndurance = true,
	hasWork = function(square, player, ctx)
		local plant = livingPlant(square);

		return plant ~= nil and Farm:isTrue(plant.hasVegetable);
	end,
	check = function(square, player, ctx)
		if player:getInventoryWeight() >= player:getMaxWeight()
		then
			A:stopBecause(getText("IGUI_AutoPilot_A_Reason_BagFull"));

			return "skip";
		end

		return nil;
	end,
	act = function(square, player, ctx)
		local plant = livingPlant(square);

		if plant == nil or not ISFarmingMenu.walkToPlant(player, square)
		then
			return false;
		end

		ISTimedActionQueue.add(ISHarvestPlantAction:new(player, plant, 100));

		return true;
	end,
});

Stencil:define("farmRemove", {
	parent = "farmer",
	unitKey = "IGUI_AutoPilot_S_Unit_Plants",
	counterKey = "IGUI_AutoPilot_P_C_Removed",
	activityKey = "IGUI_AutoPilot_P_Now_Removing",
	needsEndurance = true,
	hasWork = function(square, player, ctx)
		local plant = Farm:getPlant(square);

		return plant ~= nil and plant.state ~= "plow";
	end,
	tool = function(player, ctx)
		return Farm:getShovel(player);
	end,
	toolKey = "IGUI_AutoPilot_T_NeedShovel",
	act = function(square, player, ctx, shovel)
		local plant = Farm:getPlant(square);

		if plant == nil or not ISFarmingMenu.walkToPlant(player, square)
		then
			return false;
		end

		shovel = equip(player, shovel);
		ISTimedActionQueue.add(ISShovelAction:new(player, shovel, plant, 40));

		return true;
	end,
});

-- the menu entries (client/75_AP_JobMenu.lua), group "Campi"; the area submenu of each, then the start

local function startWith(name)
	return function(player, region, dest, params)
		return A["start" .. AutoPilotMoon:ucFirst(name)](player, AutoPilotMoon.JobMenu:squaresOf(region), nil,
			{ area = region, params = params or {} });
	end;
end

local function farmerLimit()
	return { getText("IGUI_AutoPilot_T_JobLimit", getText("IGUI_AutoPilot_O_Context_Farmer"),
		getText("IGUI_AutoPilot_T_Limit_Squares", limitPerJob())) };
end

AutoPilotMoon.JobMenu:define("digFurrows", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_DigFurrows",
	job = "farmDig",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	icon = "Base.GardenHoe",
	requirements = function(player)
		local shovel = Farm:getShovel(player);

		return { { ok = shovel ~= nil or Farm:handsCanDig(player), needKey = "IGUI_AutoPilot_T_NeedShovelHurtHands",
			haveText = shovel and shovel:getDisplayName() or nil, item = shovel } };
	end,
	notes = function(player)
		if Farm:getShovel(player) == nil and Farm:handsCanDig(player)
		then
			return { { text = getText("IGUI_AutoPilot_T_DigWithHands"), bad = true } };
		end

		return {};
	end,
	limits = farmerLimit,
	start = startWith("farmDig"),
});

AutoPilotMoon.JobMenu:define("sow", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_Sow",
	job = "farmSow",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	here = true,
	-- one line per kind of loose seed the character has, "Carote (24)" (spec 2.2)
	variants = function(player)
		local variants = {};

		for i, seed in ipairs(Farm:getLooseSeeds(player))
		do
			table.insert(variants, {
				text = getText("IGUI_AutoPilot_M_SeedLine", seed.nameText, seed.count),
				params = { seedName = seed.seedName, typeOfSeed = seed.typeOfSeed },
			});
		end

		return variants;
	end,
	requirements = function(player, params)
		if params and params.seedName
		then
			local seed = Farm:getSeed(player, params.seedName);

			return { { ok = seed ~= nil, needKey = "IGUI_AutoPilot_T_NeedSeeds", item = seed } };
		end

		return { { ok = #Farm:getLooseSeeds(player) > 0, reasonKey = "IGUI_AutoPilot_T_NoLooseSeeds" } };
	end,
	limits = farmerLimit,
	start = startWith("farmSow"),
});

AutoPilotMoon.JobMenu:define("fertilize", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_Fertilize",
	job = "farmFertilize",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	icon = "Base.Fertilizer",
	variants = {
		{ labelKey = Farm.fertilizers.fertilizer.labelKey, params = { kind = "fertilizer" } },
		{ labelKey = Farm.fertilizers.compost.labelKey, params = { kind = "compost" } },
	},
	requirements = function(player, params)
		if params and params.kind
		then
			local item = Farm:getFertilizer(player, params.kind);

			return { { ok = item ~= nil, needKey = Farm.fertilizers[params.kind].needKey, haveText = item and item:getDisplayName() or nil, item = item } };
		end

		local any = Farm:getFertilizer(player, "fertilizer") or Farm:getFertilizer(player, "compost");

		return { { ok = any ~= nil, needKey = "IGUI_AutoPilot_T_NeedFertilizer", haveText = any and any:getDisplayName() or nil, item = any } };
	end,
	notes = function(player)
		return { { text = getText("IGUI_AutoPilot_T_SkipsFertilized") } };
	end,
	limits = farmerLimit,
	start = startWith("farmFertilize"),
});

local function namesOf(list)
	local names = {};

	for i, cure in ipairs(list)
	do
		table.insert(names, getText(cure.nameKey));
	end

	return table.concat(names, ", ");
end

AutoPilotMoon.JobMenu:define("treat", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_Treat",
	job = "farmTreat",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	here = true,
	requirements = function(player)
		for i, cure in ipairs(Farm.cures)
		do
			if Farm:getCure(player, cure)
			then
				return { { ok = true } };
			end
		end

		return { { ok = false, reasonKey = "IGUI_AutoPilot_T_NoCure" } };
	end,
	-- the remedies the character has and the ones that are missing (spec 5)
	notes = function(player)
		local have, missing = {}, {};

		for i, cure in ipairs(Farm.cures)
		do
			if Farm:getCure(player, cure)
			then
				table.insert(have, cure);
			else
				table.insert(missing, cure);
			end
		end

		local notes = {};

		if #have > 0
		then
			table.insert(notes, { text = getText("IGUI_AutoPilot_T_CuresHave", namesOf(have)) });
		end

		if #missing > 0
		then
			table.insert(notes, { text = getText("IGUI_AutoPilot_T_CuresMissing", namesOf(missing)), bad = true });
		end

		return notes;
	end,
	limits = farmerLimit,
	start = startWith("farmTreat"),
});

AutoPilotMoon.JobMenu:define("harvest", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_Harvest",
	job = "farmHarvest",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	here = true,
	limits = farmerLimit,
	start = startWith("farmHarvest"),
});

AutoPilotMoon.JobMenu:define("removePlants", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_RemovePlants",
	job = "farmRemove",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	icon = "Base.Shovel",
	requirements = function(player)
		local shovel = Farm:getShovel(player);

		return { { ok = shovel ~= nil, needKey = "IGUI_AutoPilot_T_NeedShovel", haveText = shovel and shovel:getDisplayName() or nil, item = shovel } };
	end,
	notes = function(player)
		return { { text = getText("IGUI_AutoPilot_T_RemovesUnripe"), bad = true } };
	end,
	limits = farmerLimit,
	start = startWith("farmRemove"),
});
