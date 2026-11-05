-- JukeboxMoon: the game's server/Items/AcceptItemFunction.lua starts with `AcceptItemFunction = {}` and runs after
-- the shared files, wiping what Box.lua registered. A mod's server files run after the game's, on the server and on a
-- multiplayer client alike (both load media/lua/server): register again here, on both.
require "JukeboxMoon/Box"

JukeboxMoon.Box.registerAccept()
Events.OnGameStart.Add(JukeboxMoon.Box.registerAccept)
