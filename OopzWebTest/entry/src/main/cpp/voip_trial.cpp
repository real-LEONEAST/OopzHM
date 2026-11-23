#include "IAgoraRtcEngine.h"
#include "IAgoraMediaEngine.h"
#include "napi/native_api.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <string>
#include <vector>

namespace {
using namespace agora::rtc;
using agora::media::IAudioFrameObserverBase;
using agora::media::IMediaEngine;

constexpr int sampleRate = 48000;
constexpr int samplesPerFrame = sampleRate / 100;
constexpr size_t bytesPerFrame = samplesPerFrame * sizeof(int16_t);
constexpr track_id_t invalidTrack = static_cast<track_id_t>(-1);
constexpr int skipped = -999;

enum RtcSignal {
    PeerJoined,
    PeerOffline,
    PeerMuted,
    VolumeIndication
};

void CallSignal(napi_env env, napi_value callback, void*, void* data) {
    const std::unique_ptr<std::vector<double>> signal(static_cast<std::vector<double>*>(data));
    if (!env || !callback || !signal) return;
    napi_value argument;
    napi_create_array_with_length(env, signal->size(), &argument);
    uint32_t index = 0;
    for (const auto value : *signal) {
        napi_value entry;
        napi_create_double(env, value, &entry);
        napi_set_element(env, argument, index++, entry);
    }
    napi_value receiver;
    napi_get_undefined(env, &receiver);
    napi_call_function(env, receiver, callback, 1, &argument, nullptr);
}

class Events final : public IRtcEngineEventHandler {
public:
    std::atomic<int> peers{0};
    std::atomic<int> tx{0};
    std::atomic<int> rx{0};
    std::atomic<int> reason{0};
    std::atomic<int> error{0};
    std::atomic<int> expiry{0};
    std::atomic<napi_threadsafe_function> signalCallback{nullptr};

    void onUserJoined(uid_t uid, int) override {
        ++peers;
        send({PeerJoined, static_cast<double>(uid)});
    }
    void onUserOffline(uid_t uid, USER_OFFLINE_REASON_TYPE) override {
        --peers;
        send({PeerOffline, static_cast<double>(uid)});
    }
    void onUserMuteAudio(uid_t uid, bool muted) override {
        send({PeerMuted, static_cast<double>(uid), muted ? 1.0 : 0.0});
    }
    void onRemoteAudioStateChanged(uid_t uid, REMOTE_AUDIO_STATE, REMOTE_AUDIO_STATE_REASON reason, int) override {
        if (reason == REMOTE_AUDIO_REASON_REMOTE_MUTED || reason == REMOTE_AUDIO_REASON_REMOTE_UNMUTED) {
            onUserMuteAudio(uid, reason == REMOTE_AUDIO_REASON_REMOTE_MUTED);
        }
    }
    void onAudioVolumeIndication(const AudioVolumeInfo* speakers, unsigned int count, int total) override {
        std::vector<double> signal{VolumeIndication, static_cast<double>(total)};
        if (speakers) {
            signal.reserve(2 + 4 * count);
            for (unsigned int i = 0; i < count; ++i) {
                signal.emplace_back(speakers[i].uid);
                signal.emplace_back(speakers[i].volume);
                signal.emplace_back(speakers[i].vad);
                signal.emplace_back(speakers[i].voicePitch);
            }
        }
        send(std::move(signal));
    }
    void onRtcStats(const RtcStats& stats) override {
        tx = stats.txAudioKBitRate;
        rx = stats.rxAudioKBitRate;
    }
    void onConnectionStateChanged(CONNECTION_STATE_TYPE, CONNECTION_CHANGED_REASON_TYPE value) override {
        reason = value;
    }
    void onError(int code, const char*) override { error = code; }
    void onTokenPrivilegeWillExpire(const char*) override { expiry = 1; }
    void onRequestToken() override { expiry = 2; }

private:
    void send(std::vector<double> signal) {
        const auto callback = signalCallback.load();
        if (!callback) return;
        auto pending = std::make_unique<std::vector<double>>(std::move(signal));
        if (napi_call_threadsafe_function(callback, pending.get(), napi_tsfn_nonblocking) == napi_ok) {
            pending.release();
        }
    }
};

Events events;
IRtcEngine* engine = nullptr;
IMediaEngine* media = nullptr;
track_id_t track = invalidTrack;
std::string activeAppId;
std::array<uint8_t, bytesPerFrame> capture{};
std::array<int16_t, samplesPerFrame> playback{};
size_t captured = 0;
size_t played = bytesPerFrame;

napi_value Int(napi_env env, int number) {
    napi_value result;
    napi_create_int32(env, number, &result);
    return result;
}

napi_value Values(napi_env env, std::initializer_list<int> numbers) {
    napi_value result;
    napi_create_array_with_length(env, numbers.size(), &result);
    uint32_t index = 0;
    for (const auto number : numbers) {
        napi_set_element(env, result, index++, Int(env, number));
    }
    return result;
}

std::string String(napi_env env, napi_value value) {
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) return {};
    std::string content(size + 1, '\0');
    napi_get_value_string_utf8(env, value, content.data(), content.size(), &size);
    content.resize(size);
    return content;
}

