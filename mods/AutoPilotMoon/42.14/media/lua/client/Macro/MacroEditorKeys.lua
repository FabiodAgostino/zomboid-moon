-- AutoPilot (Moon): automations for the Moon server.

-- The macro editor's smart keys without the window (MACRO-AUTOPILOT.md 4.13, EDITOR-ANALISI.md): what Enter,
-- Backspace, Tab, Shift+Tab, the closing characters, a paste and the line commands do to the text. Pure: a text and a
-- cursor in, a text and a cursor out (nil: leave it as it is), so every rule is tested without any UI; the keys and
-- the box are MacroEditorInput.lua.
--
-- The game's text box (zombie.ui.UITextBox2 42.22) changes the text first and tells Lua after (a character,
-- Backspace, Delete, a paste: onTextChange) or never (Enter): every rule here takes the text AS THE BOX LEFT IT and
-- the cursor where the box put it, and says what it should be. K.diff tells what the box did from the text before and
-- the text after; K.react picks the rule. A change it cannot recognise for sure is left alone.
--
-- Positions are 0-based offsets in the whole text, as UITextBox2.getCursorPos (the cursor at offset c is after the
-- c-th character). Kahlua's strings are the game's: an accented letter or a typographic quote is one character, so
-- offsets are string positions. Columns of a line are characters; a tab counts 4 for the indentation (Lang.tabWidth).
-- The language (MACRO-AUTOPILOT.md 2): one statement per line, a block is the lines indented 4 more under a line
-- ending with ":", no line continues on the next one (Enter inside parentheses or quotes only keeps the indentation).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.EditorKeys = AutoPilotMoon.Macro.EditorKeys or {};

local K = AutoPilotMoon.Macro.EditorKeys;

K.unit = 4;            -- one level (Lang.indent)
K.replayMax = 3;       -- characters typed between two looks (a fast Enter and a letter in one frame) played one by one
K.mergeMs = 1500;      -- typing within this time is one step of the history
K.historyMax = 100;

local len = string.len;
local sub = string.sub;

local function Lang()
	return AutoPilotMoon.Macro.Lang;
end

local function spaces(n)
	return string.rep(" ", math.max(0, n));
end

-- ============================================================================================================
-- Lines
-- ============================================================================================================

-- the 1-based index of the first character of the line that holds the character at index i (i = 0: the first line)
local function lineStartAt(text, i)
	while i >= 1 and sub(text, i, i) ~= "\n"
	do
		i = i - 1;
	end

	return i + 1;
end

