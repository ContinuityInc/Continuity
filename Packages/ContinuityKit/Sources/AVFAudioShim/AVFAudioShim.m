#import "AVFAudioShim.h"

NSErrorDomain const AVFAudioShimErrorDomain = @"com.continuity.AVFAudioShim";
NSString *const AVFAudioShimExceptionNameKey = @"AVFAudioShimExceptionName";
NSString *const AVFAudioShimExceptionReasonKey = @"AVFAudioShimExceptionReason";

BOOL AVFAudioShimTry(void (NS_NOESCAPE ^block)(void), NSError *__autoreleasing _Nullable *_Nullable error)
{
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[AVFAudioShimExceptionNameKey] = exception.name ?: @"";
            info[AVFAudioShimExceptionReasonKey] = exception.reason ?: @"";
            info[NSLocalizedDescriptionKey] =
                [NSString stringWithFormat:@"%@: %@", exception.name ?: @"NSException", exception.reason ?: @""];
            *error = [NSError errorWithDomain:AVFAudioShimErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
