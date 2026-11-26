-- AutoPilot (Moon): automations for the Moon server.

-- Items and places of the macros (waves 2 and 3 of the work skills, 19/11/2026, MACRO-AUTOPILOT.md 14, decided with
-- the proposals of ANALISI-API-MACRO-LAVORATIVE.md 3.3 and 3.4): every move through the game's own actions, as by hand,
-- so the server checks each one (in multiplayer a transfer is a transaction the server accepts or refuses):
--   take("X", from="P", n=N)   the walk next to the place (luautils.walkAdj, as the trips of the jobs), a container
--                              never opened asked for first (ISInventoryPage:checkExplored, as the loot window does),
--                              then one transfer action of the game per item into the main inventory
--                              (ISInventoryTransferUtil.newInventoryTransferAction), only what fits there
--                              (ItemContainer.hasRoomFor, the test of the game's own "Grab")
--   put("X", into="P", n=N)    the walk, then one transfer per item into the first container of the place with room
--                              (Destination:findRoom, the jobs' rule); a place of ground: onto its floor
--   drop("X", n=N)             the inventory's "Drop" (ISInventoryPaneContextMenu.dropItem): onto the floor here
--   equip("X", hand=...)       the inventory's "Equip" (ISInventoryPaneContextMenu.equipWeapon): primary, secondary,
--                              both hands
--   walk_to("P")               the walk next to the place (onto it for a place of ground)
--   walk_to(x, y, z)           (26/11/2026, ANALISI-AUTONOMIA.md 3.3) the walk onto that square: a place of ground of its
--                              own ({ kind = "ground", x, y, z, name = "x, y, z" }), checked as the places are (loaded,
--                              not in a safehouse the character may not use, walkable, within MacroPlaceRadius of
--                              where the macro started); already on it: the line after, nothing counted. Arrived = on
--                              that very square (Carry:isNear), never the game action's own answer (the last node of
--                              the game's path may not be it). Idle elsewhere: MacroR_WalkBlocked with the squares
--                              still missing; walking past Items.walkTimeoutMs: the engine empties the queue
--                              (pending.busy, contract C3) and MacroR_WalkTimeout. The game opens the closed doors on
--                              the way and leaves them open; a locked door makes the walk fail.
-- "made" (put, drop): what this run made, by id (the items that came into the inventory since the start, not by take).
-- Never moved as cargo: a favourite, an equipped or a worn item (equip() may hold a favourite: the player asked for it).
-- Taken from a place: never a favourite, an equipped item, furniture packed as an item, what the container does not
-- let go (Item:isUnloadable, the Unloader's rule). A container locked for the character, a ZomBOT gravestone, a
-- safehouse the character may not use: never (Places:resolve). "Wait for the object" (19/11/2026): a line is done only
-- when every object it moved is seen where it must be (in the inventory, in the target container, off the inventory
-- for the floor, in the hand), never because the action was queued or performed; the next line does not start before.
-- The engine's AutoPilotMoon.Wait (49_AP_Wait.lua, 1.2.1) does the waiting, by id: a refusal of the server is said at
-- once, not all there Wait.timeoutMs after the character is idle again: the macro stops at the line, never a retry. A
-- container never opened is asked for and its answer awaited (never isExplored(), which the game sets at once): "not
-- there" only when the answer came; no answer: the macro stops ("non ho visto niente in Cassa"), a "while possible"
-- does not end well. At most MacroItemsPerRun items moved in a run, then the macro ends well. Switch
-- EnableMacroTransfers, read at every step.
-- put("made") / drop("made") with nothing made: the line after (first in a "while possible": the end).
--
-- Items:start(run, op) -> pending, or nil + reason text + kind: "nothing" (nothing of that kind: a "while possible"
--   ends well), "skip" (nothing to do: already there, already in the hand), "walk" (a walk queued, not an action),
--   "wait" (a container asked for, try again), "limit" (MacroItemsPerRun reached), nil (a refusal: the macro stops)
-- Items:confirm(run, pending) -> "busy" / "done" / "fail", text   (only with the character idle)
-- Items:probe(player, op) -> nil (it can be done now) or the reason's text ("Adesso si puo' fare?")
-- Items:countAt(player, types, place), Items:spaceLeft(player, place): the conditions count(at=) and space_left()

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Items = AutoPilotMoon.Macro.Items or {};

local Items = AutoPilotMoon.Macro.Items;

Items.kinds = { take = true, put = true, drop = true, equip = true, walk_to = true };

-- the longest a walk_to may walk (3.3): 15 s, 2 s more per square in a straight line, at most 2 minutes. The game's
-- own "walking on the spot" check (zombie.ai.WalkingOnTheSpot) restarts whenever the animation does not move, so a
-- walk could stay "in progress" for ever: this is looked at with the character busy (pending.busy, contract C3).
Items.walkTimeoutBaseMs = 15000;
Items.walkTimeoutPerSquareMs = 2000;
Items.walkTimeoutMaxMs = 120000;

function AutoPilotMoon.Macro.Items.walkTimeoutMs(squares)
	return math.min(Items.walkTimeoutMaxMs, Items.walkTimeoutBaseMs + Items.walkTimeoutPerSquareMs * math.max(0, squares or 0));
end

local function Places()
	return AutoPilotMoon.Macro.Places;
end

local function Run()
	return AutoPilotMoon.Macro.Run;
end

local function Wait()
	return AutoPilotMoon.Wait;
end

-- the text of the reason of a stop (or an end: MacroDoneItems), its key remembered for the notifications (the event's
-- code: MacroR_PlaceLocked...)
local function whyText(key, a, b, c, d)
	return AutoPilotMoon.Notify:why(key, a, b, c, d);
end

function AutoPilotMoon.Macro.Items:handles(kind)
	return Items.kinds[kind] == true;
end

function AutoPilotMoon.Macro.Items:isEnabled()
	return Places():isEnabled();
end

function AutoPilotMoon.Macro.Items:cap()
	return AutoPilotMoon.Sandbox:getInteger("MacroItemsPerRun");
end

-- an action that moves items (MacroItemsPerRun): every one but walk_to
function AutoPilotMoon.Macro.Items:movesItems(op)
	return Items.kinds[op.kind] == true and op.kind ~= "walk_to";
end

-- items the run may still move
function AutoPilotMoon.Macro.Items:left(run)
	return Items:cap() - (run.itemsMoved or 0);
end

-- ============================================================================================================
-- Texts
-- ============================================================================================================

-- the item of a line as the player reads it: the game's name of a single type, else as written ("made": "made")
local function itemLabel(op)
	if op.itemTypes and #op.itemTypes == 1
	then
		return AutoPilotMoon.Macro.Names:itemName(op.itemTypes[1]);
	end

	return op.itemText or "";
end

Items.itemLabel = itemLabel;

function AutoPilotMoon.Macro.Items:describe(op)
	if op.kind == "take"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroTake", itemLabel(op), op.placeName or "");
	elseif op.kind == "put"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroPut", itemLabel(op), op.placeName or "");
	elseif op.kind == "drop"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroDrop", itemLabel(op));
	elseif op.kind == "equip"
	then
		return getText("IGUI_AutoPilot_P_Now_MacroEquip", itemLabel(op));
	elseif op.spot
	then
		return getText("IGUI_AutoPilot_P_Now_MacroSpotWalk", op.placeName or "");
	end

	return getText("IGUI_AutoPilot_P_Now_MacroWalkTo", op.placeName or "");
end

-- ============================================================================================================
-- What is moved
-- ============================================================================================================

local function typeSetOf(op)
	if op.typeSet == nil and op.itemTypes
	then
		op.typeSet = {};

		for i, fullType in ipairs(op.itemTypes)
		do
			op.typeSet[fullType] = true;
		end
	end

	return op.typeSet;
end

-- the ids of the character's inventory, bags included (the run's start: what was there before "made")
function AutoPilotMoon.Macro.Items:inventoryIds(player)
	local ids = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return true;
	end);

	for i = 0, items:size() - 1
	do
		ids[items:get(i):getID()] = true;
	end

	return ids;
end

-- an item of the character the macro may move away (put, drop): in its inventory, never a favourite, an equipped or a
-- worn one (Run:isUsable, the rule of every material)
local function isCargo(player, item)
	local container = item:getContainer();

	return container ~= nil and container:isInCharacterInventory(player) and Run():isUsable(player, item);
end

-- the items of the inventory a put / drop line moves: of its types, or what the run made
function AutoPilotMoon.Macro.Items:cargo(run, player, op)
	local set = typeSetOf(op);
	local start = run and run.startIds or nil;
	local taken = run and run.takenIds or nil;
	local found = player:getInventory():getAllEvalRecurse(function(item)
		if op.made
		then
			return start ~= nil and start[item:getID()] == nil and not (taken and taken[item:getID()]) and isCargo(player, item);
		end

		return set ~= nil and set[item:getFullType()] == true and isCargo(player, item);
	end);
	local result = {};

	for i = 0, found:size() - 1
	do
		table.insert(result, found:get(i));
	end

	return result;
end

-- how many at most this line moves now: n= (or all), within what the run may still move
local function wanted(run, op)
	local left = run and Items:left(run) or Items:cap();

	if op.n and op.n < left
	then
		return op.n;
	end

	return left;
end

-- ============================================================================================================
-- Places
-- ============================================================================================================

-- the square of walk_to(x, y, z) as a place of ground of its own (made once per line), else the line's place
local function linePlace(op)
	if op.place == nil and op.spot
	then
		if op.spotPlace == nil
		then
			local spot = op.spot;

			op.spotPlace = { kind = "ground", x = spot.x, y = spot.y, z = spot.z or 0,
				name = op.placeName or (spot.x .. ", " .. spot.y .. ", " .. (spot.z or 0)) };
		end

		return op.spotPlace;
	end

	return op.place;
end

Items.linePlace = linePlace;

-- the place of a line, checked: the place resolved, or nil and why
local function placeOf(player, op, center)
	local place = linePlace(op);

	if place == nil
	then
		return nil, nil, whyText("IGUI_AutoPilot_A_MacroR_NoPlace", op.placeName or "");
	end

	if center and not Places():isInRange(place, center)
	then
		return nil, nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceFar", place.name, Places():distance(place, center), Places():radius());
	end

	local resolved, reasonKey = Places():resolve(place, player);

	if resolved == nil
	then
		return nil, nil, whyText(reasonKey, place.name);
	end

	return place, resolved, nil;
end

local function isNear(player, place, resolved)
	return AutoPilotMoon.Carry:isNear(player, Places():dest(place), resolved);
end

-- the walk to a place, once per line: the game's walk next to it (onto it for the ground); false when the game finds
-- no way (no free square next to it)
local function walkTo(player, place, resolved)
	if place.kind == "ground"
	then
		return luautils.walk(player, resolved.square, true);
	end

	return luautils.walkAdj(player, resolved.square, true);
end

-- next to the place, or a walk queued: nil (there), or the start's answer (nil, why, kind)
local function reach(run, op, place, resolved)
	local player = run.player;

	if isNear(player, place, resolved)
	then
		run.placeWalk = nil;

		return nil;
	end

	if run.placeWalk == op or not walkTo(player, place, resolved)
	then
		-- walked once for this line and still not there, or no way there
		run.placeWalk = nil;

		return true, whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", place.name), nil;
	end

	run.placeWalk = op;
	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroPlaceWalk", place.name);

	return true, nil, "walk";
end

-- What the place's containers hold, arrived from the server (bug of 1.2.0: checkExplored says "explored" at once and
-- the line said "not there" in the same frame): a container never opened is asked for as the loot window does, and
-- its answer awaited with the engine's wait (Wait:loadState). Returns false (wait, the step comes again), or true and
-- uncertain (true: no answer seen, an empty container or a server that did not answer).
local function contentsLoaded(run, op, place, containers)
	local w = run.loadWait;

	if w == nil or w.op ~= op
	then
		w = nil;

		for i, container in ipairs(containers)
		do
			Wait():explore(container, run.player);

			if Wait():loadState(container) ~= "loaded"
			then
				-- a short wait (Wait.loadMinMs at most, unless the answer keeps coming): the panel says it at once
				w = w or Wait():new(run.player, { label = place.name, waitingAfterMs = 0 });
				w:expectLoaded(container);
			end
		end

		if w == nil
		then
			return true, false;
		end

		w.op = op;
		run.loadWait = w;
	end

	local answer, why, info = w:check();

	if answer == "busy"
	then
		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_MacroExplore", place.name);

		return false, false;
	end

	run.loadWait = nil;

	return true, info.uncertain;
