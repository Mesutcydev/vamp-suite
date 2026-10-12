import CoreMedia
import Foundation
import VideoToolbox

/// Host-side probe for what this machine's video encoder can actually do.
public enum VideoEncoderCapabilities {
    /// `true` when a hardware HEVC encoder is available on this machine.
    ///
    /// Probed once and cached. The host advertises HEVC support based on this so it
    /// never negotiates HEVC into a slow software-encode path — or a session that
    /// can't be created at all — on Macs without a hardware HEVC encoder. This mirrors
    /// the client's `VTIsHardwareDecodeSupported` decode-side gate.
    public static let supportsHardwareHEVCEncode: Bool = detectHardwareHEVCEncode()

    private static func detectHardwareHEVCEncode() -> Bool {
        #if os(macOS)
        var listCF: CFArray?
        guard VTCopyVideoEncoderList(nil, &listCF) == noErr,
              let encoders = listCF as? [[String: Any]] else {
            return false
        }
        let codecKey = kVTVideoEncoderList_CodecType as String
        let hardwareKey = kVTVideoEncoderList_IsHardwareAccelerated as String
        for encoder in encoders {
            guard let codecNumber = encoder[codecKey] as? NSNumber,
                  codecNumber.uint32Value == kCMVideoCodecType_HEVC else { continue }
            if (encoder[hardwareKey] as? Bool) == true {
                return true
            }
        }
        return false
        #else
        // The host only runs on macOS; HEVC encode isn't offered on other platforms.
        return false
        #endif
    }
}
