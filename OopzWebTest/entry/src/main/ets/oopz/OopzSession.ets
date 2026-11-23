// Native Oopz REST client: password login + areas / channels / members / profiles / enter / keep-alive / leave.
// Reproduces dsh-oopz-voice and oopz-sdk entirely inside the HarmonyOS app.

import { url, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  OOPZ_API_BASE, OOPZ_APP_VERSION_NUMBER, OOPZ_CHANNEL, OOPZ_PLATFORM, OOPZ_SIGNING_KEY_PEM
} from './OopzKeyMaterial';
import { rsaEncryptPassword, rsaSignBase64 } from './OopzCrypto';
import { md5Hex, md5HexUtf8 } from './Md5';
import { httpSend, httpUploadBytes, HttpResult } from './OopzHttp';
import { extractAppId } from './OopzToken';
import { normalizeChatText } from './OopzChatText';

const LOGIN_PATH: string = '/client/v1/login/v2/login';
const CHAT_IMAGE_UPLOAD_PATH: string = '/rtc/v1/cos/v1/signedUploadUrl';
const OOPZ_LEGACY_GATEWAY: string = 'https://gateway.oopz.cn';
// Published by Oopz at https://staticcdn.oopz.cn/config/eo_gateways_web.json.
const OOPZ_WEB_GATEWAY: string = 'https://gateway-n.oopz.cn';
const TAG: string = 'OopzNative';
const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';
const APP_ID_RE: RegExp = /^[0-9a-f]{32}$/i;

export interface OopzArea {
  areaId: string;
  name: string;
  code: string;
  avatar: string;
  banner: string;
  owner: string;
  level: number;
}

export interface OopzVoiceChannel {
  channelId: string;
  name: string;
  group: string;
  type: string;
  maxMember: number;
  voiceQuality: string;
  secret: boolean;
  groupId?: string;
  tag?: string;
  isTemp?: boolean;
}

export interface OopzChannelMember {
  uid: string;
  enterTime: string;
  sort: number;
  peopleLimit: number;
  screenSharing: boolean;
  isBot: boolean;
}

export interface OopzPersonInfo {
  uid: string;
  pid: number;
  name: string;
  avatar: string;
  banner: string;
  online: boolean;
  memberLevel: number;
  introduction: string;
  greeting: string;
}

export interface OopzChatAttachment {
  attachmentType: string;
  url: string;
  fileKey: string;
  width: number;
  height: number;
  displayName: string;
}

export const MAX_CHAT_IMAGE_BYTES = 8 * 1024 * 1024;

export interface OopzChatImage {
  name: string;
  width: number;
  height: number;
  bytes: ArrayBuffer;
}

export interface OopzUploadedChatImage extends OopzChatAttachment {
  fileSize: number;
  hash: string;
  animated: boolean;
}

export interface OopzChatReference {
  messageId: string;
  senderUid: string;
  content: string;
  attachments: OopzChatAttachment[];
  recalled?: boolean;
}

export interface OopzChatSendOptions {
  clientMessageId?: string;
  reference?: OopzChatReference;
  image?: OopzUploadedChatImage;
}

export interface OopzChatMessage {
  messageId: string;
  clientMessageId: string;
  areaId: string;
  channelId: string;
  senderUid: string;
  content: string;
  timestampMs: number;
  attachments: OopzChatAttachment[];
  referenceMessageId?: string;
  reference?: OopzChatReference;
}

export interface OopzRoom {
  appId: string;
  channel: string;
  uid: number;
  token: string;
}

export interface OopzCred {
  deviceId: string;
  personUid: string;
  jwtToken: string;
  privateKey: string;
  appVersion: string;
}

interface OopzEnvelope {
  status?: boolean;
  code?: number;
  message?: string;
  msg?: string;
}

interface LoginData {
  uid?: string | number;
  signature?: string;
}

interface LoginPayload {
  status?: boolean;
  message?: string;
  msg?: string;
  data?: LoginData;
}

interface LoginRequest {
  auto: boolean;
  code: string;
  loginType: string;
  phone: string;
  autoRegister: boolean;
  deviceId: string;
  deviceRam: string;
  deviceProcessor: string;
  loggedIn: string;
  osEdition: string;
  osVersion: string;
  resolution: string;
  graphics: string;
  clientVersion: string;
}

interface AreaItem {
  areaId?: string | number;
  id?: string | number;
  code?: string | number;
  name?: string;
  areaName?: string;
  avatar?: string;
  icon?: string;
  banner?: string;
  owner?: string;
  ownerUid?: string;
  level?: number;
}

