import SharedModels
import SharedProtocol

/// A latency-bounded queue for remote input. Continuous input may supersede an
/// older unsent sample, while a button/key/text command is an ordering barrier.
struct MacRemoteInputSendQueue {
    private(set) var messages: [InputCommandMessage] = []

    var isEmpty: Bool { messages.isEmpty }

    mutating func enqueue(_ message: InputCommandMessage) {
        switch message.command {
        case .pointerMove:
            if let index = replaceableIndex(matching: {
                if case .pointerMove = $0.command {
                    return $0.sessionID == message.sessionID
                }
                return false
            }) {
                messages[index] = message
            } else {
                messages.append(message)
            }

        case .scroll(let incoming):
            if let index = replaceableIndex(matching: {
                if case .scroll = $0.command {
                    return $0.sessionID == message.sessionID
                }
                return false
            }), case .scroll(let queued) = messages[index].command {
                messages[index] = InputCommandMessage(
                    sessionID: message.sessionID,
                    command: .scroll(ScrollCommand(
                        deltaX: queued.deltaX + incoming.deltaX,
                        deltaY: queued.deltaY + incoming.deltaY,
                        isPrecise: queued.isPrecise && incoming.isPrecise
                    ))
                )
            } else {
                messages.append(message)
            }

        default:
            messages.append(message)
        }
    }

    mutating func popFirst() -> InputCommandMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    /// A release can finish an interaction already sent before control paused.
    /// Drop unsent actions but retain releases, in order, to avoid stuck keys.
    mutating func discardPendingInteractions() {
        messages.removeAll { message in
            switch message.command {
            case .key(let key): return key.action != .up
            case .pointerButton(let button): return button.action != .up
            default: return true
            }
        }
    }

    mutating func removeAll() {
        messages.removeAll(keepingCapacity: true)
    }

    /// Search only the continuous-input suffix. Discrete input forms a barrier,
    /// so a newer move can never jump across a click or key event.
    private func replaceableIndex(
        matching predicate: (InputCommandMessage) -> Bool
    ) -> Int? {
        for index in messages.indices.reversed() {
            switch messages[index].command {
            case .pointerMove, .scroll:
                if predicate(messages[index]) { return index }
            default:
                return nil
            }
        }
        return nil
    }
}
