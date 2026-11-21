import Foundation
import SharedModels
import StoreKit

/// Vamp Pro: a one-time, non-consumable unlock that removes the daily streaming cap.
/// Each store app has its own App Store Connect IAP, matched here by platform.
@MainActor
final class StreamingUnlockStore: ObservableObject {
    static var productID: String {
        #if os(macOS)
        "com.vamp.desktop.unlimited"
        #else
        "com.vamp.remote.unlimited"
        #endif
    }

    /// Only store builds sell Pro. Website and sideload builds stay unlimited, as their Open Source copy says.
    static var isEnforced: Bool { VampProductIdentity.isStoreDistribution }

    @Published private(set) var product: Product?
    @Published private(set) var isPurchased = false
    @Published private(set) var isLoading = false
    @Published private(set) var debugUnlockEnabled = false
    @Published var purchaseError: String?
    @Published var purchaseNotice: String?

    private var updatesTask: Task<Void, Never>?

    /// Debug builds can simulate Pro without a purchase. Release builds never set `debugUnlockEnabled`.
    var isEffectivelyUnlocked: Bool { isPurchased || debugUnlockEnabled }

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refreshEntitlements() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            purchaseError = "Couldn’t load the Pro price. Check your connection and try again."
        }
        await refreshEntitlements()
    }

    func purchase() async {
        guard let product else {
            purchaseError = "Pro isn’t available right now. Try again in a moment."
            return
        }
        isLoading = true
        defer { isLoading = false }
        purchaseError = nil
        purchaseNotice = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseError = "The purchase couldn’t be verified."
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
            case .userCancelled:
                break
            case .pending:
                purchaseNotice = "Purchase is waiting for approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = "The purchase didn’t complete. Try again."
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        purchaseError = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseNotice = isPurchased ? nil : "No Pro purchase was found for this Apple ID."
        } catch {
            purchaseError = "Couldn’t restore purchases. Try again."
        }
    }

    func enableDebugUnlock() {
        #if DEBUG
        debugUnlockEnabled = true
        #endif
    }

    func disableDebugUnlock() {
        #if DEBUG
        debugUnlockEnabled = false
        #endif
    }

    private func refreshEntitlements() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPurchased = owned
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        await refreshEntitlements()
    }
}
