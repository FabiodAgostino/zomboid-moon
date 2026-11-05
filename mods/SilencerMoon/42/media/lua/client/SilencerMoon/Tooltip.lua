-- SilencerMoon: three bars under the game's tooltip of a suppressor, and of a firearm that has one mounted.
-- 20 ticks each (5% per tick): green the noise taken away, orange the range lost, red the damage lost, grey the
-- rest, the exact value always written beside (12,5% fills two ticks and a half). Then the condition of a mounted
-- suppressor and the average life, which is only an average: the wear is random. A worn-out suppressor (condition
-- 0) does nothing, so it shows no bars, only that it is worn out.
--
-- The game builds one tooltip per inventory panel and reuses it for whatever the mouse is on (setItem), so every
-- tooltip gets a renderer that first draws the game's own (or another mod's) and then adds ours when it applies.

require "ISUI/ISToolTipInv"
require "SilencerMoon/Core"
if SilencerMoon.Tooltip then return SilencerMoon.Tooltip end

local Core = SilencerMoon.Core
local Tooltip = {}
SilencerMoon.Tooltip = Tooltip

local TICKS = 20
local TICK_W = 6
local TICK_GAP = 1
local BAR_W = TICKS * TICK_W + (TICKS - 1) * TICK_GAP
local PAD = 8
local COLORS = {
	noise = { 0.35, 0.80, 0.35 },
	range = { 1.00, 0.60, 0.15 },
	damage = { 0.90, 0.25, 0.25 },
}
local GREY = { 0.30, 0.30, 0.30 }

-- The tier to show for an item, the suppressor itself, and whether it is mounted on the item (a firearm).
function Tooltip.subject(item)
	if not item then return nil end
	local tier = Core.tierOfType(item:getFullType())
	if tier then return tier, item, false end
	if instanceof(item, "HandWeapon") and item:isRanged() then
		local part = Core.suppressor(item)
		if part then return Core.tierOfType(part:getFullType()), part, true end
	end
	return nil
end

-- The three rows of a tier: the share shown, its sign and colour.
function Tooltip.rows(tier)
	return {
		{ key = "IGUI_SilencerMoon_Noise", share = 1 - tier.radius, sign = "", color = "noise" },
		{ key = "IGUI_SilencerMoon_Range", share = 1 - tier.range, sign = "-", color = "range" },
		{ key = "IGUI_SilencerMoon_Damage", share = 1 - tier.damage, sign = "-", color = "damage" },
	}
end

-- Half ticks filled for a share: 0.125 -> 5 (two ticks and a half), 0.4 -> 16.
function Tooltip.halfTicks(share)
	return math.max(0, math.min(TICKS * 2, math.floor(share * TICKS * 2 + 0.5)))
end

function Tooltip.valueText(row)
	return row.sign .. Core.percentText(row.share) .. "%"
end

local function drawBar(self, x, y, h, row)
	local color = COLORS[row.color]
	local halves = Tooltip.halfTicks(row.share)
	for i = 0, TICKS - 1 do
		local tx = x + i * (TICK_W + TICK_GAP)
		self:drawRect(tx, y, TICK_W, h, 1, GREY[1], GREY[2], GREY[3])
		local filled = halves - i * 2
		if filled >= 2 then
			self:drawRect(tx, y, TICK_W, h, 1, color[1], color[2], color[3])
		elseif filled == 1 then
			self:drawRect(tx, y, TICK_W / 2, h, 1, color[1], color[2], color[3])
		end
	end
end

local function render(self, tier, part, mounted)
	if ISContextMenu and ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
	local font = UIFont.Small
	local text = getTextManager()
	local lineH = text:getFontHeight(font)
	local title = getText("IGUI_SilencerMoon_Tier", getText("IGUI_SilencerMoon_Tier_" .. tier.id))
	-- worn out (condition 0), mounted or not: it does nothing any more, so no bars, only that
	local worn = part:getCondition() <= 0
	local rows = worn and {} or Tooltip.rows(tier)
	local labelW, valueW = 0, 0
	for _, row in ipairs(rows) do
		row.label = getText(row.key)
		row.value = Tooltip.valueText(row)
		labelW = math.max(labelW, text:MeasureStringX(font, row.label))
		valueW = math.max(valueW, text:MeasureStringX(font, row.value))
	end
	local footer = {}
	if worn then
		footer[#footer + 1] = getText("IGUI_SilencerMoon_WornOut")
	else
		if mounted then
			footer[#footer + 1] = getText("IGUI_SilencerMoon_Condition", tostring(part:getCondition()),
				tostring(part:getConditionMax()))
		end
		footer[#footer + 1] = getText("IGUI_SilencerMoon_AverageLife", tostring(Core.averageShots(tier)))
	end

	local width = worn and 0 or (PAD + labelW + PAD + BAR_W + PAD + valueW + PAD)
	width = math.max(width, text:MeasureStringX(font, title) + PAD * 2)
	for _, line in ipairs(footer) do width = math.max(width, text:MeasureStringX(font, line) + PAD * 2) end
	width = math.max(width, self:getWidth())
	local extra = 4 + lineH * (1 + #rows + #footer) + 4
	local baseH = self:getHeight()
	local height = baseH + extra
	local core = getCore()
	self:setX(math.max(0, math.min(self:getX(), core:getScreenWidth() - width - 1)))
	self:setY(math.max(0, math.min(self:getY(), core:getScreenHeight() - height - 1)))
	self:setWidth(width)
	self:setHeight(height)
	local bg, border = self.backgroundColor, self.borderColor
	self:drawRect(0, baseH, width, extra, bg.a, bg.r, bg.g, bg.b)
	self:drawRectBorder(0, baseH, width, extra, border.a, border.r, border.g, border.b)

	local y = baseH + 4
	self:drawText(title, PAD, y, 1, 1, 1, 1, font)
	y = y + lineH
	local barX = PAD + labelW + PAD
	local barH = math.max(4, lineH - 6)
	for _, row in ipairs(rows) do
		self:drawText(row.label, PAD, y, 0.9, 0.9, 0.9, 1, font)
		drawBar(self, barX, y + (lineH - barH) / 2, barH, row)
		self:drawText(row.value, barX + BAR_W + PAD, y, 1, 1, 1, 1, font)
		y = y + lineH
	end
	for _, line in ipairs(footer) do
		self:drawText(line, PAD, y, 0.8, 0.8, 0.8, 1, font)
		y = y + lineH
	end
end

local function install()
	if Tooltip.originalNew or not ISToolTipInv then return end
	Tooltip.originalNew = ISToolTipInv.new
	ISToolTipInv.new = function(class, item)
		local tooltip = Tooltip.originalNew(class, item)
		local previous = tooltip.render
		tooltip.render = function(self)
			if previous and previous ~= ISToolTipInv.render then previous(self) else ISToolTipInv.render(self) end
			-- a failure is written once and our lines stop for the session: the game's tooltip always stays
			if Tooltip.failed then return end
			local ok, err = pcall(function()
				local tier, part, mounted = Tooltip.subject(self.item)
				if tier then render(self, tier, part, mounted) end
			end)
			if not ok then
				Tooltip.failed = true
				print("[SilencerMoon] tooltip: " .. tostring(err))
			end
		end
		return tooltip
	end
end

install()

return Tooltip
