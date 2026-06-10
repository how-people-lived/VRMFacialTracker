import SceneKit
import Metal
import QuartzCore

/// Off-screen SceneKit renderer with horizontal flip (mirror mode).
/// Renders to an intermediate private texture, then runs a Metal compute shader
/// to copy it horizontally-flipped into the final (IOSurface-backed) texture.
final class SceneRenderer {

    let device: MTLDevice
    let scnRenderer: SCNRenderer

    private var renderPassDescriptor = MTLRenderPassDescriptor()
    private var flipPipeline: MTLComputePipelineState?
    private var intermediateTexture: MTLTexture?
    private var cameraNode: SCNNode?

    var cameraHeight: Float = 1.4 { didSet { updateCameraPosition() } }
    var cameraDistance: Float = 2.0 { didSet { updateCameraPosition() } }

    // MARK: - Init

    init?(device: MTLDevice? = nil) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device      = dev
        self.scnRenderer = SCNRenderer(device: dev, options: nil)
        // We manage lights ourselves; disable the auto-omni so MToon directional
        // shading isn't washed out by a light that ignores surface normals.
        scnRenderer.autoenablesDefaultLighting = false
        buildFlipPipeline(device: dev)
        setupCamera()
    }

    // MARK: - Public

    func loadScene(_ scene: SCNScene) {
        scnRenderer.scene = scene
        addDefaultLighting(to: scene)
    }

    /// Renders one SceneKit frame into `outputTexture` (IOSurface-backed), applying
    /// a horizontal flip so Syphon clients receive a mirrored (front-camera style) image.
    func render(at time: TimeInterval,
                into outputTexture: MTLTexture,
                commandQueue: MTLCommandQueue) {
        let intermediate = getIntermediate(like: outputTexture)

        renderPassDescriptor.colorAttachments[0].texture     = intermediate
        renderPassDescriptor.colorAttachments[0].loadAction  = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor  =
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let viewport = CGRect(x: 0, y: 0,
                              width: intermediate.width, height: intermediate.height)
        scnRenderer.render(atTime: time, viewport: viewport,
                           commandBuffer: commandBuffer,
                           passDescriptor: renderPassDescriptor)

        // Flip intermediate → outputTexture (mirror effect)
        if let pipeline = flipPipeline,
           let encoder  = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(intermediate,  index: 0)
            encoder.setTexture(outputTexture, index: 1)
            let w   = pipeline.threadExecutionWidth
            let h   = pipeline.maxTotalThreadsPerThreadgroup / w
            let tpg = MTLSize(width: w, height: h, depth: 1)
            let grid = MTLSize(
                width:  (intermediate.width  + w - 1) / w,
                height: (intermediate.height + h - 1) / h,
                depth:  1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Private

    private func buildFlipPipeline(device: MTLDevice) {
        guard let library  = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "horizontalFlip"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return }
        flipPipeline = pipeline
    }

    private func getIntermediate(like texture: MTLTexture) -> MTLTexture {
        if let t = intermediateTexture,
           t.width == texture.width, t.height == texture.height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height, mipmapped: false)
        desc.usage       = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        intermediateTexture = device.makeTexture(descriptor: desc)!
        return intermediateTexture!
    }

    private func setupCamera() {
        let cam = SCNNode()
        cam.camera        = SCNCamera()
        cam.camera?.zNear = 0.01
        cam.camera?.zFar  = 100.0
        cam.position    = SCNVector3(0, cameraHeight, -cameraDistance)
        cam.eulerAngles = SCNVector3(0, Float.pi, 0)
        scnRenderer.pointOfView = cam
        cameraNode = cam
    }

    private func updateCameraPosition() {
        cameraNode?.position = SCNVector3(0, cameraHeight, -cameraDistance)
    }

    /// Adds ambient fill + directional key light so MToon toon shading is visible.
    /// Called once per scene load; idempotent via named node check.
    private func addDefaultLighting(to scene: SCNScene) {
        guard scene.rootNode.childNode(withName: "__vrm_ambient", recursively: false) == nil
        else { return }

        let ambient = SCNNode()
        ambient.name        = "__vrm_ambient"
        ambient.light       = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300      // soft fill so dark areas aren't pure black

        let dir = SCNNode()
        dir.name        = "__vrm_dir"
        dir.light       = SCNLight()
        dir.light?.type = .directional
        dir.light?.intensity = 1000
        // Angled from upper-left — produces a visible shadow boundary for MToon
        dir.eulerAngles = SCNVector3(Float(-Double.pi / 4), Float(-Double.pi / 6), 0)

        scene.rootNode.addChildNode(ambient)
        scene.rootNode.addChildNode(dir)
    }
}
