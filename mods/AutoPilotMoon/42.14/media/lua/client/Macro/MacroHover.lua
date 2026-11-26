-- AutoPilot (Moon): automations for the Moon server.

-- The macro editor's help under the mouse (19/11/2026, MACRO-AUTOPILOT.md 4.13): the mouse resting ~400 ms on a word
-- of the macro shows a small box in the game's tooltip style, beside the line and never over it, never off the
-- player's screen: over a word underlined by the check its problem; over a command its usage and its help, over a
-- statement's word (while, if, else...) the statement and its help, over a keyword argument (using=) its help, over a
-- state word (a moodle, endurance, craving, dark, hour) what MacroLang's Lang:hover(word) says of it (what it means
-- alone, one line per level, what a number means: already translated, MACRO-AUTOPILOT.md 16.5), else its one-line
-- help; over not / possible / True / and / or their help. Every help is the
-- suggestions' own (IGUI_AutoPilot_E_Sug_*: one source). Option "Macro: aiuto sotto il mouse"
-- (macroHover, on by default).
--
-- The word under the mouse is found on the colours' rows (MacroCodeView: the box's rows done again, the long lines
-- wrapped as the box wraps them), with the same advances the colours draw with, and read with MacroLang:classify.
-- Cost: every frame only the mouse position, the box's scroll and its string (the same object while nothing changes)
-- compared; the word, the texts and the sizes when the mouse has rested; the box draws strings already made.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Hover = AutoPilotMoon.Macro.Hover or {};

local Hv = AutoPilotMoon.Macro.Hover;

Hv.delayMs = 400;
Hv.gap = 2;              -- between the line and the box

local len = string.len;
local sub = string.sub;

local function Lang()
	return AutoPilotMoon.Macro.Lang;
end

