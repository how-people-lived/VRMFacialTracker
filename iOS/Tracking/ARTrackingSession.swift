import ARKit
import Vision
import simd
import Combine

/// Drives ARKit face tracking and Vision hand/body pose on the front camera.
/// Publishes a new TrackingFrame for each ARKit update (≈60 fps).
final class ARTrackingSession: NSObject, ObservableObject {

    // MARK: - Public

    @Published var isRunning = false
    @Published var lastFrame: TrackingFrame?

    var onFrame: ((TrackingFrame) -> Void)?

    // MARK: - Private

    let arSession = ARSession()
    private let visionQueue = DispatchQueue(label: "vrm.vision", qos: .userInteractive)
    private var frameCounter = 0

    // Latest Vision results (written on visionQueue, read on ARKit delegate queue)
    private var latestLeftHand:  HandData?
    private var latestRightHand: HandData?
    private var latestBody:      BodyData?
    private let resultsLock = NSLock()

    // Head orientation calibration
    private var calibrationInverse = simd_quatf(vector: SIMD4<Float>(0, 0, 0, 1))
    private var pendingReset = false

    /// 現在の頭の向きをゼロ点として記録する
    func resetHeadOrientation() { pendingReset = true }

    // Vision requests (created once, reused)
    private lazy var handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = TrackingConfig.maxHandCount
        return r
    }()

    private lazy var bodyRequest: VNDetectHumanBodyPoseRequest = {
        VNDetectHumanBodyPoseRequest()
    }()

    // MARK: - Lifecycle

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            print("[ARTrackingSession] ARFaceTracking not supported on this device")
            return
        }
        let config = ARFaceTrackingConfiguration()
        // isWorldTrackingEnabled: A12 以降では有効、未対応端末は無視される
        config.isWorldTrackingEnabled = true
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        arSession.pause()
        isRunning = false
    }

    // MARK: - Vision processing

    private func runVision(on pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                           orientation: .leftMirrored)
        do {
            try handler.perform([handRequest, bodyRequest])
        } catch {
            return
        }

        var leftHand:  HandData?
        var rightHand: HandData?
        var body:      BodyData?

        // Hand pose — convert VNHumanHandPoseObservation.JointName keys to String rawValues
        if let handObs = handRequest.results {
            for obs in handObs {
                guard let joints = try? obs.recognizedPoints(.all) else { continue }
                var stringJoints = [String: JointPoint]()
                for (key, point) in joints where point.confidence > 0.3 {
                    stringJoints[key.rawValue.rawValue] = JointPoint(
                        x: Float(point.location.x),
                        y: Float(point.location.y),
                        confidence: Float(point.confidence))
                }
                let isRight = isRightHand(obs)
                let data = HandData(joints: stringJoints)
                if isRight { rightHand = data } else { leftHand = data }
            }
        }

        // Body pose — convert VNHumanBodyPoseObservation.JointName keys to String rawValues
        if let bodyObs = bodyRequest.results?.first {
            let joints = (try? bodyObs.recognizedPoints(.all)) ?? [:]
            var stringJoints = [String: JointPoint]()
            for (key, point) in joints where point.confidence > 0.3 {
                stringJoints[key.rawValue.rawValue] = JointPoint(
                    x: Float(point.location.x),
                    y: Float(point.location.y),
                    confidence: Float(point.confidence))
            }
            body = BodyData(joints: stringJoints)
        }

        resultsLock.lock()
        latestLeftHand  = leftHand
        latestRightHand = rightHand
        latestBody      = body
        resultsLock.unlock()
    }

    // Chirality heuristic: in a selfie view, right hand wrist is to the right of middle finger base
    private func isRightHand(_ obs: VNHumanHandPoseObservation) -> Bool {
        guard let wrist = try? obs.recognizedPoint(.wrist),
              let middleMCP = try? obs.recognizedPoint(.middleMCP) else { return false }
        return wrist.location.x > middleMCP.location.x
    }
}

// MARK: - ARSessionDelegate

extension ARTrackingSession: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1

        // Extract face data
        var faceData: FaceData?
        for anchor in frame.anchors {
            guard let face = anchor as? ARFaceAnchor else { continue }
            let m = face.transform
            let pos = SIMD3Float(m.columns.3.x, m.columns.3.y, m.columns.3.z)

            // Convert matrix to quaternion, apply calibration offset
            let q = simd_quaternion(face.transform)
            if pendingReset {
                pendingReset        = false
                calibrationInverse  = q.inverse
            }
            let relQ = calibrationInverse * q
            let rot = SIMDQuatFloat(relQ.vector.x, relQ.vector.y, relQ.vector.z, relQ.vector.w)

            var shapes = [String: Float]()
            for (key, val) in face.blendShapes {
                shapes[key.rawValue] = val.floatValue
            }
            faceData = FaceData(blendShapes: shapes, headPosition: pos, headRotation: rot)
            break
        }

        // Run Vision every N frames (off-thread so ARKit isn't blocked)
        if frameCounter % TrackingConfig.visionFrameInterval == 0 {
            let pb = frame.capturedImage
            visionQueue.async { [weak self] in
                self?.runVision(on: pb)
            }
        }

        resultsLock.lock()
        let left  = latestLeftHand
        let right = latestRightHand
        let body  = latestBody
        resultsLock.unlock()

        let tracking = TrackingFrame(
            timestamp:  frame.timestamp,
            face:       faceData,
            leftHand:   left,
            rightHand:  right,
            body:       body
        )

        lastFrame = tracking
        onFrame?(tracking)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("[ARTrackingSession] Error: \(error)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        isRunning = false
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        start()
    }
}
