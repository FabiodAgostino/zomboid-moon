-- AutoPilot (Moon): automations for the Moon server.

-- The macro editor (spec MACRO-AUTOPILOT.md 4): a window of the game's own kind (ISCollapsableWindowJoypad: title,
-- "?" guide, collapse, close, resized in width and height, position and size remembered by the game's layout file as
-- "AutoPilotMoonMacro"), one per local player. Left: "Le tue macro" (the last used first; "(!)" in the bad colour with
-- "Problemi: n" as its tooltip, "(in corso)" for the macro running), "Esempi" (read-only), Nuova, Registra and "..."
-- (the macro's menu, also on the right click and on Y: Avvia, Rinomina, Duplica, Copia il testo, Copia con gli id,
-- Ripristina la versione di prima, Elimina; Incolla come nuova). Right: the name (a click renames it in place: Enter
-- confirms, Esc cancels), the save state and the problems in words; the text (the game's multi-line text box, the line
-- numbers on its left, "!" on a line with an error and ">" on the line running; with the option "Colori nel codice"
-- the colours of Visual Studio's dark theme drawn over it by MacroCodeView.lua, and the long lines wrapped, their
-- number on their first row only); the status bar
-- ("Riga 3, colonna 12 - 5 righe", Inserisci, Compila); the problems, each one a click to its line, then "can I do
-- this now?". At the bottom the server's limits and Avvia / Ferma.
--
-- Cost (4.10): render and prerender only draw strings already made; the text is read only 600 ms after the last change
-- (or with Compila), never every frame; "can I do this now?" every 2 s at most, only visible; the file at most every
-- 2 s and when closing; a hidden or collapsed window does nothing. The keys go to the text box while it has the focus:
-- the game's GameKeyboard.isKeyDown answers false for every key while a text box is doing text entry (42.22 jar), so
-- typing never moves the character. The suggestions while typing (MacroSuggest.lua, MacroSuggestView.lua, 4.12) use
-- Tab, Esc, Up, Down and Enter only while their list is open, Ctrl+Space to open it; with it closed every key is the
-- box's own.
-- With a controller (4.9): A = Avvia / Ferma, X = Registra, Y = the macro's menu, B = close, up / down the list;
-- writing needs a keyboard (said in the guide).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Editor = AutoPilotMoon.Macro.Editor or {};
AutoPilotMoon.Macro.EditorModel = AutoPilotMoon.Macro.EditorModel or {};   -- filled by MacroEditorModel.lua, loaded after

local Editor = AutoPilotMoon.Macro.Editor;
local Model = AutoPilotMoon.Macro.EditorModel;
local UI = AutoPilotMoon.UI;
local A = AutoPilotMoon.Automation;

Editor.windows = Editor.windows or {};
Editor.layoutName = "AutoPilotMoonMacro";
Editor.checkDelayMs = 600;
Editor.saveDelayMs = 2000;
Editor.probeEveryMs = 2000;
Editor.savingShownMs = 400;
Editor.maxScreenShare = 0.8;
Editor.problemRows = 4;

local function Macro()
	return AutoPilotMoon.Macro;
end

local function goodColor()
	local r, g, b = UI:goodColor();

	return { r = r, g = g, b = b };
end

local function badColor()
	local r, g, b = UI:badColor();

	return { r = r, g = g, b = b };
end

