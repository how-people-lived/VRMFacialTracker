import SceneKit
import simd

/// Spring bone physics simulator supporting both VRM 0.x (secondaryAnimation) and
/// VRM 1.0 (VRMC_springBone).  Uses Verlet integration per the 1.0 reference algorithm.
///
/// VRM 1.0 update order (from spec):
///   5. Resolve constraints  (not yet implemented)
///   6. Resolve spring bones  ← this class
final class SpringBoneSimulator {

    // MARK: - Internal types

    /// One bone in a spring chain.  Physics params are stored per-segment to support
    /// VRM 1.0 per-joint parameters (0.x replicates group params across all segments).
    private struct Segment {
        weak var node: SCNNode?
        weak var parentNode: SCNNode?
        let boneAxis:        SIMD3<Float>   // rest direction parent→child, local, normalised
        let boneLength:      Float
        let restOrientation: simd_quatf
        var prevTail:        SIMD3<Float>   // world-space tail, previous frame
        var currentTail:     SIMD3<Float>   // world-space tail, current frame
        // Per-segment physics (per-joint in 1.0; shared from group in 0.x)
        let stiffness:    Float
        let drag:         Float
        let gravityPower: Float
        let gravityDir:   SIMD3<Float>
        let hitRadius:    Float
    }

    private struct Chain {
        var segments: [Segment]
        let colliderGroupIndices: [Int]
    }

    private enum ColliderShape {
        case sphere(offset: SIMD3<Float>, radius: Float)
        case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
    }

    private struct Collider {
        weak var node: SCNNode?
        let shape: ColliderShape
    }

    // MARK: - State

    private var chains:         [Chain]      = []
    private var colliders:      [Collider]   = []
    private var colliderGroups: [[Int]]      = []   // group index → [collider index]

    // MARK: - Setup

    func setup(scene: SCNScene, model: VRMModel, nodeNames: [Int: String]) {
        // Build flat collider list
        colliders = model.colliders.map { def -> Collider in
            let scnNode = nodeNames[def.nodeIndex]
                .flatMap { scene.rootNode.childNode(withName: $0, recursively: true) }
            let shape: ColliderShape
            switch def.shape {
            case .sphere(let off, let r):
                shape = .sphere(offset: off, radius: r)
            case .capsule(let off, let r, let tail):
                shape = .capsule(offset: off, radius: r, tail: tail)
            }
            return Collider(node: scnNode, shape: shape)
        }

        // Build collider group index lists
        colliderGroups = model.colliderGroups.map(\.colliderIndices)

        // Build chains
        chains = []
        for springChain in model.springChains {
            if model.version == .v0 {
                buildChainV0(springChain: springChain, scene: scene, nodeNames: nodeNames)
            } else {
                buildChainV1(springChain: springChain, scene: scene, nodeNames: nodeNames)
            }
        }
    }

    // MARK: - VRM 0.x chain build (traverse single-child tree from root)

    private func buildChainV0(springChain: VRMSpringChain, scene: SCNScene, nodeNames: [Int: String]) {
        guard let rootIdx = springChain.nodeIndices.first,
              let rootName = nodeNames[rootIdx],
              let rootNode = scene.rootNode.childNode(withName: rootName, recursively: true),
              let joint = springChain.joints.first else { return }

        let segments = buildSegmentsFromTree(root: rootNode, joint: joint)
        guard !segments.isEmpty else { return }
        chains.append(Chain(segments: segments,
                            colliderGroupIndices: springChain.colliderGroupIndices))
    }

    private func buildSegmentsFromTree(root: SCNNode, joint: VRMSpringJoint) -> [Segment] {
        var result = [Segment]()
        var current: SCNNode? = root
        var parentNode: SCNNode? = root.parent
        while let node = current {
            let wHead = worldPos(node)
            let wTail: SIMD3<Float>
            let boneLen: Float

            if let child = node.childNodes.first {
                wTail   = worldPos(child)
                boneLen = max(simd_length(wTail - wHead), 0.01)
            } else {
                // Terminal node: extend 7 cm in the current bone direction (VRM 0.x convention)
                let pPos = parentNode.map(worldPos) ?? wHead
                let dir  = simd_length(wHead - pPos) > 0.001
                    ? normalize(wHead - pPos) : SIMD3<Float>(0, -1, 0)
                boneLen = 0.07
                wTail   = wHead + dir * boneLen
            }

            let localAxis = computeLocalAxis(parentNode: parentNode, head: wHead, tail: wTail)
            result.append(Segment(node: node, parentNode: parentNode,
                                  boneAxis: localAxis, boneLength: boneLen,
                                  restOrientation: node.simdOrientation,
                                  prevTail: wTail, currentTail: wTail,
                                  stiffness: joint.stiffness, drag: joint.drag,
                                  gravityPower: joint.gravityPower, gravityDir: joint.gravityDir,
                                  hitRadius: joint.hitRadius))
            parentNode = node
            current = node.childNodes.count == 1 ? node.childNodes.first : nil
        }
        return result
    }

