"""The game, imitated for JukeboxMoon's Lua in a real Lua (lupa): only the methods the mod calls, with the game's names
(checked in the 42.21 jar); a global the mod does not define is nil here as in the game.
"""

from __future__ import annotations

from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
MOD = ROOT / "mods" / "JukeboxMoon" / "42"
LUA = MOD / "media" / "lua"

PRELUDE = r"""
-- only the game's events the mod uses (checked in 42.21): any other name is nil, and .Add on it fails as in the game
EVENTS = {}
Events = {}
for _, name in ipairs({ "OnClientCommand", "OnServerCommand", "OnTick", "EveryOneMinute", "OnGameStart",
        "OnPreDistributionMerge", "OnFillWorldObjectContextMenu", "OnFillInventoryObjectContextMenu" }) do
    local e = { list = {} }
    function e.Add(f) table.insert(e.list, f) end
    Events[name] = e
    EVENTS[name] = e
end
function fire(name, ...)
    for _, f in ipairs((EVENTS[name] or { list = {} }).list) do f(...) end
end

-- MapObjects.OnLoadWithSprite: loadSquare(sq) does what the game does when it loads a square
LOAD_HOOKS = {}
MapObjects = { OnLoadWithSprite = function(sprite, fn, priority)
    assert(type(sprite) == "string" and type(fn) == "function" and type(priority) == "number")
    LOAD_HOOKS[sprite] = LOAD_HOOKS[sprite] or {}
    table.insert(LOAD_HOOKS[sprite], fn)
end }
function loadSquare(sq)
    for _, o in ipairs(sq.objects.t) do
        if o.container then o.container.accept = nil end            -- not saved: gone after a load
        for _, fn in ipairs(LOAD_HOOKS[o.spriteName] or {}) do fn(o) end
    end
end

CLIENT, SERVER, NOW = false, false, 100000
function isClient() return CLIENT end
function isServer() return SERVER end
function getTimestampMs() return NOW end
function instanceof(o, cls) return type(o) == "table" and o.classes ~= nil and o.classes[cls] == true end
function getText(key, a, b) local s = key if a then s = s .. "|" .. tostring(a) end if b then s = s .. "|" .. tostring(b) end return s end
function print() end

SandboxVars = { JukeboxMoon = {} }
CharacterStat = { BOREDOM = "BOREDOM", STRESS = "STRESS" }
CharacterTrait = { DEAF = "DEAF", HARD_OF_HEARING = "HARD_OF_HEARING" }
Capability = { CanSetupNonPVPZone = "CanSetupNonPVPZone" }
SyncPlayerStatsPacket = { getBitMaskForStat = function(stat) return stat == "BOREDOM" and 64 or 128 end }
SYNCED = {}
function syncPlayerStats(player, mask) table.insert(SYNCED, { player = player, mask = mask }) end

-- a Java list
function jlist(t)
    local l = { t = t or {} }
    function l:size() return #self.t end
    function l:get(i) return self.t[i + 1] end
    function l:add(x) table.insert(self.t, x) end
    function l:remove(x) for i, v in ipairs(self.t) do if v == x then table.remove(self.t, i) return true end end return false end
    return l
end

-- server -> client and client -> server
TO_ALL, TO_ONE, TO_SERVER = {}, {}, {}
function triggerEvent(name, ...) fire(name, ...) end
function sendServerCommand(a, b, c, d)
    if not SERVER then return end                                  -- as in the game: nothing in single player
    if type(a) == "string" then table.insert(TO_ALL, { module = a, command = b, args = c })
    else table.insert(TO_ONE, { player = a, module = b, command = c, args = d }) end
end
function sendClientCommand(player, module, command, args)
    table.insert(TO_SERVER, { player = player, module = module, command = command, args = args })
    -- single player: the game's own server side gets it (SinglePlayerServer -> OnClientCommand)
    if not CLIENT and not SERVER then fire("OnClientCommand", module, command, player, args) end
end
ADDED = {}
function sendAddItemToContainer(container, item) table.insert(ADDED, item) end

-- files of Zomboid/Lua
FILES = {}
function getFileReader(name, create)
    local text = FILES[name]
    if text == nil then return nil end
    local lines, i = {}, 0
    if string.sub(text, -1) ~= "\n" then text = text .. "\n" end   -- BufferedReader.readLine: the last line too
    for line in string.gmatch(text, "([^\n]*)\n") do lines[#lines + 1] = line end
    return { readLine = function() i = i + 1 return lines[i] end, close = function() end }
end
function getFileWriter(name, create, append)
    local buffer = {}
    return { write = function(_, s) table.insert(buffer, s) end, close = function() FILES[name] = table.concat(buffer) end }
end

-- items and containers
NEXT_ID = 0
function newMedia(id) return { id = id, getId = function(self) return self.id end } end
function newItem(fullType, mediaId)
    NEXT_ID = NEXT_ID + 1
    local item = { fullType = fullType, id = NEXT_ID, media = mediaId and newMedia(mediaId) or nil }
    function item:getFullType() return self.fullType end
    function item:getID() return self.id end
    function item:getMediaData() return self.media end
    function item:setRecordedMediaData(m) self.media = m end
    return item
end
RECORDINGS = {}   -- the game's recorded media this imitation knows
function getZomboidRadio()
    return { getRecordedMedia = function() return { getMediaData = function(_, id) return RECORDINGS[id] end } end }
end
function newContainer(kind)
    local c = { kind = kind or "crate", capacity = 0, accept = nil, explored = false, items = jlist() }
    function c:getType() return self.kind end
    function c:setType(t) self.kind = t end
    function c:getCapacity() return self.capacity end
    function c:setCapacity(n) self.capacity = n end
    function c:getAcceptItemFunction() return self.accept end
    function c:setAcceptItemFunction(f) self.accept = f end
    function c:isExplored() return self.explored end
    function c:setExplored(b) self.explored = b end
    function c:getItems() return self.items end
    function c:AddItem(fullType) local item = newItem(fullType) self.items:add(item) return item end
    return c
end

-- the world
POWER = true
SQUARES = {}
REMOVED = {}
-- the chunk's ambient emitters (IsoChunk.hasObjectAmbientEmitter / removeObjectAmbientEmitter)
CHUNK = { ambient = {} }
function CHUNK:hasObjectAmbientEmitter(o) return self.ambient[o] == true end
function CHUNK:removeObjectAmbientEmitter(o) self.ambient[o] = nil end
function newSquare(x, y, z)
    local sq = { x = x, y = y, z = z, objects = jlist() }
    function sq:getChunk() return CHUNK end
    function sq:getObjects() return self.objects end
    function sq:transmitRemoveItemFromSquare(o) table.insert(REMOVED, o) self.objects:remove(o) return 1 end
    function sq:AddSpecialObject(o, index)
        o.square = self
        if index then table.insert(self.objects.t, index + 1, o) else self.objects:add(o) end
        CHUNK.ambient[o] = true                                     -- addToWorld: AmbientSound on the sprite
    end
    function sq:RecalcProperties() end
    function sq:RecalcAllWithNeighbours(b) end
    function sq:haveElectricity() return POWER end
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    SQUARES[x .. "," .. y .. "," .. z] = sq
    return sq
end
function newObject(sq, spriteName, customName)
    local o = { square = sq, spriteName = spriteName, custom = customName, modData = {}, transmitted = 0 }
    function o:getSprite()
        local s = { name = self.spriteName, custom = self.custom }
        function s:getName() return self.name end
        function s:getProperties() local custom = self.custom return { get = function(_, k) if k == "CustomName" then return custom end return nil end } end
        return s
    end
    function o:getContainer() return self.container end
    function o:getSquare() return self.square end
    function o:getX() return self.square.x + 0.0 end
    function o:getY() return self.square.y + 0.0 end
    function o:getZ() return self.square.z + 0.0 end
    function o:getModData() return self.modData end
    function o:transmitModData() self.transmitted = self.transmitted + 1 end
    function o:hasGridPower() return false end
    if sq then sq.objects:add(o) end
    return o
end
IsoThumpable = { new = function(cell, sq, sprite, north, tbl)
    local o = newObject(nil, sprite, "Jukebox")
    o.square = sq
    o.thumpable = true
    function o:setIsContainer(b) if b then self.container = newContainer("crate") end end
    function o:setIsDismantable(b) self.dismantable = b end
    function o:setCanBarricade(b) end
    function o:setIsThumpable(b) self.isThumpable = b end
    function o:setCanBeLockByPadlock(b) end
    function o:setBlockAllTheSquare(b) end
    function o:setMaxHealth(n) end
    function o:setHealth(n) end
    function o:transmitCompleteItemToClients() self.sent = true end
    return o
end }
CELL = { getGridSquare = function(_, x, y, z) return SQUARES[x .. "," .. y .. "," .. z] end }
function getCell() return CELL end

-- players
PLAYERS = {}
function newPlayer(name, x, y, z, admin)
    local p = { name = name, x = x, y = y, z = z or 0, dead = false, admin = admin or false, traits = {},
        stats = { BOREDOM = 50, STRESS = 0.5 }, inventory = newContainer("inventory") }
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:isDead() return self.dead end
    function p:getUsername() return self.name end
    function p:getRole() local admin = self.admin return { hasAdminPower = function() return admin end, hasCapability = function() return false end } end
    function p:hasTrait(t) return self.traits[t] == true end
    function p:getInventory() return self.inventory end
    function p:getStats()
        local st = self.stats
        return {
            get = function(_, k) return st[k] end,
            remove = function(_, k, v) st[k] = math.max(0, st[k] - v) return true end,
        }
    end
    table.insert(PLAYERS, p)
    return p
end
function getOnlinePlayers() return jlist(PLAYERS) end
function getNumActivePlayers() return #PLAYERS end
function getSpecificPlayer(i) return PLAYERS[i + 1] end
LOCAL = nil
function getPlayer() return LOCAL end

-- sounds
PLAYED, STOPPED = {}, {}
NEXT_SOUND = 0
function newEmitter()
    local e = { volumes = {} }
    function e:setPos(x, y, z) self.x, self.y, self.z = x, y, z end
    -- only playSoundImpl: playSound would also go to the other clients
    function e:playSoundImpl(name, b, obj) NEXT_SOUND = NEXT_SOUND + 1 table.insert(PLAYED, { name = name, id = NEXT_SOUND, at = NOW, emitter = self }) return NEXT_SOUND end
    function e:set3D(id, b) end
    function e:setVolume(id, v) self.volumes[id] = v end
    function e:stopSound(id) table.insert(STOPPED, id) return 0 end
    return e
end
WORLD = { getFreeEmitter = function(_, x, y, z) local e = newEmitter() e:setPos(x, y, z) return e end }
function getWorld() return WORLD end
"""


def runtime(*modules: str, server: bool = False, client: bool = False, catalog: str | None = None,
            preload: str = "") -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    paths = ";".join(f"{(LUA / side).as_posix()}/?.lua" for side in ("shared", "client", "server"))
    lua.execute(f'package.path = "{paths};" .. package.path')
    lua.execute(PRELUDE)
    lua.execute(f"SERVER = {'true' if server else 'false'}; CLIENT = {'true' if client else 'false'}")
    if preload:
        lua.execute(preload)
    if catalog is not None:
        lua.execute(catalog)
    for name in modules:
        lua.execute(f'require "{name}"')
    return lua
