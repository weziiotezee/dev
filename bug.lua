-- =====================================================================
-- [OPT-v2] Performance Optimization Patch — Anti-Lag Long Session Fix
-- =====================================================================
-- สรุปการเปลี่ยนแปลง:
-- 1.  Cleanup cycle: 120s → 90s, deep cleanup 20min → 15min
--     - ใช้ in-place table clear แทนสร้าง table ใหม่ (ลด GC pressure)
--     - ล้าง stale cache obj เฉพาะที่ Parent==nil (ไม่ flush ทุกอัน)
--     - Queue threshold ลดลง (20/3/3/3 จาก 30/5/5/5)
--     - ล้าง recoveryLayer, LastMaterialsState, prompt cache
-- 2.  Minigame loop: Heartbeat(60fps) → Adaptive rate (25fps active / 7fps idle)
-- 3.  Detect flag loop: 0.5s → 0.8s
-- 4.  Overlay diagnostics: 0.5s → 1.5s, overlay boxes: 0.25s → 0.4s
-- 5.  Fishing step loop: 0.3s → 0.35s
-- 6.  Dashboard stats: 20s → 30s + yield between calls
-- 7.  AuraQueue process: 5s → 10s, Webhook check: 15s → 20s
-- 8.  NPC scan backup: 8s → 12s, Ping: 30s → 60s
-- 9.  Walk check: 0.2s → 0.25s, Shop stuck: 2s → 3s
-- 10. Biome scan: adaptive (1x when hopping, 2x slower when idle)
-- 11. Cache durations: action btn 0.2→0.4s, fish btn 0.5→0.8s,
--     minigame 1→1.5s, popup 0.3→0.5s, aura full scan 2→5s
-- 12. Scan cooldowns: GetPlayerRolls 3s, GetPlayerLuck 3s
-- 13. ProximityPrompt: cached 5s แทน GetDescendants ทุกครั้ง
-- 14. findAddIngredientsPopup: scan per-ScreenGui แทน playerGui ทั้งหมด
-- 15. ScanGear yield: 50→100, GetAuraTableData yield: 100→200, cap 2000
-- 16. AutoSaveToWebAPI: เพิ่ม yield 0.2→0.4 ระหว่าง heavy scans
-- 17. Sell loop: scrollframe fallback scan ใช้ sellFrame3 แทน mainUI
-- 18. isCacheValid: single pcall แทน 3 pcall
-- 19. ลบ dedicated recovery cleanup loop (ย้ายเข้า main cleanup)
-- =====================================================================

if not game:IsLoaded() then game.Loaded:Wait() end

math.randomseed(tick())

-- [FIX] Namespace ป้องกัน _G conflict กับเกม/executor อื่น
if not _G._XT then _G._XT = {} end
local _XT = _G._XT

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService") 
local vim = game:GetService("VirtualInputManager")
local guiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local PathfindingService = game:GetService("PathfindingService")
-- RunService ถูกลบออกแล้ว เพราะ Heartbeat ถูกเปลี่ยนเป็น task.wait loop

local player = Players.LocalPlayer
local playerName = player.DisplayName or player.Name
local playerUserId = tostring(player.UserId)
-- [FIX-CLICK] camera ต้อง refresh ทุกครั้ง เพราะ CurrentCamera เปลี่ยนได้ (respawn, teleport)
local camera = Workspace.CurrentCamera
local function getCamera()
    local cam = Workspace.CurrentCamera
    if cam then camera = cam end
    return camera
end

-- ==========================================
-- Anti-AFK (ป้องกันโดนเตะ 20 นาที เปิดอัตโนมัติ)
-- ==========================================
player.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

local parentGui = player:WaitForChild("PlayerGui")
local playerGui = parentGui
pcall(function()
    local CoreGui = game:GetService("CoreGui")
    if CoreGui then
        parentGui = (gethui and gethui()) or CoreGui:FindFirstChild("RobloxGui") or CoreGui
    end
end)

local TextChatService
pcall(function() TextChatService = game:GetService("TextChatService") end)

-- [FIX] httpRequest: ห่อด้วย pcall กัน error ตอน assign ถ้า executor ไม่มี request บางตัว
local httpRequest = nil
pcall(function()
    httpRequest = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
end)

-- ==========================================
-- ตัวแปรระบบหลัก (Main System)
-- ==========================================
local CustomWebAPIUrl = "https://www.rng-check.xyz/api.php"
local Webhooks = {
    Mari = { Url = "", Enabled = false },
    Rin = { Url = "", Enabled = false },
    Jester = { Url = "", Enabled = false },
    Biome = { Url = "", Enabled = false }
}
local lastDetectedNPC = ""

local enableAuraDetect = true
local minAuraRarity = 1000
local maxAuraRarity = 5000000000

local AuraQueue = {}
local lastAuraRollJson = "[]"

local CurrentBiomeCache = "Normal"
local NPCHistoryList = {}

local CurrentCraftTarget = ""
local IsCraftReady = false
local CurrentCraftMaterials = {}
local CraftSessionCount = 0
local CraftLogs = {}
local LastMaterialsState = {}

local enableAutoHop = false
local targetBiome = "Heaven"
local isHopping = false
local visitedServers = {}
local hopFileName = "HopBlocklist.json"

local masterAutoEnabled = false
local nextActionTime = 0

local ScannedItemsList = {}
local ScannedItemPaths = {}
local ScannedItemBaseNames = {} 
local SelectedMultiItems = {}
local CachedTargetButtons = {} 
local multiCraftIndex = 1
local multiCraftState = "SELECT"

local isIncognitoMode = false
local incognitoFakeName = "Hidden_" .. string.sub(playerUserId, -4)

local saveIntervalSeconds = 60
local isInfoWebhookEnabled = false
local scanCooldown = 2.5 

-- ==========================================
-- ตัวแปรระบบตกปลา (Auto Fish / Auto Sell)
-- ==========================================
local TARGET_FISH_POS = CFrame.new(51.72, 99.00, -282.40).Position
local TARGET_SELL_POS = CFrame.new(97.78, 107.50, -296.86).Position
local RESET_FISH_POS = CFrame.new(62.43, 99.00, -279.61).Position

local autoFarmEnabled = false
local autoSellEnabled = false
local isAtTarget = false 
local isSellingProcess = false
local isResettingUI = false
local hasArrivedAtSell = false 
local fishingStep = 0
local hasMinigameMoved = false 

local targetFishCount = 50 
local totalSellCount = 0
local fishingRoundCount = 0
local DetectFish_ON = false
local DetectMinigame_ON = false
local DetectAction_ON = false

local cachedSafeZone, cachedDiamond = nil, nil
local cachedExtraBtn, cachedFishBtn = nil, nil
local cachedSellAllBtn = nil

-- ==========================================
-- รายชื่อ Biome และ Config
-- ==========================================
local BiomeList = {
    ["Windy"] = {"windy", "wind"},
    ["Snowy"] = {"snowy", "snow"},
    ["Rainy"] = {"rainy", "rain"},
    ["Sand storm"] = {"sand storm", "sand"},
    ["Hell"] = {"hell"},
    ["Starfall"] = {"starfall", "star"},
    ["Heaven"] = {"heaven"},
    ["Corruption"] = {"corruption", "corrupt"},
    ["Null"] = {"null"},
    ["GLITCHED"] = {"glitched", "glitch"},
    ["DREAMSPACE"] = {"dreamspace", "dream"},
    ["CYBERSPACE"] = {"cyberspace", "cyber"}
}

local biomeNames = {}
for k, _ in pairs(BiomeList) do table.insert(biomeNames, k) end
table.sort(biomeNames) 

if isfile and isfile(hopFileName) then
    pcall(function() visitedServers = HttpService:JSONDecode(readfile(hopFileName)) end)
end
if #visitedServers > 200 then visitedServers = {} end
table.insert(visitedServers, game.JobId)
if writefile then pcall(function() writefile(hopFileName, HttpService:JSONEncode(visitedServers)) end) end


local ConfigFileName = "SolsHub_" .. playerName .. ".json"
local HubConfig = {
    AutoCraft = false, HopBiome = "Heaven", AutoHop = false,
    MariUrl = "", MariOn = false, RinUrl = "", RinOn = false, JesterUrl = "", JesterOn = false,
    WhInterval = 60, WhOn = false, Incognito = false, ScanDelay = 2.5,
    AutoFish = false, AutoSell = false, MaxFish = 50,
    BiomeUrl = "", BiomeOn = false, BiomeTarget = "Heaven"
}

local function LoadConfig()
    if isfile and isfile(ConfigFileName) then
        pcall(function()
            local data = HttpService:JSONDecode(readfile(ConfigFileName))
            for k, v in pairs(data) do HubConfig[k] = v end
        end)
    end
    
    masterAutoEnabled = false
    enableAutoHop = false
    HubConfig.AutoCraft = false
    HubConfig.AutoHop = false
    
    autoFarmEnabled = false 
    autoSellEnabled = false
    HubConfig.AutoFish = false
    HubConfig.AutoSell = false
    targetFishCount = tonumber(HubConfig.MaxFish) or 50
    
    targetBiome = HubConfig.HopBiome
    Webhooks.Mari.Url = HubConfig.MariUrl
    Webhooks.Mari.Enabled = HubConfig.MariOn
    Webhooks.Rin.Url = HubConfig.RinUrl
    Webhooks.Rin.Enabled = HubConfig.RinOn
    Webhooks.Jester.Url = HubConfig.JesterUrl
    Webhooks.Jester.Enabled = HubConfig.JesterOn
    
    saveIntervalSeconds = tonumber(HubConfig.WhInterval) or 60
    isInfoWebhookEnabled = HubConfig.WhOn
    isIncognitoMode = HubConfig.Incognito
    scanCooldown = tonumber(HubConfig.ScanDelay) or 2.5
    Webhooks.Biome.Url = HubConfig.BiomeUrl or ""
    Webhooks.Biome.Enabled = HubConfig.BiomeOn or false
end

local function SaveConfig()
    if writefile then
        pcall(function() writefile(ConfigFileName, HttpService:JSONEncode(HubConfig)) end)
    end
end
LoadConfig()

local ApiQueue = {}
local isApiSending = false