end

-- the items of the types a place holds that the character may take (bags inside included, as the loot window shows
-- them): never a favourite, an equipped one, furniture packed as an item, what the container keeps
local function takeable(player, op, containers)
	local set = typeSetOf(op);
	local result = {};

	for i, container in ipairs(containers)
	do
		local found = container:getAllEvalRecurse(function(item)
			local from = item:getContainer();

			return set[item:getFullType()] == true and from ~= nil and AutoPilotMoon.Item:isUnloadable(item, from) and not item:isWorn();
		end);

		for j = 0, found:size() - 1
		do
			table.insert(result, found:get(j));
		end
	end

	return result;
end

-- ============================================================================================================
-- take / put / drop / equip / walk_to
-- ============================================================================================================

-- the items that fit in the main inventory, at most max (ItemContainer.hasRoomFor with the weight already planned)
local function fittingInInventory(player, list, max)
	local inventory = player:getInventory();
	local planned = 0;
	local result = {};

	for i, item in ipairs(list)
	do
		if #result >= max
		then
			break;
		end

		local weight = item:getUnequippedWeight();

		if inventory:hasRoomFor(player, planned + weight)
		then
			planned = planned + weight;
			table.insert(result, item);
		end
	end

	return result;
end

local function startTake(run, op)
	local player = run.player;
	local place, resolved, why = placeOf(player, op, run.center);

	if place == nil
	then
		return nil, why, nil;
	end

	if place.kind == "ground"
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceGround", place.name), nil;
	end

	local moving, walkWhy, walkKind = reach(run, op, place, resolved);

	if moving
	then
		return nil, walkWhy, walkKind;
	end

	local loaded, uncertain = contentsLoaded(run, op, place, resolved.containers);

	if not loaded
	then
		return nil, nil, "wait";
	end

	local list = takeable(player, op, resolved.containers);

	if #list == 0
	then
		if uncertain
		then
			-- no answer from the server: never "not there" (a "while possible" would end as if done)
			return nil, whyText("IGUI_AutoPilot_A_MacroR_NotSeenAt", place.name), nil;
		end

		return nil, whyText("IGUI_AutoPilot_A_MacroR_NothingAt", place.name, itemLabel(op)), "nothing";
	end

	local chosen = fittingInInventory(player, list, wanted(run, op));

	if #chosen == 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_TooHeavy", itemLabel(op)), nil;
	end

	local inventory = player:getInventory();
	local entries = {};
	local wait = Wait():new(player, { label = getText("IGUI_AutoPilot_W_InInventory", itemLabel(op)) });

	for i, item in ipairs(chosen)
	do
		table.insert(entries, { id = item:getID(), source = item:getContainer() });
	end

	for i, item in ipairs(chosen)
	do
		local action = ISInventoryTransferUtil.newInventoryTransferAction(player, item, entries[i].source, inventory);

		ISTimedActionQueue.add(action);
		wait:watch(action);
		wait:expectIn(item, "inventory");
	end

	return { kind = "take", module = "items", entries = entries, place = place, wait = wait };
