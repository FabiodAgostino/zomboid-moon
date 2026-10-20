require "simple-suppressors/diagnostics"
require "simple-suppressors/compatibility"
local Release = require "simple-suppressors/release"
-- Shared effects are loaded on both server and clients so sound state agrees.
require "simple-suppressors/suppressoreffects"
SimpleSuppressorsDiagnostics.loaded("SimpleSuppressors.Client")
SimpleSuppressorsDiagnostics.loaded("SimpleSuppressors.Client.Release." .. tostring(Release.version))
SimpleSuppressorsDiagnostics.info("SimpleSuppressors.Client", "entrypoint", "loaded")
require "TimedActions/ISBaseTimedAction"
require "ISUI/ISInventoryPane"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISToolTipInv"

SimpleSuppressorsConditionTooltip = SimpleSuppressorsConditionTooltip or {}

local function isSimpleSuppressorsPart(part)
	local known = SimpleSuppressorsCompatibility.isSuppressor and SimpleSuppressorsCompatibility.isSuppressor(part)
	if known then return true end
	-- Compatibility modules register their cartridge families during shared-script
	-- startup. A tooltip can be requested before that registration reaches the
	-- client, so recognise an already-mounted part by its stable module/type too.
	local ok, fullType, partType = pcall(function()
		return part and part:getFullType(), part and part:getPartType()
	end)
	return ok and type(fullType) == "string"
		and string.find(fullType, "SimpleSuppressors", 1, true) == 1
		and (partType == "Suppressor" or string.find(fullType, ".Suppressor_", 1, true) ~= nil)
end

local function fallbackAttachedSuppressor(weapon)
	for _, slot in ipairs({ SimpleSuppressorsCompatibility.PART_TYPE, "Canon" }) do
		local ok, part = pcall(function() return weapon:getWeaponPart(slot) end)
		if ok and isSimpleSuppressorsPart(part) then return part end
	end
	local ok, parts = pcall(function() return weapon:getAllWeaponParts() end)
	if not ok or not parts then return nil end
	for index = 0, parts:size() - 1 do
		local part = parts:get(index)
		if isSimpleSuppressorsPart(part) then return part end
	end
	return nil
end

local function attachedSuppressor(weapon)
	local ok, ranged = pcall(function()
		return weapon and instanceof(weapon, "HandWeapon") and weapon:isRanged()
	end)
	if not ok or not ranged then return nil end
	local part = SimpleSuppressorsCompatibility.getAttachedSuppressor(weapon) or fallbackAttachedSuppressor(weapon)
	if not part then return nil end
	return isSimpleSuppressorsPart(part) and part or nil
end

local function compatibilityLine(weapon)
	local state, caliber = SimpleSuppressorsCompatibility.weaponStatus(weapon)
	if state == "supported" then
		return getText("IGUI_SimpleSuppressors_CompatibilitySupported", caliber)
	elseif state == "disabled" then
		return getText("IGUI_SimpleSuppressors_CompatibilityDisabled", caliber)
	elseif state == "unsupported" then
		return getText("IGUI_SimpleSuppressors_CompatibilityUnsupported")
	elseif state == "unknown" then
		return getText("IGUI_SimpleSuppressors_CompatibilityUnknown")
	end
	return nil
end

function SimpleSuppressorsConditionTooltip.lineForWeapon(weapon)
	local part = attachedSuppressor(weapon)
	if not part then return nil end
	local ok, condition, maximum = pcall(function()
		return part:getCondition(), part:getConditionMax()
	end)
	if not ok or type(condition) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then return nil end
	local percent = math.floor(math.max(0, math.min(1, condition / maximum)) * 100 + 0.5)
	if condition <= 0 then return getText("IGUI_SimpleSuppressors_SuppressorWornOut") end
	return getText("IGUI_SimpleSuppressors_SuppressorDurability", tostring(condition), tostring(maximum), tostring(percent))
end