interface AreasEnvelope {
  areas?: AreaItem[];
  data?: AreaItem[];
}

interface ChannelSettingsRaw {
  maxMember?: number;
  voiceQuality?: string;
}

interface ChannelItem {
  id?: string | number;
  channelId?: string | number;
  groupId?: string | number;
  name?: string;
  type?: string;
  secret?: boolean;
  tag?: string;
  isTemp?: boolean;
  settings?: ChannelSettingsRaw;
}

interface ChannelGroup {
  id?: string | number;
  groupId?: string | number;
  name?: string;
  sort?: number;
  system?: boolean;
  IsEnableTemp?: boolean;
  isEnableTemp?: boolean;
  channels?: ChannelItem[];
}

interface ChannelsEnvelope {
  data?: ChannelGroup[];
}

interface PersonRaw {
  uid?: string | number;
  pid?: string | number;
  name?: string;
  nickname?: string;
  avatar?: string;
  banner?: string;
  online?: boolean;
  memberLevel?: number;
  userLevel?: number;
  introduction?: string;
  bio?: string;
  greeting?: string;
}

interface SelfDetailEnvelope {
  data?: PersonRaw;
  uid?: string | number;
  pid?: string | number;
}

interface PersonInfosBody {
  persons: string[];
  commonIds: string[];
}

interface PersonInfosEnvelope {
  data?: PersonRaw[];
}

interface MembersByChannelsBody {
  area: string;
  channels: string[];
}

interface ChannelMemberRaw {
  uid?: string | number;
  personUid?: string | number;
  enterTime?: string | number;
  sort?: number;
  peopleLimit?: number;
  screenSharingState?: string;
  isBot?: boolean;
}

interface MembersByChannelsData {
  channelMembers?: Record<string, ChannelMemberRaw[]>;
}

interface MembersByChannelsEnvelope {
  data?: MembersByChannelsData;
}

interface EnterData {
  supplierSign?: string;
  roomId?: string | number;
  appId?: string;
  status?: boolean;
  message?: string;
}

interface EnterEnvelope {
  status?: boolean;
  message?: string;
  data?: EnterData;
  supplierSign?: string;
  roomId?: string | number;
  appId?: string;
}

interface EnterRequest {
  type: string;
  area: string;
  channel: string;
  fromChannel: string;
  fromArea: string;
  password: string;
  sign: number;
  pid: string;
}

interface ChatAttachmentRaw {
  attachmentType?: string;
  url?: string;
  fileKey?: string;
  width?: number;
  height?: number;
  displayName?: string;
}

export interface ChatMessageRaw {
  messageId?: string | number;
  id?: string | number;
  clientMessageId?: string;
  area?: string;
  channel?: string;
  areaId?: string;
  channelId?: string;
  person?: string | number;
  senderUid?: string | number;
  senderId?: string | number;
  content?: string | number | null;
  text?: string | number | null;
  timestamp?: string | number;
  attachments?: ChatAttachmentRaw[];
  rawImage?: ChatAttachmentRaw;
  referenceMessageId?: string | number | null;
  recall?: boolean;
}

interface MessageBeforeData {
  messages?: ChatMessageRaw[];
  referenceMessages?: ChatMessageRaw[];
}

interface MessageBeforeEnvelope extends MessageBeforeData {
  data?: MessageBeforeData;
}

interface ChatImageUploadTicket {
  signedUrl?: string;
  file?: string;
  auth?: string;
  url?: string;
}

interface ChatImageUploadEnvelope extends ChatImageUploadTicket {
  data?: ChatImageUploadTicket;
}

interface SendMessagePayload {
  area: string;
  channel: string;
  target: string;
  text: string;
  content: string;
  clientMessageId: string;
  timestamp: string;
  isMentionAll: boolean;
  mentionList: string[];
  styleTags: string[];
  referenceMessageId: string | null;
  animated: boolean;
  displayName: string;
  duration: number;
  attachments: OopzUploadedChatImage[];
}

interface SendMessageBody {
  message: SendMessagePayload;
}

interface SendMessageData {
  messageId?: string | number;
  message_id?: string | number;
  timestamp?: string | number;
  time?: string | number;
}

interface SendMessageEnvelope {
  data?: SendMessageData;
  messageId?: string | number;
  message_id?: string | number;
  timestamp?: string | number;
  time?: string | number;
}

function asString(value: string | number | undefined | null): string {
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number') {
    return String(value as number);
  }
  return '';
}

