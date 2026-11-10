-- WowPilot — coleta os dados do personagem (resumo, equipamento, Vault, moedas, grupo, chat, desempenho).
-- O envio fica no WowPilotLive.lua: código de pixels no canto superior esquerdo + Screenshot(); o cliente
-- WowPilotSync.ps1 (Windows) lê o print, decodifica e manda para o site.
-- As SavedVariables guardam só o que precisa sobreviver ao /reload (chat ainda não enviado, sessões de grupo…).

local ADDON, ns = ...
ns = ns or {}

local db

-- WoW: Forever (Classic+, 11/2026) usa o cliente moderno com interface 16xxx; o retail é 12xxxx
local BUILD = select(4, GetBuildInfo()) or 0
local GAME = (BUILD >= 16000 and BUILD < 17000) and "forever" or (BUILD >= 100000 and "retail" or "classic")

local function say(msg) print("|cff33ccff[WowPilot]|r " .. msg) end

local function selfTarget()
    local name = UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function clean(v)
    v = tostring(v or "")
    return (v:gsub("[|;=:]", "_"))
end

------------------------------------------------------------
-- Coleta
------------------------------------------------------------
local function collect()
    local d = { t = time(), st = GetServerTime and GetServerTime() or 0, char = selfTarget(), game = GAME }
    local _, classTag = UnitClass("player")
    d.class = classTag
    local spec = GetSpecialization and GetSpecialization()
    if spec then
        local _, specName = GetSpecializationInfo(spec)
        d.spec = specName
    end
    if not d.spec and GAME ~= "retail" then d.spec = ns.talentSpec and ns.talentSpec() end
    d.lvl = UnitLevel("player")
    local overall, equipped = GetAverageItemLevel()
    d.ilvl = math.floor((equipped or 0) * 10 + 0.5) / 10
    d.ilvlmax = math.floor((overall or 0) * 10 + 0.5) / 10
    d.gold = math.floor((GetMoney() or 0) / 10000)
    -- Mítica+: chave e pontuação
    if C_MythicPlus then
        local kl = C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
        local km = C_MythicPlus.GetOwnedKeystoneChallengeMapID and C_MythicPlus.GetOwnedKeystoneChallengeMapID()
        if kl and km then
            local mapName = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(km)
            d.key = clean(mapName or km) .. "+" .. kl
        else
            d.key = "none"
        end
    end
    if C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore then
        d.rio = C_ChallengeMode.GetOverallDungeonScore() or 0
    end
    return d
end

