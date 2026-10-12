import SwiftUI

/// Full-screen-friendly sheet showing Bluetooth input device status,
/// live modifier-key state, and sensitivity controls.
struct BluetoothInputStatusView: View {
    @ObservedObject var controller: BluetoothInputController
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    deviceCard
                    if controller.isKeyboardConnected {
                        modifierCard
                    }
                    if controller.isMouseConnected {
                        sensitivityCard
                    }
                    helpCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(PR.bg)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("bluetooth input")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(PR.fg)
                    Text("keyboard · mouse")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(PR.dim)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(PR.fg)
                        .frame(width: 30, height: 30)
                        .background(PR.bg2, in: Circle())
                        .overlay(Circle().strokeBorder(PR.border))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            Divider().overlay(PR.border)
        }
    }

    // MARK: - Device card

    private var deviceCard: some View {
        PRCard("devices") {
            deviceRow(
                icon: "keyboard",
                label: "keyboard",
                name: controller.keyboardName,
                connected: controller.isKeyboardConnected
            )
            Divider().overlay(PR.border)
            deviceRow(
                icon: "computermouse",
                label: "mouse",
                name: controller.mouseName,
                connected: controller.isMouseConnected
            )
        }
    }

    private func deviceRow(icon: String, label: String, name: String, connected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(connected ? PR.accent : PR.dim)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(PR.fg)
                Text(connected ? name : "not connected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(connected ? PR.dim : PR.dim.opacity(0.5))
            }
            Spacer()
            statusDot(connected: connected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusDot(connected: Bool) -> some View {
        Circle()
            .fill(connected ? PR.accent : PR.dim.opacity(0.3))
            .frame(width: 8, height: 8)
    }

    // MARK: - Modifier key state card

    private var modifierCard: some View {
        PRCard("active modifiers") {
            HStack(spacing: 8) {
                modifierPill("⌘ cmd",  active: controller.activeModifiers.contains(.command))
                modifierPill("⇧ shift", active: controller.activeModifiers.contains(.shift))
                modifierPill("⌥ opt",  active: controller.activeModifiers.contains(.option))
                modifierPill("⌃ ctrl", active: controller.activeModifiers.contains(.control))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func modifierPill(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(active ? PR.bg : PR.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? PR.accent : PR.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? PR.accent.opacity(0.4) : PR.border))
    }

    // MARK: - Sensitivity card

    private var sensitivityCard: some View {
        PRCard("sensitivity") {
            VStack(spacing: 0) {
                sensitivityRow(
                    label: "pointer",
                    icon: "cursorarrow.motionlines",
                    value: $controller.mouseSensitivity
                )
                Divider().overlay(PR.border)
                sensitivityRow(
                    label: "scroll",
                    icon: "scroll",
                    value: $controller.scrollSensitivity
                )
            }
        }
    }

    private func sensitivityRow(label: String, icon: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(PR.dim)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(PR.fg)
                Spacer()
                Text(String(format: "%.1f×", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(PR.accent)
            }
            Slider(value: value, in: 0.25...3.0, step: 0.25)
                .tint(PR.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Help card

    private var helpCard: some View {
        PRCard("pairing") {
            VStack(alignment: .leading, spacing: 8) {
                helpLine("Pair your Bluetooth keyboard or mouse in iOS Settings → Bluetooth.")
                helpLine("Once connected it is detected automatically — no setup needed here.")
                helpLine("Modifier keys (⌘ ⇧ ⌥ ⌃) are tracked live and combined with keystrokes.")
                helpLine("Mouse movement uses relative delta — works regardless of iPhone orientation.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func helpLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(PR.dim)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PR.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
