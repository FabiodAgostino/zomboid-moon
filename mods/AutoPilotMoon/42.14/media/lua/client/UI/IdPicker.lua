-- AutoPilot (Moon): automations for the Moon server.

-- "Nome nativo" (19/11/2026, UX-AUTOPILOT.md 2.6, MACRO-AUTOPILOT.md 4.14): a button in the macro editor and in the
-- AutoPilot panel; the next click on an object shows the game's own name of it, the one a macro writes:
--   * an item in the inventory or in the loot window: InventoryItem.getFullType ("Base.Axe");
--   * an item lying on the ground (the square under the mouse, IsoWorldInventoryObject.getItem): its type too;
--   * a workbench (the master object of the square's objects, as the game's context menu takes it): the id of its
--     entity, what at="..." of the macros takes ("Forge_Primitive_Forge");
--   * any other object of the world: the name of its sprite ("furniture_storage_01_12"), said as such.
-- The result: a small box near the click with the display name, the native name, what kind of name it is, "Copia"
-- (Clipboard.setClipboard), "Inserisci nell'editor" (the quoted name at the editor's cursor, as Inserisci > Oggetto)
-- when the player's macro editor is open and can be written, and "Chiudi"; also said once over the head.
--
-- How the click is caught without touching the game: while choosing, a transparent panel of the mod covers the
-- player's screen, on top of everything (the game's UIManager gives the click to the topmost element under the mouse,
-- so neither the inventory nor the world get it: no item selected, no walk); it reads what is under the mouse itself:
-- the inventory and loot windows (getPlayerInventory / getPlayerLoot, their inventoryPane: the row under the mouse as
-- ISInventoryPane.updateTooltip of 42.22 counts it), else the square under the mouse on the player's floor
-- (screenToIsoX / screenToIsoY). It wants the key events only for Esc (isKeyConsumed: the game's escape menu does not
-- open); a right click cancels too. The panel is added to the game's UI at the start and removed at the end: nothing
-- of the mod listens while no one is choosing. Only with the player's switch "Attiva AutoPilot" on (the buttons exist
-- only then; switched off while choosing: cancelled, AutoPilotMoon.Switch's shutdown).
-- With a controller there is no mouse to point: the button takes the item selected in the inventory or loot window
-- (their joypad selection) at once; nothing selected: said so.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.IdPicker = AutoPilotMoon.IdPicker or {};
AutoPilotMoon.UI = AutoPilotMoon.UI or {};

local Pick = AutoPilotMoon.IdPicker;
local UI = AutoPilotMoon.UI;

Pick.overlays = Pick.overlays or {};   -- playerNum -> the panel that catches the click (only while choosing)
Pick.results = Pick.results or {};     -- playerNum -> the box of the result

-- the colour of the native name: the texts of the macros' code (MacroCodeView "string")
Pick.idColor = { r = 206 / 255, g = 145 / 255, b = 120 / 255 };

-- ============================================================================================================
-- What is under the mouse (no UI: the tests call these)
-- ============================================================================================================

-- an item: { kind, name, id }
function AutoPilotMoon.IdPicker.itemInfo(item, kind)
	if item == nil
	then
		return nil;
	end

	local ok, id = pcall(function() return item:getFullType(); end);

	if not ok or id == nil or id == ""
	then
		return nil;
	end

	local okName, name = pcall(function() return item:getDisplayName(); end);

	return { kind = kind or "item", id = id, name = (okName and name) or id };
end

