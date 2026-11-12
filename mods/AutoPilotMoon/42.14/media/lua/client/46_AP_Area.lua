-- AutoPilot (Moon): automations for the Moon server.

-- Areas as coordinates (never as square objects: the game reuses the squares of unloaded chunks), spec UX-AUTOPILOT.md
-- 3.1-3.3. A rectangle { x1, y1, x2, y2, z } with x1 <= x2, y1 <= y2, both corners included. Used by the area tool
-- (client/70_AP_Cursors.lua), by the chains (re-scanned at each phase, with a margin) and by the menu's preview.
-- The scan counts the work of an area a slice at a time (Area.sliceSize squares per call), never a whole area in one
-- frame.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Area = AutoPilotMoon.Area or {};

local Area = AutoPilotMoon.Area;

Area.maxSide = 21;          -- the drawn rectangle: at most 21 x 21, like a radius of 10 (user, 12/11/2026; was 50), spec 3.3
Area.sliceSize = 256;       -- squares counted per frame
Area.settleMs = 120;        -- the corner must stay still this long before counting starts
Area.maxMarks = 200;        -- per-square marks drawn per frame

-- rectangles

function AutoPilotMoon.Area:rect(x1, y1, x2, y2, z)
	x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2);

	if x2 < x1
	then
		x1, x2 = x2, x1;
	end

	if y2 < y1
	then
		y1, y2 = y2, y1;
	end

	return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = math.floor(z or 0) };
end

-- the square areas of the menu: radius 1..3 (Automation.max3x3radius), 6 * radius + 1 squares a side, around a square
function AutoPilotMoon.Area:fromRadius(square, radius)
	if square == nil
	then
		return nil;
	end

	local half = 3 * radius;

	return Area:rect(square:getX() - half, square:getY() - half, square:getX() + half, square:getY() + half, square:getZ());
end

function AutoPilotMoon.Area:width(rect)
	return rect.x2 - rect.x1 + 1;
end

function AutoPilotMoon.Area:height(rect)
	return rect.y2 - rect.y1 + 1;
end

function AutoPilotMoon.Area:count(rect)
	return Area:width(rect) * Area:height(rect);
end

function AutoPilotMoon.Area:isTooBig(rect)
	return Area:width(rect) > Area.maxSide or Area:height(rect) > Area.maxSide;
end

function AutoPilotMoon.Area:contains(rect, x, y, z)
	return x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2 and (z == nil or z == rect.z);
end

function AutoPilotMoon.Area:equals(a, b)
	if a == nil or b == nil
	then
		return a == b;
	end

	return a.x1 == b.x1 and a.y1 == b.y1 and a.x2 == b.x2 and a.y2 == b.y2 and a.z == b.z;
end

