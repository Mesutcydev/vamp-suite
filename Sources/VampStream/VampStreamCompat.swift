import Combine
import SwiftUI

// `onChangeCompat` normally lives in ClientiOSApp.swift, which this target excludes (Vamp Stream
// has its own @main). Several shared ClientiOS views depend on it, so provide the same helper
// here — scoped to the Vamp Stream module, so there is no duplicate with Vamp Control.
private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    @State private var previousValue: Value?

    func body(content: Content) -> some View {
        content.onReceive(Just(value)) { newValue in
            guard let previousValue else {
                self.previousValue = newValue
                return
            }
            guard previousValue != newValue else { return }
            self.previousValue = newValue
            action(newValue)
        }
    }
}

extension View {
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        modifier(OnChangeCompatModifier(value: value, action: action))
    }
}
