-- SilencerMoon: the admin's switch for the restore (shared/SilencerMoon/Restore.lua) in the right-click menu, one line
-- shown only to admins (in single player, to you). The server decides and checks the role again; the answer shows
-- above the admin's head. Clients keep a copy of the switch (the world's mod data the server transmits), so the
-- game's "Add weapon upgrade" menu stops offering SilencerMoon suppressors while the restore is on.

require "SilencerMoon/Restore"
require "SilencerMoon/Shot"

local Restore = SilencerMoon.Restore
local MODULE = SilencerMoon.Shot.COMMAND_MODULE

local function notify(text, bad)
	local player = getPlayer()
	if not player or not text then return end
	pcall(function()
		if bad then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addGoodText(player, text) end
	end)
end

function SilencerMoon.onRestoreReply(args)
	if args.refused then
		notify(getText("IGUI_SilencerMoon_RestoreRefused"), true)
	elseif args.active then
		notify(getText("IGUI_SilencerMoon_RestoreStarted", tostring(args.fixedNow or 0), tostring(args.fixed or 0)))
	else
		notify(getText("IGUI_SilencerMoon_RestoreStopped"))
	end
end

local function send(player, command)
	if isClient() then
		sendClientCommand(player, MODULE, command, {})
	elseif SilencerMoon.onRestoreCommand then
		SilencerMoon.onRestoreCommand(player, command)
	end
end

local function addOption(context, player, labelKey, tooltipKey, command, fixed)
	local option = context:addOption(getText(labelKey), player, send, command)
	local tooltip = ISWorldObjectContextMenu.addToolTip()
	tooltip.description = getText(tooltipKey, tostring(fixed))
	option.toolTip = tooltip
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
	local player = getSpecificPlayer(playerNum)
	if not player or not Restore.isAdmin(player) then return end
	if test then return true end
	local data = Restore.data() or {}
	local fixed = tonumber(data.fixed) or 0
	if Restore.active() then
		addOption(context, player, "ContextMenu_SilencerMoon_RestoreStop", "Tooltip_SilencerMoon_RestoreStop",
			Restore.COMMAND_STOP, fixed)
	else
		addOption(context, player, "ContextMenu_SilencerMoon_RestoreStart", "Tooltip_SilencerMoon_RestoreStart",
			Restore.COMMAND_START, fixed)
	end
end

local function onServerCommand(module, command, args)
	if module == MODULE and command == Restore.REPLY then SilencerMoon.onRestoreReply(args or {}) end
end

local function onReceiveGlobalModData(key, data)
	if key == Restore.DATA and type(data) == "table" then
		ModData.add(key, data)
		Restore.cache = nil
	end
end

local function onGameStart()
	if isClient() then ModData.request(Restore.DATA) end
end

if not SilencerMoon.restoreMenuAdded then
	SilencerMoon.restoreMenuAdded = true
	local guarded = SilencerMoon.Shot.guarded
	Events.OnFillWorldObjectContextMenu.Add(guarded("RestoreMenu", onFillWorldObjectContextMenu))
	Events.OnServerCommand.Add(guarded("Restore.OnServerCommand", onServerCommand))
	Events.OnReceiveGlobalModData.Add(guarded("Restore.OnReceiveGlobalModData", onReceiveGlobalModData))
	Events.OnGameStart.Add(guarded("Restore.OnGameStart", onGameStart))
end
