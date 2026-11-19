-- AutoPilot (Moon): automations for the Moon server.

-- The workbenches of the macros (wave 1 of the work skills, 13/11/2026, MACRO-AUTOPILOT.md 13, decided with the
-- proposals of ANALISI-API-MACRO-LAVORATIVE.md 3.2 and 6): a recipe of a forge, a furnace, a pottery wheel, a kiln...
-- done as by hand with the bench's window, without opening it:
--   1. the bench: the nearest one that does the recipe within MacroBenchRadius squares of the place where the macro
--      started (same floor; the master object of a bench on more squares, as the game's context menu takes it:
--      IsoObject.getMasterObject; never on a safehouse square the player may not use, Zones:isProtected);
--   2. another player using it (ISEntityUI.CanPlayerUseEntity of 42.22: getUsingPlayer not this player): the macro
--      waits Bench.busyWaitMs (30 s, decision Q6), then stops with the reason and the name;
--   3. the walk: ISEntityUI.WalkToEntity (luautils.walkAdj next to the bench) when the character is farther than the
--      window allows (ISBaseEntityWindow.panelCloseDistance = 4: the window closes itself farther than that);
--   4. ISEntityUI.CanOpenWindowFor (the window could be opened now: power for the coffee machine, the UI enabled...);
--   5. "in use by me": entity:setUsingPlayer(player), as the window does when it opens (GameEntity.setUsingPlayer of
--      the jar sends it to the server by itself); then the recipe (Craft:queueAtBench);
--   6. released (setUsingPlayer(nil), as the window does when it closes, and only when the bench is still ours) when
--      the macro ends or stops for any reason (Automation:stopMacro), goes to another bench, or does an action that is
--      not at a bench (a rest, a meal, a recipe by hand).
-- Switch EnableMacroBenches of the server, read at every step.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Bench = AutoPilotMoon.Macro.Bench or {};

local Bench = AutoPilotMoon.Macro.Bench;

Bench.closeDistance = 4;      -- the bench window's panelCloseDistance (ISBaseEntityWindow 42.22)
Bench.walkDistance = 2;       -- ISEntityUI.WalkToEntity's distance: walk when farther (squares, as the game counts)
Bench.busyWaitMs = 30000;     -- another player at the bench: wait this long, then stop (decision Q6)

local function Names()
	return AutoPilotMoon.Macro.Names;
end

function AutoPilotMoon.Macro.Bench:isEnabled()
	return AutoPilotMoon.Sandbox:getBoolean("EnableMacroBenches");
end

function AutoPilotMoon.Macro.Bench:radius()
	return AutoPilotMoon.Sandbox:getInteger("MacroBenchRadius");
end

local function benchIdOf(object)
	local script = object:getEntityScript();

	return script and script:getName() or nil;
end

-- the bench's type: its entity's script name ("Forge_Primitive_Forge"), nil for an object that is not a bench
function AutoPilotMoon.Macro.Bench:idOf(object)
	local ok, id = pcall(benchIdOf, object);

	return ok and id or nil;
end

