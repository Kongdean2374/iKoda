import Foundation

// Run by verify-localization.sh against the unpacked IPA in a bilingual probe app.
// This exercises Apple's locale fallback and compiled .strings/.stringsdict, not source catalogs.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
require(UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first == "zh-Hant-TW", "Probe language preference was not applied")
require(Bundle.main.preferredLocalizations.first == "zh-Hant", "Probe host does not support the requested language")
let path = CommandLine.arguments[1]
guard let app = Bundle(path: path) else { fatalError("Cannot open packaged app: \(path)") }
print("Preferred languages: \(Locale.preferredLanguages); host: \(Bundle.main.preferredLocalizations); app resources: \(app.localizations); app selection: \(app.preferredLocalizations)")
require(app.localizations.contains("zh-Hant"), "App lacks zh-Hant")
require(app.developmentLocalization == "en", "English must remain the development language")
require(app.preferredLocalizations.first == "zh-Hant", "zh-Hant-TW did not resolve to zh-Hant: \(app.preferredLocalizations)")
require(app.localizedString(forKey: "Home", value: nil, table: nil) == "首頁", "Home did not load in Traditional Chinese")
for (key, translated) in [("Sound Center", "音效中心"), ("Smart Shuffle", "智慧隨機播放"), ("Audio Information", "音訊資訊"),
                          ("Automatically Translate to Traditional Chinese", "自動翻譯為繁體中文"),
                          ("Retry Translation", "重新翻譯"), ("Custom Lyrics Sources", "自訂歌詞來源"),
                          ("Translation Ready", "翻譯已完成"), ("Translation Paused", "翻譯已暫停")] {
    require(app.localizedString(forKey: key, value: nil, table: nil) == translated, "Packaged feature translation missing: \(key)")
}
let permissions = app.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
require(permissions.contains("語音搜尋"), "Localized permission text is missing")
guard let widget = Bundle(path: path + "/PlugIns/KodaWidgets.appex") else { fatalError("Missing widget extension") }
require(widget.preferredLocalizations.first == "zh-Hant", "Widget locale fallback failed")
require(widget.localizedString(forKey: "Quick Play", value: nil, table: nil) == "快速播放", "Widget translation missing")
let enumerator = FileManager.default.enumerator(atPath: path)!
var coreFound = false
for case let relative as String in enumerator where relative.hasSuffix("KodaCore_KodaCore.bundle") {
    guard let core = Bundle(path: path + "/" + relative) else { continue }
    require(core.localizations.contains("zh-Hant"), "Core lacks zh-Hant")
    require(core.preferredLocalizations.first == "zh-Hant", "Core locale fallback failed")
    require(core.localizedString(forKey: "Bass Booster", value: nil, table: nil) == "低音增強", "Core translation missing")
    require(core.localizedString(forKey: "Original and Chinese", value: nil, table: nil) == "原文＋中文雙語", "Core lyrics mode translation missing")
    require(core.localizedString(forKey: "This playlist has no playable songs.", value: nil, table: nil) == "此播放清單沒有可播放的歌曲。", "Core playlist translation missing")
    require(core.localizedString(forKey: "The audio session could not be activated. Try playing again.", value: nil, table: nil) == "無法啟用音訊工作階段，請再次嘗試播放。", "Core audio-session translation missing")
    require(core.localizedString(forKey: "Plain lyrics as an additional fallback", value: nil, table: nil) == "找不到歌詞時提供純文字歌詞備援", "Core lyrics source translation missing")
    coreFound = true
}
require(coreFound, "Packaged KodaCore resource bundle missing")
print("PASS: packaged app, widget and KodaCore select zh-Hant for zh-Hant-TW; translated UI and permission strings load.")
