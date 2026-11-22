import { randomBytes, timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { inflateSync } from 'node:zlib';

const PORT = 28692;
const APP_ID = /^[0-9a-f]{32}$/i;
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class BridgeError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function idText(value) {
  if (typeof value === 'string') return value.trim();
  return Number.isSafeInteger(value) ? String(value) : '';
}

function tokenAppId(token) {
  if (!token.startsWith('007')) return '';
  try {
    const payload = inflateSync(Buffer.from(token.slice(3), 'base64'), { maxOutputLength: 65536 });
    // AccessToken2 starts with a length-prefixed signature and then a length-prefixed App ID.
    const start = 2 + payload.readUInt16LE(0);
    if (payload.readUInt16LE(start) === 32 && start + 34 <= payload.length) {
      return payload.toString('latin1', start + 2, start + 34);
    }
  } catch {
    return '';
  }
  return '';
}

class Rooms {
  active;
  timer;
  closing = false;
  tail = Promise.resolve();

  constructor(bot, personUid, keepAliveMs) {
    this.bot = bot;
    this.transport = bot.rest.transport;
    this.personUid = personUid;
    this.keepAliveMs = keepAliveMs;
  }

  run(action) {
    const result = this.tail.then(action);
    this.tail = result.catch(() => {});
    return result;
  }

  async areas() {
    const areas = await this.bot.areas.getJoinedAreas();
    return areas.map((area) => {
      const areaId = idText(area.areaId || area.id);
      return { areaId, name: area.name || area.areaName || areaId };
    }).filter((area) => area.areaId);
  }

  async voiceChannels(areaId) {
    const areas = await this.areas();
    if (!areas.some((area) => area.areaId === areaId)) {
      throw new BridgeError(404, '这个域不在测试账号已加入的域列表里');
    }
    const groups = await this.bot.areas.getAreaChannels(areaId);
    return groups.flatMap((group) => group.channels.filter((channel) => channel.type === 'VOICE')
      .map((channel) => {
        const channelId = idText(channel.channelId);
        return { channelId, name: channel.name || channelId, group: group.name || '' };
      })).filter((channel) => channel.channelId);
  }

  async enter(sessionId, areaId, channelId) {
    return this.run(async () => {
      if (this.closing) throw new BridgeError(503, '联调服务正在退出');
      if (this.active) {
        const current = this.active;
        if (!current.leaving && current.sessionId === sessionId && current.areaId === areaId &&
            current.channelId === channelId) return current.room;
        throw new BridgeError(409, '联调服务已有房间会话，请先退出');
      }

      const channels = await this.voiceChannels(areaId);
      if (!channels.some((channel) => channel.channelId === channelId)) {
        throw new BridgeError(404, '该语音频道不在所选域的频道列表里');
      }
      const detail = await this.transport.get('/client/v1/person/v1/selfDetail');
      const pid = idText((detail?.data ?? detail)?.pid);
      if (!/^\d{1,10}$/.test(pid) || Number(pid) === 0 || Number(pid) > 4294967295) {
        throw new BridgeError(502, 'Oopz 未返回有效的声网用户 ID');
      }

      const session = { sessionId, areaId, channelId, pid, room: undefined, leaving: false };
      this.active = session;
      try {
        session.room = await this.requestRoom(session);
        this.scheduleKeepAlive(session);
        console.info('[Oopz] 已登记入房');
        return session.room;
      } catch (error) {
        try {
          await this.leaveCurrent();
        } catch {
          console.warn('[Oopz] 入房失败后退房待重试');
        }
        throw error;
      }
    });
  }

  async requestRoom(session) {
    const result = await this.transport.post('/area/v2/channel/enter', {
      type: 'VOICE',
      area: session.areaId,
      channel: session.channelId,
      fromChannel: '',
      fromArea: '',
      password: '',
      sign: 1,
      pid: session.pid,
    });
    const sign = result?.data ?? result;
    const token = sign?.supplierSign;
    const channel = idText(sign?.roomId);
    if (typeof token !== 'string' || token.length === 0 || token.length > 16384 ||
        !channel || Buffer.byteLength(channel) > 64) {
      throw new BridgeError(502, 'Oopz 未返回语音房间参数，请检查频道权限和密码设置');
    }
    const appId = typeof sign.appId === 'string' && APP_ID.test(sign.appId) ? sign.appId : tokenAppId(token);
    if (!APP_ID.test(appId)) throw new BridgeError(502, 'Oopz 返回的语音参数缺少有效 App ID');
    return { appId, channel, uid: Number(session.pid), token };
  }

  async refresh(session) {
    const room = await this.requestRoom(session);
    if (room.channel !== session.room.channel || room.appId !== session.room.appId) {
      throw new BridgeError(409, 'Oopz 返回了新的 RTC 房间，请退房后重新加入');
    }
    session.room = room;
    return room;
  }

  scheduleKeepAlive(session) {
    if (this.closing || session.leaving) return;
    this.timer = setTimeout(() => {
      this.run(async () => {
        if (this.active !== session || this.closing || session.leaving) return;
        try {
          await this.refresh(session);
          console.info('[Oopz] 成员已续期');
        } catch (error) {
          const detail = error instanceof BridgeError ? error.message : 'Oopz 请求失败';
          console.warn(`[Oopz] 保活失败 · ${detail}`);
        } finally {
          this.scheduleKeepAlive(session);
        }
      });
    }, this.keepAliveMs);
    this.timer.unref();
  }

  renew(sessionId) {
    return this.run(async () => {
      const session = this.active;
      if (session?.sessionId !== sessionId || session.leaving) {
        throw new BridgeError(404, 'Oopz 房间会话已结束');
      }
      return (await this.refresh(session)).token;
    });
  }

  leave(sessionId) {
    return this.run(async () => {
      if (this.active?.sessionId === sessionId) await this.leaveCurrent();
    });
  }

  async leaveCurrent() {
    const session = this.active;
    if (!session) return;
    session.leaving = true;
    clearTimeout(this.timer);
    const query = new URLSearchParams({ area: session.areaId, channel: session.channelId, target: this.personUid });
    try {
      await this.transport.requestJson('DELETE', `/client/v1/area/v1/member/v1/removeFromChannel?${query}`);
    } catch (error) {
      if (error?.response?.status !== 204) throw error;
    }
    this.active = undefined;
    console.info('[Oopz] 已退房');
  }

  close() {
    this.closing = true;
    clearTimeout(this.timer);
    return this.run(() => this.leaveCurrent());
  }
}

async function readJson(request) {
  let size = 0;
  const parts = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 2048) throw new BridgeError(413, '联调请求过大');
    parts.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(parts).toString('utf8'));
  } catch {
    throw new BridgeError(400, '无效的联调请求');
  }
}

