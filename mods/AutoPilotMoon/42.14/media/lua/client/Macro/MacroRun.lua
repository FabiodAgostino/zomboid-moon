-- AutoPilot (Moon): automations for the Moon server.

-- A macro running (spec MACRO-AUTOPILOT.md 5): a job of the engine like the others (Automation:register("macro")): one
-- job at a time, every stop of the engine (moving, cancel, zombies, death, vehicle, sleep, unwell, the server's switch
-- off), the auto-rest between two steps, the AutoPilot panel, the messages over the head. One "square" (the one the
-- character stands on): the engine only gives guards, stops, rest, progress and panel; the step always answers "busy"
-- and ends the job itself.
--
-- One step, only with the character idle: first the "when" blocks (11.3: in the pauses only, never during an action;
-- the first whose condition is true runs its own small program, then the macro goes on where it was), then the control
-- operations (LOOP, END, STOPIF, IF, JUMP) up to Run.maxControlOps per frame, until an ACTION or a WAIT. A recipe is the
-- game's own (Craft:queueAction = the right click's OnNewCraft, the ISHandcraftAction the server checks and performs)
-- on the first suitable item, never a favourite, an equipped or a worn one; exercise, rest, eat, drink and smoke are
-- the game's own actions as by hand (MacroBody.lua). Every action counts only when the game says so (the inventory, the
-- character's stats), with the engine's wait (AutoPilotMoon.Wait, 1.2.1): up to Wait.timeoutMs idle for the server,
-- "aspetta il server: ..." after Wait.waitingAfterMs.
-- Never a step given for done; no retry of a failed step: the macro stops and says the line and why. The server's
-- limits are read at every step: actions per run, loops per run, actions per minute (a pause, not a stop).
--
-- The workbenches (wave 1, 13/11/2026, MacroBench.lua): an action at a bench finds it, waits for a friend at it (30 s),
-- walks to it, marks it in use, then the same recipe confirmation; the bench is released at every end and stop. The
-- server's new limits of every macro, read at every step: real minutes of a run (MacroMinutesPerRun), levels of one
-- skill in a run (MacroLevelsPerRun), skills no macro works for (MacroExcludedSkills: the macro stops before an action
-- that would reward one).
--
-- Items and places (waves 2 and 3, 19/11/2026, MacroItems.lua, MacroPlaces.lua): take, put, drop, equip and walk_to are
-- the game's own transfers, drop, equip and walk, confirmed by what arrived; a named place is checked at the start
-- (marked in the macro, within MacroPlaceRadius of the start) and before every use; at most MacroItemsPerRun items
-- moved in a run. Switch EnableMacroTransfers, read at every step.
--
-- The hooks on the game's ISHandcraftAction (perform and stop, installed once at OnGameStart, also used by the
-- recorder): the game's method is always called, ours only reads (inside pcall, an error of ours never breaks the
-- player's recipe). A recipe is confirmed by id (1.2.1): the item clicked used up (not in the inventory, not on the
-- 3x3 at the feet, not in its container), or something new since the recipe was QUEUED (in the inventory or at the
-- feet: in multiplayer the outputs arrive before the client's perform, a photo there saw them already), or what the
-- recipe keeps changed.
--
-- The notifications (20/11/2026, WP1c of ANALISI-NOTIFICHE-DISCORD.md, sections 3.3 and 3.6): every reason a macro
-- ends or stops with is made with AutoPilotMoon.Notify:why (its text key, without IGUI_AutoPilot_A_, is the code of
-- the event the centralino sends: MacroR_NoItem, MacroDoneLimit...) or Notify:code ("MacroDone", "internal": no text),
-- in the same frame as the stop; fail and finish keep that code in Run.last.code. The same in MacroBody.lua,
-- MacroFood.lua and MacroItems.lua for the reasons they make. A refusal at the start is never sent (Notify:sayUnsent:
-- the player just asked for it). Every action confirmed goes to Notify:onMacroAction (the sentinel materials_low).
--
-- Autonomy (26/11/2026, package P1 of ANALISI-AUTONOMIA.md): craving alone waits for the game's stress moodle (2.3);
-- the guard of the "when" blocks counts apart the starts that did an action (3.8.1); an action that keeps the
-- character busy too long is stopped through pending.busy (Run:busyTick, 3.8.2).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Run = AutoPilotMoon.Macro.Run or {};
AutoPilotMoon.Macro.Hooks = AutoPilotMoon.Macro.Hooks or {};

local Run = AutoPilotMoon.Macro.Run;
local Hooks = AutoPilotMoon.Macro.Hooks;
local A = AutoPilotMoon.Automation;

Run.maxControlOps = 64;       -- LOOP / END / STOPIF / IF / JUMP per frame at most
-- the guard of the "when" blocks (26/11/2026, ANALISI-AUTONOMIA.md 3.8.1), between two actions of the macro itself: a
-- "when" may start this many times doing nothing (no action of its block confirmed); the next start stops the macro
Run.handlerInRow = 3;
-- and this many times doing something (have_fun() one reading a start, eat() with small foods...); the next start stops
-- it too (a rest(until=20) under "when exerted >= 3" never runs forever)
Run.handlerActsInRow = 10;
Run.severeLevel = 4;          -- a moodle a "when" looks after stops the macro only at this level (11.4)
-- the engine's "unwell" moodles a "when" can look after (eat, drink, stop calmly...): the others (injured, bleeding)
-- always stop at the engine's level, nothing in the language treats a wound
Run.relaxable = { HUNGRY = true, THIRST = true, PANIC = true };
Run.current = nil;            -- the running macro
Run.last = nil;               -- how the last run ended, for the editor: { name, reason, line, text }

-- the server's limits of the macros (shared/05_AP_Config.lua, sandbox-options.txt), read at every step
local function limits()
	return AutoPilotMoon.Sandbox:getInteger("MacroActionsPerRun"),
		AutoPilotMoon.Sandbox:getInteger("MacroLoopsPerRun"),
		AutoPilotMoon.Sandbox:getInteger("MacroActionsPerMinute");
end

Run.limits = limits;

local function Body()
	return AutoPilotMoon.Macro.Body;
end

local function Bench()
	return AutoPilotMoon.Macro.Bench;
end

local function Items()
	return AutoPilotMoon.Macro.Items;
end

local function Places()
	return AutoPilotMoon.Macro.Places;
end

-- have_fun() and has_fun() (26/11/2026, MacroFun.lua, contract C5 of ANALISI-AUTONOMIA.md 5)
local function Fun()
	return AutoPilotMoon.Macro.Fun;
end

-- the text of the reason of a stop or an end, its key remembered for the notifications (the event's code)
local function whyText(key, a, b, c)
	return AutoPilotMoon.Notify:why(key, a, b, c);
end

-- the code of the reason made last in this frame (the key Notify:why or Notify:code remembered), nil when none
local function reasonCode()
	return AutoPilotMoon.Notify:keyCode();
end

-- the skills the server keeps out of the macros (MacroExcludedSkills: game ids or names, separated by ";" or ","): a
-- set of lower perk ids, read at the moment
function AutoPilotMoon.Macro.Run:excludedSkills()
	local text = AutoPilotMoon.Sandbox:getString("MacroExcludedSkills") or "";
	local set = {};

	for word in string.gmatch(text, "[^;,]+")
	do
		local name = AutoPilotMoon.Macro.Lang.trim(word);

		if name ~= ""
		then
			set[string.lower(name)] = true;

			local perk = AutoPilotMoon.Macro.Names:resolveSkill(name);

			if perk
			then
				set[string.lower(perk:getId())] = true;
			end
		end
	end

	return set;
end

-- where the benches are looked for: the place the running macro started from, else the character's square (the
-- editor's checks)
function AutoPilotMoon.Macro.Run:center(player)
	local run = Run.current;

	if run and run.player == player and run.center
	then
		return run.center;
	end

	local square = player:getSquare();

	return square and { x = square:getX(), y = square:getY(), z = square:getZ() } or nil;
end

-- ============================================================================================================
-- Conditions (2.2, 11.2, 16): the character's inventory (bags and favourites included), a skill's level, the states
-- ============================================================================================================

function AutoPilotMoon.Macro.Run:countItems(player, types)
	local inventory = player:getInventory();
	local count = 0;

	for i, fullType in ipairs(types)
	do
		count = count + inventory:getCountTypeRecurse(fullType);
	end

	return count;
end

-- a moodle's level (0-4) by its MoodleType name
function AutoPilotMoon.Macro.Run:moodleLevel(player, name)
	local moodles = player:getMoodles();
	local moodleType = MoodleType[name];

	if moodles == nil or moodleType == nil
	then
		return 0;
	end

	return moodles:getMoodleLevel(moodleType) or 0;
end

-- the smoker's nicotine withdrawal as the game keeps it (CharacterStat.NICOTINE_WITHDRAWAL, 0-0.51)
function AutoPilotMoon.Macro.Run:nicotine(player)
	local stats = player:getStats();
	local stat = CharacterStat.NICOTINE_WITHDRAWAL;

	if stats == nil or stat == nil
	then
		return 0;
	end

	return stats:get(stat) or 0;
end

local function cravingPercent(raw)
	return math.floor(raw / AutoPilotMoon.Macro.Lang.cravingMax * 100 + 0.5);
end

-- endurance and the smoker's craving in percent (0-100)
function AutoPilotMoon.Macro.Run:percent(player, name)
	if name == "endurance"
	then
		return AutoPilotMoon.Rest:getEndurancePercent(player);
	end

	return cravingPercent(Run:nicotine(player));
end

-- The states of one pass (19/11/2026, MACRO-AUTOPILOT.md 16.2): a new snapshot at every step of the macro (one per
-- pause check) and at every evaluation outside a run; each state is read from the game at most once in it, at its
-- first use, and every condition of the pass sees the same values. Run.stateReads counts the reads (the tests).
Run.stateReads = 0;
-- after a smoke() confirmed, the craving reads 0 this long while its value is still the one of the confirmation: in
-- MP the server sends the stats every second and the cigarette goes before them (MACRO-STATI-ANALISI.md 3), so a
-- "when craving:" would smoke a second one
Run.smokeSettleMs = 3000;

function AutoPilotMoon.Macro.Run:newStates(player)
	return { player = player, level = {}, percent = {}, on = {} };
end

-- a moodle's level (0-4) in the pass, by its MoodleType name
local function stateLevel(states, moodle)
	local level = states.level[moodle];

	if level == nil
	then
		level = Run:moodleLevel(states.player, moodle);
		states.level[moodle] = level;
		Run.stateReads = Run.stateReads + 1;
	end

	return level;
end

-- the nicotine withdrawal in the pass, 0 just after a smoke() whose new value has not come yet
local function cravingRaw(states)
	if states.craving == nil
	then
		local raw = Run:nicotine(states.player);
		local run = Run.current;
		local smoked = run and run.player == states.player and run.smoked or nil;

		if smoked and raw > 0 and raw == smoked.raw and getTimestampMs() - smoked.at < Run.smokeSettleMs
		then
			raw = 0;
		end

		states.craving = raw;
		Run.stateReads = Run.stateReads + 1;
	end

	return states.craving;
end

local function statePercent(states, word)
	local value = states.percent[word];

	if value == nil
	then
		if word == "endurance"
		then
			value = AutoPilotMoon.Rest:getEndurancePercent(states.player);
			Run.stateReads = Run.stateReads + 1;
		else
			value = cravingPercent(cravingRaw(states));
		end

		states.percent[word] = value;
	end

	return value;
end

-- a smoker (the game's trait, CharacterTrait.SMOKER of 42.22: only a smoker's withdrawal grows, BodyDamage.UpdateBoredom);
-- a game without the constant: the withdrawal alone says it
local function isSmoker(player)
	local trait = CharacterTrait and CharacterTrait.SMOKER or nil;

	if trait == nil
	then
		return true;
	end

	return player:hasTrait(trait) == true;
end

-- a state word alone (16.1): the game shows it now. A moodle: its level is 1 or more (the game's own thresholds);
-- endurance: the endurance moodle (as exerted); craving (26/11/2026, ANALISI-AUTONOMIA.md 2.3, decision DA1): a smoker
-- in withdrawal while the game shows the stress moodle. The game's moodle reads Stats.getNicotineStress() = stress +
-- withdrawal, so the withdrawal alone shows it above 0.25 (49%), with other stress sooner: what the player sees. The
-- withdrawal above 0 alone (until 1.5.0) comes five times sooner than the moodle: the macro smoked five times as often.
-- Just after a smoke() the withdrawal reads 0 for Run.smokeSettleMs (cravingRaw): in MP the moodle stays on for the
-- second the new withdrawal takes to come
local function stateOn(states, word)
	local on = states.on[word];

	if on == nil
	then
		if word == "craving"
		then
			on = cravingRaw(states) > 0 and isSmoker(states.player) and stateLevel(states, "STRESS") >= 1;
		elseif word == "endurance"
		then
			on = stateLevel(states, "ENDURANCE") >= 1;
		else
			local moodle = AutoPilotMoon.Macro.Lang.moodles[word];

			on = moodle ~= nil and stateLevel(states, moodle) >= 1;
		end

		states.on[word] = on;
	end

	return on;
end

-- the value of a state word in a pass: alone (true / false) or with a number (a moodle's level, a percent)
function AutoPilotMoon.Macro.Run:stateValue(states, word, alone)
	if alone
	then
		return stateOn(states, word);
	end

	local moodle = AutoPilotMoon.Macro.Lang.moodles[word];

	if moodle
	then
		return stateLevel(states, moodle);
	end

	return statePercent(states, word);
end

-- the conditions of the work (wave 0, 13/11/2026, ANALISI-API-MACRO-LAVORATIVE.md A0.3): read only, nothing queued

-- an item's condition in percent of its most (0-100; an item without a most: 100)
local function conditionPercent(item)
	local max = item:getConditionMax();

	if max == nil or max <= 0
	then
		return 100;
	end

	return math.floor(item:getCondition() * 100 / max);
end

-- condition("X"): the best condition among the items of those types the character has (bags, favourites and the one
-- in the hands included: the tool in use is the one to look after); 0 when there is none
function AutoPilotMoon.Macro.Run:bestCondition(player, types)
	local best = 0;
	local set = {};

	for i, fullType in ipairs(types)
	do
		set[fullType] = true;
	end

	local items = player:getInventory():getAllEvalRecurse(function(item)
		return set[item:getFullType()] == true;
	end);

	for i = 0, items:size() - 1
	do
		best = math.max(best, conditionPercent(items:get(i)));
	end

	return best;
end

-- has("X", damaged=True): the items of those types below their most condition (InventoryItem.isDamaged of 42.22, the
-- test of a repair's flags[IsDamaged]) that the macro may work on (never a favourite, an equipped or a worn one)
function AutoPilotMoon.Macro.Run:countDamaged(player, types)
	local set = {};

	for i, fullType in ipairs(types)
	do
		set[fullType] = true;
	end

	local items = player:getInventory():getAllEvalRecurse(function(item)
		return set[item:getFullType()] == true and item:getCondition() < item:getConditionMax() and Run:isUsable(player, item);
	end);

	return items:size();
end

-- xp_gained("Skill"): the experience the skill took since the macro started (0 outside a run: the editor's checks)
function AutoPilotMoon.Macro.Run:xpGained(player, perk)
	local run = Run.current;
	local start = run and run.player == player and run.xpBase and run.xpBase[perk:getId()] or nil;

	if start == nil
	then
		return 0;
	end

	return math.max(0, math.floor(player:getXp():getXP(perk) - start));
end

-- the words of a condition (Lang.condWordList): dark (true / false), hour (0-23)
function AutoPilotMoon.Macro.Run:wordValue(player, name)
	if name == "dark"
	then
		return player:tooDarkToRead() == true;
	elseif name == "hour"
	then
		local time = getGameTime();

		return time and time:getHour() or 0;
	end

	return 0;
end

-- known("Recipe"): one of the recipes of the name is known (needs no learning, or learned)
function AutoPilotMoon.Macro.Run:knows(player, recipes)
	for i, recipe in ipairs(recipes)
	do
		if AutoPilotMoon.Macro.Names:isLearned(player, recipe)
		then
			return true;
		end
	end

	return false;
end

local function value(player, node, states)
	local k = node.k;

	if k == "num"
	then
		return node.v;
	elseif k == "moodle"
	then
		return stateLevel(states, node.name);
	elseif k == "percent"
	then
		return statePercent(states, node.word or node.name);
	elseif k == "count"
	then
		-- count("X", at="P") (wave 2): what the place holds
		if node.placeKey
		then
			return Items():countAt(player, node.types, node.place);
		end

		return Run:countItems(player, node.types);
	elseif k == "space"
	then
		return Items():spaceLeft(player, node.place);
	elseif k == "skill"
	then
		return player:getPerkLevel(node.perk);
	elseif k == "xp"
	then
		return Run:xpGained(player, node.perk);
	elseif k == "condition"
	then
		return Run:bestCondition(player, node.types);
	elseif k == "word"
	then
		return Run:wordValue(player, node.name);
	end

	return 0;
end

-- a condition: true or false; states (optional): the pass's states (Run:newStates), a new snapshot when nil
function AutoPilotMoon.Macro.Run:evalCondition(player, cond, states)
	local k = cond.k;

	states = states or Run:newStates(player);

	if k == "const"
	then
		return cond.v == true;
	elseif k == "state"
	then
		return stateOn(states, cond.word);
	elseif k == "has"
	then
		if cond.damaged
		then
			return Run:countDamaged(player, cond.types) >= cond.n;
		end

		return Run:countItems(player, cond.types) >= cond.n;
	elseif k == "word"
	then
		return Run:wordValue(player, cond.name) == true;
	elseif k == "known"
	then
		return Run:knows(player, cond.recipes);
	elseif k == "benchFree"
	then
		return Bench():isFree(player, Run:center(player), cond.benches);
	elseif k == "hasFood"
	then
		-- has_food(), has_drink() (20/11/2026): what eat() / drink() would find now (MacroFood.lua)
		return Body():hasFood(player, cond.op);
	elseif k == "hasDrink"
	then
		return Body():hasDrink(player, cond.op);
	elseif k == "hasFun"
	then
		-- has_fun() (26/11/2026, ANALISI-AUTONOMIA.md 3.4): what have_fun() would find now (MacroFun.lua), with the run
		-- of this player (the readings it already used)
		local run = Run.current;

		return Fun():has(player, cond.op, (run and run.player == player) and run or nil) == true;
	elseif k == "hasSmoke"
	then
		-- has_smoke() (3.8): smoke() would find something to smoke and to light it with now
		return Body():hasSmoke(player, cond.op) == true;
	elseif k == "not"
	then
		return not Run:evalCondition(player, cond.a, states);
	elseif k == "and"
	then
		return Run:evalCondition(player, cond.a, states) and Run:evalCondition(player, cond.b, states);
	elseif k == "or"
	then
		return Run:evalCondition(player, cond.a, states) or Run:evalCondition(player, cond.b, states);
	elseif k == "cmp"
	then
		local a = value(player, cond.a, states);
		local b = value(player, cond.b, states);
		local op = cond.op;

		if op == "<" then return a < b; end
		if op == "<=" then return a <= b; end
		if op == ">" then return a > b; end
		if op == ">=" then return a >= b; end
		if op == "!=" then return a ~= b; end

		return a == b;
	end

	return false;
end

-- ============================================================================================================
-- Choosing the item and the recipe (2.5)
-- ============================================================================================================

-- an item the macros may use as a material: never a favourite, an equipped or a worn one
function AutoPilotMoon.Macro.Run:isUsable(player, item)
	return not item:isFavorite() and not item:isEquipped() and not player:isEquipped(item) and not item:isWorn();
end

-- the first reachable item (the inventory, then the containers the right click would use, in their order) of one of
-- the types (a set), valid for the recipe and not one of its tools
local function findItem(player, containers, recipe, typeSet)
	local function wanted(item)
		return typeSet[item:getFullType()] == true;
	end

	for c = 0, containers:size() - 1
	do
		local items = containers:get(c):getAllEvalRecurse(wanted);

		for i = 0, items:size() - 1
		do
			local item = items:get(i);

			if Run:isUsable(player, item)
				and CraftRecipeManager.isItemValidForRecipe(recipe, item, player)
				and not CraftRecipeManager.isItemToolForRecipe(recipe, item, player)
			then
				return item;
			end
		end
	end

	return nil;
end

-- the recipe of the set the game can do now and its item, or nil and why ("dark", "surface", "refused", "noitem")
-- with the recipe it is about
function AutoPilotMoon.Macro.Run:choose(player, op)
	local containers = ISInventoryPaneContextMenu.getContainers(player);
	local reason = nil;
	local about = nil;

	for i, recipe in ipairs(op.recipes)
	do
		-- without using=: what the recipe uses up, or the item it works on and keeps (a repair: the damaged bat, never
		-- the tape, so the game does not pick a favourite bat by itself)
		local typeSet = op.withSet or AutoPilotMoon.Macro.Names:clickTypes(recipe);
		local item = containers and findItem(player, containers, recipe, typeSet) or nil;

		if item
		then
			local why = AutoPilotMoon.Craft:check(player, recipe, item);

			if why == nil
			then
				return recipe, item;
			end

			-- a reason of the place (dark, a surface) says more than a missing material
			if reason == nil or reason == "noitem" or (reason == "refused" and why ~= "refused")
			then
				reason = why;
				about = recipe;
			end
		elseif reason == nil
		then
			reason = "noitem";
			about = recipe;
		end
	end

	return nil, nil, reason or "noitem", about or op.recipes[1];
end

-- the same choice at a bench (wave 1): the recipes of the set this bench does, the first suitable item, the game's
-- check with the bench's logic (Craft:checkAtBench: "dark", "fuel", "refused")
function AutoPilotMoon.Macro.Run:chooseAtBench(player, op, bench)
	local containers = ISInventoryPaneContextMenu.getContainers(player);
	local Names = AutoPilotMoon.Macro.Names;
	local reason = nil;
	local about = nil;

	for i, recipe in ipairs(op.recipes)
	do
		if Names:bench(bench.id) == nil or Names:benchFits(bench.id, recipe)
		then
			local typeSet = op.withSet or Names:clickTypes(recipe);
			local item = containers and findItem(player, containers, recipe, typeSet) or nil;

			if item
			then
				local why = AutoPilotMoon.Craft:checkAtBench(player, recipe, item, bench);

				if why == nil
				then
					return recipe, item;
				end

				if reason == nil or reason == "noitem" or (reason == "refused" and why ~= "refused")
				then
					reason = why;
					about = recipe;
				end
			elseif reason == nil
			then
				reason = "noitem";
				about = recipe;
			end
		end
	end

	return nil, nil, reason or "noitem", about or op.recipes[1];
end

-- ============================================================================================================
-- Texts
-- ============================================================================================================

local function recipeName(recipe)
	return AutoPilotMoon.Macro.Names:recipeName(recipe);
end

-- the recipe is not known yet (a magazine, a level): the game refuses it for that, say how it is learned (A0.3)
local function notKnown(player, recipe)
	return player ~= nil and recipe ~= nil and not AutoPilotMoon.Macro.Names:isLearned(player, recipe);
end

-- why an action does not start, in words (5.3); the key remembered for the notifications
local function reasonText(op, reason, recipe, player)
	local name = recipeName(recipe);

	if reason == "dark"
	then
		return whyText("IGUI_AutoPilot_A_MacroR_Dark", name);
	elseif reason == "surface"
	then
		return whyText("IGUI_AutoPilot_A_MacroR_Surface", name);
	elseif reason == "noitem" and op.work
	then
		-- repair() / sharpen(): nothing damaged, nothing to sharpen (favourites never)
		return whyText(op.work == "sharpen" and "IGUI_AutoPilot_A_MacroR_NothingToSharpen" or "IGUI_AutoPilot_A_MacroR_NothingToRepair", op.itemText);
	elseif reason == "noitem" and op.withText
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NoItem", op.withText);
	elseif reason == "refused" and notKnown(player, recipe)
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NotKnown", name, AutoPilotMoon.Macro.Names:learnHint(recipe));
	elseif reason == "fuel"
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NoFuel", name);
	end

	return whyText("IGUI_AutoPilot_A_MacroR_Refused", name);
end

-- "smonta Martello a granchio" / "crea Assembla utensile medio" / "flessioni, 10 minuti" (the panel's "Ora:" line)
local function describe(op)
	if Items():handles(op.kind)
	then
		return Items():describe(op);
	end

	if op.kind ~= "craft"
	then
		return Body():describe(op);
	end

	if op.work
	then
		return getText(op.work == "sharpen" and "IGUI_AutoPilot_P_Now_MacroSharpen" or "IGUI_AutoPilot_P_Now_MacroRepair", op.itemText);
	end

	if op.dismantle
	then
		return getText("IGUI_AutoPilot_P_Now_MacroDismantle", op.itemText);
	end

	if op.smelt
	then
		return getText("IGUI_AutoPilot_P_Now_MacroSmelt", op.itemText, Bench():opText(op));
	end

	if op.bench
	then
		return getText("IGUI_AutoPilot_P_Now_MacroCraftAt", op.recipeText, Bench():opText(op));
	end

	return getText("IGUI_AutoPilot_P_Now_MacroCraft", op.recipeText);
end

Run.describe = describe;

-- how a loop repeats, for the start message: "finche' puoi", "20 volte", "sempre", "finche' Manutenzione < 4"
function AutoPilotMoon.Macro.Run:modeText(loop)
	if loop == nil
	then
		return getText("IGUI_AutoPilot_A_MacroMode_Once");
	elseif loop.mode == "times"
	then
		return getText("IGUI_AutoPilot_A_MacroMode_Times", loop.n);
	elseif loop.mode == "possible"
	then
		return getText("IGUI_AutoPilot_A_MacroMode_Possible");
	elseif loop.mode == "while"
	then
		return getText("IGUI_AutoPilot_A_MacroMode_While", loop.condText or "");
	end

	return getText("IGUI_AutoPilot_A_MacroMode_Forever");
end

-- the panel's second line for the outermost loop at its turn i
local function loopText(loop, i)
	if loop.mode == "times"
	then
		return getText("IGUI_AutoPilot_P_Loop_Times", i, loop.n);
	elseif loop.mode == "possible"
	then
		return getText("IGUI_AutoPilot_P_Loop_Possible", i);
	elseif loop.mode == "while"
	then
		return getText("IGUI_AutoPilot_P_Loop_While", i, loop.condText or "");
	end

	return getText("IGUI_AutoPilot_P_Loop_Forever", i);
end

-- the experience the actions gave since the start: "Manutenzione: +12 esperienza (livello 2)" per skill; and the short
-- form for the end over the head ("Manutenzione +12")
local function experience(run, short)
	local parts = {};

	for i, perk in ipairs(run.perks)
	do
		local gained = math.floor(run.player:getXp():getXP(perk) - run.xpStart[i]);

		if gained > 0
		then
			if short
			then
				table.insert(parts, getText("IGUI_AutoPilot_A_MacroXpShort", perk:getName(), gained));
			else
				table.insert(parts, getText("IGUI_AutoPilot_P_C_MacroXp", perk:getName(), gained, run.player:getPerkLevel(perk)));
			end
		end
	end

	return parts;
end

-- ============================================================================================================
-- The engine's guards a macro changes (11.4): "unwell" and the auto-rest
-- ============================================================================================================

-- the checked macro the engine is asking about: the one starting, the one running, or the one the editor checks
local function activeResult()
	if Run.starting
	then
		return Run.starting.result;
	end

	if Run.current
	then
		return Run.current.result;
	end

	return Run.checking;
end

-- the MoodleType names the "when" blocks of a checked macro look after
function AutoPilotMoon.Macro.Run:handledMoodles(result)
	local handled = {};

	for i, handler in ipairs(result and result.handlers or {})
	do
		for moodle in pairs(handler.moodles or {})
		do
			handled[moodle] = true;
		end
	end

	return handled;
end

-- the engine's "unwell" level for a moodle: a moodle a "when" looks after (hunger, thirst, panic) stops the macro only
-- when it is severe (Run.severeLevel); every other moodle as for every job
function AutoPilotMoon.Macro.Run.unwellLevel(player, moodle, level)
	local result = activeResult();

	if result and Run.relaxable[moodle] and Run:handledMoodles(result)[moodle]
	then
		return math.max(level, Run.severeLevel);
	end

	return level;
end

-- the engine's auto-rest: off for a macro that rests by itself (rest(), or a "when" on endurance, exerted or tired)
function AutoPilotMoon.Macro.Run.autoRest(job, player)
	local result = activeResult();

	if result == nil
	then
		return true;
	end

	if result.uses.rest
	then
		return false;
	end

	local handled = Run:handledMoodles(result);

	return not (handled.ENDURANCE or handled.TIRED);
end

-- ============================================================================================================
-- Start
-- ============================================================================================================

-- the reason a macro cannot start now (nil: it can), in the engine's own words where it has them (4.2, Avvia grey)
function AutoPilotMoon.Macro.Run:getStartRefusal(player, result)
	if not A:isAllowedByServer("macro")
	then
		return getText("IGUI_AutoPilot_E_Off");
	end

	if AutoPilotMoon.Macro.Recorder and AutoPilotMoon.Macro.Recorder:isRecording()
	then
		return getText("IGUI_AutoPilot_M_MacroRecording");
	end

	if A:isBusy()
	then
		local state = AutoPilotMoon.Progress.state;
		local title = state.titleText or (state.titleKey and getText(state.titleKey)) or "";

		return getText("IGUI_AutoPilot_E_RunOtherJob", title);
	end

	if result
	then
		if result.errors > 0
		then
			return getText("IGUI_AutoPilot_E_RunFixFirst", result.errors);
		end

		if result.actionCount == 0
		then
			return getText("IGUI_AutoPilot_E_RunEmpty");
		end

		-- the named places (wave 2): marked in this macro, within MacroPlaceRadius of where it starts
		local refusal = Run:placeRefusal(player, result);

		if refusal
		then
			return refusal;
		end
	end

	Run.checking = result;

	local guard = player and A:getGuardReason(player, A.definitions.macro);

	Run.checking = nil;

	if guard
	then
		return A:getReasonText(guard) or getText("IGUI_AutoPilot_A_Reason_Disabled");
	end

	return nil;
end

-- why the places of a checked macro stop it from starting here (nil: they do not): a place the text names that the
-- macro has not marked, a place farther than MacroPlaceRadius from the character (where the macro would start)
function AutoPilotMoon.Macro.Run:placeRefusal(player, result)
	if not result.placesKnown or player == nil
	then
		return nil;
	end

	local center = Run:center(player);

	for i, ref in ipairs(result.placeRefs or {})
	do
		if ref.place == nil
		then
			return getText("IGUI_AutoPilot_E_RunNoPlace", ref.line, ref.name);
		end

		if center and not Places():isInRange(ref.place, center)
		then
			return getText("IGUI_AutoPilot_E_RunPlaceFar", ref.place.name, Places():distance(ref.place, center), Places():radius());
		end
	end

	return nil;
end

-- checks a macro's text for a player with the server's limits of now; places: the macro's named places by key
-- (Places:map; nil = not known: no place is said missing)
function AutoPilotMoon.Macro.Run:check(player, text, places)
	local maxActions, maxLoops = limits();

	return AutoPilotMoon.Macro.Lang:check(text, AutoPilotMoon.Macro.Names, { player = player, maxActions = maxActions, maxLoops = maxLoops,
		benches = Bench():isEnabled(), excluded = Run:excludedSkills(), transfers = Places():isEnabled(), places = places,
		eatNear = AutoPilotMoon.Sandbox:getBooleanOn("MacroEatNear") });
end

-- the sets of "using" and the skills of an op list (the main program or a "when")
local function prepareOps(run, ops, seen)
	for i, op in ipairs(ops)
	do
		if op.op == "ACTION"
		then
			if op.withTypes and op.withSet == nil
			then
				op.withSet = {};

				for j, fullType in ipairs(op.withTypes)
				do
					op.withSet[fullType] = true;
				end
			end

			op.desc = describe(op);

			local perks = {};

			op.perks = perks;

			if op.kind == "craft"
			then
				for j, recipe in ipairs(op.recipes)
				do
					if run.icon == nil
					then
						run.icon = recipe:getIconTexture();
					end

					for k, perk in ipairs(AutoPilotMoon.Macro.Names:xpPerks(recipe))
					do
						table.insert(perks, perk);
					end
				end
			else
				for k, perk in ipairs(Body():xpPerks(op))
				do
					table.insert(perks, perk);
				end
			end

			for k, perk in ipairs(perks)
			do
				local id = perk:getId();

				if not seen[id]
				then
					seen[id] = true;
					table.insert(run.perks, perk);
					table.insert(run.xpStart, run.player:getXp():getXP(perk));
					run.levelStart[id] = run.player:getPerkLevel(perk);
				end
			end
		end
	end
end

-- Starts a stored macro for the player: the text checked again (with errors it does not start), then the engine's own
-- start with the character's square. Returns true when it runs; false and the refusal's text.
function AutoPilotMoon.Macro.Run:start(player, macro)
	if player == nil or macro == nil
	then
		return false, nil;
	end

	AutoPilotMoon.Macro.Names:buildNow();

	local result = Run:check(player, macro.text, Places():map(macro));
	local refusal = Run:getStartRefusal(player, result);

	if refusal
	then
		-- never sent to the notifications (ANALISI-NOTIFICHE-DISCORD.md 3.9: the player just asked for it, also while
		-- another job runs)
		AutoPilotMoon.Notify:sayUnsent("bad", getText("IGUI_AutoPilot_A_JobNotStarted", getText("IGUI_AutoPilot_O_Context_Macro"), refusal), player);

		return false, refusal;
	end

	local square = player:getSquare();

	Run.starting = { macro = macro, result = result };

	local started = A:startJob("macro", player, { square }, square);

	Run.starting = nil;

	if not started
	then
		local why = A.lastStartRefusal and A:getReasonText(A.lastStartRefusal) or nil;

		return false, why;
	end

	local ops = result.ops;
	local main = { ops = ops, pc = 1, counters = {} };
	local run = {
		player = player,
		name = macro.name,
		macro = macro,
		result = result,
		ops = ops,
		main = main,
		frame = main,
		actions = 0,
		loops = 0,
		starts = {},
		perks = {},
		xpStart = {},
		xpBase = {},
		levelStart = {},
		outer = nil,
		-- the benches (wave 1): around the place the macro starts from; the bench in use, a walk done, a wait
		center = { x = square:getX(), y = square:getY(), z = square:getZ() },
		bench = nil,
		benchWalk = nil,
		benchWait = nil,
		startedAt = getTimestampMs(),
		-- items and places (wave 2): items moved, what was in the inventory at the start ("made" is the rest, not
		-- taken), the line a walk to a place was for
		itemsMoved = 0,
		startIds = Items():inventoryIds(player),
		takenIds = {},
		placeWalk = nil,
	};
	local seen = {};

	-- xp_gained("Skill") counts from here (A0.3)
	for i, perk in ipairs(result.xpPerks or {})
	do
		run.xpBase[perk:getId()] = player:getXp():getXP(perk);
	end

	prepareOps(run, ops, seen);

	for i, handler in ipairs(result.handlers)
	do
		handler.inRow = 0;
		handler.actsInRow = 0;
		handler.acted = false;
		prepareOps(run, handler.ops, seen);
	end

	run.outer = AutoPilotMoon.Macro.Lang:outerLoop(ops);
	run.modeText = Run:modeText(run.outer);

	Run.current = run;
	AutoPilotMoon.Macro.Store:touch(macro);
	AutoPilotMoon.Macro.Store:save(true);

	local maxActions = limits();
	local planned = #result.handlers == 0 and AutoPilotMoon.Macro.Lang:plannedActions(ops) or nil;

	AutoPilotMoon.Progress:setTitleText(getText("IGUI_AutoPilot_P_Macro_Title", macro.name));
	AutoPilotMoon.Progress:setIcon(run.icon);
	AutoPilotMoon.Progress:setUnits(math.min(planned or maxActions, maxActions), "IGUI_AutoPilot_S_Unit_Actions");

	return true, nil;
end

-- the start over the head (5.5): "Macro: Manutenzione - martelli, finche' puoi - muoviti per fermare"
function AutoPilotMoon.Macro.Run.announceStart(job)
	local run = Run.current;

	if run
	then
		local text = getText("IGUI_AutoPilot_A_MacroStarted", run.name, run.modeText);

		AutoPilotMoon:say("info", getText("IGUI_AutoPilot_A_MacroHowToStop", text), job.player);
	end

	return true;
end

-- the end over the head (5.5): finished with its reason or its short summary, stopped (line and reason), stopped by
-- the player, stopped by the engine with its reason
function AutoPilotMoon.Macro.Run.announceStop(job, reason, stopText)
	local last = Run.last or {};

	if reason == "done"
	then
		AutoPilotMoon.UI:playSound("UISelectListItem");
		AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_MacroFinished", last.endText or last.shortText or ""), job.player);
	elseif reason == "user"
	then
		AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroStoppedUser"), job.player);
	elseif reason == "because" and last.line
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_MacroStopped", last.line, last.text), job.player);
	else
		local text = stopText or A:getReasonText(reason);

		if text
		then
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_MacroStoppedReason", text), job.player);
		else
			AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroStoppedUser"), job.player);
		end
	end

	return true;
end

-- ============================================================================================================
-- The end
-- ============================================================================================================

-- the short summary: "azioni 40, Manutenzione +36"
local function shortSummary(run)
	local parts = { getText("IGUI_AutoPilot_A_MacroActionsShort", AutoPilotMoon.Progress:getCount("IGUI_AutoPilot_P_C_MacroActions")) };

	for i, text in ipairs(experience(run, true))
	do
		table.insert(parts, text);
	end

	return table.concat(parts, ", ");
end

-- the macro ends well (end of the text, a limit, a condition, "non si puo' piu' fare"); endText: the reason or nil
-- (made with Notify:why, or Notify:code("MacroDone") before); line: the line of stop() / stop_if(). Run.last.code: the
-- code of the notification (MacroDone, MacroDoneLimit...)
local function finish(run, endText, line)
	run.ended = true;
	Run.last = { name = run.name, reason = "done", endText = endText, shortText = shortSummary(run), code = reasonCode(),
		line = line };
	A:stopAll("done");
end

-- the macro stops at a line with a reason (5.3), its text made with Notify:why in this frame (Run.last.code: the code of
-- the notification, MacroR_NoItem...)
local function fail(run, op, text)
	run.ended = true;
	Run.last = { name = run.name, reason = "because", line = op.line, text = text, code = reasonCode() };
	A:stopBecause(getText("IGUI_AutoPilot_A_MacroLine", op.line, text));
end

Run.finish = finish;
Run.fail = fail;

-- ============================================================================================================
-- The step
-- ============================================================================================================

-- a new turn of the loop at index i of the frame, or out of it; false when the macro ended (the loops' limit)
local function iterate(run, frame, i, states)
	local op = frame.ops[i];
	local go = false;

	if op.mode == "times"
	then
		go = (frame.counters[i] or 0) < op.n;
	elseif op.mode == "while"
	then
		go = Run:evalCondition(run.player, op.cond, states);
	else
		go = true;
	end

	if not go
	then
		frame.pc = op.endIndex + 1;

		return true;
	end

	local maxLoops = select(2, limits());

	if run.loops >= maxLoops
	then
		finish(run, whyText("IGUI_AutoPilot_A_MacroDoneLoops", maxLoops));

		return false;
	end

	frame.counters[i] = (frame.counters[i] or 0) + 1;
	run.loops = run.loops + 1;
	frame.pc = i + 1;

	if op == run.outer
	then
		AutoPilotMoon.Progress:setLoopText(loopText(op, frame.counters[i]));
	end

	return true;
end

local function now()
	return getTimestampMs();
end

-- an action confirmed, told to the notifications (the sentinel materials_low): never an error for the macro
local function notifyAction(run, pending)
	local notify = AutoPilotMoon.Notify;

	if notify.onMacroAction == nil
	then
		return;
	end

	local ok, err = pcall(notify.onMacroAction, notify, run, pending);

	if not ok
	then
		print("AutoPilot (Moon): macro: notify: " .. tostring(err));
	end
end

-- an action of the frame done and confirmed: counted, the line after
local function actionDone(run, frame, pending)
	frame.pc = frame.pc + 1;
	AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_MacroActions", 1);
	AutoPilotMoon.Progress:addUnitsDone(1);

	-- the first action of a "when"'s block (3.8.1): this start did something, it is not one of the starts doing nothing
	-- (checkHandlers counted it among them when it started) but one of Run.handlerActsInRow
	local handler = frame.handler;

	if handler and not handler.acted
	then
		handler.acted = true;
		handler.inRow = math.max(0, (handler.inRow or 0) - 1);
		handler.actsInRow = (handler.actsInRow or 0) + 1;
	end

	-- an action of the macro itself: every "when" may start again, three times doing nothing, ten doing something
	if frame == run.main
	then
		for i, other in ipairs(run.result.handlers)
		do
			other.inRow = 0;
			other.actsInRow = 0;
		end
	end

	local xp = experience(run, false);

	AutoPilotMoon.Progress:setDoneText(#xp > 0 and table.concat(xp, " - ") or nil);
	notifyAction(run, pending);
end

-- the recipe at a bench (wave 1, MacroBench.lua): the bench, the wait for a friend at it, the walk, "in use", the
-- recipe of the set the game can do there now on the first suitable item, then the same confirmation as by hand
local function actAtBench(run, frame, op, time)
	local player = run.player;
	local B = Bench();

	if not B:isEnabled()
	then
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_BenchesOff"));

		return;
	end

	local benchText = B:opText(op);
	local list = B:find(player, run.center, op.benchSet, op.recipes);

	if #list == 0
	then
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_NoBench", benchText, B:radius()));

		return;
	end

	local bench, user = B:firstFree(list, player);

	if bench == nil
	then
		-- a friend at the bench: wait up to Bench.busyWaitMs, then stop with the name (decision Q6)
		local wait = run.benchWait;

		if wait == nil or wait.op ~= op
		then
			wait = { op = op, since = time };
			run.benchWait = wait;
		end

		local name = B:playerName(user);

		if time - wait.since >= B.busyWaitMs
		then
			run.benchWait = nil;
			fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_BenchBusy", B:nameOf(list[1].object, list[1].id), name, math.floor(B.busyWaitMs / 1000)));

			return;
		end

		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroBenchBusy", name, math.ceil((wait.since + B.busyWaitMs - time) / 1000));

		return;
	end

	run.benchWait = nil;

	local object = bench.object;
	local name = B:nameOf(object, bench.id);

	if not B:isNear(player, object)
	then
		if run.benchWalk == object
		then
			-- walked once already and still not there
			run.benchWalk = nil;
			fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_BenchFar", name));

			return;
		end

		if not ISEntityUI.WalkToEntity(player, object, B.walkDistance)
		then
			fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_BenchFar", name));

			return;
		end

		run.benchWalk = object;
		run.pending = { kind = "walk", op = op, frame = frame };
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroBenchWalk", name);

		return;
	end

	run.benchWalk = nil;

	if not ISEntityUI.CanOpenWindowFor(player, object)
	then
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_BenchClosed", name));

		return;
	end

	local recipe, item, reason, about = Run:chooseAtBench(player, op, bench);

	if recipe == nil
	then
		if op.possibleFirst and (reason == "noitem" or ((reason == "refused" or reason == "fuel") and not notKnown(player, about)))
		then
			finish(run, whyText(reason == "fuel" and "IGUI_AutoPilot_A_MacroDoneNoFuel" or "IGUI_AutoPilot_A_MacroDoneCannot", recipeName(about)));
		else
			fail(run, op, reasonText(op, reason, about, player));
		end

		return;
	end

	B:hold(run, object);

	local kept = Run:keptState(player, recipe, item);
	local action = AutoPilotMoon.Craft:queueAtBench(player, recipe, item, bench);

	if action == nil
	then
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_NotQueued", recipeName(recipe)));

		return;
	end

	Run:addDrainables(kept, action);
	action.autopilotMacro = true;
	run.actions = run.actions + 1;
	table.insert(run.starts, time);
	run.pending = Run:craftPending(run, action, item, recipe, op, frame, kept);
	run.pending.queuedAt = time;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroLine", op.line, op.desc);
end

-- take / put / drop / equip / walk_to (wave 2, MacroItems.lua): a walk to the place first (not an action), a container
-- asked for (a wait), nothing to do (the line after), nothing of that kind ("while possible" ends well), the server's
-- limit of the items (the macro ends well), a refusal (stopped); else the game's actions are queued
local function actItems(run, frame, op, time)
	local pending, why, kind = Items():start(run, op);

	if pending == nil
	then
		if kind == "walk"
		then
			run.pending = { kind = "walk", op = op, frame = frame };
		elseif kind == "wait"
		then
			return;
		elseif kind == "skip"
		then
			frame.pc = frame.pc + 1;
		elseif kind == "limit"
		then
			finish(run, why);
		elseif kind == "nothing" and op.possibleFirst
		then
			finish(run, whyText("IGUI_AutoPilot_A_MacroDoneCannot", op.desc));
		else
			fail(run, op, why);
		end

		return;
	end

	pending.frame = frame;
	-- when the game's actions were queued: the busy time of pending.busy (Run:busyTick) counts from here
	pending.queuedAt = time;
	run.actions = run.actions + 1;
	table.insert(run.starts, time);
	run.pending = pending;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroLine", op.line, op.desc);
end

-- the levels and the excluded skills of the server (wave 1): true when the action may go on, else the macro ended
local function skillLimits(run, op)
	local maxLevels = AutoPilotMoon.Sandbox:getInteger("MacroLevelsPerRun");
	local excluded = Run:excludedSkills();

	for i, perk in ipairs(op.perks or {})
	do
		local id = perk:getId();

		if excluded[string.lower(id)]
		then
			fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_Excluded", perk:getName()));

			return false;
		end

		if maxLevels > 0 and run.levelStart[id] and run.player:getPerkLevel(perk) - run.levelStart[id] >= maxLevels
		then
			finish(run, whyText("IGUI_AutoPilot_A_MacroDoneLevels", maxLevels, perk:getName()));

			return false;
		end
	end

	return true;
end

-- the action at frame.pc: limits, choice, start
local function act(run, frame, op)
	local maxActions, maxLoops, perMinute = limits();
	local time = now();

	if run.actions >= maxActions
	then
		finish(run, whyText("IGUI_AutoPilot_A_MacroDoneLimit", maxActions));

		return;
	end

	if not skillLimits(run, op)
	then
		return;
	end

	-- the actions of the last minute (a pause, never a stop, 5.4)
	local starts = run.starts;

	while #starts > 0 and time - starts[1] >= 60000
	do
		table.remove(starts, 1);
	end

	while #starts > perMinute
	do
		table.remove(starts, 1);
	end

	if #starts >= perMinute
	then
		local seconds = math.ceil((starts[1] + 60000 - time) / 1000);

		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroRate", seconds);

		return;
	end

	if op.bench
	then
		actAtBench(run, frame, op, time);

		return;
	end

	-- an action away from the bench: the bench is left to the others, as closing its window
	Bench():release(run);

	if Items():handles(op.kind)
	then
		actItems(run, frame, op, time);

		return;
	end

	if op.kind ~= "craft"
	then
		local pending, why, kind = Body():start(run, op);

		if pending == nil
		then
			if kind == "skip"
			then
				-- nothing to do (rest() already rested): the line after, no action counted
				frame.pc = frame.pc + 1;
			elseif kind == "wait"
			then
				-- eat() / drink(): the containers within reach asked for, their contents awaited (the step comes again)
				return;
			elseif kind == "nothing" and op.possibleFirst
			then
				finish(run, whyText("IGUI_AutoPilot_A_MacroDoneCannot", op.desc));
			else
				fail(run, op, why);
			end

			return;
		end

		pending.op = op;
		pending.frame = frame;
		pending.queuedAt = time;
		run.actions = run.actions + 1;
		table.insert(starts, time);
		run.pending = pending;
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroLine", op.line, op.desc);

		return;
	end

	local recipe, item, reason, about = Run:choose(run.player, op);

	if recipe == nil
	then
		-- "while possible" ends well when the materials are over; a recipe not known yet is a reason to say instead
		if op.possibleFirst and (reason == "noitem" or (reason == "refused" and not notKnown(run.player, about)))
		then
			finish(run, whyText("IGUI_AutoPilot_A_MacroDoneCannot", recipeName(about)));
		else
			fail(run, op, reasonText(op, reason, about, run.player));
		end

		return;
	end

	-- the state of what the recipe keeps, before it (A0.1): the confirmation of a repair or a sharpening
	local kept = Run:keptState(run.player, recipe, item);
	local action = AutoPilotMoon.Craft:queueAction(run.player, recipe, item);

	if action == nil
	then
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_NotQueued", recipeName(recipe)));

		return;
	end

	Run:addDrainables(kept, action);
	action.autopilotMacro = true;
	run.actions = run.actions + 1;
	table.insert(starts, time);
	run.pending = Run:craftPending(run, action, item, recipe, op, frame, kept);
	run.pending.queuedAt = time;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroLine", op.line, op.desc);
end

-- ============================================================================================================
-- The recipes that keep their item (A0.1, wave 0, 13/11/2026): a repair or a sharpening uses up nothing whole and
-- makes nothing new (recipes_fixing.txt: the item mode:keep, the tape used only in part); the game's recipe code
-- (RecipeCodeOnCreate.genericFixer / sharpenBladeGeneric of the 42.22 jar) changes the kept item instead: its
-- condition (up, or down by 1 when it fails), its sharpness, the count of its repairs. So a recipe counts as done also
-- when, since it was queued: the experience grew in a skill the recipe gives (only once the game's perform came: an
-- earlier action's experience arriving late from the server never counts), the kept item's condition, sharpness or
-- repairs changed, or a drainable it used (tape, glue) has fewer uses or is gone.
-- ============================================================================================================

local function recipeXp(player, recipe)
	local total = 0;

	for i, perk in ipairs(AutoPilotMoon.Macro.Names:xpPerks(recipe))
	do
		total = total + player:getXp():getXP(perk);
	end

	return total;
end

local function itemStateOf(item)
	local sharpness = nil;

	if item:hasSharpness()
	then
		sharpness = item:getSharpness();
	end

	return item:getCondition(), sharpness, item:getHaveBeenRepaired();
end

-- the state of the item a recipe is started on, and the experience of its skills
function AutoPilotMoon.Macro.Run:keptState(player, recipe, item)
	local state = { xp = recipeXp(player, recipe), drains = {} };
	local ok, condition, sharpness, repaired = pcall(itemStateOf, item);

	if ok
	then
		state.condition, state.sharpness, state.repaired = condition, sharpness, repaired;
	end

	return state;
end

local function inputItemsOf(action)
	local list = {};
	local items = action.items;

	if items
	then
		for i = 0, items:size() - 1
		do
			table.insert(list, items:get(i));
		end
	end

	return list;
end

-- the drainables among the items the game chose for the recipe (ISHandcraftAction.items: getAllInputItems of its
-- logic) and their uses now
function AutoPilotMoon.Macro.Run:addDrainables(state, action)
	local ok, items = pcall(inputItemsOf, action);

	for i, item in ipairs(ok and items or {})
	do
		if instanceof(item, "DrainableComboItem")
		then
			table.insert(state.drains, { item = item, id = item:getID(), uses = item:getCurrentUsesFloat() });
		end
	end
end

-- what the recipe keeps changed since it was queued (see above)
function AutoPilotMoon.Macro.Run:keptChanged(player, pending)
	local state = pending.kept;

	if state == nil
	then
		return false;
	end

	if pending.performed and recipeXp(player, pending.recipe) > state.xp + 0.0001
	then
		return true;
	end

	local inventory = player:getInventory();
	local item = inventory:getItemWithIDRecursiv(pending.itemId) or pending.item;

	if state.condition ~= nil
	then
		local ok, condition, sharpness, repaired = pcall(itemStateOf, item);

		if ok and (condition ~= state.condition or repaired ~= state.repaired
			or (sharpness ~= nil and state.sharpness ~= nil and math.abs(sharpness - state.sharpness) > 0.0001))
		then
			return true;
		end
	end

	for i, drain in ipairs(state.drains)
	do
		local now = inventory:getItemWithIDRecursiv(drain.id);

		if now == nil and drain.item:getContainer() == nil
		then
			return true;
		end

		if (now or drain.item):getCurrentUsesFloat() < drain.uses - 0.0001
		then
			return true;
		end
	end

	return false;
end

-- the ids of the items the game chose for the recipe (ISHandcraftAction.items), as a set
local function inputIds(action)
	local ids = {};
	local ok, items = pcall(inputItemsOf, action);

	for i, item in ipairs(ok and items or {})
	do
		ids[item:getID()] = true;
	end

	return ids;
end

-- The pending recipe and its wait (1.2.1, "wait for the object"), made when the recipe is QUEUED: done when one of
--   - the item clicked is used up: by id, not in the inventory, not on the 3x3 at the character's feet, not in the
--     container it was in (an item on the floor sits in the loot window's floor list, which the game never empties:
--     1.2.0 looked at its container and never saw it used up)
--   - something new, in the inventory or on the 3x3 at the feet (Actions.addOrDropItem lays there what does not fit),
--     whose id was not there when the recipe was queued (the recipe's own materials and tools excluded: a material
--     moved in from a container nearby keeps its id). 1.2.0 took this photo at the client's perform, which in
--     multiplayer comes after the outputs arrived: a recipe that gives no experience was "not done"
--   - what the recipe keeps changed (Run:keptChanged)
function AutoPilotMoon.Macro.Run:craftPending(run, action, item, recipe, op, frame, kept)
	local player = run.player;
	local pending = { kind = "craft", action = action, item = item, itemId = item:getID(), recipe = recipe, op = op,
		frame = frame, performed = false, kept = kept };
	local exclude = inputIds(action);
	local wait = AutoPilotMoon.Wait:new(player, { label = recipeName(recipe) });

	exclude[item:getID()] = true;
	wait:expectAny({
		AutoPilotMoon.Wait.make.gone(player, item, { square = player:getSquare(), container = item:getContainer() }),
		AutoPilotMoon.Wait.make.new(player, nil, { floor = true, exclude = exclude }, 1),
		AutoPilotMoon.Wait.make.isTrue(player, function()
			return Run:keptChanged(player, pending);
		end),
	});
	pending.wait = wait;

	return pending;
end

-- the time the character has been idle since the action ended (a gap: the auto-rest, a pause, restarts it)
function AutoPilotMoon.Macro.Run:idleFor(pending)
	local time = now();

	if pending.lastSeen == nil or time - pending.lastSeen > AutoPilotMoon.Wait.idleGapMs
	then
		pending.idleSince = time;
	end

	pending.lastSeen = time;

	return time - pending.idleSince;
end

-- the character is idle again after a recipe: done, still waiting for the server, or a stop
local function confirmCraft(run, pending)
	local op = pending.op;

	if pending.interrupted and not pending.performed
	then
		pending.wait:cancel();
		fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_Interrupted"));

		return;
	end

	local answer = pending.wait:check();

	if answer == "busy"
	then
		return;
	end

	if answer == "done"
	then
		run.pending = nil;
		actionDone(run, pending.frame, pending);

		return;
	end

	fail(run, op, whyText("IGUI_AutoPilot_A_MacroR_NoEffect", recipeName(pending.recipe)));
end

local function confirm(run)
	local pending = run.pending;

	-- the walk to a bench is over (the character is idle again): the same action again, now near it
	if pending.kind == "walk"
	then
		run.pending = nil;

		return;
	end

	if pending.kind == "craft"
	then
		confirmCraft(run, pending);

		return;
	end

	local answer, text = nil, nil;

	if pending.module == "items"
	then
		answer, text = Items():confirm(run, pending);
	else
		answer, text = Body():confirm(run, pending);
	end

	if answer == "done"
	then
		AutoPilotMoon.Progress:setWaiting(false);
		run.pending = nil;
		actionDone(run, pending.frame, pending);
	elseif answer == "fail"
	then
		AutoPilotMoon.Progress:setWaiting(false);
		fail(run, pending.op, text);
	end
end

-- the "when" blocks, in a pause of the macro itself (never inside another "when"): the first whose condition is true
-- starts; false when the macro stopped. states: the pass's states (16.2). The guard (3.8.1), between two actions of the
-- macro itself: Run.handlerInRow starts doing nothing, Run.handlerActsInRow starts that did an action (actionDone);
-- the start after them stops the macro at the line of the "when"
local function checkHandlers(run, states)
	if run.frame ~= run.main
	then
		return true;
	end

	for i, handler in ipairs(run.result.handlers)
	do
		if Run:evalCondition(run.player, handler.cond, states)
		then
			-- counted as a start doing nothing until an action of its block is confirmed
			handler.inRow = (handler.inRow or 0) + 1;

			if handler.inRow > Run.handlerInRow or (handler.actsInRow or 0) >= Run.handlerActsInRow
			then
				fail(run, handler, whyText("IGUI_AutoPilot_A_MacroR_HandlerLoop", Run.handlerInRow));

				return false;
			end

			handler.acted = false;
			run.frame = { ops = handler.ops, pc = 1, counters = {}, handler = handler };
			AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroWhen", handler.line);

			return true;
		end
	end

	return true;
end

-- One step (the engine's removeCheckFunction, only with the character idle): always "busy", the macro ends itself.
function AutoPilotMoon.Macro.Run:step(player)
	local run = Run.current;

	if run == nil or run.player ~= player
	then
		-- the macro of this job is not there any more: an internal error (the notifications' code "internal")
		AutoPilotMoon.Notify:code("internal");
		A:stopAll("aborted");

		return "busy";
	end

	-- the equipment of an exercise back in the hands once the game's exercise is over (as its window does)
	if run.reequip
	then
		Body():reequip(run);
	end

	if run.pending
	then
		confirm(run);

		return "busy";
	end

	-- real minutes of a run (MacroMinutesPerRun, 0 = none): the macro ends between two actions
	local maxMinutes = AutoPilotMoon.Sandbox:getInteger("MacroMinutesPerRun");

	if maxMinutes > 0 and now() - run.startedAt >= maxMinutes * 60000
	then
		finish(run, whyText("IGUI_AutoPilot_A_MacroDoneMinutes", maxMinutes));

		return "busy";
	end

	-- the states of this pass: every condition of the step reads the same snapshot (16.2)
	local states = Run:newStates(player);

	if not checkHandlers(run, states)
	then
		return "busy";
	end

	local time = now();

	for budget = 1, Run.maxControlOps
	do
		local frame = run.frame;

		if Run.current ~= run
		then
			return "busy";
		end

		if frame.waitUntil
		then
			if time < frame.waitUntil
			then
				AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroWait", math.ceil((frame.waitUntil - time) / 1000));

				return "busy";
			end

			frame.waitUntil = nil;
			frame.pc = frame.pc + 1;
		end

		local ops = frame.ops;
		local op = ops[frame.pc];

		if op == nil
		then
			if frame == run.main
			then
				-- the end of the text: no reason to say, the notifications' code "MacroDone"
				AutoPilotMoon.Notify:code("MacroDone");
				finish(run, nil);

				return "busy";
			end

			-- the "when" is over: the macro goes on where it was. When its block did something (an action confirmed,
			-- handler.acted), its end is a pause of its own (26/11/2026, the integration of 1.6.0): the "when" blocks
			-- are looked at again, the first true one starts (the same one too: have_fun() reads one thing a start,
			-- eat() of small foods), with the states of this step, taken after that action. Without it the macro
			-- went on at once: in the recipe of ANALISI-AUTONOMIA.md 4 a meal at the fridge, the walk back and a
			-- smoke() left exercise() to start exhausted (the game's refusal stopped the macro) instead of rest().
			-- A block that did nothing goes on as before (it never starts again in the same step).
			run.frame = run.main;

			if frame.handler and frame.handler.acted and not checkHandlers(run, states)
			then
				return "busy";
			end
		elseif op.op == "ACTION"
		then
			act(run, frame, op);

			return "busy";
		elseif op.op == "WAIT"
		then
			frame.waitUntil = time + op.ms;
			AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroWait", op.seconds);

			return "busy";
		elseif op.op == "LOOP"
		then
			frame.counters[frame.pc] = 0;

			if not iterate(run, frame, frame.pc, states)
			then
				return "busy";
			end
		elseif op.op == "END"
		then
			if not iterate(run, frame, op.loopIndex, states)
			then
				return "busy";
			end
		elseif op.op == "STOPIF"
		then
			if Run:evalCondition(player, op.cond, states)
			then
				finish(run, whyText(op.plain and "IGUI_AutoPilot_A_MacroDoneStop" or "IGUI_AutoPilot_A_MacroDoneStopIf", op.line), op.line);

				return "busy";
			end

			frame.pc = frame.pc + 1;
		elseif op.op == "IF"
		then
			if Run:evalCondition(player, op.cond, states)
			then
				frame.pc = frame.pc + 1;
			else
				frame.pc = op.falseTarget;
			end
		elseif op.op == "JUMP"
		then
			frame.pc = op.target;
		else
			frame.pc = frame.pc + 1;
		end
	end

	return "busy";
end

-- A check with the character busy (contract C3 of ANALISI-AUTONOMIA.md 5, 3.8.2): the engine's step runs only with the
-- character idle, so an action that never ends (a walk "in progress" forever, an exercise past the server's 30 real
-- minutes) is looked at here, at every frame the character is doing something. The contract of the actions:
--   pending.busy = function(run, pending, busyMs) return nil --[[ or "stop" ]] end
-- busyMs: how long the character has been busy with the action, from when the step queued it (pending.queuedAt; the
-- first busy frame for a pending without it); "stop": the engine clears the actions the macro queued
-- (ISTimedActionQueue.clear: the game's StopAllActionQueue and the queue emptied, as the engine's stops do) and the
-- step with the character idle confirms as always (the action's module knows why: it answered "stop"). A pending that
-- answered "stop" is never asked again; while the character stays busy (an action the game still keeps going) the
-- queue is cleared again every Run.busyClearMs. Called only with the character busy (checkMacroQueue): never between
-- two actions, never during the engine's auto-rest. Returns "stop" when it cleared the queue, else nil.
Run.busyClearMs = 1000;

function AutoPilotMoon.Macro.Run:busyTick(player)
	local run = Run.current;
	local pending = run and run.player == player and run.pending or nil;

	if pending == nil or type(pending.busy) ~= "function"
	then
		return nil;
	end

	local time = now();

	if pending.busyStopped
	then
		if time - pending.busyStopped < Run.busyClearMs
		then
			return nil;
		end
	else
		if pending.busySince == nil
		then
			pending.busySince = pending.queuedAt or time;
		end

		if pending.busy(run, pending, time - pending.busySince) ~= "stop"
		then
			return nil;
		end
	end

	pending.busyStopped = time;
	ISTimedActionQueue.clear(player);

	return "stop";
end

-- the engine's names (Automation:register("macro"): checkMacroQueue, stopMacro)
function AutoPilotMoon.Automation:checkMacroQueue(player)
	if ISTimedActionQueue.isPlayerDoingAction(player)
	then
		Run:busyTick(player);
	end

	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "macroWorking",
		removeCheckFunction = function(square, who)
			return Run:step(who);
		end,
	});
end

function AutoPilotMoon.Automation:stopMacro()
	local run = Run.current;

	Run.current = nil;

	if run and not run.ended
	then
		-- stopped by the engine (the player, zombies, the server's switch...)
		local reason = A.stopReason;

		Run.last = { name = run.name, reason = reason, text = A.stopText or A:getReasonText(reason) };
	end

	if run and Body()
	then
		Body():onStop(run);
	end

	-- the bench is left at every end and stop, as closing its window
	if run and Bench()
	then
		Bench():release(run);
	end

	AutoPilotMoon.Automation:stopSquareProcessingQueue("macroWorking");
end

-- the macro running now (nil: none)
function AutoPilotMoon.Macro.Run:getRunningName()
	return Run.current and Run.current.name or nil;
end

-- the line the macro is at (the editor's ">")
function AutoPilotMoon.Macro.Run:getRunningLine()
	local run = Run.current;
	local frame = run and run.frame;
	local op = run and (run.pending and run.pending.op or (frame and frame.ops[frame.pc]));

	if op == nil and frame and frame.handler
	then
		return frame.handler.line;
	end

	return op and op.line or nil;
end

-- "Adesso si puo' fare?" (4.5): the first action the macro would do, tried without queueing anything. Returns the line
-- and nil (yes) or the reason's text; nil when the macro has no action. A third value, with yes: what it would do
-- (eat(), drink(), refill(): "mangera' Mela da Frigo", 20/11/2026).
function AutoPilotMoon.Macro.Run:probe(player, result)
	for i, op in ipairs(result.ops)
	do
		if op.op == "ACTION"
		then
			if Items():handles(op.kind)
			then
				return op.line, Items():probe(player, op);
			end

			if op.kind ~= "craft"
			then
				return op.line, Body():probe(player, op);
			end

			if op.withTypes and op.withSet == nil
			then
				op.withSet = {};

				for j, fullType in ipairs(op.withTypes)
				do
					op.withSet[fullType] = true;
				end
			end

			if op.bench
			then
				return op.line, Run:probeBench(player, op);
			end

			local recipe, item, reason, about = Run:choose(player, op);

			if recipe
			then
				return op.line, nil;
			end

			if reason == "noitem" and op.work
			then
				return op.line, getText(op.work == "sharpen" and "IGUI_AutoPilot_E_NowNothingToSharpen" or "IGUI_AutoPilot_E_NowNothingToRepair", op.itemText);
			elseif reason == "refused" and notKnown(player, about)
			then
				return op.line, getText("IGUI_AutoPilot_E_NowNotKnown", AutoPilotMoon.Macro.Names:learnHint(about));
			elseif reason == "noitem" and op.withText
			then
				return op.line, getText("IGUI_AutoPilot_E_NowNoItem", op.withText);
			elseif reason == "dark"
			then
				return op.line, getText("IGUI_AutoPilot_E_NowDark");
			elseif reason == "surface"
			then
				return op.line, getText("IGUI_AutoPilot_E_NowSurface");
			end

			return op.line, getText("IGUI_AutoPilot_E_NowRefused");
		end
	end

	return nil, nil;
end

-- "Adesso si puo' fare?" for an action at a bench: the server's switch, a bench within the distance, a friend at it,
-- then the recipe with the bench's logic (nothing queued, no walk, the bench not marked): nil = yes, else why
function AutoPilotMoon.Macro.Run:probeBench(player, op)
	local B = Bench();

	if not B:isEnabled()
	then
		return getText("IGUI_AutoPilot_E_NowBenchesOff");
	end

	local list = B:find(player, Run:center(player), op.benchSet, op.recipes);

	if #list == 0
	then
		return getText("IGUI_AutoPilot_E_NowNoBench", B:opText(op), B:radius());
	end

	local bench, user = B:firstFree(list, player);

	if bench == nil
	then
		return getText("IGUI_AutoPilot_E_NowBenchBusy", B:playerName(user));
	end

	local recipe, item, reason, about = Run:chooseAtBench(player, op, bench);

	if recipe
	then
		return nil;
	end

	if reason == "refused" and notKnown(player, about)
	then
		return getText("IGUI_AutoPilot_E_NowNotKnown", AutoPilotMoon.Macro.Names:learnHint(about));
	elseif reason == "noitem" and op.withText
	then
		return getText("IGUI_AutoPilot_E_NowNoItem", op.withText);
	elseif reason == "dark"
	then
		return getText("IGUI_AutoPilot_E_NowDark");
	elseif reason == "fuel"
	then
		return getText("IGUI_AutoPilot_E_NowNoFuel");
	end

	return getText("IGUI_AutoPilot_E_NowRefused");
end

AutoPilotMoon.Automation:register("macro", {
	unitKey = "IGUI_AutoPilot_S_Unit_Actions",
	limit = function()
		return AutoPilotMoon.Sandbox:getInteger("MacroActionsPerRun");
	end,
	announceStart = Run.announceStart,
	announceStop = Run.announceStop,
	unwellLevel = Run.unwellLevel,
	autoRest = Run.autoRest,
});

-- ============================================================================================================
-- The hooks on the game's recipe action (ISHandcraftAction of 42.22: perform, stop)
-- ============================================================================================================

-- the ids of the inventory and of the items at the character's feet, into a table (wiped first)
function AutoPilotMoon.Macro.Hooks:snapshot(player, ids)
	table.wipe(ids);

	local items = player:getInventory():getAllEvalRecurse(function(item)
		return true;
	end);

	for i = 0, items:size() - 1
	do
		ids[items:get(i):getID()] = true;
	end

	local square = player:getSquare();
	local objects = square and square:getWorldObjects();

	if objects
	then
		for i = 0, objects:size() - 1
		do
			local item = objects:get(i):getItem();

			if item
			then
				ids[item:getID()] = true;
			end
		end
	end

	return ids;
end

-- just before the game's perform: what the macro and the recorder need to know (read only)
function AutoPilotMoon.Macro.Hooks.beforePerform(action)
	local token = nil;
	local run = Run.current;

	if action.autopilotMacro and run and run.pending and run.pending.action == action
	then
		run.pending.performed = true;
		token = "run";
	end

	local recorder = AutoPilotMoon.Macro.Recorder;

	if not action.autopilotMacro and recorder and recorder:isRecordingFor(action.character)
	then
		token = recorder:beforePerform(action);
	end

	return token;
end

function AutoPilotMoon.Macro.Hooks.afterPerform(action, token)
	local recorder = AutoPilotMoon.Macro.Recorder;

	if type(token) == "table" and recorder
	then
		recorder:afterPerform(action, token);
	end
end

-- after the game's stop: an action of the macro interrupted (cancelled, stopped by the dark)
function AutoPilotMoon.Macro.Hooks.afterStop(action)
	local run = Run.current;

	if action.autopilotMacro and run and run.pending and run.pending.action == action
	then
		run.pending.interrupted = true;
	end
end

function AutoPilotMoon.Macro.Hooks.perform(self)
	local token = nil;

	if self.autopilotMacro or (AutoPilotMoon.Macro.Recorder and AutoPilotMoon.Macro.Recorder.session)
	then
		local ok, result = pcall(Hooks.beforePerform, self);

		if ok
		then
			token = result;
		end
	end

	Hooks.gamePerform(self);

	if token
	then
		pcall(Hooks.afterPerform, self, token);
	end
end

function AutoPilotMoon.Macro.Hooks.stop(self)
	Hooks.gameStop(self);

	if self.autopilotMacro
	then
		pcall(Hooks.afterStop, self);
	end
end

-- When the player's master switch turns on (client/06_AP_Switch.lua: at OnGameStart when it is already on, after the
-- other mods; or later from the Options): the class uses self.__index = self, so the methods hold for every action.
-- Never a second time while ours is in the chain: a mod that wrapped perform after us calls ours; taking its wrapper
-- as the game's would make ours call it again, without end (every recipe by hand would fail).
function AutoPilotMoon.Macro.Hooks:install()
	local class = rawget(_G, "ISHandcraftAction");

	if Hooks.installed or class == nil or class.perform == Hooks.perform
	then
		return;
	end

	Hooks.installed = true;
	Hooks.gamePerform = class.perform;
	Hooks.gameStop = class.stop;
	class.perform = Hooks.perform;
	class.stop = Hooks.stop;
end

-- When the master switch turns off: the game's methods back, only if they are still ours. When another mod wrapped
-- them after us, ours stays in its chain (taking it out would drop that mod's wrapper) and only calls the game's: no
-- macro runs and nothing is recorded while the switch is off, so it adds nothing (Hooks.perform / Hooks.stop look only
-- at self.autopilotMacro and a recording). Installed again later, it wraps whatever is there then.
function AutoPilotMoon.Macro.Hooks:uninstall()
	local class = rawget(_G, "ISHandcraftAction");

	if not Hooks.installed or class == nil
	then
		return false;
	end

	if class.perform == Hooks.perform and class.stop == Hooks.stop
	then
		class.perform = Hooks.gamePerform;
		class.stop = Hooks.gameStop;
		Hooks.installed = false;

		return true;
	end

	return false;
end
