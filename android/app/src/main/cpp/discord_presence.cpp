#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>
#include <jni.h>
#include <android/log.h>
#include <deque>
#include <memory>

namespace {
std::unique_ptr<discordpp::Client> client;
std::optional<discordpp::Activity> pending;
discordpp::StatusType onlineStatus = discordpp::StatusType::Online;
std::deque<std::string> events;
uint64_t generation = 0;
bool ready = false;
bool hasPending = false;

std::string text(JNIEnv* env, jstring value) {
    if (!value) return {};
    auto stringClass = env->FindClass("java/lang/String");
    auto getBytes = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    auto charset = env->NewStringUTF("UTF-8");
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, getBytes, charset));
    if (!bytes) { env->DeleteLocalRef(charset); env->DeleteLocalRef(stringClass); return {}; }
    std::string result(env->GetArrayLength(bytes), '\0');
    env->GetByteArrayRegion(bytes, 0, result.size(), reinterpret_cast<jbyte*>(result.data()));
    env->DeleteLocalRef(bytes); env->DeleteLocalRef(charset); env->DeleteLocalRef(stringClass);
    return result;
}
std::optional<std::string> optionalText(JNIEnv* env, jstring value) {
    return value ? std::optional<std::string>(text(env, value)) : std::nullopt;
}
void event(std::string value) {
    __android_log_print(ANDROID_LOG_INFO, "ZangetsuDiscord", "%s", value.c_str());
    if (events.size() == 32) events.pop_front();
    events.push_back(std::move(value));
}
void report(const discordpp::ClientResult& result, const char* operation) {
    if (result.Successful()) { event(std::string(operation) + ":ok"); return; }
    if (result.Status() == discordpp::HttpStatusCode::Unauthorized) event("authFailed");
    event(std::string(operation) + ":error=" + std::to_string(static_cast<int>(result.Type())) +
          ":http=" + std::to_string(static_cast<int>(result.Status())) + ":code=" + std::to_string(result.ErrorCode()));
}
void publish() {
    if (!client || !ready || !hasPending) return;
    const auto current = generation;
    client->SetOnlineStatus(onlineStatus, [current](discordpp::ClientResult result) {
        if (current == generation) report(result, "onlineStatus");
    });
    if (!pending) { client->ClearRichPresence(); event("cleared"); return; }
    client->UpdateRichPresence(*pending, [current](discordpp::ClientResult result) {
        if (current == generation) report(result, "published");
    });
}
jstring pollEvent(JNIEnv* env) {
    if (events.empty()) return nullptr;
    auto value = std::move(events.front()); events.pop_front();
    return env->NewStringUTF(value.c_str());
}
}

extern "C" JNIEXPORT void JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativeStart(JNIEnv* env, jobject, jlong appId, jstring token) {
    const auto current = ++generation;
    ready = false;
    client.reset();
    client = std::make_unique<discordpp::Client>();
    client->SetApplicationId(static_cast<uint64_t>(appId));
    client->SetStatusChangedCallback([current](discordpp::Client::Status status, discordpp::Client::Error error, int32_t detail) {
        if (current != generation || !client) return;
        ready = status == discordpp::Client::Status::Ready;
        event(std::string("connection:") + discordpp::Client::StatusToString(status) +
              ":error=" + std::to_string(static_cast<int>(error)) + ":detail=" + std::to_string(detail));
        if (ready) publish();
        if (detail == 4004) event("authFailed");
    });
    client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, text(env, token), [current](discordpp::ClientResult result) {
        if (current != generation || !client) return;
        report(result, "token");
        if (result.Successful()) client->Connect();
    });
}

extern "C" JNIEXPORT void JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativeUpdate(JNIEnv* env, jobject, jstring name, jint type,
    jstring details, jstring state, jstring large, jstring largeText, jstring small, jstring smallText,
    jlong start, jlong end, jobjectArray labels, jobjectArray urls, jstring status) {
    discordpp::Activity activity;
    activity.SetName(text(env, name));
    activity.SetType(static_cast<discordpp::ActivityTypes>(type));
    activity.SetDetails(optionalText(env, details));
    activity.SetState(optionalText(env, state));
    discordpp::ActivityAssets assets;
    assets.SetLargeImage(optionalText(env, large)); assets.SetLargeText(optionalText(env, largeText));
    assets.SetSmallImage(optionalText(env, small)); assets.SetSmallText(optionalText(env, smallText));
    activity.SetAssets(assets);
    if (start > 0 || end > 0) {
        discordpp::ActivityTimestamps timestamps;
        if (start > 0) timestamps.SetStart(start);
        if (end > 0) timestamps.SetEnd(end);
        activity.SetTimestamps(timestamps);
    }
    for (jsize i = 0; i < env->GetArrayLength(labels); ++i) {
        auto label = static_cast<jstring>(env->GetObjectArrayElement(labels, i));
        auto url = static_cast<jstring>(env->GetObjectArrayElement(urls, i));
        discordpp::ActivityButton button;
        button.SetLabel(text(env, label)); button.SetUrl(text(env, url));
        activity.AddButton(button);
        env->DeleteLocalRef(label); env->DeleteLocalRef(url);
    }
    const auto requested = text(env, status);
    onlineStatus = requested == "idle" ? discordpp::StatusType::Idle :
        requested == "dnd" ? discordpp::StatusType::Dnd :
        requested == "invisible" ? discordpp::StatusType::Invisible : discordpp::StatusType::Online;
    pending = std::move(activity); hasPending = true;
    publish();
}

extern "C" JNIEXPORT void JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativeClear(JNIEnv*, jobject) {
    pending.reset(); hasPending = true; publish();
}
extern "C" JNIEXPORT void JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativeClose(JNIEnv*, jobject) {
    ++generation; ready = false; hasPending = false; pending.reset();
    if (client) { client->ClearRichPresence(); client->Disconnect(); client.reset(); }
    events.clear();
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativePoll(JNIEnv* env, jobject) {
    discordpp::RunCallbacks(); return pollEvent(env);
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_spyou_watch_1app_DiscordPresenceBridge_nativePollEvent(JNIEnv* env, jobject) {
    return pollEvent(env);
}
