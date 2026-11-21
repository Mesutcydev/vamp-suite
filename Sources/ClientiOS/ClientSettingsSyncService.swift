import Foundation
import SharedModels

protocol ClientSettingsSyncing: AnyObject {
    func load() -> SessionFeatureSettings
    func hasPersistedSettings() -> Bool
    func save(_ settings: SessionFeatureSettings)
    func observeRemoteChanges(_ handler: @escaping @Sendable (SessionFeatureSettings) -> Void)
}

final class ClientSettingsSyncService: ClientSettingsSyncing {
    private enum Keys {
        static let featureSettings = "com.mesutcy.remotedesktop.terminal.featureSettings"
    }

    private let defaults: UserDefaults
    private let cloudStore: NSUbiquitousKeyValueStore?
    private var observer: NSObjectProtocol?
    private var changeHandler: (@Sendable (SessionFeatureSettings) -> Void)?

    private static var defaultCloudStore: NSUbiquitousKeyValueStore? {
        #if DIRECTDIST
        // Website and sideload builds intentionally carry no iCloud entitlement.
        // Initializing the default KVS store without that entitlement produces a
        // launch-time client fault, so keep settings local for this channel.
        nil
        #else
        // Both Stream editions use local preferences and carry no iCloud KVS
        // entitlement. Avoid a launch-time Apple Account prompt or client fault.
        if Bundle.main.bundleIdentifier == "com.mesutcy.remotedesktop.stream" { return nil }
        return NSUbiquitousKeyValueStore.default
        #endif
    }

    init(
        defaults: UserDefaults = .standard,
        cloudStore: NSUbiquitousKeyValueStore? = ClientSettingsSyncService.defaultCloudStore
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func load() -> SessionFeatureSettings {
        if let data = defaults.data(forKey: Keys.featureSettings) {
            do {
                return try JSONDecoder().decode(SessionFeatureSettings.self, from: data)
            } catch {
                CrashSafeStartupDiagnostics.error("settings.local.decode", error: error)
                defaults.removeObject(forKey: Keys.featureSettings)
            }
        }

        if let cloudStore,
           let data = cloudStore.data(forKey: Keys.featureSettings) {
            do {
                let decoded = try JSONDecoder().decode(SessionFeatureSettings.self, from: data)
                persistLocally(decoded)
                return decoded
            } catch {
                CrashSafeStartupDiagnostics.error("settings.cloud.decode", error: error)
                cloudStore.removeObject(forKey: Keys.featureSettings)
            }
        }

        return SessionFeatureSettings()
    }

    func hasPersistedSettings() -> Bool {
        if defaults.data(forKey: Keys.featureSettings) != nil {
            return true
        }

        if let cloudStore,
           cloudStore.data(forKey: Keys.featureSettings) != nil {
            return true
        }

        return false
    }

    func save(_ settings: SessionFeatureSettings) {
        persistLocally(settings)
        persistToCloud(settings)
    }

    func observeRemoteChanges(_ handler: @escaping @Sendable (SessionFeatureSettings) -> Void) {
        changeHandler = handler
        guard observer == nil, let cloudStore else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            guard
                let self,
                let data = self.cloudStore?.data(forKey: Keys.featureSettings)
            else {
                return
            }

            do {
                let decoded = try JSONDecoder().decode(SessionFeatureSettings.self, from: data)
                self.persistLocally(decoded)
                self.changeHandler?(decoded)
            } catch {
                CrashSafeStartupDiagnostics.error("settings.cloud.observe", error: error)
                self.cloudStore?.removeObject(forKey: Keys.featureSettings)
            }
        }
    }

    private func persistLocally(_ settings: SessionFeatureSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Keys.featureSettings)
    }

    private func persistToCloud(_ settings: SessionFeatureSettings) {
        guard
            let cloudStore,
            let data = try? JSONEncoder().encode(settings)
        else {
            return
        }

        cloudStore.set(data, forKey: Keys.featureSettings)
        cloudStore.synchronize()
    }
}