-- a bigger rectangle (the chains' margin: logs fall a square or two outside the area)
function AutoPilotMoon.Area:grow(rect, margin)
	margin = margin or 0;

	return { x1 = rect.x1 - margin, y1 = rect.y1 - margin, x2 = rect.x2 + margin, y2 = rect.y2 + margin, z = rect.z };
end

-- the distance in squares from a point to the rectangle (0 inside), the larger of the two axes
function AutoPilotMoon.Area:distanceTo(rect, x, y)
	local dx = 0;
	local dy = 0;

	if x < rect.x1 then dx = rect.x1 - x elseif x > rect.x2 then dx = x - rect.x2 end
	if y < rect.y1 then dy = rect.y1 - y elseif y > rect.y2 then dy = y - rect.y2 end

	if dx > dy
	then
		return dx;
	end

	return dy;
end

-- the loaded squares of the rectangle (grown by margin), and how many are not loaded (too far: getGridSquare nil)
function AutoPilotMoon.Area:squares(rect, margin)
	local cell = getCell();
	local result = {};
	local unloaded = 0;

	if rect == nil or cell == nil
	then
		return result, 0;
	end

	local r = Area:grow(rect, margin);

	for x = r.x1, r.x2
	do
		for y = r.y1, r.y2
		do
			local square = cell:getGridSquare(x, y, r.z);

			if square
			then
				table.insert(result, square);
			else
				unloaded = unloaded + 1;
			end
		end
	end

	return result, unloaded;
end

-- the nearest points of a list of { x, y } (same algorithm as Automation:keepNearest: buckets by whole distance, no
-- sort); marks the kept ones with kept = true and returns how many were kept
function AutoPilotMoon.Area:markNearest(points, refX, refY, limit)
	local buckets = {};
	local maxKey = 0;

	for i, point in ipairs(points)
	do
		local dx = point.x - refX;
		local dy = point.y - refY;
		local key = math.floor(math.sqrt(dx * dx + dy * dy));

		point.kept = false;

		if buckets[key] == nil
		then
			buckets[key] = {};
		end

		table.insert(buckets[key], point);

		if key > maxKey
		then
			maxKey = key;
		end
	end

	local kept = 0;

	for key = 0, maxKey
	do
		local bucket = buckets[key];

		if bucket
		then
			for i, point in ipairs(bucket)
			do
				if kept >= limit
				then
					return kept;
				end

				point.kept = true;
				kept = kept + 1;
			end
		end
	end

	return kept;
end

-- the scan of an area, a slice per call (spec 3.3): the same filter the job will use, the protected squares (a
-- safehouse the player may not use) and the squares not loaded are counted apart.
--   countFn(square, player) -> true when the job has something to do on the square (nil: every square counts)
-- Fields: found (list of { x, y } with work), protected (list of { x, y }), unloaded, scanned, total, done.
function AutoPilotMoon.Area:newScan(rect, player, countFn, limit, refX, refY)
	return {
		rect = rect,
		player = player,
		countFn = countFn,
		limit = limit,
		refX = refX or rect.x1,
		refY = refY or rect.y1,
		index = 0,
		total = Area:count(rect),
		found = {},
		protected = {},
		unloaded = 0,
		scanned = 0,
		capped = 0,
		done = false,
	};
end

-- counts up to max squares (Area.sliceSize by default); returns true when the scan is complete
function AutoPilotMoon.Area:stepScan(scan, max)
	if scan.done
	then
		return true;
	end

	local cell = getCell();
	local rect = scan.rect;
	local width = Area:width(rect);
	local stop = scan.index + (max or Area.sliceSize);

	if stop > scan.total
	then
		stop = scan.total;
	end

	while scan.index < stop
	do
		local x = rect.x1 + (scan.index % width);
		local y = rect.y1 + math.floor(scan.index / width);
		local square = cell and cell:getGridSquare(x, y, rect.z);

		scan.index = scan.index + 1;
		scan.scanned = scan.scanned + 1;

		if square == nil
		then
			scan.unloaded = scan.unloaded + 1;
		elseif AutoPilotMoon.Zones:isProtected(square, scan.player)
		then
			table.insert(scan.protected, { x = x, y = y });
		elseif scan.countFn == nil or scan.countFn(square, scan.player)
		then
			table.insert(scan.found, { x = x, y = y, kept = true });
		end
	end

	if scan.index >= scan.total
	then
		scan.done = true;

		if scan.limit and #scan.found > scan.limit
		then
			Area:markNearest(scan.found, scan.refX, scan.refY, scan.limit);
			scan.capped = #scan.found - scan.limit;
		end
	end

	return scan.done;
end

-- draws a rectangle on the floor for one frame (the game draws an area highlight once: it is set again every frame)
function AutoPilotMoon.Area:highlight(playerNum, rect, r, g, b, a)
	addAreaHighlightForPlayer(playerNum, rect.x1, rect.y1, rect.x2 + 1, rect.y2 + 1, rect.z, r, g, b, a);
end

-- one square, for one frame
function AutoPilotMoon.Area:highlightSquare(playerNum, x, y, z, r, g, b, a)
	addAreaHighlightForPlayer(playerNum, x, y, x + 1, y + 1, z, r, g, b, a);
end
