-- AutoPilot (Moon): automations for the Moon server.

-- The macros' vicinity (26/11/2026, ANALISI-AUTONOMIA.md 3.5, contract C4 of section 5): what eat(), drink(),
-- has_food(), has_drink(), have_fun() and has_fun() find beyond the loot window's reach, up to Near.radius squares on
-- the character's floor and in its building (or both outside: the rule of drink(source=True)'s sources and of rest()'s
-- seats), and the walk there. Never a corpse, a ZomBOT gravestone, a container locked for the character, a square of a
-- safehouse it may not use, a vehicle (those stay "within reach" only, MacroFood.lua).
--
-- The rings of eat() / drink() (MacroFood.lua): what the character carries; within reach (the loot window, the 3x3);
-- then here, the vicinity: the furniture's containers and the items on the floor of every square within Near.radius
-- that the loot window does not show (beyond the 3x3, or behind a wall of it: ISInventoryPage:refreshBackpacks of 42.22
-- lists only the 3x3 squares IsoGridSquare.canReachTo accepts). A container "known" (its contents arrived: the
-- engine's Wait:loadState says "loaded") counts for the lines and the conditions; one never opened ("unknown": not
-- explored, never asked for) only for eat() and drink(), which walk there and look (a kitchen's fridge, freezer,
-- counter, overhead cupboard, shelves; the nearest first, at most Near.maxLooks a line). Nothing is ever asked from
-- the server from afar: the loot window asks for a container when the character stands next to it.
--
-- The walk (approach): "a walk, not an action", as to a bench. The game's own walk next to the container
-- (luautils.walkAdj, as the game's menus walk to a sink or a barrel) or onto the square of an item on the floor
-- (luautils.walk);
-- the line's start answers "wait" and comes again with the character idle, when what was far is within reach and the
-- code of the loot window does the rest (the item into the inventory, the meal, the rest back where it was). The walk
-- is the macro's pending "walk" (MacroRun.lua's confirm: the same line again), with pending.busy (contract C3): longer
-- than Near.walkTimeoutMs, the engine empties the queue. The line's memory (run.approach): every walk of the line, how
-- many to the same thing (the third try stops the line: "non riesce ad arrivare a Frigo"), what was reached (never
-- walked to again by the same line), how many containers never opened it looked into. A new memory for another line,
-- or for the same line once an action was done since (a loop's next turn).
--
-- Near.radius, Near.maxLooks, Near.maxWalks, Near.kitchenTypes, Near.walkTimeoutMs(distance)
-- Near:allowed(op)               the line may look there: near ~= false, walk ~= false, the server's MacroEatNear on
-- Near:containers(player)        { { container, object, square, name, distance, state = "loaded" / "unknown" /
--                                "loading", kitchen = bool, key } }, beyond the reach, the nearest first
-- Near:floorItems(player)        { { item, square, distance, object, name, floor = true, key } }, beyond the reach
-- Near:find(player, test, opts)  the nearest entry with an item test(item) accepts (entry.item: the first one), or nil;
--                                opts.unknown: else the nearest kitchen container never opened (entry.item nil);
--                                opts.memory (Near:memory): leaves out what the line reached, at most Near.maxLooks looks
-- Near:approach(run, op, entry)  queues the walk next to the entry -> nil, nil, "wait" (the step comes again), or
--                                nil and the reason's text (whyText)
-- Near:inReach(player, square)   the square is one the loot window shows (the 3x3 the character can reach)
-- Near:memory(player, op)        the memory of the line the player's macro is at, or nil
-- Near:starting(player, op)      op is the line the player's macro is starting now (not a condition, not the editor's
--                                "Adesso si puo' fare?")

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Near = AutoPilotMoon.Macro.Near or {};

local Near = AutoPilotMoon.Macro.Near;

