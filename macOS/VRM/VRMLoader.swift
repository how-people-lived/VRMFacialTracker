import Foundation
import SceneKit
import GLTFKit2

/// Loads a .vrm file and produces a unified VRMModel that works for both VRM 0.x and 1.0.
final class VRMLoader {

    struct LoadResult {
        let scene: SCNScene
        let model: VRMModel
        /// glTF node index → node name, used by SpringBoneSimulator to resolve SCNNodes
        let nodeNames: [Int: String]
    }

    enum VRMError: Error {
        case invalidFile
        case missingVRMExtension
        case sceneConversionFailed
    }

    // MARK: - Public

    static func load(url: URL) throws -> LoadResult {
        let rawData = try Data(contentsOf: url)
        let json    = try extractJSON(from: rawData)

        let nodeNames   = buildNodeNameMap(json: json)
        let nodeMeshMap = buildNodeMeshMap(json: json)

        let extensions = json["extensions"] as? [String: Any] ?? [:]
        let version: VRMVersion = extensions["VRMC_vrm"] != nil ? .v1 : .v0

        let model: VRMModel
        switch version {
        case .v0:
            model = try buildModelV0(json: json, nodeNames: nodeNames, nodeMeshMap: nodeMeshMap)
        case .v1:
            model = try buildModelV1(json: json, nodeNames: nodeNames, nodeMeshMap: nodeMeshMap)
        }

        let asset = try GLTFAsset(url: url)
        guard let scene = GLTFSCNSceneSource(asset: asset).defaultScene else {
            throw VRMError.sceneConversionFailed
        }

        switch version {
        case .v0: applyMToon(scene: scene, materials: model.materialProperties)
        case .v1: applyMToonV1(scene: scene, json: json)
        }

        return LoadResult(scene: scene, model: model, nodeNames: nodeNames)
    }

    // MARK: - Binary glTF (GLB) JSON extraction

    /// GLB: 12-byte file header + chunks [length(4) + type(4) + data].
    /// First chunk is always JSON (type 0x4E4F534A).
    private static func extractJSON(from data: Data) throws -> [String: Any] {
        guard data.count > 20,
              data.subdata(in: 0..<4) == Data([0x67, 0x6C, 0x54, 0x46]) else {
            throw VRMError.invalidFile
        }
        let chunkLength = data.subdata(in: 12..<16).withUnsafeBytes {
            CFSwapInt32LittleToHost($0.load(as: UInt32.self))
        }
        let chunkType = data.subdata(in: 16..<20).withUnsafeBytes {
            CFSwapInt32LittleToHost($0.load(as: UInt32.self))
        }
        guard chunkType == 0x4E4F534A else { throw VRMError.invalidFile }
        let end = 20 + Int(chunkLength)
        guard data.count >= end else { throw VRMError.invalidFile }
        guard let json = try? JSONSerialization.jsonObject(
            with: data.subdata(in: 20..<end)) as? [String: Any] else {
            throw VRMError.invalidFile
        }
        return json
    }

    // MARK: - glTF node maps

    private static func buildNodeNameMap(json: [String: Any]) -> [Int: String] {
        (json["nodes"] as? [[String: Any]] ?? []).enumerated().reduce(into: [:]) { acc, pair in
            if let name = pair.element["name"] as? String { acc[pair.offset] = name }
        }
    }

    private static func buildNodeMeshMap(json: [String: Any]) -> [String: Int] {
        (json["nodes"] as? [[String: Any]] ?? []).reduce(into: [:]) { acc, node in
            if let mesh = node["mesh"] as? Int, let name = node["name"] as? String {
                acc[name] = mesh
            }
        }
    }

    // MARK: - VRM 0.x build

