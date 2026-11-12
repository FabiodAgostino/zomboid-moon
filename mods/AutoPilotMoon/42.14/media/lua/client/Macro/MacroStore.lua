-- AutoPilot (Moon): automations for the Moon server.

-- Where the macros live (spec MACRO-AUTOPILOT.md 6): one file for every macro of this PC, Zomboid/Lua/
-- autopilot_moon_macros.txt (getFileWriter / getFileReader of 42.22: Zomboid/Lua/, UTF-8 both ways, extension txt).
-- Data of the client, never Lua: nothing the server's checksum looks at. Format, by lines:
--
--   # AutoPilot (Moon) - macro - formato 2
--   === macro: Manutenzione - martelli
--   === usata: 3
--   <the macro's lines>
--   === prima: Manutenzione - martelli
--   <the previous version's lines>
--
-- A line of a macro that starts with "===" (an error the check reports) is written with a space in front, so it never
-- breaks the file. Safe writing: the file as it was is first copied to autopilot_moon_macros_backup.txt; a main file
-- missing, empty or without the header is read from the backup, said once. Read once (the first time the editor, the
-- menu or a run needs it), then kept in memory; written whole, never more than once every Store.minSaveMs except when
-- forced (closing the editor, renaming, duplicating, deleting, a recording saved).
-- The examples (6.2) are not in the file: they come from the translations, read-only, in the player's language.
-- Format 1 (the first language, 11/11/2026): read once, every macro (and its previous version) converted to the
-- language of today (AutoPilotMoon.Macro.Convert), the old file kept as autopilot_moon_macros_formato1.txt, said once;
-- a macro that cannot be converted is kept as comments with a note. The next save writes format 2.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Store = AutoPilotMoon.Macro.Store or {};

local Store = AutoPilotMoon.Macro.Store;

Store.fileName = "autopilot_moon_macros.txt";
Store.backupName = "autopilot_moon_macros_backup.txt";
Store.brokenName = "autopilot_moon_macros_broken.txt"; -- a main file that does not read, kept aside before a save
Store.bom = "\239\187\191";                            -- U+FEFF, put at the start by some text editors
Store.header = "# AutoPilot (Moon) - macro - formato 2";
Store.oldHeader = "# AutoPilot (Moon) - macro - formato 1";
Store.oldName = "autopilot_moon_macros_formato1.txt"; -- the file of format 1 as it was, before its conversion
Store.maxMacros = 50;
Store.maxNameChars = 40;
Store.minSaveMs = 2000;

Store.loaded = false;
Store.macros = {};        -- { name, text, used, previous }
Store.fileText = nil;     -- the main file as it is on disk (what the backup gets)
Store.lastSaveAt = nil;
Store.recovered = false;

