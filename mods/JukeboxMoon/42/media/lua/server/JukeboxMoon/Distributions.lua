-- JukeboxMoon in the loot (FR-12): the CDs of the catalogue join the game's lists that already hold CDs
-- (Disc_Retail), never replacing a list. Each list gets a total weight (BASE x the rarity of the server's options),
-- shared by the albums as their lootWeight says. Archived albums are never found. The server's loot (and single
-- player's): a multiplayer client, which loads media/lua/server too, skips it.
if isClient() then return end

require "Items/ProceduralDistributions"
require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog

local Loot = {}
JukeboxMoon.Loot = Loot

-- the game's own weight of CDs there, from about a tenth (music shops) to a few hundredths (bedrooms)
Loot.BASE = {
	CrateCompactDiscs = 10,
	MusicStoreCDs = 10,
	ElectronicStoreMusic = 6,
	BandPracticeInstruments = 3,
	MovieRentalShelves = 3,
	LivingRoomShelf = 1,
	LivingRoomShelfClassy = 1,
	LivingRoomShelfRedneck = 1,
	RecRoomShelf = 1,
	BedroomSidetable = 0.5,
	BedroomSidetableClassy = 0.5,
	BedroomSidetableRedneck = 0.5,
	BedroomDresser = 0.5,
	BedroomDresserClassy = 0.5,
	BedroomDresserRedneck = 0.5,
}

-- LootRarity: 1 rare, 2 normal, 3 common
Loot.RARITY = { 1, 2.5, 5 }

-- { { item, weight } } for one list: its total shared by the albums. The game's CDs (albums with `media`) are
-- already in the loot as the game's discs.
function Loot.weights(base)
	local albums = {}
	for _, album in ipairs(Catalog.activeAlbums()) do
		if album.item then albums[#albums + 1] = album end
	end
	local total = 0
	for _, album in ipairs(albums) do total = total + math.max(0, tonumber(album.loot) or 1) end
	local out = {}
	if total <= 0 then return out end
	local rarity = Loot.RARITY[math.floor(Core.option("LootRarity"))] or 1
	for _, album in ipairs(albums) do
		local share = math.max(0, tonumber(album.loot) or 1) / total
		if share > 0 then
			out[#out + 1] = { item = album.item, weight = math.max(0.01, base * rarity * share) }
		end
	end
	return out
end

function Loot.add()
	if Loot.added then return end
	Loot.added = true
	if not Core.option("Enabled") or not Core.option("EnableCDLoot") then return end
	if not Catalog.available() then
		Core.warn("no catalogue: no CD in the loot")
		return
	end
	local lists = ProceduralDistributions and ProceduralDistributions.list
	if not lists then
		Core.warn("ProceduralDistributions.list is missing: no CD in the loot")
		return
	end
	for name, base in pairs(Loot.BASE) do
		local list = lists[name]
		if list and list.items then
			for _, entry in ipairs(Loot.weights(base)) do
				table.insert(list.items, entry.item)
				table.insert(list.items, entry.weight)
			end
		else
			Core.warn("loot list " .. name .. " is missing")
		end
	end
end

Events.OnPreDistributionMerge.Add(Loot.add)

return Loot
