-- Stub mínimo da API do WoW (Midnight 12.1) para rodar o WowPilot fora do jogo.
-- Carregado por tests/run_tests.py antes do addon. Os testes podem sobrescrever
-- qualquer função global depois (o addon resolve as APIs na hora da chamada).
--
-- Links "reais" copiados de um snapshot do jogo (campos vazios entre ':' são normais).

LINK_PLAIN   = "|cffa335ee|Hitem:251148::::::::90:262::2:5:12820:13438:6652:13668:12698:1:28:3024:::::|h[Elo]|h|r"
LINK_ENCHANT = "|cffa335ee|Hitem:271483:7534:240910::::::90:264::3:2:111:222|h[Crown]|h|r"
LINK_PET     = "|cff0070dd|Hbattlepet:1234:25:3:1500:300:300:0x0|h[Pet]|h|r"

_G.time, _G.date = os.time, os.date
NOW = 1000
_G.GetTime = function() NOW = NOW + 2; return NOW end  -- avança a cada chamada (testes não esperam)
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end end
PRINTED = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    PRINTED[#PRINTED + 1] = table.concat(parts, " ")
end

-- versão do cliente: STUB_BUILD (definido antes de carregar o addon) troca retail ↔ Forever
_G.GetBuildInfo = function() return "x", "1", "Nov 1 2026", STUB_BUILD or 120105 end

-- strsplit do WoW (separador de 1 caractere)
_G.strsplit = function(sep, s)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)%" .. sep) do out[#out + 1] = piece end
    return (table.unpack or unpack)(out)
end

-- personagem
_G.UnitName = function() return "Fulano" end
_G.GetNormalizedRealmName = function() return "Reinoteste" end
_G.UnitClass = function() return "Xamã", "SHAMAN" end
_G.GetSpecialization = function() return 3 end
_G.GetSpecializationInfo = function() return 264, "Restauração" end
_G.UnitLevel = function() return 90 end
_G.GetAverageItemLevel = function() return 277.1, 274.2 end
_G.GetMoney = function() return 376640000 end
_G.GetServerTime = os.time
_G.InCombatLockdown = function() return false end
_G.IsShiftKeyDown = function() return false end
_G.LoggingChat = function() return true end
_G.issecretvalue = function(v) return v == "SECRET" end

-- M+ / Vault / moedas
_G.C_MythicPlus = { GetOwnedKeystoneLevel = function() return 3 end,
                    GetOwnedKeystoneChallengeMapID = function() return 1 end,
                    GetSeasonBestForMap = function(id) if id == 1 then return { level = 6, dungeonScore = 180 }, { level = 7 } end end,
                    GetSeasonBestAffixScoreInfoForMap = function(id) return {}, id == 1 and 195.4 or 0 end,
                    GetRunHistory = function() return { { mapChallengeModeID = 1, level = 7, completed = false, runScore = 0 } } end,
                    GetCurrentAffixes = function() return { { id = 9 } } end }
_G.C_ChallengeMode = { GetMapUIInfo = function(id) return id == 2 and "Fenda" or "Repouso do Rei", id, 1800 end,
                       GetOverallDungeonScore = function() return 458 end,
                       GetMapTable = function() return { 1, 2 } end,
                       GetAffixInfo = function() return "Tirânico" end }
_G.C_WeeklyRewards = { GetActivities = function()
    return { { type = 1, index = 1, progress = 1, threshold = 1, level = 7, id = 5, activityTierID = 40 },
             { type = 3, index = 1, progress = 2, threshold = 2, level = 15, id = 6 } } end,
    GetExampleRewardItemHyperlinks = function(id) return "item:1", id == 5 and "item:2" or nil end,
    HasAvailableRewards = function() return false end,
    GetActivityEncounterInfo = function() return { { encounterID = 2, bestDifficulty = 15, uiOrder = 2 },
                                                   { encounterID = 1, bestDifficulty = 14, uiOrder = 1 } } end,
    GetSortedProgressForActivity = function() return { { difficulty = 7, numPoints = 1 } } end }
_G.EJ_GetEncounterInfo = function(id) return id == 1 and "Chefe A" or "Chefe B" end
_G.C_CurrencyInfo = {
    GetCurrencyListSize = function() return 2 end,
    GetCurrencyListInfo = function(i)
        if i == 1 then return { isHeader = true, isHeaderExpanded = true, name = "Midnight" } end
        return { name = "Brasão do Herói", quantity = 36 }
    end,
    GetCurrencyListLink = function() return "currency:3445" end,
    GetCurrencyIDFromLink = function() return 3445 end,
    GetCurrencyInfo = function() return { quantity = 36, maxQuantity = 900,
        quantityEarnedThisWeek = 10, maxWeeklyQuantity = 90 } end,
    ExpandCurrencyList = function() end,
}

-- itens
_G.GetInventoryItemLink = function(unit, slot)
    if slot == 1 then return LINK_ENCHANT elseif slot == 11 then return LINK_PLAIN end
