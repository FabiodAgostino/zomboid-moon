-- AutoPilot (Moon): automations for the Moon server.

-- The progress of the running job or chain, for the AutoPilot panel and the messages (spec UX-AUTOPILOT.md 2.3, 4.1):
-- one state table, written by the engine, the chains, the rest and the automations, read by whoever subscribes.
-- Cheap: no table is created while a job runs (counters and warnings are kept in tables reused from job to job), an
-- observer is called only when something changes, and state.revision tells a reader (the panel, at most 4 times a
-- second) whether it must redo its texts. Only confirmed results are counted (spec 7.4.1): the automations call
-- Progress:count when the tree is down, the item is in the container.
--
-- AutoPilotMoon.Progress.state (read-only for the readers):
--   running          a job or a chain is running
--   kind             "job" or "chain"
--   name, titleKey   the job's (or the chain's) name and title key
--   jobName          the automation running now (in a chain: the current phase's)
--   startedAt        getTimestampMs() at the start
--   phase, phaseCount, nextPhase   chains: the current phase (1-based), how many, the next one (nil at the last)
--   phases[i]        chains: { job, labelKey, status = "next" / "running" / "done" / "skipped", done = n }
--   cappedFrom       a single job cut at the server's limit: how many squares there were (nil: not cut)
--   done, skipped, total, unitKey   squares of the current job or phase (total estimated at its start, can grow);
--                    with ownUnits the automation counts its own units instead (logs, items: Progress:setUnits)
--   ownUnits         done and total are the automation's units, not squares (the engine's square count is ignored)
--   counters[key], counterOrder   confirmed results by text key ("IGUI_AutoPilot_P_C_Trees"), whole job or chain
--   warnings[key], warningOrder   things left out by reason key ("IGUI_AutoPilot_A_Skip_Unreachable")
--   activityKey, activityArg1, activityArg2   what the character is doing now (text key and its arguments)
--   resting, restFrom, restTo     auto-rest: on, endurance % when it sat down and the target %
--   waiting          an action ended and its result has not arrived yet ("waiting for the server...")
--   lastStop         { reason, reasonText, phase }: how the last job or chain ended (reason "done" = by itself)
--   summary          the last job or chain at its end: { titleKey, titleText, doneText, kind, reason, reasonText, phase, phaseCount, done,
--                    skipped, counters, counterOrder, warnings, warningOrder, endedAt, startedAt }
--   titleText, loopText, doneText, icon   a job that words itself (the macros, MACRO-AUTOPILOT.md 5.6): the title
--                    already translated (wins over titleKey), the panel's second line ("Giro 7 - finche' puoi"), a text
--                    added to the confirmed counters (the experience gained), the icon texture; nil for the others
--   revision         grows at every change
--
-- Events given to the observers, fn(event, state): "start", "phase", "step", "count", "warning", "activity", "rest",
-- "stop".

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Progress = AutoPilotMoon.Progress or {};

local P = AutoPilotMoon.Progress;

P.observers = P.observers or {};

P.state = P.state or {
	running = false,
	kind = nil,
	name = nil,
	titleKey = nil,
	jobName = nil,
	startedAt = 0,
	phase = 0,
	phaseCount = 0,
	nextPhase = nil,
	phases = {},
	done = 0,
	skipped = 0,
	total = 0,
	unitKey = nil,
	counters = {},
	counterOrder = {},
	warnings = {},
	warningOrder = {},
	activityKey = nil,
	activityArg1 = nil,
	activityArg2 = nil,
	resting = false,
	restFrom = 0,
	restTo = 0,
	waiting = false,
	lastStop = nil,
	summary = nil,
	revision = 0,
};

-- observers

function AutoPilotMoon.Progress:subscribe(fn)
	for i, observer in ipairs(P.observers)
	do
		if observer == fn
		then
			return;
		end
	end

	table.insert(P.observers, fn);
end

