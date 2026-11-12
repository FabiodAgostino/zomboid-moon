-- AutoPilot (Moon): automations for the Moon server.

-- The editor's logic without the window (spec MACRO-AUTOPILOT.md 4): texts edited by lines (insertions with the
-- line's indentation, "Inserisci > Ripeti" around the cursor's line), the texts of the status bar and of the list, the
-- problems as list entries. Pure: strings in, strings out, so the tests run it without any UI.
-- Lines and columns are 1-based here. The game's text box keeps the cursor as an offset in the whole text, from 0
-- (UITextBox2 42.22: getCursorPos is textEntryCursorPos, an index into the text; its line follows from it at every
-- render): cursorFromOffset and offsetOfLine turn one into the other. Kahlua's strings are the game's (one letter per
-- character, accents included), so the offsets are string positions.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.EditorModel = AutoPilotMoon.Macro.EditorModel or {};

local M = AutoPilotMoon.Macro.EditorModel;

local function lines(text)
	local list = {};
	local start = 1;

	text = text or "";

	while true
	do
		local stop = string.find(text, "\n", start, true);

		if stop == nil
		then
			table.insert(list, string.sub(text, start));

			return list;
		end

		table.insert(list, string.sub(text, start, stop - 1));
		start = stop + 1;
	end
end

M.lines = lines;

function AutoPilotMoon.Macro.EditorModel:lineCount(text)
	return #lines(text);
end

local function indentOf(line)
	return string.match(line or "", "^( *)") or "";
end

-- the code of a line without its comment, trimmed
local function codeOf(line)
	local code = AutoPilotMoon.Macro.Lang.stripComment(AutoPilotMoon.Macro.Lang.normalize(line or ""));

	return AutoPilotMoon.Macro.Lang.trim(code);
end

