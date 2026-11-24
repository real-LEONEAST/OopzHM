import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Constants } from '@shengwang/rtc-voice';
import bridge from 'liboopz_voip_trial.so';
import type { AudioVolumeInfo, RtcCallEvents, RtcRoom } from './NativeRtcCall';

const TAG = 'OopzVoipTrial';
const STREAM: audio.AudioStreamInfo = {
  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
  channels: audio.AudioChannel.CHANNEL_1,
  sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
  encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
};

enum RtcSignal {
  PeerJoined,
  PeerOffline,
  PeerMuted,
  VolumeIndication
}

function loadCue(context: common.UIAbilityContext, name: string): Int16Array {
  try {
    const bytes = context.resourceManager.getRawFileContentSync(name);
    const wave = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    // The built-in cues are 24 kHz mono PCM16 with a standard WAV header.
    if (wave.byteLength < 44 || wave.getUint32(36) !== 0x64617461 || wave.getUint16(20, true) !== 1 ||
      wave.getUint16(22, true) !== 1 || wave.getUint32(24, true) !== 24000 || wave.getUint16(34, true) !== 16) {
      return new Int16Array(0);
    }
    const sampleCount = Math.floor(Math.min(wave.getUint32(40, true), wave.byteLength - 44) / 2);
    const samples = new Int16Array(sampleCount * 2);
    for (let i = 0; i < sampleCount; i++) {
      const current = wave.getInt16(44 + i * 2, true);
      const next = i + 1 < sampleCount ? wave.getInt16(46 + i * 2, true) : 0;
      samples[i * 2] = Math.round(current * 0.42);
      samples[i * 2 + 1] = Math.round((current + next) * 0.21);
    }
    return samples;
  } catch {
    return new Int16Array(0);
  }
}

function scalePcm(buffer: ArrayBuffer, gain: number): void {
  if (gain === 100) return;
  const pcm = new Int16Array(buffer);
  for (let i = 0; i < pcm.length; i++) {
    pcm[i] = Math.max(-32768, Math.min(32767, Math.round(pcm[i] * gain / 100)));
  }
}

export class CppVoipTrial {
  private readonly events: RtcCallEvents;
  private readonly joinCue: Int16Array;
  private readonly leaveCue: Int16Array;
  private activeCue?: Int16Array;
  private cueOffset: number = 0;
  private capturer?: audio.AudioCapturer;
  private renderer?: audio.AudioRenderer;
  private startup?: Promise<boolean>;
  private microphoneChange: Promise<void> = Promise.resolve();
  private closing: boolean = false;
  private joined: boolean = false;
  private timer: number = -1;
  private lastState: number = -1;
  private lastPeers: number = -1;
  private captureGain: number;
  private outputMuted: boolean = false;
  private pushes: number = 0;
  private pulls: number = 0;
  private peak: number = 0;
  private pushError: number = 0;
  private pullError: number = 0;

  constructor(context: common.UIAbilityContext, events: RtcCallEvents, micGain: number) {
    this.events = events;
    this.captureGain = micGain;
    this.joinCue = loadCue(context, 'voice-join.wav');
    this.leaveCue = loadCue(context, 'voice-leave.wav');
  }

  start(room: RtcRoom, liveRoom: boolean): Promise<boolean> {
    this.startup = this.open(room, liveRoom);
    return this.startup;
  }

  private async open(room: RtcRoom, liveRoom: boolean): Promise<boolean> {
    try {
      await this.openSystemAudio();
    } catch (error) {
      hilog.warn(0x0, TAG, 'System call audio setup failed code=%{public}d', (error as BusinessError).code);
      return false;
    }
    if (this.closing) return false;
    const codes = bridge.join(room.appId, room.channel, room.uid, room.token, liveRoom,
      (signal: number[]) => { this.onRtcSignal(signal); });
    hilog.info(0x0, TAG, 'C++ init=%{public}d media=%{public}d sink=%{public}d track=%{public}d sdkMic=%{public}d join=%{public}d',
      codes[0], codes[1], codes[2], codes[3], codes[4], codes[5]);
    // Only retry with standard audio when the bridge has not submitted an RTC join.
    if (codes.slice(0, 5).some((code: number): boolean => code !== 0)) return false;
    if (codes[5] !== 0) throw new Error(`原生 SDK 拒绝进房（${codes[5]}）`);
    this.joined = true;
    this.events.microphoneChanged(true, 0);
    this.poll();
    this.timer = setInterval(() => { this.poll(); }, 2000);
    return true;
  }

