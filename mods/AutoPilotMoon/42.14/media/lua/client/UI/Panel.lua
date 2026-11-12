-- AutoPilot (Moon): automations for the Moon server.

-- The AutoPilot panel (phase D, 11/11/2026, spec UX-AUTOPILOT.md 2.3, 2.4, 7): a small window of the game's own kind
-- (ISCollapsableWindowJoypad: title bar, close, collapse, "?" guide; resized in width only) that never starts a job.
-- It shows the job running for its player: icon, title, time, phase i of n, a bar with "Unit: done / total", "Now:",
-- the confirmed counters, the phases of a chain with words (done / running / next), at most two warnings grouped by
-- reason, the rest bar while the character rests; at rest the last job's summary. Buttons: Ferma (the game's cancel
-- colour) and Opzioni (the quick options: the very same values as Esc > Options > Mods, written with Options:set).
--
-- The macros (experimental, MACRO-AUTOPILOT.md 3.1, 5.5): a running macro words its own title, second line and
-- experience (Progress titleText, loopText, doneText, icon) and has the button "Editor"; at rest, with the macros on
-- the server, the button "Macro" opens the editor. While the player records a macro the panel shows the recording: a
-- dot in the bad colour that blinks every second beside the words "Registrazione macro", the time, the last lines
-- recorded (each only once confirmed), what was not recorded, "Fine registrazione" (accept) and "Annulla" (cancel).
--
-- One window per local player (split screen), created on first use. It opens by itself when a job starts (option
-- openPanelOnStart), from the menu's "Pannello AutoPilot" (with a controller it then takes the focus: A = Ferma, B =
-- close) and with the player's key (option panelKey, never while typing in the chat). It never closes by itself during
-- a job; at the end it keeps the summary and, if it opened by itself, collapses after 30 s without the mouse over it
-- (the summary stays readable in the title). A dead character's panel closes. Position, width and pin are remembered
-- with ISLayoutManager ("AutoPilotMoon", one name per local player).
--
-- Cost (spec 2.3, 7.3): the Progress observer only notes that something changed; the texts are worked out in
-- update(), at most Panel.minRebuildMs apart and only when the state's revision changed (or the clock's second); a
-- hidden window is not updated at all. prerender/render draw strings already made, at positions already computed:
-- no getText, no string.format, no new table there. Every size comes from the game's font heights (spec 1.7, 7.2).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Panel = AutoPilotMoon.Panel or {};

local Panel = AutoPilotMoon.Panel;
local UI = AutoPilotMoon.UI;

Panel.windows = Panel.windows or {};      -- playerNum -> window
Panel.minRebuildMs = 250;                 -- the texts are worked out at most 4 times a second
Panel.autoCollapseMs = 30000;             -- after the end, a panel that opened by itself collapses
Panel.layoutName = "AutoPilotMoon";
Panel.maxWarnings = 2;
Panel.maxWidthShare = 0.4;                -- of the player's screen
Panel.icons = Panel.icons or {};          -- job or chain name -> texture or false
Panel.ownerNum = nil;                     -- the local player of the running job
Panel.lastOwnerNum = nil;                 -- the local player of the last job (its summary)

-- the colours of the spec (1.1): the XUI palette of the game, good/bad from the game (colour-blind option)
Panel.colors = {
	progress = { r = 1, g = 0.95, b = 0.45 },      -- C_ProgressYellow
	complete = { r = 0.2, g = 1, b = 0.2 },        -- C_ProgressGreen
	grey = { r = 0.6, g = 0.6, b = 0.6 },
};

-- ============================================================================================================
-- The model: the texts of the panel for a player, worked out from AutoPilotMoon.Progress.state
-- ============================================================================================================

-- the local player whose job runs now (nil: none)
function AutoPilotMoon.Panel:getRunningOwnerNum()
	local job = AutoPilotMoon.Automation.job;
	local chainRun = AutoPilotMoon.Chain.current;
	local player = (job and job.player) or (chainRun and chainRun.player);

	return player and player:getPlayerNum() or nil;
end

local function formatClock(ms)
	local seconds = math.floor(math.max(ms, 0) / 1000);

	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60);
end

-- "Saltati: 2 (non raggiungibili)" for the reasons of the engine and of the automations (A_Skip_*), "<text> (n)" for a
-- warning that is a whole sentence ("Cadavere lasciato dove si e' bloccato (1)")
local function warningText(key, count)
	if string.find(key, "IGUI_AutoPilot_A_Skip_", 1, true) == 1
	then
		return getText("IGUI_AutoPilot_A_SkippedGroup", getText("IGUI_AutoPilot_P_C_Skipped", count), getText(key));
	end

	return getText("IGUI_AutoPilot_A_SkippedGroup", getText(key), count);
end

local function addWarnings(list, source)
	if source.skipped and source.skipped > 0
	then
		table.insert(list, warningText("IGUI_AutoPilot_A_Skip_Unreachable", source.skipped));
	end

	for i, key in ipairs(source.warningOrder)
	do
		if #list >= Panel.maxWarnings
		then
			break;
		end

		table.insert(list, warningText(key, source.warnings[key]));
	end
end

-- the confirmed counters as one line ("Alberi abbattuti: 18 - Tronchi segati: 12"), nil when there is none
local function countersLine(source)
	local parts = {};

	for i, key in ipairs(source.counterOrder)
	do
		table.insert(parts, getText(key, source.counters[key]));
	end

	if #parts == 0
	then
		return nil;
	end

	return table.concat(parts, " - ");
end

-- the icon of a job or a chain: its menu entry's (JobMenu, the item script's texture), read once
function AutoPilotMoon.Panel:getIcon(name)
	if name == nil
	then
		return nil;
	end

	local icon = Panel.icons[name];

	if icon == nil
	then
		icon = false;

		for i, id in ipairs(AutoPilotMoon.JobMenu.order)
		do
			local spec = AutoPilotMoon.JobMenu.specs[id];

			if (spec.job == name or spec.chain == name) and type(spec.icon) == "string"
			then
				icon = AutoPilotMoon.JobMenu:getScriptTexture(spec.icon) or false;

				break;
			end
		end

		Panel.icons[name] = icon;
	end

	return icon or nil;
end

local function lastStatus(summary)
	if summary.reason == "done"
	then
		return getText("IGUI_AutoPilot_P_Last_Done");
	elseif summary.reason == "user"
	then
		return getText("IGUI_AutoPilot_P_Last_StoppedUser");
	end

	return getText("IGUI_AutoPilot_P_Last_Stopped", summary.reasonText or getText("IGUI_AutoPilot_A_Reason_Disabled"));
