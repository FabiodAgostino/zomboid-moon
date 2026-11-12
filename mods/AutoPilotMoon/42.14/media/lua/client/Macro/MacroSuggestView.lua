-- AutoPilot (Moon): automations for the Moon server.

-- The suggestions' popup of the macro editor (MACRO-AUTOPILOT.md 4.12): a small list under the cursor while typing,
-- the entries of MacroSuggest.lua, each with its detail beside it (the moodle's Italian name, the recipe's id, the
-- usage) and the help of the chosen one under the list. Option "Macro: suggerimenti mentre scrivi" (macroSuggest,
-- on by default).
--
-- How the keys reach it (read in the 42.22 jar with javap -c: zombie.core.Core.updateKeyboardAux, zombie.ui.UITextBox2,
-- zombie.input.GameKeyboard). While the box has the keyboard, Core gives it every key and the game's Lua key events
-- (OnKeyPressed...) do not fire at all; the Lua table of the box hears only:
--   * Tab and Esc: onOtherKey(key), and the box does nothing else with them (Esc is then eaten). Tab accepts, Esc
--     closes the list; with the list closed nothing changes;
--   * Up and Down: the box moves the cursor a row, THEN calls onPressUp / onPressDown: with the list open the cursor
--     is put back where it was and the choice moves; closed, nothing changes;
--   * Enter: onKeyEnter writes "\n" at the cursor without telling Lua (no onTextChange, no onCommandEntered on a box
--     on more lines). With the list open, the next look (the window's update, and its prerender, before the box draws)
--     sees exactly the old text with "\n" at the old cursor: the old text and cursor go back and the choice is
--     written. Closed: the new line stays, as always;
--   * a character: putCharacter, then onTextChange (also Backspace and Delete): the list opens or follows here;
--   * Left, Right, Home, End, a click: the cursor moves without telling Lua: seen at the next look;
--   * Ctrl+Space: no branch of its own in Core; the box writes the space if the system gives the character (then it is
--     taken back here, Ctrl being down: org.lwjglx.input.Keyboard.isKeyDown reads the key itself, GameKeyboard answers
--     false while typing); if no character comes, the next look sees Ctrl and Space down and opens the list.
-- A click on an entry chooses it (the box keeps the keyboard: only a click on another text box takes it); the wheel
-- scrolls the list. The popup never has the controller's focus and never opens without typing: with a controller the
-- editor is as before (writing needs a keyboard, 4.9).
-- Cost: the entries only when the text or the cursor change; each look compares the box's string (the same object
-- while nothing changes) and the cursor; the sizes and the cut texts are made when the entries change, render only
-- draws them.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.SuggestView = AutoPilotMoon.Macro.SuggestView or {};

local V = AutoPilotMoon.Macro.SuggestView;

V.maxRows = 8;

local function rgb(r, g, b)
	return { r = r / 255, g = g / 255, b = b / 255 };
end

-- Visual Studio Code's suggestions widget, dark theme
V.colors = {
	background = rgb(37, 37, 38),   -- #252526
	border = rgb(69, 69, 69),       -- #454545
	selected = rgb(4, 57, 94),      -- #04395E
	hover = rgb(42, 45, 46),        -- #2A2D2E
	detail = rgb(157, 157, 157),    -- #9D9D9D
	help = rgb(204, 204, 204),      -- #CCCCCC
	scroll = rgb(121, 121, 121),    -- #797979
};

local KEY_TAB = 15;
local KEY_ESCAPE = 1;
local KEY_SPACE = 57;
local KEY_LCONTROL = 29;
local KEY_RCONTROL = 157;

local function Suggest()
	return AutoPilotMoon.Macro.Suggest;
end

local function keyDown(code)
	local keyboard = rawget(_G, "Keyboard");

	return keyboard ~= nil and keyboard.isKeyDown ~= nil and keyboard.isKeyDown(code) == true;
end

