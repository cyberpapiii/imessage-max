#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@protocol IMCoreFacade <NSObject>
- (nullable NSString *)createChatWithAddresses:(NSArray<NSString *> *)addresses
                                       service:(NSString *)service
                                         error:(NSString **)errCode;
- (BOOL)sendText:(NSString *)body toChatGuid:(NSString *)guid error:(NSString **)errCode;
- (BOOL)sendFileAtPath:(NSString *)path toChatGuid:(NSString *)guid error:(NSString **)errCode;
@end

NS_ASSUME_NONNULL_END
