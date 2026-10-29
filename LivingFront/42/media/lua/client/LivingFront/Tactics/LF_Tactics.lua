-- Living Front: unit tactics - the shared core. Settings, shouted orders, helpers, where a man
-- belongs (LF.Tactics.place) and the commander's intent. The rest of the tactics are split by
-- what the unit is doing, and load in this order:
--   LF_Tactics (this file) -> LF_Manoeuvre -> LF_Defence -> LF_Clearing -> LF_Command
-- They share their state through LF.Tactics.I (each file lists what it borrows at the top and
-- what it lends at the bottom). Require LF_Command to get all of them.
--
-- When a fight breaks out, nobody gives orders for the first few seconds (CFG.bearingsTicks):
-- every soldier returns fire, gets into the nearest cover and keeps firing on his own. Only
-- then does the commander take stock and start giving orders.
-- Orders flow one level down (see the squad tactics design doc):
--   Commander (sergeant, or the corporal of a lone team) picks the unit's intent from what the
--   unit knows: ADVANCE while the enemy is out of range, HOLD once in range or when most fit men
--   are pinned, FALL BACK after heavy losses. He shouts it; corporals within earshot take it up.
--   Once his squad has fire superiority (enough of the enemy near the contact is suppressed)
--   and it is healthy and not pinned itself, a sergeant orders a FLANK: his alpha teams
--   maneuver around one side (the side with more cover) while his bravo teams hold and keep the
--   enemy pinned; when the alphas are in position, all hold. After one side starts a flank the
--   other side must wait ~25 s before it can flank in turn.
--   Corporal turns the order into a drill for his team's two elements (pairs):
--     HOLD     - both pairs take cover around their positions and fire
--     ADVANCE  - bounding: one pair runs a bound forward past the other while the other covers
--                (aimed fire at what it sees, area fire at the last-known position), then swap
--     FALLBACK - the same, backwards
--     MANEUVER - the same bounding, along a route (out to the side, then in toward the enemy)
--   A corporal whose team is holding and finds half its fit men without an open shot (no enemy
--   in their sights for ~8 s) moves the whole team to a nearby spot with a line of sight to the
--   enemy (REPOSITION). Only one team per unit does this at a time, at most once every ~30 s;
--   among the teams that want to, the one that goes is picked at random, weighted toward the
--   less suppressed. An order from the sergeant overrides it. A stalemate flank waits until
--   two repositions have been tried (or the fight has stalled twice as long).
--   A corporal out of earshot of his commander (or with no commander here) runs his team himself:
--   advance into range, hold, fall back when shot up.
-- The brain asks LF.Tactics.place(rec) where a soldier belongs and what his role is.
-- Runtime only: after a load, units re-form from where their men stand.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Soldier/LF_Suppress"
require "LivingFront/Soldier/LF_Combat"
require "LivingFront/World/LF_Cover"
require "LivingFront/World/LF_Sense"
require "LivingFront/Units/LF_Stance"
require "LivingFront/World/LF_Building"
require "LivingFront/Units/LF_March"
require "LivingFront/Specialists/LF_Medic"

LF.Tactics = LF.Tactics or {}
LF.Tactics.I = LF.Tactics.I or {}   -- (shared between the tactics files)
local I = LF.Tactics.I
local function buildingNear(...) return I.buildingNear(...) end   -- (in LF_Command, loaded later)