end

-- the text of the macros' button: "Editor" while a macro of this player runs, "Macro" at rest when the server has the
-- macros on and the player shows them, nil otherwise (another job running, macros off)
function AutoPilotMoon.Panel:macroButtonText(runningForPlayer)
	local Macro = AutoPilotMoon.Macro;

	if Macro == nil or Macro.Run == nil or not AutoPilotMoon.Automation:isEnabled("macro")
	then
		return nil;
	end

	if runningForPlayer
	then
		if Macro.Run:getRunningName()
		then
			return getText("IGUI_AutoPilot_P_MacroEditor");
		end

		return nil;
	end

	if AutoPilotMoon.Automation:isBusy()
	then
		return nil;
	end

	return getText("IGUI_AutoPilot_P_Macro");
end

-- the recording of a macro by this player (MACRO-AUTOPILOT.md 3.1): its model, or nil
function AutoPilotMoon.Panel:buildRecording(model, playerNum, now)
	local Rec = AutoPilotMoon.Macro and AutoPilotMoon.Macro.Recorder;
	local session = Rec and Rec.session;

	if session == nil or session.playerNum ~= playerNum
	then
		return nil;
	end

	local count = Rec:countSteps(session);

	model.recording = true;
	model.running = false;
	model.macroButton = nil;
	model.recRevision = Rec.revision;
	model.jobTitle = getText("IGUI_AutoPilot_R_Title");
	model.second = math.floor((now - session.startedAt) / 1000);
	model.clock = formatClock(now - session.startedAt);
	model.recordStartedAt = session.startedAt;
	model.phaseLine = getText("IGUI_AutoPilot_R_How");
	model.recLines = Rec:panelLines(session);

	if #session.pending > 0
	then
		model.nowLine = getText("IGUI_AutoPilot_P_Now", getText("IGUI_AutoPilot_P_Waiting"));
	end

	model.warnings = {};
	model.ignoredLine = Rec:ignoredText(session);

	if session.notConfirmed
	then
		table.insert(model.warnings, session.notConfirmed);
	end

	model.collapsedTitle = getText("IGUI_AutoPilot_R_TitleCollapsed", count);

	return model;
end

-- Builds the model of the panel of playerNum at time now. Running (for this player): title, clock, phase line, bar
-- (progress 0..1, text, colour), "Now:", counters, phases of a chain, warnings, collapsed title. At rest: the idle
-- lines and the last job's summary (if it was this player's).
function AutoPilotMoon.Panel:buildModel(playerNum, now)
	local state = AutoPilotMoon.Progress.state;
	local model = { builtAt = now, revision = state.revision };

	model.title = getText("IGUI_AutoPilot_P_Title");
	model.macroButton = Panel:macroButtonText(state.running and Panel:getRunningOwnerNum() == playerNum);

	local recording = Panel:buildRecording(model, playerNum, now);

	if recording
	then
		return recording;
	end

	if state.running and Panel:getRunningOwnerNum() == playerNum
	then
		model.running = true;
		model.jobTitle = state.titleText or (state.titleKey and getText(state.titleKey)) or "";
		model.icon = state.icon or Panel:getIcon(state.name);
		model.second = math.floor((now - state.startedAt) / 1000);
		model.clock = formatClock(now - state.startedAt);

		local percent = 0;

		if state.kind == "chain" and state.phase > 0
		then
			local phase = state.phases[state.phase];

			model.phaseLine = getText("IGUI_AutoPilot_P_Phase", state.phase, state.phaseCount, phase and getText(phase.labelKey) or "");
			model.phases = {};

			for i, entry in ipairs(state.phases)
			do
				local status = nil;
				local color = UI.textColor;

				if entry.status == "done"
				then
					status = getText("IGUI_AutoPilot_P_PhaseDone", entry.done);
					color = "good";
				elseif entry.status == "running"
				then
					status = getText("IGUI_AutoPilot_P_PhaseNow");
					color = UI.titleColor;
				elseif entry.status == "skipped"
				then
					status = getText("IGUI_AutoPilot_A_Skip_Nothing");
					color = Panel.colors.grey;
				else
					status = getText("IGUI_AutoPilot_P_PhaseNext");
					color = Panel.colors.grey;
				end

				table.insert(model.phases, { label = i .. ". " .. getText(entry.labelKey), status = status, color = color });
			end
		end

		if state.resting
		then
			local player = getSpecificPlayer(playerNum);
			local current = player and AutoPilotMoon.Rest:getEndurancePercent(player) or state.restFrom;
			local span = state.restTo - state.restFrom;

			model.barProgress = span > 0 and (current - state.restFrom) / span or 0;
			model.barText = getText("IGUI_AutoPilot_P_Resting", state.restFrom, state.restTo);
			model.barColor = UI.inputColor;
		elseif state.total > 0
		then
			model.barProgress = state.done / state.total;
			model.barText = getText("IGUI_AutoPilot_P_Bar", getText(state.unitKey or "IGUI_AutoPilot_S_Unit_Squares"), state.done, state.total);
			model.barColor = state.done >= state.total and Panel.colors.complete or Panel.colors.progress;
		end

		if model.barProgress
		then
			model.barProgress = math.max(0, math.min(1, model.barProgress));
			percent = math.floor(model.barProgress * 100);
		end

		if state.waiting
		then
			model.nowLine = getText("IGUI_AutoPilot_P_Now", getText("IGUI_AutoPilot_P_Waiting"));
		elseif state.activityKey
		then
			model.nowLine = getText("IGUI_AutoPilot_P_Now", getText(state.activityKey, state.activityArg1, state.activityArg2));
		end

		if state.loopText and state.kind ~= "chain"
		then
			model.phaseLine = state.loopText;
		end

		local counters = countersLine(state);

		if state.doneText
		then
			counters = counters and (counters .. " - " .. state.doneText) or state.doneText;
		end

		if counters
		then
			model.doneLine = getText("IGUI_AutoPilot_P_Done", counters);
		end

		model.warnings = {};
		addWarnings(model.warnings, state);

		if state.kind == "chain"
		then
			model.collapsedTitle = getText("IGUI_AutoPilot_P_TitleCollapsed", model.jobTitle, state.phase .. "/" .. state.phaseCount, percent);
		else
			model.collapsedTitle = getText("IGUI_AutoPilot_P_TitleCollapsedJob", model.jobTitle, percent);
		end

		return model;
	end

	model.running = false;
	model.idleLines = { getText("IGUI_AutoPilot_P_Idle"), getText("IGUI_AutoPilot_P_IdleHow") };
	model.collapsedTitle = model.title;

	local summary = state.summary;

	if summary and Panel.lastOwnerNum == playerNum and not state.running
	then
		local title = summary.titleText or (summary.titleKey and getText(summary.titleKey)) or "";
		local status = lastStatus(summary);

		model.lastLine = getText("IGUI_AutoPilot_P_Last", title, status);
		model.lastCounters = countersLine(summary);

		if summary.doneText
		then
			model.lastCounters = model.lastCounters and (model.lastCounters .. " - " .. summary.doneText) or summary.doneText;
		end
		model.lastDone = summary.reason == "done";
		model.warnings = {};
		addWarnings(model.warnings, summary);
		model.collapsedTitle = getText("IGUI_AutoPilot_P_TitleLast", title, status);
	end

	return model;
