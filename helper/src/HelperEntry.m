// helper/src/HelperEntry.m
#import "HelperEntry.h"

@implementation HelperEntry

+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID {
    return [bundleID isEqualToString:@"com.apple.MobileSMS"];
}

+ (void)load {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([self shouldActivateForBundleIdentifier:bundleID]) {
        NSLog(@"[imessage-max-helper] activating in %@", bundleID);
        // Listener wiring added in Task 4.
    }
}

@end
