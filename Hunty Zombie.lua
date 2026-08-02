local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

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
local zombiesFolder = workspace:WaitForChild("Entities"):WaitForChild("Zombie")

-- =========================================================
-- 參數設定與狀態變數
-- =========================================================
-- [ 自動 Replay 變數 ]
local isAutoReplayEnabled = true
local endScreenConnection = nil

-- [ 自動打怪變數 ]
local isAutoFarmEnabled = true
local LOCK_Y = -5             -- 沒殭屍時的高度
local RELATIVE_Y_OFFSET = -5  -- 有殭屍時的相對高度差
local AUTO_ATTACK_DELAY = 0.1 -- 技能檢查循環間隔（秒）
local RESPAWN_DELAY = 8       -- 重生後等待 8 秒
local CLICK_INTERVAL = 0.25   -- 普攻點擊間隔（秒）

local targetZombie = nil
local zombieRoot = nil
local isRespawning = false
local lastClickTime = 0

local heartbeatConnection = nil
local inputConnection = nil
local characterAddedConnection = nil
local autoAttackThread = nil
local screenGui = nil

-- 銷毀函式：當重新執行或手動關閉時觸發
function ScriptController:Destroy()
    isAutoFarmEnabled = false
    isAutoReplayEnabled = false
    
    if endScreenConnection then endScreenConnection:Disconnect() end
    if heartbeatConnection then heartbeatConnection:Disconnect() end
    if inputConnection then inputConnection:Disconnect() end
    if characterAddedConnection then characterAddedConnection:Disconnect() end
    if autoAttackThread then task.cancel(autoAttackThread) end
    if screenGui and screenGui.Parent then screenGui:Destroy() end

    getgenv()[SCRIPT_NAME] = nil
    print("【系統】舊的 [" .. SCRIPT_NAME .. "] 腳本已被成功銷毀！")
end

-- =========================================================
-- 建立 UI 介面 (Wei Hub)
-- =========================================================
screenGui = Instance.new("ScreenGui")
screenGui.Name = SCRIPT_NAME .. "Gui"
screenGui.ResetOnSpawn = false
screenGui.Parent = CoreGui

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 300, 0, 160)
mainFrame.Position = UDim2.new(0.5, -150, 0.4, -80)
mainFrame.BackgroundColor3 = Color3.fromRGB(25, 27, 32)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "TitleLabel"
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
    toggleFrame.Name = name
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

local replayBtn, updateReplayUI = createToggleUI("ReplayToggle", "自動 Replay (自動開局)", 50, isAutoReplayEnabled)
local farmBtn, updateFarmUI = createToggleUI("FarmToggle", "自動打怪 (熱鍵: H)", 100, isAutoFarmEnabled)

-- =========================================================
-- 功能 1：自動 Replay 邏輯
-- =========================================================
local function triggerGameReplay()
    local mainScreen = playerGui:FindFirstChild("MainScreen_Sibling")
    local endScreen = mainScreen and mainScreen:FindFirstChild("EndScreen")
    local list = endScreen and endScreen:FindFirstChild("List")
    local buttons = list and list:FindFirstChild("buttons")
    
    local replayBtnObj = nil
    if buttons then
        local foundChild = buttons:FindFirstChild("Replay")
        if foundChild then
            replayBtnObj = foundChild
        else
            for _, child in pairs(buttons:GetChildren()) do
                if child.Name:lower() == "replay" then
                    replayBtnObj = child
                    break
                end
            end
        end
    end

    if replayBtnObj then
        if firesignal then
            firesignal(replayBtnObj.MouseButton1Click)
            firesignal(replayBtnObj.Activated)
        else
            local pos = replayBtnObj.AbsolutePosition
            local size = replayBtnObj.AbsoluteSize
            VirtualInputManager:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2 + 36, 0, true, game, 0)
            task.wait(0.05)
            VirtualInputManager:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2 + 36, 0, false, game, 0)
        end
    end
end

local function checkEndScreen()
    local mainScreen = playerGui:FindFirstChild("MainScreen_Sibling")
    local endScreen = mainScreen and mainScreen:FindFirstChild("EndScreen")
    
    if endScreen and isAutoReplayEnabled and endScreen.Visible then
        task.wait(0.5)
        triggerGameReplay()
    end
end

local function setupReplayListener()
    local mainScreen = playerGui:WaitForChild("MainScreen_Sibling", 10)
    local endScreen = mainScreen and mainScreen:WaitForChild("EndScreen", 10)

    if endScreen then
        if endScreenConnection then endScreenConnection:Disconnect() end
        endScreenConnection = endScreen:GetPropertyChangedSignal("Visible"):Connect(checkEndScreen)
        checkEndScreen()
    end
end

replayBtn.MouseButton1Click:Connect(function()
    isAutoReplayEnabled = not isAutoReplayEnabled
    updateReplayUI(isAutoReplayEnabled)
    if isAutoReplayEnabled then setupReplayListener() end
end)

if isAutoReplayEnabled then setupReplayListener() end

-- =========================================================
-- 功能 2：自動打怪邏輯
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
    if not zombie or not zombie.Parent then return false end
    if not root or not root.Parent then return false end
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

    if not isZombieAlive(targetZombie, zombieRoot) then
        targetZombie, zombieRoot = findNearestZombie()
    end

    if zombieRoot then
        local pos = zombieRoot.Position
        playerRoot.CFrame = CFrame.new(pos.X, pos.Y + RELATIVE_Y_OFFSET, pos.Z)
    else
        playerRoot.CFrame = CFrame.new(playerRoot.Position.X, LOCK_Y, playerRoot.Position.Z)
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
        playerRoot.CFrame = CFrame.new(playerRoot.Position.X, 3, playerRoot.Position.Z)
    end
end

farmBtn.MouseButton1Click:Connect(toggleAutoFarm)

-- =========================================================
-- 互動邏輯：拖曳與熱鍵
-- =========================================================
local dragging, dragInput, dragStart, startPos

mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)

mainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement then dragInput = input end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
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

print("【Wei Hub】載入成功！防重複執行機制已生效。")
