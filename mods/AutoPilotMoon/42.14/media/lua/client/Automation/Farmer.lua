-- AutoPilot (Moon): automations for the Moon server.

-- Farmer (Moon): waters the seeded plants of an area with the game's own watering action ("Innaffia").
-- - Up to 100, the game's top (N-A5), not to the plant's minimum: they no longer fall short again within hours. A plant
--   is worth a walk when at least one whole use (10) is missing.
-- - The water the player holds, else a watering can: never a bottle from the bags (N-A6). When the item runs short the
--   plant is kept and the next step takes another can; no water left: the job stops with a message.
-- - Phase C (11/11/2026, ANALISI-WorkOrders.md 4.8 and 6 row 4, spec 5): with a water source chosen after the area
--   (ctx.waterSource: a square whose object has water, the game's "Fill" menu), an empty watering can is filled there
--   with the game's own action (ISWorldObjectContextMenu.onTakeWater: the walk, then ISTakeWaterAction) and the job goes
--   back to the plants; a source that gives nothing twice, or is gone, stops the job with the reason.
-- - The plant is checked again right before the action (N-S7: the server's complete() fails if it is gone).
-- - Never in a protected zone (at the start and before each plant).
-- The Farmer's other jobs (dig, sow, fertilize, treat, harvest, remove) are in Automation/FarmJobs.lua, under the same
-- server switch EnableFarmer (spec 2.5). AutoPilotMoon.Farm holds what they share.

require "05_AP_Config";
require "50_AP_Automation";

AutoPilotMoon.Farm = AutoPilotMoon.Farm or {};

local Farm = AutoPilotMoon.Farm;
local A = AutoPilotMoon.Automation;

-- config

A:register("farmer", {
	squareFilter = function(square, player)
		local plant = AutoPilotMoon.Square:getSeededPlant(square);

		return plant ~= nil and AutoPilotMoon.Square:isThirsty(plant);
	end,
	unitKey = "IGUI_AutoPilot_S_Unit_Plants",
});

-- waterings of the same plant before it is left: a plant is kept only when the item runs short, and every watering
-- that happens gives at least one use, at most 10 are ever missing; more means the watering never happens
A.farmerMaxSteps = 10;

A:addJobStateField("farmerPlan");
A:addJobStateField("farmerSource");   -- the water source chosen after the area ({ x, y, z }), or nil
A:addJobStateField("farmerRefill");   -- { tries, at, can }: filling the watering can at the source
A:addJobStateField("farmerPending");  -- { square, before }: the last watering, counted when the water level rose
A:addJobStateField("farmerWatered");  -- "x,y,z" -> true: plants counted as watered (once each)

Farm.refillGraceMs = 1500;   -- the filling ended and the can is still empty: the server may still answer
Farm.maxRefillTries = 2;     -- fillings that bring no water before the job stops


-- shared helpers

-- the plant object of a square that the game shows (ISFarmingMenu.isValidPlant reads it again from the world), or nil
function AutoPilotMoon.Farm:getPlant(square)
	local plant = CFarmingSystem.instance:getLuaObjectOnSquare(square);

	if plant and ISFarmingMenu.isValidPlant(plant)
	then
		return plant;
	end

	return nil;
end

-- the game's CPlantGlobalObject:isAlive
function AutoPilotMoon.Farm:isAlive(plant)
	local state = plant.state;

	return state ~= "destroyed" and state ~= "dead" and state ~= "rotten" and state ~= "harvested";
end

-- a flag of the plant's mod data: the server writes booleans, old saves strings
function AutoPilotMoon.Farm:isTrue(value)
	return value == true or value == "true";
end

-- a watering can the character has, empty or not: the one in hand, else the first one of the inventory
function AutoPilotMoon.Farm:getRefillableCan(player)
	local hand = player:getPrimaryHandItem();

	if AutoPilotMoon.Item:isWateringCan(hand)
	then
		return hand;
	end

	return player:getInventory():getFirstEvalRecurse(function(item)
		return AutoPilotMoon.Item:isWateringCan(item);
	end);
end

-- the water of a square as the game offers it to fill a container (ISWorldObjectContextMenuLogic.doFillFluidMenu of
-- 42.22: an object with hasWater()), or nil
function AutoPilotMoon.Farm:getWaterObject(square)
	if square == nil
	then
		return nil;
	end

	local objects = square:getObjects();

	for i = 0, objects:size() - 1
	do
		local object = objects:get(i);

		if object and not instanceof(object, "IsoWorldInventoryObject") and object:hasWater()
		then
			return object;
		end
	end

	return nil;
end

local function waterSourceName(object)
	local sprite = object:getSprite();
	local props = sprite and sprite:getProperties();
	local name = props and props:get("CustomName");

	if name
	then
		return Translator.getMoveableDisplayName(name) or name;
	end

	return getText("ContextMenu_NaturalWaterSource");
end

-- the water source picker's look at a square (DestinationPicker opts.inspect)
function AutoPilotMoon.Farm:inspectWaterSource(square, player)
	local info = { ok = true, kind = "water", x = square:getX(), y = square:getY(), z = square:getZ() };
	local object = Farm:getWaterObject(square);

	if object
	then
		info.object = object;
		info.nameText = waterSourceName(object);
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Protected";
	elseif object == nil
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_NoWater";
	elseif object:getFluidAmount() <= 0
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_WaterEmpty";
	end

	return info;
end

-- the box's line for the source under the cursor (nil: nothing to name)
function AutoPilotMoon.Farm:describeWaterSource(info)
	if info.nameText == nil
	then
		return nil;
	end

	return getText("IGUI_AutoPilot_D_WaterSource", info.nameText);
end

-- the second step of "Innaffia > E riempi a una fonte" (JobMenu spec.second)
function AutoPilotMoon.Farm:waterSourceStep()
	return {
		whatKey = "IGUI_AutoPilot_D_TitleWater",
		howKey = "IGUI_AutoPilot_D_HowWater",
		noRemember = true,
		inspect = function(square, player)
			return Farm:inspectWaterSource(square, player);
		end,
		describe = function(info)
			return Farm:describeWaterSource(info);
		end,
		toDest = function(info)
			return { kind = "water", x = info.x, y = info.y, z = info.z };
		end,
	};
end

-- filters

function AutoPilotMoon.Automation:getFarmerTiles(squares)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		local plant = AutoPilotMoon.Square:getSeededPlant(square);

		return plant ~= nil and AutoPilotMoon.Square:isThirsty(plant);
	end);
end

-- methods

-- ctx (optional): waterSource = { x, y, z } where an empty watering can is filled (the menu's second step)
function AutoPilotMoon.Automation.startFarmer(player, squares, startSquare, ctx)
	local started = A:startJob("farmer", player, squares, startSquare, function(list)
		return A:getFarmerTiles(list);
	end);

	if started
	then
		A.farmerSource = ctx and ctx.waterSource or nil;
	end

	return started;
end


local function title()
	return getText("IGUI_AutoPilot_O_Context_Farmer");
end

-- Filling the watering can at the chosen source, one decision while idle: "busy" while it goes on, nil when the can
-- has water again (the watering goes on), "discard" when the job stopped.
function AutoPilotMoon.Farm:refill(player)
	local refill = A.farmerRefill;

	if refill and refill.can and AutoPilotMoon.Item:getWaterUses(refill.can) > 0
	then
		-- only what arrived counts (spec 7.4.1): the can has water
		A.farmerRefill = nil;
		AutoPilotMoon.Progress:setWaiting(false);
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Refilled");

		return nil;
	end

	if refill and refill.queued
	then
		-- the grace starts at the first idle frame after the filling, not when it was queued: the walk to the source
		-- and the filling take longer than the grace
		refill.at = refill.at or getTimestampMs();

		if getTimestampMs() - refill.at < Farm.refillGraceMs
		then
			AutoPilotMoon.Progress:setWaiting(true);

			return "busy";
		end
	end

	if refill and refill.tries >= Farm.maxRefillTries
	then
		AutoPilotMoon.Progress:setWaiting(false);
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_SourceGivesNothing"));

		return "discard";
	end

	local can = Farm:getRefillableCan(player);

	if can == nil
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_NoWaterLeft", title()));

		return "discard";
	end

	local source = A.farmerSource;
	local square = getCell():getGridSquare(source.x, source.y, source.z);
	local object = Farm:getWaterObject(square);

	if object == nil
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_SourceGone"));

		return "discard";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_Protected"));

		return "discard";
	end

	refill = refill or { tries = 0 };
	refill.tries = refill.tries + 1;
	refill.can = can;
	A.farmerRefill = refill;

	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Filling");
	-- the game's own "Fill" (ISWorldObjectContextMenu.onTakeWater): next to the source, the can into the main
	-- inventory, ISTakeWaterAction, the can back into its bag
	ISWorldObjectContextMenu.onTakeWater(nil, object, nil, can, player:getPlayerNum());
	refill.queued = true;
	refill.at = nil;

	return "busy";
end

-- a plant counts as watered (once) when its water level rose after this job's watering (spec 7.4.1: only what really
-- happened); a plant gone or a watering that did not happen is not counted
local function confirmLastWatering()
	local pending = A.farmerPending;

	A.farmerPending = nil;

	if pending == nil
	then
		return;
	end

	local plant = AutoPilotMoon.Square:getSeededPlant(pending.square);

	local square = pending.square;
	local key = square:getX() .. "," .. square:getY() .. "," .. square:getZ();
	local counted = A:getJobSet("farmerWatered");

	if plant and (tonumber(plant["waterLvl"]) or 0) > pending.before and not counted[key]
	then
		counted[key] = true;
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Watered");
	end
end

-- the last plant of the job is counted too
function AutoPilotMoon.Automation:stopFarmer()
	if A.job and A.job.name == "farmer"
	then
		confirmLastWatering();
	end

	A:stopSquareProcessingQueue("farmerWorking");
end

function AutoPilotMoon.Automation:checkFarmerSquare(square, player)
	A.farmerPlan = nil;

	confirmLastWatering();

	if A.farmerRefill
	then
		local answer = Farm:refill(player);

		if answer
		then
			return answer;
		end
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		AutoPilotMoon.Progress:warn("IGUI_AutoPilot_A_Skip_Protected");

		return "discard";
	end

	local plant = AutoPilotMoon.Square:getSeededPlant(square);

	if plant == nil
	then
		-- harvested or gone meanwhile
		return "discard";
	end

	if not AutoPilotMoon.Square:isThirsty(plant)
	then
		return true;
	end

	local item = AutoPilotMoon.Item:getWateringItem(player);

	if item == nil
	then
		if A.farmerSource
		then
			-- the can is empty: to the source, then back here
			return Farm:refill(player) or "busy";
		end

		A:finishEarly(getText("IGUI_AutoPilot_A_NoWaterLeft", title()));

		return "discard";
	end

	local needed = AutoPilotMoon.Square:getMissingWaterUses(plant);
	local uses = needed;
	local available = AutoPilotMoon.Item:getWaterUses(item);

	if available < uses
	then
		uses = available;
	end

	A.farmerPlan = { square = square, item = item, uses = uses };

	-- the item runs short of this plant: keep it, the next step takes another can
	return uses >= needed;
end

function AutoPilotMoon.Automation:workFarmerSquare(square, player)
	local plan = A.farmerPlan;

	A.farmerPlan = nil;

	if plan == nil or plan.square ~= square or plan.uses <= 0
	then
		return;
	end

	-- right before the action: the plant is still there and still thirsty (N-S7)
	local plant = AutoPilotMoon.Square:getSeededPlant(square);

	if plant == nil or not AutoPilotMoon.Square:isThirsty(plant) or AutoPilotMoon.Zones:isProtected(square, player)
	then
		return;
	end

	if not ISFarmingMenu.walkToPlant(player, square)
	then
		return;
	end

	local handItem = player:getPrimaryHandItem();

	if handItem ~= plan.item
	then
		ISWorldObjectContextMenu.equip(player, handItem, plan.item, true);
	end

	AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Watering");
	ISTimedActionQueue.add(ISWaterPlantAction:new(player, plan.item, plan.uses, square, 20 + (6 * plan.uses)));
	A.farmerPending = { square = square, before = tonumber(plant["waterLvl"]) or 0 };
end

function AutoPilotMoon.Automation:checkFarmerQueue(player)
	A:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "farmerWorking",
		maxStepsPerSquare = A.farmerMaxSteps,
		squareFunction = {
			fn = function(square, who)
				A:workFarmerSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return A:checkFarmerSquare(square, who);
		end,
		stopFunction = function()
			A:stopFarmer();
		end,
	});
