-- =============================================================================
-- KnifeLock - menu do CET
--
-- Este arquivo cuida da interface e de salvar as configurações do menu.
-- A mira é feita pelo KnifeLockAim.reds. A cada frame, este arquivo envia as
-- configurações para o redscript pelo método SetKnifeLockSettings.
--
-- As configurações são salvas em settings.txt, na mesma pasta deste arquivo,
-- e carregadas automaticamente quando o jogo abre.
-- =============================================================================

-- Configurações mostradas no menu (valores padrão)
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

-- Caminho do arquivo de configurações: mesma pasta deste script.
-- Tudo que depende de 'debug' e 'io' fica dentro de pcall, para que o mod
-- continue carregando mesmo se o CET restringir essas bibliotecas.
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
-- Salvar e carregar configurações
-- -----------------------------------------------------------------------------

-- Lê o arquivo aberto e aplica os valores encontrados
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

-- Lê settings.txt (formato "chave=valor", uma por linha) e aplica os valores
local function loadSettings()
    local ok, err = pcall(function()
        local file = io.open(SETTINGS_FILE, "r")
        if not file then
            print("KnifeLock: nenhuma configuração salva, usando padrões")
            return
        end
        readSettingsFile(file)
        file:close()
        print("KnifeLock: configurações carregadas")
    end)

    if not ok then
        print("KnifeLock: erro ao carregar configurações: " .. tostring(err))
    end
end

-- Grava as configurações atuais em settings.txt
local function saveSettings()
    local ok, err = pcall(function()
        local file = io.open(SETTINGS_FILE, "w")
        if not file then
            print("KnifeLock: não consegui salvar as configurações em " .. SETTINGS_FILE)
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
        print("KnifeLock: erro ao salvar configurações: " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- Envio ao redscript
-- -----------------------------------------------------------------------------

-- Envia as configurações do menu para o redscript
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
-- Eventos do CET
-- -----------------------------------------------------------------------------

registerForEvent("onInit", function()
    loadSettings()
    print("KnifeLock carregado")
end)

registerForEvent("onOverlayOpen", function()
    overlayOpen = true
end)

-- Ao fechar o overlay, salva se houve alteração
registerForEvent("onOverlayClose", function()
    overlayOpen = false
    if settingsDirty then
        saveSettings()
    end
end)

-- Envia as configurações ao jogo continuamente, para que mudanças valham na hora
registerForEvent("onUpdate", function(dt)
    local player = Game.GetPlayer()
    if not player then return end

    pushSettings(player)
end)

-- Desenha o menu somente quando o overlay do CET está aberto
registerForEvent("onDraw", function()
    if not overlayOpen then return end

    if ImGui.Begin("KnifeLock") then
        local changed

        KnifeLock.enabled, changed = ImGui.Checkbox("Ativar KnifeLock", KnifeLock.enabled)
        if changed then settingsDirty = true end

        ImGui.Separator()

        KnifeLock.maxDistance, changed = ImGui.SliderFloat("Distância máxima", KnifeLock.maxDistance, 5.0, 100.0, "%.1f")
        if changed then settingsDirty = true end

        KnifeLock.viewAngle, changed = ImGui.SliderFloat("Ângulo de visão", KnifeLock.viewAngle, 1.0, 90.0, "%.1f")
        if changed then settingsDirty = true end

        ImGui.Separator()
        ImGui.Text("Alvos:")

        KnifeLock.targets.police, changed = ImGui.Checkbox("Policiais", KnifeLock.targets.police)
        if changed then settingsDirty = true end

        KnifeLock.targets.gang, changed = ImGui.Checkbox("Membros de gangues", KnifeLock.targets.gang)
        if changed then settingsDirty = true end

        KnifeLock.targets.civilian, changed = ImGui.Checkbox("Civis", KnifeLock.targets.civilian)
        if changed then settingsDirty = true end
    end
    ImGui.End()
end)
