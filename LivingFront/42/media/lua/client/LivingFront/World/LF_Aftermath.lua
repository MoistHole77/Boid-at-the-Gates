-- Living Front: what a fight leaves behind (roadmap phase 4).
--
-- A man killed off-screen (LF_Clash) has no body to fall. When you come near where he died -
-- the ground loaded, within the range bodies are given in - his corpse is laid there once: in
-- his uniform, with his rifle, a real corpse the game keeps and saves like any other.
-- (Men taken prisoner leave nothing behind.)

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/World/LF_Appearance"

LF.Aftermath = LF.Aftermath or {}

local CFG = {
    updateTicks = 120,
    perPass = 4,            -- corpses laid per pass at most (spawning is not free)
}

-- A free square at or next to (x, y, z), or nil.
local function freeSquare(x, y, z)
    local cell = getCell()
    local bx, by = math.floor(x), math.floor(y)
    for r = 0, 3 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(bx + dx, by + dy, z)
                    if sq and sq:isFree(false) then return sq end
                end
            end
        end
    end
    return cell:getGridSquare(bx, by, z)
end

-- Lay rec's corpse where he died. True if it was laid (or can never be).
local function layCorpse(rec)
    local d = rec.diedOffscreen
    local sq = freeSquare(d.x, d.y, math.floor(d.z or 0))
    if not sq then return false end
    local desc = LF.Appearance.makeDescriptor(rec)
    if not desc then return true end
    local cell = getCell()
    local body = LF.try("corpse body", function()
        return IsoPlayer.new(cell, desc, sq:getX(), sq:getY(), sq:getZ())
    end)
    if not body then return true end
    LF.try("corpse setup", function()
        body:setNpc(true)
        body:setSceneCulled(false)
        body:setX(sq:getX() + 0.5); body:setY(sq:getY() + 0.5)
        return true
    end)
    LF.Appearance.dress(body, rec)
    if (rec.faction ~= "CIV" or rec.armed) and LF.Combat then LF.guard("corpse rifle", LF.Combat.arm, body) end
    -- The corpse itself: a dead body made from him; then the living one goes.
    pcall(function() body:setDir(IsoDirections.fromIndex(ZombRand(8))) end)
    local made = LF.try("corpse", function()
        local dead = IsoDeadBody.new(body, false)
        return dead ~= nil
    end)
    LF.try("corpse cleanup", function()
        body:removeFromWorld()
        local s2 = body:getCurrentSquare()
        if s2 and s2:getChunk() then body:removeFromSquare() end
        return true
    end)
    LF.log("AFTERMATH " .. LF.Units.title(rec) .. " #" .. rec.id .. " lies where he fell off-screen, at "
        .. sq:getX() .. "," .. sq:getY() .. (made and "" or " (no corpse could be made)"))
    return true
end

local function update()
    local p = getPlayer()
    if not p then return end
    local px, py = p:getX(), p:getY()
    local range = LF.Config and LF.Config.spawnRadius or 50
    local n = 0
    for _, rec in pairs(LF.Records.all()) do
        local d = rec.diedOffscreen
        if d and not rec.alive and not d.laid and LF.dist(px, py, d.x, d.y) <= range then
            if getCell():getGridSquare(math.floor(d.x), math.floor(d.y), math.floor(d.z or 0)) then
                d.laid = LF.guard("lay corpse", layCorpse, rec) ~= false
                n = n + 1
                if n >= CFG.perPass then return end
            end
        end
    end
end

Events.OnTick.Add(function()
    if LF.tick % CFG.updateTicks ~= 41 then return end
    LF.guard("aftermath", update)
end)
