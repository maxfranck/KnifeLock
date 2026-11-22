// =============================================================================
// KnifeLock - headshot aim assist for throwing knives and throwing axes
//
// What this file does:
//   1. While the player aims with a throwing weapon, it picks the enemy closest
//      to the crosshair, within the configured angle and distance, from an
//      enabled group, with a clear line of sight to the head.
//   2. It keeps (locks onto) that target while the target remains valid.
//   3. It steers the camera toward the target's head, with smoothing.
//   4. It releases the target if it dies, is knocked out, goes behind a wall,
//      or leaves the lock area.
//   5. When the player stops aiming, or there is no target, it undoes all the
//      camera rotation the mod applied.
//
// The settings (enable/disable, distance, angle and groups) come from the CET
// menu (init.lua), through SetKnifeLockSettings.
// =============================================================================

module KnifeLock

// -----------------------------------------------------------------------------
// Behavior constants (not shown in the menu)
// -----------------------------------------------------------------------------
public class KnifeLockConfig {
    // Extra margin (degrees) for keeping an already locked target
    public static func HoldAngleExtra() -> Float { return 15.0; }

    // Distance tolerance (fraction) for keeping a locked target. 1.1 = 10% more
    public static func HoldDistanceSlack() -> Float { return 1.1; }

    // Correction strength, from 0.05 to 1.0
    public static func Strength() -> Float { return 1.0; }

    // Error (degrees) below which the camera is no longer corrected
    public static func Deadzone() -> Float { return 0.5; }

    // Maximum turn speed (degrees per second)
    public static func MaxRate() -> Float { return 720.0; }

    // Maximum total turn allowed, in degrees
    public static func MaxYaw() -> Float { return 90.0; }
    public static func MaxPitch() -> Float { return 70.0; }
}

// -----------------------------------------------------------------------------
// State stored on the player
// -----------------------------------------------------------------------------

// Rotation already applied by KnifeLock (so it can be undone)
@addField(PlayerPuppet)
private let m_knifeLockYaw: Float;

@addField(PlayerPuppet)
private let m_knifeLockPitch: Float;

// Currently locked target
@addField(PlayerPuppet)
private let m_knifeLockTarget: wref<GameObject>;

// Settings received from the CET menu
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

// Accessors for the rotation and target state
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

// Called by the CET menu (init.lua) to send the settings
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
// Main logic
// -----------------------------------------------------------------------------
public class KnifeLockAim {

    // Checks whether the target's group is enabled in the menu.
    // Police and civilians are identified by the game; everything else counts as a gang member.
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

    // Checks whether the line between the crosshair and the point is free of walls and obstacles
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

    // Angle (degrees) between the crosshair and a point. Returns 999 if the point is behind.
    public static func AngleToPoint(crosshairPos: Vector4, crosshairFwd: Vector4, point: Vector4) -> Float {
        let toPoint = Vector4.Normalize(point - crosshairPos);
        let dot = Vector4.Dot(crosshairFwd, toPoint);

        if dot <= 0.0 {
            return 999.0;
        }
        if dot > 1.0 {
            dot = 1.0;
        }

        // sin(angle) = sqrt(1 - cos²). Only valid in front (dot > 0).
        let sinAngle = SqrtF(ClampF(1.0 - dot * dot, 0.0, 1.0));
        return Rad2Deg(AsinF(ClampF(sinAngle, 0.0, 1.0)));
    }

    // Checks whether the locked target is still valid
    public static func IsTargetValid(player: ref<PlayerPuppet>, target: ref<GameObject>) -> Bool {
        if !IsDefined(target) {
            return false;
        }

        // Dead or knocked out is no longer a target
        if !ScriptedPuppet.IsAlive(target) || ScriptedPuppet.IsDefeated(target) {
            return false;
        }

        let dist = Vector4.Distance(player.GetWorldPosition(), target.GetWorldPosition());
        return dist <= player.m_knifeLockMaxDistance * KnifeLockConfig.HoldDistanceSlack();
    }

    // Tries to keep the locked target. Returns true and fills 'head' if it is still valid.
    public static func TryHoldTarget(player: ref<PlayerPuppet>, target: ref<GameObject>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4) -> Bool {
        if !KnifeLockAim.IsTargetValid(player, target) {
            return false;
        }

        // Group disabled in the menu: release the target
        if !KnifeLockAim.IsGroupEnabled(player, target as ScriptedPuppet) {
            return false;
        }

        let headPos: Vector4;
        if !AIActionHelper.GetTargetSlotPosition(target, n"Head", headPos) {
            return false;
        }

        // Outside the hold margin: release the target
        let angle = KnifeLockAim.AngleToPoint(crosshairPos, crosshairFwd, headPos);
        if angle > player.m_knifeLockViewAngle + KnifeLockConfig.HoldAngleExtra() {
            return false;
        }

        // Behind a wall: release the target
        if !KnifeLockAim.IsLineClear(player, crosshairPos, headPos) {
            return false;
        }

        head = headPos;
        return true;
    }

