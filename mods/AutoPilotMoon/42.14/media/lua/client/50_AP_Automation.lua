-- AutoPilot (Moon): automations for the Moon server.

-- The automation engine: one job at a time, for one local player, one square at a time and only while the player is
-- idle. Every automation registers itself (Automation:register) and gets for free: the server and player switches
-- read live, the guards (dead, vehicle, asleep, no square, zombies, the player moving or cancelling), the watchdog,
-- the choice of the next square, the highlight and the clean stop. See "Engine API" in tests/README.md.
-- Since 11/11/2026 also: the progress model (client/48_AP_Progress.lua), the auto-rest between two steps and the stop
-- when the character is unwell (client/52_AP_Rest.lua), the chains (client/53_AP_Chain.lua: a job that is a phase of a
-- chain hands its end to the chain).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Automation = AutoPilotMoon.Automation or {};

-- engine settings

AutoPilotMoon.Automation.watchdogIdleMs = 15000;      -- idle time on the same square before it is discarded
AutoPilotMoon.Automation.maxFrameMs = 250;            -- longest frame counted by the watchdog (pauses, alt-tab)
AutoPilotMoon.Automation.maxConsecutiveWaits = 5;     -- "wait" answers in a row on the same square before discarding it
AutoPilotMoon.Automation.maxRequeues = 2;             -- times a square without a free tile next to it goes back
AutoPilotMoon.Automation.maxHighlighted = 25;         -- squares highlighted per frame

-- per-job state of the automations, reset at every start and stop (an automation can add its own fields)
AutoPilotMoon.Automation.jobStateFields = {
	"squareQueueStartSquare",
	"lastRelocateSquare",
};

-- registration and permissions

