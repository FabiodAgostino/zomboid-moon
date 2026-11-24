-- AutoPilot (Moon): automations for the Moon server.

-- The sentinels of the notifications (20/11/2026, WP1d of ANALISI-NOTIFICHE-DISCORD.md, sections 3.7 and 6.7; contract
-- NOTIFICHE-CONTRATTO.md and tests/notify_contract.json): what the engine does not say by itself while a job, a chain
-- or a macro runs, and in the 10 minutes after a stop (decision D5 of 20/11/2026), as warnings of the centralino
-- (client/47_AP_Notify.lua, Notify:emit). AutoPilot never talks to the network: these are local events only.
--
-- Who calls what (the centralino, never a game event of this file):
--   Watch:tick(job, player, nowMs)       once a second while a run is open, has had its first frame and something would
--                                        be sent (job = Automation.job, nil between two phases of a chain)
--   Watch:after(player, nowMs)           once a second in the watch after a stop: only the dangers (zombies, attacks,
--                                        the body, the critical moodles, death); the events carry after = true
--   Watch:reset()                        at every start, stop and shutdown (the run's state wiped; the body's last
--                                        sample is kept a few seconds, so the watch after a stop goes on from it)
--   Watch:onMacroAction(run, pending, player)   a macro's action confirmed (WP1c, through Notify:onMacroAction):
--                                        materials_low
-- The waits for the server (server_slow) are counted by Watch.onProgress, which the centralino's observer of
-- AutoPilotMoon.Progress calls (the mod's own model, not a game event, only while the master switch is on); it does
-- nothing until the first tick of a run.
--
-- Cheap by construction: nothing per frame, no scan of the zombies of the cell. The zombies in sight are read from the
-- game's own list of what the character sees now (IsoPlayer.getSpottedList, rebuilt by the game at every LOS update),
-- at most limits.spottedMax entries; being attacked is the game's own count of the attackers on the 3 x 3 squares
-- around (getSurroundingAttackingZombies). The body, the moodles, the hand, the weight, the light are single reads.
-- The supplies (sacks, water, seeds) look at the inventory at most every limits.suppliesEveryMs, only for the job that
-- uses them. No table is made by a tick that tells nothing (Watch.tables counts the ones made here); every sentinel
-- runs in its own pcall, an error is printed once per run and never stops the others nor the job.
--
-- Every threshold is in Watch.limits, the 26 moodles of 42.22 (MoodleType) with theirs in Watch.moodles; the rules
-- of repetition (T = at most once every n seconds, S = steps, U = once) and of re-arming are written next to each
-- sentinel below. Not here (WP1a): rest_long (52_AP_Rest.lua) and engine_error (47_AP_Notify.lua).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Watch = AutoPilotMoon.Watch or {};

local W = AutoPilotMoon.Watch;

W.limits = {
	-- zombies_seen (early): zombies the character sees on its floor within zombiesRange tiles, for zombiesConfirmMs in
	-- a row; T 120 s, at once again when the nearest comes under zombiesNear tiles or the number doubles; re-armed after
	-- zombiesRearmMs without any; the first one of the watch after a stop is critical
	zombiesRange = 20,
	zombiesConfirmMs = 3000,
	zombiesRepeatMs = 120000,
	zombiesNear = 10,
	zombiesDouble = 2,
	zombiesRearmMs = 30000,
	spottedMax = 100,
	-- attacked (early): the game's attackers around the character, at once; T 30 s
	attackedRepeatMs = 30000,
	-- hurt (always): health lost hurtDrop points in a second, or hurtTotal since the start; then each of hurtSteps
	-- crossed downwards (S first drop > 75 > 50 > 25); the first drop again after hurtRearmMs without a loss, a step
	-- again when health is back hurtStepRearm points above it
	hurtDrop = 3,
	hurtTotal = 10,
	hurtSteps = { 75, 50, 25 },
	hurtRearmMs = 120000,
	hurtStepRearm = 5,
	-- bitten (always): more parts bitten than at the start; U
	-- scratched (always): more parts scratched than last told; T 60 s
	scratchedRepeatMs = 60000,
	-- bleeding (always): parts bleeding 1 > 2 > 3 (S); the steps again after bleedingRearmMs without bleeding
	bleedingSteps = 3,
	bleedingRearmMs = 30000,
	-- on_fire (always): at once; T 30 s
	onFireRepeatMs = 30000,
	-- moodle (early): a level at its threshold (Watch.moodles) for moodleConfirmMs; S one message per new level;
	-- re-armed after moodleRearmMs under the threshold
	moodleConfirmMs = 5000,
	moodleRearmMs = 60000,
	-- materials_low (early, macros): an item the action used, materialsLeft or fewer left and fewer than before; U per type
	materialsLeft = 2,
	-- sacks_low, water_low, seeds_low (early): U per run
	sacksLeft = 2,
	waterRatio = 0.2,
	seedsLeft = 5,
	suppliesEveryMs = 5000,
	-- tool_worn (early): the tool in hand (or its head) at toolWornRatio of its maximum or less, at least 1; U per tool
	-- tool_broken (early): the tool in hand (or the one that just left the hand) broken; U per tool
	toolWornRatio = 0.15,
	-- load_high (early): weight / maximum at loadRatio for loadConfirmMs; U, re-armed under loadRearmRatio
	loadRatio = 0.9,
	loadConfirmMs = 5000,
	loadRearmRatio = 0.8,
	-- dusk (early): less than duskHours game hours to dusk (the season's, ClimateManager.getSeason():getDusk()), for a job
	-- the dark stops; U per game day
	duskHours = 1,
	-- dark_now (early): the night's strength at darkStrength or more, outdoors, for darkConfirmMs; U per night
	darkStrength = 0.7,
	darkConfirmMs = 10000,
	-- no_progress (early): nothing done, counted or changed in the activity; S 120 > 300 > 600 s (problem at 600),
	-- not while resting or in a pause the macro wants
	noProgressSteps = { 120000, 300000, 600000 },
	noProgressProblemMs = 600000,
	-- stalled (early): no action, the same square; S 45 > 180 s, the same exclusions
	stalledSteps = { 45000, 180000 },
	-- server_slow (early): serverSlowCount waits for the server within serverSlowWindowMs; T 600 s
	serverSlowCount = 3,
	serverSlowWindowMs = 120000,
	serverSlowRepeatMs = 600000,
	-- the body's last sample still counts as "just before" this long (between a stop and its watch, two runs in a row)
	bodyCarryMs = 3000,
};

-- The 26 moodles of 42.22 (zombie.scripting.objects.MoodleType, javap of the jar), each with its threshold (ANALISI-
-- NOTIFICHE-DISCORD.md 3.7): at = first level told (nil = never), sev = its severity, up / upSev = the level from which
-- the severity is upSev, once = a single warning per run (no steps, no re-arm). MoodleType is a class with static
-- fields, not an enum: every name is checked with MoodleType[name] ~= nil before use (a later game without one skips
-- it). ENDURANCE: the automatic rest handles it (3.5, rest_long and TooTired cover the rest), so it is told only while
-- the automatic rest is off (noRest): "endurance low", at "Overexerted" (3) as a notice, at 4 as a problem.
W.moodles = {
	{ name = "ENDURANCE", at = 3, sev = "notice", up = 4, upSev = "problem", noRest = true },
	{ name = "TIRED", at = 2, sev = "notice", up = 4, upSev = "problem" },
	{ name = "HUNGRY", at = 2, sev = "notice", up = 3, upSev = "problem" },
	{ name = "PANIC", at = 2, sev = "notice", up = 3, upSev = "critical" },
	{ name = "SICK", at = 1, sev = "notice", up = 3, upSev = "problem" },
	{ name = "BORED", at = 3, sev = "notice", once = true },
	{ name = "UNHAPPY", at = 3, sev = "notice", once = true },
	{ name = "BLEEDING", at = 1, sev = "critical" },
	{ name = "WET", at = 3, sev = "notice" },
	{ name = "HAS_A_COLD", at = 2, sev = "notice", up = 3, upSev = "problem" },
	{ name = "ANGRY", at = 3, sev = "notice", once = true },
	{ name = "STRESS", at = 3, sev = "notice", once = true },
	{ name = "THIRST", at = 2, sev = "notice", up = 3, upSev = "problem" },
	{ name = "INJURED", at = 1, sev = "notice", up = 2, upSev = "critical" },
	{ name = "PAIN", at = 2, sev = "notice", up = 3, upSev = "problem" },
	{ name = "HEAVY_LOAD", at = 1, sev = "notice", up = 3, upSev = "problem" },
	{ name = "DRUNK", at = 3, sev = "notice" },
	{ name = "DEAD", at = 1, sev = "critical" },
	{ name = "ZOMBIE", at = 1, sev = "critical" },
	{ name = "HYPERTHERMIA", at = 2, sev = "notice", up = 3, upSev = "critical" },
	{ name = "HYPOTHERMIA", at = 2, sev = "notice", up = 3, upSev = "critical" },
	{ name = "WINDCHILL", at = 3, sev = "notice" },
	{ name = "CANT_SPRINT" },
	{ name = "UNCOMFORTABLE", at = 3, sev = "notice", once = true },
	{ name = "NOXIOUS_SMELL", at = 3, sev = "notice", once = true },
	{ name = "FOOD_EATEN" },
};

-- a moodle of the list without a threshold of its own: the general rule (a notice at level 3); CANT_SPRINT and
-- FOOD_EATEN are not problems (never = true)
W.moodleDefault = { at = 3, sev = "notice" };
W.moodleNever = { CANT_SPRINT = true, FOOD_EATEN = true };

-- the activities that are a wanted pause, not a stuck job (no_progress, stalled): the macro's wait(), the server's
-- actions per minute, a bench another player uses, rest() and the automatic rest
W.pauseKeys = {
	IGUI_AutoPilot_P_Now_MacroWait = true,
	IGUI_AutoPilot_P_Now_MacroRate = true,
	IGUI_AutoPilot_P_Now_MacroBenchBusy = true,
	IGUI_AutoPilot_P_Now_MacroResting = true,
	IGUI_AutoPilot_P_Now_Sitting = true,
};

-- the macro actions that last minutes by design (one action: exercise, read, rest): not "no progress"
W.longKinds = { exercise = true, read = true, rest = true };

-- the jobs the dark stops (dusk): the Sawyer, the Firewood, and a macro with a recipe
W.darkJobs = { sawyer = true, firewood = true };

-- every code this file sends (the test checks it against the contract, both ways)
W.codes = { "zombies_seen", "attacked", "hurt", "bitten", "scratched", "bleeding", "on_fire", "moodle",
	"materials_low", "sacks_low", "water_low", "seeds_low", "tool_worn", "tool_broken", "load_high", "dusk", "dark_now",
	"no_progress", "stalled", "server_slow" };

-- the tables made by this file (the test checks that a tick that tells nothing makes none)
W.tables = W.tables or 0;

local function newTable()
	W.tables = W.tables + 1;

	return {};
end

local L = W.limits;

-- ============================================================================================================
-- State: one table for the run (wiped by reset, its fields reused), one for the body (kept across a reset while
-- fresh), one per moodle; made once at load
-- ============================================================================================================

W.st = W.st or newTable();
W.body = W.body or newTable();
W.moodleState = W.moodleState or newTable();

for i, entry in ipairs(W.moodles)
do
	if W.moodleState[i] == nil
	then
		W.moodleState[i] = newTable();
	end
end

-- W.armed: a run's first tick happened, the observer of the waits counts. W.duskDay / W.darkNight: the game day of
-- the last dusk told and the night of the last dark told (U per game day / per night, across runs, never reset).
W.armed = false;

local function resetMoodles()
	for i, ms in ipairs(W.moodleState)
	do
		ms.sent = 0;          -- the highest level told
		ms.cand = 0;          -- the level seen, and since when
		ms.since = 0;
		ms.below = nil;       -- under the threshold since
		ms.done = false;      -- once: told for this run
	end
end

local function resetState()
	local st = W.st;

	st.player = nil;
	st.failed = newTable();   -- sentinel -> true: its error printed once for this run
	-- zombies_seen
	st.zSince = nil;
	st.zNoneSince = nil;
	st.zSentAt = nil;
	st.zSentCount = 0;
	st.zSentDist = nil;
	st.zAfterTold = false;
	-- attacked
	st.attackedAt = nil;
	-- materials_low: item type -> left at the last confirmed action / told
	st.matCount = newTable();
	st.matSent = newTable();
	-- supplies
	st.suppliesAt = 0;
	st.sacksSent = false;
	st.waterSent = false;
	st.waterMax = 0;
	st.seedsSent = false;
	-- tools: the item in hand at the last tick; id -> told
	st.toolRef = nil;
	st.toolRefOk = false;
	st.toolWorn = newTable();
	st.toolBroken = newTable();
	-- load_high
	st.loadSince = nil;
	st.loadSent = false;
	-- dark
	st.darkSince = nil;
	st.darkJob = nil;
	st.darkJobOf = nil;
	-- no_progress
	st.pDone = nil;
	st.pSkipped = nil;
	st.pSum = nil;
	st.pKey = nil;
	st.pArg1 = nil;
	st.pSince = nil;
	st.pStep = 0;
	-- stalled
	st.sX = nil;
	st.sY = nil;
	st.sZ = nil;
	st.sSince = nil;
	st.sStep = 0;
	-- server_slow: the last three waits, the last told
	st.waitOn = false;
	st.wait1 = nil;
	st.wait2 = nil;
	st.wait3 = nil;
	st.slowAt = nil;

	resetMoodles();
end

local function initBody(b)
	b.player = nil;
	b.at = nil;
	b.hurtSteps = b.hurtSteps or newTable();
end

initBody(W.body);
resetState();

-- ============================================================================================================
-- Small helpers
-- ============================================================================================================

local function Notify()
	return AutoPilotMoon.Notify;
end

local function emit(code, fields)
	return Notify():emit("warn", code, fields);
end

local function round(value)
	return math.floor(value + 0.5);
end

-- getText with exactly the arguments the activity has (the game's getText takes Object...)
local function activityText(state)
	local key = state.activityKey;

	if key == nil
	then
		return nil;
	elseif state.activityArg1 == nil
	then
		return getText(key);
	elseif state.activityArg2 == nil
	then
		return getText(key, state.activityArg1);
	end

	return getText(key, state.activityArg1, state.activityArg2);
end

-- a wanted pause of the run (rest, a pause of the macro, a macro action that lasts minutes)
local function inPause(state)
	if state.resting or W.pauseKeys[state.activityKey or ""]
	then
		return true;
	end

	local macro = AutoPilotMoon.Macro;
	local macroRun = macro and macro.Run and macro.Run.current;
	local pending = macroRun and macroRun.pending;
	local op = pending and pending.op;

	return op ~= nil and W.longKinds[op.kind or ""] == true;
end

-- runs one sentinel in pcall; its error printed once per run
local function guard(name, fn, a, b, c, d)
	local ok, err = pcall(fn, a, b, c, d);

	if not ok and not W.st.failed[name]
	then
		W.st.failed[name] = true;
		print("AutoPilot (Moon): watch: " .. name .. ": " .. tostring(err));
	end
end

-- ============================================================================================================
-- The sentinels
-- ============================================================================================================

-- the zombies the character sees now on its floor within range: how many and the nearest distance (nil: none), from
-- the game's list of what the character sees, at most spottedMax entries (the centralino's helper, the same numbers
-- as zSeen / zDist of every event)
local function seenZombies(player, range)
	return AutoPilotMoon.Notify.seenZombies(player, range, L.spottedMax);
end

-- zombies_seen: see limits
local function checkZombies(player, now, afterMode)
	local st = W.st;
	local ok, count, nearest = pcall(seenZombies, player, L.zombiesRange);

	if not ok
	then
		-- no list: the game's counter of the zombies the character sees near it, the distance unknown
		count = player:getStats():getNumVisibleZombies() or 0;
		nearest = nil;
	end

	if count <= 0
	then
		st.zSince = nil;

		if st.zNoneSince == nil
		then
			st.zNoneSince = now;
		end

		if st.zSentAt ~= nil and now - st.zNoneSince >= L.zombiesRearmMs
		then
			st.zSentAt = nil;
			st.zSentCount = 0;
			st.zSentDist = nil;
		end

		return;
	end

	st.zNoneSince = nil;

	if st.zSince == nil
	then
		st.zSince = now;
	end

	if now - st.zSince < L.zombiesConfirmMs
	then
		return;
	end

	local due = false;

	if st.zSentAt == nil or now - st.zSentAt >= L.zombiesRepeatMs
	then
		due = true;
	elseif nearest ~= nil and nearest < L.zombiesNear and (st.zSentDist == nil or st.zSentDist >= L.zombiesNear)
	then
		due = true;
	elseif count >= st.zSentCount * L.zombiesDouble
	then
		due = true;
	end

	if not due
	then
		return;
	end

	local fields = newTable();

	fields.n1 = count;
	fields.n2 = nearest and round(nearest) or -1;

	-- the character stands still after a stop and zombies are in sight: the first one is critical
	if afterMode and not st.zAfterTold
	then
		fields.sev = "critical";
		st.zAfterTold = true;
	end

	emit("zombies_seen", fields);
	st.zSentAt = now;
	st.zSentCount = count;
	st.zSentDist = nearest;
end

-- attacked: see limits
local function checkAttacked(player, now)
	local st = W.st;
	local n = player:getSurroundingAttackingZombies() or 0;

	if n > 0 and (st.attackedAt == nil or now - st.attackedAt >= L.attackedRepeatMs)
	then
		local fields = newTable();

		fields.n1 = n;
		emit("attacked", fields);
		st.attackedAt = now;
	end
end

-- hurt, bitten, scratched, bleeding, on_fire (always): the body against its sample of a second before
local function checkBody(player, now)
	local b = W.body;
	local damage = player:getBodyDamage();
	local hp = damage:getOverallBodyHealth();
	local bitten = damage:getNumPartsBitten();
	local scratched = damage:getNumPartsScratched();
	local bleeding = damage:getNumPartsBleeding();

	if b.player ~= player or b.at == nil or now - b.at > L.bodyCarryMs
	then
		-- a new watch: the character as it is now is the start, nothing told
		b.player = player;
		b.hpStart = hp;
		b.hpPrev = hp;
		b.hurtFirst = false;
		b.lastDropAt = nil;

		for i, step in ipairs(L.hurtSteps)
		do
			b.hurtSteps[i] = hp < step;
		end

		b.bittenRef = bitten;
		b.bittenSent = false;
		b.scratchRef = scratched;
		b.scratchedAt = nil;
		b.bleedSent = 0;
		b.bleedZeroSince = nil;
		b.fireAt = nil;
	end

	b.at = now;

	-- hurt
	local drop = b.hpPrev - hp;

	b.hpPrev = hp;

	if drop > 0
	then
		b.lastDropAt = now;
	end

	if b.hurtFirst and b.lastDropAt ~= nil and now - b.lastDropAt >= L.hurtRearmMs
	then
		b.hurtFirst = false;
		b.hpStart = hp;
	end

	local tell = false;

	if not b.hurtFirst and (drop >= L.hurtDrop or b.hpStart - hp >= L.hurtTotal)
	then
		b.hurtFirst = true;
		tell = true;
	end

	for i, step in ipairs(L.hurtSteps)
	do
		if b.hurtSteps[i]
		then
			if hp >= step + L.hurtStepRearm
			then
				b.hurtSteps[i] = false;
			end
		elseif hp < step
		then
			b.hurtSteps[i] = true;
			tell = true;
		end
	end

	if tell
	then
		local fields = newTable();

		fields.n1 = round(hp);
		fields.n2 = round(b.hpStart - hp);
		emit("hurt", fields);
	end

	-- bitten
	if not b.bittenSent and bitten > b.bittenRef
	then
		local fields = newTable();

		fields.n1 = bitten;
		emit("bitten", fields);
		b.bittenSent = true;
	end

	-- scratched
	if scratched < b.scratchRef
	then
		b.scratchRef = scratched;
	elseif scratched > b.scratchRef and (b.scratchedAt == nil or now - b.scratchedAt >= L.scratchedRepeatMs)
	then
		local fields = newTable();

		fields.n1 = scratched;
		emit("scratched", fields);
		b.scratchedAt = now;
		b.scratchRef = scratched;
	end

	-- bleeding
	if bleeding <= 0
	then
		if b.bleedZeroSince == nil
		then
			b.bleedZeroSince = now;
		end

		if b.bleedSent > 0 and now - b.bleedZeroSince >= L.bleedingRearmMs
		then
			b.bleedSent = 0;
		end
	else
		b.bleedZeroSince = nil;

		local step = bleeding;

		if step > L.bleedingSteps
		then
			step = L.bleedingSteps;
		end

		if step > b.bleedSent
		then
			local fields = newTable();

			fields.n1 = bleeding;
			emit("bleeding", fields);
			b.bleedSent = step;
		end
	end

	-- on_fire
	if player:isOnFire() and (b.fireAt == nil or now - b.fireAt >= L.onFireRepeatMs)
	then
		emit("on_fire", nil);
		b.fireAt = now;
	end
end

-- the game's name of a moodle at its level now (Moodles.getMoodleDisplayString), or nil
local function moodleName(moodles, moodleType)
	return moodles:getMoodleDisplayString(moodleType);
end

-- moodle: every moodle of the list at its threshold for moodleConfirmMs; afterMode: only the critical steps
local function checkMoodles(player, now, afterMode)
	local moodles = player:getMoodles();

	if moodles == nil
	then
		return;
	end

	local restOn = nil;

	for i, entry in ipairs(W.moodles)
	do
		local ms = W.moodleState[i];
		local moodleType = MoodleType[entry.name];
		local at = entry.at;
		local sev = entry.sev;

		if at == nil and not W.moodleNever[entry.name]
		then
			at = W.moodleDefault.at;
			sev = W.moodleDefault.sev;
		end

		if entry.noRest and at ~= nil
		then
			if restOn == nil
			then
				restOn = AutoPilotMoon.Rest ~= nil and AutoPilotMoon.Rest:isEnabled() == true;
			end

			if restOn
			then
				at = nil;
			end
		end

		if at ~= nil and moodleType ~= nil and not ms.done
		then
			local level = moodles:getMoodleLevel(moodleType) or 0;

			if level >= at
			then
				ms.below = nil;

				if level ~= ms.cand
				then
					ms.cand = level;
					ms.since = now;
				end

				if level > ms.sent and now - ms.since >= L.moodleConfirmMs
				then
					local levelSev = sev;

					if entry.up and level >= entry.up
					then
						levelSev = entry.upSev;
					end

					if not afterMode or levelSev == "critical"
					then
						local fields = newTable();
						local okName, name = pcall(moodleName, moodles, moodleType);

						fields.a1 = entry.name;
						fields.a2 = okName and type(name) == "string" and name ~= "" and name or nil;
						fields.n1 = level;
						fields.sev = levelSev;
						emit("moodle", fields);
						ms.sent = level;

						if entry.once
						then
							ms.done = true;
						end
					end
				end
			else
				ms.cand = level;

				if ms.sent > 0
				then
					if ms.below == nil
					then
						ms.below = now;
					end

					if now - ms.below >= L.moodleRearmMs
					then
						ms.sent = 0;
						ms.below = nil;
					end
				end
			end
		end
	end
end

-- tool_worn, tool_broken: the tool in hand; and the one that just left the hand, if it broke
local function toolBroken(item)
	local st = W.st;
	local id = item:getID();

	if not st.toolBroken[id]
	then
		local fields = newTable();

		fields.a1 = item:getDisplayName();
		emit("tool_broken", fields);
		st.toolBroken[id] = true;
	end
end

local function checkTool(player, now)
	local st = W.st;
	local hand = player:getPrimaryHandItem();
	local before = st.toolRef;

	-- the tool that was whole in hand at the last tick is broken now (still in hand, or the game took it off): a break
	-- of this run, never one the character already had
	if before ~= nil and st.toolRefOk and before:isBroken()
	then
		toolBroken(before);
	end

	st.toolRef = hand;
	st.toolRefOk = hand ~= nil and not hand:isBroken();

	if not st.toolRefOk
	then
		return;
	end

	local max = hand:getConditionMax() or 0;

	if max <= 0
	then
		return;
	end

	local condition = hand:getCondition() or 0;
	local ratio = condition / max;

	if hand:hasHeadCondition()
	then
		local headMax = hand:getHeadConditionMax() or 0;
		local head = hand:getHeadCondition() or 0;

		if headMax > 0 and head / headMax < ratio
		then
			condition = head;
			max = headMax;
			ratio = head / headMax;
		end
	end

	local id = hand:getID();

	if condition >= 1 and ratio <= L.toolWornRatio and not st.toolWorn[id]
	then
		local fields = newTable();

		fields.a1 = hand:getDisplayName();
		fields.n1 = condition;
		fields.n2 = max;
		emit("tool_worn", fields);
		st.toolWorn[id] = true;
	end
end

-- load_high: see limits
local function checkLoad(player, now)
	local st = W.st;
	local max = player:getMaxWeight() or 0;

	if max <= 0
	then
		return;
	end

	local ratio = (player:getInventoryWeight() or 0) / max;

	if ratio >= L.loadRatio
	then
		if st.loadSince == nil
		then
			st.loadSince = now;
		end

		if not st.loadSent and now - st.loadSince >= L.loadConfirmMs
		then
			local fields = newTable();

			fields.n1 = round(ratio * 100);
			emit("load_high", fields);
			st.loadSent = true;
		end
	else
		st.loadSince = nil;

		if st.loadSent and ratio < L.loadRearmRatio
		then
			st.loadSent = false;
		end
	end
end

-- a macro's program has a recipe
local function hasRecipe(ops)
	for i, op in ipairs(ops)
	do
		if op.kind == "craft"
		then
			return true;
		end
	end

	return false;
end

-- a job the dark stops: the Sawyer, the Firewood, a macro with a recipe (looked at once per job)
local function darkStops(job)
	local st = W.st;

	if job == nil
	then
		return false;
	end

	if st.darkJobOf ~= job
	then
		st.darkJobOf = job;
		st.darkJob = W.darkJobs[job.name or ""] == true;

		if not st.darkJob and job.name == "macro"
		then
			local macro = AutoPilotMoon.Macro;
			local macroRun = macro and macro.Run and macro.Run.current;
			local result = macroRun and macroRun.result;

			if result and result.ops
			then
				st.darkJob = hasRecipe(result.ops);
			end

			if result and result.handlers and not st.darkJob
			then
				for i, handler in ipairs(result.handlers)
				do
					if handler.ops and hasRecipe(handler.ops)
					then
						st.darkJob = true;
					end
				end
			end
		end
	end

	return st.darkJob;
end

-- dusk, dark_now: see limits
local function checkLight(job, player, now)
	local st = W.st;

	if darkStops(job)
	then
		-- the season's dusk in hours (ErosionSeason.getDusk, as the game's foraging): GameTime.getDusk is a fixed old
		-- field (3), not the dusk
		local gameTime = getGameTime();
		local left = getClimateManager():getSeason():getDusk() - gameTime:getTimeOfDay();

		if left > 0 and left <= L.duskHours
		then
			local day = math.floor(gameTime:getWorldAgeHours() / 24);

			if W.duskDay ~= day
			then
				local fields = newTable();

				fields.n1 = round(left * 60);
				emit("dusk", fields);
				W.duskDay = day;
			end
		end
	end

	local strength = getClimateManager():getNightStrength();

	if strength >= L.darkStrength and player:isOutside()
	then
		if st.darkSince == nil
		then
			st.darkSince = now;
		end

		-- a night runs over midnight: counted from noon to noon
		local night = math.floor((getGameTime():getWorldAgeHours() + 12) / 24);

		if now - st.darkSince >= L.darkConfirmMs and W.darkNight ~= night
		then
			local fields = newTable();

			fields.n1 = round(strength * 100);
			emit("dark_now", fields);
			W.darkNight = night;
		end
	else
		st.darkSince = nil;
	end
end

-- no_progress, stalled: see limits
local function checkProgress(player, now)
	local st = W.st;
	local state = AutoPilotMoon.Progress.state;
	local paused = inPause(state);
	local sum = 0;

	for i, key in ipairs(state.counterOrder)
	do
		sum = sum + (state.counters[key] or 0);
	end

	local changed = st.pSince == nil or state.done ~= st.pDone or state.skipped ~= st.pSkipped or sum ~= st.pSum
		or state.activityKey ~= st.pKey or state.activityArg1 ~= st.pArg1;

	if paused or changed
	then
		st.pDone = state.done;
		st.pSkipped = state.skipped;
		st.pSum = sum;
		st.pKey = state.activityKey;
		st.pArg1 = state.activityArg1;
		st.pSince = now;
		st.pStep = 0;
	else
		local step = L.noProgressSteps[st.pStep + 1];

		if step ~= nil and now - st.pSince >= step
		then
			local fields = newTable();

			fields.n1 = math.floor((now - st.pSince) / 60000);
			fields.a1 = activityText(state);

			if step >= L.noProgressProblemMs
			then
				fields.sev = "problem";
			end

			emit("no_progress", fields);
			st.pStep = st.pStep + 1;
		end
	end

	local x = math.floor(player:getX());
	local y = math.floor(player:getY());
	local z = math.floor(player:getZ());

	-- stalled: the job does not go on (no progress either) and the character neither moves nor acts
	if paused or changed or st.sSince == nil or x ~= st.sX or y ~= st.sY or z ~= st.sZ
		or ISTimedActionQueue.isPlayerDoingAction(player)
	then
		st.sX = x;
		st.sY = y;
		st.sZ = z;
		st.sSince = now;
		st.sStep = 0;
	else
		local step = L.stalledSteps[st.sStep + 1];

		if step ~= nil and now - st.sSince >= step
		then
			local fields = newTable();

			fields.n1 = math.floor((now - st.sSince) / 1000);
			emit("stalled", fields);
			st.sStep = st.sStep + 1;
		end
	end
end

-- server_slow: the waits counted by the observer below
local function checkServer(now)
	local st = W.st;

	if st.wait1 == nil or now - st.wait1 > L.serverSlowWindowMs
	then
		return;
	end

	if st.slowAt ~= nil and now - st.slowAt < L.serverSlowRepeatMs
	then
		return;
	end

	local fields = newTable();

	fields.n1 = L.serverSlowCount;
	emit("server_slow", fields);
	st.slowAt = now;
	st.wait1 = nil;
	st.wait2 = nil;
	st.wait3 = nil;
end

-- a wait for the server began (Progress.state.waiting from false to true): the last serverSlowCount kept (3 fields)
local function countWait(state)
	local st = W.st;
	local on = state.waiting == true;

	if on == st.waitOn
	then
		return;
	end

	st.waitOn = on;

	if on
	then
		st.wait1 = st.wait2;
		st.wait2 = st.wait3;
		st.wait3 = getTimestampMs();
	end
end

function AutoPilotMoon.Watch.onProgress(event, state)
	if W.armed and event == "activity"
	then
		pcall(countWait, state);
	end
end

-- the empty soil sacks (the game's own predicate, 20_AP_Item.lua), made once
local function isEmptySack(item)
	return AutoPilotMoon.Item:isEmptySoilSack(item);
end

local function fillRatio(item)
	return item:getFluidContainer():getFilledRatio();
end

-- sacks_low (Soil bagger), water_low (Farmer), seeds_low (sowing): see limits; the job that uses them only
local function checkSupplies(job, player, now)
	local st = W.st;
	local A = AutoPilotMoon.Automation;
	local name = job and job.name;

	if name == "soilBagger" and not st.sacksSent
	then
		-- with a container to take empty sacks back from, running low is not a problem
		if A.baggerState and A.baggerState.refillable
		then
			return;
		end

		local list = player:getInventory():getAllEvalRecurse(isEmptySack);
		local n = list:size();

		if n >= 1 and n <= L.sacksLeft
		then
			local fields = newTable();

			fields.a1 = list:get(0):getDisplayName();
			fields.n1 = n;
			emit("sacks_low", fields);
			st.sacksSent = true;
		end
	elseif name == "farmer" and not st.waterSent
	then
		-- with a water source chosen, the can is filled again
		if A.farmerSource ~= nil
		then
			return;
		end

		local item = AutoPilotMoon.Item:getWateringItem(player);

		if item == nil
		then
			return;
		end

		local uses = AutoPilotMoon.Item:getWaterUses(item);
		local ok, ratio = pcall(fillRatio, item);

		if uses > st.waterMax
		then
			st.waterMax = uses;
		end

		if not ok or type(ratio) ~= "number"
		then
			ratio = st.waterMax > 0 and uses / st.waterMax or 1;
		end

		if uses >= 1 and ratio <= L.waterRatio
		then
			local fields = newTable();

			fields.a1 = item:getDisplayName();
			fields.n1 = uses;
			fields.n2 = round(ratio * 100);
			emit("water_low", fields);
			st.waterSent = true;
		end
	elseif name == "farmSow" and not st.seedsSent
	then
		local ctx = A.stencilCtx;
		local seedName = ctx and ctx.params and ctx.params.seedName;

		if seedName == nil
		then
			return;
		end

		local inventory = player:getInventory();
		local n = inventory:getCountTypeRecurse(seedName);

		if n >= 1 and n <= L.seedsLeft
		then
			local seed = inventory:getFirstTypeRecurse(seedName);
			local fields = newTable();

			fields.a1 = seed and seed:getDisplayName() or seedName;
			fields.n1 = n;
			emit("seeds_low", fields);
			st.seedsSent = true;
		end
	end
end

-- materials_low: one item the macro's action used (see limits)
local function considerItem(item, inventory)
	local st = W.st;

	if item == nil
	then
		return;
	end

	local fullType = item:getFullType();

	if fullType == nil or st.matSent[fullType]
	then
		return;
	end

	local left = inventory:getCountTypeRecurse(fullType);
	local before = st.matCount[fullType];

	-- the first time: the item was used up when it is no longer in a container (a tool kept is not a material)
	if before == nil and item:getContainer() == nil
	then
		before = left + 1;
	end

	st.matCount[fullType] = left;

	if before ~= nil and left < before and left >= 1 and left <= L.materialsLeft
	then
		local fields = newTable();

		fields.a1 = item:getDisplayName();
		fields.n1 = left;
		emit("materials_low", fields);
		st.matSent[fullType] = true;
	end
end

local function checkMaterials(pending, player)
	local inventory = player:getInventory();

	considerItem(pending.item, inventory);

	local action = pending.action;
	local items = action and action.items;

	if items ~= nil and items.size ~= nil
	then
		local n = items:size();

		if n > 8
		then
			n = 8;
		end

		for i = 0, n - 1
		do
			considerItem(items:get(i), inventory);
		end
	end
end

-- ============================================================================================================
-- The interface the centralino calls
-- ============================================================================================================

function AutoPilotMoon.Watch:reset()
	resetState();
	W.armed = false;
end

-- the options that leave everything of this run out: "Avvisi per: solo le macro" with a job that is not a macro
local function leftOut(run)
	return AutoPilotMoon.Options:get("notifyJobs") == "macros" and (run == nil or run.jobKind ~= "macro");
end

function AutoPilotMoon.Watch:tick(job, player, now)
	local notify = Notify();
	local run = notify and notify.run;

	if player == nil or run == nil or leftOut(run)
	then
		return;
	end

	now = now or getTimestampMs();
	W.armed = true;
	W.st.player = player;

	-- a dead character: the engine stops the run with "dead"
	if player:isDead()
	then
		return;
	end

	guard("body", checkBody, player, now);

	if AutoPilotMoon.Options:get("notifyEarly") ~= true
	then
		return;
	end

	guard("zombies", checkZombies, player, now, false);
	guard("attacked", checkAttacked, player, now);
	guard("moodles", checkMoodles, player, now, false);
	guard("tool", checkTool, player, now);
	guard("load", checkLoad, player, now);
	guard("light", checkLight, job, player, now);
	guard("progress", checkProgress, player, now);
	guard("server", checkServer, now);

	if now - W.st.suppliesAt >= L.suppliesEveryMs
	then
		W.st.suppliesAt = now;
		guard("supplies", checkSupplies, job, player, now);
	end
end

-- the watch after a stop (decision D5): the dangers only, while the character stands where it stopped
function AutoPilotMoon.Watch:after(player, now)
	local notify = Notify();
	local after = notify and notify.after;

	if player == nil or after == nil or leftOut(after.run)
	then
		return;
	end

	now = now or getTimestampMs();
	W.st.player = player;

	-- died while standing there: told by the centralino (once: OnPlayerDeath, if it comes first, ends the watch)
	if player:isDead()
	then
		notify:onPlayerDeath(player);

		return;
	end

	guard("body", checkBody, player, now);

	if AutoPilotMoon.Options:get("notifyEarly") ~= true
	then
		return;
	end

	guard("zombies", checkZombies, player, now, true);
	guard("attacked", checkAttacked, player, now);
	guard("moodles", checkMoodles, player, now, true);
end

-- a macro's action confirmed (WP1c, MacroRun.lua actionDone, through Notify:onMacroAction): materials_low
function AutoPilotMoon.Watch:onMacroAction(run, pending, player)
	if pending == nil or player == nil or pending.kind == "walk" or pending.module == "items"
	then
		return;
	end

	if AutoPilotMoon.Options:get("notifyEarly") ~= true
	then
		return;
	end

	guard("materials", checkMaterials, pending, player);
end

-- the waits for the server, counted only after a run's first tick (server_slow): Watch.onProgress is called by the
-- centralino's observer of Progress (only while the master switch is on), never subscribed here
