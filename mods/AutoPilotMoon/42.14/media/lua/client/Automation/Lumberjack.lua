-- AutoPilot (Moon): automations for the Moon server.

-- Lumberjack (Moon): chops the trees of an area with the game's own action, nearest first.
-- - A tree's square stays in the queue until the tree is down (B12): a chop interrupted halfway is taken up again.
-- - No axe left, or too tired to chop (the game's own check, isEnduranceSufficientForAction): the job stops with a
--   message instead of walking to every tree without chopping (B12).
-- - Never in a protected zone (at the start and before each tree).

require "05_AP_Config";
require "50_AP_Automation";

-- config

-- squareFilter: what the area tool counts (the trees), the same filter the job uses
AutoPilotMoon.Automation:register("lumberjack", {
	squareFilter = function(square)
		return square:getTree() ~= nil;
	end,
	unitKey = "IGUI_AutoPilot_S_Unit_Trees",
});

-- chops of the same tree before it is left: one chop goes on until the tree is down, a chop stopped by tiredness or
-- a broken axe ends the job, so more than a few means the tree cannot be reached (the walk fails every time)
AutoPilotMoon.Automation.lumberjackMaxSteps = 5;

-- filters

function AutoPilotMoon.Automation:getLumberjackTiles(squares)
	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		return square:getTree() ~= nil;
	end);
end

-- methods

function AutoPilotMoon.Automation.startLumberjack(player, squares)
	return AutoPilotMoon.Automation:startJob("lumberjack", player, squares, nil, function(list)
		return AutoPilotMoon.Automation:getLumberjackTiles(list);
	end);
end

function AutoPilotMoon.Automation:stopLumberjack()
	AutoPilotMoon.Automation:stopSquareProcessingQueue("lumberjackWorking");
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_Lumberjack");
end

function AutoPilotMoon.Automation:checkLumberjackSquare(square, player)
	local A = AutoPilotMoon.Automation;

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return "discard";
	end

	if square:getTree() == nil
	then
		-- down: the square is done
		return true;
	end

	if not AutoPilotMoon.Item:getBestWoodChoppingAxe(player)
	then
		A:stopBecause(getText("IGUI_AutoPilot_A_Reason_NeedTool", getText("IGUI_AutoPilot_T_NeedAxe")));

		return "discard";
	end

	if not player:isEnduranceSufficientForAction()
	then
		A:finishEarly(getText("IGUI_AutoPilot_A_TooTired", title()));

		return "discard";
	end

	-- keep the square until the tree is down
	return false;
end

function AutoPilotMoon.Automation:workLumberjackSquare(square, player)
	local tree = square:getTree();

	if tree and not AutoPilotMoon.Zones:isProtected(square, player)
	then
		ISWorldObjectContextMenu.doChopTree(player, tree);
	end
end

function AutoPilotMoon.Automation:checkLumberjackQueue(player)
	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "lumberjackWorking",
		maxStepsPerSquare = AutoPilotMoon.Automation.lumberjackMaxSteps,
		squareFunction = {
			fn = function(square, who)
				AutoPilotMoon.Automation:workLumberjackSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return AutoPilotMoon.Automation:checkLumberjackSquare(square, who);
		end,
		stopFunction = function()
			AutoPilotMoon.Automation:stopLumberjack();
		end,
	});
end

-- the menu entry "Abbatti alberi" (client/75_AP_JobMenu.lua): an axe, the area around the character or a rectangle

AutoPilotMoon.JobMenu:define("chopTrees", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_ChopTrees",
	job = "lumberjack",
	descKey = "IGUI_AutoPilot_T_Desc_ChopTrees",
	here = true,
	icon = "Base.Axe",
	requirements = function(player)
		return { AutoPilotMoon.JobMenu:axeRequirement(player) };
	end,
	limits = function()
		return { getText("IGUI_AutoPilot_T_JobLimit", title(),
			getText("IGUI_AutoPilot_T_Limit_Squares", AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob"))) };
	end,
	start = function(player, rect)
		return AutoPilotMoon.Automation.startLumberjack(player, AutoPilotMoon.Area:squares(rect));
	end,
});
