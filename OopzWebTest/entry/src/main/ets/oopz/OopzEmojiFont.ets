import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { text } from '@kit.ArkGraphics2D';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const OOPZ_EMOJI_FONT_FAMILY: string = 'OopzChatEmoji';
const FONT_URL: string = 'https://web.oopz.cn/assets/202611/fonts/emoji_glyf_colr_0.ttf';
const FONT_FILE: string = 'oopz-chat-emoji-202611.ttf';
const FONT_SIZE: number = 134016;
const FONT_SHA256: string = 'db1b9b413fdd237e0be6f2daf1ef0c29062c268b53834f2ee882d6ffa2b004c3';
const RETRY_DELAY_MS: number = 30000;
const TAG: string = 'OopzEmojiFont';

let fontReady: boolean = false;
let fontLoad: Promise<boolean> | undefined;
let retryAfter: number = 0;

function bytesToHex(bytes: Uint8Array): string {
  let hex = '';
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, '0');
  }
  return hex;
}

async function matchesOfficialFont(buffer: ArrayBuffer): Promise<boolean> {
  if (buffer.byteLength !== FONT_SIZE) {
    return false;
  }
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: new Uint8Array(buffer) });
  const digest = await md.digest();
  return bytesToHex(digest.data) === FONT_SHA256;
}

async function hasVerifiedCache(path: string): Promise<boolean> {
  try {
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size !== FONT_SIZE) {
        return false;
      }
      const bytes = new ArrayBuffer(FONT_SIZE);
      return await fileIo.read(file.fd, bytes) === FONT_SIZE && await matchesOfficialFont(bytes);
    } finally {
      await fileIo.close(file);
    }
  } catch {
    return false;
  }
}

async function fetchOfficialFont(): Promise<ArrayBuffer | undefined> {
  const request = http.createHttp();
  try {
    const response = await request.request(FONT_URL, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      connectTimeout: 8000,
      readTimeout: 8000,
      maxLimit: FONT_SIZE,
      maxRedirects: 0
    });
    if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
      return undefined;
    }
    return await matchesOfficialFont(response.result) ? response.result : undefined;
  } finally {
    request.destroy();
  }
}

async function writeVerifiedCache(path: string, bytes: ArrayBuffer): Promise<void> {
  const suffix = bytesToHex(cryptoFramework.createRandom().generateRandomSync(8).data);
  const tempPath = `${path}.${suffix}.tmp`;
  try {
    const file = await fileIo.open(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const written = await fileIo.write(file.fd, bytes);
      if (written !== bytes.byteLength) {
        throw new Error('Incomplete Oopz emoji font cache');
      }
    } finally {
      await fileIo.close(file);
    }
    await fileIo.rename(tempPath, path);
  } finally {
    await fileIo.unlink(tempPath).catch(() => {});
  }
}

async function loadOfficialFont(cacheDir: string): Promise<boolean> {
  const path = `${cacheDir}/${FONT_FILE}`;
  try {
    const cached = await hasVerifiedCache(path);
    if (!cached) {
      const bytes = await fetchOfficialFont();
      if (bytes === undefined) {
        hilog.warn(0x0, TAG, 'Oopz emoji font download could not be verified');
        return false;
      }
      await writeVerifiedCache(path, bytes);
    }
    const fonts = text.FontCollection.getGlobalInstance();
    const uri = `file://${path}`;
    if (deviceInfo.sdkApiVersion >= 23) {
      fonts.loadFontSyncWithCheck(OOPZ_EMOJI_FONT_FAMILY, uri);
    } else {
      fonts.loadFontSync(OOPZ_EMOJI_FONT_FAMILY, uri);
    }
    hilog.info(0x0, TAG, 'Oopz emoji font ready from %{public}s', cached ? 'cache' : 'network');
    return true;
  } catch {
    hilog.warn(0x0, TAG, 'Oopz emoji font could not be loaded');
    return false;
  }
}

export async function ensureOopzEmojiFont(context: common.UIAbilityContext): Promise<boolean> {
  if (fontReady || Date.now() < retryAfter) {
    return fontReady;
  }
  if (fontLoad !== undefined) {
    return fontLoad;
  }
  fontLoad = loadOfficialFont(context.cacheDir);
  try {
    fontReady = await fontLoad;
    if (!fontReady) {
      retryAfter = Date.now() + RETRY_DELAY_MS;
    }
    return fontReady;
  } finally {
    fontLoad = undefined;
  }
}
