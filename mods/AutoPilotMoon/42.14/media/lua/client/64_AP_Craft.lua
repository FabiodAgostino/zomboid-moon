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
-- Only confirmed results count (spec 7.4.1): the input gone from the inventory, the outputs that appeared.

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

-- the logic the game builds for a recipe chosen on an item (ISInventoryPaneContextMenu.OnNewCraft)
function AutoPilotMoon.Craft:newLogic(player, recipe, item)
	local logic = HandcraftLogic.new(player, nil, nil);

	logic:setIsoObject(logic:findCraftSurface(player, Craft.surfaceRange));
	logic:setContainers(ISInventoryPaneContextMenu.getContainers(player));
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

-- Starts the recipe on the item the game's way (the walk to a work surface included). outputTypes: set of full types
-- the recipe makes ({ ["Base.Plank"] = true }), to find them afterwards. Returns the pending craft, or nil when the game
-- queued nothing.
function AutoPilotMoon.Craft:start(player, recipe, item, outputTypes)
	local before = snapshot(player, outputTypes);
	local queue = ISTimedActionQueue.getTimedActionQueue(player);
	local count = #queue.queue;

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
		idleSince = nil,
	};
end

-- Once the character is idle again: "busy" while waiting for the server, else "done", consumed (the input is gone) and
-- the list of the outputs that appeared in the inventory.
function AutoPilotMoon.Craft:confirm(pending, player)
	local now = getTimestampMs();
	local consumed = player:getInventory():getItemWithIDRecursiv(pending.itemId) == nil;

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