local function ProcessApiQueue()
    if isApiSending then return end
    isApiSending = true
    task.spawn(function()
        while #ApiQueue > 0 do
            local payload = ApiQueue[#ApiQueue]
            ApiQueue = {} 

            local success, err = pcall(function() 
                local encodedBody = HttpService:JSONEncode(payload)
                local response = httpRequest({ 
                    Url = CustomWebAPIUrl, 
                    Method = "POST", 
                    Headers = {
                        ["Content-Type"] = "application/json",
                        ["User-Agent"] = "Roblox/SolRNG-Script"
                    }, 
                    Body = encodedBody 
                }) 
            end)
            
            task.wait(5)
        end
        isApiSending = false
    end)
end

local WebhookQueue = {}
local isWebhookSending = false

local function ProcessWebhookQueue()
    if isWebhookSending then return end
    isWebhookSending = true
    task.spawn(function()
        while #WebhookQueue > 0 do
            local taskData = table.remove(WebhookQueue, 1)
            pcall(function() 
                httpRequest({ 
                    Url = taskData.Url, 
                    Method = "POST", 
                    Headers = {["Content-Type"] = "application/json"}, 
                    Body = HttpService:JSONEncode(taskData.Body) 
                }) 
            end)
            task.wait(4)
        end
        isWebhookSending = false
    end)
end

task.spawn(function()
    local cleanupCycle = 0
    -- [OPT-v2] ลดจาก 120s → 90s เพื่อล้าง memory ถี่ขึ้น บนมือถือ GC ทำงานช้า
    while task.wait(90) do
        cleanupCycle = cleanupCycle + 1

        -- ล้าง cache ที่เก็บ Instance reference (ป้องกัน stale ref ค้าง)
        if not masterAutoEnabled then
            -- [OPT-v2] ใช้ table.clear แทนสร้าง table ใหม่ ลด GC pressure
            if next(ScannedItemPaths) then for k in pairs(ScannedItemPaths) do ScannedItemPaths[k] = nil end end
            if next(ScannedItemBaseNames) then for k in pairs(ScannedItemBaseNames) do ScannedItemBaseNames[k] = nil end end
            if next(CachedTargetButtons) then for k in pairs(CachedTargetButtons) do CachedTargetButtons[k] = nil end end
        end
        _XT.cachedButtons.open = nil
        _XT.cachedButtons.auto = nil
        _XT.cachedButtons.craft = nil
        _XT.cachedRecipeHolder = nil

        if not autoFarmEnabled then
            cachedSafeZone = nil
            cachedDiamond = nil
            cachedExtraBtn = nil
            cachedFishBtn = nil
            -- [OPT-v2] ล้าง recovery layer ตอนไม่ได้ fish ด้วย
            if _XT.recoveryLayer then
                for k in pairs(_XT.recoveryLayer) do _XT.recoveryLayer[k] = nil end
            end
        end

        -- [OPT-v2] ลด queue threshold เข้มขึ้น ป้องกัน memory สะสม
        if #AuraQueue > 20 then AuraQueue = {} end
        if #ApiQueue > 3 then ApiQueue = {} end
        if #WebhookQueue > 3 then WebhookQueue = {} end
        if #DetectQueue > 3 then DetectQueue = {} end

        -- [OPT-v2] ล้าง player data cache เฉพาะ obj ที่ stale (Parent == nil)
        if Cache.RollsObj and not Cache.RollsObj.Parent then Cache.RollsObj = nil end
        if Cache.LuckObj and not Cache.LuckObj.Parent then Cache.LuckObj = nil end
        if Cache.LuckUI and not Cache.LuckUI.Parent then Cache.LuckUI = nil end
        if Cache.AuraObj and not Cache.AuraObj.Parent then Cache.AuraObj = nil end
        -- Attribute cache ไม่ต้องล้างบ่อย เพราะไม่ hold reference
        -- ล้างเฉพาะ deep cleanup cycle

        -- ล้าง shared helper cache
        _G._actionBGSample = nil
        _cachedActionBtn = nil
        _cachedActionContainer = nil
        _actionSearchTick = 0
        _XT._cachedPopupRoot = nil
        _XT._popupSearchTick = 0
        cachedSellAllBtn = nil
        -- [OPT-v2] ล้าง proximity prompt cache
        _XT._cachedPrompts = nil
        _XT._promptCacheTick = 0

        -- [OPT-v2] ตัด NPCHistoryList ใช้ in-place truncation แทนสร้าง table ใหม่
        while #NPCHistoryList > 8 do table.remove(NPCHistoryList) end

        -- [OPT-v2] ตัด CraftLogs in-place
        while #CraftLogs > 10 do table.remove(CraftLogs) end

        -- [OPT-v2] ล้าง LastMaterialsState ที่สะสมจาก craft loops ก่อนหน้า
        if not masterAutoEnabled and next(LastMaterialsState) then
            for k in pairs(LastMaterialsState) do LastMaterialsState[k] = nil end
        end

        -- Deep cleanup ทุก 15 นาที (10 cycles × 90s)
        if cleanupCycle % 10 == 0 then
            -- ล้าง visitedServers ที่บวมเกิน
            if #visitedServers > 60 then
                local newVisited = {game.JobId}
                for i = math.max(1, #visitedServers - 10), #visitedServers do
                    if visitedServers[i] ~= game.JobId then
                        newVisited[#newVisited + 1] = visitedServers[i]
                    end
                end
                visitedServers = newVisited
                if writefile then pcall(function() writefile(hopFileName, HttpService:JSONEncode(visitedServers)) end) end
            end

            -- [OPT-v2] Deep cleanup: ล้าง attribute cache ทั้งหมด
            Cache.RollsObj = nil; Cache.RollsAttr = nil
            Cache.LuckObj = nil; Cache.LuckAttr = nil; Cache.LuckUI = nil
            Cache.AuraObj = nil; Cache.AuraAttr = nil
            _lastAuraFullScanTick = 0
        end
    end
end)

local function AddCraftLog(msg)
    local timeStr = os.date("%H:%M:%S")
    table.insert(CraftLogs, 1, "[" .. timeStr .. "] " .. msg)
    -- [FIX] ลดจาก 15 → 10 ให้ตรงกับ cleanup cycle cap เพื่อป้องกัน memory สะสม
    if #CraftLogs > 10 then table.remove(CraftLogs, 11) end
end

local function StripRichText(str) return tostring(str or ""):gsub("<[^>]+>", "") end
local function CleanAuraName(str) local cleaned = str:gsub(":[%w_]+:%s*:%s*", ""); return cleaned:match("^%s*(.-)%s*$") or cleaned end
local function FormatNumber(number) number = tonumber(number) or 0; return tostring(number):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") end
local function TrimString(str) return tostring(str or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function IsInvalidItemName(nameLower)
    local blacklist = {"inventory","collection","auras","delete","lock","unlock","equip","unequip","search","rolls","luck","settings","close","open","back","confirm","equipped","unequipped","select","all","auto","filter", "index", "storage"}
    for _, word in ipairs(blacklist) do if nameLower == word then return true end end
    return false
end

local function AddInventoryItem(itemsDict, name, count)
    name = TrimString(name)
    if name == "" or tonumber(name) or #name < 2 or IsInvalidItemName(name:lower()) then return end
    count = tonumber(count) or 1
    if count < 1 then count = 1 end
    itemsDict[name] = (itemsDict[name] or 0) + count
end

local function GetRealBiomeText()
    local PlayerGui = player:FindFirstChild("PlayerGui")
    if not PlayerGui then return nil end
    local MainInterface = PlayerGui:FindFirstChild("MainInterface")
    if not MainInterface then return nil end

    for _, child in ipairs(MainInterface:GetChildren()) do
        if child.Name == "TextLabel" and child:IsA("TextLabel") then
            for _, innerChild in ipairs(child:GetChildren()) do
                if innerChild.Name == "TextLabel" and innerChild:IsA("TextLabel") then
                    local text = innerChild.Text
                    if text and string.match(text, "^%[.*%]$") then return text end
                end
            end
        end
    end
    return nil
end

local CurrentBiomeLabel
local HopStatusLabel
local CraftTargetLabel
local CraftStatusLabel

local function ServerHop()
    if isHopping then return end
    isHopping = true
    if HopStatusLabel then HopStatusLabel:SetDesc("Searching for a new server...") end
    if not httpRequest then
        if HopStatusLabel then HopStatusLabel:SetDesc("Executor does not support HTTP requests") end
        return
    end

    local placeId = game.PlaceId
    local cursor = nil
    local targetServer = nil

    for i = 1, 5 do
        local url = "https://games.roblox.com/v1/games/"..placeId.."/servers/Public?sortOrder=Desc&limit=100"
        if cursor then url = url .. "&cursor=" .. cursor end
        local success, response = pcall(function() return httpRequest({Url = url, Method = "GET"}) end)
        
        if success and response.StatusCode == 200 then
            local data = HttpService:JSONDecode(response.Body)
            for _, server in pairs(data.data) do
                local function hasVisited(id)
                    for _, v in ipairs(visitedServers) do if v == id then return true end end
                    return false
                end
                if server.playing < server.maxPlayers and server.id ~= game.JobId and not hasVisited(server.id) then
                    targetServer = server.id
                    break
                end
            end
            if targetServer then break end
            cursor = data.nextPageCursor
            if not cursor then break end
        end
        task.wait(2)
    end

    if targetServer then
        if HopStatusLabel then HopStatusLabel:SetDesc("Teleporting to new server...") end
        TeleportService:TeleportToPlaceInstance(placeId, targetServer, player)
    else
        -- [FIX] เปลี่ยนจาก recursive call เป็น reset แล้วให้ loop ข้างนอกลองใหม่เอง
        -- ป้องกัน stack overflow กรณี server เต็มทุก round
        if HopStatusLabel then HopStatusLabel:SetDesc("Server not found. Resetting blocklist...") end
        visitedServers = {game.JobId}
        task.wait(3)
        isHopping = false
        -- ไม่เรียก ServerHop() ซ้ำอีก — loop biome scan จะเรียกใหม่เองในรอบถัดไป
    end
end

pcall(function() if parentGui:FindFirstChild("MerchantPro_PopupOnly") then parentGui.MerchantPro_PopupOnly:Destroy() end end)

local Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()

local function ShowGameNotification(entityName)
    local targetData = Webhooks[entityName]
    if not targetData or not targetData.Enabled then return end
    
    Fluent:Notify({
        Title = "NPC Spawned!",
        Content = entityName .. " has spawned on the map.",
        Duration = 6
    })
end

local function SendMerchantWebhook(entityName, isTestMessage, isDespawn)
    local targetData = Webhooks[entityName]
    if not targetData or not targetData.Enabled or targetData.Url == "" or not httpRequest then return end
    
    local embedColor = 3066993
    if entityName == "Rin" then embedColor = 15105570
    elseif entityName == "Jester" then embedColor = 10181046 end
    
    if isDespawn then embedColor = 16711680 end 
    
    local titleTxt = isTestMessage and "Test Notification" or (isDespawn and ("NPC Despawn Alert: " .. entityName) or ("NPC Alert: " .. entityName))
    local descTxt = isTestMessage and "Webhook system is online!" or (isDespawn and string.format("**%s** has despawned / left the map!", entityName) or string.format("**%s** has spawned on the map!\nWill despawn in 3 minutes.", entityName))
    
    local payload = {
        content = (isTestMessage or isDespawn) and "" or "@everyone",
        embeds = {{
            title = titleTxt,
            description = descTxt,
            color = embedColor,
            fields = {
                {name = "Detected By", value = "```" .. playerName .. "```", inline = true},
                {name = "NPC Name", value = "```" .. entityName .. "```", inline = true},
                {name = "Current Biome", value = "```" .. CurrentBiomeCache .. "```", inline = false}
            },
            footer = {text = "XT-HUB [1.7]"}
        }}
    }
    
    table.insert(WebhookQueue, {Url = targetData.Url, Body = payload})
    ProcessWebhookQueue()
end

local Cache = { RollsObj = nil, RollsAttr = nil, LuckObj = nil, LuckAttr = nil, LuckUI = nil, AuraObj = nil, AuraAttr = nil }

local function SendBiomeWebhook(biomeName)
    local targetData = Webhooks.Biome
    if not targetData or not targetData.Enabled or targetData.Url == "" or not httpRequest then return end

    local payload = {
        embeds = {{
            title = "🌍 Biome Alert: " .. biomeName,
            description = string.format("**%s** biome has appeared on this server!", biomeName),
            color = 3447003,
            fields = {
                {name = "Detected By", value = "```" .. playerName .. "```", inline = true},
                {name = "Biome", value = "```" .. biomeName .. "```", inline = true},
                {name = "Server", value = "```" .. tostring(game.JobId):sub(1,8) .. "...```", inline = false}
            },
            footer = {text = "XT-HUB [1.7]"}
        }}
    }
    table.insert(WebhookQueue, {Url = targetData.Url, Body = payload})
    ProcessWebhookQueue()
end

function GetPlayerRolls()
    if Cache.RollsObj and Cache.RollsObj.Parent then return Cache.RollsObj.Value end
    if Cache.RollsAttr then return player:GetAttribute(Cache.RollsAttr) or 0 end

    -- [OPT-v2] Scan cooldown ป้องกัน GetAttributes/GetChildren ซ้ำถี่
    if not _XT._lastRollsScanTick then _XT._lastRollsScanTick = 0 end
    if tick() - _XT._lastRollsScanTick < 3.0 then return 0 end
    _XT._lastRollsScanTick = tick()

    local totalRolls = 0
    pcall(function()
        local leaderstats = player:FindFirstChild("leaderstats")
        if leaderstats then
            local exactRolls = leaderstats:FindFirstChild("Rolls")
            if exactRolls and (exactRolls:IsA("IntValue") or exactRolls:IsA("NumberValue")) then
                Cache.RollsObj = exactRolls; totalRolls = exactRolls.Value; return
            end
            for _, v in pairs(leaderstats:GetChildren()) do
                if (v:IsA("IntValue") or v:IsA("NumberValue")) and (v.Name:lower():find("roll") or v.Name:lower():find("spin")) then
                    Cache.RollsObj = v; totalRolls = v.Value; return
                end
            end
        end
        for name, val in pairs(player:GetAttributes()) do
            if (name:lower():find("roll") or name:lower():find("spin")) and type(val) == "number" then
                Cache.RollsAttr = name; totalRolls = val; return
            end
        end
    end)
    return totalRolls
end

function GetPlayerLuck()
    -- Cache hit
    if Cache.LuckObj and Cache.LuckObj.Parent then return Cache.LuckObj.Value end
    if Cache.LuckAttr then return player:GetAttribute(Cache.LuckAttr) or 1.00 end
    if Cache.LuckUI and Cache.LuckUI.Parent and Cache.LuckUI:IsDescendantOf(playerGui) then
        local match = Cache.LuckUI.Text:match("%d+%.?%d*")
        if match then return tonumber(match) or 1.00 end
        Cache.LuckUI = nil
    end

    -- [OPT-v2] Scan cooldown ป้องกัน GetDescendants ซ้ำถี่เมื่อ cache miss
    if not _XT._lastLuckScanTick then _XT._lastLuckScanTick = 0 end
    if tick() - _XT._lastLuckScanTick < 3.0 then return 1.00 end
    _XT._lastLuckScanTick = tick()
 
    local totalLuck = 1.00
    pcall(function()
        -- ★★★ [FIX] Path ตรง: PlayerGui.Stats.ScrollingFrame.Lucks ★★★
        local statsGui = playerGui:FindFirstChild("Stats")
        if statsGui then
            local scrollFrame = statsGui:FindFirstChild("ScrollingFrame")
            if scrollFrame then
                local lucksObj = scrollFrame:FindFirstChild("Lucks")
                if lucksObj then
                    -- กรณี 1: Lucks เป็น ValueBase (IntValue/NumberValue)
                    if lucksObj:IsA("ValueBase") then
                        Cache.LuckObj = lucksObj
                        totalLuck = tonumber(lucksObj.Value) or 1.00
                        return
                    end
                    -- กรณี 2: Lucks เป็น TextLabel โดยตรง
                    if lucksObj:IsA("TextLabel") then
                        local xMatch = lucksObj.Text:match("[xX](%d+%.?%d*)")
                        local numMatch = xMatch or lucksObj.Text:gsub(",", ""):match("(%d+%.?%d*)")
                        if numMatch and tonumber(numMatch) then
                            Cache.LuckUI = lucksObj
                            totalLuck = tonumber(numMatch)
                            return
                        end
                    end
                    -- กรณี 3: Lucks เป็น Frame ที่มี TextLabel ลูก
                    if lucksObj:IsA("GuiObject") then
                        for _, child in ipairs(lucksObj:GetDescendants()) do
                            if child:IsA("TextLabel") and child.Visible then
                                local text = child.Text or ""
                                local xMatch = text:match("[xX](%d+%.?%d*)")
                                local numMatch = xMatch or text:gsub(",", ""):match("(%d+%.?%d*)")
                                if numMatch and tonumber(numMatch) then
                                    Cache.LuckUI = child
                                    totalLuck = tonumber(numMatch)
                                    return
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: scan ทุก TextLabel ใน Stats ที่มีตัวเลข luck
            for _, gui in ipairs(statsGui:GetDescendants()) do
                if gui:IsA("TextLabel") and gui.Visible then
                    local n = gui.Name:lower()
                    local t = gui.Text:lower()
                    if n:find("luck") or t:find("luck") or t:find("🍀") then
                        local xMatch = gui.Text:match("[xX](%d+%.?%d*)")
                        local numMatch = xMatch or gui.Text:gsub(",", ""):match("(%d+%.?%d*)")
                        if numMatch and tonumber(numMatch) then
                            Cache.LuckUI = gui
                            totalLuck = tonumber(numMatch)
                            return
                        end
                    end
                end
            end
        end
 
        -- Fallback เดิม: Folder/Configuration ลูกของ Player
        for _, v in pairs(player:GetChildren()) do
            if v:IsA("Folder") or v:IsA("Configuration") then
                local luckObj = v:FindFirstChild("Luck") or v:FindFirstChild("Multiplier")
                if luckObj and (luckObj:IsA("NumberValue") or luckObj:IsA("IntValue")) then
                    Cache.LuckObj = luckObj; totalLuck = luckObj.Value; return
                end
            end
        end
 
        -- Fallback เดิม: Attribute
        if player:GetAttribute("Luck") then Cache.LuckAttr = "Luck"; totalLuck = player:GetAttribute("Luck"); return end
        if player:GetAttribute("LuckMultiplier") then Cache.LuckAttr = "LuckMultiplier"; totalLuck = player:GetAttribute("LuckMultiplier"); return end
 
        -- Fallback เดิม: MainInterface
        local mainLuckUI = playerGui:FindFirstChild("MainInterface")
        if mainLuckUI then
            for _, gui in ipairs(mainLuckUI:GetDescendants()) do
                if gui:IsA("TextLabel") then
                    if gui.Name:lower():find("luck") or gui.Text:lower():find("luck") or gui.Text:find("🍀") then
                        local xMatch = gui.Text:match("[xX](%d+%.?%d*)")
                        local numMatch = xMatch or gui.Text:gsub(",", ""):match("(%d+%.?%d*)")
                        if numMatch and tonumber(numMatch) then
                            Cache.LuckUI = gui; totalLuck = tonumber(numMatch); return
                        end
                    end
                end
            end
        end
    end)
    return totalLuck
end

local _lastAuraFullScanTick = 0

function GetEquippedAura()
    -- Cache: ถ้าเคยเจอแล้ว ใช้ซ้ำได้
    if Cache.AuraAttr then
        local val = player:GetAttribute(Cache.AuraAttr)
        if val and val ~= "" then return val end
        Cache.AuraAttr = nil -- attribute หายไปแล้ว reset cache
    end
    if Cache.AuraObj and Cache.AuraObj.Parent then
        if Cache.AuraObj.Value ~= "" then return Cache.AuraObj.Value end
    end
 
    -- [OPT-v2] ถ้าไม่มี cache และผ่าน full scan ไปไม่นาน ให้คืน "Normal" ก่อน
    -- เพิ่มจาก 2s → 5s เพราะ aura ไม่ค่อยเปลี่ยน ลด GetDescendants ที่แพง
    if tick() - _lastAuraFullScanTick < 5.0 then return "Normal" end
    _lastAuraFullScanTick = tick()

    local currentAura = "Normal"
    pcall(function()
        -- [เดิม] ค้นหา Attribute บน Player ที่มีคำว่า "aura"
        for name, val in pairs(player:GetAttributes()) do
            local n = name:lower()
            if n:find("aura") or n == "equipped" or n == "equippedaura" then
                if type(val) == "string" and val ~= "" then
                    Cache.AuraAttr = name; currentAura = val; return
                end
            end
        end
 
        -- [เดิม] ค้นหา StringValue ลูกหลานของ Player
        for _, v in pairs(player:GetDescendants()) do
            if v:IsA("StringValue") and v.Value ~= "" then
                local n = v.Name:lower()
                if n:find("aura") or n == "equipped" or n == "currentaura" then
                    Cache.AuraObj = v; currentAura = v.Value; return
                end
            end
        end
 
        -- [FIX-2A] ค้นหาใน Character model
        -- Sol's RNG บาง version เก็บชื่อ Aura เป็น StringValue ใน Character
        local character = player.Character
        if character then
            for _, v in pairs(character:GetChildren()) do
                if v:IsA("StringValue") and v.Value ~= "" then
                    local n = v.Name:lower()
                    if n:find("aura") or n == "equipped" or n == "currentaura" then
                        Cache.AuraObj = v; currentAura = v.Value; return
                    end
                end
            end
            -- เช็ค Attribute บน Character ด้วย
            for name, val in pairs(character:GetAttributes()) do
                local n = name:lower()
                if n:find("aura") and type(val) == "string" and val ~= "" then
                    -- เก็บเป็น AuraAttr ไม่ได้เพราะอยู่บน Character ไม่ใช่ Player
                    -- เก็บ reference ไว้แทน
                    currentAura = val; return
                end
            end
        end
 
        -- [FIX-2B] ★ Scan UI ใน MainInterface ★
        -- Sol's RNG แสดงชื่อ Aura ที่สวมอยู่ใน MainInterface
        -- โดยทั่วไปจะเป็น TextLabel ที่อยู่ใกล้กับ Rolls/Luck display
        local mainUI = playerGui:FindFirstChild("MainInterface")
        if mainUI then
            -- วิธีที่ 1: หา TextLabel ที่ Name มีคำว่า "aura" หรือ "equipped"
            for _, gui in ipairs(mainUI:GetDescendants()) do
                if gui:IsA("TextLabel") and gui.Visible then
                    local nameLower = gui.Name:lower()
                    if nameLower:find("aura") or nameLower:find("equipped") then
                        local text = TrimString(gui.Text)
                        if text ~= "" and not tonumber(text) and #text >= 2 then
                            local clean = StripRichText(text)
                            -- ตัด prefix เช่น "Equipped: " หรือ "Aura: " ออก
                            clean = clean:gsub("^[Ee]quipped:?%s*", "")
                            clean = clean:gsub("^[Aa]ura:?%s*", "")
                            clean = TrimString(clean)
                            if clean ~= "" and not tonumber(clean) then
                                currentAura = clean; return
                            end
                        end
                    end
                end
            end
 
            -- วิธีที่ 2: หา TextLabel ที่ Text มีคำว่า "Equipped" ตามด้วยชื่อ
            -- เช่น "Equipped: Solar" หรือ "🌟 Equipped: Celestial"
            for _, gui in ipairs(mainUI:GetDescendants()) do
                if gui:IsA("TextLabel") and gui.Visible then
                    local text = StripRichText(gui.Text)
                    local auraName = text:match("[Ee]quipped:?%s*(.+)")
                    if auraName then
                        auraName = TrimString(auraName)
                        if auraName ~= "" and not tonumber(auraName) and #auraName >= 2 then
                            currentAura = auraName; return
                        end
                    end
                end
            end
 
            -- วิธีที่ 3: สำหรับ Sol's RNG โดยเฉพาะ
            -- ชื่อ Aura มักจะอยู่ใน Inventory UI section ใกล้กับ "Auras" tab
            local invUI = mainUI:FindFirstChild("Inventory")
            if invUI then
                for _, gui in ipairs(invUI:GetDescendants()) do
                    if gui:IsA("TextLabel") and gui.Visible then
                        local nameLower = gui.Name:lower()
                        if nameLower == "auraname" or nameLower == "equippedaura" or nameLower == "currentaura" then
                            local text = TrimString(StripRichText(gui.Text))
                            if text ~= "" and not tonumber(text) and #text >= 2 then
                                currentAura = text; return
                            end
                        end
                    end
                end
            end
        end
    end)
    return currentAura
end

local function ParseInventoryEntry(entryObj)
    local bestName, bestLen = nil, 0
    for _, node in ipairs(entryObj:GetDescendants()) do
        if node:IsA("TextLabel") or node:IsA("TextButton") then
            local textValue = TrimString(node.Text)
            if textValue ~= "" and not tonumber(textValue) and #textValue >= 2 then
                local nodeName = node.Name:lower()
                local weight = (nodeName == "auraname" and 50) or (nodeName:find("name") and 30) or (nodeName:find("title") and 20) or 0
                local scoreLen = #textValue + weight
                if scoreLen > bestLen and not IsInvalidItemName(textValue:lower()) then
                    bestLen = scoreLen; bestName = textValue
                end
            end
        end
    end
    if not bestName then return nil, nil end
    local bestCount = 1
    for _, node in ipairs(entryObj:GetDescendants()) do
        if node:IsA("TextLabel") or node:IsA("TextButton") then
            local lowerText = TrimString(node.Text):lower()
            local foundCount = lowerText:match("^x(%d+)") or lowerText:match("owned: ") or lowerText:match("owned:%s*(%d+)") or lowerText:match("^(%d+) ") or lowerText:match("owned:") or lowerText:match("(%d+)/%d+")
            if foundCount and tonumber(foundCount) then
                bestCount = tonumber(foundCount)
                local n = node.Name:lower()
                if n:find("count") or n:find("amount") or n:find("owned") then break end
            end
        end
    end
    return bestName, bestCount
end

function ScanPotions()
    local potionItems = {}
    pcall(function()
        local bankUI = playerGui:FindFirstChild("BankRework")
        if not bankUI then return end
        local materialsUI = bankUI:FindFirstChild("BankFrame") and bankUI.BankFrame:FindFirstChild("Materials")
        if not materialsUI then return end
        for _, itemProgress in ipairs(materialsUI:GetChildren()) do
            if itemProgress.Name == "ItemProgress" then
                local nameLbl = itemProgress:FindFirstChild("ItemName")
                local amountLbl = itemProgress:FindFirstChild("Amount")
                if nameLbl and amountLbl then
                    local itemName = TrimString(nameLbl.Text)
                    local countStr = TrimString(amountLbl.Text):gsub(",", ""):match("(%d+)")
                    local itemCount = countStr and tonumber(countStr) or 0
                    if itemName ~= "" and itemCount > 0 and not IsInvalidItemName(itemName:lower()) then
                        potionItems[itemName] = itemCount
                    end
                end
            end
        end
    end)
    return potionItems
end

local function GetInventoryContainer()
    local mainUI = playerGui:FindFirstChild("MainInterface")
    if mainUI then
        local invUI = mainUI:FindFirstChild("Inventory")
        if invUI and invUI:FindFirstChild("Items") and invUI.Items:FindFirstChild("ItemGrid") then
            return invUI.Items.ItemGrid:FindFirstChild("ItemGridScrollingFrame")
        end
    end
    return nil
end

function ScanGear()
    local gearItems = {}
    pcall(function()
        local container = GetInventoryContainer()
        if container then
            for i, entry in ipairs(container:GetChildren()) do
                if entry:IsA("Frame") or entry:IsA("ImageButton") or entry:IsA("TextButton") then
                    local itemName, itemCount = ParseInventoryEntry(entry)
                    if itemName then AddInventoryItem(gearItems, itemName, itemCount) end
                end
                if i % 100 == 0 then task.wait() end 
            end
        end
    end)
    return gearItems
end

function GetAuraTableData()
    local mainUI = playerGui:FindFirstChild("MainInterface")
    if not mainUI then return nil end
    local auraDataDict = {}
    local totalUniqueAuras = 0
    
    -- [OPT-v2] yield ทุก 200 items แทน 100 — ลด overhead จาก task.wait()
    -- cap total descendants ที่ 2000 ป้องกัน UI tree ใหญ่มากทำแลค
    local count = 0
    local MAX_DESCENDANTS = 2000
    for _, obj in ipairs(mainUI:GetDescendants()) do
        count = count + 1
        if count > MAX_DESCENDANTS then break end
        if obj:IsA("TextLabel") and obj.Name == "TextLabel" and obj.Parent then
            local parentName = obj.Parent.Name
            if string.match(parentName, "^0%.%d+$") then
                local auraText = obj.Text
                if auraText ~= "" and auraText ~= "Undefined" and not string.match(auraText:lower():gsub("%s+", ""), "^x%d+$") then
                    local uiLayoutOrder = 0
                    pcall(function() uiLayoutOrder = obj.Parent.LayoutOrder end)
                    if not auraDataDict[auraText] then
                        -- [FIX] cap ที่ 500 unique auras ป้องกัน memory สะสมเมื่อ inventory ขนาดใหญ่
                        if totalUniqueAuras < 500 then
                            auraDataDict[auraText] = {count = 0, order = uiLayoutOrder}
                            totalUniqueAuras = totalUniqueAuras + 1
                        end
                    end
                    if auraDataDict[auraText] then
                        auraDataDict[auraText].count = auraDataDict[auraText].count + 1
                        if uiLayoutOrder ~= 0 then auraDataDict[auraText].order = uiLayoutOrder end
                    end
                end
            end
        end
        if count % 200 == 0 then task.wait() end 
    end
    
    local sortedAuraList = {}
    for name, data in pairs(auraDataDict) do
        table.insert(sortedAuraList, {name = name, count = data.count, order = data.order})
    end
    if totalUniqueAuras == 0 then return nil end
    table.sort(sortedAuraList, function(a, b) return a.order < b.order end)
    return sortedAuraList
end

-- ==========================================
-- [FIX-CLICK-v3] Shared Click Helpers
-- ==========================================
local isTouchDevice = UserInputService.TouchEnabled

-- ==========================================
-- 1. ฟังก์ชันคลิกสำหรับ UI ทั่วไป และ Auto Craft
-- ==========================================
local function forceCraftClick(element)
    if not element then return false end
    local successClicked = false
    
    pcall(function()
        local button = element
        if not button:IsA("GuiButton") and button.Parent and button.Parent:IsA("GuiButton") then 
            button = button.Parent 
        end
        if getconnections and button:IsA("GuiButton") then
            for _, conn in ipairs(getconnections(button.MouseButton1Click)) do pcall(function() conn:Fire() end) end
            for _, conn in ipairs(getconnections(button.Activated)) do pcall(function() conn:Fire() end) end
            successClicked = true
        end
    end)

    pcall(function()
        local absPos, absSize = element.AbsolutePosition, element.AbsoluteSize
        if absSize.X > 0 and absSize.Y > 0 then
            local inset, _ = guiService:GetGuiInset()
            local cam = getCamera()
            local vp = cam.ViewportSize
            local rawX = absPos.X + (absSize.X / 2) + inset.X
            local rawY = absPos.Y + (absSize.Y / 2) + inset.Y
            local margin = 2
            local clickX = math.clamp(rawX, margin, vp.X - margin)
            local clickY = math.clamp(rawY, margin, vp.Y - margin)

            pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1) end)
            task.wait(0.05)
            pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1) end)
            -- [FIX-CLICK-v3] เพิ่ม touch event ที่เดิมไม่มี
            if isTouchDevice then
                task.wait(0.02)
                pcall(function() vim:SendTouchEvent(0, Vector2.new(clickX, clickY), true) end)
                task.wait(0.05)
                pcall(function() vim:SendTouchEvent(0, Vector2.new(clickX, clickY), false) end)
            end
            successClicked = true
        end
    end)
    
    return successClicked
end

-- ==========================================
-- 2. ฟังก์ชันคลิกเฉพาะหน้าจอ / ปุ่มสำหรับการตกปลา
-- ==========================================
local function forceFishClick(element)
    if not element then
        return false
    end
    local successClicked = false

    pcall(function()
        local button = element
        if not button:IsA("GuiButton") and button.Parent and button.Parent:IsA("GuiButton") then
            button = button.Parent
        end
        if getconnections and button:IsA("GuiButton") then
            for _, conn in ipairs(getconnections(button.MouseButton1Click)) do pcall(function() conn:Fire() end) end
            for _, conn in ipairs(getconnections(button.Activated)) do pcall(function() conn:Fire() end) end
            successClicked = true
        end
    end)

    pcall(function()
        local absPos, absSize = element.AbsolutePosition, element.AbsoluteSize
        if absSize.X > 0 and absSize.Y > 0 then
            local inset, _ = guiService:GetGuiInset()
            local cam = getCamera()
            local vp = cam.ViewportSize
            local rawX = absPos.X + (absSize.X / 2) + inset.X
            local rawY = absPos.Y + (absSize.Y / 2) + inset.Y
            local margin = 2
            local clickX = math.clamp(rawX, margin, vp.X - margin)
            local clickY = math.clamp(rawY, margin, vp.Y - margin)

            pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1) end)
            task.wait(0.05)
            pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1) end)
            if isTouchDevice then
                task.wait(0.02)
                pcall(function() vim:SendTouchEvent(0, Vector2.new(clickX, clickY), true) end)
                task.wait(0.05)
                pcall(function() vim:SendTouchEvent(0, Vector2.new(clickX, clickY), false) end)
            end
            successClicked = true
        end
    end)

    return successClicked
