-- AutoPilot (Moon): automations for the Moon server.

-- The body's actions of the macros (step M1.5, 12/11/2026, MACRO-AUTOPILOT.md 11): exercise, rest, eat, drink, smoke,
-- each done the way the game does it by hand, through the game's own code, so the game's refusals stay and in
-- multiplayer the server does the work (every action below is a timed action of 42.22 with "complete", run by the
-- server):
--   exercise  the Fitness window: ISFitnessUI.equipItems / ISFitnessAction / ISTimedActionQueue.addGetUpAndThen, and
--             ISFitnessUI.update to give back what was in the hands; the window's refusals with its own texts. Without
--             a type one at random among those the character can do, never the one done just before; without minutes
--             until the game stops it for fatigue (26/11/2026, ANALISI-AUTONOMIA.md 3.6)
--   rest      the "Rest" of a seat's right click: ISWorldObjectContextMenu.onRest (walk, sit on the furniture, or on
--             the ground next to it); "Sit on ground" (reportEvent("EventSitOnGround")) without a seat; up again
--             ("forceGetUp") when the endurance is back; with minutes (26/11/2026, 1.6.2, MACRO-AUTOPILOT.md 22) seated
--             that many game minutes even when rested (pain, sickness), then up (with until: then until the endurance)
--   eat       the inventory's "Eat": ISInventoryPaneContextMenu.eatItem (and "Open and Eat" for a can), for the food
--             carried or within reach (MacroFood.lua, 20/11/2026: the loot window's containers, the game moves the food
--             into the inventory and what is left back)
--   drink     the inventory's "Drink": ISInventoryPaneContextMenu.onDrinkFluid (a bottle carried or within reach); with
--             source=True the right click's "Drink" of a sink, a barrel, a well (ISWorldObjectContextMenu.onDrink)
--   refill    the right click's "Fill" (ISWorldObjectContextMenu.onTakeWater): the bottles carried, at a clean source
--   smoke     the inventory's "Smoke": eatItem for a cigarette, takePill for a pack; a fire as the menu asks for it
-- Every action counts only when the character shows it (stats, the item gone, sitting), with the engine's wait
-- (AutoPilotMoon.Wait, 1.2.1): the game's actions watched from the moment they are queued (a refusal of the server, an
-- action the game did not queue: said at once), the effect looked at with the character idle up to Wait.timeoutMs
-- ("Open and Eat": Body.canConfirmMs, the meal is queued by a command of the server that is not ordered with the rest);
-- the item read by its id (the game moves a bottle, a pack or a book from a bag into the inventory and back: in
-- multiplayer another object each time).
--
-- Body:start(run, op) -> pending, or nil + reason text + "nothing" (nothing to eat / drink / smoke: a "while
--   possible" ends well) / "skip" (nothing to do: already rested) / "wait" (the containers within reach not arrived
--   from the server yet: the step comes again) / nil (a refusal: the macro stops)
-- Body:confirm(run, pending) -> "busy" / "done" / "fail", text   (only with the character idle)
-- Body:probe(player, op) -> nil (it can be done now) and what it would do (food and water, the exercise chosen at
--   random), or the reason's text ("Adesso si puo' fare?")
-- Body:pickExercise(player, run) -> the exercise exercise() without a type does now, or nil (none the character can do);
--   Body:exerciseMinutes(op) -> the game minutes given to ISFitnessAction; Body:restMinutesMs(op) -> the real ms of
--   rest(minutes=N), from the server's day length, nil without minutes; Body:minutesText(n) -> "5 minuti" / "1 minuto"
-- Body:describe(op, exercise) -> the panel's "Ora:" text (exercise: the one chosen at random, else op's)
-- Body:hasFood(player, op), Body:hasDrink(player, op), Body:hasSmoke(player, op) -> the conditions has_food(),
--   has_drink(), has_smoke()
-- Body:register(kind, { start, effect, failure, probe, describe }) (26/11/2026, contract C2 of ANALISI-AUTONOMIA.md 5):
--   a body action written in another file (have_fun: MacroFun.lua); start(run, op) answers as the starts here,
--   effect(run, pending) -> true when done, failure(run, pending, why) -> the reason's text (whyText), probe(player, op)
--   as Body:probe, describe(op) -> the panel's "Ora:" text
-- eat() / drink(): a choice with far (an entry of MacroNear.lua, ANALISI-AUTONOMIA.md 3.5) walks there first
--   (Near:approach: the step comes again), then the line starts again within reach

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Body = AutoPilotMoon.Macro.Body or {};

local Body = AutoPilotMoon.Macro.Body;

Body.seatRadius = 8;            -- the nearest seat within this many squares (same floor)
Body.sitTimeoutMs = 20000;      -- idle and still not sitting after this: the macro stops
Body.restMaxMs = 600000;        -- at most 10 real minutes on a seat, then up again (the endurance may not come back);
                                -- rest(minutes=N) too: a long N on a server with long days never freezes a run