async function readSession(request) {
  const data = await readJson(request);
  if (typeof data?.sessionId !== 'string' || !SESSION_ID.test(data.sessionId)) {
    throw new BridgeError(400, '无效的房间会话 ID');
  }
  return data;
}

export function createOopzRoomBridge({ bot, personUid, authorize, pairingCode, keepAliveMs = 20000 }) {
  let rooms = bot ? new Rooms(bot, personUid, keepAliveMs) : undefined;
  let pendingLogin;
  let closing = false;

  async function authorizeAccount(code) {
    if (rooms) return;
    if (!authorize) throw new BridgeError(503, 'Node 尚未配置 Oopz 授权登录模块');
    if (pendingLogin) throw new BridgeError(409, '正在完成 Oopz 授权登录');

    pendingLogin = Promise.resolve().then(async () => {
      const account = await authorize(code);
      rooms = new Rooms(account.bot, account.personUid, keepAliveMs);
    });
    try {
      await pendingLogin;
    } catch {
      throw new BridgeError(502, 'Oopz 授权登录失败，请核对授权码和评估服务状态');
    } finally {
      pendingLogin = undefined;
    }
  }

  const key = Buffer.from(pairingCode);
  const server = createServer(async (request, response) => {
    function reply(status, payload) {
      response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(JSON.stringify(payload));
    }
    const suppliedKey = Buffer.from(String(request.headers['x-oopz-bridge-key'] ?? ''));
    if (suppliedKey.length !== key.length || !timingSafeEqual(suppliedKey, key)) {
      reply(401, { error: '联调配对码不正确' });
      return;
    }
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      if (closing) throw new BridgeError(503, '联调服务正在退出');
      if (request.method === 'GET' && url.pathname === '/account') {
        reply(200, { account: { signedIn: Boolean(rooms), canAuthorize: Boolean(authorize) } });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/account/authorize') {
        const data = await readJson(request);
        const code = typeof data?.authorizationCode === 'string' ? data.authorizationCode.trim() : '';
        if (!code || code.length > 512) throw new BridgeError(400, '请输入有效的 Oopz 授权码');
        if (closing) throw new BridgeError(503, '联调服务正在退出');
        await authorizeAccount(code);
        reply(200, { ok: true });
        return;
      }
      if (!rooms) throw new BridgeError(409, '请先完成 Oopz 授权登录');

      if (request.method === 'GET' && url.pathname === '/areas') {
        reply(200, { areas: await rooms.areas() });
      } else if (request.method === 'GET' && url.pathname === '/channels') {
        reply(200, { channels: await rooms.voiceChannels(url.searchParams.get('areaId')) });
      } else if (request.method === 'POST' && url.pathname === '/room/enter') {
        const { sessionId, areaId, channelId } = await readSession(request);
        if (typeof areaId !== 'string' || !areaId || typeof channelId !== 'string' || !channelId) {
          throw new BridgeError(400, '请先选择域和语音频道');
        }
        reply(200, { room: await rooms.enter(sessionId, areaId, channelId) });
      } else if (request.method === 'POST' && url.pathname === '/room/renew') {
        const { sessionId } = await readSession(request);
        reply(200, { token: await rooms.renew(sessionId) });
      } else if (request.method === 'POST' && url.pathname === '/room/leave') {
        const { sessionId } = await readSession(request);
        await rooms.leave(sessionId);
        reply(200, { ok: true });
      } else {
        reply(404, { error: '未知的联调接口' });
      }
    } catch (error) {
      if (error instanceof BridgeError) {
        reply(error.status, { error: error.message });
      } else {
        const upstream = error?.response?.status;
        const hint = Number.isInteger(upstream) ? `（HTTP ${upstream}）` : '';
        reply(502, { error: `Oopz 请求失败${hint}，请检查测试账号会话和网络` });
      }
    }
  });
  async function closeRoom() {
    closing = true;
    await pendingLogin?.catch(() => {});
    try {
      await rooms?.close();
    } finally {
      await rooms?.bot.rest.close?.();
    }
  }
  return { server, closeRoom };
}

