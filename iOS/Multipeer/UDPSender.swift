import Foundation
import Network

/// Sends TrackingFrames as JSON over UDP to the Unity app on the Mac.
/// Runs alongside MultipeerSender — both can be active simultaneously.
final class UDPSender: ObservableObject {

    @Published var targetHost:   String = "" {
        didSet {
            UserDefaults.standard.set(targetHost, forKey: udpHostKey)
            reconnect()
        }
    }
    @Published var lastSentTime: Date = .distantPast
    @Published var packetsSent:  Int  = 0

    /// 直近 2 秒以内にパケットを送信していれば true
    var isSending: Bool { Date().timeIntervalSince(lastSentTime) < 2.0 }

    private let port: UInt16 = 12345
    private let udpHostKey   = "udpTargetHost"
    private var connection:  NWConnection?
    private let queue = DispatchQueue(label: "udp.sender", qos: .userInteractive)

    init() {
        targetHost = UserDefaults.standard.string(forKey: udpHostKey) ?? ""
        if !targetHost.isEmpty { reconnect() }
    }

    func send(_ frame: TrackingFrame) {
        guard !targetHost.isEmpty,
              let conn = connection,
              let data = frame.jsonEncoded() else { return }
        conn.send(content: data, completion: .idempotent)
        DispatchQueue.main.async {
            self.lastSentTime = Date()
            self.packetsSent += 1
        }
    }

    private func reconnect() {
        connection?.cancel()
        guard !targetHost.isEmpty else { return }
        let ep = NWEndpoint.hostPort(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: ep, using: .udp)
        conn.start(queue: queue)
        connection = conn
    }
}
