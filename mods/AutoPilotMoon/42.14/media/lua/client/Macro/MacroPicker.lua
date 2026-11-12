-- AutoPilot (Moon): automations for the Moon server.

-- "Inserisci > Ricetta..." and "Inserisci > Oggetto dallo zaino..." of the macro editor (spec MACRO-AUTOPILOT.md 4.6):
-- a small window of the game's kind with a search field and a list, so names are never written from memory.
--   Ricetta: the recipes the character knows (CraftRecipeManager.hasPlayerLearnedRecipe, or not to be learned) among
--            the ones the macros can do, with the game's name, the result's icon and the category; those that can be
--            done NOW first, with the word "si" in the good colour. Built when the window opens, Picker.slice recipes
--            per frame (OnTick only while building: "preparo l'elenco delle ricette...").
--   Oggetto: the inventory's items grouped by type, "Manico (12)".
-- The search: every word written, any case, applied only when the search changes. Double click, Enter or Inserisci:
-- the editor inserts it (crea "Nome" on the cursor's line, or "Nome" at the cursor).

AutoPilotMoon = AutoPilotMoon or {};
AutoPilotMoon.Macro = AutoPilotMoon.Macro or {};
AutoPilotMoon.Macro.Picker = AutoPilotMoon.Macro.Picker or {};

local Picker = AutoPilotMoon.Macro.Picker;
local UI = AutoPilotMoon.UI;

Picker.slice = 16;
Picker.window = nil;

-- the entries of a kind: { text, value, lower, doable, note, icon }
local function itemEntries(player)
	local counts = {};
	local order = {};
	-- the name the macros read (the script's, MacroNames): an item's own name can be one the player gave it
	local known = AutoPilotMoon.Macro.Names and AutoPilotMoon.Macro.Names.itemText;
	local items = player:getInventory():getAllEvalRecurse(function(item)
		return true;
	end);

	for i = 0, items:size() - 1
	do
		local item = items:get(i);
		local fullType = item:getFullType();

		if counts[fullType] == nil
		then
			counts[fullType] = { count = 0, name = (known and known[fullType]) or item:getDisplayName(), icon = item:getTex() };
			table.insert(order, fullType);
		end

		counts[fullType].count = counts[fullType].count + 1;
	end

	local entries = {};

	for i, fullType in ipairs(order)
	do
		local entry = counts[fullType];

		table.insert(entries, {
			text = entry.name .. " (" .. entry.count .. ")",
			value = entry.name,
			lower = string.lower(entry.name),
			icon = entry.icon,
		});
	end

	table.sort(entries, function(a, b)
		return a.lower < b.lower;
	end);

	return entries;
end

local function sortRecipes(a, b)
	if a.doable ~= b.doable
	then
		return a.doable == true;
	end

	return a.lower < b.lower;
end

-- one slice of the recipes (true when every recipe has been looked at)
local function buildStep(window, count)
	local Names = AutoPilotMoon.Macro.Names;
	local list = Names.recipeList;
	local player = window.player;
	local done = 0;

	while window.buildIndex <= #list and done < count
	do
		local recipe = list[window.buildIndex];

		window.buildIndex = window.buildIndex + 1;

		if Names:isLearned(player, recipe)
		then
			local name = Names:recipeName(recipe);
			local doable = AutoPilotMoon.Macro.Run:choose(player, { recipes = { recipe } }) ~= nil;

			table.insert(window.all, {
				text = name,
				value = Names:isAmbiguousRecipe(recipe) and recipe:getName() or name,
				lower = string.lower(name),
				doable = doable,
				note = recipe:getCategory(),
				icon = recipe:getIconTexture(),
			});
			done = done + 1;
		end
	end

	return window.buildIndex > #list;
end

function AutoPilotMoon.Macro.Picker.onTick()
	local window = Picker.window;

	if window == nil or not window.building or not window:getIsVisible()
	then
		Events.OnTick.Remove(Picker.onTick);

		return;
	end

	if buildStep(window, Picker.slice)
	then
		window.building = false;
		table.sort(window.all, sortRecipes);
		Events.OnTick.Remove(Picker.onTick);
	end

	window:applyFilter();
end

-- ============================================================================================================
-- The window
-- ============================================================================================================

local P = {};

function AutoPilotMoon.Macro.Picker:createClasses()
	if Picker.Window
	then
		return true;
	end

	if not AutoPilotMoon.Macro.Editor:createClasses()
	then
		return false;
	end

	Picker.Window = ISCollapsableWindowJoypad:derive("AutoPilotMacroPicker");
	Picker.List = ISScrollingListBox:derive("AutoPilotMacroPickerList");

	for name, fn in pairs(P)
	do
		Picker.Window[name] = fn;
	end

	Picker.List.doDrawItem = Picker.drawItem;

	return true;
end

-- a line: the icon, the name, the category or "si" (doable now) in the good colour
function AutoPilotMoon.Macro.Picker.drawItem(self, y, item, alt)
	local height = self.itemheight;
	local entry = item.item;
	local textY = y + (height - self.fontHgt) / 2;
	local c = UI.textColor;

	if self.selected == item.index
	then
		self:drawRect(0, y, self:getWidth(), height - 1, 0.3, 0.7, 0.35, 0.15);
	end

	if entry.icon
	then
		self:drawTextureScaledAspect(entry.icon, 4, y + 2, height - 4, height - 4, 1, 1, 1, 1);
	end

	self:drawText(entry.text, height + 6, textY, c.r, c.g, c.b, 1, self.font);

	-- the right column left of the scroll bar when there is one (under it the list's stencil cut "si" and the category)
	local right = self:getWidth() - 8;

	if self:isVScrollBarVisible()
	then
		right = self.vscroll:getX() - 4;
	end

	if entry.doable
	then
		local r, g, b = UI:goodColor();

		self:drawTextRight(entry.yes, right, textY, r, g, b, 1, self.font);
	elseif entry.note
	then
		local grey = AutoPilotMoon.Panel.colors.grey;

		self:drawTextRight(entry.note, right, textY, grey.r, grey.g, grey.b, 1, self.font);
	end

	return y + height;
end

function AutoPilotMoon.Macro.Picker:open(editor, kind)
	if not Picker:createClasses()
	then
		return nil;
	end

	Picker:closeFor(nil);

	local sizes = editor.sizes;
	local width = math.floor(editor:getWidth() * 0.6);
	local height = math.floor(editor:getHeight() * 0.8);
	local window = Picker.Window:new(editor:getX() + math.floor((editor:getWidth() - width) / 2), editor:getY() + sizes.row * 2, width, height);

	window.editor = editor;
	window.kind = kind;
	window.player = editor.player;
	window.playerNum = editor.playerNum;
	window.sizes = sizes;
	window.titleBarFont = UIFont.Small;
	window:setTitle(getText(kind == "recipe" and "IGUI_AutoPilot_E_InsertRecipe" or "IGUI_AutoPilot_E_InsertItem"));
	window:initialise();
	window:instantiate();
	window:addToUIManager();
	window:setVisible(true);
	window:bringToTop();
	Picker.window = window;

	window.all = {};

	if kind == "recipe"
	then
		AutoPilotMoon.Macro.Names:buildNow();
		window.building = true;
		window.buildIndex = 1;
		Events.OnTick.Add(Picker.onTick);
	else
		window.all = itemEntries(window.player);
	end

	window:applyFilter();
	window.search:focus();

	if UI:isJoypad(window.playerNum)
	then
		setJoypadFocus(window.playerNum, window);
	end

	return window;
end

-- closes the picker (of this editor; nil: whichever)
function AutoPilotMoon.Macro.Picker:closeFor(editor)
	local window = Picker.window;

	if window and (editor == nil or window.editor == editor)
	then
		window:close();
	end
end

function P:createChildren()
	ISCollapsableWindowJoypad.createChildren(self);

	local sizes = self.sizes;
	local pad = sizes.pad;
	local top = self:titleBarHeight() + pad;

	self:setResizable(false);
	self.yes = getText("IGUI_AutoPilot_E_PickerYes");

	self.search = ISTextEntryBox:new("", pad, top, self.width - 2 * pad, sizes.button);
	self.search:initialise();
	self.search:instantiate();
	self.search:setPlaceholderText(getText("IGUI_AutoPilot_E_Search"));
	self.search.onTextChangeFunction = P.onSearch;
	self.search.target = self;
	self.search.onCommandEntered = P.onSearchEnter;
	self.search.picker = self;
	self:addChild(self.search);

	local buttonY = self.height - pad - sizes.button;

	self.insertButton = AutoPilotMoon.Panel.Button:new(pad, buttonY, 10, sizes.button, getText("IGUI_AutoPilot_E_Insert"), self, P.onInsert);
	self.insertButton:initialise();
	self.insertButton:instantiate();
	self.insertButton:enableAcceptColor();
	self.insertButton:setWidthToTitle(sizes.button * 3);
	self:addChild(self.insertButton);

	self.cancelButton = AutoPilotMoon.Panel.Button:new(0, buttonY, 10, sizes.button, getText("IGUI_AutoPilot_R_Cancel"), self, P.close);
	self.cancelButton:initialise();
	self.cancelButton:instantiate();
	self.cancelButton:setWidthToTitle(sizes.button * 3);
	self.cancelButton:setX(self.width - pad - self.cancelButton:getWidth());
	self:addChild(self.cancelButton);

	local listTop = top + sizes.button + pad / 2;

	self.statusY = buttonY - pad / 2 - sizes.row;
	self.list = Picker.List:new(pad, listTop, self.width - 2 * pad, self.statusY - pad / 2 - listTop);
	self.list:initialise();
	self.list:instantiate();
	self.list:setFont(UIFont.Small, 4);
	self.list.drawBorder = true;
	self.list:setOnMouseDoubleClick(self, P.onChosen);
	self:addChild(self.list);
end

function P:applyFilter()
	local words = {};

	for word in string.gmatch(string.lower(self.search and self.search:getText() or ""), "%S+")
	do
		table.insert(words, word);
	end

	local selected = self.list.items[self.list.selected];
	local selectedValue = selected and selected.item.value or nil;

	self.list:clear();

	for i, entry in ipairs(self.all)
	do
		local ok = true;

		for j, word in ipairs(words)
		do
			if not string.find(entry.lower, word, 1, true)
			then
				ok = false;

				break;
			end
		end

		if ok
		then
			entry.yes = self.yes;
			self.list:addItem(entry.text, entry);

			if entry.value == selectedValue
			then
				self.list.selected = #self.list.items;
			end
		end
	end

	if self.list.selected < 1 and #self.list.items > 0
	then
		self.list.selected = 1;
	end

	if self.building
	then
		self.statusText = getText("IGUI_AutoPilot_E_Preparing");
	else
		self.statusText = nil;
	end
end

function P:onSearch()
	self:applyFilter();
end

function P.onSearchEnter(entry)
	entry.picker:onInsert();
end

function P:onChosen(entry)
	if entry
	then
		local editor = self.editor;
		local kind = self.kind;

		self:close();
		editor:insertChosen(kind, entry.value);
	end
end

function P:onInsert()
	local item = self.list.items[self.list.selected];

	if item
	then
		self:onChosen(item.item);
	end
end

function P:prerender()
	ISCollapsableWindowJoypad.prerender(self);

	if self.statusText and not self.isCollapsed
	then
		local grey = AutoPilotMoon.Panel.colors.grey;

		self:drawText(self.statusText, self.sizes.pad, self.statusY, grey.r, grey.g, grey.b, 1, UIFont.Small);
	end
end

function P:close()
	ISCollapsableWindowJoypad.close(self);
	self:removeFromUIManager();
	self.building = false;
	Events.OnTick.Remove(Picker.onTick);

	if Picker.window == self
	then
		Picker.window = nil;
	end

	if self.editor and UI:isJoypad(self.playerNum)
	then
		setJoypadFocus(self.playerNum, self.editor);
	end
end

function P:onJoypadDown(button, joypadData)
	if button == Joypad.AButton
	then
		self:onInsert();
	elseif button == Joypad.BButton
	then
		self:close();
	end
end

function P:onJoypadDirUp(joypadData)
	self.list:onJoypadDirUp();
end

function P:onJoypadDirDown(joypadData)
	self.list:onJoypadDirDown();
end
