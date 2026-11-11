-- JukeboxMoon: tells the server when this player moves a unique CD (server/JukeboxMoon/Unique.lua). Taking an item
-- is a client action in 42.21: in multiplayer the server moves it in Java and fires no Lua event, then the client's
-- action runs perform() (media/lua/client/TimedActions/ISInventoryTransferAction.lua: createItemTransaction, the
-- ItemTransactionPacket, perform; ISGrabItemAction for the floor). Around those two perform() this file looks at the
-- items of the batch and, for a unique CD, sends "taken" once: the server checks it and decides. Nothing else runs.

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Player"
require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"

if JukeboxMoon.Finder then return JukeboxMoon.Finder end

local Catalog = JukeboxMoon.Catalog
local Player = JukeboxMoon.Player

local Finder = {}
JukeboxMoon.Finder = Finder

Finder.AGAIN_MS = 5000      -- the same CD is told again only after this (a move the server refused, then a new one)
Finder.GOLD = { 255, 215, 0 }               -- "Noti qualcosa di interessante", over the head
Finder.SOUND = "JukeboxMoon_Interesting"    -- media/scripts/JukeboxMoon_ui.txt: a chime made for the mod
Finder.told = {}            -- item id -> when it was told

-- The unique album of an item, or nil.
function Finder.albumOf(item)
	local ok, fullType = pcall(function() return item:getFullType() end)
	if not ok or not fullType then return nil end
	for _, album in ipairs(Catalog.uniqueAlbums()) do
		if album.item == fullType then return album end
	end
	return nil
end

function Finder.saw(item)
	local album = item and Finder.albumOf(item)
	if not album then return end
	local ok, id = pcall(function() return item:getID() end)
	id = ok and id or 0
	local t = getTimestampMs()
	if Finder.told[id] and t - Finder.told[id] < Finder.AGAIN_MS then return end
	Finder.told[id] = t
	Player.send("taken", { album = album.key, item = id })
end

-- The items of the batch perform() is about to move (it takes queueList[1]); for the floor, the world objects' items.
local function batch(action, floor)
	local out = {}
	local queued = action.queueList and action.queueList[1]
	if type(queued) ~= "table" or type(queued.items) ~= "table" then return out end
	for _, entry in ipairs(queued.items) do
		local item = entry
		if floor then
			local ok, inner = pcall(function() return entry:getItem() end)
			item = ok and inner or nil
		end
		if item then out[#out + 1] = item end
	end
	return out
end

local function wrap(class, floor)
	local perform = class.perform
	class.perform = function(self, ...)
		local items = batch(self, floor)
		local result = perform(self, ...)
		for _, item in ipairs(items) do pcall(Finder.saw, item) end
		return result
	end
end

wrap(ISInventoryTransferAction, false)
wrap(ISGrabItemAction, true)

-- A unique CD fell from the runner this player killed (Unique.drop, only to the killer): "Noti qualcosa di
-- interessante" over the head in gold, as the game's own notes (HaloTextHelper.addText with a colour, 42.21: it writes
-- [col=r,g,b] in front), and a chime only this player hears (playUISound: the UI emitter, never sent to the others).
function Finder.interesting()
	local player = getPlayer()
	if not player then return end
	local text = getText("IGUI_JukeboxMoon_Notice_interesting")
	local r, g, b = Finder.GOLD[1], Finder.GOLD[2], Finder.GOLD[3]
	local shown = HaloTextHelper and HaloTextHelper.addText
		and pcall(function() HaloTextHelper.addText(player, text, "[br/]", r, g, b) end)
	if not shown then pcall(function() player:setHaloNote(text, r, g, b, 300) end) end
	pcall(function() getSoundManager():playUISound(Finder.SOUND) end)
end

-- A copy of a unique CD already found, removed by the server (Unique.leftover): said over the player's head, as the
-- game's own notes are (setHaloNote).
table.insert(Player.listeners, function(kind, data)
	if kind ~= "notice" or type(data) ~= "table" then return end
	if data.what == "interesting" then return Finder.interesting() end
	if data.what ~= "leftover" then return end
	local player = getPlayer()
	if player then player:setHaloNote(getText("IGUI_JukeboxMoon_Notice_leftover")) end
end)

return Finder
