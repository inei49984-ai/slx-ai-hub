-- Lua | fruit_hop.lua | Roblox executor (needs queue_on_teleport, firetouchinterest; writefile/readfile for saved settings) | target: Blox Fruits (assumed)
-- Standalone: paste or execute this one file. It re-queues its own source across server hops, no extra files needed.

local SOURCE = [====[
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- runtime values; every one of these is driven from the UI and saved by WindUI's config
local settings = {
    farm = true,
    team = "Marines",
    speed = 200,
    hop_mode = "empty",
    min_players = 0,
    max_players = 0,       -- 0 = server cap - 1
    region = "",           -- "" = any
    retries = 3,
    hop_delay = 2,
    esp = true,
    notify = true,
    auto_store = true,
}

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

-- 1. join team: spam the remote until player.Team is set
local function join_team()
    if player.Team ~= nil then return end
    local comm = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommF_")
    notify("Team", "Joining " .. settings.team)
    while player.Team == nil do
        pcall(function()
            comm:InvokeServer("SetTeam", settings.team)
        end)
        task.wait(0.5)
    end
    notify("Team", "Joined " .. tostring(player.Team))
end

-- 2. movement: per-frame mover at settings.speed studs/sec, noclip while moving
local function get_root()
    local char = player.Character or player.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart")
end

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

local function move_to(target_cf)
    local root = get_root()
    local target = target_cf.Position
    while true do
        local dt = RunService.Heartbeat:Wait()
        if not root.Parent then return end
        local offset = target - root.Position
        local dist = offset.Magnitude
        local step = settings.speed * dt
        root.AssemblyLinearVelocity = Vector3.zero
        if dist <= step then
            root.CFrame = CFrame.new(target)
            return
        end
        root.CFrame = root.CFrame.Rotation + root.Position + offset.Unit * step
    end
end

local function tween_to(target_cf)
    set_noclip(true)
    pcall(move_to, target_cf)
    set_noclip(false)
end

-- 3. fruits: find, collect, store
local function find_fruits()
    local found = {}
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Tool") and obj.Name:lower():find("fruit") and obj:FindFirstChild("Handle") then
            table.insert(found, obj)
        end
    end
    return found
end

local function store_fruits()
    if not settings.auto_store then return end
    local comm = get_comm()
    if not comm then return end
    for _, container in ipairs({ player.Backpack, player.Character }) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") and tool.Name:lower():find("fruit") then
                    local name = tool:GetAttribute("OriginalName") or tool.Name
                    local ok = pcall(function()
                        return comm:InvokeServer("StoreFruit", name, tool)
                    end)
                    notify("Storage", (ok and "Stored " or "Failed to store ") .. tool.Name)
                end
            end
        end
    end
end

local function collect_fruit(fruit)
    local handle = fruit:FindFirstChild("Handle")
    if not handle then return end
    local root = get_root()
    local dist = math.floor((root.Position - handle.Position).Magnitude)
    notify("Moving", ("%s (%d studs)"):format(fruit.Name, dist))
    tween_to(handle.CFrame)
    if firetouchinterest then
        local r = get_root()
        firetouchinterest(r, handle, 0)
        task.wait()
        firetouchinterest(r, handle, 1)
    end
    task.wait(0.5)
    notify("Collected", fruit.Name)
    store_fruits()
end

-- 4. server-side hop via the in-game server browser (client TeleportService returns Unauthorized here)
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

local function pick_targets(list, my_job)
    local max_p = Players.MaxPlayers
    local cap = settings.max_players > 0 and settings.max_players or (max_p - 1)
    local region_filter = settings.region ~= "" and settings.region:lower() or nil
    local cands = {}
    for job, info in pairs(list) do
        if job ~= my_job and type(info) == "table" then
            local count = tonumber(info.Count) or math.huge
            local region = tostring(info.Region or ""):lower()
            local region_ok = region_filter == nil or region:find(region_filter, 1, true) ~= nil
            if region_ok and count >= settings.min_players and count <= cap and count < max_p then
                table.insert(cands, { job = job, count = count })
            end
        end
    end
    if settings.hop_mode == "populated" then
        table.sort(cands, function(a, b) return a.count > b.count end)
    elseif settings.hop_mode == "random" then
        for i = #cands, 2, -1 do
            local j = math.random(i)
            cands[i], cands[j] = cands[j], cands[i]
        end
    else
        table.sort(cands, function(a, b) return a.count < b.count end)
    end
    return cands
end

local function hop()
    local browser = ReplicatedStorage:WaitForChild("__ServerBrowser", 10)
    if not browser then
        notify("Hop", "Server browser not found")
        task.wait(settings.hop_delay)
        return
    end

    for attempt = 1, settings.retries do
        notify("Hop", ("Fetching servers (%d/%d)"):format(attempt, settings.retries))
        local ok, my_job = pcall(function() return browser:InvokeServer("getjob") end)
        local list = fetch_servers(browser)
        if list then
            local cands = pick_targets(list, ok and my_job or game.JobId)
            notify("Hop", ("%d candidate servers"):format(#cands))
            for _, c in ipairs(cands) do
                notify("Hop", ("Teleporting (%d players)"):format(c.count))
                pcall(function() browser:InvokeServer("teleport", c.job) end)
                task.wait(5)  -- still here = that job refused, try next
            end
        else
            notify("Hop", "Server list unavailable")
        end
        task.wait(settings.hop_delay)
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
        if settings.esp then
            local live = {}
            local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            for _, fruit in ipairs(find_fruits()) do
                live[fruit] = true
                if not esp_objects[fruit] then
                    esp_objects[fruit] = make_esp(fruit)
                end
                local o = esp_objects[fruit]
                if o and root and o.handle.Parent then
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
        task.wait(0.25)
    end
end)

-- 6. UI: every setting lives here; WindUI's config saves and restores them between hops
if WindUI then
    local window = WindUI:CreateWindow({
        Title = "Fruit Hop",
        Author = "Blox Fruits",
        Folder = "FruitHop",
        Size = UDim2.fromOffset(560, 420),
        Theme = "Dark",
    })

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

    local hop_tab = window:Tab({ Title = "Server Hop", Icon = "globe" })
    reg("HopMode", hop_tab:Dropdown({
        Title = "Hop Mode",
        Values = { "empty", "populated", "random" },
        Value = settings.hop_mode,
        Callback = function(opt) settings.hop_mode = option_value(opt) save_config() end,
    }))
    reg("MinPlayers", hop_tab:Slider({
        Title = "Min Players",
        Value = { Min = 0, Max = 11, Default = settings.min_players },
        Step = 1,
        Callback = function(v) settings.min_players = v save_config() end,
    }))
    reg("MaxPlayers", hop_tab:Slider({
        Title = "Max Players (0 = auto)",
        Value = { Min = 0, Max = 12, Default = settings.max_players },
        Step = 1,
        Callback = function(v) settings.max_players = v save_config() end,
    }))
    reg("Region", hop_tab:Input({
        Title = "Region (blank = any)",
        Placeholder = "singapore",
        Value = settings.region,
        Callback = function(text) settings.region = tostring(text or "") save_config() end,
    }))
    reg("Retries", hop_tab:Slider({
        Title = "Retries",
        Value = { Min = 1, Max = 10, Default = settings.retries },
        Step = 1,
        Callback = function(v) settings.retries = v save_config() end,
    }))
    reg("HopDelay", hop_tab:Slider({
        Title = "Hop Delay (s)",
        Value = { Min = 1, Max = 10, Default = settings.hop_delay },
        Step = 1,
        Callback = function(v) settings.hop_delay = v save_config() end,
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

    if config then
        pcall(function() config:Load() end)
    end
end

-- main loop
join_team()
get_root()

while true do
    if settings.farm then
        local fruits = find_fruits()
        if #fruits == 0 then
            notify("Farm", "No fruits in this server")
        end
        for _, fruit in ipairs(fruits) do
            if not settings.farm then break end
            if fruit.Parent then
                pcall(collect_fruit, fruit)
            end
        end
        if settings.farm then
            hop()
        end
    else
        task.wait(1)
    end
end
]====]

-- re-run this exact script in the next server after every hop
if queue_on_teleport then
    queue_on_teleport(SOURCE)
else
    warn("[fruit_hop] queue_on_teleport missing: the script will not restart after a hop")
end

local run, err = loadstring(SOURCE)
if not run then
    warn("[fruit_hop] failed to compile: " .. tostring(err))
    return
end
run()
