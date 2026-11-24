import { getTheme } from '../common/Theme';
import {
  canModerateMember, hasAreaPrivilege, OopzAreaDetail, OopzAreaMember, OopzAreaMemberDetail, OopzPrivilege
} from '../oopz/OopzAreaAdmin';
import { OopzVoiceChannel } from '../oopz/OopzSession';
import { AppStore } from '../store/AppStore';

const PAGE_SIZE = 20;

export function canManageAreaMembers(detail: OopzAreaDetail | undefined): boolean {
  return [OopzPrivilege.MOVE_MEMBER, OopzPrivilege.BLOCK_MEMBER, OopzPrivilege.DISABLE_TEXT,
    OopzPrivilege.DISABLE_VOICE, OopzPrivilege.MOVE_VOICE].some((key: string) => hasAreaPrivilege(detail, key));
}

enum MemberAction {
  MuteText = '文字禁言 5 分钟',
  UnmuteText = '解除文字禁言',
  MuteVoice = '语音禁言 5 分钟',
  UnmuteVoice = '解除语音禁言',
  KickVoice = '移出语音频道',
  KickArea = '移出域',
  Ban = '封禁成员'
}

function toMillis(time: number): number {
  if (time > 1e14) return Math.floor(time / 1000);
  return time < 1e11 ? time * 1000 : time;
}

function isMuted(until: number, now: number): boolean {
  return toMillis(until) > (now > 0 ? toMillis(now) : Date.now());
}

