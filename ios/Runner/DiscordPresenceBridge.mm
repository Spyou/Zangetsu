#import "DiscordPresenceBridge.h"
#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>
#include <memory>

static NSString *stringValue(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}
static std::optional<std::string> sdkText(id value) {
  NSString *text = stringValue(value);
  return text ? std::optional<std::string>(text.UTF8String) : std::nullopt;
}

@implementation DiscordPresenceBridge {
  FlutterMethodChannel *_channel;
  NSTimer *_timer;
  std::unique_ptr<discordpp::Client> _client;
  std::optional<discordpp::Activity> _pending;
  discordpp::StatusType _onlineStatus;
  uint64_t _generation;
  BOOL _ready;
  BOOL _hasPending;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  if (self) {
    _channel = [FlutterMethodChannel methodChannelWithName:@"zangetsu/discord_presence"
                                         binaryMessenger:messenger];
    __weak DiscordPresenceBridge *weakSelf = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
      DiscordPresenceBridge *owner = weakSelf;
      if (owner) [owner handleCall:call result:result];
      else result(FlutterMethodNotImplemented);
    }];
  }
  return self;
}

- (void)report:(const discordpp::ClientResult &)result action:(NSString *)action {
  NSString *message = result.Successful() ? [action stringByAppendingString:@":ok"] :
    [NSString stringWithFormat:@"%@:error=%d:http=%d:code=%d", action,
      (int)result.Type(), (int)result.Status(), result.ErrorCode()];
  NSLog(@"[discord] SDK %@", message);
  [_channel invokeMethod:@"status" arguments:message];
  if (result.Status() == discordpp::HttpStatusCode::Unauthorized) {
    [_channel invokeMethod:@"authFailed" arguments:nil];
  }
}

- (void)publish {
  if (!_client || !_ready || !_hasPending) return;
  const auto generation = _generation;
  __weak DiscordPresenceBridge *weakSelf = self;
  _client->SetOnlineStatus(_onlineStatus, [weakSelf, generation](discordpp::ClientResult result) {
    DiscordPresenceBridge *owner = weakSelf;
    if (owner && owner->_generation == generation) [owner report:result action:@"onlineStatus"];
  });
  if (!_pending) { _client->ClearRichPresence(); return; }
  _client->UpdateRichPresence(*_pending, [weakSelf, generation](discordpp::ClientResult result) {
    DiscordPresenceBridge *owner = weakSelf;
    if (owner && owner->_generation == generation) [owner report:result action:@"published"];
  });
}

- (void)start:(uint64_t)applicationId token:(NSString *)token {
  const auto generation = ++_generation;
  _ready = NO;
  _client.reset();
  _client = std::make_unique<discordpp::Client>();
  _client->SetApplicationId(applicationId);
  __weak DiscordPresenceBridge *weakSelf = self;
  _client->SetStatusChangedCallback([weakSelf, generation](discordpp::Client::Status status, discordpp::Client::Error error, int32_t detail) {
    DiscordPresenceBridge *owner = weakSelf;
    if (!owner || owner->_generation != generation) return;
    owner->_ready = status == discordpp::Client::Status::Ready;
    NSString *message = [NSString stringWithFormat:@"connection:%s:error=%d:detail=%d",
        discordpp::Client::StatusToString(status).c_str(), (int)error, detail];
    NSLog(@"[discord] SDK %@", message);
    [owner->_channel invokeMethod:@"status" arguments:message];
    if (owner->_ready) [owner publish];
    if (detail == 4004) [owner->_channel invokeMethod:@"authFailed" arguments:nil];
  });
  _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, token.UTF8String,
    [weakSelf, generation](discordpp::ClientResult result) {
      DiscordPresenceBridge *owner = weakSelf;
      if (!owner || owner->_generation != generation || !owner->_client) return;
      [owner report:result action:@"token"];
      if (result.Successful()) owner->_client->Connect();
    });
  if (!_timer) {
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
      if (weakSelf) discordpp::RunCallbacks();
    }];
  }
}

