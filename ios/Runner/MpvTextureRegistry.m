#import "MpvTextureRegistry.h"

// The video plugin gets the same Flutter registrar, with a texture sink that
// can also forward frames from one selected texture to the system player.
@interface MpvTextureRegistrar : NSObject
@property(nonatomic, strong) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) NSObject<FlutterTextureRegistry> *textureRegistry;
@end

@implementation MpvTextureRegistrar
- (NSObject<FlutterTextureRegistry> *)textures { return self.textureRegistry; }
- (id)forwardingTargetForSelector:(SEL)selector { return self.registrar; }
@end

@interface MpvTextureRegistry () <FlutterTextureRegistry>
@property(nonatomic, weak) NSObject<FlutterPluginRegistry> *registry;
@property(nonatomic, weak) NSObject<FlutterTextureRegistry> *textures;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSObject<FlutterTexture> *> *outputs;
@end

@implementation MpvTextureRegistry
- (instancetype)initWithRegistry:(NSObject<FlutterPluginRegistry> *)registry {
    if ((self = [super init])) {
        _registry = registry;
        _outputs = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSObject<FlutterPluginRegistrar> *)registrarForPlugin:(NSString *)key {
    NSObject<FlutterPluginRegistrar> *registrar = [self.registry registrarForPlugin:key];
    if (![key isEqualToString:@"MediaKitVideoPlugin"] || !registrar) return registrar;
    self.textures = [registrar textures];
    MpvTextureRegistrar *proxy = [MpvTextureRegistrar new];
    proxy.registrar = registrar;
    proxy.textureRegistry = self;
    return (NSObject<FlutterPluginRegistrar> *)proxy;
}

- (BOOL)hasPlugin:(NSString *)key { return [self.registry hasPlugin:key]; }
- (NSObject *)valuePublishedByPlugin:(NSString *)key {
    return [self.registry valuePublishedByPlugin:key];
}

- (int64_t)registerTexture:(NSObject<FlutterTexture> *)texture {
    int64_t identifier = [self.textures registerTexture:texture];
    if (identifier != 0) self.outputs[@(identifier)] = texture;
    return identifier;
}

- (void)textureFrameAvailable:(int64_t)identifier {
    [self.textures textureFrameAvailable:identifier];
    if (identifier == self.observedTextureID) [self deliverCurrentFrame];
}

- (void)unregisterTexture:(int64_t)identifier {
    [self.textures unregisterTexture:identifier];
    [self.outputs removeObjectForKey:@(identifier)];
}

- (void)deliverCurrentFrame {
    if (!self.onFrame) return;
    CVPixelBufferRef frame = [self.outputs[@(self.observedTextureID)] copyPixelBuffer];
    if (!frame) return;
    self.onFrame(frame);
    CVPixelBufferRelease(frame);
}
@end
