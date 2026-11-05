-- SilencerMoon: the admins' window, "ZomBOT" > "Silenziatori" (05/11/2026, the user: the restore goes in the ZomBOT
-- menu, as a "Silenziatori" button opening a window with all the settings).
--
-- The button is an "extra" of ZomBotMenu (client/ZomBotMenu.lua, the same file in every Moon mod): the main window of
-- ZomBOT for an admin (Admin-Scorte's list of bases, in ZomBOT (Moon)) shows it. Without ZomBOT (Moon), as in a
-- single-player test, a click on "ZomBOT" opens this window directly (a "main" of the lowest priority).
--
-- The window shows the values of the three kinds of suppressor (fixed in the mod: Core.TIERS) and the restore before
-- the mod leaves the server (shared/SilencerMoon/Restore.lua): its state, how many weapons it has fixed, the switch
-- (turning it on asks first) and "Aggiorna". The server decides and checks the role again; its answers show in the
-- window and, for a change, over the admin's head. Clients keep a copy of the switch (the world's mod data the server
-- transmits), so the game's "Migliora" menu stops offering SilencerMoon suppressors while the restore is on.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISModalDialog"
require "SilencerMoon/Core"
require "SilencerMoon/Restore"
require "SilencerMoon/Shot"
if SilencerMoon.Admin then return SilencerMoon.Admin end

local Core = SilencerMoon.Core
local Restore = SilencerMoon.Restore
local MODULE = SilencerMoon.Shot.COMMAND_MODULE

local Admin = {}
SilencerMoon.Admin = Admin

Admin.TIER_ORDER = { "oilfilter", "copper", "ballistic" }
Admin.WIDTH = 560

local PAD = 10

local function fontHeight(font)
	return getTextManager():getFontHeight(font)
end

local function measure(font, text)
	return getTextManager():MeasureStringX(font, text)
end

