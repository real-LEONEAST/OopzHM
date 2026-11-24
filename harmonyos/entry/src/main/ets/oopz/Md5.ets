// Pure-MD5 implementation (HarmonyOS cryptoFramework does not expose MD5).
// Used to reproduce Oopz request signing: RSA-SHA256( MD5(path + body) + time ).

import { util } from '@kit.ArkTS';

const SHIFT: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
];

function buildK(): Uint32Array {
  const table = new Uint32Array(64);
  for (let i = 0; i < 64; i++) {
    table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0;
  }
  return table;
}

const K: Uint32Array = buildK();

function rotl(value: number, count: number): number {
  return ((value << count) | (value >>> (32 - count))) >>> 0;
}

export function md5Bytes(input: Uint8Array): Uint8Array {
  const bitLen = input.length * 8;
  const withOne = input.length + 1;
  const pad = ((56 - (withOne % 64)) + 64) % 64;
  const total = withOne + pad + 8;
  const msg = new Uint8Array(total);
  msg.set(input, 0);
  msg[input.length] = 0x80;

  const lo = bitLen >>> 0;
  const hi = Math.floor(bitLen / 4294967296) >>> 0;
  msg[total - 8] = lo & 0xff;
  msg[total - 7] = (lo >>> 8) & 0xff;
  msg[total - 6] = (lo >>> 16) & 0xff;
  msg[total - 5] = (lo >>> 24) & 0xff;
  msg[total - 4] = hi & 0xff;
  msg[total - 3] = (hi >>> 8) & 0xff;
  msg[total - 2] = (hi >>> 16) & 0xff;
  msg[total - 1] = (hi >>> 24) & 0xff;

  let a0 = 0x67452301;
  let b0 = 0xefcdab89;
  let c0 = 0x98badcfe;
  let d0 = 0x10325476;
  const m = new Uint32Array(16);

  for (let off = 0; off < total; off += 64) {
    for (let j = 0; j < 16; j++) {
      const p = off + j * 4;
      m[j] = (msg[p] | (msg[p + 1] << 8) | (msg[p + 2] << 16) | (msg[p + 3] << 24)) >>> 0;
    }
    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;
    for (let i = 0; i < 64; i++) {
      let f = 0;
      let g = 0;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + K[i] + m[g]) >>> 0;
      a = d;
      d = c;
      c = b;
      b = (b + rotl(f, SHIFT[i])) >>> 0;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  const out = new Uint8Array(16);
  const regs: number[] = [a0, b0, c0, d0];
  for (let i = 0; i < 4; i++) {
    out[i * 4] = regs[i] & 0xff;
    out[i * 4 + 1] = (regs[i] >>> 8) & 0xff;
    out[i * 4 + 2] = (regs[i] >>> 16) & 0xff;
    out[i * 4 + 3] = (regs[i] >>> 24) & 0xff;
  }
  return out;
}

export function md5Hex(bytes: Uint8Array): string {
  const digest = md5Bytes(bytes);
  let hex = '';
  for (let i = 0; i < digest.length; i++) {
    const v = digest[i];
    hex += (v < 16 ? '0' : '') + v.toString(16);
  }
  return hex;
}

export function md5HexUtf8(text: string): string {
  return md5Hex(new util.TextEncoder().encodeInto(text));
}
