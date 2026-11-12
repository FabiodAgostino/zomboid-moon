-- AutoPilot (Moon): automations for the Moon server.

-- Dismantler (Moon): dismantles furniture only (L3), with the game's own dismantling, one object at a time.
-- - Furniture (F4 of the second analysis): a moveable sprite (IsMoveAble) of type Object, that can be scrapped, with
--   none of the flags of a wall, door, window, fence or floor; never a door, window, curtain or barricade object, nor
--   a door frame, stairs or floor built by players. The player's preference "electronics only" keeps only the
--   furniture whose primary material is Electric (E1).
-- - Never a ZomBOT gravestone (AutoPilotMoon.Zones:isProtectedObject: its server refuses), never in a protected zone (a
--   safehouse the player may not use, checked at the start and again before each object). Furniture over several
--   squares goes whole: none of its parts may be on a protected square or be a gravestone. Anything else a player
--   may dismantle by hand goes too (a jukebox, furniture next to another player).
-- - At most DismantlerObjectsPerJob objects per job, then the job ends with a summary (N-A14).
-- - "Empty before scrapping" empties only the object about to be dismantled (N-A2), onto the floor next to it,
--   UnloaderItemsPerStep items at a time and UnloaderItemsPerJob per job, only if all of it can go
--   (no favourites, nothing locked, room on the floor); otherwise the object is skipped with a message. No retry:
--   each object is tried once per job.
-- - A lamp gives its light bulb back before it is dismantled, as the game's own menu does (N-A7).

require "05_AP_Config";
require "50_AP_Automation";

-- config

AutoPilotMoon.Automation:register("dismantler");

AutoPilotMoon.Automation:addJobStateField("dismantlerTried");     -- objects handled or given up in this job
AutoPilotMoon.Automation:addJobStateField("dismantlerScrapped");  -- objects sent to dismantling
AutoPilotMoon.Automation:addJobStateField("dismantlerItems");     -- items taken out to empty them
AutoPilotMoon.Automation:addJobStateField("dismantlerEmptying");  -- { object, count }: the object being emptied
AutoPilotMoon.Automation:addJobStateField("dismantlerExplored");  -- object -> when its containers were first opened
AutoPilotMoon.Automation:addJobStateField("dismantlerPlan");      -- what this step's square function does
AutoPilotMoon.Automation:addJobStateField("dismantlerElectronics"); -- electronics only ("Smonta l'elettronica")
AutoPilotMoon.Automation:addJobStateField("dismantlerPending");   -- the object sent to dismantling, until it is gone

-- how long to wait for the server's items after opening a container for the first time
AutoPilotMoon.Automation.dismantlerExploreMs = 1500;

-- the sprite flags (and same-named properties) of what is not furniture
AutoPilotMoon.Automation.dismantlerStructuralFlags = {
	"WallN", "WallW", "WallNW", "WallSE", "WallNTrans", "WallWTrans", "DoorWallN", "DoorWallW",
	"doorN", "doorW", "windowN", "windowW", "WindowN", "WindowW",
	"HoppableN", "HoppableW", "TallHoppableN", "TallHoppableW",
	"solidfloor",
};

-- objects of these classes are never furniture
AutoPilotMoon.Automation.dismantlerExcludedClasses = {
	"IsoDoor", "IsoWindow", "IsoWindowFrame", "IsoCurtain", "IsoBarricade", "IsoTree", "IsoDeadBody",
};

-- filters

local function hasFlag(props, name)
	local flag = IsoFlagType[name];

	if flag ~= nil and props:has(flag)
	then
		return true;
	end

	return props:has(name);
end

-- F4 (and E1 when electronicsOnly) on the sprite's properties alone: cheap, no moveable props built (C4)
function AutoPilotMoon.Automation:isDismantlerFurniture(object, electronicsOnly)
	if object == nil
	then
		return false;
	end

	for i, class in ipairs(AutoPilotMoon.Automation.dismantlerExcludedClasses)
	do
		if instanceof(object, class)
		then
			return false;
		end
	end

	if instanceof(object, "IsoThumpable") and (object:isDoor() or object:isDoorFrame() or object:isStairs() or object:isFloor())
	then
		return false;
	end

	local sprite = object:getSprite();
	local props = sprite and sprite:getProperties();

	if props == nil or not props:has("CanScrap") or not props:has("IsMoveAble")
	then
		return false;
	end

	local moveType = props:get("MoveType");

	if moveType ~= nil and moveType ~= "Object"
	then
		return false;
	end

	local material = props:get("Material");

	if material == nil or material == "Undefined"
	then
		return false;
	end

	if electronicsOnly and material ~= "Electric"
	then
		return false;
	end

	for i, name in ipairs(AutoPilotMoon.Automation.dismantlerStructuralFlags)
	do
		if hasFlag(props, name)
		then
			return false;
		end
	end

	return true;
