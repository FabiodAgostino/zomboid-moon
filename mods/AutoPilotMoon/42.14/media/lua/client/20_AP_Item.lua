-- AutoPilot (Moon): automations for the Moon server.

-- Items: tools, water, soil bags, and taking things out of the world's containers. Nothing here moves an item by
-- itself: every move is a timed action of the game, which the server checks (D1).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Item = AutoPilotMoon.Item or {};

-- floor weight per square when the game's floor container cannot tell (ISInventoryTransferAction:floorHasRoomFor)
AutoPilotMoon.Item.floorCapacity = 50;

-- the full soil bags the Soil bagger puts away (B13: clay too)
AutoPilotMoon.Item.soilBagTypes = { "Base.Dirtbag", "Base.Sandbag", "Base.Gravelbag", "Base.Claybag" };

-- tools

function AutoPilotMoon.Item.filterFnAxe(item)
	return not item:isBroken() and item:hasTag(ItemTag.CHOP_TREE);
end

function AutoPilotMoon.Item:findNonBrokenInInventoryByTag(player, tag)
	return player:getInventory():getFirstEvalRecurse(function(item)
		return not item:isBroken() and item:hasTag(tag);
	end);
end

function AutoPilotMoon.Item:getPlantCuttingTool(player)
	return AutoPilotMoon.Item:findNonBrokenInInventoryByTag(player, ItemTag.CUT_PLANT);
end

function AutoPilotMoon.Item:getShovel(player)
	return AutoPilotMoon.Item:findNonBrokenInInventoryByTag(player, ItemTag.TAKE_DIRT);
end

-- a saw for the game's SawLogs recipe (tag base:saw, as the recipe asks), not broken; bags included
function AutoPilotMoon.Item:getSaw(player)
	return AutoPilotMoon.Item:findNonBrokenInInventoryByTag(player, ItemTag.SAW);
end

function AutoPilotMoon.Item:getBestWoodChoppingAxe(player)
	local axes = player:getInventory():getAllEvalRecurse(AutoPilotMoon.Item.filterFnAxe);
	local axe = nil;

	for i = 0, axes:size() - 1
	do
		if not axe or axe:getTreeDamage() < axes:get(i):getTreeDamage()
		then
			axe = axes:get(i);
		end
	end

	return axe;
end

-- water (N-A6): what the player holds when it has water, else a watering can; never a bottle from the bags

function AutoPilotMoon.Item:isWateringCan(item)
	return item ~= nil and (item:getPourType() == "wateringcan" or item:getFullType() == "Base.WateredCan");
end

function AutoPilotMoon.Item:getWaterUses(item)
	if item == nil
	then
		return 0;
	end

	return math.floor(ISFarmingMenu.getWaterUsesInteger(item) or 0);
end

function AutoPilotMoon.Item:getWateringItem(player)
	local hand = player:getPrimaryHandItem();

	if hand and AutoPilotMoon.Item:getWaterUses(hand) > 0
	then
		return hand;
	end

	return player:getInventory():getFirstEvalRecurse(function(item)
		return AutoPilotMoon.Item:isWateringCan(item) and AutoPilotMoon.Item:getWaterUses(item) > 0;
	end);
end

-- soil bags (B13, N-A16): the game's own choice, ISShovelGroundCursor.GetEmptyItem (every HOLD_DIRT bag, clay too)

function AutoPilotMoon.Item:getBagForSoil(player, soilType)
	return ISShovelGroundCursor.GetEmptyItem(player, soilType);
end

-- a bag that cannot take another shovelful
function AutoPilotMoon.Item:isFullSoilBag(item)
	return item:getCurrentUsesFloat() + item:getUseDelta() > 1;
end

-- the full soil bags lying in the main inventory (not in hands), which the Soil bagger puts in a worn bag
function AutoPilotMoon.Item:getFullSoilBags(player)
	local result = {};
	local inventory = player:getInventory();

	for i, fullType in ipairs(AutoPilotMoon.Item.soilBagTypes)
	do
		local bags = inventory:getItemsFromFullType(fullType);

		for j = 0, bags:size() - 1
		do
			local bag = bags:get(j);

			if bag:getContainer() == inventory and not player:isEquipped(bag) and AutoPilotMoon.Item:isFullSoilBag(bag)
			then
				table.insert(result, bag);
			end
		end
	end

	return result;
end

-- a worn or held bag with room for the item (its inventory), or nil
function AutoPilotMoon.Item:getEquippedBagWithRoom(player, item)
	local bags = player:getInventory():getItemsFromCategory("Container");

	for i = 0, bags:size() - 1
	do
		local bag = bags:get(i);

		if bag ~= item and bag:isEquipped()
		then
			local inventory = bag:getInventory();

			if inventory and inventory:hasRoomFor(player, item)
			then
				return inventory;
			end
		end
	end

	return nil;
end