async function connectOopz(sdk, data) {
  const credentials = sdk.OopzLoginCredentials.fromMapping(data);
  const config = credentials.toConfig({ request: { timeout: 8000 }, retry: { maxAttempts: 1 } });
  const bot = new sdk.OopzBot(config);
  await bot.rest.start();
  return { bot, personUid: credentials.personUid };
}

async function main() {
  const args = process.argv.slice(2);
  const adapterMode = args[0] === '--auth-adapter';
  if (args.length !== (adapterMode ? 2 : 1) || args.some((arg) => !arg)) {
    throw new Error('用法：node tools/oopz-room-bridge.mjs <会话凭据 JSON> 或 --auth-adapter <授权模块>');
  }
  let sdk;
  try {
    sdk = await import('oopz-sdk');
  } catch {
    throw new Error('无法加载 oopz-sdk，请先运行 npm ci --prefix tools --ignore-scripts');
  }
  let initialAccount;
  let authorize;
  if (adapterMode) {
    let adapter;
    try {
      adapter = await import(pathToFileURL(resolve(args[1])).href);
    } catch {
      throw new Error('无法加载 Oopz 授权登录模块，请检查本机模块路径');
    }
    if (typeof adapter.exchangeAuthorizationCode !== 'function') {
      throw new Error('授权模块需要导出 exchangeAuthorizationCode 函数');
    }
    authorize = async (code) => {
      const data = await adapter.exchangeAuthorizationCode(code, AbortSignal.timeout(25000));
      const account = await connectOopz(sdk, data);
      try {
        await account.bot.rest.transport.get('/client/v1/person/v1/selfDetail');
        return account;
      } catch (error) {
        await account.bot.rest.close();
        throw error;
      }
    };
  } else {
    try {
      initialAccount = await connectOopz(sdk, JSON.parse(await readFile(args[0], 'utf8')));
    } catch {
      throw new Error('无法加载已授权测试账号的会话配置，请检查文件和字段');
    }
  }
  const pairingCode = randomBytes(18).toString('base64url');
  const { server, closeRoom } = createOopzRoomBridge({ ...initialAccount, authorize, pairingCode });
  try {
    server.listen(PORT, '127.0.0.1');
    await once(server, 'listening');
  } catch {
    await closeRoom();
    throw new Error(`启动联调服务失败，请检查本机 ${PORT} 端口`);
  }

  console.info(`Node 联调服务 · 127.0.0.1:${PORT}`);
  console.info(`本次联调配对码 · ${pairingCode}`);
  let stopping = false;
  async function stop() {
    if (stopping) return;
    stopping = true;
    server.close();
    try {
      await closeRoom();
    } catch {
      console.warn('[Oopz] 停止服务时退房请求失败，请在官方客户端确认房间状态');
    }
  }
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
