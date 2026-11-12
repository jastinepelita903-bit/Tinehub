--[[
    ============================================================================
    TINE HUB — BLOX FRUITS AUTO LEVEL (FIRST SEA 1–699 / STOP AT 700)
    File        : TINE_HUB_FIRST_SEA_FIXED.lua
    Edition     : Full Combat & Quest Repair Release (Deep Root-Cause Audited)
    Target Place: 2753915549 (Blox Fruits — First Sea)
    ============================================================================

    ROOT-CAUSE FIXES INTEGRATED IN THIS RELEASE:
    1. Fixed Undefined `Config.SlowAttackInterval` Crash & `IsAttacking` Lock:
       - `FireAttackOnce()` previously referenced `Config.SlowAttackInterval` (nil) instead of
         `Config.NormalAttackInterval` outside `pcall` after setting `IsAttacking = true`.
       - Toggling Fast Attack OFF caused an uncaught arithmetic error on `now + interval`,
         permanently locking `IsAttacking = true` and crashing the unguarded combat worker thread.
    2. Fixed Quest Progress Parser & False-Positive Validation (`ParseQuestProgress` & `EvaluateQuestStatus`):
       - `ParseQuestProgress` no longer masks missing numbers by silently returning `defaultReq` as if
         it were parsed from the UI. It now returns `(cur, req, hasExplicitReq, hasFraction)`.
       - `ReadQuestTitle` prioritizes `Quest.Container.QuestTitle.Title` and filters out localized
         non-title labels (`"hadiah"`, `"batalkan"`, `"reward"`, `"abandon"`, `"cancel"`).
    3. Restored Full Multi-Layer Combat Execution & Viewport-Centered Input:
       - Combines `Tool:Activate()`, `VirtualInputManager:SendMouseButtonEvent` at dynamic
         `CurrentCamera.ViewportSize / 2` (fixing off-screen `1280, 672` clicks on mobile),
         `VirtualUser` at viewport center, and safe `ReplicatedStorage.Modules.Net` hit registration.
    4. Fixed Melee Tool Detection & Equip Verification (`EquipWeapon`):
       - Supports both `ToolTip == "Melee"` and fallback First Sea fighting style names in case
         `ToolTip` is localized or empty, and verifies `tool.Parent == char` after `EquipTool`.
    5. Fixed Hover Offset & Hitbox Alignment (`PositionAboveMob`):
       - Uses `HoverHeight = 3.5` and `HoverBackOffset = 2.0` with non-collinear `CFrame.lookAt`
         so the character faces the NPC within 4 studs without triggering `NaN` rotation matrices
         or `HumanoidStateType.FallingDown`.
    6. Self-Healing Combat Worker & Comprehensive Diagnostics (`DiagState`):
       - Wraps the combat worker in `xpcall(..., debug.traceback)`, monitors worker heartbeat in `Step()`,
         auto-restarts the worker if stalled, and exposes real-time combat/quest diagnostics in the GUI.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- ================= ROBLOX SERVICES =================

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local VU = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local VIM = nil
pcall(function()
    VIM = game:GetService("VirtualInputManager")
end)

local LP = Players.LocalPlayer

-- ================= CENTRALIZED CONFIGURATION =================

local Config = {
    FirstSeaPlaceId = 2753915549,
    MinFirstSeaLevel = 1,
    MaxFirstSeaLevel = 700,

    Team = "Pirates",
    WeaponType = "Melee",
    AutoStatsTarget = "Melee", -- Strictly Melee Only
    MaxStatCap = 2550,

    TweenSpeed = 210,
    TweenSpeedPresets = {180, 210, 240},
    TweenSpeedIndex = 2,

    -- Optimal melee hitbox positioning (3.5 studs up, 2.0 studs offset -> ~4.0 studs total distance)
    HoverHeight = 3.5,
    HoverBackOffset = 2.0,
    AttackRange = 35.0,
    MaxMoveDuration = 45.0,

    BringMobRadius = 180.0,
    MaxBringMobs = 5,

    FastAttack = true,
    BringMob = true,
    AutoHaki = true,
    AutoStatsMelee = true,

    MainLoopInterval = 0.08,
    FastAttackInterval = 0.12,
    NormalAttackInterval = 0.28,
    HakiInterval = 8.0,
    StatInterval = 1.0,
    SpawnCacheTTL = 15.0,

    QuestSettleDelay = 0.25,
    QuestVerifyTimeout = 3.0,
    QuestLateUIGrace = 1.2,
    QuestRetryDelay = 1.8,
    QuestMaxTries = 4,
    QuestCompleteDelay = 0.50,

    RemoteTimeout = 4.0,
    RespawnSettleDelay = 0.50,
    RespawnMaxWait = 12.0,
    WorkerWatchdogTimeout = 2.5,

    StuckCheckInterval = 1.5,
    StuckMinMoveDist = 2.0,
    MobBlacklistDuration = 4.0,
    WarnThrottleInterval = 4.0
}

-- Known First Sea Melee / Fighting Style names as fallback if ToolTip is localized or empty
local KnownMeleeToolNames = {
    ["combat"] = true,
    ["black leg"] = true,
    ["dark step"] = true,
    ["electro"] = true,
    ["electric"] = true,
    ["fishman karate"] = true,
    ["water kung fu"] = true,
    ["dragon breath"] = true,
    ["superhuman"] = true
}

-- ================= ENVIRONMENT & DIAGNOSTICS STATE =================

local env = (typeof(getgenv) == "function" and getgenv()) or _G

if env.BFAutoFarmStop then
    pcall(env.BFAutoFarmStop)
end

local HasSetHiddenProperty = (typeof(sethiddenproperty) == "function")
local GetUpvaluesFn = (typeof(getupvalues) == "function" and getupvalues)
    or (typeof(debug) == "table" and typeof(debug.getupvalues) == "function" and debug.getupvalues)
    or nil
local HasGetUpvalues = (GetUpvaluesFn ~= nil)

local WarnTimestamps = {}

local DiagState = {
    QuestState = "IDLE",
    QuestTitle = "None",
    ActiveStage = "None",
    ExpectedMob = "None",
    TotalEnemies = 0,
    MatchingEnemies = 0,
    SelectedTarget = "None",
    TargetHealth = "0/0",
    TargetDistance = -1,
    CharStatus = "Loading",
    WeaponStatus = "None",
    WorkerStatus = "Starting",
    LastAttackSkipReason = "None",
    LastError = "None",
    AttackCount = 0
}

local function RecordError(location, err)
    local now = os.clock()
    local shortErr = string.gsub(tostring(err), "\n.*", "")
    local msg = string.format("[%s] %s", tostring(location), shortErr)
    DiagState.LastError = msg

    local last = WarnTimestamps[location]
    if not last or (now - last) >= Config.WarnThrottleInterval then
        WarnTimestamps[location] = now
        warn("[TineHub][ERROR]" .. msg)
    end
end

-- ================= LIFECYCLE & STATE VARIABLES =================

local Alive = true
local Running = true
local IsStopped = false
local IsRespawning = false
local RespawnStartedAt = 0
local RespawnToken = 0
local LifecycleEpoch = 1

local function BumpEpoch()
    LifecycleEpoch += 1
    return LifecycleEpoch
end

local function CanContinue(expectedEpoch)
    if not Alive or not Running or IsRespawning then
        return false
    end
    if expectedEpoch and expectedEpoch ~= LifecycleEpoch then
        return false
    end
    return true
end

-- Quest FSM States:
-- "IDLE" | "TAKING_QUEST" | "VERIFYING_QUEST" | "UNKNOWN_QUEST" | "FARMING" | "VERIFYING_COMPLETION"
local QuestState = "IDLE"
local LockedStage = nil
local LastRequestedStage = nil
local QuestCurrentCount = 0
local QuestRequiredCount = 0
local QuestVerifyDeadline = 0
local QuestUnknownDetectedAt = 0
local QuestNextAttempt = 0
local QuestAttemptCount = 0
local QuestCompletionStartedAt = 0

-- Character & Combat State
local CharRef = nil
local HumRef = nil
local RootRef = nil
local CachedWeapon = nil
local CombatTarget = nil
local IsAttacking = false
local CombatWorkerId = 0
local CombatWorkerHeartbeatAt = os.clock()

local NextAttackAt = 0
local NextHakiAt = 0
local NextStatAt = 0
local NextSimRadiusAt = 0

-- Movement State
local ActiveTween = nil
local MoveToken = 0
local StabilizerBV = nil
local SpawnPatrolIndex = 1
local LastSpawnPatrolAt = 0

-- Weak Tables & Caches
local MobBlacklist = setmetatable({}, { __mode = "k" })
local OriginalCollideState = setmetatable({}, { __mode = "k" })
local OriginalMobState = setmetatable({}, { __mode = "k" })
local CachedCharParts = {}
local SpawnNodesCache = {}

-- Cached Quest GUI References
local CachedQuestFrame = nil
local CachedQuestTitle = nil

-- Connection Registries
local GlobalConnections = {}
local CharConnections = {}

local function RegisterGlobalConn(conn)
    if conn then
        table.insert(GlobalConnections, conn)
    end
    return conn
end

local function ClearCharConnections()
    for i = #CharConnections, 1, -1 do
        local conn = CharConnections[i]
        CharConnections[i] = nil
        pcall(function()
            conn:Disconnect()
        end)
    end
end

-- ================= NAMED-FIELD STAGE DATABASE (1–699) =================

local FISHMAN_ENTRANCE_FROM = CFrame.new(3865, 7, -1926)
local FISHMAN_ENTRANCE_TO   = Vector3.new(61164, 12, 1820)
local FISHMAN_EXIT_TO       = Vector3.new(3865, 7, -1926)

local SKY_ENTRANCE_FROM     = CFrame.new(-4608, 873, -1668)
local SKY_ENTRANCE_TO       = Vector3.new(-7895, 5547, -380)

local Stages = {
    {
        MinLevel = 1, MaxLevel = 9,
        MobName = "Bandit", QuestName = "BanditQuest1", QuestIndex = 1,
        QuestNPC = CFrame.new(1059, 16, 1550),
        FallbackSpawn = CFrame.new(1046, 27, 1561),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 5
    },
    {
        MinLevel = 10, MaxLevel = 14,
        MobName = "Monkey", QuestName = "JungleQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(-1598, 36, 153),
        FallbackSpawn = CFrame.new(-1448, 68, 11),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 6
    },
    {
        MinLevel = 15, MaxLevel = 29,
        MobName = "Gorilla", QuestName = "JungleQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(-1598, 36, 153),
        FallbackSpawn = CFrame.new(-1130, 40, -525),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 30, MaxLevel = 39,
        MobName = "Pirate", QuestName = "BuggyQuest1", QuestIndex = 1,
        QuestNPC = CFrame.new(-1140, 5, 3827),
        FallbackSpawn = CFrame.new(-1104, 14, 3896),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 40, MaxLevel = 59,
        MobName = "Brute", QuestName = "BuggyQuest1", QuestIndex = 2,
        QuestNPC = CFrame.new(-1140, 5, 3827),
        FallbackSpawn = CFrame.new(-1140, 15, 4323),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 60, MaxLevel = 74,
        MobName = "Desert Bandit", QuestName = "DesertQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(897, 6, 4390),
        FallbackSpawn = CFrame.new(985, 16, 4418),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 75, MaxLevel = 89,
        MobName = "Desert Officer", QuestName = "DesertQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(897, 6, 4390),
        FallbackSpawn = CFrame.new(1547, 14, 4382),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 6
    },
    {
        MinLevel = 90, MaxLevel = 99,
        MobName = "Snow Bandit", QuestName = "SnowQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(1387, 87, -1298),
        FallbackSpawn = CFrame.new(1356, 106, -1328),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 7
    },
    {
        MinLevel = 100, MaxLevel = 119,
        MobName = "Snowman", QuestName = "SnowQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(1387, 87, -1298),
        FallbackSpawn = CFrame.new(1219, 138, -1488),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 120, MaxLevel = 149,
        MobName = "Chief Petty Officer", QuestName = "MarineQuest2", QuestIndex = 1,
        QuestNPC = CFrame.new(-5035, 29, 4324),
        FallbackSpawn = CFrame.new(-4931, 66, 4122),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 150, MaxLevel = 174,
        MobName = "Sky Bandit", QuestName = "SkyQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(-4842, 718, -2623),
        FallbackSpawn = CFrame.new(-4956, 365, -2908),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 7
    },
    {
        MinLevel = 175, MaxLevel = 189,
        MobName = "Dark Master", QuestName = "SkyQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(-4842, 718, -2623),
        FallbackSpawn = CFrame.new(-5148, 439, -2333),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 190, MaxLevel = 209,
        MobName = "Prisoner", QuestName = "PrisonerQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(5310, 0, 475),
        FallbackSpawn = CFrame.new(5099, 0, 474),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 210, MaxLevel = 249,
        MobName = "Dangerous Prisoner", QuestName = "PrisonerQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(5310, 0, 475),
        FallbackSpawn = CFrame.new(5655, 16, 866),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 250, MaxLevel = 274,
        MobName = "Toga Warrior", QuestName = "ColosseumQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(-1580, 6, -2986),
        FallbackSpawn = CFrame.new(-1820, 52, -2741),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 7
    },
    {
        MinLevel = 275, MaxLevel = 299,
        MobName = "Gladiator", QuestName = "ColosseumQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(-1580, 6, -2986),
        FallbackSpawn = CFrame.new(-1293, 56, -3339),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 300, MaxLevel = 324,
        MobName = "Military Soldier", QuestName = "MagmaQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(-5313, 11, 8515),
        FallbackSpawn = CFrame.new(-5411, 11, 8454),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 7
    },
    {
        MinLevel = 325, MaxLevel = 374,
        MobName = "Military Spy", QuestName = "MagmaQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(-5313, 11, 8515),
        FallbackSpawn = CFrame.new(-5803, 86, 8829),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 375, MaxLevel = 399,
        MobName = "Fishman Warrior", QuestName = "FishmanQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(61123, 19, 1568),
        FallbackSpawn = CFrame.new(60844, 98, 1298),
        EntranceFrom = FISHMAN_ENTRANCE_FROM, EntranceTo = FISHMAN_ENTRANCE_TO,
        ExpectedCount = 8
    },
    {
        MinLevel = 400, MaxLevel = 449,
        MobName = "Fishman Commando", QuestName = "FishmanQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(61123, 19, 1568),
        FallbackSpawn = CFrame.new(61738, 64, 1434),
        EntranceFrom = FISHMAN_ENTRANCE_FROM, EntranceTo = FISHMAN_ENTRANCE_TO,
        ExpectedCount = 7
    },
    {
        MinLevel = 450, MaxLevel = 474,
        MobName = "God's Guard", QuestName = "SkyExp1Quest", QuestIndex = 1,
        QuestNPC = CFrame.new(-4722, 845, -1950),
        FallbackSpawn = CFrame.new(-4628, 867, -1931),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 7
    },
    {
        MinLevel = 475, MaxLevel = 524,
        MobName = "Shanda", QuestName = "SkyExp1Quest", QuestIndex = 2,
        QuestNPC = CFrame.new(-7859, 5544, -381),
        FallbackSpawn = CFrame.new(-7678, 5566, -497),
        EntranceFrom = SKY_ENTRANCE_FROM, EntranceTo = SKY_ENTRANCE_TO,
        ExpectedCount = 9
    },
    {
        MinLevel = 525, MaxLevel = 549,
        MobName = "Royal Squad", QuestName = "SkyExp2Quest", QuestIndex = 1,
        QuestNPC = CFrame.new(-7907, 5635, -1412),
        FallbackSpawn = CFrame.new(-7624, 5658, -1467),
        EntranceFrom = SKY_ENTRANCE_FROM, EntranceTo = SKY_ENTRANCE_TO,
        ExpectedCount = 8
    },
    {
        MinLevel = 550, MaxLevel = 624,
        MobName = "Royal Soldier", QuestName = "SkyExp2Quest", QuestIndex = 2,
        QuestNPC = CFrame.new(-7907, 5635, -1412),
        FallbackSpawn = CFrame.new(-7837, 5638, -1795),
        EntranceFrom = SKY_ENTRANCE_FROM, EntranceTo = SKY_ENTRANCE_TO,
        ExpectedCount = 8
    },
    {
        MinLevel = 625, MaxLevel = 649,
        MobName = "Galley Pirate", QuestName = "FountainQuest", QuestIndex = 1,
        QuestNPC = CFrame.new(5258, 39, 4050),
        FallbackSpawn = CFrame.new(5557, 152, 3999),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 8
    },
    {
        MinLevel = 650, MaxLevel = 699,
        MobName = "Galley Captain", QuestName = "FountainQuest", QuestIndex = 2,
        QuestNPC = CFrame.new(5258, 39, 4050),
        FallbackSpawn = CFrame.new(5678, 93, 4967),
        EntranceFrom = nil, EntranceTo = nil,
        ExpectedCount = 9
    }
}

local StagesBySpecificity = {}
for i = 1, #Stages do
    StagesBySpecificity[i] = Stages[i]
end
table.sort(StagesBySpecificity, function(a, b)
    if #a.MobName ~= #b.MobName then
        return #a.MobName > #b.MobName
    end
    return a.MinLevel < b.MinLevel
end)

local function IsValidVector3(v)
    if typeof(v) ~= "Vector3" then return false end
    if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z then return false end
    if math.abs(v.X) > 1e6 or math.abs(v.Y) > 1e6 or math.abs(v.Z) > 1e6 then return false end
    return true
end

local function IsValidCFrame(cf)
    if typeof(cf) ~= "CFrame" then return false end
    local x, y, z, r00, _, _, _, r11, _, _, _, r22 = cf:GetComponents()
    if x ~= x or y ~= y or z ~= z then return false end
    if r00 ~= r00 or r11 ~= r11 or r22 ~= r22 then return false end
    if math.abs(x) > 1e6 or math.abs(y) > 1e6 or math.abs(z) > 1e6 then return false end
    return true
end

local function SafeUprightCF(pos)
    if not IsValidVector3(pos) then
        return nil
    end
    return CFrame.new(pos.X, pos.Y, pos.Z)
end

-- Builds a non-collinear combat CFrame hovering above & slightly behind the mob, facing the mob's center
local function BuildCombatHoverCF(mobPos)
    if not IsValidVector3(mobPos) then
        return nil
    end
    local hoverPos = Vector3.new(
        mobPos.X,
        mobPos.Y + Config.HoverHeight,
        mobPos.Z + Config.HoverBackOffset
    )
    -- Since HoverBackOffset ~= 0, (mobPos - hoverPos) has a non-zero Z component and is NEVER collinear with Y-axis
    local cf = CFrame.lookAt(hoverPos, mobPos, Vector3.yAxis)
    if IsValidCFrame(cf) then
        return cf, hoverPos
    end
    return SafeUprightCF(hoverPos), hoverPos
end

local function ValidateStageDatabase(stageList)
    if typeof(stageList) ~= "table" or #stageList == 0 then
        return false, "Stage list is empty"
    end
    if stageList[1].MinLevel ~= Config.MinFirstSeaLevel then
        return false, "First stage must start at level 1"
    end
    if stageList[#stageList].MaxLevel ~= (Config.MaxFirstSeaLevel - 1) then
        return false, "Final stage must end at level 699"
    end

    for i, st in ipairs(stageList) do
        if typeof(st.MinLevel) ~= "number" or typeof(st.MaxLevel) ~= "number" or st.MinLevel > st.MaxLevel then
            return false, string.format("Invalid level bounds at stage #%d", i)
        end
        if i > 1 and st.MinLevel ~= (stageList[i - 1].MaxLevel + 1) then
            return false, string.format("Level gap or overlap between stage #%d and #%d", i - 1, i)
        end
        if typeof(st.MobName) ~= "string" or st.MobName == "" then
            return false, string.format("Invalid MobName at stage #%d", i)
        end
        if typeof(st.QuestName) ~= "string" or st.QuestName == "" then
            return false, string.format("Invalid QuestName at stage #%d", i)
        end
        if typeof(st.QuestIndex) ~= "number" or st.QuestIndex < 1 then
            return false, string.format("Invalid QuestIndex at stage #%d", i)
        end
        if not IsValidCFrame(st.QuestNPC) or not IsValidCFrame(st.FallbackSpawn) then
            return false, string.format("Invalid CFrame coordinate at stage #%d (%s)", i, st.MobName)
        end
        if st.EntranceFrom ~= nil and not IsValidCFrame(st.EntranceFrom) then
            return false, string.format("Invalid EntranceFrom at stage #%d", i)
        end
        if st.EntranceTo ~= nil and not IsValidVector3(st.EntranceTo) then
            return false, string.format("Invalid EntranceTo at stage #%d", i)
        end
        if typeof(st.ExpectedCount) ~= "number" or st.ExpectedCount < 1 then
            return false, string.format("Invalid ExpectedCount at stage #%d", i)
        end
    end

    return true, "OK"
end

local function GetStageForLevel(level)
    for _, stage in ipairs(Stages) do
        if level >= stage.MinLevel and level <= stage.MaxLevel then
            return stage
        end
    end
    return nil
end

-- ================= REMOTE REQUEST MANAGER =================

local CommF = nil

local RemoteManager = {
    InFlight = {},
    LastInvokeAt = {},
    MinIntervals = {
        StartQuest = 1.0,
        AbandonQuest = 1.2,
        AddPoint = 0.8,
        Buso = 5.0,
        requestEntrance = 1.0,
        SetTeam = 2.0
    }
}

function RemoteManager:CanInvoke(actionKey)
    if not Alive or not CommF then
        return false, "RemoteUnavailable"
    end
    if self.InFlight[actionKey] then
        return false, "InFlight"
    end
    local minInt = self.MinIntervals[actionKey] or 0.5
    local lastAt = self.LastInvokeAt[actionKey] or 0
    if (os.clock() - lastAt) < minInt then
        return false, "RateLimited"
    end
    return true, "OK"
end

function RemoteManager:Invoke(actionKey, ...)
    local canRun, reason = self:CanInvoke(actionKey)
    if not canRun then
        return false, nil, reason
    end

    local args = { ... }
    local requestEpoch = LifecycleEpoch
    self.InFlight[actionKey] = true
    self.LastInvokeAt[actionKey] = os.clock()

    local completed = false
    local invokeOk = false
    local invokeResult = nil

    task.spawn(function()
        invokeOk, invokeResult = xpcall(function()
            return CommF:InvokeServer(table.unpack(args))
        end, debug.traceback)
        completed = true
    end)

    local deadline = os.clock() + Config.RemoteTimeout
    while not completed and os.clock() < deadline do
        if not Alive or requestEpoch ~= LifecycleEpoch then
            self.InFlight[actionKey] = false
            return false, nil, "CancelledByEpoch"
        end
        task.wait(0.05)
    end

    self.InFlight[actionKey] = false

    if not completed then
        RecordError("RemoteTimeout:" .. tostring(actionKey), "Timed out after " .. tostring(Config.RemoteTimeout) .. "s")
        return false, nil, "Timeout"
    end

    if requestEpoch ~= LifecycleEpoch then
        return false, nil, "StaleEpoch"
    end

    if not invokeOk then
        RecordError("Remote:" .. tostring(actionKey), invokeResult)
        return false, nil, tostring(invokeResult)
    end

    return true, invokeResult, "OK"
end

-- ================= TINE HUB GUI (WITH LIVE DIAGNOSTICS) =================

local GUI = Instance.new("ScreenGui")
GUI.Name = "TineHub_AutoFarm"
GUI.ResetOnSpawn = false
GUI.DisplayOrder = 999

local guiParent = nil
pcall(function()
    if typeof(gethui) == "function" then
        guiParent = gethui()
    end
end)

if not guiParent then
    guiParent = LP:WaitForChild("PlayerGui", 15)
end

if guiParent then
    GUI.Parent = guiParent
end

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 310, 0, 350)
Main.Position = UDim2.new(0.5, -155, 0.20, 0)
Main.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = GUI

Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local Stroke = Instance.new("UIStroke", Main)
Stroke.Color = Color3.fromRGB(0, 170, 255)
Stroke.Thickness = 1.5

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 34)
Header.BackgroundColor3 = Color3.fromRGB(20, 95, 165)
Header.BorderSizePixel = 0
Header.Parent = Main

Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -16, 1, 0)
Title.Position = UDim2.new(0, 8, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "TINE HUB | FIRST SEA AUTO FARM"
Title.TextColor3 = Color3.new(1, 1, 1)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 12
Title.TextXAlignment = Enum.TextXAlignment.Center
Title.Parent = Header

local function CreateLabel(text, y, color)
    local obj = Instance.new("TextLabel")
    obj.Size = UDim2.new(1, -20, 0, 17)
    obj.Position = UDim2.new(0, 10, 0, y)
    obj.BackgroundTransparency = 1
    obj.TextColor3 = color or Color3.fromRGB(230, 235, 245)
    obj.TextXAlignment = Enum.TextXAlignment.Left
    obj.Font = Enum.Font.GothamMedium
    obj.TextSize = 11
    obj.TextTruncate = Enum.TextTruncate.AtEnd
    obj.Text = text
    obj.Parent = Main
    return obj
end

local LevelLabel      = CreateLabel("Level: Loading...", 38)
local TargetLabel     = CreateLabel("Target: None", 56)
local ProgressLabel   = CreateLabel("Quest: None (0/0)", 74)
local StatsLabel      = CreateLabel("Auto Stats: Melee Only", 92)
local StatusLabel     = CreateLabel("Status: Initializing...", 110)
local CombatDiagLabel = CreateLabel("Combat: Idle | Wpn: None", 128, Color3.fromRGB(140, 210, 255))
local MobDiagLabel    = CreateLabel("Mob: None | Dist: - | Mobs: 0/0", 146, Color3.fromRGB(180, 220, 180))
local ErrDiagLabel    = CreateLabel("Diag: Ready", 164, Color3.fromRGB(255, 195, 140))

local function CreateSmallBtn(text, xScale, xOffset, y, wScale)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(wScale or 0.48, -12, 0, 25)
    btn.Position = UDim2.new(xScale, xOffset, 0, y)
    btn.BackgroundColor3 = Color3.fromRGB(25, 135, 95)
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 10
    btn.Text = text
    btn.Parent = Main
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    return btn
end

local FastAtkBtn   = CreateSmallBtn("Fast Attack: ON", 0, 10, 188, 0.48)
local BringMobBtn  = CreateSmallBtn("Bring Mob: ON", 0.52, 2, 188, 0.48)
local AutoHakiBtn  = CreateSmallBtn("Auto Haki: ON", 0, 10, 218, 0.48)
local AutoStatBtn  = CreateSmallBtn("Melee Stats: ON", 0.52, 2, 218, 0.48)
local SpeedModeBtn = CreateSmallBtn("Tween Speed: 210", 0, 10, 248, 1.0)
SpeedModeBtn.Size  = UDim2.new(1, -20, 0, 24)
SpeedModeBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 145)