- (void)handleCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"start"]) {
    NSString *token = stringValue(args[@"token"]);
    NSString *identifier = stringValue(args[@"applicationId"]);
    uint64_t appId = strtoull(identifier.UTF8String ?: "", nullptr, 10);
    if (!token.length || !appId) {
      result([FlutterError errorWithCode:@"DISCORD_SDK_ARGUMENTS" message:@"Application ID and token required" details:nil]); return;
    }
    [self start:appId token:token];
  } else if ([call.method isEqualToString:@"update"]) {
    NSDictionary *value = args[@"activity"];
    if (!_client || ![value isKindOfClass:NSDictionary.class]) {
      result([FlutterError errorWithCode:@"DISCORD_SDK_STATE" message:@"Discord SDK is not started" details:nil]); return;
    }
    NSDictionary *assets = [value[@"assets"] isKindOfClass:NSDictionary.class] ? value[@"assets"] : @{};
    NSDictionary *timestamps = [value[@"timestamps"] isKindOfClass:NSDictionary.class] ? value[@"timestamps"] : @{};
    discordpp::Activity activity;
    activity.SetName((stringValue(value[@"name"]) ?: @"Zangetsu").UTF8String);
    activity.SetType(static_cast<discordpp::ActivityTypes>([value[@"type"] intValue]));
    activity.SetDetails(sdkText(value[@"details"])); activity.SetState(sdkText(value[@"state"]));
    discordpp::ActivityAssets artwork;
    artwork.SetLargeImage(sdkText(assets[@"large_image"])); artwork.SetLargeText(sdkText(assets[@"large_text"]));
    artwork.SetSmallImage(sdkText(assets[@"small_image"])); artwork.SetSmallText(sdkText(assets[@"small_text"]));
    activity.SetAssets(artwork);
    uint64_t start = [timestamps[@"start"] unsignedLongLongValue];
    uint64_t end = [timestamps[@"end"] unsignedLongLongValue];
    if (start || end) {
      discordpp::ActivityTimestamps time;
      if (start) time.SetStart(start);
      if (end) time.SetEnd(end);
      activity.SetTimestamps(time);
    }
    NSArray *buttons = value[@"buttons"];
    NSDictionary *metadata = value[@"metadata"];
    NSArray *urls = metadata[@"button_urls"];
    if ([buttons isKindOfClass:NSArray.class] && [urls isKindOfClass:NSArray.class]) {
      for (NSUInteger i = 0; i < MIN(2, MIN(buttons.count, urls.count)); ++i) {
        NSString *label = stringValue(buttons[i]), *url = stringValue(urls[i]);
        if (!label || !url) continue;
        discordpp::ActivityButton button;
        button.SetLabel(label.UTF8String); button.SetUrl(url.UTF8String); activity.AddButton(button);
      }
    }
    NSString *status = stringValue(args[@"status"]);
    _onlineStatus = [status isEqualToString:@"idle"] ? discordpp::StatusType::Idle :
       [status isEqualToString:@"dnd"] ? discordpp::StatusType::Dnd :
       [status isEqualToString:@"invisible"] ? discordpp::StatusType::Invisible : discordpp::StatusType::Online;
    _pending = std::move(activity); _hasPending = YES;
    [self publish];
  } else if ([call.method isEqualToString:@"clear"]) {
    _pending.reset(); _hasPending = YES; [self publish];
  } else if ([call.method isEqualToString:@"close"]) {
    [self stop];
  } else { result(FlutterMethodNotImplemented); return; }
  result(nil);
}

- (void)stop {
  ++_generation;
  [_timer invalidate]; _timer = nil;
  _ready = NO; _hasPending = NO; _pending.reset();
  if (_client) { _client->ClearRichPresence(); _client->Disconnect(); _client.reset(); }
}
- (void)dispose { [self stop]; [_channel setMethodCallHandler:nil]; }
- (void)dealloc { [self stop]; }
@end
