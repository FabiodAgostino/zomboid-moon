"""SilencerMoon: the restore before the mod leaves the server (shared/SilencerMoon/Restore.lua and
server/SilencerMoon/RestoreServer.lua), run in a real Lua with imitations of containers, vehicles, squares and the
world's mod data. Same runner as test_silencermoon.py."""

import pytest

from test_silencermoon import f32, lua_runtime, script_text

RESTORE_PRELUDE = r"""
MODDATA, TRANSMITTED = {}, 0
ModData = {
    exists = function(k) return MODDATA[k] ~= nil end,
    get = function(k) return MODDATA[k] end,
    getOrCreate = function(k) MODDATA[k] = MODDATA[k] or {}; return MODDATA[k] end,
    add = function(k, t) MODDATA[k] = t end,
    transmit = function(k) TRANSMITTED = TRANSMITTED + 1 end,
    request = function(k) end,
}
SCREWDRIVER = true
ItemCodeOnTest = { hasScrewdriver = function(c, w, p) return SCREWDRIVER end }
Capability = { CanSetupNonPVPZone = "CanSetupNonPVPZone" }
SERVERCMDS = {}
function sendServerCommand(player, module, command, args)
    table.insert(SERVERCMDS, { player = player, command = command, args = args })
end

function javaList(t)
    local l = {}
    function l:size() return #t end
    function l:get(i) return t[i + 1] end
    return l
end

function newContainer()
    local c = { items = {} }
    function c:AddItem(item) table.insert(self.items, item); item.container = self; return item end
    function c:getAllEvalRecurse(pred)
        local out = {}
        local function walk(cont)
            for _, it in ipairs(cont.items) do
                if pred(it) then table.insert(out, it) end
                if it.inner then walk(it.inner) end
            end
        end
        walk(self)
        return javaList(out)
    end
    return c
end

function newBag()
    local bag = { classes = { InventoryContainer = true, InventoryItem = true }, inner = newContainer() }
    function bag:getInventory() return self.inner end
    return bag
end

function newAdmin(admin)
    local p = newPlayer()
    local inventory = newContainer()
    function p:getInventory() return inventory end
    function p:getRole()
        return { hasAdminPower = function(self) return admin end, hasCapability = function(self, c) return false end }
    end
    return p
end

ONLINE, VEHICLES = {}, {}
function getOnlinePlayers() return javaList(ONLINE) end
function getNumActivePlayers() return #ONLINE end
function getSpecificPlayer(i) return ONLINE[i + 1] end
function getCell()
    local cell = {}
    function cell:getVehicles()
        local set = {}
        function set:iterator()
            local i = 0
            local it = {}
            function it:hasNext() return i < #VEHICLES end
            function it:next() i = i + 1; return VEHICLES[i] end
            return it
        end
        return set
    end
    return cell
end

function newVehicleWith(container)
    local v = {}
    function v:getPartCount() return 2 end
    function v:getPartByIndex(i)
        local part = {}
        function part:getItemContainer() if i == 1 then return container end return nil end
        return part
    end
    return v
end

function newSquare()
    local sq = { objects = {}, ground = {}, bodies = {}, dropped = {} }
    function sq:getObjects() return javaList(self.objects) end
    function sq:getWorldObjects() return javaList(self.ground) end
    function sq:getDeadBodys() return javaList(self.bodies) end
    function sq:AddWorldInventoryItem(item, x, y, z) table.insert(self.dropped, item); return item end
    function sq:putContainer(container)
        local o = {}
        function o:getContainerCount() return 1 end
        function o:getContainerByIndex(i) return container end
        table.insert(self.objects, o)
        local plain = {}
        function plain:getContainerCount() return 0 end
        table.insert(self.objects, plain)
    end
    function sq:putOnGround(item)
        local w = { item = item, square = self }
        function w:getItem() return self.item end
        function w:getSquare() return self.square end
        item.world = w
        table.insert(self.ground, w)
    end
    function sq:putBody(container)
        local b = {}
        function b:getContainer() return container end
        table.insert(self.bodies, b)
    end
    return sq
end

-- a suppressed weapon (the server has already applied its values) put in a container, or nowhere
function suppressedIn(container, partType)
    local w = newWeapon("Base.HuntingRifle", 40, 1.2, 2.0)
    local part = newPart(partType or "SilencerMoon.Suppressor_Rifle_Ballistic", 10)
    w:attach(part)
    if container then container:AddItem(w) end
    return w, part
end
"""

