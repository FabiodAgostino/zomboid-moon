-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Square = AutoPilotMoon.Square or {};

-- helpers

function AutoPilotMoon.Square:getCurrent(player)
    player = player or AutoPilotMoon:getPlayer();

    if player == nil
    then
        return nil;
    end

    return player:getSquare();
end

function AutoPilotMoon.Square:walkTo(player, square, synchronous, adjacent)
	if square == nil
	then
		return false;
	end

	local current = AutoPilotMoon.Square:getCurrent(player);

	if current and square:getZ() < current:getZ()
	then
		setGameSpeed(1);
	end

	if synchronous
	then
		if not AutoPilotMoon.Automation["corpsePilerWorking"] or adjacent
		then
			return luautils.walkAdj(player, square, true);
		else
			return luautils.walk(player, square, true);
		end
	else
		return ISTimedActionQueue.add(ISWalkToTimedAction:new(player, square));
	end
end

-- search functions

function AutoPilotMoon.Square:getSoilType(square)
    return ISShovelGroundCursor.GetDirtGravelSand(square);
end

function AutoPilotMoon.Square:getGrass(square)
    return AutoPilotMoon.Square:checkObjectsForIsoFlag(square, IsoFlagType.canBeRemoved);
end

function AutoPilotMoon.Square:getPlant(square)
    return AutoPilotMoon.Square:checkObjectsForIsoFlag(square, IsoFlagType.canBeCut);
end

function AutoPilotMoon.Square:checkObjectsForIsoFlag(square, isoFlag)
    local objects = square:getObjects();

    for i = 0, objects:size() - 1
    do
        local object = objects:get(i);
        local sprite = object:getSprite();
        local props = sprite and sprite:getProperties();

        if props and props:has(isoFlag)
        then
            return square;
        end
    end

    return nil;
end

-- the corpses the Corpse piler may move (B11): the dead bodies of the square only (no other moving object), players'
-- bodies too (phase C, the rule "as by hand": the game lets you drag them), never an animal (the game's "Grab corpse"
-- leaves them out), nothing on a burning square (the game greys out the grab there)
function AutoPilotMoon.Square:getValidCorpses(square)
	local result = {};

	if square == nil or square:haveFire()
	then
		return result;
	end

	local corpses = square:getDeadBodys();

	for i = 0, corpses:size() - 1
	do
		local corpse = corpses:get(i);

		if corpse and not corpse:isAnimal()
		then
			table.insert(result, corpse);
		end
	end

	return result;
end

-- farming

function AutoPilotMoon.Square:getSeededPlant(square)
    local plant = CFarmingSystem.instance:getLuaObjectOnSquare(square);

    if plant and ISFarmingMenu.isValidPlant(plant) and plant["state"] == "seeded"
    then
        return plant;
    end

    return nil;
end

-- N-A5: the Farmer waters up to 100 (the game's own top, ISWaterPlantAction), not to the plant's minimum: the
-- missing water, and the uses of a water source it takes (10 water per use, at most 10 uses per action, as the
-- game's menu)
AutoPilotMoon.Square.waterTarget = 100;
AutoPilotMoon.Square.waterPerUse = 10;
AutoPilotMoon.Square.maxUsesPerAction = 10;

function AutoPilotMoon.Square:getMissingWater(plant)
	local level = tonumber(plant["waterLvl"]) or 0;
	local missing = AutoPilotMoon.Square.waterTarget - level;

	if missing < 0
	then
		return 0;
	end

	return missing;
end

function AutoPilotMoon.Square:getMissingWaterUses(plant)
	local uses = math.ceil(AutoPilotMoon.Square:getMissingWater(plant) / AutoPilotMoon.Square.waterPerUse);

	if uses > AutoPilotMoon.Square.maxUsesPerAction
	then
		return AutoPilotMoon.Square.maxUsesPerAction;
	end

	return uses;
end

-- worth a walk: at least one whole use missing (a plant at 95 waits for the next round)
function AutoPilotMoon.Square:isThirsty(plant)
	return AutoPilotMoon.Square:getMissingWater(plant) >= AutoPilotMoon.Square.waterPerUse;
end
