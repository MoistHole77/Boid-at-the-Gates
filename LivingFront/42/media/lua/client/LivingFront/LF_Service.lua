-- Living Front: service records and earned traits.
--
-- Every soldier keeps a record of his war (saved with him, rec.svc):
--   battles - fights he has been in (shooting at, or being shot at, after a quiet spell)
--   kills   - enemy soldiers he shot who died of it
--   wounds  - times he has been hit
--   lost    - comrades from his own unit killed near him
--   broke   - times his unit broke and fell back
--   taken   - objectives his unit took
--   stress  - how much he has been through lately (comrades lost, wounds, his unit breaking);
--             it eases after a fight with no losses and a little each in-game day
--
-- Traits come from the record, not a dice roll, and change how he fights:
--   Green   - no battles yet (no effect; shown so you can watch him come up)
--   Veteran - 3+ battles: steadier under fire - suppression builds up more slowly on him, he
--             is pinned only at a higher level, and he shakes it off faster
--   Shaken  - stress 4+: suppression builds up faster and he is pinned at a lower level
-- (They can stack: a shaken veteran is roughly an ordinary soldier.)

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"

LF.Service = LF.Service or {}

local CFG = {
    battleGap = 3600,       -- ~60 s with no shooting at or by him ends a battle
    killCredit = 900,       -- a man who dies within ~15 s of being hit is the shooter's kill
    lostRadius = 40,        -- a comrade killed within this many tiles counts as lost
    veteranBattles = 3,
    shakenStress = 4,
    stressCap = 10,
    -- effects
    vetSuppress = 0.75, vetPin = 12, vetRecover = 1.3,
    shakenSuppress = 1.35, shakenPin = -12,
}
LF.Service.CFG = CFG

LF.Service.TRAITS = {
    green = { name = "Green", text = "Hasn't been in a battle yet." },
    veteran = { name = "Veteran", text = "Steady under fire: suppression builds up more slowly, he is harder to pin down "
        .. "and shakes it off faster." },
    shaken = { name = "Shaken", text = "Has been through too much lately: pinned down more easily. Eases after a fight "
        .. "without losses, and with time." },
}

local function svcOf(rec)
    if not rec then return nil end
    local s = rec.svc
    if not s then
        s = { battles = 0, kills = 0, wounds = 0, lost = 0, broke = 0, taken = 0, stress = 0 }
        rec.svc = s
    end
    return s
end
LF.Service.of = svcOf

-- Runtime only: when he was last in action, the fight he is in, and who last hit him.
local lastAction = {}   -- id -> tick
local current = {}      -- id -> { lost = n, hurt = bool }
local lastHit = {}      -- id -> { by = shooter id, tick }

local function title(rec) return LF.Units and LF.Units.title(rec) or LF.Records.fullName(rec) end

