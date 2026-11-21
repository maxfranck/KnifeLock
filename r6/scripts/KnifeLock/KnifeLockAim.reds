// =============================================================================
// KnifeLock - AimAssist de headshot para armas de arremesso (facas e machados)
//
// O que este arquivo faz:
//   1. Enquanto o jogador mira com uma arma de arremesso, escolhe o inimigo
//      mais próximo do crosshair, dentro do ângulo e da distância configurados,
//      de um grupo habilitado e com linha livre até a cabeça.
//   2. Mantém (trava) esse alvo enquanto ele continuar válido.
//   3. Gira a câmera em direção à cabeça do alvo, com suavização.
//   4. Solta o alvo se ele morrer, for nocauteado, ficar atrás de parede ou
//      sair da área de travamento.
//   5. Ao sair da mira, ou quando não houver alvo, desfaz todo o giro feito.
//
// As configurações (ligar/desligar, distância, ângulo e grupos)
// vêm do menu do CET (init.lua), por SetKnifeLockSettings.
// =============================================================================

module KnifeLock

// -----------------------------------------------------------------------------
// Constantes de comportamento (não aparecem no menu)
// -----------------------------------------------------------------------------
public class KnifeLockConfig {
    // Margem extra (graus) para manter um alvo já travado
    public static func HoldAngleExtra() -> Float { return 15.0; }

    // Folga (fração) da distância para manter um alvo travado. 1.1 = 10% a mais
    public static func HoldDistanceSlack() -> Float { return 1.1; }

    // Força da correção, de 0.05 a 1.0
    public static func Strength() -> Float { return 1.0; }

    // Erro (graus) abaixo do qual a câmera não é mais corrigida
    public static func Deadzone() -> Float { return 0.5; }

    // Velocidade máxima de giro (graus por segundo)
    public static func MaxRate() -> Float { return 720.0; }

    // Giro total máximo permitido, em graus
    public static func MaxYaw() -> Float { return 90.0; }
    public static func MaxPitch() -> Float { return 70.0; }
}

// -----------------------------------------------------------------------------
// Estado guardado no próprio jogador
// -----------------------------------------------------------------------------

// Giro já aplicado pelo KnifeLock (para poder desfazer)
@addField(PlayerPuppet)
private let m_knifeLockYaw: Float;

@addField(PlayerPuppet)
private let m_knifeLockPitch: Float;

// Alvo travado no momento
@addField(PlayerPuppet)
private let m_knifeLockTarget: wref<GameObject>;

// Configurações vindas do menu do CET
@addField(PlayerPuppet)
private let m_knifeLockEnabled: Bool;

@addField(PlayerPuppet)
private let m_knifeLockMaxDistance: Float;

@addField(PlayerPuppet)
private let m_knifeLockViewAngle: Float;

@addField(PlayerPuppet)
private let m_knifeLockPolice: Bool;

@addField(PlayerPuppet)
private let m_knifeLockGang: Bool;

@addField(PlayerPuppet)
private let m_knifeLockCivilian: Bool;

// Métodos de acesso ao estado do giro e do alvo
@addMethod(PlayerPuppet)
public final func GetKnifeLockYaw() -> Float {
    return this.m_knifeLockYaw;
}

@addMethod(PlayerPuppet)
public final func GetKnifeLockPitch() -> Float {
    return this.m_knifeLockPitch;
}

@addMethod(PlayerPuppet)
public final func SetKnifeLockAccum(yaw: Float, pitch: Float) -> Void {
    this.m_knifeLockYaw = yaw;
    this.m_knifeLockPitch = pitch;
}

@addMethod(PlayerPuppet)
public final func GetKnifeLockTarget() -> wref<GameObject> {
    return this.m_knifeLockTarget;
}

@addMethod(PlayerPuppet)
public final func SetKnifeLockTarget(target: wref<GameObject>) -> Void {
    this.m_knifeLockTarget = target;
}

