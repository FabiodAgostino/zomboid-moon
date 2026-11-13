-- AutoPilot (Moon): automations for the Moon server.

-- The macros' small language (spec MACRO-AUTOPILOT.md 2, format 2 of 12/11/2026): English words, the shape of
-- Python. One statement per line; a line ending with ":" opens a block made of the lines indented under it (spaces,
-- a tab counts as 4); "#" starts a comment; calls with keyword arguments; conditions with comparisons, and / or / not,
-- True / False. Read by this interpreter of ours: NEVER loadstring, load, require or any Lua run from the text. A
-- macro becomes only the operations of the flat program below and every name goes through the indexes of recipes,
-- items and skills (AutoPilotMoon.Macro.Names): a copied text can do nothing the player could not do by hand.
--
--   while possible:                                   craft("Recipe", using="Item", times=3)
--   repeat 10:                                        dismantle("Item", times=2)
--   while <condition>:      while True:               wait(5)        stop_if(<condition>)    stop()
--   if <condition>:   elif <condition>:   else:       exercise("pushups", minutes=10)
--   when <condition>:   (top level: checked in the pauses between two actions)
--   rest(seat="nearest", until=95)   eat(open_cans=True)   drink()   smoke()   pass   break
--   repair("Item", using="Material")   sharpen("Item")   read("Book")          (wave 0 of the work skills, 13/11/2026)
--   conditions: has("Item", at_least=20), count("Item") >= 3, skill("Maintenance") < 4, hungry >= 2, thirsty,
--   stressed, bored, sad, pain, tired, panic (moodle levels 0-4; alone = at least 1), endurance (percent 0-100);
--   xp_gained("Maintenance") >= 100, condition("Item") < 15, has("Item", damaged=True), dark, hour >= 20,
--   known("Recipe")
--
-- Lang:check(text, resolver, opts) -> result
--   result.ops        the main flat program: ACTION / WAIT / LOOP / END / STOPIF / IF / JUMP, jumps already worked out
--   result.handlers   the "when" blocks: { line, cond, ops, moodles (set of MoodleType names), endurance }
--   result.problems   { line, text, warn, severity ("error" / "warning"), s, e, code, data } sorted by line, at most
--                     Lang.maxProblems; result.more = how many past them
--   result.errors, result.warnings   counts (errors block Run, warnings do not)
--   result.requirements  what each craft line needs ("Attrezzi e materiali", 4.5): { line, recipe (id), recipeText,
--                     materials, tools ({ text, amount, types, tags, sharp }), skills ({ skill, name, level }), text }
--   result.actionCount  actions of the main program;  result.uses = { rest = true, ... } the body actions used
--   result.notReady   the resolver's indexes are not built yet (nothing else is filled)
-- opts: player (for "you do not know the recipe yet"), maxActions, maxLoops (the server's limits, for the warnings),
-- ids = true to collect the name tokens and their ids (Lang:withIds, "Copia con gli id").
--
-- Operations (indexes into the same list; the handlers have lists of their own):
--   ACTION  line, kind "craft" / "exercise" / "rest" / "eat" / "drink" / "smoke" / "read", possibleFirst
--           craft: recipes (list), recipeText, withTypes, withText, dismantle, itemText; repair() and sharpen() are
--           craft actions too, with work = "repair" / "sharpen", the item in withTypes, materialText (using=)
--           exercise: exercise (the game's id), minutes;  rest: seat "nearest" / "ground", untilPct
--           eat / drink / smoke / read: itemTypes (list or nil), itemText, openCans (eat), amount (drink: 1 / 0.5 / 0.25)
--   WAIT    line, ms, seconds
--   LOOP    line, mode "times" / "possible" / "while" / "forever", n, cond, condText, endIndex, firstAction, synthetic
--   END     line, loopIndex
--   STOPIF  line, cond, plain (stop())
--   IF      line, cond, falseTarget (the op to go to when the condition is false)
--   JUMP    line, target
-- A condition is a small tree, evaluated by Run:evalCondition: { k = "const", v } / "has" (types, n, damaged) / "count"
-- (types) / "skill" (perk) / "moodle" (name) / "percent" (name) / "word" (name: dark, hour) / "xp" (perk) /
-- "condition" (types) / "known" (recipes) / "num" (v) / "not" (a) / "and" / "or" (a, b) / "cmp" (op, a, b); text = the
-- condition as written. result.xpPerks: the skills xp_gained() reads (their experience is noted at the start).
--
-- Kahlua: the file is ASCII; the accented and typographic characters are written as UTF-8 byte escapes, which the
-- game's Lua compiler decodes into one character each.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Lang = AutoPilotMoon.Macro.Lang or {};

local Lang = AutoPilotMoon.Macro.Lang;

-- limits of the text (constants of the mod, spec 2.1)
Lang.maxLines = 200;
Lang.maxLineChars = 160;
Lang.maxDepth = 3;           -- repeat / while one inside the other
Lang.maxBlocks = 4;          -- blocks of any kind one inside the other (a "when" or an "if" around 3 loops)
Lang.maxProblems = 20;
Lang.minNumber = 1;
Lang.maxNumber = 99999;
Lang.maxWaitSeconds = 60;
Lang.tabWidth = 4;
Lang.indent = "    ";        -- what the recorder and "Inserisci" write for one level

-- every moodle of 42.22 a condition can read (zombie.scripting.objects.MoodleType, all its constants but DEAD), one
-- English snake_case name each, levels 0-4 as the game shows them (0 = no moodle; "full" and "drunk" count up like
-- the others); grouped as the editor's "Inserisci > Condizione" shows them. Table in MACRO-AUTOPILOT.md 11.2.
Lang.moodleList = {
	{ name = "hungry", moodle = "HUNGRY", group = "food" },
	{ name = "thirsty", moodle = "THIRST", group = "food" },
	{ name = "full", moodle = "FOOD_EATEN", group = "food" },
	{ name = "drunk", moodle = "DRUNK", group = "food" },
	{ name = "exerted", moodle = "ENDURANCE", group = "tired" },
	{ name = "tired", moodle = "TIRED", group = "tired" },
	{ name = "heavy_load", moodle = "HEAVY_LOAD", group = "tired" },
	{ name = "restricted", moodle = "CANT_SPRINT", group = "tired" },
	{ name = "stressed", moodle = "STRESS", group = "mood" },
	{ name = "sad", moodle = "UNHAPPY", group = "mood" },
	{ name = "bored", moodle = "BORED", group = "mood" },
	{ name = "panic", moodle = "PANIC", group = "mood" },
	{ name = "angry", moodle = "ANGRY", group = "mood" },
	{ name = "pain", moodle = "PAIN", group = "health" },
	{ name = "sick", moodle = "SICK", group = "health" },
	{ name = "injured", moodle = "INJURED", group = "health" },
	{ name = "bleeding", moodle = "BLEEDING", group = "health" },
	{ name = "has_cold", moodle = "HAS_A_COLD", group = "health" },
	{ name = "zombified", moodle = "ZOMBIE", group = "health" },
	{ name = "hot", moodle = "HYPERTHERMIA", group = "weather" },
	{ name = "cold", moodle = "HYPOTHERMIA", group = "weather" },
	{ name = "wet", moodle = "WET", group = "weather" },
	{ name = "windchill", moodle = "WINDCHILL", group = "weather" },
	{ name = "uncomfortable", moodle = "UNCOMFORTABLE", group = "weather" },
	{ name = "smelly", moodle = "NOXIOUS_SMELL", group = "weather" },
};
Lang.moodleGroups = { "food", "tired", "mood", "health", "weather" };
Lang.moodles = {};

for i, entry in ipairs(Lang.moodleList)
do
	Lang.moodles[entry.name] = entry.moodle;
end

-- the numbers in percent (0-100) a condition can read: endurance (CharacterStat.ENDURANCE) and the smoker's craving
-- (CharacterStat.NICOTINE_WITHDRAWAL, 0-0.51 in the game, shown as 0-100); the game has no moodle for the craving
Lang.percents = { endurance = "tired", craving = "mood" };

-- the other words a condition can read alone (wave 0, 13/11/2026): value "bool" (true or false: alone, never
-- compared) or "number" (compared; low-high its range). dark: too dark for a recipe that is not done in the dark, the
-- game's own test (IsoPlayer.tooDarkToRead, the one that stops ISHandcraftAction and refuses "Read"); hour: the
-- game's hour, 0-23 (GameTime.getHour). Help IGUI_AutoPilot_E_Sug_Cond_<name>, label IGUI_AutoPilot_E_Cond_<name>.
Lang.condWordList = {
	{ name = "dark", value = "bool" },
	{ name = "hour", value = "number", low = 0, high = 23 },
};
Lang.condWords = {};

for i, entry in ipairs(Lang.condWordList)
do
	Lang.condWords[entry.name] = entry;
end

-- Italian words written by habit in a condition: the name to write
Lang.moodleItalian = {
	fame = "hungry", affamato = "hungry", sete = "thirsty", assetato = "thirsty", sazio = "full", ubriaco = "drunk",
	alticcio = "drunk", fatica = "exerted", affaticato = "exerted", resistenza = "endurance", sonno = "tired",
	stanco = "tired", stanchezza = "tired", assonnato = "tired", carico = "heavy_load", stress = "stressed",
	teso = "stressed", triste = "sad", tristezza = "sad", noia = "bored", annoiato = "bored", panico = "panic",
	paura = "panic", rabbia = "angry", irritato = "angry", dolore = "pain", nausea = "sick", malato = "sick",
	ferito = "injured", ferite = "injured", sangue = "bleeding", sanguinamento = "bleeding", raffreddore = "has_cold",
	caldo = "hot", freddo = "cold", bagnato = "wet", umido = "wet", vento = "windchill", disagio = "uncomfortable",
	puzza = "smelly", odore = "smelly", astinenza = "craving", voglia = "craving", fumo = "craving",
	unhappy = "sad", hunger = "hungry", thirst = "thirsty", nauseous = "sick", hyperthermia = "hot",
	hypothermia = "cold", food_eaten = "full", fatigue = "tired", sleepy = "tired", zombie = "zombified",
	cant_sprint = "restricted", heavyload = "heavy_load", hasacold = "has_cold",
	buio = "dark", scuro = "dark", notte = "dark", darkness = "dark", ora = "hour", orario = "hour", time = "hour",
};

-- the edit distance of two short words (the closest name of a word not known)
local function distance(a, b)
	local la, lb = string.len(a), string.len(b);
	local prev = {};

	for j = 0, lb
	do
		prev[j] = j;
	end

	for i = 1, la
	do
		local cur = { [0] = i };
		local ca = string.sub(a, i, i);

		for j = 1, lb
		do
			local cost = (ca == string.sub(b, j, j)) and 0 or 1;

			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
		end

		prev = cur;
	end

	return prev[lb];
end

-- the name a condition can read that is closest to a word (Italian words by habit too), or nil
function AutoPilotMoon.Macro.Lang:closestName(word)
	word = string.lower(word or "");

	if Lang.moodleItalian[word]
	then
		return Lang.moodleItalian[word];
	end

	local best, bestDistance = nil, 4;
	local candidates = {};

	for i, entry in ipairs(Lang.moodleList)
	do
		table.insert(candidates, entry.name);
	end

	for name in pairs(Lang.percents)
	do
		table.insert(candidates, name);
	end

	for i, entry in ipairs(Lang.condWordList)
	do
		table.insert(candidates, entry.name);
	end

	table.sort(candidates);

	for i, name in ipairs(candidates)
	do
		local d = distance(word, name);

		if string.len(word) >= 3 and string.find(name, word, 1, true) == 1
		then
			d = math.min(d, 1);
		end

		if d < bestDistance
		then
			best, bestDistance = name, d;
		end
	end

	-- a guess must be closer than half the word
	if best and bestDistance * 2 > string.len(word)
	then
		return nil;
	end

	return best;
end

-- the exercises of the game's Fitness window (shared/Definitions/FitnessExercises.lua of 42.22) and the minutes it offers
Lang.exercises = { "pushups", "situp", "squats", "burpees", "barbellcurl", "dumbbellpress", "bicepscurl" };
Lang.exerciseAlias = { situps = "situp", pushup = "pushups", squat = "squats", burpee = "burpees" };
Lang.exerciseMinutes = { [10] = true, [20] = true, [30] = true, [40] = true, [50] = true, [60] = true };
-- the amounts of drink(amount="...") and the seats of rest(seat="..."), in the order the editor's suggestions show them
Lang.drinkAmountList = { { name = "all", value = 1 }, { name = "half", value = 0.5 }, { name = "quarter", value = 0.25 } };
Lang.drinkAmounts = {};

for i, entry in ipairs(Lang.drinkAmountList)
do
	Lang.drinkAmounts[entry.name] = entry.value;
end

Lang.seats = { "nearest", "ground" };

-- the typographic quotes from a phone or Discord (left and right double quote, the two guillemets) and the
-- typographic apostrophe
local QUOTES = { "\226\128\156", "\226\128\157", "\194\171", "\194\187" };
local APOSTROPHE = "\226\128\153";

local function set(...)
	local t = {};

	for i, word in ipairs({ ... })
	do
		t[word] = true;
	end

	return t;
end

-- how each call is written: positional names, the keyword arguments with their kind, the required ones, the usage
-- shown in the errors (the script language is English: these are code, not translations); names: the kind of name a
-- text argument holds ("recipe", "item", "skill", "exercise", "seat", "amount": the editor's suggestions offer those
-- names inside its quotes, the checker resolves them the same way)
Lang.calls = {
	craft = { pos = { "recipe" }, kw = { recipe = "str", using = "str", times = "num" }, req = { "recipe" },
		usage = "craft(\"Recipe\", using=\"Item\", times=3)", action = true,
		names = { recipe = "recipe", using = "item" } },
	dismantle = { pos = { "item" }, kw = { item = "str", times = "num" }, req = { "item" },
		usage = "dismantle(\"Item\", times=3)", action = true, names = { item = "item" } },
	wait = { pos = { "seconds" }, kw = { seconds = "num" }, req = { "seconds" }, usage = "wait(5)" },
	stop_if = { pos = { "condition" }, kw = { condition = "cond" }, req = { "condition" }, usage = "stop_if(has(\"Item\", at_least=20))" },
	stop = { pos = {}, kw = {}, req = {}, usage = "stop()" },
	exercise = { pos = { "type" }, kw = { type = "str", minutes = "num" }, req = { "type" },
		usage = "exercise(\"pushups\", minutes=10)", action = true, names = { type = "exercise" } },
	rest = { pos = {}, kw = { seat = "str", ["until"] = "num" }, req = {}, usage = "rest(seat=\"nearest\", until=95)", action = true,
		names = { seat = "seat" } },
	eat = { pos = { "item" }, kw = { item = "str", open_cans = "bool" }, req = {}, usage = "eat(open_cans=True)", action = true,
		names = { item = "item" } },
	drink = { pos = { "item" }, kw = { item = "str", amount = "str" }, req = {}, usage = "drink(amount=\"half\")", action = true,
		names = { item = "item", amount = "amount" } },
	smoke = { pos = { "item" }, kw = { item = "str" }, req = {}, usage = "smoke()", action = true, names = { item = "item" } },
	-- wave 0 of the work skills (13/11/2026): the game's repairs and sharpenings of an item it keeps, and reading a
	-- book or a magazine as the inventory's "Read" does
	repair = { pos = { "item" }, kw = { item = "str", using = "str", times = "num" }, req = { "item" },
		usage = "repair(\"Item\", using=\"Material\")", action = true, names = { item = "item", using = "item" } },
	sharpen = { pos = { "item" }, kw = { item = "str", times = "num" }, req = { "item" }, usage = "sharpen(\"Item\")",
		action = true, names = { item = "item" } },
	read = { pos = { "item" }, kw = { item = "str" }, req = { "item" }, usage = "read(\"Book\")", action = true,
		names = { item = "item" } },
};

-- what a condition can call; value: "bool" (alone, true or false) or "number" (to compare); names "anyRecipe": every
-- recipe of the game, the workbenches' too (known() is about knowing, not doing)
Lang.condCalls = {
	has = { pos = { "item" }, kw = { item = "str", at_least = "num", damaged = "bool" }, req = { "item" },
		usage = "has(\"Item\", at_least=20)", names = { item = "item" }, value = "bool" },
	count = { pos = { "item" }, kw = { item = "str" }, req = { "item" }, usage = "count(\"Item\") >= 20", names = { item = "item" },
		value = "number" },
	skill = { pos = { "name" }, kw = { name = "str" }, req = { "name" }, usage = "skill(\"Maintenance\") < 4", names = { name = "skill" },
		value = "number" },
	xp_gained = { pos = { "name" }, kw = { name = "str" }, req = { "name" }, usage = "xp_gained(\"Maintenance\") >= 100",
		names = { name = "skill" }, value = "number" },
	condition = { pos = { "item" }, kw = { item = "str" }, req = { "item" }, usage = "condition(\"Item\") < 15",
		names = { item = "item" }, value = "number" },
	known = { pos = { "recipe" }, kw = { recipe = "str" }, req = { "recipe" }, usage = "known(\"Recipe\")",
		names = { recipe = "anyRecipe" }, value = "bool" },
};

-- The statements of a line other than the calls, as the editor's suggestions write them (MACRO-AUTOPILOT.md 4.12; the
-- reader reads them in parseHeader / parseLine, the colours colour their words as "keyword"): word, text = what is
-- written, caret = where the cursor goes in it (0-based; nil: at its end), block = a line ending with ":" whose body
-- line follows (a new line one level in), cond = a condition is written after it (the suggestions of a condition follow),
-- label = what the list shows when it is not the text, id = its help (IGUI_AutoPilot_E_Sug_Kw_<id>)
Lang.statementList = {
	{ word = "while", text = "while possible:", block = true, id = "while_possible" },
	{ word = "while", text = "while True:", block = true, id = "while_true" },
	{ word = "while", text = "while :", caret = 6, cond = true, label = "while ...:", id = "while_cond" },
	{ word = "repeat", text = "repeat 10:", block = true, id = "repeat" },
	{ word = "if", text = "if :", caret = 3, cond = true, label = "if ...:", id = "if" },
	{ word = "elif", text = "elif :", caret = 5, cond = true, label = "elif ...:", id = "elif" },
	{ word = "else", text = "else:", block = true, id = "else" },
	{ word = "when", text = "when :", caret = 5, cond = true, label = "when ...:", id = "when" },
	{ word = "break", text = "break", id = "break" },
	{ word = "pass", text = "pass", id = "pass" },
};

-- the words a condition can start with besides the moodles, the percents and the condition's calls (the editor's
-- suggestions, help IGUI_AutoPilot_E_Sug_Word_<word>); whileOnly: only right after "while" (while possible:)
Lang.conditionWords = {
	{ word = "not", text = "not " },
	{ word = "possible", text = "possible", whileOnly = true },
	{ word = "True", text = "True", whileOnly = true },
};