function parseTimestampMs(raw: string | number | undefined | null): number {
  if (typeof raw === 'number') {
    return raw > 1e14 ? Math.floor(raw / 1000) : raw;
  }
  if (typeof raw === 'string' && raw.length > 0) {
    const num = Number(raw);
    if (!isNaN(num) && num > 0) {
      return num > 1e14 ? Math.floor(num / 1000) : num;
    }
  }
  return Date.now();
}

export function toChatReference(message: OopzChatMessage): OopzChatReference {
  return {
    messageId: message.messageId,
    senderUid: message.senderUid,
    content: message.content,
    attachments: message.attachments
  };
}

export function newChatClientMessageId(): string {
  const baseId = (Date.now() * 1000) % 10000000000000;
  return String(baseId * 100 + Math.floor(Math.random() * 90) + 10);
}

function httpsImageUrl(value: string): boolean {
  try {
    const parsed = url.URL.parseURL(value);
    return parsed.protocol === 'https:' && !!parsed.hostname && !parsed.username && !parsed.password;
  } catch {
    return false;
  }
}

export function parseChatMessageRaw(item: ChatMessageRaw, areaFallback: string = '',
  channelFallback: string = ''): OopzChatMessage {
  const messageId = asString(item.messageId).length > 0 ? asString(item.messageId) : asString(item.id);
  const sender = asString(item.person).length > 0
    ? asString(item.person)
    : (asString(item.senderUid).length > 0 ? asString(item.senderUid) : asString(item.senderId));
  const content = normalizeChatText(item.content, item.text);
  const attachments: OopzChatAttachment[] = [];
  const rawAttachments = Array.isArray(item.attachments) && item.attachments.length > 0 ?
    item.attachments : (item.rawImage ? [item.rawImage] : []);
  for (const att of rawAttachments) {
    if (!att || !asString(att.url)) continue;
    attachments.push({
      attachmentType: asString(att.attachmentType) || 'IMAGE',
      url: asString(att.url),
      fileKey: asString(att.fileKey),
      width: Number(att.width) || 0,
      height: Number(att.height) || 0,
      displayName: asString(att.displayName)
    });
  }
  const referenceId = asString(item.referenceMessageId);
  return {
    messageId: messageId,
    clientMessageId: asString(item.clientMessageId),
    areaId: asString(item.area) || asString(item.areaId) || areaFallback,
    channelId: asString(item.channel) || asString(item.channelId) || channelFallback,
    senderUid: sender,
    content: content,
    timestampMs: parseTimestampMs(item.timestamp),
    attachments: attachments,
    referenceMessageId: referenceId && referenceId !== '0' ? referenceId : undefined
  };
}

function parsePersonRaw(item: PersonRaw): OopzPersonInfo {
  const uid = asString(item.uid);
  const pidStr = asString(item.pid);
  const pidNum = /^\d{1,10}$/.test(pidStr) ? Number(pidStr) : 0;
  const name = asString(item.name).length > 0 ? asString(item.name) : asString(item.nickname);
  const intro = asString(item.introduction).length > 0 ? asString(item.introduction) : asString(item.bio);
  return {
    uid: uid,
    pid: pidNum,
    name: name.length > 0 ? name : uid.slice(0, 6),
    avatar: asString(item.avatar),
    banner: asString(item.banner),
    online: item.online === true,
    memberLevel: typeof item.memberLevel === 'number' ? item.memberLevel : 0,
    introduction: intro,
    greeting: asString(item.greeting)
  };
}

export class OopzSession {
  private cred?: OopzCred;
  private cachedAppId: string = '';
  private cachedPid: string = '';

  setCred(cred: OopzCred): void {
    this.cred = cred;
    this.cachedPid = '';
  }

  clearCred(): void {
    this.cred = undefined;
    this.cachedPid = '';
  }

  seedCred(deviceId: string, personUid: string, jwtToken: string): OopzCred {
    const cred: OopzCred = {
      deviceId: deviceId,
      personUid: personUid,
      jwtToken: jwtToken,
      privateKey: OOPZ_SIGNING_KEY_PEM,
      appVersion: OOPZ_APP_VERSION_NUMBER
    };
    this.cred = cred;
    this.cachedPid = '';
    return cred;
  }

  getCred(): OopzCred | undefined {
    return this.cred;
  }

  isSignedIn(): boolean {
    return this.cred !== undefined;
  }