// Método chamado pelo menu do CET (init.lua) para enviar as configurações
@addMethod(PlayerPuppet)
public final func SetKnifeLockSettings(enabled: Bool, maxDistance: Float, viewAngle: Float, police: Bool, gang: Bool, civilian: Bool) -> Void {
    this.m_knifeLockEnabled = enabled;
    this.m_knifeLockMaxDistance = maxDistance;
    this.m_knifeLockViewAngle = viewAngle;
    this.m_knifeLockPolice = police;
    this.m_knifeLockGang = gang;
    this.m_knifeLockCivilian = civilian;
}

// -----------------------------------------------------------------------------
// Lógica principal
// -----------------------------------------------------------------------------
public class KnifeLockAim {

    // Verifica se o grupo do alvo está habilitado no menu.
    // Policial e civil são identificados pelo jogo; o restante conta como gangue.
    public static func IsGroupEnabled(player: ref<PlayerPuppet>, puppet: ref<ScriptedPuppet>) -> Bool {
        if !IsDefined(puppet) {
            return false;
        }

        if puppet.IsCharacterPolice() || puppet.IsPrevention() {
            return player.m_knifeLockPolice;
        }

        if puppet.IsCivilian() || puppet.IsCrowd() {
            return player.m_knifeLockCivilian;
        }

        return player.m_knifeLockGang;
    }

    // Verifica se a linha entre a mira e o ponto está livre de paredes e obstáculos
    public static func IsLineClear(player: ref<PlayerPuppet>, from: Vector4, to: Vector4) -> Bool {
        let spatial = GameInstance.GetSpatialQueriesSystem(player.GetGame());
        if !IsDefined(spatial) {
            return false;
        }

        let result: TraceResult;
        if spatial.SyncRaycastByCollisionPreset(from, to, n"World Static", result, true) {
            return false;
        }
        if spatial.SyncRaycastByCollisionPreset(from, to, n"World Dynamic", result, true) {
            return false;
        }
        return true;
    }

    // Ângulo (graus) entre a mira e um ponto. Retorna 999 se o ponto estiver atrás.
    public static func AngleToPoint(crosshairPos: Vector4, crosshairFwd: Vector4, point: Vector4) -> Float {
        let toPoint = Vector4.Normalize(point - crosshairPos);
        let dot = Vector4.Dot(crosshairFwd, toPoint);

        if dot <= 0.0 {
            return 999.0;
        }
        if dot > 1.0 {
            dot = 1.0;
        }

        // sen(ângulo) = raiz(1 - cos²). Só é válido na frente (dot > 0).
        let sinAngle = SqrtF(ClampF(1.0 - dot * dot, 0.0, 1.0));
        return Rad2Deg(AsinF(ClampF(sinAngle, 0.0, 1.0)));
    }

    // Verifica se o alvo travado ainda é válido
    public static func IsTargetValid(player: ref<PlayerPuppet>, target: ref<GameObject>) -> Bool {
        if !IsDefined(target) {
            return false;
        }

        // Morto ou nocauteado não é mais alvo
        if !ScriptedPuppet.IsAlive(target) || ScriptedPuppet.IsDefeated(target) {
            return false;
        }

        let dist = Vector4.Distance(player.GetWorldPosition(), target.GetWorldPosition());
        return dist <= player.m_knifeLockMaxDistance * KnifeLockConfig.HoldDistanceSlack();
    }

    // Tenta manter o alvo travado. Retorna true e preenche 'head' se ele ainda valer.
    public static func TryHoldTarget(player: ref<PlayerPuppet>, target: ref<GameObject>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4) -> Bool {
        if !KnifeLockAim.IsTargetValid(player, target) {
            return false;
        }

        // Grupo desabilitado no menu: solta o alvo
        if !KnifeLockAim.IsGroupEnabled(player, target as ScriptedPuppet) {
            return false;
        }

        let headPos: Vector4;
        if !AIActionHelper.GetTargetSlotPosition(target, n"Head", headPos) {
            return false;
        }

        // Fora da margem de travamento: solta o alvo
        let angle = KnifeLockAim.AngleToPoint(crosshairPos, crosshairFwd, headPos);
        if angle > player.m_knifeLockViewAngle + KnifeLockConfig.HoldAngleExtra() {
            return false;
        }

        // Atrás de parede: solta o alvo
        if !KnifeLockAim.IsLineClear(player, crosshairPos, headPos) {
            return false;
        }

        head = headPos;
        return true;
    }