-- the examples: name and text keys (the text's lines separated by " <LINE> " in the translations)
Store.examples = {
	{ nameKey = "IGUI_AutoPilot_MA_Ex1_Name", textKey = "IGUI_AutoPilot_MA_Ex1_Text" },
	{ nameKey = "IGUI_AutoPilot_MA_Ex2_Name", textKey = "IGUI_AutoPilot_MA_Ex2_Text" },
	{ nameKey = "IGUI_AutoPilot_MA_Ex3_Name", textKey = "IGUI_AutoPilot_MA_Ex3_Text" },
	{ nameKey = "IGUI_AutoPilot_MA_Ex4_Name", textKey = "IGUI_AutoPilot_MA_Ex4_Text" },
	{ nameKey = "IGUI_AutoPilot_MA_Ex5_Name", textKey = "IGUI_AutoPilot_MA_Ex5_Text" },
};

-- a text of the translations with " <LINE> " between its lines, as lines with "\n"
function AutoPilotMoon.Macro.Store:linesOf(text)
	text = string.gsub(text, " <LINE> ", "\n");

	return (string.gsub(text, "<LINE>", "\n"));
end

-- the examples in the player's language: { name, text, example = true }
function AutoPilotMoon.Macro.Store:getExamples()
	local list = {};

	for i, example in ipairs(Store.examples)
	do
		table.insert(list, { name = getText(example.nameKey), text = Store:linesOf(getText(example.textKey)), example = true });
	end

	return list;
end

-- every line of a text, the last one too (empty after a final newline): the file keeps the text exactly
local function allLines(text)
	local lines = {};
	local start = 1;

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

-- ============================================================================================================
-- The file
-- ============================================================================================================

local function readFile(name)
	local handle = getFileReader(name, false);

	if not handle
	then
		return nil;
	end

	local lines = {};

	while true
	do
		local line = handle:readLine();

		if line == nil
		then
			break;
		end

		table.insert(lines, line);
	end

	handle:close();

	return lines;
end

-- the macros of a file's lines, or nil when it is not ours (no header)
function AutoPilotMoon.Macro.Store:parseFile(lines)
	if lines == nil or #lines == 0
	then
		return nil;
	end

	-- the header without a BOM and the spaces around (a file saved by a text editor)
	local first = lines[1];

	if string.find(first, Store.bom, 1, true) == 1
	then
		first = string.sub(first, string.len(Store.bom) + 1);
	end

	local header = string.match(first, "^%s*(.-)%s*$");

	if header ~= Store.header and header ~= Store.oldHeader
	then
		return nil;
	end

	local macros = {};
	local current = nil;
	local target = nil;

	local function close()
		if current
		then
			current.text = table.concat(current.textLines, "\n");
			current.previous = current.previousLines and table.concat(current.previousLines, "\n") or nil;
			current.textLines = nil;
			current.previousLines = nil;
		end
	end

	for i = 2, #lines
	do
		local line = string.gsub(lines[i], "\r", "");
		local name = string.match(line, "^=== macro: (.*)$");
		local used = string.match(line, "^=== usata: (%d+)$");
		local previous = string.match(line, "^=== prima: ");

		if name
		then
			close();
			current = { name = name, used = 0, textLines = {} };
			target = current.textLines;
			table.insert(macros, current);
		elseif used and current
		then
			current.used = tonumber(used) or 0;
		elseif previous and current
		then
			current.previousLines = {};
			target = current.previousLines;
		elseif target
		then
			table.insert(target, line);
		end
	end

	close();

	return macros, header == Store.oldHeader and 1 or 2;
end

-- a macro's text in the language of today: an old one converted (false when it could not be, kept as comments)
function AutoPilotMoon.Macro.Store:convertText(text)
	if text == nil or not AutoPilotMoon.Macro.Convert:isOld(text)
	then
		return text, true;
	end

	return AutoPilotMoon.Macro.Convert:convert(text, Store:linesOf(getText("IGUI_AutoPilot_E_ConvertNote")));
end

-- the macros of format 1 converted; the old file kept aside, said once over the head
local function convertAll(macros, lines)
	local converted, failed = 0, 0;

	for i, macro in ipairs(macros)
	do
		local text, ok = Store:convertText(macro.text);

		if text ~= macro.text
		then
			if ok then converted = converted + 1; else failed = failed + 1; end
		end

		macro.text = text;
		macro.previous = macro.previous and Store:convertText(macro.previous) or nil;
	end

	local copy = getFileWriter(Store.oldName, true, false);

	if copy
	then
		copy:write(table.concat(lines, "\n") .. "\n");
		copy:close();
	end

	Store.converted = { converted = converted, failed = failed };
	AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroConverted", converted, Store.oldName), getPlayer());

	if failed > 0
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_A_MacroNotConverted", failed), getPlayer());
	end
end

-- the file's text for the macros
function AutoPilotMoon.Macro.Store:format(macros)
	local out = { Store.header };

	local function addText(text)
		for i, line in ipairs(allLines(text or ""))
		do
			-- only a line that the reading would take for a marker: a line already with the space stays as it is
			-- (one more space at every save otherwise)
			if string.find(line, "^===")
			then
				line = " " .. line;
			end

			table.insert(out, line);
		end
	end

	for i, macro in ipairs(macros)
	do
		table.insert(out, "=== macro: " .. macro.name);
		table.insert(out, "=== usata: " .. (macro.used or 0));
		addText(macro.text);

		if macro.previous
		then
			table.insert(out, "=== prima: " .. macro.name);
			addText(macro.previous);
		end
	end

	return table.concat(out, "\n") .. "\n";
end

-- reads the file once; the backup when the main file is not usable (said once over the head)
function AutoPilotMoon.Macro.Store:load()
	if Store.loaded
	then
		return;
	end

	Store.loaded = true;

	local lines = readFile(Store.fileName);
	local macros, format = Store:parseFile(lines);

	if macros
	then
		Store.fileText = table.concat(lines, "\n") .. "\n";

		if format == 1
		then
			convertAll(macros, lines);
			Store.macros = macros;
			Store:save(true);

			return;
		end
	else
		-- a file that is there but does not read (edited by hand?): kept aside, the next save writes over it
		if lines and string.find(table.concat(lines, "\n"), "%S")
		then
			local copy = getFileWriter(Store.brokenName, true, false);

			if copy
			then
				copy:write(table.concat(lines, "\n") .. "\n");
				copy:close();
				AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroFileUnreadable", Store.brokenName), getPlayer());
			end
		end

		local backupLines = readFile(Store.backupName);

		macros, format = Store:parseFile(backupLines);

		if macros and format == 1
		then
			convertAll(macros, backupLines);
		end

		if macros
		then
			Store.recovered = true;
			AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_A_MacroRecovered"), getPlayer());
		end
	end

	Store.macros = macros or {};
end

-- writes the whole file (the backup first with what was on disk); not more than once every Store.minSaveMs unless
-- forced. Returns true when written.
function AutoPilotMoon.Macro.Store:save(force)
	Store:load();

	local now = getTimestampMs();

	if not force and Store.lastSaveAt and now - Store.lastSaveAt < Store.minSaveMs
	then
		Store.pendingSave = true;

		return false;
	end

	local text = Store:format(Store.macros);

	if Store.fileText and Store.fileText ~= ""
	then
		local backup = getFileWriter(Store.backupName, true, false);

		if backup
		then
			backup:write(Store.fileText);
			backup:close();
		end
	end

	local file = getFileWriter(Store.fileName, true, false);

	if file == nil
	then
		return false;
	end

	file:write(text);
	file:close();
	Store.fileText = text;
	Store.lastSaveAt = now;
	Store.pendingSave = false;

	return true;
end

-- ============================================================================================================
-- The macros
-- ============================================================================================================

local function byUse(a, b)
	if (a.used or 0) ~= (b.used or 0)
	then
		return (a.used or 0) > (b.used or 0);
	end

	return string.lower(a.name) < string.lower(b.name);
end

-- the macros, the last used first
function AutoPilotMoon.Macro.Store:list()
	Store:load();

	local list = {};

	for i, macro in ipairs(Store.macros)
	do
		table.insert(list, macro);
	end

	table.sort(list, byUse);

	return list;
end

function AutoPilotMoon.Macro.Store:get(name)
	Store:load();

	if name == nil
	then
		return nil;
	end

	local lower = string.lower(name);

	for i, macro in ipairs(Store.macros)
	do
		if string.lower(macro.name) == lower
		then
			return macro;
		end
	end

	return nil;
end

-- a name a macro can have: 1-40 characters, one line, not "===...", not another macro's (current: its own old name)
function AutoPilotMoon.Macro.Store:isValidName(name, current)
	if name == nil
	then
		return false;
	end

	local trimmed = AutoPilotMoon.Macro.Lang.trim(name);

	if trimmed == "" or string.len(trimmed) > Store.maxNameChars or string.find(trimmed, "\n", 1, true)
		or string.find(trimmed, "^===")
	then
		return false;
	end

	local other = Store:get(trimmed);

	return other == nil or (current ~= nil and string.lower(other.name) == string.lower(current));
end

-- a free name from a wished one: "Nome", then "Nome (2)", "Nome (3)"... (cut to fit the 40 characters)
function AutoPilotMoon.Macro.Store:freeName(wanted)
	wanted = AutoPilotMoon.Macro.Lang.trim(wanted or "");

	if wanted == "" or string.find(wanted, "^===")
	then
		wanted = getText("IGUI_AutoPilot_E_PastedName");
	end

	wanted = string.sub(wanted, 1, Store.maxNameChars);

	if Store:get(wanted) == nil
	then
		return wanted;
	end

	for n = 2, 999
	do
		local suffix = " (" .. n .. ")";
		local name = string.sub(wanted, 1, Store.maxNameChars - string.len(suffix)) .. suffix;

		if Store:get(name) == nil
		then
			return name;
		end
	end

	return nil;
end

local function nextUse()
	local top = 0;

	for i, macro in ipairs(Store.macros)
	do
		top = math.max(top, macro.used or 0);
	end

	return top + 1;
end

-- the macro was used now: first in the lists
function AutoPilotMoon.Macro.Store:touch(macro)
	macro.used = nextUse();
end

-- a new macro (a free name is made from name); nil, "full" with 50 macros
function AutoPilotMoon.Macro.Store:add(name, text)
	Store:load();

	if #Store.macros >= Store.maxMacros
	then
		return nil, "full";
	end

	local macro = { name = Store:freeName(name), text = text or "", used = nextUse() };

	table.insert(Store.macros, macro);

	return macro;
end

-- the text changed; newVersion: the first change since the macro was opened, the text before it becomes "the
-- previous version" (4.8: protects from a Ctrl+A and a key)
function AutoPilotMoon.Macro.Store:setText(macro, text, newVersion)
	if macro.text == text
	then
		return false;
	end

	if newVersion
	then
		macro.previous = macro.text;
	end

	macro.text = text;

	return true;
end

-- back to the previous version; the current one becomes the previous (one can go back again)
function AutoPilotMoon.Macro.Store:restore(macro)
	if macro.previous == nil
	then
		return false;
	end

	local current = macro.text;

	macro.text = macro.previous;
	macro.previous = current;

	return true;
end

function AutoPilotMoon.Macro.Store:rename(macro, name)
	if not Store:isValidName(name, macro.name)
	then
		return false;
	end

	macro.name = AutoPilotMoon.Macro.Lang.trim(name);

	return true;
end

function AutoPilotMoon.Macro.Store:duplicate(macro)
	return Store:add(getText("IGUI_AutoPilot_E_CopyName", macro.name), macro.text);
end

function AutoPilotMoon.Macro.Store:delete(macro)
	for i = #Store.macros, 1, -1
	do
		if Store.macros[i] == macro
		then
			table.remove(Store.macros, i);

			return true;
		end
	end

	return false;
end

-- ============================================================================================================
-- Copy and paste (6.3)
-- ============================================================================================================

-- the clipboard's text of a macro: its name on the first line, so whoever pastes it gets the name too
function AutoPilotMoon.Macro.Store:clipboardText(name, text)
	return "=== macro: " .. name .. "\n" .. (text or "");
end

-- the macros of a pasted text: { name, text } (one or more "=== macro:"; without one, a single macro "Incollata");
-- the lines "=== usata" and the "=== prima" blocks are left out
function AutoPilotMoon.Macro.Store:parsePaste(text)
	local found = {};
	local current = nil;
	local skipping = false;

	for i, line in ipairs(allLines(string.gsub(text or "", "\r", "")))
	do
		local name = string.match(line, "^=== macro: (.*)$");

		if name
		then
			current = { name = AutoPilotMoon.Macro.Lang.trim(name), lines = {} };
			skipping = false;
			table.insert(found, current);
		elseif string.find(line, "^=== usata:")
		then
			-- the order of use of someone else's file
		elseif string.find(line, "^=== prima:")
		then
			skipping = true;
		elseif not skipping
		then
			if current == nil
			then
				current = { name = getText("IGUI_AutoPilot_E_PastedName"), lines = {} };
				table.insert(found, current);
			end

			table.insert(current.lines, line);
		end
	end

	local result = {};

	for i, macro in ipairs(found)
	do
		-- trailing empty lines of a paste are dropped
		while #macro.lines > 0 and AutoPilotMoon.Macro.Lang.trim(macro.lines[#macro.lines]) == ""
		do
			table.remove(macro.lines);
		end

		-- a macro of the first language pasted from Discord or an old file: converted as the file's are
		table.insert(result, { name = macro.name, text = (Store:convertText(table.concat(macro.lines, "\n"))) });
	end

	return result;
end

-- forget what is in memory (the tests)
function AutoPilotMoon.Macro.Store:forget()
	Store.loaded = false;
	Store.macros = {};
	Store.fileText = nil;
	Store.lastSaveAt = nil;
	Store.recovered = false;
	Store.pendingSave = false;
	Store.converted = nil;
end
