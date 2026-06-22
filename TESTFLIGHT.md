# iPhone アプリを TestFlight で配布する手順

`VRMTrackerPhone`（iOS アプリ）を TestFlight でベータ配布するための手順です。
**Apple Developer Program 未加入の状態**から順に説明します。

---

## 0. 前提・制約

- **実機が必要**：ARKit のフェイストラッキングは TrueDepth カメラ搭載機（iPhone X 以降）でのみ動作。シミュレータ不可。
- **Mac + Xcode 15 以降** が必要。
- **Apple Developer Program（年額 11,800 円 / $99）への加入が必須**（TestFlight 配布に必要）。
  - 無料の Apple ID でも「自分の実機への直接インストール（7日間有効）」は可能ですが、**TestFlight 配布はできません**。

---

## 1. Apple Developer Program に加入する

1. <https://developer.apple.com/programs/enroll/> にアクセスし、Apple ID でサインイン。
2. 個人（Individual）または組織（Organization）を選択。
   - 千葉工大の組織アカウントを使う場合は、大学側の管理者に招待してもらうか、組織の D-U-N-S 番号が必要です。まずは**個人**が手軽です。
3. 二要素認証を有効化し、規約に同意して年会費を支払う。
4. 承認まで通常 24〜48 時間。承認後 <https://appstoreconnect.apple.com> が使えるようになります。

> 加入待ちの間も、以下 2〜3 のプロジェクト整備と「自分の実機への直接インストール」での動作確認は進められます。

---

## 2. プロジェクトを生成・署名する

```bash
brew install xcodegen          # 未導入の場合
cd ~/VRMFacialTracker
xcodegen generate              # アイコン / プライバシー / 署名設定を反映
open VRMFacialTracker.xcodeproj
```

Xcode で：

1. 左ペインでプロジェクト → **VRMTrackerPhone** ターゲット → **Signing & Capabilities**。
2. **Automatically manage signing** にチェック。
3. **Team** に加入した Developer アカウントを選択。
   - `Bundle Identifier` は `jp.chibatech.vrmtracker.phone`。App Store 全体で一意である必要があります。重複エラーが出たら末尾を変更（例 `jp.chibatech.<あなた>.vrmtracker.phone`）。
4. エラーが消え、Provisioning Profile が自動生成されれば OK。

> アイコン（`iOS/Resources/Assets.xcassets/AppIcon`）とプライバシーマニフェスト
> （`iOS/Resources/PrivacyInfo.xcprivacy`）、暗号化輸出申告（`ITSAppUsesNonExemptEncryption=false`）
> は設定済みです。独自アイコンに差し替える場合は `AppIcon-1024.png`（1024×1024・**透過なし**）を置き換えてください。

---

## 3. （任意）まず自分の実機で動作確認

1. iPhone を Mac に接続し、Xcode 上部のデバイス選択で実機を選ぶ。
2. ⌘R で実行 → 実機にインストール。
3. 初回は iPhone の「設定 → 一般 → VPN とデバイス管理」で開発者を信頼。
4. Mac 側（Unity アプリ）を起動し、iPhone アプリの歯車から Mac の IP を入力して接続確認。

---

## 4. App Store Connect にアプリを登録

加入承認後：

1. <https://appstoreconnect.apple.com> → **マイ App** → **＋** → **新規 App**。
2. 入力：
   - プラットフォーム：iOS
   - 名前：`VRM Tracker`（App Store 全体で一意。重複時は別名に）
   - プライマリ言語：日本語
   - バンドル ID：`jp.chibatech.vrmtracker.phone`（Xcode と一致させる）
   - SKU：任意（例 `vrmtracker001`）
3. 作成。

---

## 5. アーカイブしてアップロード

1. Xcode 上部のデバイス選択を **Any iOS Device (arm64)** にする（実機接続中なら実機でも可）。
2. メニュー **Product → Archive**（数分かかる）。
3. 完了すると **Organizer** が開く → 該当アーカイブを選び **Distribute App**。
4. **App Store Connect → Upload** を選択し、ウィザードを進める（自動署名のまま「Next」連打で可）。
5. アップロード完了。

> 暗号化の質問は `ITSAppUsesNonExemptEncryption=false` 設定済みのため**聞かれません**。

---

## 6. TestFlight でテスターに配布

1. App Store Connect → 対象 App → **TestFlight** タブ。
2. アップロードしたビルドが「処理中」→数分〜十数分で「テスト可能」になる。
3. **内部テスト（Internal Testing）**：
   - 「App Store Connect ユーザー」に追加したメンバー（最大 100 名）へすぐ配布可能。**審査不要**。
   - グループを作りビルドを割り当て、テスターを追加。
4. **外部テスト（External Testing）**：
   - 一般のメールアドレスへ配布（最大 10,000 名）。初回ビルドのみ簡易な**ベータ App 審査**が必要（通常 1 日以内）。
5. テスターは iPhone に **TestFlight アプリ**（App Store から無料）を入れ、招待メール/リンクからインストール。

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| Archive メニューが選べない | デバイスを「Any iOS Device」にする（シミュレータ選択中は不可） |
| 署名エラー | Team 未選択 / Bundle ID 重複。手順 2-3 を確認 |
| アイコン無しで弾かれる | `AppIcon-1024.png` が 1024×1024・透過なしか確認 |
| ビルドが TestFlight に出ない | 処理に時間がかかる。Connect のメール通知を待つ |
| 顔が動かない | TrueDepth 機種か、カメラ権限が許可されているか確認 |

---

## このアプリの構成（テスター向けメモ）

- iPhone：表情（52 BlendShapes）＋頭の向きを ARKit で取得し、同一 LAN 上の Mac へ送信。
- Mac（Unity アプリ）：VRM アバターを表示し、OBS にウィンドウキャプチャ＋クロマキーで取り込む。
- 腕・指は追跡せず、自然な立ち姿で固定（表情特化）。
