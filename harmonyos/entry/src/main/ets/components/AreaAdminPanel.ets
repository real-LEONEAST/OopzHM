import { AppSpacing, getTheme } from '../common/Theme';
import { hasAreaPrivilege, OopzAreaDetail, OopzChannelGroup, OopzCreateChannelType, OopzPrivilege } from '../oopz/OopzAreaAdmin';
import { OopzVoiceChannel } from '../oopz/OopzSession';
import { AppStore } from '../store/AppStore';
import { AreaMemberAdmin, canManageAreaMembers } from './AreaMemberAdmin';

export function canOpenAreaAdmin(detail: OopzAreaDetail | undefined): boolean {
  return hasAreaPrivilege(detail, OopzPrivilege.MANAGE_GROUP) ||
    hasAreaPrivilege(detail, OopzPrivilege.MANAGE_CHANNEL) || canManageAreaMembers(detail);
}

type StructureAction = 'newGroup' | 'renameGroup' | 'deleteGroup' | 'newChannel' | 'editChannel' | 'deleteChannel';

interface DeleteSnapshot {
  name: string;
  channelIds: string[];
}

@Component
export struct AreaAdminPanel {
  @Prop @Watch('resetArea') areaId: string = '';
  @Prop areaName: string = '';
  @Prop isDesktop: boolean = false;
  @Prop @Watch('syncSnapshot') revision: number = 0;
  onBackHandler: (handler: () => void) => void = () => {};
  onClose: () => void = () => {};
  onStructureChanged: (areaId: string) => void = () => {};

  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzInCall') private inCall: boolean = false;
  @StorageProp('oopzCallAreaId') private callAreaId: string = '';
  @StorageProp('oopzCallChannelId') private callChannelId: string = '';
  @State private detail: OopzAreaDetail | undefined = undefined;
  @State private groups: OopzChannelGroup[] = [];
  @State private snapshot: number = 0;
  @State private members: boolean = false;
  @State private memberDetailOpen: boolean = false;
  private backToMembers?: () => void;
  @State private loading: boolean = true;
  @State private busy: boolean = false;
  @State private notice: string = '';
  @State private error: string = '';

  @State private editor: StructureAction | '' = '';
  @State private draftName: string = '';
  @State private channelType: OopzCreateChannelType = 'VOICE';
  @State private numberText: string = '';
  @State private targetName: string = '';
  private groupId: string = '';
  private channelId: string = '';
  private originalNumber: string = '';
  private generation: number = 0;
  private mounted: boolean = false;
  private readonly store: AppStore = AppStore.get();

  aboutToAppear(): void {
    this.mounted = true;
    this.onBackHandler(() => { if (this.mounted) this.goBack(); });
    this.resetArea();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.generation++;
  }

  private resetArea(): void {
    if (!this.mounted) return;
    this.generation++;
    this.detail = undefined;
    this.groups = [];
    this.editor = '';
    this.members = false;
    this.memberDetailOpen = false;
    this.backToMembers = undefined;
    this.busy = false;
    this.notice = '';
    this.reload();
  }

  private canStructure(): boolean {
    return hasAreaPrivilege(this.detail, OopzPrivilege.MANAGE_GROUP) ||
      hasAreaPrivilege(this.detail, OopzPrivilege.MANAGE_CHANNEL);
  }

  private applyDetail(detail: OopzAreaDetail | undefined): void {
    this.detail = detail?.areaId === this.areaId ? detail : undefined;
    if (!canManageAreaMembers(this.detail)) {
      this.members = false;
      this.memberDetailOpen = false;
      this.backToMembers = undefined;
    }
    else if (!this.canStructure()) this.members = true;
    if (this.editor !== '' && !this.permits(this.editor)) this.editor = '';
  }

  private syncSnapshot(): void {
    if (!this.mounted || this.loading) return;
    this.applyDetail(this.store.getAreaDetail(this.areaId));
    const groups = this.store.channelGroupsByArea.get(this.areaId);
    if (groups !== undefined) {
      this.groups = groups;
      this.snapshot++;
    }
  }

  private async reload(): Promise<void> {
    const generation = ++this.generation;
    this.loading = true;
    this.error = '';
    try {
      const detail = await this.store.loadAreaDetail(this.areaId, true);
      if (generation !== this.generation) return;
      this.applyDetail(detail);
      if (this.canStructure()) {
        const groups = await this.store.loadChannelGroups(this.areaId);
        if (generation !== this.generation) return;
        this.groups = this.store.channelGroupsByArea.get(this.areaId) ?? groups;
        this.snapshot++;
      }
    } catch (e) {
      if (generation === this.generation) {
        this.detail = undefined;
        this.groups = [];
        this.error = (e as Error).message;
      }
    } finally {
      if (generation === this.generation) this.loading = false;
    }
  }