-- The item of an inventory window's row under the screen point (mx, my): ISInventoryPane.updateTooltip of 42.22 (the
-- row = (y - headerHgt) / itemHgt + 1 in the pane's scrolled coordinates; a collapsed stack shows its first item)
function AutoPilotMoon.IdPicker.paneItemAt(pane, mx, my)
	if pane == nil or pane.items == nil or not pane:isReallyVisible()
	then
		return nil;
	end

	local ax, ay = pane:getAbsoluteX(), pane:getAbsoluteY();

	if mx < ax or my < ay or mx >= ax + pane:getWidth() or my >= ay + pane:getHeight()
	then
		return nil;
	end

	local scroll = pane:getYScroll();
	local y = my - ay - scroll;
	local header = pane.headerHgt or 0;

	if y + scroll < header or (pane.itemHgt or 0) <= 0
	then
		return nil;
	end

	local row = math.floor((y - header) / pane.itemHgt) + 1;
	local entry = pane.items[row];

	if entry == nil
	then
		return nil;
	end

	if instanceof(entry, "InventoryItem")
	then
		return entry;
	end

	return entry.items and entry.items[1] or nil;
end

-- the inventory and loot windows of a player that are on the screen
local function panes(playerNum)
	local list = {};

	for i, name in ipairs({ "getPlayerInventory", "getPlayerLoot" })
	do
		local fn = rawget(_G, name);
		local page = fn and fn(playerNum) or nil;

		if page and page.inventoryPane and (page.getIsVisible == nil or page:getIsVisible()) and not page.isCollapsed
		then
			table.insert(list, page.inventoryPane);
		end
	end

	return list;
end

-- a world object's name for people (a moveable's group and custom names, as the game builds them), or nil
local function objectName(object)
	local ok, name = pcall(function()
		-- PropertyContainer of 42.22: has / get (Is / Val are gone)
		local props = object:getSprite():getProperties();
		local group = props:has("GroupName") and props:get("GroupName") or nil;
		local custom = props:has("CustomName") and props:get("CustomName") or nil;

		if group and custom
		then
			return group .. " " .. custom;
		end

		return custom or group;
	end);

	return ok and name or nil;
end

