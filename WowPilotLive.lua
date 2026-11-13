-- WowPilot Live — envia os dados ao site sem /reload.
-- Desenha um código colorido no canto superior esquerdo da tela, chama Screenshot() e esconde o código.
-- O cliente WowPilotSync.ps1 (Windows) vigia a pasta Screenshots, decodifica, envia ao site e apaga o print.
--
-- Código (v3): 255 colunas, células de CELL px físicos, BITS bits por célula (64 cores: 4 níveis por canal).
--   linha 0 e coluna 0 = padrão de tempo preto/branco (o leitor mede o tamanho da célula)
--   linha 1: células 1–8 = BITS em binário (preto = 1); a partir da 9 = a paleta inteira (cor 0 … 2^BITS−1),
--            o leitor classifica cada célula pela cor mais próxima medida na própria imagem (resiste a gama/brilho)
--   linha 2 em diante = cabeçalho + dados, BITS bits por célula, MSB primeiro
-- Cabeçalho (16 bytes): "WP" | 3 | colunas | tipo | flags | msg (2) | página | total | tamanho (2) | adler32 (4)
--   tipo 3 = snapshot completo (JSON); flags bit 0 = comprimido (C_EncodingUtil.CompressString, zlib)
-- Mensagens maiores que uma página viram vários prints em sequência (um código por print).

local _, ns = ...
local Live = {}
ns.Live = Live

local VERSION = 3
local COLS = 255              -- máximo do cabeçalho (1 byte)
local CELL = 2                -- px físicos por célula
local BITS = 6                -- bits por célula (64 cores)
-- altura máxima de um código (linhas). Era 100 (~18 KB, ~25 mil retângulos na tela num print só); com o código
-- quase cheio o jogo às vezes deixava de desenhar a interface no quadro do print. 40 = ~7 KB por print: o envio
-- normal cabe em um pequeno e um grande (o primeiro depois do /reload) vai em 2–3 prints menores.
local ROWS_MAX = 40
local PAGE = math.floor((ROWS_MAX - 2) * (COLS - 1) * BITS / 8) - 16  -- bytes por print (~7 KB)
local MAX_PAGES = 20
local RESEND = 300             -- s: partes grandes que só vão quando mudam (players, names) vão de novo depois disso
local COMPRESS_MIN = 200      -- abaixo disso não vale comprimir
local KIND_FULL = 3
local CHAT_PER_MSG = 60
local DEBOUNCE = 2
local DEFAULT_INTERVAL, MIN_INTERVAL = 30, 5
-- eventos que disparam um envio (debounce + intervalo mínimo)
local TRIGGERS = {
    WEEKLY_REWARDS_UPDATE = true, CHALLENGE_MODE_COMPLETED = true, CURRENCY_DISPLAY_UPDATE = true,
    PLAYER_EQUIPMENT_CHANGED = "simc", PLAYER_SPECIALIZATION_CHANGED = "simc",
    BAG_UPDATE_DELAYED = true, PLAYER_MONEY = true, CHALLENGE_MODE_MAPS_UPDATE = true,
    -- WoW: Forever (subir de nível): XP, quests, zona, profissões, talentos
    PLAYER_LEVEL_UP = true, PLAYER_XP_UPDATE = true, QUEST_LOG_UPDATE = true, ZONE_CHANGED_NEW_AREA = true,
    SKILL_LINES_CHANGED = true, CHARACTER_POINTS_CHANGED = true, UPDATE_INVENTORY_DURABILITY = true,
    PLAYER_UPDATE_RESTING = true, QUEST_TURNED_IN = true, PLAYER_TARGET_CHANGED = true,
    -- chovem em raide e cidade (placa de nome de cada um que aparece, mudança na raide): devagar (SLOW_INTERVAL)
    NAME_PLATE_UNIT_ADDED = "slow", GROUP_ROSTER_UPDATE = "slow",
}
-- envios por causa deles no máximo a cada tanto: cada envio é um print (a interface pisca) e, numa raide de 40, eles
-- disparavam um envio a cada intervalo mesmo parado. Andar, XP, quest, nível, alvo e morte seguem no intervalo normal.
local SLOW_INTERVAL = 30
local SLOW_REASONS = { chat = true, group = true, groups = true }   -- Live.onDataChanged: chat, inspeção, sessões de grupo

