import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { AVInputCastPicker, AVCastPickerState } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PRODUCT_NAME } from 'BuildProfile';
import type { AudioVolumeInfo, NativeRtcCall, RtcCallEvents, RtcRoom } from '../voice/NativeRtcCall';
import type {
  OopzArea, OopzChannelMember, OopzChatAttachment, OopzChatMessage, OopzPersonInfo, OopzVoiceChannel
} from '../oopz/OopzSession';
import { rsaEncryptPassword, rsaSignBase64 } from '../oopz/OopzCrypto';
import { ensureOopzEmojiFont, OOPZ_EMOJI_FONT_FAMILY } from '../oopz/OopzEmojiFont';
import { extractAppId } from '../oopz/OopzToken';
import { OOPZ_TEST_TOKEN, OOPZ_TEST_APPID } from '../oopz/OopzKeyMaterial';
import { AppStore, DEFAULT_MIC_GAIN, MAX_MEMBER_GAIN, MAX_MIC_GAIN } from '../store/AppStore';
import { AccountPanel } from '../components/AccountPanel';
import { BottomBar } from '../components/BottomBar';
import { ChatEmojiPicker } from '../components/ChatEmojiPicker';
import { VoiceGainSlider } from '../components/VoiceGainSlider';
import { VoiceOutputPicker } from '../components/VoiceDevices';
import { AppSpacing, getTheme, nativePopupMaterial } from '../common/Theme';
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
const SPEAK_HOLD_MS = 440;
const REMOTE_SPEECH_MIN_VOLUME = 24;
const REMOTE_SPEECH_SAMPLE_WINDOW_MS = 360;
const INITIAL_PEER_SYNC_MS = 1600;

type MobilePane = 'channels' | 'room' | 'account';

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
  return channel.isText && channel.name === '主页' && channel.group.length === 0;
}

interface ChatMessageItem {
  key: string;
  messageId: string;
  senderUid: string;
  senderName: string;
  senderAvatar: string;
  isSelf: boolean;
  timeText: string;
  cleanText: string;
  textRuns: ChatTextRun[];
  attachments: OopzChatAttachment[];
}

interface ChatTextRun {
  text: string;
  oopzEmoji: boolean;
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

@Component
struct ChatMessageRow {
  @Prop item: ChatMessageItem;
  @Prop isDark: boolean = true;
  @Prop oopzEmojiFontReady: boolean = false;