function AutoPilotMoon.Progress:unsubscribe(fn)
	for i = #P.observers, 1, -1
	do
		if P.observers[i] == fn
		then
			table.remove(P.observers, i);
		end
	end
end

function AutoPilotMoon.Progress:getState()
	return P.state;
end

local function notify(event)
	local state = P.state;

	state.revision = state.revision + 1;

	for i = 1, #P.observers
	do
		P.observers[i](event, state);
	end
end

-- empties a keyed table through the list of its keys (the keys are always in the list), then the list
local function wipeKeyed(t, order)
	for i = #order, 1, -1
	do
		t[order[i]] = nil;
		order[i] = nil;
	end
end

local function wipeList(t)
	for i = #t, 1, -1
	do
		t[i] = nil;
	end
end

local function resetRun(kind, name, titleKey)
	local state = P.state;

	state.running = true;
	state.kind = kind;
	state.name = name;
	state.titleKey = titleKey;
	state.jobName = nil;
	state.startedAt = getTimestampMs();
	state.phase = 0;
	state.phaseCount = 0;
	state.nextPhase = nil;
	wipeList(state.phases);
	state.done = 0;
	state.skipped = 0;
	state.total = 0;
	state.unitKey = nil;
	state.ownUnits = false;
	state.cappedFrom = nil;
	wipeKeyed(state.counters, state.counterOrder);
	wipeKeyed(state.warnings, state.warningOrder);
	state.activityKey = nil;
	state.activityArg1 = nil;
	state.activityArg2 = nil;
	state.resting = false;
	state.waiting = false;
	state.titleText = nil;
	state.loopText = nil;
	state.doneText = nil;
	state.icon = nil;
end

-- the engine and the chains

-- a single job starts (not a phase of a chain); cappedFrom: the squares there were before the server's limit cut them
function AutoPilotMoon.Progress:beginJob(name, titleKey, total, unitKey, cappedFrom)
	resetRun("job", name, titleKey);

	local state = P.state;

	state.jobName = name;
	state.total = total or 0;
	state.unitKey = unitKey;
	state.cappedFrom = cappedFrom;

	notify("start");
end

-- a chain starts: phases = list of { job, labelKey }
function AutoPilotMoon.Progress:beginChain(name, titleKey, phases)
	resetRun("chain", name, titleKey);

	local state = P.state;

	for i, phase in ipairs(phases)
	do
		table.insert(state.phases, { job = phase.job, labelKey = phase.labelKey, status = "next", done = 0 });
	end

	state.phaseCount = #phases;
	state.nextPhase = 1;

	notify("start");
end

-- a phase of the running chain starts (its job has been accepted by the engine)
function AutoPilotMoon.Progress:beginPhase(index, jobName, total, unitKey)
	local state = P.state;
	local phase = state.phases[index];

	state.phase = index;
	state.jobName = jobName;
	state.done = 0;
	state.skipped = 0;
	state.total = total or 0;
	state.unitKey = unitKey;
	state.ownUnits = false;
	state.activityKey = nil;
	state.waiting = false;

	if phase
	then
		phase.status = "running";
	end

	if index < state.phaseCount
	then
		state.nextPhase = index + 1;
	else
		state.nextPhase = nil;
	end

	notify("phase");
end

-- the phase ended: by itself ("done") or with nothing to do ("skipped")
function AutoPilotMoon.Progress:endPhase(index, status)
	local state = P.state;
	local phase = state.phases[index];

	if phase
	then
		phase.status = status;

		if status == "done"
		then
			phase.done = state.done;
		end
	end

	if index >= state.phaseCount
	then
		state.nextPhase = nil;
	else
		state.nextPhase = index + 1;
	end

	notify("phase");
end

-- the total of the current job or phase (squares at the start; an automation can give a better estimate)
function AutoPilotMoon.Progress:setTotal(total, unitKey)
	local state = P.state;

	if state.total == total and (unitKey == nil or state.unitKey == unitKey)
	then
		return;
	end

	state.total = total;

	if unitKey
	then
		state.unitKey = unitKey;
	end

	notify("step");
