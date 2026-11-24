-- AutoPilot (Moon): automations for the Moon server.

-- The "centralino" of the notifications (20/11/2026, ANALISI-NOTIFICHE-DISCORD.md 1.2 and 6.4, contract
-- NOTIFICHE-CONTRATTO.md and tests/notify_contract.json): AutoPilot says, to whoever listens in this same game, what
-- happens to a job, a chain or a macro (started, a problem, finished, stopped), as flat events. AutoPilot never
-- talks to the network: the listener (the bridge of ZomBOT (Moon), another mod) does. Loaded before
-- 48_AP_Progress.lua, so every other file can call it without checks.
--
-- The public interface, version 1 (other mods):
--   Notify.version                      1
--   Notify:subscribe(fn) / :unsubscribe(fn) / :hasSubscribers()   fn(event): event is a NEW flat table
--   Notify:getMode()                    "off" | "all" | "problems": the player's option (and the panel's tick for the
--                                       job, and the master switch) read now
--   Notify:getRun()                     nil, or { run = "id", job = "lumberjack", title = "Taglialegna" }
--   Notify:control(command, args)       -> ok, answer. "stop": stops the job, chain or macro with the reason "remote"
--                                       and empties the player's whole action queue (decision D7); "stopped" or
--                                       "nothing" (also with the notifications off; with the master switch off:
--                                       "nothing"). "status": "running" or "idle"
--   Notify:setStatus(code, text)        the listener says how the delivery stands (panel): "ok" (text = Discord name),
--                                       "nolink", "dmclosed", "noserver", "nolistener", "botoff"
--
-- For the other files of AutoPilot (WP1b, WP1c, WP1d):
--   Notify:why(key, a, b, c, d)         remembers the text key of a stop (and its first two arguments) and returns
--                                       getText(key, ...): A:stopBecause(Notify:why("IGUI_AutoPilot_A_Reason_NeedTool",
--                                       getText("IGUI_AutoPilot_T_NeedAxe"))). The key gives the event its code (the key
--                                       without IGUI_AutoPilot_A_); valid only for the reasons because, aborted and
--                                       done, only in the frame that said it (wiped at the start and at the end of every
--                                       player update, and by every stop)
--   Notify:code(code, a, b)             the same without a text ("MacroDone": the end of a macro's text has no key)
--   Notify:warnArgs(key, a1, a2)        the arguments of the next warn of a key counted with Progress:warn (the name
--                                       of the item a server refused for Reason_ServerRefused), right before it
--   Notify:emit(kind, code, fields)     one event now (kind "warn", "note", "stop"...); fields: the contract's fields
--                                       (text, detail, a1, a2, n1, n2, line, sev to override the catalogue's...), the
--                                       rest is filled here (run, seq, title, job, player, state). Returns the event or
--                                       nil. Nothing at all is built while the notifications are off, the master
--                                       switch is off or nobody listens (Notify.built counts the events built)
--   Notify:sayUnsent(level, text, player)  says a message over the head that is never sent (a refusal of a start the
--                                       player just asked for, while another job runs)
--   Notify:isActive()                   something would be sent now (cheap: a sentinel asks before working)
--   AutoPilotMoon.Watch (51_AP_Watch.lua, WP1d), when it exists: Watch:tick(job, player, nowMs) once a second while a
--   run is open (job = Automation.job, nil between two phases of a chain), Watch:after(player, nowMs) once a second in
--   the 10 minutes after a stop (decision D5), Watch:reset() at every start, stop and shutdown,
--   Watch:onMacroAction(run, pending, player) when a macro's action is confirmed (the macros call
--   Notify:onMacroAction(run, pending), WP1c). Each in pcall, only while something would be sent.
--
-- How the events are made (no point of the code can slip through): every end of a job, chain or macro passes through
-- Progress:finish (the observer "stop" below: code from the remembered key or from the reason); every sentence of
-- AutoPilot passes through remember() of 02_AP_Debug.lua (onMessage: a "bad" sentence during a run that is not the
-- sentence of an end becomes warn/other); the warnings grouped by Progress:warn go at 1, 5, 20, 50... of their count;
-- the rests (rest_start / rest_end, option notifyRest) and the phases of a chain (note phase / phase_skipped) come from
-- the Progress observer too. A start is sent at the job's first frame (a job refused or stopped before it sends
-- nothing: the player is at the keyboard, ANALISI-NOTIFICHE-DISCORD.md 3.9). The engine's frame is marked: when it
-- ends with a Lua error 3 frames in a row, the job is stopped (engine_error). After a stop that is not the player's
-- own (user, remote, switchedoff, dead), the watch goes on for 10 minutes or until the player moves (events with
-- after = true). The filters of the player's options (2.3) are applied here: an event that is not wanted is not built.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Notify = AutoPilotMoon.Notify or {};

local N = AutoPilotMoon.Notify;

N.version = 1;
N.subs = N.subs or {};          -- { fn = listener, errors = errors in a row }
N.maxErrors = 5;                -- a listener that fails this many times in a row is dropped
N.afterMs = 600000;             -- the watch after a stop: 10 minutes (decision D5)
N.tickMs = 1000;                -- the sentinels: once a second
N.engineErrorFrames = 3;        -- the engine's frame ended with an error this many times in a row: stop the job
N.otherRepeatMs = 60000;        -- the same bad sentence again as warn/other: not within a minute
N.warnSteps = { 1, 5, 20, 50, 100, 200, 500, 1000 };
N.zombiesRange = 20;            -- zSeen / zDist: the zombies the character sees on its floor within this many tiles
N.spottedMax = 100;             -- ... looked for in at most this many entries of the game's list of what it sees
N.keyPrefix = "IGUI_AutoPilot_A_";
N.built = 0;                    -- events built (the tests check that nothing is built while off)
N.runCounter = N.runCounter or 0;
N.run = nil;                    -- the run open now: { id, seq, job, jobKind, player, startedAt, begun, startSent, title... }
N.after = nil;                  -- the watch after a stop: { run, player, untilMs }
N.live = false;                 -- a run or the watch after a stop: the player update calls beforeUpdate / afterUpdate
N.prefMode = "off";             -- the mode last told with a pref
N.status = nil;                 -- setStatus
N.statusText = nil;
N.lastTick = 0;