end

-- the menu entry "Innaffia" (client/75_AP_JobMenu.lua): with the water the character has, or filling the watering can
-- at a source chosen after the area

local function waterRequirement(player, params)
	local can = Farm:getRefillableCan(player);

	if params and params.refill
	then
		return { ok = can ~= nil, needKey = "IGUI_AutoPilot_T_NeedWateringCan", haveText = can and can:getDisplayName() or nil, item = can };
	end

	local item = AutoPilotMoon.Item:getWateringItem(player);

	if item == nil and params == nil and can
	then
		-- the verb itself: an empty can is enough for the variant that fills it
		return { ok = true, haveText = can:getDisplayName(), item = can };
	end

	return { ok = item ~= nil, needKey = "IGUI_AutoPilot_T_NeedWater", haveText = item and item:getDisplayName() or nil, item = item };
end

AutoPilotMoon.JobMenu:define("water", {
	group = "fields",
	labelKey = "IGUI_AutoPilot_M_Water",
	job = "farmer",
	descKey = "IGUI_AutoPilot_T_Desc_Farm",
	here = true,
	variants = {
		{ labelKey = "IGUI_AutoPilot_M_WaterOnly", params = { refill = false } },
		{ labelKey = "IGUI_AutoPilot_M_WaterRefill", params = { refill = true } },
	},
	requirements = function(player, params)
		return { waterRequirement(player, params) };
	end,
	notes = function(player, params)
		if params and params.refill
		then
			return { { text = getText("IGUI_AutoPilot_T_RefillHow") } };
		end

		return {};
	end,
	second = function(params)
		if params and params.refill
		then
			return Farm:waterSourceStep();
		end

		return nil;
	end,
	start = function(player, region, dest, params)
		return A.startFarmer(player, AutoPilotMoon.JobMenu:squaresOf(region), nil, { waterSource = dest, area = region, params = params });
	end,
});