local BLOCK_WORDS = set("repeat", "while", "if", "elif", "else", "when", "for");
local CMP = set("<", "<=", ">", ">=", "==", "!=");
local END_WORDS = set("end", "fine", "endif", "endwhile", "done");

-- words of the old macros and of Italian written by habit: the English to write instead (the line's own conversion
-- is shown when the old line can be converted: AutoPilotMoon.Macro.Convert)
Lang.italian = {
	crea = "craft(\"...\")", smonta = "dismantle(\"...\")", ripeti = "repeat 10:  /  while possible:",
	aspetta = "wait(5)", fermati = "stop_if(...)", se = "if ...:", altrimenti = "else:", quando = "when ...:",
	mangia = "eat()", bevi = "drink()", fuma = "smoke()", riposa = "rest()", ["finch\195\169"] = "while ...:",
	finche = "while ...:", hai = "has(\"...\")", non = "not", e = "and", o = "or", allenati = "exercise(\"pushups\")",
	esercizio = "exercise(\"pushups\")", flessioni = "exercise(\"pushups\")", vero = "True", falso = "False",
	sempre = "while True:", altrimentise = "elif ...:", fai = "craft(\"...\")", ripara = "repair(\"...\")",
	affila = "sharpen(\"...\")", leggi = "read(\"...\")",
};

-- ============================================================================================================
-- Reading a line
-- ============================================================================================================

local function trim(s)
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"));
end

Lang.trim = trim;

-- a tab as Lang.tabWidth spaces, typographic quotes as '"', the typographic apostrophe as "'"
local function normalize(line)
	line = string.gsub(line, "\t", string.rep(" ", Lang.tabWidth));
	line = string.gsub(line, "\r", "");

	for i, quote in ipairs(QUOTES)
	do
		line = string.gsub(line, quote, "\"");
	end

	line = string.gsub(line, APOSTROPHE, "'");

	return line;
end

Lang.normalize = normalize;

-- the line without its comment: "#" up to the end, unless inside quotes ("..." or '...')
local function stripComment(line)
	local quote = nil;

	for i = 1, string.len(line)
	do
		local c = string.sub(line, i, i);

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
			return string.sub(line, 1, i - 1), string.sub(line, i);
		end
	end

	return line, nil;
end

Lang.stripComment = stripComment;

local function isNameStart(c)
	local b = string.byte(c);

	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or c == "_" or b >= 128;
end

local function isNameChar(c)
	local b = string.byte(c);

	return isNameStart(c) or (b >= 48 and b <= 57) or c == ".";
end

Lang.isNameChar = isNameChar;