  private requireCred(): OopzCred {
    const cred = this.cred;
    if (cred === undefined) {
      throw new Error('尚未登录 Oopz');
    }
    return cred;
  }

  private async makeLoginHeaders(deviceId: string, path: string, body: string): Promise<Record<string, string>> {
    const time = String(Date.now());
    const signature = await rsaSignBase64(md5HexUtf8(path + body) + time);
    const headers: Record<string, string> = {
      'Accept': '*/*',
      'Content-Type': 'application/json;charset=utf-8',
      'Oopz-App-Version-Number': OOPZ_APP_VERSION_NUMBER,
      'Oopz-Channel': OOPZ_CHANNEL,
      'Oopz-Device-Id': deviceId,
      'Oopz-Platform': OOPZ_PLATFORM,
      'Oopz-Request-Id': util.generateRandomUUID(true),
      'Oopz-Time': time,
      'Oopz-Web': 'true',
      'Origin': 'https://web.oopz.cn',
      'User-Agent': USER_AGENT,
      'Oopz-Sign': signature
    };
    return headers;
  }

  private async makeApiHeaders(deviceId: string, personUid: string, jwt: string, path: string,
    body: string): Promise<Record<string, string>> {
    const time = String(Date.now());
    const signature = await rsaSignBase64(md5HexUtf8(path + body) + time);
    const headers: Record<string, string> = {
      'Accept': '*/*',
      'Content-Type': 'application/json;charset=utf-8',
      'Oopz-App-Version-Number': OOPZ_APP_VERSION_NUMBER,
      'Oopz-Channel': OOPZ_CHANNEL,
      'Oopz-Device-Id': deviceId,
      'Oopz-Platform': OOPZ_PLATFORM,
      'Oopz-Request-Id': util.generateRandomUUID(true),
      'Oopz-Time': time,
      'Oopz-Web': 'true',
      'Origin': 'https://web.oopz.cn',
      'User-Agent': USER_AGENT,
      'Oopz-Sign': signature,
      'Oopz-Person': personUid,
      'Oopz-Signature': jwt
    };
    return headers;
  }

  private async send(path: string, method: string, body?: string, gateway: string = OOPZ_API_BASE): Promise<HttpResult> {
    const cred = this.requireCred();
    const header = await this.makeApiHeaders(cred.deviceId, cred.personUid, cred.jwtToken, path,
      body === undefined ? '' : body);
    return await httpSend(method, gateway + path, header, body);
  }

  async signedSend(path: string, method: string, body?: string): Promise<HttpResult> {
    return await this.send(path, method, body);
  }

  async signedRequestJson(path: string, method: string, body?: string): Promise<Object> {
    return await this.requestJson(path, method, body);
  }

  async signedRequestVoid(path: string, method: string, body?: string): Promise<void> {
    const result = await this.send(path, method, body);
    hilog.info(0x0, TAG, 'api %{public}s %{public}s -> %{public}d', method, path, result.status);
    let parsed: Object | undefined = undefined;
    if (result.text.length > 0) {
      try {
        parsed = JSON.parse(result.text) as Object;
      } catch {
        parsed = undefined;
      }
    }
    if (result.status !== 200 && result.status !== 204) {
      let detail = 'HTTP ' + result.status;
      if (parsed !== undefined) {
        const env = parsed as OopzEnvelope;
        const msg = env.message !== undefined ? env.message : env.msg;
        if (msg !== undefined && msg.length > 0) {
          detail = msg;
        }
      }
      throw new Error('Oopz 请求失败：' + detail);
    }
    if (parsed !== undefined) {
      const envelope = parsed as OopzEnvelope;
      if (envelope.status === false) {
        const msg = envelope.message !== undefined ? envelope.message : envelope.msg;
        throw new Error(msg !== undefined && msg.length > 0 ? msg : 'Oopz 拒绝了请求');
      }
    }
  }

  private async requestJson(path: string, method: string, body?: string,
    gateway: string = OOPZ_API_BASE): Promise<Object> {
    const result = await this.send(path, method, body, gateway);
    hilog.info(0x0, TAG, 'api %{public}s %{public}s -> %{public}d', method, path, result.status);
    let parsed: Object | undefined = undefined;
    if (result.text.length > 0) {
      try {
        parsed = JSON.parse(result.text) as Object;
      } catch (error) {
        parsed = undefined;
      }
    }
    if (result.status !== 200) {
      let detail = 'HTTP ' + result.status;
      if (parsed !== undefined) {
        const env = parsed as OopzEnvelope;
        const msg = env.message !== undefined ? env.message : env.msg;
        if (msg !== undefined && msg.length > 0) {
          detail = msg;
        }
      }
      throw new Error('Oopz 请求失败：' + detail);
    }
    if (parsed === undefined) {
      throw new Error('Oopz 返回了无效数据');
    }
    const envelope = parsed as OopzEnvelope;
    if (envelope.status === false) {
      const msg = envelope.message !== undefined ? envelope.message : envelope.msg;
      throw new Error(msg !== undefined && msg.length > 0 ? msg : 'Oopz 拒绝了请求');
    }
    return parsed;
  }

