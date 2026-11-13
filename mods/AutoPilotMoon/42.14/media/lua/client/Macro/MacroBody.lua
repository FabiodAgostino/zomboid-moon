-- AutoPilot (Moon): automations for the Moon server.

-- The body's actions of the macros (step M1.5, 12/11/2026, MACRO-AUTOPILOT.md 11): exercise, rest, eat, drink, smoke,
-- each done the way the game does it by hand, through the game's own code, so the game's refusals stay and in
-- multiplayer the server does the work (every action below is a timed action of 42.22 with "complete", run by the
-- server):
--   exercise  the Fitness window: ISFitnessUI.equipItems / ISFitnessAction / ISTimedActionQueue.addGetUpAndThen, and
--             ISFitnessUI.update to give back what was in the hands; the window's refusals with its own texts
--   rest      the "Rest" of a seat's right click: ISWorldObjectContextMenu.onRest (walk, sit on the furniture, or on
--             the ground next to it); "Sit on ground" (reportEvent("EventSitOnGround")) without a seat; up again
--             ("forceGetUp") when the endurance is back
--   eat       the inventory's "Eat > All": ISInventoryPaneContextMenu.eatItem (and "Open and Eat" for a can)
--   drink     the inventory's "Drink": ISInventoryPaneContextMenu.onDrinkFluid
--   smoke     the inventory's "Smoke": eatItem for a cigarette, takePill for a pack; a fire as the menu asks for it
-- Every action counts only when the character shows it (stats, the item gone, sitting), within a timeout.
--
-- Body:start(run, op) -> pending, or nil + reason text + "nothing" (nothing to eat / drink / smoke: a "while
--   possible" ends well) / "skip" (nothing to do: already rested) / nil (a refusal: the macro stops)
-- Body:confirm(run, pending) -> "busy" / "done" / "fail", text   (only with the character idle)
-- Body:probe(player, op) -> nil (it can be done now) or the reason's text ("Adesso si puo' fare?")

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Body = AutoPilotMoon.Macro.Body or {};

local Body = AutoPilotMoon.Macro.Body;

Body.seatRadius = 8;            -- the nearest seat within this many squares (same floor)
Body.sitTimeoutMs = 20000;      -- idle and still not sitting after this: the macro stops
Body.restMaxMs = 600000;        -- at most 10 real minutes on a seat, then up again (the endurance may not come back)
Body.standTimeoutMs = 4000;
Body.confirmMs = 3000;          -- no effect after this, idle: the macro stops
Body.canConfirmMs = 8000;       -- "Open and Eat": the server queues the eating after the can is open
Body.maxDrinkCapacity = 3.0;    -- the game's "Too big to drink from" (ISInventoryPaneContextMenu.doDrinkFluidMenu)
Body.notPerishable = 100000000; -- getOffAgeMax of the food that never spoils

local function now()
	return getTimestampMs();
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

local function moodle(player, name)
	return AutoPilotMoon.Macro.Run:moodleLevel(player, name);
end

local function sitting(player)
	return player:isSitOnGround() or player:isSittingOnFurniture();
end

-- ============================================================================================================
-- Texts
-- ============================================================================================================

function AutoPilotMoon.Macro.Body:describe(op)
	if op.kind == "exercise"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroExercise", op.exercise, op.minutes);
	elseif op.kind == "rest"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroRest", op.untilPct);
	elseif op.kind == "eat"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroEat");
	elseif op.kind == "drink"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroDrink");
	elseif op.kind == "read"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroRead", op.itemText or "");
	end

	return getText("IGUI_AutoPilot_P_Now_MacroSmoke");
end

-- the skills an action trains (the panel's experience): an exercise trains Fitness and Strength (Fitness.incStats)
function AutoPilotMoon.Macro.Body:xpPerks(op)
	if op.kind ~= "exercise"
	then
		return {};
	end

	local list = {};

	for i, id in ipairs({ "Fitness", "Strength" })
	do
		local perk = AutoPilotMoon.Macro.Names:resolveSkill(id);

		if perk
		then
			table.insert(list, perk);
		end
	end

	return list;
end

local function xpSum(player, op)
	local total = 0;

	for i, perk in ipairs(Body:xpPerks(op))
	do
		total = total + player:getXp():getXP(perk);
	end

	return total;
end

-- ============================================================================================================
-- Exercise (ISFitnessUI / ISFitnessAction of 42.22)
-- ============================================================================================================

local function exerciseData(op)
	local table_ = FitnessExercises and FitnessExercises.exercisesType;

	return table_ and table_[op.exercise] or nil;
end

-- the Fitness window's refusals (ISFitnessUI:updateButtons), with its own texts; nil: it can start
local function exerciseRefusal(player, op, data)
	if data == nil
	then
		return getText("IGUI_AutoPilot_A_MacroR_NoExercise", op.exercise);
	end

	local threshold = ISFitnessUI and ISFitnessUI.enduranceLevelThreshold or 2;

	if moodle(player, "ENDURANCE") > threshold
	then
		return getText("Tooltip_TooExhaustedFitness");
	end

	if moodle(player, "HEAVY_LOAD") > 2
	then
		return getText("Tooltip_TooHeavyFitness");
	end

	if player:getVariableBoolean("sitonground") or sitting(player)
	then
		return getText("Tooltip_StandStillFitness");
	end

	if moodle(player, "PAIN") > 3
	then
		return getText("Tooltip_TooMuchPainFitness");
	end

	if data.item and not player:getInventory():contains(data.item, true)
	then
		return getText("IGUI_AutoPilot_A_MacroR_NeedEquipment", AutoPilotMoon.Macro.Names:itemName(data.item));
	end

	return nil;
end

local function startExercise(run, op)
	local player = run.player;
	local data = exerciseData(op);
	local refusal = exerciseRefusal(player, op, data);

	if refusal
	then
		return nil, refusal, nil;
	end

	-- the window's own steps, with a table in its place: the same fields its methods read
	player:getFitness():init();

	local ui = { player = player, exeData = data, itemsToReequip = {} };

	if not ISFitnessUI.equipItems(ui)
	then
		return nil, getText("IGUI_AutoPilot_A_MacroR_NeedEquipment", AutoPilotMoon.Macro.Names:itemName(data.item)), nil;
	end

	local action = ISFitnessAction:new(player, op.exercise, op.minutes, data, data.type);

	action.autopilotMacro = true;
	ui.currentExercice = data.type;
	ISTimedActionQueue.addGetUpAndThen(player, action);
	run.reequip = ui;

	return { kind = "exercise", xp0 = xpSum(player, op), endurance0 = stat(player, "ENDURANCE") };
end

-- the hands' items back once the exercise is over (ISFitnessUI:update does it when getCurrentExe() is nil)
function AutoPilotMoon.Macro.Body:reequip(run)
	local ui = run.reequip;

	if ISTimedActionQueue.isPlayerDoingAction(run.player)
	then
		return;
	end

	pcall(ISFitnessUI.update, ui);

	if ui.currentExercice == nil
	then
		run.reequip = nil;
	end
end

local function confirmExercise(run, pending, waited)
	local player = run.player;

	if xpSum(player, pending.op) > pending.xp0 + 0.0001 or stat(player, "ENDURANCE") < pending.endurance0 - 0.0001
	then
		return "done";
	end

	if waited < Body.confirmMs
	then
		return "busy";
	end

	return "fail", getText("IGUI_AutoPilot_A_MacroR_ExerciseNoEffect", pending.op.exercise);
end

-- ============================================================================================================
-- Rest (the "Rest" of a seat, "Sit on ground")
-- ============================================================================================================

-- a seat as the game's right click offers "Rest" on it (ISWorldObjectContextMenuLogic.doBedMenu of 42.22): a
-- furniture with the "bed" flag (beds, sofas, armchairs, chairs, benches), not taken, in the same room or in sight
function AutoPilotMoon.Macro.Body:isSeat(object, player)
	local sprite = object and object:getSprite();
	local props = sprite and sprite:getProperties();

	if props == nil or not props:has(IsoFlagType.bed)
	then
		return false;
	end

	if object:isFurnitureOccupied(player)
	then
		return false;
	end

	local square = object:getSquare();
	local here = player:getSquare();

	return square ~= nil and here ~= nil and (square:getRoom() == here:getRoom() or square:isCanSee(player:getPlayerNum()));
end

-- the nearest seat within Body.seatRadius squares on the character's floor, or nil
function AutoPilotMoon.Macro.Body:findSeat(player)
	local cell = getCell();
	local here = player:getSquare();

	if cell == nil or here == nil
	then
		return nil;
	end

	local x0, y0, z = here:getX(), here:getY(), here:getZ();
	local best, bestDistance = nil, nil;
	local r = Body.seatRadius;

	for x = x0 - r, x0 + r
	do
		for y = y0 - r, y0 + r
		do
			local square = cell:getGridSquare(x, y, z);
			local objects = square and square:getObjects();

			if objects
			then
				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);
					local d = (x - x0) * (x - x0) + (y - y0) * (y - y0);

					if (bestDistance == nil or d < bestDistance) and d <= r * r and Body:isSeat(object, player)
					then
						best, bestDistance = object, d;
					end
				end
			end
		end
	end

	return best;
end

local function startRest(run, op)
	local player = run.player;

	if AutoPilotMoon.Rest:getEndurancePercent(player) >= op.untilPct and not sitting(player)
	then
		return nil, nil, "skip";
	end

	local pending = { kind = "rest", phase = "sitting", since = now() };

	if sitting(player)
	then
		pending.phase = "resting";
	elseif op.seat == "nearest"
	then
		local seat = Body:findSeat(player);

		if seat
		then
			pending.seat = seat;
			ISWorldObjectContextMenu.onRest(seat, player:getPlayerNum());
		else
			AutoPilotMoon:say("info", getText("IGUI_AutoPilot_A_MacroR_NoSeat", Body.seatRadius), player);
			player:reportEvent("EventSitOnGround");
		end
	else
		player:reportEvent("EventSitOnGround");
	end

	run.resting = pending;

	return pending;
end

local function confirmRest(run, pending, waited)
	local player = run.player;
	local time = now();

	if pending.phase == "sitting"
	then
		if sitting(player)
		then
			pending.phase = "resting";
			pending.since = time;
		elseif waited > Body.sitTimeoutMs
		then
			run.resting = nil;

			return "fail", getText("IGUI_AutoPilot_A_MacroR_CannotSit");
		end

		return "busy";
	end

	if pending.phase == "resting"
	then
		local percent = AutoPilotMoon.Rest:getEndurancePercent(player);

		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroResting", percent, pending.op.untilPct);

		if percent >= pending.op.untilPct or time - pending.since > Body.restMaxMs or not sitting(player)
		then
			if sitting(player)
			then
				player:setVariable("forceGetUp", true);
			end

			pending.phase = "standing";
			pending.since = time;
		end

		return "busy";
	end

	if not sitting(player) or time - pending.since > Body.standTimeoutMs
	then
		run.resting = nil;

		return "done";
	end

	return "busy";
end

-- the macro stopped while resting: up again, as the engine's own rest does (not a dead character)
function AutoPilotMoon.Macro.Body:onStop(run)
	local player = run.player;

	if run.resting and player and not player:isDead() and sitting(player)
	then
		player:setVariable("forceGetUp", true);
	end

	run.resting = nil;
end

-- ============================================================================================================
-- Eat, drink, smoke: the item chosen in the inventory (bags included), never a favourite, an equipped or a worn one
-- ============================================================================================================

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

-- the items of the inventory (bags included) a test accepts, as a Lua list
local function itemsWhere(player, test)
	local found = player:getInventory():getAllEvalRecurse(function(item)
		return test(item) == true;
	end);
	local list = {};

	for i = 0, found:size() - 1
	do
		table.insert(list, found:get(i));
	end

	return list;
end

-- a food that is safe to eat now (11.5): never rotten, poisonous, dangerous raw, burnt, frozen, alcoholic, a spice,
-- something to smoke, or a closed can; something that feeds
function AutoPilotMoon.Macro.Body:isSafeFood(item)
	if not instanceof(item, "Food") or item:getHungChange() >= 0
	then
		return false;
	end

	if item:isRotten() or item:isPoison() or item:getPoisonPower() > 0 or item:isBurnt() or item:isFrozen()
		or item:isAlcoholic() or item:isSpice() or item:getRequireInHandOrInventory() ~= nil
	then
		return false;
	end

	if item:isbDangerousUncooked() and not item:isCooked()
	then
		return false;
	end

	local script = item:getScriptItem();

	return not (script and script:isCantEat());
end

-- a closed can the game opens with its "Open and Eat" (the item's opening recipe), and that recipe
local function openingRecipe(player, item)
	local name = item:getOpeningRecipe();
	local recipe = name and getScriptManager():getCraftRecipe(name) or nil;

	if recipe == nil
	then
		return nil;
	end

	if AutoPilotMoon.Craft:check(player, recipe, item) ~= nil
	then
		return nil, recipe;
	end

	return recipe;
end

local function isClosedCan(item)
	if not instanceof(item, "Food") or item:getOpeningRecipe() == nil
	then
		return false;
	end

	local script = item:getScriptItem();

	return script ~= nil and script:isCantEat() and not item:isRotten() and not item:isPoison();
end

-- the days before it spoils (what spoils first is eaten first); never spoiling: last
local function daysLeft(item)
	local max = item:getOffAgeMax();

	if max == nil or max >= Body.notPerishable
	then
		return Body.notPerishable;
	end

	return max - item:getAge();
end

local function byFreshness(a, b)
	local da, db = daysLeft(a), daysLeft(b);

	if da ~= db
	then
		return da < db;
	end

	-- the smaller meal first: less waste when only a little hungry
	return a:getHungChange() > b:getHungChange();
end

-- what eat() would eat: the item and its opening recipe (a can), or nil and the reason ("nothing" or a refusal)
function AutoPilotMoon.Macro.Body:chooseFood(player, op)
	if moodle(player, "FOOD_EATEN") >= 3
	then
		return nil, nil, getText("Tooltip_CantEatMore"), nil;
	end

	local foods = itemsWhere(player, function(item)
		return usable(player, item) and named(op, item) and Body:isSafeFood(item);
	end);

	if #foods > 0
	then
		table.sort(foods, byFreshness);

		return foods[1], nil;
	end

	local cans = itemsWhere(player, function(item)
		return usable(player, item) and named(op, item) and isClosedCan(item);
	end);

	if #cans == 0
	then
		return nil, nil, getText("IGUI_AutoPilot_A_MacroR_NoFood"), "nothing";
	end

	if not op.openCans
	then
		return nil, nil, getText("IGUI_AutoPilot_A_MacroR_CansClosed"), "nothing";
	end

	table.sort(cans, byFreshness);

	for i, can in ipairs(cans)
	do
		local recipe = openingRecipe(player, can);

		if recipe
		then
			return can, recipe;
		end
	end

	return nil, nil, getText("IGUI_AutoPilot_A_MacroR_NoCanOpener"), "nothing";
end

local function startEat(run, op)
	local player = run.player;
	local item, recipe, why, kind = Body:chooseFood(player, op);

	if item == nil
	then
		return nil, why, kind;
	end

	local pending = { kind = "eat", item = item, itemId = item:getID(), name = item:getDisplayName(), hunger0 = stat(player, "HUNGER"), can = recipe ~= nil };

	if recipe
	then
		ISInventoryPaneContextMenu.eatItem(item, 1, player:getPlayerNum(), recipe, 100);
	else
		ISInventoryPaneContextMenu.eatItem(item, 1, player:getPlayerNum());
	end

	return pending;
end

local function gone(player, pending)
	return player:getInventory():getItemWithIDRecursiv(pending.itemId) == nil;
end

local function confirmEat(run, pending, waited)
	local player = run.player;

	if stat(player, "HUNGER") < pending.hunger0 - 0.0001 or (not pending.can and gone(player, pending))
	then
		return "done";
	end

	if waited < (pending.can and Body.canConfirmMs or Body.confirmMs)
	then
		return "busy";
	end

	return "fail", getText("IGUI_AutoPilot_A_MacroR_NotEaten", pending.name);
end

-- a drink that is safe (11.5): not empty, small enough for the game, not poisonous nor tainted, not sealed; without a
-- name only water (a named one may be anything else safe, alcohol included: the player chose it)
function AutoPilotMoon.Macro.Body:isSafeDrink(item, op)
	local fluid = item:getFluidContainer();

	if fluid == nil or fluid:isEmpty() or fluid:getCapacity() > Body.maxDrinkCapacity or item:isSealed()
	then
		return false;
	end

	if fluid:isPoisonous() or fluid:isTainted()
	then
		return false;
	end

	if op.itemTypes == nil
	then
		return fluid:isPrimaryFluidType("Water");
	end

	return true;
end

local function byAmount(a, b)
	return a:getFluidContainer():getAmount() < b:getFluidContainer():getAmount();
end

function AutoPilotMoon.Macro.Body:chooseDrink(player, op)
	local drinks = itemsWhere(player, function(item)
		return usable(player, item) and named(op, item) and Body:isSafeDrink(item, op);
	end);

	if #drinks == 0
	then
		return nil, getText("IGUI_AutoPilot_A_MacroR_NoDrink"), "nothing";
	end

	-- the emptiest container first (one bottle finished before the next is opened)
	table.sort(drinks, byAmount);

	return drinks[1];
end

local function startDrink(run, op)
	local player = run.player;
	local item, why, kind = Body:chooseDrink(player, op);

	if item == nil
	then
		return nil, why, kind;
	end

	local pending = { kind = "drink", item = item, name = item:getDisplayName(), thirst0 = stat(player, "THIRST"), amount0 = item:getFluidContainer():getAmount() };

	ISInventoryPaneContextMenu.onDrinkFluid(item, op.amount, player, nil, item);

	return pending;
end

local function confirmDrink(run, pending, waited)
	local player = run.player;
	local fluid = pending.item:getFluidContainer();

	if stat(player, "THIRST") < pending.thirst0 - 0.0001 or (fluid and fluid:getAmount() < pending.amount0 - 0.0001)
	then
		return "done";
	end

	if waited < Body.confirmMs
	then
		return "busy";
	end

	return "fail", getText("IGUI_AutoPilot_A_MacroR_NotDrunk", pending.name);
end

-- a drainable with something left (the game keeps its own copy of this local in every file that needs it)
local function predicateNotEmpty(item)
	return item:getCurrentUsesFloat() > 0;
end

-- the fire a smoke needs, as the "Smoke" option checks it (ISInventoryPaneContextMenu.doEatOption): an open flame
-- nearby, or one of the item's required types (lighter, matches...) not empty; nil, and the names when there is none
local function hasFire(player, item)
	if ISInventoryPaneContextMenu.hasOpenFlame(player)
	then
		return true;
	end

	local list = item:getRequireInHandOrInventory();

	if list == nil
	then
		return true;
	end

	local names = {};

	for i = 0, list:size() - 1
	do
		local fullType = moduleDotType(item:getModule(), list:get(i));

		if player:getInventory():getFirstTypeEvalRecurse(fullType, predicateNotEmpty)
		then
			return true;
		end

		table.insert(names, getItemNameFromFullType(fullType));
	end

	return false, table.concat(names, "/");
end

local function isSmokable(item)
	return item:hasTag(ItemTag.SMOKABLE) and (instanceof(item, "Food") or instanceof(item, "DrainableComboItem"));
end

-- a single cigarette before a pack (by hand the loose ones go first), then the one with fewer uses left
local function bySmoke(a, b)
	local pa, pb = instanceof(a, "DrainableComboItem"), instanceof(b, "DrainableComboItem");

	if pa ~= pb
	then
		return pb;
	end

	return false;
end

function AutoPilotMoon.Macro.Body:chooseSmoke(player, op)
	local items = itemsWhere(player, function(item)
		return usable(player, item) and named(op, item) and isSmokable(item);
	end);

	if #items == 0
	then
		return nil, getText("IGUI_AutoPilot_A_MacroR_NoSmoke"), "nothing";
	end

	table.sort(items, bySmoke);

	local missing = nil;

	for i, item in ipairs(items)
	do
		local ok, names = hasFire(player, item);

		if ok
		then
			return item;
		end

		missing = missing or names;
	end

	return nil, getText("ContextMenu_Require", missing or ""), nil;
end

local function uses(item)
	if instanceof(item, "DrainableComboItem")
	then
		return item:getCurrentUsesFloat();
	end

	return 1;
end

local function startSmoke(run, op)
	local player = run.player;
	local item, why, kind = Body:chooseSmoke(player, op);

	if item == nil
	then
		return nil, why, kind;
	end

	local pending = { kind = "smoke", item = item, itemId = item:getID(), name = item:getDisplayName(), uses0 = uses(item), stress0 = stat(player, "STRESS") };

	if instanceof(item, "DrainableComboItem")
	then
		ISInventoryPaneContextMenu.takePill(item, player:getPlayerNum());
	else
		ISInventoryPaneContextMenu.eatItem(item, 1, player:getPlayerNum());
	end

	return pending;
end

local function confirmSmoke(run, pending, waited)
	local player = run.player;

	if gone(player, pending) or uses(pending.item) < pending.uses0 - 0.0001 or stat(player, "STRESS") < pending.stress0 - 0.0001
	then
		return "done";
	end

	if waited < Body.confirmMs
	then
		return "busy";
	end

	return "fail", getText("IGUI_AutoPilot_A_MacroR_NotSmoked", pending.name);
end

-- ============================================================================================================
-- Read (wave 0, 13/11/2026, ANALISI-API-MACRO-LAVORATIVE.md A0.4): a book or a magazine as the inventory's "Read"
-- (ISInventoryPaneContextMenu.readItem of 42.22: the book moved into the main inventory when it is in a bag, the
-- ISReadABook the server runs, the book put back), with the menu's own refusals and texts
-- (ISInventoryPaneContextMenu.doLiteratureMenu): too dark, illiterate, too complicated, too simple, nothing to read
-- ============================================================================================================

local function skillBookOf(book)
	local books = rawget(_G, "SkillBook");
	local entry = books and books[book:getSkillTrained()] or nil;

	return entry and entry.perk and entry or nil;
end

-- the pages read of a book: the most of the item's and the character's (ISReadABook keeps both: the item's on the
-- server's side, synced; the character's map is the one a new reading starts from)
local function pagesRead(player, book)
	return math.max(book:getAlreadyReadPages() or 0, player:getAlreadyReadPages(book:getFullType()) or 0);
end

local function literatureTitle(book)
	return book:hasModData() and book:getModData().literatureTitle or nil;
end

-- already read: every page of a book with pages; a magazine whose recipes the character got (getAlreadyReadBook); a
-- story already read (isLiteratureRead). Reading it again gives nothing.
function AutoPilotMoon.Macro.Body:isRead(player, book)
	local pages = book:getNumberOfPages();

	if pages > 0
	then
		return pagesRead(player, book) >= pages;
	end

	local recipes = book:getLearnedRecipes();

	if recipes and not recipes:isEmpty()
	then
		return player:getAlreadyReadBook():contains(book:getFullType());
	end

	local title = literatureTitle(book);

	return title ~= nil and player:isLiteratureRead(title);
end

-- the game's refusal of "Read" for this book now, with its own text; nil: it can be read
function AutoPilotMoon.Macro.Body:readRefusal(player, book)
	local picture = book:hasTag(ItemTag.PICTUREBOOK) or book:hasTag(ItemTag.PICTURE);

	if player:tooDarkToRead()
	then
		return getText(picture and "ContextMenu_TooDarkToSee" or "ContextMenu_TooDark");
	end

	if player:hasTrait(CharacterTrait.ILLITERATE) and not picture
	then
		return getText("ContextMenu_Illiterate");
	end

	local skill = skillBookOf(book);

	if skill and book:getLvlSkillTrained() ~= -1 and book:getLvlSkillTrained() > player:getPerkLevel(skill.perk) + 1
	then
		return getText("ContextMenu_TooComplicated");
	end

	if skill and book:getMaxLevelTrained() ~= -1 and book:getMaxLevelTrained() <= player:getPerkLevel(skill.perk)
	then
		return getText("ContextMenu_TooSimple");
	end

	if book:hasTag(ItemTag.UNINTERESTING)
	then
		return getText("ContextMenu_EmptyNotebook");
	end

	return nil;
end

-- the book read() would read: the first of the named types in the inventory (bags included, favourites too: reading
-- uses nothing up) that is something to read; nil and the reason, "nothing" when there is none
function AutoPilotMoon.Macro.Body:chooseBook(player, op)
	local books = itemsWhere(player, function(item)
		return named(op, item) and instanceof(item, "Literature");
	end);

	if #books == 0
	then
		return nil, getText("IGUI_AutoPilot_A_MacroR_NoBook", op.itemText or ""), "nothing";
	end

	-- one not read yet first (two copies of a magazine: the one still to read)
	for i, book in ipairs(books)
	do
		if not Body:isRead(player, book)
		then
			return book;
		end
	end

	return books[1];
end

local function readState(player, book)
	local title = literatureTitle(book);

	return {
		pages = pagesRead(player, book),
		readBook = player:getAlreadyReadBook():contains(book:getFullType()),
		literature = title ~= nil and player:isLiteratureRead(title),
		boredom = stat(player, "BOREDOM"),
		unhappiness = stat(player, "UNHAPPINESS"),
	};
end

local function startRead(run, op)
	local player = run.player;
	local book, why, kind = Body:chooseBook(player, op);

	if book == nil
	then
		return nil, why, kind;
	end

	if Body:isRead(player, book)
	then
		-- nothing left to read: a "while possible" ends well, else the line after (like rest() already rested)
		if op.possibleFirst
		then
			return nil, getText("IGUI_AutoPilot_A_MacroR_AlreadyRead", book:getDisplayName()), "nothing";
		end

		AutoPilotMoon:say("info", getText("IGUI_AutoPilot_A_MacroR_AlreadyReadNext", book:getDisplayName()), player);

		return nil, nil, "skip";
	end

	local refusal = Body:readRefusal(player, book);

	if refusal
	then
		return nil, refusal, nil;
	end

	ISInventoryPaneContextMenu.readItem(book, player:getPlayerNum());

	-- after the game's own ISReadABook:new (its getDuration sets the item's pages from the character's)
	local state = readState(player, book);

	state.kind = "read";
	state.book = book;
	state.name = book:getDisplayName();
	state.numberOfPages = book:getNumberOfPages();

	return state;
end

-- counted when the character read something: more pages (or the whole book), a magazine's recipes, a story read, less
-- boredom or sadness (a comic without pages)
local function confirmRead(run, pending, waited)
	local player = run.player;
	local now = readState(player, pending.book);

	if now.pages > pending.pages or (pending.numberOfPages > 0 and now.pages >= pending.numberOfPages)
		or (now.readBook and not pending.readBook) or (now.literature and not pending.literature)
		or now.boredom < pending.boredom - 0.0001 or now.unhappiness < pending.unhappiness - 0.0001
	then
		return "done";
	end

	if waited < Body.confirmMs
	then
		return "busy";
	end

	return "fail", getText("IGUI_AutoPilot_A_MacroR_NotRead", pending.name);
end

-- "Adesso si puo' fare?" for read(): nil when it can start now
local function probeRead(player, op)
	local book, why = Body:chooseBook(player, op);

	if book == nil
	then
		return why;
	end

	if Body:isRead(player, book)
	then
		return getText("IGUI_AutoPilot_A_MacroR_AlreadyRead", book:getDisplayName());
	end

	return Body:readRefusal(player, book);
end

-- ============================================================================================================
-- The interface for MacroRun
-- ============================================================================================================

local starts = { exercise = startExercise, rest = startRest, eat = startEat, drink = startDrink, smoke = startSmoke, read = startRead };
local confirms = { exercise = confirmExercise, rest = confirmRest, eat = confirmEat, drink = confirmDrink, smoke = confirmSmoke,
	read = confirmRead };

function AutoPilotMoon.Macro.Body:start(run, op)
	local pending, why, kind = starts[op.kind](run, op);

	if pending
	then
		pending.op = op;
	end

	return pending, why, kind;
end

function AutoPilotMoon.Macro.Body:confirm(run, pending)
	local waited = AutoPilotMoon.Macro.Run:idleFor(pending);
	local answer, text = confirms[pending.kind](run, pending, waited);

	if answer == "busy" and pending.kind ~= "rest" and waited >= AutoPilotMoon.Macro.Run.waitingAfterMs
	then
		AutoPilotMoon.Progress:setWaiting(true);
	end

	return answer, text;
end

-- "Adesso si puo' fare?": nil when the action can start now, else why (nothing is queued)
function AutoPilotMoon.Macro.Body:probe(player, op)
	if op.kind == "exercise"
	then
		return exerciseRefusal(player, op, exerciseData(op));
	elseif op.kind == "rest"
	then
		return nil;
	elseif op.kind == "eat"
	then
		local item, recipe, why = Body:chooseFood(player, op);

		return item == nil and why or nil;
	elseif op.kind == "drink"
	then
		local item, why = Body:chooseDrink(player, op);

		return item == nil and why or nil;
	elseif op.kind == "read"
	then
		return probeRead(player, op);
	end

	local item, why = Body:chooseSmoke(player, op);

	return item == nil and why or nil;
end
