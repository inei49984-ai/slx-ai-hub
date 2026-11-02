-- Lua | fruit_hop.lua | Roblox executor (needs firetouchinterest; writefile/readfile for saved settings) | target: Blox Fruits (assumed)
-- Standalone single file. Put it in your executor's autoexec folder and it starts by itself in every server.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- autoexec can run before the client is ready: wait for the game and for LocalPlayer
if not game:IsLoaded() then game.Loaded:Wait() end
local player = Players.LocalPlayer
while not player do
    task.wait(0.1)
    player = Players.LocalPlayer
end

-- never run twice in the same server (autoexec + manual execute)
local env = (getgenv and getgenv()) or _G
if env.FruitHopServer == game.JobId then return end
env.FruitHopServer = game.JobId

-- runtime values; every one of these is driven from the UI and saved by WindUI's config
local settings = {
    farm = true,
    team = "Marines",
    speed = 200,
    esp = true,
    notify = true,
    auto_store = true,
    hotkey = "RightControl",
}

local HOLD_SECONDS = 1     -- time spent touching each fruit
local MAX_ATTEMPTS = 5     -- failed tries in a row (with no pickup anywhere) before a fruit is skipped
local HOP_RETRIES = 3
local HOP_DELAY = 2

-- UI library (if it fails to load the farm still runs on the defaults above)
local lib_ok, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not lib_ok or not WindUI then
    WindUI = nil
    warn("[fruit_hop] WindUI failed to load, running without UI")
end

local function notify(title, text)
    if not settings.notify or not WindUI then return end
    pcall(function()
        WindUI:Notify({ Title = title, Content = tostring(text), Duration = 3 })
    end)
end

local function get_comm()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    return remotes and remotes:FindFirstChild("CommF_")
end

local function get_root_now()
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function get_root()
    local char = player.Character or player.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart", 15)
end

-- 1. join team: spam the remote until player.Team is set (a manual join also ends the loop)
local function join_team()
    if player.Team ~= nil then return end
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
    local comm = remotes and remotes:WaitForChild("CommF_", 15)
    if not comm then return end
    notify("Team", "Joining " .. settings.team)
    while player.Team == nil do
        pcall(function()
            comm:InvokeServer("SetTeam", settings.team)
        end)
        task.wait(0.5)
    end
    notify("Team", "Joined " .. tostring(player.Team))
end

-- 2. noclip while moving
local noclip_conn = nil
local noclip_saved = {}

local function set_noclip(state)
    if state then
        if noclip_conn then return end
        noclip_conn = RunService.Stepped:Connect(function()
            local char = player.Character
            if not char then return end
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    if noclip_saved[part] == nil then noclip_saved[part] = part.CanCollide end
                    part.CanCollide = false
                end
            end
        end)
    else
        if noclip_conn then
            noclip_conn:Disconnect()
            noclip_conn = nil
        end
        for part, original in pairs(noclip_saved) do
            if part.Parent then part.CanCollide = original end
            noclip_saved[part] = nil
        end
    end
end

-- 3. fruits: find, move to, hold contact, store
local function find_fruits()
    local found = {}
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Tool") and obj.Name:lower():find("fruit") and obj:FindFirstChild("Handle") then
            table.insert(found, obj)
        end
    end
    return found
end

local function held_fruits()
    local list = {}
    for _, container in ipairs({ player:FindFirstChild("Backpack"), player.Character }) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") and tool.Name:lower():find("fruit") then
                    table.insert(list, tool)
                end
            end
        end
    end
    return list
end

-- returns true when nothing is left in the inventory (or auto store is off)
local storing = false
local function store_fruits()
    if not settings.auto_store then return true end
    local comm = get_comm()
    if not comm then return false end
    while storing do task.wait(0.1) end
    storing = true
    pcall(function()
        for _ = 1, 3 do
            local list = held_fruits()
            if #list == 0 then break end
            for _, tool in ipairs(list) do
                local name = tool:GetAttribute("OriginalName") or tool.Name
                pcall(function() return comm:InvokeServer("StoreFruit", name, tool) end)
                task.wait(0.25)
                if tool.Parent == nil then
                    notify("Storage", "Stored " .. name)
                end
            end
            task.wait(0.3)
        end
    end)
    storing = false
    return #held_fruits() == 0
end

-- keeps storing in the background so a fruit never sits in the inventory
task.spawn(function()
    while true do
        if settings.auto_store and #held_fruits() > 0 then
            pcall(store_fruits)
        end
        task.wait(2)
    end
end)

-- moves toward the fruit's current position every frame (so shifted fruits are tracked)
local function move_to(fruit, handle)
    local started = os.clock()
    while fruit.Parent == workspace and handle.Parent do
        if os.clock() - started > 60 then return false end
        local dt = RunService.Heartbeat:Wait()
        local root = get_root_now()
        if not root then return false end
        local offset = handle.Position - root.Position
        local dist = offset.Magnitude
        local step = settings.speed * dt
        root.AssemblyLinearVelocity = Vector3.zero
        if dist <= step then
            root.CFrame = handle.CFrame
            return true
        end
        root.CFrame = root.CFrame.Rotation + root.Position + offset.Unit * step
    end
    return false
