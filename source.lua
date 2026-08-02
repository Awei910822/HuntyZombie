local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

-- =========================================================
-- 防重複執行與銷毀機制
-- =========================================================
local SCRIPT_NAME = "WeiHub_AutoFarm"

if getgenv()[SCRIPT_NAME] and getgenv()[SCRIPT_NAME].Destroy then
    getgenv()[SCRIPT_NAME]:Destroy()
end

local ScriptController = {}
getgenv()[SCRIPT_NAME] = ScriptController

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local character = player.Character or player.CharacterAdded:Wait()
local playerRoot = character:WaitForChild("HumanoidRootPart")
local zombiesFolder = Workspace:WaitForChild("Entities"):WaitForChild("Zombie")

-- =========================================================
-- 參數設定與狀態變數
-- =========================================================
local isAutoReplayEnabled = true
local replayConnection = nil

local isAutoFarmEnabled = true
local NO_ZOMBIE_Y = 4         
local RELATIVE_Y_OFFSET = -5  
local AUTO_ATTACK_DELAY = 0.1 
local RESPAWN_DELAY = 8       
local CLICK_INTERVAL = 0.25   

-- 整合進自動打怪的定時傳送重生點參數
local TELEPORT_INTERVAL = 5     
local lastTeleportTime = 0

local targetZombie = nil
local zombieRoot = nil
local isRespawning = false
local lastClickTime = 0

local heartbeatConnection = nil
local inputConnection = nil
local characterAddedConnection = nil
local autoAttackThread = nil
local screenGui = nil

-- 更強效的重生點搜尋
local function getSpawnPart()
    for _, obj in pairs(Workspace:GetDescendants()) do
        if obj.Name == "Spawn" and obj:IsA("BasePart") then
            local parentName = obj.Parent and obj.Parent.Name or ""
            if parentName == "Entity Spawns" or obj:IsDescendantOf(Workspace) then
                return obj
            end
        end
    end
    return nil
end

-- 銷毀函式
function ScriptController:Destroy()
    isAutoFarmEnabled = false
    isAutoReplayEnabled = false
    
    if replayConnection then replayConnection:Disconnect() end
    if heartbeatConnection then heartbeatConnection:Disconnect() end
    if inputConnection then inputConnection:Disconnect() end
    if characterAddedConnection then characterAddedConnection:Disconnect() end
    if autoAttackThread then task.cancel(autoAttackThread) end
    if screenGui and screenGui.Parent then screenGui:Destroy() end

    getgenv()[SCRIPT_NAME] = nil
    print("【系統】舊的 [" .. SCRIPT_NAME .. "] 腳本已被成功銷毀！")
end

-- =========================================================
-- 建立 UI 介面
-- =========================================================
screenGui = Instance.new("ScreenGui")
screenGui.Name = SCRIPT_NAME .. "Gui"
screenGui.ResetOnSpawn = false
screenGui.Parent = CoreGui

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 300, 0, 165)
mainFrame.Position = UDim2.new(0.5, -150, 0.4, -82)
mainFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 32)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -20, 0, 35)
titleLabel.Position = UDim2.new(0, 15, 0, 5)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Wei Hub"
titleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
titleLabel.TextSize = 14
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = mainFrame

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -30, 0, 1)
divider.Position = UDim2.new(0, 15, 0, 40)
divider.BackgroundColor3 = Color3.fromRGB(45, 48, 55)
divider.BorderSizePixel = 0
divider.Parent = mainFrame

local function createToggleUI(name, text, yOffset, defaultState)
    local toggleFrame = Instance.new("Frame")
    toggleFrame.Size = UDim2.new(1, -30, 0, 45)
    toggleFrame.Position = UDim2.new(0, 15, 0, yOffset)
    toggleFrame.BackgroundTransparency = 1
    toggleFrame.Parent = mainFrame

    local checkBox = Instance.new("TextButton")
    checkBox.Size = UDim2.new(0, 26, 0, 26)
    checkBox.Position = UDim2.new(0, 0, 0.5, -13)
    checkBox.BorderSizePixel = 1
    checkBox.BorderColor3 = Color3.fromRGB(80, 85, 95)
    checkBox.TextSize = 18
    checkBox.Font = Enum.Font.GothamBold
    checkBox.Parent = toggleFrame

    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 6)
    boxCorner.Parent = checkBox

    local toggleText = Instance.new("TextLabel")
    toggleText.Size = UDim2.new(1, -35, 1, 0)
    toggleText.Position = UDim2.new(0, 35, 0, 0)
    toggleText.BackgroundTransparency = 1
    toggleText.Text = text
    toggleText.TextColor3 = Color3.fromRGB(220, 220, 220)
    toggleText.TextSize = 14
    toggleText.Font = Enum.Font.GothamMedium
    toggleText.TextXAlignment = Enum.TextXAlignment.Left
    toggleText.Parent = toggleFrame

    local function updateVisual(state)
        if state then
            checkBox.Text = "✓"
            checkBox.BackgroundColor3 = Color3.fromRGB(46, 139, 87)
        else
            checkBox.Text = ""
            checkBox.BackgroundColor3 = Color3.fromRGB(40, 44, 52)
        end
    end
    updateVisual(defaultState)

    return checkBox, updateVisual
end