-- the master object of an object (IsoObject.getMasterObject, as the game's context menu takes it) and its CraftBench,
-- or nil (read through pcall: any object of a square is looked at)
local function benchOf(object)
	local master = object:getMasterObject() or object;

	if not master:hasComponent(ComponentType.CraftBench)
	then
		return master, nil;
	end

	return master, master:getComponent(ComponentType.CraftBench);
end

-- the name the bench's window shows ("Forgia primitiva"); the name of its type when the game has none
function AutoPilotMoon.Macro.Bench:nameOf(object, id)
	local ok, text = pcall(function()
		return object:getEntityDisplayName();
	end);

	if ok and text and text ~= "" and text ~= GameEntity.getDefaultEntityDisplayName()
	then
		return text;
	end

	return Names():benchText(id or Bench:idOf(object) or "?");
end

-- the player using the bench who is not this one (nil: free or ours): ISEntityUI.CanPlayerUseEntity's test
function AutoPilotMoon.Macro.Bench:otherUser(object, player)
	local user = object:getUsingPlayer();

	if user ~= nil and user ~= player
	then
		return user;
	end

	return nil;
end

-- the name of a player as the game shows it
function AutoPilotMoon.Macro.Bench:playerName(user)
	local ok, name = pcall(function()
		return user:getDisplayName();
	end);

	if ok and name and name ~= ""
	then
		return name;
	end

	ok, name = pcall(function()
		return user:getUsername();
	end);

	return ok and name or "?";
end

-- the bench in the world does the recipe: its own recipes (CraftBench.getRecipes of 42.22), for a bench the scripts'
-- index does not know
local function liveFits(component, recipe)
	local list = component:getRecipes();
	local name = recipe:getName();

	for i = 0, list:size() - 1
	do
		if list:get(i):getName() == name
		then
			return true;
		end
	end

	return false;
end

-- the bench fits: its type among ids (a set; nil = any) and it does one of the recipes (nil = any)
local function fits(id, component, ids, recipes)
	if id == nil or (ids and not ids[id])
	then
		return false;
	end

	if recipes == nil
	then
		return true;
	end

	local known = Names():bench(id) ~= nil;

	for i, recipe in ipairs(recipes)
	do
		if known
		then
			if Names():benchFits(id, recipe)
			then
				return true;
			end
		else
			local ok, yes = pcall(liveFits, component, recipe);

			if ok and yes
			then
				return true;
			end
		end
	end

	return false;
end

-- The benches around center ({ x, y, z }, the macro's start) within the server's radius, same floor, that fit (ids: a
-- set of bench ids or nil; recipes: a list or nil), nearest to the player first: { object, component, id, distance }.
-- A bench on several squares counts once (its master object).
function AutoPilotMoon.Macro.Bench:find(player, center, ids, recipes)
	local found = {};
	local seen = {};
	local cell = getCell();
	local radius = Bench:radius();

	if cell == nil or center == nil
	then
		return found;
	end

	for x = center.x - radius, center.x + radius
	do
		for y = center.y - radius, center.y + radius
		do
			local square = cell:getGridSquare(x, y, center.z);
			local objects = square and square:getObjects();

			if objects and not AutoPilotMoon.Zones:isProtected(square, player)
			then
				for i = 0, objects:size() - 1
				do
					local object = objects:get(i);
					local ok, master, component = false, nil, nil;

					if object
					then
						ok, master, component = pcall(benchOf, object);
					end

					if ok and component and not seen[master]
					then
						seen[master] = true;

						local id = Bench:idOf(master);

						if fits(id, component, ids, recipes)
						then
							table.insert(found, { object = master, component = component, id = id,
								distance = player:DistToProper(master) });
						end
					end
				end
			end
		end
	end

	table.sort(found, function(a, b)
		return a.distance < b.distance;
	end);

	return found;
end

-- the first free bench of a list (not used by another player), else nil and the first one's user
function AutoPilotMoon.Macro.Bench:firstFree(list, player)
	for i, bench in ipairs(list)
	do
		if Bench:otherUser(bench.object, player) == nil
		then
			return bench, nil;
		end
	end

	return nil, list[1] and Bench:otherUser(list[1].object, player) or nil;
end

-- bench_free("Forge"): a bench of those types within the radius that no other player is using
function AutoPilotMoon.Macro.Bench:isFree(player, center, ids)
	local set = {};

	for i, id in ipairs(ids)
	do
		set[id] = true;
	end

	return (Bench:firstFree(Bench:find(player, center, set, nil), player)) ~= nil;
end

-- the character is near enough to work at it (the window would stay open)
function AutoPilotMoon.Macro.Bench:isNear(player, object)
	return player:DistToProper(object) <= Bench.closeDistance;
end

-- "in use by me", as the window does when it opens (the previous bench of the run released first)
function AutoPilotMoon.Macro.Bench:hold(run, object)
	if run.bench and run.bench ~= object
	then
		Bench:release(run);
	end

	if object:getUsingPlayer() ~= run.player
	then
		object:setUsingPlayer(run.player);
	end

	run.bench = object;
end

-- the run's bench released, as the window does when it closes; only when it is still ours
function AutoPilotMoon.Macro.Bench:release(run)
	local object = run and run.bench;

	if object == nil
	then
		return;
	end

	run.bench = nil;

	pcall(function()
		if object:getUsingPlayer() == run.player
		then
			object:setUsingPlayer(nil);
		end
	end);
end

-- the benches' words of an op for the messages: at= as written, else the names of the benches of its recipes
function AutoPilotMoon.Macro.Bench:opText(op)
	if op.benchText
	then
		return op.benchText;
	end

	local names = {};
	local seen = {};

	for i, recipe in ipairs(op.recipes or {})
	do
		for j, bench in ipairs(Names():benchesFor(recipe))
		do
			if not seen[bench.text] and #names < 2
			then
				seen[bench.text] = true;
				table.insert(names, bench.text);
			end
		end
	end

	if #names == 2
	then
		return getText("IGUI_AutoPilot_E_Or", names[1], names[2]);
	end

	return names[1] or "?";
end
