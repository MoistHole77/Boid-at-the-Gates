-- Living Front: talking to your men.
--
-- Right-click a soldier: "Talk to <him>". A chat window opens; type, press Enter, and he
-- answers in it (and over his head, briefly). He answers as himself (LF_Persona: his age, home,
-- trade, family, traits, way of talking, what he thinks of the war, his friend in the squad),
-- from his state now (morale, wounds, what his unit is doing) and from what he has seen
-- (LF_Memory). With the LF bridge running, a language model plays him; without it, he answers
-- plainly from what he last saw.
-- When the window closes, the conversation is summed up in a short note in his record, with
-- whether he now thinks better or worse of you (LF.Persona.remember) - so next time he
-- remembers. Within a conversation, the last exchanges go back to the model each turn.

require "LivingFront/Core/LF_Core"
require "LivingFront/Core/LF_Records"
require "LivingFront/Units/LF_Units"
require "LivingFront/World/LF_Chasm"
require "LivingFront/Soldier/LF_Memory"
require "LivingFront/Soldier/LF_Persona"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"

LF.Talk = LF.Talk or {}

local CFG = {
    keep = 8,               -- exchanges sent back to the model within a conversation
    W = 460, H = 380, PAD = 10,
}

-- ---- what he says with no language model ----------------------------------------------------------

local function firstPerson(s)
    s = s:gsub("from your squad", "from our squad"):gsub("Your squad", "Our squad"):gsub("your squad", "our squad")
    s = s:gsub("You were wounded", "I was wounded"):gsub("your side", "our side")
    return s
end

local GREET = { GER = "Jawohl.", SOV = "Da, comrade." }

-- What he asks about: the first topic whose words are in the question.
local TOPICS = {
    { "name", { "your name", "who are you", "called" } },
    { "home", { "where are you from", "where you from", "hometown", "home town", "born", "from?" } },
    { "family", { "family", "wife", "mother", "mum", "mom", "children", "kids", "sweetheart", "girl", "brother",
                  "sister", "married", "parents", "father", "letters" } },
    { "job", { "job", "work", "before the war", "trade", "for a living" } },
    { "past", { "how long", "served", "serving", "join", "enlist", "called up", "experience", "veteran", "been in" } },
    { "age", { "how old", "your age" } },
    { "fear", { "afraid", "fear", "scared", "frightened" } },
    { "want", { "want", "wish", "after the war", "dream", "hope" } },
    { "friend", { "friend", "mates", "team", "squad", "the others", "the men", "people in", "get along" } },
    { "war", { "war", "win", "lose", "winning", "losing", "fight for", "politic", "party", "stalin", "hitler",
               "fuhrer", "führer", "think of", "worth it" } },
    { "seen", { "happen", "seen", "see anything", "news", "report", "what's going on", "whats going on", "lately" } },
    { "mood", { "how are", "how's it", "hows it", "how is it", "feel", "doing", "morale", "okay", "alright", "all right" } },
}

local function topicOf(text)
    local t = " " .. text:lower() .. " "
    for _, tp in ipairs(TOPICS) do
        for _, w in ipairs(tp[2]) do
            if t:find(w, 1, true) then return tp[1] end
        end
    end
    return nil
end

