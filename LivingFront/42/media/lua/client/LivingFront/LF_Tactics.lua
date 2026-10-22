-- Living Front: unit tactics - the sergeant's intent and the corporals' drills.
--
-- Orders flow one level down (see the squad tactics design doc):
--   Commander (sergeant, or the corporal of a lone team) picks the unit's intent from what the
--   unit knows: ADVANCE while the enemy is out of range, HOLD once in range or when most fit men
--   are pinned, FALL BACK after heavy losses. He shouts it; corporals within earshot take it up.
--   Corporal turns the intent into a drill for his team's two elements (pairs):
--     HOLD     - both pairs take cover around their positions and fire
--     ADVANCE  - bounding: one pair runs a bound forward past the other while the other covers
--                (aimed fire at what it sees, area fire at the last-known position), then swap
--     FALLBACK - the same, backwards
--   A team out of earshot keeps doing its last order.
-- The brain asks LF.Tactics.place(rec) where a soldier belongs and what his role is.
-- Runtime only: after a load, units re-form from where their men stand.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Units"
require "LivingFront/LF_Squad"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Suppress"
require "LivingFront/LF_Combat"

LF.Tactics = LF.Tactics or {}

local CFG = {
    updateTicks = 30,       -- commanders and corporals re-evaluate twice a second
    bound = 6,              -- tiles each bound gains on the covering pair
    arriveDistance = 1.8,   -- a moving soldier within this of his spot has arrived
    phaseTimeout = 600,     -- a bound that hasn't finished in ~10 s is called done anyway
    earshot = 30,           -- tiles a shouted order carries
    contactMemory = 600,
    contactRange = 45,
    advanceStop = 16,       -- the leading pair stops advancing this close to the enemy
    advanceResume = 22,     -- ... and starts again beyond this
    fallbackFit = 0.5,      -- fall back when fewer than this share of the unit is fit to fight
    fallbackClear = 26,     -- ... until the leading pair is this far from the enemy
    pinnedHold = 0.5,       -- hold when this share of the fit men is pinned
    fitHealth = 35,
    shoutTicks = 150,       -- how long shouted words stay over a head
}
LF.Tactics.CFG = CFG

local squads = {}   -- squad id -> { intent, contact (point), broken }
local teams = {}    -- team id -> { order, heard, moving, pos = { A = {x,y}, B = {x,y} }, phaseStart }
local shouts = {}   -- record id -> { text, untilTick }

-- A point that aiming and cover code can treat like a body.
local POINT = {}
POINT.__index = POINT
function POINT:getX() return self.x end
function POINT:getY() return self.y end
function POINT:getZ() return self.z end
function POINT:isDead() return false end
function LF.Tactics.point(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, POINT) end

local ELEMENT_NAME = { A = "Alpha", B = "Bravo" }
local OTHER = { A = "B", B = "A" }

-- ---- shouting -------------------------------------------------------------------------------

function LF.Tactics.shout(id, text)
    local rec = LF.Records.get(id)
    shouts[id] = { text = text, untilTick = LF.tick + CFG.shoutTicks }
    LF.log("SHOUT #" .. id .. " " .. (rec and LF.Units.title(rec) or "?") .. ": " .. text)
end

local COLORS = { GER = { 0.75, 0.8, 0.9 }, SOV = { 1.0, 0.55, 0.5 }, CIV = { 0.9, 0.9, 0.7 } }

local function drawShouts()
    local core = getCore()
    local zoom = core:getZoom(0)
    local tm = getTextManager()
    for id, s in pairs(shouts) do
        local body = LF.Bodies.get(id)
        if LF.tick > s.untilTick or not body or body:isDead() then
            shouts[id] = nil
        elseif body:isOnScreen() then
            local x, y, z = body:getX(), body:getY(), body:getZ()
            local sx, sy = isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
            local rec = LF.Records.get(id)
            local c = COLORS[rec and rec.faction or "CIV"] or COLORS.CIV
            local left = (s.untilTick - LF.tick) / CFG.shoutTicks
            tm:DrawStringCentre(UIFont.Medium, sx, sy - 135 / zoom, s.text, c[1], c[2], c[3], math.min(1, left * 3))
        end
    end
end

Events.OnPostUIDraw.Add(function() LF.guard("draw shouts", drawShouts) end)

-- ---- helpers --------------------------------------------------------------------------------

