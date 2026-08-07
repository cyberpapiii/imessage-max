#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface HelperRequest : NSObject
@property (nonatomic) NSInteger v;
@property (nonatomic, copy) NSString *reqId;
@property (nonatomic, copy) NSString *cmd;
@property (nonatomic, copy, nullable) NSArray<NSString *> *addresses;
@property (nonatomic, copy, nullable) NSString *service;
@property (nonatomic, copy, nullable) NSString *chatGuid;
@property (nonatomic, copy, nullable) NSString *body;
@property (nonatomic, copy, nullable) NSString *path;
@end

@interface HelperResponse : NSObject
@property (nonatomic) NSInteger v;
@property (nonatomic, copy) NSString *reqId;
@property (nonatomic) BOOL ok;
@property (nonatomic, copy, nullable) NSString *chatGuid;
@property (nonatomic, copy, nullable) NSString *errorCode;
@property (nonatomic, copy, nullable) NSString *errorMessage;
+ (instancetype)okWithId:(NSString *)reqId chatGuid:(nullable NSString *)chatGuid;
+ (instancetype)errorWithId:(NSString *)reqId code:(NSString *)code message:(NSString *)message;
@end

@interface HelperWire : NSObject
+ (nullable HelperRequest *)decodeRequestLine:(NSData *)line error:(NSString * _Nullable * _Nonnull)errId;
+ (NSData *)encodeResponse:(HelperResponse *)resp;
@end

NS_ASSUME_NONNULL_END