end

local function clickOnce()
    local inset, _ = guiService:GetGuiInset()
    local cam = getCamera()
    local safeX = cam.ViewportSize.X * 0.5 + inset.X
    local safeY = cam.ViewportSize.Y * 0.5 + inset.Y
    pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, true, game, 1) end)
    task.wait(0.05) 
    pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, false, game, 1) end)
    if isTouchDevice then
        task.wait(0.02)
        pcall(function() vim:SendTouchEvent(0, Vector2.new(safeX, safeY), true) end)
        task.wait(0.05)
        pcall(function() vim:SendTouchEvent(0, Vector2.new(safeX, safeY), false) end)
    end
end

local function getButtonText(btn)
    if btn:IsA("TextButton") and btn.Text ~= "" then return string.lower(btn.Text) end
    for _, child in pairs(btn:GetChildren()) do
        if child:IsA("TextLabel") and child.Text ~= "" then return string.lower(child.Text) end
    end
    return ""
end

-- ==========================================
-- [PATCHED] ระบบเดิน — แก้บัคกระโดดเพี้ยน
-- ==========================================
local function walkToTarget(targetPos, locationName)
    local char = player.Character
    local hum  = char and char:FindFirstChild("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end

    local function computeAndWalk()
        local path = PathfindingService:CreatePath({
            AgentRadius     = 2,
            AgentHeight     = 5,
            AgentCanJump    = true,
            AgentJumpHeight = 10,
            AgentMaxSlope   = 45,
            WaypointSpacing = 6
        })

        local success, _ = pcall(function()
            path:ComputeAsync(root.Position, targetPos)
        end)
        local expectedSellState = isSellingProcess

        if not (success and path.Status == Enum.PathStatus.Success) then
            hum:MoveTo(targetPos)
            task.wait(1)
            return
        end

        local waypoints = path:GetWaypoints()
        for i = 2, #waypoints do
            if not autoFarmEnabled or isSellingProcess ~= expectedSellState then break end

            local flatRoot   = Vector3.new(root.Position.X, 0, root.Position.Z)
            local flatTarget = Vector3.new(targetPos.X,     0, targetPos.Z)
            if (flatRoot - flatTarget).Magnitude < 4 then break end

            local wp = waypoints[i]

            if wp.Action == Enum.PathWaypointAction.Jump then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
                task.wait(0.15)
            end
            hum:MoveTo(wp.Position)

            local lastPos     = root.Position
            local stuckTick   = tick()
            local wpStartTick = tick()

            while autoFarmEnabled and isSellingProcess == expectedSellState do
                local distToWp = (Vector3.new(root.Position.X, 0, root.Position.Z)
                                - Vector3.new(wp.Position.X,   0, wp.Position.Z)).Magnitude
                if distToWp < 4 then break end

                if (root.Position - lastPos).Magnitude > 0.5 then
                    lastPos   = root.Position
                    stuckTick = tick()
                end
                if tick() - stuckTick > 2.5 then
                    hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    task.wait(0.15)
                    hum:MoveTo(wp.Position)
                    stuckTick = tick()
                end

                if tick() - wpStartTick > 6.0 then break end

                task.wait(0.1)
            end
        end
    end

    computeAndWalk()

    local flatRoot   = Vector3.new(root.Position.X, 0, root.Position.Z)
    local flatTarget = Vector3.new(targetPos.X,     0, targetPos.Z)
    if autoFarmEnabled and (flatRoot - flatTarget).Magnitude > 6 then
        task.wait(0.5)
        computeAndWalk()
    end
end

-- ==========================================
-- [OPT] Shared helper: ค้นหา Action Button (ImageLabel>ImageLabel>ImageButton) ใน mainUI
-- ใช้แทน nested loop ที่ซ้ำกัน 5+ จุด ลด CPU จากการ traverse ซ้ำ
-- ==========================================
local _cachedActionBtn, _cachedActionContainer = nil, nil
local _actionSearchTick = 0

local function findActionBtnFast(mainUI, forceRefresh)
    -- [OPT-v2] cache valid for 0.4s (จาก 0.2s) ลด search ซ้ำ
    if not forceRefresh and _cachedActionBtn and (tick() - _actionSearchTick) < 0.4 then
        -- [FIX] pcall return value คือ success bool ไม่ใช่ผลลัพธ์ ต้องตรวจ condition ข้างใน
        local isValid = false
        pcall(function()
            isValid = _cachedActionBtn.Parent ~= nil
                   and _cachedActionBtn.Visible
                   and _cachedActionBtn.AbsoluteSize.X > 0
        end)
        if isValid then return _cachedActionBtn, _cachedActionContainer end
    end
    _cachedActionBtn, _cachedActionContainer = nil, nil
    _actionSearchTick = tick()
    
    pcall(function()
        for _, lv1 in ipairs(mainUI:GetChildren()) do
            if lv1:IsA("ImageLabel") then
                for _, lv2 in ipairs(lv1:GetChildren()) do
                    if lv2:IsA("ImageLabel") then
                        for _, lv3 in ipairs(lv2:GetChildren()) do
                            if lv3:IsA("ImageButton") and lv3.Visible and lv3.AbsoluteSize.X > 0 then
                                _cachedActionBtn = lv3
                                _cachedActionContainer = lv2
                                return
                            end
                        end
                    end
                end
            end
        end
    end)
    return _cachedActionBtn, _cachedActionContainer
end

local function isCacheValid(element)
    if not element then return false end
    -- [OPT-v2] single pcall แทน 2 pcall ลด overhead
    local ok, result = pcall(function()
        return element.Parent
            and element:IsDescendantOf(playerGui)
            and element.Visible
            and element.AbsoluteSize.X > 0
    end)
    return ok and result or false
end

local function getExtraButton(mainUI)
    if cachedExtraBtn and cachedExtraBtn.Parent and cachedExtraBtn:IsDescendantOf(playerGui) then
        local ok, vis = pcall(function() return cachedExtraBtn.Visible end)
        if ok and vis and cachedExtraBtn.AbsoluteSize.X > 0 then
            return cachedExtraBtn
        end
    end
    cachedExtraBtn = nil

    -- [OPT] ใช้ findActionBtnFast แทน scan ซ้ำ
    local fastBtn, _ = findActionBtnFast(mainUI, true)
    if fastBtn then
        cachedExtraBtn = fastBtn
        return cachedExtraBtn
    end

    return cachedExtraBtn
end

local lastFishBtnScanTime = 0
local function getFishButton(mainUI, forceRefresh)
    if not forceRefresh and cachedFishBtn and cachedFishBtn.Parent and cachedFishBtn:IsDescendantOf(playerGui) then
        local ok, vis = pcall(function() return cachedFishBtn.Visible end)
        if ok and vis then return cachedFishBtn end
    end
    cachedFishBtn = nil

    -- [FIX-v4] forceRefresh = true จะ bypass cooldown
    if not forceRefresh then
        if tick() - lastFishBtnScanTime < 0.8 then return nil end
    end
    lastFishBtnScanTime = tick()

    for _, element in ipairs(mainUI:GetDescendants()) do
        if element:IsA("TextLabel") then
            local txt = element.Text
            if txt == "Fish" or txt:lower() == "fish" then
                local parentBtn = element.Parent
                if parentBtn and (parentBtn:IsA("ImageButton") or parentBtn:IsA("TextButton") or parentBtn:IsA("GuiButton")) then
                    cachedFishBtn = parentBtn
                    return cachedFishBtn
                end
                local grandParent = parentBtn and parentBtn.Parent
                if grandParent and (grandParent:IsA("ImageButton") or grandParent:IsA("TextButton") or grandParent:IsA("GuiButton")) then
                    cachedFishBtn = grandParent
                    return cachedFishBtn
                end
            end
        end
    end
    return nil
end

local lastMinigameScanTime = 0 
local function getExactMinigameElements()
    if isCacheValid(cachedSafeZone) and isCacheValid(cachedDiamond) then
        return cachedSafeZone, cachedDiamond
    end

    -- [OPT-v2] scan cooldown 1s → 1.5s เมื่อ cache miss
    if tick() - lastMinigameScanTime < 1.5 then return nil, nil end
    lastMinigameScanTime = tick()

    local mainUI = playerGui:FindFirstChild("MainInterface")
    if not mainUI then return nil, nil end

    -- [OPT-v2] ใช้ nested GetChildren 4 ชั้น แทน GetDescendants
    -- Structure: MainInterface > ImageLabel(lv1) > ImageLabel(lv2) > ImageLabel(lv3) > container(ImageLabel)
    pcall(function()
        for _, lv1 in ipairs(mainUI:GetChildren()) do
            if not lv1:IsA("ImageLabel") then continue end
            for _, lv2 in ipairs(lv1:GetChildren()) do
                if not lv2:IsA("ImageLabel") then continue end
                for _, lv3 in ipairs(lv2:GetChildren()) do
                    if not lv3:IsA("ImageLabel") then continue end
                    for _, container in ipairs(lv3:GetChildren()) do
                        if not container:IsA("ImageLabel") then continue end
                        local validChildren = {}
                        for _, child in ipairs(container:GetChildren()) do
                            if child:IsA("ImageLabel") then validChildren[#validChildren + 1] = child end
                        end
                        if #validChildren >= 2 then
                            table.sort(validChildren, function(a, b) return a.AbsoluteSize.X > b.AbsoluteSize.X end)
                            cachedSafeZone = (#validChildren >= 3) and validChildren[2] or validChildren[1]
                            cachedDiamond = validChildren[#validChildren]
                            return
                        end
                    end
                end
            end
        end
    end)
    return cachedSafeZone, cachedDiamond
end

local function isOverlapping(diamond, safezone)
    return (diamond.AbsolutePosition.X + diamond.AbsoluteSize.X >= safezone.AbsolutePosition.X) and 
           (diamond.AbsolutePosition.X <= safezone.AbsolutePosition.X + safezone.AbsoluteSize.X)
end


local Window = Fluent:CreateWindow({
    Title = "XT-HUB [1.7]",
    SubTitle = "Sol's RNG",
    TabWidth = (math.clamp((camera and camera.ViewportSize or Vector2.new(1920,1080)).X-50,300,580) < 450) and 120 or 160,
    Size = UDim2.fromOffset(math.clamp((camera and camera.ViewportSize or Vector2.new(1920,1080)).X-50,300,580), math.clamp((camera and camera.ViewportSize or Vector2.new(1920,1080)).Y-50,250,460)),
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.LeftControl
})

local function CreateMobileToggle()
    local ToggleGui = Instance.new("ScreenGui")
    ToggleGui.Name = "XT_MobileToggle"
    ToggleGui.ResetOnSpawn = false
    
    pcall(function()
        local core = game:GetService("CoreGui")
        if gethui then ToggleGui.Parent = gethui()
        elseif core then ToggleGui.Parent = player:WaitForChild("PlayerGui") end
    end)

    local ToggleBtn = Instance.new("TextButton")
    ToggleBtn.Size = UDim2.new(0, 50, 0, 50)
    ToggleBtn.Position = UDim2.new(0.1, 0, 0.1, 0)
    ToggleBtn.BackgroundColor3 = Color3.fromRGB(25, 28, 43)
    ToggleBtn.Text = "XT"
    ToggleBtn.TextColor3 = Color3.fromRGB(46, 204, 113)
    ToggleBtn.TextSize = 24
    ToggleBtn.Font = Enum.Font.GothamBold
    ToggleBtn.Parent = ToggleGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = ToggleBtn

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(46, 204, 113)
    stroke.Thickness = 2
    stroke.Parent = ToggleBtn

    local dragging = false
    local dragInput, mousePos, framePos
    local startPos

    ToggleBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startPos = input.Position
            mousePos = input.Position
            framePos = ToggleBtn.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    ToggleBtn.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - mousePos
            ToggleBtn.Position = UDim2.new(framePos.X.Scale, framePos.X.Offset + delta.X, framePos.Y.Scale, framePos.Y.Offset + delta.Y)
        end
    end)

    ToggleBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            if startPos and (input.Position - startPos).Magnitude < 10 then
                vim:SendKeyEvent(true, Enum.KeyCode.LeftControl, false, game)
                task.wait()
                vim:SendKeyEvent(false, Enum.KeyCode.LeftControl, false, game)
            end
        end
    end)
end
CreateMobileToggle()

local Tabs = {
    Main = Window:AddTab({ Title = "Dashboard", Icon = "home" }),
    Craft = Window:AddTab({ Title = "Auto Craft", Icon = "hammer" }),
    Fishing = Window:AddTab({ Title = "Auto Fish", Icon = "anchor" }),
    Hop = Window:AddTab({ Title = "Auto Hop", Icon = "globe" }),
    Merchant = Window:AddTab({ Title = "NPC/Biome Alerts", Icon = "bell" }),
    Webhook = Window:AddTab({ Title = "Settings", Icon = "settings" })
}

local RollsLabel = Tabs.Main:AddParagraph({ Title = "Total Rolls : --" })
local LuckLabel = Tabs.Main:AddParagraph({ Title = "Current Luck : --" })
local AuraLabel = Tabs.Main:AddParagraph({ Title = "Equipped Aura : --" })

Tabs.Craft:AddParagraph({ Title = "Instructions", Content = "1. Open NPC\n2. Click 'Scan Available Items'\n3. Select up to 3 items\n4. Enable Auto Craft" })

Tabs.Craft:AddButton({
    Title = "Scan Available Items (Open NPC First)",
    Description = "Scans Gear or Item lists dynamically.",
    Callback = function()
        ScannedItemsList = {}
        ScannedItemPaths = {}
        ScannedItemBaseNames = {} 
        CachedTargetButtons = {} 
        local foundCount = 0
        local rawItems = {} 
        
        pcall(function()
            for _, gui in ipairs(player.PlayerGui:GetChildren()) do
                if gui:IsA("ScreenGui") then
                    for _, desc in ipairs(gui:GetDescendants()) do
                        if (desc.Name == "Item" or desc.Name == "Gear" or desc.Name == "Lantern") and desc:IsA("GuiObject") then
                            if desc.AbsoluteSize.Y > 0 then
                                for _, child in ipairs(desc:GetChildren()) do
                                    if child:IsA("GuiObject") and child.Name ~= "UIListLayout" and child.Name ~= "UIGridLayout" and child.Name ~= "UIPadding" and child.Name ~= "Frame" then
                                        
                                        local targetBtn = nil
                                        if child:IsA("ImageButton") or child:IsA("TextButton") then
                                            targetBtn = child
                                        else
                                            targetBtn = child:FindFirstChildWhichIsA("ImageButton", true) or child:FindFirstChildWhichIsA("TextButton", true)
                                        end

                                        if targetBtn then
                                            table.insert(rawItems, {
                                                baseName = child.Name,
                                                btn = targetBtn,
                                                x = child.AbsolutePosition.X,
                                                y = child.AbsolutePosition.Y,
                                                order = child.LayoutOrder or 0
                                            })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
        
        table.sort(rawItems, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            if math.abs(a.y - b.y) > 10 then return a.y < b.y end
            return a.x < b.x
        end)

        for _, itemData in ipairs(rawItems) do
            local baseName = itemData.baseName
            local suffix = 1
            local itemName = baseName
            
            while ScannedItemPaths[itemName] do
                suffix = suffix + 1
                itemName = baseName .. " (" .. suffix .. ")"
            end

            table.insert(ScannedItemsList, itemName)
            ScannedItemPaths[itemName] = itemData.btn
            ScannedItemBaseNames[itemName] = baseName
            foundCount = foundCount + 1
        end

        if foundCount > 0 then
            if _G.MultiCraftDropdown then _G.MultiCraftDropdown:SetValues(ScannedItemsList) end
            Fluent:Notify({ Title = "Scanner", Content = "Found " .. tostring(foundCount) .. " items.", Duration = 3 })
        else
            Fluent:Notify({ Title = "Scanner", Content = "No items found. Please open NPC first.", Duration = 3 })
        end
    end
})

_G.MultiCraftDropdown = Tabs.Craft:AddDropdown("MultiCraftDropdown", {
    Title = "Select Items to Craft (Max 3)",
    Values = {},
    Multi = true,
    Default = {},
})

_G.MultiCraftDropdown:OnChanged(function(Value)
    -- [FIX] ไม่ล้าง ScannedItemPaths / ScannedItemBaseNames ที่นี่
    -- เพราะทำให้ Craft loop หาปุ่มไม่เจอ โดยเฉพาะ Item ที่มีชื่อซ้ำ (เช่น Gear (2))
    -- ล้างแค่ CachedTargetButtons ที่เป็น positional cache เท่านั้น
    CachedTargetButtons = {}

    SelectedMultiItems = {}
    local count = 0
    for k, v in pairs(Value) do
        if v then
            count = count + 1
            if count <= 3 then
                table.insert(SelectedMultiItems, k)
            else
                Fluent:Notify({ Title = "Warning", Content = "You can only select up to 3 items.", Duration = 3 })
            end
        end
    end
    multiCraftIndex = 1
    multiCraftState = "SELECT"
    _G.PopupAddAttempts = 0
end)

CraftTargetLabel = Tabs.Craft:AddParagraph({ Title = "Target", Content = "None (Recipe Closed)" })
CraftStatusLabel = Tabs.Craft:AddParagraph({ Title = "Status", Content = "Waiting" })

local AutoCraftToggle = Tabs.Craft:AddToggle("AutoCraftToggle", { Title = "Enable Auto Craft", Default = false }) 
AutoCraftToggle:OnChanged(function(Value)
    if Value and #SelectedMultiItems == 0 then
        Fluent:Notify({ Title = "Error", Content = "Please select items before enabling Auto Craft.", Duration = 3 })
        if AutoCraftToggle then AutoCraftToggle:SetValue(false) end
        masterAutoEnabled = false
        HubConfig.AutoCraft = false
        SaveConfig()
        return
    end

    masterAutoEnabled = Value
    HubConfig.AutoCraft = Value
    SaveConfig()
end)

Tabs.Fishing:AddParagraph({ Title = "⚠️ Important", Content = "Please close the Chat Box before enabling Auto Fish to prevent accidental clicks." })
local FishStatusLabel = Tabs.Fishing:AddParagraph({ Title = "Status", Content = "Idle" })
local FishBagLabel = Tabs.Fishing:AddParagraph({ Title = "Fish Status", Content = "Rounds: " .. fishingRoundCount .. " / " .. targetFishCount })

local DetectDebugLabel = Tabs.Fishing:AddParagraph({
    Title = "🔍 Real-Time UI Diagnostics",
    Content = "Diagnostics hidden. Enable 'Show Detect Overlay' to view real-time data."
})

local showDetectOverlay = false

local ShowDetectToggle = Tabs.Fishing:AddToggle("ShowDetectToggle", {
    Title = "Show Detect Overlay",
    Default = false
})
ShowDetectToggle:OnChanged(function(Value)
    showDetectOverlay = Value
end)

task.spawn(function()
    while task.wait(1.5) do
        if not DetectDebugLabel then continue end
        if not showDetectOverlay then continue end
        -- [FIX-STUTTER] ข้ามขณะ minigame → ลด CPU
        if _XT.isMinigameActive then continue end

        pcall(function()
            local mainUI = playerGui:FindFirstChild("MainInterface")
            if not mainUI then
                DetectDebugLabel:SetTitle("🔍 Detection Diagnostics [ERROR]")
                DetectDebugLabel:SetDesc("System Error: MainInterface not found. Are you fully loaded into the game?")
                return
            end

            local function checkUIState(targetXOff, targetXScl)
                for _, child in ipairs(mainUI:GetChildren()) do
                    if child:IsA("GuiObject") and child.Visible then
                        local xOff = child.Size.X.Offset
                        local xScl = child.Size.X.Scale
                        if math.abs(xOff - targetXOff) <= 2 or math.abs(xScl - targetXScl) <= 0.005 then
                            local bg = child.BackgroundTransparency
                            return bg <= 0.6 and "Active ✅" or "Standby ⏳"
                        end
                    end
                end
                return "Not Detected ❌"
            end

            local function checkActionState()
                for _, child in ipairs(mainUI:GetChildren()) do
                    if child:IsA("GuiObject") and child.Visible then
                        local xOff = child.Size.X.Offset
                        local xScl = child.Size.X.Scale
                        if math.abs(xOff - 250) <= 2 or math.abs(xScl - 0.185) <= 0.005 then
                            local bg1 = child.BackgroundTransparency
                            task.wait(0.08)
                            local bg2 = child.BackgroundTransparency
                            local isAnimating = math.abs(bg1 - bg2) >= 0.05
                            local isActive = bg1 <= 0.6
                            
                            if isAnimating then
                                return "Processing (Animating) 🔄"
                            elseif isActive then
                                return "Ready to Click ✅"
                            else
                                return "Standby ⏳"
                            end
                        end
                    end
                end
                return "Not Detected ❌"
            end

            local fishStatus  = checkUIState(201, 0.122)
            local miniStatus  = checkUIState(230, 0.140)
            local actStatus   = checkActionState()

            local actionPosStatus = "Unavailable"
            pcall(function()
                local actBtnDiag, _ = findActionBtnFast(mainUI)
                if actBtnDiag and actBtnDiag.Visible then
                    local pos = actBtnDiag.Position
                    local xScaleOK = math.abs(pos.X.Scale - 1) < 0.05
                    local xOffOK   = math.abs(pos.X.Offset)    < 5
                    local yOK      = math.abs(pos.Y.Scale)      < 0.05 and math.abs(pos.Y.Offset) < 5
                    local ready = xScaleOK and xOffOK and yOK
                    actionPosStatus = ready and "In Position ✅" or "Moving... 🔄"
                end
            end)

            DetectDebugLabel:SetTitle("🔍 Real-Time UI Diagnostics")
            DetectDebugLabel:SetDesc(
                "▶ Fishing Interface    :  " .. fishStatus .. "\n" ..
                "▶ Minigame Event       :  " .. miniStatus .. "\n" ..
                "▶ Action Button        :  " .. actStatus .. "\n" ..
                "▶ Button Alignment     :  " .. actionPosStatus .. "\n\n" ..
                "Current Sequence Step  :  " .. tostring(fishingStep)
            )
        end)
    end
end)


local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "DetectOverlayGui"
overlayGui.ResetOnSpawn = false
overlayGui.IgnoreGuiInset = true
overlayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
overlayGui.DisplayOrder = 999
pcall(function()
    overlayGui.Parent = (gethui and gethui()) or playerGui
end)
if not overlayGui.Parent then overlayGui.Parent = playerGui end

local function makeBox(name, color)
    local box = {}
    local sides = {"Top","Bottom","Left","Right"}
    for _, side in ipairs(sides) do
        local f = Instance.new("Frame")
        f.Name = name .. "_" .. side
        f.BackgroundColor3 = color
        f.BorderSizePixel = 0
        f.ZIndex = 1000
        f.Parent = overlayGui
        box[side] = f
    end
    return box
end

local function updateBox(box, ax, ay, aw, ah, thickness)
    thickness = thickness or 2
    box.Top.Position    = UDim2.new(0, ax,           0, ay)
    box.Top.Size        = UDim2.new(0, aw,            0, thickness)
    box.Bottom.Position = UDim2.new(0, ax,           0, ay + ah - thickness)
    box.Bottom.Size     = UDim2.new(0, aw,            0, thickness)
    box.Left.Position   = UDim2.new(0, ax,           0, ay)
    box.Left.Size       = UDim2.new(0, thickness,     0, ah)
    box.Right.Position  = UDim2.new(0, ax + aw - thickness, 0, ay)
    box.Right.Size      = UDim2.new(0, thickness,     0, ah)
end

local function setBoxVisible(box, visible)
    for _, f in pairs(box) do f.Visible = visible end
end

local boxFish     = makeBox("Fish",     Color3.fromRGB(80,  200, 120))
local boxMini     = makeBox("Minigame", Color3.fromRGB(80,  160, 255))
local boxAction   = makeBox("Action",   Color3.fromRGB(255, 180,  50))
local boxConfirm  = makeBox("Confirm",  Color3.fromRGB(255,  80,  80))

local function makeLabel(name, color)
    local lbl = Instance.new("TextLabel")
    lbl.Name = name .. "_Label"
    lbl.BackgroundColor3 = color
    lbl.BackgroundTransparency = 0.3
    lbl.TextColor3 = Color3.new(1,1,1)
    lbl.TextSize = 11
    lbl.Font = Enum.Font.GothamBold
    lbl.Size = UDim2.new(0, 60, 0, 16)
    lbl.ZIndex = 1001
    lbl.Text = name
    lbl.Parent = overlayGui
    return lbl
end

local lblFish    = makeLabel("Fish",     Color3.fromRGB(80,  200, 120))
local lblMini    = makeLabel("Minigame", Color3.fromRGB(80,  160, 255))
local lblAction  = makeLabel("Action",   Color3.fromRGB(255, 180,  50))
local lblConfirm = makeLabel("Confirm",  Color3.fromRGB(255,  80,  80))

local inset = guiService:GetGuiInset()

-- [OPT-v2] ช้าลงจาก 0.25s → 0.4s overlay ไม่ต้อง update เร็ว
-- และ skip งานทั้งหมดทันทีถ้า overlay ปิด
task.spawn(function()
    local overlayWasVisible = false
    while task.wait(0.4) do
        if not showDetectOverlay then
            if overlayWasVisible then
                overlayWasVisible = false
                setBoxVisible(boxFish, false)
                setBoxVisible(boxMini, false)
                setBoxVisible(boxAction, false)
                setBoxVisible(boxConfirm, false)
                lblFish.Visible, lblMini.Visible, lblAction.Visible, lblConfirm.Visible = false, false, false, false
            end
            continue
        end
        -- [FIX-STUTTER] ข้ามขณะ minigame active → ลด CPU spike
        if _XT.isMinigameActive then continue end
        overlayWasVisible = true

        pcall(function()
            local mainUI = playerGui:FindFirstChild("MainInterface")
            if not mainUI then
                setBoxVisible(boxFish, false); setBoxVisible(boxMini, false)
                setBoxVisible(boxAction, false); setBoxVisible(boxConfirm, false)
                lblFish.Visible, lblMini.Visible, lblAction.Visible, lblConfirm.Visible = false, false, false, false
                return
            end

            local fishFound = false
            for _, child in ipairs(mainUI:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then
                    local xOff, xScl = child.Size.X.Offset, child.Size.X.Scale
                    if math.abs(xOff - 201) <= 2 or math.abs(xScl - 0.122) <= 0.005 then
                        local ap = child.AbsolutePosition
                        local as = child.AbsoluteSize
                        updateBox(boxFish, ap.X, ap.Y + inset.Y, as.X, as.Y)
                        setBoxVisible(boxFish, true)
                        lblFish.Position = UDim2.new(0, ap.X, 0, ap.Y + inset.Y - 16)
                        lblFish.Visible = true
                        fishFound = true
                        break
                    end
                end
            end
            if not fishFound then setBoxVisible(boxFish, false); lblFish.Visible = false end

            local miniFound = false
            for _, child in ipairs(mainUI:GetChildren()) do
                if child:IsA("GuiObject") and child.Visible then
                    local xOff, xScl = child.Size.X.Offset, child.Size.X.Scale
                    if math.abs(xOff - 230) <= 2 or math.abs(xScl - 0.140) <= 0.005 then
                        local ap = child.AbsolutePosition
                        local as = child.AbsoluteSize
                        updateBox(boxMini, ap.X, ap.Y + inset.Y, as.X, as.Y)
                        setBoxVisible(boxMini, true)
                        lblMini.Position = UDim2.new(0, ap.X, 0, ap.Y + inset.Y - 16)
                        lblMini.Visible = true
                        miniFound = true
                        break
                    end
                end
            end
            if not miniFound then setBoxVisible(boxMini, false); lblMini.Visible = false end

            local actionFound = false
            local actBtn, _ = findActionBtnFast(mainUI, true)
            if actBtn then
                local ap = actBtn.AbsolutePosition
                local as = actBtn.AbsoluteSize
                updateBox(boxAction, ap.X, ap.Y + inset.Y, as.X, as.Y, 2)
                setBoxVisible(boxAction, true)
                lblAction.Position = UDim2.new(0, ap.X, 0, ap.Y + inset.Y - 16)
                lblAction.Visible = true
                actionFound = true

                local confirmFound = false
                for _, child in ipairs(actBtn:GetChildren()) do
                    if child:IsA("ImageLabel") and child.Visible and child.AbsoluteSize.X > 0 then
                        local cap = child.AbsolutePosition
                        local cas = child.AbsoluteSize
                        updateBox(boxConfirm, cap.X, cap.Y + inset.Y, cas.X, cas.Y, 2)
                        setBoxVisible(boxConfirm, true)
                        lblConfirm.Position = UDim2.new(0, cap.X, 0, cap.Y + inset.Y - 16)
                        lblConfirm.Visible = true
                        confirmFound = true
                        break
                    end
                end
                if not confirmFound then setBoxVisible(boxConfirm, false); lblConfirm.Visible = false end
            end
            if not actionFound then
                setBoxVisible(boxAction, false); lblAction.Visible = false
                setBoxVisible(boxConfirm, false); lblConfirm.Visible = false
            end
        end)
    end
end)

local AutoFishToggle = Tabs.Fishing:AddToggle("AutoFishToggle", { Title = "Enable Auto Fish", Default = HubConfig.AutoFish })
AutoFishToggle:OnChanged(function(Value)
    autoFarmEnabled = Value
    HubConfig.AutoFish = Value
    SaveConfig()
    
    if not Value then
        FishStatusLabel:SetDesc("Status: Idle")
        isAtTarget = false
        hasArrivedAtSell = false
        isResettingUI = false 
        fishingStep = 0
        hasMinigameMoved = false
        
        cachedSafeZone, cachedDiamond, cachedExtraBtn, cachedFishBtn = nil, nil, nil, nil

        if player.Character and player.Character:FindFirstChild("Humanoid") then
            player.Character.Humanoid:MoveTo(player.Character.HumanoidRootPart.Position)
        end
    else
        FishStatusLabel:SetDesc("Initializing Farm...")
    end
end)

local AutoSellToggle = Tabs.Fishing:AddToggle("AutoSellToggle", { Title = "Enable Auto Sell", Default = HubConfig.AutoSell })
AutoSellToggle:OnChanged(function(Value)
    autoSellEnabled = Value
    HubConfig.AutoSell = Value
    SaveConfig()
    if not Value then
        isSellingProcess = false
    end
end)

Tabs.Fishing:AddInput("FishLimitInput", {
    Title = "Max Rounds Before Sell",
    Default = tostring(HubConfig.MaxFish),
    Placeholder = "50",
    Numeric = true,
    Finished = true,
    Callback = function(Value)
        local num = tonumber(Value)
        if num and num > 0 then
            targetFishCount = num
            HubConfig.MaxFish = num
            SaveConfig()
            if FishBagLabel then FishBagLabel:SetDesc("Rounds: " .. fishingRoundCount .. " / " .. targetFishCount) end
        end
    end
})

CurrentBiomeLabel = Tabs.Hop:AddParagraph({ Title = "Current Biome", Content = "Scanning..." })
HopStatusLabel = Tabs.Hop:AddParagraph({ Title = "Status", Content = "Idle" })

local HopDropdown = Tabs.Hop:AddDropdown("HopBiomeDropdown", { Title = "Select Target Biome", Values = biomeNames, Multi = false, Default = HubConfig.HopBiome })
HopDropdown:OnChanged(function(Value)
    targetBiome = Value
    HubConfig.HopBiome = Value
    SaveConfig()
end)

local AutoHopToggle = Tabs.Hop:AddToggle("AutoHopToggle", { Title = "Enable Auto Server Hop", Default = false }) 
AutoHopToggle:OnChanged(function(Value)
    enableAutoHop = Value
    HubConfig.AutoHop = Value
    SaveConfig()
end)

local MariInput = Tabs.Merchant:AddInput("MariUrlInput", { Title = "Mari Webhook URL", Default = HubConfig.MariUrl, Placeholder = "Webhook URL...", Numeric = false, Finished = true })
MariInput:OnChanged(function(Value) Webhooks.Mari.Url = Value; HubConfig.MariUrl = Value; SaveConfig() end)
local MariToggle = Tabs.Merchant:AddToggle("MariToggle", { Title = "Enable Mari Alert", Default = HubConfig.MariOn })
MariToggle:OnChanged(function(Value) Webhooks.Mari.Enabled = Value; HubConfig.MariOn = Value; SaveConfig() end)
Tabs.Merchant:AddButton({
    Title = "Test Mari Webhook",
    Callback = function()
        local oldState = Webhooks.Mari.Enabled
        Webhooks.Mari.Enabled = true
        SendMerchantWebhook("Mari", true, false)
        Webhooks.Mari.Enabled = oldState
        Fluent:Notify({ Title = "Webhook Test", Content = "Test payload sent for Mari.", Duration = 3 })
    end
})

local RinInput = Tabs.Merchant:AddInput("RinUrlInput", { Title = "Rin Webhook URL", Default = HubConfig.RinUrl, Placeholder = "Webhook URL...", Numeric = false, Finished = true })
RinInput:OnChanged(function(Value) Webhooks.Rin.Url = Value; HubConfig.RinUrl = Value; SaveConfig() end)
local RinToggle = Tabs.Merchant:AddToggle("RinToggle", { Title = "Enable Rin Alert", Default = HubConfig.RinOn })
RinToggle:OnChanged(function(Value) Webhooks.Rin.Enabled = Value; HubConfig.RinOn = Value; SaveConfig() end)
Tabs.Merchant:AddButton({
    Title = "Test Rin Webhook",
    Callback = function()
        local oldState = Webhooks.Rin.Enabled
        Webhooks.Rin.Enabled = true
        SendMerchantWebhook("Rin", true, false)
        Webhooks.Rin.Enabled = oldState
        Fluent:Notify({ Title = "Webhook Test", Content = "Test payload sent for Rin.", Duration = 3 })
    end
})

local JesterInput = Tabs.Merchant:AddInput("JesterUrlInput", { Title = "Jester Webhook URL", Default = HubConfig.JesterUrl, Placeholder = "Webhook URL...", Numeric = false, Finished = true })
JesterInput:OnChanged(function(Value) Webhooks.Jester.Url = Value; HubConfig.JesterUrl = Value; SaveConfig() end)
local JesterToggle = Tabs.Merchant:AddToggle("JesterToggle", { Title = "Enable Jester Alert", Default = HubConfig.JesterOn })
JesterToggle:OnChanged(function(Value) Webhooks.Jester.Enabled = Value; HubConfig.JesterOn = Value; SaveConfig() end)
Tabs.Merchant:AddButton({
    Title = "Test Jester Webhook",
    Callback = function()
        local oldState = Webhooks.Jester.Enabled
        Webhooks.Jester.Enabled = true
        SendMerchantWebhook("Jester", true, false)
        Webhooks.Jester.Enabled = oldState
        Fluent:Notify({ Title = "Webhook Test", Content = "Test payload sent for Jester.", Duration = 3 })
    end
})

local WhIntervalSlider = Tabs.Webhook:AddSlider("WhInterval", { Title = "Send Interval (Seconds)", Description = "Time between saves", Default = HubConfig.WhInterval, Min = 10, Max = 60, Rounding = 1 })
WhIntervalSlider:OnChanged(function(Value) 
    saveIntervalSeconds = tonumber(Value) or 60
    HubConfig.WhInterval = saveIntervalSeconds
    SaveConfig() 
end)

local ScanDelaySlider = Tabs.Webhook:AddSlider("ScanDelay", { 
    Title = "Scanner Cooldown (Reduce Lag)", 
    Description = "Increase this if your game is lagging (Seconds)", 
    Default = HubConfig.ScanDelay or 2.5, 
    Min = 0.5, 
    Max = 5.0, 
    Rounding = 1 
})
ScanDelaySlider:OnChanged(function(Value) 
    scanCooldown = tonumber(Value) or 2.5
    HubConfig.ScanDelay = scanCooldown
    SaveConfig() 
end)

local WebhookToggle = Tabs.Webhook:AddToggle("WebhookToggle", { Title = "Enable Auto-Save Data to Web", Default = HubConfig.WhOn })
WebhookToggle:OnChanged(function(Value) isInfoWebhookEnabled = Value; HubConfig.WhOn = Value; SaveConfig() end)

local WebNameLabel = Tabs.Webhook:AddParagraph({ Title = "Web Display Name", Content = (isIncognitoMode and incognitoFakeName or playerName) })
local IncognitoToggle = Tabs.Webhook:AddToggle("IncognitoToggle", { Title = "Enable Incognito Mode (Hide Name)", Default = HubConfig.Incognito })
IncognitoToggle:OnChanged(function(Value)
    isIncognitoMode = Value
    HubConfig.Incognito = Value
    SaveConfig()
    if Value then
        WebNameLabel:SetDesc(incognitoFakeName)
    else
        WebNameLabel:SetDesc(playerName)
    end
end)

Tabs.Webhook:AddParagraph({ Title = "Information", Content = "Developed by XT-HUB [1.7]" })

-- ==========================================
-- [ADD] Biome Webhook UI
-- ==========================================
Tabs.Merchant:AddParagraph({ Title = "── Biome Alert ──", Content = "<3" })

local BiomeInput = Tabs.Merchant:AddInput("BiomeUrlInput", {
    Title = "Biome Alert Webhook URL",
    Default = HubConfig.BiomeUrl or "",
    Placeholder = "Webhook URL...",
    Numeric = false,
    Finished = true
})
BiomeInput:OnChanged(function(Value)
    Webhooks.Biome.Url = Value
    HubConfig.BiomeUrl = Value
    SaveConfig()
end)

local BiomeWhDropdown = Tabs.Merchant:AddDropdown("BiomeWhDropdown", {
    Title = "Target Biome to Alert",
    Values = biomeNames,
    Multi = false,
    Default = HubConfig.BiomeTarget or "Heaven"
})
BiomeWhDropdown:OnChanged(function(Value)
    HubConfig.BiomeTarget = Value
    SaveConfig()
end)

local BiomeToggle = Tabs.Merchant:AddToggle("BiomeToggle", {
    Title = "Enable Biome Alert",
    Default = HubConfig.BiomeOn or false
})
BiomeToggle:OnChanged(function(Value)
    Webhooks.Biome.Enabled = Value
    HubConfig.BiomeOn = Value
    SaveConfig()
end)

Tabs.Merchant:AddButton({
    Title = "Test Biome Webhook",
    Callback = function()
        local oldState = Webhooks.Biome.Enabled
        Webhooks.Biome.Enabled = true
        SendBiomeWebhook(CurrentBiomeCache ~= "" and CurrentBiomeCache or "Normal")
        Webhooks.Biome.Enabled = oldState
        Fluent:Notify({ Title = "Webhook Test", Content = "Test Biome payload sent.", Duration = 3 })
    end
})

Window:SelectTab(1)

task.spawn(function()
    local lastBiomeForWebhook = ""
    while true do
        -- [OPT-v2] Adaptive scan rate: hop active = scanCooldown, idle = 2x slower
        local actualDelay = enableAutoHop and scanCooldown or (scanCooldown * 2)
        task.wait(actualDelay)
        local currentText = GetRealBiomeText()
        if currentText then
            local cleanBiome = currentText:gsub("%[", ""):gsub("%]", ""):match("^%s*(.-)%s*$")
            cleanBiome = cleanBiome:lower():gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
            CurrentBiomeCache = cleanBiome

            -- [ADD] Biome Webhook: แจ้งเตือนเมื่อ Biome เปลี่ยนเป็น target ที่ตั้งไว้
            if Webhooks.Biome.Enabled and Webhooks.Biome.Url ~= "" then
                local biomeTarget = HubConfig.BiomeTarget or "Heaven"
                if cleanBiome == biomeTarget and lastBiomeForWebhook ~= biomeTarget then
                    SendBiomeWebhook(cleanBiome)
                    Fluent:Notify({ Title = "Biome Alert!", Content = biomeTarget .. " biome detected! Webhook sent.", Duration = 6 })
                end
            end
            lastBiomeForWebhook = cleanBiome
        else
            CurrentBiomeCache = "Normal"
            lastBiomeForWebhook = "Normal"
        end

        if CurrentBiomeLabel then CurrentBiomeLabel:SetDesc(CurrentBiomeCache) end

        if not enableAutoHop or isHopping then continue end
        if currentText then
            local lowerText = string.lower(currentText)
            local keywords = BiomeList[targetBiome] or {"heaven"} 
            local isFound = false
            for _, kw in ipairs(keywords) do
                if string.find(lowerText, kw) then isFound = true; break end
            end
            
            if isFound then
                if HopStatusLabel then HopStatusLabel:SetDesc("Found Biome: " .. currentText) end
            else
                if HopStatusLabel then HopStatusLabel:SetDesc("Skipping: " .. currentText) end
                task.wait(1)
                ServerHop()
            end
        else
            if HopStatusLabel then HopStatusLabel:SetDesc("Scanning...") end
        end
    end
end)

local DetectQueue = {}
local isProcessingDetect = false

local function ProcessDetectQueue()
    if isProcessingDetect then return end
    isProcessingDetect = true
    task.spawn(function()
        while #DetectQueue > 0 do
            local entityName = table.remove(DetectQueue, 1)
            
            table.insert(NPCHistoryList, 1, {
                name = entityName,
                biome = CurrentBiomeCache,
                timestamp = os.time()
            })
            -- [FIX] ลดจาก 20 → 8 ให้ตรงกับ cleanup cycle cap
            if #NPCHistoryList > 8 then table.remove(NPCHistoryList, 9) end
            
            SendMerchantWebhook(entityName, false, false)
            ShowGameNotification(entityName)
            
            task.spawn(function()
                task.wait(180) 
                SendMerchantWebhook(entityName, false, true)
            end)

            task.wait(3)
        end
        isProcessingDetect = false
    end)
end

local function HandleNPCDetection(entityName)
    if entityName and entityName ~= lastDetectedNPC then
        lastDetectedNPC = entityName
        table.insert(DetectQueue, entityName)
        ProcessDetectQueue()
        task.delay(10, function() lastDetectedNPC = "" end)
    end
end

function SendToWebAPI(combinedItems, aurasTable, auraRollJson)
    if CustomWebAPIUrl == "" then return end
    if not httpRequest then 
        return 
    end
    
    local success, payload = pcall(function()
        return {
            roblox_id = player.UserId,
            username = playerName,
            is_incognito = isIncognitoMode,
            rolls = tonumber(GetPlayerRolls()) or 0, 
            luck = tonumber(GetPlayerLuck()) or 1, 
		    equipped_aura = GetEquippedAura() or "Normal", 
            auto_fish = autoFarmEnabled,                   
            auto_sell = autoSellEnabled,                   
            fish_limit = targetFishCount,                  
            sell_count = totalSellCount,                   
            inventory = combinedItems or {},
            auras = aurasTable or {}, 
            aura_roll = auraRollJson or "[]",
            current_biome = CurrentBiomeCache,
            craft_target = CurrentCraftTarget,
            craft_ready = IsCraftReady,
            craft_materials = CurrentCraftMaterials, 
            craft_count = CraftSessionCount,
            craft_logs = CraftLogs,
            auto_craft_enabled = masterAutoEnabled, 
            npc_history = HttpService:JSONEncode(NPCHistoryList)
        }
    end)

    if not success then return end
    
    table.insert(ApiQueue, payload)
    ProcessApiQueue()
end

if TextChatService then
    TextChatService.MessageReceived:Connect(function(message)
        if not message.Text then return end
        
        if not enableAuraDetect and not string.find(message.Text, "merchant") then return end

        local cleanText = StripRichText(message.Text)
        local lowerMsg = cleanText:lower()

        if lowerMsg:find("%[merchant%]") then
            if lowerMsg:find("mari") then HandleNPCDetection("Mari")
            elseif lowerMsg:find("rin") then HandleNPCDetection("Rin")
            elseif lowerMsg:find("jester") then HandleNPCDetection("Jester") end
        end

        if enableAuraDetect then
            local playerPart, auraPart, chancePart = cleanText:match("^(.-)%s*HAS FOUND(.-), CHANCE OF 1 IN (.+)")
            if playerPart and chancePart then
                if playerPart:find(player.Name) or playerPart:find(player.DisplayName) then
                    local cleanNumStr = chancePart:gsub("%D", "") 
                    local rarity = tonumber(cleanNumStr) or 0
                    
                    if rarity >= minAuraRarity and rarity <= maxAuraRarity then
                        local finalAuraName = CleanAuraName(auraPart)
                        table.insert(AuraQueue, {name = finalAuraName, rarity = rarity, timestamp = os.time()})
                    end
                end
            end
        end
    end)
end

-- [FIX] ChildAdded ตรวจแค่ลูกตรงๆ ของ Workspace
-- ถ้า NPC อยู่ใน folder จะไม่ถูก detect เลย
-- เพิ่ม DescendantAdded + scan loop เป็น backup

_XT.npcNames = {Mari = true, Rin = true, Jester = true}

Workspace.DescendantAdded:Connect(function(obj)
    if obj:IsA("Model") and _XT.npcNames[obj.Name] then
        task.wait(0.1)
        if obj.Parent then
            HandleNPCDetection(obj.Name)
        end
    end
end)

-- [OPT-v2] scan loop backup: ทุก 12s ตรวจ Workspace — single pass
-- เพิ่มจาก 8s เพราะมี DescendantAdded เป็น primary แล้ว backup ไม่ต้องถี่
task.spawn(function()
    local lastSeen = {}
    while task.wait(12) do
        pcall(function()
            local currentlySeen = {}
            -- สแกนเฉพาะ children ตรงของ Workspace + folder ลึก 1 ชั้น
            -- NPC ใน Sol's RNG จะ spawn อยู่ตรง Workspace หรือใน folder ลึกไม่เกิน 2 ชั้น
            local function scanFolder(parent)
                for _, obj in ipairs(parent:GetChildren()) do
                    if obj:IsA("Model") then
                        if _XT.npcNames[obj.Name] and obj.Parent then
                            currentlySeen[obj.Name] = true
                            if not lastSeen[obj.Name] then
                                HandleNPCDetection(obj.Name)
                            end
                        end
                    elseif obj:IsA("Folder") or obj:IsA("WorldModel") then
                        -- ลงลึกแค่ 1 ชั้นใน folder
                        for _, child in ipairs(obj:GetChildren()) do
                            if child:IsA("Model") and _XT.npcNames[child.Name] and child.Parent then
                                currentlySeen[child.Name] = true
                                if not lastSeen[child.Name] then
                                    HandleNPCDetection(child.Name)
                                end
                            end
                        end
                    end
                end
            end
            scanFolder(Workspace)
            lastSeen = currentlySeen
        end)
    end
end)

local function AutoSaveToWebAPI()
    task.spawn(function()
        -- [FIX-STUTTER] รอ minigame จบก่อนทำ heavy scan
        while _XT.isMinigameActive do task.wait(0.5) end
        local combinedItems = {}
        for k, v in pairs(ScanGear()) do combinedItems[k] = v end
        task.wait(0.4) -- [OPT-v2] เพิ่ม yield จาก 0.2 → 0.4 ลด spike
        for k, v in pairs(ScanPotions()) do combinedItems[k] = (combinedItems[k] or 0) + v end
        task.wait(0.4)
        local aurasData = GetAuraTableData()
        task.wait(0.2) -- [OPT-v2] yield ก่อน encode + send
        SendToWebAPI(combinedItems, aurasData, "[]")
    end)
end

task.spawn(function()
    -- [OPT-v2] 5s → 10s — aura queue ไม่ค่อยมี data เข้ามาบ่อย
    while task.wait(10) do
        if #AuraQueue > 0 then
            local aurasToProcess = {}
            local limit = math.min(#AuraQueue, 20)
            for i = 1, limit do aurasToProcess[i] = AuraQueue[i] end
            AuraQueue = {}
            
            local success, jsonStr = pcall(function() return HttpService:JSONEncode(aurasToProcess) end)
            if success then
                lastAuraRollJson = jsonStr
                task.spawn(function()
                    -- [FIX-STUTTER] รอ minigame จบก่อนทำ heavy scan
                    while _XT.isMinigameActive do task.wait(0.5) end
                    local inv = {}
                    for k, v in pairs(ScanGear()) do inv[k] = v end
                    task.wait(0.3)
                    for k, v in pairs(ScanPotions()) do inv[k] = (inv[k] or 0) + v end
                    task.wait(0.3)
                    SendToWebAPI(inv, GetAuraTableData(), lastAuraRollJson)
                end)
            end
        end
    end
end)

task.spawn(function()
    while task.wait(30) do
        -- [FIX-STUTTER] defer heavy scan ขณะ minigame
        if _XT.isMinigameActive then continue end
        pcall(function()
            local rolls = GetPlayerRolls()
            if RollsLabel then RollsLabel:SetTitle("Total Rolls : " .. FormatNumber(rolls)) end
        end)
        task.wait(0.1) -- [OPT-v2] yield ระหว่าง calls ลด spike
        pcall(function()
            local luck = GetPlayerLuck()
            if LuckLabel then LuckLabel:SetTitle("Current Luck : x" .. string.format("%.2f", tonumber(luck) or 1)) end
        end)
        task.wait(0.1)
        pcall(function()
            local aura = GetEquippedAura()
            if AuraLabel then AuraLabel:SetTitle("Equipped Aura : " .. tostring(aura)) end
        end)
    end
end)

_XT.lastWebhookSendTick = tick()
task.spawn(function()
    while task.wait(20) do
        -- [FIX-STUTTER] defer ขณะ minigame active
        if _XT.isMinigameActive then continue end
        local safeInterval = tonumber(saveIntervalSeconds) or 60
        if isInfoWebhookEnabled and (tick() - _XT.lastWebhookSendTick >= safeInterval) then
            _XT.lastWebhookSendTick = tick()
            task.spawn(AutoSaveToWebAPI)
        end
    end
end)

local function ProcessPopupIngredients(popupRoot)
    local scrollingFrame = nil
    for _, child in pairs(popupRoot:GetDescendants()) do
        if child:IsA("ScrollingFrame") then
            scrollingFrame = child
            break
        end
    end

    local allReady = true
    local clickedAdd = false

    local addButtons = {}
    for _, btn in pairs(popupRoot:GetDescendants()) do
        if btn:IsA("GuiButton") and btn.Visible then
            local txt = string.lower(TrimString(getButtonText(btn)))
            if txt == "add" then
                table.insert(addButtons, btn)
            end
        end
    end

    table.sort(addButtons, function(a, b)
        return a.AbsolutePosition.Y < b.AbsolutePosition.Y
    end)

    for _, addBtn in ipairs(addButtons) do
        local foundRatioOrCheck = false
        local isComplete = false
        
        local function checkNodeForCompletion(node)
            local _found = false
            local _complete = false
            for _, lbl in pairs(node:GetDescendants()) do
                if lbl:IsA("TextLabel") then
                    local rawTxt = lbl.Text
                    pcall(function() if lbl.ContentText and lbl.ContentText ~= "" then rawTxt = lbl.ContentText end end)
                    local txt = string.gsub(StripRichText(rawTxt), ",", "")
                    local c, r = string.match(txt, "(%d+)%s*/%s*(%d+)")
                    if c and r then
                        _found = true
                        if tonumber(c) >= tonumber(r) then _complete = true end
                        break
                    end
                end
            end
            if not _found then
                for _, img in pairs(node:GetDescendants()) do
                    if img:IsA("ImageLabel") then
                        local imgName = string.lower(img.Name)
                        if string.find(imgName, "check") or string.find(imgName, "tick") or string.find(imgName, "success") or img.ImageColor3 == Color3.fromRGB(0, 255, 0) or img.ImageColor3 == Color3.fromRGB(85, 255, 0) then
                            _found = true
                            _complete = true
                            break
                        end
                    end
                end
            end
            return _found, _complete
        end

        foundRatioOrCheck, isComplete = checkNodeForCompletion(addBtn.Parent)
        if not foundRatioOrCheck and addBtn.Parent and addBtn.Parent.Parent then
            foundRatioOrCheck, isComplete = checkNodeForCompletion(addBtn.Parent.Parent)
        end
        if not foundRatioOrCheck and addBtn.Parent and addBtn.Parent.Parent and addBtn.Parent.Parent.Parent then
            foundRatioOrCheck, isComplete = checkNodeForCompletion(addBtn.Parent.Parent.Parent)
        end

        if not foundRatioOrCheck then
            isComplete = false
        end

        if not isComplete then
            allReady = false
            
            if scrollingFrame then
                local maxCanvasY = 99999
                pcall(function()
                    if scrollingFrame.AbsoluteCanvasSize and scrollingFrame.AbsoluteCanvasSize.Y > 0 then
                        maxCanvasY = math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
                    elseif scrollingFrame.CanvasSize.Y.Offset > 0 then
                        maxCanvasY = math.max(0, scrollingFrame.CanvasSize.Y.Offset - scrollingFrame.AbsoluteWindowSize.Y)
                    end
                end)

                local btnY = addBtn.AbsolutePosition.Y
                local scrollY = scrollingFrame.AbsolutePosition.Y
                local scrollHeight = scrollingFrame.AbsoluteWindowSize and scrollingFrame.AbsoluteWindowSize.Y or scrollingFrame.AbsoluteSize.Y
                
                if btnY < scrollY - 10 or btnY + addBtn.AbsoluteSize.Y > scrollY + scrollHeight + 10 then
                    local targetCanvasY = scrollingFrame.CanvasPosition.Y + (btnY - scrollY) - (scrollHeight / 2)
                    targetCanvasY = math.clamp(targetCanvasY, 0, maxCanvasY)
                    
                    scrollingFrame.CanvasPosition = Vector2.new(0, targetCanvasY)
                    task.wait(0.3) 
                end
            end

            forceCraftClick(addBtn) 
            clickedAdd = true
            task.wait(0.4) 
        end
    end

    return allReady, clickedAdd
end

_XT.cachedRecipeHolder = nil
_XT.cachedButtons = { open = nil, auto = nil, craft = nil }

local function isObjectActuallyVisible(obj)
    local current = obj
    while current and current ~= game do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        current = current.Parent
    end
    return true
end

_G.IsCraftingExpected = false

-- [OPT] Cached popup finder — ลด GetDescendants จาก 2 จุดเหลือ 1 ครั้งต่อรอบ
_XT._cachedPopupRoot = nil
_XT._popupSearchTick = 0
local function findAddIngredientsPopup(forceRefresh)
    if not forceRefresh and _XT._cachedPopupRoot and (tick() - _XT._popupSearchTick) < 0.5 then
        -- [FIX] pcall return value คือ success bool ไม่ใช่ผลลัพธ์ ต้องตรวจ condition ข้างใน
        local isValid = false
        pcall(function()
            isValid = _XT._cachedPopupRoot.Parent ~= nil and _XT._cachedPopupRoot.Visible
        end)
        if isValid then return _XT._cachedPopupRoot end
    end
    _XT._cachedPopupRoot = nil
    _XT._popupSearchTick = tick()
    pcall(function()
        -- [OPT-v2] scan เฉพาะ ScreenGui ที่เกี่ยวข้อง แทน playerGui:GetDescendants() ทั้งหมด
        for _, gui in ipairs(playerGui:GetChildren()) do
            if not gui:IsA("ScreenGui") then continue end
            for _, desc in ipairs(gui:GetDescendants()) do
                if desc:IsA("TextLabel") and desc.Visible and string.lower(TrimString(desc.Text)) == "add ingredients" then
                    _XT._cachedPopupRoot = desc.Parent
                    return
                end
            end
        end
    end)
    return _XT._cachedPopupRoot
end

task.spawn(function()
    while task.wait(scanCooldown) do
        if not masterAutoEnabled then
            if CraftStatusLabel then CraftStatusLabel:SetDesc("Idle (Auto Craft Off)") end
            continue
        end

        local isRecipeOpen = false
        local holder = nil
        local currentItemName = "Unknown Item"
        local isReadyToCraft = true 
        local hasIngredients = false
        local tempMaterialsArray = {}

        pcall(function()
            if not _XT.cachedRecipeHolder or not _XT.cachedRecipeHolder.Parent then
                for _, h in pairs(playerGui:GetDescendants()) do
                    if h.Name == "indexIngredientsHolder" and h:IsA("GuiObject") then
                        _XT.cachedRecipeHolder = h
                        break
                    end
                end
            end

            if _XT.cachedRecipeHolder then
                holder = _XT.cachedRecipeHolder
                if holder.AbsoluteSize.Y > 20 and holder.Visible then
                    isRecipeOpen = true
                    
                    local uiRoot = holder.Parent.Parent.Parent 
                    local largestTextSize = 0
                    for _, obj in pairs(uiRoot:GetDescendants()) do
                        if obj:IsA("TextLabel") and obj.Text ~= "" and obj.Visible then
                            local t = obj.Text
                            if not string.find(t, "/") and not string.find(t, "%- Recipe %-") and t ~= "Open Recipe" and t ~= "Auto" and t ~= "Craft" then
                                if obj.TextSize > largestTextSize then
                                    largestTextSize = obj.TextSize
                                    currentItemName = t
                                end
                            end
                        end
                    end

                    for _, itemFrame in pairs(holder:GetChildren()) do
                        if itemFrame:IsA("Frame") or itemFrame:IsA("GuiButton") then
                            hasIngredients = true
                            local matName = "Unknown"
                            local matCur = 0
                            local matReq = 0
                            local addBtn = nil
                            
                            for _, label in pairs(itemFrame:GetDescendants()) do
                                if label:IsA("TextLabel") and label.Text ~= "" then
                                    local txtStr = label.Text
                                    if string.find(txtStr, "/") and string.find(txtStr, "%(") then
                                        local cleanTxt = string.gsub(txtStr, "[%s%,%(%)]", "")
                                        local splitData = string.split(cleanTxt, "/")
                                        if #splitData == 2 then
                                            matCur = tonumber(splitData[1]) or 0
                                            matReq = tonumber(splitData[2]) or 0
                                            if matCur < matReq then
                                                isReadyToCraft = false 
                                            end
                                        end
                                    elseif not tonumber(txtStr) and txtStr:lower() ~= "add" and not string.find(txtStr:lower(), "everything") then
                                        if label.Parent and not label.Parent:IsA("GuiButton") then
                                            matName = TrimString(txtStr)
                                        end
                                    end
                                end
                                
                                if label:IsA("GuiButton") then
                                    local btxt = getButtonText(label)
                                    if btxt == "add" then
                                        addBtn = label
                                    end
                                end
                            end
                            
                            if not addBtn then addBtn = itemFrame end
                            
                            if matReq > 0 then
                                table.insert(tempMaterialsArray, {
                                    name = matName,
                                    current = matCur,
                                    required = matReq,
                                    btn = addBtn
                                })
                            end
                        end
                    end
                end
            end
        end)

        if not hasIngredients then isReadyToCraft = false end

        pcall(function()
            local btnCacheMissing = (not _XT.cachedButtons.auto or not _XT.cachedButtons.auto.Parent or not _XT.cachedButtons.auto.Visible) 
                                 or (not _XT.cachedButtons.craft or not _XT.cachedButtons.craft.Parent or not _XT.cachedButtons.craft.Visible)
                                 or (not _XT.cachedButtons.open or not _XT.cachedButtons.open.Parent or not _XT.cachedButtons.open.Visible)
            
            if btnCacheMissing then
                _XT.cachedButtons = { open = nil, auto = nil, craft = nil }
                local foundCount = 0
                -- [OPT] scan เฉพาะ ScreenGui ที่มี _XT.cachedRecipeHolder อยู่ แทน scan ทั้ง playerGui
                local searchRoot = playerGui
                if _XT.cachedRecipeHolder and _XT.cachedRecipeHolder.Parent then
                    local ancestor = _XT.cachedRecipeHolder
                    while ancestor and ancestor.Parent and ancestor.Parent ~= playerGui do
                        ancestor = ancestor.Parent
                    end
                    if ancestor and ancestor:IsA("ScreenGui") then searchRoot = ancestor end
                end
                for _, obj in ipairs(searchRoot:GetDescendants()) do
                    if foundCount >= 3 then break end
                    if obj:IsA("GuiButton") and obj.AbsoluteSize.X > 0 and isObjectActuallyVisible(obj) then 
                        local txt = getButtonText(obj)
                        txt = txt:gsub("^%s+", ""):gsub("%s+$", "") 
                        
                        if txt == "open recipe" and not _XT.cachedButtons.open then 
                            _XT.cachedButtons.open = obj; foundCount = foundCount + 1
                        elseif txt == "auto" and not _XT.cachedButtons.auto then 
                            _XT.cachedButtons.auto = obj; foundCount = foundCount + 1
                        elseif txt == "craft" and not _XT.cachedButtons.craft then 
                            _XT.cachedButtons.craft = obj; foundCount = foundCount + 1
                        end
                    end
                end
            end
        end)

        local realBtns = _XT.cachedButtons

        if isRecipeOpen then
            if CurrentCraftTarget ~= currentItemName then
                CraftSessionCount = 0
                CraftLogs = {}
                LastMaterialsState = {}
                CurrentCraftTarget = currentItemName
                _G.IsCraftingExpected = false
                AddCraftLog("Started tracking: " .. currentItemName)
            end

            local didCraft = false
            local isFirstScan = (next(LastMaterialsState) == nil)
            local materialDecreased = false
            
            for _, mat in ipairs(tempMaterialsArray) do
                local lastCount = LastMaterialsState[mat.name] or 0
                
                if not isFirstScan then
                    if mat.current < lastCount then
                        materialDecreased = true 
                    end
                end
                LastMaterialsState[mat.name] = mat.current
            end

            if materialDecreased and _G.IsCraftingExpected then
                didCraft = true
            end

            if didCraft then
                AddCraftLog("Crafted " .. currentItemName .. "!")
                CraftSessionCount = CraftSessionCount + 1
                _G.IsCraftingExpected = false 
            end

            IsCraftReady = isReadyToCraft
            CurrentCraftMaterials = tempMaterialsArray
            local readyText = isReadyToCraft and "[ READY ]" or "[ WAITING ]"
            if CraftTargetLabel then CraftTargetLabel:SetDesc(currentItemName) end
            if CraftStatusLabel then CraftStatusLabel:SetDesc(readyText) end
        else
            if CurrentCraftTarget ~= "" then
                CurrentCraftTarget = ""
                IsCraftReady = false
                CurrentCraftMaterials = {}
                LastMaterialsState = {}
                CraftLogs = {}
                CraftSessionCount = 0
                _G.IsCraftingExpected = false
            end
            if CraftTargetLabel then CraftTargetLabel:SetDesc("None (Recipe Closed)") end
            if CraftStatusLabel then CraftStatusLabel:SetDesc("Waiting") end
        end

        if masterAutoEnabled and tick() > nextActionTime then
            if #SelectedMultiItems > 0 then
                local targetItemName = SelectedMultiItems[multiCraftIndex]
                local realName = ScannedItemBaseNames[targetItemName] or string.gsub(targetItemName, " %(Button%)$", "")
                
                local occurrenceTarget = 1
                if ScannedItemBaseNames[targetItemName] then
                    local extractNum = string.match(targetItemName, " %((%d+)%)$")
                    if extractNum then
                        occurrenceTarget = tonumber(extractNum)
                    end
                end

                local targetBtn = CachedTargetButtons[targetItemName]
                
                if not targetBtn or not targetBtn.Parent then
                    local potentialTargets = {}
                    pcall(function()
                        for _, gui in ipairs(player.PlayerGui:GetChildren()) do
                            if gui:IsA("ScreenGui") then
                                for _, desc in ipairs(gui:GetDescendants()) do
                                    if (desc.Name == "Item" or desc.Name == "Gear" or desc.Name == "Lantern") and desc:IsA("GuiObject") then
                                        if desc.AbsoluteSize.Y > 0 then
                                            for _, child in ipairs(desc:GetChildren()) do
                                                if child.Name == realName then
                                                    local tempBtn = nil
                                                    if child:IsA("ImageButton") or child:IsA("TextButton") then
                                                        tempBtn = child
                                                    else
                                                        tempBtn = child:FindFirstChildWhichIsA("ImageButton", true) or child:FindFirstChildWhichIsA("TextButton", true)
                                                    end
                                                    
                                                    if tempBtn and tempBtn.AbsoluteSize.Y > 0 then
                                                        table.insert(potentialTargets, {
                                                            btn = tempBtn,
                                                            x = child.AbsolutePosition.X,
                                                            y = child.AbsolutePosition.Y,
                                                            order = child.LayoutOrder or 0
                                                        })
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end)
                    
                    table.sort(potentialTargets, function(a, b)
                        if a.order ~= b.order then return a.order < b.order end
                        if math.abs(a.y - b.y) > 10 then return a.y < b.y end
                        return a.x < b.x
                    end)

                    if #potentialTargets >= occurrenceTarget then
                        targetBtn = potentialTargets[occurrenceTarget].btn
                    elseif #potentialTargets > 0 then
                        targetBtn = potentialTargets[#potentialTargets].btn
                    end
                    
                    if not targetBtn or not targetBtn.Parent then
                        targetBtn = ScannedItemPaths[targetItemName]
                    end
                    
                    if targetBtn then
                        CachedTargetButtons[targetItemName] = targetBtn
                    end
                end

                local isUIOpen = false
                if isRecipeOpen then
                    isUIOpen = true
                elseif targetBtn then
                    local isVisible = true
                    local p = targetBtn
                    while p and p:IsA("GuiObject") do
                        if not p.Visible then isVisible = false break end
                        p = p.Parent
                    end
                    if isVisible and targetBtn.AbsoluteSize.Y > 0 and targetBtn.AbsolutePosition.X > 0 then
                        isUIOpen = true
                    end
                end

                if not isUIOpen then
                    if AutoCraftToggle then AutoCraftToggle:SetValue(false) end
                    masterAutoEnabled = false
                    HubConfig.AutoCraft = false
                    
                    if _G.MultiCraftDropdown then _G.MultiCraftDropdown:SetValues({}) end
                    SelectedMultiItems = {}
                    CachedTargetButtons = {} 
                    
                    if CraftStatusLabel then CraftStatusLabel:SetDesc("NPC UI closed. Auto Craft Disabled.") end
                    Fluent:Notify({ Title = "Auto Craft", Content = "UI closed or item missing. Disabled & Unselected.", Duration = 4 })
                else
                    if multiCraftState == "SELECT" then
                        _G.PopupAddAttempts = 0
                        if targetBtn and targetBtn.Parent and targetBtn.AbsoluteSize.Y > 0 then
                            local scrollFrame = targetBtn:FindFirstAncestorOfClass("ScrollingFrame")
                            if scrollFrame then
                                local maxCanvasY = 99999
                                pcall(function()
                                    if scrollFrame.AbsoluteCanvasSize and scrollFrame.AbsoluteCanvasSize.Y > 0 then
                                        maxCanvasY = math.max(0, scrollFrame.AbsoluteCanvasSize.Y - scrollFrame.AbsoluteWindowSize.Y)
                                    elseif scrollFrame.CanvasSize.Y.Offset > 0 then
                                        maxCanvasY = math.max(0, scrollFrame.CanvasSize.Y.Offset - scrollFrame.AbsoluteWindowSize.Y)
                                    end
                                end)
                                
                                local btnY = targetBtn.AbsolutePosition.Y
                                local scrollY = scrollFrame.AbsolutePosition.Y
                                local scrollHeight = scrollFrame.AbsoluteWindowSize and scrollFrame.AbsoluteWindowSize.Y or scrollFrame.AbsoluteSize.Y
                                
                                local margin = 20
                                if btnY < scrollY + margin or btnY + targetBtn.AbsoluteSize.Y > scrollY + scrollHeight - margin then
                                    local targetY = scrollFrame.CanvasPosition.Y + (btnY - scrollY) - (scrollHeight / 2)
                                    scrollFrame.CanvasPosition = Vector2.new(0, math.clamp(targetY, 0, maxCanvasY))
                                    task.wait(0.5)
                                end
                            end
                            
                            if forceCraftClick(targetBtn) then
                                multiCraftState = "OPEN_RECIPE"
                                nextActionTime = tick() + 1.0 
                            else
                                CachedTargetButtons[targetItemName] = nil
                                _G.SelectFailCount = (_G.SelectFailCount or 0) + 1
                                if _G.SelectFailCount > 4 then
                                    _G.SelectFailCount = 0
                                    multiCraftState = "NEXT"
                                end
                                nextActionTime = tick() + 0.5
                            end
                        else
                            multiCraftState = "NEXT"
                            nextActionTime = tick() + 0.5
                        end
                    elseif multiCraftState == "OPEN_RECIPE" then
                        _G.PopupAddAttempts = 0
                        local realName = ScannedItemBaseNames[targetItemName] or string.gsub(targetItemName, " %(Button%)$", "")
                        local targetNameLower = string.lower(realName)
                        local currentNameLower = string.lower(currentItemName)
                        local isCorrectRecipe = string.find(currentNameLower, targetNameLower, 1, true) or string.find(targetNameLower, currentNameLower, 1, true)

                        if realBtns.open and realBtns.open.Visible then
                            forceCraftClick(realBtns.open)
                            multiCraftState = "WAIT_RECIPE"
                            nextActionTime = tick() + 1.2
                        else
                            if isRecipeOpen and isCorrectRecipe then
                                multiCraftState = "WAIT_RECIPE"
                                nextActionTime = tick() + 0.1
                            else
                                _G.OpenFailCount = (_G.OpenFailCount or 0) + 1
                                if _G.OpenFailCount > 6 then
                                    _G.OpenFailCount = 0
                                    multiCraftState = "SELECT" 
                                end
                                nextActionTime = tick() + 0.5
                            end
                        end
                    elseif multiCraftState == "WAIT_RECIPE" then
                        local popupRoot = findAddIngredientsPopup(true)

                        if popupRoot then
                            if (_G.PopupAddAttempts or 0) >= 2 then
                                for _, btn in pairs(popupRoot:GetDescendants()) do
                                    if btn:IsA("GuiButton") and btn.Visible then
                                        local btnTxt = string.lower(TrimString(getButtonText(btn)))
                                        if btnTxt == "x" or btnTxt == "close" then
                                            forceCraftClick(btn)
                                            task.wait(0.2)
                                            break
                                        end
                                    end
                                end
                                _G.PopupAddAttempts = 0
                                multiCraftState = "NEXT"
                                nextActionTime = tick() + 0.5
                            else
                                local allReady, clickedAdd = ProcessPopupIngredients(popupRoot)
                                
                                if allReady then
                                    local craftBtn = nil
                                    for _, btn in pairs(popupRoot:GetDescendants()) do
                                        if btn:IsA("GuiButton") and btn.Visible and string.lower(TrimString(getButtonText(btn))) == "craft" then
                                            craftBtn = btn
                                            break
                                        end
                                    end
                                    
                                    if craftBtn then
                                        forceCraftClick(craftBtn)
                                        _G.IsCraftingExpected = true
                                    elseif realBtns.craft and realBtns.craft.Visible then
                                        forceCraftClick(realBtns.craft)
                                        _G.IsCraftingExpected = true
                                    end
                                    
                                    _G.PopupAddAttempts = 0
                                    multiCraftState = "FINISH_CRAFT"
                                    nextActionTime = tick() + 2.0
                                elseif clickedAdd then
                                    _G.PopupAddAttempts = (_G.PopupAddAttempts or 0) + 1
                                    nextActionTime = tick() + 0.5
                                else
                                    for _, btn in pairs(popupRoot:GetDescendants()) do
                                        if btn:IsA("GuiButton") and btn.Visible then
                                            local btnTxt = string.lower(TrimString(getButtonText(btn)))
                                            if btnTxt == "x" or btnTxt == "close" then
                                                forceCraftClick(btn)
                                                task.wait(0.2)
                                                break
                                            end
                                        end
                                    end
                                    _G.PopupAddAttempts = 0
                                    multiCraftState = "NEXT"
                                    nextActionTime = tick() + 0.5
                                end
                            end
                        else
                            if isRecipeOpen then
                                local realName = ScannedItemBaseNames[targetItemName] or string.gsub(targetItemName, " %(Button%)$", "")
                                local targetNameLower = string.lower(realName)
                                local currentNameLower = string.lower(currentItemName)
                                local isCorrectRecipe = string.find(currentNameLower, targetNameLower, 1, true) or string.find(targetNameLower, currentNameLower, 1, true)
                                
                                if not isCorrectRecipe then
                                    multiCraftState = "SELECT"
                                    nextActionTime = tick() + 0.5
                                else
                                    if IsCraftReady and realBtns.craft and realBtns.craft.Visible then
                                         forceCraftClick(realBtns.craft)
                                         _G.IsCraftingExpected = true
                                         multiCraftState = "FINISH_CRAFT"
                                         nextActionTime = tick() + 2.0
                                    else
                                         if realBtns.open and realBtns.open.Visible then
                                             forceCraftClick(realBtns.open)
                                             nextActionTime = tick() + 1.0
                                         else
                                             _G.WaitPopupCount = (_G.WaitPopupCount or 0) + 1
                                             if _G.WaitPopupCount > 6 then
                                                 _G.WaitPopupCount = 0
                                                 _G.PopupAddAttempts = 0
                                                 multiCraftState = "NEXT"
                                             end
                                             nextActionTime = tick() + 0.5
                                         end
                                    end
                                end
                            else
                                _G.PopupAddAttempts = 0
                                multiCraftState = "OPEN_RECIPE"
                                nextActionTime = tick() + 0.5
                            end
                        end
                    elseif multiCraftState == "FINISH_CRAFT" then
                        _G.PopupAddAttempts = 0
                        local popupRoot = findAddIngredientsPopup(true)
                        if popupRoot then
                            for _, btn in pairs(popupRoot:GetDescendants()) do
                                if btn:IsA("GuiButton") and btn.Visible and (string.lower(TrimString(getButtonText(btn))) == "x" or string.lower(TrimString(getButtonText(btn))) == "close") then
                                    forceCraftClick(btn)
                                    task.wait(0.2)
                                    break
                                end
                            end
                        end
                        
                        multiCraftState = "NEXT"
                        nextActionTime = tick() + 0.5
                    
                    elseif multiCraftState == "NEXT" then
                        multiCraftIndex = multiCraftIndex + 1
                        if multiCraftIndex > #SelectedMultiItems then
                            multiCraftIndex = 1
                        end
                        multiCraftState = "SELECT"
                        nextActionTime = tick() + 0.5
                    end
                end
            end
        end
    end
end)

task.spawn(function()
    local _detectRate = 2.0
    while true do
        task.wait(_detectRate)
        if not autoFarmEnabled then
            DetectFish_ON, DetectMinigame_ON, DetectAction_ON = false, false, false
            _detectRate = 2.0
            continue
        end

        -- [FIX-STUTTER] ขณะ minigame active (step 1-2) ข้ามทั้ง loop ลด CPU spike
        -- flags ที่ตั้งไว้แล้วจะใช้ต่อได้ ไม่ต้อง rescan ทุก 0.6s
        if fishingStep == 1 or fishingStep == 2 then
            _detectRate = 2.0 -- ช้าลงมากเมื่อ minigame active
            continue
        end

        _detectRate = 0.8 -- ปกติเมื่อไม่ minigame

        local mainUI = playerGui:FindFirstChild("MainInterface")
        if not mainUI then
            DetectFish_ON, DetectMinigame_ON, DetectAction_ON = false, false, false
            continue
        end
        
        local fishOn, miniOn, actOn = false, false, false

        for _, child in ipairs(mainUI:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible then
                local xOff = child.Size.X.Offset
                local xScl = child.Size.X.Scale
                local bg = child.BackgroundTransparency

                if math.abs(xOff - 201) <= 2 or math.abs(xScl - 0.122) <= 0.005 then
                    fishOn = (bg <= 0.6)
                elseif math.abs(xOff - 230) <= 2 or math.abs(xScl - 0.140) <= 0.005 then
                    miniOn = (bg <= 0.6)
                end
            end
        end

        if not fishOn and isAtTarget then
            pcall(function()
                local btn = getFishButton(mainUI)
                if btn and btn.Visible and btn.AbsoluteSize.X > 0 then
                    fishOn = true
                end
            end)
        end

        if fishingStep >= 2 then
            pcall(function()
                local actBtnDetect, _ = findActionBtnFast(mainUI)
                if actBtnDetect then actOn = true end
            end)
        end

        DetectFish_ON = fishOn
        DetectMinigame_ON = miniOn
        DetectAction_ON = actOn
    end
end)

_XT.recoveryLayer = {}
local function getRecovery(step)
    if not _XT.recoveryLayer[step] then _XT.recoveryLayer[step] = {layer=0, time=0} end
    return _XT.recoveryLayer[step]
end
local function resetRecovery(step)
    _XT.recoveryLayer[step] = {layer=0, time=0}
end
local function resetAllRecovery()
    _XT.recoveryLayer = {}
end

local function ClearFishingCache()
    cachedSafeZone = nil
    cachedDiamond = nil
    cachedExtraBtn = nil
    cachedFishBtn = nil
    lastFishBtnScanTime = 0 -- [FIX-v4] reset cooldown ด้วย
    resetAllRecovery()
end

-- [OPT-v2] recovery cleanup ย้ายไปอยู่ใน main cleanup cycle แล้ว
-- ลบ dedicated loop ออกเพื่อลดจำนวน coroutine ที่วิ่ง

-- ==========================================
-- [GLOBAL] ปิด Fish Shop UI อย่างแข็งแรง
-- Path หลัก: MainInterface.Frame.TextLabel.ImageButton
-- Path สำรอง: MainInterface.Frame.TextLabel.ImageButton.ImageLabel
-- ==========================================
local function closeShopFrameUI()
    local closed = false
    pcall(function()
        local mainUI2 = playerGui:FindFirstChild("MainInterface")
        if not mainUI2 then return end
        
        -- ค้นหา Frame ทุกตัวภายใต้ MainInterface (อาจมีหลาย Frame)
        for _, f in ipairs(mainUI2:GetChildren()) do
            if f.Name == "Frame" and f:IsA("GuiObject") then
                local fOK = false
                pcall(function() fOK = f.Visible and f.AbsoluteSize.Y > 10 end)
                if not fOK then continue end
                
                -- ตรวจว่ามี TextLabel > ImageButton (path ที่ถูกต้อง)
                local tl = f:FindFirstChild("TextLabel")
                if not tl then continue end
                local ib = tl:FindFirstChild("ImageButton")
                if not ib then continue end
                
                -- เจอ path ที่ถูกต้องแล้ว — กดปิดแบบถี่ ลองทุกวิธี
                for attempt = 1, 3 do
                    -- เช็คว่า Frame ยังเปิดอยู่ไหม
                    local stillOpen = false
                    pcall(function() stillOpen = f.Visible and f.AbsoluteSize.Y > 10 end)
                    if not stillOpen then closed = true; return end
                    
                    -- กด ImageButton ด้วย fire connections
                    pcall(function()
                        if ib and ib.Parent then
                            forceCraftClick(ib)
                        end
                    end)
                    task.wait(0.12)
                    
                    -- กด ImageButton ด้วย mouse/touch sim
                    pcall(function()
                        if ib and ib.Parent then
                            forceFishClick(ib)
                        end
                    end)
                    task.wait(0.15)
                    
                    -- เช็คอีกครั้ง
                    pcall(function() stillOpen = f.Visible and f.AbsoluteSize.Y > 10 end)
                    if not stillOpen then closed = true; return end
                    
                    -- กด ImageLabel (สำรอง) ด้วยทั้ง 2 วิธี
                    pcall(function()
                        local il = ib:FindFirstChildWhichIsA("ImageLabel")
                        if il then
                            forceCraftClick(il)
                            task.wait(0.1)
                            forceFishClick(il)
                        end
                    end)
                    task.wait(0.15)
                    
                    -- เช็คอีกครั้ง
                    pcall(function() stillOpen = f.Visible and f.AbsoluteSize.Y > 10 end)
                    if not stillOpen then closed = true; return end
                    
                    -- Escape key เป็น fallback สุดท้าย
                    pcall(function()
                        vim:SendKeyEvent(true, Enum.KeyCode.Escape, false, game)
                        task.wait(0.08)
                        vim:SendKeyEvent(false, Enum.KeyCode.Escape, false, game)
                    end)
                    task.wait(0.25)
                end
                
                -- เช็คสุดท้ายหลังครบ 3 attempts
                pcall(function()
                    if not f.Visible or f.AbsoluteSize.Y <= 10 then closed = true end
                end)
                return -- พบ Frame ที่มี path ถูกต้องแล้ว ไม่ต้องหาอีก
            end
        end
    end)
    return closed
end

-- [SAFETY] ตรวจ Shop Frame ค้างระหว่างตกปลา ปิดอัตโนมัติ
task.spawn(function()
    while task.wait(3) do
        if not autoFarmEnabled or isSellingProcess then continue end
        -- [FIX-STUTTER] skip ขณะ minigame active
        if _XT.isMinigameActive then continue end
        pcall(function()
            local mainUI2 = playerGui:FindFirstChild("MainInterface")
            if not mainUI2 then return end
            for _, f in ipairs(mainUI2:GetChildren()) do
                if f.Name == "Frame" and f:IsA("GuiObject") then
                    local fOK = false
                    pcall(function() fOK = f.Visible and f.AbsoluteSize.Y > 10 end)
                    if not fOK then continue end
                    local tl = f:FindFirstChild("TextLabel")
                    if not tl then continue end
                    local ib = tl:FindFirstChild("ImageButton")
                    if not ib then continue end
                    -- Shop Frame ค้างอยู่ระหว่างตกปลา — ปิดทันที
                    if FishStatusLabel then FishStatusLabel:SetDesc("Closing stuck Shop UI...") end
                    closeShopFrameUI()
                    return
                end
            end
        end)
    end
end)

-- [OPT] Shared sell frame finder — ลดโค้ดซ้ำ 2 จุดในขั้นตอนขาย
local function findSellFrame(mainUI)
    local sellFrame3, sellScrollFrame, frameDetected = nil, nil, false
    pcall(function()
        for _, f1 in ipairs(mainUI:GetChildren()) do
            if not (f1:IsA("GuiObject") and f1.Visible) then continue end
            for _, f2 in ipairs(f1:GetChildren()) do
                if not (f2:IsA("GuiObject") and f2.Visible) then continue end
                for _, f3 in ipairs(f2:GetChildren()) do
                    if not (f3:IsA("GuiObject") and f3.Visible) then continue end
                    local sf = f3:FindFirstChildWhichIsA("ScrollingFrame")
                    if sf and sf.Visible and #sf:GetChildren() > 0 then
                        local itemCount = 0
                        for _, c in ipairs(sf:GetChildren()) do
                            if not c:IsA("UIListLayout") and not c:IsA("UIGridLayout") and not c:IsA("UIPadding") then
                                itemCount = itemCount + 1
                            end
                        end
                        if itemCount > 0 then
                            sellFrame3 = f3
                            sellScrollFrame = sf
                            frameDetected = true
                            return
                        end
                    end
                end
                if frameDetected then return end
            end
            if frameDetected then return end
        end
    end)
    return sellFrame3, sellScrollFrame, frameDetected
end

-- [OPT-v2] Shared proximity prompt firing helper
-- Cache proximity prompts เพื่อไม่ต้อง GetDescendants ทุกครั้ง
_XT._cachedPrompts = nil
_XT._promptCacheTick = 0

local function fireNearbyProximityPrompt(rootPos, maxDist)
    maxDist = maxDist or 15
    local promptFired = false

    -- [OPT-v2] Refresh prompt cache ทุก 5s แทน scan ทุกครั้ง
    local prompts = _XT._cachedPrompts
    if not prompts or (tick() - _XT._promptCacheTick) > 5.0 then
        prompts = {}
        pcall(function()
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if obj:IsA("ProximityPrompt") then
                    prompts[#prompts + 1] = obj
                end
            end
        end)
        _XT._cachedPrompts = prompts
        _XT._promptCacheTick = tick()
    end

    pcall(function()
        for _, obj in ipairs(prompts) do
            if obj.Parent and obj.Parent:IsA("BasePart") then
                if (obj.Parent.Position - rootPos).Magnitude <= maxDist then
                    if fireproximityprompt then
                        fireproximityprompt(obj, 1)
                        fireproximityprompt(obj, 0)
                        promptFired = true
                        break
                    end
                end
            end
        end
    end)
    if not promptFired then
        pcall(function()
            for i = 1, 3 do
                vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(0.1)
                vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                task.wait(0.15)
            end
        end)
    end
    return promptFired
end

task.spawn(function()
    local isWalking = false
    -- [OPT-v2] 0.2s → 0.25s ลด walk check frequency
    while task.wait(0.25) do
        if not autoFarmEnabled then 
            isAtTarget = false
            isSellingProcess = false
            continue 
        end

        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end

        if autoSellEnabled then
            if fishingRoundCount >= targetFishCount then
                if not isSellingProcess then
                    hasArrivedAtSell = false
                    print("Round met! Initiating Sell...")
                    ClearFishingCache()
                    fishingStep = 0
                    hasMinigameMoved = false
                    
                    pcall(function()
                        local mainUI = playerGui:FindFirstChild("MainInterface")
                        if mainUI then
                            local extraBtn = getExtraButton(mainUI)
                            if extraBtn and extraBtn.Visible then
                                if FishStatusLabel then FishStatusLabel:SetDesc("Claiming Extra Action...") end
                                forceCraftClick(extraBtn)
                                task.wait(0.2) -- [SELL-FAST] 0.4→0.2
                            end
                        end
                    end)

                    pcall(function()
                        if FishStatusLabel then FishStatusLabel:SetDesc("Preparing to Sell...") end
                        local mainUI = playerGui:FindFirstChild("MainInterface")
                        if mainUI then
                            local sideButtons = mainUI:FindFirstChild("SideButtons")
                            if sideButtons then
                                local bagBtn = nil
                                for _, btn in ipairs(sideButtons:GetChildren()) do
                                    if btn:IsA("GuiButton") or btn:IsA("ImageButton") or btn:IsA("TextButton") then
                                        local n = btn.Name:lower()
                                        if n:find("bag") or n:find("backpack") or n:find("inventory") or n:find("fish") then
                                            bagBtn = btn; break
                                        end
                                    end
                                end
                                if not bagBtn then
                                    local children = sideButtons:GetChildren()
                                    if children[8] then bagBtn = children[8] end
                                end
                                if bagBtn then forceCraftClick(bagBtn) task.wait(0.3) end -- [SELL-FAST] 0.5→0.3
                            end
                        end

                        local btn2 = nil
                        for _, gui in ipairs(playerGui:GetChildren()) do
                            if gui:IsA("ScreenGui") and gui.Name ~= "AutoFishTesterUI" then
                                local f = gui:FindFirstChild("Frame")
                                local tl = f and f:FindFirstChild("TextLabel")
                                local b = tl and (tl:FindFirstChild("TextButton") or tl:FindFirstChildWhichIsA("TextButton"))
                                if b and b.Visible then btn2 = b; break end
                            end
                        end
                        if btn2 then forceCraftClick(btn2) task.wait(0.2) end -- [SELL-FAST] 0.4→0.2
                    end)

                    isSellingProcess = true
                end
            end
        end

        if isSellingProcess then
            isAtTarget = false
            isResettingUI = false
            local distToSell = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(TARGET_SELL_POS.X, 0, TARGET_SELL_POS.Z)).Magnitude
            
            if distToSell > 5 then
                hasArrivedAtSell = false 
                if not isWalking then
                    isWalking = true
                    task.spawn(function()
                        pcall(function() walkToTarget(TARGET_SELL_POS, "Merchant") end)
                        isWalking = false
                    end)
                end
            else
                if not hasArrivedAtSell then
                    if char:FindFirstChild("Humanoid") then char.Humanoid:MoveTo(root.Position) end
                    task.wait(0.15) -- [SELL-FAST] 0.3→0.15

                    -- [OPT] ใช้ shared helper แทน inline prompt search
                    fireNearbyProximityPrompt(root.Position, 15)

                    task.wait(0.4) -- [SELL-FAST] 0.8→0.4
                    hasArrivedAtSell = true
                end
                
                local hasCompletedSell = false
                local sellAttemptStart = tick()
                local sellDialogRetry = 0
                local MAX_SELL_RETRY = 2 -- [SELL-FAST] 3→2

                while not hasCompletedSell and autoFarmEnabled and isSellingProcess do
                    task.wait(0.1) -- [SELL-FAST] 0.15→0.1
                    if tick() - sellAttemptStart > 30 then -- [SELL-FAST] 45→30
                        if FishStatusLabel then FishStatusLabel:SetDesc("Sell Timeout! Force Exit...") end
                        break
                    end

                    local mainUI = playerGui:FindFirstChild("MainInterface")
                    if not mainUI then task.wait(0.15); continue end -- [SELL-FAST] 0.2→0.15
                    local dialog = mainUI:FindFirstChild("Dialog")
                
                    if dialog and dialog.Visible then
                        sellDialogRetry = 0
                        local choices = dialog:FindFirstChild("Choices")
                        if choices and choices.Visible then
                            local validChoices = {}
                            for _, child in ipairs(choices:GetChildren()) do
                                if child:IsA("GuiButton") or child:IsA("TextButton") or child:IsA("ImageButton") then
                                    table.insert(validChoices, child)
                                end
                            end
                            
                            if #validChoices >= 2 then
                                local sellChoiceBtn = nil
                                for _, btn in ipairs(validChoices) do
                                    local btnText = ""
                                    pcall(function()
                                        if btn:IsA("TextButton") then btnText = btn.Text:lower()
                                        else
                                            local lbl = btn:FindFirstChildWhichIsA("TextLabel")
                                            if lbl then btnText = lbl.Text:lower() end
                                        end
                                    end)
                                    if btnText:find("sell") or btnText:find("ขาย") then
                                        sellChoiceBtn = btn; break
                                    end
                                end
                                if not sellChoiceBtn then sellChoiceBtn = validChoices[2] end
                                forceCraftClick(sellChoiceBtn)
                                if not mainUI then break end
                                if FishStatusLabel then FishStatusLabel:SetDesc("Detecting Sell Frame...") end

                                local frameDetected = false
                                local frameDetectStart = tick()
                                local sellFrame3 = nil
                                local sellScrollFrame = nil

                                while tick() - frameDetectStart < 5 do -- [SELL-FAST] 12→5
                                    sellFrame3, sellScrollFrame, frameDetected = findSellFrame(mainUI)

                                    if frameDetected then
                                        if FishStatusLabel then FishStatusLabel:SetDesc("Sell Frame Detected! (" .. #sellScrollFrame:GetChildren() .. " items)") end
                                        break
                                    end
                                    task.wait(0.15) -- [SELL-FAST] 0.25→0.15
                                end

                                if not frameDetected then
                                    if FishStatusLabel then FishStatusLabel:SetDesc("Sell Frame not found! Retrying...") end
                                    pcall(function()
                                        for i = 1, 2 do -- [SELL-FAST] 3→2
                                            vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                                            task.wait(0.08) -- [SELL-FAST] 0.1→0.08
                                            vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                                            task.wait(0.1) -- [SELL-FAST] 0.15→0.1
                                        end
                                    end)
                                    task.wait(0.8) -- [SELL-FAST] 1.5→0.8
                                    sellFrame3, sellScrollFrame, frameDetected = findSellFrame(mainUI)
                                    if not frameDetected then
                                        if FishStatusLabel then FishStatusLabel:SetDesc("No Sell Frame. Skipping...") end
                                        break
                                    end
                                end

                                -- ==========================================
                                -- [PATCHED] Inner Sell Loop — ขายจนกระเป๋าว่าง
                                -- [FIX] สุ่มเลือกเฉพาะ 4 ช่องแรก (แถวบน) ป้องกัน UI บีบมือถือจอเล็ก
                                -- ==========================================
                                local emptyBagCheck = 0
                                local innerLoopStart = tick()
                                local sellAllMissCount = 0
                                local cachedSellAllBtn = nil -- [OPT] cache Sell All button
                                while autoFarmEnabled and isSellingProcess do
                                    if tick() - innerLoopStart > 60 then -- [SELL-FAST] 120→60
                                        if FishStatusLabel then FishStatusLabel:SetDesc("Bag Timeout! Exiting...") end
                                        break
                                    end

                                    if sellFrame3 and (not sellFrame3.Parent or not sellFrame3.Visible) then
                                        if FishStatusLabel then FishStatusLabel:SetDesc("Sell Frame Closed") end
                                        break
                                    end

                                    local scrollFrame = (sellScrollFrame and sellScrollFrame.Parent and sellScrollFrame.Visible) and sellScrollFrame or nil
                                    if not scrollFrame and sellFrame3 and sellFrame3.Visible then
                                        pcall(function()
                                            local sf = sellFrame3:FindFirstChildWhichIsA("ScrollingFrame")
                                            if sf and sf.Visible then scrollFrame = sf; sellScrollFrame = sf end
                                        end)
                                    end
                                    if not scrollFrame then
                                        -- [OPT-v2] scan เฉพาะ sellFrame3 แทน mainUI:GetDescendants()
                                        pcall(function()
                                            if sellFrame3 and sellFrame3.Parent then
                                                local sf = sellFrame3:FindFirstChildWhichIsA("ScrollingFrame", true)
                                                if sf and sf.Visible and #sf:GetChildren() > 0 then
                                                    scrollFrame = sf
                                                end
                                            end
                                        end)
                                    end

                                    if scrollFrame then
                                        local items = {}
                                        for _, v in ipairs(scrollFrame:GetChildren()) do
                                            if v:IsA("GuiObject") and v.Visible and v.AbsoluteSize.Y > 5 then
                                                local btn = v:IsA("GuiButton") and v or v:FindFirstChildWhichIsA("GuiButton", true)
                                                if btn then
                                                    table.insert(items, btn)
                                                else
                                                    table.insert(items, v)
                                                end
                                            end
                                        end

                                        if #items > 0 then
                                            emptyBagCheck = 0
                                            -- [FIX] สุ่มเลือกเฉพาะ 4 ช่องแรก (แถวบน) ป้องกัน UI บีบจอมือถือเล็ก
                                            local topRowCount = math.min(4, #items)
                                            local randomItem = items[math.random(1, topRowCount)]
                                            pcall(function() scrollFrame.CanvasPosition = Vector2.new(0, 0) end)
                                            task.wait(0.1) -- [SELL-FAST] 0.2→0.1

                                            if FishStatusLabel then FishStatusLabel:SetDesc("Selecting Item... (" .. #items .. " left)") end
                                            forceCraftClick(randomItem)
                                            task.wait(0.2) -- [SELL-FAST] 0.4→0.2

                                            if FishStatusLabel then FishStatusLabel:SetDesc("Clicking Sell All...") end
                                            -- [OPT] Cache sell all button — ลดการ search ซ้ำทุกรอบ
                                            local sellAllBtn = nil
                                            if cachedSellAllBtn and cachedSellAllBtn.Parent and cachedSellAllBtn.Visible then
                                                sellAllBtn = cachedSellAllBtn
                                            else
                                                cachedSellAllBtn = nil
                                                pcall(function()
                                                    for _, f1 in ipairs(mainUI:GetChildren()) do
                                                        if not (f1:IsA("GuiObject") and f1.Visible) then continue end
                                                        for _, f2 in ipairs(f1:GetChildren()) do
                                                            if not (f2:IsA("GuiObject") and f2.Visible) then continue end
                                                            for _, imgBtn in ipairs(f2:GetChildren()) do
                                                                if imgBtn:IsA("ImageButton") and imgBtn.Visible then
                                                                    local tl = imgBtn:FindFirstChildWhichIsA("TextLabel")
                                                                    if tl then
                                                                        local txt = tl.Text:lower()
                                                                        if txt:match("sell all") or txt:match("ขายทั้งหมด") then
                                                                            sellAllBtn = imgBtn; cachedSellAllBtn = imgBtn; return
                                                                        end
                                                                    end
                                                                    local n = imgBtn.Name:lower()
                                                                    if n:match("sell") or n:match("sellall") then
                                                                        sellAllBtn = imgBtn; cachedSellAllBtn = imgBtn; return
                                                                    end
                                                                end
                                                            end
                                                            if sellAllBtn then return end
                                                        end
                                                        if sellAllBtn then return end
                                                    end
                                                end)
                                            end

                                            if sellAllBtn then
                                                sellAllMissCount = 0
                                                task.wait(0.15) -- [SELL-FAST] 0.3→0.15
                                                forceCraftClick(sellAllBtn)
                                                task.wait(0.4) -- [SELL-FAST] 0.8→0.4

                                                -- [OPT] ค้นหา Sell Confirm popup แบบ targeted
                                                -- แทนที่จะ scan GetDescendants ทุกรอบ ค้นหาแค่ children ลึก 3 ชั้น
                                                local targetConfirmBtn = nil
                                                pcall(function()
                                                    for _, f1 in ipairs(mainUI:GetChildren()) do
                                                        if not (f1:IsA("GuiObject") and f1.Visible) then continue end
                                                        for _, desc in ipairs(f1:GetDescendants()) do
                                                            if desc:IsA("TextLabel") and desc.Text == "Sell Confirm" and desc.Visible then
                                                                local popupFrame = desc.Parent
                                                                if popupFrame and popupFrame:IsA("GuiObject") then
                                                                    for _, pDesc in ipairs(popupFrame:GetDescendants()) do
                                                                        if pDesc:IsA("TextLabel") and pDesc.Text == "Sell" and pDesc.Visible then
                                                                            local button = pDesc.Parent
                                                                            if button and (button:IsA("GuiButton") or button:IsA("ImageButton")) and button.Visible then
                                                                                targetConfirmBtn = button
                                                                                return
                                                                            end
                                                                        end
                                                                    end
                                                                end
                                                            end
                                                        end
                                                        if targetConfirmBtn then return end
                                                    end
                                                end)

                                                if targetConfirmBtn then
                                                    task.wait(0.15) -- [SELL-FAST] 0.3→0.15
                                                    forceCraftClick(targetConfirmBtn)
                                                    task.wait(0.4) -- [SELL-FAST] 0.8→0.4
                                                    sellAllMissCount = 0
                                                    if FishStatusLabel then FishStatusLabel:SetDesc("Sold Item! Checking for more...") end
                                                else
                                                    task.wait(0.15) -- [SELL-FAST] 0.3→0.15
                                                end
                                            else
                                                sellAllMissCount = sellAllMissCount + 1
                                                if sellAllMissCount >= 3 then -- [SELL-FAST] 5→3
                                                    if FishStatusLabel then FishStatusLabel:SetDesc("Sell All button not found! Exiting...") end
                                                    break
                                                end
                                                task.wait(0.2) -- [SELL-FAST] 0.4→0.2
                                            end
                                        else
                                            emptyBagCheck = emptyBagCheck + 1
                                            if FishStatusLabel then FishStatusLabel:SetDesc("Checking Bag (" .. emptyBagCheck .. "/2)...") end
                                            if emptyBagCheck >= 2 then -- [SELL-FAST] 3→2
                                                if FishStatusLabel then FishStatusLabel:SetDesc("Bag Empty! All Items Sold.") end
                                                break
                                            end
                                            task.wait(0.3) -- [SELL-FAST] 0.5→0.3
                                        end
                                    else
                                        task.wait(0.3) -- [SELL-FAST] 0.5→0.3
                                    end
                                end
                                -- ==========================================

                                if FishStatusLabel then FishStatusLabel:SetDesc("Closing Shop UI...") end
                                closeShopFrameUI()
                                task.wait(0.15) -- [SELL-FAST] 0.3→0.15

                                hasCompletedSell = true
                                totalSellCount = totalSellCount + 1
                                task.wait(0.2) -- [SELL-FAST] 0.5→0.2

                                -- กด Leave (choice ตัวที่ 3) เพื่อปิด Dialog NPC หลังปิด Sell UI
                                task.wait(0.15) -- [SELL-FAST] 0.3→0.15
                                pcall(function()
                                    local dlg2 = mainUI:FindFirstChild("Dialog")
                                    if not (dlg2 and dlg2.Visible) then return end
                                    local choices2 = dlg2:FindFirstChild("Choices")
                                    if not choices2 then return end
                                    local btns2 = {}
                                    for _, child in ipairs(choices2:GetChildren()) do
                                        if child:IsA("GuiButton") or child:IsA("TextButton") or child:IsA("ImageButton") then
                                            table.insert(btns2, child)
                                        end
                                    end
                                    table.sort(btns2, function(a, b)
                                        return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
                                    end)
                                    local leaveBtn2 = btns2[3] or btns2[#btns2]
                                    if leaveBtn2 then forceCraftClick(leaveBtn2) end
                                end)
                                task.wait(0.2) -- [SELL-FAST] 0.5→0.2
                            end
                        else
                            forceCraftClick(dialog)
                            task.wait(0.15) -- [SELL-FAST] 0.2→0.15
                        end
                    else
                        sellDialogRetry = sellDialogRetry + 1
                        if FishStatusLabel then FishStatusLabel:SetDesc("No Dialog! Retry (" .. sellDialogRetry .. "/" .. MAX_SELL_RETRY .. ")") end

                        pcall(function()
                            local char2 = player.Character
                            local root2 = char2 and char2:FindFirstChild("HumanoidRootPart")
                            if not root2 then return end
                            fireNearbyProximityPrompt(root2.Position, 15)
                        end)
                        task.wait(0.4) -- [SELL-FAST] 0.8→0.4

                        if sellDialogRetry >= MAX_SELL_RETRY then
                            if FishStatusLabel then FishStatusLabel:SetDesc("Force Exiting Sell...") end
                            hasCompletedSell = true
                            totalSellCount = totalSellCount + 1
                        end
                    end
                end

                isSellingProcess = false
                hasArrivedAtSell = false
                isResettingUI = false
                isAtTarget = false
                isWalking = false
                fishingStep = 0
                hasMinigameMoved = false
                fishingRoundCount = 0

                if FishBagLabel then FishBagLabel:SetDesc("Rounds: " .. fishingRoundCount .. " / " .. targetFishCount) end
                if FishStatusLabel then FishStatusLabel:SetDesc("Sell Done! Closing Shop...") end

                -- [SELL-FAST] รวม close ทั้งหมดเป็น 1 pass ลด redundant calls
                closeShopFrameUI()
                task.wait(0.15) -- [SELL-FAST] 0.3→0.15

                local function closeDialogSafely()
                    local mainUI2 = playerGui:FindFirstChild("MainInterface")
                    if not mainUI2 then return end
                    local dlg = mainUI2:FindFirstChild("Dialog")
                    if not (dlg and dlg.Visible) then return end
                    local choices = dlg:FindFirstChild("Choices")
                    if not choices then return end
                    local btns = {}
                    for _, child in ipairs(choices:GetChildren()) do
                        if child:IsA("GuiButton") or child:IsA("TextButton") or child:IsA("ImageButton") then
                            table.insert(btns, child)
                        end
                    end
                    table.sort(btns, function(a, b) return (a.LayoutOrder or 0) < (b.LayoutOrder or 0) end)
                    if #btns >= 3 then
                        forceCraftClick(btns[3]); task.wait(0.15) -- [SELL-FAST] 0.3→0.15
                    elseif #btns > 0 then
                        forceCraftClick(btns[#btns]); task.wait(0.15)
                    end
                end

                closeDialogSafely()

                -- [SELL-FAST] รอ Dialog หาย timeout 1.5s (เดิม 3s)
                local dialogWaitStart = tick()
                while tick() - dialogWaitStart < 1.5 do
                    local mainUI = playerGui:FindFirstChild("MainInterface")
                    local dlg = mainUI and mainUI:FindFirstChild("Dialog")
                    if not dlg or not dlg.Visible then break end
                    closeDialogSafely()
                    task.wait(0.2) -- [SELL-FAST] 0.3→0.2
                end
                
                -- Safety: ปิด Shop Frame ครั้งสุดท้ายก่อนเดินกลับ
                closeShopFrameUI()

                ClearFishingCache()
                task.wait(0.15) -- [SELL-FAST] 0.3→0.15
            end
            
        else
            if isResettingUI then
                local distToReset = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(RESET_FISH_POS.X, 0, RESET_FISH_POS.Z)).Magnitude
                if distToReset > 4 then
                    isAtTarget = false
                    if not isWalking then
                        isWalking = true
                        task.spawn(function()
                            pcall(function() walkToTarget(RESET_FISH_POS, "Reset Spot") end)
                            isWalking = false
                        end)
                    end
                else
                    isResettingUI = false 
                end
            else
                local distToFish = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(TARGET_FISH_POS.X, 0, TARGET_FISH_POS.Z)).Magnitude
                if distToFish > 5 then
                    isAtTarget = false
                    if not isWalking then
                        isWalking = true
                        task.spawn(function()
                            pcall(function() walkToTarget(TARGET_FISH_POS, "Fishing Spot") end)
                            isWalking = false
                        end)
                    end
                else
                    if not isAtTarget then
                        isAtTarget = true
                        if char:FindFirstChild("Humanoid") then char.Humanoid:MoveTo(root.Position) end
                    end
                end
            end
        end
    end
end)

-- [FIX] ใช้ _G แทน local ป้องกัน "Out of local registers > 200" ในสคริปต์ระดับบนสุด
_XT.FAR_THRESHOLD  = 60
_XT.MID_THRESHOLD  = 25
_XT.isMinigameActive = false
_XT.lastClickTime  = 0
-- [FIX-MINIGAME] ลด click rate ให้เร็วขึ้น — เดิมช้าเกินกดไม่ทัน
_XT.CLICK_RATE_FAR  = 0.00  -- ไกลมาก = กดทุก frame ไม่ต้อง throttle
_XT.CLICK_RATE_MID  = 0.03  -- กลาง = กดเร็วมาก
_XT.CLICK_RATE_NEAR = 0.06  -- ใกล้ = ชะลอนิดนึง

-- [FIX] Status label cache — เขียน UI เฉพาะตอนข้อความเปลี่ยน
-- บนมือถือ UI property write แพงมาก เขียนทุก frame FPS ตกหนัก
_XT._lastFishStatus = ""
function _XT.setFishStatus(txt)
    if txt ~= _XT._lastFishStatus then
        _XT._lastFishStatus = txt
        if FishStatusLabel then pcall(function() FishStatusLabel:SetDesc(txt) end) end
    end
end

-- [FIX-MINIGAME] clickOnce สำหรับ Minigame โดยเฉพาะ
-- ไม่มี task.wait เลย = fire-and-forget ทันที
-- เดิม clickOnce() มี wait รวม ~0.12s ทำให้ loop 0.04s จริงๆวิ่ง 0.16s = 6fps
local function clickOnceMinigame()
    local cam = getCamera()
    local inset, _ = guiService:GetGuiInset()
    local safeX = cam.ViewportSize.X * 0.5 + inset.X
    local safeY = cam.ViewportSize.Y * 0.5 + inset.Y
    -- Mouse click แบบ fire-and-forget (ไม่ wait ระหว่าง down/up)
    pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, true, game, 1) end)
    pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, false, game, 1) end)
    -- Touch click แบบ fire-and-forget
    if isTouchDevice then
        pcall(function() vim:SendTouchEvent(0, Vector2.new(safeX, safeY), true) end)
        pcall(function() vim:SendTouchEvent(0, Vector2.new(safeX, safeY), false) end)
    end
end

-- [FIX-MINIGAME] Adaptive rate minigame loop
-- Active: 0.025s (40fps) — เร็วพอแม้เครื่องแลค
-- Idle: 0.15s — ลด CPU เมื่อไม่มี minigame
_XT._minigameTickRate = 0.15
task.spawn(function() while true do
    task.wait(_XT._minigameTickRate)

    if not autoFarmEnabled or not isAtTarget or isSellingProcess or isResettingUI or not DetectMinigame_ON then
        if _XT.isMinigameActive then
            _XT.isMinigameActive = false
        end
        _XT._minigameTickRate = 0.15
        continue
    end

    pcall(function()
        local safeZoneBar, diamondIcon = getExactMinigameElements()

        if safeZoneBar and safeZoneBar.Visible then
            _XT.isMinigameActive = true
            hasMinigameMoved = true
            _XT._minigameTickRate = 0.025 -- [FIX-MINIGAME] 0.04→0.025 (40fps)

            if diamondIcon and diamondIcon.Visible then
                local overlapping = isOverlapping(diamondIcon, safeZoneBar)
                local distance = math.abs((diamondIcon.AbsolutePosition.X + diamondIcon.AbsoluteSize.X / 2) - (safeZoneBar.AbsolutePosition.X + safeZoneBar.AbsoluteSize.X / 2))
                local currentTime = tick()

                if overlapping then
                    _XT.setFishStatus("Target Locked")
                elseif distance > _XT.FAR_THRESHOLD then
                    _XT.setFishStatus("Distance: Far (Spamming)")
                    -- [FIX-MINIGAME] ไกลมาก = burst click 2 ครั้งทุก frame
                    if currentTime - _XT.lastClickTime > _XT.CLICK_RATE_FAR then
                        clickOnceMinigame()
                        clickOnceMinigame()
                        _XT.lastClickTime = currentTime
                    end
                elseif distance > _XT.MID_THRESHOLD then
                    _XT.setFishStatus("Distance: Medium")
                    if currentTime - _XT.lastClickTime > _XT.CLICK_RATE_MID then
                        clickOnceMinigame()
                        _XT.lastClickTime = currentTime
                    end
                else
                    _XT.setFishStatus("Distance: Near")
                    if currentTime - _XT.lastClickTime > _XT.CLICK_RATE_NEAR then
                        clickOnceMinigame()
                        _XT.lastClickTime = currentTime
                    end
                end
            else
                _XT.setFishStatus("Waiting for Minigame...")
            end
        else
            if _XT.isMinigameActive then
                _XT.isMinigameActive = false
                _XT.setFishStatus("Waiting for Fish...")
            end
            _XT._minigameTickRate = 0.15
        end
    end)
end end)

_XT.lastFishingStepTime = tick()
_XT.actionFirstDetected = 0
_XT.lastLoopTick = tick()

-- ==========================================
-- [FIX] แยก Fishing Step เป็นฟังก์ชันย่อย ป้องกัน "Out of local registers (>200)"
-- ==========================================
function _XT.fishStep0(mainUI, isFishVisible, timeInStep, fishBtnRef)
    resetRecovery(0)
    -- ตรวจ Shop Frame ค้าง
    pcall(function()
        for _, f in ipairs(mainUI:GetChildren()) do
            if f.Name == "Frame" and f:IsA("GuiObject") then
                local fOK = false
                pcall(function() fOK = f.Visible and f.AbsoluteSize.Y > 10 end)
                if not fOK then continue end
                local tl = f:FindFirstChild("TextLabel")
                if not tl then continue end
                if tl:FindFirstChild("ImageButton") then
                    if FishStatusLabel then FishStatusLabel:SetDesc("Closing Shop Frame...") end
                    closeShopFrameUI()
                    task.wait(0.3)
                    _XT.lastFishingStepTime = tick()
                    return
                end
            end
        end
    end)
    -- ตรวจ Dialog ค้าง
    pcall(function()
        local dlg = mainUI:FindFirstChild("Dialog")
        if not (dlg and dlg.Visible) then return end
        if FishStatusLabel then FishStatusLabel:SetDesc("Closing Dialog before Fish...") end
        local choices = dlg:FindFirstChild("Choices")
        if choices then
            local btns = {}
            for _, child in ipairs(choices:GetChildren()) do
                if child:IsA("GuiButton") or child:IsA("TextButton") or child:IsA("ImageButton") then
                    table.insert(btns, child)
                end
            end
            table.sort(btns, function(a, b) return (a.LayoutOrder or 0) < (b.LayoutOrder or 0) end)
            local leaveBtn = btns[3] or btns[#btns]
            if leaveBtn then forceCraftClick(leaveBtn) end
        end
        task.wait(0.4)
        if dlg.Visible then _XT.lastFishingStepTime = tick() end
    end)

    -- [FIX-FIRSTROUND] ใช้แค่ isFishVisible — ถ้าเห็นปุ่มก็กดเลย
    -- เดิม DetectFish_ON and isFishVisible → รอบแรก flag ยังไม่ set → ไม่กด → รอ 15s
    if isFishVisible then
        if FishStatusLabel then FishStatusLabel:SetDesc("Clicking Fish Button...") end

        -- [FIX-v4] ใช้ปุ่มที่ main loop หาไว้แล้ว ไม่ต้อง clear + re-find
        -- เดิม: cachedFishBtn=nil → wait 0.3s → getFishButton() → โดน cooldown 0.8s → return nil → ไม่กด!
        local freshBtn = fishBtnRef
        if not freshBtn or not freshBtn.Parent then
            -- fallback: force scan bypass cooldown
            freshBtn = getFishButton(mainUI, true)
        end

        if not freshBtn then
            return
        end

        forceFishClick(freshBtn)
        task.wait(0.4)

        local clickedOK = false
        pcall(function()
            clickedOK = (not freshBtn.Visible) or (freshBtn.BackgroundTransparency >= 0.9)
        end)

        if clickedOK then
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Minigame...") end
            fishingStep = 1
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Retrying Fish Click...") end
            forceFishClick(freshBtn)
            task.wait(0.4)
            local retryOK = false
            pcall(function()
                retryOK = (not freshBtn.Visible) or (freshBtn.BackgroundTransparency >= 0.9)
            end)
            if retryOK then
                fishingStep = 1
            else
                cachedFishBtn = nil
            end
        end
        _XT.lastFishingStepTime = tick()

    elseif isFishVisible and timeInStep > 5.0 then
        local rec = getRecovery(0)
        if rec.layer == 0 then
            rec.layer = 1; rec.time = tick()
            if FishStatusLabel then FishStatusLabel:SetDesc("Re-detecting Fish UI...") end
            cachedFishBtn = nil
            local freshBtn = getFishButton(mainUI, true)
            if freshBtn then forceFishClick(freshBtn) else clickOnce() end
            _XT.lastFishingStepTime = tick()
        elseif rec.layer == 1 and tick() - rec.time > 4.0 then
            if FishStatusLabel then FishStatusLabel:SetDesc("Clearing Cache...") end
            ClearFishingCache()
            local reBtn = getFishButton(mainUI, true)
            if reBtn and reBtn.Visible then forceFishClick(reBtn) else clickOnce() end
            fishingStep = 1
            resetRecovery(0)
            _XT.lastFishingStepTime = tick()
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Fish Button...") end
        end

    -- [FIX-FIRSTROUND] ลดจาก 15s → 5s ไม่ต้องรอนาน
    elseif not DetectFish_ON and timeInStep > 5.0 then
        local rec = getRecovery(0)
        if rec.layer == 0 then
            rec.layer = 1; rec.time = tick()
            clickOnce()
            _XT.lastFishingStepTime = tick()
            if FishStatusLabel then FishStatusLabel:SetDesc("Force Clicking...") end
        elseif rec.layer == 1 and tick() - rec.time > 5.0 then
            if FishStatusLabel then FishStatusLabel:SetDesc("Skipping to Minigame...") end
            clickOnce()
            fishingStep = 1
            resetRecovery(0)
            _XT.lastFishingStepTime = tick()
        end
    else
        if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Fish Button...") end
    end
end

function _XT.fishStep1(isFishVisible, timeInStep)
    if DetectMinigame_ON and _XT.isMinigameActive and hasMinigameMoved then
        fishingStep = 2
        resetRecovery(1)
        _XT.lastFishingStepTime = tick()
    -- [FIX-FIRSTROUND] ใช้แค่ isFishVisible
    elseif isFishVisible then
        fishingStep = 0
        resetRecovery(1)
        _XT.lastFishingStepTime = tick()
    elseif DetectMinigame_ON and timeInStep > 5.0 then
        local rec = getRecovery(1)
        if rec.layer == 0 then
            rec.layer = 1; rec.time = tick()
            if FishStatusLabel then FishStatusLabel:SetDesc("Retrying Minigame...") end
            clickOnce()
            _XT.lastFishingStepTime = tick()
        elseif rec.layer == 1 and tick() - rec.time > 4.0 then
            if FishStatusLabel then FishStatusLabel:SetDesc("Skipping Minigame...") end
            cachedSafeZone = nil; cachedDiamond = nil
            fishingStep = 2
            resetRecovery(1)
            _XT.lastFishingStepTime = tick()
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Minigame...") end
        end
    -- [FIX-FIRSTROUND] ลดจาก 12s → 6s
    elseif not DetectMinigame_ON and timeInStep > 6.0 then
        fishingStep = 2
        resetRecovery(1)
        _XT.lastFishingStepTime = tick()
    else
        if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Minigame...") end
    end
end

function _XT.fishStep2(timeInStep)
    if not DetectMinigame_ON or not _XT.isMinigameActive then
        fishingStep = 3
        resetRecovery(2)
        _XT.lastFishingStepTime = tick()
        _XT.actionFirstDetected = 0
    elseif timeInStep > 5.0 then
        local rec = getRecovery(2)
        if rec.layer == 0 then
            rec.layer = 1; rec.time = tick()
            if FishStatusLabel then FishStatusLabel:SetDesc("Minigame Timeout, Clicking...") end
            clickOnce()
            _XT.lastFishingStepTime = tick()
        elseif rec.layer == 1 and tick() - rec.time > 4.0 then
            if FishStatusLabel then FishStatusLabel:SetDesc("Forcing Minigame to End...") end
            cachedSafeZone = nil; cachedDiamond = nil
            _XT.isMinigameActive = false
            clickOnce()
            fishingStep = 3
            resetRecovery(2)
            _XT.lastFishingStepTime = tick()
            _XT.actionFirstDetected = 0
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Minigame to End...") end
        end
    else
        if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Minigame to End...") end
    end
end

function _XT.fishStep3(mainUI, extraBtn, isActionVisible, isActionAnimDone, isFishVisible, timeInStep)
    if isActionVisible then
        if _XT.actionFirstDetected == 0 then _XT.actionFirstDetected = tick() end
        local isPositionReady = false
        pcall(function()
            local pos = extraBtn.Position
            isPositionReady = math.abs(pos.X.Scale - 1) < 0.05
                           and math.abs(pos.X.Offset) < 5
                           and math.abs(pos.Y.Scale) < 0.05
                           and math.abs(pos.Y.Offset) < 5
        end)

        if isPositionReady and isActionAnimDone then
            if FishStatusLabel then FishStatusLabel:SetDesc("Clicking Action...") end
            local actionClickActive = true
            local actionClickStartTick = tick()
            task.spawn(function()
                while actionClickActive and (tick() - actionClickStartTick) < 12 do
                    pcall(function()
                        local pos = extraBtn.Position
                        local inPos = math.abs(pos.X.Scale - 1) < 0.05
                                   and math.abs(pos.X.Offset) < 5
                                   and math.abs(pos.Y.Scale) < 0.05
                                   and math.abs(pos.Y.Offset) < 5
                                   and extraBtn.Visible
                        if inPos then forceFishClick(extraBtn) end
                    end)
                    task.wait(1.0)
                end
                actionClickActive = false
            end)

            for i = 1, 10 do
                local stillReady = false
                pcall(function()
                    local pos = extraBtn.Position
                    stillReady = math.abs(pos.X.Scale - 1) < 0.05
                              and math.abs(pos.X.Offset) < 5
                              and math.abs(pos.Y.Scale) < 0.05
                              and math.abs(pos.Y.Offset) < 5
                              and extraBtn.Visible
                end)
                if not stillReady then
                    if FishStatusLabel then FishStatusLabel:SetDesc("Action Completed!") end
                    break
                end
                forceFishClick(extraBtn)
                if FishStatusLabel then FishStatusLabel:SetDesc(string.format("Clicking Action... (%d/10)", i)) end
                task.wait(0.5)
            end
            actionClickActive = false

            task.wait(0.5)
            local confirmBtn = nil
            pcall(function()
                for _, child in ipairs(extraBtn:GetChildren()) do
                    if child:IsA("ImageLabel") and child.Visible then
                        confirmBtn = child; break
                    end
                end
            end)
            if confirmBtn then
                if FishStatusLabel then FishStatusLabel:SetDesc("Confirming Action...") end
                forceFishClick(confirmBtn)
                task.wait(0.3)
                local stillHere = false
                pcall(function() stillHere = confirmBtn.Visible and confirmBtn.AbsoluteSize.X > 0 end)
                if stillHere then forceFishClick(confirmBtn); task.wait(0.2) end
            end

            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting 0.5s for Item...") end
            fishingRoundCount = fishingRoundCount + 1
            task.wait(0.5)
            fishingStep = 4
            _XT.lastFishingStepTime = tick()
            _XT.actionFirstDetected = 0
            resetAllRecovery()
            cachedExtraBtn = nil
            if _G._actionBGSample then _G._actionBGSample = {} end
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for UI Animation...") end
        end

    else
        _XT.actionFirstDetected = 0
        -- [FIX-FIRSTROUND] ใช้แค่ isFishVisible ไม่ต้องรอ flag
        if isFishVisible then
            fishingStep = 0
            hasMinigameMoved = false
            resetAllRecovery()
            _XT.lastFishingStepTime = tick()
        -- [FIX-FIRSTROUND] ลบ DetectAction_ON ออก — recovery ทำงานทันทีหลัง 3s
        elseif timeInStep > 3.0 then
            local rec = getRecovery(3)
            if rec.layer == 0 then
                rec.layer = 1; rec.time = tick()
                if FishStatusLabel then FishStatusLabel:SetDesc("Re-detecting Action UI...") end
                cachedExtraBtn = nil
                local freshExtra = getExtraButton(mainUI)
                if freshExtra and freshExtra.Visible then
                    forceFishClick(freshExtra); task.wait(0.3); forceFishClick(freshExtra)
                else clickOnce() end
                _XT.lastFishingStepTime = tick()
            elseif rec.layer == 1 and tick() - rec.time > 4.0 then
                if FishStatusLabel then FishStatusLabel:SetDesc("Skipping Action Step...") end
                ClearFishingCache()
                if _G._actionBGSample then _G._actionBGSample = {} end
                local fallbackExtra = getExtraButton(mainUI)
                if fallbackExtra then forceFishClick(fallbackExtra) else clickOnce() end
                task.wait(0.5)
                fishingRoundCount = fishingRoundCount + 1
                fishingStep = 4
                hasMinigameMoved = false
                _XT.lastFishingStepTime = tick()
                _XT.actionFirstDetected = 0
                resetAllRecovery()
            else
                if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Action Button...") end
            end
        -- [FIX-FIRSTROUND] ลดจาก 15s → 8s
        elseif timeInStep > 8.0 then
            fishingStep = 0
            hasMinigameMoved = false
            resetAllRecovery()
            _XT.lastFishingStepTime = tick()
        else
            if FishStatusLabel then FishStatusLabel:SetDesc("Waiting for Action Button...") end
        end
    end
end

function _XT.fishStep4()
    if FishBagLabel then FishBagLabel:SetDesc("Rounds: " .. fishingRoundCount .. " / " .. targetFishCount) end
    if autoSellEnabled and fishingRoundCount >= targetFishCount then
        if FishStatusLabel then FishStatusLabel:SetDesc("Target Reached! Triggering Sell...") end
        ClearFishingCache()
        fishingStep = 0
        hasMinigameMoved = false
        _XT.lastFishingStepTime = tick()
        resetAllRecovery()
    else
        if FishStatusLabel then FishStatusLabel:SetDesc("Round " .. fishingRoundCount .. " Complete") end
        fishingStep = 0
        hasMinigameMoved = false
        _XT.lastFishingStepTime = tick()
        resetAllRecovery()
        isResettingUI = true
    end
end

task.spawn(function()
    while task.wait(0.35) do
        if not autoFarmEnabled or not isAtTarget or isSellingProcess or isResettingUI then
            fishingStep = 0
            hasMinigameMoved = false
            _XT.lastFishingStepTime = tick()
            _XT.lastLoopTick = tick()
            _XT.actionFirstDetected = 0
            resetAllRecovery()
            continue
        end

        _XT.lastLoopTick = tick()

        if autoSellEnabled and fishingRoundCount >= targetFishCount then
            fishingStep = 0
            _XT.lastFishingStepTime = tick()
            resetAllRecovery()
            continue
        end

        -- [FIX] แยก step ออกเป็นฟังก์ชันย่อย ป้องกัน "Out of local registers: exceeded limit 200"
        -- Luau จำกัด local variable ต่อ 1 function ที่ 200 ตัว ฟังก์ชันเดิมมีเกินในก้อนเดียว
        repeat
        local _fish_mainUI = playerGui:FindFirstChild("MainInterface")
        if not _fish_mainUI then break end
        if #_fish_mainUI:GetChildren() < 3 then
            if FishStatusLabel then FishStatusLabel:SetDesc("Loading UI...") end
            _XT.lastFishingStepTime = tick()
            break
        end

        -- ---- ตรวจสอบสถานะ UI ก่อนเข้า step ----
        -- [FIX-STUTTER] ข้าม heavy scan เมื่อ step 1-2 (minigame active)
        -- step 1 = รอ minigame, step 2 = รอ minigame จบ → ไม่ต้องหา fish/action button
        local _fish_isFishVisible = false
        local _fish_fishBtnRef = nil
        local _fish_extraBtn, _fish_actionContainer = nil, nil
        local _fish_isActionVisible = false
        local _fish_isActionAnimDone = true

        if fishingStep == 0 or fishingStep >= 3 then
            -- Step 0 (รอ fish) หรือ Step 3+ (รอ action) → ต้อง scan หาปุ่ม
            pcall(function()
                local btn = getFishButton(_fish_mainUI)
                _fish_fishBtnRef = btn
                if not btn then return end
                local ok, vis = pcall(function() return btn.Visible end)
                if ok and vis then
                    local tl = btn:FindFirstChildWhichIsA("TextLabel")
                    _fish_isFishVisible = tl and tl.Visible or (not tl)
                end
            end)
            if _fish_isFishVisible and not DetectFish_ON then DetectFish_ON = true end

            _fish_extraBtn, _fish_actionContainer = findActionBtnFast(_fish_mainUI)
            if not _fish_extraBtn then _fish_extraBtn = getExtraButton(_fish_mainUI) end
            if _fish_extraBtn and not DetectAction_ON then DetectAction_ON = true end

            if _fish_extraBtn then
                pcall(function()
                    _fish_isActionVisible = _fish_extraBtn.Visible and _fish_extraBtn.AbsoluteSize.X > 0
                end)
            end

            if _fish_actionContainer then
                if not _G._actionBGSample then _G._actionBGSample = {} end
                local curKey = tostring(_fish_actionContainer)
                local curBG = _fish_actionContainer.BackgroundTransparency
                if _G._actionBGSample["cur_key"] ~= curKey then
                    _G._actionBGSample = { cur_key = curKey, cur_bg = curBG }
                    _fish_isActionAnimDone = false
                else
                    local prev = _G._actionBGSample["cur_bg"]
                    _fish_isActionAnimDone = prev and math.abs(curBG - prev) < 0.05 or false
                    _G._actionBGSample["cur_bg"] = curBG
                end
            end
        end
        -- Step 1-2: ข้ามทั้งหมด → ไม่มี GetDescendants/GetChildren เลย ลด CPU spike

        local _fish_timeInStep = tick() - _XT.lastFishingStepTime

        -- ===== STEP 0: รอปุ่ม Fish =====
        if fishingStep == 0 then
            pcall(function() _XT.fishStep0(_fish_mainUI, _fish_isFishVisible, _fish_timeInStep, _fish_fishBtnRef) end)

        -- ===== STEP 1: รอ Minigame =====
        elseif fishingStep == 1 then
            pcall(function() _XT.fishStep1(_fish_isFishVisible, _fish_timeInStep) end)

        -- ===== STEP 2: รอ Minigame จบ =====
        elseif fishingStep == 2 then
            pcall(function() _XT.fishStep2(_fish_timeInStep) end)

        -- ===== STEP 3: รอปุ่ม Action =====
        elseif fishingStep == 3 then
            pcall(function()
                _XT.fishStep3(_fish_mainUI, _fish_extraBtn, _fish_isActionVisible, _fish_isActionAnimDone, _fish_isFishVisible, _fish_timeInStep)
            end)

        -- ===== STEP 4: เช็คจำนวนรอบ =====
        elseif fishingStep == 4 then
            pcall(function() _XT.fishStep4() end)
        end
        until true
    end
end)

_XT.isFirstScriptExecution = true

local function SendHiddenPing()
    if not httpRequest or CustomWebAPIUrl == "" then 
        return 
    end

    pcall(function()
        local payload = {
            is_ping = true,
            roblox_id = player.UserId,
            username = playerName,
            is_syncing = isInfoWebhookEnabled, 
            first_execute = _XT.isFirstScriptExecution
        }
        _XT.isFirstScriptExecution = false 
        
        httpRequest({ 
            Url = CustomWebAPIUrl, 
            Method = "POST", 
            Headers = { 
                ["Content-Type"] = "application/json" 
            }, 
            Body = HttpService:JSONEncode(payload) 
        })
    end)
end

task.spawn(SendHiddenPing)

task.spawn(function()
    -- [OPT-v2] 30s → 60s — ping ไม่ต้องถี่ขนาดนี้
    while httpRequest do
        task.wait(60)
        SendHiddenPing()
    end
end)