-- What he says with no language model: an answer on what you asked about, in his own words,
-- or else what he last saw, or a line in his own voice.
local function plainReply(rec, mems, n, text)
    local topic = topicOf(text or "")
    if topic == "name" then return LF.Units.title(rec) .. ", sir." end
    if topic == "seen" or (n == 1 and not topic and #mems > 0) then
        if #mems == 0 then return (GREET[rec.faction] or "") .. " Nothing to report - it has been quiet." end
        local said = {}
        for i = 1, math.min(2, #mems) do said[#said + 1] = firstPerson(mems[i]) end
        return table.concat(said, " ")
    end
    local line = topic and LF.Persona.say(rec, topic)
    if line then return line end
    if n == 1 then return (GREET[rec.faction] or "Yes?") .. " " .. LF.Persona.say(rec, "mood") end
    return LF.Persona.line(rec, n)
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

-- ---- a conversation ---------------------------------------------------------------------------------

local sessions = {}         -- record id -> { lines = { {who, text} }, exchanges = { {you, him} }, waiting }
Events.OnInitGlobalModData.Add(function() sessions = {} end)

local function session(id)
    local s = sessions[id]
    if not s then s = { lines = {}, exchanges = {} }; sessions[id] = s end
    return s
end

local function addLine(id, who, text)
    local s = session(id)
    s.lines[#s.lines + 1] = { who = who, text = text }
    while #s.lines > 60 do table.remove(s.lines, 1) end
end

-- You say text to him; his answer comes into the conversation (and the window, if open).
function LF.Talk.say(id, text)
    local rec = LF.Records.get(id)
    if not (rec and rec.alive) then return end
    local s = session(id)
    local title = LF.Units.title(rec)
    addLine(id, "You", text)
    LF.log("TALK you to " .. title .. " #" .. id .. ": " .. text)
    local mems = LF.Memory.of(rec, 6)
    local fallback = plainReply(rec, mems, #s.exchanges + 1, text)
    local function answer(words, how)
        s.waiting = nil
        s.exchanges[#s.exchanges + 1] = { you = text, him = words }
        while #s.exchanges > CFG.keep do table.remove(s.exchanges, 1) end
        addLine(id, title, words)
        LF.log("TALK " .. title .. " #" .. id .. (how and (" (" .. how .. ")") or "") .. ": " .. words)
        if LF.Tactics and LF.Tactics.say then LF.Tactics.say(id, words) end
    end
    if LF.Chasm.alive() then
        local prof = LF.Memory.profile(rec)
        prof.doing = doing(rec)
        s.waiting = true
        local sent = LF.Chasm.request({ kind = "talk", soldier = prof, persona = LF.Persona.card(rec), memories = mems,
                                        history = s.exchanges, player_text = text, fallback = fallback },
            function(ans)
                if ans and ans.text and ans.text ~= "" then answer(ans.text, ans.worded == "yes" and "language model" or nil)
                else answer(fallback, "plain") end
            end, id)
        if sent then return end
        s.waiting = nil
    end
    answer(fallback, "plain")
end

-- The conversation is over: sum it up in a note he keeps.
local function finish(id)
    local s = sessions[id]
    sessions[id] = nil
    if not s or #s.exchanges == 0 then return end
    local rec = LF.Records.get(id)
    if not (rec and rec.alive) then return end
    local first = s.exchanges[1].you
    local plainNote = "The officer talked with him" .. (first and (" (he asked: \"" .. first:sub(1, 60) .. "\")") or "") .. "."
    local function keep(note, delta)
        LF.Persona.remember(rec, note, delta)
        LF.log("TALK " .. LF.Units.title(rec) .. " #" .. id .. " remembers: " .. note .. " (trust " .. tostring(rec.talk.trust) .. ")")
    end
    if LF.Chasm.alive() then
        local sent = LF.Chasm.request({ kind = "summarize", soldier = LF.Memory.profile(rec), persona = LF.Persona.card(rec),
                                        history = s.exchanges, fallback = plainNote },
            function(ans)
                if ans and ans.text and ans.text ~= "" then
                    local d = tonumber((tostring(ans.trust or "0"):gsub("^%+", ""))) or 0
                    keep(ans.text, math.max(-1, math.min(1, d)))
                else keep(plainNote, 0) end
            end)
        if sent then return end
    end
    keep(plainNote, 0)
end

-- ---- the window -----------------------------------------------------------------------------------------

LF_TalkWindow = ISCollapsableWindow:derive("LF_TalkWindow")
local open = {}

function LF_TalkWindow:new(x, y, id)
    local o = ISCollapsableWindow.new(self, x, y, CFG.W, CFG.H)
    o.recId = id
    o.resizable = false
    local rec = LF.Records.get(id)
    o.title = "Talking to " .. (rec and LF.Units.title(rec) or "?")
    return o
end

function LF_TalkWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local th = self:titleBarHeight()
    local eh = 24
    local bw = 64
    self.entry = ISTextEntryBox:new("", CFG.PAD, self.height - eh - CFG.PAD, self.width - CFG.PAD * 3 - bw, eh)
    self.entry:initialise()
    self.entry:instantiate()
    local win = self
    self.entry.onCommandEntered = function() win:send() end
    self:addChild(self.entry)
    self.button = ISButton:new(self.width - CFG.PAD - bw, self.height - eh - CFG.PAD, bw, eh, "Say", self, LF_TalkWindow.send)
    self.button:initialise()
    self:addChild(self.button)
    self.top = th + CFG.PAD
end

function LF_TalkWindow:send()
    local t = self.entry:getText()
    if not (t and t:match("%S")) then return end
    self.entry:setText("")
    LF.Talk.say(self.recId, t)
    pcall(function() self.entry:focus() end)
end

-- Wrap text to a pixel width.
local function wrapPx(text, font, width)
    local tm = getTextManager()
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if tm:MeasureStringX(font, try) > width and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else line = try end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function LF_TalkWindow:prerender()
    ISCollapsableWindow.prerender(self)
    if self.isCollapsed then return end
    local rec = LF.Records.get(self.recId)
    local font = UIFont.Small
    local tm = getTextManager()
    local fh = tm:getFontHeight(font)
    local w = self.width - CFG.PAD * 2
    local bottom = self.height - 24 - CFG.PAD * 2
    local s = sessions[self.recId]
    -- Lay out the conversation from the bottom up; the oldest lines scroll off the top.
    local rows = {}
    if s and s.waiting then rows[#rows + 1] = { text = "...", r = 0.7, g = 0.7, b = 0.7 } end
    for i = (s and #s.lines or 0), 1, -1 do
        local l = s.lines[i]
        local you = l.who == "You"
        local body = wrapPx(l.text, font, w - 12)
        for j = #body, 1, -1 do rows[#rows + 1] = { text = body[j], x = 12, r = 1, g = 1, b = 1 } end
        rows[#rows + 1] = { text = l.who .. ":", r = you and 0.6 or 0.95, g = you and 0.85 or 0.85, b = you and 1 or 0.55 }
        if (#rows + 1) * fh > bottom - self.top then break end
    end
    local y = bottom - fh
    for _, row in ipairs(rows) do
        if y < self.top then break end
        self:drawText(row.text, CFG.PAD + (row.x or 0), y, row.r, row.g, row.b, 1, font)
        y = y - fh
    end
    if not s or #s.lines == 0 then
        local hint = rec and rec.alive and "Type and press Enter to speak to him." or "He can't answer you."
        self:drawText(hint, CFG.PAD, self.top, 0.7, 0.7, 0.7, 1, font)
    end
end

function LF_TalkWindow:close()
    open[self.recId] = nil
    LF.guard("talk finish", finish, self.recId)
    self:setVisible(false)
    self:removeFromUIManager()
end

function LF.Talk.open(id)
    if open[id] then open[id]:bringToTop(); return end
    local x = math.min(getMouseX() + 20, getCore():getScreenWidth() - CFG.W - 10)
    local y = math.min(math.max(10, getMouseY() - 80), getCore():getScreenHeight() - CFG.H - 10)
    local w = LF_TalkWindow:new(x, y, id)
    w:initialise()
    w:addToUIManager()
    open[id] = w
    pcall(function() w.entry:focus() end)
end

-- He walked off, died, or you walked away: the conversation ends.
Events.OnTick.Add(function()
    if LF.tick % 60 ~= 31 then return end
    local p = getPlayer()
    for id, w in pairs(open) do
        local rec = LF.Records.get(id)
        local b = LF.Bodies and LF.Bodies.get(id)
        local far = b and p and LF.dist(b:getX(), b:getY(), p:getX(), p:getY()) > 12
        if not (rec and rec.alive) or not b or far then
            LF.guard("talk close", function() w:close() end)
        end
    end
end)

-- Right-click: "Talk to ..." for the soldiers right there.
local function onMenu(playerNum, context, worldObjects, test)
    if test then return end
    local sq = LF.try("talk square", function() return worldObjects[1]:getSquare() end)
    if not sq or not LF.Inspect then return end
    for _, f in ipairs(LF.Inspect.near(sq:getX(), sq:getY(), sq:getZ())) do
        local rec = LF.Records.get(f.id)
        if rec and rec.alive and rec.faction ~= "CIV" then
            local id = f.id
            context:addOption("Talk to " .. LF.Units.title(rec), nil, function() LF.Talk.open(id) end)
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(function(...) LF.guard("talk menu", onMenu, ...) end)
