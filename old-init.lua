local ImmersiveFirstPerson = { version = "1.3.1" }
local Cron = require("Modules/Cron")
local GameSession = require("Modules/GameSession")
local GameSettings = require("Modules/GameSettings")
local Vars = require("Modules/Vars")
local Easings = require("Modules/Easings")
local Helpers = require("Modules/Helpers")
local Config = require("Modules/Config")

-- Statesx
local inited = false
local isLoaded = false
local defaultFOV = 68
local initialFOV = 68
local isOverlayOpen = false
local isEnabled = true
local isDisabledByApi = false
local isYInverted = false
local isXInverted = false
local freeLookInCombat = true

local API = {}

-- API Functions
function API.Enable()
    isDisabledByApi = false
    isEnabled = true
    if ShouldSetCamera(freeLookInCombat) then
        ImmersiveFirstPerson.HandleCamera(true)
    end
end

function API.Disable()
    isEnabled = false
    isDisabledByApi = true
    ResetCamera()
    ResetFreeLook()
end

function API.IsEnabled()
    return isEnabled
end

function CombatFreeLook()
    return freeLookInCombat
end

-- Helpers
function defaultFovOrNil()
    if not Config.inner.dontChangeFov then
        return defaultFOV
    end
    return nil
end

local wasReset = true
function ResetCamera(force)
    if not wasReset or force then
        Helpers.ResetCamera(defaultFovOrNil())
        wasReset = true
    end
end

function blockingThirdPartyMods()
    return false
end

local lastPitch = 0
function ShouldSetCamera(ignoreWeapon)
    ignoreWeapon = ignoreWeapon or false
    local sceneTier = Helpers.GetSceneTier()
    local isFullGameplayScene = sceneTier > 0 and sceneTier < 3
    return isFullGameplayScene
        and (not Helpers.HasWeapon() or ignoreWeapon)
        and not Helpers.IsInVehicle()
        and not Helpers.IsSwimming()
        and Helpers.IsTakingDown() <= 0
        and not blockingThirdPartyMods()
        and not Helpers.IsCarryingBody()
        and not Helpers.IsKnockedDown()
end

function IsCrouching()
    return Game.GetPlayer():GetPS():IsCrouch()
end

-- Handlers
local wasCrouching = false
function ImmersiveFirstPerson.HandleCamera(force)
    if force == nil then force = false end

    if Helpers.IsFreeObservation() then
        return
    end

    if not ShouldSetCamera() then
        HandleCameraReset()
        return
    end

    local pitchValue = Helpers.GetPitch()
    if not pitchValue then
        return
    end

    local isCrouching = IsCrouching()
    local curPitch = CalculateCurrentPitch(pitchValue)

    if not ShouldUpdateCamera(curPitch, force, isCrouching) then
        return
    end

    UpdateCameraParameters(curPitch, isCrouching)
end

function HandleCameraReset()
    if Helpers.IsInVehicle() and Helpers.HasBVFP() then
        return
    end
    ResetCamera()
end

function CalculateCurrentPitch(pitchValue)
    return math.floor(math.min(pitchValue + Vars.OFFSET, 0) * 1000) / 1000
end

function ShouldUpdateCamera(curPitch, force, isCrouching)
    local hasPitchNotablyChanged = math.abs(lastPitch - curPitch) >= Vars.PITCH_CHANGE_STEP
    local hasCrouchingChanged = isCrouching ~= wasCrouching
    return hasPitchNotablyChanged or force or hasCrouchingChanged
end

function UpdateCameraParameters(curPitch, isCrouching)
    wasCrouching = isCrouching
    lastPitch = curPitch

    if not isEnabled then
        return
    end

    local progress = math.min(1, curPitch / (-80 + Vars.OFFSET))
    if progress <= 0 then
        ResetCamera()
        return
    end

    SetCameraParameters(progress, isCrouching)
end

function SetCameraParameters(progress, isCrouching)
    local crouchMultShift = isCrouching and Vars.CROUCH_MULT_SHIFT or 1
    local crouchMultLean = isCrouching and Vars.CROUCH_MULT_LEAN or 1
    local crouchMultHeight = isCrouching and Vars.CROUCH_MULT_HEIGHT or 1

    local fovShiftCorrection = Helpers.GetFOV() / 68.23
    local shift = math.min(1, progress * 4.0) * Vars.SHIFT_BASE_VALUE * crouchMultShift
    local height = math.min(1, progress * 1.0) * Vars.HEIGHT_BASE_VALUE * (isCrouching and 1 or 1) * crouchMultHeight
    local lean = math.min(1, progress * 1.0) * Vars.LEAN_BASE_VALUE * crouchMultLean
    local fov = math.floor(defaultFOV + (68.23 - defaultFOV) * math.min(1, progress * 2))

    Helpers.SetCamera(nil, height, shift, nil, lean, nil, fov)
end

local lastNativePitch = 0
local lastNativePitchUsed = false

