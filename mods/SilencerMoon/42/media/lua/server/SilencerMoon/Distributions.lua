-- SilencerMoon in the loot: only the magazine that teaches the suppressors. Rather rare, not very rare: weights like
-- the game's recipe magazines in the same lists (WeaponMag2 is 0.5 in BookstoreMilitaryHistory, the farming
-- magazines 2 in GunStoreMagazineRack). No suppressor, alloy or oil filter is ever found: they are made.

require "Items/ProceduralDistributions"

local MAGAZINE = "SilencerMoon.SuppressorMagazine"
local LISTS = {
	GunStoreLiterature = 1,
	GunStoreMagazineRack = 1,
	BookstoreMilitaryHistory = 0.5,
	ToolStoreBooks = 0.5,
	MechanicShelfBooks = 0.5,
}

local function addMagazine()
	if SilencerMoon and SilencerMoon.lootAdded then return end
	local lists = ProceduralDistributions and ProceduralDistributions.list
	if not lists then
		print("[SilencerMoon] ProceduralDistributions.list is missing: the magazine is not in the loot")
		return
	end
	for name, weight in pairs(LISTS) do
		local list = lists[name]
		if list and list.items then
			table.insert(list.items, MAGAZINE)
			table.insert(list.items, weight)
		else
			print("[SilencerMoon] loot list " .. name .. " is missing")
		end
	end
	SilencerMoon = SilencerMoon or {}
	SilencerMoon.lootAdded = true
end

Events.OnPreDistributionMerge.Add(addMagazine)
