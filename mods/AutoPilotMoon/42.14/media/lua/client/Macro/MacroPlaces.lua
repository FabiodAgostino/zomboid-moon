-- AutoPilot (Moon): automations for the Moon server.

-- The named places of a macro (waves 2 and 3 of the work skills, 19/11/2026, MACRO-AUTOPILOT.md 14, decided with the
-- proposals of ANALISI-API-MACRO-LAVORATIVE.md 3.3 and 3.4): "Cassa forgia" is a container (or a square of ground) the
-- player marks with a click from the editor (Inserisci > Oggetti e posti > Segna un posto: the destination picker of the jobs,
-- AutoPilotMoon.DestinationPicker), then names. The macro keeps its coordinates and kind, as a job keeps a destination
-- (AutoPilotMoon.Destination), never a game object; the places belong to the macro (saved with it in the macros'
-- file, "=== posto:" lines; copied with it; a duplicate gets them too).
--   place = { name, kind = "container" | "ground", x, y, z }
-- A place is resolved to its live containers when it is used (Places:resolve: Destination:resolve, the same checks as
-- a trip's destination: a container locked for the character, a ZomBOT gravestone, a safehouse the character may not
-- use are never used); the distance from where the macro starts is at most MacroPlaceRadius squares (any floor), else
-- the macro does not start. Never a vehicle: it moves (a trunk is a destination of the jobs, not a place of a macro).
-- Switch EnableMacroTransfers of the server (shared with take, put, drop, equip, walk_to), read at the moment.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Places = AutoPilotMoon.Macro.Places or {};

local Places = AutoPilotMoon.Macro.Places;

Places.maxPlaces = 20;        -- places of one macro
Places.maxNameChars = 40;
Places.linePrefix = "=== posto: ";

function AutoPilotMoon.Macro.Places:isEnabled()
	return AutoPilotMoon.Sandbox:getBoolean("EnableMacroTransfers");
end

function AutoPilotMoon.Macro.Places:radius()
	return AutoPilotMoon.Sandbox:getInteger("MacroPlaceRadius");
end

-- the key of a name: trimmed, lower case (a place is found in any case, as the rest of the language)
function AutoPilotMoon.Macro.Places:key(name)
	return string.lower(AutoPilotMoon.Macro.Lang.trim(name or ""));
end

-- the places of a macro (a list, created when missing)
function AutoPilotMoon.Macro.Places:list(macro)
	if macro == nil
	then
		return {};
	end

	if macro.places == nil
	then
		macro.places = {};
	end

	return macro.places;
end

-- the places of a macro by key, for the checker (Lang:check opts.places); an example has none
function AutoPilotMoon.Macro.Places:map(macro)
	local map = {};

	for i, place in ipairs(macro and macro.places or {})
	do
		map[Places:key(place.name)] = place;
	end

	return map;
end

function AutoPilotMoon.Macro.Places:get(macro, name)
	local key = Places:key(name);

	for i, place in ipairs(macro and macro.places or {})
	do
		if Places:key(place.name) == key
		then
			return place;
		end
	end

	return nil;
end

-- a name a place may have: 1-40 characters, no quotes (it is written between quotes in the text), not another
-- place's name of the same macro (current: the place being renamed)
function AutoPilotMoon.Macro.Places:isValidName(macro, name, current)
	local trimmed = AutoPilotMoon.Macro.Lang.trim(name or "");

	if trimmed == "" or string.len(trimmed) > Places.maxNameChars or string.find(trimmed, "[\"'\\]")
	then
		return false;
	end

	local other = Places:get(macro, trimmed);

	return other == nil or other == current;
end

-- a free name from wanted: "Cassa di legno", then "Cassa di legno 2"...
function AutoPilotMoon.Macro.Places:freeName(macro, wanted)
	local base = AutoPilotMoon.Macro.Lang.trim(string.gsub(wanted or "", "[\"'\\]", ""));

	if base == ""
	then
		base = getText("IGUI_AutoPilot_E_PlaceDefault");
	end

	if string.len(base) > Places.maxNameChars - 3
	then
		base = string.sub(base, 1, Places.maxNameChars - 3);
	end

	if Places:get(macro, base) == nil
	then
		return base;
	end

	for n = 2, 99
	do
		local name = base .. " " .. n;

		if Places:get(macro, name) == nil
		then
			return name;
		end
	end

	return base;
