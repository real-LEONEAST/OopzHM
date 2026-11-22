// AppStore: single source of truth for session, profiles, room presence, text chat, UI theme & diagnostics.

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resolveIsDark } from '../common/Theme';
import { OopzSession } from '../oopz/OopzSession';
import { OopzCredStore } from '../oopz/OopzCredStore';
import { OopzWsClient, VoicePresenceChange } from '../oopz/OopzWs';
import type {
  OopzArea, OopzChannelMember, OopzChatMessage, OopzCred, OopzPersonInfo, OopzVoiceChannel
} from '../oopz/OopzSession';

const TAG: string = 'OopzStore';
const UI_PREF_NAME: string = 'oopz_ui_prefs';
const GRIP_STABILITY_MS: number = 500;

export type PresenceListener = (areaId: string, channelId: string) => void;
export type ChatListener = (channelId: string) => void;

export const DEFAULT_MIC_GAIN = 100;
export const MAX_MIC_GAIN = 150;
export const MAX_MEMBER_GAIN = 200;
export const VOICE_GAIN_STEP = 5;

export class AppStore {
  private static instance: AppStore | undefined = undefined;

  static get(): AppStore {
    if (AppStore.instance === undefined) {
      AppStore.instance = new AppStore();
    }
    return AppStore.instance;
  }

  readonly session: OopzSession = new OopzSession();
  readonly ws: OopzWsClient = new OopzWsClient();
  selfProfile?: OopzPersonInfo;
  areas: OopzArea[] = [];
  channels: OopzVoiceChannel[] = [];
  readonly channelsByArea: Map<string, OopzVoiceChannel[]> = new Map<string, OopzVoiceChannel[]>();
  readonly membersByChannel: Map<string, OopzChannelMember[]> = new Map<string, OopzChannelMember[]>();
  readonly messagesByChannel: Map<string, OopzChatMessage[]> = new Map<string, OopzChatMessage[]>();
  readonly personByUid: Map<string, OopzPersonInfo> = new Map<string, OopzPersonInfo>();
  readonly personByPid: Map<number, OopzPersonInfo> = new Map<number, OopzPersonInfo>();

  private credStore?: OopzCredStore;
  private presenceListener?: PresenceListener;
  private chatListener?: ChatListener;
  private themeListener?: (isDark: boolean) => void;
  private prefsLoaded: boolean = false;
  private foreground: boolean = false;
  private observingGrip: boolean = false;
  private gripUnavailable: boolean = false;
  private gripSubscriptionFailed: boolean = false;
  private gripCandidate?: string;
  private stableGrip: string = 'center';
  private gripTimer: number = -1;
  private readonly gripInteractions: Set<string> = new Set<string>();