function SimpleSuppressorsConditionTooltip.linesForWeapon(weapon)
	local part = attachedSuppressor(weapon)
	local conditionLine = SimpleSuppressorsConditionTooltip.lineForWeapon(weapon)
	if not part or not conditionLine then
		local line = compatibilityLine(weapon)
		return line and { line } or nil
	end
	local caliber = SimpleSuppressorsCompatibility.getPartCaliber(part) or "?"
	local oilFilter = SimpleSuppressorsCompatibility.isOilFilterSuppressor(part)
	local vars = SandboxVars and SandboxVars.SimpleSuppressors or {}
	local legacy = tonumber(vars.SoundRadiusReduction)
	local range = oilFilter and (tonumber(vars.OilFilterSoundRadiusReduction) or legacy or 35)
		or (tonumber(vars.MachinedSoundRadiusReduction) or legacy or 25)
	local lines = {
		conditionLine,
		getText("IGUI_SimpleSuppressors_SuppressorStatus", caliber,
			oilFilter and getText("IGUI_SimpleSuppressors_OilFilter") or getText("IGUI_SimpleSuppressors_Machined"),
			tostring(range)),
	}
	local shotWear, shotsToBreak
	if SimpleSuppressorsEffects and SimpleSuppressorsEffects.getDurabilityProgress then
		shotWear, shotsToBreak = SimpleSuppressorsEffects.getDurabilityProgress(part)
	end
	if shotWear ~= nil and shotsToBreak then
		lines[#lines + 1] = getText("IGUI_SimpleSuppressors_SuppressorShotWear",
			string.format("%.1f", shotWear), tostring(shotsToBreak))
	end
	if vars.EnableSuppressorHeat ~= false then
		local heat = SimpleSuppressorsEffects and SimpleSuppressorsEffects.getHeat(part) or 0
		local state = heat >= 70 and getText("IGUI_SimpleSuppressors_HeatHot")
			or heat >= 25 and getText("IGUI_SimpleSuppressors_HeatWarm")
			or getText("IGUI_SimpleSuppressors_HeatCool")
		local impact = vars.HeatAcceleratesWear == false
			and getText("IGUI_SimpleSuppressors_HeatVisualOnly")
			or heat > 25 and getText("IGUI_SimpleSuppressors_HeatVisualWear")
			or getText("IGUI_SimpleSuppressors_HeatVisualNormalWear")
		lines[#lines + 1] = getText("IGUI_SimpleSuppressors_HeatVisual", state, impact)
	end
	return lines
end

-- Keep the shared renderer owned by the game and other UI mods.  A tooltip
-- instance for a suppressed weapon gets a small private renderer which first
-- calls the current shared renderer, then extends only that instance.  This
-- avoids global wrapper chains while preserving other mods' weapon tooltips.
local function appendSuppressorLines(self, lines)
	if not lines or (ISContextMenu and ISContextMenu.instance and ISContextMenu.instance.visibleCheck) then return end
	local font = UIFont.Small
	local lineHeight = getTextManager():getFontHeight(font)
	local extraHeight = lineHeight * #lines + 8
	local width = self:getWidth()
	for _, line in ipairs(lines) do
		width = math.max(width, getTextManager():MeasureStringX(font, line) + 16)
	end
	local baseHeight = self:getHeight()
	local height = baseHeight + extraHeight
	local core = getCore()
	local x = math.max(0, math.min(self:getX(), core:getScreenWidth() - width - 1))
	local y = math.max(0, math.min(self:getY(), core:getScreenHeight() - height - 1))
	self:setX(x)
	self:setY(y)
	self:setWidth(width)
	self:setHeight(height)
	self:drawRect(0, baseHeight, width, extraHeight, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
	self:drawRectBorder(0, baseHeight, width, extraHeight, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
	local textY = baseHeight + 4
	for _, line in ipairs(lines) do
		self:drawText(line, 8, textY, 1, 1, 1, 1, font)
		textY = textY + lineHeight
	end
end

local function installConditionTooltip()
	if not ISToolTipInv or SimpleSuppressorsConditionTooltip.originalNew then return end
	SimpleSuppressorsConditionTooltip.originalNew = ISToolTipInv.new
	ISToolTipInv.new = function(class, item)
		local tooltip = SimpleSuppressorsConditionTooltip.originalNew(class, item)
		-- [moon] every tooltip, not only one created over a suppressed weapon: the game makes one tooltip per
		-- inventory panel and then reuses it with setItem() for whatever the mouse is on, so before the lines
		-- showed only in a panel whose first tooltip happened to be a suppressed weapon. linesForWeapon() answers
		-- nil for anything that is not a firearm.
		tooltip.render = function(self)
			-- Resolve this at render time so any legitimate renderer supplied by
			-- another mod remains in control of the base tooltip.
			ISToolTipInv.render(self)
			appendSuppressorLines(self, SimpleSuppressorsConditionTooltip.linesForWeapon(self.item))
		end
		return tooltip
	end
end

installConditionTooltip()

-- Timed actions live in shared/ so they exist on the server too (required for
-- multiplayer NetTimedAction mirroring); this just ensures they are loaded.
require "simple-suppressors/suppressoractions"

local function attachSuppressor(weapon, player, part)
	ISInventoryPaneContextMenu.transferIfNeeded(player, weapon)
	ISInventoryPaneContextMenu.transferIfNeeded(player, part)
	ISTimedActionQueue.add(ISAttachSuppressor:new(player, weapon, part))
end

local function removeSuppressor(weapon, player, partType)
	ISInventoryPaneContextMenu.transferIfNeeded(player, weapon)
	ISTimedActionQueue.add(ISRemoveSuppressor:new(player, weapon, partType))
end

if not SimpleSuppressorsGenericAttachMenuRegistered then
	local function isSuppressorType(fullType)
		return string.find(fullType, "SimpleSuppressors.Suppressor_", 1, true) == 1
	end

	Events.OnFillInventoryObjectContextMenu.Add(SimpleSuppressorsDiagnostics.guard("SimpleSuppressors.Client", "GenericAttachMenu", function(playerNum, context, items)
		local player = getSpecificPlayer(playerNum)
		if not player then return end
		local weapon = ISInventoryPane.getActualItems(items)[1]
		if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then return end

		local suppressor = SimpleSuppressorsCompatibility.getAttachedSuppressor(weapon)

		local submenu = context:getNew(context)
		local hasOption = false

		-- Remove: only our own suppressors are offered for removal here.
		if suppressor then
			local option = submenu:addOption(getText("ContextMenu_SimpleSuppressors_Remove", suppressor:getDisplayName()),
				weapon, removeSuppressor, player, suppressor:getPartType())
			-- [moon] without a screwdriver the removal is refused: say so here instead of a silent cancel
			if not ISRemoveSuppressor.hasScrewdriver(player) then
				option.notAvailable = true
				local tooltip = ISInventoryPaneContextMenu.addToolTip()
				tooltip.description = getText("ContextMenu_SimpleSuppressors_NeedScrewdriver")
				option.toolTip = tooltip
			end
			hasOption = true
		end

		-- Attach: compatible suppressors in inventory. Canon accessories are
		-- independent, while fitting another suppressor offers a direct swap.
		local parts = player:getInventory():getAllEvalRecurse(function(item)
			return isSuppressorType(item:getFullType())
				and SimpleSuppressorsCompatibility.canAttachDynamic(player, weapon, item)
		end)
		if parts and not parts:isEmpty() then
			local seen = {}
			for index = 0, parts:size() - 1 do
				local part = parts:get(index)
				local fullType = part:getFullType()
				if not seen[fullType] then
					seen[fullType] = true
					local label = getText("ContextMenu_SimpleSuppressors_Attach", part:getDisplayName())
					if suppressor then
						label = getText("ContextMenu_SimpleSuppressors_Replace", part:getDisplayName(), suppressor:getDisplayName())
					end
					local option = submenu:addOption(label, weapon, attachSuppressor, player, part)
					option.itemForTexture = part
					hasOption = true
				end
			end
		end

		if not hasOption then return end
		local root = context:addOption(getText("ContextMenu_SimpleSuppressors_Menu"), items, nil)
		context:addSubMenu(root, submenu)
	end))
	SimpleSuppressorsGenericAttachMenuRegistered = true
end
