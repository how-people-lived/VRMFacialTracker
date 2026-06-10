import MultipeerConnectivity
import Combine

/// Browses for an iPhone peer and receives TrackingFrames.
final class MultipeerReceiver: NSObject, ObservableObject {

    @Published var connectedPeerName: String?

    var onFrame: ((TrackingFrame) -> Void)?

    private let peerID  = MCPeerID(displayName: Multipeer.macPeerID)
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser

    override init() {
        session = MCSession(peer: peerID,
                             securityIdentity: nil,
                             encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: peerID,
                                          serviceType: Multipeer.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    func start() { browser.startBrowsingForPeers() }
    func stop()  { browser.stopBrowsingForPeers(); session.disconnect() }
}

// MARK: - MCSessionDelegate

extension MultipeerReceiver: MCSessionDelegate {
    func session(_ session: MCSession, peer: MCPeerID,
                 didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeerName = state == .connected ? peer.displayName : nil
        }
        if state == .notConnected {
            // Immediately resume browsing after disconnect
            browser.startBrowsingForPeers()
        }
    }

    func session(_ session: MCSession, didReceive data: Data,
                 fromPeer: MCPeerID) {
        guard let frame = TrackingFrame.decoded(from: data) else { return }
        onFrame?(frame)
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String,
                 fromPeer: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String,
                 fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerReceiver: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Invite immediately; iPhone accepts all invitations
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser,
                 didNotStartBrowsingForPeers error: Error) {
        print("[MultipeerReceiver] Browse error: \(error)")
    }
}
