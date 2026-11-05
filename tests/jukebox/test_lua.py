"""JukeboxMoon: the mod's Lua run in a real Lua (lupa), plus static checks of files and translations.

Run from the repository root with a Python that has pytest, lupa and Pillow (for example ZomBOT's .venv):

    python -m pytest -q tests/jukebox
"""

from __future__ import annotations

import json
import re
import sys

import pytest

pytest.importorskip("lupa")

from gamefake import LUA, MOD, ROOT, runtime  # noqa: E402

sys.path.insert(0, str(ROOT))
from tools.jukebox import generate  # noqa: E402
from tools.jukebox.generate import AlbumOut, TrackOut  # noqa: E402

KEY = "ab" * 32
GAME_MEDIA = "89108e07-fc70-4eec-a267-790d6f4b9831"
KEY_ID = "0123456789abcdef"


def catalog() -> str:
    albums = [
        AlbumOut(key=1, id="estate", title="Estate è qui", artist="Vari", year=1993, loot=1.0, archived=False,
                 tracks=[TrackOut(1, "a", 1, "Primo", "A", 25000, 3), TrackOut(2, "b", 2, "Secondo", "", 12000, 2),
                         TrackOut(3, "c", 3, "Terzo", "C", 8000, 1)], cover=None),
        AlbumOut(key=2, id="due", title="Due", artist="", year=None, loot=3.0, archived=False,
                 tracks=[TrackOut(4, "d", 1, "Quarto", "D", 30000, 3)], cover=None),
        AlbumOut(key=3, id="vecchio", title="Vecchio", artist="", year=None, loot=2.0, archived=True,
                 tracks=[TrackOut(5, "e", 1, "Quinto", "", 15000, 2)], cover=None),
        AlbumOut(key=4, id="cd-89108e07", title="Your Smile. Your Kiss.", artist="Every Reason", year=1993, loot=0.0,
                 archived=False, tracks=[TrackOut(6, "s-1", 1, "I don't know", "", 20000, 2)], cover=None,
                 media=GAME_MEDIA),
    ]
    return generate.catalog_lua("v1test", albums)


WORLD = r"""
SQ = newSquare(10, 20, 0)
VANILLA = newObject(SQ, "recreational_01_1", "Jukebox")
newObject(SQ, "floors_01_1", nil)
P = newPlayer("anna", 11.5, 20.5, 0)
function cmd(command, args, player) fire("OnClientCommand", "JukeboxMoon", command, player or P, args) end
function at() return { x = 10, y = 20, z = 0 } end
function jukebox() local o = SQ.objects.t for i = 1, #o do if o[i].container then return o[i] end end end
function lastAll() return TO_ALL[#TO_ALL] end
function lastOne() return TO_ONE[#TO_ONE] end
function put(fullType) return jukebox().container:AddItem(fullType) end
function tick(ms) NOW = NOW + ms fire("OnTick") end
"""


def server(**kw):
    lua = runtime("JukeboxMoon/Server", "JukeboxMoon/Accept", server=True, catalog=kw.pop("catalog", catalog()), **kw)
    lua.execute(WORLD)
    return lua


def opened(lua):
    lua.execute("cmd('open', at())")
    return lua


# ------------------------------------------------------------------------------------------------ the jukebox


def test_opening_converts_the_tile_once_on_the_server():
    lua = server()
    lua.execute("cmd('open', at())")
    assert lua.eval("REMOVED[1] == VANILLA")
    box = lua.eval("jukebox()")
    assert box.container.kind == "jukeboxmoon"
    assert box.container.accept == "AcceptItemFunction.JukeboxMoon"
    assert box.container.explored is True and box.container.capacity == 50
    assert box.isThumpable is False and box.dismantable is False and box.sent is True
    assert lua.eval("SQ.objects.t[1] == jukebox()")      # in the old one's place
    assert lua.eval("lastOne().command") == "opened"
    lua.execute("cmd('open', at())")
    assert lua.eval("#REMOVED") == 1                      # already converted: nothing again


def test_too_far_or_another_floor_is_refused():
    lua = server()
    lua.execute("P.x = 16; cmd('open', at())")
    assert lua.eval("#REMOVED") == 0 and lua.eval("lastOne().args.what") == "far"
    lua.execute("P.x = 11.5; P.z = 1; cmd('open', at())")
    assert lua.eval("#REMOVED") == 0
    lua.execute("P.z = 0; P.dead = true; cmd('open', at())")
    assert lua.eval("#REMOVED") == 0


def test_only_catalogue_cds_get_in_up_to_the_limit():
    lua = opened(server())
    lua.execute("""
        C = jukebox().container
        accept = function(item) return AcceptItemFunction.JukeboxMoon(C, item) end
    """)
    assert lua.eval("accept(newItem('JukeboxMoon.CD_1'))") is True
    assert lua.eval("accept(newItem('Base.Disc_Retail'))") is False
    assert lua.eval("accept(newItem('JukeboxMoon.CD_99'))") is False
    lua.execute("SandboxVars.JukeboxMoon.MaxCDsPerJukebox = 2; put('JukeboxMoon.CD_1'); put('JukeboxMoon.CD_2')")
    assert lua.eval("accept(newItem('JukeboxMoon.CD_1'))") is False


def test_the_games_cds_get_in_only_when_the_catalogue_has_their_recording():
    lua = opened(server())
    lua.execute('C = jukebox().container; accept = function(item) return AcceptItemFunction.JukeboxMoon(C, item) end')
    assert lua.eval(f'accept(newItem("Base.Disc_Retail", "{GAME_MEDIA}"))') is True
    assert lua.eval('accept(newItem("Base.Disc_Retail", "00000000-0000-0000-0000-000000000000"))') is False
    assert lua.eval('accept(newItem("Base.Disc_Retail", nil))') is False


def test_a_game_cd_plays_its_album():
    lua = opened(server())
    lua.execute(f'D = newItem("Base.Disc_Retail", "{GAME_MEDIA}"); jukebox().container.items:add(D); put("JukeboxMoon.CD_2")')
    lua.execute("cmd('play', at())")
    state = lua.eval("lastAll().args")
    assert state.track == 6 and state.cd == lua.eval("D.id") and state.count == 2 and state.ends == 101200 + 20000


