import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { VoiceMode } from '../common/VoiceMode';

const TAG = 'OopzAudioRoute';
// HarmonyOS can report the separate NearLink microphone descriptor on a phone.
const NEARLINK_INPUT_TYPE = 32;

export class VoiceRouteStatus {
  input: string = '';
  output: string = '';
  usage?: audio.StreamUsage;
  source?: audio.SourceType;
  pickerType?: 'audio' | 'voice_call';
  independentInput: boolean = false;
  mediaInput: boolean = false;
  voipStreams: boolean = false;
  acousticEchoCancelerSupported?: boolean;
}

export interface VoiceCallCard {
  title: string;
  domain: string;
  avatar: string;
}

export function isCallUsage(usage?: audio.StreamUsage): boolean {
  return usage === audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION ||
    usage === audio.StreamUsage.STREAM_USAGE_VIDEO_COMMUNICATION;
}

export function volumeLabel(usage?: audio.StreamUsage): string {
  if (usage === undefined || usage === audio.StreamUsage.STREAM_USAGE_UNKNOWN) return '等待播放流';
  return isCallUsage(usage) ? '通话音量' : '媒体音量';
}

export function voiceDeviceName(device: audio.AudioDeviceDescriptor | undefined): string {
  if (device === undefined) return '';
  switch (device.deviceType) {
    case audio.DeviceType.SPEAKER: return '扬声器';
    case audio.DeviceType.EARPIECE: return '听筒';
    case audio.DeviceType.MIC: return '内置麦克风';
    case audio.DeviceType.INVALID:
    case audio.DeviceType.DEFAULT: return '';
  }
  if (device.displayName || device.name) return device.displayName || device.name;
  switch (device.deviceType) {
    case audio.DeviceType.BLUETOOTH_SCO:
    case audio.DeviceType.BLUETOOTH_A2DP: return '蓝牙设备';
    case audio.DeviceType.WIRED_HEADSET:
    case audio.DeviceType.WIRED_HEADPHONES: return '有线耳机';
    case audio.DeviceType.USB_HEADSET:
    case audio.DeviceType.USB_DEVICE: return 'USB 音频设备';
    case audio.DeviceType.NEARLINK: return '星闪音频设备';
    case audio.DeviceType.REMOTE_CAST:
    case audio.DeviceType.REMOTE_DAUDIO: return '跨设备音频';
    default: return '系统音频设备';
  }
}

function externalInputName(name: string): string {
  const trimmed = name.trim();
  return trimmed === deviceInfo.marketName || trimmed === deviceInfo.productModel ? '' : trimmed;
}

function voiceInputName(input: audio.AudioDeviceDescriptor | undefined, output: audio.AudioDeviceDescriptor | undefined,
  followsCallOutput: boolean): string {
  if (input === undefined || input.deviceType === audio.DeviceType.MIC ||
    input.deviceType === audio.DeviceType.INVALID || input.deviceType === audio.DeviceType.DEFAULT) {
    return voiceDeviceName(input);
  }
  if (input.deviceType === audio.DeviceType.NEARLINK || Number(input.deviceType) === NEARLINK_INPUT_TYPE) {
    if (followsCallOutput && output?.deviceType === audio.DeviceType.NEARLINK) {
      const headset = externalInputName(output.name || '') || externalInputName(output.displayName || '');
      if (headset.length > 0) return headset;
    }
    return externalInputName(input.name || '') || externalInputName(input.displayName || '') || '星闪耳机麦克风';
  }
  return externalInputName(input.name || '') || externalInputName(voiceDeviceName(input)) || '外接麦克风';
}