    private static func buildModelV0(json: [String: Any],
                                     nodeNames: [Int: String],
                                     nodeMeshMap: [String: Int]) throws -> VRMModel {
        guard let extensions = json["extensions"] as? [String: Any],
              let vrmRaw = extensions["VRM"] else { throw VRMError.missingVRMExtension }

        let data = try JSONSerialization.data(withJSONObject: vrmRaw)
        let root = try JSONDecoder().decode(V0Root.self, from: data)

        // Humanoid
        var boneNodeMap  = [String: String]()
        var humanBoneMap = [String: String]()
        for bone in root.humanoid?.humanBones ?? [] {
            if let name = nodeNames[bone.node] {
                boneNodeMap[bone.bone] = name
                humanBoneMap[name]     = bone.bone
            }
        }

        // Expressions: normalise preset names to VRM 1.0, weights from [0,100] to [0,1]
        var expressions = [String: VRMExpression]()
        for group in root.blendShapeMaster?.blendShapeGroups ?? [] {
            let rawKey  = group.presetName?.lowercased() ?? ""
            let key     = (rawKey == "unknown" || rawKey.isEmpty
                ? group.name.lowercased()
                : (vrm0To1PresetMap[rawKey] ?? rawKey)).lowercased()
            let binds = group.binds.map {
                VRMExpression.MorphBind(meshIndex: $0.mesh,
                                       morphIndex: $0.index,
                                       weight: ($0.weight / 100.0).clamped(to: 0...1))
            }
            expressions[key] = VRMExpression(name: key, binds: binds,
                                             isBinary: group.isBinary ?? false,
                                             overrideMouth: .none,
                                             overrideBlink: .none,
                                             overrideLookAt: .none)
        }

        // Spring bone
        let v0ColliderGroups = root.secondaryAnimation?.colliderGroups ?? []
        // Flatten V0ColliderGroups into a linear colliders[] + colliderGroups[]
        var colliders      = [VRMColliderDef]()
        var colliderGroups = [VRMColliderGroup]()
        for cg in v0ColliderGroups {
            let start = colliders.count
            for c in cg.colliders {
                // VRM left-handed → right-handed: negate X
                let off = SIMD3<Float>(-c.offset.x, c.offset.y, c.offset.z)
                colliders.append(VRMColliderDef(nodeIndex: cg.node,
                                               shape: .sphere(offset: off, radius: c.radius)))
            }
            colliderGroups.append(VRMColliderGroup(colliderIndices: Array(start..<colliders.count)))
        }

        var springChains = [VRMSpringChain]()
        for g in root.secondaryAnimation?.boneGroups ?? [] {
            let joint = VRMSpringJoint(
                stiffness:    g.stiffiness  ?? 1.0,
                drag:         g.dragForce   ?? 0.4,
                gravityPower: g.gravityPower ?? 0.0,
                gravityDir:   gravDir0(g.gravityDir),
                hitRadius:    g.hitRadius   ?? 0.02
            )
            for rootIdx in g.bones {
                springChains.append(VRMSpringChain(
                    nodeIndices:          [rootIdx],
                    joints:               [joint],
                    colliderGroupIndices: g.colliderGroups ?? []
                ))
            }
        }

        return VRMModel(version: .v0,
                        boneNodeMap: boneNodeMap, humanBoneMap: humanBoneMap,
                        expressions: expressions, nodeMeshMap: nodeMeshMap,
                        materialProperties: root.materialProperties ?? [],
                        springChains: springChains,
                        colliders: colliders, colliderGroups: colliderGroups)
    }

    // MARK: - VRM 1.0 build

