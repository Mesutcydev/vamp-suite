import Foundation

/// Converts macOS virtual key codes to the names accepted by Vamp Assistant's
/// `/api/control/input` endpoint.
enum MacAssistantKeyMapping {
    static func name(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: "return"
        case 48: "tab"
        case 51: "backspace"
        case 53: "escape"
        case 117: "forward_delete"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 115: "home"
        case 119: "end"
        case 116: "page_up"
        case 121: "page_down"
        default: nil
        }
    }
}
