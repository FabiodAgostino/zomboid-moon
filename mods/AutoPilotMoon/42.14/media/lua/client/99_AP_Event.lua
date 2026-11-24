-- AutoPilot (Moon): automations for the Moon server.

-- Game events. Bound only while the player's master switch "Attiva AutoPilot" is on (client/06_AP_Switch.lua,
-- Switch:bind; off by default): turning it on or off in the Options needs no restart. While on and no job runs, a
-- player update only looks at the message queue. No key handler: a job stops when the player moves or cancels
-- (pressedMovement / pressedCancelAction, which follow the player's key bindings and the controller), see
-- Automation:update().
-- At game start (always bound, once): the player's options are read again (ModOptions.ini, the server's mods load
-- after the main menu in multiplayer), then the switch decides
-- (Switch:start; when on it derives the cursor and window classes, whose base classes are in the game's server/
-- folder, loaded after client/, and installs the hooks of the macros).
-- The notifications (20/11/2026, client/47_AP_Notify.lua): the Progress observer is added when the master switch turns
-- on (Notify:startup, 23/11/2026; before, here at load); while a run or the watch after a stop is open, Notify:beforeUpdate / afterUpdate go around the engine's part of the player
-- update, each in pcall (the engine not: its error stays in the log, and the mark left on finds it).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Event = AutoPilotMoon.Event or {};

function AutoPilotMoon.Event.initialize()
	AutoPilotMoon.Options:buildPage();
	AutoPilotMoon.Options:load();

	-- the player's master switch: off = nothing more (no event, no hook, no window)
	AutoPilotMoon.Switch:start();
end