end

local function startPut(run, op)
	local player = run.player;
	local place, resolved, why = placeOf(player, op, run.center);

	if place == nil
	then
		return nil, why, nil;
	end

	local list = Items:cargo(run, player, op);

	if #list == 0
	then
		if op.made
		then
			-- nothing made (yet): nothing to put away, the line after; first in "while possible": the end
			return nil, whyText("IGUI_AutoPilot_A_MacroR_NothingMade"), op.possibleFirst and "nothing" or "skip";
		end

		return nil, whyText("IGUI_AutoPilot_A_MacroR_NothingToPut", itemLabel(op)), "nothing";
	end

	local moving, walkWhy, walkKind = reach(run, op, place, resolved);

	if moving
	then
		return nil, walkWhy, walkKind;
	end

	local max = wanted(run, op);
	local entries = {};
	local planned = {};
	local floor = nil;
	local floorRoom = 0;
	local wait = nil;

	if place.kind == "ground"
	then
		floor = ISInventoryPage.GetFloorContainer(player:getPlayerNum());
		floorRoom = floor and AutoPilotMoon.Item:getFloorRoom(player:getSquare(), player) or 0;
		wait = Wait():new(player, { label = getText("IGUI_AutoPilot_W_OnFloor", itemLabel(op)) });
	else
		wait = Wait():new(player, { label = getText("IGUI_AutoPilot_W_InPlace", itemLabel(op), place.name) });
	end

	for i, item in ipairs(list)
	do
		if #entries >= max
		then
			break;
		end

		local target = nil;

		if floor
		then
			local weight = item:getUnequippedWeight();

			if floorRoom >= weight
			then
				floorRoom = floorRoom - weight;
				target = floor;
			end
		else
			target = AutoPilotMoon.Destination:findRoom(resolved, player, item, planned);
		end

		if target
		then
			local action = ISInventoryTransferUtil.newInventoryTransferAction(player, item, item:getContainer(), target);

			ISTimedActionQueue.add(action);
			wait:watch(action);

			if target == floor
			then
				-- on the floor: what the client can tell is that it left (the game lays it on the 3x3)
				wait:expectOut(item, "inventory");
			else
				wait:expectIn(item, target);
			end

			table.insert(entries, { id = item:getID(), target = target, floor = target == floor });
		end
	end

	if #entries == 0
	then
		return nil, whyText(floor and "IGUI_AutoPilot_A_MacroR_FloorFull" or "IGUI_AutoPilot_A_MacroR_PlaceFull", place.name), nil;
	end

	return { kind = "put", module = "items", entries = entries, place = place, wait = wait };
