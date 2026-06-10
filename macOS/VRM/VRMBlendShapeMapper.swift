import SceneKit

/// Maps ARKit/MediaPipe 52 blend-shape coefficients to VRM expression weights.
/// Mapping table matches the mediapipe-vrm-tracking reference implementation exactly.
final class VRMBlendShapeMapper {

    private weak var scene: SCNScene?
    private let model: VRMModel
    private var morpherCache = [String: [SCNNode]]()

    // (arkitShape, vrmExpression, scale) — multiple rows may share the same target (additive).
    private static let mapping: [(String, String, Float)] = [
        // Blink / eye-wide / squint
        ("eyeBlinkLeft",        "blinkLeft",   1.0),
        ("eyeBlinkRight",       "blinkRight",  1.0),
        ("eyeWideLeft",         "surprised",   0.4),
        ("eyeWideRight",        "surprised",   0.4),
        ("eyeSquintLeft",       "relaxed",     0.4),
        ("eyeSquintRight",      "relaxed",     0.4),
        // LookAt (ARKit In/Out naming is eye-relative; convert to character-relative)
        ("eyeLookUpLeft",       "lookUp",      0.8),
        ("eyeLookUpRight",      "lookUp",      0.8),
        ("eyeLookDownLeft",     "lookDown",    0.8),
        ("eyeLookDownRight",    "lookDown",    0.8),
        ("eyeLookInLeft",       "lookRight",   0.7),   // left eye looking in = gaze right
        ("eyeLookOutRight",     "lookRight",   0.7),
        ("eyeLookOutLeft",      "lookLeft",    0.7),
        ("eyeLookInRight",      "lookLeft",    0.7),
        // Brow
        ("browInnerUp",         "surprised",   0.7),
        ("browDownLeft",        "angry",       0.5),
        ("browDownRight",       "angry",       0.5),
        ("browOuterUpLeft",     "surprised",   0.3),
        ("browOuterUpRight",    "surprised",   0.3),
        // Jaw / mouth primary
        ("jawOpen",             "aa",          1.0),
        ("mouthFunnel",         "oh",          0.7),
        ("mouthPucker",         "ou",          0.9),
        ("mouthSmileLeft",      "happy",       0.6),
        ("mouthSmileRight",     "happy",       0.6),
        ("mouthFrownLeft",      "sad",         0.6),
        ("mouthFrownRight",     "sad",         0.6),
        ("mouthDimpleLeft",     "happy",       0.2),
        ("mouthDimpleRight",    "happy",       0.2),
        // Mouth detail
        ("mouthLowerDownLeft",  "aa",          0.3),
        ("mouthLowerDownRight", "aa",          0.3),
        ("mouthUpperUpLeft",    "ih",          0.3),
        ("mouthUpperUpRight",   "ih",          0.3),
        ("mouthStretchLeft",    "ih",          0.25),
        ("mouthStretchRight",   "ih",          0.25),
        ("mouthPressLeft",      "relaxed",     0.2),
        ("mouthPressRight",     "relaxed",     0.2),
        ("mouthRollLower",      "oh",          0.3),
        ("mouthRollUpper",      "ou",          0.3),
        ("mouthShrugLower",     "sad",         0.25),
        ("mouthShrugUpper",     "surprised",   0.2),
        // Cheek / nose
        ("cheekPuff",           "surprised",   0.35),
        ("cheekSquintLeft",     "happy",       0.25),
        ("cheekSquintRight",    "happy",       0.25),
        ("noseSneerLeft",       "angry",       0.3),
        ("noseSneerRight",      "angry",       0.3),
    ]

    init(scene: SCNScene, model: VRMModel) {
        self.scene = scene
        self.model = model
        buildCache(scene: scene)
    }

    // MARK: - Public

