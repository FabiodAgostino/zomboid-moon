-- JukeboxMoon: the admins' window to make CDs (FR-12), the button "Jukebox" of the ZomBOT window (an "extra" of
-- ZomBotMenu, client/ZomBotMenu.lua, the same file in every Moon mod). Without ZomBOT (Moon), as in a single-player
-- test, a click on "ZomBOT" opens it directly (a "main" of the lowest priority). The server checks the role again and
-- makes at most Core.SPAWN_MAX CDs at a time, only of albums that are not archived.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Player"

if JukeboxMoon.Admin then return JukeboxMoon.Admin end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Player = JukeboxMoon.Player

local Admin = {}
JukeboxMoon.Admin = Admin

Admin.WIDTH = 460
Admin.HEIGHT = 420
local PAD = 10

-- "Estate 1993 - Artisti vari (1993), 3 brani"
function Admin.albumText(album)
	local text = tostring(album.title)
	if album.artist and album.artist ~= "" then text = text .. " - " .. tostring(album.artist) end
	if album.year then text = text .. " (" .. tostring(album.year) .. ")" end
	text = text .. ", " .. getText("IGUI_JukeboxMoon_Tracks", tostring(#album.tracks))
	if album.media then text = text .. " - " .. getText("IGUI_JukeboxMoon_GameCD") end
	return text
end

JukeboxMoonAdminWindow = ISCollapsableWindow:derive("JukeboxMoonAdminWindow")

function JukeboxMoonAdminWindow:new(x, y)
	local o = ISCollapsableWindow.new(self, x, y, Admin.WIDTH, Admin.HEIGHT)
	o:setTitle(getText("IGUI_JukeboxMoon_AdminTitle"))
	o.resizable = false
	o.count = 1
	o.noticeText = nil
	o.noticeUntil = 0
	return o
end

function JukeboxMoonAdminWindow:createChildren()
	ISCollapsableWindow.createChildren(self)
	local th = self:titleBarHeight()
	local small = getTextManager():getFontHeight(UIFont.Small)
	local buttonH = small + 8
	self.top = th + PAD
	local listTop = self.top + small + PAD
	local bottom = self.height - PAD * 3 - buttonH * 2

	self.list = ISScrollingListBox:new(PAD, listTop, self.width - PAD * 2, bottom - listTop)
	self.list:initialise()
	self.list:instantiate()
	self.list.itemheight = small + 6
	self.list.font = UIFont.Small
	self.list.drawBorder = true
	self:addChild(self.list)
	for _, album in ipairs(Catalog.activeAlbums()) do
		self.list:addItem(Admin.albumText(album), album)
	end

	self.countY = bottom + PAD
	self.slider = ISSliderPanel:new(self.width - PAD - 200, self.countY + 2, 200, buttonH - 4, self,
		JukeboxMoonAdminWindow.onCount)
	self.slider:initialise()
	self.slider:instantiate()
	self.slider:setValues(1, Core.SPAWN_MAX, 1, 5, true)
	self.slider:setCurrentValue(1, true)
	self:addChild(self.slider)

	local y = self.countY + buttonH + PAD
	self.make = ISButton:new(PAD, y, self.width - PAD * 2, buttonH, getText("IGUI_JukeboxMoon_Make"), self,
		JukeboxMoonAdminWindow.onMake)
	self.make:initialise()
	self.make:instantiate()
	self:addChild(self.make)
end

function JukeboxMoonAdminWindow:onCount(value)
	self.count = math.floor(tonumber(value) or 1)
end

function JukeboxMoonAdminWindow:onMake()
	local row = self.list.items[self.list.selected]
	if not row then return end
	Player.send("spawn", { album = row.item.key, count = self.count })
end

function JukeboxMoonAdminWindow:update()
	ISCollapsableWindow.update(self)
	self.make:setEnable(self.list.items[self.list.selected] ~= nil)
end

function JukeboxMoonAdminWindow:render()
	ISCollapsableWindow.render(self)
	if self.isCollapsed then return end
	local text = Catalog.available() and getText("IGUI_JukeboxMoon_AdminPick")
		or getText("IGUI_JukeboxMoon_Status_NoCatalog")
	self:drawText(text, PAD, self.top, 0.9, 0.9, 0.9, 1, UIFont.Small)
	self:drawText(getText("IGUI_JukeboxMoon_Count", tostring(self.count)), PAD, self.countY + 2, 0.85, 0.85, 0.85, 1,
		UIFont.Small)
	if self.noticeText and getTimestampMs() < self.noticeUntil then
		self:drawTextRight(self.noticeText, self.width - PAD, self.top, 0.6, 0.95, 0.6, 1, UIFont.Small)
	end
end

function JukeboxMoonAdminWindow:close()
	ISCollapsableWindow.close(self)
	self:removeFromUIManager()
	if Admin.instance == self then Admin.instance = nil end
end

function Admin.open()
	if Admin.instance then
		Admin.instance:bringToTop()
		return
	end
	local x = getCore():getScreenWidth() / 2 - Admin.WIDTH / 2
	local y = getCore():getScreenHeight() / 2 - Admin.HEIGHT / 2
	local window = JukeboxMoonAdminWindow:new(x, y)
	window:initialise()
	window:addToUIManager()
	Admin.instance = window
end

table.insert(Player.listeners, function(kind, data)
	local window = Admin.instance
	if not window or kind ~= "notice" then return end
	if data.what == "spawned" then
		window.noticeText = getText("IGUI_JukeboxMoon_Notice_spawned", tostring(data.count or 0))
	else
		window.noticeText = getText("IGUI_JukeboxMoon_Notice_" .. tostring(data.what))
	end
	window.noticeUntil = getTimestampMs() + 5000
end)

-- the ZomBOT menu
ZomBotMenu = ZomBotMenu or {}
ZomBotMenu.defs = ZomBotMenu.defs or {}
table.insert(ZomBotMenu.defs, {
	kind = "extra", id = "jukeboxmoon", order = 65,
	available = function(player, ctx) return Core.isAdmin(player or getPlayer()) end,
	label = function(ctx) return getText("IGUI_JukeboxMoon_AdminButton") end,
	onClick = function(ctx) Admin.open() end,
})
table.insert(ZomBotMenu.defs, {
	kind = "main", id = "jukeboxmoon", order = 95,
	available = function(player, ctx) return Core.isAdmin(player or getPlayer()) end,
	open = function(ctx) Admin.open() end,
})

return Admin
