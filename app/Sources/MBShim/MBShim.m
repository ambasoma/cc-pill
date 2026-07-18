#import "include/MBShim.h"

BOOL MBTryCatch(void (NS_NOESCAPE ^block)(void), NSString **reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"?"];
        }
        return NO;
    }
}