    private static func buildModelV1(json: [String: Any],
                                     nodeNames: [Int: String],
                                     nodeMeshMap: [String: Int]) throws -> VRMModel {
        guard let extensions = json["extensions"] as? [String: Any],
              let vrmRaw = extensions["VRMC_vrm"] else { throw VRMError.missingVRMExtension }

        let data = try JSONSerialization.data(withJSONObject: vrmRaw)
        let root = try JSONDecoder().decode(V1Root.self, from: data)

        // Humanoid: keyed object { boneName: { node: int } }
        var boneNodeMap  = [String: String]()
        var humanBoneMap = [String: String]()
        for (boneName, ref) in root.humanoid?.humanBones ?? [:] {
            if let nodeName = nodeNames[ref.node] {
                boneNodeMap[boneName] = nodeName
                humanBoneMap[nodeName] = boneName
            }
        }

        // Expressions
        var expressions = [String: VRMExpression]()
        func addExpressions(_ dict: [String: V1Expression]?) {
            for (name, expr) in dict ?? [:] {
                let key = name.lowercased()
                let binds = (expr.morphTargetBinds ?? []).compactMap { bind -> VRMExpression.MorphBind? in
                    // In VRM 1.0, morphTargetBind.node is a glTF node index;
                    // we need the mesh index on that node.
                    guard let nodeName = nodeNames[bind.node],
                          let meshIdx = nodeMeshMap[nodeName] else { return nil }
                    return VRMExpression.MorphBind(meshIndex: meshIdx,
                                                  morphIndex: bind.index,
                                                  weight: bind.weight.clamped(to: 0...1))
                }
                expressions[key] = VRMExpression(
                    name: key, binds: binds, isBinary: expr.isBinary ?? false,
                    overrideMouth:   VRMExpression.OverrideMode(expr.overrideMouth),
                    overrideBlink:   VRMExpression.OverrideMode(expr.overrideBlink),
                    overrideLookAt:  VRMExpression.OverrideMode(expr.overrideLookAt)
                )
            }
        }
        addExpressions(root.expressions?.preset)
        addExpressions(root.expressions?.custom)

        // Spring bone (VRMC_springBone is a separate top-level extension)
        var colliders      = [VRMColliderDef]()
        var colliderGroups = [VRMColliderGroup]()
        var springChains   = [VRMSpringChain]()

        if let sbRaw = extensions["VRMC_springBone"] {
            let sbData = try JSONSerialization.data(withJSONObject: sbRaw)
            let sb = try JSONDecoder().decode(V1SpringBoneRoot.self, from: sbData)

            for c in sb.colliders ?? [] {
                let shape: VRMColliderShape
                if let s = c.shape.sphere {
                    // VRM 1.0 uses glTF right-hand coords (same as SceneKit); no X-flip needed.
                    shape = .sphere(offset: simd3(s.offset), radius: s.radius ?? 0.05)
                } else if let cap = c.shape.capsule {
                    shape = .capsule(offset: simd3(cap.offset),
                                     radius: cap.radius ?? 0.05,
                                     tail:   simd3(cap.tail))
                } else {
                    continue
                }
                colliders.append(VRMColliderDef(nodeIndex: c.node, shape: shape))
            }

            for cg in sb.colliderGroups ?? [] {
                colliderGroups.append(VRMColliderGroup(colliderIndices: cg.colliders))
            }

            for spring in sb.springs ?? [] {
                let nodeIndices = spring.joints.map(\.node)
                let joints = spring.joints.map { j -> VRMSpringJoint in
                    let gd = j.gravityDir.map { simd3($0) } ?? SIMD3<Float>(0, -1, 0)
                    return VRMSpringJoint(
                        stiffness:    j.stiffness    ?? 1.0,
                        drag:         j.dragForce    ?? 0.4,
                        gravityPower: j.gravityPower ?? 0.0,
                        gravityDir:   simd_length(gd) > 0 ? normalize(gd) : SIMD3(0, -1, 0),
                        hitRadius:    j.hitRadius    ?? 0.02
                    )
                }
                springChains.append(VRMSpringChain(
                    nodeIndices:          nodeIndices,
                    joints:               joints,
                    colliderGroupIndices: spring.colliderGroups ?? []
                ))
            }
        }

        return VRMModel(version: .v1,
                        boneNodeMap: boneNodeMap, humanBoneMap: humanBoneMap,
                        expressions: expressions, nodeMeshMap: nodeMeshMap,
                        materialProperties: [],
                        springChains: springChains,
                        colliders: colliders, colliderGroups: colliderGroups)
    }

    // MARK: - MToon application

    private static func applyMToon(scene: SCNScene, materials: [V0Material]) {
        for mat in materials {
            guard let shader = mat.shader, shader.contains("MToon") else { continue }
            scene.rootNode.enumerateChildNodes { node, _ in
                node.geometry?.materials
                    .filter { $0.name == mat.name }
                    .forEach { MToonMaterial.apply(props: mat, to: $0) }
            }
        }
    }

    /// Applies VRMC_materials_mtoon for VRM 1.0 by reading per-material extension data
    /// directly from the glTF JSON (GLTFKit2 does not handle VRM-specific extensions).
    private static func applyMToonV1(scene: SCNScene, json: [String: Any]) {
        guard let materials = json["materials"] as? [[String: Any]] else { return }
        for matJSON in materials {
            guard let extensions = matJSON["extensions"] as? [String: Any],
                  let mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any] else { continue }
            let matName = matJSON["name"] as? String
            scene.rootNode.enumerateChildNodes { node, _ in
                node.geometry?.materials
                    .filter { $0.name == matName }
                    .forEach { MToonMaterial.applyV1(mtoonJSON: mtoon,
                                                    materialJSON: matJSON, to: $0) }
            }
        }
    }

    // MARK: - Helpers

    private static func gravDir0(_ v: V0Vec3?) -> SIMD3<Float> {
        guard let v else { return SIMD3(0, -1, 0) }
        let s = v.simd; return simd_length(s) > 0 ? normalize(s) : SIMD3(0, -1, 0)
    }

    private static func simd3(_ arr: [Float]?) -> SIMD3<Float> {
        guard let a = arr, a.count >= 3 else { return .zero }
        return SIMD3(a[0], a[1], a[2])
    }
}
