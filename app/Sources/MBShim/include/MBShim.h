#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, catching any Objective-C exception (which Swift cannot).
/// Returns YES on success; on an exception, fills `reason` and returns NO.
BOOL MBTryCatch(void (NS_NOESCAPE ^block)(void), NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