-- What a square shows: an item on the ground (the last one put there), a workbench (its entity's id), the sprite of
-- the topmost object that is not the floor; nil when there is nothing with a name of the game
function AutoPilotMoon.IdPicker.squareInfo(square)
	if square == nil
	then
		return nil;
	end

	local items = square:getWorldObjects();

	if items and items:size() > 0
	then
		local object = items:get(items:size() - 1);
		local info = Pick.itemInfo(object:getItem(), "worldItem");

		if info
		then
			info.more = items:size() - 1;

			return info;
		end
	end

	local objects = square:getObjects();
	local floor = square:getFloor();
	local Bench = AutoPilotMoon.Macro and AutoPilotMoon.Macro.Bench;

	for i = objects:size() - 1, 0, -1
	do
		local object = objects:get(i);

		if object ~= floor and Bench
		then
			local okMaster, master = pcall(function() return object:getMasterObject() or object; end);

			master = okMaster and master or object;

			local id = Bench:idOf(master);

			if id
			then
				return { kind = "bench", id = id, name = Bench:nameOf(master, id) };
			end
		end
	end

	for i = objects:size() - 1, 0, -1
	do
		local object = objects:get(i);

		if object ~= floor
		then
			local ok, sprite = pcall(function() return object:getSprite():getName(); end);

			if ok and sprite and sprite ~= ""
			then
				return { kind = "sprite", id = sprite, name = objectName(object) or sprite };
			end
		end
	end

	return nil;
end

-- what is under the screen point for a player: an inventory or loot window first (they are drawn over the world),
-- else the square on the player's floor
function AutoPilotMoon.IdPicker.at(playerNum, mx, my)
	for i, pane in ipairs(panes(playerNum))
	do
		local ok, item = pcall(Pick.paneItemAt, pane, mx, my);

		if ok and item
		then
			return Pick.itemInfo(item, "item");
		end

		if ok and pane.getAbsoluteX and mx >= pane:getAbsoluteX() and mx < pane:getAbsoluteX() + pane:getWidth()
			and my >= pane:getAbsoluteY() and my < pane:getAbsoluteY() + pane:getHeight()
		then
			-- over the window but not on an item: not the world under it
			return nil;
		end
	end

	local ok, info = pcall(function()
		local player = getSpecificPlayer(playerNum);
		local z = math.floor(player:getZ());
		local x = math.floor(screenToIsoX(playerNum, mx, my, z));
		local y = math.floor(screenToIsoY(playerNum, mx, my, z));

		return Pick.squareInfo(getCell():getGridSquare(x, y, z));
	end);

	return ok and info or nil;
end

-- the item a controller has selected in the inventory or the loot window (their joypad selection), or nil
function AutoPilotMoon.IdPicker.joypadItem(playerNum)
	for i, pane in ipairs(panes(playerNum))
	do
		local index = pane.joyselection;

		if index ~= nil and pane.items
		then
			local entry = pane.items[index + 1];

			if entry ~= nil
			then
				if instanceof(entry, "InventoryItem")
				then
					return entry;
				end

				if entry.items and entry.items[1]
				then
					return entry.items[1];
				end
			end
		end
	end

	return nil;
end

-- the words of a result: { title, name, id, kind (what kind of name it is), more (other items on the square) }
function AutoPilotMoon.IdPicker.texts(info)
	local kinds = { item = "IGUI_AutoPilot_Pick_KindItem", worldItem = "IGUI_AutoPilot_Pick_KindWorldItem",
		bench = "IGUI_AutoPilot_Pick_KindBench", sprite = "IGUI_AutoPilot_Pick_KindSprite" };
	local t = { title = getText("IGUI_AutoPilot_Pick_Title"), name = info.name or info.id, id = info.id,
		kind = getText(kinds[info.kind] or kinds.item) };

	if info.more and info.more > 0
	then
		t.more = getText("IGUI_AutoPilot_Pick_More", info.more);
	end

	return t;
end

-- ============================================================================================================
-- Choosing
-- ============================================================================================================

function AutoPilotMoon.IdPicker:isAllowed()
	return AutoPilotMoon.Switch == nil or AutoPilotMoon.Switch:isOn();
end

function AutoPilotMoon.IdPicker:isPicking(playerNum)
	return Pick.overlays[playerNum] ~= nil;
end

-- the classes, derived at the first use (ISPanel and the panel's buttons exist by then)
function AutoPilotMoon.IdPicker:createClasses()
	if Pick.Overlay
	then
		return true;
	end

	if ISPanel == nil or ISPanelJoypad == nil or AutoPilotMoon.Panel == nil or not AutoPilotMoon.Panel:createClasses()
	then
		return false;
	end

	Pick.Overlay = ISPanel:derive("AutoPilotIdPickOverlay");

	for name, fn in pairs(Pick.OverlayMethods)
	do
		Pick.Overlay[name] = fn;
	end

	Pick.Result = ISPanelJoypad:derive("AutoPilotIdPickResult");

	for name, fn in pairs(Pick.ResultMethods)
	do
		Pick.Result[name] = fn;
	end

	return true;
end

-- the button pressed (the editor's or the panel's)
function AutoPilotMoon.IdPicker:begin(playerNum)
	if not Pick:isAllowed() or not Pick:createClasses()
	then
		return false;
	end

	Pick:cancel(playerNum);
	Pick:closeResult(playerNum);

	if UI:isJoypad(playerNum)
	then
		local info = Pick.itemInfo(Pick.joypadItem(playerNum), "item");

		if info
		then
			Pick:finish(playerNum, info);
		else
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_Pick_Joypad"), getSpecificPlayer(playerNum));
		end

		return info ~= nil;
	end

	local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum);
	local overlay = Pick.Overlay:new(left, top, getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum));

	overlay:initialise();
	overlay:instantiate();
	overlay.playerNum = playerNum;
	overlay.background = false;
	overlay:setAlwaysOnTop(true);
	overlay:setWantKeyEvents(true);
	overlay:addToUIManager();
	overlay:bringToTop();
	overlay:refresh();
	Pick.overlays[playerNum] = overlay;
	UI:playSound("UISelectListItem");

	return true;