    // Escolhe o alvo mais próximo da mira, dentro do cone de escolha.
    public static func FindNewTarget(player: ref<PlayerPuppet>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4, out chosen: wref<GameObject>) -> Bool {
        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return false;
        }

        // Consulta: NPCs dentro da distância configurada, sem alvos secundários
        let query: TargetSearchQuery;
        query = TSQ_NPC();
        query.testedSet = TargetingSet.Complete;
        query.includeSecondaryTargets = false;
        query.maxDistance = player.m_knifeLockMaxDistance;
        query.filterObjectByDistance = true;
        TargetSearchQuery.SetComponentFilter(query, TargetComponentFilterType.Shooting);

        let parts: array<TS_TargetPartInfo>;
        ts.GetTargetParts(player, query, parts);

        let bestAngle: Float = 999.0;
        let found: Bool = false;

        for part in parts {
            let component = TS_TargetPartInfo.GetComponent(part);
            let entity = component.GetEntity() as GameObject;
            let puppet = entity as ScriptedPuppet;

            let headPos: Vector4;
            if IsDefined(entity) && AIActionHelper.GetTargetSlotPosition(entity, n"Head", headPos) {
                let angle = KnifeLockAim.AngleToPoint(crosshairPos, crosshairFwd, headPos);

                // Só aceita alvos visíveis, com linha livre, de grupo habilitado
                let clear = ts.IsVisibleTarget(player, entity)
                    && KnifeLockAim.IsLineClear(player, crosshairPos, headPos)
                    && KnifeLockAim.IsGroupEnabled(player, puppet);

                if clear && !ScriptedPuppet.IsDefeated(entity) && angle <= player.m_knifeLockViewAngle && angle < bestAngle {
                    bestAngle = angle;
                    head = headPos;
                    chosen = entity;
                    found = true;
                }
            }
        }

