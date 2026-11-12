-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};

-- Messages over the player's head (spec UX-AUTOPILOT.md 4.1), shown with the game's HaloTextHelper: it waits for the
-- message on screen to fade and joins the queued ones, so it never wipes the game's own messages (experience, "too
-- dark") as setHaloNote does. Every message has a level:
--   detail   a square or object left out, a limit, what was left out at the start: over the head only with "Tutti" and
--            the panel closed (the panel has it in its log and its warnings)
--   info     start, phase, rest and resume: with "Solo importanti" and "Tutti", not while the panel is open
--   plain    the player's own stop ("Taglialegna fermato"): always (white)
--   bad      a stop with its reason, a job that did not start: always (the game's "bad" colour)
--   good     the end with its short summary: always (the game's "good" colour)
-- "Nessuno" shows nothing. At most one of ours every AutoPilotMoon.msBetweenMessages, the same text not again within
-- AutoPilotMoon.messageRepeatMs, at most AutoPilotMoon.maxQueuedMessages waiting (the oldest details go first). Never
-- written to the log. Every message, shown or not, is kept in AutoPilotMoon.messageLog (the last ones, for the panel).

local function isPanelOpenFor(player)
	local panel = AutoPilotMoon.Panel;

	return panel ~= nil and panel.isOpenFor ~= nil and panel:isOpenFor(player);
end

-- a message of this level goes over the head of this player now
function AutoPilotMoon:wantsMessage(level, player)
	local mode = AutoPilotMoon.Options:get("haloMode");

	if mode == "none"
	then
		return false;
	end

	if level == "detail"
	then
		return mode == "all" and not isPanelOpenFor(player);
	end

	if level == "info"
	then
		return not isPanelOpenFor(player);
	end

	return true;
end

local function remember(text, level)
	local log = AutoPilotMoon.messageLog;

	table.insert(log, { text = text, level = level, at = getTimestampMs() });

	while #log > AutoPilotMoon.maxLoggedMessages
	do
		table.remove(log, 1);
	end
end

-- true when the same text was said a moment ago (and the moments too old are forgotten)
local function isRepeat(text, now)
	local recent = AutoPilotMoon.recentMessages;
	local old = {};

	for key, at in pairs(recent)
	do
		if now - at > AutoPilotMoon.messageRepeatMs
		then
			table.insert(old, key);
		end
	end

	for i, key in ipairs(old)
	do
		recent[key] = nil;
	end

	if recent[text]
	then
		return true;
	end

	recent[text] = now;

	return false;
end

-- too many waiting: the oldest detail goes, else the oldest
local function trim(queue)
	while #queue > AutoPilotMoon.maxQueuedMessages
	do
		local drop = 1;

		for i, entry in ipairs(queue)
		do
			if entry.level == "detail"
			then
				drop = i;

				break;
			end
		end

		table.remove(queue, drop);
	end
end

local function enqueue(position, level, message, player)
	local text = AutoPilotMoon:printValue(message);

	remember(text, level);

	player = player or AutoPilotMoon:getPlayer();

	if not player or not AutoPilotMoon:wantsMessage(level, player) or isRepeat(text, getTimestampMs())
	then
		return;
	end

	local queue = AutoPilotMoon.messageQueue;

	if position == nil or position > #queue + 1
	then
		position = #queue + 1;
	elseif position < 1
	then
		position = 1;
	end

	table.insert(queue, position, { player = player, text = text, level = level });
	trim(queue);
end

-- a message of a level (detail, info, plain, bad, good)
function AutoPilotMoon:say(level, message, player)
	enqueue(nil, level or "detail", message, player);
end

-- a detail (silent: nothing at all)
function AutoPilotMoon:message(message, silent, player)
	if silent == true
	then
		return;
	end

	enqueue(nil, "detail", message, player);
end

-- the same, at a position of the queue (a line that must come before what was queued after position - 1)
function AutoPilotMoon:messageAt(position, message, player, level)
	enqueue(position, level or "detail", message, player);
end

-- called at every player update while something waits
function AutoPilotMoon:showNextMessage()
	local now = getTimestampMs();

	if now - AutoPilotMoon.lastMessageAt < AutoPilotMoon.msBetweenMessages
	then
		return;
	end

	local entry = table.remove(AutoPilotMoon.messageQueue, 1);

	AutoPilotMoon.lastMessageAt = now;

	if entry and entry.player and not entry.player:isDead()
	then
		if entry.level == "good"
		then
			HaloTextHelper.addGoodText(entry.player, entry.text);
		elseif entry.level == "bad"
		then
			HaloTextHelper.addBadText(entry.player, entry.text);
		else
			HaloTextHelper.addText(entry.player, entry.text);
		end
	end
end

-- drops what waits for a player (dead, or gone)
function AutoPilotMoon:clearMessages(player)
	local queue = AutoPilotMoon.messageQueue;

	for i = #queue, 1, -1
	do
		if queue[i].player == player
		then
			table.remove(queue, i);
		end
	end
end

function AutoPilotMoon:printValue(value)
    local vType = type(value);

    if vType == "boolean"
    then
        if value == true
        then
            return "true";
        else
            return "false";
        end
    elseif vType == "function"
    then
        return "<function>";
    elseif not value
    then
        return "";
    end

    return tostring(value) or "[?]";
end
