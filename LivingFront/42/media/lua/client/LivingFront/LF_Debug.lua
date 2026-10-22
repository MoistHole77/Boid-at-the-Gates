-- Living Front: debug tools (right-click menu) for testing records and bodies.

require "LivingFront/LF_Core"
require "LivingFront/LF_Records"
require "LivingFront/LF_Bodies"
require "LivingFront/LF_Combat"
require "LivingFront/LF_Brain"
require "LivingFront/LF_Cover"

LF.Debug = LF.Debug or {}

local function fmt(v)
    return string.format("%.3f", v or 0)
end

function LF.Debug.reportAll()
    local player = getPlayer()
    local px, py = player:getX(), player:getY()
    local total, withBody = 0, 0
    for id, rec in pairs(LF.Records.all()) do
        total = total + 1
        local body = LF.Bodies.get(id)
        if body then
            withBody = withBody + 1
            LF.Bodies.sync(rec, body)
        end
        LF.log("REC #" .. id .. " " .. LF.Records.fullName(rec) .. " [" .. rec.faction .. "]"
            .. " " .. (rec.female and "F" or "M")
            .. " alive=" .. tostring(rec.alive) .. " body=" .. tostring(body ~= nil)
            .. " pos=" .. math.floor(rec.x) .. "," .. math.floor(rec.y)
            .. " dist=" .. math.floor(LF.dist(rec.x, rec.y, px, py))
            .. " hunger=" .. fmt(rec.hunger) .. " thirst=" .. fmt(rec.thirst) .. " fatigue=" .. fmt(rec.fatigue)
            .. " worn=" .. (rec.worn and #rec.worn or 0)
            .. " skin=" .. tostring(rec.look and rec.look.skin) .. " hair=" .. tostring(rec.look and rec.look.hair)
            .. " beard=" .. tostring(rec.look and rec.look.beard) .. " outfit=" .. tostring(rec.outfit))
    end
    LF.log("REPORT records=" .. total .. " bodies=" .. withBody .. " savesSynced=" .. tostring(LF.syncedOnSave or 0))
    LF.say("Living Front: " .. total .. " NPCs, " .. withBody .. " with bodies")
end

local function create(faction, x, y, z)
    local rec = LF.Records.create({ faction = faction, x = x + 0.5, y = y + 0.5, z = z })
    LF.log("created #" .. rec.id .. " " .. LF.Records.fullName(rec) .. " [" .. faction .. "] "
        .. (rec.female and "F" or "M") .. " skin=" .. tostring(rec.look.skin) .. " hair=" .. tostring(rec.look.hair)
        .. " beard=" .. tostring(rec.look.beard) .. " outfit=" .. rec.outfit)
    LF.say("Created " .. LF.Records.fullName(rec) .. " (" .. LF.Factions[faction].name .. ")")
end

-- Two squads 16 tiles apart, either side of the clicked square.
local function createSkirmish(x, y, z)
    for i = 0, 2 do
        create("GER", x - 8 + ZombRand(-1, 2), y - 2 + i * 2, z)
        create("SOV", x + 8 + ZombRand(-1, 2), y - 2 + i * 2, z)
    end
end

local function createGroup(_, x, y, z)
    for _ = 1, 5 do
        create("CIV", x + ZombRand(-4, 5), y + ZombRand(-4, 5), z)
    end
end

local function walkNearestToMe(_, playerNum)
    local p = getSpecificPlayer(playerNum)
    local best, bestD = nil, math.huge
    for _, body in pairs(LF.Bodies.all()) do
        local d = LF.dist(body:getX(), body:getY(), p:getX(), p:getY())
        if d < bestD then best, bestD = body, d end
    end
    if not best then
        LF.say("Living Front: no NPC bodies nearby")
        return
    end
    LF.try("walk", function()
        ISTimedActionQueue.add(ISWalkToTimedAction:new(best, p:getSquare()))
        return true
    end)
end

local function armNearestCivilian(_, playerNum)
    local p = getSpecificPlayer(playerNum)
    local best, bestD = nil, math.huge
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.faction == "CIV" and not body:isDead() and not LF.Combat.isArmed(body) then
            local d = LF.dist(body:getX(), body:getY(), p:getX(), p:getY())
            if d < bestD then best, bestD = body, d end
        end
    end
    if not best then
        LF.say("No unarmed civilian nearby")
        return
    end
    LF.Combat.arm(best)
    LF.log("armed civilian #" .. tostring(best:getModData().LF_id))
    LF.say("Gave a civilian a rifle")
end

-- What cover does the clicked square offer against the nearest soldier?
local function checkCover(x, y, z)
    local best, bestD, bestRec = nil, math.huge, nil
    for id, body in pairs(LF.Bodies.all()) do
        local rec = LF.Records.get(id)
        if rec and rec.faction ~= "CIV" and not body:isDead() then
            local d = LF.distSq(body:getX(), body:getY(), x + 0.5, y + 0.5)
            if d < bestD then best, bestD, bestRec = body, d, rec end
        end
    end
    if not best then
        LF.say("No soldier nearby to check cover against")
        return
    end
    local q = LF.Cover.quality(x, y, z, best:getX(), best:getY())
    local sight = LF.Cover.canSeeFrom(x, y, z, best)
    local msg = "Cover here vs " .. LF.Records.fullName(bestRec) .. ": " .. LF.Cover.name(q)
        .. ", line of sight " .. (sight and "clear" or "blocked")
    LF.log("COVER CHECK " .. x .. "," .. y .. " " .. msg)
    LF.say(msg)
end

local function deleteAll()
    LF.Bodies.despawnAll()
    for id in pairs(LF.Records.all()) do LF.Records.remove(id) end
    LF.log("deleted all records")
    LF.say("Living Front: all NPCs deleted")
end

local function onMenu(playerNum, context, worldObjects, test)
    if test then return end
    local sq = LF.try("clicked square", function() return worldObjects[1]:getSquare() end)
    if not sq then
        local p = getSpecificPlayer(playerNum)
        sq = p and p:getSquare()
    end
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()

    local option = context:addOption("Living Front (debug)")
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    sub:addOption("Create civilian here", nil, function() create("CIV", x, y, z) end)
    sub:addOption("Create German here", nil, function() create("GER", x, y, z) end)
    sub:addOption("Create Soviet here", nil, function() create("SOV", x, y, z) end)
    sub:addOption("Create 5 civilians around here", nil, createGroup, x, y, z)
    sub:addOption("Walk nearest NPC to me", nil, walkNearestToMe, playerNum)
    sub:addOption("Report all NPCs", nil, LF.Debug.reportAll)

    local combatOption = sub:addOption("Combat / brains")
    local combat = ISContextMenu:getNew(sub)
    sub:addSubMenu(combatOption, combat)
    combat:addOption("Skirmish: 3 Germans (west) vs 3 Soviets (east)", nil, function() createSkirmish(x, y, z) end)
    combat:addOption("Arm all soldiers with rifles", nil, LF.Combat.armAllSoldiers)
    combat:addOption("Give nearest civilian a rifle (resistance)", nil, armNearestCivilian, playerNum)
    combat:addOption("Check cover on this square (vs nearest soldier)", nil, function() checkCover(x, y, z) end)
    combat:addOption((LF.Brain.enabled and "Turn NPC brains OFF" or "Turn NPC brains ON"), nil, LF.Brain.toggle)
    combat:addOption("Brain report", nil, LF.Brain.report)
    sub:addOption("Delete ALL NPCs", nil, deleteAll)
end

Events.OnFillWorldObjectContextMenu.Add(onMenu)
Events.OnGameStart.Add(function()
    local dropped = LF.Records.dropOutdated()
    if dropped > 0 then LF.log("removed " .. dropped .. " NPC records from an older mod version") end
    LF.log("v" .. LF.VERSION .. " loaded, " .. LF.Records.count() .. " NPC records in this save")
end)