-- `text` in lines no wider than `width`. Only plain spaces split words: patterns depend on the locale outside the game.
function Admin.wrap(text, width, widthOf)
	local lines, line = {}, ""
	local rest = tostring(text or "")
	while true do
		local space = string.find(rest, " ", 1, true)
		local word = space and string.sub(rest, 1, space - 1) or rest
		local candidate = line == "" and word or (line .. " " .. word)
		if line ~= "" and widthOf(candidate) > width then
			lines[#lines + 1] = line
			line = word
		else
			line = candidate
		end
		if not space then break end
		rest = string.sub(rest, space + 1)
	end
	if line ~= "" then lines[#lines + 1] = line end
	return lines
end

-- One row of the values table: the kind and its four values as the window writes them.
function Admin.valuesRow(tier)
	return {
		name = getText("IGUI_SilencerMoon_TierName_" .. tier.id),
		"-" .. Core.percentText(1 - tier.radius) .. "%",
		"-" .. Core.percentText(1 - tier.range) .. "%",
		"-" .. Core.percentText(1 - tier.damage) .. "%",
		getText("IGUI_SilencerMoon_Shots", tostring(Core.averageShots(tier))),
	}
end

local function notify(text, bad)
	local player = getPlayer()
	if not player or not text then return end
	pcall(function()
		if bad then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addGoodText(player, text) end
	end)
end

-- To the server (in single player straight to the server's handler, loaded in the same game).
function Admin.send(command)
	local player = getPlayer()
	if not player then return end
	if isClient() then
		sendClientCommand(player, MODULE, command, {})
	elseif SilencerMoon.onRestoreCommand then
		SilencerMoon.onRestoreCommand(player, command)
	end
end

---------------------------------------------------------------- the window

SilencerMoonAdminWindow = ISCollapsableWindow:derive("SilencerMoonAdminWindow")

function SilencerMoonAdminWindow:new(x, y, width, height)
	local o = ISCollapsableWindow.new(self, x, y, width, height)
	o:setTitle(getText("IGUI_SilencerMoon_AdminTitle"))
	o:setResizable(false)
	o.status, o.statusBad = nil, false
	o.fixed = nil -- weapons fixed so far, from the server's last answer (else the copy of the world's mod data)
	return o
end

function SilencerMoonAdminWindow:button(x, y, w, title, onClick)
	local button = ISButton:new(x, y, w, Admin.buttonHeight(), title, self, onClick)
	button:initialise()
	button:instantiate()
	self:addChild(button)
	return button
end

function Admin.buttonHeight()
	return math.max(25, fontHeight(UIFont.Small) + 8)
end

function SilencerMoonAdminWindow:createChildren()
	ISCollapsableWindow.createChildren(self)
	local h = Admin.buttonHeight()
	local y = self.height - h - PAD
	local w = (self.width - PAD * 4) / 3
	self.switchButton = self:button(PAD, y, w, "", SilencerMoonAdminWindow.onSwitch)
	self.queryButton = self:button(PAD * 2 + w, y, w, getText("IGUI_SilencerMoon_Refresh"),
		SilencerMoonAdminWindow.onQuery)
	-- not closeButton: that is the X of the title bar in ISCollapsableWindow
	self.doneButton = self:button(PAD * 3 + w * 2, y, w, getText("IGUI_SilencerMoon_Close"),
		SilencerMoonAdminWindow.close)
	self:refresh()
end

function SilencerMoonAdminWindow:refresh()
	if not self.switchButton then return end
	if Restore.active() then
		self.switchButton:setTitle(getText("IGUI_SilencerMoon_RestoreOff"))
		self.switchButton:enableAcceptColor()
	else
		self.switchButton:setTitle(getText("IGUI_SilencerMoon_RestoreOn"))
		self.switchButton:enableCancelColor()
	end
end

-- The lines of the restore's explanation, wrapped to the window.
function SilencerMoonAdminWindow:explanation()
	if not self.explainLines then
		self.explainLines = Admin.wrap(getText("IGUI_SilencerMoon_RestoreExplain"), self.width - PAD * 2,
			function(t) return measure(UIFont.Small, t) end)
	end
	return self.explainLines
end

function SilencerMoonAdminWindow:render()
	ISCollapsableWindow.render(self)
	local small, medium = fontHeight(UIFont.Small), fontHeight(UIFont.Medium)
	local y = self:titleBarHeight() + PAD
	-- the values of the three kinds
	self:drawText(getText("IGUI_SilencerMoon_ValuesTitle"), PAD, y, 1, 1, 1, 1, UIFont.Medium)
	y = y + medium + 4
	local columns = { PAD, PAD + 180, PAD + 270, PAD + 360, PAD + 450 }
	local header = { getText("IGUI_SilencerMoon_ColumnKind"), getText("IGUI_SilencerMoon_ColumnNoise"),
		getText("IGUI_SilencerMoon_ColumnRange"), getText("IGUI_SilencerMoon_ColumnDamage"),
		getText("IGUI_SilencerMoon_ColumnLife") }
	for i, text in ipairs(header) do self:drawText(text, columns[i], y, 0.7, 0.7, 0.7, 1, UIFont.Small) end
	y = y + small + 2
	for _, id in ipairs(Admin.TIER_ORDER) do
		local row = Admin.valuesRow(Core.TIERS[id])
		self:drawText(row.name, columns[1], y, 1, 1, 1, 1, UIFont.Small)
		for i = 1, 4 do self:drawText(row[i], columns[i + 1], y, 1, 1, 1, 1, UIFont.Small) end
		y = y + small + 2
	end
	self:drawText(getText("IGUI_SilencerMoon_ValuesFixed"), PAD, y, 0.6, 0.6, 0.6, 1, UIFont.Small)
	y = y + small + PAD * 2
	-- the restore
	self:drawText(getText("IGUI_SilencerMoon_RestoreTitle"), PAD, y, 1, 1, 1, 1, UIFont.Medium)
	y = y + medium + 4
	local data = Restore.data() or {}
	local fixed = self.fixed or tonumber(data.fixed) or 0
	if Restore.active() then
		self:drawText(getText("IGUI_SilencerMoon_RestoreStateOn", tostring(fixed)), PAD, y, 1, 0.75, 0.3, 1,
			UIFont.Small)
	else
		self:drawText(getText("IGUI_SilencerMoon_RestoreStateOff"), PAD, y, 0.4, 0.85, 0.4, 1, UIFont.Small)
	end
	y = y + small + 6
	for _, line in ipairs(self:explanation()) do
		self:drawText(line, PAD, y, 0.8, 0.8, 0.8, 1, UIFont.Small)
		y = y + small
	end
	-- the server's last answer, over the buttons
	if self.status and self.status ~= "" then
		local r, g, b = 0.4, 0.85, 0.4
		if self.statusBad then r, g, b = 0.9, 0.3, 0.3 end
		self:drawText(self.status, PAD, self.height - Admin.buttonHeight() - PAD - small - 4, r, g, b, 1, UIFont.Small)
	end
end

-- The height the window needs for its texts.
function Admin.height(width)
	local small, medium = fontHeight(UIFont.Small), fontHeight(UIFont.Medium)
	local lines = #Admin.wrap(getText("IGUI_SilencerMoon_RestoreExplain"), width - PAD * 2,
		function(t) return measure(UIFont.Small, t) end)
	return 26 + PAD + medium + 4 + (small + 2) * 4 + small + PAD * 2 + medium + 4 + small + 6 + lines * small
		+ PAD + small + 4 + Admin.buttonHeight() + PAD * 2
end

function SilencerMoonAdminWindow:onSwitch()
	if Restore.active() then
		Admin.send(Restore.COMMAND_STOP)
		return
	end
	local player = getPlayer()
	local modal = ISModalDialog:new(getCore():getScreenWidth() / 2 - 200, getCore():getScreenHeight() / 2 - 90, 400, 180,
		getText("IGUI_SilencerMoon_RestoreConfirm"), true, self, SilencerMoonAdminWindow.onConfirm,
		player and player:getPlayerNum() or 0)
	modal:initialise()
	modal:addToUIManager()
end

function SilencerMoonAdminWindow:onConfirm(button)
	if button.internal == "YES" then Admin.send(Restore.COMMAND_START) end
end

function SilencerMoonAdminWindow:onQuery()
	Admin.send(Restore.COMMAND_QUERY)
end

function SilencerMoonAdminWindow:close()
	self:setVisible(false)
	self:removeFromUIManager()
	if Admin.window == self then Admin.window = nil end
end

-- One window at a time, in the middle of the screen; it asks the server how the restore stands.
function Admin.open()
	if Admin.window then Admin.window:close() end
	local width = Admin.WIDTH
	local height = Admin.height(width)
	local x = (getCore():getScreenWidth() - width) / 2
	local y = (getCore():getScreenHeight() - height) / 2
	local window = SilencerMoonAdminWindow:new(x, y, width, height)
	window:initialise()
	window:addToUIManager()
	Admin.window = window
	if isClient() then Admin.send(Restore.COMMAND_QUERY) end
	return window
end

---------------------------------------------------------------- answers and the switch's copy

-- The server's answer (in single player called directly by server/SilencerMoon/RestoreServer.lua).
function SilencerMoon.onRestoreReply(args)
	local window = Admin.window
	if args.refused then
		notify(getText("IGUI_SilencerMoon_RestoreRefused"), true)
		if window then window.status, window.statusBad = getText("IGUI_SilencerMoon_RestoreRefused"), true end
		return
	end
	-- the answer carries the state: the copy of the switch follows it at once (the transmit may come later)
	local data = ModData.getOrCreate(Restore.DATA)
	data.restoring = args.active == true
	data.fixed = tonumber(args.fixed) or tonumber(data.fixed) or 0
	Restore.cache = nil
	local text = nil
	if not args.query then
		if args.active then
			text = getText("IGUI_SilencerMoon_RestoreStarted", tostring(args.fixedNow or 0), tostring(args.fixed or 0))
		else
			text = getText("IGUI_SilencerMoon_RestoreStopped")
		end
		notify(text)
	end
	if window then
		window.fixed = tonumber(args.fixed)
		if text then window.status, window.statusBad = text, false end
		window:refresh()
	end
end

local function onServerCommand(module, command, args)
	if module == MODULE and command == Restore.REPLY then SilencerMoon.onRestoreReply(args or {}) end
end

local function onReceiveGlobalModData(key, data)
	if key == Restore.DATA and type(data) == "table" then
		ModData.add(key, data)
		Restore.cache = nil
		if Admin.window then Admin.window:refresh() end
	end
end

local function onGameStart()
	if isClient() then ModData.request(Restore.DATA) end
end

---------------------------------------------------------------- in the ZomBOT menu

local function isAdmin(player)
	return Restore.isAdmin(player or getPlayer())
end

ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}
table.insert(ZomBotMenu.defs, {
	kind = "extra", id = "silencermoon", order = 60,
	available = function(player, ctx) return isAdmin(player) end,
	label = function(ctx) return getText("IGUI_SilencerMoon_AdminButton") end,
	onClick = function(ctx) Admin.open() end,
})
-- only when no other mod offers a main window (ZomBOT (Moon) offers one to everyone)
table.insert(ZomBotMenu.defs, {
	kind = "main", id = "silencermoon", order = 90,
	available = function(player, ctx) return isAdmin(player) end,
	open = function(ctx) Admin.open() end,
})

if not SilencerMoon.adminAdded then
	SilencerMoon.adminAdded = true
	local guarded = SilencerMoon.Shot.guarded
	Events.OnServerCommand.Add(guarded("Admin.OnServerCommand", onServerCommand))
	Events.OnReceiveGlobalModData.Add(guarded("Admin.OnReceiveGlobalModData", onReceiveGlobalModData))
	Events.OnGameStart.Add(guarded("Admin.OnGameStart", onGameStart))
end

return Admin
