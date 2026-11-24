import { audio } from '@kit.AudioKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const AUDIO_LAB_TAG = 'OopzAudioLab';
export const AUDIO_LAB_PORT = 28690;

const BYTES_PER_FRAME = 4;
const STREAM: audio.AudioStreamInfo = {
  samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
  channels: audio.AudioChannel.CHANNEL_2,
  sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
  encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
};

// TCP delivers a byte stream. Keep an aligned, bounded receive queue to limit latency.
class PcmReceiveQueue {
  private readonly storage = new Uint8Array(76800);
  private head = 0;
  private length = 0;

  append(chunk: Uint8Array): number {
    const overflow = Math.max(0, this.length + chunk.byteLength - this.storage.byteLength);
    const discard = Math.ceil(overflow / BYTES_PER_FRAME) * BYTES_PER_FRAME;
    const discardBuffered = Math.min(discard, this.length);
    this.head = (this.head + discardBuffered) % this.storage.byteLength;
    this.length -= discardBuffered;
    const input = chunk.subarray(discard - discardBuffered);
    const tail = (this.head + this.length) % this.storage.byteLength;
    const first = Math.min(input.byteLength, this.storage.byteLength - tail);
    this.storage.set(input.subarray(0, first), tail);
    this.storage.set(input.subarray(first), 0);
    this.length += input.byteLength;
    return discard;
  }

  consume(output: Uint8Array): number {
    const count = Math.floor(Math.min(output.byteLength, this.length) / BYTES_PER_FRAME) * BYTES_PER_FRAME;
    const first = Math.min(count, this.storage.byteLength - this.head);
    output.set(this.storage.subarray(this.head, this.head + first));
    output.set(this.storage.subarray(0, count - first), first);
    output.fill(0, count);
    this.head = (this.head + count) % this.storage.byteLength;
    this.length -= count;
    return count;
  }
}

function signalPeak(buffer: ArrayBuffer, length: number): number {
  const samples = new Int16Array(buffer, 0, Math.floor(length / 2));
  let peak = 0;
  for (let index = 0; index < samples.length; index++) {
    peak = Math.max(peak, Math.abs(samples[index]));
  }
  return peak;
}

function scalePcm(buffer: ArrayBuffer, length: number, gain: number): void {
  if (gain === 100) return;
  const samples = new Int16Array(buffer, 0, Math.floor(length / 2));
  for (let index = 0; index < samples.length; index++) {
    samples[index] = Math.max(-32768, Math.min(32767, Math.round(samples[index] * gain / 100)));
  }
}

export class LocalVoiceCall {
  private readonly receive = new PcmReceiveQueue();
  private connection?: socket.TCPSocket;
  private capturer?: audio.AudioCapturer;
  private renderer?: audio.AudioRenderer;
  private statsTimer = -1;
  private sending = false;
  private captured = 0;
  private delivered = 0;
  private received = 0;
  private rendered = 0;
  private capturePeak = 0;
  private renderPeak = 0;
  private sendDrop = 0;
  private receiveDrop = 0;
  private captureGain = 100;
  private playbackGain = 100;
  private readonly onFailure: (reason: string) => void;

  constructor(onFailure: (reason: string) => void) {
    this.onFailure = onFailure;
  }

  setGains(capture: number, playback: number): void {
    this.captureGain = capture;
    this.playbackGain = playback;
  }

  async start(): Promise<void> {
    const connection = socket.constructTCPSocketInstance();
    this.connection = connection;
    connection.on('message', (packet: socket.SocketMessageInfo) => {
      this.received += packet.message.byteLength;
      this.receiveDrop += this.receive.append(new Uint8Array(packet.message));
    });
    connection.on('error', (error: BusinessError) => {
      this.reportConnectionFailure(connection, '本机测试连接错误 ' + error.code);
    });
    connection.on('close', () => { this.reportConnectionFailure(connection, '本机测试对端已关闭'); });
    await connection.bind({ address: '127.0.0.1', port: 0, family: 1 });
    await connection.connect({ address: { address: '127.0.0.1', port: AUDIO_LAB_PORT, family: 1 }, timeout: 3000 });
    await connection.setExtraOptions({ TCPNoDelay: true });

    const renderer = await audio.createAudioRenderer({
      streamInfo: STREAM,
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 }
    });
    this.renderer = renderer;
    renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
      const count = this.receive.consume(new Uint8Array(buffer));
      scalePcm(buffer, count, this.playbackGain);
      this.rendered += count;
      this.renderPeak = Math.max(this.renderPeak, signalPeak(buffer, count));
      return audio.AudioDataCallbackResult.VALID;
    });
    await renderer.start();

    const capturer = await audio.createAudioCapturer({
      streamInfo: STREAM,
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
    });
    this.capturer = capturer;
    capturer.on('readData', (buffer: ArrayBuffer) => { this.sendMicrophone(connection, buffer); });
    await capturer.start();

    const capture = await capturer.getAudioStreamId();
    const playback = await renderer.getAudioStreamId();
    hilog.info(0x0, AUDIO_LAB_TAG, 'Native streams running capture=%{public}d playback=%{public}d', capture, playback);
    this.statsTimer = setInterval(() => { this.reportProgress(); }, 2000);
  }

  private sendMicrophone(connection: socket.TCPSocket, buffer: ArrayBuffer): void {
    if (this.connection !== connection) {
      return;
    }
    this.captured += buffer.byteLength;
    this.capturePeak = Math.max(this.capturePeak, signalPeak(buffer, buffer.byteLength));
    if (this.sending) {
      this.sendDrop += buffer.byteLength;
      return;
    }
    this.sending = true;
    const data = buffer.slice(0);
    scalePcm(data, data.byteLength, this.captureGain);
    connection.send({ data }).then(() => {
      this.delivered += data.byteLength;
    }).catch((error: BusinessError) => {
      this.reportConnectionFailure(connection, '本机语音发送失败 ' + error.code);
    }).finally(() => {
      this.sending = false;
    });
  }

  private reportConnectionFailure(connection: socket.TCPSocket, message: string): void {
    if (this.connection === connection) {
      this.onFailure(message);
    }
  }

  private reportProgress(): void {
    hilog.info(0x0, AUDIO_LAB_TAG,
      'Native media capture=%{public}d uplink=%{public}d downlink=%{public}d write=%{public}d inPeak=%{public}d outPeak=%{public}d',
      this.captured, this.delivered, this.received, this.rendered, this.capturePeak, this.renderPeak);
    this.capturePeak = 0;
    this.renderPeak = 0;
  }

  async close(): Promise<void> {
    clearInterval(this.statsTimer);
    const connection = this.connection;
    const capturer = this.capturer;
    const renderer = this.renderer;
    this.connection = undefined;
    this.capturer = undefined;
    this.renderer = undefined;
    if (capturer !== undefined) {
      await capturer.release().catch((error: BusinessError) => {
        hilog.warn(0x0, AUDIO_LAB_TAG, 'Capture release failed code=%{public}d', error.code);
      });
    }
    if (renderer !== undefined) {
      await renderer.release().catch((error: BusinessError) => {
        hilog.warn(0x0, AUDIO_LAB_TAG, 'Playback release failed code=%{public}d', error.code);
      });
    }
    if (connection !== undefined) {
      await connection.close().catch((error: BusinessError) => {
        hilog.warn(0x0, AUDIO_LAB_TAG, 'Peer release failed code=%{public}d', error.code);
      });
    }
    hilog.info(0x0, AUDIO_LAB_TAG, 'Native call closed uplinkDrop=%{public}d downlinkDrop=%{public}d',
      this.sendDrop, this.receiveDrop);
  }
}
