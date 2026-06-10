import Foundation

enum Multipeer {
    static let serviceType = "vrm-tracker"   // ≤15 chars, DNS-SD compatible
    static let iPhonePeerID = "VRMPhone"
    static let macPeerID    = "VRMMac"
}

enum TrackingConfig {
    /// Vision requests run every N ARKit frames to reduce CPU load
    static let visionFrameInterval = 2
    /// Max hands to detect simultaneously
    static let maxHandCount = 2
}