end

-- Esc, a right click, the switch off, death: nothing chosen, nothing left in the game's UI
function AutoPilotMoon.IdPicker:cancel(playerNum)
	local overlay = Pick.overlays[playerNum];

	Pick.overlays[playerNum] = nil;

	if overlay
	then
		overlay:setVisible(false);
		overlay:removeFromUIManager();
	end
end

-- a name found: the box, the words over the head
function AutoPilotMoon.IdPicker:finish(playerNum, info)
	Pick:cancel(playerNum);

	local player = getSpecificPlayer(playerNum);

	AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_Pick_Said", info.name or info.id, info.id), player);
	Pick:showResult(playerNum, info, getMouseX(), getMouseY());
end

-- ============================================================================================================
-- The panel that catches the click
-- ============================================================================================================

local O = {};

Pick.OverlayMethods = O;

-- the lines of the help box: what to do, what is under the mouse now (or that there is nothing there)
function O:refresh()
	local mx, my = getMouseX(), getMouseY();

	if mx == self.mx and my == self.my and self.lines
	then
		return;
	end

	self.mx, self.my = mx, my;

	local info = Pick.at(self.playerNum, mx, my);
	local lines = { { text = getText("IGUI_AutoPilot_Pick_Help"), color = UI.inputColor } };

	if info
	then
		table.insert(lines, { text = (info.name or info.id) .. "  -  " .. info.id, color = UI.textColor });
	elseif self.nothing
	then
		local r, g, b = UI:badColor();

		table.insert(lines, { text = getText("IGUI_AutoPilot_Pick_Nothing"), color = { r = r, g = g, b = b } });
	end

	local width = 0;

	for i, line in ipairs(lines)
	do
		line.width = getTextManager():MeasureStringX(UIFont.Small, line.text);
		width = math.max(width, line.width);
	end

	self.lines = lines;
	self.boxWidth = width + 2 * UI.spacing;
	self.boxHeight = #lines * (getTextManager():getFontHeight(UIFont.Small) + 2) + UI.spacing;
end

function O:prerender()
end

-- the help box beside the mouse, inside the player's screen (as the area tool's)
function O:render()
	self:refresh();

	if self.lines == nil
	then
		return;
	end

	local w, h = self.boxWidth, self.boxHeight;
	local x = getMouseX() - self:getAbsoluteX() + UI.boxOffset;
	local y = getMouseY() - self:getAbsoluteY() + UI.boxOffset;

	if x + w > self.width
	then
		x = getMouseX() - self:getAbsoluteX() - UI.boxOffset - w;
	end

	if y + h > self.height
	then
		y = getMouseY() - self:getAbsoluteY() - UI.boxOffset - h;
	end

	x = math.max(0, math.min(x, self.width - w));
	y = math.max(0, math.min(y, self.height - h));
	self:drawRect(x, y, w, h, 0.8, 0.05, 0.05, 0.05);
	self:drawRectBorder(x, y, w, h, 0.5, 0.9, 0.9, 1);

	local lh = getTextManager():getFontHeight(UIFont.Small) + 2;

	for i, line in ipairs(self.lines)
	do
		local c = line.color;

		self:drawText(line.text, x + UI.spacing, y + UI.spacing / 2 + (i - 1) * lh, c.r, c.g, c.b, 1, UIFont.Small);
	end
end

function O:onMouseDown(x, y)
	local info = Pick.at(self.playerNum, getMouseX(), getMouseY());

	if info
	then
		Pick:finish(self.playerNum, info);
	else
		self.nothing = true;
		self.lines = nil;
	end

	return true;
end

function O:onMouseUp(x, y)
	return true;
end

function O:onMouseMove(dx, dy)
	self.nothing = false;

	return true;
end

function O:onRightMouseDown(x, y)
	return true;
end

