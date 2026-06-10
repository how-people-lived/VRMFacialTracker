import SceneKit
import Vision
import simd

/// Applies head/neck/arm/finger rotations from ARKit + Vision data to the VRM skeleton.
///
/// Head & neck rotation follows the mediapipe-vrm-tracking JS reference exactly:
///   head.rotation(-eu.x*0.6, -eu.y*0.6, eu.z*0.6, YXZ)
///   neck.rotation(-eu.x*0.25, -eu.y*0.25, eu.z*0.25, YXZ)
///
/// Arm rotation uses the quaternion-chain approach from the same reference, adapted for
/// Vision 2D landmarks (no depth). The key fix: lower-arm local space is derived from the
/// TARGET upper-arm quaternion, not the current animated value, preventing drift.
final class VRMBoneMapper {

    private weak var scene: SCNScene?
    private let model: VRMModel
    private var restOrientations = [String: simd_quatf]()

    private lazy var fingerSegments: [FingerSegment] = makeFingerSegments()

    init(scene: SCNScene, model: VRMModel) {
        self.scene = scene
        self.model = model
    }

    // MARK: - Public

    func apply(face: FaceData?, body: BodyData?, leftHand: HandData?, rightHand: HandData?) {
        guard let scene else { return }
        if restOrientations.isEmpty { captureRest(scene: scene) }

        if let face { applyHead(face: face, scene: scene) }
        if let body { applyArms(body: body, scene: scene) }
        if let lh = leftHand  { applyFingers(hand: lh, side: .left,  scene: scene) }
        if let rh = rightHand { applyFingers(hand: rh, side: .right, scene: scene) }
    }

    // MARK: - Head / Neck

    private func applyHead(face: FaceData, scene: SCNScene) {
        let q = face.headRotation
        let quat = simd_quatf(vector: SIMD4<Float>(q.x, q.y, q.z, q.w)).normalized
        // ARKit face transform → YXZ Euler in camera space
        let eu = quat.yxzEuler

        // Apply same scaling + axis negation as JS reference (YXZ intrinsic order)
        if let headNode = boneNode(VRMBone.head, scene: scene) {
            let d = simd_quatf(yxzEuler: SIMD3(-eu.x * 0.6, -eu.y * 0.6, eu.z * 0.6))
            headNode.simdOrientation = restOri(VRMBone.head) * d
        }
        if let neckNode = boneNode(VRMBone.neck, scene: scene) {
            let d = simd_quatf(yxzEuler: SIMD3(-eu.x * 0.25, -eu.y * 0.25, eu.z * 0.25))
            neckNode.simdOrientation = restOri(VRMBone.neck) * d
        }
    }

    // MARK: - Arms

    private enum Side { case left, right }

    private func applyArms(body: BodyData, scene: SCNScene) {
        applyArmSide(.left,  joints: body.joints, scene: scene)
        applyArmSide(.right, joints: body.joints, scene: scene)
    }

    private func applyArmSide(_ side: Side, joints: [String: JointPoint], scene: SCNScene) {
        let shKey, elKey, wrKey: String
        let prefix: String
        switch side {
        case .left:
            shKey = Key.Body.leftShoulder;  elKey = Key.Body.leftElbow;  wrKey = Key.Body.leftWrist;  prefix = "left"
        case .right:
            shKey = Key.Body.rightShoulder; elKey = Key.Body.rightElbow; wrKey = Key.Body.rightWrist; prefix = "right"
        }

        guard let sh = joints[shKey], sh.confidence > 0.4,
              let el = joints[elKey], el.confidence > 0.4,
              let wr = joints[wrKey], wr.confidence > 0.3 else { return }

        // Vision front-camera: image is left-right mirrored relative to the person.
        // Negate X to get person-relative direction. Negate Y (Vision Y=0 is top).
        let uDir = normalize3(x: -(el.x - sh.x), y: -(el.y - sh.y))
        let lDir = normalize3(x: -(wr.x - el.x), y: -(wr.y - el.y))

        // VRM T-pose: right arm points +X, left arm points -X (normalized bone space).
        let tPose = SIMD3<Float>(side == .right ? 1 : -1, 0, 0)

        // Upper arm rotation: T-pose → current direction
        let uQ = safeFromTo(from: tPose, to: uDir)
        if let node = boneNode("\(prefix)UpperArm", scene: scene) {
            node.simdOrientation = restOri("\(prefix)UpperArm") * uQ
        }

        // Lower arm: transform world direction into upper-arm LOCAL space using the
        // TARGET quaternion uQ (not the current animated quaternion — avoids drift).
        let lDirLocal = simd_act(uQ.inverse, lDir)
        let lQ = safeFromTo(from: tPose, to: lDirLocal)
        if let node = boneNode("\(prefix)LowerArm", scene: scene) {
            node.simdOrientation = restOri("\(prefix)LowerArm") * lQ
        }
    }

