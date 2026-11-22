// Oopz WebSocket real-time event client (wss://ws.oopz.cn).
// Reproduces oopz-sdk OopzWSClient on HarmonyOS @ohos.net.webSocket.

import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OOPZ_APP_VERSION_NUMBER, OOPZ_PLATFORM } from './OopzKeyMaterial';
import { inflateZlib } from './Inflate';
import type { OopzChatAttachment, OopzChatMessage, OopzCred } from './OopzSession';

const TAG: string = 'OopzWs';
const WS_URL: string = 'wss://ws.oopz.cn';
const HEARTBEAT_MS: number = 10000;
const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';

export interface VoicePresenceChange {
  areaId: string;
  channelId: string;
  entered: boolean;
  persons: string[];
  activeNum: number;
}

export interface ChannelStructureEvent {
  eventCode: number;
  action: 'create' | 'update' | 'delete';
  areaId: string;
  channelId: string;
  name: string;
  groupId: string;
  rawJson: string;
}

export interface AreaOrRoleChangeEvent {
  eventCode: number;
  kind: 'area' | 'role';
  areaId: string;
  rawJson: string;
}

export interface ModerationEvent {
  eventCode: number;
  kind: 'voice_ban' | 'text_ban';
  areaId: string;
  channelId: string;
  targetUid: string;
  rawJson: string;
}

export interface OopzWsCallbacks {
  onStateChange?: (connected: boolean) => void;
  onVoicePresence?: (event: VoicePresenceChange) => void;
  onChatMessage?: (message: OopzChatMessage) => void;
  onMessageRecall?: (areaId: string, channelId: string, messageId: string) => void;
  onChannelStructureChange?: (event: ChannelStructureEvent) => void;
  onAreaOrRoleChange?: (event: AreaOrRoleChangeEvent) => void;
  onModerationChange?: (event: ModerationEvent) => void;
}

interface WsHeaders {
  'Origin': string;
  'User-Agent': string;
  'x-oopz-device-id': string;
  'x-oopz-person-uid': string;
  'x-oopz-app-version': string;
  'x-oopz-platform': string;
}

interface WsOutboundFrame {
  time: string;
  body: string;
  event: number;
}

interface WsAuthBody {
  person: string;
  deviceId: string;
  signature: string;
  deviceName: string;
  platformName: string;
  reconnect: number;
}

interface WsSubBody {
  areas: string[];
  type: number;
  uid: string;
}

interface WsHeartbeatBody {
  person: string;
}

interface WsInboundFrame {
  event?: number;
  time?: string;
  body?: string | Object;
}

interface WsCheckResBody {
  checkRes?: boolean;
}

interface WsVoiceBody {
  area?: string;
  areaId?: string;
  channel?: string;
  channelId?: string;
  persons?: string[];
  activeNum?: number;
}

interface WsChatAttachmentRaw {
  attachmentType?: string;
  url?: string;
  fileKey?: string;
  width?: number;
  height?: number;
  displayName?: string;
}

interface WsChatMsgRaw {
  messageId?: string | number;
  id?: string | number;
  clientMessageId?: string;
  area?: string;
  areaId?: string;
  channel?: string;
  channelId?: string;
  person?: string | number;
  senderUid?: string | number;
  senderId?: string | number;
  content?: string;
  text?: string;
  timestamp?: string | number;
  attachments?: WsChatAttachmentRaw[];
}

interface WsMessageEnvelopeBody {
  data?: string | WsChatMsgRaw;
}

interface WsRecallBody {
  area?: string;
  areaId?: string;
  channel?: string;
  channelId?: string;
  messageId?: string | number;
  id?: string | number;
}

interface WsAdminBody {
  area?: string | number;
  areaId?: string | number;
  channel?: string | number;
  channelId?: string | number;
  id?: string | number;
  name?: string;
  group?: string | number;
  groupId?: string | number;
  person?: string | number;
  target?: string | number;
  uid?: string | number;
}

