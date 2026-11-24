import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AUDIO_LAB_TAG, LocalVoiceCall } from '../voice/LocalVoiceCall';
import { VoiceBackgroundTest } from '../voice/VoiceBackgroundTest';
import { VoiceAudioRoute, VoiceRouteStatus, volumeLabel } from '../voice/VoiceAudioRoute';
import { VoiceMicStatus, VoiceOutputPicker } from '../components/VoiceDevices';
import { VoiceGainSlider } from '../components/VoiceGainSlider';
import { AppStore, DEFAULT_MIC_GAIN, MAX_MIC_GAIN, MAX_MEMBER_GAIN } from '../store/AppStore';
import { getTheme } from '../common/Theme';

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';

@Entry
@Component
struct AudioLab {
  @State private notice: string = '等待开始';
  @State private busy: boolean = false;
  @State private connected: boolean = false;
  @State private routeStatus: VoiceRouteStatus = new VoiceRouteStatus();
  @State private peerGain: number = DEFAULT_MIC_GAIN;
  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzMicGain') private micGain: number = DEFAULT_MIC_GAIN;
  @StorageProp('oopzGripSupported') private gripSupported: boolean = false;
  private active = false;
  private hiddenAt = 0;
  private failure = '';
  private call?: LocalVoiceCall;
  private readonly task = new VoiceBackgroundTest();
  private readonly route = new VoiceAudioRoute();
  private readonly store = AppStore.get();
  private readonly onTaskCancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.task.matchesTask(info.id)) {
      this.task.taskEnded();
      this.disconnect('通话后台任务已取消');
    }
  };

  aboutToAppear(): void {
    this.active = true;
    const context = this.context();
    if (context !== undefined) this.store.loadUiPrefs(context);
    if (deviceInfo.apiAvailable(15)) {
      backgroundTaskManager.on('continuousTaskCancel', this.onTaskCancelled);
    }
  }

  aboutToDisappear(): void {
    this.active = false;
    if (deviceInfo.apiAvailable(15)) {
      backgroundTaskManager.off('continuousTaskCancel', this.onTaskCancelled);
    }
    if (!this.busy) {
      this.disconnect('通话已结束');
    }
  }

  onPageHide(): void {
    this.hiddenAt = Date.now();
    hilog.info(0x0, AUDIO_LAB_TAG, 'Native background task=%{public}d', this.task.isRunning() ? 1 : 0);
  }

  onPageShow(): void {
    if (this.hiddenAt > 0) {
      hilog.info(0x0, AUDIO_LAB_TAG, 'Native foreground afterMs=%{public}d', Date.now() - this.hiddenAt);
      this.hiddenAt = 0;
      this.route.refresh();
      const context = this.context();
      if (context && this.task.isRunning()) {
        this.task.inspect(context).then((state) => {
          hilog.info(0x0, AUDIO_LAB_TAG, 'Native task state after return=%{public}d', state ?? -1);
        }).catch((error: BusinessError) => {
          hilog.warn(0x0, AUDIO_LAB_TAG, 'Task inspection failed code=%{public}d', error.code);
        });
      }
    }
  }

  private context(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private async connect(): Promise<void> {
    const context = this.context();
    if (!context || this.busy || this.connected) {
      return;
    }
    this.busy = true;
    this.failure = '';
    this.notice = '正在连接本机对端';
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MICROPHONE]);
      if (result.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.notice = '需要麦克风权限';
        return;
      }
      if (!this.active) {
        return;
      }
      const call = new LocalVoiceCall((message: string) => {
        this.failure = message;
        if (!this.busy) {
          this.disconnect(message);
        }
      });
      this.call = call;
      this.route.begin(context, (status: VoiceRouteStatus) => { this.routeStatus = status; });
      call.setGains(this.micGain, this.peerGain);
      await call.start();
      if (!this.active || this.failure) {
        await this.disconnect(this.failure || '通话已结束');
        return;
      }
      this.route.activate(false, () => { this.disconnect('通话已结束'); });
      this.route.refresh();
      await this.task.startCall(context, this.routeStatus, true, () => this.active && this.hiddenAt === 0);
      if (!this.active || this.failure) {
        await this.disconnect(this.failure || '通话已结束');
        return;
      }
      this.connected = true;
      this.notice = '双向音频已启动，后台任务已开启';
      hilog.info(0x0, AUDIO_LAB_TAG, 'Native call ready');
    } catch (error) {
      const detail = error as BusinessError;
      hilog.error(0x0, AUDIO_LAB_TAG, 'Native call start failed code=%{public}d message=%{public}s',
        detail.code ?? -1, detail.message);
      await this.disconnect('连接失败 ' + (detail.code ?? detail.message));
    } finally {
      this.busy = false;
    }
  }

  private async disconnect(message: string): Promise<void> {
    const call = this.call;
    this.call = undefined;
    this.connected = false;
    this.busy = true;
    if (call) {
      await call.close();
    }
    await this.route.close();
    this.routeStatus = new VoiceRouteStatus();
    const context = this.context();
    if (context && this.task.isRunning()) {
      try {
        await this.task.stop(context);
      } catch (error) {
        hilog.warn(0x0, AUDIO_LAB_TAG, 'Task stop failed code=%{public}d', (error as BusinessError).code);
        await this.task.taskEnded();
      }
    }
    this.notice = message;
    this.busy = false;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('后台语音调试').fontSize(24).fontColor(getTheme(this.isDark).text)
        Text('采集的音频只送往电脑本机的测试对端。').fontSize(14).fontColor(getTheme(this.isDark).textMuted)
        Text(this.notice).fontSize(16).fontColor(getTheme(this.isDark).text)
        Text(this.gripSupported ? '智感握姿可用' : '智感握姿使用居中回退')
          .fontSize(12).fontColor(getTheme(this.isDark).textMuted)
        VoiceMicStatus({
          capturing: this.connected,
          isDark: this.isDark,
          input: this.routeStatus.input,
          output: this.routeStatus.output
        })
        Row({ space: 8 }) {
          VoiceOutputPicker({
            label: this.routeStatus.output,
            isDark: this.isDark,
            compact: true,
            sessionType: this.routeStatus.pickerType ?? '',
            onRefresh: () => { this.route.refresh(); }
          })
          Text(volumeLabel(this.routeStatus.usage)).fontSize(13).fontColor(getTheme(this.isDark).text)
          Blank()
          Button(this.connected ? '结束双向测试' : '开始双向测试')
            .enabled(!this.busy)
            .onClick(() => {
              if (this.connected) {
                this.disconnect('通话已结束');
              } else {
                this.connect();
              }
            })
        }
        .width('100%')
        VoiceGainSlider({
          label: '麦克风发送音量',
          value: this.micGain,
          max: MAX_MIC_GAIN,
          isDark: this.isDark,
          onGainChange: (gain: number, commit: boolean) => {
            this.store.setMicGain(this.context(), gain, commit);
            this.call?.setGains(gain, this.peerGain);
          }
        })
        VoiceGainSlider({
          label: '成员播放音量',
          value: this.peerGain,
          max: MAX_MEMBER_GAIN,
          isDark: this.isDark,
          onGainChange: (gain: number, _commit: boolean) => {
            this.peerGain = gain;
            this.call?.setGains(this.micGain, gain);
          }
        })
      }
      .width('100%')
      .padding(16)
    }
    .height('100%')
    .width('100%')
    .align(Alignment.Top)
    .backgroundColor(getTheme(this.isDark).bg)
  }
}
