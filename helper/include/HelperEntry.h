// helper/include/HelperEntry.h
#import <Foundation/Foundation.h>

@interface HelperEntry : NSObject
+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID;
@end
