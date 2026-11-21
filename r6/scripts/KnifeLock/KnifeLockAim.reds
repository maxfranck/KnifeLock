module KnifeLock

public class KnifeLockConfig {
    public static func MaxDistance() -> Float { return 30.0; }
    public static func ViewAngle() -> Float { return 15.0; }
    public static func Strength() -> Float { return 1.0; }
    public static func Deadzone() -> Float { return 0.5; }
    public static func MaxRate() -> Float { return 720.0; }
    public static func MaxYaw() -> Float { return 90.0; }
    public static func MaxPitch() -> Float { return 85.0; }
}

// Guarda quanto a câmera já foi girado pelo KnifeLock, para poder desfazer depois
@addField(PlayerPuppet)
private let m_knifeLockYaw: Float;

@addField(PlayerPuppet)
private let m_knifeLockPitch: Float;

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

public class KnifeLockAim {
    // Procura o alvo mais próximo do crosshair dentro do ângulo e da distância
    public static func FindHead(player: ref<PlayerPuppet>, out head: Vector4) -> Bool {
        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return false;
        }

        let crosshairPos: Vector4;
        let crosshairFwd: Vector4;
        ts.GetDefaultCrosshairData(player, crosshairPos, crosshairFwd);
        let fwd = Vector4.Normalize(crosshairFwd);

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
                let toHead = Vector4.Normalize(headPos - crosshairPos);
                let dot = Vector4.Dot(fwd, toHead);
                if dot > 1.0 {
                    dot = 1.0;
                }
                if dot < -1.0 {
                    dot = -1.0;
                }
                let sinAngle = SqrtF(ClampF(1.0 - dot * dot, 0.0, 1.0));
                let angle = Rad2Deg(AsinF(ClampF(sinAngle, 0.0, 1.0)));

                if dot > 0.0 && angle <= KnifeLockConfig.ViewAngle() && angle < bestAngle {
                    bestAngle = angle;
                    head = headPos;
                    found = true;
                }
            }
        }

        return found;
    }

    // Gira a câmera localmente em yaw e pitch, respeitando os limites
    public static func ApplyLocal(player: ref<PlayerPuppet>, deltaYaw: Float, deltaPitch: Float) -> Void {
        let cameraComponent = player.GetFPPCameraComponent();
        if !IsDefined(cameraComponent) {
            return;
        }

        let current = cameraComponent.GetLocalOrientation();
        let euler = Quaternion.ToEulerAngles(current);
        euler.Yaw += deltaYaw;
        euler.Pitch = ClampF(euler.Pitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());
        cameraComponent.SetLocalOrientation(EulerAngles.ToQuat(euler));
    }

    // Aplica a correção em direção ao ponto da cabeça.
    // O erro é a direção do alvo projetada nos eixos da mira (direita, cima e frente).
    public static func SteerTo(player: ref<PlayerPuppet>, aimPosition: Vector4, timeDelta: Float) -> Void {
        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return;
        }

        let crosshairPos: Vector4;
        let crosshairFwd: Vector4;
        ts.GetDefaultCrosshairData(player, crosshairPos, crosshairFwd);

        let f = Vector4.Normalize(crosshairFwd);
        let r = Vector4.Normalize(Vector4(f.Y, 0.0 - f.X, 0.0, 0.0));
        let u = Vector4(r.Y * f.Z - r.Z * f.Y, r.Z * f.X - r.X * f.Z, r.X * f.Y - r.Y * f.X, 0.0);

        let t = Vector4.Normalize(aimPosition - crosshairPos);
        let tx = Vector4.Dot(t, r);
        let ty = Vector4.Dot(t, u);
        let tz = Vector4.Dot(t, f);

        let yawError = 0.0 - Rad2Deg(AtanF(tx, tz));
        let pitchError = Rad2Deg(AtanF(ty, tz));
        let totalError = SqrtF(yawError * yawError + pitchError * pitchError);

        FTLog("KnifeLock: erro yaw=" + ToString(yawError) + " pitch=" + ToString(pitchError) + " total=" + ToString(totalError) + " tz=" + ToString(tz) + " acumYaw=" + ToString(player.GetKnifeLockYaw()) + " acumPitch=" + ToString(player.GetKnifeLockPitch()));

        if tz <= 0.01 {
            FTLog("KnifeLock: alvo fora da frente da mira (tz baixo)");
            return;
        }

        if totalError <= KnifeLockConfig.Deadzone() {
            return;
        }

        let dt = ClampF(timeDelta, 0.001, 0.050);
        let response = 10.0 + 38.0 * ClampF(KnifeLockConfig.Strength(), 0.05, 1.0);
        let alpha = 1.0 - ExpF(-response * dt);
        let deltaYaw = yawError * alpha;
        let deltaPitch = pitchError * alpha;

        let maxDelta = ClampF(KnifeLockConfig.MaxRate(), 30.0, 720.0) * ClampF(totalError / 20.0, 1.0, 2.0) * dt;
        let totalDelta = SqrtF(deltaYaw * deltaYaw + deltaPitch * deltaPitch);
        if totalDelta > maxDelta && totalDelta > 0.0001 {
            let scale = maxDelta / totalDelta;
            deltaYaw *= scale;
            deltaPitch *= scale;
        }

        // Respeita o limite total de giro acumulado
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();
        let newYaw = ClampF(accumYaw + deltaYaw, -KnifeLockConfig.MaxYaw(), KnifeLockConfig.MaxYaw());
        let newPitch = ClampF(accumPitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());

        KnifeLockAim.ApplyLocal(player, newYaw - accumYaw, newPitch - accumPitch);
        player.SetKnifeLockAccum(newYaw, newPitch);
    }

    // Desfaz todo o giro acumulado, para a câmera voltar ao normal
    public static func Release(player: ref<PlayerPuppet>) -> Void {
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();

        if accumYaw != 0.0 || accumPitch != 0.0 {
            KnifeLockAim.ApplyLocal(player, 0.0 - accumYaw, 0.0 - accumPitch);
            player.SetKnifeLockAccum(0.0, 0.0);
        }
    }

    public static func Tick(player: ref<PlayerPuppet>, timeDelta: Float) -> Void {
        let weapon = GameObject.GetActiveWeapon(player) as WeaponObject;
        if !IsDefined(weapon) {
            FTLog("KnifeLock: sem arma ativa");
            KnifeLockAim.Release(player);
            return;
        }
        if !weapon.IsThrowable() {
            FTLog("KnifeLock: arma nao e de arremesso");
            KnifeLockAim.Release(player);
            return;
        }

        let head: Vector4;
        if KnifeLockAim.FindHead(player, head) {
            FTLog("KnifeLock: alvo encontrado, steer");
            KnifeLockAim.SteerTo(player, head, timeDelta);
        } else {
            FTLog("KnifeLock: nenhum alvo no cone");
            KnifeLockAim.Release(player);
        }
    }
}

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    return wrappedMethod();
}

@wrapMethod(AimingStateEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(timeDelta, stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Tick(player, timeDelta);
    }
}

@wrapMethod(AimingStateEvents)
protected func OnExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Release(player);
    }
}
