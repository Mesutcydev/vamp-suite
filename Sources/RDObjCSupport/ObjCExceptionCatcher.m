#import "ObjCExceptionCatcher.h"
#import <AVFAudio/AVFAudio.h>

BOOL RDExecuteIgnoringExceptions(void (^block)(void), NSException **outException) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outException) {
            *outException = exception;
        }
        return NO;
    }
}

BOOL RDAudioPlayerNodeStart(AVAudioPlayerNode *player, NSError **outError) {
    if (player == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"RDAudioPlayerNode"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"AVAudioPlayerNode is nil"}];
        }
        return NO;
    }

    @try {
        // macOS 27 / iOS 27 deprecate void -play in favor of -playAndReturnError:.
        // Resolve at runtime so this compiles against older SDKs too.
        SEL playAndReturnError = NSSelectorFromString(@"playAndReturnError:");
        if ([player respondsToSelector:playAndReturnError]) {
            typedef BOOL (*PlayAndReturnErrorIMP)(id, SEL, NSError **);
            PlayAndReturnErrorIMP imp = (PlayAndReturnErrorIMP)[player methodForSelector:playAndReturnError];
            return imp(player, playAndReturnError, outError);
        }

        [player play];
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"RDAudioPlayerNode"
                                            code:2
                                        userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"AVAudioPlayerNode play failed",
                @"exception.name": exception.name ?: @"",
            }];
        }
        return NO;
    }
}
