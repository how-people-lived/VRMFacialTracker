import SwiftUI
import SceneKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = AvatarController()
    @State private var showFilePicker   = false
    @State private var showSettings     = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, maxWidth: 260)
            previewPane
                .frame(minWidth: 440)
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showFilePicker = true } label: {
                    Label("VRMを開く", systemImage: "folder.badge.plus")
                }
                .help("VRMファイルを開く（VRM 0.x / 1.0）")

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(controller: controller)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "vrm")!],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.loadVRM(url: url)
            }
        }
        .alert("読み込みエラー",
               isPresented: Binding(
                   get: { controller.errorMessage != nil },
                   set: { if !$0 { controller.errorMessage = nil } }
               )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onAppear    { controller.setup() }
        .onDisappear { controller.teardown() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Form {
            // ① アバター
            Section {
                if let name = controller.loadedFileName {
                    Label {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                } else {
                    Text("VRM 0.x / 1.0 に対応")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("VRMファイルを開く…") { showFilePicker = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } header: {
                Label("アバター", systemImage: "person.crop.rectangle")
            }

            // ② iPhone 接続
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isConnected ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                        .shadow(color: controller.isConnected ? .green.opacity(0.6) : .clear,
                                radius: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(controller.isConnected ? "接続済み" : "待機中")
                            .font(.caption.weight(.medium))
                        if let peer = controller.connectedPeerName {
                            Text(peer)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if !controller.isConnected {
                    Text("iPhone アプリを起動すると\n自動で接続されます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Label("iPhone 接続", systemImage: "iphone")
            }

            // ③ Syphon 出力
            Section {
                LabeledContent("サーバー名") {
                    Text(controller.syphonName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LabeledContent("解像度") {
                    Text(controller.outputSize.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("OBS: ソース → Syphon Client")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Syphon 出力", systemImage: "video.fill")
            }

            // ④ パフォーマンス
            Section {
                HStack(spacing: 10) {
                    let fps = controller.framesPerSecond
                    Text(fps > 0 ? "\(Int(fps))" : "—")
                        .monospacedDigit()
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(fpsColor)
                        .frame(width: 36, alignment: .trailing)
                    Text("fps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    FPSBar(fps: fps, color: fpsColor)
                        .frame(width: 56, height: 10)
                }
                .padding(.vertical, 2)
            } header: {
                Label("パフォーマンス", systemImage: "chart.bar.fill")
            }
        }
        .formStyle(.grouped)
    }

    private var fpsColor: Color {
        let fps = controller.framesPerSecond
        if fps >= 55 { return .green }
        if fps >= 30 { return .orange }
        return fps == 0 ? .secondary : .red
    }

    // MARK: - Preview pane

    private var previewPane: some View {
        ZStack {
            Color.black

            if let scene = controller.currentScene {
                ScenePreviewView(scene: scene)
                    .transition(.opacity.animation(.easeIn(duration: 0.3)))

                // Overlay badges
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        // iPhone 接続バッジ
                        if controller.isConnected {
                            overlayBadge(
                                icon: "iphone.radiowaves.left.and.right",
                                text: controller.connectedPeerName ?? "接続済み"
                            )
                        }
                        Spacer()
                        // Syphon バッジ
                        overlayBadge(
                            icon: "dot.radiowaves.left.and.right",
                            text: "Syphon 出力中"
                        )
                    }
                    .padding(12)
                }
            } else {
                emptyState
            }
        }
    }

    private func overlayBadge(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.12))
            VStack(spacing: 6) {
                Text("アバター未読み込み")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text("ツールバーの「VRMを開く」からファイルを選択してください")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
            Button("VRMを開く…") { showFilePicker = true }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - FPS mini bar

private struct FPSBar: View {
    let fps: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * min(1, fps / 60))
            }
        }
    }
}

// MARK: - Live SceneKit preview

struct ScenePreviewView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor            = .clear
        v.allowsCameraControl        = true
        v.autoenablesDefaultLighting = true
        v.wantsLayer                 = true
        v.layer?.transform           = CATransform3DMakeScale(-1, 1, 1)
        attachCamera(to: v, scene: scene)
        return v
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard nsView.scene !== scene else { return }
        nsView.pointOfView?.removeFromParentNode()
        attachCamera(to: nsView, scene: scene)
    }

    private func attachCamera(to view: SCNView, scene: SCNScene) {
        let cam         = SCNNode()
        cam.camera      = SCNCamera()
        cam.position    = SCNVector3(0, 1.4, -2.0)
        cam.eulerAngles = SCNVector3(0, Float.pi, 0)
        scene.rootNode.addChildNode(cam)
        view.scene       = scene
        view.pointOfView = cam
    }
}

// MARK: - Settings sheet

struct SettingsView: View {
    @ObservedObject var controller: AvatarController
    @Environment(\.dismiss) var dismiss

    @State private var draftSyphonName:     String
    @State private var draftOutputSize:     OutputSize
    @State private var draftCameraHeight:   Float
    @State private var draftCameraDistance: Float

    init(controller: AvatarController) {
        self.controller      = controller
        _draftSyphonName     = State(initialValue: controller.syphonName)
        _draftOutputSize     = State(initialValue: controller.outputSize)
        _draftCameraHeight   = State(initialValue: controller.cameraHeight)
        _draftCameraDistance = State(initialValue: controller.cameraDistance)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("設定").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    TextField("サーバー名", text: $draftSyphonName)
                        .textFieldStyle(.roundedBorder)
                    Picker("解像度", selection: $draftOutputSize) {
                        ForEach(OutputSize.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Label("Syphon 出力", systemImage: "video.fill")
                } footer: {
                    Text("OBS: ソース → + → Syphon Client → サーバー名を選択")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    sliderRow("高さ", value: $draftCameraHeight,   range: 0.3...2.8,
                              format: "%.2f m")
                    sliderRow("距離", value: $draftCameraDistance, range: 0.5...5.0,
                              format: "%.2f m")
                    Button("デフォルトに戻す") {
                        draftCameraHeight   = 1.4
                        draftCameraDistance = 2.0
                    }
                    .controlSize(.small)
                } header: {
                    Label("出力カメラ", systemImage: "camera.fill")
                } footer: {
                    Text("プレビュー内のカメラ操作とは独立しています")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("適用") {
                    controller.applySettings(
                        syphonName:     draftSyphonName,
                        outputSize:     draftOutputSize,
                        cameraHeight:   draftCameraHeight,
                        cameraDistance: draftCameraDistance)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draftSyphonName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sliderRow(_ label: String, value: Binding<Float>,
                            range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: range.upperBound > 3 ? 0.1 : 0.05)
        }
    }
}
