-- // MAX-OBSERVABLE FORENSICS V18
-- // MAX-OBSERVABLE FORENSICS V17
-- // ========================================================================================
-- // ⚡ 4080 CUSTOM HUB v9.0 - SPECIALIST PRODUCTION FRAMEWORK
-- // Performance profile: shared target/animation state caches, throttled visual/cast steering
-- // Architecture: Modular Luau Service Architecture + IoC Container + FSM & Telemetry
-- // Pipeline: Automated CI/CD Verified Build
-- // ========================================================================================

local __modules = {}
local __cache = {}
local __loading = {}

local function require(modName)
    local normalized = modName:gsub("%.luau$", ""):gsub("%.lua$", ""):gsub("^src/", "")
    normalized = normalized:gsub("/", ".")
    
    if __cache[normalized] ~= nil then
        return __cache[normalized]
    end

    -- Exact or normalized match
    local modFunc = __modules[normalized] or __modules[modName] or __modules[normalized:gsub("%.", "/")]
    if not modFunc then
        for k, v in pairs(__modules) do
            if k:lower() == normalized:lower() or k:lower() == modName:lower() then
                modFunc = v
                normalized = k
                break
            end
        end
    end

    if not modFunc then
        error(string.format("[Bundler] Module '%s' not found!", tostring(modName)))
    end

    if __loading[normalized] then
        -- Circular require cycle guard: prevent infinite C-stack recursion
        if __cache[normalized] == nil then
            __cache[normalized] = {}
        end
        return __cache[normalized]
    end

    __loading[normalized] = true
    local exports = modFunc()
    __cache[normalized] = exports
    __loading[normalized] = nil

    return exports
end

-- ============================================================================
-- Module: Architecture.FeatureManager
-- ============================================================================
__modules["Architecture.FeatureManager"] = function()
--!strict
local Maid = require("Core.Maid")

export type Feature = {
    Name: string,
    Phase: string,
    Priority: number,
    Budget: number,
    Dependencies: { string },
    Enabled: boolean,
    Status: string, -- "INITIALIZED", "RUNNING", "STOPPED", "DEGRADED", "THROTTLED"
    DegradedReason: string?,
    OverBudgetCount: number,
    FailureCount: number,
    LastError: string?,
    Maid: any,
    Init: ((self: Feature, ctx: any) -> ())?,
    Start: ((self: Feature, ctx: any) -> ())?,
    Update: ((self: Feature, dt: number, ctx: any) -> ())?,
    Stop: ((self: Feature, ctx: any) -> ())?,
    Destroy: ((self: Feature) -> ())?,
}

local FeatureManager = {}
FeatureManager.__index = FeatureManager

function FeatureManager.new(logger: any, profiler: any)
    local self = setmetatable({
        _logger = logger,
        _profiler = profiler,
        _features = {},
        _renderPipeline = {},
        _steppedPipeline = {},
        _heartbeatPipeline = {},
    }, FeatureManager)
    return self
end

function FeatureManager:Register(def: any): Feature
    assert(type(def.Name) == "string", "Feature must have a unique Name")
    assert(self._features[def.Name] == nil, string.format("Feature '%s' is already registered", def.Name))
    local feat: Feature = {
        Name = def.Name,
        Phase = def.Phase or "Heartbeat",
        Priority = def.Priority or 50,
        Budget = def.Budget or 2.0, -- in ms
        Dependencies = def.Dependencies or {},
        Enabled = def.Enabled or false,
        Status = "INITIALIZED",
        DegradedReason = nil,
        OverBudgetCount = 0,
        FailureCount = 0,
        LastError = nil,
        Maid = Maid.new(),
        Init = def.Init,
        Start = def.Start,
        Update = def.Update,
        Stop = def.Stop,
        Destroy = def.Destroy,
    }

    self._features[feat.Name] = feat

    local list = self._heartbeatPipeline
    if feat.Phase == "RenderStepped" then list = self._renderPipeline
    elseif feat.Phase == "Stepped" then list = self._steppedPipeline end

    table.insert(list, feat)
    table.sort(list, function(a, b) return a.Priority > b.Priority end)
    return feat
end

function FeatureManager:ValidateDependencies(container: any): (boolean, { [string]: string })
    local report = {}
    local allValid = true

    for name, feat in pairs(self._features) do
        for _, dep in ipairs(feat.Dependencies) do
            if not container:Has(dep) and not self._features[dep] then
                local reason = string.format("Missing Required Dependency '%s'", dep)
                report[name] = reason
                feat.Status = "DEGRADED"
                feat.DegradedReason = reason
                feat.Enabled = false -- Isolate and prevent execution
                allValid = false
            end
        end
    end

    return allValid, report
end

function FeatureManager:InitAll(ctx: any)
    for name, feat in pairs(self._features) do
        if feat.Status == "DEGRADED" then
            self._logger:Warn("FeatureManager", string.format("Skipping Degraded Feature '%s': %s", name, tostring(feat.DegradedReason)))
            continue
        end

        if feat.Init then
            self._logger:SafeCall(name .. ".Init", feat.Init, feat, ctx)
        end

        if feat.Enabled then
            feat.Status = "RUNNING"
            if feat.Start then
                self._logger:SafeCall(name .. ".Start", feat.Start, feat, ctx)
            end
        end
    end
end

function FeatureManager:SetEnabled(name: string, enabled: boolean, ctx: any)
    local feat = self._features[name]
    if not feat or feat.Enabled == enabled then return end

    if feat.Status == "DEGRADED" and enabled then
        self._logger:Warn("FeatureManager", string.format("Cannot enable Degraded Feature '%s': %s", name, tostring(feat.DegradedReason)))
        return
    end

    feat.Enabled = enabled
    if enabled then
        feat.Status = "RUNNING"
        feat.FailureCount = 0
        feat.LastError = nil
        if feat.Start then
            local ok, err = self._logger:SafeCall(name .. ".Start", feat.Start, feat, ctx)
            if not ok then
                feat.FailureCount = 1
                feat.LastError = tostring(err)
                feat.Status = "DEGRADED"
                feat.Enabled = false
            end
        end
    else
        feat.Status = "STOPPED"
        if feat.Stop then
            self._logger:SafeCall(name .. ".Stop", feat.Stop, feat, ctx)
        end
        feat.Maid:DoCleaning()
    end
end

function FeatureManager:ExecutePipeline(phase: string, dt: number, ctx: any)
    local list = self._heartbeatPipeline
    if phase == "RenderStepped" then list = self._renderPipeline
    elseif phase == "Stepped" then list = self._steppedPipeline end

    for _, feat in ipairs(list) do
        if feat.Enabled and feat.Status ~= "DEGRADED" and feat.Update then
            local start = self._profiler and self._profiler:Begin(feat.Name, feat.Budget)
            local ok, err = self._logger:SafeCall(feat.Name .. ".Update", feat.Update, feat, dt, ctx)
            if self._profiler then
                self._profiler:End(feat.Name, start)
            end
            if ok then
                feat.FailureCount = 0
                feat.LastError = nil
            else
                feat.FailureCount += 1
                feat.LastError = tostring(err)
                if feat.FailureCount >= 3 then
                    feat.Enabled = false
                    feat.Status = "DEGRADED"
                    feat.DegradedReason = "Repeated runtime failure: " .. tostring(err)
                    pcall(function() if feat.Stop then feat.Stop(feat, ctx) end end)
                    feat.Maid:DoCleaning()
                    self._logger:Warn("FeatureManager", string.format("Feature '%s' disabled after %d consecutive failures.", feat.Name, feat.FailureCount))
                end
            end
        end
    end
end

function FeatureManager:DestroyAll()
    for _, feat in pairs(self._features) do
        local wasEnabled = feat.Enabled
        if wasEnabled and feat.Stop then
            self._logger:SafeCall(feat.Name .. ".Stop", feat.Stop, feat)
        end
        feat.Enabled = false
        feat.Status = "STOPPED"
        feat.Maid:DoCleaning()
        if feat.Destroy then
            pcall(feat.Destroy, feat)
        end
    end
    table.clear(self._features)
    table.clear(self._renderPipeline)
    table.clear(self._steppedPipeline)
    table.clear(self._heartbeatPipeline)
end

function FeatureManager:GetFeature(name: string): Feature?
    return self._features[name]
end

function FeatureManager:GetFeatureStates(): { [string]: { Enabled: boolean, Status: string, Budget: number, Priority: number, OverBudgetCount: number } }
    local states = {}
    for name, feat in pairs(self._features) do
        states[name] = {
            Enabled = feat.Enabled,
            Status = feat.Status,
            Budget = feat.Budget,
            Priority = feat.Priority,
            OverBudgetCount = feat.OverBudgetCount,
            FailureCount = feat.FailureCount,
            LastError = feat.LastError,
        }
    end
    return states
end

return FeatureManager

end
__modules["Architecture/FeatureManager"] = __modules["Architecture.FeatureManager"]

-- ============================================================================
-- Module: Architecture.StateMachine
-- ============================================================================
__modules["Architecture.StateMachine"] = function()
--!strict
local Signal = require("Core.Signal")

export type StateDefinition = {
    Priority: number?,
    Timeout: number?, -- Max duration in seconds before auto-recovering to fallback
    FallbackState: string?,
    OnEnter: ((self: any, prevState: string, ctx: any, reason: string?) -> ())?,
    OnUpdate: ((self: any, dt: number, ctx: any) -> ())?,
    OnExit: ((self: any, nextState: string, ctx: any) -> ())?,
    CanEnter: ((self: any, ctx: any) -> boolean)?,
    CanExit: ((self: any, ctx: any) -> boolean)?,
}

export type TransitionTelemetry = {
    From: string,
    To: string,
    Reason: string,
    Source: string,
    Timestamp: number,
    DurationInPrev: number,
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState: string?, logger: any?)
    local self = setmetatable({
        CurrentState = initialState or "IDLE",
        PreviousState = "NONE",
        StateStartTime = os.clock(),
        TransitionsCount = 0,
        History = {},
        TelemetryLogs = {}, -- Structured Transition Telemetry
        MaxTelemetryLogs = 50,
        StateChanged = Signal.new(),
        _logger = logger,
        _states = {},
        _transitions = {},
        _priorities = {
            EMERGENCY_STOP = 100,
            SKY_ESCAPE     = 90,
            SKY_DODGE      = 80,
            VOID_KILL      = 70,
            MASS_BRING     = 60,
            BEHIND_TP      = 50,
            COMBAT         = 30,
            IDLE           = 0,
        },
    }, StateMachine)

    self:RegisterDefaultTransitions()
    return self
end

function StateMachine:RegisterState(name: string, def: StateDefinition)
    self._states[name] = def
    if def.Priority then
        self._priorities[name] = def.Priority
    end
end

function StateMachine:RegisterTransition(fromState: string | { string }, toState: string, condition: ((ctx: any) -> boolean)?)
    local fromList = type(fromState) == "table" and fromState or { fromState }
    for _, f in ipairs(fromList) do
        local key = f .. "->" .. toState
        self._transitions[key] = {
            From = f,
            To = toState,
            Condition = condition,
        }
    end
end

function StateMachine:RegisterDefaultTransitions()
    -- Explicit Strict Whitelist Transitions Graph
    self:RegisterTransition("IDLE", "COMBAT")
    self:RegisterTransition("IDLE", "BEHIND_TP")
    self:RegisterTransition("IDLE", "MASS_BRING")
    self:RegisterTransition("IDLE", "VOID_KILL")
    self:RegisterTransition("IDLE", "SKY_DODGE")
    self:RegisterTransition("IDLE", "SKY_ESCAPE")
    self:RegisterTransition("IDLE", "EMERGENCY_STOP")

    self:RegisterTransition("COMBAT", "IDLE")
    self:RegisterTransition("COMBAT", "BEHIND_TP")
    self:RegisterTransition("COMBAT", "MASS_BRING")
    self:RegisterTransition("COMBAT", "VOID_KILL")
    self:RegisterTransition("COMBAT", "SKY_DODGE")
    self:RegisterTransition("COMBAT", "SKY_ESCAPE")
    self:RegisterTransition("COMBAT", "EMERGENCY_STOP")

    self:RegisterTransition("BEHIND_TP", "IDLE")
    self:RegisterTransition("BEHIND_TP", "COMBAT")
    self:RegisterTransition("BEHIND_TP", "SKY_DODGE")
    self:RegisterTransition("BEHIND_TP", "SKY_ESCAPE")
    self:RegisterTransition("BEHIND_TP", "EMERGENCY_STOP")

    self:RegisterTransition("MASS_BRING", "IDLE")
    self:RegisterTransition("MASS_BRING", "COMBAT")
    self:RegisterTransition("MASS_BRING", "EMERGENCY_STOP")

    self:RegisterTransition("VOID_KILL", "IDLE")
    self:RegisterTransition("VOID_KILL", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_DODGE", "IDLE")
    self:RegisterTransition("SKY_DODGE", "COMBAT")
    self:RegisterTransition("SKY_DODGE", "EMERGENCY_STOP")

    self:RegisterTransition("SKY_ESCAPE", "IDLE")
    self:RegisterTransition("SKY_ESCAPE", "EMERGENCY_STOP")

    self:RegisterTransition("EMERGENCY_STOP", "IDLE")

    -- Built-in state definitions keep the FSM update/timeout layer functional.
    self:RegisterState("IDLE", { Priority = 0 })
    self:RegisterState("COMBAT", { Priority = 30 })
    self:RegisterState("BEHIND_TP", { Priority = 50 })
    self:RegisterState("MASS_BRING", { Priority = 60, Timeout = 30, FallbackState = "IDLE" })
    self:RegisterState("VOID_KILL", { Priority = 70, Timeout = 5, FallbackState = "IDLE" })
    self:RegisterState("SKY_DODGE", { Priority = 80, Timeout = 2, FallbackState = "IDLE" })
    self:RegisterState("SKY_ESCAPE", { Priority = 90, Timeout = 20, FallbackState = "IDLE" })
    self:RegisterState("EMERGENCY_STOP", { Priority = 100, Timeout = 3, FallbackState = "IDLE" })
end

function StateMachine:CanTransitionTo(targetState: string, ctx: any): boolean
    if self.CurrentState == targetState then return false end

    if targetState == "EMERGENCY_STOP" then return true end
    if self.CurrentState == "EMERGENCY_STOP" and targetState ~= "IDLE" then return false end

    local transKey = self.CurrentState .. "->" .. targetState
    local transRule = self._transitions[transKey]
    if not transRule then
        return false -- Whitelist guard
    end

    if transRule.Condition and not transRule.Condition(ctx) then
        return false
    end

    local currentDef = self._states[self.CurrentState]
    if currentDef and currentDef.CanExit and not currentDef:CanExit(ctx) then
        return false
    end

    local targetDef = self._states[targetState]
    if targetDef and targetDef.CanEnter and not targetDef:CanEnter(ctx) then
        return false
    end

    return true
end

function StateMachine:TransitionTo(newState: string, ctx: any, reason: string?, source: string?, force: boolean?): boolean
    if self.CurrentState == newState then
        return false
    end
    if self._states[newState] == nil and self._priorities[newState] == nil then
        if self._logger then
            self._logger:Warn("FSM", string.format("Rejected transition to unknown state '%s'", tostring(newState)))
        end
        return false
    end
    if not force and not self:CanTransitionTo(newState, ctx) then
        return false
    end

    local now = os.clock()
    local oldState = self.CurrentState
    local durationInPrev = now - self.StateStartTime

    local oldDef = self._states[oldState]
    if oldDef and oldDef.OnExit then
        if self._logger then
            self._logger:SafeCall("FSM.OnExit", oldDef.OnExit, oldDef, newState, ctx)
        else
            pcall(oldDef.OnExit, oldDef, newState, ctx)
        end
    end

    table.insert(self.History, 1, oldState)
    if #self.History > 20 then table.remove(self.History) end

    -- Record Structured Telemetry Entry
    local telemetry: TransitionTelemetry = {
        From = oldState,
        To = newState,
        Reason = reason or "Standard Transition",
        Source = source or "Engine",
        Timestamp = now,
        DurationInPrev = durationInPrev,
    }
    table.insert(self.TelemetryLogs, 1, telemetry)
    if #self.TelemetryLogs > self.MaxTelemetryLogs then
        table.remove(self.TelemetryLogs)
    end

    self.PreviousState = oldState
    self.CurrentState = newState
    self.StateStartTime = now
    self.TransitionsCount += 1

    local newDef = self._states[newState]
    if newDef and newDef.OnEnter then
        if self._logger then
            self._logger:SafeCall("FSM.OnEnter", newDef.OnEnter, newDef, oldState, ctx, reason)
        else
            pcall(newDef.OnEnter, newDef, oldState, ctx, reason)
        end
    end

    self.StateChanged:Fire(newState, oldState, telemetry)
    return true
end

function StateMachine:Rollback(ctx: any): boolean
    if #self.History > 0 then
        local prev = table.remove(self.History, 1)
        return self:TransitionTo(prev, ctx, "FSM Rollback", "FSM", true)
    end
    return false
end

function StateMachine:Update(dt: number, ctx: any)
    local def = self._states[self.CurrentState]
    if def then
        -- Timeout Auto-Recovery Guard (Prevents getting permanently stuck in transient special states)
        if def.Timeout and (os.clock() - self.StateStartTime) > def.Timeout then
            local fallback = def.FallbackState or "IDLE"
            if self._logger then
                self._logger:Warn("FSM", string.format("State '%s' timed out (> %.1fs), auto-recovering to '%s'", self.CurrentState, def.Timeout, fallback))
            end
            self:TransitionTo(fallback, ctx, "State Timeout Recovery", "FSM", true)
            return
        end

        if def.OnUpdate then
            if self._logger then
                self._logger:SafeCall("FSM.OnUpdate", def.OnUpdate, def, dt, ctx)
            else
                pcall(def.OnUpdate, def, dt, ctx)
            end
        end
    end
end

return StateMachine

end
__modules["Architecture/StateMachine"] = __modules["Architecture.StateMachine"]

-- ============================================================================
-- Module: Bootstrap
-- ============================================================================
__modules["Bootstrap"] = function()
--!strict
local ServiceContainer = require("Core.ServiceContainer")
local Signal = require("Core.Signal")
local EventBus = require("Core.EventBus")
local Logger = require("Core.Logger")
local Maid = require("Core.Maid")
local Scheduler = require("Core.Scheduler")
local StateMachine = require("Architecture.StateMachine")
local FeatureManager = require("Architecture.FeatureManager")
local Profiler = require("Performance.Profiler")
local CacheEngine = require("Performance.Cache")
local ObjectPool = require("Performance.ObjectPool")
local ConfigManager = require("Config.ConfigManager")
local NetworkEngine = require("Network.NetworkEngine")
local RemoteResolver = require("Network.RemoteResolver")
local Combat = require("Systems.Combat")
local Movement = require("Systems.Movement")
local Survival = require("Systems.Survival")
local Skills = require("Systems.Skills")
local World = require("Systems.World")
local Visuals = require("Systems.Visuals")
local EnemyState = require("Systems.EnemyState")
local TelemetryRecorder = require("Systems.TelemetryRecorder")
local UnitTests = require("Diagnostics.UnitTests")
local SelfDiagnostics = require("Diagnostics.SelfDiagnostics")
local UIController = require("UI.UIController")
local TeleportManager = require("Systems.TeleportManager")

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Bootstrap = {
    _maid = nil :: any,
    _isInitialized = false,
    Container = nil :: any,
    _isBooting = false,
}

function Bootstrap:_InitInternal()
    if self._isInitialized then
        -- Prevent Duplicate Loops: Destroy previous instance symmetrically
        self:Destroy()
    end

    self._maid = Maid.new()
    self._isInitialized = false

    local logger = Logger.new(3)
    logger:Info("Bootstrap", "=== 4080 HUB v9.0 PRODUCTION SPECIALIST FRAMEWORK BOOTING ===")

    -- 1. Create Core Instances (Instance-based OOP Architecture)
    local container = ServiceContainer.new()
    self.Container = container
    local eventBus = EventBus.new()
    local scheduler = Scheduler.new()
    local profiler = Profiler.new()
    local cache = CacheEngine.new(0.08)
    local fsm = StateMachine.new("IDLE", logger)
    local featureManager = FeatureManager.new(logger, profiler)
    local configManager = ConfigManager.new(logger)
    local diagnostics = SelfDiagnostics.new(logger)

    -- 2. Register Core Singletons into IoC Container
    container:Register("Logger", logger, {})
    container:Register("EventBus", eventBus, { "Logger" })
    container:Register("Scheduler", scheduler, { "Logger" })
    container:Register("Profiler", profiler, {})
    container:Register("Cache", cache, {})
    container:Register("StateMachine", fsm, { "Logger" })
    container:Register("FeatureManager", featureManager, { "Logger", "Profiler" })
    container:Register("ConfigManager", configManager, { "Logger" })
    container:Register("Diagnostics", diagnostics, { "Logger" })
    container:Register("ObjectPool", ObjectPool, {})

    -- 3. Register Systems via True Constructor Dependency Injection with Explicit DAG Dependencies
    container:Register("RemoteResolver", function(c)
        return RemoteResolver.new(c:Get("Logger"))
    end, { "Logger" })

    container:Register("NetworkEngine", function(c)
        return NetworkEngine.new({
            Logger = c:Get("Logger"),
            EventBus = c:Get("EventBus"),
            RemoteResolver = c:Get("RemoteResolver"),
        })
    end, { "Logger", "EventBus", "RemoteResolver" })

    container:Register("EnemyState", function(c)
        return EnemyState.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "EventBus", "Logger" })

    container:Register("Combat", function(c)
        return Combat.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Network = c:Get("NetworkEngine"),
            EnemyState = c:Get("EnemyState"),
            Logger = c:Get("Logger"),
            StateMachine = c:Get("StateMachine"),
        })
    end, { "Cache", "EventBus", "NetworkEngine", "EnemyState", "Logger", "StateMachine" })

    container:Register("Movement", function(c)
        return Movement.new({
            Cache = c:Get("Cache"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "Logger" })

    container:Register("Survival", function(c)
        return Survival.new({
            Cache = c:Get("Cache"),
            StateMachine = c:Get("StateMachine"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "StateMachine", "EventBus", "Logger" })

    container:Register("Skills", function(c)
        return Skills.new({
            Cache = c:Get("Cache"),
            Combat = c:Get("Combat"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "Combat", "Logger" })

    container:Register("World", function(c)
        return World.new({
            ConfigManager = c:Get("ConfigManager"),
            Logger = c:Get("Logger"),
        })
    end, { "ConfigManager", "Logger" })

    container:Register("TeleportManager", function(c)
        return TeleportManager.new({
            ConfigManager = c:Get("ConfigManager"),
            Movement = c:Get("Movement"),
            Logger = c:Get("Logger"),
        })
    end, { "ConfigManager", "Movement", "Logger" })

    container:Register("Visuals", function(c)
        return Visuals.new({
            Cache = c:Get("Cache"),
            ObjectPool = ObjectPool,
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "ObjectPool", "Logger" })

    container:Register("TelemetryRecorder", function(c)
        return TelemetryRecorder.new({
            Cache = c:Get("Cache"),
            EventBus = c:Get("EventBus"),
            Logger = c:Get("Logger"),
        })
    end, { "Cache", "EventBus", "Logger" })

    local this = self
    container:Register("UIController", function(c)
        return UIController.new({
            ConfigManager = c:Get("ConfigManager"),
            FeatureManager = c:Get("FeatureManager"),
            StateMachine = c:Get("StateMachine"),
            Profiler = c:Get("Profiler"),
            Cache = c:Get("Cache"),
            NetworkEngine = c:Get("NetworkEngine"),
            Logger = c:Get("Logger"),
            Bootstrap = this,
            Container = c,
        })
    end, { "ConfigManager", "FeatureManager", "StateMachine", "Profiler", "Cache", "NetworkEngine", "Logger" })

    -- 4. Run Diagnostics Health Check
    pcall(function() diagnostics:RunHealthCheck() end)

    -- 5. Topological DAG Resolution of All Systems
    local initOrder = container:ResolveAllInOrder()
    logger:Info("Bootstrap", string.format("DAG Resolution Complete. Initialized %d services in topological order.", #initOrder))

    local network = container:Get("NetworkEngine")

    -- Event-Driven Cache Invalidation connected to Root Maid
    cache:HookWorkspaceEvents(self._maid)

    local combat = container:Get("Combat")
    local movement = container:Get("Movement")
    local survival = container:Get("Survival")
    local skills = container:Get("Skills")
    local world = container:Get("World")
    local visuals = container:Get("Visuals")
    local enemyState = container:Get("EnemyState")
    local telemetryRecorder = container:Get("TelemetryRecorder")
    self._maid:GiveTask(function() telemetryRecorder:Destroy() end)
    self._maid:GiveTask(function() movement:Destroy() end)
    self._maid:GiveTask(function() survival:Destroy() end)
    self._maid:GiveTask(function() visuals:Destroy() end)
    self._maid:GiveTask(function() world:Destroy() end)


    -- 6. Load Config
    configManager:Load()
    pcall(function() telemetryRecorder:LoadFromDisk() end)
    pcall(function() telemetryRecorder:InitHooks() end)

    -- Initialize Combat lifecycle
    combat:InitLifecycle(self._maid, configManager)

    -- Single Perform Auto Tech Keybind listener (KittyWare line 2172)
    local singlePerformConn = game:GetService("UserInputService").InputBegan:Connect(function(input, gpe)
        if gpe then return end
        local cfg = configManager.Config
        if not cfg or not cfg.Keybinds or not cfg.Combat then return end
        local bind = cfg.Keybinds.SinglePerformKey
        if bind and input.KeyCode == bind then
            cfg.Combat.AutoTechPerformOnce = true
            if cfg.Combat.AutoTechNotifications then
                eventBus:Publish("UI.Notification", "Auto Tech", "Single Perform Armed for next hit!", "Success", 2)
            end
        end
    end)
    self._maid:GiveTask(singlePerformConn)

    -- Remote observation hook is opt-in and only enabled while telemetry recording requires it.
    network:Init(configManager.Config)
    self._maid:GiveTask(function() network:Destroy() end)

    -- Wire jump features after config is loaded (event-driven, respawn-safe)
    movement:ToggleJumpFeatures(configManager.Config)
    -- Re-wire if config toggles change jump settings via UI (config reference is shared, so
    -- the toggle callbacks set config.Movement.InfiniteJump directly. We also
    -- wire it once here so any persisted config is applied on boot.)

    -- 7. Active Scheduler Tasks Registration (Tiered Frequencies)

    scheduler:Register("EnemyState_Normal", "Normal", function(dt)
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= Players.LocalPlayer then
                enemyState:Update(p)
            end
        end
    end)

    scheduler:Register("WorldHop_Slow", "Slow", function(dt)
        world:CheckAutoServerHop(configManager.Config)
    end)

    -- World environment features (FullBright, Fog, CustomFOV) — 2Hz sync
    scheduler:Register("WorldEnv_Slow", "Slow", function(dt)
        local cfg = configManager.Config
        if cfg.World then
            world:ToggleFullBright(cfg.World.FullBright or false)
            world:ToggleRemoveFog(cfg.World.RemoveFog or false)
            world:ToggleCustomFOV(cfg.World.CustomFOV == true, cfg.World.FOVValue)
        end
    end)

    -- AntiAFK: VirtualUser simulation — throttled to once per 60 seconds max
    local lastAntiAFKTick = 0
    scheduler:Register("AntiAFK_Background", "Background", function(dt)
        local cfg = configManager.Config
        if cfg.World and cfg.World.AntiAFK then
            local now = os.clock()
            if (now - lastAntiAFKTick) >= 60 then
                lastAntiAFKTick = now
                pcall(function()
                    local vu = game:GetService("VirtualUser")
                    if vu then vu:CaptureController() vu:ClickButton2(Vector2.new()) end
                end)
            end
        end
    end)

    scheduler:Register("Telemetry_Slow", "Slow", function(dt)
        profiler:UpdateSystemMetrics()
    end)

    scheduler:Register("CombatTelemetry_Background", "Background", function(dt)
        telemetryRecorder:Update(dt, configManager.Config)
    end)

    scheduler:Register("ConfigAutosave_Background", "Background", function(dt)
        local cfg = configManager.Config
        if cfg and cfg.UI and cfg.UI.AutoSave ~= false then
            configManager:Save()
        end
    end)

    -- 8. Register and Validate Feature Pipelines
    featureManager:Register({
        Name = "FlyMovement",
        Phase = "RenderStepped",
        Priority = 90,
        Budget = 1.0,
        Dependencies = { "Movement", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx) movement:UpdateFly(dt, configManager.Config) end
    })

    featureManager:Register({
        Name = "CombatEngine",
        Phase = "Heartbeat",
        Priority = 100,
        Budget = 2.0,
        Dependencies = { "Combat", "Cache", "EnemyState" },
        Enabled = true,
        Update = function(self, dt, ctx)
            movement:UpdateBehindLock(dt, configManager.Config, combat)
        end
    })

    featureManager:Register({
        Name = "MovementEngine",
        Phase = "Heartbeat",
        Priority = 90,
        Budget = 1.0,
        Dependencies = { "Movement", "Combat" },
        Enabled = true,
        Update = function(self, dt, ctx)
            movement:UpdateSpeed(dt, configManager.Config)
            movement:UpdateAntiVoid(configManager.Config)
        end
    })

    featureManager:Register({
        Name = "SkillsEngine",
        Phase = "Heartbeat",
        Priority = 80,
        Budget = 1.0,
        Dependencies = { "Skills", "Combat", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx)
            skills:UpdateSkillTracking(configManager.Config)
            skills:UpdateAutoSkillSpam(configManager.Config)
            skills:UpdateVoidKill(configManager.Config)
        end,
        Destroy = function()
            skills:Destroy()
        end
    })

    featureManager:Register({
        Name = "SurvivalEngine",
        Phase = "Heartbeat",
        Priority = 85,
        Budget = 1.5,
        Dependencies = { "Survival", "StateMachine" },
        Enabled = true,
        Update = function(self, dt, ctx)
            survival:UpdateSkyDodge(dt, configManager.Config)
            survival:CheckSkyEscape(configManager.Config)
        end
    })

    featureManager:Register({
        Name = "VisualsEngine",
        Phase = "Heartbeat",
        Priority = 70,
        Budget = 2.0,
        Dependencies = { "Visuals", "Cache" },
        Enabled = true,
        Update = function(self, dt, ctx)
            visuals:Update(configManager.Config)
        end
    })

    -- Validate all feature dependencies in DI container
    local depsOk, depReport = featureManager:ValidateDependencies(container)
    logger:Info("Bootstrap", string.format("Feature Dependency Graph: %s", depsOk and "ALL SATISFIED" or "DEGRADED ISOLATION ACTIVE"))

    featureManager:InitAll(container)
    self._maid:GiveTask(function() featureManager:DestroyAll() end)

    -- 9. Connect Game Loop Pipelines & Store Connections in Root Maid
    local rsConn = RunService.RenderStepped:Connect(function(dt)
        featureManager:ExecutePipeline("RenderStepped", dt, container)
    end)
    self._maid:GiveTask(rsConn)

    local stConn = RunService.Stepped:Connect(function()
        movement:UpdateNoclip(configManager.Config)
        featureManager:ExecutePipeline("Stepped", 1/60, container)
    end)
    self._maid:GiveTask(stConn)

    local hbConn = RunService.Heartbeat:Connect(function(dt)
        fsm:Update(dt, container)
        scheduler:Step(dt)
        featureManager:ExecutePipeline("Heartbeat", dt, container)
    end)
    self._maid:GiveTask(hbConn)

    -- 10. Initialize GUI Presentation Layer
    local okUI, uiOrErr = pcall(function()
        local uiController = container:Get("UIController")
        uiController:Init()
        self.UIController = uiController
        self._maid:GiveTask(function()
            uiController:Destroy()
            self.UIController = nil
        end)
    end)
    if not okUI then
        logger:Warn("Bootstrap", string.format("GUI Initialization warning: %s", tostring(uiOrErr)))
    end

    self._isInitialized = true
    logger:Info("Bootstrap", "=== 4080 HUB FRAMEWORK FULLY OPERATIONAL (SPECIALIST PRODUCTION ARCHITECTURE) ===")
end

function Bootstrap:Init()
    if self._isBooting then return false end
    self._isBooting = true
    local ok, err = xpcall(function() self:_InitInternal() end, debug.traceback)
    self._isBooting = false
    if not ok then
        self:Destroy()
        error(err, 0)
    end
    return true
end

function Bootstrap:Destroy()
    if self._maid then
        self._maid:DoCleaning()
        self._maid = nil
    end
    self.UIController = nil
    self._isInitialized = false
end

function Bootstrap:GetDiagnostics(): { [string]: any }
    if not self._isInitialized or not self.Container then
        return { Status = "Uninitialized", Initialized = false }
    end

    local profiler = self.Container:Get("Profiler")
    local fsm = self.Container:Get("StateMachine")
    local featureManager = self.Container:Get("FeatureManager")
    local cache = self.Container:Get("Cache")
    local network = self.Container:Get("NetworkEngine")
    local telemetry = self.Container:Has("TelemetryRecorder") and self.Container:Get("TelemetryRecorder") or nil

    return {
        Status = "Operational",
        Initialized = true,
        CurrentState = fsm and fsm.CurrentState or "UNKNOWN",
        StateHistory = fsm and fsm.TelemetryLogs or {},
        FeatureStates = featureManager and featureManager:GetFeatureStates() or {},
        Network = {
            IsHooked = network and network._isHooked or false,
            PacketCount = network and network.PacketCount or 0,
            LastGoal = network and network.LastGoal or nil,
        },
        CacheStats = {
            Player = cache and cache.PlayerStats or {},
            Raycast = cache and cache.RaycastStats or {},
        },
        Telemetry = telemetry and telemetry:GetStats() or {},
        ProfilerReport = profiler and profiler:GetReport() or {},
    }
end

return Bootstrap

end

-- ============================================================================
-- Module: Config.ConfigManager
-- ============================================================================
__modules["Config.ConfigManager"] = function()
--!strict
local ConfigSchema = require("Config.ConfigSchema")
local HttpService = game:GetService("HttpService")

local ConfigManager = {}
ConfigManager.__index = ConfigManager

function ConfigManager.new(logger: any)
    local self = setmetatable({
        FileName = "4080_Hub_TSB_Config.json",
        Config = {},
        RegisteredUI = {},
        _logger = logger,
        _degradedMode = false,
        _lastSerialized = nil :: string?,
    }, ConfigManager)

    self:ResetToDefaults()

    if typeof(writefile) ~= "function" or typeof(readfile) ~= "function" then
        self._degradedMode = true
        if self._logger then
            self._logger:Warn("ConfigManager", "Running in In-Memory Degraded Mode (writefile API unsupported)")
        end
    end

    return self
end

function ConfigManager:ResetToDefaults()
    for catName, catSchema in pairs(ConfigSchema) do
        self.Config[catName] = {}
        for key, spec in pairs(catSchema) do
            self.Config[catName][key] = spec.Default
        end
    end
end

function ConfigManager:ValidateAndClamp(data: any): any
    -- Strict Runtime Schema Enforcement with EnumItem type validation
    for catName, catSchema in pairs(ConfigSchema) do
        if type(data[catName]) == "table" then
            for key, spec in pairs(catSchema) do
                local val = data[catName][key]
                if val ~= nil then
                    if spec.Type == "number" then
                        if type(val) == "number" then
                            if spec.Min and spec.Max then
                                data[catName][key] = math.clamp(val, spec.Min, spec.Max)
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "boolean" then
                        if type(val) ~= "boolean" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "string" then
                        if type(val) ~= "string" then
                            data[catName][key] = spec.Default
                        end
                    elseif spec.Type == "EnumItem" then
                        if typeof(val) == "EnumItem" then
                            if spec.EnumType and val.EnumType ~= spec.EnumType then
                                data[catName][key] = spec.Default
                            end
                        else
                            data[catName][key] = spec.Default
                        end
                    end
                else
                    data[catName][key] = spec.Default
                end
            end
        else
            data[catName] = {}
            for key, spec in pairs(catSchema) do
                data[catName][key] = spec.Default
            end
        end
    end

    -- Runtime-safe enum-like normalization for string modes. Never silently fall back
    -- to Nearest just because a saved value came from an older build.
    if data.Target and type(data.Target.TargetMode) == "string" then
        local valid = {
            ["Nearest"] = true, ["Lowest HP"] = true,
            ["Random"] = true, ["Specific Player"] = true,
        }
        if not valid[data.Target.TargetMode] then
            data.Target.TargetMode = "Nearest"
        end
    end

    return data
end

function ConfigManager:Commit()
    self._isDirty = true
    if self.Config.UI and self.Config.UI.AutoSave ~= false then
        self:Save()
    end
end

local function SerializeValue(val: any): any
    if typeof(val) == "Color3" then
        return { __type = "Color3", R = val.R, G = val.G, B = val.B }
    elseif typeof(val) == "EnumItem" then
        return { __type = "EnumItem", EnumType = tostring(val.EnumType), Name = val.Name }
    elseif type(val) == "table" then
        local t = {}
        for k, v in pairs(val) do t[tostring(k)] = SerializeValue(v) end
        return t
    else
        return val
    end
end

local function DeserializeValue(val: any): any
    if type(val) == "table" then
        if val.__type == "Color3" then
            return Color3.new(val.R or 0, val.G or 0, val.B or 0)
        elseif val.__type == "EnumItem" then
            local enumTypeStr = val.EnumType or ""
            local enumName = val.Name or ""
            if enumTypeStr:find("KeyCode") and Enum.KeyCode[enumName] then
                return Enum.KeyCode[enumName]
            elseif enumTypeStr:find("UserInputType") and Enum.UserInputType[enumName] then
                return Enum.UserInputType[enumName]
            end
            return val
        else
            local t = {}
            for k, v in pairs(val) do t[k] = DeserializeValue(v) end
            return t
        end
    else
        return val
    end
end

function ConfigManager:Save(force: boolean?): (boolean, string?)
    if self._degradedMode then
        return true, "In-Memory"
    end

    self:ValidateAndClamp(self.Config)

    local dataToSave = {}
    for cat, val in pairs(self.Config) do
        dataToSave[cat] = SerializeValue(val)
    end

    local okEncode, jsonOrErr = pcall(function()
        return HttpService:JSONEncode(dataToSave)
    end)
    if not okEncode then
        return false, tostring(jsonOrErr)
    end

    local json = jsonOrErr :: string
    if not force and self._lastSerialized == json then
        return true, "Clean"
    end

    local ok, err = pcall(function()
        writefile(self.FileName, json)
    end)
    if ok then
        self._lastSerialized = json
        self._isDirty = false
        if self._logger then
            self._logger:Info("Config", "Saved validated config to disk.")
        end
    end
    return ok, err
end

function ConfigManager:Load(): (boolean, string?)
    if self._degradedMode or typeof(isfile) ~= "function" or not isfile(self.FileName) then
        return false, "Config file not found or degraded"
    end
    local ok, err = pcall(function()
        local raw = readfile(self.FileName)
        local rawData = HttpService:JSONDecode(raw)
        local decoded = DeserializeValue(rawData)
        self:ValidateAndClamp(decoded)
        for catName, catData in pairs(decoded) do
            if type(self.Config[catName]) == "table" and type(catData) == "table" then
                for k, v in pairs(catData) do
                    if self.Config[catName][k] ~= nil then
                        self.Config[catName][k] = v
                    end
                end
            else
                self.Config[catName] = catData
            end
        end
        self._lastSerialized = HttpService:JSONEncode(self:SerializeConfigForSnapshot())
        self._isDirty = false
        self:RefreshUI()
    end)
    if ok and self._logger then self._logger:Info("Config", "Loaded and validated config from disk.") end
    return ok, err
end

function ConfigManager:SerializeConfigForSnapshot(): any
    local snapshot = {}
    for cat, val in pairs(self.Config) do
        snapshot[cat] = SerializeValue(val)
    end
    return snapshot
end

function ConfigManager:RefreshUI()
    for _, item in ipairs(self.RegisteredUI) do
        if item.Getter and item.Setter then
            pcall(function()
                local val = item.Getter()
                if val ~= nil then item.Setter(val) end
            end)
        end
    end
end

function ConfigManager:Reset()
    if typeof(delfile) == "function" and typeof(isfile) == "function" and isfile(self.FileName) then
        pcall(function() delfile(self.FileName) end)
    end
    self:ResetToDefaults()
    self._lastSerialized = nil
    self._isDirty = true
    self:RefreshUI()
end

return ConfigManager

end
__modules["Config/ConfigManager"] = __modules["Config.ConfigManager"]

-- ============================================================================
-- Module: Config.ConfigSchema
-- ============================================================================
__modules["Config.ConfigSchema"] = function()
--!strict
local ConfigSchema = {
    Combat = {
        -- Targeting / aim state (referenced by Skills + UI)
        Aimlock               = { Type = "boolean", Default = false },
        AimlockMode           = { Type = "string",  Default = "Body Only (No Screen Spin)" },
        PredictiveAim         = { Type = "boolean", Default = true },

        -- Auto Tech Core (KittyWare 1:1 Architecture)
        AutoTechEnabled        = { Type = "boolean", Default = false },
        AutoTechVariant        = { Type = "string",  Default = "Loop Dash" },
        AutoTechMethod         = { Type = "string",  Default = "Perform Always" },
        AutoTechPerformOnce    = { Type = "boolean", Default = false },
        AutoTechNotifications  = { Type = "boolean", Default = true },
        AutoTechDelay          = { Type = "number",  Default = 0.38, Min = 0.15, Max = 0.65 },
        AutoTechAutoM1         = { Type = "boolean", Default = false },

        -- Auto Tech Settings (KittyWare TechSettings)
        Loopv2Precision        = { Type = "number",  Default = 35, Min = 0, Max = 100 },
        Loopv2FirstFlick       = { Type = "number",  Default = 0, Min = -360, Max = 360 },
        Loopv2SecondFlick      = { Type = "number",  Default = 5, Min = 0, Max = 50 },
        Loopv2Jump             = { Type = "boolean", Default = false },
        Loopv2RotateCam        = { Type = "boolean", Default = false },
        LockonPrecision        = { Type = "number",  Default = 100, Min = 0, Max = 100 },
        SupaMethod             = { Type = "string",  Default = "RenderStepped" },
        LoopDashLooksUp        = { Type = "boolean", Default = false },

        -- Custom Dash Settings (KittyWare Customdash)
        CustomDashJump         = { Type = "boolean", Default = false },
        CustomDashRotateCam    = { Type = "boolean", Default = false },
        CustomDashStartFlickAngle = { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashSecondFlickDelay= { Type = "number", Default = 5, Min = 0, Max = 50 },
        CustomDashSecondFlickAngle= { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashThirdFlickDelay = { Type = "number", Default = 5, Min = 0, Max = 50 },
        CustomDashThirdFlickAngle = { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashLockOn       = { Type = "boolean", Default = false },
        CustomDashLockOnAfter  = { Type = "string",  Default = "Second Flick" },
        CustomDashLockOnPrecision = { Type = "number", Default = 100, Min = 0, Max = 100 },
        CustomDashLockOnDelay  = { Type = "number", Default = 0, Min = 0, Max = 10 },

        -- Custom Dash v2 Settings (KittyWare Customdashv2)
        CustomDashv2Jump       = { Type = "boolean", Default = false },
        CustomDashv2RotateCam  = { Type = "boolean", Default = false },
        CustomDashv2StartFlickAngle = { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashv2SecondFlickDelay= { Type = "number", Default = 5, Min = 0, Max = 50 },
        CustomDashv2SecondFlickDuration = { Type = "number", Default = 0.35, Min = 0.05, Max = 2.0 },
        CustomDashv2SecondFlickAngle= { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashv2ThirdFlickDelay = { Type = "number", Default = 5, Min = 0, Max = 50 },
        CustomDashv2ThirdFlickDuration  = { Type = "number", Default = 0.35, Min = 0.05, Max = 2.0 },
        CustomDashv2ThirdFlickAngle = { Type = "number", Default = 0, Min = -360, Max = 360 },
        CustomDashv2LockOn     = { Type = "boolean", Default = false },
        CustomDashv2LockOnAfter= { Type = "string",  Default = "Second Flick" },
        CustomDashv2LockOnPrecision = { Type = "number", Default = 100, Min = 0, Max = 100 },
        CustomDashv2LockOnDelay = { Type = "number", Default = 0, Min = 0, Max = 10 },
    },
    Target = {
        TargetMode         = { Type = "string",  Default = "Nearest" },
        SpecificPlayer     = { Type = "string",  Default = "None" },
        WholeMap           = { Type = "boolean", Default = true },
        TargetRange       = { Type = "number",  Default = 200, Min = 25, Max = 1000 },
        IgnoreTeam         = { Type = "boolean", Default = true },
        BehindTP           = { Type = "boolean", Default = false },
        BehindDistance     = { Type = "number",  Default = 3.0, Min = 0.0, Max = 5.0 },
    },
    Skills = {
        AutoAim            = { Type = "boolean", Default = true },
        AutoSkillSpam      = { Type = "boolean", Default = false },
        SkillSpamDelay     = { Type = "number",  Default = 0.25, Min = 0.1, Max = 1.0 },
        AutoUltSpam        = { Type = "boolean", Default = false },
        VoidKill           = { Type = "boolean", Default = false },
        VoidDepth          = { Type = "number",  Default = -350, Min = -500, Max = -100 },
        VoidReturnDelay    = { Type = "number",  Default = 0.5, Min = 0.2, Max = 2.0 },
    },
    Survival = {
        SkyTeleport        = { Type = "boolean", Default = false },
        SkyEscapeHP        = { Type = "number",  Default = 30, Min = 10, Max = 60 },
        SkyReturnHP        = { Type = "number",  Default = 80, Min = 50, Max = 100 },
        SkyEscapeHeight    = { Type = "number",  Default = 180, Min = 50, Max = 400 },
        SkyDodge           = { Type = "boolean", Default = false },
        SkyDodgeHeight     = { Type = "number",  Default = 65, Min = 20, Max = 150 },
        SkyDodgeRange      = { Type = "number",  Default = 18, Min = 5, Max = 30 },
        SkyDodgeLockCamera = { Type = "boolean", Default = true },
    },
    Movement = {
        Fly                = { Type = "boolean", Default = false },
        FlySpeed           = { Type = "number",  Default = 60, Min = 10, Max = 200 },
        FlyMode            = { Type = "string",  Default = "CFrame" },
        SpeedBoost         = { Type = "boolean", Default = false },
        SpeedVal           = { Type = "number",  Default = 42, Min = 16, Max = 150 },
        InfiniteJump       = { Type = "boolean", Default = false },
        Noclip             = { Type = "boolean", Default = false },
        AntiVoid           = { Type = "boolean", Default = true },
    },
    Visuals = {
        HighlightESP       = { Type = "boolean", Default = false },
        BillboardESP       = { Type = "boolean", Default = false },
        ShowCharacterESP   = { Type = "boolean", Default = true },
        Tracers            = { Type = "boolean", Default = false },
        TracerOrigin       = { Type = "string",  Default = "Bottom" },
        FOVCircle          = { Type = "boolean", Default = false },
        UseCharacterColors = { Type = "boolean", Default = true },
        HighlightColor     = { Type = "string", Default = "Cyan" },
        ShowDeathCounterRisk = { Type = "boolean", Default = true },
        DeathCounterRiskColor = { Type = "string", Default = "Red" },
        SaitamaESPColor    = { Type = "string", Default = "Green" },
        GarouESPColor      = { Type = "string", Default = "Blue" },
        SonicESPColor      = { Type = "string", Default = "Yellow" },
        SuiryuESPColor     = { Type = "string", Default = "Orange" },
        OtherCharacterESPColor = { Type = "string", Default = "Cyan" },
        MetalBatESPColor  = { Type = "string", Default = "Orange" },
        AtomicESPColor    = { Type = "string", Default = "Purple" },
        TatsumakiESPColor = { Type = "string", Default = "Pink" },
        GenosESPColor     = { Type = "string", Default = "Red" },
        ChildEmperorESPColor = { Type = "string", Default = "Yellow" },
        ZombieManESPColor = { Type = "string", Default = "White" },
        GojoESPColor      = { Type = "string", Default = "Purple" },
        KJESPColor        = { Type = "string", Default = "Red" },
        FrozenSoulESPColor= { Type = "string", Default = "Cyan" },
    },
    World = {
        FullBright         = { Type = "boolean", Default = false },
        RemoveFog          = { Type = "boolean", Default = false },
        CustomFOV          = { Type = "boolean", Default = false },
        FOVValue           = { Type = "number",  Default = 90, Min = 60, Max = 120 },
        AntiAFK            = { Type = "boolean", Default = true },
        AutoServerHop      = { Type = "boolean", Default = true },
        AutoHopMinPlayers  = { Type = "number",  Default = 4, Min = 2, Max = 8 },
    },
    UI = {
        IsOpen             = { Type = "boolean", Default = true },
        AccentName         = { Type = "string",  Default = "Cyan Neon" },
        AutoSave           = { Type = "boolean", Default = true },
    },
    Telemetry = {
        AutoRecordData     = { Type = "boolean", Default = false },
        AutoSaveInterval   = { Type = "number",  Default = 120, Min = 15, Max = 600 },
        RecordHitboxes     = { Type = "boolean", Default = true },
        RecordAnimations   = { Type = "boolean", Default = true },
        RecordAttributes   = { Type = "boolean", Default = true },
        RecordCooldowns    = { Type = "boolean", Default = true },
        RecordSounds       = { Type = "boolean", Default = true },
        RecordTools        = { Type = "boolean", Default = true },
        RecordRemotes      = { Type = "boolean", Default = true },
        RecordCorrelations = { Type = "boolean", Default = true },
        RecordCharacters   = { Type = "boolean", Default = true },
        RecordInteractions = { Type = "boolean", Default = true },
        RecordWorldObjects = { Type = "boolean", Default = true },
        RecordCombatEvents = { Type = "boolean", Default = true },
        MaxCombatEvents    = { Type = "number",  Default = 1000, Min = 100, Max = 5000 },
        RecordSkillRecon         = { Type = "boolean", Default = true },
        ReconSampleHz             = { Type = "number",  Default = 20, Min = 5, Max = 30 },
        ReconPreWindow            = { Type = "number",  Default = 1.25, Min = 0.25, Max = 3 },
        ReconTargetRange          = { Type = "number",  Default = 45, Min = 15, Max = 100 },
        ReconMaxSkillDuration     = { Type = "number",  Default = 12, Min = 3, Max = 30 },
        ReconToolWindow            = { Type = "number",  Default = 4, Min = 1, Max = 8 },
        MaxSkillSessions          = { Type = "number",  Default = 1500, Min = 200, Max = 8000 },
        MaxReconEventsPerSession  = { Type = "number",  Default = 320, Min = 80, Max = 1000 },
        MaxReconSamplesPerSession = { Type = "number",  Default = 180, Min = 30, Max = 500 },

        RecordOmni                 = { Type = "boolean", Default = true },
        OmniHookAllChanged         = { Type = "boolean", Default = true },
        OmniCaptureRemoteIncoming  = { Type = "boolean", Default = true },
        OmniCaptureRemoteOutgoing  = { Type = "boolean", Default = true },
        OmniCaptureMap             = { Type = "boolean", Default = true },
        OmniCaptureTerrain         = { Type = "boolean", Default = true },
        OmniPlayerSampleHz         = { Type = "number",  Default = 20, Min = 2, Max = 30 },
        OmniMaxEvents              = { Type = "number",  Default = 50000, Min = 5000, Max = 200000 },
        OmniMaxInstances           = { Type = "number",  Default = 100000, Min = 10000, Max = 500000 },
        OmniMaxNetworkRecords      = { Type = "number",  Default = 20000, Min = 1000, Max = 100000 },
        OmniSnapshotInterval       = { Type = "number",  Default = 60, Min = 10, Max = 600 },
        OmniTerrainCellSize        = { Type = "number",  Default = 4, Min = 2, Max = 8 },
        OmniTerrainMaxCells        = { Type = "number",  Default = 250000, Min = 10000, Max = 2000000 },
        OmniRawNDJSON               = { Type = "boolean", Default = true },
    },
    Keybinds = {
        ToggleGUI          = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.RightControl },
        ToggleFly          = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F5 },
        ToggleNoclip       = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F6 },
        ToggleAimlock      = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F7 },
        ToggleBehindTP     = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.F9 },
        ToggleSkyDodge     = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.H },
        EmergencyStop      = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.Delete },
        MassBringKey       = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.G },
        SinglePerformKey   = { Type = "EnumItem", EnumType = Enum.KeyCode, Default = Enum.KeyCode.V },
    }
}

return ConfigSchema
end

-- ============================================================================
-- Module: Core.EventBus
-- ============================================================================
__modules["Core.EventBus"] = function()
--!strict
local Signal = require("Core.Signal")

local EventBus = {}
EventBus.__index = EventBus

function EventBus.new()
    local self = setmetatable({
        _events = {},
        _history = {},
        _maxHistory = 25,
    }, EventBus)
    return self
end

function EventBus:Subscribe(eventName: string, callback: (...any) -> ())
    if not self._events[eventName] then
        self._events[eventName] = Signal.new()
    end
    return self._events[eventName]:Connect(callback)
end

function EventBus:Publish(eventName: string, ...: any)
    if not self._history[eventName] then
        self._history[eventName] = {}
    end
    local entry = { Timestamp = os.clock(), Data = { ... } }
    table.insert(self._history[eventName], 1, entry)
    if #self._history[eventName] > self._maxHistory then
        table.remove(self._history[eventName])
    end

    if self._events[eventName] then
        self._events[eventName]:Fire(...)
    end
end

function EventBus:PublishSync(eventName: string, ...: any)
    if not self._history[eventName] then
        self._history[eventName] = {}
    end
    local entry = { Timestamp = os.clock(), Data = { ... } }
    table.insert(self._history[eventName], 1, entry)
    if #self._history[eventName] > self._maxHistory then
        table.remove(self._history[eventName])
    end

    if self._events[eventName] then
        self._events[eventName]:FireSync(...)
    end
end

function EventBus:GetHistory(eventName: string)
    return self._history[eventName] or {}
end

function EventBus:Clear()
    for _, sig in pairs(self._events) do
        sig:Destroy()
    end
    table.clear(self._events)
    table.clear(self._history)
end

return EventBus

end
__modules["Core/EventBus"] = __modules["Core.EventBus"]

-- ============================================================================
-- Module: Core.Logger
-- ============================================================================
__modules["Core.Logger"] = function()
--!strict
local Logger = {}
Logger.__index = Logger

local LevelNames = {
    [1] = "TRACE",
    [2] = "DEBUG",
    [3] = "INFO",
    [4] = "WARN",
    [5] = "ERROR",
    [6] = "FATAL"
}

function Logger.new(initialLevel: (number | string)?)
    local self = setmetatable({
        Level = 3,
        History = {},
        MaxHistory = 100,
        OnLog = nil,
    }, Logger)
    if initialLevel then
        self:SetLevel(initialLevel)
    end
    return self
end

function Logger:SetLevel(level: number | string)
    if type(level) == "string" then
        for k, v in pairs(LevelNames) do
            if v == level:upper() then
                self.Level = k
                return
            end
        end
    elseif type(level) == "number" then
        self.Level = math.clamp(level, 1, 6)
    end
end

function Logger:_Log(level: number, tag: string, message: any)
    if level < self.Level then return end
    local levelStr = LevelNames[level] or "INFO"
    local timestamp = os.date("%X")
    local formatted = string.format("[%s] [%s] [%s] %s", timestamp, levelStr, tag, tostring(message))

    table.insert(self.History, 1, formatted)
    if #self.History > self.MaxHistory then
        table.remove(self.History)
    end

    if level >= 5 then
        warn(formatted)
    else
        print(formatted)
    end

    if self.OnLog then
        pcall(self.OnLog, formatted, level, tag)
    end
end

function Logger:Trace(tag: string, message: any) self:_Log(1, tag, message) end
function Logger:Debug(tag: string, message: any) self:_Log(2, tag, message) end
function Logger:Info(tag: string, message: any)  self:_Log(3, tag, message) end
function Logger:Warn(tag: string, message: any)  self:_Log(4, tag, message) end
function Logger:Error(tag: string, message: any) self:_Log(5, tag, message) end
function Logger:Fatal(tag: string, message: any) self:_Log(6, tag, message) end

function Logger:SafeCall(tag: string, fn: (...any) -> ...any, ...: any): (boolean, ...any)
    local results = { pcall(fn, ...) }
    local success = results[1]
    if not success then
        local err = tostring(results[2])
        local trace = debug.traceback()
        self:Error(tag, string.format("SafeCall Failed: %s\nTrace: %s", err, trace))
    end
    return table.unpack(results)
end

return Logger

end
__modules["Core/Logger"] = __modules["Core.Logger"]

-- ============================================================================
-- Module: Core.Maid
-- ============================================================================
__modules["Core.Maid"] = function()
--!strict
local Maid = {}
Maid.__index = Maid

export type Task = (() -> ()) | RBXScriptConnection | { Disconnect: (any) -> () } | { Destroy: (any) -> () } | Instance

function Maid.new()
    local self = setmetatable({
        _tasks = {},
    }, Maid)
    return self
end

function Maid:GiveTask(taskItem: Task): any
    assert(taskItem ~= nil, "Task cannot be nil")
    local taskId = #self._tasks + 1
    self._tasks[taskId] = taskItem
    return taskId
end

function Maid:DoCleaning()
    local tasks = self._tasks
    for index, taskItem in pairs(tasks) do
        if typeof(taskItem) == "RBXScriptConnection" then
            taskItem:Disconnect()
        elseif type(taskItem) == "function" then
            pcall(taskItem)
        elseif typeof(taskItem) == "Instance" then
            pcall(function() taskItem:Destroy() end)
        elseif type(taskItem) == "table" then
            if type(taskItem.Destroy) == "function" then
                pcall(function() taskItem:Destroy() end)
            elseif type(taskItem.Disconnect) == "function" then
                pcall(function() taskItem:Disconnect() end)
            elseif type(taskItem.DoCleaning) == "function" then
                pcall(function() taskItem:DoCleaning() end)
            end
        end
        tasks[index] = nil
    end
end

function Maid:Destroy()
    self:DoCleaning()
end

return Maid

end
__modules["Core/Maid"] = __modules["Core.Maid"]

-- ============================================================================
-- Module: Core.Scheduler
-- ============================================================================
__modules["Core.Scheduler"] = function()
--!strict
local Scheduler = {}
Scheduler.__index = Scheduler

export type TaskDefinition = {
    Category: string,
    Callback: (dt: number) -> (),
    LastRun: number,
    Enabled: boolean,
    ExecutionCount: number,
}

function Scheduler.new(logger: any?)
    local self = setmetatable({
        _logger = logger,
        _intervals = {
            Fast       = 1 / 60, -- Exact 60 Hz interval (~0.0166s)
            Normal     = 0.0667,  -- ~15 Hz
            Slow       = 0.5,    -- 2 Hz
            Background = 2.0,    -- 0.5 Hz
        },
        _tasks = {},
    }, Scheduler)
    return self
end

function Scheduler:Register(name: string, category: string, callback: (dt: number) -> (), enabled: boolean?)
    self._tasks[name] = {
        Category = category or "Normal",
        Callback = callback,
        LastRun = 0,
        Enabled = enabled ~= false,
        ExecutionCount = 0,
    }
end

function Scheduler:SetEnabled(name: string, enabled: boolean)
    if self._tasks[name] then
        self._tasks[name].Enabled = enabled
    end
end

function Scheduler:Step(dt: number)
    local now = os.clock()
    for taskName, taskItem in pairs(self._tasks) do
        if taskItem.Enabled then
            local interval = self._intervals[taskItem.Category] or 0.05
            if (now - taskItem.LastRun) >= interval then
                local taskDt = taskItem.LastRun == 0 and dt or (now - taskItem.LastRun)
                taskItem.LastRun = now
                taskItem.ExecutionCount += 1
                local ok, err = pcall(taskItem.Callback, taskDt)
                if not ok then
                    local message = string.format("Task '%s' failed: %s", tostring(taskName), tostring(err))
                    if self._logger then
                        self._logger:Error("Scheduler", message)
                    else
                        warn("[Scheduler] " .. message)
                    end
                end
            end
        end
    end
end

function Scheduler:GetTaskStats(): { [string]: { Category: string, Executions: number, Enabled: boolean } }
    local stats = {}
    for name, item in pairs(self._tasks) do
        stats[name] = {
            Category = item.Category,
            Executions = item.ExecutionCount,
            Enabled = item.Enabled,
        }
    end
    return stats
end

return Scheduler

end
__modules["Core/Scheduler"] = __modules["Core.Scheduler"]

-- ============================================================================
-- Module: Core.ServiceContainer
-- ============================================================================
__modules["Core.ServiceContainer"] = function()
--!strict
local ServiceContainer = {}
ServiceContainer.__index = ServiceContainer

export type ServiceEntry = {
    Name: string,
    Instance: any?,
    Factory: ((container: any) -> any)?,
    Dependencies: { string },
    Resolved: boolean,
}

function ServiceContainer.new()
    local self = setmetatable({
        _services = {},
        _factories = {},
        _dependencies = {}, -- Adjacency list for real DAG
        _resolving = {},
    }, ServiceContainer)
    return self
end

function ServiceContainer:Register(name: string, instanceOrFactory: any, dependencies: { string }?)
    assert(name and instanceOrFactory, "ServiceContainer:Register requires name and instance/factory")
    assert(not self._services[name] and not self._factories[name], string.format("ServiceContainer: duplicate registration for '%s'", tostring(name)))
    local deps = dependencies or {}
    self._dependencies[name] = deps

    if type(instanceOrFactory) == "function" then
        self._factories[name] = instanceOrFactory
    else
        self._services[name] = instanceOrFactory
    end
    return instanceOrFactory
end

function ServiceContainer:Get(name: string): any
    if self._services[name] then
        return self._services[name]
    end

    if self._factories[name] then
        if self._resolving[name] then
            error(string.format("[ServiceContainer] Circular dependency detected while resolving service '%s'!", name))
        end

        self._resolving[name] = true
        local factory = self._factories[name]

        local ok, result = pcall(factory, self)
        self._resolving[name] = nil
        if not ok then
            error(result, 0)
        end

        local instance = result
        self._services[name] = instance
        self._factories[name] = nil
        return instance
    end

    error(string.format("[ServiceContainer] Service '%s' is not registered!", tostring(name)))
end

function ServiceContainer:Has(name: string): boolean
    return self._services[name] ~= nil or self._factories[name] ~= nil
end

function ServiceContainer:BuildGraph(): { [string]: { string } }
    local graph = {}
    for name, deps in pairs(self._dependencies) do
        graph[name] = deps
    end
    return graph
end

-- Kahn's Algorithm / Topological Sort for Dependency Graph
-- Resolves services in dependency-first order and detects any cyclic dependencies
function ServiceContainer:TopologicalSort(): ({ string }, boolean, string?)
    local inDegree = {}
    local adjList = {}
    local allNodes = {}

    -- Collect all registered nodes
    for name, _ in pairs(self._dependencies) do
        allNodes[name] = true
        inDegree[name] = 0
        adjList[name] = {}
    end
    for name, _ in pairs(self._services) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end
    for name, _ in pairs(self._factories) do
        if not allNodes[name] then
            allNodes[name] = true
            inDegree[name] = 0
            adjList[name] = {}
        end
    end

    -- Build adjacency list: if A depends on B, edge is B -> A (B must resolve before A)
    for node, deps in pairs(self._dependencies) do
        for _, dep in ipairs(deps) do
            if allNodes[dep] then
                table.insert(adjList[dep], node)
                inDegree[node] = (inDegree[node] or 0) + 1
            end
        end
    end

    -- Queue for nodes with in-degree 0 (no unresolved dependencies)
    local queue = {}
    for node, deg in pairs(inDegree) do
        if deg == 0 then
            table.insert(queue, node)
        end
    end

    local order = {}
    while #queue > 0 do
        local curr = table.remove(queue, 1)
        table.insert(order, curr)

        for _, neighbor in ipairs(adjList[curr] or {}) do
            inDegree[neighbor] -= 1
            if inDegree[neighbor] == 0 then
                table.insert(queue, neighbor)
            end
        end
    end

    -- If order contains all nodes, no cycles exist; otherwise a cycle was detected
    local totalCount = 0
    for _ in pairs(allNodes) do totalCount += 1 end

    local hasCycle = (#order < totalCount)
    local cycleNode = nil
    if hasCycle then
        for node, deg in pairs(inDegree) do
            if deg > 0 then
                cycleNode = node
                break
            end
        end
    end

    return order, not hasCycle, cycleNode
end

function ServiceContainer:ResolveAllInOrder(): { string }
    local order, noCycles, cycleNode = self:TopologicalSort()
    if not noCycles then
        error(string.format("[ServiceContainer] Cannot initialize services due to circular dependency involving '%s'!", tostring(cycleNode)))
    end

    for _, sName in ipairs(order) do
        self:Get(sName)
    end
    return order
end

return ServiceContainer

end
__modules["Core/ServiceContainer"] = __modules["Core.ServiceContainer"]

-- ============================================================================
-- Module: Core.Signal
-- ============================================================================
__modules["Core.Signal"] = function()
--!strict
local Signal = {}
Signal.__index = Signal

export type Connection = {
    Disconnect: (self: Connection) -> (),
    Connected: boolean,
}

export type Signal = {
    Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
    Fire: (self: Signal, ...any) -> (),
    FireSync: (self: Signal, ...any) -> (),
    Wait: (self: Signal) -> ...any,
    Destroy: (self: Signal) -> (),
    GetListenerCount: (self: Signal) -> number,
}

function Signal.new(): Signal
    local self = setmetatable({
        _listeners = {},
        _listenerCount = 0,
    }, Signal)
    return (self :: any) :: Signal
end

function Signal:Connect(callback: (...any) -> ()): Connection
    assert(type(callback) == "function", "Signal:Connect requires a function")
    local connection = {
        _callback = callback,
        _signal = self,
        Connected = true,
    }
    function connection:Disconnect()
        if not self.Connected then return end
        self.Connected = false
        if self._signal then
            self._signal._listeners[self] = nil
            self._signal._listenerCount = math.max(0, self._signal._listenerCount - 1)
        end
    end
    self._listeners[connection] = true
    self._listenerCount += 1
    return connection
end

function Signal:Fire(...: any)
    for connection in pairs(self._listeners) do
        if connection.Connected and connection._callback then
            task.spawn(connection._callback, ...)
        end
    end
end

-- Synchronous Fire: executes callbacks immediately in the calling thread
function Signal:FireSync(...: any)
    for connection in pairs(self._listeners) do
        if connection.Connected and connection._callback then
            local ok, err = pcall(connection._callback, ...)
            if not ok then
                warn(string.format("[Signal] Error in synchronous listener: %s", tostring(err)))
            end
        end
    end
end

function Signal:Wait(): ...any
    local thread = coroutine.running()
    local conn
    conn = self:Connect(function(...)
        conn:Disconnect()
        task.spawn(thread, ...)
    end)
    return coroutine.yield()
end

function Signal:GetListenerCount(): number
    return self._listenerCount
end

function Signal:Destroy()
    for connection in pairs(self._listeners) do
        connection.Connected = false
    end
    table.clear(self._listeners)
    self._listenerCount = 0
end

return Signal

end
__modules["Core/Signal"] = __modules["Core.Signal"]

-- ============================================================================
-- Module: Diagnostics.SelfDiagnostics
-- ============================================================================
__modules["Diagnostics.SelfDiagnostics"] = function()
--!strict
local SelfDiagnostics = {}
SelfDiagnostics.__index = SelfDiagnostics

function SelfDiagnostics.new(logger: any)
    local self = setmetatable({
        _logger = logger,
        DegradedModes = {
            Network = false,
            Config = false,
            Visuals = false,
        }
    }, SelfDiagnostics)
    return self
end

function SelfDiagnostics:RunHealthCheck(): (boolean, { [string]: string })
    local report = {}
    local isHealthy = true

    local requiredServices = { "Players", "RunService", "UserInputService", "Workspace", "HttpService" }
    for _, sName in ipairs(requiredServices) do
        local ok, s = pcall(function() return game:GetService(sName) end)
        if ok and s then
            report["Service_" .. sName] = "OK"
        else
            report["Service_" .. sName] = "MISSING"
            isHealthy = false
        end
    end

    -- Real Degraded Fallback Assessment
    if typeof(hookmetamethod) ~= "function" then
        self.DegradedModes.Network = true
        report["API_hookmetamethod"] = "UNSUPPORTED (Degraded Network Mode)"
    else
        report["API_hookmetamethod"] = "AVAILABLE"
    end

    if typeof(writefile) ~= "function" or typeof(readfile) ~= "function" then
        self.DegradedModes.Config = true
        report["API_FileIO"] = "UNSUPPORTED (Degraded In-Memory Config)"
    else
        report["API_FileIO"] = "AVAILABLE"
    end

    local visualsOk = pcall(function()
        local h = Instance.new("Highlight")
        h:Destroy()
    end)
    self.DegradedModes.Visuals = not visualsOk
    report["API_InstanceVisuals"] = visualsOk and "AVAILABLE" or "UNSUPPORTED"

    self._logger:Info("SelfDiagnostics", string.format("Health Check Complete. Status: %s", isHealthy and "HEALTHY" or "DEGRADED"))
    return isHealthy, report
end

return SelfDiagnostics

end
__modules["Diagnostics/SelfDiagnostics"] = __modules["Diagnostics.SelfDiagnostics"]

-- ============================================================================
-- Module: Diagnostics.UnitTests
-- ============================================================================
__modules["Diagnostics.UnitTests"] = function()
--!strict
local Signal = require("Core.Signal")
local EventBus = require("Core.EventBus")
local Maid = require("Core.Maid")
local Scheduler = require("Core.Scheduler")
local ServiceContainer = require("Core.ServiceContainer")
local StateMachine = require("Architecture.StateMachine")
local FeatureManager = require("Architecture.FeatureManager")
local CacheEngine = require("Performance.Cache")
local ObjectPool = require("Performance.ObjectPool")
local Profiler = require("Performance.Profiler")
local ConfigManager = require("Config.ConfigManager")
local Logger = require("Core.Logger")

local UnitTests = {}

function UnitTests.RunAll(): (boolean, { [string]: boolean })
    local results = {}
    local logger = Logger.new(3)

    -- 1. Deterministic Signal Test (Synchronous & Async)
    local sig = Signal.new()
    local sigVal = nil
    local conn = sig:Connect(function(v) sigVal = v end)
    sig:FireSync(42) -- Deterministic immediate dispatch
    conn:Disconnect()
    sig:FireSync(99)
    sig:Destroy()
    results["Signal_DeterministicSyncTest"] = (sigVal == 42)

    -- 2. Deterministic EventBus Test
    local eb = EventBus.new()
    local ebReceived = false
    local ebConn = eb:Subscribe("Test.Event", function(d) if d == "OK" then ebReceived = true end end)
    eb:PublishSync("Test.Event", "OK")
    ebConn:Disconnect()
    eb:Clear()
    results["EventBus_DeterministicSyncTest"] = ebReceived

    -- 3. Maid Resource Cleanup Test
    local maid = Maid.new()
    local cleaned = false
    maid:GiveTask(function() cleaned = true end)
    maid:DoCleaning()
    results["MaidTest"] = cleaned

    -- 4. Isolated Strict Whitelist FSM Test
    local isolatedFSM = StateMachine.new("IDLE", logger)
    isolatedFSM:RegisterState("LOW_STATE",  { Priority = 20 })
    isolatedFSM:RegisterState("HIGH_STATE", { Priority = 90 })

    local unregBlocked = not isolatedFSM:CanTransitionTo("HIGH_STATE", nil)
    isolatedFSM:RegisterTransition("IDLE", "HIGH_STATE")
    local regAllowed = isolatedFSM:CanTransitionTo("HIGH_STATE", nil)
    isolatedFSM:TransitionTo("HIGH_STATE", nil, "Test Enter", "UnitTest")

    isolatedFSM:RegisterTransition("HIGH_STATE", "LOW_STATE")
    local lowBlocked = not isolatedFSM:CanTransitionTo("LOW_STATE", nil)
    isolatedFSM:TransitionTo("IDLE", nil, "Reset", "UnitTest", true)
    results["FSM_StrictWhitelistAndPriorityTest"] = (unregBlocked and regAllowed and lowBlocked and #isolatedFSM.TelemetryLogs >= 2)

    -- 5. Isolated 60 Hz Scheduler Test
    local sched = Scheduler.new()
    local schedCount = 0
    sched:Register("FastTask", "Fast", function() schedCount += 1 end)
    sched:Step(0.0166)
    results["Scheduler_60HzTest"] = (schedCount == 1)

    -- 6. ServiceContainer True Factory DI & Kahn's DAG Topological Sort Test
    local container = ServiceContainer.new()
    container:Register("ServiceA", function(c) return { Name = "A" } end, {})
    container:Register("ServiceB", function(c) return { Dep = c:Get("ServiceA") } end, { "ServiceA" })
    local order, noCycles = container:TopologicalSort()
    local resolvedB = container:Get("ServiceB")
    results["DependencyGraph_KahnTopologicalSortTest"] = (noCycles and resolvedB.Dep.Name == "A")

    -- 7. ObjectPool Double-Release Guard & Telemetry Test
    local pool = ObjectPool.new(function() return { active = true } end, function(o) o.active = false end, 2, 10)
    local item = pool:Acquire()
    pool:Release(item)
    pool:Release(item) -- Double-release attempt
    local telem = pool:GetTelemetry()
    results["ObjectPool_DoubleReleaseGuardTest"] = (item.active == false and telem.InvalidReleases == 1 and telem.AcquireCount == 1)
    pool:Destroy()

    -- 8. Cache Weak-Key Instance ID Map & Invalidation Test
    local cache = CacheEngine.new(0.08)
    cache:Clear()
    local partA = Instance.new("Part")
    local partB = Instance.new("Part")
    local los1 = cache:CachedRaycast(Vector3.new(0,0,0), Vector3.new(0,10,0), { partA })
    local los2 = cache:CachedRaycast(Vector3.new(0,0,0), Vector3.new(0,10,0), { partB })
    cache:InvalidateRaycasts()
    results["Cache_WeakKeyAndInvalidationTest"] = (cache.RaycastStats.Misses == 2 and cache.RaycastStats.Invalidations == 1)
    partA:Destroy()
    partB:Destroy()

    -- 9. Profiler Hysteresis Test
    local profiler = Profiler.new()
    local pStart = profiler:Begin("BudgetTask", 0.001)
    task.wait(0.004)
    profiler:End("BudgetTask", pStart)
    local metric = profiler.Metrics["BudgetTask"]
    results["Profiler_HysteresisTest"] = (metric and metric.Status == "OVER_BUDGET")

    -- 10. Config Strict EnumFamily & Clamping Runtime Validation Test
    local cfg = ConfigManager.new(logger)
    local dirtyData = {
        World = { FOVValue = 99999 },
        Keybinds = {
            ToggleFly = "CorruptedString",         -- String -> Default Enum.KeyCode.F5
            ToggleAimlock = Enum.Material.Plastic, -- Wrong Enum Family -> Default Enum.KeyCode.F7
        }
    }
    cfg:ValidateAndClamp(dirtyData)
    local isEnumCorrect = (dirtyData.Keybinds.ToggleFly == Enum.KeyCode.F5 and dirtyData.Keybinds.ToggleAimlock == Enum.KeyCode.F7)
    results["Config_StrictEnumFamilyValidationTest"] = (dirtyData.World.FOVValue == 120 and isEnumCorrect)

    -- 11. UI Presentation Layer Lifecycle & Idempotency Test
    local UIController = require("UI.UIController")
    local mockContainer = ServiceContainer.new()
    local testUI = UIController.new({
        ConfigManager = cfg,
        FeatureManager = FeatureManager.new(logger, profiler),
        StateMachine = isolatedFSM,
        Profiler = profiler,
        Cache = cache,
        NetworkEngine = { _isHooked = false, PacketCount = 0, LastGoal = nil },
        Logger = logger,
        Bootstrap = { GetDiagnostics = function() return {} end },
        Container = mockContainer,
    })
    
    local okInit, _ = pcall(function() testUI:Init() end)
    local okToggle, _ = pcall(function() testUI:Toggle() end)
    local okTab, _ = pcall(function() testUI:SelectTab("Movement") end)
    local okDestroy, _ = pcall(function() testUI:Destroy() end)
    local okReinit, _ = pcall(function()
        testUI:Init()
        testUI:Destroy()
    end)
    results["UI_LifecycleAndIdempotencyTest"] = (okInit and okToggle and okTab and okDestroy and okReinit)

    local allPassed = true
    for name, passed in pairs(results) do
        if not passed then
            allPassed = false
            logger:Error("UnitTests", "FAILED: " .. name)
        else
            logger:Info("UnitTests", "PASSED: " .. name)
        end
    end

    return allPassed, results
end

return UnitTests

end
__modules["Diagnostics/UnitTests"] = __modules["Diagnostics.UnitTests"]

-- ============================================================================
-- Module: Network.NetworkEngine
-- ============================================================================
__modules["Network.NetworkEngine"] = function()
--!strict
local NetworkEngine = {}
NetworkEngine.__index = NetworkEngine

function NetworkEngine.new(deps: { Logger: any, EventBus: any, RemoteResolver: any })
    local self = setmetatable({
        _logger = deps.Logger,
        _eventBus = deps.EventBus,
        _remoteResolver = deps.RemoteResolver,
        _isHooked = false,
        _oldNamecall = nil,
        OutgoingHooked = false,
        PacketCount = 0,
        LastPacketTick = 0,
        LastGoal = nil,
        _degradedMode = false,
    }, NetworkEngine)
    return self
end

function NetworkEngine:Init(config: any?)
    if self._isHooked then return end -- Idempotency Guard

    -- The hook is only useful for telemetry/remote observation. Keep it OFF during normal play
    -- because every RemoteEvent/RemoteFunction namecall passes through this metamethod.
    local telemetry = config and config.Telemetry
    if not (telemetry and telemetry.AutoRecordData == true
        and (telemetry.RecordRemotes ~= false or telemetry.RecordOmni == true)) then
        self._degradedMode = true
        self.OutgoingHooked = false
        return
    end

    pcall(function()
        if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
            local oldNamecall
            local this = self
            oldNamecall = hookmetamethod(game, "__namecall", function(selfRemote, ...)
                if not this._isHooked then
                    return oldNamecall(selfRemote, ...)
                end

                local method = getnamecallmethod()
                local args = {...}

                local isRemote =
                    selfRemote:IsA("RemoteEvent") or selfRemote:IsA("RemoteFunction")
                    or selfRemote:IsA("BindableEvent") or selfRemote:IsA("BindableFunction")

                if isRemote then
                    local path = selfRemote.Name
                    pcall(function() path = getPath(selfRemote) end)
                    local info = {Name=selfRemote.Name,Class=selfRemote.ClassName,Path=path}

                    local function pack(v, depth, seen)
                        depth=depth or 0
                        if depth>12 then return {__type="Truncated",Reason="MaxDepth"} end
                        local tv=typeof(v)
                        if v==nil or type(v)=="boolean" or type(v)=="string" then return v end
                        if type(v)=="number" then return v end
                        if tv=="Instance" then
                            local pth=""
                            pcall(function() pth=getPath(v) end)
                            return {__type="Instance",Class=v.ClassName,Name=v.Name,Path=pth}
                        elseif tv=="Vector3" then return {__type="Vector3",X=v.X,Y=v.Y,Z=v.Z}
                        elseif tv=="CFrame" then local c={v:GetComponents()} return {__type="CFrame",Components=c}
                        elseif tv=="Vector2" then return {__type="Vector2",X=v.X,Y=v.Y}
                        elseif tv=="Color3" then return {__type="Color3",R=v.R,G=v.G,B=v.B}
                        elseif tv=="EnumItem" then return {__type="EnumItem",EnumType=tostring(v.EnumType),Name=v.Name,Value=v.Value}
                        end
                        if type(v)=="table" then
                            seen=seen or {}
                            if seen[v] then return {__type="Cycle"} end
                            seen[v]=true
                            local out,n={},0
                            for k,val in pairs(v) do
                                n+=1
                                if n>1024 then out.__truncated=true break end
                                out[tostring(k)]=pack(val,depth+1,seen)
                            end
                            seen[v]=nil
                            return out
                        end
                        return {__type=tv,Value=tostring(v)}
                    end

                    local packed={}
                    for i,v in ipairs(args) do packed[i]=pack(v) end
                    this.PacketCount+=1
                    this.LastPacketTick=os.clock()
                    this._eventBus:Publish("Network.OutgoingAny",info,method,packed)

                    if method=="FireServer" and type(args[1])=="table" and args[1].Goal then
                        this.LastGoal=tostring(args[1].Goal)
                        this._eventBus:Publish("Network.OutgoingGoal",args[1].Goal,args[1])
                    end
                end
                return oldNamecall(selfRemote, ...)
            end)
            self._oldNamecall = oldNamecall
            self._isHooked = true
            self.OutgoingHooked = true
            self._logger:Info("NetworkEngine", "Metamethod Hook initialized successfully.")
        else
            self._degradedMode = true
            self._logger:Warn("NetworkEngine", "Running in Degraded Mode (hookmetamethod API unsupported)")
        end
    end)
end

function NetworkEngine:Unhook()
    if not self._isHooked then return end
    self._isHooked = false
    self.OutgoingHooked = false

    -- Attempt genuine metamethod restoration if environment supports it
    pcall(function()
        if self._oldNamecall then
            if typeof(hookmetamethod) == "function" then
                hookmetamethod(game, "__namecall", self._oldNamecall)
                self._logger:Info("NetworkEngine", "Metamethod Hook restored to original state.")
            elseif typeof(restorefunction) == "function" then
                restorefunction(self._oldNamecall)
            end
        end
    end)
end

function NetworkEngine:Destroy()
    self:Unhook()
    self._oldNamecall = nil
    self._isHooked = false
    self.OutgoingHooked = false
end

function NetworkEngine:SendAction(goalName: string, payload: any?): boolean
    local remote = self._remoteResolver:Resolve("Communicate")
    if remote and remote.Parent then
        local data = (type(payload) == "table" and table.clone(payload)) or {}
        data.Goal = goalName
        local ok = pcall(function() remote:FireServer(data) end)
        return ok
    end
    return false
end

return NetworkEngine

end
__modules["Network/NetworkEngine"] = __modules["Network.NetworkEngine"]

-- ============================================================================
-- Module: Network.RemoteResolver
-- ============================================================================
__modules["Network.RemoteResolver"] = function()
--!strict
local RemoteResolver = {}
RemoteResolver.__index = RemoteResolver

function RemoteResolver.new(logger: any)
    local self = setmetatable({
        _logger = logger,
        _cache = {},
    }, RemoteResolver)
    return self
end

function RemoteResolver:Resolve(namePattern: string): RemoteEvent?
    if self._cache[namePattern] and (self._cache[namePattern] :: Instance).Parent then
        return self._cache[namePattern] :: RemoteEvent
    end

    local char = game:GetService("Players").LocalPlayer.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("RemoteEvent") and child.Name:lower():find(namePattern:lower()) then
                self._cache[namePattern] = child
                return child
            end
        end
    end

    local rep = game:GetService("ReplicatedStorage")
    for _, desc in ipairs(rep:GetDescendants()) do
        if desc:IsA("RemoteEvent") and desc.Name:lower():find(namePattern:lower()) then
            self._cache[namePattern] = desc
            return desc
        end
    end

    return nil
end

return RemoteResolver

end
__modules["Network/RemoteResolver"] = __modules["Network.RemoteResolver"]

-- ============================================================================
-- Module: Performance.Cache
-- ============================================================================
__modules["Performance.Cache"] = function()
--!strict
local CacheEngine = {}
CacheEngine.__index = CacheEngine

function CacheEngine.new(baseTTL: number?)
    local self = setmetatable({
        PlayerCache = {},
        RaycastCache = {},
        _instanceIdMap = setmetatable({}, { __mode = "k" }), -- Ephemeron Weak-Key ID Map (100% collision-free in standard scripts)
        _nextInstanceId = 1,
        BaseTTL = baseTTL or 0.08,
        PlayerStats = { Hits = 0, Misses = 0, Invalidations = 0 },
        RaycastStats = { Hits = 0, Misses = 0, Invalidations = 0 },
        _maxRaycastEntries = 200,
    }, CacheEngine)
    return self
end

function CacheEngine:_GetInstanceId(inst: Instance): number
    local id = self._instanceIdMap[inst]
    if not id then
        id = self._nextInstanceId
        self._nextInstanceId += 1
        self._instanceIdMap[inst] = id
    end
    return id
end

function CacheEngine:GetPlayerEntry(player: Player): any
    if not player or not player.Parent then return nil end
    local entry = self.PlayerCache[player]
    local now = os.clock()

    local ttl = self.BaseTTL
    local totalReq = self.PlayerStats.Hits + self.PlayerStats.Misses
    if totalReq > 50 then
        local hitRate = self.PlayerStats.Hits / totalReq
        if hitRate > 0.85 then ttl *= 1.25
        elseif hitRate < 0.40 then ttl *= 0.75 end
    end

    if entry and (now - entry.LastCheck) < ttl and entry.Character and entry.Character.Parent then
        self.PlayerStats.Hits += 1
        return entry
    end

    self.PlayerStats.Misses += 1
    local char = player.Character
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso"))
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    local anim = hum and hum:FindFirstChildWhichIsA("Animator")
    local isAlive = (char ~= nil and hum ~= nil and root ~= nil and hum.Health > 0 and char.Parent ~= nil)

    entry = {
        Player = player,
        Character = char,
        RootPart = root,
        Humanoid = hum,
        Animator = anim,
        IsAlive = isAlive,
        Team = player.Team,
        LastCheck = now,
    }
    self.PlayerCache[player] = entry
    return entry
end

function CacheEngine:CachedRaycast(origin: Vector3, targetPos: Vector3, filterList: { Instance }?): boolean
    -- Collision-free deterministic hash using weak-key instance map
    local filterStr = ""
    if filterList and #filterList > 0 then
        local ids = {}
        for _, inst in ipairs(filterList) do
            table.insert(ids, tostring(self:_GetInstanceId(inst)))
        end
        filterStr = table.concat(ids, ",")
    end

    local hash = string.format("%.1f_%.1f_%.1f_%.1f_%.1f_%.1f_[%s]", origin.X, origin.Y, origin.Z, targetPos.X, targetPos.Y, targetPos.Z, filterStr)
    local cached = self.RaycastCache[hash]
    local now = os.clock()

    if cached and (now - cached.Time) < 0.04 then
        self.RaycastStats.Hits += 1
        return cached.Result
    end

    self.RaycastStats.Misses += 1
    local direction = targetPos - origin
    if direction.Magnitude < 0.1 then return true end

    local params = RaycastParams.new()
    params.FilterDescendantsInstances = filterList or {game:GetService("Players").LocalPlayer.Character}
    params.FilterType = Enum.RaycastFilterType.Exclude

    local result = workspace:Raycast(origin, direction, params)
    local hasLOS = true
    if result and result.Instance then
        local hitChar = result.Instance:FindFirstAncestorWhichIsA("Model")
        local isPlayerModel = false
        for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
            if p.Character == hitChar then
                isPlayerModel = true
                break
            end
        end
        if not isPlayerModel then
            hasLOS = false
        end
    end

    self.RaycastCache[hash] = { Result = hasLOS, Time = now }
    return hasLOS
end

function CacheEngine:InvalidatePlayer(player: Player)
    self.PlayerCache[player] = nil
    self.PlayerStats.Invalidations += 1
    self:InvalidateRaycasts()
end

function CacheEngine:InvalidateRaycasts()
    table.clear(self.RaycastCache)
    self.RaycastStats.Invalidations += 1
end

-- Event-driven cache invalidation for workspace topology changes & player lifecycle
function CacheEngine:HookWorkspaceEvents(maid: any)
    if not maid then return end

    local lastGeomInvalidate = 0
    local function onTopologyChange()
        local now = os.clock()
        if (now - lastGeomInvalidate) > 0.1 then -- Debounced invalidation (max 10 Hz)
            lastGeomInvalidate = now
            table.clear(self.RaycastCache)
            self.RaycastStats.Invalidations += 1
        end
    end

    local Players = game:GetService("Players")

    pcall(function()
        maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
            self:InvalidatePlayer(player)
        end))
    end)

    pcall(function()
        for _, player in ipairs(Players:GetPlayers()) do
            maid:GiveTask(player.CharacterAdded:Connect(function()
                self:InvalidatePlayer(player)
            end))
            maid:GiveTask(player.CharacterRemoving:Connect(function()
                self:InvalidatePlayer(player)
            end))
        end
    end)

    pcall(function()
        maid:GiveTask(Players.PlayerAdded:Connect(function(player)
            self:InvalidatePlayer(player)
            maid:GiveTask(player.CharacterAdded:Connect(function()
                self:InvalidatePlayer(player)
            end))
            maid:GiveTask(player.CharacterRemoving:Connect(function()
                self:InvalidatePlayer(player)
            end))
        end))
    end)

    -- Raycast cache uses TTL; no need to listen to all workspace descendants
end

function CacheEngine:Clear()
    table.clear(self.PlayerCache)
    table.clear(self.RaycastCache)
    self.PlayerStats.Hits = 0
    self.PlayerStats.Misses = 0
    self.RaycastStats.Hits = 0
    self.RaycastStats.Misses = 0
end

return CacheEngine

end
__modules["Performance/Cache"] = __modules["Performance.Cache"]

-- ============================================================================
-- Module: Performance.ObjectPool
-- ============================================================================
__modules["Performance.ObjectPool"] = function()
--!strict
local ObjectPool = {}
ObjectPool.__index = ObjectPool

export type PoolTelemetry = {
    Available: number,
    Active: number,
    PeakUsage: number,
    MaxCapacity: number,
    AcquireCount: number,
    ReleaseCount: number,
    InvalidReleases: number,
}

function ObjectPool.new(factory: () -> any, resetFn: ((any) -> ())?, initialSize: number?, maxCapacity: number?)
    local self = setmetatable({
        _factory = factory,
        _reset = resetFn,
        _pool = {},
        _activeSet = setmetatable({}, { __mode = "k" }), -- Ownership & double-release protection
        MaxCapacity = maxCapacity or 32,
        Acquisitions = 0,
        Releases = 0,
        InvalidReleases = 0,
        PeakUsage = 0,
    }, ObjectPool)

    for i = 1, math.min(initialSize or 8, self.MaxCapacity) do
        table.insert(self._pool, factory())
    end
    return self
end

function ObjectPool:Acquire(): any
    self.Acquisitions += 1
    local obj = nil

    if #self._pool > 0 then
        obj = table.remove(self._pool)
    else
        obj = self._factory()
    end

    self._activeSet[obj] = true
    local activeCount = self:GetActiveCount()
    if activeCount > self.PeakUsage then
        self.PeakUsage = activeCount
    end

    return obj
end

function ObjectPool:Release(obj: any)
    -- Guard: Prevent double release of the exact same object
    if not self._activeSet[obj] then
        self.InvalidReleases += 1
        return
    end

    self._activeSet[obj] = nil
    self.Releases += 1

    if self._reset then
        pcall(self._reset, obj)
    end

    -- Respect maximum capacity bound to prevent unbounded pool growth
    if #self._pool < self.MaxCapacity then
        table.insert(self._pool, obj)
    elseif typeof(obj) == "Instance" then
        pcall(function() obj:Destroy() end)
    end
end

function ObjectPool:GetActiveCount(): number
    local count = 0
    for _ in pairs(self._activeSet) do count += 1 end
    return count
end

function ObjectPool:GetSize(): number
    return #self._pool
end

function ObjectPool:GetTelemetry(): PoolTelemetry
    return {
        Available = #self._pool,
        Active = self:GetActiveCount(),
        PeakUsage = self.PeakUsage,
        MaxCapacity = self.MaxCapacity,
        AcquireCount = self.Acquisitions,
        ReleaseCount = self.Releases,
        InvalidReleases = self.InvalidReleases,
    }
end

function ObjectPool:Destroy()
    for _, obj in ipairs(self._pool) do
        if typeof(obj) == "Instance" then
            pcall(function() obj:Destroy() end)
        end
    end
    table.clear(self._pool)
    table.clear(self._activeSet)
end

return ObjectPool

end
__modules["Performance/ObjectPool"] = __modules["Performance.ObjectPool"]

-- ============================================================================
-- Module: Performance.Profiler
-- ============================================================================
__modules["Performance.Profiler"] = function()
--!strict
local Profiler = {}
Profiler.__index = Profiler

export type ProfilerMetric = {
    TotalTime: number,
    Calls: number,
    MinTime: number,
    MaxTime: number,
    PeakMicroseconds: number,
    LastTime: number,
    AvgMicroseconds: number,
    EmaMicroseconds: number,
    Budget: number,
    Status: string,
}

function Profiler.new()
    local self = setmetatable({
        Enabled = false,
        Metrics = {},
        FrameSamples = 0,
        LastFpsCalc = os.clock(),
        CurrentFPS = 60,
        MemoryKB = 0,
        PingMS = 0,
    }, Profiler)
    return self
end

function Profiler:Begin(tag: string, budgetMs: number?): number?
    if not self.Enabled then return nil end
    if not self.Metrics[tag] then
        self.Metrics[tag] = {
            TotalTime = 0,
            Calls = 0,
            MinTime = math.huge,
            MaxTime = 0,
            PeakMicroseconds = 0,
            LastTime = 0,
            AvgMicroseconds = 0,
            EmaMicroseconds = 0,
            Budget = (budgetMs or 2.0) * 1000, -- microseconds
            Status = "OK",
        }
    end
    return os.clock()
end

function Profiler:End(tag: string, startTime: number?)
    if not self.Enabled or not startTime then return end
    local duration = (os.clock() - startTime) * 1000000 -- microseconds
    local metric: ProfilerMetric = self.Metrics[tag]
    if metric then
        metric.Calls += 1
        metric.TotalTime += duration
        metric.LastTime = duration
        if duration < metric.MinTime then metric.MinTime = duration end
        if duration > metric.MaxTime then metric.MaxTime = duration end
        if duration > metric.PeakMicroseconds then metric.PeakMicroseconds = duration end
        metric.AvgMicroseconds = metric.TotalTime / metric.Calls

        -- Real-Time Rolling EMA Calculation (Alpha = 0.20)
        metric.EmaMicroseconds = (metric.EmaMicroseconds == 0) and duration or (metric.EmaMicroseconds * 0.80 + duration * 0.20)

        -- Real-Time Budget Assessment with Hysteresis (Enter > 100%, Exit < 80%)
        if metric.Status == "OK" then
            if metric.EmaMicroseconds > metric.Budget then
                metric.Status = "OVER_BUDGET"
            end
        elseif metric.Status == "OVER_BUDGET" then
            if metric.EmaMicroseconds < (metric.Budget * 0.80) then
                metric.Status = "OK"
            end
        end
    end
end

function Profiler:UpdateSystemMetrics()
    self.FrameSamples += 1
    local now = os.clock()
    if (now - self.LastFpsCalc) >= 0.5 then
        self.CurrentFPS = math.floor(self.FrameSamples / (now - self.LastFpsCalc))
        self.FrameSamples = 0
        self.LastFpsCalc = now

        pcall(function()
            local stats = game:GetService("Stats")
            self.MemoryKB = math.floor(stats:GetTotalMemoryUsageMb() * 1024)
            local net = stats:FindFirstChild("PerformanceStats") and stats.PerformanceStats:FindFirstChild("Ping")
            if net then
                self.PingMS = math.floor(net:GetValue())
            end
        end)
    end
end

function Profiler:GetReport(): { [string]: any }
    return {
        FPS = self.CurrentFPS,
        MemoryKB = self.MemoryKB,
        PingMS = self.PingMS,
        Metrics = self.Metrics,
    }
end

return Profiler

end
__modules["Performance/Profiler"] = __modules["Performance.Profiler"]

-- ============================================================================
-- Module: Systems.Combat
-- ============================================================================
__modules["Systems.Combat"] = function()
--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Stats = game:GetService("Stats")
local LocalPlayer = Players.LocalPlayer

local Maid = require("Core.Maid")

local Combat = {}
Combat.__index = Combat

-- KittyWare Animation Constants / OUR AutoTech trigger = Uppercut
local AnimM1       = "10479335397"
local AnimDash     = "10480793962"
local AnimKick     = "10503381238"
local AnimUlt      = "13379003796"
local AnimBlock    = "10491993682"

-- Input payloads used by the combat remote (KittyWare line 129)
local InputActions = {
    frontDash = { Dash = Enum.KeyCode.W, Key = Enum.KeyCode.Q, Goal = "KeyPress" },
    backDash  = { Dash = Enum.KeyCode.S, Key = Enum.KeyCode.Q, Goal = "KeyPress" },
    holdBlock = { Key = Enum.KeyCode.F, Goal = "KeyPress" },
    releaseBlock = { Key = Enum.KeyCode.F, Goal = "KeyRelease" },
}

local function getPingValue(divider: number?): number
    local div = divider or 1
    local ping = 50
    pcall(function()
        local net = Stats.Network
        local ssi = net and net:FindFirstChild("ServerStatsItem")
        local dp = ssi and ssi:FindFirstChild("Data Ping")
        if dp and typeof(dp.GetValue) == "function" then
            ping = dp:GetValue()
        end
    end)
    return ping / div
end

local function setCameraAngles(pos: Vector3, yaw: number, pitch: number)
    local Camera = Workspace.CurrentCamera
    if not Camera then return end
    Camera.CFrame = CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
end

function Combat.new(deps: { Cache: any, EventBus: any, Network: any, EnemyState: any, Logger: any, StateMachine: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _network = deps.Network,
        _enemyState = deps.EnemyState,
        _logger = deps.Logger,
        _fsm = deps.StateMachine,
        _config = nil,
        _charMaid = nil :: any,
        _renderBinds = {},
        _runtimeGeneration = 0,
        _activeGeneration = nil,
        _targetRevision = 0,
        _manualDashSuppressUntil = 0,

        -- Auto Tech State (KittyWare Architecture)
        Character = nil :: Model?,
        RootPart = nil :: BasePart?,
        Humanoid = nil :: Humanoid?,
        Animator = nil :: Animator?,
        CombatRemote = nil :: RemoteEvent?,
        DashCooldownActive = false,
        ShutdownConnection = false,
        FrontDashAt = 0,
        TechBusy = false,
        CurrentTarget = nil :: Player?,
        _stickyRandomTarget = nil :: Player?,
        MassBringActive = false,
        _massBringConnection = nil :: RBXScriptConnection?,
        _massBringOriginal = {} :: { [Player]: CFrame },
        _lastMassBringTick = 0,
    }, Combat)

    return self
end

-- =============================================================================
-- AUTO TECH ENGINE & DYNAMIC CHARACTER LIFECYCLE (KITTYWARE CORE + HUB INTEGRATION)
-- =============================================================================

function Combat:InitLifecycle(maid: any, configManager: any)
    self._config = configManager

    -- Manual dash guard: Roblox TSB uses Q for dash input. A short suppression
    -- window prevents a side/back/front dash from being mistaken for AutoTech.
    maid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Q then
            self._manualDashSuppressUntil = os.clock() + 0.65
        end
    end))

    -- Hook LocalPlayer character lifecycle
    maid:GiveTask(LocalPlayer.CharacterAdded:Connect(function(char)
        self:HookCharacter(char)
    end))

    maid:GiveTask(LocalPlayer.CharacterRemoving:Connect(function()
        self:CleanupCharacter()
    end))

    if LocalPlayer.Character then
        self:HookCharacter(LocalPlayer.Character)
    end

    maid:GiveTask(function()
        self:Destroy()
    end)
end

function Combat:CleanupCharacter()
    self._runtimeGeneration += 1
    self._activeGeneration = nil
    if self._charMaid then
        self._charMaid:DoCleaning()
        self._charMaid = nil
    end
    self.ShutdownConnection = false
    self.TechBusy = false

    for bindName in pairs(self._renderBinds) do
        pcall(function()
            RunService:UnbindFromRenderStep(bindName)
        end)
    end
    table.clear(self._renderBinds)

    self.CurrentTarget = nil
    self._stickyRandomTarget = nil
    self.Character = nil
    self.Humanoid = nil
    self.RootPart = nil
    self.Animator = nil
    self.CombatRemote = nil
    self.DashCooldownActive = false
    self.ShutdownConnection = false
    self.TechBusy = false
    self.FrontDashAt = 0
end

function Combat:HookCharacter(char: Model)
    self:CleanupCharacter()

    self._charMaid = Maid.new()
    self.Character = char
    self.DashCooldownActive = false
    self.ShutdownConnection = false
    self.TechBusy = false
    self.FrontDashAt = 0

    local humanoid = char:WaitForChild("Humanoid", 5) :: Humanoid?
    local rootPart = char:WaitForChild("HumanoidRootPart", 5) :: BasePart?
    local remote = char:WaitForChild("Communicate", 5) :: RemoteEvent?

    self.Humanoid = humanoid
    self.RootPart = rootPart
    self.CombatRemote = remote

    if not humanoid or not rootPart then
        if self._logger then
            self._logger:Warn("Combat", "HookCharacter: Humanoid or RootPart not found within timeout")
        end
        return
    end

    -- Symmetrical cleanup on character death
    self._charMaid:GiveTask(humanoid.Died:Connect(function()
        self.DashCooldownActive = false
        self.ShutdownConnection = false
        self.TechBusy = false
        for bindName in pairs(self._renderBinds) do
            pcall(function()
                RunService:UnbindFromRenderStep(bindName)
            end)
        end
        table.clear(self._renderBinds)
    end))

    -- AutoRotate lock management during tech execution (KittyWare line 1609-1610)
    self._charMaid:GiveTask(humanoid:GetPropertyChangedSignal("AutoRotate"):Connect(function()
        if self.ShutdownConnection and self.Humanoid then
            self.Humanoid.AutoRotate = false
        end
    end))

    -- KittyWare line 1578: Animator.AnimationPlayed hook
    local animator = humanoid:WaitForChild("Animator", 5) :: Animator?
    self.Animator = animator

    if animator then
        self._charMaid:GiveTask(animator.AnimationPlayed:Connect(function(track)
            self:OnAnimationPlayed(track)
        end))
    else
        self._charMaid:GiveTask(humanoid.ChildAdded:Connect(function(child)
            if child:IsA("Animator") then
                self.Animator = child
                self._charMaid:GiveTask(child.AnimationPlayed:Connect(function(track)
                    self:OnAnimationPlayed(track)
                end))
            end
        end))
    end
end

-- =============================================================================
-- AUTO TECH CORE METHODS (KITTYWARE-ALIGNED IMPLEMENTATION)
-- =============================================================================

function Combat:IsMovingForward(): boolean
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local bar = pg and pg:FindFirstChild("Bar")
    local mh = bar and bar:FindFirstChild("MagicHealth")
    local cdholder = mh and mh:FindFirstChild("cdholder")
    return cdholder ~= nil and cdholder:FindFirstChild("forward") ~= nil
end

function Combat:PerformFrontDash(): boolean
    -- KittyWare guard: do not stack front-dash requests while the dash state is
    -- already active or the game still reports the forward-dash window.
    -- This also prevents AutoTech's ping helper from producing accidental
    -- extra dash requests during a player's manual dash chain.
    local now = os.clock()
    if self.DashCooldownActive and (now - self.FrontDashAt < 0.5 or self:IsMovingForward()) then
        return false
    end

    local comm = self.CombatRemote
    if not comm or not comm.Parent then
        local char = self.Character or LocalPlayer.Character
        comm = char and (char:FindFirstChild("Communicate") or char:WaitForChild("Communicate", 1))
        self.CombatRemote = comm
    end

    if not comm or not comm:IsA("RemoteEvent") then
        return false
    end

    local fired = false
    pcall(function()
        comm:FireServer(InputActions.frontDash)
        fired = true
    end)

    if fired then
        self.FrontDashAt = now
        if not Workspace:GetAttribute("NoDashCooldown") then
            self.DashCooldownActive = true
            task.delay(5, function()
                self.DashCooldownActive = false
            end)
        end
    end

    return fired
end

function Combat:IsRuntimeValid(generation: number?): boolean
    if generation and generation ~= self._runtimeGeneration then return false end
    if not self.Character or not self.Character.Parent or not self.Humanoid or self.Humanoid.Health <= 0 then return false end
    return self._runtimeGeneration >= 0
end

function Combat:WaitForPing(extraDelay: number?, generation: number?): boolean
    generation = generation or self._activeGeneration
    if not self:IsRuntimeValid(generation) then error("__TSB_RUNTIME_CANCEL__", 0) end
    self.ShutdownConnection = true
    self:PerformFrontDash()
    task.wait(math.max(0, getPingValue(1000) + 0.05 + (extraDelay or 0)))
    if not self:IsRuntimeValid(generation) then error("__TSB_RUNTIME_CANCEL__", 0) end
    return true
end

function Combat:RotateCamera(angle: number?, targetPos: Vector3?, rotateChar: boolean?, rotateCam: boolean?, arg5: any?, precision: number?)
    local Camera = Workspace.CurrentCamera
    if not Camera or not self.RootPart then return end

    if not rotateChar and not rotateCam and not angle then
        rotateChar = true
    end

    local prec = precision or 1
    local camCF = Camera.CFrame
    local camPos = camCF.Position
    local isChar = rotateChar or rotateCam
    local isCam = (not rotateChar) or rotateCam

    local effectiveCamPos = camPos
    if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        effectiveCamPos = effectiveCamPos - camCF.RightVector * 1.75
    end

    local pitch = math.asin(camCF.LookVector.Y)
    local currentYaw = 0
    local targetYaw = 0

    if targetPos then
        local dir
        if isChar then
            dir = (targetPos - self.RootPart.Position).Unit
            currentYaw = math.atan2(-self.RootPart.CFrame.LookVector.X, -self.RootPart.CFrame.LookVector.Z)
        else
            dir = (targetPos - effectiveCamPos).Unit
            currentYaw = math.atan2(-camCF.LookVector.X, -camCF.LookVector.Z)
        end
        targetYaw = math.atan2(-dir.X, -dir.Z)
    else
        local baseLook = isChar and self.RootPart.CFrame.LookVector or camCF.LookVector
        currentYaw = math.atan2(-baseLook.X, -baseLook.Z)
        targetYaw = currentYaw + math.rad(angle or 0)
    end

    local diff = math.atan2(math.sin(targetYaw - currentYaw), math.cos(targetYaw - currentYaw))
    local finalYaw = currentYaw + diff * prec

    if isChar and self.Humanoid and self.RootPart then
        self.Humanoid.AutoRotate = false
        self.RootPart.CFrame = CFrame.new(self.RootPart.Position) * CFrame.Angles(0, finalYaw, 0)
        if not isCam then return end
    end

    setCameraAngles(camPos, finalYaw, pitch)
end

function Combat:BindCameraRotation(angle: number, duration: number, isRootPart: boolean?)
    local Camera = Workspace.CurrentCamera
    if not Camera or not self.RootPart then return end

    local radAngle = math.rad(angle or 0)
    local startTick = tick()
    local baseCF = isRootPart and self.RootPart.CFrame or Camera.CFrame
    local look = baseCF.LookVector
    local startYaw = math.atan2(-look.X, -look.Z)
    local targetYaw = startYaw + radAngle
    local bindName = "KittyWareSmoothRotateCamera" .. tostring(tick())

    self._renderBinds[bindName] = true
    local dur = (duration and duration > 0) and duration or 0.35

    RunService:BindToRenderStep(bindName, Enum.RenderPriority.Camera.Value + 1, function()
        if not self.Character or not self.Character.Parent then
            pcall(function() RunService:UnbindFromRenderStep(bindName) end)
            self._renderBinds[bindName] = nil
            return
        end

        local elapsed = tick() - startTick
        local alpha = math.clamp(elapsed / dur, 0, 1)
        local smoothAlpha = alpha * alpha * (3 - 2 * alpha)
        local curCam = Camera.CFrame
        local camPos = curCam.Position
        local pitch = math.asin(curCam.LookVector.Y)
        local currentYaw = startYaw + (targetYaw - startYaw) * smoothAlpha

        if isRootPart and self.Humanoid and self.RootPart then
            self.Humanoid.AutoRotate = false
            self.RootPart.CFrame = CFrame.new(self.RootPart.Position) * CFrame.Angles(0, currentYaw, 0)
        else
            setCameraAngles(camPos, currentYaw, pitch)
        end

        if alpha >= 1 then
            pcall(function() RunService:UnbindFromRenderStep(bindName) end)
            self._renderBinds[bindName] = nil
        end
    end)
end

function Combat:WaitForHumanoid(stepPhase: string, duration: number, enemyChar: Model, enemyHum: Humanoid, callback: () -> (), generation: number?): boolean
    generation = generation or self._activeGeneration
    if not self:IsRuntimeValid(generation) then error("__TSB_RUNTIME_CANCEL__", 0) end
    local phaseName = (stepPhase == "RenderStepped" and "RenderStepped") or "Heartbeat"
    local event = RunService[phaseName]
    local conn: RBXScriptConnection? = nil
    local alive = true

    conn = event:Connect(function()
        if not alive or not self:IsRuntimeValid(generation) then
            alive = false
            if conn then conn:Disconnect(); conn=nil end
            self.ShutdownConnection = false
            return
        end
        if not enemyChar or not enemyChar.Parent or not enemyHum or enemyHum.Health <= 0 then
            alive = false
            if conn then conn:Disconnect(); conn=nil end
            self.ShutdownConnection = false
            return
        end
        -- Ragdoll is optional. The target can be in a normal state and still be a valid cast target.
        pcall(callback)
    end)

    local deadline = os.clock() + math.max(0, duration or 0.4)
    while alive and os.clock() < deadline do
        task.wait()
        if not self:IsRuntimeValid(generation) then
            alive = false
            if conn then conn:Disconnect(); conn=nil end
            error("__TSB_RUNTIME_CANCEL__", 0)
        end
    end
    if conn then conn:Disconnect(); conn=nil end
    self.ShutdownConnection = false
    if self.Humanoid then self.Humanoid.AutoRotate = true end
    return alive and self:IsRuntimeValid(generation)
end

function Combat:FlattenVector(targetPart: BasePart): boolean
    if not self.RootPart or not targetPart then return false end
    local myPos = self.RootPart.Position
    local targetPos = targetPart.Position
    local horizontalDist = (Vector3.new(myPos.X, 0, myPos.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
    if horizontalDist <= 0.2 and myPos.Y < targetPos.Y then return true end
    return false
end

function Combat:PerformAutoTech(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    local targetCFrame: CFrame? = nil
    self:WaitForPing()
    self:RotateCamera(90, nil, true)
    self:BindCameraRotation(270, 0.35, true)
    task.wait(0.3)
    self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
        if targetCFrame or self:FlattenVector(targetHrp) then
            if not targetCFrame then
                if cfg and cfg.Combat and cfg.Combat.LoopDashLooksUp and self.RootPart then
                    local p = self.RootPart.Position
                    targetCFrame = CFrame.lookAt(p, Vector3.new(p.X + 1.5, p.Y + 1.5, p.Z))
                else
                    targetCFrame = self.RootPart and self.RootPart.CFrame
                end
            end
            if targetCFrame and self.Character then
                self.Character:PivotTo(targetCFrame)
            end
        else
            self:RotateCamera(nil, targetHrp.Position, true)
        end
    end)
    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:PerformCustomDash(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    local combatCfg = cfg and cfg.Combat or {}
    local rotateCam = combatCfg.CustomDashRotateCam or false
    local lockPrec = (combatCfg.CustomDashLockOnPrecision or 100) / 100

    if combatCfg.CustomDashJump and self.RootPart then
        local vel = self.RootPart.AssemblyLinearVelocity
        self.RootPart.AssemblyLinearVelocity = Vector3.new(vel.X, 50, vel.Z)
    end

    self.ShutdownConnection = true
    self:RotateCamera(combatCfg.CustomDashStartFlickAngle or 0, nil, false, rotateCam)
    self:WaitForPing(combatCfg.CustomDashSecondFlickDelay or 5)
    self:RotateCamera(combatCfg.CustomDashSecondFlickAngle or 0, nil, false, rotateCam)

    if combatCfg.CustomDashLockOn and combatCfg.CustomDashLockOnAfter == "Second Flick" then
        task.wait(combatCfg.CustomDashLockOnDelay or 0)
        self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
            self:RotateCamera(nil, targetHrp.Position, false, rotateCam, nil, lockPrec)
        end)
    else
        task.wait(combatCfg.CustomDashThirdFlickDelay or 5)
        self:RotateCamera(combatCfg.CustomDashThirdFlickAngle or 0, nil, false, rotateCam)
        if combatCfg.CustomDashLockOn and combatCfg.CustomDashLockOnAfter == "Third Flick" then
            task.wait(combatCfg.CustomDashLockOnDelay or 0)
            self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
                self:RotateCamera(nil, targetHrp.Position, false, rotateCam, nil, lockPrec)
            end)
        end
    end

    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:PerformCustomDashV2(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    local combatCfg = cfg and cfg.Combat or {}
    local rotateCam = combatCfg.CustomDashv2RotateCam or false
    local lockPrec = (combatCfg.CustomDashv2LockOnPrecision or 100) / 100

    if combatCfg.CustomDashv2Jump and self.RootPart then
        local vel = self.RootPart.AssemblyLinearVelocity
        self.RootPart.AssemblyLinearVelocity = Vector3.new(vel.X, 50, vel.Z)
    end

    self.ShutdownConnection = true
    self:RotateCamera(combatCfg.CustomDashv2StartFlickAngle or 0, nil, true, rotateCam)
    self:WaitForPing(combatCfg.CustomDashv2SecondFlickDelay or 5)
    self:BindCameraRotation(combatCfg.CustomDashv2SecondFlickAngle or 0, combatCfg.CustomDashv2SecondFlickDuration or 0.35, not rotateCam)

    if combatCfg.CustomDashv2LockOn and combatCfg.CustomDashv2LockOnAfter == "Second Flick" then
        task.wait(combatCfg.CustomDashv2LockOnDelay or 0)
        self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
            self:RotateCamera(nil, targetHrp.Position, false, rotateCam, nil, lockPrec)
        end)
    else
        task.wait(combatCfg.CustomDashv2ThirdFlickDelay or 5)
        self:BindCameraRotation(combatCfg.CustomDashv2ThirdFlickAngle or 0, combatCfg.CustomDashv2ThirdFlickDuration or 0.35, not rotateCam)
        if combatCfg.CustomDashv2LockOn and combatCfg.CustomDashv2LockOnAfter == "Third Flick" then
            task.wait(combatCfg.CustomDashv2LockOnDelay or 0)
            self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
                self:RotateCamera(nil, targetHrp.Position, false, rotateCam, nil, lockPrec)
            end)
        end
    end

    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:PerformTechLoop(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    local combatCfg = cfg and cfg.Combat or {}
    if combatCfg.Loopv2Jump and self.RootPart then
        local vel = self.RootPart.AssemblyLinearVelocity
        self.RootPart.AssemblyLinearVelocity = Vector3.new(vel.X, 50, vel.Z)
    end
    self.ShutdownConnection = true
    self:RotateCamera(combatCfg.Loopv2FirstFlick or 0, nil, true, combatCfg.Loopv2RotateCam)
    self:WaitForPing(combatCfg.Loopv2SecondFlick or 5)
    self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
        self:RotateCamera(nil, targetHrp.Position, true, combatCfg.Loopv2RotateCam, nil, (combatCfg.Loopv2Precision or 35) / 100)
    end)
    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:LockOnTarget(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    self:WaitForPing()
    local prec = ((cfg and cfg.Combat and cfg.Combat.LockonPrecision) or 100) / 100
    self:WaitForHumanoid("Heartbeat", 0.7, targetChar, targetHum, function()
        self:RotateCamera(nil, targetHrp.Position, true, false, nil, prec)
    end)
    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:TeleportTarget(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    self:WaitForPing()
    self:WaitForHumanoid("Heartbeat", 0.4, targetChar, targetHum, function()
        local pos = targetHrp.Position - Vector3.new(0, 3, 2)
        local cf = CFrame.new(pos, targetHrp.Position)
        if self.Character then
            self.Character:PivotTo(cf)
        end
    end)
    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:PerformAutoLethal(targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    self:WaitForPing()
    if not self.RootPart or not targetHrp then return end
    local relPos = targetHrp.CFrame:PointToObjectSpace(self.RootPart.Position)
    local method = (cfg and cfg.Combat and cfg.Combat.SupaMethod) or "RenderStepped"
    self:WaitForHumanoid(method, 0.3, targetChar, targetHum, function()
        local tPos = targetHrp.Position
        local worldPos = targetHrp.CFrame:PointToWorldSpace(relPos)
        if self.Character then
            self.Character:PivotTo(CFrame.lookAt(worldPos, Vector3.new(tPos.X, worldPos.Y + 1.5, tPos.Z), Vector3.new(0, 1, 0)))
        end
    end)
    self.ShutdownConnection = false
    if self.Humanoid then
        self.Humanoid.AutoRotate = true
    end
end

function Combat:ExecuteAutoTechVariant(variant: string, targetChar: Model, targetHrp: BasePart, targetHum: Humanoid, cfg: any)
    if self.TechBusy then return end
    self.TechBusy = true
    self._runtimeGeneration += 1
    local generation = self._runtimeGeneration
    self._activeGeneration = generation

    if cfg and cfg.Combat and cfg.Combat.AutoTechNotifications and self._eventBus then
        self._eventBus:Publish("UI.Notification", "Auto Tech", "Triggered " .. variant .. " on " .. targetChar.Name, "Success")
    end

    task.spawn(function()
        local success, err = pcall(function()
            if not self:IsRuntimeValid(generation) then return end
            if variant == "Supa" then
                self:PerformAutoLethal(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Lock On Dash" then
                self:LockOnTarget(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Loop Dash" then
                self:PerformAutoTech(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Kiba" then
                self:TeleportTarget(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Loop Dash v2" then
                self:PerformTechLoop(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Custom Dash" then
                self:PerformCustomDash(targetChar, targetHrp, targetHum, cfg)
            elseif variant == "Custom Dash v2" then
                self:PerformCustomDashV2(targetChar, targetHrp, targetHum, cfg)
            end
        end)

        if not self:IsRuntimeValid(generation) then
            if self._activeGeneration == generation then
                self._activeGeneration = nil
                self.TechBusy = false
            end
            return
        end

        if not self:IsRuntimeValid(generation) then
            if self._activeGeneration == generation then
                self._activeGeneration = nil
                self.TechBusy = false
            end
            return
        end

        self.ShutdownConnection = false
        if self.Humanoid then
            self.Humanoid.AutoRotate = true
        end

        for bindName in pairs(self._renderBinds) do
            pcall(function()
                RunService:UnbindFromRenderStep(bindName)
            end)
        end
        table.clear(self._renderBinds)

        -- Auto M1 follow-up if enabled
        if success and self:IsRuntimeValid(generation) and cfg and cfg.Combat and cfg.Combat.AutoTechAutoM1 then
            task.wait(0.04)
            if not self:IsRuntimeValid(generation) then
                if self._activeGeneration == generation then self.TechBusy = false end
                return
            end
            local comm = self.CombatRemote
            if comm and comm:IsA("RemoteEvent") then
                pcall(function() comm:FireServer({ Goal = "m1" }) end)
            end
        end

        if not success and tostring(err) ~= "__TSB_RUNTIME_CANCEL__" then
            warn("[KittyWare] auto tech: " .. tostring(err))
        end

        task.wait(0.1)
        if self._activeGeneration == generation then
            self._activeGeneration = nil
            self.TechBusy = false
        end
    end)
end

function Combat:OnAnimationPlayed(track: AnimationTrack)
    local anim = track and track.Animation
    if not anim then return end

    local cfg = self._config and self._config.Config or nil
    local combatCfg = cfg and cfg.Combat
    if not combatCfg or combatCfg.AutoTechEnabled ~= true then
        return
    end

    local animId = tostring(anim.AnimationId or '')
    local numericId = animId:match('%d+') or animId

    -- OUR AutoTech trigger: UPPERCUT only.
    -- Ult (G) must never trigger AutoTech.
    -- Kick/Ult were used by the source script, but they are intentionally not
    -- used here because our AutoTech was built around the Uppercut trigger.
    local isUppercut = numericId == AnimUppercut
    if not isUppercut then
        return
    end

    -- A manual Q-dash gets a short hard suppression window. This is separate
    -- from the AutoTech-generated front dash, so a legitimate tech chain is
    -- not permanently blocked by the helper's own dash request.
    if os.clock() < (self._manualDashSuppressUntil or 0) then
        return
    end

    -- Also reject the generic dash track when it overlaps the combat track.
    if self.Animator then
        for _, playing in ipairs(self.Animator:GetPlayingAnimationTracks()) do
            local a = playing.Animation
            local id = a and tostring(a.AnimationId or '') or ''
            if (id:match('%d+') or id) == AnimDash then
                return
            end
        end
    end

    -- DashCooldownActive is kept as a re-entry guard, but only blocks when it
    -- represents a currently active helper dash. Do not use the old 5-second
    -- window as a blanket AutoTech lockout.
    if self.DashCooldownActive and (os.clock() - (self.FrontDashAt or 0) < 0.65) then
        return
    end

    if self.TechBusy then
        return
    end

    local triggerGeneration = self._runtimeGeneration

    task.spawn(function()
        if triggerGeneration ~= self._runtimeGeneration then return end

        local char = self.Character or LocalPlayer.Character
        if not char or not char.Parent then return end

        local rootPart = self.RootPart or (char:FindFirstChild('HumanoidRootPart') :: BasePart?)
        if not rootPart then return end

        -- Prefer the exact victim reported by TSB when LastM1Hitted is present.
        -- Fall back to the hub target selector so AutoTech remains functional
        -- on character states where the transient hit marker is already gone.
        local targetPlayer: Player? = nil
        local lastHit = char:GetAttribute('LastM1Hitted')
        if type(lastHit) == 'string' and lastHit ~= '' then
            local liveFolder = Workspace:FindFirstChild('Live')
            if liveFolder then
                local hitName = lastHit:match('^(.-);;') or lastHit
                local hitChar = liveFolder:FindFirstChild(hitName)
                if hitChar and hitChar:IsA('Model') then
                    targetPlayer = Players:GetPlayerFromCharacter(hitChar)
                end
            end
        end

        if not targetPlayer then
            targetPlayer = self:GetTarget(cfg)
        end
        if not targetPlayer then return end

        local targetChar = targetPlayer.Character
        if not targetChar or not targetChar.Parent then return end

        local targetHrp = targetChar:FindFirstChild('HumanoidRootPart') :: BasePart?
        local targetHum = targetChar:FindFirstChildOfClass('Humanoid') :: Humanoid?
        if not targetHrp or not targetHum or targetHum.Health <= 0 then return end

        -- Preserve KittyWare's 20-stud trigger range.
        if (rootPart.Position - targetHrp.Position).Magnitude > 20 then
            return
        end

        local ping = getPingValue(1000)
        local baseDelay = tonumber(combatCfg.AutoTechDelay) or 0.38
        local delayTime = math.clamp(baseDelay - math.min(ping, 0.08), 0.15, 0.60)
        task.wait(delayTime)

        if triggerGeneration ~= self._runtimeGeneration then return end
        if not self.Character or not targetChar.Parent or targetHum.Health <= 0 then return end

        -- Re-check dash state right before executing the variant.
        if os.clock() < (self._manualDashSuppressUntil or 0) then return end
        if self.TechBusy then return end

        local method = tostring(combatCfg.AutoTechMethod or 'Perform Always')
        local performOnce = combatCfg.AutoTechPerformOnce == true
        if method ~= 'Perform Always' and not (method == 'Perform Once' and performOnce) then
            return
        end

        local techVariant = tostring(combatCfg.AutoTechVariant or 'Loop Dash')
        if techVariant == '' then return end

        if method == 'Perform Once' then
            combatCfg.AutoTechPerformOnce = false
            if self._eventBus then
                self._eventBus:Publish('Combat.AutoTechConsumed')
            end
        end

        self:ExecuteAutoTechVariant(techVariant, targetChar, targetHrp, targetHum, cfg)
    end)
end

function Combat:StopAllRuntime()
    self._runtimeGeneration += 1
    self._activeGeneration = nil
    self.TechBusy = false
    self:StopMassBring()
    self:CleanupCharacter()
    self.CurrentTarget = nil
    self._stickyRandomTarget = nil
    self._targetRevision += 1
end

function Combat:Destroy()
    self._runtimeGeneration += 1
    self._activeGeneration = nil
    self.TechBusy = false
    self:StopMassBring()
    self:CleanupCharacter()
    self.CurrentTarget = nil
    self._stickyRandomTarget = nil
end

-- Public target/aim API used by Movement, Skills, UI and other systems.
local function getTargetParts(player: Player): (Model?, Humanoid?, BasePart?)
    if not player or not player.Parent then return nil, nil, nil end
    local char = player.Character
    if not char or not char.Parent then return nil, nil, nil end
    local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
    local root = (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")) :: BasePart?
    if not hum or hum.Health <= 0 or not root then return nil, nil, nil end
    return char, hum, root
end

local function isTargetAllowed(player: Player, ignoreTeam: boolean): boolean
    if player == LocalPlayer or not player.Parent then return false end
    if ignoreTeam and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then
        return false
    end
    local _, hum, root = getTargetParts(player)
    return hum ~= nil and root ~= nil and hum.Health > 0
end

function Combat:GetTarget(config: any): Player?
    config = config or {}
    local targetCfg = config.Target or {}
    local modeRaw = tostring(targetCfg.TargetMode or "Nearest")
    local modeMap = {
        ["nearest"] = "Nearest",
        ["lowest hp"] = "Lowest HP",
        ["random"] = "Random",
        ["specific player"] = "Specific Player",
    }
    local mode = modeMap[modeRaw:lower()] or "Nearest"
    local ignoreTeam = targetCfg.IgnoreTeam ~= false
    local wholeMap = targetCfg.WholeMap ~= false
    local searchRange = math.clamp(tonumber(targetCfg.TargetRange) or 200, 25, 1000)

    local myChar = LocalPlayer.Character
    local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")) :: BasePart?
    if not myRoot then
        self.CurrentTarget = nil
        return nil
    end

    if mode == "Specific Player" then
        local requested = tostring(targetCfg.SpecificPlayer or "None")
        if requested == "None" or requested == "" then
            self.CurrentTarget = nil
            return nil
        end
        for _, player in ipairs(Players:GetPlayers()) do
            if (player.Name == requested or player.DisplayName == requested) and isTargetAllowed(player, ignoreTeam) then
                self.CurrentTarget = player
                return player
            end
        end
        self.CurrentTarget = nil
        return nil
    end

    local candidates = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if isTargetAllowed(player, ignoreTeam) then
            local _, _, targetRoot = getTargetParts(player)
            local inRange = true
            if not wholeMap and targetRoot then
                inRange = (targetRoot.Position - myRoot.Position).Magnitude <= searchRange
            end
            if inRange then
                table.insert(candidates, player)
            end
        end
    end
    if #candidates == 0 then
        self.CurrentTarget = nil
        self._stickyRandomTarget = nil
        return nil
    end

    if mode == "Random" then
        if self._stickyRandomTarget and isTargetAllowed(self._stickyRandomTarget, ignoreTeam) then
            self.CurrentTarget = self._stickyRandomTarget
            return self._stickyRandomTarget
        end
        local picked = candidates[math.random(1, #candidates)]
        self._stickyRandomTarget = picked
        self.CurrentTarget = picked
        return picked
    end

    if mode == "Lowest HP" then
        -- Lowest HP means lowest CURRENT HP, not nearest and not HP percentage.
        -- Distance is only a deterministic tie-breaker.
        local best, bestHp, bestDist = nil, math.huge, math.huge
        for _, player in ipairs(candidates) do
            local _, hum, root = getTargetParts(player)
            if hum and root then
                local hp = math.max(0, hum.Health)
                local dist = (root.Position - myRoot.Position).Magnitude
                if hp < bestHp - 0.001 or (math.abs(hp - bestHp) <= 0.001 and dist < bestDist) then
                    best, bestHp, bestDist = player, hp, dist
                end
            end
        end
        self.CurrentTarget = best
        return best
    end

    local best, bestDist = nil, math.huge
    for _, player in ipairs(candidates) do
        local _, _, root = getTargetParts(player)
        if root then
            local dist = (root.Position - myRoot.Position).Magnitude
            if dist < bestDist then
                best, bestDist = player, dist
            end
        end
    end
    self.CurrentTarget = best
    return best
end

function Combat:GetTargetDebug(config: any): string
    local target = self:GetTarget(config)
    if not target then return "Target: NONE" end
    local _, hum, root = getTargetParts(target)
    local me = LocalPlayer.Character and (LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or LocalPlayer.Character:FindFirstChild("Torso"))
    local dist = (me and root) and math.floor((root.Position - me.Position).Magnitude) or 0
    return string.format("Target: %s | HP %.0f/%.0f | %dm", target.DisplayName or target.Name, hum and hum.Health or 0, hum and hum.MaxHealth or 0, dist)
end

function Combat:GetPredictedAimPosition(target: any, lead: number?): Vector3?
    if not target or typeof(target) ~= "Instance" or not target:IsA("Player") then
        return nil
    end
    local _, hum, root = getTargetParts(target :: Player)
    if not hum or not root then return nil end

    local prediction = math.clamp(tonumber(lead) or 0, 0, 0.50)
    local velocity = root.AssemblyLinearVelocity
    return root.Position + velocity * prediction
end

function Combat:FaceTargetForAttack(target: any, config: any, lead: number?): boolean
    if not target or typeof(target) ~= "Instance" or not target:IsA("Player") then
        return false
    end

    local myRoot = self.RootPart or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")) :: BasePart?
    local aimPos = self:GetPredictedAimPosition(target, lead)
    if not myRoot or not aimPos then return false end

    local flatTarget = Vector3.new(aimPos.X, myRoot.Position.Y, aimPos.Z)
    if (flatTarget - myRoot.Position).Magnitude <= 0.001 then
        return true
    end

    pcall(function()
        myRoot.CFrame = CFrame.lookAt(myRoot.Position, flatTarget)
    end)

    local combatCfg = config and config.Combat or {}
    if combatCfg.Aimlock == true and combatCfg.AimlockMode ~= "Body Only (No Screen Spin)" then
        local cam = Workspace.CurrentCamera
        if cam then
            pcall(function()
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aimPos + Vector3.new(0, 1.5, 0))
            end)
        end
    end
    return true
end

function Combat:StartMassBring(config: any)
    if self.MassBringActive then return end

    local myChar = LocalPlayer.Character
    local myRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")) :: BasePart?
    if not myRoot then return end

    self.MassBringActive = true
    self._lastMassBringTick = 0
    local targetCfg = config and config.Target or {}
    local ignoreTeam = targetCfg.IgnoreTeam ~= false
    if self._fsm then
        self._fsm:TransitionTo("MASS_BRING", nil, "Mass Bring Enabled", "Combat", true)
    end

    self._massBringConnection = RunService.Heartbeat:Connect(function()
        if not self.MassBringActive then return end
        local now = os.clock()
        if now - self._lastMassBringTick < 0.08 then return end
        self._lastMassBringTick = now

        local currentChar = LocalPlayer.Character
        local localRoot = currentChar and (currentChar:FindFirstChild("HumanoidRootPart") or currentChar:FindFirstChild("Torso")) :: BasePart?
        if not localRoot then return end

        local index = 0
        for _, player in ipairs(Players:GetPlayers()) do
            if isTargetAllowed(player, ignoreTeam) then
                local char, hum, root = getTargetParts(player)
                if char and hum and root then
                    if self._massBringOriginal[player] == nil then
                        self._massBringOriginal[player] = root.CFrame
                    end
                    index += 1
                    local angle = index * (math.pi * 2 / math.max(#Players:GetPlayers() - 1, 1))
                    local offset = Vector3.new(math.cos(angle) * 4, 0, math.sin(angle) * 4)
                    pcall(function()
                        root.CFrame = CFrame.lookAt(localRoot.Position + offset, localRoot.Position)
                        root.AssemblyLinearVelocity = Vector3.zero
                    end)
                end
            end
        end
    end)
end

function Combat:StopMassBring()
    self.MassBringActive = false
    if self._massBringConnection then
        pcall(function() self._massBringConnection:Disconnect() end)
        self._massBringConnection = nil
    end

    for player, cf in pairs(self._massBringOriginal) do
        local _, hum, root = getTargetParts(player)
        if hum and hum.Health > 0 and root then
            pcall(function() root.CFrame = cf end)
        end
        self._massBringOriginal[player] = nil
    end

    self._lastMassBringTick = 0
    if self._fsm and self._fsm.CurrentState == "MASS_BRING" then
        self._fsm:TransitionTo("IDLE", nil, "Mass Bring Disabled", "Combat", true)
    end
end

return Combat
end

__modules["Systems/Combat"] = __modules["Systems.Combat"]

-- ============================================================================
-- Module: Systems.EnemyState
-- ============================================================================
__modules["Systems.EnemyState"] = function()
--!strict
export type EnemyData = {
    Cooldowns: { [string]: number },
    IsRagdoll: boolean,
    RagdollStart: number,
    WakeupTime: number,
    IsBlocking: boolean,
    IsAttacking: boolean,
    LastSkill: string,
    LastSkillTick: number,
}

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local EnemyState = {}
EnemyState.__index = EnemyState

local function attributeTruthy(char: Instance?, name: string): boolean
    if not char then return false end
    local value = char:GetAttribute(name)
    return value == true or value == "true" or (type(value) == "number" and value ~= 0)
end

local COUNTER_ATTRIBUTES = {
    "HoldingDeathCounter", "HoldingFlowingWater", "HoldingWaterStreamCuttingFist",
    "HoldingPreysPeril", "HoldingGodSlayer", "HoldingHuntersGrasp"
}

local ATTACK_ATTRIBUTES = {
    "HoldingM1", "HoldingNormalPunch", "HoldingConsecutivePunches", "HoldingSeriousPunch",
    "HoldingOmniDirectionalPunch", "HoldingGammaRayBurst", "HoldingAtomicSlash", "HoldingBeatdown",
    "HoldingGrandSlam", "HoldingHomerun", "HoldingIncinerate", "HoldingIgnitionBurst",
    "HoldingFlashStrike", "HoldingScatter", "HoldingVanishingKick", "HoldingHeadFirst",
    "HoldingSpeedblitzDropkick", "HoldingAtmosCleave", "HoldingSolarCleave", "HoldingTwinbladeRush",
    "HoldingDeathBlow", "HoldingTrinityTear", "HoldingCarnage", "HoldingExpulsivePush"
}

function EnemyState.new(deps: { Cache: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        _states = {},
        _animationCheckTick = {},
        _counterCache = {},
        Profiles = {
            Saitama = { NormalPunch = 12, Consecutive = 15, Shove = 14, Uppercut = 16 },
            Garou = { FlowingWater = 14, LethalWhirlwind = 15, HuntersGrasp = 18, PreysPeril = 16 },
            Sonic = { FlashStrike = 12, WhirlwindKick = 14, Scatter = 16, Shuriken = 15 },
            Suiryu = { VanishingKick = 14, HeadFirst = 15, SweepingKick = 16, FistBarrage = 18 },
            Universal = { Skill1 = 14, Skill2 = 15, Skill3 = 16, Skill4 = 16 },
        }
    }, EnemyState)
    return self
end

function EnemyState:Get(player: Player): EnemyData
    local data = self._states[player]
    if not data then
        data = {
            Cooldowns = {},
            IsRagdoll = false,
            RagdollStart = 0,
            WakeupTime = 0,
            IsBlocking = false,
            IsAttacking = false,
            LastSkill = "None",
            LastSkillTick = 0,
        }
        self._states[player] = data
    end
    return data
end

function EnemyState:Update(player: Player)
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive then return end

    local data = self:Get(player)
    local hum = entry.Humanoid
    local char = entry.Character
    local now = os.clock()
    local hState = hum:GetState()
    local isRag = (hState == Enum.HumanoidStateType.Physics or hState == Enum.HumanoidStateType.Ragdoll)

    if isRag and not data.IsRagdoll then
        data.IsRagdoll = true
        data.RagdollStart = now
        data.WakeupTime = now + 2.25
        self._eventBus:Publish("Combat.EnemyRagdolled", player, data.WakeupTime)
    elseif not isRag and data.IsRagdoll then
        data.IsRagdoll = false
        self._eventBus:Publish("Combat.EnemyWakeup", player)
    end

    local isBlock = false
    local isAttack = false
    if char then
        local blkAttr = char:GetAttribute("Blocking")
        isBlock = (blkAttr == true or blkAttr == "true" or (char:GetAttribute("BlockTime") and not char:GetAttribute("StoppedBlocking")))
        isAttack = attributeTruthy(char, "HoldingM1")
            or attributeTruthy(char, "HoldingNormalPunch")
            or attributeTruthy(char, "HoldingConsecutivePunches")
            or attributeTruthy(char, "HoldingSeriousPunch")
            or attributeTruthy(char, "HoldingOmniDirectionalPunch")
    end

    -- Expensive animation enumeration is shared and throttled per player.
    local last = self._animationCheckTick[player] or 0
    if (now - last) >= 0.08 and entry.Animator then
        self._animationCheckTick[player] = now
        local isCounter = false
        for _, t in ipairs(entry.Animator:GetPlayingAnimationTracks()) do
            local n = (t.Name or ""):lower()
            if n:find("attack") or n:find("punch") or n:find("slash") or n:find("strike") then
                isAttack = true
            end
            if n:find("block") or n:find("guard") or n:find("defend") then
                isBlock = true
            end
            if n:find("counter") or n:find("flowing") or n:find("deflect") or n:find("reflect") then
                isCounter = true
            end
            if isAttack and isBlock and isCounter then break end
        end
        self._counterCache[player] = isCounter
    end

    data.IsBlocking = isBlock
    data.IsAttacking = isAttack
end

function EnemyState:IsEnemyInCounterStance(player: Player): boolean
    local entry = self._cache:GetPlayerEntry(player)
    if not entry or not entry.IsAlive or not entry.Character then return false end
    local char = entry.Character

    for _, attr in ipairs(COUNTER_ATTRIBUTES) do
        if attributeTruthy(char, attr) then
            return true
        end
    end

    return self._counterCache[player] == true
end

return EnemyState

end
__modules["Systems/EnemyState"] = __modules["Systems.EnemyState"]

-- ============================================================================
-- Module: Systems.Movement
-- ============================================================================
__modules["Systems.Movement"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Maid = require("Core.Maid")

local Movement = {}
Movement.__index = Movement

function Movement.new(deps: { Cache: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _logger = deps.Logger,
        LastSafePos = nil,
        LastSafeY = nil,
        LastBehindTPTick = 0,
        LastBehindAttackTick = 0,
        -- Runtime restoration state
        _originalCollision = setmetatable({}, { __mode = "k" }),
        _behindCollisionOriginal = setmetatable({}, { __mode = "k" }),
        _characterConnection = nil :: RBXScriptConnection?,
        _jumpMaid = nil :: any,
        _jumpConfig = nil :: any,
        _config = nil :: any,
        _speedOverride = 42,
        _speedEnabled = false,
        _originalWalkSpeed = nil :: number?,
        _originalPlatformStand = nil :: boolean?,
        _noclipEnabled = false,
        _noclipMaid = nil :: any,
    }, Movement)

    self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(char)
        self.LastSafePos = nil
        self.LastSafeY = nil
        self:RestoreNoclip()
        self:RestoreBehindCollision()
        self:DisableFlyRuntime()
        self._originalWalkSpeed = nil
        self._originalPlatformStand = nil
        if self._noclipMaid then self._noclipMaid:DoCleaning(); self._noclipMaid=nil end
        if self._config and self._config.Movement then
            self:ToggleNoclip(self._config.Movement.Noclip == true)
            self:ToggleJumpFeatures(self._config)
        end
    end)

    return self
end

local function SafeAttackM1()
    local char = LocalPlayer.Character
    local comm = char and char:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        pcall(function() comm:FireServer({ Goal = "m1" }) end)
        return
    end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        pcall(function()
            vim:SendMouseButtonEvent(0, 0, 0, true, game, 1)
            task.delay(0.02, function()
                pcall(function() vim:SendMouseButtonEvent(0, 0, 0, false, game, 1) end)
            end)
        end)
    elseif typeof(mouse1click) == "function" then
        pcall(function() mouse1click() end)
    end
end

function Movement:ToggleFly(enable: boolean, config: any)
    self._config = config or self._config
    if config and config.Movement then
        config.Movement.Fly = enable
    end

    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid then return end

    if not enable then
        self:DisableFlyRuntime()
        return
    end

    if self._originalPlatformStand == nil then
        self._originalPlatformStand = entry.Humanoid.PlatformStand
    end
    pcall(function() entry.Humanoid.PlatformStand = true end)
end

function Movement:DisableFlyRuntime()
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid then
        self._originalPlatformStand = nil
        return
    end

    local original = self._originalPlatformStand
    self._originalPlatformStand = nil
    pcall(function()
        entry.Humanoid.PlatformStand = original == true
        if original ~= true and entry.Humanoid.Health > 0 then
            entry.Humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end
    end)
end

function Movement:UpdateFly(dt: number, config: any)
    self._config = config or self._config
    if not config or not config.Movement or config.Movement.Fly ~= true then
        self:DisableFlyRuntime()
        return
    end

    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    local cam = Workspace.CurrentCamera
    if not entry or not entry.RootPart or not cam or not entry.Humanoid then return end

    local speed = math.clamp(tonumber(config.Movement.FlySpeed) or 60, 10, 200)
    local moveDir = Vector3.zero
    local look = cam.CFrame.LookVector
    local right = cam.CFrame.RightVector

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += look end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= look end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= right end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += right end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then moveDir += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then moveDir -= Vector3.yAxis end

    if moveDir.Magnitude > 1 then moveDir = moveDir.Unit end

    local root = entry.RootPart
    pcall(function() entry.Humanoid.PlatformStand = true end)

    -- Never integrate position with CFrame every frame. Keep the character hovering
    -- at the desired velocity so gravity cannot pull it down and trigger correction.
    local desiredVelocity = moveDir * speed
    pcall(function()
        root.AssemblyLinearVelocity = desiredVelocity
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

function Movement:UpdateSpeed(dt: number, config: any)
    self._config = config or self._config
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid then return end

    local enabled = config and config.Movement and config.Movement.SpeedBoost == true
    local requested = math.clamp(tonumber(config and config.Movement and config.Movement.SpeedVal) or self._speedOverride or 42, 16, 150)
    self._speedEnabled = enabled
    self._speedOverride = requested

    if enabled then
        if self._originalWalkSpeed == nil then self._originalWalkSpeed = entry.Humanoid.WalkSpeed end
        pcall(function() entry.Humanoid.WalkSpeed = requested end)
    elseif self._originalWalkSpeed ~= nil then
        local original = self._originalWalkSpeed
        self._originalWalkSpeed = nil
        pcall(function() entry.Humanoid.WalkSpeed = original end)
    end
end

function Movement:RestoreNoclip()
    for part, original in pairs(self._originalCollision) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = original
            end)
        end
        self._originalCollision[part] = nil
    end
end

function Movement:SuppressBehindCollision(char: Model)
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if self._behindCollisionOriginal[part] == nil then
                self._behindCollisionOriginal[part] = part.CanCollide
            end
            pcall(function() part.CanCollide = false end)
        end
    end
end

function Movement:RestoreBehindCollision()
    for part, original in pairs(self._behindCollisionOriginal) do
        if part and part.Parent then
            pcall(function() part.CanCollide = original end)
        end
        self._behindCollisionOriginal[part] = nil
    end
end

function Movement:UpdateNoclip(config: any)
    self._config = config or self._config
    if not config or not config.Movement or config.Movement.Noclip ~= true then
        self:RestoreNoclip()
        if self._noclipMaid then self._noclipMaid:DoCleaning(); self._noclipMaid=nil end
        return
    end

    local char = LocalPlayer.Character
    if not char then
        self:RestoreNoclip()
        return
    end

    -- Apply immediately; DescendantAdded keeps newly-created hitbox/effect parts covered.
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if self._originalCollision[part] == nil then self._originalCollision[part] = part.CanCollide end
            pcall(function() part.CanCollide = false end)
        end
    end

    if not self._noclipMaid then
        local maid = Maid.new()
        self._noclipMaid = maid
        maid:GiveTask(char.DescendantAdded:Connect(function(inst)
            if not self._config or not self._config.Movement or self._config.Movement.Noclip ~= true then return end
            if inst:IsA("BasePart") then
                if self._originalCollision[inst] == nil then self._originalCollision[inst] = inst.CanCollide end
                pcall(function() inst.CanCollide = false end)
            end
        end))
    end
end

function Movement:SetSpeed(enable: boolean, value: number?)
    self._speedEnabled = enable == true
    if value ~= nil then
        self._speedOverride = math.clamp(tonumber(value) or 42, 16, 150)
    end
    if self._config and self._config.Movement then
        self._config.Movement.SpeedBoost = self._speedEnabled
        self._config.Movement.SpeedVal = self._speedOverride
    end
end

function Movement:SuppressAntiVoid(duration: number?)
    self._antiVoidSuppressedUntil = math.max(self._antiVoidSuppressedUntil or 0, os.clock() + math.max(0, tonumber(duration) or 0.75))
end

function Movement:UpdateAntiVoid(config: any)
    if not config or not config.Movement or config.Movement.AntiVoid ~= true then return end
    if os.clock() < (self._antiVoidSuppressedUntil or 0) then return end
    if config.Movement.Fly == true then return end

    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.RootPart or not entry.Humanoid or entry.Humanoid.Health <= 0 then return end

    local root, hum = entry.RootPart, entry.Humanoid
    local char = LocalPlayer.Character
    if not char then return end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {char}
    rayParams.IgnoreWater = true

    local groundHit
    pcall(function()
        groundHit = Workspace:Raycast(root.Position, Vector3.new(0, -18, 0), rayParams)
    end)

    local vy = root.AssemblyLinearVelocity.Y
    if groundHit and groundHit.Instance and (root.Position.Y - groundHit.Position.Y) <= 6 and math.abs(vy) <= 8 then
        self.LastSafePos = root.CFrame
        self.LastSafeY = root.Position.Y
        return
    end

    if not self.LastSafePos then return end
    local deepBelowSaved = self.LastSafeY and root.Position.Y < (self.LastSafeY - 90)
    local deepVoid = root.Position.Y < -120
    local fastFall = vy < -110 and not groundHit

    if deepVoid or deepBelowSaved or fastFall then
        local safe = self.LastSafePos
        self.LastSafePos = nil
        self.LastSafeY = nil
        pcall(function()
            root.CFrame = safe + Vector3.new(0, 4, 0)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

-- ============================================================================
-- SHARED TARGET SELECTOR
-- ============================================================================
function Movement:FindMapTarget(config: any, combatService: any): Player?
    if combatService and type(combatService.GetTarget)=="function" then
        return combatService:GetTarget(config)
    end
    return nil
end

-- ============================================================================
-- BEHIND TP
-- ============================================================================
local function placeBehind(myRoot: BasePart, tRoot: BasePart, distance: number)
    local look=tRoot.CFrame.LookVector
    local flat=Vector3.new(look.X,0,look.Z)
    flat=flat.Magnitude>0.001 and flat.Unit or Vector3.new(0,0,-1)
    local pos=tRoot.Position-flat*distance+Vector3.new(0,0.15,0)
    local face=tRoot.Position+Vector3.new(0,0.15,0)
    myRoot.AssemblyLinearVelocity=Vector3.zero
    myRoot.AssemblyAngularVelocity=Vector3.zero
    myRoot.CFrame=CFrame.lookAt(pos,face)
end

function Movement:ExecuteBehindTP(config: any, combatService: any): (boolean,string?)
    local char=LocalPlayer.Character
    local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    if not char or not root or not hum or hum.Health<=0 then return false,"Karakter hazır değil" end

    local target=self:FindMapTarget(config,combatService)
    if not target or not target.Character then return false,"Hedef bulunamadı" end
    local tChar=target.Character
    local tRoot=tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum=tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health<=0 then return false,"Hedef geçersiz" end

    self:SuppressBehindCollision(char)
    local dist=math.clamp((config.Target and config.Target.BehindDistance) or 3,0,5)
    pcall(function() placeBehind(root,tRoot,dist) end)
    self.LastBehindTPTick=os.clock()
    return true,target.DisplayName or target.Name
end

function Movement:UpdateBehindLock(dt: number, config: any, combatService: any)
    if not config or not config.Target or config.Target.BehindTP~=true then
        self:RestoreBehindCollision(); return
    end

    local char=LocalPlayer.Character
    local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    if not char or not root or not hum or hum.Health<=0 then
        self:RestoreBehindCollision(); return
    end

    local target=self:FindMapTarget(config,combatService)
    if not target or not target.Character then
        self:RestoreBehindCollision(); return
    end
    local tChar=target.Character
    local tRoot=tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
    local tHum=tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not tHum or tHum.Health<=0 then
        self:RestoreBehindCollision(); return
    end

    self:SuppressBehindCollision(char)
    local dist=math.clamp((config.Target and config.Target.BehindDistance) or 3,0,5)
    pcall(function() placeBehind(root,tRoot,dist) end)
end

-- ============================================================================
-- RELIABLE INFINITE JUMP (DOUBLE JUMP REMOVED)
-- ============================================================================
function Movement:ToggleInfiniteJump(enable: boolean)
    self._jumpEnabled=enable==true
    if self._jumpConfig and self._jumpConfig.Movement then
        self._jumpConfig.Movement.InfiniteJump=self._jumpEnabled
    end
    self:ToggleJumpFeatures(self._jumpConfig)
end

function Movement:ToggleNoclip(enable: boolean)
    self._noclipEnabled=enable==true
    if self._config and self._config.Movement then
        self._config.Movement.Noclip=self._noclipEnabled
    end
    if not self._noclipEnabled then
        self:RestoreNoclip()
        if self._noclipMaid then self._noclipMaid:DoCleaning(); self._noclipMaid=nil end
    else
        self:UpdateNoclip(self._config)
    end
end

function Movement:ToggleJumpFeatures(config: any)
    self._config = config or self._config
    self._jumpConfig = config or self._jumpConfig

    if self._jumpMaid then self._jumpMaid:DoCleaning(); self._jumpMaid=nil end
    if not self._jumpConfig or not self._jumpConfig.Movement or self._jumpConfig.Movement.InfiniteJump ~= true then
        self._jumpEnabled = false
        return
    end

    self._jumpEnabled = true
    local maid = Maid.new()
    self._jumpMaid = maid
    local currentHum: Humanoid? = nil
    local jumpConnection: RBXScriptConnection? = nil

    local function hookCharacter(char: Model)
        currentHum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5) :: Humanoid?
        if jumpConnection then pcall(function() jumpConnection:Disconnect() end); jumpConnection=nil end
        if not currentHum then return end

        jumpConnection = UserInputService.JumpRequest:Connect(function()
            local hum = currentHum
            local cfg = self._jumpConfig and self._jumpConfig.Movement
            if self._jumpMaid ~= maid or not hum or not cfg or cfg.InfiniteJump ~= true or hum.Health <= 0 then return end

            local state = hum:GetState()
            local airborne = state ~= Enum.HumanoidStateType.Running
                and state ~= Enum.HumanoidStateType.Landed
                and state ~= Enum.HumanoidStateType.RunningNoPhysics
                and state ~= Enum.HumanoidStateType.Seated
                and state ~= Enum.HumanoidStateType.Swimming

            if not airborne then return end
            pcall(function()
                hum.Jump = true
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end)
        end)
        maid:GiveTask(jumpConnection)
    end

    if LocalPlayer.Character then hookCharacter(LocalPlayer.Character) end
    maid:GiveTask(LocalPlayer.CharacterAdded:Connect(hookCharacter))
end

function Movement:RefreshJumpFeatures(config: any)
    self:ToggleJumpFeatures(config)
end

function Movement:Destroy()
    if self._jumpMaid then
        self._jumpMaid:DoCleaning()
        self._jumpMaid = nil
    end
    if self._noclipMaid then
        self._noclipMaid:DoCleaning()
        self._noclipMaid = nil
    end

    self:RestoreNoclip()
    self:RestoreBehindCollision()
    if self._originalWalkSpeed ~= nil then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local original = self._originalWalkSpeed
        self._originalWalkSpeed = nil
        if hum then pcall(function() hum.WalkSpeed = original end) end
    end
    self:DisableFlyRuntime()

    if self._characterConnection then
        pcall(function() self._characterConnection:Disconnect() end)
        self._characterConnection = nil
    end
end

return Movement

end
__modules["Systems/Movement"] = __modules["Systems.Movement"]

-- ============================================================================
-- Module: Systems.Skills
-- ============================================================================
__modules["Systems.Skills"] = function()
--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local MoveSetResolver = require("Systems.MoveSetResolver")

local Skills = {}
Skills.__index = Skills

function Skills.new(deps: { Cache: any, Combat: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _combat = deps.Combat,
        _logger = deps.Logger,
        LastSpamTick = 0,
        LastUltSpamTick = 0,
        SpamIdx = 1,
        Keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four },
        _trackTarget = nil,
        _trackUntil = 0,
        _trackLead = 0.10,
        _trackLastTick = 0,
        _trackRoot = nil,
        _localRoot = nil,
        _localCharacter = nil,
        _lastSkillUse = setmetatable({}, {__mode = "k"}),
        _lastSkillTools = {},
    }, Skills)
    return self
end

local function GetCommunicate(): RemoteEvent?
    local char = LocalPlayer.Character
    local comm = char and char:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        return comm
    end
    return nil
end

local function SafeKeyClick(keyCode: Enum.KeyCode): boolean
    -- Prefer TSB's character input remote.
    local comm = GetCommunicate()
    if comm then
        local ok = pcall(function()
            comm:FireServer({ Goal = "KeyPress", Key = keyCode })
        end)
        if ok then
            task.delay(0.045, function()
                pcall(function()
                    local currentComm = GetCommunicate()
                    if currentComm then
                        currentComm:FireServer({ Goal = "KeyRelease", Key = keyCode })
                    end
                end)
            end)
            return true
        end
    end

    local vim = nil
    pcall(function() vim = game:GetService("VirtualInputManager") end)
    if vim then
        return pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.delay(0.045, function()
                pcall(function() vim:SendKeyEvent(false, keyCode, false, game) end)
            end)
        end)
    end

    if typeof(keypress) == "function" and typeof(keyrelease) == "function" then
        return pcall(function()
            keypress(keyCode.Value)
            task.delay(0.045, function()
                pcall(function() keyrelease(keyCode.Value) end)
            end)
        end)
    end
    return false
end

function Skills:BeginSkillTracking(target: Player, duration: number?, lead: number?)
    self._trackTarget = target
    self._trackUntil = os.clock() + math.clamp(duration or 0.55, 0.12, 1.20)
    self._trackLead = math.clamp(lead or 0.10, 0, 0.18)
    self._trackLastTick = 0
    local char = target and target.Character
    self._trackRoot = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")) or nil
end

function Skills:UpdateSkillTracking(config: any)
    local now = os.clock()
    if (now - self._trackLastTick) < 0.033 then return end -- ~30Hz is enough for cast steering
    self._trackLastTick = now

    local target = self._trackTarget
    if not target or not target.Parent or now > self._trackUntil then
        self._trackTarget = nil
        self._trackRoot = nil
        return
    end

    local myChar = LocalPlayer.Character
    if myChar ~= self._localCharacter then
        self._localCharacter = myChar
        self._localRoot = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar:FindFirstChild("Torso")) or nil
    end
    local tChar = target.Character
    if not tChar then
        self._trackTarget = nil
        self._trackRoot = nil
        return
    end

    local tRoot = self._trackRoot
    if not tRoot or not tRoot.Parent or tRoot:IsDescendantOf(tChar) == false then
        tRoot = tChar:FindFirstChild("HumanoidRootPart") or tChar:FindFirstChild("Torso")
        self._trackRoot = tRoot
    end
    local myRoot = self._localRoot
    local tHum = tChar:FindFirstChildOfClass("Humanoid")
    if not tRoot or not myRoot or not tHum or tHum.Health <= 0 then
        self._trackTarget = nil
        self._trackRoot = nil
        return
    end

    local aimPos = self._combat:GetPredictedAimPosition(target, self._trackLead)
    if not aimPos then return end

    local flat = Vector3.new(aimPos.X, myRoot.Position.Y, aimPos.Z)
    if (flat - myRoot.Position).Magnitude > 0.001 then
        pcall(function() myRoot.CFrame = CFrame.lookAt(myRoot.Position, flat) end)
    end

    -- Camera steering is optional and only needed while Aimlock is enabled.
    if config and config.Combat and config.Combat.Aimlock == true and config.Combat.AimlockMode ~= "Body Only (No Screen Spin)" then
        local cam = game:GetService("Workspace").CurrentCamera
        if cam then
            pcall(function() cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aimPos + Vector3.new(0, 1.5, 0)) end)
        end
    end
end

function Skills:OrientToTarget(config: any, target: Player?)
    target = target or self._combat:GetTarget(config)
    if not target then return end

    -- Use the same moving-target prediction as M1.
    local lead = (config.Skills.AutoAim == true and config.Combat.PredictiveAim == true) and 0.10 or 0
    self._combat:FaceTargetForAttack(target, config, lead)

    if lead > 0 then
        local targetPos = self._combat:GetPredictedAimPosition(target, lead)
        local cam = game:GetService("Workspace").CurrentCamera
        if targetPos and cam then
            pcall(function()
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, targetPos + Vector3.new(0, 1.5, 0))
            end)
        end
    end
end

local function getLocalTools(): {Tool}
    local result = {}
    local seen = {}
    local function scan(container: Instance?)
        if not container then return end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") and not seen[child] then
                seen[child] = true
                table.insert(result, child)
            end
        end
    end
    scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    scan(LocalPlayer.Character)
    return result
end

local function readBool(container: Instance?, names: {string}): boolean?
    if not container then return nil end
    for _, name in ipairs(names) do
        local v = container:GetAttribute(name)
        if type(v) == "boolean" then return v end
        local child = container:FindFirstChild(name)
        if child and child:IsA("BoolValue") then return child.Value end
    end
    return nil
end

local function readNumber(container: Instance?, names: {string}): number?
    if not container then return nil end
    for _, name in ipairs(names) do
        local v = container:GetAttribute(name)
        if type(v) == "number" then return v end
        local child = container:FindFirstChild(name)
        if child and (child:IsA("NumberValue") or child:IsA("IntValue")) then return child.Value end
    end
    return nil
end

local function toolCooldownReady(tool: Tool, now: number, runtimeLastUse: number?): boolean
    if tool.Enabled == false then return false end
    local onCooldown = readBool(tool, {"OnCooldown","CooldownActive","IsOnCooldown"})
    if onCooldown == true then return false end
    local ready = readBool(tool, {"Ready","CanUse","Usable"})
    if ready == false then return false end

    local absolute = readNumber(tool, {"CooldownEnd","CooldownUntil","NextUse","ReadyAt"})
    if absolute and absolute > now then return false end
    local duration = readNumber(tool, {"CooldownRemaining","RemainingCooldown"})
    if duration and duration > 0 then return false end
    local cd = readNumber(tool, {"Cooldown","CooldownTime","CD"})
    if cd and cd > 0 and cd <= 60 then
        if type(runtimeLastUse) == "number" and now - runtimeLastUse < cd then return false end
        local observedLast = tool:GetAttribute("LastUsedAt")
        if type(observedLast) == "number" and now - observedLast < cd then return false end
    end
    return true
end

local function markToolUsed(runtimeMap: {[Tool]: number}, tool: Tool, now: number)
    runtimeMap[tool] = now
end

local function getExplicitUltReady(): boolean?
    local char = LocalPlayer.Character
    if not char then return nil end
    for _, container in ipairs({char, LocalPlayer}) do
        for _, name in ipairs({"UltimateReady","AwakeningReady","UltReady","CanAwaken"}) do
            local v = container:GetAttribute(name)
            if type(v) == "boolean" then return v end
        end
    end
    return nil
end

function Skills:GetUsableSkillIndices(): {number}
    local tools = getLocalTools()
    local result = {}
    self._lastSkillTools = {}
    local now = os.clock()

    -- First choice: explicit slot metadata exposed by the game.
    local usedSlots = {}
    for _, tool in ipairs(tools) do
        local slot = tool:GetAttribute("Slot") or tool:GetAttribute("HotbarSlot") or tool:GetAttribute("Index")
        if type(slot) == "number" then
            slot = math.floor(slot)
            if slot >= 1 and slot <= 4 and not usedSlots[slot] and toolCooldownReady(tool, now, self._lastSkillUse[tool]) then
                usedSlots[slot] = true
                self._lastSkillTools[slot] = tool
                table.insert(result, slot)
            end
        end
    end
    if #result > 0 then
        table.sort(result)
        return result
    end

    -- Second choice: map by the character's known four normal skill names.
    -- This avoids inventing alphabetical inventory order and survives backpack ordering changes.
    local state = MoveSetResolver.Resolve(LocalPlayer)
    local profiles = MoveSetResolver.GetProfiles()
    local profile = state and state.Key and profiles[state.Key]
    if profile and #profile.Normal > 0 then
        for slot, skillName in ipairs(profile.Normal) do
            if slot > 4 then break end
            local tool = MoveSetResolver.FindTool(LocalPlayer, skillName)
            if tool and toolCooldownReady(tool, now, self._lastSkillUse[tool]) then
                table.insert(result, slot)
                self._lastSkillTools[slot] = tool
            end
        end
        if #result > 0 then return result end
    end

    -- Last-resort fallback: preserve the live inventory enumeration order.
    -- This cannot know a hidden hotbar's logical slots when the game exposes neither metadata nor names.
    local slotIndex = 0
    for _, tool in ipairs(tools) do
        if slotIndex >= 4 then break end
        slotIndex += 1
        if toolCooldownReady(tool, now, self._lastSkillUse[tool]) then
            table.insert(result, slotIndex)
            self._lastSkillTools[slotIndex] = tool
        end
    end
    return result
end

function Skills:UpdateAutoSkillSpam(config: any)
    local skillsCfg = config and config.Skills
    if not skillsCfg or (skillsCfg.AutoSkillSpam ~= true and skillsCfg.AutoUltSpam ~= true) then return end

    local target = self._combat:GetTarget(config)
    if not target then return end
    local now = os.clock()

    -- Awakening is stateful: never keep pressing G while awakening tools are present.
    if skillsCfg.AutoUltSpam == true and (now - (self.LastUltSpamTick or 0)) >= 0.50 then
        local localState = MoveSetResolver.Resolve(LocalPlayer)
        local explicitReady = getExplicitUltReady()
        if not localState.IsUlt and explicitReady ~= false then
            self.LastUltSpamTick = now
            if skillsCfg.AutoAim == true then
                self:OrientToTarget(config, target)
                self:BeginSkillTracking(target, 0.85, 0.12)
            end
            SafeKeyClick(Enum.KeyCode.G)
        end
    end

    if skillsCfg.AutoSkillSpam == true and (now - self.LastSpamTick) >= (tonumber(skillsCfg.SkillSpamDelay) or 0.25) then
        local localState = MoveSetResolver.Resolve(LocalPlayer)
        if localState.IsUlt then return end
        local indices = self:GetUsableSkillIndices()
        if #indices == 0 then return end
        self.SpamIdx = math.clamp(self.SpamIdx, 1, #self.Keys)
        local chosenIndex = nil
        for _, idx in ipairs(indices) do
            if idx >= self.SpamIdx then chosenIndex = idx; break end
        end
        chosenIndex = chosenIndex or indices[1]
        if chosenIndex then
            self.LastSpamTick = now
            if skillsCfg.AutoAim == true then
                self:OrientToTarget(config, target)
                self:BeginSkillTracking(target, 0.62, 0.11)
            end
            if SafeKeyClick(self.Keys[chosenIndex]) then
                local usedTool = self._lastSkillTools[chosenIndex]
                if usedTool then markToolUsed(self._lastSkillUse, usedTool, now) end
            end
            self.SpamIdx = (chosenIndex % #self.Keys) + 1
        end
    end
end

function Skills:Destroy()
    self._trackTarget = nil
    self._trackRoot = nil
    self._localRoot = nil
    self._localCharacter = nil
    self._trackUntil = 0
    self._trackLastTick = 0
    table.clear(self._lastSkillUse)
    table.clear(self._lastSkillTools)
end

function Skills:UpdateVoidKill(config: any)
    if not config.Skills.VoidKill then return end
    local target = self._combat:GetTarget(config)
    if not target then return end

    local tEntry = self._cache:GetPlayerEntry(target)
    if not tEntry or not tEntry.IsAlive or not tEntry.RootPart then return end

    -- Throttle: only trigger once every 3 seconds
    local now = os.clock()
    if (now - (self._lastVoidKillTick or 0)) < 3 then return end
    self._lastVoidKillTick = now

    local root = tEntry.RootPart
    local originalCFrame = root.CFrame
    local voidDepth = config.Skills.VoidDepth or -350

    pcall(function()
        root.CFrame = CFrame.new(originalCFrame.Position.X, voidDepth, originalCFrame.Position.Z)
    end)

    local returnDelay = config.Skills.VoidReturnDelay or 0.5
    task.delay(returnDelay, function()
        pcall(function()
            -- Only return if still in void and still alive
            if root and root.Parent and root.Position.Y < -100 then
                root.CFrame = originalCFrame
            end
        end)
    end)
end

return Skills

end
__modules["Systems/Skills"] = __modules["Systems.Skills"]

-- ============================================================================
-- Module: Systems.Survival
-- ============================================================================
__modules["Systems.Survival"] = function()
--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Survival = {}
Survival.__index = Survival

function Survival.new(deps: { Cache: any, StateMachine: any, EventBus: any, Logger: any })
    local self = setmetatable({
        _cache = deps.Cache,
        _fsm = deps.StateMachine,
        _eventBus = deps.EventBus,
        _logger = deps.Logger,
        IsDodging = false,
        SavedGroundPos = nil,
        LockedCameraPos = nil,
        LastDodgeTick = 0,
        HasSkyEscaped = false,
        SavedEscapeGround = nil,
        _character = LocalPlayer.Character,
        _characterConnection = nil :: RBXScriptConnection?,
    }, Survival)

    self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(char)
        self:ResetState()
        self._character = char
    end)

    return self
end

function Survival:ResetState()
    self.IsDodging = false
    self.SavedGroundPos = nil
    self.LockedCameraPos = nil
    self.HasSkyEscaped = false
    self.SavedEscapeGround = nil
end

function Survival:Stop()
    self:ResetState()
    if self._fsm.CurrentState == "SKY_DODGE" or self._fsm.CurrentState == "SKY_ESCAPE" then
        self._fsm:TransitionTo("IDLE", nil, "Survival Disabled", "Survival", true)
    end
end

function Survival:Destroy()
    self:Stop()
    if self._characterConnection then
        pcall(function() self._characterConnection:Disconnect() end)
        self._characterConnection = nil
    end
end

function Survival:CheckSkyEscape(config: any)
    if config and config.Movement and config.Movement.Fly == true then return end
    if not config.Survival.SkyTeleport then return end
    if LocalPlayer.Character ~= self._character then
        self:ResetState()
        self._character = LocalPlayer.Character
    end
    local entry = self._cache:GetPlayerEntry(LocalPlayer)
    if not entry or not entry.Humanoid or not entry.RootPart or entry.Humanoid.Health <= 0 then return end

    local hpPct = (entry.Humanoid.Health / entry.Humanoid.MaxHealth) * 100

    if hpPct <= config.Survival.SkyEscapeHP then
        if not self.HasSkyEscaped then
            -- Clean FSM Priority Transition
            if self._fsm:TransitionTo("SKY_ESCAPE") then
                self.HasSkyEscaped = true
                self.SavedEscapeGround = entry.RootPart.CFrame

                local skyY = entry.RootPart.Position.Y + config.Survival.SkyEscapeHeight
                pcall(function()
                    entry.RootPart.CFrame = CFrame.new(entry.RootPart.Position.X, skyY, entry.RootPart.Position.Z)
                    entry.RootPart.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end
    elseif self.HasSkyEscaped and hpPct >= (config.Survival.SkyReturnHP or 80) then
        self.HasSkyEscaped = false
        if self.SavedEscapeGround and entry.RootPart then
            entry.RootPart.CFrame = self.SavedEscapeGround + Vector3.new(0, 3, 0)
        end
        self._fsm:TransitionTo("IDLE")
    end
end

function Survival:UpdateSkyDodge(dt: number, config: any)
    if config and config.Movement and config.Movement.Fly == true then
        if self.IsDodging or self.HasSkyEscaped then self:ResetState() end
        return
    end
    if not config.Survival.SkyDodge or self.HasSkyEscaped then
        if not config.Survival.SkyDodge and self.IsDodging then
            self:ResetState()
        end
        return
    end

    if LocalPlayer.Character ~= self._character then
        self:ResetState()
        self._character = LocalPlayer.Character
    end
    local myEntry = self._cache:GetPlayerEntry(LocalPlayer)
    if not myEntry or not myEntry.RootPart or not myEntry.Humanoid or myEntry.Humanoid.Health <= 0 then return end

    local now = os.clock()
    if (now - (self._lastScanTick or 0)) < 0.10 then return end
    self._lastScanTick = now
    if not self.IsDodging then
        if (now - self.LastDodgeTick) < 0.2 then return end
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            local tEntry = self._cache:GetPlayerEntry(p)
            if not tEntry or not tEntry.IsAlive or not tEntry.RootPart or not tEntry.Animator then continue end

            local dist = (tEntry.RootPart.Position - myEntry.RootPart.Position).Magnitude
            if dist <= config.Survival.SkyDodgeRange then
                local attacking = false
                for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                    local n = (track.Name or ""):lower()
                    if n:find("attack") or n:find("punch") or n:find("strike") or n:find("slash") then
                        attacking = true
                        break
                    end
                end

                if attacking then
                    if self._fsm:TransitionTo("SKY_DODGE") then
                        self.IsDodging = true
                        self.LastDodgeTick = now
                        self.SavedGroundPos = myEntry.RootPart.CFrame
                        self.LockedCameraPos = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or nil

                        local skyY = myEntry.RootPart.Position.Y + config.Survival.SkyDodgeHeight
                        myEntry.RootPart.CFrame = CFrame.new(myEntry.RootPart.Position.X, skyY, myEntry.RootPart.Position.Z)
                        break
                    end
                end
            end
        end
    else
        local anyAttacking = false
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            local tEntry = self._cache:GetPlayerEntry(p)
            if tEntry and tEntry.IsAlive and tEntry.RootPart and self.SavedGroundPos then
                local d = (tEntry.RootPart.Position - self.SavedGroundPos.Position).Magnitude
                if d <= config.Survival.SkyDodgeRange and tEntry.Animator then
                    for _, track in ipairs(tEntry.Animator:GetPlayingAnimationTracks()) do
                        local n = (track.Name or ""):lower()
                        if n:find("attack") or n:find("punch") or n:find("strike") then
                            anyAttacking = true
                            break
                        end
                    end
                end
            end
        end

        if not anyAttacking then
            self.IsDodging = false
            if self.SavedGroundPos and myEntry.RootPart then
                myEntry.RootPart.CFrame = self.SavedGroundPos
            end
            self.SavedGroundPos = nil
            self.LockedCameraPos = nil
            self._fsm:TransitionTo("IDLE")
        end
    end
end

return Survival

end
__modules["Systems/Survival"] = __modules["Systems.Survival"]

-- ============================================================================
-- Module: Systems.MoveSetResolver
-- ============================================================================
__modules["Systems.MoveSetResolver"] = function()
--!strict
local Players = game:GetService("Players")
local MoveSetResolver = {}

local function norm(v: any): string
    return tostring(v or ""):lower():gsub("[^%w]", "")
end

local Profiles = {
    Saitama = {
        Label = "Saitama", ColorKey = "SaitamaESPColor",
        Normal = {"Normal Punch", "Consecutive Punches", "Shove", "Uppercut"},
        Ult = {"Death Counter", "Table Flip", "Serious Punch", "Omni-Directional Punch"},
    },
    Garou = {
        Label = "Garou", ColorKey = "GarouESPColor",
        Normal = {"Flowing Water", "Lethal Whirlwind Stream", "Hunter's Grasp", "Prey's Peril"},
        Ult = {"Water Stream Cutting Fist", "The Final Hunt", "Rock Splitting Fist", "Crushed Rock"},
    },
    MonsterGarou = {
        Label = "Garou (Monster)", ColorKey = "GarouESPColor",
        Normal = {"Doom Dive", "Crowd Buster", "Hammer Heel", "Binding Cloth"},
        Ult = {"Hunter's Mark", "Great Fajin", "God Slayer", "Sky Ripping Fist"},
    },
    Genos = {
        Label = "Genos", ColorKey = "GenosESPColor",
        Normal = {"Machine Gun Blows", "Ignition Burst", "Blitz Shot", "Jet Dive"},
        Ult = {"Thunder Kick", "Speedblitz Dropkick", "Flamewave Cannon", "Incinerate"},
    },
    Sonic = {
        Label = "Sonic", ColorKey = "SonicESPColor",
        Normal = {"Flash Strike", "Whirlwind Kick", "Scatter", "Explosive Shuriken"},
        Ult = {"Twinblade Rush", "Straight On", "Carnage", "Fourfold Flashstrike"},
    },
    MetalBat = {
        Label = "Metal Bat", ColorKey = "MetalBatESPColor",
        Normal = {"Homerun", "Beatdown", "Grand Slam", "Foul Ball"},
        Ult = {"Savage Tornado", "Brutal Beatdown", "Strength Difference", "Death Blow"},
    },
    Atomic = {
        Label = "Atomic Samurai", ColorKey = "AtomicESPColor",
        Normal = {"Quick Slice", "Atmos Cleave", "Pinpoint Cut", "Split Second Counter"},
        Ult = {"Sunset", "Solar Cleave", "Sunrise", "Atomic Slash"},
    },
    Tatsumaki = {
        Label = "Tatsumaki", ColorKey = "TatsumakiESPColor",
        Normal = {"Crushing Pull", "Windstorm Fury", "Stone Coffin", "Expulsive Push"},
        Ult = {"Cosmic Strike", "Psychic Ricochet", "Terrible Tornado", "Sky Snatcher"},
    },
    Suiryu = {
        Label = "Suiryu", ColorKey = "SuiryuESPColor",
        Normal = {"Bullet Barrage", "Vanishing Kick", "Whirlwind Drop", "Head First"},
        Ult = {"Grand Fissure", "Twin Fangs", "Earth Splitting Strike", "Last Breath"},
    },
    ChildEmperor = {
        Label = "Child Emperor", ColorKey = "ChildEmperorESPColor",
        Normal = {"Weboom", "Plasma Cannon", "Trinity Tear", "Twin Burst"},
        Ult = {"Photon Edge", "Photon Dive", "Conquest", "Missiles"},
    },
    ZombieMan = {
        Label = "Zombie Man", ColorKey = "ZombieManESPColor",
        Normal = {"Grave Maker", "Blast Breaker", "Point Blank", "Crossfire"},
        Ult = {},
    },
    Gojo = {
        Label = "Gojo", ColorKey = "GojoESPColor",
        Normal = {"Infinity", "Attract", "Repulse", "Erase"},
        Ult = {},
    },
    KJ = {
        Label = "KJ", ColorKey = "KJESPColor",
        Normal = {"Ravage", "Swift Sweep", "Collateral Ruin", "Spiraling Storm"},
        Ult = {"Stoic Bomb", "20-20-20 Dropkick", "Five Seasons", "Unlimited Flex Works"},
    },
    FrozenSoul = {
        Label = "Frozen Soul", ColorKey = "FrozenSoulESPColor",
        Normal = {"Permafrost", "Frost Forge", "Freezing Path", "Judgement Chain"},
        Ult = {"Sub-Zero Slash Storm"},
    },
}

local function scanTools(player: Player): {[string]: boolean}
    local set = {}
    local function scan(container: Instance?)
        if not container then return end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") then
                set[norm(child.Name)] = true
            end
        end
    end
    scan(player.Character)
    scan(player:FindFirstChildOfClass("Backpack"))
    return set
end

local function matchCount(toolSet: {[string]: boolean}, names: {string}): number
    local count = 0
    for _, name in ipairs(names) do
        if toolSet[norm(name)] then count += 1 end
    end
    return count
end

function MoveSetResolver.GetProfiles()
    return Profiles
end

function MoveSetResolver.Resolve(player: Player?): any
    if not player or not player.Parent then
        return {Key=nil, Label="Unknown", ColorKey="OtherCharacterESPColor", NormalCount=0, UltCount=0, IsUlt=false, Tools={}}
    end

    local tools = scanTools(player)
    local bestKey, bestProfile, bestNormal, bestUlt, bestTotal = nil, nil, 0, 0, 0
    local tiedBest = 0

    for key, profile in pairs(Profiles) do
        local n = matchCount(tools, profile.Normal)
        local u = matchCount(tools, profile.Ult)
        local total = n + u
        if total > bestTotal then
            bestKey, bestProfile, bestNormal, bestUlt, bestTotal = key, profile, n, u, total
            tiedBest = 1
        elseif total > 0 and total == bestTotal then
            tiedBest += 1
        end
    end

    if tiedBest > 1 and bestTotal > 0 then
        return {Key=nil, Label="Unknown", ColorKey="OtherCharacterESPColor", NormalCount=0, UltCount=0, IsUlt=false, Tools=tools}
    end

    -- Require a meaningful signature. One generic tool is not enough except for
    -- profiles that intentionally expose only one unique ultimate (Frozen Soul).
    if not bestProfile then
        return {Key=nil, Label="Unknown", ColorKey="OtherCharacterESPColor", NormalCount=0, UltCount=0, IsUlt=false, Tools=tools}
    end
    local minimum = (#bestProfile.Normal == 0 and #bestProfile.Ult > 0) and 1 or 2
    if bestTotal < minimum then
        local uniqueUltMatch = false
        if bestUlt == 1 then
            local matchedName = nil
            for _, name in ipairs(bestProfile.Ult) do
                local key = norm(name)
                if tools[key] then matchedName = key; break end
            end
            if matchedName then
                local owners = 0
                for _, profile in pairs(Profiles) do
                    for _, name in ipairs(profile.Ult) do
                        if norm(name) == matchedName then owners += 1; break end
                    end
                end
                uniqueUltMatch = owners == 1
            end
        end
        if not uniqueUltMatch then
            return {Key=nil, Label="Unknown", ColorKey="OtherCharacterESPColor", NormalCount=0, UltCount=0, IsUlt=false, Tools=tools}
        end
    end

    return {
        Key = bestKey,
        Label = bestProfile.Label,
        ColorKey = bestProfile.ColorKey,
        NormalCount = bestNormal,
        UltCount = bestUlt,
        IsUlt = bestUlt > 0,
        Tools = tools,
    }
end

function MoveSetResolver.FindTool(player: Player?, wantedName: string): Tool?
    if not player then return nil end
    local wanted = norm(wantedName)
    local containers = {player.Character, player:FindFirstChildOfClass("Backpack")}
    for _, container in ipairs(containers) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and norm(child.Name) == wanted then
                    return child
                end
            end
        end
    end
    return nil
end

return MoveSetResolver
end
__modules["Systems/MoveSetResolver"] = __modules["Systems.MoveSetResolver"]

-- ============================================================================
-- Module: Systems.TelemetryRecorder
-- ============================================================================
__modules["Systems.TelemetryRecorder"] = function()
--!strict
-- =============================================================================
-- TelemetryRecorder v10.0 — Comprehensive Multi-Category Data Collector
-- Normalized, deduplicated, multi-file persistent dataset for all players.
-- =============================================================================
local Players    = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local TelemetryRecorder = {}
TelemetryRecorder.__index = TelemetryRecorder

-- ============================================================================
-- HELPERS
-- ============================================================================
local function countKeys(t: any): number
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end

local function setAdd(s: {[string]: boolean}, val: string)
    s[val] = true
end

local function isBehavioral(name: string): boolean
    local n = name:lower()
    return n:find("holding") ~= nil
        or n:find("blocking") ~= nil
        or n:find("skill") ~= nil
        or n:find("ulted") ~= nil
        or n:find("state") ~= nil
        or n:find("counter") ~= nil
        or n:find("dash") ~= nil
        or n:find("hurt") ~= nil
        or n:find("ragdoll") ~= nil
        or n:find("stun") ~= nil
end

local MoveSetResolver = require("Systems.MoveSetResolver")

local function getCharType(char: any, player: Player?): string
    if player then
        local resolved = MoveSetResolver.Resolve(player)
        if resolved and resolved.Label ~= "Unknown" then return resolved.Label end
    end

    -- Only accept Character attributes that correspond to a known moveset.
    -- Arbitrary labels from unrelated game systems are not character identities.
    if char then
        local attr = char:GetAttribute("Character")
        if type(attr) == "string" and #attr > 0 then
            local wanted = attr:lower():gsub("[^%w]", "")
            for _, profile in pairs(MoveSetResolver.GetProfiles()) do
                local known = tostring(profile.Label):lower():gsub("[^%w]", "")
                if wanted == known then
                    return profile.Label
                end
            end
        end
    end
    return "Unknown"
end

local function getRigType(char: any): string
    if char and char:FindFirstChild("UpperTorso") then
        return "R15"
    end
    return "R6"
end

local function getPath(inst: Instance): string
    local parts = {}
    local cur: Instance? = inst
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, ".")
end

local function JSONEncode(data: any): string
    local ok, result = pcall(function() return HttpService:JSONEncode(data) end)
    if ok then return result end
    return "{}"
end

local function JSONDecode(raw: string): any
    local ok, result = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok then return result end
    return nil
end

local function safeReadFile(path: string): string?
    local ok, result = pcall(function()
        if isfile and isfile(path) then
            return readfile(path)
        end
    end)
    if ok then return result end
    return nil
end

local function safeWriteFile(path: string, content: string): boolean
    if typeof(writefile) ~= "function" then return false end
    local ok = pcall(function() writefile(path, content) end)
    return ok
end

local function safeMakeFolder(path: string): boolean
    if typeof(makefolder) ~= "function" then return false end
    local ok = pcall(function() makefolder(path) end)
    if ok then return true end
    -- Folder may already exist; verify that assumption.
    if typeof(isfolder) == "function" then
        return pcall(function() return isfolder(path) end) and isfolder(path) or false
    end
    return false
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
function TelemetryRecorder.new(deps: { Logger: any, EventBus: any })
    local self = setmetatable({
        _logger    = deps.Logger,
        _eventBus  = deps.EventBus,

        -- Multi-category normalized data store
        Data = {
            Meta = {
                Version           = "10.0",
                Created           = os.time(),
                LastUpdated       = os.time(),
                TotalSessions     = 1,
                FrameworkVersion  = "9.0-SPECIALIST-PRODUCTION",
            },
            Animations    = {},
            Characters    = {},
            Hitboxes      = {},
            Attributes    = {},
            Correlations  = {},
            CombatEvents  = {},  -- ring buffer
            Cooldowns     = {},
            Sounds        = {},
            Tools         = {},
            Remotes       = {},
            Interactions  = {},
            WorldObjects  = {},
            SkillRecon    = { Profiles = {}, Sessions = {} },
            Omni          = {
                Meta = {
                    Version = "1.0",
                    StartedAt = os.time(),
                    EventCount = 0,
                    InstanceCount = 0,
                    NetworkCount = 0,
                    Truncated = 0,
                },
                Events = {},
                Instances = {},
                Network = { Outgoing = {}, Incoming = {} },
                Map = { SnapshotAt = 0, Bounds = nil, Terrain = nil },
            },
            World         = {},
        },

        _connections      = {},
        _playerTrackers   = {},  -- per-player state for correlation/cooldown
        _notifThrottle    = {},  -- key → last notif time
        _isDirty          = false,
        _lastSaveTick     = 0,
        _sessionStart     = os.clock(),
        _isRecording      = false,
        _maxCombatEvents  = 1000,  -- overwritten from config in Update
        _lastRemoteScan   = 0,
        _lastInteractionScan = 0,
        _cfg = nil,
        _activeSkillSessions = {},
        _reconRecentAnimations = {},
        _reconRecentGoals = {},
        _skillSessionSeq = 0,
        _reconLastSample = 0,
        _reconHeartbeat = nil,
        _reconHooksInstalled = false,
        _lastSuccessfulSaveAt = 0,
        _lastSuccessfulSavedRecords = 0,
        _saveInFlight = false,
        _dataRevision = 0,
        _lastSuccessfulSavedRevision = 0,
        _lastSaveError = nil,

        _omniConnections = {},
        _omniInstanceIds = setmetatable({}, { __mode = "k" }),
        _omniNextInstanceId = 1,
        _omniRootConnections = {},
        _omniRunning = false,
        _omniLastSample = 0,
        _omniLastSnapshot = 0,
        _omniLastMapSnapshot = 0,
        _omniDiskBuffer = {},
        _omniLastDiskFlush = 0,
    }, TelemetryRecorder)

    return self
end

function TelemetryRecorder:_MarkDirty()
    self._isDirty = true
    self._dataRevision = (self._dataRevision or 0) + 1
end

-- ============================================================================
-- SKILL_RECON_V14
-- Session-level forensic collector for building an empirical skill database.
-- It records observations; it does not assume or invent release timings.
-- ============================================================================
local RECON_FLAGS={
    "Ragdoll","BeingLaunched","Freeze","ForceField","Counter","HunterCounter",
    "AbsoluteImmortal","AtomicCounter","UpFrames","CanBringUp","BarrageBind",
    "NoRotate","NoJump","NoPunch","NoBlock",
}
local RECON_GENERIC={HoldingM1=true,HoldingSpace=true}
local function rn() return os.clock() end
local function rb(v) if v==true then return true end if type(v)=="string" then return v:lower()=="true" end if type(v)=="number" then return v~=0 end return false end
local function rr(v,d) if type(v)~="number" then return nil end local p=10^(d or 3) return math.floor(v*p+0.5)/p end
local function rv(v) if not v then return nil end return {X=rr(v.X),Y=rr(v.Y),Z=rr(v.Z)} end
local function rp(v) local t=typeof(v) if t=="boolean" or t=="number" or t=="string" then return v end if v==nil then return nil end return tostring(v) end
local function ri(n) local x=tostring(n):lower() return x:find("holding",1,true) or x:find("skill",1,true) or x:find("dash",1,true) or x:find("ragdoll",1,true) or x:find("launch",1,true) or x:find("freeze",1,true) or x:find("counter",1,true) or x:find("stun",1,true) or x:find("target",1,true) or x:find("grab",1,true) or x:find("weld",1,true) or x:find("constraint",1,true) or x:find("velocity",1,true) end

function TelemetryRecorder:_ReconFlags(char)
    local t={} if not char then return t end
    for _,n in ipairs(RECON_FLAGS) do t[n]=char:FindFirstChild(n)~=nil or rb(char:GetAttribute(n)) end
    return t
end
function TelemetryRecorder:_ReconAttrs(char)
    local t={} if not char then return t end
    pcall(function() for n,v in pairs(char:GetAttributes()) do if ri(n) then t[n]=rp(v) end end end)
    return t
end
function TelemetryRecorder:_ReconSnap(char)
    if not char then return nil end
    local h=char:FindFirstChildOfClass("Humanoid") local r=char:FindFirstChild("HumanoidRootPart")
    if not h then return nil end
    return {Health=rr(h.Health,2),MaxHealth=rr(h.MaxHealth,2),State=tostring(h:GetState()),Position=r and rv(r.Position) or nil,Velocity=r and rv(r.AssemblyLinearVelocity) or nil,Speed=r and rr(r.AssemblyLinearVelocity.Magnitude,3) or nil,AutoRotate=h.AutoRotate,WalkSpeed=rr(h.WalkSpeed,2),JumpPower=rr(h.JumpPower,2),PlatformStand=h.PlatformStand,Flags=self:_ReconFlags(char)}
end
function TelemetryRecorder:_ReconSkillName(player,raw)
    local wanted=tostring(raw or ""):gsub("^Holding","")
    local wn=wanted:lower():gsub("[^%w]","")
    for _,c in ipairs({player and player.Character,player and player:FindFirstChildOfClass("Backpack")}) do
        if c then for _,x in ipairs(c:GetChildren()) do if x:IsA("Tool") then local n=x.Name:lower():gsub("[^%w]","") if n==wn then return x.Name end end end end
    end
    local w=wanted:gsub("(%l)(%u)","%1 %2"):gsub("(%a)(%d)","%1 %2")
    return w~="" and w or "Unknown Skill"
end
function TelemetryRecorder:_ReconTarget(attacker,char)
    if not char then return nil,nil,"None" end
    local lh=char:GetAttribute("LastM1Hitted")
    if type(lh)=="string" and lh~="" then
        local name=lh:match("^(.-);;") or lh local live=workspace:FindFirstChild("Live") local tc=live and live:FindFirstChild(name)
        if tc and tc:IsA("Model") then local p=Players:GetPlayerFromCharacter(tc) if p and p~=attacker then return p,tc,"LastM1Hitted" end end
    end
    for _,an in ipairs({"Target","TargetPlayer","TargetCharacter","GrabbedTarget","TargetUserId"}) do
        local v=char:GetAttribute(an)
        if v~=nil then local w=tostring(v)
            for _,p in ipairs(Players:GetPlayers()) do if p~=attacker and (p.Name==w or p.DisplayName==w or tostring(p.UserId)==w) and p.Character then return p,p.Character,"ExplicitAttribute:"..an end end
            local live=workspace:FindFirstChild("Live") local tc=live and live:FindFirstChild(w) if tc and tc:IsA("Model") then local p=Players:GetPlayerFromCharacter(tc) if p and p~=attacker then return p,tc,"ExplicitAttribute:"..an end end
        end
    end
    local root=char:FindFirstChild("HumanoidRootPart") if not root then return nil,nil,"None" end
    local range=math.clamp(tonumber(self._cfg and self._cfg.ReconTargetRange) or 45,15,100) local bp,bc,bd=nil,nil,math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=attacker and p.Character and p.Character.Parent then local r=p.Character:FindFirstChild("HumanoidRootPart") local h=p.Character:FindFirstChildOfClass("Humanoid") if r and h and h.Health>0 then local d=(r.Position-root.Position).Magnitude if d<bd and d<=range then bp,bc,bd=p,p.Character,d end end end
    end
    if bp then return bp,bc,"NearestHeuristic" end return nil,nil,"None"
end
function TelemetryRecorder:_ReconPush(s,typ,data)
    if not s then return end local cap=math.clamp(tonumber(self._cfg and self._cfg.MaxReconEventsPerSession) or 320,80,1000)
    table.insert(s.Events,{T=rr(rn()-s._ClockStart,4),Type=typ,Data=data or {}}) while #s.Events>cap do table.remove(s.Events,1) end
end
function TelemetryRecorder:_ReconSample(s,forced)
    if not s or s.Status~="Active" then return end local max=math.clamp(tonumber(self._cfg and self._cfg.MaxReconSamplesPerSession) or 180,30,500) if #s.Samples>=max and not forced then return end
    local c=s._Character local r=c and c:FindFirstChild("HumanoidRootPart") local h=c and c:FindFirstChildOfClass("Humanoid") if not r or not h then return end
    local tp,tc,src=self:_ReconTarget(s._Player,c) local tr=tc and tc:FindFirstChild("HumanoidRootPart") local th=tc and tc:FindFirstChildOfClass("Humanoid")
    local q={T=rr(rn()-s._ClockStart,4),Attacker={Position=rv(r.Position),Velocity=rv(r.AssemblyLinearVelocity),Speed=rr(r.AssemblyLinearVelocity.Magnitude,3),Health=rr(h.Health,2),State=tostring(h:GetState()),Flags=self:_ReconFlags(c)},TargetSource=src,Target=nil,VoidHeight=rr(workspace.FallenPartsDestroyHeight,2)}
    if tp and tc and tr and th then local d=tr.Position-r.Position q.Target={PlayerName=tp.Name,UserId=tp.UserId,Character=getCharType(tc,tp),Position=rv(tr.Position),Velocity=rv(tr.AssemblyLinearVelocity),Speed=rr(tr.AssemblyLinearVelocity.Magnitude,3),Health=rr(th.Health,2),MaxHealth=rr(th.MaxHealth,2),State=tostring(th:GetState()),Distance=rr(d.Magnitude,3),Relative=rv(d),Flags=self:_ReconFlags(tc)} end
    table.insert(s.Samples,q)
end
function TelemetryRecorder:_ReconCreate(player,char,skill,trigger,tool)
    self._skillSessionSeq+=1 local tp,tc,src=self:_ReconTarget(player,char) local now=rn() local root=char:FindFirstChild("HumanoidRootPart") local ta={}
    if tool then pcall(function() for n,v in pairs(tool:GetAttributes()) do ta[n]=rp(v) end end) end
    local s={SessionId=self._skillSessionSeq,PlayerName=player.Name,UserId=player.UserId,Character=getCharType(char,player),Skill=self:_ReconSkillName(player,skill),ToolName=tool and tool.Name or nil,Trigger=trigger,Status="Active",StartedAt=os.time(),Duration=0,HoldingAttribute=nil,HoldingStart=nil,HoldingEnd=nil,Events={},Samples={},Animations={},Target={InitialPlayerName=tp and tp.Name or nil,InitialUserId=tp and tp.UserId or nil,InitialCharacter=tc and getCharType(tc,tp) or nil,InitialSource=src},Start={Snapshot=self:_ReconSnap(char),Attributes=self:_ReconAttrs(char),Position=root and rv(root.Position) or nil,Velocity=root and rv(root.AssemblyLinearVelocity) or nil,ToolAttributes=ta,ToolEnabled=tool and tool.Enabled or nil,VoidHeight=rr(workspace.FallenPartsDestroyHeight,2)},_ClockStart=now,_Player=player,_Character=char}
    local pre=tonumber(self._cfg and self._cfg.ReconPreWindow) or 1.25
    for _,a in ipairs(self._reconRecentAnimations[player] or {}) do if now-a.T<=pre then table.insert(s.Animations,{T=rr(a.T-now,4),Side="Before",Id=a.Id,Name=a.Name,Length=a.Length,Speed=a.Speed,Priority=a.Priority}) end end
    self:_ReconPush(s,"SkillSessionStart",{Trigger=trigger,Skill=s.Skill,Tool=s.ToolName,TargetSource=src}) self:_ReconSample(s,true)
    return s
end
function TelemetryRecorder:_ReconStartTool(player,char,tool)
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false then return end
    local active=self._activeSkillSessions[player] local now=rn() local s=active and active.Session
    if s and s.Status=="Active" and now-(s._LastToolActivation or 0)<0.20 then s._LastToolActivation=now s.ToolName=tool.Name return s end
    s=self:_ReconCreate(player,char,tool.Name,"Tool.Activated",tool) if not s then return end s._LastToolActivation=now s._ToolWindowUntil=now+math.clamp(tonumber(self._cfg.ReconToolWindow) or 4,1,8)
    self._activeSkillSessions[player]={Session=s} return s
end
function TelemetryRecorder:_ReconHolding(player,char,attr,val)
    if RECON_GENERIC[attr] then return end local active=self._activeSkillSessions[player] local s=active and active.Session local now=rn()
    if rb(val) then
        if not s or s.Status~="Active" or now-(s._ClockStart or now)>1.25 then s=self:_ReconCreate(player,char,attr,"HoldingAttribute",nil) if not s then return end self._activeSkillSessions[player]={Session=s} end
        s.Skill=self:_ReconSkillName(player,attr) s.HoldingAttribute=attr s.HoldingStart=rr(now-s._ClockStart,4) self:_ReconPush(s,"HoldingStart",{Attribute=attr,Value=rp(val)})
    elseif s and s.Status=="Active" and s.HoldingAttribute==attr then
        s.HoldingEnd=rr(now-s._ClockStart,4) self:_ReconPush(s,"HoldingEnd",{Attribute=attr,Value=rp(val)}) self:_ReconEnd(player,"HoldingAttributeEnded")
    end
end
function TelemetryRecorder:_ReconEnd(player,reason)
    local active=self._activeSkillSessions[player] local s=active and active.Session if not s or s.Status~="Active" then return end
    self:_ReconSample(s,true) local d=math.max(0,rn()-s._ClockStart) s.Duration=rr(d,4) or 0 s.EndedAt=os.time() s.Status="Complete" s.EndReason=reason or "SessionEnded"
    s.End={Snapshot=self:_ReconSnap(s._Character),Attributes=self:_ReconAttrs(s._Character),Flags=self:_ReconFlags(s._Character),VoidHeight=rr(workspace.FallenPartsDestroyHeight,2)} self:_ReconPush(s,"SkillRelease",{Reason=s.EndReason,HoldingAttribute=s.HoldingAttribute})
    local key=s.Character.."::"..s.Skill local p=self.Data.SkillRecon.Profiles[key]
    if not p then p={Character=s.Character,Skill=s.Skill,Uses=0,Completed=0,TotalDuration=0,TotalHoldingDuration=0,MinDuration=math.huge,MaxDuration=0,MinHoldingDuration=math.huge,MaxHoldingDuration=0,AvgDuration=0,AvgHoldingDuration=0,AnimationIds={},TargetCharacters={},ReleaseReasons={}} self.Data.SkillRecon.Profiles[key]=p end
    p.Uses+=1 p.Completed+=1 p.TotalDuration+=s.Duration p.MinDuration=math.min(p.MinDuration,s.Duration) p.MaxDuration=math.max(p.MaxDuration,s.Duration) p.AvgDuration=p.TotalDuration/p.Completed
    if s.HoldingStart and s.HoldingEnd then local hold=math.max(0,s.HoldingEnd-s.HoldingStart) p.TotalHoldingDuration+=hold p.MinHoldingDuration=math.min(p.MinHoldingDuration,hold) p.MaxHoldingDuration=math.max(p.MaxHoldingDuration,hold) p.AvgHoldingDuration=p.TotalHoldingDuration/p.Completed end
    if s.Target.InitialCharacter then p.TargetCharacters[s.Target.InitialCharacter]=(p.TargetCharacters[s.Target.InitialCharacter] or 0)+1 end p.ReleaseReasons[s.EndReason]=(p.ReleaseReasons[s.EndReason] or 0)+1 p.LastSeen=os.time()
    for _,a in ipairs(s.Animations) do if a.Id then p.AnimationIds[a.Id]=true end end
    s._Player=nil s._Character=nil s._ClockStart=nil s._LastToolActivation=nil s._ToolWindowUntil=nil
    table.insert(self.Data.SkillRecon.Sessions,s) local max=math.clamp(tonumber(self._cfg and self._cfg.MaxSkillSessions) or 1500,200,8000) while #self.Data.SkillRecon.Sessions>max do table.remove(self.Data.SkillRecon.Sessions,1) end
    self._activeSkillSessions[player]=nil self:_MarkDirty()
end
function TelemetryRecorder:_ReconAnimation(track,player,char)
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false or not track or not track.Animation then return end local id=tostring(track.Animation.AnimationId or "") if id=="" or id=="0" then return end
    local now=rn() local a={T=now,Id=id,Name=track.Name or "",Length=rr(track.Length or 0,4),Speed=rr(track.Speed or 1,3),Priority=tostring(track.Priority or "")} local b=self._reconRecentAnimations[player] or {} self._reconRecentAnimations[player]=b table.insert(b,a) while #b>100 do table.remove(b,1) end
    local active=self._activeSkillSessions[player] local s=active and active.Session if s and s.Status=="Active" then table.insert(s.Animations,{T=rr(now-s._ClockStart,4),Side="Attacker",Id=id,Name=a.Name,Length=a.Length,Speed=a.Speed,Priority=a.Priority}) self:_ReconPush(s,"AnimationPlayed",{Side="Attacker",Id=id,Name=a.Name,TimePosition=rr(track.TimePosition or 0,4)}) end
    for owner,oa in pairs(self._activeSkillSessions) do if owner~=player then local os=oa and oa.Session if os and os.Status=="Active" then local tp,tc=self:_ReconTarget(os._Player,os._Character) if tp==player and tc==char then self:_ReconPush(os,"TargetAnimationPlayed",{Id=id,Name=a.Name,TimePosition=rr(track.TimePosition or 0,4)}) end end end end
end
function TelemetryRecorder:_ReconAttribute(attr,val,player,char)
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false then return end
    if tostring(attr):lower():sub(1,7)=="holding" then self:_ReconHolding(player,char,attr,val) return end
    local active=self._activeSkillSessions[player] local s=active and active.Session if s and s.Status=="Active" then self:_ReconPush(s,"AttributeChanged",{Side="Attacker",Name=attr,Value=rp(val)}) end
    for owner,oa in pairs(self._activeSkillSessions) do if owner~=player then local os=oa and oa.Session if os and os.Status=="Active" then local tp,tc=self:_ReconTarget(os._Player,os._Character) if tp==player and tc==char then self:_ReconPush(os,"TargetAttributeChanged",{Side="Target",Name=attr,Value=rp(val)}) end end end end
end
function TelemetryRecorder:_HookReconTool(tool,player,char)
    if not tool or not tool:IsA("Tool") then return end local key="ReconTool_"..player.UserId.."_"..getPath(tool) if self._connections[key] then pcall(function() self._connections[key]:Disconnect() end) end
    self._connections[key]=tool.Activated:Connect(function() pcall(function() local s=self:_ReconStartTool(player,char,tool) if s then self:_ReconPush(s,"ToolActivated",{Name=tool.Name,Path=getPath(tool),Enabled=tool.Enabled}) end end) end)
end
function TelemetryRecorder:_ReconObject(char,player,kind,inst)
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false or not inst then return end if not ri(inst.Name) and not inst:IsA("WeldConstraint") and not inst:IsA("Weld") and not inst:IsA("AlignPosition") and not inst:IsA("AlignOrientation") and not inst:IsA("LinearVelocity") and not inst:IsA("BodyVelocity") then return end
    local active=self._activeSkillSessions[player] local s=active and active.Session if s and s.Status=="Active" then self:_ReconPush(s,"RuntimeObject"..kind,{Class=inst.ClassName,Name=inst.Name,Path=getPath(inst)}) end
    for owner,oa in pairs(self._activeSkillSessions) do if owner~=player then local os=oa and oa.Session if os and os.Status=="Active" then local tp,tc=self:_ReconTarget(os._Player,os._Character) if tp==player and tc==char then self:_ReconPush(os,"TargetRuntimeObject"..kind,{Class=inst.ClassName,Name=inst.Name,Path=getPath(inst)}) end end end end
end
function TelemetryRecorder:_ReconState(char,player,eventType,data)
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false then return end local active=self._activeSkillSessions[player] local s=active and active.Session if s and s.Status=="Active" then self:_ReconPush(s,eventType,{Side="Attacker",Data=data or {}}) end
    for owner,oa in pairs(self._activeSkillSessions) do if owner~=player then local os=oa and oa.Session if os and os.Status=="Active" then local tp,tc=self:_ReconTarget(os._Player,os._Character) if tp==player and tc==char then self:_ReconPush(os,eventType,{Side="Target",Data=data or {}}) end end end end
end
function TelemetryRecorder:_ReconHeartbeat()
    if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false then return end local hz=math.clamp(tonumber(self._cfg.ReconSampleHz) or 20,5,30) local now=rn()
    if now-(self._reconLastSample or 0)<1/hz then return end self._reconLastSample=now
    for player,active in pairs(self._activeSkillSessions) do local s=active and active.Session if s and s.Status=="Active" then local holding=s.HoldingAttribute~=nil local max=holding and math.clamp(tonumber(self._cfg.ReconMaxSkillDuration) or 12,3,30) or math.clamp(tonumber(self._cfg.ReconToolWindow) or 4,1,8) if now-s._ClockStart>=max then self:_ReconPush(s,"SessionTimeout",{MaxDuration=max,Holding=holding}) self:_ReconEnd(player,holding and "SafetyTimeout" or "ToolWindowExpired") else self:_ReconSample(s,false) end end end
    local pre=tonumber(self._cfg.ReconPreWindow) or 1.25 for player,b in pairs(self._reconRecentAnimations) do for i=#b,1,-1 do if now-(b[i].T or 0)>pre then table.remove(b,i) end end end for player,b in pairs(self._reconRecentGoals) do for i=#b,1,-1 do if now-(b[i].T or 0)>pre then table.remove(b,i) end end end
end
function TelemetryRecorder:_ReconStartHeartbeat()
    if self._reconHeartbeat then return end self._reconHeartbeat=RunService.Heartbeat:Connect(function() pcall(function() self:_ReconHeartbeat() end) end)
end
function TelemetryRecorder:_ReconStopHeartbeat()
    if self._reconHeartbeat then pcall(function() self._reconHeartbeat:Disconnect() end) self._reconHeartbeat=nil end
end
function TelemetryRecorder:_ReconResetRuntime()
    self:_ReconStopHeartbeat() local ps={} for p in pairs(self._activeSkillSessions) do table.insert(ps,p) end for _,p in ipairs(ps) do self:_ReconEnd(p,"RecorderStopped") end table.clear(self._activeSkillSessions) table.clear(self._reconRecentAnimations) table.clear(self._reconRecentGoals)
end


-- ============================================================================
-- OMNI OBSERVER v1.0
-- Maximum practical client-observable capture. Local-only.
-- ============================================================================

local function omniN(v: any, d: number?): number?
    if type(v) ~= "number" then return nil end
    local p = 10 ^ (d or 4)
    return math.floor(v * p + 0.5) / p
end

local function omniV3(v: any)
    if typeof(v) ~= "Vector3" then return nil end
    return {X=omniN(v.X,4),Y=omniN(v.Y,4),Z=omniN(v.Z,4)}
end

local function omniCF(v: any)
    if typeof(v) ~= "CFrame" then return nil end
    local c={v:GetComponents()}
    for i=1,#c do c[i]=omniN(c[i],4) end
    return c
end

local function omniPack(v: any, depth: number?, seen: any?): any
    local d=depth or 0
    if d>12 then return {__type="Truncated",Reason="MaxDepth"} end
    local tv=typeof(v)

    if v==nil or type(v)=="boolean" or type(v)=="string" then return v end
    if type(v)=="number" then return omniN(v,6) end

    if tv=="Instance" then
        local p=""
        pcall(function() p=getPath(v) end)
        return {__type="Instance",Class=v.ClassName,Name=v.Name,Path=p}
    elseif tv=="Vector3" then
        return {__type="Vector3",Value=omniV3(v)}
    elseif tv=="Vector2" then
        return {__type="Vector2",X=omniN(v.X,5),Y=omniN(v.Y,5)}
    elseif tv=="CFrame" then
        return {__type="CFrame",Components=omniCF(v)}
    elseif tv=="Color3" then
        return {__type="Color3",R=omniN(v.R,6),G=omniN(v.G,6),B=omniN(v.B,6)}
    elseif tv=="EnumItem" then
        return {__type="EnumItem",EnumType=tostring(v.EnumType),Name=v.Name,Value=v.Value}
    elseif tv=="BrickColor" then
        return {__type="BrickColor",Name=v.Name,Number=v.Number}
    elseif tv=="UDim2" then
        return {__type="UDim2",XScale=v.X.Scale,XOffset=v.X.Offset,YScale=v.Y.Scale,YOffset=v.Y.Offset}
    elseif tv=="UDim" then
        return {__type="UDim",Scale=v.Scale,Offset=v.Offset}
    elseif tv=="NumberRange" then
        return {__type="NumberRange",Min=v.Min,Max=v.Max}
    elseif tv=="NumberSequence" then
        local o={__type="NumberSequence",Keypoints={}}
        for _,k in ipairs(v.Keypoints) do
            table.insert(o.Keypoints,{Time=k.Time,Value=k.Value,Envelope=k.Envelope})
        end
        return o
    elseif tv=="ColorSequence" then
        local o={__type="ColorSequence",Keypoints={}}
        for _,k in ipairs(v.Keypoints) do
            table.insert(o.Keypoints,{Time=k.Time,Value={R=k.Value.R,G=k.Value.G,B=k.Value.B}})
        end
        return o
    elseif tv=="Ray" then
        return {__type="Ray",Origin=omniV3(v.Origin),Direction=omniV3(v.Direction)}
    elseif tv=="PhysicalProperties" then
        return {__type="PhysicalProperties",Density=v.Density,Friction=v.Friction,Elasticity=v.Elasticity,FrictionWeight=v.FrictionWeight,ElasticityWeight=v.ElasticityWeight}
    end

    if type(v)=="table" then
        seen=seen or {}
        if seen[v] then return {__type="Cycle"} end
        seen[v]=true
        local o,n={},0
        for k,val in pairs(v) do
            n+=1
            if n>1024 then o.__truncated=true break end
            o[tostring(k)]=omniPack(val,d+1,seen)
        end
        seen[v]=nil
        return o
    end

    return {__type=tv,Value=tostring(v)}
end

function TelemetryRecorder:_OmniPush(kind: string, data: any)
    if not self._omniRunning or not self._cfg or self._cfg.RecordOmni==false then return end
    local max=math.clamp(tonumber(self._cfg.OmniMaxEvents) or 50000,5000,200000)
    table.insert(self.Data.Omni.Events,{T=os.clock(),Kind=kind,Data=data or {}})
    while #self.Data.Omni.Events>max do
        table.remove(self.Data.Omni.Events,1)
        self.Data.Omni.Meta.Truncated+=1
    end
    self.Data.Omni.Meta.EventCount+=1

    -- Preserve a raw chronological event stream when the executor exposes
    -- appendfile. This avoids relying exclusively on the bounded in-memory ring.
    if typeof(appendfile)=="function" and self._cfg.OmniRawNDJSON ~= false then
        local okLine,line=pcall(function()
            return HttpService:JSONEncode({
                T=event.T,Kind=event.Kind,Data=event.Data
            })
        end)
        if okLine and line then
            table.insert(self._omniDiskBuffer,line)
        end
        if #self._omniDiskBuffer>=100 or os.clock()-(self._omniLastDiskFlush or 0)>=1 then
            pcall(function()
                safeMakeFolder("tsb_data")
                appendfile("tsb_data/omni_events.ndjson",table.concat(self._omniDiskBuffer,"\\n").."\\n")
            end)
            table.clear(self._omniDiskBuffer)
            self._omniLastDiskFlush=os.clock()
        end
    end

    self:_MarkDirty()
end

function TelemetryRecorder:_OmniFlushRaw()
    if #self._omniDiskBuffer==0 or typeof(appendfile)~="function" then return end
    pcall(function()
        safeMakeFolder("tsb_data")
        appendfile("tsb_data/omni_events.ndjson",table.concat(self._omniDiskBuffer,"\\n").."\\n")
    end)
    table.clear(self._omniDiskBuffer)
    self._omniLastDiskFlush=os.clock()
end

function TelemetryRecorder:_OmniInstanceId(inst: Instance): number
    local id=self._omniInstanceIds[inst]
    if id then return id end
    id=self._omniNextInstanceId
    self._omniNextInstanceId+=1
    self._omniInstanceIds[inst]=id
    self.Data.Omni.Meta.InstanceCount=id
    return id
end

function TelemetryRecorder:_OmniSnapshot(inst: Instance, reason: string)
    local id=self:_OmniInstanceId(inst)
    local rec={
        Id=id, Class=inst.ClassName, Name=inst.Name, Reason=reason, Path="",
        Attributes={}, Props={}
    }
    pcall(function() rec.Path=getPath(inst) end)
    rec.Tags={}
    pcall(function()
        for _,tag in ipairs(game:GetService("CollectionService"):GetTags(inst)) do
            table.insert(rec.Tags,tag)
        end
    end)
    pcall(function()
        for n,v in pairs(inst:GetAttributes()) do
            rec.Attributes[n]=omniPack(v)
        end
    end)

    local function read(p)
        local ok,v=pcall(function() return (inst :: any)[p] end)
        if ok then rec.Props[p]=omniPack(v) end
    end

    if inst:IsA("BasePart") then
        for _,p in ipairs({"CFrame","Position","Orientation","Size","AssemblyLinearVelocity","AssemblyAngularVelocity","Anchored","CanCollide","CanTouch","CanQuery","Massless","Transparency","Reflectance","Material","Color","CollisionGroup","CustomPhysicalProperties"}) do read(p) end
    elseif inst:IsA("Humanoid") then
        for _,p in ipairs({"Health","MaxHealth","WalkSpeed","JumpPower","AutoRotate","PlatformStand","HipHeight","RigType","Sit","MoveDirection","FloorMaterial","UseJumpPower"}) do read(p) end
    elseif inst:IsA("ValueBase") then
        read("Value")
    elseif inst:IsA("Tool") then
        for _,p in ipairs({"Enabled","RequiresHandle","CanBeDropped","Grip","ToolTip"}) do read(p) end
    elseif inst:IsA("Sound") then
        for _,p in ipairs({"SoundId","Volume","PlaybackSpeed","TimePosition","Playing","Looped","RollOffMaxDistance","RollOffMinDistance","EmitterSize"}) do read(p) end
    elseif inst:IsA("Animation") then
        read("AnimationId")
    elseif inst:IsA("GuiObject") then
        for _,p in ipairs({"Visible","Position","Size","AbsolutePosition","AbsoluteSize","AnchorPoint","Rotation","BackgroundTransparency","ZIndex"}) do read(p) end
    elseif inst:IsA("ScreenGui") then
        for _,p in ipairs({"Enabled","DisplayOrder","IgnoreGuiInset","ResetOnSpawn"}) do read(p) end
    elseif inst:IsA("ParticleEmitter") then
        for _,p in ipairs({"Enabled","Rate","Lifetime","Speed","Spread","Rotation","Transparency","Size","Texture","LightEmission","LightInfluence"}) do read(p) end
    elseif inst:IsA("Trail") then
        for _,p in ipairs({"Enabled","Lifetime","MinLength","Transparency","Color","Texture"}) do read(p) end
    elseif inst:IsA("Beam") then
        for _,p in ipairs({"Enabled","Width0","Width1","Texture","TextureLength","TextureSpeed","Transparency","Color"}) do read(p) end
    end

    self.Data.Omni.Instances[tostring(id)]=rec
end

function TelemetryRecorder:_OmniHookInstance(inst: Instance)
    if not inst or self._omniConnections[inst] then return end
    self:_OmniSnapshot(inst,"Hook")

    local cs={}
    if self._cfg.OmniHookAllChanged~=false then
        local ok,c=pcall(function()
            return inst.Changed:Connect(function(prop)
                if not self._omniRunning then return end
                local value
                pcall(function() value=(inst :: any)[prop] end)
                self:_OmniPush("PropertyChanged",{
                    Id=self:_OmniInstanceId(inst),
                    Class=inst.ClassName,Name=inst.Name,
                    Property=tostring(prop),Value=omniPack(value)
                })
            end)
        end)
        if ok and c then table.insert(cs,c) end
    end

    pcall(function()
        local c=inst.AttributeChanged:Connect(function(attr)
            local value
            pcall(function() value=inst:GetAttribute(attr) end)
            self:_OmniPush("AttributeChanged",{
                Id=self:_OmniInstanceId(inst),
                Class=inst.ClassName,Name=inst.Name,
                Attribute=tostring(attr),Value=omniPack(value)
            })
        end)
        table.insert(cs,c)
    end)

    if inst:IsA("ValueBase") then
        pcall(function()
            table.insert(cs,inst.Changed:Connect(function(value)
                self:_OmniPush("ValueChanged",{
                    Id=self:_OmniInstanceId(inst),Class=inst.ClassName,Name=inst.Name,
                    Value=omniPack(value)
                })
            end))
        end)
    end

    self._omniConnections[inst]=cs
end

function TelemetryRecorder:_OmniUnhookInstance(inst: Instance)
    local cs=self._omniConnections[inst]
    if cs then
        for _,c in ipairs(cs) do pcall(function() c:Disconnect() end) end
        self._omniConnections[inst]=nil
    end
end

function TelemetryRecorder:_OmniHookRoot(root: Instance)
    if not root or self._omniRootConnections[root] then return end

    pcall(function()
        self:_OmniHookInstance(root)
        for _,inst in ipairs(root:GetDescendants()) do
            self:_OmniHookInstance(inst)
        end
    end)

    local add=root.DescendantAdded:Connect(function(inst)
        if not self._omniRunning then return end
        pcall(function()
            self:_OmniHookInstance(inst)
            self:_OmniPush("InstanceAdded",{
                Id=self:_OmniInstanceId(inst),
                Class=inst.ClassName,Name=inst.Name,Path=getPath(inst)
            })
        end)
    end)

    local rem=root.DescendantRemoving:Connect(function(inst)
        if not self._omniRunning then return end
        pcall(function()
            self:_OmniPush("InstanceRemoving",{
                Id=self:_OmniInstanceId(inst),
                Class=inst.ClassName,Name=inst.Name,Path=getPath(inst),
                Final=self.Data.Omni.Instances[tostring(self:_OmniInstanceId(inst))]
            })
            self:_OmniUnhookInstance(inst)
        end)
    end)

    self._omniRootConnections[root]={add,rem}
end

function TelemetryRecorder:_OmniPlayerSnapshot()
    local out={}
    for _,p in ipairs(Players:GetPlayers()) do
        local c=p.Character
        local h=c and c:FindFirstChildOfClass("Humanoid")
        local r=c and (c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso") or c:FindFirstChild("UpperTorso"))
        table.insert(out,{
            Name=p.Name,DisplayName=p.DisplayName,UserId=p.UserId,
            Character=c and getCharType(c,p) or nil,
            Position=r and omniV3(r.Position) or nil,
            CFrame=r and omniCF(r.CFrame) or nil,
            LinearVelocity=r and omniV3(r.AssemblyLinearVelocity) or nil,
            AngularVelocity=r and omniV3(r.AssemblyAngularVelocity) or nil,
            Health=h and omniN(h.Health,2) or nil,
            MaxHealth=h and omniN(h.MaxHealth,2) or nil,
            State=h and tostring(h:GetState()) or nil,
        })
    end
    local cam=workspace.CurrentCamera
    self:_OmniPush("PlayersSnapshot",{
        Players=out,
        Camera=cam and {CFrame=omniCF(cam.CFrame),FieldOfView=omniN(cam.FieldOfView,2),Viewport={X=cam.ViewportSize.X,Y=cam.ViewportSize.Y}} or nil,
        VoidHeight=omniN(workspace.FallenPartsDestroyHeight,2)
    })
end

function TelemetryRecorder:_OmniMapSnapshot()
    if self._cfg.OmniCaptureMap==false then return end
    local minV=Vector3.new(math.huge,math.huge,math.huge)
    local maxV=Vector3.new(-math.huge,-math.huge,-math.huge)
    local parts=0
    for _,inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("BasePart") then
            local p=inst.Position
            local h=inst.Size*0.5
            minV=Vector3.new(math.min(minV.X,p.X-h.X),math.min(minV.Y,p.Y-h.Y),math.min(minV.Z,p.Z-h.Z))
            maxV=Vector3.new(math.max(maxV.X,p.X+h.X),math.max(maxV.Y,p.Y+h.Y),math.max(maxV.Z,p.Z+h.Z))
            parts+=1
        end
    end
    local map=self.Data.Omni.Map
    map.SnapshotAt=os.time()
    map.Bounds={Min=omniV3(minV),Max=omniV3(maxV),BasePartCount=parts}
    local terrain=workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        local meta={Present=true,MaxExtents=nil,CellSize=tonumber(self._cfg.OmniTerrainCellSize) or 4,EstimatedCells=0,CapturedCells=0,NonEmpty={},Truncated=false}
        pcall(function()
            local r=terrain.MaxExtents
            meta.MaxExtents={Min={X=r.Min.X,Y=r.Min.Y,Z=r.Min.Z},Max={X=r.Max.X,Y=r.Max.Y,Z=r.Max.Z}}
        end)
        if self._cfg.OmniCaptureTerrain~=false and meta.MaxExtents then
            local a,b=meta.MaxExtents.Min,meta.MaxExtents.Max
            local cell=math.max(2,tonumber(self._cfg.OmniTerrainCellSize) or 4)
            local sx,sy,sz=math.max(0,b.X-a.X)/cell,math.max(0,b.Y-a.Y)/cell,math.max(0,b.Z-a.Z)/cell
            local cells=math.floor(sx*sy*sz+0.5)
            meta.EstimatedCells=cells
            local cap=tonumber(self._cfg.OmniTerrainMaxCells) or 250000
            if cells>0 and cells<=cap then
                local ok,mats,occ=pcall(function()
                    local region=Region3.new(
                        Vector3.new(a.X,a.Y,a.Z),
                        Vector3.new(b.X,b.Y,b.Z)
                    )
                    return terrain:ReadVoxels(region:ExpandToGrid(cell),cell)
                end)
                if ok and mats and occ then
                    meta.CapturedCells=cells
                    for x=1,#mats do
                        for y=1,#mats[x] do
                            for z=1,#mats[x][y] do
                                local o=occ[x][y][z]
                                if o and o>0 then
                                    table.insert(meta.NonEmpty,{X=x,Y=y,Z=z,Material=tostring(mats[x][y][z]),Occupancy=o})
                                end
                            end
                        end
                    end
                end
            else
                meta.Truncated=true
            end
        end
        map.Terrain=meta
    else
        map.Terrain={Present=false}
    end
    self:_OmniPush("MapSnapshot",map)
end

function TelemetryRecorder:_OmniNetworkHooks()
    if not self._eventBus then return end
    if self._connections["OmniIncomingRemote"] then return end

    self._connections["OmniIncomingRemote"]=self._eventBus:Subscribe(
        "Network.IncomingRemote",
        function(info,args)
            if not self._omniRunning then return end
            local list=self.Data.Omni.Network.Incoming
            table.insert(list,{T=os.clock(),Remote=info,Args=args})
            local max=math.clamp(tonumber(self._cfg.OmniMaxNetworkRecords) or 20000,1000,100000)
            while #list>max do table.remove(list,1) end
            self:_OmniPush("NetworkIncoming",{Remote=info,Args=args})
        end
    )

    self._connections["OmniOutgoingRemote"]=self._eventBus:Subscribe(
        "Network.OutgoingAny",
        function(info,method,args)
            if not self._omniRunning then return end
            local list=self.Data.Omni.Network.Outgoing
            table.insert(list,{T=os.clock(),Remote=info,Method=method,Args=args})
            local max=math.clamp(tonumber(self._cfg.OmniMaxNetworkRecords) or 20000,1000,100000)
            while #list>max do table.remove(list,1) end
            self:_OmniPush("NetworkOutgoing",{Remote=info,Method=method,Args=args})
        end
    )
end

function TelemetryRecorder:_OmniStart()
    if self._omniRunning or not self._cfg or self._cfg.RecordOmni==false then return end
    self._omniRunning=true
    self._omniDiskBuffer={}
    self:_OmniNetworkHooks()

    local roots={game,workspace,LocalPlayer}
    pcall(function() table.insert(roots,game:GetService("CoreGui")) end)
    pcall(function() table.insert(roots,LocalPlayer:FindFirstChildOfClass("PlayerGui")) end)
    for _,root in ipairs(roots) do if root then pcall(function() self:_OmniHookRoot(root) end) end end

    self:_OmniPlayerSnapshot()
    self:_OmniMapSnapshot()
    self._omniLastSample=os.clock()
    self._omniLastSnapshot=os.clock()

    if not self._omniHeartbeat then
        self._omniHeartbeat=RunService.Heartbeat:Connect(function()
            if not self._omniRunning then return end
            local now=os.clock()
            local hz=math.clamp(tonumber(self._cfg.OmniPlayerSampleHz) or 20,2,30)
            if now-(self._omniLastSample or 0)>=1/hz then
                self._omniLastSample=now
                pcall(function() self:_OmniPlayerSnapshot() end)
            end
            local si=math.clamp(tonumber(self._cfg.OmniSnapshotInterval) or 60,10,600)
            if now-(self._omniLastSnapshot or 0)>=si then
                self._omniLastSnapshot=now
                task.spawn(function() pcall(function() self:_OmniMapSnapshot() end) end)
            end
        end)
    end

    self:_OmniPush("OmniStarted",{Roots=#roots})
end

function TelemetryRecorder:_OmniStop()
    self._omniRunning=false
    self:_OmniFlushRaw()
    if self._omniHeartbeat then pcall(function() self._omniHeartbeat:Disconnect() end) self._omniHeartbeat=nil end
    for root,cs in pairs(self._omniRootConnections) do
        for _,c in ipairs(cs) do pcall(function() c:Disconnect() end) end
        self._omniRootConnections[root]=nil
    end
    for inst in pairs(self._omniConnections) do self:_OmniUnhookInstance(inst) end
end

-- ============================================================================
-- NOTIFICATION THROTTLE
-- ============================================================================
function TelemetryRecorder:SendNotification(key: string, title: string, msg: string, duration: number?, kind: any?)
    local now = os.clock()
    if (now - (self._notifThrottle[key] or 0)) < 2 then return end
    self._notifThrottle[key] = now
    self._eventBus:Publish("Notification.Show", title, msg, duration or 3.0, kind or "Info")
end

-- ============================================================================
-- ANIMATION RECORDING
-- ============================================================================
function TelemetryRecorder:RecordAnimation(track: AnimationTrack, player: Player, char: any)
    if self._cfg and self._cfg.RecordSkillRecon ~= false then pcall(function() self:_ReconAnimation(track,player,char) end) end
    if self._cfg and self._cfg.RecordAnimations == false then return end
    if not track or not track.Animation then return end
    local animId = tostring(track.Animation.AnimationId or "")
    if animId == "" or animId == "0" then return end

    local charType = getCharType(char, player)
    local playerName = player.Name

    local now = os.time()
    local record = self.Data.Animations[animId]
    if not record then
        record = {
            Id              = animId,
            RawUrl          = animId,
            Name            = track.Name or "",
            Length          = track.Length or 0,
            Priority        = tostring(track.Priority or ""),
            Looped          = track.Looped or false,
            Speed           = track.Speed or 1,
            FirstSeen       = now,
            LastSeen        = now,
            PlayCount       = 0,
            TotalPlaytime   = 0,
            PlayersSeen     = {},
            CharactersSeen  = {},
        }
        self.Data.Animations[animId] = record
    end

    record.PlayCount += 1
    record.LastSeen = now
    record.TotalPlaytime += (track.Length or 0)
    setAdd(record.PlayersSeen, playerName)
    setAdd(record.CharactersSeen, charType)

    -- Link to character profile
    if self.Data.Characters[charType] then
        setAdd(self.Data.Characters[charType].AnimationsSeen, animId)
    end

    self:_MarkDirty()
end

-- ============================================================================
-- CHARACTER PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordCharacterProfile(char: any, player: Player)
    if self._cfg and self._cfg.RecordCharacters == false then return end
    if not char then return end
    local charType = getCharType(char, player)
    local rigType = getRigType(char)
    local now = os.time()

    local record = self.Data.Characters[charType]
    if not record then
        local attrList = {}
        pcall(function()
            for attrName, _ in pairs(char:GetAttributes()) do
                attrList[attrName] = true
            end
        end)
        record = {
            CharacterType  = charType,
            RigType        = rigType,
            PartCount      = 0,
            Attributes     = attrList,
            AnimationsSeen = {},
            FirstSeen      = now,
            LastSeen       = now,
            ObservedCount  = 0,
            PlayersSeen    = {},
        }
        self.Data.Characters[charType] = record
    end

    record.ObservedCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)

    -- Update part count
    local partCount = 0
    pcall(function()
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("BasePart") then partCount += 1 end
        end
    end)
    record.PartCount = partCount

    self:_MarkDirty()
end

-- ============================================================================
-- HITBOX PROFILE RECORDING
-- ============================================================================
function TelemetryRecorder:RecordHitboxProfile(char: any, player: Player)
    if self._cfg and self._cfg.RecordHitboxes == false then return end
    if not char then return end
    local charType = getCharType(char, player)
    local rigType = getRigType(char)
    local now = os.time()

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local hrpPos = hrp.Position

    local record = self.Data.Hitboxes[charType]
    local shouldUpdate = not record or record.SampleCount == 0

    if not record then
        record = {
            CharacterType = charType,
            RigType       = rigType,
            Parts         = {},
            FirstSeen     = now,
            LastSeen      = now,
            SampleCount   = 0,
        }
        self.Data.Hitboxes[charType] = record
    end

    if shouldUpdate then
        -- Record all BaseParts
        pcall(function()
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    local rel = part.Position - hrpPos
                    record.Parts[part.Name] = {
                        Size             = { X = part.Size.X, Y = part.Size.Y, Z = part.Size.Z },
                        RelativePosition = { X = math.floor(rel.X * 100) / 100, Y = math.floor(rel.Y * 100) / 100, Z = math.floor(rel.Z * 100) / 100 },
                        CanCollide       = part.CanCollide,
                        Mass             = part.Mass,
                        Transparency     = part.Transparency,
                        Class            = part.ClassName,
                    }
                end
            end
        end)
    end

    record.SampleCount += 1
    record.LastSeen = now
    self:_MarkDirty()
end

-- ============================================================================
-- ATTRIBUTE RECORDING + CORRELATION
-- ============================================================================
function TelemetryRecorder:RecordAttribute(attrName: string, value: any, player: Player, char: any)
    if not attrName then return end
    if self._cfg and self._cfg.RecordSkillRecon ~= false then pcall(function() self:_ReconAttribute(attrName,value,player,char) end) end
    if self._cfg and self._cfg.RecordAttributes == false then return end
    local charType = getCharType(char, player)
    local now = os.time()

    local record = self.Data.Attributes[attrName]
    if not record then
        record = {
            Name           = attrName,
            ValueType      = typeof(value),
            ObservedValues = {},
            FirstSeen      = now,
            LastSeen       = now,
            ChangeCount    = 0,
            PlayersSeen    = {},
            CharactersSeen = {},
            IsBehavioral   = isBehavioral(attrName),
        }
        self.Data.Attributes[attrName] = record
    end

    record.ChangeCount += 1
    record.LastSeen = now
    setAdd(record.PlayersSeen, player.Name)
    setAdd(record.CharactersSeen, charType)

    -- Normalize observed values (handle different types)
    local valKey = tostring(value)
    if #valKey <= 32 then
        record.ObservedValues[valKey] = true
    end

    -- Track cooldown: time since last change
    if record.IsBehavioral then
        self:TrackCooldown(charType, attrName, player)
    end

    -- Correlation: check animations playing within 500ms
    self:CheckCorrelation(attrName, player)

    self:_MarkDirty()
end

-- ============================================================================
-- COOLDOWN ANALYSIS
-- ============================================================================
function TelemetryRecorder:TrackCooldown(charType: string, eventKey: string, player: Player?)
    if self._cfg and self._cfg.RecordCooldowns == false then return end
    local now = os.clock()
    local playerKey = player and tostring(player.UserId) or "0"
    local trackerKey = playerKey .. "_" .. charType .. "_" .. eventKey
    local lastTime = self._playerTrackers[trackerKey]

    if lastTime then
        local interval = now - lastTime
        -- Only meaningful intervals (0.01s to 60s)
        if interval >= 0.01 and interval <= 60 then
            if not self.Data.Cooldowns[charType] then
                self.Data.Cooldowns[charType] = {}
            end
            local cd = self.Data.Cooldowns[charType][eventKey]
            if not cd then
                cd = { Min = math.huge, Max = 0, Avg = 0, Samples = {}, Count = 0 }
                self.Data.Cooldowns[charType][eventKey] = cd
            end
            cd.Count += 1
            if interval < cd.Min then cd.Min = interval end
            if interval > cd.Max then cd.Max = interval end
            table.insert(cd.Samples, math.floor(interval * 1000))  -- store in ms
            if #cd.Samples > 30 then table.remove(cd.Samples, 1) end
            -- Rolling average from samples
            local sum = 0
            for _, s in ipairs(cd.Samples) do sum += s end
            cd.Avg = math.floor(sum / #cd.Samples)
        end
    end
    self._playerTrackers[trackerKey] = now
end

-- ============================================================================
-- CORRELATION DETECTION
-- ============================================================================
function TelemetryRecorder:CheckCorrelation(attrName: string, player: Player)
    if self._cfg and self._cfg.RecordCorrelations == false then return end
    if not self.Data.Attributes[attrName] or not self.Data.Attributes[attrName].IsBehavioral then return end

    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local anim = hum:FindFirstChildOfClass("Animator")
    if not anim then return end

    local now = os.time()
    local tracks = {}
    pcall(function() tracks = anim:GetPlayingAnimationTracks() end)

    for _, track in ipairs(tracks) do
        if not track.Animation then continue end
        local animId = tostring(track.Animation.AnimationId or "")
        if animId == "" or animId == "0" then continue end
        local corrKey = animId .. "_" .. attrName
        local corr = self.Data.Correlations[corrKey]
        if not corr then
            corr = {
                AnimationId     = animId,
                AttributeName   = attrName,
                CoOccurrenceCount = 0,
                WindowMs        = 500,
                FirstSeen       = now,
                LastSeen        = now,
            }
            self.Data.Correlations[corrKey] = corr
        end
        corr.CoOccurrenceCount += 1
        corr.LastSeen = now
    end
end

-- ============================================================================
-- COMBAT EVENT RECORDING (ring buffer)
-- ============================================================================
function TelemetryRecorder:RecordCombatEvent(eventType: string, player: Player?, char: any?, details: any?)
    if self._cfg and self._cfg.RecordCombatEvents == false then return end
    local now = os.time()
    local charType = char and getCharType(char, player) or "Unknown"
    local playerName = player and player.Name or "Unknown"

    -- Get current animation and position from player
    local currentAnimation = nil
    local position = nil
    local velocity = nil
    pcall(function()
        if char then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                position = { X = math.floor(hrp.Position.X), Y = math.floor(hrp.Position.Y), Z = math.floor(hrp.Position.Z) }
                velocity = math.floor(hrp.AssemblyLinearVelocity.Magnitude * 10) / 10
            end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                local tracks = anim:GetPlayingAnimationTracks()
                if tracks and #tracks > 0 and tracks[1].Animation then
                    currentAnimation = tostring(tracks[1].Animation.AnimationId)
                end
            end
        end
    end)

    local event = {
        Type             = eventType,
        Timestamp        = now,
        Player           = playerName,
        Character        = charType,
        Position         = position,
        Velocity         = velocity,
        CurrentAnimation = currentAnimation,
        Details          = details or {},
    }

    table.insert(self.Data.CombatEvents, event)
    -- Enforce ring buffer limit
    local maxEv = self._maxCombatEvents
    while #self.Data.CombatEvents > maxEv do
        table.remove(self.Data.CombatEvents, 1)
    end

    self:_MarkDirty()
end

-- ============================================================================
-- SOUND RECORDING
-- ============================================================================
function TelemetryRecorder:RecordSound(sound: any, player: Player, char: any)
    if self._cfg and self._cfg.RecordSounds == false then return end
    if not sound or not sound:IsA("Sound") then return end
    local soundId = tostring(sound.SoundId or "")
    if soundId == "" or soundId == "0" then return end
    local charType = getCharType(char, player)
    local now = os.time()

    local record = self.Data.Sounds[soundId]
    if not record then
        record = {
            Id             = soundId,
            Name           = sound.Name or "",
            Volume         = sound.Volume or 0.5,
            PlaybackSpeed  = sound.PlaybackSpeed or 1,
            CharactersSeen = {},
            PlayersSeen    = {},
            PlayCount      = 0,
            FirstSeen      = now,
            LastSeen       = now,
        }
        self.Data.Sounds[soundId] = record
    end

    record.PlayCount += 1
    record.LastSeen = now
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self:_MarkDirty()
end

-- ============================================================================
-- TOOL / ACCESSORY / ATTACHMENT RECORDING
-- ============================================================================
function TelemetryRecorder:RecordTool(inst: any, player: Player, char: any)
    if self._cfg and self._cfg.RecordTools == false then return end
    if not inst then return end
    local name = inst.Name or "Unknown"
    local class = inst.ClassName or "Unknown"
    local charType = getCharType(char, player)
    local now = os.time()
    local key = class .. "_" .. name

    local record = self.Data.Tools[key]
    if not record then
        record = {
            Name           = name,
            Class          = class,
            CharactersSeen = {},
            PlayersSeen    = {},
            Count          = 0,
            FirstSeen      = now,
            LastSeen       = now,
            Attributes     = {},
        }
        self.Data.Tools[key] = record
    end

    record.Count += 1
    record.LastSeen = now
    pcall(function()
        for attrName, value in pairs(inst:GetAttributes()) do
            record.Attributes[attrName] = tostring(value)
        end
    end)
    setAdd(record.CharactersSeen, charType)
    setAdd(record.PlayersSeen, player.Name)
    self:_MarkDirty()
end

-- ============================================================================
-- REMOTE DISCOVERY SCAN
-- ============================================================================
function TelemetryRecorder:ScanRemotes()
    if self._cfg
        and self._cfg.RecordRemotes == false
        and self._cfg.RecordOmni ~= true then
        return
    end
    local now = os.time()
    local scanTargets = { game:GetService("ReplicatedStorage") }

    for _, root in ipairs(scanTargets) do
        pcall(function()
            for _, desc in ipairs(root:GetDescendants()) do
                if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") or desc:IsA("BindableEvent") then
                    local path = getPath(desc)
                    local record = self.Data.Remotes[path]
                    if not record then
                        record = {
                            Name      = desc.Name,
                            Class     = desc.ClassName,
                            Path      = path,
                            FirstSeen = now,
                            LastSeen  = now,
                        }
                        self.Data.Remotes[path] = record
                    else
                        record.LastSeen = now
                    end

                    if desc:IsA("RemoteEvent")
                        and self._cfg and self._cfg.OmniCaptureRemoteIncoming ~= false
                        and not self._connections["OmniIn_"..path] then
                        local key="OmniIn_"..path
                        self._connections[key]=desc.OnClientEvent:Connect(function(...)
                            local args={...}
                            self._eventBus:Publish("Network.IncomingRemote",
                                {Name=desc.Name,Class=desc.ClassName,Path=path},args)
                        end)
                    end
                end
            end
        end)
    end

    self:_MarkDirty()
end

-- ============================================================================
-- HOOK CHARACTER (called for each player's character)
-- ============================================================================
function TelemetryRecorder:HookCharacter(player: Player, char: any)
    if not self._isRecording or not char then return end
    -- Wait for character to fully load
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        pcall(function()
            hrp = char:WaitForChild("HumanoidRootPart", 10)
        end)
        if not hrp then return end
    end

    local charType = getCharType(char, player)

    -- Record static profiles
    self:RecordCharacterProfile(char, player)
    self:RecordHitboxProfile(char, player)

    -- Hook AttributeChanged
    local attrConn = char.AttributeChanged:Connect(function(attrName: string)
        if not self._isRecording then return end
        pcall(function()
            local val = char:GetAttribute(attrName)
            self:RecordAttribute(attrName, val, player, char)
        end)
    end)
    local connKey = "AttrChanged_" .. player.UserId
    if self._connections[connKey] then
        pcall(function() self._connections[connKey]:Disconnect() end)
    end
    self._connections[connKey] = attrConn

    -- Do initial attribute scan
    pcall(function()
        for attrName, val in pairs(char:GetAttributes()) do
            self:RecordAttribute(attrName, val, player, char)
        end
    end)

    -- Hook HealthChanged
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local healthConn = hum.HealthChanged:Connect(function(newHp: number)
            if not self._isRecording then return end
            self:RecordCombatEvent("HealthChange", player, char, { HP = math.floor(newHp) })
        end)
        local hKey = "Health_" .. player.UserId
        if self._connections[hKey] then pcall(function() self._connections[hKey]:Disconnect() end) end
        self._connections[hKey] = healthConn

        -- Hook StateChanged for ragdoll events
        local stateConn = hum.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType)
            if not self._isRecording then return end
            if newState == Enum.HumanoidStateType.Physics or newState == Enum.HumanoidStateType.FallingDown then
                self:RecordCombatEvent("RagdollEntered", player, char, { State = tostring(newState) })
            elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.Landed then
                self:RecordCombatEvent("RagdollWakeup", player, char, { State = tostring(newState) })
            end
            pcall(function() self:_ReconState(char,player,"HumanoidStateChanged",{State=tostring(newState)}) end)
        end)
        local sKey = "State_" .. player.UserId
        if self._connections[sKey] then pcall(function() self._connections[sKey]:Disconnect() end) end
        self._connections[sKey] = stateConn
    end

    -- Hook Animator for animation events
    local anim = hum and hum:FindFirstChildOfClass("Animator")
    if anim then
        local animConn = anim.AnimationPlayed:Connect(function(track: AnimationTrack)
            if not self._isRecording then return end
            pcall(function() self:RecordAnimation(track, player, char) end)
        end)
        local aKey = "Anim_" .. player.UserId
        if self._connections[aKey] then pcall(function() self._connections[aKey]:Disconnect() end) end
        self._connections[aKey] = animConn
    end

    -- Live tool/skill and sound discovery. Skill Tools are the primary source for
    -- character identification elsewhere in the hub, so inventory changes must be
    -- observable rather than sampled only once at spawn.
    local function hookContainer(container: Instance?)
        if not container then return end
        for _, desc in ipairs(container:GetChildren()) do
            if desc:IsA("Tool") or desc:IsA("Accessory") then
                self:RecordTool(desc, player, char)
                if desc:IsA("Tool") then self:_HookReconTool(desc,player,char) end
            elseif desc:IsA("Sound") then
                self:RecordSound(desc, player, char)
            end
        end
        local addKey="ContainerAdded_"..player.UserId.."_"..container.Name
        if self._connections[addKey] then pcall(function() self._connections[addKey]:Disconnect() end) end
        self._connections[addKey]=container.ChildAdded:Connect(function(inst)
            if not self._isRecording then return end
            if inst:IsA("Tool") or inst:IsA("Accessory") then
                self:RecordTool(inst,player,char)
                if inst:IsA("Tool") then self:_HookReconTool(inst,player,char) end
            end
            if inst:IsA("Sound") then self:RecordSound(inst,player,char) end
        end)
    end

    hookContainer(char)
    hookContainer(player:FindFirstChildOfClass("Backpack"))
    local rk1="ReconDescAdded_"..tostring(player.UserId) local rk2="ReconDescRemoving_"..tostring(player.UserId)
    if self._connections[rk1] then pcall(function() self._connections[rk1]:Disconnect() end) end
    if self._connections[rk2] then pcall(function() self._connections[rk2]:Disconnect() end) end
    self._connections[rk1]=char.DescendantAdded:Connect(function(inst) if self._isRecording then pcall(function() self:_ReconObject(char,player,"Added",inst) end) end end)
    self._connections[rk2]=char.DescendantRemoving:Connect(function(inst) if self._isRecording then pcall(function() self:_ReconObject(char,player,"Removing",inst) end) end end)
    pcall(function()
        for _,desc in ipairs(char:GetDescendants()) do
            if desc:IsA("Sound") then self:RecordSound(desc,player,char) end
        end
    end)
end

-- ============================================================================
-- INIT HOOKS (called once at startup)
-- ============================================================================
function TelemetryRecorder:InitHooks()
    -- Hook existing players
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            task.spawn(function() self:HookCharacter(p, p.Character) end)
        end
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
        local bpKey="BackpackAdded_"..tostring(p.UserId)
        self._connections[bpKey]=p.ChildAdded:Connect(function(child)
            if child:IsA("Backpack") and p.Character then
                task.spawn(function() if self._isRecording then self:HookCharacter(p,p.Character) end end)
            end
        end)
    end

    -- Hook newly joined players
    self._connections["PlayerAdded"] = Players.PlayerAdded:Connect(function(p)
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        self._connections[charAddedKey] = p.CharacterAdded:Connect(function(char)
            task.spawn(function() self:HookCharacter(p, char) end)
        end)
        local bpKey="BackpackAdded_"..tostring(p.UserId)
        self._connections[bpKey]=p.ChildAdded:Connect(function(child)
            if child:IsA("Backpack") and p.Character then
                task.spawn(function() if self._isRecording then self:HookCharacter(p,p.Character) end end)
            end
        end)
    end)

    self._connections["PlayerRemoving"] = Players.PlayerRemoving:Connect(function(p)
        self._playerTrackers["target_" .. p.Name] = nil
        local charAddedKey = "CharAdded_" .. tostring(p.UserId)
        local bpKey = "BackpackAdded_" .. tostring(p.UserId)
        if self._connections[bpKey] then
            pcall(function() self._connections[bpKey]:Disconnect() end)
            self._connections[bpKey] = nil
        end
        if self._connections[charAddedKey] then
            pcall(function() self._connections[charAddedKey]:Disconnect() end)
            self._connections[charAddedKey] = nil
        end
    end)

    if not self._reconHooksInstalled and self._eventBus then
        self._reconHooksInstalled=true
        self._connections["NetworkGoalRecon"]=self._eventBus:Subscribe("Network.OutgoingGoal",function(goal,payload)
            if not self._isRecording or not self._cfg or self._cfg.RecordSkillRecon==false then return end
            local p=LocalPlayer local now=rn() local b=self._reconRecentGoals[p] or {} self._reconRecentGoals[p]=b local keys={}
            if type(payload)=="table" then for k in pairs(payload) do if #keys>=30 then break end table.insert(keys,tostring(k)) end end
            table.insert(b,{T=now,Goal=tostring(goal),Keys=keys}) while #b>30 do table.remove(b,1) end
            local active=self._activeSkillSessions[p] local sess=active and active.Session if sess and sess.Status=="Active" then self:_ReconPush(sess,"OutgoingGoal",{Goal=tostring(goal),Keys=keys}) end
        end)
    end
    task.spawn(function() self:ScanRemotes() end)
end

-- ============================================================================
-- LOAD FROM DISK (multi-file first, single file fallback)
-- ============================================================================
function TelemetryRecorder:LoadFromDisk()
    -- Try multi-file first
    local metaRaw = safeReadFile("tsb_data/metadata.json")
    if metaRaw then
        local categories = {
            "metadata", "animations", "characters", "hitboxes",
            "attributes", "combat_events", "cooldowns", "sounds", "tools", "remotes", "interactions", "world_objects", "skill_recon", "omni"
        }
        local dataMap = {
            metadata      = "Meta",
            animations    = "Animations",
            characters    = "Characters",
            hitboxes      = "Hitboxes",
            attributes    = "Attributes",
            combat_events = "CombatEvents",
            cooldowns     = "Cooldowns",
            sounds        = "Sounds",
            tools         = "Tools",
            remotes       = "Remotes",
            interactions = "Interactions",
            world_objects= "WorldObjects",
            skill_recon  = "SkillRecon",
            omni         = "Omni",
        }
        local loaded = false
        for _, cat in ipairs(categories) do
            local raw = safeReadFile("tsb_data/" .. cat .. ".json")
            if raw then
                local decoded = JSONDecode(raw)
                if decoded and type(decoded) == "table" then
                    local key = dataMap[cat]
                    if key then
                        if cat == "metadata" then
                            -- Merge meta: preserve session count
                            if type(decoded.TotalSessions) == "number" then
                                self.Data.Meta.TotalSessions = decoded.TotalSessions + 1
                            end
                            if type(decoded.Created) == "number" then
                                self.Data.Meta.Created = decoded.Created
                            end
                        elseif cat == "combat_events" then
                            if type(decoded) == "table" then
                                for _, ev in ipairs(decoded) do
                                    table.insert(self.Data.CombatEvents, ev)
                                end
                                -- Trim to max
                                while #self.Data.CombatEvents > self._maxCombatEvents do
                                    table.remove(self.Data.CombatEvents, 1)
                                end
                            end
                        else
                            -- Merge into existing data table
                            for k, v in pairs(decoded) do
                                if self.Data[key] then
                                    self.Data[key][k] = v
                                end
                            end
                        end
                        loaded = true
                    end
                end
            end
        end
        if loaded then
            self._logger:Info("TelemetryRecorder", "Loaded multi-file dataset from tsb_data/")
            return
        end
    end

    -- Fallback: single combined file
    local raw = safeReadFile("tsb_combat_data.json")
    if not raw then return end
    local decoded = JSONDecode(raw)
    if not decoded or type(decoded) ~= "table" then return end

    -- Merge each category
    for key, tbl in pairs(decoded) do
        if self.Data[key] and type(tbl) == "table" then
            if key == "Meta" then
                if type(tbl.TotalSessions) == "number" then
                    self.Data.Meta.TotalSessions = tbl.TotalSessions + 1
                end
            elseif key == "CombatEvents" then
                for _, ev in ipairs(tbl) do
                    table.insert(self.Data.CombatEvents, ev)
                end
            else
                for k, v in pairs(tbl) do
                    self.Data[key][k] = v
                end
            end
        end
    end

    self._logger:Info("TelemetryRecorder", "Loaded single-file dataset from tsb_combat_data.json")
end

-- ============================================================================
-- SAVE TO DISK (multi-file + combined fallback)
-- ============================================================================
function TelemetryRecorder:CountDataRecords(): number
    return countKeys(self.Data.Animations)+countKeys(self.Data.Characters)+countKeys(self.Data.Hitboxes)
        +countKeys(self.Data.Attributes)+countKeys(self.Data.Correlations)+#self.Data.CombatEvents
        +countKeys(self.Data.Cooldowns)+countKeys(self.Data.Sounds)+countKeys(self.Data.Tools)
        +countKeys(self.Data.Remotes)+countKeys(self.Data.Interactions)+countKeys(self.Data.WorldObjects)
        +countKeys(self.Data.SkillRecon.Profiles)+#self.Data.SkillRecon.Sessions
        +#self.Data.Omni.Events+countKeys(self.Data.Omni.Instances)
end

function TelemetryRecorder:SaveToDisk(force: boolean?): boolean
    if not force and (not self._isRecording or not self._isDirty) then return true end
    if self._saveInFlight then return false end
    if typeof(writefile) ~= "function" then
        self._lastSaveError = "writefile is unavailable"
        return false
    end

    self._saveInFlight = true
    local serial = (self._saveSerial or 0) + 1
    self._saveSerial = serial
    local revisionAtStart = self._dataRevision or 0
    local recordCountAtStart = self:CountDataRecords()

    local function doSave(): (boolean, string?)
        local allOk = true
        self.Data.Meta.LastUpdated = os.time()

        local multiOk = false
        if typeof(makefolder) == "function" then
            safeMakeFolder("tsb_data")
            local writes = {
                {"tsb_data/metadata.json", JSONEncode(self.Data.Meta)},
                {"tsb_data/animations.json", JSONEncode(self.Data.Animations)},
                {"tsb_data/characters.json", JSONEncode(self.Data.Characters)},
                {"tsb_data/hitboxes.json", JSONEncode(self.Data.Hitboxes)},
                {"tsb_data/attributes.json", JSONEncode(self.Data.Attributes)},
                {"tsb_data/combat_events.json", JSONEncode(self.Data.CombatEvents)},
                {"tsb_data/cooldowns.json", JSONEncode(self.Data.Cooldowns)},
                {"tsb_data/sounds.json", JSONEncode(self.Data.Sounds)},
                {"tsb_data/tools.json", JSONEncode(self.Data.Tools)},
                {"tsb_data/remotes.json", JSONEncode(self.Data.Remotes)},
                {"tsb_data/interactions.json", JSONEncode(self.Data.Interactions)},
                {"tsb_data/world_objects.json", JSONEncode(self.Data.WorldObjects)},
                {"tsb_data/skill_recon.json", JSONEncode(self.Data.SkillRecon)},
                {"tsb_data/omni.json", JSONEncode(self.Data.Omni)},
            }
            multiOk = true
            for _, pair in ipairs(writes) do
                if not safeWriteFile(pair[1], pair[2]) then
                    multiOk = false
                    break
                end
            end
            allOk = multiOk
        end

        -- Always maintain a combined file as the portable fallback.
        local combinedOk = safeWriteFile("tsb_combat_data.json", JSONEncode(self.Data))
        if typeof(makefolder) == "function" then
            allOk = combinedOk and multiOk
        else
            allOk = combinedOk
        end

        if allOk then
            self._lastSuccessfulSaveAt = os.clock()
            self._lastSuccessfulSavedRecords = recordCountAtStart
            self._lastSuccessfulSavedRevision = revisionAtStart
            if serial == self._saveSerial and (self._dataRevision or 0) == revisionAtStart then
                self._isDirty = false
            end
            self._lastSaveTick = self._lastSuccessfulSaveAt
            self._lastSaveError = nil
            return true, nil
        end

        self._lastSaveError = "One or more data files could not be written"
        return false, self._lastSaveError
    end

    if force then
        local okCall, okSave, err = pcall(doSave)
        self._saveInFlight = false
        if not okCall then
            self._lastSaveError = tostring(okSave)
            return false
        end
        return okSave == true, err
    end

    task.spawn(function()
        local okCall, okSave, err = pcall(doSave)
        if not okCall then
            self._lastSaveError = tostring(okSave)
        elseif not okSave then
            self._lastSaveError = err
        end
        self._saveInFlight = false
    end)
    return true
end

function TelemetryRecorder:RecordInteraction(inst: Instance)
    if self._cfg and self._cfg.RecordInteractions == false then return end
    if not inst then return end
    local key=getPath(inst)
    self.Data.Interactions[key]={Class=inst.ClassName,Name=inst.Name,Path=key,LastSeen=os.time()}
    self:_MarkDirty()
end

function TelemetryRecorder:RecordWorldObject(inst: Instance)
    if self._cfg and self._cfg.RecordWorldObjects == false then return end
    if not inst then return end
    local key=getPath(inst)
    self.Data.WorldObjects[key]={Class=inst.ClassName,Name=inst.Name,Path=key,LastSeen=os.time()}
    self:_MarkDirty()
end

function TelemetryRecorder:ScanInteractions()
    if not self._isRecording then return end
    if self._cfg and self._cfg.RecordInteractions ~= false then
        pcall(function()
            for _,d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") or d:IsA("ClickDetector") or d:IsA("Seat") or d:IsA("VehicleSeat") then
                    self:RecordInteraction(d)
                end
            end
        end)
    end
    if self._cfg and self._cfg.RecordWorldObjects ~= false then
        pcall(function()
            local count=0
            for _,d in ipairs(workspace:GetDescendants()) do
                if d:IsA("Tool") or d:IsA("Model") then
                    self:RecordWorldObject(d)
                    count+=1
                    if count>=2500 then break end
                end
            end
        end)
    end
end

-- ============================================================================
-- UPDATE (called from scheduler)
-- ============================================================================
function TelemetryRecorder:Update(dt: number, config: any)
    local cfg = config and config.Telemetry
    if not cfg then return end

    self._cfg = cfg
    local wasRecording = self._isRecording
    self._isRecording = (cfg.AutoRecordData == true)

    if self._isRecording and cfg.RecordSkillRecon ~= false then self:_ReconStartHeartbeat()
    elseif wasRecording and (not self._isRecording or cfg.RecordSkillRecon == false) then self:_ReconResetRuntime() end

    if self._isRecording and cfg.RecordOmni ~= false then
        self:_OmniStart()
    elseif wasRecording and (not self._isRecording or cfg.RecordOmni == false) then
        self:_OmniStop()
    end

    if self._isRecording and not wasRecording then
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Character then
                task.spawn(function() self:HookCharacter(p, p.Character) end)
            end
        end
    elseif not self._isRecording and wasRecording then
        for key, conn in pairs(self._connections) do
            if key ~= "PlayerAdded" and key ~= "PlayerRemoving" and not key:find("CharAdded_") and not key:find("BackpackAdded_") then
                pcall(function() conn:Disconnect() end)
                self._connections[key] = nil
            end
        end
    end

    if not self._isRecording then return end
    self._maxCombatEvents = cfg.MaxCombatEvents or 1000

    local now = os.clock()
    -- Periodic remote scan (every 60s, only while recording)
    if (now - self._lastInteractionScan) >= 30 then
        self._lastInteractionScan = now
        task.spawn(function() self:ScanInteractions() end)
    end

    if cfg.RecordRemotes ~= false and (now - self._lastRemoteScan) >= 60 then
        self._lastRemoteScan = now
        task.spawn(function() self:ScanRemotes() end)
    end

    -- Periodic animation fallback scan for players (every 15s)
    if cfg.RecordAnimations ~= false and (now - (self._lastAnimScan or 0)) >= 15 then
        self._lastAnimScan = now
        for _, p in ipairs(Players:GetPlayers()) do
            local char = p.Character
            if not char then continue end
            local hum = char:FindFirstChildOfClass("Humanoid")
            local anim = hum and hum:FindFirstChildOfClass("Animator")
            if anim then
                pcall(function()
                    for _, track in ipairs(anim:GetPlayingAnimationTracks()) do
                        if track.IsPlaying and track.Animation then
                            local animId = tostring(track.Animation.AnimationId or "")
                            if animId ~= "" and animId ~= "0" and not self.Data.Animations[animId] then
                                self:RecordAnimation(track, p, char)
                            end
                        end
                    end
                end)
            end
        end
    end

    -- Autosave (throttled to at least 180s)
    local interval = math.clamp(tonumber(cfg.AutoSaveInterval) or 120, 15, 600)
    if (now - self._lastSaveTick) >= interval then
        self:SaveToDisk(false)
    end
end

-- ============================================================================
-- STATS / EXPORT
-- ============================================================================
function TelemetryRecorder:GetStats(): any
    return {
        TotalAnimations       = countKeys(self.Data.Animations),
        TotalCharacters       = countKeys(self.Data.Characters),
        TotalHitboxProfiles   = countKeys(self.Data.Hitboxes),
        TotalAttributes       = countKeys(self.Data.Attributes),
        TotalCorrelations     = countKeys(self.Data.Correlations),
        TotalCombatEvents     = #self.Data.CombatEvents,
        TotalCooldownProfiles = countKeys(self.Data.Cooldowns),
        TotalSounds           = countKeys(self.Data.Sounds),
        TotalTools            = countKeys(self.Data.Tools),
        TotalRemotes          = countKeys(self.Data.Remotes),
        TotalInteractions     = countKeys(self.Data.Interactions),
        TotalWorldObjects     = countKeys(self.Data.WorldObjects),
        TotalSkillProfiles    = countKeys(self.Data.SkillRecon.Profiles),
        TotalSkillSessions    = #self.Data.SkillRecon.Sessions,
        ActiveSkillSessions   = (function() local n=0 for _,a in pairs(self._activeSkillSessions) do if a and a.Session then n+=1 end end return n end)(),
        OmniEvents             = #self.Data.Omni.Events,
        OmniInstances          = countKeys(self.Data.Omni.Instances),
        OmniIncoming           = #self.Data.Omni.Network.Incoming,
        OmniOutgoing           = #self.Data.Omni.Network.Outgoing,
        OmniTruncated          = self.Data.Omni.Meta.Truncated or 0,
        TotalDataRecords      = self:CountDataRecords(),
        SavedDataRecords      = self._lastSuccessfulSavedRecords,
        PendingDataRecords    = ((self._dataRevision or 0) == (self._lastSuccessfulSavedRevision or 0)) and 0 or self:CountDataRecords(),
        SaveInFlight          = self._saveInFlight == true,
        LastSaveError         = self._lastSaveError,
        TotalObservations     = (function()
            local n=#self.Data.CombatEvents
            for _,v in pairs(self.Data.Animations) do n+=(tonumber(v.PlayCount) or 0) end
            for _,v in pairs(self.Data.Characters) do n+=(tonumber(v.ObservedCount) or 0) end
            for _,v in pairs(self.Data.Attributes) do n+=(tonumber(v.ChangeCount) or 0) end
            for _,v in pairs(self.Data.Tools) do n+=(tonumber(v.Count) or 0) end
            return n
        end)(),
        LastSaved             = self._lastSuccessfulSaveAt,
        IsRecording           = self._isRecording,
        SessionDuration       = os.clock() - self._sessionStart,
        SessionNumber         = self.Data.Meta.TotalSessions,
    }
end

function TelemetryRecorder:ExportSummary(): string
    local s = self:GetStats()
    return string.format(
        "=== TSB Data Collector v10.0 ===\nSession #%d | Runtime: %.0fs\nAnimations: %d | Characters: %d | Hitboxes: %d\nAttributes: %d | Correlations: %d | Events: %d\nCooldowns: %d | Sounds: %d | Tools: %d | Remotes: %d",
        s.SessionNumber, s.SessionDuration,
        s.TotalAnimations, s.TotalCharacters, s.TotalHitboxProfiles,
        s.TotalAttributes, s.TotalCorrelations, s.TotalCombatEvents,
        s.TotalCooldownProfiles, s.TotalSounds, s.TotalTools, s.TotalRemotes
    )
end

-- ============================================================================
-- DESTROY
-- ============================================================================
function TelemetryRecorder:Destroy()
    self._isRecording = false
    pcall(function() self:_OmniStop() end)
    self:_ReconResetRuntime()
    if self._saveInFlight then
        local deadline = os.clock() + 2
        while self._saveInFlight and os.clock() < deadline do
            task.wait()
        end
    end
    self:SaveToDisk(true)
    for key, conn in pairs(self._connections) do
        if conn and typeof(conn) == "RBXScriptConnection" then
            pcall(function() conn:Disconnect() end)
        end
        self._connections[key] = nil
    end
    table.clear(self._playerTrackers)
    table.clear(self._notifThrottle)
end

return TelemetryRecorder

end
__modules["Systems/TelemetryRecorder"] = __modules["Systems.TelemetryRecorder"]

-- ============================================================================
-- Module: Systems.Visuals
-- ============================================================================
__modules["Systems.Visuals"] = function()
--!strict
local Players=game:GetService("Players")
local CoreGui=game:GetService("CoreGui")
local LocalPlayer=Players.LocalPlayer

local Visuals={}; Visuals.__index=Visuals

local COLORS={
    Cyan=Color3.fromRGB(0,200,255), Green=Color3.fromRGB(40,255,110), Blue=Color3.fromRGB(70,130,255),
    Yellow=Color3.fromRGB(255,225,50), Orange=Color3.fromRGB(255,150,40), Red=Color3.fromRGB(255,55,70),
    Purple=Color3.fromRGB(185,90,255), Pink=Color3.fromRGB(255,90,190), White=Color3.fromRGB(245,245,255),
}

local MoveSetResolver = require("Systems.MoveSetResolver")

local function pickColor(name:any,fallback:string):Color3 return COLORS[tostring(name)] or COLORS[fallback] end

local function getGuiParent(char:Model):Instance
    local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then return pg end
    if typeof(gethui)=="function" then
        local ok,h=pcall(gethui); if ok and h then return h end
    end
    if CoreGui then return CoreGui end
    return char
end

function Visuals.new(deps:{Cache:any,ObjectPool:any?,Logger:any})
    local self=setmetatable({
        _cache=deps.Cache,_logger=deps.Logger,_playerVisuals={},_identity={},_connections={},_globalConnections={},_lastVisualsTick=0,
    },Visuals)
    self:Init(); return self
end

function Visuals:BindPlayer(player:Player)
    if player == LocalPlayer then return end
    if self._connections[player] then
        for _, conn in ipairs(self._connections[player]) do pcall(function() conn:Disconnect() end) end
    end
    self._connections[player] = {}

    local function markRescan()
        local st = self._identity[player]
        if st then st.ForceRescan = true end
    end

    local bindCharacterTools
    bindCharacterTools = function(char: Model)
        table.insert(self._connections[player], char.DescendantAdded:Connect(function(inst)
            if inst:IsA("Tool") then markRescan() end
        end))
        table.insert(self._connections[player], char.DescendantRemoving:Connect(function(inst)
            if inst:IsA("Tool") then markRescan() end
        end))
    end

    table.insert(self._connections[player], player.CharacterAdded:Connect(function(char)
        self:CleanupPlayerVisuals(player)
        self._identity[player] = {Character=char, ClassKey=nil, HadUlt=false, PreviousUltSet={}, RiskUntil=0, ForceRescan=true, LastScan=0, IsUlt=false}
        bindCharacterTools(char)
        markRescan()
    end))

    local function bindBackpack(bp: Backpack?)
        if not bp then return end
        table.insert(self._connections[player], bp.ChildAdded:Connect(markRescan))
        table.insert(self._connections[player], bp.ChildRemoved:Connect(markRescan))
        markRescan()
    end

    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then bindBackpack(backpack) end
    table.insert(self._connections[player], player.ChildAdded:Connect(function(child)
        if child:IsA("Backpack") then bindBackpack(child) end
    end))
    if player.Character then bindCharacterTools(player.Character) end
    table.insert(self._connections[player], player.CharacterRemoving:Connect(function()
        self:CleanupPlayerVisuals(player)
    end))
end

function Visuals:Init()
    table.insert(self._globalConnections,Players.PlayerAdded:Connect(function(p) self:BindPlayer(p) end))
    table.insert(self._globalConnections,Players.PlayerRemoving:Connect(function(p)
        self:CleanupPlayerVisuals(p); self._identity[p]=nil
        local conns=self._connections[p]; if conns then for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end end
        self._connections[p]=nil
    end))
    for _,p in ipairs(Players:GetPlayers()) do self:BindPlayer(p) end
end

function Visuals:CleanupPlayerVisuals(player:Player)
    local vis=self._playerVisuals[player]
    if vis then
        if vis.Highlight then pcall(function() vis.Highlight:Destroy() end) end
        if vis.Billboard then pcall(function() vis.Billboard:Destroy() end) end
        self._playerVisuals[player]=nil
    end
end

function Visuals:GetCharacterState(player:Player,char:Model):(string,boolean,boolean)
    local now = os.clock()
    local state = self._identity[player]
    if not state or state.Character ~= char then
        state = {Character=char, ClassKey=nil, HadUlt=false, DeathCounterPresent=false, PreviousUltSet={}, RiskUntil=0, ForceRescan=true, LastScan=0}
        self._identity[player] = state
    end

    if state.ForceRescan or (now - (state.LastScan or 0)) >= 0.08 then
        state.ForceRescan = false
        state.LastScan = now
        local resolved = MoveSetResolver.Resolve(player)
        if resolved.Key then
            state.ClassKey = resolved.Key
            state.Label = resolved.Label
            state.ColorKey = resolved.ColorKey
        end
        state.IsUlt = resolved.IsUlt == true
        state.Resolved = resolved

        local currentUlt = {}
        local profile = resolved.Key and MoveSetResolver.GetProfiles()[resolved.Key]
        if profile then
            for _, name in ipairs(profile.Ult) do
                if resolved.Tools[tostring(name):lower():gsub("[^%w]", "")] then
                    currentUlt[tostring(name):lower():gsub("[^%w]", "")] = true
                end
            end
        end
        local currentUltCount = resolved.UltCount or 0

        if state.ClassKey == "Saitama" then
            local deathCounterPresent = resolved.Tools["deathcounter"] == true

            -- Arm Risk when Death Counter disappears even if other awakening tools are still
            -- visible; also arm when the entire awakening tool set disappears after a use.
            if state.HadUlt and state.DeathCounterPresent and not deathCounterPresent then
                state.RiskUntil = now + 10
            end

            if currentUltCount > 0 then
                state.HadUlt = true
                state.PreviousUltSet = currentUlt
                state.DeathCounterPresent = deathCounterPresent
            elseif state.HadUlt and next(state.PreviousUltSet) ~= nil then
                state.RiskUntil = math.max(state.RiskUntil or 0, now + 10)
                state.HadUlt = false
                state.DeathCounterPresent = false
                state.PreviousUltSet = {}
            else
                state.DeathCounterPresent = false
            end
        else
            state.HadUlt = false
            state.DeathCounterPresent = false
            state.PreviousUltSet = currentUlt
            state.RiskUntil = 0
        end
    end

    local profile = state.ClassKey and MoveSetResolver.GetProfiles()[state.ClassKey] or nil
    local risk = state.ClassKey == "Saitama" and now < (state.RiskUntil or 0)
    return (profile and profile.Label) or "Unknown", state.IsUlt == true, risk
end

function Visuals:CreateBillboard(player:Player,char:Model,targetPart:BasePart):BillboardGui
    local bg=Instance.new("BillboardGui")
    bg.Name="TSB_InfoESP_"..player.UserId; bg.Adornee=targetPart; bg.Size=UDim2.new(0,230,0,100)
    bg.StudsOffset=Vector3.new(0,3.7,0); bg.AlwaysOnTop=true; bg.MaxDistance=5000; bg.ResetOnSpawn=false
    bg.Parent=getGuiParent(char)
    local f=Instance.new("Frame"); f.Size=UDim2.fromScale(1,1); f.BackgroundTransparency=1; f.Parent=bg
    local function label(name,y,size,font):TextLabel
        local l=Instance.new("TextLabel"); l.Name=name; l.Size=UDim2.new(1,0,0,size+4); l.Position=UDim2.new(0,0,0,y)
        l.BackgroundTransparency=1;l.Text="";l.TextStrokeTransparency=0.15;l.TextSize=size;l.Font=font;l.Parent=f;return l
    end
    label("NameLabel",0,11,Enum.Font.GothamBold); label("ClassLabel",17,11,Enum.Font.GothamBold); label("RiskLabel",34,12,Enum.Font.GothamBlack)
    local hpBg=Instance.new("Frame");hpBg.Name="HpBg";hpBg.Size=UDim2.new(.85,0,0,4);hpBg.Position=UDim2.new(.075,0,0,53);hpBg.BackgroundColor3=Color3.fromRGB(20,20,25);hpBg.BorderSizePixel=0;hpBg.Parent=f;Instance.new("UICorner",hpBg).CornerRadius=UDim.new(1,0)
    local hp=Instance.new("Frame");hp.Name="HpBar";hp.Size=UDim2.new(1,0,1,0);hp.BackgroundColor3=Color3.fromRGB(0,230,120);hp.BorderSizePixel=0;hp.Parent=hpBg;Instance.new("UICorner",hp).CornerRadius=UDim.new(1,0)
    local d=Instance.new("TextLabel");d.Name="DistLabel";d.Size=UDim2.new(1,0,0,13);d.Position=UDim2.new(0,0,0,61);d.BackgroundTransparency=1;d.Text="0m";d.TextColor3=Color3.fromRGB(180,185,200);d.TextStrokeTransparency=.4;d.TextSize=9;d.Font=Enum.Font.Gotham;d.Parent=f
    return bg
end

function Visuals:Update(config:any)
    local cfg=config and config.Visuals or {}
    local hlEnabled=cfg.HighlightESP==true; local infoEnabled=cfg.BillboardESP==true
    local showChar=cfg.ShowCharacterESP~=false; local showRisk=cfg.ShowDeathCounterRisk~=false
    local useClassColors=cfg.UseCharacterColors~=false
    local now=os.clock(); if now-(self._lastVisualsTick or 0)<0.08 then return end; self._lastVisualsTick=now
    local myEntry=self._cache:GetPlayerEntry(LocalPlayer); local myPos=(myEntry and myEntry.RootPart and myEntry.RootPart.Position) or Vector3.zero

    for _,player in ipairs(Players:GetPlayers()) do
        if player==LocalPlayer then continue end
        local char=player.Character; local hum=char and char:FindFirstChildOfClass("Humanoid")
        local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
        if not char or not char.Parent or not hum or not root or hum.Health<=0 then self:CleanupPlayerVisuals(player);continue end

        local className,isUlt,risk=self:GetCharacterState(player,char)
        local state=self._identity[player]
        local vis=self._playerVisuals[player] or {}; self._playerVisuals[player]=vis
        local profile=state and state.ClassKey and MoveSetResolver.GetProfiles()[state.ClassKey] or nil
        local defaultName=profile and profile.ColorKey or "OtherCharacterESPColor"
        local classColor=pickColor(cfg[defaultName],"Cyan")
        local espColor=useClassColors and classColor or pickColor(cfg.HighlightColor,"Cyan")
        if risk then espColor=pickColor(cfg.DeathCounterRiskColor,"Red") end

        if hlEnabled then
            local hl=vis.Highlight
            if not hl or not hl.Parent or hl.Adornee~=char then
                if hl then pcall(function() hl:Destroy() end) end
                hl=Instance.new("Highlight");hl.Name="TSB_HL_"..player.UserId;hl.Adornee=char;hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop;hl.Parent=char;vis.Highlight=hl
            end
            hl.FillColor=espColor;hl.OutlineColor=espColor;hl.FillTransparency=risk and .18 or .42;hl.OutlineTransparency=.05;hl.Enabled=true
        elseif vis.Highlight then pcall(function() vis.Highlight:Destroy() end);vis.Highlight=nil end

        local needBillboard=infoEnabled or showChar or (showRisk and risk)
        if needBillboard then
            local targetPart=char:FindFirstChild("Head") or root
            local bb=vis.Billboard
            if not bb or not bb.Parent or bb.Adornee~=targetPart then
                if bb then pcall(function() bb:Destroy() end) end
                bb=self:CreateBillboard(player,char,targetPart);vis.Billboard=bb
                vis.NameLabel=bb:FindFirstChild("NameLabel",true);vis.ClassLabel=bb:FindFirstChild("ClassLabel",true);vis.RiskLabel=bb:FindFirstChild("RiskLabel",true);vis.HpBar=bb:FindFirstChild("HpBar",true);vis.DistLabel=bb:FindFirstChild("DistLabel",true)
            end
            local dist=math.floor((root.Position-myPos).Magnitude); local hpPct=math.clamp(hum.Health/math.max(hum.MaxHealth,1),0,1)
            local status=(className~="Unknown" and ("["..className.."]"..(isUlt and " [ULT]" or ""))) or ""
            if vis.NameLabel then vis.NameLabel.Visible=infoEnabled;vis.NameLabel.Text=string.format("%s (@%s)",player.DisplayName,player.Name);vis.NameLabel.TextColor3=Color3.fromRGB(255,255,255) end
            if vis.ClassLabel then vis.ClassLabel.Visible=showChar and status~="";vis.ClassLabel.Text=status;vis.ClassLabel.TextColor3=classColor end
            if vis.RiskLabel then vis.RiskLabel.Visible=showRisk and risk;vis.RiskLabel.Text=risk and "Death Counter Risk" or "";vis.RiskLabel.TextColor3=pickColor(cfg.DeathCounterRiskColor,"Red") end
            if vis.HpBar then vis.HpBar.Visible=infoEnabled;vis.HpBar.Size=UDim2.new(hpPct,0,1,0) end
            if vis.DistLabel then vis.DistLabel.Visible=infoEnabled;vis.DistLabel.Text=string.format("%dm",dist) end
        elseif vis.Billboard then pcall(function() vis.Billboard:Destroy() end);vis.Billboard=nil end
    end
end

function Visuals:Destroy()
    for p in pairs(self._playerVisuals) do self:CleanupPlayerVisuals(p) end
    for _,conns in pairs(self._connections) do for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end end
    for _,c in ipairs(self._globalConnections) do pcall(function() c:Disconnect() end) end
    self._playerVisuals={};self._identity={};self._connections={};self._globalConnections={}
end
return Visuals
end

-- ============================================================================
-- Module: Systems.World
-- ============================================================================
__modules["Systems.World"] = function()
--!strict
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local World = {}
World.__index = World

function World.new(deps: { ConfigManager: any, Logger: any })
    local self = setmetatable({
        _configManager = deps.ConfigManager,
        _logger = deps.Logger,
        OriginalLighting = {
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness,
            FogEnd = Lighting.FogEnd,
        },
        LastHopCheck = 0,
        HopActive = false,
        _lastFullBright = nil :: boolean?,
        _lastRemoveFog = nil :: boolean?,
        _lastCustomFOV = nil :: boolean?,
        _cameraOriginalFOV = setmetatable({}, { __mode = "k" }),
    }, World)
    return self
end

function World:ToggleFullBright(enable: boolean)
    if self._lastFullBright == enable then return end
    self._lastFullBright = enable
    if enable then
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        Lighting.Brightness = 2
    else
        Lighting.Ambient = self.OriginalLighting.Ambient
        Lighting.OutdoorAmbient = self.OriginalLighting.OutdoorAmbient
        Lighting.Brightness = self.OriginalLighting.Brightness
    end
end

function World:ToggleRemoveFog(enable: boolean)
    if self._lastRemoveFog == enable then return end
    self._lastRemoveFog = enable
    if enable then
        Lighting.FogEnd = 9e9
    else
        Lighting.FogEnd = self.OriginalLighting.FogEnd
    end
end

function World:ToggleCustomFOV(enable: boolean, value: number?)
    local cam = Workspace.CurrentCamera
    if not cam then return end

    if enable then
        if self._cameraOriginalFOV[cam] == nil then
            self._cameraOriginalFOV[cam] = cam.FieldOfView
        end
        local fov = math.clamp(value or 90, 60, 120)
        pcall(function() cam.FieldOfView = fov end)
    else
        local original = self._cameraOriginalFOV[cam]
        if original ~= nil then
            pcall(function() cam.FieldOfView = original end)
            self._cameraOriginalFOV[cam] = nil
        end
    end
    self._lastCustomFOV = enable
end

function World:ServerHop(minPlayers: number?)
    if self.HopActive then return end
    self.HopActive = true
    local requiredPlayers = math.clamp(minPlayers or 4, 2, 8)

    task.spawn(function()
        local teleported = false
        local ok, err = pcall(function()
            local placeId = game.PlaceId
            local jobId = game.JobId
            local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Desc&limit=100"

            local req = nil
            if typeof(syn) == "table" and typeof(syn.request) == "function" then
                req = syn.request
            elseif typeof(http_request) == "function" then
                req = http_request
            elseif typeof(request) == "function" then
                req = request
            end
            local body = nil
            if req then
                local reqOk, res = pcall(req, { Url = url, Method = "GET" })
                if reqOk and res and res.Body then body = res.Body end
            elseif typeof(game.HttpGet) == "function" then
                pcall(function() body = game:HttpGet(url) end)
            end

            if body then
                local decodeOk, data = pcall(function() return HttpService:JSONDecode(body) end)
                if decodeOk and data and type(data.data) == "table" then
                    for _, server in ipairs(data.data) do
                        if server.id ~= jobId and server.playing and server.maxPlayers
                            and server.playing < (server.maxPlayers - 1)
                            and server.playing >= requiredPlayers then
                            local tpOk = pcall(TeleportService.TeleportToPlaceInstance, TeleportService, placeId, server.id, Players.LocalPlayer)
                            teleported = tpOk
                            if teleported then return end
                        end
                    end
                end
            end

            teleported = pcall(TeleportService.Teleport, TeleportService, placeId, Players.LocalPlayer)
        end)

        if not ok or not teleported then
            self.HopActive = false
            if self._logger then
                self._logger:Warn("World", "Server hop failed" .. (err and (": " .. tostring(err)) or ""))
            end
        end
    end)
end

function World:Destroy()
    pcall(function() self:ToggleFullBright(false) end)
    pcall(function() self:ToggleRemoveFog(false) end)
    pcall(function() self:ToggleCustomFOV(false) end)
    self.HopActive = false
end

function World:CheckAutoServerHop(config: any)
    if not config.World.AutoServerHop or self.HopActive then return end
    local now = os.clock()
    if (now - self.LastHopCheck) < 10 then return end
    self.LastHopCheck = now

    local count = #Players:GetPlayers()
    if count < (config.World.AutoHopMinPlayers or 4) then
        self:ServerHop(config.World.AutoHopMinPlayers or 4)
    end
end

return World

end
__modules["Systems/World"] = __modules["Systems.World"]

-- ============================================================================
-- Module: UI.Components
-- ============================================================================
__modules["UI.Components"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Theme = require("UI.Theme")

local Components = {}

-- -----------------------------------------------------------------------------
-- SECTION HEADER
-- -----------------------------------------------------------------------------
function Components.Section(parent: Instance, title: string, accentName: string?)
    local accent = Theme.GetAccent(accentName)

    local f = Instance.new("Frame")
    f.Name = "Section_" .. title
    f.Size = UDim2.new(1, 0, 0, 30)
    f.BackgroundTransparency = 1
    f.Parent = parent

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 3, 0, 14)
    bar.Position = UDim2.new(0, 2, 0.5, -7)
    bar.BackgroundColor3 = accent.Primary
    bar.BorderSizePixel = 0
    bar.Parent = f
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.AutomaticSize = Enum.AutomaticSize.X
    lbl.Size = UDim2.new(0, 0, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.upper(title)
    lbl.TextColor3 = accent.Primary
    lbl.TextSize = 11
    lbl.Font = Theme.Fonts.Bold
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    local divLine = Instance.new("Frame")
    divLine.Size = UDim2.new(1, -20, 0, 1)
    divLine.Position = UDim2.new(0, 12, 1, -1)
    divLine.BackgroundColor3 = Theme.Colors.BorderSubtle
    divLine.BorderSizePixel = 0
    divLine.Parent = f

    return f
end

-- -----------------------------------------------------------------------------
-- INFO BANNER
-- -----------------------------------------------------------------------------
function Components.InfoBanner(parent: Instance, text: string, kind: string?, accentName: string?)
    local accent = Theme.GetAccent(accentName)
    local col = accent.Primary
    if kind == "Warning" then col = Theme.Colors.Warning
    elseif kind == "Danger" then col = Theme.Colors.Danger
    elseif kind == "Success" then col = Theme.Colors.Success
    elseif kind == "Info" then col = Theme.Colors.Info end

    local f = Instance.new("Frame")
    f.Name = "Banner"
    f.Size = UDim2.new(1, 0, 0, 28)
    f.BackgroundColor3 = Theme.Colors.Header
    f.BorderSizePixel = 0
    f.Parent = parent
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)

    local stroke = Instance.new("UIStroke")
    stroke.Color = col
    stroke.Thickness = 1
    stroke.Transparency = 0.5
    stroke.Parent = f

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -16, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = col
    lbl.TextSize = 11
    lbl.Font = Theme.Fonts.Subtitle
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    return f
end

-- -----------------------------------------------------------------------------
-- TOGGLE COMPONENT
-- -----------------------------------------------------------------------------
function Components.Toggle(parent: Instance, title: string, subtitle: string?, defaultVal: boolean, accentName: string?, callback: ((boolean) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Toggle_" .. title
    frame.Size = UDim2.new(1, 0, 0, subtitle and 44 or 38)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -68, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, subtitle and 5 or 10)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    if subtitle then
        local subL = Instance.new("TextLabel")
        subL.Size = UDim2.new(1, -68, 0, 14)
        subL.Position = UDim2.new(0, 12, 0, 24)
        subL.BackgroundTransparency = 1
        subL.Text = subtitle
        subL.TextColor3 = Theme.Colors.TextSecondary
        subL.TextSize = 10
        subL.Font = Theme.Fonts.Body
        subL.TextXAlignment = Enum.TextXAlignment.Left
        subL.Parent = frame
    end

    local switchBg = Instance.new("Frame")
    switchBg.Size = UDim2.new(0, 40, 0, 20)
    switchBg.Position = UDim2.new(1, -52, 0.5, -10)
    switchBg.BackgroundColor3 = defaultVal and accent.Primary or Theme.Colors.CardHover
    switchBg.BorderSizePixel = 0
    switchBg.Parent = frame
    Instance.new("UICorner", switchBg).CornerRadius = UDim.new(1, 0)

    local switchCirc = Instance.new("Frame")
    switchCirc.Size = UDim2.new(0, 14, 0, 14)
    switchCirc.Position = defaultVal and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    switchCirc.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    switchCirc.BorderSizePixel = 0
    switchCirc.Parent = switchBg
    Instance.new("UICorner", switchCirc).CornerRadius = UDim.new(1, 0)

    local state = defaultVal
    local function SetOn(val: boolean, fireCallback: boolean?)
        state = val
        Theme.Tween(switchBg, 0.16, { BackgroundColor3 = state and accent.Primary or Theme.Colors.CardHover })
        Theme.Tween(switchCirc, 0.16, { Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7) })
        if fireCallback ~= false and callback then
            pcall(callback, state)
        end
    end

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 1, 0)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.ZIndex = 10
    btn.Active = true
    btn.Parent = frame

    btn.MouseEnter:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.CardHover })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(frame, 0.12, { BackgroundColor3 = Theme.Colors.Card })
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)

    local lastToggleTick = 0
    local function HandleToggle()
        local now = os.clock()
        if (now - lastToggleTick) < 0.12 then return end
        lastToggleTick = now
        SetOn(not state, true)
    end
    btn.MouseButton1Click:Connect(HandleToggle)
    btn.Activated:Connect(HandleToggle)

    return {
        Frame = frame,
        SetOn = SetOn,
        GetState = function() return state end
    }
end

-- -----------------------------------------------------------------------------
-- SLIDER COMPONENT
-- -----------------------------------------------------------------------------
function Components.Slider(parent: Instance, title: string, minV: number, maxV: number, defaultV: number, suffix: string?, step: number?, accentName: string?, callback: ((number) -> ())?)
    local accent = Theme.GetAccent(accentName)
    local stepVal = step or 1

    local frame = Instance.new("Frame")
    frame.Name = "Slider_" .. title
    frame.Size = UDim2.new(1, 0, 0, 50)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -80, 0, 18)
    titleL.Position = UDim2.new(0, 12, 0, 8)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local valL = Instance.new("TextLabel")
    valL.Size = UDim2.new(0, 70, 0, 18)
    valL.Position = UDim2.new(1, -82, 0, 8)
    valL.BackgroundTransparency = 1
    valL.Text = tostring(defaultV) .. (suffix or "")
    valL.TextColor3 = accent.Primary
    valL.TextSize = 12
    valL.Font = Theme.Fonts.Bold
    valL.TextXAlignment = Enum.TextXAlignment.Right
    valL.Parent = frame

    local trackBg = Instance.new("Frame")
    trackBg.Size = UDim2.new(1, -24, 0, 6)
    trackBg.Position = UDim2.new(0, 12, 0, 34)
    trackBg.BackgroundColor3 = Theme.Colors.Header
    trackBg.BorderSizePixel = 0
    trackBg.Parent = frame
    Instance.new("UICorner", trackBg).CornerRadius = UDim.new(1, 0)

    local curVal = math.clamp(defaultV, minV, maxV)
    local initialPct = (curVal - minV) / (maxV - minV)

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new(math.clamp(initialPct, 0, 1), 0, 1, 0)
    trackFill.BackgroundColor3 = accent.Primary
    trackFill.BorderSizePixel = 0
    trackFill.Parent = trackBg
    Instance.new("UICorner", trackFill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.Position = UDim2.new(1, -6, 0.5, -6)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = trackFill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local sliding = false
    local function SetValue(newVal: number, fireCallback: boolean?)
        curVal = math.clamp(newVal, minV, maxV)
        if stepVal >= 1 then
            curVal = math.floor(curVal / stepVal + 0.5) * stepVal
        else
            curVal = math.floor(curVal * 100 + 0.5) / 100
        end

        local pct = (curVal - minV) / (maxV - minV)
        trackFill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)
        valL.Text = tostring(curVal) .. (suffix or "")

        if fireCallback ~= false and callback then
            pcall(callback, curVal)
        end
    end

    local function UpdateFromInput(inp: any)
        local rel = math.clamp((inp.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X, 0, 1)
        local rawVal = minV + (maxV - minV) * rel
        SetValue(rawVal, true)
    end

    local connEnded: RBXScriptConnection? = nil
    local connChanged: RBXScriptConnection? = nil

    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(1, -8, 0.5, -8) })
            UpdateFromInput(inp)
        end
    end)

    connEnded = UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if sliding then
                sliding = false
                Theme.Tween(knob, 0.1, { Size = UDim2.new(0, 12, 0, 12), Position = UDim2.new(1, -6, 0.5, -6) })
            end
        end
    end)

    connChanged = UserInputService.InputChanged:Connect(function(inp)
        if sliding and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            UpdateFromInput(inp)
        end
    end)

    -- Clean up global connections when this slider frame is destroyed
    frame.AncestryChanged:Connect(function()
        if not frame.Parent then
            if connEnded then connEnded:Disconnect() connEnded = nil end
            if connChanged then connChanged:Disconnect() connChanged = nil end
        end
    end)

    frame.MouseEnter:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderActive })
    end)
    frame.MouseLeave:Connect(function()
        Theme.Tween(stroke, 0.12, { Color = Theme.Colors.BorderSubtle })
    end)

    return {
        Frame = frame,
        SetValue = SetValue,
        GetValue = function() return curVal end,
    }
end

-- -----------------------------------------------------------------------------
-- DROPDOWN COMPONENT
-- -----------------------------------------------------------------------------
function Components.Dropdown(parent: Instance, title: string, options: { string }, defaultSelected: string, accentName: string?, callback: ((string) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Dropdown_" .. title
    frame.Size = UDim2.new(1, 0, 0, 42)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(0, 120, 0, 42)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local selectBtn = Instance.new("TextButton")
    selectBtn.Size = UDim2.new(1, -145, 0, 26)
    selectBtn.Position = UDim2.new(0, 135, 0, 8)
    selectBtn.BackgroundColor3 = Theme.Colors.Header
    selectBtn.BorderSizePixel = 0
    selectBtn.Text = "  " .. tostring(defaultSelected)
    selectBtn.TextColor3 = accent.Primary
    selectBtn.TextSize = 11
    selectBtn.Font = Theme.Fonts.Subtitle
    selectBtn.TextXAlignment = Enum.TextXAlignment.Left
    selectBtn.ZIndex = 10
    selectBtn.Active = true
    selectBtn.Parent = frame
    Instance.new("UICorner", selectBtn).CornerRadius = UDim.new(0, 5)

    local arrow = Instance.new("TextLabel")
    arrow.Size = UDim2.new(0, 20, 1, 0)
    arrow.Position = UDim2.new(1, -22, 0, 0)
    arrow.BackgroundTransparency = 1
    arrow.Text = "▼"
    arrow.TextColor3 = Theme.Colors.TextSecondary
    arrow.TextSize = 9
    arrow.Font = Theme.Fonts.Bold
    arrow.ZIndex = 11
    arrow.Parent = selectBtn

    local listFrame = Instance.new("ScrollingFrame")
    listFrame.Name = "DropdownList"
    listFrame.Size = UDim2.new(1, -24, 0, 0)
    listFrame.Position = UDim2.new(0, 12, 0, 42)
    listFrame.BackgroundTransparency = 1
    listFrame.BorderSizePixel = 0
    listFrame.ScrollBarThickness = 3
    listFrame.ScrollBarImageColor3 = accent.Primary
    listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    listFrame.ZIndex = 15
    listFrame.Parent = frame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 2)
    listLayout.Parent = listFrame

    local isOpen = false
    local currentSelected = (table.find(options, defaultSelected) and defaultSelected) or options[1] or ""
    local SelectOption: (string) -> () = nil :: any

    local function RebuildOptions(opts: { string })
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        for idx, opt in ipairs(opts) do
            local optBtn = Instance.new("TextButton")
            optBtn.Size = UDim2.new(1, -6, 0, 26)
            optBtn.BackgroundColor3 = Theme.Colors.Header
            optBtn.BorderSizePixel = 0
            optBtn.Text = "  " .. opt
            optBtn.TextColor3 = (opt == currentSelected) and accent.Primary or Theme.Colors.TextSecondary
            optBtn.TextSize = 11
            optBtn.Font = Theme.Fonts.Body
            optBtn.TextXAlignment = Enum.TextXAlignment.Left
            optBtn.LayoutOrder = idx
            optBtn.ZIndex = 20
            optBtn.Active = true
            optBtn.Parent = listFrame
            Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)

            optBtn.MouseEnter:Connect(function()
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
            end)
            optBtn.MouseLeave:Connect(function()
                local isSel = (opt == currentSelected)
                Theme.Tween(optBtn, 0.1, { BackgroundColor3 = Theme.Colors.Header, TextColor3 = isSel and accent.Primary or Theme.Colors.TextSecondary })
            end)

            local lastOptClick = 0
            local function HandleOptClick()
                local now = os.clock()
                if (now - lastOptClick) < 0.12 then return end
                lastOptClick = now
                SelectOption(opt)
            end
            optBtn.MouseButton1Click:Connect(HandleOptClick)
            optBtn.Activated:Connect(HandleOptClick)
        end
    end

    local currentOpts = options
    local function ToggleOpen()
        isOpen = not isOpen
        local visibleCount = math.clamp(#currentOpts, 1, 5)
        local listH = visibleCount * 28
        listFrame.Size = UDim2.new(1, -24, 0, listH)
        local targetH = isOpen and (48 + listH) or 42
        arrow.Text = isOpen and "▲" or "▼"
        Theme.Tween(frame, 0.12, { Size = UDim2.new(1, 0, 0, targetH) })
    end

    SelectOption = function(opt: string)
        currentSelected = opt
        selectBtn.Text = "  " .. opt
        if isOpen then
            ToggleOpen()
        end
        if callback then
            task.spawn(function()
                pcall(callback, opt)
            end)
        end
    end

    local function SetOptions(newOpts: { string })
        currentOpts = newOpts
        if not table.find(newOpts, currentSelected) then
            currentSelected = newOpts[1] or ""
            selectBtn.Text = "  " .. currentSelected
            if callback and currentSelected ~= "" then
                task.spawn(function() pcall(callback, currentSelected) end)
            end
        end
        RebuildOptions(newOpts)
        if isOpen then
            local visibleCount = math.clamp(#newOpts, 1, 5)
            local listH = visibleCount * 28
            listFrame.Size = UDim2.new(1, -24, 0, listH)
            local targetH = 48 + listH
            Theme.Tween(frame, 0.12, { Size = UDim2.new(1, 0, 0, targetH) })
        end
    end

    RebuildOptions(options)
    local lastToggleClick = 0
    local function HandleToggleOpen()
        local now = os.clock()
        if (now - lastToggleClick) < 0.12 then return end
        lastToggleClick = now
        ToggleOpen()
    end
    selectBtn.MouseButton1Click:Connect(HandleToggleOpen)
    selectBtn.Activated:Connect(HandleToggleOpen)

    return {
        Frame = frame,
        Select = SelectOption,
        SetOptions = SetOptions,
        GetSelected = function() return currentSelected end,
    }
end

-- -----------------------------------------------------------------------------
-- BUTTON COMPONENT
-- -----------------------------------------------------------------------------
function Components.Button(parent: Instance, title: string, btnText: string, kind: string?, accentName: string?, callback: (() -> ())?)
    local accent = Theme.GetAccent(accentName)
    local btnBgColor = accent.Primary
    if kind == "Danger" then btnBgColor = Theme.Colors.Danger
    elseif kind == "Secondary" then btnBgColor = Theme.Colors.CardHover
    elseif kind == "Success" then btnBgColor = Theme.Colors.Success end

    local frame = Instance.new("Frame")
    frame.Name = "Button_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -125, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 105, 0, 26)
    btn.Position = UDim2.new(1, -117, 0.5, -13)
    btn.BackgroundColor3 = btnBgColor
    btn.BorderSizePixel = 0
    btn.Text = btnText
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 11
    btn.Font = Theme.Fonts.Bold
    btn.ZIndex = 10
    btn.Active = true
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    btn.MouseEnter:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0.15 })
    end)
    btn.MouseLeave:Connect(function()
        Theme.Tween(btn, 0.1, { BackgroundTransparency = 0 })
    end)
    btn.MouseButton1Down:Connect(function()
        Theme.Tween(btn, 0.05, { Size = UDim2.new(0, 101, 0, 24), Position = UDim2.new(1, -115, 0.5, -12) })
    end)
    btn.MouseButton1Up:Connect(function()
        Theme.Tween(btn, 0.1, { Size = UDim2.new(0, 105, 0, 26), Position = UDim2.new(1, -117, 0.5, -13) })
    end)

    local lastBtnTick = 0
    local function HandleBtnClick()
        local now = os.clock()
        if (now - lastBtnTick) < 0.12 then return end
        lastBtnTick = now
        if callback then pcall(callback) end
    end
    btn.MouseButton1Click:Connect(HandleBtnClick)
    btn.Activated:Connect(HandleBtnClick)

    return { Frame = frame, Button = btn }
end

-- -----------------------------------------------------------------------------
-- KEYBIND COMPONENT
-- -----------------------------------------------------------------------------
function Components.Keybind(parent: Instance, title: string, defaultKey: EnumItem, accentName: string?, callback: ((EnumItem) -> ())?)
    local accent = Theme.GetAccent(accentName)

    local frame = Instance.new("Frame")
    frame.Name = "Keybind_" .. title
    frame.Size = UDim2.new(1, 0, 0, 40)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -110, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local keyBtn = Instance.new("TextButton")
    keyBtn.Size = UDim2.new(0, 90, 0, 24)
    keyBtn.Position = UDim2.new(1, -102, 0.5, -12)
    keyBtn.BackgroundColor3 = Theme.Colors.Header
    keyBtn.BorderSizePixel = 0
    keyBtn.Text = defaultKey.Name
    keyBtn.TextColor3 = accent.Primary
    keyBtn.TextSize = 11
    keyBtn.Font = Theme.Fonts.Bold
    keyBtn.Parent = frame
    Instance.new("UICorner", keyBtn).CornerRadius = UDim.new(0, 5)

    local keyStroke = Instance.new("UIStroke")
    keyStroke.Color = Theme.Colors.BorderSubtle
    keyStroke.Thickness = 1
    keyStroke.Parent = keyBtn

    local isListening = false
    local currentKey = defaultKey
    local listeningConnection: RBXScriptConnection? = nil

    local function SetKey(key: EnumItem)
        if listeningConnection then
            pcall(function() listeningConnection:Disconnect() end)
            listeningConnection = nil
        end
        currentKey = key
        keyBtn.Text = key.Name
        isListening = false
        keyStroke.Color = Theme.Colors.BorderSubtle
        keyBtn.TextColor3 = accent.Primary
        if callback then pcall(callback, key) end
    end

    keyBtn.MouseButton1Click:Connect(function()
        if isListening then return end
        isListening = true
        keyBtn.Text = "..."
        keyStroke.Color = accent.Primary
        keyBtn.TextColor3 = Theme.Colors.Warning

        if listeningConnection then
            pcall(function() listeningConnection:Disconnect() end)
        end
        listeningConnection = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                SetKey(input.KeyCode)
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                -- Right-click cancels
                SetKey(currentKey)
            end
        end)
    end)

    frame.AncestryChanged:Connect(function(_, parentNow)
        if parentNow == nil and listeningConnection then
            pcall(function() listeningConnection:Disconnect() end)
            listeningConnection = nil
        end
    end)

    return {
        Frame = frame,
        SetKey = SetKey,
        GetKey = function() return currentKey end,
    }
end

-- -----------------------------------------------------------------------------
-- STATUS BADGE COMPONENT
-- -----------------------------------------------------------------------------
function Components.StatusBadge(parent: Instance, title: string, statusText: string, statusColor: Color3?)
    local frame = Instance.new("Frame")
    frame.Name = "Status_" .. title
    frame.Size = UDim2.new(1, 0, 0, 36)
    frame.BackgroundColor3 = Theme.Colors.Card
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 7)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.BorderSubtle
    stroke.Thickness = 1
    stroke.Parent = frame

    local titleL = Instance.new("TextLabel")
    titleL.Size = UDim2.new(1, -120, 1, 0)
    titleL.Position = UDim2.new(0, 12, 0, 0)
    titleL.BackgroundTransparency = 1
    titleL.Text = title
    titleL.TextColor3 = Theme.Colors.TextPrimary
    titleL.TextSize = 12
    titleL.Font = Theme.Fonts.Subtitle
    titleL.TextXAlignment = Enum.TextXAlignment.Left
    titleL.Parent = frame

    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 100, 0, 22)
    badge.Position = UDim2.new(1, -112, 0.5, -11)
    badge.BackgroundColor3 = Theme.Colors.Header
    badge.BorderSizePixel = 0
    badge.Parent = frame
    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 5)

    local badgeL = Instance.new("TextLabel")
    badgeL.Size = UDim2.new(1, 0, 1, 0)
    badgeL.BackgroundTransparency = 1
    badgeL.Text = statusText
    badgeL.TextColor3 = statusColor or Theme.Colors.Success
    badgeL.TextSize = 10
    badgeL.Font = Theme.Fonts.Bold
    badgeL.Parent = badge

    local function Update(newText: string, newColor: Color3?)
        badgeL.Text = newText
        if newColor then badgeL.TextColor3 = newColor end
    end

    return { Frame = frame, Update = Update }
end

return Components

end
__modules["UI/Components"] = __modules["UI.Components"]

-- ============================================================================
-- Module: UI.Notifications
-- ============================================================================
__modules["UI.Notifications"] = function()
--!strict
local Theme = require("UI.Theme")

local Notifications = {}
Notifications.__index = Notifications

export type NotificationType = "Info" | "Success" | "Warning" | "Error"

function Notifications.new(parentGui: Instance, accentName: string?)
    local container = Instance.new("Frame")
    container.Name = "NotificationsContainer"
    container.Size = UDim2.new(0, 280, 1, -20)
    container.Position = UDim2.new(1, -290, 0, 10)
    container.BackgroundTransparency = 1
    container.Parent = parentGui

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
    layout.Padding = UDim.new(0, 8)
    layout.Parent = container

    local self = setmetatable({
        _container = container,
        _accentName = accentName or "Cyan Neon",
        _count = 0,
    }, Notifications)
    return self
end

function Notifications:Show(title: string, message: string, duration: number?, kind: NotificationType?)
    local dur = duration or 2.8
    local k = kind or "Info"
    self._count += 1

    local accent = Theme.GetAccent(self._accentName)
    local barColor = accent.Primary
    if k == "Success" then barColor = Theme.Colors.Success
    elseif k == "Warning" then barColor = Theme.Colors.Warning
    elseif k == "Error" then barColor = Theme.Colors.Danger end

    local toast = Instance.new("Frame")
    toast.Name = "Toast_" .. tostring(self._count)
    toast.Size = UDim2.new(1, 0, 0, 54)
    toast.Position = UDim2.new(1, 40, 0, 0) -- starts off-screen right
    toast.BackgroundColor3 = Theme.Colors.Card
    toast.BorderSizePixel = 0
    toast.LayoutOrder = self._count
    toast.Parent = self._container
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Theme.Colors.Border
    stroke.Thickness = 1
    stroke.Parent = toast

    local sideBar = Instance.new("Frame")
    sideBar.Size = UDim2.new(0, 4, 1, -12)
    sideBar.Position = UDim2.new(0, 6, 0.5, -21)
    sideBar.BackgroundColor3 = barColor
    sideBar.BorderSizePixel = 0
    sideBar.Parent = toast
    Instance.new("UICorner", sideBar).CornerRadius = UDim.new(1, 0)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -26, 0, 18)
    titleLbl.Position = UDim2.new(0, 18, 0, 7)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = title
    titleLbl.TextColor3 = Theme.Colors.TextPrimary
    titleLbl.TextSize = 12
    titleLbl.Font = Theme.Fonts.Bold
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = toast

    local msgLbl = Instance.new("TextLabel")
    msgLbl.Size = UDim2.new(1, -26, 0, 18)
    msgLbl.Position = UDim2.new(0, 18, 0, 26)
    msgLbl.BackgroundTransparency = 1
    msgLbl.Text = message
    msgLbl.TextColor3 = Theme.Colors.TextSecondary
    msgLbl.TextSize = 10
    msgLbl.Font = Theme.Fonts.Body
    msgLbl.TextXAlignment = Enum.TextXAlignment.Left
    msgLbl.TextTruncate = Enum.TextTruncate.AtEnd
    msgLbl.Parent = toast

    -- Slide in animation
    Theme.Tween(toast, 0.22, { BackgroundTransparency = 0 })
    
    -- Lifetime countdown & Slide out
    task.delay(dur, function()
        if toast and toast.Parent then
            local tw = Theme.Tween(toast, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(titleLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(msgLbl, 0.2, { TextTransparency = 1 })
            Theme.Tween(sideBar, 0.2, { BackgroundTransparency = 1 })
            Theme.Tween(stroke, 0.2, { Transparency = 1 })
            tw.Completed:Connect(function()
                toast:Destroy()
            end)
        end
    end)
end

function Notifications:Destroy()
    if self._container then
        self._container:Destroy()
        self._container = nil :: any
    end
end

return Notifications

end
__modules["UI/Notifications"] = __modules["UI.Notifications"]

-- ============================================================================
-- Module: UI.Sidebar
-- ============================================================================
__modules["UI.Sidebar"] = function()
--!strict
local Theme = require("UI.Theme")

local Sidebar = {}
Sidebar.__index = Sidebar

export type TabDef = {
    Name: string,
    Icon: string?,
}

function Sidebar.new(parent: Instance, accentName: string?, onTabSelected: (string) -> ())
    local accent = Theme.GetAccent(accentName)

    local sidebarFrame = Instance.new("Frame")
    sidebarFrame.Name = "Sidebar"
    sidebarFrame.Size = UDim2.new(0, 160, 1, 0)
    sidebarFrame.BackgroundColor3 = Theme.Colors.Sidebar
    sidebarFrame.BorderSizePixel = 0
    sidebarFrame.Parent = parent

    -- Right separator line
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(0, 1, 1, 0)
    sep.Position = UDim2.new(1, -1, 0, 0)
    sep.BackgroundColor3 = Theme.Colors.BorderSubtle
    sep.BorderSizePixel = 0
    sep.Parent = sidebarFrame

    -- Branding Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 56)
    header.BackgroundTransparency = 1
    header.Parent = sidebarFrame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -24, 0, 20)
    title.Position = UDim2.new(0, 16, 0, 12)
    title.BackgroundTransparency = 1
    title.Text = "TSB HUB"
    title.TextColor3 = Theme.Colors.TextPrimary
    title.TextSize = 15
    title.Font = Theme.Fonts.Title
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -24, 0, 14)
    subtitle.Position = UDim2.new(0, 16, 0, 32)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "v9.0 SPECIALIST"
    subtitle.TextColor3 = accent.Primary
    subtitle.TextSize = 9
    subtitle.Font = Theme.Fonts.Bold
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.Parent = header

    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.Position = UDim2.new(1, -20, 0, 18)
    statusDot.BackgroundColor3 = Theme.Colors.Success
    statusDot.BorderSizePixel = 0
    statusDot.Parent = header
    Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

    -- Tab Button Container
    local tabContainer = Instance.new("ScrollingFrame")
    tabContainer.Name = "TabButtons"
    tabContainer.Size = UDim2.new(1, 0, 1, -64)
    tabContainer.Position = UDim2.new(0, 0, 0, 60)
    tabContainer.BackgroundTransparency = 1
    tabContainer.BorderSizePixel = 0
    tabContainer.ScrollBarThickness = 0
    tabContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tabContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
    tabContainer.Parent = sidebarFrame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.Parent = tabContainer

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = tabContainer

    local self = setmetatable({
        _frame = sidebarFrame,
        _container = tabContainer,
        _accentName = accentName or "Cyan Neon",
        _buttons = {},
        _activeTab = nil :: string?,
        _onTabSelected = onTabSelected,
    }, Sidebar)

    return self
end

function Sidebar:AddCategory(categoryName: string, layoutOrder: number)
    local catLabel = Instance.new("TextLabel")
    catLabel.Name = "Category_" .. categoryName
    catLabel.Size = UDim2.new(1, 0, 0, 18)
    catLabel.BackgroundTransparency = 1
    catLabel.Text = "  " .. string.upper(categoryName)
    catLabel.TextColor3 = Theme.Colors.TextDim
    catLabel.TextSize = 9
    catLabel.Font = Theme.Fonts.Bold
    catLabel.TextXAlignment = Enum.TextXAlignment.Left
    catLabel.LayoutOrder = layoutOrder
    catLabel.Parent = self._container
end

function Sidebar:AddTab(tabName: string, iconSymbol: string?, layoutOrder: number)
    local accent = Theme.GetAccent(self._accentName)

    local btn = Instance.new("TextButton")
    btn.Name = "Tab_" .. tabName
    btn.Size = UDim2.new(1, 0, 0, 32)
    btn.BackgroundColor3 = Theme.Colors.Sidebar
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = layoutOrder or 1
    btn.Parent = self._container
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    -- Active Indicator line
    local indicator = Instance.new("Frame")
    indicator.Name = "Indicator"
    indicator.Size = UDim2.new(0, 3, 0, 14)
    indicator.Position = UDim2.new(0, 4, 0.5, -7)
    indicator.BackgroundColor3 = accent.Primary
    indicator.BorderSizePixel = 0
    indicator.BackgroundTransparency = 1
    indicator.Parent = btn
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 16, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = (iconSymbol and (iconSymbol .. "  ") or "") .. tabName
    lbl.TextColor3 = Theme.Colors.TextSecondary
    lbl.TextSize = 11
    lbl.Font = Theme.Fonts.Subtitle
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = btn

    local this = self
    btn.MouseEnter:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextPrimary })
        end
    end)
    btn.MouseLeave:Connect(function()
        if this._activeTab ~= tabName then
            Theme.Tween(btn, 0.12, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(lbl, 0.12, { TextColor3 = Theme.Colors.TextSecondary })
        end
    end)
    btn.MouseButton1Click:Connect(function()
        this:SetActive(tabName)
    end)

    self._buttons[tabName] = {
        Button = btn,
        Label = lbl,
        Indicator = indicator,
    }
end

function Sidebar:SetActive(tabName: string)
    self._activeTab = tabName
    local accent = Theme.GetAccent(self._accentName)

    for name, item in pairs(self._buttons) do
        if name == tabName then
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Card })
            Theme.Tween(item.Label, 0.15, { TextColor3 = accent.Primary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 0 })
        else
            Theme.Tween(item.Button, 0.15, { BackgroundColor3 = Theme.Colors.Sidebar })
            Theme.Tween(item.Label, 0.15, { TextColor3 = Theme.Colors.TextSecondary })
            Theme.Tween(item.Indicator, 0.15, { BackgroundTransparency = 1 })
        end
    end

    if self._onTabSelected then
        pcall(self._onTabSelected, tabName)
    end
end

function Sidebar:Destroy()
    if self._frame then
        self._frame:Destroy()
        self._frame = nil :: any
    end
    table.clear(self._buttons)
end

return Sidebar

end
__modules["UI/Sidebar"] = __modules["UI.Sidebar"]

-- ============================================================================
-- Module: UI.Tabs.Combat
-- ============================================================================
__modules["UI.Tabs.Combat"] = function()
--!strict
local Components = require("UI.Components")

local CombatTab = {}

function CombatTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    -- =========================================================================
    -- SECTION: AUTO TECH (KittyWare line 2169-2182)
    -- =========================================================================
    Components.Section(parent, "Auto Tech", accent)
    Components.InfoBanner(parent, "KittyWare 1:1 Auto Tech Engine (Multi-Variant)", "Info", accent)

    Components.Toggle(parent, "Enabled", "Master toggle for automatic dash/tech follow-up", cfg.Combat.AutoTechEnabled or false, accent, function(val)
        cfg.Combat.AutoTechEnabled = val
        if notifs then
            notifs:Show("Auto Tech", val and "Auto Tech Activated" or "Auto Tech Deactivated", 2, val and "Success" or "Warning")
        end
    end)

    Components.Dropdown(parent, "Auto Tech Variant", {
        "Kiba",
        "Supa",
        "Lock On Dash",
        "Loop Dash",
        "Loop Dash v2",
        "Custom Dash",
        "Custom Dash v2"
    }, cfg.Combat.AutoTechVariant or "Loop Dash", accent, function(val)
        cfg.Combat.AutoTechVariant = val
    end)

    Components.Dropdown(parent, "Auto Tech Method", {
        "Perform Always",
        "Perform Once"
    }, cfg.Combat.AutoTechMethod or "Perform Always", accent, function(val)
        cfg.Combat.AutoTechMethod = val
    end)

    Components.Keybind(parent, "Single Perform Keybind", cfg.Keybinds.SinglePerformKey or Enum.KeyCode.V, accent, function(key)
        cfg.Keybinds.SinglePerformKey = key
    end)

    Components.Button(parent, "Arm Single Perform", "Arm Once", "Primary", accent, function()
        cfg.Combat.AutoTechPerformOnce = true
        if notifs then
            notifs:Show("Auto Tech", "Single Perform Armed for next hit!", 2, "Success")
        end
    end)

    Components.Toggle(parent, "Auto Tech Notifications", "Show alerts when tech executes", cfg.Combat.AutoTechNotifications ~= false, accent, function(val)
        cfg.Combat.AutoTechNotifications = val
    end)

    -- =========================================================================
    -- SECTION: AUTO TECH SETTINGS (KittyWare line 2183-2191)
    -- =========================================================================
    Components.Section(parent, "Auto Tech Settings", accent)

    Components.Slider(parent, "Loop v2 Precision", 0, 100, cfg.Combat.Loopv2Precision or 35, "%", 1, accent, function(val)
        cfg.Combat.Loopv2Precision = val
    end)

    Components.Slider(parent, "Loop v2 First Flick Angle", -360, 360, cfg.Combat.Loopv2FirstFlick or 0, "°", 5, accent, function(val)
        cfg.Combat.Loopv2FirstFlick = val
    end)

    Components.Slider(parent, "Loop v2 Second Flick Delay", 0, 50, cfg.Combat.Loopv2SecondFlick or 5, " ms", 1, accent, function(val)
        cfg.Combat.Loopv2SecondFlick = val
    end)

    Components.Toggle(parent, "Loop v2 Jump", "Add vertical boost during Loop Dash v2", cfg.Combat.Loopv2Jump or false, accent, function(val)
        cfg.Combat.Loopv2Jump = val
    end)

    Components.Toggle(parent, "Loop v2 Rotate Camera", "Rotate camera alongside character flick", cfg.Combat.Loopv2RotateCam or false, accent, function(val)
        cfg.Combat.Loopv2RotateCam = val
    end)

    Components.Slider(parent, "Lockon Dash Precision", 0, 100, cfg.Combat.LockonPrecision or 100, "%", 1, accent, function(val)
        cfg.Combat.LockonPrecision = val
    end)

    Components.Slider(parent, "Execution Delay / Timing", 0.15, 0.65, cfg.Combat.AutoTechDelay or 0.38, "s", 0.01, accent, function(val)
        cfg.Combat.AutoTechDelay = val
    end)

    Components.Toggle(parent, "Auto M1 After Tech", "Automatically swing M1 to catch enemy out of the air", cfg.Combat.AutoTechAutoM1 or false, accent, function(val)
        cfg.Combat.AutoTechAutoM1 = val
    end)

    Components.Toggle(parent, "Loop Dash Looks Up", "Makes loop dash look up so it lands consistently", cfg.Combat.LoopDashLooksUp or false, accent, function(val)
        cfg.Combat.LoopDashLooksUp = val
    end)

    -- =========================================================================
    -- SECTION: CUSTOM DASH (KittyWare line 2192-2202)
    -- =========================================================================
    Components.Section(parent, "Custom Dash", accent)

    Components.Toggle(parent, "Custom Dash Jump", "Add vertical velocity on first flick", cfg.Combat.CustomDashJump or false, accent, function(val)
        cfg.Combat.CustomDashJump = val
    end)

    Components.Toggle(parent, "Rotate Camera", "Rotate camera during flicks", cfg.Combat.CustomDashRotateCam or false, accent, function(val)
        cfg.Combat.CustomDashRotateCam = val
    end)

    Components.Slider(parent, "First Flick Angle", -360, 360, cfg.Combat.CustomDashStartFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashStartFlickAngle = val
    end)

    Components.Slider(parent, "Second Flick Delay", 0, 50, cfg.Combat.CustomDashSecondFlickDelay or 5, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashSecondFlickDelay = val
    end)

    Components.Slider(parent, "Second Flick Angle", -360, 360, cfg.Combat.CustomDashSecondFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashSecondFlickAngle = val
    end)

    Components.Slider(parent, "Third Flick Delay", 0, 50, cfg.Combat.CustomDashThirdFlickDelay or 5, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashThirdFlickDelay = val
    end)

    Components.Slider(parent, "Third Flick Angle", -360, 360, cfg.Combat.CustomDashThirdFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashThirdFlickAngle = val
    end)

    Components.Toggle(parent, "Lock On", "Lock on target after flick sequence", cfg.Combat.CustomDashLockOn or false, accent, function(val)
        cfg.Combat.CustomDashLockOn = val
    end)

    Components.Dropdown(parent, "Lock On After", { "Second Flick", "Third Flick" }, cfg.Combat.CustomDashLockOnAfter or "Second Flick", accent, function(val)
        cfg.Combat.CustomDashLockOnAfter = val
    end)

    Components.Slider(parent, "Lock On Precision", 0, 100, cfg.Combat.CustomDashLockOnPrecision or 100, "%", 1, accent, function(val)
        cfg.Combat.CustomDashLockOnPrecision = val
    end)

    Components.Slider(parent, "Lock On Delay", 0, 10, cfg.Combat.CustomDashLockOnDelay or 0, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashLockOnDelay = val
    end)

    -- =========================================================================
    -- SECTION: CUSTOM DASH V2 (KittyWare line 2203-2215)
    -- =========================================================================
    Components.Section(parent, "Custom Dash v2", accent)

    Components.Toggle(parent, "Custom Dash v2 Jump", "Add vertical velocity on smooth flick start", cfg.Combat.CustomDashv2Jump or false, accent, function(val)
        cfg.Combat.CustomDashv2Jump = val
    end)

    Components.Toggle(parent, "v2 Rotate Camera", "Rotate camera during smooth flicks", cfg.Combat.CustomDashv2RotateCam or false, accent, function(val)
        cfg.Combat.CustomDashv2RotateCam = val
    end)

    Components.Slider(parent, "v2 First Flick Angle", -360, 360, cfg.Combat.CustomDashv2StartFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashv2StartFlickAngle = val
    end)

    Components.Slider(parent, "v2 Second Flick Delay", 0, 50, cfg.Combat.CustomDashv2SecondFlickDelay or 5, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashv2SecondFlickDelay = val
    end)

    Components.Slider(parent, "v2 Second Flick Duration", 0.05, 2.0, cfg.Combat.CustomDashv2SecondFlickDuration or 0.35, "s", 0.05, accent, function(val)
        cfg.Combat.CustomDashv2SecondFlickDuration = val
    end)

    Components.Slider(parent, "v2 Second Flick Angle", -360, 360, cfg.Combat.CustomDashv2SecondFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashv2SecondFlickAngle = val
    end)

    Components.Slider(parent, "v2 Third Flick Delay", 0, 50, cfg.Combat.CustomDashv2ThirdFlickDelay or 5, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashv2ThirdFlickDelay = val
    end)

    Components.Slider(parent, "v2 Third Flick Duration", 0.05, 2.0, cfg.Combat.CustomDashv2ThirdFlickDuration or 0.35, "s", 0.05, accent, function(val)
        cfg.Combat.CustomDashv2ThirdFlickDuration = val
    end)

    Components.Slider(parent, "v2 Third Flick Angle", -360, 360, cfg.Combat.CustomDashv2ThirdFlickAngle or 0, "°", 5, accent, function(val)
        cfg.Combat.CustomDashv2ThirdFlickAngle = val
    end)

    Components.Toggle(parent, "v2 Lock On", "Smooth lock on target after flick", cfg.Combat.CustomDashv2LockOn or false, accent, function(val)
        cfg.Combat.CustomDashv2LockOn = val
    end)

    Components.Dropdown(parent, "v2 Lock On After", { "Second Flick", "Third Flick" }, cfg.Combat.CustomDashv2LockOnAfter or "Second Flick", accent, function(val)
        cfg.Combat.CustomDashv2LockOnAfter = val
    end)

    Components.Slider(parent, "v2 Lock On Precision", 0, 100, cfg.Combat.CustomDashv2LockOnPrecision or 100, "%", 1, accent, function(val)
        cfg.Combat.CustomDashv2LockOnPrecision = val
    end)

    Components.Slider(parent, "v2 Lock On Delay", 0, 10, cfg.Combat.CustomDashv2LockOnDelay or 0, " ms", 1, accent, function(val)
        cfg.Combat.CustomDashv2LockOnDelay = val
    end)
end

return CombatTab
end

__modules["UI.Tabs.Skills"] = function()
--!strict
local Components = require("UI.Components")

local SkillsTab = {}

function SkillsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName

    Components.Section(parent, "Skill Aiming & Automation", accent)
    Components.Toggle(parent, "Auto Aim Skills", "Rotate character to target on skill cast", cfg.Skills.AutoAim, accent, function(val)
        cfg.Skills.AutoAim = val
    end)

    Components.Toggle(parent, "Auto Skill Spam", "Fire skills as soon as cooldown finishes", cfg.Skills.AutoSkillSpam, accent, function(val)
        cfg.Skills.AutoSkillSpam = val
    end)

    Components.Slider(parent, "Skill Spam Delay", 0.1, 1.0, cfg.Skills.SkillSpamDelay or 0.25, "s", 0.05, accent, function(val)
        cfg.Skills.SkillSpamDelay = val
    end)

    Components.Toggle(parent, "Auto Ultimate Spam", "Instantly trigger awakening when gauge is full", cfg.Skills.AutoUltSpam, accent, function(val)
        cfg.Skills.AutoUltSpam = val
    end)

    Components.Section(parent, "Void Elimination", accent)
    Components.Toggle(parent, "Void Kill", "Teleport grabbed enemy into the void", cfg.Skills.VoidKill, accent, function(val)
        cfg.Skills.VoidKill = val
    end)

    Components.Slider(parent, "Void Depth", -500, -100, cfg.Skills.VoidDepth or -350, " studs", 10, accent, function(val)
        cfg.Skills.VoidDepth = val
    end)

    Components.Slider(parent, "Void Return Delay", 0.2, 2.0, cfg.Skills.VoidReturnDelay or 0.5, "s", 0.1, accent, function(val)
        cfg.Skills.VoidReturnDelay = val
    end)
end

return SkillsTab

end
__modules["UI/Tabs/Skills"] = __modules["UI.Tabs.Skills"]

-- ============================================================================
-- Module: UI.Tabs.Survival
-- ============================================================================
__modules["UI.Tabs.Survival"] = function()
--!strict
local Components = require("UI.Components")

local SurvivalTab = {}

function SurvivalTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local fm = ctx.FeatureManager
    local notifs = ctx.Notifications
    local accent = ctx.AccentName

    local feat = fm:GetFeature("SurvivalEngine")
    local isEngineRunning = feat and feat.Enabled or true

    Components.Section(parent, "Master Pipeline Control", accent)
    Components.Toggle(parent, "Survival Engine Pipeline", "Controls Heartbeat survival and FSM evasion checks", isEngineRunning, accent, function(val)
        fm:SetEnabled("SurvivalEngine", val, ctx.Container)
        notifs:Show("Survival Engine", val and "Pipeline Activated" or "Pipeline Deactivated", 2.0, val and "Success" or "Warning")
    end)

    Components.Section(parent, "Sky Teleport Emergency Escape", accent)
    Components.Toggle(parent, "Sky Teleport", "Escape into the sky upon critical health", cfg.Survival.SkyTeleport, accent, function(val)
        cfg.Survival.SkyTeleport = val
    end)

    Components.Slider(parent, "Escape HP Threshold", 10, 60, cfg.Survival.SkyEscapeHP or 30, " HP", 5, accent, function(val)
        cfg.Survival.SkyEscapeHP = val
    end)

    Components.Slider(parent, "Return HP Threshold", 50, 100, cfg.Survival.SkyReturnHP or 80, " HP", 5, accent, function(val)
        cfg.Survival.SkyReturnHP = val
    end)

    Components.Slider(parent, "Escape Height", 50, 400, cfg.Survival.SkyEscapeHeight or 180, " studs", 10, accent, function(val)
        cfg.Survival.SkyEscapeHeight = val
    end)

    Components.Section(parent, "Sky Dodge Reflex", accent)
    Components.Toggle(parent, "Sky Dodge", "Automatic vertical hop to dodge unblockable strikes", cfg.Survival.SkyDodge, accent, function(val)
        cfg.Survival.SkyDodge = val
    end)

    Components.Slider(parent, "Dodge Height", 20, 150, cfg.Survival.SkyDodgeHeight or 65, " studs", 5, accent, function(val)
        cfg.Survival.SkyDodgeHeight = val
    end)

    Components.Slider(parent, "Trigger Range", 5, 30, cfg.Survival.SkyDodgeRange or 18, " studs", 1, accent, function(val)
        cfg.Survival.SkyDodgeRange = val
    end)

    Components.Toggle(parent, "Lock Camera During Dodge", "Keep camera tracking target while in mid-air", cfg.Survival.SkyDodgeLockCamera, accent, function(val)
        cfg.Survival.SkyDodgeLockCamera = val
    end)
end

return SurvivalTab

end
__modules["UI/Tabs/Survival"] = __modules["UI.Tabs.Survival"]

-- ============================================================================
-- Module: UI.Tabs.Target
-- ============================================================================
__modules["UI.Tabs.Target"] = function()
--!strict
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Components = require("UI.Components")
local Theme = require("UI.Theme")
local Maid = require("Core.Maid")

local TargetTab = {}

function TargetTab.Build(parent: Instance, ctx: any)
    local maid = Maid.new()
    local alive = true
    maid:GiveTask(parent.AncestryChanged:Connect(function(_, newParent)
        if newParent == nil then
            alive = false
            maid:DoCleaning()
        end
    end))
    local cfg = ctx.ConfigManager.Config
    local notifs = ctx.Notifications
    local accent = ctx.AccentName
    if not cfg.Target then cfg.Target = {} end

    -- Section: Target Selection & Filtering
    Components.Section(parent, "Target Selection & Filtering", accent)
    Components.InfoBanner(parent, "Lowest HP compares current HP. Distance is only a tie-breaker. Behind TP uses the same selector.", "Info", accent)

    local playerDropdownRef: any = nil
    local nameToPlayerMap = {}

    Components.Dropdown(parent, "Targeting Mode", { "Nearest", "Lowest HP", "Random", "Specific Player" }, cfg.Target.TargetMode or "Nearest", accent, function(val)
        cfg.Target.TargetMode = val
        ctx.ConfigManager:Commit()
        local combat = ctx.Container and ctx.Container:Get("Combat")
        if combat then
            combat.CurrentTarget = nil
            combat._stickyRandomTarget = nil
        end
        if val ~= "Specific Player" then
            cfg.Target.SpecificPlayer = "None"
            if playerDropdownRef and playerDropdownRef.Select then
                playerDropdownRef.Select("None")
            end
        end
        notifs:Show("Target Mode", "Targeting mode: " .. val, 2.0, "Info")
    end)

    Components.Toggle(parent, "Target Entire Map", "Use all valid opponents on the map; disable to use Target Search Range", cfg.Target.WholeMap ~= false, accent, function(val)
        cfg.Target.WholeMap = val
        ctx.ConfigManager:Commit()
    end)

    Components.Slider(parent, "Target Search Range", 25, 1000, cfg.Target.TargetRange or 200, " studs", 25, accent, function(val)
        cfg.Target.TargetRange = val
        ctx.ConfigManager:Commit()
    end)

    Components.Toggle(parent, "Ignore Teammates", "Do not target players on your team", cfg.Target.IgnoreTeam ~= false, accent, function(val)
        cfg.Target.IgnoreTeam = val
        ctx.ConfigManager:Commit()
    end)

    -- Specific Player Dynamic List with DisplayName (@Username) formatting
    local function GetFormattedPlayerList(): ({ string }, { [string]: string })
        local list = { "None" }
        local map = { ["None"] = "None" }
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                local formatted = string.format("%s (@%s)", p.DisplayName, p.Name)
                table.insert(list, formatted)
                map[formatted] = p.Name
                map[p.Name] = formatted
            end
        end
        return list, map
    end

    local playerList, pMap = GetFormattedPlayerList()
    nameToPlayerMap = pMap

    local curSpecific = cfg.Target.SpecificPlayer or "None"
    local initialDisplay = nameToPlayerMap[curSpecific] or "None"

    playerDropdownRef = Components.Dropdown(parent, "Select Specific Player", playerList, initialDisplay, accent, function(selectedDisplay)
        local rawName = nameToPlayerMap[selectedDisplay] or selectedDisplay
        cfg.Target.SpecificPlayer = rawName
        local combat = ctx.Container and ctx.Container:Get("Combat")
        if rawName ~= "None" then
            cfg.Target.TargetMode = "Specific Player"
            ctx.ConfigManager:Commit()
            local p = Players:FindFirstChild(rawName)
            if combat then combat.CurrentTarget = p end
            notifs:Show("Target Locked", "Target set to: " .. selectedDisplay, 2.0, "Success")
        else
            if cfg.Target.TargetMode == "Specific Player" then
                cfg.Target.TargetMode = "Nearest"
            end
            if combat then combat.CurrentTarget = nil end
            ctx.ConfigManager:Commit()
            notifs:Show("Target Reset", "Specific target cleared.", 2.0, "Info")
        end
    end)

    local function RefreshPlayers()
        local freshList, freshMap = GetFormattedPlayerList()
        nameToPlayerMap = freshMap
        if playerDropdownRef and playerDropdownRef.SetOptions then
            playerDropdownRef.SetOptions(freshList)
        end
    end

    maid:GiveTask(Players.PlayerAdded:Connect(function()
        task.delay(1, function() if alive then RefreshPlayers() end end)
    end))
    maid:GiveTask(Players.PlayerRemoving:Connect(function(leaving)
        if cfg.Target.SpecificPlayer == leaving.Name then
            cfg.Target.SpecificPlayer = "None"
            cfg.Target.TargetMode = "Nearest"
        end
        task.delay(0.5, function() if alive then RefreshPlayers() end end)
    end))

    Components.Button(parent, "Refresh Online Player List", "Refresh Players", "Secondary", accent, function()
        local freshList = GetFormattedPlayerList()
        RefreshPlayers()
        notifs:Show("Player List", string.format("Refreshed! Found %d players.", math.max(#freshList - 1, 0)), 2.0, "Info")
    end)

    Components.InfoBanner(parent, "Target selection is shared by Behind TP, Auto Aim, Void Kill and skill tracking. The selector below uses CURRENT HP for Lowest HP.", "Info", accent)
    do
        local combat = ctx.Container and ctx.Container:Get("Combat")
        if combat and combat.GetTargetDebug then
            Components.InfoBanner(parent, combat:GetTargetDebug(cfg), "Success", accent)
        end
    end

    -- Section: Behind TP Lock & Distance
    Components.Toggle(parent, "Behind TP", "Stay locked directly behind target's back", cfg.Target.BehindTP or false, accent, function(val)
        cfg.Target.BehindTP = val
        ctx.ConfigManager:Commit()
        if val then
            local combat = ctx.Container and ctx.Container:Get("Combat")
            local t = combat and combat:GetTarget(cfg)
            local tName = t and (t.DisplayName or t.Name) or "Target"
            notifs:Show("⚡ Behind TP", "Locked behind " .. tName, 2.0, "Success")
        else
            notifs:Show("Behind TP", "Behind lock disabled.", 2.0, "Warning")
        end
    end)

    Components.Slider(parent, "Behind Distance", 0.0, 5.0, cfg.Target.BehindDistance or 3.0, " studs", 0.5, accent, function(val)
        cfg.Target.BehindDistance = val
        ctx.ConfigManager:Commit()
    end)
end

return TargetTab
end

-- ============================================================================
-- Module: UI.Tabs.Visuals
-- ============================================================================
__modules["UI.Tabs.Visuals"] = function()
--!strict
local Components=require("UI.Components")
local VisualsTab={}
function VisualsTab.Build(parent:Instance,ctx:any)
    local cfg=ctx.ConfigManager.Config; local accent=ctx.AccentName
    local colors={"Cyan","Green","Blue","Yellow","Orange","Red","Purple","Pink","White"}
    Components.Section(parent,"ESP & Character Identity",accent)
    Components.InfoBanner(parent,"Character detection reads the player's actual skill Tools. It does not use the character model name, so false labels like 'Ester' are not treated as a fighter.","Info",accent)
    Components.Toggle(parent,"ESP","Color-coded silhouette visible through walls",cfg.Visuals.HighlightESP,accent,function(v) cfg.Visuals.HighlightESP=v;ctx.ConfigManager:Commit() end)
    Components.Toggle(parent,"Use Character-Specific Colors","Saitama/Garou/etc. override the default ESP color",cfg.Visuals.UseCharacterColors~=false,accent,function(v) cfg.Visuals.UseCharacterColors=v;ctx.ConfigManager:Commit() end)
    Components.Dropdown(parent,"Default ESP Color",colors,cfg.Visuals.HighlightColor or "Cyan",accent,function(v) cfg.Visuals.HighlightColor=v end)
    Components.Toggle(parent,"Info ESP","Show player name, HP and distance",cfg.Visuals.BillboardESP,accent,function(v) cfg.Visuals.BillboardESP=v;ctx.ConfigManager:Commit() end)
    Components.Toggle(parent,"Character ESP","Show [Saitama], [Garou], etc. above the player",cfg.Visuals.ShowCharacterESP,accent,function(v) cfg.Visuals.ShowCharacterESP=v;ctx.ConfigManager:Commit() end)

    Components.Section(parent,"Character Colors",accent)
    local characterColors={
        {"Saitama ESP Color","SaitamaESPColor","Green"},{"Garou ESP Color","GarouESPColor","Blue"},{"Genos ESP Color","GenosESPColor","Red"},{"Sonic ESP Color","SonicESPColor","Yellow"},{"Metal Bat ESP Color","MetalBatESPColor","Orange"},{"Atomic Samurai ESP Color","AtomicESPColor","Purple"},{"Tatsumaki ESP Color","TatsumakiESPColor","Pink"},{"Suiryu ESP Color","SuiryuESPColor","Orange"},{"Child Emperor ESP Color","ChildEmperorESPColor","Yellow"},{"Zombie Man ESP Color","ZombieManESPColor","White"},{"Gojo ESP Color","GojoESPColor","Purple"},{"KJ ESP Color","KJESPColor","Red"},{"Frozen Soul ESP Color","FrozenSoulESPColor","Cyan"},{"Other Character Color","OtherCharacterESPColor","Cyan"},
    }
    for _,row in ipairs(characterColors) do Components.Dropdown(parent,row[1],colors,cfg.Visuals[row[2]] or row[3],accent,function(v) cfg.Visuals[row[2]]=v;ctx.ConfigManager:Commit() end) end

    Components.Section(parent,"Saitama Death Counter",accent)
    Components.InfoBanner(parent,"Saitama awakening is sticky for the current character life. When the awakening has been seen and Death Counter is no longer present, the warning appears until the normal Saitama kit returns.","Warning",accent)
    Components.Toggle(parent,"Death Counter Risk ESP","Show 'Death Counter Risk' over Saitama when Death Counter is unavailable",cfg.Visuals.ShowDeathCounterRisk~=false,accent,function(v) cfg.Visuals.ShowDeathCounterRisk=v end)
    Components.Dropdown(parent,"Death Counter Risk Color",colors,cfg.Visuals.DeathCounterRiskColor or "Red",accent,function(v) cfg.Visuals.DeathCounterRiskColor=v end)
end
return VisualsTab
end

-- ============================================================================
-- Module: UI.Tabs.World
-- ============================================================================
__modules["UI.Tabs.World"] = function()
--!strict
local Components = require("UI.Components")

local WorldTab = {}

function WorldTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName
    local notifs = ctx.Notifications

    local function GetWorld(): any?
        if ctx.Container and ctx.Container:Has("World") then
            return ctx.Container:Get("World")
        end
        return nil
    end

    Components.Section(parent, "Lighting & Atmosphere", accent)
    Components.Toggle(parent, "FullBright", "Amplify world ambient lighting to maximum", cfg.World.FullBright, accent, function(val)
        cfg.World.FullBright = val
        local w = GetWorld()
        if w then w:ToggleFullBright(val) end
    end)

    Components.Toggle(parent, "Remove Fog", "Clear atmosphere fog, blur and distance haze", cfg.World.RemoveFog, accent, function(val)
        cfg.World.RemoveFog = val
        local w = GetWorld()
        if w then w:ToggleRemoveFog(val) end
    end)

    Components.Toggle(parent, "Custom Field of View", "Override camera rendering angle", cfg.World.CustomFOV, accent, function(val)
        cfg.World.CustomFOV = val
        local w = GetWorld()
        if w then w:ToggleCustomFOV(val, cfg.World.FOVValue) end
    end)

    Components.Slider(parent, "FOV Value", 60, 120, cfg.World.FOVValue or 90, "°", 1, accent, function(val)
        cfg.World.FOVValue = val
        if cfg.World.CustomFOV then
            local w = GetWorld()
            if w then w:ToggleCustomFOV(true, val) end
        end
    end)

    Components.Section(parent, "Server & Anti-Disconnect", accent)
    Components.Toggle(parent, "Anti-AFK Protection", "Bypass Roblox 20-minute idle disconnection", cfg.World.AntiAFK, accent, function(val)
        cfg.World.AntiAFK = val
        notifs:Show("Anti-AFK", val and "Anti-AFK ENABLED" or "Anti-AFK DISABLED", 2.0, val and "Success" or "Warning")
    end)

    Components.Toggle(parent, "Auto Server Hop", "Find and hop to full server when match empties", cfg.World.AutoServerHop, accent, function(val)
        cfg.World.AutoServerHop = val
    end)

    Components.Slider(parent, "Hop Trigger Min Players", 2, 8, cfg.World.AutoHopMinPlayers or 4, " players", 1, accent, function(val)
        cfg.World.AutoHopMinPlayers = val
    end)

    Components.Button(parent, "Force Server Hop Now", "Hop Now", "Danger", accent, function()
        local w = GetWorld()
        if w then
            w.HopActive = false
            w:ServerHop()
            notifs:Show("Server Hop", "Searching for new server...", 2.5, "Warning")
        end
    end)
end

return WorldTab

end
__modules["UI/Tabs/World"] = __modules["UI.Tabs.World"]

-- ============================================================================
-- Module: UI.Tabs.Movement
-- ============================================================================
__modules["UI.Tabs.Movement"] = function()
--!strict
local Components = require("UI.Components")

local MovementTab = {}

function MovementTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName
    local notifs = ctx.Notifications
    local movement = ctx.Container and ctx.Container:Has("Movement") and ctx.Container:Get("Movement")

    Components.Section(parent, "Locomotion & Speed", accent)
    Components.InfoBanner(parent, "Infinite Jump is the only extra-jump system. Double Jump is removed. Anti-Void now saves real grounded positions and restores from the void instead of assuming the floor is Y=0.", "Info", accent)

    Components.Toggle(parent, "Speed Boost", "Accelerate walk speed dynamically", cfg.Movement.SpeedBoost, accent, function(val)
        cfg.Movement.SpeedBoost = val
        if movement and movement.SetSpeed then
            movement:SetSpeed(val, cfg.Movement.SpeedVal)
        end
    end)

    Components.Slider(parent, "Speed Value", 16, 150, cfg.Movement.SpeedVal or 42, " studs/s", 1, accent, function(val)
        cfg.Movement.SpeedVal = val
        if cfg.Movement.SpeedBoost and movement and movement.SetSpeed then
            movement:SetSpeed(true, val)
        end
    end)

    Components.Toggle(parent, "Infinite Jump", "Jump infinitely in air without ground contact", cfg.Movement.InfiniteJump, accent, function(val)
        cfg.Movement.InfiniteJump = val
        if movement and movement.ToggleInfiniteJump then
            movement:ToggleInfiniteJump(val)
        end
    end)

    Components.Section(parent, "Flight & Collision", accent)

    Components.Toggle(parent, "Fly", "Freely fly in 3D camera space", cfg.Movement.Fly, accent, function(val)
        cfg.Movement.Fly = val
        if movement and movement.ToggleFly then
            movement:ToggleFly(val, cfg)
        end
    end)

    Components.Slider(parent, "Fly Speed", 10, 200, cfg.Movement.FlySpeed or 60, " studs/s", 5, accent, function(val)
        cfg.Movement.FlySpeed = val
    end)

    Components.Dropdown(parent, "Fly Mode", { "CFrame", "Velocity" }, cfg.Movement.FlyMode or "CFrame", accent, function(val)
        cfg.Movement.FlyMode = val
    end)

    Components.Toggle(parent, "Noclip", "Phase through walls and collisions", cfg.Movement.Noclip, accent, function(val)
        cfg.Movement.Noclip = val
        if movement and movement.ToggleNoclip then
            movement:ToggleNoclip(val)
        end
    end)

    Components.Toggle(parent, "Anti-Void", "Safety return to ground when falling into void", cfg.Movement.AntiVoid, accent, function(val)
        cfg.Movement.AntiVoid = val
    end)
end

return MovementTab
end
__modules["UI/Tabs/Movement"] = __modules["UI.Tabs.Movement"]

-- ============================================================================
-- Module: UI.Tabs.Keybinds
-- ============================================================================
__modules["UI.Tabs.Keybinds"] = function()
--!strict
local Components = require("UI.Components")

local KeybindsTab = {}

function KeybindsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    Components.InfoBanner(parent, "Keyboard shortcuts change the same runtime config used by the GUI. The interface is refreshed after shortcut toggles so ON/OFF indicators stay synchronized.", "Info", ctx.AccentName)
    local accent = ctx.AccentName

    Components.Section(parent, "Global Shortcuts", accent)

    Components.Keybind(parent, "Toggle GUI", cfg.Keybinds.ToggleGUI or Enum.KeyCode.RightControl, accent, function(key)
        cfg.Keybinds.ToggleGUI = key
    end)

    Components.Keybind(parent, "Emergency Stop", cfg.Keybinds.EmergencyStop or Enum.KeyCode.Delete, accent, function(key)
        cfg.Keybinds.EmergencyStop = key
    end)

    Components.Section(parent, "Combat & Movement Shortcuts", accent)

    Components.Keybind(parent, "Single Perform Auto Tech", cfg.Keybinds.SinglePerformKey or Enum.KeyCode.V, accent, function(key)
        cfg.Keybinds.SinglePerformKey = key
    end)

    Components.Keybind(parent, "Toggle Fly", cfg.Keybinds.ToggleFly or Enum.KeyCode.F5, accent, function(key)
        cfg.Keybinds.ToggleFly = key
    end)

    Components.Keybind(parent, "Toggle Noclip", cfg.Keybinds.ToggleNoclip or Enum.KeyCode.F6, accent, function(key)
        cfg.Keybinds.ToggleNoclip = key
    end)

    Components.Keybind(parent, "Toggle Aimlock", cfg.Keybinds.ToggleAimlock or Enum.KeyCode.F7, accent, function(key)
        cfg.Keybinds.ToggleAimlock = key
    end)

    Components.Keybind(parent, "Toggle Behind TP", cfg.Keybinds.ToggleBehindTP or Enum.KeyCode.F9, accent, function(key)
        cfg.Keybinds.ToggleBehindTP = key
    end)

    Components.Keybind(parent, "Toggle Sky Dodge", cfg.Keybinds.ToggleSkyDodge or Enum.KeyCode.H, accent, function(key)
        cfg.Keybinds.ToggleSkyDodge = key
    end)

    Components.Keybind(parent, "Mass Bring Key", cfg.Keybinds.MassBringKey or Enum.KeyCode.G, accent, function(key)
        cfg.Keybinds.MassBringKey = key
    end)
end

return KeybindsTab
end
__modules["UI/Tabs/Keybinds"] = __modules["UI.Tabs.Keybinds"]

-- ============================================================================
-- Module: UI.Tabs.Settings
-- ============================================================================
__modules["UI.Tabs.Settings"] = function()
--!strict
local Components = require("UI.Components")

local SettingsTab = {}

function SettingsTab.Build(parent: Instance, ctx: any)
    local cfg = ctx.ConfigManager.Config
    local accent = ctx.AccentName
    local notifs = ctx.Notifications
    local cm = ctx.ConfigManager

    Components.Section(parent, "Theme & Appearance", accent)

    Components.Dropdown(parent, "Theme Accent", { "Cyan Neon", "Emerald Green", "Purple Phantom", "Crimson Blood", "Golden Sun", "Pure White" }, cfg.UI.AccentName or "Cyan Neon", accent, function(val)
        cfg.UI.AccentName = val
        if ctx.UIController and ctx.UIController.SetAccent then
            ctx.UIController:SetAccent(val)
        end
        notifs:Show("Theme", "Accent changed to " .. tostring(val), 2.0, "Info")
    end)

    Components.Section(parent, "Configuration Management", accent)

    Components.Toggle(parent, "Auto Save Config", "Save settings periodically", cfg.UI.AutoSave, accent, function(val)
        cfg.UI.AutoSave = val
    end)

    Components.Button(parent, "Save Configuration Now", "Save Config", "Primary", accent, function()
        if cm and cm.Save then
            local ok, err = cm:Save(true)
            if ok then
                notifs:Show("Config", "Configuration saved successfully!", 2.5, "Success")
            else
                notifs:Show("Config", "Save failed: " .. tostring(err), 3.0, "Error")
            end
        end
    end)

    Components.Button(parent, "Reset Settings to Default", "Reset Defaults", "Danger", accent, function()
        if cm and cm.ResetToDefaults then
            cm:ResetToDefaults()
            notifs:Show("Config", "Settings reset to default values", 2.5, "Warning")
        end
    end)
end

return SettingsTab
end
__modules["UI/Tabs/Settings"] = __modules["UI.Tabs.Settings"]


-- ============================================================================
-- Module: Systems.TeleportManager
-- ============================================================================
__modules["Systems.TeleportManager"] = function()
--!strict
local Players=game:GetService("Players")
local HttpService=game:GetService("HttpService")
local LocalPlayer=Players.LocalPlayer
local TeleportManager={};TeleportManager.__index=TeleportManager

local function safeRead(path:string):any
    if typeof(isfile)~="function" or not isfile(path) then return nil end
    local ok,raw=pcall(readfile,path);if not ok then return nil end
    local ok2,data=pcall(function() return HttpService:JSONDecode(raw) end);return ok2 and data or nil
end
local function safeWrite(path:string,data:any):boolean
    if typeof(writefile)~="function" then return false end
    local ok=pcall(writefile,path,HttpService:JSONEncode(data));return ok
end

function TeleportManager.new(deps:{ConfigManager:any,Movement:any?,Logger:any?})
    local self=setmetatable({Path="4080_Hub_TSB_Teleports.json",Points={},_config=deps.ConfigManager,_movement=deps.Movement,_logger=deps.Logger},TeleportManager)
    self:Load();return self
end
function TeleportManager:Load()
    local data=safeRead(self.Path)
    if type(data)=="table" then self.Points=data end
end
function TeleportManager:Save()
    if safeWrite(self.Path,self.Points) then return true end
    return false
end
function TeleportManager:SavePosition(name:string):boolean
    name=tostring(name or ""):match("^%s*(.-)%s*$")
    if name=="" then return false end
    local char=LocalPlayer.Character;local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    if not root or not root:IsA("BasePart") then return false end
    local components={root.CFrame:GetComponents()}
    self.Points[name]={components=components,x=root.Position.X,y=root.Position.Y,z=root.Position.Z}
    self:Save();return true
end
function TeleportManager:DeletePosition(name:string):boolean
    if self.Points[name]==nil then return false end
    self.Points[name]=nil;self:Save();return true
end
function TeleportManager:TeleportTo(name:string):boolean
    local point=self.Points[name];if type(point)~="table" then return false end
    if self._movement and self._movement.SuppressAntiVoid then self._movement:SuppressAntiVoid(1.25) end
    local char=LocalPlayer.Character;local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    if not root or not root:IsA("BasePart") then return false end
    local cf
    if type(point.components) == "table" and #point.components == 12 then
        cf = CFrame.new(table.unpack(point.components))
    else
        cf = CFrame.new(tonumber(point.x) or 0,tonumber(point.y) or 0,tonumber(point.z) or 0)
    end
    local ok=pcall(function() root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero;root.CFrame=cf end)
    return ok
end
function TeleportManager:TeleportReady(kind:string):boolean
    local char=LocalPlayer.Character;local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    if self._movement and self._movement.SuppressAntiVoid then self._movement:SuppressAntiVoid(1.25) end
    if not root or not root:IsA("BasePart") then return false end
    if kind=="Void" then return pcall(function() root.CFrame=CFrame.new(root.Position.X,-350,root.Position.Z);root.AssemblyLinearVelocity=Vector3.zero end) end
    if kind=="Sky" then return pcall(function() root.CFrame=CFrame.new(root.Position.X,root.Position.Y+180,root.Position.Z);root.AssemblyLinearVelocity=Vector3.zero end) end
    if kind=="Safe Position" and self._movement and self._movement.LastSafePos then return pcall(function() root.CFrame=self._movement.LastSafePos+Vector3.new(0,3,0);root.AssemblyLinearVelocity=Vector3.zero end) end
    return false
end
function TeleportManager:TeleportToPlayer(player:Player):boolean
    if not player or player==LocalPlayer then return false end
    if self._movement and self._movement.SuppressAntiVoid then self._movement:SuppressAntiVoid(1.25) end
    local target=player.Character;local tRoot=target and (target:FindFirstChild("HumanoidRootPart") or target:FindFirstChild("Torso"))
    local char=LocalPlayer.Character;local root=char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
    if not tRoot or not root then return false end
    local flatLook=Vector3.new(tRoot.CFrame.LookVector.X,0,tRoot.CFrame.LookVector.Z)
    if flatLook.Magnitude < 0.001 then flatLook=Vector3.new(0,0,-1) end
    flatLook=flatLook.Unit
    return pcall(function() root.CFrame=CFrame.lookAt(tRoot.Position-flatLook*4, tRoot.Position);root.AssemblyLinearVelocity=Vector3.zero end)
end
return TeleportManager
end

-- ============================================================================
-- Module: UI.Tabs.Diagnostics
-- ============================================================================
__modules["UI.Tabs.Teleport"] = function()
--!strict
local Components=require("UI.Components")
local Players=game:GetService("Players")
local TeleportTab={}
function TeleportTab.Build(parent:Instance,ctx:any)
    local accent=ctx.AccentName;local notifs=ctx.Notifications
    local tp=ctx.Container and ctx.Container:Has("TeleportManager") and ctx.Container:Get("TeleportManager")
    if not tp then Components.InfoBanner(parent,"Teleport service unavailable.","Warning",accent);return end

    Components.Section(parent,"Ready Teleports",accent)
    Components.InfoBanner(parent,"Void uses your current X/Z at Y=-350. Sky moves you +180 studs. Safe Position uses the last grounded position known by Anti-Void.","Info",accent)
    for _,name in ipairs({"Void","Sky","Safe Position"}) do
        Components.Button(parent,name,"Teleport","Secondary",accent,function()
            if tp:TeleportReady(name) then notifs:Show("Teleport",name.." teleport complete.",2,"Success") else notifs:Show("Teleport",name.." is unavailable.",2,"Warning") end
        end)
    end

    Components.Section(parent,"Saved Locations",accent)
    local nameBox=Instance.new("TextBox")
    nameBox.Size=UDim2.new(1,0,0,38);nameBox.BackgroundColor3=Color3.fromRGB(22,26,39);nameBox.BorderSizePixel=0;nameBox.PlaceholderText="Location name";nameBox.Text="";nameBox.TextColor3=Color3.fromRGB(245,248,255);nameBox.PlaceholderColor3=Color3.fromRGB(120,125,145);nameBox.TextSize=12;nameBox.Font=Enum.Font.Gotham;nameBox.Parent=parent;Instance.new("UICorner",nameBox).CornerRadius=UDim.new(0,7)
    Components.Button(parent,"Save Current Position","Save","Success",accent,function()
        if tp:SavePosition(nameBox.Text) then
            nameBox.Text=""
            notifs:Show("Teleport", "Location saved.",2,"Success")
            if ctx.UIController then task.defer(function() ctx.UIController:Refresh() end) end
        else notifs:Show("Teleport","Enter a location name first.",2,"Warning") end
    end)

    local savedNames={}
    for name in pairs(tp.Points) do table.insert(savedNames,name) end
    table.sort(savedNames)
    if #savedNames>0 then
        local selected=savedNames[1]
        Components.Dropdown(parent,"Saved Location",savedNames,selected,accent,function(v) selected=v end)
        Components.Button(parent,"Teleport to Saved","Teleport","Secondary",accent,function()
            if tp:TeleportTo(selected) then notifs:Show("Teleport","Teleported to "..selected,2,"Success") else notifs:Show("Teleport","Saved location unavailable.",2,"Warning") end
        end)
        Components.Button(parent,"Delete Saved","Delete","Danger",accent,function()
            if tp:DeletePosition(selected) then
                notifs:Show("Teleport","Deleted "..selected,2,"Info")
                if ctx.UIController then task.defer(function() ctx.UIController:Refresh() end) end
            end
        end)
    else
        Components.InfoBanner(parent,"No saved locations yet. Save your current position above.","Info",accent)
    end

    Components.Section(parent,"Player Teleport",accent)
    local list={};local map={}
    for _,p in ipairs(Players:GetPlayers()) do if p~=Players.LocalPlayer then local label=string.format("%s (@%s)",p.DisplayName,p.Name);table.insert(list,label);map[label]=p end end
    table.sort(list)
    local selectedPlayer=nil
    if #list>0 then
        Components.Dropdown(parent,"Player",list,list[1],accent,function(v) selectedPlayer=map[v] end)
        selectedPlayer=map[list[1]]
        Components.Button(parent,"Teleport to Player","Teleport","Secondary",accent,function()
            if selectedPlayer and tp:TeleportToPlayer(selectedPlayer) then notifs:Show("Teleport","Teleported to player.",2,"Success") else notifs:Show("Teleport","Player unavailable.",2,"Warning") end
        end)
    else
        Components.InfoBanner(parent,"No other players are currently available.","Info",accent)
    end
end
return TeleportTab
end

__modules["UI.Tabs.Diagnostics"] = function()
--!strict
local Components=require("UI.Components")
local DiagnosticsTab={}
function DiagnosticsTab.Build(parent:Instance,ctx:any)
    local cfg=ctx.ConfigManager.Config;local accent=ctx.AccentName;local notifs=ctx.Notifications
    local recorder=ctx.Container and ctx.Container:Has("TelemetryRecorder") and ctx.Container:Get("TelemetryRecorder")
    local stats=recorder and recorder:GetStats() or {}
    local total=stats.TotalDataRecords or 0
    local saved=stats.SavedDataRecords or 0
    Components.Section(parent,"Saved Data",accent)
    Components.InfoBanner(parent,string.format("Saved records: %d | Total records: %d | Pending: %d",stats.SavedDataRecords or 0,stats.TotalDataRecords or total,stats.PendingDataRecords or 0),"Success",accent)
    Components.InfoBanner(parent,string.format("Observations: %d | Combat events: %d | Animations: %d | Hitboxes: %d | Tools: %d",stats.TotalObservations or 0,stats.TotalCombatEvents or 0,stats.TotalAnimations or 0,stats.TotalHitboxProfiles or 0,stats.TotalTools or 0),"Info",accent)
    Components.InfoBanner(parent,string.format("Characters: %d | Attributes: %d | Cooldowns: %d | Sounds: %d | Remotes: %d",stats.TotalCharacters or 0,stats.TotalAttributes or 0,stats.TotalCooldownProfiles or 0,stats.TotalSounds or 0,stats.TotalRemotes or 0),"Info",accent)
    Components.InfoBanner(parent,string.format("Interactions: %d | World objects: %d | Session: %d",stats.TotalInteractions or 0,stats.TotalWorldObjects or 0,stats.SessionNumber or 1),"Info",accent)
    Components.InfoBanner(parent,string.format("Skill Recon: %d profiles | %d sessions | %d active",stats.TotalSkillProfiles or 0,stats.TotalSkillSessions or 0,stats.ActiveSkillSessions or 0),"Info",accent)
    Components.InfoBanner(parent,string.format("OMNI: %d events | %d instances | IN %d / OUT %d | trunc %d",stats.OmniEvents or 0,stats.OmniInstances or 0,stats.OmniIncoming or 0,stats.OmniOutgoing or 0,stats.OmniTruncated or 0),"Info",accent)

    Components.Section(parent,"Automatic Data Recorder",accent)
    Components.Toggle(parent,"Automatic Data Recorder","Collect runtime data in the background",cfg.Telemetry.AutoRecordData,accent,function(v) cfg.Telemetry.AutoRecordData=v;ctx.ConfigManager:Commit();notifs:Show("Recorder",v and "Recording enabled" or "Recording disabled",2,"Info") end)
    Components.Slider(parent,"Save Interval",30,600,cfg.Telemetry.AutoSaveInterval or 300,"s",10,accent,function(v) cfg.Telemetry.AutoSaveInterval=v;ctx.ConfigManager:Commit() end)

    Components.Section(parent,"Skill Recon",accent)
    Components.Toggle(parent,"OMNI Capture","Maximum practical client-observable forensic capture",cfg.Telemetry.RecordOmni~=false,accent,function(v) cfg.Telemetry.RecordOmni=v;ctx.ConfigManager:Commit() end)
    Components.Toggle(parent,"Skill Recon","High-resolution skill, grab/release, target and runtime-state capture",cfg.Telemetry.RecordSkillRecon~=false,accent,function(v) cfg.Telemetry.RecordSkillRecon=v;ctx.ConfigManager:Commit() end)
    Components.Slider(parent,"Recon Sample Rate",5,30,cfg.Telemetry.ReconSampleHz or 20," Hz",1,accent,function(v) cfg.Telemetry.ReconSampleHz=v;ctx.ConfigManager:Commit() end)
    Components.Slider(parent,"Recon Target Range",15,100,cfg.Telemetry.ReconTargetRange or 45," studs",1,accent,function(v) cfg.Telemetry.ReconTargetRange=v;ctx.ConfigManager:Commit() end)
    Components.Section(parent,"What to Record",accent)
    Components.InfoBanner(parent,"OMNI raw event log: tsb_data/omni_events.ndjson (when appendfile is available)","Info",accent)
    local toggles={
        {"Characters","RecordCharacters","Player/character profiles and rig data"},
        {"Animations","RecordAnimations","Animation IDs, priority, speed and play counts"},
        {"Hitboxes","RecordHitboxes","BasePart names, sizes and relative geometry"},
        {"Attributes","RecordAttributes","Attribute values and behavioral changes"},
        {"Cooldowns","RecordCooldowns","Cooldown-related behavioral changes"},
        {"Sounds","RecordSounds","Sound IDs, names and character context"},
        {"Tools / Skills","RecordTools","Inventory tools, skill names and observed context"},
        {"Remotes","RecordRemotes","Observed RemoteEvent/RemoteFunction paths"},
        {"Combat Events","RecordCombatEvents","Health, ragdoll and combat telemetry"},
        {"Correlations","RecordCorrelations","Attribute-to-animation behavioral correlations"},
        {"Interactions","RecordInteractions","ProximityPrompts, ClickDetectors and seats"},
        {"World Objects","RecordWorldObjects","Relevant Models and world Tool objects"},
    }
    for _,row in ipairs(toggles) do
        Components.Toggle(parent,row[1],row[3],cfg.Telemetry[row[2]]~=false,accent,function(v) cfg.Telemetry[row[2]]=v;ctx.ConfigManager:Commit() end)
    end
end
return DiagnosticsTab
end
__modules["UI/Tabs/Diagnostics"] = __modules["UI.Tabs.Diagnostics"]

-- ============================================================================
-- Module: UI.Theme
-- ============================================================================
__modules["UI.Theme"] = function()
--!strict
local TweenService = game:GetService("TweenService")

local Theme = {
    Accents = {
        ["Cyan Neon"] = {
            Primary = Color3.fromRGB(0, 220, 255),
            Hover = Color3.fromRGB(40, 235, 255),
            Glow = Color3.fromRGB(0, 170, 220),
            Dim = Color3.fromRGB(0, 90, 120),
        },
        ["Crimson Red"] = {
            Primary = Color3.fromRGB(255, 60, 80),
            Hover = Color3.fromRGB(255, 95, 115),
            Glow = Color3.fromRGB(210, 40, 60),
            Dim = Color3.fromRGB(120, 30, 45),
        },
        ["Purple Velvet"] = {
            Primary = Color3.fromRGB(170, 80, 255),
            Hover = Color3.fromRGB(195, 115, 255),
            Glow = Color3.fromRGB(140, 50, 220),
            Dim = Color3.fromRGB(80, 35, 125),
        },
        ["Emerald Green"] = {
            Primary = Color3.fromRGB(45, 220, 125),
            Hover = Color3.fromRGB(75, 240, 150),
            Glow = Color3.fromRGB(30, 180, 95),
            Dim = Color3.fromRGB(20, 95, 55),
        },
    },
    Colors = {
        Background = Color3.fromRGB(13, 15, 22),
        Header = Color3.fromRGB(18, 21, 30),
        Sidebar = Color3.fromRGB(16, 19, 28),
        Card = Color3.fromRGB(22, 26, 39),
        CardHover = Color3.fromRGB(28, 33, 50),
        CardActive = Color3.fromRGB(34, 40, 62),
        Border = Color3.fromRGB(36, 42, 64),
        BorderSubtle = Color3.fromRGB(28, 32, 48),
        BorderActive = Color3.fromRGB(60, 72, 108),
        
        TextPrimary = Color3.fromRGB(245, 248, 255),
        TextSecondary = Color3.fromRGB(152, 162, 192),
        TextMuted = Color3.fromRGB(92, 100, 128),
        TextDim = Color3.fromRGB(65, 72, 95),
        
        Success = Color3.fromRGB(46, 213, 115),
        Warning = Color3.fromRGB(255, 171, 0),
        Danger = Color3.fromRGB(255, 71, 87),
        Info = Color3.fromRGB(0, 180, 255),
    },
    Fonts = {
        Title = Enum.Font.GothamBold,
        Subtitle = Enum.Font.GothamMedium,
        Body = Enum.Font.Gotham,
        Bold = Enum.Font.GothamBold,
        Mono = Enum.Font.Code,
    },
}

function Theme.GetAccent(name: string?): { Primary: Color3, Hover: Color3, Glow: Color3, Dim: Color3 }
    local key = name or "Cyan Neon"
    return Theme.Accents[key] or Theme.Accents["Cyan Neon"]
end

function Theme.Tween(inst: Instance, duration: number?, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
    local ti = TweenInfo.new(
        duration or 0.18,
        style or Enum.EasingStyle.Quart,
        dir or Enum.EasingDirection.Out
    )
    local tw = TweenService:Create(inst, ti, props)
    tw:Play()
    return tw
end

return Theme

end
__modules["UI/Theme"] = __modules["UI.Theme"]

-- ============================================================================
-- Module: UI.Tabs.Guide
-- ============================================================================
__modules["UI.Tabs.Guide"] = function()
--!strict
local Components=require("UI.Components")
local GuideTab={}
function GuideTab.Build(parent:Instance,ctx:any)
    local cfg=ctx.ConfigManager.Config;local accent=ctx.AccentName
    Components.Section(parent,"Targeting",accent)
    Components.InfoBanner(parent,"Lowest HP = lowest CURRENT HP. Distance is used only when HP is tied. Behind TP uses this exact same selector and does not fall back to Nearest.","Success",accent)
    Components.InfoBanner(parent,"Target mode is committed immediately, so reopening the GUI cannot silently replace Lowest HP with Nearest unless you explicitly choose it or the saved value is invalid.","Info",accent)
    Components.Section(parent,"Movement",accent)
    Components.InfoBanner(parent,"Infinite Jump uses JumpRequest and is the only extra-jump system. Double Jump has been removed. Anti-Void pauses while Fly is active, so it cannot pull a flyer back to an old safe position.","Info",accent)
    Components.Section(parent,"Character / Skill Detection",accent)
    Components.InfoBanner(parent,"The current roster contains 14 documented movesets: Saitama, Garou, Monster Garou, Genos, Sonic, Metal Bat, Atomic Samurai, Tatsumaki, Suiryu, Child Emperor, Zombie Man, Gojo, KJ and Frozen Soul. Skill Tools are used for detection instead of arbitrary model/attribute names.","Info",accent)
    Components.InfoBanner(parent,"Saitama base: Normal Punch, Consecutive Punches, Shove, Uppercut. Serious Mode: Death Counter, Table Flip, Serious Punch, Omni-Directional Punch.","Success",accent)
    Components.InfoBanner(parent,"When Saitama awakening tools appear, [ULT] is shown. When awakening tools disappear after an observed awakening, Death Counter Risk starts for 10 seconds.","Warning",accent)
    Components.Section(parent,"Telemetry",accent)
    Components.InfoBanner(parent,"Diagnostics now shows saved-record totals and lets you independently choose animations, hitboxes, attributes, cooldowns, sounds, tools/skills, remotes, combat events, correlations, interactions and world objects.","Info",accent)
end
return GuideTab
end
__modules["UI/Tabs/Guide"] = __modules["UI.Tabs.Guide"]

-- ============================================================================
-- Module: UI.UIController
-- ============================================================================
__modules["UI.UIController"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local Maid = require("Core.Maid")
local Window = require("UI.Window")
local Notifications = require("UI.Notifications")

-- Tabs
local CombatTab = require("UI.Tabs.Combat")
local TargetTab = require("UI.Tabs.Target")
local MovementTab = require("UI.Tabs.Movement")
local SkillsTab = require("UI.Tabs.Skills")
local SurvivalTab = require("UI.Tabs.Survival")
local VisualsTab = require("UI.Tabs.Visuals")
local WorldTab = require("UI.Tabs.World")
local KeybindsTab = require("UI.Tabs.Keybinds")
local SettingsTab = require("UI.Tabs.Settings")
local DiagnosticsTab = require("UI.Tabs.Diagnostics")
local TeleportTab = require("UI.Tabs.Teleport")
local GuideTab = require("UI.Tabs.Guide")

local UIController = {}
UIController.__index = UIController

export type UIDependencies = {
    ConfigManager: any,
    FeatureManager: any,
    StateMachine: any,
    Profiler: any,
    Cache: any,
    NetworkEngine: any,
    Logger: any,
    Bootstrap: any,
    Container: any,
}

function UIController.new(deps: UIDependencies)
    local self = setmetatable({
        _deps = deps,
        _maid = Maid.new(),
        _gui = nil :: ScreenGui?,
        _window = nil :: any,
        _notifications = nil :: any,
        _isInitialized = false,
        _accentName = "Cyan Neon",
        _lastActiveTab = nil :: string?,
    }, UIController)

    return self
end

function UIController:Init()
    if self._isInitialized or self._gui or self._window then
        self:Destroy()
    end

    self._isInitialized = false
    local cfg = self._deps.ConfigManager.Config
    local accent = (cfg and cfg.UI and cfg.UI.AccentName) or "Cyan Neon"
    self._accentName = accent

    -- Target ScreenGui parent (gethui -> PlayerGui -> CoreGui)
    local function GetSafeGuiParent(): Instance
        if typeof(gethui) == "function" then
            local ok, h = pcall(gethui)
            if ok and h then return h end
        end

        local lp = Players.LocalPlayer
        if not lp then
            pcall(function()
                Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
                lp = Players.LocalPlayer
            end)
        end

        if lp then
            local pg = lp:FindFirstChildOfClass("PlayerGui")
            if not pg then
                pcall(function() pg = lp:WaitForChild("PlayerGui", 4) end)
            end
            if pg then return pg end
        end

        local okCore, cg = pcall(function() return game:GetService("CoreGui") end)
        if okCore and cg then return cg end

        return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end

    local parentTarget = GetSafeGuiParent()

    -- Remove any old GUI instances to guarantee idempotency
    pcall(function()
        local oldGui = parentTarget:FindFirstChild("TSB_Framework_UI")
        if oldGui then oldGui:Destroy() end
    end)

    -- Create ScreenGui
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TSB_Framework_UI"
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 999
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true

    if typeof(syn) == "table" and typeof(syn.protect_gui) == "function" then
        pcall(syn.protect_gui, screenGui)
    end

    screenGui.Parent = parentTarget
    self._gui = screenGui

    self._maid:GiveTask(screenGui)

    -- Initialize Notifications
    local notifs = Notifications.new(screenGui, accent)
    self._notifications = notifs
    self._maid:GiveTask(function() notifs:Destroy() end)

    -- Initialize Window
    local window = Window.new(screenGui, accent, function()
        if cfg and cfg.UI then
            cfg.UI.IsOpen = false
        end
    end)
    self._window = window
    self._maid:GiveTask(function() window:Destroy() end)

    -- Shared Tab Context
    local tabCtx = {
        ConfigManager = self._deps.ConfigManager,
        FeatureManager = self._deps.FeatureManager,
        StateMachine = self._deps.StateMachine,
        Profiler = self._deps.Profiler,
        Cache = self._deps.Cache,
        NetworkEngine = self._deps.NetworkEngine,
        Logger = self._deps.Logger,
        Bootstrap = self._deps.Bootstrap,
        Container = self._deps.Container,
        Notifications = notifs,
        AccentName = accent,
        UIController = self,
    }

    -- Build Categorized Tabs
    local sidebar = window:GetSidebar()

    -- Category 1: COMBAT & MOVEMENT
    sidebar:AddCategory("Combat & Move", 1)
    local combatTabs = {
        { Name = "Combat",      Icon = "⚔️", Builder = CombatTab.Build,      Order = 2 },
        { Name = "Target",      Icon = "🎯", Builder = TargetTab.Build,      Order = 3 },
        { Name = "Movement",    Icon = "⚡", Builder = MovementTab.Build,    Order = 4 },
    }
    for _, t in ipairs(combatTabs) do
        sidebar:AddTab(t.Name, t.Icon, t.Order)
        local page = window:CreateTabPage(t.Name)
        t.Builder(page, tabCtx)
    end

    -- Category 2: ENVIRONMENT & VISUALS
    sidebar:AddCategory("World & Visuals", 10)
    local envTabs = {
        { Name = "Visuals",     Icon = "👁️", Builder = VisualsTab.Build,     Order = 11 },
        { Name = "World",       Icon = "🌐", Builder = WorldTab.Build,       Order = 12 },
    }
    for _, t in ipairs(envTabs) do
        sidebar:AddTab(t.Name, t.Icon, t.Order)
        local page = window:CreateTabPage(t.Name)
        t.Builder(page, tabCtx)
    end

    -- Category 3: SYSTEM & TOOLS
    sidebar:AddCategory("System & Tools", 20)
    local sysTabs = {
        { Name = "Keybinds",    Icon = "⌨️", Builder = KeybindsTab.Build,    Order = 21 },
        { Name = "Settings",    Icon = "⚙️", Builder = SettingsTab.Build,    Order = 22 },
        { Name = "Teleport",   Icon = "📍", Builder = TeleportTab.Build,   Order = 23 },
        { Name = "Diagnostics", Icon = "📊", Builder = DiagnosticsTab.Build, Order = 24 },
        { Name = "Guide",       Icon = "📖", Builder = GuideTab.Build,       Order = 25 },
    }
    for _, t in ipairs(sysTabs) do
        sidebar:AddTab(t.Name, t.Icon, t.Order)
        local page = window:CreateTabPage(t.Name)
        t.Builder(page, tabCtx)
    end

    -- Default Active Tab
    sidebar:SetActive(self._lastActiveTab or "Movement")

    -- EventBus Global Notification Listener
    if self._deps.Container and self._deps.Container:Has("EventBus") then
        local eb = self._deps.Container:Get("EventBus")
        local notifConn = eb:Subscribe("Notification.Show", function(title: string, msg: string, dur: number?, kind: any?)
            self:ShowNotification(title, msg, dur, kind)
        end)
        self._maid:GiveTask(notifConn)

        -- Combat publishes Auto Tech notifications on this channel.
        local uiNotifConn = eb:Subscribe("UI.Notification", function(title: string, msg: string, kind: any?, dur: number?)
            self:ShowNotification(title, msg, dur, kind)
        end)
        self._maid:GiveTask(uiNotifConn)
    end

    -- Keybind Listeners (GUI Toggle, Continuous Safe Behind Lock, Aimlock, Fly, Noclip, Emergency Stop)
    local function RefreshUIAfterShortcut()
        task.defer(function()
            if self._isInitialized then pcall(function() self:Refresh() end) end
        end)
    end

    local keybindConn = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            local kb = cfg and cfg.Keybinds or {}
            local toggleGUIBind = kb.ToggleGUI or Enum.KeyCode.RightControl
            local behindTPBind = kb.ToggleBehindTP or Enum.KeyCode.F9
            local aimlockBind = kb.ToggleAimlock or Enum.KeyCode.F7
            local flyBind = kb.ToggleFly or Enum.KeyCode.F5
            local noclipBind = kb.ToggleNoclip or Enum.KeyCode.F6
            local emerBind = kb.EmergencyStop or Enum.KeyCode.Delete

            if input.KeyCode == toggleGUIBind then
                self:Toggle()
            elseif input.KeyCode == behindTPBind then
                if not cfg.Target then cfg.Target = {} end
                local newState = not cfg.Target.BehindTP
                cfg.Target.BehindTP = newState
                self._deps.ConfigManager:Commit()
                if newState then
                    local combat = self._deps.Container:Get("Combat")
                    local mov = self._deps.Container:Get("Movement")
                    local success, tName = false, "Opponent"
                    if mov then
                        success, tName = mov:ExecuteBehindTP(cfg, combat)
                    end
                    if not success then
                        cfg.Target.BehindTP = false
                        if mov and type(mov.RestoreNoclip) == "function" then
                            mov:RestoreNoclip()
                        end
                        self:ShowNotification("⚡ Behind TP", "No valid target found.", 2.0, "Warning")
                    else
                        self:ShowNotification("⚡ Behind TP", "LOCKED behind " .. tostring(tName or "Opponent"), 2.0, "Success")
                    end
                else
                    self:ShowNotification("Behind TP", "Behind TP DISABLED", 2.0, "Warning")
                end
                RefreshUIAfterShortcut()
            elseif input.KeyCode == aimlockBind then
                if cfg.Combat then
                    cfg.Combat.Aimlock = not cfg.Combat.Aimlock
                    self._deps.ConfigManager:Commit()
                    self:ShowNotification("Aimlock", cfg.Combat.Aimlock and "Aimlock ENABLED" or "Aimlock DISABLED", 2.0, cfg.Combat.Aimlock and "Success" or "Warning")
                    RefreshUIAfterShortcut()
                end
            elseif input.KeyCode == flyBind then
                if cfg.Movement then
                    cfg.Movement.Fly = not cfg.Movement.Fly
                    self._deps.ConfigManager:Commit()
                    local mov = self._deps.Container:Get("Movement")
                    if mov then mov:ToggleFly(cfg.Movement.Fly, cfg) end
                    self:ShowNotification("Flight", cfg.Movement.Fly and "Fly ENABLED" or "Fly DISABLED", 2.0, cfg.Movement.Fly and "Success" or "Warning")
                    RefreshUIAfterShortcut()
                end
            elseif input.KeyCode == noclipBind then
                if cfg.Movement then
                    cfg.Movement.Noclip = not cfg.Movement.Noclip
                    self._deps.ConfigManager:Commit()
                    local mov = self._deps.Container and self._deps.Container:Get("Movement")
                    if mov and mov.ToggleNoclip then mov:ToggleNoclip(cfg.Movement.Noclip) end
                    self:ShowNotification("Noclip", cfg.Movement.Noclip and "Noclip ENABLED" or "Noclip DISABLED", 2.0, cfg.Movement.Noclip and "Success" or "Warning")
                    RefreshUIAfterShortcut()
                end
            elseif input.KeyCode == emerBind then
                if cfg.Target then cfg.Target.BehindTP = false end
                if cfg.Movement then cfg.Movement.Fly = false; cfg.Movement.Noclip = false end

                if cfg.Skills then
                    cfg.Skills.AutoSkillSpam = false
                    cfg.Skills.AutoUltSpam = false
                    cfg.Skills.VoidKill = false
                end
                if cfg.Survival then
                    cfg.Survival.SkyDodge = false
                    cfg.Survival.SkyTeleport = false
                end
                local container = self._deps.Container
                if container and container:Has("Combat") then pcall(function() container:Get("Combat"):StopAllRuntime() end) end
                if container and container:Has("Movement") then pcall(function() container:Get("Movement"):RestoreNoclip(); container:Get("Movement"):RestoreBehindCollision(); container:Get("Movement"):DisableFlyRuntime() end) end
                if container and container:Has("Survival") then pcall(function() container:Get("Survival"):Stop() end) end
                self:ShowNotification("🛑 Emergency Stop", "All active combat & movement loops stopped.", 2.5, "Warning")
                RefreshUIAfterShortcut()
            elseif input.KeyCode == (kb.MassBringKey or Enum.KeyCode.G) then
                if self._deps.Container and self._deps.Container:Has("Combat") then
                    local combat = self._deps.Container:Get("Combat")
                    if combat.MassBringActive then
                        combat:StopMassBring()
                        self:ShowNotification("Mass Bring", "Mass Bring STOPPED", 2.0, "Warning")
                    else
                        combat:StartMassBring(cfg)
                        self:ShowNotification("Mass Bring", "Mass Bring STARTED", 2.0, "Success")
                    end
                    RefreshUIAfterShortcut()
                end
            elseif input.KeyCode == (kb.ToggleSkyDodge or Enum.KeyCode.H) then
                if cfg.Survival then
                    cfg.Survival.SkyDodge = not cfg.Survival.SkyDodge
                    self:ShowNotification("Sky Dodge", cfg.Survival.SkyDodge and "Sky Dodge ENABLED" or "Sky Dodge DISABLED", 2.0, cfg.Survival.SkyDodge and "Success" or "Warning")
                    RefreshUIAfterShortcut()
                end
            end
        end
    end)
    self._maid:GiveTask(keybindConn)

    -- Initial Window State
    if cfg and cfg.UI and cfg.UI.IsOpen == false then
        window:Minimize()
    else
        window:Open()
    end

    notifs:Show("TSB Framework", "System operational. Press RightControl to toggle UI.", 3.0, "Success")
    if self._deps.Logger then
        self._deps.Logger:Info("UIController", "GUI System Initialized successfully.")
    end
    self._isInitialized = true
end

function UIController:Open()
    if self._window then
        self._window:Open()
    end
end

function UIController:Close()
    if self._window then
        self._window:Close()
    end
end

function UIController:Toggle()
    if self._window then
        self._window:Toggle()
    end
end

function UIController:ShowNotification(title: string, message: string, duration: number?, kind: any?)
    if self._notifications then
        self._notifications:Show(title, message, duration, kind)
    end
end

function UIController:SetAccent(name: string)
    local nextAccent = tostring(name or "Cyan Neon")
    self._accentName = nextAccent
    local cfg = self._deps.ConfigManager and self._deps.ConfigManager.Config
    if cfg and cfg.UI then
        cfg.UI.AccentName = nextAccent
    end
    if self._isInitialized then
        self:Refresh()
    end
end

function UIController:SelectTab(tabName: string)
    if self._window and self._window:GetSidebar() then
        self._window:GetSidebar():SetActive(tabName)
    end
end

function UIController:Refresh()
    local lastTab = (self._window and self._window:GetSidebar() and self._window:GetSidebar()._activeTab) or self._lastActiveTab or "Settings"
    self._lastActiveTab = lastTab
    self:Init()
    if self._window and self._window:GetSidebar() then
        self._window:GetSidebar():SetActive(lastTab)
    end
end

function UIController:Destroy()
    if self._maid then
        self._maid:DoCleaning()
    end
    self._gui = nil
    self._window = nil
    self._notifications = nil
    self._isInitialized = false
end

return UIController

end
__modules["UI/UIController"] = __modules["UI.UIController"]

-- ============================================================================
-- Module: UI.Window
-- ============================================================================
__modules["UI.Window"] = function()
--!strict
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Theme = require("UI.Theme")
local Sidebar = require("UI.Sidebar")
local Maid = require("Core.Maid")

local Window = {}
Window.__index = Window

function Window.new(parentGui: Instance, accentName: string?, onClosed: (() -> ())?)
    local accent = Theme.GetAccent(accentName)
    local inputMaid = Maid.new()

    -- Floating Reopen Button (visible when window is minimized)
    local reopenBtn = Instance.new("TextButton")
    reopenBtn.Name = "TSB_ReopenButton"
    reopenBtn.Size = UDim2.new(0, 88, 0, 32)
    reopenBtn.Position = UDim2.new(0, 16, 0, 16)
    reopenBtn.BackgroundColor3 = Theme.Colors.Header
    reopenBtn.BorderSizePixel = 0
    reopenBtn.Text = "⚡ TSB HUB"
    reopenBtn.TextColor3 = accent.Primary
    reopenBtn.TextSize = 11
    reopenBtn.Font = Theme.Fonts.Bold
    reopenBtn.Visible = false
    reopenBtn.Parent = parentGui
    Instance.new("UICorner", reopenBtn).CornerRadius = UDim.new(1, 0)

    local reopenStroke = Instance.new("UIStroke")
    reopenStroke.Color = accent.Primary
    reopenStroke.Thickness = 1
    reopenStroke.Parent = reopenBtn

    -- Make reopen button draggable
    local draggingReopen = false
    local dragReopenStart: Vector3? = nil
    local startReopenPos: UDim2? = nil

    reopenBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = true
            dragReopenStart = input.Position
            startReopenPos = reopenBtn.Position
        end
    end)
    inputMaid:GiveTask(UserInputService.InputChanged:Connect(function(input)
        if draggingReopen and dragReopenStart and startReopenPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragReopenStart
            reopenBtn.Position = UDim2.new(
                startReopenPos.X.Scale,
                startReopenPos.X.Offset + delta.X,
                startReopenPos.Y.Scale,
                startReopenPos.Y.Offset + delta.Y
            )
        end
    end))
    inputMaid:GiveTask(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingReopen = false
        end
    end))

    -- Main Window Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "TSB_MainWindow"
    mainFrame.Size = UDim2.new(0, 680, 0, 480)
    mainFrame.Position = UDim2.new(0.5, -340, 0.5, -240)
    mainFrame.BackgroundColor3 = Theme.Colors.Background
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    mainFrame.Parent = parentGui
    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = Theme.Colors.Border
    mainStroke.Thickness = 1
    mainStroke.Parent = mainFrame

    -- Header Bar
    local headerBar = Instance.new("Frame")
    headerBar.Name = "HeaderBar"
    headerBar.Size = UDim2.new(1, 0, 0, 42)
    headerBar.BackgroundColor3 = Theme.Colors.Header
    headerBar.BorderSizePixel = 0
    headerBar.Parent = mainFrame

    local headerSep = Instance.new("Frame")
    headerSep.Size = UDim2.new(1, 0, 0, 1)
    headerSep.Position = UDim2.new(0, 0, 1, -1)
    headerSep.BackgroundColor3 = Theme.Colors.BorderSubtle
    headerSep.BorderSizePixel = 0
    headerSep.Parent = headerBar

    local headerTitle = Instance.new("TextLabel")
    headerTitle.Name = "HeaderTitle"
    headerTitle.Size = UDim2.new(1, -250, 1, 0)
    headerTitle.Position = UDim2.new(0, 175, 0, 0)
    headerTitle.BackgroundTransparency = 1
    headerTitle.Text = "Combat Dashboard"
    headerTitle.TextColor3 = Theme.Colors.TextPrimary
    headerTitle.TextSize = 13
    headerTitle.Font = Theme.Fonts.Title
    headerTitle.TextXAlignment = Enum.TextXAlignment.Left
    headerTitle.Parent = headerBar

    -- Header Window Control Buttons (Minimize & Close)
    local minBtn = Instance.new("TextButton")
    minBtn.Name = "MinimizeButton"
    minBtn.Size = UDim2.new(0, 28, 0, 24)
    minBtn.Position = UDim2.new(1, -64, 0.5, -12)
    minBtn.BackgroundColor3 = Theme.Colors.Card
    minBtn.BorderSizePixel = 0
    minBtn.Text = "—"
    minBtn.TextColor3 = Theme.Colors.TextSecondary
    minBtn.TextSize = 12
    minBtn.Font = Theme.Fonts.Bold
    minBtn.Parent = headerBar
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0, 28, 0, 24)
    closeBtn.Position = UDim2.new(1, -32, 0.5, -12)
    closeBtn.BackgroundColor3 = Theme.Colors.Card
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Theme.Colors.TextSecondary
    closeBtn.TextSize = 11
    closeBtn.Font = Theme.Fonts.Bold
    closeBtn.Parent = headerBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    closeBtn.MouseEnter:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Danger, TextColor3 = Color3.fromRGB(255, 255, 255) })
    end)
    closeBtn.MouseLeave:Connect(function()
        Theme.Tween(closeBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    minBtn.MouseEnter:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.CardHover, TextColor3 = Theme.Colors.TextPrimary })
    end)
    minBtn.MouseLeave:Connect(function()
        Theme.Tween(minBtn, 0.1, { BackgroundColor3 = Theme.Colors.Card, TextColor3 = Theme.Colors.TextSecondary })
    end)

    -- Content Area Frame
    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "ContentFrame"
    contentFrame.Size = UDim2.new(1, -165, 1, -42)
    contentFrame.Position = UDim2.new(0, 165, 0, 42)
    contentFrame.BackgroundTransparency = 1
    contentFrame.Parent = mainFrame

    -- Dragging with Boundary Clamping
    local isDragging = false
    local dragStartPos: Vector3? = nil
    local frameStartPos: UDim2? = nil

    headerBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = true
            dragStartPos = input.Position
            frameStartPos = mainFrame.Position
        end
    end)

    inputMaid:GiveTask(UserInputService.InputChanged:Connect(function(input)
        if isDragging and dragStartPos and frameStartPos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStartPos
            local cam = Workspace.CurrentCamera
            local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)

            local newX = frameStartPos.X.Offset + delta.X
            local newY = frameStartPos.Y.Offset + delta.Y

            -- Screen boundary clamping
            local absoluteW = mainFrame.AbsoluteSize.X
            local absoluteH = mainFrame.AbsoluteSize.Y
            local screenX = frameStartPos.X.Scale * vp.X + newX
            local screenY = frameStartPos.Y.Scale * vp.Y + newY

            if screenX < 0 then newX = -frameStartPos.X.Scale * vp.X end
            if screenY < 0 then newY = -frameStartPos.Y.Scale * vp.Y end
            if (screenX + absoluteW) > vp.X then newX = vp.X - absoluteW - (frameStartPos.X.Scale * vp.X) end
            if (screenY + absoluteH) > vp.Y then newY = vp.Y - absoluteH - (frameStartPos.Y.Scale * vp.Y) end

            mainFrame.Position = UDim2.new(frameStartPos.X.Scale, newX, frameStartPos.Y.Scale, newY)
        end
    end))

    inputMaid:GiveTask(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            isDragging = false
        end
    end))

    local self = setmetatable({
        _gui = parentGui,
        _mainFrame = mainFrame,
        _headerTitle = headerTitle,
        _contentFrame = contentFrame,
        _reopenBtn = reopenBtn,
        _minBtn = minBtn,
        _closeBtn = closeBtn,
        _accentName = accentName or "Cyan Neon",
        _isOpen = true,
        _isMinimized = false,
        _tabPages = {},
        _sidebar = nil :: any,
        _onClosed = onClosed,
        _inputMaid = inputMaid,
    }, Window)

    -- Sidebar Integration
    self._sidebar = Sidebar.new(mainFrame, accentName, function(tabName)
        self:SelectTab(tabName)
    end)

    -- Minimize Action
    minBtn.MouseButton1Click:Connect(function()
        self:Minimize()
    end)

    -- Reopen Action
    reopenBtn.MouseButton1Click:Connect(function()
        self:Restore()
    end)

    -- Close Action
    closeBtn.MouseButton1Click:Connect(function()
        self:Close()
    end)

    return self
end

function Window:CreateTabPage(tabName: string): ScrollingFrame
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "TabPage_" .. tabName
    scroll.Size = UDim2.new(1, 0, 1, 0)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Theme.Colors.BorderActive
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Visible = false
    scroll.Parent = self._contentFrame

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 6)
    listLayout.Parent = scroll

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 14)
    pad.Parent = scroll

    self._tabPages[tabName] = scroll
    return scroll
end

function Window:SelectTab(tabName: string)
    self._headerTitle.Text = tabName .. " Dashboard"
    for name, page in pairs(self._tabPages) do
        page.Visible = (name == tabName)
    end
end

function Window:Minimize()
    if not self._mainFrame or not self._reopenBtn then return end
    self._isMinimized = true
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 680, 0, 0) })
    task.delay(0.18, function()
        if self._isMinimized and self._mainFrame and self._reopenBtn and self._mainFrame.Parent and self._reopenBtn.Parent then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            Theme.Tween(self._reopenBtn, 0.15, { BackgroundTransparency = 0 })
        end
    end)
end

function Window:Restore()
    if not self._mainFrame or not self._reopenBtn then return end
    self._isOpen = true
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    Theme.Tween(self._mainFrame, 0.2, { Size = UDim2.new(0, 680, 0, 480) })
end

function Window:Open()
    if not self._mainFrame or not self._reopenBtn then return end
    if self._isOpen and self._mainFrame.Visible then return end
    self._isOpen = true
    self._isMinimized = false
    self._reopenBtn.Visible = false
    self._mainFrame.Visible = true
    self._mainFrame.Size = UDim2.new(0, 630, 0, 430)
    Theme.Tween(self._mainFrame, 0.22, { Size = UDim2.new(0, 680, 0, 480) })
end

function Window:Close()
    if not self._mainFrame or not self._reopenBtn then return end
    self._isOpen = false
    Theme.Tween(self._mainFrame, 0.18, { Size = UDim2.new(0, 630, 0, 430) })
    task.delay(0.18, function()
        if not self._isOpen and self._mainFrame and self._reopenBtn and self._mainFrame.Parent and self._reopenBtn.Parent then
            self._mainFrame.Visible = false
            self._reopenBtn.Visible = true
            if self._onClosed then pcall(self._onClosed) end
        end
    end)
end

function Window:Toggle()
    if self._mainFrame.Visible then
        self:Close()
    else
        self:Open()
    end
end

function Window:GetSidebar(): any
    return self._sidebar
end

function Window:Destroy()
    if self._inputMaid then
        self._inputMaid:DoCleaning()
        self._inputMaid = nil
    end
    if self._sidebar then
        self._sidebar:Destroy()
        self._sidebar = nil :: any
    end
    if self._mainFrame then
        self._mainFrame:Destroy()
        self._mainFrame = nil :: any
    end
    if self._reopenBtn then
        self._reopenBtn:Destroy()
        self._reopenBtn = nil :: any
    end
    table.clear(self._tabPages)
end

return Window

end
__modules["UI/Window"] = __modules["UI.Window"]

-- ============================================================================
-- FRAMEWORK PUBLIC RUNTIME SURFACE & ENTRYPOINT
-- ============================================================================
local Bootstrap = require("Bootstrap")
local UnitTests = require("Diagnostics.UnitTests")

local Framework = {
    Version = "9.0-SPECIALIST-PRODUCTION",
    Bootstrap = Bootstrap,
    
    Start = function(self)
        return Bootstrap:Init()
    end,
    
    Stop = function(self)
        return Bootstrap:Destroy()
    end,
    
    Destroy = function(self)
        return Bootstrap:Destroy()
    end,
    
    GetService = function(self, serviceName: string)
        if Bootstrap.Container and Bootstrap.Container:Has(serviceName) then
            return Bootstrap.Container:Get(serviceName)
        end
        return nil
    end,
    
    GetDiagnostics = function(self)
        return Bootstrap:GetDiagnostics()
    end,
    
    GetUI = function(self)
        if Bootstrap.Container and Bootstrap.Container:Has("UIController") then
            return Bootstrap.Container:Get("UIController")
        end
        return nil
    end,
    
    RunTests = function(self)
        return UnitTests.RunAll()
    end,
}

-- Expose Public Framework Handle to Global Environment for External Lifecycle Control
if typeof(_G) == "table" then
    _G.TSBFramework = Framework
end
if typeof(getgenv) == "function" then
    pcall(function()
        getgenv().TSBFramework = Framework
    end)
end

-- Automatic Framework Boot with Error Handling & Native Notification
print("[4080 HUB v9.0] Initializing Specialist Production Framework...")

local okBoot, bootErr = pcall(function()
    Bootstrap:Init()
end)

if not okBoot then
    warn("[4080 HUB v9.0] FATAL BOOT ERROR: " .. tostring(bootErr))
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "TSB HUB Error",
            Text = "Boot failed: " .. tostring(bootErr):sub(1, 80),
            Duration = 10,
        })
    end)
else
    print("[4080 HUB v9.0] Specialist Production Framework Booted Successfully.")
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "⚡ TSB HUB v9.0",
            Text = "Specialist Hub Loaded! Press RightControl to toggle UI.",
            Duration = 5,
        })
    end)
end

return Framework