    // Chooses the target closest to the crosshair, within the selection cone.
    public static func FindNewTarget(player: ref<PlayerPuppet>, crosshairPos: Vector4, crosshairFwd: Vector4, out head: Vector4, out chosen: wref<GameObject>) -> Bool {
        let ts = GameInstance.GetTargetingSystem(player.GetGame());
        if !IsDefined(ts) {
            return false;
        }

        // Query: NPCs within the configured distance, without secondary targets
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

                // Only accept targets visible to the game, with a clear line, from an enabled group
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

    // Rotates the camera locally, adding the delta to the current orientation.
    public static func ApplyLocal(player: ref<PlayerPuppet>, deltaYaw: Float, deltaPitch: Float) -> Void {
        let cameraComponent = player.GetFPPCameraComponent();
        if !IsDefined(cameraComponent) {
            return;
        }

        let current = cameraComponent.GetLocalOrientation();
        let euler = Quaternion.ToEulerAngles(current);
        euler.Yaw += deltaYaw;
        euler.Pitch = ClampF(euler.Pitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());
        // Only yaw and pitch are corrected. Zeroing the roll prevents the camera from tilting
        // (the Euler/quaternion conversion can mix yaw and roll).
        euler.Roll = 0.0;
        cameraComponent.SetLocalOrientation(EulerAngles.ToQuat(euler));
    }

    // Corrects the aim toward the head position.
    // The error is the direction to the target projected onto the crosshair axes:
    //   f = forward, r = right, u = up.
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

        // Error in degrees. Yaw is inverted because the camera turns opposite to the projection.
        let yawError = 0.0 - Rad2Deg(AtanF(tx, tz));
        let pitchError = Rad2Deg(AtanF(ty, tz));
        let totalError = SqrtF(yawError * yawError + pitchError * pitchError);

        if totalError <= KnifeLockConfig.Deadzone() {
            return;
        }

        // Fraction of the error to correct this frame, with exponential smoothing
        let dt = ClampF(timeDelta, 0.001, 0.050);
        let response = 10.0 + 38.0 * ClampF(KnifeLockConfig.Strength(), 0.05, 1.0);
        let alpha = 1.0 - ExpF(-response * dt);
        let deltaYaw = yawError * alpha;
        let deltaPitch = pitchError * alpha;

        // Limit the turn speed per frame
        let maxDelta = ClampF(KnifeLockConfig.MaxRate(), 30.0, 720.0) * ClampF(totalError / 20.0, 1.0, 2.0) * dt;
        let totalDelta = SqrtF(deltaYaw * deltaYaw + deltaPitch * deltaPitch);
        if totalDelta > maxDelta && totalDelta > 0.0001 {
            let scale = maxDelta / totalDelta;
            deltaYaw *= scale;
            deltaPitch *= scale;
        }

        // Respect the accumulated total turn and apply only the difference
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();
        let newYaw = ClampF(accumYaw + deltaYaw, -KnifeLockConfig.MaxYaw(), KnifeLockConfig.MaxYaw());
        let newPitch = ClampF(accumPitch + deltaPitch, -KnifeLockConfig.MaxPitch(), KnifeLockConfig.MaxPitch());

        KnifeLockAim.ApplyLocal(player, newYaw - accumYaw, newPitch - accumPitch);
        player.SetKnifeLockAccum(newYaw, newPitch);
    }

    // Undoes the accumulated rotation and releases the locked target
    public static func Release(player: ref<PlayerPuppet>) -> Void {
        let accumYaw = player.GetKnifeLockYaw();
        let accumPitch = player.GetKnifeLockPitch();

        if accumYaw != 0.0 || accumPitch != 0.0 {
            KnifeLockAim.ApplyLocal(player, 0.0 - accumYaw, 0.0 - accumPitch);
            player.SetKnifeLockAccum(0.0, 0.0);
        }

        player.SetKnifeLockTarget(null);
    }

    // Runs every frame while the player is in the aiming state
    public static func Tick(player: ref<PlayerPuppet>, timeDelta: Float) -> Void {
        // Mod disabled in the menu
        if !player.m_knifeLockEnabled {
            KnifeLockAim.Release(player);
            return;
        }

        // Only acts with a throwing weapon (knives and axes)
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

        // 1) Keep the locked target, if it is still valid
        let locked = player.GetKnifeLockTarget();
        if KnifeLockAim.TryHoldTarget(player, locked, crosshairPos, crosshairFwd, head) {
            KnifeLockAim.SteerTo(player, crosshairPos, crosshairFwd, head, timeDelta);
            return;
        }

        // 2) Otherwise choose a new target and lock onto it
        let chosen: wref<GameObject>;
        if KnifeLockAim.FindNewTarget(player, crosshairPos, crosshairFwd, head, chosen) {
            player.SetKnifeLockTarget(chosen);
            KnifeLockAim.SteerTo(player, crosshairPos, crosshairFwd, head, timeDelta);
        } else {
            // 3) No valid target: undo the correction
            KnifeLockAim.Release(player);
        }
    }
}

// -----------------------------------------------------------------------------
// Game hooks
// -----------------------------------------------------------------------------

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    return wrappedMethod();
}

// Runs the logic every frame while the player is aiming
@wrapMethod(AimingStateEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(timeDelta, stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Tick(player, timeDelta);
    }
}

// When aiming stops, undo the rotation and release the target
@wrapMethod(AimingStateEvents)
protected func OnExit(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        KnifeLockAim.Release(player);
    }
}
