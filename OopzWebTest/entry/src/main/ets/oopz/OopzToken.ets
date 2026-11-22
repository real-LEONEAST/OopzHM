// Extract the Agora App ID hidden in Oopz's supplierSign (Agora AccessToken2).
// Token = "<3-digit version>" + base64( zlib( payload ) ); payload starts with uint32BE len + appId.

import { util } from '@kit.ArkTS';
import { inflateZlib } from './Inflate';

const HEX32: RegExp = /^[0-9a-f]{32}$/i;

function readU32BE(bytes: Uint8Array, at: number): number {
  return ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
}

function asciiOf(bytes: Uint8Array, from: number, to: number): string {
  let out = '';
  const end = Math.min(to, bytes.length);
  for (let i = from; i < end; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function latin1Of(bytes: Uint8Array): string {
  let out = '';
  const end = Math.min(bytes.length, 4096);
  for (let i = 0; i < end; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export function extractAppId(token: string): string {
  if (!token || token.length < 4) {
    return '';
  }
  const body = /^\d{3}/.test(token) ? token.substring(3) : token;
  const helper = new util.Base64Helper();
  let raw: Uint8Array;
  try {
    const compressed = helper.decodeSync(body);
    raw = inflateZlib(compressed);
  } catch (error) {
    try {
      raw = helper.decodeSync(body);
    } catch (error2) {
      return '';
    }
  }
  if (raw.length < 8) {
    return '';
  }
  const length = readU32BE(raw, 0);
  if (length > 0 && length < 100) {
    const candidate = asciiOf(raw, 4, 4 + length);
    if (HEX32.test(candidate)) {
      return candidate;
    }
  }
  const match = latin1Of(raw).match(/[0-9a-f]{32}/i);
  return match !== null ? match[0] : '';
}