-- D1: the full bags go into a worn bag with a transfer action of the game (the server checks it), never by hand;
-- returns how many transfers were queued
function AutoPilotMoon.Item:stashFullSoilBags(player)
	local queued = 0;

	for i, bag in ipairs(AutoPilotMoon.Item:getFullSoilBags(player))
	do
		local destination = AutoPilotMoon.Item:getEquippedBagWithRoom(player, bag);

		if destination
		then
			ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, bag, bag:getContainer(), destination));
			queued = queued + 1;
		end
	end

	return queued;
end

-- the world's containers

function AutoPilotMoon.Item:getAllObjectContainers(object)
	local containers = {};

	for i = 0, object:getContainerCount() - 1
	do
		local container = object:getContainerByIndex(i);

		if container
		then
			table.insert(containers, container);
		end
	end

	return containers;
end

-- locked for this character (N-A3): the container itself, or a locked crate of the player's kind (IsoThumpable)
function AutoPilotMoon.Item:isLockedFor(object, container, player)
	if container:isLockedToCharacter(player)
	then
		return true;
	end

	return instanceof(object, "IsoThumpable") and object:isLockedToCharacter(player);
end

-- the containers of an object the player may take things out of: none of a protected object (a ZomBOT gravestone),
-- nothing locked for the player
function AutoPilotMoon.Item:getUnloadableContainers(object, player)
	local result = {};

	if AutoPilotMoon.Zones:isProtectedObject(object)
	then
		return result;
	end

	for i, container in ipairs(AutoPilotMoon.Item:getAllObjectContainers(object))
	do
		if not AutoPilotMoon.Item:isLockedFor(object, container, player)
		then
			table.insert(result, container);
		end
	end

	return result;
end

-- an item that may leave its container (N-S10): never a favourite, never equipped or worn, never a piece of furniture
-- packed as an item (it stays inside), only what the container lets go. Keys are ordinary loot in a world container
-- and go out like the rest.
function AutoPilotMoon.Item:isUnloadable(item, container)
	if item == nil or item:isFavorite() or item:isEquipped()
	then
		return false;
	end

	if instanceof(item, "Moveable")
	then
		return false;
	end

	return container:isRemoveItemAllowed(item);
end

-- the items to take out, and how many stay because they may not leave
function AutoPilotMoon.Item:getUnloadableItems(container)
	local result = {};
	local kept = 0;
	local items = container:getItems();

	for i = 0, items:size() - 1
	do
		local item = items:get(i);

		if AutoPilotMoon.Item:isUnloadable(item, container)
		then
			table.insert(result, item);
		else
			kept = kept + 1;
		end
	end

	return result, kept;
end

function AutoPilotMoon.Item:getTotalWeight(items)
	local total = 0;

	for i, item in ipairs(items)
	do
		total = total + item:getUnequippedWeight();
	end

	return total;
end

-- room left on the floor around a square: the 3x3 where the game puts what is dropped next to it
-- (ISInventoryTransferAction:getNotFullFloorSquare), each square up to the floor's capacity
function AutoPilotMoon.Item:getFloorRoom(square, player)
	local cell = getCell();

	if square == nil or cell == nil
	then
		return 0;
	end

	local capacity = AutoPilotMoon.Item.floorCapacity;
	local floor = player and ISInventoryPage.GetFloorContainer(player:getPlayerNum());

	if floor
	then
		capacity = floor:getEffectiveCapacity(player);
	end

	local room = 0;

	for dx = -1, 1
	do
		for dy = -1, 1
		do
			local other = cell:getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ());

			if other and other:TreatAsSolidFloor() and not other:isSolid() and not other:isSolidTrans()
			then
				local free = capacity - other:getTotalWeightOfItemsOnFloor();

				if free > 0
				then
					room = room + free;
				end
			end
		end
	end

	return room;
end

-- the first items that fit in max items and in the given weight
function AutoPilotMoon.Item:takeFitting(items, max, room)
	local result = {};
	local weight = 0;

	for i, item in ipairs(items)
	do
		if #result >= max
		then
			break;
		end

		local itemWeight = item:getUnequippedWeight();

		if weight + itemWeight > room
		then
			break;
		end

		weight = weight + itemWeight;
		table.insert(result, item);
	end

	return result;
end

-- one transfer action of the game per item, from the container to the floor where the player stands (as the
-- game's own "drop", ISInventoryPaneContextMenu.dropItem); returns how many were queued
function AutoPilotMoon.Item:queueDropToFloor(player, container, items)
	local floor = ISInventoryPage.GetFloorContainer(player:getPlayerNum());

	for i, item in ipairs(items)
	do
		ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, container, floor));
	end

	return #items;
end

-- what the loot window does when a container is first opened (ISInventoryPage:checkExplored): on a server the items
-- are asked for, they arrive a moment later (N-A4)
function AutoPilotMoon.Item:explore(container, player)
	if not container:isExplored()
	then
		ISInventoryPage:checkExplored(container, player);
	end
end