-- Every automation registers itself here (one line in its file: AutoPilotMoon.Automation:register("gardener")).
-- From the name come: the lock Automation.<name>Working, the player's switch Options "enable<Name>", the server
-- switch SandboxVars.AutoPilotMoon.Enable<Name>, the functions check<Name>Queue, stop<Name> and the title
-- IGUI_AutoPilot_O_Context_<Name>. Its menu entries are data (client/75_AP_JobMenu.lua, JobMenu:define).
-- options (all optional):
--   start(player, squares, startSquare, ctx) -> started: how a chain starts this job as one of its phases (default:
--     Automation.start<Name>(player, squares, startSquare, ctx));
--   squareFilter(square, player) -> true when the job has something to do there: the area tool counts with it, so the
--     number shown before the start is the one the job will do;
--   unitKey: what the job counts in the area tool and the panel ("IGUI_AutoPilot_S_Unit_Trees");
--   limit() -> the server's limit shown with the count (default: MaxSquaresPerJob);
--   parent: the name of an automation registered before (phase C, 11/11/2026): this one is one of its jobs and shares
--     its server switch, its tick in "Jobs in the menu" and its title (the Farmer's new jobs under EnableFarmer, spec
--     2.5); it gets no tick of its own;
--   titleKey: the title, when it is not IGUI_AutoPilot_O_Context_<Name> (or the parent's);
--   announceStart(job), announceStop(job, reason, stopText) -> true: a job that says its own start and end over the
--     head (the macros, feminine in Italian and with the line of the macro: MACRO-AUTOPILOT.md 5.5); the engine then
--     says nothing of its own;
--   unwellLevel(player, moodle, level) -> level: the "unwell" level of a moodle for this job (the macros: a moodle a
--     "when" block looks after stops only when severe, MACRO-AUTOPILOT.md 11.4); autoRest(job, player) -> false: no
--     auto-rest for this job (a macro that rests by itself).
function AutoPilotMoon.Automation:register(name, options)
	if AutoPilotMoon.Automation.definitions[name]
	then
		return AutoPilotMoon.Automation.definitions[name];
	end

	options = options or {};

	local uc = AutoPilotMoon:ucFirst(name);
	local parent = options.parent and AutoPilotMoon.Automation.definitions[options.parent] or nil;
	local definition = {
		name = name,
		uc = uc,
		lockVar = name .. "Working",
		option = "enable" .. uc,
		sandboxKey = "Enable" .. uc,
		titleKey = options.titleKey or ("IGUI_AutoPilot_O_Context_" .. uc),
		start = options.start,
		squareFilter = options.squareFilter,
		unitKey = options.unitKey or "IGUI_AutoPilot_S_Unit_Squares",
		limit = options.limit,
		announceStart = options.announceStart,
		announceStop = options.announceStop,
		unwellLevel = options.unwellLevel,
		autoRest = options.autoRest,
	};

	if parent
	then
		definition.parent = parent.name;
		definition.option = parent.option;
		definition.sandboxKey = parent.sandboxKey;
		definition.titleKey = options.titleKey or parent.titleKey;
	end

	AutoPilotMoon.Automation.definitions[name] = definition;
	AutoPilotMoon.Automation.byLockVar[definition.lockVar] = definition;
	table.insert(AutoPilotMoon.Automation.registered, definition);
	AutoPilotMoon.Automation[definition.lockVar] = false;

	if parent == nil
	then
		AutoPilotMoon.Options:addMenuJob(name, definition.titleKey);
	end

	return definition;
end

-- an automation's own per-job field, reset with the others at start and stop
function AutoPilotMoon.Automation:addJobStateField(field)
	table.insert(AutoPilotMoon.Automation.jobStateFields, field);
end

-- the server allows it (sandbox, read now)
function AutoPilotMoon.Automation:isAllowedByServer(name)
	local definition = AutoPilotMoon.Automation.definitions[name];

	return definition ~= nil and AutoPilotMoon.Sandbox:getBoolean(definition.sandboxKey);
end

-- the server's limit of a job (shown with the count of the area tool)
function AutoPilotMoon.Automation:getLimit(name)
	local definition = AutoPilotMoon.Automation.definitions[name];

	if definition and definition.limit
	then
		return definition.limit();
	end

	return AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob");
end

-- the server allows it and the player shows it in the menu ("Jobs in the menu" in the Options). The engine itself only
-- looks at the server (isAllowedByServer): hiding a job from the menu never stops it.
function AutoPilotMoon.Automation:isEnabled(name)
	local definition = AutoPilotMoon.Automation.definitions[name];

	return definition ~= nil
		and AutoPilotMoon.Sandbox:getBoolean(definition.sandboxKey)
		and AutoPilotMoon.Options:get(definition.option) == true;
end

function AutoPilotMoon.Automation:isAnyAutomationEnabled()
	for i, definition in ipairs(AutoPilotMoon.Automation.registered)
	do
		if AutoPilotMoon.Automation:isEnabled(definition.name)
		then
			return true;
		end
	end

	return false;
end

-- the running job is identified by its lock (Automation.job), never by the options

function AutoPilotMoon.Automation:getRunningJob()
	local job = AutoPilotMoon.Automation.job;

	return job and job.name or nil;
end

function AutoPilotMoon.Automation:isOtherJobRunning(name)
	local job = AutoPilotMoon.Automation.job;

	return job ~= nil and job.name ~= name;
end

-- a job or a chain (also between two phases) is running: one at a time
function AutoPilotMoon.Automation:isBusy()
	return AutoPilotMoon.Automation.job ~= nil or AutoPilotMoon.Chain.current ~= nil;
end

function AutoPilotMoon.Automation:getTitle(definition)
	return getText(definition.titleKey);
end

-- guards

-- why the player cannot work now (nil: it can). Checked at the start and before every step.
function AutoPilotMoon.Automation:getGuardReason(player, definition)
	if player == nil or player:isDead()
	then
		return "dead";
	end

	if player:getVehicle()
	then
		return "vehicle";
	end

	if player:isAsleep()
	then
		return "asleep";
	end

	if player:getSquare() == nil
	then
		return "nosquare";
	end

	local stats = player:getStats();

	if stats and (stats:getNumVeryCloseZombies() > 0 or stats:getNumChasingZombies() > 0)
	then
		return "zombies";
	end

	-- decision D1 (11/11/2026): thirst, hunger, a serious injury or bleeding, strong panic (player's option)
	return AutoPilotMoon.Rest:getUnwellReason(player, definition);
end

local reasonKeys = {
	zombies = "IGUI_AutoPilot_A_Reason_Zombies",
	vehicle = "IGUI_AutoPilot_A_Reason_Vehicle",
	asleep = "IGUI_AutoPilot_A_Reason_Asleep",
	notallowed = "IGUI_AutoPilot_A_Reason_Disabled",
	otherjob = "IGUI_AutoPilot_A_Reason_OtherJob",
	unwell = "IGUI_AutoPilot_A_Reason_Unwell",
	-- the player's master switch turned off in the Options (client/06_AP_Switch.lua)
	switchedoff = "IGUI_AutoPilot_A_Reason_SwitchedOff",
};

AutoPilotMoon.Automation.reasonKeys = reasonKeys;

-- the text of a stop reason of the engine (nil for "done", "user", "aborted" and the ones without a text)
function AutoPilotMoon.Automation:getReasonText(reason)
	if reasonKeys[reason]
	then
		return getText(reasonKeys[reason]);
	end

	return nil;
end

-- timed actions: on a stop the engine clears only what the job queued itself, except for zombies and death

local function snapshotActions(player)
	local snapshot = {};
	local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player];

	if queue and queue.queue
	then
		for i, action in ipairs(queue.queue)
		do
			snapshot[action] = true;
		end
	end

	return snapshot;
end

-- what appeared in the player's queue since the snapshot was queued by the job
local function markOwnedActions(job, player, before)
	local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player];

	if queue and queue.queue
	then
		for i, action in ipairs(queue.queue)
		do
			if not before[action]
			then
				job.owned[action] = true;
			end
		end
	end