  private readonly onGripChanged = (status: motion.HoldingHandStatus): void => {
    if (!this.observingGrip) return;
    if (status === motion.HoldingHandStatus.UNKNOWN_STATUS) {
      this.clearGripCandidate();
      return;
    }
    let side = 'center';
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) side = 'left';
    if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) side = 'right';
    if (side === this.gripCandidate) return;
    this.clearGripCandidate();
    if (side === this.stableGrip) return;
    this.gripCandidate = side;
    this.gripTimer = setTimeout(() => {
      this.gripTimer = -1;
      this.gripCandidate = undefined;
      this.stableGrip = side;
      this.publishGrip();
    }, GRIP_STABILITY_MS);
  };

  private clearGripCandidate(): void {
    if (this.gripTimer >= 0) {
      clearTimeout(this.gripTimer);
      this.gripTimer = -1;
    }
    this.gripCandidate = undefined;
  }

  private publishGrip(): void {
    if (this.gripInteractions.size === 0) {
      AppStorage.setOrCreate<string>('oopzHandGrip', this.stableGrip);
    }
  }

  setGripInteractionActive(source: string, active: boolean): void {
    if (active) {
      this.gripInteractions.add(source);
    } else {
      this.gripInteractions.delete(source);
      this.publishGrip();
    }
  }

  private constructor() {
    this.initStorageDefaults();
    this.ws.setCallbacks({
      onStateChange: (connected: boolean) => {
        AppStorage.setOrCreate<boolean>('oopzWsConnected', connected);
      },
      onVoicePresence: (event: VoicePresenceChange) => {
        this.handleVoicePresence(event);
      },
      onChatMessage: (message: OopzChatMessage) => {
        this.handleIncomingMessage(message);
      },
      onMessageRecall: (areaId: string, channelId: string, messageId: string) => {
        this.handleMessageRecall(areaId, channelId, messageId);
      }
    });
  }

  private initStorageDefaults(): void {
    AppStorage.setOrCreate<string>('oopzAccountUid', '');
    AppStorage.setOrCreate<string>('oopzDeviceId', '');
    AppStorage.setOrCreate<string>('oopzSelfName', '');
    AppStorage.setOrCreate<string>('oopzSelfAvatar', '');
    AppStorage.setOrCreate<string>('oopzSelfPid', '');
    AppStorage.setOrCreate<string>('oopzSelfGreeting', '');
    AppStorage.setOrCreate<boolean>('oopzWsConnected', false);
    AppStorage.setOrCreate<boolean>('oopzInCall', false);
    AppStorage.setOrCreate<string>('oopzCallAreaId', '');
    AppStorage.setOrCreate<string>('oopzCallChannelId', '');
    AppStorage.setOrCreate<string>('oopzCallAreaName', '');
    AppStorage.setOrCreate<string>('oopzCallChannelName', '');
    AppStorage.setOrCreate<boolean>('oopzCallMuted', false);
    AppStorage.setOrCreate<string>('oopzCallRates', '');
    AppStorage.setOrCreate<string>('oopzCallInput', '');
    AppStorage.setOrCreate<string>('oopzCallOutput', '');
    AppStorage.setOrCreate<string>('oopzCallVolumeType', '');
    AppStorage.setOrCreate<number>('oopzCallPeers', 0);
    AppStorage.setOrCreate<string>('oopzTaskStatus', '');
    AppStorage.setOrCreate<string>('oopzSdkVersion', '');
    AppStorage.setOrCreate<string>('oopzHandGrip', 'center');
    AppStorage.setOrCreate<boolean>('oopzGripEnabled', true);
    AppStorage.setOrCreate<boolean>('oopzGripSupported', false);
    AppStorage.setOrCreate<number>('oopzMicGain', DEFAULT_MIC_GAIN);
    AppStorage.setOrCreate<boolean>('oopzAppForeground', false);
    AppStorage.setOrCreate<boolean>('oopzRequestReturnRoom', false);
    AppStorage.setOrCreate<string>('oopzThemeMode', 'system');
    AppStorage.setOrCreate<boolean>('oopzImmersiveLight', true);
    if (!AppStorage.has('oopzSystemIsDark')) {
      AppStorage.setOrCreate<boolean>('oopzSystemIsDark', true);
    }
    if (!AppStorage.has('oopzIsDark')) {
      AppStorage.setOrCreate<boolean>('oopzIsDark', true);
    }
    AppStorage.setOrCreate<boolean>('oopzTrayOnClose', true);
    if (!AppStorage.has('oopzIsPc')) {
      AppStorage.setOrCreate<boolean>('oopzIsPc', false);
    }
    AppStorage.setOrCreate<boolean>('oopzInTray', false);
  }

  bind(context: common.UIAbilityContext): void {
    if (this.credStore === undefined) {
      this.credStore = new OopzCredStore(context);
    }
  }

  async loadUiPrefs(context: common.UIAbilityContext): Promise<void> {
    if (this.prefsLoaded) {
      return;
    }
    this.prefsLoaded = true;
    try {
      const pref = await preferences.getPreferences(context, UI_PREF_NAME);
      const themeMode = String(await pref.get('themeMode', 'system'));
      const gripEnabled = Boolean(await pref.get('gripEnabled', true));
      const micGain = Number(await pref.get('micGain', DEFAULT_MIC_GAIN));
      const trayOnClose = Boolean(await pref.get('trayOnClose', true));
      const immersiveLight = Boolean(await pref.get('immersiveLight', true));
      const micCue = Boolean(await pref.get('micCue', false));
      AppStorage.setOrCreate<boolean>('oopzGripEnabled', gripEnabled);
      this.setMicGain(undefined, micGain, false);
      AppStorage.setOrCreate<boolean>('oopzTrayOnClose', trayOnClose);
      AppStorage.setOrCreate<boolean>('oopzImmersiveLight', immersiveLight);
      AppStorage.setOrCreate<boolean>('oopzMicCue', micCue);
      this.applyThemeMode(context, themeMode);
    } catch {
      hilog.warn(0x0, TAG, 'loadUiPrefs failed');
    }
    this.updateGripObserver();
  }

  private applyThemeMode(context: common.UIAbilityContext | undefined, mode: string): void {
    const clean = (mode === 'light' || mode === 'dark') ? mode : 'system';
    const sysDark = AppStorage.get<boolean>('oopzSystemIsDark') ?? true;
    const isDark = resolveIsDark(clean, sysDark);
    AppStorage.setOrCreate<string>('oopzThemeMode', clean);
    AppStorage.setOrCreate<boolean>('oopzIsDark', isDark);
    this.themeListener?.(isDark);
    if (context !== undefined) {
      try {
        const appCtx = context.getApplicationContext();
        if (clean === 'dark') {
          appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
        } else if (clean === 'light') {
          appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        } else {
          appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        }
      } catch {
        // ignore if unsupported on older platform
      }
    }
  }

  setThemeListener(listener?: (isDark: boolean) => void): void {
    this.themeListener = listener;
  }

  setThemeMode(context: common.UIAbilityContext | undefined, mode: string): void {
    this.applyThemeMode(context, mode);
    if (context !== undefined) {
      this.saveUiPrefValue(context, 'themeMode', mode);
    }
  }

  setImmersiveLight(context: common.UIAbilityContext | undefined, enabled: boolean): void {
    AppStorage.setOrCreate<boolean>('oopzImmersiveLight', enabled);
    if (context !== undefined) {
      this.saveUiPrefValue(context, 'immersiveLight', enabled);
    }
  }

  setGripEnabled(context: common.UIAbilityContext | undefined, enabled: boolean): void {
    AppStorage.setOrCreate<boolean>('oopzGripEnabled', enabled);
    this.updateGripObserver();
    if (context !== undefined) {
      this.saveUiPrefValue(context, 'gripEnabled', enabled);
    }
  }

  setForeground(foreground: boolean): void {
    if (this.foreground === foreground) return;
    this.foreground = foreground;
    AppStorage.setOrCreate<boolean>('oopzAppForeground', foreground);
    this.updateGripObserver();
  }

  private updateGripObserver(): void {
    const supported = !this.gripUnavailable && deviceInfo.deviceType === 'phone' && deviceInfo.apiAvailable(20) &&
      canIUse('SystemCapability.MultimodalAwareness.Motion');
    const shouldObserve = supported && this.foreground && (AppStorage.get<boolean>('oopzGripEnabled') ?? true);
    if (shouldObserve !== this.observingGrip) {
      this.observingGrip = shouldObserve;
      try {
        if (shouldObserve) {
          motion.on('holdingHandChanged', this.onGripChanged);
          this.gripSubscriptionFailed = false;
        } else {
          motion.off('holdingHandChanged', this.onGripChanged);
        }
      } catch (error) {
        this.observingGrip = false;
        const code = (error as BusinessError).code;
        this.gripUnavailable = code === 801 || code === 201;
        this.gripSubscriptionFailed = shouldObserve;
        hilog.info(0x0, TAG, 'Holding hand subscription unavailable, code=%{public}d', code);
      }
    }
    AppStorage.setOrCreate<boolean>('oopzGripSupported', supported && !this.gripSubscriptionFailed);
    if (!this.observingGrip) {
      this.clearGripCandidate();
      this.stableGrip = 'center';
      this.publishGrip();
    }
  }

  setMicGain(context: common.UIAbilityContext | undefined, value: number, commit: boolean): void {
    const gain = Number.isFinite(value) ? Math.max(0, Math.min(MAX_MIC_GAIN, value)) : DEFAULT_MIC_GAIN;
    AppStorage.setOrCreate<number>('oopzMicGain', gain);
    if (commit && context !== undefined) {
      this.saveUiPrefValue(context, 'micGain', gain);
    }
  }

  setTrayOnClose(context: common.UIAbilityContext | undefined, enabled: boolean): void {
    AppStorage.setOrCreate<boolean>('oopzTrayOnClose', enabled);
    if (context !== undefined) {
      this.saveUiPrefValue(context, 'trayOnClose', enabled);
    }
  }

  setMicCue(context: common.UIAbilityContext | undefined, enabled: boolean): void {
    AppStorage.setOrCreate<boolean>('oopzMicCue', enabled);
    if (context !== undefined) this.saveUiPrefValue(context, 'micCue', enabled);
  }

  private saveUiPrefValue(context: common.UIAbilityContext, key: string, value: preferences.ValueType): void {
    preferences.getPreferences(context, UI_PREF_NAME).then(async (pref) => {
      await pref.put(key, value);
      await pref.flush();
    }).catch(() => {});
  }

  setPresenceListener(listener?: PresenceListener): void {
    this.presenceListener = listener;
  }

  setChatListener(listener?: ChatListener): void {
    this.chatListener = listener;
  }

  private syncCredStorage(cred?: OopzCred): void {
    AppStorage.setOrCreate<string>('oopzAccountUid', cred !== undefined ? cred.personUid : '');
    AppStorage.setOrCreate<string>('oopzDeviceId', cred !== undefined ? cred.deviceId : '');
  }

  private cachePerson(person: OopzPersonInfo): void {
    if (person.uid.length > 0) {
      this.personByUid.set(person.uid, person);
    }
    if (person.pid > 0) {
      this.personByPid.set(person.pid, person);
    }
  }

  getPersonByUid(uid: string): OopzPersonInfo | undefined {
    return this.personByUid.get(uid);
  }

  getPersonByPid(pid: number): OopzPersonInfo | undefined {
    return this.personByPid.get(pid);
  }

  async restore(): Promise<OopzCred | undefined> {
    if (this.credStore === undefined) {
      return undefined;
    }
    const cred = await this.credStore.loadCred();
    if (cred !== undefined) {
      this.session.setCred(cred);
      this.syncCredStorage(cred);
    }
    return cred;
  }

  async seedAndSaveCred(deviceId: string, personUid: string, jwt: string): Promise<OopzCred> {
    const cred = this.session.seedCred(deviceId, personUid, jwt);
    this.syncCredStorage(cred);
    if (this.credStore !== undefined) {
      try {
        await this.credStore.saveCred(cred);
      } catch {
        hilog.warn(0x0, TAG, 'Unable to persist seeded cred');
      }
    }
    return cred;
  }

  async loadDeviceId(): Promise<string> {
    if (this.credStore === undefined) {
      return '';
    }
    let deviceId = await this.credStore.loadDeviceId();
    if (deviceId.length === 0) {
      deviceId = util.generateRandomUUID(true);
      await this.credStore.saveDeviceId(deviceId);
    }
    return deviceId;
  }

  async login(phone: string, password: string, deviceId: string): Promise<OopzCred> {
    const cred = await this.session.login(phone, password, deviceId);
    if (this.credStore !== undefined) {
      await this.credStore.saveCred(cred);
    }
    this.syncCredStorage(cred);
    return cred;
  }

  async logout(): Promise<void> {
    this.ws.stop();
    this.session.clearCred();
    this.selfProfile = undefined;
    this.areas = [];
    this.channels = [];
    this.channelsByArea.clear();
    this.membersByChannel.clear();
    this.messagesByChannel.clear();
    this.personByUid.clear();
    this.personByPid.clear();
    this.syncCredStorage(undefined);
    AppStorage.setOrCreate<string>('oopzSelfName', '');
    AppStorage.setOrCreate<string>('oopzSelfAvatar', '');
    AppStorage.setOrCreate<string>('oopzSelfPid', '');
    AppStorage.setOrCreate<string>('oopzSelfGreeting', '');
    AppStorage.setOrCreate<boolean>('oopzWsConnected', false);
    this.updateCallStorage(false, '', '', '', '', false, 0, '');
    if (this.credStore !== undefined) {
      await this.credStore.clearCred();
    }
  }

  updateCallStorage(inCall: boolean, areaId: string, channelId: string, areaName: string, channelName: string,
    muted: boolean, peers: number, rates: string): void {
    AppStorage.setOrCreate<boolean>('oopzInCall', inCall);
    AppStorage.setOrCreate<string>('oopzCallAreaId', areaId);
    AppStorage.setOrCreate<string>('oopzCallChannelId', channelId);
    AppStorage.setOrCreate<string>('oopzCallAreaName', areaName);
    AppStorage.setOrCreate<string>('oopzCallChannelName', channelName);
    AppStorage.setOrCreate<boolean>('oopzCallMuted', muted);
    AppStorage.setOrCreate<number>('oopzCallPeers', peers);
    AppStorage.setOrCreate<string>('oopzCallRates', rates);
  }

  async loadSelfProfile(): Promise<OopzPersonInfo | undefined> {
    if (!this.session.isSignedIn()) {
      return undefined;
    }
    try {
      const profile = await this.session.selfProfile();
      this.selfProfile = profile;
      this.cachePerson(profile);
      AppStorage.setOrCreate<string>('oopzSelfName', profile.name);
      AppStorage.setOrCreate<string>('oopzSelfAvatar', profile.avatar);
      AppStorage.setOrCreate<string>('oopzSelfPid', profile.pid > 0 ? String(profile.pid) : '');
      AppStorage.setOrCreate<string>('oopzSelfGreeting', profile.greeting);
      return profile;
    } catch {
      hilog.warn(0x0, TAG, 'loadSelfProfile failed');
      return undefined;
    }
  }

  async loadAreas(): Promise<OopzArea[]> {
    this.areas = await this.session.areas();
    const cred = this.session.getCred();
    if (cred !== undefined) {
      const areaIds = this.areas.map((a: OopzArea): string => a.areaId);
      this.ws.start(cred, areaIds);
    }
    return this.areas;
  }

  async loadChannels(areaId: string): Promise<OopzVoiceChannel[]> {
    const channels = await this.session.channels(areaId);
    this.channels = channels;
    this.channelsByArea.set(areaId, channels);
    const voiceChannels = channels.filter((c: OopzVoiceChannel): boolean =>
      c.type === 'VOICE' || c.type === 'AUDIO');
    await this.loadAreaPresence(areaId, voiceChannels);
    return channels;
  }

  async loadAreaPresence(areaId: string, channels: OopzVoiceChannel[]): Promise<void> {
    const voiceOnly = channels.filter((c: OopzVoiceChannel): boolean =>
      c.type === 'VOICE' || c.type === 'AUDIO');
    if (areaId.length === 0 || voiceOnly.length === 0) {
      return;
    }
    const ids = voiceOnly.map((c: OopzVoiceChannel): string => c.channelId);
    try {
      const map = await this.session.channelMembers(areaId, ids);
      const uids: string[] = [];
      for (const cid of ids) {
        const list = map.get(cid) ?? [];
        this.membersByChannel.set(cid, list);
        for (const m of list) {
          if (uids.indexOf(m.uid) < 0) {
            uids.push(m.uid);
          }
        }
      }
      await this.ensurePersons(uids);
    } catch {
      hilog.warn(0x0, TAG, 'loadAreaPresence failed for area=%{public}s', areaId);
    }
  }

  async loadChannelMessages(areaId: string, channelId: string, before?: string): Promise<OopzChatMessage[]> {
    if (areaId.length === 0 || channelId.length === 0) {
      return [];
    }
    const fetched = await this.session.getChannelMessages(areaId, channelId, 30, before);
    const existing = before !== undefined && before.length > 0 ? (this.messagesByChannel.get(channelId) ?? []) : [];
    const merged: OopzChatMessage[] = [];
    const seen = new Set<string>();
    const combined = before !== undefined && before.length > 0 ? fetched.concat(existing) : fetched;
    const uids: string[] = [];
    for (const msg of combined) {
      const key = msg.messageId.length > 0 ? msg.messageId : msg.clientMessageId;
      if (key.length > 0) {
        if (seen.has(key)) continue;
        seen.add(key);
      }
      merged.push(msg);
      if (msg.senderUid.length > 0 && uids.indexOf(msg.senderUid) < 0) {
        uids.push(msg.senderUid);
      }
    }
    merged.sort((a: OopzChatMessage, b: OopzChatMessage): number => a.timestampMs - b.timestampMs);
    this.messagesByChannel.set(channelId, merged);
    await this.ensurePersons(uids);
    this.chatListener?.(channelId);
    return merged;
  }

  async sendChannelMessage(areaId: string, channelId: string, text: string): Promise<OopzChatMessage> {
    const sent = await this.session.sendChannelMessage(areaId, channelId, text);
    this.appendMessage(channelId, sent);
    this.chatListener?.(channelId);
    return sent;
  }

  private appendMessage(channelId: string, msg: OopzChatMessage): void {
    const current = (this.messagesByChannel.get(channelId) ?? []).slice();
    const exists = current.some((item: OopzChatMessage): boolean =>
      (msg.messageId.length > 0 && item.messageId === msg.messageId) ||
      (msg.clientMessageId.length > 0 && item.clientMessageId === msg.clientMessageId));
    if (!exists) {
      current.push(msg);
      current.sort((a: OopzChatMessage, b: OopzChatMessage): number => a.timestampMs - b.timestampMs);
      this.messagesByChannel.set(channelId, current);
    }
  }

  private async handleIncomingMessage(message: OopzChatMessage): Promise<void> {
    if (message.senderUid.length > 0) {
      await this.ensurePersons([message.senderUid]);
    }
    this.appendMessage(message.channelId, message);
    this.chatListener?.(message.channelId);
  }

  private handleMessageRecall(_areaId: string, channelId: string, messageId: string): void {
    const current = this.messagesByChannel.get(channelId);
    if (current === undefined) {
      return;
    }
    const filtered = current.filter((m: OopzChatMessage): boolean => m.messageId !== messageId);
    this.messagesByChannel.set(channelId, filtered);
    this.chatListener?.(channelId);
  }

  async ensurePersons(uids: string[]): Promise<void> {
    const missing: string[] = [];
    for (const u of uids) {
      if (u.length > 0 && !this.personByUid.has(u) && missing.indexOf(u) < 0) {
        missing.push(u);
      }
    }
    if (missing.length === 0) {
      return;
    }
    try {
      const infos = await this.session.personInfos(missing);
      for (const p of infos) {
        this.cachePerson(p);
      }
    } catch {
      hilog.warn(0x0, TAG, 'ensurePersons failed');
    }
  }

  private async handleVoicePresence(event: VoicePresenceChange): Promise<void> {
    const existing = (this.membersByChannel.get(event.channelId) ?? []).slice();
    if (event.entered) {
      for (const uid of event.persons) {
        if (!existing.some((m: OopzChannelMember): boolean => m.uid === uid)) {
          existing.push({
            uid: uid,
            enterTime: String(Date.now()),
            sort: 0,
            peopleLimit: 0,
            screenSharing: false,
            isBot: false
          });
        }
      }
    } else {
      const filtered = existing.filter((m: OopzChannelMember): boolean => event.persons.indexOf(m.uid) < 0);
      this.membersByChannel.set(event.channelId, filtered);
    }
    if (event.entered) {
      this.membersByChannel.set(event.channelId, existing);
    }
    await this.ensurePersons(event.persons);
    this.presenceListener?.(event.areaId, event.channelId);

    try {
      const map = await this.session.channelMembers(event.areaId, [event.channelId]);
      const fresh = map.get(event.channelId);
      if (fresh !== undefined) {
        this.membersByChannel.set(event.channelId, fresh);
        await this.ensurePersons(fresh.map((m: OopzChannelMember): string => m.uid));
        this.presenceListener?.(event.areaId, event.channelId);
      }
    } catch {
      // keep optimistic update
    }
  }
}
