require "simple-suppressors/diagnostics"
SimpleSuppressorsDiagnostics.loaded("DevStartingKit.Shared")

local LOADED_GUNS = {
    { gun = "Base.Shotgun",         suppressor = "SimpleSuppressors.Suppressor_12Gauge" },
    { gun = "Base.JS3T_Shotgun",    suppressor = "SimpleSuppressors.Suppressor_12Gauge" },
    { gun = "Base.AssaultRifle",    suppressor = "SimpleSuppressors.Suppressor_556" },
    { gun = "Base.VarmintRifle",    suppressor = "SimpleSuppressors.Suppressor_556" },
    { gun = "Base.JS14_Rifle",      suppressor = "SimpleSuppressors.Suppressor_556" },
    { gun = "Base.Pistol",          suppressor = "SimpleSuppressors.Suppressor_9mm" },
    { gun = "Base.Pistol2",         suppressor = "SimpleSuppressors.Suppressor_45ACP" },
    { gun = "Base.Pistol3",         suppressor = "SimpleSuppressors.Suppressor_44" },
    { gun = "Base.TrapperCarbine",  suppressor = "SimpleSuppressors.Suppressor_45ACP" },
    { gun = "Base.L92_Carbine",     suppressor = "SimpleSuppressors.Suppressor_357" },
    { gun = "Base.L94_Rifle",       suppressor = "SimpleSuppressors.Suppressor_3030" },
    { gun = "Base.AssaultRifle2",   suppressor = "SimpleSuppressors.Suppressor_308" },
    { gun = "Base.HuntingRifle",    suppressor = "SimpleSuppressors.Suppressor_308" },
    { gun = "Base.MSR7T_Rifle",     suppressor = "SimpleSuppressors.Suppressor_308" },
}

local EXTRA_GEAR = {
    "SimpleSuppressors.SuppressorManual",
    "SimpleSuppressors.Suppressor_OilFilter_12Gauge",
    "SimpleSuppressors.Suppressor_OilFilter_556",
    "SimpleSuppressors.Suppressor_OilFilter_9mm",
    "SimpleSuppressors.Suppressor_OilFilter_45ACP",
    "SimpleSuppressors.Suppressor_OilFilter_308",
    "SimpleSuppressors.Suppressor_OilFilter_3030",
    "SimpleSuppressors.Suppressor_OilFilter_357",
    "SimpleSuppressors.Suppressor_OilFilter_44",
    "Base.SmallSheetMetal", "Base.MetalPipe",
    "Base.HandDrill", "Base.Screwdriver", "Base.BlowTorch", "Base.WeldingMask",
    "Base.ShotgunShellsBox", "Base.556Box", "Base.Bullets9mmBox", "Base.Bullets45Box",
    "Base.308Box", "Base.Bullets357Box", "Base.Bullets44Box", "Base.3030Box",
}

local function addStartingItem(player, itemType)
    if not ScriptManager.instance:getItem(itemType) then return nil end
    return player:getInventory():AddItem(itemType)
end

local function fillWeapon(player, weapon)
    local inventory = player:getInventory()
    local magazineType = weapon:getMagazineType()
    if magazineType and ScriptManager.instance:getItem(magazineType) then
        local magazine = inventory:AddItem(magazineType)
        if magazine and magazine:getMaxAmmo() > 0 then
            magazine:setCurrentAmmoCount(magazine:getMaxAmmo())
            inventory:Remove(magazine)
        end
        weapon:setContainsClip(true)
    end

    local maxAmmo = weapon:getMaxAmmo()
    if maxAmmo and maxAmmo > 0 then
        weapon:setCurrentAmmoCount(maxAmmo)
    end
end

local function attachSuppressor(player, weapon, suppressorType)
    local part = addStartingItem(player, suppressorType)
    if not part then return false end
    weapon:attachWeaponPart(player, part)
    player:getInventory():Remove(part)
    return true
end

local function addDevStartingKit(player)
    if isClient() or not SandboxVars or not SandboxVars.SimpleSuppressors
        or not SandboxVars.SimpleSuppressors.DevStartingKit then return end

    local data = player:getModData()
    if data.suppressorDevKitGiven then return end

    for _, itemType in ipairs(EXTRA_GEAR) do
        addStartingItem(player, itemType)
    end

    for _, entry in ipairs(LOADED_GUNS) do
        local weapon = addStartingItem(player, entry.gun)
        if weapon and instanceof(weapon, "HandWeapon") and weapon:isRanged()
            and attachSuppressor(player, weapon, entry.suppressor) then
            fillWeapon(player, weapon)
        end
    end

    data.suppressorDevKitGiven = true
end

Events.OnNewGame.Add(SimpleSuppressorsDiagnostics.guard(
    "DevStartingKit.Shared", "OnNewGame.AddDevStartingKit", addDevStartingKit))
