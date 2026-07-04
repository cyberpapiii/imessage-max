#import <Foundation/Foundation.h>
#import "IMCoreFacade.h"
#import "HelperWire.h"
NS_ASSUME_NONNULL_BEGIN

@interface HelperDispatcher : NSObject
- (instancetype)initWithFacade:(id<IMCoreFacade>)facade;
- (HelperResponse *)handle:(HelperRequest *)req;
@end

NS_ASSUME_NONNULL_END
