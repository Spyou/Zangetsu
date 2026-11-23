#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN
@interface MpvTextureRegistry : NSObject <FlutterPluginRegistry>
- (instancetype)initWithRegistry:(NSObject<FlutterPluginRegistry> *)registry;
@property(nonatomic) int64_t observedTextureID;
@property(nonatomic, copy, nullable) void (^onFrame)(CVPixelBufferRef);
- (void)deliverCurrentFrame;
@end
NS_ASSUME_NONNULL_END
