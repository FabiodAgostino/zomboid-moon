require "simple-suppressors/diagnostics"
require "simple-suppressors/compatibility"
-- Recipe migration mutates a player's learned-recipes list, so it must be
-- loaded in the authoritative server Lua state. The client also requires the
-- file through suppressoreffects.lua, but recipemigration intentionally does
-- nothing there; without this server entrypoint old manual readers in MP never
-- received the missing .30-30 recipes.
require "simple-suppressors/recipemigration"
require "Items/ProceduralDistributions"
SimpleSuppressorsDiagnostics.loaded("SuppressorsDistributions.Server")
SimpleSuppressorsDiagnostics.info("SuppressorsDistributions.Server", "entrypoint", "loaded")
-- Thematic spread: gun/police/military caches carry finished suppressors and
-- adapters; mechanic, welding, metal, technical-book, and outdoor caches carry
-- components or the manual. The manual also reaches bookstores, libraries,
-- universities, repair shops, and safehouse shelves, but not generic homes.
local LOOT = {
	-- Gun stores: finished suppressors, caliber adapters, and the manual.
	GunStoreAccessories = {
		{"SimpleSuppressors.Suppressor_12Gauge", 4}, {"SimpleSuppressors.Suppressor_556", 4}, {"SimpleSuppressors.Suppressor_9mm", 6},
		{"SimpleSuppressors.Suppressor_45ACP", 6}, {"SimpleSuppressors.Suppressor_308", 3}, {"SimpleSuppressors.Suppressor_357", 4},
		{"SimpleSuppressors.Suppressor_44", 4},
		{"SimpleSuppressors.Suppressor_3030", 3}, {"SimpleSuppressors.Adapter_3030", 5},
		{"SimpleSuppressors.Adapter_Shotgun", 6}, {"SimpleSuppressors.Adapter_556", 6}, {"SimpleSuppressors.Adapter_9mm", 8},
		{"SimpleSuppressors.Adapter_45ACP", 8}, {"SimpleSuppressors.Adapter_44", 6}, {"SimpleSuppressors.Adapter_308", 5}, {"SimpleSuppressors.Adapter_357", 6},
		{"SimpleSuppressors.SuppressorManual", 6},
	},
	GunStoreLiterature = { {"SimpleSuppressors.SuppressorManual", 5}, },
	-- Police armories lean toward pistol and revolver calibers.
	PoliceStorageGuns = {
		{"SimpleSuppressors.Suppressor_9mm", 3}, {"SimpleSuppressors.Suppressor_45ACP", 2}, {"SimpleSuppressors.Suppressor_357", 2},
		{"SimpleSuppressors.Suppressor_44", 2},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.Adapter_45ACP", 2}, {"SimpleSuppressors.Adapter_44", 2},
	},
	-- Military caches lean toward rifle and shotgun calibers.
	ArmyBunkerStorage = {
		{"SimpleSuppressors.Suppressor_556", 3}, {"SimpleSuppressors.Suppressor_308", 2}, {"SimpleSuppressors.Suppressor_12Gauge", 2},
		{"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_308", 2},
	},
	-- Caliber-specific gun-store subsections spread finished suppressors by type.
	GunStorePistols = {
		{"SimpleSuppressors.Suppressor_9mm", 3}, {"SimpleSuppressors.Suppressor_45ACP", 3}, {"SimpleSuppressors.Suppressor_357", 2},
		{"SimpleSuppressors.Suppressor_44", 2},
		{"SimpleSuppressors.Adapter_9mm", 3}, {"SimpleSuppressors.Adapter_45ACP", 3}, {"SimpleSuppressors.Adapter_357", 3}, {"SimpleSuppressors.Adapter_44", 3},
	},
	GunStoreRifles = {
		{"SimpleSuppressors.Suppressor_556", 3}, {"SimpleSuppressors.Suppressor_308", 3},
		{"SimpleSuppressors.Adapter_556", 3}, {"SimpleSuppressors.Adapter_308", 3},
		{"SimpleSuppressors.Suppressor_3030", 2}, {"SimpleSuppressors.Adapter_3030", 3},
	},
	GunStoreShotguns = {
		{"SimpleSuppressors.Suppressor_12Gauge", 3}, {"SimpleSuppressors.Adapter_Shotgun", 4},
	},
	-- SWAT armory and pawn shops: pistol/carbine calibers, plus the manual.
	SWATStorageGuns = {
		{"SimpleSuppressors.Suppressor_9mm", 2}, {"SimpleSuppressors.Suppressor_45ACP", 2}, {"SimpleSuppressors.Suppressor_556", 2},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.Adapter_556", 2},
	},
	PawnShopGuns = {
		{"SimpleSuppressors.Suppressor_9mm", 2}, {"SimpleSuppressors.Suppressor_45ACP", 2}, {"SimpleSuppressors.Suppressor_357", 2},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.SuppressorManual", 3},
	},
	-- Mechanic and garage: scavenged oil filters, baffles, and mounting adapters.
	MechanicSpecial = {
		{"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 8}, {"SimpleSuppressors.Baffle", 6},
		{"SimpleSuppressors.Adapter_9mm", 3}, {"SimpleSuppressors.Adapter_556", 3}, {"SimpleSuppressors.Adapter_45ACP", 3},
		{"SimpleSuppressors.Adapter_Shotgun", 3}, {"SimpleSuppressors.Adapter_308", 2}, {"SimpleSuppressors.Adapter_357", 2}, {"SimpleSuppressors.Adapter_44", 2},
		{"SimpleSuppressors.Adapter_3030", 2},
	},
	GarageMechanics = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 6}, {"SimpleSuppressors.Baffle", 4}, },
	MechanicShelfMisc = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 5}, },
	CrateMechanics = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 5}, {"SimpleSuppressors.Baffle", 4}, },
	MechanicShelfBooks = { {"SimpleSuppressors.SuppressorManual", 4}, },
	-- Welding and metalworking: baffles, baffle stacks, and machined adapters.
	WeldingWorkshopTools = {
		{"SimpleSuppressors.Baffle", 8}, {"SimpleSuppressors.BaffleStack", 2},
	},
	WeldingWorkshopMetal = { {"SimpleSuppressors.Baffle", 6}, {"SimpleSuppressors.BaffleStack", 3}, },
	MetalShopTools = {
		{"SimpleSuppressors.Baffle", 5}, {"SimpleSuppressors.BaffleStack", 2},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_45ACP", 2},
		{"SimpleSuppressors.Adapter_Shotgun", 2}, {"SimpleSuppressors.Adapter_308", 2}, {"SimpleSuppressors.Adapter_357", 2}, {"SimpleSuppressors.Adapter_44", 2},
		{"SimpleSuppressors.Adapter_3030", 2},
	},
	GarageMetalwork = { {"SimpleSuppressors.Baffle", 5}, {"SimpleSuppressors.BaffleStack", 2}, },
	ToolStoreMetalwork = { {"SimpleSuppressors.Baffle", 4}, {"SimpleSuppressors.BaffleStack", 2}, },
	-- Books: the manual follows the same caches as vanilla skill literature.
	BookstoreBooks = { {"SimpleSuppressors.SuppressorManual", 4}, },
	LibraryBooks = { {"SimpleSuppressors.SuppressorManual", 3}, },
	GarageTools = { {"SimpleSuppressors.SuppressorManual", 4}, },
	GunStoreMagazineRack = { {"SimpleSuppressors.SuppressorManual", 4}, },
	BookstoreOutdoors = { {"SimpleSuppressors.SuppressorManual", 4}, },
	LibraryOutdoors = { {"SimpleSuppressors.SuppressorManual", 3}, },
	CampingStoreBooks = { {"SimpleSuppressors.SuppressorManual", 3}, },
	-- Additional active book, technical, military, and survivor pools broaden
	-- discovery beyond dedicated gun stores without touching generic homes.
	BookstoreAutomotive = { {"SimpleSuppressors.SuppressorManual", 3}, },
	BookstoreBlueCollar = { {"SimpleSuppressors.SuppressorManual", 3}, },
	BookstoreGeneralReference = { {"SimpleSuppressors.SuppressorManual", 2}, },
	BookstoreMilitaryHistory = { {"SimpleSuppressors.SuppressorManual", 3}, },
	BookstoreScience = { {"SimpleSuppressors.SuppressorManual", 2}, },
	UniversityLibraryBooks = { {"SimpleSuppressors.SuppressorManual", 3}, },
	ToolStoreBooks = { {"SimpleSuppressors.SuppressorManual", 4}, },
	BlacksmithLiterature = { {"SimpleSuppressors.SuppressorManual", 3}, },
	RangerBooks = { {"SimpleSuppressors.SuppressorManual", 3}, },
	OutdoorSupplyMagazines = { {"SimpleSuppressors.SuppressorManual", 3}, },
	CarSupplyLiterature = { {"SimpleSuppressors.SuppressorManual", 3}, },
	SafehouseBookShelf = { {"SimpleSuppressors.SuppressorManual", 2}, },
	-- Military armories and hangars: finished rifle/shotgun suppressors plus
	-- machined components in maintenance and hangar stock.
	ArmyStorageGuns = {
		{"SimpleSuppressors.Suppressor_556", 3}, {"SimpleSuppressors.Suppressor_308", 2}, {"SimpleSuppressors.Suppressor_12Gauge", 2},
		{"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_308", 2}, {"SimpleSuppressors.Adapter_Shotgun", 2},
		{"SimpleSuppressors.Suppressor_3030", 2}, {"SimpleSuppressors.Adapter_3030", 2},
	},
	ArmyHangarTools = {
		{"SimpleSuppressors.Baffle", 5}, {"SimpleSuppressors.BaffleStack", 2},
		{"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_308", 2},
	},
	ArmyHangarMechanics = {
		{"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 6}, {"SimpleSuppressors.Baffle", 4},
	},
	-- Farm outbuildings and hardware stock: raw components and mounting hardware.
	BarnTools = {
		{"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 5}, {"SimpleSuppressors.Baffle", 4},
	},
	StoreShelfMechanics = {
		{"SimpleSuppressors.Baffle", 4}, {"SimpleSuppressors.BaffleStack", 2},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_Shotgun", 2},
	},
	CrateTools = {
		{"SimpleSuppressors.Baffle", 4}, {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 4},
	},
	-- Auto-parts stores and gas-station mechanic stock: where players expect
	-- to buy an oil filter. Baffles/adapters tag along in the tool sections.
	CarSupplyTools = {
		{"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 8}, {"SimpleSuppressors.Baffle", 4},
		{"SimpleSuppressors.Adapter_9mm", 2}, {"SimpleSuppressors.Adapter_556", 2}, {"SimpleSuppressors.Adapter_Shotgun", 2},
	},
	CarSupplyBatteries = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 5}, },
	GasStorageMechanics = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 6}, {"SimpleSuppressors.Baffle", 3}, },
	GasStorageCombo = { {"SimpleSuppressors.EngineOil", 6}, {"SimpleSuppressors.ScavengedOilFilter", 4}, },
	-- Deprecated GunStoreCounter/GunStoreShelf and nonexistent SafehouseGuns
	-- pools are intentionally not listed; they never produce loot in current B42.
}
local LOOT_CALIBERS = {
	["SimpleSuppressors.Suppressor_12Gauge"] = "12Gauge",
	["SimpleSuppressors.Suppressor_OilFilter_12Gauge"] = "12Gauge",
	["SimpleSuppressors.Adapter_Shotgun"] = "12Gauge",
	["SimpleSuppressors.Suppressor_556"] = "556",
	["SimpleSuppressors.Suppressor_OilFilter_556"] = "556",
	["SimpleSuppressors.Adapter_556"] = "556",
	["SimpleSuppressors.Suppressor_9mm"] = "9mm",
	["SimpleSuppressors.Suppressor_OilFilter_9mm"] = "9mm",
	["SimpleSuppressors.Adapter_9mm"] = "9mm",
	["SimpleSuppressors.Suppressor_45ACP"] = "45ACP",
	["SimpleSuppressors.Suppressor_OilFilter_45ACP"] = "45ACP",
	["SimpleSuppressors.Adapter_45ACP"] = "45ACP",
	["SimpleSuppressors.Suppressor_308"] = "308",
	["SimpleSuppressors.Suppressor_OilFilter_308"] = "308",
	["SimpleSuppressors.Adapter_308"] = "308",
	["SimpleSuppressors.Suppressor_3030"] = "3030",
	["SimpleSuppressors.Suppressor_OilFilter_3030"] = "3030",
	["SimpleSuppressors.Adapter_3030"] = "3030",
	["SimpleSuppressors.Suppressor_357"] = "357",
	["SimpleSuppressors.Suppressor_OilFilter_357"] = "357",
	["SimpleSuppressors.Adapter_357"] = "357",
	["SimpleSuppressors.Suppressor_44"] = "44",
	["SimpleSuppressors.Suppressor_OilFilter_44"] = "44",
	["SimpleSuppressors.Adapter_44"] = "44",
}