end

function AutoPilotMoon.Automation:releaseActions(job, reason)
	local player = job.player;

	if reason == "done" or player == nil
	then
		return;
	end

	if reason == "dead" or reason == "zombies"
	then
		ISTimedActionQueue.clear(player);

		return;
	end

	local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player];

	if queue == nil or queue.queue == nil or #queue.queue == 0
	then
		return;
	end

	for i, action in ipairs(queue.queue)
	do
		if not job.owned[action]
		then
			-- the player queued something by hand: leave the queue alone
			return;
		end
	end

	ISTimedActionQueue.clear(player);
end

-- queue entries: the square plus its coordinates, cached when it enters the queue

local function newEntry(square)
	return {
		square = square,
		x = square:getX(),
		y = square:getY(),
		z = square:getZ(),
		requeues = 0,
	};
end

-- the nearest squares (same floor first), at most limit, without sorting: buckets by whole distance
function AutoPilotMoon.Automation:keepNearest(squares, refX, refY, refZ, limit)
	if #squares <= limit
	then
		return squares;
	end

	local buckets = {};
	local maxKey = 0;

	for i, square in ipairs(squares)
	do
		local dx = square:getX() - refX;
		local dy = square:getY() - refY;
		local dz = square:getZ() - refZ;
		local key = math.floor(math.sqrt(dx * dx + dy * dy));

		if dz ~= 0
		then
			key = key + 1000 * math.abs(dz);
		end

		if buckets[key] == nil
		then
			buckets[key] = {};
		end

		table.insert(buckets[key], square);

		if key > maxKey
		then
			maxKey = key;
		end
	end

	local kept = {};

	for key = 0, maxKey
	do
		local bucket = buckets[key];

		if bucket
		then
			for i, square in ipairs(bucket)
			do
				if #kept >= limit
				then
					return kept;
				end

				table.insert(kept, square);
			end
		end
	end

	return kept;
end

-- index of the next square, one linear scan: the nearest to the player on the same floor, then the other floors;
-- squares sent back (no free tile next to them) come after all the others
local function findNearest(entries, player)
	local px = math.floor(player:getX());
	local py = math.floor(player:getY());
	local pz = math.floor(player:getZ());
	local best = 1;
	local bestKey = nil;

	for i, entry in ipairs(entries)
	do
		local dx = entry.x - px;
		local dy = entry.y - py;
		local key = dx * dx + dy * dy + entry.requeues * 1000000000;

		if entry.z ~= pz
		then
			local dz = entry.z - pz;

			key = key + 100000000 + dz * dz * 1000000;
		end

		if bestKey == nil or key < bestKey
		then
			best = i;
			bestKey = key;
		end
	end

	return best;
end

