-- Living Front: physical bodies for records near the player.
-- Bodies are disposable. A body exists only while its record is near the player; when it is
-- put away, its position and needs are copied back into the record first.
--
-- Rendering note (found in the game's FBORenderCell): the engine never draws a plain IsoPlayer
-- that is not a local player slot, so we draw our bodies ourselves from the
-- RenderOpaqueObjectsInWorld event, the same way the engine's renderPlayer() does.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Appearance"
require "LivingFront/Core/LF_Perf"

LF.Bodies = LF.Bodies or {}

local bodies = {}      -- record id -> IsoPlayer
local wanted = {}      -- squad id -> tick until which its men should have bodies (an off-screen fight met you)

-- A unit near a fight you are in: its men get bodies where the ground is loaded (LF_Clash).
function LF.Bodies.want(squadId)
    if squadId then wanted[squadId] = LF.tick + 600 end
end

local function readStat(body, name)
    return body:getStats():get(CharacterStat[name])
end

local function writeStat(body, name, value)
    body:getStats():set(CharacterStat[name], value)
end

local function getStat(body, name)
    return LF.guard("stat get " .. name, readStat, body, name)
end

local function setStat(body, name, value)
    LF.guard("stat set " .. name, writeStat, body, name, value)
end

-- Copy a body's live state back into its record.
function LF.Bodies.sync(rec, body)
    rec.x, rec.y, rec.z = body:getX(), body:getY(), body:getZ()
    rec.hunger = getStat(body, "HUNGER") or rec.hunger
    rec.thirst = getStat(body, "THIRST") or rec.thirst
    rec.fatigue = getStat(body, "FATIGUE") or rec.fatigue
end

function LF.Bodies.get(id)
    return bodies[id]
end

function LF.Bodies.all()
    return bodies
end

function LF.Bodies.spawn(rec)
    if bodies[rec.id] then return bodies[rec.id] end
    local cell = getCell()
    local sq = cell:getGridSquare(math.floor(rec.x), math.floor(rec.y), math.floor(rec.z))
    if not sq then return nil end -- chunk not loaded yet; try again next pass
    -- (Walked here off-screen, he may have been put down on a wall or a tree: the nearest free
    -- square instead.)
    if not sq:isFree(false) then
        local bx, by, bz = math.floor(rec.x), math.floor(rec.y), math.floor(rec.z)
        local found = nil
        for r = 1, 4 do
            for dx = -r, r do
                for dy = -r, r do
                    if not found and math.max(math.abs(dx), math.abs(dy)) == r then
                        local q = cell:getGridSquare(bx + dx, by + dy, bz)
                        if q and q:isFree(false) then found = q end
                    end
                end
            end
            if found then break end
        end
        if found then
            sq = found
            rec.x, rec.y = found:getX() + 0.5, found:getY() + 0.5
        end
    end

    local t0 = LF.Perf.start()
    local desc = LF.Appearance.makeDescriptor(rec)
    if not desc then return nil end
    local body = LF.try("IsoPlayer.new", function()
        return IsoPlayer.new(cell, desc, math.floor(rec.x), math.floor(rec.y), math.floor(rec.z))
    end)
    if not body then return nil end

    LF.try("setup body", function()
        body:setNpc(true)
        body:setSceneCulled(false)
        -- No upper-body twist: for an NPC the twist target is an arbitrary aim point, which made
        -- soldiers aim off to the side even though their bodies faced the target.
        body:setMaxTwist(0)
        body:addToWorld()
        return true
    end)
    LF.try("identity", function()
        local name = LF.Units and LF.Units.title(rec) or LF.Records.fullName(rec)
        body:setUsername(name)
        body:setDisplayName(name)
        body:getModData().LF_id = rec.id
        return true
    end)
    local wornCount = LF.Appearance.dress(body, rec)
    if rec.medic and LF.Medic and LF.Medic.equip then LF.guard("medic kit", LF.Medic.equip, body, rec) end

    setStat(body, "HUNGER", rec.hunger)
    setStat(body, "THIRST", rec.thirst)
    setStat(body, "FATIGUE", rec.fatigue)

    -- Soldiers (and anyone recorded as armed) carry their rifle from the start.
    if (rec.faction ~= "CIV" or rec.armed) and LF.Combat then LF.guard("arm on spawn", LF.Combat.arm, body) end

    -- Wounded off-screen (LF_Clash): the wound is on him now.
    -- (Seriously or critically wounded - LF_Wounds: his grade sets how he is, dressed, not the raw
    -- wound - which up to 0.69.1 could kill a man outright the moment his body came.)
    local g = rec.wound and rec.wound.grade
    if g == "serious" or g == "critical" then rec.offWound = nil end
    if rec.offWound and LF.Combat and LF.Combat.blastWound then
        local w = rec.offWound
        rec.offWound = nil
        LF.Combat.blastWound(body, w.part, w.severity, w.impact)
    end
    bodies[rec.id] = body
    LF.Perf.stop("spawn", t0)
    LF.log("spawned #" .. rec.id .. " " .. LF.Records.fullName(rec) .. " (" .. rec.faction .. ") at "
        .. math.floor(rec.x) .. "," .. math.floor(rec.y) .. " wearing " .. wornCount .. " items")
    return body
end

function LF.Bodies.despawn(id)
    local body = bodies[id]
    if not body then return end
    local rec = LF.Records.get(id)
    if rec then LF.Bodies.sync(rec, body) end
    if LF.Combat and LF.Combat.liftGrounded then LF.Combat.liftGrounded(body) end
    LF.try("remove body", function()
        body:removeFromWorld()
        -- (Only from a square still in a loaded chunk: the game's pathfinder throws on one whose
        -- chunk has gone - 0.56 logged 7 of those when a platoon was left behind.)
        local sq = body:getCurrentSquare()
        if sq and sq:getChunk() then body:removeFromSquare() end
        return true
    end)
    bodies[id] = nil
    LF.log("despawned #" .. id)
end

function LF.Bodies.despawnAll()
    for id in pairs(bodies) do LF.Bodies.despawn(id) end
end

function LF.Bodies.syncAll()
    for id, body in pairs(bodies) do
        local rec = LF.Records.get(id)
        if rec then LF.Bodies.sync(rec, body) end
    end
end

-- Body manager: give nearby records bodies, put distant bodies away.
-- NOTE: loops every record each pass. Fine for hundreds; will need spatial buckets later.
local squadsNear = {}
local function managerPass()
    local player = getPlayer()
    if not player or player:isDead() then return end
    local px, py = player:getX(), player:getY()
    local cfg = LF.Config
    local spawnSq = cfg.spawnRadius * cfg.spawnRadius
    local despawnSq = cfg.despawnRadius * cfg.despawnRadius
    local spawned = 0
    -- A squad stays together: while any of its men is within range of the player, the rest of
    -- them keep (or get) their bodies too, as long as the ground under them is loaded - so a long
    -- column doesn't lose its rear when the player walks on ahead.
    local near = squadsNear
    for k in pairs(near) do near[k] = nil end
    for id, rec in pairs(LF.Records.all()) do
        local body = bodies[id]
        if rec.squad and rec.alive and body and not body:isDead()
            and LF.distSq(body:getX(), body:getY(), px, py) <= despawnSq then
            near[rec.squad] = true
        end
    end
    for sid, untilTick in pairs(wanted) do
        if untilTick > LF.tick then near[sid] = true else wanted[sid] = nil end
    end
    local cell = getCell()
    local function loaded(x, y, z)
        return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) ~= nil
    end

    for id, rec in pairs(LF.Records.all()) do
        local body = bodies[id]
        if body and body:isDead() then
            -- Died: the record is finished. The engine owns the corpse from here on.
            LF.Bodies.sync(rec, body)
            rec.alive = false
            bodies[id] = nil
            LF.log("#" .. id .. " " .. LF.Records.fullName(rec) .. " DIED at " .. math.floor(rec.x) .. "," .. math.floor(rec.y))
            if LF.Service then LF.guard("service record", LF.Service.died, rec) end
            if LF.Units then LF.guard("succession", LF.Units.onDeath, rec) end
            if LF.Memory then LF.guard("memory died", LF.Memory.died, rec) end
        elseif body then
            if LF.distSq(body:getX(), body:getY(), px, py) > despawnSq
                and not (rec.squad and near[rec.squad] and loaded(body:getX(), body:getY(), body:getZ())) then
                LF.Bodies.despawn(id)
            end
        elseif rec.alive and spawned < cfg.maxSpawnsPerPass then
            local d2 = LF.distSq(rec.x, rec.y, px, py)
            if d2 < spawnSq or (rec.squad and near[rec.squad] and d2 < despawnSq * 2.25 and loaded(rec.x, rec.y, rec.z)) then
                if LF.Bodies.spawn(rec) then spawned = spawned + 1 end
            end
        end
    end
