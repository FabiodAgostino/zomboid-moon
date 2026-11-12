-- AutoPilot (Moon): automations for the Moon server.

-- Destinations of the jobs that carry things (11/11/2026, spec UX-AUTOPILOT.md 3.5): a world container (crates, shelves,
-- stacked crates filled from the bottom), a vehicle's part with a container (trunk, truck bed, trailer) or the ground.
-- As by hand: any container the character may use, also somebody else's; never one locked for the character, never a
-- ZomBOT gravestone, never in a safehouse the character may not use.
--
-- A destination is kept as coordinates and ids, never as game objects (spec 7.3.7):
--   { kind = "container" | "vehicle" | "ground", x, y, z, vehicleId, partId, vx, vy (where the vehicle was) }
-- and resolved to the live containers when it is used (Destination:resolve), checked again before every trip
-- (Destination:validate, spec 3.5 "continuous check").

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Destination = AutoPilotMoon.Destination or {};

local D = AutoPilotMoon.Destination;

D.lastMaxDistance = 40;    -- the last destination is offered again when it is this close (spec 3.5)
D.vehicleMoveTolerance = 1; -- squares a vehicle may have moved before it counts as moved
D.last = nil;              -- { x, y, z } of the last destination chosen in this session

-- the containers of a square

-- the usable containers of the world objects of a square, in the objects' order (stacked crates: the bottom one
-- first), as { object, container }; and the reason when there are containers but none usable
-- ("IGUI_AutoPilot_D_Bad_Locked" / "IGUI_AutoPilot_D_Bad_Grave")
function AutoPilotMoon.Destination:getSquareContainers(square, player)
	local result = {};
	local badKey = nil;

	if square == nil
	then
		return result, nil;
	end

	local objects = square:getObjects();

	for i = 0, objects:size() - 1
	do
		local object = objects:get(i);

		if object and not instanceof(object, "IsoWorldInventoryObject") and object:getContainerCount() > 0
		then
			if AutoPilotMoon.Zones:isProtectedObject(object)
			then
				badKey = "IGUI_AutoPilot_D_Bad_Grave";
			else
				for j, container in ipairs(AutoPilotMoon.Item:getAllObjectContainers(object))
				do
					if AutoPilotMoon.Item:isLockedFor(object, container, player)
					then
						badKey = badKey or "IGUI_AutoPilot_D_Bad_Locked";
					else
						table.insert(result, { object = object, container = container });
					end
				end
			end
		end
	end

	return result, badKey;
end

-- the name of a world container as in the loot window
function AutoPilotMoon.Destination:getContainerName(container)
	return getTextOrNull("IGUI_ContainerTitle_" .. container:getType())
		or getTextOrNull("IGUI_ContainerTitle_" .. tostring(container:getDisplayType()))
		or container:getType();
end

-- vehicles

-- the part with a container nearest to the square (x, y) and its index, or nil
function AutoPilotMoon.Destination:getNearestVehiclePart(vehicle, x, y)
	local best = nil;
	local bestIndex = nil;
	local bestDistance = nil;

	for i = 0, vehicle:getPartCount() - 1
	do
		local part = vehicle:getPartByIndex(i);

		if part and part:getItemContainer() and not part:isInventoryItemUninstalled() and part:getArea()
		then
			local center = vehicle:getAreaCenter(part:getArea());

			if center
			then
				local dx = center:getX() - (x + 0.5);
				local dy = center:getY() - (y + 0.5);
				local distance = dx * dx + dy * dy;

				if bestDistance == nil or distance < bestDistance
				then
					best = part;
					bestIndex = i;
					bestDistance = distance;
				end
			end
		end
	end

	return best, bestIndex;
end

-- the door that closes a part's container: the trunk's for the truck bed (as Vehicles.ContainerAccess.TruckBed), else
-- the part's own door
local function containerDoor(vehicle, part)
	local id = part:getId() or "";

	if string.find(id, "TruckBed", 1, true) == 1
	then
		return vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear") or vehicle:getPartById("TrunkDoorOpened");
	end

	if part:getDoor()
	then
		return part;
	end

	return nil;
end

-- locked for the character: its door is installed and locked (a closed, unlocked door is opened by the trip, as by hand)
function AutoPilotMoon.Destination:isVehiclePartLocked(vehicle, part)
	local door = containerDoor(vehicle, part);

	return door ~= nil and door:getDoor() ~= nil and door:getInventoryItem() ~= nil and door:getDoor():isLocked();
end

-- the door to open before using the part, when it is closed (nil: nothing to open)
function AutoPilotMoon.Destination:getClosedDoor(vehicle, part)
	local door = containerDoor(vehicle, part);

	if door and door:getDoor() and door:getInventoryItem() and not door:getDoor():isOpen()
	then
		return door;
	end

	return nil;
end

