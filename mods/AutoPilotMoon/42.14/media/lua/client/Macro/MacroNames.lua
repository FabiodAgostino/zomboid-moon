-- AutoPilot (Moon): automations for the Moon server.

-- The names of the macros (spec MACRO-AUTOPILOT.md 2.4, 2.5): recipes, items and skills as the player writes them,
-- found in indexes built once per session, a slice at a time (Names.slice per frame, OnTick only while building;
-- buildNow() at once when a macro starts before the editor ever opened).
--   recipes: the game's id (getScriptManager():getAllCraftRecipes(), CraftRecipe:getName(), any case) or the name in
--            the player's language (getText(recipe:getTranslationName())). One name can stand for several recipes
--            (151 Italian names are used by more than one key): the name is the SET of its recipes.
--   items:   the full type (Base.Handle, Item:getFullName()) or the name in the player's language
--            (Item:getDisplayName()); a name is the set of its types ("Claw Hammer" = Base.Hammer and Base.HammerForged).
--   skills:  PerkFactory.PerkList (the skills, not their groups): the translated name or the English id.
-- The macros only do the recipes "by hand" (tag InHandCraft) and "on any surface" (AnySurfaceCraft); a workbench recipe
-- is said with the bench's name (step M2). "smonta X": the recipes by hand whose id starts with a dismantling prefix and
-- that consume X. repair("X") / sharpen("X") (wave 0, 13/11/2026): the game's repairs and sharpenings that keep X
-- (Names:workRecipes, the kept input with flags[IsDamaged] / flags[IsSharpenable]).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Names = AutoPilotMoon.Macro.Names or {};

local Names = AutoPilotMoon.Macro.Names;

Names.slice = 512;          -- recipes or items indexed per frame
Names.maxSuggestions = 3;
Names.maxLike = 200;        -- names of one item a warning looks at (Names:uniqueNamesLike)
Names.dismantlePrefixes = { "Dismantle", "Disassemble", "Scrap", "Salvage", "Reclaim", "BreakDown" };

Names.state = nil;          -- nil: not started; "building"; "ready"