-- a line one character for one: a tab or a carriage return as a space, the typographic quotes as '"' and the
-- apostrophe as "'" (each is one character of the game's strings), so the positions stay those of the line shown (the
-- colours, the editor's suggestions)
function AutoPilotMoon.Macro.Lang.plainLine(raw)
	local line = string.gsub(raw or "", "[\t\r]", " ");

	for i, quote in ipairs(QUOTES)
	do
		line = string.gsub(line, quote, "\"");
	end

	line = string.gsub(line, APOSTROPHE, "'");

	return line;
end

-- the tokens of a line: { k = "str" / "num" / "name" / "sym", text, lower, s, e } (s, e: positions in the line, the
-- quotes included for a "str"); nil and "quote" when a quote is not closed, then the tokens before it and the quote's
-- position (the editor's colours: the rest of the line is a text being written)
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
		elseif c == "\"" or c == "'"
		then
			local close = string.find(line, c, i + 1, true);

			if close == nil
			then
				return nil, "quote", tokens, i;
			end

			local text = trim(string.sub(line, i + 1, close - 1));

			table.insert(tokens, { k = "str", text = text, lower = string.lower(text), s = i, e = close });
			i = close + 1;
		elseif isNameChar(c)
		then
			local j = i;

			while j <= n and isNameChar(string.sub(line, j, j))
			do
				j = j + 1;
			end

			local text = string.sub(line, i, j - 1);
			local k = "name";

			if string.find(text, "^%d+$")
			then
				k = "num";
			end

			table.insert(tokens, { k = k, text = text, lower = string.lower(text), s = i, e = j - 1 });
			i = j;
		else
			local two = string.sub(line, i, i + 1);
			local text = c;

			if two == "<=" or two == ">=" or two == "==" or two == "!="
			then
				text = two;
			end

			table.insert(tokens, { k = "sym", text = text, lower = text, s = i, e = i + string.len(text) - 1 });
			i = i + string.len(text);
		end
	end

	return tokens, nil;
end

Lang.tokenize = tokenize;

local function indentOf(line)
	local spaces = string.match(line, "^( *)") or "";

	return string.len(spaces);
end

-- ============================================================================================================
-- Problems
-- ============================================================================================================

-- A problem: { line, text, warn, severity, s, e, code, data }. severity "error" (blocks Run) or "warning" (shown, never
-- blocks); warn = (severity == "warning"), kept for the readers written before severity. token (optional): the word the
-- problem is about; its place in the line read (problem.s, problem.e) is what the editor underlines, red for an error,
-- amber for a warning. code / data (optional, the warnings of 2.9): what the warning is about, for the programs that
-- read the problems (ZomBOT): "ambiguousItem" / "ambiguousRecipe" / "unchosenMaterial" and their data.
local function addProblem(result, line, text, warn, token, code, data)
	if warn
	then
		result.warnings = result.warnings + 1;
		text = getText("IGUI_AutoPilot_E_P_Warn", text);
	else
		result.errors = result.errors + 1;
	end

	table.insert(result.all, { line = line, text = text, warn = warn == true, severity = warn and "warning" or "error",
		s = token and token.s or nil, e = token and token.e or nil, code = code, data = data });
end

-- an error of the line being read; only the first one of a line (one mistake, one message); token: the word it is
-- about (optional)
local function lineError(ctx, text, token)
	if ctx.lineFailed
	then
		return;
	end

	ctx.lineFailed = true;
	addProblem(ctx.result, ctx.line, text, false, token);
end

local function warn(ctx, text, token, code, data)
	addProblem(ctx.result, ctx.line, text, true, token, code, data);
end

-- "Forse: "a", "b"" appended to a "not found" problem
local function withMaybe(text, suggestions)
	if suggestions and #suggestions > 0
	then
		local quoted = {};

		for i, name in ipairs(suggestions)
		do
			table.insert(quoted, "\"" .. name .. "\"");
		end

		return text .. ". " .. getText("IGUI_AutoPilot_E_P_Maybe", table.concat(quoted, ", "));
	end

	return text;
end

-- the text of the line from token k to token last (default: the end)
local function textOf(ctx, k, last)
	local first = ctx.tokens[k];

	if first == nil
	then
		return "";
	end

	local stop = last and ctx.tokens[last] and ctx.tokens[last].e or string.len(ctx.code);

	return trim(string.sub(ctx.code, first.s, stop));
end

local function noteId(ctx, token, kind, id)
	if ctx.ids and token and id
	then
		table.insert(ctx.ids, { line = ctx.line, s = token.s, e = token.e, id = id, kind = kind });
	end
end

-- an item name: the set of its full types, or nil (the problem is added)
local function resolveItem(ctx, token)
	local types, suggestions = ctx.resolver:resolveItem(token.text);

	if types == nil
	then
		lineError(ctx, withMaybe(getText("IGUI_AutoPilot_E_P_UnknownItem", ctx.line, token.text), suggestions), token);

		return nil;
	end

	if #types == 1
	then
		noteId(ctx, token, "item", types[1]);
	end

	return types;
end

-- ============================================================================================================
-- Warnings about names that stand for several things, and what a recipe needs (2.9, 4.5)
-- ============================================================================================================

Lang.kindOrder = { "food", "seed", "container" };
Lang.maxSuggested = 3;      -- names or types a warning keeps in its data (the text shows the first)

local function quoted(text)
	return "\"" .. text .. "\"";
end

-- "a", "a o b", "a, b o c"
local function joinOr(list)
	if #list <= 1
	then
		return list[1] or "";
	end

	local head = {};

	for i = 1, #list - 1
	do
		table.insert(head, list[i]);
	end

	return getText("IGUI_AutoPilot_E_Or", table.concat(head, ", "), list[#list]);
end

-- the kinds among the types the resolver knows (food, seeds, containers): their words ("cibo e semi") and their list,
-- or nil and an empty list
local function kindsOf(resolver, types)
	local kinds = {};

	if resolver.itemKind == nil
	then
		return nil, kinds;
	end

	local has = {};

	for i, fullType in ipairs(types)
	do
		local kind = resolver:itemKind(fullType);

		if kind
		then
			has[kind] = true;
		end
	end

	local words = {};

	for i, kind in ipairs(Lang.kindOrder)
	do
		if has[kind]
		then
			table.insert(kinds, kind);
			table.insert(words, getText("IGUI_AutoPilot_E_Kind_" .. kind));
		end
	end

	if #words == 0
	then
		return nil, kinds;
	end

	if #words == 1
	then
		return words[1], kinds;
	end

	local last = table.remove(words);

	return getText("IGUI_AutoPilot_E_Kind_And", table.concat(words, ", "), last), kinds;
end

-- one of the recipes uses up this type
local function takenBy(resolver, recipes, fullType)
	for i, recipe in ipairs(recipes)
	do
		if resolver:acceptsAny(recipe, { fullType })
		then
			return true;
		end
	end

	return false;
end

-- what to write for one type: its name when no other type has it, else the type itself
local function writable(resolver, fullType)
	local same = resolver.typesWithSameName and resolver:typesWithSameName(fullType) or nil;

	if same and #same == 1
	then
		return resolver:itemName(fullType);
	end

	return fullType;
end

-- the types in the order a suggestion takes them (the resolver's, else as they are)
local function ranked(resolver, types)
	return resolver.rankTypes and resolver:rankTypes(types) or types;
end

-- An item name that stands for several types (2.9). relevant: the types that matter on this line (those the recipes
-- take; all of them for has / count); use: "use" (craft using=, dismantle: the macro takes the first it finds) or
-- "count" (has, count: all counted together); recipes / recipeText: the line's recipes and the recipe as written (for
-- a name of one item they take, and the other recipe a similar name goes with). Nothing when fewer than 2 matter.
local function warnAmbiguousItem(ctx, token, types, relevant, use, recipes, recipeText)
	if #relevant < 2
	then
		return;
	end

	local resolver = ctx.resolver;
	local text;

	if #relevant < #types
	then
		text = getText("IGUI_AutoPilot_E_P_AmbiguousItemFor", ctx.line, token.text, #types, #relevant);
	else
		text = getText("IGUI_AutoPilot_E_P_AmbiguousItem", ctx.line, token.text, #types);
	end

	local kindText, kinds = kindsOf(resolver, relevant);

	if kindText
	then
		text = text .. getText("IGUI_AutoPilot_E_P_Including", kindText);
	end

	-- what the macro does with them: the first it finds ("use"), all counted together ("count"), the best condition
	-- among all of them ("best", condition())
	local what = { use = "IGUI_AutoPilot_E_P_FirstFound", count = "IGUI_AutoPilot_E_P_CountsAll", best = "IGUI_AutoPilot_E_P_BestOfAll" };
	local writeOne = { use = "IGUI_AutoPilot_E_P_WriteOne", count = "IGUI_AutoPilot_E_P_CountOne", best = "IGUI_AutoPilot_E_P_WatchOne" };

	text = text .. getText(what[use]);

	-- what to write: a name of one item the recipes take, then the game's types
	local suggestions = {};

	if use == "use" and recipes and resolver.uniqueNamesLike
	then
		local found = resolver:uniqueNamesLike(token.text, function(fullType)
			return takenBy(resolver, recipes, fullType);
		end, Lang.maxSuggested);

		for i, entry in ipairs(found)
		do
			table.insert(suggestions, entry.text);
		end
	end

	for i, fullType in ipairs(ranked(resolver, relevant))
	do
		if #suggestions >= Lang.maxSuggested
		then
			break;
		end

		table.insert(suggestions, fullType);
	end

	text = text .. getText(writeOne[use], quoted(suggestions[1]));

	-- a similar name of one item that another recipe takes: "Sacco di juta" goes with "Strappa sacco grande" (the
	-- incident of 12/11/2026: the macro meant the jute sack, which "Strappa sacco" does not take)
	local other = nil;

	if use == "use" and recipes and recipeText and resolver.uniqueNamesLike and resolver.recipesAccepting
	then
		local similar = resolver:uniqueNamesLike(token.text, function(fullType)
			return not takenBy(resolver, recipes, fullType);
		end, 10);

		for i, entry in ipairs(similar)
		do
			local found = resolver:recipesAccepting({ entry.fullType }, recipeText, 1);

			if found[1]
			then
				other = { item = entry.text, recipe = found[1] };
				text = text .. getText("IGUI_AutoPilot_E_P_GoesWith", entry.text, found[1]);

				break;
			end
		end
	end

	warn(ctx, text, token, "ambiguousItem", { name = token.text, use = use, types = relevant, allTypes = types,
		kinds = kinds, suggestions = suggestions, otherRecipe = other });
end

-- craft("R") without using= (2.9): a material the recipe uses up that can be 2 or more types, food, seeds or a
-- container among them. The macro takes the first one it finds (2.5), maybe the sack of seeds. Once per line.
local function warnUnchosen(ctx, token, recipes)
	local resolver = ctx.resolver;

	if resolver.inputSlots == nil or resolver.itemKind == nil
	then
		return;
	end

	for i, recipe in ipairs(recipes)
	do
		for j, slot in ipairs(resolver:inputSlots(recipe))
		do
			if not slot.keep and #slot.types >= 2
			then
				local kindText, kinds = kindsOf(resolver, slot.types);

				if kindText
				then
					local suggestions = {};

					for k, fullType in ipairs(ranked(resolver, slot.types))
					do
						if #suggestions >= Lang.maxSuggested
						then
							break;
						end

						table.insert(suggestions, writable(resolver, fullType));
					end

					local text = getText("IGUI_AutoPilot_E_P_Unchosen", ctx.line, token.text, #slot.types) ..
						getText("IGUI_AutoPilot_E_P_Including", kindText) .. getText("IGUI_AutoPilot_E_P_TakesFirst") ..
						getText("IGUI_AutoPilot_E_P_SayWhich", token.text, suggestions[1]);

					warn(ctx, text, token, "unchosenMaterial", { recipe = resolver:recipeId(recipe), types = slot.types,
						tags = slot.tags, kinds = kinds, suggestions = suggestions });

					return;
				end
			end
		end
	end
end

-- one input in words: the one name of its types ("Sacco"), else the words of its tags ("coltello affilato o forbici"),
-- else two names and how many more; "x2" for more than one
local function slotText(resolver, slot)
	local names = {};
	local seen = {};

	for i, fullType in ipairs(slot.types)
	do
		local name = resolver:itemName(fullType);

		if not seen[name]
		then
			seen[name] = true;
			table.insert(names, name);
		end
	end

	local text = names[1] or "?";

	if #names > 1
	then
		local tagWords = nil;

		if #slot.tags > 0
		then
			tagWords = {};

			for i, tag in ipairs(slot.tags)
			do
				local word = getTextOrNull("IGUI_AutoPilot_E_Tag_" .. (string.match(tag, ":(.+)$") or tag));

				if word == nil
				then
					tagWords = nil;

					break;
				end

				table.insert(tagWords, word);
			end
		end

		if tagWords
		then
			text = joinOr(tagWords);
		elseif #names > 2
		then
			text = joinOr({ names[1], names[2], getText("IGUI_AutoPilot_E_OtherItems", #names - 2) });
		else
			text = joinOr(names);
		end
	end

	if slot.amount > 1
	then
		text = text .. " x" .. tostring(slot.amount);
	end

	return text;
end

-- what a craft line needs ("Attrezzi e materiali", 4.5): the materials it uses up, the tools it keeps, the skills, in
-- data (for ZomBOT) and in words; nil when the resolver cannot say (it has no inputSlots). The item a repair or a
-- sharpening works on (slot.target) is not a tool: entry.target, "su ..." (targetText: the item of the line, when the
-- line names it). alternatives: the other recipes of a repair() / sharpen() line, in the order the macro tries them
-- (entry.alternatives = their ids, "oppure: ..." with their names).
local function requirementsOf(ctx, recipe, recipeText, targetText, alternatives)
	local resolver = ctx.resolver;

	if resolver.inputSlots == nil
	then
		return nil;
	end

	local entry = { line = ctx.line, recipe = resolver:recipeId(recipe), recipeText = recipeText, materials = {}, tools = {},
		skills = {} };
	local materialWords = {};
	local toolWords = {};
	local skillWords = {};
	local targetWords = {};

	for i, slot in ipairs(resolver:inputSlots(recipe))
	do
		local text = slotText(resolver, slot);
		local item = { text = text, amount = slot.amount, types = slot.types, tags = slot.tags, sharp = slot.sharp };

		if slot.target
		then
			item.text = targetText or text;
			item.damaged = slot.damaged;
			item.sharpenable = slot.sharpenable;
			entry.target = item;
			table.insert(targetWords, item.text);
		elseif slot.keep
		then
			table.insert(entry.tools, item);
			table.insert(toolWords, text);
		else
			table.insert(entry.materials, item);
			table.insert(materialWords, text);
		end
	end

	local skills = resolver.requiredSkills and resolver:requiredSkills(recipe) or {};

	for i, required in ipairs(skills)
	do
		local name = required.perk:getName();

		table.insert(entry.skills, { skill = resolver:skillId(required.perk) or name, name = name, level = required.level });
		table.insert(skillWords, name .. " " .. tostring(required.level));
	end

	local parts = {};

	if #targetWords > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsOn", table.concat(targetWords, ", ")));
	end

	if #materialWords > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsUses", table.concat(materialWords, ", ")));
	end

	if #toolWords > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsTools", table.concat(toolWords, ", ")));
	end

	if #skillWords > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsSkills", table.concat(skillWords, ", ")));
	end

	if #parts == 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsNothing"));
	end

	if alternatives and #alternatives > 0
	then
		local names = {};

		entry.alternatives = {};

		for i, other in ipairs(alternatives)
		do
			table.insert(entry.alternatives, resolver:recipeId(other));
			table.insert(names, resolver:recipeName(other));
		end

		table.insert(parts, getText("IGUI_AutoPilot_E_NeedsOr", table.concat(names, ", ")));
	end

	entry.text = getText("IGUI_AutoPilot_E_Needs", ctx.line, recipeText, table.concat(parts, "; "));

	return entry;
end

-- ============================================================================================================
-- Expressions: values, calls, conditions (recursive descent over the tokens of one line)
-- ============================================================================================================

local function peek(p, d)
	local i = p.i + (d or 0);

	if p.stop and i > p.stop
	then
		return nil;
	end

	return p.t[i];
end

local function isSym(token, text)
	return token ~= nil and token.k == "sym" and token.text == text;
end

local parseOr;

-- the arguments of a call after its "(": { pos = { node... }, kw = { name = node }, kwTokens }, the index after ")"
local function parseArgs(p)
	local args = { pos = {}, kw = {}, kwTokens = {} };

	if isSym(peek(p), ")")
	then
		p.i = p.i + 1;

		return args;
	end

	while true
	do
		local token = peek(p);

		if token and token.k == "name" and isSym(peek(p, 1), "=")
		then
			p.i = p.i + 2;

			local value = parseOr(p);

			if value == nil
			then
				return nil;
			end

			args.kw[token.lower] = value;
			args.kwTokens[token.lower] = token;
		else
			local value = parseOr(p);

			if value == nil
			then
				return nil;
			end

			table.insert(args.pos, value);
		end

		local after = peek(p);

		if isSym(after, ",")
		then
			p.i = p.i + 1;
		elseif isSym(after, ")")
		then
			p.i = p.i + 1;

			return args;
		else
			p.err = after == nil and "paren" or "syntax";

			return nil;
		end
	end
end

local function parseValue(p)
	local token = peek(p);

	if token == nil
	then
		p.err = "syntax";

		return nil;
	end

	p.i = p.i + 1;

	if token.k == "num"
	then
		return { k = "num", v = tonumber(token.text), tok = token };
	elseif token.k == "str"
	then
		return { k = "str", v = token.text, tok = token };
	elseif token.k == "name"
	then
		if token.lower == "true" or token.lower == "false"
		then
			return { k = "bool", v = token.lower == "true", tok = token };
		end

		if isSym(peek(p), "(")
		then
			p.i = p.i + 1;

			local args = parseArgs(p);

			if args == nil
			then
				return nil;
			end

			return { k = "call", fn = token.lower, args = args, tok = token, last = p.i - 1 };
		end

		return { k = "name", v = token.text, lower = token.lower, tok = token };
	elseif isSym(token, "(")
	then
		local inner = parseOr(p);

		if inner == nil
		then
			return nil;
		end

		if not isSym(peek(p), ")")
		then
			p.err = "paren";

			return nil;
		end

		p.i = p.i + 1;

		return inner;
	end

	p.err = isSym(token, "=") and "equals" or "syntax";
	p.errToken = token;

	return nil;
end

local function parseCmp(p)
	local a = parseValue(p);

	if a == nil
	then
		return nil;
	end

	local op = peek(p);

	if op and op.k == "sym" and CMP[op.text]
	then
		p.i = p.i + 1;

		local b = parseValue(p);

		if b == nil
		then
			return nil;
		end

		local after = peek(p);

		if after and after.k == "sym" and CMP[after.text]
		then
			p.err = "chain";

			return nil;
		end

		return { k = "cmp", op = op.text, a = a, b = b, tok = op };
	end

	if isSym(op, "=")
	then
		p.err = "equals";

		return nil;
	end

	return a;
end

local function parseNot(p)
	local token = peek(p);

	if token and token.k == "name" and token.lower == "not"
	then
		p.i = p.i + 1;

		local a = parseNot(p);

		if a == nil
		then
			return nil;
		end

		return { k = "not", a = a, tok = token };
	end

	return parseCmp(p);
end

local function parseAnd(p)
	local a = parseNot(p);

	while a and peek(p) and peek(p).k == "name" and peek(p).lower == "and"
	do
		p.i = p.i + 1;

		local b = parseNot(p);

		if b == nil
		then
			return nil;
		end

		a = { k = "and", a = a, b = b };
	end

	return a;
end

parseOr = function(p)
	local a = parseAnd(p);

	while a and peek(p) and peek(p).k == "name" and peek(p).lower == "or"
	do
		p.i = p.i + 1;

		local b = parseAnd(p);

		if b == nil
		then
			return nil;
		end

		a = { k = "or", a = a, b = b };
	end

	return a;
end

-- the message of a parse that failed (p.err)
local function syntaxError(ctx, p, usage, from, to)
	if p.err == "equals"
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_SingleEquals", ctx.line));
	elseif p.err == "paren"
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_MissingParen", ctx.line));
	elseif usage
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, usage));
	else
		lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, textOf(ctx, from or 1, to)));
	end
end

-- the arguments of a call by name, checked against its spec: { name = node }, or nil (the problem is added)
local function bindArgs(ctx, name, spec, args)
	local bound = {};

	for i, node in ipairs(args.pos)
	do
		local key = spec.pos[i];

		if key == nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return nil;
		end

		bound[key] = node;
	end

	for key, node in pairs(args.kw)
	do
		if spec.kw[key] == nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadArg", ctx.line, name, args.kwTokens[key].text, spec.usage), args.kwTokens[key]);

			return nil;
		end

		if bound[key] ~= nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return nil;
		end

		bound[key] = node;
	end

	for i, key in ipairs(spec.req)
	do
		if bound[key] == nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return nil;
		end
	end

	-- the kinds: a name always in quotes, numbers, True / False
	for key, node in pairs(bound)
	do
		local kind = spec.kw[key];

		if kind == "str" and node.k ~= "str"
		then
			if node.k == "name"
			then
				lineError(ctx, getText("IGUI_AutoPilot_E_P_NeedQuotes", ctx.line, node.v), node.tok);
			else
				lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));
			end

			return nil;
		elseif kind == "num" and node.k ~= "num"
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return nil;
		elseif kind == "bool" and node.k ~= "bool"
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return nil;
		end
	end

	return bound;
end

local function checkNumber(ctx, n, low, high)
	if n == nil or n < low or n > high
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_BadNumber", ctx.line, low, high));

		return false;
	end

	return true;
end

local compileBool;

-- a word a condition does not know: the closest name when there is one
local function unknownName(ctx, word, token)
	local closest = Lang:closestName(word);
	local text = getText("IGUI_AutoPilot_E_P_UnknownName", ctx.line, word);

	if closest
	then
		text = text .. ". " .. getText("IGUI_AutoPilot_E_P_Maybe", closest);
	end

	lineError(ctx, text, token);
end

-- a node as a number: { k = "num" / "moodle" / "endurance" / "count" / "skill" }, or nil
local function compileNum(ctx, node)
	if node.k == "num"
	then
		return { k = "num", v = node.v };
	elseif node.k == "name"
	then
		if Lang.moodles[node.lower]
		then
			ctx.moodlesSeen[Lang.moodles[node.lower]] = true;

			return { k = "moodle", name = Lang.moodles[node.lower], word = node.lower };
		elseif Lang.percents[node.lower]
		then
			if node.lower == "endurance"
			then
				ctx.moodlesSeen.ENDURANCE = true;
			end

			return { k = "percent", name = node.lower };
		elseif Lang.condWords[node.lower]
		then
			if Lang.condWords[node.lower].value == "number"
			then
				return { k = "word", name = node.lower };
			end

			-- dark compared: it is true or false
			lineError(ctx, getText("IGUI_AutoPilot_E_P_NotNumber", ctx.line, node.v), node.tok);

			return nil;
		end

		unknownName(ctx, node.v, node.tok);

		return nil;
	elseif node.k == "call"
	then
		local spec = Lang.condCalls[node.fn];

		if spec == nil or spec.value == "bool"
		then
			if spec == nil
			then
				lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownName", ctx.line, node.tok.text), node.tok);
			elseif node.fn == "has"
			then
				-- has() compared: count() is the number
				lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, Lang.condCalls.count.usage));
			else
				lineError(ctx, getText("IGUI_AutoPilot_E_P_NotNumber", ctx.line, node.tok.text), node.tok);
			end

			return nil;
		end

		local bound = bindArgs(ctx, node.fn, spec, node.args);

		if bound == nil
		then
			return nil;
		end

		if node.fn == "count" or node.fn == "condition"
		then
			local types = resolveItem(ctx, bound.item.tok);

			if types
			then
				warnAmbiguousItem(ctx, bound.item.tok, types, types, node.fn == "count" and "count" or "best");
			end

			if types == nil
			then
				return nil;
			end

			return { k = node.fn, types = types };
		end

		local perk = ctx.resolver:resolveSkill(bound.name.v);

		if perk == nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownSkill", ctx.line, bound.name.v), bound.name.tok);

			return nil;
		end

		noteId(ctx, bound.name.tok, "skill", ctx.resolver:skillId(perk));

		if node.fn == "xp_gained"
		then
			-- the skills whose experience the run notes at its start (xp_gained counts from there)
			local list = ctx.result.xpPerks;
			local seen = false;

			for i, other in ipairs(list)
			do
				seen = seen or other == perk;
			end

			if not seen
			then
				table.insert(list, perk);
			end

			return { k = "xp", perk = perk };
		end

		return { k = "skill", perk = perk };
	end

	lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, textOf(ctx, ctx.condFrom, ctx.condTo)));

	return nil;
