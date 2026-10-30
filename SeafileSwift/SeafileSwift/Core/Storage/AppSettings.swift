import SwiftUI

enum AppSettingsKeys {
    static let biometricUnlock = "settings.biometricUnlock"
    static let rememberRepoPasswords = "settings.rememberRepoPasswords"
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let appearance = "settings.appearance"
        static let sortKey = "settings.sortKey"
        static let sortAscending = "settings.sortAscending"
        static let gridMode = "settings.gridMode"
        static let convertPhotosToJPEG = "settings.convertPhotosToJPEG"
    }

    var appearance: AppearancePreference {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var sortKey: DirentSortKey {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: Keys.sortKey) }
    }

    var sortAscending: Bool {
        didSet { UserDefaults.standard.set(sortAscending, forKey: Keys.sortAscending) }
    }

    var useGrid: Bool {
        didSet { UserDefaults.standard.set(useGrid, forKey: Keys.gridMode) }
    }

    var biometricUnlockEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricUnlockEnabled, forKey: AppSettingsKeys.biometricUnlock) }
    }

    var rememberRepoPasswords: Bool {
        didSet { UserDefaults.standard.set(rememberRepoPasswords, forKey: AppSettingsKeys.rememberRepoPasswords) }
    }

    var convertPhotosToJPEG: Bool {
        didSet { UserDefaults.standard.set(convertPhotosToJPEG, forKey: Keys.convertPhotosToJPEG) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        sortKey = DirentSortKey(rawValue: defaults.string(forKey: Keys.sortKey) ?? "") ?? .name
        sortAscending = defaults.object(forKey: Keys.sortAscending) as? Bool ?? true
        useGrid = defaults.object(forKey: Keys.gridMode) as? Bool ?? false
        biometricUnlockEnabled = defaults.object(forKey: AppSettingsKeys.biometricUnlock) as? Bool ?? false
        rememberRepoPasswords = defaults.object(forKey: AppSettingsKeys.rememberRepoPasswords) as? Bool ?? true
        convertPhotosToJPEG = defaults.object(forKey: Keys.convertPhotosToJPEG) as? Bool ?? false
    }
}
