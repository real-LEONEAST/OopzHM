import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { DEFAULT_MIC_GAIN } from '../store/AppStore';
import {
  AudioVolumeInfo, ChannelMediaOptions, Constants, IRtcEngineEventHandler, LogConfig, RtcEngine, RtcEngineConfig,
  RtcStats
} from '@shengwang/rtc-voice';

export type { AudioVolumeInfo };

export interface RtcRoom {
  appId: string;
  channel: string;
  uid: number;
  token: string;
}

export interface RtcCallEvents {
  connected: () => void;
  reconnecting: () => void;
  connectionFailed: (reason: number) => void;
  microphoneChanged: (capturing: boolean, reason: number) => void;
  peerCountChanged: (count: number) => void;
  peerJoined?: (uid: number) => void;
  peerOffline?: (uid: number) => void;
  audioStats: (sentKbps: number, receivedKbps: number) => void;
  tokenExpiring: () => void;
  error: (code: number) => void;
  volumeIndication?: (speakers: AudioVolumeInfo[], totalVolume: number) => void;
  userMuteAudio?: (uid: number, muted: boolean) => void;
}

export class NativeRtcCall {
  private engine?: RtcEngine;
  private generation: number = 0;
  private joinedCue: string = '';
  private leftCue: string = '';

  static sdkVersion(): string {
    return RtcEngine.getSdkVersion();
  }

  start(context: common.UIAbilityContext, room: RtcRoom, events: RtcCallEvents, liveRoom: boolean = false,
    micGain: number = DEFAULT_MIC_GAIN): void {
    const generation = ++this.generation;
    const isCurrent = (): boolean => generation === this.generation;
    const peers = new Set<number>();
    const handler: IRtcEngineEventHandler = {
      onJoinChannelSuccess: () => {
        if (isCurrent()) {
          events.connected();
        }
      },
      onRejoinChannelSuccess: () => {
        if (isCurrent()) {
          events.connected();
        }
      },
      onConnectionStateChanged: (state: Constants.ConnectionState, reason: Constants.ConnectionChangedReason) => {
        if (!isCurrent()) {
          return;
        }
        if (state === Constants.ConnectionState.RECONNECTING) {
          events.reconnecting();
        } else if (state === Constants.ConnectionState.FAILED) {
          events.connectionFailed(reason);
        }
      },
      onLocalAudioStateChanged: (state: Constants.LocalAudioStreamState, reason: Constants.LocalAudioStreamReason) => {
        if (isCurrent()) {
          const capturing = state === Constants.LocalAudioStreamState.RECORDING ||
            state === Constants.LocalAudioStreamState.ENCODING;
          events.microphoneChanged(capturing, reason);
        }
      },
      onUserJoined: (uid: number) => {
        if (isCurrent()) {
          peers.add(uid);
          events.peerCountChanged(peers.size);
          events.peerJoined?.(uid);
        }
      },
      onUserOffline: (uid: number) => {
        if (isCurrent()) {
          peers.delete(uid);
          events.peerCountChanged(peers.size);
          events.peerOffline?.(uid);
        }
      },
      onRtcStats: (stats: RtcStats) => {
        if (isCurrent()) {
          events.audioStats(stats.txAudioKBitRate, stats.rxAudioKBitRate);
        }
      },
      onTokenPrivilegeWillExpire: () => {
        if (isCurrent()) {
          events.tokenExpiring();
        }
      },
      onRequestToken: () => {
        if (isCurrent()) {
          events.connectionFailed(Constants.ConnectionChangedReason.TOKEN_EXPIRED);
        }
      },
      onError: (code: Constants.ErrorCode) => {
        if (isCurrent()) {
          events.error(code);
        }
      },
      onAudioVolumeIndication: (speakers: Array<AudioVolumeInfo>, totalVolume: number) => {
        if (isCurrent()) {
          events.volumeIndication?.(speakers, totalVolume);
        }
      },
      onUserMuteAudio: (uid: number, muted: boolean) => {
        if (isCurrent()) {
          events.userMuteAudio?.(uid, muted);
        }
      },
      onRemoteAudioStateChanged: (uid: number, _state: Constants.RemoteAudioStreamState,
        reason: Constants.RemoteAudioStreamReason, _elapsed: number) => {
        if (!isCurrent()) return;
        if (reason === Constants.RemoteAudioStreamReason.REMOTE_MUTED) events.userMuteAudio?.(uid, true);
        if (reason === Constants.RemoteAudioStreamReason.REMOTE_UNMUTED) events.userMuteAudio?.(uid, false);
      }
    };

    const config = new RtcEngineConfig(context, room.appId, handler);
    const logs = new LogConfig();
    logs.level = Constants.LogLevel.NONE;
    config.mLogConfig = logs;
    const engine = RtcEngine.create(config);
    this.engine = engine;
    const audio = engine.enableAudio();
    if (audio !== 0) {
      throw new Error(`启用原生音频失败（${audio}）`);
    }
    engine.enableAudioVolumeIndication(200, 2, true);
    engine.setAudioProfile(Constants.AudioProfileType.SPEECH_STANDARD);
    engine.setAudioScenario(Constants.AudioScenarioType.CHATROOM);
    engine.adjustRecordingSignalVolume(micGain);
    this.joinedCue = this.copyCue(context, 'voice-join.wav');
    this.leftCue = this.copyCue(context, 'voice-leave.wav');

    const options = new ChannelMediaOptions();
    options.channelProfile = liveRoom ? Constants.ChannelProfile.LIVE_BROADCASTING :
      Constants.ChannelProfile.COMMUNICATION;
    options.clientRoleType = Constants.ClientRole.BROADCASTER;
    options.publishCameraTrack = false;
    options.publishMicrophoneTrack = true;
    options.autoSubscribeAudio = true;
    options.autoSubscribeVideo = false;
    const result = engine.joinChannelWithOptions(room.token, room.channel, room.uid, options);
    if (result !== 0) {
      throw new Error(`原生 SDK 拒绝进房（${result}）`);
    }
  }