local Toggle = Instance.new("TextButton")
Toggle.Size = UDim2.new(1, -20, 0, 30)
Toggle.Position = UDim2.new(0, 10, 0, 278)
Toggle.BackgroundColor3 = Color3.fromRGB(30, 150, 85)
Toggle.TextColor3 = Color3.new(1, 1, 1)
Toggle.Font = Enum.Font.GothamBold
Toggle.TextSize = 12
Toggle.Text = "STOP AUTO FARM"
Toggle.Parent = Main
Instance.new("UICorner", Toggle).CornerRadius = UDim.new(0, 6)

local FooterLabel = CreateLabel("TINE HUB | FSM: IDLE | Worker: OK", 316, Color3.fromRGB(135, 160, 190))

local function SetLabelText(label, newText)
    if label and label.Parent and label.Text ~= newText then
        label.Text = newText
    end
end

local function RefreshDiagnosticsUI()
    DiagState.QuestState = QuestState
    DiagState.ActiveStage = LockedStage and LockedStage.QuestName or "None"
    DiagState.ExpectedMob = LockedStage and LockedStage.MobName or "None"

    local workerAge = os.clock() - CombatWorkerHeartbeatAt
    DiagState.WorkerStatus = (workerAge <= Config.WorkerWatchdogTimeout) and "OK" or "STALLED"

    SetLabelText(
        CombatDiagLabel,
        string.format(
            "Wpn: %s | Atk: %d | Skip: %s",
            DiagState.WeaponStatus,
            DiagState.AttackCount,
            DiagState.LastAttackSkipReason
        )
    )

    local distStr = (DiagState.TargetDistance >= 0) and string.format("%.1f", DiagState.TargetDistance) or "-"
    SetLabelText(
        MobDiagLabel,
        string.format(
            "Tgt: %s (%s) | Dist: %s | Mobs: %d/%d",
            DiagState.SelectedTarget,
            DiagState.TargetHealth,
            distStr,
            DiagState.MatchingEnemies,
            DiagState.TotalEnemies
        )
    )

    SetLabelText(ErrDiagLabel, "Err: " .. tostring(DiagState.LastError))
    SetLabelText(
        FooterLabel,
        string.format("TINE HUB | FSM: %s | Worker: %s", QuestState, DiagState.WorkerStatus)
    )
