-- AutoPilot (Moon): automations for the Moon server.

-- have_fun() and has_fun() of the macros (26/11/2026, ANALISI-AUTONOMIA.md 3.4, contract C5 of section 5): one source
-- of fun a line, first a reading not read yet (carried, within reach, within 8 squares: MacroNear.lua), then a snack
-- that cheers up; what was used is remembered for the whole run (run.funUsed) and never chosen again.
--
-- Fun:choose(player, op, run)    { kind = "read" / "snack", item, from, far } (from: a container within reach, as
--                                MacroFood.lua lists them; far: an entry of Near, walk there first), or nil, the
--                                reason's text (whyText) and the kind ("nothing": nothing to use, a "while possible"
--                                ends well)
-- Fun:has(player, op, run)       true / false: have_fun() would find something now (the condition has_fun()); it
--                                never walks, never opens a container, never remembers a reason
-- Fun:isFunReading(item)         a reading that cheers up as the game reads it
-- Fun:isUnread(player, item)     not read lately, as the game's "Read" / "Re-read" menu says it
-- have_fun is a body action of MacroBody.lua, registered here (Body:register, contract C2).
--
-- What cheers up in 42.22 (verified in the jar and the Lua of the game):
--   a reading: ISReadABook:complete -> IsoGameCharacter.ReadLiterature (stress + Literature.getStressChange) ->
--     BodyDamage.JustReadSomething (boredom + getBoredomChange, unhappiness + getUnhappyChange), all at the end, only
--     when the title was not read lately (ISReadABook:perform keeps isLiteratureRead before addReadLiterature;
--     IsoGameCharacter.isLiteratureRead: within SandboxOptions.literatureCooldown days) and never for a skill book. The
--     three getters answer 0 for an item whose alreadyRead is set. Novels -50 / -40 / -0.40, comics -30 / -20 / -0.20,
--     magazines -20 / 0 / -0.15 (the 42.21 scripts). Never a skill book (SkillBook[getSkillTrained()]), a newspaper or a
--     flyer (modData.printMedia), an UNINTERESTING item (an empty notebook, a newspaper read).
--   a snack: ISEatFoodAction -> BodyDamage.JustAteFood: boredom + getBoredomChange x part, unhappiness + getUnhappyChange
--     x part (0-100, as the moodles). Only what eat() would eat (MacroFood's foodVerdict: never rotten, raw to cook,
--     frozen, a known poison, very unpleasant...), whole, and never when the game refuses to eat more (the "Eat" of the
--     inventory: FOOD_EATEN at 3).
-- The game's refusals of "Read" stay: too dark (player:tooDarkToRead(): a snack is still fine), illiterate but for the
-- pictures (PICTUREBOOK, PICTURE); the start asks MacroBody's readRefusal once more.
--
-- The order (decision DA4): only what has an effect; the readings first, then the food. Among the readings the one that
-- takes away the most of the moodle shown (sad: unhappiness; else bored: boredom; else stressed: stress; nothing shown:
-- boredom), then carried, within reach, the nearest, then the shorter (fewer pages). Among the snacks the smallest
-- (least hunger) of those that take the moodle away (the game's level-1 threshold, Lang.stateNumbers), else the one
-- that takes away the most; then carried, within reach, the nearest.
-- Done when the game shows it: the title read, more pages, less boredom / unhappiness / stress, or the game performed
-- the reading (a reading the server pays nothing for is still done: run.funUsed keeps it from being chosen again); the
-- snack: less hunger, boredom or unhappiness, or used up once the meal was performed.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Fun = AutoPilotMoon.Macro.Fun or {};

local Fun = AutoPilotMoon.Macro.Fun;

-- the kinds of source, in their order (3.9: a source added later is a kind more, the language does not change)
Fun.sources = { "read", "snack" };
Fun.fullLevel = 3;             -- the game's "Eat" refuses from this level of FOOD_EATEN (ISInventoryPaneContextMenu)

-- the text of why nothing is found, its key remembered for the notifications (the code of the stop that follows)
local function whyText(key, a, b, c)
	return AutoPilotMoon.Notify:why(key, a, b, c);
end

local function Body()
	return AutoPilotMoon.Macro.Body;
end

local function Food()
	return AutoPilotMoon.Macro.Food;
end

local function Near()
	return AutoPilotMoon.Macro.Near;
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

local function modData(item)
	return item:hasModData() and item:getModData() or nil;
end

local function titleOf(item)
	local data = modData(item);

	return data and data.literatureTitle or nil;
end

local function picture(item)
	return item:hasTag(ItemTag.PICTUREBOOK) or item:hasTag(ItemTag.PICTURE);
end

-- ============================================================================================================
-- What counts
-- ============================================================================================================

-- a reading that cheers up as the game reads it: Literature, not UNINTERESTING, not a skill book, not a newspaper or a
-- flyer (modData.printMedia), with less boredom, unhappiness or stress
function AutoPilotMoon.Macro.Fun:isFunReading(item)
	if not item:IsLiterature() or item:hasTag(ItemTag.UNINTERESTING)
	then
		return false;
	end

	local books = rawget(_G, "SkillBook");

	if books and books[item:getSkillTrained()] ~= nil
	then
		return false;
	end

	local data = modData(item);

	if data and data.printMedia ~= nil
	then
		return false;
	end

	return item:getBoredomChange() < 0 or item:getUnhappyChange() < 0 or item:getStressChange() < 0;
end

-- not read lately: the game's "Read" (and not "Re-read") of ISInventoryPaneContextMenu.doLiteratureMenu, the same test
-- ISReadABook makes before paying (the title, within the literature cooldown)
function AutoPilotMoon.Macro.Fun:isUnread(player, item)
	local title = titleOf(item);

	return not (title ~= nil and player:isLiteratureRead(title));
end

-- a snack that cheers up: what eat() would eat as it is (MacroFood's rules), with less boredom or unhappiness
local function isSnack(player, item, op)
	if Food():foodVerdict(player, item, op) ~= "food"
	then
		return false;
	end

	return item:getBoredomChange() < 0 or item:getUnhappyChange() < 0;
end

-- the stat the line aims at now: the moodle the game shows (sad, then bored, then stressed), boredom when none
local function goalOf(player)
	if moodle(player, "UNHAPPY") >= 1
	then
		return "unhappy";
	elseif moodle(player, "BORED") >= 1
	then
		return "boredom";
	elseif moodle(player, "STRESS") >= 1
	then
		return "stress";
	end

	return "boredom";
end

-- how much of the goal an item takes away (0: nothing)
local function dropOf(item, goal)
	local change = 0;

	if goal == "unhappy"
	then
		change = item:getUnhappyChange();
	elseif goal == "stress"
	then
		change = item:getStressChange();
	else
		change = item:getBoredomChange();
	end

	return change < 0 and -change or 0;
end

-- how much of the goal must go for the moodle to go (the game's level-1 threshold, Lang.stateNumbers); nil: no number
-- (stress: the snacks are ranked by what they take away)
local function neededOf(player, goal)
	local word = (goal == "unhappy" and "sad") or (goal == "boredom" and "bored") or nil;
	local numbers = word and AutoPilotMoon.Macro.Lang.stateNumbers[word] or nil;

	if numbers == nil or numbers.at == nil
	then
		return nil;
	end

	return stat(player, goal == "unhappy" and "UNHAPPINESS" or "BOREDOM") - numbers.at[1];
end

-- ============================================================================================================
-- Where: carried, within reach (MacroFood's loot window), within 8 squares (MacroNear, contract C4)
-- ============================================================================================================

-- every item of the three circles once: fn(item, circle, entry, distance); circle 1 carried (entry nil), 2-3 within
-- reach (MacroFood's group: 3 a part of a car; entry { container, group, name }), 4 within Near.radius (an entry of
-- Near: a container already known, or an item on the floor). A container whose contents have not arrived is never
-- looked into here: a condition does not open, have_fun() does not go and look (only eat() and drink() do, 3.5).
local function eachItem(player, op, fn)
	local seen = {};

	local function consider(item, circle, entry, distance)
		if item == nil
		then
			return;
		end

		local id = item:getID();

		if seen[id]
		then
			return;
		end

		seen[id] = true;
		fn(item, circle, entry, distance or 0);
	end

	local carried = player:getInventory():getAllEvalRecurse(function(item)
		return item:IsLiterature() or instanceof(item, "Food");
	end);

	for i = 0, carried:size() - 1
	do
		consider(carried:get(i), 1, nil, 0);
	end

	if Food():nearAllowed(op)
	then
		for i, entry in ipairs(Food():nearContainers(player))
		do
			if AutoPilotMoon.Wait:loadState(entry.container) == "loaded"
			then
				local items = entry.container:getItems();

				for k = 0, items:size() - 1
				do
					consider(items:get(k), entry.group or 2, entry, 0);
				end
			end
		end
	end

	if Near():allowed(op)
	then
		for i, entry in ipairs(Near():containers(player) or {})
		do
			if entry.state == "loaded" and entry.container
			then
				local items = entry.container:getItems();

				for k = 0, items:size() - 1
				do
					consider(items:get(k), 4, entry, entry.distance);
				end
			end
		end

		for i, entry in ipairs(Near():floorItems(player) or {})
		do
			consider(entry.item, 4, entry, entry.distance);
		end
	end
end

-- ============================================================================================================
-- The choice
-- ============================================================================================================

local function betterRead(a, b)
	if a.drop ~= b.drop
	then
		return a.drop > b.drop;
	end

	if a.circle ~= b.circle
	then
		return a.circle < b.circle;
	end

	if a.distance ~= b.distance
	then
		return a.distance < b.distance;
	end

	if a.pages ~= b.pages
	then
		return a.pages < b.pages;
	end

	return a.id < b.id;
end

local function betterSnack(a, b)
	if a.enough ~= b.enough
	then
		return a.enough;
	end

	if a.enough
	then
		if a.hunger ~= b.hunger
		then
			return a.hunger < b.hunger;
		end
	elseif a.drop ~= b.drop
	then
		return a.drop > b.drop;
	end

	if a.circle ~= b.circle
	then
		return a.circle < b.circle;
	end

	if a.distance ~= b.distance
	then
		return a.distance < b.distance;
	end

	if a.hunger ~= b.hunger
	then
		return a.hunger < b.hunger;
	end

	return a.id < b.id;
end

-- every source have_fun() could use now, in order, and what was left out by the game's refusals (no reason made here:
-- the condition has_fun() calls it at every pause)
local function collect(player, op, run)
	local found = { reads = {}, snacks = {}, dark = 0, illiterate = 0 };
	local goal = goalOf(player);
	local dark = player:tooDarkToRead();
	local illiterate = player:hasTrait(CharacterTrait.ILLITERATE);
	local snacks = op.snacks ~= false and moodle(player, "FOOD_EATEN") < Fun.fullLevel;
	local used = run and run.funUsed or {};
	local needed = nil;

	if snacks
	then
		needed = neededOf(player, goal);
	end

	eachItem(player, op, function(item, circle, entry, distance)
		local id = item:getID();

		if item:IsLiterature()
		then
			if used[id] or not Fun:isFunReading(item) or not Fun:isUnread(player, item)
			then
				return;
			end

			if dark
			then
				found.dark = found.dark + 1;

				return;
			end

			if illiterate and not picture(item)
			then
				found.illiterate = found.illiterate + 1;

				return;
			end

			table.insert(found.reads, { kind = "read", item = item, id = id, circle = circle, entry = entry, distance = distance,
				drop = dropOf(item, goal), pages = item:getNumberOfPages() or 0 });
		elseif snacks and instanceof(item, "Food") and isSnack(player, item, op)
		then
			local drop = dropOf(item, goal);

			table.insert(found.snacks, { kind = "snack", item = item, id = id, circle = circle, entry = entry, distance = distance,
				drop = drop, hunger = math.abs(item:getHungChange() or 0), enough = needed ~= nil and drop > 0 and drop >= needed });
		end
	end);

	table.sort(found.reads, betterRead);
	table.sort(found.snacks, betterSnack);

	return found;
end

-- the choice of a source found: within reach (from) or within 8 squares (far: the walk first). A container of the
-- vicinity comes from Near:containers without its item (only Near:find gives one): the entry gets the source, so
-- Near:approach says «va a Scaffale (Romanzo)» and not «va a guardare in Scaffale» (that one is for a container never
-- opened). The entries are made again at every call: nothing of Near's is kept.
local function choiceOf(source)
	local far = source.circle == 4;

	if far and source.entry and source.entry.item == nil
	then
		source.entry.item = source.item;
	end

	return { kind = source.kind, item = source.item, from = (not far) and source.entry or nil, far = far and source.entry or nil };
end

function AutoPilotMoon.Macro.Fun:choose(player, op, run)
	local found = collect(player, op, run);
	local best = found.reads[1] or found.snacks[1];

	if best
	then
		return choiceOf(best);
	end

	if found.dark > 0
	then
		-- only readings, and too dark to read them (a snack would do in the dark)
		return nil, whyText("IGUI_AutoPilot_A_MacroR_FunTooDark"), "nothing";
	end

	if found.illiterate > 0
	then
		return nil, whyText("ContextMenu_Illiterate"), "nothing";
	end

	return nil, whyText("IGUI_AutoPilot_A_MacroR_NoFun"), "nothing";
end

function AutoPilotMoon.Macro.Fun:has(player, op, run)
	local found = collect(player, op or {}, run);

	return #found.reads > 0 or #found.snacks > 0;
end

-- ============================================================================================================
-- The body action have_fun (MacroBody.lua's Body:register)
-- ============================================================================================================

-- the name of where a choice is: a container's, the floor's
local function placeName(entry)
	if entry == nil
	then
		return nil;
	end

	return entry.name or getTextOrNull("IGUI_ContainerTitle_floor") or "floor";
end

-- the first watched action of the game of that type (the reading among what readItem queued: the transfer from a
-- crate, the reading, the transfer back)
local function watchedOfType(wait, typeName)
	for i, action in ipairs(wait and wait.actions or {})
	do
		if action.Type == typeName
		then
			return action;
		end
	end

	return nil;
end

local function mood(player)
	return { boredom = stat(player, "BOREDOM"), unhappiness = stat(player, "UNHAPPINESS"), stress = stat(player, "STRESS"),
		hunger = stat(player, "HUNGER") };
end

-- the start: the walk to a source within 8 squares (Near:approach: the step comes again, then it is within reach), or
-- the game's "Read" / "Eat" of the inventory as by hand (the item moved in from a bag or a container within reach and
-- put back); a reading is remembered for the whole run from here (run.funUsed)
local function startFun(run, op)
	local player = run.player;
	local choice, why, kind = Fun:choose(player, op, run);

	if choice == nil
	then
		return nil, why, kind;
	end

	if choice.far
	then
		return Near():approach(run, op, choice.far);
	end

	local item = choice.item;
	local pending = { kind = "have_fun", source = choice.kind, itemId = item:getID(), name = item:getDisplayName(),
		fullType = item:getFullType(), square = player:getCurrentSquare(), mood = mood(player),
		fromContainer = choice.from and choice.from.container or nil, fromName = placeName(choice.from) };

	if choice.kind == "read"
	then
		local refusal = Body():readRefusal(player, item);

		if refusal
		then
			return nil, refusal, nil;
		end

		pending.title = titleOf(item);
		pending.pages = player:getAlreadyReadPages(item:getFullType()) or 0;
		run.funUsed = run.funUsed or {};
		run.funUsed[pending.itemId] = true;
		ISInventoryPaneContextMenu.readItem(item, player:getPlayerNum());
	else
		ISInventoryPaneContextMenu.eatItem(item, 1, player:getPlayerNum());
	end

	return pending;
end

-- less of it than at the start
local function lower(now, before, name)
	return now[name] < before[name] - 0.0001;
end

-- the snack with that id is nowhere: not carried, not in the container it came from, not on the 3x3
local function goneEverywhere(player, pending)
	return AutoPilotMoon.Wait:findById(player, pending.itemId, { container = pending.fromContainer, square = pending.square }) == nil;
end

local function hadFun(run, pending)
	local player = run.player;
	local now = mood(player);
	local before = pending.mood;

	if pending.source == "read"
	then
		if (pending.title and player:isLiteratureRead(pending.title)) or (player:getAlreadyReadPages(pending.fullType) or 0) > pending.pages
			or lower(now, before, "boredom") or lower(now, before, "unhappiness") or lower(now, before, "stress")
		then
			return true;
		end

		-- performed without a change: a reading the game does not pay for (the server's own "read lately"); done, and
		-- never chosen again in this run
		return pending.wait ~= nil and pending.wait:wasPerformed(watchedOfType(pending.wait, "ISReadABook"));
	end

	if lower(now, before, "hunger") or lower(now, before, "boredom") or lower(now, before, "unhappiness")
	then
		return true;
	end

	return goneEverywhere(player, pending) and (pending.mealAction == nil or (pending.wait ~= nil and pending.wait:wasPerformed(pending.mealAction)));
end

local function funFailed(run, pending, why)
	if pending.source == "read"
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NotRead", pending.name);
	end

	if why == "refused" and pending.fromName
	then
		return whyText("IGUI_AutoPilot_A_MacroR_EatRefused", pending.name, pending.fromName);
	end

	return whyText("IGUI_AutoPilot_A_MacroR_NotEaten", pending.name);
end

-- "Adesso si puo' fare?": nil and what it would do ("leggera' Fumetto da Frigo"), or why not
local function probeFun(player, op)
	local choice, why = Fun:choose(player, op, nil);

	if choice == nil
	then
		return why;
	end

	local name = choice.item:getDisplayName();
	local from = placeName(choice.from or choice.far);

	if choice.kind == "read"
	then
		return nil, from and getText("IGUI_AutoPilot_E_NowFunReadFrom", name, from) or getText("IGUI_AutoPilot_E_NowFunRead", name);
	end

	return nil, from and getText("IGUI_AutoPilot_E_NowFunSnackFrom", name, from) or getText("IGUI_AutoPilot_E_NowFunSnack", name);
end

local function describeFun(op)
	return getText("IGUI_AutoPilot_P_Now_MacroFun");
end

if AutoPilotMoon.Macro.Body and AutoPilotMoon.Macro.Body.register
then
	AutoPilotMoon.Macro.Body:register("have_fun", { start = startFun, effect = hadFun, failure = funFailed, probe = probeFun,
		describe = describeFun });
end
