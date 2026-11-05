"""SilencerMoon: the mod's Lua run in a real Lua (lupa), plus static checks of scripts, files and translations.

Run from the repository root with a Python that has pytest and lupa (for example ZomBOT's .venv):

    python -m pytest -q tests/silencermoon

The imitations of the game below have only the methods the mod calls, with the game's names (checked in the 42.21
jar); a global the mod does not define is nil here as in the game. Weapon values are stored as 32-bit floats, as
HandWeapon keeps them.
"""

import json
import random
import re
from pathlib import Path

import pytest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
MOD = ROOT / "mods" / "SilencerMoon" / "42"
MEDIA = MOD / "media"
LUA = MEDIA / "lua"
SCRIPTS = MEDIA / "scripts"

PRELUDE = r"""
EVENTS = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { list = {} }
    function e.Add(f) table.insert(e.list, f) end
    rawset(t, name, e)
    EVENTS[name] = e
    return e
end })
CLIENT, SERVER, NOW = false, false, 0
function isClient() return CLIENT end
function isServer() return SERVER end
function getTimestampMs() return NOW end
function instanceof(o, cls) return type(o) == "table" and o.classes ~= nil and o.classes[cls] == true end
RAND = function(n) return 1 end
function ZombRand(n) return RAND(n) end
SENT = {}
function sendClientCommand(player, module, command, args) table.insert(SENT, { module = module, command = command, args = args }) end
SYNCED = 0
function syncHandWeaponFields(player, weapon) SYNCED = SYNCED + 1 end
ADDED = {}
function sendAddItemToContainer(container, item) table.insert(ADDED, item) end
XP = 0
function addXp(character, perk, amount) XP = XP + amount end
Perks = { Mechanics = "Mechanics" }
ItemTag = { WRENCH = "base:wrench" }

local function f32(x) return (string.unpack("f", string.pack("f", x))) end
F32 = f32

NEXT_ID = 0
function newPart(fullType, condition, conditionMax)
    local p = { classes = { WeaponPart = true, InventoryItem = true }, fullType = fullType,
        condition = condition, conditionMax = conditionMax or condition }
    function p:getFullType() return self.fullType end
    function p:getCondition() return self.condition end
    function p:setCondition(c) self.condition = c end
    function p:getConditionMax() return self.conditionMax end
    function p:isBroken() return self.condition <= 0 end
    return p
end

FRESH = {}
function newWeapon(fullType, range, low, high)
    NEXT_ID = NEXT_ID + 1
    local w = { classes = { HandWeapon = true, InventoryItem = true }, fullType = fullType, id = NEXT_ID,
        range = f32(range), low = f32(low), high = f32(high), modData = {}, parts = {}, partList = {},
        ammo = 0, chambered = false, spentChambered = false, spentCount = 0, magazine = nil, clip = false,
        radius = 100, swing = "VanillaShoot", flash = "flash_key" }
    function w:getFullType() return self.fullType end
    function w:getID() return self.id end
    function w:isRanged() return true end
    function w:getModData() return self.modData end
    function w:getMaxRange() return self.range end
    function w:setMaxRange(v) self.range = f32(v) end
    function w:getMinDamage() return self.low end
    function w:setMinDamage(v) self.low = f32(v) end
    function w:getMaxDamage() return self.high end
    function w:setMaxDamage(v) self.high = f32(v) end
    function w:getWeaponPart(t) return self.parts[t] end
    function w:getAllWeaponParts()
        local list = {}
        for _, p in pairs(self.parts) do table.insert(list, p) end
        return { size = function() return #list end }
    end
    function w:getSoundRadius() return self.radius end
    function w:setSoundRadius(v) self.radius = v end
    function w:getSwingSound() return self.swing end
    function w:setSwingSound(v) self.swing = v end
    function w:getMuzzleFlashModelKey() return self.flash end
    function w:setMuzzleFlashModelKey(v) self.flash = v end
    function w:getCurrentAmmoCount() return self.ammo end
    function w:isRoundChambered() return self.chambered end
    function w:isSpentRoundChambered() return self.spentChambered end
    function w:getSpentRoundCount() return self.spentCount end
    function w:getMagazineType() return self.magazine end
    function w:isContainsClip() return self.clip end
    -- the game: fixed modifiers (0 for ours), then the part's OnAttach / OnDetach
    function w:attach(part, typeName)
        self.parts[typeName or "Suppressor"] = part
        if SilencerMoon.onAttach then SilencerMoon.onAttach(nil, self, part) end
    end
    function w:detach(typeName)
        local part = self.parts[typeName or "Suppressor"]
        self.parts[typeName or "Suppressor"] = nil
        if SilencerMoon.onDetach then SilencerMoon.onDetach(nil, self, part) end
        return part
    end
    -- HandWeapon.detachWeaponPart(character, part): the game's own modifiers off (0 for ours), then OnDetach
    function w:detachWeaponPart(owner, part)
        for t, p in pairs(self.parts) do if p == part then self.parts[t] = nil end end
        DETACHED_BY = owner
        if SilencerMoon.onDetach then SilencerMoon.onDetach(owner, self, part) end
    end
    function w:getContainer() return self.container end
    function w:getWorldItem() return self.world end
    function w:hasModData() return next(self.modData) ~= nil end
    return w
end

function instanceItem(fullType)
    local w = newWeapon(fullType, 10, 1, 2)
    local fresh = FRESH[fullType] or {}
    w.radius = fresh.radius or 100
    w.swing = fresh.swing or "VanillaShoot"
    w.flash = fresh.flash or "flash_key"
    return w
end

function newPlayer()
    local p = { classes = { IsoPlayer = true, IsoGameCharacter = true }, shove = false, empty = false,
        primary = nil, name = "tester", mechanics = 10, wrench = true, inVehicle = nil, items = {} }
    function p:isLocalPlayer() return true end
    function p:isDoShove() return self.shove end
    function p:isRangedWeaponEmpty() return self.empty end
    function p:getPrimaryHandItem() return self.primary end
    function p:getUsername() return self.name end
    function p:getPerkLevel(perk) return self.mechanics end
    function p:getVehicle() return self.inVehicle end
    local inventory = { owner = p }
    function inventory:containsTagEvalRecurse(tag, fn) return p.wrench end
    function inventory:AddItem(t) local item = { type = t }; table.insert(p.items, item); return item end
    function p:getInventory() return inventory end
    function p:isTimedActionInstant() return false end
    return p
end

function newVehicle(engine)
    local v = { modData = {}, running = false, transmitted = 0 }
    function v:getModData() return self.modData end
    function v:transmitModData() self.transmitted = self.transmitted + 1 end
    function v:isEngineRunning() return self.running end
    function v:isInArea(area, character) return true end
    local part = { vehicle = v }
    function part:getVehicle() return self.vehicle end
    function part:getArea() return "Engine" end
    function v:getPartById(id) if id == "Engine" and engine ~= false then return part end return nil end
    return v
end

package.preload["TimedActions/ISBaseTimedAction"] = function()
    ISBaseTimedAction = {}
    ISBaseTimedAction.__index = ISBaseTimedAction
    function ISBaseTimedAction:derive(name)
        local c = setmetatable({}, { __index = self })
        c.__index = c
        c.Type = name
        return c
    end
    function ISBaseTimedAction.new(class, character)
        return setmetatable({ character = character }, class)
    end
    function ISBaseTimedAction:stop() end
    function ISBaseTimedAction:perform() end
end
package.preload["ISUI/ISToolTipInv"] = function()
    ISToolTipInv = { new = function(class, item) return { item = item } end, render = function(self) end }
end
"""