local replayBtn, updateReplayUI = createToggleUI("ReplayToggle", "自動 Replay", 50, isAutoReplayEnabled)
local farmBtn, updateFarmUI = createToggleUI("FarmToggle", "自動打怪 (Key: H)", 100, isAutoFarmEnabled)

-- =========================================================
-- 功能 1：自動 Replay（優化升級版：主動全域搜尋 Replay 按鈕）
-- =========================================================
local function triggerGameReplay()
    for _, desc in pairs(playerGui:GetDescendants()) do
        if desc:IsA("GuiButton") and (desc.Name == "Replay" or desc.Name:lower():find("replay")) then
            if desc.Visible and desc.AbsoluteSize.X > 0 then
                if firesignal then
                    firesignal(desc.MouseButton1Click)
                else
                    local pos = desc.AbsolutePosition
                    local size = desc.AbsoluteSize
                    VirtualInputManager:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, true, game, 0)
                    task.wait(0.05)
                    VirtualInputManager:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, false, game, 0)
                end
                print("【Wei Hub】已自動點擊 Replay 按鈕！")
                return true
            end
        end
    end
    return false
end

-- 使用迴圈定時檢查結算畫面是否出現，避免因為 UI 結構改變而失效
task.spawn(function()
    while true do
        if isAutoReplayEnabled then
            triggerGameReplay()
        end
        task.wait(1) -- 每秒檢查一次
    end
end)

replayBtn.MouseButton1Click:Connect(function()
    isAutoReplayEnabled = not isAutoReplayEnabled
    updateReplayUI(isAutoReplayEnabled)
end)

-- =========================================================
-- 功能 2：自動打怪
-- =========================================================
local function pressKey(keyCode)
    VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
    task.wait(0.02)
    VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
end

local function clickMouse()
    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
    task.wait(0.02)
    VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
end

local function isZombieAlive(zombie, root)
    if not zombie or not zombie.Parent or not root or not root.Parent then return false end
    local head = zombie:FindFirstChild("Head")
    return not (head and head.CanCollide == true)
end

local function findNearestZombie()
    if not playerRoot or not playerRoot.Parent then return nil, nil end
    local closestZombie, closestRoot = nil, nil
    local shortestDistance = math.huge

    for _, zombie in pairs(zombiesFolder:GetChildren()) do
        if zombie:IsA("Model") then
            local root = zombie:FindFirstChild("HumanoidRootPart")
            if root and isZombieAlive(zombie, root) then
                local distance = (playerRoot.Position - root.Position).Magnitude
                if distance < shortestDistance then
                    shortestDistance = distance
                    closestZombie = zombie
                    closestRoot = root
                end
            end
        end
    end
    return closestZombie, closestRoot
end

autoAttackThread = task.spawn(function()
    while true do
        if isAutoFarmEnabled and not isRespawning and playerRoot and playerRoot.Parent then
            pressKey(Enum.KeyCode.Z)
            pressKey(Enum.KeyCode.X)
            pressKey(Enum.KeyCode.C)
            pressKey(Enum.KeyCode.E)
            
            if tick() - lastClickTime >= CLICK_INTERVAL then
                clickMouse()
                lastClickTime = tick()
            end
        end
        task.wait(AUTO_ATTACK_DELAY)
    end
end)

heartbeatConnection = RunService.Heartbeat:Connect(function()
    if not isAutoFarmEnabled or isRespawning then return end 
    if not playerRoot or not playerRoot.Parent then return end 

    local currentTime = tick()

    if currentTime - lastTeleportTime >= TELEPORT_INTERVAL then
        local spawnPart = getSpawnPart()
        if spawnPart then
            local pos = spawnPart.Position
            playerRoot.CFrame = CFrame.new(pos.X, pos.Y + 4, pos.Z)
            lastTeleportTime = currentTime
            return 
        end
    end

    if not isZombieAlive(targetZombie, zombieRoot) then
        targetZombie, zombieRoot = findNearestZombie()
    end

    if zombieRoot then
        local pos = zombieRoot.Position
        playerRoot.CFrame = CFrame.new(pos.X, pos.Y + RELATIVE_Y_OFFSET, pos.Z)
    else
        playerRoot.CFrame = CFrame.new(playerRoot.Position.X, NO_ZOMBIE_Y, playerRoot.Position.Z)
    end
end)

characterAddedConnection = player.CharacterAdded:Connect(function(newCharacter)
    isRespawning = true
    task.wait(RESPAWN_DELAY)
    character = newCharacter
    playerRoot = newCharacter:WaitForChild("HumanoidRootPart")
    isRespawning = false
end)

local function toggleAutoFarm()
    isAutoFarmEnabled = not isAutoFarmEnabled
    updateFarmUI(isAutoFarmEnabled)
    
    if not isAutoFarmEnabled and playerRoot and playerRoot.Parent then
        local currentPos = playerRoot.Position
        playerRoot.CFrame = CFrame.new(currentPos.X, 4, currentPos.Z)
    end
end

farmBtn.MouseButton1Click:Connect(toggleAutoFarm)

-- =========================================================
-- 互動邏輯（含防黏住機制）
-- =========================================================
local dragging, dragInput, dragStart, startPos

mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.K then
        mainFrame.Visible = not mainFrame.Visible
    elseif input.KeyCode == Enum.KeyCode.H then
        toggleAutoFarm()
    end
end)

print("【Wei Hub】載入成功！")