-- the warnings (MacroLang's severity "warning"): amber, apart from the errors' red and the progress' yellow
Editor.warnColor = { r = 1, g = 0.7, b = 0.2 };

local function colorOf(color)
	if color == "good"
	then
		return goodColor();
	elseif color == "bad"
	then
		return badColor();
	elseif color == "warn"
	then
		return Editor.warnColor;
	end

	return color or UI.textColor;
end

local function measure(font, text)
	return getTextManager():MeasureStringX(font, text);
end

-- the text, or its start with "..." when it is wider than width (measured when the texts change, never in render)
local function fitText(font, text, width)
	if text == nil or measure(font, text) <= width
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

-- a button's colour ("accept", "cancel" or nil), on or grey with the reason as its tooltip. ISButton:setEnable keeps
-- the colours of its first call to give them back: they are forgotten first, so a colour changed meanwhile holds.
function AutoPilotMoon.Macro.Editor.setButton(button, mode, enabled, reason)
	button.borderColorEnabled = nil;
	button.backgroundColorEnabled = nil;

	if mode == "accept"
	then
		button:enableAcceptColor();
	elseif mode == "cancel"
	then
		button:enableCancelColor();
	end

	button:setEnable(enabled);
	button.tooltip = (not enabled) and reason or nil;
end

-- the text's font: a fixed-width one when the player wants it (option macroCodeFont). UIFont.CodeSmall, not
-- UIFont.Code: Code (zomboidCode.fnt) has one size only, 16 px, and with the game's font at 2x-4x the macro was much
-- smaller than the rest of the window; CodeSmall (codeSmall.fnt, fixed width, with the accented letters) has a file
-- for each font size of the game, as tall as UIFont.Small
function AutoPilotMoon.Macro.Editor:getCodeFont()
	if AutoPilotMoon.Options:get("macroCodeFont") and UIFont.CodeSmall
	then
		return UIFont.CodeSmall;
	end

	return UIFont.Small;
end

-- ============================================================================================================
-- The classes (derived at the game's start and before the first use)
-- ============================================================================================================

local W = {};
local L = {};
local G = {};

Editor.WindowMethods = W;

function AutoPilotMoon.Macro.Editor:createClasses()
	if Editor.Window
	then
		return true;
	end

	if ISCollapsableWindowJoypad == nil or ISScrollingListBox == nil or ISTextEntryBox == nil or ISPanel == nil
		or AutoPilotMoon.Panel == nil or not AutoPilotMoon.Panel:createClasses()
	then
		return false;
	end

	Editor.List = ISScrollingListBox:derive("AutoPilotMacroList");

	for name, fn in pairs(L)
	do
		Editor.List[name] = fn;
	end

	Editor.Gutter = ISPanel:derive("AutoPilotMacroGutter");

	for name, fn in pairs(G)
	do
		Editor.Gutter[name] = fn;
	end

	-- the suggestions' popup (MacroSuggestView.lua)
	Editor.Popup = ISPanel:derive("AutoPilotMacroSuggest");

	for name, fn in pairs(AutoPilotMoon.Macro.SuggestView.PopupMethods)
	do
		Editor.Popup[name] = fn;
	end

	Editor.Window = ISCollapsableWindowJoypad:derive("AutoPilotMacroEditor");

	for name, fn in pairs(W)
	do
		Editor.Window[name] = fn;
	end

	return true;
end

-- a list line: the name, then its suffix ("(!)" in the bad colour, "(in corso)")
function L:doDrawItem(y, item, alt)
	local height = item.height or self.itemheight;

	if self.selected == item.index
	then
		self:drawRect(0, y, self:getWidth(), height - 1, 0.3, 0.7, 0.35, 0.15);
	elseif self.mouseoverselected == item.index and self:isMouseOver()
	then
		self:drawRect(0, y, self:getWidth(), height - 1, 0.95, 0.05, 0.05, 0.05);
	end

	local entry = item.item;
	local textY = y + (height - self.fontHgt) / 2;
	local c = entry.textColor or UI.textColor;

	-- a problem longer than the list: its lines (made by W:wrapProblems when the text or the width changes)
	if entry.lines
	then
		local lineY = y + (self.itemheight - self.fontHgt) / 2;

		for i, line in ipairs(entry.lines)
		do
			self:drawText(line, 8, lineY, c.r, c.g, c.b, 1, self.font);
			lineY = lineY + self.fontHgt;
		end

		return y + height;
	end

	self:drawText(entry.text, 8, textY, c.r, c.g, c.b, 1, self.font);

	if entry.suffix
	then
		local sc = entry.bad and badColor() or AutoPilotMoon.Panel.colors.grey;

		if entry.color
		then
			sc = colorOf(entry.color);
		end

		self:drawText(entry.suffix, 8 + entry.textWidth + 6, textY, sc.r, sc.g, sc.b, 1, self.font);
	end

	return y + height;
end

function L:onRightMouseUp(x, y)
	local row = self:rowAt(x, y);

	if row >= 1 and row <= #self.items
	then
		self.selected = row;
		self:invokeOnMouseDownFunction();

		if self.onRightClick
		then
			self.onRightClick(self.target, self, self.items[row].item, x, y);
		end
	end

	return true;
end

-- the line numbers: only the visible ones, strings made once ("1".."200"), "!" on an error line and ">" on the line
-- running (4.3); the text box's own rows (a wrapped line has its number on its first row), scroll and line height
G.numbers = nil;

function G:render()
	local window = self.window;
	local entry = window and window.entry;

	if entry == nil or entry.javaObject == nil
	then
		return;
	end

	if G.numbers == nil
	then
		G.numbers = {};

		for i = 1, AutoPilotMoon.Macro.Lang.maxLines
		do
			G.numbers[i] = tostring(i);
		end
	end

	window:syncView();

	local rows = window.codeView.rows;
	local lineHeight = window.lineHeight;
	local inset = window.textInset;
	local scroll = entry:getYScroll();
	local first = math.max(1, math.floor(-scroll / lineHeight) + 1);
	local visible = math.floor(self.height / lineHeight) + 1;
	local grey = AutoPilotMoon.Panel.colors.grey;
	local errors = window.errorLines;
	local running = window.runningLine;
	local font = window.codeFont;
	local right = self.width - 4;

	-- the last row can be half visible (as in the text field, which cuts it at its edge): its number cut the same way,
	-- not drawn over the window below the gutter
	self:setStencilRect(0, 0, self.width, self.height);

	for index = first, math.min(#rows, first + visible)
	do
		local y = inset + (index - 1) * lineHeight + scroll;
		local row = rows[index];
		local line = row.line;

		if y > self.height
		then
			break;
		end

		if not row.first or line > AutoPilotMoon.Macro.Lang.maxLines
		then
			-- a wrapped line's next rows, a line past the limit: no number
		elseif running == line
		then
			local c = UI.inputColor;

			self:drawText(">", 2, y, c.r, c.g, c.b, 1, font);
			self:drawTextRight(G.numbers[line], right, y, c.r, c.g, c.b, 1, font);
		elseif errors and errors[line]
		then
			local c = window.badColor;

			self:drawText("!", 2, y, c.r, c.g, c.b, 1, font);
			self:drawTextRight(G.numbers[line], right, y, c.r, c.g, c.b, 1, font);
		else
			self:drawTextRight(G.numbers[line], right, y, grey.r, grey.g, grey.b, 1, font);
		end
	end

	self:clearStencilRect();
end

-- ============================================================================================================
-- Opening, closing
-- ============================================================================================================

function AutoPilotMoon.Macro.Editor:getLayoutName(playerNum)
	if playerNum == 0
	then
		return Editor.layoutName;
	end

	return Editor.layoutName .. playerNum;
end

-- the window's sizes from the game's font (spec 4.2: about 64 x 30 small characters, at least 44 x 20, at most 80% of
-- the player's screen)
function AutoPilotMoon.Macro.Editor:getSizes()
	local sizes = AutoPilotMoon.Panel:getSizes();
	local unit = math.floor(sizes.small * 0.75 + 0.5);

	sizes.unit = unit;
	sizes.defaultWidth = 64 * unit;
	sizes.defaultHeight = 30 * sizes.small;
	sizes.minWidth = 44 * unit;
	sizes.minHeight = 20 * sizes.small;

	return sizes;
end

function AutoPilotMoon.Macro.Editor:isOpen(playerNum)
	local window = Editor.windows[playerNum];

	return window ~= nil and window:getIsVisible();
end

-- opens the editor of a local player (name: the macro to show; fromMenu: a controller takes the focus)
function AutoPilotMoon.Macro.Editor:open(playerNum, name, fromMenu)
	if not Editor:createClasses()
	then
		return nil;
	end

	Macro().Store:load();
	Macro().Names:ensure();

	local window = Editor.windows[playerNum];

	if window == nil
	then
		local sizes = Editor:getSizes();
		local width = math.min(sizes.defaultWidth, math.floor(getPlayerScreenWidth(playerNum) * Editor.maxScreenShare));
		local height = math.min(sizes.defaultHeight, math.floor(getPlayerScreenHeight(playerNum) * Editor.maxScreenShare));
		local x = getPlayerScreenLeft(playerNum) + math.floor((getPlayerScreenWidth(playerNum) - width) / 2);
		local y = getPlayerScreenTop(playerNum) + math.floor((getPlayerScreenHeight(playerNum) - height) / 2);

		window = Editor.Window:new(x, y, width, height);
		window.playerNum = playerNum;
		window.sizes = sizes;
		window.minimumWidth = math.min(sizes.minWidth, width);
		window.minimumHeight = math.min(sizes.minHeight, height);
		window.titleBarFont = UIFont.Small;
		window:setTitle(getText("IGUI_AutoPilot_E_Title"));
		window:initialise();
		window:instantiate();
		window:setVisible(false);
		window:addToUIManager();
		Editor.windows[playerNum] = window;
		ISLayoutManager.RegisterWindow(Editor:getLayoutName(playerNum), Editor.Window, window);
	end

	window.player = getSpecificPlayer(playerNum);

	-- the option "lettere tutte larghe uguali" may have changed in the Options
	local font = Editor:getCodeFont();

	if window.codeFont ~= font
	then
		window.codeFont = font;
		window.lineHeight = getTextManager():getFontHeight(font);
		window.entry:setFont(font);
		window:relayout();
	end

	-- the option "Colori nel codice" may have changed too
	window:applyColors();

	if window.isCollapsed
	then
		window.isCollapsed = false;
		window:clearMaxDrawHeight();
	end

	window:setVisible(true);
	window:bringToTop();

	-- the macro shown before may be gone (deleted, the file recovered from its backup)
	if window.selected and not window.selected.example and Macro().Store:get(window.selected.macro.name) ~= window.selected.macro
	then
		window.selected = nil;
	end

	window:fillLists();

	if name
	then
		window:selectByName(name);
	elseif window.selected == nil
	then
		window:selectFirst();
	end

	window:refresh();

	if fromMenu and UI:isJoypad(playerNum)
	then
		setJoypadFocus(playerNum, window);
	end

	return window;
end

function AutoPilotMoon.Macro.Editor:close(playerNum)
	local window = Editor.windows[playerNum];

	if window and window:getIsVisible()
	then
		window:close();
	end
end

function AutoPilotMoon.Macro.Editor:toggle(playerNum, fromMenu)
	local window = Editor.windows[playerNum];

	if window and window:getIsVisible() and not window.isCollapsed
	then
		window:close();
	else
		Editor:open(playerNum, nil, fromMenu);
	end
end

-- a text box of ours has the keyboard (the key must then not open or close anything)
function AutoPilotMoon.Macro.Editor:isTyping()
	for playerNum, window in pairs(Editor.windows)
	do
		if window:getIsVisible() and ((window.entry and window.entry:isFocused()) or (window.renameEntry and window.renameEntry:getIsVisible() and window.renameEntry:isFocused()))
		then
			return true;
		end
	end

	local picker = Macro().Picker and Macro().Picker.window;

	return picker ~= nil and picker:getIsVisible() and picker.search ~= nil and picker.search:isFocused();
end

-- the player's key (option macroEditorKey, none by default), never while typing in the chat or in a text box of ours
function AutoPilotMoon.Macro.Editor.onKeyPressed(key)
	local wanted = AutoPilotMoon.Options:get("macroEditorKey");

	if wanted == nil or wanted == 0 or key ~= wanted or not A:isAllowedByServer("macro")
	then
		return;
	end

	local chat = rawget(_G, "ISChat");

	if (chat and chat.focused) or Editor:isTyping()
	then
		return;
	end

	local player = getSpecificPlayer(0);

	if player and not player:isDead()
	then
		Editor:toggle(0, false);
	end
end

function AutoPilotMoon.Macro.Editor:onPlayerDeath(player)
	if player
	then
		Editor:close(player:getPlayerNum());
	end
end

-- the player's master switch turned off (client/06_AP_Switch.lua): every editor closes as with its button (the text
-- saved, the recipe picker closed) and leaves the game's UI list (the game updates even hidden elements at every
-- frame; the editor's update polls the suggestions); a recipe list still being built in slices stops
function AutoPilotMoon.Macro.Editor:shutdown()
	local numbers = {};

	for playerNum, window in pairs(Editor.windows)
	do
		table.insert(numbers, playerNum);
	end

	for i, playerNum in ipairs(numbers)
	do
		local window = Editor.windows[playerNum];

		Editor.windows[playerNum] = nil;

		if window:getIsVisible()
		then
			window:close();
		end

		window:removeFromUIManager();

		-- the list of the suggestions is a window of its own
		local suggest = window.suggest;

		if suggest and suggest.popup
		then
			suggest:close();
			suggest.popup:removeFromUIManager();
			suggest.popup = nil;
		end
	end

	if Macro().Picker
	then
		Macro().Picker:closeFor(nil);
	end

	local names = Macro().Names;

	if names and names.state == "building"
	then
		names:forget();
	end
end

-- ============================================================================================================
-- The window: children
-- ============================================================================================================

local function newButton(window, title, onclick, accept, cancel)
	local sizes = window.sizes;
	local button = AutoPilotMoon.Panel.Button:new(0, 0, 10, sizes.button, title, window, onclick);

	button:initialise();
	button:instantiate();

	if accept
	then
		button:enableAcceptColor();
	elseif cancel
	then
		button:enableCancelColor();
	end

	button:setWidthToTitle(sizes.button * 2);
	window:addChild(button);

	return button;
end

-- After a new size: the scroll bar on the right edge, as tall as its list or text field. ISScrollBar follows its
-- parent only through the anchors of zombie.ui.UIElement, which apply the change of the last setWidth / setHeight
-- before the next update: the lists are made 10 x 10 and sized by relayout, and two layouts before an update lost the
-- change (in the game the bar stayed at the left edge and the list's stencil hid every row). The game's own windows
-- place their bars by hand the same way (ISCraftInventoryPanel, ISWidgetRecipeListPanel).
local function fitScrollBar(element)
	local bar = element and element.vscroll;

	if bar == nil
	then
		return;
	end

	element:ignoreWidthChange();
	element:ignoreHeightChange();
	bar:setX(element:getWidth() - bar:getWidth());
	bar:setY(0);
	bar:setHeight(element:getHeight());
end

local function newList(window, onSelect)
	local sizes = window.sizes;
	local list = Editor.List:new(0, 0, 10, 10);

	list:initialise();
	list:instantiate();
	list:setFont(UIFont.Small, 3);
	list.drawBorder = true;
	list:setOnMouseDownFunction(window, onSelect);
	list.onRightClick = W.onListRightClick;
	window:addChild(list);

	return list;
end

function W:createChildren()
	ISCollapsableWindowJoypad.createChildren(self);

	local sizes = self.sizes;

	self:setInfo(getText("IGUI_AutoPilot_E_Info"));
	self:setResizable(true);
	self.badColor = badColor();
	self.unsavedText = Model:saveText("unsaved");
	self.codeFont = Editor:getCodeFont();
	self.lineHeight = getTextManager():getFontHeight(self.codeFont);
	self.textInset = 2;

	local function resized(target, width, height)
		local maxWidth = math.floor(getPlayerScreenWidth(target.playerNum) * Editor.maxScreenShare);
		local maxHeight = math.floor(getPlayerScreenHeight(target.playerNum) * Editor.maxScreenShare);

		target:setWidth(math.max(target.minimumWidth, math.min(width, maxWidth)));
		target:setHeight(math.max(target.minimumHeight, math.min(height, maxHeight)));
		target:relayout();
	end

	if self.resizeWidget
	then
		self.resizeWidget.resizeFunction = resized;
	end

	if self.resizeWidget2
	then
		self.resizeWidget2.resizeFunction = resized;
	end

	self.myList = newList(self, W.onSelectMine);
	self.exampleList = newList(self, W.onSelectExample);

	self.newButton = newButton(self, getText("IGUI_AutoPilot_E_New"), W.onNew);
	self.recordButton = newButton(self, getText("IGUI_AutoPilot_E_Record"), W.onRecord);
	self.moreButton = newButton(self, "...", W.onMore);
	self.moreButton:setWidth(sizes.button * 1.5);

	self.duplicateButton = newButton(self, getText("IGUI_AutoPilot_E_Duplicate"), W.onDuplicate);

	self.entry = ISTextEntryBox:new("", 0, 0, 10, 10);
	self.entry:initialise();
	self.entry:instantiate();
	self.entry:setFont(self.codeFont);
	self.entry:setMultipleLine(true);
	self.entry:setMaxLines(AutoPilotMoon.Macro.Lang.maxLines);
	self.entry.javaObject:setMaxTextLength(AutoPilotMoon.Macro.Lang.maxLines * (AutoPilotMoon.Macro.Lang.maxLineChars + 1));
	self.entry.javaObject:setWrapLines(false);
	self.entry:addScrollBars();
	self.entry.onTextChangeFunction = W.onBoxTextChange;
	-- the keys the box gives its Lua table (UITextBox2 42.22): Tab and Esc, Up and Down after it moved the cursor; for
	-- the suggestions, only while their list is open
	self.entry.onOtherKey = W.onEntryOtherKey;
	self.entry.onPressUp = W.onEntryPressUp;
	self.entry.onPressDown = W.onEntryPressDown;
	self.entry.target = self;
	self:addChild(self.entry);
	self.suggest = AutoPilotMoon.Macro.SuggestView:attach(self);

	-- where the box draws its first line (UITextBox2.getInset of 42.22), for the line numbers
	self.textInset = self.entry.javaObject:getInset();

	-- the colours (MacroCodeView.lua): the rows of the box worked out again, drawn over its text (the window's render,
	-- after the box)
	self.codeView = AutoPilotMoon.Macro.CodeView:new();
	self:applyColors();

	self.gutter = Editor.Gutter:new(0, 0, 10, 10);
	self.gutter:initialise();
	self.gutter:instantiate();
	self.gutter.background = false;
	self.gutter.window = self;
	self:addChild(self.gutter);

	self.insertButton = newButton(self, getText("IGUI_AutoPilot_E_Insert") .. " v", W.onInsert);
	self.checkButton = newButton(self, getText("IGUI_AutoPilot_E_Check"), W.onCheck);

	self.problemList = Editor.List:new(0, 0, 10, 10);
	self.problemList:initialise();
	self.problemList:instantiate();
	self.problemList:setFont(UIFont.Small, 1);
	self.problemList.drawBorder = true;
	self.problemList:setOnMouseDownFunction(self, W.onProblem);
	self:addChild(self.problemList);

	self.runButton = newButton(self, getText("IGUI_AutoPilot_E_Run"), W.onRun, true);
	self.runButton:setWidth(math.max(self.runButton:getWidth(), sizes.button * 5));
	self.runButton:setHeight(sizes.button + 4);

	self.renameEntry = ISTextEntryBox:new("", 0, 0, 10, sizes.button);
	self.renameEntry:initialise();
	self.renameEntry:instantiate();
	self.renameEntry:setMaxTextLength(AutoPilotMoon.Macro.Store.maxNameChars);
	self.renameEntry.onCommandEntered = W.onRenameEnter;
	self.renameEntry.onOtherKey = W.onRenameKey;
	self.renameEntry.onTextChangeFunction = W.onRenameChange;
	self.renameEntry.target = self;
	self.renameEntry.window = self;
	self.renameEntry:setVisible(false);
	self:addChild(self.renameEntry);

	self:relayout();
end

-- ============================================================================================================
-- Layout (when the size changes, never in render)
-- ============================================================================================================

function W:relayout()
	local sizes = self.sizes;
	local pad = sizes.pad;
	local row = sizes.row;
	local width = self.width;
	local height = self.height;
	local top = self:titleBarHeight() + pad;
	local bottom = height - self:resizeWidgetHeight() - pad;
	local leftWidth = math.max(18 * sizes.unit, math.floor((width - 3 * pad) * 0.3));
	local right = pad + leftWidth + pad;
	local rightWidth = width - right - pad;
	local labels = {};

	-- the bottom bar: the server's limits and Avvia
	local runY = bottom - self.runButton:getHeight();

	self.runButton:setX(width - pad - self.runButton:getWidth());
	self.runButton:setY(runY);
	self.limitsY = runY + (self.runButton:getHeight() - sizes.small) / 2;
	self.bottomSeparatorY = runY - pad / 2;

	local contentBottom = self.bottomSeparatorY - pad / 2;

	-- left: the lists and their buttons
	local buttonsY = contentBottom - sizes.button;

	self.newButton:setX(pad);
	self.newButton:setY(buttonsY);
	self.recordButton:setX(pad + self.newButton:getWidth() + pad / 2);
	self.recordButton:setY(buttonsY);
	self.moreButton:setX(pad + leftWidth - self.moreButton:getWidth());
	self.moreButton:setY(buttonsY);

	local exampleCount = #(self.exampleList.items or {});
	local exampleHeight = math.max(1, exampleCount) * self.exampleList.itemheight + 2;

	-- the column shared: "Le tue macro" keeps at least two rows and its title, the examples scroll when they do not fit
	-- (five examples with the big font on a small screen pushed the examples' title under my list)
	local room = buttonsY - pad / 2 - (top + row) - self.myList.itemheight * 2 - pad / 2 - row;

	exampleHeight = math.max(self.exampleList.itemheight + 2, math.min(exampleHeight, room));

	local exampleY = buttonsY - pad / 2 - exampleHeight;

	self.examplesLabelY = exampleY - row;
	self.exampleList:setX(pad);
	self.exampleList:setY(exampleY);
	self.exampleList:setWidth(leftWidth);
	self.exampleList:setHeight(exampleHeight);

	self.yoursLabelY = top;
	self.myList:setX(pad);
	self.myList:setY(top + row);
	self.myList:setWidth(leftWidth);
	self.myList:setHeight(math.max(self.myList.itemheight * 2, self.examplesLabelY - pad / 2 - (top + row)));
	fitScrollBar(self.exampleList);
	fitScrollBar(self.myList);

	-- right: name, banner, text, status bar, problems
	self.rightX = right;
	self.rightWidth = rightWidth;
	self.nameY = top;

	local y = top + sizes.medium + pad / 2;

	self.nameSeparatorY = y;
	y = y + pad / 2;
	self.bannerY = y;

	if self.bannerText
	then
		self.duplicateButton:setX(right + rightWidth - self.duplicateButton:getWidth());
		self.duplicateButton:setY(y);
		y = y + math.max(row, sizes.button) + pad / 2;
	end

	self.duplicateButton:setVisible(self.bannerText ~= nil and self.bannerIsExample == true);

	local problemsHeight = Editor.problemRows * self.problemList.itemheight + 2;
	local problemsY = contentBottom - problemsHeight;
	local statusY = problemsY - pad / 2 - sizes.button;

	self.problemList:setX(right);
	self.problemList:setY(problemsY);
	self.problemList:setWidth(rightWidth);
	self.problemList:setHeight(problemsHeight);
	fitScrollBar(self.problemList);
	self:wrapProblems();

	self.checkButton:setX(right + rightWidth - self.checkButton:getWidth());
	self.checkButton:setY(statusY);
	self.insertButton:setX(self.checkButton:getX() - pad / 2 - self.insertButton:getWidth());
	self.insertButton:setY(statusY);
	self.statusY = statusY + (sizes.button - sizes.small) / 2;

	local textTop = y;
	local textHeight = math.max(self.lineHeight * 3, statusY - pad / 2 - textTop);
	local gutterWidth = measure(self.codeFont, "0000") + 6;

	self.gutter:setX(right);
	self.gutter:setY(textTop);
	self.gutter:setWidth(gutterWidth);
	self.gutter:setHeight(textHeight);
	self.entry:setX(right + gutterWidth);
	self.entry:setY(textTop);
	self.entry:setWidth(rightWidth - gutterWidth);
	self.entry:setHeight(textHeight);
	fitScrollBar(self.entry);

	self.renameEntry:setX(right);
	self.renameEntry:setY(top);
	self.renameEntry:setWidth(math.floor(rightWidth * 0.6));

	self:makeOps();
end

-- the texts to draw at their places (after a layout or a change of the texts)
function W:makeOps()
	local sizes = self.sizes;
	local pad = sizes.pad;
	local ops = {};
	local grey = AutoPilotMoon.Panel.colors.grey;

	local function op(text, x, y, color, font, alignRight)
		if text
		then
			local c = colorOf(color);

			table.insert(ops, { text = text, x = x, y = y, r = c.r, g = c.g, b = c.b, font = font or UIFont.Small, right = alignRight });
		end
	end

	op(getText("IGUI_AutoPilot_E_Yours"), pad, self.yoursLabelY, UI.titleColor);
	op(getText("IGUI_AutoPilot_E_Examples"), pad, self.examplesLabelY, UI.titleColor);

	local rightEdge = self.rightX + self.rightWidth;
	local statusX = rightEdge;
	local statusY = self.nameY + (sizes.medium - sizes.small) / 2;

	if self.problemsText
	then
		op(self.problemsText, statusX, statusY, self.problemsColor, UIFont.Small, true);
		statusX = statusX - measure(UIFont.Small, self.problemsText) - pad;
	end

	-- the save state only when the name keeps room for a few letters beside it ("Problemi: 2, avvisi: 1" is long: on
	-- a small screen with a big font the state went over the name)
	if self.saveStateText
	then
		local width = measure(UIFont.Small, self.saveStateText .. " -") + pad;

		if statusX - width - self.rightX >= measure(UIFont.Medium, "MMMM...")
		then
			op(self.saveStateText .. " -", statusX, statusY, grey, UIFont.Small, true);
			statusX = statusX - width;
		end
	end

	-- the name left of the state, shortened with "..." when the window is narrow (a small screen, a big font: the name
	-- was drawn over "Salvata - Nessun problema")
	if not self.renaming
	then
		op(fitText(UIFont.Medium, self.nameText or "", statusX - self.rightX), self.rightX, self.nameY, UI.titleColor, UIFont.Medium);
	end

	if self.renameNote
	then
		op(self.renameNote, self.renameEntry:getX() + self.renameEntry:getWidth() + pad / 2, statusY, "bad");
	end

	-- the banner left of Duplica, the cursor's line left of Inserisci (they were drawn under the buttons)
	if self.bannerText
	then
		local room = self.rightWidth;

		if self.duplicateButton:getIsVisible()
		then
			room = self.duplicateButton:getX() - pad - self.rightX;
		end

		op(fitText(UIFont.Small, self.bannerText, room), self.rightX, self.bannerY + 2, self.bannerColor or UI.inputColor);
	end

	if self.cursorText
	then
		op(fitText(UIFont.Small, self.cursorText, self.insertButton:getX() - pad - self.rightX), self.rightX, self.statusY, UI.textColor);
	end
	op(self.limitsText, pad, self.limitsY, grey);
	self.ops = ops;
end

-- ============================================================================================================
-- Lists and selection
-- ============================================================================================================

local function fillList(list, entries)
	local selectedName = list.items[list.selected] and list.items[list.selected].item.name or nil;

	list:clear();

	for i, entry in ipairs(entries)
	do
		entry.textWidth = measure(UIFont.Small, entry.text);

		local item = list:addItem(entry.text, entry);

		if entry.tooltip
		then
			item.tooltip = entry.tooltip;
		end
	end

	list.selected = -1;

	if selectedName
	then
		for i, item in ipairs(list.items)
		do
			if item.item.name == selectedName
			then
				list.selected = i;
			end
		end
	end
end

-- The problems longer than their list go on more lines (a small screen, a big font: "Riga 5: non capisco ...
-- Comandi: ..." was cut by the list's edge). Worked out when the problems or the list's width change, never in render;
-- the room of the scroll bar is always kept, so the lines do not depend on whether it shows.
function W:wrapProblems()
	local list = self.problemList;

	if list == nil or list.items == nil
	then
		return;
	end

	local width = list:getWidth() - 16 - (list.vscroll and list.vscroll:getWidth() or 0);
	local font = list.font or UIFont.Small;
	local fontHgt = getTextManager():getFontHeight(font);

	for i, item in ipairs(list.items)
	do
		local entry = item.item;

		entry.lines = nil;
		item.height = list.itemheight;

		if entry.text and width > 0 and measure(font, entry.text) > width
		then
			local lines = {};
			local current = nil;

			for word in string.gmatch(entry.text, "%S+")
			do
				local candidate = current and (current .. " " .. word) or word;

				if current and measure(font, candidate) > width
				then
					table.insert(lines, current);
					current = word;
				else
					current = candidate;
				end
			end

			table.insert(lines, current);
			entry.lines = lines;
			item.height = list.itemheight + (#lines - 1) * fontHgt;
		end
	end
end

-- the errors of a stored macro, from its last check (the same text), or checked now when the names are ready
function W:errorsOf(macro)
	if macro.checkedText ~= macro.text and Macro().Names:isReady()
	then
		local result = Macro().Run:check(self.player, macro.text);

		macro.checkedText = macro.text;
		macro.errors = result.errors;
	end

	if macro.checkedText == macro.text
	then
		return macro.errors;
	end

	return nil;
end

function W:fillLists()
	local running = Macro().Run:getRunningName();
	local entries = {};

	for i, macro in ipairs(Macro().Store:list())
	do
		table.insert(entries, Model:listEntry(macro, running, self:errorsOf(macro)));
	end

	fillList(self.myList, entries);

	local examples = {};

	self.examples = Macro().Store:getExamples();

	for i, example in ipairs(self.examples)
	do
		table.insert(examples, Model:listEntry(example, running, nil));
	end

	fillList(self.exampleList, examples);
	self:relayout();
end

function W:currentMacro()
	return self.selected and self.selected.macro or nil;
end

function W:isExample()
	return self.selected ~= nil and self.selected.example == true;
end

-- shows a macro (mine or an example): saves the one before, loads the text, checks it
function W:show(macro, example)
	if self.selected and self.selected.macro == macro
	then
		return;
	end

	self:saveNow();
	self:endRename(false);

	self.selected = { macro = macro, example = example == true };
	self.newVersionDone = false;
	self.savingUntil = nil;
	self.failure = nil;
	self.now = nil;
	self.entry:setText(macro.text or "");
	self.lastText = macro.text or "";
	self.unsaved = false;
	self.dirty = false;
	self:check();
	self:refresh();

	self.myList.selected = -1;
	self.exampleList.selected = -1;

	local list = example and self.exampleList or self.myList;

	for i, item in ipairs(list.items)
	do
		if item.item.macro == macro or item.item.name == macro.name
		then
			list.selected = i;
		end
	end
end

function W:onSelectMine(entry)
	self:show(entry.macro, false);
end

function W:onSelectExample(entry)
	self:show(entry.macro, true);
end

function W:selectByName(name)
	local macro = Macro().Store:get(name);

	if macro
	then
		self:show(macro, false);

		return;
	end

	for i, example in ipairs(self.examples or {})
	do
		if example.name == name
		then
			self:show(example, true);

			return;
		end
	end
end

function W:selectFirst()
	local list = Macro().Store:list();

	if list[1]
	then
		self:show(list[1], false);
	elseif self.examples and self.examples[1]
	then
		self:show(self.examples[1], true);
	end
end

-- ============================================================================================================
-- Text, check, save
-- ============================================================================================================

function W:onTextChange()
	self.changedAt = getTimestampMs();
	self.dirty = true;

	if self.selected and not self.selected.example
	then
		self.unsaved = true;
	end

	-- a failure of the last run is shown until the text changes (4.7)
	self.failure = nil;
end

-- the box's own text change (a key: a character, Backspace, Delete): the check and the save later, the suggestions now
function W:onBoxTextChange()
	self:onTextChange();

	if self.suggest
	then
		self.suggest:onTyped();
	end
end

function W.onEntryOtherKey(entry, key)
	local window = entry.target;

	if window and window.suggest
	then
		window.suggest:onKey(key);
	end
end

function W.onEntryPressUp(entry)
	local window = entry.target;

	if window and window.suggest
	then
		window.suggest:onArrow(-1);
	end
end

function W.onEntryPressDown(entry)
	local window = entry.target;

	if window and window.suggest
	then
		window.suggest:onArrow(1);
	end
end

-- the cursor at an offset of the whole text (0-based). A multi-line box clamps setCursorPos to the length of the row
-- in cursorLine (UITextBox2 42.22): the row first, the offset set as a one-line box
function W:setCaret(offset)
	local java = self.entry.javaObject;

	java:setCursorLine(java:toDisplayLine(offset));
	java:setMultipleLine(false);
	java:setCursorPos(offset);
	java:setMultipleLine(true);
end

-- the cursor's row in view (after a suggestion written: the box does not scroll by itself)
function W:scrollToCaret(offset)
	local view = self.codeView;
	local lh = self.lineHeight;
	local row = view:rowOfOffset(offset);
	local visible = math.max(1, math.floor((self.entry:getHeight() - 2 * self.textInset) / lh));
	local top = view:topRow(self.entry:getYScroll());

	if row - 1 < top
	then
		self.entry:setYScroll(-(row - 1) * lh);
	elseif row - 1 >= top + visible
	then
		self.entry:setYScroll(-(row - visible) * lh);
	end
end

-- a new text with the cursor at an offset (a suggestion written; restoring: the text as it was before a key the
-- suggestions took back, Enter or Ctrl+Space's space, so nothing changed)
function W:replaceText(text, offset, restoring)
	self.entry:setText(text);
	self.lastText = text;
	self.lineTotal = Model:lineCount(text);
	self:setCaret(offset);

	if not restoring
	then
		self:onTextChange();
	end

	self:syncView();
	self:scrollToCaret(offset);
	self:updateCursorText(true);
	self:makeOps();
end

-- The box's text as it is now. UITextBox2 (42.22) keeps two: internalText, changed at once by a key, and text,
-- copied from it by the box's update and drawn (getText); right after a key getText is the text before it. The status
-- line, the check, the save and the suggestions read this one; the colours draw getText, the text the box draws.
function W:liveText()
	local java = self.entry.javaObject;

	return java:getInternalText() or self.entry:getText() or "";
end

-- the text of the box (read here at the check and at the save)
function W:readText()
	local text = self:liveText();

	self.lastText = text;

	return text;
end

function W:check()
	self.dirty = false;

	local macro = self:currentMacro();

	if macro == nil
	then
		self.result = nil;
		self:refresh();

		return;
	end

	local text = self:readText();

	if not Macro().Names:isReady()
	then
		Macro().Names:ensure();
		self.waitingNames = true;
		self.result = { notReady = true, problems = {}, errors = 0, warnings = 0, more = 0, ops = {}, actionCount = 0 };
		self:refresh();

		return;
	end

	self.waitingNames = false;
	self.result = Macro().Run:check(self.player, text);
	self.lineTotal = Model:lineCount(text);

	if not self.selected.example
	then
		local before = macro.errors;

		macro.checkedText = text;
		macro.errors = self.result.errors;

		-- the list's "(!)" follows the check
		if (before or 0) ~= macro.errors
		then
			self:fillLists();
		end
	end

	local errorLines = {};

	for i, problem in ipairs(self.result.problems)
	do
		if not problem.warn and problem.line
		then
			errorLines[problem.line] = true;
		end
	end

	self.errorLines = errorLines;
	self.codeView:setProblems(text, self.result.problems);
	self.probedAt = nil;
	self:probe();
	self:refresh();
end

-- "Adesso si puo' fare?" (4.5): after a check without errors, every Editor.probeEveryMs while visible
function W:probe()
	local result = self.result;

	if result == nil or result.notReady or result.errors > 0 or self.player == nil or Macro().Run:getRunningName()
	then
		self.now = nil;

		return;
	end

	local line, reason = Macro().Run:probe(self.player, result);

	self.probedAt = getTimestampMs();

	if line == nil
	then
		self.now = nil;
	else
		self.now = { line = line, reason = reason };
	end
end

-- writes the text into the macro and the file (force: now, the file too even within 2 s)
function W:save(force)
	local macro = self:currentMacro();

	if macro == nil or self.selected.example
	then
		return;
	end

	if not self.unsaved
	then
		-- Enter and Ctrl+X change the text without onTextChange (UITextBox2 42.22): a save now (close, another
		-- macro, Avvia, Copia) looks at the text itself
		if not force or self:liveText() == (macro.text or "")
		then
			return;
		end

		self:onTextChange();
	end

	local text = self:readText();
	local first = not self.newVersionDone;

	if Macro().Store:setText(macro, text, first)
	then
		self.newVersionDone = true;
	end

	if Macro().Store:save(force)
	then
		self.unsaved = false;
		self.savingUntil = getTimestampMs() + Editor.savingShownMs;
	end

	-- the list's "(!)" of the text just saved
	self:fillLists();
	self:refresh();
end

function W:saveNow()
	self:save(true);
end

-- ============================================================================================================
-- The texts of the window (after an event, never in render)
-- ============================================================================================================

function W:refresh()
	local macro = self:currentMacro();
	local running = Macro().Run:getRunningName();
	local isRunning = macro ~= nil and running ~= nil and string.lower(running) == string.lower(macro.name);
	local busy = A:isBusy();
	local allowed = A:isAllowedByServer("macro");
	local now = getTimestampMs();

	self.allowed = allowed;
	self.busy = busy;
	self.recording = Macro().Recorder:isRecording();
	self.runningName = running;
	self.nameText = macro and macro.name or "";

	-- the save state
	if macro == nil or self:isExample()
	then
		self.saveStateText = nil;
	elseif self.savingUntil and now < self.savingUntil
	then
		self.saveStateText = Model:saveText("saving");
	elseif self.unsaved
	then
		self.saveStateText = Model:saveText("unsaved");
	else
		self.saveStateText = Model:saveText("saved");
	end

	local problemsText, problemsColor = Model:problemsText(self.result);

	self.problemsText = macro and problemsText or nil;
	self.problemsColor = problemsColor;

	-- the banner: an example, the macro running, another job running, the server's switch off
	self.bannerText = nil;
	self.bannerIsExample = false;
	self.bannerColor = nil;

	if self:isExample()
	then
		self.bannerText = getText("IGUI_AutoPilot_E_ExampleBanner");
		self.bannerIsExample = true;
	elseif isRunning
	then
		self.bannerText = getText("IGUI_AutoPilot_E_RunningBanner");
	elseif busy
	then
		local state = AutoPilotMoon.Progress.state;

		self.bannerText = getText("IGUI_AutoPilot_E_RunOtherJob", state.titleText or (state.titleKey and getText(state.titleKey)) or "");
	elseif not allowed
	then
		self.bannerText = getText("IGUI_AutoPilot_E_Off");
		self.bannerColor = "bad";
	end

	-- read-only: an example, the macro running, another job running (4.3, 4.7)
	local editable = macro ~= nil and not self:isExample() and not busy;

	if self.editable ~= editable
	then
		self.editable = editable;
		self.entry:setEditable(editable);
	end

	self.insertButton:setEnable(editable);

	-- the gutter's marks
	self.runningLine = isRunning and Macro().Run:getRunningLine() or nil;

	-- the problems
	local entries = Model:problemEntries(macro and self.result or nil, self.failure, self.now);

	self.problemList:clear();

	for i, entry in ipairs(entries)
	do
		entry.textWidth = 0;
		entry.suffix = nil;

		if entry.color
		then
			entry.textColor = colorOf(entry.color);
		end

		local item = self.problemList:addItem(entry.text, entry);

		item.textColor = entry.textColor;
	end

	self:wrapProblems();

	-- Avvia / Ferma, Registra
	if isRunning
	then
		self.runButton:setTitle(getText("IGUI_AutoPilot_E_Stop"));
		Editor.setButton(self.runButton, "cancel", true, nil);
	else
		local refusal = nil;

		if macro == nil
		then
			refusal = getText("IGUI_AutoPilot_E_RunEmpty");
		elseif self.result == nil or self.result.notReady
		then
			refusal = getText("IGUI_AutoPilot_E_Preparing");
		else
			refusal = Macro().Run:getStartRefusal(self.player, self.result);
		end

		self.runButton:setTitle(getText("IGUI_AutoPilot_E_Run"));
		Editor.setButton(self.runButton, "accept", refusal == nil, refusal);
	end

	local recordRefusal = Macro().Recorder:getStartRefusal(self.player);

	Editor.setButton(self.recordButton, nil, recordRefusal == nil, recordRefusal);

	local maxActions, maxLoops, perMinute = Macro().Run.limits();

	self.limitsText = getText("IGUI_AutoPilot_E_ServerLimits", maxActions, maxLoops, perMinute);

	self:updateCursorText(true);
	self:relayout();
end

-- the cursor's line and column from its offset in the whole text (UITextBox2 42.22), against the text read last
-- (never read here: at most 600 ms old while typing, then the check reads it and calls this again)
function W:updateCursorText(force)
	local offset = self.entry.javaObject:getCursorPos();
	-- the text as it is now (the same string object while nothing changes: the comparison costs nothing)
	local text = self:liveText();

	if not force and offset == self.cursorOffset and text == self.cursorSource
	then
		return false;
	end

	self.cursorOffset = offset;

	if text ~= self.cursorSource or self.cursorLines == nil
	then
		self.cursorSource = text;
		self.cursorLines = Model:lineCount(text);
	end

	local line, column = Model:cursorFromOffset(text, offset);

	if force or line ~= self.cursorLine or column ~= self.cursorColumn or self.cursorTotal ~= self.cursorLines
	then
		self.cursorLine = line;
		self.cursorColumn = column;
		self.cursorTotal = self.cursorLines;
		self.cursorText = Model:cursorText(line, column, self.cursorLines);

		return true;
	end

	return false;
end

-- the cursor on a line (a problem clicked, the line where the macro stopped), the line in view
function W:goToLine(line)
	if line == nil
	then
		return;
	end

	local java = self.entry.javaObject;
	local visible = math.max(1, math.floor(self.entry:getHeight() / self.lineHeight));
	local top = math.max(0, line - 1 - math.floor(visible / 2));

	if self.editable
	then
		self.entry:focus();
	end

	-- the cursor at the start of the line: an offset in the whole text. A multi-line box clamps setCursorPos to the
	-- length of the line it has now and keeps the number as an offset (UITextBox2 42.22): set as a one-line box
	local text = self.dirty and self:readText() or (self.lastText or "");

	java:setCursorLine(line - 1);
	java:setMultipleLine(false);
	java:setCursorPos(Model:offsetOfLine(text, line));
	java:setMultipleLine(true);

	-- the line's first row in the middle (the long lines are wrapped: rows and lines differ)
	self:syncView();
	top = math.max(0, self.codeView:rowOfLine(line) - 1 - math.floor(visible / 2));
	self.entry:setYScroll(-top * self.lineHeight);
	self:updateCursorText(true);
	self:makeOps();
end

-- ============================================================================================================
-- Every frame while visible
-- ============================================================================================================

function W:update()
	ISCollapsableWindowJoypad.update(self);

	-- the suggestions: Enter, the cursor moved, Ctrl+Space (closed when the window is hidden or collapsed)
	if self.suggest
	then
		self.suggest:poll();
	end

	if not self:getIsVisible() or self.isCollapsed
	then
		return;
	end

	local now = getTimestampMs();
	local Run = Macro().Run;
	local changed = false;

	if (AutoPilotMoon.Options:get("macroColors") ~= false) ~= self.colorsWanted
	then
		self:applyColors();
	end

	-- a run that started or ended (its failure shown and its line under the cursor, 4.7), the server's switch
	local running = Run:getRunningName();

	if running ~= self.runningName
	then
		local macro = self:currentMacro();
		local last = Run.last;

		if running == nil and macro and last and last.name == macro.name and last.reason == "because" and last.line
		then
			self.failure = { line = last.line, text = last.text };
			self:goToLine(last.line);
		end

		self:fillLists();
		changed = true;
	end

	if A:isAllowedByServer("macro") ~= self.allowed or A:isBusy() ~= self.busy
		or Macro().Recorder:isRecording() ~= self.recording
	then
		changed = true;
	end

	if Run:getRunningLine() ~= self.runningLine and running
	then
		self.runningLine = Run:getRunningLine();
	end

	if self.waitingNames and Macro().Names:isReady()
	then
		self:check();
		self:fillLists();
	end

	if self.dirty and now - (self.changedAt or 0) >= Editor.checkDelayMs
	then
		self:check();
		changed = false;
	end

	if self.unsaved and now - (self.changedAt or 0) >= Editor.saveDelayMs
	then
		self:save(false);
	end

	-- Enter, Ctrl+X and Ctrl+V change the text without onTextChange (UITextBox2 42.22): the box's text compared every
	-- frame (the same string object while nothing changes: no cost), a change is one like a key's (check 600 ms after,
	-- save 2 s after)
	if self.editable
	then
		local live = self:liveText();

		if live ~= self.seenText
		then
			self.seenText = live;

			if live ~= (self.lastText or "")
			then
				self:onTextChange();
			end
		end
	end

	if self.savingUntil and now >= self.savingUntil
	then
		self.savingUntil = nil;
		changed = true;
	end

	-- "Modifiche non salvate" at the first key, without redoing the rest
	if self.unsaved and not self.savingUntil and self.saveStateText ~= self.unsavedText and not changed
	then
		self.saveStateText = self.unsavedText;
		self:makeOps();
	end

	if self.probedAt and now - self.probedAt >= Editor.probeEveryMs and not self.dirty
	then
		local before = self.now;

		self:probe();

		if (before == nil) ~= (self.now == nil) or (before and self.now and (before.line ~= self.now.line or before.reason ~= self.now.reason))
		then
			changed = true;
		end
	end

	if changed
	then
		self:refresh();
	elseif self:updateCursorText(false)
	then
		self:makeOps();
	end
end

function W:prerender()
	ISCollapsableWindowJoypad.prerender(self);

	-- an Enter the suggestions take back, before the box draws it (the game may read the keys after the update)
	if self.suggest and self.suggest.isOpen
	then
		self.suggest:poll();
	end

	if self.isCollapsed or self.ops == nil
	then
		return;
	end

	for i, entry in ipairs(self.ops)
	do
		if entry.right
		then
			self:drawTextRight(entry.text, entry.x, entry.y, entry.r, entry.g, entry.b, 1, entry.font);
		else
			self:drawText(entry.text, entry.x, entry.y, entry.r, entry.g, entry.b, 1, entry.font);
		end
	end

	local pad = self.sizes.pad;

	if self.nameSeparatorY
	then
		self:drawRect(self.rightX, self.nameSeparatorY, self.rightWidth, 1, 1, 0.4, 0.4, 0.4);
	end

	if self.bottomSeparatorY
	then
		self:drawRect(pad, self.bottomSeparatorY, self.width - 2 * pad, 1, 1, 0.4, 0.4, 0.4);
	end
end

-- ============================================================================================================
-- The colours of the text (MACRO-AUTOPILOT.md 4.11, MacroCodeView.lua)
-- ============================================================================================================

-- on with the option "Colori nel codice" (macroColors, on by default) and a fixed-width font ("lettere tutte larghe
-- uguali"): the box wraps its long lines and draws its text in its background's colour, the view draws it coloured.
-- Off: the box as the game makes it (white text, no wrapping), the view only gives the line numbers their rows
function W:applyColors()
	local font = self.codeFont;
	local view = self.codeView;

	view:setFont(font, self.lineHeight, self.textInset, function(s)
		return getTextManager():MeasureStringX(font, s);
	end);

	self.colorsWanted = AutoPilotMoon.Options:get("macroColors") ~= false;

	local on = self.colorsWanted and not self.colorsFailed and view:isMonospace();

	if on == self.colorsOn
	then
		return;
	end

	self.colorsOn = on;
	self.entry.javaObject:setWrapLines(on);

	if on
	then
		local bg = AutoPilotMoon.Macro.CodeView.background;

		self.entry:setTextRGBA(bg.r, bg.g, bg.b, 1);
		self.entry.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 1 };
	else
		self.entry:setTextRGBA(1, 1, 1, 1);
		self.entry.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 };
	end
end

-- an error of the colours (never expected): off for this session, the plain box back, said once in the console
function W:colorsFailedWith(err)
	self.colorsFailed = true;
	self.codeViewError = tostring(err);
	print("AutoPilot (Moon): macro editor colours turned off: " .. self.codeViewError);
	self:applyColors();
end

-- the view's rows on the box's own text (the string the box draws: the same object while nothing changes, so the
-- comparison costs nothing), its width and the wrapping
function W:syncView()
	local entry = self.entry;

	self.codeView:sync(entry:getText() or "", entry:getWidth(), self.colorsOn == true);
end

function W:drawCodeFront()
	local entry = self.entry;

	self:syncView();
	self.codeView:drawFront(entry, entry:isFocused() and entry.javaObject:getCursorPos() or nil, self.runningLine);
end

-- after the children (the box drew its text, caret and selection): the rows of the line running and of the errors, the
-- coloured text over it
function W:render()
	if self.colorsOn and not self.isCollapsed
	then
		local ok, err = pcall(self.drawCodeFront, self);

		if not ok
		then
			self:colorsFailedWith(err);
		end
	end

	ISCollapsableWindowJoypad.render(self);
end

-- ============================================================================================================
-- Buttons
-- ============================================================================================================

function W:onRun()
	local macro = self:currentMacro();
	local Run = Macro().Run;

	if macro == nil
	then
		return;
	end

	if Run:getRunningName() and string.lower(Run:getRunningName()) == string.lower(macro.name)
	then
		A:stopAll("user");

		return;
	end

	self:saveNow();
	self:check();

	local started, why = Run:start(self.player, macro);

	if not started and why
	then
		self.failure = nil;
		self.runButton.tooltip = why;
	end

	self:fillLists();
	self:refresh();
end

function W:onRecord()
	if Macro().Recorder:start(self.player)
	then
		-- the window steps aside to let the game be seen (3.1)
		self.isCollapsed = true;
		self:setMaxDrawHeight(self:titleBarHeight());
	end

	self:refresh();
end

function W:onNew()
	local Store = Macro().Store;
	local macro, why = Store:add(getText("IGUI_AutoPilot_E_NewName"), Store:linesOf(getText("IGUI_AutoPilot_E_NewTemplate")));

	if macro == nil
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_E_Full", Store.maxMacros), self.player);

		return;
	end

	Store:save(true);
	self:fillLists();
	self:show(macro, false);
	self:beginRename();
end

function W:onDuplicate()
	local macro = self:currentMacro();
	local Store = Macro().Store;

	if macro == nil
	then
		return;
	end

	self:saveNow();

	local copy = Store:duplicate(macro);

	if copy == nil
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_E_Full", Store.maxMacros), self.player);

		return;
	end

	Store:save(true);
	self:fillLists();
	self:show(copy, false);
end

function W:onCheck()
	self:save(true);
	self:check();
end

function W:onProblem(entry)
	if entry and entry.line
	then
		self:goToLine(entry.line);
	end
end

-- ============================================================================================================
-- Renaming in place (4.2, 4.8)
-- ============================================================================================================

function W:beginRename()
	local macro = self:currentMacro();

	if macro == nil or self:isExample() or (Macro().Run:getRunningName() == macro.name)
	then
		return;
	end

	self.renaming = true;
	self.renameNote = nil;
	self.renameEntry:setText(macro.name);
	self.renameEntry:setValid(true);
	self.renameEntry:setVisible(true);
	self.renameEntry:focus();
	self:makeOps();
end

function W:endRename(apply)
	if not self.renaming
	then
		return true;
	end

	local macro = self:currentMacro();

	if apply and macro
	then
		local name = self.renameEntry:getText();

		if not Macro().Store:rename(macro, name)
		then
			self.renameEntry:setValid(false);
			self.renameNote = getText("IGUI_AutoPilot_E_NameBad", Macro().Store.maxNameChars);
			self:makeOps();

			return false;
		end

		Macro().Store:save(true);
	end

	self.renaming = false;
	self.renameNote = nil;
	self.renameEntry:unfocus();
	self.renameEntry:setVisible(false);
	self:fillLists();
	self:refresh();

	return true;
end

function W.onRenameEnter(entry)
	entry.window:endRename(true);
end

function W.onRenameKey(entry, key)
	if key == Keyboard.KEY_ESCAPE
	then
		entry.window:endRename(false);
	end
end

function W:onRenameChange(entry)
	local macro = self:currentMacro();
	local valid = macro ~= nil and Macro().Store:isValidName(entry:getText(), macro.name);

	entry:setValid(valid);
	self.renameNote = (not valid) and getText("IGUI_AutoPilot_E_NameBad", Macro().Store.maxNameChars) or nil;
	self:makeOps();
end

function W:onMouseDown(x, y)
	-- a click on the name renames it in place
	if not self.renaming and self.rightX and x >= self.rightX and x <= self.rightX + self.rightWidth * 0.6
		and y >= self.nameY and y <= self.nameY + self.sizes.medium
	then
		self:beginRename();

		return true;
	end

	return ISCollapsableWindowJoypad.onMouseDown(self, x, y);
end

-- ============================================================================================================
-- The macro's menu (list right click, "...", Y), Inserisci
-- ============================================================================================================

local function contextAt(window, x, y)
	local context = ISContextMenu.get(window.playerNum, x, y);

	if UI:isJoypad(window.playerNum)
	then
		context.origin = window;
		context.mouseOver = 1;
		setJoypadFocus(window.playerNum, context);
	end

	return context;
end

local function grey(option, reason)
	option.notAvailable = true;

	if reason
	then
		option.toolTip = ISWorldObjectContextMenu.addToolTip();
		option.toolTip.description = "<BHC> " .. reason;
	end
end

function W:fillMacroMenu(context, withPaste)
	local macro = self:currentMacro();
	local Run = Macro().Run;

	if macro
	then
		local running = Run:getRunningName();
		local isRunning = running ~= nil and string.lower(running) == string.lower(macro.name);
		local example = self:isExample();

		if isRunning
		then
			context:addOption(getText("IGUI_AutoPilot_E_Stop"), self, W.onRun);
		else
			local option = context:addOption(getText("IGUI_AutoPilot_E_Run"), self, W.onRun);
			local refusal = (self.result == nil or self.result.notReady) and getText("IGUI_AutoPilot_E_Preparing") or Run:getStartRefusal(self.player, self.result);

			if refusal
			then
				grey(option, refusal);
			end
		end

		if not example
		then
			local rename = context:addOption(getText("IGUI_AutoPilot_E_Rename"), self, W.beginRename);

			if isRunning
			then
				grey(rename, getText("IGUI_AutoPilot_E_RunningBanner"));
			end
		end

		context:addOption(getText("IGUI_AutoPilot_E_Duplicate"), self, W.onDuplicate);
		context:addOption(getText("IGUI_AutoPilot_E_CopyText"), self, W.onCopy, false);
		context:addOption(getText("IGUI_AutoPilot_E_CopyIds"), self, W.onCopy, true);

		if not example
		then
			local restore = context:addOption(getText("IGUI_AutoPilot_E_Restore"), self, W.onRestore);

			if macro.previous == nil or isRunning
			then
				grey(restore, nil);
			end

			local delete = context:addOption(getText("IGUI_AutoPilot_E_Delete"), self, W.onDelete);

			if isRunning
			then
				grey(delete, getText("IGUI_AutoPilot_E_RunningBanner"));
			end
		end
	end

	if withPaste
	then
		context:addOption(getText("IGUI_AutoPilot_E_Paste"), self, W.onPaste);
	end
end

function W:onListRightClick(list, entry, x, y)
	self:fillMacroMenu(contextAt(self, list:getAbsoluteX() + x, list:getAbsoluteY() + y), true);
end

function W:onMore(button)
	self:fillMacroMenu(contextAt(self, button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight()), true);
end

function W:onCopy(withIds)
	local macro = self:currentMacro();

	if macro == nil
	then
		return;
	end

	self:saveNow();

	local text = self:readText();

	if withIds
	then
		Macro().Names:buildNow();
		text = Macro().Lang:withIds(text, Macro().Names, {});
	end

	Clipboard.setClipboard(Macro().Store:clipboardText(macro.name, text));
	AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroCopied"), self.player);
end

function W:onPaste()
	local Store = Macro().Store;
	local pasted = Store:parsePaste(Clipboard.getClipboard());
	local first = nil;

	for i, entry in ipairs(pasted)
	do
		local macro = Store:add(entry.name, entry.text);

		if macro == nil
		then
			AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_E_Full", Store.maxMacros), self.player);

			break;
		end

		first = first or macro;
	end

	if first
	then
		Store:save(true);
		self:fillLists();
		self:show(first, false);
	end
end

function W:onRestore()
	local macro = self:currentMacro();

	if macro == nil or self:isExample()
	then
		return;
	end

	self:saveNow();

	if Macro().Store:restore(macro)
	then
		Macro().Store:save(true);
		self.entry:setText(macro.text);
		self.lastText = macro.text;
		self.unsaved = false;
		self:check();
		self:fillLists();
	end
end

function W:onDelete()
	local macro = self:currentMacro();

	if macro == nil or self:isExample()
	then
		return;
	end

	local dialog = ISModalDialog:new(0, 0, 320, 120, getText("IGUI_AutoPilot_E_DeleteConfirm", macro.name), true, self, W.onDeleteAnswer, self.playerNum, macro);

	dialog:initialise();

	-- "Elimina" in the cancel colour, "Annulla" (4.8)
	if dialog.yes
	then
		dialog.yes:setTitle(getText("IGUI_AutoPilot_E_Delete"));
		dialog.yes:enableCancelColor();
	end

	if dialog.no
	then
		dialog.no:setTitle(getText("IGUI_AutoPilot_R_Cancel"));
		dialog.no:enableAcceptColor();
	end

	dialog:addToUIManager();

	if UI:isJoypad(self.playerNum)
	then
		setJoypadFocus(self.playerNum, dialog);
	end
end

function W:onDeleteAnswer(button, macro)
	if button.internal ~= "YES" or macro == nil
	then
		return;
	end

	Macro().Store:delete(macro);
	Macro().Store:save(true);
	self.selected = nil;
	self:fillLists();
	self:selectFirst();
	self:refresh();
end

-- Inserisci (4.6, 11.7): recipe, item, repeat, if, body, work, when, condition, wait, stop if; every form written in the
-- language of the macros with its indentation (the game's text box does not indent by itself)
function W:onInsert(button)
	if not self.editable
	then
		return;
	end

	local context = contextAt(self, button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight());
	local Lang = Macro().Lang;
	local skill = getText("IGUI_AutoPilot_E_TplSkill");
	local item = getText("IGUI_AutoPilot_E_TplItem");

	local function sub(titleKey)
		local option = context:addOption(getText(titleKey), nil, nil);
		local menu = context:getNew(context);

		context:addSubMenu(option, menu);

		return menu;
	end

	context:addOption(getText("IGUI_AutoPilot_E_InsertRecipe"), self, W.onInsertPicker, "recipe");
	context:addOption(getText("IGUI_AutoPilot_E_InsertItem"), self, W.onInsertPicker, "item");

	local repeatMenu = sub("IGUI_AutoPilot_E_InsertRepeat");

	for i, header in ipairs({ "while possible:", "repeat 10:", "while skill(\"" .. skill .. "\") < 4:", "while True:" })
	do
		repeatMenu:addOption(header, self, W.onInsertBlock, header);
	end

	local ifMenu = sub("IGUI_AutoPilot_E_InsertIf");

	for i, header in ipairs({ "if has(\"" .. item .. "\"):", "if not has(\"" .. item .. "\", at_least=10):", "if hungry >= 2:", "if endurance < 30:" })
	do
		ifMenu:addOption(header, self, W.onInsertBlock, header);
	end

	local bodyMenu = sub("IGUI_AutoPilot_E_InsertBody");

	for i, line in ipairs({ "exercise(\"pushups\", minutes=10)", "exercise(\"squats\", minutes=10)", "rest()", "rest(seat=\"ground\")",
		"eat(open_cans=True)", "drink()", "smoke()", "read(\"Base.BookMaintenance1\")" })
	do
		bodyMenu:addOption(line, self, W.onInsertLine, line);
	end

	-- the work on the tools (wave 0, 13/11/2026): repair, sharpen, read, the loop on the damaged ones; with the game's
	-- ids, valid in every language
	local workMenu = sub("IGUI_AutoPilot_E_InsertWork");

	workMenu:addOption("while has(\"Base.BaseballBat\", damaged=True):", self, W.onInsertBlock, "while has(\"Base.BaseballBat\", damaged=True):");

	for i, line in ipairs({ "repair(\"Base.BaseballBat\", using=\"Base.DuctTape\")", "repair(\"Base.BaseballBat\")",
		"sharpen(\"Base.KitchenKnife\")", "read(\"Base.BookMaintenance1\")", "stop_if(condition(\"Base.KitchenKnife\") < 15)",
		"stop_if(dark)" })
	do
		workMenu:addOption(line, self, W.onInsertLine, line);
	end

	local whenMenu = sub("IGUI_AutoPilot_E_InsertWhen");

	for i, pair in ipairs({ { "when hungry >= 2:", "eat(open_cans=True)" }, { "when thirsty >= 2:", "drink()" },
		{ "when stressed >= 2:", "smoke()" }, { "when endurance < 30:", "rest()" }, { "when panic >= 3:", "stop()" } })
	do
		whenMenu:addOption(pair[1] .. " " .. pair[2], self, W.onInsertHandler, pair);
	end

	-- the conditions the moodles give, grouped (11.2): "hungry >= 2" at the cursor
	local condMenu = sub("IGUI_AutoPilot_E_InsertCondition");

	for g, group in ipairs(Lang.moodleGroups)
	do
		local option = condMenu:addOption(getText("IGUI_AutoPilot_E_CondGroup_" .. group), nil, nil);
		local groupMenu = condMenu:getNew(condMenu);

		condMenu:addSubMenu(option, groupMenu);

		for k, entry in ipairs(Lang.moodleList)
		do
			if entry.group == group
			then
				groupMenu:addOption(entry.name .. " - " .. getText("IGUI_AutoPilot_E_Moodle_" .. entry.name), self, W.onInsertText, entry.name .. " >= 2");
			end
		end

		for name, percentGroup in pairs(Lang.percents)
		do
			if percentGroup == group
			then
				groupMenu:addOption(name .. " - " .. getText("IGUI_AutoPilot_E_Moodle_" .. name), self, W.onInsertText, name .. " < 30");
			end
		end
	end

	-- the conditions of the work (wave 0): the words (dark, hour) and the calls xp_gained, condition, has damaged, known
	local workOption = condMenu:addOption(getText("IGUI_AutoPilot_E_CondGroup_work"), nil, nil);
	local workGroup = condMenu:getNew(condMenu);

	condMenu:addSubMenu(workOption, workGroup);

	for i, word in ipairs(Lang.condWordList)
	do
		local text = word.value == "number" and (word.name .. " >= 20") or word.name;

		workGroup:addOption(word.name .. " - " .. getText("IGUI_AutoPilot_E_Cond_" .. word.name), self, W.onInsertText, text);
	end

	for i, text in ipairs({ "xp_gained(\"" .. skill .. "\") >= 100", "condition(\"Base.KitchenKnife\") < 15",
		"has(\"Base.BaseballBat\", damaged=True)", "known(\"CarvePlank\")" })
	do
		workGroup:addOption(text, self, W.onInsertText, text);
	end

	context:addOption(getText("IGUI_AutoPilot_E_InsertWait"), self, W.onInsertLine, "wait(5)");
	context:addOption(getText("IGUI_AutoPilot_E_InsertStopIf"), self, W.onInsertLine, "stop_if(has(\"" .. item .. "\", at_least=10))");
end

-- a new text in the box (an insertion): changed, the cursor on its line
function W:setTextAndLine(text, line)
	self.entry:setText(text);
	self.lastText = text;
	self:onTextChange();
	self.lineTotal = Model:lineCount(text);
	self:goToLine(line);
end

function W:onInsertLine(command)
	local current = self:readText();

	self:updateCursorText(true);

	local text, line = Model:insertLine(current, self.cursorLine, command);

	self:setTextAndLine(text, line);
end

function W:onInsertBlock(header)
	local current = self:readText();

	self:updateCursorText(true);

	local text, line = Model:wrapBlock(current, self.cursorLine, header);

	self:setTextAndLine(text, line);
end

function W:onInsertHandler(pair)
	local text, line = Model:insertHandler(self:readText(), pair[1], pair[2]);

	self:setTextAndLine(text, line);
end

-- a piece at the cursor (a condition)
function W:onInsertText(piece)
	local current = self:readText();

	self:updateCursorText(true);

	local text, line = Model:insertAt(current, self.cursorLine, self.cursorColumn, piece);

	self:setTextAndLine(text, line);
end

function W:onInsertPicker(kind)
	if Macro().Picker
	then
		Macro().Picker:open(self, kind);
	end
end

-- what the picker chose: a recipe ("crea "Nome"" on the cursor's line) or an item ("Nome" at the cursor)
function W:insertChosen(kind, text)
	if not self.editable or text == nil
	then
		return;
	end

	local current = self:readText();

	self:updateCursorText(true);

	if kind == "recipe"
	then
		self:onInsertLine("craft(\"" .. text .. "\")");
	else
		local newText, line = Model:insertAt(current, self.cursorLine, self.cursorColumn, "\"" .. text .. "\"");

		self:setTextAndLine(newText, line);
	end
end

-- ============================================================================================================
-- Close, layout file, controller
-- ============================================================================================================

function W:close()
	if self.suggest
	then
		self.suggest:close();
	end

	self:endRename(false);
	self:saveNow();
	ISCollapsableWindowJoypad.close(self);

	if Macro().Picker
	then
		Macro().Picker:closeFor(self);
	end

	local joypadData = JoypadState.players[self.playerNum + 1];

	if joypadData and joypadData.focus == self
	then
		setJoypadFocus(self.playerNum, nil);
	end
end

function W:RestoreLayout(name, layout)
	local x = tonumber(layout.x);
	local y = tonumber(layout.y);
	local width = tonumber(layout.width);
	local height = tonumber(layout.height);

	if x and y
	then
		self:setX(x);
		self:setY(y);
	end

	if width and height
	then
		self:setWidth(math.max(self.minimumWidth or 0, width));
		self:setHeight(math.max(self.minimumHeight or 0, height));
	end

	self:relayout();
	AutoPilotMoon.Panel:keepOnScreen(self);
end

function W:SaveLayout(name, layout)
	layout.x = self:getX();
	layout.y = self:getY();
	layout.width = self:getWidth();
	layout.height = self:getHeight();
end

-- the macros of both lists in order, for up and down
function W:allEntries()
	local list = {};

	for i, item in ipairs(self.myList.items)
	do
		table.insert(list, { list = self.myList, index = i, item = item.item, example = false });
	end

	for i, item in ipairs(self.exampleList.items)
	do
		table.insert(list, { list = self.exampleList, index = i, item = item.item, example = true });
	end

	return list;
end

function W:moveSelection(delta)
	local all = self:allEntries();
	local current = 0;

	for i, entry in ipairs(all)
	do
		if self.selected and entry.item.macro == self.selected.macro
		then
			current = i;
		end
	end

	local target = all[math.max(1, math.min(#all, current + delta))];

	if target
	then
		self:show(target.item.macro, target.example);
	end
end

function W:onJoypadDown(button, joypadData)
	if button == Joypad.AButton
	then
		if self.runButton.enable
		then
			self:onRun();
		end
	elseif button == Joypad.BButton
	then
		self:close();
	elseif button == Joypad.XButton
	then
		if self.recordButton.enable
		then
			self:onRecord();
		end
	elseif button == Joypad.YButton
	then
		self:fillMacroMenu(contextAt(self, self:getAbsoluteX() + self.sizes.pad, self:getAbsoluteY() + self.myList:getY()), true);
	end
end

function W:onJoypadDirUp(joypadData)
	self:moveSelection(-1);
end

function W:onJoypadDirDown(joypadData)
	self:moveSelection(1);
end

function W:onGainJoypadFocus(joypadData)
	ISCollapsableWindowJoypad.onGainJoypadFocus(self, joypadData);
	self.drawJoypadFocus = true;
end

function W:onLoseJoypadFocus(joypadData)
	ISCollapsableWindowJoypad.onLoseJoypadFocus(self, joypadData);
	self.drawJoypadFocus = false;
end

-- the editor's key: only while the master switch is on
AutoPilotMoon.Switch:bind("OnKeyPressed", Editor.onKeyPressed);
