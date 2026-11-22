// Area administration permissions, structural queries, channel CRUD, and member/message moderation APIs.

import { OopzSession, OopzVoiceChannel } from './OopzSession';

/** Known Oopz area privilege keys from /area/v3/info areaRoleInfos.privilegeKeys. */
export class OopzPrivilege {
  static readonly MANAGE_GROUP: string = 'MANAGE_GROUP';
  static readonly MANAGE_CHANNEL: string = 'MANAGE_CHANNEL';
  static readonly MANAGE_ROLE_MEMBER: string = 'MANAGE_ROLE_MEMBER';
  static readonly MOVE_VOICE: string = 'MOVE_VOICE';
  static readonly MOVE_MEMBER: string = 'MOVE_MEMBER';
  static readonly BLOCK_MEMBER: string = 'BLOCK_MEMBER';
  static readonly DISABLE_TEXT: string = 'DISABLE_TEXT';
  static readonly DISABLE_VOICE: string = 'DISABLE_VOICE';
  static readonly RECALL_MESSAGE: string = 'RECALL_MESSAGE';
  static readonly TOP_MESSAGE: string = 'TOP_MESSAGE';
  static readonly MENTION_ALL: string = 'MENTION_ALL';
  static readonly IMPORTANT_MESSAGE: string = 'IMPORTANT_MESSAGE';
  static readonly ORGANIZE_LOTTERY: string = 'ORGANIZE_LOTTERY';
  static readonly UNLIMITED_CHAT: string = 'UNLIMITED_CHAT';
}

export interface OopzAreaRole {
  roleId: number;
  name: string;
  description: string;
  sort: number;
  isDisplay: boolean;
  type: number;
}

export interface OopzAreaDetail {
  areaId: string;
  code: string;
  name: string;
  desc: string;
  avatar: string;
  banner: string;
  isPublic: boolean;
  isOwner: boolean;
  maxRole: number;
  roles: number[];
  privilegeKeys: string[];
  categoryKeys: string[];
  roleList: OopzAreaRole[];
  homePageChannelId: string;
  defaultEnterChannelId: string;
  disableTextTo: number;
  disableVoiceTo: number;
}

export interface OopzChannelGroup {
  groupId: string;
  areaId: string;
  name: string;
  sort: number;
  system: boolean;
  isEnableTemp: boolean;
  channels: OopzVoiceChannel[];
}

export interface OopzChannelSetting {
  channelId: string;
  areaId: string;
  groupId: string;
  name: string;
  type: string;
  maxMember: number;
  voiceQuality: string;
  voiceDelay: string;
  secret: boolean;
  memberPublic: boolean;
  hasPassword: boolean;
  password: string;
  accessControlEnabled: boolean;
  voiceControlEnabled: boolean;
  textControlEnabled: boolean;
  articleControlEnabled: boolean;
  textGapSecond: number;
  articleGapSecond: number;
  commentGapSecond: number;
  voiceRoles: number[];
  textRoles: number[];
  articleRoles: number[];
  accessibleRoles: number[];
  accessibleMembers: string[];
}

export interface OopzAreaMember {
  uid: string;
  role: number;
  roleSort: number;
  online: boolean;
  roleStatus: number;
  playingState: string;
  displayType: string;
}

export interface OopzAreaMemberList {
  members: OopzAreaMember[];
  totalCount: number;
  offsetStart: number;
  offsetEnd: number;
}

export interface OopzAreaMemberDetail {
  uid: string;
  disableTextTo: number;
  disableVoiceTo: number;
  now: number;
  higherUid: string;
  score: number;
  roles: OopzAreaRole[];
}

export type OopzCreateChannelType = 'TEXT' | 'VOICE';

export interface CreateChannelOptions {
  areaId: string;
  name: string;
  type: OopzCreateChannelType;
  groupId?: string;
  secret?: boolean;
  maxMember?: number;
}

export interface CreateChannelResult {
  channelId: string;
  name: string;
  type: string;
  groupId: string;
}