end

local function SetStatus(text)
    SetLabelText(StatusLabel, "Status: " .. tostring(text))
    RefreshDiagnosticsUI()
end

local function SetProgressText(text)
    SetLabelText(ProgressLabel, "Quest: " .. tostring(text))
    RefreshDiagnosticsUI()
end

-- ================= CHARACTER LIFECYCLE & CACHE =================

local function GetCharacter()
    if CharRef and CharRef.Parent and HumRef and HumRef.Parent and RootRef and RootRef.Parent then
        if HumRef.Health > 0 then
            DiagState.CharStatus = string.format("Alive (HP %d)", math.floor(HumRef.Health))
            return CharRef, HumRef, RootRef
        end
        DiagState.CharStatus = "Dead"
        return nil
    end

    local char = LP.Character
    if not char or not char.Parent then
        CharRef, HumRef, RootRef = nil, nil, nil
        DiagState.CharStatus = "NoChar"
        return nil
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")

    if hum and root and hum.Health > 0 then
        CharRef, HumRef, RootRef = char, hum, root
        DiagState.CharStatus = string.format("Alive (HP %d)", math.floor(hum.Health))
        return char, hum, root
    end

    DiagState.CharStatus = "InvalidHumOrRoot"
    return nil
end

local function RestoreCharacterCollisions()
    for part, origCollide in pairs(OriginalCollideState) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = origCollide
            end)
        end
    end
end

local function RestoreModifiedMobs()
    for mob, state in pairs(OriginalMobState) do
        if mob and mob.Parent then
            pcall(function()
                local mr = mob:FindFirstChild("HumanoidRootPart")
                local mh = mob:FindFirstChildOfClass("Humanoid")
                if mr and state.CanCollide ~= nil then
                    mr.CanCollide = state.CanCollide
                end
                if mh then
                    if state.WalkSpeed then mh.WalkSpeed = state.WalkSpeed end
                    if state.JumpPower then mh.JumpPower = state.JumpPower end
                end
            end)
        end
        OriginalMobState[mob] = nil
    end
end

local function EnableStabilizer(root)
    if not root or not root.Parent then return end
    if not StabilizerBV or StabilizerBV.Parent ~= root then
        if StabilizerBV then
            pcall(function() StabilizerBV:Destroy() end)
        end
        local bv = Instance.new("BodyVelocity")
        bv.Name = "TineHubStabilizerBV"
        bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        bv.Velocity = Vector3.zero
        bv.Parent = root
        StabilizerBV = bv
    else
        StabilizerBV.Velocity = Vector3.zero
    end
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function DisableStabilizer()
    if StabilizerBV then
        pcall(function()
            StabilizerBV:Destroy()
        end)
        StabilizerBV = nil
    end
end

local function CancelMovement(reason)
    MoveToken += 1
    if ActiveTween then
        pcall(function()
            ActiveTween:Cancel()
        end)
        ActiveTween = nil
    end
    if reason then
        DiagState.LastAttackSkipReason = "MoveCancel:" .. tostring(reason)
    end
end

