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
import {
  AreaOrRoleChangeEvent, ChannelStructureEvent, ModerationEvent, OopzWsClient, VoicePresenceChange
} from '../oopz/OopzWs';
import {
  CreateChannelOptions, CreateChannelResult, EditChannelOptions, hasAreaPrivilege, OopzAreaAdmin, OopzAreaDetail,
  OopzChannelGroup, OopzPrivilege
} from '../oopz/OopzAreaAdmin';
import type {
  OopzArea, OopzChannelMember, OopzChatMessage, OopzCred, OopzPersonInfo, OopzVoiceChannel
} from '../oopz/OopzSession';

const TAG: string = 'OopzStore';
const UI_PREF_NAME: string = 'oopz_ui_prefs';
const GRIP_STABILITY_MS: number = 500;

export type PresenceListener = (areaId: string, channelId: string) => void;
export type ChatListener = (channelId: string, change: 'history' | 'append' | 'recall', messageId?: string) => void;
export type AreaAdminListener = (areaId: string, reason: string) => void;

interface AreaChannels {
  groups: OopzChannelGroup[];
  channels: OopzVoiceChannel[];
}

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
  readonly admin: OopzAreaAdmin = new OopzAreaAdmin(this.session);
  readonly ws: OopzWsClient = new OopzWsClient();
  selfProfile?: OopzPersonInfo;
  areas: OopzArea[] = [];
  channels: OopzVoiceChannel[] = [];
  readonly channelsByArea: Map<string, OopzVoiceChannel[]> = new Map<string, OopzVoiceChannel[]>();
  readonly areaDetailById: Map<string, OopzAreaDetail> = new Map<string, OopzAreaDetail>();
  readonly channelGroupsByArea: Map<string, OopzChannelGroup[]> = new Map<string, OopzChannelGroup[]>();
  private selectedChannelArea: string = '';
  private channelReadSequence: number = 0;
  private readonly latestChannelRead: Map<string, number> = new Map<string, number>();
  readonly membersByChannel: Map<string, OopzChannelMember[]> = new Map<string, OopzChannelMember[]>();
  readonly messagesByChannel: Map<string, OopzChatMessage[]> = new Map<string, OopzChatMessage[]>();
  private readonly recalledIds: Map<string, Set<string>> = new Map<string, Set<string>>();
  private readonly pendingRecalls: Map<string, OopzCred> = new Map<string, OopzCred>();
  readonly personByUid: Map<string, OopzPersonInfo> = new Map<string, OopzPersonInfo>();
  readonly personByPid: Map<number, OopzPersonInfo> = new Map<number, OopzPersonInfo>();

  private credStore?: OopzCredStore;
  private presenceListener?: PresenceListener;
  private chatListener?: ChatListener;
  private areaAdminListener?: AreaAdminListener;
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
      },
      onChannelStructureChange: (event: ChannelStructureEvent) => {
        this.handleChannelStructureChange(event);
      },
      onAreaOrRoleChange: (event: AreaOrRoleChangeEvent) => {
        this.handleAreaOrRoleChange(event);
      },
      onModerationChange: (event: ModerationEvent) => {
        this.handleModerationChange(event);
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
    this.selectedChannelArea = '';
    this.latestChannelRead.clear();
    this.areaDetailById.clear();
    this.channelGroupsByArea.clear();
    this.membersByChannel.clear();
    this.messagesByChannel.clear();
    this.recalledIds.clear();
    this.pendingRecalls.clear();
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
    this.selectedChannelArea = areaId;
    return (await this.readAreaChannels(areaId)).channels;
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
    const cred = this.session.getCred();
    const previous = this.messagesByChannel.get(channelId) ?? [];
    const fetched = await this.session.getChannelMessages(areaId, channelId, 30, before);
    if (this.session.getCred() !== cred) return [];
    const current = this.messagesByChannel.get(channelId) ?? [];
    const existing = before ? current : current.filter((msg: OopzChatMessage): boolean => !previous.includes(msg));
    const merged = this.updateChatCache(channelId, fetched.concat(existing));
    await this.ensurePersons(merged.map((msg: OopzChatMessage): string => msg.senderUid));
    if (this.session.getCred() !== cred) return [];
    this.chatListener?.(channelId, 'history');
    return this.messagesByChannel.get(channelId) ?? [];
  }

  async sendChannelMessage(areaId: string, channelId: string, text: string): Promise<OopzChatMessage> {
    const cred = this.session.getCred();
    const sent = await this.session.sendChannelMessage(areaId, channelId, text);
    if (this.session.getCred() !== cred) return sent;
    this.appendMessage(channelId, sent);
    this.chatListener?.(channelId, 'append');
    return sent;
  }

  private appendMessage(channelId: string, msg: OopzChatMessage): void {
    this.updateChatCache(channelId, (this.messagesByChannel.get(channelId) ?? []).concat([msg]));
  }

  private clientMessageKey(msg: OopzChatMessage): string {
    return msg.clientMessageId ? 'client/' + msg.senderUid + '/' + msg.clientMessageId : '';
  }

  private updateChatCache(channelId: string, messages: OopzChatMessage[]): OopzChatMessage[] {
    const recalled = this.recalledIds.get(channelId);
    const serverByClient = new Map<string, string>();
    // A recall can arrive before the send acknowledgement that links the two IDs.
    for (const msg of messages) {
      if (!msg.messageId || !msg.clientMessageId) continue;
      const clientKey = this.clientMessageKey(msg);
      serverByClient.set(clientKey, msg.messageId);
      if (recalled?.has(msg.messageId)) recalled.add(clientKey);
    }
    const merged: OopzChatMessage[] = [];
    const positions = new Map<string, number>();
    for (const msg of messages) {
      const clientKey = this.clientMessageKey(msg);
      const key = msg.messageId || serverByClient.get(clientKey) || clientKey;
      if (recalled?.has(key) || recalled?.has(clientKey)) continue;
      const index = positions.get(key);
      if (index === undefined) {
        if (key) positions.set(key, merged.length);
        merged.push(msg);
      } else if (msg.messageId && (!merged[index].messageId || (!merged[index].clientMessageId && msg.clientMessageId))) {
        merged[index] = msg;
      }
    }
    merged.sort((a: OopzChatMessage, b: OopzChatMessage): number => a.timestampMs - b.timestampMs);
    this.messagesByChannel.set(channelId, merged);
    return merged;
  }

  private async handleIncomingMessage(message: OopzChatMessage): Promise<void> {
    const cred = this.session.getCred();
    if (message.senderUid.length > 0) {
      await this.ensurePersons([message.senderUid]);
    }
    if (this.session.getCred() !== cred) return;
    this.appendMessage(message.channelId, message);
    this.chatListener?.(message.channelId, 'append');
  }

  private handleMessageRecall(_areaId: string, channelId: string, messageId: string): void {
    if (!channelId || !messageId) return;
    const ids = this.recalledIds.get(channelId) ?? new Set<string>();
    if (ids.has(messageId)) return;
    ids.add(messageId);
    this.recalledIds.set(channelId, ids);
    const current = this.messagesByChannel.get(channelId);
    if (current === undefined) {
      return;
    }
    this.updateChatCache(channelId, current);
    this.chatListener?.(channelId, 'recall', messageId);
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

  setAreaAdminListener(listener?: AreaAdminListener): void {
    this.areaAdminListener = listener;
  }

  getAreaDetail(areaId: string): OopzAreaDetail | undefined {
    return this.areaDetailById.get(areaId);
  }

  hasAreaPrivilege(areaId: string, privilege: string): boolean {
    return hasAreaPrivilege(this.areaDetailById.get(areaId), privilege);
  }

  private assertAreaPrivilege(areaId: string, privilege: string, label: string): void {
    const detail = this.areaDetailById.get(areaId);
    if (detail !== undefined && !hasAreaPrivilege(detail, privilege)) {
      throw new Error('缺少域权限：' + label + '（' + privilege + '）');
    }
  }

  async loadAreaDetail(areaId: string, forceRefresh: boolean = false): Promise<OopzAreaDetail> {
    if (!forceRefresh) {
      const cached = this.areaDetailById.get(areaId);
      if (cached !== undefined) {
        return cached;
      }
    }
    const cred = this.session.getCred();
    const detail = await this.admin.getAreaDetail(areaId);
    if (this.session.getCred() !== cred) {
      throw new Error('Oopz 会话已切换');
    }
    this.areaDetailById.set(areaId, detail);
    return detail;
  }

  async loadChannelGroups(areaId: string): Promise<OopzChannelGroup[]> {
    return (await this.readAreaChannels(areaId)).groups;
  }

  private async readAreaChannels(areaId: string): Promise<AreaChannels> {
    const sequence = ++this.channelReadSequence;
    this.latestChannelRead.set(areaId, sequence);
    const groups = await this.admin.getChannelGroups(areaId);
    const flat: OopzVoiceChannel[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      for (let j = 0; j < g.channels.length; j++) {
        const ch = g.channels[j];
        if (ch.type === 'VOICE' || ch.type === 'AUDIO' || ch.type === 'TEXT') {
          flat.push(ch);
        }
      }
    }
    if (this.latestChannelRead.get(areaId) === sequence) {
      this.channelGroupsByArea.set(areaId, groups);
      this.channelsByArea.set(areaId, flat);
      if (areaId === this.selectedChannelArea) this.channels = flat;
      await this.loadAreaPresence(areaId, flat);
    }
    return { groups: groups, channels: flat };
  }

  private async requireStructurePrivilege(areaId: string, privilege: string, label: string): Promise<void> {
    const detail = await this.loadAreaDetail(areaId, true);
    if (detail.areaId !== areaId || !hasAreaPrivilege(detail, privilege)) {
      throw new Error('缺少域权限：' + label + '（' + privilege + '）');
    }
  }

  private async refreshAfterStructureChange(areaId: string, reason: string): Promise<void> {
    this.channelGroupsByArea.delete(areaId);
    this.channelsByArea.delete(areaId);
    try {
      await this.loadChannelGroups(areaId);
    } catch {
      // The write already succeeded. A later list read can retry without repeating it.
      hilog.warn(0x0, TAG, 'Unable to reload groups after %{public}s', reason);
    }
    this.areaAdminListener?.(areaId, reason);
  }

  async createChannelGroup(areaId: string, name: string): Promise<void> {
    await this.requireStructurePrivilege(areaId, OopzPrivilege.MANAGE_GROUP, '管理分类');
    await this.admin.createChannelGroup(areaId, name);
    await this.refreshAfterStructureChange(areaId, 'group_create');
  }

  async renameChannelGroup(areaId: string, groupId: string, name: string): Promise<void> {
    await this.requireStructurePrivilege(areaId, OopzPrivilege.MANAGE_GROUP, '管理分类');
    await this.admin.renameChannelGroup(areaId, groupId, name);
    await this.refreshAfterStructureChange(areaId, 'group_update');
  }

  async deleteChannelGroup(areaId: string, groupId: string): Promise<void> {
    await this.requireStructurePrivilege(areaId, OopzPrivilege.MANAGE_GROUP, '管理分类');
    await this.admin.deleteChannelGroup(areaId, groupId);
    await this.refreshAfterStructureChange(areaId, 'group_delete');
  }

  async createChannel(options: CreateChannelOptions): Promise<CreateChannelResult> {
    await this.requireStructurePrivilege(options.areaId, OopzPrivilege.MANAGE_CHANNEL, '管理频道');
    const created = await this.admin.createChannel(options);
    await this.refreshAfterStructureChange(options.areaId, 'channel_create');
    return created;
  }

  async editChannel(options: EditChannelOptions): Promise<void> {
    await this.requireStructurePrivilege(options.areaId, OopzPrivilege.MANAGE_CHANNEL, '管理频道');
    await this.admin.editChannel(options);
    await this.refreshAfterStructureChange(options.areaId, 'channel_update');
  }

  async deleteChannel(areaId: string, channelId: string): Promise<void> {
    await this.requireStructurePrivilege(areaId, OopzPrivilege.MANAGE_CHANNEL, '管理频道');
    await this.admin.deleteChannel(areaId, channelId);
    this.messagesByChannel.delete(channelId);
    this.membersByChannel.delete(channelId);
    await this.refreshAfterStructureChange(areaId, 'channel_delete');
  }

  async recallChannelMessage(areaId: string, channelId: string, messageId: string): Promise<void> {
    const cred = this.session.getCred();
    const msg = this.messagesByChannel.get(channelId)?.find((m: OopzChatMessage): boolean => m.messageId === messageId);
    if (!cred || !cred.personUid || !messageId || !msg || (msg.areaId && msg.areaId !== areaId)) {
      throw new Error('这条消息已不可撤回');
    }
    if (msg.senderUid !== cred.personUid) throw new Error('只能撤回自己发送的消息');
    const key = channelId + '/' + messageId;
    if (this.pendingRecalls.has(key)) throw new Error('正在撤回消息');
    this.pendingRecalls.set(key, cred);
    try {
      if (this.recalledIds.get(channelId)?.has(messageId)) return;
      await this.admin.recallMessage(areaId, channelId, messageId);
      if (this.session.getCred() === cred) this.handleMessageRecall(areaId, channelId, messageId);
    } finally {
      if (this.pendingRecalls.get(key) === cred) this.pendingRecalls.delete(key);
    }
  }

  async kickFromVoiceChannel(areaId: string, channelId: string, targetUid: string): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.MOVE_VOICE, '移出语音频道');
    await this.admin.kickFromVoiceChannel(areaId, channelId, targetUid);
    try {
      const map = await this.session.channelMembers(areaId, [channelId]);
      const fresh = map.get(channelId);
      if (fresh !== undefined) {
        this.membersByChannel.set(channelId, fresh);
        await this.ensurePersons(fresh.map((m: OopzChannelMember): string => m.uid));
        this.presenceListener?.(areaId, channelId);
      }
    } catch {
      // ignore optimistic refresh error
    }
  }

  async kickFromArea(areaId: string, targetUid: string): Promise<void> {
    const detail = this.areaDetailById.get(areaId);
    if (detail !== undefined && !hasAreaPrivilege(detail, OopzPrivilege.MOVE_MEMBER) &&
      !hasAreaPrivilege(detail, OopzPrivilege.BLOCK_MEMBER)) {
      throw new Error('缺少域权限：移出域（MOVE_MEMBER / BLOCK_MEMBER）');
    }
    await this.admin.kickFromArea(areaId, targetUid);
  }

  async banMember(areaId: string, targetUid: string): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.BLOCK_MEMBER, '封禁成员');
    await this.admin.banMember(areaId, targetUid);
  }

  async unbanMember(areaId: string, targetUid: string): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.BLOCK_MEMBER, '解除封禁');
    await this.admin.unbanMember(areaId, targetUid);
  }

  async muteText(areaId: string, targetUid: string, durationSeconds: number = 300): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.DISABLE_TEXT, '文字禁言');
    await this.admin.muteText(areaId, targetUid, durationSeconds);
  }

  async unmuteText(areaId: string, targetUid: string): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.DISABLE_TEXT, '解除文字禁言');
    await this.admin.unmuteText(areaId, targetUid);
  }

  async muteVoice(areaId: string, targetUid: string, durationSeconds: number = 300): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.DISABLE_VOICE, '语音禁言');
    await this.admin.muteVoice(areaId, targetUid, durationSeconds);
  }

  async unmuteVoice(areaId: string, targetUid: string): Promise<void> {
    this.assertAreaPrivilege(areaId, OopzPrivilege.DISABLE_VOICE, '解除语音禁言');
    await this.admin.unmuteVoice(areaId, targetUid);
  }

  private handleChannelStructureChange(event: ChannelStructureEvent): void {
    if (event.areaId.length === 0) {
      return;
    }
    this.loadChannelGroups(event.areaId).then(() => {
      this.areaAdminListener?.(event.areaId, 'channel_' + event.action);
    }).catch(() => {
      this.areaAdminListener?.(event.areaId, 'channel_' + event.action);
    });
  }

  private handleAreaOrRoleChange(event: AreaOrRoleChangeEvent): void {
    if (event.areaId.length === 0) {
      return;
    }
    this.areaDetailById.delete(event.areaId);
    this.loadAreaDetail(event.areaId, true).then(() => {
      this.areaAdminListener?.(event.areaId, event.kind);
    }).catch(() => {
      this.areaAdminListener?.(event.areaId, event.kind);
    });
  }

  private handleModerationChange(event: ModerationEvent): void {
    if (event.areaId.length > 0) {
      this.areaAdminListener?.(event.areaId, event.kind);
    }
  }
}