        return found;
    }

    // Gira a câmera localmente, somando o delta à orientação atual.
    public static func ApplyLocal(player: ref<PlayerPuppet>, deltaYaw: Float, deltaPitch: Float) -> Void {
        let cameraComponent = player.GetFPPCameraComponent();
        if !IsDefined(cameraComponent) {
            return;
        }

        let current = cameraComponent.GetLocalOrientation();
        let euler = Quaternion.ToEulerAngles(current);
        euler.Yaw += deltaYaw;
        euler.Pitch = ClampF(euler.Pitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());
        // Só yaw e pitch são corrigidos. Zerar o roll evita a câmera inclinar
        // (a conversão Euler/quaternion pode misturar yaw e roll).
        euler.Roll = 0.0;
        cameraComponent.SetLocalOrientation(EulerAngles.ToQuat(euler));
    }

    // Corrige a mira em direção ao ponto da cabeça.
    // O erro é a direção até o alvo projetada nos eixos da mira:
    //   f = frente, r = direita, u = cima.
    public static func SteerTo(player: ref<PlayerPuppet>, crosshairPos: Vector4, crosshairFwd: Vector4, aimPosition: Vector4, timeDelta: Float) -> Void {
        let f = Vector4.Normalize(crosshairFwd);
        let r = Vector4.Normalize(Vector4(f.Y, 0.0 - f.X, 0.0, 0.0));
        let u = Vector4(r.Y * f.Z - r.Z * f.Y, r.Z * f.X - r.X * f.Z, r.X * f.Y - r.Y * f.X, 0.0);

        let t = Vector4.Normalize(aimPosition - crosshairPos);
        let tx = Vector4.Dot(t, r);
        let ty = Vector4.Dot(t, u);
        let tz = Vector4.Dot(t, f);

        if tz <= 0.01 {
            return;
        }

        // Erro em graus. O yaw é invertido porque o giro da câmera vai no sentido oposto à projeção.
        let yawError = 0.0 - Rad2Deg(AtanF(tx, tz));
        let pitchError = Rad2Deg(AtanF(ty, tz));
        let totalError = SqrtF(yawError * yawError + pitchError * pitchError);

        if totalError <= KnifeLockConfig.Deadzone() {
            return;
        }

        // Fração do erro a corrigir neste frame, com suavização exponencial
        let dt = ClampF(timeDelta, 0.001, 0.050);
        let response = 10.0 + 38.0 * ClampF(KnifeLockConfig.Strength(), 0.05, 1.0);
        let alpha = 1.0 - ExpF(-response * dt);
        let deltaYaw = yawError * alpha;
        let deltaPitch = pitchError * alpha;

        // Limita a velocidade de giro por frame
        let maxDelta = ClampF(KnifeLockConfig.MaxRate(), 30.0, 720.0) * ClampF(totalError / 20.0, 1.0, 2.0) * dt;
        let totalDelta = SqrtF(deltaYaw * deltaYaw + deltaPitch * deltaPitch);
        if totalDelta > maxDelta && totalDelta > 0.0001 {
            let scale = maxDelta / totalDelta;
            deltaYaw *= scale;
            deltaPitch *= scale;
        }

        // Respeita o giro total acumulado e aplica só a diferença
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();
        let newYaw = ClampF(accumYaw + deltaYaw, -KnifeLockConfig.MaxYaw(), KnifeLockConfig.MaxYaw());
        let newPitch = ClampF(accumPitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());

        KnifeLockAim.ApplyLocal(player, newYaw - accumYaw, newPitch - accumPitch);
        player.SetKnifeLockAccum(newYaw, newPitch);
    }

    // Desfaz o giro acumulado e solta o alvo travado
    public static func Release(player: ref<PlayerPuppet>) -> Void {
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();

        if accumYaw != 0.0 || accumPitch != 0.0 {
            KnifeLockAim.ApplyLocal(player, 0.0 - accumYaw, 0.0 - accumPitch);
            player.SetKnifeLockAccum(0.0, 0.0);
        }

        player.SetKnifeLockTarget(null);
    }

    // Executado a cada frame enquanto o jogador está no estado de mira
    public static func Tick(player: ref<PlayerPuppet>, timeDelta: Float) -> Void {
        // Mod desligado no menu
        if !player.m_knifeLockEnabled {
            KnifeLockAim.Release(player);
            return;
        }

        // Só atua com arma de arremesso (facas e machados)
        let weapon = GameObject.GetActiveWeapon(player) as WeaponObject;
        if !IsDefined(weapon) || !weapon.IsThrowable() {
            KnifeLockAim.Release(player);
            return;
        }

        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return;
        }

        let crosshairPos: Vector4;
        let crosshairFwd: Vector4;
        ts.GetDefaultCrosshairData(player, crosshairPos, crosshairFwd);
        crosshairFwd = Vector4.Normalize(crosshairFwd);

        let head: Vector4;

        // 1) Mantém o alvo travado, se ele ainda for válido
        let locked = player.GetKnifeLockTarget();
        if KnifeLockAim.TryHoldTarget(player, locked, crosshairPos, crosshairFwd, head) {
            KnifeLockAim.SteerTo(player, crosshairPos, crosshairFwd, head, timeDelta);
            return;
        }

        // 2) Senão, escolhe um alvo novo e trava nele
        let chosen: wref<GameObject>;
        if KnifeLockAim.FindNewTarget(player, crosshairPos, crosshairFwd, head, chosen) {
            player.SetKnifeLockTarget(chosen);
            KnifeLockAim.SteerTo(player, crosshairPos, crosshairFwd, head, timeDelta);
        } else {
            // 3) Nenhum alvo válido: desfaz a correção
            KnifeLockAim.Release(player);
        }
    }
}

// -----------------------------------------------------------------------------
// Hooks no jogo
// -----------------------------------------------------------------------------

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    return wrappedMethod();
}

// Executa a lógica a cada frame enquanto o jogador está mirando
@wrapMethod(AimingStateEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(timeDelta, stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Tick(player, timeDelta);
    }
}

// Ao sair da mira, desfaz o giro e solta o alvo
@wrapMethod(AimingStateEvents)
protected func OnExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Release(player);
    }
}
