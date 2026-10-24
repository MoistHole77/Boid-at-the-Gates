-- Living Front: the inspect window - right-click a soldier, "Inspect ...": his name, rank, unit
-- and job, what he is doing, his earned traits and his service record. It stays open and updates
-- live (one window per soldier).

require "ISUI/ISCollapsableWindow"
require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Soldier/LF_Service"
require "LivingFront/Units/LF_Stance"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Combat"
require "LivingFront/Soldier/LF_Suppress"

LF.Inspect = LF.Inspect or {}

local RANK_NAME = { LT = "Lieutenant", SSG = "Staff Sergeant", SGT = "Sergeant", CPL = "Corporal", PVT = "Private" }
local STATE_WORDS = {
    idle = "standing by", guard = "on guard", alert = "alert, covering", engage = "firing",
    bound = "moving under fire", file = "on the move", hide = "taking cover (wounded)", down = "down, wounded",
    flee = "wounded, getting to safety", cover = "in cover",
}

LF_InspectWindow = ISCollapsableWindow:derive("LF_InspectWindow")

local open = {}          -- record id -> window

local W, H = 400, 360
local PAD = 12

function LF_InspectWindow:new(x, y, recId)
    local o = ISCollapsableWindow.new(self, x, y, W, H)
    o.recId = recId
    o.resizable = false
    o.title = "Soldier"
    return o
end

function LF_InspectWindow:close()
    open[self.recId] = nil
    self:setVisible(false)
    self:removeFromUIManager()
end

-- Wrap text to the window width.
local function wrap(text, font, width)
    local tm = getTextManager()
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if tm:MeasureStringX(font, try) > width and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- The unit a team that joined another unit came from ("with GER team 2 from GER team 3").
local function joinedFrom(rec)
    for _, u in pairs(LF.Units.all()) do
        if u.joined and u.joinTeam == rec.team then return u.name end
    end
    return nil
end

local function roleOf(rec)
    if rec.faction == "CIV" and not rec.squad then return "Civilian" end
    local squad = rec.squad and LF.Units.get(rec.squad)
    local team = rec.team and LF.Units.get(rec.team)
    if not squad then return "No unit (on his own)" end
    if squad.kind == "hq" then
        local p = LF.Units.get(squad.platoon)
        local pn = p and p.name or squad.name
        if squad.leader == rec.id then return "Platoon commander, " .. pn end
        if rec.hqRole == "ssgt" then return "Platoon sergeant, " .. pn end
        if rec.hqRole == "rto" then return "Radio operator, " .. pn end
        return "Platoon headquarters, " .. pn
    end
    if squad.leader == rec.id then return "Squad leader, " .. squad.name end
    if team and team.leader == rec.id then return "Team leader, " .. team.name .. " (" .. squad.name .. ")" end
    if team then return "Rifleman, " .. team.name .. " (" .. squad.name .. ")" end
    return squad.name
end

local PLATOON_TASK = { support = "supporting by fire", dig = "dug in, covering", withdraw = "withdrawing", hold = "holding",
                       take = "the assault" }
local function taskOf(squad)
    local t = squad and squad.objTask
    if not t then return squad and squad.platoonTask and PLATOON_TASK[squad.platoonTask] or nil end
    local obj = LF.Objective and LF.Objective.get(t.obj)
    local name = obj and obj.name or "an objective"
    if t.kind == "hold" then return "holding " .. name end
    return "taking " .. name .. " (" .. tostring(t.phase) .. ")"
end

function LF_InspectWindow:prerender()
    ISCollapsableWindow.prerender(self)
end