local function reset()
	Names.recipeById = {};      -- lower id -> recipe
	Names.recipesByName = {};   -- lower name -> list of recipes
	Names.recipeNameList = {};  -- the distinct names, as shown { lower, text }
	Names.recipeText = {};      -- id -> name shown
	Names.recipeList = {};      -- every recipe the macros can do (for "Inserisci > Ricetta")
	Names.dismantleByType = {}; -- full type -> list of dismantling recipes
	Names.typeByLower = {};     -- lower full type -> full type
	Names.typesByName = {};     -- lower name -> list of full types
	Names.itemNameList = {};
	Names.itemText = {};        -- full type -> name shown
	Names.perkByLower = {};     -- lower name or id -> perk
	Names.skillList = {};       -- the skills { text = name shown, id }, by name (the editor's suggestions)
	Names.consumedCache = {};   -- recipe id -> set of full types of its consumed inputs
	Names.itemCategory = {};    -- full type -> the game's DisplayCategory ("Food", "Container"...)
	Names.slotsCache = {};      -- recipe id -> its item inputs (Names:inputSlots)
	Names.allRecipeList = {};   -- every recipe of the game, the workbenches' too (known("...") and its suggestions)
	Names.targetCache = {};     -- recipe id -> set of full types of the item the recipe works on (Names:targetTypes)
	Names.clickCache = {};      -- recipe id -> set of full types the macro clicks for it (Names:clickTypes)
end

reset();

-- ============================================================================================================
-- Building the indexes
-- ============================================================================================================

local function isDismantleId(id)
	for i, prefix in ipairs(Names.dismantlePrefixes)
	do
		if string.sub(id, 1, string.len(prefix)) == prefix
		then
			return true;
		end
	end

	return false;
end

Names.isDismantleId = isDismantleId;

-- the macros can do it: by hand or on any surface (the right click's recipes), not a workbench's
function AutoPilotMoon.Macro.Names:isAllowed(recipe)
	return recipe:isInHandCraftCraft() or recipe:isAnySurfaceCraft();
end

-- the full types of the inputs a recipe consumes (not kept, not tools), cached per recipe
function AutoPilotMoon.Macro.Names:consumedTypes(recipe)
	local id = recipe:getName();
	local types = Names.consumedCache[id];

	if types
	then
		return types;
	end

	types = {};

	local inputs = recipe:getInputs();

	for i = 0, inputs:size() - 1
	do
		local input = inputs:get(i);

		if not input:isKeep() and not input:isTool()
		then
			local items = input:getPossibleInputItems();

			if items
			then
				for j = 0, items:size() - 1
				do
					types[items:get(j):getFullName()] = true;
				end
			end
		end
	end

	Names.consumedCache[id] = types;

	return types;
end

local function indexRecipe(recipe)
	local id = recipe:getName();
	local text = getText(recipe:getTranslationName());
	local lower = string.lower(text);
	local list = Names.recipesByName[lower];

	Names.recipeById[string.lower(id)] = recipe;
	Names.recipeText[id] = text;
	table.insert(Names.allRecipeList, recipe);

	if list == nil
	then
		list = {};
		Names.recipesByName[lower] = list;
		table.insert(Names.recipeNameList, { lower = lower, text = text });
	end

	table.insert(list, recipe);

	if Names:isAllowed(recipe)
	then
		table.insert(Names.recipeList, recipe);

		if isDismantleId(id)
		then
			for fullType in pairs(Names:consumedTypes(recipe))
			do
				local recipes = Names.dismantleByType[fullType];

				if recipes == nil
				then
					recipes = {};
					Names.dismantleByType[fullType] = recipes;
				end

				table.insert(recipes, recipe);
			end
		end
	end
end

-- The game's methods read only for the warnings and "Attrezzi e materiali" (all in 42.22, read in the jar): through
-- pcall, so that a program that runs this checker on a game of its own (ZomBOT) without them still has the indexes and
-- the rest of the check; nil (or the default) when one is missing.
local function displayCategoryOf(item)
	return item:getDisplayCategory();
end

local function categoryOf(item)
	local ok, category = pcall(displayCategoryOf, item);

	return ok and category or nil;
end

local function inputExtrasOf(input)
	return input:getIntAmount(), input:getOriginalLine(), input:isNotDull() or input:sharpnessCheck();
end

local function inputExtras(input)
	local ok, amount, line, sharp = pcall(inputExtrasOf, input);

	if not ok
	then
		return 1, nil, false;
	end

	return amount or 1, line, sharp == true;
end

local function indexItem(item)
	if item:getObsolete()
	then
		return;
	end

	local fullType = item:getFullName();
	local text = item:getDisplayName() or fullType;
	local lower = string.lower(text);
	local list = Names.typesByName[lower];

	Names.typeByLower[string.lower(fullType)] = fullType;
	Names.itemText[fullType] = text;
	Names.itemCategory[fullType] = categoryOf(item);

	if list == nil
	then
		list = {};
		Names.typesByName[lower] = list;
		table.insert(Names.itemNameList, { lower = lower, text = text });
	end

	table.insert(list, fullType);
end

local function indexPerks()
	local list = PerkFactory and PerkFactory.PerkList;

	if list == nil
	then
		return;
	end

	for i = 0, list:size() - 1
	do
		local perk = list:get(i);

		if perk:getParent() ~= Perks.None
		then
			Names.perkByLower[string.lower(perk:getName())] = perk;
			Names.perkByLower[string.lower(perk:getId())] = perk;
			table.insert(Names.skillList, { text = perk:getName(), id = perk:getId() });
		end
	end

	table.sort(Names.skillList, function(a, b)
		return string.lower(a.text) < string.lower(b.text);
	end);
end

-- one slice of the building; true when everything is indexed
local function step(max)
	local build = Names.build;
	local manager = getScriptManager();

	if build.recipes == nil
	then
		build.recipes = manager:getAllCraftRecipes();
		build.items = manager:getAllItems();
		build.recipeIndex = 0;
		build.itemIndex = 0;
	end

	local done = 0;

	while build.recipeIndex < build.recipes:size() and done < max
	do
		indexRecipe(build.recipes:get(build.recipeIndex));
		build.recipeIndex = build.recipeIndex + 1;
		done = done + 1;
	end

	while build.itemIndex < build.items:size() and done < max
	do
		indexItem(build.items:get(build.itemIndex));
		build.itemIndex = build.itemIndex + 1;
		done = done + 1;
	end

	if build.recipeIndex >= build.recipes:size() and build.itemIndex >= build.items:size()
	then
		indexPerks();
		Names.build = nil;
		Names.state = "ready";

		return true;
	end

	return false;
end

function AutoPilotMoon.Macro.Names.onTick()
	if Names.state ~= "building" or step(Names.slice)
	then
		Events.OnTick.Remove(Names.onTick);
	end
end

function AutoPilotMoon.Macro.Names:isReady()
	return Names.state == "ready";
end

-- starts the building in slices (the editor says "preparo l'elenco delle ricette..." meanwhile)
function AutoPilotMoon.Macro.Names:ensure()
	if Names.state ~= nil
	then
		return;
	end

	reset();
	Names.state = "building";
	Names.build = {};
	Events.OnTick.Add(Names.onTick);
end

-- everything now (a macro started from the menu before the editor was ever opened: once per session)
function AutoPilotMoon.Macro.Names:buildNow()
	if Names.state == "ready"
	then
		return;
	end

	if Names.state == nil
	then
		reset();
		Names.state = "building";
		Names.build = {};
	end

	Events.OnTick.Remove(Names.onTick);

	while not step(100000)
	do
	end
end

-- forget everything (the tests; a reload of the scripts)
function AutoPilotMoon.Macro.Names:forget()
	Events.OnTick.Remove(Names.onTick);
	Names.state = nil;
	Names.build = nil;
	reset();
end

-- ============================================================================================================
-- Resolution (the resolver of AutoPilotMoon.Macro.Lang)
-- ============================================================================================================

local function words(text)
	local list = {};

	for word in string.gmatch(string.lower(text), "%S+")
	do
		table.insert(list, word);
	end

	return list;
end

-- up to Names.maxSuggestions names: those containing every word written, then those starting like it
local function suggest(nameList, text)
	local wanted = words(text);
	local found = {};
	local seen = {};

	if #wanted == 0
	then
		return found;
	end

	for i, entry in ipairs(nameList)
	do
		if #found >= Names.maxSuggestions
		then
			return found;
		end

		local all = true;

		for j, word in ipairs(wanted)
		do
			if not string.find(entry.lower, word, 1, true)
			then
				all = false;

				break;
			end
		end

		if all and not seen[entry.lower]
		then
			seen[entry.lower] = true;
			table.insert(found, entry.text);
		end
	end

	for i, entry in ipairs(nameList)
	do
		if #found >= Names.maxSuggestions
		then
			return found;
		end

		if string.sub(entry.lower, 1, string.len(wanted[1])) == wanted[1] and not seen[entry.lower]
		then
			seen[entry.lower] = true;
			table.insert(found, entry.text);
		end
	end

	return found;
end

local function clean(text)
	return string.lower(AutoPilotMoon.Macro.Lang.trim(string.gsub(text or "", "%s+", " ")));
end

-- the recipes of a name or an id (a list), or nil and up to 3 suggestions
function AutoPilotMoon.Macro.Names:resolveRecipe(text)
	local lower = clean(text);
	local byId = Names.recipeById[lower];

	if byId
	then
		return { byId };
	end

	local list = Names.recipesByName[lower];

	if list
	then
		return list;
	end

	return nil, suggest(Names.recipeNameList, lower);
end

-- the full types of a name or a type (a list), or nil and up to 3 suggestions
function AutoPilotMoon.Macro.Names:resolveItem(text)
	local lower = clean(text);
	local fullType = Names.typeByLower[lower];

	if fullType
	then
		return { fullType };
	end

	local list = Names.typesByName[lower];

	if list
	then
		return list;
	end

	return nil, suggest(Names.itemNameList, lower);
end

function AutoPilotMoon.Macro.Names:resolveSkill(text)
	return Names.perkByLower[clean(text)];
end

function AutoPilotMoon.Macro.Names:skillId(perk)
	local id = perk:getId();

	if string.find(id, " ", 1, true)
	then
		return nil;
	end

	return id;
end

function AutoPilotMoon.Macro.Names:recipeId(recipe)
	return recipe:getName();
end

function AutoPilotMoon.Macro.Names:recipeName(recipe)
	local id = recipe:getName();

	return Names.recipeText[id] or getText(recipe:getTranslationName());
end

function AutoPilotMoon.Macro.Names:itemName(fullType)
	return Names.itemText[fullType] or fullType;
end

-- more than one recipe has this recipe's name (the recorder then writes the id)
function AutoPilotMoon.Macro.Names:isAmbiguousRecipe(recipe)
	local list = Names.recipesByName[string.lower(Names:recipeName(recipe))];

	return list ~= nil and #list > 1;
end

-- the other types with this type's name
function AutoPilotMoon.Macro.Names:typesWithSameName(fullType)
	return Names.typesByName[string.lower(Names:itemName(fullType))] or { fullType };
end

-- the recipe consumes one of these types, or works on one of them (the item a repair or a sharpening keeps: the one
-- the right click is on, Names:targetTypes)
function AutoPilotMoon.Macro.Names:acceptsAny(recipe, types)
	local consumed = Names:consumedTypes(recipe);
	local targets = Names:targetTypes(recipe);

	for i, fullType in ipairs(types)
	do
		if consumed[fullType] or targets[fullType]
		then
			return true;
		end
	end

	return false;
end

-- the dismantling recipes of these types (each once)
function AutoPilotMoon.Macro.Names:dismantleRecipes(types)
	local found = {};
	local seen = {};

	for i, fullType in ipairs(types)
	do
		for j, recipe in ipairs(Names.dismantleByType[fullType] or {})
		do
			if not seen[recipe]
			then
				seen[recipe] = true;
				table.insert(found, recipe);
			end
		end
	end

	return found;
end

-- the workbench of a recipe the macros cannot do yet, with the game's own words ("Fornace semplice o migliore")
function AutoPilotMoon.Macro.Names:benchName(recipe)
	local tags = recipe:getTags();
	local fallback = nil;

	if tags
	then
		for i = 0, tags:size() - 1
		do
			local tag = tags:get(i);
			local text = getTextOrNull("IGUI_CraftingWindow_" .. tag);

			if text
			then
				return text;
			end

			if fallback == nil and tag ~= "InHandCraft" and tag ~= "AnySurfaceCraft"
			then
				fallback = tag;
			end
		end
	end

	return fallback or recipe:getCategory() or "?";
end

function AutoPilotMoon.Macro.Names:isLearned(player, recipe)
	return not recipe:needToBeLearn() or CraftRecipeManager.hasPlayerLearnedRecipe(recipe, player);
end

-- the skills a recipe gives experience in
function AutoPilotMoon.Macro.Names:xpPerks(recipe)
	local perks = {};

	for i = 0, recipe:getXPAwardCount() - 1
	do
		local award = recipe:getXPAward(i);

		if award and award:getPerk()
		then
			table.insert(perks, award:getPerk());
		end
	end

	return perks;
end

-- ============================================================================================================
-- Kinds, inputs, requirements (the warnings of MACRO-AUTOPILOT.md 2.9 and "Attrezzi e materiali", 4.5)
-- ============================================================================================================

-- the kinds of items a macro must not use up unless told which: food, seeds (the game's Gardening: seeds and packets),
-- containers (they may hold something: sacks, bags, bottles). From the game's DisplayCategory of the item.
Names.kindOfCategory = { Food = "food", Gardening = "seed", Container = "container", Bag = "container", WaterContainer = "container" };
Names.kindOrder = { "food", "seed", "container" };

-- "food" / "seed" / "container" or nil
function AutoPilotMoon.Macro.Names:itemKind(fullType)
	return Names.kindOfCategory[Names.itemCategory[fullType] or ""];
end

local function splitTags(line)
	local tags = {};
	local list = line and string.match(line, "tags%[([^%]]*)%]");

	if list
	then
		for tag in string.gmatch(list, "[^;%s]+")
		do
			table.insert(tags, string.lower(tag));
		end
	end

	return tags;
end

-- the flags of an input that say it is the item the recipe works on (InputScript.isDamaged / isSharpenable of 42.22:
-- flags[IsDamaged] of the repairs, flags[IsSharpenable] of the sharpenings); read through pcall like the extras, else
-- from the line of the recipe ("flags[Prop2;IsDamaged]")
local function inputTargetOf(input)
	return input:isDamaged(), input:isSharpenable();
end

local function inputTarget(input, line)
	local ok, damaged, sharpenable = pcall(inputTargetOf, input);

	if ok
	then
		return damaged == true, sharpenable == true;
	end

	local flags = line and string.match(line, "flags%[([^%]]*)%]") or "";

	return string.find(flags, "IsDamaged", 1, true) ~= nil, string.find(flags, "IsSharpenable", 1, true) ~= nil;
end

-- the item inputs of a recipe, cached: { keep (a tool, never used up: mode:keep), types (full types, each once, the
-- game's order), tags (as the recipe writes them, "base:sharpknife"; empty for a list of types), amount, sharp (it must
-- cut: IsNotDull or SharpnessCheck), damaged / sharpenable (flags[IsDamaged] / flags[IsSharpenable]: the item must be
-- damaged / not fully sharp), target (kept and one of those two: the item the recipe works on, a repair's or a
-- sharpening's) }. Inputs of fluids or energy are left out.
function AutoPilotMoon.Macro.Names:inputSlots(recipe)
	local id = recipe:getName();
	local slots = Names.slotsCache[id];

	if slots
	then
		return slots;
	end

	slots = {};

	local inputs = recipe:getInputs();

	for i = 0, inputs:size() - 1
	do
		local input = inputs:get(i);
		local items = input:getPossibleInputItems();

		if items and items:size() > 0
		then
			local amount, line, sharp = inputExtras(input);
			local damaged, sharpenable = inputTarget(input, line);
			local keep = input:isKeep() or input:isTool();
			local slot = { keep = keep, types = {}, tags = splitTags(line), amount = amount > 0 and amount or 1, sharp = sharp,
				damaged = damaged, sharpenable = sharpenable, target = keep and (damaged or sharpenable) };
			local seen = {};

			for j = 0, items:size() - 1
			do
				local item = items:get(j);
				local fullType = item:getFullName();

				if not seen[fullType]
				then
					seen[fullType] = true;
					table.insert(slot.types, fullType);

					if Names.itemCategory[fullType] == nil
					then
						Names.itemCategory[fullType] = categoryOf(item);
					end
				end
			end

			table.insert(slots, slot);
		end
	end

	Names.slotsCache[id] = slots;

	return slots;
end

local function requiredSkillsOf(recipe)
	local list = {};

	for i = 0, recipe:getRequiredSkillCount() - 1
	do
		local required = recipe:getRequiredSkill(i);

		if required and required:getPerk()
		then
			table.insert(list, { perk = required:getPerk(), level = required:getLevel() });
		end
	end

	return list;
end

-- the skills a recipe needs: { perk, level } (none when the game cannot say: see categoryOf)
function AutoPilotMoon.Macro.Names:requiredSkills(recipe)
	local ok, list = pcall(requiredSkillsOf, recipe);

	return ok and list or {};
end

-- the types in the order a suggestion takes them: what is not food, seeds or a container first, then containers,
-- seeds, food; an "Empty..." type first among its kind (Base.EmptySandbag before a sack with something in it)
function AutoPilotMoon.Macro.Names:rankTypes(types)
	local rank = { container = 1, seed = 2, food = 3 };
	local list = {};

	for i, fullType in ipairs(types)
	do
		local empty = string.find(fullType, ".Empty", 1, true) and 0 or 1;

		table.insert(list, { fullType = fullType, key = (rank[Names:itemKind(fullType) or ""] or 0) * 10 + empty, i = i });
	end

	table.sort(list, function(a, b)
		if a.key ~= b.key
		then
			return a.key < b.key;
		end

		return a.i < b.i;
	end);

	local sorted = {};

	for i, entry in ipairs(list)
	do
		table.insert(sorted, entry.fullType);
	end

	return sorted;
end

-- names of ONE item each that contain every word written (not the name itself), whose type passes keep(fullType):
-- { { text, fullType } }, the shortest first (the closest to what was written: "Sacco di juta" before "Sacco della
-- posta", whatever the order of the game's item list), at most max
function AutoPilotMoon.Macro.Names:uniqueNamesLike(text, keep, max)
	local wanted = words(text);
	local lower = clean(text);
	local found = {};

	if #wanted == 0
	then
		return found;
	end

	for i, entry in ipairs(Names.itemNameList)
	do
		-- a short word matches half the game: enough to choose from
		if #found >= Names.maxLike
		then
			break;
		end

		local types = Names.typesByName[entry.lower];

		if entry.lower ~= lower and types and #types == 1 and (keep == nil or keep(types[1]))
		then
			local all = true;

			for j, word in ipairs(wanted)
			do
				if not string.find(entry.lower, word, 1, true)
				then
					all = false;

					break;
				end
			end

			if all
			then
				table.insert(found, { text = entry.text, fullType = types[1] });
			end
		end
	end

	table.sort(found, function(a, b)
		local la, lb = string.len(a.text), string.len(b.text);

		if la ~= lb
		then
			return la < lb;
		end

		return a.text < b.text;
	end);

	while #found > max
	do
		table.remove(found);
	end

	return found;
end

-- the names of other recipes the macros can do, whose name holds every word of this one, that use one of the types
-- ("Strappa sacco grande" for "Sacco di juta" written with "Strappa sacco"), at most max
function AutoPilotMoon.Macro.Names:recipesAccepting(types, nearText, max)
	local wanted = words(nearText);
	local lower = clean(nearText);
	local found = {};
	local seen = {};

	if #wanted == 0
	then
		return found;
	end

	for i, recipe in ipairs(Names.recipeList)
	do
		if #found >= max
		then
			break;
		end

		local name = Names:recipeName(recipe);
		local nameLower = string.lower(name);

		if nameLower ~= lower and not seen[nameLower]
		then
			local all = true;

			for j, word in ipairs(wanted)
			do
				if not string.find(nameLower, word, 1, true)
				then
					all = false;

					break;
				end
			end

			if all and Names:acceptsAny(recipe, types)
			then
				seen[nameLower] = true;
				table.insert(found, name);
			end
		end
	end

	return found;
end

-- ============================================================================================================
-- Work on a kept item: repair and sharpen (wave 0, 13/11/2026, ANALISI-API-MACRO-LAVORATIVE.md A0.1-A0.3)
-- ============================================================================================================

-- the full types of the item a recipe works on and keeps (a repair's damaged item, a sharpening's blade: the kept
-- inputs with flags[IsDamaged] or flags[IsSharpenable]), a set, cached; empty for the other recipes
function AutoPilotMoon.Macro.Names:targetTypes(recipe)
	local id = recipe:getName();
	local set = Names.targetCache[id];

	if set
	then
		return set;
	end

	set = {};

	for i, slot in ipairs(Names:inputSlots(recipe))
	do
		if slot.target
		then
			for j, fullType in ipairs(slot.types)
			do
				set[fullType] = true;
			end
		end
	end

	Names.targetCache[id] = set;

	return set;
end

-- the full types the macro clicks for a recipe when the line does not say which item (craft("R") without using=): the
-- item the recipe works on when it keeps one (the right click on the damaged bat, never on the tape: the game would
-- then choose the bat itself, maybe a favourite), else what it uses up (Names:consumedTypes); a set, cached
function AutoPilotMoon.Macro.Names:clickTypes(recipe)
	local id = recipe:getName();
	local set = Names.clickCache[id];

	if set
	then
		return set;
	end

	local targets = Names:targetTypes(recipe);
	local any = false;

	for i, slot in ipairs(Names:inputSlots(recipe))
	do
		any = any or slot.target;
	end

	set = any and targets or Names:consumedTypes(recipe);
	Names.clickCache[id] = set;

	return set;
end

-- the order of the game's recipes when more than one repairs or sharpens the item and the line does not choose the
-- material: the richest first (resin, duct tape, glue, adhesive tape, zip ties: ANALISI-API-MACRO-LAVORATIVE.md A0.2);
-- a recipe not in the list after them, in the game's order
Names.workOrder = {
	repair = { "FixWithEpoxy", "FixWithDuctTape", "FixWithWoodGlue", "FixWithGlue", "FixWithAdhesiveTape", "FixWithZipties",
		"FixWithEpoxyAndRags" },
	sharpen = { "SharpenBlade", "SharpenBladePoorlyWithFile" },
};

local function startsWith(text, prefix)
	return string.sub(text, 1, string.len(prefix)) == prefix;
end

-- the recipe is one of the game's repairs (its category Repair or an id Fix...) or sharpenings (an id Sharpen...)
local function isWorkRecipe(work, recipe)
	local id = recipe:getName();

	if work == "sharpen"
	then
		return startsWith(id, "Sharpen") or recipe:getCategory() == "Repair";
	end

	return startsWith(id, "Fix") or recipe:getCategory() == "Repair";
end

-- The recipes the macros can do (by hand or on a surface) that repair (work = "repair": a kept input with
-- flags[IsDamaged]) or sharpen (work = "sharpen": flags[IsSharpenable]) one of the types; with materials (a list of
-- full types, or nil) only those that use one of them up. In the order of Names.workOrder: the first the game can do
-- now is the one a macro uses (MacroRun's choice).
function AutoPilotMoon.Macro.Names:workRecipes(work, types, materials)
	local flag = work == "sharpen" and "sharpenable" or "damaged";
	local rank = {};
	local found = {};

	for i, id in ipairs(Names.workOrder[work] or {})
	do
		rank[id] = i;
	end

	for i, recipe in ipairs(Names.recipeList)
	do
		if isWorkRecipe(work, recipe)
		then
			local fits = false;

			for j, slot in ipairs(Names:inputSlots(recipe))
			do
				if slot.target and slot[flag]
				then
					for k, fullType in ipairs(slot.types)
					do
						for m, wanted in ipairs(types)
						do
							fits = fits or fullType == wanted;
						end
					end
				end
			end

			if fits and materials
			then
				local consumed = Names:consumedTypes(recipe);
				local uses = false;

				for j, fullType in ipairs(materials)
				do
					uses = uses or consumed[fullType] == true;
				end

				fits = uses;
			end

			if fits
			then
				table.insert(found, { recipe = recipe, rank = rank[recipe:getName()] or (1000 + i) });
			end
		end
	end

	table.sort(found, function(a, b)
		return a.rank < b.rank;
	end);

	local list = {};

	for i, entry in ipairs(found)
	do
		table.insert(list, entry.recipe);
	end

	return list;
end

local function autoLearnOf(recipe)
	local any = {};
	local all = {};

	for i = 0, recipe:getAutoLearnAnySkillCount() - 1
	do
		local skill = recipe:getAutoLearnAnySkill(i);

		table.insert(any, skill:getPerk():getName() .. " " .. tostring(skill:getLevel()));
	end

	for i = 0, recipe:getAutoLearnAllSkillCount() - 1
	do
		local skill = recipe:getAutoLearnAllSkill(i);

		table.insert(all, skill:getPerk():getName() .. " " .. tostring(skill:getLevel()));
	end

	return any, all;
end

-- how a recipe not known yet is learned, in words (CraftRecipe.getAutoLearnAnySkill / getAutoLearnAllSkill of 42.22,
-- AutoLearnAny / AutoLearnAll of the scripts): "si impara da sola a Manutenzione 2", else from a magazine or a book
-- "a", "a o b", "a, b o c" (key: IGUI_AutoPilot_E_Or or IGUI_AutoPilot_E_Kind_And, "%1 o %2")
local function joined(list, key)
	if #list <= 1
	then
		return list[1] or "";
	end

	local head = {};

	for i = 1, #list - 1
	do
		table.insert(head, list[i]);
	end

	return getText(key, table.concat(head, ", "), list[#list]);
end

function AutoPilotMoon.Macro.Names:learnHint(recipe)
	local ok, any, all = pcall(autoLearnOf, recipe);

	if ok and #any > 0
	then
		return getText("IGUI_AutoPilot_E_LearnAny", joined(any, "IGUI_AutoPilot_E_Or"));
	end

	if ok and #all > 0
	then
		return getText("IGUI_AutoPilot_E_LearnAll", joined(all, "IGUI_AutoPilot_E_Kind_And"));
	end

	return getText("IGUI_AutoPilot_E_LearnRead");
end