-- a translation that may be missing (a word without a help of its own: no box rather than the key's name)
local function textOrNil(key, arg)
	local t = nil;

	if arg
	then
		t = getTextOrNull(key, arg);
	else
		t = getTextOrNull(key);
	end

	if t == nil or t == "" or t == key
	then
		return nil;
	end

	return t;
end

-- ============================================================================================================
-- Pure: where, which word, what to say
-- ============================================================================================================

-- The row, the line and the character of a CodeView under a point of the box: x, y from the box's top-left corner on
-- the screen (not scrolled), scroll = the box's getYScroll. The row k is drawn at y = inset + (k - 1) * line height +
-- scroll (MacroCodeView.drawFront), each character moves the next one by its advance (a character from 256 up drawn
-- as "?"). nil past the end of a row or outside the rows.
function AutoPilotMoon.Macro.Hover.locate(view, x, y, scroll)
	local lh = view.lineHeight;
	local inset = view.inset or 0;

	if lh == nil or lh <= 0 or view.rows == nil
	then
		return nil;
	end

	local index = math.floor((y - inset - (scroll or 0)) / lh) + 1;
	local row = view.rows[index];
	local lx = x - inset;

	if row == nil or lx < 0
	then
		return nil;
	end

	local line = view.lines[row.line] or "";
	local at = 0;

	for k = 0, row.len - 1
	do
		local c = sub(line, row.a + k, row.a + k);

		if string.byte(c) >= 256
		then
			c = "?";
		end

		local width = view:advance(c);

		if lx < at + width
		then
			return { row = index, line = row.line, pos = row.a + k, x = at, rowTop = inset + (index - 1) * lh + (scroll or 0) };
		end

		at = at + width;
	end

	return nil;
end

-- the word at a character of a line (1-based): its first and last character, its text and the class the colours give
-- it (MacroLang:classify)
function AutoPilotMoon.Macro.Hover.wordAt(line, pos)
	local L = Lang();
	local classes = L:classify(line);
	local class = classes[pos];
	local c = sub(line, pos, pos);

	if c == "" or not L.isNameChar(c)
	then
		return { s = pos, e = pos, class = class };
	end

	local s, e = pos, pos;

	while s > 1 and L.isNameChar(sub(line, s - 1, s - 1)) and classes[s - 1] == class
	do
		s = s - 1;
	end

	while e < len(line) and L.isNameChar(sub(line, e + 1, e + 1)) and classes[e + 1] == class
	do
		e = e + 1;
	end

	return { s = s, e = e, word = sub(line, s, e), class = class };
end

-- the statement of the language a keyword stands for on that line (while possible:, while True:, while ...:)
local function statementFor(line, word)
	local L = Lang();
	local code = string.lower(L.plainLine(line));

	if word == "while"
	then
		local id = "while_cond";

		if string.find(code, "while%s+possible%s*:")
		then
			id = "while_possible";
		elseif string.find(code, "while%s+true%s*:")
		then
			id = "while_true";
		end

		for i, statement in ipairs(L.statementList)
		do
			if statement.id == id
			then
				return statement;
			end
		end
	end

	for i, statement in ipairs(L.statementList)
	do
		if statement.word == word
		then
			return statement;
		end
	end

	return nil;
end

-- what MacroLang says of a state word (Lang:hover, MACRO-AUTOPILOT.md 16.5; absent or failing: nil): its lines but the
-- first, which is its own title (the word and its name: the box has its title already)
local function langLines(word)
	local L = Lang();

	if type(L.hover) ~= "function"
	then
		return nil;
	end

	local ok, lines = pcall(L.hover, L, word);

	if not ok or type(lines) ~= "table" or #lines < 2
	then
		return nil;
	end

	local out = {};

	for i, line in ipairs(lines)
	do
		if i > 1 and type(line) == "string" and line ~= ""
		then
			table.insert(out, line);
		end
	end

	return #out > 0 and out or nil;
end

-- What the box says for the character pos of a line: { title, titleClass (the colours' class), lines = { text, color
-- ("bad", "warn", nil) }, s, e (the word) } or nil. problems: the checked problems of this line whose word is
-- underlined ({ s, e, text, warn }, columns of the line as shown)
function AutoPilotMoon.Macro.Hover.describe(line, pos, problems)
	for i, problem in ipairs(problems or {})
	do
		if problem.text and problem.s and problem.e and pos >= problem.s and pos <= problem.e
		then
			return { lines = { { text = problem.text, color = problem.warn and "warn" or "bad" } }, s = problem.s, e = problem.e };
		end
	end

	local word = Hv.wordAt(line, pos);

	if word.word == nil
	then
		return nil;
	end

	local L = Lang();
	local lower = string.lower(word.word);
	local class = word.class;
	local info = { s = word.s, e = word.e, titleClass = class, lines = {} };
	local help = nil;

	if class == "keyword"
	then
		local statement = statementFor(line, lower);

		if statement
		then
			info.title = statement.label or statement.text;
			help = textOrNil("IGUI_AutoPilot_E_Sug_Kw_" .. statement.id);
		end
	elseif class == "call"
	then
		local spec = L.calls[lower] or L.condCalls[lower];

		if spec
		then
			info.title = spec.usage;
			help = textOrNil("IGUI_AutoPilot_E_Sug_Call_" .. lower);

			-- walk_to (26/11/2026, ANALISI-AUTONOMIA.md 3.3): its two forms in the title, and what a walk leaves behind
			if lower == "walk_to" and help
			then
				local door = textOrNil("IGUI_AutoPilot_E_Hover_WalkDoor");

				if door
				then
					table.insert(info.lines, { text = help });
					help = door;
				end
			end
		end
	elseif class == "param"
	then
		info.title = lower .. "=";
		help = textOrNil("IGUI_AutoPilot_E_Sug_Arg_" .. lower);
	elseif class == "logic" or (class == "number" and lower == "true")
	then
		info.title = word.word;
		help = textOrNil("IGUI_AutoPilot_E_Sug_Word_" .. (lower == "true" and "True" or lower))
			or textOrNil("IGUI_AutoPilot_E_Hover_Word_" .. lower);
	elseif class == "name"
	then
		local levels = langLines(lower);

		if L.moodles[lower]
		then
			local italian = textOrNil("IGUI_AutoPilot_E_Moodle_" .. lower);

			info.title = italian and (lower .. " - " .. italian) or lower;
			help = (levels == nil) and textOrNil("IGUI_AutoPilot_E_Sug_Moodle", italian or lower) or nil;
		elseif L.percents[lower]
		then
			local italian = textOrNil("IGUI_AutoPilot_E_Moodle_" .. lower);

			info.title = italian and (lower .. " - " .. italian) or lower;
			help = (levels == nil) and textOrNil("IGUI_AutoPilot_E_Sug_Percent", italian or lower) or nil;
		elseif L.condWords[lower]
		then
			info.title = lower;
			help = (levels == nil) and textOrNil("IGUI_AutoPilot_E_Sug_Cond_" .. lower) or nil;
		elseif levels
		then
			info.title = word.word;
		end

		for i, text in ipairs(levels or {})
		do
			table.insert(info.lines, { text = text });
		end
	end

	if help
	then
		table.insert(info.lines, { text = help });
	end

	if info.title == nil and #info.lines == 0
	then
		return nil;
	end

	return info;
end

-- the words of text in lines of at most width pixels (measure(s): the width; a word longer than the line stays whole)
function AutoPilotMoon.Macro.Hover.wrap(text, width, measure)
	local lines = {};
	local current = nil;

	for word in string.gmatch(text or "", "%S+")
	do
		local candidate = current and (current .. " " .. word) or word;

		if current and measure(candidate) > width
		then
			table.insert(lines, current);
			current = word;
		else
			current = candidate;
		end
	end

	if current
	then
		table.insert(lines, current);
	end

	return lines;
end

-- ============================================================================================================
-- The controller (one per editor window) and its box
-- ============================================================================================================

local C = {};
local CMeta = { __index = C };

Hv.ControllerMethods = C;

function AutoPilotMoon.Macro.Hover:attach(window)
	local o = { window = window };

	setmetatable(o, CMeta);

	return o;
end

function AutoPilotMoon.Macro.Hover.isOn()
	return AutoPilotMoon.Options:get("macroHover") ~= false;
end

-- the mouse over the macro's text, nothing else in the way (the suggestions' list, a menu over it, renaming)
function C:wanted()
	local w = self.window;
	local entry = w.entry;

	return Hv.isOn() and w:getIsVisible() and not w.isCollapsed and entry ~= nil and entry:isMouseOver() == true
		and not (w.suggest and w.suggest.isOpen) and not w.renaming and w.codeView ~= nil;