-- Ctrl held (the keyboard itself: GameKeyboard answers false while a text box has the keyboard)
function AutoPilotMoon.Macro.SuggestView.ctrlDown()
	return keyDown(KEY_LCONTROL) or keyDown(KEY_RCONTROL);
end

function AutoPilotMoon.Macro.SuggestView.ctrlSpaceDown()
	return keyDown(KEY_SPACE) and V.ctrlDown();
end

-- the box wrote "\n" at the old cursor and nothing else (UITextBox2.onKeyEnter on more lines)
function AutoPilotMoon.Macro.SuggestView.isEnter(oldText, oldCaret, text, caret)
	if oldText == nil or oldCaret == nil or caret ~= oldCaret + 1 or string.len(text) ~= string.len(oldText) + 1
	then
		return false;
	end

	return string.sub(text, caret, caret) == "\n" and string.sub(text, 1, oldCaret) == string.sub(oldText, 1, oldCaret)
		and string.sub(text, caret + 1) == string.sub(oldText, oldCaret + 1);
end

local function measure(font, s)
	return getTextManager():MeasureStringX(font, s or "");
end

-- the text, or its start with "..." when wider than width
local function fit(font, s, width)
	if s == nil or measure(font, s) <= width
	then
		return s;
	end

	local n = string.len(s);

	while n > 1 and measure(font, string.sub(s, 1, n) .. "...") > width
	do
		n = n - 1;
	end

	return string.sub(s, 1, n) .. "...";
end

local function helpOf(entry)
	if entry == nil
	then
		return nil;
	end

	if entry.helpText
	then
		return entry.helpText;
	end

	if entry.helpKey == nil
	then
		return nil;
	end

	return Suggest().text(entry.helpKey, entry.helpArg);
end

-- ============================================================================================================
-- The controller (one per editor window)
-- ============================================================================================================

local C = {};
local CMeta = { __index = C };

V.ControllerMethods = C;

function AutoPilotMoon.Macro.SuggestView:attach(window)
	local o = { window = window, entries = {}, selected = 1, top = 1, isOpen = false };

	setmetatable(o, CMeta);

	return o;
end

-- typing in the box with the keyboard, the option on
function C:enabled()
	local w = self.window;
	local entry = w.entry;

	return AutoPilotMoon.Options:get("macroSuggest") ~= false and w:getIsVisible() and not w.isCollapsed
		and w.editable == true and entry ~= nil and entry:isFocused() == true;
end

-- the box's text as it is now: UITextBox2.getText gives the text of its last update (putCharacter changes
-- internalText, update copies it), so in onTextChange only getInternalText has the key just typed
function C:read()
	local java = self.window.entry.javaObject;

	return java:getInternalText() or "", java:getCursorPos();
end

-- the box's text changed by a key (putCharacter, Backspace, Delete: UITextBox2.onTextChange)
function C:onTyped()
	local text, caret = self:read();
	local oldText, oldCaret = self.text, self.caret;

	self.text, self.caret = text, caret;

	if not self:enabled()
	then
		self:close();

		return;
	end

	local typed = nil;

	if oldText and oldCaret and caret == oldCaret + 1 and string.len(text) == string.len(oldText) + 1
	then
		typed = string.sub(text, caret, caret);
	end

	-- Ctrl+Space: the box wrote the space, it goes back and the list opens
	if typed == " " and V.ctrlDown()
	then
		self.ctrlLatch = true;
		self.window:replaceText(oldText, oldCaret, true);
		self.text, self.caret = oldText, oldCaret;
		self:open(true, nil);

		return;
	end

	if self.isOpen
	then
		self:refresh(true);
	elseif typed
	then
		self:open(false, typed);
	end
end

