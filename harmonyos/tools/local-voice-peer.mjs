import { createServer } from 'node:net';
import { performance } from 'node:perf_hooks';

const PORT = 28690;
const SAMPLE_RATE = 48000;
const FRAME_MS = 20;
const FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS / 1000;
const BYTES_PER_FRAME = 4;
const QUIET_AFTER_MS = process.argv.includes('--quiet') ? 15000 : Infinity;

function log(event, values = {}) {
  process.stdout.write(JSON.stringify({ event, utc: new Date().toISOString(), ...values }) + '\n');
}

function signal(sampleIndex) {
  // Alternate frequencies every second to verify that the incoming data is reaching the renderer.
  const second = Math.floor(sampleIndex / SAMPLE_RATE);
  const frequency = second % 2 === 0 ? 440 : 660;
  return Math.round(480 * Math.sin(2 * Math.PI * frequency * sampleIndex / SAMPLE_RATE));
}

let active;
const server = createServer((connection) => {
  if (active) {
    connection.destroy();
    return;
  }
  active = connection;
  connection.setNoDelay(true);
  let sent = 0;
  let received = 0;
  let peak = 0;
  let singleByte;
  let position = 0;
  let nextFrame = performance.now();
  const startedAt = nextFrame;
  let sendTimer;
  log('connected');

  function sendFrame() {
    if (connection.destroyed) return;
    const frame = Buffer.allocUnsafe(FRAME_SAMPLES * BYTES_PER_FRAME);
    const quiet = performance.now() - startedAt >= QUIET_AFTER_MS;
    for (let i = 0; i < FRAME_SAMPLES; i++) {
      const value = quiet ? 0 : signal(position++);
      frame.writeInt16LE(value, i * BYTES_PER_FRAME);
      frame.writeInt16LE(value, i * BYTES_PER_FRAME + 2);
    }
    if (connection.writableLength < 5 * frame.length) {
      connection.write(frame);
      sent += frame.length;
    }
    nextFrame = Math.max(nextFrame + FRAME_MS, performance.now() - 2 * FRAME_MS);
    sendTimer = setTimeout(sendFrame, Math.max(0, nextFrame - performance.now()));
  }

  connection.on('data', (chunk) => {
    received += chunk.length;
    let offset = 0;
    if (singleByte !== undefined && chunk.length) {
      peak = Math.max(peak, Math.abs(((chunk[0] << 24) >> 16) | singleByte));
      singleByte = undefined;
      offset = 1;
    }
    for (; offset + 1 < chunk.length; offset += 2) {
      peak = Math.max(peak, Math.abs(chunk.readInt16LE(offset)));
    }
    if (offset < chunk.length) singleByte = chunk[offset];
  });
  const stats = setInterval(() => {
    log('media', { sent, received, inputPeak: peak });
    peak = 0;
  }, 2000);
  connection.on('error', (error) => { log('socketError', { code: error.code }); });
  connection.on('close', () => {
    clearTimeout(sendTimer);
    clearInterval(stats);
    active = undefined;
    log('disconnected', { sent, received });
  });
  sendFrame();
});

server.on('error', (error) => {
  log('serverError', { code: error.code });
  process.exitCode = 1;
});
server.listen(PORT, '127.0.0.1', () => { log('listening', { port: PORT }); });
process.on('SIGINT', () => {
  active?.destroy();
  server.close();
});
