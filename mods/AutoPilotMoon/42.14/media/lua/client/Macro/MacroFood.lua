-- AutoPilot (Moon): automations for the Moon server.

-- Smart food and water for the macros (20/11/2026, ANALISI-MACRO-INTELLIGENTI.md 4-7, the owner's decisions of 10):
-- what eat(), drink(), drink(source=True), refill(), has_food() and has_drink() choose. Only the choice: MacroBody.lua
-- queues the game's own actions and confirms them with the engine's wait.
--
-- Where (5): what the character carries (the inventory, bags inside included), then what is within reach as the loot
-- window shows it (ISInventoryPage:refreshBackpacks of 42.22: the 3x3 squares on the character's floor it can reach,
-- the floor, furniture, fridges, freezers, a trunk; the safehouses the character may not loot already left out by the
-- window, the crates locked for the character left out by ISInventoryPaneContextMenu.getContainers). Never a corpse,
-- a ZomBOT gravestone, a container locked for the character, a square of a safehouse it may not use. The server can
-- switch the search within reach off (MacroEatNear, on by default). A container never opened answers later in
-- multiplayer (the engine's Wait:loadState): it is "loading" until then.
-- The vicinity (26/11/2026, ANALISI-AUTONOMIA.md 3.5, MacroNear.lua): when nothing carried or within reach will do,
-- eat() and drink() look within Near.radius squares in the character's building (walk=False, near=False or the server's
-- MacroEatNear off: never): the nearest container already known (or item on the floor) with what the line takes is the
-- choice's far (MacroBody.lua walks there with Near:approach, then the line starts again within reach); else, for the
-- line the macro is starting only, the nearest kitchen container never opened (the walk, then the loot window asks for
-- it), at most Near.maxLooks a line. has_food(), has_drink() and "Adesso si puo' fare?" never count a container never
-- opened (the editor says it would look into it); the order of the food does not change (the vicinity after the reach).
--
-- The food eat() eats as it is (4.3): the game's own double click (ISInventoryPane: Food that feeds, not CantEat, not
-- burnt, not rotten, not a poison the character recognises, not dangerous raw), and what a careful player leaves:
-- tainted (made with tainted water), frozen (but ice cream and what is good frozen), a favourite, held or worn, very
-- unpleasant (unhappiness 30 or more, unless picky=False), alcohol, what needs a lighter, what the game's menu does
-- not call "Eat" (oils and sauces "Drink"), and berries and mushrooms the character cannot tell apart (a herbalist's
-- type without the Herbalist recipe, or the NO_DETECT tag: their poison is given at random when foraged). Never
-- getPoisonPower nor isPoison: they would tell the macro a poison the player cannot see.
-- A closed can: the item's own opening recipe ("Open and Eat"), when the game can do it now (a can opener on the
-- character or within reach).
--
-- The order: what the character carries first; within reach only when it spoils within a day and what is carried does
-- not (decision Q3); then what spoils first, then the smaller meal; closed cans after the food ready to eat.
--
-- Water (4.5): drink() without a name only clean water (never tainted, poisonous, bleach, sealed, over 3 litres), the
-- emptiest first; source=True: the nearest water source of the world with clean water (a sink, a barrel, a well),
-- within F.sourceRadius squares on the character's floor, as the game's "Drink" of the right click offers it (the
-- same building, not a washer or a dryer, a drink); never tainted water, also when the player could not know it
-- (decision Q5: the hidden information only used to NOT drink). refill(): the bottles carried that hold clean water or
-- nothing, at that source, as the game's "Fill".

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Food = AutoPilotMoon.Macro.Food or {};

local F = AutoPilotMoon.Macro.Food;

F.urgentDays = 1;              -- within reach beats carried only when it spoils within this many days (Q3)
F.unhappyMax = 30;             -- eat() leaves what makes this unhappy or more (dog food, lard, raw pasta), unless picky=False
F.sourceRadius = 8;            -- drink(source=True), refill(): a water source within this many squares (same floor)
F.lootRefreshMs = 10000;       -- the loot window, caught up with the character's square, rebuilt at most this often
F.maxDrinkCapacity = 3.0;      -- the game's "Too big to drink from" (ISInventoryPaneContextMenu.doDrinkFluidMenu)
F.notPerishable = 100000000;   -- getOffAgeMax of the food that never spoils
F.eatAmounts = { all = 1, half = 0.5, quarter = 0.25 };

