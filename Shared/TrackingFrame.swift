import Foundation

// MARK: - Top-level frame sent from iPhone to Mac at ~60fps

struct TrackingFrame: Codable {
    let timestamp:  Double
    let face:       FaceData?
    let leftHand:   HandData?
    let rightHand:  HandData?
    let body:       BodyData?

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

// MARK: - Body (Vision, upper-body joints)

struct BodyData: Codable {
    let joints: [String: JointPoint]
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