local function RebuildCharacterPartCache(char)
    table.clear(CachedCharParts)

    local function TrackPart(inst)
        if inst:IsA("BasePart") then
            if OriginalCollideState[inst] == nil then
                OriginalCollideState[inst] = inst.CanCollide
            end
            if not table.find(CachedCharParts, inst) then
                table.insert(CachedCharParts, inst)
            end
        end
    end

    for _, desc in ipairs(char:GetDescendants()) do
        TrackPart(desc)
    end

    table.insert(CharConnections, char.DescendantAdded:Connect(TrackPart))
    table.insert(CharConnections, char.DescendantRemoving:Connect(function(inst)
        if inst:IsA("BasePart") then
            local idx = table.find(CachedCharParts, inst)
            if idx then
                table.remove(CachedCharParts, idx)
            end
        end
    end))
end

local function BindCharacterEvents(char, expectedToken)
    ClearCharConnections()
    CachedWeapon = nil

    if not char or not char.Parent then
        return false
    end

    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
    local root = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 10)

    if not Alive or expectedToken ~= RespawnToken or not hum or not root then
        return false
    end

    CharRef = char
    HumRef = hum
    RootRef = root

    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
    end)

    RebuildCharacterPartCache(char)

    table.insert(CharConnections, hum.Died:Connect(function()
        BumpEpoch()
        IsRespawning = true
        RespawnStartedAt = os.clock()
        CombatTarget = nil
        CachedWeapon = nil
        IsAttacking = false
        CancelMovement("CharacterDied")
        DisableStabilizer()
        if Running and Alive then
            SetStatus("Character died, waiting respawn...")
        end
    end))

    return true
end

local function InitRespawnHandler()
    if LP.Character then
        RespawnToken += 1
        BindCharacterEvents(LP.Character, RespawnToken)
    end

    RegisterGlobalConn(LP.CharacterRemoving:Connect(function()
        BumpEpoch()
        IsRespawning = true
        RespawnStartedAt = os.clock()
        CombatTarget = nil
        CachedWeapon = nil
        IsAttacking = false
        CharRef, HumRef, RootRef = nil, nil, nil
        CancelMovement("CharacterRemoving")
        DisableStabilizer()
        ClearCharConnections()
    end))

    RegisterGlobalConn(LP.CharacterAdded:Connect(function(newChar)
        RespawnToken += 1
        local myRespawnToken = RespawnToken
        BumpEpoch()

        IsRespawning = true
        RespawnStartedAt = os.clock()
        CombatTarget = nil
        CachedWeapon = nil
        IsAttacking = false
        CancelMovement("CharacterAdded")
        DisableStabilizer()

        local bound = BindCharacterEvents(newChar, myRespawnToken)
        if myRespawnToken ~= RespawnToken or not Alive then
            return
        end

        if not bound then
            IsRespawning = false
            RecordError("Respawn", "BindCharacterEvents timed out; watchdog will recover")
            return
        end

        task.wait(Config.RespawnSettleDelay)
        if myRespawnToken ~= RespawnToken or not Alive then
            return
        end

        IsRespawning = false

        if Running then
            if QuestState == "FARMING" or QuestState == "VERIFYING_QUEST" then
                SetStatus("Respawned! Verifying quest...")
            else
                QuestState = "IDLE"
                SetStatus("Respawned! Resuming...")
            end
        end
    end))
end

-- ================= STRUCTURED MOVEMENT CONTROLLER =================

local function MoveToCFrame(targetCF, cancelCheck, maxDuration)
    if not CanContinue() then
        return false, "LifecyclePaused"
    end
    if typeof(targetCF) ~= "CFrame" then
        return false, "InvalidTargetType"
    end

    local _, _, root = GetCharacter()
    if not root then
        return false, "NoCharacterRoot"
    end

    local cleanCF = IsValidCFrame(targetCF) and targetCF or SafeUprightCF(targetCF.Position)
    if not cleanCF or not IsValidCFrame(cleanCF) then
        return false, "InvalidCoordinates"
    end

    local initialDist = (root.Position - cleanCF.Position).Magnitude
    if initialDist <= 1.5 then
        EnableStabilizer(root)
        return true, "AlreadyAtTarget"
    elseif initialDist <= 7.0 then
        CancelMovement()
        EnableStabilizer(root)
        root.CFrame = cleanCF
        return true, "SnappedShortDistance"
    end

    CancelMovement()
    local myToken = MoveToken
    local moveEpoch = LifecycleEpoch
    EnableStabilizer(root)

    local duration = initialDist / math.max(Config.TweenSpeed, 1)
    local timeoutDeadline = os.clock() + math.min(duration + 8.0, maxDuration or Config.MaxMoveDuration)

    local tween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        {CFrame = cleanCF}
    )

    ActiveTween = tween
    tween:Play()

    local lastProgressPos = root.Position
    local lastProgressTime = os.clock()
    local stuckRecoveries = 0

    while tween.PlaybackState == Enum.PlaybackState.Playing do
        if not CanContinue(moveEpoch) or myToken ~= MoveToken then
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end
            return false, "Cancelled"
        end

        if os.clock() >= timeoutDeadline then
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end
            return false, "Timeout"
        end

        local _, _, currentRoot = GetCharacter()
        if currentRoot ~= root then
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end
            return false, "CharacterChanged"
        end

        EnableStabilizer(root)

        local distNow = (root.Position - cleanCF.Position).Magnitude
        if distNow <= 7.0 then
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end
            root.CFrame = cleanCF
            return true, "Arrived"
        end

        if cancelCheck and cancelCheck() then
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end
            return false, "ConditionInterrupted"
        end

        local now = os.clock()
        if (root.Position - lastProgressPos).Magnitude >= Config.StuckMinMoveDist then
            lastProgressPos = root.Position
            lastProgressTime = now
        elseif (now - lastProgressTime) >= Config.StuckCheckInterval and distNow > 12.0 then
            stuckRecoveries += 1
            pcall(function() tween:Cancel() end)
            if ActiveTween == tween then ActiveTween = nil end

            if stuckRecoveries >= 2 then
                return false, "StuckObstacle"
            end

            SetStatus("Anti-stuck recovery...")
            local nudgeCF = SafeUprightCF(root.Position + Vector3.new(0, 15, 0))
            if nudgeCF then
                root.CFrame = nudgeCF
            end
            lastProgressPos = root.Position
            lastProgressTime = os.clock()

            local newDist = (root.Position - cleanCF.Position).Magnitude
            local newDur = newDist / math.max(Config.TweenSpeed, 1)
            tween = TweenService:Create(
                root,
                TweenInfo.new(newDur, Enum.EasingStyle.Linear),
                {CFrame = cleanCF}
            )
            ActiveTween = tween
            tween:Play()
        end

        task.wait(0.04)
    end

    if not CanContinue(moveEpoch) or myToken ~= MoveToken then
        if ActiveTween == tween then ActiveTween = nil end
        return false, "PostYieldCancelled"
    end

    local _, _, finalRoot = GetCharacter()
    local arrived = (finalRoot == root) and ((root.Position - cleanCF.Position).Magnitude <= 12.0)

    if ActiveTween == tween then
        ActiveTween = nil
    end

    return arrived, (arrived and "Completed" or "IncompleteDistance")
end

local function NavigateIslandTransition(stage)
    if not CanContinue() then return false end
    local _, _, root = GetCharacter()
    if not root then return false end

    local questPos = stage.QuestNPC.Position
    local epoch = LifecycleEpoch

    if root.Position.X > 55000 and questPos.X < 50000 then
        SetStatus("Exiting Fishman Island...")
        RemoteManager:Invoke("requestEntrance", FISHMAN_EXIT_TO)
        task.wait(0.6)
        if not CanContinue(epoch) then return false end

        local _, _, checkRoot = GetCharacter()
        if checkRoot and checkRoot.Position.X > 55000 then
            MoveToCFrame(CFrame.new(FISHMAN_ENTRANCE_TO), nil, 25.0)
            task.wait(0.4)
            if not CanContinue(epoch) then return false end
        end
    end

    if not stage.EntranceFrom or not stage.EntranceTo then
        return true
    end

    _, _, root = GetCharacter()
    if not root then return false end

    if (root.Position - questPos).Magnitude < 2800 then
        return true
    end

    SetStatus("Requesting island entrance...")
    RemoteManager:Invoke("requestEntrance", stage.EntranceTo)
    task.wait(0.6)
    if not CanContinue(epoch) then return false end

    local _, _, afterRoot = GetCharacter()
    if afterRoot and (afterRoot.Position - questPos).Magnitude < 2800 then
        return true
    end

    SetStatus("Navigating to island portal...")
    local moved = MoveToCFrame(stage.EntranceFrom, nil, 40.0)
    if not moved or not CanContinue(epoch) then
        return false
    end

    local _, _, portalRoot = GetCharacter()
    if not portalRoot then return false end

    if (portalRoot.Position - stage.EntranceFrom.Position).Magnitude < 80 then
        RemoteManager:Invoke("requestEntrance", stage.EntranceTo)
        task.wait(0.8)
        if not CanContinue(epoch) then return false end
    end

    local _, _, finalRoot = GetCharacter()
    return finalRoot ~= nil and (finalRoot.Position - questPos).Magnitude < 2800
end

local function NavigateToQuestNPC(stage, level)
    if not NavigateIslandTransition(stage) or not CanContinue() then
        return false, "IslandTransitionFailed"
    end

    SetStatus(string.format("Lv %d | Moving to %s", level, stage.QuestName))
    local questCF = SafeUprightCF(stage.QuestNPC.Position)
    if not questCF then
        return false, "InvalidQuestNPCCF"
    end

    local moved, reason = MoveToCFrame(questCF, nil, 40.0)
    if not moved or not CanContinue() then
        return false, reason
    end

    local _, _, root = GetCharacter()
    if not root then
        return false, "NoCharacterRoot"
    end

    if (root.Position - questCF.Position).Magnitude > 8.0 then
        root.CFrame = questCF
    end
    EnableStabilizer(root)
    return true, "ArrivedAtQuestNPC"
end

-- ================= TARGET DETECTION & BRING MOB =================