local function Wait()
	return AutoPilotMoon.Wait;
end

-- the vicinity within 8 squares, walking (MacroNear.lua, contract C4 of ANALISI-AUTONOMIA.md 5)
local function Near()
	return AutoPilotMoon.Macro.Near;
end

-- the text of why eat() / drink() find nothing, its key remembered for the notifications (the event's code of the stop
-- that follows: MacroR_NoFood...; the game's own "cannot eat more": the code "stopped" with the key in its detail)
local function whyText(key, a)
	return AutoPilotMoon.Notify:why(key, a);
end

local function moodle(player, name)
	return AutoPilotMoon.Macro.Run:moodleLevel(player, name);
end

local function stat(player, name)
	local stats = player:getStats();
	local which = CharacterStat[name];

	if stats == nil or which == nil
	then
		return 0;
	end

	return stats:get(which) or 0;
end

-- an item the macros may use: never a favourite, an equipped or a worn one
local function usable(player, item)
	return not item:isFavorite() and not item:isEquipped() and not player:isEquipped(item) and not item:isWorn();
end

local function named(op, item)
	if op.itemTypes == nil
	then
		return true;
	end

	for i, fullType in ipairs(op.itemTypes)
	do
		if item:getFullType() == fullType
		then
			return true;
		end
	end

	return false;
end

-- ============================================================================================================
-- Within reach
-- ============================================================================================================

-- the server lets the macros look within reach (MacroEatNear) and the line did not say near=False
function AutoPilotMoon.Macro.Food:nearAllowed(op)
	return op.near ~= false and AutoPilotMoon.Sandbox:getBooleanOn("MacroEatNear") == true;
end

-- The loot window rebuilt when it has not caught up with the character yet. It rebuilds itself when the character
-- changes square or direction (ISInventoryPage:update, its lastSquare) and when an item lands on the floor
-- (OnContainerUpdate), maybe a frame after the macro decides: rebuilt here only when its square is not the
-- character's, else at most every F.lootRefreshMs (the window's buttons are not rebuilt at every condition).
local function refreshLoot(player)
	local loot = getPlayerLoot(player:getPlayerNum());

	if loot == nil
	then
		return;
	end

	local square = player:getCurrentSquare();
	local time = getTimestampMs();
	local last = F.lastRefresh;

	if loot.lastSquare == square and last and last.player == player and time - last.at < F.lootRefreshMs
	then
		return;
	end

	loot:refreshBackpacks();
	F.lastRefresh = { player = player, at = time };
end

-- the loot window's containers the macros may eat and drink from: { container, group (2: within reach; 3: a part of a
-- car, the game may walk to it), name (as the loot window says it) }
function AutoPilotMoon.Macro.Food:nearContainers(player)
	local list = {};
	local inventory = player:getInventory();

	refreshLoot(player);

	local containers = ISInventoryPaneContextMenu.getContainers(player);

	if containers == nil
	then
		return list;
	end

	for i = 0, containers:size() - 1
	do
		local container = containers:get(i);

		if container and container ~= inventory and not container:isInCharacterInventory(player)
		then
			local parent = container:getParent();
			local skip = false;

			if parent
			then
				local square = parent:getSquare();

				skip = instanceof(parent, "IsoDeadBody") or AutoPilotMoon.Zones:isGrave(parent)
					or AutoPilotMoon.Item:isLockedFor(parent, container, player)
					or (square ~= nil and AutoPilotMoon.Zones:isProtected(square, player));
			else
				skip = container:isLockedToCharacter(player);
			end

			if not skip
			then
				table.insert(list, { container = container, group = (parent and instanceof(parent, "IsoMovingObject")) and 3 or 2,
					name = AutoPilotMoon.Destination:getContainerName(container) });
			end
		end
	end

	return list;
end

-- the contents of a container arrived from the server: "loaded" (and true when certain: an empty one may be a server
-- that never answered, Wait:loadState) or "loading" (a container never seen is asked for, as the loot window does)
local function contentsState(player, container)
	local state, certain = Wait():loadState(container);

	if state == "unknown"
	then
		Wait():explore(container, player);
		state, certain = Wait():loadState(container);
	end

	if state == "loaded"
	then
		return "loaded", certain == true;
	end

	return "loading", false;
