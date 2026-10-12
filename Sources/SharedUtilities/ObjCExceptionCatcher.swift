import Foundation
import RDObjCSupport

#if canImport(AVFAudio)
import AVFAudio
#endif

/// Swift façade over the ObjC `@try/@catch` helpers in `RDObjCSupport`.
public enum ObjCExceptionCatcher {
    /// Runs `body`, converting unexpected `NSException`s into a returned exception.
    @discardableResult
    public static func execute(_ body: () -> Void) -> NSException? {
        var exception: NSException?
        let succeeded = RDExecuteIgnoringExceptions({
            body()
        }, &exception)
        return succeeded ? nil : exception
    }

#if canImport(AVFAudio)
    /// Starts playback on `player` without letting AVFAudio ObjC exceptions escape.
    public static func startAudioPlayerNode(_ player: AVAudioPlayerNode) throws {
        var error: NSError?
        guard RDAudioPlayerNodeStart(player, &error) else {
            throw error ?? NSError(
                domain: "RDAudioPlayerNode",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayerNode failed to start"]
            )
        }
    }
#endif
}
