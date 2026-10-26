-- Living Front: the platoon - a lieutenant and his four squads.
--
-- A platoon is its headquarters (LF_Units kind "hq") and four squads (kind "squad", each with
-- squad.platoon set; a machine-gun platoon has three rifle squads and a machine-gun squad):
--   lieutenant        - commands. A pistol, an officer's greatcoat and peaked cap. He gives each
--                       squad its task and then lets its sergeant run it, watching from cover
--                       behind the main effort. He changes a squad's task only for something its
--                       sergeant couldn't see coming: the assault failing, or a withdrawal.
--   platoon sergeant  - goes with the main-effort squad and steadies it (morale - LF_Morale). He
--                       hears every order the lieutenant gives, however far off; when the
--                       lieutenant can't make a sergeant hear him, the platoon sergeant runs the
--                       order over, then goes back to the main effort. (Runner duty is the
--                       exception: the lieutenant gives most orders by voice.)
--   radio operator    - the only man in the platoon with a radio; stays at the lieutenant's side.
-- If the lieutenant falls, the platoon sergeant takes command; with no officer left the squads
-- carry on with their last tasks on their own.
--
-- Missions (from the debug menu for now):
--   take (a building, or a spot) - the main effort (the fittest rifle squad) takes it as a squad
--          objective (LF_Objective: approach, assault, clear, consolidate). The other squad - the
--          machine-gun squad if there is one - is the support: it goes to a support-by-fire
--          position ~22 tiles off the objective, out to a flank of the assault, and from there
--          keeps the building's windows under fire (it doesn't advance, flank or clear).
--          The rest are the reserve: they wait in cover behind the main effort, ~20 tiles short.
--          Objective taken: the main effort holds it, the support digs in where it is to cover
--          it, and all are told they did well (morale).
--          The assault breaks: the lieutenant commits the reserve - a rifle squad in good shape
--          takes over the assault and the broken squad covers it (failing a reserve, a rifle
--          support squad does); with nobody left to send, or the platoon down to under 45% fit,
--          he pulls the platoon out.
--   hold (a building, or a spot) - the main effort holds it; each other squad holds one of the
--          nearest other buildings within 25 tiles (or digs in where it is). Withdraws when the
--          platoon is down to under 30% fit.
--   withdraw (to a point) - every squad breaks contact (falls back by bounds until out of range),
--          then marches to the point and digs in there.
-- Orders are spoken: a squad sergeant within earshot (30 tiles) of the lieutenant gets his at
-- once. Further off, the platoon sergeant carries it; without him, the lieutenant goes himself.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Squad"
require "LivingFront/Units/LF_March"
require "LivingFront/Units/LF_Objective"
require "LivingFront/World/LF_Bodies"
require "LivingFront/World/LF_Building"
require "LivingFront/World/LF_Cover"
require "LivingFront/Soldier/LF_Morale"
require "LivingFront/Tactics/LF_Command"

LF.Platoon = LF.Platoon or {}

local CFG = {
    updateTicks = 60,
    earshot = 30,           -- the lieutenant's voice
    runnerReach = 5,        -- the platoon sergeant hands an order over this close
    runnerTimeout = 3600,   -- ~60 s: an order that hasn't arrived is given up on
    ltBehind = 10,          -- the lieutenant watches from this far behind the main effort's sergeant
    ssgtBehind = 3,         -- the platoon sergeant this far behind it
    rtoBeside = 1.8,
    sbfRange = 22,          -- the support-by-fire position: this far from the objective ...
    sbfAngles = { 65, 85, 45 },   -- ... this many degrees off the assault's line
    holdNear = 25,
    reserveBack = 20,       -- the reserve waits this far short of the objective, behind the main effort          -- holding: the second squad takes a building within this
    takeOverFit = 0.6,      -- the support takes over a failed assault if this share of it is fit
    withdrawTake = 0.45,    -- the platoon is pulled out of an attack below this share fit
    withdrawHold = 0.30,    -- ... out of a defence below this
    withdrawBack = 35,      -- with no rally point, it withdraws this far back from the enemy
    clearOfEnemy = 28,      -- a withdrawing squad marches once no enemy is known this close
    arriveDist = 8,
    assembly = 40,          -- taking an objective from afar: the platoon moves up together to this far short of it
    abreast = 7,            -- a platoon patrol, two squads: each this far out from the line of march
    abreastGap = 10,        -- ... more squads: this far apart, side by side
    hqBehind = 4,           -- ... the headquarters this far behind the rearmost man
}
LF.Platoon.CFG = CFG

local state = {}            -- platoon id -> { queue = {orders}, runner = {...}, walkTo } (runtime)
Events.OnInitGlobalModData.Add(function() state = {} end)
local function S(p)
    local s = state[p.id]
    if not s then s = { queue = {} }; state[p.id] = s end
    return s
end

local function title(rec) return rec and LF.Units.title(rec) or "?" end
local function bodyOf(id)
    local b = id and LF.Bodies.get(id)
    if b and not b:isDead() then return b end
    return nil
end
local function fit(rec) return LF.Tactics.I.fit(rec) end

local function platoonOf(unit) return unit and unit.platoon and LF.Units.get(unit.platoon) or nil end
LF.Platoon.of = platoonOf
local function hqOf(p) return p and LF.Units.get(p.hq) or nil end

-- The platoon's commander now (the lieutenant, or the platoon sergeant who took over), or nil.
local function commander(p)
    if p.leaderless then return nil end
    local hq = hqOf(p)
    local r = hq and hq.leader and LF.Records.get(hq.leader)
    if r and r.alive then return r end
    return nil
end
LF.Platoon.commander = commander

-- The platoon sergeant, if he is not in command himself.
local function ssgtOf(p)
    local hq = hqOf(p)
    if not hq then return nil end
    for _, rid in ipairs(LF.Units.members(hq.id)) do
        local r = LF.Records.get(rid)
        if r and r.alive and r.hqRole == "ssgt" and rid ~= hq.leader then return r end
    end
    return nil
end