    func apply(faceData: FaceData) {
        let bs = faceData.blendShapes

        // 1. Accumulate (additive, clamped to [0,1])
        var weights = [String: Float]()
        for (shape, target, scale) in Self.mapping {
            let v = (bs[shape] ?? 0).clamped(to: 0...1)
            weights[target] = min(1, (weights[target] ?? 0) + v * scale)
        }

        // 2. Override system (VRM 1.0): block zeroes; blend scales by (1 – saturate(sum))
        let blinkKeys  = [VRMPreset.blink, VRMPreset.blinkLeft, VRMPreset.blinkRight]
        let mouthKeys  = [VRMPreset.aa, VRMPreset.ih, VRMPreset.ou, VRMPreset.ee, VRMPreset.oh]
        let lookAtKeys = [VRMPreset.lookUp, VRMPreset.lookDown, VRMPreset.lookLeft, VRMPreset.lookRight]

        var blinkBlock = false, mouthBlock = false, lookAtBlock = false
        var blinkBlend: Float = 0, mouthBlend: Float = 0, lookAtBlend: Float = 0

        for (key, w) in weights where w > 0 {
            guard let expr = model.expressions[key.lowercased()] else { continue }
            let ew = expr.isBinary ? (w >= 0.5 ? Float(1) : Float(0)) : w
            guard ew > 0 else { continue }
            switch expr.overrideBlink  { case .block: blinkBlock  = true; case .blend: blinkBlend  += ew; case .none: break }
            switch expr.overrideMouth  { case .block: mouthBlock  = true; case .blend: mouthBlend  += ew; case .none: break }
            switch expr.overrideLookAt { case .block: lookAtBlock = true; case .blend: lookAtBlend += ew; case .none: break }
        }

        func applyFactor(_ keys: [String], block: Bool, blend: Float) {
            let factor: Float = block ? 0 : max(1 - blend, 0)
            guard factor < 1 else { return }
            for key in keys { if let w = weights[key] { weights[key] = w * factor } }
        }
        applyFactor(blinkKeys,  block: blinkBlock,  blend: blinkBlend)
        applyFactor(mouthKeys,  block: mouthBlock,  blend: mouthBlend)
        applyFactor(lookAtKeys, block: lookAtBlock, blend: lookAtBlend)

        // 3. Write morph targets
        for (key, w) in weights { setExpression(key, weight: w) }
    }

    // MARK: - Private

    private func setExpression(_ name: String, weight: Float) {
        guard let expr = model.expressions[name.lowercased()] else { return }
        let w = expr.isBinary ? (weight > 0.5 ? Float(1) : Float(0)) : weight
        for bind in expr.binds {
            let nodes = morpherCache["mesh_\(bind.meshIndex)"] ?? []
            for node in nodes {
                guard let morpher = node.morpher,
                      bind.morphIndex < morpher.targets.count else { continue }
                morpher.setWeight(CGFloat(w * bind.weight), forTargetAt: bind.morphIndex)
            }
        }
    }

    private func buildCache(scene: SCNScene) {
        for (nodeName, meshIdx) in model.nodeMeshMap {
            guard let node = scene.rootNode.childNode(withName: nodeName, recursively: true)
            else { continue }
            collectMorphers(under: node, into: &morpherCache["mesh_\(meshIdx)", default: []])
        }
        // Fallback: any morpher not yet indexed
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let m = node.morpher, !m.targets.isEmpty else { return }
            let indexed = self.morpherCache.values.contains { $0.contains { $0 === node } }
            guard !indexed else { return }
            var n: SCNNode? = node
            while let candidate = n {
                if let name = candidate.name, let mi = self.model.nodeMeshMap[name] {
                    self.morpherCache["mesh_\(mi)", default: []].append(node); return
                }
                n = candidate.parent
            }
        }
    }

    private func collectMorphers(under node: SCNNode, into list: inout [SCNNode]) {
        if let m = node.morpher, !m.targets.isEmpty { list.append(node) }
        node.enumerateChildNodes { child, _ in
            if let m = child.morpher, !m.targets.isEmpty { list.append(child) }
        }
    }
}
