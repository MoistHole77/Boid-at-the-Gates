-- Living Front: winter on the Stalingrad map - the city lies under snow, as it did from mid-November 1942 to
-- the end in February 1943.
--
-- The game's own snow does the work (it lays snow on the outdoor ground and turns the plants to their winter
-- sprites), the way its "Winter Is Coming" challenge does it:
--   * force snow: the ground stays white (snow cover held at the game's forced level) whatever the weather does;
--   * the seasons are set for the lower Volga in winter - latitude 49 N, cold all year round - so the air is
--     below freezing, what falls is snow, and the temperature the soldiers feel is a Russian winter's.
-- Only on the Stalingrad map: elsewhere the game's weather is left alone.

require "LivingFront/Core/LF_Core"

LF.Winter = LF.Winter or {}

local CFG = {
    lat = 49,           -- Stalingrad, 48.7 N
    tempMin = -22,      -- the coldest of the year (degrees C, the game's season curve)
    tempMax = -4,       -- the warmest: never a thaw
    tempDiff = 7,       -- day/night swing
}
LF.Winter.CFG = CFG

-- (Read straight from the world, not LF_District's cached answer: the seasons are set while the world is
-- still loading, before the district code has looked.)
local function onMap()
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
    return found
end

local function hold()
    if not onMap() then return end
    LF.try("Winter.hold", function()
        local core = getCore()
        if not core:isForceSnow() then
            core:setForceSnow(true)
            LF.log("WINTER snow forced on")
        end
    end)
end

LF.on("OnInitSeasons", "Winter", function(season)
    if not onMap() then return end
    LF.try("Winter.seasons", function()
        season:init(CFG.lat, CFG.tempMin, CFG.tempMax, CFG.tempDiff, season:getSeasonLag(), season:getHighNoon(),
            season:getSeedA(), season:getSeedB(), season:getSeedC())
        LF.log("WINTER seasons set: lat " .. CFG.lat .. ", " .. CFG.tempMin .. ".." .. CFG.tempMax .. " C")
    end)
end)

LF.on("OnGameStart", "Winter", function()
    hold()
    LF.try("Winter.check", function() if forceSnowCheck then forceSnowCheck() end end)
end)

LF.on("EveryHours", "Winter", hold)