function AutoPilotMoon.Destination:getVehicleName(vehicle)
	local script = vehicle:getScript();
	local name = script and (script:getCarModelName() or script:getName());

	if name == nil
	then
		return "";
	end

	return getTextOrNull("IGUI_VehicleName" .. name) or name;
end

-- inspecting a square (the picker)

-- What the square offers as a destination, for the picker's box and colours (spec 3.5):
--   { ok, kind, x, y, z, reasonKey (D_Bad_*, when not ok), nameText, weight, capacity, count (containers),
--     vehicleName, vehicleId, partId, vx, vy, object (the first container's object or the vehicle, outlined while the
--     cursor is on it) }
-- nil without a square.
function AutoPilotMoon.Destination:inspect(square, player)
	if square == nil
	then
		return nil;
	end

	local info = { ok = true, x = square:getX(), y = square:getY(), z = square:getZ(), weight = 0, capacity = 0, count = 0 };
	local protected = AutoPilotMoon.Zones:isProtected(square, player);
	local vehicle = square:getVehicleContainer();

	if vehicle
	then
		local part = D:getNearestVehiclePart(vehicle, info.x, info.y);

		if part
		then
			local container = part:getItemContainer();

			info.kind = "vehicle";
			info.nameText = getTextOrNull("IGUI_VehiclePart" .. container:getType()) or container:getType();
			info.vehicleName = D:getVehicleName(vehicle);
			info.vehicleId = vehicle:getId();
			info.partId = part:getId();
			info.vx = vehicle:getX();
			info.vy = vehicle:getY();
			info.object = vehicle;
			info.weight = container:getContentsWeight();
			info.capacity = container:getEffectiveCapacity(player);
			info.count = 1;

			if protected
			then
				info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Protected";
			elseif D:isVehiclePartLocked(vehicle, part)
			then
				info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Locked";
			elseif info.weight >= info.capacity
			then
				info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Full";
			end

			return info;
		end
	end

	local containers, badKey = D:getSquareContainers(square, player);

	if #containers > 0 or badKey
	then
		info.kind = "container";
		info.count = #containers;

		for i, entry in ipairs(containers)
		do
			info.weight = info.weight + entry.container:getContentsWeight();
			info.capacity = info.capacity + entry.container:getEffectiveCapacity(player);
		end

		if #containers > 0
		then
			info.nameText = D:getContainerName(containers[1].container);
			info.object = containers[1].object;
		end

		if protected
		then
			info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Protected";
		elseif #containers == 0
		then
			info.ok, info.reasonKey = false, badKey;
		elseif info.weight >= info.capacity
		then
			info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Full";
		elseif AdjacentFreeTileFinder.Find(square, player) == nil
		then
			info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Unreachable";
		end

		return info;
	end

	info.kind = "ground";
	info.weight = square:getTotalWeightOfItemsOnFloor();
	info.capacity = D:getFloorCapacity(player);
	info.count = 0;

	if protected
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Protected";
	elseif square:isWaterSquare()
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Water";
	elseif not square:TreatAsSolidFloor() or square:isSolid() or square:isSolidTrans()
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Unreachable";
	elseif info.weight >= info.capacity
	then
		info.ok, info.reasonKey = false, "IGUI_AutoPilot_D_Bad_Full";
	end

	return info;
end

-- the floor's capacity for the character (the game's floor container), Item.floorCapacity without it
function AutoPilotMoon.Destination:getFloorCapacity(player)
	local floor = player and ISInventoryPage.GetFloorContainer(player:getPlayerNum());

	if floor
	then
		return floor:getEffectiveCapacity(player);
	end

	return AutoPilotMoon.Item.floorCapacity;
end

-- the line of the picker's box: "Cassa di legno: 12.5 / 50", "2 contenitori: 30 / 100", "Bagagliaio di <car>: ...",
-- "A terra: 12.0 / 50"
local function round1(value)
	return math.floor(value * 10 + 0.5) / 10;
end

function AutoPilotMoon.Destination:describe(info)
	local weight = round1(info.weight);
	local capacity = round1(info.capacity);

	if info.kind == "vehicle"
	then
		return getText("IGUI_AutoPilot_D_Vehicle", info.nameText, info.vehicleName, weight, capacity);
	elseif info.kind == "container"
	then
		if info.count > 1
		then
			return getText("IGUI_AutoPilot_D_Stack", info.count, weight, capacity);
		end

		return getText("IGUI_AutoPilot_D_Container", info.nameText or "", weight, capacity);
	end

	return getText("IGUI_AutoPilot_D_Ground", weight, capacity);
end

-- the destination of the jobs (coordinates and ids only), from what the picker inspected
function AutoPilotMoon.Destination:fromInfo(info)
	return {
		kind = info.kind,
		x = info.x,
		y = info.y,
		z = info.z,
		vehicleId = info.vehicleId,
		partId = info.partId,
		vx = info.vx,
		vy = info.vy,
		nameText = info.nameText,
	};
end

