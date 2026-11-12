-- AutoPilot (Moon): automations for the Moon server.

-- The macros of the first language (format 1 of the file, step M1 of 11/11/2026: "crea ... con ...", "ripeti finche'
-- puoi ... fine", the English words "craft ... with ...", "repeat while possible ... end") into the language of today
-- (MacroLang.lua, format 2): the file's macros are converted once when it is read (MacroStore), a pasted old macro
-- when it is pasted, and the check shows the converted line as the fix of an old line written by habit.
--
-- Convert:line(code) -> the line in the new language (no indentation), or nil when it is not an old statement
-- Convert:isOld(text) -> true when the text has a line of the old language
-- Convert:convert(text, note) -> newText, true; or, when a line cannot be converted, the old text commented with the
--   note on top and false (never a macro lost: the player rewrites it from the comment)
-- Purely syntactic: names are copied as written (in quotes), nothing is resolved.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Convert = AutoPilotMoon.Macro.Convert or {};

local Convert = AutoPilotMoon.Macro.Convert;

local function set(...)
	local t = {};

	for i, word in ipairs({ ... })
	do
		t[word] = true;
	end

	return t;
end

local FINCHE = "finch\195\169";
local CRAFT = set("crea", "craft");
local DISMANTLE = set("smonta", "dismantle");
local REPEAT = set("ripeti", "repeat");
local ENDS = set("fine", "end");
local WAIT = set("aspetta", "wait");
local STOP = set("fermati", "stop");
local WITH = set("con", "with");
local TIMES = set("volte", "volta", "times", "time");
local WHILE = set(FINCHE, "finche", "while");
local POSSIBLE = set("puoi", "possible");
local FOREVER = set("sempre", "forever");
local SECONDS = set("secondi", "secondo", "s", "sec", "seconds", "second");
local IF = set("se", "if");
local HAVE = set("hai", "have");
local NOT = set("non", "not", "don't", "dont");
local OPS = { ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=", ["="] = "==" };
local SEPARATORS = set(" ", "\"", "<", ">", "=", "{", "}");

-- the old reading of a line: words, numbers, texts in double quotes, operators (format 1, spec 2.3 of 11/11/2026)
local function tokenize(line)
	local tokens = {};
	local i = 1;
	local n = string.len(line);

	while i <= n
	do
		local c = string.sub(line, i, i);

		if c == " "
		then
			i = i + 1;
		elseif c == "\""
		then
			local close = string.find(line, "\"", i + 1, true);

			if close == nil
			then
				return nil;
			end

			local text = AutoPilotMoon.Macro.Lang.trim(string.sub(line, i + 1, close - 1));

			table.insert(tokens, { kind = "str", text = text, lower = string.lower(text) });
			i = close + 1;
		elseif c == "<" or c == ">" or c == "="
		then
			local text = c;

			if (c == "<" or c == ">") and string.sub(line, i + 1, i + 1) == "="
			then
				text = c .. "=";
			end

			table.insert(tokens, { kind = "op", text = text, lower = text });
			i = i + string.len(text);
		elseif c == "{" or c == "}"
		then
			table.insert(tokens, { kind = "brace", text = c, lower = c });
			i = i + 1;
		else
			local j = i;

			while j <= n and not SEPARATORS[string.sub(line, j, j)]
			do
				j = j + 1;
			end

			local text = string.sub(line, i, j - 1);

			table.insert(tokens, { kind = string.find(text, "^%d+$") and "num" or "word", text = text, lower = string.lower(text) });
			i = j;
		end
	end

	return tokens;
end

local function isName(token)
	return token ~= nil and (token.kind == "str" or token.kind == "word");
end

local function quoted(token)
	return "\"" .. token.text .. "\"";
end

-- the old line without its comment (only double quotes protect a "#")
local function stripComment(line)
	local inQuote = false;

	for i = 1, string.len(line)
	do
		local c = string.sub(line, i, i);

		if c == "\""
		then
			inQuote = not inQuote;
		elseif c == "#" and not inQuote
		then
			return string.sub(line, 1, i - 1), string.sub(line, i);
		end
	end

	return line, nil;
end

local function normalize(line)
	line = AutoPilotMoon.Macro.Lang.normalize(line);

	return (string.gsub(line, "\t", " "));
end

-- an old condition from token k: hai "X" / hai almeno N "X" / non hai "X" / Skill < N
local function condition(tokens, k)
	local first = tokens[k];

	if first == nil
	then
		return nil;
	end

	if NOT[first.lower] and tokens[k + 1] and HAVE[tokens[k + 1].lower] and isName(tokens[k + 2]) and tokens[k + 3] == nil
	then
		return "not has(" .. quoted(tokens[k + 2]) .. ")";
	end

	if HAVE[first.lower]
	then
		local i = k + 1;

		if tokens[i] and tokens[i].lower == "almeno"
		then
			i = i + 1;
		elseif tokens[i] and tokens[i].lower == "at" and tokens[i + 1] and tokens[i + 1].lower == "least"
		then
			i = i + 2;
		end

		local n = nil;

		if tokens[i] and tokens[i].kind == "num"
		then
			n = tokens[i].text;
			i = i + 1;
		end

		if not isName(tokens[i]) or tokens[i + 1] ~= nil
		then
			return nil;
		end

		if n and tonumber(n) > 1
		then
			return "has(" .. quoted(tokens[i]) .. ", at_least=" .. n .. ")";
		end

		return "has(" .. quoted(tokens[i]) .. ")";
	end

	local op = tokens[k + 1];
	local n = tokens[k + 2];

	if isName(first) and op and op.kind == "op" and OPS[op.text] and n and n.kind == "num" and tokens[k + 3] == nil
	then
		return "skill(" .. quoted(first) .. ") " .. OPS[op.text] .. " " .. n.text;
	end

	return nil;
end

-- "N volte" at token k: the number and the next index; false when nothing is there; nil when it is something else
local function times(tokens, k)
	if tokens[k] == nil
	then
		return false;
	end

	if tokens[k].kind == "num" and tokens[k + 1] and TIMES[tokens[k + 1].lower]
	then
		return tokens[k].text, k + 2;
	end

	return nil;
end

-- one old statement (the tokens of the line without its comment): the new line and whether it opens a block
local function statement(tokens)
	local first = tokens[1];
	local word = first and first.lower;

	if word == nil or first.kind ~= "word"
	then
		return nil;
	end

	if CRAFT[word] and isName(tokens[2])
	then
		local line = "craft(" .. quoted(tokens[2]);
		local k = 3;

		if tokens[k] and WITH[tokens[k].lower]
		then
			if not isName(tokens[k + 1])
			then
				return nil;
			end

			line = line .. ", using=" .. quoted(tokens[k + 1]);
			k = k + 2;
		end

		local n, after = times(tokens, k);

		if n == nil
		then
			return nil;
		elseif n
		then
			if tonumber(n) > 1
			then
				line = line .. ", times=" .. n;
			end

			k = after;
		end

		if tokens[k] ~= nil
		then
			return nil;
		end

		return line .. ")", false;
	end

	if DISMANTLE[word] and isName(tokens[2])
	then
		local line = "dismantle(" .. quoted(tokens[2]);
		local n, after = times(tokens, 3);

		if n == nil or (n and tokens[after] ~= nil) or (not n and tokens[3] ~= nil)
		then
			return nil;
		end

		if n and tonumber(n) > 1
		then
			line = line .. ", times=" .. n;
		end

		return line .. ")", false;
	end

	if REPEAT[word]
	then
		local second = tokens[2];

		if second == nil
		then
			return nil;
		end

		if second.kind == "num"
		then
			local n, after = times(tokens, 2);

			if n and tokens[after] == nil
			then
				return "repeat " .. n .. ":", true;
			end

			return nil;
		end

		if WHILE[second.lower] and tokens[3] and POSSIBLE[tokens[3].lower] and tokens[4] == nil
		then
			return "while possible:", true;
		end

		if WHILE[second.lower]
		then
			local cond = condition(tokens, 3);

			return cond and ("while " .. cond .. ":") or nil, true;
		end

		if FOREVER[second.lower] and tokens[3] == nil
		then
			return "while True:", true;
		end

		return nil;
	end

	if WAIT[word] and tokens[2] and tokens[2].kind == "num" and (tokens[3] == nil or (SECONDS[tokens[3].lower] and tokens[4] == nil))
	then
		return "wait(" .. tokens[2].text .. ")", false;
	end

	if STOP[word] and tokens[2] and IF[tokens[2].lower]
	then
		local cond = condition(tokens, 3);

		return cond and ("stop_if(" .. cond .. ")") or nil, false;
	end

	return nil;
end

-- the new line of an old statement (the check's hint), or nil
function AutoPilotMoon.Macro.Convert:line(code)
	local tokens = tokenize(AutoPilotMoon.Macro.Lang.trim(normalize(code or "")));

	if tokens == nil or #tokens == 0
	then
		return nil;
	end

	-- a line already written in the new way is never "old" (craft("X") has "(" in its first word)
	if string.find(tokens[1].text, "(", 1, true)
	then
		return nil;
	end

	local line = statement(tokens);

	return line;
end

-- the first word of a line that only the old language has
local function oldLine(code)
	local tokens = tokenize(AutoPilotMoon.Macro.Lang.trim(normalize(code)));

	if tokens == nil or #tokens == 0 or tokens[1].kind ~= "word"
	then
		return false;
	end

	local word = tokens[1].lower;

	if ENDS[word] and #tokens == 1
	then
		return true;
	end

	if word == "crea" or word == "smonta" or word == "ripeti" or word == "aspetta" or word == "fermati"
	then
		return true;
	end

	-- the English words of format 1: written without "(" (craft "X", wait 5, repeat 3 times, stop if ...)
	if (word == "craft" or word == "dismantle" or word == "wait" or word == "repeat" or word == "stop")
		and not string.find(tokens[1].text, "(", 1, true) and statement(tokens) ~= nil
	then
		return true;
	end

	return false;
end

function AutoPilotMoon.Macro.Convert:isOld(text)
	for i, raw in ipairs(AutoPilotMoon.Macro.Lang:splitLines(text or ""))
	do
		local code = stripComment(normalize(raw));

		if AutoPilotMoon.Macro.Lang.trim(code) ~= "" and oldLine(code)
		then
			return true;
		end
	end

	return false;
end

-- the whole text in the new language: blocks by indentation (Lang.indent per "ripeti"), "fine" left out, comments and
-- empty lines kept where they were
function AutoPilotMoon.Macro.Convert:convert(text, note)
	local out = {};
	local depth = 0;
	local unit = AutoPilotMoon.Macro.Lang.indent;

	for i, raw in ipairs(AutoPilotMoon.Macro.Lang:splitLines(text or ""))
	do
		local line = normalize(raw);
		local code, comment = stripComment(line);
		local trimmed = AutoPilotMoon.Macro.Lang.trim(code);
		local indent = string.rep(unit, depth);

		if trimmed == ""
		then
			table.insert(out, comment and (indent .. comment) or "");
		else
			local tokens = tokenize(trimmed);

			if tokens == nil
			then
				return Convert:commented(text, note), false;
			end

			if #tokens == 1 and tokens[1].kind == "word" and ENDS[tokens[1].lower]
			then
				depth = math.max(0, depth - 1);

				if comment
				then
					table.insert(out, string.rep(unit, depth) .. comment);
				end
			else
				local newLine, opens = statement(tokens);

				if newLine == nil
				then
					return Convert:commented(text, note), false;
				end

				table.insert(out, indent .. newLine .. (comment and ("  " .. comment) or ""));

				if opens
				then
					depth = depth + 1;
				end
			end
		end
	end

	return table.concat(out, "\n"), true;
end

-- an old macro that cannot be converted: kept whole as comments, with the note on top
function AutoPilotMoon.Macro.Convert:commented(text, note)
	local out = {};

	for i, line in ipairs(AutoPilotMoon.Macro.Lang:splitLines(note or ""))
	do
		table.insert(out, "# " .. line);
	end

	for i, line in ipairs(AutoPilotMoon.Macro.Lang:splitLines(text or ""))
	do
		table.insert(out, "# " .. line);
	end

	return table.concat(out, "\n");
end
