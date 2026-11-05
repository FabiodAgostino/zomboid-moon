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
BROADCAST = {}
function sendServerCommand(a, b, c, d)  -- (module, command, args) to every game; (player, ...) to one
    if type(a) == "string" then table.insert(BROADCAST, { module = a, command = b, args = c }) end
end
PLAYERS_BY_ID = {}
function getPlayerByOnlineID(id) return PLAYERS_BY_ID[id] end
MODDATA = {}
ModData = {
    exists = function(k) return MODDATA[k] ~= nil end,
    get = function(k) return MODDATA[k] end,
    getOrCreate = function(k) MODDATA[k] = MODDATA[k] or {}; return MODDATA[k] end,
    transmit = function(k) end,
}
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
        primary = nil, name = "tester", mechanics = 10, wrench = true, inVehicle = nil, items = {},
        remote = false, num = 0, onlineId = 1 }
    function p:isLocalPlayer() return not self.remote end
    function p:getPlayerNum() return self.num end
    function p:getOnlineID() return self.onlineId end
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
    "SilencerMoon.Suppressor_OilFilter": (0.35, 0.60, 0.75, 5),
    "SilencerMoon.Suppressor_Pistol_Copper": (0.20, 0.70, 0.80, 10),
    "SilencerMoon.Suppressor_Rifle_Copper": (0.20, 0.70, 0.80, 10),
    "SilencerMoon.Suppressor_Pistol_Ballistic": (0.10, 0.80, 0.875, 100),
    "SilencerMoon.Suppressor_Rifle_Ballistic": (0.10, 0.80, 0.875, 100),
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
    assert lua.eval("SilencerMoon.Shot").wear(w) == (True, True)  # changed, and broke with this round
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


def test_the_best_suppressor_keeps_a_rifle_shot_under_20_tiles(lua):
    """05/11/2026, the user's test: with the old 35% a rifle with the best suppressor still drew zombies from 30
    tiles and more. The Hunting Rifle's 170 now become 17 (halved again indoors by the game)."""
    lua.execute('FRESH["Base.HuntingRifle"] = { radius = 170, swing = "HuntingRifleShoot", flash = "flash_key" }')
    w = lua.eval('newWeapon("Base.HuntingRifle", 40, 1.2, 2.0)')
    w.parts["Suppressor"] = lua.eval('newPart("SilencerMoon.Suppressor_Rifle_Ballistic", 100)')
    lua.eval("SilencerMoon.Shot").applyNoise(w)
    assert w.radius == 17


def test_a_suppressor_that_breaks_says_so_and_stays_on_the_weapon(lua):
    """05/11/2026, the user: when it breaks it must say «Silenziatore rotto», and never disappear."""
    lua.execute("HALO = {}; HaloTextHelper = { addBadText = function(p, t) table.insert(HALO, t) end }")
    lua.execute("function getText(key) return key end")
    lua.execute("RAND = function(n) return 0 end")
    on_hit = lua.eval("EVENTS.OnWeaponSwingHitPoint.list[1]")
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    part = lua.eval('newPart("SilencerMoon.Suppressor_OilFilter", 2, 5)')
    w.attach(w, part)
    player = lua.eval("newPlayer()")
    on_hit(player, w)
    assert part.condition == 1 and len(lua.eval("HALO")) == 0
    on_hit(player, w)
    assert part.condition == 0
    assert list(lua.eval("HALO").values()) == ["IGUI_SilencerMoon_Broken"]
    assert lua.eval("function(w, p) return rawequal(w.parts.Suppressor, p) end")(w, part) is True  # still on
    assert (w.range, w.low, w.high) == (f32(15), f32(0.6), f32(1.0))
    on_hit(player, w)  # broken: no longer a working suppressor, nothing more is said
    assert len(lua.eval("HALO")) == 1


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


def test_a_worn_out_suppressor_is_announced_to_every_game_once(server):
    player = server.eval("newPlayer()")
    player.onlineId = 5
    w = server.eval('newWeapon("Base.AssaultRifle", 30, 1.0, 1.6)')
    w.parts["Suppressor"] = server.eval('newPart("SilencerMoon.Suppressor_Rifle_Ballistic", 2)')
    player.primary = w
    command = server.eval("SilencerMoon.onClientCommand")
    args = server.eval(f"{{ id = {w.id} }}")
    command("SilencerMoon", "shot", player, args)
    assert len(server.eval("BROADCAST")) == 0
    command("SilencerMoon", "shot", player, args)
    command("SilencerMoon", "shot", player, args)  # worn out: no longer a working suppressor, ignored
    sent = server.eval("BROADCAST")
    assert w.parts["Suppressor"].condition == 0 and len(sent) == 1
    assert sent[1].module == "SilencerMoon" and sent[1].command == "worn"
    assert sent[1].args.player == 5 and sent[1].args.id == w.id


