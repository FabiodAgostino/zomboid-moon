-- JukeboxMoon: the catalogue of CDs, read from JukeboxMoonCatalog. That table is defined by CatalogData.lua, which
-- tools/jukebox generates and the launcher installs with the music: it is not in the repository. Without it there is
-- no music at all (fail closed): the window says so and the server plays nothing.
--
--   JukeboxMoonCatalog = { version = "...", segmentMs = 10000, overlapMs = 250, albums = {
--     { key = 1, id = "estate-1993", item = "JukeboxMoon.CD_1", title = "...", artist = "...", year = 1993,
--       loot = 1.0, archived = false,
--       tracks = { { key = 1, id = "traccia-01", n = 1, title = "...", artist = "...", ms = 183450, segments = 19 } } } } }
--
-- An album with `media` instead of `item` is a CD of the game: the game's disc (Base.Disc_Retail) whose recording
-- (item:getMediaData():getId()) is that id plays it. No new item for it, and never in the loot: the game has it.

require "JukeboxMoon/Core"

if JukeboxMoon.Catalog then return JukeboxMoon.Catalog end

local Catalog = {}
JukeboxMoon.Catalog = Catalog

local indexed = nil   -- the table last indexed: a new JukeboxMoonCatalog (tests, a reload) is indexed again

local byItem, byMedia, byKey, byTrack, albums = {}, {}, {}, {}, {}

Catalog.GAME_CD = "Base.Disc_Retail"

local function index()
	local data = JukeboxMoonCatalog
	if data == indexed then return end
	indexed = data
	byItem, byMedia, byKey, byTrack, albums = {}, {}, {}, {}, {}
	if type(data) ~= "table" or type(data.albums) ~= "table" then return end
	for _, album in ipairs(data.albums) do
		local source = type(album) == "table" and (type(album.item) == "string" or type(album.media) == "string")
		if source and type(album.key) == "number" and type(album.tracks) == "table" then
			albums[#albums + 1] = album
			byKey[album.key] = album
			if album.item then byItem[album.item] = album end
			if album.media then byMedia[album.media] = album end
			for _, track in ipairs(album.tracks) do
				if type(track) == "table" and type(track.key) == "number" then
					track.album = album
					byTrack[track.key] = track
				end
			end
		end
	end
end

-- The catalogue's version, or nil when there is none.
function Catalog.version()
	index()
	return indexed and indexed.version or nil
end

function Catalog.available()
	index()
	return #albums > 0
end

function Catalog.segmentMs()
	index()
	return (indexed and tonumber(indexed.segmentMs)) or 10000
end

function Catalog.overlapMs()
	index()
	return (indexed and tonumber(indexed.overlapMs)) or 250
end

-- Every album, archived ones included (their CDs still play), in the catalogue's order.
function Catalog.albums()
	index()
	return albums
end

-- The albums an admin can make and the loot can hold.
function Catalog.activeAlbums()
	index()
	local out = {}
	for _, album in ipairs(albums) do
		if not album.archived then out[#out + 1] = album end
	end
	return out
end

function Catalog.album(fullType)
	index()
	return byItem[fullType]
end

function Catalog.albumByKey(key)
	index()
	return byKey[tonumber(key) or -1]
end

function Catalog.albumByMedia(id)
	index()
	return byMedia[id]
end

function Catalog.track(key)
	index()
	return byTrack[tonumber(key) or -1]
end

-- The album of a CD: one of ours by its type, one of the game's by its recording. nil for anything else, a game's
-- CD of a recording the catalogue does not have included.
function Catalog.albumOf(item)
	if not item then return nil end
	local ok, fullType = pcall(function() return item:getFullType() end)
	if not ok then return nil end
	if fullType == Catalog.GAME_CD then
		local found, id = pcall(function()
			local media = item:getMediaData()
			return media and media:getId() or nil
		end)
		return found and id and Catalog.albumByMedia(id) or nil
	end
	return Catalog.album(fullType)
end

function Catalog.isCD(item)
	return Catalog.albumOf(item) ~= nil
end

-- The name of the sound of piece `segment` (from 0) of a track: the scripts tools/jukebox writes use the same.
function Catalog.soundName(trackKey, segment)
	return string.format("JukeboxMoon_T%d_S%d", math.floor(trackKey), math.floor(segment))
end

-- "3:07" for 187000 ms
function Catalog.clock(ms)
	local s = math.floor((tonumber(ms) or 0) / 1000)
	if s < 0 then s = 0 end
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

return Catalog