end

-- the containers within reach whose contents are read now, those still loading, and those read but not for sure (no
-- answer seen: empty, or the server did not answer); opts.anyway: read them all
local function readableNear(player, op, opts)
	local ready, loading, unsure = {}, {}, {};

	if not F:nearAllowed(op)
	then
		return ready, loading, unsure;
	end

	for i, entry in ipairs(F:nearContainers(player))
	do
		local state, certain = contentsState(player, entry.container);

		if state == "loaded" or (opts and opts.anyway)
		then
			table.insert(ready, entry);

			if not certain
			then
				table.insert(unsure, entry);
			end
		else
			table.insert(loading, entry);
		end
	end

	return ready, loading, unsure;
end

-- The vicinity (ring 3, MacroNear.lua): the nearest entry with an item test accepts, as a choice { item, group = 3,
-- from = { container, name, group = 3 }, far = the entry } (best(container): the item of that container the line
-- would take first; nil: entry.item); else, for the eat() / drink() line the macro is starting now (kind), the nearest
-- kitchen container never opened (a choice without item: the walk, then a look). Never for a condition: what never
-- opened only for the editor's "Adesso si puo' fare?", as a second value (the list it would look into).
local function farChoice(player, op, kind, test, best)
	if not Near():allowed(op)
	then
		return nil, nil;
	end

	local line = op.op == "ACTION" and op.kind == kind;
	local starting = line and Near():starting(player, op);
	local entry = Near():find(player, test, { unknown = line, memory = starting and Near():memory(player, op) or nil });

	if entry == nil
	then
		return nil, nil;
	end

	local from = { container = entry.container, name = entry.name, group = 3 };

	if entry.item == nil
	then
		if starting
		then
			return { group = 3, from = from, far = entry }, nil;
		end

		return nil, { entry };
	end

	local item = entry.container and best(entry.container) or entry.item;

	return { item = item, id = item:getID(), group = 3, from = from, far = entry }, nil;
end

-- the items of a container a test accepts, as a Lua list (its own items, never inside a bag of it)
local function itemsOf(container, test)
	local list = {};
	local items = container:getItems();

	for i = 0, items:size() - 1
	do
		local item = items:get(i);

		if item and test(item)
		then
			table.insert(list, item);
		end
	end

	return list;
end

-- the names of entries, "Frigo, Pavimento"
function AutoPilotMoon.Macro.Food:names(entries)
	local names = {};
	local seen = {};

	for i, entry in ipairs(entries or {})
	do
		if not seen[entry.name]
		then
			seen[entry.name] = true;
			table.insert(names, entry.name);
		end
	end

	return table.concat(names, ", ");
end

-- ============================================================================================================
-- Food
-- ============================================================================================================

-- berries and mushrooms whose poison the character cannot see: a herbalist's type (static: the script's) without the
-- Herbalist recipe, or the NO_DETECT tag. The game's own IsoGameCharacter.isKnownPoison tells a herbalist's food only
-- by that recipe; nothing here reads the poison itself.
function AutoPilotMoon.Macro.Food:isDoubtful(player, item)
	local herbal = item:getHerbalistType();

	if herbal == nil or herbal == ""
	then
		return false;
	end

	return item:hasTag(ItemTag.NO_DETECT) or not player:isRecipeActuallyKnown("Herbalist");
end

-- good frozen: ice cream and the GOOD_FROZEN tag (Food.getUnhappyChange of 42.22 adds nothing for them)
local function goodFrozen(item)
	return item:getType() == "Icecream" or item:hasTag(ItemTag.GOOD_FROZEN);
end