export interface EditChannelOptions {
  areaId: string;
  channelId: string;
  name?: string;
  groupId?: string;
  maxMember?: number;
  secret?: boolean;
  voiceQuality?: string;
  voiceDelay?: string;
  memberPublic?: boolean;
  textGapSecond?: number;
}

interface RawAreaRole {
  roleID?: number;
  roleId?: number;
  name?: string;
  description?: string;
  sort?: number;
  isDisplay?: boolean;
  type?: number;
}

interface RawAreaRoleInfos {
  maxRole?: number;
  roles?: number[];
  privilegeKeys?: string[];
  categoryKeys?: string[];
  isOwner?: boolean;
}

interface RawAreaInfoData {
  id?: string | number;
  areaId?: string | number;
  code?: string | number;
  name?: string;
  desc?: string;
  description?: string;
  avatar?: string;
  banner?: string;
  isPublic?: boolean;
  roleList?: RawAreaRole[];
  areaRoleInfos?: RawAreaRoleInfos;
  homePageChannelId?: string;
  defaultEnterChannelId?: string;
  disableTextTo?: number | string | null;
  disableVoiceTo?: number | string | null;
}

interface RawAreaInfoEnvelope {
  data?: RawAreaInfoData;
}

interface RawChannelSettings {
  maxMember?: number;
  voiceQuality?: string;
}

interface RawChannelNode {
  id?: string | number;
  channelId?: string | number;
  groupId?: string | number;
  name?: string;
  type?: string;
  secret?: boolean;
  tag?: string;
  isTemp?: boolean;
  settings?: RawChannelSettings;
}

interface RawChannelGroupNode {
  id?: string | number;
  groupId?: string | number;
  area?: string | number;
  name?: string;
  sort?: number;
  system?: boolean;
  IsEnableTemp?: boolean;
  isEnableTemp?: boolean;
  channels?: RawChannelNode[];
}

interface RawChannelGroupsEnvelope {
  data?: RawChannelGroupNode[];
}

interface RawChannelSettingData {
  channel?: string | number;
  channelId?: string | number;
  areaId?: string | number;
  groupId?: string | number;
  name?: string;
  type?: string;
  maxMember?: number;
  voiceQuality?: string;
  voiceDelay?: string;
  secret?: boolean;
  memberPublic?: boolean;
  hasPassword?: boolean;
  password?: string;
  accessControlEnabled?: boolean;
  voiceControlEnabled?: boolean;
  textControlEnabled?: boolean;
  articleControlEnabled?: boolean;
  textGapSecond?: number;
  articleGapSecond?: number;
  commentGapSecond?: number;
  voiceRoles?: number[];
  textRoles?: number[];
  articleRoles?: number[];
  accessibleRoles?: number[];
  accessibleMembers?: string[];
}

interface RawChannelSettingEnvelope {
  data?: RawChannelSettingData;
}

interface RawAreaMemberNode {
  uid?: string | number;
  role?: number;
  roleSort?: number;
  online?: number | boolean;
  roleStatus?: number;
  playingState?: string;
  displayType?: string;
}

interface RawAreaMembersData {
  members?: RawAreaMemberNode[];
  totalCount?: number;
}

interface RawAreaMembersEnvelope {
  data?: RawAreaMembersData;
}

interface RawAreaUserDetailData {
  disableTextTo?: number | string | null;
  disableVoiceTo?: number | string | null;
  now?: number;
  higherUid?: string | number;
  score?: number;
  list?: RawAreaRole[];
  roles?: RawAreaRole[];
}

interface RawAreaUserDetailEnvelope {
  data?: RawAreaUserDetailData;
}

interface GroupNameBody {
  name: string;
  area: string;
  id?: string;
}

interface CreateChannelBody {
  area: string;
  name: string;
  type: string;
  group: string;
  secret: boolean;
  maxMember: number;
}

interface RawCreateChannelData {
  channelId?: string | number;
  id?: string | number;
  channel?: string | number;
  name?: string;
  type?: string | number;
  groupId?: string | number;
  group?: string | number;
}

interface RawCreateChannelEnvelope {
  data?: RawCreateChannelData;
  channelId?: string | number;
  id?: string | number;
  channel?: string | number;
  name?: string;
  type?: string | number;
}