end

-- an example of how to compare a number ("hungry >= 2", "skill("Maintenance") < 4")
local function compareExample(ctx, node)
	if node.k == "call"
	then
		return textOf(ctx, ctx.tokenIndex[node.tok], node.last) .. " >= 1";
	end

	if node.lower and Lang.condWords[node.lower]
	then
		-- hour: an hour of the game
		return node.v .. " >= 20";
	end

	return (node.v or node.tok.text) .. " < 30";
end

-- a node as a condition, or nil
compileBool = function(ctx, node)
	if node.k == "bool"
	then
		return { k = "const", v = node.v };
	elseif node.k == "not"
	then
		local a = compileBool(ctx, node.a);

		return a and { k = "not", a = a } or nil;
	elseif node.k == "and" or node.k == "or"
	then
		local a = compileBool(ctx, node.a);
		local b = a and compileBool(ctx, node.b);

		return b and { k = node.k, a = a, b = b } or nil;
	elseif node.k == "cmp"
	then
		local a = compileNum(ctx, node.a);
		local b = a and compileNum(ctx, node.b);

		return b and { k = "cmp", op = node.op, a = a, b = b } or nil;
	elseif node.k == "name" and Lang.moodles[node.lower]
	then
		-- a moodle alone: at least level 1
		ctx.moodlesSeen[Lang.moodles[node.lower]] = true;

		return { k = "cmp", op = ">=", a = { k = "moodle", name = Lang.moodles[node.lower], word = node.lower }, b = { k = "num", v = 1 } };
	elseif node.k == "name" and Lang.condWords[node.lower] and Lang.condWords[node.lower].value == "bool"
	then
		-- dark: alone
		return { k = "word", name = node.lower };
	elseif node.k == "call" and node.fn == "has"
	then
		local bound = bindArgs(ctx, "has", Lang.condCalls.has, node.args);

		if bound == nil
		then
			return nil;
		end

		local n = 1;

		if bound.at_least
		then
			n = bound.at_least.v;

			if not checkNumber(ctx, n, Lang.minNumber, Lang.maxNumber)
			then
				return nil;
			end
		end

		local types = resolveItem(ctx, bound.item.tok);

		if types
		then
			warnAmbiguousItem(ctx, bound.item.tok, types, types, "count");
		end

		-- damaged=True: only the damaged ones the macro may work on (condition below the most, never a favourite, an
		-- equipped or a worn one: what repair() takes)
		return types and { k = "has", types = types, n = n, damaged = bound.damaged ~= nil and bound.damaged.v == true } or nil;
	elseif node.k == "call" and node.fn == "known"
	then
		local bound = bindArgs(ctx, "known", Lang.condCalls.known, node.args);

		if bound == nil
		then
			return nil;
		end

		-- any recipe of the game, a workbench's too: known() is about knowing it, not about doing it here
		local token = bound.recipe.tok;
		local recipes, suggestions = ctx.resolver:resolveRecipe(token.text);

		if recipes == nil
		then
			lineError(ctx, withMaybe(getText("IGUI_AutoPilot_E_P_UnknownRecipe", ctx.line, token.text), suggestions), token);

			return nil;
		end

		if #recipes == 1
		then
			noteId(ctx, token, "recipe", ctx.resolver:recipeId(recipes[1]));
		end

		return { k = "known", recipes = recipes };
	elseif node.k == "num" or (node.k == "name" and (Lang.percents[node.lower] or Lang.condWords[node.lower]))
		or (node.k == "call" and Lang.condCalls[node.fn])
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_CompareIt", ctx.line, node.k == "call" and node.tok.text or (node.v and tostring(node.v)) or node.tok.text,
			compareExample(ctx, node)));

		return nil;
	elseif node.k == "name"
	then
		unknownName(ctx, node.v, node.tok);

		return nil;
	elseif node.k == "call"
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownName", ctx.line, node.tok.text), node.tok);

		return nil;
	end

	lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, textOf(ctx, ctx.condFrom, ctx.condTo)));

	return nil;