    // MARK: - VRM 1.0 chain build (explicit joint node list)

    private func buildChainV1(springChain: VRMSpringChain, scene: SCNScene, nodeNames: [Int: String]) {
        guard springChain.nodeIndices.count >= 2 else { return }

        var segments = [Segment]()
        let nodeObjects = springChain.nodeIndices.compactMap { idx -> SCNNode? in
            guard let name = nodeNames[idx] else { return nil }
            return scene.rootNode.childNode(withName: name, recursively: true)
        }
        guard nodeObjects.count == springChain.nodeIndices.count else { return }

        // In 1.0, joints[i] describes node nodeIndices[i].
        // The terminal joint is the tail tip; it doesn't move itself but defines the tail
        // of the second-to-last segment.
        for i in 0..<(nodeObjects.count - 1) {
            let node   = nodeObjects[i]
            let parent = i == 0 ? node.parent : nodeObjects[i - 1]
            let child  = nodeObjects[i + 1]

            let wHead   = worldPos(node)
            let wTail   = worldPos(child)
            let boneLen = max(simd_length(wTail - wHead), 0.01)
            let axis    = computeLocalAxis(parentNode: parent, head: wHead, tail: wTail)

            // Joint index i corresponds to this node (last joint is the tail tip only)
            let joint = springChain.joints[safe: i] ?? springChain.joints.last ?? defaultJoint
            segments.append(Segment(node: node, parentNode: parent,
                                    boneAxis: axis, boneLength: boneLen,
                                    restOrientation: node.simdOrientation,
                                    prevTail: wTail, currentTail: wTail,
                                    stiffness: joint.stiffness, drag: joint.drag,
                                    gravityPower: joint.gravityPower, gravityDir: joint.gravityDir,
                                    hitRadius: joint.hitRadius))
        }
        guard !segments.isEmpty else { return }
        chains.append(Chain(segments: segments,
                            colliderGroupIndices: springChain.colliderGroupIndices))
    }

    private let defaultJoint = VRMSpringJoint(stiffness: 1, drag: 0.4,
                                              gravityPower: 0, gravityDir: SIMD3(0,-1,0),
                                              hitRadius: 0.02)

    // MARK: - Per-frame update

    func update(deltaTime: Float) {
        let dt = min(deltaTime, 1.0 / 30.0)
        for i in chains.indices {
            for j in chains[i].segments.indices {
                updateSegment(&chains[i].segments[j], colliderGroupIndices: chains[i].colliderGroupIndices, dt: dt)
            }
        }
    }

    // MARK: - Verlet step  (VRM 1.0 spec reference algorithm)

    private func updateSegment(_ seg: inout Segment, colliderGroupIndices: [Int], dt: Float) {
        guard let node = seg.node else { return }
        let parentPos = seg.parentNode.map(worldPos) ?? worldPos(node)

        let parentMat = seg.parentNode.map(\.simdWorldTransform) ?? node.simdWorldTransform

        // 1. Inertia
        let velocity = (seg.currentTail - seg.prevTail) * (1.0 - seg.drag)
        // 2. Stiffness: constant-direction force toward rest bone axis in world space (VRM spec).
        //    boneAxis is in parent-local space; multiply by parent world matrix (w=0 for direction)
        //    then normalise to remove any scale factor. Scale is uniform-positive per VRM spec.
        let rawAxis = (parentMat * SIMD4(seg.boneAxis, 0)).xyz
        let stiffForce = (simd_length(rawAxis) > 0.001 ? simd_normalize(rawAxis) : SIMD3<Float>(0, -1, 0))
                         * seg.stiffness * dt
        // 3. External (gravity)
        let gravForce = seg.gravityPower * seg.gravityDir * dt

        var next = seg.currentTail + velocity + stiffForce + gravForce

        // 4. Constrain to bone length
        next = clampToBoneLength(next, from: parentPos, length: seg.boneLength)

        // 5. Collision
        for cgIdx in colliderGroupIndices where cgIdx < colliderGroups.count {
            for ci in colliderGroups[cgIdx] where ci < colliders.count {
                next = resolveCollision(tail: next, parentPos: parentPos,
                                        boneLength: seg.boneLength,
                                        hitRadius: seg.hitRadius,
                                        collider: colliders[ci])
            }
        }
        next = clampToBoneLength(next, from: parentPos, length: seg.boneLength)

        // 6. Apply rotation.
        //    Per VRM spec: rotation delta must be computed in bone-local space.
        //    boneAxis is in parent-local space; transform both vectors to bone-local space
        //    by multiplying by the inverse rest orientation before calling fromTo.
        //    Reference: VRMC_springBone spec §5 + UniVRM VRMSpringBoneLogic.cs.
        let parentWorldInv  = simd_inverse(parentMat)
        let headInParent    = (parentWorldInv * SIMD4(worldPos(node), 1)).xyz
        let nextInParent    = (parentWorldInv * SIMD4(next, 1)).xyz
        let nextDirInParent = nextInParent - headInParent
        if simd_length(nextDirInParent) > 0.001 {
            // Convert from parent-local → bone-local so the fromTo rotation is in the
            // correct space.  When restOrientation == identity this is a no-op.
            let invRest = seg.restOrientation.inverse
            let from = normalize(simd_act(invRest, seg.boneAxis))
            let to   = normalize(simd_act(invRest, nextDirInParent))
            let d = simd_clamp(simd_dot(from, to), -1.0, 1.0)
            if abs(d) < 0.9999 {
                node.simdOrientation = seg.restOrientation * simd_quatf(from: from, to: to)
            }
        }

        seg.prevTail    = seg.currentTail
        seg.currentTail = next
    }

