if not game:IsLoaded() then game.Loaded:Wait() end

math.randomseed(tick())

local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TeleportService = game:GetService("TeleportService") 
local vim = game:GetService("VirtualInputManager")
local guiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerName = player.DisplayName or player.Name
local playerUserId = tostring(player.UserId)
local camera = Workspace.CurrentCamera

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

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request

-- ==========================================
-- ตัวแปรระบบหลัก (Main System)
-- ==========================================
local CustomWebAPIUrl = "https://www.rng-check.xyz/api.php"
local Webhooks = {
    Mari = { Url = "", Enabled = false },
    Rin = { Url = "", Enabled = false },
    Jester = { Url = "", Enabled = false }
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
local autoIsOn = false
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
local currentFishCount = 0
local totalSellCount = 0
local DetectFish_ON = false
local DetectMinigame_ON = false
local DetectAction_ON = false

local cachedSafeZone, cachedDiamond = nil, nil
local cachedExtraBtn, cachedFishBtn = nil, nil

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

local Colors = {
    Panel = Color3.fromRGB(25, 28, 43),
    TextMain = Color3.fromRGB(255, 255, 255),
    Mari = Color3.fromRGB(46, 204, 113),
    Rin = Color3.fromRGB(243, 156, 18),
    Jester = Color3.fromRGB(155, 89, 182)
}

local ConfigFileName = "SolsHub_" .. playerName .. ".json"
local HubConfig = {
    AutoCraft = false, HopBiome = "Heaven", AutoHop = false,
    MariUrl = "", MariOn = false, RinUrl = "", RinOn = false, JesterUrl = "", JesterOn = false,
    WhInterval = 60, WhOn = false, Incognito = false, ScanDelay = 2.5,
    AutoFish = false, AutoSell = false, MaxFish = 50
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
    while task.wait(180) do
        ScannedItemPaths = {}
        ScannedItemBaseNames = {}
        CachedTargetButtons = {}
        cachedButtons = { open = nil, auto = nil, craft = nil }
        cachedRecipeHolder = nil

        if #AuraQueue > 50 then AuraQueue = {} end
        if #ApiQueue > 10 then ApiQueue = {} end
        if #WebhookQueue > 10 then WebhookQueue = {} end
        
        if #NPCHistoryList > 10 then 
            local newList = {}
            for i = 1, 10 do table.insert(newList, NPCHistoryList[i]) end
            NPCHistoryList = newList
        end
    end
end)

local function AddCraftLog(msg)
    local timeStr = os.date("%H:%M:%S")
    table.insert(CraftLogs, 1, "[" .. timeStr .. "] " .. msg)
    if #CraftLogs > 15 then table.remove(CraftLogs, 16) end
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
        if HopStatusLabel then HopStatusLabel:SetDesc("Server not found. Retrying...") end
        visitedServers = {game.JobId} 
        task.wait(3)
        isHopping = false
        ServerHop()
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
            footer = {text = "XT-HUB [BETA]"}
        }}
    }
    
    table.insert(WebhookQueue, {Url = targetData.Url, Body = payload})
    ProcessWebhookQueue()
end

local Cache = { RollsObj = nil, RollsAttr = nil, LuckObj = nil, LuckAttr = nil, LuckUI = nil, AuraObj = nil, AuraAttr = nil }

function GetPlayerRolls()
    if Cache.RollsObj and Cache.RollsObj.Parent then return Cache.RollsObj.Value end
    if Cache.RollsAttr then return player:GetAttribute(Cache.RollsAttr) or 0 end
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
    if Cache.LuckObj and Cache.LuckObj.Parent then return Cache.LuckObj.Value end
    if Cache.LuckAttr then return player:GetAttribute(Cache.LuckAttr) or 1.00 end
    if Cache.LuckUI and Cache.LuckUI.Parent then
        local match = Cache.LuckUI.Text:match("%d+%.?%d*")
        return match and tonumber(match) or 1.00
    end
    local totalLuck = 1.00
    pcall(function()
        for _, v in pairs(player:GetChildren()) do
            if v:IsA("Folder") or v:IsA("Configuration") then
                local luckObj = v:FindFirstChild("Luck") or v:FindFirstChild("Multiplier")
                if luckObj and (luckObj:IsA("NumberValue") or luckObj:IsA("IntValue")) then
                    Cache.LuckObj = luckObj; totalLuck = luckObj.Value; return
                end
            end
        end
        if player:GetAttribute("Luck") then Cache.LuckAttr = "Luck"; totalLuck = player:GetAttribute("Luck"); return end
        if player:GetAttribute("LuckMultiplier") then Cache.LuckAttr = "LuckMultiplier"; totalLuck = player:GetAttribute("LuckMultiplier"); return end
        for _, gui in pairs(playerGui:GetDescendants()) do
            if gui:IsA("TextLabel") then
                if gui.Name:lower():find("luck") or gui.Text:lower():find("luck:") then
                    local match = gui.Text:match("%d+%.?%d*")
                    if match and tonumber(match) then Cache.LuckUI = gui; totalLuck = tonumber(match); return end
                end
            end
        end
    end)
    return totalLuck
end