  async login(phone: string, password: string, deviceId: string): Promise<OopzCred> {
    const encrypted = await rsaEncryptPassword(password);
    const body: LoginRequest = {
      auto: true,
      code: encrypted,
      loginType: 'PASSWORD',
      phone: phone,
      autoRegister: true,
      deviceId: deviceId,
      deviceRam: 'TBD',
      deviceProcessor: '0',
      loggedIn: deviceId,
      osEdition: 'web',
      osVersion: 'web/BrowserName.chrome',
      resolution: 'TBD',
      graphics: 'TBD',
      clientVersion: '0.73.817'
    };
    const bodyStr = JSON.stringify(body);
    const header = await this.makeLoginHeaders(deviceId, LOGIN_PATH, bodyStr);
    const result = await httpSend('POST', OOPZ_API_BASE + LOGIN_PATH, header, bodyStr);
    hilog.info(0x0, TAG, 'login http=%{public}d bytes=%{public}d', result.status, result.text.length);

    let parsed: Object | undefined = undefined;
    try {
      parsed = JSON.parse(result.text) as Object;
    } catch (error) {
      parsed = undefined;
    }
    if (result.status !== 200 || parsed === undefined) {
      throw new Error('Oopz 登录失败（HTTP ' + result.status + '）');
    }
    const payload = parsed as LoginPayload;
    if (payload.status === false) {
      const msg = payload.message !== undefined ? payload.message : payload.msg;
      throw new Error(msg !== undefined && msg.length > 0 ? msg : '账号或密码不正确');
    }
    const data: LoginData = payload.data !== undefined ? payload.data : {};
    const personUid = asString(data.uid);
    const jwt = asString(data.signature);
    if (personUid.length === 0 || jwt.length === 0) {
      throw new Error('Oopz 登录返回缺少会话字段');
    }
    const cred: OopzCred = {
      deviceId: deviceId,
      personUid: personUid,
      jwtToken: jwt,
      privateKey: OOPZ_SIGNING_KEY_PEM,
      appVersion: OOPZ_APP_VERSION_NUMBER
    };
    this.cred = cred;
    this.cachedPid = '';
    return cred;
  }

  async areas(): Promise<OopzArea[]> {
    const raw = await this.requestJson('/userSubscribeArea/v1/list', 'GET');
    let items: AreaItem[] = [];
    if (Array.isArray(raw)) {
      items = raw as AreaItem[];
    } else {
      const envelope = raw as AreasEnvelope;
      if (envelope.areas !== undefined) {
        items = envelope.areas;
      } else if (envelope.data !== undefined) {
        items = envelope.data;
      }
    }
    const out: OopzArea[] = [];
    for (const item of items) {
      const areaId = asString(item.areaId).length > 0 ? asString(item.areaId) : asString(item.id);
      if (areaId.length === 0) {
        continue;
      }
      const name = asString(item.name).length > 0 ? asString(item.name) : asString(item.areaName);
      const avatar = asString(item.avatar).length > 0 ? asString(item.avatar) : asString(item.icon);
      const owner = asString(item.owner).length > 0 ? asString(item.owner) : asString(item.ownerUid);
      out.push({
        areaId: areaId,
        name: name.length > 0 ? name : areaId,
        code: asString(item.code),
        avatar: avatar,
        banner: asString(item.banner),
        owner: owner,
        level: typeof item.level === 'number' ? item.level : 0
      });
    }
    return out;
  }

