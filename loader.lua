--// Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

--// Locals
local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

--// Configuration
local CONFIG = {
    UpdateRate = 0.1, -- обновление ролей 10 раз в секунду вместо 60
    MaxDistance = 500, -- отключение ESP на дистанции > 500 studs
    FadeDistance = 300, -- начало затухания
    RoleCacheTime = 2, -- кэш роли на 2 секунды
    GunScanInterval = 5, -- периодическая перепроверка пистолетов
    Colors = {
        Murderer = Color3.fromRGB(255, 50, 50),
        Sheriff = Color3.fromRGB(50, 150, 255),
        Innocent = Color3.fromRGB(50, 255, 50),
        Gun = Color3.fromRGB(255, 215, 0)
    }
}

--// State management
local State = {
    PlayerData = {}, -- [Player] = {Highlight, Connection, Role, LastUpdate}
    GunData = {}, -- [Instance] = {Billboard, Highlight, Connection}
    Active = true
}

--// Utility: Safe WaitForChild with timeout
local function safeWaitForChild(parent, name, timeout)
    timeout = timeout or 5
    local child = parent:FindFirstChild(name)
    if child then return child end
    
    local startTime = tick()
    while tick() - startTime < timeout do
        child = parent:FindFirstChild(name)
        if child then return child end
        task.wait(0.05)
    end
    return nil
end

--// Utility: Clean disconnect
local function safeDisconnect(conn)
    if conn and typeof(conn) == "RBXScriptConnection" then
        pcall(function() conn:Disconnect() end)
    end
end

--// Utility: Clean destroy
local function safeDestroy(obj)
    if obj and typeof(obj) == "Instance" then
        pcall(function() obj:Destroy() end)
    end
end

--// Role detection with caching
local function detectRole(player)
    local char = player.Character
    if not char then return "Innocent" end
    
    -- Check character
    if char:FindFirstChild("Knife") or char:FindFirstChild("KnifeSkin") then
        return "Murderer"
    end
    if char:FindFirstChild("Gun") or char:FindFirstChild("Revolver") or char:FindFirstChild("GunDrop") then
        return "Sheriff"
    end
    
    -- Check backpack
    local backpack = player:FindFirstChild("Backpack")
    if backpack then
        if backpack:FindFirstChild("Knife") or backpack:FindFirstChild("KnifeSkin") then
            return "Murderer"
        end
        if backpack:FindFirstChild("Gun") or backpack:FindFirstChild("Revolver") or backpack:FindFirstChild("GunDrop") then
            return "Sheriff"
        end
    end
    
    return "Innocent"
end

--// Cached role getter
local function getRole(player)
    local data = State.PlayerData[player]
    if not data then return "Innocent" end
    
    local now = tick()
    if not data.LastRoleCheck or (now - data.LastRoleCheck) > CONFIG.RoleCacheTime then
        data.Role = detectRole(player)
        data.LastRoleCheck = now
    end
    
    return data.Role
end

--// Color getter
local function getRoleColor(role)
    return CONFIG.Colors[role] or CONFIG.Colors.Innocent
end

--// Distance-based transparency calculator
local function calculateTransparency(origin, targetPos)
    local distance = (origin - targetPos).Magnitude
    if distance > CONFIG.MaxDistance then return 1 end
    if distance < CONFIG.FadeDistance then return 0 end
    
    local fadeRange = CONFIG.MaxDistance - CONFIG.FadeDistance
    local currentFade = distance - CONFIG.FadeDistance
    return currentFade / fadeRange
end

--// Cleanup player data
local function cleanupPlayer(player)
    local data = State.PlayerData[player]
    if not data then return end
    
    safeDisconnect(data.RenderConnection)
    safeDisconnect(data.DiedConnection)
    safeDisconnect(charRemovingConnection)
    safeDestroy(data.Highlight)
    
    State.PlayerData[player] = nil
end

