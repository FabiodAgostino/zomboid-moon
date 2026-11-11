-- JukeboxMoon: boredom and stress near a playing jukebox (FR-05, FR-06), as plain functions. The server counts, for
-- each player, the game minutes spent in range of a jukebox really playing, and every MoodEvaluationMinutes takes off
-- rate x minutes / 60 x the hearing multiplier. Several jukeboxes do not add up.
-- A unique CD (Catalog.isUnique) also takes off unhappiness, for the minutes in range of one playing it (1.2.0, 11
-- November 2026, the user: "la musica deve togliere anche la tristezza ... solo per i CD unici").

require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"

if JukeboxMoon.Mood then return JukeboxMoon.Mood end

local Core = JukeboxMoon.Core
local Mood = {}
JukeboxMoon.Mood = Mood

-- A jukebox state (Server.active) heard at (x, y, z) now: playing, powered, within the radius, on the same floor
-- unless the server allows other floors.
function Mood.inRange(box, x, y, z, nowMs, radius, crossFloor)
	if not box or not box.on or not box.power then return false end
	if nowMs < (box.start or 0) or nowMs >= (box.ends or 0) then return false end
	if not crossFloor and math.floor(z) ~= math.floor(box.z) then return false end
	local dx = (x - (box.x + 0.5))
	local dy = (y - (box.y + 0.5))
	return dx * dx + dy * dy <= radius * radius
end

function Mood.anyInRange(boxes, x, y, z, nowMs)
	local radius = Core.option("BenefitRadiusTiles")
	local crossFloor = Core.option("AllowCrossFloorBenefits")
	for _, box in pairs(boxes or {}) do
		if Mood.inRange(box, x, y, z, nowMs, radius, crossFloor) then return true end
	end
	return false
end

-- In range of a jukebox whose track is from a unique CD: the minutes that also take off unhappiness.
function Mood.uniqueInRange(boxes, x, y, z, nowMs)
	local radius = Core.option("BenefitRadiusTiles")
	local crossFloor = Core.option("AllowCrossFloorBenefits")
	local Catalog = JukeboxMoon.Catalog
	for _, box in pairs(boxes or {}) do
		if Mood.inRange(box, x, y, z, nowMs, radius, crossFloor) then
			local track = Catalog.track(box.track)
			if track and Catalog.isUnique(track.album) then return true end
		end
	end
	return false
end

-- deaf, hardOfHearing: booleans of the player's traits.
function Mood.multiplier(deaf, hardOfHearing)
	if deaf then return Core.option("DeafBenefitMultiplier") end
	if hardOfHearing then return Core.option("HardOfHearingBenefitMultiplier") end
	return 1
end

-- What to take off after `minutes` game minutes in range: boredom (0..100) and stress (0..1), and after
-- `uniqueMinutes` of them with a unique CD unhappiness (0..100), never more than what the player has (no credit for
-- later).
function Mood.relief(minutes, multiplier, boredomNow, stressNow, uniqueMinutes, unhappyNow)
	local boredom = Core.option("BoredomReductionPerGameHour") * minutes / 60 * multiplier
	local stress = Core.option("StressReductionPerGameHour") * minutes / 60 * multiplier
	local unhappiness = Core.option("UnhappinessReductionPerGameHour") * (uniqueMinutes or 0) / 60 * multiplier
	if boredom > (boredomNow or 0) then boredom = math.max(0, boredomNow or 0) end
	if stress > (stressNow or 0) then stress = math.max(0, stressNow or 0) end
	if unhappiness > (unhappyNow or 0) then unhappiness = math.max(0, unhappyNow or 0) end
	return boredom, stress, unhappiness
end

return Mood
