import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeWebMicrophone } from '../voice/NativeWebMicrophone';
import { VoiceBackgroundTest } from '../voice/VoiceBackgroundTest';
import { NATIVE_WEB_MICROPHONE_SCRIPT } from '../web/NativeWebMicrophoneScript';

const ORIGIN = 'http://127.0.0.1:28691';
const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';
const TAG = 'OopzWebAudioLab';

@Entry
@Component
struct WebAudioLab {
  @StorageProp('oopzWebLabMode') mode: string = 'web-standard';
  @StorageProp('oopzWebLabQuiet') quiet: boolean = false;
  @State private notice: string = '正在加载本机测试网页';
  @State private ready: boolean = false;
  @State private running: boolean = false;
  @State private busy: boolean = false;
  private readonly controller = new webview.WebviewController();
  private bridge?: NativeWebMicrophone;
  private task?: VoiceBackgroundTest;
  private permissionPending = false;
  private playing = false;
  private hiddenAt = 0;
  private resumeTimer = -1;
  private microphone?: MicrophoneCaptureState;
  private disposed = false;
  private readonly onTaskCancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.task?.matchesTask(info.id)) {
      this.task.taskEnded();
      hilog.warn(0x0, TAG, 'Web task cancelled reason=%{public}d detail=%{public}d', info.reason, info.detailedReason);
      this.notice = '长时任务已取消，媒体状态仍在观测';
    }
  };

  aboutToAppear(): void {
    if (deviceInfo.apiAvailable(15)) {
      backgroundTaskManager.on('continuousTaskCancel', this.onTaskCancelled);
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    clearTimeout(this.resumeTimer);
    if (deviceInfo.apiAvailable(15)) {
      backgroundTaskManager.off('continuousTaskCancel', this.onTaskCancelled);
    }
    this.releaseTask();
    this.bridge?.close();
  }

  onPageHide(): void {
    this.hiddenAt = Date.now();
    hilog.info(0x0, TAG, 'Web background mode=%{public}s task=%{public}d playing=%{public}d mic=%{public}d',
      this.mode, this.task?.isRunning() ? 1 : 0, this.playing ? 1 : 0, this.microphone ?? -1);
    if (this.quiet && this.task?.isRunning() && this.isTestPage()) {
      this.controller.runJavaScript('window.oopzWebLab.silenceRemote(75)').catch((error: BusinessError) => {
        hilog.warn(0x0, TAG, 'Unable to start the remote silence gap code=%{public}d', error.code);
      });
    }
    if (!this.task?.isRunning() ||
      (this.mode !== 'web-native-mic' && this.microphone !== MicrophoneCaptureState.ACTIVE)) {
      return;
    }
    this.resumeTimer = setTimeout(() => {
      if (!this.hiddenAt || !this.task?.isRunning() || !this.isTestPage()) {
        return;
      }
      try {
        if (this.mode !== 'web-standard') {
          this.controller.onActive();
          hilog.info(0x0, TAG, 'Web onActive issued');
        }
        if (this.mode !== 'web-native-mic' && deviceInfo.apiAvailable(23)) {
          this.controller.resumeMicrophone();
          hilog.info(0x0, TAG, 'Web resumeMicrophone issued');
        }
      } catch (error) {
        hilog.warn(0x0, TAG, 'Web activation failed code=%{public}d', (error as BusinessError).code);
      }
    }, 180);
  }

  onPageShow(): void {
    clearTimeout(this.resumeTimer);
    if (!this.hiddenAt) {
      return;
    }
    hilog.info(0x0, TAG, 'Web foreground afterMs=%{public}d', Date.now() - this.hiddenAt);
    this.hiddenAt = 0;
    const context = this.context();
    if (context && this.task) {
      this.task.inspect(context).then((state) => {
        hilog.info(0x0, TAG, 'Web task state after return=%{public}d', state ?? -1);
      }).catch((error: BusinessError) => {
        hilog.warn(0x0, TAG, 'Web task inspection failed code=%{public}d', error.code);
      });
    }
  }

  private context(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private isTestPage(): boolean {
    return this.controller.getUrl() === ORIGIN + '/';
  }

  private async grantMicrophone(request: PermissionRequest): Promise<void> {
    const resource = ProtectedResourceType.AUDIO_CAPTURE;
    const origin = request.getOrigin();
    const context = this.context();
    if ((origin !== ORIGIN && origin !== ORIGIN + '/') ||
      !request.getAccessibleResource().includes(resource) || this.permissionPending || !context) {
      request.deny();
      return;
    }
    this.permissionPending = true;
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MICROPHONE]);
      if (result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED && !this.disposed) {
        request.grant([resource]);
      } else {
        request.deny();
      }
    } catch (error) {
      request.deny();
      hilog.warn(0x0, TAG, 'Web microphone permission failed code=%{public}d', (error as BusinessError).code);
    } finally {
      this.permissionPending = false;
    }
  }

  private async prepareTask(): Promise<void> {
    const context = this.context();
    if (!context || this.task || this.disposed) {
      return;
    }
    const task = new VoiceBackgroundTest(
      this.mode === 'web-voip' || this.mode === 'web-native-mic' ? 'native' : 'web');
    this.task = task;
    try {
      await task.start(context, this.playing);
      if (this.disposed) {
        await task.stop(context);
        return;
      }
      this.running = true;
      this.notice = 'WebRTC 双向测试和长时任务已启动';
      hilog.info(0x0, TAG, 'Web call ready mode=%{public}s', this.mode);
    } catch (error) {
      this.notice = '长时任务申请失败';
      const detail = error as BusinessError;
      hilog.error(0x0, TAG, 'Web task failed code=%{public}d message=%{public}s', detail.code, detail.message);
      await this.controller.runJavaScript('window.oopzWebLab.stop()').catch(() => '');
      await this.releaseTask();
    } finally {
      this.busy = false;
    }
  }

  private async releaseTask(): Promise<void> {
    const task = this.task;
    this.task = undefined;
    const context = this.context();
    if (!task || !context) {
      return;
    }
    try {
      await task.stop(context);
    } catch (error) {
      hilog.warn(0x0, TAG, 'Web task stop failed code=%{public}d', (error as BusinessError).code);
      await task.taskEnded();
    }
  }

  private async toggle(): Promise<void> {
    if (this.busy || !this.ready || !this.isTestPage()) {
      return;
    }
    this.busy = true;
    try {
      if (this.running) {
        await this.controller.runJavaScript('window.oopzWebLab.stop()');
        await this.releaseTask();
        this.running = false;
        this.notice = 'WebRTC 测试已结束';
        this.busy = false;
      } else {
        this.notice = '正在连接测试音频';
        await this.controller.runJavaScript(
          this.mode === 'web-native-mic' ? 'void window.oopzWebLab.start(true)' : 'void window.oopzWebLab.start()');
      }
    } catch (error) {
      this.notice = '测试网页命令失败';
      this.busy = false;
      hilog.warn(0x0, TAG, 'Web test command failed code=%{public}d', (error as BusinessError).code);
    }
  }

  private onWebMessage(message: string): void {
    if (!message.startsWith('OOPZ_WEB_LAB ')) {
      return;
    }
    hilog.info(0x0, TAG, '%{public}s', message);
    if (message === 'OOPZ_WEB_LAB ready' && this.busy) {
      this.prepareTask();
    } else if (message.startsWith('OOPZ_WEB_LAB error ')) {
      this.notice = 'WebRTC 测试启动失败';
      this.busy = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('ArkWeb 双向语音调试').fontSize(22)
      Text(this.notice).fontSize(16)
      Button(this.running ? '结束网页双向测试' : '开始网页双向测试')
        .enabled(this.ready && !this.busy)
        .onClick(() => { this.toggle(); })
      Web({ src: ORIGIN + '/', controller: this.controller })
        .javaScriptAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.None)
        .mediaPlayGestureAccess(false)
        .runJavaScriptOnDocumentStart([{ script: NATIVE_WEB_MICROPHONE_SCRIPT, scriptRules: [ORIGIN] }])
        .onLoadIntercept((event) => !event.data.getRequestUrl().startsWith(ORIGIN + '/'))
        .onPageEnd((event) => {
          this.ready = event.url === ORIGIN + '/';
          this.notice = this.ready ? '等待开始' : '本机测试网页未加载';
          const context = this.context();
          if (this.ready && context && this.mode === 'web-native-mic' && !this.bridge) {
            const bridge = new NativeWebMicrophone({ diagnostics: true });
            bridge.attach(this.controller, ORIGIN, context);
            this.bridge = bridge;
          }
        })
        .onPermissionRequest((event) => { this.grantMicrophone(event.request); })
        .onConsole((event) => {
          this.onWebMessage(event.message.getMessage());
          return false;
        })
        .onAudioStateChanged((event) => {
          this.playing = event.playing;
          this.task?.updateWebPlayback(event.playing);
          hilog.info(0x0, TAG, 'Web playback=%{public}d', event.playing ? 1 : 0);
        })
        .onMicrophoneCaptureStateChange((event) => {
          this.microphone = event.newState;
          hilog.info(0x0, TAG, 'Web microphone %{public}d -> %{public}d', event.originalState, event.newState);
        })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
