-- Living Front: watching the real player.
--
-- 1. Keep him visible. After bumping into an NPC the player can turn invisible. Our NPC bodies
--    are IsoPlayers on player index 0 - the same index as the real player - and the engine fades
--    characters per player index from what "that player" can see, so an NPC's view can fade the
--    real player out. The engine only draws the player if he is in the cell's object list, on
--    screen, on a square and not faded out. This logs whenever that changes (PLAYER render ...)
--    and puts him back if he has been faded out or dropped from the object list.
-- 2. Measure his walking pace while aiming (LF.Move.adsPace): patrols walk at that pace.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"

LF.Watch = LF.Watch or {}
LF.Move = LF.Move or {}

local lastKey = nil
local fixes = 0

local function describe(p, inList)
    return string.format("inList=%s square=%s onScreen=%s alpha=%.2f targetAlpha=%.2f culled=%s invisible=%s ghost=%s",
        tostring(inList), tostring(p:getCurrentSquare() ~= nil), tostring(p:isOnScreen()), p:getAlpha(0),
        p:getTargetAlpha(0), tostring(p:isSceneCulled()), tostring(p:isInvisible()), tostring(p:isGhostMode()))
end

-- Pace measurement: aiming and walking steadily for a second -> one sample.
local paceX, paceY, paceT = nil, nil, 0

local function measurePace(p)
    local moving = p:isAiming() and not p:isRunning() and not p:isSprinting() and not p:isSneaking()
    if not moving then paceX = nil; return end
    if not paceX then paceX, paceY, paceT = p:getX(), p:getY(), 0; return end
    paceT = paceT + 1
    if paceT < 60 then return end
    local speed = LF.dist(paceX, paceY, p:getX(), p:getY()) * 60 / paceT
    paceX, paceY, paceT = p:getX(), p:getY(), 0
    if speed < 0.2 or speed > 3 then return end      -- standing still (or not a walk)
    local old = LF.Move.adsPace
    LF.Move.adsPace = old and (old * 0.7 + speed * 0.3) or speed
    LF.Records.data().adsPace = LF.Move.adsPace          -- remembered with the save
    if not old or math.abs(LF.Move.adsPace - old) / old > 0.05 then
        LF.log(string.format("PACE your walking pace while aiming: %.2f tiles/s (patrols will match it)", LF.Move.adsPace))
    end
end

local function watch()
    local p = getPlayer()
    if not p or p:isDead() then return end
    local inList = getCell():getObjectList():contains(p)
    local a, ta = p:getAlpha(0), p:getTargetAlpha(0)
    local faded = a < 0.5 or ta < 0.5
    -- Only build a description when something we watch has changed (or needs fixing).
    local key = (inList and "L" or "-") .. (faded and "F" or "-") .. (p:getCurrentSquare() and "S" or "-")
        .. (p:isInvisible() and "I" or "-") .. (p:isGhostMode() and "G" or "-")
    local needsFix = not p:isInvisible() and not p:isGhostMode() and (a < 0.99 or ta < 0.99 or not inList)
    if key ~= lastKey or needsFix then
        local text = describe(p, inList)
        if key ~= lastKey then
            if lastKey then LF.log("PLAYER render " .. text) end
            lastKey = key
        end
        if needsFix then
            p:setAlpha(0, 1)
            p:setTargetAlpha(0, 1)
            if not inList then getCell():getObjectList():add(p) end
            fixes = fixes + 1
            if fixes <= 20 or fixes % 100 == 0 then LF.log("PLAYER render fix #" .. fixes .. " (was: " .. text .. ")") end
        end
    end
    measurePace(p)
end

Events.OnTick.Add(function() LF.guard("player watch", watch) end)
Events.OnGameStart.Add(function()
    local v = LF.Records.data().adsPace
    if v then
        LF.Move.adsPace = v
        LF.log(string.format("PACE your aiming pace from the save: %.2f tiles/s", v))
    end
end)

local function keepShown(p)
    if not p:isInvisible() and not p:isGhostMode() and (p:getAlpha(0) < 0.99 or p:getTargetAlpha(0) < 0.99) then
        p:setAlpha(0, 1)
        p:setTargetAlpha(0, 1)
    end
end

Events.OnPlayerUpdate.Add(function(p)
    if p == getPlayer() then LF.guard("player shown", keepShown, p) end
end)
