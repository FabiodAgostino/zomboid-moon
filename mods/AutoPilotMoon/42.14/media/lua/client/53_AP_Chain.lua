-- AutoPilot (Moon): automations for the Moon server.

-- Chains of jobs (11/11/2026; jb-workorders-ricerca/ANALISI-WorkOrders.md 7.2, spec UX-AUTOPILOT.md 2.2, 4.2, 5):
-- "chop and saw" as phases, each phase an ordinary job of the engine (its filter, its limits, its watchdog).
-- - The area is kept as coordinates (AutoPilotMoon.Area) and looked at again at the start of every phase, with the
--   phase's margin (logs fall a square or two outside the area).
-- - The next phase starts only when the previous one ended by itself (its queue ran out, or Automation:finishDone):
--   any other end (moving, cancelling, zombies, death, vehicle, sleep, unwell, a switch turned off, a finishEarly or a
--   stopBecause of the automation) stops the whole chain, so it never starts again behind the player's back.
-- - A phase with nothing to do is skipped with a note; the chain is offered only when every phase is allowed by the
--   server, and stops if one gets switched off before its turn.
-- - Between two phases (1.2.1, "wait for the object"): the next phase starts once the items lying in the area (with
--   the next phase's margin) did not change for Chain.settleMs, at most Wait.timeoutMs with the character idle: the logs
--   of the last tree fall on the server after the tree, the next phase must see them (1.2.0 looked one frame later).
-- - At most Chain.maxPhases phases; a chain runs once.
-- - Messages: "<Chain>: phase 2 of 3, <phase>" at each phase, one summary at the end (the confirmed counters of all the
--   phases), "<Chain> stopped (phase 2): <reason>" on a stop.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Chain = AutoPilotMoon.Chain or {};

local Chain = AutoPilotMoon.Chain;

Chain.maxPhases = 4;
Chain.settleMs = 1000;      -- the items lying in the area unchanged this long before the next phase starts
Chain.definitions = Chain.definitions or {};
Chain.registered = Chain.registered or {};
Chain.current = nil;

-- Defines a chain, at load time (before client/UI/ModOptions.lua, so it gets its tick in "Jobs in the menu").
--   name: "woodChain"; definition:
--     titleKey   (default IGUI_AutoPilot_O_Context_<Name>)
--     phases     list of 2..maxPhases { job = automation name, labelKey = text key of the phase ("Sega i tronchi"),
--                margin = extra squares around the area for this phase (default 0), params = anything the phase's
--                start gets in ctx.params }
-- Returns the definition, or nil (and nothing registered) when the phases are not 2..maxPhases.
function AutoPilotMoon.Chain:define(name, definition)
	local phases = definition and definition.phases;

	if Chain.definitions[name] or phases == nil or #phases < 2 or #phases > Chain.maxPhases
	then
		return nil;
	end

	definition.name = name;
	definition.titleKey = definition.titleKey or ("IGUI_AutoPilot_O_Context_" .. AutoPilotMoon:ucFirst(name));
	definition.option = AutoPilotMoon.Options:addMenuJob(name, definition.titleKey);

	Chain.definitions[name] = definition;
	table.insert(Chain.registered, definition);

	return definition;
end

-- every phase is a registered automation the server allows now
function AutoPilotMoon.Chain:isAllowedByServer(name)
	local definition = Chain.definitions[name];

	if definition == nil
	then
		return false;
	end

	for i, phase in ipairs(definition.phases)
	do
		if not AutoPilotMoon.Automation:isAllowedByServer(phase.job)
		then
			return false;
		end
	end

	return true;
end

-- allowed by the server and shown in the player's menu
function AutoPilotMoon.Chain:isEnabled(name)
	local definition = Chain.definitions[name];

	return definition ~= nil and Chain:isAllowedByServer(name) and AutoPilotMoon.Options:get(definition.option) == true;
end

function AutoPilotMoon.Chain:getTitle(run)
	return getText(run.definition.titleKey);
end

-- starting

local function startPhaseJob(run, phase, squares)
	local automation = AutoPilotMoon.Automation;
	local definition = automation.definitions[phase.job];
	local ctx = {
		chain = run,
		phase = run.phase,
		params = phase.params,
		area = run.area,
		destination = run.ctx.destination,
		run = run.ctx,
	};

	if definition == nil
	then
		automation.lastStartRefusal = "notallowed";

		return false;
	end

	local start = definition.start or automation["start" .. definition.uc];

	if start == nil
	then
		automation.lastStartRefusal = "aborted";

		return false;
	end

	automation.lastStartRefusal = nil;
	automation.startingChain = run;

	local started = start(run.player, squares, nil, ctx);

	automation.startingChain = nil;

	if started and automation.job and automation.job.chainRun == run
	then
		return true;
	end

	if automation.lastStartRefusal == nil
	then
		automation.lastStartRefusal = "aborted";
	end

	return false;
end

-- the chain ended by itself: one summary
local function finishRun(run)
	local title = Chain:getTitle(run);
	local short = AutoPilotMoon.Progress:getShortSummaryText();

	Chain.current = nil;
	AutoPilotMoon.UI:playSound("UISelectListItem");

	-- short over the head, the whole summary in the panel (spec 4.2)
	if short
	then
		AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_JobFinishedSummary", title, short), run.player);
	else
		AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_JobFinished", title), run.player);
	end

	AutoPilotMoon.Progress:finish("done", nil, run.player);
	setGameSpeed(1);
end

-- starts the next phases until one runs, skipping the ones with nothing to do; the chain ends after the last
function AutoPilotMoon.Chain:advance(run)
	run.pendingNext = false;

	local phases = run.definition.phases;
	local title = Chain:getTitle(run);

	while run.phase < #phases
	do
		run.phase = run.phase + 1;

		local phase = phases[run.phase];

		if not AutoPilotMoon.Automation:isAllowedByServer(phase.job)
		then
			Chain:stopRun(run, "notallowed");

			return false;
		end

		local squares = AutoPilotMoon.Area:squares(run.area, phase.margin);
		local mark = #AutoPilotMoon.messageQueue;

		if startPhaseJob(run, phase, squares)
		then
			-- the phase's line goes before what the job said at its start (left out, limited...)
			AutoPilotMoon:messageAt(mark + 1, getText("IGUI_AutoPilot_A_Phase", title, run.phase, #phases, getText(phase.labelKey)), run.player, "info");

			return true;
		end

		local refusal = AutoPilotMoon.Automation.lastStartRefusal;

		if refusal ~= "nothing"
		then
			Chain:stopRun(run, refusal);

			return false;
		end

		AutoPilotMoon:say("info", getText("IGUI_AutoPilot_A_PhaseSkipped", title, run.phase), run.player);
		AutoPilotMoon.Progress:endPhase(run.phase, "skipped");
	end

	finishRun(run);

	return false;
end

-- Starts a chain for the player on an area ({ x1, y1, x2, y2, z }, AutoPilotMoon.Area:rect). ctx (optional): what the
-- phases need, given to each phase's start as ctx.run (ctx.destination also as ctx.destination). Refused with a
-- message (returns false) when a job or chain runs, a phase is not allowed by the server or the player cannot work.
-- Returns true when the chain is running (its first phase with something to do has started).
function AutoPilotMoon.Chain:start(name, player, area, ctx)
	local definition = Chain.definitions[name];

	if definition == nil or player == nil or area == nil
	then
		return false;
	end

	local title = getText(definition.titleKey);
	local reason = nil;

	if AutoPilotMoon.Automation:isBusy()
	then
		reason = "otherjob";
	elseif not Chain:isAllowedByServer(name)
	then
		reason = "notallowed";
	else
		reason = AutoPilotMoon.Automation:getGuardReason(player);
	end

	if reason
	then
		local text = AutoPilotMoon.Automation:getReasonText(reason);

		if text
		then
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", title, text), player);
		end

		return false;
	end

	local run = {
		name = name,
		definition = definition,
		player = player,
		area = { x1 = area.x1, y1 = area.y1, x2 = area.x2, y2 = area.y2, z = area.z },
		ctx = ctx or {},
		phase = 0,
		pendingNext = false,
	};

	Chain.current = run;
	AutoPilotMoon.Progress:beginChain(name, definition.titleKey, definition.phases);

	Chain:advance(run);

	return Chain.current == run;
end

-- the engine: a job that is a phase of the chain ended
function AutoPilotMoon.Chain:onJobEnded(job, reason, stopText)
	local run = job.chainRun;

	if run == nil or Chain.current ~= run
	then
		return;
	end

	if reason == "done"
	then
		AutoPilotMoon.Progress:endPhase(run.phase, "done");

		-- the next phase starts at the next frame of the player, outside the engine's own call
		run.pendingNext = true;

		return;
	end

	Chain:stopRun(run, reason, stopText);
end

-- Stops the chain (and says why): reason as in Automation:stopAll; "aborted" means the automation already said why.
function AutoPilotMoon.Chain:stopRun(run, reason, stopText)
	if run == nil or Chain.current ~= run
	then
		return;
	end

	Chain.current = nil;

	local automation = AutoPilotMoon.Automation;

	if automation.job and automation.job.chainRun == run
	then
		-- the phase's job first (its own stop gives the end back here, ignored: the chain is no longer current)
		automation:stopAll(reason);
	end

	local title = Chain:getTitle(run);
	local reasonText = stopText or automation:getReasonText(reason);

	if reason == "user"
	then
		AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_JobStopped", title), run.player);
	elseif reason ~= "aborted" and reasonText
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_ChainStoppedBecause", title, run.phase, reasonText), run.player);
	end

	AutoPilotMoon.Progress:finish(reason, reasonText, run.player);
	setGameSpeed(1);
end

-- the items lying in the area of the next phase (its margin included)
function AutoPilotMoon.Chain:groundCount(run)
	local phase = run.definition.phases[run.phase + 1];
	local margin = phase and phase.margin or 0;
	local area = run.area;
	local cell = getCell();
	local count = 0;

	for x = area.x1 - margin, area.x2 + margin
	do
		for y = area.y1 - margin, area.y2 + margin
		do
			local square = cell and cell:getGridSquare(x, y, area.z);
			local objects = square and square:getWorldObjects();

			if objects
			then
				count = count + objects:size();
			end
		end
	end

	return count;
end

-- the wait between two phases: the items of the area unchanged for Chain.settleMs (the engine's wait gives the limit)
local function settleWait(run, player)
	local wait = AutoPilotMoon.Wait:new(player, {});
	local state = { count = Chain:groundCount(run), since = getTimestampMs() };

	wait:expectTrue(function()
		local count = Chain:groundCount(run);
		local time = getTimestampMs();

		if count ~= state.count
		then
			state.count = count;
			state.since = time;
		end

		return time - state.since >= Chain.settleMs;
	end);

	return wait;
end

-- Every frame of the chain's player while it waits between two phases (client/99_AP_Event.lua): the stops of the
-- engine apply here too, then the next phase starts (once the area settled).
function AutoPilotMoon.Chain:update(player)
	local run = Chain.current;

	if run == nil or run.player ~= player or not run.pendingNext or AutoPilotMoon.Automation.job ~= nil
	then
		return;
	end

	local reason = AutoPilotMoon.Automation:getGuardReason(player);

	if reason == nil and (player:pressedMovement(false) or player:pressedCancelAction())
	then
		reason = "user";
	end

	if reason
	then
		run.settle = nil;
		Chain:stopRun(run, reason);

		return;
	end

	run.settle = run.settle or settleWait(run, player);

	if run.settle:check() == "busy"
	then
		return;
	end

	run.settle = nil;
	Chain:advance(run);
end
