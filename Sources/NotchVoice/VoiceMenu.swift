import AppKit
import AVFoundation

@MainActor
final class VoiceMenu: NSObject {
    private let selectedID: String?
    private let onPick: (String?) -> Void

    init(selectedID: String?, onPick: @escaping (String?) -> Void) {
        self.selectedID = selectedID
        self.onPick = onPick
    }

    func popUp(at screenPoint: NSPoint) {
        makeMenu().popUp(positioning: nil, at: screenPoint, in: nil)
    }

    func makeMenu() -> NSMenu {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        let novelty = voices.filter { $0.voiceTraits.contains(.isNoveltyVoice) }
        let byLanguage = Dictionary(grouping: voices.filter { !$0.voiceTraits.contains(.isNoveltyVoice) }) {
            Self.languageCode($0.language)
        }
        var seen = Set<String>()
        let preferred = Locale.preferredLanguages.map(Self.languageCode).filter { byLanguage[$0] != nil && seen.insert($0).inserted }
        let others = byLanguage.keys
            .filter { !preferred.contains($0) }
            .sorted { Self.languageName($0) < Self.languageName($1) }

        let menu = Self.emptyMenu()
        menu.addItem(item(title: "System Voice", id: nil))
        for code in preferred {
            menu.addItem(.separator())
            addVoices(byLanguage[code]!, to: menu)
        }
        if !novelty.isEmpty || !others.isEmpty {
            menu.addItem(.separator())
        }
        if !novelty.isEmpty {
            menu.addItem(submenuItem(title: "Novelty") { submenu in
                for voice in Self.sorted(novelty) { submenu.addItem(item(for: voice)) }
            })
        }
        if !others.isEmpty {
            menu.addItem(submenuItem(title: "Other Languages") { submenu in
                for code in others {
                    submenu.addItem(submenuItem(title: Self.languageName(code)) { addVoices(byLanguage[code]!, to: $0) })
                }
            })
        }
        return menu
    }

    static func displayName(of identifier: String) -> String? {
        AVSpeechSynthesisVoice(identifier: identifier).map(displayName)
    }

    private func addVoices(_ voices: [AVSpeechSynthesisVoice], to menu: NSMenu) {
        let byLocale = Dictionary(grouping: voices, by: \.language)
        let locales = byLocale.keys.sorted { a, b in
            Self.rank(a) != Self.rank(b) ? Self.rank(a) < Self.rank(b) : Self.localeName(a) < Self.localeName(b)
        }
        for locale in locales {
            menu.addItem(.sectionHeader(title: Self.localeName(locale)))
            for voice in Self.sorted(byLocale[locale]!) { menu.addItem(item(for: voice)) }
        }
    }

    private func item(for voice: AVSpeechSynthesisVoice) -> NSMenuItem {
        item(title: Self.displayName(voice), id: voice.identifier)
    }

    private func item(title: String, id: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.state = id == selectedID ? .on : .off
        return item
    }

    private func submenuItem(title: String, build: (NSMenu) -> Void) -> NSMenuItem {
        let submenu = Self.emptyMenu()
        build(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.state = submenu.items.contains { $0.state == .on } ? .on : .off
        return item
    }

    @objc private func pick(_ item: NSMenuItem) {
        onPick(item.representedObject as? String)
    }

    private static func emptyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    private static func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        default: voice.name
        }
    }

    private static func sorted(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.sorted { a, b in
            a.quality != b.quality ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
        }
    }

    private static func rank(_ locale: String) -> Int {
        Locale.preferredLanguages.firstIndex(of: locale) ?? .max
    }

    private static func languageCode(_ identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" })
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private static func localeName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