-- What eat() makes of an item: "food" (eaten as it is), "can" (closed, the game opens it), "frozen" (never: said when
-- nothing else is left), "unhappy" (very unpleasant: only with picky=False), or nil (never).
function AutoPilotMoon.Macro.Food:foodVerdict(player, item, op)
	if not instanceof(item, "Food") or not usable(player, item) or not named(op, item)
	then
		return nil;
	end

	if item:isRotten() or item:isTainted() or player:isKnownPoison(item) or F:isDoubtful(player, item)
	then
		return nil;
	end

	local script = item:getScriptItem();

	if script ~= nil and script:isCantEat() == true
	then
		-- a closed can: its own opening recipe; a jar or a frozen bag: a recipe of its own first, never eat()
		if item:getOpeningRecipe() ~= nil
		then
			return "can";
		end

		return nil;
	end

	if item:getHungChange() >= 0
	then
		return nil;
	end

	local menu = item:getCustomMenuOption();

	if menu ~= nil and menu ~= getText("ContextMenu_Eat")
	then
		return nil;
	end

	if item:isBurnt() or (item:isbDangerousUncooked() and not item:isCooked())
	then
		return nil;
	end

	if item:isAlcoholic() or item:getRequireInHandOrInventory() ~= nil
	then
		return nil;
	end

	if item:isFrozen() and not goodFrozen(item)
	then
		return "frozen";
	end

	if item:getUnhappyChange() >= F.unhappyMax
	then
		return op.picky == false and "food" or "unhappy";
	end

	return "food";
end

-- the days before it spoils; never spoiling: last
local function daysLeft(item)
	local max = item:getOffAgeMax();

	if max == nil or max >= F.notPerishable
	then
		return F.notPerishable;
	end

	return max - item:getAge();
end

-- the food first, then: within a day first (Q3), carried first, what spoils first, the smaller meal, the lower id
local function better(a, b)
	if a.can ~= b.can
	then
		return not a.can;
	end

	local ua, ub = a.days <= F.urgentDays, b.days <= F.urgentDays;

	if ua ~= ub
	then
		return ua;
	end

	if a.group ~= b.group
	then
		return a.group < b.group;
	end

	if a.days ~= b.days
	then
		return a.days < b.days;
	end

	if a.hung ~= b.hung
	then
		return a.hung > b.hung;
	end

	return a.id < b.id;
end

-- the closed can's opening recipe when the game can do it now (an opener carried or within reach), else nil
local function openingRecipe(player, item)
	local name = item:getOpeningRecipe();
	local recipe = name and getScriptManager():getCraftRecipe(name) or nil;

	if recipe == nil or AutoPilotMoon.Craft:check(player, recipe, item) ~= nil
	then
		return nil;
	end

	return recipe;
end

-- every food and closed can eat() could take, with what was left out and why
local function collectFood(player, op, opts)
	local found = { list = {}, frozen = 0, unhappy = 0, cans = 0, loading = {}, unsure = {} };
	local seen = {};

	local function consider(item, group, entry)
		local id = item:getID();

		if seen[id]
		then
			return;
		end

		seen[id] = true;

		local verdict = F:foodVerdict(player, item, op);

		if verdict == "food" or verdict == "can"
		then
			if verdict == "can"
			then
				found.cans = found.cans + 1;
			end

			if verdict == "food" or op.openCans ~= false
			then
				table.insert(found.list, { item = item, id = id, group = group, from = entry, days = daysLeft(item),
					hung = item:getHungChange(), can = verdict == "can" });
			end
		elseif verdict == "frozen"
		then
			found.frozen = found.frozen + 1;
		elseif verdict == "unhappy"
		then
			found.unhappy = found.unhappy + 1;
		end
	end

	local carried = player:getInventory():getAllEvalRecurse(function(item)
		return instanceof(item, "Food");
	end);

	for i = 0, carried:size() - 1
	do
		consider(carried:get(i), 1, nil);
	end

	local ready, loading, unsure = readableNear(player, op, opts);

	found.loading = loading;
	found.unsure = unsure;

	for i, entry in ipairs(ready)
	do
		-- the container's own items, as its button in the loot window shows them (the bags inside a crate are not
		-- listed by the game: never looked into)
		local items = entry.container:getItems();

		for k = 0, items:size() - 1
		do
			consider(items:get(k), entry.group, entry);
		end
	end

	table.sort(found.list, better);

	return found;
end

