-- AutoPilot (Moon): automations for the Moon server.

-- The suggestions of the macro editor while typing (MACRO-AUTOPILOT.md 4.12), without the window: where the cursor
-- is (the context), what fits there (the entries), what accepting one writes (the new text and the cursor). Pure:
-- strings in, strings out, so the tests run it without any UI; the popup is MacroSuggestView.lua.
--
-- One source: every word comes from the language's own tables, the ones the checker and the colours read
-- (Lang.statementList, Lang.calls with their keyword arguments and the kinds of name they hold, Lang.condCalls,
-- Lang.moodleList, Lang.percents, Lang.moodleItalian, Lang.conditionWords, Lang.exercises, Lang.seats,
-- Lang.drinkAmountList) and from the names' indexes (MacroNames: the recipes the macros can do, the items, the skills).
-- Recipes and items are written as "Inserisci > Ricetta / Oggetto" writes them: the name in the player's language, the
-- recipe's id when its name stands for more than one recipe.
--
-- Contexts (S:context(line, column)):
--   statement   a word at the start of a line: the statements (while possible:, if ...:, when ...:) and the commands
--   condition   after if / elif / while / when, after and / or / not, in stop_if(...) and in a parenthesis there:
--               the moodles (with their Italian names), endurance, craving, dark, hour (Lang.condWordList), has(,
--               count(, skill(, xp_gained(, condition(, known(, not
--   args        after "(" or "," in a call: its keyword arguments not written yet (using=, minutes=, seat=, damaged=...),
--               and after "(" the names its first argument holds (craft( -> the recipes, written with the quotes)
--   recipe, anyRecipe, item, skill, exercise, seat, amount   inside the quotes of an argument that holds that kind of
--               name, or right after its "=" without the quotes (anyRecipe: every recipe, the workbenches' too, for
--               known("..."))
-- Searching: without accents and case (an accented e = e), every word typed; the name in the player's language
-- first (the whole name, then a word of it, then every word anywhere), then the game's id (AssembleShortImplement,
-- Base.ClawhammerHead: "short implement", "clawhammer" find them, in any language); the last two from 3 letters; at
-- most S.maxEntries.
-- Cost: only when the text or the cursor change (the editor calls it); the recipes and the items folded once into an
-- index (S.index, built the first time it is needed after the names are ready).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Suggest = AutoPilotMoon.Macro.Suggest or {};

local S = AutoPilotMoon.Macro.Suggest;

-- at most this many entries (a condition offers 31 words: every moodle stays in the list before typing)
S.maxEntries = 40;
S.index = nil;
S.texts = {};

local function Lang()
	return AutoPilotMoon.Macro.Lang;
end

local function Names()
	return AutoPilotMoon.Macro.Names;
end

-- a translation, read once per session (the language does not change while playing)
local function text(key, arg)
	local cacheKey = arg and (key .. "\n" .. arg) or key;
	local t = S.texts[cacheKey];

	if t == nil
	then
		if arg
		then
			t = getText(key, arg);
		else
			t = getText(key);
		end

		S.texts[cacheKey] = t;
	end

	return t;
end

S.text = text;

-- ============================================================================================================
-- Folding: lower case without accents (written as UTF-8 escapes: one character each in the game's strings)
-- ============================================================================================================

local ACCENTS = {
	a = "\195\160\195\161\195\162\195\163\195\164\195\165\195\128\195\129\195\130\195\131\195\132\195\133",
	e = "\195\168\195\169\195\170\195\171\195\136\195\137\195\138\195\139",
	i = "\195\172\195\173\195\174\195\175\195\140\195\141\195\142\195\143",
	o = "\195\178\195\179\195\180\195\181\195\182\195\146\195\147\195\148\195\149\195\150",
	u = "\195\185\195\186\195\187\195\188\195\153\195\154\195\155\195\156",
	c = "\195\167\195\135",
	n = "\195\177\195\145",
	["'"] = "\226\128\153",
};
local FOLD = {};

for base, chars in pairs(ACCENTS)
do
	for i = 1, string.len(chars)
	do
		FOLD[string.sub(chars, i, i)] = base;
	end
end

-- lower case, the accented letters as plain ones, the typographic apostrophe as "'"
function AutoPilotMoon.Macro.Suggest.fold(s)
	s = string.lower(s or "");

	local n = string.len(s);
	local parts = nil;
	local from = 1;

	for i = 1, n
	do
		if string.byte(s, i) > 127
		then
			local plain = FOLD[string.sub(s, i, i)];

			if plain
			then
				parts = parts or {};
				table.insert(parts, string.sub(s, from, i - 1));
				table.insert(parts, plain);
				from = i + 1;
			end
		end
	end

	if parts == nil
	then
		return s;
	end

	table.insert(parts, string.sub(s, from));

	return table.concat(parts);
end

local fold = S.fold;

-- the words of a game id: "AssembleShortImplement" -> "assemble short implement", "Base.ClawhammerHead" ->
-- "clawhammer head base.clawhammerhead"
function AutoPilotMoon.Macro.Suggest.idWords(id)
	id = id or "";

	local short = string.match(id, "([^%.]+)$") or id;
	local words = string.gsub(short, "(%l)(%u)", "%1 %2");

	words = string.gsub(words, "(%a)(%d)", "%1 %2");

	return string.lower(words) .. " " .. string.lower(id);
end

local function trim(s)
	return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"));
end

-- the folded words of a query
local function queryWords(query)
	local q = fold(trim(string.gsub(query or "", "%s+", " ")));
	local words = {};

	for word in string.gmatch(q, "%S+")
	do
		table.insert(words, word);
	end

	return q, words;
end

local function allIn(s, words)
	for i, word in ipairs(words)
	do
		if not string.find(s, word, 1, true)
		then
			return false;
		end
	end

	return true;
end

-- ============================================================================================================
-- The line at the cursor
-- ============================================================================================================

-- the line of an offset of the whole text (0-based, as UITextBox2's getCursorPos): the line, the characters before
-- the cursor in it, the offset where the line starts
function AutoPilotMoon.Macro.Suggest.lineAt(text, offset)
	text = text or "";
	offset = math.max(0, math.min(offset or 0, string.len(text)));

	local start = offset;

	while start > 0 and string.sub(text, start, start) ~= "\n"
	do
		start = start - 1;
	end

	local stop = string.find(text, "\n", offset + 1, true);
	local line = string.sub(text, start + 1, (stop or (string.len(text) + 1)) - 1);

	return line, offset - start, start;
end

-- the open parentheses of tokens: { call = the lower name before "(" or nil, at = the index of "(" }
local function openParens(tokens)
	local stack = {};

	for k, token in ipairs(tokens)
	do
		if token.k == "sym" and token.text == "("
		then
			local before = tokens[k - 1];

			table.insert(stack, { call = (before and before.k == "name") and before.lower or nil, at = k });
		elseif token.k == "sym" and token.text == ")"
		then
			table.remove(stack);
		end
	end

	return stack;
end

local function callSpec(name)
	if name == nil
	then
		return nil;
	end

	return Lang().calls[name] or Lang().condCalls[name];
end

-- the call takes a condition (stop_if)
local function takesCondition(spec)
	return spec ~= nil and spec.pos[1] ~= nil and spec.kw[spec.pos[1]] == "cond";
end

-- the keyword arguments already written in the call whose "(" is tokens[at] (its first argument too, when written
-- without a name)
local function usedArgs(tokens, at, spec)
	local used = {};
	local depth = 0;
	local first = true;

	for k = at + 1, #tokens
	do
		local token = tokens[k];

		if token.k == "sym" and token.text == "("
		then
			depth = depth + 1;
		elseif token.k == "sym" and token.text == ")"
		then
			depth = depth - 1;
		elseif depth == 0
		then
			local after = tokens[k + 1];

			if token.k == "name" and after and after.k == "sym" and after.text == "="
			then
				used[token.lower] = true;
			elseif first and token.k == "str" and spec.pos[1]
			then
				used[spec.pos[1]] = true;
			end

			first = token.k == "sym" and token.text == ",";
		end
	end

	return used;
end

local HEADERS = { ["if"] = true, ["elif"] = true, ["while"] = true, ["when"] = true };

-- the token before the word opens a condition's operand: the header's own word, and / or / not, "("
local function startsOperand(prev, first)
	if prev == nil
	then
		return false;
	end

	if prev == first and HEADERS[first.lower]
	then
		return true;
	end

	if prev.k == "name" and (prev.lower == "and" or prev.lower == "or" or prev.lower == "not")
	then
		return true;
	end

	return prev.k == "sym" and prev.text == "(";
end

-- inside the quotes: the kind of name the argument holds (nil: nothing to suggest)
local function stringContext(line, column, tokens, quoteAt)
	local prev = tokens[#tokens];

	if prev == nil or prev.k ~= "sym"
	then
		return nil;
	end

	local stack = openParens(tokens);
	local open = stack[#stack];
	local spec = open and callSpec(open.call);

	if spec == nil or spec.names == nil
	then
		return nil;
	end

	local kind = nil;

	if prev.text == "="
	then
		local name = tokens[#tokens - 1];

		kind = name and name.k == "name" and spec.names[name.lower] or nil;
	elseif prev.text == "(" and spec.pos[1]
	then
		kind = spec.names[spec.pos[1]];
	end

	if kind == nil
	then
		return nil;
	end

	local quote = string.sub(line, quoteAt, quoteAt);
	local close = string.find(line, quote, column + 1, true);
	local ctx = { kind = kind, quoted = true, call = open.call, from = quoteAt + 1,
		query = string.gsub(string.sub(line, quoteAt + 1, column), "^%s+", "") };

	if close
	then
		ctx.to = close - 1;
		ctx.closed = true;
	else
		ctx.to = column;
		ctx.closeParens = 0;

		-- nothing after the cursor: the parentheses still open are closed too
		if trim(string.sub(line, column + 1)) == ""
		then
			ctx.closeParens = #stack;
		end
	end

	ctx.word = string.sub(line, ctx.from, ctx.to);

	return ctx;
end

-- out of the quotes: the word at the cursor and what comes before it
local function codeContext(ctx, before)
	local L = Lang();
	local prev = before[#before];
	local first = before[1];

	if prev == nil
	then
		ctx.kind = "statement";

		return ctx;
	end

	for k, token in ipairs(before)
	do
		if token.k == "sym" and token.text == ":"
		then
			return nil;
		end
	end

	local stack = openParens(before);
	local open = stack[#stack];
	local spec = open and callSpec(open.call);
	local header = first.k == "name" and HEADERS[first.lower];
	local inCondition = header;

	for k, entry in ipairs(stack)
	do
		inCondition = inCondition or takesCondition(callSpec(entry.call));
	end

	-- stop_if(...): a condition inside, not arguments
	if spec and not takesCondition(spec)
	then
		ctx.call = open.call;

		if prev.k == "sym" and (prev.text == "(" or prev.text == ",")
		then
			ctx.kind = "args";
			ctx.used = usedArgs(before, open.at, spec);
			ctx.afterComma = prev.text == ",";
			ctx.tightComma = prev.text == "," and prev.e == ctx.from - 1;

			-- after "(": the names its first argument holds, when it needs one (craft(, skill(; eat( needs nothing)
			if prev.text == "(" and spec.pos[1] and spec.names and spec.req[1] == spec.pos[1]
			then
				ctx.names = spec.names[spec.pos[1]];
			end

			return ctx;
		end

		if prev.k == "sym" and prev.text == "="
		then
			local name = before[#before - 1];
			local kind = spec.names and name and name.k == "name" and spec.names[name.lower];

			if kind
			then
				ctx.kind = kind;
				ctx.quoted = false;

				return ctx;
			end

			return nil;
		end

		return nil;
	end

	if inCondition and startsOperand(prev, first)
	then
		ctx.kind = "condition";
		ctx.afterWhile = prev == first and first.lower == "while";

		return ctx;
	end

	return nil;
end

-- The context at the cursor: line = the line as written, column = the characters before the cursor in it. nil when
-- nothing fits there (a comment, a number, after the ":" of a header, after a value...). Fields: kind, query (what is
-- typed before the cursor), from / to (the part of the line an entry replaces, 1-based, inclusive; to < from when
-- nothing), word (that part), quoted (inside quotes), closed (the closing quote is there), closeParens, call (the
-- call the cursor is in), used (its arguments written), names (the kind of name its first argument holds),
-- afterComma / tightComma (an argument after "," / right after it), afterWhile.
function AutoPilotMoon.Macro.Suggest:context(line, column)
	local L = Lang();

	line = line or "";

	local n = string.len(line);

	column = math.max(0, math.min(column or n, n));

	local plain = L.plainLine(line);

	if string.len(plain) ~= n
	then
		return nil;
	end

	local code, comment = L.stripComment(string.sub(plain, 1, column));

	if comment
	then
		return nil;
	end

	local tokens, err, partial, quoteAt = L.tokenize(code);

	if tokens == nil
	then
		return stringContext(plain, column, partial or {}, quoteAt);
	end

	local from = column;

	while from > 0 and L.isNameChar(string.sub(plain, from, from))
	do
		from = from - 1;
	end

	local to = column;

	while to < n and L.isNameChar(string.sub(plain, to + 1, to + 1))
	do
		to = to + 1;
	end

	local query = string.sub(plain, from + 1, column);

	if string.find(query, "^%d")
	then
		return nil;
	end

	local before = tokens;

	if query ~= ""
	then
		before = {};

		for k = 1, #tokens - 1
		do
			before[k] = tokens[k];
		end
	end

	return codeContext({ query = query, from = from + 1, to = to, word = string.sub(plain, from + 1, to) }, before);
end

-- the context at an offset of the whole text, with the line's place (lineStart: the offset of its first character)
function AutoPilotMoon.Macro.Suggest:contextAt(text, offset)
	local line, column, lineStart = S.lineAt(text, offset);
	local ctx = S:context(line, column);

	if ctx
	then
		ctx.lineStart = lineStart;
		ctx.offset = offset;
	end

	return ctx;
end

-- ============================================================================================================
-- Entries
-- ============================================================================================================

-- An entry: label (what the list shows), detail (beside it, dim), class (its colour: the editor's colours' classes),
-- helpKey / helpArg or helpText (the line under the list), text (what is written; caret = where the cursor goes in
-- it, 0-based, nil = its end), block (a body line follows), reopen (the suggestions of what comes next open again), word (only
-- the name, when the call's "(" or the argument's "=" is already written), value (a name written inside quotes).

-- the small lists: buckets by how well a key matches (0: the label starts with the query, 1: the query inside the
-- label, 2: inside another key: an Italian name, a detail)
local function rankSmall(query, label, others)
	if query == ""
	then
		return 1;
	end

	local l = fold(label);

	if string.sub(l, 1, string.len(query)) == query
	then
		return 1;
	end

	if string.len(query) >= 2 and string.find(l, query, 1, true)
	then
		return 2;
	end

	if string.len(query) >= 2 and others
	then
		for i, other in ipairs(others)
		do
			if string.find(fold(other), query, 1, true)
			then
				return 3;
			end
		end
	end

	return nil;
end

local function newBuckets()
	return { {}, {}, {}, {} };
end

local function flatten(buckets, max)
	local list = {};

	for b, bucket in ipairs(buckets)
	do
		for i, entry in ipairs(bucket)
		do
			if #list >= max
			then
				return list;
			end

			table.insert(list, entry);
		end
	end

	return list;
end

local function sortedKeys(t)
	local keys = {};

	for key in pairs(t or {})
	do
		table.insert(keys, key);
	end

	table.sort(keys);

	return keys;
end

-- how a command is written when chosen: name("") with the cursor in the quotes when its first argument is a name
-- it needs, name() with the cursor inside when it needs a condition or a number, name() with the cursor after it
-- when it needs nothing
local function callEntry(name, spec)
	local entry = { label = name, detail = spec.usage, class = "call", helpKey = "IGUI_AutoPilot_E_Sug_Call_" .. name,
		word = name, call = true };
	local first = spec.pos[1];
	local required = false;

	for i, req in ipairs(spec.req)
	do
		required = required or req == first;
	end

	if first and required and spec.kw[first] == "str"
	then
		entry.text = name .. "(\"\")";
		entry.caret = string.len(name) + 2;
		entry.reopen = spec.names ~= nil and spec.names[first] ~= nil;
	elseif first and required
	then
		entry.text = name .. "()";
		entry.caret = string.len(name) + 1;
		entry.reopen = spec.kw[first] == "cond";
	else
		entry.text = name .. "()";
	end

	return entry;
end

local function statementEntries(ctx, q)
	local L = Lang();
	local buckets = newBuckets();

	for i, statement in ipairs(L.statementList)
	do
		local b = rankSmall(q, statement.word, nil);

		if b
		then
			table.insert(buckets[b], { label = statement.label or statement.text, class = "keyword",
				helpKey = "IGUI_AutoPilot_E_Sug_Kw_" .. statement.id, text = statement.text, caret = statement.caret,
				block = statement.block, reopen = statement.cond, word = statement.word });
		end
	end

	for i, name in ipairs(sortedKeys(L.calls))
	do
		local b = rankSmall(q, name, nil);

		if b
		then
			table.insert(buckets[b], callEntry(name, L.calls[name]));
		end
	end

	return buckets;
end

-- the Italian words written by habit that lead to a name (Lang.moodleItalian: fame -> hungry)
local function italianWords()
	if S.italian == nil
	then
		S.italian = {};

		for word, name in pairs(Lang().moodleItalian)
		do
			S.italian[name] = S.italian[name] or {};
			table.insert(S.italian[name], word);
		end
	end

	return S.italian;
end

local function conditionEntries(ctx, q)
	local L = Lang();
	local buckets = newBuckets();
	local italian = italianWords();

	local function add(entry, others)
		local b = rankSmall(q, entry.label, others);

		if b
		then
			table.insert(buckets[b], entry);
		end
	end

	if ctx.afterWhile
	then
		for i, word in ipairs(L.conditionWords)
		do
			if word.whileOnly
			then
				add({ label = word.word, class = word.word == "True" and "number" or "logic", text = word.text,
					helpKey = "IGUI_AutoPilot_E_Sug_Word_" .. word.word });
			end
		end
	end

	for i, moodle in ipairs(L.moodleList)
	do
		local name = moodle.name;
		local detail = text("IGUI_AutoPilot_E_Moodle_" .. name);
		local others = { detail };

		for k, word in ipairs(italian[name] or {})
		do
			table.insert(others, word);
		end

		add({ label = name, detail = detail, class = "name", text = name, helpKey = "IGUI_AutoPilot_E_Sug_Moodle",
			helpArg = detail }, others);
	end

	for i, name in ipairs(sortedKeys(L.percents))
	do
		local detail = text("IGUI_AutoPilot_E_Moodle_" .. name);
		local others = { detail };

		for k, word in ipairs(italian[name] or {})
		do
			table.insert(others, word);
		end

		add({ label = name, detail = detail, class = "name", text = name, helpKey = "IGUI_AutoPilot_E_Sug_Percent",
			helpArg = detail }, others);
	end

	-- dark, hour (Lang.condWordList, wave 0)
	for i, word in ipairs(L.condWordList)
	do
		local name = word.name;
		local detail = text("IGUI_AutoPilot_E_Cond_" .. name);
		local others = { detail };

		for k, italianWord in ipairs(italian[name] or {})
		do
			table.insert(others, italianWord);
		end

		add({ label = name, detail = detail, class = "name", text = name, helpKey = "IGUI_AutoPilot_E_Sug_Cond_" .. name }, others);
	end

	for i, name in ipairs(sortedKeys(L.condCalls))
	do
		local entry = callEntry(name, L.condCalls[name]);

		add(entry, nil);
	end

	for i, word in ipairs(L.conditionWords)
	do
		if not word.whileOnly
		then
			add({ label = word.word, class = "logic", text = word.text, helpKey = "IGUI_AutoPilot_E_Sug_Word_" .. word.word });
		end
	end

	return buckets;
end

-- ============================================================================================================
-- Names: recipes and items (indexed once), skills, exercises, seats, amounts
-- ============================================================================================================

local function byFold(a, b)
	if a.fold ~= b.fold
	then
		return a.fold < b.fold;
	end

	if a.label ~= b.label
	then
		return a.label < b.label;
	end

	-- one name of two recipes: by id, always in the same order
	return a.id < b.id;
end

-- the index of the recipes and the items, built once the names are ready (again if the names were built again)
function AutoPilotMoon.Macro.Suggest:getIndex()
	local N = Names();

	if N == nil or not N:isReady()
	then
		return nil;
	end

	if S.index and S.index.source == N.recipeList
	then
		return S.index;
	end

	local recipes = {};

	for i, recipe in ipairs(N.recipeList)
	do
		local name = N:recipeName(recipe);
		local id = N:recipeId(recipe);

		table.insert(recipes, { label = name, value = N:isAmbiguousRecipe(recipe) and id or name, id = id,
			fold = fold(name), alt = S.idWords(id) });
	end

	table.sort(recipes, byFold);

	-- every recipe of the game, the workbenches' too (known("...")), the same way
	local anyRecipes = {};

	for i, recipe in ipairs(N.allRecipeList or N.recipeList)
	do
		local name = N:recipeName(recipe);
		local id = N:recipeId(recipe);

		table.insert(anyRecipes, { label = name, value = N:isAmbiguousRecipe(recipe) and id or name, id = id,
			fold = fold(name), alt = S.idWords(id) });
	end

	table.sort(anyRecipes, byFold);

	local items = {};

	for i, entry in ipairs(N.itemNameList)
	do
		local types = N.typesByName[entry.lower] or {};
		local alt = {};

		for k, fullType in ipairs(types)
		do
			table.insert(alt, S.idWords(fullType));
		end

		table.insert(items, { label = entry.text, value = entry.text, id = types[1] or entry.text,
			count = #types, fold = fold(entry.text), alt = table.concat(alt, " ") });
	end

	table.sort(items, byFold);

	S.index = { source = N.recipeList, recipe = recipes, anyRecipe = anyRecipes, item = items };

	return S.index;
end

-- the recipes or the items matching a query: the name starting with it, a word of the name starting with it, every
-- word in the name, every word in the id (these two from 3 letters: "te" would find half the game); alphabetical in
-- each
local function searchIndex(list, q, words, max)
	local buckets = newBuckets();
	local length = string.len(q);
	local anywhere = length >= 3;

	for i, e in ipairs(list)
	do
		local b = nil;

		if length == 0 or string.sub(e.fold, 1, length) == q
		then
			b = 1;
		elseif string.find(e.fold, " " .. q, 1, true)
		then
			b = 2;
		elseif anywhere and allIn(e.fold, words)
		then
			b = 3;
		elseif anywhere and allIn(e.alt, words)
		then
			b = 4;
		end

		if b and #buckets[b] < max
		then
			table.insert(buckets[b], e);

			if b == 1 and #buckets[1] >= max
			then
				break;
			end
		end
	end

	return buckets;
end

local function quotedText(ctx, value)
	if ctx.quoted
	then
		return nil;
	end

	return "\"" .. value .. "\"";
end

local function nameEntries(ctx, kind, q, words)
	local L = Lang();
	local buckets = newBuckets();

	local function add(entry, others)
		local b = rankSmall(q, entry.label, others);

		if b
		then
			entry.text = quotedText(ctx, entry.value);
			table.insert(buckets[b], entry);
		end
	end

	if kind == "recipe" or kind == "anyRecipe" or kind == "item"
	then
		local index = S:getIndex();

		if index == nil
		then
			return buckets, true;
		end

		local found = searchIndex(index[kind], q, words, S.maxEntries);

		for b, bucket in ipairs(found)
		do
			-- an item: the names of one item first, then those of several (2.9: "Sacco" is 7 items), with how many
			local later = {};

			for i, e in ipairs(bucket)
			do
				if kind == "item" and e.count > 1
				then
					table.insert(later, { label = e.label, detail = text("IGUI_AutoPilot_E_Sug_Types", tostring(e.count)), class = "string",
						value = e.value, text = quotedText(ctx, e.value), helpText = getText("IGUI_AutoPilot_E_Sug_ItemMany", e.count, e.id),
						count = e.count });
				else
					table.insert(buckets[b], { label = e.label, detail = e.id, class = "string", value = e.value, text = quotedText(ctx, e.value),
						helpKey = kind == "item" and "IGUI_AutoPilot_E_Sug_Item" or "IGUI_AutoPilot_E_Sug_Recipe", helpArg = e.id });
				end
			end

			for i, entry in ipairs(later)
			do
				table.insert(buckets[b], entry);
			end
		end
	elseif kind == "skill"
	then
		for i, skill in ipairs(Names() and Names().skillList or {})
		do
			add({ label = skill.text, detail = skill.id ~= skill.text and skill.id or nil, class = "name", value = skill.text,
				helpKey = "IGUI_AutoPilot_E_Sug_Skill", helpArg = skill.id }, { skill.id });
		end
	elseif kind == "exercise"
	then
		-- the game's own name and tooltip of the exercise (shared/Definitions/FitnessExercises.lua: "Piegamenti")
		local types = rawget(_G, "FitnessExercises") and FitnessExercises.exercisesType or {};

		for i, id in ipairs(L.exercises)
		do
			local data = types[id] or {};

			add({ label = id, detail = data.name, class = "string", value = id, helpText = data.tooltip,
				helpKey = "IGUI_AutoPilot_E_Sug_Exercise" }, { data.name or id });
		end
	elseif kind == "seat"
	then
		for i, seat in ipairs(L.seats)
		do
			local detail = text("IGUI_AutoPilot_E_Sug_Seat_" .. seat);

			add({ label = seat, detail = detail, class = "string", value = seat, helpKey = "IGUI_AutoPilot_E_Sug_Seat_" .. seat }, { detail });
		end
	elseif kind == "amount"
	then
		for i, amount in ipairs(L.drinkAmountList)
		do
			local detail = text("IGUI_AutoPilot_E_Sug_Amount_" .. amount.name);

			add({ label = amount.name, detail = detail, class = "string", value = amount.name,
				helpKey = "IGUI_AutoPilot_E_Sug_Amount_" .. amount.name }, { detail });
		end
	end

	return buckets, false;
end

-- the keyword arguments of the call not written yet (its first, positional one excluded), then after "(" the names
-- its first argument holds, written with the quotes
local function argEntries(ctx, q, words)
	local spec = callSpec(ctx.call);
	local buckets = newBuckets();
	local positional = {};

	for i, name in ipairs(spec.pos)
	do
		positional[name] = true;
	end

	for i, name in ipairs(sortedKeys(spec.kw))
	do
		local kind = spec.kw[name];

		if not positional[name] and not ctx.used[name] and kind ~= "cond"
		then
			local b = rankSmall(q, name, nil);

			if b
			then
				local entry = { label = name .. "=", class = "param", helpKey = "IGUI_AutoPilot_E_Sug_Arg_" .. name, word = name,
					param = true };

				if kind == "str"
				then
					entry.text = name .. "=\"\"";
					entry.caret = string.len(name) + 2;
					entry.reopen = spec.names ~= nil and spec.names[name] ~= nil;
				elseif kind == "bool"
				then
					entry.text = name .. "=True";
				else
					entry.text = name .. "=";
				end

				table.insert(buckets[b], entry);
			end
		end
	end

	if ctx.names
	then
		local names, waiting = nameEntries(ctx, ctx.names, q, words);

		for b = 1, 4
		do
			for i, entry in ipairs(names[b])
			do
				table.insert(buckets[b], entry);
			end
		end

		return buckets, waiting;
	end

	return buckets, false;
end

-- The entries for a context, at most S.maxEntries; waiting = true when the names are not indexed yet (the editor says
-- "preparo l'elenco..." meanwhile). An entry that would write exactly what is already there is left out (typing a
-- whole word does not keep a list open for nothing: Enter is then a new line).
function AutoPilotMoon.Macro.Suggest:entries(ctx)
	if ctx == nil
	then
		return {}, false;
	end

	local q, words = queryWords(ctx.query);
	local buckets = nil;
	local waiting = false;

	if ctx.kind == "statement"
	then
		buckets = statementEntries(ctx, q);
	elseif ctx.kind == "condition"
	then
		buckets = conditionEntries(ctx, q);
	elseif ctx.kind == "args"
	then
		buckets, waiting = argEntries(ctx, q, words);
	else
		buckets, waiting = nameEntries(ctx, ctx.kind, q, words);
	end

	local list = {};

	for b, bucket in ipairs(buckets)
	do
		for i, entry in ipairs(bucket)
		do
			local same = false;

			if ctx.quoted
			then
				same = ctx.closed and entry.value == ctx.word;
			else
				same = entry.text == ctx.word and entry.caret == nil and not entry.block;
			end

			if not same and #list < S.maxEntries
			then
				table.insert(list, entry);
			end
		end
	end

	return list, waiting;
end

-- ============================================================================================================
-- Accepting
-- ============================================================================================================

local function indentOf(line)
	return string.match(line or "", "^([ \t]*)") or "";
end

local function indentWidth(indent)
	local width = 0;

	for i = 1, string.len(indent)
	do
		width = width + (string.sub(indent, i, i) == "\t" and Lang().tabWidth or 1);
	end

	return width;
end

-- the next line (after the line ending at offset lineEnd) has code more indented than indent (a body already there)
local function bodyFollows(text, lineEnd, indent)
	if lineEnd == nil
	then
		return false;
	end

	local stop = string.find(text, "\n", lineEnd + 1, true);
	local nextLine = string.sub(text, lineEnd + 1, (stop or (string.len(text) + 1)) - 1);

	return trim(nextLine) ~= "" and indentWidth(indentOf(nextLine)) > indentWidth(indent);
end

-- What choosing an entry writes: the new text and the cursor's new offset (0-based). text and offset: where the
-- context was read (S:contextAt). Inside quotes the name and the closing quote (and the parentheses still open when
-- nothing follows), the cursor after the call when only its ")" follow; else the entry's text with the cursor where it says, a body line one level in after a header
-- that opens a block (when nothing follows on the line and no body is there yet), a space after a "," right before.
function AutoPilotMoon.Macro.Suggest:apply(text, offset, ctx, entry)
	local line, column, lineStart = S.lineAt(text, offset);
	local startOffset = lineStart + ctx.from - 1;
	local endOffset = lineStart + math.max(ctx.to, ctx.from - 1);
	local insert = nil;
	local at = nil;

	if ctx.quoted
	then
		insert = entry.value;
		at = string.len(insert) + 1;

		-- the call ends there (only ")" after the closing quote): the cursor after it, so Enter is then a new line and
		-- not a line break inside the parentheses
		local parens = ctx.closed and string.match(string.sub(line, ctx.to + 2), "^(%)*)%s*$");

		if parens
		then
			at = at + string.len(parens);
		end

		if not ctx.closed
		then
			insert = insert .. "\"" .. string.rep(")", ctx.closeParens or 0);
			at = string.len(insert);
		end
	else
		insert = entry.text;
		at = entry.caret or string.len(insert);

		local after = string.sub(line, ctx.to + 1, ctx.to + 1);

		if (entry.call and after == "(") or (entry.param and after == "=")
		then
			insert = entry.word;
			at = string.len(insert);
		elseif entry.block
		then
			local indent = indentOf(line);
			local lineEnd = string.find(text, "\n", offset + 1, true);

			if trim(string.sub(line, ctx.to + 1)) == "" and not bodyFollows(text, lineEnd, indent)
			then
				insert = insert .. "\n" .. indent .. Lang().indent;
				at = string.len(insert);
			end
		end

		if ctx.tightComma
		then
			insert = " " .. insert;
			at = at + 1;
		end
	end

	local newText = string.sub(text, 1, startOffset) .. insert .. string.sub(text, endOffset + 1);

	return newText, startOffset + at;
end