    // Lift 2D Vision point to 3D in the XY plane (Z=0), normalised.
    private func normalize3(x: Float, y: Float) -> SIMD3<Float> {
        let len = (x * x + y * y).squareRoot()
        guard len > 0.001 else { return SIMD3(0, -1, 0) }
        return SIMD3(x / len, y / len, 0)
    }

    // Quaternion that rotates `from` to `to`; falls back to 180° around Z when anti-parallel.
    private func safeFromTo(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        guard simd_dot(a, b) > -0.9999 else {
            return simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
        }
        return simd_quatf(from: a, to: b)
    }

    // MARK: - Fingers

    private struct FingerSegment {
        let parentKey: String; let childKey: String
        let leftBone: String;  let rightBone: String
    }

    private func makeFingerSegments() -> [FingerSegment] {
        func seg(_ p: String, _ c: String, _ l: String, _ r: String) -> FingerSegment {
            FingerSegment(parentKey: p, childKey: c, leftBone: l, rightBone: r)
        }
        let hk = Key.Hand.self; let lb = VRMBone.self

        // VRM 1.0 vs 0.x thumb naming: detect by checking which bone is present.
        let hasMetaL = model.boneNodeMap[lb.leftThumbMetacarpal]  != nil
        let hasMetaR = model.boneNodeMap[lb.rightThumbMetacarpal] != nil
        let lThumb1  = hasMetaL ? lb.leftThumbMetacarpal  : lb.leftThumbProximal
        let lThumb2  = hasMetaL ? lb.leftThumbProximal    : lb.leftThumbIntermediate
        let rThumb1  = hasMetaR ? lb.rightThumbMetacarpal : lb.rightThumbProximal
        let rThumb2  = hasMetaR ? lb.rightThumbProximal   : lb.rightThumbIntermediate

        return [
            seg(hk.thumbCMC,  hk.thumbMP,   lThumb1,                    rThumb1),
            seg(hk.thumbMP,   hk.thumbIP,   lThumb2,                    rThumb2),
            seg(hk.thumbIP,   hk.thumbTip,  lb.leftThumbDistal,         lb.rightThumbDistal),
            seg(hk.indexMCP,  hk.indexPIP,  lb.leftIndexProximal,       lb.rightIndexProximal),
            seg(hk.indexPIP,  hk.indexDIP,  lb.leftIndexIntermediate,   lb.rightIndexIntermediate),
            seg(hk.indexDIP,  hk.indexTip,  lb.leftIndexDistal,         lb.rightIndexDistal),
            seg(hk.middleMCP, hk.middlePIP, lb.leftMiddleProximal,      lb.rightMiddleProximal),
            seg(hk.middlePIP, hk.middleDIP, lb.leftMiddleIntermediate,  lb.rightMiddleIntermediate),
            seg(hk.middleDIP, hk.middleTip, lb.leftMiddleDistal,        lb.rightMiddleDistal),
            seg(hk.ringMCP,   hk.ringPIP,   lb.leftRingProximal,        lb.rightRingProximal),
            seg(hk.ringPIP,   hk.ringDIP,   lb.leftRingIntermediate,    lb.rightRingIntermediate),
            seg(hk.ringDIP,   hk.ringTip,   lb.leftRingDistal,          lb.rightRingDistal),
            seg(hk.littleMCP, hk.littlePIP, lb.leftLittleProximal,      lb.rightLittleProximal),
            seg(hk.littlePIP, hk.littleDIP, lb.leftLittleIntermediate,  lb.rightLittleIntermediate),
            seg(hk.littleDIP, hk.littleTip, lb.leftLittleDistal,        lb.rightLittleDistal),
        ]
    }

