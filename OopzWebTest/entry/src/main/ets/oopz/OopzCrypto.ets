// Native Oopz request signing & password encryption using HarmonyOS CryptoArchitectureKit.
//   sign   : RSA(PKCS1v15)+SHA256 over ( MD5(path + body) + timeMs ), Base64
//   encrypt: RSA OAEP(SHA256) of the password with the client password modulus (e=65537)

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  OOPZ_SIGNING_KEY_PEM, OOPZ_SIGNING_KEY_BITS, OOPZ_PASSWORD_MODULUS_HEX, OOPZ_PASSWORD_KEY_BITS
} from './OopzKeyMaterial';

function utf8(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function toBase64(bytes: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(bytes);
}

export async function rsaSignBase64(data: string): Promise<string> {
  const generator = cryptoFramework.createAsyKeyGenerator('RSA' + OOPZ_SIGNING_KEY_BITS);
  const keyPair = await generator.convertPemKey(null, OOPZ_SIGNING_KEY_PEM);
  const signer = cryptoFramework.createSign('RSA' + OOPZ_SIGNING_KEY_BITS + '|PKCS1|SHA256');
  await signer.init(keyPair.priKey);
  const blob: cryptoFramework.DataBlob = { data: utf8(data) };
  const signature = await signer.sign(blob);
  return toBase64(signature.data);
}

// ---- minimal DER encoder to build an X.509 SubjectPublicKeyInfo (RSA, e=65537) ----

function bigintToBytes(value: bigint): Uint8Array {
  let hex = value.toString(16);
  if (hex.length % 2 === 1) {
    hex = '0' + hex;
  }
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  if (out.length > 0 && (out[0] & 0x80) !== 0) {
    const padded = new Uint8Array(out.length + 1);
    padded[0] = 0;
    padded.set(out, 1);
    return padded;
  }
  return out;
}

function derLength(length: number): Uint8Array {
  if (length < 128) {
    return new Uint8Array([length]);
  }
  const bytes: number[] = [];
  let rest = length;
  while (rest > 0) {
    bytes.unshift(rest & 0xff);
    rest = rest >> 8;
  }
  const out = new Uint8Array(bytes.length + 1);
  out[0] = 0x80 | bytes.length;
  for (let i = 0; i < bytes.length; i++) {
    out[i + 1] = bytes[i];
  }
  return out;
}

function derTlv(tag: number, content: Uint8Array): Uint8Array {
  const len = derLength(content.length);
  const out = new Uint8Array(1 + len.length + content.length);
  out[0] = tag;
  out.set(len, 1);
  out.set(content, 1 + len.length);
  return out;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) {
    total += part.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function rsaPublicKeyPem(modulusHex: string): string {
  const n = bigintToBytes(BigInt('0x' + modulusHex));
  const nInt = derTlv(0x02, n);
  const eInt = derTlv(0x02, new Uint8Array([0x01, 0x00, 0x01]));
  const rsaPub = derTlv(0x30, concatBytes([nInt, eInt]));
  const rsaOid = new Uint8Array([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]);
  const nullParam = new Uint8Array([0x05, 0x00]);
  const algId = derTlv(0x30, concatBytes([rsaOid, nullParam]));
  const bitStr = derTlv(0x03, concatBytes([new Uint8Array([0x00]), rsaPub]));
  const spki = derTlv(0x30, concatBytes([algId, bitStr]));

  const b64 = toBase64(spki);
  let body = '';
  for (let i = 0; i < b64.length; i += 64) {
    body += b64.substring(i, Math.min(i + 64, b64.length)) + '\n';
  }
  return '-----BEGIN PUBLIC KEY-----\n' + body + '-----END PUBLIC KEY-----\n';
}

let cachedPublicKey: cryptoFramework.PubKey | undefined = undefined;

async function passwordPublicKey(): Promise<cryptoFramework.PubKey> {
  if (cachedPublicKey !== undefined) {
    return cachedPublicKey;
  }
  const pem = rsaPublicKeyPem(OOPZ_PASSWORD_MODULUS_HEX);
  const generator = cryptoFramework.createAsyKeyGenerator('RSA' + OOPZ_PASSWORD_KEY_BITS);
  const keyPair = await generator.convertPemKey(pem, null);
  cachedPublicKey = keyPair.pubKey;
  return keyPair.pubKey;
}

export async function rsaEncryptPassword(password: string): Promise<string> {
  const publicKey = await passwordPublicKey();
  let cipher: cryptoFramework.Cipher;
  try {
    cipher = cryptoFramework.createCipher('RSA' + OOPZ_PASSWORD_KEY_BITS + '|PKCS1_OAEP|SHA256|MGF1_SHA256');
  } catch (error) {
    cipher = cryptoFramework.createCipher('RSA' + OOPZ_PASSWORD_KEY_BITS + '|PKCS1_OAEP');
  }
  try {
    cipher.setCipherSpec(cryptoFramework.CipherSpecItem.OAEP_MD_NAME_STR, utf8('SHA256'));
    cipher.setCipherSpec(cryptoFramework.CipherSpecItem.OAEP_MGF_NAME_STR, utf8('MGF1'));
    cipher.setCipherSpec(cryptoFramework.CipherSpecItem.OAEP_MGF1_MD_STR, utf8('SHA256'));
  } catch (error) {
    // Some builds accept the digest/mgf only via the transformation string.
  }
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, publicKey, null);
  const encrypted = await cipher.doFinal({ data: utf8(password) });
  return toBase64(encrypted.data);
}