end
_G.ItemLocation = {
    CreateFromEquipmentSlot = function() return { IsValid = function() return true end } end,
    CreateFromBagAndSlot = function() return { IsValid = function() return true end } end,
}
_G.C_Item = {
    GetItemInfo = function() return "Serpent Crown", nil, 4, nil, nil, "Armadura", "Malha", nil, "INVTYPE_HEAD" end,
    GetCurrentItemLevel = function() return 276 end,
    GetDetailedItemLevelInfo = function() return 276 end,
    GetItemStats = function() return { ITEM_MOD_CRIT_RATING_SHORT = 120, ITEM_MOD_INTELLECT_SHORT = 300 } end,
    GetItemGem = function(_, i) if i == 1 then return "Garnet Versátil" end end,
}
_G.C_TooltipInfo = { GetInventoryItem = function() return { lines = {
    { leftText = "Serpent Crown" }, { leftText = "Nível de aprimoramento: Herói 4/6" },
    { leftText = "Cabeça", rightText = "Malha" } } } end }
_G.C_Container = {
    GetContainerNumSlots = function(b) return b == 0 and 3 or 0 end,
    GetContainerItemInfo = function(_, s)
        local L = { LINK_PLAIN, LINK_PET, LINK_ENCHANT }
        return { hyperlink = L[s], stackCount = 1, isBound = true }
    end,
}
_G.Enum = { BagIndex = { CharacterBankTab_1 = 6 },
            DamageMeterSessionType = { Overall = 0, Current = 1 },
            DamageMeterType = { DamageDone = 0, HealingDone = 2, Absorbs = 4 } }
_G.NUM_BAG_SLOTS = 4

-- grupo / inspeção (sem grupo por padrão; test_group sobrescreve)
_G.IsInRaid = function() return false end
_G.IsInGroup = function() return false end
_G.GetInstanceInfo = function() return "Dornogal", "none", 0, "" end
_G.UnitExists = function() return false end
_G.UnitIsPlayer = function() return true end
_G.UnitIsUnit = function(a, b) return a == b end
_G.GetNumGroupMembers = function() return 0 end
_G.UnitGUID = function(u) return u == "player" and "P" or nil end
_G.UnitFullName = function() return "Fulano", "Reinoteste" end
_G.UnitGroupRolesAssigned = function() return "HEALER" end
_G.CanInspect = function() return false end
_G.NotifyInspect = function() end
_G.ClearInspectPlayer = function() end
_G.GetInspectSpecialization = function() return 0 end
_G.GetSpecializationInfoByID = function() return 0, "?" end
_G.C_PaperDollInfo = { GetInspectItemLevel = function() return 0 end }
_G.C_BattleNet = { GetAccountInfoByID = function() return { battleTag = "Amigo#1234" } end }

-- timers: enfileirados; run_timers() executa (permite testar fluxos assíncronos)
TIMERS = {}
_G.C_Timer = { After = function(_, f) TIMERS[#TIMERS + 1] = f end }
function run_timers(max)
    local n = 0
    while #TIMERS > 0 and n < (max or 50) do
        n = n + 1
        table.remove(TIMERS, 1)()
    end
end

RELOADS = 0
_G.ReloadUI = function() RELOADS = RELOADS + 1 end

-- frames
FRAMES = {}
_G.GameTooltip = setmetatable({}, { __index = function() return function() end end })
_G.UIParent, _G.SlashCmdList = {}, {}
local function stubObject(o)
    return setmetatable(o, { __index = function() return function() end end })
end
TEXTURES = 0
TEXLIST = {}
_G.CreateFrame = function(_, name)
    local f = { scripts = {}, events = {}, shown = true }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:SetPoint(...) self.point = { ... } end
    function f:CreateTexture()
        TEXTURES = TEXTURES + 1
        -- registra posição/tamanho para o teste ponta a ponta redesenhar a tela
        local t = { shown = true, x = 0, y = 0, w = false, h = false }  -- fundo (SetAllPoints) fica w=false
        function t:SetPoint(_, _, _, x, y) self.x, self.y = x, y end
        function t:SetSize(w, h) self.w, self.h = w, h end
        function t:SetColorTexture(r, g, b) self.r, self.g, self.b = r, g, b end
        function t:Show() self.shown = true end
        function t:Hide() self.shown = false end
        TEXLIST[#TEXLIST + 1] = t
        return stubObject(t)
    end
    stubObject(f)
    FRAMES[#FRAMES + 1] = f
    if name then _G[name] = f end
    return f
end

-- FRAMES[1] (frame principal do WowPilot.lua) recebe tudo; os demais só o que registraram
function fire(event, ...)
    for i, f in ipairs(FRAMES) do
        if f.scripts.OnEvent and (i == 1 or f.events[event]) then f.scripts.OnEvent(f, event, ...) end
    end
end

-- tela / screenshot (WowPilotLive)
_G.GetPhysicalScreenSize = function() return 1920, 1080 end
SCREENSHOTS = 0
_G.Screenshot = function() SCREENSHOTS = SCREENSHOTS + 1 end
CVARS = { screenshotFormat = "jpg", screenshotQuality = "3" }
_G.C_CVar = { GetCVar = function(k) return CVARS[k] end, SetCVar = function(k, v) CVARS[k] = v end }

function slash(cmd) SlashCmdList.WOWPILOT(cmd) end