  private isGroupAction(action: StructureAction): boolean {
    return action === 'newGroup' || action === 'renameGroup' || action === 'deleteGroup';
  }

  private permits(action: StructureAction): boolean {
    return hasAreaPrivilege(this.detail, this.isGroupAction(action) ? OopzPrivilege.MANAGE_GROUP : OopzPrivilege.MANAGE_CHANNEL);
  }

  private activeChannel(id: string): boolean {
    return this.inCall && this.callAreaId === this.areaId && this.callChannelId === id;
  }

  private groupInCall(group: OopzChannelGroup): boolean {
    return group.channels.some((channel: OopzVoiceChannel): boolean => this.activeChannel(channel.channelId));
  }

  private targetExists(action: StructureAction, groupId: string, channelId: string): boolean {
    if (action === 'newGroup' || (action === 'newChannel' && !groupId)) return true;
    const group = this.groups.find((item: OopzChannelGroup): boolean => item.groupId === groupId);
    if (group === undefined) return false;
    if (action === 'renameGroup' || action === 'deleteGroup') {
      return !group.system && (action !== 'deleteGroup' || !this.groupInCall(group));
    }
    if (action === 'newChannel') return true;
    return group.channels.some((channel: OopzVoiceChannel): boolean => channel.channelId === channelId) &&
      (action !== 'deleteChannel' || !this.activeChannel(channelId));
  }

  private openEditor(action: StructureAction, group?: OopzChannelGroup, channel?: OopzVoiceChannel): void {
    if (this.busy || !this.permits(action)) return;
    this.notice = '';
    this.error = '';
    this.groupId = group?.groupId ?? '';
    this.channelId = channel?.channelId ?? '';
    this.targetName = group?.name ?? '';
    this.draftName = action === 'renameGroup' ? this.targetName : (channel?.name ?? '');
    this.channelType = channel?.type === 'TEXT' ? 'TEXT' : 'VOICE';
    this.numberText = '';
    this.originalNumber = '';
    this.editor = action;
    if (action === 'editChannel') this.loadSetting();
  }

  private goBack(): void {
    if (this.busy) return;
    if (this.editor !== '') {
      this.editor = '';
      this.error = '';
    } else if (this.members && this.memberDetailOpen) {
      this.backToMembers?.();
    } else {
      this.onClose();
    }
  }

  private backLabel(): string {
    if (this.editor !== '') return '频道与分组';
    if (this.members && this.memberDetailOpen) return '成员管理';
    return this.isDesktop ? '返回原频道' : '频道列表';
  }

  private pageTitle(): string {
    if (this.members && this.memberDetailOpen) return '成员详情';
    switch (this.editor) {
      case 'newGroup': return '新建分组';
      case 'renameGroup': return '重命名分组';
      case 'newChannel': return '新建频道';
      case 'editChannel': return '编辑频道';
      default: return '域管理';
    }
  }