def test_admins_make_the_games_cds_with_their_recording():
    lua = server()
    lua.execute('P.admin = true; cmd("spawn", { album = 4, count = 2 })')
    assert lua.eval("lastOne().args.what") == "noalbum"            # the game does not know the recording here
    lua.execute(f'RECORDINGS["{GAME_MEDIA}"] = newMedia("{GAME_MEDIA}"); NOW = NOW + 5000; cmd("spawn", {{ album = 4, count = 2 }})')
    assert lua.eval("P.inventory.items:size()") == 2
    item = lua.eval("P.inventory.items:get(0)")
    assert item.fullType == "Base.Disc_Retail" and item.media.id == GAME_MEDIA


def test_the_game_wiping_accept_functions_does_not_lose_ours():
    lua = server()
    lua.execute("AcceptItemFunction = {}")                 # what the game's AcceptItemFunction.lua does
    lua.execute('package.loaded["JukeboxMoon/Accept"] = nil; require "JukeboxMoon/Accept"')
    assert lua.eval("type(AcceptItemFunction.JukeboxMoon)") == "function"


@pytest.mark.parametrize("side", ["server", "client"])
def test_a_jukebox_loaded_again_gets_its_cd_only_rule_back(side):
    # the accept function is not saved: after a restart, or when the square is loaded again, the server would let
    # anything in, and the loot window would not filter
    lua = runtime("JukeboxMoon/Box", catalog=catalog(), **{side: True})
    lua.execute(WORLD + """
        local o = IsoThumpable.new(nil, SQ, "recreational_01_1", false, {})
        o:setIsContainer(true); o.container:setType("jukeboxmoon"); SQ:AddSpecialObject(o)
        loadSquare(SQ)
    """)
    assert lua.eval("jukebox().container:getAcceptItemFunction()") == "AcceptItemFunction.JukeboxMoon"
    assert lua.eval("AcceptItemFunction.JukeboxMoon(jukebox().container, newItem('Base.Axe'))") is False
    assert lua.eval("VANILLA.container") is None                    # the game's own tile is left alone


# ------------------------------------------------------------------------------------------------ playing


def test_play_starts_after_the_lead_and_the_server_moves_on_by_itself():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', at())")
    state = lua.eval("lastAll().args")
    assert state.on is True and state.track == 1 and state.start == 100000 + 1200 and state.ends == 101200 + 25000
    assert state.key == "10,20,0" and state.count == 3
    lua.execute("tick(26200)")
    assert lua.eval("lastAll().args.track") == 2
    lua.execute("tick(13300)")
    assert lua.eval("lastAll().args.track") == 3
    lua.execute("tick(9300)")
    assert lua.eval("lastAll().args.track") == 1               # end of the list: back to the start


def test_opening_the_window_never_plays_and_play_twice_does_not_restart():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1')")
    assert lua.eval("#TO_ALL") == 0
    lua.execute("cmd('play', at())")
    seq = lua.eval("lastAll().args.seq")
    lua.execute("NOW = NOW + 5000; cmd('play', at())")
    assert lua.eval("lastAll().args.seq") == seq


def test_a_chosen_track_next_prev_and_stop():
    lua = opened(server())
    lua.execute("CD = put('JukeboxMoon.CD_1'); cmd('play', { x = 10, y = 20, z = 0, cd = CD.id, track = 3 })")
    assert lua.eval("lastAll().args.track") == 3
    lua.execute("NOW = NOW + 500; cmd('next', at())")
    assert lua.eval("lastAll().args.track") == 1
    lua.execute("NOW = NOW + 500; cmd('prev', at())")
    assert lua.eval("lastAll().args.track") == 3
    lua.execute("NOW = NOW + 500; cmd('stop', at())")
    assert lua.eval("lastAll().args.on") is False and lua.eval("lastAll().args.reason") == "off"
    assert lua.eval("JukeboxMoon.Server.count") == 0
    lua.execute("tick(60000)")
    assert lua.eval("lastAll().args.on") is False


def test_a_track_from_a_cd_the_client_made_up_is_ignored():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', { x = 10, y = 20, z = 0, cd = 999, track = 4 })")
    assert lua.eval("lastAll().args.track") == 1                 # not in the jukebox: from the start


def test_losing_power_stops_and_coming_back_does_not_resume():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', at()); POWER = false; tick(1000)")
    assert lua.eval("lastAll().args.on") is False and lua.eval("lastAll().args.reason") == "nopower"
    lua.execute("POWER = true; tick(60000)")
    assert lua.eval("lastAll().args.on") is False
    lua.execute("POWER = false; NOW = NOW + 5000; cmd('play', at())")
    assert lua.eval("lastOne().args.what") == "nopower"


def test_taking_out_the_playing_cd_goes_on_with_the_next_and_stops_when_none_is_left():
    lua = opened(server())
    lua.execute("""
        A = put('JukeboxMoon.CD_1'); B = put('JukeboxMoon.CD_2')
        cmd('play', { x = 10, y = 20, z = 0, cd = B.id, track = 4 })
        jukebox().container.items:remove(B)
        tick(1000)
    """)
    state = lua.eval("lastAll().args")
    assert state.on is True and state.track == 1 and state.cd == lua.eval("A.id")
    lua.execute("jukebox().container.items:remove(A); tick(1000)")
    assert lua.eval("lastAll().args.reason") == "nocd"


def test_taking_out_another_cd_keeps_the_track_playing():
    lua = opened(server())
    lua.execute("""
        A = put('JukeboxMoon.CD_1'); B = put('JukeboxMoon.CD_2')
        cmd('play', { x = 10, y = 20, z = 0, cd = B.id, track = 4 })
        SEQ = lastAll().args.seq
        jukebox().container.items:remove(A)
        tick(1000)
    """)
    state = lua.eval("lastAll().args")
    assert state.track == 4 and state.index == 1 and state.start == 101200


def test_a_jukebox_that_disappears_stops_but_an_unloaded_one_keeps_playing():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', at()); SQUARES['10,20,0'] = nil; tick(27000)")
    assert lua.eval("lastAll().args.track") == 2                 # nobody near: it goes on by the clock
    lua.execute("SQUARES['10,20,0'] = SQ; SQ.objects:remove(jukebox()); tick(1000)")
    assert lua.eval("lastAll().args.reason") == "gone"