local function removeEntry(job, index)
	local entries = job.entries;
	local entry = entries[index];

	if job.fifo
	then
		table.remove(entries, index);
	else
		entries[index] = entries[#entries];
		entries[#entries] = nil;
	end

	if job.head == entry
	then
		job.head = nil;
		job.headIndex = nil;
	end
end

-- the square being worked on; a new one is chosen when there is none (squares no longer loaded are skipped)
function AutoPilotMoon.Automation:getHead(job, player)
	if job.head
	then
		return job.head;
	end

	local cell = getCell();

	while #job.entries > 0
	do
		local index = 1;

		if not job.fifo
		then
			index = findNearest(job.entries, player);
		end

		local entry = job.entries[index];
		local square = cell and cell:getGridSquare(entry.x, entry.y, entry.z);

		if square
		then
			entry.square = square;
			job.head = entry;
			job.headIndex = index;

			return entry;
		end

		removeEntry(job, index);
		job.skipped = job.skipped + 1;
	end

	return nil;
end

-- the head is done (true from the automation's check)
function AutoPilotMoon.Automation:consumeHead(job)
	if job.head
	then
		removeEntry(job, job.headIndex);
		AutoPilotMoon.Progress:addDone(1);
	end
end

-- the head cannot be worked: counted in the summary at the end (stuck: also said at once)
function AutoPilotMoon.Automation:discardHead(job, stuck)
	if job.head
	then
		removeEntry(job, job.headIndex);
		job.skipped = job.skipped + 1;
		AutoPilotMoon.Progress:addSkipped(1);

		if stuck
		then
			AutoPilotMoon:message(getText("IGUI_AutoPilot_A_SquareSkipped", AutoPilotMoon.Automation:getTitle(job.definition)), false, job.player);
		end
	end
end

-- no free tile next to the head: back after the others, at most maxRequeues times, then discarded
function AutoPilotMoon.Automation:requeueHead(job)
	local entry = job.head;

	if entry == nil
	then
		return;
	end

	entry.requeues = entry.requeues + 1;

	if entry.requeues > AutoPilotMoon.Automation.maxRequeues
	then
		AutoPilotMoon.Automation:discardHead(job, false);

		return;
	end

	if job.fifo
	then
		table.remove(job.entries, job.headIndex);
		table.insert(job.entries, entry);
	end

	job.head = nil;
	job.headIndex = nil;
end


function AutoPilotMoon.Automation:relocateIfNeeded(square, player)
	player = player or AutoPilotMoon:getPlayer();

	local playerSquare = AutoPilotMoon.Square:getCurrent(player);

	if square == nil or playerSquare == nil
	then
		return false;
	end

	if AutoPilotMoon.Automation.lastRelocateSquare ~= square
	then
		local targetRoom = square:getRoom();

		if square:getZ() ~= playerSquare:getZ() or targetRoom ~= playerSquare:getRoom()
		then
			AutoPilotMoon.Automation.lastRelocateSquare = square;

			local target = nil;

			if targetRoom
			then
				target = targetRoom:getRandomFreeSquare();
			end

			AutoPilotMoon.Square:walkTo(player, target or square);

			return true;
		end
	end

	return false;
end

-- On the ground during the job (spec 4.3, 3.6): the game draws an area highlight for one frame only, so it is drawn
-- again every frame with addAreaHighlightForPlayer, by coordinates (never a square object kept). With "Mostra l'area
-- del lavoro sul terreno": the whole area (one rectangle, when the job came from a radius or a drawn rectangle) and the
-- next Automation.maxHighlighted squares in the informative colour (C_Input), never the red of a problem; always the
-- square being worked now, in the game's "good" colour.
function AutoPilotMoon.Automation:highlight(job)
	local playerNum = job.player:getPlayerNum();
	local info = AutoPilotMoon.UI.inputColor;
	local head = job.head;

	if AutoPilotMoon.Options:get("showJobArea")
	then
		if job.area
		then
			AutoPilotMoon.Area:highlight(playerNum, job.area, info.r, info.g, info.b, 0.12);
		end

		local count = 0;

		for i, entry in ipairs(job.entries)
		do
			if count >= AutoPilotMoon.Automation.maxHighlighted
			then
				break;
			end

			if entry ~= head
			then
				AutoPilotMoon.Area:highlightSquare(playerNum, entry.x, entry.y, entry.z, info.r, info.g, info.b, 0.35);
				count = count + 1;
			end
		end
	end

	if head
	then
		local r, g, b = AutoPilotMoon.UI:goodColor();

		AutoPilotMoon.Area:highlightSquare(playerNum, head.x, head.y, head.z, r, g, b, 0.5);
	end
end

-- start and stop

function AutoPilotMoon.Automation:resetJobState()
	for i, field in ipairs(AutoPilotMoon.Automation.jobStateFields)
	do
		AutoPilotMoon.Automation[field] = nil;
	end

	for i, definition in ipairs(AutoPilotMoon.Automation.registered)
	do
		AutoPilotMoon.Automation[definition.lockVar] = false;
	end

	AutoPilotMoon.Automation.job = nil;
	AutoPilotMoon.Automation.stopReason = nil;
	AutoPilotMoon.Automation.stopText = nil;
end

-- items: list of squares, or a function returning it (called now). settings (optional): player (default: the player
-- whose menu was opened), fifo (work the squares in the given order instead of nearest first).
-- Refused (with a message, returns false) when another job runs, the server does not allow the automation, the player
-- cannot work (guards) or there is nothing to do; Automation.lastStartRefusal says why ("otherjob", "notallowed", a
-- guard reason, "nothing"). More than MaxSquaresPerJob squares: the nearest ones, with a message.
-- A phase of a chain (Automation.startingChain set by the chain) is not refused because of its own chain, and its
-- refusals are worded by the chain (a phase with nothing to do is skipped with the chain's own note).
function AutoPilotMoon.Automation:startSquareProcessingQueue(items, runLockVariable, message, startSquare, settings)
	settings = settings or {};

	local definition = AutoPilotMoon.Automation.byLockVar[runLockVariable];
	local player = settings.player or AutoPilotMoon:getPlayer();
	local chainRun = AutoPilotMoon.Automation.startingChain;

	AutoPilotMoon.Automation.lastStartRefusal = nil;

	if definition == nil or player == nil
	then
		AutoPilotMoon.Automation.lastStartRefusal = "aborted";

		return false;
	end

	local title = AutoPilotMoon.Automation:getTitle(definition);
	local reason = nil;

	if AutoPilotMoon.Automation.job ~= nil or (AutoPilotMoon.Chain.current ~= nil and AutoPilotMoon.Chain.current ~= chainRun)
	then
		reason = "otherjob";
	elseif not AutoPilotMoon.Automation:isAllowedByServer(definition.name)
	then
		reason = "notallowed";
	else
		reason = AutoPilotMoon.Automation:getGuardReason(player, definition);
	end

	if reason
	then
		AutoPilotMoon.Automation.lastStartRefusal = reason;

		if reasonKeys[reason] and chainRun == nil
		then
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobNotStarted", title, getText(reasonKeys[reason])), player);
		end

		return false;
	end

	if AutoPilotMoon:isFunction(items)
	then
		items = items();
	end

	local squares = {};

	for i, square in ipairs(items or {})
	do
		if square
		then
			table.insert(squares, square);
		end
	end

	if #squares == 0
	then
		AutoPilotMoon.Automation.lastStartRefusal = "nothing";

		if chainRun == nil
		then
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_NothingToDo", title), player);
		end

		return false;
	end

	local limit = AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob");
	local total = #squares;
	local cappedFrom = nil;

	if total > limit
	then
		local ref = startSquare or player:getSquare();

		squares = AutoPilotMoon.Automation:keepNearest(squares, ref:getX(), ref:getY(), ref:getZ(), limit);

		AutoPilotMoon:message(getText("IGUI_AutoPilot_A_JobCapped", title, #squares, total), false, player);
		cappedFrom = total;
	end

	AutoPilotMoon.Automation:resetJobState();

	local job = {
		name = definition.name,
		definition = definition,
		lockVar = definition.lockVar,
		player = player,
		entries = {},
		head = nil,
		headIndex = nil,
		fifo = settings.fifo == true,
		startSquare = startSquare,
		total = #squares,
		skipped = 0,
		owned = {},
		watch = { entry = nil, idleMs = 0, lastTick = nil, waits = 0, steps = 0 },
		rest = { phase = nil, since = 0, gaveUp = false, from = 0 },
		chainRun = chainRun,
		-- the area chosen in the menu (a rectangle; nil for a room, a building), drawn on the ground (spec 4.3)
		area = AutoPilotMoon.Automation.startingArea or (chainRun and chainRun.area) or nil,
		-- the start is said at the job's first frame, once the automation has given its own units (Progress:setUnits)
		announce = chainRun == nil,
	};

	for i, square in ipairs(squares)
	do
		table.insert(job.entries, newEntry(square));
	end

	AutoPilotMoon.Automation.job = job;
	AutoPilotMoon.Automation[definition.lockVar] = true;
	AutoPilotMoon.Automation.squareQueueStartSquare = startSquare;

	if chainRun
	then
		AutoPilotMoon.Progress:beginPhase(chainRun.phase, definition.name, job.total, definition.unitKey);
	else
		AutoPilotMoon.Progress:beginJob(definition.name, definition.titleKey, job.total, definition.unitKey, cappedFrom);
	end

	return true;
end

-- The start shared by the automations: the squares (a list, or a function giving it), without those in a protected
-- zone (AutoPilotMoon.Zones), then the automation's own filter, filterFn(squares, player) -> squares. Both run only once
-- the engine has accepted the start (no other job, allowed, guards), and only once (C4). The job is bound to the given
-- player. Returns the engine's answer; a message says how many squares were left out because they are protected.
function AutoPilotMoon.Automation:startJob(name, player, squares, startSquare, filterFn, settings)
	local definition = AutoPilotMoon.Automation.definitions[name];

	if definition == nil or player == nil
	then
		return false;
	end

	settings = settings or {};
	settings.player = player;

	local protected = 0;

	local function items()
		local list = squares;

		if AutoPilotMoon:isFunction(list)
		then
			list = list();
		end

		local kept, count = AutoPilotMoon.Grid:filterUnprotected(list or {}, player);

		protected = count;

		if filterFn
		then
			kept = filterFn(kept, player);
		end

		return kept;
	end

	local started = AutoPilotMoon.Automation:startSquareProcessingQueue(items, definition.lockVar, nil, startSquare, settings);

	if protected > 0
	then
		AutoPilotMoon:message(getText("IGUI_AutoPilot_A_ProtectedLeftOut", AutoPilotMoon.Automation:getTitle(definition), protected), false, player);
	end

	return started;
end

-- an automation that stops by itself (a limit reached, no tool, no water...) says why, and the engine adds nothing.
-- It is a stop: in a chain, the chain stops too.
function AutoPilotMoon.Automation:finishEarly(text)
	local job = AutoPilotMoon.Automation.job;

	if job == nil
	then
		return;
	end

	AutoPilotMoon.Automation.stopText = text;
	AutoPilotMoon:say("bad", text, job.player);
	AutoPilotMoon.Automation:stopAll("aborted");
end

-- a stop with a reason the engine words itself: "<Title> stopped: <reason>", in a chain "<Chain> stopped (phase 2):
-- <reason>" (reasonText: an already translated text, "you need a saw")
function AutoPilotMoon.Automation:stopBecause(reasonText)
	local job = AutoPilotMoon.Automation.job;

	if job == nil
	then
		return;
	end

	AutoPilotMoon.Automation.stopText = reasonText;
	AutoPilotMoon.Automation:stopAll("because");
end

-- the job is finished as far as it goes (a limit of the server reached): it ends like a job that ran out of squares, so
-- a chain goes on with its next phase. text (optional) is said first.
function AutoPilotMoon.Automation:finishDone(text)
	local job = AutoPilotMoon.Automation.job;

	if job == nil
	then
		return;
	end

	if text
	then
		AutoPilotMoon:message(text, false, job.player);
	end

	AutoPilotMoon.Automation:stopAll("done");
end

-- a counter of the running job (a job state field), nil read as 0
function AutoPilotMoon.Automation:getJobCount(field)
	return AutoPilotMoon.Automation[field] or 0;
end

function AutoPilotMoon.Automation:addJobCount(field, amount)
	AutoPilotMoon.Automation[field] = (AutoPilotMoon.Automation[field] or 0) + (amount or 1);

	return AutoPilotMoon.Automation[field];
end

-- a per-job set (a job state field: a table keyed by game objects), created on first use
function AutoPilotMoon.Automation:getJobSet(field)
	local set = AutoPilotMoon.Automation[field];

	if set == nil
	then
		set = {};
		AutoPilotMoon.Automation[field] = set;
	end

	return set;
end

-- the end over the head (spec 4.2): short (the main confirmed result), the whole summary is in the panel
local function announceStop(job, reason, stopText)
	if job.definition.announceStop and job.definition.announceStop(job, reason, stopText)
	then
		return;
	end

	local title = AutoPilotMoon.Automation:getTitle(job.definition);

	if reason == "done"
	then
		local short = AutoPilotMoon.Progress:getShortSummaryText();

		-- the end of a job (spec 4.4); never a sound of ours for a stop (zombies: the game's sounds first)
		AutoPilotMoon.UI:playSound("UISelectListItem");

		if short
		then
			AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_JobFinishedSummary", title, short), job.player);
		elseif job.skipped > 0
		then
			AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_JobFinishedSkipped", title, job.skipped), job.player);
		else
			AutoPilotMoon:say("good", getText("IGUI_AutoPilot_A_JobFinished", title), job.player);
		end
	elseif reason == "user"
	then
		AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_JobStopped", title), job.player);
	elseif reason == "because" and stopText
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobStoppedBecause", title, stopText), job.player);
	elseif reasonKeys[reason]
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_JobStoppedBecause", title, getText(reasonKeys[reason])), job.player);
	end
end

-- what a count of the start message says per unit ("alberi 37", spec 4.2)
AutoPilotMoon.Automation.countKeys = {
	IGUI_AutoPilot_S_Unit_Trees = "IGUI_AutoPilot_T_Limit_Trees",
	IGUI_AutoPilot_S_Unit_Logs = "IGUI_AutoPilot_T_Limit_Logs",
	IGUI_AutoPilot_S_Unit_Items = "IGUI_AutoPilot_T_Limit_Items",
	IGUI_AutoPilot_S_Unit_Plants = "IGUI_AutoPilot_T_Limit_Plants",
};

-- The start over the head (spec 4.2), at the job's first frame: "Taglialegna: alberi 37", with the panel closed
-- "... - muoviti per fermare", cut at the server's limit "Taglialegna: alberi 400 su 520 (limite)". The rule of the
-- level "info" leaves it out while the panel is open (the panel says it).
function AutoPilotMoon.Automation:announceStart(job)
	job.announce = false;

	if job.definition.announceStart and job.definition.announceStart(job)
	then
		return;
	end

	local state = AutoPilotMoon.Progress.state;
	local title = AutoPilotMoon.Automation:getTitle(job.definition);
	local countKey = AutoPilotMoon.Automation.countKeys[state.unitKey or ""] or "IGUI_AutoPilot_T_Limit_Squares";
	local count = getText(countKey, state.total);
	local text = nil;

	if state.cappedFrom and not state.ownUnits
	then
		text = getText("IGUI_AutoPilot_A_JobStartedCapped", title, count, state.cappedFrom);
	else
		text = getText("IGUI_AutoPilot_A_JobStartedHowToStop", title, count);
	end

	AutoPilotMoon:say("info", text, job.player);
end

-- the engine's teardown: automations call it from their stop function, with their lock
function AutoPilotMoon.Automation:stopSquareProcessingQueue(runLockVariable)
	local job = AutoPilotMoon.Automation.job;

	if job and runLockVariable ~= nil and runLockVariable ~= job.lockVar
	then
		-- not the running job: nothing to stop
		return;
	end

	local reason = AutoPilotMoon.Automation.stopReason or "aborted";
	local stopText = AutoPilotMoon.Automation.stopText;

	AutoPilotMoon.Automation:resetJobState();

	if job
	then
		AutoPilotMoon.Rest:onJobStop(job, reason);
		AutoPilotMoon.Automation:releaseActions(job, reason);

		if job.chainRun
		then
			-- the chain says what happened and decides what comes next
			AutoPilotMoon.Chain:onJobEnded(job, reason, stopText);
		else
			announceStop(job, reason, stopText);
			AutoPilotMoon.Progress:finish(reason, stopText or AutoPilotMoon.Automation:getReasonText(reason), job.player);
			setGameSpeed(1);
		end
	end
end

-- stops the running job through the automation's own stop function (and its chain, if it is a phase of one).
-- reason: done, user, zombies, vehicle, asleep, dead, nosquare, notallowed, unwell, switchedoff, aborted (the
-- automation said why),
-- because (Automation:stopBecause, with Automation.stopText). Between two phases of a chain there is no job: the chain
-- stops.
function AutoPilotMoon.Automation:stopAll(reason)
	local job = AutoPilotMoon.Automation.job;

	if not job
	then
		local stopText = AutoPilotMoon.Automation.stopText;

		AutoPilotMoon.Automation:resetJobState();

		if AutoPilotMoon.Chain.current
		then
			AutoPilotMoon.Chain:stopRun(AutoPilotMoon.Chain.current, reason or "aborted", stopText);
		end

		return;
	end

	AutoPilotMoon.Automation.stopReason = reason or "aborted";

	local stopFunction = AutoPilotMoon.Automation["stop" .. job.definition.uc];

	if stopFunction
	then
		stopFunction(AutoPilotMoon.Automation);
	end

	if AutoPilotMoon.Automation.job == job
	then
		AutoPilotMoon.Automation:stopSquareProcessingQueue(job.lockVar);
	end
end

-- every frame of the job's player (client/99_AP_Event.lua)
function AutoPilotMoon.Automation:update(player)
	local job = AutoPilotMoon.Automation.job;

	if job == nil or job.player ~= player
	then
		return;
	end

	local reason = AutoPilotMoon.Automation:getGuardReason(player, job.definition);

	if reason == nil and (player:pressedMovement(false) or player:pressedCancelAction())
	then
		reason = "user";
	end

	if reason == nil and not AutoPilotMoon.Automation:isAllowedByServer(job.name)
	then
		reason = "notallowed";
	end

	if reason
	then
		AutoPilotMoon.Automation:stopAll(reason);

		return;
	end

	if job.announce
	then
		AutoPilotMoon.Automation:announceStart(job);
	end

	-- auto-rest between two steps: nothing else happens while the character sits, the watchdog's clock does not run
	if AutoPilotMoon.Rest:update(job, player)
	then
		job.watch.lastTick = nil;

		return;
	end

	local check = AutoPilotMoon.Automation["check" .. job.definition.uc .. "Queue"];

	if check == nil
	then
		AutoPilotMoon.Automation:stopAll("aborted");

		return;
	end

	check(AutoPilotMoon.Automation, player);

	if AutoPilotMoon.Automation.job == job
	then
		AutoPilotMoon.Automation:highlight(job);
	end
end

-- One step of the job, called by the automation's check<Name>Queue with its config:
--   player, runLockVariable,
--   squareFunction = { fn = function(square, param1, param2, param3), param1, param2, param3 }: works the square,
--   removeCheckFunction(square, player) (optional), before it: true = the square is done after this step,
--     false = keep it for another step, "wait" = nothing this time, "discard" = drop it, "busy" = the automation
--     is doing something of its own under its own limits (not counted by the watchdog, no square function),
--   stopFunction(player): the automation's stop, called when the queue is empty,
--   disableSortByDistance: keep the given order (like settings.fifo at the start),
--   maxStepsPerSquare (optional): times the square function may run on the same square (it is kept by false) before
--     the square is discarded with a message.
-- Watchdog: idle time on the same square (real time, counted only while the player is idle) and "wait" answers in a
-- row are limited; past the limit the square is discarded with a message. The idle clock alone cannot catch a step
-- that keeps the player busy and then ends without progress (a walk that fails clears the queue, the next frame
-- queues it again: the player is never idle two frames in a row): maxStepsPerSquare bounds that.
function AutoPilotMoon.Automation:checkSquareProcessingQueue(config)
	local job = AutoPilotMoon.Automation.job;

	if job == nil or job.lockVar ~= config.runLockVariable
	then
		return;
	end

	local player = config.player or job.player;
	local watch = job.watch;

	if config.disableSortByDistance
	then
		job.fifo = true;
	end

	if ISTimedActionQueue.isPlayerDoingAction(player)
	then
		-- busy: the watchdog's clock does not run
		watch.lastTick = nil;

		return;
	end

	local entry = AutoPilotMoon.Automation:getHead(job, player);

	if entry == nil
	then
		if job.startSquare
		then
			AutoPilotMoon.Square:walkTo(player, job.startSquare);
		end

		AutoPilotMoon.Automation.stopReason = "done";

		if config.stopFunction
		then
			config.stopFunction(player);
		end

		if AutoPilotMoon.Automation.job == job
		then
			AutoPilotMoon.Automation:stopSquareProcessingQueue(job.lockVar);
		end

		return;
	end

	-- watchdog
	local now = getTimestampMs();

	if watch.entry ~= entry
	then
		watch.entry = entry;
		watch.idleMs = 0;
		watch.waits = 0;
		watch.steps = 0;
		watch.lastTick = now;
	else
		if watch.lastTick
		then
			local elapsed = now - watch.lastTick;

			if elapsed > AutoPilotMoon.Automation.maxFrameMs
			then
				elapsed = AutoPilotMoon.Automation.maxFrameMs;
			end

			if elapsed > 0
			then
				watch.idleMs = watch.idleMs + elapsed;
			end
		end

		watch.lastTick = now;
	end

	if watch.idleMs >= AutoPilotMoon.Automation.watchdogIdleMs or watch.waits >= AutoPilotMoon.Automation.maxConsecutiveWaits
	then
		AutoPilotMoon.Automation:discardHead(job, true);

		return;
	end

	local square = entry.square;
	local before = snapshotActions(player);
	local result = true;

	if config.removeCheckFunction
	then
		result = config.removeCheckFunction(square, player);

		if AutoPilotMoon.Automation.job ~= job
		then
			return;
		end
	end

	if result == "wait"
	then
		watch.waits = watch.waits + 1;
		markOwnedActions(job, player, before);

		return;
	end

	if result == "busy"
	then
		-- the automation works outside the queue's steps (carrying a corpse...) under its own time limits: the
		-- watchdog does not count this frame, nothing else happens
		watch.waits = 0;
		watch.idleMs = 0;
		watch.lastTick = nil;
		markOwnedActions(job, player, before);

		return;
	end

	watch.waits = 0;

	if result == "discard"
	then
		AutoPilotMoon.Automation:discardHead(job, false);
		markOwnedActions(job, player, before);

		return;
	end

	if AdjacentFreeTileFinder.Find(square, player) == nil
	then
		AutoPilotMoon.Automation:requeueHead(job);
		markOwnedActions(job, player, before);

		return;
	end

	if result == true
	then
		AutoPilotMoon.Automation:consumeHead(job);
	elseif config.maxStepsPerSquare
	then
		watch.steps = watch.steps + 1;

		if watch.steps > config.maxStepsPerSquare
		then
			AutoPilotMoon.Automation:discardHead(job, true);
			markOwnedActions(job, player, before);

			return;
		end
	end

	local fn = config.squareFunction and config.squareFunction.fn;

	if fn
	then
		fn(square, config.squareFunction.param1, config.squareFunction.param2, config.squareFunction.param3);
	end

	if AutoPilotMoon.Automation.job == job
	then
		markOwnedActions(job, player, before);
	end
end