local cfg                      -- WowPilotDB.live
local frame, bg, pool = nil, nil, {}
local busy, waitCombat = false, false
local queue = {}               -- códigos (páginas) esperando o print
local current                  -- token da página na tela (o timer de segurança não fecha a seguinte)
local sched = { last = 0 }
local simcDirty = true         -- recalcula o SimC na próxima captura (login, troca de item/spec)
local savedCVars
local lastPrint = -10          -- GetTime() do último Screenshot()
local GAP = 1.1                -- o nome do arquivo tem precisão de segundos: 2 prints no mesmo segundo colidem

------------------------------------------------------------
-- Codificação
------------------------------------------------------------
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function u8(n) return string.char(n % 256) end

local function u16(n) return u8(math.floor(n / 256)) .. u8(n) end

-- cor da paleta (índice 0..2^BITS-1) → r, g, b em 0..1; o último índice é branco (fundo, sem textura)
function Live.paletteColor(i)
    local L = 2 ^ (BITS / 3)
    return (math.floor(i / (L * L)) % L) / (L - 1), (math.floor(i / L) % L) / (L - 1), (i % L) / (L - 1)
end

-- h = { kind, flags, msg, page, total }; devolve { cols, rows, color(r, c) → índice da paleta, size }
function Live.encode(chunk, h)
    h = h or {}
    local n, sum = #chunk, adler32(chunk)
    local bytes = "WP" .. u8(VERSION) .. u8(COLS) .. u8(h.kind or KIND_FULL) .. u8(h.flags or 0)
        .. u16(h.msg or 0) .. u8(h.page or 0) .. u8(h.total or 1) .. u16(n)
        .. u16(math.floor(sum / 65536)) .. u16(sum)
        .. chunk
    local bits = {}
    for i = 1, #bytes do
        local b = bytes:byte(i)
        for k = 7, 0, -1 do bits[#bits + 1] = math.floor(b / 2 ^ k) % 2 end
    end
    local width, ncol = COLS - 1, 2 ^ BITS
    local cells = math.ceil(#bits / BITS)
    local white = ncol - 1
    local function color(r, c)
        if r == 0 then return (c % 2 == 0) and 0 or white end
        if c == 0 then return (r % 2 == 0) and 0 or white end
        if r == 1 then
            if c <= 8 then return (math.floor(BITS / 2 ^ (8 - c)) % 2 == 1) and 0 or white end
            local p = c - 9
            return p < ncol and p or white
        end
        local idx = (r - 2) * width + (c - 1)
        if idx >= cells then return white end
        local v = 0
        for k = 1, BITS do v = v * 2 + (bits[idx * BITS + k] or 0) end
        return v
    end
    return { cols = COLS, rows = 2 + math.ceil(cells / width), color = color, white = white, size = #bytes }
end

-- comprime (se a API existir e compensar) e divide em páginas
function Live.frames(kind, payload)
    local data, flags = payload, 0
    local enc = C_EncodingUtil
    if #payload >= COMPRESS_MIN and enc and enc.CompressString then
        local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib
        local ok, out = pcall(enc.CompressString, payload, method)
        if ok and type(out) == "string" and #out < #payload then data, flags = out, 1 end
    end
    cfg.msg = ((cfg.msg or 0) + 1) % 65536
    local total = math.min(MAX_PAGES, math.max(1, math.ceil(#data / PAGE)))
    local codes = {}
    for page = 0, total - 1 do
        codes[#codes + 1] = Live.encode(data:sub(page * PAGE + 1, (page + 1) * PAGE),
            { kind = kind or KIND_FULL, flags = flags, msg = cfg.msg, page = page, total = total })
    end
    return codes, #payload, #data
end

-- JSON mínimo (Lua 5.1) — chaves ordenadas para a saída ser estável
local function json(v)
    local t = type(v)
    if t == "table" then
        local out = {}
        if #v > 0 or next(v) == nil then
            for i = 1, #v do out[i] = json(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do out[#out + 1] = json(tostring(k)) .. ":" .. json(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    elseif t == "string" then
        local esc = v:gsub('[%c"\\]', function(c)
            if c == '"' or c == "\\" then return "\\" .. c end
            if c == "\n" then return "\\n" end
            return string.format("\\u%04x", c:byte())
        end)
        return '"' .. esc .. '"'
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) then return string.format("%.0f", v) end
        return string.format("%.6g", v)
    elseif t == "boolean" then
        return tostring(v)
    end
    return "null"
end
Live.json = json

------------------------------------------------------------
-- Snapshot completo (JSON). Itens vão compactos:
--   equipamento: id.encanto.gema-gema.bonus-bonus.ilvl     bolsas: qtd*<item>  (ou qtd*id)
------------------------------------------------------------
local function itemStr(link, ilvl)
    local p = ns.parseLink(link)
    if not p.id then return nil end
    if not p.bonus and not p.enchant and #p.gems == 0 and not ilvl then return tostring(p.id) end
    return string.format("%d.%d.%s.%s.%d", p.id, p.enchant or 0, table.concat(p.gems, "-"),
        table.concat(p.bonus or {}, "-"), ilvl or 0)
end

local function summary()
    return ns.collect()
end

local function vault()
    local out = {}
    for _, a in ipairs(ns.collectVault()) do
        out[#out + 1] = { a.type or 0, a.index or 0, a.progress or 0, a.threshold or 0, a.level or 0,
                          a.ilvl or 0, a.upIlvl or 0 }
    end
    return out
end

-- moedas: a lista completa (expandindo cabeçalhos) só na 1ª vez; depois GetCurrencyInfo por id,
-- para não reabrir categorias que o jogador fechou na janela de moedas
local function currencies()
    if not cfg.curIds then
        cfg.curIds = {}
        for _, c in ipairs(ns.collectCurrencies()) do if c.id then cfg.curIds[#cfg.curIds + 1] = c.id end end
    end
    local seen = {}
    for _, id in ipairs(cfg.curIds) do seen[id] = true end
    for i = 1, (C_CurrencyInfo.GetCurrencyListSize() or 0) do  -- moedas novas visíveis na lista
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        local link = info and not info.isHeader and C_CurrencyInfo.GetCurrencyListLink(i)
        local id = link and C_CurrencyInfo.GetCurrencyIDFromLink(link)
        if id and not seen[id] then seen[id] = true; cfg.curIds[#cfg.curIds + 1] = id end
    end
    local out = {}
    for _, id in ipairs(cfg.curIds) do
        local c = ns.safe(C_CurrencyInfo.GetCurrencyInfo, id)
        if c then
            out[#out + 1] = { id, c.quantity or 0, c.maxQuantity or 0, c.quantityEarnedThisWeek or 0,
                              c.maxWeeklyQuantity or 0, c.totalEarned or 0, c.useTotalEarnedForMaxQty and 1 or 0 }
        end
    end
    return out
end

local function players()
    local list = {}
    local _, classTag = UnitClass("player")
    local me = { name = ns.selfTarget(), class = classTag, level = UnitLevel("player"), me = true, items = {} }
    local spec = GetSpecialization and GetSpecialization()
    if spec then
        local _, specName, _, _, role = GetSpecializationInfo(spec)
        me.spec, me.role = specName, role
    end
    local _, equipped = GetAverageItemLevel()
    me.ilvl = equipped and math.floor(equipped * 10 + 0.5) / 10
    for slot, key in pairs(ns.SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local loc = ItemLocation:CreateFromEquipmentSlot(slot)
            local ilvl = (loc and loc:IsValid() and ns.safe(C_Item.GetCurrentItemLevel, loc))
                or ns.safe(C_Item.GetDetailedItemLevelInfo, link) or 0
            me.items[key] = itemStr(link, ilvl)
        end
    end
    list[1] = me
    local db = ns.db()
    local members = db.group and db.group.members or {}
    local guids = {}
    for guid in pairs(members) do guids[#guids + 1] = guid end
    table.sort(guids)
    for _, guid in ipairs(guids) do
        local m = members[guid]
        local p = { name = m.name, class = m.class, spec = m.spec, role = m.role, level = m.level,
                    rio = m.rio, inspectStatus = m.inspectStatus, inspectedAt = m.inspectedAt, items = {} }
        p.ilvl = m.ilvl and math.floor(m.ilvl * 10 + 0.5) / 10
        for key, it in pairs(m.items or {}) do
            if it.link then p.items[key] = itemStr(it.link, it.ilvl or 0) end
        end
        list[#list + 1] = p
    end
    return list
end

local function bags()
    local out = {}
    for _, bag in ipairs(ns.bagIds()) do
        for slot = 1, (ns.safe(C_Container.GetContainerNumSlots, bag) or 0) do
            local info = ns.safe(C_Container.GetContainerItemInfo, bag, slot)
            local p = info and info.hyperlink and ns.parseLink(info.hyperlink)
            if p and p.id then  -- mascote/keystone não são item: ficam de fora
                local ilvl
                if p.bonus then
                    local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                    ilvl = loc and loc:IsValid() and ns.safe(C_Item.GetCurrentItemLevel, loc) or nil
                end
                out[#out + 1] = (info.stackCount or 1) .. "*" .. itemStr(info.hyperlink, ilvl)
            end
        end
    end
    return out
end

-- formato das bolsas (para o site desenhar igual ao jogo): tamanho de cada bolsa e, na ordem da lista `bags`,
-- a posição de cada item como bolsa*100 + espaço
local function bagLayout()
    local sizes, pos = {}, {}
    for _, bag in ipairs(ns.bagIds()) do
        local n = ns.safe(C_Container.GetContainerNumSlots, bag) or 0
        if n > 0 then sizes[#sizes + 1] = { bag, n } end
        for slot = 1, n do
            local info = ns.safe(C_Container.GetContainerItemInfo, bag, slot)
            local p = info and info.hyperlink and ns.parseLink(info.hyperlink)
            if p and p.id then pos[#pos + 1] = bag * 100 + slot end
        end
    end
    return { sizes = sizes, pos = pos }
end

local function bank(preview)
    local db = ns.db()
    local b = db.bank and db.bank[ns.selfTarget()]
    if not b or b.t == cfg.bankSent then return nil end
    if not preview then cfg.bankSent = b.t end
    local out = {}
    for _, it in ipairs(b.items or {}) do
        local s = it.link and itemStr(it.link, it.bonus and it.ilvl or nil)
        if s then out[#out + 1] = (it.count or 1) .. "*" .. s end
    end
    return { t = b.t, items = out }
end

local function chat(preview)
    local log, out, last = ns.db().chat or {}, {}, cfg.chatSent or 0
    local maxN = last
    for i = math.max(1, #log - 200), #log do
        local m = log[i]
        if m and m.n and m.n > last then
            out[#out + 1] = { m.n, m.t, m.ch, m.from or "", m.msg or "", m.chan or "" }
            if m.n > maxN then maxN = m.n end
        end
    end
    while #out > CHAT_PER_MSG do table.remove(out, 1) end
    if not preview then cfg.chatSent = maxN end
    return #out > 0 and out or nil
end

-- Mítica+: pontuação/melhor nível por masmorra, runs da semana e afixos
--   maps = [[mapID, nome, pontos, nível, noTempo, tempoLimite]]   runs = [[mapID, nível, concluída, pontos]]
local function mythicPlus()
    local CM, MP = C_ChallengeMode, C_MythicPlus
    if not (CM and MP and CM.GetMapTable) then return nil end
    local out = { score = ns.safe(CM.GetOverallDungeonScore) or 0, maps = {}, runs = {}, affixes = {} }
    for _, mapID in ipairs(ns.safe(CM.GetMapTable) or {}) do
        local name, _, timeLimit = ns.safe(CM.GetMapUIInfo, mapID)
        local level, timed, score = 0, 0, 0
        if MP.GetSeasonBestForMap then
            local intime, overtime = ns.safe(MP.GetSeasonBestForMap, mapID)
            local li, lo = intime and intime.level or 0, overtime and overtime.level or 0
            level, timed = math.max(li, lo), (li > 0 and li >= lo) and 1 or 0
            score = (intime and intime.dungeonScore) or (overtime and overtime.dungeonScore) or 0
        end
        if MP.GetSeasonBestAffixScoreInfoForMap then
            local _, bonus = ns.safe(MP.GetSeasonBestAffixScoreInfoForMap, mapID)
            if bonus and bonus > 0 then score = bonus end
        end
        out.maps[#out.maps + 1] = { mapID, name or "", math.floor(score + 0.5), level, timed, timeLimit or 0 }
    end
    for _, r in ipairs(MP.GetRunHistory and ns.safe(MP.GetRunHistory, false, true) or {}) do
        out.runs[#out.runs + 1] = { r.mapChallengeModeID or 0, r.level or 0, r.completed and 1 or 0, r.runScore or 0 }
    end
    for _, a in ipairs(MP.GetCurrentAffixes and ns.safe(MP.GetCurrentAffixes) or {}) do
        local name = CM.GetAffixInfo and ns.safe(CM.GetAffixInfo, a.id)
        if name then out.affixes[#out.affixes + 1] = name end
    end
    return out
end

-- sessões de grupo que mudaram desde a última captura
local function groups(preview)
    local sent = cfg.groupsSent or 0
    local out, maxU = {}, sent
    for _, g in ipairs(ns.db().groups or {}) do
        if (g.u or 0) > sent then
            local m = {}
            for name, x in pairs(g.members or {}) do
                m[#m + 1] = { name, x.class or "", x.role or "", x.spec or "",
                              x.ilvl and math.floor(x.ilvl + 0.5) or 0, x.rio and math.floor(x.rio) or 0,
                              x.joined or 0, x.left or 0 }
            end
            table.sort(m, function(a, b) if a[7] ~= b[7] then return a[7] < b[7] end return a[1] < b[1] end)
            local perf
            if g.perf then  -- [[nome, dano, cura, dps, hps]]
                perf = { t = g.perf.t, dur = math.floor(g.perf.dur or 0), rows = {} }
                for name, r in pairs(g.perf.by or {}) do
                    perf.rows[#perf.rows + 1] = { name, math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4]) }
                end
                table.sort(perf.rows, function(a, b) return a[1] < b[1] end)
            end
            out[#out + 1] = { id = g.id, start = g.start, stop = g.stop or 0, raid = g.raid and 1 or 0,
                              places = g.places or {}, m = m, u = g.u, perf = perf }
            if g.u > maxU then maxU = g.u end
        end
    end
    if not preview then cfg.groupsSent = maxU end
    return #out > 0 and out or nil
end

local function simc(preview, force)
    if not (simcDirty or force) or not (SimulationcraftAPI and SimulationcraftAPI.GetSimcProfile) then return nil end
    local ok, profile = pcall(SimulationcraftAPI.GetSimcProfile, Simulationcraft, false, false, false, false)
    if not ok or type(profile) ~= "string" then return nil end
    profile = profile:gsub("||", "|")
    local sum = adler32(profile)
    if not preview then simcDirty = false end
    if sum == cfg.simcSum and not force then return nil end
    if not preview then cfg.simcSum = sum end
    return profile
end

function Live.fullPayload(preview, forceSimc)
    if not preview then cfg.seq = (cfg.seq or 0) + 1 end  -- prévia não gasta número
    -- partes grandes que mudam pouco (equipamento de cada membro do grupo/raide: ~15 KB numa raide de 40; nomes dos
    -- itens): só quando mudam, ou a cada RESEND s; o site guarda as do envio anterior. Envio menor = código menor
    -- na tela (com o código quase cheio, o jogo deixava de desenhar a interface no quadro do print).
    local function changed(key, value)
        if value == nil then return nil end
        local sums = cfg.sums or {}
        local sum = adler32(json(value))
        if not forceSimc and sums[key] == sum and time() - (sums[key .. "@"] or 0) < RESEND then return nil end
        if not preview then sums[key], sums[key .. "@"] = sum, time(); cfg.sums = sums end
        return value
    end
    local function part(fn, ...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        ns.say("live: falha ao coletar: " .. tostring(res))
    end
    local s = part(summary) or {}
    local data = {
        v = 1, t = time(), seq = cfg.seq or 0, s = s,
        vault = part(vault), cur = part(currencies), players = changed("players", part(players)), bags = part(bags), bagl = part(bagLayout),
        bank = part(bank, preview), chat = part(chat, preview), simc = part(simc, preview, forceSimc),
        groups = part(groups, preview), mp = part(mythicPlus), vd = part(ns.collectVaultDetail),
    }
    if ns.GAME ~= "retail" then
        data.fv = part(ns.collectForever)
        data.names = changed("names", part(ns.itemDetails))
        local maps = not cfg.mapsSent and part(ns.mapNames) or nil  -- 1x por sessão
        if maps or forceSimc then
            data.maps = maps or part(ns.mapNames)
            if not preview then cfg.mapsSent = true end
        end
        -- quests entregues: só quando a lista muda
        local done = part(ns.completedQuests)
        if done then
            local sum = adler32(table.concat(done, ","))
            if forceSimc or sum ~= cfg.doneSum then
                data.done = done
                if not preview then cfg.doneSum = sum end
            end
        end
    end
    return json(data)
end

------------------------------------------------------------
-- Desenho (1 unidade de UI = 1 pixel físico), sempre no canto superior esquerdo
------------------------------------------------------------
local function ensureFrame()
    if frame then return end
    frame = CreateFrame("Frame", "WowPilotLiveCode", UIParent)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(9999)
    if frame.SetIgnoreParentScale then frame:SetIgnoreParentScale(true) end
    frame:Hide()
    bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(1, 1, 1, 1)
    bg:SetAllPoints(frame)
end

local function tex(i)
    local t = pool[i]
    if not t then
        t = frame:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0, 0, 0, 1)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        pool[i] = t
    end
    return t
end

function Live.draw(code)
    ensureFrame()
    local _, ph = GetPhysicalScreenSize()
    frame:SetScale(768 / (ph and ph > 0 and ph or 768))
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    frame:SetSize(code.cols * CELL, code.rows * CELL)
    -- sequências horizontais da mesma cor viram uma textura só; branco é o fundo (sem textura)
    local used = 0
    for r = 0, code.rows - 1 do
        local col = 0
        while col < code.cols do
            local v = code.color(r, col)
            if v ~= code.white then
                local start = col
                while col < code.cols and code.color(r, col) == v do col = col + 1 end
                used = used + 1
                local t = tex(used)
                t:SetColorTexture(Live.paletteColor(v))
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", frame, "TOPLEFT", start * CELL, -r * CELL)
                t:SetSize((col - start) * CELL, CELL)
                t:Show()
            else
                col = col + 1
            end
        end
    end
    for i = used + 1, #pool do pool[i]:Hide() end
    return used
end

------------------------------------------------------------
-- Captura
------------------------------------------------------------
local function setCVar(name, value)
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    local set = C_CVar and C_CVar.SetCVar or SetCVar
    local ok, old = pcall(get, name)
    if ok and old ~= nil then
        pcall(set, name, value)
        return old
    end
end

local pump

local function finish(token)
    if not busy or (token and token ~= current) then return end
    busy, current = false, nil
    if frame then frame:Hide() end
    if #queue > 0 then
        C_Timer.After(GAP, pump)  -- próxima página
        return
    end
    if savedCVars then
        for name, old in pairs(savedCVars) do setCVar(name, old) end
        savedCVars = nil
    end
    -- some a mensagem "Captura de tela salva" (se o UIParent já mostrou)
    C_Timer.After(0, function() if ActionStatus and ActionStatus.Hide then ActionStatus:Hide() end end)
end

pump = function()
    if busy or #queue == 0 then return end
    if InCombatLockdown() then waitCombat = true; return end  -- retoma no fim do combate
    local wait = GAP - (GetTime() - lastPrint)
    if wait > 0 then return C_Timer.After(wait, pump) end
    local code = table.remove(queue, 1)
    Live.draw(code)
    busy = true
    local token = {}
    current = token
    -- PNG sempre: JPEG destrói as cores do código
    savedCVars = savedCVars or { screenshotFormat = setCVar("screenshotFormat", "png"),
                                 screenshotQuality = setCVar("screenshotQuality", "10") }
    frame:Show()
    lastPrint = GetTime()
    Screenshot()
    C_Timer.After(3, function() finish(token) end)  -- segurança, caso SCREENSHOT_* não dispare
end

function Live.capture(reason, forceSimc)
    if InCombatLockdown() then
        waitCombat = true
        sched.dirty = true
        if reason == "manual" then ns.say("Em combate — envio adiado para o fim do combate.") end
        return false
    end
    local ok, payload = pcall(Live.fullPayload, false, forceSimc)
    if not ok then
        ns.say("erro na coleta: " .. tostring(payload))
        return false
    end
    local codes, raw, sent = Live.frames(KIND_FULL, payload)
    for _, c in ipairs(codes) do queue[#queue + 1] = c end
    sched.last, sched.dirty = time(), false
    pump()
    if reason == "manual" then
        ns.say(string.format("envio #%d: %d bytes%s, %d print(s)", cfg.seq, raw,
            sent < raw and string.format(" → %d comprimido", sent) or "", #codes))
    end
    return true
end
WowPilot_Send = function() return Live.capture("manual") end  -- macro: /run WowPilot_Send()

-- debounce + intervalo: junta rajadas de eventos num envio só (intervalo 0 = só manual). slow = evento barulhento: no
-- máximo a cada SLOW_INTERVAL s (ou o intervalo, se maior). Um envio marcado mais cedo leva tudo junto; um pedido que
-- precisa sair antes do marcado o substitui.
local function schedule(delay, slow)
    if not cfg or cfg.interval == 0 then return end
    local gap = slow and math.max(cfg.interval, SLOW_INTERVAL) or cfg.interval
    local due = math.max(time() + delay, sched.last + gap)
    if sched.due and sched.due <= due then return end
    sched.due = due
    C_Timer.After(math.max(0, due - time()), function()
        if sched.due ~= due then return end   -- outro envio, mais cedo, assumiu
        sched.due = nil
        if cfg.interval == 0 then return end
        local wait = cfg.interval - (time() - sched.last)
        if wait > 0 then return schedule(wait, slow) end
        Live.capture("auto")
    end)
end

-- andar não gera evento: a cada intervalo confere a posição e agenda um envio se mudou (> 0,3% do mapa)
local lastPos
local function posKey()
    local M = C_Map
    local id = M and M.GetBestMapForUnit and ns.safe(M.GetBestMapForUnit, "player")
    local p = id and M.GetPlayerMapPosition and ns.safe(M.GetPlayerMapPosition, id, "player")
    local x, y
    if p and p.GetXY then x, y = ns.safe(p.GetXY, p) end
    if type(x) ~= "number" or type(y) ~= "number" or (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then return nil end
    return id, x * 100, y * 100
end
-- andou o bastante para valer um envio? No mundo (UnitPosition, jardas, com altura: subir uma escada em espiral
-- conta) ~4 jd; sem ela, 0,3% do mapa. O intervalo mínimo entre envios continua valendo (schedule).
local MOVE_YARDS = 4
local MOVE_DEBOUNCE = 1   -- andar não vem em rajada como os eventos: espera menos que o DEBOUNCE
-- com o pulso ligado a posição vai pela faixa a cada segundo: andar só puxa um print (quests, bolsas…) a cada tanto.
-- Antes cada passo virava um print completo a cada intervalo, e o site remontava tudo (~1 MB) a cada poucos segundos.
local MOVE_PULSE_GAP = 60
local function worldPos()
    if not UnitPosition then return nil end
    local a, b, c = ns.safe(UnitPosition, "player")
    if type(a) ~= "number" or type(b) ~= "number" or (issecretvalue and (issecretvalue(a) or issecretvalue(b))) then return nil end
    return a, b, type(c) == "number" and not (issecretvalue and issecretvalue(c)) and c or 0
end
function Live.checkMovement()
    if not cfg or cfg.interval == 0 or InCombatLockdown() then return end
    local id, x, y = posKey()
    if not id then return end
    local a, b, c = worldPos()
    local moved
    if a and lastPos and lastPos[4] then
        moved = math.sqrt((lastPos[4] - a) ^ 2 + (lastPos[5] - b) ^ 2 + (lastPos[6] - c) ^ 2) > MOVE_YARDS
    else
        moved = not lastPos or math.abs(lastPos[2] - x) + math.abs(lastPos[3] - y) > 0.3
    end
    if not lastPos or lastPos[1] ~= id or moved then
        local changedMap = not lastPos or lastPos[1] ~= id
        lastPos = { id, x, y, a, b, c }
        if not changedMap and ns.Pulse and ns.Pulse.active() and time() - sched.last < MOVE_PULSE_GAP then return end
        schedule(MOVE_DEBOUNCE)
    end
end

-- jogador inimigo apareceu na tela (placa de nome): envio já (no intervalo normal, não no lento das placas); em
-- combate o print espera o fim do combate, como sempre
local function hostilePlayer(unit)
    return unit and UnitIsPlayer and UnitIsPlayer(unit) and UnitCanAttack and UnitCanAttack("player", unit)
end
Live.hostilePlayer = hostilePlayer

-- chamado pelo WowPilot.lua: chat novo, banco escaneado, inspeção de membro concluída, grupo
function Live.onDataChanged(reason)
    if cfg then schedule(DEBOUNCE, SLOW_REASONS[reason]) end
end

------------------------------------------------------------
-- Eventos e comando
------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        local db = ns.db()
        db.live = db.live or {}
        cfg = db.live
        cfg.mapsSent = nil
        cfg.sums = nil   -- entrou no jogo: manda tudo de novo no primeiro envio
        -- opções de versões antigas (canto, célula, cores… agora fixos)
        if cfg.interval == nil then cfg.interval = cfg.enabled == false and 0 or (cfg.throttle or DEFAULT_INTERVAL) end
        for _, k in ipairs({ "enabled", "throttle", "debounce", "corner", "cell", "colors", "gear", "gearThrottle" }) do
            cfg[k] = nil
        end
        for e in pairs(TRIGGERS) do pcall(ev.RegisterEvent, ev, e) end
        for _, e in ipairs({ "SCREENSHOT_SUCCEEDED", "SCREENSHOT_FAILED", "PLAYER_REGEN_ENABLED" }) do
            pcall(ev.RegisterEvent, ev, e)
        end
        -- dados de M+ chegam do servidor do jogo sob pedido
        for _, fn in ipairs({ "RequestMapInfo", "RequestRewards", "RequestCurrentAffixes" }) do
            if C_MythicPlus and C_MythicPlus[fn] then pcall(C_MythicPlus[fn]) end
        end
        schedule(8)  -- estado inicial (depois da inspeção do grupo, que começa em 3 s)
        if C_Timer and C_Timer.NewTicker and ns.GAME ~= "retail" then  -- mapa ao vivo no Forever
            C_Timer.NewTicker(1, function() pcall(Live.checkMovement) end)  -- 1 s: posição atualizada mais rápido
        end
        ns.say("carregado — envio " .. (cfg.interval == 0 and "só manual (/wpilot agora)"
            or ("automático, no máximo a cada " .. cfg.interval .. "s")) .. ". /wpilot para ajuda.")
    elseif event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED" then
        if busy and event == "SCREENSHOT_FAILED" then ns.say("Screenshot() falhou.") end
        finish(current)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if waitCombat then
            waitCombat = false
            pump()
            if sched.dirty then schedule(DEBOUNCE) end
        end
    elseif TRIGGERS[event] then
        if TRIGGERS[event] == "simc" then simcDirty = true end
        local slow = TRIGGERS[event] == "slow" and not (event == "NAME_PLATE_UNIT_ADDED" and hostilePlayer(arg1))
        if cfg then schedule(DEBOUNCE, slow) end
    end
end)

function Live.command(arg)
    local sub, val = (arg or ""):match("^(%S*)%s*(.-)$")
    sub = sub:lower()
    if sub == "api" then  -- diagnóstico: o que este cliente (retail/Forever) expõe
        local names = { "GetSpecialization", "GetNumTalentTabs", "GetTalentTabInfo", "GetUnspentTalentPoints",
                        "UnitCharacterPoints", "C_ClassTalents", "C_Traits", "C_SpecializationInfo", "C_SkillInfo",
                        "GetNumSkillLines", "C_QuestLog", "GetQuestLogTitle", "C_EncodingUtil", "RXPCData",
                        "RXPCTrackingData", "ForeverLevelingBiSDB" }
        local out = {}
        for _, n in ipairs(names) do out[#out + 1] = n .. "=" .. (_G[n] ~= nil and type(_G[n]) or "não") end
        ns.say("jogo " .. tostring(ns.GAME) .. " · build " .. tostring(select(4, GetBuildInfo())))
        print("  " .. table.concat(out, "  "))
        local SI = C_SkillInfo
        local s = SI and SI.GetSkillLineInfo and ns.safe(SI.GetSkillLineInfo, 2)
        if type(s) == "table" then
            local keys = {}
            for k in pairs(s) do keys[#keys + 1] = k end
            print("  C_SkillInfo campos: " .. table.concat(keys, ","))
        end
    elseif sub == "agora" then
        Live.capture("manual", true)
    elseif sub == "intervalo" and tonumber(val) then
        local n = math.floor(tonumber(val))
        cfg.interval = n <= 0 and 0 or math.max(MIN_INTERVAL, n)
        ns.say(cfg.interval == 0 and "envio automático desligado (use /wpilot agora)"
            or ("envio automático no máximo a cada " .. cfg.interval .. "s"))
        if cfg.interval > 0 then schedule(DEBOUNCE) end
    else
        ns.say(string.format("envio %s · último #%d %s", cfg.interval == 0 and "só manual"
            or ("a cada " .. cfg.interval .. "s (no máximo)"), cfg.seq or 0,
            sched.last > 0 and date("às %H:%M:%S", sched.last) or "(nenhum nesta sessão)"))
        print("  /wpilot agora          envia já (macro: /run WowPilot_Send())")
        print("  /wpilot intervalo N    segundos mínimos entre envios automáticos (padrão 30, mínimo 5; 0 = só manual)")
        print("  /wpilot pulso on|off   faixa no canto que leva a posição ao site a cada segundo, sem print")
        print("  /wpilot ajustes        configurações sugeridas do jogo (placas de nome) · /wpilot ajustes aplicar")
        print("  /wpilot vender IDs     com o vendedor aberto, vende esses itens (copie a lista na janela de bolsas do site)")
        print("  /wpilot api            lista o que o jogo oferece para addons (e o que vem protegido) · depois /reload")
        print("  /wpilot proteger IDs   itens que nunca vão ao vendedor (recompra se vender na mão) · /wpilot proteger nada limpa")
    end
end
