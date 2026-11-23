import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStore, DEFAULT_MIC_GAIN, MAX_MIC_GAIN } from '../store/AppStore';
import { AppSpacing, getTheme } from '../common/Theme';
import { VoiceMode, voiceModeLabel } from '../common/VoiceMode';
import { PcTrayManager } from '../desktop/PcTrayManager';
import { VoiceGainSlider } from './VoiceGainSlider';

const TAG = 'OopzAccount';

@Component
export struct AccountPanel {
  @Prop embedded: boolean = false;
  @Prop settingsFirst: boolean = false;
  @Prop bottomInset: number = 0;
  onClose: () => void = () => {};
  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzThemeMode') private themeMode: string = 'system';
  @StorageProp('oopzVoiceMode') private voiceMode: VoiceMode = 'standard';
  @StorageProp('oopzIsPc') private isPc: boolean = false;
  @StorageProp('oopzTrayOnClose') private trayOnClose: boolean = true;

  @StorageProp('oopzAccountUid') private uid: string = '';
  @StorageProp('oopzDeviceId') private deviceId: string = '';
  @StorageProp('oopzSelfName') private selfName: string = '';
  @StorageProp('oopzSelfAvatar') private selfAvatar: string = '';
  @StorageProp('oopzSelfPid') private selfPid: string = '';
  @StorageProp('oopzSelfGreeting') private selfGreeting: string = '';
  @StorageProp('oopzWsConnected') private wsConnected: boolean = false;
  @StorageProp('oopzMicCue') private micCue: boolean = false;
  @StorageProp('oopzPeerCue') private peerCue: boolean = true;
  @StorageProp('oopzInCall') private inCall: boolean = false;
  @StorageProp('oopzCallAreaName') private callAreaName: string = '';
  @StorageProp('oopzCallChannelName') private callChannelName: string = '';
  @StorageProp('oopzCallPeers') private callPeers: number = 0;
  @StorageProp('oopzCallRates') private callRates: string = '';
  @StorageProp('oopzTaskStatus') private taskStatus: string = '';
  @StorageProp('oopzSdkVersion') private sdkVersion: string = '';
  @StorageProp('oopzGripEnabled') private gripEnabled: boolean = true;
  @StorageProp('oopzGripSupported') private gripSupported: boolean = false;
  @StorageProp('oopzMicGain') private micGain: number = DEFAULT_MIC_GAIN;
  @StorageProp('oopzCallVolumeType') private volumeType: string = '';
  @StorageProp('oopzCallInput') private callInput: string = '';
  @StorageProp('oopzCallOutput') private callOutput: string = '';
  @StorageProp('oopzActiveVoiceMode') private activeVoiceMode: VoiceMode | '' = '';
  @StorageProp('oopzCallProcessing') private callProcessing: string = '';
  @StorageProp('oopzCallAecSupport') private callAecSupport: string = '';

  @State private notice: string = '';
  @State private busy: boolean = false;
  @State private appVersion: string = '';
  private readonly store: AppStore = AppStore.get();

  aboutToAppear(): void {
    try {
      this.appVersion = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
        .versionName;
    } catch {
      hilog.warn(0x0, TAG, 'Unable to read the app version');
    }
    this.ensureLoaded();
  }

