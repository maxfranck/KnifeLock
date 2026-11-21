-- KnifeLock: AimAssist de headshot para armas de arremesso (facas e machados)
-- Esta versão: menu ImGui, detecção de arma e de mira, listagem de alvos,
-- seleção do alvo mais próximo da mira dentro do ângulo e da distância,
-- posição da cabeça (com diagnóstico) e posição dos pés para conferir a altura.
-- Travamento contínuo ainda não implementado.

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

-- Tipos de item aceitos pelo mod
local THROWABLE_TYPES = {
    Wea_Knife = true,
    Wea_Axe = true,
}

local overlayOpen = false
local lastWeapon = nil
local aiming = false

-- ===== Vetores (matemática em Lua pura) =====

local function vsub(a, b)
    return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function vlen(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vnorm(v)
    local l = vlen(v)
    if l == 0 then return { x = 0, y = 0, z = 0 } end
    return { x = v.x / l, y = v.y / l, z = v.z / l }
end

local function vdot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function toVec(v)
    return { x = v.x, y = v.y, z = v.z }
end

-- Procura, entre vários valores de retorno, um que seja um vetor (tenha x, y, z)
local function findVector(...)
    local values = { ... }
    for _, v in ipairs(values) do
        local ok, vec = pcall(toVec, v)
        if ok and vec.x ~= nil and vec.y ~= nil and vec.z ~= nil then
            return vec
        end
    end
    return nil
end

-- ===== Utilidades do jogo =====

-- Retorna o nome do tipo do item (ex.: Wea_Knife, Wea_Axe)
local function getItemTypeName(itemID)
    local record = TweakDB:GetRecord(itemID)
    if not record then return nil end

    local itemType = record:ItemType()
    if not itemType then return nil end

    return tostring(itemType:Type().value)
end

local function isThrowableWeapon(itemType)
    return THROWABLE_TYPES[itemType] == true
end

-- Verifica se o jogador está mirando (ADS)
local function isPlayerAiming()
    local player = Game.GetPlayer()
    if not player then return false end

    local ok, result = pcall(function()
        local bb = Game.GetBlackboardSystem():GetLocalInstanced(
            player:GetEntityID(),
            GetAllBlackboardDefs().PlayerStateMachine
        )
        if bb == nil then return false end

        local upper = bb:GetInt(GetAllBlackboardDefs().PlayerStateMachine.UpperBody)
        return upper == gamePSMUpperBodyStates.Aim
    end)

    if ok and result then return true end

    local ok2, result2 = pcall(function()
        return Game.GetStatusEffectSystem():HasStatusEffect(
            player:GetEntityID(),
            TweakDBID.new("BaseStatusEffect.PlayerAiming")
        )
    end)

    return ok2 and result2 == true
end

-- Pega a entidade de um TS_TargetPartInfo
local function partToEntity(part)
    local ok, entity = pcall(function()
        local component = TS_TargetPartInfo.GetComponent(part)
        if component == nil then return nil end
        return component:GetEntity()
    end)
    if ok then return entity end
    return nil
end

-- Classifica o alvo seguindo a mesma regra do outro mod
local function classifyTarget(entity, player)
    local info = { group = "gangue", hostile = false, attitudeRaw = "?", attitudeErr = nil }

    local okP, isPolice = pcall(function()
        return entity:IsCharacterPolice() or entity:IsPrevention()
    end)
    local okC, isCivilian = pcall(function()
        return entity:IsCivilian() or entity:IsCrowd()
    end)

    local okA, attitude = pcall(function()
        return GameObject.GetAttitudeTowards(entity, player)
    end)

    if okA and attitude ~= nil then
        info.attitudeRaw = tostring(attitude)
        local okH, isHostile = pcall(function()
            return attitude == EAIAttitude.AIA_Hostile
        end)
        if okH then
            info.hostile = isHostile == true
        end
    else
        info.attitudeErr = tostring(attitude)
    end

    if okP and isPolice then
        info.group = "policial"
    elseif okC and isCivilian then
        info.group = "civil"
    end

    return info
end

-- Obtém a origem e a direção da mira pelo crosshair do TargetingSystem
local function getAimRay(player, ts)
    local okX, cPos, cFwd = pcall(function()
        return ts:GetDefaultCrosshairData(player)
    end)
    if okX and cPos and cFwd then
        return toVec(cPos), toVec(cFwd), "crosshair"
    end

    local okP, pPos, pFwd = pcall(function()
        return player:GetWorldPosition(), player:GetWorldForward()
    end)
    if okP and pPos and pFwd then
        return toVec(pPos), toVec(pFwd), "jogador"
    end

    return nil, nil, "nenhuma"
end

-- Tenta obter a posição da cabeça do alvo (slot "Head"), com diagnóstico
local function getHeadPosition(entity)
    local attempts = {
        {
            name = "AIActionHelper(texto)",
            fn = function() return AIActionHelper.GetTargetSlotPosition(entity, "Head") end,
        },
        {
            name = "AIActionHelper(CName)",
            fn = function() return AIActionHelper.GetTargetSlotPosition(entity, CName.new("Head")) end,
        },
    }

    local log = {}
    for _, attempt in ipairs(attempts) do
        local ok, r1, r2 = pcall(attempt.fn)
        if ok then
            local vec = findVector(r1, r2)
            if vec then
                return vec, attempt.name
            end
            table.insert(log, attempt.name .. ": retorno sem vetor (r1=" .. tostring(r1) .. ", r2=" .. tostring(r2) .. ")")
        else
            table.insert(log, attempt.name .. ": erro=" .. tostring(r1))
        end
    end

    return nil, table.concat(log, " | ")
end

-- Verifica se o grupo do alvo está marcado no menu
local function isGroupEnabled(group)
    if group == "policial" then return KnifeLock.targets.police end
    if group == "civil" then return KnifeLock.targets.civilian end
    if group == "gangue" then return KnifeLock.targets.gang end
    return false
end

-- Lista os alvos, aplica os filtros e escolhe o mais próximo da mira
local function selectTarget()
    local player = Game.GetPlayer()
    if not player then return end

    local ts = Game.GetTargetingSystem()
    if not ts then
        print("Seleção: TargetingSystem indisponível")
        return
    end

    local okQ, query = pcall(function() return TSQ_NPC() end)
    if not okQ or not query then
        print("Seleção: não consegui criar TSQ_NPC")
        return
    end

    query.maxDistance = KnifeLock.maxDistance
    query.filterObjectByDistance = true
    query.includeSecondaryTargets = false
    query.ignoreInstigator = true

    local ok, found, parts = pcall(function()
        return ts:GetTargetParts(player, query)
    end)

    if not ok then
        print("GetTargetParts erro: " .. tostring(found))
        return
    end

    if type(parts) ~= "table" then
        print("GetTargetParts: lista inválida")
        return
    end

    local aimPos, aimFwd, aimSource = getAimRay(player, ts)
    if not aimPos or not aimFwd then
        print("Seleção: sem direção de mira")
        return
    end

    local best = nil
    local bestAngle = math.huge

    for i, part in ipairs(parts) do
        local entity = partToEntity(part)
        if entity ~= nil then
            local info = classifyTarget(entity, player)

            local okD, dist = pcall(function()
                return Vector4.Distance(player:GetWorldPosition(), entity:GetWorldPosition())
            end)

            local okAng, angle = pcall(function()
                local tp = toVec(entity:GetWorldPosition())
                local toTarget = vnorm(vsub(tp, aimPos))
                local dot = vdot(vnorm(aimFwd), toTarget)
                if dot > 1.0 then dot = 1.0 end
                if dot < -1.0 then dot = -1.0 end
                return math.deg(math.acos(dot))
            end)

            local inRange = okD and dist <= KnifeLock.maxDistance
            local inCone = okAng and angle <= KnifeLock.viewAngle
            local groupOk = isGroupEnabled(info.group)

            print(string.format(
                "  [%d] grupo=%s | hostil=%s | dist=%s | ângulo=%s | ok=%s",
                i,
                info.group,
                tostring(info.hostile),
                okD and string.format("%.1f", dist) or "?",
                okAng and string.format("%.1f", angle) or "erro",
                tostring(inRange and inCone and groupOk)
            ))

            if inRange and inCone and groupOk and okAng and angle < bestAngle then
                bestAngle = angle
                best = { entity = entity, info = info, dist = dist, angle = angle }
            end
        end
    end

    if best == nil then
        print("Alvo escolhido: nenhum dentro do ângulo, distância e grupos marcados")
        return
    end

    print(string.format(
        "Alvo escolhido: grupo=%s | dist=%.1f | ângulo=%.1f | mira=%s",
        best.info.group, best.dist, best.angle, aimSource
    ))

    -- Posição dos pés do alvo, para conferir a altura da cabeça
    local okFeet, feet = pcall(function()
        return toVec(best.entity:GetWorldPosition())
    end)
    if okFeet and feet then
        print(string.format("Pés do alvo: x=%.2f y=%.2f z=%.2f", feet.x, feet.y, feet.z))
    else
        print("Pés do alvo: não obtidos")
    end

    local okH, head, headInfo = pcall(getHeadPosition, best.entity)
    if not okH then
        print("Cabeça: erro inesperado: " .. tostring(head))
        return
    end

    if head then
        print(string.format(
            "Cabeça: x=%.2f y=%.2f z=%.2f | origem=%s",
            head.x, head.y, head.z, tostring(headInfo)
        ))

        if okFeet and feet then
            print(string.format("Diferença de altura (cabeça - pés): %.2f m", head.z - feet.z))
        end
    else
        print("Cabeça: não obtida | " .. tostring(headInfo))
    end
end

registerForEvent("onInit", function()
    print("KnifeLock carregado")
end)

registerForEvent("onOverlayOpen", function()
    overlayOpen = true
end)

registerForEvent("onOverlayClose", function()
    overlayOpen = false
end)

registerForEvent("onUpdate", function(dt)
    local player = Game.GetPlayer()
    if not player then return end

    local item = Game.GetTransactionSystem():GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight"))
    local weapon = nil
    local itemType = nil

    if item then
        local itemID = item:GetItemID().tdbid
        weapon = TDBID.ToStringDEBUG(itemID)
        itemType = getItemTypeName(itemID)
    end

    local valid = isThrowableWeapon(itemType)

    if weapon ~= lastWeapon then
        lastWeapon = weapon
        print("Arma equipada: " .. tostring(weapon) .. " | tipo: " .. tostring(itemType) .. " | válida: " .. tostring(valid))
    end

    local nowAiming = isPlayerAiming()
    if nowAiming ~= aiming then
        aiming = nowAiming
        print("Mirando: " .. tostring(aiming) .. " | válida: " .. tostring(valid))

        if aiming and valid then
            local okS, errS = pcall(selectTarget)
            if not okS then
                print("Seleção erro: " .. tostring(errS))
            end
        end
    end
end)

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