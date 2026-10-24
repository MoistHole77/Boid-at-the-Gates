-- Living Front: grenades.
--
-- Only leaders carry them: a sergeant 2, a corporal 1 (a man who takes over command picks up what
-- his fallen leader had left). They are thrown sparingly - only when a leader judges that it could
-- decide the fight:
--   turning the tide  - his unit is losing (a third of it down, or out-numbered by the enemy it
--                       knows of) and two or more of the enemy are bunched together in reach
--   breaking a stall  - the fight has gone ~45 s without moving, and there's a bunch of the enemy,
--                       or one holed up in a building, in reach
--   securing the win  - assaulting an objective whose last 1-3 defenders are holding out (~30 s):
--                       a grenade into their building; and a corporal clearing a building throws
--                       one through the door before his stack goes in, if an enemy is close inside
-- and never: within 30 s of the unit's last one, more than twice in one fight, nearer than 5 or
-- further than 18 tiles, with a friend within 5 tiles of where it lands, or without a clear throw
-- (open doors and broken or open windows let it through - walls and closed ones don't; a grenade
-- that would bounce back well short isn't thrown).
--
-- The blast (~3.5 s after the throw): within 1.5 tiles usually fatal; within 3.5 tiles wounds and
-- mostly knocks men down; within 6 tiles perhaps a light wound or a stagger; within 10 tiles heavy
-- suppression. Walls and closed doors and windows shelter men from it; crouching helps. Men who
-- see it land within 4 tiles of them may dive clear first. It hurts friend and foe alike.

require "TimedActions/ISBaseTimedAction"
require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Bodies"
require "LivingFront/Units/LF_Units"
require "LivingFront/Units/LF_Stance"
require "LivingFront/World/LF_Building"
require "LivingFront/Units/LF_Squad"

LF.Grenade = LF.Grenade or {}

local CFG = {
    carry = { SGT = 2, CPL = 1 },
    minRange = 5, maxRange = 18,
    friendlyClear = 5,          -- no friend within this of the landing point
    unitCooldown = 1800,        -- ~30 s between a unit's grenades
    perFight = 2,
    releaseTicks = 24,          -- into the throw clip when it leaves his hand
    throwTicks = 50,
    fuseTicks = 210,            -- ~3.5 s from the throw to the bang
    stallTicks = 2700,          -- ~45 s without progress
    holdOutTicks = 1800,        -- last defenders holding out ~30 s
    bunch = 3.5,                -- enemies this close together count as a bunch
    -- Taking a building (attacking an enemy who is inside one): the leaders are readier to throw.
    building = { cooldown = 900, perFight = 4, stallTicks = 900 },   -- ~15 s between, 4 a fight, after ~15 s
    lethal = 1.5, wound = 3.5, light = 6, suppress = 10,
    dodgeRadius = 4, dodgeChance = 50,
}
LF.Grenade.CFG = CFG

-- ---- carrying -----------------------------------------------------------------------------------

function LF.Grenade.count(rec)
    if not rec then return 0 end
    if rec.grenades == nil then rec.grenades = CFG.carry[rec.rank or ""] or 0 end
    return rec.grenades
end

-- A man takes over command: he picks up what the fallen leader had left.
function LF.Grenade.handOver(from, to)
    if not (from and to) then return end
    local n = LF.Grenade.count(from)
    if n > 0 then
        to.grenades = LF.Grenade.count(to) + n
        from.grenades = 0
    end
end

-- ---- the throw's path ---------------------------------------------------------------------------

-- Does something stop a grenade (or its blast) between square a and the next square b? Walls, closed
-- doors, and windows with the glass in. (Fences don't.)
local function blocked(a, b)
    if a:isWallTo(b) then return true end
    if a:isWindowTo(b) then
        local w = a:getWindowTo(b)
        return not (w and (w:isSmashed() or w:isDestroyed() or w:IsOpen()))
    end
    if a:isDoorTo(b) then
        local d = a:getDoorTo(b)
        return not (d and d:IsOpen())
    end
    return false
end

-- Step from (x1, y1) to (x2, y2): the last square reached before something stops it, and whether
-- it got all the way.
local function travel(x1, y1, x2, y2, z)
    local cell = getCell()
    local ax, ay = math.floor(x1), math.floor(y1)
    local bx, by = math.floor(x2), math.floor(y2)
    local cur = cell:getGridSquare(ax, ay, z)
    if not cur then return x1, y1, false end
    local steps = math.max(math.abs(bx - ax), math.abs(by - ay))
    local px, py = ax, ay
    for i = 1, steps do
        local nx = math.floor(ax + (bx - ax) * i / steps + 0.5)
        local ny = math.floor(ay + (by - ay) * i / steps + 0.5)
        for _, h in ipairs({ { nx, py }, { nx, ny } }) do
            if h[1] ~= px or h[2] ~= py then
                local nxt = cell:getGridSquare(h[1], h[2], z)
                if not nxt or blocked(cur, nxt) then return px + 0.5, py + 0.5, false end
                cur, px, py = nxt, h[1], h[2]
            end
        end
    end
    return x2, y2, true
end
LF.Grenade.travel = travel

-- ---- the blast ----------------------------------------------------------------------------------

local pending = {}          -- { x, y, z, at, by, faction }
local pendingCount = 0      -- (Kahlua has no next())
local lights = {}           -- { light, off }

local PARTS = { "Torso_Upper", "Torso_Lower", "UpperArm_L", "UpperArm_R", "UpperLeg_L", "UpperLeg_R",
                "LowerLeg_L", "LowerLeg_R", "Head" }

local function exposed(g, body)
    local _, _, through = travel(g.x, g.y, body:getX(), body:getY(), g.z)
    return through
end

local function hurt(g, body)
    if body:isDead() or math.abs(body:getZ() - g.z) > 0.5 then return end
    local d = LF.dist(body:getX(), body:getY(), g.x, g.y)
    if d > CFG.suppress then return end
    local id = body:getModData().LF_id
    local shielded = not exposed(g, body)
    if LF.Suppress and id then LF.Suppress.add(body, (shielded and 30 or 90) * (1 - d / (CFG.suppress + 1))) end
    if shielded or d > CFG.light then return end
    local low = body:isSneaking()
    local hits, severity, impact, fall = 0, 0, 0, nil
    if d <= CFG.lethal then
        hits, severity, impact, fall = 3, 70, 85 + ZombRand(30), true
    elseif d <= CFG.wound then
        hits, severity, impact = 1 + ZombRand(2), 45, 15 + ZombRand(15)
        fall = ZombRand(100) < (low and 40 or 70)
    elseif ZombRand(100) < (low and 20 or 40) then
        hits, severity, impact = 1, 20, 5
        fall = false
    end
    if hits == 0 then
        if ZombRand(100) < 40 then LF.Combat.knock(body, g.x, g.y, false) end
        return
    end
    for _ = 1, hits do LF.Combat.blastWound(body, PARTS[ZombRand(#PARTS) + 1], severity, impact / hits) end
    if fall ~= nil then LF.Combat.knock(body, g.x, g.y, fall) end
    if LF.Medic and LF.Medic.onHit then LF.guard("critical", LF.Medic.onHit, body, d <= CFG.lethal and "blastLethal" or "blast") end
    if id and LF.Service and g.by then LF.Service.shot(g.by, id, true) end
end

local function explode(g)
    local cell = getCell()
    local sq = cell:getGridSquare(math.floor(g.x), math.floor(g.y), g.z)
    if sq then
        if not g.engineBang then      -- (the game's own explosion has already made the bang)
            if not pcall(function() getSoundManager():PlayWorldSound("PipeBombExplode", sq, 0, 60, 1.0, false) end) then
                pcall(function() getSoundManager():PlayWorldSound("PipeBombExplode", false, sq, 0, 60, 1.0, false) end)
            end
        end
        pcall(function() addSound(nil, sq:getX(), sq:getY(), g.z, 60, 60) end)   -- (zombies hear it)
        local ok, light = pcall(function() return cell:addLamppost(sq:getX(), sq:getY(), g.z, 1.0, 0.75, 0.4, 8) end)
        if ok and light then lights[#lights + 1] = { light = light, off = LF.tick + 12 } end
    end
    local n = 0
    for _, body in pairs(LF.Bodies.all()) do
        LF.guard("grenade blast", hurt, g, body)
        n = n + 1
    end
    local p = getPlayer()
    if p and not p:isDead() then LF.guard("grenade blast", hurt, g, p) end
    LF.log(string.format("GRENADE goes off at %d,%d%s", math.floor(g.x), math.floor(g.y),
        g.engine and (g.engineBang and " (where the game's throw physics took it)" or " (the game's throw never landed - at the aimed point)") or ""))
end

Events.OnTick.Add(function()
    if pendingCount > 0 then
        for i = #pending, 1, -1 do
            local g = pending[i]
            -- (One thrown with the game's physics goes off when the game says it has - see
            -- OnThrowableExplode below - or, if that never comes, a little after its fuse.)
            if LF.tick >= g.at + (g.engine and 120 or 0) then
                table.remove(pending, i)
                pendingCount = pendingCount - 1
                LF.guard("grenade", explode, g)
            end
        end
    end
    for i = #lights, 1, -1 do
        if LF.tick >= lights[i].off then
            pcall(function() getCell():removeLamppost(lights[i].light) end)
            table.remove(lights, i)
        end
    end
end)
Events.OnInitGlobalModData.Add(function() pending, pendingCount, lights = {}, 0, {} end)

-- The game's own explosion of one of our throws: it goes off there - where the game's physics
-- took it (arc, bounces off walls, the roll after it lands).
if Events.OnThrowableExplode then
    Events.OnThrowableExplode.Add(function(trap, sq)
        if pendingCount == 0 or not sq then return end
        local who = nil
        pcall(function() who = trap:getAttacker() end)
        local wid = who and who:getModData().LF_id
        local pick, pi = nil, nil
        for i, g in ipairs(pending) do
            if g.engine and not g.engineBang and (wid == nil or g.by == wid) then
                if not pick or g.at < pick.at then pick, pi = g, i end
            end
        end
        if not pick then return end
        table.remove(pending, pi)
        pendingCount = pendingCount - 1
        pick.x, pick.y, pick.z = sq:getX() + 0.5, sq:getY() + 0.5, sq:getZ()
        pick.engineBang = true
        LF.guard("grenade", explode, pick)
    end)
end

-- Throw it with the game's own throwable physics: a pipe bomb flies from his hand toward the
-- target square (the game's arc and spread), and goes off after the fuse wherever it ends up. Our
-- copy of the pipe bomb has no blast of its own (power and range 0): the game's explosion only
-- gives the bang, the noise and the event; the hurting is ours (below), so cover, crouching and
-- the wound tiers work as before. Returns true if the game took the throw.
local function engineThrow(c, tx, ty, tz)
    if LF.Grenade.engine == false then return false end
    local ok, err = pcall(function()
        local w = instanceItem("Base.PipeBomb")
        w:setExplosionPower(0)
        w:setExplosionRange(0)
        w:setFireRange(0)
        w:setSmokeRange(0)
        w:setExplosionTimer(0)
        w:setTriggerExplosionTimer(math.max(1, math.floor((CFG.fuseTicks - CFG.releaseTicks) / 2)))  -- (30 fps frames)
        w:setMaxRange(CFG.maxRange + 2)
        local sq = getCell():getGridSquare(math.floor(tx), math.floor(ty), tz)
        if not sq then error("no square") end
        c:setAttackTargetSquare(sq)
        c:Throw(w)
    end)
    if not ok and LF.Grenade.engine == nil then
        LF.Grenade.engine = false
        LF.log("GRENADE the game's throw isn't available for NPCs (" .. tostring(err) .. ") - using our own")
    end
    return ok
end

-- It's in the air: men who see it land near them may dive clear.
local function warn(g)
    for id, body in pairs(LF.Bodies.all()) do
        if not body:isDead() and math.abs(body:getZ() - g.z) < 0.5 then
            local d = LF.dist(body:getX(), body:getY(), g.x, g.y)
            if d <= CFG.dodgeRadius and exposed(g, body) and ZombRand(100) < CFG.dodgeChance
                and not (LF.Suppress and LF.Suppress.isPinned(body)) and LF.Brain and LF.Brain.dodge then
                LF.Brain.dodge(id, body, g.x, g.y)
            end
        end
    end
end

-- ---- throwing -----------------------------------------------------------------------------------

LF_ThrowAction = ISBaseTimedAction:derive("LF_ThrowAction")

function LF_ThrowAction:isValid() return not self.character:isDead() end
function LF_ThrowAction:waitToStart() return false end

function LF_ThrowAction:start()
    self.character:faceLocation(self.tx, self.ty)
    if LF.Combat then self.slung = LF.Combat.sling(self.character) end
    self:setActionAnim("LF_Throw")
    pcall(function() self:setOverrideHandModels("Base.PipeBomb", nil) end)
    self.releaseAt = LF.tick + CFG.releaseTicks
end

function LF_ThrowAction:update()
    if self.releaseAt and LF.tick >= self.releaseAt then
        self.releaseAt = nil
        LF.guard("grenade release", self.release, self)
    end
end

function LF_ThrowAction:release()
    local c = self.character
    local rec = LF.Records.get(c:getModData().LF_id)
    if rec then rec.grenades = math.max(0, LF.Grenade.count(rec) - 1) end
    pcall(function() c:playSound("PipeBombThrow") end)
    -- Where it lands: a little off the mark (more the further it goes), and short if something is
    -- in the way.
    local d = LF.dist(c:getX(), c:getY(), self.tx, self.ty)
    local spread = 0.5 + d * 0.06
    local a = ZombRand(360) * math.pi / 180
    local r = ZombRand(100) / 100 * spread
    local lx, ly = self.tx + math.cos(a) * r, self.ty + math.sin(a) * r
    lx, ly = travel(c:getX(), c:getY(), lx, ly, self.tz)
    -- The game's physics takes it from here if it can (it aims at the target square itself and
    -- adds its own spread); else it lands where we reckon.
    local viaEngine = engineThrow(c, self.tx, self.ty, self.tz)
    local g = { x = lx, y = ly, z = self.tz, at = LF.tick + CFG.fuseTicks - CFG.releaseTicks,
                by = rec and rec.id, faction = rec and rec.faction, engine = viaEngine }
    pending[#pending + 1] = g
    pendingCount = pendingCount + 1
    if LF.Tactics and rec then LF.Tactics.shout(rec.id, "Grenade!") end
    LF.log(string.format("GRENADE #%s %s throws at %d,%d (%s) - lands at %d,%d",
        tostring(rec and rec.id), rec and LF.Units.title(rec) or "?", math.floor(self.tx), math.floor(self.ty),
        self.why or "", math.floor(lx), math.floor(ly)))
    warn(g)
end

local function rearm(self)
    if self.slung and LF.Combat then
        self.slung = nil
        LF.Combat.unsling(self.character)
    end
end
function LF_ThrowAction:stop() rearm(self); ISBaseTimedAction.stop(self) end
function LF_ThrowAction:perform() rearm(self); ISBaseTimedAction.perform(self) end

function LF_ThrowAction:new(character, tx, ty, tz, why)
    local o = ISBaseTimedAction.new(self, character)
    o.tx, o.ty, o.tz, o.why = tx, ty, tz, why
    o.maxTime = CFG.throwTicks
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
    o.ignoreHandsWounds = true
    return o
end

-- Can this man throw at (tx, ty) from where he stands: a grenade left, in range, a clear throw?
local function canThrow(rec, body, tx, ty, tz)
    if LF.Grenade.count(rec) <= 0 or body:isDead() or math.floor(body:getZ()) ~= tz then return false end
    if LF.Suppress and LF.Suppress.isPinned(body) then return false end
    if LF.Combat and LF.Combat.knockedDown(body) then return false end
    local d = LF.dist(body:getX(), body:getY(), tx, ty)
    if d < CFG.minRange or d > CFG.maxRange then return false end
    local lx, ly = travel(body:getX(), body:getY(), tx, ty, tz)
    return LF.dist(lx, ly, tx, ty) <= 1.5
end

-- No friend of `faction` within CFG.friendlyClear of (x, y)?
local function clearOfFriends(faction, x, y)
    for id, body in pairs(LF.Bodies.all()) do
        local r = LF.Records.get(id)
        if r and r.faction == faction and not body:isDead()
            and LF.distSq(body:getX(), body:getY(), x, y) < CFG.friendlyClear * CFG.friendlyClear then
            return false
        end
    end
    return true
end

-- No friend of `faction` near enough to (x, y) AND out in the open to it (a man round the corner
-- of a wall from the blast is safe)?
local function safeForFriends(faction, x, y, z)
    for id, body in pairs(LF.Bodies.all()) do
        local r = LF.Records.get(id)
        if r and r.faction == faction and not body:isDead() and math.abs(body:getZ() - z) < 0.5
            and LF.distSq(body:getX(), body:getY(), x, y) < CFG.friendlyClear * CFG.friendlyClear
            and exposed({ x = x, y = y, z = z }, body) then
            return false
        end
    end
    return true
end

-- Throw now (the action replaces whatever he was doing).
function LF.Grenade.throw(body, tx, ty, tz, why)
    ISTimedActionQueue.clear(body)
    if LF.Posture and LF.Posture.crouched(body) then LF.Posture.set(body, false) end
    ISTimedActionQueue.add(LF_ThrowAction:new(body, tx, ty, tz, why))
end

-- ---- the leader's decision ----------------------------------------------------------------------

local function leadersOf(squad)
    local list = {}
    if squad.leader then list[#list + 1] = squad.leader end
    for _, tid in ipairs(squad.teams) do
        local t = LF.Units.get(tid)
        if t and t.leader then list[#list + 1] = t.leader end
    end
    return list
end

-- Each tactics update for a unit in a fight (sq: its runtime state). Returns true if it threw.
function LF.Grenade.consider(squad, sq)
    local B = CFG.building
    if LF.tick - (sq.lastGrenade or -100000) < B.cooldown then return false end
    if (sq.grenadesThisFight or 0) >= B.perFight then return false end
    -- Anyone with a grenade at all?
    local any = false
    for _, rid in ipairs(leadersOf(squad)) do
        if LF.Grenade.count(LF.Records.get(rid)) > 0 then any = true; break end
    end
    if not any then return false end
    local contacts = LF.Squad.contactPoints(squad.id, 600, 24)
    if #contacts == 0 then
        sq.nadeSince, sq.grenadesThisFight = nil, nil      -- the fight is over
        return false
    end
    sq.nadeSince = sq.nadeSince or LF.tick
    -- How it's going.
    local total, fitN = 0, 0
    for _, rid in ipairs(LF.Units.members(squad.id)) do
        local r = LF.Records.get(rid)
        if r then
            total = total + 1
            if r.alive and not r.wounded then fitN = fitN + 1 end
        end
    end
    local losing = total > 0 and (fitN / total < 0.67 or #contacts >= fitN)
    local fightAge = LF.tick - sq.nadeSince
    local attacking = LF.Stance.get(squad).maneuvers == true
    -- Taking a building: attacking, and the enemy known to be inside one. Grenades are what
    -- shift men from behind walls, so the leaders use them sooner and more often (still at most
    -- two each).
    local inBuilding = 0
    for _, c in ipairs(contacts) do
        if LF.Building.idAt(c.x, c.y, c.z or 0) then inBuilding = inBuilding + 1 end
    end
    local takingBuilding = attacking and inBuilding > 0
    if not takingBuilding then
        if LF.tick - (sq.lastGrenade or -100000) < CFG.unitCooldown then return false end
        if (sq.grenadesThisFight or 0) >= CFG.perFight then return false end
    end
    -- An enemy machine gun in reach: silence it - whoever can throw to it does.
    if LF.MG then
        for _, rid in ipairs(leadersOf(squad)) do
            local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
            local gun = b and LF.MG.enemyGunNear(squad.faction, b:getX(), b:getY(), 30)
            if gun and r and r.alive and not r.wounded then
                local gz = math.floor(gun.z or 0)
                if clearOfFriends(squad.faction, gun.x, gun.y) and canThrow(r, b, gun.x, gun.y, gz) then
                    LF.Grenade.throw(b, gun.x, gun.y, gz, "silencing the machine gun")
                    sq.lastGrenade = LF.tick
                    sq.grenadesThisFight = (sq.grenadesThisFight or 0) + 1
                    return true
                end
            end
        end
    end
    local stalled = attacking and fightAge >= (takingBuilding and B.stallTicks or CFG.stallTicks)   -- (a defence only throws when losing)
    local t = squad.objTask
    local holdingOut = attacking and t and t.kind == "take" and t.phase == "assault" and #contacts <= 3
        and fightAge >= (takingBuilding and B.stallTicks or CFG.holdOutTicks)
    if not (losing or stalled or holdingOut) then return false end
    -- The target: the biggest bunch; or (stalled / holding out) one holed up in a building.
    local best, bestN, bestScore = nil, 0, -1
    for _, c in ipairs(contacts) do
        local n = 0
        for _, o in ipairs(contacts) do
            if LF.dist(c.x, c.y, o.x, o.y) <= CFG.bunch then n = n + 1 end
        end
        local inside = LF.Building and LF.Building.idAt(c.x, c.y, c.z or 0) ~= nil
        local score = n + (inside and 0.5 or 0)
        if score > bestScore then best, bestN, bestScore = c, n, score end
    end
    if not best then return false end
    local inside = LF.Building and LF.Building.idAt(best.x, best.y, best.z or 0) ~= nil
    local worth = bestN >= 2 or ((stalled or holdingOut or takingBuilding) and inside)
    if not worth then return false end
    local tz = math.floor(best.z or 0)
    if not clearOfFriends(squad.faction, best.x, best.y) then return false end
    -- Who throws: the leader in reach with a clear throw, the commander first.
    for _, rid in ipairs(leadersOf(squad)) do
        local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
        if r and r.alive and b and not r.wounded and canThrow(r, b, best.x, best.y, tz) then
            local why = losing and "turning the tide" or (holdingOut and "finishing the last defenders"
                or (takingBuilding and inside and "shifting them out of the building" or "breaking the stall"))
            LF.Grenade.throw(b, best.x, best.y, tz, why .. ", " .. bestN .. " enemy there")
            sq.lastGrenade = LF.tick
            sq.grenadesThisFight = (sq.grenadesThisFight or 0) + 1
            return true
        end
    end
    return false
end

-- Clearing a building: the corporal throws one through the opened door if an enemy is known close
-- inside. Returns the ticks to wait for the bang, or nil.
function LF.Grenade.intoRoom(squad, team, C)
    local cid = team.leader
    local r, b = cid and LF.Records.get(cid), cid and LF.Bodies.get(cid)
    if not (r and b and r.alive) or LF.Grenade.count(r) <= 0 then return nil end
    local best, bd = nil, math.huge
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, 900, 24)) do
        if LF.Building.isInside(C.L, c.x, c.y) then
            local d = LF.dist(c.x, c.y, C.door.x, C.door.y)
            if d >= 2 and d <= 8 and d < bd then best, bd = c, d end
        end
    end
    if not best then return nil end
    -- Close range is fine here (he ducks back beside the door), but it must go through the door.
    local tz = C.L.z
    local lx, ly = travel(b:getX(), b:getY(), best.x, best.y, tz)
    if LF.dist(lx, ly, best.x, best.y) > 2 or LF.dist(b:getX(), b:getY(), best.x, best.y) < 2 then return nil end
    LF.Grenade.throw(b, best.x, best.y, tz, "into the room before going in")
    return CFG.fuseTicks + 40
end

-- Before a stack goes in: an enemy known inside near the door (at a window over the stack, say)
-- gets a grenade from whichever leader of the squad has a clear throw at him - in through his
-- window - so the men at the door aren't shot down going in. Returns the ticks to wait, or nil.
function LF.Grenade.coverDoor(squad, C)
    local sq = LF.Tactics and LF.Tactics.state and LF.Tactics.state(squad)
    local tz = C.L.z
    local ox, oy = C.door.x + (C.door.dx or 0), C.door.y + (C.door.dy or 0)
    local targets = {}
    for _, c in ipairs(LF.Squad.contactPoints(squad.id, 900, 24)) do
        if math.floor(c.z or 0) == tz and LF.Building.isInside(C.L, c.x, c.y)
            and LF.dist(c.x, c.y, ox + 0.5, oy + 0.5) <= 7 then
            targets[#targets + 1] = c
        end
    end
    if #targets == 0 then return nil end
    table.sort(targets, function(a, b2)
        return LF.dist(a.x, a.y, ox, oy) < LF.dist(b2.x, b2.y, ox, oy)
    end)
    for _, c in ipairs(targets) do
        for _, rid in ipairs(leadersOf(squad)) do
            local r, b = LF.Records.get(rid), LF.Bodies.get(rid)
            if r and r.alive and b and not r.wounded and canThrow(r, b, c.x, c.y, tz)
                and safeForFriends(squad.faction, c.x, c.y, tz) then
                LF.Grenade.throw(b, c.x, c.y, tz, "covering the door before the stack goes in")
                if sq then
                    sq.lastGrenade = LF.tick
                    sq.grenadesThisFight = (sq.grenadesThisFight or 0) + 1
                end
                return CFG.fuseTicks + 40
            end
        end
    end
    return nil
end