-- the job or the chain of this player, one frame (the engine is not in pcall: an error of it stays in the log, and the
-- notifications' mark left on finds it, client/47_AP_Notify.lua)
local function runEngine(player)
	local job = AutoPilotMoon.Automation.job;

	if job == nil
	then
		if AutoPilotMoon.Chain.current
		then
			-- between two phases of a chain
			AutoPilotMoon.Chain:update(player);
		end

		return;
	end

	if job.player ~= player
	then
		return;
	end

	AutoPilotMoon.Automation:update(player);
end

-- the notifications (client/47_AP_Notify.lua), only while a run or the watch after a stop is open; never breaks a frame
local function notifyFrame(method, player)
	local notify = AutoPilotMoon.Notify;

	if notify and notify.live
	then
		local ok, err = pcall(notify[method], notify, player);

		if not ok
		then
			print("AutoPilot (Moon): notify: " .. tostring(err));
		end
	end
end

function AutoPilotMoon.Event.onPlayerUpdate(player)
	if #AutoPilotMoon.messageQueue > 0
	then
		AutoPilotMoon:showNextMessage();
	end

	-- a macro being recorded (MACRO-AUTOPILOT.md 3): only while recording, only for its player
	local recorder = AutoPilotMoon.Macro and AutoPilotMoon.Macro.Recorder;

	if recorder and recorder.session and recorder.session.player == player
	then
		recorder:update(player);
	end

	notifyFrame("beforeUpdate", player);
	runEngine(player);
	notifyFrame("afterUpdate", player);
end

-- a local player died: whatever it was doing stops, its messages are dropped
function AutoPilotMoon.Event.onPlayerDeath(player)
	local job = AutoPilotMoon.Automation.job;
	local chainRun = AutoPilotMoon.Chain.current;

	if (job and job.player == player) or (job == nil and chainRun and chainRun.player == player)
	then
		AutoPilotMoon.Automation:stopAll("dead");
	end

	-- the notifications' watch after a stop: "dead" (client/47_AP_Notify.lua)
	local ok, err = pcall(AutoPilotMoon.Notify.onPlayerDeath, AutoPilotMoon.Notify, player);

	if not ok
	then
		print("AutoPilot (Moon): notify: " .. tostring(err));
	end

	if AutoPilotMoon.Event.currentPlayer == player
	then
		AutoPilotMoon.Event.currentPlayer = nil;
	end

	AutoPilotMoon:clearMessages(player);

	if AutoPilotMoon.Panel
	then
		AutoPilotMoon.Panel:onPlayerDeath(player);
	end

	if AutoPilotMoon.IdPicker
	then
		AutoPilotMoon.IdPicker:onPlayerDeath(player);
	end

	-- a recording is thrown away without questions, the editor closes (MACRO-AUTOPILOT.md 3.1, 4.2)
	if AutoPilotMoon.Macro and AutoPilotMoon.Macro.Recorder
	then
		AutoPilotMoon.Macro.Recorder:onPlayerDeath(player);
		AutoPilotMoon.Macro.Editor:onPlayerDeath(player);
	end
end

-- a character is created in a local slot (game start, respawn, split screen): a job of the previous character of that
-- slot, or of a dead one, never carries over
function AutoPilotMoon.Event.onCreatePlayer(playerNum, player)
	local job = AutoPilotMoon.Automation.job;
	local chainRun = AutoPilotMoon.Chain.current;
	local owner = (job and job.player) or (chainRun and chainRun.player);

	if (job or chainRun) and (owner == nil or owner:isDead() or owner:getPlayerNum() == playerNum)
	then
		AutoPilotMoon.Automation:stopAll("dead");
	end

	AutoPilotMoon.Event.currentPlayer = nil;
end

-- AutoPilot has something to offer this player: a running job or chain to stop, or a job the server allows (out of a
-- vehicle). The menu itself always has the panel's entry.
function AutoPilotMoon.Event.hasSomethingToOffer(player)
	if AutoPilotMoon.Automation:isBusy() or (AutoPilotMoon.Macro and AutoPilotMoon.Macro.Recorder:isRecordingFor(player))
	then
		return true;
	end

	return player:getVehicle() == nil
		and (AutoPilotMoon.JobMenu:isAnyAllowedByServer() or AutoPilotMoon.Automation:isAllowedByServer("macro"));
end

-- The right click on the world, for the player whose menu it is: the submenu "AutoPilot" at the end of the game's menu
-- (spec 2.2: nothing of the game's menu is touched). In the controller's test pass (test == true) nothing is built:
-- the game only asks whether there is something to show, and without ISWorldObjectContextMenu.setTest() it would not
-- open the menu where AutoPilot is the only thing to offer (a meadow).
function AutoPilotMoon.Event.onCreateContextMenu(playerNum, contextMenu, worldobjects, test)
	local player = getSpecificPlayer(playerNum);

	if player == nil or player:isDead()
	then
		return;
	end

	if test
	then
		if AutoPilotMoon.Event.hasSomethingToOffer(player)
		then
			return ISWorldObjectContextMenu.setTest();
		end

		return;
	end

	AutoPilotMoon.Event.currentPlayer = player;

	local menu = AutoPilotMoon:addContextMenuSubMenu(contextMenu, getText("IGUI_AutoPilot_M_Root"));

	AutoPilotMoon.JobMenu:fill(menu, player, worldobjects);
end

Events.OnGameStart.Add(AutoPilotMoon.Event.initialize);

-- the notifications follow every start and end of a job, chain or macro: their observer of Progress is added by
-- Notify:startup when the master switch turns on and taken away by Notify:shutdown (client/47_AP_Notify.lua)

-- only while the master switch is on
AutoPilotMoon.Switch:bind("OnPlayerUpdate", AutoPilotMoon.Event.onPlayerUpdate);
AutoPilotMoon.Switch:bind("OnPlayerDeath", AutoPilotMoon.Event.onPlayerDeath);
AutoPilotMoon.Switch:bind("OnCreatePlayer", AutoPilotMoon.Event.onCreatePlayer);
AutoPilotMoon.Switch:bind("OnFillWorldObjectContextMenu", AutoPilotMoon.Event.onCreateContextMenu);
