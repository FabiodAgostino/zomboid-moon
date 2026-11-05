-- JukeboxMoon: the catalogue of CDs, read from JukeboxMoonCatalog. That table is defined by CatalogData.lua, which
-- tools/jukebox generates and the launcher installs with the music: it is not in the repository. Without it there is
-- no music at all (fail closed): the window says so and the server plays nothing.
--
--   JukeboxMoonCatalog = { version = "...", segmentMs = 10000, overlapMs = 250, albums = {
--     { key = 1, id = "estate-1993", item = "JukeboxMoon.CD_1", title = "...", artist = "...", year = 1993,
--       loot = 1.0, archived = false,
--       tracks = { { key = 1, id = "traccia-01", n = 1, title = "...", artist = "...", ms = 183450, segments = 19 } } } } }

require "JukeboxMoon/Core"

if JukeboxMoon.Catalog then return JukeboxMoon.Catalog end

local Catalog = {}
JukeboxMoon.Catalog = Catalog

local indexed = nil   -- the table last indexed: a new JukeboxMoonCatalog (tests, a reload) is indexed again

local byItem, byTrack, albums = {}, {}, {}

local function index()
	local data = JukeboxMoonCatalog
	if data == indexed then return end
	indexed = data
	byItem, byTrack, albums = {}, {}, {}
	if type(data) ~= "table" or type(data.albums) ~= "table" then return end
	for _, album in ipairs(data.albums) do
		if type(album) == "table" and type(album.item) == "string" and type(album.tracks) == "table" then
			albums[#albums + 1] = album
			byItem[album.item] = album
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

function Catalog.track(key)
	index()
	return byTrack[tonumber(key) or -1]
end

-- The album of a CD item, or nil for anything else.
function Catalog.albumOf(item)
	if not item then return nil end
	local ok, fullType = pcall(function() return item:getFullType() end)
	if not ok then return nil end
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