def test_without_catalogue_or_switched_off_nothing_plays():
    lua = opened(server(catalog=""))
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', at())")
    assert lua.eval("lastOne().args.what") == "nocatalog" and lua.eval("#TO_ALL") == 0
    lua = opened(server())
    lua.execute("SandboxVars.JukeboxMoon.Enabled = false; put('JukeboxMoon.CD_1'); cmd('play', at())")
    assert lua.eval("lastOne().args.what") == "disabled" and lua.eval("#TO_ALL") == 0


def test_shuffle_is_the_servers_never_repeats_and_is_the_same_every_time():
    def run():
        lua = opened(server())
        lua.execute("put('JukeboxMoon.CD_1'); put('JukeboxMoon.CD_2'); cmd('shuffle', { x = 10, y = 20, z = 0, on = true })")
        lua.execute("cmd('play', at())")
        tracks = []
        for _ in range(12):
            lua.execute("NOW = NOW + 1000; cmd('next', at())")
            tracks.append(lua.eval("lastAll().args.track"))
        return tracks, lua
    first, lua = run()
    second, _ = run()
    assert first == second
    assert all(a != b for a, b in zip(first, first[1:]))
    assert len(set(first)) > 1
    assert lua.eval("jukebox().modData.jbm.shuffle") is True


def test_every_switch_on_takes_a_new_random_order():
    def order(start):
        lua = opened(server())
        lua.execute(f"NOW = {start}; put('JukeboxMoon.CD_1'); put('JukeboxMoon.CD_2'); "
                    f"cmd('shuffle', {{ x = 10, y = 20, z = 0, on = true }}); cmd('play', at())")
        tracks = [lua.eval("lastAll().args.track")]
        for _ in range(5):
            lua.execute("NOW = NOW + 1000; cmd('next', at())")
            tracks.append(lua.eval("lastAll().args.track"))
        return tuple(tracks)
    assert order(200000) == order(200000)                         # the same moment, the same order: testable
    assert len({order(200000 + k * 7777) for k in range(5)}) > 1  # another moment, another order


def test_hello_and_ping_at_most_once_a_second():
    lua = server()
    lua.execute("cmd('hello', { t0 = 1 }); cmd('hello', { t0 = 2 }); cmd('ping', { t0 = 3 }); cmd('ping', { t0 = 4 })")
    assert [c.command for c in lua.eval("TO_ONE").values()] == ["welcome", "pong"]
    lua.execute("NOW = NOW + 1000; cmd('hello', { t0 = 5 })")
    assert lua.eval("lastOne().command") == "welcome" and lua.eval("lastOne().args.t0") == 5


def test_single_player_works_without_a_network():
    # in single player sendServerCommand sends nothing: the answers must reach the local game anyway
    lua = runtime("JukeboxMoon/Server", "JukeboxMoon/Accept", "JukeboxMoon/Player", catalog=catalog())
    lua.execute(WORLD + """
        LOCAL = P
        HEARD = {}
        table.insert(JukeboxMoon.Player.listeners, function(kind) table.insert(HEARD, kind) end)
        fire("OnTick")                                              -- hello, answered at once
        JukeboxMoon.Player.send("open", at())
    """)
    heard = list(lua.eval("HEARD").values())
    assert "welcome" in heard and "opened" in heard and lua.eval("#TO_ALL + #TO_ONE") == 0
    lua.execute("put('JukeboxMoon.CD_1'); JukeboxMoon.Player.send('play', at()); tick(1200)")
    assert lua.eval("#PLAYED") == 1 and lua.eval("PLAYED[1].name") == "JukeboxMoon_T1_S0"
    # the game's own jukebox sound does not play under the music
    assert lua.eval("CHUNK.ambient[jukebox()]") is None


def test_shuffle_off_when_the_server_does_not_allow_it():
    lua = opened(server())
    lua.execute("SandboxVars.JukeboxMoon.ShuffleAllowed = false; cmd('shuffle', { x = 10, y = 20, z = 0, on = true })")
    assert lua.eval("jukebox().modData.jbm.shuffle") is False


def test_too_many_commands_are_dropped():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); for i = 1, 12 do cmd('next', at()) end")
    assert lua.eval("#TO_ALL") == 7                             # open was the first of the 8 allowed
    lua.execute("NOW = NOW + 5000; cmd('next', at())")
    assert lua.eval("#TO_ALL") == 8


def test_hello_gives_the_state_the_clock_and_the_key():
    lua = opened(server())
    lua.execute("put('JukeboxMoon.CD_1'); cmd('play', at()); cmd('hello', { t0 = 5 })")
    welcome = lua.eval("TO_ONE[#TO_ONE].args")
    assert welcome.t0 == 5 and welcome.now == 100000 and welcome.version == "v1test" and len(welcome.list) == 1
    assert lua.eval("JukeboxMoon.Server.key") is None              # no key file on the server
    lua = runtime("JukeboxMoon/Server", server=True, catalog=catalog(),
                  preload=f'FILES["JukeboxMoon_server_key.txt"] = "{KEY}\\n{KEY_ID}\\n"')
    lua.execute(WORLD + "cmd('hello', { t0 = 1 })")
    sent = lua.eval("lastOne()")
    assert sent.command == "key" and sent.args.key == KEY and sent.args.id == KEY_ID
    lua = runtime("JukeboxMoon/Server", server=True, catalog=catalog(),
                  preload='FILES["JukeboxMoon_server_key.txt"] = "not a key\\nxx\\n"')
    assert lua.eval("JukeboxMoon.Server.key") is None


def test_only_admins_make_cds_and_only_of_albums_not_archived():
    lua = server()
    lua.execute("cmd('spawn', { album = 1, count = 3 })")
    assert lua.eval("lastOne().args.what") == "notadmin" and lua.eval("P.inventory.items:size()") == 0
    lua.execute("P.admin = true; NOW = NOW + 5000; cmd('spawn', { album = 1, count = 3 })")
    assert lua.eval("P.inventory.items:size()") == 3 and lua.eval("#ADDED") == 3
    assert lua.eval("P.inventory.items:get(0):getFullType()") == "JukeboxMoon.CD_1"
    lua.execute("cmd('spawn', { album = 1, count = 21 })")
    assert lua.eval("lastOne().args.what") == "badcount"
    lua.execute("cmd('spawn', { album = 3, count = 1 })")
    assert lua.eval("lastOne().args.what") == "noalbum"


# ------------------------------------------------------------------------------------------------ boredom and stress


MOOD = r"""
put('JukeboxMoon.CD_1'); cmd('play', at())
NOW = NOW + 2000          -- past the lead: it really plays
function minutes(n) for i = 1, n do fire("EveryOneMinute") end end
"""


