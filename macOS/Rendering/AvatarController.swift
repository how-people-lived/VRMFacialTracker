import SceneKit
import Metal
import QuartzCore
import Combine

// MARK: - OutputSize

enum OutputSize: String, CaseIterable, Identifiable {
    case hd720  = "720p"
    case hd1080 = "1080p"

    var id:     String  { rawValue }
    var label:  String  { rawValue }
    var cgSize: CoreGraphics.CGSize {
        switch self {
        case .hd720:  return CoreGraphics.CGSize(width: 1280, height: 720)
        case .hd1080: return CoreGraphics.CGSize(width: 1920, height: 1080)
        }
    }
}

/// Central coordinator: drives the CVDisplayLink render loop, routes tracking
/// data to the VRM mappers, and publishes frames to Syphon.
@MainActor
final class AvatarController: ObservableObject {

    @Published var isConnected:      Bool       = false
    @Published var connectedPeerName: String?
    @Published var framesPerSecond:  Double     = 0
    @Published var currentScene:     SCNScene?
    @Published var loadedFileName:   String?
    @Published var errorMessage:     String?

    // Persisted settings
    @Published private(set) var syphonName:  String     = UserDefaults.standard.string(forKey: "syphonName") ?? "VRM Avatar"
    @Published private(set) var outputSize:  OutputSize = OutputSize(rawValue: UserDefaults.standard.string(forKey: "outputSize") ?? "") ?? .hd720
    @Published private(set) var cameraHeight:   Float = Float(UserDefaults.standard.double(forKey: "cameraHeight").nonZeroOr(1.4))
    @Published private(set) var cameraDistance: Float = Float(UserDefaults.standard.double(forKey: "cameraDistance").nonZeroOr(2.0))

    // MARK: - Private

    private let receiver      = MultipeerReceiver()
    private var sceneRenderer: SceneRenderer?
    private var syphonBridge:  SyphonBridge?
    private var commandQueue:  MTLCommandQueue?

    private var blendMapper:  VRMBlendShapeMapper?
    private var boneMapper:   VRMBoneMapper?
    private var springBones = SpringBoneSimulator()
    private var lastRenderTime: Double = 0

    private var displayLink: CVDisplayLink?
    private var fpsTimer:    Timer?
    private var frameCount = 0

    private var latestFrame: TrackingFrame?
    private let frameLock = NSLock()

    // MARK: - Lifecycle

    func setup() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        commandQueue = device.makeCommandQueue()

        syphonBridge  = makeSyphonBridge(device: device)
        sceneRenderer = SceneRenderer(device: device)
        sceneRenderer?.cameraHeight   = cameraHeight
        sceneRenderer?.cameraDistance = cameraDistance

        receiver.onFrame = { [weak self] frame in
            self?.frameLock.lock()
            self?.latestFrame = frame
            self?.frameLock.unlock()
        }
        receiver.start()
        startDisplayLink()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                framesPerSecond  = Double(frameCount)
                frameCount       = 0
                isConnected      = receiver.connectedPeerName != nil
                connectedPeerName = receiver.connectedPeerName
            }
        }
    }

    func teardown() {
        fpsTimer?.invalidate()
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        syphonBridge?.stop()
        receiver.stop()
    }

    // MARK: - Settings

    func applySettings(syphonName: String, outputSize: OutputSize,
                       cameraHeight: Float, cameraDistance: Float) {
        let nameChanged = syphonName != self.syphonName || outputSize != self.outputSize
        self.syphonName      = syphonName
        self.outputSize      = outputSize
        self.cameraHeight    = cameraHeight
        self.cameraDistance  = cameraDistance

        UserDefaults.standard.set(syphonName,        forKey: "syphonName")
        UserDefaults.standard.set(outputSize.rawValue, forKey: "outputSize")
        UserDefaults.standard.set(Double(cameraHeight),   forKey: "cameraHeight")
        UserDefaults.standard.set(Double(cameraDistance), forKey: "cameraDistance")

        sceneRenderer?.cameraHeight   = cameraHeight
        sceneRenderer?.cameraDistance = cameraDistance

        if nameChanged, let device = commandQueue?.device {
            syphonBridge?.stop()
            syphonBridge = makeSyphonBridge(device: device)
        }
    }

    func resetCamera() {
        applySettings(syphonName: syphonName, outputSize: outputSize,
                      cameraHeight: 1.4, cameraDistance: 2.0)
    }

    // MARK: - VRM loading

    func loadVRM(url: URL) {
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try VRMLoader.load(url: url)
                }.value
                sceneRenderer?.loadScene(result.scene)
                blendMapper   = VRMBlendShapeMapper(scene: result.scene, model: result.model)
                boneMapper    = VRMBoneMapper(scene: result.scene, model: result.model)
                springBones   = SpringBoneSimulator()
                springBones.setup(scene: result.scene, model: result.model, nodeNames: result.nodeNames)
                currentScene   = result.scene
                loadedFileName = url.lastPathComponent
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, userInfo in
            Unmanaged<AvatarController>.fromOpaque(userInfo!).takeUnretainedValue().renderFrame()
            return kCVReturnSuccess
        }, ptr)
        CVDisplayLinkStart(dl)
    }

    private func renderFrame() {
        guard let renderer = sceneRenderer,
              let bridge   = syphonBridge,
              let cq       = commandQueue else { return }

        let now = CACurrentMediaTime()
        let dt  = lastRenderTime == 0 ? Float(1.0 / 60.0) : Float(now - lastRenderTime)
        lastRenderTime = now

        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()

        if let frame {
            boneMapper?.apply(face:      frame.face,
                              body:      frame.body,
                              leftHand:  frame.leftHand,
                              rightHand: frame.rightHand)
            if let face = frame.face { blendMapper?.apply(faceData: face) }
        }

        springBones.update(deltaTime: dt)

        renderer.render(at: CACurrentMediaTime(), into: bridge.metalTexture, commandQueue: cq)
        bridge.publish()

        Task { @MainActor [weak self] in self?.frameCount += 1 }
    }

    // MARK: - Helpers

    private func makeSyphonBridge(device: MTLDevice) -> SyphonBridge? {
        let w = Int(outputSize.cgSize.width)
        let h = Int(outputSize.cgSize.height)
        return SyphonBridge(name: syphonName, device: device, width: w, height: h)
    }
}

// MARK: - Double helper

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
