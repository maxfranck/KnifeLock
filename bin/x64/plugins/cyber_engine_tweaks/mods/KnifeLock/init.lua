-- =============================================================================
-- KnifeLock - menu do CET
--
-- Este arquivo cuida apenas da interface e de configurações exibidas no menu.
-- A mira em si é feita pelo KnifeLockAim.reds (redscript).
--
-- Observação: as configurações deste menu ainda NÃO são lidas pelo redscript.
-- Os valores usados na mira estão em KnifeLockAim.reds (KnifeLockConfig).
-- =============================================================================

-- Configurações mostradas no menu
local KnifeLock = {
    enabled = false,
    maxDistance = 30.0,
    viewAngle = 15.0,
    autoFire = false,
    targets = {
        police = true,
        gang = true,
        civilian = true,
    }
}

-- Tipos de arma de arremesso aceitos
local THROWABLE_TYPES = {
    Wea_Knife = true,
    Wea_Axe = true,
}

local overlayOpen = false

-- -----------------------------------------------------------------------------
-- Utilidades
-- -----------------------------------------------------------------------------

-- Retorna o tipo do item (ex.: Wea_Knife, Wea_Axe) ou nil
local function getItemTypeName(itemID)
    local record = TweakDB:GetRecord(itemID)
    if not record then return nil end

    local itemType = record:ItemType()
    if not itemType then return nil end

    return tostring(itemType:Type().value)
end

-- Indica se o tipo de item é uma arma de arremesso
local function isThrowableType(itemType)
    return THROWABLE_TYPES[itemType] == true
end

-- -----------------------------------------------------------------------------
-- Eventos do CET
-- -----------------------------------------------------------------------------

registerForEvent("onInit", function()
    print("KnifeLock carregado")
end)

registerForEvent("onOverlayOpen", function()
    overlayOpen = true
end)

registerForEvent("onOverlayClose", function()
    overlayOpen = false
end)

-- Desenha o menu somente quando o overlay do CET está aberto
registerForEvent("onDraw", function()
    if not overlayOpen then return end

    if ImGui.Begin("KnifeLock") then
        local changed

        KnifeLock.enabled, changed = ImGui.Checkbox("Ativar KnifeLock", KnifeLock.enabled)
        if changed then
            print("KnifeLock: " .. (KnifeLock.enabled and "ligado" or "desligado"))
        end

        ImGui.Separator()

        KnifeLock.maxDistance, _ = ImGui.SliderFloat("Distância máxima", KnifeLock.maxDistance, 5.0, 100.0, "%.1f")
        KnifeLock.viewAngle, _ = ImGui.SliderFloat("Ângulo de visão", KnifeLock.viewAngle, 1.0, 90.0, "%.1f")

        ImGui.Separator()
        ImGui.Text("Alvos:")

        KnifeLock.targets.police, _ = ImGui.Checkbox("Policiais", KnifeLock.targets.police)
        KnifeLock.targets.gang, _ = ImGui.Checkbox("Membros de gangues", KnifeLock.targets.gang)
        KnifeLock.targets.civilian, _ = ImGui.Checkbox("Civis", KnifeLock.targets.civilian)

        ImGui.Separator()

        KnifeLock.autoFire, _ = ImGui.Checkbox("Auto fire", KnifeLock.autoFire)
    end
    ImGui.End()
end)