-- the food of the vicinity (MacroNear.lua): what eat() eats as it is, and the closed cans unless open_cans=False (the
-- opener is looked for once within reach); in a container the best by the same order
local function farFood(player, op)
	local function takes(item)
		local verdict = F:foodVerdict(player, item, op);

		return verdict == "food" or (verdict == "can" and op.openCans ~= false);
	end

	local function best(container)
		local list = {};

		for i, item in ipairs(itemsOf(container, takes))
		do
			table.insert(list, { item = item, id = item:getID(), group = 3, days = daysLeft(item), hung = item:getHungChange(),
				can = F:foodVerdict(player, item, op) == "can" });
		end

		table.sort(list, better);

		return list[1] and list[1].item or nil;
	end

	local choice, looking = farChoice(player, op, "eat", takes, best);

	if choice and choice.item
	then
		choice.days = daysLeft(choice.item);
		choice.hung = choice.item:getHungChange();
		choice.can = F:foodVerdict(player, choice.item, op) == "can";
	end

	return choice, looking;
end

-- What eat() would eat now: { item, group, from (nil: carried; else { container, group, name }), can, recipe (a can's
-- opening recipe), days, far (the vicinity, MacroNear.lua: the entry to walk to first; item nil for a kitchen
-- container never opened) }, or nil, the reason's text and its kind: "nothing" (nothing to eat: a "while possible" ends
-- well), "loading" (containers within reach not arrived yet: found.loading, the caller waits for them; for the editor
-- also the container never opened it would look into), nil (a refusal).
-- opts.anyway: read the containers still loading as they are (after the wait); opts.ignoreFull: do not ask whether the
-- character can eat more (has_food())
function AutoPilotMoon.Macro.Food:chooseFood(player, op, opts)
	if not (opts and opts.ignoreFull) and moodle(player, "FOOD_EATEN") >= 3
	then
		return nil, whyText("Tooltip_CantEatMore"), nil, nil;
	end

	local found = collectFood(player, op, opts);
	local noOpener = false;

	for i, choice in ipairs(found.list)
	do
		if not choice.can
		then
			return choice;
		end

		choice.recipe = openingRecipe(player, choice.item);

		if choice.recipe
		then
			return choice;
		end

		noOpener = true;
	end

	if #found.loading > 0
	then
		return nil, nil, "loading", found.loading;
	end

	-- nothing carried or within reach will do: the vicinity, walking (ANALISI-AUTONOMIA.md 3.5)
	local far, looking = farFood(player, op);

	if far
	then
		return far;
	end

	if looking
	then
		return nil, nil, "loading", looking;
	end

	if #found.unsure > 0 and #found.list == 0
	then
		-- a container within reach with no answer seen: never "nothing to eat" for sure (a "while possible" would end as
		-- if done)
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NotSeenNear", F:names(found.unsure)), nil, nil;
	end

	if noOpener
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoCanOpener"), "nothing", nil;
	end

	if found.cans > 0 and op.openCans == false
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_CansClosed"), "nothing", nil;
	end

	if found.frozen > 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_OnlyFrozen"), "nothing", nil;
	end

	if found.unhappy > 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_OnlyUnpleasant"), "nothing", nil;
	end

	return nil, whyText(F:nearAllowed(op) and "IGUI_AutoPilot_A_MacroR_NoFood" or "IGUI_AutoPilot_A_MacroR_NoFoodOn"), "nothing", nil;
end

-- The portion of eatItem: amount "all" (or nil) 1; "half" / "quarter" only when the game's "Eat" menu offers it for
-- that food (ISInventoryPaneContextMenu of 42.22: half from 2 of hunger and half the base hunger, a quarter from 4 and
-- a quarter of the base; always with an opening recipe), else all; "auto": the smallest portion offered that takes the
-- hunger under the game's first level (the moodle gone), else all.
function AutoPilotMoon.Macro.Food:portion(player, choice, amount)
	if amount == nil or amount == "all"
	then
		return 1;
	end

	local item = choice.item;
	local change = math.abs(item:getHungerChange() * 100) + 0.001;
	local base = math.abs(item:getBaseHunger() * 100) + 0.001;
	local can = choice.recipe ~= nil;
	local offered = { [0.5] = can or (change >= 2 and change >= base / 2), [0.25] = can or (change >= 4 and change >= base / 4) };

	if amount == "auto"
	then
		local numbers = AutoPilotMoon.Macro.Lang.stateNumbers.hungry;
		local target = numbers.at[1] / 100;
		local hunger = stat(player, "HUNGER");

		if change >= 1
		then
			for i, part in ipairs({ 0.25, 0.5 })
			do
				if offered[part] and hunger - change / 100 * part <= target
				then
					return part;
				end
			end
		end

		return 1;
	end

	local part = F.eatAmounts[amount] or 1;

	return (part == 1 or offered[part]) and part or 1;