end

-- the condition in the tokens from k to last (both included): the compiled tree with its text, or nil
local function parseCondition(ctx, k, last)
	if k > last
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, ""));

		return nil;
	end

	local p = { t = ctx.tokens, i = k, stop = last };
	local node = parseOr(p);

	ctx.condFrom = k;
	ctx.condTo = last;

	if node == nil or p.i <= last
	then
		if node and p.err == nil
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, textOf(ctx, k, last)));
		else
			syntaxError(ctx, p, nil, k, last);
		end

		return nil;
	end

	local cond = compileBool(ctx, node);

	if cond
	then
		cond.text = textOf(ctx, k, last);
	end

	return cond;
end

-- ============================================================================================================
-- The program: operations, blocks, indentation
-- ============================================================================================================

local function addOp(ctx, op)
	op.line = op.line or ctx.line;
	table.insert(ctx.ops, op);

	return #ctx.ops;
end

-- the frames are the bodies being read: frames[1] is the macro itself; each other frame is the body of a block
local function loopDepth(ctx)
	local depth = 0;

	for i, frame in ipairs(ctx.frames)
	do
		if frame.block and frame.block.kind == "loop"
		then
			depth = depth + 1;
		end
	end

	return depth;
end

local function finalizeChain(ctx, frame)
	local chain = frame.chain;

	if chain
	then
		for i, index in ipairs(chain.endJumps)
		do
			chain.ops[index].target = #chain.ops + 1;
		end

		frame.chain = nil;
	end
end

local function closeLoopOp(ctx, loopIndex, block)
	local ops = ctx.ops;
	local endIndex = addOp(ctx, { op = "END", loopIndex = loopIndex });
	local loop = ops[loopIndex];

	loop.endIndex = endIndex;

	for i = loopIndex + 1, endIndex - 1
	do
		if ops[i].op == "ACTION"
		then
			loop.firstAction = i;

			break;
		end
	end

	if loop.firstAction == nil and not loop.synthetic and not (block and block.emptySaid)
	then
		addProblem(ctx.result, loop.line, getText("IGUI_AutoPilot_E_P_EmptyLoop", loop.line));
	end

	if loop.mode == "possible" and loop.firstAction
	then
		ops[loop.firstAction].possibleFirst = true;
	end

	for i, index in ipairs(block and block.breaks or {})
	do
		ops[index].target = endIndex + 1;
	end
end