end

-- furniture the dismantler may touch: F4/E1, not a ZomBOT gravestone, and the game's own moveable props agree
-- (moveable, scrappable, of type Object); returns its moveable props
function AutoPilotMoon.Automation:getDismantlerTarget(object, electronicsOnly)
	if not AutoPilotMoon.Automation:isDismantlerFurniture(object, electronicsOnly) or AutoPilotMoon.Zones:isProtectedObject(object)
	then
		return nil;
	end

	local moveProps = ISMoveableSpriteProps.fromObject(object);

	if moveProps == nil or not moveProps.isMoveable or not moveProps.canScrap or moveProps.type ~= "Object" or moveProps.object ~= object
	then
		return nil;
	end

	return moveProps;
end

local function hasUnexploredContainer(object)
	for i, container in ipairs(AutoPilotMoon.Item:getAllObjectContainers(object))
	do
		if not container:isExplored()
		then
			return true;
		end
	end

	return false;
end

-- the player has the tools for this material (cached per material for one filtering pass)
local function hasToolsFor(moveProps, player, cache)
	local key = tostring(moveProps.material);

	if cache[key] == nil
	then
		local ok = true;

		if moveProps.scrapUseTool
		then
			ok = moveProps:hasScrapTool(player, false) ~= false and moveProps:hasScrapTool(player, true) ~= false;
		end

		cache[key] = ok;
	end

	return cache[key];
end

-- at the start: the squares with furniture the player could dismantle now (its tools), or whose content is unknown
-- yet or could be emptied first
function AutoPilotMoon.Automation:getDismantlerTiles(squares, player, electronicsOnly)
	electronicsOnly = electronicsOnly == true;

	local unload = AutoPilotMoon.Options:get("unloadBeforeScrapping") == true;
	local cache = {};

	return AutoPilotMoon.Grid:filterSquaresBy(squares, function(square)
		local objects = square:getObjects();

		for i = 0, objects:size() - 1
		do
			local object = objects:get(i);
			local moveProps = AutoPilotMoon.Automation:getDismantlerTarget(object, electronicsOnly);

			if moveProps and hasToolsFor(moveProps, player, cache)
				and (unload or object:isObjectNoContainerOrEmpty() or hasUnexploredContainer(object))
			then
				return true;
			end
		end

		return false;
	end);
end

-- methods

-- ctx (optional): { params = { electronics = true } } for "Smonta l'elettronica" (only what is mainly electric, E1)
function AutoPilotMoon.Automation.startDismantler(player, squares, startSquare, ctx)
	local electronicsOnly = ctx ~= nil and ctx.params ~= nil and ctx.params.electronics == true;
	local started = AutoPilotMoon.Automation:startJob("dismantler", player, squares, startSquare, function(list, who)
		return AutoPilotMoon.Automation:getDismantlerTiles(list, who, electronicsOnly);
	end);

	if started
	then
		AutoPilotMoon.Automation.dismantlerElectronics = electronicsOnly;
	end

	return started;
end

-- the object sent to dismantling is gone from the world (getObjectIndex -1): counted (spec 7.4.1); at every step and at
-- the end
local function confirmScrapped()
	local pending = AutoPilotMoon.Automation.dismantlerPending;

	if pending and pending:getObjectIndex() < 0
	then
		AutoPilotMoon.Progress:count("IGUI_AutoPilot_P_C_Dismantled", 1);
		AutoPilotMoon.Automation.dismantlerPending = nil;
	end
end

function AutoPilotMoon.Automation:stopDismantler()
	confirmScrapped();
	AutoPilotMoon.Automation:stopSquareProcessingQueue("dismantlerWorking");
end

local function title()
	return getText("IGUI_AutoPilot_O_Context_Dismantler");
end

