import { http } from '@kit.NetworkKit';
import type { RtcRoom } from './NativeRtcCall';

const BRIDGE_URL = 'http://127.0.0.1:28692';

export interface OopzArea {
  areaId: string;
  name: string;
}

export interface OopzVoiceChannel {
  channelId: string;
  name: string;
  group: string;
}

interface OopzAccountState {
  signedIn: boolean;
  canAuthorize: boolean;
}

interface BridgeRequest {
  sessionId?: string;
  areaId?: string;
  channelId?: string;
  authorizationCode?: string;
}

interface BridgeResponse {
  account?: OopzAccountState;
  areas?: OopzArea[];
  channels?: OopzVoiceChannel[];
  room?: RtcRoom;
  token?: string;
  error?: string;
}

class BridgeHttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export class OopzRoomBridge {
  private readonly pairingCode: string;

  constructor(pairingCode: string) {
    this.pairingCode = pairingCode;
  }

  private async request(path: string, body?: BridgeRequest): Promise<BridgeResponse> {
    const request = http.createHttp();
    let response: http.HttpResponse;
    try {
      response = await request.request(`${BRIDGE_URL}${path}`, {
        method: body === undefined ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: { 'X-Oopz-Bridge-Key': this.pairingCode, 'Content-Type': 'application/json' },
        extraData: body === undefined ? undefined : JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        connectTimeout: 4000,
        readTimeout: 45000
      });
    } catch {
      throw new Error('无法连接 Node 联调服务，请检查服务和 HDC 反向端口');
    } finally {
      request.destroy();
    }
    if (typeof response.result !== 'string') {
      throw new Error('Node 联调服务返回了无效响应');
    }
    let result: BridgeResponse;
    try {
      result = JSON.parse(response.result) as BridgeResponse;
    } catch {
      throw new Error('Node 联调服务返回了无效响应');
    }
    if (response.responseCode !== 200) {
      throw new BridgeHttpError(response.responseCode, result?.error ?? `联调请求失败（${response.responseCode}）`);
    }
    if (result === null || typeof result !== 'object') {
      throw new Error('Node 联调服务返回了无效响应');
    }
    return result;
  }

  async account(): Promise<OopzAccountState> {
    const response = await this.request('/account');
    if (response.account === undefined) {
      throw new Error('Node 联调服务没有返回账号状态');
    }
    return response.account;
  }

  async authorize(authorizationCode: string): Promise<void> {
    await this.request('/account/authorize', { authorizationCode });
  }

  async areas(): Promise<OopzArea[]> {
    return (await this.request('/areas')).areas ?? [];
  }

  async channels(areaId: string): Promise<OopzVoiceChannel[]> {
    return (await this.request(`/channels?areaId=${encodeURIComponent(areaId)}`)).channels ?? [];
  }

  async enter(sessionId: string, areaId: string, channelId: string): Promise<RtcRoom> {
    const response = await this.request('/room/enter', { sessionId, areaId, channelId });
    if (response.room === undefined) {
      throw new Error('联调服务没有返回语音房间参数');
    }
    return response.room;
  }

  async renew(sessionId: string): Promise<string> {
    const response = await this.request('/room/renew', { sessionId });
    if (!response.token) {
      throw new Error('联调服务没有返回新的语音 Token');
    }
    return response.token;
  }

  async leave(sessionId: string): Promise<void> {
    try {
      await this.request('/room/leave', { sessionId });
    } catch (error) {
      // Pairing codes last for one Node process. A restarted bridge has no previous session.
      if (!(error instanceof BridgeHttpError) || error.status !== 401) throw error as Error;
    }
  }
}
