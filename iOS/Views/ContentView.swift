import SwiftUI
import ARKit

struct ContentView: View {

    @StateObject private var tracker    = ARTrackingSession()
    @StateObject private var sender     = MultipeerSender()   // Swift macOS app
    @StateObject private var udpSender  = UDPSender()         // Unity macOS app
    @State private var showCamera       = false
    @State private var showUDPSettings  = false
    @State private var clockTick        = false  // 1秒ごとに反転させて isSending を再評価

    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if showCamera {
                ARPreviewView(session: tracker.arSession)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                Spacer()
                trackingGrid
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showUDPSettings) { udpSettingsSheet }
        .onAppear {
            tracker.onFrame = { [weak sender, weak udpSender] frame in
                sender?.send(frame)
                udpSender?.send(frame)
            }
            sender.start()
            tracker.start()
        }
        .onDisappear {
            tracker.stop()
            sender.stop()
        }
        .animation(.easeInOut(duration: 0.3), value: showCamera)
        .onReceive(refreshTimer) { _ in clockTick.toggle() }
    }

    // MARK: - UDP Settings Sheet

    private var udpSettingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Unity アプリの Mac IP アドレス")) {
                    TextField("例: 192.168.1.10", text: $udpSender.targetHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Mac で「システム設定 → Wi-Fi → 詳細 → TCP/IP」で確認できます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(header: Text("ポート")) {
                    Text("12345（固定）")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Unity 接続設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showUDPSettings = false }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VRM Tracker")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("iPhone")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                udpBadge
                multipeerBadge
            }
        }
        .padding(.top, 8)
    }

    // Unity (UDP) 接続バッジ — メイン表示
    private var udpBadge: some View {
        Button { showUDPSettings = true } label: {
            HStack(spacing: 6) {
                if udpSender.targetHost.isEmpty {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Unity 未設定")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.45))
                } else if udpSender.isSending {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Unity  \(udpSender.targetHost)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 7, height: 7)
                    Text("Unity  \(udpSender.targetHost)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                udpSender.isSending
                    ? Color.green.opacity(0.18)
                    : Color.white.opacity(0.1),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    // Multipeer バッジ — サブ表示（Swift macOS アプリ用）
    private var multipeerBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(sender.connectedPeerName != nil ? Color.cyan.opacity(0.8) : Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
            Text(sender.connectedPeerName != nil ? "Multipeer 接続中" : "Multipeer 検索中…")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(sender.connectedPeerName != nil ? 0.65 : 0.35))
        }
    }

    // MARK: - Tracking status grid

    private var trackingGrid: some View {
        VStack(spacing: 16) {
            Text(tracker.isRunning ? "トラッキング中" : "停止中")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tracker.isRunning ? .green : .red)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TrackingTile(icon: "face.smiling",       label: "表情",    active: tracker.isRunning)
                TrackingTile(icon: "head.profile",       label: "頭の向き",  active: tracker.isRunning)
                TrackingTile(icon: "hand.raised",        label: "手・指",   active: tracker.isRunning)
                TrackingTile(icon: "figure.arms.open",   label: "上半身",   active: tracker.isRunning)
            }
        }
        .padding(20)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Pause / Resume
            Button {
                if tracker.isRunning { tracker.stop() } else { tracker.start() }
            } label: {
                Label(tracker.isRunning ? "停止" : "開始",
                      systemImage: tracker.isRunning ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tracker.isRunning ? .red.opacity(0.8) : .green.opacity(0.8))

            // Head orientation reset
            Button {
                tracker.resetHeadOrientation()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 44)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            // Camera preview toggle
            Button {
                showCamera.toggle()
            } label: {
                Image(systemName: showCamera ? "eye.slash" : "eye")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 44)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Tracking tile

private struct TrackingTile: View {
    let icon:   String
    let label:  String
    let active: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(active ? .white : .white.opacity(0.3))
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? .white.opacity(0.85) : .white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(active ? Color.white.opacity(0.1) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(active ? Color.white.opacity(0.2) : .clear, lineWidth: 1)
        )
    }
}

// MARK: - ARPreviewView (カメラ映像、任意表示)

struct ARPreviewView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = true
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