@Component
export struct AreaMemberAdmin {
  @Prop @Watch('resetArea') areaId: string = '';
  @Prop areaDetail?: OopzAreaDetail = undefined;
  @Prop isDark: boolean = true;
  onDetailNavigation: (opened: boolean, back: () => void) => void = () => {};
  @State private members: OopzAreaMember[] = [];
  @State private pageOffset: number = 0;
  @State private total: number = 0;
  @State private selected?: OopzAreaMember = undefined;
  @State private detail?: OopzAreaMemberDetail = undefined;
  @State private voiceChannel?: OopzVoiceChannel = undefined;
  @State private loading: boolean = false;
  @State private writing: boolean = false;
  @State private errorText: string = '';
  @State private resultText: string = '';
  private readonly store: AppStore = AppStore.get();
  private revision: number = 0;
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.resetArea();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.revision++;
    this.onDetailNavigation(false, () => {});
  }

  private closeDetail(): void {
    this.selected = undefined;
    this.detail = undefined;
    this.voiceChannel = undefined;
    this.onDetailNavigation(false, () => {});
  }

  private backToList(): void {
    if (!this.active || this.writing) return;
    this.revision++;
    this.loading = false;
    this.errorText = '';
    this.resultText = '';
    this.closeDetail();
  }

  private resetArea(): void {
    this.revision++;
    this.closeDetail();
    this.members = [];
    this.total = 0;
    this.pageOffset = 0;
    this.writing = false;
    this.resultText = '';
    if (this.active) this.loadPage(0);
  }

  private current(revision: number, area: string, self: string): boolean {
    return this.active && this.revision === revision && this.areaId === area &&
      self === this.store.session.getCred()?.personUid;
  }

  private async loadPage(offset: number): Promise<void> {
    const revision = ++this.revision;
    const area = this.areaId;
    const self = this.store.session.getCred()?.personUid ?? '';
    if (this.selected) this.closeDetail();
    this.loading = true;
    this.errorText = '';
    try {
      let page = await this.store.admin.getAreaMembers(area, offset, PAGE_SIZE);
      if (offset > 0 && page.members.length === 0 && this.current(revision, area, self)) {
        const lastPage = Math.max(0, Math.ceil(page.totalCount / PAGE_SIZE) - 1) * PAGE_SIZE;
        if (lastPage < offset) page = await this.store.admin.getAreaMembers(area, lastPage, PAGE_SIZE);
      }
      if (!this.current(revision, area, self)) return;
      await this.store.ensurePersons(page.members.map((m: OopzAreaMember) => m.uid));
      if (!this.current(revision, area, self)) return;
      this.members = page.members;
      this.pageOffset = page.offsetStart;
      this.total = page.totalCount;
    } catch (error) {
      if (this.current(revision, area, self)) this.errorText = '读取成员列表失败：' + (error as Error).message;
    } finally {
      if (revision === this.revision) this.loading = false;
    }
  }

  private async loadMember(member: OopzAreaMember): Promise<void> {
    const revision = ++this.revision;
    const area = this.areaId;
    const self = this.store.session.getCred()?.personUid ?? '';
    const openingDetail = !this.selected;
    this.selected = member;
    if (openingDetail) this.onDetailNavigation(true, () => { this.backToList(); });
    this.detail = undefined;
    this.voiceChannel = undefined;
    this.errorText = '';
    this.loading = true;
    try {
      const detail = await this.store.admin.getAreaMemberDetail(area, member.uid);
      if (!this.current(revision, area, self)) return;
      this.detail = detail;
      const voice = (this.store.channelsByArea.get(area) ?? [])
        .filter((c: OopzVoiceChannel) => c.type === 'VOICE' || c.type === 'AUDIO');
      const presence = await this.store.session.channelMembers(area, voice.map((c: OopzVoiceChannel) => c.channelId));
      if (!this.current(revision, area, self)) return;
      this.voiceChannel = voice.find((c: OopzVoiceChannel) => presence.get(c.channelId)?.some(m => m.uid === member.uid));
    } catch (error) {
      if (this.current(revision, area, self)) {
        this.errorText = (this.detail ? '读取语音频道失败：' : '读取成员详情失败：') + (error as Error).message;
      }
    } finally {
      if (revision === this.revision) this.loading = false;
    }
  }

  private name(uid: string): string {
    return this.store.getPersonByUid(uid)?.name || uid;
  }

  private mayTarget(area: OopzAreaDetail | undefined, member: OopzAreaMember, target: OopzAreaMemberDetail,
    self: string): boolean {
    const owner = this.store.areas.find(a => a.areaId === this.areaId)?.owner;
    if (!area || area.areaId !== this.areaId || !self || target.uid !== member.uid || member.uid === owner ||
      !canModerateMember(area, target, self)) return false;
    if (area.isOwner) return true;
    let ownRank = 0;
    let targetRank = member.roleSort;
    for (const role of area.roleList) {
      if (area.roles.includes(role.roleId)) ownRank = Math.max(ownRank, role.sort);
    }
    for (const role of target.roles) targetRank = Math.max(targetRank, role.sort);
    return ownRank > targetRank;
  }

  private permits(action: MemberAction, area: OopzAreaDetail | undefined, target: OopzAreaMemberDetail): boolean {
    switch (action) {
      case MemberAction.MuteText:
      case MemberAction.UnmuteText:
        return hasAreaPrivilege(area, OopzPrivilege.DISABLE_TEXT) &&
          isMuted(target.disableTextTo, target.now) === (action === MemberAction.UnmuteText);
      case MemberAction.MuteVoice:
      case MemberAction.UnmuteVoice:
        return hasAreaPrivilege(area, OopzPrivilege.DISABLE_VOICE) &&
          isMuted(target.disableVoiceTo, target.now) === (action === MemberAction.UnmuteVoice);
      case MemberAction.KickVoice: return hasAreaPrivilege(area, OopzPrivilege.MOVE_VOICE) && !!this.voiceChannel;
      case MemberAction.KickArea: return hasAreaPrivilege(area, OopzPrivilege.MOVE_MEMBER) ||
        hasAreaPrivilege(area, OopzPrivilege.BLOCK_MEMBER);
      case MemberAction.Ban: return hasAreaPrivilege(area, OopzPrivilege.BLOCK_MEMBER);
    }
  }

  private confirmAction(action: MemberAction): void {
    const member = this.selected;
    if (!member || this.loading || this.writing) return;
    const revision = this.revision;
    const area = this.areaId;
    const self = this.store.session.getCred()?.personUid ?? '';
    const channel = action === MemberAction.KickVoice ? this.voiceChannel : undefined;
    const context = channel ? '频道：' + channel.name : '域：' + (this.areaDetail?.name || this.areaId);
    this.getUIContext().showAlertDialog({
      title: action,
      message: context + '\n成员：' + this.name(member.uid) + '\nUID：' + member.uid,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '确认', action: () => {
        if (this.current(revision, area, self)) this.apply(action, member, channel);
      } }
    });
  }

  private async apply(action: MemberAction, member: OopzAreaMember, channel?: OopzVoiceChannel): Promise<void> {
    if (this.writing || this.selected?.uid !== member.uid) return;
    const revision = this.revision;
    const area = this.areaId;
    const self = this.store.session.getCred()?.personUid ?? '';
    this.writing = true;
    this.errorText = '';
    this.resultText = '';
    try {
      const authority = await this.store.loadAreaDetail(area, true);
      if (!this.current(revision, area, self)) return;
      const fresh = await this.store.admin.getAreaMemberDetail(area, member.uid);
      if (!this.current(revision, area, self)) return;
      this.areaDetail = authority;
      this.detail = fresh;
      if (!this.mayTarget(authority, member, fresh, self) || !this.permits(action, authority, fresh)) {
        throw new Error('成员状态或管理权限已变更，请重新查看');
      }
      switch (action) {
        case MemberAction.KickVoice: {
          if (!channel) throw new Error('缺少语音频道');
          const presence = await this.store.session.channelMembers(area, [channel.channelId]);
          if (!this.current(revision, area, self)) return;
          if (!presence.get(channel.channelId)?.some(m => m.uid === member.uid)) {
            this.voiceChannel = undefined;
            throw new Error('成员已离开该语音频道');
          }
          await this.store.kickFromVoiceChannel(area, channel.channelId, member.uid);
          break;
        }
        case MemberAction.MuteText: await this.store.muteText(area, member.uid, 300); break;
        case MemberAction.UnmuteText: await this.store.unmuteText(area, member.uid); break;
        case MemberAction.MuteVoice: await this.store.muteVoice(area, member.uid, 300); break;
        case MemberAction.UnmuteVoice: await this.store.unmuteVoice(area, member.uid); break;
        case MemberAction.KickArea: await this.store.kickFromArea(area, member.uid); break;
        case MemberAction.Ban: await this.store.banMember(area, member.uid); break;
      }
      if (!this.current(revision, area, self)) return;
      this.resultText = action + '成功';
      this.writing = false;
      if (action === MemberAction.KickArea || action === MemberAction.Ban) {
        this.members = this.members.filter(m => m.uid !== member.uid);
        await this.loadPage(this.pageOffset);
      } else {
        await this.loadMember(member);
      }
    } catch (error) {
      if (this.current(revision, area, self)) this.errorText = (error as Error).message;
    } finally {
      if (revision === this.revision) this.writing = false;
    }
  }

  @Builder
  private button(label: string, click: () => void, enabled: boolean = true, destructive: boolean = false) {
    Button(label).fontSize(14).height(38)
      .fontColor(destructive ? getTheme(this.isDark).dangerText : getTheme(this.isDark).accent)
      .backgroundColor(destructive ? getTheme(this.isDark).dangerFill : getTheme(this.isDark).accentSoft)
      .enabled(enabled && !this.writing).onClick(click)
  }

  @Builder
  private listBody() {
    Row({ space: 8 }) {
      Text('域成员 · ' + this.total).fontSize(17).fontWeight(FontWeight.Medium)
        .fontColor(getTheme(this.isDark).text).layoutWeight(1)
      this.button('刷新', () => { this.resultText = ''; this.loadPage(this.pageOffset); }, !this.loading)
    }.width('100%')
    if (this.members.length === 0 && !this.loading && !this.errorText) {
      Text('暂无成员').fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
    }
    List({ space: 2 }) {
      ForEach(this.members, (m: OopzAreaMember) => {
        ListItem() {
          Row({ space: 10 }) {
            Circle({ width: 8, height: 8 }).fill(m.online ? getTheme(this.isDark).speaking : getTheme(this.isDark).textMuted)
            Column({ space: 2 }) {
              Text(this.name(m.uid)).fontSize(15).fontColor(getTheme(this.isDark).text)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(m.uid === this.store.session.getCred()?.personUid ? '我' : (m.online ? '在线' : '离线'))
                .fontSize(12).fontColor(getTheme(this.isDark).textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([getTheme(this.isDark).textMuted])
          }.width('100%').padding(10).backgroundColor(getTheme(this.isDark).surface).borderRadius(12)
        }.enabled(!this.loading).onClick(() => { this.resultText = ''; this.loadMember(m); })
      }, (m: OopzAreaMember) => m.uid + '|' + m.online + '|' + m.roleSort + '|' + this.name(m.uid))
    }.width('100%').layoutWeight(1)
    if (this.total > PAGE_SIZE || this.pageOffset > 0) {
      Row({ space: 8 }) {
        this.button('上一页', () => { this.loadPage(Math.max(0, this.pageOffset - PAGE_SIZE)); }, !this.loading && this.pageOffset > 0)
        Text((Math.floor(this.pageOffset / PAGE_SIZE) + 1) + ' / ' + Math.max(1, Math.ceil(this.total / PAGE_SIZE)))
          .fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
        this.button('下一页', () => { this.loadPage(this.pageOffset + PAGE_SIZE); },
          !this.loading && this.pageOffset + PAGE_SIZE < this.total)
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)
    }
  }

  @Builder
  private actions(member: OopzAreaMember, target: OopzAreaMemberDetail) {
    if (this.mayTarget(this.areaDetail, member, target, this.store.session.getCred()?.personUid ?? '')) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([MemberAction.MuteText, MemberAction.UnmuteText, MemberAction.MuteVoice, MemberAction.UnmuteVoice,
          MemberAction.KickVoice, MemberAction.KickArea, MemberAction.Ban], (action: MemberAction) => {
          if (this.permits(action, this.areaDetail, target)) {
            Row() {
              this.button(action, () => { this.confirmAction(action); }, !this.loading,
                action === MemberAction.KickArea || action === MemberAction.Ban)
            }.margin({ right: 8, bottom: 8 })
          }
        }, (action: MemberAction) => action)
      }.width('100%')
    } else {
      Text('该成员仅可查看').fontSize(13).fontColor(getTheme(this.isDark).textMuted)
    }
  }

  @Builder
  private memberBody(member: OopzAreaMember) {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text(this.name(member.uid)).fontSize(19).fontWeight(FontWeight.Bold).fontColor(getTheme(this.isDark).text)
            .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(member.online ? '在线' : '离线').fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
          this.button('刷新', () => { this.resultText = ''; this.loadMember(member); }, !this.loading)
        }.width('100%')
        Text('UID：' + member.uid).fontSize(12).fontColor(getTheme(this.isDark).textMuted)
        if (this.detail) {
          Text('身份组：' + (this.detail.roles.map(r => r.name).filter(n => n.length > 0).join('、') || '无'))
            .fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
          Text('文字：' + (isMuted(this.detail.disableTextTo, this.detail.now) ? '禁言中' : '可发言') +
            '　语音：' + (isMuted(this.detail.disableVoiceTo, this.detail.now) ? '禁言中' : '可发言'))
            .fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
          if (!this.loading && (this.voiceChannel || !this.errorText)) {
            Text('所在频道：' + (this.voiceChannel?.name ?? '未加入语音频道'))
              .fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
          }
          this.actions(member, this.detail)
        }
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
        .backgroundColor(getTheme(this.isDark).surface).borderRadius(14)
    }.width('100%').layoutWeight(1).align(Alignment.TopStart)
  }

  build() {
    Column({ space: 10 }) {
      if (this.resultText) {
        Text(this.resultText).fontSize(13).fontColor(getTheme(this.isDark).accent)
      }
      if (this.errorText) {
        Text(this.errorText).fontSize(13).fontColor(getTheme(this.isDark).warn)
      }
      if (this.loading || this.writing) {
        LoadingProgress().width(24).height(24).color(getTheme(this.isDark).accent)
      }
      if (this.selected) {
        this.memberBody(this.selected)
      } else {
        this.listBody()
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start).padding(12)
  }
}
