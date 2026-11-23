import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { AVInputCastPicker, AVCastPickerState } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PRODUCT_NAME } from 'BuildProfile';
import type { AudioVolumeInfo, NativeRtcCall, RtcCallEvents, RtcRoom } from '../voice/NativeRtcCall';
import { newChatClientMessageId, toChatReference } from '../oopz/OopzSession';
import type {
  OopzArea, OopzChannelMember, OopzChatAttachment, OopzChatImage, OopzChatMessage, OopzChatReference, OopzPersonInfo,
  OopzUploadedChatImage, OopzVoiceChannel
} from '../oopz/OopzSession';
import { rsaEncryptPassword, rsaSignBase64 } from '../oopz/OopzCrypto';
import { ensureOopzEmojiFont, OOPZ_EMOJI_FONT_FAMILY } from '../oopz/OopzEmojiFont';
import { extractAppId } from '../oopz/OopzToken';
import { OOPZ_TEST_TOKEN, OOPZ_TEST_APPID } from '../oopz/OopzKeyMaterial';
import { AppStore, DEFAULT_MIC_GAIN, MAX_MEMBER_GAIN, MAX_MIC_GAIN } from '../store/AppStore';
import { AccountPanel } from '../components/AccountPanel';
import { AreaAdminPanel, canOpenAreaAdmin } from '../components/AreaAdminPanel';
import { BottomBar, BOTTOM_BAR_INSET } from '../components/BottomBar';
import { ChatEmojiPicker } from '../components/ChatEmojiPicker';
import {
  chatMessageExcerpt, ChatMessageActions, ChatMessageItem, ChatMessageRow, ChatReferenceStrip, ChatReferenceView,
  ChatTextRun
} from '../components/ChatMessageRow';
import { ChatImageDraft, discardChatImage, pickChatImage } from '../components/ChatImagePicker';
import { ChatImagePreview } from '../components/ChatImagePreview';
import { VoiceGainSlider } from '../components/VoiceGainSlider';
import { VoiceOutputPicker } from '../components/VoiceDevices';
import { AppSpacing, getTheme, nativePopupMaterial } from '../common/Theme';
import type { VoiceMode } from '../common/VoiceMode';
import { PcTrayManager, TrayCallAction } from '../desktop/PcTrayManager';
import { VoiceBackgroundTest, VoiceTaskState } from '../voice/VoiceBackgroundTest';
import { VoiceAudioRoute, voiceDeviceName, VoiceRouteStatus, volumeLabel } from '../voice/VoiceAudioRoute';

const TAG = 'OopzNativeVoice';
const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const IS_MATE90_EMULATOR = String(PRODUCT_NAME) === 'mate90Emulator';
const KEEP_ALIVE_MS = 20000;
const WIDE_BREAKPOINT_VP = 680;
const PC_DOMAIN_BREAKPOINT_VP = 840;
const PC_CHANNEL_BREAKPOINT_VP = 600;
const PC_DOMAIN_RAIL_WIDTH = 64;
const PC_CHANNEL_PANE_WIDTH = 224;
const PC_CALL_BAR_COMPACT_VP = 506;
const PC_CAPTION_HEIGHT = 40;
const MOBILE_DOMAIN_RAIL_WIDTH = 56;
const MOBILE_CHANNEL_PADDING = 8;
const MOBILE_DOMAIN_TITLE_INDENT = 10;
const SPEAK_HOLD_MS = 440;
const REMOTE_SPEECH_MIN_VOLUME = 24;
const REMOTE_SPEECH_SAMPLE_WINDOW_MS = 360;
const INITIAL_PEER_SYNC_MS = 1600;

type MobilePane = 'channels' | 'room' | 'account';

interface ChatAnchor {
  key: string;
  y: number;
}

interface ChatSendAttempt {
  text: string;
  referenceId: string;
  imagePath: string;
  clientMessageId: string;
}

interface ChannelMemberPreview {
  uid: string;
  name: string;
  avatar: string;
}

enum CallState {
  IDLE,
  JOINING,
  CONNECTED,
  RECONNECTING,
  LEAVING
}

interface ChannelCard {
  channelId: string;
  name: string;
  group: string;
  type: string;
  isText: boolean;
  maxMember: number;
  voiceQuality: string;
  onlineCount: number;
  members: ChannelMemberPreview[];
  isSelected: boolean;
  inCall: boolean;
  isDark: boolean;
}

interface ChannelListItem {
  key: string;
  label: string;
  channel?: ChannelCard;
}

function isDomainHome(channel: ChannelCard): boolean {
  if (!channel.isText || channel.name !== '主页') {
    return false;
  }
  const group = channel.group.trim();
  return group === '' || group === '无分类' || group === '未分类';
}

function splitOopzEmojiRuns(text: string): ChatTextRun[] {
  const runs: ChatTextRun[] = [];
  let plain = '';
  for (const character of text) {
    const codepoint = character.codePointAt(0) ?? 0;
    if (codepoint < 0x103200 || codepoint > 0x10320f) {
      plain += character;
      continue;
    }
    if (plain.length > 0) runs.push({ text: plain, oopzEmoji: false });
    plain = '';
    runs.push({ text: character, oopzEmoji: true });
  }
  if (runs.length > 0 && plain.length > 0) runs.push({ text: plain, oopzEmoji: false });
  return runs;
}

function formatChatTime(tsMs: number): string {
  if (tsMs <= 0) {
    return '';
  }
  const d = new Date(tsMs);
  const pad = (n: number): string => n < 10 ? `0${n}` : String(n);
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function cleanChatContent(content: string, hasAttachments: boolean): string {
  const trimmed = content.trim();
  if (hasAttachments && /^!\[IMAGEw\d*h\d*\]\([^)]+\)$/i.test(trimmed)) {
    return '';
  }
  if (hasAttachments) {
    return trimmed.replace(/!\[IMAGEw\d*h\d*\]\([^)]+\)/gi, '').trim();
  }
  return trimmed;
}

@Observed
class RoomMemberModel {
  uid: string;
  pid: number;
  name: string;
  avatar: string;
  isSelf: boolean;
  speaking: boolean;
  muted: boolean;
  screenSharing: boolean;
  volume: number;
  localMuted: boolean;
  expanded: boolean;

  constructor(uid: string, pid: number, name: string, avatar: string, isSelf: boolean, speaking: boolean,
    muted: boolean, screenSharing: boolean, volume: number, localMuted: boolean, expanded: boolean) {
    this.uid = uid;
    this.pid = pid;
    this.name = name;
    this.avatar = avatar;
    this.isSelf = isSelf;
    this.speaking = speaking;
    this.muted = muted;
    this.screenSharing = screenSharing;
    this.volume = volume;
    this.localMuted = localMuted;
    this.expanded = expanded;
  }
}

@Component
struct MemberRow {
  @ObjectLink item: RoomMemberModel;
  @Prop inCurrentCall: boolean = false;
  @Prop isDark: boolean = true;
  @Prop compact: boolean = false;
  onToggleExpand: (uid: string) => void = () => {};
  onSelectVolume: (pid: number, vol: number) => void = () => {};
  onToggleLocalMute: (pid: number) => void = () => {};

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Stack() {
          Column() {
            Text(this.item.name.length > 0 ? this.item.name.slice(0, 1).toUpperCase() : 'U')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(getTheme(this.isDark).accent)
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(getTheme(this.isDark).surfaceAlt)
          .justifyContent(FlexAlign.Center)

          if (this.item.avatar.length > 0) {
            Image(this.item.avatar)
              .width(38)
              .height(38)
              .borderRadius(19)
              .objectFit(ImageFit.Cover)
          }
        }
        .width(38)
        .height(38)
        .border({
          width: this.item.speaking ? 2 : 0,
          color: getTheme(this.isDark).speaking
        })
        .shadow(this.item.speaking
          ? { radius: 12, color: getTheme(this.isDark).speakingSoft }
          : { radius: 0, color: Color.Transparent })
        .borderRadius(19)

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(this.item.isSelf ? `${this.item.name}（我）` : this.item.name)
              .fontSize(14)
              .fontWeight(this.item.speaking ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(getTheme(this.isDark).text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.item.localMuted && !this.item.isSelf) {
              Text('已屏蔽')
                .fontSize(10)
                .fontColor(getTheme(this.isDark).warn)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
                .backgroundColor(getTheme(this.isDark).warnSoft)
            } else if (this.item.volume !== 100 && !this.item.isSelf) {
              Text(`${this.item.volume}%`)
                .fontSize(10)
                .fontColor(getTheme(this.isDark).accent)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
                .backgroundColor(getTheme(this.isDark).accentSoft)
            }
          }

          if (!this.compact && this.item.pid > 0 && !this.item.isSelf && this.inCurrentCall) {
            Text('点击调节音量或单独屏蔽')
              .fontSize(11)
              .fontColor(getTheme(this.isDark).textMuted)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 5 }) {
          if (this.item.muted) {
            SymbolGlyph($r('sys.symbol.mic_slash'))
              .fontSize(16)
              .fontColor([getTheme(this.isDark).textMuted])
              .accessibilityText('已闭麦')
          } else if (this.item.speaking) {
            Row()
              .width(7)
              .height(7)
              .borderRadius(4)
              .backgroundColor(getTheme(this.isDark).speaking)
            Text('正在说话').fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(getTheme(this.isDark).speaking)
          } else if (this.item.screenSharing) {
            Text('共享屏幕中').fontSize(12).fontColor(getTheme(this.isDark).textMuted)
          }
        }
      }
      .width('100%')
      .onClick(() => {
        if (!this.item.isSelf && this.item.pid > 0 && this.inCurrentCall) {
          this.onToggleExpand(this.item.uid);
        }
      })

      if (this.item.expanded && !this.item.isSelf && this.item.pid > 0 && this.inCurrentCall) {
        Column({ space: 4 }) {
          VoiceGainSlider({
            label: '成员播放音量',
            value: this.item.volume,
            max: MAX_MEMBER_GAIN,
            isDark: this.isDark,
            onGainChange: (vol: number, _commit: boolean) => { this.onSelectVolume(this.item.pid, vol); }
          })
          Button(this.item.localMuted ? '取消屏蔽' : '屏蔽TA')
            .height(30)
            .fontSize(12)
            .borderRadius(8)
            .backgroundColor(this.item.localMuted ? getTheme(this.isDark).accent : getTheme(this.isDark).warnSoft)
            .fontColor(this.item.localMuted ? getTheme(this.isDark).accentText : getTheme(this.isDark).warn)
            .onClick(() => { this.onToggleLocalMute(this.item.pid); })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 48, top: 2 })
      }
    }
    .width('100%')
    .padding({ top: 9, bottom: 9, left: this.compact ? 10 : 4, right: this.compact ? 10 : 4 })
    .backgroundColor(this.compact ? getTheme(this.isDark).surface : Color.Transparent)
    .borderRadius(this.compact ? 9 : 0)
    .border({ width: this.compact ? 0 : { bottom: 1 }, color: getTheme(this.isDark).borderSubtle })
  }
}

@Entry
@Component
struct NativeVoice {
  @State private pageWidth: number = 390;
  @State private mobilePane: MobilePane = 'channels';
  @State private desktopPane: 'room' | 'account' | 'settings' = 'room';
  @State private captionMerged: boolean = false;
  @State private captionInset: number = 0;
  @State private sdkVersion: string = '';

  // Oopz data states
  @State private signedIn: boolean = false;
  @State private areas: OopzArea[] = [];
  @State private selectedAreaId: string = '';
  @State private areaAdminOpen: boolean = false;
  @State private canManageArea: boolean = false;
  @State private adminRevision: number = 0;
  @State private selectedChannelId: string = '';
  @State private selectedAreaObj?: OopzArea = undefined;
  @State private selectedChannelObj?: OopzVoiceChannel = undefined;
  @State private channelCards: ChannelCard[] = [];
  @State private expandedChannels: string[] = [];
  @State private emojiPickerOpen: boolean = false;
  @State private mediaInputMenuOpen: boolean = false;
  @State private roomMembers: RoomMemberModel[] = [];
  @State private chatMessages: ChatMessageItem[] = [];
  @State private chatInput: string = '';
  @State private chatReply?: OopzChatReference = undefined;
  @State private chatImage?: ChatImageDraft = undefined;
  private chatImagePayload?: OopzChatImage;
  @State private pickingChatImage: boolean = false;
  @State private actionItem?: ChatMessageItem = undefined;
  private chatComposerVersion: number = 0;
  private uploadedChatImage?: OopzUploadedChatImage;
  private chatSendAttempt?: ChatSendAttempt;
  @State private previewImage?: OopzChatAttachment = undefined;
  @State private recallConfirming: boolean = false;
  @State private recallBusy: boolean = false;
  private menuX: number = 0;
  private menuY: number = 0;
  private actionMessageId: string = '';
  private actionSourceKey: string = '';
  private actionSelfUid: string = '';
  private actionChannel: string = '';
  private actionArea: string = '';
  private chatInteraction: number = 0;
  @State private chatAtEnd: boolean = true;
  private chatLoadVersion: number = 0;
  private chatFirstVisible: number = 0;
  private chatLastVisible: number = 0;
  private anchors: ChatAnchor[] = [];
  @State private oopzEmojiFontReady: boolean = false;
  @State private oopzEmojiFontLoading: boolean = false;
  @State private loadingChat: boolean = false;
  @State private sendingChat: boolean = false;
  @State private readingRooms: boolean = false;

  // Call & diagnostics states
  @State private callAreaId: string = '';
  @State private callChannelId: string = '';
  @State private callTitle: string = '';
  @State private state: CallState = CallState.IDLE;
  @State private notice: string = '';
  @State private peers: number = 0;
  @State private capturing: boolean = false;
  @State private muted: boolean = false;
  @State private speakerMuted: boolean = false;
  @State private rates: string = '';
  @State private routes: VoiceRouteStatus = new VoiceRouteStatus();
  @State private showMicGain: boolean = false;

  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzIsPc') private isPc: boolean = false;
  @StorageProp('oopzImmersiveLight') private immersiveLight: boolean = true;
  @StorageProp('oopzMicGain') @Watch('applyMicGain') private micGain: number = DEFAULT_MIC_GAIN;
  @StorageProp('oopzAppForeground') @Watch('updateForeground') private foreground: boolean = false;
  @StorageProp('oopzSelfName') private selfName: string = '';
  @StorageProp('oopzSelfAvatar') private selfAvatar: string = '';
  @StorageProp('oopzCallChannelName') private activeCallName: string = '';
  @StorageProp('oopzMicCue') private micCue: boolean = false;

  private readonly store: AppStore = AppStore.get();
  private readonly chatScroller: Scroller = new Scroller();
  private readonly channelScroller: Scroller = new Scroller();
  private readonly channelOffsets: Map<string, number> = new Map<string, number>();
  private paneBeforeAccount: MobilePane = 'channels';
  private rtc?: NativeRtcCall;
  private callVoiceMode: VoiceMode = 'standard';
  private fallbackCleanup?: Promise<void>;
  private captionWindow?: window.Window;
  private originalCaptionHeight: number = PC_CAPTION_HEIGHT;
  private captionObserverAttached: boolean = false;
  private readonly voiceTask: VoiceBackgroundTest = new VoiceBackgroundTest();
  private readonly voiceRoute: VoiceAudioRoute = new VoiceAudioRoute();
  private observingCancellation: boolean = false;
  private activePage: boolean = false;
  private adminPermissionRead: number = 0;
  private adminBack?: () => void;
  private startingTask?: Promise<void>;
  private taskAttempted: boolean = false;
  private joinTimer: number = -1;
  private keepAliveTimer: number = -1;
  private speakDecayTimer: number = -1;
  private hiddenAt: number = 0;
  private lastStatsAt: number = 0;
  private peerCuesAfter: number = Number.POSITIVE_INFINITY;
  private lastPresenceChannelId: string = '';
  private lastPresenceFetchAt: number = 0;
  private joinGeneration: number = 0;