local function lootItemEnabled(itemType)
	if itemType == "SimpleSuppressors.EngineOil" and SandboxVars and SandboxVars.SimpleSuppressors and SandboxVars.SimpleSuppressors.EnableVehicleOil == false then return false end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	-- Craft-only removes finished suppressors, keeping the manual and supplies.
	if vars and vars.FindSuppressorsNaturally == false
		and itemType:find("SimpleSuppressors.Suppressor_", 1, true) == 1 then
		return false
	end
	local caliber = LOOT_CALIBERS[itemType]
	if not caliber then return true end
	return SimpleSuppressorsCompatibility.isCaliberEnabled(caliber)
end

local function addSuppressorLoot()
	if SimpleSuppressorsLootInjected then
		SimpleSuppressorsDiagnostics.info("Loot", "inject", "skipped: already injected")
		return
	end
	if not ProceduralDistributions or not ProceduralDistributions.list then
		SimpleSuppressorsDiagnostics.failure("Loot", "inject", "distribution lists unavailable")
		return
	end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	local rarity = (vars and type(vars.LootRarity) == "number") and vars.LootRarity or 75
	if rarity <= 0 then
		SimpleSuppressorsDiagnostics.info("Loot", "inject", "disabled rarity=" .. tostring(rarity))
		return
	end
	local distributions = ProceduralDistributions.list
	local insert = table.insert
	local lists, entriesAdded = 0, 0
	for listName, entries in pairs(LOOT) do
		local list = distributions[listName]
		if list and list.items then
			lists = lists + 1
			for _, entry in ipairs(entries) do
				if lootItemEnabled(entry[1]) then
					-- Keep positive probability at low rarity without collapsing
					-- every entry to zero through integer flooring.
					local weight = math.max(0.1, entry[2] * rarity / 100)
					insert(list.items, entry[1]); insert(list.items, weight); entriesAdded = entriesAdded + 1
				end
			end
		else
			SimpleSuppressorsDiagnostics.info("Loot", "listMissing", listName)
		end
	end
	if lists == 0 then
		SimpleSuppressorsDiagnostics.failure("Loot", "inject", "no target distribution lists found")
		return
	end
	SimpleSuppressorsLootInjected = true
	SimpleSuppressorsDiagnostics.info("Loot", "inject", "lists=" .. lists .. " entries=" .. entriesAdded .. " rarity=" .. tostring(rarity))