--// Create player ESP
local function createPlayerESP(player)
    if player == LocalPlayer then return end
    if State.PlayerData[player] then cleanupPlayer(player) end
    
    local function setupCharacter(char)
        if not char then return end
        
        -- Wait for Humanoid with timeout
        local humanoid = safeWaitForChild(char, "Humanoid", 3)
        if not humanoid then return end
        
        -- Create Highlight
        local highlight = Instance.new("Highlight")
        highlight.Name = "BB_ESP_" .. player.Name
        highlight.FillTransparency = 1
        highlight.OutlineTransparency = 0.5
        highlight.OutlineColor = CONFIG.Colors.Innocent
        highlight.Adornee = char
        highlight.Parent = char
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        
        -- Initialize player data
        local data = {
            Highlight = highlight,
            Role = "Innocent",
            LastRoleCheck = 0,
            LastUpdate = tick(),
            RenderConnection = nil,
            DiedConnection = nil,
            CharRemovingConnection = nil
        }
        State.PlayerData[player] = data
        
        -- Throttled update loop (10Hz instead of 60Hz)
        local lastUpdate = tick()
        data.RenderConnection = RunService.Heartbeat:Connect(function()
            if not State.Active then return end
            if tick() - lastUpdate < CONFIG.UpdateRate then return end
            lastUpdate = tick()
            
            if not char or not char.Parent or not humanoid or not humanoid.Parent then
                cleanupPlayer(player)
                return
            end
            
            local role = getRole(player)
            local color = getRoleColor(role)
            
            -- Distance-based fade
            local charPos = char:GetPivot().Position
            local cameraPos = Camera.CFrame.Position
            local transparency = calculateTransparency(cameraPos, charPos)
            
            local outlineTransparency = (role == "Murderer") and 0.2 or 0.5
            outlineTransparency = math.clamp(outlineTransparency + transparency, 0, 1)
            
            pcall(function()
                highlight.OutlineColor = color
                highlight.OutlineTransparency = outlineTransparency
                highlight.Enabled = transparency < 1
            end)
        end)
        
        -- Death handler
        data.DiedConnection = humanoid.Died:Connect(function()
            task.delay(1, function()
                scanGuns() -- Check for dropped gun
            end)
            cleanupPlayer(player)
        end)
        
        -- Character removing handler
        data.CharRemovingConnection = player.CharacterRemoving:Connect(function()
            cleanupPlayer(player)
        end)
    end
    
    if player.Character then
        setupCharacter(player.Character)
    end
    
    player.CharacterAdded:Connect(setupCharacter)
end