local function objectName(moveProps)
	return Translator.getMoveableDisplayName(moveProps.name);
end

local function summary(key)
	return getText(key, title(), AutoPilotMoon.Automation:getJobCount("dismantlerScrapped"));
end

-- skip an object for the rest of the job, with a message saying why
local function skip(object, moveProps, reasonKey)
	AutoPilotMoon.Automation:getJobSet("dismantlerTried")[object] = true;
	AutoPilotMoon.Automation.dismantlerEmptying = nil;

	if reasonKey
	then
		AutoPilotMoon:message(getText("IGUI_AutoPilot_A_ObjectSkipped", objectName(moveProps), getText(reasonKey)));
	end
end

-- the next object of the square to work on, with its moveable props (objects already tried are left out)
local function nextTarget(square, electronicsOnly)
	local tried = AutoPilotMoon.Automation:getJobSet("dismantlerTried");
	local objects = square:getObjects();

	for i = objects:size() - 1, 0, -1
	do
		local object = objects:get(i);

		if not tried[object]
		then
			local moveProps = AutoPilotMoon.Automation:getDismantlerTarget(object, electronicsOnly);

			if moveProps
			then
				return object, moveProps;
			end

			tried[object] = true;
		end
	end

	return nil, nil;
end

-- Furniture over several squares is dismantled whole (ISMoveableSpriteProps:scrapObject takes every part of its
-- sprite grid), so every part must be free to touch, not only the one checked: none on a protected square (a
-- safehouse boundary through a couch), none a gravestone. Returns the reason key, nil when the whole grid is free. A
-- grid the game cannot read is refused by the game itself (canScrapObject), nothing to add here.
local function gridProtectionReason(moveProps, square, player)
	if not moveProps.isMultiSprite
	then
		return nil;
	end

	local grid = moveProps:getSpriteGridInfo(square, true);

	if grid == nil
	then
		return nil;
	end

	for i, member in ipairs(grid)
	do
		if member.square == nil or AutoPilotMoon.Zones:isProtected(member.square, player)
		then
			return "IGUI_AutoPilot_A_Reason_Protected";
		end

		if member.object and AutoPilotMoon.Zones:isProtectedObject(member.object)
		then
			return "IGUI_AutoPilot_A_Reason_Grave";
		end
	end

	return nil;
end

-- tools present and nothing in the way but the content (canScrapObject: containerFull)
local function blockedOnlyByContent(result, moveProps)
	if not result.containerFull or result.craftValid == false
	then
		return false;
	end

	return not moveProps.scrapUseTool or (result.haveTool ~= false and result.haveTool ~= nil and result.haveTool2 ~= false and result.haveTool2 ~= nil);
end

