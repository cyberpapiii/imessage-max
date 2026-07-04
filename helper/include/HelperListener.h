#import <Foundation/Foundation.h>
#import "HelperDispatcher.h"
NS_ASSUME_NONNULL_BEGIN

@interface HelperListener : NSObject
+ (NSString *)resolveSocketPath;
- (instancetype)initWithDispatcher:(HelperDispatcher *)dispatcher;
- (void)serveConnectionFD:(int)fd;
- (BOOL)bindAndListenAtPath:(NSString *)path error:(NSString **)err;
- (void)acceptLoop;
@end

NS_ASSUME_NONNULL_END