-- the 1-based index of the "\n" that ends the line holding index from (or the text's length + 1)
local function lineEndAt(text, from)
	return string.find(text, "\n", from, true) or (len(text) + 1);
end

-- the line of the cursor: its first character's index, the index after its last character, the line itself
function AutoPilotMoon.Macro.EditorKeys.lineAt(text, caret)
	local s = lineStartAt(text, caret);
	local e = lineEndAt(text, s);

	return s, e, sub(text, s, e - 1);
end

-- the indentation of a line in columns (a tab counts 4: Lang.tabWidth)
local function indentWidth(line)
	local width = 0;

	for i = 1, len(line)
	do
		local c = sub(line, i, i);

		if c == " "
		then
			width = width + 1;
		elseif c == "\t"
		then
			width = width + K.unit;
		else
			return width;
		end
	end

	return width;
end

K.indentWidth = indentWidth;

local function leading(line)
	return string.match(line, "^[ \t]*") or "";
end

local function isBlank(line)
	return string.find(line, "[^ \t\r]") == nil;
end

-- the code of a line without its comment, trimmed (the language's own reader: a "#" in quotes is text)
local function codeOf(line)
	local code = Lang().stripComment(Lang().plainLine(line));

	return Lang().trim(code);
end

K.codeOf = codeOf;

-- the line read up to (and with) its character upto: the quote still open ("\"" or "'", the typographic ones as
-- these), whether a comment started, how many parentheses are open (outside the texts)
local function scan(line, upto)
	local plain = Lang().plainLine(line);
	local quote = nil;
	local depth = 0;

	for i = 1, math.min(upto, len(plain))
	do
		local c = sub(plain, i, i);

		if quote
		then
			if c == quote
			then
				quote = nil;
			end
		elseif c == "\"" or c == "'"
		then
			quote = c;
		elseif c == "#"
		then
			return { comment = true, depth = depth };
		elseif c == "("
		then
			depth = depth + 1;
		elseif c == ")"
		then
			depth = depth - 1;
		end
	end

	return { quote = quote, depth = depth };
end

K.scan = scan;

-- a line after which nothing of its block is done: one level less on the next line (Python's IDLE and editors do it
-- after return, raise, pass, break, continue; here break, pass and stop())
local function closesBlock(code)
	local lower = string.lower(code);

	return lower == "break" or lower == "pass" or string.match(lower, "^stop%s*%(%s*%)$") ~= nil;
end

-- the indentation of the block a line at width belongs to: the nearest line above (before index s) less indented
-- and ending with ":" (works with any consistent indentation); none: one level less
local function blockIndent(text, s, width)
	local at = s;

	while at > 1
	do
		local stop = at - 1;
		local start = lineStartAt(text, stop - 1);
		local line = sub(text, start, stop - 1);
		local code = codeOf(line);

		if code ~= ""
		then
			local indent = indentWidth(line);

			if indent < width and sub(code, -1) == ":"
			then
				return indent;
			end
		end

		at = start;
	end

	return math.max(0, width - K.unit);
end

-- ============================================================================================================
-- Enter
-- ============================================================================================================

-- The box wrote "\n" just before the cursor (text: the text with it). The new line starts at the indentation of the
-- line above, one level more after a line ending with ":", one less after break / pass / stop(); the rest of the line
-- (Enter in the middle) comes with it without its own spaces; the spaces left at the end of the line above go. Enter
-- in the indentation or on a blank line: an empty line above and the line as it was (its spaces kept: pressing Enter
-- twice leaves no spaces behind). Inside quotes the text is not touched (only the indentation).
function AutoPilotMoon.Macro.EditorKeys.afterEnter(text, caret)
	if caret == nil or caret < 1 or sub(text, caret, caret) ~= "\n"
	then
		return nil;
	end

	local s = lineStartAt(text, caret - 1);
	local left = sub(text, s, caret - 1);
	local e = lineEndAt(text, caret + 1);
	local right = sub(text, caret + 1, e - 1);
	local newLeft, newRight, column;

	if isBlank(left)
	then
		newLeft = "";
		newRight = left .. right;
		column = len(left);
	else
		local base = indentWidth(left);
		local state = scan(left, len(left));
		local indent = base;

		if state.quote
		then
			newLeft = left;
			newRight = right;
		else
			local code = codeOf(left);

			if sub(code, -1) == ":"
			then
				indent = base + K.unit;
			elseif closesBlock(code)
			then
				indent = blockIndent(text, s, base);
			end

			newLeft = (string.gsub(left, "[ \t]+$", ""));
			newRight = (string.gsub(right, "^[ \t]+", ""));
		end

		newRight = spaces(indent) .. newRight;
		column = indent;
	end

	local result = sub(text, 1, s - 1) .. newLeft .. "\n" .. newRight .. sub(text, e);
	local at = (s - 1) + len(newLeft) + 1 + column;

	if result == text and at == caret
	then
		return nil;
	end

	return result, at;
end

-- ============================================================================================================
-- A character typed
-- ============================================================================================================

-- the characters before which an opening bracket or quote is closed (as VS Code: a space, the end of the line, or a
-- closing / separating character)
local function closesBefore(c)
	return c == "" or c == " " or c == "\t" or c == ")" or c == "," or c == ":";
end

-- "else:" / "elif ...:" just completed: the line moves left to the "if" or "elif" it belongs to (the nearest one
-- above at most as indented, not hidden by a line less indented, not already closed by an "else" at its indentation)
local function matchIf(text, s, width)
	local minSeen = width;
	local blocked = {};
	local at = s;

	while at > 1
	do
		local stop = at - 1;
		local start = lineStartAt(text, stop - 1);
		local line = sub(text, start, stop - 1);
		local code = string.lower(codeOf(line));

		if code ~= ""
		then
			local indent = indentWidth(line);

			if indent <= minSeen
			then
				local word = string.match(code, "^([%a_]+)");

				if (word == "if" or word == "elif") and sub(code, -1) == ":" and not blocked[indent]
				then
					return indent;
				end

				if word == "else"
				then
					blocked[indent] = true;
				end

				minSeen = indent;
			end

			if minSeen == 0 and indent == 0
			then
				return nil;
			end
		end

		at = start;
	end

	return nil;
end

local function electric(text, caret, s, e, line, column)
	local code = string.lower(codeOf(line));

	if not (string.match(code, "^else%s*:$") or string.match(code, "^elif[%s%(].*:$"))
	then
		return nil;
	end

	-- the ":" typed ends the code (only spaces or a comment after it)
	if codeOf(sub(line, column + 1)) ~= ""
	then
		return nil;
	end

	local width = indentWidth(line);
	local target = matchIf(text, s, width);

	if target == nil or target >= width
	then
		return nil;
	end

	local lead = len(leading(line));
	local newLine = spaces(target) .. sub(line, lead + 1);

	return sub(text, 1, s - 1) .. newLine .. sub(text, e), caret - lead + target;
end

-- The box wrote the character ch just before the cursor (text: the text with it): the closing ")" or "\"" added after
-- an opening one, typed over when it is already there, "else:" / "elif ...:" moved to their "if". Never in a comment;
-- a quote only closes a text it opened, never after a letter (don"t), and only before a space, the end of the line or
-- ")" "," ":".
function AutoPilotMoon.Macro.EditorKeys.afterType(text, caret, ch)
	if caret == nil or caret < 1 or sub(text, caret, caret) ~= ch
	then
		return nil;
	end

	local s = lineStartAt(text, caret);
	local e = lineEndAt(text, s);
	local line = sub(text, s, e - 1);
	local column = caret - s + 1;
	local before = scan(line, column - 1);

	if before.comment
	then
		return nil;
	end

	local nextChar = sub(line, column + 1, column + 1);
	local prevChar = sub(line, column - 1, column - 1);

	if ch == ":" and not before.quote
	then
		return electric(text, caret, s, e, line, column);
	elseif ch == "(" and not before.quote
	then
		if closesBefore(nextChar)
		then
			return sub(text, 1, caret) .. ")" .. sub(text, caret + 1), caret;
		end
	elseif ch == ")" and not before.quote
	then
		-- typed over the ")" after it, when the line has one ")" too many
		if nextChar == ")" and scan(line, len(line)).depth < 0
		then
			return sub(text, 1, caret) .. sub(text, caret + 2), caret;
		end
	elseif ch == "\""
	then
		if before.quote == "\""
		then
			-- it closes the text it is in: typed over the quote after it
			if nextChar == "\""
			then
				return sub(text, 1, caret) .. sub(text, caret + 2), caret;
			end
		elseif before.quote == nil and closesBefore(nextChar) and not Lang().isNameChar(prevChar == "" and " " or prevChar)
			and prevChar ~= "\"" and prevChar ~= "'"
		then
			return sub(text, 1, caret) .. "\"" .. sub(text, caret + 1), caret;
		end
	end

	return nil;
end

-- ============================================================================================================
-- Backspace
-- ============================================================================================================

-- The box deleted the character removed just before the cursor (text: the text without it). In the indentation the
-- line goes back to the previous level (a multiple of 4) instead of one space; between "(" and ")" or two quotes the
-- pair goes together.
function AutoPilotMoon.Macro.EditorKeys.afterBackspace(text, caret, removed)
	if caret == nil or caret < 0
	then
		return nil;
	end

	local nextChar = sub(text, caret + 1, caret + 1);

	if removed == " "
	then
		local s = lineStartAt(text, caret);
		local before = sub(text, s, caret);

		if before ~= "" and string.find(before, "[^ ]") == nil
		then
			-- one space taken: the cursor was at column width + 1, the previous level is the multiple of 4 below it
			local width = len(before);
			local target = math.floor(width / K.unit) * K.unit;
			local extra = width - target;

			if extra > 0
			then
				return sub(text, 1, caret - extra) .. sub(text, caret + 1), caret - extra;
			end
		end
	elseif removed == "(" and nextChar == ")"
	then
		return sub(text, 1, caret) .. sub(text, caret + 2), caret;
	elseif removed == "\"" and nextChar == "\""
	then
		local s = lineStartAt(text, caret);

		-- the quote taken opened a text (nothing open before it)
		if scan(sub(text, s, caret), caret - s + 1).quote == nil
		then
			return sub(text, 1, caret) .. sub(text, caret + 2), caret;
		end
	end

	return nil;
end

-- ============================================================================================================
-- Tab, Shift+Tab, the line commands
-- ============================================================================================================

-- Tab: spaces up to the next level
function AutoPilotMoon.Macro.EditorKeys.tab(text, caret)
	local s = lineStartAt(text, caret);
	local column = caret - (s - 1);
	local n = K.unit - column % K.unit;

	return sub(text, 1, caret) .. spaces(n) .. sub(text, caret + 1), caret + n;
end

-- Shift+Tab: the cursor's line one level to the left (a tab at its start counts one level); the cursor stays on
-- the same character
function AutoPilotMoon.Macro.EditorKeys.dedent(text, caret)
	local s, e, line = K.lineAt(text, caret);
	local count = len(string.match(line, "^ *") or "");
	local remove = 0;

	if count == 0 and sub(line, 1, 1) == "\t"
	then
		remove = 1;
	elseif count > 0
	then
		remove = count % K.unit;

		if remove == 0
		then
			remove = K.unit;
		end
	end

	if remove == 0
	then
		return nil;
	end

	local column = caret - (s - 1);

	column = math.max(0, column - remove);

	return sub(text, 1, s - 1) .. sub(line, remove + 1) .. sub(text, e), (s - 1) + column;
end

-- Ctrl+/: a "#" at the start of the line's code (after its indentation), or taken away with the space after it
function AutoPilotMoon.Macro.EditorKeys.toggleComment(text, caret)
	local s, e, line = K.lineAt(text, caret);
	local lead = leading(line);
	local rest = sub(line, len(lead) + 1);
	local column = caret - (s - 1);
	local newLine;

	if sub(rest, 1, 1) == "#"
	then
		local k = sub(rest, 2, 2) == " " and 2 or 1;

		newLine = lead .. sub(rest, k + 1);

		if column > len(lead)
		then
			column = math.max(len(lead), column - k);
		end
	else
		newLine = lead .. "# " .. rest;

		if column >= len(lead)
		then
			column = column + 2;
		end
	end

	return sub(text, 1, s - 1) .. newLine .. sub(text, e), (s - 1) + column;
end

-- Ctrl+D: a copy of the cursor's line under it, the cursor on the copy at the same column
function AutoPilotMoon.Macro.EditorKeys.duplicateLine(text, caret)
	local s, e, line = K.lineAt(text, caret);

	return sub(text, 1, e - 1) .. "\n" .. line .. sub(text, e), caret + len(line) + 1;
end

-- Home: the box put the cursor at the start of its row (oldCaret: where it was). On the first row of an indented line
-- the cursor goes to the first character of the code instead; from there Home goes on to column 0 (as VS Code)
function AutoPilotMoon.Macro.EditorKeys.home(text, oldCaret, newCaret)
	if newCaret == nil or oldCaret == nil or newCaret == oldCaret
	then
		return nil;
	end

	local s, e, line = K.lineAt(text, newCaret);

	-- a row of a long line wrapped by the box (not the line's start): as the box does
	if newCaret ~= s - 1 or isBlank(line)
	then
		return nil;
	end

	local first = (s - 1) + len(leading(line));

	if first == newCaret or oldCaret == first or oldCaret < s - 1 or oldCaret > e - 1
	then
		return nil;
	end

	return first;
end

-- a pasted text: Windows' and old Mac's line ends as "\n", a tab as 4 spaces (the editor writes spaces; the checker
-- reads a tab as 4 all the same)
function AutoPilotMoon.Macro.EditorKeys.normalizePaste(s)
	s = string.gsub(s, "\r\n", "\n");
	s = string.gsub(s, "\r", "\n");
	s = string.gsub(s, "\t", spaces(K.unit));

	return s;
end

-- ============================================================================================================
-- What the box did, what to do
-- ============================================================================================================

-- The change from old to new where the cursor ended at caret (hint: where it was): { at = offset where the change
-- starts, removed = the characters taken away, inserted = those written }. The text after the cursor is the same in
-- both (the box always leaves the cursor after what it wrote); nil when it is not (a change that is not a key's).
function AutoPilotMoon.Macro.EditorKeys.diff(old, new, caret, hint)
	if old == nil or new == nil or caret == nil
	then
		return nil;
	end

	local lo, ln = len(old), len(new);

	if caret < 0 or caret > ln
	then
		return nil;
	end

	local tail = ln - caret;

	if tail > lo or (tail > 0 and sub(new, caret + 1) ~= sub(old, lo - tail + 1))
	then
		return nil;
	end

	local oldHead = lo - tail;
	local m = math.min(oldHead, caret);
	local p = nil;

	-- the common start: from the old cursor (one comparison, then a few characters), else halving
	if hint and hint >= 0
	then
		local k = math.min(hint, m);

		if sub(old, 1, k) == sub(new, 1, k)
		then
			p = k;

			while p < m and sub(old, p + 1, p + 1) == sub(new, p + 1, p + 1)
			do
				p = p + 1;
			end
		end
	end

	if p == nil
	then
		local low, high = 0, m;

		while low < high
		do
			local mid = math.ceil((low + high) / 2);

			if sub(old, 1, mid) == sub(new, 1, mid)
			then
				low = mid;
			else
				high = mid - 1;
			end
		end

		p = low;
	end

	return { at = p, removed = sub(old, p + 1, oldHead), inserted = sub(new, p + 1, caret) };
end

-- What the box did (from the text and cursor before to those after) and the text it should be:
-- returns newText, newCaret (nil: leave it), kind ("type", "delete", "enter", "edit": for the history), typed (the one
-- character typed, for the suggestions). opts.maxLength: a result longer is given up (the box would cut it).
function AutoPilotMoon.Macro.EditorKeys.react(old, oldCaret, new, newCaret, opts)
	opts = opts or {};

	local d = K.diff(old, new, newCaret, oldCaret);

	if d == nil
	then
		return nil, nil, "edit", nil;
	end

	local ins, rem = d.inserted, d.removed;
	local result, caret, kind, typed = nil, nil, "edit", nil;

	if ins == "" and len(rem) == 1
	then
		kind = "delete";

		-- Backspace (the cursor moved back by it); Delete leaves the cursor where it was
		if oldCaret == newCaret + 1
		then
			result, caret = K.afterBackspace(new, newCaret, rem);
		end
	elseif string.find(ins, "[\r\t]")
	then
		-- a paste (the box writes the clipboard as it is)
		local clean = K.normalizePaste(ins);

		result = sub(new, 1, d.at) .. clean .. sub(new, newCaret + 1);
		caret = d.at + len(clean);
	elseif ins == "\n"
	then
		kind = "enter";
		result, caret = K.afterEnter(new, newCaret);
	elseif len(ins) == 1
	then
		kind = "type";
		typed = ins;

		if rem == ""
		then
			result, caret = K.afterType(new, newCaret, ins);
		end
	elseif rem == "" and len(ins) <= K.replayMax and ins ~= ""
	then
		-- a few keys between two looks: one by one
		kind = "type";

		local t, c = sub(new, 1, d.at) .. sub(new, newCaret + 1), d.at;

		for i = 1, len(ins)
		do
			local ch = sub(ins, i, i);
			local t2, c2;

			t = sub(t, 1, c) .. ch .. sub(t, c + 1);
			c = c + 1;

			if ch == "\n"
			then
				t2, c2 = K.afterEnter(t, c);
			else
				t2, c2 = K.afterType(t, c, ch);
			end

			if t2
			then
				t, c = t2, c2;
			end
		end

		result, caret = t, c;
	end

	if result and opts.maxLength and len(result) > opts.maxLength
	then
		result, caret = nil, nil;
	end

	if result == new and caret == newCaret
	then
		result, caret = nil, nil;
	end

	return result, caret, kind, typed;
end

-- ============================================================================================================
-- The history (Ctrl+Z / Ctrl+Y): the box has none (EDITOR-ANALISI.md 2.4)
-- ============================================================================================================

local H = {};
local HMeta = { __index = H };

K.HistoryMethods = H;

function AutoPilotMoon.Macro.EditorKeys.newHistory(max)
	local o = { undos = {}, redos = {}, max = max or K.historyMax };

	setmetatable(o, HMeta);

	return o;
end

-- a change seen: text, caret = the state BEFORE it; letters typed (or deleted) one after the other within
-- K.mergeMs are one step
function H:record(text, caret, kind, now)
	local merge = (kind == "type" or kind == "delete") and kind == self.lastKind and now ~= nil and self.lastAt ~= nil
		and now - self.lastAt <= K.mergeMs and #self.undos > 0;

	if not merge
	then
		table.insert(self.undos, { text = text, caret = caret });

		if #self.undos > self.max
		then
			table.remove(self.undos, 1);
		end
	end

	self.redos = {};
	self.lastKind = kind;
	self.lastAt = now;
end

-- the state before the last step (text, caret: the state now, kept for Ctrl+Y); nil when there is none
function H:undo(text, caret)
	local entry = table.remove(self.undos);

	if entry == nil
	then
		return nil;
	end

	table.insert(self.redos, { text = text, caret = caret });
	self.lastKind = nil;

	return entry.text, entry.caret;
end

function H:redo(text, caret)
	local entry = table.remove(self.redos);

	if entry == nil
	then
		return nil;
	end

	table.insert(self.undos, { text = text, caret = caret });
	self.lastKind = nil;

	return entry.text, entry.caret;
end

function H:clear()
	self.undos = {};
	self.redos = {};
	self.lastKind = nil;
	self.lastAt = nil;
end