def mood(**setup) -> object:
    lua = opened(server())
    lua.execute(MOOD)
    for code in setup.values():
        lua.execute(code)
    return lua


def test_ten_minutes_in_range_take_off_the_hourly_rate_times_ten_sixtieths():
    lua = mood()
    lua.execute("minutes(10)")
    assert lua.eval("P.stats.BOREDOM") == pytest.approx(50 - 4 * 10 / 60)
    assert lua.eval("P.stats.STRESS") == pytest.approx(0.5 - 0.02 * 10 / 60)
    assert lua.eval("#SYNCED") == 1 and lua.eval("SYNCED[1].mask") == 64 + 128


def test_only_the_minutes_really_in_range_count():
    lua = mood()
    lua.execute("minutes(7); P.x = 30; minutes(3)")            # left after seven
    assert lua.eval("P.stats.BOREDOM") == pytest.approx(50 - 4 * 7 / 60)


def test_out_of_range_other_floor_or_not_yet_playing_gives_nothing():
    for code in ("P.x = 21.6", "P.z = 1", "NOW = NOW - 1500"):
        lua = mood(move=code)
        lua.execute("minutes(10)")
        assert lua.eval("P.stats.BOREDOM") == 50, code
    lua = mood(move="P.z = 1; SandboxVars.JukeboxMoon.AllowCrossFloorBenefits = true")
    lua.execute("minutes(10)")
    assert lua.eval("P.stats.BOREDOM") < 50


def test_deaf_none_hard_of_hearing_half():
    lua = mood(deaf="P.traits.DEAF = true")
    lua.execute("minutes(10)")
    assert lua.eval("P.stats.BOREDOM") == 50
    lua = mood(hoh="P.traits.HARD_OF_HEARING = true")
    lua.execute("minutes(10)")
    assert lua.eval("P.stats.BOREDOM") == pytest.approx(50 - 0.5 * 4 * 10 / 60)


def test_two_jukeboxes_do_not_add_up_and_nothing_goes_below_zero():
    lua = mood()
    lua.execute("""
        SQ2 = newSquare(12, 20, 0); V2 = newObject(SQ2, "recreational_01_0", "Jukebox")
        cmd('open', { x = 12, y = 20, z = 0 })
        for i = 1, SQ2.objects:size() do local o = SQ2.objects:get(i - 1) if o.container then o.container:AddItem('JukeboxMoon.CD_1') end end
        cmd('play', { x = 12, y = 20, z = 0 }); NOW = NOW + 2000
        P.stats.STRESS = 0.001
        minutes(10)
    """)
    assert lua.eval("JukeboxMoon.Server.count") == 2
    assert lua.eval("P.stats.BOREDOM") == pytest.approx(50 - 4 * 10 / 60)
    assert lua.eval("P.stats.STRESS") == 0


def test_mood_switched_off():
    lua = mood(off="SandboxVars.JukeboxMoon.MoodEffectsEnabled = false")
    lua.execute("minutes(20)")
    assert lua.eval("P.stats.BOREDOM") == 50


# ------------------------------------------------------------------------------------------------ the loot


def test_cds_join_the_loot_lists_without_replacing_them():
    stub = """
        LISTS = { CrateCompactDiscs = { items = { "Base.Disc_Retail", 50 } }, MusicStoreCDs = { items = {} } }
        package.preload["Items/ProceduralDistributions"] = function() ProceduralDistributions = { list = LISTS } end
    """
    lua = runtime("JukeboxMoon/Distributions", server=True, catalog=catalog(), preload=stub)
    lua.execute('fire("OnPreDistributionMerge"); fire("OnPreDistributionMerge")')
    items = list(lua.eval("LISTS.CrateCompactDiscs.items").values())
    assert items[:2] == ["Base.Disc_Retail", 50]
    added = dict(zip(items[2::2], items[3::2]))
    assert set(added) == {"JukeboxMoon.CD_1", "JukeboxMoon.CD_2"}      # the archived album is never found
    assert added["JukeboxMoon.CD_1"] == pytest.approx(10 * 1 / 4) and added["JukeboxMoon.CD_2"] == pytest.approx(10 * 3 / 4)
    lua = runtime("JukeboxMoon/Distributions", server=True, catalog=catalog(),
                  preload=stub + "SandboxVars.JukeboxMoon.EnableCDLoot = false")
    lua.execute('fire("OnPreDistributionMerge")')
    assert len(lua.eval("LISTS.CrateCompactDiscs.items")) == 2


# ------------------------------------------------------------------------------------------------ the unique CD

UNIQUE_FILE = 'FILES["jukeboxmoon_unique.json"]'


def unique_catalog() -> str:
    albums = [
        AlbumOut(key=1, id="estate", title="Estate", artist="Vari", year=1993, loot=1.0, archived=False,
                 tracks=[TrackOut(1, "a", 1, "Primo", "A", 25000, 3)], cover=None),
        AlbumOut(key=5, id="love-storii", title="Love storii...", artist="Prince", year=2023, loot=1.0,
                 archived=False, tracks=[TrackOut(9, "alpha", 1, "Alpha", "Prince, Ervie", 20000, 2)], cover=None,
                 unique={"from": "runner", "oneIn": 300}),
    ]
    return generate.catalog_lua("v1test", albums)


# The game's two actions that move items, as the client runs them (42.21: perform() takes queueList[1] and moves its
# items; ISGrabItemAction's are world objects). Here they move the items themselves, as single player does.
ACTIONS = r"""
local function action(name, floor)
    local c = {}
    function c.new(character, items, src, dest)
        return { character = character, queueList = { { items = items } }, src = src, dest = dest, perform = c.perform }
    end
    function c.perform(self)
        local queued = table.remove(self.queueList, 1)
        for _, entry in ipairs(queued.items) do
            local item = floor and entry:getItem() or entry
            if self.src then self.src.items:remove(item) end
            self.dest.items:add(item)
        end
    end
    _G[name] = c
end
action("ISInventoryTransferAction", false)
action("ISGrabItemAction", true)
package.preload["TimedActions/ISInventoryTransferAction"] = function() end
package.preload["TimedActions/ISGrabItemAction"] = function() end
"""

