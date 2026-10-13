#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for exceptions caught by `AVFAudioShimTry`. `userInfo` carries
/// `AVFAudioShimExceptionNameKey` and `AVFAudioShimExceptionReasonKey`.
FOUNDATION_EXPORT NSErrorDomain const AVFAudioShimErrorDomain;
FOUNDATION_EXPORT NSString *const AVFAudioShimExceptionNameKey;
FOUNDATION_EXPORT NSString *const AVFAudioShimExceptionReasonKey;

/// Runs `block` inside an Objective-C `@try`. Returns YES when it completed normally. When the
/// block raises an `NSException` — the way AVFAudio reports a precondition failure such as
/// `AVAudioPlayerNode.play()` on a stopped engine (`_engine->IsRunning()`), a `play(at:)` start
/// time in the past, or `scheduleSegment` with an invalid frame range — the exception is caught,
/// described in `*error`, and NO is returned instead of the process aborting.
///
/// Swift cannot catch Objective-C exceptions at all: the unwinder finds no handler and the
/// runtime calls `abort()` — the `SIGABRT` "transient crash" class. Keep the block to a single
/// AVFAudio call with no Swift-side allocations, because Swift frames are not unwound cleanly.
FOUNDATION_EXPORT BOOL AVFAudioShimTry(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error)
    NS_SWIFT_NAME(AVFAudioShimTry(_:_:));

NS_ASSUME_NONNULL_END
