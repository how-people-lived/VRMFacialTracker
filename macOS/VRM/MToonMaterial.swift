import SceneKit
import AppKit

/// Applies VRM MToon toon shading to GLTFKit2-loaded SCNMaterials.
/// Supports both VRM 0.x (materialProperties[]) and VRM 1.0 (VRMC_materials_mtoon per material).
final class MToonMaterial {

    // MARK: - VRM 0.x

    static func apply(props: V0Material, to mat: SCNMaterial) {
        let fp = props.floatProperties ?? [:]
        let vp = props.vectorProperties ?? [:]

        // Emission
        if let e = vp["_EmissionColor"], e.count >= 3,
           e[0] > 0.01 || e[1] > 0.01 || e[2] > 0.01 {
            mat.emission.contents = NSColor(srgbRed: CGFloat(e[0]),
                                            green:   CGFloat(e[1]),
                                            blue:    CGFloat(e[2]),
                                            alpha:   1)
        }

        // Culling: 0 = both, 1 = front, 2 = back (default)
        switch Int(fp["_CullMode"] ?? 2) {
        case 0: mat.isDoubleSided = true
        case 1: mat.cullMode = .front
        default: mat.cullMode = .back
        }

        let sc = vp["_ShadeColor"]
        let rc = vp["_RimColor"]

        applyShader(
            to: mat,
            shadeR:     sc?[safe: 0] ?? 0.8,
            shadeG:     sc?[safe: 1] ?? 0.8,
            shadeB:     sc?[safe: 2] ?? 0.8,
            shadeShift: fp["_ShadeShift"] ?? 0.0,
            shadeToony: fp["_ShadeToony"] ?? 0.9,
            rimR:       rc?[safe: 0] ?? 0.0,
            rimG:       rc?[safe: 1] ?? 0.0,
            rimB:       rc?[safe: 2] ?? 0.0,
            rimPow:     fp["_RimFresnelPower"] ?? 5.0,
            cutoff:     fp["_Cutoff"] ?? 0.5,
            isCutout:   Int(fp["_BlendMode"] ?? 0) == 1
        )
    }

    // MARK: - VRM 1.0  (VRMC_materials_mtoon extension JSON + base glTF material JSON)

    static func applyV1(mtoonJSON: [String: Any], materialJSON: [String: Any], to mat: SCNMaterial) {
        func rgb(_ key: String, _ d0: Double, _ d1: Double, _ d2: Double) -> (Float, Float, Float) {
            let a = jArr(mtoonJSON, key)
            return (Float(a[safe: 0] ?? d0), Float(a[safe: 1] ?? d1), Float(a[safe: 2] ?? d2))
        }
        func f(_ dict: [String: Any], _ key: String, _ def: Double) -> Float {
            if let v = dict[key] as? Double { return Float(v) }
            if let v = dict[key] as? Int    { return Float(v) }
            return Float(def)
        }

        let (shR, shG, shB) = rgb("shadeColorFactor", 0.97, 0.81, 0.86)
        let (riR, riG, riB) = rgb("parametricRimColorFactor", 0, 0, 0)
        let shift = f(mtoonJSON, "shadingShiftFactor", 0.0)
        let toony = f(mtoonJSON, "shadingToonyFactor", 0.9)
        let rimPow = f(mtoonJSON, "parametricRimFresnelPowerFactor", 5.0)

        let alphaMode = materialJSON["alphaMode"] as? String ?? "OPAQUE"
        let cutoff = f(materialJSON, "alphaCutoff", 0.5)
        if materialJSON["doubleSided"] as? Bool == true { mat.isDoubleSided = true }

        // VRM 1.0 emissive is handled by GLTFKit2 via emissiveFactor + KHR_materials_emissive_strength

        applyShader(
            to: mat,
            shadeR: shR, shadeG: shG, shadeB: shB,
            shadeShift: shift, shadeToony: toony,
            rimR: riR, rimG: riG, rimB: riB, rimPow: rimPow,
            cutoff: cutoff, isCutout: alphaMode == "MASK"
        )
    }

    // MARK: - Core shader application

    private static func applyShader(to mat: SCNMaterial,
                                    shadeR: Float, shadeG: Float, shadeB: Float,
                                    shadeShift: Float, shadeToony: Float,
                                    rimR: Float, rimG: Float, rimB: Float, rimPow: Float,
                                    cutoff: Float, isCutout: Bool) {
        mat.lightingModel = .lambert
        mat.shaderModifiers = [.fragment: makeShader(
            shadeR: shadeR, shadeG: shadeG, shadeB: shadeB,
            shadeShift: shadeShift, shadeToony: shadeToony,
            rimR: rimR, rimG: rimG, rimB: rimB, rimPow: rimPow,
            cutoff: cutoff, isCutout: isCutout
        )]
    }

    // MARK: - Shader source

    private static func makeShader(
        shadeR: Float, shadeG: Float, shadeB: Float,
        shadeShift: Float, shadeToony: Float,
        rimR: Float, rimG: Float, rimB: Float, rimPow: Float,
        cutoff: Float, isCutout: Bool
    ) -> String {
        // VRM MToon toon ramp:
        //   litI  = luminance of directional diffuse ∈ [0,1]
        //           (NOT divided by surface colour — that inflates litI for saturated surfaces
        //            and collapses the toon boundary on any non-white texture)
        //   lo/hi = smoothstep boundary derived from _ShadeShift / _ShadeToony:
        //           • mid  = 0.5 + shadeShift * 0.5  (0 → boundary at 50% light, i.e. NdotL≈0)
        //           • width = (1 − shadeToony)        (0.9 → 10% width, gives a visible ramp)
        let mid   = (0.5 + shadeShift * 0.5).clamped(to: 0.01 ... 0.99)
        let width = max(1.0 - shadeToony, 0.01)   // minimum 1% so smoothstep is never degenerate
        let lo    = max(mid - width * 0.5, 0.0)
        let hi    = min(mid + width * 0.5, 1.0)

        let cutoutLine = isCutout
            ? "    if (_surface.diffuse.a < \(cutoff)) { discard_fragment(); }\n"
            : ""

        return """
        #pragma body
        {
        \(cutoutLine)\
            // litI: luminance of the directional diffuse contribution only.
            // Using the raw contribution (not normalised by surfLum) keeps the toon
            // boundary at the same NdotL angle regardless of surface hue.
            float litI = clamp(dot(_lightingContribution.diffuse.rgb,
                                   vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

            // Toon ramp
            float toon  = smoothstep(\(lo), \(hi), litI);
            vec3  shade = vec3(\(shadeR), \(shadeG), \(shadeB)) * _surface.diffuse.rgb;
            _output.color.rgb = mix(shade, _output.color.rgb, toon);

            // Fresnel rim light
            float vdotn = clamp(dot(normalize(_surface.normal),
                                    normalize(-_surface.position)), 0.0, 1.0);
            float rim   = pow(1.0 - vdotn, max(\(rimPow), 0.1));
            _output.color.rgb += vec3(\(rimR), \(rimG), \(rimB)) * rim;
        }
        """
    }

    // MARK: - Helpers

    private static func jArr(_ d: [String: Any], _ key: String) -> [Double] {
        guard let arr = d[key] as? [Any] else { return [] }
        return arr.compactMap {
            if let v = $0 as? Double { return v }
            if let v = $0 as? Int    { return Double(v) }
            return nil
        }
    }
}