-- what was said since the start of the frame (the end's sentence): two lists reused, at most saidMax
N.saidText = {};
N.saidLevel = {};
N.saidCount = 0;
N.saidMax = 6;

-- the catalogue (tests/notify_contract.json, generated): code -> "kind severity [filter]", the codes the client sends
N.codes = {
	start = "start info start",
	start_late = "start info start",
	phase = "note info",
	phase_skipped = "note info",
	zombies = "stop critical",
	dead = "stop critical",
	unwell = "stop problem",
	vehicle = "stop problem",
	asleep = "stop notice",
	nosquare = "stop problem",
	user = "stop info manual",
	notallowed = "stop problem",
	switchedoff = "stop info",
	remote = "stop info",
	internal = "stop problem",
	stopped = "stop problem",
	chain_refused = "stop problem",
	done = "stop info",
	UnloaderCapReached = "stop notice",
	CorpseCapReached = "stop notice",
	DismantlerCapReached = "stop notice",
	MacroDone = "stop info",
	MacroDoneStop = "stop info",
	MacroDoneStopIf = "stop info",
	MacroDoneCannot = "stop notice",
	MacroDoneNoFuel = "stop notice",
	MacroDoneLimit = "stop notice",
	MacroDoneLoops = "stop notice",
	MacroDoneMinutes = "stop notice",
	MacroDoneLevels = "stop notice",
	MacroDoneItems = "stop notice",
	Reason_NeedTool = "stop problem",
	Reason_NoTools = "stop problem",
	TooTired = "stop problem",
	TooHeavy = "stop problem",
	Reason_BagFull = "stop problem",
	Reason_DestFull = "stop problem",
	Reason_DestLocked = "stop problem",
	Reason_DestUnreachable = "stop problem",
	Reason_DestGone = "stop problem",
	Reason_VehicleMoved = "stop problem",
	Reason_NoSurface = "stop problem",
	Reason_NoRoomForPlanks = "stop problem",
	Reason_NoRoomForBags = "stop problem",
	Reason_TooDark = "stop problem",
	Reason_TooDarkChop = "stop problem",
	Reason_GameRefused = "stop problem",
	NoWaterLeft = "stop problem",
	Reason_SourceGivesNothing = "stop problem",
	Reason_SourceGone = "stop problem",
	Reason_NoEmptySacksRefill = "stop problem",
	Reason_NoEmptySacksNoRefill = "stop problem",
	Reason_Protected = "stop problem",
	CorpsePileUnreachable = "stop problem",
	CorpseNotDropped = "stop problem",
	square_skipped = "warn notice",
	Reason_ServerRefused = "warn problem",
	Skip_Unreachable = "warn notice",
	Skip_Protected = "warn info",
	Skip_GameRefused = "warn notice",
	Skip_BushesNoTool = "warn notice",
	Skip_StumpsNoTool = "warn notice",
	Skip_BouldersNoTool = "warn notice",
	Skip_NoTools = "warn notice",
	Skip_NotEmptied = "warn info",
	Skip_NotOpened = "warn notice",
	Skip_AlreadyFertilized = "warn info",
	Skip_NoCure = "warn info",
	Skip_Nothing = "warn info",
	CorpseLeftStuck = "warn notice",
	ObjectSkipped = "warn info",
	UnableToEmptyContainer = "warn notice",
	FloorFull = "warn notice",
	rest_start = "warn info rest",
	rest_end = "warn info rest",
	RestCannotSit = "warn notice",
	MacroR_NoSeat = "warn info",
	MacroR_NotThirsty = "warn info",
	MacroR_AllFull = "warn info",
	MacroR_AlreadyReadNext = "warn info",
	MacroR_FilledPart = "warn notice",
	MacroR_NoItem = "stop problem",
	MacroR_Refused = "stop problem",
	MacroR_NothingToRepair = "stop problem",
	MacroR_NothingToSharpen = "stop problem",
	MacroR_NotKnown = "stop problem",
	MacroR_Dark = "stop problem",
	MacroR_Surface = "stop problem",
	MacroR_NoFuel = "stop problem",
	MacroR_NotQueued = "stop problem",
	MacroR_Interrupted = "stop problem",
	MacroR_NoEffect = "stop problem",
	MacroR_Excluded = "stop problem",
	MacroR_HandlerLoop = "stop problem",
	MacroR_BenchesOff = "stop problem",
	MacroR_NoBench = "stop problem",
	MacroR_BenchBusy = "stop problem",
	MacroR_BenchFar = "stop problem",
	MacroR_BenchClosed = "stop problem",
	MacroR_NoExercise = "stop problem",
	MacroR_NeedEquipment = "stop problem",
	MacroR_ExerciseNoEffect = "stop problem",
	MacroR_CannotSit = "stop problem",
	MacroR_NoFood = "stop problem",
	MacroR_NoFoodOn = "stop problem",
	MacroR_OnlyFrozen = "stop problem",
	MacroR_OnlyUnpleasant = "stop problem",
	MacroR_CansClosed = "stop problem",
	MacroR_NoCanOpener = "stop problem",
	MacroR_NotSeenNear = "stop problem",
	MacroR_CanNoMeal = "stop problem",
	MacroR_EatRefused = "stop problem",
	MacroR_DrinkRefused = "stop problem",
	MacroR_NotEaten = "stop problem",
	MacroR_NotDrunk = "stop problem",
	MacroR_NotDrunkSource = "stop problem",
	MacroR_NoDrink = "stop problem",
	MacroR_NoDrinkOn = "stop problem",
	MacroR_NoSource = "stop problem",
	MacroR_SourceUnreachable = "stop problem",
	MacroR_NoBottle = "stop problem",
	MacroR_NotFilled = "stop problem",
	MacroR_NoSmoke = "stop problem",
	MacroR_NotSmoked = "stop problem",
	MacroR_NoBook = "stop problem",
	MacroR_AlreadyRead = "stop problem",
	MacroR_NotRead = "stop problem",
	MacroR_WaitNotQueued = "stop problem",
	MacroR_TransfersOff = "stop problem",
	MacroR_NoPlace = "stop problem",
	MacroR_PlaceFar = "stop problem",
	MacroR_PlaceGone = "stop problem",
	MacroR_PlaceLocked = "stop problem",
	MacroR_PlaceProtected = "stop problem",
	MacroR_PlaceUnreachable = "stop problem",
	MacroR_PlaceGround = "stop problem",
	MacroR_NotSeenAt = "stop problem",
	MacroR_NothingAt = "stop problem",
	MacroR_NothingToPut = "stop problem",
	MacroR_NothingMade = "stop problem",
	MacroR_TooHeavy = "stop problem",
	MacroR_PlaceFull = "stop problem",
	MacroR_FloorFull = "stop problem",
	MacroR_FloorFullHere = "stop problem",
	MacroR_DropProtected = "stop problem",
	MacroR_NotAccepted = "stop problem",
	MacroR_PartlyRefused = "stop problem",
	MacroR_NotMoved = "stop problem",
	MacroR_PartlyMoved = "stop problem",
	MacroR_NoEquip = "stop problem",
	MacroR_NotEquipped = "stop problem",
	zombies_seen = "warn notice early",
	attacked = "warn critical early",
	hurt = "warn critical always",
	bitten = "warn critical always",
	scratched = "warn critical always",
	bleeding = "warn critical always",
	on_fire = "warn critical always",
	moodle = "warn notice early",
	materials_low = "warn notice early",
	sacks_low = "warn notice early",
	water_low = "warn notice early",
	seeds_low = "warn notice early",
	tool_worn = "warn notice early",
	tool_broken = "warn problem early",
	load_high = "warn notice early",
	dusk = "warn notice early",
	dark_now = "warn notice early",
	no_progress = "warn notice early",
	stalled = "warn problem early",
	server_slow = "warn notice early",
	rest_long = "warn notice always",
	engine_error = "stop problem always",
	other = "warn problem",
	pref = "pref info",
};

-- a detail that changes the severity (contract "details")
N.details = {
	unwell = { unwell_THIRST = "problem", unwell_HUNGRY = "problem", unwell_INJURED = "critical",
		unwell_BLEEDING = "critical", unwell_PANIC = "problem" },
	done = { LimitReached = "notice" },
	ObjectSkipped = { Reason_NoFloorRoom = "notice", Reason_NoTools = "notice" },
};

-- the reasons after which the watch after a stop does not start (the player is there, or nothing is left to watch)
N.noAfter = { user = true, remote = true, switchedoff = true, dead = true };

-- the values of "reason" in the contract; another reason (a refusal of a chain's phase: nodestination...) is told as
-- "aborted", with the reason in detail
N.reasons = { done = true, user = true, zombies = true, vehicle = true, asleep = true, dead = true, nosquare = true,
	notallowed = true, unwell = true, switchedoff = true, remote = true, because = true, aborted = true, otherjob = true };

-- the fields of the contract a caller may give (strings: their maximum; code characters: minus the maximum; numbers: 0)
N.fieldSpec = {
	text = 300, counters = 200, title = 80, a1 = 60, a2 = 60, reason = 16,
	detail = -64,
	line = 0, phase = 0, phases = 0, done = 0, total = 0, skipped = 0, n1 = 0, n2 = 0,
	hp = 0, endu = 0, hunger = 0, thirst = 0, bleed = 0, zSeen = 0, zChase = 0, zClose = 0, zDist = 0,
};

N.statusKeys = {
	ok = "IGUI_AutoPilot_P_Discord_Ok",
	nolink = "IGUI_AutoPilot_P_Discord_NoLink",
	dmclosed = "IGUI_AutoPilot_P_Discord_DmClosed",
	noserver = "IGUI_AutoPilot_P_Discord_NoServer",
	nolistener = "IGUI_AutoPilot_P_Discord_NoListener",
	botoff = "IGUI_AutoPilot_P_Discord_BotOff",
	waiting = "IGUI_AutoPilot_P_Discord_Waiting",
};

-- the per-run tick of the panel ("Avvisi su Discord" for this job): a value of this session only
AutoPilotMoon.Options:register("notifyThisRun", false);

-- ============================================================================================================
-- Small helpers
-- ============================================================================================================

local function Automation()
	return AutoPilotMoon.Automation;
end

local function Progress()
	return AutoPilotMoon.Progress;
end

local function switchOn()
	local switch = AutoPilotMoon.Switch;

	return switch ~= nil and switch:isOn();
end

-- getText with exactly the arguments given (the game's getText takes Object...)
local function text(key, a, b, c, d)
	if a == nil
	then
		return getText(key);
	elseif b == nil
	then
		return getText(key, a);
	elseif c == nil
	then
		return getText(key, a, b);
	elseif d == nil
	then
		return getText(key, a, b, c);
	end

	return getText(key, a, b, c, d);
end

-- "IGUI_AutoPilot_A_Reason_NeedTool" -> "Reason_NeedTool"; only letters, digits and "_", at most 48
local function cleanCode(code, max)
	code = tostring(code or "");

	local prefix = N.keyPrefix;

	if string.sub(code, 1, string.len(prefix)) == prefix
	then
		code = string.sub(code, string.len(prefix) + 1);
	elseif string.sub(code, 1, 15) == "IGUI_AutoPilot_"
	then
		code = string.sub(code, 16);
	end

	code = string.gsub(code, "[^%w_]", "_");

	return string.sub(code, 1, max or 48);
end

N.cleanCode = cleanCode;

local function cleanText(value, max)
	local s = string.gsub(tostring(value), "[\r\n\t]", " ");

	return string.sub(s, 1, max);
end

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge;
end

-- kind, severity and filter of a code of the catalogue (nil for an unknown code)
local function codeInfo(code)
	local entry = N.codes[code or ""];

	if entry == nil
	then
		return nil, nil, nil;
	end

	local kind, sev, filter = string.match(entry, "^(%S+) (%S+) ?(%S*)$");

	return kind, sev, filter;
end

N.codeInfo = codeInfo;

-- the severity of a code, a detail first (contract "details")
function AutoPilotMoon.Notify:sevOf(code, detail, kind)
	local byDetail = N.details[code or ""];

	if byDetail and detail and byDetail[detail]
	then
		return byDetail[detail];
	end

	local known, sev = codeInfo(code);

	if sev
	then
		return sev;
	end

	if kind == "stop" or kind == "warn"
	then
		return "problem";
	end

	return "info";
end

-- the local player of the running job or chain
local function ownerPlayer()
	local automation = Automation();
	local job = automation and automation.job;
	local chainRun = AutoPilotMoon.Chain and AutoPilotMoon.Chain.current;

	return (job and job.player) or (chainRun and chainRun.player) or nil;
end

-- the title of the running job (already translated, the macros word their own)
local function titleNow()
	local state = Progress().state;

	if state.titleText
	then
		return state.titleText;
	end

	if state.titleKey
	then
		return getText(state.titleKey);
	end

	return "";
end

local function updateLive()
	N.live = N.run ~= nil or N.after ~= nil;
end

local function forgetKey()
	N.key = nil;
	N.keyA = nil;
	N.keyB = nil;
end

local function forgetSaid()
	for i = N.saidCount, 1, -1
	do
		N.saidText[i] = nil;
		N.saidLevel[i] = nil;
	end

	N.saidCount = 0;
end

local function resetWatch()
	local watch = AutoPilotMoon.Watch;

	if watch and watch.reset
	then
		local ok, err = pcall(watch.reset, watch);

		if not ok
		then
			print("AutoPilot (Moon): notify: watch: " .. tostring(err));
		end
	end
end

-- ============================================================================================================
-- Listeners, mode, status
-- ============================================================================================================

function AutoPilotMoon.Notify:subscribe(fn)
	if type(fn) ~= "function"
	then
		return false;
	end

	for i, sub in ipairs(N.subs)
	do
		if sub.fn == fn
		then
			return true;
		end
	end

	table.insert(N.subs, { fn = fn, errors = 0 });

	-- the listener asks the mode itself (getMode): the next pref is a change from now
	N.prefMode = N:getMode();

	-- a run already going whose start nobody heard: start_late at its next frame (never inside this call)
	if N.run and N.run.begun and not N.run.startSent
	then
		N.run.lateDue = true;
	end

	if N.status == "nolistener"
	then
		N.status = nil;
		N.statusText = nil;
	end

	return true;
end

function AutoPilotMoon.Notify:unsubscribe(fn)
	for i = #N.subs, 1, -1
	do
		if N.subs[i].fn == fn
		then
			table.remove(N.subs, i);
		end
	end
end

function AutoPilotMoon.Notify:hasSubscribers()
	return #N.subs > 0;
end

-- the player's option: "off", "all" or "problems"
function AutoPilotMoon.Notify:getGeneralMode()
	local mode = AutoPilotMoon.Options:get("notifyDiscord");

	if mode == "all" or mode == "problems"
	then
		return mode;
	end

	return "off";
end

-- the mode in force: the master switch (a run still open while it turns off says its end), the panel's tick for
-- this job (notifyThisRun: off = nothing for this job; on with the option off = "all"), the option
function AutoPilotMoon.Notify:getMode()
	if not switchOn() and N.run == nil
	then
		return "off";
	end

	if AutoPilotMoon.Options:get("notifyThisRun") ~= true
	then
		return "off";
	end

	local general = N:getGeneralMode();

	if general == "off"
	then
		return "all";
	end

	return general;
end

-- something would be sent now
function AutoPilotMoon.Notify:isActive()
	return #N.subs > 0 and N:getMode() ~= "off";
end

function AutoPilotMoon.Notify:getRun()
	local run = N.run;

	if run == nil
	then
		return nil;
	end

	return { run = run.id, job = run.job, title = run.title or titleNow() };
end

function AutoPilotMoon.Notify:setStatus(code, statusText)
	N.status = code;
	N.statusText = statusText;

	-- the panels show it at their next update
	local panel = AutoPilotMoon.Panel;

	if panel and panel.windows
	then
		for playerNum, window in pairs(panel.windows)
		do
			window.dirty = true;
		end
	end
end

-- the delivery's status: code and text; "nolistener" while nobody listens, "waiting" before the listener said it
function AutoPilotMoon.Notify:getStatus()
	if #N.subs == 0
	then
		return "nolistener", nil;
	end

	return N.status or "waiting", N.statusText;
end

-- the panel's line ("Discord: Yoridyon", "Discord: account non collegato"...)
function AutoPilotMoon.Notify:getStatusLine()
	local code, statusText = N:getStatus();
	local key = N.statusKeys[code] or N.statusKeys.waiting;

	if code == "ok"
	then
		return getText(key, statusText or "?");
	end

	return getText(key);
end

-- ============================================================================================================
-- Building and sending an event
-- ============================================================================================================

-- the character's state (from "notice" up): health, endurance, hunger, thirst, bleeding, zombies. Each read in its
-- own pcall around a Lua closure (the game's methods called with ":" as everywhere in the mod), a missing one left out.
local function readNumber(fn)
	local ok, value = pcall(fn);

	if ok and finite(value)
	then
		return value;
	end

	return nil;
end

-- The zombies the character sees now on its floor within range: how many and the nearest distance (nil: none). The
-- game's list of what the character sees (IsoPlayer.getSpottedList, rebuilt by the game at every line-of-sight update),
-- at most max entries looked at: never a scan of the zombies of the cell. Also used by the sentinels (51_AP_Watch.lua).
-- Errors are the caller's (pcall): a game without the list.
function AutoPilotMoon.Notify.seenZombies(player, range, max)
	local list = player:getSpottedList();

	if list == nil
	then
		return 0, nil;
	end

	local n = list:size();

	if n > max
	then
		n = max;
	end

	local px = player:getX();
	local py = player:getY();
	local pz = math.floor(player:getZ());
	local count = 0;
	local nearest = nil;

	for i = 0, n - 1
	do
		local object = list:get(i);

		if object ~= nil and instanceof(object, "IsoZombie") and math.floor(object:getZ()) == pz
		then
			local dx = object:getX() - px;
			local dy = object:getY() - py;
			local d = math.sqrt(dx * dx + dy * dy);

			if d <= range
			then
				count = count + 1;

				if nearest == nil or d < nearest
				then
					nearest = d;
				end
			end
		end
	end

	return count, nearest;
end

local function readState(event, player)
	local hp = readNumber(function() return player:getBodyDamage():getOverallBodyHealth() end);
	local bleed = readNumber(function() return player:getBodyDamage():getNumPartsBleeding() end);

	if hp
	then
		event.hp = math.floor(hp + 0.5);
	end

	event.bleed = bleed;

	local function stat(name)
		local value = readNumber(function() return player:getStats():get(CharacterStat[name]) end);

		if value
		then
			return math.floor(value * 100 + 0.5);
		end

		return nil;
	end

	event.endu = stat("ENDURANCE");
	event.hunger = stat("HUNGER");
	event.thirst = stat("THIRST");
	event.zChase = readNumber(function() return player:getStats():getNumChasingZombies() end) or 0;
	event.zClose = readNumber(function() return player:getStats():getNumVeryCloseZombies() end) or 0;

	-- the zombies the character sees on its floor within zombiesRange and the nearest (-1 = none): the game's list of
	-- what the character sees, as the sentinel zombies_seen; without that list the game's own counter (it counts only
	-- the zombies a few tiles away), the distance unknown
	local ok, seen, nearest = pcall(N.seenZombies, player, N.zombiesRange, N.spottedMax);

	if ok and finite(seen)
	then
		event.zSeen = seen;
		event.zDist = finite(nearest) and math.floor(nearest + 0.5) or -1;
	else
		event.zSeen = readNumber(function() return player:getStats():getNumVisibleZombies() end) or 0;
		event.zDist = -1;
	end
end

-- the game's language ("IT", "EN"...)
local function language()
	local ok, name = pcall(function() return Translator.getLanguage():name() end);

	if ok and type(name) == "string" and name ~= ""
	then
		return string.sub(name, 1, 5);
	end

	return "EN";
end

-- gives the event to every listener, each in pcall; one that fails maxErrors times in a row is dropped
local function dispatch(event)
	local list = {};

	for i, sub in ipairs(N.subs)
	do
		list[i] = sub;
	end

	for i, sub in ipairs(list)
	do
		local copy = event;

		if i > 1
		then
			copy = {};

			for k, v in pairs(event)
			do
				copy[k] = v;
			end
		end

		local ok, err = pcall(sub.fn, copy);

		if ok
		then
			sub.errors = 0;
		else
			sub.errors = sub.errors + 1;
			print("AutoPilot (Moon): notify: a listener failed: " .. tostring(err));

			if sub.errors >= N.maxErrors
			then
				N:unsubscribe(sub.fn);

				if #N.subs == 0
				then
					N.status = "nolistener";
				end
			end
		end
	end
end

-- Builds one event and gives it to the listeners (the caller has checked that it is wanted). mode: the mode written
-- in the event (a pref says its own); run: the run it belongs to (the open one, or the one of the watch after a stop:
-- after = true), nil for none (a pref outside a run, also during the watch after a stop).
local function build(kind, code, fields, mode, run)
	local state = Progress().state;
	local player = (run and run.player) or (N.after and N.after.player) or getSpecificPlayer(0);
	local now = getTimestampMs();
	local event = {};

	N.built = N.built + 1;

	event.v = 1;
	event.kind = kind;
	event.code = cleanCode(code);

	if run
	then
		run.seq = run.seq + 1;
		event.run = run.id;
		event.seq = run.seq;
		event.job = cleanCode(run.job, 32);
		event.jobKind = run.jobKind;
		event.title = cleanText(run.title or titleNow(), 80);
		event.dur = math.floor((now - run.startedAt) / 1000);

		if run.jobKind == "chain"
		then
			event.phase = state.phase or 0;
			event.phases = state.phaseCount or 0;
		end
	else
		event.seq = 0;
		event.dur = 0;
	end

	event.running = run ~= nil and run == N.run and kind ~= "stop";

	if run ~= nil and run ~= N.run
	then
		event.after = true;
	end

	if fields
	then
		for name, spec in pairs(N.fieldSpec)
		do
			local value = fields[name];

			if value ~= nil
			then
				if spec > 0
				then
					event[name] = cleanText(value, spec);
				elseif spec < 0
				then
					event[name] = cleanCode(value, -spec);
				elseif finite(value)
				then
					event[name] = value;
				end
			end
		end
	end

	event.sev = (fields and fields.sev) or N:sevOf(event.code, event.detail, kind);

	if player
	then
		event.x = math.floor(player:getX());
		event.y = math.floor(player:getY());
		event.z = math.floor(player:getZ());
		event.playerNum = player:getPlayerNum();

		if event.sev ~= "info"
		then
			readState(event, player);
		end
	else
		event.x = 0;
		event.y = 0;
		event.z = 0;
		event.playerNum = 0;
	end

	event.lang = language();
	event.mode = mode;

	dispatch(event);

	return event;
end

-- the player's options that filter a code (2.3): only "all" for a start, the early warnings, the rests, the stop by hand
local function passes(code, mode, run)
	local kind, sev, filter = codeInfo(code);

	if filter == "start" and mode ~= "all"
	then
		return false;
	elseif filter == "early" and AutoPilotMoon.Options:get("notifyEarly") ~= true
	then
		return false;
	elseif filter == "rest" and AutoPilotMoon.Options:get("notifyRest") ~= true
	then
		return false;
	elseif filter == "manual" and AutoPilotMoon.Options:get("notifyManual") ~= true
	then
		return false;
	end

	-- "Avvisi per: solo le macro"
	if AutoPilotMoon.Options:get("notifyJobs") == "macros" and (run == nil or run.jobKind ~= "macro")
	then
		return false;
	end

	return true;
end

-- One event now (see the head of the file). Nothing is built when it is not wanted: nobody listens, the mode is off,
-- a run that has not had its first frame yet, an option that leaves it out.
function AutoPilotMoon.Notify:emit(kind, code, fields)
	if #N.subs == 0 or code == nil
	then
		return nil;
	end

	local run = N.run or (N.after and N.after.run) or nil;

	if run and not run.begun
	then
		return nil;
	end

	local mode = N:getMode();

	if mode == "off" or not passes(code, mode, run)
	then
		return nil;
	end

	-- a coded warning of the job right after a bad sentence of the job describes it: that sentence is not sent again as
	-- "other" (the warning without a text of its own carries it). Not the warnings of the sentinels and of the rest,
	-- which come from the clock, not from what the job said; not a warning with another sentence of its own.
	local pending = N.pendingBad;

	if kind == "warn" and code ~= "other" and pending
	then
		local known, sev, filter = codeInfo(code);

		if fields and fields.text == pending
		then
			N.pendingBad = nil;
		elseif (fields == nil or fields.text == nil) and (filter == nil or filter == "")
		then
			N.pendingBad = nil;

			local withText = {};

			for k, v in pairs(fields or {})
			do
				withText[k] = v;
			end

			withText.text = pending;
			fields = withText;
		end
	end

	return build(kind, code, fields, mode, run);
end

-- a pref: the mode changed (also outside a run, also "off"); only while the master switch is on or turning off
local function sendPref(mode)
	if #N.subs == 0
	then
		return nil;
	end

	-- the run only while one is open: the run of the watch after a stop is over
	return build("pref", "pref", nil, mode, N.run);
end

-- ============================================================================================================
-- The codes of the stops: remembered keys
-- ============================================================================================================

-- remembers the key of a stop and its first two arguments; returns its text
function AutoPilotMoon.Notify:why(key, a, b, c, d)
	-- only during a run: outside one (the editor's "Adesso si puo' fare?", a refusal at the start) nothing is remembered
	if N.run ~= nil
	then
		N.key = key;
		N.keyA = a;
		N.keyB = b;
	end

	return text(key, a, b, c, d);
end

-- remembers a code without a text (only during a run)
function AutoPilotMoon.Notify:code(code, a, b)
	if N.run ~= nil
	then
		N.key = code;
		N.keyA = a;
		N.keyB = b;
	end
end

-- the code of the key remembered in this frame by why() or code() (MacroR_NoItem...), nil when none (MacroRun.lua keeps
-- it in Run.last.code)
function AutoPilotMoon.Notify:keyCode()
	if N.key == nil
	then
		return nil;
	end

	return cleanCode(N.key);
end

-- the arguments of the next warn of a warning counted with Progress:warn(key) (WP1b, 20/11/2026): the name of the
-- item a server refused (Reason_ServerRefused: a1), called right before Progress:warn; the last ones given are told
-- (a warn goes at 1, 5, 20... of the count). Nothing outside a run.
function AutoPilotMoon.Notify:warnArgs(key, a1, a2)
	local run = N.run;

	if run == nil or key == nil
	then
		return;
	end

	local code = cleanCode(key);

	run.warnA1[code] = a1;
	run.warnA2[code] = a2;
end

-- a phase of a chain did not start (53_AP_Chain.lua): the chain's stop gets the code chain_refused, with the phase
-- that did not start (the chain's progress still shows the one before)
function AutoPilotMoon.Notify:chainRefused(reason, phase)
	N.chainRefusal = reason;
	N.chainRefusalPhase = phase;
end

-- a message over the head that is never sent (a refusal the player just asked for)
function AutoPilotMoon.Notify:sayUnsent(level, message, player)
	N.muted = true;

	local ok, err = pcall(AutoPilotMoon.say, AutoPilotMoon, level, message, player);

	N.muted = false;

	if not ok
	then
		error(err);
	end
end

-- A warning of the job that may come in bursts (an object, a square, a container left out, one per frame): counted in
-- the run by code and group (the reason: Reason_Locked...); due = true when its count reaches 1, 5, 20, 50... (as the
-- warnings of Progress:warn) and something would be sent: the caller then emits it with n1 = count, built only then.
-- Returns count, due (0, false outside a run). Counts also while nothing is sent (a number, no table).
function AutoPilotMoon.Notify:stepCount(code, group)
	local run = N.run;

	if run == nil or code == nil
	then
		return 0, false;
	end

	local key = code .. ":" .. tostring(group or "");
	local count = (run.stepCount[key] or 0) + 1;

	run.stepCount[key] = count;

	for i, step in ipairs(N.warnSteps)
	do
		if step == count
		then
			return count, N:isActive();
		end
	end

	return count, false;
end

-- the arguments remembered with the key: texts to a1, a2, numbers to n1, n2
local function putArgs(fields, a, b)
	local texts = 0;
	local numbers = 0;

	for i, value in ipairs({ a or false, b or false })
	do
		if type(value) == "number"
		then
			numbers = numbers + 1;
			fields["n" .. numbers] = value;
		elseif type(value) == "string"
		then
			texts = texts + 1;
			fields["a" .. texts] = value;
		end
	end
end

-- the sentence of the end: the last one said in this frame (bad, good, plain) that is not an end warning
local function endText(summary)
	if N.saidCount == 0
	then
		return nil;
	end

	local skip = {};

	for i, sentence in ipairs(Progress():getEndWarningTexts(summary))
	do
		skip[sentence] = true;
	end

	for i = N.saidCount, 1, -1
	do
		local level = N.saidLevel[i];

		if (level == "bad" or level == "good" or level == "plain") and not skip[N.saidText[i]]
		then
			return N.saidText[i];
		end
	end

	return nil;
end

-- code and fields of a stop
local function stopFields(state, summary, run)
	local reason = summary.reason or "aborted";
	local key = N.key and cleanCode(N.key) or nil;
	local keyA = N.keyA;
	local keyB = N.keyB;
	local fields = {};
	local code = nil;
	local said = endText(summary);

	-- a reason the contract does not list (a refusal of a chain's phase: nodestination, nosurface...): aborted, the
	-- reason kept in detail
	if not N.reasons[reason]
	then
		fields.detail = cleanCode(reason, 64);
		reason = "aborted";
	end

	fields.reason = reason;

	-- a chain that ends after its last phase ended at a limit of the server (LimitReached, remembered at that phase's
	-- end, in an earlier frame)
	if key == nil and reason == "done" and summary.kind == "chain" and run.phaseKey
	then
		key = cleanCode(run.phaseKey);
		keyA = run.phaseKeyA;
		keyB = run.phaseKeyB;
	end

	if N.chainRefusal and summary.kind == "chain"
	then
		code = "chain_refused";
		fields.detail = cleanCode(N.chainRefusal, 64);
		fields.sev = N:sevOf(fields.detail, nil, "stop");

		if fields.sev == "info"
		then
			fields.sev = "problem";
		end

		if N.chainRefusalPhase
		then
			fields.phase = N.chainRefusalPhase;
		end
	elseif reason == "because" or reason == "aborted" or reason == "done"
	then
		local kind = key and codeInfo(key) or nil;

		if key and kind == "stop"
		then
			code = key;
			fields.detail = key;
		elseif key and reason == "done"
		then
			code = "done";
			fields.detail = key;
		elseif key
		then
			code = "stopped";
			fields.detail = key;
		elseif reason == "done"
		then
			code = "done";
		elseif reason == "aborted" and said == nil and summary.reasonText == nil
		then
			code = "internal";
		else
			code = "stopped";
		end

		if key
		then
			putArgs(fields, keyA, keyB);
		end
	else
		code = cleanCode(reason);

		if reason == "unwell"
		then
			local unwell = AutoPilotMoon.Rest and AutoPilotMoon.Rest.lastUnwell;

			if unwell and unwell.moodle
			then
				fields.detail = "unwell_" .. unwell.moodle;
				fields.a1 = unwell.moodle;
				fields.n1 = unwell.level;
			end
		end
	end

	fields.text = said or summary.reasonText;

	-- the counters of the end (the macros add their experience)
	local counters = Progress():getCountersText(summary);

	if summary.doneText
	then
		counters = counters and (counters .. " - " .. summary.doneText) or summary.doneText;
	end

	fields.counters = counters;
	fields.done = summary.done;
	fields.skipped = summary.skipped;
	fields.total = state.total;

	-- a macro that stopped at a line, or ended at the condition of a line (stop(), stop_if(): MacroDoneStop,
	-- MacroDoneStopIf); Run.last is written by the macro in this same stop
	local macro = AutoPilotMoon.Macro;
	local last = macro and macro.Run and macro.Run.last;

	if summary.name == "macro" and last and last.line and (reason == "because" or reason == "done")
	then
		fields.line = last.line;
	end

	return code, fields;
end

-- ============================================================================================================
-- The run: start, stop, the watch after a stop
-- ============================================================================================================

local syncThisRun;

local function endAfter()
	if N.after
	then
		N.after = nil;
		resetWatch();
	end

	updateLive();

	-- the panel's tick kept for the watch: back to the option now
	if N.keepTick
	then
		N.keepTick = false;
		syncThisRun();
	end
end

local function openRun()
	local state = Progress().state;
	local now = getTimestampMs();
	local jobKind = "job";

	if state.kind == "chain"
	then
		jobKind = "chain";
	elseif state.name == "macro"
	then
		jobKind = "macro";
	end

	-- a job started during the watch after a stop: the watch ends, the panel's tick kept for it stays as the player
	-- sees it (it is the tick of this new job now)
	N.keepTick = false;
	endAfter();
	N.runCounter = N.runCounter + 1;
	N.run = {
		id = string.format("%.0f", now) .. "." .. N.runCounter,
		seq = 0,
		job = state.name or "job",
		jobKind = jobKind,
		player = ownerPlayer(),
		startedAt = now,
		begun = false,
		startSent = false,
		phaseSeen = {},
		warnSeen = {},
		warnA1 = {},
		warnA2 = {},
		stepCount = {},
		others = {},
		otherCount = 0,
		resting = false,
	};

	forgetKey();
	forgetSaid();
	N.pendingBad = nil;
	N.chainRefusal = nil;
	N.chainRefusalPhase = nil;
	N.mark = false;
	N.inFrame = false;
	N.errorFrames = 0;
	resetWatch();
	updateLive();
end

-- the per-run tick goes back to the player's option at the end of every run
local function resetThisRun()
	N.syncing = true;
	AutoPilotMoon.Options:set("notifyThisRun", N:getGeneralMode() ~= "off");
	N.syncing = false;
end

-- the per-run tick back to the option, and the mode told with a pref if it changed (the tick of this job was off, or
-- on with the option off)
syncThisRun = function()
	resetThisRun();

	local mode = N:getMode();

	if mode ~= N.prefMode
	then
		N.prefMode = mode;
		sendPref(mode);
	end
end

-- keepTick: the watch after this stop starts, the panel's tick stays until it ends (endAfter)
local function closeRun(keepTick)
	N.run = nil;
	N.mark = false;
	N.inFrame = false;
	N.errorFrames = 0;
	forgetKey();
	forgetSaid();
	N.pendingBad = nil;
	N.chainRefusal = nil;
	N.chainRefusalPhase = nil;
	resetWatch();
	updateLive();

	if keepTick
	then
		N.keepTick = true;

		return;
	end

	syncThisRun();
end

local function tellStop(state, summary, run)
	run.title = summary.titleText or (summary.titleKey and getText(summary.titleKey)) or run.title;

	local code, fields = stopFields(state, summary, run);

	return N:emit("stop", code, fields);
end

local function onStop(state)
	local run = N.run;
	local summary = state.summary or {};
	local sent = nil;

	if run.begun and N:isActive()
	then
		-- the run is closed whatever happens here (an error would leave it open: sentinels of a finished job)
		local ok, result = pcall(tellStop, state, summary, run);

		if ok
		then
			sent = result;
		else
			print("AutoPilot (Moon): notify: stop: " .. tostring(result));
		end
	end

	local player = run.player;
	local watch = sent ~= nil and player ~= nil and not N.noAfter[summary.reason or ""];

	-- the watch after a stop (decision D5): only when this stop was told, never after the player's own. The panel's
	-- tick of this run stays until the watch ends (endAfter), so the watch of a run told only by that tick goes on.
	closeRun(watch);

	if watch
	then
		N.after = { run = run, player = player, untilMs = getTimestampMs() + N.afterMs };
		updateLive();
	end
end

-- the phases of a chain: a phase that starts (note phase), a phase skipped (note phase_skipped); the rest is in the end
local function onPhase(state)
	local run = N.run;

	for i, phase in ipairs(state.phases)
	do
		if run.phaseSeen[i] ~= phase.status
		then
			run.phaseSeen[i] = phase.status;

			-- a phase that ended at a limit of the server (its key remembered now, in the frame of its end): the chain's
			-- end says it if no phase runs after it
			if phase.status == "done"
			then
				run.phaseKey = N.key;
				run.phaseKeyA = N.keyA;
				run.phaseKeyB = N.keyB;
			elseif phase.status == "running"
			then
				run.phaseKey = nil;
				run.phaseKeyA = nil;
				run.phaseKeyB = nil;
			end

			if (phase.status == "running" or phase.status == "skipped") and run.begun and N:isActive()
			then
				N:emit("note", phase.status == "running" and "phase" or "phase_skipped",
					{ phase = i, phases = state.phaseCount, a1 = getText(phase.labelKey) });
			end
		end
	end
end

-- the warnings grouped by Progress:warn: one warn at 1, 5, 20, 50... of each key's count. Those counted before the
-- run's first frame (at the start: plants already fertilized, a tool missing for stumps) are kept by Progress and
-- told at the first frame (beforeUpdate calls this again); a run stopped before its first frame tells nothing (3.9).
-- The arguments given with Notify:warnArgs (the item a server refused) go in a1 / a2.
local function onWarning(state)
	local run = N.run;

	if not run.begun
	then
		return;
	end

	for i, key in ipairs(state.warningOrder)
	do
		local count = state.warnings[key] or 0;
		local before = run.warnSeen[key] or 0;

		if count ~= before
		then
			run.warnSeen[key] = count;

			local crossed = false;

			for j, step in ipairs(N.warnSteps)
			do
				if before < step and count >= step
				then
					crossed = true;
				end
			end

			if crossed and N:isActive()
			then
				local code = cleanCode(key);
				local fields = { n1 = count, a1 = run.warnA1[code], a2 = run.warnA2[code] };

				if codeInfo(code) == nil
				then
					-- a key the catalogue does not know: told as information (it is only in the summary)
					fields.sev = "info";
				end

				N:emit("warn", code, fields);
			end
		end
	end
end

-- the rests of auto-rest: rest_start / rest_end (option notifyRest); a rest ended by a stop says nothing
local function onRest(state)
	local run = N.run;

	if state.resting and not run.resting
	then
		run.resting = true;

		if run.begun and N:isActive()
		then
			N:emit("warn", "rest_start", { n1 = state.restFrom, n2 = state.restTo });
		end
	elseif not state.resting and run.resting
	then
		run.resting = false;

		local automation = Automation();

		if automation.job ~= nil and run.begun and N:isActive()
		then
			local player = run.player;
			local percent = player and AutoPilotMoon.Rest and AutoPilotMoon.Rest:getEndurancePercent(player) or nil;

			N:emit("warn", "rest_end", { n1 = percent });
		end
	end
end

local function handleProgress(event, state)
	if event == "start"
	then
		openRun();

		return;
	end

	if N.run == nil
	then
		return;
	end

	if event == "stop"
	then
		onStop(state);
	elseif event == "phase"
	then
		onPhase(state);
	elseif event == "warning"
	then
		onWarning(state);
	elseif event == "rest"
	then
		onRest(state);
	end
end

-- the observer of AutoPilotMoon.Progress (added by startup, taken away by shutdown: nothing while the master switch is
-- off): never breaks a job. The sentinels' own observer (Watch.onProgress, the waits for the server) is called from here.
function AutoPilotMoon.Notify.onProgress(event, state)
	local ok, err = pcall(handleProgress, event, state);

	if not ok
	then
		print("AutoPilot (Moon): notify: " .. tostring(err));
	end

	local watch = AutoPilotMoon.Watch;

	if watch and watch.onProgress
	then
		ok, err = pcall(watch.onProgress, event, state);

		if not ok
		then
			print("AutoPilot (Moon): notify: watch: " .. tostring(err));
		end
	end
end

-- ============================================================================================================
-- Net 2: every sentence of AutoPilot (02_AP_Debug.lua, remember)
-- ============================================================================================================

-- a bad sentence said during a run and not followed by an end in the same frame: warn/other, the same sentence at
-- most once a minute
local function flushBad()
	local sentence = N.pendingBad;
	local run = N.run;

	N.pendingBad = nil;

	if sentence == nil or run == nil or not N:isActive()
	then
		return;
	end

	local now = getTimestampMs();
	local at = run.others[sentence];

	if at and now - at < N.otherRepeatMs
	then
		return;
	end

	if run.otherCount >= 50
	then
		run.others = {};
		run.otherCount = 0;
	end

	if at == nil
	then
		run.otherCount = run.otherCount + 1;
	end

	run.others[sentence] = now;
	N:emit("warn", "other", { text = sentence });
end

-- player: who hears it (nil when the caller did not say); a sentence for another player is not this run's
function AutoPilotMoon.Notify:onMessage(level, sentence, player)
	if N.muted or N.run == nil or (player ~= nil and N.run.player ~= nil and player ~= N.run.player)
	then
		return;
	end

	if level == "bad" or level == "good" or level == "plain"
	then
		if N.saidCount >= N.saidMax
		then
			for i = 1, N.saidCount - 1
			do
				N.saidText[i] = N.saidText[i + 1];
				N.saidLevel[i] = N.saidLevel[i + 1];
			end

			N.saidCount = N.saidCount - 1;
		end

		N.saidCount = N.saidCount + 1;
		N.saidText[N.saidCount] = sentence;
		N.saidLevel[N.saidCount] = level;
	end

	-- only a sentence of the job itself: said inside the engine's part of the run's player update (a sentence of the
	-- interface, said by a click while the job runs, is the player's own: never sent, ANALISI-NOTIFICHE-DISCORD.md 3.9)
	if level == "bad" and N.run.begun and N.inFrame
	then
		if N.pendingBad
		then
			flushBad();
		end

		N.pendingBad = sentence;
	end
end

-- ============================================================================================================
-- The player update (99_AP_Event.lua): before and after the engine's part, each in pcall there
-- ============================================================================================================

function AutoPilotMoon.Notify:beforeUpdate(player)
	local run = N.run;

	if run and run.player == player
	then
		-- the engine's frame before did not reach its end: a Lua error (engine_error after 3 in a row)
		if N.mark
		then
			N.errorFrames = N.errorFrames + 1;
		else
			N.errorFrames = 0;
		end

		flushBad();
		forgetKey();
		forgetSaid();

		if N.errorFrames >= N.engineErrorFrames and N:isActive()
		then
			N.mark = false;
			N.errorFrames = 0;
			N:code("engine_error");

			local automation = Automation();
			local ok, err = pcall(automation.stopAll, automation, "aborted");

			if not ok
			then
				print("AutoPilot (Moon): notify: engine_error stop: " .. tostring(err));
			end

			-- the stop itself failed (the run is still open): told from here and closed, never tried again
			if N.run == run
			then
				N:code("engine_error");
				N:emit("stop", "engine_error", { reason = "aborted", text = tostring(err) });
				closeRun();
			end

			forgetKey();

			return;
		end

		-- the first frame of the run: its start
		if not run.begun
		then
			run.begun = true;
			run.title = titleNow();

			if N:isActive()
			then
				local state = Progress().state;
				local macro = AutoPilotMoon.Macro;
				local macroRun = macro and macro.Run and macro.Run.current;
				local fields = { total = state.total, done = state.done, n1 = state.cappedFrom };

				if state.unitKey
				then
					fields.a1 = getText(state.unitKey);
				end

				if run.jobKind == "macro" and macroRun and macroRun.modeText
				then
					fields.a2 = macroRun.modeText;
				end

				run.startSent = N:emit("start", "start", fields) ~= nil;
			end

			-- the warnings counted before this first frame (at the start of the job)
			onWarning(Progress().state);
		elseif run.lateDue
		then
			-- a listener came while the run was going (subscribe): it is followed from now
			run.lateDue = false;

			if not run.startSent
			then
				run.startSent = N:emit("start", "start_late", nil) ~= nil;
			end
		end

		N.mark = true;
		N.inFrame = true;
	elseif N.after and N.after.player == player
	then
		-- the player is back at the keyboard: the watch after the stop ends
		if player:pressedMovement(false)
		then
			endAfter();
		end
	end
end

function AutoPilotMoon.Notify:afterUpdate(player)
	local run = N.run;

	if run and run.player == player
	then
		N.mark = false;
		N.inFrame = false;
		N.errorFrames = 0;
		flushBad();
		forgetKey();
		forgetSaid();
	end

	local now = getTimestampMs();
	local after = N.after;

	if after and after.player == player and (now > after.untilMs or not N:isActive())
	then
		endAfter();

		return;
	end

	if now - N.lastTick < N.tickMs or not N:isActive()
	then
		return;
	end

	local watch = AutoPilotMoon.Watch;

	if N.run and N.run.player == player and N.run.begun
	then
		N.lastTick = now;

		if watch and watch.tick
		then
			local ok, err = pcall(watch.tick, watch, Automation().job, player, now);

			if not ok
			then
				print("AutoPilot (Moon): notify: watch: " .. tostring(err));
			end
		end
	elseif N.after and N.after.player == player
	then
		N.lastTick = now;

		if watch and watch.after
		then
			local ok, err = pcall(watch.after, watch, player, now);

			if not ok
			then
				print("AutoPilot (Moon): notify: watch: " .. tostring(err));
			end
		end
	end
end

-- a macro's action confirmed (MacroRun.lua, actionDone, WP1c): handed to the sentinels (Watch:onMacroAction(run,
-- pending, player), WP1d: materials_low), only while something would be sent; never an error for the macro
function AutoPilotMoon.Notify:onMacroAction(run, pending)
	local watch = AutoPilotMoon.Watch;

	if watch == nil or watch.onMacroAction == nil or N.run == nil or not N.run.begun or not N:isActive()
	then
		return;
	end

	local ok, err = pcall(watch.onMacroAction, watch, run, pending, N.run.player);

	if not ok
	then
		print("AutoPilot (Moon): notify: watch: " .. tostring(err));
	end
end

-- a local player died (99_AP_Event.lua): during the watch after a stop, "dead"
function AutoPilotMoon.Notify:onPlayerDeath(player)
	local after = N.after;

	if after and after.player == player
	then
		if N:isActive()
		then
			N:emit("stop", "dead", { reason = "dead" });
		end

		endAfter();
	end
end

-- ============================================================================================================
-- The options, the master switch, the stop from outside
-- ============================================================================================================

-- an option of the notifications changed (the Options screen's Apply, Options:set, the panel's tick): the per-run
-- tick follows the option, a pref tells the new mode, a job running now is followed from now (start_late)
function AutoPilotMoon.Notify:onOptionsChanged()
	if N.syncing
	then
		return;
	end

	local general = N:getGeneralMode();

	if general ~= N.lastGeneral
	then
		N.lastGeneral = general;
		N.syncing = true;
		AutoPilotMoon.Options:set("notifyThisRun", general ~= "off");
		N.syncing = false;
	end

	local mode = N:getMode();

	if mode ~= N.prefMode
	then
		N.prefMode = mode;
		sendPref(mode);
	end

	-- a job running now that was not told (the mode was off, or "Avvisi per" left it out): followed from now
	local run = N.run;

	if run and run.begun and mode ~= "off" and not run.startSent
	then
		run.startSent = N:emit("start", "start_late", nil) ~= nil;
	end

	if mode == "off"
	then
		endAfter();
	end
end

-- the master switch turned on (06_AP_Switch.lua): the observer of Progress added, the per-run tick from the option,
-- the mode told
function AutoPilotMoon.Notify:startup()
	Progress():subscribe(N.onProgress);
	N.lastGeneral = nil;
	N:onOptionsChanged();
end

-- the master switch turned off (06_AP_Switch.lua, after the stop of what ran, before the events go): the run and the
-- watch after a stop end, the mode "off" is told
function AutoPilotMoon.Notify:shutdown()
	if N.run
	then
		closeRun();
	end

	endAfter();
	forgetKey();
	forgetSaid();
	N.pendingBad = nil;

	if N.prefMode ~= "off"
	then
		N.prefMode = "off";
		sendPref("off");
	end

	updateLive();

	-- nothing of the notifications while the master switch is off (the stop of what ran has been told before this)
	Progress():unsubscribe(N.onProgress);
end

-- the stop and the status asked from outside (the bridge, a button on Discord)
function AutoPilotMoon.Notify:control(command, args)
	local automation = Automation();

	if command == "status"
	then
		return true, (automation:isBusy() and "running" or "idle");
	end

	if command ~= "stop"
	then
		return false, "unknown";
	end

	if not switchOn() or not automation:isBusy()
	then
		return true, "nothing";
	end

	local player = ownerPlayer();
	local ok, err = pcall(automation.stopAll, automation, "remote");

	-- decision D7: what the player queued by hand goes too (also between two phases of a chain, where there is no job)
	if player and ISTimedActionQueue and ISTimedActionQueue.clear
	then
		pcall(ISTimedActionQueue.clear, player);
	end

	if not ok
	then
		print("AutoPilot (Moon): notify: remote stop: " .. tostring(err));

		return false, "error";
	end

	return true, "stopped";
end