  async channels(areaId: string): Promise<OopzVoiceChannel[]> {
    const raw = await this.requestJson('/client/v1/area/v1/detail/v1/channels?area=' + encodeURIComponent(areaId), 'GET');
    let groups: ChannelGroup[] = [];
    if (Array.isArray(raw)) {
      groups = raw as ChannelGroup[];
    } else {
      const envelope = raw as ChannelsEnvelope;
      if (envelope.data !== undefined) {
        groups = envelope.data;
      }
    }
    const out: OopzVoiceChannel[] = [];
    for (const group of groups) {
      const groupName = asString(group.name);
      const gid = asString(group.id).length > 0 ? asString(group.id) : asString(group.groupId);
      const channels = group.channels;
      if (channels === undefined) {
        continue;
      }
      for (const channel of channels) {
        const chType = asString(channel.type);
        if (chType !== 'VOICE' && chType !== 'AUDIO' && chType !== 'TEXT') {
          continue;
        }
        const channelId = asString(channel.id).length > 0 ? asString(channel.id) : asString(channel.channelId);
        if (channelId.length === 0) {
          continue;
        }
        const name = asString(channel.name);
        const maxMember = typeof channel.settings?.maxMember === 'number' ? channel.settings.maxMember : 50;
        const voiceQuality = asString(channel.settings?.voiceQuality);
        const chGroupId = asString(channel.groupId).length > 0 ? asString(channel.groupId) : gid;
        out.push({
          channelId: channelId,
          name: name.length > 0 ? name : channelId,
          group: groupName,
          type: chType,
          maxMember: maxMember,
          voiceQuality: voiceQuality.length > 0 ? voiceQuality : '64k',
          secret: channel.secret === true,
          groupId: chGroupId,
          tag: asString(channel.tag),
          isTemp: channel.isTemp === true
        });
      }
    }
    return out;
  }

  async selfProfile(): Promise<OopzPersonInfo> {
    const cred = this.requireCred();
    const raw = await this.requestJson('/client/v1/person/v1/selfDetail', 'GET');
    const envelope = raw as SelfDetailEnvelope;
    const data: PersonRaw = envelope.data !== undefined ? envelope.data : { uid: envelope.uid, pid: envelope.pid };
    const profile = parsePersonRaw(data);
    if (profile.uid.length === 0) {
      profile.uid = cred.personUid;
    }
    if (profile.pid > 0) {
      this.cachedPid = String(profile.pid);
    }
    return profile;
  }

  async selfPid(): Promise<string> {
    if (/^\d{1,10}$/.test(this.cachedPid) && Number(this.cachedPid) > 0) {
      return this.cachedPid;
    }
    const profile = await this.selfProfile();
    if (profile.pid <= 0) {
      throw new Error('Oopz 未返回有效的声网用户 ID');
    }
    this.cachedPid = String(profile.pid);
    return this.cachedPid;
  }

  async personInfos(uids: string[]): Promise<OopzPersonInfo[]> {
    const clean: string[] = [];
    for (const u of uids) {
      if (u.length > 0 && clean.indexOf(u) < 0) {
        clean.push(u);
      }
    }
    if (clean.length === 0) {
      return [];
    }
    const body: PersonInfosBody = { persons: clean, commonIds: [] };
    const raw = await this.requestJson('/client/v1/person/v1/personInfos', 'POST', JSON.stringify(body));
    const list: PersonRaw[] = Array.isArray(raw)
      ? raw as PersonRaw[]
      : ((raw as PersonInfosEnvelope).data ?? []);
    const out: OopzPersonInfo[] = [];
    for (const item of list) {
      const person = parsePersonRaw(item);
      if (person.uid.length > 0) {
        out.push(person);
      }
    }
    return out;
  }

  async channelMembers(areaId: string, channelIds: string[]): Promise<Map<string, OopzChannelMember[]>> {
    const out = new Map<string, OopzChannelMember[]>();
    if (areaId.length === 0 || channelIds.length === 0) {
      return out;
    }
    for (let i = 0; i < channelIds.length; i += 20) {
      const slice = channelIds.slice(i, i + 20);
      const body: MembersByChannelsBody = { area: areaId, channels: slice };
      const raw = await this.requestJson('/area/v3/channel/membersByChannels', 'POST', JSON.stringify(body));
      const envelope = raw as MembersByChannelsEnvelope;
      const rawMap = envelope.data?.channelMembers;
      if (rawMap === undefined) {
        continue;
      }
      for (const cid of slice) {
        const list = rawMap[cid];
        const members: OopzChannelMember[] = [];
        if (Array.isArray(list)) {
          for (const item of list) {
            const uid = asString(item.uid).length > 0 ? asString(item.uid) : asString(item.personUid);
            if (uid.length === 0) continue;
            const sharing = asString(item.screenSharingState);
            members.push({
              uid: uid,
              enterTime: asString(item.enterTime),
              sort: typeof item.sort === 'number' ? item.sort : 0,
              peopleLimit: typeof item.peopleLimit === 'number' ? item.peopleLimit : 0,
              screenSharing: sharing.length > 0 && sharing !== 'CLOSE',
              isBot: item.isBot === true
            });
          }
        }
        out.set(cid, members);
      }
    }
    return out;
  }