export class VoiceAudioRoute {
  private context?: common.UIAbilityContext;
  private manager?: audio.AudioSessionManager;
  private mixing?: Promise<void>;
  private ownsMixSession: boolean = false;
  private mode: VoiceMode = 'standard';
  private acousticEchoCancelerSupported?: boolean;
  private streamManager?: audio.AudioStreamManager;
  private session?: avSession.AVSession;
  private pickerType?: 'audio' | 'voice_call';
  private failedPickerType?: 'audio' | 'voice_call';
  private onHangUp?: () => void;
  private onToggleMute?: () => void;
  private card?: VoiceCallCard;
  private opening?: Promise<void>;
  private updatingMute?: Promise<void>;
  private muted: boolean = false;
  private observingRenderers: boolean = false;
  private observingCapturers: boolean = false;
  private observingOutputDevice: boolean = false;
  private observingInputDevice: boolean = false;
  private selectedMediaInput: boolean = false;
  private selectingMediaInput?: Promise<void>;
  private renderersBefore?: Set<number>;
  private capturersBefore?: Set<number>;
  private rendererId?: number;
  private capturerId?: number;
  private lastUsage?: audio.StreamUsage;
  private lastInputSource?: audio.SourceType;
  private previous = new VoiceRouteStatus();
  private onChange?: (status: VoiceRouteStatus) => void;

  private readonly onRendererChange = (_infos: audio.AudioRendererChangeInfoArray): void => { this.refresh(); };
  private readonly onCapturerChange = (_infos: audio.AudioCapturerChangeInfoArray): void => { this.refresh(); };
  private readonly onOutputDeviceChange = (_event: audio.CurrentOutputDeviceChangedEvent): void => { this.refresh(); };
  private readonly onInputDeviceChange = (_event: audio.CurrentInputDeviceChangedEvent): void => { this.refresh(); };

  begin(context: common.UIAbilityContext, onChange: (status: VoiceRouteStatus) => void,
    mode: VoiceMode = 'standard'): void {
    this.context = context;
    this.onChange = onChange;
    this.mode = mode;
    try {
      const audioManager = audio.getAudioManager();
      this.manager = audioManager.getSessionManager();
      const streams = audioManager.getStreamManager();
      this.streamManager = streams;
      if (mode === 'native-voip' && deviceInfo.apiAvailable(20)) {
        try {
          this.acousticEchoCancelerSupported =
            streams.isAcousticEchoCancelerSupported(audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION);
        } catch {
          hilog.debug(0x0, TAG, 'Echo cancellation capability unavailable');
        }
      }
      // The public stream records have no owner ID. Exclude pre-existing streams and only
      // report a new stream when there is a unique match or a previously identified ID.
      try {
        this.renderersBefore = new Set<number>(
          streams.getCurrentAudioRendererInfoArraySync().map((info) => info.streamId));
        streams.on('audioRendererChange', this.onRendererChange);
        this.observingRenderers = true;
      } catch {
        hilog.info(0x0, TAG, 'Renderer monitoring unavailable');
      }
      try {
        this.capturersBefore = new Set<number>(
          streams.getCurrentAudioCapturerInfoArraySync().map((info) => info.streamId));
        streams.on('audioCapturerChange', this.onCapturerChange);
        this.observingCapturers = true;
      } catch {
        hilog.info(0x0, TAG, 'Capturer monitoring unavailable');
      }
      if (deviceInfo.apiAvailable(20)) {
        this.manager.on('currentOutputDeviceChanged', this.onOutputDeviceChange);
        this.observingOutputDevice = true;
      }
      if (deviceInfo.apiAvailable(21)) {
        this.manager.on('currentInputDeviceChanged', this.onInputDeviceChange);
        this.observingInputDevice = true;
      }
    } catch (error) {
      hilog.info(0x0, TAG, 'Audio route services unavailable, code=%{public}d', (error as BusinessError).code);
    }
  }

  identifySystemStreams(captureId: number, playbackId: number): void {
    this.capturerId = captureId;
    this.rendererId = playbackId;
    this.refresh();
  }