------------------------------------------------------------
-- Coleta detalhada: itens equipados, bolsas, banco, moedas
------------------------------------------------------------
local SLOTS = {
    [1] = "head", [2] = "neck", [3] = "shoulder", [4] = "shirt", [5] = "chest",
    [6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands",
    [11] = "finger1", [12] = "finger2", [13] = "trinket1", [14] = "trinket2",
    [15] = "back", [16] = "mainhand", [17] = "offhand", [18] = "ranged", [19] = "tabard",  -- 18: só no Classic/Forever
}

local function packOk(ok, ...)
    if ok then return ... end
end
local function safe(fn, ...)
    return packOk(pcall(fn, ...))  -- devolve TODOS os retornos (GetItemInfo tem vários)
end

-- itemString: item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:mods:context:numBonus:bonus...
local function parseLink(link)
    local s = link and link:match("item:([%-%d:]+)")
    if not s then return { gems = {} } end  -- não é item (mascote, keystone...)
    local f, n = {}, 0
    for v in (s .. ":"):gmatch("([^:]*):") do
        n = n + 1
        f[n] = tonumber(v)  -- campos vazios viram nil, mas mantêm a posição
    end
    local out = { id = f[1], enchant = f[2], gems = {} }
    for i = 3, 6 do if f[i] then out.gems[#out.gems + 1] = f[i] end end
    local nb = f[13]
    if nb and nb > 0 then
        out.bonus = {}
        for i = 14, 13 + nb do if f[i] then out.bonus[#out.bonus + 1] = f[i] end end
    end
    return out
end

local function itemInfo(link, loc)
    local p = parseLink(link)
    local name, _, quality, _, _, itemType, subType, _, equipLoc = safe(C_Item.GetItemInfo, link)
    local it = {
        link = link, id = p.id, name = name, quality = quality,
        type = itemType, subtype = subType, equipLoc = equipLoc,
        enchant = (p.enchant and p.enchant > 0) and p.enchant or nil,
        gemIds = (#p.gems > 0) and p.gems or nil, bonus = p.bonus,
    }
    if loc and loc:IsValid() then
        it.ilvl = safe(C_Item.GetCurrentItemLevel, loc)
    end
    it.ilvl = it.ilvl or safe(C_Item.GetDetailedItemLevelInfo, link)
    local stats = safe(C_Item.GetItemStats, link)
    if stats and next(stats) then it.stats = stats end
    if it.gemIds then
        it.gems = {}
        for i = 1, 4 do
            local gname = safe(C_Item.GetItemGem, link, i)
            if gname then it.gems[#it.gems + 1] = gname end
        end
    end
    return it
end

local function collectBagIds(ids)
    local items = {}
    for _, bag in ipairs(ids) do
        local n = safe(C_Container.GetContainerNumSlots, bag) or 0
        for slot = 1, n do
            local info = safe(C_Container.GetContainerItemInfo, bag, slot)
            if info and info.hyperlink then
                local okI, it = pcall(itemInfo, info.hyperlink, ItemLocation:CreateFromBagAndSlot(bag, slot))
                if not okI then it = { link = info.hyperlink, err = tostring(it) } end
                it.bag, it.bagSlot = bag, slot
                it.count = info.stackCount
                it.bound = info.isBound or nil
                it.stats = nil  -- bolsa: só o essencial (stats ficam nos equipados)
                items[#items + 1] = it
            end
        end
    end
    return items
end

local function bagIds()
    local ids = {}
    for i = 0, (NUM_BAG_SLOTS or 4) + 1 do ids[#ids + 1] = i end  -- 0-4 + bolsa de reagentes (5)
    return ids
end

local function bankIds()
    local ids = { -1 }
    if Enum and Enum.BagIndex then
        for k, v in pairs(Enum.BagIndex) do
            if type(k) == "string" and k:find("^CharacterBankTab") then ids[#ids + 1] = v end
        end
    end
    for i = 6, 12 do ids[#ids + 1] = i end  -- bolsas de banco antigas, se existirem
    return ids
end

local function collectCurrencies()
    local cur = {}
    if not C_CurrencyInfo then return cur end
    -- expande todos os cabeçalhos (moedas dentro de grupos fechados não aparecem na lista)
    if C_CurrencyInfo.ExpandCurrencyList then
        local i = 1
        while i <= (C_CurrencyInfo.GetCurrencyListSize() or 0) and i < 1000 do
            local h = C_CurrencyInfo.GetCurrencyListInfo(i)
            if h and h.isHeader and not h.isHeaderExpanded then
                pcall(C_CurrencyInfo.ExpandCurrencyList, i, true)
            end
            i = i + 1
        end
    end
    local n = C_CurrencyInfo.GetCurrencyListSize() or 0
    for i = 1, n do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader then
            local link = C_CurrencyInfo.GetCurrencyListLink(i)
            local id = link and C_CurrencyInfo.GetCurrencyIDFromLink(link)
            local full = id and C_CurrencyInfo.GetCurrencyInfo(id)
            cur[#cur + 1] = {
                id = id, name = info.name, qty = info.quantity,
                max = full and full.maxQuantity or nil,
                weekly = full and full.quantityEarnedThisWeek or nil,
                weeklyMax = full and full.maxWeeklyQuantity or nil,
                totalEarned = full and full.totalEarned or nil,
                seasonMax = full and full.useTotalEarnedForMaxQty and full.maxQuantity or nil,
            }
        end
    end
    return cur
end

local function linkIlvl(link)
    return link and safe(C_Item.GetDetailedItemLevelInfo, link) or nil
end

local function collectVault()
    local out = {}
    if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return out end
    local WR = C_WeeklyRewards
    for _, a in ipairs(WR.GetActivities() or {}) do
        local v = { type = a.type, index = a.index, progress = a.progress,
                    threshold = a.threshold, level = a.level, id = a.id }
        -- item de exemplo da recompensa: ilvl atual e o do próximo nível de dificuldade
        if a.id and a.id > 0 and WR.GetExampleRewardItemHyperlinks then
            local link, upLink = safe(WR.GetExampleRewardItemHyperlinks, a.id)
            v.ilvl, v.upIlvl = linkIlvl(link), linkIlvl(upLink)
        end
        out[#out + 1] = v
    end
    return out
end

-- detalhes por linha do Vault: chefes de raide, progresso por nível (M+/mundo), recompensa a coletar
local function collectVaultDetail()
    local WR = C_WeeklyRewards
    if not WR then return nil end
    local d = { raid = {}, prog = {} }
    d.claim = WR.HasAvailableRewards and safe(WR.HasAvailableRewards) and 1 or 0
    local seen = {}
    for _, a in ipairs(WR.GetActivities and WR.GetActivities() or {}) do
        if a.type == 3 and not seen.raid and WR.GetActivityEncounterInfo then
            seen.raid = true
            for _, e in ipairs(safe(WR.GetActivityEncounterInfo, a.type, a.index) or {}) do
                local name = EJ_GetEncounterInfo and safe(EJ_GetEncounterInfo, e.encounterID)
                d.raid[#d.raid + 1] = { name or ("#" .. tostring(e.encounterID)), e.bestDifficulty or 0, e.uiOrder or 0 }
            end
            table.sort(d.raid, function(x, y) return x[3] < y[3] end)
        elseif a.type ~= 3 and not seen[a.type] and a.activityTierID and WR.GetSortedProgressForActivity then
            seen[a.type] = true
            local list = {}
            for _, p in ipairs(safe(WR.GetSortedProgressForActivity, a.type, a.activityTierID) or {}) do
                list[#list + 1] = { p.difficulty or 0, p.numPoints or 0 }
            end
            d.prog[tostring(a.type)] = list
        end
    end
    return d
end

------------------------------------------------------------
-- Grupo: inspeciona os membros (fora de combate, um por vez)
------------------------------------------------------------
local inspectQueue, inspecting = {}, nil
local INSPECT_GAP, INSPECT_TIMEOUT = 1.5, 4

local function unitFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    realm = (realm and realm ~= "") and realm or (GetNormalizedRealmName and GetNormalizedRealmName())
    return realm and (name .. "-" .. realm) or name
end

local function raiderIOScore(unit)
    if not (RaiderIO and RaiderIO.GetProfile) then return nil end
    local name, realm = UnitFullName(unit)
    local okR, prof = pcall(RaiderIO.GetProfile, name, realm)
    local mp = okR and prof and prof.mythicKeystoneProfile
    return mp and mp.currentScore or nil
end

local function groupUnits()
    local units = {}
    if IsInRaid() then  -- raide: raid1..raidN (inclui o próprio jogador, que fica de fora)
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 40) do
            local u = "raid" .. i
            if UnitExists(u) and UnitIsPlayer(u) and not UnitIsUnit(u, "player") then units[#units + 1] = u end
        end
        return units
    end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and UnitIsPlayer(u) then units[#units + 1] = u end
    end
    return units
end

local processInspect
local function queueGroupInspect()
    if not db then return end
    db.group = db.group or { members = {} }
    -- remove quem saiu do grupo
    local present = {}
    for _, u in ipairs(groupUnits()) do
        local guid = UnitGUID(u)
        if guid then
            present[guid] = true
            local m = db.group.members[guid]
            if not m or (time() - (m.inspectedAt or 0)) > 300 then
                inspectQueue[#inspectQueue + 1] = guid
            end
        end
    end
    for guid in pairs(db.group.members) do
        if not present[guid] then db.group.members[guid] = nil end
    end
    db.group.t = time()
    processInspect()
end

local function unitForGUID(guid)
    for _, u in ipairs(groupUnits()) do
        if UnitGUID(u) == guid then return u end
    end
end

processInspect = function()
    if inspecting or #inspectQueue == 0 then return end
    if InCombatLockdown() or (InspectFrame and InspectFrame:IsShown()) then return end
    local guid = table.remove(inspectQueue, 1)
    local unit = unitForGUID(guid)
    if not unit then return processInspect() end
    -- dados básicos mesmo se não der para inspecionar (longe/offline)
    local _, classTag = UnitClass(unit)
    db.group.members[guid] = db.group.members[guid] or {}
    local m = db.group.members[guid]
    m.name, m.class, m.role = unitFullName(unit), classTag, UnitGroupRolesAssigned(unit)
    m.level, m.rio = UnitLevel(unit), raiderIOScore(unit)
    if not CanInspect(unit) then
        m.inspectStatus = "fora de alcance"
        return C_Timer.After(0.1, processInspect)
    end
    inspecting = { guid = guid, unit = unit }
    NotifyInspect(unit)
    C_Timer.After(INSPECT_TIMEOUT, function()
        if inspecting and inspecting.guid == guid then
            m.inspectStatus = "sem resposta"
            inspecting = nil
            processInspect()
        end
    end)
end

local function onInspectReady(guid)
    if not inspecting or inspecting.guid ~= guid then return end
    local unit = inspecting.unit
    local m = db.group.members[guid]
    if m and UnitGUID(unit) == guid then
        local specID = GetInspectSpecialization and GetInspectSpecialization(unit)
        if specID and specID > 0 then
            local _, specName = GetSpecializationInfoByID(specID)
            m.spec = specName
        end
        m.ilvl = safe(C_PaperDollInfo.GetInspectItemLevel, unit)
        m.items = {}
        for slot, key in pairs(SLOTS) do
            local link = GetInventoryItemLink(unit, slot)
            if link then
                local okI, it = pcall(itemInfo, link, nil)
                if okI then
                    it.stats = nil
                    m.items[key] = it
                end
            end
        end
        m.inspectedAt = time()
        m.inspectStatus = "ok"
        local g = db.groups and db.groups[#db.groups]
        local gm = g and not g.stop and m.name and g.members[m.name]
        if gm then gm.spec, gm.ilvl, gm.rio = m.spec, m.ilvl, m.rio or gm.rio; ns.touchGroup(g) end
        if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("group") end
    end
    if ClearInspectPlayer then ClearInspectPlayer() end
    inspecting = nil
    C_Timer.After(INSPECT_GAP, processInspect)
end

local function scanBank()
    if not db then return end
    local char = selfTarget()
    db.bank = db.bank or {}
    db.bank[char] = { t = time(), items = collectBagIds(bankIds()) }
    say("Banco salvo (" .. #db.bank[char].items .. " itens).")
    if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("bank") end
end

------------------------------------------------------------
-- Chat: o WowPilotLive envia as mensagens novas; aqui fica só um buffer (sobrevive ao /reload)
------------------------------------------------------------
local CHAT_MAX = 300
local CHAT_EVENTS = {
    CHAT_MSG_WHISPER = "whisper_in",   CHAT_MSG_WHISPER_INFORM = "whisper_out",
    CHAT_MSG_BN_WHISPER = "bn_in",     CHAT_MSG_BN_WHISPER_INFORM = "bn_out",
    CHAT_MSG_PARTY = "party",          CHAT_MSG_PARTY_LEADER = "party",
    CHAT_MSG_RAID = "raid",            CHAT_MSG_RAID_LEADER = "raid", CHAT_MSG_RAID_WARNING = "raid",
    CHAT_MSG_INSTANCE_CHAT = "instance", CHAT_MSG_INSTANCE_CHAT_LEADER = "instance",
    CHAT_MSG_GUILD = "guild",          CHAT_MSG_OFFICER = "officer",
    CHAT_MSG_SAY = "say",              CHAT_MSG_YELL = "yell",
    CHAT_MSG_CHANNEL = "channel",      -- Comércio/Geral etc. (desligado por padrão)
}
local CHAT_OFF = { say = true, yell = true, channel = true }  -- canais públicos ficam de fora

local function isSecret(v)
    local fn = issecretvalue  -- API do Midnight (12.0+); resolvida na hora da chamada
    return fn ~= nil and fn(v) == true
end

local function plain(v)
    if v == nil or isSecret(v) then return nil end
    return tostring(v)
end

local function onChat(event, msg, author, _, channelName, _, _, _, _, _, _, lineID, _, bnID)
    if not db or not db.chat then return end
    local ch = CHAT_EVENTS[event]
    if not ch or CHAT_OFF[ch] then return end
    local text = plain(msg)
    if not text then return end                       -- conteúdo secreto (ex.: em combate) → ignora

    local from = plain(author)
    if (ch == "bn_in" or ch == "bn_out") and bnID and C_BattleNet and C_BattleNet.GetAccountInfoByID then
        local acc = safe(C_BattleNet.GetAccountInfoByID, bnID)
        if acc then from = acc.battleTag or acc.accountName or from end
    end

    local log = db.chat
    db.chatN = (db.chatN or 0) + 1  -- número crescente: o WowPilotLive envia só as mensagens novas
    log[#log + 1] = {
        n = db.chatN, t = time(), ch = ch, from = from, msg = text,
        chan = (ch == "channel") and plain(channelName) or nil,
        me = selfTarget(),
    }
    if #log > CHAT_MAX then table.remove(log, 1) end
    if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("chat") end
end

------------------------------------------------------------
-- Histórico de grupos: uma sessão por grupo formado (quem entrou/saiu e onde estiveram)
------------------------------------------------------------
local GROUPS_MAX = 30
local rosterResumed = false  -- 1ª leitura após login/reload: decide se o grupo salvo continua

-- revisão crescente: o WowPilotLive envia só as sessões com u maior que a última enviada
local function touchGroup(g)
    db.groupsRev = (db.groupsRev or 0) + 1
    g.u = db.groupsRev
end
ns.touchGroup = touchGroup

local function openGroup()
    local g = db.groups[#db.groups]
    if g and not g.stop then return g end
end

local function closeGroup(g, at)
    g.stop = at
    for _, m in pairs(g.members) do m.left = m.left or at end
    touchGroup(g)
    if not next(g.members) then table.remove(db.groups) end  -- grupo que nunca teve ninguém
end

local function trackPlace(g)
    local name, itype, _, diffName = GetInstanceInfo()
    if not g or not name or isSecret(name) or itype == "none" or itype == nil then return end
    local place = (diffName and diffName ~= "" and not isSecret(diffName)) and (name .. " (" .. diffName .. ")") or name
    for _, p in ipairs(g.places) do if p == place then return end end
    g.places[#g.places + 1] = place
    touchGroup(g)
end

local function trackRoster()
    if not db then return end
    local now = time()
    local g = openGroup()
    if not IsInGroup() then
        if g then closeGroup(g, rosterResumed and now or (g.seen or now)) end  -- após logout: acabou quando saiu do jogo
        rosterResumed = true
        if g and ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("groups") end
        return
    end
    local present = {}
    for _, u in ipairs(groupUnits()) do
        local name = unitFullName(u)
        if name and not isSecret(name) then present[name] = u end
    end
    if g and not rosterResumed then  -- voltou ao jogo em outro grupo → fecha o antigo
        local same = false
        for name, m in pairs(g.members) do if present[name] and not m.left then same = true end end
        if not same then closeGroup(g, g.seen or now); g = nil end
    end
    rosterResumed = true
    if not g then
        g = { id = now, start = now, members = {}, places = {} }
        db.groups[#db.groups + 1] = g
        while #db.groups > GROUPS_MAX do table.remove(db.groups, 1) end
    end
    g.raid = IsInRaid() or nil
    for name, u in pairs(present) do
        local m = g.members[name]
        if not m then
            m = { joined = now }
            g.members[name] = m
        end
        m.left = nil  -- (re)entrou
        local _, classTag = UnitClass(u)
        local role = UnitGroupRolesAssigned(u)
        m.class = classTag or m.class
        if role and role ~= "NONE" then m.role = role end
        m.rio = m.rio or raiderIOScore(u)
    end
    for name, m in pairs(g.members) do
        if not present[name] and not m.left then m.left = now end
    end
    trackPlace(g)
    g.seen = now
    touchGroup(g)
    if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("groups") end
end

-- Desempenho: medidor nativo do Midnight (C_DamageMeter, o mesmo que o Details! usa), sessão "Overall".
-- Lido só fora de combate (em combate os valores são secretos). Fica na sessão de grupo aberta.
local function meterRows(DM, sessionType, meterType, into, field)
    local s = safe(DM.GetCombatSessionFromType, sessionType, meterType)
    for _, src in ipairs(s and s.combatSources or {}) do
        local name, total, ps = src.name, src.totalAmount, src.amountPerSecond
        if name and not isSecret(name) and not isSecret(total) and not isSecret(ps) then
            if not name:find("-", 1, true) and GetNormalizedRealmName then name = name .. "-" .. GetNormalizedRealmName() end
            local r = into[name] or { 0, 0, 0, 0 }
            r[field] = r[field] + (total or 0)
            r[field + 2] = r[field + 2] + (ps or 0)
            into[name] = r
        end
    end
end

local function capturePerf()
    local DM, E = C_DamageMeter, Enum
    if not (db and DM and DM.GetCombatSessionFromType and IsInGroup()) or InCombatLockdown() then return end
    local g = openGroup()
    if not g then return end
    local ST = E and E.DamageMeterSessionType or {}
    local MT = E and E.DamageMeterType or {}
    local overall = ST.Overall or 0
    local by = {}  -- nome → { dano, cura+absorção, dps, hps }
    meterRows(DM, overall, MT.DamageDone or 0, by, 1)
    if MT.HealingDone then meterRows(DM, overall, MT.HealingDone, by, 2) end
    if MT.Absorbs then meterRows(DM, overall, MT.Absorbs, by, 2) end
    if not next(by) then return end
    g.perf = { t = time(), dur = DM.GetSessionDurationSeconds and safe(DM.GetSessionDurationSeconds, overall) or 0, by = by }
    touchGroup(g)
    if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("groups") end
end

local function onChallengeStart()
    local g = openGroup()
    local name = GetInstanceInfo()
    local lvl = C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo and safe(C_ChallengeMode.GetActiveKeystoneInfo)
    if not (g and name and lvl) or isSecret(name) then return end
    g.places[#g.places + 1] = name .. " +" .. lvl
    touchGroup(g)
end

------------------------------------------------------------
-- WoW: Forever (Classic+): sem spec por API; itens vão com nome e atributos.
-- Coleta o que importa para subir de nível: XP, zona, quests, talentos, profissões.
------------------------------------------------------------
local function isSecretValue(v)
    local fn = issecretvalue
    return fn ~= nil and fn(v) == true
end
local function num(v) if type(v) == "number" and not isSecretValue(v) then return v end end

-- árvore de talentos com mais pontos (GetTalentTabInfo muda de formato entre clientes: com ou sem id na frente)
local function talentTabs()
    local tabs = {}
    if not (GetNumTalentTabs and GetTalentTabInfo) then return tabs end
    for i = 1, (safe(GetNumTalentTabs) or 0) do
        local r = { safe(GetTalentTabInfo, i) }
        local name, pts
        if type(r[1]) == "string" then name, pts = r[1], r[3] else name, pts = r[2], r[5] end
        if type(name) == "string" then tabs[#tabs + 1] = { name, num(pts) or 0 } end
    end
    return tabs
end

-- spec escolhida no ForeverLevelingBiS (o Forever não tem API de spec): chave inglesa → nome em pt-BR
local FLB_SPECS = {
    arms = "Armas", fury = "Fúria", protection = "Proteção", holy = "Sagrado", retribution = "Retribuição",
    beastmastery = "Domínio das Feras", marksmanship = "Precisão", survival = "Sobrevivência",
    assassination = "Assassinato", combat = "Combate", subtlety = "Subterfúgio", discipline = "Disciplina",
    shadow = "Sombra", elemental = "Elemental", enhancement = "Aperfeiçoamento", restoration = "Restauração",
    arcane = "Arcano", fire = "Fogo", frost = "Gelo", affliction = "Suplício", demonology = "Demonologia",
    destruction = "Destruição", balance = "Equilíbrio", feral = "Combate Feral", guardian = "Guardião",
    tank = "Proteção", bear = "Guardião", cat = "Combate Feral",
}
local function flbSpec()
    local d = ForeverLevelingBiSDB
    if type(d) ~= "table" or type(d.chars) ~= "table" then return nil end
    local realm = GetRealmName and GetRealmName() or ""
    local c = d.chars[UnitName("player") .. "-" .. realm]
    if not c then  -- a chave deles usa o nome do reino com espaços; procura pelo nome do personagem
        for k, v in pairs(d.chars) do
            if type(k) == "string" and k:sub(1, #UnitName("player") + 1) == UnitName("player") .. "-" then c = v; break end
        end
    end
    local key = c and type(c.spec) == "string" and c.spec:lower() or nil
    return key and (FLB_SPECS[key] or key) or nil
end

function ns.talentSpec()
    local best
    for _, t in ipairs(talentTabs()) do
        if t[2] > 0 and (not best or t[2] > best[2]) then best = t end
    end
    return best and best[1] or flbSpec()
end

local function questLog()
    local out = {}
    local QL = C_QuestLog
    if QL and QL.GetNumQuestLogEntries and QL.GetInfo then
        for i = 1, (safe(QL.GetNumQuestLogEntries) or 0) do
            local q = safe(QL.GetInfo, i)
            if q and not q.isHeader and q.questID and q.questID > 0 then
                local obj = {}
                for _, o in ipairs(QL.GetQuestObjectives and safe(QL.GetQuestObjectives, q.questID) or {}) do
                    obj[#obj + 1] = { o.text or "", o.finished and 1 or 0 }
                end
                local done = q.isComplete
                if done == nil and QL.IsComplete then done = safe(QL.IsComplete, q.questID) end
                out[#out + 1] = { q.questID, q.title or "", q.level or 0, done and 1 or 0, obj }
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then  -- API clássica
        for i = 1, (safe(GetNumQuestLogEntries) or 0) do
            local title, level, _, isHeader, _, isComplete, _, questID = safe(GetQuestLogTitle, i)
            if title and not isHeader then
                local obj = {}
                for k = 1, (GetNumQuestLeaderBoards and safe(GetNumQuestLeaderBoards, i) or 0) do
                    local text, _, finished = safe(GetQuestLogLeaderBoard, k, i)
                    obj[#obj + 1] = { text or "", finished and 1 or 0 }
                end
                out[#out + 1] = { questID or 0, title, level or 0, (isComplete == 1 or isComplete == true) and 1 or 0, obj }
            end
        end
    end
    return out
end

local function skills()
    local out = {}
    local SI = C_SkillInfo  -- o Forever trocou as globais por C_SkillInfo (mesma checagem do Questie)
    if SI and SI.GetNumSkillLines and SI.GetSkillLineInfo then
        for i = 1, (safe(SI.GetNumSkillLines) or 0) do
            local s = safe(SI.GetSkillLineInfo, i)
            if type(s) == "table" and not s.isHeader and s.name then
                local rank = num(s.rank) or num(s.skillRank) or 0
                local mod = num(s.modifier) or num(s.skillModifier) or num(s.tempPoints) or 0
                local max = num(s.maxRank) or num(s.skillMaxRank) or num(s.max) or 0
                if max > 1 or rank > 1 then out[#out + 1] = { s.name, rank + mod, max } end
            end
        end
        return out
    end
    if not (GetNumSkillLines and GetSkillLineInfo) then return out end
    for i = 1, (safe(GetNumSkillLines) or 0) do
        local name, isHeader, _, rank, _, mod, maxRank = safe(GetSkillLineInfo, i)
        if name and not isHeader and (maxRank or 0) > 1 then
            out[#out + 1] = { name, (rank or 0) + (mod or 0), maxRank or 0 }
        end
    end
    return out
end

local function position()
    local mapID = C_Map and C_Map.GetBestMapForUnit and safe(C_Map.GetBestMapForUnit, "player")
    if not num(mapID) then return nil end
    local pos = C_Map.GetPlayerMapPosition and safe(C_Map.GetPlayerMapPosition, mapID, "player")
    local x, y
    if pos and pos.GetXY then x, y = safe(pos.GetXY, pos) end
    local info = C_Map.GetMapInfo and safe(C_Map.GetMapInfo, mapID)
    -- % do mapa com 2 casas (~1 jd; com 1 casa eram ~10 jd numa zona inteira) + posição no mundo com a altura
    -- (UnitPosition: os 3 valores crus; nil em instância)
    local out = { mapID, info and info.name or "", num(x) and math.floor(x * 10000 + 0.5) / 100 or 0,
                  num(y) and math.floor(y * 10000 + 0.5) / 100 or 0 }
    if UnitPosition then
        local a, b, c = safe(UnitPosition, "player")
        if num(a) and num(b) then
            out[5], out[6], out[7] = math.floor(a * 10 + 0.5) / 10, math.floor(b * 10 + 0.5) / 10, num(c) and math.floor(c * 10 + 0.5) / 10 or 0
        end
    end
    return out
end

-- tempo jogado: TIME_PLAYED_MSG (pedido 1x no login; o RXP também pede) + o que passou desde então
local played = nil  -- { total, level, at = GetTime() }
function ns.onTimePlayed(total, level)
    if num(total) then played = { total = total, level = num(level) or 0, at = GetTime() } end
end

local function playedNow()
    if not played then return nil end
    local d = GetTime() - played.at
    return { math.floor(played.total + d), math.floor(played.level + d) }
end

local function durability()
    local minPct, sum, n = nil, 0, 0
    for slot = 1, 18 do
        local cur, max = safe(GetInventoryItemDurability, slot)
        if num(cur) and num(max) and max > 0 then
            local pct = cur / max
            minPct = math.min(minPct or 1, pct)
            sum, n = sum + pct, n + 1
        end
    end
    if n == 0 then return nil end
    return { math.floor(minPct * 100 + 0.5), math.floor(sum / n * 100 + 0.5) }
end

local function freeSlots()
    local free, total = 0, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        free = free + (num(safe(C_Container.GetContainerNumFreeSlots, bag)) or 0)
        total = total + (num(safe(C_Container.GetContainerNumSlots, bag)) or 0)
    end
    return { free, total }
end

local HEARTHSTONE = 6948
local function hearthCooldown()
    local fn = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    if not fn then return nil end
    local start, dur = safe(fn, HEARTHSTONE)
    if not (num(start) and num(dur)) then return nil end
    if start == 0 or dur == 0 then return 0 end
    return math.max(0, math.floor(start + dur - GetTime()))
end

-- RestedXP (RXPGuides): guia/passo atuais e o histórico por nível do rastreador deles
local function rxp()
    local c = RXPCData
    if type(c) ~= "table" then return nil end
    local out = { guide = c.currentGuideName, group = c.currentGuideGroup, step = num(c.currentStep), levels = {} }
    local tr = RXPCTrackingData
    if type(tr) == "table" and type(tr.profiles) == "table" then
        local key = tr.profileKeys and (tr.profileKeys[UnitName("player") .. " - " .. (GetRealmName and GetRealmName() or "")])
        local prof = key and tr.profiles[key]
        if not prof then for _, p in pairs(tr.profiles) do prof = p; break end end
        for lvl, l in pairs(prof and prof.levels or {}) do
            if type(lvl) == "number" and type(l) == "table" then
                local mobXp, mobN, qXp, qN = 0, 0, 0, 0
                for _, z in pairs(l.mobs or {}) do mobXp, mobN = mobXp + (z.xp or 0), mobN + (z.count or 0) end
                for _, z in pairs(l.quests or {}) do for _, xp in pairs(z) do qXp, qN = qXp + (tonumber(xp) or 0), qN + 1 end end
                local ts = l.timestamp or {}
                out.levels[#out.levels + 1] = { lvl, ts.started or 0, ts.finished or 0, l.deaths or 0,
                                                mobXp, mobN, qXp, qN, l.groupExperience or 0 }
            end
        end
        table.sort(out.levels, function(a, b) return a[1] < b[1] end)
    end
    return out
end

-- detalhes dos itens vistos (equipados, bolsas, banco)
--   {["id"] = {nome, qualidade, venda (cobre), nível mín., classID, subclassID, equipLoc, ilvl, {atributos}}}
function ns.itemDetails()
    local links = {}
    local function add(link)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id and not links[id] then links[id] = link end
    end
    for slot in pairs(SLOTS) do add(GetInventoryItemLink("player", slot)) end
    for _, bag in ipairs(bagIds()) do
        for slot = 1, (safe(C_Container.GetContainerNumSlots, bag) or 0) do
            local info = safe(C_Container.GetContainerItemInfo, bag, slot)
            add(info and info.hyperlink)
        end
    end
    local b = db and db.bank and db.bank[selfTarget()]
    for _, it in ipairs(b and b.items or {}) do add(it.link) end
    local statsFn = (C_Item and C_Item.GetItemStats) or GetItemStats
    local out = {}
    for id, link in pairs(links) do
        local name, _, quality, ilvl, minLevel, _, _, _, equipLoc, _, sell, classID, subclassID = safe(C_Item.GetItemInfo, link)
        if name then
            local e = { name, quality or 0, sell or 0, minLevel or 0, classID or -1, subclassID or -1, equipLoc or "", ilvl or 0 }
            if equipLoc and equipLoc ~= "" and statsFn then
                local st = safe(statsFn, link)
                if st and next(st) then e[9] = st end
            end
            out[tostring(id)] = e
        end
    end
    return next(out) and out or nil
end

-- quests já entregues: lista de ids ordenada
local function completedQuests()
    local ids = {}
    local QL = C_QuestLog
    if QL and QL.GetAllCompletedQuestIDs then
        ids = safe(QL.GetAllCompletedQuestIDs) or {}
    elseif GetQuestsCompleted then
        local t = safe(GetQuestsCompleted) or {}
        for id, done in pairs(t) do if done then ids[#ids + 1] = id end end
    end
    local out = {}
    for _, id in ipairs(ids) do if num(id) then out[#out + 1] = id end end
    table.sort(out)
    return out
end
ns.completedQuests = completedQuests

-- nomes dos mapas (continentes e zonas) no idioma do cliente
function ns.mapNames()
    if not (C_Map and C_Map.GetMapChildrenInfo) then return nil end
    local out = {}
    for _, m in ipairs(safe(C_Map.GetMapChildrenInfo, 947, nil, true) or {}) do
        if m.mapID and m.name and (m.mapType or 9) <= 4 then out[tostring(m.mapID)] = m.name end
    end
    return next(out) and out or nil
end

-- modelo do alvo: um PlayerModel escondido recebe SetUnit("target") ao trocar de alvo; o display sai de GetDisplayInfo()
local targetModel
function ns.onTargetChanged()
    if not CreateFrame then return end
    if not targetModel then
        local ok, m = pcall(CreateFrame, "PlayerModel", nil, UIParent)
        if not ok or not m then return end
        targetModel = m
        m:SetSize(1, 1)
        m:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -50, 50)  -- fora da tela
        m:SetAlpha(0)
        m:Show()
    end
    if UnitExists("target") then pcall(targetModel.SetUnit, targetModel, "target") else pcall(targetModel.ClearModel, targetModel) end
end

local function targetDisplay()
    if not (targetModel and targetModel.GetDisplayInfo) then return nil end
    return num(safe(targetModel.GetDisplayInfo, targetModel))
end

-- alvo atual: id do NPC (do GUID "Creature-0-…-<id>-…"), nome, nível, vida %, reação; jogador = só nome/classe
local function target()
    if not UnitExists("target") then return nil end
    local guid = UnitGUID("target")
    if not guid or isSecretValue(guid) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    local t = { kind = kind, id = tonumber(id), name = UnitName("target"), level = num(UnitLevel("target")),
                dead = UnitIsDead("target") and 1 or 0, reaction = num(UnitReaction("target", "player")),
                class = UnitClassification and UnitClassification("target") or nil }
    if isSecretValue(t.name) then t.name = nil end
    local hp, hpMax = num(UnitHealth("target")), num(UnitHealthMax("target"))
    if hp and hpMax and hpMax > 0 then t.hp = math.floor(hp / hpMax * 100 + 0.5) end
    if kind == "Player" then t.id, t.class = nil, select(2, UnitClass("target")) end
    local d = targetDisplay()
    if d and d > 0 then t.display = d end
    return t
end

-- NPCs visíveis agora (placas de nome): o jogo não dá posição de NPC a addons, só quem está perto e na tela
--   [[id, nível, vida %, morto, reação, classificação], ...] (máx. 40; repetidos do mesmo id juntos com contagem)
local function visibleNpcs()
    local NP = C_NamePlate
    if not (NP and NP.GetNamePlates) then return nil end
    local out, seen = {}, {}
    for _, plate in ipairs(safe(NP.GetNamePlates) or {}) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local guid = unit and UnitGUID(unit)
        if guid and not isSecretValue(guid) then
            local kind, _, _, _, _, id = strsplit("-", guid)
            id = tonumber(id)
            if (kind == "Creature" or kind == "Vehicle") and id then
                local hp, hpMax = num(UnitHealth(unit)), num(UnitHealthMax(unit))
                local key = id .. (UnitIsDead(unit) and "d" or "")
                if seen[key] then
                    seen[key][7] = seen[key][7] + 1
                elseif #out < 40 then
                    local row = { id, num(UnitLevel(unit)) or 0, (hp and hpMax and hpMax > 0) and math.floor(hp / hpMax * 100 + 0.5) or -1,
                                  UnitIsDead(unit) and 1 or 0, num(UnitReaction(unit, "player")) or 0,
                                  (UnitClassification and UnitClassification(unit)) or "", 1 }
                    seen[key] = row
                    out[#out + 1] = row
                end
            end
        end
    end
    return #out > 0 and out or nil
end

-- texto de passo do RestedXP sem códigos de cor/ícone/link
local function plainText(s)
    s = tostring(s or "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cRXP_%u+_", ""):gsub("|r", ""):gsub("|T.-|t", "")
    s = s:gsub("|H.-|h", ""):gsub("|h", ""):gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$")
end

local NULL = 0 / 0   -- vira null no JSON: guarda a posição numa lista sem deslocar os itens seguintes

-- próximos passos do guia do RestedXP (o addon deles é global: RXP = addon), já filtrados para o personagem:
--   [[índice, ativo, texto, [[uiMap, x, y, seta], ...]], ...] (máx. 30 passos), na ordem em que o RXP desenha os pinos:
--   1º os passos ativos (inclui os "grudados" de antes do atual, ex. "#completewith": entrar na cidade), depois os
--   seguintes. Pula o que o RXP já não mostra: passo concluído, ponto pulado/alcançado (element.skip,
--   RXPCData.completedWaypoints) ou com o pai concluído. seta = 1 no ponto para onde a seta do RXP aponta agora.
local function rxpPath()
    local A = RXP
    local guide = type(A) == "table" and A.currentGuide
    if type(guide) ~= "table" or type(guide.steps) ~= "table" then return nil end
    local cur = tonumber(RXPCData and RXPCData.currentStep) or 1
    local done = RXPCData and type(RXPCData.completedWaypoints) == "table" and RXPCData.completedWaypoints or {}
    local arrow = type(A.arrowFrame) == "table" and A.arrowFrame.element or nil
    local order, seen = {}, {}
    local function add(step)
        if type(step) == "table" and not seen[step] then seen[step] = true; order[#order + 1] = step end
    end
    local act = {}
    for _, step in pairs(type(A.RXPFrame) == "table" and type(A.RXPFrame.activeSteps) == "table" and A.RXPFrame.activeSteps or {}) do
        if type(step) == "table" and step.index then act[#act + 1] = step end
    end
    table.sort(act, function(a, b) return a.index < b.index end)
    for _, step in ipairs(act) do add(step) end
    for i = cur, math.min(#guide.steps, cur + 40) do
        local step = guide.steps[i]
        if type(step) == "table" and (i == cur or not step.completed) then add(step) end
    end
    local out = {}
    for _, step in ipairs(order) do
        local idx = step.index or 0
        local wps = done[idx] or {}
        local pts, text = {}, nil
        for _, el in ipairs(step.elements or {}) do
            if type(el) == "table" then
                local gone = el.skip or (el.wpHash and wps[el.wpHash])
                    or (type(el.parent) == "table" and (el.parent.completed or el.parent.skip))
                if el.zone and el.x and el.y and not el.hidePin and not gone and #pts < 8 then
                    pts[#pts + 1] = { el.zone, math.floor(el.x * 100 + 0.5) / 100, math.floor(el.y * 100 + 0.5) / 100,
                                      el == arrow and 1 or nil }
                end
                if not text and type(el.text) == "string" and el.text ~= "" then text = plainText(el.text) end
            end
        end
        if #pts > 0 or (text and step.active) then
            out[#out + 1] = { idx, step.active and 1 or 0, (text or ""):sub(1, 110), pts }
        end
        if #out >= 30 then break end
    end
    local res = { guide = guide.name, cur = cur, total = #guide.steps, steps = out }
    -- para onde a seta aponta, mesmo que o ponto não esteja na lista acima: a seta do RXP também usa pontos gerados
    -- (.line/.mob) que não ficam em step.elements. [passo, uiMap, x, y, motivo]; motivo = por que não está na
    -- lista: "fora" (não é elemento do passo), "skip", "feito" (completedWaypoints), "pai" (pai concluído), "pin"
    -- (hidePin); sem motivo = está na lista. Seta escondida ou sem coordenada de mapa: não manda.
    local af = A.arrowFrame
    local shown = type(af) == "table" and type(af.IsShown) == "function" and select(2, pcall(af.IsShown, af))
    if arrow and shown and type(arrow) == "table" and num(arrow.zone) and num(arrow.x) and num(arrow.y) then
        local owner = type(arrow.step) == "table" and arrow.step or nil
        local member = false
        for _, step in ipairs(guide.steps) do
            for _, el in ipairs(type(step) == "table" and step.elements or {}) do
                if el == arrow then owner, member = owner or step, true; break end
            end
            if member then break end
        end
        local why
        if not member then why = "fora"
        elseif arrow.skip then why = "skip"
        elseif arrow.wpHash and owner and (done[owner.index or 0] or {})[arrow.wpHash] then why = "feito"
        elseif type(arrow.parent) == "table" and (arrow.parent.completed or arrow.parent.skip) then why = "pai"
        elseif arrow.hidePin then why = "pin" end
        res.arrow = { owner and owner.index or NULL, arrow.zone, math.floor(arrow.x * 100 + 0.5) / 100,
                      math.floor(arrow.y * 100 + 0.5) / 100, why }
    end
    return res
end


local function pct(a, b)
    a, b = num(a), num(b)
    if a and b and b > 0 then return math.floor(a * 100 / b + 0.5) end
end

-- ficha do jogador: vida, recurso da classe (e a mana do druida em forma), atributos e armadura efetivos
local function sheet()
    local me = {}
    local hp, hpMax = num(UnitHealth and UnitHealth("player")), num(UnitHealthMax and UnitHealthMax("player"))
    if hp and hpMax then me.hp = { hp, hpMax } end
    if UnitPowerType and UnitPower and UnitPowerMax then
        local ptype, token = UnitPowerType("player")
        local pw, pwMax = num(UnitPower("player")), num(UnitPowerMax("player"))
        if pw and pwMax then me.pw = { pw, pwMax, type(token) == "string" and token or nil } end
        if num(ptype) ~= 0 then   -- recurso atual não é mana: mostra a mana se a classe tiver (druida em forma)
            local m, mMax = num(UnitPower("player", 0)), num(UnitPowerMax("player", 0))
            if m and mMax and mMax > 0 then me.mana = { m, mMax } end
        end
    end
    if UnitStat then
        local st = {}
        for i = 1, 5 do   -- força, agilidade, vigor, intelecto, espírito (2º retorno = valor efetivo)
            local ok, _, v = pcall(UnitStat, "player", i)
            st[i] = ok and num(v) or NULL
        end
        me.st = st
    end
    if UnitArmor then
        local ok, _, eff = pcall(UnitArmor, "player")
        if ok and num(eff) then me.armor = eff end
    end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then me.dead = 1 end
    return me
end

-- voos aprendidos (ids do TaxiNodes): o jogo só lista os pontos de voo conhecidos com o mapa de voo aberto, então
-- guarda por personagem a cada visita a um mestre de voo (um continente por vez: soma ao que já tinha)
local function scanTaxi()
    if not (db and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID) then return end
    local nodes = safe(C_TaxiMap.GetAllTaxiNodes, safe(GetTaxiMapID))
    if type(nodes) ~= "table" then return end
    db.taxi = db.taxi or {}
    local me = selfTarget()
    local known, added = db.taxi[me] or {}, false
    for _, n in ipairs(nodes) do
        local id = num(n.nodeID)
        if id and not known[id] then known[id], added = true, true end
    end
    db.taxi[me] = known
    if added and ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("taxi") end
end

local function taxiList()
    local known = db and db.taxi and db.taxi[selfTarget()]
    if not known then return nil end
    local out = {}
    for id in pairs(known) do out[#out + 1] = id end
    table.sort(out)
    return #out > 0 and out or nil
end

-- outras posições que o jogo dá a addons: direção, corpo, alfinete do mapa, grupo, POIs de quest do próprio jogo
local function extras()
    local M = C_Map
    local mapID = M and M.GetBestMapForUnit and safe(M.GetBestMapForUnit, "player")
    local out = {}
    local okMe, me = pcall(sheet)
    if okMe and next(me) then out.me = me end
    local f = GetPlayerFacing and num(safe(GetPlayerFacing))
    if f then out.facing = math.floor(f * 1000 + 0.5) / 1000 end
    if mapID and UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") and C_DeathInfo and C_DeathInfo.GetCorpseMapPosition then
        local p = safe(C_DeathInfo.GetCorpseMapPosition, mapID)
        if p and p.GetXY then local x, y = p:GetXY(); out.corpse = { mapID, num(x) and x * 100, num(y) and y * 100 } end
    end
    if M and M.HasUserWaypoint and safe(M.HasUserWaypoint) then
        local wp = safe(M.GetUserWaypoint)
        if wp and wp.uiMapID and wp.position then
            local x, y = wp.position:GetXY()
            out.pin = { wp.uiMapID, num(x) and x * 100, num(y) and y * 100 }
        end
    end
    if mapID and IsInGroup and IsInGroup() then
        -- grupo (party1..4) ou raide (raid1..40, sem você; com o subgrupo de cada um)
        local party, raid = {}, IsInRaid and IsInRaid()
        local n = raid and math.min(GetNumGroupMembers and GetNumGroupMembers() or 40, 40) or 4
        for i = 1, n do
            local u = (raid and "raid" or "party") .. i
            if UnitExists(u) and not (raid and UnitIsUnit and UnitIsUnit(u, "player")) then
                local p = safe(M.GetPlayerMapPosition, mapID, u)
                local x, y
                if p and p.GetXY then x, y = p:GetXY() end
                local _, cls = UnitClass(u)
                -- vida e recurso em % (null se o jogo não informa, ex.: longe demais)
                local hpP = pct(UnitHealth and UnitHealth(u), UnitHealthMax and UnitHealthMax(u))
                local pwP = UnitPower and pct(UnitPower(u), UnitPowerMax(u))
                local token
                if UnitPowerType then token = select(2, UnitPowerType(u)) end
                local sub
                if raid and GetRaidRosterInfo then sub = num(select(3, GetRaidRosterInfo(i))) end
                party[#party + 1] = { UnitName(u), cls, num(x) and x * 100 or -1, num(y) and y * 100 or -1,
                                      hpP or NULL, pwP or NULL, type(token) == "string" and token or NULL, sub or NULL }
            end
        end
        if #party > 0 then out.party = party end
    end
    if mapID and C_QuestLog and C_QuestLog.GetQuestsOnMap then
        local poi = {}
        for _, q in ipairs(safe(C_QuestLog.GetQuestsOnMap, mapID) or {}) do
            if q.questID and num(q.x) and num(q.y) then poi[#poi + 1] = { q.questID, q.x * 100, q.y * 100 } end
        end
        if #poi > 0 then out.poi = poi end
    end
    out.taxi = taxiList()
    return out
end

-- payload "fv": tudo opcional; cada parte isolada para um erro não derrubar as outras
function ns.collectForever()
    local function part(fn, ...) local ok, r = pcall(fn, ...); if ok then return r end end
    local d = {
        xp = num(UnitXP("player")), xpMax = num(UnitXPMax("player")),
        rested = GetXPExhaustion and num(GetXPExhaustion()) or 0,
        zone = GetRealZoneText and GetRealZoneText() or nil,
        subzone = GetSubZoneText and GetSubZoneText() or nil,
        bind = GetBindLocation and GetBindLocation() or nil,
        talents = part(talentTabs),
        free = (GetUnspentTalentPoints and num((safe(GetUnspentTalentPoints))))
            or (UnitCharacterPoints and num((safe(UnitCharacterPoints, "player")))) or nil,
        quests = part(questLog), skills = part(skills), pos = part(position),
        played = part(playedNow), dur = part(durability), bagFree = part(freeSlots), hearth = part(hearthCooldown),
        resting = IsResting and IsResting() and 1 or 0, money = num(GetMoney()), rxp = part(rxp),
        deaths = db and db.deaths and db.deaths[selfTarget()] or 0,
        faction = UnitFactionGroup and (UnitFactionGroup("player")) or nil,
        race = select(3, UnitRace("player")), classId = select(3, UnitClass("player")),
        target = part(target), near = part(visibleNpcs), path = part(rxpPath), ex = part(extras),
    }
    for _, k in ipairs({ "zone", "subzone", "bind" }) do
        if d[k] == "" or isSecretValue(d[k]) then d[k] = nil end
    end
    return d
end
ns.GAME = GAME

------------------------------------------------------------
-- Eventos
------------------------------------------------------------
local OBSOLETE = { "last", "history", "chars", "syncSeq", "button", "hideButton", "currencies", "chatChannels",
                   "autoCombatLog", "seq", "auto", "hide", "chatlog" }  -- chaves de versões antigas (≤ 0.9)

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        WowPilotDB = WowPilotDB or {}
        db = WowPilotDB
        for _, k in ipairs(OBSOLETE) do db[k] = nil end
        db.chat = db.chat or {}
        while #db.chat > CHAT_MAX do table.remove(db.chat, 1) end
        db.groups = db.groups or {}
        while #db.groups > GROUPS_MAX do table.remove(db.groups, 1) end
        for ev in pairs(CHAT_EVENTS) do pcall(f.RegisterEvent, f, ev) end

    elseif event == "PLAYER_LOGIN" then
        for _, ev in ipairs({ "PLAYER_REGEN_ENABLED", "BANKFRAME_OPENED", "GROUP_ROSTER_UPDATE", "INSPECT_READY",
                              "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CHALLENGE_MODE_START",
                              "PLAYER_LOGOUT", "CHALLENGE_MODE_COMPLETED", "TIME_PLAYED_MSG", "PLAYER_DEAD",
                              "PLAYER_TARGET_CHANGED", "TAXIMAP_OPENED" }) do
            pcall(f.RegisterEvent, f, ev)
        end
        if GAME ~= "retail" and RequestTimePlayed then
            C_Timer.After(6, function() if not played then pcall(RequestTimePlayed) end end)
        end
        C_Timer.After(3, queueGroupInspect)  -- após /reload o evento de grupo não dispara
        C_Timer.After(3, trackRoster)

    elseif CHAT_EVENTS[event] then
        onChat(event, arg1, ...)

    elseif event == "BANKFRAME_OPENED" then
        C_Timer.After(0.5, scanBank)  -- dá tempo do banco popular

    elseif event == "GROUP_ROSTER_UPDATE" then
        trackRoster()
        C_Timer.After(2, queueGroupInspect)

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local g = db and openGroup()
        if g and IsInGroup() then trackPlace(g) end

    elseif event == "CHALLENGE_MODE_START" then
        onChallengeStart()

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        C_Timer.After(2, capturePerf)

    elseif event == "PLAYER_LOGOUT" then  -- logout e /reload: marca até quando o grupo foi visto
        local g = db and openGroup()
        if g then g.seen = time() end

    elseif event == "PLAYER_TARGET_CHANGED" then
        pcall(ns.onTargetChanged)

    elseif event == "TAXIMAP_OPENED" then
        pcall(scanTaxi)

    elseif event == "TIME_PLAYED_MSG" then
        ns.onTimePlayed(arg1, ...)

    elseif event == "PLAYER_DEAD" then  -- mortes por personagem (o rastreador do RXP conta por nível)
        local me = selfTarget()
        db.deaths = db.deaths or {}
        db.deaths[me] = (db.deaths[me] or 0) + 1
        if ns.Live and ns.Live.onDataChanged then ns.Live.onDataChanged("death") end

    elseif event == "INSPECT_READY" then
        onInspectReady(arg1)

    elseif event == "PLAYER_REGEN_ENABLED" then
        C_Timer.After(1, capturePerf)
        processInspect()  -- retoma inspeções pausadas pelo combate
    end
end)

-- exportado para o WowPilotLive.lua
ns.db = function() return db end
ns.say, ns.safe, ns.collect, ns.selfTarget = say, safe, collect, selfTarget
ns.collectCurrencies, ns.parseLink, ns.SLOTS = collectCurrencies, parseLink, SLOTS
ns.capturePerf = capturePerf
ns.collectVault, ns.collectVaultDetail, ns.bagIds = collectVault, collectVaultDetail, bagIds

------------------------------------------------------------
-- Comando: /wpilot (status), /wpilot agora, /wpilot intervalo N — o resto é automático
------------------------------------------------------------
SLASH_WOWPILOT1 = "/wpilot"
SLASH_WOWPILOT2 = "/wowpilot"
SlashCmdList.WOWPILOT = function(input)
    local sub, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    if sub and sub:lower() == "pulso" and ns.Pulse then return ns.Pulse.command(rest:lower()) end
    ns.Live.command(input or "")
end
