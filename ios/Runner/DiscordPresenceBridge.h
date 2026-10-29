#import <Flutter/Flutter.h>

@interface DiscordPresenceBridge : NSObject
- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)dispose;
@end
