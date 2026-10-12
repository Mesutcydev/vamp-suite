#import <Foundation/Foundation.h>

@class AVAudioPlayerNode;

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside `@try/@catch`. Returns YES on success.
/// On failure, fills `outException` (when non-null) and returns NO.
FOUNDATION_EXPORT BOOL RDExecuteIgnoringExceptions(
    NS_NOESCAPE void (^block)(void),
    NSException *_Nullable *_Nullable outException
);

/// Starts an `AVAudioPlayerNode`, preferring `playAndReturnError:` when present
/// (macOS 27+ / iOS 27+) and catching ObjC exceptions that bypass NSError.
FOUNDATION_EXPORT BOOL RDAudioPlayerNodeStart(
    AVAudioPlayerNode *player,
    NSError *_Nullable *_Nullable outError
);

NS_ASSUME_NONNULL_END
