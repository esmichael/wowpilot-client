-- WowPilot Pulso — telemetria em tempo real sem print.
-- Uma faixa de 2 linhas de células coloridas (2 px físicos cada, 8 cores = 3 bits) fica sempre no canto superior
-- esquerdo da tela; o WowPilotSync lê esses pixels direto da janela do jogo a cada segundo e manda ao site
-- (/api/pulse). Só o que muda o tempo todo: posição, direção, vida, morto/fantasma, combate, nível, mortes.
-- O resto (quests, bolsas, equipamento…) continua indo pelo print do WowPilotLive.
--
-- Pacote (big-endian): "WQ" | versão | tamanho do conteúdo | conteúdo | adler32 (4) do conteúdo
-- Conteúdo v1 (34 bytes; o pacote todo tem 42 = as 2 linhas de 56 células):
--   seq (2) · t (4, unix) · personagem (4, adler32 de "Nome-Reino") · uiMap (2) · x (2) · y (2) (fração × 65535)
--   a, b, c da UnitPosition (4 cada, jardas × 10, com sinal) · direção (1, 0–255 = 0–2π) · vida % (1, 255 = ?)
--   estado (1: 1 morto, 2 fantasma, 4 combate, 8 voo de grifo, 16 descansando, 32 montado, 64 direção ok,
--   128 posição ok) · nível (1) · mortes (2)
-- Bits: 3 por célula (vermelho, verde, azul ligado/desligado), MSB primeiro, linha 0 e depois linha 1.

local _, ns = ...
local Pulse = {}
ns.Pulse = Pulse

local VERSION = 1
local CELL = 2            -- px físicos
local BITS = 3
local COLS = 56           -- células por linha (2 linhas = 336 bits = 42 bytes, o pacote inteiro)
local ROWS = 2
local TICK = 1            -- s

local frame, cells = nil, {}
local seq, lastBody = 0, nil
local cfg

local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end
Pulse.adler32 = adler32

local function u8(n) n = math.floor(n) % 256; return string.char(n) end
local function u16(n) n = math.floor(n) % 65536; return u8(n / 256) .. u8(n) end
local function u32(n) n = math.floor(n) % 4294967296; return u16(n / 65536) .. u16(n) end
local function s32(n) n = math.floor(n + 0.5); if n < 0 then n = n + 4294967296 end; return u32(n) end

local function secret(v) return issecretvalue and issecretvalue(v) end
local function num(v) return type(v) == "number" and not secret(v) and v or nil end

-- conteúdo do pacote (sem seq/t, para saber se mudou) e o estado atual
local function sample()
    local M = C_Map
    local ui = M and M.GetBestMapForUnit and ns.safe(M.GetBestMapForUnit, "player")
    local x, y
    local p = ui and M.GetPlayerMapPosition and ns.safe(M.GetPlayerMapPosition, ui, "player")
    if p and p.GetXY then x, y = ns.safe(p.GetXY, p) end
    x, y = num(x), num(y)
    local a, b, c
    if UnitPosition then a, b, c = ns.safe(UnitPosition, "player") end
    a, b, c = num(a), num(b), num(c)
    local f = GetPlayerFacing and num(ns.safe(GetPlayerFacing))
    local hp, hpMax = num(UnitHealth and UnitHealth("player")), num(UnitHealthMax and UnitHealthMax("player"))
    local flags = 0
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then flags = flags + 1 end
    if UnitIsGhost and UnitIsGhost("player") then flags = flags + 2 end
    if (UnitAffectingCombat and UnitAffectingCombat("player")) or InCombatLockdown() then flags = flags + 4 end
    if UnitOnTaxi and UnitOnTaxi("player") then flags = flags + 8 end
    if IsResting and IsResting() then flags = flags + 16 end
    if IsMounted and IsMounted() then flags = flags + 32 end
    if f then flags = flags + 64 end
    local posOk = ui and x and y
    if posOk then flags = flags + 128 end
    local db = ns.db and ns.db()
    local me = ns.selfTarget()
    local deaths = db and db.deaths and db.deaths[me] or 0
    return u32(adler32(me))
        .. u16(posOk and ui or 0) .. u16(posOk and x * 65535 or 0) .. u16(posOk and y * 65535 or 0)
        .. s32((a or 0) * 10) .. s32((b or 0) * 10) .. s32((c or 0) * 10)
        .. u8(f and f / (2 * math.pi) * 256 or 0)
        .. u8(hp and hpMax and hpMax > 0 and math.floor(hp / hpMax * 100 + 0.5) or 255)
        .. u8(flags) .. u8(num(UnitLevel("player")) or 0) .. u16(deaths)