function asWsStr(value: string | number | undefined | null): string {
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number') {
    return String(value as number);
  }
  return '';
}

function parseWsTsMs(raw: string | number | undefined): number {
  if (typeof raw === 'number') {
    return raw > 1e14 ? Math.floor(raw / 1000) : raw;
  }
  if (typeof raw === 'string' && raw.length > 0) {
    const n = Number(raw);
    if (!isNaN(n) && n > 0) {
      return n > 1e14 ? Math.floor(n / 1000) : n;
    }
  }
  return Date.now();
}

function decodeWsPayload(value: string | ArrayBuffer): string {
  if (typeof value === 'string') {
    return value as string;
  }
  const bytes = new Uint8Array(value as ArrayBuffer);
  let raw = '';
  try {
    raw = util.TextDecoder.create('utf-8').decodeToString(bytes);
    if (raw.trim().startsWith('{')) {
      return raw;
    }
  } catch {
    raw = '';
  }
  try {
    const inflated = inflateZlib(bytes);
    return util.TextDecoder.create('utf-8').decodeToString(inflated);
  } catch {
    return raw;
  }
}

export class OopzWsClient {
  private callbacks: OopzWsCallbacks = {};
  private cred?: OopzCred;
  private subscribedAreas: string[] = [];
  private ws?: webSocket.WebSocket;
  private running: boolean = false;
  private connected: boolean = false;
  private subscribedThisConn: boolean = false;
  private generation: number = 0;
  private failures: number = 0;
  private heartbeatTimer: number = -1;
  private reconnectTimer: number = -1;
  private subFallbackTimer: number = -1;

  setCallbacks(callbacks: OopzWsCallbacks): void {
    this.callbacks = callbacks;
  }

  isConnected(): boolean {
    return this.connected;
  }

  start(cred: OopzCred, areaIds: string[]): void {
    this.cred = cred;
    this.subscribedAreas = areaIds.filter((a: string): boolean => a.length > 0);
    if (this.running) {
      if (this.connected) {
        this.sendSubscribe();
      }
      return;
    }
    this.running = true;
    this.failures = 0;
    this.connectOnce();
  }

  subscribeAreas(areaIds: string[]): void {
    const clean = areaIds.filter((a: string): boolean => a.length > 0);
    if (clean.length === 0) {
      return;
    }
    this.subscribedAreas = clean;
    if (this.connected) {
      this.sendSubscribe();
    }
  }

  stop(): void {
    this.running = false;
    this.generation++;
    this.clearTimers();
    this.closeSocket();
    this.updateConnected(false);
  }

  private clearTimers(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    if (this.subFallbackTimer !== -1) {
      clearTimeout(this.subFallbackTimer);
      this.subFallbackTimer = -1;
    }
  }

  private closeSocket(): void {
    const socket = this.ws;
    this.ws = undefined;
    if (socket !== undefined) {
      try {
        socket.close().catch(() => {});
      } catch {
        // ignore close errors
      }
    }
  }

  private updateConnected(next: boolean): void {
    if (this.connected === next) {
      return;
    }
    this.connected = next;
    this.callbacks.onStateChange?.(next);
  }