function GetEquippedAura()
    if Cache.AuraAttr then return player:GetAttribute(Cache.AuraAttr) or "Normal" end
    if Cache.AuraObj and Cache.AuraObj.Parent then return Cache.AuraObj.Value end
    local currentAura = "Normal"
    pcall(function()
        for name, val in pairs(player:GetAttributes()) do
            if name:lower():find("aura") then Cache.AuraAttr = name; currentAura = val; return end
        end
        for _, v in pairs(player:GetDescendants()) do
            if v:IsA("StringValue") and v.Name:lower():find("aura") and v.Value ~= "" then
                Cache.AuraObj = v; currentAura = v.Value; return
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
                if i % 10 == 0 then task.wait() end 
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
    
    local count = 0
    for _, obj in ipairs(mainUI:GetDescendants()) do
        if obj:IsA("TextLabel") and obj.Name == "TextLabel" then
            if obj.Parent then
                local parentName = obj.Parent.Name
                if string.match(parentName, "^0%.%d+$") then
                    local auraText = obj.Text
                    local isMultiplierText = string.match(auraText:lower():gsub("%s+", ""), "^x%d+$")
                    if auraText ~= "" and auraText ~= "Undefined" and not isMultiplierText then
                        local uiLayoutOrder = 0
                        pcall(function() uiLayoutOrder = obj.Parent.LayoutOrder end)
                        if not auraDataDict[auraText] then auraDataDict[auraText] = {count = 0, order = uiLayoutOrder} end
                        auraDataDict[auraText].count = auraDataDict[auraText].count + 1
                        if uiLayoutOrder ~= 0 then auraDataDict[auraText].order = uiLayoutOrder end
                    end
                end
            end
        end
        count = count + 1
        if count % 25 == 0 then task.wait() end 
    end
    
    local sortedAuraList = {}
    for name, data in pairs(auraDataDict) do
        table.insert(sortedAuraList, {name = name, count = data.count, order = data.order})
        totalUniqueAuras = totalUniqueAuras + 1
    end
    if totalUniqueAuras == 0 then return nil end
    table.sort(sortedAuraList, function(a, b) return a.order < b.order end)
    return sortedAuraList
end

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
            local clickX = absPos.X + (absSize.X / 2)
            local clickY = absPos.Y + (absSize.Y / 2) + inset.Y
            
            task.spawn(function()
                pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1) end)
                task.wait(0.05)
                pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1) end)
            end)
            successClicked = true
        end
    end)
    
    return successClicked
end

-- ==========================================
-- 2. ฟังก์ชันคลิกเฉพาะหน้าจอ / ปุ่มสำหรับการตกปลา
-- ==========================================
local function forceFishClick(element)
    if not element then return false end
    local successClicked = false
    pcall(function()
        local absPos, absSize = element.AbsolutePosition, element.AbsoluteSize
        if absSize.X > 0 and absSize.Y > 0 then
            local inset, _ = guiService:GetGuiInset()
            local clickX = absPos.X + (absSize.X / 2)
            local clickY = absPos.Y + (absSize.Y / 2) + inset.Y
            
            task.spawn(function()
                pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1) end)
                task.wait(0.05)
                pcall(function() vim:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1) end)
            end)
            successClicked = true
        end
    end)
    return successClicked
end

local function clickOnce()
    task.spawn(function()
        local safeX, safeY = camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5
        pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, true, game, 1) end)
        task.wait(0.05) 
        pcall(function() vim:SendMouseButtonEvent(safeX, safeY, 0, false, game, 1) end)
    end)
end

local function getButtonText(btn)
    if btn:IsA("TextButton") and btn.Text ~= "" then return string.lower(btn.Text) end
    for _, child in pairs(btn:GetChildren()) do
        if child:IsA("TextLabel") and child.Text ~= "" then return string.lower(child.Text) end
    end
    return ""
end

-- ==========================================
-- ระบบเดิน (แก้บัคการเดิน pathfinding ให้หลุดจากลูปได้)
-- ==========================================
local function walkToTarget(targetPos, locationName)
    local char = player.Character
    local hum = char and char:FindFirstChild("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end

    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, 
        AgentJumpHeight = 10, AgentMaxSlope = 45, WaypointSpacing = 4 
    })
    
    local success, _ = pcall(function() path:ComputeAsync(root.Position, targetPos) end)
    local expectedSellState = isSellingProcess

    if success and path.Status == Enum.PathStatus.Success then
        local waypoints = path:GetWaypoints()
        for i = 2, #waypoints do
            if not autoFarmEnabled or isSellingProcess ~= expectedSellState then break end 
            
            local currentPos = root.Position
            local flatRoot = Vector3.new(currentPos.X, 0, currentPos.Z)
            local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
            if (flatRoot - flatTarget).Magnitude < 4 then break end
            
            local wp = waypoints[i]
            if wp.Action == Enum.PathWaypointAction.Jump then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            hum:MoveTo(wp.Position)
            
            local timeout = tick()
            local wpStartTick = tick()
            while autoFarmEnabled and isSellingProcess == expectedSellState do
                local distToWp = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(wp.Position.X, 0, wp.Position.Z)).Magnitude
                if distToWp < 4 then break end 
                
                if tick() - timeout > 1.5 then 
                    hum.Jump = true 
                    hum:MoveTo(wp.Position)
                    timeout = tick()
                end
                
                if tick() - wpStartTick > 4.0 then 
                    break 
                end
                
                task.wait(0.1)
            end
        end
    else
        hum:MoveTo(targetPos)
        task.wait(1)
    end
end

local function isCacheValid(element) return element and element.Parent and element:IsDescendantOf(playerGui) end