Body.restDayFallback = 60;      -- rest(minutes=N): the real minutes of a day when the game does not say (the default)
Body.standTimeoutMs = 4000;
Body.canConfirmMs = 8000;       -- "Open and Eat": the server queues the eating after the can is open (Wait's exception)
-- exercise() without minutes (26/11/2026, ANALISI-AUTONOMIA.md 3.6): until the game stops it for fatigue
-- (ISFitnessAction:update, endurance moodle above ISFitnessUI.enduranceLevelThreshold). The game is given a time that
-- does not end first but stays below the 30 real minutes after which the server no longer counts the repetitions
-- (AnimEventEmulator.getDurationMax, 1 800 000 ms): this many real minutes, in game minutes of the server's day length
Body.exerciseMaxRealMin = 20;
Body.exerciseMinMinutes = 10;   -- never less than the Fitness window offers
Body.exerciseMaxMinutes = 1440; -- never more than a day of the game
-- busy with an exercise longer than this (real time, every exercise): the mod stops the game's action and the line is
-- done (pending.busy, contract C3 of ANALISI-AUTONOMIA.md 5)
Body.exerciseMaxMs = 1500000;

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

-- the text of the reason of a stop, its key remembered for the notifications (the event's code: MacroR_CannotSit...;
-- a refusal of the game with its own text: the code "stopped" with the key in its detail)
local function whyText(key, a, b, c)
	return AutoPilotMoon.Notify:why(key, a, b, c);
end

-- a line with nothing to do, or done only in part (MacroR_NoSeat, MacroR_NotThirsty, MacroR_AllFull,
-- MacroR_AlreadyReadNext, MacroR_FilledPart): said over the head, and a warning of the summary for the notifications
local function note(player, code, text, fields)
	AutoPilotMoon:say("info", text, player);
	fields.text = text;
	AutoPilotMoon.Notify:emit("warn", code, fields);
end

-- ============================================================================================================
-- Texts
-- ============================================================================================================

-- "5 minuti", "1 minuto" (rest(minutes=N), 1.6.2: the panel's texts of the seated wait)
function AutoPilotMoon.Macro.Body:minutesText(n)
	if n == 1
	then
		return getText("IGUI_AutoPilot_P_Now_MacroMinutesOne");
	end

	return getText("IGUI_AutoPilot_P_Now_MacroMinutes", n);
end

-- the body actions written in other files (Body:register, contract C2): kind -> { start, effect, failure, probe, describe }
local registered = {};

-- exercise: the one chosen at random for this start (exercise() without a type), else the op's own
function AutoPilotMoon.Macro.Body:describe(op, exercise)
	if registered[op.kind] and registered[op.kind].describe
	then
		return registered[op.kind].describe(op);
	end

	if op.kind == "exercise"
	then
		-- "esercizio pushups, 10 minuti" (as before 26/11/2026 with the minutes written), "esercizio squats, fino alla
		-- stanchezza", "esercizio a caso, 20 minuti" (before the choice)
		local name = exercise or op.exercise or getText("IGUI_AutoPilot_P_Now_MacroExerciseRandom");

		if op.minutes
		then
			return getText("IGUI_AutoPilot_P_Now_MacroExercise", name, op.minutes);
		end

		return getText("IGUI_AutoPilot_P_Now_MacroExerciseTired", name);
	elseif op.kind == "rest"
	then
		-- rest(minutes=N) (1.6.2): "riposa seduto per 5 minuti", with until "... per almeno 5 minuti, poi fino al 95%"
		if op.minutes and op.untilPct
		then
			return getText("IGUI_AutoPilot_P_Now_MacroRestForUntil", Body:minutesText(op.minutes), op.untilPct);
		elseif op.minutes
		then
			return getText("IGUI_AutoPilot_P_Now_MacroRestFor", Body:minutesText(op.minutes));
		end

		return getText("IGUI_AutoPilot_P_Now_MacroRest", op.untilPct);
	elseif op.kind == "eat"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroEat");
	elseif op.kind == "drink"
	then
		return getText(op.source and "IGUI_AutoPilot_P_Now_MacroDrinkSource" or "IGUI_AutoPilot_P_Now_MacroDrink");
	elseif op.kind == "refill"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroRefill");
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

local function Lang()
	return AutoPilotMoon.Macro.Lang;
end

local function exerciseData(exercise)
	local table_ = FitnessExercises and FitnessExercises.exercisesType;

	return table_ and exercise and table_[exercise] or nil;
end

-- the exercises the character can do now, in the language's order: the game's (FitnessExercises.exercisesType) whose
-- equipment it carries, as the Fitness window enables them (ISFitnessUI:addExerciseToList: contains(item, true))
function AutoPilotMoon.Macro.Body:availableExercises(player)
	local list = {};
	local inventory = player:getInventory();

	for i, exercise in ipairs(Lang().exercises)
	do
		local data = exerciseData(exercise);

		if data and (data.item == nil or inventory:contains(data.item, true))
		then
			table.insert(list, exercise);
		end
	end

	return list;
end

-- the exercise drawn for exercise() without a type and not started yet, by player number: "Adesso si puo' fare?" names
-- it and the run does that one (a draw at every look would name another one each time)
Body.drawn = {};

-- exercise() without a type: one at random (ZombRand) among those the character can do, never the one done just before
-- (run.lastExercise) when there is more than one (the stiffness spread over arms, legs and abs); nil: none
function AutoPilotMoon.Macro.Body:pickExercise(player, run)
	local list = Body:availableExercises(player);

	if #list == 0
	then
		return nil;
	end

	local last = run and run.lastExercise or nil;
	local candidates = {};

	for i, exercise in ipairs(list)
	do
		if #list == 1 or exercise ~= last
		then
			table.insert(candidates, exercise);
		end
	end

	local num = player:getPlayerNum();
	local kept = Body.drawn[num];

	for i, exercise in ipairs(candidates)
	do
		if exercise == kept
		then
			return kept;
		end
	end

	local pick = candidates[1];

	if #candidates > 1
	then
		pick = candidates[math.floor(ZombRand(#candidates)) + 1] or candidates[1];
	end

	Body.drawn[num] = pick;

	return pick;
end

-- the game minutes given to ISFitnessAction: the ones written, else Body.exerciseMaxRealMin real minutes of the
-- server's day (GameTime.getMinutesPerDay: the real minutes of a day of the game), from 10 to a day: the game stops the
-- exercise for fatigue first
function AutoPilotMoon.Macro.Body:exerciseMinutes(op)
	if op.minutes
	then
		return op.minutes;
	end

	local perDay = getGameTime():getMinutesPerDay();

	if perDay == nil or perDay <= 0
	then
		return Body.exerciseMaxMinutes;
	end

	local minutes = math.floor(Body.exerciseMaxRealMin * 1440 / perDay);

	return math.max(Body.exerciseMinMinutes, math.min(Body.exerciseMaxMinutes, minutes));
end

-- the Fitness window's refusals (ISFitnessUI:updateButtons), with its own texts; nil: it can start
local function exerciseRefusal(player, exercise, data)
	if data == nil
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NoExercise", exercise or table.concat(Lang().exercises, "/"));
	end

	local threshold = ISFitnessUI and ISFitnessUI.enduranceLevelThreshold or 2;

	if moodle(player, "ENDURANCE") > threshold
	then
		return whyText("Tooltip_TooExhaustedFitness");
	end

	if moodle(player, "HEAVY_LOAD") > 2
	then
		return whyText("Tooltip_TooHeavyFitness");
	end

	if player:getVariableBoolean("sitonground") or sitting(player)
	then
		return whyText("Tooltip_StandStillFitness");
	end

	if moodle(player, "PAIN") > 3
	then
		return whyText("Tooltip_TooMuchPainFitness");
	end

	if data.item and not player:getInventory():contains(data.item, true)
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NeedEquipment", AutoPilotMoon.Macro.Names:itemName(data.item));
	end

	return nil;
end

-- busy with the exercise (contract C3): past Body.exerciseMaxMs of real time "stop" (the engine clears the actions of
-- the macro, the step with the character idle confirms as always: the experience or the endurance spent)
local function exerciseBusy(run, pending, busyMs)
	if busyMs ~= nil and busyMs > Body.exerciseMaxMs
	then
		return "stop";
	end

	return nil;
end

local function startExercise(run, op)
	local player = run.player;
	local exercise = op.exercise or Body:pickExercise(player, run);
	local data = exerciseData(exercise);
	local refusal = exerciseRefusal(player, exercise, data);

	if refusal
	then
		return nil, refusal, nil;
	end

	-- the window's own steps, with a table in its place: the same fields its methods read
	player:getFitness():init();

	local ui = { player = player, exeData = data, itemsToReequip = {} };

	if not ISFitnessUI.equipItems(ui)
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NeedEquipment", AutoPilotMoon.Macro.Names:itemName(data.item)), nil;
	end

	local action = ISFitnessAction:new(player, exercise, Body:exerciseMinutes(op), data, data.type);

	action.autopilotMacro = true;
	ui.currentExercice = data.type;
	ISTimedActionQueue.addGetUpAndThen(player, action);
	run.reequip = ui;
	run.lastExercise = exercise;
	Body.drawn[player:getPlayerNum()] = nil;

	if op.exercise == nil
	then
		-- the panel's "Ora:" (MacroRun shows op.desc once the action started) names the exercise chosen
		op.desc = Body:describe(op, exercise);
	end

	return { kind = "exercise", exercise = exercise, xp0 = xpSum(player, op), endurance0 = stat(player, "ENDURANCE"),
		busy = exerciseBusy };
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

-- the effect of an exercise: experience, or endurance spent
local function exercised(run, pending)
	local player = run.player;

	return xpSum(player, pending.op) > pending.xp0 + 0.0001 or stat(player, "ENDURANCE") < pending.endurance0 - 0.0001;
end

local function exerciseFailed(run, pending)
	return whyText("IGUI_AutoPilot_A_MacroR_ExerciseNoEffect", pending.exercise);
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

-- rest(minutes=N) (26/11/2026, 1.6.2, MACRO-AUTOPILOT.md 22): the real milliseconds of N game minutes, counted as
-- exercise(minutes=) counts them (GameTime.getMinutesPerDay: the real minutes of a day of the game, the server's day
-- length; Body.restDayFallback when the game does not say); nil without minutes. Body.restMaxMs stays the ceiling.
function AutoPilotMoon.Macro.Body:restMinutesMs(op)
	if op.minutes == nil
	then
		return nil;
	end

	local perDay = getGameTime():getMinutesPerDay();

	if perDay == nil or perDay <= 0
	then
		perDay = Body.restDayFallback;
	end

	return math.max(1, math.floor(op.minutes * perDay * 60000 / 1440));
end

-- the game minutes still to sit of rest(minutes=N), at least 1 while seated (the ceiling counted: never more than the
-- real minutes left before it)
local function restMinutesLeft(pending, seatedMs)
	local leftMs = math.min(pending.minutesMs, Body.restMaxMs) - seatedMs;

	return math.max(1, math.ceil(leftMs * pending.op.minutes / pending.minutesMs));
end

local function startRest(run, op)
	local player = run.player;

	-- rested and standing: nothing to do, the line after; rest(minutes=N) sits all the same (1.6.2: pain, sickness)
	if op.minutes == nil and AutoPilotMoon.Rest:getEndurancePercent(player) >= op.untilPct and not sitting(player)
	then
		return nil, nil, "skip";
	end

	-- already sitting: the minutes count from now, never up and down again
	local pending = { kind = "rest", phase = "sitting", since = now(), minutesMs = Body:restMinutesMs(op) };

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
			note(player, "MacroR_NoSeat", getText("IGUI_AutoPilot_A_MacroR_NoSeat", Body.seatRadius), { n1 = Body.seatRadius });
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

			return "fail", whyText("IGUI_AutoPilot_A_MacroR_CannotSit");
		end

		return "busy";
	end

	if pending.phase == "resting"
	then
		local op = pending.op;
		local seatedMs = time - pending.since;
		-- the ceiling (10 real minutes), or the game got the character up (a zombie, the seat taken): the rest is over
		local over = seatedMs > Body.restMaxMs or not sitting(player);

		if pending.minutesMs and seatedMs < pending.minutesMs
		then
			-- rest(minutes=N) (1.6.2): seated N game minutes whatever the endurance, "riposa seduto, ancora 3 minuti"
			local left = restMinutesLeft(pending, seatedMs);

			if pending.leftShown ~= left
			then
				pending.leftShown = left;
				pending.leftText = Body:minutesText(left);
			end

			AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroRestingFor", pending.leftText);
		elseif op.untilPct
		then
			-- rest(), rest(until=P); with minutes too, past them: until the endurance is back
			local percent = AutoPilotMoon.Rest:getEndurancePercent(player);

			AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroResting", percent, op.untilPct);
			over = over or percent >= op.untilPct;
		else
			-- rest(minutes=N) without until: the minutes are over
			over = true;
		end

		if over
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
-- Eat, drink, refill (smart food and water, 20/11/2026, MacroFood.lua: what the character carries and what is within
-- reach), smoke: the item chosen, never a favourite, an equipped or a worn one
-- ============================================================================================================

local function Food()
	return AutoPilotMoon.Macro.Food;
end

-- the walk to what is within 8 squares (MacroNear.lua, contract C4 of ANALISI-AUTONOMIA.md 5)
local function Near()
	return AutoPilotMoon.Macro.Near;
end

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

-- The containers within reach whose contents have not arrived from the server yet (a crate never opened in
-- multiplayer): one wait for all of them ("Ora: apre Frigo (aspetta il server...)"), then the choice again with what
-- arrived. Returns false while the wait goes on; else true, uncertain (no answer seen: an empty container, or a server
-- that did not answer) and the containers' names.
local function awaitContents(run, op, loading)
	local load = run.foodLoad;

	if load == nil or load.op ~= op
	then
		local names = Food():names(loading);
		local w = AutoPilotMoon.Wait:new(run.player, { label = names, waitingAfterMs = 0 });

		for i, entry in ipairs(loading)
		do
			w:expectLoaded(entry.container);
		end

		load = { op = op, wait = w, names = names };
		run.foodLoad = load;
	end

	local answer, why, info = load.wait:check();

	if answer == "busy"
	then
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroExplore", load.names);

		return false;
	end

	run.foodLoad = nil;

	return true, info ~= nil and info.uncertain == true, load.names;
end

-- a choice of chooseFood / chooseDrink, waiting for the containers within reach still loading: the choice, or nil, the
-- reason and the kind ("wait": the step comes again)
local function chooseWaiting(run, op, choose)
	local player = run.player;
	local choice, why, kind, loading = choose(player, op);

	if choice == nil and kind == "loading"
	then
		local done, uncertain, names = awaitContents(run, op, loading);

		if not done
		then
			return nil, nil, "wait";
		end

		choice, why, kind = choose(player, op, { anyway = true });

		if choice == nil and uncertain and kind == "nothing"
		then
			-- no answer from the server: never "nothing" for sure (a "while possible" would end as if done)
			return nil, whyText("IGUI_AutoPilot_A_MacroR_NotSeenNear", names), nil;
		end
	end

	return choice, why, kind;
end

local function startEat(run, op)
	local player = run.player;
	local choice, why, kind = chooseWaiting(run, op, function(p, o, opts)
		return Food():chooseFood(p, o, opts);
	end);

	if choice == nil
	then
		return nil, why, kind;
	end

	if choice.far then return Near():approach(run, op, choice.far) end

	local item = choice.item;
	local part = Food():portion(player, choice, op.amount);
	local pending = { kind = "eat", itemId = item:getID(), name = item:getDisplayName(), hunger0 = stat(player, "HUNGER"),
		can = choice.recipe ~= nil, part = part, square = player:getCurrentSquare(),
		fromContainer = choice.from and choice.from.container or nil, fromName = choice.from and choice.from.name or nil };

	-- the inventory's "Eat" (and "Open and Eat"): ISInventoryPaneContextMenu.eatItem moves the food from a bag or a
	-- container within reach into the inventory, opens the can, eats, puts what is left back where it was
	if choice.recipe
	then
		ISInventoryPaneContextMenu.eatItem(item, part, player:getPlayerNum(), choice.recipe, math.floor(part * 100 + 0.5));
	else
		ISInventoryPaneContextMenu.eatItem(item, part, player:getPlayerNum());
	end

	return pending;
end

-- the food (or the bottle) with that id is nowhere: not carried, not in the container it came from, not on the 3x3
local function goneEverywhere(player, pending)
	return AutoPilotMoon.Wait:findById(player, pending.itemId, { container = pending.fromContainer, square = pending.square }) == nil;
end

-- eaten: less hungry, or the food used up (by id, wherever it came from) once the game performed the meal; a can: only
-- the hunger (opening it uses the closed can up)
local function eaten(run, pending)
	local player = run.player;

	if stat(player, "HUNGER") < pending.hunger0 - 0.0001
	then
		return true;
	end

	if pending.can
	then
		return false;
	end

	return goneEverywhere(player, pending) and (pending.mealAction == nil or pending.wait:wasPerformed(pending.mealAction));
end

local function eatFailed(run, pending, why)
	if pending.can and goneEverywhere(run.player, pending)
	then
		-- opened (the closed can is gone), the meal never came: the server's command did not arrive
		return whyText("IGUI_AutoPilot_A_MacroR_CanNoMeal", pending.name);
	end

	if why == "refused" and pending.fromName
	then
		return whyText("IGUI_AutoPilot_A_MacroR_EatRefused", pending.name, pending.fromName);
	end

	return whyText("IGUI_AutoPilot_A_MacroR_NotEaten", pending.name);
end

-- drink(source=True): the nearest clean source, as the right click's "Drink" (ISWorldObjectContextMenu.onDrink: the
-- walk next to it, ISTakeWaterAction for what the thirst asks)
local function startDrinkSource(run, op)
	local player = run.player;
	local source = Food():findSource(player);

	if source == nil
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoSource", Food().sourceRadius), "nothing";
	end

	local thirst = stat(player, "THIRST");

	-- the game drinks from a source what the thirst asks (thirst x 2 of water): not thirsty, nothing to do
	if thirst * 2 < 0.01
	then
		note(player, "MacroR_NotThirsty", getText("IGUI_AutoPilot_A_MacroR_NotThirsty"), {});

		return nil, nil, "skip";
	end

	ISWorldObjectContextMenu.onDrink(nil, source.object, player:getPlayerNum());

	return { kind = "drink", source = true, name = source.name, thirst0 = thirst };
end

local function startDrink(run, op)
	if op.source
	then
		return startDrinkSource(run, op);
	end

	local player = run.player;
	local choice, why, kind = chooseWaiting(run, op, function(p, o, opts)
		return Food():chooseDrink(p, o, opts);
	end);

	if choice == nil
	then
		return nil, why, kind;
	end

	if choice.far then return Near():approach(run, op, choice.far) end

	local item = choice.item;
	local pending = { kind = "drink", itemId = item:getID(), name = item:getDisplayName(), thirst0 = stat(player, "THIRST"),
		amount0 = item:getFluidContainer():getAmount(), square = player:getCurrentSquare(),
		fromContainer = choice.from and choice.from.container or nil, fromName = choice.from and choice.from.name or nil };

	-- the inventory's "Drink" (ISInventoryPaneContextMenu.onDrinkFluid: into the inventory, the drink, back)
	ISInventoryPaneContextMenu.onDrinkFluid(item, op.amount or 1, player, nil, item);

	return pending;
end

-- the item now, by id (in multiplayer a bottle from a bag comes back as another object); nil: used up or gone
local function current(pending)
	local wait = pending.wait;

	return wait and wait:resolve(pending.itemId) or nil;
end

-- drunk: less thirsty, or less in the bottle (found again by id, wherever it came from)
local function drunk(run, pending)
	local player = run.player;

	if stat(player, "THIRST") < pending.thirst0 - 0.0001
	then
		return true;
	end

	if pending.source
	then
		return false;
	end

	local item = AutoPilotMoon.Wait:findById(player, pending.itemId, { container = pending.fromContainer, square = pending.square });
	local fluid = item and item:getFluidContainer();

	return fluid ~= nil and fluid:getAmount() < pending.amount0 - 0.0001;
end

local function drinkFailed(run, pending, why)
	if pending.source
	then
		return whyText("IGUI_AutoPilot_A_MacroR_NotDrunkSource", pending.name);
	end

	if why == "refused" and pending.fromName
	then
		return whyText("IGUI_AutoPilot_A_MacroR_DrinkRefused", pending.name, pending.fromName);
	end

	return whyText("IGUI_AutoPilot_A_MacroR_NotDrunk", pending.name);
end

-- refill(): the bottles carried that can take clean water, at the nearest clean source, as the right click's "Fill"
-- (ISWorldObjectContextMenu.onTakeWater: the walk, each bottle into the inventory, ISTakeWaterAction, back into its bag)
local function startRefill(run, op)
	local player = run.player;
	local items, full = Food():fillable(player, op);

	if #items == 0
	then
		if full > 0
		then
			-- every bottle already full: nothing to do, the line after (a "while possible" ends well)
			if op.possibleFirst
			then
				return nil, getText("IGUI_AutoPilot_A_MacroR_AllFull"), "nothing";
			end

			note(player, "MacroR_AllFull", getText("IGUI_AutoPilot_A_MacroR_AllFull"), {});

			return nil, nil, "skip";
		end

		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoBottle"), nil;
	end

	local source = Food():findSource(player, items);

	if source == nil
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoSource", Food().sourceRadius), nil;
	end

	local fills = {};

	for i, item in ipairs(source.items)
	do
		table.insert(fills, { id = item:getID(), amount0 = item:getFluidContainer():getAmount() });
	end

	ISWorldObjectContextMenu.onTakeWater(nil, source.object, source.items, source.items[1], player:getPlayerNum());

	return { kind = "refill", name = source.name, fills = fills, square = player:getCurrentSquare() };
end

-- one expectation per bottle: more water in it (found again by id: each bottle goes from its bag into the inventory and
-- back, in multiplayer another object each time)
local function expectFilled(wait, run, pending)
	for i, fill in ipairs(pending.fills)
	do
		wait:expectTrue(function()
			local item = AutoPilotMoon.Wait:findById(run.player, fill.id, { square = pending.square });
			local fluid = item and item:getFluidContainer();

			return fluid ~= nil and fluid:getAmount() > fill.amount0 + 0.0001;
		end);
	end
end

local function refillFailed(run, pending, why)
	return whyText("IGUI_AutoPilot_A_MacroR_NotFilled", pending.name);
end

-- has_food(), has_drink() (conditions): what eat() / drink() would find now, nothing queued; a container within reach
-- still loading counts as "not yet" (its contents are asked for). has_food() does not ask whether the character can
-- eat more.
function AutoPilotMoon.Macro.Body:hasFood(player, op)
	return Food():chooseFood(player, op, { ignoreFull = true }) ~= nil;
end

function AutoPilotMoon.Macro.Body:hasDrink(player, op)
	if op.source
	then
		return Food():findSource(player) ~= nil;
	end

	return Food():chooseDrink(player, op) ~= nil;
end

-- has_smoke() (26/11/2026, ANALISI-AUTONOMIA.md 3.8): smoke() would find something to smoke and to light it with now
function AutoPilotMoon.Macro.Body:hasSmoke(player, op)
	return Body:chooseSmoke(player, op) ~= nil;
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
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoSmoke"), "nothing";
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

	return nil, whyText("ContextMenu_Require", missing or ""), nil;
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

-- smoked: used up, fewer uses in the pack (found again by id), or less stressed
local function smoked(run, pending)
	local player = run.player;
	local item = current(pending);

	return player:getInventory():getItemWithIDRecursiv(pending.itemId) == nil or (item ~= nil and uses(item) < pending.uses0 - 0.0001)
		or stat(player, "STRESS") < pending.stress0 - 0.0001;
end

-- a smoke() confirmed: the craving as the client has it now; in MP the new value comes with the next stats of the
-- server (MacroRun.lua, Run.smokeSettleMs; MACRO-AUTOPILOT.md 16.3)
local function noteSmoked(run)
	run.smoked = { at = now(), raw = stat(run.player, "NICOTINE_WITHDRAWAL") };
end

local function smokeFailed(run, pending)
	return whyText("IGUI_AutoPilot_A_MacroR_NotSmoked", pending.name);
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
		return whyText(picture and "ContextMenu_TooDarkToSee" or "ContextMenu_TooDark");
	end

	if player:hasTrait(CharacterTrait.ILLITERATE) and not picture
	then
		return whyText("ContextMenu_Illiterate");
	end

	local skill = skillBookOf(book);

	if skill and book:getLvlSkillTrained() ~= -1 and book:getLvlSkillTrained() > player:getPerkLevel(skill.perk) + 1
	then
		return whyText("ContextMenu_TooComplicated");
	end

	if skill and book:getMaxLevelTrained() ~= -1 and book:getMaxLevelTrained() <= player:getPerkLevel(skill.perk)
	then
		return whyText("ContextMenu_TooSimple");
	end

	if book:hasTag(ItemTag.UNINTERESTING)
	then
		return whyText("ContextMenu_EmptyNotebook");
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
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoBook", op.itemText or ""), "nothing";
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
			return nil, whyText("IGUI_AutoPilot_A_MacroR_AlreadyRead", book:getDisplayName()), "nothing";
		end

		note(player, "MacroR_AlreadyReadNext", getText("IGUI_AutoPilot_A_MacroR_AlreadyReadNext", book:getDisplayName()),
			{ a1 = book:getDisplayName() });

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
	state.itemId = book:getID();
	state.name = book:getDisplayName();
	state.numberOfPages = book:getNumberOfPages();

	return state;
end

-- counted when the character read something: more pages (or the whole book), a magazine's recipes, a story read, less
-- boredom or sadness (a comic without pages)
local function read(run, pending)
	local player = run.player;
	-- the book by id: the game moves it from a bag into the inventory and back (another object in multiplayer)
	local now = readState(player, current(pending) or pending.book);

	return now.pages > pending.pages or (pending.numberOfPages > 0 and now.pages >= pending.numberOfPages)
		or (now.readBook and not pending.readBook) or (now.literature and not pending.literature)
		or now.boredom < pending.boredom - 0.0001 or now.unhappiness < pending.unhappiness - 0.0001;
end

local function readFailed(run, pending)
	return whyText("IGUI_AutoPilot_A_MacroR_NotRead", pending.name);
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

local starts = { exercise = startExercise, rest = startRest, eat = startEat, drink = startDrink, smoke = startSmoke, read = startRead,
	refill = startRefill };
-- what shows the action happened, and what to say when it did not
local effects = { exercise = exercised, eat = eaten, drink = drunk, smoke = smoked, read = read };
local failures = { exercise = exerciseFailed, eat = eatFailed, drink = drinkFailed, smoke = smokeFailed, read = readFailed,
	refill = refillFailed };
-- the actions whose expectations are more than one effect: refill() (one per bottle)
local expecters = { refill = expectFilled };

-- A body action written in another file (contract C2 of ANALISI-AUTONOMIA.md 5, 26/11/2026: have_fun in MacroFun.lua):
-- its start, the effect that confirms it, the reason when it did not happen, "Adesso si puo' fare?" and the panel's
-- text, used as the ones of this file. A kind registered again replaces the one before.
function AutoPilotMoon.Macro.Body:register(kind, action)
	registered[kind] = action;
	starts[kind] = action.start;
	effects[kind] = action.effect;
	failures[kind] = action.failure;
end

-- the first watched action of the game of that type (the meal among what eatItem queued: the transfer from a crate,
-- the meal, the transfer back)
local function watchedOfType(wait, typeName)
	for i, action in ipairs(wait.actions)
	do
		if action.Type == typeName
		then
			return action;
		end
	end

	return nil;
end

function AutoPilotMoon.Macro.Body:start(run, op)
	local mark = AutoPilotMoon.Wait:mark(run.player);
	local pending, why, kind = starts[op.kind](run, op);

	if pending
	then
		pending.op = op;

		if effects[pending.kind] or expecters[pending.kind]
		then
			-- the engine's wait: the game's actions just queued watched (a refusal at once), the effect looked at
			-- while idle; "Open and Eat" waits longer (the meal comes with a command of the server)
			local wait = AutoPilotMoon.Wait:new(run.player, { label = Body:describe(op, pending.exercise),
				timeoutMs = pending.can and Body.canConfirmMs or nil });

			wait:watchQueued(mark);

			if expecters[pending.kind]
			then
				expecters[pending.kind](wait, run, pending);
			else
				wait:expectTrue(function()
					return effects[pending.kind](run, pending);
				end);
			end

			pending.wait = wait;
			pending.mealAction = watchedOfType(wait, "ISEatFoodAction");
		end
	end

	return pending, why, kind;
end

function AutoPilotMoon.Macro.Body:confirm(run, pending)
	if pending.kind == "rest"
	then
		return confirmRest(run, pending, AutoPilotMoon.Macro.Run:idleFor(pending));
	end

	local answer, why, info = pending.wait:check();

	if answer == "done" and pending.kind == "smoke"
	then
		noteSmoked(run);
	end

	if answer == "busy" or answer == "done"
	then
		return answer;
	end

	if pending.kind == "refill" and info and info.arrived > 0
	then
		-- some bottles filled, then the source ran dry (or the server refused the rest): done, said
		note(run.player, "MacroR_FilledPart", getText("IGUI_AutoPilot_A_MacroR_FilledPart", info.arrived, info.total, pending.name),
			{ n1 = info.arrived, n2 = info.total, a1 = pending.name });

		return "done";
	end

	if why == "notqueued"
	then
		if pending.source or pending.kind == "refill"
		then
			-- the game's walk next to the source could not start (no free square next to it)
			return "fail", whyText("IGUI_AutoPilot_A_MacroR_SourceUnreachable", pending.name);
		end

		return "fail", whyText("IGUI_AutoPilot_A_MacroR_WaitNotQueued", Body:describe(pending.op));
	end

	return "fail", failures[pending.kind](run, pending, why);
end

-- what eat() would eat, said by "Adesso si puo' fare?": "mangera' Mela", "mangera' Mela da Frigo", "aprira' e mangera'..."
local function eatDetail(choice)
	local name = choice.item:getDisplayName();

	if choice.recipe
	then
		return choice.from and getText("IGUI_AutoPilot_E_NowEatCanFrom", name, choice.from.name) or getText("IGUI_AutoPilot_E_NowEatCan", name);
	end

	return choice.from and getText("IGUI_AutoPilot_E_NowEatFrom", name, choice.from.name) or getText("IGUI_AutoPilot_E_NowEat", name);
end

local function drinkDetail(choice)
	local name = choice.item:getDisplayName();

	return choice.from and getText("IGUI_AutoPilot_E_NowDrinkFrom", name, choice.from.name) or getText("IGUI_AutoPilot_E_NowDrink", name);
end

-- "Adesso si puo' fare?" of eat(), drink(), refill(): nil and what it would do, or the reason
local function probeFood(player, op)
	if op.kind == "eat"
	then
		local choice, why, kind, loading = Food():chooseFood(player, op);

		if choice
		then
			return nil, eatDetail(choice);
		end

		if kind == "loading"
		then
			return nil, getText("IGUI_AutoPilot_E_NowLook", Food():names(loading));
		end

		return why;
	end

	if op.kind == "drink" and not op.source
	then
		local choice, why, kind, loading = Food():chooseDrink(player, op);

		if choice
		then
			return nil, drinkDetail(choice);
		end

		if kind == "loading"
		then
			return nil, getText("IGUI_AutoPilot_E_NowLook", Food():names(loading));
		end

		return why;
	end

	local items = nil;

	if op.kind == "refill"
	then
		local full = 0;

		items, full = Food():fillable(player, op);

		if #items == 0
		then
			return getText(full > 0 and "IGUI_AutoPilot_A_MacroR_AllFull" or "IGUI_AutoPilot_A_MacroR_NoBottle");
		end
	end

	local source = Food():findSource(player, items);

	if source == nil
	then
		return getText("IGUI_AutoPilot_A_MacroR_NoSource", Food().sourceRadius);
	end

	if op.kind == "refill"
	then
		return nil, getText("IGUI_AutoPilot_E_NowRefill", #source.items, source.name);
	end

	return nil, getText("IGUI_AutoPilot_E_NowDrinkSource", source.name);
end

-- "Adesso si puo' fare?" for exercise(): nil, and without a type the one the run will do ("fara' squats (scelto a
-- caso)": drawn once, kept until started); else the window's refusal
local function probeExercise(player, op)
	local exercise = op.exercise or Body:pickExercise(player, nil);
	local refusal = exerciseRefusal(player, exercise, exerciseData(exercise));

	if refusal or op.exercise
	then
		return refusal;
	end

	return nil, getText("IGUI_AutoPilot_E_NowExerciseAny", exercise);
end

-- "Adesso si puo' fare?": nil when the action can start now (and, for the food and the water, what it would do), else
-- why (nothing is queued)
function AutoPilotMoon.Macro.Body:probe(player, op)
	if registered[op.kind] and registered[op.kind].probe
	then
		return registered[op.kind].probe(player, op);
	end

	if op.kind == "exercise"
	then
		return probeExercise(player, op);
	elseif op.kind == "rest"
	then
		return nil;
	elseif op.kind == "eat" or op.kind == "drink" or op.kind == "refill"
	then
		return probeFood(player, op);
	elseif op.kind == "read"
	then
		return probeRead(player, op);
	end

	local item, why = Body:chooseSmoke(player, op);

	return item == nil and why or nil;
end
