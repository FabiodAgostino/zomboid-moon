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
-- character's stats), waiting up to Run.confirmMs for the server, "aspetta il server..." after Run.waitingAfterMs.
-- Never a step given for done; no retry of a failed step: the macro stops and says the line and why. The server's
-- limits are read at every step: actions per run, loops per run, actions per minute (a pause, not a stop).
--
-- The hooks on the game's ISHandcraftAction (perform and stop, installed once at OnGameStart, also used by the
-- recorder): the game's method is always called, ours only reads (inside pcall, an error of ours never breaks the
-- player's recipe); the "before" snapshot of the inventory is taken just before the game's perform, because in single
-- player perform makes the recipe at once.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Run = AutoPilotMoon.Macro.Run or {};
AutoPilotMoon.Macro.Hooks = AutoPilotMoon.Macro.Hooks or {};

local Run = AutoPilotMoon.Macro.Run;
local Hooks = AutoPilotMoon.Macro.Hooks;
local A = AutoPilotMoon.Automation;

Run.maxControlOps = 64;       -- LOOP / END / STOPIF / IF / JUMP per frame at most
Run.confirmMs = 3000;         -- the action ended without a result: give up after this
Run.waitingAfterMs = 1500;    -- "aspetta il server..." from this
Run.handlerInRow = 3;         -- a "when" that runs this many times with no action of the macro between: stop
Run.severeLevel = 4;          -- a moodle a "when" looks after stops the macro only at this level (11.4)
-- the engine's "unwell" moodles a "when" can look after (eat, drink, stop calmly...): the others (injured, bleeding)
-- always stop at the engine's level, nothing in the language treats a wound
Run.relaxable = { HUNGRY = true, THIRST = true, PANIC = true };
Run.current = nil;            -- the running macro
Run.last = nil;               -- how the last run ended, for the editor: { name, reason, line, text }
Run.beforeIds = {};           -- the ids of the inventory (and of the items at the feet) at the action's perform

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

-- ============================================================================================================
-- Conditions (2.2, 11.2): the character's inventory (bags and favourites included), a skill's level, the moodles
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

-- endurance and the smoker's craving in percent (0-100)
function AutoPilotMoon.Macro.Run:percent(player, name)
	if name == "endurance"
	then
		return AutoPilotMoon.Rest:getEndurancePercent(player);
	end

	local stats = player:getStats();
	local stat = CharacterStat.NICOTINE_WITHDRAWAL;

	if stats == nil or stat == nil
	then
		return 0;
	end

	return math.floor((stats:get(stat) or 0) / 0.51 * 100 + 0.5);
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

local function value(player, node)
	local k = node.k;

	if k == "num"
	then
		return node.v;
	elseif k == "moodle"
	then
		return Run:moodleLevel(player, node.name);
	elseif k == "percent"
	then
		return Run:percent(player, node.name);
	elseif k == "count"
	then
		return Run:countItems(player, node.types);
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

function AutoPilotMoon.Macro.Run:evalCondition(player, cond)
	local k = cond.k;

	if k == "const"
	then
		return cond.v == true;
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
	elseif k == "not"
	then
		return not Run:evalCondition(player, cond.a);
	elseif k == "and"
	then
		return Run:evalCondition(player, cond.a) and Run:evalCondition(player, cond.b);
	elseif k == "or"
	then
		return Run:evalCondition(player, cond.a) or Run:evalCondition(player, cond.b);
	elseif k == "cmp"
	then
		local a = value(player, cond.a);
		local b = value(player, cond.b);
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

-- why an action does not start, in words (5.3)
local function reasonText(op, reason, recipe, player)
	local name = recipeName(recipe);

	if reason == "dark"
	then
		return getText("IGUI_AutoPilot_A_MacroR_Dark", name);
	elseif reason == "surface"
	then
		return getText("IGUI_AutoPilot_A_MacroR_Surface", name);
	elseif reason == "noitem" and op.work
	then
		-- repair() / sharpen(): nothing damaged, nothing to sharpen (favourites never)
		return getText(op.work == "sharpen" and "IGUI_AutoPilot_A_MacroR_NothingToSharpen" or "IGUI_AutoPilot_A_MacroR_NothingToRepair", op.itemText);
	elseif reason == "noitem" and op.withText
	then
		return getText("IGUI_AutoPilot_A_MacroR_NoItem", op.withText);
	elseif reason == "refused" and notKnown(player, recipe)
	then
		return getText("IGUI_AutoPilot_A_MacroR_NotKnown", name, AutoPilotMoon.Macro.Names:learnHint(recipe));
	end

	return getText("IGUI_AutoPilot_A_MacroR_Refused", name);