local function NameMatches(instanceName, mobName)
    if not instanceName or not mobName then return false end
    if instanceName == mobName then
        return true
    end
    local prefix = mobName .. " ["
    return string.sub(instanceName, 1, #prefix) == prefix
end

local function IsMobValid(mob, expectedMobName)
    if not mob or not mob.Parent then
        return false
    end

    if expectedMobName and not NameMatches(mob.Name, expectedMobName) then
        return false
    end

    local blockedUntil = MobBlacklist[mob]
    if blockedUntil then
        if os.clock() < blockedUntil then
            return false
        else
            MobBlacklist[mob] = nil
        end
    end

    local mobHum = mob:FindFirstChildOfClass("Humanoid")
    local mobRoot = mob:FindFirstChild("HumanoidRootPart")

    if not mobHum or not mobRoot or mobHum.Health <= 0 then
        return false
    end

    return true
end

local function FindNearestMob(mobName, root)
    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies or not root then
        DiagState.TotalEnemies = 0
        DiagState.MatchingEnemies = 0
        return nil
    end

    local children = enemies:GetChildren()
    DiagState.TotalEnemies = #children

    local nearest = nil
    local shortest = math.huge
    local matchCount = 0
    local rootPos = root.Position

    for _, mob in ipairs(children) do
        if IsMobValid(mob, mobName) then
            matchCount += 1
            local mobRoot = mob:FindFirstChild("HumanoidRootPart")
            local distance = (rootPos - mobRoot.Position).Magnitude
            if distance < shortest then
                shortest = distance
                nearest = mob
            end
        end
    end

    DiagState.MatchingEnemies = matchCount

    if nearest then
        local mh = nearest:FindFirstChildOfClass("Humanoid")
        DiagState.SelectedTarget = nearest.Name
        DiagState.TargetHealth = mh and string.format("%d/%d", math.floor(mh.Health), math.floor(mh.MaxHealth)) or "?"
        DiagState.TargetDistance = shortest
    else
        DiagState.SelectedTarget = "None"
        DiagState.TargetHealth = "0/0"
        DiagState.TargetDistance = -1
    end

    return nearest
end

local function BringNearbyMobs(mobName, targetPos, primaryMob)
    if not Config.BringMob or not targetPos or not CanContinue() then
        return
    end

    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies then return end

    local targetCF = SafeUprightCF(targetPos)
    if not targetCF then return end

    local broughtCount = 0

    for _, mob in ipairs(enemies:GetChildren()) do
        if broughtCount >= Config.MaxBringMobs then
            break
        end

        if IsMobValid(mob, mobName) then
            local mobHum = mob:FindFirstChildOfClass("Humanoid")
            local mobRoot = mob:FindFirstChild("HumanoidRootPart")
            if mobHum and mobRoot then
                local dist = (mobRoot.Position - targetPos).Magnitude
                if dist <= Config.BringMobRadius then
                    broughtCount += 1
                    pcall(function()
                        if not OriginalMobState[mob] then
                            OriginalMobState[mob] = {
                                WalkSpeed = mobHum.WalkSpeed,
                                JumpPower = mobHum.JumpPower,
                                CanCollide = mobRoot.CanCollide
                            }
                        end
                        if mob ~= primaryMob and dist > 3.5 then
                            mobRoot.CFrame = targetCF
                        end
                        if mobRoot.CanCollide then
                            mobRoot.CanCollide = false
                        end
                        mobRoot.AssemblyLinearVelocity = Vector3.zero
                        if mobHum.WalkSpeed ~= 0 then mobHum.WalkSpeed = 0 end
                        if mobHum.JumpPower ~= 0 then mobHum.JumpPower = 0 end
                    end)
                end
            end
        end
    end
end

local function GetSpawnNodes(stage)
    local mobName = stage.MobName
    local now = os.clock()
    local cached = SpawnNodesCache[mobName]

    if cached and (now - cached.timestamp) < Config.SpawnCacheTTL and #cached.nodes > 0 then
        return cached.nodes
    end

    local nodes = {}
    local origin = workspace:FindFirstChild("_WorldOrigin")
    local spawns = origin and origin:FindFirstChild("EnemySpawns")

    if spawns then
        for _, sp in ipairs(spawns:GetChildren()) do
            if NameMatches(sp.Name, mobName) then
                local part = sp:IsA("BasePart") and sp
                    or sp:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    local cf = SafeUprightCF(part.Position + Vector3.new(0, Config.HoverHeight + 5, 0))
                    if cf then
                        table.insert(nodes, cf)
                    end
                end
            end
        end
    end

    local fallbackCF = SafeUprightCF(stage.FallbackSpawn.Position + Vector3.new(0, Config.HoverHeight + 5, 0))
    if fallbackCF then
        table.insert(nodes, fallbackCF)
    end

    SpawnNodesCache[mobName] = {
        timestamp = now,
        nodes = nodes
    }

    return nodes
end

local function PatrolSpawnNodes(stage)
    SetStatus(string.format("Waiting %s spawn (%d/%d)", stage.MobName, QuestCurrentCount, QuestRequiredCount))

    local nodes = GetSpawnNodes(stage)
    local now = os.clock()
    if now - LastSpawnPatrolAt > 2.2 then
        SpawnPatrolIndex = (SpawnPatrolIndex % #nodes) + 1
        LastSpawnPatrolAt = now
    end

    local targetNode = nodes[SpawnPatrolIndex] or nodes[1]
    if targetNode then
        MoveToCFrame(targetNode, function()
            local _, _, r = GetCharacter()
            return not CanContinue() or (r and FindNearestMob(stage.MobName, r) ~= nil)
        end, 20.0)
    end
end

local function PositionAboveMob(stage, mob, root)
    local mobRoot = mob:FindFirstChild("HumanoidRootPart")
    local mobHum = mob:FindFirstChildOfClass("Humanoid")
    if not mobRoot or not mobHum then return false end

    local mobPos = mobRoot.Position
    local hoverCF, hoverPos = BuildCombatHoverCF(mobPos)
    if not hoverCF or not hoverPos then return false end

    if (root.Position - hoverPos).Magnitude > 16.0 then
        SetStatus(string.format("Moving to %s (%d/%d)", stage.MobName, QuestCurrentCount, QuestRequiredCount))
        local arrived, reason = MoveToCFrame(hoverCF, function()
            if not CanContinue() then return true end
            if not IsMobValid(mob, stage.MobName) then return true end
            local _, _, r = GetCharacter()
            if r and (r.Position - mobRoot.Position).Magnitude <= 14.0 then
                return true
            end
            return false
        end, 30.0)

        if not CanContinue() then return false end

        if not arrived and reason == "StuckObstacle" and IsMobValid(mob, stage.MobName) then
            MobBlacklist[mob] = os.clock() + Config.MobBlacklistDuration
            CombatTarget = nil
            return false
        end
    end

    local _, _, latestRoot = GetCharacter()
    if not latestRoot or not IsMobValid(mob, stage.MobName) then
        return false
    end

    CancelMovement()
    EnableStabilizer(latestRoot)

    local latestMobPos = mobRoot.Position
    local lockCF, _ = BuildCombatHoverCF(latestMobPos)
    if lockCF and IsValidCFrame(lockCF) then
        latestRoot.CFrame = lockCF
    end

    local currentDist = (latestRoot.Position - latestMobPos).Magnitude
    DiagState.TargetDistance = currentDist
    DiagState.SelectedTarget = mob.Name
    DiagState.TargetHealth = string.format("%d/%d", math.floor(mobHum.Health), math.floor(mobHum.MaxHealth))

    if currentDist <= Config.AttackRange then
        BringNearbyMobs(stage.MobName, latestMobPos, mob)
    end

    return currentDist <= Config.AttackRange
end

-- ================= ACCURATE QUEST VALIDATION & PROGRESS PARSER =================

local function IsGuiHierarchyVisible(guiObj)
    local curr = guiObj
    while curr and curr ~= LP do
        if curr:IsA("GuiObject") and not curr.Visible then
            return false
        end
        if curr:IsA("LayerCollector") and not curr.Enabled then
            return false
        end
        curr = curr.Parent
    end
    return curr == LP or (curr ~= nil)
end

local function FindActiveQuestFrame()
    if CachedQuestFrame and CachedQuestFrame.Parent and IsGuiHierarchyVisible(CachedQuestFrame) then
        return CachedQuestFrame
    end

    CachedQuestFrame = nil
    CachedQuestTitle = nil

    local playerGui = LP:FindFirstChild("PlayerGui")
    if not playerGui then return nil end

    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") and child.Name ~= "TineHub_AutoFarm" and child.Enabled then
            -- Prefer direct Quest frame containing Container.QuestTitle.Title
            local q = child:FindFirstChild("Quest") or child:FindFirstChild("Quest", true)
            if q and q:IsA("GuiObject") and IsGuiHierarchyVisible(q) then
                local container = q:FindFirstChild("Container")
                local questTitle = container and container:FindFirstChild("QuestTitle")
                local titleLabel = questTitle and questTitle:FindFirstChild("Title")
                if titleLabel and titleLabel:IsA("TextLabel") then
                    CachedQuestFrame = q
                    CachedQuestTitle = titleLabel
                    return q
                end
            end
        end
    end

    -- Secondary fallback if Quest frame structure lacks Container.QuestTitle
    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") and child.Name ~= "TineHub_AutoFarm" and child.Enabled then
            local q = child:FindFirstChild("Quest")
            if q and q:IsA("GuiObject") and IsGuiHierarchyVisible(q) then
                CachedQuestFrame = q
                return q
            end
        end
    end

    return nil
end

local function IsIgnoredQuestLabelText(lowerTxt)
    if lowerTxt == "" or lowerTxt == "quest" or lowerTxt == "quests" then
        return true
    end
    if string.find(lowerTxt, "reward", 1, true)
        or string.find(lowerTxt, "hadiah", 1, true)
        or string.find(lowerTxt, "exp", 1, true)
        or string.find(lowerTxt, "beli", 1, true)
        or string.find(lowerTxt, "$", 1, true)
        or string.find(lowerTxt, "abandon", 1, true)
        or string.find(lowerTxt, "cancel", 1, true)
        or string.find(lowerTxt, "batal", 1, true) then
        return true
    end
    return false
end

local function ReadQuestTitle()
    local questFrame = FindActiveQuestFrame()
    if not questFrame then
        DiagState.QuestTitle = "Hidden"
        return false, "", ""
    end

    if CachedQuestTitle and CachedQuestTitle.Parent and CachedQuestTitle.Visible then
        local rawText = CachedQuestTitle.Text or ""
        local contentText = ""
        pcall(function()
            contentText = CachedQuestTitle.ContentText or ""
        end)
        local primary = (contentText ~= "" and contentText) or rawText
        DiagState.QuestTitle = primary ~= "" and primary or "EmptyTitle"
        return true, primary, rawText
    end

    for _, desc in ipairs(questFrame:GetDescendants()) do
        if desc:IsA("TextLabel") and desc.Visible then
            local txt = desc.Text or ""
            local lower = string.lower(txt)
            if not IsIgnoredQuestLabelText(lower) then
                if desc.Name == "Title" and not CachedQuestTitle then
                    CachedQuestTitle = desc
                end
                local contentText = ""
                pcall(function()
                    contentText = desc.ContentText or ""
                end)
                local primary = (contentText ~= "" and contentText) or txt
                DiagState.QuestTitle = primary
                return true, primary, txt
            end
        end
    end

    DiagState.QuestTitle = "PendingText"
    return true, "", ""
end

-- Returns: (cur: number, req: number, hasExplicitReq: boolean, hasFraction: boolean)
-- Does NOT pretend defaultReq was found in the text when no number exists.
local function ParseQuestProgress(primaryText, rawText, stage)
    local defaultReq = (stage and stage.ExpectedCount) or 8

    local function ExtractNumbers(txt)
        if not txt or txt == "" then
            return nil, nil, false, false
        end

        -- 1. Check fraction pattern "(X/Y)" or "X/Y"
        local c1, r1 = string.match(txt, "(%d+)%s*/%s*(%d+)")
        if c1 and r1 then
            local reqNum = tonumber(r1)
            if reqNum and reqNum > 0 and reqNum <= 25 then
                return (tonumber(c1) or 0), reqNum, true, true
            end
        end

        -- 2. Strip level prefixes ("Lv. 10", "Level 10") before checking standalone target count
        local cleaned = string.gsub(string.lower(txt), "lv%.?%s*%d+", "")
        cleaned = string.gsub(cleaned, "level%s*%d+", "")

        local n = string.match(cleaned, "(%d+)")
        if n then
            local reqNum = tonumber(n)
            if reqNum and reqNum > 0 and reqNum <= 25 then
                return 0, reqNum, true, false
            end
        end

        return nil, nil, false, false
    end

    local cur, req, hasExp, hasFrac = ExtractNumbers(rawText)
    if not hasExp and primaryText ~= rawText then
        cur, req, hasExp, hasFrac = ExtractNumbers(primaryText)
    end

    return (cur or 0), (req or defaultReq), hasExp, hasFrac
end

local function TextMatchesMob(rawText, mobName)
    if not rawText or not mobName or rawText == "" then return false end
    local lowerText = string.lower(rawText)
    local lowerMob = string.lower(mobName)

    if lowerMob == "bandit" then
        if string.find(lowerText, "desert bandit", 1, true)
            or string.find(lowerText, "snow bandit", 1, true)
            or string.find(lowerText, "sky bandit", 1, true) then
            return false
        end
    elseif lowerMob == "pirate" then
        if string.find(lowerText, "galley pirate", 1, true) then
            return false
        end
    elseif lowerMob == "prisoner" then
        if string.find(lowerText, "dangerous prisoner", 1, true) then
            return false
        end
    end

    if string.find(lowerText, lowerMob, 1, true) then
        return true
    end
    if string.sub(lowerMob, -1) == "y" then
        if string.find(lowerText, string.sub(lowerMob, 1, -2) .. "ies", 1, true) then
            return true
        end
    end
    if string.sub(lowerMob, -3) == "man" then
        if string.find(lowerText, string.sub(lowerMob, 1, -4) .. "men", 1, true) then
            return true
        end
    end
    return false
end

local function FindStageByQuestText(primaryText, rawText)
    for _, stage in ipairs(StagesBySpecificity) do
        if TextMatchesMob(primaryText, stage.MobName) or TextMatchesMob(rawText, stage.MobName) then
            return stage
        end
    end
    return nil
end

-- Comprehensive Quest State Classifier:
-- Returns: status ("NO_GUI" | "TITLE_PENDING" | "MATCHED_STAGE" | "TRANSLATED_MATCH" | "MISMATCHED_QUEST"),
--          matchedStage, curKills, reqKills
local function EvaluateQuestStatus(expectedStage)
    local questVisible, primaryTitle, rawTitle = ReadQuestTitle()
    if not questVisible then
        return "NO_GUI", nil, 0, (expectedStage and expectedStage.ExpectedCount or 8)
    end

    local trimmed = string.gsub(primaryTitle or "", "^%s*(.-)%s*$", "%1")
    if trimmed == "" or IsIgnoredQuestLabelText(string.lower(trimmed)) then
        return "TITLE_PENDING", nil, 0, (expectedStage and expectedStage.ExpectedCount or 8)
    end

    local cur, req, hasExplicitReq, hasFraction = ParseQuestProgress(primaryTitle, rawTitle, expectedStage)
    local matchedStage = FindStageByQuestText(primaryTitle, rawTitle)

    if matchedStage then
        local c, r = ParseQuestProgress(primaryTitle, rawTitle, matchedStage)
        return "MATCHED_STAGE", matchedStage, c, r
    end

    -- If the client translated the mob name (so English `FindStageByQuestText` returned nil),
    -- verify that `hasExplicitReq == true` (an actual target count or X/Y fraction exists in the title)
    -- AND either we explicitly requested `expectedStage` via StartQuest or `req == expectedStage.ExpectedCount` (with req > 1 to exclude 1-kill Boss quests).
    if expectedStage and hasExplicitReq then
        if (LastRequestedStage == expectedStage and req > 1)
            or (req == expectedStage.ExpectedCount and req > 1)
            or hasFraction then
            return "TRANSLATED_MATCH", expectedStage, cur, req
        end
    end

    return "MISMATCHED_QUEST", nil, cur, req
end

local function ResetQuestFSM()
    QuestState = "IDLE"
    LockedStage = nil
    CombatTarget = nil
    QuestCurrentCount = 0
    QuestRequiredCount = 0
    QuestVerifyDeadline = 0
    QuestUnknownDetectedAt = 0
    QuestCompletionStartedAt = 0
    QuestAttemptCount = 0
    QuestNextAttempt = 0
    SetProgressText("None (0/0)")
end

-- ================= AUTO STATS (MELEE ONLY) & AUTO HAKI =================

local function ProcessAutoStats()
    if not Config.AutoStatsMelee or not CanContinue() then
        return
    end
    local now = os.clock()
    if now < NextStatAt then return end
    NextStatAt = now + Config.StatInterval

    local data = LP:FindFirstChild("Data")
    if not data then return end

    local pointsObj = data:FindFirstChild("Points")
    local statsFolder = data:FindFirstChild("Stats")
    local meleeStat = statsFolder and statsFolder:FindFirstChild("Melee")
    local meleeLevel = meleeStat and meleeStat:FindFirstChild("Level")

    local availablePoints = (pointsObj and pointsObj.Value) or 0
    local currentMeleeLv = (meleeLevel and meleeLevel.Value) or 0

    if meleeLevel then
        SetLabelText(StatsLabel, string.format("Melee Stat: Lv %d | Pts: %d", currentMeleeLv, availablePoints))
    else
        SetLabelText(StatsLabel, string.format("Auto Stats: Melee Only (Pts: %d)", availablePoints))
    end

    local remainingCap = Config.MaxStatCap - currentMeleeLv
    local pointsToSpend = math.min(availablePoints, remainingCap)

    if pointsToSpend > 0 then
        task.spawn(function()
            RemoteManager:Invoke("AddPoint", Config.AutoStatsTarget, pointsToSpend)
        end)
    end
end

local function EnableHaki(char)
    if not Config.AutoHaki or not char or not CanContinue() then return end
    if char:FindFirstChild("HasBuso") or char:GetAttribute("HasBuso") then
        return
    end

    local now = os.clock()
    if now < NextHakiAt then
        return
    end
    NextHakiAt = now + Config.HakiInterval

    task.spawn(function()
        RemoteManager:Invoke("Buso")
    end)
end

-- ================= MULTI-LAYER COMBAT & WEAPON EQUIP ENGINE =================

local NetRegisterAttack = nil
local NetRegisterHit = nil
local CachedCombatFrameworkTable = nil

local function ResolveCombatDependencies()
    if not NetRegisterAttack or not NetRegisterHit then
        pcall(function()
            local modules = RS:FindFirstChild("Modules")
            local net = modules and modules:FindFirstChild("Net")
            if net then
                NetRegisterAttack = net:FindFirstChild("RE/RegisterAttack")
                NetRegisterHit = net:FindFirstChild("RE/RegisterHit")
            end
        end)
    end

    if HasGetUpvalues and not CachedCombatFrameworkTable then
        pcall(function()
            local ps = LP:FindFirstChild("PlayerScripts")
            local cfScript = ps and ps:FindFirstChild("CombatFramework")
            if cfScript then
                local upvals = GetUpvaluesFn(require(cfScript))
                if upvals and typeof(upvals[2]) == "table" then
                    CachedCombatFrameworkTable = upvals[2]
                end
            end
        end)
    end
end

ResolveCombatDependencies()

local function IsMatchingMeleeTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end
    if tool.ToolTip == Config.WeaponType then
        return true
    end
    local lowerName = string.lower(tool.Name or "")
    if KnownMeleeToolNames[lowerName] then
        return true
    end
    return false
end

local function EquipWeapon(char, hum)
    if not char or not hum or hum.Health <= 0 then
        DiagState.WeaponStatus = "NoChar"
        return nil
    end

    -- 1. Check if cached weapon is already equipped in Character
    if CachedWeapon and CachedWeapon.Parent == char and IsMatchingMeleeTool(CachedWeapon) then
        DiagState.WeaponStatus = CachedWeapon.Name .. " (Equipped)"
        return CachedWeapon
    end

    -- 2. Scan Character for already-equipped Melee tool
    for _, tool in ipairs(char:GetChildren()) do
        if IsMatchingMeleeTool(tool) then
            CachedWeapon = tool
            DiagState.WeaponStatus = tool.Name .. " (Equipped)"
            return tool
        end
    end

    -- 3. Scan Backpack and equip into Character
    local backpack = LP:FindFirstChild("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if IsMatchingMeleeTool(tool) then
                pcall(function()
                    hum:EquipTool(tool)
                end)
                -- Fallback direct parent assignment if Humanoid:EquipTool was blocked by physics state
                if tool.Parent ~= char then
                    pcall(function()
                        tool.Parent = char
                    end)
                end
                if tool.Parent == char then
                    CachedWeapon = tool
                    DiagState.WeaponStatus = tool.Name .. " (Equipped)"
                    return tool
                else
                    DiagState.WeaponStatus = tool.Name .. " (EquipPending)"
                    return nil
                end
            end
        end
    end

    CachedWeapon = nil
    DiagState.WeaponStatus = "MissingMelee"
    return nil
end

local function GetBladeHits(root, mobName, maxRadius)
    local targets = {}
    local enemies = workspace:FindFirstChild("Enemies")
    if not enemies or not root then return targets end

    local rootPos = root.Position
    local limit = maxRadius or 55.0

    for _, mob in ipairs(enemies:GetChildren()) do
        if IsMobValid(mob, mobName) then
            local mobRoot = mob:FindFirstChild("HumanoidRootPart")
            local head = mob:FindFirstChild("Head") or mobRoot
            if (rootPos - mobRoot.Position).Magnitude <= limit then
                table.insert(targets, {mob, head})
            end
        end
    end

    return targets
end

local function FireAttackOnce(char, root, weapon, mobName)
    if IsAttacking then
        DiagState.LastAttackSkipReason = "BusyAttacking"
        return false
    end
    if not CanContinue() then
        DiagState.LastAttackSkipReason = "LifecyclePaused"
        return false
    end
    if QuestState ~= "FARMING" then
        DiagState.LastAttackSkipReason = "NotFarmingState"
        return false
    end
    if not weapon or weapon.Parent ~= char then
        DiagState.LastAttackSkipReason = "WeaponNotInChar"
        return false
    end

    -- Safe interval resolution (Fixed: uses Config.NormalAttackInterval with numeric fallback 0.28)
    local interval = (Config.FastAttack and Config.FastAttackInterval) or Config.NormalAttackInterval or 0.28
    local now = os.clock()
    if now < NextAttackAt then
        return false
    end

    IsAttacking = true
    NextAttackAt = now + interval

    local ok, err = xpcall(function()
        -- Layer 1: Standard Tool:Activate()
        pcall(function()
            weapon:Activate()
        end)

        -- Calculate dynamic viewport center for VirtualInputManager & VirtualUser
        local vpCenter = Vector2.new(640, 360)
        local cam = workspace.CurrentCamera
        if cam then
            local vs = cam.ViewportSize
            if vs.X > 0 and vs.Y > 0 then
                vpCenter = Vector2.new(vs.X * 0.5, vs.Y * 0.5)
            end
        end

        -- Layer 2: VirtualInputManager Mouse Click at Viewport Center
        if VIM then
            pcall(function()
                VIM:SendMouseButtonEvent(vpCenter.X, vpCenter.Y, 0, true, game, 0)
                VIM:SendMouseButtonEvent(vpCenter.X, vpCenter.Y, 0, false, game, 0)
            end)
        end

        -- Layer 3: VirtualUser Click Controller at Viewport Center
        pcall(function()
            VU:CaptureController()
            VU:Button1Down(vpCenter)
            VU:Button1Up(vpCenter)
        end)

        -- Layer 4: ReplicatedStorage.Modules.Net FastAttack & CombatFramework (when available)
        if Config.FastAttack then
            if not NetRegisterAttack or not NetRegisterHit then
                ResolveCombatDependencies()
            end
            if NetRegisterAttack and NetRegisterHit and root then
                pcall(function()
                    local hits = GetBladeHits(root, mobName, 55.0)
                    if #hits > 0 then
                        NetRegisterAttack:FireServer(0)
                        NetRegisterHit:FireServer(hits[1][2], hits)
                    end
                end)
            end

            if CachedCombatFrameworkTable then
                pcall(function()
                    local activeController = CachedCombatFrameworkTable.activeController
                    if activeController and activeController.blades and #activeController.blades > 0 then
                        activeController.timeToNextAttack = 0
                        activeController.hitboxMagnitude = 55
                        if typeof(activeController.attack) == "function" then
                            activeController:attack()
                        end
                    end
                end)
            end
        end
    end, debug.traceback)

    -- Always release IsAttacking lock even if an error occurred
    IsAttacking = false

    if not ok then
        DiagState.LastAttackSkipReason = "AttackError"
        RecordError("FireAttackOnce", err)
        return false
    end

    DiagState.AttackCount += 1
    DiagState.LastAttackSkipReason = "OK (HitFired)"
    return true
end

-- ================= SELF-HEALING COMBAT WORKER =================

local function SpawnCombatWorker()
    CombatWorkerId += 1
    local myWorkerId = CombatWorkerId
    CombatWorkerHeartbeatAt = os.clock()

    task.spawn(function()
        while Alive and myWorkerId == CombatWorkerId do
            CombatWorkerHeartbeatAt = os.clock()
            local interval = (Config.FastAttack and Config.FastAttackInterval) or Config.NormalAttackInterval or 0.28
            task.wait(interval)
            CombatWorkerHeartbeatAt = os.clock()

            if CanContinue() and QuestState == "FARMING" and LockedStage then
                local ok, err = xpcall(function()
                    local target = CombatTarget
                    if not IsMobValid(target, LockedStage.MobName) then
                        DiagState.LastAttackSkipReason = "NoValidTarget"
                        return
                    end

                    local char, hum, root = GetCharacter()
                    if not char or not hum or not root then
                        DiagState.LastAttackSkipReason = "InvalidChar"
                        return
                    end

                    local mobRoot = target:FindFirstChild("HumanoidRootPart")
                    if not mobRoot then
                        DiagState.LastAttackSkipReason = "NoMobRoot"
                        return
                    end

                    local dist = (root.Position - mobRoot.Position).Magnitude
                    DiagState.TargetDistance = dist
                    if dist > Config.AttackRange then
                        DiagState.LastAttackSkipReason = string.format("OutOfRange(%.0f)", dist)
                        return
                    end

                    local weapon = EquipWeapon(char, hum)
                    if not weapon then
                        DiagState.LastAttackSkipReason = "WeaponUnready"
                        return
                    end

                    FireAttackOnce(char, root, weapon, LockedStage.MobName)
                end, debug.traceback)

                if not ok then
                    IsAttacking = false
                    RecordError("CombatWorker", err)
                end
            end
        end
    end)
end

-- ================= UI CONTROL & RUNNING STATE =================

local function SetRunning(state, customReason)
    Running = state
    BumpEpoch()

    SetLabelText(Toggle, state and "STOP AUTO FARM" or "START AUTO FARM")
    Toggle.BackgroundColor3 = state
        and Color3.fromRGB(30, 150, 85)
        or Color3.fromRGB(175, 45, 50)

    if not state then
        CombatTarget = nil
        IsAttacking = false
        CancelMovement("UserStopped")
        DisableStabilizer()
        RestoreCharacterCollisions()
        RestoreModifiedMobs()
        SetStatus(customReason or "Stopped")
    else
        CombatTarget = nil
        IsAttacking = false
        ResetQuestFSM()
        SetStatus(customReason or "Resuming...")
    end
end

-- ================= MAIN QUEST FSM STEP =================

local function Step()
    if not Alive or not Running then
        return
    end

    -- Self-Healing Combat Worker Watchdog
    if (os.clock() - CombatWorkerHeartbeatAt) > Config.WorkerWatchdogTimeout then
        IsAttacking = false
        RecordError("Watchdog", "Combat worker stalled; restarting worker")
        SpawnCombatWorker()
    end

    -- Respawn Watchdog Recovery
    if IsRespawning then
        if (os.clock() - RespawnStartedAt) >= Config.RespawnMaxWait and LP.Character then
            local c = LP.Character
            local h = c:FindFirstChildOfClass("Humanoid")
            local r = c:FindFirstChild("HumanoidRootPart")
            if h and r and h.Health > 0 then
                RespawnToken += 1
                BindCharacterEvents(c, RespawnToken)
                IsRespawning = false
            end
        end
        if IsRespawning then
            SetStatus("Waiting respawn...")
            return
        end
    end

    local level = LP.Data.Level.Value
    SetLabelText(LevelLabel, string.format("Level: %d / %d", level, Config.MaxFirstSeaLevel))

    ProcessAutoStats()

    if level >= Config.MaxFirstSeaLevel then
        SetRunning(false, "Level 700 reached! First Sea Completed.")
        return
    end

    local char, hum, root = GetCharacter()
    if not root then
        CombatTarget = nil
        DisableStabilizer()
        SetStatus("Waiting character...")
        return
    end

    local stepEpoch = LifecycleEpoch
    local qStatus, matchedStage, curKills, reqKills = EvaluateQuestStatus(LockedStage or GetStageForLevel(level))

    -- =========================================================================
    -- STATE 1: IDLE (Evaluate Level & Validate Any Existing Active Quest)
    -- =========================================================================
    if QuestState == "IDLE" then
        CombatTarget = nil
        local desiredStage = GetStageForLevel(level)
        if not desiredStage then
            SetStatus("No stage found for Lv " .. tostring(level))
            return
        end

        if qStatus == "MATCHED_STAGE" or qStatus == "TRANSLATED_MATCH" then
            LockedStage = matchedStage or desiredStage
            QuestCurrentCount = curKills
            QuestRequiredCount = reqKills
            QuestUnknownDetectedAt = 0
            SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)
            SetProgressText(string.format("%s (%d/%d)", LockedStage.MobName, QuestCurrentCount, QuestRequiredCount))
            QuestState = "FARMING"
            return
        elseif qStatus == "TITLE_PENDING" or qStatus == "MISMATCHED_QUEST" then
            LockedStage = desiredStage
            if QuestUnknownDetectedAt == 0 then
                QuestUnknownDetectedAt = os.clock()
            end
            QuestState = "UNKNOWN_QUEST"
            SetStatus("Validating active quest UI...")
            return
        end

        LockedStage = desiredStage
        QuestCurrentCount = 0
        QuestRequiredCount = desiredStage.ExpectedCount
        QuestAttemptCount = 0
        QuestUnknownDetectedAt = 0
        SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)
        SetProgressText("Taking Quest...")
        QuestState = "TAKING_QUEST"
        return
    end

    -- =========================================================================
    -- STATE 2: UNKNOWN_QUEST (Grace Period for Late UI Text or Safe Abandon)
    -- =========================================================================
    if QuestState == "UNKNOWN_QUEST" then
        CombatTarget = nil
        if qStatus == "NO_GUI" then
            QuestUnknownDetectedAt = 0
            QuestState = "IDLE"
            return
        end

        if qStatus == "MATCHED_STAGE" or qStatus == "TRANSLATED_MATCH" then
            LockedStage = matchedStage or LockedStage or GetStageForLevel(level)
            QuestCurrentCount = curKills
            QuestRequiredCount = reqKills
            QuestUnknownDetectedAt = 0
            SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)
            SetProgressText(string.format("%s (%d/%d)", LockedStage.MobName, QuestCurrentCount, QuestRequiredCount))
            QuestState = "FARMING"
            return
        end

        if (os.clock() - QuestUnknownDetectedAt) < Config.QuestLateUIGrace then
            SetStatus("Waiting quest title text...")
            return
        end

        SetStatus("Abandoning incompatible quest...")
        RemoteManager:Invoke("AbandonQuest")
        LastRequestedStage = nil
        QuestUnknownDetectedAt = os.clock()
        task.wait(0.4)
        if not CanContinue(stepEpoch) then return end
        QuestState = "IDLE"
        return
    end

    if not LockedStage then
        ResetQuestFSM()
        return
    end

    SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)

    -- =========================================================================
    -- STATE 3: TAKING_QUEST (Navigate to Quest NPC & Request Quest)
    -- =========================================================================
    if QuestState == "TAKING_QUEST" then
        CombatTarget = nil

        if qStatus ~= "NO_GUI" then
            QuestVerifyDeadline = os.clock() + Config.QuestVerifyTimeout
            QuestState = "VERIFYING_QUEST"
            return
        end

        local latestStage = GetStageForLevel(level)
        if latestStage and latestStage ~= LockedStage then
            LockedStage = latestStage
            QuestRequiredCount = LockedStage.ExpectedCount
            QuestAttemptCount = 0
            SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)
        end

        local now = os.clock()
        if now < QuestNextAttempt then
            SetStatus(string.format("Quest retry in %.1fs...", QuestNextAttempt - now))
            return
        end

        if QuestAttemptCount >= Config.QuestMaxTries then
            QuestAttemptCount = 0
            pcall(function()
                LP:RequestStreamAroundAsync(LockedStage.QuestNPC.Position)
            end)
        end

        local navOk = NavigateToQuestNPC(LockedStage, level)
        if not navOk or not CanContinue(stepEpoch) then
            return
        end

        task.wait(Config.QuestSettleDelay)
        if not CanContinue(stepEpoch) then
            return
        end

        SetStatus("Lv " .. level .. " | Taking Quest: " .. LockedStage.MobName)
        LastRequestedStage = LockedStage
        local invoked = RemoteManager:Invoke("StartQuest", LockedStage.QuestName, LockedStage.QuestIndex)
        if not CanContinue(stepEpoch) then
            return
        end

        QuestAttemptCount += 1
        QuestNextAttempt = os.clock() + Config.QuestRetryDelay

        if not invoked then
            return
        end

        QuestVerifyDeadline = os.clock() + Config.QuestVerifyTimeout
        QuestState = "VERIFYING_QUEST"
        return
    end

    -- =========================================================================
    -- STATE 4: VERIFYING_QUEST (Confirm Quest UI Opened & Validate Stage Match)
    -- =========================================================================
    if QuestState == "VERIFYING_QUEST" then
        CombatTarget = nil
        qStatus, matchedStage, curKills, reqKills = EvaluateQuestStatus(LockedStage)

        if qStatus == "MATCHED_STAGE" or qStatus == "TRANSLATED_MATCH" then
            LockedStage = matchedStage or LockedStage
            QuestCurrentCount = curKills
            QuestRequiredCount = reqKills
            QuestAttemptCount = 0
            SetLabelText(TargetLabel, "Target: " .. LockedStage.MobName)
            SetProgressText(string.format("%s (%d/%d)", LockedStage.MobName, QuestCurrentCount, QuestRequiredCount))
            SetStatus(string.format("Quest verified! Target: %d %s", QuestRequiredCount, LockedStage.MobName))
            QuestState = "FARMING"
            return
        end

        if os.clock() >= QuestVerifyDeadline then
            if qStatus ~= "NO_GUI" then
                QuestUnknownDetectedAt = os.clock()
                QuestState = "UNKNOWN_QUEST"
            else
                SetStatus("Quest not active, retrying...")
                QuestState = "TAKING_QUEST"
            end
            return
        end

        SetStatus("Verifying quest active...")
        return
    end

    -- =========================================================================
    -- STATE 5: FARMING (Farm Validated Stage Mobs & Track Progress)
    -- =========================================================================
    if QuestState == "FARMING" then
        qStatus, matchedStage, curKills, reqKills = EvaluateQuestStatus(LockedStage)

        if qStatus == "NO_GUI" then
            CombatTarget = nil
            RestoreModifiedMobs()
            QuestCompletionStartedAt = os.clock()
            QuestState = "VERIFYING_COMPLETION"
            SetStatus("Verifying quest completion...")
            return
        end

        QuestCurrentCount = curKills or QuestCurrentCount
        if reqKills and reqKills > 0 then
            QuestRequiredCount = reqKills
        end
        SetProgressText(string.format("%s (%d/%d)", LockedStage.MobName, QuestCurrentCount, QuestRequiredCount))

        if not NavigateIslandTransition(LockedStage) or not CanContinue(stepEpoch) then
            return
        end

        char, hum, root = GetCharacter()
        if not root then return end

        EnableHaki(char)
        local weapon = EquipWeapon(char, hum)

        if not IsMobValid(CombatTarget, LockedStage.MobName) then
            CombatTarget = FindNearestMob(LockedStage.MobName, root)
        end

        if not CombatTarget then
            DiagState.LastAttackSkipReason = "WaitingMobSpawn"
            PatrolSpawnNodes(LockedStage)
            return
        end

        local inAttackRange = PositionAboveMob(LockedStage, CombatTarget, root)
        if inAttackRange then
            char, hum, root = GetCharacter()
            if char and hum and root then
                weapon = EquipWeapon(char, hum)
                if weapon then
                    -- Direct immediate attack trigger on arrival + background worker continuity
                    FireAttackOnce(char, root, weapon, LockedStage.MobName)
                    SetStatus(string.format("Lv %d | Farming %s (%d/%d)", level, LockedStage.MobName, QuestCurrentCount, QuestRequiredCount))
                else
                    SetStatus("Equip " .. Config.WeaponType .. " weapon!")
                end
            end
        end
        return
    end

    -- =========================================================================
    -- STATE 6: VERIFYING_COMPLETION (Multi-Check Completion Confirmation)
    -- =========================================================================
    if QuestState == "VERIFYING_COMPLETION" then
        CombatTarget = nil
        qStatus, _, curKills, _ = EvaluateQuestStatus(LockedStage)

        if qStatus ~= "NO_GUI" then
            QuestCurrentCount = curKills or QuestCurrentCount
            QuestState = "FARMING"
            return
        end

        if (os.clock() - QuestCompletionStartedAt) < Config.QuestCompleteDelay then
            SetProgressText(string.format("Completed! (%d/%d)", QuestRequiredCount, QuestRequiredCount))
            SetStatus("Quest finished! Preparing next...")
            return
        end

        LastRequestedStage = nil
        ResetQuestFSM()
        return
    end
