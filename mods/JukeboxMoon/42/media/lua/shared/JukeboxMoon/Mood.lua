-- JukeboxMoon: boredom and stress near a playing jukebox (FR-05, FR-06), as plain functions. The server counts, for
-- each player, the game minutes spent in range of a jukebox really playing, and every MoodEvaluationMinutes takes off
-- rate x minutes / 60 x the hearing multiplier. Several jukeboxes do not add up.

require "JukeboxMoon/Core"

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

-- deaf, hardOfHearing: booleans of the player's traits.
function Mood.multiplier(deaf, hardOfHearing)
	if deaf then return Core.option("DeafBenefitMultiplier") end
	if hardOfHearing then return Core.option("HardOfHearingBenefitMultiplier") end
	return 1
end

-- What to take off after `minutes` game minutes in range: boredom (0..100) and stress (0..1), never more than what
-- the player has (no credit for later).
function Mood.relief(minutes, multiplier, boredomNow, stressNow)
	local boredom = Core.option("BoredomReductionPerGameHour") * minutes / 60 * multiplier
	local stress = Core.option("StressReductionPerGameHour") * minutes / 60 * multiplier
	if boredom > (boredomNow or 0) then boredom = math.max(0, boredomNow or 0) end
	if stress > (stressNow or 0) then stress = math.max(0, stressNow or 0) end
	return boredom, stress
end

return Mood
