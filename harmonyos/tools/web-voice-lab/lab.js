const incoming = document.querySelector('#incoming');
const status = document.querySelector('#status');
let call;

function log(message) {
  console.info('OOPZ_WEB_LAB ' + message);
}

function statsFor(stats) {
  const audio = [...stats.values()].find((entry) => entry.type === 'inbound-rtp' && entry.kind === 'audio');
  return [audio?.packetsReceived ?? 0, audio?.totalSamplesReceived ?? 0, audio?.totalAudioEnergy ?? 0];
}

async function report(session) {
  const [phone, remote] = await Promise.all([session.phone.getStats(), session.remote.getStats()]);
  const up = statsFor(remote);
  const down = statsFor(phone);
  const source = [...phone.values()].find((entry) => entry.type === 'media-source' && entry.kind === 'audio');
  let upPeak = 0;
  if (session.meter) {
    session.meter.getFloatTimeDomainData(session.meterSamples);
    for (const sample of session.meterSamples) upPeak = Math.max(upPeak, Math.abs(sample));
  }
  log('media ' + JSON.stringify({
    time: Date.now(),
    visibility: document.visibilityState,
    mic: session.capture.getAudioTracks()[0].muted ? 'muted' : session.capture.getAudioTracks()[0].readyState,
    up, down, output: incoming.currentTime, paused: incoming.paused,
    inputEnergy: source?.totalAudioEnergy ?? 0, nativeBytes: window.oopzNativeMicrophone?.bytes ?? 0, upPeak
  }));
  return up[0] > 0 && down[0] > 0 && down[2] > 0 && incoming.currentTime > 0 && !incoming.paused;
}

function addCandidates(local, remote) {
  const pending = [];
  local.onicecandidate = ({ candidate }) => {
    if (!candidate) return;
    if (remote.remoteDescription) {
      remote.addIceCandidate(candidate).catch((error) => log('candidate ' + error.name));
    } else {
      pending.push(candidate);
    }
  };
  return () => Promise.all(pending.splice(0).map((candidate) => remote.addIceCandidate(candidate)));
}

async function stop() {
  const session = call;
  call = undefined;
  if (!session) return;
  clearInterval(session.interval);
  session.phone?.close();
  session.remote?.close();
  session.capture?.getTracks().forEach((track) => track.stop());
  session.testTrack?.stop();
  incoming.pause();
  incoming.srcObject = null;
  if (session.context) {
    await session.context.close();
  }
  status.textContent = '测试已结束';
  log('stopped');
}

async function start(useNativeMicrophone = false) {
  if (call) return;
  const session = {};
  call = session;
  try {
    if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone not available at ' + location.origin);
    if (useNativeMicrophone && !window.oopzNativeMicrophone?.ready) {
      throw new Error('The native microphone port is not attached');
    }
    session.capture = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
    });
    session.context = new AudioContext({ sampleRate: 48000 });
    const destination = session.context.createMediaStreamDestination();
    const gain = session.context.createGain();
    gain.gain.value = 0.022;
    session.remoteGain = gain;
    gain.connect(destination);
    const tone = session.context.createOscillator();
    tone.frequency.value = 523.25;
    tone.connect(gain);
    tone.start();
    await session.context.resume();
    session.testTrack = destination.stream.getAudioTracks()[0];
    session.phone = new RTCPeerConnection({ iceServers: [] });
    session.remote = new RTCPeerConnection({ iceServers: [] });
    const deliverToRemote = addCandidates(session.phone, session.remote);
    const deliverToPhone = addCandidates(session.remote, session.phone);
    session.phone.ontrack = ({ track }) => {
      incoming.srcObject = new MediaStream([track]);
      incoming.play().catch((error) => log('play ' + error.name));
    };
    session.remote.ontrack = ({ track }) => {
      const source = session.context.createMediaStreamSource(new MediaStream([track]));
      session.meter = session.context.createAnalyser();
      session.meter.fftSize = 2048;
      session.meterSamples = new Float32Array(session.meter.fftSize);
      source.connect(session.meter);
    };
    session.phone.addTrack(session.capture.getAudioTracks()[0], session.capture);
    session.remote.addTrack(session.testTrack, destination.stream);
    await session.phone.setLocalDescription(await session.phone.createOffer());
    await session.remote.setRemoteDescription(session.phone.localDescription);
    await deliverToRemote();
    await session.remote.setLocalDescription(await session.remote.createAnswer());
    await session.phone.setRemoteDescription(session.remote.localDescription);
    await deliverToPhone();

    for (let attempt = 0; attempt < 20; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      if (await report(session)) {
        status.textContent = '两路 RTP 音频已连通';
        session.interval = setInterval(() => {
          report(session).catch((error) => log('stats ' + error.name));
        }, 2000);
        log('ready');
        return;
      }
    }
    throw new Error('Both RTP streams did not start');
  } catch (error) {
    await stop();
    log('error ' + error.name + ' ' + error.message);
  }
}

document.addEventListener('visibilitychange', () => log('visibility=' + document.visibilityState));
function silenceRemote(seconds) {
  if (!call?.remoteGain) return;
  const start = call.context.currentTime + 0.5;
  call.remoteGain.gain.cancelScheduledValues(start);
  call.remoteGain.gain.setValueAtTime(0, start);
  call.remoteGain.gain.setValueAtTime(0.022, start + seconds);
  log('remote quiet for ' + seconds + ' seconds');
}
window.oopzWebLab = { start, stop, silenceRemote };
document.querySelector('#join').addEventListener('click', () => start());
document.querySelector('#leave').addEventListener('click', () => stop());