local freeLookRestore = { progress = 0 }
function ImmersiveFirstPerson.RestoreFreeCam()
    local fpp = Helpers.GetFPP()
    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(fpp:GetLocalOrientation())
    local curPos = fpp:GetLocalPosition()

    if not Config.inner.smoothRestore then
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
        ResetCamera(true)
        return
    end

    if curEuler.pitch == 0 and curEuler.roll == 0 and curEuler.yaw == 0 and curPos.x == 0 and curPos.y == 0 and curPos.z == 0 then
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
        return
    end

    local itersWithSpeed = Vars.FREELOOK_SMOOTH_RESTORE_ITERS / Config.inner.smoothRestoreSpeed * Vars.FREELOOK_SMOOTH_RESTORE_ITERS
    local progressEased = (freeLookRestore.progress / itersWithSpeed)
    local roll = math.floor((curEuler.roll - progressEased * curEuler.roll) * 10) / 10
    local pitch = math.floor((curEuler.pitch - progressEased * curEuler.pitch) * 10) / 10
    local yaw = math.floor((curEuler.yaw - progressEased * curEuler.yaw) * 10) / 10
    local x = math.floor((curPos.x - progressEased * curPos.x) * 1000) / 1000
    local y = math.floor((curPos.y - progressEased * curPos.y) * 1000) / 1000
    local z = math.floor((curPos.z - progressEased * curPos.z) * 1000) / 1000

    if freeLookRestore.progress >= itersWithSpeed then
        roll = 0
        pitch = 0
        yaw = 0
        x = 0
        y = 0
        z = 0
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
    end

    Helpers.SetCamera(x, y, z, roll, pitch, yaw)
    freeLookRestore.progress = freeLookRestore.progress + 1
end

local function curve(t, a, b, c)
    return (1 - t)^2 * a + 2 * (1 - t) * t * b + t^2 * c
end

function ImmersiveFirstPerson.HandleFreeLook(relX, relY)
    if Helpers.IsRestoringCamera() then
        return
    end

    if not ShouldSetCamera(freeLookInCombat) then
        HandleCameraReset()
        return
    end

    local fpp = Helpers.GetFPP()
    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(fpp:GetLocalOrientation())
    local curPos = fpp:GetLocalPosition()

    local weapon = Helpers.HasWeapon()
    local curYaw = curEuler.yaw
    local curPitch = curEuler.pitch

    local zoom = fpp:GetZoom()
    local xSensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity / 20
    local ySensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity / 20

    local yaw = CalculateYaw(curYaw, relX, xSensitivity)
    local pitch = CalculatePitch(curPitch, relY, weapon)

    local xShiftMultiplier = math.abs(yaw) / Vars.FREELOOK_MAX_YAW * 2
    local freelookMaxXShift = weapon and Vars.FREELOOK_MAX_X_SHIFT_COMBAT or Vars.FREELOOK_MAX_X_SHIFT
    local x = freelookMaxXShift * xShiftMultiplier * (yaw < 0 and 1 or -1)

    local y = CalculateY(curPitch, weapon, xShiftMultiplier)
    local z = CalculateZ(curPitch, weapon, xShiftMultiplier)

    local fov = CalculateFOV()

    Helpers.SetCamera(x, y, z, 0, pitch, yaw, fov)
end

function CalculateYaw(curYaw, relX, xSensitivity)
    local yawingOut = curYaw > 0 and relX > 0 or curYaw < 0 and relX < 0
    local yawProgress = (yawingOut and easeOutExp(math.abs(curYaw / Vars.FREELOOK_MAX_YAW)) or 0) + (1 - easeOutExp(math.abs(curYaw / Vars.FREELOOK_MAX_YAW)))
    return math.min(Vars.FREELOOK_MAX_YAW, math.max(-Vars.FREELOOK_MAX_YAW, (curYaw - (relX * xSensitivity * yawProgress))))
end

function CalculatePitch(curPitch, relY, weapon)
    local maxPitch = weapon and Vars.FREELOOK_MAX_PITCH_COMBAT_UP or Vars.FREELOOK_MAX_PITCH
    return math.min(maxPitch, math.max(-maxPitch, (curPitch) + (relY * ySensitivity)))
end

function CalculateY(curPitch, weapon, xShiftMultiplier)
    local pitchProgress = -math.min(0, curPitch / Vars.FREELOOK_MAX_PITCH)
    return curve(pitchProgress, 0, (-Vars.FREELOOK_MIN_Y * (weapon and 0.2 or 1)), Vars.FREELOOK_MIN_Y / 2 * (weapon and 0.001 or 1) + 0.02) * (1 - (xShiftMultiplier / 2))
end

function CalculateZ(curPitch, weapon, xShiftMultiplier)
    return curve(-math.min(0, curPitch / Vars.FREELOOK_MAX_PITCH), 0, (-Vars.FREELOOK_MIN_Z * (weapon and 0.2 or 1)), Vars.FREELOOK_MIN_Z / 2 * (weapon and 0.001 or 1) + 0.02) * (1 - (xShiftMultiplier / 2))
end

