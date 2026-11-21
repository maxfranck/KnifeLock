// =============================================================================
// KnifeLock - AimAssist de headshot para armas de arremesso (facas e machados)
//
// O que este arquivo faz:
//   1. Enquanto o jogador mira com uma arma de arremesso, escolhe o inimigo
//      mais próximo do crosshair, dentro do ângulo e da distância configurados.
//   2. Mantém (trava) esse alvo enquanto ele continuar válido, mesmo que outro
//      inimigo fique mais perto da mira.
//   3. Gira a câmera em direção à cabeça do alvo, com suavização.
//   4. Ao sair da mira, ou quando não houver alvo, desfaz todo o giro feito.
//
// Observação: os valores abaixo estão fixos no código. O menu do CET (init.lua)
// ainda não controla este arquivo.
// =============================================================================

module KnifeLock

// -----------------------------------------------------------------------------
// Configurações
// -----------------------------------------------------------------------------
public class KnifeLockConfig {
    // Distância máxima (metros) para escolher um alvo
    public static func MaxDistance() -> Float { return 30.0; }

    // Ângulo máximo (graus) para escolher um alvo novo
    public static func ViewAngle() -> Float { return 15.0; }

    // Margem extra (graus) para manter um alvo já travado.
    // Com ela, o alvo continua travado mesmo se sair um pouco do cone de escolha.
    public static func HoldAngleExtra() -> Float { return 15.0; }

    // Folga (fração) da distância para manter um alvo travado.
    // 1.1 significa 10% a mais que MaxDistance.
    public static func HoldDistanceSlack() -> Float { return 1.1; }

    // Força da correção, de 0.05 a 1.0. Valores maiores reagem mais rápido
    public static func Strength() -> Float { return 1.0; }

    // Erro (graus) abaixo do qual a câmera não é mais corrigida
    public static func Deadzone() -> Float { return 0.5; }

    // Velocidade máxima de giro (graus por segundo)
    public static func MaxRate() -> Float { return 720.0; }

    // Giro total máximo permitido, em graus, na horizontal e na vertical
    public static func MaxYaw() -> Float { return 90.0; }
    public static func MaxPitch() -> Float { return 70.0; }
}

// -----------------------------------------------------------------------------
// Estado guardado no próprio jogador:
//   - quanto a câmera já foi girada pelo KnifeLock (para desfazer depois)
//   - qual alvo está travado no momento
// -----------------------------------------------------------------------------
@addField(PlayerPuppet)
private let m_knifeLockYaw: Float;

@addField(PlayerPuppet)
private let m_knifeLockPitch: Float;

@addField(PlayerPuppet)
private let m_knifeLockTarget: wref<GameObject>;

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

// -----------------------------------------------------------------------------
// Lógica principal
// -----------------------------------------------------------------------------
public class KnifeLockAim {

    // Verifica se a linha entre a mira e o ponto está livre de paredes e obstáculos.
    // Usa raycast contra geometria estática e dinâmica do mundo.
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

    // Calcula o ângulo (graus) entre a mira e um ponto.
    // Retorna 999 se o ponto estiver atrás da mira, para nunca ser aceito.
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

    // Verifica se um alvo ainda é válido: vivo, não nocauteado e dentro da distância
    public static func IsTargetValid(player: ref<PlayerPuppet>, target: ref<GameObject>) -> Bool {
        if !IsDefined(target) {
            return false;
        }

        // Morto ou nocauteado (derrubado) não é mais alvo válido.
        // Estas funções são estáticas e recebem o alvo como argumento.
        if !ScriptedPuppet.IsAlive(target) || ScriptedPuppet.IsDefeated(target) {
            return false;
        }

        let dist = Vector4.Distance(player.GetWorldPosition(), target.GetWorldPosition());
        return dist <= KnifeLockConfig.MaxDistance() * KnifeLockConfig.HoldDistanceSlack();
    }