-- Work out his traits from his record; log any change.
local function refresh(rec)
    local s = svcOf(rec)
    local t = {}
    if s.battles == 0 then t[#t + 1] = "green" end
    if s.battles >= CFG.veteranBattles then t[#t + 1] = "veteran" end
    if s.stress >= CFG.shakenStress then t[#t + 1] = "shaken" end
    local key = table.concat(t, ",")
    if key ~= (s.traitKey or "") then
        if s.traitKey then
            LF.log("SERVICE #" .. rec.id .. " " .. title(rec) .. " is now " .. (key ~= "" and key or "steady")
                .. " (battles " .. s.battles .. ", stress " .. s.stress .. ")")
        end
        s.traitKey = key
    end
    s.traits = t
    s.veteran = s.battles >= CFG.veteranBattles or nil
    s.shaken = s.stress >= CFG.shakenStress or nil
end
LF.Service.refresh = refresh

local function addStress(s, n)
    s.stress = math.max(0, math.min(CFG.stressCap, s.stress + n))
end

-- He is in action (fired, was fired at, was hit). After a quiet spell this is a new battle.
function LF.Service.action(id)
    local rec = id and LF.Records.get(id)
    if not rec or not rec.alive or rec.faction == "CIV" and not rec.squad then return end
    local s = svcOf(rec)
    local last = lastAction[id]
    if not last or LF.tick - last > CFG.battleGap then
        -- The last fight went by without a loss or a wound: he steadies a little.
        local c = current[id]
        if c and c.lost == 0 and not c.hurt then addStress(s, -2) end
        s.battles = s.battles + 1
        current[id] = { lost = 0, hurt = false }
        refresh(rec)
    end
    lastAction[id] = LF.tick
end

-- A round fired by shooterId at targetId; hit or not.
function LF.Service.shot(shooterId, targetId, hit)
    LF.Service.action(shooterId)
    LF.Service.action(targetId)
    if hit and targetId then
        local rec = LF.Records.get(targetId)
        if rec then
            local s = svcOf(rec)
            s.wounds = s.wounds + 1
            addStress(s, 1)
            if current[targetId] then current[targetId].hurt = true end
            lastHit[targetId] = { by = shooterId, tick = LF.tick }
            refresh(rec)
        end
    end
end

-- A soldier died: credit the kill, and his comrades nearby lose a man.
function LF.Service.died(rec)
    local h = lastHit[rec.id]
    if h and h.by and LF.tick - h.tick <= CFG.killCredit then
        local killer = LF.Records.get(h.by)
        if killer and killer.faction ~= rec.faction then
            local s = svcOf(killer)
            s.kills = s.kills + 1
            refresh(killer)
        end
    end
    lastHit[rec.id], lastAction[rec.id], current[rec.id] = nil, nil, nil
    if not rec.squad then return end
    for id, r in pairs(LF.Records.all()) do
        local b = LF.Bodies and LF.Bodies.get(id)
        local rx, ry = r.x, r.y
        if b then rx, ry = b:getX(), b:getY() end
        if id ~= rec.id and r.alive and r.squad == rec.squad and LF.dist(rx, ry, rec.x, rec.y) <= CFG.lostRadius then
            local s = svcOf(r)
            s.lost = s.lost + 1
            addStress(s, 1)
            if current[id] then current[id].lost = current[id].lost + 1 end
            refresh(r)
        end
    end
end

-- His unit broke (fell back, shot to pieces).
function LF.Service.unitBroke(squad)
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.squad == squad.id then
            local s = svcOf(r)
            s.broke = s.broke + 1
            addStress(s, 3)
            refresh(r)
        end
    end
end

-- His unit took an objective.
function LF.Service.objectiveTaken(squad)
    for _, r in pairs(LF.Records.all()) do
        if r.alive and r.squad == squad.id then
            local s = svcOf(r)
            s.taken = s.taken + 1
            addStress(s, -1)
            refresh(r)
        end
    end
end

-- Time heals a little: each in-game day, everyone's stress eases by one.
Events.EveryDays.Add(function()
    LF.guard("service day", function()
        for _, r in pairs(LF.Records.all()) do
            if r.alive and r.svc and r.svc.stress > 0 then
                addStress(r.svc, -1)
                refresh(r)
            end
        end
    end)
end)

Events.OnInitGlobalModData.Add(function() lastAction, current, lastHit = {}, {}, {} end)

-- ---- effects (read by LF_Suppress) ------------------------------------------------------------

-- Multiplier on suppression he picks up.
function LF.Service.suppressMul(id)
    local rec = LF.Records.get(id)
    local s = rec and rec.svc
    if not s then return 1 end
    local m = 1
    if s.veteran then m = m * CFG.vetSuppress end
    if s.shaken then m = m * CFG.shakenSuppress end
    return m
end

-- Change to the suppression level at which he is pinned.
function LF.Service.pinShift(id)
    local rec = LF.Records.get(id)
    local s = rec and rec.svc
    if not s then return 0 end
    return (s.veteran and CFG.vetPin or 0) + (s.shaken and CFG.shakenPin or 0)
end

-- Multiplier on how fast his suppression fades.
function LF.Service.recoverMul(id)
    local rec = LF.Records.get(id)
    local s = rec and rec.svc
    return (s and s.veteran) and CFG.vetRecover or 1
end

-- His traits as a list of keys (see LF.Service.TRAITS).
function LF.Service.traits(rec)
    local s = svcOf(rec)
    if not s.traits then refresh(rec) end
    return s.traits
end