  private context(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private async ensureLoaded(): Promise<void> {
    const ctx = this.context();
    if (ctx !== undefined) {
      this.store.bind(ctx);
      await this.store.loadUiPrefs(ctx);
    }
    try {
      if (!this.store.session.isSignedIn()) {
        await this.store.restore();
      }
      if (this.store.session.isSignedIn() && this.selfName.length === 0) {
        await this.store.loadSelfProfile();
      }
    } catch {
      hilog.warn(0x0, TAG, 'ensureLoaded failed');
    }
  }

  private setTheme(mode: string): void {
    this.store.setThemeMode(this.context(), mode);
    const label = mode === 'light' ? '浅色模式' : (mode === 'dark' ? '深色模式' : '跟随系统');
    this.notice = `外观已切换为：${label}`;
  }

  private async clearSession(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const router = this.getUIContext().getRouter();
      await this.store.logout();
      this.notice = '已退出当前账号';
      router.clear();
      router.replaceUrl({ url: 'pages/Login' }).catch(() => {});
    } catch {
      this.notice = '退出失败，请重试';
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private themeOption(label: string, mode: string) {
    Button(label)
      .height(32)
      .padding({ left: 12, right: 12 })
      .fontSize(12)
      .borderRadius(AppSpacing.radiusSm)
      .backgroundColor(this.themeMode === mode ? getTheme(this.isDark).accent : getTheme(this.isDark).surfaceAlt)
      .fontColor(this.themeMode === mode ? getTheme(this.isDark).accentText : getTheme(this.isDark).textSecondary)
      .fontWeight(this.themeMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .onClick(() => { this.setTheme(mode); })
  }

  @Builder
  private voiceModeOption(mode: VoiceMode) {
    Button(voiceModeLabel(mode))
      .height(32)
      .padding({ left: 12, right: 12 })
      .fontSize(12)
      .borderRadius(AppSpacing.radiusSm)
      .backgroundColor(this.voiceMode === mode ? getTheme(this.isDark).accent : getTheme(this.isDark).surfaceAlt)
      .fontColor(this.voiceMode === mode ? getTheme(this.isDark).accentText : getTheme(this.isDark).textSecondary)
      .fontWeight(this.voiceMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .accessibilityText(this.voiceMode === mode ? voiceModeLabel(mode) + '，已选中' : voiceModeLabel(mode))
      .onClick(() => { this.store.setVoiceMode(this.context(), mode); })
  }

  @Builder
  private row(label: string, value: string, highlight: boolean = false) {
    Row() {
      Text(label).fontSize(13).fontColor(getTheme(this.isDark).textMuted).width(108)
      Text(value.length > 0 ? value : '—')
        .fontSize(13)
        .fontColor(highlight ? getTheme(this.isDark).accent : getTheme(this.isDark).text)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private profileCard() {
    Row({ space: 14 }) {
      Stack() {
        Column() {
          Text(this.selfName.length > 0 ? this.selfName.slice(0, 1).toUpperCase() : 'O')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(getTheme(this.isDark).accent)
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .justifyContent(FlexAlign.Center)

        if (this.selfAvatar.length > 0) {
          Image(this.selfAvatar)
            .width(56)
            .height(56)
            .borderRadius(28)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(56)
      .height(56)

      Column({ space: 4 }) {
        Text(this.selfName.length > 0 ? this.selfName : 'Oopz 用户')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(getTheme(this.isDark).text)
        Text(this.selfPid.length > 0 ? `Oopz ID · ${this.selfPid}` : '已登录原生会话')
          .fontSize(12)
          .fontColor(getTheme(this.isDark).accent)
        if (this.selfGreeting.length > 0) {
          Text(this.selfGreeting)
            .fontSize(12)
            .fontColor(getTheme(this.isDark).textSecondary)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(AppSpacing.card)
    .backgroundColor(getTheme(this.isDark).surface)
    .borderRadius(AppSpacing.radiusLg)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private appearanceOptions() {
    Column({ space: 12 }) {
      Text('外观与交互').fontSize(13).fontColor(getTheme(this.isDark).textMuted)

      Column({ space: 8 }) {
        Text('主题模式').fontSize(14).fontColor(getTheme(this.isDark).text)
        Row({ space: 6 }) {
          this.themeOption('跟随系统', 'system')
          this.themeOption('浅色', 'light')
          this.themeOption('深色', 'dark')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        Text('通话模式').fontSize(14).fontColor(getTheme(this.isDark).text)
        Row({ space: 6 }) {
          this.voiceModeOption('standard')
          this.voiceModeOption('native-voip')
        }
        Text('本机保存，下次进入语音生效').fontSize(11).fontColor(getTheme(this.isDark).textMuted)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      VoiceGainSlider({
        label: '麦克风发送音量',
        value: this.micGain,
        max: MAX_MIC_GAIN,
        isDark: this.isDark,
        onGainChange: (gain: number, commit: boolean) => { this.store.setMicGain(this.context(), gain, commit); }
      })

      Row({ space: 12 }) {
        Text('开关麦克风提示音').layoutWeight(1).fontSize(14).fontColor(getTheme(this.isDark).text)
        Toggle({ type: ToggleType.Switch, isOn: this.micCue })
          .accessibilityText('开关麦克风提示音')
          .selectedColor(getTheme(this.isDark).accent)
          .onChange((enabled: boolean) => { this.store.setMicCue(this.context(), enabled); })
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('成员进出提示音').layoutWeight(1).fontSize(14).fontColor(getTheme(this.isDark).text)
        Toggle({ type: ToggleType.Switch, isOn: this.peerCue })
          .accessibilityText('成员进出提示音')
          .selectedColor(getTheme(this.isDark).accent)
          .onChange((enabled: boolean) => { this.store.setPeerCue(this.context(), enabled); })
      }
      .width('100%')

      if (!this.isPc) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text('智感握姿').fontSize(14).fontColor(getTheme(this.isDark).text)
            Text(this.gripSupported ? '底部导航跟随左手或右手握持' : '当前设备使用居中导航')
              .fontSize(11)
              .fontColor(getTheme(this.isDark).textMuted)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.gripEnabled && this.gripSupported })
            .selectedColor(getTheme(this.isDark).accent)
            .accessibilityText('智感握姿')
            .enabled(this.gripSupported)
            .onChange((isOn: boolean) => { this.store.setGripEnabled(this.context(), isOn); })
        }
        .width('100%')
      }

      if (this.isPc) {
        Row() {
          Column({ space: 2 }) {
            Text('关闭窗口时最小化到托盘').fontSize(14).fontColor(getTheme(this.isDark).text)
            Text('保持语音连接与实时消息推送不断开').fontSize(11).fontColor(getTheme(this.isDark).textMuted)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.trayOnClose })
            .selectedColor(getTheme(this.isDark).accent)
            .onChange((isOn: boolean) => {
              this.store.setTrayOnClose(this.context(), isOn);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(AppSpacing.card)
    .backgroundColor(getTheme(this.isDark).surface)
    .borderRadius(AppSpacing.radiusLg)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private connectionStatus() {
    Column({ space: 4 }) {
      Text('连接状态').fontSize(13).fontColor(getTheme(this.isDark).textMuted).margin({ bottom: 4 })
      this.row('实时通道', this.wsConnected ? '已连接' : '连接中', this.wsConnected)
      this.row('语音引擎', this.sdkVersion.length > 0 ? `v${this.sdkVersion} 就绪` : '仅文字与浏览模式')
      this.row('当前通话',
        this.inCall ? `${this.callAreaName} / ${this.callChannelName}（远端 ${this.callPeers} 人）` : '未在语音中',
        this.inCall)
      this.row('通话码率', this.callRates)
      if (this.inCall) {
        this.row('实际通话模式', this.activeVoiceMode === '' ? '正在连接' : voiceModeLabel(this.activeVoiceMode))
        this.row('当前麦克风', this.callInput || '等待识别')
        this.row('声音输出', this.callOutput || '由系统选择')
        this.row('系统音量', this.volumeType || '等待播放流')
        if (this.activeVoiceMode !== '') {
          this.row('系统通话处理', this.callProcessing)
        }
        if (this.activeVoiceMode === 'native-voip') {
          this.row('回声消除能力', this.callAecSupport)
          Text('系统按设备与路由管理回声消除、降噪和自动增益。')
            .fontSize(11)
            .fontColor(getTheme(this.isDark).textMuted)
        }
      }
      this.row('后台语音保活', this.taskStatus.length > 0 ? this.taskStatus : '待命')
      this.row('账号 ID', this.selfPid.length > 0 ? this.selfPid : this.uid)
      this.row('应用版本', this.appVersion)
    }
    .width('100%')
    .padding(AppSpacing.card)
    .backgroundColor(getTheme(this.isDark).surface)
    .borderRadius(AppSpacing.radiusLg)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private securityOptions() {
    Column({ space: 10 }) {
      Text('账号与安全').fontSize(13).fontColor(getTheme(this.isDark).textMuted)
      Text('会话凭据使用系统 Asset Store 加密保管。退出后会立即离开语音频道并清除本地登录态。')
        .fontSize(12)
        .fontColor(getTheme(this.isDark).textSecondary)
      Button(this.busy ? '正在退出…' : '退出登录')
        .width('100%')
        .height(44)
        .borderRadius(AppSpacing.radiusSm)
        .backgroundColor(getTheme(this.isDark).dangerFill)
        .fontColor(getTheme(this.isDark).dangerText)
        .fontWeight(FontWeight.Medium)
        .enabled(!this.busy)
        .onClick(() => { this.clearSession(); })
    }
    .width('100%')
    .padding(AppSpacing.card)
    .backgroundColor(getTheme(this.isDark).surface)
    .borderRadius(AppSpacing.radiusLg)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: AppSpacing.gap }) {
        Row({ space: 10 }) {
          if (this.embedded) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(16)
                .fontColor([getTheme(this.isDark).text])
            }
            .width(36)
            .height(36)
            .accessibilityText('返回频道')
            .backgroundColor(getTheme(this.isDark).surfaceAlt)
            .hoverEffect(HoverEffect.Highlight)
            .onClick(() => { this.onClose(); })
          }
          Text(this.settingsFirst ? '设置' : '我的')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(getTheme(this.isDark).text)
          Blank()
          if (this.isPc && !this.embedded) {
            Button('最小化到托盘')
              .height(34)
              .fontSize(12)
              .backgroundColor(getTheme(this.isDark).surfaceAlt)
              .fontColor(getTheme(this.isDark).textSecondary)
              .onClick(() => { PcTrayManager.get().minimizeToTray(); })
          }
        }
        .width('100%')

        if (this.settingsFirst) {
          this.appearanceOptions()
        }
        this.profileCard()
        if (!this.settingsFirst) {
          this.appearanceOptions()
        }
        this.connectionStatus()
        this.securityOptions()

        if (this.notice.length > 0) {
          Text(this.notice).fontSize(13).fontColor(getTheme(this.isDark).accent)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 620 })
      .padding({ top: 20, bottom: 20 + this.bottomInset,
        left: AppSpacing.page, right: AppSpacing.page })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(getTheme(this.isDark).bg)
  }
}
