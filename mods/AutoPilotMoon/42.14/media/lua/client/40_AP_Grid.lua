-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Grid = AutoPilotMoon.Grid or {};

-- squares of an area, a room, a building; the automations filter them themselves, once (C4)

-- radius 1..3 (Automation.max3x3radius): (6 * radius + 1) squares a side
function AutoPilotMoon.Grid:getAllSquaresIn3x3GridRadius(centerSquare, radius)
    local cell = getWorld():getCell();

    if centerSquare == nil or cell == nil
    then
        return {};
    end

    if radius > AutoPilotMoon.Automation.max3x3radius
    then
        radius = AutoPilotMoon.Automation.max3x3radius;
    end

    local rTimes3 = (3 * radius);
    local centerX = centerSquare:getX();
    local centerY = centerSquare:getY();
    local centerZ = centerSquare:getZ();
    local boundsStartX = centerX - rTimes3;
    local boundsStartY = centerY - rTimes3;
    local boundsEndX = centerX + rTimes3;
    local boundsEndY = centerY + rTimes3;

    local squares = {};

    for xOffset = 0, boundsEndX - boundsStartX
    do
        for yOffset = 0, boundsEndY - boundsStartY
        do
            local square = cell:getGridSquare(boundsStartX + xOffset, boundsStartY + yOffset, centerZ);

            if square
            then
                table.insert(squares, square);
            end
        end
    end

    return squares;
end

function AutoPilotMoon.Grid:getAllSquaresInRoom(room)
	local result = {};

	if room
	then
		local squares = room:getSquares();

		for i = 0, squares:size() - 1
		do
			local square = squares:get(i);

			if square
			then
				table.insert(result, square);
			end
		end
	end

	return result;
end

function AutoPilotMoon.Grid:getAllSquaresInBuilding(building)
	local result = {};

	-- every square of every loaded room (B6: not only the rooms that have a free square)
	local def = building and building:getDef();
	local rooms = def and def:getRooms();

	if rooms
	then
		for i = 0, rooms:size() - 1
		do
			local roomDef = rooms:get(i);
			local room = roomDef and roomDef:getIsoRoom();

			if room
			then
				result = AutoPilotMoon:concatArrays(result, AutoPilotMoon.Grid:getAllSquaresInRoom(room));
			end
		end
	end

	return result;
end

function AutoPilotMoon.Grid:filterSquaresBy(squares, filterFn)
    local filteredSquares = {};

    for i, square in ipairs(squares)
    do
        if filterFn(square)
        then
            table.insert(filteredSquares, square);
        end
    end

    return filteredSquares;
end

-- the squares the player may work on (AutoPilotMoon.Zones:isProtected: safehouses the player may not use), and how
-- many were left out
function AutoPilotMoon.Grid:filterUnprotected(squares, player)
    local kept = {};
    local protected = 0;

    for i, square in ipairs(squares)
    do
        if AutoPilotMoon.Zones:isProtected(square, player)
        then
            protected = protected + 1;
        else
            table.insert(kept, square);
        end
    end

    return kept, protected;
end