end

-- pacote completo → lista de índices de cor (0–7), ROWS × COLS
function Pulse.packet(body, n, t)
    local content = u16(n) .. u32(t) .. body
    local bytes = "WQ" .. u8(VERSION) .. u8(#content) .. content .. u32(adler32(content))
    local bits = {}
    for i = 1, #bytes do
        local v = bytes:byte(i)
        for k = 7, 0, -1 do bits[#bits + 1] = math.floor(v / 2 ^ k) % 2 end
    end
    local out = {}
    for i = 0, ROWS * COLS - 1 do
        out[i + 1] = (bits[i * 3 + 1] or 0) * 4 + (bits[i * 3 + 2] or 0) * 2 + (bits[i * 3 + 3] or 0)
    end
    return out, #bytes
end

local function ensureFrame()
    if frame then return end
    -- filho do WorldFrame: continua na tela com a interface escondida (Alt+Z)
    frame = CreateFrame("Frame", "WowPilotPulse", WorldFrame)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(9000)   -- abaixo do código do print (9999), que cobre esta faixa quando aparece
    if frame.SetIgnoreParentScale then frame:SetIgnoreParentScale(true) end
    for i = 1, ROWS * COLS do
        local t = frame:CreateTexture(nil, "ARTWORK")
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        cells[i] = t
    end
end

local function layout()
    local _, ph = GetPhysicalScreenSize()
    frame:SetScale(768 / (ph and ph > 0 and ph or 768))
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", WorldFrame, "TOPLEFT", 0, 0)
    frame:SetSize(COLS * CELL, ROWS * CELL)
    for i, t in ipairs(cells) do
        local r, c = math.floor((i - 1) / COLS), (i - 1) % COLS
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", c * CELL, -r * CELL)
        t:SetSize(CELL, CELL)
    end
end

function Pulse.draw(colors)
    ensureFrame()
    layout()
    for i, t in ipairs(cells) do
        local v = colors[i] or 0
        t:SetColorTexture(math.floor(v / 4) % 2, math.floor(v / 2) % 2, v % 2, 1)
    end
    frame:Show()
end

function Pulse.tick()
    if not cfg or cfg.off then if frame then frame:Hide() end return end
    local ok, body = pcall(sample)
    if not ok then return end
    if body ~= lastBody then
        seq, lastBody = (seq + 1) % 65536, body
        Pulse.draw((Pulse.packet(body, seq, time())))
    elseif not frame or not frame:IsShown() then
        Pulse.draw((Pulse.packet(body, seq, time())))
    end
end

function Pulse.active() return cfg ~= nil and not cfg.off end

function Pulse.command(arg)
    if arg == "off" or arg == "desligar" then
        cfg.off = true
        if frame then frame:Hide() end
        ns.say("pulso desligado: posição só pelos prints")
    elseif arg == "on" or arg == "ligar" then
        cfg.off = nil
        lastBody = nil
        Pulse.tick()
        ns.say("pulso ligado: a faixa no canto superior esquerdo leva a posição ao site a cada segundo")
    else
        ns.say("pulso " .. (cfg.off and "desligado" or "ligado") .. " · /wpilot pulso on|off")
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("DISPLAY_SIZE_CHANGED")
ev:RegisterEvent("UI_SCALE_CHANGED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local db = ns.db()
        db.pulse = db.pulse or {}
        cfg = db.pulse
        if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(TICK, function() pcall(Pulse.tick) end) end
        pcall(Pulse.tick)
    elseif frame then
        lastBody = nil   -- tela mudou de tamanho: redesenha no próximo tique
    end
end)
