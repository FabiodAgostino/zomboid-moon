-- AutoPilot (Moon): automations for the Moon server.

-- The right click menu of AutoPilot (spec UX-AUTOPILOT.md 2.2, 3.1, 3.5, 6.3, 6.4), built from data: every job's entry
-- is declared once with JobMenu:define (in the automation's own file) and the whole submenu "AutoPilot" is built by
-- JobMenu:fill(menu, player, worldobjects) (client/99_AP_Event.lua), in a fixed order (phase D, 11/11/2026):
--
--   Qui            the jobs about what was clicked (at most 3, cheap checks of the clicked square only: spec field here)
--   Legna / Terreno / Campi / Casa   headers (JobMenu.groups: the order of the spec), each with its entries
--   Sperimentale   the macros (MACRO-AUTOPILOT.md 5.6: AutoPilotMoon.Macro.Menu, its submenu is not an area)
--   Pannello AutoPilot
--
-- While the player records a macro: "Fine registrazione" and "Annulla registrazione" first, every other entry grey
-- with "Stai registrando una macro" (MACRO-AUTOPILOT.md 3.1).
-- With a job running: only "Ferma: <job> (fase i di n)" and the panel (rule 7). Jobs switched off on the server or
-- hidden by the player do not appear, a header without entries does not appear; nothing on the server: one grey entry
-- that says so (rule 1-2). A header is an option the game draws grey and never runs (isDisabled, no onSelect).
--
-- An entry is the job's verb ("Sega i tronchi") with the area as its submenu (spec 2.2):
--   Scegli un'area...  (the area tool; for a job that carries, then the destination: AreaTool:beginWithDestination)
--   Area piccola / media / grande (7 x 7, 13 x 13, 19 x 19 around the character)
--   Questa stanza / Questo edificio (tutti i piani)   (spec field rooms; grey with the reason outside one)
-- each shown on the ground while it is highlighted (AreaPreview: the square, the room's rectangles, the rectangles of
-- the building's rooms on the character's floor). With variants (Raccogli > Tronchi / Assi / ...) the verb opens the
-- variants, each with the area submenu (4 levels at most).
-- A requirement missing that the job cannot get by itself: the verb is grey (notAvailable: the game draws it in its
-- "bad" colour) with the reason first in the tooltip (rule 3): "<BHC> Serve: una sega", then what the character has in
-- <GHC>, notes, the description, the job and the server's limits, auto-rest on or off. The icon is the tool or the
-- object the job uses: the character's own item (option.itemForTexture, as the game's menus), else the item script's
-- texture (read once and kept), else none.
-- Cost (rule 10): no scan of the area when the menu opens; the tooltip of an entry and its requirements are worked out
-- once per opening (JobMenu:memo, also used by the requirement helpers for the axe and the saw), so the "Qui" copy of an
-- entry costs nothing more.
--
-- spec fields:
--   group        "wood" / "ground" / "fields" / "house"
--   labelKey     the verb ("IGUI_AutoPilot_M_SawLogs"), or label(player, params) -> text ("Insacca: sabbia")
--   job | chain  the automation or the chain the entry starts (Automation:isEnabled / Chain:isEnabled)
--   titleKey     the job's title in "Lavoro: %1" (default: the automation's or the chain's)
--   descKey      the description (T_Desc_*)
--   whatKey      the destination step's title ("IGUI_AutoPilot_D_TitlePlanks") for a job that carries; nil: none
--   onSpot       with whatKey: the picker offers "Sul posto" first (the character's own square; start gets dest = nil),
--                the text key of what happens then ("IGUI_AutoPilot_D_OnSpotPlanks"; the Sawyer, 12/11/2026)
--   countJob     the automation whose squareFilter the area tool counts with (default: job, or the chain's first phase)
--   countFn(params) -> function(square, player)   instead of countJob, when the count depends on the variant
--   unitKey      what the area tool counts (default the counting automation's)
--   requirements(player, params) -> list of { ok = bool, needKey = "IGUI_AutoPilot_T_NeedSaw", haveText = name,
--                item = the character's item (its icon) } (or reasonKey instead of needKey: a whole reason, said
--                without "Serve:"); params is nil for the verb itself (the most permissive check), a variant's params
--                for the variant
--   notes(player, params) -> list of { text, bad = bool }      extra tooltip lines (too dark now...)
--   limits(params) -> list of texts                            the server's limits ("Lavoro: X. Limite del server: ...")
--   menuParams(player) -> params   for an entry without variants: the params its areas start with, worked out when
--                the menu is built (the Soil bagger: the soil of the clicked square, JobMenu.clickedSquare)
--   variants     list of { labelKey | text, params }, or function(player) -> that list (the seeds the character has,
--                "Carote (24)"); a variant whose requirements(player, params) miss something is grey with the reason
--   start(player, rect, dest, params) -> started              rect = AutoPilotMoon.Area:rect, dest = Destination or nil
--   rooms = true  the area submenu also has "Questa stanza" and "Questo edificio (tutti i piani)" (spec 3.1); start then
--                gets a region instead of a rect: { kind = "room", room } or { kind = "building", building }
--                (JobMenu:squaresOf(region) gives its squares)
--   second(params) -> nil | picker options   a second step after the area other than the containers' destination
--                (the corpses' pile, the water source): the options of DestinationPicker:begin (whatKey, inspect,
--                describe, howKey, startAtPlayer, noRemember, toDest); without second, whatKey alone is the destination
--   here         true: the entry goes in "Qui" when the clicked square passes the count filter (countFn(nil), or the
--                countJob's squareFilter); or here(square, player) -> bool; nil: never in "Qui" (rule 6)
--   icon         the full type of the item whose icon the entry shows when no requirement gives the character's item
--                ("Base.Axe"); or icon(player, params) -> an item or a full type

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.JobMenu = AutoPilotMoon.JobMenu or {};

local JobMenu = AutoPilotMoon.JobMenu;

JobMenu.specs = JobMenu.specs or {};
JobMenu.order = JobMenu.order or {};

-- the order of the menu (spec 2.2): fixed, the muscle memory counts more than "relevance". An entry defined later
-- that is not in the list goes at the end of its group, in the order it was defined.
JobMenu.groups = {
	{ id = "wood", headerKey = "IGUI_AutoPilot_M_HeaderWood",
		ids = { "chopTrees", "sawLogs", "firewood", "gather", "woodChain", "chopAndGather" } },
	{ id = "ground", headerKey = "IGUI_AutoPilot_M_HeaderGround",
		ids = { "clear", "clearAndGather", "bagSoil" } },
	{ id = "fields", headerKey = "IGUI_AutoPilot_M_HeaderFields",
		ids = { "digFurrows", "sow", "water", "fertilize", "treat", "harvest", "removePlants" } },
	{ id = "house", headerKey = "IGUI_AutoPilot_M_HeaderHouse",
		ids = { "scrapFurniture", "scrapElectronics", "unload", "pileCorpses" } },
};

JobMenu.maxHere = 3;      -- entries of the "Qui" block (rule 6)

-- the areas of the submenu: the area tool, then the three squares around the character (radius of Area:fromRadius)
JobMenu.radiusKeys = {
	"IGUI_AutoPilot_M_AreaSmall",
	"IGUI_AutoPilot_M_AreaMedium",
	"IGUI_AutoPilot_M_AreaLarge",
};

JobMenu.textures = JobMenu.textures or {};   -- full type -> texture of the item script, or false (read once)
JobMenu.cache = nil;                          -- what one opening of the menu worked out (JobMenu:memo)
JobMenu.clickedSquare = nil;                  -- while the menu is built: the clicked square (JobMenu:getClickedSquare)

function AutoPilotMoon.JobMenu:define(id, spec)
	if JobMenu.specs[id] == nil
	then
		table.insert(JobMenu.order, id);
	end

	spec.id = id;
	JobMenu.specs[id] = spec;

	return spec;
end

-- the entry is offered: its job (or every phase of its chain) on the server, and shown by the player
function AutoPilotMoon.JobMenu:isOffered(spec)
	if spec.chain
	then
		return AutoPilotMoon.Chain:isEnabled(spec.chain);
	end

	return AutoPilotMoon.Automation:isEnabled(spec.job);
end

-- the server allows it (the player's choice aside)
function AutoPilotMoon.JobMenu:isAllowedByServer(spec)
	if spec.chain
	then
		return AutoPilotMoon.Chain:isAllowedByServer(spec.chain);
	end

	return AutoPilotMoon.Automation:isAllowedByServer(spec.job);
end

function AutoPilotMoon.JobMenu:getTitle(spec)
	if spec.titleKey
	then
		return getText(spec.titleKey);
	end

	if spec.chain
	then
		return getText(AutoPilotMoon.Chain.definitions[spec.chain].titleKey);
	end

	return getText(AutoPilotMoon.Automation.definitions[spec.job].titleKey);
end

function AutoPilotMoon.JobMenu:getLabel(spec, player, params)
	if spec.label
	then
		return spec.label(player, params);
	end

	return getText(spec.labelKey);
end

-- the automation whose filter counts in the area tool
local function countJob(spec)
	if spec.countJob
	then
		return spec.countJob;
	end

	if spec.chain
	then
		return AutoPilotMoon.Chain.definitions[spec.chain].phases[1].job;
	end

	return spec.job;
end

-- the filter of the job's count, for one square (the area tool's and the "Qui" block's)
local function countFilter(spec, params)
	if spec.countFn
	then
		return spec.countFn(params);
	end

	local definition = AutoPilotMoon.Automation.definitions[countJob(spec)];

	return definition and definition.squareFilter or nil;
end

-- one opening of the menu: what is worked out once (an entry's tooltip, the character's axe) is kept until the next one

function AutoPilotMoon.JobMenu:beginBuild()
	JobMenu.cache = {};
end

function AutoPilotMoon.JobMenu:endBuild()
	JobMenu.cache = nil;
	JobMenu.clickedSquare = nil;
end

-- fn() once per opening of the menu (outside a menu: every time)
function AutoPilotMoon.JobMenu:memo(key, fn)
	local cache = JobMenu.cache;

	if cache == nil
	then
		return fn();
	end

	local entry = cache[key];

	if entry == nil
	then
		entry = { value = fn() };
		cache[key] = entry;
	end

	return entry.value;
end

-- requirements shared by several entries, looked up once per opening of the menu

function AutoPilotMoon.JobMenu:axeRequirement(player)
	local axe = JobMenu:memo("axe", function()
		return AutoPilotMoon.Item:getBestWoodChoppingAxe(player);
	end);

	return { ok = axe ~= nil, needKey = "IGUI_AutoPilot_T_NeedAxe", haveText = axe and axe:getDisplayName() or nil, item = axe };
end

function AutoPilotMoon.JobMenu:sawRequirement(player)
	local saw = JobMenu:memo("saw", function()
		return AutoPilotMoon.Item:getSaw(player);
	end);

	return { ok = saw ~= nil, needKey = "IGUI_AutoPilot_T_NeedSaw", haveText = saw and saw:getDisplayName() or nil, item = saw };
end

function AutoPilotMoon.JobMenu:shovelRequirement(player)
	local shovel = JobMenu:memo("shovel", function()
		return AutoPilotMoon.Item:getShovel(player);
	end);

	return { ok = shovel ~= nil, needKey = "IGUI_AutoPilot_T_NeedShovel", haveText = shovel and shovel:getDisplayName() or nil, item = shovel };
end

-- tooltips (the game's rich text: <LINE>, <GHC>, <BHC>, <RGB:r,g,b>)

local NORMAL = "<RGB:1,1,1> ";

local function buildTooltip(spec, player, params)
	local lines = {};
	local missing = nil;
	local item = nil;
	local requirements = spec.requirements and spec.requirements(player, params) or {};

	for i, requirement in ipairs(requirements)
	do
		if not requirement.ok and missing == nil
		then
			missing = requirement;
		end
	end

	if missing
	then
		if missing.reasonKey
		then
			-- a reason said as it is ("Nessun seme sfuso: apri prima una bustina")
			table.insert(lines, "<BHC> " .. getText(missing.reasonKey));
		else
			table.insert(lines, "<BHC> " .. getText("IGUI_AutoPilot_T_Needs", getText(missing.needKey)));
		end
	end

	for i, requirement in ipairs(requirements)
	do
		if requirement.ok and requirement.haveText
		then
			table.insert(lines, "<GHC> " .. getText("IGUI_AutoPilot_T_Have", requirement.haveText));
		end

		if requirement.ok and requirement.item and item == nil
		then
			item = requirement.item;
		end
	end

	if spec.notes
	then
		for i, note in ipairs(spec.notes(player, params))
		do
			if note.bad
			then
				table.insert(lines, "<BHC> " .. note.text);
			else
				table.insert(lines, NORMAL .. note.text);
			end
		end
	end

	if spec.descKey
	then
		table.insert(lines, NORMAL .. getText(spec.descKey));
	end

	if spec.whatKey
	then
		table.insert(lines, NORMAL .. getText("IGUI_AutoPilot_T_DestFullFallback"));
	end

	local limits = spec.limits and spec.limits(params) or { getText("IGUI_AutoPilot_T_Job", JobMenu:getTitle(spec)) };

	for i, text in ipairs(limits)
	do
		table.insert(lines, NORMAL .. text);
	end

	if AutoPilotMoon.Rest:isEnabled()
	then
		table.insert(lines, NORMAL .. getText("IGUI_AutoPilot_T_Rest_On"));
	else
		table.insert(lines, NORMAL .. getText("IGUI_AutoPilot_T_Rest_Off"));
	end

	return { text = table.concat(lines, " <LINE> "), missing = missing, item = item };
end

-- the tooltip of an entry, its first missing requirement (nil: everything is there) and the character's item for its
-- icon; once per opening of the menu for the same entry and variant
function AutoPilotMoon.JobMenu:describe(spec, player, params)
	local cache = JobMenu.cache;
	local result = nil;

	if cache
	then
		local bySpec = cache[spec];

		if bySpec == nil
		then
			bySpec = {};
			cache[spec] = bySpec;
		end

		local key = params or bySpec;

		result = bySpec[key];

		if result == nil
		then
			result = buildTooltip(spec, player, params);
			bySpec[key] = result;
		end
	else
		result = buildTooltip(spec, player, params);
	end

	return result.text, result.missing, result.item;
end

local function setTooltip(option, text)
	option.toolTip = ISWorldObjectContextMenu.addToolTip();
	option.toolTip.description = text;
end

-- the texture of an item script (read once and kept; false when the item or its texture is missing)
function AutoPilotMoon.JobMenu:getScriptTexture(fullType)
	local texture = JobMenu.textures[fullType];

	if texture == nil
	then
		local item = getScriptManager():FindItem(fullType);

		texture = item and item:getNormalTexture() or false;
		JobMenu.textures[fullType] = texture;
	end

	return texture or nil;
end

-- the icon of an entry (rule 4): the character's item, else the script's texture, else none
local function setIcon(option, spec, player, params, item)
	local icon = item;

	if icon == nil and spec.icon
	then
		if type(spec.icon) == "function"
		then
			icon = spec.icon(player, params);
		else
			icon = spec.icon;
		end
	end

	if icon == nil
	then
		return;
	end

	if type(icon) == "string"
	then
		option.iconTexture = JobMenu:getScriptTexture(icon);
	else
		option.itemForTexture = icon;
	end
end

-- starting

-- the squares of a region of the menu: a rect (AutoPilotMoon.Area:rect), a room or a building (every floor, cellar
-- included: Grid:getAllSquaresInBuilding); the loaded ones only
function AutoPilotMoon.JobMenu:squaresOf(region)
	if region == nil
	then
		return {};
	end

	if region.kind == "room"
	then
		return AutoPilotMoon.Grid:getAllSquaresInRoom(region.room);
	elseif region.kind == "building"
	then
		return AutoPilotMoon.Grid:getAllSquaresInBuilding(region.building);
	end

	return (AutoPilotMoon.Area:squares(region));
end

-- the rectangles of a room (its RoomDef), on the room's floor
local function addRoomRects(roomDef, rects)
	local list = roomDef and roomDef:getRects();

	if list == nil
	then
		return;
	end

	local z = roomDef:getZ();

	for i = 0, list:size() - 1
	do
		local r = list:get(i);

		table.insert(rects, AutoPilotMoon.Area:rect(r:getX(), r:getY(), r:getX() + r:getW() - 1, r:getY() + r:getH() - 1, z));
	end
end

-- The preview of "Questa stanza" / "Questo edificio" (spec 3.1): the room's rectangles; the building's rooms on the
-- character's floor (the job takes every floor, the preview shows the one the character sees). Worked out when the
-- entry is highlighted, never when the menu opens.
function AutoPilotMoon.JobMenu:regionRects(kind, room, z)
	local rects = {};

	if room == nil
	then
		return rects;
	end

	if kind == "room"
	then
		addRoomRects(room:getRoomDef(), rects);

		return rects;
	end

	local building = room:getBuilding();
	local def = building and building:getDef();
	local rooms = def and def:getRooms();

	if rooms == nil
	then
		return rects;
	end

	for i = 0, rooms:size() - 1
	do
		local roomDef = rooms:get(i);

		if roomDef and roomDef:getZ() == z
		then
			addRoomRects(roomDef, rects);
		end
	end

	return rects;
end

-- starts the entry's job; a rectangle (a radius, a drawn area) is given to the engine to draw on the ground (spec 4.3)
local function startSpec(spec, player, region, dest, params)
	local automation = AutoPilotMoon.Automation;

	if region and region.kind == nil
	then
		automation.startingArea = region;
	end

	local started = spec.start(player, region, dest, params);

	automation.startingArea = nil;

	return started;
end

-- the second step of the entry for these params: the picker's options, or nil (none)
local function secondStep(spec, params)
	if spec.second
	then
		return spec.second(params);
	end

	if spec.whatKey
	then
		return { whatKey = spec.whatKey, onSpot = spec.onSpot };
	end

	return nil;
end

-- after the area: the second step if the entry has one, then the start
function AutoPilotMoon.JobMenu:afterArea(player, spec, region, params)
	local second = secondStep(spec, params);

	if second == nil
	then
		return startSpec(spec, player, region, nil, params);
	end

	local opts = {};

	for k, v in pairs(second)
	do
		opts[k] = v;
	end

	opts.titleText = JobMenu:getLabel(spec, player, params);
	opts.step = true;

	if region and region.kind == nil
	then
		opts.area = region;
	end

	opts.onConfirm = function(dest)
		startSpec(spec, player, region, dest, params);
	end;
	opts.onCancel = function() end;

	return AutoPilotMoon.DestinationPicker:begin(player, opts);
end

-- the area tool (then the destination, for a job that carries)
function AutoPilotMoon.JobMenu.onPickArea(player, id, params)
	local spec = JobMenu.specs[id];

	if spec == nil or player == nil
	then
		return;
	end

	local opts = {
		titleText = JobMenu:getLabel(spec, player, params),
		unitKey = spec.unitKey,
		whatKey = spec.whatKey,
		onSpot = spec.onSpot,
		onCancel = function() end,
	};

	if spec.countFn
	then
		opts.countFn = spec.countFn(params);
		opts.limit = AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob");
		opts.unitKey = opts.unitKey or "IGUI_AutoPilot_S_Unit_Squares";
	else
		opts.jobName = countJob(spec);
	end

	if spec.whatKey and spec.second == nil
	then
		opts.onConfirm = function(rect, dest)
			startSpec(spec, player, rect, dest, params);
		end;

		return AutoPilotMoon.AreaTool:beginWithDestination(player, opts);
	end

	opts.onConfirm = function(rect)
		JobMenu:afterArea(player, spec, rect, params);
	end;

	return AutoPilotMoon.AreaTool:begin(player, opts);
end

-- a square area around the character (then the second step, for a job that has one)
function AutoPilotMoon.JobMenu.onRadius(player, id, radius, params)
	local spec = JobMenu.specs[id];

	if spec == nil or player == nil
	then
		return;
	end

	local rect = AutoPilotMoon.Area:fromRadius(player:getSquare(), radius);

	if rect == nil
	then
		return;
	end

	return JobMenu:afterArea(player, spec, rect, params);
end

-- the room or the building where the character is (then the second step)
function AutoPilotMoon.JobMenu.onRegion(player, id, kind, params)
	local spec = JobMenu.specs[id];
	local square = player and player:getSquare();
	local room = square and square:getRoom();

	if spec == nil or room == nil
	then
		return;
	end

	local region = { kind = "room", room = room };

	if kind == "building"
	then
		local building = room:getBuilding();

		if building == nil
		then
			return;
		end

		region = { kind = "building", building = building };
	end

	return JobMenu:afterArea(player, spec, region, params);
end

-- the submenu of the areas
local function addAreas(menu, player, spec, params)
	AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_AreaPick"), JobMenu.onPickArea, { player, spec.id, params });

	for radius, key in ipairs(JobMenu.radiusKeys)
	do
		local option = AutoPilotMoon:addContextMenuItem(menu, getText(key), JobMenu.onRadius, { player, spec.id, radius, params });

		AutoPilotMoon.AreaPreview:attach(option, function()
			return AutoPilotMoon.Area:fromRadius(player:getSquare(), radius);
		end);
	end

	if spec.rooms
	then
		local square = player:getSquare();
		local room = square and square:getRoom();
		local building = room and room:getBuilding();
		local z = square and square:getZ() or 0;

		if room
		then
			local option = AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_AreaRoom"), JobMenu.onRegion, { player, spec.id, "room", params });

			AutoPilotMoon.AreaPreview:attach(option, function()
				return JobMenu:regionRects("room", room, z);
			end);
		else
			AutoPilotMoon:addDisabledContextMenuItem(menu, getText("IGUI_AutoPilot_M_AreaRoom"), "<BHC> " .. getText("IGUI_AutoPilot_A_NotInRoom"));
		end

		if building
		then
			local option = AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_AreaBuilding"), JobMenu.onRegion, { player, spec.id, "building", params });

			AutoPilotMoon.AreaPreview:attach(option, function()
				return JobMenu:regionRects("building", room, z);
			end);
		else
			AutoPilotMoon:addDisabledContextMenuItem(menu, getText("IGUI_AutoPilot_M_AreaBuilding"), "<BHC> " .. getText("IGUI_AutoPilot_A_NotInBuilding"));
		end
	end
end

-- the variants of an entry (a list, or a function of the character)
function AutoPilotMoon.JobMenu:getVariants(spec, player)
	if spec.variants == nil
	then
		return nil;
	end

	if type(spec.variants) == "function"
	then
		return JobMenu:memo("variants:" .. spec.id, function()
			return spec.variants(player) or {};
		end);
	end

	return spec.variants;
end

local function variantLabel(variant)
	if variant.text
	then
		return variant.text;
	end

	return getText(variant.labelKey);
end

-- Builds the entry id in context (nothing when it is not offered). Returns the option of the verb, or nil.
function AutoPilotMoon.JobMenu:add(context, player, id)
	local spec = JobMenu.specs[id];

	if spec == nil or player == nil or not JobMenu:isOffered(spec)
	then
		return nil;
	end

	local label = JobMenu:getLabel(spec, player);
	local tip, missing, item = JobMenu:describe(spec, player, nil);

	if missing
	then
		local option = AutoPilotMoon:addDisabledContextMenuItem(context, label, tip);

		setIcon(option, spec, player, nil, nil);

		return option;
	end

	local menu, option = AutoPilotMoon:addContextMenuSubMenu(context, label);

	setTooltip(option, tip);
	setIcon(option, spec, player, nil, item);

	local variants = JobMenu:getVariants(spec, player);

	if variants
	then
		for i, variant in ipairs(variants)
		do
			local variantTip, variantMissing, variantItem = JobMenu:describe(spec, player, variant.params);

			if variantMissing
			then
				AutoPilotMoon:addDisabledContextMenuItem(menu, variantLabel(variant), variantTip);
			else
				local variantMenu, variantOption = AutoPilotMoon:addContextMenuSubMenu(menu, variantLabel(variant));

				setTooltip(variantOption, variantTip);
				setIcon(variantOption, spec, player, variant.params, variantItem);
				addAreas(variantMenu, player, spec, variant.params);
			end
		end
	else
		addAreas(menu, player, spec, spec.menuParams and spec.menuParams(player) or nil);
	end

	return option;
end

-- ============================================================================================================
-- The whole submenu "AutoPilot" (spec 2.2)
-- ============================================================================================================

-- the ids of a group in the menu's order: the spec's list, then the ones defined later for that group
function AutoPilotMoon.JobMenu:getGroupIds(group)
	local ids = {};
	local seen = {};

	for i, id in ipairs(group.ids)
	do
		if JobMenu.specs[id]
		then
			table.insert(ids, id);
			seen[id] = true;
		end
	end

	for i, id in ipairs(JobMenu.order)
	do
		if not seen[id] and JobMenu.specs[id].group == group.id
		then
			table.insert(ids, id);
			seen[id] = true;
		end
	end

	return ids;
end

-- the clicked square: the one of the first object the game passed, else the character's
function AutoPilotMoon.JobMenu:getClickedSquare(worldobjects, player)
	if worldobjects
	then
		for i, object in ipairs(worldobjects)
		do
			local square = object and object:getSquare();

			if square
			then
				return square;
			end
		end
	end

	return nil;
end

-- the entry is about what is on the square (rule 6): its own here(), or the job's count filter
local function isHere(spec, square, player)
	if spec.here == nil
	then
		return false;
	end

	if type(spec.here) == "function"
	then
		return spec.here(square, player) == true;
	end

	local filter = countFilter(spec, nil);

	return filter ~= nil and filter(square, player) == true;
end

-- the "Qui" entries for the clicked square: at most JobMenu.maxHere, in the menu's order, offered ones only
function AutoPilotMoon.JobMenu:getHereIds(square, player)
	local ids = {};

	if square == nil
	then
		return ids;
	end

	for i, group in ipairs(JobMenu.groups)
	do
		for j, id in ipairs(JobMenu:getGroupIds(group))
		do
			local spec = JobMenu.specs[id];

			if #ids < JobMenu.maxHere and JobMenu:isOffered(spec) and isHere(spec, square, player)
			then
				table.insert(ids, id);
			end
		end
	end

	return ids;
end

-- the panel entry (from the menu: with a controller the panel takes the focus, spec 2.3)
function AutoPilotMoon.JobMenu.onPanel(player)
	if player and AutoPilotMoon.Panel
	then
		AutoPilotMoon.Panel:toggle(player:getPlayerNum(), true);
	end
end

function AutoPilotMoon.JobMenu.onStop()
	AutoPilotMoon.Automation:stopAll("user");
end

-- the stop entry's text: "Ferma: Catena legna (fase 2 di 3)"
function AutoPilotMoon.JobMenu:getStopText()
	local state = AutoPilotMoon.Progress.state;
	local title = nil;
	local job = AutoPilotMoon.Automation.job;
	local chainRun = AutoPilotMoon.Chain.current;

	if chainRun
	then
		title = getText(chainRun.definition.titleKey);
	elseif job and state.running and state.titleText
	then
		-- a job that words its own title ("Macro: Manutenzione - martelli")
		title = state.titleText;
	elseif job
	then
		title = AutoPilotMoon.Automation:getTitle(job.definition);
	else
		title = state.titleKey and getText(state.titleKey) or "";
	end

	if chainRun and state.running and state.kind == "chain" and state.phase > 0
	then
		return getText("IGUI_AutoPilot_M_StopPhase", title, state.phase, state.phaseCount);
	end

	return getText("IGUI_AutoPilot_M_Stop", title);
end

-- any job the server allows (a chain needs all its phases: its phases are jobs too)
function AutoPilotMoon.JobMenu:isAnyAllowedByServer()
	for i, id in ipairs(JobMenu.order)
	do
		if JobMenu:isAllowedByServer(JobMenu.specs[id])
		then
			return true;
		end
	end

	return false;
end

local function addPanelEntry(menu, player)
	return AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_Panel"), JobMenu.onPanel, { player });
end

-- Fills the submenu "AutoPilot" for the player (worldobjects: what the game passed to its menu event, for "Qui").
function AutoPilotMoon.JobMenu:fill(menu, player, worldobjects)
	JobMenu:beginBuild();
	JobMenu.clickedSquare = JobMenu:getClickedSquare(worldobjects, player);

	if AutoPilotMoon.Automation:isBusy()
	then
		-- rule 7: one job at a time, the stop comes first
		local stop = AutoPilotMoon:addContextMenuItem(menu, JobMenu:getStopText(), JobMenu.onStop);

		setTooltip(stop, getText("IGUI_AutoPilot_M_Stop_Tooltip"));
		addPanelEntry(menu, player);
		JobMenu:endBuild();

		return;
	end

	local Macro = AutoPilotMoon.Macro;
	local recording = Macro.Menu:addRecording(menu, player);
	local firstGrey = #menu.options + 1;

	if menu.numOptions
	then
		firstGrey = menu.numOptions;
	end

	if player:getVehicle() == nil
	then
		local anyJob = JobMenu:isAnyAllowedByServer();

		if not anyJob and not AutoPilotMoon.Automation:isAllowedByServer("macro")
		then
			-- rule 1: the player can do nothing about it, but knows why the list is empty
			AutoPilotMoon:addDisabledContextMenuItem(menu, getText("IGUI_AutoPilot_M_NoneOnServer"), getText("IGUI_AutoPilot_M_NoneOnServer_Tooltip"));
		else
			local hereIds = anyJob and JobMenu:getHereIds(JobMenu.clickedSquare, player) or {};

			if #hereIds > 0
			then
				AutoPilotMoon:addContextMenuHeader(menu, getText("IGUI_AutoPilot_M_HeaderHere"));

				for i, id in ipairs(hereIds)
				do
					JobMenu:add(menu, player, id);
				end
			end

			for i, group in ipairs(JobMenu.groups)
			do
				local header = nil;

				for j, id in ipairs(JobMenu:getGroupIds(group))
				do
					if JobMenu:isOffered(JobMenu.specs[id])
					then
						-- rule 2: a header only above at least one entry
						if header == nil
						then
							header = AutoPilotMoon:addContextMenuHeader(menu, getText(group.headerKey));
						end

						JobMenu:add(menu, player, id);
					end
				end
			end

			-- the experimental macros, at the end of the list
			Macro.Menu:addSection(menu, player);
		end
	end

	local panel = addPanelEntry(menu, player);

	if recording
	then
		Macro.Menu:greyFrom(menu, firstGrey, panel);
	end

	JobMenu:endBuild();
end