end

local function startDrop(run, op)
	local player = run.player;
	local list = Items:cargo(run, player, op);

	if #list == 0
	then
		if op.made
		then
			-- nothing made (yet): nothing to put away, the line after; first in "while possible": the end
			return nil, whyText("IGUI_AutoPilot_A_MacroR_NothingMade"), op.possibleFirst and "nothing" or "skip";
		end

		return nil, whyText("IGUI_AutoPilot_A_MacroR_NothingToPut", itemLabel(op)), "nothing";
	end

	if AutoPilotMoon.Zones:isProtected(player:getSquare(), player)
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_DropProtected"), nil;
	end

	local room = AutoPilotMoon.Item:getFloorRoom(player:getSquare(), player);
	local chosen = AutoPilotMoon.Item:takeFitting(list, wanted(run, op), room);

	if #chosen == 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_FloorFullHere"), nil;
	end

	local entries = {};
	local wait = Wait():new(player, { label = getText("IGUI_AutoPilot_W_OnFloor", itemLabel(op)) });
	local mark = Wait():mark(player);

	for i, item in ipairs(chosen)
	do
		ISInventoryPaneContextMenu.dropItem(item, player:getPlayerNum());
		wait:expectOut(item, "inventory");
		table.insert(entries, { id = item:getID(), floor = true });
	end

	wait:watchQueued(mark);

	return { kind = "drop", module = "items", entries = entries, wait = wait };