local function fit(rec)
    if not (rec and rec.alive and not rec.wounded) then return false end
    local body = LF.Bodies.get(rec.id)
    return body ~= nil and LF.Combat.health(body) >= CFG.fitHealth
end

local function facing(squad) return squad.facingX or 1, squad.facingY or 0 end

-- Centroid of a team's living members in one element, from their bodies.
local function elementCentre(team, el)
    local sx, sy, n = 0, 0, 0
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.element == el and r.team == team.id then
            local b = LF.Bodies.get(rid)
            if b then sx, sy, n = sx + b:getX(), sy + b:getY(), n + 1 end
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

-- ---- placement (asked by the brain) ---------------------------------------------------------

-- Where a soldier belongs right now and his role:
--   "move" (run to x, y without stopping to fight), "hold" (take cover near x, y and fight),
--   "command" (the sergeant: stay behind his teams and fight).
-- Returns role, x, y, z, point (the enemy's last-known position), or nil when the unit has no
-- intent (no contact): the brain then keeps the plain formation.
function LF.Tactics.place(rec)
    local sq = rec.squad and squads[rec.squad]
    if not (sq and sq.intent) then return nil end
    local squad = LF.Units.get(rec.squad)
    if not squad then return nil end
    local fx, fy = facing(squad)
    local z = rec.z or 0

    if squad.leader == rec.id then
        -- The sergeant keeps a few tiles behind the middle of his teams.
        local sx, sy, n = 0, 0, 0
        for _, tid in ipairs(squad.teams) do
            local t = teams[tid]
            if t and t.pos then
                for _, el in ipairs({ "A", "B" }) do
                    local p = t.pos[el]
                    if p then sx, sy, n = sx + p.x, sy + p.y, n + 1 end
                end
            end
        end
        if n == 0 then return nil end
        return "command", sx / n - fx * 3, sy / n - fy * 3, z, sq.contact
    end

    local t = rec.team and teams[rec.team]
    if not (t and t.pos and t.pos[rec.element]) then
        local x, y, sz = LF.Squad.slot(rec)
        if not x then return nil end
        return "hold", x, y, sz, sq.contact
    end
    local p = t.pos[rec.element]
    local lat = LF.Units.slotLat(rec)
    local x, y = p.x - fy * lat, p.y + fx * lat
    return (t.moving == rec.element) and "move" or "hold", x, y, z, sq.contact
end

function LF.Tactics.intent(squadId)
    local sq = squads[squadId]
    return sq and sq.intent
end

-- ---- corporal: drills -----------------------------------------------------------------------

-- Has every fit, unpinned soldier of the moving element reached his spot?
local function boundDone(team, t, squad)
    if LF.tick - t.phaseStart > CFG.phaseTimeout then return true end
    local fx, fy = facing(squad)
    local p = t.pos[t.moving]
    for _, rid in ipairs(team.members) do
        local r = LF.Records.get(rid)
        if r and r.team == team.id and r.element == t.moving and fit(r) then
            local b = LF.Bodies.get(rid)
            if b and not LF.Suppress.isPinned(b) then
                local lat = LF.Units.slotLat(r)
                local x, y = p.x - fy * lat, p.y + fx * lat
                if LF.dist(b:getX(), b:getY(), x, y) > CFG.arriveDistance then return false end
            end
        end
    end
    return true
end

local function startBound(team, t, squad, el, dir)
    local fx, fy = facing(squad)
    local other = t.pos[OTHER[el]]
    local mine = t.pos[el]
    if not (other and mine) then return end
    t.moving = el
    t.phaseStart = LF.tick
    -- Leapfrog: the moving pair ends up a bound beyond (or behind) the covering pair.
    mine.x, mine.y = other.x + fx * CFG.bound * dir, other.y + fy * CFG.bound * dir
    if team.leader then
        LF.Tactics.shout(team.leader, ELEMENT_NAME[el] .. ", move! " .. ELEMENT_NAME[OTHER[el]] .. ", cover!")
    end
end

local function driveTeam(team, t, squad)
    local order = t.heard
    if order == "ADVANCE" or order == "FALLBACK" then
        local dir = order == "ADVANCE" and 1 or -1
        if t.order ~= order then
            t.order = order
            startBound(team, t, squad, "A", dir)
        elseif t.moving and boundDone(team, t, squad) then
            startBound(team, t, squad, OTHER[t.moving], dir)
        end
    elseif order == "HOLD" and t.order ~= "HOLD" then
        t.order, t.moving = "HOLD", nil
    end
end

-- ---- commander: intent ----------------------------------------------------------------------

local INTENT_WORDS = { ADVANCE = "Advance!", HOLD = "Hold! Open fire!", FALLBACK = "Fall back!" }

local function setIntent(squad, sq, cid, intent, why)
    if sq.intent == intent then return end
    LF.log("INTENT " .. squad.name .. " " .. tostring(sq.intent) .. " -> " .. tostring(intent) .. " (" .. why .. ")")
    sq.intent = intent
    if intent and cid then LF.Tactics.shout(cid, INTENT_WORDS[intent]) end
end

local function updateSquad(squad)
    local cid = LF.Units.commander(squad)
    local cmd = cid and LF.Bodies.get(cid)
    if not cmd or cmd:isDead() then return end   -- no commander here: everyone keeps their last order
    local sq = squads[squad.id]
    if not sq then sq = {}; squads[squad.id] = sq end

    local c = LF.Squad.bestContact(squad.id, cmd:getX(), cmd:getY(), CFG.contactMemory, CFG.contactRange)
    if not c then
        if sq.intent then
            setIntent(squad, sq, cid, nil, "no contact")
            for _, tid in ipairs(squad.teams) do teams[tid] = nil end
        end
        return
    end
    if not sq.contact then sq.contact = LF.Tactics.point(c.x, c.y, c.z)
    else sq.contact.x, sq.contact.y, sq.contact.z = c.x, c.y, c.z end

    -- Team positions start from where the men stand when the fight begins.
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        if team and not teams[tid] then
            local ax, ay = elementCentre(team, "A")
            local bx, by = elementCentre(team, "B")
            if ax or bx then
                ax, ay = ax or bx, ay or by
                bx, by = bx or ax, by or ay
                teams[tid] = { order = nil, pos = { A = { x = ax, y = ay }, B = { x = bx, y = by } } }
            end
        end
    end

    -- How the unit stands.
    local total, fitN, pinnedN = 0, 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if fit(r) then
                fitN = fitN + 1
                if LF.Suppress.isPinned(LF.Bodies.get(rid)) then pinnedN = pinnedN + 1 end
            end
        end
    end
    local front = math.huge
    for _, tid in ipairs(squad.teams) do
        local t = teams[tid]
        if t then
            for _, p in pairs(t.pos) do
                local d = LF.dist(p.x, p.y, c.x, c.y)
                if d < front then front = d end
            end
        end
    end

    local intent = sq.intent
    local why
    if total > 0 and fitN / total < CFG.fallbackFit then
        sq.broken = true
        if front < CFG.fallbackClear then intent, why = "FALLBACK", fitN .. "/" .. total .. " fit"
        else intent, why = "HOLD", "fallen back out of range" end
    elseif fitN > 0 and pinnedN / fitN >= CFG.pinnedHold then
        intent, why = "HOLD", pinnedN .. "/" .. fitN .. " pinned"
    elseif intent == "ADVANCE" and front <= CFG.advanceStop then
        intent, why = "HOLD", "in range (" .. math.floor(front) .. " tiles)"
    elseif intent ~= "ADVANCE" and front > CFG.advanceResume and not sq.broken then
        intent, why = "ADVANCE", "enemy at " .. math.floor(front) .. " tiles"
    elseif not intent then
        intent, why = "HOLD", "contact at " .. math.floor(front) .. " tiles"
    end
    setIntent(squad, sq, cid, intent, why or "")

    -- Pass it on: corporals within earshot take up the intent, then run their drills.
    for _, tid in ipairs(squad.teams) do
        local team = LF.Units.get(tid)
        local t = teams[tid]
        if team and t then
            local cpl = team.leader and LF.Bodies.get(team.leader)
            if cpl and not cpl:isDead() then
                if LF.dist(cpl:getX(), cpl:getY(), cmd:getX(), cmd:getY()) <= CFG.earshot then
                    t.heard = sq.intent
                end
                driveTeam(team, t, squad)
            end
        end
    end
end

local function onTick()
    if LF.tick % CFG.updateTicks ~= 0 then return end
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "squad" then LF.guard("tactics", updateSquad, u) end
    end
end

Events.OnTick.Add(onTick)

function LF.Tactics.forgetAll()
    squads, teams, shouts = {}, {}, {}
end
Events.OnInitGlobalModData.Add(function() LF.Tactics.forgetAll() end)
