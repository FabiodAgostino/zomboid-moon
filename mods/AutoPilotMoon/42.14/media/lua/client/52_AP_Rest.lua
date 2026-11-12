-- AutoPilot (Moon): automations for the Moon server.

-- The character's condition during a job (11/11/2026, spec UX-AUTOPILOT.md 5, decisions D1 and D3).
--
-- Auto-rest: between two steps (only while the character is idle), when the server allows it (EnableAutoRest) and the
-- player's option "Rest when you are tired" is on, at the endurance moodle level the player chose (option restLevel,
-- 1-4, default 2; until 12/11/2026 it was the server's RestAtFatigueLevel) or when the game says the endurance is no
-- longer enough for an action, the character sits on the ground as with the game's "Sit on ground"
-- (reportEvent("EventSitOnGround")), waits until the endurance is back at 95%, gets up as the game does (variable
-- forceGetUp) and the job resumes. If it cannot sit within 6 seconds it gives up for this job (one message) and the
-- job goes on (an automation that needs endurance then stops with "too tired"). Rest does not count for the watchdog;
-- every stop of the engine still applies while sitting, and a stop gets the character up.
--
-- Unwell (decision D1): when the player's option "Stop when you are unwell" is on (default), the engine refuses to
-- start and stops a job when thirst, hunger, an injury, bleeding or panic reach the levels of Rest.unwellLevels.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Rest = AutoPilotMoon.Rest or {};

local Rest = AutoPilotMoon.Rest;

Rest.sitTimeoutMs = 6000;      -- give up when the character is not sitting after this long
Rest.standTimeoutMs = 4000;    -- longest wait for the character to be up again
Rest.targetEndurance = 0.95;   -- rest until the endurance is back here

-- moodle -> level from which the character is unwell (moodle levels go from 0 to 4; MoodleType of 42.22)
Rest.unwellLevels = {
	{ moodle = "THIRST", level = 3 },     -- parched
	{ moodle = "HUNGRY", level = 3 },     -- very hungry
	{ moodle = "INJURED", level = 3 },    -- severely injured
	{ moodle = "BLEEDING", level = 2 },   -- bleeding a lot (a scratch that bleeds a little does not stop a job)
	{ moodle = "PANIC", level = 3 },      -- strong panic
};

local function moodleLevel(player, name)
	local moodles = player:getMoodles();
	local moodleType = MoodleType[name];

	if moodles == nil or moodleType == nil
	then
		return 0;
	end

	return moodles:getMoodleLevel(moodleType) or 0;
end

local function endurance(player)
	local stats = player:getStats();

	if stats == nil
	then
		return 1;
	end

	return stats:get(CharacterStat.ENDURANCE) or 1;
end

local function percent(value)
	return math.floor(value * 100 + 0.5);
end

-- the character's endurance in percent (the panel's rest bar)
function AutoPilotMoon.Rest:getEndurancePercent(player)
	return percent(endurance(player));
end

-- unwell

-- "unwell" or nil; definition (optional): the job's, whose unwellLevel(player, moodle, level) may change a level
function AutoPilotMoon.Rest:getUnwellReason(player, definition)
	if player == nil or AutoPilotMoon.Options:get("stopWhenUnwell") ~= true
	then
		return nil;
	end

	for i, entry in ipairs(Rest.unwellLevels)
	do
		local level = entry.level;

		if definition and definition.unwellLevel
		then
			level = definition.unwellLevel(player, entry.moodle, level) or level;
		end

		if moodleLevel(player, entry.moodle) >= level
		then
			return "unwell";
		end
	end

	return nil;
end

-- auto-rest

-- the server allows it and the player wants it
function AutoPilotMoon.Rest:isEnabled()
	return AutoPilotMoon.Sandbox:getBoolean("EnableAutoRest") and AutoPilotMoon.Options:get("autoRest") == true;
end

-- the endurance moodle level at which the character sits down: the player's option (1-4)
function AutoPilotMoon.Rest:getLevel()
	local level = tonumber(AutoPilotMoon.Options:get("restLevel")) or 2;

	if level < 1
	then
		return 1;
	elseif level > 4
	then
		return 4;
	end

	return level;
end

function AutoPilotMoon.Rest:needsRest(player)
	if moodleLevel(player, "ENDURANCE") >= Rest:getLevel()
	then
		return true;
	end

	return not player:isEnduranceSufficientForAction();
end

local function title(job)
	if job.chainRun
	then
		return getText(job.chainRun.definition.titleKey);
	end

	return AutoPilotMoon.Automation:getTitle(job.definition);
end

local function endRest(job, player, said)
	local rest = job.rest;

	rest.phase = nil;
	AutoPilotMoon.Progress:setResting(false);
	AutoPilotMoon.Progress:setActivity(nil);

	if said
	then
		AutoPilotMoon:say("info", getText(said, title(job)), player);
	end
end

-- Called by the engine every frame of the job, after the stops: true while the character rests (the engine does
-- nothing else that frame).
function AutoPilotMoon.Rest:update(job, player)
	local rest = job.rest;

	if rest == nil
	then
		return false;
	end

	local now = getTimestampMs();

	if rest.phase == nil
	then
		-- never with a corpse in the arms (the Corpse piler is idle between its walks while dragging): it is
		-- carried to the pile and dropped first
		if rest.gaveUp or not Rest:isEnabled() or ISTimedActionQueue.isPlayerDoingAction(player) or player:isDraggingCorpse()
			or (job.definition and job.definition.autoRest and job.definition.autoRest(job, player) == false)
			or not Rest:needsRest(player)
		then
			return false;
		end

		rest.phase = "sitting";
		rest.since = now;
		rest.from = percent(endurance(player));

		if not player:isSitOnGround()
		then
			player:reportEvent("EventSitOnGround");
		end

		AutoPilotMoon:say("info", getText("IGUI_AutoPilot_A_RestStart", title(job)), player);
		AutoPilotMoon.Progress:setResting(true, rest.from, percent(Rest.targetEndurance));
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Sitting");

		return true;
	end

	if rest.phase == "sitting"
	then
		if player:isSitOnGround()
		then
			rest.phase = "resting";
		elseif now - rest.since > Rest.sitTimeoutMs
		then
			rest.gaveUp = true;
			endRest(job, player, "IGUI_AutoPilot_A_RestCannotSit");

			return false;
		end

		return true;
	end

	if rest.phase == "resting"
	then
		if endurance(player) >= Rest.targetEndurance or not player:isSitOnGround()
		then
			if player:isSitOnGround()
			then
				player:setVariable("forceGetUp", true);
			end

			rest.phase = "standing";
			rest.since = now;
		end

		return true;
	end

	-- standing
	if not player:isSitOnGround() or now - rest.since > Rest.standTimeoutMs
	then
		endRest(job, player, "IGUI_AutoPilot_A_RestEnd");
	end

	return true;
end

-- the job stopped (any reason): a character sitting because of the job gets up (not a dead one)
function AutoPilotMoon.Rest:onJobStop(job, reason)
	local rest = job.rest;
	local player = job.player;

	if rest == nil or rest.phase == nil
	then
		return;
	end

	rest.phase = nil;
	AutoPilotMoon.Progress:setResting(false);

	if player and not player:isDead() and player:isSitOnGround()
	then
		player:setVariable("forceGetUp", true);
	end
end