end

-- the hand of an equip line: as written, else both hands for an item that needs them (the game's two-handed weapons)
local function handOf(op, item)
	if op.hand
	then
		return op.hand;
	end

	if item and (item:isRequiresEquippedBothHands() or item:isTwoHandWeapon())
	then
		return "both";
	end

	return "primary";
end

local function inHand(player, hand, test)
	local primary = player:getPrimaryHandItem();
	local secondary = player:getSecondaryHandItem();

	if hand == "secondary"
	then
		return secondary ~= nil and test(secondary);
	elseif hand == "both"
	then
		-- the same item in the two hands (by id: two references of the game's object may not compare equal)
		return primary ~= nil and secondary ~= nil and primary:getID() == secondary:getID() and test(primary);
	end

	return primary ~= nil and test(primary);
end

-- the item an equip line takes in hand: of its types, in the inventory (bags too), never broken nor worn; a favourite
-- may be (the player asked for it)
function AutoPilotMoon.Macro.Items:chooseEquip(player, op)
	local set = typeSetOf(op);

	return player:getInventory():getFirstEvalRecurse(function(item)
		return set[item:getFullType()] == true and not item:isBroken() and not item:isWorn();
	end);
end

local function startEquip(run, op)
	local player = run.player;
	local set = typeSetOf(op);
	local hand = op.hand or "primary";

	if inHand(player, hand, function(held) return set[held:getFullType()] == true end)
	then
		return nil, nil, "skip";
	end

	local item = Items:chooseEquip(player, op);

	if item == nil
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_NoEquip", itemLabel(op)), "nothing";
	end

	hand = handOf(op, item);

	local wait = Wait():new(player, { label = getText("IGUI_AutoPilot_W_InHand", itemLabel(op)) });
	local mark = Wait():mark(player);

	ISInventoryPaneContextMenu.equipWeapon(item, hand == "primary", hand == "both", player:getPlayerNum());
	-- by id: in multiplayer an item taken from a bag arrives in the hand as another object (the two hands: the same id)
	wait:expectInHand(item, hand);
	wait:watchQueued(mark);

	return { kind = "equip", module = "items", entries = { { id = item:getID() } }, hand = hand, wait = wait };
end

-- squares in a straight line between the character and a place (the walk's longest time, the text of a walk that
-- stopped short), at least 1
local function squaresLeft(player, place)
	local dx = place.x + 0.5 - player:getX();
	local dy = place.y + 0.5 - player:getY();

	return math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) + 0.5));