  private connectOnce(): void {
    const cred = this.cred;
    if (!this.running || cred === undefined) {
      return;
    }
    this.clearTimers();
    this.closeSocket();
    const gen = ++this.generation;
    const isCurrent = (): boolean => this.running && gen === this.generation;

    const socket = webSocket.createWebSocket();
    this.ws = socket;
    this.subscribedThisConn = false;

    socket.on('open', (err: BusinessError) => {
      if (!isCurrent()) return;
      if (err) {
        hilog.warn(0x0, TAG, 'WS open error code=%{public}d', err.code);
        this.scheduleReconnect(gen);
        return;
      }
      this.failures = 0;
      this.updateConnected(true);
      hilog.info(0x0, TAG, 'WS connected');
      this.sendAuth();
      this.startHeartbeat();
      if (this.subscribedAreas.length > 0) {
        this.subFallbackTimer = setTimeout(() => {
          if (isCurrent() && !this.subscribedThisConn) {
            this.sendSubscribe();
          }
        }, 500);
      }
    });

    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (!isCurrent() || err) return;
      const text = decodeWsPayload(value);
      if (text.length === 0) return;
      this.handleMessage(text);
    });

    socket.on('error', (err: BusinessError) => {
      if (!isCurrent()) return;
      hilog.warn(0x0, TAG, 'WS error code=%{public}d msg=%{public}s', err.code, err.message);
      this.scheduleReconnect(gen);
    });

    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (!isCurrent()) return;
      hilog.info(0x0, TAG, 'WS closed code=%{public}d reason=%{public}s', value?.code ?? -1, value?.reason ?? '');
      this.scheduleReconnect(gen);
    });

    const headers: WsHeaders = {
      'Origin': 'https://web.oopz.cn',
      'User-Agent': USER_AGENT,
      'x-oopz-device-id': cred.deviceId,
      'x-oopz-person-uid': cred.personUid,
      'x-oopz-app-version': OOPZ_APP_VERSION_NUMBER,
      'x-oopz-platform': OOPZ_PLATFORM
    };
    socket.connect(WS_URL, { header: headers }).catch((err: BusinessError) => {
      if (!isCurrent()) return;
      hilog.warn(0x0, TAG, 'WS connect rejected code=%{public}d', err.code);
      this.scheduleReconnect(gen);
    });
  }

  private scheduleReconnect(gen: number): void {
    if (!this.running || gen !== this.generation || this.reconnectTimer !== -1) {
      return;
    }
    this.clearTimers();
    this.closeSocket();
    this.updateConnected(false);
    const delaySec = Math.min(2 * Math.pow(2, this.failures), 60);
    this.failures++;
    hilog.info(0x0, TAG, 'WS reconnect in %{public}ds', delaySec);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.running && gen === this.generation) {
        this.connectOnce();
      }
    }, delaySec * 1000);
  }

  private sendFrame(event: number, bodyJson: string): void {
    const socket = this.ws;
    if (socket === undefined) {
      return;
    }
    const frame: WsOutboundFrame = {
      time: String(Date.now()),
      body: bodyJson,
      event: event
    };
    socket.send(JSON.stringify(frame)).catch((err: BusinessError) => {
      hilog.warn(0x0, TAG, 'WS send event=%{public}d failed code=%{public}d', event, err.code);
    });
  }

  private sendAuth(): void {
    const cred = this.cred;
    if (cred === undefined) return;
    const body: WsAuthBody = {
      person: cred.personUid,
      deviceId: cred.deviceId,
      signature: cred.jwtToken,
      deviceName: cred.deviceId,
      platformName: 'web',
      reconnect: this.failures > 0 ? 1 : 0
    };
    this.sendFrame(253, JSON.stringify(body));
  }

  private sendSubscribe(): void {
    const cred = this.cred;
    if (cred === undefined || this.subscribedAreas.length === 0) {
      return;
    }
    this.subscribedThisConn = true;
    const body: WsSubBody = {
      areas: this.subscribedAreas,
      type: 1,
      uid: cred.personUid
    };
    this.sendFrame(249, JSON.stringify(body));
    hilog.info(0x0, TAG, 'WS subscribed areas=%{public}d', this.subscribedAreas.length);
  }

  private startHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
    }
    this.heartbeatTimer = setInterval(() => {
      const cred = this.cred;
      if (!this.running || !this.connected || cred === undefined) {
        return;
      }
      const hb: WsHeartbeatBody = { person: cred.personUid };
      this.sendFrame(254, JSON.stringify(hb));
    }, HEARTBEAT_MS);
  }

  private handleMessage(rawText: string): void {
    let frame: WsInboundFrame;
    try {
      frame = JSON.parse(rawText) as WsInboundFrame;
    } catch {
      return;
    }
    const event = frame.event;
    if (event === undefined || event === 253 || event === 254) {
      return;
    }
    let bodyObj: Object | undefined = undefined;
    if (typeof frame.body === 'string') {
      try {
        bodyObj = JSON.parse(frame.body as string) as Object;
      } catch {
        bodyObj = undefined;
      }
    } else if (frame.body !== undefined && frame.body !== null) {
      bodyObj = frame.body as Object;
    }
    if (bodyObj === undefined) {
      return;
    }

    const checkBody = bodyObj as WsCheckResBody;
    if (typeof checkBody.checkRes === 'boolean') {
      hilog.info(0x0, TAG, 'WS auth checkRes=%{public}d', checkBody.checkRes ? 1 : 0);
      if (checkBody.checkRes && !this.subscribedThisConn) {
        this.sendSubscribe();
      }
      return;
    }

    if (event === 1) {
      if (!this.subscribedThisConn && this.subscribedAreas.length > 0) {
        this.sendSubscribe();
      }
      return;
    }

    if (event === 20 || event === 19) {
      const voice = bodyObj as WsVoiceBody;
      const areaId = voice.area !== undefined ? voice.area : (voice.areaId !== undefined ? voice.areaId : '');
      const channelId = voice.channel !== undefined ? voice.channel : (voice.channelId !== undefined ? voice.channelId : '');
      const persons = Array.isArray(voice.persons) ? voice.persons : [];
      const activeNum = typeof voice.activeNum === 'number' ? voice.activeNum : 0;
      if (areaId.length > 0 && channelId.length > 0) {
        hilog.info(0x0, TAG, 'WS voice event=%{public}d area=%{public}s ch=%{public}s num=%{public}d',
          event, areaId, channelId, activeNum);
        this.callbacks.onVoicePresence?.({
          areaId: areaId,
          channelId: channelId,
          entered: event === 20,
          persons: persons,
          activeNum: activeNum
        });
      }
      return;
    }

    if (event === 9) {
      const env = bodyObj as WsMessageEnvelopeBody;
      let msgRaw: WsChatMsgRaw = bodyObj as WsChatMsgRaw;
      if (typeof env.data === 'string') {
        try {
          msgRaw = JSON.parse(env.data as string) as WsChatMsgRaw;
        } catch {
          msgRaw = bodyObj as WsChatMsgRaw;
        }
      } else if (env.data !== undefined && env.data !== null) {
        msgRaw = env.data as WsChatMsgRaw;
      }
      const channelId = msgRaw.channel !== undefined ? msgRaw.channel : (msgRaw.channelId ?? '');
      const areaId = msgRaw.area !== undefined ? msgRaw.area : (msgRaw.areaId ?? '');
      const msgId = msgRaw.messageId !== undefined ? String(msgRaw.messageId)
        : (msgRaw.id !== undefined ? String(msgRaw.id) : '');
      const sender = msgRaw.person !== undefined ? String(msgRaw.person)
        : (msgRaw.senderUid !== undefined ? String(msgRaw.senderUid)
          : (msgRaw.senderId !== undefined ? String(msgRaw.senderId) : ''));
      const content = msgRaw.content !== undefined ? msgRaw.content : (msgRaw.text ?? '');
      const attachments: OopzChatAttachment[] = [];
      if (Array.isArray(msgRaw.attachments)) {
        for (const att of msgRaw.attachments) {
          const url = att.url ?? '';
          if (url.length === 0) continue;
          attachments.push({
            attachmentType: att.attachmentType ?? 'IMAGE',
            url: url,
            fileKey: att.fileKey ?? '',
            width: typeof att.width === 'number' ? att.width : 0,
            height: typeof att.height === 'number' ? att.height : 0,
            displayName: att.displayName ?? ''
          });
        }
      }
      if (channelId.length > 0 && (msgId.length > 0 || content.length > 0 || attachments.length > 0)) {
        hilog.info(0x0, TAG, 'WS chat msg ch=%{public}s id=%{public}s', channelId, msgId);
        this.callbacks.onChatMessage?.({
          messageId: msgId,
          clientMessageId: msgRaw.clientMessageId ?? '',
          areaId: areaId,
          channelId: channelId,
          senderUid: sender,
          content: content,
          timestampMs: parseWsTsMs(msgRaw.timestamp),
          attachments: attachments
        });
      }
      return;
    }

    if (event === 8) {
      const recall = bodyObj as WsRecallBody;
      const areaId = recall.area !== undefined ? recall.area : (recall.areaId ?? '');
      const channelId = recall.channel !== undefined ? recall.channel : (recall.channelId ?? '');
      const msgId = recall.messageId !== undefined ? String(recall.messageId)
        : (recall.id !== undefined ? String(recall.id) : '');
      if (channelId.length > 0 && msgId.length > 0) {
        hilog.info(0x0, TAG, 'WS chat recall ch=%{public}s id=%{public}s', channelId, msgId);
        this.callbacks.onMessageRecall?.(areaId, channelId, msgId);
      }
      return;
    }

    if (event === 25 || event === 18 || event === 13) {
      const chBody = bodyObj as WsAdminBody;
      const areaId = asWsStr(chBody.area).length > 0 ? asWsStr(chBody.area) : asWsStr(chBody.areaId);
      const channelId = asWsStr(chBody.channel).length > 0
        ? asWsStr(chBody.channel)
        : (asWsStr(chBody.channelId).length > 0 ? asWsStr(chBody.channelId) : asWsStr(chBody.id));
      const groupId = asWsStr(chBody.groupId).length > 0 ? asWsStr(chBody.groupId) : asWsStr(chBody.group);
      const action: 'create' | 'update' | 'delete' = event === 25 ? 'create' : (event === 18 ? 'update' : 'delete');
      hilog.info(0x0, TAG, 'WS channel event=%{public}d area=%{public}s ch=%{public}s raw=%{public}s',
        event, areaId, channelId, rawText.slice(0, 260));
      this.callbacks.onChannelStructureChange?.({
        eventCode: event,
        action: action,
        areaId: areaId,
        channelId: channelId,
        name: asWsStr(chBody.name),
        groupId: groupId,
        rawJson: rawText
      });
      return;
    }

    if (event === 28 || event === 52) {
      const areaBody = bodyObj as WsAdminBody;
      const areaId = asWsStr(areaBody.area).length > 0
        ? asWsStr(areaBody.area)
        : (asWsStr(areaBody.areaId).length > 0 ? asWsStr(areaBody.areaId) : asWsStr(areaBody.id));
      const kind: 'area' | 'role' = event === 28 ? 'area' : 'role';
      hilog.info(0x0, TAG, 'WS area/role event=%{public}d area=%{public}s', event, areaId);
      this.callbacks.onAreaOrRoleChange?.({
        eventCode: event,
        kind: kind,
        areaId: areaId,
        rawJson: rawText
      });
      return;
    }

    if (event === 11 || event === 12) {
      const modBody = bodyObj as WsAdminBody;
      const areaId = asWsStr(modBody.area).length > 0 ? asWsStr(modBody.area) : asWsStr(modBody.areaId);
      const channelId = asWsStr(modBody.channel).length > 0 ? asWsStr(modBody.channel) : asWsStr(modBody.channelId);
      const targetUid = asWsStr(modBody.target).length > 0
        ? asWsStr(modBody.target)
        : (asWsStr(modBody.person).length > 0 ? asWsStr(modBody.person) : asWsStr(modBody.uid));
      const kind: 'voice_ban' | 'text_ban' = event === 11 ? 'voice_ban' : 'text_ban';
      hilog.info(0x0, TAG, 'WS moderation event=%{public}d area=%{public}s target=%{public}s', event, areaId, targetUid);
      this.callbacks.onModerationChange?.({
        eventCode: event,
        kind: kind,
        areaId: areaId,
        channelId: channelId,
        targetUid: targetUid,
        rawJson: rawText
      });
    }
  }
}