    private func applyFingers(hand: HandData, side: Side, scene: SCNScene) {
        // VRM: right hand curl = –Z rotation, left hand = +Z rotation.
        let curlSign: Float = side == .right ? -1 : 1
        // Front-camera mirror: person's right hand appears on image-left → fingers point image-left.
        // Rest direction (fully extended) in image X: right hand → –X image, left hand → +X image.
        let restX: Float = side == .right ? -1 : 1

        for seg in fingerSegments {
            guard let p = hand.joints[seg.parentKey], p.confidence > 0.3,
                  let c = hand.joints[seg.childKey],  c.confidence > 0.3 else { continue }
            let segX = c.x - p.x
            let segY = -(c.y - p.y)          // flip Vision Y (down) to math Y (up)
            let segLen = (segX * segX + segY * segY).squareRoot()
            guard segLen > 0.005 else { continue }

            // 2D curl matching JS reference fingerCurl():
            //   curl = max(0, (1 − cos θ) / 2)  where θ = bend angle from rest (extended = 0).
            //   cos θ = dot(segDir, restDir) = (segX * restX) / segLen  (restDir = (restX, 0))
            let cosTheta = (segX * restX) / segLen
            let curl = max(0, (1 - cosTheta) / 2)   // 0 = straight, 1 = fully reversed

            let boneName = side == .left ? seg.leftBone : seg.rightBone
            guard let node = boneNode(boneName, scene: scene) else { continue }

            let factor: Float = boneName.contains("Distal") ? 0.75 : 0.55
            let rot: simd_quatf
            if boneName.contains("Thumb") {
                rot = simd_quatf(angle:  curl * .pi * factor * 0.6,          axis: SIMD3(1, 0, 0))
                   * simd_quatf(angle: -curlSign * curl * .pi * factor * 0.5, axis: SIMD3(0, 0, 1))
            } else {
                rot = simd_quatf(angle: curlSign * curl * .pi * factor, axis: SIMD3(0, 0, 1))
            }
            node.simdOrientation = restOri(boneName) * rot
        }
    }

    // MARK: - Helpers

    private func boneNode(_ boneName: String, scene: SCNScene) -> SCNNode? {
        guard let nodeName = model.boneNodeMap[boneName] else { return nil }
        return scene.rootNode.childNode(withName: nodeName, recursively: true)
    }

    private func restOri(_ boneName: String) -> simd_quatf {
        guard let nodeName = model.boneNodeMap[boneName] else { return .identity }
        return restOrientations[nodeName] ?? .identity
    }

    private func captureRest(scene: SCNScene) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let name = node.name else { return }
            self.restOrientations[name] = node.simdOrientation
        }
    }
}

// MARK: - Vision joint key strings

