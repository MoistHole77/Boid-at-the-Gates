-- Living Front: physical bodies for records near the player.
-- Bodies are disposable. A body exists only while its record is near the player; when it is
-- put away, its position and needs are copied back into the record first.
--
-- Rendering note (found in the game's FBORenderCell): the engine never draws a plain IsoPlayer
-- that is not a local player slot, so we draw our bodies ourselves from the
-- RenderOpaqueObjectsInWorld event, the same way the engine's renderPlayer() does.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Appearance"

LF.Bodies = LF.Bodies or {}

local bodies = {}      -- record id -> IsoPlayer
local tick = 0

local function getStat(body, name)
    return LF.try("stat get " .. name, function()
        return body:getStats():get(CharacterStat[name])
    end)
end

local function setStat(body, name, value)
    LF.try("stat set " .. name, function()
        body:getStats():set(CharacterStat[name], value)
        return true
    end)
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

    local desc = LF.Appearance.makeDescriptor(rec)
    if not desc then return nil end
    local body = LF.try("IsoPlayer.new", function()
        return IsoPlayer.new(cell, desc, math.floor(rec.x), math.floor(rec.y), math.floor(rec.z))
    end)
    if not body then return nil end

    LF.try("setNpc", function() body:setNpc(true); return true end)
    LF.try("setSceneCulled", function() body:setSceneCulled(false); return true end)
    -- No upper-body twist: for an NPC the twist target is an arbitrary aim point, which made
    -- soldiers aim off to the side even though their bodies faced the target.
    LF.try("setMaxTwist", function() body:setMaxTwist(0); return true end)
    LF.try("addToWorld", function() body:addToWorld(); return true end)
    LF.try("identity", function()
        local name = LF.Records.fullName(rec)
        body:setUsername(name)
        body:setDisplayName(name)
        body:getModData().LF_id = rec.id
        return true
    end)
    local wornCount = LF.Appearance.dress(body, rec)

    setStat(body, "HUNGER", rec.hunger)
    setStat(body, "THIRST", rec.thirst)
    setStat(body, "FATIGUE", rec.fatigue)

    bodies[rec.id] = body
    LF.log("spawned #" .. rec.id .. " " .. LF.Records.fullName(rec) .. " (" .. rec.faction .. ") at "
        .. math.floor(rec.x) .. "," .. math.floor(rec.y) .. " wearing " .. wornCount .. " items")
    return body
end

function LF.Bodies.despawn(id)
    local body = bodies[id]
    if not body then return end
    local rec = LF.Records.get(id)
    if rec then LF.Bodies.sync(rec, body) end
    LF.try("removeFromWorld", function() body:removeFromWorld(); return true end)
    LF.try("removeFromSquare", function() body:removeFromSquare(); return true end)
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
local function managerPass()
    local player = getPlayer()
    if not player or player:isDead() then return end
    local px, py = player:getX(), player:getY()
    local cfg = LF.Config
    local spawned = 0

    for id, rec in pairs(LF.Records.all()) do
        local body = bodies[id]
        if body and body:isDead() then
            -- Died: the record is finished. The engine owns the corpse from here on.
            LF.Bodies.sync(rec, body)
            rec.alive = false
            bodies[id] = nil
            LF.log("#" .. id .. " " .. LF.Records.fullName(rec) .. " DIED at " .. math.floor(rec.x) .. "," .. math.floor(rec.y))
        elseif body then
            local d = LF.dist(body:getX(), body:getY(), px, py)
            if d > cfg.despawnRadius then
                LF.Bodies.despawn(id)
            end
        elseif rec.alive and spawned < cfg.maxSpawnsPerPass then
            if LF.dist(rec.x, rec.y, px, py) < cfg.spawnRadius then
                if LF.Bodies.spawn(rec) then spawned = spawned + 1 end
            end
        end
    end
end

local function onTick()
    tick = tick + 1
    if tick % LF.Config.managerInterval == 0 then
        LF.try("managerPass", function() managerPass(); return true end)
    end
end

-- Draw every body, mirroring FBORenderCell.renderPlayer(): shadow, then render.
local function onRenderOpaque(playerIndex, _x, _y, _z, _square)
    for _, body in pairs(bodies) do
        local sq = body:getCurrentSquare()
        if sq and body:isOnScreen() then
            local light = sq:getLightInfo(playerIndex)
            if light then
                local x, y, z = body:getX(), body:getY(), body:getZ()
                LF.try("renderShadow", function() body:renderShadow(x, y, z); return true end)
                LF.try("render", function() body:render(x, y, z, light, true, false, nil); return true end)
            end
        end
    end
end

-- Keep records current right before the game writes the save.
local function onSave()
    LF.syncedOnSave = (LF.syncedOnSave or 0) + 1
    LF.Bodies.syncAll()
end

Events.OnTick.Add(onTick)
Events.EveryTenMinutes.Add(function() LF.Bodies.syncAll() end)
if Events.OnSave then Events.OnSave.Add(onSave) else LF.log("OnSave event not available") end
if Events.RenderOpaqueObjectsInWorld then
    Events.RenderOpaqueObjectsInWorld.Add(onRenderOpaque)
else
    LF.log("RenderOpaqueObjectsInWorld NOT available: bodies will be invisible")
end