-- a destination on a square without asking anything (the Corpse piler's pile where the character stands, a job
-- started from code)
function AutoPilotMoon.Destination:fromSquare(square, player)
	local info = D:inspect(square, player);

	if info == nil
	then
		return nil;
	end

	return D:fromInfo(info);
end

-- remembered for the session, offered again by the picker when close enough
function AutoPilotMoon.Destination:remember(dest)
	D.last = { x = dest.x, y = dest.y, z = dest.z };
end

-- where the picker starts: the last destination when within lastMaxDistance of the character, else nil
function AutoPilotMoon.Destination:getLastNear(player)
	local last = D.last;

	if last == nil or player == nil or last.z ~= math.floor(player:getZ())
	then
		return nil;
	end

	local dx = last.x - player:getX();
	local dy = last.y - player:getY();

	if math.sqrt(dx * dx + dy * dy) > D.lastMaxDistance
	then
		return nil;
	end

	return last;
end

-- using a destination

-- The live side of a destination: { square, containers = list of ItemContainer (in order), objects (their objects),
-- vehicle, part, partIndex }, or nil and the reason key of a stop ("IGUI_AutoPilot_A_Reason_DestGone",
-- "..._DestLocked", "..._VehicleMoved", "..._DestUnreachable").
function AutoPilotMoon.Destination:resolve(dest, player)
	local cell = getCell();
	local square = cell and cell:getGridSquare(dest.x, dest.y, dest.z);

	if dest.kind == "vehicle"
	then
		local vehicle = getVehicleById(dest.vehicleId);

		if vehicle == nil
		then
			return nil, "IGUI_AutoPilot_A_Reason_DestGone";
		end

		if math.abs(vehicle:getX() - dest.vx) > D.vehicleMoveTolerance or math.abs(vehicle:getY() - dest.vy) > D.vehicleMoveTolerance
		then
			return nil, "IGUI_AutoPilot_A_Reason_VehicleMoved";
		end

		local part = vehicle:getPartById(dest.partId);
		local container = part and part:getItemContainer();

		if container == nil or part:isInventoryItemUninstalled()
		then
			return nil, "IGUI_AutoPilot_A_Reason_DestGone";
		end

		if D:isVehiclePartLocked(vehicle, part)
		then
			return nil, "IGUI_AutoPilot_A_Reason_DestLocked";
		end

		local partIndex = nil;

		for i = 0, vehicle:getPartCount() - 1
		do
			if vehicle:getPartByIndex(i) == part
			then
				partIndex = i;
			end
		end

		return { square = square, vehicle = vehicle, part = part, partIndex = partIndex, containers = { container }, objects = {} };
	end

	if square == nil
	then
		return nil, "IGUI_AutoPilot_A_Reason_DestUnreachable";
	end

	if AutoPilotMoon.Zones:isProtected(square, player)
	then
		return nil, "IGUI_AutoPilot_A_Reason_DestGone";
	end

	if dest.kind == "container"
	then
		local entries, badKey = D:getSquareContainers(square, player);

		if #entries == 0
		then
			if badKey == "IGUI_AutoPilot_D_Bad_Locked"
			then
				return nil, "IGUI_AutoPilot_A_Reason_DestLocked";
			end

			return nil, "IGUI_AutoPilot_A_Reason_DestGone";
		end

		local containers = {};
		local objects = {};

		for i, entry in ipairs(entries)
		do
			table.insert(containers, entry.container);
			table.insert(objects, entry.object);
		end

		return { square = square, containers = containers, objects = objects };
	end

	if square:isWaterSquare() or not square:TreatAsSolidFloor() or square:isSolid() or square:isSolidTrans()
	then
		return nil, "IGUI_AutoPilot_A_Reason_DestUnreachable";
	end

	return { square = square, containers = {}, objects = {} };
end

-- the first container of the destination with room for the item (and allowing it), or nil. planned (optional):
-- container -> weight already planned for it in this deposit (the transfers are queued together: each one is checked
-- by the game when it starts, so the plan must not count on room taken by the items before it)
function AutoPilotMoon.Destination:findRoom(resolved, player, item, planned)
	local weight = item:getUnequippedWeight();

	for i, container in ipairs(resolved.containers)
	do
		local already = (planned and planned[container]) or 0;

		-- the game's own check for the item, then the weight already planned (ItemContainer.hasRoomFor adds the weight
		-- to getCapacityWeight and compares it with getEffectiveCapacity)
		if container:isItemAllowed(item) and container:hasRoomFor(player, item)
			and (already == 0 or container:getCapacityWeight() + already + weight <= container:getEffectiveCapacity(player))
		then
			if planned
			then
				planned[container] = already + weight;
			end

			return container;
		end
	end

	return nil;
end

-- checked before every trip (spec 3.5): true, or false and the reason key
function AutoPilotMoon.Destination:validate(dest, player)
	local resolved, reasonKey = D:resolve(dest, player);

	if resolved == nil
	then
		return false, reasonKey;
	end

	return true, nil, resolved;
end
