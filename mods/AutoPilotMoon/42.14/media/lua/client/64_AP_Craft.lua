-- AutoPilot (Moon): automations for the Moon server.

-- Running one of the game's recipes on one item (11/11/2026, phase B): the Sawyer (SawLogs) and the Woodcutter
-- (ChopLog, ChopLargeBranch). Exactly the way the game does it when the player right-clicks the item in the inventory
-- and chooses the recipe: ISInventoryPaneContextMenu.OnNewCraft of 42.22 (HandcraftLogic with the containers the
-- player can reach, a work surface within 2 squares for the "any surface" recipes, ISEntityUI.HandcraftStart, the
-- ISHandcraftAction the server performs: it consumes the input and creates the outputs, into the inventory or at the
-- player's feet as by hand). Nothing of the recipe is ours: inputs, tools, surface, time, experience, darkness.
--
-- Craft:check says beforehand whether the game would start it and, when not, why (the game's own reasons): "dark"
-- (ISHandcraftAction stops at once when the recipe is not CanBeDoneInDark and tooDarkToRead), "surface" (an any-surface
-- recipe without a work surface near the character), "refused" (anything else the recipe asks: a tool, a skill...).
-- Only confirmed results count (spec 7.4.1): the input gone (from the inventory, or from the ground), the outputs that
-- appeared.
--
-- An item lying on the ground (12/11/2026, owner's test: the Sawyer used to pick the log up first): the game's own way
-- by hand is the loot window. Next to the log, its "floor" lists the world items of the 3x3 squares around the
-- character that it can reach (ISInventoryPage:refreshBackpacks, rebuilt when the character changes square or
-- direction); a right click on the log there and "Sega tronco" call the same OnNewCraft with the world item's
-- InventoryItem. The containers of the logic are ISInventoryPaneContextMenu.getContainers (the inventory and the
-- loot window's containers, the floor among them). A recipe tagged CanBeDoneFromFloor (SawLogs, ChopLog in 42.22) moves
-- nothing: the ISHandcraftAction consumes the log where it lies and the outputs go into the inventory
-- (Actions.addOrDropItem: at the character's feet when they do not fit); any other recipe has its inputs moved into the
-- inventory first by OnNewCraft itself (transferIfNeeded), the tools put back after (ReturnItemsToOriginalContainer).
-- Craft:getContainers refreshes the loot window first when the item is on the ground and the floor does not list it
-- yet (the window refreshes itself on its next update: the job may decide before it).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Craft = AutoPilotMoon.Craft or {};

local Craft = AutoPilotMoon.Craft;

Craft.confirmGraceMs = 1500;   -- the action ended and the input is still there: the server may still answer
Craft.surfaceRange = 2;        -- squares around the character where the game looks for a work surface (OnNewCraft)

-- the game's recipe by name ("SawLogs"), nil when this version of the game does not have it
function AutoPilotMoon.Craft:getRecipe(name)
	local manager = getScriptManager();

	return manager and manager:getCraftRecipe(name) or nil;
end

-- the recipe's name as the game shows it ("Sega tronco")
function AutoPilotMoon.Craft:getRecipeName(recipe)
	return getText(recipe:getTranslationName());
end

-- the item is in one of the containers (a Java list)
local function listed(containers, item)
	if containers == nil
	then
		return false;
	end

	for i = 0, containers:size() - 1
	do
		local container = containers:get(i);

		if container and container:contains(item)
		then
			return true;
		end
	end

	return false;
end

-- the item lies on the ground (an IsoWorldInventoryObject holds it)
function AutoPilotMoon.Craft:isOnGround(item)
	return item ~= nil and item:getWorldItem() ~= nil;
end

-- The containers of the right click (ISInventoryPaneContextMenu.getContainers): for an item on the ground, the loot
-- window is refreshed first when its floor does not list the item yet (the character just arrived next to it).
function AutoPilotMoon.Craft:getContainers(player, item)
	local containers = ISInventoryPaneContextMenu.getContainers(player);

	if Craft:isOnGround(item) and not listed(containers, item)
	then
		local loot = getPlayerLoot(player:getPlayerNum());

		if loot
		then
			loot:refreshBackpacks();
			containers = ISInventoryPaneContextMenu.getContainers(player);
		end
	end

	return containers;
end

-- The item is among what the right click reaches now. An item on the ground: on one of the 3x3 squares around the
-- character that it can reach (the rule of the loot window's floor, ISInventoryPage:refreshBackpacks: also when the
-- window has not caught up with a step yet), and listed by the floor.
function AutoPilotMoon.Craft:canReach(player, item)
	local worldItem = item:getWorldItem();

	if worldItem
	then
		local square = worldItem:getSquare();
		local here = player:getCurrentSquare();

		if square == nil or here == nil or square:getZ() ~= here:getZ()
			or math.abs(square:getX() - here:getX()) > 1 or math.abs(square:getY() - here:getY()) > 1
			or (square ~= here and not here:canReachTo(square))
		then
			return false;
		end
	end

	return listed(Craft:getContainers(player, item), item);
end

-- the logic the game builds for a recipe chosen on an item (ISInventoryPaneContextMenu.OnNewCraft)
function AutoPilotMoon.Craft:newLogic(player, recipe, item)
	local logic = HandcraftLogic.new(player, nil, nil);

	logic:setIsoObject(logic:findCraftSurface(player, Craft.surfaceRange));
	logic:setContainers(Craft:getContainers(player, item));
	logic:setRecipeFromContextClick(recipe, item);

	return logic;
end

-- nil when the game would start the recipe on the item now, else "dark", "surface" or "refused"
function AutoPilotMoon.Craft:check(player, recipe, item)
	if not recipe:canBeDoneInDark() and player:tooDarkToRead()
	then
		return "dark";
	end

	local logic = Craft:newLogic(player, recipe, item);

	if logic:canPerformCurrentRecipe()
	then
		return nil;
	end

	if recipe:isAnySurfaceCraft() and logic:getIsoObject() == nil
	then
		return "surface";
	end

	return "refused";
end

-- a work surface (a table, a counter...: IsoObject.isGenericCraftingSurface) within range squares of the square: the
-- object, or nil
function AutoPilotMoon.Craft:findSurfaceNear(square, range)
	local cell = getCell();

	if square == nil or cell == nil
	then
		return nil;
	end

	range = range or Craft.surfaceRange;

	for x = square:getX() - range, square:getX() + range
	do
		for y = square:getY() - range, square:getY() + range
		do
			local near = cell:getGridSquare(x, y, square:getZ());
			local objects = near and near:getObjects();

			if objects
			then
				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);

					if object and object:isGenericCraftingSurface()
					then
						return object;
					end
				end
			end
		end
	end

	return nil;
end

function AutoPilotMoon.Craft:hasSurfaceNear(square, range)
	return Craft:findSurfaceNear(square, range) ~= nil;
end

-- the ids of the items of these full types in the inventory (bags included)
local function snapshot(player, outputTypes)
	local ids = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return outputTypes[item:getFullType()] == true;
	end);

	for i = 0, items:size() - 1
	do
		ids[items:get(i):getID()] = true;
	end

	return ids;
end

-- The recipe on the item the game's way (OnNewCraft: the walk to a surface, the transfers of the materials, the
-- ISHandcraftAction), for the macros: the ISHandcraftAction the game queued, or nil when it queued none.
function AutoPilotMoon.Craft:queueAction(player, recipe, item)
	local queue = ISTimedActionQueue.getTimedActionQueue(player);
	local count = #queue.queue;

	ISInventoryPaneContextMenu.OnNewCraft(item, recipe, player:getPlayerNum(), false);

	local actions = ISTimedActionQueue.getTimedActionQueue(player).queue;

	for i = count + 1, #actions
	do
		if actions[i].Type == "ISHandcraftAction"
		then
			return actions[i];
		end
	end

	return nil;
end

-- Starts the recipe on the item the game's way (the walk to a work surface included; an item on the ground: from where
-- it lies, the loot window refreshed first when needed). outputTypes: set of full types the recipe makes
-- ({ ["Base.Plank"] = true }), to find them afterwards. Returns the pending craft, or nil when the game queued nothing.
function AutoPilotMoon.Craft:start(player, recipe, item, outputTypes)
	local before = snapshot(player, outputTypes);
	local queue = ISTimedActionQueue.getTimedActionQueue(player);
	local count = #queue.queue;
	local ground = nil;
	local worldItem = item:getWorldItem();
	local square = worldItem and worldItem:getSquare();

	if square
	then
		ground = { x = square:getX(), y = square:getY(), z = square:getZ() };
	end

	Craft:getContainers(player, item);
	ISInventoryPaneContextMenu.OnNewCraft(item, recipe, player:getPlayerNum(), false);

	if #ISTimedActionQueue.getTimedActionQueue(player).queue == count
	then
		return nil;
	end

	return {
		itemId = item:getID(),
		recipe = recipe,
		outputTypes = outputTypes,
		before = before,
		ground = ground,
		idleSince = nil,
	};
end

-- the item with this id still lies on the square (x, y, z)
local function isOnSquare(ground, id)
	local cell = getCell();
	local square = cell and cell:getGridSquare(ground.x, ground.y, ground.z);
	local objects = square and square:getWorldObjects();

	if objects == nil
	then
		return false;
	end

	for i = 0, objects:size() - 1
	do
		local item = objects:get(i) and objects:get(i):getItem();

		if item and item:getID() == id
		then
			return true;
		end
	end

	return false;
end

-- Once the character is idle again: "busy" while waiting for the server, else "done", consumed (the input is gone: from
-- the inventory and, for an item that lay on the ground, from its square) and the list of the outputs that appeared in
-- the inventory.
function AutoPilotMoon.Craft:confirm(pending, player)
	local now = getTimestampMs();
	local consumed = player:getInventory():getItemWithIDRecursiv(pending.itemId) == nil
		and not (pending.ground and isOnSquare(pending.ground, pending.itemId));

	if pending.idleSince == nil
	then
		pending.idleSince = now;
	end

	if not consumed and now - pending.idleSince < Craft.confirmGraceMs
	then
		AutoPilotMoon.Progress:setWaiting(true);

		return "busy";
	end

	AutoPilotMoon.Progress:setWaiting(false);

	local outputs = {};
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return pending.outputTypes[item:getFullType()] == true and not pending.before[item:getID()];
	end);

	for i = 0, items:size() - 1
	do
		table.insert(outputs, items:get(i));
	end

	return "done", consumed, outputs;
end