function O:onRightMouseUp(x, y)
	Pick:cancel(self.playerNum);

	return true;
end

function O:isKeyConsumed(key)
	return key == 1;
end

function O:onKeyRelease(key)
	if key == 1
	then
		Pick:cancel(self.playerNum);
	end
end

-- ============================================================================================================
-- The result
-- ============================================================================================================

local R = {};

Pick.ResultMethods = R;

-- the box near the point (mx, my), inside the player's screen
function AutoPilotMoon.IdPicker:showResult(playerNum, info, mx, my)
	if not Pick:createClasses()
	then
		return nil;
	end

	Pick:closeResult(playerNum);

	local box = Pick.Result:new(0, 0, 10, 10);

	box.playerNum = playerNum;
	box.info = info;
	box:initialise();
	box:instantiate();
	box:setAlwaysOnTop(true);
	box:setWantKeyEvents(true);
	box:build();
	box:place(mx or getMouseX(), my or getMouseY());
	box:addToUIManager();
	box:bringToTop();
	Pick.results[playerNum] = box;

	if UI:isJoypad(playerNum)
	then
		setJoypadFocus(playerNum, box);
	end

	return box;
end

function AutoPilotMoon.IdPicker:closeResult(playerNum)
	local box = Pick.results[playerNum];

	Pick.results[playerNum] = nil;

	if box
	then
		box:setVisible(false);
		box:removeFromUIManager();

		local joypadData = JoypadState and JoypadState.players[playerNum + 1];

		if joypadData and joypadData.focus == box
		then
			setJoypadFocus(playerNum, nil);
		end
	end
end

-- the player's macro editor, when it can take the name
function AutoPilotMoon.IdPicker.editorFor(playerNum)
	local Editor = AutoPilotMoon.Macro and AutoPilotMoon.Macro.Editor;
	local window = Editor and Editor.windows and Editor.windows[playerNum];

	if window and window:getIsVisible() and window.editable == true
	then
		return window;
	end

	return nil;
end

local function measure(font, text)
	return getTextManager():MeasureStringX(font, text or "");
end

-- a text cut with "..." to a width
local function fit(font, text, width)
	if measure(font, text) <= width
	then
		return text;
	end

	local n = string.len(text);

	while n > 1 and measure(font, string.sub(text, 1, n) .. "...") > width
	do
		n = n - 1;
	end

	return string.sub(text, 1, n) .. "...";
end

-- the texts and the buttons, their sizes
function R:build()
	local sizes = AutoPilotMoon.Panel:getSizes();
	local pad = sizes.pad;
	local texts = Pick.texts(self.info);
	local codeFont = (UIFont.CodeSmall and AutoPilotMoon.Options:get("macroCodeFont") ~= false) and UIFont.CodeSmall or UIFont.Small;
	local maxText = math.floor(getPlayerScreenWidth(self.playerNum) * 0.45) - 2 * pad;
	local Button = AutoPilotMoon.Panel.Button or ISButton;

	self.sizes = sizes;
	self.codeFont = codeFont;
	self.buttons = {};

	local function button(titleKey, fn)
		local b = Button:new(0, 0, 10, sizes.button, getText(titleKey), self, fn);

		b:initialise();
		b:setWidthToTitle(sizes.button * 3);
		self:addChild(b);
		table.insert(self.buttons, b);

		return b;
	end

	self.copyButton = button("IGUI_AutoPilot_Pick_Copy", R.onCopy);

	if Pick.editorFor(self.playerNum)
	then
		self.insertButton = button("IGUI_AutoPilot_Pick_Insert", R.onInsert);
	end

	self.closeButton = button("IGUI_AutoPilot_Pick_Close", R.onClose);

	local buttonsWidth = -pad;

	for i, b in ipairs(self.buttons)
	do
		buttonsWidth = buttonsWidth + b:getWidth() + pad;
	end

	local rows = {
		{ text = texts.title, font = UIFont.Small, color = UI.titleColor },
		{ text = texts.name, font = UIFont.Medium, color = UI.textColor },
		{ text = texts.id, font = codeFont, color = Pick.idColor },
		{ text = texts.kind, font = UIFont.Small, color = UI.greyColor },
	};

	if texts.more
	then
		table.insert(rows, { text = texts.more, font = UIFont.Small, color = UI.greyColor });
	end

	local width = buttonsWidth;

	for i, row in ipairs(rows)
	do
		row.text = fit(row.font, row.text, maxText);
		row.height = getTextManager():getFontHeight(row.font);
		width = math.max(width, measure(row.font, row.text));
	end

	local y = pad;

	for i, row in ipairs(rows)
	do
		row.y = y;
		y = y + row.height + 2;
	end

	y = y + pad / 2;

	local x = pad;

	for i, b in ipairs(self.buttons)
	do
		b:setX(x);
		b:setY(y);
		x = x + b:getWidth() + pad;
	end

	self.rows = rows;
	self:setWidth(width + 2 * pad);
	self:setHeight(y + sizes.button + pad);
