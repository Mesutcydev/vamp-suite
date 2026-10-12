import SwiftUI
import LocalAuthentication

struct AppLockView: View {
    @ObservedObject var lockService: AppLockService

    var body: some View {
        ZStack {
            PR.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                PRScreenHeader(
                    title: "locked",
                    host: "vamp host · auth required",
                    state: .idle
                )

                Spacer()

                VStack(spacing: 28) {
                    ZStack {
                        Circle()
                            .fill(PR.bg2)
                            .overlay(Circle().strokeBorder(PR.border))
                            .frame(width: 88, height: 88)
                        Image(systemName: biometryIcon)
                            .font(.system(size: 36, weight: .ultraLight))
                            .foregroundColor(PR.accent)
                    }

                    VStack(spacing: 6) {
                        Text("authentication required")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(PR.fg)
                        Text(biometryLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(PR.dim)
                    }

                    if let err = lockService.authError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(PR.err)
                        .frame(maxWidth: 260)
                        .multilineTextAlignment(.leading)
                    }

                    Button {
                        Task { await lockService.authenticate() }
                    } label: {
                        HStack(spacing: 8) {
                            if lockService.isAuthenticating {
                                ProgressView().tint(PR.bg).scaleEffect(0.8)
                            } else {
                                Image(systemName: biometryIcon)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text(lockService.isAuthenticating ? "verifying…" : "authenticate")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(PR.bg)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 14)
                        .background(PR.accent)
                        .clipShape(RoundedRectangle(cornerRadius: PR.r8))
                    }
                    .buttonStyle(.plain)
                    .disabled(lockService.isAuthenticating)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .task {
            await lockService.authenticate()
        }
    }

    private var biometryIcon: String {
        switch lockService.biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        default:       return "lock.fill"
        }
    }

    private var biometryLabel: String {
        switch lockService.biometryType {
        case .faceID:  return "use face id to unlock"
        case .touchID: return "use touch id to unlock"
        default:       return "tap to authenticate"
        }
    }
}