def lua_runtime(*files):
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = (LUA / "shared").as_posix()
    lua.execute(f'package.path = "{shared}/?.lua;" .. package.path')
    lua.execute(PRELUDE)
    for name in files:
        lua.execute((LUA / name).read_text(encoding="utf-8"))
    return lua


@pytest.fixture
def lua():
    return lua_runtime("shared/SilencerMoon/Core.lua", "shared/SilencerMoon/Stats.lua", "shared/SilencerMoon/Shot.lua")


def f32(x: float) -> float:
    import struct

    return struct.unpack("f", struct.pack("f", x))[0]


TIERS = {
    "SilencerMoon.Suppressor_OilFilter": (0.70, 0.60, 0.75, 5),
    "SilencerMoon.Suppressor_Pistol_Copper": (0.60, 0.70, 0.80, 10),
    "SilencerMoon.Suppressor_Rifle_Copper": (0.60, 0.70, 0.80, 10),
    "SilencerMoon.Suppressor_Pistol_Ballistic": (0.35, 0.80, 0.875, 100),
    "SilencerMoon.Suppressor_Rifle_Ballistic": (0.35, 0.80, 0.875, 100),
}


# ------------------------------------------------------------------ range and damage


@pytest.mark.parametrize("part_type", sorted(TIERS))
def test_a_mounted_suppressor_scales_range_and_damage_once(lua, part_type):
    radius, range_share, damage_share, _ = TIERS[part_type]
    w = lua.eval(f'newWeapon("Base.HuntingRifle", 40, 1.2, 2.0)')
    w.attach(w, lua.eval(f'newPart("{part_type}", 10)'))
    assert w.range == pytest.approx(40 * range_share, rel=1e-6)
    assert w.low == pytest.approx(1.2 * damage_share, rel=1e-6)
    assert w.high == pytest.approx(2.0 * damage_share, rel=1e-6)
    stats = lua.eval("SilencerMoon.Stats")
    for _ in range(5):  # equip, shots, reloads: nothing piles up
        assert stats.refresh(w) is False
    assert w.range == pytest.approx(40 * range_share, rel=1e-6)
    w.detach(w)
    assert (w.range, w.low, w.high) == (f32(40), f32(1.2), f32(2.0))
    assert w.modData.SilencerMoon is None