end

-- a new place from what the picker chose (Places:fromInfo); nil, "full" with Places.maxPlaces
function AutoPilotMoon.Macro.Places:add(macro, name, spot)
	local list = Places:list(macro);

	if #list >= Places.maxPlaces
	then
		return nil, "full";
	end

	local place = { name = Places:freeName(macro, name), kind = spot.kind, x = spot.x, y = spot.y, z = spot.z };

	table.insert(list, place);

	return place;
end

function AutoPilotMoon.Macro.Places:rename(macro, place, name)
	if not Places:isValidName(macro, name, place)
	then
		return false;
	end

	place.name = AutoPilotMoon.Macro.Lang.trim(name);

	return true;
end

-- marked again somewhere else: the same name, the new square
function AutoPilotMoon.Macro.Places:move(place, spot)
	place.kind, place.x, place.y, place.z = spot.kind, spot.x, spot.y, spot.z;
end

function AutoPilotMoon.Macro.Places:remove(macro, place)
	local list = Places:list(macro);

	for i = #list, 1, -1
	do
		if list[i] == place
		then
			table.remove(list, i);

			return true;
		end
	end

	return false;
end

-- a copy of the places of a macro (a duplicate)
function AutoPilotMoon.Macro.Places:copy(places)
	local copy = {};

	for i, place in ipairs(places or {})
	do
		table.insert(copy, { name = place.name, kind = place.kind, x = place.x, y = place.y, z = place.z });
	end

	return copy;
end

-- ============================================================================================================
-- The file: one line per place, "=== posto: container 10567 9876 0 Cassa forgia"
-- ============================================================================================================

function AutoPilotMoon.Macro.Places:formatLine(place)
	return Places.linePrefix .. place.kind .. " " .. place.x .. " " .. place.y .. " " .. place.z .. " " .. place.name;
end

-- a place from a line of the file, or nil (a line that does not read is dropped)
function AutoPilotMoon.Macro.Places:parseLine(line)
	local kind, x, y, z, name = string.match(line or "", "^=== posto: (%a+) (%-?%d+) (%-?%d+) (%-?%d+) (.+)$");

	if kind == nil or (kind ~= "container" and kind ~= "ground")
	then
		return nil;
	end

	name = AutoPilotMoon.Macro.Lang.trim(name);

	if name == "" or string.len(name) > Places.maxNameChars or string.find(name, "[\"'\\]")
	then
		return nil;
	end

	return { name = name, kind = kind, x = tonumber(x), y = tonumber(y), z = tonumber(z) };
end

-- ============================================================================================================
-- Where a place is
-- ============================================================================================================

-- squares between the place and a point (any floor: the forge upstairs, the crate in the cellar)
function AutoPilotMoon.Macro.Places:distance(place, center)
	if place == nil or center == nil
	then
		return 0;
	end

	local dx = place.x - center.x;
	local dy = place.y - center.y;

	return math.floor(math.sqrt(dx * dx + dy * dy) + 0.5);
end

-- within MacroPlaceRadius of the point
function AutoPilotMoon.Macro.Places:isInRange(place, center)
	return Places:distance(place, center) <= Places:radius();
end

-- the place as a destination of the jobs (AutoPilotMoon.Destination: coordinates and kind)
function AutoPilotMoon.Macro.Places:dest(place)
	return { kind = place.kind, x = place.x, y = place.y, z = place.z, nameText = place.name };
end

