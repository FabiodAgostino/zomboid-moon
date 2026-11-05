-- SilencerMoon on the server: the admin's commands for the restore (shared/SilencerMoon/Restore.lua), and the rounds
-- that keep fixing weapons while it is on: every ten game minutes the players online and the loaded vehicles, and
-- each square as it loads. Nothing at all runs while it is off.

require "SilencerMoon/Restore"
require "SilencerMoon/Shot"

local Restore = SilencerMoon.Restore

local function reply(player, fixed)
	local data = Restore.data() or {}
	local args = { active = Restore.active(), fixedNow = fixed or 0, fixed = tonumber(data.fixed) or 0 }
	if isServer() then
		sendServerCommand(player, SilencerMoon.Shot.COMMAND_MODULE, Restore.REPLY, args)
	elseif SilencerMoon.onRestoreReply then
		SilencerMoon.onRestoreReply(args)
	end
end

-- The admin's command (in single player the client calls it directly).
function SilencerMoon.onRestoreCommand(player, command)
	if command ~= Restore.COMMAND_START and command ~= Restore.COMMAND_STOP then return end
	if not Restore.isAdmin(player) then
		if isServer() then sendServerCommand(player, SilencerMoon.Shot.COMMAND_MODULE, Restore.REPLY, { refused = true }) end
		return
	end
	local fixed = Restore.set(command == Restore.COMMAND_START)
	print("[SilencerMoon] restore " .. (Restore.active() and "on" or "off") .. " by "
		.. tostring(player and player:getUsername()) .. ", weapons fixed now: " .. tostring(fixed))
	reply(player, fixed)
end

local function onClientCommand(module, command, player, args)
	if module ~= SilencerMoon.Shot.COMMAND_MODULE then return end
	SilencerMoon.onRestoreCommand(player, command)
end

local function everyTenMinutes()
	Restore.cache = nil
	if not Restore.activeCached() then return end
	Restore.count(Restore.players() + Restore.vehicles())
end

local function fixSquare(square)
	if square then Restore.count(Restore.square(square)) end
end

if not SilencerMoon.restoreAdded then
	SilencerMoon.restoreAdded = true
	local guarded = SilencerMoon.Shot.guarded
	Events.OnClientCommand.Add(guarded("Restore.OnClientCommand", onClientCommand))
	Events.EveryTenMinutes.Add(guarded("Restore.EveryTenMinutes", everyTenMinutes))
	Events.OnInitGlobalModData.Add(function() Restore.cache = nil end)
	-- thousands of squares load at a time: while the restore is off this is one Lua comparison each
	local guardedSquare = guarded("Restore.LoadGridsquare", fixSquare)
	Events.LoadGridsquare.Add(function(square)
		if Restore.activeCached() then guardedSquare(square) end
	end)
end