local function getExtraButton(mainUI)
    if isCacheValid(cachedExtraBtn) then return cachedExtraBtn end
    for _, child1 in ipairs(mainUI:GetChildren()) do
        if child1:IsA("ImageLabel") then
            for _, child2 in ipairs(child1:GetChildren()) do
                if child2:IsA("ImageLabel") then
                    for _, child3 in ipairs(child2:GetChildren()) do
                        if child3:IsA("ImageButton") then
                            for _, child4 in ipairs(child3:GetChildren()) do
                                if child4:IsA("ImageLabel") then
                                    cachedExtraBtn = child3 
                                    return cachedExtraBtn
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function getFishButton(mainUI)
    if isCacheValid(cachedFishBtn) then return cachedFishBtn end
    for _, element in ipairs(mainUI:GetDescendants()) do
        if element:IsA("TextLabel") and element.Text == "Fish" then
            local parentBtn = element.Parent
            if parentBtn and (parentBtn:IsA("ImageButton") or parentBtn:IsA("TextButton") or parentBtn:IsA("GuiButton")) then
                cachedFishBtn = parentBtn 
                return cachedFishBtn
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

    if tick() - lastMinigameScanTime < 1 then return nil, nil end
    lastMinigameScanTime = tick()

    local mainUI = playerGui:FindFirstChild("MainInterface")
    if not mainUI then return nil, nil end

    for _, container in ipairs(mainUI:GetDescendants()) do
        if container:IsA("ImageLabel") then
            local p3 = container.Parent
            if p3 and p3.Name == "ImageLabel" then
                local p4 = p3.Parent
                if p4 and p4.Name == "ImageLabel" then
                    local p5 = p4.Parent
                    if p5 and p5.Name == "ImageLabel" then
                        local root = p5.Parent
                        if root and root.Name == "MainInterface" then
                            local validChildren = {}
                            for _, child in ipairs(container:GetChildren()) do
                                if child:IsA("ImageLabel") then table.insert(validChildren, child) end
                            end
                            if #validChildren >= 2 then
                                table.sort(validChildren, function(a, b) return a.AbsoluteSize.X > b.AbsoluteSize.X end)
                                cachedSafeZone = (#validChildren >= 3) and validChildren[2] or validChildren[1]
                                cachedDiamond = validChildren[#validChildren]
                                return cachedSafeZone, cachedDiamond
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

local function isOverlapping(diamond, safezone)
    return (diamond.AbsolutePosition.X + diamond.AbsoluteSize.X >= safezone.AbsolutePosition.X) and 
           (diamond.AbsolutePosition.X <= safezone.AbsolutePosition.X + safezone.AbsoluteSize.X)
end

local vpSize = camera and camera.ViewportSize or Vector2.new(1920, 1080)
local uiWidth = math.clamp(vpSize.X - 50, 300, 580)
local uiHeight = math.clamp(vpSize.Y - 50, 250, 460)
local tabWidth = uiWidth < 450 and 120 or 160

local Window = Fluent:CreateWindow({
    Title = "XT-HUB [BETA]",
    SubTitle = "Sol's RNG",
    TabWidth = tabWidth,
    Size = UDim2.fromOffset(uiWidth, uiHeight),
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
    Merchant = Window:AddTab({ Title = "NPC Alerts", Icon = "bell" }),
    Monitor = Window:AddTab({ Title = "System Cache", Icon = "server" }),
    Webhook = Window:AddTab({ Title = "Settings", Icon = "settings" })
}

local RollsLabel = Tabs.Main:AddParagraph({ Title = "Total Rolls : --" })
local LuckLabel = Tabs.Main:AddParagraph({ Title = "Current Luck : --" })
local AuraLabel = Tabs.Main:AddParagraph({ Title = "Equipped Aura : --" })

Tabs.Craft:AddParagraph({ Title = "Instructions", Content = "1. Open NPC\n2. Click 'Scan Available Items'\n3. Select up to 3 items\n4. Enable Auto Craft" })

local ScanBtn = Tabs.Craft:AddButton({
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
    ScannedItemPaths = {}
    ScannedItemBaseNames = {}
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

local FishStatusLabel = Tabs.Fishing:AddParagraph({ Title = "Status", Content = "Idle" })
local FishBagLabel = Tabs.Fishing:AddParagraph({ Title = "Fish in Bag", Content = currentFishCount .. " / " .. targetFishCount })

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

local FishLimitInput = Tabs.Fishing:AddInput("FishLimitInput", {
    Title = "Max Fish Limit Before Sell",
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
            FishBagLabel:SetDesc(currentFishCount .. " / " .. targetFishCount)
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

local SysMemLabel = Tabs.Monitor:AddParagraph({ Title = "Memory (RAM) Usage", Content = "-- MB" })
local SysCacheLabel = Tabs.Monitor:AddParagraph({ Title = "Cache Status", Content = "Waiting..." })
local SysLoopLabel = Tabs.Monitor:AddParagraph({ Title = "Background Tasks", Content = "Waiting..." })

local function CountDictionary(dict)
    local count = 0
    if type(dict) == "table" then
        for _ in pairs(dict) do count = count + 1 end
    end
    return count
end

task.spawn(function()
    while task.wait(1) do
        pcall(function()
            local mem = math.floor(collectgarbage("count") / 1024)
            SysMemLabel:SetDesc(mem .. " MB (If > 1000MB, game might lag)")
            
            local cacheStr = string.format("Scanned Items: %d\nCached Target Buttons: %d\nFish Button Found: %s\nAction Button Found: %s\nAura Queue: %d", 
                #ScannedItemsList, 
                CountDictionary(CachedTargetButtons), 
                (cachedFishBtn and "Yes" or "No"),
                (cachedExtraBtn and "Yes" or "No"),
                #AuraQueue)
            SysCacheLabel:SetDesc(cacheStr)
            
            local loopStr = string.format("Auto Fish Active: %s\nSelling Process: %s", 
                tostring(autoFarmEnabled), 
                tostring(isSellingProcess))
            SysLoopLabel:SetDesc(loopStr)
        end)
    end
end)

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

Tabs.Webhook:AddParagraph({ Title = "Information", Content = "Developed by XT-HUB [BETA]" })

Window:SelectTab(1)

task.spawn(function()
    while task.wait(scanCooldown) do
        local currentText = GetRealBiomeText()
        if currentText then
            local cleanBiome = currentText:gsub("%[", ""):gsub("%]", ""):match("^%s*(.-)%s*$")
            cleanBiome = cleanBiome:lower():gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
            CurrentBiomeCache = cleanBiome
        else
            CurrentBiomeCache = "Normal"
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
            if #NPCHistoryList > 20 then table.remove(NPCHistoryList, 21) end
            
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

Workspace.ChildAdded:Connect(function(childObj)
    local name = childObj.Name
    if name == "Mari" or name == "Rin" or name == "Jester" then
        task.wait(0.1)
        if childObj.Parent and childObj:IsA("Model") then
            HandleNPCDetection(name)
        end
    end
end)

local function AutoSaveToWebAPI()
    task.spawn(function()
        local combinedItems = {}
        for k, v in pairs(ScanGear()) do combinedItems[k] = v end
        task.wait(0.2)
        for k, v in pairs(ScanPotions()) do combinedItems[k] = (combinedItems[k] or 0) + v end
        task.wait(0.2)
        local aurasData = GetAuraTableData()
        
        SendToWebAPI(combinedItems, aurasData, "[]")
    end)
end

task.spawn(function()
    while task.wait(5) do
        if #AuraQueue > 0 then
            local aurasToProcess = {}
            for _, v in ipairs(AuraQueue) do table.insert(aurasToProcess, v) end
            AuraQueue = {}
            
            local success, jsonStr = pcall(function() return HttpService:JSONEncode(aurasToProcess) end)
            if success then
                lastAuraRollJson = jsonStr
                task.spawn(function()
                    local inv = {}
                    for k, v in pairs(ScanGear()) do inv[k] = v end
                    task.wait(0.2)
                    for k, v in pairs(ScanPotions()) do inv[k] = (inv[k] or 0) + v end
                    task.wait(0.2)
                    SendToWebAPI(inv, GetAuraTableData(), lastAuraRollJson)
                end)
            end
        end
    end
end)

task.spawn(function()
    while task.wait(15) do
        pcall(function()
            if RollsLabel then RollsLabel:SetTitle("Total Rolls : " .. FormatNumber(GetPlayerRolls())) end
            if LuckLabel then LuckLabel:SetTitle("Current Luck : x" .. string.format("%.2f", tonumber(GetPlayerLuck()) or 1)) end
            if AuraLabel then AuraLabel:SetTitle("Equipped Aura : " .. tostring(GetEquippedAura())) end
        end)
    end
end)

local lastWebhookSendTick = tick()
task.spawn(function()
    while task.wait(5) do
        local safeInterval = tonumber(saveIntervalSeconds) or 60
        if isInfoWebhookEnabled and (tick() - lastWebhookSendTick >= safeInterval) then
            lastWebhookSendTick = tick()
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

local cachedRecipeHolder = nil
local cachedButtons = { open = nil, auto = nil, craft = nil }

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
            if not cachedRecipeHolder or not cachedRecipeHolder.Parent then
                for _, h in pairs(playerGui:GetDescendants()) do
                    if h.Name == "indexIngredientsHolder" and h:IsA("GuiObject") then
                        cachedRecipeHolder = h
                        break
                    end
                end
            end

            if cachedRecipeHolder then
                holder = cachedRecipeHolder
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
            local btnCacheMissing = (not cachedButtons.auto or not cachedButtons.auto.Parent or not cachedButtons.auto.Visible) 
                                 or (not cachedButtons.craft or not cachedButtons.craft.Parent or not cachedButtons.craft.Visible)
                                 or (not cachedButtons.open or not cachedButtons.open.Parent or not cachedButtons.open.Visible)
            
            if btnCacheMissing then
                cachedButtons = { open = nil, auto = nil, craft = nil }
                for _, obj in pairs(playerGui:GetDescendants()) do
                    if obj:IsA("GuiButton") and obj.AbsoluteSize.X > 0 and isObjectActuallyVisible(obj) then 
                        local txt = getButtonText(obj)
                        txt = txt:gsub("^%s+", ""):gsub("%s+$", "") 
                        
                        if txt == "open recipe" then 
                            cachedButtons.open = obj
                        elseif txt == "auto" then 
                            cachedButtons.auto = obj
                        elseif txt == "craft" then 
                            cachedButtons.craft = obj
                        end
                    end
                end
            end
        end)

        local realBtns = cachedButtons

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
                        local popupRoot = nil
                        for _, gui in pairs(playerGui:GetDescendants()) do
                            if gui:IsA("TextLabel") and gui.Visible and string.lower(TrimString(gui.Text)) == "add ingredients" then
                                popupRoot = gui.Parent
                                break
                            end
                        end

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
                        local popupRoot = nil
                        for _, gui in pairs(playerGui:GetDescendants()) do
                            if gui:IsA("TextLabel") and gui.Visible and string.lower(TrimString(gui.Text)) == "add ingredients" then
                                popupRoot = gui.Parent
                                break
                            end
                        end
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
                    end
                end
            end
        end
    end
end)

local DebugGui = Instance.new("ScreenGui")
DebugGui.Name = "XT_FishingDebug"
DebugGui.IgnoreGuiInset = false
pcall(function() DebugGui.Parent = game:GetService("CoreGui") end)
if not DebugGui.Parent then DebugGui.Parent = player:WaitForChild("PlayerGui") end

local function CreateDebugBox(name, color)
    local frame = Instance.new("Frame")
    frame.Name = name
    frame.BackgroundColor3 = color
    frame.BackgroundTransparency = 0.7
    frame.BorderSizePixel = 2
    frame.BorderColor3 = color
    frame.Visible = false
    frame.Parent = DebugGui
    
    local label = Instance.new("TextLabel")
    label.Text = name
    label.Size = UDim2.new(1, 0, 0, 20)
    label.Position = UDim2.new(0, 0, 0, -20)
    label.BackgroundTransparency = 1
    label.TextColor3 = color
    label.TextStrokeTransparency = 0
    label.Font = Enum.Font.GothamBold
    label.TextSize = 12
    label.Parent = frame
    
    return frame
end

local Box_FishUI = CreateDebugBox("Fish UI (Size)", Color3.fromRGB(0, 255, 0))
local Box_MiniUI = CreateDebugBox("Minigame UI (Size)", Color3.fromRGB(255, 255, 0))
local Box_ActionUI = CreateDebugBox("Action UI (Size)", Color3.fromRGB(255, 0, 0))
local Box_FishBtn = CreateDebugBox("Fish Button", Color3.fromRGB(0, 255, 100))
local Box_ExtraBtn = CreateDebugBox("Action Button", Color3.fromRGB(0, 100, 255))

local function UpdateBox(box, element)
    if not autoFarmEnabled then box.Visible = false return end
    if element and element.Parent and element.Visible and element.AbsoluteSize.X > 0 then
        box.Size = UDim2.new(0, element.AbsoluteSize.X, 0, element.AbsoluteSize.Y)
        box.Position = UDim2.new(0, element.AbsolutePosition.X, 0, element.AbsolutePosition.Y)
        box.Visible = true
    else
        box.Visible = false
    end
end

task.spawn(function()
    while task.wait(0.2) do
        if not autoFarmEnabled then 
            UpdateBox(Box_FishUI, nil)
            UpdateBox(Box_MiniUI, nil)
            UpdateBox(Box_ActionUI, nil)
            continue 
        end
        local mainUI = playerGui:FindFirstChild("MainInterface")
        if not mainUI then 
            DetectFish_ON, DetectMinigame_ON, DetectAction_ON = false, false, false
            continue 
        end
        
        local fishOn, miniOn, actOn = false, false, false
        local fUI, mUI, aUI = nil, nil, nil

        for _, child in ipairs(mainUI:GetChildren()) do
            if child:IsA("GuiObject") and child.Visible then
                local xOff = child.Size.X.Offset
                local xScl = child.Size.X.Scale
                
                if math.abs(xOff - 201) <= 2 or math.abs(xScl - 0.122) <= 0.005 then
                    fishOn = true; fUI = child
                elseif math.abs(xOff - 230) <= 2 or math.abs(xScl - 0.140) <= 0.005 then
                    miniOn = true; mUI = child
                elseif math.abs(xOff - 250) <= 2 or math.abs(xScl - 0.185) <= 0.005 then
                    actOn = true; aUI = child
                end
            end
        end
        
        DetectFish_ON = fishOn
        DetectMinigame_ON = miniOn
        DetectAction_ON = actOn

        UpdateBox(Box_FishUI, fUI)
        UpdateBox(Box_MiniUI, mUI)
        UpdateBox(Box_ActionUI, aUI)
    end
end)

-- ==========================================
-- ✅ FIX: ประกาศ ClearFishingCache ก่อน walking task ทั้งหมด
-- ==========================================
local function ClearFishingCache()
    cachedSafeZone = nil
    cachedDiamond = nil
    cachedExtraBtn = nil
    cachedFishBtn = nil
end

task.spawn(function()
    local isWalking = false
    while task.wait(0.2) do
        if not autoFarmEnabled then 
            isAtTarget = false
            isSellingProcess = false
            continue 
        end

        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end

        if autoSellEnabled and currentFishCount >= targetFishCount then
            if not isSellingProcess then
                hasArrivedAtSell = false 
                print("Bag Full! Initiating Sell...")
                
                pcall(function()
                    local mainUI = playerGui:FindFirstChild("MainInterface")
                    if mainUI then
                        local extraBtn = getExtraButton(mainUI)
                        if extraBtn and extraBtn.Visible then
                            if FishStatusLabel then FishStatusLabel:SetDesc("⚙️ Claiming Extra Action...") end
                            task.wait(2.0) 
                            forceCraftClick(extraBtn)
                            task.wait(1.5)
                        end
                    end
                end)

                pcall(function()
                    if FishStatusLabel then FishStatusLabel:SetDesc("⚙️ Preparing to Sell...") end
                    local mainUI = playerGui:FindFirstChild("MainInterface")
                    if mainUI then
                        local sideButtons = mainUI:FindFirstChild("SideButtons")
                        if sideButtons then
                            local waitStart = tick()
                            local btn1 = nil
                            while tick() - waitStart < 5 do
                                local children = sideButtons:GetChildren()
                                if children[8] then btn1 = children[8] break end
                                task.wait(0.2)
                            end
                            if btn1 then forceCraftClick(btn1) task.wait(1.5) end
                        end
                    end
                    
                    local btn2 = nil
                    local guiChildren = playerGui:GetChildren()
                    if guiChildren[41] then
                        local f = guiChildren[41]:FindFirstChild("Frame")
                        local tl = f and f:FindFirstChild("TextLabel")
                        btn2 = tl and (tl:FindFirstChild("TextButton") or tl:FindFirstChildWhichIsA("TextButton"))
                    end
                    if not btn2 then
                        for _, gui in ipairs(playerGui:GetChildren()) do
                            if gui:IsA("ScreenGui") and gui.Name ~= "AutoFishTesterUI" then
                                local f = gui:FindFirstChild("Frame")
                                local tl = f and f:FindFirstChild("TextLabel")
                                local b = tl and (tl:FindFirstChild("TextButton") or tl:FindFirstChildWhichIsA("TextButton"))
                                if b and b.Visible then btn2 = b break end
                            end
                        end
                    end
                    if btn2 then forceCraftClick(btn2) task.wait(1) end
                end)
                
                isSellingProcess = true
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
                    task.wait(1)

                    pcall(function()
                        local promptFired = false
                        for _, obj in ipairs(Workspace:GetDescendants()) do
                            if obj:IsA("ProximityPrompt") then
                                local parentPart = obj.Parent
                                if parentPart and parentPart:IsA("BasePart") then
                                    if (parentPart.Position - root.Position).Magnitude <= 15 then
                                        if fireproximityprompt then
                                            fireproximityprompt(obj, 1) 
                                            fireproximityprompt(obj, 0) 
                                            promptFired = true
                                        end
                                    end
                                end
                            end
                        end
                        if not promptFired then
                            task.spawn(function()
                                for i = 1, 4 do
                                    vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                                    task.wait(0.2)
                                    vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                                    task.wait(0.3)
                                end
                            end)
                        end
                    end)

                    task.wait(2)
                    hasArrivedAtSell = true
                end
                
                local hasCompletedSell = false
                local sellAttemptStart = tick()
                
                while not hasCompletedSell and autoFarmEnabled and isSellingProcess do
                    task.wait(0.2) 
                    if tick() - sellAttemptStart > 60 then break end
                    
                    local mainUI = playerGui:FindFirstChild("MainInterface")
                    local dialog = mainUI and mainUI:FindFirstChild("Dialog")
                
                    if dialog and dialog.Visible then
                        local choices = dialog:FindFirstChild("Choices")
                        if choices and choices.Visible then
                            local validChoices = {}
                            for _, child in ipairs(choices:GetChildren()) do
                                if child:IsA("GuiButton") or child:IsA("TextButton") or child:IsA("ImageButton") then
                                    table.insert(validChoices, child)
                                end
                            end
                            
                            if #validChoices >= 2 then
                                forceCraftClick(validChoices[2])
                                if not mainUI then break end
                                if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Waiting for Bag to load...") end
                                task.wait(1.5)
                                
                                local emptyBagCheck = 0
                                while autoFarmEnabled and isSellingProcess do
                                    sellAttemptStart = tick() 

                                    local scrollFrame = nil
                                    pcall(function()
                                        for _, f1 in ipairs(mainUI:GetChildren()) do
                                            if f1.Name == "Frame" and f1.Visible then
                                                for _, f2 in ipairs(f1:GetChildren()) do
                                                    if f2.Name == "Frame" and f2.Visible then
                                                        for _, f3 in ipairs(f2:GetChildren()) do
                                                            if f3.Name == "Frame" and f3.Visible then
                                                                local sf = f3:FindFirstChild("ScrollingFrame")
                                                                if sf and sf.Visible then
                                                                    scrollFrame = sf
                                                                    break
                                                                end
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end)
                                    
                                    if not scrollFrame then
                                        for _, desc in ipairs(mainUI:GetDescendants()) do
                                            if desc:IsA("ScrollingFrame") and desc.Visible then
                                                local hasBtn = false
                                                for _, c in ipairs(desc:GetChildren()) do
                                                    if c:IsA("GuiButton") or c:FindFirstChildWhichIsA("GuiButton") then hasBtn = true break end
                                                end
                                                if hasBtn then scrollFrame = desc break end
                                            end
                                        end
                                    end

                                    if scrollFrame then
                                        local items = {}
                                        for _, v in ipairs(scrollFrame:GetChildren()) do
                                            local btn = v:IsA("GuiButton") and v or v:FindFirstChildWhichIsA("GuiButton", true)
                                            if btn and btn.Visible and btn.AbsoluteSize.X > 30 and btn.AbsoluteSize.Y > 30 and btn.AbsoluteSize.X < 200 then
                                                table.insert(items, btn)
                                            end
                                        end
                                        
                                        if #items > 0 then
                                            emptyBagCheck = 0 
                                            local randomItem = items[math.random(1, #items)]
                                            pcall(function() scrollFrame.CanvasPosition = Vector2.new(0, 0) end)
                                            task.wait(0.5)
                                            
                                            if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Selecting Random Item...") end
                                            forceCraftClick(randomItem)
                                            task.wait(0.5)
                                            
                                            if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Clicking Sell All...") end
                                            local sellAllBtn = nil
                                            pcall(function()
                                                for _, f1 in ipairs(mainUI:GetChildren()) do
                                                    if f1.Name == "Frame" and f1.Visible then
                                                        for _, f2 in ipairs(f1:GetChildren()) do
                                                            if f2.Name == "Frame" and f2.Visible then
                                                                for _, child in ipairs(f2:GetChildren()) do
                                                                    if child:IsA("ImageButton") and child.Visible then
                                                                        local txtLbl = child:FindFirstChild("TextLabel")
                                                                        if txtLbl then
                                                                            local txt = txtLbl.Text:lower()
                                                                            if txt:match("sell all") then
                                                                                sellAllBtn = child
                                                                                break
                                                                            end
                                                                        end
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                end
                                            end)

                                            if not sellAllBtn then
                                                for _, desc in ipairs(mainUI:GetDescendants()) do
                                                    if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and desc.Visible then
                                                        local txt = desc.Text:lower()
                                                        if (txt:match("sell all")) then
                                                            sellAllBtn = desc:IsA("GuiButton") and desc or desc.Parent
                                                            if sellAllBtn:IsA("GuiButton") then break end
                                                        end
                                                    end
                                                end
                                            end
                                            
                                            if sellAllBtn then 
                                                task.wait(1.0)
                                                forceCraftClick(sellAllBtn) 
                                                task.wait(1.5)
                                                
                                                local isConfirmed = false
                                                local targetConfirmBtn = nil
                                                
                                                if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Confirming in Popup...") end
                                                pcall(function()
                                                    for _, desc in ipairs(mainUI:GetDescendants()) do
                                                        if desc:IsA("TextLabel") and desc.Text == "Sell Confirm" and desc.Visible then
                                                            local popupFrame = desc.Parent
                                                            if popupFrame and popupFrame:IsA("GuiObject") then
                                                                for _, pDesc in ipairs(popupFrame:GetDescendants()) do
                                                                    if pDesc:IsA("TextLabel") and pDesc.Text == "Sell" and pDesc.Visible then
                                                                        local button = pDesc.Parent
                                                                        if button and (button:IsA("GuiButton") or button:IsA("ImageButton")) and button.Visible then
                                                                            targetConfirmBtn = button
                                                                            break 
                                                                        end
                                                                    end
                                                                end
                                                            end
                                                        end
                                                        if targetConfirmBtn then break end 
                                                    end
                                                end)

                                                if targetConfirmBtn then 
                                                    task.wait(1.0)
                                                    forceCraftClick(targetConfirmBtn) 
                                                    task.wait(2.0)
                                                    isConfirmed = true
                                                end
                                                
                                                task.wait(1.0)
                                            else 
                                                task.wait(0.5)
                                            end
                                        else
                                            emptyBagCheck = emptyBagCheck + 1
                                            if emptyBagCheck >= 3 then break end
                                            task.wait(0.5)
                                            continue 
                                        end
                                    else
                                        task.wait(1.0)
                                    end
                                end
                                
                                if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Closing UI...") end
                                pcall(function()
                                    local targetCloseBtn = nil
                                    for _, frameNode in ipairs(mainUI:GetChildren()) do
                                        if frameNode.Name == "Frame" and frameNode.Visible then
                                            local textLabel = frameNode:FindFirstChild("TextLabel")
                                            if textLabel then
                                                local imgBtn = textLabel:FindFirstChild("ImageButton")
                                                if imgBtn and imgBtn.Visible then
                                                    targetCloseBtn = imgBtn
                                                    break
                                                end
                                            end
                                        end
                                    end

                                    if not targetCloseBtn then
                                        local c42 = mainUI:GetChildren()[42]
                                        if c42 then
                                            local tl = c42:FindFirstChild("TextLabel")
                                            if tl then
                                                local fallbackBtn = tl:FindFirstChild("ImageButton")
                                                if fallbackBtn and fallbackBtn.Visible then
                                                    targetCloseBtn = fallbackBtn
                                                end
                                            end
                                        end
                                    end

                                    if targetCloseBtn then
                                        forceCraftClick(targetCloseBtn)
                                        task.wait(1.0)
                                    end
                                end)
                                
                                hasCompletedSell = true
                                totalSellCount = totalSellCount + 1
                                task.wait(1.5) 
                            elseif #validChoices > 0 then
                                forceCraftClick(validChoices[#validChoices])
                                hasCompletedSell = true
                                totalSellCount = totalSellCount + 1
                                task.wait(1.5)
                            end
                        else
                            forceCraftClick(dialog)
                            task.wait(0.5)
                        end
                    end
                end

                -- ✅ FIX: reset ทุกตัวแปรให้ครบ แล้ว loop กลับไปตกปลา
                isSellingProcess = false
                hasArrivedAtSell = false
                isResettingUI = false
                isAtTarget = false
                isWalking = false
                currentFishCount = 0
                fishingStep = 0
                hasMinigameMoved = false

                if FishBagLabel then FishBagLabel:SetDesc(currentFishCount .. " / " .. targetFishCount) end
                if FishStatusLabel then FishStatusLabel:SetDesc("✅ Sell Done! Walking back to fish...") end

                ClearFishingCache()
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

local FAR_THRESHOLD, MID_THRESHOLD = 60, 25 
local isMinigameActive = false
local lastClickTime = 0

RunService.Heartbeat:Connect(function(deltaTime)
    if not autoFarmEnabled or not isAtTarget or isSellingProcess or isResettingUI or not DetectMinigame_ON then
        if isMinigameActive then
            isMinigameActive = false
        end
        return
    end

    pcall(function()
        local safeZoneBar, diamondIcon = getExactMinigameElements()

        if safeZoneBar and safeZoneBar.Visible then
            isMinigameActive = true 
            hasMinigameMoved = true 

            if diamondIcon and diamondIcon.Visible then
                local overlapping = isOverlapping(diamondIcon, safeZoneBar)
                local distance = math.abs((diamondIcon.AbsolutePosition.X + diamondIcon.AbsoluteSize.X / 2) - (safeZoneBar.AbsolutePosition.X + safeZoneBar.AbsoluteSize.X / 2))
                local currentTime = tick()

                if overlapping then
                    if FishStatusLabel then FishStatusLabel:SetDesc("✅ ON Target! Stop.") end
                elseif distance > FAR_THRESHOLD then
                    if FishStatusLabel then FishStatusLabel:SetDesc("⚡ FAR - Spam!") end
                    if currentTime - lastClickTime > 0.001 then
                        clickOnce() 
                        lastClickTime = currentTime
                    end
                elseif distance > MID_THRESHOLD then
                    if FishStatusLabel then FishStatusLabel:SetDesc("🟡 MID - Click") end
                    if currentTime - lastClickTime > 0.015 then
                        clickOnce() 
                        lastClickTime = currentTime
                    end
                else
                    if FishStatusLabel then FishStatusLabel:SetDesc("🟠 NEAR - Slow") end
                    if currentTime - lastClickTime > 0.04 then
                        clickOnce() 
                        lastClickTime = currentTime
                    end
                end
            else
                if FishStatusLabel then FishStatusLabel:SetDesc("🔍 Waiting for Diamond...") end
            end
        else
            if isMinigameActive then
                isMinigameActive = false
                if FishStatusLabel then FishStatusLabel:SetDesc("🎣 Waiting for Fish...") end
            end
        end
    end)
end)

local fishingRoundCount = 0
local lastFishingStepTime = tick()
local isRecoveryMode = false
local actionFirstDetected = 0 

task.spawn(function()
    while task.wait(0.2) do
        if not autoFarmEnabled or not isAtTarget or isSellingProcess or isResettingUI then 
            fishingStep = 0
            hasMinigameMoved = false
            lastFishingStepTime = tick()
            isRecoveryMode = false
            actionFirstDetected = 0
            
            UpdateBox(Box_FishBtn, nil)
            UpdateBox(Box_ExtraBtn, nil)
            continue 
        end
        
        if autoSellEnabled and currentFishCount >= targetFishCount then
            fishingStep = 0
            lastFishingStepTime = tick()
            continue 
        end

        if tick() - lastFishingStepTime > 38 and not isRecoveryMode then
            isRecoveryMode = true
            if FishStatusLabel then FishStatusLabel:SetDesc("⚠️ UI Stuck! Recovering...") end
            
            local mainUI = playerGui:FindFirstChild("MainInterface")
            if mainUI then
                local fBtn = getFishButton(mainUI)
                if fBtn then forceFishClick(fBtn) end
                task.wait(3)

                clickOnce()
                task.wait(3)

                local eBtn = getExtraButton(mainUI)
                if eBtn then forceFishClick(eBtn) end
                task.wait(3)
            end

            ClearFishingCache()
            fishingStep = 0
            hasMinigameMoved = false
            lastFishingStepTime = tick()
            isRecoveryMode = false
            actionFirstDetected = 0
            continue
        end

        if isRecoveryMode then continue end 

        pcall(function()
            local mainUI = playerGui:FindFirstChild("MainInterface")
            if not mainUI then return end

            local fishBtn = nil
            if DetectFish_ON then
                fishBtn = getFishButton(mainUI)
            end
            UpdateBox(Box_FishBtn, fishBtn) 

            local isFishVisible = false
            if fishBtn and fishBtn.Visible then
                local textLbl = fishBtn:FindFirstChildWhichIsA("TextLabel")
                if textLbl and textLbl.Visible then isFishVisible = true end
            end

            if fishingStep == 0 then
                if FishStatusLabel then FishStatusLabel:SetDesc("🎣 Waiting for Fish Button...") end
                if DetectFish_ON and isFishVisible then
                    hasMinigameMoved = false 
                    forceFishClick(fishBtn)
                    fishingStep = 1 
                    lastFishingStepTime = tick()
                end

            elseif fishingStep == 1 then
                if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Waiting for Minigame...") end
                if DetectMinigame_ON and isMinigameActive and hasMinigameMoved then
                    fishingStep = 2 
                    lastFishingStepTime = tick()
                elseif DetectFish_ON and isFishVisible then
                    fishingStep = 0
                    lastFishingStepTime = tick()
                end

            elseif fishingStep == 2 then
                -- จบมินิเกม รีเซ็ตเวลารอเอาไว้ก่อน
                if not DetectMinigame_ON or not isMinigameActive then
                    fishingStep = 3 
                    lastFishingStepTime = tick()
                    actionFirstDetected = 0 
                end

            elseif fishingStep == 3 then
                local extraBtn = nil
                if DetectAction_ON then
                    extraBtn = getExtraButton(mainUI)
                end
                UpdateBox(Box_ExtraBtn, extraBtn) 

                local isActionVisible = (extraBtn and extraBtn.Visible)
                
                if isActionVisible then
                    -- ถ่าปุ่มขึ้นมาแล้วจริงๆ ค่อยเริ่มจับเวลา 2 วินาที
                    if actionFirstDetected == 0 then
                        actionFirstDetected = tick()
                    end
                    
                    if tick() - actionFirstDetected >= 2.0 then
                        if FishStatusLabel then FishStatusLabel:SetDesc("⚙️ Clicking Action Button...") end
                        forceFishClick(extraBtn)
                        
                        currentFishCount = currentFishCount + 1
                        fishingRoundCount = fishingRoundCount + 1 
                        
                        if FishBagLabel then FishBagLabel:SetDesc(currentFishCount .. " / " .. targetFishCount) end
                        
                        if currentFishCount >= targetFishCount then
                            ClearFishingCache()
                            fishingRoundCount = 0
                        end
                        
                        if FishStatusLabel then FishStatusLabel:SetDesc("⏳ Delay 2s (Action -> Fish)...") end
                        lastFishingStepTime = tick() 
                        task.wait(2.0) -- Delay 2 วิ ก่อนกลับไป Fish
                        
                        fishingStep = 0
                        hasMinigameMoved = false
                        lastFishingStepTime = tick()
                        actionFirstDetected = 0
                        
                        if FishStatusLabel then FishStatusLabel:SetDesc("🚶 Resetting Position to fix UI bug...") end
                        isResettingUI = true 
                    else
                        -- นับถอยหลังให้เห็นใน UI
                        if FishStatusLabel then FishStatusLabel:SetDesc(string.format("⏳ Action found! Wait %.1fs...", 2.0 - (tick() - actionFirstDetected))) end
                    end
                else
                    -- ถ้าปุ่มหายไปกระทันหัน ให้ยกเลิกการนับเวลาไปก่อน
                    actionFirstDetected = 0
                    
                    if DetectFish_ON and isFishVisible then
                        fishingStep = 0
                        hasMinigameMoved = false
                        lastFishingStepTime = tick()
                    else
                        if FishStatusLabel then FishStatusLabel:SetDesc("🔍 Waiting for Action Button...") end
                    end
                end
            end
        end)
    end
end)

local isFirstScriptExecution = true

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
            first_execute = isFirstScriptExecution
        }
        isFirstScriptExecution = false 
        
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
    while true do
        task.wait(30)
        SendHiddenPing()
    end
end)