function LF_InspectWindow:render()
    ISCollapsableWindow.render(self)
    if self.isCollapsed then return end
    local rec = LF.Records.get(self.recId)
    local font, big = UIFont.Small, UIFont.Medium
    local fh = getTextManager():getFontHeight(font)
    local y = self:titleBarHeight() + PAD
    local width = self.width - PAD * 2
    local function text(s, r, g, b, f)
        f = f or font
        for _, l in ipairs(wrap(s, f, width)) do
            self:drawText(l, PAD, y, r or 0.9, g or 0.9, b or 0.9, 1, f)
            y = y + getTextManager():getFontHeight(f)
        end
    end
    local function gap(n) y = y + (n or 6) end
    if not rec then
        text("This soldier's record is gone.", 0.8, 0.5, 0.5)
        return
    end
    local faction = LF.Factions[rec.faction]
    self.title = LF.Units.title(rec)
    text(LF.Records.fullName(rec), 1, 1, 0.85, big)
    text((RANK_NAME[rec.rank] or "") .. (rec.rank and " - " or "") .. (faction and faction.name or rec.faction), 0.75, 0.8, 0.9)
    text(roleOf(rec), 0.75, 0.8, 0.9)
    local from = rec.team and joinedFrom(rec)
    if from then text("Attached for this task (from " .. from .. ")", 0.75, 0.8, 0.9) end
    gap()

    -- Now.
    local body = LF.Bodies.get(rec.id)
    local squad = rec.squad and LF.Units.get(rec.squad)
    if not rec.alive then
        text("Killed in action.", 0.9, 0.4, 0.4)
    elseif not body then
        text("Not nearby (away from you, not loaded).", 0.7, 0.7, 0.7)
    else
        local state, detail = nil, nil
        if LF.Brain and LF.Brain.stateOf then state, detail = LF.Brain.stateOf(rec.id) end
        local hp = math.floor(LF.Combat.health(body))
        local supp = math.floor(LF.Suppress.value(body))
        local doing = STATE_WORDS[state or ""] or state or "-"
        text("Now: " .. doing .. (detail and (" - " .. detail) or ""))
        text("Health " .. hp .. "%   Suppression " .. supp .. (LF.Suppress.isPinned(body) and " (pinned)"
            or (LF.Suppress.isSuppressed(body) and " (suppressed)" or "")),
            hp < 50 and 0.95 or 0.9, hp < 50 and 0.55 or 0.9, hp < 50 and 0.5 or 0.9)
        if squad then
            local task = taskOf(squad)
            text("Unit stance: " .. LF.Stance.get(squad).name .. (task and ("   Task: " .. task) or ""))
            local p = LF.Platoon and LF.Units.get(squad.platoon)
            if p and p.kind == "platoon" then
                local role = squad.kind == "hq" and "" or (p.mainEffort == squad.id and " - main effort" or "")
                text("Platoon: " .. LF.Platoon.describe(p) .. role, 0.75, 0.8, 0.9)
            end
        end
        if LF.Morale then
            local mv = math.floor(LF.Morale.get(rec))
            text("Morale " .. mv .. " (" .. LF.Morale.word(mv) .. ")", mv < 40 and 0.95 or 0.8, mv < 40 and 0.6 or 0.9, mv < 40 and 0.5 or 0.8)
        end
    end
    gap()

    if LF.Grenade and rec.faction ~= "CIV" then
        local g = LF.Grenade.count(rec)
        if g > 0 or rec.rank == "SGT" or rec.rank == "CPL" then text("Grenades: " .. g, 0.8, 0.8, 0.8) end
    end
    if LF.MG and LF.MG.roleName(rec) then
        local team = rec.team and LF.Units.get(rec.team)
        text(LF.MG.roleName(rec):gsub("^%l", string.upper) .. (team and (", " .. team.name) or ""), 0.9, 0.8, 0.5)
    end
    if LF.Medic and LF.Medic.levelOf then
        if rec.medic then
            text("Squad medic (" .. LF.Medic.levelOf(rec) .. ") - dressings " .. (rec.kit or 0) .. "/" .. LF.Medic.CFG2.kit
                .. ", men saved " .. (rec.medicSaves or 0), 0.6, 0.9, 0.6)
        end
        local left = LF.Medic.critLeft(rec.id)
        if left then text("CRITICAL - bleeding out, " .. math.floor(left / 60) .. " s left", 1, 0.4, 0.4)
        elseif LF.Medic.isStable(rec.id) then text("Stabilised by the medic - out of the fight", 0.9, 0.8, 0.5) end
    end
    gap()
    -- Traits.
    local s = LF.Service.of(rec)
    text("Traits", 1, 0.85, 0.5)
    local traits = LF.Service.traits(rec)
    if #traits == 0 then
        text("Steady - nothing out of the ordinary yet.", 0.8, 0.8, 0.8)
    else
        for _, k in ipairs(traits) do
            local t = LF.Service.TRAITS[k]
            if t then
                local col = k == "shaken" and { 0.95, 0.6, 0.5 } or (k == "veteran" and { 0.6, 0.9, 0.6 } or { 0.8, 0.8, 0.8 })
                text(t.name .. ": " .. t.text, col[1], col[2], col[3])
            end
        end
    end
    gap()

    -- Service record.
    text("Service record", 1, 0.85, 0.5)
    text("Battles " .. s.battles .. "   Kills " .. s.kills .. "   Times hit " .. s.wounds)
    text("Comrades lost " .. s.lost .. "   Unit broke " .. s.broke .. "   Objectives taken " .. s.taken)
    text("Strain " .. s.stress .. " / " .. LF.Service.CFG.stressCap
        .. "  (shaken at " .. LF.Service.CFG.shakenStress .. ")", 0.7, 0.7, 0.7)
    -- Grow to fit.
    local want = y + PAD
    if math.abs(want - self.height) > 2 then self:setHeight(want) end
    local _ = fh
end

function LF.Inspect.open(recId)
    if open[recId] then
        open[recId]:bringToTop()
        return
    end
    local mx, my = getMouseX(), getMouseY()
    local x = math.min(mx + 20, getCore():getScreenWidth() - W - 10)
    local y = math.min(math.max(10, my - 60), getCore():getScreenHeight() - H - 10)
    local w = LF_InspectWindow:new(x, y, recId)
    w:initialise()
    w:addToUIManager()
    open[recId] = w
end

-- Soldiers standing on or right next to (x, y), nearest first (at most four).
function LF.Inspect.near(x, y, z)
    local found = {}
    for id, body in pairs(LF.Bodies.all()) do
        if math.floor(body:getZ()) == z then
            local d = LF.dist(body:getX(), body:getY(), x + 0.5, y + 0.5)
            if d <= 1.8 then found[#found + 1] = { id = id, d = d } end
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    while #found > 4 do table.remove(found) end
    return found
end
