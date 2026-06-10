import MultipeerConnectivity
import Combine

/// Advertises the iPhone on the local network and sends TrackingFrames to the
/// first Mac that connects.  Automatically reconnects on disconnect.
final class MultipeerSender: NSObject, ObservableObject {

    @Published var connectedPeerName: String?

    private let peerID   = MCPeerID(displayName: Multipeer.iPhonePeerID)
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser

    override init() {
        session    = MCSession(peer: peerID,
                               securityIdentity: nil,
                               encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID,
                                               discoveryInfo: nil,
                                               serviceType: Multipeer.serviceType)
        super.init()
        session.delegate    = self
        advertiser.delegate = self
    }

    func start() { advertiser.startAdvertisingPeer() }
    func stop()  { advertiser.stopAdvertisingPeer(); session.disconnect() }

    // MARK: - Send

    /// Encodes and sends a frame as unreliable data (UDP-like semantics for low latency).
    func send(_ frame: TrackingFrame) {
        guard !session.connectedPeers.isEmpty,
              let data = frame.encoded() else { return }
        try? session.send(data,
                          toPeers: session.connectedPeers,
                          with: .unreliable)
    }
}

// MARK: - MCSessionDelegate

extension MultipeerSender: MCSessionDelegate {
    func session(_ session: MCSession, peer: MCPeerID,
                 didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeerName = state == .connected ? peer.displayName : nil
        }
    }
    func session(_ session: MCSession, didReceive data: Data,
                 fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String,
                 fromPeer: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String,
                 fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSender: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        print("[MultipeerSender] Advertising error: \(error)")
    }
}