  build() {
    Row({ space: 10 }) {
      Stack() {
        Column() {
          Text(this.item.senderName.length > 0 ? this.item.senderName.slice(0, 1).toUpperCase() : 'U')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(getTheme(this.isDark).accent)
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .justifyContent(FlexAlign.Center)

        if (this.item.senderAvatar.length > 0) {
          Image(this.item.senderAvatar)
            .width(34)
            .height(34)
            .borderRadius(17)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(34)
      .height(34)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.item.senderName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.item.isSelf ? getTheme(this.isDark).accent : getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.item.timeText)
            .fontSize(11)
            .fontColor(getTheme(this.isDark).textMuted)
        }

        if (this.item.cleanText.length > 0) {
          Text() {
            if (this.item.textRuns.length === 0) {
              Span(this.item.cleanText)
            } else {
              ForEach(this.item.textRuns, (run: ChatTextRun) => {
                if (run.oopzEmoji && this.oopzEmojiFontReady) {
                  Span(run.text).fontFamily(OOPZ_EMOJI_FONT_FAMILY).fontSize(21)
                } else {
                  Span(run.oopzEmoji ? '[表情]' : run.text).fontSize(14)
                }
              }, (run: ChatTextRun, index: number) => `${index}-${run.text}-${this.oopzEmojiFontReady}`)
            }
          }
            .fontSize(14)
            .fontColor(getTheme(this.isDark).text)
            .lineHeight(this.item.textRuns.length > 0 ? 27 : 20)
            .copyOption(CopyOptions.InApp)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(AppSpacing.radiusSm)
            .backgroundColor(this.item.isSelf ? getTheme(this.isDark).tint : getTheme(this.isDark).surface)
            .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
        }

        if (this.item.attachments.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.item.attachments, (att: OopzChatAttachment, idx: number) => {
              Image(att.url)
                .constraintSize({ maxWidth: 260, maxHeight: 200 })
                .borderRadius(12)
                .objectFit(ImageFit.Cover)
                .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
            }, (att: OopzChatAttachment, idx: number) => `${att.fileKey}_${idx}_${att.url}`)
          }
          .alignItems(HorizontalAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 4, bottom: 4 })
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
  private captionWindow?: window.Window;
  private originalCaptionHeight: number = PC_CAPTION_HEIGHT;
  private captionObserverAttached: boolean = false;
  private readonly voiceTask: VoiceBackgroundTest = new VoiceBackgroundTest();
  private readonly voiceRoute: VoiceAudioRoute = new VoiceAudioRoute();
  private observingCancellation: boolean = false;
  private activePage: boolean = false;
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
    this.store.setChatListener((channelId: string) => {
      if (channelId === this.selectedChannelId) {
        this.syncChatMessages(true);
      }
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
    this.restoreDesktopCaption();
    this.activePage = false;
    this.store.setGripInteractionActive('voice-input-menu', false);
    this.store.setGripInteractionActive('voice-input-picker', false);
    this.store.setGripInteractionActive('voice-output-picker', false);
    this.store.setGripInteractionActive('voice-emoji', false);
    this.store.setPresenceListener(undefined);
    this.store.setChatListener(undefined);
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
    if (this.emojiPickerOpen) {
      this.emojiPickerOpen = false;
      return true;
    }
    if (this.mediaInputMenuOpen) {
      this.setMediaInputMenuOpen(false);
      return true;
    }
    if (this.showMicGain) {
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
      if (isDomainHome(channel)) {
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
    if (advanceMobile) this.mobilePane = 'channels';
    this.selectedAreaId = areaId;
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
    const areaId = this.selectedAreaId;
    const ch = this.selectedChannelObj;
    if (areaId.length === 0 || ch === undefined || ch.type !== 'TEXT' || this.loadingChat) {
      return;
    }
    this.loadingChat = true;
    try {
      await this.store.loadChannelMessages(areaId, ch.channelId, before);
      if (this.selectedChannelId === ch.channelId) {
        this.syncChatMessages(before === undefined);
      }
    } catch (error) {
      this.notice = (error as Error).message;
    } finally {
      this.loadingChat = false;
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

  private async sendChatMessage(): Promise<void> {
    const ch = this.selectedChannelObj;
    const areaId = this.selectedAreaId;
    const text = this.chatInput.trim();
    if (this.sendingChat || text.length === 0 || areaId.length === 0 || ch === undefined || ch.type !== 'TEXT') {
      return;
    }
    this.sendingChat = true;
    this.notice = '';
    try {
      await this.store.sendChannelMessage(areaId, ch.channelId, text);
      this.chatInput = '';
      this.syncChatMessages(true);
    } catch (error) {
      this.notice = (error as Error).message;
    } finally {
      this.sendingChat = false;
    }
  }

  private syncChatMessages(scrollToBottom: boolean = false): void {
    const chId = this.selectedChannelId;
    if (chId.length === 0) {
      this.chatMessages = [];
      return;
    }
    const selfUid = this.store.session.getCred()?.personUid ?? '';
    const rawList: OopzChatMessage[] = this.store.messagesByChannel.get(chId) ?? [];
    const items: ChatMessageItem[] = [];
    for (let i = 0; i < rawList.length; i++) {
      const m = rawList[i];
      const person = this.store.getPersonByUid(m.senderUid) ??
        (m.senderUid === selfUid ? this.store.selfProfile : undefined);
      const senderName = person !== undefined ? person.name : (m.senderUid.length > 0 ? m.senderUid.slice(0, 6) : '成员');
      const senderAvatar = person !== undefined ? person.avatar : '';
      const key = m.messageId.length > 0 ? m.messageId : (m.clientMessageId.length > 0 ? m.clientMessageId : `idx_${i}`);
      const cleanText = cleanChatContent(m.content, m.attachments.length > 0);
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
        attachments: m.attachments
      });
    }
    this.chatMessages = items;
    if (items.some((item: ChatMessageItem) => item.textRuns.length > 0)) this.loadOopzEmojiFont();
    if (scrollToBottom && items.length > 0) {
      setTimeout(() => {
        try {
          this.chatScroller.scrollToIndex(items.length - 1, false, ScrollAlign.END);
        } catch {
          // ignore if not attached yet
        }
      }, 60);
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
    if (this.selectedAreaId !== this.callAreaId) {
      await this.selectArea(this.callAreaId, false);
    }
    this.selectedChannelId = this.callChannelId;
    this.mobilePane = 'room';
    this.syncViewModels();
  }

  private syncViewModels(): void {
    this.selectedAreaObj = this.areas.find((a: OopzArea): boolean => a.areaId === this.selectedAreaId);
    const channels = this.store.channelsByArea.get(this.selectedAreaId) ?? [];
    this.selectedChannelObj = channels.find((c: OopzVoiceChannel): boolean => c.channelId === this.selectedChannelId);

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
    PcTrayManager.get().updateTrayState(inCall, channelLabel, this.muted);
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
      this.voiceRoute.begin(context, (status: VoiceRouteStatus) => { this.updateVoiceRoute(status); });
      this.joinTimer = setTimeout(() => { this.leave('进房超时，请检查网络连接'); }, 20000);
      await this.voiceRoute.activateMixing();
      if (!this.activePage || generation !== this.joinGeneration) return;
      rtc.start(context, room, this.callEvents(), true, this.micGain);
    } catch (error) {
      if (generation !== this.joinGeneration) {
        return;
      }
      const message = (error as Error).message;
      const known = /^(启用原生音频失败|原生 SDK 拒绝进房)（-?\d+）$/.test(message);
      await this.leave(known ? message : '无法加入语音频道');
    }
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
        this.maybeStartTask();
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
  private desktopMoreMenu() {
    Menu() {
      MenuItem({ content: '最小化到托盘' })
        .onClick(() => { PcTrayManager.get().minimizeToTray(); })
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
          SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(19).fontColor([getTheme(this.isDark).textSecondary])
        }
        .width(36)
        .height(34)
        .borderRadius(8)
        .backgroundColor(Color.Transparent)
        .accessibilityText('更多操作')
        .hoverEffect(HoverEffect.Highlight)
        .bindMenu(this.desktopMoreMenu())
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
    .onClick(() => { this.desktopPane = settings ? 'settings' : 'account'; })
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

  @Builder
  private desktopChannelPane() {
    Column({ space: 8 }) {
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
        .width(35)
        .height(42)
        .padding(0)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.muted ? '麦克风已闭麦，点击打开' : '麦克风，点击闭麦')
        .enabled(this.state === CallState.CONNECTED || this.state === CallState.RECONNECTING)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => { this.toggleMicrophone(); })
        Divider().vertical(true).height(15).color(getTheme(this.isDark).borderSubtle)
        this.inputDevicePicker()
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
  private mobileCallBar() {
    Column({ space: 4 }) {
      if (this.showMicGain) {
        this.microphoneGainPanel()
      }
      Row({ space: 5 }) {
        this.desktopCallSummary()
      }
      .width('100%')
      this.callActions(true)
    }
    .width('calc(100% - 20vp)')
    .padding({ left: 8, right: 8, top: 2, bottom: 6 })
    .margin({ top: 4, bottom: 4 })
    .borderRadius(AppSpacing.radius)
    .backgroundColor(getTheme(this.isDark).surfaceSolid)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .clip(true)
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
    }
    .width('100%')
    .height(50)
    .padding({ left: 12, right: 10, top: 6, bottom: 6 })
    .backgroundColor(getTheme(this.isDark).bg)
  }

  @Builder
  private mobileDomainRail() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.areas, (area: OopzArea) => {
          Button({ type: ButtonType.Normal }) {
            if (area.avatar.length > 0) {
              Image(area.avatar).width(34).height(34).borderRadius(AppSpacing.radiusSm)
                .clip(true).objectFit(ImageFit.Cover)
            } else {
              Text(area.name.slice(0, 1)).fontSize(17).fontColor(getTheme(this.isDark).text)
            }
          }
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(area.areaId === this.selectedAreaId ? getTheme(this.isDark).accentSoft :
            getTheme(this.isDark).surfaceAlt)
          .border({ width: 1, color: area.areaId === this.selectedAreaId ? getTheme(this.isDark).accent :
            Color.Transparent, radius: AppSpacing.radius })
          .accessibilityText(area.name)
          .onClick(() => { this.selectArea(area.areaId); })
        }, (area: OopzArea) => area.areaId)
      }
      .width('100%')
      .padding({ top: 8, bottom: 10 })
    }
    .scrollBar(BarState.Off)
    .width(56)
    .height('100%')
    .backgroundColor(getTheme(this.isDark).rail)
    .borderRadius({ topRight: AppSpacing.radius, bottomRight: AppSpacing.radius })
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
          SymbolGlyph(isDomainHome(channel) ? $r('sys.symbol.house') :
            (channel.isText ? $r('sys.symbol.message') : $r('sys.symbol.mic')))
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
      ? getTheme(this.isDark).accentSoft : (isDomainHome(channel) ? getTheme(this.isDark).surfaceAlt : Color.Transparent))

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
      .padding({ left: 8, right: 8, top: 8, bottom: 12 })
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
        List({ scroller: this.chatScroller, space: 8 }) {
          ForEach(this.chatMessages, (msg: ChatMessageItem) => {
            ListItem() {
              ChatMessageRow({ item: msg, isDark: this.isDark, oopzEmojiFontReady: this.oopzEmojiFontReady })
            }
          }, (msg: ChatMessageItem) => `${msg.key}_${this.isDark ? 1 : 0}_${msg.textRuns.length > 0 && this.oopzEmojiFontReady}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 4, right: 4, top: 4, bottom: 4 })
      }

      if (this.notice.length > 0) {
        Text(this.notice).fontSize(12).fontColor(getTheme(this.isDark).warn)
      }

      // Composer input bar positioned cleanly above BottomBar
      Row({ space: 8 }) {
        TextInput({
          placeholder: `发消息到 #${this.selectedChannelObj?.name ?? '频道'}`,
          text: this.chatInput
        })
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

        Button(this.sendingChat ? '发送中' : '发送')
          .height(42)
          .padding({ left: 16, right: 16 })
          .borderRadius(14)
          .backgroundColor(getTheme(this.isDark).accent)
          .fontColor(getTheme(this.isDark).accentText)
          .fontWeight(FontWeight.Medium)
          .enabled(!this.sendingChat && this.chatInput.trim().length > 0)
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
      .padding({ left: 16, right: 16, top: this.isPc ? 0 : 16, bottom: 12 })
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
            if (this.desktopPane !== 'room') {
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
    Stack() {
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
            AccountPanel({ embedded: true, onClose: () => { this.backToParent(); } })
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

        if (this.isInCall()) {
          this.mobileCallBar()
        }
        BottomBar({
          active: this.mobilePane === 'account' ? 'account' : 'voice',
          showMiniBar: false,
          onNavigate: (tab: string) => { this.switchMobileTab(tab); },
          onReturnRoom: () => { this.jumpToActiveRoom(); }
        })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(getTheme(this.isDark).bg)
  }

  build() {
    Column() {
      if (this.isPc) {
        this.desktopShell()
      } else {
        this.mobileShell()
      }
    }
    .width('100%')
    .height('100%')
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
