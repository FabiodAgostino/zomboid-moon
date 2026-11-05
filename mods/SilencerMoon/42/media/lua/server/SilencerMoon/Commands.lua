-- SilencerMoon on the server: each round the shooter's game reports (shared/SilencerMoon/Shot.lua) is rolled here,
-- then the weapon goes back to its owner. The report is checked: the weapon in hand, a working SilencerMoon
-- suppressor, and no more rounds than a firearm can fire (a burst of at most 20 in any second). When the suppressor
-- wears out, every game is told (Shot.COMMAND_WORN), so the others stop hiding that weapon's flash. While the restore
-- is on (shared/SilencerMoon/Restore.lua), a reported round fixes the weapon at once instead of wearing it.
--
-- A multiplayer client loads media/lua/server too (GameLoadingState.enter, with no condition): this file is for the
-- server and single player only.
if isClient() then return end

require "SilencerMoon/Core"
require "SilencerMoon/Stats"
require "SilencerMoon/Shot"
require "SilencerMoon/Restore"

local Core = SilencerMoon.Core
local Shot = SilencerMoon.Shot
local Restore = SilencerMoon.Restore

local WINDOW_MS = 1000
local MAX_PER_WINDOW = 20
local windows = {} -- by username: { start = ms, count = n }

local function allowed(player)
	local key = tostring(player:getUsername())
	local now = getTimestampMs()
	local window = windows[key]
	if not window or now - window.start >= WINDOW_MS then
		windows[key] = { start = now, count = 1 }
		return true
	end
	window.count = window.count + 1
	return window.count <= MAX_PER_WINDOW
end

local function onClientCommand(module, command, player, args)
	if module ~= Shot.COMMAND_MODULE or command ~= Shot.COMMAND_SHOT then return end
	if not player or type(args) ~= "table" then return end
	local weapon = player:getPrimaryHandItem()
	if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return end
	if args.id ~= weapon:getID() then return end
	if not Core.activeTier(weapon) then return end
	if not allowed(player) then return end
	if Restore.active() then
		if Restore.weapon(weapon, player) then
			Restore.count(1)
			syncHandWeaponFields(player, weapon)
		end
		return
	end
	if Shot.wear(weapon) then
		syncHandWeaponFields(player, weapon)
		if not Core.activeTier(weapon) then
			sendServerCommand(Shot.COMMAND_MODULE, Shot.COMMAND_WORN, { player = player:getOnlineID(), id = weapon:getID() })
		end
	end
end

SilencerMoon.onClientCommand = onClientCommand

if not SilencerMoon.commandsAdded then
	SilencerMoon.commandsAdded = true
	Events.OnClientCommand.Add(Shot.guarded("OnClientCommand", onClientCommand))
end