-- every frame (the window's update and prerender): Enter, the cursor moved, Ctrl+Space without a character, the
-- place of the list
function C:poll()
	if not self:enabled()
	then
		if self.isOpen
		then
			self:close();
		end

		self.ctrlLatch = false;
		self.text = nil;

		return;
	end

	local text, caret = self:read();

	if not self.isOpen
	then
		local down = V.ctrlSpaceDown();

		self.text, self.caret = text, caret;

		if down and not self.ctrlLatch
		then
			self.ctrlLatch = true;
			self:open(true, nil);
		elseif not down
		then
			self.ctrlLatch = false;
		end

		return;
	end

	if text ~= self.text
	then
		if V.isEnter(self.text, self.caret, text, caret)
		then
			local old, at = self.text, self.caret;

			self.window:replaceText(old, at, true);
			self.text, self.caret = old, at;
			self:accept(self.selected);
		else
			-- a change that is not typing (cut, paste, another macro shown)
			self:close();
			self.text, self.caret = text, caret;
		end

		return;
	end

	if caret ~= self.caret
	then
		self.caret = caret;
		self:refresh(false);

		return;
	end

	self:place(false);
end

-- the list for the cursor: force (Ctrl+Space, after a choice that goes on) opens it even before a letter; typed: the
-- character just written (a letter opens it when a word is being typed; a quote, "(", ",", "=" or a space after a
-- condition's word open it on what comes next)
function C:open(force, typed)
	local S = Suggest();
	local ctx = S:contextAt(self.text, self.caret);

	if ctx == nil
	then
		self:close();

		return;
	end

	if not force and typed
	then
		local isName = AutoPilotMoon.Macro.Lang.isNameChar(typed);

		if isName and ctx.query == ""
		then
			return;
		end

		if not isName and typed ~= "\"" and typed ~= "'" and typed ~= "(" and typed ~= "," and typed ~= "=" and typed ~= " "
			and not ctx.quoted
		then
			return;
		end

		if typed == " " and ctx.kind ~= "condition" and ctx.kind ~= "args"
		then
			return;
		end
	end

	local entries = S:entries(ctx);

	if #entries == 0
	then
		self:close();

		return;
	end

	self.ctx = ctx;
	self.entries = entries;
	self.selected = 1;
	self.top = 1;
	self.hover = nil;
	self.isOpen = true;
	self.wantVisible = true;
	self:layout();
	self:place(true);
end

-- the list again after typing (sameWord false: the cursor moved; it follows only inside the same word)
function C:refresh(typing)
	local S = Suggest();
	local old = self.ctx;
	local ctx = S:contextAt(self.text, self.caret);

	-- closed: another line; the cursor moved out of the word; the word typed at the start of a line deleted
	if ctx == nil or old == nil or ctx.lineStart ~= old.lineStart or (not typing and ctx.from ~= old.from)
		or (ctx.kind == "statement" and ctx.query == "" and old.query ~= "")
	then
		self:close();

		return;
	end

	local entries = S:entries(ctx);

	if #entries == 0
	then
		self:close();

		return;
	end

	-- typing: the best match first; the cursor moved in the word: the same entry stays chosen when it is still there
	local chosen = not typing and self.entries[self.selected] or nil;
	local selected = 1;

	for i, entry in ipairs(entries)
	do
		if chosen and entry.label == chosen.label and entry.text == chosen.text
		then
			selected = i;

			break;
		end
	end

	self.ctx = ctx;
	self.entries = entries;
	self.selected = selected;
	self.top = 1;
	self.wantVisible = typing;
	self:layout();
	self:keepVisible();
	self:place(true);
end

function C:close()
	self.isOpen = false;
	self.entries = {};
	self.ctx = nil;
	self.hover = nil;

	if self.popup
	then
		self.popup:setVisible(false);
	end
end

function C:keepVisible()
	local rows = math.max(1, self.rows or math.min(#self.entries, V.maxRows));

	if self.selected < self.top
	then
		self.top = self.selected;
	elseif self.selected > self.top + rows - 1
	then
		self.top = self.selected - rows + 1;
	end
end

-- Up / Down (the list open)
function C:move(delta)
	local count = #self.entries;

	if count == 0
	then
		return;
	end

	self.selected = self.selected + delta;

	if self.selected < 1
	then
		self.selected = count;
	elseif self.selected > count
	then
		self.selected = 1;
	end

	self:keepVisible();
	self:layoutHelp();
end

function C:scroll(delta)
	local rows = math.max(1, self.rows or math.min(#self.entries, V.maxRows));

	self.top = math.max(1, math.min(self.top + delta, #self.entries - rows + 1));
end

-- the box moved its cursor a row (UITextBox2.onKeyUp / onKeyDown), then told us: back where it was, the choice moves
function C:onArrow(delta)
	if not self.isOpen
	then
		return;
	end

	self.window:setCaret(self.caret);
	self:move(delta);
end

-- Tab and Esc (UITextBox2.onOtherKey); true when used
function C:onKey(key)
	if not self.isOpen
	then
		return false;
	end

	if key == KEY_TAB
	then
		self:accept(self.selected);

		return true;
	elseif key == KEY_ESCAPE
	then
		self:close();

		return true;
	end

	return false;
end

-- writes the entry (Tab, Enter, a click)
function C:accept(index)
	local entry = self.entries[index];
	local ctx = self.ctx;

	if entry == nil or ctx == nil or self.text == nil
	then
		self:close();

		return;
	end

	local newText, newCaret = Suggest():apply(self.text, self.caret, ctx, entry);

	self.window:replaceText(newText, newCaret, false);
	self.text, self.caret = newText, newCaret;

	if entry.reopen
	then
		self:open(true, nil);
	else
		self:close();
	end
end

-- ============================================================================================================
-- Sizes and place
-- ============================================================================================================

-- the rows' height, the width and the texts as drawn (labels in the editor's font, details and help in the small one)
function C:layout()
	local w = self.window;
	local tm = getTextManager();
	local codeFont = w.codeFont or UIFont.Small;
	local font = UIFont.Small;
	local codeHeight = tm:getFontHeight(codeFont);
	local height = tm:getFontHeight(font);
	local rowHeight = math.max(codeHeight, height) + 2;
	local pad = math.max(4, math.floor(height / 3));
	local gap = pad * 3;
	local screenWidth = getPlayerScreenWidth(w.playerNum or 0);
	local maxWidth = math.floor(screenWidth * 0.45);
	local minWidth = math.min(maxWidth, measure(font, "M") * 18);
	local labelWidth, detailWidth, helpWidth = 0, 0, 0;
	local scrollRoom = #self.entries > V.maxRows and 6 or 0;

	for i, entry in ipairs(self.entries)
	do
		entry.labelWidth = measure(codeFont, entry.label);
		entry.detailWidth = entry.detail and measure(font, entry.detail) or 0;
		labelWidth = math.max(labelWidth, entry.labelWidth);
		detailWidth = math.max(detailWidth, entry.detailWidth);
		helpWidth = math.max(helpWidth, measure(font, helpOf(entry)));
	end

	local width = pad + labelWidth + (detailWidth > 0 and (gap + detailWidth) or 0) + pad + scrollRoom;

	width = math.max(width, helpWidth + 2 * pad);
	width = math.floor(math.max(minWidth, math.min(width, maxWidth)));

	local inner = width - 2 * pad - scrollRoom;

	for i, entry in ipairs(self.entries)
	do
		entry.shownLabel = entry.labelWidth > inner and fit(codeFont, entry.label, inner) or entry.label;

		local room = inner - math.min(entry.labelWidth, inner) - gap;

		if entry.detail and room >= measure(font, "M...")
		then
			entry.shownDetail = entry.detailWidth > room and fit(font, entry.detail, room) or entry.detail;
		else
			entry.shownDetail = nil;
		end
	end

	self.rowHeight = rowHeight;
	self.pad = pad;
	self.codeFont = codeFont;
	self.codeHeight = codeHeight;
	self.fontHeight = height;
	self.scrollRoom = scrollRoom;
	self.width = width;
	self.rows = math.min(#self.entries, V.maxRows);
	self.height = self.rows * rowHeight + rowHeight + 3;
	self:layoutHelp();
end

function C:layoutHelp()
	self.help = fit(UIFont.Small, helpOf(self.entries[self.selected]), (self.width or 0) - 2 * (self.pad or 0));
end

function C:popupElement()
	if self.popup == nil
	then
		local Editor = AutoPilotMoon.Macro.Editor;
		local popup = Editor.Popup:new(0, 0, 10, 10);

		popup:initialise();
		popup:instantiate();
		popup.controller = self;
		popup.background = false;
		popup:setAlwaysOnTop(true);
		popup:setVisible(false);
		popup:addToUIManager();
		self.popup = popup;
	end

	return self.popup;
end

-- Under the first character of the word (or of the name in quotes), below its row; above it when there is no room
-- below on the player's screen, moved left when it would go past the right edge. Hidden while that row is scrolled
-- out of the box. Worked out again only when something it depends on changed.
function C:place(force)
	local w = self.window;
	local entry = w.entry;
	local ctx = self.ctx;

	if not self.isOpen or ctx == nil
	then
		return;
	end

	-- the box's rows are those of its drawn text (getText): right after a key it is still the one before (the box's
	-- update copies it before the next render), and the row would be wrong. The window's prerender places it then
	if entry:getText() ~= entry.javaObject:getInternalText()
	then
		self.placed = nil;

		return;
	end

	local anchor = ctx.lineStart + ctx.from - 1;

	-- typed on a row out of view (the box does not scroll by itself: UITextBox2.update only snaps the scroll to the
	-- rows): the cursor's row in view once, when the list opens or follows the typing
	if self.wantVisible
	then
		self.wantVisible = false;
		w:syncView();
		w:scrollToCaret(self.caret);
	end

	local ex, ey = entry:getAbsoluteX(), entry:getAbsoluteY();
	local scroll = entry:getYScroll();
	local entryWidth = entry:getWidth();
	local textLength = string.len(entry:getText() or "");
	-- what the place depends on, compared number by number (no string made every frame)
	local p = self.placed;

	if not force and p and p.ex == ex and p.ey == ey and p.scroll == scroll and p.anchor == anchor and p.width == self.width
		and p.height == self.height and p.entryWidth == entryWidth and p.textLength == textLength
	then
		return;
	end

	local popup = self:popupElement();

	w:syncView();

	local row, x = w.codeView:offsetPlace(anchor);
	local lh = w.lineHeight;
	local inset = w.textInset;
	local rowTop = ey + inset + (row - 1) * lh + scroll;

	if rowTop < ey or rowTop + lh > ey + entry:getHeight()
	then
		popup:setVisible(false);
		self.placed = nil;

		return;
	end

	local playerNum = w.playerNum or 0;
	local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum);
	local right, bottom = left + getPlayerScreenWidth(playerNum), top + getPlayerScreenHeight(playerNum);
	local px = ex + inset + x - self.pad;
	local below = bottom - (rowTop + lh + 1);
	local above = rowTop - 1 - top;
	local rh = self.rowHeight;
	local rows = math.min(#self.entries, V.maxRows);

	-- below the row; above it when it does not fit below; on a small screen with a big font, on the side with more
	-- room and with fewer rows (never over the row)
	if rows * rh + rh + 3 > below and rows * rh + rh + 3 > above
	then
		rows = math.max(1, math.min(rows, math.floor((math.max(below, above) - rh - 3) / rh)));
	end

	if rows ~= self.rows
	then
		self.rows = rows;
		self.height = rows * rh + rh + 3;
		self:keepVisible();
	end

	local py = rowTop + lh + 1;

	if self.height > below and above > below
	then
		py = rowTop - self.height - 1;
		self.above = true;
	else
		self.above = false;
	end

	py = math.max(top, math.min(py, bottom - self.height));
	px = math.max(left, math.min(px, right - self.width));

	popup:setX(math.floor(px));
	popup:setY(math.floor(py));
	popup:setWidth(self.width);
	popup:setHeight(self.height);
	popup:setVisible(true);
	popup:bringToTop();
	self.placed = { ex = ex, ey = ey, scroll = scroll, anchor = anchor, width = self.width, height = self.height,
		entryWidth = entryWidth, textLength = textLength };
end

-- ============================================================================================================
-- The popup (an ISPanel of its own on the screen, always on top; derived by Editor:createClasses)
-- ============================================================================================================

local P = {};

V.PopupMethods = P;

-- the row (index into the entries) at y, or nil
function P:rowAt(y)
	local c = self.controller;

	if c == nil or not c.isOpen or c.rowHeight == nil
	then
		return nil;
	end

	local k = math.floor((y - 1) / c.rowHeight);

	if k < 0 or k >= c.rows
	then
		return nil;
	end

	return c.top + k;
end

function P:prerender()
	local c = self.controller;

	if c == nil or not c.isOpen
	then
		return;
	end

	local colors = V.colors;
	local view = AutoPilotMoon.Macro.CodeView.colors;
	local width, height = self.width, self.height;
	local rh = c.rowHeight;
	local pad = c.pad;
	local bg = colors.background;
	local border = colors.border;

	self:drawRect(0, 0, width, height, 0.97, bg.r, bg.g, bg.b);

	for k = 0, c.rows - 1
	do
		local i = c.top + k;
		local entry = c.entries[i];

		if entry == nil
		then
			break;
		end

		local y = 1 + k * rh;

		if i == c.selected
		then
			local s = colors.selected;

			self:drawRect(1, y, width - 2, rh, 1, s.r, s.g, s.b);
		elseif i == c.hover
		then
			local s = colors.hover;

			self:drawRect(1, y, width - 2, rh, 1, s.r, s.g, s.b);
		end

		local col = view[entry.class] or view.plain;

		self:drawText(entry.shownLabel or entry.label, pad, y + math.floor((rh - c.codeHeight) / 2), col.r, col.g, col.b, 1, c.codeFont);

		if entry.shownDetail
		then
			local d = colors.detail;

			self:drawTextRight(entry.shownDetail, width - pad - c.scrollRoom, y + math.floor((rh - c.fontHeight) / 2), d.r, d.g, d.b, 1, UIFont.Small);
		end
	end

	-- a scroll bar when there are more entries than rows
	if #c.entries > c.rows
	then
		local s = colors.scroll;
		local track = c.rows * rh;
		local thumb = math.max(4, math.floor(track * c.rows / #c.entries));
		local at = math.floor((track - thumb) * (c.top - 1) / math.max(1, #c.entries - c.rows));

		self:drawRect(width - 5, 1 + at, 3, thumb, 0.8, s.r, s.g, s.b);
	end

	-- the help of the entry chosen, under a line
	local lineY = 1 + c.rows * rh;

	self:drawRect(1, lineY, width - 2, 1, 1, border.r, border.g, border.b);

	if c.help
	then
		local h = colors.help;

		self:drawText(c.help, pad, lineY + 1 + math.floor((rh - c.fontHeight) / 2), h.r, h.g, h.b, 1, UIFont.Small);
	end

	self:drawRectBorder(0, 0, width, height, 1, border.r, border.g, border.b);
end

function P:render()
end

function P:onMouseDown(x, y)
	local i = self:rowAt(y);

	if i
	then
		self.controller:accept(i);
	end

	return true;
end

function P:onMouseUp(x, y)
	return true;
end

function P:onMouseMove(dx, dy)
	if self.controller
	then
		self.controller.hover = self:rowAt(self:getMouseY());
	end

	return true;
end

function P:onMouseMoveOutside(dx, dy)
	if self.controller
	then
		self.controller.hover = nil;
	end
end

function P:onMouseWheel(delta)
	if self.controller
	then
		self.controller:scroll(delta > 0 and 1 or -1);
	end

	return true;
end