-- The live side of a place: { square, containers, objects } or nil and the reason key of a stop
-- ("IGUI_AutoPilot_A_MacroR_PlaceProtected", "..._PlaceLocked", "..._PlaceGone", "..._PlaceUnreachable"): a safehouse
-- the character may not use, every container locked for the character, no container any more (or a ZomBOT
-- gravestone), a square of ground that cannot be stood on.
function AutoPilotMoon.Macro.Places:resolve(place, player)
	local cell = getCell();
	local square = cell and cell:getGridSquare(place.x, place.y, place.z);

	if square == nil
	then
		return nil, "IGUI_AutoPilot_A_MacroR_PlaceUnreachable";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return nil, "IGUI_AutoPilot_A_MacroR_PlaceProtected";
	end

	local resolved, reasonKey = AutoPilotMoon.Destination:resolve(Places:dest(place), player);

	if resolved == nil
	then
		if reasonKey == "IGUI_AutoPilot_A_Reason_DestLocked"
		then
			return nil, "IGUI_AutoPilot_A_MacroR_PlaceLocked";
		elseif reasonKey == "IGUI_AutoPilot_A_Reason_DestUnreachable"
		then
			return nil, "IGUI_AutoPilot_A_MacroR_PlaceUnreachable";
		end

		return nil, "IGUI_AutoPilot_A_MacroR_PlaceGone";
	end

	return resolved, nil;
end

-- the name of what the place holds, for the editor's list: "cassa" / "a terra"
function AutoPilotMoon.Macro.Places:kindText(place)
	return getText(place.kind == "ground" and "IGUI_AutoPilot_E_PlaceGround" or "IGUI_AutoPilot_E_PlaceContainer");
end

-- the editor's line of a place: "Cassa forgia (cassa, 4 caselle)"
function AutoPilotMoon.Macro.Places:describe(place, player)
	local square = player and player:getSquare();
	local center = square and { x = square:getX(), y = square:getY(), z = square:getZ() } or nil;

	return getText("IGUI_AutoPilot_E_PlaceLine", place.name, Places:kindText(place), Places:distance(place, center));
end

-- ============================================================================================================
-- Marking a place: the destination picker of the jobs, a container or a square of ground
-- ============================================================================================================

-- what the picker shows under the cursor: a container (full is fine: a place to take from), a square of ground; never
-- a vehicle (it moves), never what a destination refuses (locked, a gravestone, a safehouse, water, not walkable)
function AutoPilotMoon.Macro.Places:inspect(square, player)
	local info = AutoPilotMoon.Destination:inspect(square, player);

	if info == nil
	then
		return nil;
	end

	if info.kind == "vehicle"
	then
		-- not the picker's "vehicle" (its warning about the trunk is for the jobs)
		info.kind = "moving";
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_PlaceMoves";
		info.object = nil;
	elseif info.reasonKey == "IGUI_AutoPilot_D_Bad_Full"
	then
		info.ok, info.reasonKey = true, nil;
	end

	return info;
end

-- the place's square and kind from what the picker chose
function AutoPilotMoon.Macro.Places:fromInfo(info)
	return { kind = info.kind == "ground" and "ground" or "container", x = info.x, y = info.y, z = info.z,
		nameText = info.nameText };
end

-- Opens the picker for a place: onConfirm(spot, info) with spot = { kind, x, y, z, nameText }; onCancel()
function AutoPilotMoon.Macro.Places:pick(player, titleText, onConfirm, onCancel)
	return AutoPilotMoon.DestinationPicker:begin(player, {
		titleText = titleText,
		whatKey = "IGUI_AutoPilot_D_TitlePlace",
		howKey = "IGUI_AutoPilot_D_HowPlace",
		startAtPlayer = true,
		noRemember = true,
		inspect = function(square, who)
			return Places:inspect(square, who);
		end,
		toDest = function(info)
			return Places:fromInfo(info);
		end,
		describe = function(info)
			if info.kind == "moving"
			then
				return info.nameText;
			end

			return AutoPilotMoon.Destination:describe(info);
		end,
		onConfirm = function(spot, info)
			if onConfirm
			then
				onConfirm(spot, info);
			end
		end,
		onCancel = function()
			if onCancel
			then
				onCancel();
			end
		end,
	});
end
