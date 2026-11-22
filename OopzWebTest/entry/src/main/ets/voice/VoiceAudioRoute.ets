import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'OopzAudioRoute';

export class VoiceRouteStatus {
  input: string = '';
  output: string = '';
  usage?: audio.StreamUsage;
  source?: audio.SourceType;
  pickerType?: 'audio' | 'voice_call';
  independentInput: boolean = false;
  mediaInput: boolean = false;
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

export class VoiceAudioRoute {
  private context?: common.UIAbilityContext;
  private manager?: audio.AudioSessionManager;
  private streamManager?: audio.AudioStreamManager;
  private session?: avSession.AVSession;
  private pickerType?: 'audio' | 'voice_call';
  private failedPickerType?: 'audio' | 'voice_call';
  private onHangUp?: () => void;
  private onToggleMute?: () => void;
  private opening?: Promise<void>;
  private updatingMute?: Promise<void>;
  private muted: boolean = false;
  private observingRenderers: boolean = false;
  private observingCapturers: boolean = false;
  private observingOutputDevice: boolean = false;
  private observingInputDevice: boolean = false;
  private enhanced: boolean = false;
  private selectedMediaInput: boolean = false;
  private selectingMediaInput?: Promise<void>;
  private renderersBefore?: Set<number>;
  private capturersBefore?: Set<number>;
  private rendererId?: number;
  private capturerId?: number;
  private previous = new VoiceRouteStatus();
  private onChange?: (status: VoiceRouteStatus) => void;

  private readonly onRendererChange = (_infos: audio.AudioRendererChangeInfoArray): void => { this.refresh(); };
  private readonly onCapturerChange = (_infos: audio.AudioCapturerChangeInfoArray): void => { this.refresh(); };
  private readonly onOutputDeviceChange = (_event: audio.CurrentOutputDeviceChangedEvent): void => { this.refresh(); };
  private readonly onInputDeviceChange = (_event: audio.CurrentInputDeviceChangedEvent): void => { this.refresh(); };

  begin(context: common.UIAbilityContext, onChange: (status: VoiceRouteStatus) => void): void {
    this.context = context;
    this.onChange = onChange;
    try {
      const audioManager = audio.getAudioManager();
      this.manager = audioManager.getSessionManager();
      const streams = audioManager.getStreamManager();
      this.streamManager = streams;
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
      if (deviceInfo.apiAvailable('26.0.0') && canIUse('SystemCapability.Multimedia.Audio.DeviceEnhance')) {
        this.enhanced = audioManager.getDeviceEnhanceManager().isEnhancedRoutingSupported();
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

  activate(muted: boolean, onHangUp: () => void, onToggleMute?: () => void): void {
    this.muted = muted;
    this.onHangUp = onHangUp;
    this.onToggleMute = onToggleMute;
    this.failedPickerType = undefined;
    this.refresh();
  }

  private syncSession(usage?: audio.StreamUsage): void {
    const context = this.context;
    const hangUp = this.onHangUp;
    const pickerType = usage === undefined || usage === audio.StreamUsage.STREAM_USAGE_UNKNOWN
      ? (this.pickerType ?? 'voice_call')
      : (isCallUsage(usage) ? 'voice_call' : 'audio');
    if (context === undefined || hangUp === undefined || this.opening !== undefined ||
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
        await session.setAVMetadata({ assetId: 'oopzhm-voice', title: 'OopzHM 语音' });
        await session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_PLAY });
        session.on('stop', onHangUp);
      }
      await session.activate();
      this.pickerType = pickerType;
      this.updateMute(this.muted);
      hilog.info(0x0, TAG, 'System AVSession activated, type=%{public}s', pickerType);
    } catch (error) {
      hilog.warn(0x0, TAG, 'Unable to activate call session, code=%{public}d', (error as BusinessError).code);
      this.failedPickerType = pickerType;
      await this.destroySession();
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
    next.pickerType = this.pickerType;
    next.independentInput = this.enhanced && canIUse('SystemCapability.Multimedia.AVSession.AVCast');
    try {
      if (streams !== undefined && this.renderersBefore !== undefined) {
        const candidates = streams.getCurrentAudioRendererInfoArraySync().filter((info) =>
          !this.renderersBefore?.has(info.streamId));
        const renderer = candidates.find((info) => info.streamId === this.rendererId) ??
          (candidates.length === 1 ? candidates[0] : undefined);
        this.rendererId = renderer?.streamId;
        next.usage = renderer?.rendererInfo.usage;
        next.output = voiceDeviceName(renderer?.deviceDescriptors[0]);
      }
      if (streams !== undefined && this.capturersBefore !== undefined) {
        const candidates = streams.getCurrentAudioCapturerInfoArraySync().filter((info) =>
          !this.capturersBefore?.has(info.streamId));
        const capturer = candidates.find((info) => info.streamId === this.capturerId) ??
          (candidates.length === 1 ? candidates[0] : undefined);
        this.capturerId = capturer?.streamId;
        next.source = capturer?.capturerInfo.source;
        next.input = voiceDeviceName(capturer?.deviceDescriptors[0]);
        next.mediaInput = !next.independentInput && next.source === audio.SourceType.SOURCE_TYPE_MIC &&
          this.manager !== undefined && deviceInfo.apiAvailable(21);
      }
    } catch (error) {
      hilog.debug(0x0, TAG, 'Audio route refresh unavailable, code=%{public}d', (error as BusinessError).code);
    }
    this.publish(next);
    this.syncSession(next.usage);
  }

  private publish(next: VoiceRouteStatus): void {
    const previous = this.previous;
    if (next.usage === previous.usage && next.source === previous.source && next.input === previous.input &&
      next.output === previous.output && next.pickerType === previous.pickerType &&
      next.independentInput === previous.independentInput && next.mediaInput === previous.mediaInput) return;
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
    this.enhanced = false;
    this.previous = new VoiceRouteStatus();
    await this.selectingMediaInput?.catch(() => {});
    if (this.selectedMediaInput) {
      await this.manager?.clearSelectedMediaInputDevice().catch(() => {});
      this.selectedMediaInput = false;
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
