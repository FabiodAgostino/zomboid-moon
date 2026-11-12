-- AutoPilot (Moon): automations for the Moon server.

-- Choosing on the ground (11/11/2026, spec UX-AUTOPILOT.md 3.2-3.6): the area tool ("Choose an area...": a rectangle by
-- dragging or by two clicks, or with the controller), the destination picker (one square: a crate, a trunk, the
-- ground) and the preview of an area while a menu entry is highlighted.
--
-- The two cursors are classes derived from the game's ISBuildingObject, put with getCell():setDrag(cursor, playerNum)
-- like the game's own cursors (ISSelectCursor, ISChopTreeCursor): Esc removes them, the controller moves them (A, B, Y
-- with their prompts), DoTileBuilding fixes the pressed square while the left button is down. ISBuildingObject lives
-- in the game's server/ folder, which loads after client/: the classes are derived at OnGameStart
-- (Cursors:createClasses, again before the first use), never when this file loads.
-- The help box next to the cursor is a small panel (ISPanel); its lines are worked out when something changes, never
-- in render. Every handler is added while a choice is open and removed at every exit (confirm, cancel, Esc, death,
-- another cursor).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Cursors = AutoPilotMoon.Cursors or {};
AutoPilotMoon.AreaTool = AutoPilotMoon.AreaTool or {};
AutoPilotMoon.DestinationPicker = AutoPilotMoon.DestinationPicker or {};
AutoPilotMoon.AreaPreview = AutoPilotMoon.AreaPreview or {};
AutoPilotMoon.UI = AutoPilotMoon.UI or {};

local Cursors = AutoPilotMoon.Cursors;
local AreaTool = AutoPilotMoon.AreaTool;
local Picker = AutoPilotMoon.DestinationPicker;
local Preview = AutoPilotMoon.AreaPreview;
local UI = AutoPilotMoon.UI;

Cursors.classesCreated = false;

-- colours of the spec (3.6): the good/bad ones come from the game (colour-blind option), C_Input is the XUI accent
UI.titleColor = { r = 1, g = 1, b = 0.8 };
UI.textColor = { r = 0.9, g = 0.9, b = 0.9 };
UI.inputColor = { r = 0, g = 0.635, b = 0.91 };
UI.greyColor = { r = 0.5, g = 0.5, b = 0.5 };
UI.boxOffset = 24;          -- the help box follows the mouse this far below and right
UI.spacing = 10;            -- UI_BORDER_SPACING of the game's windows

function AutoPilotMoon.UI:goodColor()
	local c = getCore():getGoodHighlitedColor();

	return c:getR(), c:getG(), c:getB();
end

function AutoPilotMoon.UI:badColor()
	local c = getCore():getBadHighlitedColor();

	return c:getR(), c:getG(), c:getB();
end

-- the interface sounds of the spec (4.4), only when the player's option is on
function AutoPilotMoon.UI:playSound(name)
	if AutoPilotMoon.Options:get("uiSounds")
	then
		getSoundManager():playUISound(name);
	end
end

-- the player uses a controller for the cursor (as DoTileBuilding decides)
function AutoPilotMoon.UI:isJoypad(playerNum)
	return JoypadState.players[playerNum + 1] ~= nil;
end

-- the square under the mouse on floor z
function AutoPilotMoon.UI:mouseSquare(playerNum, z)
	local x = screenToIsoX(playerNum, getMouseX(), getMouseY(), z);
	local y = screenToIsoY(playerNum, getMouseX(), getMouseY(), z);

	return math.floor(x), math.floor(y);
end

-- a line of a help box: text and colour
local function line(lines, text, r, g, b)
	table.insert(lines, { text = text, r = r, g = g, b = b });
end

local function goodLine(lines, text)
	local r, g, b = UI:goodColor();

	line(lines, text, r, g, b);
end

local function badLine(lines, text)
	local r, g, b = UI:badColor();

	line(lines, text, r, g, b);
end

local function textLine(lines, text)
	line(lines, text, UI.textColor.r, UI.textColor.g, UI.textColor.b);
end

-- The help box (spec 3.2): black 80%, border 0.4, small font; next to the mouse (24 px below right, inside the
-- player's screen) or, with a controller, at the top centre of the player's screen.
local HelpBox = {};

function HelpBox:new(playerNum)
	local o = ISPanel.new(self, 0, 0, 10, 10);

	o.playerNum = playerNum;
	o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 };
	o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 };
	o.moveWithMouse = false;
	o.lines = {};
	o.lineHeight = getTextManager():getFontHeight(UIFont.Small) + 4;

	return o;
end

