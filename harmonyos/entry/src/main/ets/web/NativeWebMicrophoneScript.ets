export const NATIVE_WEB_MICROPHONE_SCRIPT: string = `
(() => {
  if (window !== window.top || window.oopzNativeMicrophone) return;
  let port;
  let capture;

  function stop(reason) {
    const current = capture;
    if (!current) return;
    capture = undefined;
    clearTimeout(current.timeout);
    for (const [track, stopTrack] of current.tracks) {
      stopTrack();
      track.dispatchEvent(new Event('ended'));
    }
    current.tracks.clear();
    current.source.stop();
    current.context.close().catch(() => {});
    if (current.reject) current.reject(new DOMException(reason, 'NotReadableError'));
    if (port) port.postMessage('stop');
  }

  function disconnect() {
    if (port) port.close();
    port = undefined;
    stop('Native microphone disconnected');
  }

  function addTrack(current, track) {
    const stopTrack = track.stop.bind(track);
    const cloneTrack = track.clone.bind(track);
    current.tracks.set(track, stopTrack);
    track.stop = () => {
      stopTrack();
      if (current.tracks.delete(track) && current.tracks.size === 0 && capture === current) {
        stop('Microphone track stopped');
      }
    };
    track.clone = () => {
      const clone = cloneTrack();
      return capture === current && current.tracks.has(track) ? addTrack(current, clone) : clone;
    };
    return track;
  }

  function accept(event) {
    if (event.data === 'closed') {
      disconnect();
      return;
    }
    if (!capture) return;
    const current = capture;
    if (event.data === 'ready') {
      clearTimeout(current.timeout);
      current.resolve();
      current.reject = undefined;
      // Bound the number of chunks waiting for JavaScript without serializing the round trips.
      for (let credit = 0; credit < 5; credit++) port.postMessage('pull');
      return;
    }
    if (event.data === 'denied' || event.data === 'failed') {
      stop('Native microphone was not started');
      return;
    }
    if (!(event.data instanceof ArrayBuffer)) return;
    const samples = new Int16Array(event.data);
    const now = current.context.currentTime;
    if (samples.length && current.nextTime - now < 0.20) {
      const audio = current.context.createBuffer(1, samples.length, 48000);
      const pcm = audio.getChannelData(0);
      for (let index = 0; index < samples.length; index++) pcm[index] = samples[index] / 32768;
      const source = current.context.createBufferSource();
      source.buffer = audio;
      source.connect(current.destination);
      if (current.nextTime < now + 0.01) current.nextTime = now + 0.055;
      const queued = current.nextTime - now;
      // The microphone and Web Audio clocks can drift. Keep roughly 80 ms of queued audio.
      const rate = 1 + Math.min(0.09, Math.max(-0.025, (queued - 0.08) * 1.5));
      source.playbackRate.value = rate;
      source.start(current.nextTime);
      current.nextTime += audio.duration / rate;
      current.bytes += event.data.byteLength;
    }
    port.postMessage('pull');
  }

  window.addEventListener('message', (event) => {
    if (event.data !== 'oopz-native-microphone' || event.ports.length !== 1 || port) return;
    if (event.source && event.source !== window) return;
    port = event.ports[0];
    port.onmessage = accept;
  });
  window.addEventListener('pagehide', () => stop('Page closed'));

  async function getStream() {
    if (!port) throw new DOMException('Native microphone is not attached', 'NotReadableError');
    if (!capture) {
      const context = new AudioContext({ sampleRate: 48000 });
      const destination = context.createMediaStreamDestination();
      destination.channelCount = 1;
      const current = {
        context, destination, source: destination.stream.getAudioTracks()[0],
        tracks: new Map(), bytes: 0, nextTime: 0
      };
      capture = current;
      current.started = context.resume().then(() => {
        if (capture !== current || !port) throw new DOMException('Native microphone stopped', 'AbortError');
        return new Promise((resolve, reject) => {
          current.resolve = resolve;
          current.reject = reject;
          current.timeout = setTimeout(() => stop('Native microphone did not respond'), 12000);
          port.postMessage('open');
        });
      }).catch((error) => {
        if (capture === current) stop('Could not start microphone');
        throw error;
      });
    }
    const current = capture;
    await current.started;
    if (capture !== current) throw new DOMException('Native microphone stopped', 'AbortError');
    const track = addTrack(current, current.source.clone());
    return new MediaStream([track]);
  }

  window.oopzNativeMicrophone = {
    get ready() { return !!port; },
    get bytes() { return capture?.bytes ?? 0; },
    disconnect
  };
  const devices = navigator.mediaDevices;
  if (devices && typeof devices.getUserMedia === 'function') {
    const browserGetUserMedia = devices.getUserMedia.bind(devices);
    devices.getUserMedia = (constraints) => {
      if (!port || !constraints?.audio || constraints.video) return browserGetUserMedia(constraints);
      return getStream();
    };
  }
})();
`;
