-- AutoPilot (Moon): automations for the Moon server.

-- The macro editor's smart keys on the game's text box (19/11/2026, MACRO-AUTOPILOT.md 4.13, EDITOR-ANALISI.md): the
-- rules are MacroEditorKeys.lua (pure); this file watches the box and applies them. Option "Macro: rientro
-- automatico" (macroAutoIndent, on by default); off: every key is the box's own, nothing is rewritten.
--
-- How the keys reach it (read in the 42.22 jar, EDITOR-ANALISI.md 2.1):
--   * a character, Backspace, Delete, Ctrl+V: the box changes the text, then calls onTextChange (its last statement):
--     onTyped, right then, compares with the text seen before and rewrites it (the closing pair, else / elif to their
--     if, Backspace back to the previous level, a paste's tabs and line ends);
--   * Enter (also Ctrl+Enter), Ctrl+X: the box changes the text and tells nobody: poll, every frame from the window's
--     update and from its prerender (before the box draws), sees "\n" written at the cursor and rewrites it with the
--     indentation; with Ctrl down the "\n" goes back and the macro is checked ("Compila");
--   * Tab and Shift+Tab: onOtherKey(15) (the suggestions take it first while their list is open);
--   * Ctrl+Z, Ctrl+Y, Ctrl+D, Ctrl+/ (and Ctrl+Shift+7, the "/" of the Italian keyboard): nothing reaches the box (no
--     character under 32 comes from GLFW): poll reads the keys held with org.lwjglx.input.Keyboard.isKeyDown (the
--     keyboard itself, also while typing), once per press; Ctrl with Alt (AltGr) is not Ctrl;
--   * Home: the box moves the cursor to the row's start and tells nobody: poll sees it with Home down and puts it on
--     the first character of the code (not with Shift: that would lose the selection).
-- Every text the editor sets itself (a macro shown, Inserisci, a suggestion, a version restored) goes through the
-- box's setText: wrapped on this one box, so it is never taken for a key. The history (the box has none) keeps the
-- text before each change; letters typed one after the other are one step.
-- The box never scrolls to its cursor (UITextBox2.update only snaps the scroll to the rows): after a change or a move
-- of the cursor, its row is brought into view (also with the option off: it is the box's fault, it eats no key).
-- Cost: every frame only the box's string (the same object while nothing changes) and cursor compared, two
-- Keyboard.isKeyDown for Ctrl; the rest only when something changed.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.EditorInput = AutoPilotMoon.Macro.EditorInput or {};

local I = AutoPilotMoon.Macro.EditorInput;

local KEY_TAB = 15;
local KEY_LSHIFT = 42;
local KEY_RSHIFT = 54;
local KEY_LCONTROL = 29;
local KEY_RCONTROL = 157;
local KEY_LMENU = 56;
local KEY_RMENU = 184;
local KEY_HOME = 199;
local KEY_Z = 44;
local KEY_Y = 21;
local KEY_D = 32;
local KEY_SLASH = 53;
local KEY_7 = 8;

local function K()
	return AutoPilotMoon.Macro.EditorKeys;
end

local function keyDown(code)
	local keyboard = rawget(_G, "Keyboard");

	return keyboard ~= nil and keyboard.isKeyDown ~= nil and keyboard.isKeyDown(code) == true;
end

function AutoPilotMoon.Macro.EditorInput.shiftDown()
	return keyDown(KEY_LSHIFT) or keyDown(KEY_RSHIFT);
end

-- Ctrl without Alt (AltGr is Ctrl+Alt on Windows: the Italian "#" is AltGr+a-grave)
function AutoPilotMoon.Macro.EditorInput.ctrlDown()
	return (keyDown(KEY_LCONTROL) or keyDown(KEY_RCONTROL)) and not (keyDown(KEY_LMENU) or keyDown(KEY_RMENU));
end

function AutoPilotMoon.Macro.EditorInput.isOn()
	return AutoPilotMoon.Options:get("macroAutoIndent") ~= false;
end

-- ============================================================================================================
-- The controller (one per editor window)
-- ============================================================================================================

local C = {};
local CMeta = { __index = C };

I.ControllerMethods = C;

function AutoPilotMoon.Macro.EditorInput:attach(window)
	local o = { window = window, history = K().newHistory(), latched = {} };

	setmetatable(o, CMeta);

	-- the editor's own texts (a macro shown, an insertion, a suggestion): the box's setText, on this box only
	local entry = window.entry;
	local setText = entry.setText;

	entry.setText = function(box, text)
		setText(box, text);
		o:onSetText();
	end

	return o;
end

-- the box has the keyboard and can be written
function C:typing()
	local w = self.window;
	local entry = w.entry;

	return w:getIsVisible() and not w.isCollapsed and w.editable == true and entry ~= nil and entry:isFocused() == true;
end

function C:enabled()
	return I.isOn() and self:typing();
end

-- the box's text as it is now (getText is the one of its last update: EDITOR-ANALISI.md 2.1)
function C:read()
	local java = self.window.entry.javaObject;

	return java:getInternalText() or "", java:getCursorPos();
end

function C:maxLength()
	local java = self.window.entry.javaObject;

	return java.getMaxTextLength and java:getMaxTextLength() or nil;
end

-- another macro shown: its own history
function C:own()
	local selected = self.window.selected;

	if selected ~= self.owner
	then
		self.owner = selected;
		self.history:clear();
		self.text = nil;
		self.caret = nil;
	end
end

-- a text written by the window itself: the history keeps the one before; the cursor is set by the caller next
function C:onSetText()
	if self.applying
	then
		return;
	end

	if not I.isOn()
	then
		self.text = nil;

		return;
	end

	self:own();

	local text = self:read();

	if self.text ~= nil and text ~= self.text
	then
		local mark = self.mark;

		-- the change just seen taken back (the suggestions take back the space of Ctrl+Space): its step goes too
		if mark and text == mark.before
		then
			while #self.history.undos > mark.count
			do
				table.remove(self.history.undos);
			end
		else
			self.history:record(self.text, self.caret or string.len(self.text), "edit", getTimestampMs());
		end
	end

	self.mark = nil;
	self.text = text;
	self.caret = nil;
	self.scrollWanted = true;
end

-- the text and the cursor written by a rule (or Ctrl+Z): the window's own replacement (the cursor, the scroll, the
-- status bar, the check later)
function C:apply(text, caret)
	self.applying = true;
	self.window:replaceText(text, caret, false);
	self.applying = false;
	self.text, self.caret = text, caret;
	self.scrollWanted = true;
end

-- a change of the box seen (old -> text): the history, then the rule. Returns what was typed when it rewrote it
function C:react(text, caret, now)
	local old, oldCaret = self.text, self.caret;

	self.text, self.caret = text, caret;
	self.scrollWanted = true;

	if old == nil or old == text
	then
		return nil;
	end

	local result, at, kind, typed = K().react(old, oldCaret, text, caret, { maxLength = self:maxLength() });

	self.mark = { before = old, count = #self.history.undos };
	self.history:record(old, oldCaret or string.len(old), kind, now);

	if result
	then
		self:apply(result, at);

		return kind, typed;
	end

	return nil;
end

-- The box's onTextChange (a character, Backspace, Delete, a paste), before the suggestions. Returns, when a rule
-- rewrote the text after a character typed, the text and cursor the suggestions should take as "before" (the text
-- now without that character): they then see that one character typed, as without the rule.
function C:onTyped()
	if not self:enabled()
	then
		self.text = nil;

		return nil;
	end

	self:own();

	local text, caret = self:read();
	local kind, typed = self:react(text, caret, getTimestampMs());

	if kind == "type" and typed
	then
		local t, c = self.text, self.caret;

		if c >= 1 and string.sub(t, c, c) == typed
		then
			return string.sub(t, 1, c - 1) .. string.sub(t, c + 1), c - 1;
		end
	end

	return nil;
end

-- a change the box did not tell (Enter, Ctrl+X): Ctrl+Enter = Compila
function C:catchUp(text, caret)
	local old, oldCaret = self.text, self.caret;
	local d = K().diff(old, text, caret, oldCaret);

	if d and d.inserted == "\n" and d.removed == "" and I.ctrlDown()
	then
		local back = oldCaret or (caret - 1);

		self.applying = true;
		self.window:replaceText(old, back, true);
		self.applying = false;
		self.text, self.caret = old, back;
		self.window:onCheck();

		return;
	end

	self:react(text, caret, getTimestampMs());
end

-- Every frame (the window's update, and its prerender: inPrerender, before the box draws): the changes the box did
-- not tell, Home, the Ctrl keys, the cursor's row in view
function C:poll(inPrerender)
	if not self:typing()
	then
		self.text = nil;
		self:unlatch();

		return;
	end

	if I.isOn()
	then
		self:own();

		local text, caret = self:read();

		if self.text == nil
		then
			self.text, self.caret = text, caret;
		elseif text ~= self.text
		then
			self:catchUp(text, caret);
		elseif caret ~= self.caret
		then
			local old = self.caret;

			self.caret = caret;
			self.scrollWanted = true;

			if old ~= nil and keyDown(KEY_HOME) and not I.shiftDown()
			then
				local first = K().home(text, old, caret);

				if first
				then
					self.window:setCaret(first);
					self.caret = first;
				end
			end
		end

		self:shortcuts();
	else
		local caret = self.window.entry.javaObject:getCursorPos();
		local text = self.window.entry.javaObject:getInternalText();

		if caret ~= self.lastCaret or text ~= self.lastText
		then
			self.lastCaret, self.lastText = caret, text;
			self.scrollWanted = true;
		end
	end

	if inPrerender and self.scrollWanted
	then
		self:keepCaretVisible();
	end
end

-- the cursor's row in view, on the rows the box draws (its drawn text equal to the text: after its update)
function C:keepCaretVisible()
	local w = self.window;
	local entry = w.entry;
	local java = entry.javaObject;

	if entry:getText() ~= java:getInternalText()
	then
		return;
	end

	self.scrollWanted = false;
	w:syncView();
	w:scrollToCaret(java:getCursorPos());
end

-- the keys held let go: a new table only when one was held (poll runs twice a frame: no table made every frame)
function C:unlatch()
	if self.anyLatched
	then
		self.latched = {};
		self.anyLatched = false;
	end
end

-- the Ctrl keys, once per press
function C:shortcuts()
	if not I.ctrlDown()
	then
		self:unlatch();

		return;
	end

	local shift = I.shiftDown();

	self:shortcut(KEY_Z, shift and C.redo or C.undo);
	self:shortcut(KEY_Y, C.redo);
	self:shortcut(KEY_D, function(c) c:command(K().duplicateLine); end);
	self:shortcut(KEY_SLASH, function(c) c:command(K().toggleComment); end);

	if shift
	then
		self:shortcut(KEY_7, function(c) c:command(K().toggleComment); end);
	end
end

function C:shortcut(code, fn)
	if keyDown(code)
	then
		if not self.latched[code]
		then
			self.latched[code] = true;
			self.anyLatched = true;
			fn(self);
		end
	else
		self.latched[code] = nil;
	end
end

-- the box's text with every change seen (a key between two looks)
function C:current()
	local text, caret = self:read();

	if self.text ~= nil and text ~= self.text
	then
		self:catchUp(text, caret);
		text, caret = self:read();
	end

	return text, caret;
end

-- a rule of the whole line (Tab, Shift+Tab, Ctrl+D, Ctrl+/): one step of the history
function C:command(fn)
	local text, caret = self:current();
	local result, at = fn(text, caret);
	local max = self:maxLength();

	if result == nil or (max and string.len(result) > max)
	then
		return false;
	end

	self.history:record(text, caret, "edit", getTimestampMs());
	self:apply(result, at);

	return true;
end

function C:undo()
	local text, caret = self:current();
	local t, c = self.history:undo(text, caret);

	if t
	then
		self:apply(t, math.min(c or string.len(t), string.len(t)));
	end
end

function C:redo()
	local text, caret = self:current();
	local t, c = self.history:redo(text, caret);

	if t
	then
		self:apply(t, math.min(c or string.len(t), string.len(t)));
	end
end

-- Tab and Shift+Tab (the box's onOtherKey, when the suggestions did not take it); true when used
function C:onKey(key)
	if key ~= KEY_TAB or not self:enabled()
	then
		return false;
	end

	self:own();

	return self:command(I.shiftDown() and K().dedent or K().tab);
end