    // Tenta manter o alvo já travado. Retorna true e preenche 'head' se ele ainda valer.
    public static func TryHoldTarget(player: ref<PlayerPuppet>, target: ref<GameObject>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4) -> Bool {
        if !KnifeLockAim.IsTargetValid(player, target) {
            return false;
        }

        let headPos: Vector4;
        if !AIActionHelper.GetTargetSlotPosition(target, n"Head", headPos) {
            return false;
        }

        let angle = KnifeLockAim.AngleToPoint(crosshairPos, crosshairFwd, headPos);
        if angle > KnifeLockConfig.ViewAngle() + KnifeLockConfig.HoldAngleExtra() {
            return false;
        }

        // Alvo atrás de parede: solta o travamento
        if !KnifeLockAim.IsLineClear(player, crosshairPos, headPos) {
            return false;
        }

        head = headPos;
        return true;
    }

    // Escolhe o alvo mais próximo da mira, dentro do cone de escolha.
    // Retorna true e preenche 'head' e 'chosen' com o alvo encontrado.
    public static func FindNewTarget(player: ref<PlayerPuppet>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4, out chosen: wref<GameObject>) -> Bool {
        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return false;
        }

        // Consulta: NPCs dentro da distância, sem alvos secundários
        let query: TargetSearchQuery;
        query = TSQ_NPC();
        query.testedSet = TargetingSet.Complete;
        query.includeSecondaryTargets = false;
        query.maxDistance = KnifeLockConfig.MaxDistance();
        query.filterObjectByDistance = true;
        TargetSearchQuery.SetComponentFilter(query, TargetComponentFilterType.Shooting);

        let parts: array<TS_TargetPartInfo>;
        ts.GetTargetParts(player, query, parts);

        let bestAngle: Float = 999.0;
        let found: Bool = false;

        for part in parts {
            let component = TS_TargetPartInfo.GetComponent(part);
            let entity = component.GetEntity() as GameObject;

            let headPos: Vector4;
            if IsDefined(entity) && AIActionHelper.GetTargetSlotPosition(entity, n"Head", headPos) {
                let angle = KnifeLockAim.AngleToPoint(crosshairPos, crosshairFwd, headPos);

                // Só aceita alvos visíveis para o jogo e com linha livre até a cabeça
                let clear = ts.IsVisibleTarget(player, entity) && KnifeLockAim.IsLineClear(player, crosshairPos, headPos);

                if clear && angle <= KnifeLockConfig.ViewAngle() && angle < bestAngle {
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
        // O KnifeLock só corrige yaw e pitch. Zerar o roll impede a câmera de inclinar
        // ao longo das correções (a conversão Euler/quaternion pode misturar yaw e roll).
        euler.Roll = 0.0;
        cameraComponent.SetLocalOrientation(EulerAngles.ToQuat(euler));
    }

    // Corrige a mira em direção ao ponto da cabeça.
    //
    // O erro é a direção até o alvo projetada em três eixos da mira:
    //   f = frente do crosshair
    //   r = direita (produto vetorial de f com o eixo vertical)
    //   u = cima (produto vetorial de r com f)
    // A componente em r dá o erro horizontal (yaw) e a componente em u, o vertical (pitch).
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

    // Desfaz o giro acumulado e solta o alvo travado.
    public static func Release(player: ref<PlayerPuppet>) -> Void {
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();

        if accumYaw != 0.0 || accumPitch != 0.0 {
            KnifeLockAim.ApplyLocal(player, 0.0 - accumYaw, 0.0 - accumPitch);
            player.SetKnifeLockAccum(0.0, 0.0);
        }

        player.SetKnifeLockTarget(null);
    }

    // Executado a cada frame enquanto o jogador está no estado de mira.
    public static func Tick(player: ref<PlayerPuppet>, timeDelta: Float) -> Void {
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
            // 3) Nenhum alvo: desfaz a correção
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
