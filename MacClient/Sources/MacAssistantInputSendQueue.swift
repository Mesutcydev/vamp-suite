/// A latency-bounded queue for Vamp Assistant's HTTP input transport.
/// Continuous input can replace an older unsent sample, while clicks and keys
/// remain ordering barriers.
struct MacAssistantInputSendQueue {
    private(set) var commands: [BeetCodeInputCommand] = []

    var isEmpty: Bool { commands.isEmpty }

    mutating func enqueue(_ command: BeetCodeInputCommand) {
        switch command {
        case .move:
            if let index = replaceableIndex(where: {
                if case .move = $0 { return true }
                return false
            }) {
                commands[index] = command
            } else {
                commands.append(command)
            }
        case let .relative(dx, dy):
            if let index = replaceableIndex(where: {
                if case .relative = $0 { return true }
                return false
            }), case let .relative(previousDX, previousDY) = commands[index] {
                commands[index] = .relative(dx: previousDX + dx, dy: previousDY + dy)
            } else {
                commands.append(command)
            }
        case let .scroll(x, y, dx, dy):
            if let index = replaceableIndex(where: {
                if case .scroll = $0 { return true }
                return false
            }), case let .scroll(previousX, previousY, previousDX, previousDY) = commands[index] {
                commands[index] = .scroll(
                    x: x ?? previousX,
                    y: y ?? previousY,
                    dx: previousDX + dx,
                    dy: previousDY + dy)
            } else {
                commands.append(command)
            }
        default:
            commands.append(command)
        }
    }

    mutating func popFirst() -> BeetCodeInputCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func discardPendingInteractions() {
        commands.removeAll { command in
            if case .up = command { return false }
            return true
        }
    }

    mutating func removeAll() {
        commands.removeAll(keepingCapacity: true)
    }

    private func replaceableIndex(
        where predicate: (BeetCodeInputCommand) -> Bool
    ) -> Int? {
        for index in commands.indices.reversed() {
            guard commands[index].isMotion else { return nil }
            if predicate(commands[index]) { return index }
        }
        return nil
    }
}