Near.radius = 8;               -- squares from the character (MacroLang.lua's Lang.nearRadius, the same)
Near.maxLooks = 3;             -- containers never opened looked into in one line, at most
Near.maxWalks = 2;             -- walks of one line to the same thing: the third try stops the line
-- the kitchen's containers eat() and drink() walk to when never opened (the types of IGUI_ContainerTitle_*)
Near.kitchenTypes = { fridge = true, freezer = true, counter = true, overhead = true, shelves = true };

-- the longest a walk there may last (real time, the character busy): as walk_to's (ANALISI-AUTONOMIA.md 3.3), 15 s and
-- 2 s a square in a straight line, at most 2 minutes
function AutoPilotMoon.Macro.Near.walkTimeoutMs(distance)
	return math.min(120000, 15000 + 2000 * math.ceil(distance or 0));
end

-- the text of why the walk cannot be done, its key remembered for the notifications (the code of the stop)
local function whyText(key, a, b, c)
	return AutoPilotMoon.Notify:why(key, a, b, c);
end

function AutoPilotMoon.Macro.Near:allowed(op)
	return op ~= nil and op.near ~= false and op.walk ~= false and AutoPilotMoon.Sandbox:getBooleanOn("MacroEatNear") == true;
end

-- ============================================================================================================
-- Where
-- ============================================================================================================

-- One of the squares the loot window shows (ISInventoryPage:refreshBackpacks of 42.22): the character's own, or one of
-- the 8 around it on its floor that IsoGridSquare.canReachTo accepts (no wall, window or closed door between).
function AutoPilotMoon.Macro.Near:inReach(player, square)
	local here = player:getCurrentSquare();

	if here == nil or square == nil or square:getZ() ~= here:getZ()
	then
		return false;
	end

	if math.abs(square:getX() - here:getX()) > 1 or math.abs(square:getY() - here:getY()) > 1
	then
		return false;
	end

	return square == here or here:canReachTo(square);
end

local function nearer(a, b)
	if a.distance ~= b.distance
	then
		return a.distance < b.distance;
	end

	if a.y ~= b.y
	then
		return a.y < b.y;
	end

	if a.x ~= b.x
	then
		return a.x < b.x;
	end

	return a.order < b.order;
end

-- The squares of the vicinity, the nearest first: { square, distance, x, y } within Near.radius squares (in a straight
-- line) on the character's floor, in its building (IsoGridSquare.getBuilding, the room's; both nil: outside), never one
-- the loot window shows already, never one of a safehouse the character may not use.
local function squares(player)
	local list = {};
	local cell = getCell();
	local here = player:getCurrentSquare();

	if cell == nil or here == nil
	then
		return list;
	end

	local building = player:getBuilding();
	local x0, y0, z = here:getX(), here:getY(), here:getZ();
	local r = Near.radius;

	for x = x0 - r, x0 + r
	do
		for y = y0 - r, y0 + r
		do
			local d2 = (x - x0) * (x - x0) + (y - y0) * (y - y0);
			local square = d2 <= r * r and cell:getGridSquare(x, y, z) or nil;

			if square and square:getBuilding() == building and not Near:inReach(player, square)
				and not AutoPilotMoon.Zones:isProtected(square, player)
			then
				table.insert(list, { square = square, distance = math.sqrt(d2), x = x, y = y, order = #list + 1 });
			end
		end
	end

	table.sort(list, nearer);

	return list;
end

-- a piece of the world whose containers are never looked into here: a corpse, an item lying on the floor (its bag), a
-- vehicle or anything moving, a ZomBOT gravestone
local function leftOut(object)
	return instanceof(object, "IsoDeadBody") or instanceof(object, "IsoWorldInventoryObject") or instanceof(object, "IsoMovingObject")
		or AutoPilotMoon.Zones:isGrave(object);
end

-- the containers on those squares (spots: squares(player))
local function containersOn(player, spots)
	local list = {};

	for i, spot in ipairs(spots)
	do
		local objects = spot.square:getObjects();

		for k = 0, objects:size() - 1
		do
			local object = objects:get(k);

			if object and not leftOut(object)
			then
				for c = 0, object:getContainerCount() - 1
				do
					local container = object:getContainerByIndex(c);

					if container and not AutoPilotMoon.Item:isLockedFor(object, container, player)
					then
						table.insert(list, { container = container, object = object, square = spot.square, distance = spot.distance,
							name = AutoPilotMoon.Destination:getContainerName(container), state = (AutoPilotMoon.Wait:loadState(container)),
							kitchen = Near.kitchenTypes[container:getType()] == true, key = container,
							x = spot.x, y = spot.y, order = #list + 1 });
					end
				end
			end
		end
	end

	return list;
end

-- the items lying on the floor of those squares
local function floorOn(spots)
	local list = {};
	local name = nil;

	for i, spot in ipairs(spots)
	do
		local objects = spot.square:getWorldObjects();

		for k = 0, objects:size() - 1
		do
			local object = objects:get(k);
			local item = object and object:getItem();

			if item
			then
				-- the loot window's name of the floor ("Pavimento")
				name = name or getText("IGUI_ContainerTitle_floor");
				table.insert(list, { item = item, square = spot.square, distance = spot.distance, object = object, name = name,
					floor = true, key = spot.square, x = spot.x, y = spot.y, order = 1000000 + #list });
			end
		end
	end

	return list;
end

function AutoPilotMoon.Macro.Near:containers(player)
	return containersOn(player, squares(player));
end

function AutoPilotMoon.Macro.Near:floorItems(player)
	return floorOn(squares(player));
end

-- the first item of a container (its own items, as its button in the loot window shows them: never inside a bag of it)
-- that test accepts
local function firstItem(container, test)
	local items = container:getItems();

	for i = 0, items:size() - 1
	do
		local item = items:get(i);

		if item and test(item)
		then
			return item;
		end
	end

	return nil;
end

-- the keys the line reached already (the character stood next to them since the walk): never walked to again
local function reachedKeys(player, memory)
	local keys = {};

	if memory == nil
	then
		return keys;
	end

	for key, target in pairs(memory.targets)
	do
		if target.reached or Near:inReach(player, target.square)
		then
			target.reached = true;
			keys[key] = true;
		end
	end

	return keys;
end

function AutoPilotMoon.Macro.Near:find(player, test, opts)
	opts = opts or {};

	local memory = opts.memory;
	local skip = reachedKeys(player, memory);
	local spots = squares(player);
	local entries = containersOn(player, spots);
	local unknown = nil;

	for i, entry in ipairs(floorOn(spots))
	do
		table.insert(entries, entry);
	end

	table.sort(entries, nearer);

	for i, entry in ipairs(entries)
	do
		if not skip[entry.key]
		then
			if entry.floor
			then
				if test(entry.item)
				then
					return entry;
				end
			elseif entry.state == "loaded"
			then
				local item = firstItem(entry.container, test);

				if item
				then
					entry.item = item;

					return entry;
				end
			elseif entry.state == "unknown" and entry.kitchen and unknown == nil
			then
				unknown = entry;
			end
		end
	end

	if opts.unknown and unknown and (memory == nil or memory.looks < Near.maxLooks)
	then
		return unknown;
	end

	return nil;
end

-- ============================================================================================================
-- The line: its memory, the walk
-- ============================================================================================================

local function memoryOf(run, op, create)
	local memory = run.approach;

	if memory and memory.op == op and memory.frame == run.frame and memory.actions == run.actions
	then
		return memory;
	end

	if not create
	then
		return nil;
	end

	memory = { op = op, frame = run.frame, actions = run.actions, targets = {}, looks = 0 };
	run.approach = memory;

	return memory;
end

local function current(player)
	local run = AutoPilotMoon.Macro.Run and AutoPilotMoon.Macro.Run.current;

	if run == nil or run.player ~= player or run.ended
	then
		return nil;
	end

	return run;
end

function AutoPilotMoon.Macro.Near:memory(player, op)
	local run = current(player);

	return run and memoryOf(run, op, false) or nil;
end

-- the line the macro starts now (MacroRun.lua's act: the op at the frame's pc, nothing pending): a condition's op or the
-- editor's "Adesso si puo' fare?" (ops of another check) never is
function AutoPilotMoon.Macro.Near:starting(player, op)
	local run = current(player);
	local frame = run and run.frame;

	return frame ~= nil and run.pending == nil and frame.ops ~= nil and frame.ops[frame.pc] == op;
end

-- the walk's pending (contract C3): longer than its time, the engine empties the queue; the step with the character
-- idle then starts the line again (a walk that did not arrive: walked again, the third try stops the line)
local function walkBusy(run, pending, busyMs)
	if busyMs ~= nil and busyMs > pending.timeoutMs
	then
		return "stop";
	end

	return nil;
end

function AutoPilotMoon.Macro.Near:approach(run, op, entry)
	local player = run and run.player;
	local name = entry and entry.name or "";
	local square = entry and entry.square;

	if player == nil or square == nil
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", name);
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceProtected", name);
	end

	local memory = memoryOf(run, op, true);
	local key = entry.key or entry.container or square;
	local target = memory.targets[key];

	if target == nil
	then
		target = { tries = 0, square = square };
		memory.targets[key] = target;
	end

	if target.tries >= Near.maxWalks
	then
		-- walked there twice and still not next to it: a closed door, no way, a walk the game stopped
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", name);
	end

	local walked = false;

	if entry.floor
	then
		walked = luautils.walk(player, square, true);
	else
		walked = luautils.walkAdj(player, square, true);
	end

	if not walked
	then
		-- the game finds no free square next to it
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", name);
	end

	target.tries = target.tries + 1;

	if not entry.floor and entry.item == nil and entry.state == "unknown" and not target.looked
	then
		target.looked = true;
		memory.looks = memory.looks + 1;
	end

	run.pending = { kind = "walk", op = op, frame = run.frame, near = entry, timeoutMs = Near.walkTimeoutMs(entry.distance),
		busy = walkBusy };

	if entry.item
	then
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroGoNear", name, entry.item:getDisplayName());
	else
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroLookNear", name);
	end

	return nil, nil, "wait";
end
