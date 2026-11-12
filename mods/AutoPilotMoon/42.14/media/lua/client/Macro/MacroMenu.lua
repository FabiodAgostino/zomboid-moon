-- AutoPilot (Moon): automations for the Moon server.

-- The macros in the right click's menu (spec MACRO-AUTOPILOT.md 5.6, 3.1), built by JobMenu:fill:
--
--   Sperimentale                              (header, at the end of the list, before the panel's entry)
--     Macro >
--       Apri l'editor delle macro...
--       Registra una macro
--       Le tue macro                          (header, when there is one)
--       Avvia: Manutenzione - martelli        (the last 8 used; grey with the reason when it has problems)
--
-- The macros' submenu is not an area (the exception to "every job's submenu is its area": a macro works on no area).
-- Each "Avvia" has the macro's first 4 lines, the job and the server's limit as its tooltip. While recording, the first
-- entries of AutoPilot are "Fine registrazione (passi 2)" and "Annulla registrazione", every other entry is grey with
-- "Stai registrando una macro". Off on the server, or hidden by the player ("Lavori nel menu"): nothing at all.

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Menu = AutoPilotMoon.Macro.Menu or {};

local Menu = AutoPilotMoon.Macro.Menu;
local A = AutoPilotMoon.Automation;

Menu.maxRecent = 8;
Menu.tooltipLines = 4;

-- the section is offered: on the server and shown by the player
function AutoPilotMoon.Macro.Menu:isOffered()
	return A:isEnabled("macro");
end

local function tooltip(option, text)
	option.toolTip = ISWorldObjectContextMenu.addToolTip();
	option.toolTip.description = text;
end

function AutoPilotMoon.Macro.Menu.onEditor(player)
	AutoPilotMoon.Macro.Editor:open(player:getPlayerNum(), nil, true);
end

function AutoPilotMoon.Macro.Menu.onRecord(player)
	AutoPilotMoon.Macro.Recorder:start(player);
end

function AutoPilotMoon.Macro.Menu.onRun(player, name)
	local macro = AutoPilotMoon.Macro.Store:get(name);

	if macro
	then
		AutoPilotMoon.Macro.Run:start(player, macro);
	end
end

function AutoPilotMoon.Macro.Menu.onFinishRecording()
	AutoPilotMoon.Macro.Recorder:finish();
end

function AutoPilotMoon.Macro.Menu.onCancelRecording()
	AutoPilotMoon.Macro.Recorder:askCancel();
end

-- While recording (3.1): the two entries of the recording first; returns true when the player is recording
function AutoPilotMoon.Macro.Menu:addRecording(menu, player)
	local Rec = AutoPilotMoon.Macro.Recorder;

	if not Rec:isRecordingFor(player)
	then
		return false;
	end

	AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_MacroRecordEnd", Rec:countSteps()), Menu.onFinishRecording);
	AutoPilotMoon:addContextMenuItem(menu, getText("IGUI_AutoPilot_M_MacroRecordCancel"), Menu.onCancelRecording);

	return true;
end

-- every entry from index first on grey with "Stai registrando una macro" (headers and the panel's entry excepted)
function AutoPilotMoon.Macro.Menu:greyFrom(menu, first, keep)
	local last = menu.numOptions and (menu.numOptions - 1) or #menu.options;
	local reason = "<BHC> " .. getText("IGUI_AutoPilot_M_MacroRecording");

	for i = first, last
	do
		local option = menu.options[i];

		if option and not option.isDisabled and option ~= keep
		then
			option.notAvailable = true;
			option.onSelect = nil;
			option.subOption = nil;
			option.subMenu = nil;
			tooltip(option, reason);
		end
	end
end

-- the first lines of a macro, for its tooltip ("<" written so the rich text keeps it)
local function firstLines(text)
	local lines = {};

	for i, line in ipairs(AutoPilotMoon.Macro.EditorModel.lines(text))
	do
		if #lines >= Menu.tooltipLines
		then
			table.insert(lines, "...");

			break;
		end

		if AutoPilotMoon.Macro.Lang.trim(line) ~= ""
		then
			table.insert(lines, (string.gsub(line, "<", "&lt;")));
		end
	end

	return lines;
end

-- the errors of a macro (its last check, or a check now when the names are indexed), nil when unknown
local function errorsOf(player, macro)
	if macro.checkedText ~= macro.text and AutoPilotMoon.Macro.Names:isReady()
	then
		local result = AutoPilotMoon.Macro.Run:check(player, macro.text);

		macro.checkedText = macro.text;
		macro.errors = result.errors;
	end

	if macro.checkedText == macro.text
	then
		return macro.errors;
	end

	return nil;
end

-- "Sperimentale > Macro >" (5.6)
function AutoPilotMoon.Macro.Menu:addSection(menu, player)
	if not Menu:isOffered()
	then
		return;
	end

	AutoPilotMoon:addContextMenuHeader(menu, getText("IGUI_AutoPilot_M_HeaderExperimental"));

	local submenu, entry = AutoPilotMoon:addContextMenuSubMenu(menu, getText("IGUI_AutoPilot_M_Macro"));

	tooltip(entry, getText("IGUI_AutoPilot_T_Desc_Macro"));

	AutoPilotMoon:addContextMenuItem(submenu, getText("IGUI_AutoPilot_M_MacroEditor"), Menu.onEditor, { player });

	local record = AutoPilotMoon:addContextMenuItem(submenu, getText("IGUI_AutoPilot_M_MacroRecord"), Menu.onRecord, { player });
	local refusal = AutoPilotMoon.Macro.Recorder:getStartRefusal(player);

	if refusal
	then
		record.notAvailable = true;
		tooltip(record, "<BHC> " .. refusal);
	end

	local macros = AutoPilotMoon.Macro.Store:list();

	if #macros == 0
	then
		return;
	end

	AutoPilotMoon:addContextMenuHeader(submenu, getText("IGUI_AutoPilot_E_Yours"));

	local maxActions = AutoPilotMoon.Sandbox:getInteger("MacroActionsPerRun");
	local limitLine = getText("IGUI_AutoPilot_T_JobLimit", getText("IGUI_AutoPilot_O_Context_Macro"), getText("IGUI_AutoPilot_T_Limit_Actions", maxActions));

	for i = 1, math.min(Menu.maxRecent, #macros)
	do
		local macro = macros[i];
		local option = AutoPilotMoon:addContextMenuItem(submenu, getText("IGUI_AutoPilot_M_MacroRun", macro.name), Menu.onRun, { player, macro.name });
		local lines = {};
		local errors = errorsOf(player, macro);

		if errors and errors > 0
		then
			option.notAvailable = true;
			table.insert(lines, "<BHC> " .. getText("IGUI_AutoPilot_E_RunFixFirst", errors));
		end

		for j, line in ipairs(firstLines(macro.text))
		do
			table.insert(lines, "<RGB:0.9,0.9,0.9> " .. line);
		end

		table.insert(lines, "<RGB:1,1,1> " .. limitLine);
		tooltip(option, table.concat(lines, " <LINE> "));
	end
end
