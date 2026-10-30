-- Living Front: watching the real player - keeping him visible.
--
-- 1. Keep him visible. After bumping into an NPC the player can turn invisible. Our NPC bodies
--    are IsoPlayers on player index 0 - the same index as the real player - and the engine fades
--    characters per player index from what "that player" can see, so an NPC's view can fade the
--    real player out. The engine only draws the player if he is in the cell's object list, on
--    screen, on a square and not faded out. This logs whenever that changes (PLAYER render ...)
--    and puts him back if he has been faded out or dropped from the object list.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"

LF.Watch = LF.Watch or {}
LF.Move = LF.Move or {}

local lastKey = nil
local fixes = 0

local function describe(p, inList)
    return string.format("inList=%s square=%s onScreen=%s alpha=%.2f targetAlpha=%.2f culled=%s invisible=%s ghost=%s",
        tostring(inList), tostring(p:getCurrentSquare() ~= nil), tostring(p:isOnScreen()), p:getAlpha(0),
        p:getTargetAlpha(0), tostring(p:isSceneCulled()), tostring(p:isInvisible()), tostring(p:isGhostMode()))
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
end

-- (Every 10 ticks: whether the player is in the cell's object list is a walk through that whole
-- list - thousands of entries in a busy cell - and a sixth of a second is soon enough.)
LF.on("OnTick", "Watch", function()
    if LF.frame % 10 ~= 4 then return end
    LF.guard("player watch", watch)
end)
local function keepShown(p)
    if not p:isInvisible() and not p:isGhostMode() and (p:getAlpha(0) < 0.99 or p:getTargetAlpha(0) < 0.99) then
        p:setAlpha(0, 1)
        p:setTargetAlpha(0, 1)
    end
end

-- (The game fires this for every one of our bodies too - they are player characters. Only the
-- real player matters: one comparison with him, no call into the game, for each of the others.)
-- (0.84) Called from the posture fix's handler (LF_Posture) - one handler a character a frame
-- instead of two: the game charges for each call, even one that does nothing.
local me = nil
LF.on("OnTick", "Watch", function() me = getPlayer() end)
function LF.Watch.onUpdate(p)
    if p == me then LF.guard("player shown", keepShown, p) end
end