-- the body of a block ends (the indentation went back, or the text ended)
local function closeFrame(ctx)
	local frame = table.remove(ctx.frames);
	local block = frame.block;
	local parent = ctx.frames[#ctx.frames];

	finalizeChain(ctx, frame);

	if block.kind == "loop"
	then
		closeLoopOp(ctx, block.opIndex, block);
	elseif block.kind == "if"
	then
		local jump = addOp(ctx, { op = "JUMP", line = block.line });

		table.insert(parent.chain.endJumps, jump);
		ctx.ops[block.opIndex].falseTarget = #ctx.ops + 1;
	elseif block.kind == "else"
	then
		finalizeChain(ctx, parent);
	elseif block.kind == "when"
	then
		local handler = block.handler;

		if handler.actionCount == 0 and not handler.stops and not block.emptySaid
		then
			addProblem(ctx.result, handler.line, getText("IGUI_AutoPilot_E_P_WhenEmpty", handler.line));
		end

		ctx.ops = ctx.mainOps;
		ctx.handler = nil;
	end
end

-- a header read: the next code line must be indented under it
local function openBlock(ctx, block)
	if ctx.depthSaid ~= true
	then
		if block.kind == "loop" and loopDepth(ctx) + 1 > Lang.maxDepth
		then
			ctx.depthSaid = true;
			addProblem(ctx.result, ctx.line, getText("IGUI_AutoPilot_E_P_TooDeep", ctx.line, Lang.maxDepth));
		elseif #ctx.frames > Lang.maxBlocks
		then
			ctx.depthSaid = true;
			addProblem(ctx.result, ctx.line, getText("IGUI_AutoPilot_E_P_TooDeepBlocks", ctx.line, Lang.maxBlocks));
		end
	end

	block.line = ctx.line;
	ctx.expect = block;
end

-- the indentation of a code line against the open blocks (Python's rules); returns nothing, problems are added
local function handleIndent(ctx, indent)
	local top = ctx.frames[#ctx.frames];

	if ctx.expect
	then
		local block = ctx.expect;

		ctx.expect = nil;

		if indent > top.indent
		then
			table.insert(ctx.frames, { indent = indent, block = block });

			return;
		end

		-- the block has no body: said once, then closed empty
		addProblem(ctx.result, ctx.line, getText("IGUI_AutoPilot_E_P_ExpectIndent", ctx.line, block.line));
		block.emptySaid = true;
		table.insert(ctx.frames, { indent = top.indent + 1, block = block });
		closeFrame(ctx);
		top = ctx.frames[#ctx.frames];
	end

	if indent > top.indent
	then
		addProblem(ctx.result, ctx.line, getText("IGUI_AutoPilot_E_P_UnexpectedIndent", ctx.line));

		return;
	end

	while indent < ctx.frames[#ctx.frames].indent
	do
		closeFrame(ctx);
	end

	if indent ~= ctx.frames[#ctx.frames].indent
	then
		addProblem(ctx.result, ctx.line, getText("IGUI_AutoPilot_E_P_BadDedent", ctx.line));
	end
end

-- ============================================================================================================
-- Statements
-- ============================================================================================================

-- the recipes of a name (allowed for the macros), or nil (the problem is added)
local function resolveRecipe(ctx, token)
	local resolver = ctx.resolver;
	local recipes, suggestions = resolver:resolveRecipe(token.text);

	if recipes == nil
	then
		lineError(ctx, withMaybe(getText("IGUI_AutoPilot_E_P_UnknownRecipe", ctx.line, token.text), suggestions), token);

		return nil;
	end

	local allowed = {};
	local bench = nil;

	for i, recipe in ipairs(recipes)
	do
		if resolver:isAllowed(recipe)
		then
			table.insert(allowed, recipe);
		elseif bench == nil
		then
			bench = resolver:benchName(recipe);
		end
	end

	if #allowed == 0
	then
		if bench
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BenchRecipe", ctx.line, token.text, bench), token);
		else
			lineError(ctx, getText("IGUI_AutoPilot_E_P_NotAllowedRecipe", ctx.line, token.text), token);
		end

		return nil;
	end

	if #allowed == 1
	then
		noteId(ctx, token, "recipe", resolver:recipeId(allowed[1]));
	end

	return allowed;
end

-- an action of the program (counted for the macro or its "when"); times > 1: a loop of that line (2.6)
local function addAction(ctx, action, times)
	if ctx.handler
	then
		ctx.handler.actionCount = ctx.handler.actionCount + 1;
	else
		ctx.result.actionCount = ctx.result.actionCount + 1;
	end

	ctx.result.uses[action.kind] = true;

	if times and times > 1
	then
		local loopIndex = addOp(ctx, { op = "LOOP", mode = "times", n = times, synthetic = true });

		addOp(ctx, action);
		closeLoopOp(ctx, loopIndex, nil);
	else
		addOp(ctx, action);
	end
end

-- craft("R", using="X", times=N) / dismantle("X", times=N)
local function compileCraft(ctx, name, bound)
	local resolver = ctx.resolver;
	local action = { op = "ACTION", kind = "craft" };
	local times = bound.times and bound.times.v or 1;

	if bound.times and not checkNumber(ctx, times, Lang.minNumber, Lang.maxNumber)
	then
		return;
	end

	if name == "craft"
	then
		local recipeToken = bound.recipe.tok;
		local allowed = resolveRecipe(ctx, recipeToken);

		if allowed == nil
		then
			return;
		end

		action.recipes = allowed;
		action.recipeText = recipeToken.text;

		if bound.using
		then
			local itemToken = bound.using.tok;
			local types = resolveItem(ctx, itemToken);

			if types == nil
			then
				return;
			end

			local accepting = {};

			for i, recipe in ipairs(allowed)
			do
				if resolver:acceptsAny(recipe, types)
				then
					table.insert(accepting, recipe);
				end
			end

			if #accepting == 0
			then
				-- the recipe with a similar name that takes it ("Strappa sacco grande" for "Sacco di juta")
				local others = resolver.recipesAccepting and resolver:recipesAccepting(types, recipeToken.text, 3) or nil;

				lineError(ctx, withMaybe(getText("IGUI_AutoPilot_E_P_ItemNotForRecipe", ctx.line, itemToken.text, recipeToken.text), others), itemToken);

				return;
			end

			-- the types of the name the recipes take: two or more = the macro takes the first one it finds
			local relevant = {};

			for i, fullType in ipairs(types)
			do
				if takenBy(resolver, accepting, fullType)
				then
					table.insert(relevant, fullType);
				end
			end

			warnAmbiguousItem(ctx, itemToken, types, relevant, "use", accepting, recipeToken.text);

			action.recipes = accepting;
			action.withTypes = types;
			action.withText = itemToken.text;
		else
			warnUnchosen(ctx, recipeToken, allowed);
		end
	else
		local itemToken = bound.item.tok;
		local types = resolveItem(ctx, itemToken);

		if types == nil
		then
			return;
		end

		local recipes = resolver:dismantleRecipes(types);

		if #recipes == 0
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_NoDismantle", ctx.line, itemToken.text));

			return;
		end

		if #recipes > 1
		then
			local names = {};

			for i, recipe in ipairs(recipes)
			do
				table.insert(names, "\"" .. resolver:recipeName(recipe) .. "\"");
			end

			lineError(ctx, getText("IGUI_AutoPilot_E_P_ManyDismantle", ctx.line, itemToken.text, #recipes, table.concat(names, ", ")));

			return;
		end

		local relevant = {};

		for i, fullType in ipairs(types)
		do
			if takenBy(resolver, recipes, fullType)
			then
				table.insert(relevant, fullType);
			end
		end

		warnAmbiguousItem(ctx, itemToken, types, relevant, "use", recipes, nil);

		action.recipes = recipes;
		action.recipeText = resolver:recipeName(recipes[1]);
		action.withTypes = types;
		action.withText = itemToken.text;
		action.dismantle = true;
		action.itemText = itemToken.text;
	end

	-- the warnings of a recipe that can be done: several recipes with one name (with their ids, to write one), a
	-- recipe not learned yet
	local recipeToken = name == "craft" and bound.recipe.tok or nil;

	if #action.recipes > 1
	then
		local ids = {};

		for i, recipe in ipairs(action.recipes)
		do
			table.insert(ids, resolver:recipeId(recipe));
		end

		warn(ctx, getText("IGUI_AutoPilot_E_P_SameName", ctx.line, action.recipeText, #action.recipes) ..
			getText("IGUI_AutoPilot_E_P_SameNameIds", quoted(ids[1])), recipeToken, "ambiguousRecipe",
			{ name = action.recipeText, recipes = ids });
	end

	if ctx.opts.player
	then
		local learned = false;

		for i, recipe in ipairs(action.recipes)
		do
			if resolver:isLearned(ctx.opts.player, recipe)
			then
				learned = true;
			end
		end

		if not learned
		then
			warn(ctx, getText("IGUI_AutoPilot_E_P_NotLearned", ctx.line, action.recipeText), recipeToken);
		end
	end

	-- what the line needs ("Attrezzi e materiali"): the first recipe of the name
	local needs = requirementsOf(ctx, action.recipes[1], action.recipeText);

	if needs
	then
		table.insert(ctx.result.requirements, needs);
	end

	addAction(ctx, action, times);
end

-- the types of a list a set of recipes takes (uses up, or works on)
local function takenTypes(resolver, recipes, types)
	local list = {};

	for i, fullType in ipairs(types)
	do
		if takenBy(resolver, recipes, fullType)
		then
			table.insert(list, fullType);
		end
	end

	return list;
end

-- repair("X", using="M", times=N) / sharpen("X", times=N) (wave 0, A0.2): the game's own recipes that repair or
-- sharpen X and keep it, like dismantle() finds the one that dismantles; a craft action on X with every recipe that
-- fits, in the order the macro tries them (the first the game can do now: Names.workOrder), only those using M up
-- when the line says it. The game keeps its own rules: a repair can fail and damage, the more repairs the more it
-- fails; the macro counts the attempt (A0.1) and goes on.
local function compileWork(ctx, name, bound)
	local resolver = ctx.resolver;
	local times = bound.times and bound.times.v or 1;

	if bound.times and not checkNumber(ctx, times, Lang.minNumber, Lang.maxNumber)
	then
		return;
	end

	local itemToken = bound.item.tok;
	local types = resolveItem(ctx, itemToken);

	if types == nil
	then
		return;
	end

	local noRecipe = name == "sharpen" and "IGUI_AutoPilot_E_P_NoSharpen" or "IGUI_AutoPilot_E_P_NoRepair";
	local recipes = resolver.workRecipes and resolver:workRecipes(name, types, nil) or {};

	if #recipes == 0
	then
		lineError(ctx, getText(noRecipe, ctx.line, itemToken.text), itemToken);

		return;
	end

	local action = { op = "ACTION", kind = "craft", work = name, withTypes = types, withText = itemToken.text,
		itemText = itemToken.text };

	if bound.using
	then
		local materialToken = bound.using.tok;
		local materials = resolveItem(ctx, materialToken);

		if materials == nil
		then
			return;
		end

		local fitting = resolver:workRecipes(name, types, materials);

		if #fitting == 0
		then
			-- the materials it is repaired with: the first type of what each recipe uses up
			local others = {};

			for i, recipe in ipairs(recipes)
			do
				for j, slot in ipairs(resolver.inputSlots and resolver:inputSlots(recipe) or {})
				do
					if not slot.keep and slot.types[1] and #others < Lang.maxSuggested
					then
						local text = writable(resolver, slot.types[1]);
						local seen = false;

						for k, other in ipairs(others)
						do
							seen = seen or other == text;
						end

						if not seen
						then
							table.insert(others, text);
						end

						break;
					end
				end
			end

			lineError(ctx, withMaybe(getText("IGUI_AutoPilot_E_P_NoRepairWith", ctx.line, itemToken.text, materialToken.text), others),
				materialToken);

			return;
		end

		-- a material name of several types the recipes use up: the macro leaves the choice to the game, say it
		warnAmbiguousItem(ctx, materialToken, materials, takenTypes(resolver, fitting, materials), "use", fitting, nil);
		recipes = fitting;
		action.materialText = materialToken.text;
	end

	-- an item name of several types the recipes work on: the macro takes the first damaged one it finds (2.9)
	warnAmbiguousItem(ctx, itemToken, types, takenTypes(resolver, recipes, types), "use", recipes, nil);

	action.recipes = recipes;
	action.recipeText = resolver:recipeName(recipes[1]);

	if ctx.opts.player
	then
		local learned = false;

		for i, recipe in ipairs(recipes)
		do
			learned = learned or resolver:isLearned(ctx.opts.player, recipe);
		end

		if not learned
		then
			warn(ctx, getText("IGUI_AutoPilot_E_P_NotLearned", ctx.line, action.recipeText), itemToken);
		end
	end

	local alternatives = {};

	for i = 2, #recipes
	do
		table.insert(alternatives, recipes[i]);
	end

	local needs = requirementsOf(ctx, recipes[1], action.recipeText, itemToken.text, alternatives);

	if needs
	then
		needs.work = name;
		table.insert(ctx.result.requirements, needs);
	end

	addAction(ctx, action, times);
end

-- exercise / rest / eat / drink / smoke / read
local function compileBody(ctx, name, bound)
	local action = { op = "ACTION", kind = name };

	if name == "exercise"
	then
		local wanted = string.lower(bound.type.v);
		local id = Lang.exerciseAlias[wanted] or wanted;
		local known = false;

		for i, exercise in ipairs(Lang.exercises)
		do
			if exercise == id
			then
				known = true;
			end
		end

		if not known
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadExercise", ctx.line, bound.type.v, table.concat(Lang.exercises, ", ")));

			return;
		end

		action.exercise = id;
		action.minutes = bound.minutes and bound.minutes.v or 10;

		if not Lang.exerciseMinutes[action.minutes]
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadMinutes", ctx.line));

			return;
		end
	elseif name == "rest"
	then
		action.seat = bound.seat and string.lower(bound.seat.v) or "nearest";
		action.untilPct = bound["until"] and bound["until"].v or 95;

		local seatKnown = false;

		for i, seat in ipairs(Lang.seats)
		do
			seatKnown = seatKnown or seat == action.seat;
		end

		if not seatKnown
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadSeat", ctx.line));

			return;
		end

		if not checkNumber(ctx, action.untilPct, 1, 100)
		then
			return;
		end
	else
		if bound.item
		then
			local types = resolveItem(ctx, bound.item.tok);

			if types == nil
			then
				return;
			end

			if name == "read"
			then
				-- a name of several books: the first one the macro finds is read (2.9)
				warnAmbiguousItem(ctx, bound.item.tok, types, types, "use");
			end

			action.itemTypes = types;
			action.itemText = bound.item.v;
		end

		action.openCans = bound.open_cans ~= nil and bound.open_cans.v == true;

		if name == "drink"
		then
			local amount = bound.amount and string.lower(bound.amount.v) or "all";

			action.amount = Lang.drinkAmounts[amount];

			if action.amount == nil
			then
				lineError(ctx, getText("IGUI_AutoPilot_E_P_BadAmount", ctx.line));

				return;
			end
		end
	end

	addAction(ctx, action, 1);
end

-- a call statement: craft(...), wait(...), stop_if(...)...
local function parseCall(ctx, first)
	local name = first.lower;
	local spec = Lang.calls[name];
	local p = { t = ctx.tokens, i = 3 };
	local args = parseArgs(p);

	if args == nil
	then
		syntaxError(ctx, p, spec and spec.usage or nil);

		return;
	end

	if p.i <= #ctx.tokens
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec and spec.usage or textOf(ctx, 1)));

		return;
	end

	if spec == nil
	then
		if Lang.condCalls[name]
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_CondAlone", ctx.line, first.text), first);
		elseif Lang.italian[name]
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Italian", ctx.line, first.text, Lang.italian[name]), first);
		else
			lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownCommand", ctx.line, textOf(ctx, 1)), first);
		end

		return;
	end

	-- stop_if's condition: the tokens between its parentheses
	if name == "stop_if"
	then
		local close = #ctx.tokens;

		if not isSym(ctx.tokens[close], ")") or close < 4
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, spec.usage));

			return;
		end

		local cond = parseCondition(ctx, 3, close - 1);

		if cond
		then
			addOp(ctx, { op = "STOPIF", cond = cond });

			if ctx.handler
			then
				ctx.handler.stops = true;
			end
		end

		return;
	end

	local bound = bindArgs(ctx, name, spec, args);

	if bound == nil
	then
		return;
	end

	if name == "craft" or name == "dismantle"
	then
		compileCraft(ctx, name, bound);
	elseif name == "repair" or name == "sharpen"
	then
		compileWork(ctx, name, bound);
	elseif name == "wait"
	then
		local n = bound.seconds.v;

		if checkNumber(ctx, n, 1, Lang.maxWaitSeconds)
		then
			addOp(ctx, { op = "WAIT", ms = n * 1000, seconds = n });
		end
	elseif name == "stop"
	then
		addOp(ctx, { op = "STOPIF", cond = { k = "const", v = true, text = "stop()" }, plain = true });

		if ctx.handler
		then
			ctx.handler.stops = true;
		end
	else
		compileBody(ctx, name, bound);
	end
end

-- the headers: repeat N, while ..., if / elif / else, when, for (a hint); colonOk: the line ended with ":"
local function parseHeader(ctx, first, last)
	local tokens = ctx.tokens;
	local word = first.lower;
	local top = ctx.frames[#ctx.frames];

	if word == "for"
	then
		local n = nil;

		for i = 2, last
		do
			if tokens[i].k == "num"
			then
				n = tokens[i].text;
			end
		end

		lineError(ctx, getText("IGUI_AutoPilot_E_P_ForRange", ctx.line, n or "10"));
		openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, { op = "LOOP", mode = "times", n = 1 }), breaks = {} });

		return;
	end

	if word == "elif" or word == "else"
	then
		if top.chain == nil or top.chain.closed
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_ElifWithoutIf", ctx.line, word));
			finalizeChain(ctx, top);
			top.chain = { endJumps = {}, ops = ctx.ops };
		end
	else
		finalizeChain(ctx, top);
	end

	if word == "repeat"
	then
		local n = tokens[2] and tokens[2].k == "num" and tonumber(tokens[2].text) or nil;
		local loop = { op = "LOOP", mode = "times", n = n or 1 };

		if n == nil or last ~= 2
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, "repeat 10:"));
		elseif checkNumber(ctx, n, Lang.minNumber, Lang.maxNumber) and ctx.opts.maxLoops and n > ctx.opts.maxLoops
		then
			warn(ctx, getText("IGUI_AutoPilot_E_P_OverLimit", ctx.line, ctx.opts.maxLoops));
		end

		openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, loop), breaks = {} });
	elseif word == "while"
	then
		local loop = { op = "LOOP" };
		local second = tokens[2];

		if last == 2 and second and second.k == "name" and second.lower == "possible"
		then
			loop.mode = "possible";
		elseif last == 2 and second and second.k == "name" and second.lower == "true"
		then
			loop.mode = "forever";
			warn(ctx, getText("IGUI_AutoPilot_E_P_Forever", ctx.line, ctx.opts.maxActions or 0));
		else
			loop.mode = "while";
			loop.cond = parseCondition(ctx, 2, last);
			loop.condText = loop.cond and loop.cond.text or "";
		end

		openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, loop), breaks = {} });
	elseif word == "if" or word == "elif"
	then
		local cond = parseCondition(ctx, 2, last);
		local index = addOp(ctx, { op = "IF", cond = cond or { k = "const", v = false } });

		if word == "if"
		then
			top.chain = { endJumps = {}, ops = ctx.ops };
		end

		openBlock(ctx, { kind = "if", opIndex = index });
	elseif word == "else"
	then
		if last ~= 1
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, "else:"));
		end

		top.chain.closed = true;
		openBlock(ctx, { kind = "else" });
	elseif word == "when"
	then
		ctx.moodlesSeen = {};

		local cond = parseCondition(ctx, 2, last);
		local handler = { line = ctx.line, cond = cond or { k = "const", v = false }, ops = {}, actionCount = 0, moodles = ctx.moodlesSeen };

		-- only the "when" line's own condition says which moodles the handler looks after (the engine's "unwell")
		ctx.moodlesSeen = {};

		if #ctx.frames > 1 or ctx.handler
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_WhenNotTop", ctx.line));
		end

		if ctx.handler == nil
		then
			table.insert(ctx.result.handlers, handler);
			ctx.ops = handler.ops;
			ctx.handler = handler;
		end

		openBlock(ctx, { kind = "when", handler = handler });
	end
