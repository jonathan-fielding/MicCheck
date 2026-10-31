import Foundation

enum LightingError: LocalizedError {
    case invalidPacketSize
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPacketSize:
            return "Invalid packet size (must be 64 bytes)"
        case .sendFailed(let msg):
            return msg
        }
    }
}