end
-- Vehicle trunks: a scavenged oil filter is a natural thing to find in a car
-- boot. ClutterTables.TrunkItems is a flat {name, weight, ...} array shared by
-- every vehicle trunk-junk roll.
local function addTrunkOilFilter()
	if SimpleSuppressorsTrunkInjected then return end
	local vars = SandboxVars and SandboxVars.SimpleSuppressors
	if not ClutterTables or type(ClutterTables.TrunkItems) ~= "table" then
		SimpleSuppressorsDiagnostics.info("Loot", "trunk", "ClutterTables.TrunkItems unavailable")
		return
	end
	local rarity = (vars and type(vars.LootRarity) == "number") and vars.LootRarity or 75
	if rarity <= 0 then return end
	local weight = math.max(1, 4 * rarity / 100)
	table.insert(ClutterTables.TrunkItems, "SimpleSuppressors.ScavengedOilFilter")
	table.insert(ClutterTables.TrunkItems, weight)
	SimpleSuppressorsTrunkInjected = true
	SimpleSuppressorsDiagnostics.info("Loot", "trunk", "oil filter added weight=" .. tostring(weight))
end

if not SimpleSuppressorsSuppressorsDistributionsRegistered then
	Events.OnPreDistributionMerge.Add(addSuppressorLoot)
	Events.OnPreDistributionMerge.Add(addTrunkOilFilter)
	SimpleSuppressorsSuppressorsDistributionsRegistered = true
end
