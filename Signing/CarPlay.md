# Koda 0.6.3 CarPlay 測試與簽署

## 使用未簽署 IPA

以平常的側載方式簽署並安裝 IPA。iPhone 需要 iOS 26 或更新版本。開啟 Koda 一次後，將 iPhone 連到相容的 CarPlay 車機。在停車時開啟 iPhone「設定」→「一般」→「CarPlay」→ 你的車輛 →「小工具」，選擇「新增小工具」並搜尋「Koda 播放器」。部分車輛提供不同的 CarPlay 配置或由系統隱藏小工具選項。

一般側載簽署可以測試 Live Activity。若簽署沒有可用的 App Group，Koda 播放器小工具會顯示預設唱片和通用播放圖示。Apple 只允許支援觸控且具正式 CarPlay 整合的 App 在車機小工具執行按鈕操作。未授權的環境可使用 CarPlay 系統「正在播放」或車機原本的播放鍵控制 Koda。iPhone 小工具使用同一組音訊 App Intents。

## 開啟 Koda 歌詞

1. 播放一首歌並開啟 Koda 的播放頁。
2. 點右上「⋯」→「CarPlay 歌詞延遲」→「開啟 Koda 歌詞」。
3. 在 iPhone 鎖定畫面點「顯示歌詞」，依系統提示驗證身分。
4. 若 CarPlay 沒顯示，確認 iPhone 已允許 Koda 的即時動態，並在 CarPlay「設定」啟用「即時動態」。查看 CarPlay 儀表板。
5. 回到同一設定頁可結束活動，或在鎖定畫面移除。

可在歌曲播放頁調整該首的延遲。正值較晚、負值較早，原文及譯文一起移動。App 正在播放且可執行時，會按歌曲時間更新目前句子。ActivityKit 與車機可能合併或延後更新。暫時失去更新時畫面可出現等待提示。裝置端翻譯使用 Koda 既有快取和系統語言模型，語言模型未準備好時先顯示原文。車機沒有歌詞按鈕，請在 iPhone 操作。

## 開啟封面與車機觸控控制

需要具 Apple Developer Program 權限的開發團隊。由團隊帳號註冊一個唯一的 App Group，並指派給 App 和 Widget 兩個 App ID。兩個 Target 的 `KODA_CARPLAY_APP_GROUP` 建置設定應填入相同識別碼。確保 Widget 的 Bundle Identifier 是主 App 識別碼加上 `.Widgets`，若需要使用團隊自己的 App ID，只在本機建置設定覆寫。

- **封面與狀態**使用 App Groups。可在 Xcode 兩個 Target 的 **Signing & Capabilities** 加入同一個組合，並更新各自的 provisioning profile。也可以使用 `Signing/KodaWidgets-CarPlay.entitlements` 作為 Widget 的 Code Signing Entitlements，並為主 App 配置相同的 App Groups entitlement。
- **車機 Widget 觸控**另需要 Apple 核准 CarPlay Audio 並把權限加入主 App ID 和 provisioning profile。主 App 可使用 `Signing/Koda-CarPlay.entitlements` 作為 Code Signing Entitlements。只有主 App 需要 CarPlay Audio，Widget 需要 App Group。若只具 App Group 權限，請在 Xcode 啟用 App Groups，保留 Apple 核准後再配置 CarPlay Audio。
- 設定各 Target 的開發團隊與相符的憑證及 provisioning profile，由 Xcode 安裝至 iPhone。保留兩個 Target 的相同版本號。專案中的 entitlements 範本供本機使用，CI 的未簽署 IPA 不會替團隊取得這些權限。

[Apple 的 CarPlay 小工具說明](https://support.apple.com/guide/iphone/customize-widgets-in-carplay-iphb4d6a0bbb/ios) · [CarPlay 即時動態](https://support.apple.com/guide/iphone/view-live-activities-iph3d92302ee/ios) · [CarPlay 觸控條件](https://developer.apple.com/documentation/widgetkit/adding-standby-and-carplay-support-to-your-widget) · [CarPlay 授權設定](https://developer.apple.com/documentation/carplay/preparing-your-ios-app-for-carplay-development) · [App Groups 設定](https://developer.apple.com/documentation/xcode/configuring-app-groups)