end

local function onTick()
    if LF.due(LF.Config.managerInterval, 0) then
        local t0 = LF.Perf.start()
        LF.guard("managerPass", managerPass)
        LF.Perf.stop("manager", t0)
    end
end

-- Draw one body, mirroring FBORenderCell.renderPlayer(): shadow, then render.
local function drawBody(body, playerIndex)
    local sq = body:getCurrentSquare()
    if not sq or not body:isOnScreen() then return end
    local light = sq:getLightInfo(playerIndex)
    if not light then return end
    local x, y, z = body:getX(), body:getY(), body:getZ()
    body:renderShadow(x, y, z)
    body:render(x, y, z, light, true, false, nil)
end

-- One guarded call per body per frame, with no closures created.
local function onRenderOpaque(playerIndex, _x, _y, _z, _square)
    local t0 = LF.Perf.start()
    for _, body in pairs(bodies) do
        LF.guard("draw body", drawBody, body, playerIndex)
    end
    LF.Perf.stop("draw", t0)
end

-- Keep records current right before the game writes the save.
local function onSave()
    LF.syncedOnSave = (LF.syncedOnSave or 0) + 1
    LF.Bodies.syncAll()
end

LF.on("OnTick", "Bodies", onTick)
Events.EveryTenMinutes.Add(function() LF.Bodies.syncAll() end)
if Events.OnSave then Events.OnSave.Add(onSave) else LF.log("OnSave event not available") end
if Events.RenderOpaqueObjectsInWorld then
    Events.RenderOpaqueObjectsInWorld.Add(onRenderOpaque)
else
    LF.log("RenderOpaqueObjectsInWorld NOT available: bodies will be invisible")
end