end

-- ================= BACKGROUND SERVICES =================

local function StartBackgroundServices()
    RegisterGlobalConn(RunService.Stepped:Connect(function()
        if not CanContinue() then return end
        for i = 1, #CachedCharParts do
            local part = CachedCharParts[i]
            if part and part.Parent and part.CanCollide then
                part.CanCollide = false
            end
        end
    end))

    if HasSetHiddenProperty then
        RegisterGlobalConn(RunService.Heartbeat:Connect(function()
            if not CanContinue() then return end
            local now = os.clock()
            if now < NextSimRadiusAt then return end
            NextSimRadiusAt = now + 0.50
            pcall(function()
                sethiddenproperty(LP, "SimulationRadius", math.huge)
            end)
        end))
    end

    SpawnCombatWorker()
end

-- ================= GUI INTERACTION & IDEMPOTENT CLEANUP =================

RegisterGlobalConn(Toggle.MouseButton1Click:Connect(function()
    SetRunning(not Running)
end))

RegisterGlobalConn(FastAtkBtn.MouseButton1Click:Connect(function()
    Config.FastAttack = not Config.FastAttack
    SetLabelText(FastAtkBtn, Config.FastAttack and "Fast Attack: ON" or "Fast Attack: OFF")
    FastAtkBtn.BackgroundColor3 = Config.FastAttack
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
end))

