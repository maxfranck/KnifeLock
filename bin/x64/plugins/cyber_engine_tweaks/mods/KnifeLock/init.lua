-- =============================================================================
-- KnifeLock - CET menu
--
-- This file handles the user interface and the settings menu.
-- The aiming logic lives in KnifeLockAim.reds. Every frame, this file sends the
-- settings to the redscript side through SetKnifeLockSettings.
--
-- Settings are saved to settings.txt in the same folder as this script and are
-- loaded automatically when the game starts.
-- =============================================================================

-- Settings shown in the menu (default values)
local KnifeLock = {
    enabled = false,
    maxDistance = 30.0,
    viewAngle = 15.0,
    targets = {
        police = true,
        gang = true,
        civilian = true,
    }
}

-- Path to the settings file: the same folder as this script.
-- Everything that depends on 'debug' and 'io' is wrapped in pcall, so the mod
-- keeps loading even if CET restricts those libraries.
local SETTINGS_FILE = "settings.txt"
pcall(function()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local dir = info.source:match("@(.*[/\\])")
        if dir then
            SETTINGS_FILE = dir .. "settings.txt"
        end
    end
end)

local overlayOpen = false
local settingsDirty = false

-- -----------------------------------------------------------------------------
-- Saving and loading settings
-- -----------------------------------------------------------------------------

-- Reads an open file in the "key=value" format (one per line) and applies the values
local function readSettingsFile(file)
    for line in file:lines() do
        local key, value = line:match("^(%w+)=(.+)$")
        if key and value then
            if value == "true" then value = true
            elseif value == "false" then value = false
            else value = tonumber(value) or value end

            if key == "enabled" then KnifeLock.enabled = value
            elseif key == "maxDistance" then KnifeLock.maxDistance = value
            elseif key == "viewAngle" then KnifeLock.viewAngle = value
            elseif key == "police" then KnifeLock.targets.police = value
            elseif key == "gang" then KnifeLock.targets.gang = value
            elseif key == "civilian" then KnifeLock.targets.civilian = value
            end
        end
    end
end

-- Loads settings.txt and applies the values
local function loadSettings()
    local ok, err = pcall(function()
        local file = io.open(SETTINGS_FILE, "r")
        if not file then
            print("KnifeLock: no saved settings found, using defaults")
            return
        end
        readSettingsFile(file)
        file:close()
        print("KnifeLock: settings loaded")
    end)

    if not ok then
        print("KnifeLock: error loading settings: " .. tostring(err))
    end
end

-- Writes the current settings to settings.txt
local function saveSettings()
    local ok, err = pcall(function()
        local file = io.open(SETTINGS_FILE, "w")
        if not file then
            print("KnifeLock: could not save settings to " .. SETTINGS_FILE)
            return
        end

        file:write("enabled=" .. tostring(KnifeLock.enabled) .. "\n")
        file:write("maxDistance=" .. tostring(KnifeLock.maxDistance) .. "\n")
        file:write("viewAngle=" .. tostring(KnifeLock.viewAngle) .. "\n")
        file:write("police=" .. tostring(KnifeLock.targets.police) .. "\n")
        file:write("gang=" .. tostring(KnifeLock.targets.gang) .. "\n")
        file:write("civilian=" .. tostring(KnifeLock.targets.civilian) .. "\n")
        file:close()

        settingsDirty = false
    end)

    if not ok then
        print("KnifeLock: error saving settings: " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- Sending settings to the redscript side
-- -----------------------------------------------------------------------------

-- Sends the menu settings to the redscript side
local function pushSettings(player)
    if player == nil then return end

    pcall(function()
        player:SetKnifeLockSettings(
            KnifeLock.enabled,
            KnifeLock.maxDistance,
            KnifeLock.viewAngle,
            KnifeLock.targets.police,
            KnifeLock.targets.gang,
            KnifeLock.targets.civilian
        )
    end)
end

-- -----------------------------------------------------------------------------
-- CET events
-- -----------------------------------------------------------------------------

registerForEvent("onInit", function()
    loadSettings()
    print("KnifeLock loaded")
end)

registerForEvent("onOverlayOpen", function()
    overlayOpen = true
end)

-- When the overlay closes, save if anything changed
registerForEvent("onOverlayClose", function()
    overlayOpen = false
    if settingsDirty then
        saveSettings()
    end
end)

-- Send settings to the game continuously, so changes take effect immediately
registerForEvent("onUpdate", function(dt)
    local player = Game.GetPlayer()
    if not player then return end

    pushSettings(player)
end)

-- Draw the menu only while the CET overlay is open
registerForEvent("onDraw", function()
    if not overlayOpen then return end

    if ImGui.Begin("KnifeLock") then
        local changed

        KnifeLock.enabled, changed = ImGui.Checkbox("Activate KnifeLock", KnifeLock.enabled)
        if changed then settingsDirty = true end

        ImGui.Separator()

        KnifeLock.maxDistance, changed = ImGui.SliderFloat("Max distance", KnifeLock.maxDistance, 5.0, 100.0, "%.1f")
        if changed then settingsDirty = true end

        KnifeLock.viewAngle, changed = ImGui.SliderFloat("View angle", KnifeLock.viewAngle, 1.0, 90.0, "%.1f")
        if changed then settingsDirty = true end

        ImGui.Separator()
        ImGui.Text("Targets:")

        KnifeLock.targets.police, changed = ImGui.Checkbox("Police", KnifeLock.targets.police)
        if changed then settingsDirty = true end

        KnifeLock.targets.gang, changed = ImGui.Checkbox("Gang members", KnifeLock.targets.gang)
        if changed then settingsDirty = true end

        KnifeLock.targets.civilian, changed = ImGui.Checkbox("Civilians", KnifeLock.targets.civilian)
        if changed then settingsDirty = true end
    end
    ImGui.End()
end)