end

-- With the character busy walking (contract C3, ANALISI-AUTONOMIA.md 3.8.2): past the walk's longest time, "stop":
-- the engine empties the queue and the step, with the character idle again, says why (Items:confirm)
local function walkBusy(run, pending, busyMs)
	if busyMs ~= nil and busyMs >= pending.timeoutMs
	then
		pending.timedOutSeconds = math.floor(busyMs / 1000);

		return "stop";
	end

	return nil;
end

-- walk_to("P") and walk_to(x, y, z): one walk per line (the game's walk next to the place, onto a square), never an
-- action of its own when already there
local function startWalk(run, op)
	local player = run.player;
	local place, resolved, why = placeOf(player, op, run.center);

	if place == nil
	then
		return nil, why, nil;
	end

	if isNear(player, place, resolved)
	then
		return nil, nil, "skip";
	end

	if not walkTo(player, place, resolved)
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", place.name), nil;
	end

	return { kind = "walkto", module = "items", place = place, spot = op.place == nil and op.spot ~= nil,
		timeoutMs = Items.walkTimeoutMs(squaresLeft(player, place)), busy = walkBusy };
end

local starts = { take = startTake, put = startPut, drop = startDrop, equip = startEquip, walk_to = startWalk };

function AutoPilotMoon.Macro.Items:start(run, op)
	if not Items:isEnabled()
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroR_TransfersOff"), nil;
	end

	if Items:movesItems(op) and Items:left(run) <= 0
	then
		return nil, whyText("IGUI_AutoPilot_A_MacroDoneItems", Items:cap()), "limit";
	end

	local pending, why, kind = starts[op.kind](run, op);

	if pending
	then
		pending.op = op;
		pending.label = itemLabel(op);
	end

	return pending, why, kind;
end

-- ============================================================================================================
-- Confirmation: only what arrived counts
-- ============================================================================================================

-- "Wait for the object" (owner's test of 19/11/2026): a line is done only when EVERY object it moved is where it must
-- be, by id (in multiplayer the object the client holds after the server's answer is another one with the same id):
--   take   in the character's inventory (bags included)
--   put    in the container it was sent to; a place of ground and drop: no longer in the character's inventory (the
--          item on the floor is another object of the game, on one of the 3x3 squares: what the client can tell is
--          that it left)
--   equip  in the hand asked for (the two hands: the same id)
-- Never because the game's action was queued or performed: the engine's wait (AutoPilotMoon.Wait) looks at the game's
-- state with the character idle (the next line never starts before), "aspetta il server: Carbone nello zaino (2 su
-- 3)" after Wait.waitingAfterMs; a refusal of the server said at once; not all there after Wait.timeoutMs: the macro
-- stops at the line and says how many arrived.
function AutoPilotMoon.Macro.Items:confirm(run, pending)
	local player = run.player;

	if pending.kind == "walkto"
	then
		local place = pending.place;
		local arrived = false;

		if pending.spot
		then
			-- walk_to(x, y, z): on that very square (a place of ground: its coordinates only)
			arrived = AutoPilotMoon.Carry:isNear(player, Places():dest(place), nil);
		else
			local resolved = Places():resolve(place, player);

			arrived = resolved ~= nil and isNear(player, place, resolved);
		end

		if arrived
		then
			return "done";
		end

		if pending.timedOutSeconds
		then
			return "fail", whyText("IGUI_AutoPilot_A_MacroR_WalkTimeout", place.name, pending.timedOutSeconds);
		end

		if pending.spot
		then
			-- idle somewhere else: no way there (a locked door, nothing walkable), said with what was missing
			return "fail", whyText("IGUI_AutoPilot_A_MacroR_WalkBlocked", place.name, squaresLeft(player, place));
		end

		return "fail", whyText("IGUI_AutoPilot_A_MacroR_PlaceUnreachable", place.name);
	end

	local wait = pending.wait;
	local answer, why, info = wait:check();

	if answer == "busy"
	then
		return "busy";
	end

	-- what arrived is counted, also when the line fails (it did move)
	local count = info.arrived;
	local total = info.total;

	if count > 0
	then
		run.itemsMoved = (run.itemsMoved or 0) + count;
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_MacroItems", count);

		if pending.kind == "take"
		then
			run.takenIds = run.takenIds or {};

			for id in pairs(info.ids)
			do
				run.takenIds[id] = true;
			end
		end
	end

	if answer == "done"
	then
		return "done";
	end

	local label = pending.label or "";
	local seconds = wait:seconds();

	if why == "notqueued"
	then
		return "fail", whyText("IGUI_AutoPilot_A_MacroR_WaitNotQueued", label);
	elseif info.refused
	then
		if count == 0
		then
			return "fail", whyText("IGUI_AutoPilot_A_MacroR_NotAccepted", label);
		end

		return "fail", whyText("IGUI_AutoPilot_A_MacroR_PartlyRefused", label, count, total);
	elseif pending.kind == "equip"
	then
		return "fail", whyText("IGUI_AutoPilot_A_MacroR_NotEquipped", label, seconds);
	elseif count == 0
	then
		return "fail", whyText("IGUI_AutoPilot_A_MacroR_NotMoved", label, seconds);
	end

	return "fail", whyText("IGUI_AutoPilot_A_MacroR_PartlyMoved", label, count, total, seconds);
end

-- ============================================================================================================
-- "Adesso si puo' fare?" (nothing queued, no walk)
-- ============================================================================================================

function AutoPilotMoon.Macro.Items:probe(player, op)
	if not Items:isEnabled()
	then
		return getText("IGUI_AutoPilot_A_MacroR_TransfersOff");
	end

	local center = Run():center(player);

	if op.kind == "drop"
	then
		return #Items:cargo(nil, player, op) == 0 and not op.made and getText("IGUI_AutoPilot_A_MacroR_NothingToPut", itemLabel(op)) or nil;
	elseif op.kind == "equip"
	then
		return Items:chooseEquip(player, op) == nil and getText("IGUI_AutoPilot_A_MacroR_NoEquip", itemLabel(op)) or nil;
	end

	local place, resolved, why = placeOf(player, op, center);

	if place == nil
	then
		return why;
	end

	if op.kind == "take"
	then
		if place.kind == "ground"
		then
			return getText("IGUI_AutoPilot_A_MacroR_PlaceGround", place.name);
		end

		local list = takeable(player, op, resolved.containers);

		if #list == 0
		then
			return getText("IGUI_AutoPilot_A_MacroR_NothingAt", place.name, itemLabel(op));
		end

		if #fittingInInventory(player, list, 1) == 0
		then
			return getText("IGUI_AutoPilot_A_MacroR_TooHeavy", itemLabel(op));
		end
	elseif op.kind == "put" and not op.made and #Items:cargo(nil, player, op) == 0
	then
		return getText("IGUI_AutoPilot_A_MacroR_NothingToPut", itemLabel(op));
	end

	return nil;
end

-- ============================================================================================================
-- The conditions count("X", at="P") and space_left() / space_left(at="P")
-- ============================================================================================================

-- how many of the types the place holds (0 when it cannot be read: unmarked, too far to be loaded, locked); a
-- container never opened is asked for, as the loot window does
function AutoPilotMoon.Macro.Items:countAt(player, types, place)
	if place == nil
	then
		return 0;
	end

	local resolved = Places():resolve(place, player);

	if resolved == nil
	then
		return 0;
	end

	local count = 0;

	if place.kind == "ground"
	then
		local set = {};

		for i, fullType in ipairs(types)
		do
			set[fullType] = true;
		end

		local objects = resolved.square:getWorldObjects();

		for i = 0, objects:size() - 1
		do
			local item = objects:get(i):getItem();

			if item and set[item:getFullType()]
			then
				count = count + 1;
			end
		end

		return count;
	end

	for i, container in ipairs(resolved.containers)
	do
		Wait():explore(container, player);

		for j, fullType in ipairs(types)
		do
			count = count + container:getCountTypeRecurse(fullType);
		end
	end

	return count;
end

local function round1(value)
	return math.floor(value * 10 + 0.5) / 10;
end

-- the weight the character can still carry before the heavy load (getMaxWeight - the inventory's weight), or the room
-- left in the place's containers (on its floor for a place of ground); never below 0
function AutoPilotMoon.Macro.Items:spaceLeft(player, place)
	local room = 0;

	if place == nil
	then
		room = player:getMaxWeight() - player:getInventoryWeight();
	else
		local resolved = Places():resolve(place, player);

		if resolved == nil
		then
			return 0;
		end

		if place.kind == "ground"
		then
			room = AutoPilotMoon.Destination:getFloorCapacity(player) - resolved.square:getTotalWeightOfItemsOnFloor();
		else
			for i, container in ipairs(resolved.containers)
			do
				room = room + math.max(0, container:getEffectiveCapacity(player) - container:getCapacityWeight());
			end
		end
	end

	return math.max(0, round1(room));
end