local CFG = {
    updateTicks = 30,       -- commanders and corporals re-evaluate twice a second
    bound = 6,              -- tiles each bound gains on the covering pair
    arriveDistance = 1.8,   -- a moving soldier within this of his spot has arrived
    phaseTimeout = 600,     -- a bound that hasn't finished in ~10 s is called done anyway
    boundMin = 150,         -- a rush lasts at least ~2.5 s ...
    boundSettle = 90,       -- ... then the pair is down and firing ~1.5 s before the other goes
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
    bearingsTicks = 300,    -- the first ~5 s of a fight: everyone for himself, no orders
    -- Flanking (squads only)
    flankMinHold = 180,     -- HOLD at least ~3 s before considering a flank
    flankSuperiority = 0.3, -- ... and at least this share of the enemy near the contact suppressed
    superiorityRadius = 25, -- enemies within this of the contact count toward that share
    flankCooldown = 1800,   -- ... at most once per 30 s
    flankFit = 0.6,         -- ... only while at least this share of the squad is fit
    flankPinned = 0.34,     -- ... and less than this share of the fit men is pinned
    flankOut = 18,          -- first waypoint: this far out to the side (and flankLean toward the enemy)
    flankLean = 4,
    flankStandoff = 10,     -- final waypoint: this far short of the enemy (along the squad's facing) ...
    flankWide = 20,         -- ... and this far off to the side of him
    counterFlankTicks = 1500, -- after one side starts a flank, the other must wait this long (~25 s)
    flankPushes = 3,
    reformTicks = 2700,
    -- Clearing a building (offensive)
    clearAt = 3,            -- send a team in when the enemy known in a building is down to this many
    clearCooldown = 3600,   -- at most one clearing order per ~60 s
    clearStackTimeout = 1200, -- after ~20 s, go in with whoever is stacked (2+ men) or call it off
    clearStackClose = 480,  -- after ~8 s, a man within 2.5 tiles of his stack spot counts as stacked
    clearManTimeout = 600,  -- the next man goes after ~10 s even if the one ahead is held up
    clearTimeout = 5400,    -- give up on a room after ~90 s (each room, and each regroup, starts the clock again)
    clearRooms = 6,
    clearPartnerWait = 480, -- a team stacked on one door waits up to ~8 s for the team at the other -
                            -- and only if that team is nearly stacked itself
    casualtyMinHealth = 35, -- a man knocked over while clearing is dragged out only if healthier than this
    backDoorMin = 6,        -- a back door: at least this far from the front one         -- clear at most this many rooms one after another
    standDownTicks = 2700,  -- ~45 s with nothing to do: the unit stands by
    -- The sergeant choosing his stance
    digInOdds = 1.5,        -- dig in when the known enemy is this many times our fit men
    lossShare = 0.34,       -- ... or this share of the unit is down and the enemy isn't giving
    attackOdds = 1.5,       -- go (back) on the attack with this many times the known enemy
    quietOpen = 2700,       -- a defence in the open moves up after ~45 s without seeing the enemy
    quietBuilding = 5400,   -- a building is only left after ~90 s without seeing the enemy
    stanceConfirm = 180,    -- a reason must hold ~3 s before he acts on it
    stanceCooldown = 3600,  -- at most one change of stance per ~60 s
    buildingNear = 3,       -- a building within this of the sergeant counts as "here"     -- a defence re-forms toward a new attack direction at most every ~45 s
    -- Stalemate: if neither side reaches fire superiority for this long, the side with the better
    -- share of the enemy suppressed flanks anyway (battles should still last a while).
    stalemateTicks = 2700,  -- ~45 s of holding in range with no flank by either side
    stalemateRadius = 45,   -- enemy squads whose last contact is within this of our commander count
    -- Corporal's reposition (team without an open shot)
    blindShare = 0.5,       -- this share of the team's fit men without a shot -> the team wants to move
    shiftInterval = 1800,   -- one team per unit repositions at most once per ~30 s
    shiftsBeforeStalemate = 2, -- repositions tried before a stalemate flank (or 2x stalemateTicks)        -- a flanking team that can't see the enemy at the end pushes on this many times
    flankTimeout = 5400,    -- give up on a flank after ~90 s
    -- Regrouping (0.75): a squad that has fallen back out of range with its men spread out
    regroupSpread = 8,      -- ... a fit man further than this from the sergeant: regroup on him
    regroupTimeout = 1200,  -- ... called done after ~20 s, whoever has come in
    regroupCooldown = 3600, -- ... at most once a minute
}
LF.Tactics.CFG = CFG

local squads = {}   -- squad id -> { intent, contact (point), broken }
function LF.Tactics.state(squad) return squad and squads[squad.id] end
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

local ELEMENT_NAME = { A = "First pair", B = "Second pair" }   -- (a team's two pairs)
local OTHER = { A = "B", B = "A" }

-- ---- shouting -------------------------------------------------------------------------------

-- Break text into lines of at most n characters (at spaces).
local function wrap(text, n)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        if #line > 0 and #line + 1 + #word > n then lines[#lines + 1] = line; line = word
        else line = (#line > 0 and (line .. " ") or "") .. word end
    end
    if #line > 0 then lines[#lines + 1] = line end
    return lines
end
LF.Tactics.wrap = wrap

function LF.Tactics.shout(id, text)
    local rec = LF.Records.get(id)
    shouts[id] = { text = text, untilTick = LF.tick + CFG.shoutTicks }
    LF.log("SHOUT #" .. id .. " " .. (rec and LF.Units.title(rec) or "?") .. ": " .. text)
end

-- Words spoken (not shouted) - a reply when you talk to him: wrapped over several lines above his
-- head, on show for longer (seconds, default from its length).
-- Lines of speech over him right now (0 if none), and their height.
function LF.Tactics.speechLines(id)
    local s = shouts[id]
    if not s or LF.tick > s.untilTick then return 0, 0 end
    local h = getTextManager():getFontHeight(s.lines and UIFont.Small or UIFont.Medium)
    return s.lines and #s.lines or 1, h
end

-- (quiet: words still coming in, as he speaks - shown, not logged)
function LF.Tactics.say(id, text, seconds, quiet)
    local rec = LF.Records.get(id)
    seconds = seconds or math.max(4, math.min(20, #text / 12))
    shouts[id] = { text = text, lines = wrap(text, 48), untilTick = LF.tick + seconds * 60, dur = seconds * 60 }
    if quiet then return end
    LF.log("SAYS #" .. id .. " " .. (rec and LF.Units.title(rec) or "?") .. ": " .. text)
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
            local sx, sy = LF.screenOf(x, y, z)
            local head = LF.headHeight(body)
            local rec = LF.Records.get(id)
            local c = COLORS[rec and rec.faction or "CIV"] or COLORS.CIV
            local left = (s.untilTick - LF.tick) / (s.dur or CFG.shoutTicks)
            local a = math.min(1, left * 3)
            if s.lines then
                local h = tm:getFontHeight(UIFont.Small)
                local top = sy - head / zoom - (#s.lines - 1) * h
                for i, l in ipairs(s.lines) do
                    tm:DrawStringCentre(UIFont.Small, sx + 1, top + (i - 1) * h + 1, l, 0, 0, 0, a * 0.8)
                    tm:DrawStringCentre(UIFont.Small, sx, top + (i - 1) * h, l, 1, 1, 1, a)
                end
            else
                tm:DrawStringCentre(UIFont.Medium, sx, sy - head / zoom, s.text, c[1], c[2], c[3], a)
            end
        end
    end
end

LF.on("OnPostUIDraw", "Tactics", function() LF.guard("draw shouts", drawShouts) end)

-- ---- helpers --------------------------------------------------------------------------------

-- Fit to fight: alive, not relieved for wounds, and (if he has a body here) not badly hurt.
-- A soldier without a body (out of range of the player) counts as fit, so a unit that is
-- only partly near the player doesn't think it has lost half its men.
local function fit(rec)
    if not (rec and rec.alive and not rec.wounded and not rec.aid) then return false end
    if LF.Medic and LF.Medic.busy(rec.id) then return false end   -- down on his back, or dragging one
    local body = LF.Bodies.get(rec.id)
    return body == nil or LF.Combat.health(body) >= CFG.fitHealth
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
local function placeOf(rec)
    local sq = rec.squad and squads[rec.squad]
    if not sq then return nil end
    local tc = rec.team and teams[rec.team]
    if tc and tc.clear then
        local role, x, y, z, face, gait = LF.Tactics.clearPlace(tc.clear, rec)
        if role then return role, x, y, z, face, gait end
    end
    if tc and tc.inside then
        local sp = tc.inside.spots[rec.id]
        if sp then return "file", sp.x, sp.y, tc.inside.L.z, sp.face, "halt" end
    end
    -- On the march: his place in the column.
    do
        local role, x, y, z, face, gait, scan = LF.March.place(rec)
        if role then return role, x, y, z, face, gait, scan end
    end
    local alone = rec.team and teams[rec.team]
    alone = alone and alone.alone and alone.heard and alone or nil
    if not (sq.intent or alone) then return nil end
    local squad = LF.Units.get(rec.squad)
    if not squad then return nil end
    if sq.intent == "DEFEND" and sq.perim then
        if sq.perim.layout then return LF.Tactics.buildingPlace(squad, sq, rec) end
        return LF.Tactics.perimeterPlace(squad, sq, rec)
    end
    local fx, fy = facing(squad)
    local z = rec.z or 0
    local point = (alone and alone.contact) or sq.contact

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
        return "command", sx / n - fx * 3, sy / n - fy * 3, z, point
    end

    local t = rec.team and teams[rec.team]
    if not (t and t.pos and t.pos[rec.element]) then
        local x, y, sz = LF.Squad.slot(rec)
        if not x then return nil end
        return "hold", x, y, sz, point
    end
    local p = t.pos[rec.element]
    local lat = LF.Units.slotLat(rec)
    local x, y = p.x - fy * lat, p.y + fx * lat
    return (t.moving == rec.element or t.shifting) and "move" or "hold", x, y, z, point
end

-- (A machine gun's crew then go to the gun - LF_MG.)
-- (The platoon headquarters goes where the lieutenant's plan puts it - LF_Platoon.)
function LF.Tactics.place(rec)
    if rec.hqRole and LF.Platoon then return LF.Platoon.place(rec) end
    if rec.mgRole and LF.MG then return LF.MG.place(rec, placeOf(rec)) end
    return placeOf(rec)
end

function LF.Tactics.intent(squadId)
    local sq = squads[squadId]
    return sq and sq.intent
end

-- Is this unit in the opening seconds of a fight (no orders yet; everyone returns fire and
-- takes cover on his own)?
function LF.Tactics.bearings(squadId)
    local unit = LF.Units.get(squadId)
    if not LF.Stance.get(unit).bearings then return false end
    if LF.Objective and LF.Objective.planned(unit) then return false end    -- a planned assault
    local sq = squads[squadId]
    return sq ~= nil and sq.fightStart ~= nil and not sq.intent and LF.tick - sq.fightStart < CFG.bearingsTicks
end

-- ---- squad plans (combat overhaul, 0.75) ------------------------------------------------------
--
-- Every order a commander can give his squad, and every order a corporal can give his team, as
-- data: the drill each fire team runs under it (LF_Manoeuvre) and what is shouted. Adding a plan is
-- adding a row here (and a drill, if it needs a new kind of movement).
--   drill:   bound  - the two pairs leapfrog (dir: 1 forward, -1 back along the squad's front), one
--                     moving while the other covers, then they swap
--            route  - the same leapfrog along a route (a flank)
--            hold   - both pairs take cover where they are and fire; a team with no shot repositions
--            gather - each pair runs to its place round the sergeant (a regroup)
--   toContact:  an advance never takes a pair inside the stopping distance of the enemy
--   pinnedMove: the men go whether pinned or not (getting out from under the fire)
--   barks: squadBark (the sergeant, as he gives it), moveBark (a corporal, as a pair moves),
--          aloneBark (a corporal on his own), and the drill's own - {mover} {cover} {side} filled in.
-- The squad-level plans (FLANK, DEFEND) hand their teams other plans: FLANK sends the alpha teams
-- on a MANEUVER and holds the bravo teams; DEFEND is the perimeter or the building (LF_Defence).
local PLANS = {
    ADVANCE  = { drill = "bound", dir = 1, toContact = true,
                 squadBark = "Advance!", moveBark = "{mover}, move! {cover}, cover!", aloneBark = "On me - advance!" },
    FALLBACK = { drill = "bound", dir = -1, pinnedMove = true,
                 squadBark = "Fall back!", moveBark = "{mover}, back! {cover}, cover them!", aloneBark = "Fall back! Back!" },
    HOLD     = { drill = "hold",
                 squadBark = "Hold! Open fire!", shiftBark = "Can't see them - move! Find a shot!", aloneBark = "Hold here! Fire!" },
    MANEUVER = { drill = "route",
                 moveBark = "{mover}, move! {cover}, cover!", pushBark = "No good here - keep moving!", doneBark = "In position!" },
    FLANK    = { squadBark = "Alpha, flank {side}! Bravo, cover!", gunBark = "Alpha, flank that gun - {side}! Bravo, cover!" },
    REGROUP  = { drill = "gather", pinnedMove = true,
                 squadBark = "On me! Regroup!", doneBark = "All here!" },
    DEFEND   = { squadBark = "All-round defence! Get in cover!" },
}
LF.Tactics.PLANS = PLANS

-- A plan's words with its blanks filled in.
local function bark(text, vars)
    if not text then return nil end
    for k, v in pairs(vars or {}) do text = text:gsub("{" .. k .. "}", v) end
    return text
end
LF.Tactics.bark = bark

-- Do this squad's men move under its plan whether pinned or not?
function LF.Tactics.movesPinned(squadId)
    local sq = squads[squadId]
    local P = sq and sq.intent and PLANS[sq.intent]
    return P ~= nil and P.pinnedMove == true
end

-- ---- commander: intent ----------------------------------------------------------------------

local function setIntent(squad, sq, cid, intent, why)
    if sq.intent == intent then return end
    LF.log("INTENT " .. squad.name .. " " .. tostring(sq.intent) .. " -> " .. tostring(intent) .. " (" .. why .. ")")
    if sq.intent == "FLANK" then sq.lastFlank, sq.flank = LF.tick, nil end
    sq.intent = intent
    if intent == "HOLD" then sq.holdSince = LF.tick end
    -- (0.78 reaction test) A movement order: when did it come, has a man started moving yet.
    if intent == "ADVANCE" or intent == "FALLBACK" or intent == "FLANK" or intent == "REGROUP" then
        sq.moveOrderAt, sq.moveOrderMet = LF.tick, nil
    end
    if LF.Brain and LF.Brain.wakeSquad then LF.Brain.wakeSquad(squad.id, "order") end     -- (0.79: a new order - every man re-decides)
    if intent and cid then
        local P = PLANS[intent]
        local words = P and P.squadBark
        if intent == "FLANK" and sq.flank then
            words = bark(sq.flank.gun and P.gunBark or P.squadBark, { side = sq.flank.side < 0 and "left" or "right" })
        end
        if words then LF.Tactics.shout(cid, words) end
    end
end

-- ---- shared with the other tactics files ----------------------------------------------------
I.CFG = CFG I.ELEMENT_NAME = ELEMENT_NAME I.OTHER = OTHER I.elementCentre = elementCentre I.facing = facing
I.fit = fit I.setIntent = setIntent I.shouts = shouts I.squads = squads I.teams = teams I.PLANS = PLANS I.bark = bark