UNIQUE_WORLD = r"""
CD = "JukeboxMoon.CD_5"
function kill(walk, killer, burning, x, y)
    local z = newZombie(x or 10, y or 20, 0, walk, killer, burning)
    fire("OnZombieDead", z)
    return z
end
function state() return ((MODDATA.JukeboxMoon or {}).unique or {})["5"] or {} end
function taken(player) cmd("taken", { album = 5, item = 1 }, player) end
"""


def unique_game(server=True, client=False):
    modules = ["JukeboxMoon/Server", "JukeboxMoon/Unique"] + (["JukeboxMoon/Finder"] if client else [])
    lua = runtime(*modules, server=server, catalog=unique_catalog(), preload=ACTIONS)
    lua.execute(WORLD + UNIQUE_WORLD)
    return lua


def found(lua):
    return json.loads(lua.eval(UNIQUE_FILE))["unique"][0]["found"]


def test_the_unique_cd_is_never_loot_nor_made_by_admins():
    lua = unique_game()
    assert [a.key for a in lua.eval("JukeboxMoon.Catalog.activeAlbums()").values()] == [1]
    lua.execute("P.admin = true; cmd('spawn', { album = 5, count = 1 })")
    assert lua.eval("lastOne().args.what") == "noalbum" and lua.eval("P.inventory.items:size()") == 0


def test_the_file_for_zombot_says_the_cd_is_waiting():
    lua = unique_game()
    lua.execute('fire("OnInitGlobalModData", false)')
    assert lua.eval(UNIQUE_FILE) == ('{"v":1,"unique":[{"key":"5","name":"CD: Love storii...","artist":"Prince",'
                                     '"found":null}]}\n')


def test_only_a_runner_killed_by_a_player_rolls_and_the_cd_drops_once():
    lua = unique_game()
    lua.execute("kill('slow2', P); kill('sprint3', nil); kill('sprint3', P, true)")
    assert lua.eval("#RANDS") == 0                                  # a shambler, no killer, burning: no roll
    lua.execute("Z1 = kill('sprint3', P)")
    assert lua.eval("RANDS[1]") == 300 and lua.eval("Z1.inventory.items:size()") == 0
    lua.execute("fire('OnZombieDead', Z1)")                          # the fire path: the same zombie again
    assert lua.eval("#RANDS") == 1 and lua.eval("state().state") == "waiting"
    lua.execute("NEXT_RAND = 0; Z2 = kill('sprint1', P)")
    assert lua.eval("Z2.inventory:containsTypeRecurse(CD)") is True   # on the zombie: the game makes the corpse of it
    s = lua.eval("state()")
    assert s.state == "dropped" and (s.x, s.y, s.z) == (10, 20, 0) and found(lua) is None
    lua.execute("NEXT_RAND = 0; Z3 = kill('sprint1', P)")
    assert lua.eval("Z3.inventory.items:size()") == 0 and lua.eval("#RANDS") == 2   # out already: no more rolls


def test_the_server_does_nothing_on_its_own():
    lua = unique_game()
    lua.execute("NEXT_RAND = 0; Z = kill('sprint2', P); P.inventory.items:add(Z.inventory:take(CD))")
    lua.execute("for i = 1, 30 do fire('EveryOneMinute') end")
    assert lua.eval("state().state") == "dropped"                    # nobody told it: it does not look


def test_found_by_the_player_who_carries_it_and_never_again():
    lua = unique_game()
    lua.execute("taken()")
    assert lua.eval("state().state") == "waiting"                    # nothing out: a message is ignored
    lua.execute("NEXT_RAND = 0; Z = kill('sprint2', P); newCorpse(SQ, Z.inventory)")
    lua.execute("P.inventory.items:add(Z.inventory:take(CD)); NOW = NOW + 60000; taken()")
    assert lua.eval("state().state") == "found"
    assert found(lua) == {"user": "anna", "character": "Nome anna", "at": 160, "from": "runner", "test": False}
    lua.execute("NEXT_RAND = 0; Z4 = kill('sprint1', P)")
    assert lua.eval("Z4.inventory.items:size()") == 0 and lua.eval("state().state") == "found"


def test_put_in_a_crate_where_it_fell_counts_only_off_its_corpse_and_near():
    lua = unique_game()
    lua.execute("""
        NEXT_RAND = 0; Z = kill('sprint2', P); BODY = newCorpse(SQ, Z.inventory)
        B = newPlayer("bruno", 200, 200, 0); taken(B)
    """)
    assert lua.eval("state().state") == "dropped"                    # far away and not carrying it: refused
    lua.execute("taken()")
    assert lua.eval("state().state") == "dropped"                    # near, but it is still on the corpse
    lua.execute("""
        CRATE = newObject(newSquare(11, 21, 0), 'crate', nil); CRATE.container = newContainer('crate')
        CRATE.container.items:add(Z.inventory:take(CD)); NOW = NOW + 5000; taken()
    """)
    assert lua.eval("state().state") == "found" and found(lua)["user"] == "anna"


def test_a_corpse_nobody_loots_lets_it_drop_again_only_after_the_removal_time():
    lua = unique_game()
    lua.execute("SandboxVars.HoursForCorpseRemoval = 216; HOURS = 1000; NEXT_RAND = 0; Z = kill('sprint2', P)")
    assert lua.eval("state().hours") == 1000
    lua.execute("HOURS = 1215; NEXT_RAND = 0; Z2 = kill('sprint2', P, false, 40, 40)")
    assert lua.eval("#RANDS") == 1 and lua.eval("Z2.inventory.items:size()") == 0   # still within the time: no roll
    lua.execute("HOURS = 1216; NEXT_RAND = 0; Z3 = kill('sprint2', P, false, 40, 40)")
    assert lua.eval("Z3.inventory:containsTypeRecurse(CD)") is True
    s = lua.eval("state()")
    assert s.state == "dropped" and (s.x, s.y) == (40, 40) and s.hours == 1216
    lua = unique_game()
    lua.execute("SandboxVars.HoursForCorpseRemoval = -1; NEXT_RAND = 0; kill('sprint2', P); HOURS = 99999")
    lua.execute("NEXT_RAND = 0; Z2 = kill('sprint2', P)")
    assert lua.eval("Z2.inventory.items:size()") == 0                # corpses never removed: it stays on its own


def test_names_are_escaped_for_json():
    lua = unique_game()
    lua.execute("""P.fullName = 'Anna "la" \\\\ B'
        NEXT_RAND = 0; Z = kill('sprint2', P); P.inventory.items:add(Z.inventory:take(CD)); taken()""")
    assert found(lua)["character"] == 'Anna "la" \\ B'