RegisterGlobalConn(BringMobBtn.MouseButton1Click:Connect(function()
    Config.BringMob = not Config.BringMob
    SetLabelText(BringMobBtn, Config.BringMob and "Bring Mob: ON" or "Bring Mob: OFF")
    BringMobBtn.BackgroundColor3 = Config.BringMob
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
    if not Config.BringMob then
        RestoreModifiedMobs()
    end
end))

RegisterGlobalConn(AutoHakiBtn.MouseButton1Click:Connect(function()
    Config.AutoHaki = not Config.AutoHaki
    SetLabelText(AutoHakiBtn, Config.AutoHaki and "Auto Haki: ON" or "Auto Haki: OFF")
    AutoHakiBtn.BackgroundColor3 = Config.AutoHaki
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
end))

RegisterGlobalConn(AutoStatBtn.MouseButton1Click:Connect(function()
    Config.AutoStatsMelee = not Config.AutoStatsMelee
    SetLabelText(AutoStatBtn, Config.AutoStatsMelee and "Melee Stats: ON" or "Melee Stats: OFF")
    AutoStatBtn.BackgroundColor3 = Config.AutoStatsMelee
        and Color3.fromRGB(25, 135, 95)
        or Color3.fromRGB(80, 85, 105)
end))

RegisterGlobalConn(SpeedModeBtn.MouseButton1Click:Connect(function()
    Config.TweenSpeedIndex = (Config.TweenSpeedIndex % #Config.TweenSpeedPresets) + 1
    Config.TweenSpeed = Config.TweenSpeedPresets[Config.TweenSpeedIndex]
    SetLabelText(SpeedModeBtn, "Tween Speed: " .. tostring(Config.TweenSpeed))
end))

local dragging = false
local activeDragInput = nil
local dragStart = nil
local startPosition = nil

RegisterGlobalConn(Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then

        dragging = true
        activeDragInput = input
        dragStart = input.Position
        startPosition = Main.Position
    end
end))