# ------------------------------------------------------------------ noise


@pytest.mark.parametrize(
    "part_type,radius,sound,flash",
    [
        ("SilencerMoon.Suppressor_OilFilter", 35, "M9Shoot", "flash_key"),
        ("SilencerMoon.Suppressor_Pistol_Copper", 20, "SilencerMoon_Suppressed9mm", None),
        ("SilencerMoon.Suppressor_Pistol_Ballistic", 10, "SilencerMoon_Suppressed9mm", None),
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


def test_every_supported_firearm_has_a_suppressed_sound_and_no_loop():
    sounds = set(re.findall(r"sound (SilencerMoon_Suppressed\w+)", (SCRIPTS / "SilencerMoon_sounds.txt").read_text()))
    lua = lua_runtime("shared/SilencerMoon/Core.lua")
    for weapon, calibre in lua.eval("SilencerMoon.Core.CALIBER_SOUND").items():
        assert f"SilencerMoon_Suppressed{calibre}" in sounds, weapon
    # attackHook plays <SwingSound>FullAuto as a loop when it exists: a single shot used that way skips rounds
    assert not any(s.endswith("FullAuto") for s in sounds)


def test_another_players_shot_is_suppressed_on_my_screen_too(lua):
    lua.execute('FRESH["Base.Pistol"] = { radius = 100, swing = "M9Shoot", flash = "flash_key" }')
    remote = lua.eval("newPlayer()")
    lua.execute("function remoteIsNotLocal(p) function p:isLocalPlayer() return false end end")
    lua.eval("remoteIsNotLocal")(remote)
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.parts["Suppressor"] = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Ballistic", 10)')
    lua.eval("EVENTS.OnWeaponSwing.list[1]")(remote, w)
    assert (w.radius, w.swing, w.flash) == (10, "SilencerMoon_Suppressed9mm", None)
    lua.execute("CLIENT = true")
    lua.eval("EVENTS.OnWeaponSwingHitPoint.list[1]")(remote, w)
    assert len(lua.eval("SENT")) == 0  # only the shooter's own game reports the round


def ballistic_pistol(lua):
    lua.execute('FRESH["Base.Pistol"] = { radius = 100, swing = "M9Shoot", flash = "flash_key" }')
    w = lua.eval('newWeapon("Base.Pistol", 15, 0.6, 1.0)')
    w.swing = "M9Shoot"
    w.parts["Suppressor"] = lua.eval('newPart("SilencerMoon.Suppressor_Pistol_Ballistic", 10)')
    return w


SUPPRESSED = (10, "SilencerMoon_Suppressed9mm", None)
VANILLA = (100, "M9Shoot", "flash_key")


def noise(w):
    return (w.radius, w.swing, w.flash)


def test_the_weapon_in_hand_is_ready_before_the_first_shot(lua):
    """attackHook (Hook.Attack) reads the radius and the sound before OnWeaponSwing: the values are there already."""
    player, w = lua.eval("newPlayer()"), ballistic_pistol(lua)
    player.primary = w
    update = lua.eval("EVENTS.OnPlayerUpdate.list[1]")
    update(player)
    assert noise(w) == SUPPRESSED
    w.radius = 77  # nothing changed in hand: nothing is set again
    update(player)
    assert w.radius == 77
    w.radius = 10
    w.parts["Suppressor"].condition = 0  # worn out: the game's values before the next trigger pull
    update(player)
    assert noise(w) == VANILLA
    fresh = ballistic_pistol(lua)  # a new copy (logged in again, another weapon): set at once
    player.primary = fresh
    update(player)
    assert noise(fresh) == SUPPRESSED
    fresh.parts["Suppressor"] = None  # taken off
    update(player)
    assert noise(fresh) == VANILLA
    player.primary = None
    update(player)


def test_another_players_weapon_is_set_when_it_comes_into_their_hands(lua):
    """Their weapon arrives whole with each EquipPacket: the flash on my screen is drawn from that copy."""
    remote, w = lua.eval("newPlayer()"), ballistic_pistol(lua)
    remote.remote = True
    lua.eval("EVENTS.OnEquipPrimary.list[1]")(remote, w)
    assert noise(w) == SUPPRESSED
    lua.eval("EVENTS.OnEquipPrimary.list[1]")(remote, None)  # empty hands


def test_the_others_learn_that_a_suppressor_wore_out(lua):
    remote, w = lua.eval("newPlayer()"), ballistic_pistol(lua)
    remote.remote, remote.onlineId, remote.primary = True, 7, w
    lua.globals().PLAYERS_BY_ID[7] = remote
    lua.eval("EVENTS.OnEquipPrimary.list[1]")(remote, w)
    on_server = lua.eval("EVENTS.OnServerCommand.list[1]")
    on_server("SilencerMoon", "worn", lua.eval(f"{{ player = 7, id = {w.id + 1} }}"))  # another weapon
    on_server("Other", "worn", lua.eval(f"{{ player = 7, id = {w.id} }}"))
    on_server("SilencerMoon", "worn", lua.eval(f"{{ player = 8, id = {w.id} }}"))  # nobody
    assert noise(w) == SUPPRESSED
    on_server("SilencerMoon", "worn", lua.eval(f"{{ player = 7, id = {w.id} }}"))
    assert w.parts["Suppressor"].condition == 0 and noise(w) == VANILLA
    mine = ballistic_pistol(lua)  # my own copy comes from the server with syncHandWeaponFields, not from here
    me = lua.eval("newPlayer()")
    me.onlineId, me.primary = 9, mine
    lua.globals().PLAYERS_BY_ID[9] = me
    on_server("SilencerMoon", "worn", lua.eval(f"{{ player = 9, id = {mine.id} }}"))
    assert mine.parts["Suppressor"].condition == 10


def test_the_dedicated_server_does_not_watch_the_noise():
    lua = lua_runtime()
    lua.execute("SERVER = true")
    for name in ("shared/SilencerMoon/Core.lua", "shared/SilencerMoon/Stats.lua", "shared/SilencerMoon/Shot.lua"):
        lua.execute((LUA / name).read_text(encoding="utf-8"))
    assert lua.eval("EVENTS.OnWeaponSwingHitPoint") is not None
    for name in ("OnPlayerUpdate", "OnEquipPrimary", "OnWeaponSwing", "OnServerCommand"):
        assert lua.eval(f"EVENTS.{name}") is None, name


def test_a_failing_handler_keeps_working_and_writes_the_error_once(lua):
    lua.execute("""
        PRINTED = {}
        print = function(s) table.insert(PRINTED, s) end
        CALLS = 0
        function flaky(fail) CALLS = CALLS + 1; if fail then error("boom") end return "ok" end
    """)
    handler = lua.eval("SilencerMoon.Shot.guarded")("test", lua.eval("flaky"))
    handler(True)
    handler(True)
    assert handler(False) == "ok"  # no pause after an error: the next square or shot is never skipped
    assert lua.eval("CALLS") == 3 and len(lua.eval("PRINTED")) == 1


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
        "oilfilter": ([13, 8, 5], ["65%", "-40%", "-25%"]),
        "copper": ([16, 6, 4], ["80%", "-30%", "-20%"]),
        "ballistic": ([18, 4, 2.5], ["90%", "-20%", "-12,5%"]),
    }
    for tier_id, (ticks, values) in expected.items():
        rows = tooltip.rows(core.TIERS[tier_id])
        assert [tooltip.halfTicks(rows[i].share) / 2 for i in (1, 2, 3)] == ticks, tier_id
        assert [tooltip.valueText(rows[i]) for i in (1, 2, 3)] == values, tier_id


def test_the_tooltip_block_goes_under_or_over_and_never_moves_the_games():
    runtime = lua_runtime("shared/SilencerMoon/Core.lua", "client/SilencerMoon/Tooltip.lua")
    place = runtime.eval("SilencerMoon.Tooltip.place")
    assert place(100, 100, 200, 300, 80, 1920, 1080) == (0, 200)  # under the game's
    assert place(100, 900, 150, 300, 80, 1920, 1080) == (0, -80)  # the screen ends first: over it
    assert place(100, 20, 1040, 300, 80, 1920, 1080) == (0, 1040)  # no room either way: under
    assert place(1800, 100, 200, 300, 80, 1920, 1080) == (-180, 200)  # the right edge
    text = (LUA / "client" / "SilencerMoon" / "Tooltip.lua").read_text()
    for call in ("setX(", "setY(", "setWidth(", "setHeight("):  # the game placed and drew its own already
        assert call not in text, call


# ------------------------------------------------------------------ static checks


def lua_files():
    return sorted(LUA.rglob("*.lua"))


MISSING = re.compile(r"(?<![\w.:])(next|xpcall)\s*\(|\btable\.(pack|unpack)\b|\bos\.clock\b")


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_lua_is_plain_ascii_and_uses_only_what_the_game_has(path):
    text = path.read_text(encoding="utf-8")
    if path.name == "ZomBotMenu.lua":
        # byte for byte the copy of ZomBOT (Moon): its comments keep the accents (the game skips them), its code not
        code = [line.split("--", 1)[0] for line in text.splitlines()]
        assert all(part.isascii() for part in code), "ZomBotMenu.lua: accented letters outside the comments"
    else:
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
    for line in re.findall(r"ModelWeaponPart = (\S+) (\S+) canon muzzle", script_text()):
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
    for prefix in ("IGUI_SilencerMoon_Tier_", "IGUI_SilencerMoon_TierName_"):  # built in Lua from the tier's id
        used |= {f"{prefix}{t}" for t in ("oilfilter", "copper", "ballistic")}
        used.discard(prefix)
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


def test_the_shared_zombot_menu_is_the_same_file_as_in_zombot_moon():
    """The one «ZomBOT» entry: the same file, byte for byte, in every Moon mod (its header says so)."""
    ours = LUA / "client" / "ZomBotMenu.lua"
    theirs = ROOT / "mods" / "ZomBOTMoon" / "42" / "media" / "lua" / "client" / "ZomBotMenu.lua"
    assert ours.read_bytes() == theirs.read_bytes()


def test_a_worn_out_suppressor_shows_no_bars():
    text = (LUA / "client" / "SilencerMoon" / "Tooltip.lua").read_text()
    assert "local rows = worn and {} or Tooltip.rows(tier)" in text


# ------------------------------------------------------------------ weapon models (no model of the game is written)

# The "muzzle" point of the model of each supported firearm, from 42.21 media/scripts/generated/models_weapons.txt,
# and the model of each item (its WeaponSprite). Checked against the installed game when it is there.
VANILLA_MUZZLE = {
    "Handgun": ((0.0, 0.1466, -0.0236), (-90.0, 0.0, 0.0)),
    "Handgun02": ((0.0, 0.1432, -0.0225), (-90.0, 0.0, 0.0)),
    "Handgun03": ((0.0, 0.1443, -0.0279), (-90.0, 0.0, 0.0)),
    "Trapper_Carbine": ((0.0, 0.353, 0.021), (-90.0, 0.0, -180.0)),
    "L92_Carbine": ((0.0, 0.3866, 0.0263), (-90.0, 0.0, -180.0)),
    "L94_Rifle": ((0.0, 0.3866, 0.0263), (-90.0, 0.0, -180.0)),
    "AssaultRifle": ((0.0, 0.3993, 0.0237), (-90.0, 0.0, -180.0)),
    "VarmintRifle": ((0.0, 0.5065, 0.0331), (-90.0, 0.0, 180.0)),
    "M14": ((0.0, 0.5004, 0.0297), (-90.0, 0.0, -180.0)),
    "HuntingRifle": ((0.0, 0.4968, 0.0308), (-90.0, 0.0, 180.0)),
    "MSR7T_Rifle": ((0.0, 0.4968, 0.0308), (-90.0, 0.0, 180.0)),
    "JS14_Rifle": ((0.0, 0.3822, 0.0321), (-90.0, 0.0, -180.0)),
}
WEAPON_MODEL = {
    "Pistol": "Handgun03", "Pistol2": "Handgun02", "Pistol3": "Handgun", "TrapperCarbine": "Trapper_Carbine",
    "L92_Carbine": "L92_Carbine", "AssaultRifle": "AssaultRifle", "VarmintRifle": "VarmintRifle",
    "JS14_Rifle": "JS14_Rifle", "AssaultRifle2": "M14", "HuntingRifle": "HuntingRifle",
    "MSR7T_Rifle": "MSR7T_Rifle", "L94_Rifle": "L94_Rifle",
}
GAME_SCRIPTS = Path(r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\scripts")


def _mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def _attachment(offset, rotate, scale=1.0):
    """ModelInstanceRenderData.makeAttachmentTransform: translation(offset).rotateXYZ(rotate, degrees).scale(scale)."""
    import math

    m = [[1, 0, 0, offset[0]], [0, 1, 0, offset[1]], [0, 0, 1, offset[2]], [0, 0, 0, 1]]
    for axis, deg in zip("xyz", rotate):
        c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
        r = {
            "x": [[1, 0, 0, 0], [0, c, -s, 0], [0, s, c, 0], [0, 0, 0, 1]],
            "y": [[c, 0, s, 0], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]],
            "z": [[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
        }[axis]
        m = _mul(m, r)
    return _mul(m, [[scale, 0, 0, 0], [0, scale, 0, 0], [0, 0, scale, 0], [0, 0, 0, 1]])


def _numbers(text):
    return tuple(float(x) for x in text.split())


def _attachments(body):
    out = {}
    for name, inner in re.findall(r"attachment (\w+)\s*\{([^}]*)\}", body):
        out[name] = dict((k, v.strip()) for k, v in re.findall(r"(\w+) = ([^,]+),", inner))
    return out


def test_no_model_of_the_game_is_written():
    """A second body of a model resets it (mesh, texture, scale) before loading: the guns would lose their mesh."""
    for path in sorted(SCRIPTS.glob("*.txt")):
        text = path.read_text(encoding="utf-8")
        module = re.search(r"^module (\w+)", text, re.M).group(1)
        models = re.findall(r"^\s*model (\w+)\s*\{", text, re.M)
        assert module == "SilencerMoon" or not models, (path.name, models)
        assert not set(models) & set(VANILLA_MUZZLE), path.name


def test_each_part_sits_on_the_muzzle_where_simple_suppressors_put_it():
    """parent point x part point (the game never inverts the part's) = the muzzle offset, unturned, part's scale."""
    models, items = blocks("model"), blocks("item")
    seen = 0
    for item, model in WEAPON_MODEL.items():
        offset, rotate = VANILLA_MUZZLE[model]
        lines = re.findall(r"ModelWeaponPart = (\S+) (\S+) (\S+) (\S+),", items[item])
        assert len(lines) == 3, item
        for _part, part_model, self_point, parent_point in lines:
            assert (self_point, parent_point) == ("canon", "muzzle"), (item, part_model)
            canon = _attachments(models[part_model.split(".", 1)[1]])["canon"]
            assert set(canon) <= {"offset", "rotate", "scale"}, canon
            scale = float(canon.get("scale", 1))
            part = _attachment(_numbers(canon["offset"]), _numbers(canon["rotate"]), scale)
            got = _mul(_attachment(offset, rotate), part)
            want = _mul(_attachment(offset, (0, 0, 0)), _attachment((0, 0, 0), (0, 0, 0), scale))
            assert all(abs(got[i][j] - want[i][j]) < 1e-9 for i in range(4) for j in range(4)), (item, part_model)
            seen += 1
    assert seen == 36


def test_attachments_use_only_keys_the_game_reads():
    """ModelScript.LoadAttachment reads bone, offset, rotate and scale (a zoffset there was ignored)."""
    for body in blocks("model").values():
        for name, keys in _attachments(body).items():
            assert set(keys) <= {"bone", "offset", "rotate", "scale"}, (name, keys)


@pytest.mark.skipif(not GAME_SCRIPTS.exists(), reason="the game is not installed here")
def test_the_muzzles_are_those_of_the_installed_game():
    text = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in GAME_SCRIPTS.rglob("*.txt"))
    for model, (offset, rotate) in VANILLA_MUZZLE.items():
        start = re.search(rf"\bmodel\s+{model}\s*\{{", text)
        assert start, model
        body = text[start.end() : text.index("\n    }", start.end())]
        muzzle = _attachments(body)["muzzle"]
        assert _numbers(muzzle["offset"]) == offset and _numbers(muzzle["rotate"]) == rotate, model
    for item, model in WEAPON_MODEL.items():
        body = re.search(rf"\bitem\s+{item}\s*\{{(.*?)\n\s*\}}", text, re.S).group(1)
        assert re.search(r"WeaponSprite\s*=\s*([^,\s]+)", body).group(1) == model, item
