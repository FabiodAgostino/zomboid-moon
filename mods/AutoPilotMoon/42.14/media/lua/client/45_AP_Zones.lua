-- AutoPilot (Moon): automations for the Moon server.

-- Protected zones and objects. The rule (11/11/2026): what a player can do by hand without the mod, they can do with
-- it; the mod only automates the game and forbids only what the game (or Moon's server mods) forbids by hand.
-- What stays out: a safehouse the player may not use (the game blocks it; PlayerSafehouse=false on Moon, checked for
-- any other server) and ZomBOT's gravestones (its server blocks scrapping them). Client-side only: what must really
-- hold is checked on the server (decision 2 of the second analysis).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Zones = AutoPilotMoon.Zones or {};

-- true when the square is in a safehouse the player may not interact with (SafeHouse.isSafehouseAllowInteract(square,
-- player) of 42.22: true without a safehouse, for members, for those with CanGoInsideSafehouses and during a war).
-- A missing square counts as protected.
function AutoPilotMoon.Zones:isProtected(square, player)
	if square == nil
	then
		return true;
	end

	if player ~= nil and SafeHouse ~= nil and not SafeHouse.isSafehouseAllowInteract(square, player)
	then
		return true;
	end

	return false;
end

-- ZomBOT's gravestone (zomboid-discord, host/lua/server/ZomBotGraves.lua, Graves.isGrave): the modData "zombotGrave".
-- Never dismantled nor emptied, wherever it is (N-M9): ZomBOT's server refuses to scrap it.
AutoPilotMoon.Zones.graveKey = "zombotGrave";

function AutoPilotMoon.Zones:isGrave(object)
	return object ~= nil and object:hasModData() and object:getModData()[AutoPilotMoon.Zones.graveKey] ~= nil;
end

-- an object no automation touches: a missing one, or a ZomBOT gravestone
function AutoPilotMoon.Zones:isProtectedObject(object)
	return object == nil or AutoPilotMoon.Zones:isGrave(object);
end
