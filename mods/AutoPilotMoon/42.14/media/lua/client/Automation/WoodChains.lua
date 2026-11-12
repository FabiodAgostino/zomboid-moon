-- AutoPilot (Moon): automations for the Moon server.

-- The chains of phase B (11/11/2026; ANALISI-WorkOrders.md 7, spec UX-AUTOPILOT.md 2.2, 5), on the engine of
-- client/53_AP_Chain.lua (the next phase only after the previous one ended by itself, any stop stops everything, the
-- area looked at again at each phase):
-- - woodChain ("Taglia e sega", user's decision of 12/11/2026; until then "Taglia, sega e porta" with a destination and
--   a third phase that gathered the planks): Lumberjack -> Sawyer without a destination (the logs, 2 squares of margin:
--   trees fall outside the area); the planks stay on the ground next to each sawn log, never carried away. Same name
--   "woodChain" as before: the player's tick in "Jobs in the menu" keeps its place and its value.
-- - chopAndGather ("Taglia e raccogli"): Lumberjack -> Gatherer of the logs (2 squares of margin).
-- - clearAndGather ("Pulisci e raccogli"): Gardener ("Tutto": grass, bushes, stones and twigs, stumps, boulders, each
--   when the character has its tool; phase C) -> Gatherer of stones, twigs and branches, the yields of stumps and
--   boulders, and what the Gardener's pick-ups brought into the inventory (ctx.run.gardenerPicked).
-- The destination of the two gathering chains is chosen at the start, after the area (AreaTool:beginWithDestination);
-- "Taglia e sega" has none. A chain is offered only when every phase is on on the server, and has its own tick in "Jobs
-- in the menu".

require "05_AP_Config";
require "53_AP_Chain";

local A = AutoPilotMoon.Automation;
local Chain = AutoPilotMoon.Chain;

AutoPilotMoon.WoodChains = AutoPilotMoon.WoodChains or {};

local WoodChains = AutoPilotMoon.WoodChains;

WoodChains.fallMargin = 2;   -- squares around the area where the logs of a felled tree may land

Chain:define("woodChain", {
	titleKey = "IGUI_AutoPilot_O_Context_WoodChain",
	phases = {
		{ job = "lumberjack", labelKey = "IGUI_AutoPilot_M_ChopTrees" },
		{ job = "sawyer", labelKey = "IGUI_AutoPilot_M_SawLogs", margin = WoodChains.fallMargin },
	},
});

Chain:define("chopAndGather", {
	titleKey = "IGUI_AutoPilot_O_Context_ChopAndGather",
	phases = {
		{ job = "lumberjack", labelKey = "IGUI_AutoPilot_M_ChopTrees" },
		{ job = "gatherer", labelKey = "IGUI_AutoPilot_M_CarryLogs", margin = WoodChains.fallMargin, params = { what = "logs" } },
	},
});

Chain:define("clearAndGather", {
	titleKey = "IGUI_AutoPilot_O_Context_ClearAndGather",
	phases = {
		{ job = "gardener", labelKey = "IGUI_AutoPilot_M_Clear", params = { preset = "all" } },
		{ job = "gatherer", labelKey = "IGUI_AutoPilot_M_CarryStonesTwigs", params = { what = "stonesTwigs" } },
	},
});

-- the menu entries (client/75_AP_JobMenu.lua): area, then destination, then the chain

local function axeRequirement(player)
	return AutoPilotMoon.JobMenu:axeRequirement(player);
end

local function startChain(name)
	return function(player, rect, dest)
		return Chain:start(name, player, rect, { destination = dest });
	end;
end

-- "Taglia e sega": never a destination, even if a caller passes one
local function startWoodChain(player, rect)
	return Chain:start("woodChain", player, rect, {});
end

local function chainLimit(phaseTitleKey, limitText)
	return getText("IGUI_AutoPilot_T_JobLimit", getText(phaseTitleKey), limitText);
end

AutoPilotMoon.JobMenu:define("woodChain", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_WoodChain",
	chain = "woodChain",
	descKey = "IGUI_AutoPilot_T_Desc_WoodChain",
	here = true,
	icon = "Base.Axe",
	-- no whatKey: no destination, the planks stay on the ground next to each log (12/11/2026)
	requirements = function(player)
		return { axeRequirement(player), AutoPilotMoon.Sawyer.sawRequirement(player) };
	end,
	notes = function(player)
		local notes = { { text = getText("IGUI_AutoPilot_T_PlanksStayOnGround") } };

		if player:tooDarkToRead()
		then
			table.insert(notes, 1, { text = getText("IGUI_AutoPilot_T_TooDarkToSaw"), bad = true });
		end

		return notes;
	end,
	limits = function()
		return {
			getText("IGUI_AutoPilot_T_Job", getText("IGUI_AutoPilot_O_Context_WoodChain")),
			chainLimit("IGUI_AutoPilot_O_Context_Sawyer", getText("IGUI_AutoPilot_T_Limit_Logs", AutoPilotMoon.Sawyer:getLimit())),
		};
	end,
	start = startWoodChain,
});

AutoPilotMoon.JobMenu:define("chopAndGather", {
	group = "wood",
	labelKey = "IGUI_AutoPilot_M_ChopAndGather",
	chain = "chopAndGather",
	descKey = "IGUI_AutoPilot_T_Desc_ChopAndGather",
	icon = "Base.Axe",
	whatKey = "IGUI_AutoPilot_D_TitleItems",
	requirements = function(player)
		return { axeRequirement(player) };
	end,
	limits = function()
		return {
			getText("IGUI_AutoPilot_T_Job", getText("IGUI_AutoPilot_O_Context_ChopAndGather")),
			chainLimit("IGUI_AutoPilot_O_Context_Gatherer", getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob"))),
		};
	end,
	start = startChain("chopAndGather"),
});

AutoPilotMoon.JobMenu:define("clearAndGather", {
	group = "ground",
	labelKey = "IGUI_AutoPilot_M_ClearAndGather",
	chain = "clearAndGather",
	descKey = "IGUI_AutoPilot_T_Desc_ClearAndGather",
	icon = "Base.Scythe",
	whatKey = "IGUI_AutoPilot_D_TitleItems",
	-- "Tutto" does what the character's tools allow: no requirement, the tooltip says what it leaves (phase C)
	notes = function(player)
		return AutoPilotMoon.JobMenu.specs.clear.notes(player, { preset = "all" });
	end,
	limits = function()
		return {
			getText("IGUI_AutoPilot_T_Job", getText("IGUI_AutoPilot_O_Context_ClearAndGather")),
			chainLimit("IGUI_AutoPilot_O_Context_Gatherer", getText("IGUI_AutoPilot_T_Limit_Items", AutoPilotMoon.Sandbox:getInteger("GathererItemsPerJob"))),
		};
	end,
	start = startChain("clearAndGather"),
});