end

-- ============================================================================================================
-- Drink
-- ============================================================================================================

-- a drink that is safe: not empty, small enough for the game, not sealed, nothing poisonous (bleach), tainted or a
-- mixture with them; without a name only water (a named one may be anything else safe: the player chose it)
function AutoPilotMoon.Macro.Food:isSafeDrink(player, item, op)
	local fluid = item:getFluidContainer();

	if fluid == nil or not usable(player, item) or not named(op, item)
	then
		return false;
	end

	if fluid:isEmpty() or fluid:getCapacity() > F.maxDrinkCapacity or item:isSealed() or not fluid:canPlayerEmpty()
	then
		return false;
	end

	if fluid:isPoisonous() or fluid:isTainted() or fluid:isPrimaryFluidType("Bleach")
	then
		return false;
	end

	if op.itemTypes == nil
	then
		return fluid:isPrimaryFluidType("Water");
	end

	return true;
end

-- carried first, then the emptiest (one bottle finished before the next is opened), then the lower id
local function byDrink(a, b)
	if a.group ~= b.group
	then
		return a.group < b.group;
	end

	if a.amount ~= b.amount
	then
		return a.amount < b.amount;
	end

	return a.id < b.id;
end

-- What drink() would drink from now: { item, group, from, far (the vicinity, as chooseFood) }, or nil, the reason's
-- text, the kind ("nothing", "loading" with the containers still loading). opts.anyway as chooseFood.
function AutoPilotMoon.Macro.Food:chooseDrink(player, op, opts)
	local list = {};
	local seen = {};

	local function consider(item, group, entry)
		local id = item:getID();

		if not seen[id] and F:isSafeDrink(player, item, op)
		then
			seen[id] = true;
			table.insert(list, { item = item, id = id, group = group, from = entry, amount = item:getFluidContainer():getAmount() });
		end
	end

	local carried = player:getInventory():getAllEvalRecurse(function(item)
		return item:getFluidContainer() ~= nil;
	end);

	for i = 0, carried:size() - 1
	do
		consider(carried:get(i), 1, nil);
	end

	local ready, loading, unsure = readableNear(player, op, opts);

	for i, entry in ipairs(ready)
	do
		local items = entry.container:getItems();

		for k = 0, items:size() - 1
		do
			consider(items:get(k), entry.group, entry);
		end
	end

	if #list > 0
	then
		table.sort(list, byDrink);

		return list[1];
	end

	if #loading > 0
	then
		return nil, nil, "loading", loading;
	end

	-- nothing carried or within reach: the vicinity, walking (ANALISI-AUTONOMIA.md 3.5), the emptiest bottle of the
	-- nearest place that has one
	local function takes(item)
		return F:isSafeDrink(player, item, op);
	end

	local far, looking = farChoice(player, op, "drink", takes, function(container)
		local bottles = itemsOf(container, takes);

		table.sort(bottles, function(a, b)
			return byDrink({ group = 3, amount = a:getFluidContainer():getAmount(), id = a:getID() },
				{ group = 3, amount = b:getFluidContainer():getAmount(), id = b:getID() });
		end);

		return bottles[1];
	end);

	if far
	then
		return far;
	end

	if looking
	then
		return nil, nil, "loading", looking;
	end

	if #unsure > 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NotSeenNear", F:names(unsure)), nil, nil;
	end

	return nil, whyText(F:nearAllowed(op) and "IGUI_AutoPilot_A_MacroR_NoDrink" or "IGUI_AutoPilot_A_MacroR_NoDrinkOn"), "nothing", nil;
end

-- ============================================================================================================
-- Water sources of the world (drink(source=True), refill())
-- ============================================================================================================