  private async openSystemAudio(): Promise<void> {
    const renderer = await audio.createAudioRenderer({
      streamInfo: STREAM,
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 }
    });
    this.renderer = renderer;
    if (this.closing) return;
    renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
      if (this.closing || !this.joined) {
        new Uint8Array(buffer).fill(0);
      } else {
        const peak = bridge.pull(buffer);
        if (peak < 0) {
          this.pullError = peak;
        } else {
          this.pulls++;
          this.peak = Math.max(this.peak, peak);
        }
        if (this.outputMuted) {
          new Uint8Array(buffer).fill(0);
        } else {
          this.mixCue(buffer);
        }
      }
      return audio.AudioDataCallbackResult.VALID;
    });
    await renderer.start();
    if (this.closing) return;

    const capturer = await audio.createAudioCapturer({
      streamInfo: STREAM,
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
    });
    this.capturer = capturer;
    if (this.closing) return;
    capturer.on('readData', (buffer: ArrayBuffer) => {
      if (this.closing || !this.joined) return;
      scalePcm(buffer, this.captureGain);
      const pushed = bridge.push(buffer);
      if (pushed < 0) {
        this.pushError = pushed;
      } else {
        this.pushes += pushed;
      }
    });
    await capturer.start();
    if (this.closing) return;
    await this.reportSystemStreams(capturer, renderer);
  }

  private async reportSystemStreams(capturer: audio.AudioCapturer, renderer: audio.AudioRenderer): Promise<void> {
    try {
      const captureId = await capturer.getAudioStreamId();
      const playbackId = await renderer.getAudioStreamId();
      if (this.closing) return;
      hilog.info(0x0, TAG, 'C++ system streams capture=%{public}d playback=%{public}d', captureId, playbackId);
      this.events.systemStreams?.(captureId, playbackId);
    } catch (error) {
      hilog.warn(0x0, TAG, 'System stream IDs unavailable code=%{public}d', (error as BusinessError).code);
    }
  }

  private onRtcSignal(signal: number[]): void {
    if (this.closing || signal.length < 2) return;
    switch (signal[0]) {
      case RtcSignal.PeerJoined:
        this.events.peerJoined?.(signal[1]);
        break;
      case RtcSignal.PeerOffline:
        this.events.peerOffline?.(signal[1]);
        break;
      case RtcSignal.PeerMuted:
        this.events.userMuteAudio?.(signal[1], signal[2] === 1);
        break;
      case RtcSignal.VolumeIndication: {
        const speakers: AudioVolumeInfo[] = [];
        for (let i = 2; i + 3 < signal.length; i += 4) {
          speakers.push({ uid: signal[i], volume: signal[i + 1], vad: signal[i + 2], voicePitch: signal[i + 3] });
        }
        this.events.volumeIndication?.(speakers, signal[1]);
        break;
      }
    }
  }

  private poll(): void {
    const stats = bridge.stats();
    const state = stats[0];
    const reason = stats[1];
    const peers = Math.max(0, stats[2]);
    if (state !== this.lastState) {
      this.lastState = state;
      if (state === Constants.ConnectionState.CONNECTED) this.events.connected();
      if (state === Constants.ConnectionState.RECONNECTING) this.events.reconnecting();
      if (state === Constants.ConnectionState.FAILED) this.events.connectionFailed(reason);
    }
    if (peers !== this.lastPeers) {
      this.lastPeers = peers;
      this.events.peerCountChanged(peers);
    }
    this.events.audioStats(stats[3], stats[4]);
    if (stats[5] !== 0) this.events.error(stats[5]);
    if (stats[6] === 1) this.events.tokenExpiring();
    if (stats[6] === 2) this.events.connectionFailed(Constants.ConnectionChangedReason.TOKEN_EXPIRED);
    hilog.info(0x0, TAG, 'C++ PCM pushed=%{public}d pulls=%{public}d peak=%{public}d pushError=%{public}d pullError=%{public}d peers=%{public}d tx=%{public}d rx=%{public}d',
      this.pushes, this.pulls, this.peak, this.pushError, this.pullError, peers, stats[3], stats[4]);
    this.peak = 0;
  }

  setMicrophone(enabled: boolean): number {
    const capturer = this.capturer;
    if (capturer === undefined || this.closing) return -1;
    this.microphoneChange = this.microphoneChange.then(async (): Promise<void> => {
      if (this.closing || enabled === (capturer.state === audio.AudioState.STATE_RUNNING)) return;
      if (enabled) {
        await capturer.start();
        if (this.renderer !== undefined) await this.reportSystemStreams(capturer, this.renderer);
      } else {
        await capturer.stop();
      }
      if (!this.closing) this.events.microphoneChanged(enabled, 0);
    }).catch((error: BusinessError) => {
      hilog.warn(0x0, TAG, 'C++ system microphone change failed code=%{public}d', error.code);
    });
    return 0;
  }

  setSpeakerMuted(muted: boolean): number {
    this.outputMuted = muted;
    if (muted) this.activeCue = undefined;
    return 0;
  }

  playRoomCue(joined: boolean): void {
    if (this.outputMuted || this.closing) return;
    this.activeCue = joined ? this.joinCue : this.leaveCue;
    this.cueOffset = 0;
  }

  private mixCue(buffer: ArrayBuffer): void {
    const cue = this.activeCue;
    if (cue === undefined) return;
    const output = new Int16Array(buffer);
    const count = Math.min(output.length, cue.length - this.cueOffset);
    for (let i = 0; i < count; i++) {
      output[i] = Math.max(-32768, Math.min(32767, output[i] + cue[this.cueOffset + i]));
    }
    this.cueOffset += count;
    if (this.cueOffset >= cue.length) this.activeCue = undefined;
  }

  setRecordingVolume(volume: number): number {
    this.captureGain = volume;
    return 0;
  }

  setUserVolume(uid: number, volume: number): number {
    return bridge.setRemoteVolume(uid, volume);
  }

  muteRemoteUser(uid: number, muted: boolean): number {
    return bridge.muteRemote(uid, muted);
  }

  renewToken(token: string): number {
    return bridge.renewToken(token);
  }

  async close(): Promise<void> {
    this.closing = true;
    clearInterval(this.timer);
    await this.startup?.catch(() => {});
    await this.microphoneChange;
    await this.capturer?.release().catch(() => {});
    await this.renderer?.release().catch(() => {});
    bridge.close();
  }
}