end

-- a line of an old macro (format 1) or Italian written by habit: the hint with the English to write
local function oldOrItalian(ctx, first)
	local word = first.lower;
	local converted = AutoPilotMoon.Macro.Convert and AutoPilotMoon.Macro.Convert:line(ctx.code) or nil;

	if converted and converted ~= ""
	then
		-- the whole old statement underlined
		lineError(ctx, getText("IGUI_AutoPilot_E_P_OldSyntax", ctx.line, converted), { s = first.s, e = ctx.tokens[#ctx.tokens].e });

		return true;
	end

	if Lang.italian[word]
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_Italian", ctx.line, first.text, Lang.italian[word]), first);

		return true;
	end

	return false;
end

-- whether an old line opens a block (ripeti / repeat ... without the colon): its body is then read as a body
local function oldOpensBlock(first, tokens)
	return (first.lower == "ripeti" or first.lower == "repeat") and not isSym(tokens[#tokens], ":");
end

local function parseLine(ctx)
	local tokens = ctx.tokens;
	local first = tokens[1];
	local last = #tokens;
	local colon = isSym(tokens[last], ":");

	for i, token in ipairs(tokens)
	do
		if isSym(token, "{") or isSym(token, "}")
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_Braces", ctx.line));

			if colon or BLOCK_WORDS[first.lower]
			then
				openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, { op = "LOOP", mode = "times", n = 1 }), breaks = {}, emptySaid = true });
			end

			return;
		end
	end

	if colon
	then
		last = last - 1;
	end

	-- an old "ripeti" / "repeat ... times" written without the colon: the old form's hint, its body read as a body
	if not colon and first.k == "name" and (first.lower == "repeat" or first.lower == "ripeti") and oldOrItalian(ctx, first)
	then
		openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, { op = "LOOP", mode = "times", n = 1 }), breaks = {}, emptySaid = true });

		return;
	end

	if first.k == "name" and BLOCK_WORDS[first.lower]
	then
		if not colon
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_MissingColon", ctx.line, textOf(ctx, 1) .. ":"));
		end

		if last < 1 or (last < 2 and first.lower ~= "else")
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_BadCondition", ctx.line, ""));
		end

		parseHeader(ctx, first, math.max(last, 1));

		return;
	end

	-- an Italian word opening a block by habit (se, quando, altrimenti...): the English, its body read as a body
	if colon and first.k == "name" and Lang.italian[first.lower]
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_Italian", ctx.line, first.text, Lang.italian[first.lower]), first);
		openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, { op = "LOOP", mode = "times", n = 1 }), breaks = {}, emptySaid = true });

		return;
	end

	if colon
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_ExtraColon", ctx.line));
	end

	if first.k == "name" and (first.lower == "pass")
	then
		if last > 1
		then
			lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownCommand", ctx.line, textOf(ctx, 1)), first);
		end

		finalizeChain(ctx, ctx.frames[#ctx.frames]);

		return;
	end

	if first.k == "name" and first.lower == "break"
	then
		finalizeChain(ctx, ctx.frames[#ctx.frames]);

		for i = #ctx.frames, 1, -1
		do
			local block = ctx.frames[i].block;

			if block and block.kind == "when"
			then
				break;
			end

			if block and block.kind == "loop"
			then
				table.insert(block.breaks, addOp(ctx, { op = "JUMP" }));

				return;
			end
		end

		lineError(ctx, getText("IGUI_AutoPilot_E_P_BreakOutside", ctx.line));

		return;
	end

	finalizeChain(ctx, ctx.frames[#ctx.frames]);

	if first.k == "name" and isSym(tokens[2], "(")
	then
		parseCall(ctx, first);

		return;
	end

	if first.k == "name" and oldOrItalian(ctx, first)
	then
		if oldOpensBlock(first, tokens)
		then
			openBlock(ctx, { kind = "loop", opIndex = addOp(ctx, { op = "LOOP", mode = "times", n = 1 }), breaks = {}, emptySaid = true });
		end

		return;
	end

	if first.k == "name" and Lang.calls[first.lower]
	then
		lineError(ctx, getText("IGUI_AutoPilot_E_P_Usage", ctx.line, Lang.calls[first.lower].usage));

		return;
	end

	lineError(ctx, getText("IGUI_AutoPilot_E_P_UnknownCommand", ctx.line, textOf(ctx, 1)), first);
end

-- ============================================================================================================
-- Checking a text
-- ============================================================================================================

-- the lines of a text ("\r\n" and "\n"; a last empty line after the final newline does not count)
function AutoPilotMoon.Macro.Lang:splitLines(text)
	local lines = {};
	local start = 1;
	local n = string.len(text or "");

	while start <= n
	do
		local stop = string.find(text, "\n", start, true);

		if stop == nil
		then
			table.insert(lines, (string.gsub(string.sub(text, start), "\r", "")));

			break;
		end

		table.insert(lines, (string.gsub(string.sub(text, start, stop - 1), "\r", "")));
		start = stop + 1;
	end

	return lines;
end

local function byLine(a, b)
	local la = a.line or 0;
	local lb = b.line or 0;

	if la ~= lb
	then
		return la < lb;
	end

	return a.order < b.order;
end

-- a line made only of an old block's end ("fine", "end", "}"): said, and left out of the indentation
local function isEndLine(tokens)
	if #tokens ~= 1
	then
		return false;
	end

	return (tokens[1].k == "name" and END_WORDS[tokens[1].lower]) or isSym(tokens[1], "}");
end

-- Checks a macro's text. See the head of the file for the result.
function AutoPilotMoon.Macro.Lang:check(text, resolver, opts)
	opts = opts or {};

	local result = { ops = {}, handlers = {}, problems = {}, all = {}, errors = 0, warnings = 0, more = 0, actionCount = 0,
		lineCount = 0, uses = {}, requirements = {}, xpPerks = {} };

	if resolver == nil or not resolver:isReady()
	then
		result.notReady = true;

		return result;
	end

	local lines = Lang:splitLines(text);

	result.lineCount = #lines;

	if #lines > Lang.maxLines
	then
		-- never cut in silence (4.3): the text stays as it is, the check says it
		addProblem(result, nil, getText("IGUI_AutoPilot_E_P_TooManyLines", Lang.maxLines));
	else
		local ctx = { result = result, resolver = resolver, opts = opts, ops = result.ops, mainOps = result.ops,
			frames = { { indent = 0 } }, ids = opts.ids and {} or nil, moodlesSeen = {} };

		for i, raw in ipairs(lines)
		do
			ctx.line = i;
			ctx.lineFailed = false;

			local line = normalize(raw);
			local stripped = trim(line);

			if string.len(raw) > Lang.maxLineChars
			then
				addProblem(result, i, getText("IGUI_AutoPilot_E_P_LineTooLong", i, Lang.maxLineChars));
			elseif string.find(stripped, "^===")
			then
				addProblem(result, i, getText("IGUI_AutoPilot_E_P_Reserved", i));
			else
				local code = stripComment(line);

				ctx.code = code;

				if trim(code) ~= ""
				then
					local tokens, err = tokenize(code);

					if tokens == nil
					then
						addProblem(result, i, getText("IGUI_AutoPilot_E_P_Quote", i));
					elseif isEndLine(tokens)
					then
						addProblem(result, i, getText(isSym(tokens[1], "}") and "IGUI_AutoPilot_E_P_Braces" or "IGUI_AutoPilot_E_P_EndWord", i, tokens[1].text), false, tokens[1]);
					else
						ctx.tokens = tokens;
						ctx.tokenIndex = {};

						for k, token in ipairs(tokens)
						do
							ctx.tokenIndex[token] = k;
						end

						if ctx.handler == nil
						then
							ctx.moodlesSeen = {};
						end

						handleIndent(ctx, indentOf(code));
						parseLine(ctx);
					end
				end
			end
		end

		if ctx.expect
		then
			local block = ctx.expect;

			ctx.expect = nil;
			addProblem(result, block.line, getText("IGUI_AutoPilot_E_P_ExpectIndent", block.line, block.line));
			block.emptySaid = true;
			table.insert(ctx.frames, { indent = ctx.frames[#ctx.frames].indent + 1, block = block });
		end

		while #ctx.frames > 1
		do
			closeFrame(ctx);
		end

		finalizeChain(ctx, ctx.frames[1]);

		if result.actionCount == 0 and result.errors == 0
		then
			addProblem(result, nil, getText("IGUI_AutoPilot_E_P_Empty"));
		end

		result.ids = ctx.ids;
	end

	for i, problem in ipairs(result.all)
	do
		problem.order = i;
	end

	table.sort(result.all, byLine);

	for i, problem in ipairs(result.all)
	do
		if i <= Lang.maxProblems
		then
			table.insert(result.problems, problem);
		else
			result.more = result.more + 1;
		end
	end

	result.all = nil;

	return result;
end

-- the first line with an error (nil: none)
function AutoPilotMoon.Macro.Lang:firstErrorLine(result)
	for i, problem in ipairs(result.problems)
	do
		if not problem.warn and problem.line
		then
			return problem.line;
		end
	end

	return nil;
end

-- the actions the program will do when every loop is "repeat N" and nothing depends on a condition (the panel's
-- bar), else nil
local function spanTotal(ops, first, last)
	local total = 0;
	local i = first;

	while i <= last
	do
		local op = ops[i];

		if op.op == "ACTION"
		then
			total = total + 1;
			i = i + 1;
		elseif op.op == "LOOP"
		then
			if op.mode ~= "times" or op.endIndex == nil
			then
				return nil;
			end

			local inner = spanTotal(ops, i + 1, op.endIndex - 1);

			if inner == nil
			then
				return nil;
			end

			total = total + inner * op.n;
			i = op.endIndex + 1;
		elseif op.op == "IF" or op.op == "JUMP"
		then
			return nil;
		else
			i = i + 1;
		end
	end

	return total;
end

function AutoPilotMoon.Macro.Lang:plannedActions(ops)
	return spanTotal(ops, 1, #ops);
end

-- the outermost loop (the panel's "Giro" line and the start message), nil when the macro has none
function AutoPilotMoon.Macro.Lang:outerLoop(ops)
	for i, op in ipairs(ops)
	do
		if op.op == "LOOP"
		then
			return op, i;
		end
	end

	return nil;
end

-- "Copia con gli id" (6.3): the text with recipes, items and skills written as the game's ids (in quotes), the rest
-- untouched (keywords, indentation, comments); a name that stands for several recipes or items stays as it is
function AutoPilotMoon.Macro.Lang:withIds(text, resolver, opts)
	local copy = {};

	for k, v in pairs(opts or {})
	do
		copy[k] = v;
	end

	copy.ids = true;

	local result = Lang:check(text, resolver, copy);
	local lines = Lang:splitLines(text);

	if result.notReady or result.ids == nil
	then
		return text;
	end

	-- right to left on each line, so the positions before stay valid
	table.sort(result.ids, function(a, b)
		if a.line ~= b.line
		then
			return a.line < b.line;
		end

		return a.s > b.s;
	end);

	for i, entry in ipairs(result.ids)
	do
		local line = normalize(lines[entry.line]);

		lines[entry.line] = string.sub(line, 1, entry.s - 1) .. "\"" .. entry.id .. "\"" .. string.sub(line, entry.e + 1);
	end

	return table.concat(lines, "\n");
end

-- the text of an action line as the recorder and "Inserisci" write it: craft("R", using="X", times=3) /
-- dismantle("X", times=2)
function AutoPilotMoon.Macro.Lang:formatAction(kind, recipeText, withText, times)
	local line = nil;

	if kind == "dismantle"
	then
		line = "dismantle(\"" .. withText .. "\"";
	else
		line = "craft(\"" .. recipeText .. "\"";

		if withText
		then
			line = line .. ", using=\"" .. withText .. "\"";
		end
	end

	if times and times > 1
	then
		line = line .. ", times=" .. times;
	end

	return line .. ")";
end

-- ============================================================================================================
-- The editor's colours (MACRO-AUTOPILOT.md 4.11): the class of every character of a line, from the same lexer
-- ============================================================================================================

-- the words of the blocks (violet in the editor) and the logical ones (blue), as Python's colours in VS Code
-- the words of the statements (Lang.statementList) and "for" (an error the checker explains)
local CONTROL_WORDS = set("for");

for i, statement in ipairs(Lang.statementList)
do
	CONTROL_WORDS[statement.word] = true;
end
local LOGIC_WORDS = set("and", "or", "not", "possible", "in");

-- The class of each character of a line as the editor colours it: a list as long as the line (one entry per character
-- of the game's strings, an accented letter is one), each "plain", "keyword", "logic", "call", "param", "name",
-- "string", "number" or "comment". Read with this file's own reader (stripComment, tokenize): a "#" in quotes is
-- text, a word in quotes is text, the typographic quotes are quotes, an unclosed quote makes the rest a text. Never an
-- error: a line the checker refuses is coloured as far as it reads, the checker's problem says the rest.
--   keyword  while if elif else when repeat break pass for     logic  and or not possible in
--   call     a name followed by "(" (craft, has, skill, an unknown one too: the checker says it)
--   param    a name followed by "=" (using=, minutes=...)       name   a moodle (hungry, endurance...), a skill's name
--   string   "text" 'text' (quotes included)                    number 3, 10, True, False
--   comment  from "#" to the end                                plain  the rest (operators, brackets, other words)
function AutoPilotMoon.Macro.Lang:classify(raw)
	raw = raw or "";

	local n = string.len(raw);
	local classes = {};

	for i = 1, n
	do
		classes[i] = "plain";
	end

	-- one character for one (Lang.plainLine), so the positions stay those of the line shown
	local line = Lang.plainLine(raw);

	if string.len(line) ~= n
	then
		return classes;
	end

	local code, comment = stripComment(line);
	local codeLength = string.len(code);

	if comment
	then
		for i = codeLength + 1, n
		do
			classes[i] = "comment";
		end
	end

	local tokens, err, partial, quoteAt = tokenize(code);

	if tokens == nil
	then
		tokens = partial or {};

		for i = quoteAt or (codeLength + 1), codeLength
		do
			classes[i] = "string";
		end
	end

	for k, token in ipairs(tokens)
	do
		local class = "plain";
		local after = tokens[k + 1];

		if token.k == "str"
		then
			class = "string";

			-- skill("Name"), xp_gained("Name"): the skill's name, as the moodles
			local before = tokens[k - 1];
			local call = tokens[k - 2];
			local spec = call and call.k == "name" and Lang.condCalls[call.lower] or nil;

			if before and before.k == "sym" and before.text == "(" and spec and spec.names and spec.names[spec.pos[1]] == "skill"
			then
				class = "name";
			end
		elseif token.k == "num"
		then
			class = "number";
		elseif token.k == "name"
		then
			if token.lower == "true" or token.lower == "false"
			then
				class = "number";
			elseif after and after.k == "sym" and after.text == "("
			then
				class = "call";
			elseif after and after.k == "sym" and after.text == "="
			then
				class = "param";
			elseif CONTROL_WORDS[token.lower]
			then
				class = "keyword";
			elseif LOGIC_WORDS[token.lower]
			then
				class = "logic";
			elseif Lang.moodles[token.lower] or Lang.percents[token.lower] or Lang.condWords[token.lower]
			then
				class = "name";
			end
		end

		for i = token.s, token.e
		do
			classes[i] = class;
		end
	end

	return classes;
end

-- the position in a line as shown of a position in the line as read (Lang:check reads a tab as Lang.tabWidth spaces):
-- the editor's underline of a problem's word
function AutoPilotMoon.Macro.Lang:rawColumn(raw, column)
	local read = 0;

	for i = 1, string.len(raw or "")
	do
		local c = string.sub(raw, i, i);

		if c == "\t"
		then
			read = read + Lang.tabWidth;
		elseif c ~= "\r"
		then
			read = read + 1;
		end

		if read >= column
		then
			return i;
		end
	end

	return string.len(raw or "");
end