end

-- "smonta Martello a granchio" / "crea Assembla utensile medio" / "flessioni, 10 minuti" (the panel's "Ora:" line)
local function describe(op)
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

-- checks a macro's text for a player with the server's limits of now
function AutoPilotMoon.Macro.Run:check(player, text)
	local maxActions, maxLoops = limits();

	return AutoPilotMoon.Macro.Lang:check(text, AutoPilotMoon.Macro.Names, { player = player, maxActions = maxActions, maxLoops = maxLoops });
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

	local result = Run:check(player, macro.text);
	local refusal = Run:getStartRefusal(player, result);

	if refusal
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", getText("IGUI_AutoPilot_O_Context_Macro"), refusal), player);

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
		outer = nil,
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
local function finish(run, endText)
	run.ended = true;
	Run.last = { name = run.name, reason = "done", endText = endText, shortText = shortSummary(run) };
	A:stopAll("done");
end

-- the macro stops at a line with a reason (5.3)
local function fail(run, op, text)
	run.ended = true;
	Run.last = { name = run.name, reason = "because", line = op.line, text = text };
	A:stopBecause(getText("IGUI_AutoPilot_A_MacroLine", op.line, text));
end

Run.finish = finish;
Run.fail = fail;

-- ============================================================================================================
-- The step
-- ============================================================================================================

-- a new turn of the loop at index i of the frame, or out of it; false when the macro ended (the loops' limit)
local function iterate(run, frame, i)
	local op = frame.ops[i];
	local go = false;

	if op.mode == "times"
	then
		go = (frame.counters[i] or 0) < op.n;
	elseif op.mode == "while"
	then
		go = Run:evalCondition(run.player, op.cond);
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
		finish(run, getText("IGUI_AutoPilot_A_MacroDoneLoops", maxLoops));

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

-- an action of the frame done and confirmed: counted, the line after
local function actionDone(run, frame)
	frame.pc = frame.pc + 1;
	AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_MacroActions", 1);
	AutoPilotMoon.Progress:addUnitsDone(1);

	-- an action of the macro itself: every "when" may run again three times
	if frame == run.main
	then
		for i, handler in ipairs(run.result.handlers)
		do
			handler.inRow = 0;
		end
	end

	local xp = experience(run, false);

	AutoPilotMoon.Progress:setDoneText(#xp > 0 and table.concat(xp, " - ") or nil);
end

-- the action at frame.pc: limits, choice, start
local function act(run, frame, op)
	local maxActions, maxLoops, perMinute = limits();
	local time = now();

	if run.actions >= maxActions
	then
		finish(run, getText("IGUI_AutoPilot_A_MacroDoneLimit", maxActions));

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

	if op.kind ~= "craft"
	then
		local pending, why, kind = Body():start(run, op);

		if pending == nil
		then
			if kind == "skip"
			then
				-- nothing to do (rest() already rested): the line after, no action counted
				frame.pc = frame.pc + 1;
			elseif kind == "nothing" and op.possibleFirst
			then
				finish(run, getText("IGUI_AutoPilot_A_MacroDoneCannot", op.desc));
			else
				fail(run, op, why);
			end

			return;
		end

		pending.op = op;
		pending.frame = frame;
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
			finish(run, getText("IGUI_AutoPilot_A_MacroDoneCannot", recipeName(about)));
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
		fail(run, op, getText("IGUI_AutoPilot_A_MacroR_NotQueued", recipeName(recipe)));

		return;
	end

	Run:addDrainables(kept, action);
	action.autopilotMacro = true;
	run.actions = run.actions + 1;
	table.insert(starts, time);
	run.pending = { kind = "craft", action = action, item = item, itemId = item:getID(), recipe = recipe, op = op, frame = frame,
		performed = false, kept = kept };
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

-- something new in the inventory, or at the character's feet, since the action's perform
local function hasNew(run)
	local before = Run.beforeIds;
	local items = run.player:getInventory():getAllEvalRecurse(function(item)
		return before[item:getID()] == nil;
	end);

	if items:size() > 0
	then
		return true;
	end

	local square = run.player:getSquare();
	local objects = square and square:getWorldObjects();

	if objects
	then
		for i = 0, objects:size() - 1
		do
			local item = objects:get(i):getItem();

			if item and before[item:getID()] == nil
			then
				return true;
			end
		end
	end

	return false;
end

-- the time the character has been idle since the action ended (a gap: the auto-rest, a pause, restarts it)
function AutoPilotMoon.Macro.Run:idleFor(pending)
	local time = now();

	if pending.lastSeen == nil or time - pending.lastSeen > 500
	then
		pending.idleSince = time;
	end

	pending.lastSeen = time;

	return time - pending.idleSince;
end

-- the character is idle again after a recipe: done, still waiting for the server, or a stop
local function confirmCraft(run, pending)
	local waited = Run:idleFor(pending);
	local op = pending.op;

	if pending.interrupted and not pending.performed
	then
		AutoPilotMoon.Progress:setWaiting(false);
		fail(run, op, getText("IGUI_AutoPilot_A_MacroR_Interrupted"));

		return;
	end

	local inventory = run.player:getInventory();
	local consumed = inventory:getItemWithIDRecursiv(pending.itemId) == nil and pending.item:getContainer() == nil;

	if consumed or (pending.performed and hasNew(run)) or Run:keptChanged(run.player, pending)
	then
		AutoPilotMoon.Progress:setWaiting(false);
		run.pending = nil;
		actionDone(run, pending.frame);

		return;
	end

	if waited < Run.confirmMs
	then
		if waited >= Run.waitingAfterMs
		then
			AutoPilotMoon.Progress:setWaiting(true);
		end

		return;
	end

	AutoPilotMoon.Progress:setWaiting(false);
	fail(run, op, getText("IGUI_AutoPilot_A_MacroR_NoEffect", recipeName(pending.recipe)));
end

local function confirm(run)
	local pending = run.pending;

	if pending.kind == "craft"
	then
		confirmCraft(run, pending);

		return;
	end

	local answer, text = Body():confirm(run, pending);

	if answer == "done"
	then
		AutoPilotMoon.Progress:setWaiting(false);
		run.pending = nil;
		actionDone(run, pending.frame);
	elseif answer == "fail"
	then
		AutoPilotMoon.Progress:setWaiting(false);
		fail(run, pending.op, text);
	end
end

-- the "when" blocks, in a pause of the macro itself (never inside another "when"): the first whose condition is true
-- starts; false when the macro stopped
local function checkHandlers(run)
	if run.frame ~= run.main
	then
		return true;
	end

	for i, handler in ipairs(run.result.handlers)
	do
		if Run:evalCondition(run.player, handler.cond)
		then
			handler.inRow = (handler.inRow or 0) + 1;

			if handler.inRow > Run.handlerInRow
			then
				fail(run, handler, getText("IGUI_AutoPilot_A_MacroR_HandlerLoop", Run.handlerInRow));

				return false;
			end

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

	if not checkHandlers(run)
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
				finish(run, nil);

				return "busy";
			end

			-- the "when" is over: the macro goes on where it was
			run.frame = run.main;
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

			if not iterate(run, frame, frame.pc)
			then
				return "busy";
			end
		elseif op.op == "END"
		then
			if not iterate(run, frame, op.loopIndex)
			then
				return "busy";
			end
		elseif op.op == "STOPIF"
		then
			if Run:evalCondition(player, op.cond)
			then
				finish(run, getText(op.plain and "IGUI_AutoPilot_A_MacroDoneStop" or "IGUI_AutoPilot_A_MacroDoneStopIf", op.line));

				return "busy";
			end

			frame.pc = frame.pc + 1;
		elseif op.op == "IF"
		then
			if Run:evalCondition(player, op.cond)
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

-- the engine's names (Automation:register("macro"): checkMacroQueue, stopMacro)
function AutoPilotMoon.Automation:checkMacroQueue(player)
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

	table.wipe(Run.beforeIds);
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
-- and nil (yes) or the reason's text; nil when the macro has no action.
function AutoPilotMoon.Macro.Run:probe(player, result)
	for i, op in ipairs(result.ops)
	do
		if op.op == "ACTION"
		then
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
		Hooks:snapshot(action.character, Run.beforeIds);
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
