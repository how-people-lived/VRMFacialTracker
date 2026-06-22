# VRM Facial Tracker

ARKit による**フェイシャルトラッキング**アプリ。
iPhone で表情・頭の向きをキャプチャして Mac に送り、VRM アバターをリアルタイム制御します。
腕・指は追従せず、アバターは自然な立ち姿で静止します（表情に専念）。

## 構成

```
iPhone App  →  Multipeer / UDP  →  Mac App (Swift / Unity)  →  Syphon  →  OBS
(ARKit Face)                       (SceneKit / UniVRM)                  (仮想カメラ)
```

## トラッキング内容

| ソース | 内容 |
|--------|------|
| ARKit `ARFaceTrackingConfiguration` | 表情 52 BlendShapes + 頭部 6DoF |

> 手・上半身の Vision 推定 (`VNDetectHumanHandPoseRequest` /
> `VNDetectHumanBodyPose3DRequest`) は `ARTrackingSession.trackBodyAndHands`
> フラグで無効化しています。再度有効にすればデータ送信を復活できます。

## セットアップ手順

### 1. 依存関係

```bash
# xcodegen インストール (Xcode プロジェクト生成用)
brew install xcodegen

# Syphon.framework を取得
# https://github.com/Syphon/Syphon-Framework/releases から最新版をダウンロード
# Syphon.framework を macOS/Frameworks/ に配置
```

### 2. Xcode プロジェクト生成

```bash
cd ~/VRMFacialTracker
xcodegen generate
open VRMFacialTracker.xcodeproj
```

### 3. Syphon.framework をプロジェクトに追加

1. Xcode で `VRMTrackerMac` ターゲットを選択
2. General → Frameworks, Libraries, and Embedded Content
3. `+` → Add Other → `macOS/Frameworks/Syphon.framework`
4. `SyphonServer.swift` の `#if canImport(Syphon)` ブロックが有効になる

### 4. Signing & Capabilities

**VRMTrackerPhone (iOS)**
- Signing & Capabilities → `+` → **Local Network**  
- Info.plist に `NSBonjourServices` が含まれていることを確認

**VRMTrackerMac (macOS)**
- App Sandbox は **OFF** にしてください (Syphon と Multipeer が共存できないため)

### 5. 実行

1. Mac 側: `VRMTrackerMac` を実行 → `.vrm` ファイルを開く
2. iPhone 側: `VRMTrackerPhone` を実行 → 自動接続
3. OBS: **Tools → Syphon Inject** または [obs-syphon](https://github.com/zakk4223/obs-syphon) プラグインで `VRM Avatar` ソースを追加

## OBS での透明背景の使い方

1. OBS に `obs-syphon` プラグインをインストール
2. ソース追加 → **Syphon Client** → サーバー: `VRM Avatar`  
3. アルファチャンネルが有効になっているため、背景は透明 → クロマキー不要

グリーンバックが必要な場合: `SceneRenderer.swift` の `clearColor` を
`MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)` に変更

## VRM ファイルについて

VRM 0.x 形式 (.vrm) に対応しています。  
無料アバター: [VRoid Hub](https://hub.vroid.com/) (配布設定を確認してください)

## アーキテクチャ

```
iOS/
  ARTrackingSession.swift   — ARKit + Vision を統合したメイントラッカー
  MultipeerSender.swift     — TrackingFrame を Multipeer で送信

macOS/
  MultipeerReceiver.swift   — iPhone からデータ受信
  VRMLoader.swift           — GLTFKit2 + VRM 拡張パーサ
  VRMBlendShapeMapper.swift — ARKit 52 BS → VRM プリセット変換
  VRMBoneMapper.swift       — Vision 関節位置 → VRM ボーン回転
  SceneRenderer.swift       — SCNRenderer によるオフスクリーン描画
  SyphonServer.swift        — Syphon Metal テクスチャ出力
  AvatarController.swift    — 全体コーディネーター

Shared/
  TrackingFrame.swift       — iPhone↔Mac 間の共有データモデル
  Constants.swift           — Multipeer サービス名など
```

## 既知の制限

- **腕・指トラッキングは廃止**: ARKit は前面カメラの顔と背面カメラの全身を同時に扱えず、
  前カメラ + Vision の 2D/3D 推定では精度に限界があったため、表情トラッキングに専念する方針にしました。
  腕・指は受信側 (`BoneMapper`) で**自然な立ち姿**（腕を下ろし指を軽く曲げた姿勢）に固定されます。
  立ち姿の角度は Unity の `BoneMapper` インスペクタ（`upperArmDownAngle` 等）で調整できます。
- **Syphon**: `#if canImport(Syphon)` が false の場合はフレームが出力されません。
  Syphon.framework の追加を確認してください。
- **VRM 1.0**: 現時点では VRM 0.x のみ対応。VRM 1.0 (`VRMC_vrm` 拡張) は今後対応予定。