def test_the_mod_tells_the_server_once_when_it_moves_the_cd():
    lua = unique_game(server=False, client=True)                      # single player: the same Lua, no network
    lua.execute("""
        LOCAL = P
        DEBUG = true; Z = kill('sprint2', P); BODY = newCorpse(SQ, Z.inventory)
        OTHER = BODY.container:AddItem("JukeboxMoon.CD_1")
        ISInventoryTransferAction.new(P, { OTHER }, BODY.container, P.inventory):perform()
    """)
    assert lua.eval("RANDS[1]") == 1                                  # -debug: the first runner has it
    assert lua.eval("#TO_SERVER") == 0 and lua.eval("state().state") == "dropped"   # another CD: nothing said
    lua.execute("CDITEM = BODY.container:take(CD); BODY.container.items:add(CDITEM)")
    lua.execute("ISInventoryTransferAction.new(P, { CDITEM }, BODY.container, P.inventory):perform()")
    sent = [c.command for c in lua.eval("TO_SERVER").values()]
    assert sent == ["taken"] and lua.eval("state().state") == "found" and found(lua)["test"] is True
    lua.execute("ISInventoryTransferAction.new(P, { CDITEM }, P.inventory, P.inventory):perform()")
    assert lua.eval("#TO_SERVER") == 1                                # the same CD again soon: not said twice


def test_the_mod_tells_it_from_the_floor_too():
    lua = unique_game(server=False, client=True)
    lua.execute("""
        LOCAL = P
        DEBUG = true; Z = kill('sprint2', P)
        CDITEM = Z.inventory:take(CD); FLOOR = { getItem = function() return CDITEM end }
        ISGrabItemAction.new(P, { FLOOR }, nil, P.inventory):perform()
    """)
    assert lua.eval("state().state") == "found"


# ------------------------------------------------------------------------------------------------ the client


CLIENT = r"""
LOCAL = newPlayer("bruno", 12.5, 21.5, 0)
function server(command, args) fire("OnServerCommand", "JukeboxMoon", command, args) end
NOW = 1100
server("welcome", { t0 = 1000, now = 6000, version = "v1test", list = {} })   -- offset 6000 - 1050 = 4950
function serverNow() return NOW + 4950 end
function state(seq, track, start, on) server("state", { key = "10,20,0", x = 10, y = 20, z = 0, on = on ~= false, seq = seq, track = track, start = start, ends = start + 25000 }) end
function names() local out = {} for i = 1, #PLAYED do out[i] = PLAYED[i].name end return out end
function tick(ms) NOW = NOW + ms fire("OnTick") end
"""


def client(**kw):
    lua = runtime("JukeboxMoon/Player", client=True, catalog=kw.pop("catalog", catalog()), **kw)
    lua.execute(CLIENT)
    return lua


def played(lua) -> list[str]:
    return list(lua.eval("names()").values())


def test_the_clock_keeps_the_quickest_answer():
    lua = client()
    assert lua.eval("JukeboxMoon.Player.offset") == 4950
    lua.execute('NOW = 2000; server("pong", { t0 = 1500, now = 7000 })')    # slower (500 ms): ignored
    assert lua.eval("JukeboxMoon.Player.offset") == 4950
    lua.execute('NOW = 3010; server("pong", { t0 = 3000, now = 7960 })')    # quicker (10 ms)
    assert lua.eval("JukeboxMoon.Player.offset") == 7960 - 3005


def test_pieces_follow_each_other_at_the_servers_time():
    lua = client()
    lua.execute("state(1, 1, serverNow() + 1200); tick(0)")
    assert played(lua) == []                                  # not yet
    lua.execute("tick(1200)")
    assert played(lua) == ["JukeboxMoon_T1_S0"]
    lua.execute("tick(9990)")
    assert played(lua) == ["JukeboxMoon_T1_S0"]
    lua.execute("tick(10)")
    assert played(lua) == ["JukeboxMoon_T1_S0", "JukeboxMoon_T1_S1"]
    assert lua.eval("#STOPPED") == 0                          # the piece before fades out by itself
    lua.execute("tick(10000)")
    assert played(lua)[-1] == "JukeboxMoon_T1_S2" and lua.eval("STOPPED[1]") == 1
    lua.execute("tick(10000)")
    assert len(played(lua)) == 3                              # over: the server moves on


def test_arriving_in_the_middle_waits_for_the_next_piece():
    lua = client()
    lua.execute("state(1, 1, serverNow() - 13000); tick(0)")
    assert played(lua) == []
    lua.execute("tick(6990)")
    assert played(lua) == []
    lua.execute("tick(10)")
    assert played(lua) == ["JukeboxMoon_T1_S2"]
    assert lua.eval("PLAYED[1].emitter.x") == 10.5 and lua.eval("PLAYED[1].emitter.y") == 20.5


def test_walking_away_stops_only_this_client_and_coming_back_rejoins_at_the_right_point():
    lua = client()
    lua.execute("state(1, 1, serverNow()); tick(0)")
    assert played(lua) == ["JukeboxMoon_T1_S0"]
    lua.execute("LOCAL.x = 100; tick(3000)")
    assert lua.eval("#STOPPED") == 1
    lua.execute("LOCAL.x = 12.5; tick(3000)")
    assert played(lua) == ["JukeboxMoon_T1_S0"]
    lua.execute("tick(4000)")
    assert played(lua) == ["JukeboxMoon_T1_S0", "JukeboxMoon_T1_S1"]
    assert all(c.command in ("hello", "ping") for c in lua.eval("TO_SERVER").values())


def test_a_new_track_or_a_stop_replaces_what_plays():
    lua = client()
    lua.execute("state(1, 1, serverNow()); tick(0); state(2, 4, serverNow() + 1200); tick(0)")
    assert lua.eval("#STOPPED") == 1
    lua.execute("tick(1200)")
    assert played(lua)[-1] == "JukeboxMoon_T4_S0"
    lua.execute("state(1, 1, serverNow()); tick(0)")            # an older message: ignored
    assert played(lua)[-1] == "JukeboxMoon_T4_S0"
    lua.execute("state(3, 4, serverNow(), false); tick(0)")
    assert lua.eval("#STOPPED") == 2


