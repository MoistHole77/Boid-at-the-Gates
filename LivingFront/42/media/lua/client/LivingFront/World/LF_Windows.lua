-- Living Front: the windows of a city under bombardment - on the Stalingrad map most panes are broken, the frames
-- still in their walls. The map ships whole windows (a map can only hold a window as built); the first time a
-- square loads, its windows are smashed by the game's own IsoWindow:smashWindow, so the frame stays, the glass is
-- gone, and the window can be climbed through like any broken window. Which windows break is fixed by the square's
-- position (the same in every game), and each window is done once: it is marked in its mod data, so a window the
-- player has boarded or replaced is never broken again.
-- Only on the Stalingrad map.

require "LivingFront/Core/LF_Core"

LF.Windows = LF.Windows or {}

local CFG = {
    broken = 85,            -- percent of windows found broken
}
LF.Windows.CFG = CFG

local onMapCache = nil

local function onMap()
    if onMapCache ~= nil then return onMapCache end
    local found = false
    pcall(function()
        local l = getLotDirectories()
        for i = 0, l:size() - 1 do
            if tostring(l:get(i)):find("Stalingrad", 1, true) then found = true end
        end
    end)
    if not found then
        pcall(function() found = tostring(getWorld():getMap()):find("Stalingrad", 1, true) ~= nil end)
    end
    onMapCache = found
    return found
end

-- the same answer for a square in every game
local function broken(x, y, z)
    return (x * 7919 + y * 104729 + z * 1299709) % 100 < CFG.broken
end
LF.Windows.broken = broken

local function visit(sq)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and instanceof(o, "IsoWindow") then
            local md = o:getModData()
            if not md.lfGlass then
                md.lfGlass = true
                if not o:isDestroyed() and not o:isSmashed() and broken(sq:getX(), sq:getY(), sq:getZ()) then
                    o:smashWindow(true, false)
                end
            end
        end
    end
end

-- (every square of the map passes through here as it loads: timed one call in 32)
LF.on("LoadGridsquare", "Windows", function(sq)
    if not sq or not onMap() then return end
    LF.guard("Windows.visit", visit, sq)
end, 32)