private enum Key {
    enum Body {
        static let leftShoulder  = VNHumanBodyPoseObservation.JointName.leftShoulder .rawValue.rawValue
        static let rightShoulder = VNHumanBodyPoseObservation.JointName.rightShoulder.rawValue.rawValue
        static let leftElbow     = VNHumanBodyPoseObservation.JointName.leftElbow    .rawValue.rawValue
        static let rightElbow    = VNHumanBodyPoseObservation.JointName.rightElbow   .rawValue.rawValue
        static let leftWrist     = VNHumanBodyPoseObservation.JointName.leftWrist    .rawValue.rawValue
        static let rightWrist    = VNHumanBodyPoseObservation.JointName.rightWrist   .rawValue.rawValue
    }
    enum Hand {
        static let thumbCMC  = VNHumanHandPoseObservation.JointName.thumbCMC .rawValue.rawValue
        static let thumbMP   = VNHumanHandPoseObservation.JointName.thumbMP  .rawValue.rawValue
        static let thumbIP   = VNHumanHandPoseObservation.JointName.thumbIP  .rawValue.rawValue
        static let thumbTip  = VNHumanHandPoseObservation.JointName.thumbTip .rawValue.rawValue
        static let indexMCP  = VNHumanHandPoseObservation.JointName.indexMCP .rawValue.rawValue
        static let indexPIP  = VNHumanHandPoseObservation.JointName.indexPIP .rawValue.rawValue
        static let indexDIP  = VNHumanHandPoseObservation.JointName.indexDIP .rawValue.rawValue
        static let indexTip  = VNHumanHandPoseObservation.JointName.indexTip .rawValue.rawValue
        static let middleMCP = VNHumanHandPoseObservation.JointName.middleMCP.rawValue.rawValue
        static let middlePIP = VNHumanHandPoseObservation.JointName.middlePIP.rawValue.rawValue
        static let middleDIP = VNHumanHandPoseObservation.JointName.middleDIP.rawValue.rawValue
        static let middleTip = VNHumanHandPoseObservation.JointName.middleTip.rawValue.rawValue
        static let ringMCP   = VNHumanHandPoseObservation.JointName.ringMCP  .rawValue.rawValue
        static let ringPIP   = VNHumanHandPoseObservation.JointName.ringPIP  .rawValue.rawValue
        static let ringDIP   = VNHumanHandPoseObservation.JointName.ringDIP  .rawValue.rawValue
        static let ringTip   = VNHumanHandPoseObservation.JointName.ringTip  .rawValue.rawValue
        static let littleMCP = VNHumanHandPoseObservation.JointName.littleMCP.rawValue.rawValue
        static let littlePIP = VNHumanHandPoseObservation.JointName.littlePIP.rawValue.rawValue
        static let littleDIP = VNHumanHandPoseObservation.JointName.littleDIP.rawValue.rawValue
        static let littleTip = VNHumanHandPoseObservation.JointName.littleTip.rawValue.rawValue
    }
}

// MARK: - simd_quatf helpers

extension simd_quatf {
    static let identity = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

    /// YXZ Euler angles (pitch, yaw, roll) — same decomposition as Three.js 'YXZ' order.
    /// Matches `new THREE.Euler().setFromRotationMatrix(mat, 'YXZ')`.
    var yxzEuler: SIMD3<Float> {
        let m = simd_matrix3x3(self)
        // m.columns are column vectors: columns.j.i = m[i][j]
        let m12 = m.columns.2.y           // row 1 col 2  = –sin(pitch)
        let pitch = asin(-m12.clamped(to: -1...1))
        let yaw, roll: Float
        if abs(m12) < 0.9999 {
            yaw  = atan2( m.columns.2.x, m.columns.2.z)   // m02 / m22
            roll = atan2( m.columns.0.y, m.columns.1.y)   // m10 / m11
        } else {
            yaw  = atan2(-m.columns.0.z,  m.columns.0.x)  // gimbal: –m20 / m00
            roll = 0
        }
        return SIMD3(pitch, yaw, roll)
    }

    /// Build quaternion from YXZ intrinsic Euler angles (Y first, then X, then Z).
    /// Equivalent to Three.js `new Quaternion().setFromEuler(new Euler(x,y,z,'YXZ'))`.
    init(yxzEuler eu: SIMD3<Float>) {
        let qy = simd_quatf(angle: eu.y, axis: SIMD3(0, 1, 0))
        let qx = simd_quatf(angle: eu.x, axis: SIMD3(1, 0, 0))
        let qz = simd_quatf(angle: eu.z, axis: SIMD3(0, 0, 1))
        self = (qy * qx * qz).normalized
    }
}