end

-- below-right of the point, moved to stay inside the player's screen
function R:place(mx, my)
	local playerNum = self.playerNum;
	local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum);
	local right, bottom = left + getPlayerScreenWidth(playerNum), top + getPlayerScreenHeight(playerNum);
	local x = mx + UI.boxOffset;
	local y = my + UI.boxOffset;

	if x + self.width > right
	then
		x = mx - UI.boxOffset - self.width;
	end

	if y + self.height > bottom
	then
		y = my - UI.boxOffset - self.height;
	end

	self:setX(math.floor(math.max(left, math.min(x, right - self.width))));
	self:setY(math.floor(math.max(top, math.min(y, bottom - self.height))));
end

function R:prerender()
	self:drawRect(0, 0, self.width, self.height, 0.92, 0.05, 0.05, 0.05);
	self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.9, 0.9, 1);

	local pad = self.sizes.pad;

	for i, row in ipairs(self.rows or {})
	do
		local c = row.color;

		self:drawText(row.text, pad, row.y, c.r, c.g, c.b, 1, row.font);
	end
end

function R:onCopy()
	Clipboard.setClipboard(self.info.id);
	self.copyButton:setTitle(getText("IGUI_AutoPilot_Pick_Copied"));
end

function R:onInsert()
	local window = Pick.editorFor(self.playerNum);

	if window
	then
		window:insertChosen("item", self.info.id);
	end

	Pick:closeResult(self.playerNum);
end

function R:onClose()
	Pick:closeResult(self.playerNum);
end

function R:isKeyConsumed(key)
	return key == 1;
end

function R:onKeyRelease(key)
	if key == 1
	then
		Pick:closeResult(self.playerNum);
	end
end

-- the controller: A copies, X inserts in the editor, B closes
function R:onJoypadDown(button, joypadData)
	if button == Joypad.AButton
	then
		self:onCopy();
	elseif button == Joypad.XButton and self.insertButton
	then
		self:onInsert();
	elseif button == Joypad.BButton
	then
		Pick:closeResult(self.playerNum);
	end
end

-- ============================================================================================================
-- Exits
-- ============================================================================================================

-- the player's switch off (client/06_AP_Switch.lua): nothing left in the game's UI
function AutoPilotMoon.IdPicker:shutdown()
	local numbers = {};

	for playerNum in pairs(Pick.overlays)
	do
		table.insert(numbers, playerNum);
	end

	for playerNum in pairs(Pick.results)
	do
		table.insert(numbers, playerNum);
	end

	for i, playerNum in ipairs(numbers)
	do
		Pick:cancel(playerNum);
		Pick:closeResult(playerNum);
	end
end

function AutoPilotMoon.IdPicker:onPlayerDeath(player)
	if player
	then
		Pick:cancel(player:getPlayerNum());
		Pick:closeResult(player:getPlayerNum());
	end
end