def test_another_catalogue_than_the_servers_or_none_plays_nothing():
    lua = client()
    lua.execute('server("welcome", { t0 = 1000, now = 6000, version = "other", list = {} }); state(1, 1, serverNow()); tick(0)')
    assert played(lua) == [] and lua.eval("JukeboxMoon.Player.problem()") == "update"
    lua = client(catalog="")
    lua.execute("state(1, 1, serverNow()); tick(0)")
    assert played(lua) == [] and lua.eval("JukeboxMoon.Player.problem()") == "nocatalog"


def test_the_key_is_written_for_the_launcher_only_when_it_is_a_key():
    lua = client()
    lua.execute(f'server("key", {{ key = "{KEY}", id = "{KEY_ID}" }})')
    assert lua.eval('FILES["JukeboxMoon_key.txt"]') == f"{KEY}\n{KEY_ID}\n"
    lua.execute('FILES["JukeboxMoon_key.txt"] = nil; server("key", { key = "zz", id = "1" })')
    assert lua.eval('FILES["JukeboxMoon_key.txt"]') is None


def test_the_local_volume_is_kept_on_this_computer():
    lua = client()
    lua.execute("state(1, 1, serverNow()); tick(0); JukeboxMoon.Player.setVolume(0.3)")
    assert lua.eval("PLAYED[1].emitter.volumes[PLAYED[1].id]") == pytest.approx(0.3)   # the sound at once
    assert lua.eval('FILES["JukeboxMoon_volume.txt"]') is None                         # the file once it stops
    lua.execute("JukeboxMoon.Player.setVolume(0.4); tick(500); JukeboxMoon.Player.setVolume(0.3); tick(500)")
    assert lua.eval('FILES["JukeboxMoon_volume.txt"]') is None
    lua.execute("tick(500)")
    assert lua.eval('FILES["JukeboxMoon_volume.txt"]') == "0.3"
    lua.execute("JukeboxMoon.Player.volume = 1; JukeboxMoon.Player.loadVolume()")
    assert lua.eval("JukeboxMoon.Player.volume") == pytest.approx(0.3)


# ------------------------------------------------------------------------------------------------ the window

UI_STUBS = r"""
local function class(name)
    local c = {}
    c.__index = c
    function c:derive(n) local d = setmetatable({}, { __index = self }) d.__index = d return d end
    _G[name] = c
end
for _, name in ipairs({ "ISCollapsableWindow", "ISButton", "ISScrollingListBox", "ISTickBox", "ISSliderPanel" }) do class(name) end
for _, path in ipairs({ "ISUI/ISCollapsableWindow", "ISUI/ISButton", "ISUI/ISScrollingListBox", "ISUI/ISTickBox",
    "RadioCom/ISUIRadio/ISSliderPanel" }) do package.preload[path] = function() end end
"""


def test_the_status_line_says_why_it_does_not_play():
    lua = runtime("JukeboxMoon/Window", client=True, catalog=catalog(), preload=UI_STUBS)
    key = lua.eval("JukeboxMoon.Window.statusKey")
    base = {"problem": None, "enabled": True, "converted": True, "on": False, "trackKnown": False, "power": True, "cds": 2}

    def status(**change):
        view = dict(base, **change)
        return key(lua.table_from(view))

    assert status() == "IGUI_JukeboxMoon_Status_Ready"
    assert status(on=True, trackKnown=True) == "IGUI_JukeboxMoon_Status_Playing"
    assert status(on=True) == "IGUI_JukeboxMoon_Status_Unavailable"
    assert status(power=False) == "IGUI_JukeboxMoon_Status_NoPower"
    assert status(cds=0) == "IGUI_JukeboxMoon_Status_NoCD"
    assert status(converted=False) == "IGUI_JukeboxMoon_Status_Preparing"
    assert status(enabled=False) == "IGUI_JukeboxMoon_Status_Off"
    assert status(problem="nocatalog", on=True) == "IGUI_JukeboxMoon_Status_NoCatalog"
    assert status(problem="update") == "IGUI_JukeboxMoon_Status_Update"
    mine = lua.eval("JukeboxMoon.Window.forJukebox")
    assert mine(lua.table_from({"what": "nopower", "key": "10,20,0"}), "10,20,0")
    assert not mine(lua.table_from({"what": "nopower", "key": "1,2,0"}), "10,20,0")      # another jukebox
    assert mine(lua.table_from({"what": "far"}), "10,20,0")
    assert not mine(lua.table_from({"what": "spawned", "count": 3}), "10,20,0")          # the admin window's
    row = lua.eval("JukeboxMoon.Window.rowText({ cd = 1, track = 2 })")
    assert row == "2. Secondo - Vari  (Estate è qui)"
    assert lua.eval("JukeboxMoon.Window.rowText({ cd = 1, track = 77 })") == "IGUI_JukeboxMoon_UnknownTrack"


# ------------------------------------------------------------------------------------------------ static checks


def lua_files():
    return sorted(LUA.rglob("*.lua"))


MISSING = re.compile(r"(?<![\w.:])(next|xpcall)\s*\(|\btable\.(pack|unpack)\b|\bos\.clock\b|//")


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_lua_is_plain_ascii_and_uses_only_what_the_game_has(path):
    text = path.read_text(encoding="utf-8")
    if path.name == "ZomBotMenu.lua":
        code = [line.split("--", 1)[0] for line in text.splitlines()]
        assert all(part.isascii() for part in code)
        return
    assert text.isascii(), f"{path.name}: Kahlua loses accented letters in strings; texts go in Translate/*.json"
    code = "\n".join(re.sub(r"--.*$", "", line) for line in text.split("\n"))
    found = MISSING.search(code)
    assert not found, f"{path.name}: the game's Lua has no {found.group(0)}"


def translations(lang):
    out = {}
    for path in (LUA / "shared" / "Translate" / lang).glob("*.json"):
        out.update(json.loads(path.read_text(encoding="utf-8")))
    return out


def sandbox_options():
    text = (MOD / "media" / "sandbox-options.txt").read_text(encoding="utf-8")
    return re.findall(r"^option JukeboxMoon\.(\w+)", text, re.M)