  async activateMixing(): Promise<void> {
    const manager = this.manager;
    if (manager === undefined || this.context === undefined) return;
    if (this.mixing !== undefined) return this.mixing;
    this.mixing = (async (): Promise<void> => {
      try {
        if (manager.isAudioSessionActivated()) return;
        if (deviceInfo.apiAvailable(20)) {
          try {
            const scene = this.mode === 'native-voip' ?
              audio.AudioSessionScene.AUDIO_SESSION_SCENE_VOICE_COMMUNICATION :
              audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA;
            manager.setAudioSessionScene(scene);
          } catch (error) {
            hilog.info(0x0, TAG, 'Audio session scene unavailable, code=%{public}d', (error as BusinessError).code);
          }
        }
        await manager.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS });
        this.ownsMixSession = true;
        hilog.info(0x0, TAG, 'Concurrent app audio session activated');
      } catch (error) {
        hilog.info(0x0, TAG, 'Concurrent app audio unavailable, code=%{public}d', (error as BusinessError).code);
      }
    })();
    try {
      await this.mixing;
    } finally {
      this.mixing = undefined;
    }
  }

  activate(muted: boolean, onHangUp: () => void, onToggleMute?: () => void, card?: VoiceCallCard): void {
    this.muted = muted;
    this.card = card ?? { title: '语音联调', domain: '', avatar: '' };
    this.onHangUp = onHangUp;
    this.onToggleMute = onToggleMute;
    this.failedPickerType = undefined;
    this.refresh();
  }

  private syncSession(usage?: audio.StreamUsage, source?: audio.SourceType): void {
    const context = this.context;
    const hangUp = this.onHangUp;
    const pickerType = usage !== undefined && usage !== audio.StreamUsage.STREAM_USAGE_UNKNOWN
      ? (isCallUsage(usage) ? 'voice_call' : 'audio')
      : (source === audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION ? 'voice_call' :
        (source === audio.SourceType.SOURCE_TYPE_MIC ? 'audio' : this.pickerType));
    if (context === undefined || hangUp === undefined || pickerType === undefined || this.opening !== undefined ||
      this.pickerType === pickerType || this.failedPickerType === pickerType) return;
    this.opening = this.openSession(context, pickerType, hangUp).finally(() => {
      this.opening = undefined;
      this.refresh();
    });
  }

  private async openSession(context: common.UIAbilityContext, pickerType: 'audio' | 'voice_call',
    onHangUp: () => void): Promise<void> {
    try {
      await this.updatingMute;
      await this.destroySession();
      if (this.context === undefined) return;
      const session = await avSession.createAVSession(context, 'OopzHMCall', pickerType);
      this.session = session;
      if (this.context === undefined) return;
      if (pickerType === 'voice_call') {
        await session.setAVCallState({ state: avSession.CallState.CALL_STATE_ACTIVE, muted: this.muted });
        session.on('hangUp', onHangUp);
        if (this.onToggleMute !== undefined) session.on('toggleCallMute', this.onToggleMute);
      } else {
        await this.updateMediaCard(session, context);
        await session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_PLAY });
        session.on('stop', onHangUp);
      }
      await session.activate();
      this.pickerType = pickerType;
      if (pickerType === 'audio') this.loadDomainArtwork(session);
      this.updateMute(this.muted);
      hilog.info(0x0, TAG, 'System AVSession activated, type=%{public}s', pickerType);
    } catch (error) {
      hilog.warn(0x0, TAG, 'Unable to activate call session, code=%{public}d', (error as BusinessError).code);
      this.failedPickerType = pickerType;
      await this.destroySession();
    }
  }

  private async updateMediaCard(session: avSession.AVSession, context: common.UIAbilityContext,
    bytes?: ArrayBuffer): Promise<void> {
    const card = this.card;
    if (card === undefined || this.session !== session) return;
    const metadata: avSession.AVMetadata = {
      assetId: 'oopzhm-voice', title: card.title, artist: card.domain, subtitle: card.domain
    };
    let source: image.ImageSource | undefined;
    let cover: image.PixelMap | undefined;
    try {
      const data = bytes ?? (await context.resourceManager.getMediaContent($r('app.media.app_icon').id)).buffer;
      source = image.createImageSource(data);
      cover = await source.createPixelMap({ desiredSize: { width: 144, height: 144 } });
      metadata.mediaImage = cover;
    } catch {
      // If domain artwork fails, the existing card already has the app icon.
      if (bytes !== undefined) return;
    } finally {
      await source?.release().catch(() => {});
    }
    try {
      if (this.session === session && this.context === context) await session.setAVMetadata(metadata);
    } finally {
      await cover?.release().catch(() => {});
    }
  }

  private async loadDomainArtwork(session: avSession.AVSession): Promise<void> {
    const context = this.context;
    const url = this.card?.avatar ?? '';
    if (context === undefined || !url.startsWith('https://')) return;
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 3500, readTimeout: 3500, maxLimit: 524288
      });
      if (response.responseCode === 200 && response.result instanceof ArrayBuffer) {
        await this.updateMediaCard(session, context, response.result);
      }
    } catch {
      // Leave the app icon in the media card when the domain image is unavailable.
    } finally {
      request.destroy();
    }
  }

  updateMute(muted: boolean): void {
    this.muted = muted;
    const session = this.session;
    if (session === undefined || this.pickerType !== 'voice_call' || this.context === undefined) return;
    const previous = this.updatingMute;
    this.updatingMute = (async (): Promise<void> => {
      await previous;
      if (this.context === undefined || muted !== this.muted) return;
      try {
        await session.setAVCallState({ state: avSession.CallState.CALL_STATE_ACTIVE, muted: muted });
      } catch (error) {
        hilog.info(0x0, TAG, 'Unable to update call mute, code=%{public}d', (error as BusinessError).code);
      }
    })();
  }

  refresh(): void {
    const streams = this.streamManager;
    if (this.context === undefined) return;
    const next = new VoiceRouteStatus();
    const isPc = deviceInfo.deviceType === '2in1';
    const nativeVoip = this.mode === 'native-voip';
    next.acousticEchoCancelerSupported = this.acousticEchoCancelerSupported;
    next.pickerType = this.pickerType;
    next.independentInput = isPc && deviceInfo.apiAvailable(20) &&
      canIUse('SystemCapability.Multimedia.AVSession.AVInputCast');
    let outputDevice: audio.AudioDeviceDescriptor | undefined;
    let activeUsage: audio.StreamUsage | undefined;
    try {
      if (streams !== undefined && (nativeVoip || this.renderersBefore !== undefined)) {
        const candidates = streams.getCurrentAudioRendererInfoArraySync().filter((info) =>
          nativeVoip ? info.streamId === this.rendererId : !this.renderersBefore?.has(info.streamId));
        const renderer = candidates.find((info) => info.streamId === this.rendererId) ??
          (candidates.length === 1 ? candidates[0] : undefined);
        if (!nativeVoip) this.rendererId = renderer?.streamId;
        activeUsage = renderer?.rendererInfo.usage;
        this.lastUsage = activeUsage ?? this.lastUsage;
        next.usage = this.lastUsage;
        outputDevice = renderer?.deviceDescriptors[0];
        next.output = voiceDeviceName(outputDevice);
      }
      if (streams !== undefined && (nativeVoip || this.capturersBefore !== undefined)) {
        const candidates = streams.getCurrentAudioCapturerInfoArraySync().filter((info) =>
          nativeVoip ? info.streamId === this.capturerId : !this.capturersBefore?.has(info.streamId));
        const capturer = candidates.find((info) => info.streamId === this.capturerId) ??
          (candidates.length === 1 ? candidates[0] : undefined);
        if (!nativeVoip) this.capturerId = capturer?.streamId;
        this.lastInputSource = capturer?.capturerInfo.source ?? this.lastInputSource;
        next.source = this.lastInputSource;
        next.input = voiceInputName(capturer?.deviceDescriptors[0], outputDevice, !isPc && nativeVoip);
        next.voipStreams = isCallUsage(activeUsage) &&
          capturer?.capturerInfo.source === audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION && capturer.muted !== true;
        next.mediaInput = isPc && !next.independentInput && next.source === audio.SourceType.SOURCE_TYPE_MIC &&
          this.manager !== undefined && deviceInfo.apiAvailable(21);
      }
    } catch (error) {
      hilog.debug(0x0, TAG, 'Audio route refresh unavailable, code=%{public}d', (error as BusinessError).code);
    }
    this.publish(next);
    this.syncSession(next.usage, next.source);
  }

  private publish(next: VoiceRouteStatus): void {
    const previous = this.previous;
    if (next.usage === previous.usage && next.source === previous.source && next.input === previous.input &&
      next.output === previous.output && next.pickerType === previous.pickerType &&
      next.independentInput === previous.independentInput && next.mediaInput === previous.mediaInput &&
      next.voipStreams === previous.voipStreams &&
      next.acousticEchoCancelerSupported === previous.acousticEchoCancelerSupported) return;
    this.previous = next;
    hilog.info(0x0, TAG, 'Route observation usage=%{public}d source=%{public}d inputKnown=%{public}d outputKnown=%{public}d',
      next.usage ?? -1, next.source ?? -1, next.input.length > 0 ? 1 : 0, next.output.length > 0 ? 1 : 0);
    this.onChange?.(next);
  }

  getMediaInputs(): audio.AudioDeviceDescriptors {
    try {
      return this.manager?.getAvailableDevices(audio.DeviceUsage.MEDIA_INPUT_DEVICES) ?? [];
    } catch {
      return [];
    }
  }

  async selectMediaInput(device?: audio.AudioDeviceDescriptor): Promise<void> {
    const manager = this.manager;
    if (manager === undefined || this.context === undefined || this.selectingMediaInput !== undefined) return;
    this.selectingMediaInput = device === undefined ? manager.clearSelectedMediaInputDevice() :
      manager.selectMediaInputDevice(device);
    try {
      await this.selectingMediaInput;
      this.selectedMediaInput = device !== undefined;
      this.refresh();
    } finally {
      this.selectingMediaInput = undefined;
    }
  }

  async close(): Promise<void> {
    this.context = undefined;
    this.onChange = undefined;
    this.onHangUp = undefined;
    this.onToggleMute = undefined;
    this.card = undefined;
    this.failedPickerType = undefined;
    const streams = this.streamManager;
    this.streamManager = undefined;
    try {
      if (this.observingRenderers) streams?.off('audioRendererChange', this.onRendererChange);
      if (this.observingCapturers) streams?.off('audioCapturerChange', this.onCapturerChange);
    } catch {
      hilog.debug(0x0, TAG, 'Audio stream observer already released');
    }
    this.observingRenderers = false;
    this.observingCapturers = false;
    if (deviceInfo.apiAvailable(20) && this.observingOutputDevice) {
      try {
        this.manager?.off('currentOutputDeviceChanged', this.onOutputDeviceChange);
      } catch {
        hilog.debug(0x0, TAG, 'Output device observer already released');
      }
    }
    if (deviceInfo.apiAvailable(21) && this.observingInputDevice) {
      try {
        this.manager?.off('currentInputDeviceChanged', this.onInputDeviceChange);
      } catch {
        hilog.debug(0x0, TAG, 'Input device observer already released');
      }
    }
    this.observingOutputDevice = false;
    this.observingInputDevice = false;
    this.renderersBefore = undefined;
    this.capturersBefore = undefined;
    this.rendererId = undefined;
    this.capturerId = undefined;
    this.lastUsage = undefined;
    this.lastInputSource = undefined;
    this.acousticEchoCancelerSupported = undefined;
    this.previous = new VoiceRouteStatus();
    await this.selectingMediaInput?.catch(() => {});
    if (this.selectedMediaInput) {
      await this.manager?.clearSelectedMediaInputDevice().catch(() => {});
      this.selectedMediaInput = false;
    }
    await this.mixing;
    if (this.ownsMixSession) {
      this.ownsMixSession = false;
      await this.manager?.deactivateAudioSession().catch(() => {});
    }
    this.manager = undefined;
    await this.opening;
    await this.updatingMute;
    this.updatingMute = undefined;
    await this.destroySession();
  }

  private async destroySession(): Promise<void> {
    const session = this.session;
    this.session = undefined;
    this.pickerType = undefined;
    try {
      await session?.destroy();
    } catch (error) {
      hilog.debug(0x0, TAG, 'Call session reset, code=%{public}d', (error as BusinessError).code);
    }
  }
}
