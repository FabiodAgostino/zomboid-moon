-- AutoPilot (Moon): automations for the Moon server.

-- Soil bagger (Moon): fills bags with the dirt, sand, gravel or clay of an area, with the game's own shovelling.
-- - The bag is the game's own choice (ISShovelGroundCursor.GetEmptyItem): a bag of that soil not full yet, else any
--   empty bag with the HOLD_DIRT tag (N-A16); clay goes into Base.Claybag as in the game (B13).
-- - Full bags lying in the main inventory go into a worn bag with room, through the game's transfer action that the
--   server checks (D1), never by hand.
-- - No shovel or no bag left: the job stops with a message. Never in a protected zone (start and every square).

require "05_AP_Config";
require "50_AP_Automation";

-- config

AutoPilotMoon.Automation:register("soilBagger");

AutoPilotMoon.Automation:addJobStateField("baggerSoilType");   -- the soil of the running job
AutoPilotMoon.Automation:addJobStateField("baggerFilling");    -- the sack being filled, until it is full

-- filters

function AutoPilotMoon.Automation:getSoilBaggerTiles(squares, soilType)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		return AutoPilotMoon.Square:getSoilType(square) == soilType;
	end);
end

-- methods

function AutoPilotMoon.Automation.startSoilBagger(player, squares, startSquare, soilType)
	local started = AutoPilotMoon.Automation:startJob("soilBagger", player, squares, startSquare, function(list)
		return AutoPilotMoon.Automation:getSoilBaggerTiles(list, soilType);
	end);

	if started
	then
		AutoPilotMoon.Automation.baggerSoilType = soilType;
	end

	return started;
end

-- the sack being filled is full: counted (spec 7.4.1: the sack as it is in the inventory, not the shovelful queued)
local function confirmFilled()
	local sack = AutoPilotMoon.Automation.baggerFilling;

	if sack and AutoPilotMoon.Item:isFullSoilBag(sack)
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Bags", 1);
		AutoPilotMoon.Automation.baggerFilling = nil;
	end
end

function AutoPilotMoon.Automation:stopSoilBagger()
	confirmFilled();
	AutoPilotMoon.Automation:stopSquareProcessingQueue("soilBaggerWorking");
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_SoilBagger");
end

function AutoPilotMoon.Automation:checkSoilBaggerSquare(square, player)
	local A = AutoPilotMoon.Automation;

	confirmFilled();

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return "discard";
	end

	if not AutoPilotMoon.Item:getShovel(player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedShovel")));

		return "discard";
	end

	local soilType = AutoPilotMoon.Square:getSoilType(square);

	if soilType ~= A.baggerSoilType
	then
		-- shovelled meanwhile, or something else now: nothing to do here
		return "discard";
	end

	local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

	if bag == nil
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedBag")));

		return "discard";
	end

	return true;
end

function AutoPilotMoon.Automation:workSoilBaggerSquare(square, player)
	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return;
	end

	-- the bags filled by the previous steps first
	AutoPilotMoon.Item:stashFullSoilBags(player);

	local shovel = AutoPilotMoon.Item:getShovel(player);
	local soilType, soilTile = AutoPilotMoon.Square:getSoilType(square);

	if shovel == nil or soilType == nil
	then
		return;
	end

	local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

	if bag == nil
	then
		return;
	end

	-- as the game's own cursor (ISShovelGroundCursor:create)
	if AutoPilotMoon.Square:walkTo(player, square, true)
	then
		ISWorldObjectContextMenu.transferIfNeeded(player, bag);
		ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), shovel, true, true);
		ISTimedActionQueue.add(ISShovelGround:new(player, bag, soilTile, "blends_natural_01_64", bagType));
		AutoPilotMoon.Automation.baggerFilling = bag;
	end
end

function AutoPilotMoon.Automation:checkSoilBaggerQueue(player)
	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "soilBaggerWorking",
		squareFunction = {
			fn = function(square, who)
				AutoPilotMoon.Automation:workSoilBaggerSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return AutoPilotMoon.Automation:checkSoilBaggerSquare(square, who);
		end,
		stopFunction = function()
			AutoPilotMoon.Automation:stopSoilBagger();
		end,
	});
end

-- the menu entry "Insacca: terra" (client/75_AP_JobMenu.lua): the soil the character stands on (spec 2.2), a shovel
-- and an empty sack for it; the squares of that soil in the area

local function currentSoil(player)
	local square = player and AutoPilotMoon.Square:getCurrent(player);

	return square, square and AutoPilotMoon.Square:getSoilType(square) or nil;
end

local function soilName(soilType)
	return getText("IGUI_AutoPilot_A_Soil" .. AutoPilotMoon:ucFirst(soilType or "dirt"));
end

AutoPilotMoon.JobMenu:define("bagSoil", {
	group = "ground",
	job = "soilBagger",
	labelKey = "IGUI_AutoPilot_M_BagSoil",
	label = function(player)
		local square, soilType = currentSoil(player);

		return getText("IGUI_AutoPilot_M_BagSoil", soilName(soilType));
	end,
	descKey = "IGUI_AutoPilot_T_Desc_BagSoil",
	icon = "Base.Shovel",
	-- the soil under the character's feet: the clicked square has that same soil (spec 2.2 rule 6)
	here = function(square, player)
		local current, soilType = currentSoil(player);

		return soilType ~= nil and AutoPilotMoon.Square:getSoilType(square) == soilType;
	end,
	requirements = function(player)
		local square, soilType = currentSoil(player);
		local requirements = {
			{ ok = soilType ~= nil, reasonKey = "IGUI_AutoPilot_A_WrongSoil" },
			AutoPilotMoon.JobMenu:shovelRequirement(player),
		};

		if soilType
		then
			local bagType, bag = AutoPilotMoon.Item:getBagForSoil(player, soilType);

			table.insert(requirements, { ok = bag ~= nil, needKey = "IGUI_AutoPilot_T_NeedBag", haveText = bag and bag:getDisplayName() or nil });
		end

		return requirements;
	end,
	-- the squares of the soil the character stands on when the area tool opens
	countFn = function(params)
		local square, soilType = currentSoil(AutoPilotMoon:getPlayer());

		return function(other)
			return soilType ~= nil and AutoPilotMoon.Square:getSoilType(other) == soilType;
		end;
	end,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", title(),
			getText("IGUI_AutoPilot_T_Limit_Squares", AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob"))) };
	end,
	start = function(player, rect)
		local square, soilType = currentSoil(player);

		if soilType == nil
		then
			return false;
		end

		return AutoPilotMoon.Automation.startSoilBagger(player, AutoPilotMoon.Area:squares(rect), square, soilType);
	end,
});
