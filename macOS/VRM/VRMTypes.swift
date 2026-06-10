import Foundation
import SceneKit
import simd

// MARK: - Version

enum VRMVersion { case v0, v1 }

// MARK: - VRM 0.x raw decode types

struct V0Meta: Decodable {
    let title: String?
    let author: String?
    let version: String?
}

struct V0HumanBone: Decodable {
    let bone: String
    let node: Int
}

struct V0Humanoid: Decodable {
    let humanBones: [V0HumanBone]
}

struct V0BlendShapeBind: Decodable {
    let mesh: Int
    let index: Int
    let weight: Float  // 0–100 in VRM 0.x spec
}

struct V0BlendShapeGroup: Decodable {
    let name: String
    let presetName: String?
    let binds: [V0BlendShapeBind]
    let isBinary: Bool?
}

struct V0BlendShapeMaster: Decodable {
    let blendShapeGroups: [V0BlendShapeGroup]
}

struct V0Material: Decodable {
    let name: String?
    let shader: String?
    let renderQueue: Int?
    let floatProperties: [String: Float]?
    let vectorProperties: [String: [Float]]?
    let textureProperties: [String: Int]?
    let keywordMap: [String: Bool]?
    let tagMap: [String: String]?
}

struct V0Vec3: Decodable {
    let x, y, z: Float
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}

struct V0Collider: Decodable {
    let offset: V0Vec3
    let radius: Float
}

struct V0ColliderGroup: Decodable {
    let node: Int
    let colliders: [V0Collider]
}

struct V0SpringGroup: Decodable {
    let comment: String?
    let stiffiness: Float?   // spec typo preserved
    let gravityPower: Float?
    let gravityDir: V0Vec3?
    let dragForce: Float?
    let center: Int?
    let hitRadius: Float?
    let bones: [Int]
    let colliderGroups: [Int]?
}

struct V0SecondaryAnimation: Decodable {
    let boneGroups: [V0SpringGroup]?
    let colliderGroups: [V0ColliderGroup]?
}

struct V0Root: Decodable {
    let meta: V0Meta?
    let humanoid: V0Humanoid?
    let blendShapeMaster: V0BlendShapeMaster?
    let materialProperties: [V0Material]?
    let secondaryAnimation: V0SecondaryAnimation?
}

// MARK: - VRM 1.0 raw decode types  (extensions.VRMC_vrm)

struct V1Meta: Decodable {
    let name: String?
    let authors: [String]?
    let version: String?
}

struct V1HumanBoneRef: Decodable {
    let node: Int
}

struct V1Humanoid: Decodable {
    // keyed object { "hips": {"node": 1}, ... } per VRMC_vrm-1.0 spec
    let humanBones: [String: V1HumanBoneRef]
}

struct V1MorphBind: Decodable {
    let node: Int
    let index: Int
    let weight: Float  // 0–1 in VRM 1.0 spec
}

struct V1MaterialColorBind: Decodable {
    let material: Int
    let type: String
    let targetValue: [Float]
}

struct V1TextureTransformBind: Decodable {
    let material: Int
    let scale: [Float]?
    let offset: [Float]?
}

struct V1Expression: Decodable {
    let isBinary: Bool?
    let morphTargetBinds: [V1MorphBind]?
    let materialColorBinds: [V1MaterialColorBind]?
    let textureTransformBinds: [V1TextureTransformBind]?
    let overrideMouth: String?    // "none" | "block" | "blend"
    let overrideBlink: String?
    let overrideLookAt: String?
}

struct V1Expressions: Decodable {
    let preset: [String: V1Expression]?
    let custom: [String: V1Expression]?
}

struct V1Root: Decodable {
    let specVersion: String?
    let meta: V1Meta?
    let humanoid: V1Humanoid?
    let expressions: V1Expressions?
}

// MARK: - VRM 1.0 spring bone (VRMC_springBone separate extension)

struct V1SBColliderSphere: Decodable {
    let offset: [Float]?
    let radius: Float?
}

struct V1SBColliderCapsule: Decodable {
    let offset: [Float]?
    let radius: Float?
    let tail: [Float]?
}