interface EditChannelBody {
  channel: string;
  name: string;
  textGapSecond: number;
  area: string;
  voiceQuality: string;
  voiceDelay: string;
  maxMember: number;
  voiceControlEnabled: boolean;
  textControlEnabled: boolean;
  textRoles: number[];
  voiceRoles: number[];
  accessControlEnabled: boolean;
  accessible: number[];
  accessibleMembers: string[];
  secret: boolean;
  hasPassword: boolean;
  password: string;
}

interface AreaTargetBody {
  area: string;
  target: string;
}

interface RecallGimBody {
  area: string;
  channel: string;
  messageId: string;
  timestamp: string;
  target: string;
}

function asStr(value: string | number | undefined | null): string {
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number') {
    return String(value as number);
  }
  return '';
}

function asNum(value: number | string | undefined | null, fallback: number = 0): number {
  if (typeof value === 'number' && !isNaN(value)) {
    return value;
  }
  if (typeof value === 'string' && value.length > 0) {
    const parsed = Number(value);
    if (!isNaN(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

function copyNumberArray(input: number[] | undefined): number[] {
  const out: number[] = [];
  if (Array.isArray(input)) {
    for (let i = 0; i < input.length; i++) {
      if (typeof input[i] === 'number') {
        out.push(input[i]);
      }
    }
  }
  return out;
}

function copyStringArray(input: string[] | undefined): string[] {
  const out: string[] = [];
  if (Array.isArray(input)) {
    for (let i = 0; i < input.length; i++) {
      if (typeof input[i] === 'string') {
        out.push(input[i]);
      }
    }
  }
  return out;
}

function parseRoles(rawList: RawAreaRole[] | undefined): OopzAreaRole[] {
  const out: OopzAreaRole[] = [];
  if (!Array.isArray(rawList)) {
    return out;
  }
  for (let i = 0; i < rawList.length; i++) {
    const r = rawList[i];
    out.push({
      roleId: typeof r.roleID === 'number' ? r.roleID : (typeof r.roleId === 'number' ? r.roleId : 0),
      name: asStr(r.name),
      description: asStr(r.description),
      sort: typeof r.sort === 'number' ? r.sort : 0,
      isDisplay: r.isDisplay === true,
      type: typeof r.type === 'number' ? r.type : 0
    });
  }
  return out;
}

export function hasAreaPrivilege(detail: OopzAreaDetail | undefined, privilege: string): boolean {
  if (detail === undefined) {
    return false;
  }
  if (detail.isOwner) {
    return true;
  }
  return detail.privilegeKeys.indexOf(privilege) >= 0;
}

export function canModerateMember(selfDetail: OopzAreaDetail | undefined,
  targetDetail: OopzAreaMemberDetail | undefined, selfUid: string): boolean {
  if (targetDetail === undefined) {
    return false;
  }
  if (targetDetail.uid.length > 0 && targetDetail.uid === selfUid) {
    return false;
  }
  if (selfDetail !== undefined && selfDetail.isOwner) {
    return true;
  }
  if (targetDetail.higherUid.length > 0 && targetDetail.higherUid === selfUid) {
    return true;
  }
  if (selfDetail === undefined) {
    return false;
  }
  let selfSort = 0;
  for (let i = 0; i < selfDetail.roleList.length; i++) {
    const r = selfDetail.roleList[i];
    if (selfDetail.roles.indexOf(r.roleId) >= 0 && r.sort > selfSort) {
      selfSort = r.sort;
    }
  }
  let targetSort = 0;
  for (let i = 0; i < targetDetail.roles.length; i++) {
    if (targetDetail.roles[i].sort > targetSort) {
      targetSort = targetDetail.roles[i].sort;
    }
  }
  return selfSort > targetSort;
}

export function mapTextMuteIntervalId(durationSeconds: number): number {
  if (durationSeconds <= 60) {
    return 1;
  }
  if (durationSeconds <= 300) {
    return 2;
  }
  if (durationSeconds <= 3600) {
    return 3;
  }
  if (durationSeconds <= 86400) {
    return 4;
  }
  if (durationSeconds <= 259200) {
    return 5;
  }
  return 6;
}

export function mapVoiceMuteIntervalId(durationSeconds: number): number {
  if (durationSeconds <= 60) {
    return 7;
  }
  if (durationSeconds <= 300) {
    return 8;
  }
  if (durationSeconds <= 3600) {
    return 9;
  }
  if (durationSeconds <= 86400) {
    return 10;
  }
  if (durationSeconds <= 259200) {
    return 11;
  }
  return 12;
}

/** Area structure and moderation requests for the signed-in account. */
export class OopzAreaAdmin {
  private readonly session: OopzSession;

  constructor(session: OopzSession) {
    this.session = session;
  }

  private requireArg(value: string, label: string): void {
    if (value.trim().length === 0) {
      throw new Error('缺少参数：' + label);
    }
  }

  async getAreaDetail(areaId: string): Promise<OopzAreaDetail> {
    this.requireArg(areaId, 'areaId');
    const path = '/area/v3/info?area=' + encodeURIComponent(areaId);
    const raw = await this.session.signedRequestJson(path, 'GET');
    const env = raw as RawAreaInfoEnvelope;
    const data: RawAreaInfoData = env.data !== undefined ? env.data : (raw as RawAreaInfoData);
    const roleInfos: RawAreaRoleInfos = data.areaRoleInfos !== undefined ? data.areaRoleInfos : {};
    const resolvedId = asStr(data.id).length > 0 ? asStr(data.id) : asStr(data.areaId);
    return {
      areaId: resolvedId.length > 0 ? resolvedId : areaId,
      code: asStr(data.code),
      name: asStr(data.name),
      desc: asStr(data.desc).length > 0 ? asStr(data.desc) : asStr(data.description),
      avatar: asStr(data.avatar),
      banner: asStr(data.banner),
      isPublic: data.isPublic === true,
      isOwner: roleInfos.isOwner === true,
      maxRole: typeof roleInfos.maxRole === 'number' ? roleInfos.maxRole : 0,
      roles: copyNumberArray(roleInfos.roles),
      privilegeKeys: copyStringArray(roleInfos.privilegeKeys),
      categoryKeys: copyStringArray(roleInfos.categoryKeys),
      roleList: parseRoles(data.roleList),
      homePageChannelId: asStr(data.homePageChannelId),
      defaultEnterChannelId: asStr(data.defaultEnterChannelId),
      disableTextTo: asNum(data.disableTextTo, 0),
      disableVoiceTo: asNum(data.disableVoiceTo, 0)
    };
  }

  async getChannelGroups(areaId: string): Promise<OopzChannelGroup[]> {
    this.requireArg(areaId, 'areaId');
    const path = '/client/v1/area/v1/detail/v1/channels?area=' + encodeURIComponent(areaId);
    const raw = await this.session.signedRequestJson(path, 'GET');
    let groups: RawChannelGroupNode[] = [];
    if (Array.isArray(raw)) {
      groups = raw as RawChannelGroupNode[];
    } else {
      const env = raw as RawChannelGroupsEnvelope;
      if (Array.isArray(env.data)) {
        groups = env.data;
      }
    }
    const out: OopzChannelGroup[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const groupId = asStr(g.id).length > 0 ? asStr(g.id) : asStr(g.groupId);
      const groupName = asStr(g.name);
      const rawChannels = Array.isArray(g.channels) ? g.channels : [];
      const channels: OopzVoiceChannel[] = [];
      for (let j = 0; j < rawChannels.length; j++) {
        const ch = rawChannels[j];
        const channelId = asStr(ch.id).length > 0 ? asStr(ch.id) : asStr(ch.channelId);
        if (channelId.length === 0) {
          continue;
        }
        const chType = asStr(ch.type);
        const maxMember = typeof ch.settings?.maxMember === 'number' ? ch.settings.maxMember : 50;
        const voiceQuality = asStr(ch.settings?.voiceQuality);
        const chGroupId = asStr(ch.groupId).length > 0 ? asStr(ch.groupId) : groupId;
        channels.push({
          channelId: channelId,
          name: asStr(ch.name).length > 0 ? asStr(ch.name) : channelId,
          group: groupName,
          type: chType,
          maxMember: maxMember,
          voiceQuality: voiceQuality.length > 0 ? voiceQuality : '64k',
          secret: ch.secret === true,
          groupId: chGroupId,
          tag: asStr(ch.tag),
          isTemp: ch.isTemp === true
        });
      }
      out.push({
        groupId: groupId,
        areaId: asStr(g.area).length > 0 ? asStr(g.area) : areaId,
        name: groupName,
        sort: typeof g.sort === 'number' ? g.sort : 0,
        system: g.system === true,
        isEnableTemp: g.IsEnableTemp === true || g.isEnableTemp === true,
        channels: channels
      });
    }
    return out;
  }

  async getChannelSetting(channelId: string): Promise<OopzChannelSetting> {
    this.requireArg(channelId, 'channelId');
    const path = '/area/v3/channel/setting/info?channel=' + encodeURIComponent(channelId);
    const raw = await this.session.signedRequestJson(path, 'GET');
    const env = raw as RawChannelSettingEnvelope;
    const data: RawChannelSettingData = env.data !== undefined ? env.data : (raw as RawChannelSettingData);
    const resolvedId = asStr(data.channel).length > 0 ? asStr(data.channel) : asStr(data.channelId);
    return {
      channelId: resolvedId.length > 0 ? resolvedId : channelId,
      areaId: asStr(data.areaId),
      groupId: asStr(data.groupId),
      name: asStr(data.name),
      type: asStr(data.type),
      maxMember: typeof data.maxMember === 'number' ? data.maxMember : 50,
      voiceQuality: asStr(data.voiceQuality),
      voiceDelay: asStr(data.voiceDelay),
      secret: data.secret === true,
      memberPublic: data.memberPublic === true,
      hasPassword: data.hasPassword === true,
      password: asStr(data.password),
      accessControlEnabled: data.accessControlEnabled === true,
      voiceControlEnabled: data.voiceControlEnabled === true,
      textControlEnabled: data.textControlEnabled === true,
      articleControlEnabled: data.articleControlEnabled === true,
      textGapSecond: typeof data.textGapSecond === 'number' ? data.textGapSecond : 0,
      articleGapSecond: typeof data.articleGapSecond === 'number' ? data.articleGapSecond : 0,
      commentGapSecond: typeof data.commentGapSecond === 'number' ? data.commentGapSecond : 0,
      voiceRoles: copyNumberArray(data.voiceRoles),
      textRoles: copyNumberArray(data.textRoles),
      articleRoles: copyNumberArray(data.articleRoles),
      accessibleRoles: copyNumberArray(data.accessibleRoles),
      accessibleMembers: copyStringArray(data.accessibleMembers)
    };
  }

  async getAreaMembers(areaId: string, offsetStart: number = 0, limit: number = 50): Promise<OopzAreaMemberList> {
    this.requireArg(areaId, 'areaId');
    const safeStart = Math.max(0, Math.floor(offsetStart));
    const safeLimit = Math.max(1, Math.min(200, Math.floor(limit)));
    const offsetEnd = safeStart + safeLimit - 1;
    const path = '/area/v3/members?area=' + encodeURIComponent(areaId) +
      '&offsetStart=' + String(safeStart) + '&offsetEnd=' + String(offsetEnd);
    const raw = await this.session.signedRequestJson(path, 'GET');
    const env = raw as RawAreaMembersEnvelope;
    const data: RawAreaMembersData = env.data !== undefined ? env.data : (raw as RawAreaMembersData);
    const list = Array.isArray(data.members) ? data.members : [];
    const members: OopzAreaMember[] = [];
    for (let i = 0; i < list.length; i++) {
      const m = list[i];
      const uid = asStr(m.uid);
      if (uid.length === 0) {
        continue;
      }
      members.push({
        uid: uid,
        role: typeof m.role === 'number' ? m.role : 0,
        roleSort: typeof m.roleSort === 'number' ? m.roleSort : 0,
        online: m.online === true || m.online === 1,
        roleStatus: typeof m.roleStatus === 'number' ? m.roleStatus : -1,
        playingState: asStr(m.playingState),
        displayType: asStr(m.displayType)
      });
    }
    return {
      members: members,
      totalCount: typeof data.totalCount === 'number' ? data.totalCount : members.length,
      offsetStart: safeStart,
      offsetEnd: offsetEnd
    };
  }

  async getAreaMemberDetail(areaId: string, targetUid: string): Promise<OopzAreaMemberDetail> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/area/v3/userDetail?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid);
    const raw = await this.session.signedRequestJson(path, 'GET');
    const env = raw as RawAreaUserDetailEnvelope;
    const data: RawAreaUserDetailData = env.data !== undefined ? env.data : (raw as RawAreaUserDetailData);
    const rawRoles = Array.isArray(data.list) ? data.list : data.roles;
    return {
      uid: targetUid,
      disableTextTo: asNum(data.disableTextTo, 0),
      disableVoiceTo: asNum(data.disableVoiceTo, 0),
      now: typeof data.now === 'number' ? data.now : 0,
      higherUid: asStr(data.higherUid),
      score: typeof data.score === 'number' ? data.score : 0,
      roles: parseRoles(rawRoles)
    };
  }

  async createChannelGroup(areaId: string, name: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(name, 'name');
    const body: GroupNameBody = { name: name.trim(), area: areaId };
    await this.session.signedRequestVoid('/client/v1/area/v1/group/v1/create', 'POST', JSON.stringify(body));
  }

  async renameChannelGroup(areaId: string, groupId: string, name: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(groupId, 'groupId');
    this.requireArg(name, 'name');
    const body: GroupNameBody = { name: name.trim(), id: groupId, area: areaId };
    await this.session.signedRequestVoid('/client/v1/area/v1/group/v1/change', 'PUT', JSON.stringify(body));
  }

  async deleteChannelGroup(areaId: string, groupId: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(groupId, 'groupId');
    const path = '/client/v1/area/v1/group/v1/delete?id=' + encodeURIComponent(groupId) +
      '&area=' + encodeURIComponent(areaId);
    await this.session.signedRequestVoid(path, 'DELETE');
  }

  async createChannel(options: CreateChannelOptions): Promise<CreateChannelResult> {
    this.requireArg(options.areaId, 'areaId');
    this.requireArg(options.name, 'name');
    const body: CreateChannelBody = {
      area: options.areaId,
      name: options.name.trim(),
      type: options.type === 'VOICE' ? 'VOICE' : 'TEXT',
      group: options.groupId !== undefined ? options.groupId : '',
      secret: options.secret === true,
      maxMember: options.maxMember !== undefined ? options.maxMember : (options.type === 'VOICE' ? 50 : 100)
    };
    const raw = await this.session.signedRequestJson('/client/v1/area/v1/channel/v1/create', 'POST',
      JSON.stringify(body));
    const env = raw as RawCreateChannelEnvelope;
    const data: RawCreateChannelData = env.data !== undefined ? env.data : {
      channelId: env.channelId,
      id: env.id,
      channel: env.channel,
      name: env.name,
      type: env.type
    };
    const channelId = asStr(data.channelId).length > 0
      ? asStr(data.channelId)
      : (asStr(data.id).length > 0 ? asStr(data.id) : asStr(data.channel));
    const resolvedType = asStr(data.type).length > 0 ? asStr(data.type) : options.type;
    const resolvedGroup = asStr(data.groupId).length > 0
      ? asStr(data.groupId)
      : (asStr(data.group).length > 0 ? asStr(data.group) : body.group);
    return {
      channelId: channelId,
      name: asStr(data.name).length > 0 ? asStr(data.name) : body.name,
      type: resolvedType,
      groupId: resolvedGroup
    };
  }

  async editChannel(options: EditChannelOptions): Promise<void> {
    this.requireArg(options.areaId, 'areaId');
    this.requireArg(options.channelId, 'channelId');
    const current = await this.getChannelSetting(options.channelId);
    const fallbackMax = (current.type === 'TEXT' && (current.maxMember <= 0 || current.maxMember > 30000))
      ? 30000
      : current.maxMember;
    const body: EditChannelBody = {
      channel: options.channelId,
      name: options.name !== undefined ? options.name : current.name,
      textGapSecond: options.textGapSecond !== undefined ? options.textGapSecond : current.textGapSecond,
      area: options.areaId,
      voiceQuality: options.voiceQuality !== undefined
        ? options.voiceQuality
        : (current.voiceQuality.length > 0 ? current.voiceQuality : '64k'),
      voiceDelay: options.voiceDelay !== undefined
        ? options.voiceDelay
        : (current.voiceDelay.length > 0 ? current.voiceDelay : 'LOW'),
      maxMember: options.maxMember !== undefined ? options.maxMember : fallbackMax,
      voiceControlEnabled: current.voiceControlEnabled,
      textControlEnabled: current.textControlEnabled,
      textRoles: current.textRoles,
      voiceRoles: current.voiceRoles,
      accessControlEnabled: current.accessControlEnabled,
      accessible: current.accessibleRoles,
      accessibleMembers: current.accessibleMembers,
      secret: options.secret !== undefined ? options.secret : current.secret,
      hasPassword: current.hasPassword,
      password: current.password
    };
    await this.session.signedRequestVoid('/area/v3/channel/setting/edit', 'POST', JSON.stringify(body));
  }

  async deleteChannel(areaId: string, channelId: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(channelId, 'channelId');
    const path = '/client/v1/area/v1/channel/v1/delete?area=' + encodeURIComponent(areaId) +
      '&channel=' + encodeURIComponent(channelId);
    await this.session.signedRequestVoid(path, 'DELETE');
  }

  async kickFromVoiceChannel(areaId: string, channelId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(channelId, 'channelId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/client/v1/area/v1/member/v1/removeFromChannel?area=' + encodeURIComponent(areaId) +
      '&channel=' + encodeURIComponent(channelId) + '&target=' + encodeURIComponent(targetUid);
    await this.session.signedRequestVoid(path, 'DELETE');
  }

  async kickFromArea(areaId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const body: AreaTargetBody = { area: areaId, target: targetUid };
    await this.session.signedRequestVoid('/area/v3/remove', 'POST', JSON.stringify(body));
  }

  async banMember(areaId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/client/v1/area/v1/block?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid);
    await this.session.signedRequestVoid(path, 'DELETE');
  }

  async unbanMember(areaId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/client/v1/area/v1/unblock?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid);
    await this.session.signedRequestVoid(path, 'PATCH');
  }

  async muteText(areaId: string, targetUid: string, durationSeconds: number = 300): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const intervalId = mapTextMuteIntervalId(durationSeconds);
    const path = '/client/v1/area/v1/member/v1/disableText?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid) + '&intervalId=' + String(intervalId);
    await this.session.signedRequestVoid(path, 'PATCH');
  }

  async unmuteText(areaId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/client/v1/area/v1/member/v1/recoverText?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid);
    await this.session.signedRequestVoid(path, 'PATCH');
  }

  async muteVoice(areaId: string, targetUid: string, durationSeconds: number = 300): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const intervalId = mapVoiceMuteIntervalId(durationSeconds);
    const path = '/client/v1/area/v1/member/v1/disableVoice?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid) + '&intervalId=' + String(intervalId);
    await this.session.signedRequestVoid(path, 'PATCH');
  }

  async unmuteVoice(areaId: string, targetUid: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(targetUid, 'targetUid');
    const path = '/client/v1/area/v1/member/v1/recoverVoice?area=' + encodeURIComponent(areaId) +
      '&target=' + encodeURIComponent(targetUid);
    await this.session.signedRequestVoid(path, 'PATCH');
  }

  async recallMessage(areaId: string, channelId: string, messageId: string): Promise<void> {
    this.requireArg(areaId, 'areaId');
    this.requireArg(channelId, 'channelId');
    this.requireArg(messageId, 'messageId');
    const body: RecallGimBody = {
      area: areaId,
      channel: channelId,
      messageId: messageId,
      timestamp: String(Date.now() * 1000),
      target: ''
    };
    await this.session.signedRequestVoid('/im/session/v1/recallGim', 'POST', JSON.stringify(body));
  }
}
