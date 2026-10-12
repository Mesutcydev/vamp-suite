import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockService: ObservableObject {

    @AppStorage("client.security.appLockEnabled") var isEnabled = false {
        didSet {
            if isEnabled {
                lock()
            } else {
                isLocked = false
                authError = nil
            }
        }
    }

    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authError: String?
    @Published private(set) var biometryType: LABiometryType = .none

    private var backgroundedAt: Date?
    private let gracePeriod: TimeInterval = 15

    init() {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        biometryType = ctx.biometryType
        if isEnabled { isLocked = true }
    }

    func handleSceneBackground() {
        guard isEnabled, !isLocked else { return }
        backgroundedAt = Date()
    }

    func handleSceneActive() {
        guard isEnabled, !isLocked else { return }
        let elapsed = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed > gracePeriod { lock() }
        backgroundedAt = nil
    }

    func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"

        var nsError: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &nsError)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        do {
            let ok = try await ctx.evaluatePolicy(policy, localizedReason: "Unlock Vamp Control")
            if ok { isLocked = false }
        } catch let laErr as LAError {
            switch laErr.code {
            case .userCancel, .appCancel, .systemCancel:
                break
            case .biometryLockout:
                authError = "Too many attempts. Use passcode."
            case .biometryNotAvailable, .biometryNotEnrolled:
                authError = "Biometrics unavailable. Use passcode."
            default:
                authError = laErr.localizedDescription
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    private func lock() {
        isLocked = true
        authError = nil
    }
}
