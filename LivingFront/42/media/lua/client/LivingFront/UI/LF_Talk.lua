-- Living Front: talking to your men (roadmap phase 4).
--
-- Right-click a soldier: "Talk to <him>", type what you say. He answers from who he is - name,
-- rank, side, unit, how his morale is, whether he is wounded, how many men he has lost - and
-- from what he has seen (LF_Memory: the events he witnessed, on- or off-screen). His answer is
-- spoken over his head; with the LF bridge and Chasm running, the language model answers in
-- character and you hear it in his voice, from where he stands. Without them, he tells you
-- plainly what he last saw.
-- The last few exchanges with each man are remembered for the conversation (not saved).

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Chasm"
require "LivingFront/Soldier/LF_Memory"
require "ISUI/ISTextBox"

LF.Talk = LF.Talk or {}

local history = {}          -- record id -> { { you, him }, ... } (runtime)
Events.OnInitGlobalModData.Add(function() history = {} end)

-- His memories put in his own mouth ("our squad", "I was wounded").
local function firstPerson(s)
    s = s:gsub("from your squad", "from our squad"):gsub("Your squad", "Our squad"):gsub("your squad", "our squad")
    s = s:gsub("You were wounded", "I was wounded"):gsub("your side", "our side")
    return s
end

local GREET = { GER = "Jawohl.", SOV = "Da, comrade." }

-- What he says with no language model: what he last saw.
local function plainReply(rec, mems)
    local open = GREET[rec.faction] or "Yes?"
    if #mems == 0 then return open .. " Nothing to report - it has been quiet." end
    local said = { open }
    for i = 1, math.min(2, #mems) do said[#said + 1] = firstPerson(mems[i]) end
    return table.concat(said, " ")
end

local function doing(rec)
    local u = rec.squad and LF.Units.get(rec.squad)
    if not u then return "" end
    local t = u.objTask
    local obj = t and LF.Objective and LF.Objective.get(t.obj)
    if t and t.kind == "take" and obj then return "taking " .. obj.name end
    if t and t.kind == "hold" and obj then return "holding " .. obj.name end
    local M = LF.March and LF.March.get(u.id)
    if M and not M.arrived then return "on the march" end
    return u.stance or ""
end

function LF.Talk.say(id, text)
    local rec = LF.Records.get(id)
    if not (rec and rec.alive) then return end
    local title = LF.Units.title(rec)
    LF.log("TALK you to " .. title .. " #" .. id .. ": " .. text)
    local mems = LF.Memory.of(rec, 6)
    local h = history[id] or {}
    history[id] = h
    local fallback = plainReply(rec, mems)
    local function answer(words)
        h[#h + 1] = { you = text, him = words }
        while #h > 6 do table.remove(h, 1) end
        if LF.Tactics and LF.Tactics.say then LF.Tactics.say(id, words) end
    end
    if LF.Chasm.alive() then
        local prof = LF.Memory.profile(rec)
        prof.doing = doing(rec)
        if LF.Tactics and LF.Tactics.say then LF.Tactics.say(id, "...", 30) end
        local sent = LF.Chasm.request({ kind = "talk", soldier = prof, memories = mems, history = h,
                                        player_text = text, fallback = fallback },
            function(ans)
                if ans and ans.text and ans.text ~= "" then answer(ans.text)
                else answer(fallback) end
            end, id)
        if sent then return end
    end
    answer(fallback)
end

-- The text box.
function LF.Talk.open(id, playerNum)
    local rec = LF.Records.get(id)
    if not rec then return end
    local w, h = 380, 130
    local x = (getCore():getScreenWidth() - w) / 2
    local y = (getCore():getScreenHeight() - h) / 2
    local box = ISTextBox:new(x, y, w, h, "Say to " .. LF.Units.title(rec) .. ":", "", nil,
        function(_, button)
            if button.internal == "OK" then
                local t = button.parent.entry:getText()
                if t and t:match("%S") then LF.Talk.say(id, t) end
            end
        end, playerNum)
    box:initialise()
    box:addToUIManager()
    pcall(function() box.entry:focus() end)
end

-- Right-click: "Talk to ..." for the soldiers right there.
local function onMenu(playerNum, context, worldObjects, test)
    if test then return end
    local sq = LF.try("talk square", function() return worldObjects[1]:getSquare() end)
    if not sq or not LF.Inspect then return end
    for _, f in ipairs(LF.Inspect.near(sq:getX(), sq:getY(), sq:getZ())) do
        local rec = LF.Records.get(f.id)
        if rec and rec.alive and rec.faction ~= "CIV" then
            local id = f.id
            context:addOption("Talk to " .. LF.Units.title(rec), nil, function() LF.Talk.open(id, playerNum) end)
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(function(...) LF.guard("talk menu", onMenu, ...) end)