void CloseCall() {
    if (engine) {
        engine->leaveChannel();
        if (media) {
            if (track != invalidTrack) media->destroyCustomAudioTrack(track);
            media->release();
        }
        engine->release(true);
    }
    if (const auto callback = events.signalCallback.exchange(nullptr)) {
        napi_release_threadsafe_function(callback, napi_tsfn_release);
    }
    engine = nullptr;
    media = nullptr;
    track = invalidTrack;
    captured = 0;
    played = bytesPerFrame;
    activeAppId.clear();
}

napi_value Join(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t uid = 0;
    bool liveRoom = false;
    if (argc != 6 || napi_get_value_uint32(env, args[2], &uid) != napi_ok ||
        napi_get_value_bool(env, args[4], &liveRoom) != napi_ok || engine) {
        return Values(env, {-2, skipped, skipped, skipped, skipped, skipped});
    }
    napi_value resourceName;
    napi_create_string_utf8(env, "OopzVoiceSignals", NAPI_AUTO_LENGTH, &resourceName);
    napi_threadsafe_function callback = nullptr;
    if (napi_create_threadsafe_function(env, args[5], nullptr, resourceName, 32, 1, nullptr, nullptr,
        nullptr, CallSignal, &callback) != napi_ok) {
        return Values(env, {-1, skipped, skipped, skipped, skipped, skipped});
    }
    events.signalCallback = callback;
    napi_unref_threadsafe_function(env, callback);
    activeAppId = String(env, args[0]);
    const auto channel = String(env, args[1]);
    const auto token = String(env, args[3]);
    const auto profile = liveRoom ? agora::CHANNEL_PROFILE_LIVE_BROADCASTING : agora::CHANNEL_PROFILE_COMMUNICATION;
    events.peers = events.tx = events.rx = events.reason = events.error = events.expiry = 0;
    engine = createAgoraRtcEngine();
    if (!engine) return Values(env, {-1, skipped, skipped, skipped, skipped, skipped});

    RtcEngineContext context;
    context.appId = activeAppId.c_str();
    context.eventHandler = &events;
    context.channelProfile = profile;
    context.logConfig.level = agora::commons::LOG_LEVEL::LOG_LEVEL_NONE;
    const int init = engine->initialize(context);
    if (init != 0) return Values(env, {init, skipped, skipped, skipped, skipped, skipped});

    void* mediaInterface = nullptr;
    const int query = engine->queryInterface(AGORA_IID_MEDIA_ENGINE, &mediaInterface);
    if (query != 0 || !mediaInterface) {
        return Values(env, {init, query != 0 ? query : -1, skipped, skipped, skipped, skipped});
    }
    media = static_cast<IMediaEngine*>(mediaInterface);
    const int sink = media->setExternalAudioSink(true, sampleRate, 1);
    if (sink != 0) return Values(env, {init, query, sink, skipped, skipped, skipped});

    AudioTrackConfig trackConfig;
    trackConfig.enableLocalPlayback = false;
    track = media->createCustomAudioTrack(AUDIO_TRACK_DIRECT, trackConfig);
    if (track == invalidTrack) return Values(env, {init, query, sink, -1, skipped, skipped});
    const int localAudio = engine->enableLocalAudio(false);
    if (localAudio != 0) return Values(env, {init, query, sink, 0, localAudio, skipped});
    engine->enableAudioVolumeIndication(200, 2, true);

    ChannelMediaOptions options;
    options.channelProfile = profile;
    options.clientRoleType = CLIENT_ROLE_BROADCASTER;
    options.publishCameraTrack = false;
    options.publishMicrophoneTrack = false;
    options.publishCustomAudioTrack = true;
    options.publishCustomAudioTrackId = track;
    options.autoSubscribeAudio = true;
    options.autoSubscribeVideo = false;
    options.enableAudioRecordingOrPlayout = false;
    const int joined = engine->joinChannel(token.c_str(), channel.c_str(), uid, options);
    return Values(env, {init, query, sink, 0, localAudio, joined});
}

