// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import SwiftUI

nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case en
    case vi
    case zhHans = "zh-Hans"
    case ja
    case ko
    case es

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: return L10n.t("settings.language.system")
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        }
    }

    static func resolveSystemLanguageCode() -> String {
        for preferred in Locale.preferredLanguages {
            let lower = preferred.lowercased()
            if lower.hasPrefix("vi") { return "vi" }
            if lower.hasPrefix("zh") { return "zh-Hans" }
            if lower.hasPrefix("ja") { return "ja" }
            if lower.hasPrefix("ko") { return "ko" }
            if lower.hasPrefix("es") { return "es" }
            if lower.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    var resolvedLanguageCode: String {
        switch self {
        case .system: return Self.resolveSystemLanguageCode()
        case .en, .vi, .zhHans, .ja, .ko, .es: return rawValue
        }
    }

    var locale: Locale {
        Locale(identifier: resolvedLanguageCode)
    }
}

private nonisolated final class LockedLanguageStorage: @unchecked Sendable {
    static let storageKey = "dynarium.appLanguage"
    private let lock = NSLock()
    private var selectedLanguage: AppLanguage
    private var resolvedCode: String
    private var activeBundle: Bundle?
    private var englishBundle: Bundle?

    init() {
        let savedRaw = UserDefaults.standard.string(forKey: Self.storageKey)
        let lang = savedRaw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        let code = lang.resolvedLanguageCode
        self.selectedLanguage = lang
        self.resolvedCode = code
        self.englishBundle = Self.findBundle(for: "en")
        self.activeBundle = Self.findBundle(for: code) ?? self.englishBundle
    }

    func getLanguage() -> AppLanguage {
        lock.withLock { selectedLanguage }
    }

    func getResolvedCode() -> String {
        lock.withLock { resolvedCode }
    }

    func setLanguage(_ language: AppLanguage) {
        let code = language.resolvedLanguageCode
        let bundle = Self.findBundle(for: code) ?? englishBundle
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        lock.withLock {
            selectedLanguage = language
            resolvedCode = code
            activeBundle = bundle
        }
    }

    func string(forKey key: String) -> String {
        let (active, fallback) = lock.withLock {
            if activeBundle == nil {
                englishBundle = Self.findBundle(for: "en")
                activeBundle = Self.findBundle(for: resolvedCode) ?? englishBundle
            }
            return (activeBundle, englishBundle)
        }
        let sentinel = "__DYNARIUM_MISSING__"
        if let active {
            let value = active.localizedString(forKey: key, value: sentinel, table: nil)
            if value != sentinel {
                return value
            }
        }
        if let fallback {
            let value = fallback.localizedString(forKey: key, value: sentinel, table: nil)
            if value != sentinel {
                return value
            }
        }
        let mainValue = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        return mainValue != sentinel ? mainValue : key
    }

    private static func findBundle(for code: String) -> Bundle? {
        let candidates = [code, code.lowercased(), code.replacingOccurrences(of: "-", with: "_")]
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }
}

nonisolated enum L10n {
    private static let storage = LockedLanguageStorage()

    static var currentLanguage: AppLanguage {
        get { storage.getLanguage() }
        set { storage.setLanguage(newValue) }
    }

    static var resolvedLanguageCode: String {
        storage.getResolvedCode()
    }

    static func t(_ key: String) -> String {
        storage.string(forKey: key)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: Locale(identifier: resolvedLanguageCode), arguments: args)
    }
}

@MainActor
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()

    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            L10n.currentLanguage = language
            revision &+= 1
        }
    }

    @Published private(set) var revision: Int = 0

    private init() {
        self.language = L10n.currentLanguage
    }

    var locale: Locale {
        language.locale
    }

    func t(_ key: String) -> String {
        _ = revision
        return L10n.t(key)
    }

    func f(_ key: String, _ args: CVarArg...) -> String {
        _ = revision
        return String(format: L10n.t(key), locale: locale, arguments: args)
    }
}
