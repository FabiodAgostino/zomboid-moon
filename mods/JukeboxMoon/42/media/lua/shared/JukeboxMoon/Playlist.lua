-- JukeboxMoon: the playlist of a jukebox, as plain functions (no game object here, so the tests run it as it is).
-- A playlist is every track of every CD in the jukebox, CD after CD in the container's order, tracks in the album's
-- order. An entry is { cd = item id, track = track key, album = album key, n = track number }: two copies of the same
-- CD are two different CDs.

require "JukeboxMoon/Catalog"

if JukeboxMoon.Playlist then return JukeboxMoon.Playlist end

local Catalog = JukeboxMoon.Catalog
local Playlist = {}
JukeboxMoon.Playlist = Playlist

Playlist.MODULUS = 2147483647
Playlist.SEED = 12345

-- cds: { { id = number, album = album key }, ... } in the container's order (Box.cds). Unknown albums are skipped.
function Playlist.build(cds)
	local entries = {}
	for _, cd in ipairs(cds or {}) do
		local album = Catalog.albumByKey(cd.album)
		if album then
			for _, track in ipairs(album.tracks) do
				entries[#entries + 1] = { cd = cd.id, track = track.key, album = album.key, n = track.n }
			end
		end
	end
	return entries
end

function Playlist.indexOf(entries, cd, track)
	for i, entry in ipairs(entries or {}) do
		if entry.cd == cd and entry.track == track then return i end
	end
	return nil
end

-- A starting value for lcg from any number (a time, a position): between 1 and MODULUS - 1.
function Playlist.seed(n)
	return (math.floor(math.abs(tonumber(n) or 0)) % (Playlist.MODULUS - 1)) + 1
end

-- Park-Miller: every value stays below 2^46, exact in the game's doubles.
function Playlist.lcg(rand)
	local r = math.floor(tonumber(rand) or Playlist.SEED)
	if r <= 0 or r >= Playlist.MODULUS then r = Playlist.SEED end
	return (r * 16807) % Playlist.MODULUS
end

-- The index after `current` (dir 1) or before it (dir -1), looping; with shuffle a random one that is never the same
-- as the current (when there are at least two). Returns index, rand.
function Playlist.step(count, current, dir, shuffle, rand)
	if count <= 0 then return nil, rand end
	current = current or 0
	if shuffle and count > 1 then
		rand = Playlist.lcg(rand)
		local pick = (rand % count) + 1
		if pick == current then pick = (pick % count) + 1 end
		return pick, rand
	end
	if current < 1 or current > count then
		return (dir or 1) < 0 and count or 1, rand
	end
	return ((current - 1 + (dir or 1)) % count) + 1, rand
end

-- After the CDs changed: where the playing entry (old[current]) is now, or, when its CD was taken out, the first
-- entry after it in the old order that is still there. nil when nothing is left. Returns index, moved (true when the
-- playing track itself is gone and the jukebox must go on with another).
function Playlist.follow(old, current, new)
	if #new == 0 then return nil, true end
	local playing = old[current or 0]
	if playing then
		local i = Playlist.indexOf(new, playing.cd, playing.track)
		if i then return i, false end
		for step = 1, #old - 1 do
			local candidate = old[((current - 1 + step) % #old) + 1]
			local j = Playlist.indexOf(new, candidate.cd, candidate.track)
			if j then return j, true end
		end
	end
	return 1, true
end

-- Two playlists with the same entries in the same order.
function Playlist.same(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i].cd ~= b[i].cd or a[i].track ~= b[i].track then return false end
	end
	return true
end

return Playlist
