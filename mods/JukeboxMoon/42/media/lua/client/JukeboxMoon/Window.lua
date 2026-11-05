-- JukeboxMoon: the jukebox's window (FR-01, FR-03, FR-04). It shows the state, what plays and where it is, the tracks
-- of the CDs inside, and sends the buttons to the server, which decides. Opening it never starts the music. The CDs go
-- in and out with the game's loot window: the jukebox is a container.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTickBox"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "JukeboxMoon/Core"
require "JukeboxMoon/Catalog"
require "JukeboxMoon/Playlist"
require "JukeboxMoon/Box"
require "JukeboxMoon/Player"

if JukeboxMoon.Window then return JukeboxMoon.Window end

local Core = JukeboxMoon.Core
local Catalog = JukeboxMoon.Catalog
local Playlist = JukeboxMoon.Playlist
local Box = JukeboxMoon.Box
local Player = JukeboxMoon.Player

local Window = {}
JukeboxMoon.Window = Window

Window.WIDTH = 540
Window.HEIGHT = 470
Window.NOTICE_MS = 5000
Window.SHUFFLE_HOLD_MS = 1500

local PAD = 10

------------------------------------------------------------------------------------------------- plain helpers

-- The status line's key: what the jukebox is doing, or why it cannot play.
-- view = { problem, enabled, converted, on, trackKnown, power, cds }
function Window.statusKey(view)
	if view.problem == "nocatalog" then return "IGUI_JukeboxMoon_Status_NoCatalog" end
	if view.problem == "update" then return "IGUI_JukeboxMoon_Status_Update" end
	if not view.enabled then return "IGUI_JukeboxMoon_Status_Off" end
	if not view.converted then return "IGUI_JukeboxMoon_Status_Preparing" end
	if view.on then
		if not view.trackKnown then return "IGUI_JukeboxMoon_Status_Unavailable" end
		return "IGUI_JukeboxMoon_Status_Playing"
	end
	if not view.power then return "IGUI_JukeboxMoon_Status_NoPower" end
	if view.cds == 0 then return "IGUI_JukeboxMoon_Status_NoCD" end
	return "IGUI_JukeboxMoon_Status_Ready"
end