  setMicrophone(enabled: boolean): number {
    return this.engine?.enableLocalAudio(enabled) ?? -1;
  }

  setSpeakerMuted(muted: boolean): number {
    const result = this.engine?.adjustPlaybackSignalVolume(muted ? 0 : 100) ?? -1;
    if (muted && result === 0) {
      this.engine?.stopEffect(1);
      this.engine?.stopEffect(2);
    }
    return result;
  }

  playRoomCue(joined: boolean): void {
    const path = joined ? this.joinedCue : this.leftCue;
    if (path.length > 0) this.engine?.playEffect(joined ? 1 : 2, path, 0, 1, 0, 42, false);
  }

  private copyCue(context: common.UIAbilityContext, name: string): string {
    try {
      const data = context.resourceManager.getRawFileContentSync(name);
      const path = `${context.cacheDir}/${name}`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
      } finally {
        fileIo.closeSync(file);
      }
      return path;
    } catch {
      return '';
    }
  }

  setUserVolume(uid: number, volume: number): number {
    return this.engine?.adjustUserPlaybackSignalVolume(uid, volume) ?? -1;
  }

  setRecordingVolume(volume: number): number {
    return this.engine?.adjustRecordingSignalVolume(volume) ?? -1;
  }

  muteRemoteUser(uid: number, muted: boolean): number {
    return this.engine?.muteRemoteAudioStream(uid, muted) ?? -1;
  }

  renewToken(token: string): number {
    return this.engine?.renewToken(token) ?? -1;
  }

  async close(): Promise<void> {
    this.generation++;
    const engine = this.engine;
    this.engine = undefined;
    if (engine !== undefined) {
      try {
        engine.leaveChannel();
      } finally {
        await RtcEngine.destroy();
      }
    }
  }
}