    // MARK: - Collision resolution

    private func resolveCollision(tail: SIMD3<Float>, parentPos: SIMD3<Float>,
                                  boneLength: Float, hitRadius: Float,
                                  collider: Collider) -> SIMD3<Float> {
        guard let cn = collider.node else { return tail }
        let mat = cn.simdWorldTransform

        switch collider.shape {
        case .sphere(let off, let r):
            let centre = (mat * SIMD4(off, 1)).xyz
            return pushOut(tail: tail, parentPos: parentPos, boneLength: boneLength,
                           centre: centre, combinedRadius: hitRadius + r)

        case .capsule(let off, let r, let tailOff):
            // Push out from nearest point on the capsule segment
            let a = (mat * SIMD4(off, 1)).xyz
            let b = (mat * SIMD4(tailOff, 1)).xyz
            let ab = b - a
            let abLen = simd_length(ab)
            let centre: SIMD3<Float>
            if abLen < 0.0001 {
                centre = a
            } else {
                let t = simd_clamp(simd_dot(tail - a, ab) / (abLen * abLen), 0, 1)
                centre = a + ab * t
            }
            return pushOut(tail: tail, parentPos: parentPos, boneLength: boneLength,
                           centre: centre, combinedRadius: hitRadius + r)
        }
    }

    private func pushOut(tail: SIMD3<Float>, parentPos: SIMD3<Float>, boneLength: Float,
                         centre: SIMD3<Float>, combinedRadius: Float) -> SIMD3<Float> {
        let d    = tail - centre
        let dist = simd_length(d)
        guard dist < combinedRadius, dist > 0.0001 else { return tail }
        let pushed = centre + d / dist * combinedRadius
        return clampToBoneLength(pushed, from: parentPos, length: boneLength)
    }

    // MARK: - Helpers

    private func clampToBoneLength(_ p: SIMD3<Float>, from origin: SIMD3<Float>, length: Float) -> SIMD3<Float> {
        let d = p - origin
        let l = simd_length(d)
        return l > 0.001 ? origin + d / l * length : p
    }

    private func computeLocalAxis(parentNode: SCNNode?, head: SIMD3<Float>, tail: SIMD3<Float>) -> SIMD3<Float> {
        guard let p = parentNode else { return SIMD3(0, -1, 0) }
        let inv = simd_inverse(p.simdWorldTransform)
        let lh = (inv * SIMD4(head, 1)).xyz
        let lt = (inv * SIMD4(tail, 1)).xyz
        let d  = lt - lh
        return simd_length(d) > 0.001 ? normalize(d) : SIMD3(0, -1, 0)
    }

    private func worldPos(_ node: SCNNode) -> SIMD3<Float> { node.simdWorldPosition }
}

// MARK: - SIMD helpers

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

private extension simd_float4x4 {
    init(_ m: SCNMatrix4) {
        self.init(columns: (
            SIMD4<Float>(Float(m.m11), Float(m.m12), Float(m.m13), Float(m.m14)),
            SIMD4<Float>(Float(m.m21), Float(m.m22), Float(m.m23), Float(m.m24)),
            SIMD4<Float>(Float(m.m31), Float(m.m32), Float(m.m33), Float(m.m34)),
            SIMD4<Float>(Float(m.m41), Float(m.m42), Float(m.m43), Float(m.m44))
        ))
    }
}