function CalculateFOV()
    local fov = math.floor(defaultFOV + (68.23 - defaultFOV) * math.min(1, pitchProgress * 2) + ((math.min(1, pitchProgress)) * -8))
    if Config.inner.dontChangeFov then
        fov = nil
    end
    return fov
end

function ResetFreeLook()
    Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFovOrNil())
    Helpers.SetRestoringCamera(true)
    Helpers.UnlockMovement()
    lastNativePitchUsed = false
    ImmersiveFirstPerson.RestoreFreeCam()
end

function SaveNativeSens()
    if not Config.isReady then
        return
    end
    Config.inner.mouseNativeSensX = GameSettings.Get('/controls/fppcameramouse/FPP_MouseX')
    Config.inner.mouseNativeSensY = GameSettings.Get('/controls/fppcameramouse/FPP_MouseY')
    Config.SaveConfig()
end

-- INIT
function ImmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        Helpers.UnlockMovement()
        local fpp = Helpers.GetFPP()
        if fpp then
            fpp:ResetPitch()
            ImmersiveFirstPerson.RestoreFreeCam()
            Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFovOrNil())
        end
        ResetCamera()
    end)

    registerForEvent("onInit", function()
        inited = true
        Config.InitConfig()
        defaultFOV = Helpers.GetFOV()
        isYInverted = Helpers.IsYInverted()
        isXInverted = Helpers.IsXInverted()

        if Config.inner.mouseNativeSensX == -1 or Config.inner.mouseNativeSensX == nil then
            SaveNativeSens()
        end

        if GameSettings.Get('/controls/fppcameramouse/FPP_MouseX') == 0 then
            Helpers.UnlockMovement()
        end

        GameSession.OnStart(function()
            isLoaded = true
            defaultFOV = Helpers.GetFOV()
        end)

        GameSession.OnEnd(function()
            isLoaded = false
            ResetCamera(true)
        end)

        local cetVer = tonumber((GetVersion():gsub('^v(%d+)%.(%d+)%.(%d+)(.*)', function(major, minor, patch, wip)
            return ('%d.%02d%02d%d'):format(major, minor, patch, (wip == '' and 0 or 1))
        end))) or 1.12

        Observe('PlayerPuppet', 'OnGameAttached', function(self, b)
            self:RegisterInputListener(self, "CameraMouseY")
            self:RegisterInputListener(self, "CameraMouseX")
        end)

        Observe('PlayerPuppet', 'OnAction', function(a, b)
            if not isLoaded then
                return
            end

            local action = a
            if cetVer >= 1.14 then
                action = b
            end

            local ListenerAction = GetSingleton('gameinputScriptListenerAction')
            local actionName = Game.NameToString(ListenerAction:GetName(action))
            local actionValue = ListenerAction:GetValue(action)

            if Helpers.IsFreeObservation() then
                if actionName == "CameraMouseY" then
                    ImmersiveFirstPerson.HandleFreeLook(0, actionValue * (isYInverted and -1 or 1))
                end
                if actionName == "CameraMouseX" then
                    ImmersiveFirstPerson.HandleFreeLook(actionValue * (isXInverted and -1 or 1), 0)
                end
                return
            end

            if actionName == "CameraMouseY" or actionName == "CameraMouseX" then
                ImmersiveFirstPerson.HandleCamera()
            end
        end)

        Cron.Every(0.65, function ()
            if isLoaded then
                ImmersiveFirstPerson.HandleCamera()
            end
        end)
    end)

    registerForEvent("onUpdate", function(delta)
        Cron.Update(delta)

        if not isLoaded then
            return
        end

        if Helpers.IsRestoringCamera() then
            ImmersiveFirstPerson.RestoreFreeCam()
        end

        if not inited then
            return
        end

        if Helpers.IsFreeObservation() and not ShouldSetCamera(freeLookInCombat) and not Helpers.IsRestoringCamera() then
            HandleCameraReset()
            return
        end
    end)

    registerForEvent("onDraw", function()
        if not isOverlayOpen then
            return
        end

        ImGui.Begin("ImmersiveFirstPerson Settings", ImGuiWindowFlags.AlwaysAutoResize)

        -- Camera sensitivity setting
        ImGui.Text("Camera Sensitivity")
        Config.inner.freeLookSensitivity, changed = ImGui.SliderInt("Sensitivity", math.floor(Config.inner.freeLookSensitivity), 1, 100)
        if changed then
            Config.SaveConfig()
        end

        ImGui.End()
    end)

    registerHotkey("ifp_toggle_enabled", "Toggle Enabled", function()
        isEnabled = not isEnabled
        if isEnabled and ShouldSetCamera() then
            ImmersiveFirstPerson.HandleCamera(true)
        else
            ResetCamera()
        end
    end)

    registerForEvent("onOverlayOpen", function()
        isOverlayOpen = true
    end)
    registerForEvent("onOverlayClose", function()
        isOverlayOpen = false
    end)

    return {
        version = ImmersiveFirstPerson.version,
        api = API,
    }
end

return ImmersiveFirstPerson.Init()