end

-- every frame (the window's update): the mouse resting, the box shown or hidden
function C:poll()
	if not self:wanted()
	then
		self:hide();
		self.mx = nil;

		return;
	end

	local entry = self.window.entry;
	local mx, my = getMouseX(), getMouseY();
	local scroll = entry:getYScroll();
	local text = entry:getText();
	local now = getTimestampMs();

	if mx ~= self.mx or my ~= self.my or scroll ~= self.scroll or text ~= self.text
	then
		self.mx, self.my, self.scroll, self.text = mx, my, scroll, text;
		self.since = now;
		self.tried = false;
		self:hide();

		return;
	end

	if self.tried or now - (self.since or now) < Hv.delayMs
	then
		return;
	end

	self.tried = true;

	local ok, err = pcall(self.show, self, mx, my);

	if not ok
	then
		-- never expected: the help stays off for this window, the editor goes on
		self.failed = tostring(err);
		print("AutoPilot (Moon): macro editor hover turned off: " .. self.failed);
		self:hide();
	end
end

-- the problems of a line as the colours underline them (only while the line is still the one checked)
function C:problemsOf(index, line)
	local view = self.window.codeView;
	local spans = view.spans and view.spans[index];

	if spans == nil or view.problemLines == nil or view.problemLines[index] ~= line
	then
		return nil;
	end

	return spans;
end

function C:show(mx, my)
	if self.failed
	then
		return;
	end

	local w = self.window;
	local entry = w.entry;
	local view = w.codeView;
	local ex, ey = entry:getAbsoluteX(), entry:getAbsoluteY();
	local inset = w.textInset or 2;

	-- inside the box's text area (its stencil), not on its scroll bar
	if my < ey + inset or my >= ey + entry:getHeight() - inset or mx < ex + inset
	then
		return;
	end

	w:syncView();

	local hit = Hv.locate(view, mx - ex, my - ey, entry:getYScroll());

	if hit == nil
	then
		return;
	end

	local line = view.lines[hit.line] or "";
	local info = Hv.describe(line, hit.pos, self:problemsOf(hit.line, line));

	if info == nil
	then
		return;
	end

	-- where the word starts on its row
	local row = view.rows[hit.row];
	local wordX = hit.x;

	if row and info.s and info.s >= row.a and info.s < hit.pos
	then
		wordX = view:drawnWidth(line, row.a, info.s - 1);
	end

	self:layout(info);
	self:place(ex + inset + wordX, ey + hit.rowTop, view.lineHeight);
end

-- the texts and the sizes (title in the macro's font and the colour of its class, the rest in the small font)
function C:layout(info)
	local w = self.window;
	local tm = getTextManager();
	local small = UIFont.Small;
	local codeFont = w.codeFont or small;
	local playerNum = w.playerNum or 0;
	local pad = math.max(4, math.floor(tm:getFontHeight(small) / 2));
	local maxWidth = math.floor(math.min(getPlayerScreenWidth(playerNum) * 0.45, tm:MeasureStringX(small, "M") * 46));
	local rows = {};
	local width = 0;
	local colors = AutoPilotMoon.Macro.CodeView.colors;
	local function measureSmall(s) return tm:MeasureStringX(small, s); end

	if info.title
	then
		local c = colors[info.titleClass] or colors.plain;
		local title = info.title;

		if tm:MeasureStringX(codeFont, title) > maxWidth
		then
			-- a long usage: cut with "..."
			while len(title) > 4 and tm:MeasureStringX(codeFont, title .. "...") > maxWidth
			do
				title = sub(title, 1, len(title) - 1);
			end

			title = title .. "...";
		end

		table.insert(rows, { text = title, font = codeFont, r = c.r, g = c.g, b = c.b, height = tm:getFontHeight(codeFont) });
	end

	for i, entry in ipairs(info.lines)
	do
		local r, g, b = 0.9, 0.9, 0.9;

		if entry.color == "bad"
		then
			r, g, b = AutoPilotMoon.UI:badColor();
		elseif entry.color == "warn"
		then
			local warn = AutoPilotMoon.Macro.Editor.warnColor;

			r, g, b = warn.r, warn.g, warn.b;
		end

		for k, text in ipairs(Hv.wrap(entry.text, maxWidth, measureSmall))
		do
			table.insert(rows, { text = text, font = small, r = r, g = g, b = b, height = tm:getFontHeight(small) });
		end
	end

	for i, row in ipairs(rows)
	do
		row.width = tm:MeasureStringX(row.font, row.text);
		width = math.max(width, row.width);
	end

	self.rows = rows;
	self.pad = pad;
	self.width = math.min(maxWidth, width) + 2 * pad;
end

function C:heightOf(count)
	local height = 2 * self.pad;

	for i = 1, count
	do
		height = height + self.rows[i].height + (i > 1 and 2 or 0);
	end

	return height;
end

-- below the line, above it when there is no room below; never over the line (fewer rows when neither side holds them
-- all), never off the player's screen
function C:place(wordX, rowTop, lineHeight)
	local w = self.window;
	local playerNum = w.playerNum or 0;
	local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum);
	local right, bottom = left + getPlayerScreenWidth(playerNum), top + getPlayerScreenHeight(playerNum);
	local below = bottom - (rowTop + lineHeight + Hv.gap);
	local above = rowTop - Hv.gap - top;
	local count = #self.rows;

	while count > 1 and self:heightOf(count) > math.max(below, above)
	do
		count = count - 1;
	end

	-- the rows that do not fit on either side are left out (a long help on a small screen with a big font)
	while #self.rows > count
	do
		table.remove(self.rows);
	end

	local height = self:heightOf(count);
	local y = rowTop + lineHeight + Hv.gap;

	if height > below and above > below
	then
		y = rowTop - Hv.gap - height;
	end

	local x = math.max(left, math.min(wordX - self.pad, right - self.width));

	y = math.max(top, math.min(y, bottom - height));

	local panel = self:panel();

	-- the size first (ISUIElement.setY keeps an element on the screen with the height it has then)
	panel:setWidth(self.width);
	panel:setHeight(height);
	panel:setX(math.floor(x));
	panel:setY(math.floor(y));
	panel:setVisible(true);
	panel:bringToTop();
	self.shown = true;
end

function C:panel()
	if self.box == nil
	then
		if Hv.Panel == nil
		then
			Hv.Panel = ISPanel:derive("AutoPilotMacroHover");

			for name, fn in pairs(Hv.PanelMethods)
			do
				Hv.Panel[name] = fn;
			end
		end

		local box = Hv.Panel:new(0, 0, 10, 10);

		box:initialise();
		box:instantiate();
		box.controller = self;
		box.background = false;
		box:setAlwaysOnTop(true);
		box:setVisible(false);
		box:addToUIManager();
		self.box = box;
	end

	return self.box;
end

function C:hide()
	if self.shown and self.box
	then
		self.box:setVisible(false);
	end

	self.shown = false;
end

-- the window leaves the game's UI (the player's master switch off, MacroEditor:shutdown)
function C:dispose()
	self:hide();

	if self.box
	then
		self.box:removeFromUIManager();
		self.box = nil;
	end
end

-- ============================================================================================================
-- The box (an ISPanel of its own, always on top; the game's tooltip look: ISToolTip.render of 42.22)
-- ============================================================================================================

local P = {};

Hv.PanelMethods = P;

function P:prerender()
	local c = self.controller;

	if c == nil or not c.shown or c.rows == nil
	then
		return;
	end

	-- the game's tooltip colours, a little less see-through: it stands over code
	self:drawRect(0, 0, self.width, self.height, 0.92, 0.05, 0.05, 0.05);
	self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.9, 0.9, 1);

	local y = c.pad;

	for i, row in ipairs(c.rows)
	do
		self:drawText(row.text, c.pad, y, row.r, row.g, row.b, 1, row.font);
		y = y + row.height + 2;
	end
end

function P:render()
end

-- the mouse never rests on the box (it is placed off the line under the mouse); a click passes nothing on
function P:onMouseDown(x, y)
	return false;
end