def test_attaching_and_removing_many_times_gives_back_the_exact_values(lua):
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    for _ in range(200):
        w.attach(w, lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Ballistic", 10)'))
        w.detach(w)
    assert (w.range, w.low, w.high) == (f32(15), f32(0.6), f32(1.0))


def test_a_saved_and_loaded_weapon_is_not_penalised_twice(lua):
    w = lua.eval('newWeapon("Base.AssaultRifle", 30, 1.0, 1.6)')
    w.attach(w, lua.eval('newPart("SilencerMoon.Suppressor_Rifle_Copper", 10)'))
    saved = (w.range, w.low, w.high)
    # the save keeps the weapon's values and modData; loading does not call OnAttach
    loaded = lua.eval('newWeapon("Base.AssaultRifle", 0, 0, 0)')
    loaded.range, loaded.low, loaded.high = saved
    loaded.modData = w.modData
    loaded.parts["Suppressor"] = w.parts["Suppressor"]
    assert lua.eval("SilencerMoon.Stats").refresh(loaded) is False
    assert (loaded.range, loaded.low, loaded.high) == saved
    loaded.detach(loaded)
    assert (loaded.range, loaded.low, loaded.high) == (f32(30), f32(1.0), f32(1.6))


def test_a_change_made_by_another_part_meanwhile_is_kept(lua):
    w = lua.eval('newWeapon("Base.HuntingRifle", 40, 1.2, 2.0)')
    w.attach(w, lua.eval('newPart("SilencerMoon.Suppressor_Rifle_Ballistic", 10)'))
    w.range = f32(w.range + 2)  # the game adds another part's +2 range
    lua.eval("SilencerMoon.Stats").refresh(w)
    assert w.range == pytest.approx(42 * 0.8, rel=1e-6)  # the percentage now counts the other part too
    w.detach(w)
    assert w.range == pytest.approx(42, rel=1e-6)


def test_a_worn_out_suppressor_gives_the_weapon_back_its_values(lua):
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    part = lua.eval('newPart("SilencerMoon.Suppressor_OilFilter", 1, 5)')
    w.attach(w, part)
    assert w.range == pytest.approx(9, rel=1e-6)
    lua.execute("RAND = function(n) return 0 end")  # the next round wears it
    assert lua.eval("SilencerMoon.Shot").wear(w) is True
    assert part.condition == 0
    assert (w.range, w.low, w.high) == (f32(15), f32(0.6), f32(1.0))


def test_the_client_never_changes_range_or_damage(lua):
    lua.execute("CLIENT = true")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.attach(w, lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Copper", 10)'))
    assert (w.range, w.low, w.high) == (f32(15), f32(0.6), f32(1.0))


def test_a_part_that_is_not_ours_changes_nothing(lua):
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.attach(w, lua.eval('newPart("Base.Laser", 10)'), "Canon")
    assert lua.eval("SilencerMoon.Stats").refresh(w) is False
    assert (w.range, w.low, w.high) == (f32(15), f32(0.6), f32(1.0))


# ------------------------------------------------------------------ wear


@pytest.mark.parametrize(
    "part_type,mean,tolerance",
    [
        ("SilencerMoon.Suppressor_OilFilter", 25, 3),
        ("SilencerMoon.Suppressor_Rifle_Copper", 100, 5),
        ("SilencerMoon.Suppressor_Pistol_Ballistic", 1000, 25),
    ],
)
def test_the_average_life_over_10000_suppressors(lua, part_type, mean, tolerance):
    rng = random.Random(42)
    lua.globals().RAND = lambda n: rng.randrange(int(n))
    wear = lua.eval("SilencerMoon.Shot").wear
    condition_max = 5 if "OilFilter" in part_type else 10
    lives = []
    for _ in range(10000):
        w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
        part = lua.eval(f'newPart("{part_type}", {condition_max})')
        w.parts["Suppressor"] = part
        shots = 0
        while part.condition > 0:
            wear(w)
            shots += 1
        lives.append(shots)
    average = sum(lives) / len(lives)
    assert abs(average - mean) <= tolerance
    assert len(set(lives)) > 10  # random, not a fixed number of shots
    assert lua.eval("SilencerMoon.Core").averageShots(lua.eval("SilencerMoon.Core").tierOfType(part_type)) == mean


def test_the_shooter_reports_each_round_and_skips_dry_pulls_and_shoves(lua):
    lua.execute("CLIENT = true")
    on_hit = lua.eval("EVENTS.OnWeaponSwingHitPoint.list[1]")
    player = lua.eval("newPlayer()")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.parts["Suppressor"] = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Copper", 10)')
    on_hit(player, w)
    player.empty = True
    on_hit(player, w)
    player.empty = False
    player.shove = True
    on_hit(player, w)
    player.shove = False
    w.parts["Suppressor"].condition = 0
    on_hit(player, w)
    sent = lua.eval("SENT")
    assert len(sent) == 1
    assert sent[1].module == "SilencerMoon" and sent[1].command == "shot" and sent[1].args.id == w.id


def test_the_dedicated_server_ignores_its_own_hit_event(lua):
    lua.execute("SERVER = true; RAND = function(n) return 0 end")
    on_hit = lua.eval("EVENTS.OnWeaponSwingHitPoint.list[1]")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    part = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Copper", 10)')
    w.parts["Suppressor"] = part
    on_hit(lua.eval("newPlayer()"), w)
    assert part.condition == 10


def test_single_player_wears_on_the_spot(lua):
    lua.execute("RAND = function(n) return 0 end")
    on_hit = lua.eval("EVENTS.OnWeaponSwingHitPoint.list[1]")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    part = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Copper", 10)')
    w.parts["Suppressor"] = part
    on_hit(lua.eval("newPlayer()"), w)
    assert part.condition == 9
    assert len(lua.eval("SENT")) == 0


@pytest.fixture
def server():
    lua = lua_runtime(
        "shared/SilencerMoon/Core.lua",
        "shared/SilencerMoon/Stats.lua",
        "shared/SilencerMoon/Shot.lua",
        "server/SilencerMoon/Commands.lua",
    )
    lua.execute("SERVER = true; RAND = function(n) return 0 end")
    return lua


def test_the_server_rolls_a_reported_round_and_sends_the_weapon_back(server):
    player = server.eval("newPlayer()")
    w = server.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.parts["Suppressor"] = server.eval('newPart("SilencerMoon.Suppressor_Pistol_Copper", 10)')
    player.primary = w
    command = server.eval("SilencerMoon.onClientCommand")
    command("SilencerMoon", "shot", player, server.eval(f"{{ id = {w.id} }}"))
    assert w.parts["Suppressor"].condition == 9
    assert server.eval("SYNCED") == 1
    command("SilencerMoon", "shot", player, server.eval(f"{{ id = {w.id + 1} }}"))  # not the weapon in hand
    command("Other", "shot", player, server.eval(f"{{ id = {w.id} }}"))
    assert w.parts["Suppressor"].condition == 9


def test_the_server_takes_at_most_20_rounds_a_second(server):
    player = server.eval("newPlayer()")
    w = server.eval('newWeapon("Base.AssaultRifle", 30, 1.0, 1.6)')
    w.parts["Suppressor"] = server.eval('newPart("SilencerMoon.Suppressor_Rifle_Ballistic", 100)')
    player.primary = w
    command = server.eval("SilencerMoon.onClientCommand")
    args = server.eval(f"{{ id = {w.id} }}")
    for _ in range(50):
        command("SilencerMoon", "shot", player, args)
    assert w.parts["Suppressor"].condition == 80
    server.execute("NOW = 1000")
    command("SilencerMoon", "shot", player, args)
    assert w.parts["Suppressor"].condition == 79


# ------------------------------------------------------------------ noise


@pytest.mark.parametrize(
    "part_type,radius,sound,flash",
    [
        ("SilencerMoon.Suppressor_OilFilter", 70, "M9Shoot", "flash_key"),
        ("SilencerMoon.Suppressor_Pistol_Copper", 60, "SilencerMoon_Suppressed9mm", None),
        ("SilencerMoon.Suppressor_Pistol_Ballistic", 35, "SilencerMoon_Suppressed9mm", None),
    ],
)
def test_the_shot_noise_of_each_tier_and_back(lua, part_type, radius, sound, flash):
    lua.execute('FRESH["Base.Pistol"] = { radius = 100, swing = "M9Shoot", flash = "flash_key" }')
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.swing = "M9Shoot"
    w.parts["Suppressor"] = lua.eval(f'newPart("{part_type}", 10)')
    shot = lua.eval("SilencerMoon.Shot")
    shot.applyNoise(w)
    assert (w.radius, w.swing, w.flash) == (radius, sound, flash)
    w.parts["Suppressor"] = None
    shot.applyNoise(w)
    assert (w.radius, w.swing, w.flash) == (100, "M9Shoot", "flash_key")


def test_the_dedicated_server_does_not_touch_the_noise(lua):
    lua.execute("SERVER = true")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.parts["Suppressor"] = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Ballistic", 10)')
    lua.eval("SilencerMoon.Shot").applyNoise(w)
    assert w.radius == 100


def test_every_supported_firearm_has_a_suppressed_sound():
    sounds = set(re.findall(r"sound (SilencerMoon_Suppressed\w+)", (SCRIPTS / "SilencerMoon_sounds.txt").read_text()))
    lua = lua_runtime("shared/SilencerMoon/Core.lua")
    for weapon, calibre in lua.eval("SilencerMoon.Core.CALIBER_SOUND").items():
        assert f"SilencerMoon_Suppressed{calibre}" in sounds, weapon
        assert f"SilencerMoon_Suppressed{calibre}FullAuto" in sounds, weapon


# ------------------------------------------------------------------ alloy recipes


def test_only_an_empty_bare_shotgun_goes_into_the_furnace(lua):
    test = lua.eval("SilencerMoon.recipeTestShotgun")
    w = lua.eval('newWeapon("Base.Shotgun", 12, 1.5, 2.2)')
    assert test(w) is True
    for field, value in (("ammo", 2), ("chambered", True), ("spentChambered", True), ("spentCount", 1)):
        setattr(w, field, value)
        assert test(w) is False, field
        setattr(w, field, lua.eval('newWeapon("x", 1, 1, 1)')[field])
    assert test(w) is True
    w.parts["Canon"] = lua.eval('newPart("Base.ChokeTubeFull", 10)')
    assert test(w) is False
    assert test(lua.eval("{ classes = { InventoryItem = true } }")) is True  # copper, sheets, charcoal...


# ------------------------------------------------------------------ oil filter


@pytest.fixture
def oil():
    return lua_runtime("shared/SilencerMoon/Core.lua", "shared/SilencerMoon/OilFilter.lua")


def test_the_oil_filter_needs_mechanics_8_a_wrench_and_the_engine_off(oil):
    check = oil.eval("SilencerMoon.OilFilter.check")
    player, vehicle = oil.eval("newPlayer()"), oil.eval("newVehicle()")
    assert check(player, vehicle) == (True, None)
    player.mechanics = 7
    assert check(player, vehicle)[1] == "ContextMenu_SilencerMoon_NeedMechanics"
    player.mechanics = 8
    player.wrench = False
    assert check(player, vehicle)[1] == "ContextMenu_SilencerMoon_NeedWrench"
    player.wrench = True
    vehicle.running = True
    assert check(player, vehicle)[1] == "ContextMenu_SilencerMoon_EngineRunning"
    assert check(player, oil.eval("newVehicle(false)")) == (False, None)


def test_a_vehicle_gives_its_oil_filter_once(oil):
    player, vehicle = oil.eval("newPlayer()"), oil.eval("newVehicle()")
    action_class = oil.eval("ISSilencerMoonTakeOilFilter")
    action = action_class.new(action_class, player, vehicle.getPartById(vehicle, "Engine"))
    assert action.isValid(action) is True
    assert action.complete(action) is True
    items = player["items"]  # a Lua field: player.items would be lupa's own items() method
    assert [i.type for i in items.values()] == ["SilencerMoon.ScavengedOilFilter"]
    assert vehicle.transmitted == 1 and oil.eval("XP") == 5
    again = action_class.new(action_class, player, vehicle.getPartById(vehicle, "Engine"))
    assert again.isValid(again) is False
    assert again.complete(again) is False
    assert len(items) == 1


# ------------------------------------------------------------------ tooltip


def test_the_tooltip_bars():
    runtime = lua_runtime("shared/SilencerMoon/Core.lua", "client/SilencerMoon/Tooltip.lua")
    tooltip, core = runtime.eval("SilencerMoon.Tooltip"), runtime.eval("SilencerMoon.Core")
    expected = {
        "oilfilter": ([6, 8, 5], ["30%", "-40%", "-25%"]),
        "copper": ([8, 6, 4], ["40%", "-30%", "-20%"]),
        "ballistic": ([13, 4, 2.5], ["65%", "-20%", "-12,5%"]),
    }
    for tier_id, (ticks, values) in expected.items():
        rows = tooltip.rows(core.TIERS[tier_id])
        assert [tooltip.halfTicks(rows[i].share) / 2 for i in (1, 2, 3)] == ticks, tier_id
        assert [tooltip.valueText(rows[i]) for i in (1, 2, 3)] == values, tier_id


# ------------------------------------------------------------------ static checks


def lua_files():
    return sorted(LUA.rglob("*.lua"))


MISSING = re.compile(r"(?<![\w.:])(next|xpcall)\s*\(|\btable\.(pack|unpack)\b|\bos\.clock\b")


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_lua_is_plain_ascii_and_uses_only_what_the_game_has(path):
    text = path.read_text(encoding="utf-8")
    assert text.isascii(), f"{path.name}: Kahlua loses accented letters in strings; texts go in Translate/*.json"
    code = "\n".join(re.sub(r"--.*$", "", line) for line in text.split("\n"))
    assert not MISSING.search(code), f"{path.name}: the game's Lua has no {MISSING.search(code).group(0)}"


def script_text():
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(SCRIPTS.glob("*.txt")))


def blocks(kind):
    """{name: body} of every `kind name { ... }` in the scripts (one level of nesting is enough here)."""
    out = {}
    text = script_text()
    for match in re.finditer(rf"^\s*{kind} (\w+)\s*\{{", text, re.M):
        depth, i = 1, match.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        out.setdefault(match.group(1), "")
        out[match.group(1)] += text[match.end() : i - 1]
    return out


def test_every_item_model_icon_and_file_the_scripts_name_exists():
    items, models, recipes = blocks("item"), blocks("model"), blocks("craftRecipe")
    ours = {n for n in items if n in {
        "CopperSteelIngot", "BallisticAlloyIngot", "ScavengedOilFilter", "SuppressorMagazine",
    } or n.startswith("Suppressor_")}
    assert len(ours) == 9
    for name in ours:
        body = items[name]
        icon = re.search(r"Icon = (\w+)", body).group(1)
        if icon.startswith("SilencerMoon_"):
            assert (MEDIA / "textures" / f"Item_{icon}.png").exists(), icon
        for key in ("StaticModel", "WorldStaticModel"):
            model = re.search(rf"{key} = (\w+)", body).group(1)
            assert model in models or model in {"SteelIngot", "Magazine", "WeaponMag1"}, (name, model)
    for name, body in models.items():
        mesh = re.search(r"mesh = ([\w/]+)", body)
        if mesh and mesh.group(1).startswith("silencermoon/"):
            assert (MEDIA / "models_X" / f"{mesh.group(1)}.fbx").exists(), mesh.group(1)
        texture = re.search(r"texture = (\w+)", body)
        if texture:
            assert (MEDIA / "textures" / f"{texture.group(1)}.png").exists(), texture.group(1)
    for line in re.findall(r"ModelWeaponPart = (\S+) (\S+) canon canon", script_text()):
        item, model = (x.split(".", 1)[1] for x in line)
        assert item in items and model in models, line
    for body in recipes.values():
        for ref in re.findall(r"(?<!= )SilencerMoon\.(\w+)", body):  # items, not OnTest = SilencerMoon.fn
            assert ref in items, ref
    learned = re.search(r"LearnedRecipes = ([\w;]+)", items["SuppressorMagazine"]).group(1).split(";")
    assert sorted(learned) == sorted(r for r in recipes if r.startswith("SilencerMoon_Make"))
    for sound in re.findall(r"file = (media/sound/[\w/.-]+)", script_text()):
        assert (MOD / sound).exists(), sound


def test_the_lua_tiers_match_the_items():
    lua = lua_runtime("shared/SilencerMoon/Core.lua")
    core = lua.eval("SilencerMoon.Core")
    items = blocks("item")
    parts = {f"SilencerMoon.{n}" for n, b in items.items() if "PartType = Suppressor" in b}
    assert parts == set(core.PARTS.keys())
    for full, tier_id in core.PARTS.items():
        body = items[full.split(".", 1)[1]]
        assert int(re.search(r"ConditionMax = (\d+)", body).group(1)) == core.TIERS[tier_id].conditionMax
        assert "OnAttach = SilencerMoon.onAttach" in body and "OnDetach = SilencerMoon.onDetach" in body
        mount = re.search(r"MountOn = ([\w.;]+)", body).group(1).split(";")
        assert set(mount) <= set(core.CALIBER_SOUND.keys()), full
        assert TIERS[full][:3] == (core.TIERS[tier_id].radius, core.TIERS[tier_id].range, core.TIERS[tier_id].damage)


def translations(lang):
    out = {}
    for path in (LUA / "shared" / "Translate" / lang).glob("*.json"):
        out.update(json.loads(path.read_text(encoding="utf-8")))
    return out


@pytest.mark.parametrize("lang", ["IT", "EN"])
def test_every_text_has_a_translation(lang):
    texts = translations(lang)
    used = set()
    for path in lua_files():
        used |= set(re.findall(r'"((?:IGUI|ContextMenu|Tooltip)_SilencerMoon_\w+)"', path.read_text()))
    used |= {f"IGUI_SilencerMoon_Tier_{t}" for t in ("oilfilter", "copper", "ballistic")}
    used.discard("IGUI_SilencerMoon_Tier_")
    used |= set(re.findall(r"Tooltip = (\w+)", script_text()))
    used |= {f"SilencerMoon.{n}" for n in blocks("item") if n in {
        "CopperSteelIngot", "BallisticAlloyIngot", "ScavengedOilFilter", "SuppressorMagazine",
    } or n.startswith("Suppressor_")}
    used |= set(blocks("craftRecipe"))
    missing = sorted(k for k in used if k not in texts)
    assert not missing, f"{lang}: {missing}"


def test_italian_texts_avoid_glyphs_the_game_font_may_lack():
    for value in translations("IT").values():
        assert not set(value) & set("—–«»“”"), value