ORIGINAL = (f32(40), f32(1.2), f32(2.0))


def restore_runtime(server=True):
    lua = lua_runtime(
        "shared/SilencerMoon/Core.lua",
        "shared/SilencerMoon/Stats.lua",
        "shared/SilencerMoon/Shot.lua",
        "shared/SilencerMoon/Restore.lua",
        "server/SilencerMoon/RestoreServer.lua",
    )
    lua.execute(RESTORE_PRELUDE)
    if server:
        lua.execute("SERVER = true")
    return lua


def values(weapon):
    return (weapon.range, weapon.low, weapon.high)


def same(lua, a, b):
    """The same Lua table (two Python wrappers of it are not ==)."""
    return lua.eval("function(a, b) return rawequal(a, b) end")(a, b) is True


def test_no_suppressor_can_be_attached_while_the_restore_is_on():
    lua = restore_runtime()
    can = lua.eval("SilencerMoon.canAttach")
    assert can(None, None, None) is True
    lua.execute("SCREWDRIVER = false")
    assert can(None, None, None) is False
    lua.execute("SCREWDRIVER = true; ModData.getOrCreate('SilencerMoon').restoring = true")
    assert can(None, None, None) is False
    assert "CanAttach = SilencerMoon.canAttach" in script_text()
    assert "CanAttach = ItemCodeOnTest" not in script_text()


def test_turning_it_on_fixes_the_weapons_of_the_players_online_at_once():
    lua = restore_runtime()
    admin = lua.eval("newAdmin(true)")
    lua.globals().ONLINE[1] = admin
    inventory = admin.getInventory(admin)
    weapon, part = lua.eval("suppressedIn")(inventory)
    bag = lua.eval("newBag()")
    inventory.AddItem(inventory, bag)
    nested, nested_part = lua.eval("suppressedIn")(bag.inner, "SilencerMoon.Suppressor_Rifle_Copper")
    assert weapon.range == pytest.approx(32, rel=1e-6)

    lua.eval("SilencerMoon.onRestoreCommand")(admin, "restoreStart")

    for w, p, where in ((weapon, part, inventory), (nested, nested_part, bag.inner)):
        assert w.parts["Suppressor"] is None
        assert values(w) == ORIGINAL
        assert w.modData.SilencerMoon is None
        assert same(lua, p.container, where)  # the suppressor stays next to its weapon
    assert lua.eval("MODDATA.SilencerMoon.restoring") is True
    assert lua.eval("MODDATA.SilencerMoon.fixed") == 2
    assert lua.eval("SYNCED") == 2 and lua.eval("TRANSMITTED") == 1
    reply = lua.eval("SERVERCMDS[1]")
    assert reply.command == "restoreState" and reply.args.active is True and reply.args.fixedNow == 2
    assert lua.eval("SilencerMoon.Restore.players")() == 0  # done: a second round finds nothing


def test_only_an_admin_can_turn_it_on():
    lua = restore_runtime()
    player = lua.eval("newAdmin(false)")
    lua.globals().ONLINE[1] = player
    weapon, _ = lua.eval("suppressedIn")(player.getInventory(player))
    lua.eval("SilencerMoon.onRestoreCommand")(player, "restoreStart")
    assert lua.eval("MODDATA.SilencerMoon") is None
    assert weapon.parts["Suppressor"] is not None
    assert lua.eval("SERVERCMDS[1]").args.refused is True


def test_single_player_needs_no_role():
    lua = restore_runtime(server=False)
    assert lua.eval("SilencerMoon.Restore.isAdmin")(lua.eval("newPlayer()")) is True