@pytest.mark.parametrize("lang", ["IT", "EN"])
def test_every_text_has_a_translation(lang):
    texts = translations(lang)
    used = set()
    for path in lua_files():
        used |= set(re.findall(r'"((?:IGUI|ContextMenu|Tooltip)_JukeboxMoon_\w+)"', path.read_text(encoding="utf-8")))
    used |= {f"IGUI_JukeboxMoon_Stopped_{r}" for r in ("nopower", "nocd", "unavailable", "gone")}
    used |= {f"IGUI_JukeboxMoon_Notice_{w}" for w in
             ("far", "nopower", "nocd", "nocatalog", "disabled", "notadmin", "badcount", "noalbum", "spawned")}
    used -= {"IGUI_JukeboxMoon_Stopped_", "IGUI_JukeboxMoon_Notice_"}
    used.add("Tooltip_JukeboxMoon_CD")                       # the generated CD items
    for option in sandbox_options():
        used |= {f"Sandbox_JukeboxMoon_{option}", f"Sandbox_JukeboxMoon_{option}_tooltip"}
    used |= {"Sandbox_JukeboxMoon"} | {f"Sandbox_JukeboxMoon_LootRarity_option{i}" for i in (1, 2, 3)}
    missing = sorted(k for k in used if k not in texts)
    assert not missing, f"{lang}: {missing}"
    assert set(translations("IT")) == set(translations("EN"))


def test_the_server_reasons_and_notices_are_the_ones_translated():
    text = (LUA / "server" / "JukeboxMoon" / "Server.lua").read_text(encoding="utf-8")
    reasons = set(re.findall(r'Server\.stop\(\w+, "(\w+)"\)', text)) - {"off"}
    notices = set(re.findall(r'notice\(player, "(\w+)"', text)) | {"spawned"}
    texts = translations("IT")
    assert reasons and all(f"IGUI_JukeboxMoon_Stopped_{r}" in texts for r in reasons), reasons
    assert all(f"IGUI_JukeboxMoon_Notice_{n}" in texts for n in notices), notices


def test_italian_texts_avoid_glyphs_the_game_font_may_lack():
    for value in translations("IT").values():
        assert not set(value) & set("—–«»“”"), value


def test_the_options_and_their_defaults_match_the_lua():
    lua = runtime("JukeboxMoon/Core")
    defaults = lua.eval("JukeboxMoon.Core.DEFAULTS")
    assert set(defaults.keys()) == set(sandbox_options())
    text = (MOD / "media" / "sandbox-options.txt").read_text(encoding="utf-8")
    for name, value in defaults.items():
        block = re.search(rf"option JukeboxMoon\.{name}\s*\{{(.*?)\}}", text, re.S).group(1)
        written = re.search(r"default = ([\w.]+)", block).group(1)
        expected = str(value).lower() if isinstance(value, bool) else value
        assert str(written) == str(expected) or float(written) == float(expected), name


def test_the_shared_zombot_menu_is_the_same_file_as_in_zombot_moon():
    ours = LUA / "client" / "ZomBotMenu.lua"
    theirs = ROOT / "mods" / "ZomBOTMoon" / "42" / "media" / "lua" / "client" / "ZomBotMenu.lua"
    assert ours.read_bytes() == theirs.read_bytes()


def test_mod_info():
    info = dict(line.split("=", 1) for line in (MOD / "mod.info").read_text(encoding="utf-8").splitlines() if "=" in line)
    assert info["id"] == "JukeboxMoon" and info["versionMin"] == "42.21.0"
    assert (MOD / "poster.png").exists() and (MOD / "icon.png").exists() and (MOD.parent / "icon.png").exists()


def test_the_generated_catalogue_is_ascii_and_loads():
    text = catalog()
    assert text.isascii()
    lua = runtime("JukeboxMoon/Catalog", catalog=text)
    assert lua.eval("JukeboxMoon.Catalog.version()") == "v1test"
    assert lua.eval("JukeboxMoon.Catalog.track(1).album.title") == "Estate è qui"
    assert lua.eval("JukeboxMoon.Catalog.soundName(12, 3)") == "JukeboxMoon_T12_S3"
    assert lua.eval("JukeboxMoon.Catalog.clock(187000)") == "3:07"
    assert lua.eval("#JukeboxMoon.Catalog.activeAlbums()") == 3 and lua.eval("#JukeboxMoon.Catalog.albums()") == 4
    assert lua.eval("JukeboxMoon.Catalog.albumByKey(4).item") is None


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_every_file_compiles(path):
    lua = runtime()
    compile_ = lua.eval("function(code, name) local f, err = load(code, name) return err end")
    assert compile_(path.read_text(encoding="utf-8"), path.name) is None


def test_the_right_click_and_the_admin_button_are_registered():
    lua = runtime("JukeboxMoon/Context", "JukeboxMoon/Admin", client=True, catalog=catalog(), preload=UI_STUBS)
    lua.execute("""
        SQ = newSquare(10, 20, 0); J = newObject(SQ, "recreational_01_1", "Jukebox"); W = newObject(SQ, "walls", nil)
        LOCAL = newPlayer("bruno", 11.5, 20.5, 0)
        OPTIONS = {}
        MENU = { addOption = function(_, text, target, fn, a, b) table.insert(OPTIONS, { text = text, fn = fn, a = a, b = b }) end }
        fire("OnFillWorldObjectContextMenu", 0, MENU, { W }, false)
    """)
    assert lua.eval("#OPTIONS") == 1 and lua.eval("OPTIONS[1].text") == "ContextMenu_JukeboxMoon_Open"
    assert lua.eval("OPTIONS[1].a == J")
    lua.execute("OPTIONS[1].fn({ W }, J, 0)")
    sent = lua.eval("TO_SERVER[#TO_SERVER]")
    assert sent.command == "open" and (sent.args.x, sent.args.y, sent.args.z) == (10, 20, 0)
    ids = {(d.kind, d.id) for d in lua.eval("ZomBotMenu.defs").values()}
    assert ("extra", "jukeboxmoon") in ids and ("main", "jukeboxmoon") in ids
    # a controller first asks whether there is an option: yes on a jukebox (setTest), nothing elsewhere
    lua.execute("ISWorldObjectContextMenu = { setTest = function() TESTED = true return true end }; OPTIONS = {}")
    assert lua.eval("JukeboxMoon.Context.onFill(0, MENU, { W }, true)") is True
    assert lua.eval("TESTED") is True and lua.eval("#OPTIONS") == 0
    lua.execute("TESTED = nil; SQ2 = newSquare(50, 50, 0); W2 = newObject(SQ2, 'walls', nil)")
    assert lua.eval("JukeboxMoon.Context.onFill(0, MENU, { W2 }, true)") is None and lua.eval("TESTED") is None