--// Gun ESP with ownership tracking
local function createGunESP(item)
    if not item or not item.Parent then return end
    if State.GunData[item] then return end -- Already tracked
    
    -- Validate it's actually a dropped gun (not equipped or in display)
    local parent = item.Parent
    while parent do
        if parent:IsA("Model") and Players:GetPlayerFromCharacter(parent) then
            return -- Equipped by player
        end
        if parent:IsA("Backpack") then
            return -- In someone's backpack
        end
        if parent.Name == "WeaponDisplays" then
            return -- Shop display
        end
        parent = parent.Parent
    end
    
    -- Create container in CoreGui for stability
    local container = Instance.new("ScreenGui")
    container.Name = "BB_GunESP_" .. item:GetFullName():gsub("[^%w]", "_")
    container.ResetOnSpawn = false
    container.Parent = CoreGui
    
    -- BillboardGui
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "GE"
    billboard.Size = UDim2.new(0, 200, 0, 40)
    billboard.StudsOffset = Vector3.new(0, 2, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = item
    billboard.Parent = container
    
    -- Text label with enhanced styling
    local label = Instance.new("TextLabel")
    label.Name = "GunLabel"
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 18
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.TextColor3 = CONFIG.Colors.Gun
    label.Text = "🔫 GUN"
    label.Parent = billboard
    
    -- Distance indicator
    local distLabel = Instance.new("TextLabel")
    distLabel.Name = "DistanceLabel"
    distLabel.Size = UDim2.new(1, 0, 0.5, 0)
    distLabel.Position = UDim2.new(0, 0, 0.5, 0)
    distLabel.BackgroundTransparency = 1
    distLabel.Font = Enum.Font.Gotham
    distLabel.TextSize = 14
    distLabel.TextStrokeTransparency = 0
    distLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    distLabel.TextColor3 = Color3.new(1, 1, 1)
    distLabel.Text = ""
    distLabel.Parent = billboard
    
    -- Highlight
    local highlight = Instance.new("Highlight")
    highlight.Name = "BB_GunHighlight"
    highlight.FillTransparency = 0.8
    highlight.FillColor = CONFIG.Colors.Gun
    highlight.OutlineTransparency = 0.2
    highlight.OutlineColor = CONFIG.Colors.Gun
    highlight.Adornee = item
    highlight.Parent = item
    
    -- Store data
    local data = {
        Container = container,
        Billboard = billboard,
        Highlight = highlight,
        DistanceLabel = distLabel,
        Connection = nil
    }
    State.GunData[item] = data
    
    -- Update distance and cleanup check
    local lastUpdate = tick()
    data.Connection = RunService.Heartbeat:Connect(function()
        if tick() - lastUpdate < 0.2 then return end
        lastUpdate = tick()
        
        if not item or not item.Parent then
            cleanupGun(item)
            return
        end
        
        -- Update distance
        local itemPos = item:GetPivot().Position
        local cameraPos = Camera.CFrame.Position
        local distance = math.floor((cameraPos - itemPos).Magnitude)
        
        pcall(function()
            distLabel.Text = string.format("[%dst]", distance)
            -- Fade based on distance
            local transparency = calculateTransparency(cameraPos, itemPos)
            billboard.Enabled = transparency < 1
        end)
    end)
    
    -- Ancestry change handler
    item.AncestryChanged:Connect(function(_, newParent)
        if not newParent then
            cleanupGun(item)
        end
    end)
end

--// Cleanup gun ESP
local function cleanupGun(item)
    local data = State.GunData[item]
    if not data then return end
    
    safeDisconnect(data.Connection)
    safeDestroy(data.Container)
    safeDestroy(data.Highlight)
    
    State.GunData[item] = nil
end

--// Scan workspace for guns
local function scanGuns()
    if not State.Active then return end
    
    -- Clear orphaned entries
    for item, data in pairs(State.GunData) do
        if not item or not item.Parent then
            cleanupGun(item)
        end
    end
    
    -- Scan workspace
    local function scanContainer(container)
        for _, descendant in ipairs(container:GetDescendants()) do
            if descendant.Name == "GunDrop" and not State.GunData[descendant] then
                task.spawn(function()
                    task.wait(0.1) -- Small delay to ensure item settled
                    createGunESP(descendant)
                end)
            end
        end
    end
    
    scanContainer(Workspace)
end

--// Initialize player tracking
local function initPlayerTracking()
    -- Existing players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            createPlayerESP(player)
        end
    end
    
    -- New players
    Players.PlayerAdded:Connect(function(player)
        if player ~= LocalPlayer then
            createPlayerESP(player)
        end
    end)
    
    -- Player leaving cleanup
    Players.PlayerRemoving:Connect(function(player)
        cleanupPlayer(player)
    end)
end

--// Initialize gun tracking
local function initGunTracking()
    scanGuns()
    
    -- New items
    Workspace.DescendantAdded:Connect(function(item)
        if item.Name == "GunDrop" then
            task.delay(0.3, function()
                createGunESP(item)
            end)
        end
    end)
    
    -- Periodic rescan for safety
    task.spawn(function()
        while State.Active do
            task.wait(CONFIG.GunScanInterval)
            scanGuns()
        end
    end)
end

--// Performance monitor
local function initPerformanceMonitor()
    task.spawn(function()
        while State.Active do
            task.wait(30)
            local playerCount = 0
            local gunCount = 0
            
            for _ in pairs(State.PlayerData) do playerCount += 1 end
            for _ in pairs(State.GunData) do gunCount += 1 end
            
            print(string.format("[Blackbox ESP] Active | Players: %d | Guns: %d", playerCount, gunCount))
        end
    end)
end

--// Cleanup all
local function cleanupAll()
    State.Active = false
    
    for player, _ in pairs(State.PlayerData) do
        cleanupPlayer(player)
    end
    
    for item, _ in pairs(State.GunData) do
        cleanupGun(item)
    end
    
    print("[Blackbox ESP] Shutdown complete")
end

--// Main initialization
local function initialize()
    if not LocalPlayer then
        warn("[Blackbox ESP] LocalPlayer not found")
        return
    end
    
    initPlayerTracking()
    initGunTracking()
    initPerformanceMonitor()
    
    print("[Blackbox ESP] Loaded | Update rate: " .. CONFIG.UpdateRate .. "s | Max distance: " .. CONFIG.MaxDistance)
end

--// Auto-execute
initialize()

--// Expose API for external control
getgenv().BlackboxESP = {
    State = State,
    Config = CONFIG,
    Cleanup = cleanupAll,
    Rescan = scanGuns,
    GetRole = function(player)
        return getRole(player)
    end
}