def test_vehicles_and_loading_squares_are_fixed_while_it_is_on():
    lua = restore_runtime()
    trunk = lua.eval("newContainer()")
    in_trunk, _ = lua.eval("suppressedIn")(trunk)
    lua.globals().VEHICLES[1] = lua.eval("newVehicleWith")(trunk)

    square = lua.eval("newSquare()")
    crate = lua.eval("newContainer()")
    in_crate, _ = lua.eval("suppressedIn")(crate)
    square.putContainer(square, crate)
    on_ground, ground_part = lua.eval("suppressedIn")(None)
    square.putOnGround(square, on_ground)
    bag = lua.eval("newBag()")
    in_bag, _ = lua.eval("suppressedIn")(bag.inner)
    square.putOnGround(square, bag)
    corpse = lua.eval("newContainer()")
    on_corpse, _ = lua.eval("suppressedIn")(corpse)
    square.putBody(square, corpse)

    load = lua.eval("EVENTS.LoadGridsquare.list[1]")
    load(square)  # off: nothing happens
    assert in_crate.parts["Suppressor"] is not None

    lua.eval("SilencerMoon.onRestoreCommand")(lua.eval("newAdmin(true)"), "restoreStart")
    assert in_trunk.parts["Suppressor"] is None  # the loaded vehicles at once
    load(square)
    for w in (in_crate, on_ground, in_bag, on_corpse):
        assert w.parts["Suppressor"] is None
        assert values(w) == ORIGINAL
    dropped = list(square.dropped.values())
    assert len(dropped) == 1 and same(lua, dropped[0], ground_part)  # the one on the ground lies next to it
    assert lua.eval("MODDATA.SilencerMoon.fixed") == 5


def test_whoever_logs_in_later_is_fixed_within_ten_minutes():
    lua = restore_runtime()
    lua.eval("SilencerMoon.onRestoreCommand")(lua.eval("newAdmin(true)"), "restoreStart")
    late = lua.eval("newAdmin(false)")
    weapon, _ = lua.eval("suppressedIn")(late.getInventory(late))
    lua.globals().ONLINE[1] = late
    lua.eval("EVENTS.EveryTenMinutes.list[1]")()
    assert weapon.parts["Suppressor"] is None
    assert values(weapon) == ORIGINAL


def test_the_switch_is_read_again_after_a_restart():
    lua = restore_runtime()
    lua.execute("ModData.getOrCreate('SilencerMoon').restoring = true")  # saved in the world, read at start
    square = lua.eval("newSquare()")
    crate = lua.eval("newContainer()")
    in_crate, _ = lua.eval("suppressedIn")(crate)
    square.putContainer(square, crate)
    lua.eval("EVENTS.LoadGridsquare.list[1]")(square)
    assert in_crate.parts["Suppressor"] is None


def test_turning_it_off_stops_everything():
    lua = restore_runtime()
    admin = lua.eval("newAdmin(true)")
    command = lua.eval("SilencerMoon.onRestoreCommand")
    command(admin, "restoreStart")
    command(admin, "restoreStop")
    assert lua.eval("MODDATA.SilencerMoon.restoring") is False
    assert lua.eval("SERVERCMDS[2]").args.active is False
    lua.globals().ONLINE[1] = admin
    weapon, _ = lua.eval("suppressedIn")(admin.getInventory(admin))
    lua.eval("EVENTS.EveryTenMinutes.list[1]")()
    square = lua.eval("newSquare()")
    crate = lua.eval("newContainer()")
    in_crate, _ = lua.eval("suppressedIn")(crate)
    square.putContainer(square, crate)
    lua.eval("EVENTS.LoadGridsquare.list[1]")(square)
    assert weapon.parts["Suppressor"] is not None and in_crate.parts["Suppressor"] is not None
    assert lua.eval("SilencerMoon.canAttach")(None, None, None) is True


def test_a_weapon_left_with_our_values_but_no_suppressor_is_fixed_too():
    lua = restore_runtime()
    weapon, _ = lua.eval("suppressedIn")(None)
    weapon.parts["Suppressor"] = None  # taken off by something that skipped OnDetach
    assert lua.eval("SilencerMoon.Restore.weapon")(weapon, None) is True
    assert values(weapon) == ORIGINAL


def test_the_client_never_fixes_anything():
    lua = restore_runtime(server=False)
    lua.execute("CLIENT = true")
    weapon, _ = lua.eval("suppressedIn")(None)
    assert lua.eval("SilencerMoon.Restore.weapon")(weapon, None) is False
    assert weapon.parts["Suppressor"] is not None