end

-- ============================================================================================================
-- The window
-- ============================================================================================================

-- the game's sizes (spec 1.7, 7.2): read from the font heights, never fixed
function AutoPilotMoon.Panel:getSizes()
	local small = getTextManager():getFontHeight(UIFont.Small);
	local medium = getTextManager():getFontHeight(UIFont.Medium);

	return {
		small = small,
		medium = medium,
		row = small + 4,
		button = small + 6,
		pad = UI.spacing,
		minWidth = 20 * small,
	};
end

local function measure(font, text)
	return getTextManager():MeasureStringX(font, text);
end

-- After the window's own setWidth / setHeight: the frame's pieces where ISCollapsableWindow put them for that size (the
-- corner handle and the bottom bar, the collapse / pin button at the right of the title bar). They follow the window
-- only through the anchors of zombie.ui.UIElement, which apply the change of the last setWidth / setHeight before the
-- next update: two layouts in a row (created, then opened) lost the change, and in the game the corner handle stayed
-- where the window's first size put it (dragging the drawn corner did nothing). The pending change is dropped and the
-- pieces are placed here, as the game's own windows do with their scroll bars.
function AutoPilotMoon.Panel:fitFrame(window)
	window:ignoreWidthChange();
	window:ignoreHeightChange();

	local width = window:getWidth();
	local height = window:getHeight();
	local rh = window:resizeWidgetHeight();
	local button = window:titleBarHeight() - 2;

	if window.resizeWidget
	then
		window.resizeWidget:setX(width - rh);
		window.resizeWidget:setY(height - rh);
	end

	if window.resizeWidget2
	then
		window.resizeWidget2:setY(height - rh);
		window.resizeWidget2:setWidth(width - rh);
	end

	if window.pinButton
	then
		window.pinButton:setX(width - 1 - button);
	end

	if window.collapseButton
	then
		window.collapseButton:setX(width - 1 - button);
	end
end

-- the words of text in lines of at most width pixels (a word longer than the line stays whole)
local function wrap(font, text, width)
	local lines = {};

	if measure(font, text) <= width
	then
		table.insert(lines, text);

		return lines;
	end

	local current = nil;

	for word in string.gmatch(text, "%S+")
	do
		local candidate = current and (current .. " " .. word) or word;

		if current and measure(font, candidate) > width
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

local function colorOf(color)
	if color == "good"
	then
		local r, g, b = UI:goodColor();

		return { r = r, g = g, b = b };
	elseif color == "bad"
	then
		local r, g, b = UI:badColor();

		return { r = r, g = g, b = b };
	end

	return color or UI.textColor;
end

-- the controls with the player's sound option (spec 4.4): the game's own classes, their click without the game's
-- unconditional sound, ours (UI:playSound) instead. Same logic as ISButton / ISTickBox / ISComboBox of 42.22.

function AutoPilotMoon.Panel:createClasses()
	if Panel.Window
	then
		return true;
	end

	if ISCollapsableWindowJoypad == nil or ISButton == nil or ISTickBox == nil or ISComboBox == nil or ISProgressBar == nil
	then
		return false;
	end

	local Button = ISButton:derive("AutoPilotPanelButton");

	function Button:onMouseUp(x, y)
		if not self:getIsVisible()
		then
			return;
		end

		local process = self.pressed == true;

		self.pressed = false;

		if self.onclick == nil
		then
			return;
		end

		if self.enable and (process or self.allowMouseUpProcessing)
		then
			UI:playSound(self.sounds.activate);
			self.onclick(self.target, self, self.onClickArgs[1], self.onClickArgs[2], self.onClickArgs[3], self.onClickArgs[4]);
		end
	end

	function Button:forceClick()
		if not self:getIsVisible() or not self.enable
		then
			return;
		end

		UI:playSound(self.sounds.activate);
		self.onclick(self.target, self, self.onClickArgs[1], self.onClickArgs[2], self.onClickArgs[3], self.onClickArgs[4]);
	end

	local TickBox = ISTickBox:derive("AutoPilotPanelTickBox");

	local function toggle(self, index)
		UI:playSound("UIToggleTickBox");
		self.selected[index] = not self.selected[index];

		if self.changeOptionMethod ~= nil
		then
			self.changeOptionMethod(self.changeOptionTarget, index, self.selected[index], self.changeOptionArgs[1], self.changeOptionArgs[2], self);
		end
	end

	function TickBox:onMouseUp(x, y)
		local clickedOption = self.clickedOption;

		self.clickedOption = nil;

		if not clickedOption or clickedOption ~= self.mouseOverOption
		then
			return false;
		end

		if self.enable and self.mouseOverOption ~= nil and self.mouseOverOption > 0 and self.mouseOverOption < self.optionCount
			and not self.disabledOptions[self.optionsIndex[self.mouseOverOption]]
		then
			toggle(self, self.mouseOverOption);
		end

		return false;
	end

	function TickBox:forceClick()
		if self.disabledOptions[self.optionsIndex[self.joypadIndex]]
		then
			return;
		end

		toggle(self, self.joypadIndex);
	end

	local Combo = ISComboBox:derive("AutoPilotPanelComboBox");

	function Combo:showPopup()
		UI:playSound("UIToggleComboBox");
		self.popup:setFont(self.font, 4);
		self.popup:setComboBox(self);
		self.popup:addToUIManager();
	end

	function Combo:hidePopup()
		UI:playSound("UIToggleComboBox");
		self.popup:removeFromUIManager();
	end

	Panel.Button = Button;
	Panel.TickBox = TickBox;
	Panel.Combo = Combo;
	Panel.Window = ISCollapsableWindowJoypad:derive("AutoPilotPanel");

	for name, fn in pairs(Panel.WindowMethods)
	do
		Panel.Window[name] = fn;
	end

	return true;