IAudioFrameObserverBase::AudioFrame MakeFrame(void* buffer) {
    IAudioFrameObserverBase::AudioFrame frame{};
    frame.type = IAudioFrameObserverBase::FRAME_TYPE_PCM16;
    frame.samplesPerChannel = samplesPerFrame;
    frame.bytesPerSample = TWO_BYTES_PER_SAMPLE;
    frame.channels = 1;
    frame.samplesPerSec = sampleRate;
    frame.buffer = buffer;
    return frame;
}

uint8_t* Buffer(napi_env env, napi_callback_info info, size_t& length) {
    size_t argc = 1;
    napi_value arg;
    void* buffer = nullptr;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    if (argc != 1 || napi_get_arraybuffer_info(env, arg, &buffer, &length) != napi_ok) return nullptr;
    return static_cast<uint8_t*>(buffer);
}

napi_value Push(napi_env env, napi_callback_info info) {
    size_t length = 0;
    const auto* buffer = Buffer(env, info, length);
    if (!buffer || !media || track == invalidTrack) return Int(env, -1);
    int frames = 0;
    for (size_t offset = 0; offset < length;) {
        const auto size = std::min(bytesPerFrame - captured, length - offset);
        std::memcpy(capture.data() + captured, buffer + offset, size);
        captured += size;
        offset += size;
        if (captured != bytesPerFrame) continue;
        auto frame = MakeFrame(capture.data());
        const int result = media->pushAudioFrame(&frame, track);
        captured = 0;
        if (result != 0) return Int(env, result);
        ++frames;
    }
    return Int(env, frames);
}

napi_value Pull(napi_env env, napi_callback_info info) {
    size_t length = 0;
    auto* buffer = Buffer(env, info, length);
    if (!buffer) return Int(env, -1);
    std::memset(buffer, 0, length);
    if (!media) return Int(env, -1);
    int peak = 0;
    for (size_t offset = 0; offset < length;) {
        if (played == bytesPerFrame) {
            playback.fill(0);
            auto frame = MakeFrame(playback.data());
            const int result = media->pullAudioFrame(&frame);
            if (result != 0) return Int(env, result);
            if (frame.buffer && frame.buffer != playback.data()) {
                const int samples = std::clamp(frame.samplesPerChannel, 0, samplesPerFrame);
                std::memcpy(playback.data(), frame.buffer, samples * sizeof(int16_t));
            }
            for (const int sample : playback) peak = std::max(peak, std::abs(sample));
            played = 0;
        }
        const auto size = std::min(bytesPerFrame - played, length - offset);
        std::memcpy(buffer + offset, reinterpret_cast<const uint8_t*>(playback.data()) + played, size);
        offset += size;
        played += size;
    }
    return Int(env, peak);
}

napi_value Stats(napi_env env, napi_callback_info) {
    return Values(env, {engine ? static_cast<int>(engine->getConnectionState()) : 0,
                        events.reason.load(), events.peers.load(), events.tx.load(), events.rx.load(),
                        events.error.exchange(0), events.expiry.exchange(0)});
}

napi_value RenewToken(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    if (!engine || argc != 1) return Int(env, -1);
    const auto token = String(env, arg);
    return Int(env, engine->renewToken(token.c_str()));
}

napi_value MuteRemote(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    uint32_t uid = 0;
    bool mute = false;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engine || argc != 2 || napi_get_value_uint32(env, args[0], &uid) != napi_ok ||
        napi_get_value_bool(env, args[1], &mute) != napi_ok) return Int(env, -1);
    return Int(env, engine->muteRemoteAudioStream(uid, mute));
}

napi_value SetRemoteVolume(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    uint32_t uid = 0;
    int volume = 0;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engine || argc != 2 || napi_get_value_uint32(env, args[0], &uid) != napi_ok ||
        napi_get_value_int32(env, args[1], &volume) != napi_ok) return Int(env, -1);
    return Int(env, engine->adjustUserPlaybackSignalVolume(uid, volume));
}

napi_value Close(napi_env env, napi_callback_info) {
    CloseCall();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    const napi_property_descriptor methods[] = {
        {"join", nullptr, Join, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"push", nullptr, Push, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pull", nullptr, Pull, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renewToken", nullptr, RenewToken, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"muteRemote", nullptr, MuteRemote, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRemoteVolume", nullptr, SetRemoteVolume, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "oopz_voip_trial", nullptr, {0}};
}

extern "C" __attribute__((constructor)) void RegisterOopzVoipTrial() {
    napi_module_register(&module);
}