  private async enterRoom(areaId: string, channelId: string): Promise<OopzRoom> {
    const pid = await this.selfPid();
    const body: EnterRequest = {
      type: 'VOICE',
      area: areaId,
      channel: channelId,
      fromChannel: '',
      fromArea: '',
      password: '',
      sign: 1,
      pid: pid
    };
    const raw = await this.requestJson('/area/v2/channel/enter', 'POST', JSON.stringify(body));
    const envelope = raw as EnterEnvelope;
    const sign: EnterData = envelope.data !== undefined ? envelope.data :
      { supplierSign: envelope.supplierSign, roomId: envelope.roomId, appId: envelope.appId };
    const token = asString(sign.supplierSign);
    const roomId = asString(sign.roomId);
    if (token.length === 0 || roomId.length === 0) {
      throw new Error('Oopz 未返回语音房间参数，请检查频道权限');
    }
    let appId = asString(sign.appId);
    if (!APP_ID_RE.test(appId)) {
      appId = this.cachedAppId.length > 0 ? this.cachedAppId : extractAppId(token);
    }
    if (!APP_ID_RE.test(appId)) {
      throw new Error('无法从 Oopz 令牌解析声网 App ID');
    }
    this.cachedAppId = appId;
    const room: OopzRoom = { appId: appId, channel: roomId, uid: Number(pid), token: token };
    return room;
  }

  async getChannelMessages(areaId: string, channelId: string, size: number = 30,
    before?: string): Promise<OopzChatMessage[]> {
    let query = '?area=' + encodeURIComponent(areaId) + '&channel=' + encodeURIComponent(channelId) +
      '&size=' + String(size);
    if (before !== undefined && before.length > 0) {
      query += '&before=' + encodeURIComponent(before);
    }
    const raw = await this.requestJson('/im/session/v2/messageBefore' + query, 'GET');
    const env = raw as MessageBeforeEnvelope;
    const list: ChatMessageRaw[] = env.data?.messages ?? env.messages ?? [];
    const references = new Map<string, OopzChatReference>();
    for (const item of env.data?.referenceMessages ?? env.referenceMessages ?? []) {
      const original = parseChatMessageRaw(item, areaId, channelId);
      if (!original.messageId || original.areaId !== areaId || original.channelId !== channelId) continue;
      const reference = toChatReference(original);
      if (item.recall === true) {
        reference.recalled = true;
        reference.content = '';
        reference.attachments = [];
      }
      references.set(original.messageId, reference);
    }
    const out: OopzChatMessage[] = [];
    for (const item of list) {
      const msg = parseChatMessageRaw(item, areaId, channelId);
      if (msg.referenceMessageId) msg.reference = references.get(msg.referenceMessageId);
      if (msg.messageId.length > 0 || msg.content.length > 0 || msg.attachments.length > 0) {
        out.push(msg);
      }
    }
    out.sort((a: OopzChatMessage, b: OopzChatMessage): number => {
      if (a.timestampMs !== b.timestampMs) {
        return a.timestampMs - b.timestampMs;
      }
      return a.messageId < b.messageId ? -1 : (a.messageId > b.messageId ? 1 : 0);
    });
    return out;
  }

  private async requestChatImageUpload(): Promise<ChatImageUploadTicket> {
    const gateway = OOPZ_API_BASE === OOPZ_LEGACY_GATEWAY ? OOPZ_WEB_GATEWAY : OOPZ_API_BASE;
    const body = JSON.stringify({ type: 'IMAGE', ext: '.webp' });
    try {
      const envelope = await this.requestJson(CHAT_IMAGE_UPLOAD_PATH, 'PUT', body, gateway) as ChatImageUploadEnvelope;
      return envelope.data ?? envelope;
    } catch (error) {
      throw new Error('申请图片上传地址失败：' + (error as Error).message);
    }
  }

