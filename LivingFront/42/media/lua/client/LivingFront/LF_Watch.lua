-- Living Front: keep the real player visible.
--
-- After bumping into an NPC the player can turn invisible. Our NPC bodies are IsoPlayers on
-- player index 0 - the same index as the real player - and the engine fades characters out per
-- player index (alpha / target alpha) from what "that player" can see, so an NPC's view can fade
-- the real player out. The engine only draws the player if he is in the cell's object list, on
-- screen, on a square, and not faded out.
-- This watchdog logs whenever any of those change for the player (PLAYER render ...), and if he
-- has been faded out or dropped from the object list, puts him back.

require "LivingFront/LF_Core"

LF.Watch = LF.Watch or {}

local last = nil
local fixes = 0

local function state(p)
    local inList = getCell():getObjectList():contains(p)
    local sq = p:getCurrentSquare() ~= nil
    local a, ta = p:getAlpha(0), p:getTargetAlpha(0)
    return inList, sq, a, ta, string.format("inList=%s square=%s onScreen=%s alpha=%.2f targetAlpha=%.2f culled=%s invisible=%s ghost=%s",
        tostring(inList), tostring(sq), tostring(p:isOnScreen()), a, ta, tostring(p:isSceneCulled()),
        tostring(p:isInvisible()), tostring(p:isGhostMode()))
end

local function watch()
    local p = getPlayer()
    if not p or p:isDead() then return end
    local inList, _, a, ta, text = state(p)
    -- Fix a faded-out or dropped player (unless he is invisible on purpose: debug invisibility).
    if not p:isInvisible() and not p:isGhostMode() then
        local fixed = false
        if a < 0.99 or ta < 0.99 then
            p:setAlpha(0, 1)
            p:setTargetAlpha(0, 1)
            fixed = true
        end
        if not inList then
            getCell():getObjectList():add(p)
            fixed = true
        end
        if fixed then
            fixes = fixes + 1
            if fixes <= 20 or fixes % 100 == 0 then
                LF.log("PLAYER render fix #" .. fixes .. " (was: " .. text .. ")")
            end
        end
    end
    -- Log changes of the underlying state (alpha changes only when it drops out).
    local key = text:gsub("alpha=[%d%.]+ targetAlpha=[%d%.]+", (a < 0.5 or ta < 0.5) and "faded" or "shown")
    if key ~= last then
        if last then LF.log("PLAYER render " .. text) end
        last = key
    end
end

Events.OnTick.Add(function() LF.guard("player watch", watch) end)
local function keepShown(p)
    if not p:isInvisible() and not p:isGhostMode() and (p:getAlpha(0) < 0.99 or p:getTargetAlpha(0) < 0.99) then
        p:setAlpha(0, 1)
        p:setTargetAlpha(0, 1)
    end
end

Events.OnPlayerUpdate.Add(function(p)
    if p == getPlayer() then LF.guard("player shown", keepShown, p) end
end)