end

local W = {};

Panel.WindowMethods = W;

function W:createChildren()
	ISCollapsableWindowJoypad.createChildren(self);

	local sizes = self.sizes;

	self:setInfo(getText("IGUI_AutoPilot_P_Info"));
	self:setResizable(true);

	-- width only (spec 2.3): the corner resizes the width, the bottom bar is not offered; the height follows the content
	if self.resizeWidget
	then
		self.resizeWidget.resizeFunction = function(target, width, height)
			target.userWidth = width;
			target:relayout();
		end;
	end

	if self.resizeWidget2
	then
		self.resizeWidget2:setVisible(false);
	end

	self.bar = ISProgressBar:new(sizes.pad, 0, 100, sizes.small, nil, UIFont.Small);
	self.bar:initialise();
	self.bar:setVisible(false);
	self:addChild(self.bar);

	self.stopButton = Panel.Button:new(sizes.pad, 0, 10, sizes.button, getText("IGUI_AutoPilot_P_Stop"), self, W.onStop);
	self.stopButton:initialise();
	self.stopButton:enableCancelColor();
	self.stopButton:setWidthToTitle(sizes.button * 3);
	self.stopButton:setVisible(false);
	self:addChild(self.stopButton);

	-- the macros (experimental): "Editor" / "Macro", and the recording's two buttons
	self.macroButton = Panel.Button:new(sizes.pad, 0, 10, sizes.button, getText("IGUI_AutoPilot_P_Macro"), self, W.onMacro);
	self.macroButton:initialise();
	self.macroButton:setWidthToTitle(sizes.button * 3);
	self.macroButton:setVisible(false);
	self:addChild(self.macroButton);

	self.finishRecordButton = Panel.Button:new(sizes.pad, 0, 10, sizes.button, getText("IGUI_AutoPilot_R_Finish"), self, W.onFinishRecording);
	self.finishRecordButton:initialise();
	self.finishRecordButton:enableAcceptColor();
	self.finishRecordButton:setWidthToTitle(sizes.button * 3);
	self.finishRecordButton:setVisible(false);
	self:addChild(self.finishRecordButton);

	self.cancelRecordButton = Panel.Button:new(sizes.pad, 0, 10, sizes.button, getText("IGUI_AutoPilot_R_Cancel"), self, W.onCancelRecording);
	self.cancelRecordButton:initialise();
	self.cancelRecordButton:enableCancelColor();
	self.cancelRecordButton:setWidthToTitle(sizes.button * 3);
	self.cancelRecordButton:setVisible(false);
	self:addChild(self.cancelRecordButton);

	-- the game's own filled circle (its radio buttons' indicator), tinted with the bad colour when drawn
	self.recordDot = getTexture("media/ui/RadioButtonIndicator.png");

	self.optionsButton = Panel.Button:new(sizes.pad, 0, 10, sizes.button, getText("IGUI_AutoPilot_P_Options"), self, W.onOptions);
	self.optionsButton:initialise();
	self.optionsButton:setWidthToTitle(sizes.button * 3);
	self:addChild(self.optionsButton);

	-- the quick options (spec 2.4), shown under the buttons by "Opzioni"
	local spec = AutoPilotMoon.Options.specs.haloMode;

	self.haloCombo = Panel.Combo:new(sizes.pad, 0, 10, sizes.button, self, W.onHaloMode);
	self.haloCombo:initialise();

	for i, key in ipairs(spec.itemKeys)
	do
		self.haloCombo:addOption(getText(key));
	end

	self.haloCombo:setWidthToOptions(sizes.button * 4);
	self.haloCombo:setVisible(false);
	self:addChild(self.haloCombo);

	self.ticks = Panel.TickBox:new(sizes.pad, 0, sizes.small, sizes.small, "", self, W.onTick);
	self.ticks:initialise();
	self.ticks.choicesColor = { r = 0.9, g = 0.9, b = 0.9, a = 1 };
	self.tickKeys = { "openPanelOnStart", "showJobArea", "uiSounds", "autoRest" };
	self.tickLabels = {
		getText("IGUI_AutoPilot_MO_OpenPanel"),
		getText("IGUI_AutoPilot_MO_ShowArea"),
		getText("IGUI_AutoPilot_MO_Sounds"),
		getText("IGUI_AutoPilot_MO_AutoRest"),
	};
	self.autoRestOffLabel = getText("IGUI_AutoPilot_MO_AutoRest") .. " - " .. getText("IGUI_AutoPilot_MO_AutoRest_Off");
	self.ticks:setVisible(false);
	self:addChild(self.ticks);

	self:rebuild(getTimestampMs());
end

-- the quick options: the values of the game's Options, read when the section opens (they may change in Esc > Options)
function W:syncOptions()
	local spec = AutoPilotMoon.Options.specs.haloMode;
	local mode = AutoPilotMoon.Options:get("haloMode");

	for i, value in ipairs(spec.values)
	do
		if value == mode
		then
			self.haloCombo.selected = i;
		end
	end

	local serverRest = AutoPilotMoon.Sandbox:getBoolean("EnableAutoRest");

	self.ticks:clearOptions();

	for i, key in ipairs(self.tickKeys)
	do
		local label = self.tickLabels[i];

		if key == "autoRest" and not serverRest
		then
			label = self.autoRestOffLabel;
		end

		self.ticks:addOption(label);
		self.ticks:setSelected(i, AutoPilotMoon.Options:get(key) == true);

		if key == "autoRest" and not serverRest
		then
			self.ticks:disableOption(label, true);
		end
	end

	self.ticks:setWidthToFit();
end

function W:onStop()
	AutoPilotMoon.Automation:stopAll("user");
end

function W:onMacro()
	local Macro = AutoPilotMoon.Macro;

	if Macro
	then
		Macro.Editor:open(self.playerNum, Macro.Run:getRunningName(), true);
	end
end

function W:onFinishRecording()
	AutoPilotMoon.Macro.Recorder:finish();
end

function W:onCancelRecording()
	AutoPilotMoon.Macro.Recorder:askCancel();
end