-- new lines: the size is measured here (when the text changes), never in render
function HelpBox:setLines(lines)
	local width = 0;

	for i, entry in ipairs(lines)
	do
		local w = getTextManager():MeasureStringX(UIFont.Small, entry.text);

		if w > width
		then
			width = w;
		end
	end

	self.lines = lines;
	self:setWidth(width + 2 * UI.spacing);
	self:setHeight(#lines * self.lineHeight + 2 * UI.spacing - 4);
end

function HelpBox:update()
	local left = getPlayerScreenLeft(self.playerNum);
	local top = getPlayerScreenTop(self.playerNum);
	local screenWidth = getPlayerScreenWidth(self.playerNum);
	local screenHeight = getPlayerScreenHeight(self.playerNum);
	local x = 0;
	local y = 0;

	if UI:isJoypad(self.playerNum)
	then
		x = left + (screenWidth - self:getWidth()) / 2;
		y = top + 2 * UI.spacing;
	else
		local mouseX = getMouseX();
		local mouseY = getMouseY();

		x = mouseX + UI.boxOffset;
		y = mouseY + UI.boxOffset;

		-- past the edge: to the other side of the pointer, never under it (the box takes the mouse: under the pointer
		-- it would stop the ground's picking and the clicks)
		if x + self:getWidth() > left + screenWidth
		then
			x = math.max(left, mouseX - UI.boxOffset - self:getWidth());
		end

		if y + self:getHeight() > top + screenHeight
		then
			y = math.max(top, mouseY - UI.boxOffset - self:getHeight());
		end
	end

	self:setX(x);
	self:setY(y);
end

function HelpBox:render()
	local y = UI.spacing - 2;

	for i, entry in ipairs(self.lines)
	do
		self:drawText(entry.text, UI.spacing, y, entry.r, entry.g, entry.b, 1, UIFont.Small);
		y = y + self.lineHeight;
	end
end

-- the cursor class's methods (copied onto the classes derived from ISBuildingObject)

local CursorMethods = {};

function CursorMethods:create(x, y, z, north, sprite)
	self.tool:onCreate(self.session, x, y, z);
end

function CursorMethods:isValid(square)
	return self.tool:isValid(self.session);
end

function CursorMethods:render(x, y, z, square)
	self.tool:onRender(self.session, x, y, z);
end

-- called by the game when the cursor is replaced or removed (Esc, another cursor, setDrag(nil))
function CursorMethods:deactivate()
	self.tool:onDeactivate(self.session);
end

function CursorMethods:onJoypadPressButton(joypadIndex, joypadData, button)
	if button == Joypad.BButton
	then
		self.tool:back(self.session);
	elseif button == Joypad.YButton
	then
		self.xJoypad = self.character:getXi();
		self.yJoypad = self.character:getYi();
	end
end

function CursorMethods:getAPrompt()
	return self.tool:getAPrompt(self.session);
end

function CursorMethods:getBPrompt()
	return getText("UI_Cancel");
end

function CursorMethods:getYPrompt()
	return getText("IGUI_AutoPilot_S_PromptBack");
end

function CursorMethods:getLBPrompt()
	return nil;
end

function CursorMethods:getRBPrompt()
	return nil;
end

-- no rotation: nothing is built
function CursorMethods:rotateKey(key)
end

function CursorMethods:rotateMouse(x, y)
end

-- clicks on objects while choosing: blocked (no loot window), as ISMoveableCursor does (called with a dot)
function CursorMethods.onObjectLeftMouseButtonDown(object, x, y)
	return true;
end

-- Derives the classes from the game's ISBuildingObject and ISPanel (server/ loads after client/): at OnGameStart and
-- before the first use. False when the game's classes are not there.
function AutoPilotMoon.Cursors:createClasses()
	if Cursors.classesCreated
	then
		return true;
	end

	if ISBuildingObject == nil or ISPanel == nil
	then
		return false;
	end

	Cursors.AreaCursor = ISBuildingObject:derive("AutoPilotAreaCursor");
	Cursors.DestinationCursor = ISBuildingObject:derive("AutoPilotDestinationCursor");

	for name, fn in pairs(CursorMethods)
	do
		Cursors.AreaCursor[name] = fn;
		Cursors.DestinationCursor[name] = fn;
	end

	UI.HelpBox = ISPanel:derive("AutoPilotHelpBox");

	for name, fn in pairs(HelpBox)
	do
		UI.HelpBox[name] = fn;
	end

	Cursors.classesCreated = true;

	return true;
end

-- a cursor of a class, for the player, driven by tool (AreaTool or DestinationPicker) and its session
function AutoPilotMoon.Cursors:newCursor(class, player, tool, session, startX, startY)
	local o = {};

	setmetatable(o, class);
	class.__index = class;
	o:init();
	o.character = player;
	o.player = player:getPlayerNum();
	o.noNeedHammer = true;
	o.skipBuildAction = true;
	o.skipWalk2 = true;           -- without it tryBuild walks the character to the square
	o.dragNilAfterPlace = false;
	o.isYButtonResetCursor = true;
	o.xJoypad = startX;
	o.yJoypad = startY;
	o.tool = tool;
	o.session = session;

	return o;
end

-- what is common to the two tools: one session at a time on this client, opened and closed cleanly

local function openSession(tool, session, class, startX, startY)
	local player = session.player;

	session.cursor = Cursors:newCursor(class, player, tool, session, startX, startY);
	session.box = UI.HelpBox:new(session.playerNum);
	session.box:initialise();
	session.box:addToUIManager();
	session.box:setAlwaysOnTop(true);

	tool.session = session;
	ISWorldObjectContextMenu.disableWorldMenu = true;
	Events.OnRightMouseDown.Add(Cursors.onRightMouseDown);
	Events.OnPlayerDeath.Add(Cursors.onPlayerDeath);

	getCell():setDrag(session.cursor, session.playerNum);
	UI:playSound("UIObjectMenuEnter");
end

local function closeSession(tool, session)
	if tool.session == session
	then
		tool.session = nil;
	end

	if session.box
	then
		session.box:removeFromUIManager();
		session.box = nil;
	end

	if session.outlined
	then
		session.outlined:setOutlineHighlight(session.playerNum, false);
		session.outlined = nil;
	end

	if AreaTool.session == nil and Picker.session == nil
	then
		ISWorldObjectContextMenu.disableWorldMenu = false;
		Events.OnRightMouseDown.Remove(Cursors.onRightMouseDown);
		Events.OnPlayerDeath.Remove(Cursors.onPlayerDeath);
	end
end

-- ends a session: ours removes the cursor (the game's deactivate then finds the session already ended)
local function endSession(tool, session)
	if session.ended
	then
		return false;
	end

	session.ended = true;
	closeSession(tool, session);

	local cell = getCell();

	if cell and cell:getDrag(session.playerNum) == session.cursor
	then
		cell:setDrag(nil, session.playerNum);
	end

	return true;
end

-- the right button (player 0, the only one with a mouse): back one step
function AutoPilotMoon.Cursors.onRightMouseDown(x, y)
	local session = AreaTool.session or Picker.session;

	if session and session.playerNum == 0
	then
		session.tool:back(session);
	end
end

function AutoPilotMoon.Cursors.onPlayerDeath(player)
	for i, tool in ipairs({ AreaTool, Picker })
	do
		local session = tool.session;

		if session and session.player == player
		then
			tool:cancel(session);
		end
	end
end

-- ============================================================================================================
-- The area tool (spec 3.2, 3.3)
-- ============================================================================================================

-- Opens the area tool for the player. opts:
--   titleText    the job's verb or title for the box ("Abbatti alberi")
--   unitKey      what is counted ("IGUI_AutoPilot_S_Unit_Trees"); default the job's (jobName)
--   jobName      the automation (its squareFilter counts, its limit is shown) - or countFn and limit directly:
--   countFn(square, player) -> bool, limit (number)
--   onConfirm(rect, session)   rect = AutoPilotMoon.Area:rect; onCancel(session)
-- Returns the session, or nil when the cursor cannot be made.
function AutoPilotMoon.AreaTool:begin(player, opts)
	if player == nil or not Cursors:createClasses()
	then
		return nil;
	end

	AreaTool:cancelAll();

	opts = opts or {};

	local definition = opts.jobName and AutoPilotMoon.Automation.definitions[opts.jobName];
	local session = {
		tool = AreaTool,
		player = player,
		playerNum = player:getPlayerNum(),
		z = math.floor(player:getZ()),
		opts = opts,
		titleText = opts.titleText or "",
		unitKey = opts.unitKey or (definition and definition.unitKey) or "IGUI_AutoPilot_S_Unit_Squares",
		countFn = opts.countFn or (definition and definition.squareFilter),
		limit = opts.limit or (opts.jobName and AutoPilotMoon.Automation:getLimit(opts.jobName))
			or AutoPilotMoon.Sandbox:getInteger("MaxSquaresPerJob"),
		first = nil,
		anchorX = nil,
		anchorY = nil,
		pointerX = nil,
		pointerY = nil,
		rect = nil,
		scan = nil,
		settleAt = 0,
		dirty = true,
		dragging = false,
		ended = false,
	};
	local square = player:getSquare();

	openSession(AreaTool, session, Cursors.AreaCursor, square and square:getX(), square and square:getY());
	AreaTool:refreshLines(session);

	return session;
end

-- the rectangle follows the corners; a new rectangle restarts the count after Area.settleMs
function AutoPilotMoon.AreaTool:setPointer(session, anchorX, anchorY, pointerX, pointerY)
	if session.anchorX == anchorX and session.anchorY == anchorY and session.pointerX == pointerX and session.pointerY == pointerY
	then
		return false;
	end

	session.anchorX = anchorX;
	session.anchorY = anchorY;
	session.pointerX = pointerX;
	session.pointerY = pointerY;

	if anchorX ~= nil
	then
		session.rect = AutoPilotMoon.Area:rect(anchorX, anchorY, pointerX, pointerY, session.z);
	else
		session.rect = nil;
	end

	session.scan = nil;
	session.settleAt = getTimestampMs() + AutoPilotMoon.Area.settleMs;
	session.dirty = true;

	return true;
end

-- the count: after the corner stood still Area.settleMs, a slice per frame
function AutoPilotMoon.AreaTool:tick(session)
	local rect = session.rect;

	if rect and not AutoPilotMoon.Area:isTooBig(rect)
	then
		if session.scan == nil and getTimestampMs() >= session.settleAt
		then
			local square = session.player:getSquare();

			session.scan = AutoPilotMoon.Area:newScan(rect, session.player, session.countFn, session.limit,
				square and square:getX(), square and square:getY());
			session.dirty = true;
		end

		if session.scan and not session.scan.done
		then
			if AutoPilotMoon.Area:stepScan(session.scan)
			then
				session.dirty = true;
			end
		end
	end

	if session.dirty
	then
		AreaTool:refreshLines(session);
	end
end

function AutoPilotMoon.AreaTool:isValid(session)
	return session.rect == nil or not AutoPilotMoon.Area:isTooBig(session.rect);
end

-- the lines of the help box (spec 3.2), worked out only when something changed
function AutoPilotMoon.AreaTool:refreshLines(session)
	session.dirty = false;

	local lines = {};
	local joypad = UI:isJoypad(session.playerNum);
	local rect = session.rect;
	local unit = getText(session.unitKey);

	line(lines, getText("IGUI_AutoPilot_S_Title", session.titleText), UI.titleColor.r, UI.titleColor.g, UI.titleColor.b);

	if joypad
	then
		textLine(lines, getText("IGUI_AutoPilot_S_HowJoypad"));
	else
		if session.first
		then
			textLine(lines, getText("IGUI_AutoPilot_S_HowSecondCorner"));
		else
			textLine(lines, getText("IGUI_AutoPilot_S_HowDrag"));
		end

		textLine(lines, getText("IGUI_AutoPilot_S_HowCancel"));
	end

	if rect
	then
		local width = AutoPilotMoon.Area:width(rect);
		local height = AutoPilotMoon.Area:height(rect);

		textLine(lines, getText("IGUI_AutoPilot_S_Size", width, height));

		if AutoPilotMoon.Area:isTooBig(rect)
		then
			badLine(lines, getText("IGUI_AutoPilot_S_TooBig", AutoPilotMoon.Area.maxSide));

			if not joypad and session.dragging
			then
				badLine(lines, getText("IGUI_AutoPilot_S_ReleaseToCancel"));
			end
		else
			local scan = session.scan;

			if scan == nil or not scan.done
			then
				textLine(lines, getText("IGUI_AutoPilot_S_Found", unit, getText("IGUI_AutoPilot_S_Counting"), session.limit));
			elseif #scan.found == 0
			then
				badLine(lines, getText("IGUI_AutoPilot_S_NothingFound"));
			elseif scan.capped > 0
			then
				badLine(lines, getText("IGUI_AutoPilot_S_FoundCapped", unit, #scan.found, session.limit));
			else
				goodLine(lines, getText("IGUI_AutoPilot_S_Found", unit, #scan.found, session.limit));
			end

			if scan and scan.done and #scan.protected > 0
			then
				badLine(lines, getText("IGUI_AutoPilot_S_ExcludedProtected", #scan.protected));
			end

			if scan and scan.done and scan.unloaded > 0
			then
				textLine(lines, getText("IGUI_AutoPilot_S_ExcludedFar", scan.unloaded));
			end
		end
	end

	session.lines = lines;

	if session.box
	then
		session.box:setLines(lines);
	end
end

-- the frame's drawing: the rectangle (one call), then at most Area.maxMarks marks (spec 3.4)
function AutoPilotMoon.AreaTool:draw(session, x, y, z)
	local playerNum = session.playerNum;
	local rect = session.rect;
	local gr, gg, gb = UI:goodColor();
	local br, bg, bb = UI:badColor();

	if rect
	then
		if AutoPilotMoon.Area:isTooBig(rect)
		then
			AutoPilotMoon.Area:highlight(playerNum, rect, br, bg, bb, 0.25);
		else
			AutoPilotMoon.Area:highlight(playerNum, rect, gr, gg, gb, 0.25);
		end

		local scan = session.scan;

		if scan and scan.done
		then
			local marks = 0;
			local maxMarks = AutoPilotMoon.Area.maxMarks;

			for i, point in ipairs(scan.protected)
			do
				if marks >= maxMarks then break end

				AutoPilotMoon.Area:highlightSquare(playerNum, point.x, point.y, rect.z, br, bg, bb, 0.5);
				marks = marks + 1;
			end

			for i, point in ipairs(scan.found)
			do
				if marks >= maxMarks then break end

				if point.kept
				then
					AutoPilotMoon.Area:highlightSquare(playerNum, point.x, point.y, rect.z, gr, gg, gb, 0.45);
				else
					AutoPilotMoon.Area:highlightSquare(playerNum, point.x, point.y, rect.z, UI.greyColor.r, UI.greyColor.g, UI.greyColor.b, 0.35);
				end

				marks = marks + 1;
			end
		end
	end

	if session.cursor
	then
		local valid = AreaTool:isValid(session);
		local r, g, b = gr, gg, gb;

		if not valid
		then
			r, g, b = br, bg, bb;
		end

		session.cursor:getFloorCursorSprite():RenderGhostTileColor(x, y, z, r, g, b, 0.8);
	end
end

-- every frame (the cursor's render): the floor, the corners, the count, the drawing
function AutoPilotMoon.AreaTool:onRender(session, x, y, z)
	if session.ended
	then
		return;
	end

	if math.floor(session.player:getZ()) ~= session.z
	then
		AreaTool:cancel(session, "IGUI_AutoPilot_S_FloorChanged");

		return;
	end

	local cursor = session.cursor;
	local joypad = UI:isJoypad(session.playerNum);
	local pointerX, pointerY = x, y;
	local anchorX, anchorY = nil, nil;
	local dragging = false;

	if not joypad and cursor.isLeftDown and cursor.square
	then
		-- the button is down: the game keeps the pressed square, the other corner is under the mouse
		pointerX, pointerY = UI:mouseSquare(session.playerNum, session.z);
		dragging = session.first == nil;
	end

	if session.first
	then
		anchorX, anchorY = session.first.x, session.first.y;
	elseif dragging
	then
		anchorX, anchorY = cursor.square:getX(), cursor.square:getY();
	end

	if session.dragging ~= dragging
	then
		session.dragging = dragging;
		session.dirty = true;
	end

	AreaTool:setPointer(session, anchorX, anchorY, pointerX, pointerY);
	AreaTool:tick(session);
	AreaTool:draw(session, x, y, z);
end

-- the game's "build" (mouse released, controller A): a corner or the confirmation
function AutoPilotMoon.AreaTool:onCreate(session, x, y, z)
	if session.ended
	then
		return;
	end

	if session.first == nil
	then
		if UI:isJoypad(session.playerNum)
		then
			AreaTool:setFirstCorner(session, x, y);

			return;
		end

		-- the mouse: (x, y) is where the button went down, the release is under the mouse now
		local releaseX, releaseY = UI:mouseSquare(session.playerNum, session.z);

		if releaseX == x and releaseY == y
		then
			-- a plain click: the first corner, the second one is the next click
			AreaTool:setFirstCorner(session, x, y);

			return;
		end

		AreaTool:confirm(session, x, y, releaseX, releaseY);

		return;
	end

	if UI:isJoypad(session.playerNum)
	then
		AreaTool:confirm(session, session.first.x, session.first.y, x, y);

		return;
	end

	-- the mouse: the rectangle drawn while the button was down followed the mouse, so the second corner is where it
	-- was released (what the player saw)
	local releaseX, releaseY = UI:mouseSquare(session.playerNum, session.z);

	AreaTool:confirm(session, session.first.x, session.first.y, releaseX, releaseY);
end

function AutoPilotMoon.AreaTool:setFirstCorner(session, x, y)
	session.first = { x = x, y = y };
	session.dirty = true;
	AreaTool:setPointer(session, x, y, x, y);
end

-- the rectangle chosen: too big -> the choice stays open with the first corner free (spec 3.2); else the tool closes
-- and opts.onConfirm(rect) runs
function AutoPilotMoon.AreaTool:confirm(session, x1, y1, x2, y2)
	local rect = AutoPilotMoon.Area:rect(x1, y1, x2, y2, session.z);

	if AutoPilotMoon.Area:isTooBig(rect)
	then
		session.first = nil;
		session.dirty = true;

		return false;
	end

	session.result = rect;

	if not endSession(AreaTool, session)
	then
		return false;
	end

	UI:playSound("UIObjectMenuObjectPlace");

	if session.opts.onConfirm
	then
		session.opts.onConfirm(rect, session);
	end

	return true;
end

-- right button or B: the first corner goes; without it, the choice is cancelled
function AutoPilotMoon.AreaTool:back(session)
	if session.first
	then
		session.first = nil;
		session.dirty = true;
		AreaTool:setPointer(session, nil, nil, session.pointerX, session.pointerY);

		return;
	end

	AreaTool:cancel(session);
end

-- cancelled (with an optional message key)
function AutoPilotMoon.AreaTool:cancel(session, messageKey)
	if not endSession(AreaTool, session)
	then
		return;
	end

	if messageKey
	then
		AutoPilotMoon:say("bad", getText(messageKey), session.player);
	end

	if session.opts.onCancel
	then
		session.opts.onCancel(session);
	end
end

-- the game removed the cursor (Esc, another cursor)
function AutoPilotMoon.AreaTool:onDeactivate(session)
	if session.ended
	then
		return;
	end

	session.ended = true;
	closeSession(AreaTool, session);

	if session.opts.onCancel
	then
		session.opts.onCancel(session);
	end
end

function AutoPilotMoon.AreaTool:getAPrompt(session)
	if session.first
	then
		return getText("IGUI_AutoPilot_S_PromptSecond");
	end

	return getText("IGUI_AutoPilot_S_PromptFirst");
end

-- closes whatever choice is open (a new one starts, a job starts)
function AutoPilotMoon.AreaTool:cancelAll()
	if AreaTool.session
	then
		AreaTool:cancel(AreaTool.session);
	end

	if Picker.session
	then
		Picker:cancel(Picker.session);
	end
end

-- ============================================================================================================
-- The destination picker (spec 3.5)
-- ============================================================================================================

Picker.refreshMs = 250;     -- the square under the cursor is looked at again this often (weights change in MP)

-- Opens the destination picker. opts:
--   titleText    the job's title ("Sega i tronchi"); whatKey: "IGUI_AutoPilot_D_TitlePlanks" / _TitleItems /
--                _TitlePile; step = true after the area ("(step 2 of 2)"); area (rect) for "N squares from the area"
--   onConfirm(dest, info, session)   dest = AutoPilotMoon.Destination (coordinates); onCancel(session)
-- The cursor starts on the last destination when it is near (spec 3.5), else on the character.
-- Phase C (11/11/2026), for a second step that is not a container: inspect(square, player) -> info (as
--   Destination:inspect: ok, x, y, z, reasonKey, object), describe(info) -> the line of the box, howKey (the "Click..."
--   line), startAtPlayer (the cursor starts on the character: the corpses' pile, spec 3.5), noRemember (not the "last
--   destination" of the containers), toDest(info) -> what onConfirm gets (default Destination:fromInfo).
-- "Sul posto" (12/11/2026, the Sawyer: owner's test): onSpot = the text key of what happens then
--   ("IGUI_AutoPilot_D_OnSpotPlanks"). It is the first and default choice: the cursor starts on the character, whose
--   square means "Sul posto" (one click, or A, and it starts), told in the box in the "good" colour; any other square is
--   a destination as before (the last one still marked). onConfirm then gets dest = nil and info.kind = "onSpot".
function AutoPilotMoon.DestinationPicker:begin(player, opts)
	if player == nil or not Cursors:createClasses()
	then
		return nil;
	end

	AreaTool:cancelAll();

	opts = opts or {};

	local session = {
		tool = Picker,
		player = player,
		playerNum = player:getPlayerNum(),
		z = math.floor(player:getZ()),
		opts = opts,
		info = nil,
		infoKey = nil,
		inspectedAt = 0,
		last = not (opts.startAtPlayer or opts.noRemember) and AutoPilotMoon.Destination:getLastNear(player) or nil,
		dirty = true,
		ended = false,
	};
	local startX, startY = nil, nil;

	if session.last and not opts.onSpot
	then
		startX, startY = session.last.x, session.last.y;
	else
		local square = player:getSquare();

		startX, startY = square and square:getX(), square and square:getY();
	end

	openSession(Picker, session, Cursors.DestinationCursor, startX, startY);
	Picker:refreshLines(session);

	return session;
end

-- what is under the cursor, looked at when the square changes and every refreshMs
function AutoPilotMoon.DestinationPicker:inspectAt(session, x, y, z)
	local key = x * 1000003 + y * 7 + z;
	local now = getTimestampMs();

	if session.infoKey == key and now - session.inspectedAt < Picker.refreshMs
	then
		return session.info;
	end

	local cell = getCell();

	session.infoKey = key;
	session.inspectedAt = now;
	local square = cell and cell:getGridSquare(x, y, z);

	if session.opts.onSpot and square ~= nil and square == session.player:getSquare()
	then
		session.info = { ok = true, kind = "onSpot", x = x, y = y, z = z };
	elseif session.opts.inspect
	then
		session.info = square and session.opts.inspect(square, session.player) or nil;
	else
		session.info = AutoPilotMoon.Destination:inspect(square, session.player);
	end
	session.dirty = true;

	return session.info;
end

function AutoPilotMoon.DestinationPicker:isValid(session)
	return session.info ~= nil and session.info.ok == true;
end

function AutoPilotMoon.DestinationPicker:refreshLines(session)
	session.dirty = false;

	local lines = {};
	local opts = session.opts;
	local info = session.info;
	local title = getText("IGUI_AutoPilot_D_Title", opts.titleText or "", getText(opts.whatKey or "IGUI_AutoPilot_D_TitleItems"));

	if opts.step
	then
		title = title .. " " .. getText("IGUI_AutoPilot_D_Step");
	end

	line(lines, title, UI.titleColor.r, UI.titleColor.g, UI.titleColor.b);

	if opts.onSpot
	then
		textLine(lines, getText(opts.howKey or "IGUI_AutoPilot_D_HowOnSpot"));
	else
		textLine(lines, getText(opts.howKey or "IGUI_AutoPilot_D_How"));
	end

	if UI:isJoypad(session.playerNum)
	then
		textLine(lines, getText(opts.onSpot and "IGUI_AutoPilot_D_HowJoypadOnSpot" or "IGUI_AutoPilot_D_HowJoypad"));
	else
		textLine(lines, getText("IGUI_AutoPilot_S_HowCancel"));
	end

	if info and info.kind == "onSpot"
	then
		goodLine(lines, getText(opts.onSpot));
	elseif info
	then
		local describe = opts.describe or function(i) return AutoPilotMoon.Destination:describe(i) end;

		if info.ok
		then
			goodLine(lines, describe(info));
		else
			if opts.describe or info.kind ~= "ground" or info.reasonKey == "IGUI_AutoPilot_D_Bad_Full"
			then
				local text = describe(info);

				if text
				then
					badLine(lines, text);
				end
			end

			badLine(lines, getText(info.reasonKey));
		end

		if opts.area
		then
			textLine(lines, getText("IGUI_AutoPilot_D_Distance", AutoPilotMoon.Area:distanceTo(opts.area, info.x, info.y)));
		end

		if info.kind == "vehicle"
		then
			textLine(lines, getText("IGUI_AutoPilot_D_VehicleWarn"));
		end

		if session.last and session.last.x == info.x and session.last.y == info.y and session.last.z == info.z
		then
			line(lines, getText("IGUI_AutoPilot_D_Last"), UI.inputColor.r, UI.inputColor.g, UI.inputColor.b);
		end
	end

	session.lines = lines;

	if session.box
	then
		session.box:setLines(lines);
	end
end

-- the outline of the container under the cursor (spec 3.5): set when it changes, removed when it goes
local function outline(session, object)
	if session.outlined == object
	then
		return;
	end

	if session.outlined
	then
		session.outlined:setOutlineHighlight(session.playerNum, false);
	end

	session.outlined = object;

	if object
	then
		local r, g, b = UI:goodColor();

		if not (session.info and session.info.ok)
		then
			r, g, b = UI:badColor();
		end

		object:setOutlineHighlightCol(session.playerNum, r, g, b, 1);
		object:setOutlineHighlight(session.playerNum, true);
	end
end

function AutoPilotMoon.DestinationPicker:onRender(session, x, y, z)
	if session.ended
	then
		return;
	end

	if math.floor(session.player:getZ()) ~= session.z
	then
		Picker:cancel(session, "IGUI_AutoPilot_S_FloorChanged");

		return;
	end

	local info = Picker:inspectAt(session, x, y, z);

	if session.dirty
	then
		Picker:refreshLines(session);
	end

	outline(session, info and info.object);

	local r, g, b = UI:badColor();

	if info and info.ok
	then
		r, g, b = UI:goodColor();
	end

	if session.last and (session.last.x ~= x or session.last.y ~= y)
	then
		AutoPilotMoon.Area:highlightSquare(session.playerNum, session.last.x, session.last.y, session.last.z,
			UI.inputColor.r, UI.inputColor.g, UI.inputColor.b, 0.6);
	end

	session.cursor:getFloorCursorSprite():RenderGhostTileColor(x, y, z, r, g, b, 0.8);
end

-- one click (or A) on a square that is fine: chosen
function AutoPilotMoon.DestinationPicker:onCreate(session, x, y, z)
	if session.ended
	then
		return;
	end

	-- looked at again now: the click must not use a stale answer
	session.infoKey = nil;

	local info = Picker:inspectAt(session, x, y, z);

	if info == nil or not info.ok
	then
		return;
	end

	local dest = nil;

	if info.kind == "onSpot"
	then
		dest = nil;
	elseif session.opts.toDest
	then
		dest = session.opts.toDest(info);
	else
		dest = AutoPilotMoon.Destination:fromInfo(info);
	end

	session.result = dest;

	if dest ~= nil and not session.opts.noRemember
	then
		AutoPilotMoon.Destination:remember(dest);
	end

	if not endSession(Picker, session)
	then
		return;
	end

	UI:playSound("UIObjectMenuObjectPlace");

	if session.opts.onConfirm
	then
		session.opts.onConfirm(dest, info, session);
	end
end

function AutoPilotMoon.DestinationPicker:back(session)
	Picker:cancel(session);
end

function AutoPilotMoon.DestinationPicker:cancel(session, messageKey)
	if not endSession(Picker, session)
	then
		return;
	end

	if messageKey
	then
		AutoPilotMoon:say("bad", getText(messageKey), session.player);
	end

	if session.opts.onCancel
	then
		session.opts.onCancel(session);
	end
end

function AutoPilotMoon.DestinationPicker:onDeactivate(session)
	if session.ended
	then
		return;
	end

	session.ended = true;
	closeSession(Picker, session);

	if session.opts.onCancel
	then
		session.opts.onCancel(session);
	end
end

function AutoPilotMoon.DestinationPicker:getAPrompt(session)
	if Picker:isValid(session)
	then
		return getText("IGUI_AutoPilot_D_PromptChoose");
	end

	return nil;
end

-- Area, then destination, in one go (spec 3.5: "prima l'area, poi la destinazione"): opts as AreaTool:begin plus
-- whatKey and onSpot (the picker's "Sul posto"); onConfirm(rect, dest, info) when both are chosen (dest nil: "Sul
-- posto"), onCancel() when either is cancelled.
function AutoPilotMoon.AreaTool:beginWithDestination(player, opts)
	local areaOpts = {};

	for k, v in pairs(opts)
	do
		areaOpts[k] = v;
	end

	areaOpts.onConfirm = function(rect)
		Picker:begin(player, {
			titleText = opts.titleText,
			whatKey = opts.whatKey,
			onSpot = opts.onSpot,
			step = true,
			area = rect,
			onConfirm = function(dest, info)
				if opts.onConfirm
				then
					opts.onConfirm(rect, dest, info);
				end
			end,
			onCancel = opts.onCancel,
		});
	end

	return AreaTool:begin(player, areaOpts);
end

-- ============================================================================================================
-- The preview of an area while a menu entry is highlighted (spec 2.2 rule 5)
-- ============================================================================================================

-- Makes a menu option show its area on the ground while it is highlighted (mouse or controller): areaFn() returns a
-- rectangle (AutoPilotMoon.Area:rect) or a list of rectangles, worked out when the option is highlighted.
-- onHighlightParams is always a table: the game calls unpack on it.
function AutoPilotMoon.AreaPreview:attach(option, areaFn)
	option.onHighlight = Preview.onHighlight;
	option.onHighlightParams = { areaFn };
end

function AutoPilotMoon.AreaPreview.onHighlight(option, menu, isHighlighted, areaFn)
	if isHighlighted and areaFn
	then
		Preview:show(menu.player, areaFn());
	else
		Preview:hide();
	end
end

-- area: one rectangle or a list of rectangles (a room, a building: at most Area.maxMarks are drawn)
function AutoPilotMoon.AreaPreview:show(playerNum, area)
	if area == nil
	then
		Preview:hide();

		return;
	end

	local rects = area;

	if area.x1 ~= nil
	then
		rects = { area };
	end

	if Preview.active == nil
	then
		Events.OnPreUIDraw.Add(Preview.draw);
	end

	Preview.active = { playerNum = playerNum, rects = rects };
end

function AutoPilotMoon.AreaPreview:hide()
	if Preview.active
	then
		Preview.active = nil;
		Events.OnPreUIDraw.Remove(Preview.draw);
	end
end

function AutoPilotMoon.AreaPreview.draw()
	local active = Preview.active;

	if active == nil
	then
		return;
	end

	local r, g, b = UI:goodColor();

	for i, rect in ipairs(active.rects)
	do
		if i > AutoPilotMoon.Area.maxMarks then break end

		AutoPilotMoon.Area:highlight(active.playerNum, rect, r, g, b, 0.25);
	end
end