struct V1SBColliderShape: Decodable {
    let sphere: V1SBColliderSphere?
    let capsule: V1SBColliderCapsule?
}

struct V1SBCollider: Decodable {
    let node: Int
    let shape: V1SBColliderShape
}

struct V1SBColliderGroup: Decodable {
    let name: String?
    let colliders: [Int]  // indices into VRMC_springBone.colliders[]
}

struct V1SBJoint: Decodable {
    let node: Int
    let hitRadius: Float?
    let stiffness: Float?    // corrected spelling in 1.0 (was "stiffiness" in 0.x)
    let gravityPower: Float?
    let gravityDir: [Float]?
    let dragForce: Float?
}

struct V1SBSpring: Decodable {
    let name: String?
    let center: Int?
    let joints: [V1SBJoint]
    let colliderGroups: [Int]?  // indices into VRMC_springBone.colliderGroups[]
}

struct V1SpringBoneRoot: Decodable {
    let specVersion: String?
    let colliders: [V1SBCollider]?
    let colliderGroups: [V1SBColliderGroup]?
    let springs: [V1SBSpring]?
}

// MARK: - Unified runtime types

/// Expression with weights normalised to 0–1 regardless of source version.
struct VRMExpression {
    enum OverrideMode {
        case none, block, blend
        init(_ raw: String?) {
            switch raw { case "block": self = .block; case "blend": self = .blend; default: self = .none }
        }
    }

    struct MorphBind {
        let meshIndex: Int
        let morphIndex: Int
        let weight: Float  // 0–1
    }

    let name: String
    let binds: [MorphBind]
    let isBinary: Bool
    let overrideMouth: OverrideMode
    let overrideBlink: OverrideMode
    let overrideLookAt: OverrideMode
}

enum VRMColliderShape {
    case sphere(offset: SIMD3<Float>, radius: Float)
    case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
}

struct VRMColliderDef {
    let nodeIndex: Int
    let shape: VRMColliderShape
}

struct VRMColliderGroup {
    let colliderIndices: [Int]  // indices into VRMModel.colliders[]
}

struct VRMSpringJoint {
    let stiffness: Float
    let drag: Float
    let gravityPower: Float
    let gravityDir: SIMD3<Float>
    let hitRadius: Float
}

struct VRMSpringChain {
    /// 0.x: single-element [rootNodeIndex]; SpringBoneSimulator traverses children.
    /// 1.0: all joint node indices in order from the spec.
    let nodeIndices: [Int]
    /// 0.x: one entry shared across all segments. 1.0: one entry per node in nodeIndices.
    let joints: [VRMSpringJoint]
    let colliderGroupIndices: [Int]
}

struct VRMModel {
    let version: VRMVersion
    /// VRM humanoid bone name → glTF node name
    let boneNodeMap: [String: String]
    /// glTF node name → VRM humanoid bone name
    let humanBoneMap: [String: String]
    /// Expression name (1.0-normalised, lowercase key) → VRMExpression
    let expressions: [String: VRMExpression]
    /// glTF node name → mesh index (for morph-target binding)
    let nodeMeshMap: [String: Int]
    /// VRM 0.x MToon material properties (empty for 1.0; handled per-material in glTF)
    let materialProperties: [V0Material]
    let springChains: [VRMSpringChain]
    let colliders: [VRMColliderDef]
    let colliderGroups: [VRMColliderGroup]
}

// MARK: - Preset name constants  (VRM 1.0 naming used throughout the runtime)

enum VRMPreset {
    // Emotions
    static let neutral   = "neutral"
    static let happy     = "happy"
    static let angry     = "angry"
    static let sad       = "sad"
    static let relaxed   = "relaxed"
    static let surprised = "surprised"
    // Lip sync
    static let aa = "aa"; static let ih = "ih"; static let ou = "ou"
    static let ee = "ee"; static let oh = "oh"
    // Blink
    static let blink      = "blink"
    static let blinkLeft  = "blinkLeft"
    static let blinkRight = "blinkRight"
    // LookAt
    static let lookUp    = "lookUp"
    static let lookDown  = "lookDown"
    static let lookLeft  = "lookLeft"
    static let lookRight = "lookRight"
}

