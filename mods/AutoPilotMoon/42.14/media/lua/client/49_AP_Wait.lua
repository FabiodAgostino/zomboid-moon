-- AutoPilot (Moon): automations for the Moon server.

-- "Wait for the object" (19/11/2026, ANALISI-MACRO-INTELLIGENTI.md 3): the one rule of the engine, the jobs and the
-- macros. A step is done when the game's state shows it, looked at by id, with the character idle; never because an
-- action was queued or ended, never after a fixed time. Time is only a limit: past it the step stops and says why.
-- Why by id and not by object (verified in the 42.22 Lua and jar):
--   - in multiplayer the item that arrives on the client is a NEW object with the same id (the server's
--     AddInventoryItemToContainer builds it; ItemContainer.contains compares the object, not the id): a reference kept
--     by the mod stays the old object, out of every container, for ever;
--   - a refused transfer (or an action whose start is not valid) stops and empties the whole queue
--     (ISBaseTimedAction:stop -> resetQueue -> forceCancel on what had not started): the queue is empty, nothing happened;
--   - a container never opened says isExplored() at once, its items arrive later (ISInventoryPage:checkExplored), and
--     the loot window explores the containers next to the character by itself: isExplored() is never trusted;
--   - "Open and Eat" gets its meal with a command of the server that is not ordered with the rest.
--
-- local w = AutoPilotMoon.Wait:new(player, { label = text already translated, timeoutMs = ms })
-- what is awaited (item: the object or its id; container: an ItemContainer or "inventory"):
--   w:expectIn(item, container)            in the container by id, bags inside included
--   w:expectOut(item, container)           no longer in the container (by id)
--   w:expectOnFloor(item, square, radius)  among the world items of the square (radius 0) or of its 3x3 (radius 1)
--   w:expectInHand(item, hand)             "primary" | "secondary" | "both" (the same id in the two hands)
--   w:expectGone(item, where)              used up: not in the inventory, not on the 3x3 of where.square (else the
--                                          character's), not in where.container
--   w:expectNew(types, where, n)           at least n items of those types (nil: any) whose id was not there NOW (the
--                                          photo is taken here, when queued), in the inventory and, with where.floor,
--                                          on the 3x3 at the character's feet (where.square, where.radius: elsewhere,
--                                          wider); where.exclude: ids never counted
--   w:expectCount(container, types, delta) the number of those types in the container changed by delta since now
--   w:expectLoaded(container)              what a container holds arrived from the server (see Wait:loadState); never a
--                                          failure: past the limit "done" with info.uncertain
--   w:expectTrue(fn, key)                  a free test (hunger down, the plant's water up)
--   w:expectAny({ entries })               one of these is enough (Wait.make.<kind>(player, ...) builds them)
--   w:watch(action)                        after ISTimedActionQueue.add: not queued -> "fail" "notqueued" at once; stopped
--                                          or cancelled before its perform -> a refusal, said Wait.refusedSettleMs later
--   w:watchQueued(mark)                    every action queued since Wait:mark(player) (a game's helper queued them)
--   w:wasPerformed(action)                 the game performed that watched action (20/11/2026: an item gone from a
--                                          crate counts as eaten only once the meal itself was performed)
-- the check, only with the character idle (the step that calls it is already the engine's idle step):
--   w:check() -> "busy" | "done" | "fail", reasonKey ("timeout" | "partial" | "refused" | "notqueued"), info
--     info = { arrived = n, total = m, uncertain = bool, ids = { [id] = true } }
--   w:resolve(id) -> the item with that id now (inventory, the containers of the wait, the 3x3 at the feet)
--   w:arrivedIds() -> { [id] = true } of what arrived (counted also when the wait fails)
-- without a wait: Wait:findById(player, id, where), Wait:floorIds(square, radius), Wait:loadState(container),
--   Wait:explore(container, player)
-- The panel: after Wait.waitingAfterMs idle "Ora: aspetta il server: Carbone nello zaino (2 su 3)" (the label is the
-- caller's), "aspetta il contenuto di Cassa" for what a container holds. Only two numbers for every job and macro:
-- Wait.waitingAfterMs and Wait.timeoutMs (a kind that needs more says it: opts.timeoutMs, "Open and Eat" 8 s).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Wait = AutoPilotMoon.Wait or {};

local Wait = AutoPilotMoon.Wait;
local WaitMeta = {};

WaitMeta.__index = WaitMeta;

Wait.waitingAfterMs = 1500;   -- idle: from here the panel says "aspetta il server: ..."
Wait.timeoutMs = 5000;        -- idle: past this, "fail" with the reason (a kind may ask for more: opts.timeoutMs)
Wait.refusedSettleMs = 300;   -- an action of the step refused: the state is looked at this long more, then "refused"
Wait.idleGapMs = 500;         -- a longer gap between two checks = the character was busy: the idle clock starts again
Wait.loadMinMs = 1500;        -- a container asked for: its answer is awaited this long (from the request)
Wait.loadStableMs = 400;      -- and the number of its items unchanged this long
Wait.loadForgetMs = 600000;   -- a container's request forgotten after this (the registry stays small)
Wait.watchActions = true;     -- false: no field of the game's actions touched, only the state and the limit
Wait.loads = Wait.loads or {};
Wait.make = Wait.make or {};

local function now()
	return getTimestampMs();
end

local function idOf(item)
	if item == nil or type(item) == "number"
	then
		return item;
	end

	return item:getID();
end

local function typeOf(item)
	if item == nil or type(item) == "number"
	then
		return nil;
	end

	return item:getFullType();
end

-- a set of full types from a list, a set, a single type, or nil (any type)
local function typeSet(types)
	if types == nil
	then
		return nil;
	end

	if type(types) == "string"
	then
		return { [types] = true };
	end

	local set = {};

	for k, v in pairs(types)
	do
		if type(k) == "number"
		then
			set[v] = true;
		elseif v == true
		then
			set[k] = true;
		end
	end

	return set;
end

local function containerOf(player, container)
	if container == "inventory" or container == nil
	then
		return player:getInventory();
	end

	return container;
end

-- the floor of the loot window (ISInventoryPage.GetFloorContainer): a list of the world items around, never emptied
-- by the game (ItemContainer.clear): an id found there says nothing
local function isFloorContainer(container)
	return container ~= nil and container ~= "inventory" and container:getType() == "floor";
end

local function coordsOf(square)
	if square == nil
	then
		return nil;
	end

	-- coordinates already ({ x, y, z }, a Lua table without the square's methods)
	if type(square) == "table" and square.getX == nil
	then
		return square;
	end

	return { x = square:getX(), y = square:getY(), z = square:getZ() };
end

local function squareAt(coords)
	local cell = getCell();

	return cell and coords and cell:getGridSquare(coords.x, coords.y, coords.z) or nil;
end

-- ============================================================================================================
-- Without a wait
-- ============================================================================================================

-- the ids of the items lying on the square (radius 0) or around it (radius 1: the 3x3), same floor
function AutoPilotMoon.Wait:floorIds(square, radius)
	local ids = {};
	local at = coordsOf(square);
	local cell = getCell();

	if at == nil or cell == nil
	then
		return ids;
	end

	radius = radius or 0;

	for dx = -radius, radius
	do
		for dy = -radius, radius
		do
			local other = cell:getGridSquare(at.x + dx, at.y + dy, at.z);
			local objects = other and other:getWorldObjects();

			if objects
			then
				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);
					local item = object and object:getItem();

					if item
					then
						ids[item:getID()] = true;
					end
				end
			end
		end
	end

	return ids;
end

-- the item lying around the square with this id (nil: none)
local function floorItem(square, radius, id)
	local at = coordsOf(square);
	local cell = getCell();

	if at == nil or cell == nil
	then
		return nil;
	end

	for dx = -radius, radius
	do
		for dy = -radius, radius
		do
			local other = cell:getGridSquare(at.x + dx, at.y + dy, at.z);
			local objects = other and other:getWorldObjects();

			if objects
			then
				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);
					local item = object and object:getItem();

					if item and item:getID() == id
					then
						return item;
					end
				end
			end
		end
	end

	return nil;
end

-- The item with this id now: the inventory (bags included), then the containers of where (where.containers, a list,
-- or where.container), then the items lying on the 3x3 of where.square (else of the character's square; where.floor =
-- false: not on the floor).
function AutoPilotMoon.Wait:findById(player, id, where)
	if id == nil
	then
		return nil;
	end

	local item = player:getInventory():getItemWithIDRecursiv(id);

	if item
	then
		return item;
	end

	where = where or {};

	local list = where.containers or {};

	if where.container
	then
		list = { where.container };

		for i, c in ipairs(where.containers or {})
		do
			table.insert(list, c);
		end
	end

	for i, container in ipairs(list)
	do
		if container ~= "inventory" and not isFloorContainer(container)
		then
			item = container:getItemWithIDRecursiv(id);

			if item
			then
				return item;
			end
		end
	end

	if where.floor == false
	then
		return nil;
	end

	return floorItem(where.square or player:getSquare(), where.radius or 1, id);
end

-- ============================================================================================================
-- Containers never opened (ANALISI-MACRO-INTELLIGENTI.md 3.4): the game gives no "loaded" signal. A registry by
-- container: when it was asked for, how many items it had then. Loaded when it was explored and held items the first
-- time it was seen (the game asked for it long ago), when its number of items changed since the request (the answer is
-- one packet with everything: the first change is the answer), or when Wait.loadMinMs passed since the request with
-- the number unchanged for Wait.loadStableMs (empty, or the server did not answer: "uncertain"). Explored and empty the
-- first time it is seen: maybe the loot window asked for it a moment ago (it explores the containers around the
-- character by itself), so it is watched from now as if just asked for (then certain: the game asked, not us).
-- ============================================================================================================

local function itemCount(container)
	local items = container:getItems();

	return items and items:size() or 0;
end

local function forgetOld(time)
	for container, entry in pairs(Wait.loads)
	do
		if time - entry.at > Wait.loadForgetMs
		then
			Wait.loads[container] = nil;
		end
	end
end

local function register(container, assumed)
	local time = now();

	forgetOld(time);

	local entry = { at = time, count = itemCount(container), stableSince = time, assumed = assumed == true };

	Wait.loads[container] = entry;

	return entry;
end

-- what the loot window does when a container is first opened (ISInventoryPage:checkExplored: on a server the items are
-- asked for), and the request written down; nothing for a container already explored
function AutoPilotMoon.Wait:explore(container, player)
	if container == nil or container == "inventory" or container:isExplored()
	then
		return;
	end

	-- the number before the request: a change is the answer
	local entry = register(container, false);

	ISInventoryPage:checkExplored(container, player);

	-- in single player the game fills the container at once (ItemPicker.fillContainer): nothing to wait for
	if itemCount(container) ~= entry.count or not isClient()
	then
		entry.loaded = true;
	end
end

-- the time of a request moved to now (a request made before a walk: the answer is awaited from the arrival); nothing
-- for a container already loaded
function AutoPilotMoon.Wait:restartLoad(container)
	local entry = Wait.loads[container];

	if entry and not entry.loaded
	then
		entry.at = now();
		entry.stableSince = entry.at;
	end
end

-- "loaded" (and true when certain), "loading", or "unknown" (never explored and never asked for)
function AutoPilotMoon.Wait:loadState(container)
	if container == nil or container == "inventory" or isFloorContainer(container)
	then
		return "loaded", true;
	end

	local entry = Wait.loads[container];
	local count = itemCount(container);

	if entry == nil
	then
		if not container:isExplored()
		then
			return "unknown", false;
		end

		if not isClient()
		then
			-- single player: explored means filled
			return "loaded", true;
		end

		entry = register(container, true);

		if count > 0
		then
			-- written down as loaded: emptied later (by this very job), it is still known
			entry.loaded = true;

			return "loaded", true;
		end
	end

	if entry.loaded
	then
		return "loaded", true;
	end

	local time = now();

	if count ~= entry.count
	then
		entry.loaded = true;

		return "loaded", true;
	end

	if time - entry.at >= Wait.loadMinMs and time - entry.stableSince >= Wait.loadStableMs
	then
		return "loaded", entry.assumed;
	end

	return "loading", false;
end

-- ============================================================================================================
-- What is awaited (each a small table; Wait.make.<kind>(player, ...) builds one, w:expect<Kind> adds it)
-- ============================================================================================================

function Wait.make.inside(player, item, container)
	return { kind = "in", id = idOf(item), type = typeOf(item), container = container or "inventory" };
end

function Wait.make.outside(player, item, container)
	return { kind = "out", id = idOf(item), type = typeOf(item), container = container or "inventory" };
end

function Wait.make.onFloor(player, item, square, radius)
	return { kind = "floor", id = idOf(item), type = typeOf(item), at = coordsOf(square or player:getSquare()), radius = radius or 0 };
end

function Wait.make.inHand(player, item, hand)
	return { kind = "hand", id = idOf(item), type = typeOf(item), hand = hand or "primary" };
end

function Wait.make.gone(player, item, where)
	where = where or {};

	local container = where.container;

	if container and isFloorContainer(container)
	then
		container = nil;
	end

	return { kind = "gone", id = idOf(item), type = typeOf(item), at = coordsOf(where.square or player:getSquare()),
		radius = where.radius or 1, container = container };
end

local function snapshotIds(player, set, where)
	local ids = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return set == nil or set[item:getFullType()] == true;
	end);

	for i = 0, items:size() - 1
	do
		ids[items:get(i):getID()] = true;
	end

	if where and where.floor
	then
		for id in pairs(Wait:floorIds(where.square or player:getSquare(), where.radius or 1))
		do
			ids[id] = true;
		end
	end

	for id in pairs(where and where.exclude or {})
	do
		ids[id] = true;
	end

	return ids;
end

function Wait.make.new(player, types, where, n)
	local set = typeSet(types);
	local at = where and where.floor and coordsOf(where.square or player:getSquare()) or nil;

	return { kind = "new", types = set, n = n or 1, floor = at, radius = where and where.radius or 1,
		before = snapshotIds(player, set, where), newIds = {} };
end

local function countTypes(container, set)
	local items = container:getAllEvalRecurse(function(item)
		return set == nil or set[item:getFullType()] == true;
	end);

	return items:size();
end

function Wait.make.count(player, container, types, delta)
	local set = typeSet(types);
	local c = containerOf(player, container);

	return { kind = "count", container = c, types = set, delta = delta, base = countTypes(c, set) };
end

function Wait.make.loaded(player, container)
	Wait:explore(container, player);

	return { kind = "loaded", container = container };
end

function Wait.make.isTrue(player, fn, key)
	return { kind = "true", fn = fn, key = key };
end

-- ============================================================================================================
-- A wait
-- ============================================================================================================

function AutoPilotMoon.Wait:new(player, opts)
	opts = opts or {};

	return setmetatable({
		player = player,
		label = opts.label,
		timeoutMs = opts.timeoutMs or Wait.timeoutMs,
		waitingAfterMs = opts.waitingAfterMs or Wait.waitingAfterMs,
		list = {},
		actions = {},
		containers = {},
		idleSince = nil,
		lastSeen = nil,
		refusedAt = nil,
		performed = 0,
		performedActions = {},
		stopped = {},
		cancelled = {},
		notQueued = false,
		showing = false,
	}, WaitMeta);
end

function WaitMeta:add(entry)
	table.insert(self.list, entry);

	if entry.container and entry.container ~= "inventory" and entry.kind ~= "count" and entry.kind ~= "loaded"
	then
		table.insert(self.containers, entry.container);
	end

	return entry;
end

function WaitMeta:expectIn(item, container)
	return self:add(Wait.make.inside(self.player, item, container));
end

function WaitMeta:expectOut(item, container)
	return self:add(Wait.make.outside(self.player, item, container));
end

function WaitMeta:expectOnFloor(item, square, radius)
	return self:add(Wait.make.onFloor(self.player, item, square, radius));
end

function WaitMeta:expectInHand(item, hand)
	return self:add(Wait.make.inHand(self.player, item, hand));
end

function WaitMeta:expectGone(item, where)
	return self:add(Wait.make.gone(self.player, item, where));
end

function WaitMeta:expectNew(types, where, n)
	return self:add(Wait.make.new(self.player, types, where, n));
end

function WaitMeta:expectCount(container, types, delta)
	return self:add(Wait.make.count(self.player, container, types, delta));
end

function WaitMeta:expectLoaded(container)
	return self:add(Wait.make.loaded(self.player, container));
end

function WaitMeta:expectTrue(fn, key)
	return self:add(Wait.make.isTrue(self.player, fn, key));
end

function WaitMeta:expectAny(entries)
	for i, entry in ipairs(entries)
	do
		if entry.container and entry.container ~= "inventory" and entry.kind ~= "count" and entry.kind ~= "loaded"
		then
			table.insert(self.containers, entry.container);
		end
	end

	return self:add({ kind = "any", list = entries });
end

-- ============================================================================================================
-- The actions of the step: fields of the single action (never the game's class), the game's own method always
-- called first; only a note is taken. Actions merged by the game (ISInventoryTransferAction:checkQueueList wipes them)
-- lose the fields: the first one, the one that stops, keeps them.
-- ============================================================================================================

function WaitMeta:watch(action)
	if action == nil
	then
		self.notQueued = true;

		return;
	end

	if not action.ignoreAction and not ISTimedActionQueue.hasAction(action)
	then
		-- ISTimedActionQueue.add drops an action silently (asleep, dragging a corpse)
		self.notQueued = true;

		return;
	end

	table.insert(self.actions, action);

	if not Wait.watchActions
	then
		return;
	end

	local w = self;
	local gameStop = action.stop;
	local gameCancel = action.forceCancel;
	local gamePerform = action.perform;

	action.stop = function(a)
		w.refusedAt = w.refusedAt or now();
		w.stopped[a] = true;

		if gameStop
		then
			return gameStop(a);
		end
	end;

	action.forceCancel = function(a)
		w.refusedAt = w.refusedAt or now();
		w.cancelled[a] = true;

		if gameCancel
		then
			return gameCancel(a);
		end
	end;

	action.perform = function(a)
		w.performed = w.performed + 1;
		w.performedActions[a] = true;

		if gamePerform
		then
			return gamePerform(a);
		end
	end;
end

-- the action was stopped by the game (a refusal, an action not valid any more) / cancelled before it started (the
-- queue emptied by a refusal before it: it never ran)
function WaitMeta:wasStopped(action)
	return action ~= nil and self.stopped[action] == true;
end

function WaitMeta:wasCancelled(action)
	return action ~= nil and self.cancelled[action] == true;
end

-- the game performed the action (its perform came: a success)
function WaitMeta:wasPerformed(action)
	return action ~= nil and self.performedActions[action] == true;
end

-- the actions in the character's queue now (Wait:mark), to watch what a game's helper queues
function AutoPilotMoon.Wait:mark(player)
	local seen = {};
	local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player];

	if queue and queue.queue
	then
		for i, action in ipairs(queue.queue)
		do
			seen[action] = true;
		end
	end

	return seen;
end

-- every action queued since the mark; none: not queued
function WaitMeta:watchQueued(mark)
	local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[self.player];
	local any = false;

	if queue and queue.queue
	then
		for i, action in ipairs(queue.queue)
		do
			if not mark[action]
			then
				any = true;
				self:watch(action);
			end
		end
	end

	if not any
	then
		self.notQueued = true;
	end
end

-- ============================================================================================================
-- The check
-- ============================================================================================================

local function inHand(player, hand, id)
	local primary = player:getPrimaryHandItem();
	local secondary = player:getSecondaryHandItem();

	if hand == "secondary"
	then
		return secondary ~= nil and secondary:getID() == id;
	elseif hand == "both"
	then
		return primary ~= nil and secondary ~= nil and primary:getID() == id and secondary:getID() == id;
	end

	return primary ~= nil and primary:getID() == id;
end

local function holds(player, container, id)
	if isFloorContainer(container)
	then
		return false;
	end

	return containerOf(player, container):getItemWithIDRecursiv(id) ~= nil;
end

local function countNew(player, e)
	local count = 0;
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return (e.types == nil or e.types[item:getFullType()] == true) and e.before[item:getID()] == nil;
	end);

	for i = 0, items:size() - 1
	do
		e.newIds[items:get(i):getID()] = true;
		count = count + 1;
	end

	if e.floor
	then
		local cell = getCell();
		local radius = e.radius or 1;

		for dx = -radius, radius
		do
			for dy = -radius, radius
			do
				local other = cell and cell:getGridSquare(e.floor.x + dx, e.floor.y + dy, e.floor.z);
				local objects = other and other:getWorldObjects();

				if objects
				then
					for i = 0, objects:size() - 1
					do
						local item = objects:get(i) and objects:get(i):getItem();

						if item and (e.types == nil or e.types[item:getFullType()] == true) and e.before[item:getID()] == nil
						then
							e.newIds[item:getID()] = true;
							count = count + 1;
						end
					end
				end
			end
		end
	end

	return count;
end

local satisfied;

satisfied = function(w, e)
	local player = w.player;
	local kind = e.kind;

	if kind == "in"
	then
		return holds(player, e.container, e.id);
	elseif kind == "out"
	then
		return not holds(player, e.container, e.id);
	elseif kind == "floor"
	then
		return floorItem(e.at, e.radius, e.id) ~= nil;
	elseif kind == "hand"
	then
		return inHand(player, e.hand, e.id);
	elseif kind == "gone"
	then
		return player:getInventory():getItemWithIDRecursiv(e.id) == nil
			and not (e.container and e.container:getItemWithIDRecursiv(e.id) ~= nil)
			and floorItem(e.at, e.radius, e.id) == nil;
	elseif kind == "new"
	then
		return countNew(player, e) >= e.n;
	elseif kind == "count"
	then
		local change = countTypes(e.container, e.types) - e.base;

		if e.delta >= 0
		then
			return change >= e.delta;
		end

		return change <= e.delta;
	elseif kind == "loaded"
	then
		local state, certain = Wait:loadState(e.container);

		if state == "unknown"
		then
			Wait:explore(e.container, player);

			return false;
		end

		e.uncertain = not certain;

		return state == "loaded";
	elseif kind == "any"
	then
		for i, sub in ipairs(e.list)
		do
			if satisfied(w, sub)
			then
				e.which = sub;

				return true;
			end
		end

		return false;
	end

	return e.fn() == true;
end

function WaitMeta:info(arrived, total)
	local uncertain = false;

	for i, e in ipairs(self.list)
	do
		if e.kind == "loaded" and e.uncertain
		then
			uncertain = true;
		end
	end

	return { arrived = arrived or 0, total = total or #self.list, uncertain = uncertain, ids = self:arrivedIds(),
		performed = self.performed, refused = self.refusedAt ~= nil };
end

function WaitMeta:arrivedIds()
	local ids = {};

	for i, e in ipairs(self.list)
	do
		if e.done and e.id
		then
			ids[e.id] = true;
		end
	end

	return ids;
end

-- the ids that appeared, of every expectNew (also inside an expectAny)
function WaitMeta:newIds()
	local ids = {};
	local function collect(e)
		if e.kind == "new"
		then
			for id in pairs(e.newIds)
			do
				ids[id] = true;
			end
		elseif e.kind == "any"
		then
			for i, sub in ipairs(e.list)
			do
				collect(sub);
			end
		end
	end

	for i, e in ipairs(self.list)
	do
		collect(e);
	end

	return ids;
end

-- the item with this id now (to read its state: the can's water, the book's pages)
function WaitMeta:resolve(id)
	return Wait:findById(self.player, id, { containers = self.containers });
end

local function onlyLoads(w)
	for i, e in ipairs(w.list)
	do
		if not e.done and e.kind ~= "loaded"
		then
			return false;
		end
	end

	return true;
end

function WaitMeta:panelText(arrived, total)
	if onlyLoads(self)
	then
		return self.label and getText("IGUI_AutoPilot_P_Now_WaitLoad", self.label) or nil;
	end

	if self.label == nil
	then
		return nil;
	end

	if total > 1
	then
		return getText("IGUI_AutoPilot_P_Now_WaitServer", self.label, arrived, total);
	end

	return getText("IGUI_AutoPilot_P_Now_WaitServerOne", self.label);
end

local function ended(w)
	if w.showing
	then
		w.showing = false;
		AutoPilotMoon.Progress:setWaiting(false);
	end
end

-- the panel's line off (a wait dropped before its end: the job stopped, a new step)
function WaitMeta:cancel()
	ended(self);
end

function WaitMeta:check()
	local time = now();
	local player = self.player;

	if ISTimedActionQueue.isPlayerDoingAction(player)
	then
		self.lastSeen = nil;

		return "busy";
	end

	if self.notQueued
	then
		ended(self);

		return "fail", "notqueued", self:info(0, #self.list);
	end

	if self.lastSeen == nil or time - self.lastSeen > Wait.idleGapMs
	then
		self.idleSince = time;
	end

	self.lastSeen = time;

	local arrived = 0;
	local total = #self.list;

	for i, e in ipairs(self.list)
	do
		if e.done or satisfied(self, e)
		then
			-- once true, it stays true: an item arrived and then taken by a friend does not go back
			e.done = true;
			arrived = arrived + 1;
		end
	end

	if arrived == total
	then
		ended(self);

		return "done", nil, self:info(arrived, total);
	end

	local idle = time - self.idleSince;

	if self.refusedAt and time - math.max(self.refusedAt, self.idleSince) >= Wait.refusedSettleMs
	then
		ended(self);

		return "fail", arrived > 0 and "partial" or "refused", self:info(arrived, total);
	end

	if idle >= self.timeoutMs
	then
		ended(self);

		if onlyLoads(self)
		then
			-- an empty container is an answer too: what a container holds never fails, it is uncertain
			for i, e in ipairs(self.list)
			do
				if not e.done
				then
					e.done = true;
					e.uncertain = true;
				end
			end

			return "done", nil, self:info(total, total);
		end

		return "fail", arrived > 0 and "partial" or "timeout", self:info(arrived, total);
	end

	if idle >= self.waitingAfterMs
	then
		self.showing = true;
		AutoPilotMoon.Progress:setWaiting(true, self:panelText(arrived, total));
	end

	return "busy";
end

-- what is there now, looked at once without the clock (a job stopped meanwhile counts what arrived): arrived, total
function WaitMeta:settle()
	local arrived = 0;

	for i, e in ipairs(self.list)
	do
		if e.done or satisfied(self, e)
		then
			e.done = true;
			arrived = arrived + 1;
		end
	end

	ended(self);

	return arrived, #self.list;
end

-- the seconds of the limit, for the texts ("dopo 5 secondi")
function WaitMeta:seconds()
	return math.floor(self.timeoutMs / 1000);
end
