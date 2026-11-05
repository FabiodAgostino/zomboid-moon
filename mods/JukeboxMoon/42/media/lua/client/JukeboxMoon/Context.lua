-- JukeboxMoon: "Jukebox" in the right click on a jukebox (FR-01). Too far, the player first walks next to it (the
-- game's own walk), then the jukebox opens: the server converts the game's tile into a jukebox with a container the
-- first time, and answers "opened". No timed action of ours: in multiplayer the server would not know it.

require "JukeboxMoon/Core"
require "JukeboxMoon/Box"
require "JukeboxMoon/Player"
require "JukeboxMoon/Window"

if JukeboxMoon.Context then return JukeboxMoon.Context end

local Core = JukeboxMoon.Core
local Box = JukeboxMoon.Box
local Player = JukeboxMoon.Player
local Window = JukeboxMoon.Window

local Context = {}
JukeboxMoon.Context = Context

Context.pending = nil      -- { x, y, z, untilMs }: a jukebox the player is walking to
Context.WALK_MS = 15000

local function near(player, x, y, z)
	if math.floor(player:getZ()) ~= z then return false end
	local dx, dy = player:getX() - (x + 0.5), player:getY() - (y + 0.5)
	return dx * dx + dy * dy <= Core.USE_TILES * Core.USE_TILES
end

function Context.open(x, y, z)
	Context.pending = nil
	Player.send("open", { x = x, y = y, z = z })
end

function Context.onChoose(worldobjects, object, playerNum)
	local player = getSpecificPlayer(playerNum)
	if not player or not object then return end
	local x, y, z = math.floor(object:getX()), math.floor(object:getY()), math.floor(object:getZ())
	if near(player, x, y, z) then
		Context.open(x, y, z)
		return
	end
	local square = object:getSquare()
	if square and luautils.walkAdj(player, square, true) then
		Context.pending = { x = x, y = y, z = z, untilMs = getTimestampMs() + Context.WALK_MS }
	end
end

function Context.onFill(playerNum, context, worldobjects, test)
	if test then return true end
	local found = nil
	for _, object in ipairs(worldobjects or {}) do
		if Box.isJukebox(object) then found = object end
		if not found then
			local square = object and object.getSquare and object:getSquare()
			local onSquare = square and Box.onSquare(square)
			if onSquare then found = onSquare end
		end
		if found then break end
	end
	if not found then return end
	context:addOption(getText("ContextMenu_JukeboxMoon_Open"), worldobjects, Context.onChoose, found, playerNum)
end

function Context.onTick()
	local pending = Context.pending
	if not pending then return end
	local player = getPlayer()
	if not player or getTimestampMs() > pending.untilMs then
		Context.pending = nil
		return
	end
	if near(player, pending.x, pending.y, pending.z) then Context.open(pending.x, pending.y, pending.z) end
end

table.insert(Player.listeners, function(kind, data)
	if kind == "opened" then Window.open(math.floor(data.x), math.floor(data.y), math.floor(data.z)) end
end)

Events.OnFillWorldObjectContextMenu.Add(Context.onFill)
Events.OnTick.Add(Context.onTick)

return Context
