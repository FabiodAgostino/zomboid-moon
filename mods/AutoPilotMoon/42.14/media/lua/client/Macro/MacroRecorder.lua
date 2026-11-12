-- AutoPilot (Moon): automations for the Moon server.

-- The recorder (spec MACRO-AUTOPILOT.md 3): it watches the recipes the player completes by hand (the item's menu or the
-- Crafting window, "Crea tutto" too) and writes the macro. Through the hooks on ISHandcraftAction (MacroRun.lua):
-- before the game's perform it notes the recipe, the input items with their InputScript and the ids of the inventory;
-- the line is written only when the inventory confirms it (an input gone or something new; up to Recorder.confirmMs
-- for the server in multiplayer, else "Non registrata: il gioco non ha fatto ..."). A workbench's recipe is not
-- recorded in step M1 (said with the bench's name); the other actions of the player are only counted for the line
-- "Non registrate" (ISTimedActionQueue.add is wrapped only while recording, and the actions queued together with a
-- recipe, its materials' transfers, belong to the recipe and are not counted).
-- Generalized (3.3): the recipe by its name (its id when the name stands for several recipes), "smonta X" when the
-- recipe dismantles and is the only one that dismantles X, "con" the type of the first consumed input that accepts more
-- than one type; never an item's id, a container or a place. Equal lines in a row become "N volte".
-- Moving never stops it; Fine, Annulla, death (thrown away), Recorder.maxSteps steps or Recorder.idleFinishMs without
-- a new step end it. The preview (3.4) asks how to repeat it ("Finche' si puo'" by default, decision DM3) and the name.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Recorder = AutoPilotMoon.Macro.Recorder or {};

local Rec = AutoPilotMoon.Macro.Recorder;
local UI = AutoPilotMoon.UI;

Rec.maxSteps = 50;
Rec.idleFinishMs = 15 * 60 * 1000;
Rec.confirmMs = 3000;
Rec.checkEveryMs = 200;      -- the pending recipes are compared with the inventory at most this often
Rec.visibleLines = 6;        -- the panel's last recorded lines
Rec.session = nil;
Rec.revision = 0;            -- grows when the recording changes (the panel redoes its texts)
Rec.repeatMode = "possible"; -- the preview's choice, kept for the session (DM3: "finche' si puo'" by default)
Rec.repeatTimes = 10;

-- the actions only counted as "not recorded", by their Type
Rec.moveTypes = { ISInventoryTransferAction = true };
Rec.equipTypes = { ISEquipWeaponAction = true, ISWearClothing = true, ISUnequipAction = true };
Rec.walkTypes = { ISWalkToTimedAction = true, ISPathFindAction = true, ISHandcraftAction = true };
-- the body's actions done by hand (M1.5): not recorded, said with the command that writes them (MACRO-AUTOPILOT.md 11.6)
Rec.bodyTypes = { ISFitnessAction = true, ISEatFoodAction = true, ISDrinkFluidAction = true, ISTakePillAction = true,
	ISRestAction = true, ISSitOnGround = true, ISWaitWhileGettingUp = true };

local function changed()
	Rec.revision = Rec.revision + 1;
end

function AutoPilotMoon.Macro.Recorder:isRecording(playerNum)
	local session = Rec.session;

	return session ~= nil and (playerNum == nil or session.playerNum == playerNum);
end

function AutoPilotMoon.Macro.Recorder:isRecordingFor(character)
	local session = Rec.session;

	return session ~= nil and session.player == character;
end

-- why the recording cannot start now (nil: it can)
function AutoPilotMoon.Macro.Recorder:getStartRefusal(player)
	if not AutoPilotMoon.Automation:isAllowedByServer("macro")
	then
		return getText("IGUI_AutoPilot_E_Off");
	end

	if Rec.session
	then
		return getText("IGUI_AutoPilot_M_MacroRecording");
	end

	if AutoPilotMoon.Automation:isBusy()
	then
		return getText("IGUI_AutoPilot_M_MacroStopFirst");
	end

	if player == nil or player:isDead()
	then
		return getText("IGUI_AutoPilot_A_Reason_Disabled");
	end

	return nil;
end

-- ============================================================================================================
-- Start and end
-- ============================================================================================================

function AutoPilotMoon.Macro.Recorder.queueAdd(action)
	local session = Rec.session;

	if session and action and action.character == session.player
	then
		table.insert(session.batch, action.Type or "?");
	end

	return Rec.gameQueueAdd(action);
end

local function wrapQueue()
	-- Rec.queueWrapped: ours is still in the chain (another mod wrapped it after us and we could not take it out):
	-- wrapping again would take their wrapper, which calls ours, for the game's, without end
	if ISTimedActionQueue.add ~= Rec.queueAdd and not Rec.queueWrapped
	then
		Rec.gameQueueAdd = ISTimedActionQueue.add;
		ISTimedActionQueue.add = Rec.queueAdd;
	end

	Rec.queueWrapped = true;
end

local function unwrapQueue()
	-- only when it is still ours (another mod may have wrapped it after us: then ours stays in the chain, it records
	-- nothing without a session)
	if ISTimedActionQueue.add == Rec.queueAdd and Rec.gameQueueAdd
	then
		ISTimedActionQueue.add = Rec.gameQueueAdd;
		Rec.queueWrapped = false;
	end
end

function AutoPilotMoon.Macro.Recorder:start(player)
	local refusal = Rec:getStartRefusal(player);

	if refusal
	then
		AutoPilotMoon:say("bad", refusal, player);

		return false;
	end

	AutoPilotMoon.Macro.Hooks:install();
	AutoPilotMoon.Macro.Names:buildNow();

	local now = getTimestampMs();

	Rec.session = {
		player = player,
		playerNum = player:getPlayerNum(),
		startedAt = now,
		lastStepAt = now,
		steps = {},
		pending = {},
		batch = {},
		ignored = { move = 0, equip = 0, other = 0, body = 0 },
		benches = {},
		benchOrder = {},
		notConfirmed = nil,
		checkedAt = 0,
	};
	wrapQueue();
	changed();

	AutoPilotMoon:say("info", getText("IGUI_AutoPilot_R_Started"), player);

	if AutoPilotMoon.Panel and AutoPilotMoon.Options:get("openPanelOnStart")
	then
		AutoPilotMoon.Panel:open(player:getPlayerNum(), false, true);
	end

	return true;
end

local function endSession()
	local session = Rec.session;

	Rec.session = nil;
	unwrapQueue();
	changed();

	return session;
end

-- throws the recording away (Annulla after the confirmation, death)
function AutoPilotMoon.Macro.Recorder:cancel()
	endSession();
end

-- Fine: the preview, or "nothing to record"
function AutoPilotMoon.Macro.Recorder:finish()
	local session = Rec.session;

	if session == nil
	then
		return;
	end

	-- what the server confirmed meanwhile
	Rec:update(session.player, true);
	endSession();

	if #session.steps == 0
	then
		AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_R_Nothing"), session.player);

		return;
	end

	Rec:openPreview(session);
end

-- Annulla: asks when there are steps already ("Buttare 2 passi registrati?")
function AutoPilotMoon.Macro.Recorder:askCancel()
	local session = Rec.session;

	if session == nil
	then
		return;
	end

	if #session.steps == 0
	then
		Rec:cancel();

		return;
	end

	local dialog = ISModalDialog:new(0, 0, 300, 120, getText("IGUI_AutoPilot_R_CancelConfirm", Rec:countSteps(session)), true, nil, Rec.onCancelAnswer, session.playerNum);

	dialog:initialise();
	dialog:addToUIManager();

	if UI:isJoypad(session.playerNum)
	then
		setJoypadFocus(session.playerNum, dialog);
	end
end

function AutoPilotMoon.Macro.Recorder.onCancelAnswer(target, button)
	if button.internal == "YES"
	then
		Rec:cancel();
	end
end

-- the steps recorded, the repeats included ("crea ... 3 volte" counts 3)
function AutoPilotMoon.Macro.Recorder:countSteps(session)
	local count = 0;

	for i, step in ipairs((session or Rec.session or {}).steps or {})
	do
		count = count + step.count;
	end

	return count;
end

-- ============================================================================================================
-- What the hooks see
-- ============================================================================================================

-- before the game's perform of a recipe of the recording player: what it is, what goes in, the inventory now
function AutoPilotMoon.Macro.Recorder:beforePerform(action)
	local session = Rec.session;
	local recipe = action.craftRecipe;

	if session == nil or recipe == nil
	then
		return nil;
	end

	local Names = AutoPilotMoon.Macro.Names;

	if action.craftBench ~= nil or not Names:isAllowed(recipe)
	then
		-- step M2: a workbench's recipe is only said
		local key = recipe:getName();
		local entry = session.benches[key];

		if entry == nil
		then
			entry = { bench = Names:benchName(recipe), recipe = Names:recipeName(recipe), count = 0 };
			session.benches[key] = entry;
			table.insert(session.benchOrder, key);
		end

		entry.count = entry.count + 1;
		changed();

		return nil;
	end

	local player = action.character;
	local inputs = {};
	local items = action.items;

	if items
	then
		for i = 0, items:size() - 1
		do
			local item = items:get(i);

			if item
			then
				local script = CraftRecipeManager.getValidInputScriptForItem(recipe, item, player);

				table.insert(inputs, {
					id = item:getID(),
					fullType = item:getFullType(),
					script = script,
					keep = script ~= nil and (script:isKeep() or script:isTool()),
				});
			end
		end
	end

	return {
		recipe = recipe,
		inputs = inputs,
		before = AutoPilotMoon.Macro.Hooks:snapshot(player, {}),
		at = getTimestampMs(),
	};
end

function AutoPilotMoon.Macro.Recorder:afterPerform(action, token)
	local session = Rec.session;

	if session
	then
		token.at = getTimestampMs();
		table.insert(session.pending, token);
		changed();
	end
end

-- ============================================================================================================
-- Generalizing (3.3)
-- ============================================================================================================

-- the name to write for a type: its name, or the type when the name also stands for another type the input accepts
local function itemText(fullType, script)
	local Names = AutoPilotMoon.Macro.Names;
	local same = Names:typesWithSameName(fullType);

	if #same > 1 and script
	then
		local accepted = 0;
		local possible = script:getPossibleInputItems();

		for i = 0, possible:size() - 1
		do
			local other = possible:get(i):getFullName();

			for j, t in ipairs(same)
			do
				if t == other
				then
					accepted = accepted + 1;
				end
			end
		end

		if accepted > 1
		then
			return fullType;
		end
	end

	return Names:itemName(fullType);
end

-- a confirmed recipe as a step: { kind, recipeText, withText, count, recipe, mainType }
function AutoPilotMoon.Macro.Recorder:generalize(token, gone)
	local Names = AutoPilotMoon.Macro.Names;
	local recipe = token.recipe;
	local consumed = {};

	for i, input in ipairs(token.inputs)
	do
		if not input.keep and gone[input.id]
		then
			table.insert(consumed, input);
		end
	end

	local first = consumed[1];

	if first and Names.isDismantleId(recipe:getName())
	then
		local recipes = Names:dismantleRecipes({ first.fullType });

		if #recipes == 1 and recipes[1] == recipe
		then
			return { kind = "dismantle", withText = itemText(first.fullType, first.script), count = 1, recipe = recipe, mainType = first.fullType };
		end
	end

	local step = { kind = "craft", count = 1, recipe = recipe, mainType = first and first.fullType or nil };

	if Names:isAmbiguousRecipe(recipe)
	then
		step.recipeText = recipe:getName();
	else
		step.recipeText = Names:recipeName(recipe);
	end

	-- one "con" in step M1: the first consumed input that accepts more than one type
	for i, input in ipairs(consumed)
	do
		if input.script and input.script:getPossibleInputItems():size() > 1
		then
			step.withText = itemText(input.fullType, input.script);
			step.mainType = input.fullType;

			break;
		end
	end

	return step;
end

function AutoPilotMoon.Macro.Recorder:stepText(step, times)
	return AutoPilotMoon.Macro.Lang:formatAction(step.kind, step.recipeText, step.withText, times or step.count);
end

-- adds a confirmed step: equal to the last one = "N volte"
function AutoPilotMoon.Macro.Recorder:addStep(session, step)
	local last = session.steps[#session.steps];

	if last and last.kind == step.kind and last.recipeText == step.recipeText and last.withText == step.withText
	then
		last.count = last.count + 1;
	else
		table.insert(session.steps, step);
	end

	session.lastStepAt = getTimestampMs();
	changed();
end

-- ============================================================================================================
-- Every frame of the recording player
-- ============================================================================================================

local function processBatch(session)
	local batch = session.batch;

	if #batch == 0
	then
		return;
	end

	local withRecipe = false;

	for i, kind in ipairs(batch)
	do
		if kind == "ISHandcraftAction"
		then
			withRecipe = true;
		end
	end

	if not withRecipe
	then
		for i, kind in ipairs(batch)
		do
			if Rec.moveTypes[kind]
			then
				session.ignored.move = session.ignored.move + 1;
			elseif Rec.equipTypes[kind]
			then
				session.ignored.equip = session.ignored.equip + 1;
			elseif Rec.bodyTypes[kind]
			then
				if kind ~= "ISWaitWhileGettingUp"
				then
					session.ignored.body = session.ignored.body + 1;
				end
			elseif not Rec.walkTypes[kind]
			then
				session.ignored.other = session.ignored.other + 1;
			end
		end

		changed();
	end

	table.wipe(batch);
end

-- the pending recipes against the inventory: confirmed (a step), or given up after Rec.confirmMs
local function confirmPending(session, force)
	if #session.pending == 0
	then
		return;
	end

	local now = getTimestampMs();

	if not force and now - session.checkedAt < Rec.checkEveryMs
	then
		return;
	end

	session.checkedAt = now;

	local current = AutoPilotMoon.Macro.Hooks:snapshot(session.player, {});
	local waiting = {};

	-- in the order they were done ("Crea tutto" makes several in a row)
	for i, token in ipairs(session.pending)
	do
		local gone = {};
		local anyGone = false;
		local anyNew = false;

		for j, input in ipairs(token.inputs)
		do
			if not current[input.id]
			then
				gone[input.id] = true;

				if not input.keep
				then
					anyGone = true;
				end
			end
		end

		for id in pairs(current)
		do
			if not token.before[id]
			then
				anyNew = true;

				break;
			end
		end

		if anyGone or anyNew
		then
			Rec:addStep(session, Rec:generalize(token, gone));
		elseif now - token.at >= Rec.confirmMs
		then
			session.notConfirmed = getText("IGUI_AutoPilot_R_NotConfirmed", AutoPilotMoon.Macro.Names:recipeName(token.recipe));
			changed();
		else
			table.insert(waiting, token);
		end
	end

	session.pending = waiting;
end

-- Recorder:update (OnPlayerUpdate of the recording player): the batch of the queued actions, the confirmations, the
-- automatic end (full, too long without steps)
function AutoPilotMoon.Macro.Recorder:update(player, force)
	local session = Rec.session;

	if session == nil or session.player ~= player
	then
		return;
	end

	processBatch(session);
	confirmPending(session, force);

	if force
	then
		return;
	end

	local now = getTimestampMs();

	if Rec:countSteps(session) >= Rec.maxSteps
	then
		AutoPilotMoon:say("plain", getText("IGUI_AutoPilot_R_Full", Rec.maxSteps), player);
		Rec:finish();
	elseif now - session.lastStepAt >= Rec.idleFinishMs
	then
		Rec:finish();
	end
end

-- the recording player died: thrown away without questions
function AutoPilotMoon.Macro.Recorder:onPlayerDeath(player)
	if Rec.session and Rec.session.player == player
	then
		Rec:cancel();
	end
end

-- the player's master switch turned off (client/06_AP_Switch.lua): a recording is thrown away, with the reason over
-- the head (the game's queue gets its own add back at once); the preview of a finished one closes without saving
function AutoPilotMoon.Macro.Recorder:shutdown()
	local session = Rec.session;

	if session
	then
		Rec:cancel();
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_R_SwitchedOff"), session.player);
	end

	if Rec.preview
	then
		Rec.preview:close();
	end
end

-- "Non registrate: Sposta oggetti (3), Fornace: Fondi ... (1) - arriva piu' avanti" (nil: nothing)
function AutoPilotMoon.Macro.Recorder:ignoredText(session)
	local parts = {};

	if session.ignored.move > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_R_IgnoredMove", session.ignored.move));
	end

	if session.ignored.equip > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_R_IgnoredEquip", session.ignored.equip));
	end

	for i, key in ipairs(session.benchOrder)
	do
		local entry = session.benches[key];

		table.insert(parts, getText("IGUI_AutoPilot_R_IgnoredBench", entry.bench, entry.recipe, entry.count));
	end

	if (session.ignored.body or 0) > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_R_IgnoredBody", session.ignored.body));
	end

	if session.ignored.other > 0
	then
		table.insert(parts, getText("IGUI_AutoPilot_R_IgnoredOther", session.ignored.other));
	end

	if #parts == 0
	then
		return nil;
	end

	return getText("IGUI_AutoPilot_R_Ignored", table.concat(parts, ", "));
end

-- the panel's model of the recording (UI/Panel.lua): the last lines, numbered, and what was not recorded
function AutoPilotMoon.Macro.Recorder:panelLines(session)
	local lines = {};
	local first = math.max(1, #session.steps - Rec.visibleLines + 1);

	for i = first, #session.steps
	do
		table.insert(lines, i .. ". " .. Rec:stepText(session.steps[i]));
	end

	return lines;
end

-- ============================================================================================================
-- The macro's text (3.4)
-- ============================================================================================================

-- the date of the recording: the real one (os.date, used by the game's own admin panel), else the game's
function AutoPilotMoon.Macro.Recorder:dateText()
	local ok, text = pcall(function()
		return os.date("%d/%m/%Y");
	end);

	if ok and type(text) == "string" and text ~= ""
	then
		return text;
	end

	ok, text = pcall(function()
		local time = getGameTime();

		return string.format("%02d/%02d/%d", time:getDay() + 1, time:getMonth() + 1, time:getYear());
	end);

	if ok and type(text) == "string"
	then
		return text;
	end

	return nil;
end

-- mode "possible" / "times" (with n) / "once"
function AutoPilotMoon.Macro.Recorder:buildText(steps, mode, n, date)
	local lines = {};
	local indent = "";

	if date
	then
		table.insert(lines, "# " .. getText("IGUI_AutoPilot_R_RecordedOn", date));
	end

	if mode == "possible"
	then
		table.insert(lines, "while possible:");
		indent = AutoPilotMoon.Macro.Lang.indent;
	elseif mode == "times"
	then
		table.insert(lines, "repeat " .. n .. ":");
		indent = AutoPilotMoon.Macro.Lang.indent;
	end

	for i, step in ipairs(steps)
	do
		table.insert(lines, indent .. Rec:stepText(step));
	end

	return table.concat(lines, "\n");
end

-- the proposed name: the skill of the first recipe that gives experience and the main item ("Manutenzione - Testa di
-- martello a granchio"); a free one ("(2)" when it exists)
function AutoPilotMoon.Macro.Recorder:proposeName(steps)
	local Names = AutoPilotMoon.Macro.Names;
	local skill = nil;
	local item = nil;

	for i, step in ipairs(steps)
	do
		if skill == nil
		then
			local perks = Names:xpPerks(step.recipe);

			if perks[1]
			then
				skill = perks[1]:getName();
			end
		end

		if item == nil and step.mainType
		then
			item = Names:itemName(step.mainType);
		end
	end

	-- the first that fits the 40 characters of a name, never cut in the middle of a word
	local max = AutoPilotMoon.Macro.Store.maxNameChars;
	local candidates = {};

	if skill and item
	then
		table.insert(candidates, skill .. " - " .. item);
	end

	table.insert(candidates, item);
	table.insert(candidates, skill);
	table.insert(candidates, Names:recipeName(steps[1].recipe));

	local name = nil;

	for i = 1, 4
	do
		local candidate = candidates[i];

		if name == nil and candidate and string.len(candidate) <= max
		then
			name = candidate;
		end
	end

	if name == nil
	then
		name = item or skill or Names:recipeName(steps[1].recipe);
		name = string.match(string.sub(name, 1, max), "^(.*%S)%s") or string.sub(name, 1, max);
	end

	return AutoPilotMoon.Macro.Store:freeName(name);
end

-- ============================================================================================================
-- The preview window (3.4): the game's own window, modal for its player
-- ============================================================================================================

local Preview = {};

Rec.PreviewMethods = Preview;

function AutoPilotMoon.Macro.Recorder:createClasses()
	if Rec.PreviewWindow
	then
		return true;
	end

	if ISCollapsableWindowJoypad == nil or ISRadioButtons == nil or ISTextEntryBox == nil or AutoPilotMoon.Panel == nil
		or not AutoPilotMoon.Panel:createClasses()
	then
		return false;
	end

	Rec.PreviewWindow = ISCollapsableWindowJoypad:derive("AutoPilotMacroPreview");

	for name, fn in pairs(Preview)
	do
		Rec.PreviewWindow[name] = fn;
	end

	return true;
end

function AutoPilotMoon.Macro.Recorder:openPreview(session)
	if not Rec:createClasses()
	then
		return nil;
	end

	local playerNum = session.playerNum;
	local sizes = AutoPilotMoon.Panel:getSizes();
	local width = math.floor(math.max(sizes.minWidth * 1.6, 44 * sizes.small * 0.6));
	local x = getPlayerScreenLeft(playerNum) + math.floor((getPlayerScreenWidth(playerNum) - width) / 2);
	local y = getPlayerScreenTop(playerNum) + math.floor(getPlayerScreenHeight(playerNum) / 5);
	local window = Rec.PreviewWindow:new(x, y, width, 10 * sizes.row);

	window.playerNum = playerNum;
	window.player = session.player;
	window.sizes = sizes;
	window.session = session;
	window.steps = session.steps;
	window.ignoredText = Rec:ignoredText(session);
	window.date = Rec:dateText();
	window.titleBarFont = UIFont.Small;
	window:setTitle(getText("IGUI_AutoPilot_R_PreviewTitle"));
	window:initialise();
	window:instantiate();
	window:addToUIManager();
	window:setVisible(true);
	window:bringToTop();
	Rec.preview = window;

	if UI:isJoypad(playerNum)
	then
		setJoypadFocus(playerNum, window);
	end

	return window;
end

function Preview:createChildren()
	ISCollapsableWindowJoypad.createChildren(self);

	local sizes = self.sizes;
	local maxLoops = AutoPilotMoon.Sandbox:getInteger("MacroLoopsPerRun");

	self:setResizable(false);

	self.radio = ISRadioButtons:new(sizes.pad, 0, 10, 3 * sizes.button, self, Preview.onRepeat);
	self.radio:initialise();
	self.radio.choicesColor = { r = 0.9, g = 0.9, b = 0.9, a = 1 };
	self.radio:addOption(getText("IGUI_AutoPilot_R_RepeatPossible"));
	self.radio:addOption(getText("IGUI_AutoPilot_R_RepeatTimes"));
	self.radio:addOption(getText("IGUI_AutoPilot_R_RepeatOnce"));
	self.radio:setWidthToFit();
	self:addChild(self.radio);

	self.times = ISTextEntryBox:new(tostring(math.min(Rec.repeatTimes, maxLoops)), 0, 0, 5 * sizes.small, sizes.button);
	self.times:initialise();
	self.times:instantiate();
	self.times:setOnlyNumbers(true);
	self.times.onTextChangeFunction = Preview.onTimesChange;
	self.times.target = self;
	self:addChild(self.times);

	self.nameEntry = ISTextEntryBox:new(Rec:proposeName(self.steps) or "", 0, 0, 20 * sizes.small, sizes.button);
	self.nameEntry:initialise();
	self.nameEntry:instantiate();
	self.nameEntry:setMaxTextLength(AutoPilotMoon.Macro.Store.maxNameChars);
	self:addChild(self.nameEntry);

	self.saveOpenButton = AutoPilotMoon.Panel.Button:new(0, 0, 10, sizes.button, getText("IGUI_AutoPilot_R_SaveOpen"), self, Preview.onSaveOpen);
	self.saveOpenButton:initialise();
	self.saveOpenButton:enableAcceptColor();
	-- with a controller the A glyph sits left of the title (updateJoypad): the button grows to hold it
	self.saveOpenButton:setWidthToTitle(sizes.button * 3, UI:isJoypad(self.playerNum));
	self:addChild(self.saveOpenButton);

	self.saveButton = AutoPilotMoon.Panel.Button:new(0, 0, 10, sizes.button, getText("IGUI_AutoPilot_R_Save"), self, Preview.onSave);
	self.saveButton:initialise();
	self.saveButton:setWidthToTitle(sizes.button * 3);
	self:addChild(self.saveButton);

	self.discardButton = AutoPilotMoon.Panel.Button:new(0, 0, 10, sizes.button, getText("IGUI_AutoPilot_R_Discard"), self, Preview.onDiscard);
	self.discardButton:initialise();
	self.discardButton:enableCancelColor();
	self.discardButton:setWidthToTitle(sizes.button * 3);
	self:addChild(self.discardButton);

	local selected = 1;

	if Rec.repeatMode == "times"
	then
		selected = 2;
	elseif Rec.repeatMode == "once"
	then
		selected = 3;
	end

	self.radio:setSelected(selected);
	self:layout();
end

function Preview:getMode()
	if self.radio:isSelected(2)
	then
		return "times";
	elseif self.radio:isSelected(3)
	then
		return "once";
	end

	return "possible";
end

-- the number of times, within 1 and the server's loops (fixed by itself with the line "Il server ne permette...")
function Preview:getTimes()
	local maxLoops = AutoPilotMoon.Sandbox:getInteger("MacroLoopsPerRun");
	local n = tonumber(self.times:getText()) or 1;

	n = math.floor(n);

	if n > maxLoops
	then
		self.timesNote = getText("IGUI_AutoPilot_R_ServerMax", maxLoops);

		return maxLoops;
	end

	self.timesNote = nil;

	return math.max(1, n);
end

function Preview:onRepeat()
	self:layout();
end

function Preview:onTimesChange(entry)
	self:getTimes();
	self:layout();
end

local function measure(text)
	return getTextManager():MeasureStringX(UIFont.Small, text);
end

local function addOp(ops, text, x, y, color)
	table.insert(ops, { text = text, x = x, y = y, r = color.r, g = color.g, b = color.b });
end

-- every position (when something changes, never in render)
function Preview:layout()
	local sizes = self.sizes;
	local pad = sizes.pad;
	local ops = {};
	local text = UI.textColor;
	local y = self:titleBarHeight() + pad;
	local width = self.width;

	addOp(ops, getText("IGUI_AutoPilot_R_Steps", Rec:countSteps(self.session)), pad, y, UI.titleColor);
	y = y + sizes.row;

	local numberWidth = measure("00") + pad;

	for i, step in ipairs(self.steps)
	do
		local line = Rec:stepText(step);

		addOp(ops, tostring(i), pad + numberWidth - pad - measure(tostring(i)), y, AutoPilotMoon.Panel.colors.grey);
		addOp(ops, line, pad + numberWidth, y, text);
		width = math.max(width, measure(line) + numberWidth + 3 * pad);
		y = y + sizes.row;
	end

	if self.ignoredText
	then
		y = y + sizes.row / 2;
		addOp(ops, self.ignoredText, pad, y, AutoPilotMoon.Panel.colors.grey);
		width = math.max(width, measure(self.ignoredText) + 2 * pad);
		y = y + sizes.row;
		addOp(ops, getText("IGUI_AutoPilot_R_IgnoredHint"), pad, y, AutoPilotMoon.Panel.colors.grey);
		y = y + sizes.row;
	end

	y = y + sizes.row / 2;
	addOp(ops, getText("IGUI_AutoPilot_R_HowRepeat"), pad, y, text);
	y = y + sizes.row;
	self.radio:setX(pad * 2);
	self.radio:setY(y);

	local rowHeight = self.radio:getHeight() / 3;

	self.times:setX(self.radio:getX() + self.radio:getWidth() + pad);
	self.times:setY(y + rowHeight + (rowHeight - sizes.button) / 2);
	y = y + self.radio:getHeight() + pad / 2;

	if self.timesNote and self:getMode() == "times"
	then
		local r, g, b = UI:badColor();

		addOp(ops, self.timesNote, pad * 2, y, { r = r, g = g, b = b });
		y = y + sizes.row;
	end

	local label = getText("IGUI_AutoPilot_R_Name");

	-- the window's width before placing what sits on its right edge (the name's field, Scarta): wide enough for the
	-- name and the three buttons, at most 80% of the player's screen (before, Scarta and the field were placed for
	-- the wider window and ended outside it on a small screen with a big font)
	width = math.max(width, measure(label) + 20 * sizes.small + 3 * pad,
		self.saveOpenButton:getWidth() + self.saveButton:getWidth() + self.discardButton:getWidth() + 5 * pad);
	width = math.min(width, math.floor(getPlayerScreenWidth(self.playerNum) * 0.8));

	addOp(ops, label, pad, y + (sizes.button - sizes.small) / 2, text);
	self.nameEntry:setX(pad + measure(label) + pad);
	self.nameEntry:setY(y);
	self.nameEntry:setWidth(width - measure(label) - 3 * pad);
	y = y + sizes.button + pad;

	self.separatorY = y;
	y = y + pad;
	self.saveOpenButton:setX(pad);
	self.saveOpenButton:setY(y);
	self.saveButton:setX(pad + self.saveOpenButton:getWidth() + pad);
	self.saveButton:setY(y);
	self.discardButton:setX(width - pad - self.discardButton:getWidth());
	self.discardButton:setY(y);
	y = y + sizes.button + pad;

	self.ops = ops;
	self:setWidth(width);
	self:setHeight(y);
	self:updateJoypad();
end

function Preview:updateJoypad()
	if self.joypadReady
	then
		return;
	end

	self.joypadReady = true;
	self:clearJoypadButtonsList();
	self:insertNewLineOfButtons(self.radio);
	self:insertNewLineOfButtons(self.saveOpenButton, self.saveButton, self.discardButton);

	-- the A glyph only for a controller player (the preview takes the focus then): on a button it hides the
	-- background and the colours (ISButton 42.22), Salva e apri would lose its green for a mouse player
	if UI:isJoypad(self.playerNum)
	then
		self:setISButtonForA(self.saveOpenButton);
	end
end

function Preview:prerender()
	ISCollapsableWindowJoypad.prerender(self);

	if self.isCollapsed or self.ops == nil
	then
		return;
	end

	for i, entry in ipairs(self.ops)
	do
		self:drawText(entry.text, entry.x, entry.y, entry.r, entry.g, entry.b, 1, UIFont.Small);
	end

	if self.separatorY
	then
		self:drawRect(self.sizes.pad, self.separatorY, self.width - 2 * self.sizes.pad, 1, 1, 0.4, 0.4, 0.4);
	end
end

-- saves the macro with the chosen repeat and name; returns it (nil: 50 macros already)
function Preview:save()
	local Store = AutoPilotMoon.Macro.Store;
	local mode = self:getMode();
	local times = self:getTimes();

	Rec.repeatMode = mode;
	Rec.repeatTimes = times;

	local text = Rec:buildText(self.steps, mode, times, self.date);
	local macro, why = Store:add(self.nameEntry:getText(), text);

	if macro == nil
	then
		AutoPilotMoon:say("bad", getText("IGUI_AutoPilot_E_Full", Store.maxMacros), self.player);

		return nil;
	end

	Store:save(true);
	self:close();

	return macro;
end

function Preview:onSaveOpen()
	local macro = self:save();

	if macro and AutoPilotMoon.Macro.Editor
	then
		AutoPilotMoon.Macro.Editor:open(self.playerNum, macro.name, true);
	end
end

function Preview:onSave()
	self:save();
end

function Preview:onDiscard()
	local dialog = ISModalDialog:new(0, 0, 300, 120, getText("IGUI_AutoPilot_R_CancelConfirm", Rec:countSteps(self.session)), true, self, Preview.onDiscardAnswer, self.playerNum);

	dialog:initialise();
	dialog:addToUIManager();
end

function Preview:onDiscardAnswer(button)
	if button.internal == "YES"
	then
		self:close();
	end
end

function Preview:close()
	ISCollapsableWindowJoypad.close(self);
	self:removeFromUIManager();

	if Rec.preview == self
	then
		Rec.preview = nil;
	end

	local joypadData = JoypadState.players[self.playerNum + 1];

	if joypadData and joypadData.focus == self
	then
		setJoypadFocus(self.playerNum, nil);
	end
end

function Preview:onJoypadDown(button, joypadData)
	if button == Joypad.BButton
	then
		self:onDiscard();

		return;
	end

	ISCollapsableWindowJoypad.onJoypadDown(self, button, joypadData);
end

-- the controller's focus starts on "Salva e apri", the button with the A glyph: ISPanelJoypad gives A to the focused
-- control first, and without this the focus was on the repeat choice (the first row, not even marked), so A only chose
-- "Finche' si puo'" again and never saved; up reaches the repeat choice
function Preview:onGainJoypadFocus(joypadData)
	ISCollapsableWindowJoypad.onGainJoypadFocus(self, joypadData);
	self.drawJoypadFocus = true;
	self:setJoypadFocus(self.saveOpenButton, joypadData);
end