end

-- stays on the fruit for `duration` seconds, touching it every frame
local function hold_contact(fruit, handle, duration)
    local started = os.clock()
    while os.clock() - started < duration do
        if fruit.Parent ~= workspace or not handle.Parent then return end
        RunService.Heartbeat:Wait()
        local root = get_root_now()
        if not root then return end
        root.CFrame = handle.CFrame
        root.AssemblyLinearVelocity = Vector3.zero
        if firetouchinterest then
            firetouchinterest(root, handle, 0)
            firetouchinterest(root, handle, 1)
        end
    end
end

local function collect_fruit(fruit)
    local handle = fruit:FindFirstChild("Handle")
    if not handle then return false end
    set_noclip(true)
    pcall(function()
        if move_to(fruit, handle) then
            hold_contact(fruit, handle, HOLD_SECONDS)
        end
    end)
    set_noclip(false)
    return fruit.Parent ~= workspace
end

-- re-scans the map after every pickup, always goes for the nearest remaining fruit
local function farm_server()
    local attempts = {}
    while settings.farm do
        local root = get_root_now()
        if not root then
            task.wait(0.5)
            root = get_root()
            if not root then return end
        end

        local nearest, nearest_dist = nil, math.huge
        for _, fruit in ipairs(find_fruits()) do
            if (attempts[fruit] or 0) < MAX_ATTEMPTS then
                local dist = (fruit.Handle.Position - root.Position).Magnitude
                if dist < nearest_dist then
                    nearest, nearest_dist = fruit, dist
                end
            end
        end

        if not nearest then
            notify("Farm", "No fruits left in this server")
            return
        end

        attempts[nearest] = (attempts[nearest] or 0) + 1
        notify("Moving", ("%s (%d studs)"):format(nearest.Name, math.floor(nearest_dist)))
        local got = collect_fruit(nearest)
        if got then
            notify("Collected", nearest.Name)
            -- any pickup is progress (piles drop one fruit at a time), so every fruit gets fresh tries
            attempts = {}
        end

        -- storing runs on its own and never gates the loop; the hop happens only when no fruit is left
        task.spawn(store_fruits)
    end
end

-- 4. random server hop through the in-game server browser (client TeleportService returns Unauthorized here)
local function fetch_servers(browser)
    local deadline = os.clock() + 30
    for i = 1, 100 do
        local ok, list = pcall(function() return browser:InvokeServer(i) end)
        if ok and type(list) == "table" then
            local n = 0
            for _ in pairs(list) do
                n += 1
                if n > 5 then return list end
            end
        end
        if os.clock() > deadline then break end
        task.wait(0.02)
    end
    return nil
end