local function squadsOf(p)
    local out = {}
    for _, sid in ipairs(p.squads or {}) do
        local s = LF.Units.get(sid)
        if s and s.kind == "squad" then out[#out + 1] = s end
    end
    return out
end

-- Share of a unit's men who are fit to fight (and how many).
local function fitShare(unit)
    local n, f = 0, 0
    for _, rid in ipairs(LF.Units.members(unit.id)) do
        local r = LF.Records.get(rid)
        if r then
            n = n + 1
            if fit(r) then f = f + 1 end
        end
    end
    return n > 0 and f / n or 0, f
end

local function platoonFit(p)
    local n, f = 0, 0
    for _, s in ipairs(squadsOf(p)) do
        for _, rid in ipairs(LF.Units.members(s.id)) do
            local r = LF.Records.get(rid)
            if r then
                n = n + 1
                if fit(r) then f = f + 1 end
            end
        end
    end
    return n > 0 and f / n or 0
end

local function cmdBodyOf(unit)
    local cid = unit and LF.Units.commander(unit)
    return bodyOf(cid), cid
end

local function posOf(unit)
    local b = cmdBodyOf(unit)
    if b then return b:getX(), b:getY(), math.floor(b:getZ()) end
    local x, y, z = LF.Squad.anchor(unit.id)
    if x then return x, y, math.floor(z or 0) end
    return nil
end

-- The nearest enemy any unit of the platoon knows of, to (x, y).
local function platoonContact(p, x, y, range)
    local best, bd = nil, (range or 60)
    local units = { p.hq }
    for _, sid in ipairs(p.squads or {}) do units[#units + 1] = sid end
    for _, uid in ipairs(units) do
        local c = LF.Squad.bestContact(uid, x, y, LF.Tactics.CFG.contactMemory, bd)
        if c then
            local d = LF.dist(x, y, c.x, c.y)
            if d < bd then best, bd = c, d end
        end
    end
    return best, bd
end
LF.Platoon.contact = platoonContact

local function shout(id, words) if id and bodyOf(id) then LF.Tactics.shout(id, words) end end

-- ---- making a platoon -----------------------------------------------------------------------

local function nextNumber(faction)
    local n = 0
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "platoon" and u.faction == faction then n = n + 1 end
    end
    return n + 1
end

-- A platoon at (x, y) facing (fx, fy): its headquarters centre rear, its four squads in a line
-- ahead of it, 1 squad on the left to 4 squad (the machine-gun squad, with mg) on the right.
function LF.Platoon.create(faction, x, y, z, fx, fy, mg)
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.01 then fx, fy, len = 1, 0, 1 end
    fx, fy = fx / len, fy / len
    local rx, ry = -fy, fx
    local function at(fwd, lat) return x + fx * fwd + rx * lat, y + fy * fwd + ry * lat end
    local n = nextNumber(faction)
    local p = LF.Units.newUnit({ kind = "platoon", faction = faction, name = faction .. " platoon " .. n, squads = {},
        facingX = fx, facingY = fy })
    local hq = LF.Units.newUnit({ kind = "hq", faction = faction, platoon = p.id, name = p.name .. " HQ", teams = {},
        stance = "standby", facingX = fx, facingY = fy })
    p.hq = hq.id
    local lx, ly = at(-3, 0)
    local lt = LF.Units.placeSoldier(faction, lx, ly, z, { squad = hq.id, rank = "LT", element = "L", slot = 0, hqRole = "lt" })
    hq.leader = lt.id
    local team = LF.Units.newUnit({ kind = "team", faction = faction, squad = hq.id, name = "HQ", element = "B", members = {} })
    hq.teams[1] = team.id
    local sx, sy = at(-5, 2)
    local ssgt = LF.Units.placeSoldier(faction, sx, sy, z, { squad = hq.id, team = team.id, rank = "SSG", element = "B",
        slot = 1, hqRole = "ssgt", grenades = 1 })
    local ox, oy = at(-4.5, -1.5)
    local rto = LF.Units.placeSoldier(faction, ox, oy, z, { squad = hq.id, team = team.id, rank = "PVT", element = "B",
        slot = 2, hqRole = "rto" })
    team.members = { ssgt.id, rto.id }
    local SPOTS = { { 5, -15 }, { 8, -5 }, { 8, 5 }, { 5, 15 } }
    local names = {}
    for i, sp in ipairs(SPOTS) do
        local isMG = mg and i == #SPOTS
        local qx, qy = at(sp[1], sp[2])
        local sq = LF.Units.createSquad(faction, qx, qy, z, fx, fy, false, isMG)
        sq.platoon = p.id
        sq.name = p.name .. " / " .. i .. (isMG and " MG squad" or " squad")
        p.squads[#p.squads + 1] = sq.id
        names[#names + 1] = sq.name
    end
    LF.log("PLATOON created " .. p.name .. " (#" .. p.id .. "): " .. title(lt) .. ", " .. title(ssgt) .. " (platoon sergeant), "
        .. title(rto) .. " (radio), " .. table.concat(names, ", "))
    return p
end

-- ---- succession -----------------------------------------------------------------------------

-- The headquarters' leader is gone (killed, or too badly hurt): the platoon sergeant takes the
-- platoon. Returns false if nobody could take over (a relieved lieutenant then keeps it).
function LF.Platoon.handOver(hq, rec, why)
    local p = LF.Units.get(hq.platoon)
    local team = LF.Units.get(hq.teams[1])
    local function able(r)
        if not (r and r.alive and not r.wounded) then return false end
        local b = bodyOf(r.id)
        return not b or LF.Combat.health(b) >= LF.Units.woundedHealth
    end
    local function takeOut(r)
        if team then
            for i = #team.members, 1, -1 do if team.members[i] == r.id then table.remove(team.members, i) end end
        end
        r.team, r.element, r.slot = nil, "L", 0
    end
    local new = nil
    for _, rid in ipairs(team and team.members or {}) do
        local r = LF.Records.get(rid)
        if r and r.hqRole == "ssgt" and able(r) then new = r end
    end
    if not new and rec.alive then return false end
    if not new then
        -- No officer left: the radio operator keeps the headquarters together, nobody commands
        -- the platoon.
        for _, rid in ipairs(team and team.members or {}) do
            local r = LF.Records.get(rid)
            if r and r.alive then new = r; break end
        end
        if p then
            p.leaderless = true
            LF.log("PLATOON " .. p.name .. ": no officer left (" .. why .. ") - the squads fight on alone")
        end
        hq.leader = new and new.id or nil
        if new then takeOut(new) end
        LF.Units.dirty(hq.id)
        return true
    end
    takeOut(new)
    hq.leader = new.id
    if rec.alive and team then
        team.members[#team.members + 1] = rec.id
        rec.team, rec.element, rec.slot = team.id, "B", #team.members
    end
    LF.Units.dirty(hq.id)
    if p then
        local s = S(p)
        if s.runner then table.insert(s.queue, 1, s.runner.order); s.runner = nil end
        LF.log("PLATOON " .. p.name .. ": " .. title(new) .. " takes command (" .. why .. ")")
    end
    shout(new.id, "The lieutenant's down - I have the platoon!")
    return true
end

-- ---- orders ---------------------------------------------------------------------------------

-- A support-by-fire position for squad `sup` on objective `obj`, the assault coming from (ax, ay):
-- ~22 tiles from the objective, out to a flank of the assault's line (the side the squad is
-- already on first), on open ground with a view of one of the building's windows.
local function sbfSpot(obj, ax, ay, sup)
    local ox, oy, z = obj.x, obj.y, obj.z
    local dx, dy = ax - ox, ay - oy
    local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    dx, dy = dx / d, dy / d
    local sx, sy = posOf(sup)
    local first = 1
    if sx then first = ((sx - ox) * dy - (sy - oy) * dx) > 0 and -1 or 1 end
    local L = obj.building and LF.Building.at(obj.x, obj.y, obj.z)
    local cell = getCell()
    local function seesIn(x, y)
        if not L then return true end
        for _, o in ipairs(L.openings) do
            if o.kind == "window" and LF.dist(x, y, o.x, o.y) < CFG.sbfRange + 8
                and LF.Cover.canSeeFrom(x, y, z, LF.Tactics.point(o.x + 0.5, o.y + 0.5, z)) then return true end
        end
        return false
    end
    for _, side in ipairs({ first, -first }) do
        for _, deg in ipairs(CFG.sbfAngles) do
            local a = math.rad(deg) * side
            local vx, vy = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
            local px, py = math.floor(ox + vx * CFG.sbfRange), math.floor(oy + vy * CFG.sbfRange)
            for r = 0, 3 do
                for ddx = -r, r do
                    for ddy = -r, r do
                        if math.max(math.abs(ddx), math.abs(ddy)) == r then
                            local sq = cell:getGridSquare(px + ddx, py + ddy, z)
                            if sq and sq:isFree(false) and not sq:getBuilding() and seesIn(px + ddx, py + ddy) then
                                return px + ddx, py + ddy, z
                            end
                        end
                    end
                end
            end
        end
    end
    -- Nowhere better: straight back down the assault's line, off to one side.
    return math.floor(ox + dx * CFG.sbfRange - dy * 8 * first), math.floor(oy + dy * CFG.sbfRange + dx * 8 * first), z
end

-- What the support squad fires on when nobody is in sight: the objective's nearest window.
local aims = {}             -- squad id -> { point, at }
Events.OnInitGlobalModData.Add(function() aims = {} end)
function LF.Platoon.supportContact(squad)
    local t = squad.sbf
    if not (t and t.inPlace) then return nil end
    local obj = LF.Objective.get(t.obj)
    if not obj then return nil end
    local a = aims[squad.id]
    if a and LF.tick - a.at < 600 then return a.point end
    local px, py = obj.x, obj.y
    local x, y = posOf(squad)
    local L = x and obj.building and LF.Building.at(obj.x, obj.y, obj.z)
    if L then
        local best, bd = nil, math.huge
        for _, o in ipairs(L.openings) do
            if o.kind == "window" then
                local d = LF.dist(x, y, o.x + 0.5, o.y + 0.5)
                if d < bd then best, bd = o, d end
            end
        end
        if best then px, py = best.x + 0.5, best.y + 0.5 end
    end
    a = a or { point = LF.Tactics.point(px, py, obj.z) }
    a.point.x, a.point.y, a.point.z, a.at = px, py, obj.z, LF.tick
    aims[squad.id] = a
    return a.point
end

-- Clear whatever platoon task a squad had.
local function clearTask(squad)
    squad.platoonTask, squad.supportOnly, squad.sbf, squad.withdrawTo, squad.reserveAt = nil, nil, nil, nil, nil
end

-- Carry out an order (the squad's sergeant has it now).
local function apply(p, o)
    local squad = LF.Units.get(o.squad)
    if not squad then return end
    -- Its men aren't here (bodies only exist near you): the order waits for them.
    if o.kind ~= "dig" and o.kind ~= "withdraw" and not cmdBodyOf(squad) then
        local s = S(p)
        s.waiting = s.waiting or {}
        for i = #s.waiting, 1, -1 do if s.waiting[i].squad == o.squad then table.remove(s.waiting, i) end end
        s.waiting[#s.waiting + 1] = o
        if not o.waitLogged then
            o.waitLogged = true
            LF.log("PLATOON " .. p.name .. ": " .. squad.name .. "'s men aren't here yet - its order (" .. o.kind .. ") waits for them")
        end
        return
    end
    local obj = o.obj and LF.Objective.get(o.obj)
    LF.log("PLATOON " .. p.name .. ": " .. squad.name .. " has its orders - " .. o.kind)
    if o.kind == "take" and obj then
        clearTask(squad)
        squad.platoonTask = "take"
        local ok, why = LF.Objective.take(squad, obj)
        if not ok then LF.log("PLATOON " .. squad.name .. " can't take " .. obj.name .. ": " .. tostring(why)) end
    elseif o.kind == "support" and obj then
        clearTask(squad)
        squad.objTask = nil
        squad.platoonTask, squad.supportOnly = "support", true
        squad.sbf = { obj = obj.id, x = o.x, y = o.y, z = o.z }
        local x, y = posOf(squad)
        if x and LF.dist(x, y, o.x, o.y) > CFG.arriveDist then
            local ok, why = LF.March.order(squad, o.x, o.y, o.z, "auto", { noGather = true })
            if not ok then
                LF.log("PLATOON " .. squad.name .. " can't reach its support position (" .. tostring(why) .. ") - supports from here")
                LF.Platoon.onArrived(squad)
            end
        else
            LF.Platoon.onArrived(squad)
        end
    elseif o.kind == "cover" and obj then
        -- (The squad whose assault failed: it stays where it is and covers the one taking over.)
        clearTask(squad)
        squad.objTask = nil
        squad.platoonTask, squad.supportOnly = "support", true
        local x, y, z = posOf(squad)
        squad.sbf = { obj = obj.id, x = x and math.floor(x) or obj.x, y = y and math.floor(y) or obj.y, z = z or obj.z, inPlace = true }
        LF.Tactics.setStance(squad, "offensive")
    elseif o.kind == "reserve" then
        -- Behind the main effort, out of the fight until the lieutenant sends it in.
        clearTask(squad)
        squad.objTask = nil
        squad.platoonTask = "reserve"
        squad.reserveAt = { x = o.x, y = o.y, z = o.z }
        local x, y = posOf(squad)
        if x and LF.dist(x, y, o.x, o.y) > CFG.arriveDist and LF.March.order(squad, o.x, o.y, o.z, "auto", { noGather = true }) then
            return
        end
        LF.Platoon.onArrived(squad)
    elseif o.kind == "dig" then
        clearTask(squad)
        squad.platoonTask = "dig"
        LF.Tactics.setStance(squad, "defensive")
    elseif o.kind == "hold" and obj then
        clearTask(squad)
        squad.platoonTask = "hold"
        local x, y = posOf(squad)
        if x and LF.dist(x, y, obj.x, obj.y) > 25 then
            local ok = LF.March.order(squad, math.floor(obj.x), math.floor(obj.y), obj.z, "auto", { noGather = true })
            if ok then squad.pendingHold = obj.id else LF.Objective.hold(squad, obj) end
        else
            LF.Objective.hold(squad, obj)
        end
    elseif o.kind == "withdraw" then
        clearTask(squad)
        squad.objTask, squad.pendingHold = nil, nil
        squad.platoonTask = "withdraw"
        squad.withdrawTo = { x = o.x, y = o.y, z = o.z }
        LF.March.cancel(squad.id)
        if LF.Stance.get(squad).name ~= "offensive" then LF.Tactics.setStance(squad, "offensive") end
        LF.Morale.withdraw(squad)
    end
end

-- Give an order: by voice if its sergeant can hear the lieutenant, else by runner.
local function issue(p, o)
    local cmd = commander(p)
    local cb = cmd and bodyOf(cmd.id)
    local squad = LF.Units.get(o.squad)
    local sb = cmdBodyOf(squad)
    if not (cb and sb) or LF.dist(cb:getX(), cb:getY(), sb:getX(), sb:getY()) <= CFG.earshot then
        if cb then shout(cmd.id, o.words) end
        apply(p, o)
        return
    end
    LF.log("PLATOON " .. p.name .. ": " .. squad.name .. " is out of earshot (" .. math.floor(LF.dist(cb:getX(), cb:getY(), sb:getX(), sb:getY()))
        .. " tiles) - the order goes by runner")
    local s = S(p)
    -- (A newer order to the same squad replaces one still waiting.)
    for i = #s.queue, 1, -1 do if s.queue[i].squad == o.squad then table.remove(s.queue, i) end end
    s.queue[#s.queue + 1] = o
end

local function short(squad) return (squad.name:gsub("^.* / ", "")) end

-- Orders on their way: the platoon sergeant runs them over; without him the lieutenant walks
-- until his sergeant can hear him.
local function deliver(p)
    local s = S(p)
    local cmd = commander(p)
    local cb = cmd and bodyOf(cmd.id)
    -- Orders waiting for a squad's men to be here.
    if s.waiting and #s.waiting > 0 then
        local w = s.waiting
        s.waiting = {}
        for _, o in ipairs(w) do apply(p, o) end
    end
    if s.runner then
        local r = s.runner
        local rb = bodyOf(r.id)
        local squad = LF.Units.get(r.order.squad)
        local sb = cmdBodyOf(squad)
        if not rb or not squad then
            -- The runner is down: the order waits for another way.
            table.insert(s.queue, 1, r.order)
            s.runner = nil
        elseif not sb then
            apply(p, r.order); s.runner = nil
        elseif LF.dist(rb:getX(), rb:getY(), sb:getX(), sb:getY()) <= CFG.runnerReach then
            shout(r.id, "From the lieutenant: " .. r.order.words)
            LF.log("PLATOON " .. p.name .. ": " .. title(LF.Records.get(r.id)) .. " delivers the order to " .. squad.name)
            apply(p, r.order)
            s.runner = nil
        elseif LF.tick - r.since > CFG.runnerTimeout then
            LF.log("PLATOON " .. p.name .. ": the runner never got through to " .. squad.name .. " - order dropped")
            s.runner = nil
        end
        return
    end
    local o = s.queue[1]
    if not o then s.walkTo = nil; return end
    local squad = LF.Units.get(o.squad)
    local sb = cmdBodyOf(squad)
    if not squad then table.remove(s.queue, 1); return end
    if not (cb and sb) or LF.dist(cb:getX(), cb:getY(), sb:getX(), sb:getY()) <= CFG.earshot then
        table.remove(s.queue, 1)
        s.walkTo = nil
        if cb then shout(cmd.id, o.words) end
        apply(p, o)
        return
    end
    local ss = ssgtOf(p)
    local sbody = ss and fit(ss) and bodyOf(ss.id)
    if sbody then
        table.remove(s.queue, 1)
        s.runner = { id = ss.id, order = o, since = LF.tick }
        s.walkTo = nil
        LF.log("PLATOON " .. p.name .. ": " .. title(ss) .. " runs the order to " .. squad.name)
        shout(ss.id, "I'll take it to " .. short(squad) .. "!")
    else
        s.walkTo = squad.id
    end
end

-- ---- missions -------------------------------------------------------------------------------

local function setHQStance(p, stance)
    local hq = hqOf(p)
    if hq and hq.stance ~= stance then hq.stance = stance end
end

-- The rifle squads, fittest first, and the machine-gun squad.
-- (Main effort rifles[1]; support the machine-gun squad, else rifles[2]; the rest the reserve.)
local function rolesFor(p)
    local rifles, mg = {}, nil
    for _, s in ipairs(squadsOf(p)) do
        if s.mg then mg = mg or s else rifles[#rifles + 1] = s end
    end
    local fitN = {}
    for _, s in ipairs(rifles) do local _, n = fitShare(s); fitN[s.id] = n end
    table.sort(rifles, function(a, b) return fitN[a.id] > fitN[b.id] end)
    return rifles, mg
end

-- Take an objective.
function LF.Platoon.take(p, obj)
    local rifles, mg = rolesFor(p)
    local main = rifles[1]
    if not main then return false, "it has no rifle squad left to make the assault" end
    local sup = mg or rifles[2]
    local reserve = {}
    for _, s2 in ipairs(rifles) do
        if s2 ~= main and s2 ~= sup then reserve[#reserve + 1] = s2.id end
    end
    p.mission = { kind = "take", obj = obj.id, phase = "approach", since = LF.tick, main = main.id, support = sup and sup.id,
        reserve = reserve, committed = {} }
    p.mainEffort = main.id
    local hx, hy, hz = posOf(hqOf(p) or main)
    if not hx then hx, hy, hz = posOf(main) end
    p.home = hx and { x = math.floor(hx), y = math.floor(hy), z = hz } or nil
    S(p).queue, S(p).runner = {}, nil
    setHQStance(p, "offensive")
    LF.log("PLATOON " .. p.name .. " ordered to take " .. obj.name .. ": main effort " .. main.name
        .. (sup and (", support " .. sup.name) or "") .. ", " .. #reserve .. " squad(s) in reserve")
    -- Far off: the platoon moves up together to an assembly area short of it first.
    local d = hx and LF.dist(hx, hy, obj.x, obj.y) or 0
    if d > CFG.assembly + 15 then
        local ax, ay = obj.x + (hx - obj.x) / d * CFG.assembly, obj.y + (hy - obj.y) / d * CFG.assembly
        p.mission.assembly = { x = math.floor(ax), y = math.floor(ay), z = obj.z }
        local cmd = commander(p)
        if cmd then shout(cmd.id, "Platoon - we're taking that " .. (obj.building and "building" or "position") .. ". Move out!") end
        local ok, why = LF.Platoon.move(p, ax, ay, obj.z)
        if not ok then
            p.mission.pendingMove = true
            LF.log("PLATOON " .. p.name .. " can't move off yet (" .. tostring(why) .. ") - it will as soon as it can")
        end
        return true
    end
    LF.Platoon.deploy(p, p.mission, "close enough to go straight in")
    return true
end

-- The assault: the main effort takes the objective, the support goes to its fire position.
function LF.Platoon.deploy(p, m, why)
    local obj = LF.Objective.get(m.obj)
    if not obj then return end
    m.phase = "assault"
    LF.Platoon.stopMove(p)
    local main = LF.Units.get(m.main)
    local sup = m.support and LF.Units.get(m.support)
    LF.log("PLATOON " .. p.name .. " deploys for the assault on " .. obj.name .. " (" .. why .. ")")
    if main then
        issue(p, { squad = main.id, kind = "take", obj = obj.id,
            words = short(main) .. ", you're the main effort - take that " .. (obj.building and "building" or "position") .. "!" })
    end
    if sup then
        local mx, my = posOf(main or sup)
        local x, y, z = sbfSpot(obj, mx or obj.x + 20, my or obj.y, sup)
        m.sbf = { x = x, y = y, z = z }
        issue(p, { squad = sup.id, kind = "support", obj = obj.id, x = x, y = y, z = z,
            words = short(sup) .. ", support by fire from the flank - keep their heads down!" })
    end
    -- The reserve: short of the objective on the main effort's line, spread a little apart.
    local mx, my = posOf(main or sup or hqOf(p))
    local rs = m.reserve or {}
    for i, rid in ipairs(rs) do
        local r = LF.Units.get(rid)
        if r and mx then
            local dx, dy = mx - obj.x, my - obj.y
            local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
            dx, dy = dx / d, dy / d
            local back = math.max(CFG.reserveBack, math.min(d, CFG.reserveBack + 10))
            local lat = (i - (#rs + 1) / 2) * 8
            local x, y = math.floor(obj.x + dx * back - dy * lat), math.floor(obj.y + dy * back + dx * lat)
            issue(p, { squad = r.id, kind = "reserve", x = x, y = y, z = obj.z,
                words = short(r) .. ", you're the reserve - stay back in cover and be ready!" })
        end
    end
end

-- Hold an objective.
function LF.Platoon.hold(p, obj)
    local rifles, mg = rolesFor(p)
    local main = rifles[1] or mg
    if not main then return false, "it has no squad left" end
    local others = {}
    for _, s in ipairs(squadsOf(p)) do if s ~= main then others[#others + 1] = s end end
    p.mission = { kind = "hold", obj = obj.id, phase = "hold", since = LF.tick, main = main.id, support = others[1] and others[1].id,
        seconds = {} }
    p.mainEffort = main.id
    S(p).queue, S(p).runner = {}, nil
    setHQStance(p, "offensive")
    issue(p, { squad = main.id, kind = "hold", obj = obj.id, words = short(main) .. ", hold that " .. (obj.building and "building" or "ground") .. "!" })
    -- Each other squad: the nearest building within reach not already given out; else it digs in.
    local used = {}
    if obj.building then used[obj.building] = true end
    for _, second in ipairs(others) do
        local o2 = nil
        for r = 8, CFG.holdNear, 3 do
            for k = 0, 15 do
                local a = k * math.pi / 8
                local x, y = math.floor(obj.x + math.cos(a) * r), math.floor(obj.y + math.sin(a) * r)
                local id = not o2 and LF.Building.idAt(x, y, obj.z)
                if id and not used[id] then
                    local exists = nil
                    for _, oo in pairs(LF.Objective.all()) do if oo.building == id then exists = oo end end
                    o2 = exists or LF.Objective.create(x, y, obj.z)
                    if o2 then used[id] = true end
                end
            end
            if o2 then break end
        end
        if o2 then
            p.mission.seconds[#p.mission.seconds + 1] = o2.id
            p.mission.second = p.mission.second or o2.id
            issue(p, { squad = second.id, kind = "hold", obj = o2.id, words = short(second) .. ", hold " .. o2.name .. " - cover their flank!" })
        else
            -- (No other building near: it digs in where it is, covering the objective.)
            issue(p, { squad = second.id, kind = "dig", words = short(second) .. ", dig in where you are - cover the building!" })
        end
    end
    return true
end

-- Withdraw to (x, y).
function LF.Platoon.withdraw(p, x, y, z, why)
    p.mission = { kind = "withdraw", x = math.floor(x), y = math.floor(y), z = z or 0, phase = "withdraw", since = LF.tick }
    S(p).queue = {}
    setHQStance(p, "offensive")
    LF.log("PLATOON " .. p.name .. " withdraws to " .. math.floor(x) .. "," .. math.floor(y) .. " (" .. (why or "ordered") .. ")")
    local cmd = commander(p)
    if cmd then shout(cmd.id, "Platoon - withdraw! Fall back by squads!") end
    for _, s in ipairs(squadsOf(p)) do
        issue(p, { squad = s.id, kind = "withdraw", x = math.floor(x), y = math.floor(y), z = z or 0,
            words = short(s) .. ", fall back to the rally point - go!" })
    end
    return true
end

-- Move the platoon to (x, y). The sergeant of the lead squad picks the formation from the ground:
--   ranger file / tactical column - one file: the lead squad, the other squads behind it one after
--       another (each sergeant at his squad's head), the headquarters at the rear
--   wedge - the squads abreast (10 tiles apart), each sergeant leading his squad, the
--       headquarters in the centre behind them
-- Returns true, or false and why (its men aren't here yet: try again later).
function LF.Platoon.move(p, x, y, z)
    local rifles, mg = rolesFor(p)
    local order = {}
    for _, s2 in ipairs(rifles) do order[#order + 1] = s2 end
    if mg then order[#order + 1] = mg end
    local lead = order[1]
    if not lead then return false, "it has no squads" end
    for _, sq in ipairs(order) do
        local cid = LF.Units.commander(sq)
        if not (cid and LF.Bodies.get(cid)) then return false, sq.name .. "'s men aren't here (too far from you)" end
    end
    for _, sq in ipairs(order) do clearTask(sq); sq.objTask = nil; LF.March.cancel(sq.id) end
    local group = {}
    for i = 2, #order do group[#group + 1] = order[i].id end
    group[#group + 1] = p.hq
    lead.marchGroup = group
    local ok, why = LF.March.order(lead, math.floor(x), math.floor(y), z or 0, "auto", { noGather = true, platoonPatrol = true })
    if not ok then lead.marchGroup = nil; return false, why end
    local M = LF.March.get(lead.id)
    local cx, cy = posOf(lead)
    local dx, dy = x - (cx or x - 1), y - (cy or y)
    local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    dx, dy = dx / d, dy / d
    p.facingX, p.facingY = dx, dy
    for _, sq in ipairs(order) do sq.platoonTask = "patrol" end
    if M and M.form ~= "wedge" then
        p.move = { x = x, y = y, z = z or 0, mode = "file", lead = lead.id, since = LF.tick }
        LF.log("PLATOON " .. p.name .. " moves to " .. math.floor(x) .. "," .. math.floor(y) .. " in one file ("
            .. LF.March.FORMATIONS[M.form] .. "): " .. lead.name .. " leads, the headquarters at the rear")
        return true
    end
    -- Open ground: the squads abreast instead.
    LF.March.cancel(lead.id)
    lead.marchGroup = nil
    local rx, ry = -dy, dx
    local side = {}
    for _, sq in ipairs(order) do
        local sx, sy = posOf(sq)
        side[sq.id] = sx and ((sx - (cx or sx)) * rx + (sy - (cy or sy)) * ry) or 0
    end
    table.sort(order, function(a, b) return side[a.id] < side[b.id] end)
    local gap = #order <= 2 and CFG.abreast * 2 or CFG.abreastGap
    for i, sq in ipairs(order) do
        local l = (i - (#order + 1) / 2) * gap
        local ok2, why2 = LF.March.order(sq, math.floor(x + rx * l), math.floor(y + ry * l), z or 0, "wedge",
            { noGather = true, platoonPatrol = true })
        if not ok2 then LF.log("PLATOON " .. sq.name .. " can't move: " .. tostring(why2)) end
        sq.platoonTask = "patrol"
    end
    p.move = { x = x, y = y, z = z or 0, mode = "abreast", since = LF.tick }
    LF.log("PLATOON " .. p.name .. " moves to " .. math.floor(x) .. "," .. math.floor(y) .. " in wedges, squads abreast, the headquarters centre rear")
    return true
end

function LF.Platoon.stopMove(p)
    if not p.move then return end
    for _, sq in ipairs(squadsOf(p)) do
        sq.marchGroup = nil
        if sq.platoonTask == "patrol" then sq.platoonTask = nil end
        LF.March.cancel(sq.id)
    end
    LF.March.cancel(p.hq)
    p.move = nil
    local hq = hqOf(p)
    if hq and hq.stance == "patrolling" then hq.stance = "offensive" end
end

-- Has the platoon got where it was moving to?
local function moveArrived(p)
    local mv = p.move
    if not mv then return true end
    if mv.mode == "file" then
        local M = LF.March.get(mv.lead)
        return M == nil or M.arrived == true
    end
    for _, sq in ipairs(squadsOf(p)) do
        local M = LF.March.get(sq.id)
        if M and not M.arrived then return false end
    end
    return true
end

-- Patrol to (x, y).
function LF.Platoon.patrol(p, x, y, z)
    local ok, why = LF.Platoon.move(p, x, y, z)
    if not ok then return false, why end
    p.mission = { kind = "patrol", x = math.floor(x), y = math.floor(y), z = z or 0, phase = "moving", since = LF.tick }
    S(p).queue, S(p).runner = {}, nil
    setHQStance(p, "offensive")
    local cmd = commander(p)
    if cmd then shout(cmd.id, "Platoon - move out!") end
    return true
end

-- Where the headquarters walks on a platoon patrol: centred between the squads, just behind their
-- rearmost men. x, y and whether the squads are on the move.
local function patrolSpot(p)
    local fx, fy = p.facingX or 1, p.facingY or 0
    local sx, sy, n, rear = 0, 0, 0, math.huge
    local moving = false
    for _, sq in ipairs(squadsOf(p)) do
        local M = LF.March.get(sq.id)
        if M and not M.arrived and not M.halted then moving = true end
        for _, rid in ipairs(LF.Units.members(sq.id)) do
            local r = LF.Records.get(rid)
            local b = r and r.alive and bodyOf(rid)
            if b then
                local x, y = b:getX(), b:getY()
                sx, sy, n = sx + x, sy + y, n + 1
                rear = math.min(rear, x * fx + y * fy)
            end
        end
    end
    if n == 0 then return nil end
    sx, sy = sx / n, sy / n
    local back = (sx * fx + sy * fy) - rear + CFG.hqBehind
    return sx - fx * back, sy - fy * back, moving
end

-- Where to pull back to: the platoon's start point, or straight back from the enemy.
local function rallyPoint(p)
    if p.home then return p.home.x, p.home.y, p.home.z end
    local hq = hqOf(p)
    local x, y, z = posOf(hq)
    if not x then return nil end
    local c = platoonContact(p, x, y, 60)
    local dx, dy = -(p.facingX or 1), -(p.facingY or 0)
    if c then
        local vx, vy = x - c.x, y - c.y
        local d = math.max(0.1, math.sqrt(vx * vx + vy * vy))
        dx, dy = vx / d, vy / d
    end
    return x + dx * CFG.withdrawBack, y + dy * CFG.withdrawBack, z
end

-- A squad got where it was sent (LF_Objective.onArrived asks here first). True if handled.
function LF.Platoon.onArrived(squad)
    if squad.sbf and not squad.sbf.inPlace then
        squad.sbf.inPlace = true
        local obj = LF.Objective.get(squad.sbf.obj)
        LF.March.cancel(squad.id)
        LF.Tactics.setStance(squad, "offensive")
        if obj then
            local x, y = posOf(squad)
            if x then
                local dx, dy = obj.x - x, obj.y - y
                local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
                squad.facingX, squad.facingY = dx / d, dy / d
            end
        end
        local cid = LF.Units.commander(squad)
        shout(cid, "In position - open fire on those windows!")
        LF.log("PLATOON " .. squad.name .. " is in its support-by-fire position")
        return true
    end
    if squad.reserveAt then
        squad.reserveAt = nil
        LF.March.cancel(squad.id)
        LF.Tactics.setStance(squad, "defensive")
        shout(LF.Units.commander(squad), "Reserve's in place - get into cover and stay ready!")
        LF.log("PLATOON " .. squad.name .. " is in reserve")
        return true
    end
    if squad.withdrawTo then
        squad.withdrawTo = nil
        squad.platoonTask = "dig"
        LF.Tactics.setStance(squad, "defensive")
        shout(LF.Units.commander(squad), "At the rally point - dig in!")
        LF.log("PLATOON " .. squad.name .. " reached the rally point and digs in")
        return true
    end
    return false
end

-- A squad's last-known enemy distance (from its commander), or nil.
local function enemyNear(squad)
    local x, y = posOf(squad)
    if not x then return nil end
    local c = LF.Squad.bestContact(squad.id, x, y, LF.Tactics.CFG.contactMemory, 60)
    return c and LF.dist(x, y, c.x, c.y) or nil
end

local function updateWithdrawals(p)
    local all = true
    for _, s in ipairs(squadsOf(p)) do
        if s.withdrawTo then
            all = false
            local w = s.withdrawTo
            local x, y = posOf(s)
            local near = enemyNear(s)
            if x and LF.dist(x, y, w.x, w.y) <= CFG.arriveDist then
                LF.Platoon.onArrived(s)
            elseif x and (not near or near > CFG.clearOfEnemy) and not LF.March.get(s.id) then
                local ok, why = LF.March.order(s, w.x, w.y, w.z, "auto", { noGather = true })
                if ok then
                    LF.Tactics.shout(LF.Units.commander(s), "We're clear - move!")
                elseif why == "already there" then
                    LF.Platoon.onArrived(s)
                end
            end
        end
    end
    return all
end

local function updateTake(p, m)
    local obj = LF.Objective.get(m.obj)
    if not obj then p.mission = nil; return end
    if m.phase == "approach" then
        if m.pendingMove then
            local a = m.assembly
            if LF.Platoon.move(p, a.x, a.y, a.z) then m.pendingMove = nil end
            return
        end
        -- At the assembly area, or the enemy met on the way: deploy. (Not every squad need be in:
        -- once the main effort is there and half the platoon with it - or it has waited 30 s, or
        -- anyone has waited 90 s - the lieutenant goes on. A squad that took the long way round,
        -- or whose men aren't here, gets its orders where it is; 0.53 waited for it for ever.)
        local hx, hy = posOf(hqOf(p))
        local c = hx and platoonContact(p, hx, hy, 40)
        if c then LF.Platoon.deploy(p, m, "contact on the way in"); return end
        if moveArrived(p) then LF.Platoon.deploy(p, m, "at the assembly area"); return end
        local n, inN, mainIn = 0, 0, false
        for _, sq in ipairs(squadsOf(p)) do
            n = n + 1
            local M = LF.March.get(sq.id)
            local done = M == nil or M.arrived == true
            if done then inN = inN + 1 end
            if done and sq.id == m.main then mainIn = true end
        end
        if inN > 0 and not m.firstIn then m.firstIn = LF.tick end
        local waited = m.firstIn and LF.tick - m.firstIn or 0
        if mainIn and (inN * 2 >= n or waited > 1800) then
            LF.Platoon.deploy(p, m, string.format("at the assembly area, %d of %d squads in", inN, n))
        elseif waited > 5400 then
            LF.Platoon.deploy(p, m, string.format("waited long enough - %d of %d squads in", inN, n))
        end
        return
    end
    local main = LF.Units.get(m.main)
    local sup = m.support and LF.Units.get(m.support)
    local cmd = commander(p)
    if m.phase == "assault" then
        -- Taken?
        if main and main.objTask and main.objTask.kind == "hold" and main.objTask.obj == obj.id and obj.holder == main.faction then
            m.phase = "taken"
            LF.log("PLATOON " .. p.name .. ": " .. obj.name .. " taken by " .. main.name)
            LF.Morale.taskDone(main, "took " .. obj.name .. " as the lieutenant ordered")
            if cmd then shout(cmd.id, "Well done, " .. short(main) .. "! Hold it!") end
            if sup then
                LF.Morale.taskDone(sup, "kept the enemy's heads down for the assault")
                issue(p, { squad = sup.id, kind = "dig", words = short(sup) .. ", good work - dig in where you are and cover the building!" })
            end
            for _, rid in ipairs(m.reserve or {}) do
                local r = LF.Units.get(rid)
                if r and not (m.committed or {})[rid] then
                    issue(p, { squad = r.id, kind = "dig", words = short(r) .. ", dig in there - stay ready to back them up!" })
                end
            end
            return
        end
        -- The assault has failed?
        local mainShare = main and fitShare(main) or 0
        local broken = not main or mainShare < 0.4 or (LF.Tactics.state(main) and LF.Tactics.state(main).broken)
        if broken then
            local pf = platoonFit(p)
            -- Who is left to send in: the reserve first, then a rifle support squad.
            m.committed = m.committed or {}
            local fresh = nil
            for _, rid in ipairs(m.reserve or {}) do
                local r = LF.Units.get(rid)
                if not fresh and r and not m.committed[rid] and fitShare(r) >= CFG.takeOverFit then fresh = r end
            end
            local fromReserve = fresh ~= nil
            if not fresh and sup and not sup.mg and not m.swapped and fitShare(sup) >= CFG.takeOverFit then fresh = sup end
            if fresh and pf >= CFG.withdrawTake then
                m.committed[fresh.id] = true
                if fromReserve then
                    m.main = fresh.id
                else
                    m.swapped = true
                    m.main, m.support = sup.id, main and main.id or nil
                end
                p.mainEffort = fresh.id
                LF.log("PLATOON " .. p.name .. ": " .. (main and main.name or "the main effort") .. "'s assault has failed - "
                    .. (fromReserve and "the reserve is committed: " or "") .. fresh.name .. " takes it over")
                issue(p, { squad = fresh.id, kind = "take", obj = obj.id,
                    words = short(fresh) .. (fromReserve and ", you're up - take that building!" or ", you take the assault - go!") })
                if main then
                    issue(p, { squad = main.id, kind = "cover", obj = obj.id, words = short(main) .. ", get down and cover them!" })
                end
            else
                local x, y, z = rallyPoint(p)
                if x then LF.Platoon.withdraw(p, x, y, z, string.format("the assault has failed; the platoon is %.0f%% fit", pf * 100)) end
            end
            return
        end
        if platoonFit(p) < CFG.withdrawTake then
            local x, y, z = rallyPoint(p)
            if x then LF.Platoon.withdraw(p, x, y, z, "the platoon is too badly cut up to go on") end
        end
    end
end

local function updateHold(p, m)
    if platoonFit(p) >= CFG.withdrawHold then return end
    local hq = hqOf(p)
    local x, y = posOf(hq)
    if not (x and platoonContact(p, x, y, 40)) then return end
    local rx, ry, rz = rallyPoint(p)
    if rx then LF.Platoon.withdraw(p, rx, ry, rz, "the defence can't hold - the platoon is cut to pieces") end
end

local function updatePlatoon(p)
    local cmd = commander(p)
    -- Missions only run with someone in command; without, the squads carry on alone.
    if not cmd then return end
    deliver(p)
    local m = p.mission
    if not m then return end
    if m.kind == "take" then updateTake(p, m)
    elseif m.kind == "hold" then updateHold(p, m)
    elseif m.kind == "withdraw" then
        if updateWithdrawals(p) and #S(p).queue == 0 and not S(p).runner then
            LF.log("PLATOON " .. p.name .. ": withdrawal complete")
            p.mission = { kind = "rally", x = m.x, y = m.y, z = m.z, phase = "hold", since = LF.tick }
        end
    end
    if p.mission and p.mission.kind ~= "withdraw" then updateWithdrawals(p) end
end

Events.OnTick.Add(function()
    if LF.tick % CFG.updateTicks ~= 7 then return end
    for _, u in pairs(LF.Units.all()) do
        if u.kind == "platoon" then LF.guard("platoon", updatePlatoon, u) end
    end
end)

-- ---- where the headquarters goes (asked by LF.Tactics.place) ------------------------------------

local function behind(cb, tx, ty, dist)
    local x, y = cb:getX(), cb:getY()
    local dx, dy = x - tx, y - ty
    local d = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    return x + dx / d * dist, y + dy / d * dist
end

-- What the platoon is facing: the nearest enemy known, else the objective.
local function focus(p, x, y)
    local c = platoonContact(p, x, y, 60)
    if c then return c end
    local m = p.mission
    local obj = m and m.obj and LF.Objective.get(m.obj)
    if obj then return LF.Tactics.point(obj.x, obj.y, obj.z) end
    return nil
end

-- "hold" at (x, y) - or "move" there first while it's well away and no enemy is close (keeping up
-- with a squad on the march, rather than leaving cover every few steps to catch up).
local function goTo(p, body, x, y, z, point, far)
    local d = LF.dist(body:getX(), body:getY(), x, y)
    if d > (far or 8) and not platoonContact(p, body:getX(), body:getY(), 20) then return "move", x, y, z, point end
    return "hold", x, y, z, point
end

function LF.Platoon.place(rec)
    local hq = rec.squad and LF.Units.get(rec.squad)
    if not (hq and hq.kind == "hq") then return nil end
    local p = LF.Units.get(hq.platoon)
    if not p then return nil end
    local body = bodyOf(rec.id)
    if not body then return nil end
    local z = math.floor(body:getZ())
    local m = p.mission
    local isCmd = hq.leader == rec.id
    -- The platoon on the move in one file: the headquarters' places at its rear (LF_March).
    if p.move and p.move.mode == "file" then
        local role, x, y, mz, face, gait, scan = LF.March.place(rec)
        if role then return role, x, y, mz, face, gait, scan end
    end
    -- On the move with the squads abreast, no enemy close: the centre rear, in step with them.
    if p.move and p.move.mode == "abreast" and not platoonContact(p, body:getX(), body:getY(), 35) then
        local px, py, moving = patrolSpot(p)
        if px then
            local fx, fy = p.facingX or 1, p.facingY or 0
            local f, l = 0, 0
            if not isCmd then
                local o = rec.hqRole == "rto" and { -1.5, -1.5 } or { -2, 2 }
                f, l = o[1], o[2]
            end
            local x, y = px + fx * f - fy * l, py + fy * f + fx * l
            local st = S(p)
            st.patrolFaces = st.patrolFaces or {}
            local face = st.patrolFaces[rec.id]
            if not face then
                face = LF.Tactics.point(0, 0, z)
                st.patrolFaces[rec.id] = face
            end
            -- Moving: eyes ahead. Halted: the lieutenant forward, his men out to the flanks and rear.
            local hx, hy = fx, fy
            if not moving and not isCmd then
                if rec.hqRole == "rto" then hx, hy = fy, -fx else hx, hy = -fx, -fy end
            end
            face.x, face.y, face.z = x + hx * 6, y + hy * 6, z
            return "file", x, y, z, face, moving and "march" or "halt"
        end
    end
    local point = focus(p, body:getX(), body:getY())
        or LF.Tactics.point(body:getX() + (p.facingX or 1) * 10, body:getY() + (p.facingY or 0) * 10, z)
    local s = S(p)
    if isCmd then
        -- With no task: hold where he is if the enemy is about, else lead the headquarters on.
        if not m or p.leaderless then
            if platoonContact(p, body:getX(), body:getY(), 45) then return "hold", body:getX(), body:getY(), z, point end
            return nil
        end
        -- Going to give an order himself.
        if s.walkTo then
            local sb = cmdBodyOf(LF.Units.get(s.walkTo))
            if sb then return "move", sb:getX(), sb:getY(), math.floor(sb:getZ()), point end
        end
        if m.kind == "withdraw" or m.kind == "rally" then
            local d = LF.dist(body:getX(), body:getY(), m.x, m.y)
            if d > CFG.arriveDist then
                if not platoonContact(p, body:getX(), body:getY(), CFG.clearOfEnemy) then
                    return "move", m.x, m.y, m.z, point or LF.Tactics.point(m.x, m.y, m.z)
                end
                return "hold", body:getX(), body:getY(), z, point
            end
            return "hold", m.x, m.y, m.z, point or LF.Tactics.point(m.x - (p.facingX or 1) * 10, m.y - (p.facingY or 0) * 10, z)
        end
        local obj = m.obj and LF.Objective.get(m.obj)
        point = point or LF.Tactics.point(body:getX() + (p.facingX or 1) * 10, body:getY() + (p.facingY or 0) * 10, z)
        if (m.phase == "taken" or m.kind == "hold") and obj then
            return goTo(p, body, obj.x, obj.y, obj.z, point)                -- in the objective
        end
        local main = LF.Units.get(p.mainEffort)
        local mb = cmdBodyOf(main)
        if mb then
            local x, y = behind(mb, point:getX(), point:getY(), CFG.ltBehind)
            return goTo(p, body, x, y, math.floor(mb:getZ()), point)
        end
        return "hold", body:getX(), body:getY(), z, point
    end
    local cmd = LF.Records.get(hq.leader)
    local cb = cmd and bodyOf(cmd.id)
    if rec.hqRole == "ssgt" then
        if s.runner and s.runner.id == rec.id then
            local sb = cmdBodyOf(LF.Units.get(s.runner.order.squad))
            if sb then return "move", sb:getX(), sb:getY(), math.floor(sb:getZ()), point end
        end
        if not m then return nil end
        -- With the main effort, just behind its sergeant.
        local mb = cmdBodyOf(LF.Units.get(p.mainEffort))
        if mb and point and m.kind ~= "withdraw" and m.kind ~= "rally" then
            local x, y = behind(mb, point:getX(), point:getY(), CFG.ssgtBehind)
            return goTo(p, body, x, y, math.floor(mb:getZ()), point, 6)
        end
    end
    -- The radio operator (and the platoon sergeant with nothing else to do): at the commander's side.
    if not m or not cb then return nil end
    local off = rec.hqRole == "rto" and CFG.rtoBeside or 2.5
    local tx, ty = cb:getX(), cb:getY()
    if point then tx, ty = behind(cb, point:getX(), point:getY(), off) else tx = tx - off end
    local far = LF.dist(body:getX(), body:getY(), tx, ty) > 6
    return far and "move" or "hold", tx, ty, math.floor(cb:getZ()), point or LF.Tactics.point(tx + 10, ty, z)
end

-- ---- report -----------------------------------------------------------------------------------

function LF.Platoon.describe(p)
    local m = p.mission
    local cmd = commander(p)
    local s = string.format("%s: %s, %d%% fit", p.name, cmd and title(cmd) or "no officer", math.floor(platoonFit(p) * 100))
    if m then
        local obj = m.obj and LF.Objective.get(m.obj)
        s = s .. ", " .. m.kind .. (obj and (" " .. obj.name) or "") .. " (" .. tostring(m.phase) .. ")"
    end
    return s
end