  private async loadSetting(): Promise<void> {
    const generation = this.generation;
    this.busy = true;
    try {
      const setting = await this.store.admin.getChannelSetting(this.channelId);
      if (generation !== this.generation || this.editor !== 'editChannel') return;
      this.draftName = setting.name;
      this.numberText = String(this.channelType === 'VOICE' ? setting.maxMember : setting.textGapSecond);
      this.originalNumber = this.numberText;
    } catch (e) {
      if (generation === this.generation) {
        this.editor = '';
        this.error = (e as Error).message;
      }
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }

  private confirmDelete(action: StructureAction, group: OopzChannelGroup, channel?: OopzVoiceChannel): void {
    if (this.busy || !this.permits(action)) return;
    const generation = this.generation;
    const channelId = channel?.channelId ?? '';
    const label = channel === undefined ? '分组' : '频道';
    const name = channel?.name ?? group.name;
    const count = channel === undefined && group.channels.length > 0 ? `该分组包含 ${group.channels.length} 个频道。` : '';
    const expected: DeleteSnapshot = { name: name,
      channelIds: channel === undefined ? group.channels.map((item: OopzVoiceChannel): string => item.channelId) : [] };
    this.getUIContext().showAlertDialog({
      title: `删除${label}`, message: `${count}确认删除「${name}」？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: getTheme(this.isDark).dangerFill, action: () => {
        if (generation === this.generation) this.submit(action, group.groupId, channelId, expected);
      } }
    });
  }

  private matchesConfirmation(groups: OopzChannelGroup[], groupId: string, channelId: string, expected: DeleteSnapshot): boolean {
    const group = groups.find((item: OopzChannelGroup): boolean => item.groupId === groupId);
    if (group === undefined) return false;
    if (channelId) {
      return group.channels.some((channel: OopzVoiceChannel): boolean =>
        channel.channelId === channelId && channel.name === expected.name);
    }
    return group.name === expected.name && group.channels.length === expected.channelIds.length &&
      group.channels.every((channel: OopzVoiceChannel): boolean => expected.channelIds.includes(channel.channelId));
  }

  private async submit(action: StructureAction, groupId: string, channelId: string, expected?: DeleteSnapshot): Promise<void> {
    if (this.busy || !this.permits(action)) return;
    const areaId = this.areaId;
    const generation = this.generation;
    const name = this.draftName.trim();
    const type = this.channelType;
    const editsNumber = action === 'editChannel' && this.numberText !== this.originalNumber;
    const number = Number(this.numberText);
    this.notice = '';
    this.error = '';
    if (action !== 'deleteGroup' && action !== 'deleteChannel' && !name) {
      this.error = '请输入名称';
      return;
    }
    if (editsNumber && (!/^\d+$/.test(this.numberText) || !Number.isSafeInteger(number) || (type === 'VOICE' && number < 1))) {
      this.error = type === 'VOICE' ? '请输入大于零的频道人数' : '请输入非负整数秒数';
      return;
    }
    this.busy = true;
    try {
      const detail = await this.store.loadAreaDetail(areaId, true);
      if (generation !== this.generation) return;
      this.applyDetail(detail);
      if (!this.permits(action)) throw new Error('当前账号缺少此项管理权限');
      if (expected !== undefined) {
        const groups = await this.store.loadChannelGroups(areaId);
        if (generation !== this.generation) return;
        this.groups = this.store.channelGroupsByArea.get(areaId) ?? groups;
        this.snapshot++;
        if (!this.matchesConfirmation(groups, groupId, channelId, expected) ||
          !this.matchesConfirmation(this.groups, groupId, channelId, expected)) throw new Error('删除对象已变化，请重新确认');
      }
      if (!this.targetExists(action, groupId, channelId)) throw new Error('操作对象已变化，请刷新分组与频道');
      switch (action) {
        case 'newGroup': await this.store.createChannelGroup(areaId, name); break;
        case 'renameGroup': await this.store.renameChannelGroup(areaId, groupId, name); break;
        case 'deleteGroup': await this.store.deleteChannelGroup(areaId, groupId); break;
        case 'newChannel': await this.store.createChannel({ areaId: areaId, groupId: groupId, name: name, type: type }); break;
        case 'editChannel':
          await this.store.editChannel({ areaId: areaId, channelId: channelId, name: name,
            maxMember: editsNumber && type === 'VOICE' ? number : undefined,
            textGapSecond: editsNumber && type === 'TEXT' ? number : undefined });
          break;
        case 'deleteChannel': await this.store.deleteChannel(areaId, channelId); break;
      }
      this.onStructureChanged(areaId);
      if (generation !== this.generation) return;
      this.editor = '';
      this.notice = action === 'deleteChannel' || action === 'deleteGroup' ? '已删除' : '已保存';
      const groups = this.store.channelGroupsByArea.get(areaId);
      if (groups !== undefined) {
        this.groups = groups;
        this.snapshot++;
      } else {
        this.error = '列表刷新失败，请点刷新重新读取';
      }
    } catch (e) {
      if (generation === this.generation) this.error = (e as Error).message;
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }

  @Builder
  private smallButton(label: string, primary: boolean, action: () => void) {
    Button(label).fontSize(13).height(34).padding({ left: 13, right: 13 })
      .borderRadius(8).border({ width: 1, color: primary ? getTheme(this.isDark).accent : getTheme(this.isDark).border })
      .backgroundColor(primary ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceSolid)
      .fontColor(primary ? getTheme(this.isDark).accent : getTheme(this.isDark).text)
      .enabled(!this.busy && !this.loading).onClick(action)
  }

  @Builder
  private backButton() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(14).fontColor([getTheme(this.isDark).text])
        Text(this.backLabel()).fontSize(14).fontColor(getTheme(this.isDark).text)
      }
    }.height(36).padding({ left: 7, right: 7 }).borderRadius(8)
      .backgroundColor(this.isDesktop ? getTheme(this.isDark).surfaceAlt : Color.Transparent)
      .accessibilityText(this.backLabel()).enabled(!this.busy).onClick(() => { this.goBack(); })
  }

  @Builder
  private titleBar() {
    Row({ space: 10 }) {
      if (!this.isDesktop) {
        this.backButton()
      }
      Text(this.pageTitle()).fontSize(this.isDesktop ? 20 : 18).fontWeight(FontWeight.Bold)
        .layoutWeight(1).fontColor(getTheme(this.isDark).text)
        .textAlign(this.isDesktop ? TextAlign.Start : TextAlign.End)
      if (this.isDesktop) {
        this.backButton()
      }
    }.width('100%').padding({ bottom: 8 }).border({ width: { bottom: 1 }, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private channelMenu(group: OopzChannelGroup, channel: OopzVoiceChannel) {
    Menu() {
      MenuItem({ content: '编辑频道' }).onClick(() => { this.openEditor('editChannel', group, channel); })
      MenuItem({ content: '删除频道' }).enabled(!this.activeChannel(channel.channelId))
        .onClick(() => { this.confirmDelete('deleteChannel', group, channel); })
    }
  }

  @Builder
  private groupMenu(group: OopzChannelGroup) {
    Menu() {
      if (this.permits('newChannel')) {
        MenuItem({ content: '新建频道' }).onClick(() => { this.openEditor('newChannel', group); })
      }
      if (!group.system && this.permits('renameGroup')) {
        if (!this.isDesktop) {
          MenuItem({ content: '重命名分组' }).onClick(() => { this.openEditor('renameGroup', group); })
        }
        MenuItem({ content: '删除分组' }).enabled(!this.groupInCall(group))
          .onClick(() => { this.confirmDelete('deleteGroup', group); })
      }
    }
  }

  @Builder
  private groupCard(group: OopzChannelGroup) {
    Column() {
      Row({ space: 8 }) {
        Text(group.name || '未命名分组').fontSize(16).fontWeight(FontWeight.Medium).fontColor(getTheme(this.isDark).text)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${group.channels.length} 个频道`).fontSize(12).fontColor(getTheme(this.isDark).textMuted)
        if (this.isDesktop && !group.system && this.permits('renameGroup')) {
          this.smallButton('重命名分组', false, () => { this.openEditor('renameGroup', group); })
        }
        if (this.permits('newChannel') || (!group.system && this.permits('renameGroup'))) {
          Button('更多 ···').fontSize(12).height(32).borderRadius(8).backgroundColor(getTheme(this.isDark).surfaceAlt)
            .fontColor(getTheme(this.isDark).text).enabled(!this.busy)
            .accessibilityText(`管理分组${group.name}`).bindMenu(this.groupMenu(group))
        }
      }.height(50).width('100%')
      ForEach(group.channels, (channel: OopzVoiceChannel) => {
        Row({ space: 10 }) {
          Text(channel.type === 'TEXT' ? '#' : (channel.type === 'VOICE' || channel.type === 'AUDIO' ? '语音' : channel.type))
            .fontSize(12).fontColor(getTheme(this.isDark).textMuted)
          Text(channel.name).fontSize(14).fontColor(getTheme(this.isDark).text).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.permits('editChannel') && (channel.type === 'TEXT' || channel.type === 'VOICE' || channel.type === 'AUDIO')) {
            Button('操作').fontSize(12).height(32).backgroundColor(Color.Transparent).fontColor(getTheme(this.isDark).accent)
              .enabled(!this.busy).accessibilityText(`${channel.name}频道操作`).bindMenu(this.channelMenu(group, channel))
          }
        }.width('100%').height(44).border({ width: { top: 1 }, color: getTheme(this.isDark).borderSubtle })
      }, (channel: OopzVoiceChannel) => channel.channelId)
    }.width('100%').padding({ left: 14, right: 14, bottom: 3 }).borderRadius(AppSpacing.radius)
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
  }

  @Builder
  private structureList() {
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Blank()
          this.smallButton('刷新', false, () => { this.notice = ''; this.reload(); })
          if (this.permits('newGroup')) {
            this.smallButton('新建分组', true, () => { this.openEditor('newGroup'); })
          }
        }.width('100%')
        if (!this.groups.length) {
          Text('还没有频道分组').fontSize(14).fontColor(getTheme(this.isDark).textMuted)
          if (this.permits('newChannel')) {
            this.smallButton('新建频道', false, () => { this.openEditor('newChannel'); })
          }
        }
        ForEach(this.groups, (group: OopzChannelGroup) => { this.groupCard(group); },
          (group: OopzChannelGroup) => group.groupId + '/' + this.snapshot.toString())
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart)
  }

  @Builder
  private editorForm() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.editor === 'newChannel' && this.targetName) {
          Text('所属分组 · ' + this.targetName).fontSize(13).fontColor(getTheme(this.isDark).textMuted)
        }
        if (this.editor === 'newChannel') {
          Row({ space: 8 }) {
            this.smallButton('语音频道', this.channelType === 'VOICE', () => { this.channelType = 'VOICE'; })
            this.smallButton('文字频道', this.channelType === 'TEXT', () => { this.channelType = 'TEXT'; })
          }
        }
        Text(this.editor === 'newGroup' || this.editor === 'renameGroup' ? '分组名称' : '频道名称')
          .fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
        TextInput({ text: this.draftName, placeholder: '输入名称' }).enabled(!this.busy)
          .fontColor(getTheme(this.isDark).text).backgroundColor(getTheme(this.isDark).surfaceAlt)
          .onChange((value: string) => { this.draftName = value; })
        if (this.editor === 'editChannel') {
          Text(this.channelType === 'VOICE' ? '人数上限' : '发言间隔（秒）').fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
          TextInput({ text: this.numberText }).type(InputType.Number).enabled(!this.busy)
            .fontColor(getTheme(this.isDark).text).backgroundColor(getTheme(this.isDark).surfaceAlt)
            .onChange((value: string) => { this.numberText = value; })
        }
        Row({ space: 8 }) {
          this.smallButton('取消', false, () => { this.goBack(); })
          this.smallButton('保存', true, () => { if (this.editor !== '') this.submit(this.editor, this.groupId, this.channelId); })
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(AppSpacing.card)
        .borderRadius(AppSpacing.radius).backgroundColor(getTheme(this.isDark).surfaceSolid)
    }.width('100%').layoutWeight(1).align(Alignment.TopStart)
  }

  build() {
    Column({ space: 14 }) {
      this.titleBar()
      if (this.error) {
        Text(this.error).fontSize(14).fontColor(getTheme(this.isDark).warn)
      } else if (this.notice) {
        Text(this.notice).fontSize(13).fontColor(getTheme(this.isDark).accent)
      }
      if (this.loading) {
        Text('正在读取域管理信息…').fontSize(14).fontColor(getTheme(this.isDark).textMuted)
      } else if (this.detail !== undefined && canOpenAreaAdmin(this.detail)) {
        if (this.editor !== '') {
          this.editorForm()
        } else {
          if (!this.isDesktop && !this.memberDetailOpen) {
            Text(this.areaName || this.detail.name || this.areaId).fontSize(13).fontColor(getTheme(this.isDark).textMuted)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (!this.memberDetailOpen && this.canStructure() && canManageAreaMembers(this.detail)) {
            Row({ space: 8 }) {
              this.smallButton('频道与分组', !this.members, () => { this.members = false; this.error = ''; this.notice = ''; })
              this.smallButton('成员管理', this.members, () => { this.members = true; this.error = ''; this.notice = ''; })
            }
          }
          if (this.members) {
            AreaMemberAdmin({ areaId: this.areaId, areaDetail: this.detail, isDark: this.isDark,
              onDetailNavigation: (opened: boolean, back: () => void) => {
                this.memberDetailOpen = opened;
                this.backToMembers = opened ? back : undefined;
              } }).layoutWeight(1)
          } else {
            this.structureList()
          }
        }
      } else {
        if (!this.error) {
          Text('当前账号没有可用的域管理权限').fontSize(14).fontColor(getTheme(this.isDark).textMuted)
        }
        this.smallButton('重新读取权限', false, () => { this.reload(); })
      }
    }.width('100%').height('100%')
      .padding({ top: AppSpacing.card, bottom: AppSpacing.card, left: AppSpacing.card, right: AppSpacing.card })
      .alignItems(HorizontalAlign.Start).backgroundColor(getTheme(this.isDark).bg)
  }
}
