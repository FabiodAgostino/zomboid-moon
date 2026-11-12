-- AutoPilot (Moon): automations for the Moon server.

-- The colours of the macro editor's text (MACRO-AUTOPILOT.md 4.11): Visual Studio's dark theme over the game's own
-- text box. The game's box (zombie.ui.UITextBox2 of 42.22) draws all its text in one colour: it keeps typing, the
-- caret, the selection, Enter, the clipboard; its text is drawn in the colour of its background (invisible: it draws
-- with alpha 1 whatever the colour's alpha) and this file draws the same text again, coloured, at exactly the places
-- the box drew it:
--
--   * the box's lines (UITextBox2.Paginate, read in the 42.22 jar): the text split at "\n" (an empty last line kept),
--     each line wrapped at a space when the words up to the next space are as wide as the box less 2 insets and 17
--     pixels; the space where it wraps is not drawn, a word wider than the box is not cut. Done again here with the
--     same measure (TextManager.MeasureStringX), so the rows are the box's rows, and their places in the whole text
--     (textOffsetOfLineStart) too: the caret's row is UITextBox2.toDisplayLine done again;
--   * where: the row k of the box at y = inset + k * line height, moved by the box's scroll; x = inset (a box on more
--     lines never scrolls sideways: UITextBox2.keepCursorVisible keeps xOffset at 0), the box's stencil (inset on every
--     side);
--   * each colour is one string as long as the row, the characters of the other colours turned into spaces: the font is
--     fixed-width (UIFont.CodeSmall: every character as wide as the space), so every character is drawn by the game's
--     own AngelCodeFont.drawString at the very place it draws it in the box. A character the font cannot draw (no
--     glyph: drawn as nothing) is kept as it is in every colour;
--   * the caret again, over the coloured text (the box draws it before), steady; the selection is the box's own, under
--     the coloured text;
--   * under the coloured text, see-through: the row of the line running, the rows of the lines with an error (the box's
--     hidden text under them stays invisible); a red line under the word an error is about, an amber one under the word
--     a warning is about (MacroLang's problem.s / problem.e, problem.warn).
--
-- Cost: the text is split and wrapped again only when it changes (the box's own string, compared every frame: the same
-- object while nothing changes), the width or the font; a line's colours are worked out once per text of the line
-- (MacroLang:classify) and kept; a row's strings when it is first drawn. Every frame: only drawText of strings ready.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.CodeView = AutoPilotMoon.Macro.CodeView or {};

local View = AutoPilotMoon.Macro.CodeView;

local function rgb(r, g, b)
	return { r = r / 255, g = g / 255, b = b / 255 };
end

-- Visual Studio Code's "Dark+" for Python (the classes of MacroLang:classify)
View.colors = {
	plain = rgb(212, 212, 212),     -- #D4D4D4 operators, brackets, other words
	keyword = rgb(197, 134, 192),   -- #C586C0 while if elif else when repeat break pass
	logic = rgb(86, 156, 214),      -- #569CD6 and or not possible
	call = rgb(220, 220, 170),      -- #DCDCAA craft eat has skill...
	param = rgb(156, 220, 254),     -- #9CDCFE using= minutes=...
	name = rgb(79, 193, 255),       -- #4FC1FF hungry, endurance, a skill's name
	string = rgb(206, 145, 120),    -- #CE9178 "text"
	number = rgb(181, 206, 168),    -- #B5CEA8 3, True, False
	comment = rgb(106, 153, 85),    -- #6A9955 # comment
};
View.classOrder = { "plain", "keyword", "logic", "call", "param", "name", "string", "number", "comment" };
View.background = rgb(30, 30, 30);      -- #1E1E1E the editor's background
-- the rows of a line with an error and of the line running: see-through, over the box's hidden text (drawn in the
-- background's colour, it vanishes under them as under the background) and its selection, under the coloured text;
-- over the background #1E1E1E they give #3C1E1E (red) and #303018 (olive)
View.errorRow = { r = 1, g = 30 / 255, b = 30 / 255, a = 30 / 225 };
View.runningRow = { r = 120 / 255, g = 120 / 255, b = 0, a = 0.2 };
View.underline = rgb(241, 76, 76);      -- #F14C4C the word an error is about
View.warnUnderline = rgb(204, 167, 0);  -- #CCA700 the word a warning is about (VS Code's warning squiggle)
-- UITextBox2.textEntryCursorColour of 42.22: Color(170, 170, 220, 240)
View.caret = { r = 170 / 255, g = 170 / 255, b = 220 / 255, a = 240 / 255 };
-- UITextBox2.Paginate: the room it leaves for the scroll bar when it wraps
View.scrollBarRoom = 17;
View.maxCachedLines = 1000;

local Methods = {};
local Meta = { __index = Methods };

View.Methods = Methods;

-- a view for one text box; font: a UIFont
function AutoPilotMoon.Macro.CodeView:new()
	local o = { lineCache = {}, cacheCount = 0, wrapCache = {}, advances = {}, rows = {}, firstRow = {}, lines = {},
		problemLines = {}, errorLines = {}, spans = {}, generation = 0 };

	setmetatable(o, Meta);

	return o;
end

-- the text split as UITextBox2.Paginate does (String.split("\n", -1): an empty line after a last "\n" kept)
function AutoPilotMoon.Macro.CodeView.splitLines(text)
	local lines = {};
	local start = 1;

	text = text or "";

	while true
	do
		local stop = string.find(text, "\n", start, true);

		if stop == nil
		then
			table.insert(lines, string.sub(text, start));

			return lines;
		end

		table.insert(lines, string.sub(text, start, stop - 1));
		start = stop + 1;
	end
end

-- The rows of one line as UITextBox2.Paginate makes them (42.22 jar, line by line): { { a = first character (1 =
-- the line's first), len = characters } ... }. limit = width - 2 * inset - 17; measure(s) = TextManager.MeasureStringX.
-- In Java: n = 0; loop { m = rest.indexOf(" ", n + 1); z = m == -1 ? rest.length : m; wid = measure(rest[0, z]);
-- if (wrap && wid >= limit && n > 0) { a row of rest[0, n]; rest = rest[n + 1 ..]; m = 0 } else if (m == -1) { a row
-- of rest; next line } n = m; while rest not empty }. A row ends before the space where it wraps (that space is not
-- drawn); a rest left empty by a wrap adds no row.
function AutoPilotMoon.Macro.CodeView.wrapLine(line, wrap, limit, measure)
	local rows = {};
	local length = string.len(line);

	if length == 0 or not wrap
	then
		table.insert(rows, { a = 1, len = length });

		return rows;
	end

	local rest = line;
	local base = 0;
	local n = 0;

	while true
	do
		local found = string.find(rest, " ", n + 2, true);
		local m = found and (found - 1) or -1;
		local z = m == -1 and string.len(rest) or m;
		local width = measure(string.sub(rest, 1, z));

		if width >= limit and n > 0
		then
			table.insert(rows, { a = base + 1, len = n });
			base = base + n + 1;
			rest = string.sub(rest, n + 2);
			m = 0;
		elseif m == -1
		then
			table.insert(rows, { a = base + 1, len = string.len(rest) });

			return rows;
		end

		n = m;

		if rest == ""
		then
			return rows;
		end
	end
end

-- ============================================================================================================
-- The layout (only when the text, the width, the font or the wrapping change)
-- ============================================================================================================

-- the font and its measure (a new font: every measure and colour string kept is forgotten)
function Methods:setFont(font, lineHeight, inset, measure)
	if font == self.font and lineHeight == self.lineHeight and inset == self.inset
	then
		return;
	end

	self.font = font;
	self.lineHeight = lineHeight;
	self.inset = inset;
	self.measure = measure;
	self.advances = {};
	self.lineCache = {};
	self.cacheCount = 0;
	self.wrapCache = {};
	self.text = nil;
end

-- how far a character moves the next one, as AngelCodeFont.getWidth counts it (0 for a character without a glyph)
function Methods:advance(c)
	local a = self.advances[c];

	if a == nil
	then
		a = self.measure(c .. "x") - self.measure("x");
		self.advances[c] = a;
	end

	return a;
end

-- every character the box can show as wide as the space: the colours need a fixed-width font
function Methods:isMonospace()
	if self.monospace == nil or self.monospaceFont ~= self.font
	then
		local space = self:advance(" ");

		self.monospaceFont = self.font;
		self.monospace = space > 0;

		for i, c in ipairs({ "i", "W", "m", "?", "1", ".", "_" })
		do
			if self:advance(c) ~= space
			then
				self.monospace = false;
			end
		end
	end

	return self.monospace;
end

-- the rows again when the text, the width or the wrapping changed (true when they did)
function Methods:sync(text, width, wrap)
	text = text or "";

	if text == self.text and width == self.width and wrap == self.wrap
	then
		return false;
	end

	if width ~= self.width or wrap ~= self.wrap
	then
		self.wrapCache = {};
	end

	self.text = text;
	self.width = width;
	self.wrap = wrap;
	self.generation = self.generation + 1;

	local limit = width - 2 * self.inset - View.scrollBarRoom;
	local lines = View.splitLines(text);
	local rows = {};
	local firstRow = {};
	local offset = 0;

	for L, line in ipairs(lines)
	do
		local segments = self.wrapCache[line];

		if segments == nil
		then
			segments = View.wrapLine(line, wrap, limit, self.measure);
			self.wrapCache[line] = segments;
		end

		firstRow[L] = #rows + 1;

		for k, segment in ipairs(segments)
		do
			table.insert(rows, { line = L, a = segment.a, len = segment.len, offset = offset, first = k == 1 });
			offset = offset + segment.len + 1;
		end
	end

	self.lines = lines;
	self.rows = rows;
	self.firstRow = firstRow;

	return true;
end

-- the row (1-based) of an offset in the whole text: UITextBox2.toDisplayLine (the first row whose start <= offset <=
-- its end; else the first row)
function Methods:rowOfOffset(offset)
	for i, row in ipairs(self.rows)
	do
		if offset >= row.offset and offset <= row.offset + row.len
		then
			return i;
		end
	end

	return 1;
end

-- the row (1-based) of an offset of the whole text and the x the box's caret has there (from the text's inset, before
-- the box takes 1 off: UITextBox2.render's getWidth(row, 0, n - 1, true)); the editor's suggestions open under it
function Methods:offsetPlace(offset)
	local index = self:rowOfOffset(offset);
	local row = self.rows[index];

	if row == nil
	then
		return 1, 0;
	end

	local n = math.max(0, math.min(offset - row.offset, row.len));
	local segment = string.sub(self.lines[row.line] or "", row.a, row.a + row.len - 1);

	return index, self:caretWidth(segment, n);
end

-- the first row (1-based) of a line of the text (1-based)
function Methods:rowOfLine(line)
	return self.firstRow[line] or math.max(1, #self.rows);
end

-- the first row shown (0-based) for the box's scroll: UITextBox2.update's topLineIndex
function Methods:topRow(scroll)
	return math.max(0, math.floor((-scroll + self.inset) / self.lineHeight));
end

-- how many rows the box draws: UITextBox2.update's numVisibleLines
function Methods:visibleRows(height)
	local n = math.floor((height - 2 * self.inset) / self.lineHeight);

	if n * self.lineHeight + 2 * self.inset < math.floor(height)
	then
		n = n + 1;
	end

	return n;
end

-- ============================================================================================================
-- Colours of a line, strings of a row (worked out once, kept)
-- ============================================================================================================

-- a line's colours: { [class] = the line with the other classes' characters as spaces }, the classes in order
function Methods:lineInfo(line)
	local info = self.lineCache[line];

	if info
	then
		return info;
	end

	if self.cacheCount >= View.maxCachedLines
	then
		self.lineCache = {};
		self.cacheCount = 0;
	end

	local classes = AutoPilotMoon.Macro.Lang:classify(line);
	local n = string.len(line);
	local chars = {};
	local keep = {};
	local present = {};

	for i = 1, n
	do
		local c = string.sub(line, i, i);

		chars[i] = c;
		-- a character with no glyph below 256 is drawn as nothing and moves nothing: kept in every colour (a character
		-- from 256 up is drawn as "?", as wide as the space)
		keep[i] = string.byte(c) < 256 and self:advance(c) == 0;
		present[classes[i]] = true;
	end

	info = { masks = {}, classes = classes };

	for k, class in ipairs(View.classOrder)
	do
		if present[class]
		then
			local parts = {};
			local any = false;

			for i = 1, n
			do
				if classes[i] == class or keep[i]
				then
					parts[i] = chars[i];
					any = any or (classes[i] == class and chars[i] ~= " ");
				else
					parts[i] = " ";
				end
			end

			if any
			then
				table.insert(info.masks, { class = class, text = table.concat(parts) });
			end
		end
	end

	self.lineCache[line] = info;
	self.cacheCount = self.cacheCount + 1;

	return info;
end

-- the width the box's caret counts for the first n characters of a string (AngelCodeFont.getWidth(s, 0, n - 1, true):
-- the advances of the characters with a glyph)
function Methods:caretWidth(s, n)
	local width = 0;

	for i = 1, n
	do
		width = width + self:advance(string.sub(s, i, i));
	end

	return width;
end

-- the width drawString moves over n characters (a character from 256 up drawn as "?")
function Methods:drawnWidth(s, from, to)
	local width = 0;

	for i = from, to
	do
		local c = string.sub(s, i, i);

		if string.byte(c) >= 256
		then
			c = "?";
		end

		width = width + self:advance(c);
	end

	return width;
end

-- a row's strings ({ text, color }) and its underlines ({ x, w }), made the first time it is drawn after a change
function Methods:rowDraw(index)
	local row = self.rows[index];

	if row == nil
	then
		return nil;
	end

	if row.draw and row.drawn == self.problemGeneration
	then
		return row.draw;
	end

	local line = self.lines[row.line] or "";
	local info = self:lineInfo(line);
	local last = row.a + row.len - 1;
	local draw = { layers = {}, underlines = {} };

	if not row.draw
	then
		for k, mask in ipairs(info.masks)
		do
			local piece = string.gsub(string.sub(mask.text, row.a, last), " +$", "");

			if string.find(piece, "[^ ]")
			then
				table.insert(draw.layers, { text = piece, color = View.colors[mask.class] or View.colors.plain });
			end
		end
	else
		draw.layers = row.draw.layers;
	end

	-- the problems' words, while the line is still the one checked
	local spans = self.spans[row.line];

	if spans and self.problemLines[row.line] == line
	then
		for k, span in ipairs(spans)
		do
			local s = math.max(span.s, row.a);
			local e = math.min(span.e, last);

			if s <= e
			then
				local x = self:drawnWidth(line, row.a, s - 1);

				table.insert(draw.underlines, { x = x, w = math.max(1, self:drawnWidth(line, s, e)), warn = span.warn });
			end
		end
	end

	row.draw = draw;
	row.drawn = self.problemGeneration;

	return draw;
end

-- the checked text's problems: the lines with an error, the words to underline (MacroLang's problem.s / problem.e,
-- columns of the line as read: a tab counts 4)
function Methods:setProblems(text, problems)
	local lines = View.splitLines(text or "");
	local errorLines = {};
	local spans = {};

	for i, problem in ipairs(problems or {})
	do
		if problem.line
		then
			if not problem.warn
			then
				errorLines[problem.line] = true;
			end

			local raw = lines[problem.line];

			if raw and problem.s and problem.e
			then
				local Lang = AutoPilotMoon.Macro.Lang;

				spans[problem.line] = spans[problem.line] or {};
				table.insert(spans[problem.line], { s = Lang:rawColumn(raw, problem.s), e = Lang:rawColumn(raw, problem.e),
					warn = problem.warn == true });
			end
		end
	end

	self.problemLines = lines;
	self.errorLines = errorLines;
	self.spans = spans;
	self.problemGeneration = (self.problemGeneration or 0) + 1;
end

-- ============================================================================================================
-- Drawing (only strings and rectangles already made)
-- ============================================================================================================

-- over the box's text (after it): the rows of the line running and of the errors, the coloured text, the underlines,
-- the caret (cursor: the offset in the whole text, nil when the box has not the keyboard), inside the box's own stencil
-- (inset on every side; the rows as UITextBox2 draws its own highlighted lines: x = inset - 1, width - 2 * inset + 2)
function Methods:drawFront(entry, cursor, runningLine)
	local height = entry:getHeight();
	local width = entry:getWidth();
	local inset = self.inset;
	local lh = self.lineHeight;
	local font = self.font;
	local top = self:topRow(entry:getYScroll());
	local count = self:visibleRows(height);
	local thick = math.max(1, math.floor(lh / 18));
	local u = View.underline;
	local draws = {};
	local caretX = nil;
	local caretIndex = nil;

	-- everything worked out before the stencil: an error cannot leave it open
	for k = 0, count - 1
	do
		local draw = self:rowDraw(top + k + 1);

		if draw == nil
		then
			break;
		end

		draws[k + 1] = draw;
	end

	if cursor
	then
		-- worked out again only when the cursor or the rows change
		if self.caretCursor ~= cursor or self.caretGeneration ~= self.generation
		then
			local index = self:rowOfOffset(cursor);

			self.caretCursor = cursor;
			self.caretGeneration = self.generation;
			self.caretIndex = nil;

			if self.rows[index]
			then
				-- UITextBox2.render: n = min(offset - row start, row length); x = getWidth(row, 0, n - 1, true), less 1
				local row, x = self:offsetPlace(cursor);

				self.caretIndex = row;
				self.caretX = x;

				if self.caretX > 0
				then
					self.caretX = self.caretX - 1;
				end
			end
		end

		if self.caretIndex and self.caretIndex > top and self.caretIndex <= top + count
		then
			caretIndex = self.caretIndex;
			caretX = self.caretX;
		end
	end

	entry:setStencilRect(inset, inset, width - 2 * inset, height - 2 * inset);

	for k, draw in ipairs(draws)
	do
		local line = self.rows[top + k].line;
		local c = nil;

		if runningLine and line == runningLine
		then
			c = View.runningRow;
		elseif self.errorLines[line]
		then
			c = View.errorRow;
		end

		if c
		then
			entry:drawRect(inset - 1, inset + (top + k - 1) * lh, width - 2 * inset + 2, lh, c.a, c.r, c.g, c.b);
		end
	end

	for k, draw in ipairs(draws)
	do
		local y = inset + (top + k - 1) * lh;

		for i, layer in ipairs(draw.layers)
		do
			local c = layer.color;

			entry:drawText(layer.text, inset, y, c.r, c.g, c.b, 1, font);
		end

		for i, line in ipairs(draw.underlines)
		do
			local c = line.warn and View.warnUnderline or u;

			entry:drawRect(inset + line.x, y + lh - thick - 1, line.w, thick, 1, c.r, c.g, c.b);
		end
	end

	if caretX
	then
		local c = View.caret;

		entry:drawRect(inset + caretX, inset + (caretIndex - 1) * lh, 1, lh, c.a, c.r, c.g, c.b);
	end

	entry:clearStencilRect();
	entry:repaintStencilRect(inset, inset, width - 2 * inset, height - 2 * inset);
end