  async uploadChatImage(image: OopzChatImage): Promise<OopzUploadedChatImage> {
    const cred = this.requireCred();
    const fileSize = image.bytes.byteLength;
    if (fileSize === 0 || fileSize > MAX_CHAT_IMAGE_BYTES || image.width <= 0 || image.height <= 0) {
      throw new Error('图片文件大小或尺寸无效');
    }
    const ticket = await this.requestChatImageUpload();
    if (this.getCred() !== cred) throw new Error('Oopz 会话已切换');
    const uploadUrl = asString(ticket.signedUrl);
    const downloadUrl = asString(ticket.url);
    const fileKey = asString(ticket.file);
    if (!httpsImageUrl(uploadUrl) || !httpsImageUrl(downloadUrl) || !fileKey || /[()\s]/.test(fileKey)) {
      throw new Error('Oopz 未返回有效的图片上传地址');
    }
    const headers: Record<string, string> = { 'Content-Type': 'image/webp' };
    if (ticket.auth) headers['Authorization'] = ticket.auth;
    let status: number;
    try {
      status = await httpUploadBytes(uploadUrl, headers, image.bytes);
    } catch {
      throw new Error('图片上传失败，请重试');
    }
    if (status < 200 || status >= 300) throw new Error('图片上传失败（HTTP ' + status + '）');
    if (this.getCred() !== cred) throw new Error('Oopz 会话已切换');
    return {
      attachmentType: 'IMAGE',
      fileKey: fileKey,
      url: downloadUrl,
      width: image.width,
      height: image.height,
      displayName: image.name,
      fileSize: fileSize,
      hash: md5Hex(new Uint8Array(image.bytes)),
      animated: false
    };
  }

  async sendChannelMessage(areaId: string, channelId: string, text: string,
    options?: OopzChatSendOptions): Promise<OopzChatMessage> {
    const cred = this.requireCred();
    const nowMs = Date.now();
    const nowUs = nowMs * 1000;
    const clientMessageId = options?.clientMessageId ?? newChatClientMessageId();
    const reference = options?.reference;
    const image = options?.image;
    let content = text;
    if (image !== undefined) {
      const marker = '![IMAGEw' + image.width + 'h' + image.height + '](' + image.fileKey + ')';
      content = text ? text + '\n' + marker : marker;
    }
    const body: SendMessageBody = {
      message: {
        area: areaId,
        channel: channelId,
        target: '',
        text: content,
        content: content,
        clientMessageId: clientMessageId,
        timestamp: String(nowUs),
        isMentionAll: false,
        mentionList: [],
        styleTags: [],
        referenceMessageId: reference?.messageId ?? null,
        animated: false,
        displayName: '',
        duration: 0,
        attachments: image ? [image] : []
      }
    };
    let path = '/im/session/v2/sendGimMessage';
    if (image) {
      path += '?a=' + encodeURIComponent(areaId) + '&c=' + encodeURIComponent(channelId);
    }
    let raw: Object;
    try {
      raw = await this.requestJson(path, 'POST', JSON.stringify(body));
    } catch (error) {
      if (image) throw new Error('提交图片消息失败：' + (error as Error).message);
      throw error as Error;
    }
    const env = raw as SendMessageEnvelope;
    const data: SendMessageData = env.data !== undefined ? env.data : {
      messageId: env.messageId,
      message_id: env.message_id,
      timestamp: env.timestamp,
      time: env.time
    };
    const msgId = asString(data.messageId).length > 0 ? asString(data.messageId) : asString(data.message_id);
    const tsRaw = data.timestamp !== undefined ? data.timestamp : data.time;
    return {
      messageId: msgId,
      clientMessageId: clientMessageId,
      areaId: areaId,
      channelId: channelId,
      senderUid: cred.personUid,
      content: content,
      timestampMs: tsRaw !== undefined ? parseTimestampMs(tsRaw) : nowMs,
      attachments: image ? [image] : [],
      referenceMessageId: reference?.messageId,
      reference: reference
    };
  }

  async enter(areaId: string, channelId: string): Promise<OopzRoom> {
    return await this.enterRoom(areaId, channelId);
  }

  async refresh(areaId: string, channelId: string): Promise<string> {
    const room = await this.enterRoom(areaId, channelId);
    return room.token;
  }

  async leave(areaId: string, channelId: string): Promise<void> {
    const cred = this.requireCred();
    const query = '?area=' + encodeURIComponent(areaId) + '&channel=' + encodeURIComponent(channelId) +
      '&target=' + encodeURIComponent(cred.personUid);
    const result = await this.send('/client/v1/area/v1/member/v1/removeFromChannel' + query, 'DELETE');
    if (result.status !== 204 && result.status !== 200) {
      throw new Error('Oopz 退房失败（HTTP ' + result.status + '）');
    }
  }
}