end

-- An automation that counts its own units (logs sawn, items carried) instead of squares: the total of its units and
-- their text key; from now on only Progress:addUnitsDone moves "done" (the engine's squares no longer do).
function AutoPilotMoon.Progress:setUnits(total, unitKey)
	P.state.ownUnits = true;
	P.state.done = 0;
	P.state.total = -1;
	AutoPilotMoon.Progress:setTotal(total, unitKey);
end

function AutoPilotMoon.Progress:addUnitsDone(amount)
	local state = P.state;

	if not state.ownUnits
	then
		return;
	end

	state.done = state.done + (amount or 1);

	if state.done > state.total
	then
		state.total = state.done;
	end

	notify("step");
end

-- a square done or skipped (the engine); ignored when the automation counts its own units
function AutoPilotMoon.Progress:addDone(amount)
	local state = P.state;

	if state.ownUnits
	then
		return;
	end

	state.done = state.done + (amount or 1);

	if state.done > state.total
	then
		state.total = state.done;
	end

	notify("step");
end

function AutoPilotMoon.Progress:addSkipped(amount)
	local state = P.state;

	state.skipped = state.skipped + (amount or 1);

	notify("step");
end

-- automations: a confirmed result ("IGUI_AutoPilot_P_C_Trees", 1)
function AutoPilotMoon.Progress:count(key, amount)
	local state = P.state;

	if not state.running
	then
		return;
	end

	if state.counters[key] == nil
	then
		state.counters[key] = 0;
		table.insert(state.counterOrder, key);
	end

	state.counters[key] = state.counters[key] + (amount or 1);

	notify("count");
end

function AutoPilotMoon.Progress:getCount(key)
	return P.state.counters[key] or 0;
end

-- something left out, grouped by reason ("IGUI_AutoPilot_A_Skip_Unreachable")
function AutoPilotMoon.Progress:warn(key, amount)
	local state = P.state;

	if not state.running
	then
		return;
	end

	if state.warnings[key] == nil
	then
		state.warnings[key] = 0;
		table.insert(state.warningOrder, key);
	end

	state.warnings[key] = state.warnings[key] + (amount or 1);

	notify("warning");
end

-- what the character is doing now (a text key of the panel's "Now:" line and up to two arguments); nothing happens when
-- it is the same as before
function AutoPilotMoon.Progress:setActivity(key, arg1, arg2)
	local state = P.state;

	if state.activityKey == key and state.activityArg1 == arg1 and state.activityArg2 == arg2
	then
		return;
	end

	state.activityKey = key;
	state.activityArg1 = arg1;
	state.activityArg2 = arg2;

	notify("activity");
end

-- a job that words itself (the macros, MACRO-AUTOPILOT.md 5.6): the title already translated ("Macro: Manutenzione"),
-- the second line of the panel, a text after the confirmed counters, the icon; nothing happens when it is the same
local function setField(field, value)
	local state = P.state;

	if state[field] == value
	then
		return;
	end

	state[field] = value;

	notify("activity");
end

function AutoPilotMoon.Progress:setTitleText(text)
	setField("titleText", text);
end

function AutoPilotMoon.Progress:setLoopText(text)
	setField("loopText", text);
end

function AutoPilotMoon.Progress:setDoneText(text)
	setField("doneText", text);
end

function AutoPilotMoon.Progress:setIcon(texture)
	setField("icon", texture);
end

-- an action ended and its result has not arrived yet
function AutoPilotMoon.Progress:setWaiting(waiting)
	local state = P.state;

	if state.waiting == (waiting == true)
	then
		return;
	end

	state.waiting = waiting == true;

	notify("activity");
end

-- auto-rest: on, with the endurance % it started from and the target %; or off
function AutoPilotMoon.Progress:setResting(resting, from, to)
	local state = P.state;

	from = from or 0;
	to = to or 0;

	if state.resting == (resting == true) and state.restFrom == from and state.restTo == to
	then
		return;
	end

	state.resting = resting == true;
	state.restFrom = from;
	state.restTo = to;

	notify("rest");
end

-- Warnings told once more at the end of the job, over the head (12/11/2026, user's decision on the fertilizer): a
-- warning key -> the key of a sentence with the count ("Saltate 3 piante gia' fertilizzate: ..."). Said after the end
-- message by Progress:finish, at any end (finished or stopped), with the level "plain" (shown with the panel open too;
-- never with the messages off). Registered by the automations at load time.
P.endWarnings = P.endWarnings or {};

function AutoPilotMoon.Progress:addEndWarning(warningKey, sentenceKey)
	P.endWarnings[warningKey] = sentenceKey;
end

-- the sentences of the end warnings of a summary (or of the running state), in the order the warnings came
function AutoPilotMoon.Progress:getEndWarningTexts(summary)
	local source = summary or P.state;
	local texts = {};

	for i, key in ipairs(source.warningOrder)
	do
		local sentenceKey = P.endWarnings[key];

		if sentenceKey and (source.warnings[key] or 0) > 0
		then
			table.insert(texts, getText(sentenceKey, source.warnings[key]));
		end
	end

	return texts;
end

-- the job or the chain ended; reason "done" when it finished by itself. Keeps the summary for the panel at rest.
-- player (optional): who hears the end warnings (P.endWarnings)
function AutoPilotMoon.Progress:finish(reason, reasonText, player)
	local state = P.state;

	if not state.running
	then
		return;
	end

	local counters = {};
	local counterOrder = {};
	local warnings = {};
	local warningOrder = {};

	for i, key in ipairs(state.counterOrder)
	do
		counters[key] = state.counters[key];
		counterOrder[i] = key;
	end

	for i, key in ipairs(state.warningOrder)
	do
		warnings[key] = state.warnings[key];
		warningOrder[i] = key;
	end

	state.summary = {
		titleKey = state.titleKey,
		titleText = state.titleText,
		doneText = state.doneText,
		kind = state.kind,
		name = state.name,
		reason = reason,
		reasonText = reasonText,
		phase = state.phase,
		phaseCount = state.phaseCount,
		done = state.done,
		skipped = state.skipped,
		counters = counters,
		counterOrder = counterOrder,
		warnings = warnings,
		warningOrder = warningOrder,
		startedAt = state.startedAt,
		endedAt = getTimestampMs(),
	};

	for i, text in ipairs(AutoPilotMoon.Progress:getEndWarningTexts(state.summary))
	do
		AutoPilotMoon:say("plain", text, player);
	end

	state.lastStop = { reason = reason, reasonText = reasonText, phase = state.phase };
	state.running = false;
	state.resting = false;
	state.waiting = false;
	state.activityKey = nil;
	state.activityArg1 = nil;
	state.activityArg2 = nil;

	notify("stop");
end

-- the main confirmed result, for the short end over the head ("Assi portate: 36"): the last counter that started (in a
-- chain, the last phase's), nil when nothing was counted
function AutoPilotMoon.Progress:getShortSummaryText(summary)
	local source = summary or P.state;
	local key = source.counterOrder[#source.counterOrder];

	if key == nil
	then
		return nil;
	end

	return getText(key, source.counters[key]);
end

-- the confirmed counters as one line, "Trees cut: 18 - Skipped: 2" (the summary when given, else the running state);
-- nil when there is nothing to say
function AutoPilotMoon.Progress:getCountersText(summary)
	local source = summary or P.state;
	local parts = {};

	for i, key in ipairs(source.counterOrder)
	do
		table.insert(parts, getText(key, source.counters[key]));
	end

	if source.skipped and source.skipped > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_P_C_Skipped", source.skipped));
	end

	if #parts == 0
	then
		return nil;
	end

	return table.concat(parts, " - ");
end
