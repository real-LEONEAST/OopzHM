import { url } from '@kit.ArkTS';
import { NATIVE_WEB_MICROPHONE_SCRIPT } from './NativeWebMicrophoneScript';

export const OOPZ_ORIGIN = 'https://web.oopz.cn';
export const OOPZ_HOME = `${OOPZ_ORIGIN}/`;
export const LOCAL_VOICE_ORIGIN = 'http://127.0.0.1:28691';
const RENDERER_KEY = 'dev.oopzwebtest.renderer';
const OOPZ_MAIN_FRAME = `window === window.top && location.origin === '${OOPZ_ORIGIN}'`;

export function isOopzPage(address: string): boolean {
  try {
    const parsed = url.URL.parseURL(address);
    return parsed.protocol === 'https:' && parsed.origin === OOPZ_ORIGIN &&
      parsed.username === '' && parsed.password === '';
  } catch {
    return false;
  }
}

export function resourceLabel(address: string): string {
  try {
    const parsed = url.URL.parseURL(address);
    const asset = parsed.pathname.match(/\/(flutter[^/]*\.js|main\.dart\.(?:js|mjs|wasm)|skwasm[^/]*\.(?:js|wasm))$/);
    return asset ? `${parsed.hostname}/${asset[1]}` : parsed.hostname || '网页资源';
  } catch {
    return '网页资源';
  }
}

export const WEB_STATUS = `(${OOPZ_MAIN_FRAME}) ? [
  navigator.onLine,
  !!document.querySelector('flutter-view, flt-glass-pane') && !document.querySelector('#loading:not([hidden])'),
  !!document.body?.innerText.includes('网络连接已中断'),
  document.documentElement.dataset.oopzTestRenderer === 'canvaskit'
].join('|') : ''`;

export const REQUEST_CANVAS_KIT = `(() => {
  if (!(${OOPZ_MAIN_FRAME})) return false;
  if (!window._flutter?.buildConfig?.builds?.some(build => build.renderer === 'canvaskit')) return false;
  sessionStorage.setItem('${RENDERER_KEY}', 'canvaskit');
  return true;
})()`;

// On retry, select the alternate renderer offered by the site's existing Flutter build.
export const OOPZ_SCRIPTS: ScriptItem[] = [{
  scriptRules: [OOPZ_ORIGIN],
  script: `(() => {
    if (!(${OOPZ_MAIN_FRAME}) || sessionStorage.getItem('${RENDERER_KEY}') !== 'canvaskit') return;
    document.addEventListener('DOMContentLoaded', () => {
      const flutter = window._flutter;
      const loader = flutter?.loader;
      if (typeof loader?.load !== 'function' ||
          !flutter.buildConfig?.builds?.some(build => build.renderer === 'canvaskit')) return;
      const load = loader.load;
      loader.load = function (options) {
        loader.load = load;
        document.documentElement.dataset.oopzTestRenderer = 'canvaskit';
        return load.call(this, { ...options, config: { ...options?.config, renderer: 'canvaskit' } });
      };
    }, { once: true });
  })()`
}, { scriptRules: [OOPZ_ORIGIN], script: NATIVE_WEB_MICROPHONE_SCRIPT }];

export const LOCAL_VOICE_SCRIPTS: ScriptItem[] = [
  { scriptRules: [LOCAL_VOICE_ORIGIN], script: NATIVE_WEB_MICROPHONE_SCRIPT }
];

export function setViewportScale(percent: number): string {
  return `(() => {
    if (!(${OOPZ_MAIN_FRAME})) return false;
    const content = 'width=device-width,initial-scale=${percent / 100},minimum-scale=0.25,' +
      'maximum-scale=4,user-scalable=yes';
    const tags = document.querySelectorAll('meta[name="viewport"]');
    if (tags.length === 0) {
      const tag = document.createElement('meta');
      tag.name = 'viewport';
      tag.content = content;
      document.head.append(tag);
    } else {
      tags.forEach(tag => tag.content = content);
    }
    return true;
  })()`;
}