local function sourceName(object)
	local sprite = object:getSprite();
	local props = sprite and sprite:getProperties();
	local name = props and props:get("CustomName");

	if name
	then
		return Translator.getMoveableDisplayName(name) or name;
	end

	return getText("ContextMenu_NaturalWaterSource");
end

-- an object the game's "Drink" of the right click offers (ISWorldObjectContextMenuLogic.doDrinkWaterMenu of 42.22: an
-- object with water, not a washer nor a dryer, a drink as its first fluid) with clean water in it; tainted: true when
-- its water is tainted (then never)
local function isSource(object)
	if instanceof(object, "IsoWorldInventoryObject") or instanceof(object, "IsoClothingWasher") or instanceof(object, "IsoClothingDryer")
	then
		return false, false;
	end

	if not object:hasWater() or object:getFluidAmount() <= 0
	then
		return false, false;
	end

	if object:isTaintedWater()
	then
		return false, true;
	end

	local fluid = object:getPrimaryFluid();

	return fluid ~= nil and fluid:isCategory(FluidCategory.Beverage), false;
end

-- The nearest source of clean water within F.sourceRadius squares on the character's floor, in the same building as
-- the character (or both outside: the game's own rule for "Drink" and "Fill"), never on a safehouse square it may not
-- use: { object, square, name, distance, items (with items: those the source can fill, ISWorldObjectContextMenuLogic.
-- doFillFluidMenu's canTransferFluidTo) }, or nil. items (optional): the bottles to fill; a source that fills none of
-- them is skipped.
function AutoPilotMoon.Macro.Food:findSource(player, items)
	local cell = getCell();
	local here = player:getCurrentSquare();

	if cell == nil or here == nil
	then
		return nil;
	end

	local building = player:getBuilding();
	local x0, y0, z = here:getX(), here:getY(), here:getZ();
	local r = F.sourceRadius;
	local best = nil;

	for x = x0 - r, x0 + r
	do
		for y = y0 - r, y0 + r
		do
			local d = (x - x0) * (x - x0) + (y - y0) * (y - y0);
			local square = (best == nil or d < best.distance) and d <= r * r and cell:getGridSquare(x, y, z) or nil;

			if square and square:getBuilding() == building and not AutoPilotMoon.Zones:isProtected(square, player)
			then
				local objects = square:getObjects();

				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);

					if object and isSource(object) and (best == nil or d < best.distance)
					then
						local fits = nil;

						if items
						then
							fits = {};

							for k, item in ipairs(items)
							do
								if object:canTransferFluidTo(item:getFluidContainer())
								then
									table.insert(fits, item);
								end
							end
						end

						if fits == nil or #fits > 0
						then
							best = { object = object, square = square, name = sourceName(object), distance = d, items = fits };
						end
					end
				end
			end
		end
	end

	return best;
end

-- a bottle refill() fills: carried (bags too), never a favourite, held or worn one, of the types named (without a
-- name only what is small enough to drink from), not sealed, empty or holding only clean water, with room for water;
-- full: the same but already full
function AutoPilotMoon.Macro.Food:fillState(player, item, op)
	local fluid = item:getFluidContainer();

	if fluid == nil or not usable(player, item) or not named(op, item) or item:isSealed()
	then
		return nil;
	end

	if op.itemTypes == nil and fluid:getCapacity() > F.maxDrinkCapacity
	then
		return nil;
	end

	if not fluid:isEmpty() and (not fluid:isPrimaryFluidType("Water") or fluid:isTainted() or fluid:isPoisonous() or fluid:isMixture())
	then
		return nil;
	end

	if fluid:isFull()
	then
		return "full";
	end

	return fluid:canAddFluid(Fluid.Water) and "fill" or nil;
end

-- the bottles to fill (a list) and how many are already full
function AutoPilotMoon.Macro.Food:fillable(player, op)
	local list, full = {}, 0;
	local carried = player:getInventory():getAllEvalRecurse(function(item)
		return item:getFluidContainer() ~= nil;
	end);

	for i = 0, carried:size() - 1
	do
		local item = carried:get(i);
		local state = F:fillState(player, item, op);

		if state == "fill"
		then
			table.insert(list, item);
		elseif state == "full"
		then
			full = full + 1;
		end
	end

	table.sort(list, function(a, b)
		return a:getID() < b:getID();
	end);

	return list, full;
end