-- the indentation a new line after line n should have (the game's text box does not indent by itself): one level
-- more after a line ending with ":", else the indentation of the last line with code (MACRO-AUTOPILOT.md 4.6)
function AutoPilotMoon.Macro.EditorModel:indentAfter(list, n)
	for i = n, 1, -1
	do
		local code = codeOf(list[i]);

		if code ~= ""
		then
			local indent = indentOf(AutoPilotMoon.Macro.Lang.normalize(list[i]));

			if string.sub(code, -1) == ":"
			then
				return indent .. AutoPilotMoon.Macro.Lang.indent;
			end

			return indent;
		end
	end

	return "";
end

-- a command on the cursor's line: on an empty line it takes it (with the indentation the line should have), else it
-- goes on a new line after it, indented as a line after it should be. Returns the new text and the 1-based line.
function AutoPilotMoon.Macro.EditorModel:insertLine(text, cursorLine, command)
	local list = lines(text);

	cursorLine = math.max(1, math.min(cursorLine or #list, #list));

	local current = list[cursorLine] or "";

	if AutoPilotMoon.Macro.Lang.trim(current) == ""
	then
		local indent = M:indentAfter(list, cursorLine - 1);

		-- spaces already typed on the empty line are kept when they are a level of their own
		if string.len(current) > string.len(indent) and string.len(current) % 4 == 0
		then
			indent = current;
		end

		list[cursorLine] = indent .. command;

		return table.concat(list, "\n"), cursorLine;
	end

	table.insert(list, cursorLine + 1, M:indentAfter(list, cursorLine) .. command);

	return table.concat(list, "\n"), cursorLine + 1;
end

-- "Inserisci > Ripeti / Se": the header (ending with ":") at the cursor's line's indentation, the line under it one
-- level more; on an empty line an empty body line to fill, the cursor on it
function AutoPilotMoon.Macro.EditorModel:wrapBlock(text, cursorLine, header)
	local list = lines(text);
	local unit = AutoPilotMoon.Macro.Lang.indent;

	cursorLine = math.max(1, math.min(cursorLine or #list, #list));

	local current = list[cursorLine] or "";

	if AutoPilotMoon.Macro.Lang.trim(current) == ""
	then
		local indent = M:indentAfter(list, cursorLine - 1);

		list[cursorLine] = indent .. header;
		table.insert(list, cursorLine + 1, indent .. unit);

		return table.concat(list, "\n"), cursorLine + 1;
	end

	local indent = indentOf(current);

	list[cursorLine] = unit .. current;
	table.insert(list, cursorLine, indent .. header);

	return table.concat(list, "\n"), cursorLine;
end

-- "Inserisci > Quando": a "when" block at the top of the macro (after its first comments), its action under it
function AutoPilotMoon.Macro.EditorModel:insertHandler(text, header, body)
	local list = lines(text);
	local at = 1;

	while at <= #list and string.find(list[at], "^%s*#")
	do
		at = at + 1;
	end

	if #list == 1 and AutoPilotMoon.Macro.Lang.trim(list[1]) == ""
	then
		list = {};
		at = 1;
	end

	table.insert(list, at, header);
	table.insert(list, at + 1, AutoPilotMoon.Macro.Lang.indent .. body);

	if list[at + 2] ~= nil and AutoPilotMoon.Macro.Lang.trim(list[at + 2]) ~= ""
	then
		table.insert(list, at + 2, "");
	end

	return table.concat(list, "\n"), at + 1;
end

-- a piece of text at line, column (1-based; "Inserisci > Oggetto" puts "Nome" where the cursor is)
function AutoPilotMoon.Macro.EditorModel:insertAt(text, line, column, piece)
	local list = lines(text);

	line = math.max(1, math.min(line or #list, #list));

	local current = list[line] or "";

	column = math.max(1, math.min(column or (string.len(current) + 1), string.len(current) + 1));
	list[line] = string.sub(current, 1, column - 1) .. piece .. string.sub(current, column);

	return table.concat(list, "\n"), line, column + string.len(piece);
end

-- the 1-based line and column of the text box's cursor offset (0-based, in the whole text)
function AutoPilotMoon.Macro.EditorModel:cursorFromOffset(text, offset)
	text = text or "";
	offset = math.max(0, math.min(offset or 0, string.len(text)));

	local line = 1;
	local lineStart = 0;
	local start = 1;

	while true
	do
		local stop = string.find(text, "\n", start, true);

		if stop == nil or stop > offset
		then
			break;
		end

		line = line + 1;
		lineStart = stop;
		start = stop + 1;
	end

	return line, offset - lineStart + 1;
end

-- the text box's offset (0-based) of the start of a 1-based line; past the last line: the end of the text
function AutoPilotMoon.Macro.EditorModel:offsetOfLine(text, line)
	text = text or "";

	local offset = 0;
	local start = 1;

	for i = 2, line or 1
	do
		local stop = string.find(text, "\n", start, true);

		if stop == nil
		then
			return string.len(text);
		end

		offset = stop;
		start = stop + 1;
	end

	return offset;
end

-- "Riga 3, colonna 12 - 5 righe"
function AutoPilotMoon.Macro.EditorModel:cursorText(line, column, count)
	return getText("IGUI_AutoPilot_E_Cursor", line, column, count);
end

-- the macro's status: "Salvata" / "Modifiche non salvate" / "Salvo..." and the problems in words
function AutoPilotMoon.Macro.EditorModel:saveText(state)
	if state == "saving"
	then
		return getText("IGUI_AutoPilot_E_Saving");
	elseif state == "unsaved"
	then
		return getText("IGUI_AutoPilot_E_Unsaved");
	end

	return getText("IGUI_AutoPilot_E_Saved");
end

-- the entries of the problems' list: { text, line, color = "good" / "bad" / "warn" / nil }: the errors in the bad colour,
-- the warnings in amber, then "can I do this now?" and what each craft line needs ("Attrezzi e materiali", 4.5).
-- result: Lang:check's; failure: the line where the last run stopped ({ line, text }); now: the "can I do this now?"
-- ({ line, reason } or nil)
function AutoPilotMoon.Macro.EditorModel:problemEntries(result, failure, now)
	local entries = {};

	if failure
	then
		table.insert(entries, { text = getText("IGUI_AutoPilot_E_RunFailed", failure.line, failure.text), line = failure.line, color = "bad" });
	end

	if result == nil
	then
		return entries;
	end

	if result.notReady
	then
		table.insert(entries, { text = getText("IGUI_AutoPilot_E_Preparing") });

		return entries;
	end

	for i, problem in ipairs(result.problems)
	do
		table.insert(entries, { text = problem.text, line = problem.line, color = problem.warn and "warn" or "bad" });
	end

	if result.more > 0
	then
		table.insert(entries, { text = getText("IGUI_AutoPilot_E_MoreProblems", result.more) });
	end

	if result.errors == 0
	then
		if #result.problems == 0
		then
			-- after the last run's failure, which stays first
			table.insert(entries, failure and 2 or 1, { text = getText("IGUI_AutoPilot_E_ProblemsNone") });
		end

		if now and now.line
		then
			if now.reason
			then
				table.insert(entries, { text = getText("IGUI_AutoPilot_E_NowNo", now.line, now.reason), line = now.line, color = "bad" });
			else
				table.insert(entries, { text = getText("IGUI_AutoPilot_E_NowOk", now.line), line = now.line, color = "good" });
			end
		end
	end

	for i, needs in ipairs(result.requirements or {})
	do
		table.insert(entries, { text = needs.text, line = needs.line, needs = true });
	end

	return entries;
end

-- the problems of a check in words, for the status and its colour: "Nessun problema" (good), "Problemi: 2" (bad),
-- "Problemi: 0, avvisi: 1" (amber when there are only warnings, bad with errors too)
function AutoPilotMoon.Macro.EditorModel:problemsText(result)
	if result == nil or result.notReady
	then
		return getText("IGUI_AutoPilot_E_Preparing"), nil;
	end

	if result.errors + result.warnings == 0
	then
		return getText("IGUI_AutoPilot_E_NoProblems"), "good";
	end

	if result.warnings > 0
	then
		return getText("IGUI_AutoPilot_E_ProblemsWarnings", result.errors, result.warnings), result.errors > 0 and "bad" or "warn";
	end

	return getText("IGUI_AutoPilot_E_Problems", result.errors), "bad";
end

-- a line of the list: the name, "(in corso)" for the macro running, "(!)" (in the bad colour, with the count in the
-- tooltip) for one with errors
function AutoPilotMoon.Macro.EditorModel:listEntry(macro, runningName, errors)
	local entry = { name = macro.name, macro = macro, text = macro.name };

	if runningName and string.lower(runningName) == string.lower(macro.name)
	then
		entry.suffix = getText("IGUI_AutoPilot_E_Running");
	elseif errors and errors > 0
	then
		entry.suffix = "(!)";
		entry.bad = true;
		entry.tooltip = getText("IGUI_AutoPilot_E_Problems", errors);
	end

	return entry;
end