  private readonly rtcPeerPids: Set<number> = new Set<number>();
  private readonly remoteMutedPids: Set<number> = new Set<number>();
  private readonly speakingHoldUntil: Map<number, number> = new Map<number, number>();
  private readonly lastRemoteSpeechSample: Map<number, number> = new Map<number, number>();
  private readonly userVolumeMap: Map<number, number> = new Map<number, number>();
  private readonly userLocalMuteMap: Map<number, boolean> = new Map<number, boolean>();
  private readonly expandedUids: Set<string> = new Set<string>();

  private readonly onCaptionRectChange = (rect: window.TitleButtonRect): void => {
    this.captionInset = Math.max(0, rect.right + rect.width);
  };

  private readonly onTaskCancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (!this.voiceTask.matchesTask(info.id)) {
      return;
    }
    this.voiceTask.taskEnded();
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
      this.leave('已从系统通知结束语音');
      return;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (info.detailedReason === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_VOIP_NOT_RUNNING) {
        this.reportTask('系统未检测到通话音频流，已结束后台任务');
        return;
      }
    }
    this.reportTask(`系统已结束后台任务（${info.reason}）`);
  };

  aboutToAppear(): void {
    this.activePage = true;
    const context = this.getAbilityContext();
    if (context !== undefined) {
      this.store.bind(context);
      this.store.loadUiPrefs(context);
    }
    this.store.setPresenceListener((areaId: string, _channelId: string) => {
      if (areaId === this.selectedAreaId) {
        this.syncViewModels();
      }
    });
    this.store.setChatListener((channelId: string, change: string, messageId?: string) => {
      if (channelId === this.selectedChannelId) {
        if (change === 'recall' && this.chatReply && this.chatReply.messageId === messageId) {
          this.chatReply = {
            messageId: this.chatReply.messageId, senderUid: this.chatReply.senderUid,
            content: '', attachments: [], recalled: true
          };
        }
        if (this.hasChatAction()) {
          if (change === 'recall' && messageId === this.actionMessageId) this.closeChatAction();
          return;
        }
        this.syncChatMessages(change === 'append' && this.chatAtEnd);
      }
    });
    this.store.setAreaAdminListener((areaId: string, reason: string) => {
      if (!this.activePage || areaId !== this.selectedAreaId) return;
      if (reason === 'area' || reason === 'role') {
        this.adminPermissionRead++;
        this.canManageArea = canOpenAreaAdmin(this.store.getAreaDetail(areaId));
        if (!this.canManageArea) this.areaAdminOpen = false;
      } else if (reason.startsWith('group_') || reason.startsWith('channel_')) {
        this.syncAdminChannels(areaId);
      }
      if (this.areaAdminOpen) this.adminRevision++;
    });
    PcTrayManager.get().setCallActionHandler((action: TrayCallAction) => {
      this.handleTrayAction(action);
    });
    if (!IS_MATE90_EMULATOR) {
      this.loadRtc();
    }
    if (deviceInfo.apiAvailable(15)) {
      try {
        backgroundTaskManager.on('continuousTaskCancel', this.onTaskCancelled);
        this.observingCancellation = true;
      } catch {
        hilog.warn(0x0, TAG, 'Unable to observe task cancellation');
      }
    }
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.closeChatAction(false);
    this.resetChatAttachments();
    this.restoreDesktopCaption();
    this.activePage = false;
    this.store.setGripInteractionActive('voice-input-menu', false);
    this.store.setGripInteractionActive('voice-input-picker', false);
    this.store.setGripInteractionActive('voice-output-picker', false);
    this.store.setGripInteractionActive('voice-emoji', false);
    this.store.setPresenceListener(undefined);
    this.store.setChatListener(undefined);
    this.store.setAreaAdminListener(undefined);
    PcTrayManager.get().setCallActionHandler(undefined);
    this.callKeepAlive();
    this.stopSpeakDecayTimer();
    if (deviceInfo.apiAvailable(15) && this.observingCancellation) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.onTaskCancelled);
      } catch {
        hilog.warn(0x0, TAG, 'Unable to remove task observer');
      }
      this.observingCancellation = false;
    }
    if (this.state !== CallState.IDLE) {
      this.leave();
    }
    this.store.ws.stop();
  }

  onPageHide(): void {
    this.restoreDesktopCaption();
  }

  onPageShow(): void {
    this.attachDesktopCaption();
    if (AppStorage.get<boolean>('oopzRequestReturnRoom') === true) {
      AppStorage.setOrCreate<boolean>('oopzRequestReturnRoom', false);
      this.jumpToActiveRoom();
    }
  }

  onBackPress(): boolean {
    if (this.backToParent()) return true;
    if (!this.isInCall()) return false;
    this.getAbilityContext()?.moveAbilityToBackground().catch(() => {});
    return true;
  }

  private backToParent(): boolean {
    if (this.hasChatAction()) {
      if (!this.recallBusy) this.closeChatAction();
      return true;
    }
    if (this.areaAdminOpen) {
      if (this.adminBack !== undefined) this.adminBack();
      else this.closeAreaAdmin();
      return true;
    }
    if (this.emojiPickerOpen) {
      this.emojiPickerOpen = false;
      return true;
    }
    if (this.mediaInputMenuOpen) {
      this.setMediaInputMenuOpen(false);
      return true;
    }
    if (this.showMicGain && (this.isPc || this.isViewingActiveRoom())) {
      this.showMicGain = false;
      return true;
    }
    if (this.isPc && this.desktopPane !== 'room') {
      this.desktopPane = 'room';
      return true;
    }
    if (this.mobilePane === 'account') {
      this.mobilePane = this.paneBeforeAccount;
      return true;
    }
    if (this.mobilePane !== 'channels' && (!this.isPc || !this.isWide())) {
      this.mobilePane = 'channels';
      return true;
    }
    return false;
  }

  private switchMobileTab(tab: string): void {
    if (tab === 'account' && this.mobilePane !== 'account') {
      this.paneBeforeAccount = this.mobilePane;
      this.emojiPickerOpen = false;
      this.mobilePane = 'account';
    } else if (tab === 'voice') {
      this.emojiPickerOpen = false;
      this.mobilePane = 'channels';
    }
  }

  private updateForeground(): void {
    if (!this.activePage) return;
    if (!this.foreground) {
      this.hiddenAt = Date.now();
      this.lastStatsAt = 0;
      hilog.info(0x0, TAG, 'Native app background, state=%{public}d task=%{public}d',
        this.state, this.voiceTask.isRunning() ? 1 : 0);
    } else if (this.hiddenAt > 0) {
      const seconds = Math.round((Date.now() - this.hiddenAt) / 1000);
      this.hiddenAt = 0;
      this.lastStatsAt = 0;
      hilog.info(0x0, TAG, 'Native app foreground after %{public}d seconds, state=%{public}d', seconds, this.state);
      this.resumeCallAudio();
    }
  }

  private getAbilityContext(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private attachDesktopCaption(): void {
    if (!this.isPc || this.captionWindow !== undefined) return;
    try {
      const mainWindow = this.getAbilityContext()?.windowStage.getMainWindowSync();
      if (mainWindow === undefined) return;
      this.originalCaptionHeight = mainWindow.getWindowDecorHeight();
      mainWindow.setWindowDecorVisible(false);
      this.captionWindow = mainWindow;
      mainWindow.setWindowDecorHeight(PC_CAPTION_HEIGHT);
      this.onCaptionRectChange(mainWindow.getTitleButtonRect());
      mainWindow.on('windowTitleButtonRectChange', this.onCaptionRectChange);
      this.captionObserverAttached = true;
      this.captionMerged = true;
    } catch {
      this.restoreDesktopCaption();
    }
  }

  private restoreDesktopCaption(): void {
    const mainWindow = this.captionWindow;
    if (mainWindow === undefined) return;
    this.captionWindow = undefined;
    this.captionMerged = false;
    this.captionInset = 0;
    if (this.captionObserverAttached) {
      this.captionObserverAttached = false;
      try {
        mainWindow.off('windowTitleButtonRectChange', this.onCaptionRectChange);
      } catch {
        // The window may have already closed.
      }
    }
    try {
      mainWindow.setWindowDecorVisible(true);
      mainWindow.setWindowDecorHeight(this.originalCaptionHeight);
    } catch {
      // A closing window no longer has a title bar to restore.
    }
  }

  private async handleTrayAction(action: TrayCallAction): Promise<void> {
    if (action === 'toggle_mute') {
      if (this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING) {
        this.toggleMicrophone();
      }
    } else if (action === 'leave_call') {
      if (this.state !== CallState.IDLE) {
        await this.leave('已从系统托盘退出语音');
      }
    } else if (action === 'quit_app') {
      if (this.state !== CallState.IDLE) {
        await this.leave('正在退出应用');
      }
      await PcTrayManager.get().quitApp();
    }
  }

  private isWide(): boolean {
    return this.pageWidth >= (this.isPc ? PC_CHANNEL_BREAKPOINT_VP : WIDE_BREAKPOINT_VP);
  }

  private mobileBottomBarInset(): number {
    return this.mobilePane === 'room' && this.selectedChannelObj?.type === 'TEXT' ? 0 : BOTTOM_BAR_INSET;
  }

  private showsDesktopDomainRail(): boolean {
    return this.pageWidth >= PC_DOMAIN_BREAKPOINT_VP;
  }

  private isDesktopCallBarCompact(): boolean {
    const railWidth = this.showsDesktopDomainRail() ? PC_DOMAIN_RAIL_WIDTH : 0;
    const channelWidth = this.isWide() ? PC_CHANNEL_PANE_WIDTH : 0;
    return this.pageWidth - railWidth - channelWidth < PC_CALL_BAR_COMPACT_VP;
  }

  private callStateText(): string {
    switch (this.state) {
      case CallState.JOINING: return '正在加入';
      case CallState.CONNECTED: return '语音已连接';
      case CallState.RECONNECTING: return '重新连接中';
      case CallState.LEAVING: return '正在退出';
      default: return '未连接语音';
    }
  }

  private desktopChannelItems(): ChannelListItem[] {
    const groups: Map<string, ChannelCard[]> = new Map<string, ChannelCard[]>();
    const items: ChannelListItem[] = [];
    for (const channel of this.channelCards) {
      if (isDomainHome(channel) && (!this.isPc || channel.group.length === 0)) {
        items.push(this.channelListItem(channel));
        continue;
      }
      const group = channel.group || '未分类';
      const existing = groups.get(group);
      if (existing !== undefined) {
        existing.push(channel);
      } else {
        groups.set(group, [channel]);
      }
    }
    groups.forEach((channels: ChannelCard[], title: string) => {
      items.push({ key: `group-${title}`, label: title });
      for (const channel of channels) {
        items.push(this.channelListItem(channel));
      }
    });
    return items;
  }

  private channelListItem(channel: ChannelCard): ChannelListItem {
    const members = channel.members.map((member: ChannelMemberPreview) => member.uid + member.name + member.avatar);
    return {
      key: `channel-${channel.channelId}-${channel.name}-${channel.onlineCount}-${channel.isSelected}-${channel.inCall}-${this.isDark}-${members.join('|')}`,
      label: channel.name,
      channel: channel
    };
  }

  private isInCall(): boolean {
    return this.state !== CallState.IDLE;
  }

  private isViewingActiveRoom(): boolean {
    if (!this.isInCall() || (this.isPc && this.desktopPane !== 'room')) {
      return false;
    }
    return this.callAreaId === this.selectedAreaId && this.callChannelId === this.selectedChannelId &&
      (this.mobilePane === 'room' || (this.isPc && this.isWide()));
  }

  private selectedArea(): OopzArea | undefined {
    return this.areas.find((a: OopzArea): boolean => a.areaId === this.selectedAreaId);
  }

  private selectedChannel(): OopzVoiceChannel | undefined {
    return this.store.channelsByArea.get(this.selectedAreaId)?.find((c: OopzVoiceChannel): boolean =>
      c.channelId === this.selectedChannelId);
  }

  private async bootstrap(): Promise<void> {
    await this.restoreSession();
    const selfTest = AppStorage.get<boolean>('oopzNativeSelfTest') === true;
    const hasAutoCred = (AppStorage.get<string>('oopzAutoJwt') ?? '').length > 0 ||
      ((AppStorage.get<string>('oopzAutoPhone') ?? '').length > 0 &&
        (AppStorage.get<string>('oopzAutoPass') ?? '').length > 0);
    if (!this.signedIn && !selfTest && !hasAutoCred) {
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' }).catch(() => {});
      return;
    }
    await this.applyLaunch();
    if (selfTest) {
      this.runSelfTest();
    }
  }

  private async loadRtc(): Promise<void> {
    try {
      const sdk = await import('../voice/NativeRtcCall');
      if (!this.activePage) return;
      this.sdkVersion = sdk.NativeRtcCall.sdkVersion();
      AppStorage.setOrCreate<string>('oopzSdkVersion', this.sdkVersion);
      this.rtc = new sdk.NativeRtcCall();
      hilog.info(0x0, TAG, 'Native RTC SDK loaded %{public}s', this.sdkVersion);
    } catch {
      if (this.activePage) this.notice = '语音引擎加载失败';
      hilog.error(0x0, TAG, 'Native RTC SDK load failed');
    }
  }

  private async restoreSession(): Promise<void> {
    const context = this.getAbilityContext();
    if (context === undefined) return;
    this.store.bind(context);
    try {
      const cred = await this.store.restore();
      if (cred === undefined) return;
      this.signedIn = true;
      hilog.info(0x0, TAG, 'Restored Oopz session');
      await this.store.loadSelfProfile();
      await this.loadAreas();
    } catch {
      hilog.warn(0x0, TAG, 'Unable to restore Oopz session');
    }
  }

  private async applyLaunch(): Promise<void> {
    if (this.signedIn) {
      await this.autoPickAndJoin();
      return;
    }
    const jwt = AppStorage.get<string>('oopzAutoJwt');
    if (jwt !== undefined && jwt.length > 0) {
      const person = AppStorage.get<string>('oopzAutoPerson') ?? '';
      const device = AppStorage.get<string>('oopzAutoDevice') ?? '';
      const deviceId = device.length > 0 ? device : util.generateRandomUUID(true);
      await this.store.seedAndSaveCred(deviceId, person, jwt);
      this.signedIn = true;
      await this.store.loadSelfProfile();
      await this.loadAreas();
      await this.autoPickAndJoin();
      return;
    }
    const phone = AppStorage.get<string>('oopzAutoPhone') ?? '';
    const pass = AppStorage.get<string>('oopzAutoPass') ?? '';
    if (phone.length > 0 && pass.length > 0) {
      const deviceId = await this.store.loadDeviceId();
      await this.store.login(phone, pass, deviceId);
      this.signedIn = true;
      await this.store.loadSelfProfile();
      await this.loadAreas();
      await this.autoPickAndJoin();
    }
  }

  private async autoPickAndJoin(): Promise<void> {
    if (!this.signedIn) return;
    const areaName = AppStorage.get<string>('oopzAutoArea');
    if (areaName === undefined || areaName.length === 0) return;
    const targetArea = this.areas.find((a: OopzArea): boolean => a.name === areaName || a.areaId === areaName);
    if (targetArea === undefined) {
      this.notice = '未找到域：' + areaName;
      return;
    }
    await this.selectArea(targetArea.areaId, false);
    const channelName = AppStorage.get<string>('oopzAutoChannel');
    if (channelName === undefined || channelName.length === 0) return;
    const targetChannel = this.store.channels.find((c: OopzVoiceChannel): boolean =>
      c.name === channelName || c.channelId === channelName);
    if (targetChannel === undefined) {
      this.notice = '未找到频道：' + channelName;
      return;
    }
    this.selectedChannelId = targetChannel.channelId;
    this.mobilePane = 'room';
    this.syncViewModels();
    if (targetChannel.type === 'TEXT') {
      await this.loadSelectedChat();
      return;
    }
    await this.join();
  }

  private async runSelfTest(): Promise<void> {
    try {
      const sig = await rsaSignBase64('selftest' + String(Date.now()));
      const enc = await rsaEncryptPassword('probe-pass');
      const parsedAppId = extractAppId(OOPZ_TEST_TOKEN);
      const tokenOk = parsedAppId === OOPZ_TEST_APPID;
      hilog.info(0x0, TAG, 'SelfTest sign=%{public}d enc=%{public}d appid=%{public}s ok=%{public}d',
        sig.length, enc.length, parsedAppId, tokenOk ? 1 : 0);
      this.notice = `自检 签名=${sig.length} 加密=${enc.length} AppID=${tokenOk ? 'OK' : 'FAIL'}`;
    } catch (error) {
      this.notice = `自检失败: ${(error as Error).message}`;
    }
  }

  private async loadAreas(): Promise<void> {
    if (this.readingRooms || !this.signedIn) return;
    this.readingRooms = true;
    try {
      const areas = await this.store.loadAreas();
      this.areas = areas;
      hilog.info(0x0, TAG, 'Oopz areas count=%{public}d', areas.length);
      if (areas.length === 0) {
        this.canManageArea = false;
        this.areaAdminOpen = false;
        this.selectedAreaId = '';
        this.selectedChannelId = '';
        this.selectedAreaObj = undefined;
        this.selectedChannelObj = undefined;
        this.channelCards = [];
        this.roomMembers = [];
        this.chatMessages = [];
        this.notice = '该账号没有已加入的域';
        return;
      }
      const nextArea = areas.some((a: OopzArea): boolean => a.areaId === this.selectedAreaId)
        ? this.selectedAreaId : areas[0].areaId;
      await this.selectArea(nextArea, false);
    } catch (error) {
      this.notice = (error as Error).message;
    } finally {
      this.readingRooms = false;
    }
  }

  private pickDefaultChannel(channels: OopzVoiceChannel[]): string {
    const voice = channels.find((c: OopzVoiceChannel): boolean => c.type !== 'TEXT');
    if (voice !== undefined) {
      return voice.channelId;
    }
    return channels.length > 0 ? channels[0].channelId : '';
  }

  private async selectArea(areaId: string, advanceMobile: boolean = true): Promise<void> {
    if (areaId.length === 0) return;
    this.rememberChannelPosition();
    this.emojiPickerOpen = false;
    if (this.selectedAreaId !== areaId) this.canManageArea = false;
    this.closeChatAction(false);
    this.areaAdminOpen = false;
    if (advanceMobile) this.mobilePane = 'channels';
    this.selectedAreaId = areaId;
    this.refreshAdminPermission(areaId);
    this.readingRooms = true;
    this.syncViewModels();
    try {
      const channels = await this.store.loadChannels(areaId);
      if (this.selectedAreaId !== areaId) return;
      hilog.info(0x0, TAG, 'Oopz channels count=%{public}d', channels.length);
      if (!channels.some((c: OopzVoiceChannel): boolean => c.channelId === this.selectedChannelId)) {
        this.selectedChannelId = this.pickDefaultChannel(channels);
      }
      this.lastPresenceChannelId = this.selectedChannelId;
      this.lastPresenceFetchAt = Date.now();
      this.notice = channels.length > 0 ? '' : '该域暂无可用频道';
      this.syncViewModels();
      this.restoreChannelPosition();
      if (this.selectedChannelObj?.type === 'TEXT' && this.isPc && this.isWide()) {
        await this.loadSelectedChat();
      }
    } catch (error) {
      if (this.selectedAreaId === areaId) this.notice = (error as Error).message;
    } finally {
      if (this.selectedAreaId === areaId) this.readingRooms = false;
    }
  }

  private selectChannel(channelId: string): void {
    this.closeChatAction(false);
    this.areaAdminOpen = false;
    this.rememberChannelPosition();
    this.emojiPickerOpen = false;
    this.selectedChannelId = channelId;
    this.mobilePane = 'room';
    this.syncViewModels();
    if (this.selectedChannelObj === undefined) {
      return;
    }
    if (this.selectedChannelObj.type === 'TEXT') {
      this.syncChatMessages(true);
      this.loadSelectedChat();
      return;
    }
    const now = Date.now();
    if (this.selectedAreaId.length > 0 &&
      (this.lastPresenceChannelId !== channelId || now - this.lastPresenceFetchAt >= 5000)) {
      this.lastPresenceChannelId = channelId;
      this.lastPresenceFetchAt = now;
      this.store.loadAreaPresence(this.selectedAreaId, [this.selectedChannelObj]).then(() => {
        this.syncViewModels();
      }).catch(() => {});
    }
  }

  private async loadSelectedChat(before?: string): Promise<void> {
    const interaction = this.chatInteraction;
    const areaId = this.selectedAreaId;
    const ch = this.selectedChannelObj;
    if (areaId.length === 0 || ch === undefined || ch.type !== 'TEXT' || this.loadingChat) {
      return;
    }
    const request = ++this.chatLoadVersion;
    this.loadingChat = true;
    try {
      await this.store.loadChannelMessages(areaId, ch.channelId, before);
      if (request === this.chatLoadVersion && this.selectedChannelId === ch.channelId) {
        this.syncChatMessages(before === undefined && interaction === this.chatInteraction);
      }
    } catch (error) {
      if (request === this.chatLoadVersion) this.notice = (error as Error).message;
    } finally {
      if (request === this.chatLoadVersion) this.loadingChat = false;
    }
  }

  private async loadOlderMessages(): Promise<void> {
    if (this.chatMessages.length === 0) {
      await this.loadSelectedChat();
      return;
    }
    const oldest = this.chatMessages[0].messageId;
    if (oldest.length > 0) {
      await this.loadSelectedChat(oldest);
    }
  }

  private clearChatImage(): void {
    const previous = this.chatImage;
    this.chatImage = undefined;
    this.chatImagePayload = undefined;
    this.uploadedChatImage = undefined;
    discardChatImage(previous);
  }

  private resetChatAttachments(): void {
    this.chatComposerVersion++;
    this.chatReply = undefined;
    this.chatSendAttempt = undefined;
    this.clearChatImage();
  }

  private async chooseChatImage(): Promise<void> {
    const context = this.getAbilityContext();
    const cred = this.store.session.getCred();
    if (context === undefined || !cred || this.pickingChatImage || this.sendingChat ||
      this.selectedChannelObj?.type !== 'TEXT' || this.hasChatAction()) return;
    const version = this.chatComposerVersion;
    this.pickingChatImage = true;
    try {
      const selected = await pickChatImage(context, this.isPc);
      if (!selected) return;
      if (!this.activePage || version !== this.chatComposerVersion || this.store.session.getCred() !== cred) {
        discardChatImage(selected.preview);
        return;
      }
      this.clearChatImage();
      this.chatImagePayload = selected.image;
      this.chatImage = selected.preview;
      this.notice = '';
    } catch (error) {
      if (version === this.chatComposerVersion && this.activePage && this.store.session.getCred() === cred) {
        const reason = (error as Error).message;
        this.notice = reason ? '无法选用图片：' + reason : '无法选用图片，请重试';
      }
    } finally {
      this.pickingChatImage = false;
    }
  }

  private async sendChatMessage(): Promise<void> {
    const ch = this.selectedChannelObj;
    const areaId = this.selectedAreaId;
    const cred = this.store.session.getCred();
    const draft = this.chatInput;
    const text = draft.trim();
    const image = this.chatImage;
    const payload = this.chatImagePayload;
    const reference = this.chatReply;
    if (this.sendingChat || this.pickingChatImage || this.hasChatAction() || (!text && !payload) ||
      !cred || !areaId || ch?.type !== 'TEXT') {
      return;
    }
    if (reference && this.store.isChatMessageRecalled(ch.channelId, reference.messageId)) {
      this.notice = '引用的消息已撤回，请取消引用后再发送';
      return;
    }
    const version = this.chatComposerVersion;
    const referenceId = reference?.messageId ?? '';
    const imagePath = image?.path ?? '';
    const previousAttempt = this.chatSendAttempt;
    const sameAttempt = previousAttempt?.text === text && previousAttempt.referenceId === referenceId &&
      previousAttempt.imagePath === imagePath;
    const clientMessageId = sameAttempt ? previousAttempt.clientMessageId : newChatClientMessageId();
    this.chatSendAttempt = { text: text, referenceId: referenceId, imagePath: imagePath, clientMessageId: clientMessageId };
    this.sendingChat = true;
    const interaction = this.chatInteraction;
    this.notice = '';
    try {
      let attachment = this.uploadedChatImage;
      if (image && payload && !attachment) {
        attachment = await this.store.session.uploadChatImage(payload);
        if (version === this.chatComposerVersion && image.path === this.chatImage?.path) {
          this.uploadedChatImage = attachment;
        }
      }
      if (this.store.session.getCred() !== cred) return;
      await this.store.sendChannelMessage(areaId, ch.channelId, text, {
        clientMessageId: clientMessageId,
        reference: reference,
        image: attachment
      });
      if (version !== this.chatComposerVersion || this.store.session.getCred() !== cred || !this.activePage) return;
      if (this.chatInput === draft) this.chatInput = '';
      if (this.chatReply?.messageId === referenceId) this.chatReply = undefined;
      if (image && this.chatImage?.path === imagePath) this.clearChatImage();
      this.chatSendAttempt = undefined;
      this.syncChatMessages(interaction === this.chatInteraction);
    } catch (error) {
      if (version === this.chatComposerVersion && this.store.session.getCred() === cred && this.activePage) {
        this.notice = (error as Error).message || '消息发送失败，请重试';
      }
    } finally {
      this.sendingChat = false;
    }
  }

  private chatReferenceView(referenceId: string, source?: OopzChatReference): ChatReferenceView {
    if (source?.recalled || this.store.isChatMessageRecalled(this.selectedChannelId, referenceId)) {
      return { author: '', excerpt: '引用的消息已撤回' };
    }
    if (source === undefined) return { author: '', excerpt: '引用消息暂不可见' };
    const person = this.store.getPersonByUid(source.senderUid) ??
      (this.store.session.getCred()?.personUid === source.senderUid ? this.store.selfProfile : undefined);
    const text = cleanChatContent(source.content, source.attachments.length > 0);
    return {
      author: person?.name || source.senderUid.slice(0, 6) || '成员',
      excerpt: chatMessageExcerpt(text, source.attachments).replace(/[\u{103200}-\u{10320f}]/gu, '[表情]')
    };
  }

  private syncChatMessages(scrollToBottom: boolean = false): void {
    if (this.hasChatAction()) return;
    const chId = this.selectedChannelId;
    if (chId.length === 0) {
      this.chatMessages = [];
      return;
    }
    const selfUid = this.store.session.getCred()?.personUid ?? '';
    const rawList: OopzChatMessage[] = this.store.messagesByChannel.get(chId) ?? [];
    const messagesById = new Map<string, OopzChatMessage>();
    for (const message of rawList) {
      if (message.messageId) messagesById.set(message.messageId, message);
    }
    const items: ChatMessageItem[] = [];
    for (let i = 0; i < rawList.length; i++) {
      const m = rawList[i];
      const person = this.store.getPersonByUid(m.senderUid) ??
        (m.senderUid === selfUid ? this.store.selfProfile : undefined);
      const senderName = person !== undefined ? person.name : (m.senderUid.length > 0 ? m.senderUid.slice(0, 6) : '成员');
      const senderAvatar = person !== undefined ? person.avatar : '';
      const key = m.messageId.length > 0 ? m.messageId : (m.clientMessageId.length > 0 ? m.clientMessageId : `idx_${i}`);
      const cleanText = cleanChatContent(m.content, m.attachments.length > 0);
      const referenceId = m.referenceMessageId;
      const original = referenceId ? messagesById.get(referenceId) : undefined;
      const source = original !== undefined && !m.reference?.recalled ? toChatReference(original) : m.reference;
      items.push({
        key: key,
        messageId: m.messageId,
        senderUid: m.senderUid,
        senderName: senderName,
        senderAvatar: senderAvatar,
        isSelf: m.senderUid === selfUid && selfUid.length > 0,
        timeText: formatChatTime(m.timestampMs),
        cleanText: cleanText,
        textRuns: splitOopzEmojiRuns(cleanText),
        attachments: m.attachments,
        reference: referenceId ? this.chatReferenceView(referenceId, source) : undefined
      });
    }
    this.chatMessages = items;
    if (items.some((item: ChatMessageItem) => item.textRuns.length > 0)) this.loadOopzEmojiFont();
    if (scrollToBottom && items.length > 0) {
      const interaction = this.chatInteraction;
      setTimeout(() => {
        if (interaction !== this.chatInteraction || this.selectedChannelId !== chId || !this.activePage) return;
        try {
          this.chatScroller.scrollEdge(Edge.Bottom);
        } catch {
          // ignore if not attached yet
        }
      }, 60);
    }
  }

  private updateChatEnd(): void {
    this.chatAtEnd = this.chatMessages.length === 0 || this.chatScroller.isAtEnd();
  }

  private jumpToChatEnd(): void {
    if (!this.chatMessages.length || this.hasChatAction()) return;
    this.chatInteraction++;
    this.chatScroller.scrollEdge(Edge.Bottom);
    this.updateChatEnd();
  }

  private hasChatAction(): boolean {
    return this.actionItem !== undefined || this.previewImage !== undefined;
  }

  private beginChatAction(msg: ChatMessageItem): void {
    this.chatInteraction++;
    this.actionArea = this.selectedAreaId;
    this.actionChannel = this.selectedChannelId;
    this.actionMessageId = msg.messageId;
    this.actionSourceKey = msg.key;
    this.actionSelfUid = this.store.session.getCred()?.personUid ?? '';
    this.anchors = [];
    for (let i = this.chatFirstVisible; i >= 0 && i <= this.chatLastVisible && i < this.chatMessages.length; i++) {
      const rect = this.chatScroller.getItemRect(i);
      if (rect.height > 0) this.anchors.push({ key: this.chatMessages[i].key, y: rect.y });
    }
  }

  private openMessageMenu(msg: ChatMessageItem, x: number, y: number): void {
    if (this.hasChatAction() || !msg.messageId) return;
    this.beginChatAction(msg);
    this.menuX = x;
    this.menuY = y;
    this.actionItem = msg;
  }

  private chooseChatReply(): void {
    const item = this.actionItem;
    if (!item) return;
    const original = this.store.messagesByChannel.get(this.selectedChannelId)?.find((msg: OopzChatMessage): boolean =>
      msg.messageId === item.messageId);
    if (original && this.actionSelfUid === this.store.session.getCred()?.personUid) {
      this.chatReply = toChatReference(original);
      this.closeChatAction(true, true);
    } else {
      this.closeChatAction();
    }
  }

  private async copyChatMessage(): Promise<void> {
    const text = this.actionItem?.cleanText;
    this.closeChatAction();
    if (!text) return;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败，请重试' });
    }
  }

  private openChatImage(msg: ChatMessageItem, image: OopzChatAttachment): void {
    if (this.hasChatAction() || !image.url) return;
    this.beginChatAction(msg);
    this.previewImage = image;
  }

  private closeChatAction(restore: boolean = true, focusComposer: boolean = false): void {
    const interaction = ++this.chatInteraction;
    if (!this.hasChatAction()) return;
    const channelId = this.actionChannel;
    const sourceKey = this.actionSourceKey;
    this.actionItem = undefined;
    this.recallConfirming = false;
    this.recallBusy = false;
    this.previewImage = undefined;
    if (!restore || channelId !== this.selectedChannelId || this.actionArea !== this.selectedAreaId) return;
    const saved = this.anchors;
    this.syncChatMessages();
    // The list stays mounted. Correct only an actual displacement (for example,
    // if a visible row was recalled while a newer page of history arrived).
    setTimeout(() => {
      if (interaction !== this.chatInteraction || channelId !== this.selectedChannelId || !this.activePage) return;
      const anchor = saved.find((a: ChatAnchor): boolean => this.chatMessages.some((m: ChatMessageItem): boolean =>
        m.key === a.key));
      if (anchor !== undefined) {
        const index = this.chatMessages.findIndex((m: ChatMessageItem): boolean => m.key === anchor.key);
        const rect = this.chatScroller.getItemRect(index);
        if (rect.height > 0) {
          if (Math.abs(rect.y - anchor.y) > 0.5) this.chatScroller.scrollBy(0, rect.y - anchor.y);
        } else {
          this.chatScroller.scrollToIndex(index, false, ScrollAlign.START);
          this.chatScroller.scrollBy(0, -anchor.y);
        }
      }
      if (this.isPc) {
        if (focusComposer) {
          focusControl.requestFocus('chat-composer-input');
        } else {
          const index = this.chatMessages.findIndex((m: ChatMessageItem): boolean => m.key === sourceKey);
          const key = index >= 0 && this.chatScroller.getItemRect(index).height > 0 ? sourceKey : anchor?.key;
          if (key) focusControl.requestFocus('chat-message-' + key);
        }
      }
    }, 32);
  }

  private async submitChatRecall(): Promise<void> {
    const msg = this.actionItem;
    if (!msg?.isSelf || !this.recallConfirming || this.recallBusy) return;
    if (this.actionSelfUid !== this.store.session.getCred()?.personUid || this.actionArea !== this.selectedAreaId ||
      this.actionChannel !== this.selectedChannelId) {
      this.closeChatAction(false);
      return;
    }
    const interaction = this.chatInteraction;
    this.recallBusy = true;
    try {
      await this.store.recallChannelMessage(this.actionArea, this.actionChannel, msg.messageId);
      if (interaction === this.chatInteraction) this.closeChatAction();
    } catch (error) {
      if (interaction === this.chatInteraction) {
        this.closeChatAction();
        this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
      }
    }
  }

  private async loadOopzEmojiFont(): Promise<void> {
    const context = this.getAbilityContext();
    if (context === undefined || this.oopzEmojiFontReady || this.oopzEmojiFontLoading) return;
    this.oopzEmojiFontLoading = true;
    try {
      const ready = await ensureOopzEmojiFont(context).catch(() => false);
      if (this.activePage) this.oopzEmojiFontReady = ready;
    } finally {
      this.oopzEmojiFontLoading = false;
    }
  }

  private async jumpToActiveRoom(): Promise<void> {
    if (!this.isInCall() || this.callAreaId.length === 0 || this.callChannelId.length === 0) {
      return;
    }
    this.areaAdminOpen = false;
    if (this.selectedAreaId !== this.callAreaId) {
      await this.selectArea(this.callAreaId, false);
    }
    this.selectedChannelId = this.callChannelId;
    this.mobilePane = 'room';
    this.syncViewModels();
  }

  private async refreshAdminPermission(areaId: string): Promise<void> {
    const read = ++this.adminPermissionRead;
    let allowed = false;
    try {
      const detail = await this.store.loadAreaDetail(areaId, true);
      allowed = detail.areaId === areaId && canOpenAreaAdmin(detail);
    } catch {
      // Browsing the area remains available when its management permissions cannot be read.
    }
    if (this.activePage && this.selectedAreaId === areaId && read === this.adminPermissionRead) {
      this.canManageArea = allowed;
      if (!allowed) this.areaAdminOpen = false;
    }
  }

  private syncAdminChannels(areaId: string): void {
    if (areaId !== this.selectedAreaId) return;
    const channels = this.store.channelsByArea.get(areaId);
    if (channels === undefined) return;
    const selectionChanged = !channels.some((ch: OopzVoiceChannel): boolean => ch.channelId === this.selectedChannelId);
    if (selectionChanged) {
      this.closeChatAction(false);
      this.selectedChannelId = this.pickDefaultChannel(channels);
      this.chatInput = '';
    }
    this.syncViewModels();
    if (selectionChanged) {
      this.syncChatMessages();
      if (this.selectedChannelObj?.type === 'TEXT') this.loadSelectedChat();
    }
  }

  private syncViewModels(): void {
    const previousChannel = this.selectedChannelObj?.channelId;
    this.selectedAreaObj = this.areas.find((a: OopzArea): boolean => a.areaId === this.selectedAreaId);
    const channels = this.store.channelsByArea.get(this.selectedAreaId) ?? [];
    this.selectedChannelObj = channels.find((c: OopzVoiceChannel): boolean => c.channelId === this.selectedChannelId);
    if (previousChannel !== this.selectedChannelObj?.channelId) {
      this.resetChatAttachments();
      this.chatInteraction++;
      this.chatLoadVersion++;
      this.loadingChat = false;
      this.chatAtEnd = true;
      this.chatFirstVisible = 0;
      this.chatLastVisible = 0;
      this.chatMessages = [];
    }

    const cards: ChannelCard[] = [];
    const darkFlag = this.isDark;
    for (const ch of channels) {
      const isText = ch.type === 'TEXT';
      const inThisRoom = !isText && this.isInCall() && this.callAreaId === this.selectedAreaId &&
        this.callChannelId === ch.channelId;
      let count = 0;
      const previews: ChannelMemberPreview[] = [];
      if (!isText) {
        const members = this.store.membersByChannel.get(ch.channelId) ?? [];
        for (const m of members) {
          const p = this.store.getPersonByUid(m.uid);
          previews.push({ uid: m.uid, name: p?.name || '成员', avatar: p?.avatar ?? '' });
        }
        if (inThisRoom && this.store.selfProfile !== undefined &&
          !previews.some((member: ChannelMemberPreview) => member.uid === this.store.selfProfile?.uid)) {
          const self = this.store.selfProfile;
          previews.push({ uid: self.uid, name: self.name, avatar: self.avatar });
        }
        count = inThisRoom ? Math.max(members.length, this.peers + 1) : members.length;
      }
      const card: ChannelCard = {
        channelId: ch.channelId,
        name: ch.name,
        group: ch.group,
        type: ch.type,
        isText: isText,
        maxMember: ch.maxMember,
        voiceQuality: ch.voiceQuality,
        onlineCount: count,
        members: previews,
        isSelected: ch.channelId === this.selectedChannelId,
        inCall: inThisRoom,
        isDark: darkFlag
      };
      cards.push(card);
    }
    this.channelCards = cards;
    this.syncRoomMembers();
  }

  private syncRoomMembers(): void {
    const chId = this.selectedChannelId;
    if (chId.length === 0 || this.selectedChannelObj?.type === 'TEXT') {
      this.roomMembers = [];
      return;
    }
    const selfUid = this.store.session.getCred()?.personUid ?? '';
    const rawMembers: OopzChannelMember[] = (this.store.membersByChannel.get(chId) ?? []).slice();
    const inThisCall = this.isInCall() && this.callAreaId === this.selectedAreaId && this.callChannelId === chId;

    if (inThisCall && selfUid.length > 0 && !rawMembers.some((m: OopzChannelMember): boolean => m.uid === selfUid)) {
      rawMembers.push({
        uid: selfUid, enterTime: '', sort: 99, peopleLimit: 0, screenSharing: false, isBot: false
      });
    }

    const now = Date.now();
    const seenUids = new Set<string>();
    const nextModels: RoomMemberModel[] = [];

    for (const m of rawMembers) {
      seenUids.add(m.uid);
      const person: OopzPersonInfo | undefined = this.store.getPersonByUid(m.uid) ??
        (m.uid === selfUid ? this.store.selfProfile : undefined);
      const pid = person !== undefined ? person.pid : 0;
      const isSelf = m.uid === selfUid;
      const muted = inThisCall && (isSelf ? this.muted : (pid > 0 && this.remoteMutedPids.has(pid)));
      const speakUntil = this.speakingHoldUntil.get(isSelf ? 0 : pid) ?? 0;
      const speaking = inThisCall && (isSelf || pid > 0) && !muted && speakUntil > now;
      const vol = pid > 0 ? (this.userVolumeMap.get(pid) ?? 100) : 100;
      const localMuted = pid > 0 && (this.userLocalMuteMap.get(pid) ?? false);
      const expanded = this.expandedUids.has(m.uid);
      const name = person !== undefined ? person.name : m.uid.slice(0, 6);
      const avatar = person !== undefined ? person.avatar : '';

      nextModels.push(this.reuseOrCreateMember(
        m.uid, pid, name, avatar, isSelf, speaking, muted, m.screenSharing, vol, localMuted, expanded
      ));
    }

    if (inThisCall) {
      this.rtcPeerPids.forEach((pid: number) => {
        const person = this.store.getPersonByPid(pid);
        if (person !== undefined && seenUids.has(person.uid)) {
          return;
        }
        const synthUid = person !== undefined ? person.uid : `pid:${pid}`;
        if (seenUids.has(synthUid)) {
          return;
        }
        seenUids.add(synthUid);
        const muted = this.remoteMutedPids.has(pid);
        const speaking = !muted && (this.speakingHoldUntil.get(pid) ?? 0) > now;
        const vol = this.userVolumeMap.get(pid) ?? 100;
        const localMuted = this.userLocalMuteMap.get(pid) ?? false;
        const expanded = this.expandedUids.has(synthUid);
        const name = person !== undefined ? person.name : `成员 ${pid}`;
        const avatar = person !== undefined ? person.avatar : '';
        nextModels.push(this.reuseOrCreateMember(
          synthUid, pid, name, avatar, false, speaking, muted, false, vol, localMuted, expanded
        ));
      });
    }

    const sameOrder = nextModels.length === this.roomMembers.length &&
      nextModels.every((m: RoomMemberModel, idx: number): boolean => m === this.roomMembers[idx]);
    if (!sameOrder) {
      this.roomMembers = nextModels;
    }
  }

  private reuseOrCreateMember(uid: string, pid: number, name: string, avatar: string, isSelf: boolean,
    speaking: boolean, muted: boolean, screenSharing: boolean, volume: number, localMuted: boolean,
    expanded: boolean): RoomMemberModel {
    const existing = this.roomMembers.find((item: RoomMemberModel): boolean => item.uid === uid);
    if (existing !== undefined) {
      if (existing.pid !== pid) existing.pid = pid;
      if (existing.name !== name) existing.name = name;
      if (existing.avatar !== avatar) existing.avatar = avatar;
      if (existing.isSelf !== isSelf) existing.isSelf = isSelf;
      if (existing.speaking !== speaking) existing.speaking = speaking;
      if (existing.muted !== muted) existing.muted = muted;
      if (existing.screenSharing !== screenSharing) existing.screenSharing = screenSharing;
      if (existing.volume !== volume) existing.volume = volume;
      if (existing.localMuted !== localMuted) existing.localMuted = localMuted;
      if (existing.expanded !== expanded) existing.expanded = expanded;
      return existing;
    }
    return new RoomMemberModel(uid, pid, name, avatar, isSelf, speaking, muted, screenSharing,
      volume, localMuted, expanded);
  }

  private reportTask(status: string): void {
    AppStorage.setOrCreate<string>('oopzTaskStatus', status);
    hilog.info(0x0, TAG, '%{public}s', status);
  }

  private maybeStartTask(): void {
    const context = this.getAbilityContext();
    if (context === undefined || this.state !== CallState.CONNECTED || this.hiddenAt !== 0 ||
      this.taskAttempted || this.startingTask !== undefined || this.voiceTask.isRunning() ||
      (!this.capturing && this.routes.usage === undefined) ||
      (!this.muted && !this.capturing && this.routes.source === undefined)) {
      return;
    }
    const generation = this.joinGeneration;
    this.taskAttempted = true;
    this.reportTask('正在开启后台保活');
    this.startingTask = this.voiceTask.startCall(context, this.routes, this.capturing || this.routes.source !== undefined,
      () => generation === this.joinGeneration && this.hiddenAt === 0).then(() => {
      if (generation === this.joinGeneration && this.voiceTask.isRunning()) {
        this.reportTask('后台语音保活已开启');
      }
    }).catch((error: BusinessError) => {
      if (generation === this.joinGeneration) {
        this.reportTask(`后台保活未开启（${error.code}）`);
      }
    }).finally(() => {
      this.startingTask = undefined;
    });
  }

  private async resumeCallAudio(): Promise<void> {
    const context = this.getAbilityContext();
    if (context === undefined || this.state !== CallState.CONNECTED) return;
    const generation = this.joinGeneration;
    await this.startingTask;
    if (generation !== this.joinGeneration || this.hiddenAt !== 0) return;
    if (this.voiceTask.isRunning()) {
      try {
        const status = await this.voiceTask.inspect(context);
        if (generation !== this.joinGeneration || this.hiddenAt !== 0) return;
        if (status === VoiceTaskState.SUSPENDED) {
          this.reportTask('后台任务已被系统挂起');
        } else if (status === VoiceTaskState.ABSENT) {
          await this.voiceTask.taskEnded();
        } else {
          this.reportTask('后台语音保活已开启');
        }
      } catch {
        hilog.debug(0x0, TAG, 'Background task inspection unavailable');
      }
    }
    if (generation !== this.joinGeneration || this.hiddenAt !== 0 || this.state !== CallState.CONNECTED) return;
    await this.voiceRoute.activateMixing();
    if (generation !== this.joinGeneration || this.hiddenAt !== 0 || this.state !== CallState.CONNECTED) return;
    if (!this.muted && !this.capturing) this.rtc?.setMicrophone(true);
    this.applyMicGain();
    this.startSystemCallSession();
    this.taskAttempted = false;
    this.voiceRoute.refresh();
    this.maybeStartTask();
  }

  private syncCallStore(): void {
    const area = this.areas.find((a: OopzArea): boolean => a.areaId === this.callAreaId);
    const chList = this.store.channelsByArea.get(this.callAreaId) ?? this.store.channels;
    const ch = chList.find((c: OopzVoiceChannel): boolean => c.channelId === this.callChannelId);
    const channelLabel = ch !== undefined ? ch.name : this.callTitle;
    const areaLabel = area !== undefined ? area.name : '';
    const inCall = this.state !== CallState.IDLE;
    this.store.updateCallStorage(
      inCall,
      this.callAreaId,
      this.callChannelId,
      areaLabel,
      channelLabel,
      this.muted,
      this.peers,
      this.rates
    );
    this.syncCallAudioStatus();
    PcTrayManager.get().updateTrayState(inCall, channelLabel, this.muted);
  }

  private syncCallAudioStatus(): void {
    const mode = this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING ? this.callVoiceMode : '';
    AppStorage.setOrCreate<VoiceMode | ''>('oopzActiveVoiceMode', mode);
    let processing = '';
    if (mode !== '') {
      if (this.muted) {
        processing = '麦克风已关闭';
      } else if (this.capturing && this.routes.voipStreams) {
        processing = 'VoIP 已接入 · 系统自动';
      } else {
        processing = mode === 'native-voip' ? '等待通话采播确认' : '普通媒体采播';
      }
    }
    AppStorage.setOrCreate<string>('oopzCallProcessing', processing);
    const supportsAec = this.routes.acousticEchoCancelerSupported;
    AppStorage.setOrCreate<string>('oopzCallAecSupport',
      supportsAec === undefined ? '未查询到' : (supportsAec ? '通话音源支持' : '通话音源不支持'));
  }

  private startSystemCallSession(): void {
    const area = this.areas.find((candidate: OopzArea) => candidate.areaId === this.callAreaId);
    const channel = this.store.channelsByArea.get(this.callAreaId)?.find((candidate: OopzVoiceChannel) =>
      candidate.channelId === this.callChannelId);
    this.voiceRoute.activate(this.muted, () => {
      if (this.isInCall()) this.leave();
    }, () => {
      if (this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING) this.toggleMicrophone();
    }, {
      title: channel?.name ?? '语音频道', domain: area?.name ?? '', avatar: area?.avatar ?? ''
    });
  }

  private updateVoiceRoute(status: VoiceRouteStatus): void {
    this.routes = status;
    AppStorage.setOrCreate<string>('oopzCallInput', this.muted ? '已关闭' : status.input);
    AppStorage.setOrCreate<string>('oopzCallOutput', status.output);
    AppStorage.setOrCreate<string>('oopzCallVolumeType', volumeLabel(status.usage));
    this.syncCallAudioStatus();
    this.maybeStartTask();
  }

  private applyMicGain(): void {
    if (this.state === CallState.CONNECTED && this.rtc?.setRecordingVolume(this.micGain) !== 0) {
      this.notice = '调整麦克风发送音量失败';
    }
  }

  private async switchToSelectedRoom(): Promise<void> {
    if (this.state !== CallState.IDLE) {
      await this.leave('正在切换语音频道');
    }
    await this.join();
  }

  private async join(): Promise<void> {
    if (this.state !== CallState.IDLE || this.readingRooms) {
      return;
    }
    const context = this.getAbilityContext();
    const rtc = this.rtc;
    if (context === undefined || rtc === undefined || this.sdkVersion.length === 0) {
      this.notice = '语音引擎尚未就绪';
      return;
    }
    const area = this.selectedArea();
    const voiceChannel = this.selectedChannel();
    if (!this.signedIn || area === undefined || voiceChannel === undefined || voiceChannel.type === 'TEXT') {
      this.notice = '请先选择一个语音频道';
      return;
    }

    const generation = ++this.joinGeneration;
    this.state = CallState.JOINING;
    this.notice = '正在申请麦克风权限';
    try {
      await this.store.loadUiPrefs(context);
      if (!this.activePage || generation !== this.joinGeneration) return;
      const mode = AppStorage.get<VoiceMode>('oopzVoiceMode') ?? 'standard';
      const auth = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MIC_PERMISSION]);
      if (!this.activePage || generation !== this.joinGeneration || this.state !== CallState.JOINING) {
        return;
      }
      if (auth.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.state = CallState.IDLE;
        this.notice = '请允许麦克风权限后再加入语音频道';
        return;
      }

      this.taskAttempted = false;
      this.rtcPeerPids.clear();
      this.remoteMutedPids.clear();
      this.speakingHoldUntil.clear();
      this.lastRemoteSpeechSample.clear();
      this.peerCuesAfter = Number.POSITIVE_INFINITY;
      this.userVolumeMap.clear();
      this.userLocalMuteMap.clear();
      this.expandedUids.clear();

      this.callAreaId = area.areaId;
      this.callChannelId = voiceChannel.channelId;
      this.callTitle = `${area.name} / ${voiceChannel.name}`;
      this.notice = '正在进入语音频道';

      let room: RtcRoom;
      try {
        const oopzRoom = await this.store.session.enter(area.areaId, voiceChannel.channelId);
        room = { appId: oopzRoom.appId, channel: oopzRoom.channel, uid: oopzRoom.uid, token: oopzRoom.token };
      } catch (error) {
        if (generation === this.joinGeneration) {
          await this.leave((error as Error).message);
        }
        return;
      }
      if (!this.activePage || generation !== this.joinGeneration) return;
      this.startKeepAlive();
      this.syncCallStore();
      this.syncViewModels();
      this.notice = '正在连接语音服务';
      this.joinTimer = setTimeout(() => { this.leave('进房超时，请检查网络连接'); }, 20000);
      const started = await this.startCallAudio(context, rtc, room, mode, generation);
      if (started || mode !== 'native-voip' || !this.activePage || generation !== this.joinGeneration) return;

      const cleanup = rtc.close().finally(() => this.voiceRoute.close());
      this.fallbackCleanup = cleanup;
      try {
        await cleanup;
      } finally {
        this.fallbackCleanup = undefined;
      }
      if (!this.activePage || generation !== this.joinGeneration) return;
      this.updateVoiceRoute(new VoiceRouteStatus());
      this.getUIContext().getPromptAction().showToast({ message: '原生 VoIP 初始化失败，本次使用标准语音' });
      await this.startCallAudio(context, rtc, room, 'standard', generation);
    } catch (error) {
      if (generation !== this.joinGeneration) {
        return;
      }
      const message = (error as Error).message;
      const known = /^(启用原生音频失败|原生 SDK 拒绝进房)（-?\d+）$/.test(message);
      await this.leave(known ? message : '无法加入语音频道');
    }
  }

  private async startCallAudio(context: common.UIAbilityContext, rtc: NativeRtcCall, room: RtcRoom,
    mode: VoiceMode, generation: number): Promise<boolean> {
    this.callVoiceMode = mode;
    this.voiceRoute.begin(context, (status: VoiceRouteStatus) => { this.updateVoiceRoute(status); }, mode);
    await this.voiceRoute.activateMixing();
    if (!this.activePage || generation !== this.joinGeneration) return false;
    return rtc.start(context, room, this.callEvents(), true, this.micGain, mode);
  }

  private startKeepAlive(): void {
    this.callKeepAlive();
    const generation = this.joinGeneration;
    this.keepAliveTimer = setInterval(() => {
      this.store.session.refresh(this.callAreaId, this.callChannelId).then((newToken: string) => {
        if (generation === this.joinGeneration && this.state === CallState.CONNECTED &&
          this.rtc?.renewToken(newToken) !== 0) {
          this.notice = '语音令牌续期失败';
        }
      }).catch((error: Error) => {
        hilog.warn(0x0, TAG, 'Oopz keep-alive failed: %{public}s', error.message);
      });
    }, KEEP_ALIVE_MS);
  }

  private callKeepAlive(): void {
    if (this.keepAliveTimer !== -1) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
  }

  private startSpeakDecayTimer(): void {
    if (this.speakDecayTimer !== -1) {
      return;
    }
    this.speakDecayTimer = setInterval(() => {
      const now = Date.now();
      let hasActive = false;
      this.speakingHoldUntil.forEach((until: number, key: number) => {
        if (until <= now) {
          this.speakingHoldUntil.delete(key);
        } else {
          hasActive = true;
        }
      });
      this.syncRoomMembers();
      if (!hasActive) {
        this.stopSpeakDecayTimer();
      }
    }, 300);
  }

  private stopSpeakDecayTimer(): void {
    if (this.speakDecayTimer !== -1) {
      clearInterval(this.speakDecayTimer);
      this.speakDecayTimer = -1;
    }
  }

  private callEvents(): RtcCallEvents {
    return {
      connected: () => {
        const reconnecting = this.state === CallState.RECONNECTING;
        clearTimeout(this.joinTimer);
        this.state = CallState.CONNECTED;
        this.peerCuesAfter = Date.now() + INITIAL_PEER_SYNC_MS;
        this.notice = '';
        hilog.info(0x0, TAG, 'Native RTC joined');
        if (reconnecting) {
          this.taskAttempted = false;
          if (this.muted) this.rtc?.setMicrophone(false);
          if (this.speakerMuted) this.rtc?.setSpeakerMuted(true);
        }
        this.applyMicGain();
        this.startSystemCallSession();
        this.voiceRoute.refresh();
        this.syncCallStore();
        this.syncViewModels();
        this.maybeStartTask();
        if (this.callAreaId.length > 0 && this.callChannelId.length > 0) {
          const ch = (this.store.channelsByArea.get(this.callAreaId) ?? [])
            .find((c: OopzVoiceChannel): boolean => c.channelId === this.callChannelId);
          if (ch !== undefined) {
            this.store.loadAreaPresence(this.callAreaId, [ch]).then(() => {
              this.syncViewModels();
            }).catch(() => {});
          }
        }
      },
      reconnecting: () => {
        this.state = CallState.RECONNECTING;
        this.peerCuesAfter = Number.POSITIVE_INFINITY;
        this.speakingHoldUntil.clear();
        this.lastRemoteSpeechSample.clear();
        this.syncRoomMembers();
        this.notice = '语音正在重新连接';
        hilog.warn(0x0, TAG, 'Native RTC reconnecting');
      },
      connectionFailed: (reason: number) => {
        const status = reason === 8 || reason === 9 ? '语音会话已过期' : `语音连接中断（${reason}）`;
        const generation = this.joinGeneration;
        setTimeout(() => { if (generation === this.joinGeneration) this.leave(status); }, 0);
      },
      microphoneChanged: (capturing: boolean, reason: number) => {
        this.capturing = capturing;
        hilog.info(0x0, TAG, 'Native mic active=%{public}d reason=%{public}d', capturing ? 1 : 0, reason);
        if (capturing && !this.muted) this.applyMicGain();
        this.voiceRoute.refresh();
        this.syncCallAudioStatus();
        this.maybeStartTask();
      },
      systemStreams: (captureId: number, playbackId: number) => {
        this.voiceRoute.identifySystemStreams(captureId, playbackId);
      },
      peerCountChanged: (count: number) => {
        this.peers = count;
        this.syncCallStore();
        this.syncViewModels();
        hilog.info(0x0, TAG, 'Native RTC remote peers=%{public}d', count);
      },
      peerJoined: (pid: number) => {
        if (!this.rtcPeerPids.has(pid)) this.playPeerCue(true);
        this.rtcPeerPids.add(pid);
        if (this.store.getPersonByPid(pid) === undefined && this.callAreaId.length > 0) {
          const ch = (this.store.channelsByArea.get(this.callAreaId) ?? [])
            .find((c: OopzVoiceChannel): boolean => c.channelId === this.callChannelId);
          if (ch !== undefined) {
            this.store.loadAreaPresence(this.callAreaId, [ch]).then(() => {
              this.syncViewModels();
            }).catch(() => {});
          }
        }
        this.syncRoomMembers();
      },
      peerOffline: (pid: number) => {
        if (this.rtcPeerPids.delete(pid)) this.playPeerCue(false);
        this.remoteMutedPids.delete(pid);
        this.speakingHoldUntil.delete(pid);
        this.lastRemoteSpeechSample.delete(pid);
        this.syncRoomMembers();
      },
      volumeIndication: (speakers: AudioVolumeInfo[], _totalVolume: number) => {
        if (this.state !== CallState.CONNECTED) return;
        const now = Date.now();
        let changed = false;
        for (const s of speakers) {
          // The SDK only reports VAD for the local microphone. Require two above-threshold
          // remote samples to avoid triggering from silence or a single noise spike.
          const active = s.uid === 0 ? (!this.muted && s.vad === 1 && s.volume > 0) :
            this.hasRemoteSpeech(s.uid, s.volume, now);
          if (active) {
            changed = changed || (this.speakingHoldUntil.get(s.uid) ?? 0) <= now;
            this.speakingHoldUntil.set(s.uid, now + SPEAK_HOLD_MS);
          }
        }
        if (this.speakingHoldUntil.size > 0) this.startSpeakDecayTimer();
        if (changed) this.syncRoomMembers();
      },
      userMuteAudio: (pid: number, muted: boolean) => {
        if (muted) {
          this.remoteMutedPids.add(pid);
          this.speakingHoldUntil.delete(pid);
          this.lastRemoteSpeechSample.delete(pid);
        } else {
          this.remoteMutedPids.delete(pid);
        }
        this.syncRoomMembers();
      },
      audioStats: (sent: number, received: number) => {
        if (Date.now() - this.lastStatsAt >= 5000) {
          this.lastStatsAt = Date.now();
          this.rates = `发送 ${sent} kbps · 接收 ${received} kbps`;
          this.voiceRoute.refresh();
          this.syncCallStore();
          hilog.info(0x0, TAG, 'Native audio kbps tx=%{public}d rx=%{public}d background=%{public}d',
            sent, received, this.hiddenAt > 0 ? 1 : 0);
        }
      },
      tokenExpiring: () => {
        if (this.callAreaId.length > 0) {
          const generation = this.joinGeneration;
          this.store.session.refresh(this.callAreaId, this.callChannelId).then((newToken: string) => {
            if (generation === this.joinGeneration) this.rtc?.renewToken(newToken);
          }).catch(() => {});
        }
      },
      error: (code: number) => { hilog.warn(0x0, TAG, 'Native RTC error code=%{public}d', code); }
    };
  }

  private hasRemoteSpeech(pid: number, volume: number, now: number): boolean {
    if (this.remoteMutedPids.has(pid) || volume < REMOTE_SPEECH_MIN_VOLUME) {
      this.lastRemoteSpeechSample.delete(pid);
      return false;
    }
    const previous = this.lastRemoteSpeechSample.get(pid) ?? 0;
    this.lastRemoteSpeechSample.set(pid, now);
    return previous > 0 && now - previous <= REMOTE_SPEECH_SAMPLE_WINDOW_MS;
  }

  private playPeerCue(joined: boolean): void {
    if (!this.speakerMuted && this.state === CallState.CONNECTED && Date.now() >= this.peerCuesAfter) {
      this.rtc?.playRoomCue(joined);
    }
  }

  private toggleSpeaker(): void {
    const next = !this.speakerMuted;
    if (this.rtc?.setSpeakerMuted(next) === 0) {
      this.speakerMuted = next;
    } else {
      this.notice = '切换扬声器静音失败';
    }
  }

  private toggleMicrophone(): void {
    if (this.rtc?.setMicrophone(this.muted) === 0) {
      this.muted = !this.muted;
      if (this.muted) {
        this.capturing = false;
        this.speakingHoldUntil.delete(0);
      }
      if (this.micCue && !this.speakerMuted) this.rtc?.playRoomCue(!this.muted);
      this.voiceRoute.updateMute(this.muted);
      AppStorage.setOrCreate<string>('oopzCallInput', this.muted ? '已关闭' : this.routes.input);
      if (!this.muted) this.applyMicGain();
      this.syncCallStore();
      this.syncRoomMembers();
      this.maybeStartTask();
    } else {
      this.notice = '切换麦克风失败';
    }
  }

  private toggleMemberExpand(uid: string): void {
    if (this.expandedUids.has(uid)) {
      this.expandedUids.delete(uid);
    } else {
      this.expandedUids.add(uid);
    }
    this.syncRoomMembers();
  }

  private setMemberVolume(pid: number, vol: number): void {
    if (this.rtc?.setUserVolume(pid, vol) === 0) {
      this.userVolumeMap.set(pid, vol);
      this.syncRoomMembers();
    } else {
      this.notice = '调节成员音量失败';
    }
  }

  private toggleMemberLocalMute(pid: number): void {
    const next = !(this.userLocalMuteMap.get(pid) ?? false);
    if (this.rtc?.muteRemoteUser(pid, next) === 0) {
      this.userLocalMuteMap.set(pid, next);
      this.syncRoomMembers();
    } else {
      this.notice = '屏蔽成员音频失败';
    }
  }

  private async leave(status: string = ''): Promise<void> {
    if (this.state === CallState.LEAVING) return;
    this.joinGeneration++;
    this.state = CallState.LEAVING;
    clearTimeout(this.joinTimer);
    this.callKeepAlive();
    this.stopSpeakDecayTimer();
    this.lastStatsAt = 0;
    const prevArea = this.callAreaId;
    const prevChannel = this.callChannelId;
    const context = this.getAbilityContext();

    try {
      await this.fallbackCleanup;
      await this.rtc?.close();
    } catch {
      hilog.warn(0x0, TAG, 'Native RTC cleanup failed');
    } finally {
      await this.voiceRoute.close();
      if (prevArea.length > 0 && this.signedIn) {
        try {
          await this.store.session.leave(prevArea, prevChannel);
        } catch (error) {
          hilog.warn(0x0, TAG, 'Oopz leave failed: %{public}s', (error as Error).message);
        }
      }
      await this.startingTask;
      if (context !== undefined && this.voiceTask.isRunning()) {
        try {
          await this.voiceTask.stop(context);
        } catch (error) {
          hilog.warn(0x0, TAG, 'Unable to stop native background task, code=%{public}d', (error as BusinessError).code);
          await this.voiceTask.taskEnded();
        }
      }
      this.callAreaId = '';
      this.callChannelId = '';
      this.callTitle = '';
      this.peers = 0;
      this.capturing = false;
      this.muted = false;
      this.speakerMuted = false;
      this.rates = '';
      this.showMicGain = false;
      this.setMediaInputMenuOpen(false);
      this.routes = new VoiceRouteStatus();
      this.rtcPeerPids.clear();
      this.remoteMutedPids.clear();
      this.speakingHoldUntil.clear();
      this.lastRemoteSpeechSample.clear();
      this.peerCuesAfter = Number.POSITIVE_INFINITY;
      this.userVolumeMap.clear();
      this.userLocalMuteMap.clear();
      this.expandedUids.clear();
      this.notice = status;
      this.state = CallState.IDLE;
      AppStorage.setOrCreate<string>('oopzTaskStatus', '');
      AppStorage.setOrCreate<string>('oopzCallInput', '');
      AppStorage.setOrCreate<string>('oopzCallOutput', '');
      AppStorage.setOrCreate<string>('oopzCallVolumeType', '');
      this.syncCallStore();
      if (prevArea.length > 0 && prevArea === this.selectedAreaId) {
        const ch = this.store.channels.find((c: OopzVoiceChannel): boolean => c.channelId === prevChannel);
        if (ch !== undefined) {
          this.store.loadAreaPresence(prevArea, [ch]).then(() => {
            this.syncViewModels();
          }).catch(() => {});
        }
      }
      this.syncViewModels();
      hilog.info(0x0, TAG, 'Native RTC call ended');
    }
  }

  @Builder
  private desktopHeader() {
    Column() {
      Row({ space: 10 }) {
        if (!this.isWide() && this.desktopPane === 'room' && this.mobilePane === 'room') {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([getTheme(this.isDark).text])
          }
          .width(34)
          .height(34)
          .borderRadius(8)
          .backgroundColor(Color.Transparent)
          .accessibilityText('返回频道列表')
          .hoverEffect(HoverEffect.Highlight)
          .onClick(() => { this.backToParent(); })
        }

        if (this.captionMerged) {
          Image($r('app.media.app_icon')).width(25).height(25)
          Text($r('app.string.app_name')).fontSize(14).fontWeight(FontWeight.Medium).fontColor(getTheme(this.isDark).text)
        }
        Blank()
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.square_and_arrow_down'))
            .fontSize(19).fontColor([getTheme(this.isDark).textSecondary])
        }
        .width(36)
        .height(34)
        .borderRadius(8)
        .backgroundColor(Color.Transparent)
        .accessibilityText('最小化到托盘')
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => { PcTrayManager.get().minimizeToTray(); })
      }
      .width('100%')
      .padding({ left: 12, right: this.captionInset + 12, top: 3, bottom: 3 })
    }
    .width('100%')
    .backgroundColor(getTheme(this.isDark).surfaceSolid)
    .border({ width: { bottom: 1 }, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private desktopUserButton(settings: boolean) {
    Button({ type: ButtonType.Circle }) {
      if (!settings && this.selfAvatar.length > 0) {
        Image(this.selfAvatar).width(30).height(30).borderRadius(15).objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph(settings ? $r('sys.symbol.gearshape') : $r('sys.symbol.person'))
          .fontSize(18)
          .fontColor([getTheme(this.isDark).textSecondary])
      }
    }
    .width(36)
    .height(36)
    .backgroundColor(this.desktopPane === (settings ? 'settings' : 'account')
      ? getTheme(this.isDark).accentSoft : Color.Transparent)
    .accessibilityText(settings ? '设置' : (this.selfName.length > 0 ? `我的，${this.selfName}` : '我的'))
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.areaAdminOpen = false;
      this.desktopPane = settings ? 'settings' : 'account';
    })
  }

  @Builder
  private desktopDomainRail() {
    Column({ space: 6 }) {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.areas, (area: OopzArea) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 5 }) {
                Row()
                  .width(3)
                  .height(22)
                  .borderRadius(2)
                  .backgroundColor(area.areaId === this.selectedAreaId ? getTheme(this.isDark).accent : Color.Transparent)
                Stack() {
                  Text(area.name.slice(0, 1).toUpperCase()).fontSize(15).fontColor(getTheme(this.isDark).accent)
                  if (area.avatar.length > 0) {
                    Image(area.avatar).width(36).height(36).objectFit(ImageFit.Cover)
                  }
                }
                .width(36)
                .height(36)
                .backgroundColor(getTheme(this.isDark).surfaceAlt)
                .borderRadius(10)
                .clip(true)
              }
            }
            .width(54)
            .height(45)
            .padding(0)
            .borderRadius(9)
            .backgroundColor(Color.Transparent)
            .accessibilityText(area.areaId === this.selectedAreaId ? `${area.name}，已选中` : area.name)
            .hoverEffect(HoverEffect.Highlight)
            .onClick(() => { this.desktopPane = 'room'; this.selectArea(area.areaId, true); })
          }, (area: OopzArea) => `${area.areaId}-${area.areaId === this.selectedAreaId}`)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      this.desktopUserButton(false)
      this.desktopUserButton(true)
    }
    .width(PC_DOMAIN_RAIL_WIDTH)
    .height('100%')
    .padding({ top: 10, bottom: 12 })
    .backgroundColor(getTheme(this.isDark).rail)
    .border({ width: { right: 1 }, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private desktopDomainMenu() {
    Menu() {
      ForEach(this.areas, (area: OopzArea) => {
        MenuItem({ content: area.name })
          .selected(area.areaId === this.selectedAreaId)
          .onClick(() => { this.desktopPane = 'room'; this.selectArea(area.areaId, true); })
      }, (area: OopzArea) => area.areaId)
    }
  }

  @Builder
  private desktopChannelRow(ch: ChannelCard) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        if (ch.isText) {
          Text('#').width(16).fontSize(15).fontColor(getTheme(this.isDark).textSecondary)
        } else {
          SymbolGlyph($r('sys.symbol.speaker')).fontSize(16).fontColor([getTheme(this.isDark).textSecondary])
        }
        Text(ch.name)
          .fontSize(13)
          .fontWeight(ch.isSelected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(getTheme(this.isDark).text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (ch.inCall) {
          SymbolGlyph($r('sys.symbol.waveform')).fontSize(14).fontColor([getTheme(this.isDark).speaking])
        }
        if (ch.onlineCount > 0) {
          Text(String(ch.onlineCount)).fontSize(11).fontColor(getTheme(this.isDark).textSecondary)
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height(35)
    .padding(0)
    .borderRadius(7)
    .backgroundColor(ch.isSelected ? getTheme(this.isDark).accentSoft : Color.Transparent)
    .accessibilityText(`${ch.name}${ch.inCall ? '，通话中' : ''}${ch.isSelected ? '，正在浏览' : ''}`)
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => { this.desktopPane = 'room'; this.selectChannel(ch.channelId); })
  }

  private closeAreaAdmin(): void {
    this.areaAdminOpen = false;
    this.adminBack = undefined;
    if (this.isPc && !this.isWide() && this.selectedChannelObj !== undefined) this.mobilePane = 'room';
  }

  @Builder
  private adminEntry() {
    Button('域管理').fontSize(13).height(34).padding({ left: 10, right: 10 })
      .fontColor(getTheme(this.isDark).accent).backgroundColor(getTheme(this.isDark).accentSoft)
      .onClick(() => {
        if (!this.canManageArea || this.areaAdminOpen) return;
        if (!this.isPc) this.rememberChannelPosition();
        this.desktopPane = 'room';
        this.adminBack = undefined;
        this.areaAdminOpen = true;
      })
  }

  @Builder
  private adminPanel() {
    AreaAdminPanel({
      areaId: this.selectedAreaId,
      areaName: this.selectedAreaObj?.name ?? '',
      isDesktop: this.isPc,
      revision: this.adminRevision,
      onBackHandler: (handler: () => void) => { this.adminBack = handler; },
      onStructureChanged: (areaId: string) => { this.syncAdminChannels(areaId); },
      onClose: () => { this.closeAreaAdmin(); }
    })
  }

  @Builder
  private desktopAreaTitle() {
    if (this.showsDesktopDomainRail() || !this.isWide() || this.areas.length === 0) {
      Text(this.selectedAreaObj?.name ?? '频道')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(getTheme(this.isDark).text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 5, right: 5, top: 7, bottom: 5 })
    } else {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Text(this.selectedAreaObj?.name ?? '选择域')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(13).fontColor([getTheme(this.isDark).textMuted])
        }
        .width('100%')
        .padding({ left: 5, right: 5 })
      }
      .width('100%')
      .height(34)
      .padding(0)
      .borderRadius(7)
      .backgroundColor(Color.Transparent)
      .accessibilityText(`${this.selectedAreaObj?.name ?? '频道'}，切换域`)
      .hoverEffect(HoverEffect.Highlight)
      .bindMenu(this.desktopDomainMenu())
    }
  }

  @Builder
  private desktopChannelPane() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        Column() { this.desktopAreaTitle() }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.canManageArea) { this.adminEntry() }
      }.width('100%')
      if (this.channelCards.length === 0) {
        Text(this.readingRooms ? '正在读取频道…' : '暂无可浏览的频道')
          .fontSize(12)
          .fontColor(getTheme(this.isDark).textMuted)
          .padding(5)
      } else {
        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.desktopChannelItems(), (item: ChannelListItem) => {
              if (item.channel !== undefined) {
                this.desktopChannelRow(item.channel)
              } else {
                Text(item.label)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(getTheme(this.isDark).textMuted)
                  .padding({ left: 6, top: 9, bottom: 4 })
              }
            }, (item: ChannelListItem) => item.key)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
      }
    }
    .height('100%')
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(getTheme(this.isDark).canvasTint)
  }

  @Builder
  private desktopCallSummary() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(19)
          .fontColor([this.isInCall() ? getTheme(this.isDark).accent : getTheme(this.isDark).textMuted])
        Column({ space: 2 }) {
          Text(this.isInCall() ? (this.activeCallName || this.callTitle || '语音频道') : '未连接语音')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.isInCall()) {
            Text(this.callStateText())
              .fontSize(11)
              .fontColor(this.state === CallState.CONNECTED ? getTheme(this.isDark).speaking : getTheme(this.isDark).textMuted)
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
    }
    .layoutWeight(1)
    .height(42)
    .padding({ left: 3, right: 3 })
    .borderRadius(8)
    .backgroundColor(Color.Transparent)
    .accessibilityText(this.callAreaId.length > 0 ? `返回当前通话，${this.activeCallName || this.callTitle}` : this.callStateText())
    .enabled(this.callAreaId.length > 0)
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => { this.desktopPane = 'room'; this.jumpToActiveRoom(); })
  }

  @Builder
  private callActions(compact: boolean) {
    Row({ space: 6 }) {
      Row() {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.muted ? $r('sys.symbol.mic_slash') : $r('sys.symbol.mic'))
            .fontSize(18)
            .fontColor([this.muted ? getTheme(this.isDark).accent : getTheme(this.isDark).text])
        }
        .width(this.isPc ? 35 : 50)
        .height(42)
        .padding(0)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.muted ? '麦克风已闭麦，点击打开' : '麦克风，点击闭麦')
        .enabled(this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.toggleMicrophone(); })
        if (this.isPc) {
          Divider().vertical(true).height(15).color(getTheme(this.isDark).borderSubtle)
          this.inputDevicePicker()
        }
      }
      .height(42)
      .borderRadius(AppSpacing.radius)
      .backgroundColor(this.muted ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceAlt)

      Row() {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.speakerMuted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker'))
            .fontSize(18)
            .fontColor([this.speakerMuted ? getTheme(this.isDark).accent : getTheme(this.isDark).text])
        }
        .width(35)
        .height(42)
        .padding(0)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.speakerMuted ? '扬声器已静音，点击恢复' : '扬声器，点击静音')
        .enabled(this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.toggleSpeaker(); })
        Divider().vertical(true).height(15).color(getTheme(this.isDark).borderSubtle)
        VoiceOutputPicker({
          label: this.routes.output,
          isDark: this.isDark,
          split: true,
          sessionType: this.state !== CallState.LEAVING ? (this.routes.pickerType ?? '') : '',
          onOpenChange: (open: boolean) => { this.deviceMenuState('voice-output-picker', open); }
        })
      }
      .height(42)
      .borderRadius(AppSpacing.radius)
      .backgroundColor(this.speakerMuted ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceAlt)

      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.waveform')).fontSize(17)
          .fontColor([this.showMicGain ? getTheme(this.isDark).accent : getTheme(this.isDark).text])
      }
      .width(40)
      .height(42)
      .padding(0)
      .borderRadius(AppSpacing.radius)
      .backgroundColor(this.showMicGain ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceAlt)
      .accessibilityText('调节麦克风发送音量')
      .onClick(() => { this.showMicGain = !this.showMicGain; })

      Button({ type: ButtonType.Capsule }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.phone_down_fill')).fontSize(17).fontColor([getTheme(this.isDark).dangerText])
          if (!compact) {
            Text(this.state === CallState.JOINING ? '取消' : '离开').fontSize(12)
              .fontColor(getTheme(this.isDark).dangerText)
          }
        }
      }
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(getTheme(this.isDark).dangerFill)
      .accessibilityText(this.state === CallState.JOINING ? '取消加入语音' : '离开语音频道')
      .enabled(this.isInCall() && this.state !== CallState.LEAVING)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => { this.leave(); })
    }
  }

  @Builder
  private microphoneGainPanel() {
    VoiceGainSlider({
      label: '麦克风发送音量',
      value: this.micGain,
      max: MAX_MIC_GAIN,
      isDark: this.isDark,
      onGainChange: (gain: number, commit: boolean) => {
        this.store.setMicGain(this.getAbilityContext(), gain, commit);
      }
    })
  }

  @Builder
  private inputPickerGlyph() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([getTheme(this.isDark).textSecondary])
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  private deviceMenuState(source: string, open: boolean): void {
    this.store.setGripInteractionActive(source, open);
    if (!open) this.voiceRoute.refresh();
  }

  private setMediaInputMenuOpen(open: boolean): void {
    if (this.mediaInputMenuOpen === open) return;
    this.mediaInputMenuOpen = open;
    this.deviceMenuState('voice-input-menu', open);
  }

  private async selectMediaInput(device?: audio.AudioDeviceDescriptor): Promise<void> {
    this.setMediaInputMenuOpen(false);
    try {
      await this.voiceRoute.selectMediaInput(device);
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '系统未能切换麦克风设备' });
    }
  }

  @Builder
  private mediaInputMenu() {
    Menu() {
      MenuItem({ content: '由系统选择' }).onClick(() => { this.selectMediaInput(); })
      ForEach(this.voiceRoute.getMediaInputs(), (device: audio.AudioDeviceDescriptor) => {
        MenuItem({ content: voiceDeviceName(device) || '系统麦克风' })
          .onClick(() => { this.selectMediaInput(device); })
      }, (device: audio.AudioDeviceDescriptor) => String(device.id))
    }
  }

  @Builder
  private inputDevicePicker() {
    if (this.routes.independentInput) {
      AVInputCastPicker({
        customPicker: () => this.inputPickerGlyph(),
        onStateChange: (state: AVCastPickerState) => {
          this.deviceMenuState('voice-input-picker', state === AVCastPickerState.STATE_APPEARING);
        }
      })
        .width(39)
        .height(42)
        .accessibilityText(this.routes.input ? '选择麦克风，当前' + this.routes.input : '选择麦克风设备')
    } else {
      Button({ type: ButtonType.Normal }) {
        this.inputPickerGlyph()
      }
      .width(39)
      .height(42)
      .padding(0)
      .borderRadius(AppSpacing.radiusSm)
      .backgroundColor(Color.Transparent)
      .enabled(this.routes.mediaInput)
      .opacity(this.routes.mediaInput ? 1 : 0.42)
      .accessibilityText(this.routes.mediaInput ? '选择麦克风设备' : '麦克风由系统选择')
      .onClick(() => { this.setMediaInputMenuOpen(!this.mediaInputMenuOpen); })
      .bindMenu(this.mediaInputMenuOpen, this.mediaInputMenu, {
        systemMaterial: nativePopupMaterial(this.immersiveLight),
        onDisappear: () => { this.setMediaInputMenuOpen(false); }
      })
    }
  }

  @Builder
  private desktopCallBar() {
    Column() {
      Column() {
        if (this.showMicGain && this.isInCall()) {
          Column() {
            this.microphoneGainPanel()
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 4 })
        }
        if (this.isDesktopCallBarCompact()) {
          Row({ space: 5 }) {
            if (!this.showsDesktopDomainRail()) {
              this.desktopUserButton(false)
              this.desktopUserButton(true)
            }
            this.desktopCallSummary()
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 2 })

          Row() {
            if (this.isInCall()) {
              this.callActions(this.isDesktopCallBarCompact())
            }
          }
          .width('100%')
          .padding({ left: 8, right: 8, bottom: 6 })
          .justifyContent(FlexAlign.End)
        } else {
          Row({ space: 8 }) {
            if (!this.showsDesktopDomainRail()) {
              this.desktopUserButton(false)
              this.desktopUserButton(true)
            }
            this.desktopCallSummary()
            if (this.isInCall()) {
              this.callActions(this.isDesktopCallBarCompact())
            }
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        }
      }
      .width('100%')
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
      .borderRadius(AppSpacing.radius)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 5, bottom: 10 })
  }

  @Builder
  private headerBar() {
    Row({ space: 9 }) {
      if (this.mobilePane === 'room') {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(17).fontColor([getTheme(this.isDark).text])
        }
        .width(40)
        .height(40)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .accessibilityText('返回频道列表')
        .onClick(() => { this.backToParent(); })
      }
      Text(this.mobilePane === 'room' && !this.isWide()
        ? (this.selectedChannelObj?.name ?? '频道')
        : (this.selectedAreaObj?.name ?? '频道'))
        .layoutWeight(1)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(getTheme(this.isDark).text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.mobilePane === 'channels' && this.canManageArea) { this.adminEntry() }
    }
    .width('100%')
    .height(50)
    .padding({
      left: this.mobilePane === 'channels'
        ? MOBILE_DOMAIN_RAIL_WIDTH + MOBILE_CHANNEL_PADDING + MOBILE_DOMAIN_TITLE_INDENT : 12,
      right: 10,
      top: 6,
      bottom: 6
    })
    .backgroundColor(getTheme(this.isDark).bg)
  }

  @Builder
  private mobileDomainRail() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.areas, (area: OopzArea) => {
          Button({ type: ButtonType.Normal }) {
            if (area.avatar.length > 0) {
              Image(area.avatar).width(38).height(38).borderRadius(AppSpacing.radiusSm)
                .clip(true).objectFit(ImageFit.Cover)
            } else {
              Text(area.name.slice(0, 1))
                .width(38).height(38)
                .textAlign(TextAlign.Center)
                .fontSize(17)
                .fontColor(getTheme(this.isDark).text)
                .backgroundColor(getTheme(this.isDark).surfaceAlt)
                .borderRadius(AppSpacing.radiusSm)
            }
          }
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .border({ width: 1.5, color: area.areaId === this.selectedAreaId ? getTheme(this.isDark).accent :
            Color.Transparent, radius: AppSpacing.radiusSm + 3 })
          .accessibilityText(area.areaId === this.selectedAreaId ? `${area.name}，当前域` : area.name)
          .onClick(() => { this.selectArea(area.areaId); })
        }, (area: OopzArea) => area.areaId)
      }
      .width('100%')
      .padding({ top: 8, bottom: 10 + this.mobileBottomBarInset() })
    }
    .scrollBar(BarState.Off)
    .width(MOBILE_DOMAIN_RAIL_WIDTH)
    .height('100%')
    .align(Alignment.Top)
  }

  private toggleChannelMembers(channelId: string): void {
    this.expandedChannels = this.expandedChannels.includes(channelId)
      ? this.expandedChannels.filter((id: string) => id !== channelId)
      : this.expandedChannels.concat([channelId]);
  }

  private rememberChannelPosition(): void {
    if (this.selectedAreaId.length === 0) return;
    try {
      this.channelOffsets.set(this.selectedAreaId, this.channelScroller.currentOffset().yOffset);
    } catch {
      // The list may already have left the view.
    }
  }

  private restoreChannelPosition(): void {
    const areaId = this.selectedAreaId;
    const yOffset = this.channelOffsets.get(areaId) ?? 0;
    setTimeout(() => {
      if (!this.activePage || this.selectedAreaId !== areaId) return;
      try {
        this.channelScroller.scrollTo({ xOffset: 0, yOffset: yOffset, animation: false });
      } catch {
        // The list has not appeared on this layout.
      }
    }, 0);
  }

  @Builder
  private mobileChannelRow(channel: ChannelCard) {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph(channel.isText ? $r('sys.symbol.message') : $r('sys.symbol.mic'))
            .fontSize(17)
            .fontColor([channel.inCall ? getTheme(this.isDark).accent : getTheme(this.isDark).textSecondary])
          Text(channel.name)
            .layoutWeight(1)
            .fontSize(14)
            .fontWeight(channel.inCall ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!channel.isText) {
            Text(channel.maxMember > 0 ? channel.onlineCount + '/' + channel.maxMember : String(channel.onlineCount))
              .fontSize(11)
              .fontColor(getTheme(this.isDark).textMuted)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height(40)
      .padding({ left: 8, right: 6 })
      .borderRadius(AppSpacing.radiusSm)
      .backgroundColor(Color.Transparent)
      .accessibilityText(channel.name)
      .onClick(() => { this.selectChannel(channel.channelId); })
      if (!channel.isText && channel.members.length > 0) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.expandedChannels.includes(channel.channelId) ? $r('sys.symbol.chevron_up') :
            $r('sys.symbol.chevron_down')).fontSize(12).fontColor([getTheme(this.isDark).textSecondary])
        }
        .width(36)
        .height(40)
        .padding(0)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.expandedChannels.includes(channel.channelId) ? '收起 ' + channel.name + ' 的成员' :
          '展开 ' + channel.name + ' 的成员')
        .onClick(() => { this.toggleChannelMembers(channel.channelId); })
      }
    }
    .width('100%')
    .borderRadius(AppSpacing.radiusSm)
    .backgroundColor(channel.inCall || (this.mobilePane === 'room' && channel.isSelected)
      ? getTheme(this.isDark).accentSoft : Color.Transparent)

    if (this.expandedChannels.includes(channel.channelId) && channel.members.length > 0) {
      Column({ space: 4 }) {
        ForEach(channel.members, (member: ChannelMemberPreview) => {
          Row({ space: 8 }) {
            if (member.avatar.length > 0) {
              Image(member.avatar).width(24).height(24).borderRadius(12).objectFit(ImageFit.Cover)
            } else {
              SymbolGlyph($r('sys.symbol.person')).fontSize(24)
                .fontColor([getTheme(this.isDark).textMuted])
            }
            Text(member.name).fontSize(12).fontColor(getTheme(this.isDark).textSecondary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(29)
        }, (member: ChannelMemberPreview) => member.uid + member.name + member.avatar)
      }
      .width('100%')
      .padding({ left: 25, right: 6, bottom: 4 })
    }
  }

  @Builder
  private mobileChannelBrowser() {
    Scroll(this.channelScroller) {
      Column({ space: 3 }) {
        if ((this.selectedAreaObj?.banner ?? '').length > 0) {
          Image(this.selectedAreaObj?.banner ?? '')
            .width('100%')
            .aspectRatio(1.78)
            .constraintSize({ maxHeight: 188 })
            .objectFit(ImageFit.Cover)
            .borderRadius(AppSpacing.radius)
            .clip(true)
            .margin({ bottom: 5 })
            .accessibilityText('域封面')
        }
        ForEach(this.desktopChannelItems(), (item: ChannelListItem) => {
          if (item.channel === undefined) {
            Text(item.label)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(getTheme(this.isDark).textSecondary)
              .padding({ left: 8, top: 10, bottom: 2 })
              .maxLines(1)
          } else {
            this.mobileChannelRow(item.channel)
          }
        }, (item: ChannelListItem) => item.key)
        if (this.channelCards.length === 0) {
          Text(this.readingRooms ? '正在加载频道…' : (this.notice || '暂无频道'))
            .fontSize(13)
            .fontColor(getTheme(this.isDark).textMuted)
            .padding(10)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: MOBILE_CHANNEL_PADDING, right: MOBILE_CHANNEL_PADDING, top: 8, bottom: 12 + this.mobileBottomBarInset()
      })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .onAppear(() => { this.restoreChannelPosition(); })
    .onScrollStop(() => { this.rememberChannelPosition(); })
  }

  @Builder
  private domainHome() {
    Column({ space: 12 }) {
      if ((this.selectedAreaObj?.avatar ?? '').length > 0) {
        Image(this.selectedAreaObj?.avatar ?? '').width(62).height(62).borderRadius(AppSpacing.radius)
          .objectFit(ImageFit.Cover)
      }
      Text(this.selectedAreaObj?.name ?? '域主页').fontSize(21).fontWeight(FontWeight.Bold)
        .fontColor(getTheme(this.isDark).text).maxLines(2)
      Text(this.channelCards.length + ' 个频道').fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private textChatPane() {
    Column({ space: 10 }) {
      // Text channel header bar
      Row({ space: 10 }) {
        Column() {
          Text('#').fontSize(16).fontWeight(FontWeight.Bold).fontColor(getTheme(this.isDark).accent)
        }
        .width(34)
        .height(34)
        .borderRadius(10)
        .backgroundColor(getTheme(this.isDark).accentSoft)
        .justifyContent(FlexAlign.Center)

        Column({ space: 2 }) {
          Text(this.selectedChannelObj?.name ?? '')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.selectedAreaObj?.name ?? ''} · 文字聊天区`)
            .fontSize(11)
            .fontColor(getTheme(this.isDark).textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.loadingChat ? '加载中…' : '加载更早')
          .height(30)
          .padding({ left: 10, right: 10 })
          .fontSize(11)
          .borderRadius(10)
          .backgroundColor(getTheme(this.isDark).surfaceAlt)
          .fontColor(getTheme(this.isDark).textSecondary)
          .enabled(!this.loadingChat)
          .onClick(() => { this.loadOlderMessages(); })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(16)
      .backgroundColor(getTheme(this.isDark).surface)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })

      // Message timeline
      if (this.chatMessages.length === 0) {
        Column() {
          Text(this.loadingChat ? '正在拉取频道消息…' : '暂时还没有聊天消息')
            .fontSize(13)
            .fontColor(getTheme(this.isDark).textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Stack({ alignContent: Alignment.BottomEnd }) {
          List({ scroller: this.chatScroller, space: 8 }) {
            ForEach(this.chatMessages, (msg: ChatMessageItem) => {
              ListItem() {
                ChatMessageRow({
                  item: msg, isDark: this.isDark, oopzEmojiFontReady: this.oopzEmojiFontReady, isDesktop: this.isPc,
                  onMessageMenu: (item: ChatMessageItem, x: number, y: number) => { this.openMessageMenu(item, x, y); },
                  onPreview: (image: OopzChatAttachment) => { this.openChatImage(msg, image); }
                })
              }
              .onAreaChange(() => {
                if (this.chatMessages[this.chatMessages.length - 1]?.key === msg.key) this.updateChatEnd();
              })
            }, (msg: ChatMessageItem) => `${msg.key}_${this.isDark ? 1 : 0}_${msg.textRuns.length > 0 && this.oopzEmojiFontReady}`)
          }
          .width('100%')
          .height('100%')
          .maintainVisibleContentPosition(true)
          .onScrollIndex((first: number, last: number) => {
            this.chatFirstVisible = first;
            this.chatLastVisible = last;
            this.updateChatEnd();
          })
          .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => {
            if (offset !== 0 && !this.hasChatAction() && (source === ScrollSource.DRAG ||
              source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
              source === ScrollSource.FLING || source === ScrollSource.SCROLL_BAR_FLING)) this.chatInteraction++;
          })
          .onDidScroll(() => { this.updateChatEnd(); })
          .onAreaChange(() => { this.updateChatEnd(); })
          .padding(4)
          if (!this.chatAtEnd) {
            Button('回到最底部').height(40).fontSize(13).padding({ left: 14, right: 14 })
              .fontColor(getTheme(this.isDark).accent).backgroundColor(getTheme(this.isDark).surfaceSolid)
              .border({ width: 1, color: getTheme(this.isDark).border }).margin({ right: 8, bottom: 8 })
              .onClick(() => { this.jumpToChatEnd(); })
          }
        }.width('100%').layoutWeight(1)
      }

      if (this.notice.length > 0) {
        Text(this.notice).fontSize(12).fontColor(getTheme(this.isDark).warn)
      }

      if (this.chatReply !== undefined) {
        ChatReferenceStrip({
          reference: this.chatReferenceView(this.chatReply.messageId, this.chatReply),
          isDark: this.isDark, inComposer: true, canRemove: !this.sendingChat,
          onRemove: () => { this.chatReply = undefined; this.notice = ''; }
        })
      }
      if (this.chatImage !== undefined) {
        Row({ space: 10 }) {
          Image(this.chatImage.previewUri).width(46).height(46).borderRadius(6)
            .objectFit(ImageFit.Contain).draggable(false).accessibilityText('待发送图片预览')
          Text(this.chatImage.name).layoutWeight(1).fontSize(13).maxLines(1)
            .fontColor(getTheme(this.isDark).text).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('×').width(34).height(34).fontSize(18).backgroundColor(Color.Transparent)
            .fontColor(getTheme(this.isDark).textSecondary).accessibilityText('移除图片')
            .enabled(!this.sendingChat).onClick(() => { this.clearChatImage(); this.notice = ''; })
        }.width('100%').padding(6).borderRadius(8).backgroundColor(getTheme(this.isDark).surfaceAlt)
      }

      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          if (this.pickingChatImage) {
            LoadingProgress().width(20).height(20).color(getTheme(this.isDark).accent)
          } else {
            SymbolGlyph($r('sys.symbol.picture')).fontSize(21).fontColor([getTheme(this.isDark).text])
          }
        }
        .width(46).height(42).padding(0).borderRadius(12)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .accessibilityText(this.pickingChatImage ? '正在选择图片' : '选择图片')
        .enabled(!this.sendingChat && !this.pickingChatImage)
        .onClick(() => { this.chooseChatImage(); })

        TextInput({
          placeholder: `发消息到 #${this.selectedChannelObj?.name ?? '频道'}`,
          text: this.chatInput
        })
          .id('chat-composer-input')
          .layoutWeight(1)
          .height(42)
          .borderRadius(14)
          .fontColor(getTheme(this.isDark).text)
          .fontFamily(this.oopzEmojiFontReady && /[\u{103200}-\u{10320f}]/u.test(this.chatInput)
            ? OOPZ_EMOJI_FONT_FAMILY + ',sans-serif' : undefined)
          .placeholderColor(getTheme(this.isDark).textMuted)
          .backgroundColor(getTheme(this.isDark).surfaceAlt)
          .enterKeyType(EnterKeyType.Send)
          .onChange((val: string) => { this.chatInput = val; })
          .onSubmit(() => { this.sendChatMessage(); })

        ChatEmojiPicker({
          isDark: this.isDark,
          isOpen: $emojiPickerOpen,
          fontReady: this.oopzEmojiFontReady,
          fontLoading: this.oopzEmojiFontLoading,
          onPick: (emoji: string) => { this.chatInput += emoji; },
          onOpenChange: (open: boolean) => {
            this.store.setGripInteractionActive('voice-emoji', open);
            if (open) this.loadOopzEmojiFont();
          }
        })

        Button({ type: ButtonType.Normal }) {
          if (this.sendingChat) {
            LoadingProgress().width(20).height(20).color(getTheme(this.isDark).accentText)
          } else {
            SymbolGlyph($r('sys.symbol.paperplane_fill')).fontSize(21)
              .fontColor([getTheme(this.isDark).accentText])
          }
        }
        .width(60).height(42).padding(0).borderRadius(14)
        .backgroundColor(getTheme(this.isDark).accent)
        .accessibilityText(this.sendingChat ? '正在发送' : '发送消息')
        .enabled(!this.sendingChat && !this.pickingChatImage &&
          (this.chatInput.trim().length > 0 || this.chatImage !== undefined))
        .onClick(() => { this.sendChatMessage(); })
      }
      .width('100%')
      .padding(8)
      .borderRadius(18)
      .backgroundColor(getTheme(this.isDark).surface)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16,
      top: 14,
      bottom: 8
    })
  }

  @Builder
  private desktopRoomHeader() {
    Stack({ alignContent: Alignment.Start }) {
      if ((this.selectedAreaObj?.banner ?? '').length > 0) {
        Image(this.selectedAreaObj?.banner ?? '')
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
        Row()
          .width('100%')
          .height('100%')
          .linearGradient({
            direction: GradientDirection.Right,
            colors: [
              [getTheme(this.isDark).bg, 0],
              [getTheme(this.isDark).bg, 0.24],
              [Color.Transparent, 0.92]
            ]
          })
          .hitTestBehavior(HitTestMode.None)
        Row()
          .width('100%')
          .height('100%')
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [[Color.Transparent, 0.25], [getTheme(this.isDark).bg, 1]]
          })
          .hitTestBehavior(HitTestMode.None)
      }

      Column({ space: 5 }) {
        Text(this.selectedChannelObj?.name ?? '')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(getTheme(this.isDark).text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 7 }) {
          if (this.isViewingActiveRoom()) {
            Row().width(7).height(7).borderRadius(4)
              .backgroundColor(this.state === CallState.CONNECTED ? getTheme(this.isDark).speaking : getTheme(this.isDark).warn)
            Text(this.callStateText()).fontSize(12).fontColor(getTheme(this.isDark).textSecondary)
          }
          Text((this.selectedChannelObj?.maxMember ?? 0) > 0
            ? `${this.roomMembers.length} / ${this.selectedChannelObj?.maxMember} 人` : `${this.roomMembers.length} 人`)
            .fontSize(12)
            .fontColor(getTheme(this.isDark).textSecondary)
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(116)
    .clip(true)
    .backgroundColor(getTheme(this.isDark).bg)
    .border({ width: { bottom: 1 }, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private voiceRoomPane() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.isPc) {
          this.desktopRoomHeader()
        } else {
          // Hero Cover Card with Area Banner + Directional Gradient Scrim
          Stack({ alignContent: Alignment.BottomStart }) {
            if ((this.selectedAreaObj?.banner ?? '').length > 0) {
              Image(this.selectedAreaObj?.banner ?? '')
                .width('100%')
                .height(152)
                .borderRadius(20)
                .objectFit(ImageFit.Cover)
            } else if ((this.selectedAreaObj?.avatar ?? '').length > 0) {
              Image(this.selectedAreaObj?.avatar ?? '')
                .width('100%')
                .height(152)
                .borderRadius(20)
                .objectFit(ImageFit.Cover)
            } else {
              Column()
                .width('100%')
                .height(152)
                .borderRadius(20)
                .linearGradient({
                  angle: 135,
                  colors: [[getTheme(this.isDark).tint, 0.0], [getTheme(this.isDark).surfaceSolid, 1.0]]
                })
            }

            Column()
              .width('100%')
              .height(152)
              .borderRadius(20)
              .linearGradient({
                direction: GradientDirection.Top,
                colors: [
                  [getTheme(this.isDark).scrimStart, 0.0],
                  [getTheme(this.isDark).scrimMid, 0.55],
                  [getTheme(this.isDark).scrimEnd, 1.0]
                ]
              })

            Column({ space: 4 }) {
              Text(`${this.selectedAreaObj?.name ?? ''} · ${this.selectedChannelObj?.group ?? '语音频道'}`)
                .fontSize(12)
                .fontColor('#DAE4F2')
              Text(this.selectedChannelObj?.name ?? '')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Row({ space: 6 }) {
                if (this.state !== CallState.IDLE && this.callChannelId === this.selectedChannelId) {
                  Row()
                    .width(8)
                    .height(8)
                    .borderRadius(4)
                    .backgroundColor(getTheme(this.isDark).speaking)
                  Text(this.state === CallState.CONNECTED ? '语音已连接' :
                    (this.state === CallState.JOINING ? '正在加入…' :
                      (this.state === CallState.RECONNECTING ? '重新连接中…' : '正在退出…')))
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(getTheme(this.isDark).speaking)
                } else {
                  Text(`${this.roomMembers.length} / ${this.selectedChannelObj?.maxMember ?? 50} 人 · ${this.selectedChannelObj?.voiceQuality ?? '64k'}`)
                    .fontSize(12)
                    .fontColor('#DAE4F2')
                }
              }
            }
            .width('100%')
            .padding(18)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .height(152)
          .border({ width: 1, color: getTheme(this.isDark).specularBorder })
          .borderRadius(20)
          .shadow({ radius: 22, color: getTheme(this.isDark).shadowColor, offsetY: 8 })
        }

        if (this.isViewingActiveRoom()) {
          Text(this.rates || '发送 0 kbps · 接收 0 kbps')
            .width('100%')
            .fontSize(12)
            .fontColor(getTheme(this.isDark).textSecondary)
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(AppSpacing.radiusSm)
            .backgroundColor(getTheme(this.isDark).surface)
            .border({ width: 1, color: getTheme(this.isDark).borderSubtle })

          if (!this.isPc) {
            Row() {
              this.callActions(true)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            if (this.showMicGain) {
              this.microphoneGainPanel()
            }
          }
        }

        // Action Controls
        if (this.state === CallState.IDLE) {
          Row({ space: 10 }) {
            Button(IS_MATE90_EMULATOR ? '当前设备仅支持浏览' : '加入语音')
              .height(44)
              .padding({ left: 24, right: 24 })
              .borderRadius(14)
              .backgroundColor(getTheme(this.isDark).accent)
              .fontColor(getTheme(this.isDark).accentText)
              .fontWeight(FontWeight.Medium)
              .shadow({ radius: 16, color: getTheme(this.isDark).accentSoft, offsetY: 4 })
              .enabled(!IS_MATE90_EMULATOR && this.sdkVersion.length > 0 && !this.readingRooms)
              .onClick(() => { this.join(); })
          }
          .width('100%')
        } else if (!this.isViewingActiveRoom()) {
          Row({ space: 8 }) {
            Button(this.state === CallState.JOINING ? '正在加入语音' : '切换到此频道')
              .layoutWeight(1)
              .height(44)
              .borderRadius(14)
              .backgroundColor(getTheme(this.isDark).accent)
              .fontColor(getTheme(this.isDark).accentText)
              .enabled(!IS_MATE90_EMULATOR && (this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING))
              .onClick(() => { this.switchToSelectedRoom(); })

            Button('回到当前通话')
              .height(44)
              .padding({ left: 14, right: 14 })
              .borderRadius(14)
              .backgroundColor(getTheme(this.isDark).surface)
              .fontColor(getTheme(this.isDark).text)
              .border({ width: 1, color: getTheme(this.isDark).specularBorder })
              .enabled(this.callAreaId.length > 0)
              .onClick(() => { this.jumpToActiveRoom(); })
          }
          .width('100%')
        }

        Column({ space: 6 }) {
          Row() {
            Text(`频道成员（${this.roomMembers.length}）`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(getTheme(this.isDark).text)
            Blank()
            if (this.isViewingActiveRoom()) {
              Text('点击成员调音量').fontSize(11).fontColor(getTheme(this.isDark).textMuted)
            }
          }
          .width('100%')

          if (this.roomMembers.length === 0) {
            Text('现在还没有人在频道里')
              .fontSize(13)
              .fontColor(getTheme(this.isDark).textMuted)
              .padding({ top: 10, bottom: 10 })
          } else {
            ForEach(this.roomMembers, (member: RoomMemberModel) => {
              MemberRow({
                item: member,
                inCurrentCall: this.isViewingActiveRoom(),
                isDark: this.isDark,
                compact: this.isPc,
                onToggleExpand: (uid: string) => { this.toggleMemberExpand(uid); },
                onSelectVolume: (pid: number, vol: number) => { this.setMemberVolume(pid, vol); },
                onToggleLocalMute: (pid: number) => { this.toggleMemberLocalMute(pid); }
              })
            }, (member: RoomMemberModel) => member.uid)
          }
        }
        .width('100%')
        .padding(this.isPc ? 0 : 16)
        .backgroundColor(this.isPc ? getTheme(this.isDark).bg : getTheme(this.isDark).surface)
        .borderRadius(this.isPc ? 0 : 18)
        .border({ width: this.isPc ? 0 : 1, color: getTheme(this.isDark).borderSubtle })
        .alignItems(HorizontalAlign.Start)

        if (this.notice.length > 0) {
          Text(this.notice).fontSize(13).fontColor(getTheme(this.isDark).warn)
        }
      }
      .width('100%')
      .padding({
        left: 16, right: 16, top: this.isPc ? 0 : 16, bottom: 12 + (this.isPc ? 0 : BOTTOM_BAR_INSET)
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
  }

  @Builder
  private roomDetailPane() {
    if (this.selectedChannelObj === undefined) {
      Column() {
        Text(this.readingRooms ? '正在加载频道信息…' : '请从左侧选择一个频道')
          .fontSize(14)
          .fontColor(getTheme(this.isDark).textMuted)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.selectedChannelObj.type === 'TEXT') {
      this.textChatPane()
    } else {
      this.voiceRoomPane()
    }
  }

  @Builder
  private desktopShell() {
    Column() {
      this.desktopHeader()

      Row() {
        if (this.showsDesktopDomainRail()) {
          this.desktopDomainRail()
        }
        if (this.isWide()) {
          Column() {
            this.desktopChannelPane()
          }
          .width(PC_CHANNEL_PANE_WIDTH)
          .height('100%')
          .border({ width: { right: 1 }, color: getTheme(this.isDark).borderSubtle })
        }

        Column() {
          Column() {
            if (this.areaAdminOpen) {
              this.adminPanel()
            } else if (this.desktopPane !== 'room') {
              AccountPanel({
                embedded: true,
                settingsFirst: this.desktopPane === 'settings',
                onClose: () => { this.desktopPane = 'room'; }
              })
            } else if (!this.isWide() && this.mobilePane !== 'room') {
              this.desktopChannelPane()
            } else {
              this.roomDetailPane()
            }
          }
          .width('100%')
          .layoutWeight(1)

          this.desktopCallBar()
        }
        .height('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(getTheme(this.isDark).bg)
  }

  @Builder
  private mobileShell() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(getTheme(this.isDark).bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None)

      Column() {
        if (this.mobilePane !== 'account') {
          this.headerBar()
        }

        Column() {
          if (this.mobilePane === 'account') {
            AccountPanel({
              embedded: true,
              bottomInset: BOTTOM_BAR_INSET,
              onClose: () => { this.backToParent(); }
            })
          } else if (this.isWide()) {
            Row() {
              this.mobileDomainRail()
              Column() {
                this.mobileChannelBrowser()
              }
              .width(226)
              .height('100%')
              Column() {
                if (this.mobilePane === 'room') {
                  this.roomDetailPane()
                } else {
                  this.domainHome()
                }
              }
              .layoutWeight(1)
              .height('100%')
            }
            .width('100%')
            .height('100%')
          } else if (this.mobilePane === 'channels') {
            Row() {
              this.mobileDomainRail()
              Column() {
                this.mobileChannelBrowser()
              }
              .layoutWeight(1)
              .height('100%')
            }
            .width('100%')
            .height('100%')
          } else {
            this.roomDetailPane()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.mobileBottomBarInset() > 0) {
        BottomBar({
          active: this.mobilePane === 'account' ? 'account' : 'voice',
          showMiniBar: false,
          onNavigate: (tab: string) => { this.switchMobileTab(tab); },
          onReturnRoom: () => { this.jumpToActiveRoom(); }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(getTheme(this.isDark).bg)
  }

  build() {
    Stack() {
      Column() {
        if (this.isPc) {
          this.desktopShell()
        } else if (this.areaAdminOpen) {
          this.adminPanel()
        } else {
          this.mobileShell()
        }
      }.width('100%').height('100%')
        .enabled(!this.hasChatAction())
        .accessibilityLevel(this.hasChatAction() ? 'no-hide-descendants' : 'auto')
      if (this.previewImage !== undefined) {
        ChatImagePreview({
          imageUrl: this.previewImage.url, imageName: this.previewImage.displayName || '图片',
          isDesktop: this.isPc, onClose: () => { this.closeChatAction(); }
        })
      } else if (this.actionItem !== undefined) {
        ChatMessageActions({
          item: this.actionItem, isDark: this.isDark, isDesktop: this.isPc,
          windowX: this.menuX, windowY: this.menuY, confirming: this.recallConfirming, busy: this.recallBusy,
          onDismiss: () => { this.closeChatAction(); },
          onReply: () => { this.chooseChatReply(); },
          onCopy: () => { this.copyChatMessage(); },
          onChooseRecall: () => { this.recallConfirming = true; },
          onSubmit: () => { this.submitChatRecall(); }
        })
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ESCAPE || !this.hasChatAction()) return false;
      if (!this.recallBusy) this.closeChatAction();
      return true;
    })
    .onAreaChange((_oldVal: Area, newVal: Area) => {
      const w = parseFloat(String(newVal.width));
      if (w > 0 && Math.abs(w - this.pageWidth) >= 2) {
        if (this.isPc && this.isWide() && w < PC_CHANNEL_BREAKPOINT_VP) {
          this.mobilePane = this.selectedChannelObj !== undefined ? 'room' : 'channels';
        }
        this.pageWidth = w;
      }
    })
  }
}