-- "Primo brano - Artista A" for a track (the album's artist when the track has none)
function Window.trackLine(track)
	if not track then return "" end
	local artist = track.artist
	if (artist == nil or artist == "") and track.album then artist = track.album.artist end
	if artist and artist ~= "" then return tostring(track.title) .. " - " .. tostring(artist) end
	return tostring(track.title)
end

-- "Estate 1993, traccia 2"
function Window.albumLine(track)
	if not track or not track.album then return "" end
	return getText("IGUI_JukeboxMoon_AlbumTrack", tostring(track.album.title), tostring(track.n or "?"))
end

-- the list's row: "2. Secondo brano - Artista B  (Estate 1993)"
function Window.rowText(entry)
	local track = Catalog.track(entry.track)
	if not track then return getText("IGUI_JukeboxMoon_UnknownTrack") end
	local album = track.album and track.album.title or ""
	return string.format("%d. %s  (%s)", math.floor(track.n or 0), Window.trackLine(track), tostring(album))
end

------------------------------------------------------------------------------------------------- the window

JukeboxMoonWindow = ISCollapsableWindow:derive("JukeboxMoonWindow")

function JukeboxMoonWindow:new(x, y, bx, by, bz)
	local o = ISCollapsableWindow.new(self, x, y, Window.WIDTH, Window.HEIGHT)
	o:setTitle(getText("IGUI_JukeboxMoon_Title"))
	o.resizable = false
	o.bx, o.by, o.bz = bx, by, bz
	o.key = Core.key(bx, by, bz)
	o.entries = {}
	o.signature = nil
	o.noticeText = nil
	o.noticeUntil = 0
	o.lastRefresh = 0
	return o
end

function JukeboxMoonWindow:button(x, y, w, title, onClick)
	local h = getTextManager():getFontHeight(UIFont.Small) + 8
	local button = ISButton:new(x, y, w, h, title, self, onClick)
	button:initialise()
	button:instantiate()
	self:addChild(button)
	return button
end

function JukeboxMoonWindow:createChildren()
	ISCollapsableWindow.createChildren(self)
	local th = self:titleBarHeight()
	local small = getTextManager():getFontHeight(UIFont.Small)
	local medium = getTextManager():getFontHeight(UIFont.Medium)
	self.textTop = th + PAD
	local listTop = self.textTop + medium + small * 3 + PAD * 3
	local buttonH = small + 8
	local bottom = self.height - PAD - small * 2 - buttonH * 2 - PAD * 3

	self.list = ISScrollingListBox:new(PAD, listTop, self.width - PAD * 2, bottom - listTop)
	self.list:initialise()
	self.list:instantiate()
	self.list.itemheight = small + 6
	self.list.font = UIFont.Small
	self.list.drawBorder = true
	self.list.window = self
	self.list.doDrawItem = JukeboxMoonWindow.drawRow
	self.list:setOnMouseDoubleClick(self, JukeboxMoonWindow.onRowDoubleClick)
	self:addChild(self.list)

	local y = bottom + PAD
	local w = math.floor((self.width - PAD * 5) / 4)
	self.playButton = self:button(PAD, y, w, getText("IGUI_JukeboxMoon_Play"), JukeboxMoonWindow.onPlay)
	self.stopButton = self:button(PAD * 2 + w, y, w, getText("IGUI_JukeboxMoon_Stop"), JukeboxMoonWindow.onStop)
	self.prevButton = self:button(PAD * 3 + w * 2, y, w, getText("IGUI_JukeboxMoon_Prev"), JukeboxMoonWindow.onPrev)
	self.nextButton = self:button(PAD * 4 + w * 3, y, w, getText("IGUI_JukeboxMoon_Next"), JukeboxMoonWindow.onNext)

	y = y + buttonH + PAD
	self.shuffleBox = ISTickBox:new(PAD, y, 150, buttonH, "", self, JukeboxMoonWindow.onShuffle)
	self.shuffleBox:initialise()
	self.shuffleBox:instantiate()
	self.shuffleBox:addOption(getText("IGUI_JukeboxMoon_Shuffle"))
	self:addChild(self.shuffleBox)

	local volumeLabelW = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_JukeboxMoon_Volume")) + PAD
	self.volumeX = self.width - PAD - 180 - volumeLabelW
	self.volumeY = y
	self.volume = ISSliderPanel:new(self.width - PAD - 180, y + 2, 180, buttonH - 4, self, JukeboxMoonWindow.onVolume)
	self.volume:initialise()
	self.volume:instantiate()
	self.volume:setValues(0, 100, 5, 10, true)
	self.volume:setCurrentValue(math.floor(Player.volume * 100 + 0.5), true)
	self:addChild(self.volume)

	self.hintY = y + buttonH + PAD
end

function JukeboxMoonWindow:object()
	local cell = getCell()
	local square = cell and cell:getGridSquare(self.bx, self.by, self.bz)
	if not square then return nil end
	return (Box.onSquare(square))
end

-- the rows again when the CDs inside changed
function JukeboxMoonWindow:refreshList(object)
	local cds = object and Box.isConverted(object) and Box.cds(object) or {}
	local parts = {}
	for _, cd in ipairs(cds) do parts[#parts + 1] = tostring(cd.id) end
	local signature = table.concat(parts, ",")
	if signature == self.signature then return end
	self.signature = signature
	self.entries = Playlist.build(cds)
	local selected = self.list.selected
	self.list:clear()
	for _, entry in ipairs(self.entries) do
		self.list:addItem(Window.rowText(entry), entry)
	end
	if selected and selected <= #self.entries then self.list.selected = selected end
end

function JukeboxMoonWindow:view(object)
	local state = Player.boxes[self.key]
	local converted = object ~= nil and Box.isConverted(object)
	return {
		problem = Player.problem(),
		enabled = Core.option("Enabled"),
		converted = converted,
		on = state ~= nil and state.on == true,
		trackKnown = state ~= nil and Catalog.track(state.track) ~= nil,
		power = object ~= nil and Box.hasPower(object),
		cds = #self.entries,
	}
end

function JukeboxMoonWindow:update()
	ISCollapsableWindow.update(self)
	local t = getTimestampMs()
	if t - self.lastRefresh < 250 then return end
	self.lastRefresh = t
	local player = getPlayer()
	local object = self:object()
	if not player or player:isDead() then
		self:close()
		return
	end
	-- the server replaces the game's tile with the jukebox: for a moment there may be neither
	if not object then
		self.missingSince = self.missingSince or t
		if t - self.missingSince > 3000 then self:close() end
		return
	end
	self.missingSince = nil
	local dx, dy = player:getX() - (self.bx + 0.5), player:getY() - (self.by + 0.5)
	if dx * dx + dy * dy > (Core.USE_TILES + 3) * (Core.USE_TILES + 3) or math.floor(player:getZ()) ~= self.bz then
		self:close()
		return
	end
	self:refreshList(object)
	local converted = Box.isConverted(object)
	local state = Player.boxes[self.key]
	local shuffle = (state and state.on and state.shuffle) or (converted and Box.settings(object).shuffle) or false
	-- after a click the tick waits for the server's answer instead of jumping back for a moment
	if t >= (self.shuffleHoldUntil or 0) then self.shuffleBox:setSelected(1, shuffle == true) end
	self.shuffleBox:setVisible(Core.option("ShuffleAllowed") == true)
	local ready = converted and Player.problem() == nil and Core.option("Enabled")
	self.playButton:setEnable(ready)
	self.prevButton:setEnable(ready)
	self.nextButton:setEnable(ready)
	self.stopButton:setEnable(converted and state ~= nil and state.on == true)
end

function JukeboxMoonWindow:prerender()
	ISCollapsableWindow.prerender(self)
end

function JukeboxMoonWindow:render()
	ISCollapsableWindow.render(self)
	if self.isCollapsed then return end
	local small = getTextManager():getFontHeight(UIFont.Small)
	local medium = getTextManager():getFontHeight(UIFont.Medium)
	local object = self:object()
	local view = self:view(object)
	local y = self.textTop
	self:drawText(getText(Window.statusKey(view)), PAD, y, 1, 1, 1, 1, UIFont.Medium)
	y = y + medium + PAD
	local state = Player.boxes[self.key]
	if view.on and view.trackKnown then
		local track = Catalog.track(state.track)
		self:drawText(Window.trackLine(track), PAD, y, 0.9, 0.85, 0.6, 1, UIFont.Small)
		self:drawText(Window.albumLine(track), PAD, y + small, 0.75, 0.75, 0.75, 1, UIFont.Small)
		local position = Player.serverNow() - (state.start or 0)
		if position < 0 then position = 0 end
		if position > track.ms then position = track.ms end
		self:drawText(Catalog.clock(position) .. " / " .. Catalog.clock(track.ms), PAD, y + small * 2,
			0.75, 0.75, 0.75, 1, UIFont.Small)
		-- the album's cover (tools/jukebox writes one for every album, drawn when the admin gave none)
		local cover = track.album and track.album.cover and getTexture(track.album.cover)
		if cover then
			local side = medium + small * 3
			self:drawTextureScaled(cover, self.width - PAD - side, self.textTop, side, side, 1, 1, 1, 1)
		end
	elseif state and not state.on and state.reason and state.reason ~= "off" then
		self:drawText(getText("IGUI_JukeboxMoon_Stopped_" .. state.reason), PAD, y, 0.85, 0.6, 0.5, 1, UIFont.Small)
	end
	if self.noticeText and getTimestampMs() < self.noticeUntil then
		self:drawTextRight(self.noticeText, self.width - PAD, self.list.y - small - 4, 0.95, 0.6, 0.4, 1, UIFont.Small)
	end
	if #self.entries == 0 and view.converted then
		self:drawTextCentre(getText("IGUI_JukeboxMoon_Empty"), self.width / 2, self.list.y + self.list.height / 2 - small / 2,
			0.7, 0.7, 0.7, 1, UIFont.Small)
	end
	self:drawText(getText("IGUI_JukeboxMoon_Volume"), self.volumeX, self.volumeY + 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
	self:drawText(getText("IGUI_JukeboxMoon_Hint", tostring(Core.maxCDs())), PAD, self.hintY, 0.65, 0.65, 0.65, 1,
		UIFont.Small)
end

-- a row of the list: the track that plays is marked and lit
function JukeboxMoonWindow.drawRow(list, y, item, alt)
	local window = list.window
	local state = Player.boxes[window.key]
	local entry = item.item
	local playing = state and state.on and entry.cd == state.cd and entry.track == state.track
	if list.selected == item.index then
		list:drawRect(0, y, list:getWidth(), item.height - 1, 0.3, 0.7, 0.35, 0.15)
	end
	list:drawRectBorder(0, y, list:getWidth(), item.height, 0.5, list.borderColor.r, list.borderColor.g, list.borderColor.b)
	local r, g, b = 0.9, 0.9, 0.9
	if playing then r, g, b = 1, 0.85, 0.4 end
	list:drawText((playing and "> " or "   ") .. item.text, 6, y + 3, r, g, b, 1, UIFont.Small)
	return y + item.height
end

function JukeboxMoonWindow:args(extra)
	local args = { x = self.bx, y = self.by, z = self.bz }
	for k, v in pairs(extra or {}) do args[k] = v end
	return args
end

function JukeboxMoonWindow:selectedEntry()
	local row = self.list.items[self.list.selected]
	return row and row.item or nil
end

function JukeboxMoonWindow:onPlay()
	local entry = self:selectedEntry()
	Player.send("play", self:args(entry and { cd = entry.cd, track = entry.track } or nil))
end

function JukeboxMoonWindow:onRowDoubleClick(entry)
	if entry then Player.send("play", self:args({ cd = entry.cd, track = entry.track })) end
end

function JukeboxMoonWindow:onStop() Player.send("stop", self:args()) end
function JukeboxMoonWindow:onPrev() Player.send("prev", self:args()) end
function JukeboxMoonWindow:onNext() Player.send("next", self:args()) end

function JukeboxMoonWindow:onShuffle(index, selected)
	self.shuffleHoldUntil = getTimestampMs() + Window.SHUFFLE_HOLD_MS
	Player.send("shuffle", self:args({ on = selected == true }))
end

function JukeboxMoonWindow:onVolume(value)
	Player.setVolume((tonumber(value) or 0) / 100)
end

function JukeboxMoonWindow:notice(what)
	self.noticeText = getText("IGUI_JukeboxMoon_Notice_" .. tostring(what))
	self.noticeUntil = getTimestampMs() + Window.NOTICE_MS
end

function JukeboxMoonWindow:close()
	Player.saveVolume(true)
	ISCollapsableWindow.close(self)
	self:removeFromUIManager()
	if Window.instance == self then Window.instance = nil end
end

------------------------------------------------------------------------------------------------- opening

function Window.open(bx, by, bz)
	if Window.instance then
		if Window.instance.key == Core.key(bx, by, bz) then
			Window.instance:bringToTop()
			return Window.instance
		end
		Window.instance:close()
	end
	local x = getCore():getScreenWidth() / 2 - Window.WIDTH / 2
	local y = getCore():getScreenHeight() / 2 - Window.HEIGHT / 2
	local window = JukeboxMoonWindow:new(x, y, bx, by, bz)
	window:initialise()
	window:addToUIManager()
	Window.instance = window
	return window
end

-- The notices of this jukebox, and "far" (which has no jukebox); never the admin window's.
function Window.forJukebox(data, key)
	if type(data) ~= "table" or Core.ADMIN_NOTICES[data.what] then return false end
	return data.key == key or (data.key == nil and data.what == "far")
end

table.insert(Player.listeners, function(kind, data)
	local window = Window.instance
	if window and kind == "notice" and Window.forJukebox(data, window.key) then
		window:notice(data.what)
	end
end)

return Window