function W:onOptions()
	self.showOptions = not self.showOptions;

	if self.showOptions
	then
		self:syncOptions();
	end

	self:relayout();
end

function W:onHaloMode(combo)
	local spec = AutoPilotMoon.Options.specs.haloMode;

	AutoPilotMoon.Options:set("haloMode", spec.values[combo.selected]);
end

function W:onTick(index, selected)
	local key = self.tickKeys[index];

	if key
	then
		AutoPilotMoon.Options:set(key, selected == true);
	end
end

-- the texts again (from update, at most every Panel.minRebuildMs, only when something changed)
function W:rebuild(now)
	self.dirty = false;
	self.model = Panel:buildModel(self.playerNum, now);
	self:relayout();
end

-- adds a text to draw (ops are made here, never in render)
local function op(ops, text, x, y, color, font, right)
	local c = colorOf(color);

	table.insert(ops, { text = text, x = x, y = y, r = c.r, g = c.g, b = c.b, font = font or UIFont.Small, right = right });
end

-- the positions of everything, the width and the height (spec 2.3: margin 10, row = small font + 4, the title in the
-- medium font, minimum width 20 x small font, then the longest line up to 40% of the screen, longer lines wrap)
function W:relayout()
	local model = self.model;
	local sizes = self.sizes;

	if model == nil
	then
		return;
	end

	if not self.showOptions
	then
		self.compactOptions = false;
	end

	local compact = self.compactOptions == true;

	local pad = sizes.pad;
	local maxWidth = math.floor(getPlayerScreenWidth(self.playerNum) * Panel.maxWidthShare);
	local iconSize = sizes.medium;

	-- the width the texts want (measured here, when they change)
	local wanted = sizes.minWidth;
	local function want(font, text, extra)
		if text
		then
			wanted = math.max(wanted, measure(font, text) + 2 * pad + (extra or 0));
		end
	end

	if model.running
	then
		want(UIFont.Medium, model.jobTitle, iconSize + pad + measure(UIFont.Small, "00:00") + pad);
		want(UIFont.Small, model.phaseLine, iconSize + pad);
		want(UIFont.Small, model.nowLine);
		want(UIFont.Small, model.doneLine);

		if model.barText
		then
			want(UIFont.Small, model.barText, 6 * sizes.small + pad);
		end

		for i, phase in ipairs(model.phases or {})
		do
			want(UIFont.Small, phase.label .. "    " .. phase.status);
		end
	elseif model.recording
	then
		want(UIFont.Medium, model.jobTitle, sizes.small + pad + measure(UIFont.Small, "00:00") + pad);

		for i, text in ipairs(model.recLines)
		do
			want(UIFont.Small, text);
		end

		want(UIFont.Small, model.phaseLine);
		want(UIFont.Small, model.nowLine);
	else
		for i, text in ipairs(model.idleLines)
		do
			want(UIFont.Small, text);
		end

		want(UIFont.Small, model.lastLine);
		want(UIFont.Small, model.lastCounters);
	end

	for i, text in ipairs(model.warnings or {})
	do
		want(UIFont.Small, text);
	end

	local width = math.max(self.userWidth or 0, wanted);

	width = math.max(sizes.minWidth, math.min(width, maxWidth));

	local inner = width - 2 * pad;
	local ops = {};
	local y = self:titleBarHeight() + pad;
	local function lines(text, color, indent)
		if text == nil
		then
			return;
		end

		for i, line in ipairs(wrap(UIFont.Small, text, inner - (indent or 0)))
		do
			op(ops, line, pad + (indent or 0), y, color);
			y = y + sizes.row;
		end
	end

	self.iconY = nil;
	self.clockOp = nil;
	self.dotY = nil;

	if model.recording
	then
		-- the dot (drawn in prerender, blinking), the words, the time
		self.dotY = y + (sizes.medium - sizes.small) / 2;
		op(ops, model.jobTitle, pad + sizes.small + pad / 2, y, UI.titleColor, UIFont.Medium);
		op(ops, model.clock, width - pad, y + (sizes.medium - sizes.small) / 2, UI.textColor, UIFont.Small, true);
		self.clockOp = ops[#ops];
		y = y + sizes.medium + 4;
		lines(model.phaseLine, UI.textColor);

		for i, text in ipairs(compact and {} or model.recLines)
		do
			lines(text, UI.textColor);
		end

		lines(model.nowLine, UI.textColor);
		lines(model.ignoredLine, Panel.colors.grey);
		self.bar:setVisible(false);
	elseif model.running
	then
		-- icon, title, time
		local titleX = pad;

		if model.icon
		then
			self.iconY = y;
			titleX = pad + iconSize + pad;
		end

		op(ops, model.jobTitle, titleX, y, UI.titleColor, UIFont.Medium);
		op(ops, model.clock, width - pad, y + (sizes.medium - sizes.small) / 2, UI.textColor, UIFont.Small, true);
		self.clockOp = ops[#ops];
		y = y + sizes.medium + 4;

		if model.phaseLine
		then
			lines(model.phaseLine, UI.textColor, titleX - pad);
		end

		-- the bar, its text on the right
		if model.barProgress
		then
			local textWidth = measure(UIFont.Small, model.barText);
			local barWidth = math.max(inner - textWidth - pad, 4 * sizes.small);

			self.bar:setX(pad);
			self.bar:setY(y + 2);
			self.bar:setWidth(barWidth);
			self.bar:setHeight(sizes.small);
			self.bar:setProgress(model.barProgress);
			self.bar.progressColor = { r = model.barColor.r, g = model.barColor.g, b = model.barColor.b, a = 1 };
			self.bar:setVisible(true);
			op(ops, model.barText, pad + barWidth + pad, y + 2, UI.textColor);
			y = y + sizes.row + 4;
		else
			self.bar:setVisible(false);
		end

		lines(model.nowLine, UI.textColor);

		if not compact
		then
			lines(model.doneLine, UI.textColor);
		end

		if model.phases and not compact
		then
			local column = 0;

			for i, phase in ipairs(model.phases)
			do
				column = math.max(column, measure(UIFont.Small, phase.label));
			end

			for i, phase in ipairs(model.phases)
			do
				op(ops, phase.label, pad, y, phase.color);
				op(ops, phase.status, pad + column + 2 * pad, y, phase.color);
				y = y + sizes.row;
			end
		end
	else
		self.bar:setVisible(false);

		for i, text in ipairs(model.idleLines)
		do
			lines(text, UI.textColor);
		end

		if model.lastLine
		then
			y = y + sizes.row / 2;
			lines(model.lastLine, model.lastDone and "good" or UI.textColor);
			lines(model.lastCounters, UI.textColor);
		end
	end

	for i, text in ipairs(compact and {} or model.warnings or {})
	do
		lines(text, "bad");
	end

	-- the line above the buttons, then the buttons: Ferma on the left (running only), Opzioni on the right
	y = y + pad / 2;
	self.separatorY = y;
	y = y + pad / 2;

	-- with the controller's focus the A glyph sits left of the title: the button grows to hold it (ISButton 42.22)
	self.stopButton:setWidthToTitle(sizes.button * 3, self.joyfocus ~= nil);
	self.finishRecordButton:setWidthToTitle(sizes.button * 3, self.joyfocus ~= nil);
	self.stopButton:setVisible(model.running == true);
	self.stopButton:setX(pad);
	self.stopButton:setY(y);
	self.optionsButton:setX(width - pad - self.optionsButton:getWidth());
	self.optionsButton:setY(y);
	self.finishRecordButton:setVisible(model.recording == true);
	self.finishRecordButton:setX(pad);
	self.finishRecordButton:setY(y);
	self.cancelRecordButton:setVisible(model.recording == true);
	self.cancelRecordButton:setX(pad + self.finishRecordButton:getWidth() + pad);
	self.cancelRecordButton:setY(y);
	self.macroButton:setVisible(model.macroButton ~= nil);

	if model.macroButton
	then
		if self.macroButton.title ~= model.macroButton
		then
			self.macroButton:setTitle(model.macroButton);
			self.macroButton:setWidthToTitle(sizes.button * 3);
		end

		self.macroButton:setX(self.optionsButton:getX() - pad - self.macroButton:getWidth());
		self.macroButton:setY(y);
	end
	y = y + sizes.button + pad;

	if self.showOptions
	then
		op(ops, getText("IGUI_AutoPilot_MO_Halo"), pad, y + (sizes.button - sizes.small) / 2, UI.textColor);
		self.haloCombo:setX(width - pad - self.haloCombo:getWidth());
		self.haloCombo:setY(y);
		self.haloCombo:setVisible(true);
		y = y + sizes.button + pad;
		self.ticks:setX(pad);
		self.ticks:setY(y);
		self.ticks:setVisible(true);
		y = y + self.ticks:getHeight() + pad;
		lines(getText("IGUI_AutoPilot_P_MoreOptions"), Panel.colors.grey);
	else
		self.haloCombo:setVisible(false);
		self.ticks:setVisible(false);
	end

	-- with the quick options open the panel can be taller than the player's screen (a big font on a small screen: the
	-- last options were out of reach below the screen's edge): the job's details (done, phases, warnings, recorded
	-- lines) wait until the options close
	local height = y + pad / 2 + self:resizeWidgetHeight();

	if self.showOptions and not compact and height > getPlayerScreenTop(self.playerNum) + getPlayerScreenHeight(self.playerNum) - self:getY()
	then
		self.compactOptions = true;

		return self:relayout();
	end

	self.ops = ops;
	self:setWidth(width);
	self:setHeight(height);
	Panel:fitFrame(self);
	self:updateJoypadButtons();
	self:updateTitle();
end

-- the controller: Ferma for A while a job runs, B closes; with the options open the rows reach their controls. The
-- rows are made again only when they change (a job starts or ends, the options open or close, the controller's focus
-- comes or goes), so the focus stays where the player put it while the texts change. The A glyph only while the
-- panel has the controller's focus: on a button it hides the background and the colours (ISButton 42.22), and the
-- game's own panels set it only then.
function W:preferredJoypadFocus()
	if self.model and self.model.recording
	then
		return self.finishRecordButton;
	elseif self.model and self.model.running
	then
		return self.stopButton;
	end

	return self.optionsButton;
end

function W:updateJoypadButtons()
	local running = self.model ~= nil and self.model.running == true;
	local recording = self.model ~= nil and self.model.recording == true;
	local macro = self.model ~= nil and self.model.macroButton ~= nil;
	local joypad = self.joyfocus ~= nil;
	local shape = (running and "run" or (recording and "rec" or "idle")) .. (macro and "+macro" or "") .. (self.showOptions and "+options" or "") .. (joypad and "+pad" or "");

	if self.joypadShape == shape
	then
		return;
	end

	self.joypadShape = shape;

	-- the control with the focus now: clearJoypadButtonsList moves the index but not the focus mark
	local focused = nil;

	if joypad
	then
		for i, row in ipairs(self.joypadButtonsY or {})
		do
			for j, element in ipairs(row)
			do
				if element.joypadFocused
				then
					focused = element;
				end
			end
		end

		self:clearJoypadFocus(self.joyfocus);
	end

	self:clearJoypadButtonsList();
	local buttonA = nil;

	if recording
	then
		self:insertNewLineOfButtons(self.finishRecordButton, self.cancelRecordButton, self.optionsButton);
		buttonA = self.finishRecordButton;
	elseif running
	then
		if macro
		then
			self:insertNewLineOfButtons(self.stopButton, self.macroButton, self.optionsButton);
		else
			self:insertNewLineOfButtons(self.stopButton, self.optionsButton);
		end

		buttonA = self.stopButton;
	else
		if macro
		then
			self:insertNewLineOfButtons(self.macroButton, self.optionsButton);
		else
			self:insertNewLineOfButtons(self.optionsButton);
		end
	end

	self:clearISButtonA();

	if joypad and buttonA
	then
		self:setISButtonForA(buttonA);
	end

	if self.showOptions
	then
		self:insertNewLineOfButtons(self.haloCombo);
		self:insertNewLineOfButtons(self.ticks);
	end

	-- the focus where it was if that control is still there, else on the main button
	if joypad and not (focused and self:setJoypadFocus(focused, self.joyfocus))
	then
		self:setJoypadFocus(self:preferredJoypadFocus(), self.joyfocus);
	end
end

-- collapsed: the job and its progress (or the last summary) in the title, changed only when it changes
function W:updateTitle()
	local wanted = self.model and self.model.title or "";

	if self.isCollapsed and self.model
	then
		wanted = self.model.collapsedTitle;
	end

	if self.title ~= wanted
	then
		self:setTitle(wanted);
	end
end

-- every frame while visible (a hidden window is never updated): the texts only when the state changed, the clock
-- when its second changed, the collapse after the end
function W:update()
	ISCollapsableWindowJoypad.update(self);

	-- the game calls update on every element of its UI list at every frame, a hidden one too
	-- (UIManager.updateUIElements): a closed panel does nothing (spec 7.3, rule 2); opening it rebuilds the texts
	if not self:getIsVisible()
	then
		return;
	end

	local now = getTimestampMs();
	local state = AutoPilotMoon.Progress.state;
	local model = self.model;

	local Rec = AutoPilotMoon.Macro and AutoPilotMoon.Macro.Recorder;
	local recRevision = Rec and Rec.session and Rec.revision or nil;
	local macroButton = model and Panel:macroButtonText(state.running and Panel:getRunningOwnerNum() == self.playerNum) or nil;

	if model == nil or ((state.revision ~= model.revision or self.dirty or recRevision ~= model.recRevision or macroButton ~= model.macroButton)
		and now - model.builtAt >= Panel.minRebuildMs)
	then
		self:rebuild(now);
	elseif model.recording and model.recordStartedAt
	then
		local second = math.floor((now - model.recordStartedAt) / 1000);

		if second ~= model.second and self.clockOp
		then
			model.second = second;
			self.clockOp.text = formatClock(now - model.recordStartedAt);
		end
	elseif model.running and state.running
	then
		local second = math.floor((now - state.startedAt) / 1000);

		if second ~= model.second and self.clockOp
		then
			model.second = second;
			self.clockOp.text = formatClock(now - state.startedAt);
		end
	end

	if self.autoOpened and self.endedAt and not state.running and not self.isCollapsed
	then
		if self:isMouseOver()
		then
			self.endedAt = now;
		elseif now - self.endedAt >= Panel.autoCollapseMs
		then
			self.isCollapsed = true;
			self:setMaxDrawHeight(self:titleBarHeight());
			self.autoOpened = false;
		end
	end

	self:updateTitle();
end

function W:prerender()
	ISCollapsableWindowJoypad.prerender(self);

	-- collapsed, the title says the job and its progress (spec 2.3); the game draws no title on a collapsed window
	-- (ISUIElement:drawText / drawTextCentre return when isCollapsed), so it is drawn here as ISCollapsableWindow does
	if self.isCollapsed and self.title and self.javaObject
	then
		self.javaObject:DrawTextCentre(self.titleBarFont or UIFont.Small, self.title, self:getWidth() / 2, 1, 1, 1, 1, 1);
	end

	if self.isCollapsed or self.ops == nil
	then
		return;
	end

	-- the recording's dot: the bad colour, on one second and off the next, always beside its words
	if self.dotY and self.recordDot and math.floor(getTimestampMs() / 1000) % 2 == 0
	then
		local r, g, b = UI:badColor();

		self:drawTextureScaled(self.recordDot, self.sizes.pad, self.dotY, self.sizes.small, self.sizes.small, 1, r, g, b);
	end

	if self.iconY and self.model and self.model.icon
	then
		self:drawTextureScaledAspect(self.model.icon, self.sizes.pad, self.iconY, self.sizes.medium, self.sizes.medium, 1, 1, 1, 1);
	end

	for i, entry in ipairs(self.ops)
	do
		if entry.right
		then
			self:drawTextRight(entry.text, entry.x, entry.y, entry.r, entry.g, entry.b, 1, entry.font);
		else
			self:drawText(entry.text, entry.x, entry.y, entry.r, entry.g, entry.b, 1, entry.font);
		end
	end

	if self.separatorY
	then
		self:drawRect(self.sizes.pad, self.separatorY, self.width - 2 * self.sizes.pad, 1, 1, 0.4, 0.4, 0.4);
	end
end

function W:close()
	ISCollapsableWindowJoypad.close(self);
	self.autoOpened = false;

	-- the controller's focus back to the game (JoyPadSetup.lua: joypadData.focus is the element with the focus)
	local joypadData = JoypadState.players[self.playerNum + 1];

	if joypadData and joypadData.focus == self
	then
		setJoypadFocus(self.playerNum, nil);
	end
end

-- B closes (the title bar's close button is an image: no B glyph drawn over it), the rest as the game's panels; with
-- the halo list open B closes the list first (ISPanelJoypad:onJoypadDown 42.22)
function W:onJoypadDown(button, joypadData)
	if button == Joypad.BButton and self.haloCombo and self.haloCombo.expanded
	then
		self.haloCombo.expanded = false;
		self.haloCombo:hidePopup();

		return;
	end

	if button == Joypad.BButton
	then
		self:close();

		return;
	end

	ISCollapsableWindowJoypad.onJoypadDown(self, button, joypadData);
end

-- the rows, the A glyph and the button widths follow the focus (relayout ends with updateJoypadButtons)
function W:onGainJoypadFocus(joypadData)
	ISCollapsableWindowJoypad.onGainJoypadFocus(self, joypadData);
	self.drawJoypadFocus = true;
	self:relayout();
	self:updateJoypadButtons();
end

function W:onLoseJoypadFocus(joypadData)
	self:clearJoypadFocus(joypadData);
	ISCollapsableWindowJoypad.onLoseJoypadFocus(self, joypadData);
	self.drawJoypadFocus = false;
	self:relayout();
	self:updateJoypadButtons();
end

-- remembered by the game's layout file: position, width and pin; the height is the content's, the visibility ours
function W:RestoreLayout(name, layout)
	local x = tonumber(layout.x);
	local y = tonumber(layout.y);
	local width = tonumber(layout.width);

	if x and y
	then
		self:setX(x);
		self:setY(y);
	end

	if width
	then
		self.userWidth = width;
	end

	if layout.pin == "false"
	then
		self:collapse();
	end

	self:relayout();
	Panel:keepOnScreen(self);
end

function W:SaveLayout(name, layout)
	layout.x = self:getX();
	layout.y = self:getY();
	-- only the width the player chose with the corner: the drawn one grows with the longest line, saved it would
	-- never let the panel be narrower again after a restart
	layout.width = self.userWidth;
	layout.height = self:getHeight();

	if self.pin
	then
		layout.pin = "true";
	else
		layout.pin = "false";
	end
end

-- ============================================================================================================
-- Opening, closing, the observer
-- ============================================================================================================

function AutoPilotMoon.Panel:getLayoutName(playerNum)
	if playerNum == 0
	then
		return Panel.layoutName;
	end

	return Panel.layoutName .. playerNum;
end

-- inside the player's screen (first opening, resolution change, a remembered position from another resolution)
function AutoPilotMoon.Panel:keepOnScreen(window)
	local left = getPlayerScreenLeft(window.playerNum);
	local top = getPlayerScreenTop(window.playerNum);
	local right = left + getPlayerScreenWidth(window.playerNum);
	local bottom = top + getPlayerScreenHeight(window.playerNum);
	local x = math.max(left, math.min(window:getX(), right - window:getWidth()));
	local y = math.max(top, math.min(window:getY(), bottom - window:titleBarHeight()));

	window:setX(x);
	window:setY(y);
end

-- the window of a player, created the first time: at the top, a third of the player's screen from its left (away from
-- the inventory on the left, the moodles on the right and the chat at the bottom)
function AutoPilotMoon.Panel:getWindow(playerNum)
	local window = Panel.windows[playerNum];

	if window or not Panel:createClasses()
	then
		return window;
	end

	local sizes = Panel:getSizes();
	local x = getPlayerScreenLeft(playerNum) + math.floor(getPlayerScreenWidth(playerNum) / 3);
	local y = getPlayerScreenTop(playerNum) + 4 * sizes.pad;

	window = Panel.Window:new(x, y, sizes.minWidth, 10 * sizes.row);
	window.playerNum = playerNum;
	window.sizes = sizes;
	window.titleBarFont = UIFont.Small;
	window.showOptions = false;
	window:setTitle(getText("IGUI_AutoPilot_P_Title"));
	window:initialise();
	window:instantiate();
	window:setVisible(false);
	window:addToUIManager();
	Panel.windows[playerNum] = window;

	ISLayoutManager.RegisterWindow(Panel:getLayoutName(playerNum), Panel.Window, window);

	if not Panel.resolutionHandler
	then
		Panel.resolutionHandler = true;
		Events.OnResolutionChange.Add(Panel.onResolutionChange);
	end

	return window;
end

function AutoPilotMoon.Panel:isOpen(playerNum)
	local window = Panel.windows[playerNum];

	return window ~= nil and window:getIsVisible();
end

-- the panel is on screen and not collapsed for this character (the messages' rule, spec 4.1)
function AutoPilotMoon.Panel:isOpenFor(player)
	local window = player and Panel.windows[player:getPlayerNum()];

	return window ~= nil and window:getIsVisible() and not window.isCollapsed;
end

-- opens (and uncollapses) the panel; fromMenu: with a controller it takes the focus; auto: it opened by itself
function AutoPilotMoon.Panel:open(playerNum, fromMenu, auto)
	local window = Panel:getWindow(playerNum);

	if window == nil
	then
		return nil;
	end

	if window.isCollapsed
	then
		window.isCollapsed = false;
		window:clearMaxDrawHeight();
	end

	if not window:getIsVisible()
	then
		window.autoOpened = auto == true;
	end

	window.endedAt = nil;
	window:rebuild(getTimestampMs());
	window:setVisible(true);
	window:bringToTop();

	if fromMenu and UI:isJoypad(playerNum)
	then
		setJoypadFocus(playerNum, window);
	end

	return window;
end

function AutoPilotMoon.Panel:close(playerNum)
	local window = Panel.windows[playerNum];

	if window and window:getIsVisible()
	then
		window:close();
	end
end

function AutoPilotMoon.Panel:toggle(playerNum, fromMenu)
	if Panel:isOpen(playerNum) and not Panel.windows[playerNum].isCollapsed
	then
		Panel:close(playerNum);
	else
		Panel:open(playerNum, fromMenu, false);
	end
end

-- the Progress observer: notes only (the texts are made by the visible window's update); a job's start opens its
-- player's panel when the player wants it, its end starts the countdown of the collapse
function AutoPilotMoon.Panel.onProgress(event, state)
	if event == "start"
	then
		Panel.ownerNum = Panel:getRunningOwnerNum();

		if Panel.ownerNum ~= nil and AutoPilotMoon.Options:get("openPanelOnStart")
		then
			local window = Panel.windows[Panel.ownerNum];

			Panel:open(Panel.ownerNum, false, window == nil or not window:getIsVisible() or (window.autoOpened == true));
		end
	elseif event == "stop"
	then
		Panel.lastOwnerNum = Panel.ownerNum;

		local window = Panel.ownerNum and Panel.windows[Panel.ownerNum];

		if window
		then
			window.endedAt = getTimestampMs();
			window.dirty = true;
		end
	end
end

-- the player's key (option panelKey; none by default, decision D2), never while typing in the chat
function AutoPilotMoon.Panel.onKeyPressed(key)
	local wanted = AutoPilotMoon.Options:get("panelKey");

	if wanted == nil or wanted == 0 or key ~= wanted
	then
		return;
	end

	local chat = rawget(_G, "ISChat");

	if chat and chat.focused
	then
		return;
	end

	local player = getSpecificPlayer(0);

	if player and not player:isDead()
	then
		Panel:toggle(0, false);
	end
end

-- a dead character's panel closes (called by the mod's death handler, client/99_AP_Event.lua)
function AutoPilotMoon.Panel:onPlayerDeath(player)
	if player
	then
		Panel:close(player:getPlayerNum());
	end
end

function AutoPilotMoon.Panel.onResolutionChange()
	for playerNum, window in pairs(Panel.windows)
	do
		window:relayout();
		Panel:keepOnScreen(window);
	end
end

-- the player's master switch turned off (client/06_AP_Switch.lua): every panel closes and leaves the game's UI list
-- (the game updates even hidden elements at every frame); the next open makes a new one at the remembered place
function AutoPilotMoon.Panel:shutdown()
	local numbers = {};

	for playerNum, window in pairs(Panel.windows)
	do
		table.insert(numbers, playerNum);
	end

	for i, playerNum in ipairs(numbers)
	do
		local window = Panel.windows[playerNum];

		Panel.windows[playerNum] = nil;

		if window:getIsVisible()
		then
			window:close();
		end

		window:removeFromUIManager();
	end

	if Panel.resolutionHandler
	then
		Panel.resolutionHandler = false;
		Events.OnResolutionChange.Remove(Panel.onResolutionChange);
	end
end

-- the classes are derived at the game's start (client/99_AP_Event.lua) and again before the first use
AutoPilotMoon.Progress:subscribe(Panel.onProgress);

-- the panel's key: only while the master switch is on
AutoPilotMoon.Switch:bind("OnKeyPressed", Panel.onKeyPressed);