// 0.x preset name → 1.0 normalised name
let vrm0To1PresetMap: [String: String] = [
    "joy": "happy",   "sorrow": "sad",  "fun": "relaxed",
    "a": "aa",        "i": "ih",        "u": "ou",   "e": "ee",   "o": "oh",
    "blink_l": "blinkLeft",  "blink_r": "blinkRight",
    "lookup": "lookUp",   "lookdown": "lookDown",
    "lookleft": "lookLeft",  "lookright": "lookRight",
]

// MARK: - Bone name constants  (VRM 1.0; 0.x names are identical except thumb)

enum VRMBone {
    static let hips          = "hips"
    static let spine         = "spine"
    static let chest         = "chest"
    static let upperChest    = "upperChest"
    static let neck          = "neck"
    static let head          = "head"
    static let leftEye       = "leftEye"
    static let rightEye      = "rightEye"
    static let jaw           = "jaw"
    static let leftShoulder  = "leftShoulder"
    static let leftUpperArm  = "leftUpperArm"
    static let leftLowerArm  = "leftLowerArm"
    static let leftHand      = "leftHand"
    static let rightShoulder = "rightShoulder"
    static let rightUpperArm = "rightUpperArm"
    static let rightLowerArm = "rightLowerArm"
    static let rightHand     = "rightHand"
    static let leftUpperLeg  = "leftUpperLeg"
    static let leftLowerLeg  = "leftLowerLeg"
    static let leftFoot      = "leftFoot"
    static let leftToes      = "leftToes"
    static let rightUpperLeg = "rightUpperLeg"
    static let rightLowerLeg = "rightLowerLeg"
    static let rightFoot     = "rightFoot"
    static let rightToes     = "rightToes"

    // Fingers – left
    // VRM 1.0: Metacarpal → Proximal → Distal
    // VRM 0.x: Proximal → Intermediate → Distal  (no Metacarpal)
    static let leftThumbMetacarpal    = "leftThumbMetacarpal"
    static let leftThumbProximal      = "leftThumbProximal"
    static let leftThumbIntermediate  = "leftThumbIntermediate"  // 0.x only
    static let leftThumbDistal        = "leftThumbDistal"
    static let leftIndexProximal      = "leftIndexProximal"
    static let leftIndexIntermediate  = "leftIndexIntermediate"
    static let leftIndexDistal        = "leftIndexDistal"
    static let leftMiddleProximal     = "leftMiddleProximal"
    static let leftMiddleIntermediate = "leftMiddleIntermediate"
    static let leftMiddleDistal       = "leftMiddleDistal"
    static let leftRingProximal       = "leftRingProximal"
    static let leftRingIntermediate   = "leftRingIntermediate"
    static let leftRingDistal         = "leftRingDistal"
    static let leftLittleProximal     = "leftLittleProximal"
    static let leftLittleIntermediate = "leftLittleIntermediate"
    static let leftLittleDistal       = "leftLittleDistal"

    // Fingers – right
    static let rightThumbMetacarpal    = "rightThumbMetacarpal"
    static let rightThumbProximal      = "rightThumbProximal"
    static let rightThumbIntermediate  = "rightThumbIntermediate"  // 0.x only
    static let rightThumbDistal        = "rightThumbDistal"
    static let rightIndexProximal      = "rightIndexProximal"
    static let rightIndexIntermediate  = "rightIndexIntermediate"
    static let rightIndexDistal        = "rightIndexDistal"
    static let rightMiddleProximal     = "rightMiddleProximal"
    static let rightMiddleIntermediate = "rightMiddleIntermediate"
    static let rightMiddleDistal       = "rightMiddleDistal"
    static let rightRingProximal       = "rightRingProximal"
    static let rightRingIntermediate   = "rightRingIntermediate"
    static let rightRingDistal         = "rightRingDistal"
    static let rightLittleProximal     = "rightLittleProximal"
    static let rightLittleIntermediate = "rightLittleIntermediate"
    static let rightLittleDistal       = "rightLittleDistal"
}

// MARK: - Utility

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