local function hop()
    local browser = ReplicatedStorage:WaitForChild("__ServerBrowser", 10)
    if not browser then
        notify("Hop", "Server browser not found")
        task.wait(HOP_DELAY)
        return
    end

    for attempt = 1, HOP_RETRIES do
        notify("Hop", ("Fetching servers (%d/%d)"):format(attempt, HOP_RETRIES))
        local ok, my_job = pcall(function() return browser:InvokeServer("getjob") end)
        my_job = ok and my_job or game.JobId
        local list = fetch_servers(browser)
        if list then
            local cands = {}
            for job, info in pairs(list) do
                if job ~= my_job and type(info) == "table" then
                    local count = tonumber(info.Count) or math.huge
                    if count < Players.MaxPlayers then
                        table.insert(cands, { job = job, count = count })
                    end
                end
            end
            for i = #cands, 2, -1 do
                local j = math.random(i)
                cands[i], cands[j] = cands[j], cands[i]
            end
            notify("Hop", ("%d candidate servers"):format(#cands))
            for _, c in ipairs(cands) do
                notify("Hop", ("Teleporting (%d players)"):format(c.count))
                pcall(function() browser:InvokeServer("teleport", c.job) end)
                task.wait(5)  -- still here = that job refused, try the next one
            end
        else
            notify("Hop", "Server list unavailable")
        end
        task.wait(HOP_DELAY)
    end
end

-- 5. fruit ESP
local ui_parent = (gethui and gethui()) or game:GetService("CoreGui")
local esp_objects = {}

local function destroy_esp(o)
    if o.highlight then o.highlight:Destroy() end
    if o.billboard then o.billboard:Destroy() end
end

local function clear_esp()
    for fruit, o in pairs(esp_objects) do
        destroy_esp(o)
        esp_objects[fruit] = nil
    end
end

local function make_esp(fruit)
    local handle = fruit:FindFirstChild("Handle")
    if not handle then return nil end

    local highlight = Instance.new("Highlight")
    highlight.Adornee = fruit
    highlight.FillColor = Color3.fromRGB(255, 170, 0)
    highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
    highlight.FillTransparency = 0.5
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = ui_parent

    local billboard = Instance.new("BillboardGui")
    billboard.Adornee = handle
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.fromOffset(180, 22)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.Parent = ui_parent

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.fromRGB(255, 220, 120)
    label.TextStrokeTransparency = 0.4
    label.Font = Enum.Font.GothamBold
    label.TextSize = 14
    label.Parent = billboard

    return { highlight = highlight, billboard = billboard, label = label, fruit = fruit, handle = handle }
end

task.spawn(function()
    while true do
        pcall(function()
            if settings.esp then
                local live = {}
                local root = get_root_now()
                for _, fruit in ipairs(find_fruits()) do
                    live[fruit] = true
                    if not esp_objects[fruit] then
                        esp_objects[fruit] = make_esp(fruit)
                    end
                    local o = esp_objects[fruit]
                    if o and root and o.handle and o.handle.Parent then
                        local dist = math.floor((root.Position - o.handle.Position).Magnitude)
                        o.label.Text = ("%s [%dm]"):format(fruit.Name, dist)
                    end
                end
                for fruit, o in pairs(esp_objects) do
                    if not live[fruit] or not fruit.Parent then
                        destroy_esp(o)
                        esp_objects[fruit] = nil
                    end
                end
            end
        end)
        task.wait(0.25)
    end
end)

-- 6. UI: every setting lives here; WindUI's config saves and restores them between hops
if WindUI then
    local window = WindUI:CreateWindow({
        Title = "Fruit Hop",
        Author = "Blox Fruits",
        Folder = "FruitHop",
        Size = UDim2.fromOffset(560, 380),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
    })

    -- hotkey that reopens the window after it was minimized with "-"
    local hotkey_native = pcall(function()
        window:SetToggleKey(Enum.KeyCode.RightControl)
    end)
    local current_key = Enum.KeyCode.RightControl

    local function apply_hotkey(name)
        local ok, key = pcall(function() return Enum.KeyCode[name] end)
        if not ok or not key then return end
        current_key = key
        if hotkey_native then
            pcall(function() window:SetToggleKey(key) end)
        end
    end

    if not hotkey_native then
        UserInputService.InputBegan:Connect(function(input, processed)
            if processed or input.KeyCode ~= current_key then return end
            pcall(function() window:Toggle() end)
        end)
    end

    local config = nil
    pcall(function()
        config = window.ConfigManager:CreateConfig("settings")
    end)

    local save_pending = false
    local function save_config()
        if not config or save_pending then return end
        save_pending = true
        task.delay(1, function()
            save_pending = false
            pcall(function() config:Save() end)
        end)
    end

    local function reg(flag, element)
        if config and element then
            pcall(function() config:Register(flag, element) end)
        end
        return element
    end

    local function option_value(opt)
        return type(opt) == "table" and opt[1] or opt
    end

    local main_tab = window:Tab({ Title = "Main", Icon = "home" })
    reg("AutoFarm", main_tab:Toggle({
        Title = "Auto Farm",
        Value = settings.farm,
        Callback = function(v) settings.farm = v save_config() end,
    }))
    reg("Team", main_tab:Dropdown({
        Title = "Team",
        Values = { "Marines", "Pirates" },
        Value = settings.team,
        Callback = function(opt) settings.team = option_value(opt) save_config() end,
    }))
    reg("TweenSpeed", main_tab:Slider({
        Title = "Tween Speed (studs/s)",
        Value = { Min = 50, Max = 500, Default = settings.speed },
        Step = 10,
        Callback = function(v) settings.speed = v save_config() end,
    }))
    reg("AutoStore", main_tab:Toggle({
        Title = "Auto Store Fruits",
        Value = settings.auto_store,
        Callback = function(v) settings.auto_store = v save_config() end,
    }))

    local visual_tab = window:Tab({ Title = "Visuals", Icon = "eye" })
    reg("FruitESP", visual_tab:Toggle({
        Title = "Fruit ESP",
        Value = settings.esp,
        Callback = function(v)
            settings.esp = v
            if not v then clear_esp() end
            save_config()
        end,
    }))
    reg("Notifications", visual_tab:Toggle({
        Title = "Notifications",
        Value = settings.notify,
        Callback = function(v) settings.notify = v save_config() end,
    }))

    local ui_tab = window:Tab({ Title = "UI", Icon = "settings" })
    reg("UIHotkey", ui_tab:Dropdown({
        Title = "UI Hotkey (default RightControl)",
        Values = {
            "RightControl", "LeftControl", "RightShift", "RightAlt", "Insert", "Delete",
            "Home", "End", "PageUp", "PageDown", "F1", "F2", "F3", "F4",
        },
        Value = settings.hotkey,
        Callback = function(opt)
            settings.hotkey = option_value(opt)
            apply_hotkey(settings.hotkey)
            save_config()
        end,
    }))

    if config then
        pcall(function() config:Load() end)
    end
    apply_hotkey(settings.hotkey)
end

-- main loop: every step is protected so one error never stops the farm
pcall(join_team)
get_root()

while true do
    if settings.farm then
        if player.Team == nil then pcall(join_team) end
        local ok, err = pcall(farm_server)
        if not ok then warn("[fruit_hop] farm error: " .. tostring(err)) end
        if settings.farm then
            local hop_ok, hop_err = pcall(hop)
            if not hop_ok then warn("[fruit_hop] hop error: " .. tostring(hop_err)) end
        end
    else
        task.wait(1)
    end
end
