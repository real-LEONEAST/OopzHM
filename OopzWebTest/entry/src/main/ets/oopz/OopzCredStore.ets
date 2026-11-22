// Credential storage for the native Oopz session.
// Primary: HarmonyOS Asset Store Kit (@kit.AssetStoreKit) — encrypted at rest.
// Fallback: app-private preferences (plain) for devices/builds without asset support.

import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import type { OopzCred } from './OopzSession';

const STORE_NAME: string = 'oopz_native_session';
const KEY_DEVICE: string = 'device_id';
const KEY_CRED: string = 'cred';
const ALIAS_MAIN: string = 'oopz_cred_v1';
const ALIAS_SELFTEST: string = 'oopz_cred_selftest';

interface StoredCred {
  deviceId?: string;
  personUid?: string;
  jwtToken?: string;
  privateKey?: string;
  appVersion?: string;
}

function enc(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function dec(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export class OopzCredStore {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private async open(): Promise<preferences.Preferences> {
    return await preferences.getPreferences(this.context, STORE_NAME);
  }

  private queryMap(alias: string, includeSecret: boolean): asset.AssetMap {
    const map: asset.AssetMap = new Map();
    map.set(asset.Tag.ALIAS, enc(alias));
    if (includeSecret) {
      map.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    }
    return map;
  }

  private async assetPut(alias: string, json: string): Promise<void> {
    try {
      await asset.remove(this.queryMap(alias, false));
    } catch (error) {
      // not found — ignore
    }
    const map: asset.AssetMap = new Map();
    map.set(asset.Tag.ALIAS, enc(alias));
    map.set(asset.Tag.SECRET, enc(json));
    map.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    map.set(asset.Tag.REQUIRE_PASSWORD_SET, false);
    await asset.add(map);
  }

  private async assetGet(alias: string): Promise<string | undefined> {
    try {
      const rows = await asset.query(this.queryMap(alias, true));
      if (rows.length === 0) {
        return undefined;
      }
      const secret = rows[0].get(asset.Tag.SECRET);
      if (secret === undefined) {
        return undefined;
      }
      return dec(secret as Uint8Array);
    } catch (error) {
      return undefined;
    }
  }

  private async assetDel(alias: string): Promise<void> {
    try {
      await asset.remove(this.queryMap(alias, false));
    } catch (error) {
      // not found — ignore
    }
  }

  async loadDeviceId(): Promise<string> {
    const store = await this.open();
    const value = await store.get(KEY_DEVICE, '');
    return typeof value === 'string' ? value as string : '';
  }

  async saveDeviceId(deviceId: string): Promise<void> {
    const store = await this.open();
    await store.put(KEY_DEVICE, deviceId);
    await store.flush();
  }

  async saveCred(cred: OopzCred): Promise<void> {
    const payload: StoredCred = {
      deviceId: cred.deviceId,
      personUid: cred.personUid,
      jwtToken: cred.jwtToken,
      privateKey: cred.privateKey,
      appVersion: cred.appVersion
    };
    const json = JSON.stringify(payload);
    try {
      await this.assetPut(ALIAS_MAIN, json);
      return;
    } catch (error) {
      // fall through to preferences
    }
    const store = await this.open();
    await store.put(KEY_CRED, json);
    await store.flush();
  }

  async loadCred(): Promise<OopzCred | undefined> {
    let json = await this.assetGet(ALIAS_MAIN);
    if (json === undefined) {
      const store = await this.open();
      const raw = await store.get(KEY_CRED, '');
      if (typeof raw === 'string' && (raw as string).length > 0) {
        json = raw as string;
      }
    }
    if (json === undefined || json.length === 0) {
      return undefined;
    }
    try {
      const obj = JSON.parse(json) as StoredCred;
      const deviceId = obj.deviceId;
      const personUid = obj.personUid;
      const jwtToken = obj.jwtToken;
      const privateKey = obj.privateKey;
      if (deviceId === undefined || personUid === undefined || jwtToken === undefined || privateKey === undefined) {
        return undefined;
      }
      const appVersion = obj.appVersion;
      const cred: OopzCred = {
        deviceId: deviceId,
        personUid: personUid,
        jwtToken: jwtToken,
        privateKey: privateKey,
        appVersion: appVersion !== undefined ? appVersion : '73817'
      };
      return cred;
    } catch (error) {
      return undefined;
    }
  }

  async clearCred(): Promise<void> {
    await this.assetDel(ALIAS_MAIN);
    const store = await this.open();
    await store.delete(KEY_CRED);
    await store.flush();
  }

  async secureTest(): Promise<boolean> {
    try {
      const sample = '{"probe":1}';
      await this.assetPut(ALIAS_SELFTEST, sample);
      const got = await this.assetGet(ALIAS_SELFTEST);
      await this.assetDel(ALIAS_SELFTEST);
      return got === sample;
    } catch (error) {
      return false;
    }
  }
}
