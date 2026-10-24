-- Living Front: building a consistent-looking person from a record.
-- The record decides sex, skin, hair and beard when it is created. Clothing comes from the
-- record's named outfit on first spawn, then is remembered as a list of worn items.
--
-- Engine notes (from the game's code):
--  * IsoPlayer:dressInNamedOutfit() only builds a preview for non-local players; turning it
--    into worn items is gated on isLocalPlayer(). We do that conversion ourselves.
--  * The body type ("torso") is set when a descriptor is created. Changing sex afterwards
--    needs SurvivorFactory.setTorso(), as the game's character creator does.

require "LivingFront/Core/LF_Core"

LF.Appearance = LF.Appearance or {}

local function applyLook(visual, look)
    if not visual or not look then return end
    LF.try("apply skin", function() visual:setSkinTextureIndex(look.skin); return true end)
    LF.try("apply hair", function() visual:setHairModel(look.hair or ""); return true end)
    LF.try("apply beard", function() visual:setBeardModel(look.beard or ""); return true end)
    if look.hairR then
        LF.try("apply hair colour", function()
            local c = ImmutableColor.new(look.hairR, look.hairG, look.hairB, 1)
            visual:setHairColor(c)
            visual:setNaturalHairColor(c)
            visual:setBeardColor(c)
            visual:setNaturalBeardColor(c)
            return true
        end)
    end
end

-- A descriptor with the record's sex, body type, name and look.
function LF.Appearance.makeDescriptor(rec)
    local desc = LF.try("CreateSurvivor", function() return SurvivorFactory.CreateSurvivor() end)
    if not desc then return nil end
    LF.try("desc sex", function()
        desc:setFemale(rec.female)
        SurvivorFactory.setTorso(desc)
        return true
    end)
    LF.try("desc name", function()
        desc:setForename(rec.forename)
        desc:setSurname(rec.surname)
        return true
    end)
    applyLook(desc:getHumanVisual(), rec.look)
    return desc
end

local function captureWorn(body)
    return LF.try("capture worn", function()
        local list = {}
        local worn = body:getWornItems()
        for i = 0, worn:size() - 1 do
            local item = worn:getItemByIndex(i)
            if item then list[#list + 1] = item:getFullType() end
        end
        return list
    end) or {}
end

-- Turn a named outfit into real worn items (the step vanilla only does for local players).
local function wearNamedOutfit(body, outfit)
    return LF.try("wear outfit " .. tostring(outfit), function()
        local visuals = ItemVisuals.new()
        body:getHumanVisual():dressInNamedOutfit(outfit, visuals)
        body:getWornItems():setFromItemVisuals(visuals)
        body:getWornItems():addItemsToItemContainer(body:getInventory())
        return true
    end)
end

local function wearList(body, list)
    local inv = body:getInventory()
    for _, fullType in ipairs(list) do
        LF.try("wear " .. fullType, function()
            local item = inv:AddItem(fullType)
            if item and item:getBodyLocation() then
                body:setWornItem(item:getBodyLocation(), item)
            end
            return true
        end)
    end
end

-- Dress and style a freshly created body. Returns how many items it is wearing.
function LF.Appearance.dress(body, rec)
    LF.try("body sex", function() body:setFemale(rec.female); return true end)

    if rec.worn and #rec.worn > 0 then
        wearList(body, rec.worn)
    else
        -- Some outfits have no version for one sex and produce nothing. Try the record's
        -- outfit, then the faction's others, then a plain generic outfit.
        local candidates = { rec.outfit }
        for _, name in ipairs(LF.Factions[rec.faction].outfits) do
            if name ~= rec.outfit then candidates[#candidates + 1] = name end
        end
        candidates[#candidates + 1] = "Generic01"
        rec.worn = {}
        for _, name in ipairs(candidates) do
            wearNamedOutfit(body, name)
            rec.worn = captureWorn(body)
            if #rec.worn > 0 then
                if name ~= rec.outfit then
                    LF.log("#" .. rec.id .. " outfit " .. tostring(rec.outfit) .. " gave no clothes; using " .. name)
                    rec.outfit = name
                end
                break
            end
        end
    end

    -- Outfits can change hair, so the record's look is applied last.
    applyLook(body:getHumanVisual(), rec.look)

    LF.try("refresh visuals", function()
        body:onWornItemsChanged()
        body:resetModelNextFrame()
        return true
    end)
    return #rec.worn
end