-- the plan to empty the object: the containers and items of this step, or the reason it cannot be emptied
local function planEmptying(square, object, moveProps, player)
	local A = AutoPilotMoon.Automation;
	local containers = AutoPilotMoon.Item:getAllObjectContainers(object);
	local unloadable = AutoPilotMoon.Item:getUnloadableContainers(object, player);

	if #unloadable < #containers
	then
		return nil, "IGUI_AutoPilot_A_Reason_Locked";
	end

	local all = {};
	local byContainer = {};

	for i, container in ipairs(unloadable)
	do
		local items, kept = AutoPilotMoon.Item:getUnloadableItems(container);

		if kept > 0
		then
			return nil, "IGUI_AutoPilot_A_Reason_ItemsStay";
		end

		for j, item in ipairs(items)
		do
			table.insert(all, item);
			byContainer[item] = container;
		end
	end

	if #all == 0
	then
		return nil, "IGUI_AutoPilot_A_Reason_CannotEmpty";
	end

	-- no progress since the last step: the server refused the transfers
	local emptying = A.dismantlerEmptying;

	if emptying and emptying.object == object and #all >= emptying.count
	then
		return nil, "IGUI_AutoPilot_A_Reason_CannotEmpty";
	end

	local budget = AutoPilotMoon.Sandbox:getInteger("UnloaderItemsPerJob") - A:getJobCount("dismantlerItems");

	if #all > budget
	then
		return nil, "IGUI_AutoPilot_A_Reason_ItemLimit";
	end

	if AutoPilotMoon.Item:getTotalWeight(all) > AutoPilotMoon.Item:getFloorRoom(square, player)
	then
		return nil, "IGUI_AutoPilot_A_Reason_NoFloorRoom";
	end

	local step = AutoPilotMoon.Item:takeFitting(all, AutoPilotMoon.Sandbox:getInteger("UnloaderItemsPerStep"), AutoPilotMoon.Item:getTotalWeight(all));
	local groups = {};
	local order = {};

	for i, item in ipairs(step)
	do
		local container = byContainer[item];

		if groups[container] == nil
		then
			groups[container] = {};
			table.insert(order, container);
		end

		table.insert(groups[container], item);
	end

	-- dismantlerEmptying is written when the transfers are queued (workDismantlerSquare): a step the engine does not
	-- carry out (no free tile next to the square) must not look like a refusal next time
	return { kind = "empty", square = square, object = object, moveProps = moveProps, order = order, groups = groups,
		count = #all }, nil;
end

-- one step on a square: decide (removeCheckFunction), then the square function carries the plan out
function AutoPilotMoon.Automation:checkDismantlerSquare(square, player)
	local A = AutoPilotMoon.Automation;

	A.dismantlerPlan = nil;
	confirmScrapped();

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return "discard";
	end

	local cap = AutoPilotMoon.Sandbox:getInteger("DismantlerObjectsPerJob");

	if A:getJobCount("dismantlerScrapped") >= cap
	then
		A:finishEarly(summary("IGUI_AutoPilot_A_DismantlerCapReached"));

		return "discard";
	end

	if A:relocateIfNeeded(square, player)
	then
		return "wait";
	end

	local electronicsOnly = A.dismantlerElectronics == true;
	local object, moveProps = nextTarget(square, electronicsOnly);

	if object == nil
	then
		-- nothing left here: the square is done
		return true;
	end

	local gridReason = gridProtectionReason(moveProps, square, player);

	if gridReason
	then
		skip(object, moveProps, gridReason);

		return false;
	end

	-- containers never opened: open them first (the server sends their content) and wait a moment
	local explored = A:getJobSet("dismantlerExplored");

	if hasUnexploredContainer(object)
	then
		A.dismantlerPlan = { kind = "explore", square = square, object = object };

		return false;
	end

	if explored[object] and getTimestampMs() - explored[object] < A.dismantlerExploreMs
	then
		return false;
	end

	local result = moveProps:canScrapObject(player);

	if result.canScrap
	then
		A.dismantlerPlan = { kind = "scrap", square = square, object = object, moveProps = moveProps };

		return false;
	end

	if blockedOnlyByContent(result, moveProps)
	then
		if not AutoPilotMoon.Options:get("unloadBeforeScrapping")
		then
			skip(object, moveProps, nil);

			return false;
		end

		local plan, reasonKey = planEmptying(square, object, moveProps, player);

		if plan == nil
		then
			skip(object, moveProps, reasonKey);

			return false;
		end

		A.dismantlerPlan = plan;

		return false;
	end

	-- no tools, or the game says no for another reason (something on top, barricaded...): never again in this job
	skip(object, moveProps, nil);

	return false;
end

-- the square function: carries out the step's plan, after checking the zone and the object once more
function AutoPilotMoon.Automation:workDismantlerSquare(square, player)
	local A = AutoPilotMoon.Automation;
	local plan = A.dismantlerPlan;

	A.dismantlerPlan = nil;

	if plan == nil or plan.square ~= square
	then
		return;
	end

	local object = plan.object;

	if AutoPilotMoon.Zones:isProtected(square, player) or AutoPilotMoon.Zones:isProtectedObject(object)
	then
		A:getJobSet("dismantlerTried")[object] = true;

		return;
	end

	if plan.kind == "explore"
	then
		if AutoPilotMoon.Square:walkTo(player, square, true)
		then
			for i, container in ipairs(AutoPilotMoon.Item:getUnloadableContainers(object, player))
			do
				AutoPilotMoon.Item:explore(container, player);
			end
		end

		A:getJobSet("dismantlerExplored")[object] = getTimestampMs();

		-- a locked container stays unexplored: the object is not tried again
		if hasUnexploredContainer(object)
		then
			A:getJobSet("dismantlerTried")[object] = true;
		end

		return;
	end

	if plan.kind == "empty"
	then
		if AutoPilotMoon.Square:walkTo(player, square, true)
		then
			for i, container in ipairs(plan.order)
			do
				A:addJobCount("dismantlerItems", AutoPilotMoon.Item:queueDropToFloor(player, container, plan.groups[container]));
			end

			A.dismantlerEmptying = { object = object, count = plan.count };
		else
			skip(object, plan.moveProps, "IGUI_AutoPilot_A_Reason_CannotEmpty");
		end

		return;
	end

	if plan.kind == "scrap"
	then
		local moveProps = plan.moveProps;

		-- tried once, whatever happens (no retry)
		A:getJobSet("dismantlerTried")[object] = true;
		A.dismantlerEmptying = nil;

		local gridReason = gridProtectionReason(moveProps, square, player);

		if gridReason
		then
			skip(object, moveProps, gridReason);

			return;
		end

		if not moveProps:walkToAndEquip(player, square, "scrap")
		then
			AutoPilotMoon:message(getText("IGUI_AutoPilot_A_ObjectSkipped", objectName(moveProps), getText("IGUI_AutoPilot_A_Reason_NoTools")));

			return;
		end

		-- the game's own menu takes the light bulb out first (ISDisassembleMenu.disassemble)
		if instanceof(object, "IsoLightSwitch") and object:hasLightBulb()
		then
			ISTimedActionQueue.add(ISLightActions:new("RemoveLightBulb", player, object));
		end

		-- the object checked above, never another one with the same sprite (N-A13)
		local direction = moveProps:getFaceDirectionFromSpriteName(moveProps.sprite:getName());

		ISTimedActionQueue.add(ISMoveablesAction:new(player, square, "scrap", nil, object, direction, nil, nil));
		A:addJobCount("dismantlerScrapped");
		A.dismantlerPending = object;

		AutoPilotMoon.Progress:setActivity("IGUI_AutoPilot_P_Now_Dismantling", objectName(moveProps));
	end
end

function AutoPilotMoon.Automation:checkDismantlerQueue(player)
	AutoPilotMoon.Automation:checkSquareProcessingQueue({
		player = player,
		runLockVariable = "dismantlerWorking",
		squareFunction = {
			fn = function(square, who)
				AutoPilotMoon.Automation:workDismantlerSquare(square, who);
			end,
			param1 = player,
		},
		removeCheckFunction = function(square, who)
			return AutoPilotMoon.Automation:checkDismantlerSquare(square, who);
		end,
		stopFunction = function()
			AutoPilotMoon.Automation:stopDismantler();
		end,
	});
end

-- the menu entries "Smonta i mobili" and "Smonta l'elettronica" (client/75_AP_JobMenu.lua): every area mode (spec 5);
-- the tools are taken from the bag by the job itself, so a missing one never greys the entry (spec 2.2 rule 3)

local function scrapFilter(electronics)
	return function(square, player)
		return #AutoPilotMoon.Automation:getDismantlerTiles({ square }, player, electronics) > 0;
	end;
end

local function scrapEntry(id, labelKey, descKey, electronics)
	AutoPilotMoon.JobMenu:define(id, {
		group = "house",
		labelKey = labelKey,
		job = "dismantler",
		descKey = descKey,
		rooms = true,
		icon = "Base.Screwdriver",
		unitKey = "IGUI_AutoPilot_S_Unit_Squares",
		-- "Qui" (spec 2.2 rule 6): a piece of furniture -> "Smonta i mobili" only
		here = (not electronics) and scrapFilter(false) or nil,
		countFn = function(params)
			return scrapFilter(electronics);
		end,
		notes = function(player)
			return { { text = getText("IGUI_AutoPilot_T_TakesFromBag") } };
		end,
		limits = function()
			return { getText("IGUI_AutoPilot_T_JobLimit", title(),
				getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("DismantlerObjectsPerJob"))) };
		end,
		start = function(player, region)
			return AutoPilotMoon.Automation.startDismantler(player, AutoPilotMoon.JobMenu:squaresOf(region), player:getSquare(),
				{ params = { electronics = electronics } });
		end,
	});
end

scrapEntry("scrapFurniture", "IGUI_AutoPilot_M_ScrapFurniture", "IGUI_AutoPilot_T_Desc_ScrapFurniture", false);
scrapEntry("scrapElectronics", "IGUI_AutoPilot_M_ScrapElectronics", "IGUI_AutoPilot_T_Desc_ScrapElectronics", true);