RegisterGlobalConn(UIS.InputChanged:Connect(function(input)
    if dragging and dragStart and startPosition and (
        input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseMovement
    ) then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end))

RegisterGlobalConn(UIS.InputEnded:Connect(function(input)
    if input == activeDragInput
        or input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
        activeDragInput = nil
    end
end))

RegisterGlobalConn(LP.Idled:Connect(function()
    pcall(function()
        VU:CaptureController()
        VU:ClickButton2(Vector2.zero)
    end)
end))

env.BFAutoFarmStop = function()
    if IsStopped then return end
    IsStopped = true
    Alive = false
    Running = false
    IsRespawning = false
    CombatWorkerId += 1
    BumpEpoch()

    CombatTarget = nil
    CachedWeapon = nil
    IsAttacking = false

    CancelMovement("Shutdown")
    DisableStabilizer()
    RestoreCharacterCollisions()
    RestoreModifiedMobs()
    ClearCharConnections()

    for i = #GlobalConnections, 1, -1 do
        local conn = GlobalConnections[i]
        GlobalConnections[i] = nil
        pcall(function()
            conn:Disconnect()
        end)
    end

    table.clear(CachedCharParts)
    table.clear(SpawnNodesCache)

    if GUI then
        pcall(function()
            GUI:Destroy()
        end)
    end
end

-- ================= STRICT INITIALIZATION SEQUENCE =================

local function InitializeScript()
    if game.PlaceId ~= Config.FirstSeaPlaceId then
        SetRunning(false, "First Sea only (PlaceId 2753915549)")
        RecordError("Init", "Invalid PlaceId: " .. tostring(game.PlaceId))
        return false
    end

    local dbValid, dbErr = ValidateStageDatabase(Stages)
    if not dbValid then
        SetRunning(false, "Stage DB Error: " .. tostring(dbErr))
        RecordError("Database", dbErr)
        return false
    end

    if not LP.Character then
        LP.CharacterAdded:Wait()
    end

    local Remotes = RS:WaitForChild("Remotes", 30)
    CommF = Remotes and Remotes:WaitForChild("CommF_", 30)

    if not CommF then
        SetRunning(false, "Remote CommF_ unavailable")
        RecordError("Init", "CommF_ remote not found")
        return false
    end

    if not LP.Team then
        RemoteManager:Invoke("SetTeam", Config.Team)
    end

    local Data = LP:WaitForChild("Data", 30)
    local LevelValue = Data and Data:WaitForChild("Level", 30)

    if not LevelValue then
        SetRunning(false, "Level data unavailable")
        RecordError("Init", "Player Level data not found")
        return false
    end

    InitRespawnHandler()
    StartBackgroundServices()
    SetStatus("Ready")
    return true
end

if InitializeScript() then
    task.spawn(function()
        while Alive do
            task.wait(Config.MainLoopInterval)

            if Running then
                local ok, err = xpcall(Step, debug.traceback)
                if not ok then
                    SetStatus("Error - check Err Diag")
                    RecordError("Step", err)
                end
            end
        end
    end)
    print("[TineHub] TINE_HUB_FIRST_SEA_FIXED initialized successfully")
end
