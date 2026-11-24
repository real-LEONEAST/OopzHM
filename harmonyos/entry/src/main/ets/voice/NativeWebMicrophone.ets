import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';
const TAG = 'OopzNativeWebMic';
const MAX_IN_FLIGHT = 5;
const STREAM: audio.AudioStreamInfo = {
  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
  channels: audio.AudioChannel.CHANNEL_1,
  sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
  encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
};

export interface NativeWebMicrophoneOptions {
  diagnostics: boolean;
  onStarted?: () => Promise<void>;
  onStopped?: () => Promise<void>;
}

export class NativeWebMicrophone {
  private readonly options: NativeWebMicrophoneOptions;
  private port?: webview.WebMessagePort;
  private capture?: audio.AudioCapturer;
  private startingCall?: Promise<void>;
  private releasing?: Promise<void>;
  private credits = 0;
  private opening = false;
  private generation = 0;
  private statsTimer = -1;
  private sent = 0;
  private peak = 0;
  private dropped = 0;

  constructor(options: NativeWebMicrophoneOptions = { diagnostics: false }) {
    this.options = options;
  }

  attach(controller: webview.WebviewController, origin: string, context: common.UIAbilityContext): void {
    if (this.port !== undefined) {
      throw new Error('Native microphone port is already attached');
    }
    const ports = controller.createWebMessagePorts();
    const port = ports[0];
    this.port = port;
    try {
      port.onMessageEvent((message: webview.WebMessage) => {
        if (this.port !== port) {
          return;
        }
        if (message === 'open') {
          this.open(port, context);
        } else if (message === 'pull') {
          this.credits = Math.min(this.credits + 1, MAX_IN_FLIGHT);
        } else if (message === 'stop') {
          this.stopCapture();
        }
      });
      controller.postMessage('oopz-native-microphone', [ports[1]], origin);
    } catch (error) {
      this.port = undefined;
      port.close();
      ports[1].close();
      throw error as Error;
    }
  }

  private async open(port: webview.WebMessagePort, context: common.UIAbilityContext): Promise<void> {
    if (this.opening || this.capture !== undefined) {
      return;
    }
    this.opening = true;
    const generation = this.generation;
    let capture: audio.AudioCapturer | undefined;
    try {
      await this.releasing;
      if (this.port !== port || this.generation !== generation) {
        return;
      }
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MICROPHONE]);
      if (this.port !== port || this.generation !== generation) {
        return;
      }
      if (result.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        port.postMessageEvent('denied');
        return;
      }
      capture = await audio.createAudioCapturer({
        streamInfo: STREAM,
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
      });
      if (this.port !== port || this.generation !== generation) {
        await capture.release();
        return;
      }
      this.capture = capture;
      this.sent = 0;
      this.peak = 0;
      this.dropped = 0;
      capture.on('readData', (buffer: ArrayBuffer) => { this.send(port, buffer); });
      await capture.start();
      if (this.port !== port || this.capture !== capture) {
        return;
      }
      const streamId = await capture.getAudioStreamId();
      if (this.port !== port || this.capture !== capture) {
        return;
      }
      this.startingCall = this.options.onStarted?.();
      await this.startingCall;
      if (this.port !== port || this.capture !== capture) {
        return;
      }
      port.postMessageEvent('ready');
      if (this.options.diagnostics) {
        this.statsTimer = setInterval(() => { this.logProgress(); }, 2000);
      }
      hilog.info(0x0, TAG, 'Native Web capture started stream=%{public}d', streamId);
    } catch (error) {
      hilog.warn(0x0, TAG, 'Native Web capture failed code=%{public}d', (error as BusinessError).code ?? -1);
      if (this.capture === capture) {
        await this.stopCapture();
      }
      if (this.port === port) {
        port.postMessageEvent('failed');
      }
    } finally {
      this.opening = false;
    }
  }

  private send(port: webview.WebMessagePort, buffer: ArrayBuffer): void {
    if (this.port !== port || !this.capture) {
      return;
    }
    if (this.credits === 0) {
      this.dropped += buffer.byteLength;
      return;
    }
    this.credits--;
    try {
      port.postMessageEvent(buffer);
      if (this.options.diagnostics) {
        this.sent += buffer.byteLength;
        const samples = new Int16Array(buffer);
        for (let index = 0; index < samples.length; index++) {
          this.peak = Math.max(this.peak, Math.abs(samples[index]));
        }
      }
    } catch (error) {
      hilog.warn(0x0, TAG, 'Native Web capture port closed code=%{public}d', (error as BusinessError).code);
      this.close();
    }
  }

  private logProgress(): void {
    hilog.info(0x0, TAG, 'Native Web microphone sent=%{public}d dropped=%{public}d peak=%{public}d',
      this.sent, this.dropped, this.peak);
    this.peak = 0;
  }

  private stopCapture(): Promise<void> {
    this.generation++;
    const capture = this.capture;
    this.capture = undefined;
    this.credits = 0;
    clearInterval(this.statsTimer);
    if (capture === undefined) {
      return this.releasing ?? Promise.resolve();
    }
    const starting = this.startingCall;
    this.startingCall = undefined;
    const releasing = this.releaseCapture(capture, starting);
    this.releasing = releasing;
    return releasing;
  }

  private async releaseCapture(capture: audio.AudioCapturer, starting?: Promise<void>): Promise<void> {
    try {
      await capture.release();
      hilog.info(0x0, TAG, 'Native Web microphone released');
    } catch (error) {
      hilog.warn(0x0, TAG, 'Native Web capture release failed code=%{public}d', (error as BusinessError).code);
    }
    await starting?.catch(() => {});
    await this.options.onStopped?.();
  }

  async close(): Promise<void> {
    const port = this.port;
    this.port = undefined;
    if (port !== undefined) {
      try {
        port.postMessageEvent('closed');
      } catch (error) {
        hilog.warn(0x0, TAG, 'Native Web port close notification failed code=%{public}d', (error as BusinessError).code);
      }
      try {
        port.close();
      } catch (error) {
        hilog.warn(0x0, TAG, 'Native Web port release failed code=%{public}d', (error as BusinessError).code);
      }
    }
    await this.stopCapture();
  }
}
