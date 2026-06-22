import Foundation

// MARK: - Top-level frame sent from iPhone to Mac at ~60fps

struct TrackingFrame: Codable {
    let timestamp:  Double
    let face:       FaceData?
    let leftHand:   HandData?
    let rightHand:  HandData?
    let body:       BodyData?       // Vision 2D body pose (legacy; kept for compatibility)
    let body3D:     Body3DData?     // Vision 3D body pose (iOS 17+) — drives accurate arms

    func encoded()     -> Data? { try? PropertyListEncoder().encode(self) }
    func jsonEncoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(from data: Data) -> TrackingFrame? {
        try? PropertyListDecoder().decode(TrackingFrame.self, from: data)
    }
}

// MARK: - Face (ARKit TrueDepth, 52 blend shapes + 6DoF head)

struct FaceData: Codable {
    let blendShapes:  [String: Float]   // ARKit blend shape coefficient name → 0–1
    let headPosition: SIMD3Float
    let headRotation: SIMDQuatFloat
}

// MARK: - Hand (Vision, 21 joints per hand)

struct HandData: Codable {
    let joints: [String: JointPoint]    // joint name → normalised image-space point
}

// MARK: - Body (Vision, upper-body joints — 2D normalised image space, legacy)

struct BodyData: Codable {
    let joints: [String: JointPoint]
}

// MARK: - Body3D (Vision VNDetectHumanBodyPose3DRequest, iOS 17+)
//
// Joint positions are in Vision's 3D model space (metres), relative to the body root.
// Only the joints we need for arm rotation are transmitted; nil = not detected this frame.
// The Mac/Unity side reconstructs full-3DoF arm rotations from the direction vectors
// shoulder→elbow and elbow→wrist, which (unlike 2D) preserve depth and twist.

struct Body3DData: Codable {
    let leftShoulder:  SIMD3Float?
    let leftElbow:     SIMD3Float?
    let leftWrist:     SIMD3Float?
    let rightShoulder: SIMD3Float?
    let rightElbow:    SIMD3Float?
    let rightWrist:    SIMD3Float?
    let root:          SIMD3Float?   // pelvis / hip centre
    let spine:         SIMD3Float?
}

struct JointPoint: Codable {
    let x, y:      Float
    let confidence: Float
}

// MARK: - Codable wrappers for SIMD types (not Codable by default)

struct SIMD3Float: Codable {
    let x, y, z: Float
    init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    static let zero = SIMD3Float(0, 0, 0)
}

struct SIMDQuatFloat: Codable {
    let x, y, z, w: Float
    init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    static let identity = SIMDQuatFloat(0, 0, 0, 1)
}
