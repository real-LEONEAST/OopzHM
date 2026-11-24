import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PRODUCT_NAME } from 'BuildProfile';
import { NativeWebMicrophone } from '../voice/NativeWebMicrophone';
import { VoiceBackgroundTest, VoiceTaskState } from '../voice/VoiceBackgroundTest';
import {
  isOopzPage, LOCAL_VOICE_ORIGIN, LOCAL_VOICE_SCRIPTS, OOPZ_HOME, OOPZ_ORIGIN, OOPZ_SCRIPTS,
  REQUEST_CANVAS_KIT, resourceLabel, setViewportScale, WEB_STATUS
} from '../web/OopzPage';

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';
const LOG_TAG = 'OopzVoiceTest';
const PAGE_LOAD_TIMEOUT = 32000;

class WebMicrophoneObserver implements AttributeModifier<WebAttribute> {
  private readonly onChange: OnMicrophoneCaptureStateChangeCallback;

  constructor(onChange: OnMicrophoneCaptureStateChangeCallback) {
    this.onChange = onChange;
  }

  applyNormalAttribute(instance: WebAttribute): void {
    if (deviceInfo.apiAvailable(23)) {
      instance.onMicrophoneCaptureStateChange(this.onChange);
    }
  }
}

@Entry
@Component
struct Index {
  @StorageProp('oopzIndexLab') localLab: boolean = false;
  @StorageProp('oopzWebLabQuiet') quietLab: boolean = false;
  @State private webReady: boolean = false;
  @State private pageReady: boolean = false;
  @State private webNotice: string = '正在加载网页…';
  @State private webDiagnostic: string = '';
  @State private webScale: number = 100;
  @State private micNotice: string = '麦克风尚未授权';
  @State private taskNotice: string = '需要后台通话时，请先开启，再进语音频道';
  @State private bridgeEnabled: boolean = false;
  @State private taskOn: boolean = false;
  @State private taskBusy: boolean = false;

  private readonly mobileWindow: boolean = deviceInfo.deviceType === 'phone' || deviceInfo.deviceType === 'tablet';
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private readonly voiceTest = new VoiceBackgroundTest();
  private voiceBridge?: NativeWebMicrophone;
  private webPlaying: boolean = false;
  private webMicrophoneState?: MicrophoneCaptureState;
  private webActivationTimer: number = -1;
  private readonly microphoneObserver = new WebMicrophoneObserver((event: MicrophoneCaptureStateChangeInfo) => {
    this.webMicrophoneState = event.newState;
    hilog.info(0x0, LOG_TAG, 'ArkWeb microphone %{public}d -> %{public}d', event.originalState, event.newState);
  });
  private requestingMic: boolean = false;
  private observingCancellation: boolean = false;
  private hiddenAt: number = 0;
  private pageSequence: number = 0;
  private checkingSequence: number = -1;
  private checkTimer: number = -1;
  private loadTimer: number = -1;
  private loadingPage: boolean = false;
  private mainFrameLoaded: boolean = false;
  private networkRetryAttempted: boolean = false;
  private correctedNetworkState: boolean = false;
  private wasmStartupFailed: boolean = false;
  private rendererRetryAttempted: boolean = false;

  private readonly onTaskCancelled = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (deviceInfo.apiAvailable(15)) {
      if (this.voiceTest.matchesTask(info.id)) {
        this.voiceTest.taskEnded();
        this.taskOn = false;
        this.closeVoiceBridge();
        if (deviceInfo.apiAvailable('26.0.0')) {
          hilog.info(0x0, LOG_TAG, 'Web task cancelled, detail=%{public}d, playback=%{public}d',
            info.detailedReason, this.webPlaying ? 1 : 0);
          if (info.detailedReason ===
            backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_AUDIO_RECORDING_NOT_RUNNING) {
            this.reportTask('系统未检测到麦克风采集，后台任务已结束。');
            return;
          }
          if (info.detailedReason ===
            backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING) {
            this.reportTask('系统未检测到网页播放，后台任务已结束。');
            return;
          }
        }
        this.reportTask(`后台任务已取消（原因 ${info.reason}）。`);
      }
    }
  };

  aboutToAppear(): void {
    if (deviceInfo.apiAvailable(15)) {
      try {
        backgroundTaskManager.on('continuousTaskCancel', this.onTaskCancelled);
        this.observingCancellation = true;
      } catch (error) {
        hilog.warn(0x0, LOG_TAG, 'Unable to observe task cancellation, code=%{public}d', (error as BusinessError).code);
      }
    }
  }

  aboutToDisappear(): void {
    clearTimeout(this.webActivationTimer);
    this.finishPageLoad('');
    if (this.observingCancellation) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.onTaskCancelled);
      } catch (error) {
        hilog.warn(0x0, LOG_TAG, 'Unable to remove task observer, code=%{public}d', (error as BusinessError).code);
      }
    }
    this.closeVoiceBridge();
  }

  onPageShow(): void {
    clearTimeout(this.webActivationTimer);
    if (this.hiddenAt > 0) {
      const elapsed = Math.round((Date.now() - this.hiddenAt) / 1000);
      this.hiddenAt = 0;
      hilog.info(0x0, LOG_TAG, 'Page returned after %{public}d seconds, task=%{public}d playback=%{public}d',
        elapsed, this.taskOn ? 1 : 0, this.webPlaying ? 1 : 0);
      this.checkTask();
      if (this.loadingPage) {
        this.schedulePageChecks();
      }
    }
  }

  onPageHide(): void {
    this.hiddenAt = Date.now();
    clearTimeout(this.checkTimer);
    clearTimeout(this.loadTimer);
    hilog.info(0x0, LOG_TAG, 'Page entered background, task=%{public}d playback=%{public}d',
      this.taskOn ? 1 : 0, this.webPlaying ? 1 : 0);
    this.keepWebAudioActive();
  }

  private keepWebAudioActive(): void {
    if (!this.voiceBridge || !this.voiceTest.isRunning()) {
      return;
    }
    if (this.isLocalLab() && this.quietLab) {
      this.controller.runJavaScript('window.oopzWebLab.silenceRemote(75)').catch((error: BusinessError) => {
        hilog.warn(0x0, LOG_TAG, 'Local peer quiet sequence failed, code=%{public}d', error.code);
      });
    }
    clearTimeout(this.webActivationTimer);
    this.webActivationTimer = setTimeout(() => {
      if (this.hiddenAt === 0 || !this.voiceBridge || !this.voiceTest.isRunning()) {
        return;
      }
      try {
        if (this.isVoicePage(this.controller.getUrl())) {
          this.controller.onActive();
          hilog.info(0x0, LOG_TAG, 'ArkWeb playback activated during native call');
        }
      } catch (error) {
        hilog.warn(0x0, LOG_TAG, 'Unable to keep web audio active, code=%{public}d', (error as BusinessError).code);
      }
    }, 180);
  }

  onBackPress(): boolean {
    return this.goBackInWeb();
  }

  private getAbilityContext(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private isLocalLab(): boolean {
    return String(PRODUCT_NAME) === 'mate90Emulator' && this.localLab;
  }

  private voiceOrigin(): string {
    return this.isLocalLab() ? LOCAL_VOICE_ORIGIN : OOPZ_ORIGIN;
  }

  private isVoicePage(address: string): boolean {
    if (this.isLocalLab()) {
      return address === LOCAL_VOICE_ORIGIN || address === LOCAL_VOICE_ORIGIN + '/';
    }
    return isOopzPage(address);
  }

  private reportTask(status: string): void {
    this.taskNotice = status;
    hilog.info(0x0, LOG_TAG, '%{public}s', status);
  }

  private showWebDiagnostic(detail: string): void {
    if (this.webDiagnostic !== detail) {
      this.webDiagnostic = detail;
      hilog.warn(0x0, LOG_TAG, 'Web diagnostic %{public}s', detail);
    }
  }

  private beginPageLoad(): void {
    clearTimeout(this.webActivationTimer);
    if (this.voiceBridge) {
      this.closeVoiceBridge();
      this.reportTask('网页已重新加载，需要后台通话时请先开启');
    }
    this.webMicrophoneState = undefined;
    this.pageSequence++;
    this.pageReady = false;
    this.webPlaying = false;
    this.loadingPage = true;
    this.mainFrameLoaded = false;
    this.wasmStartupFailed = false;
    this.webNotice = '正在加载网页…';
    this.schedulePageChecks();
  }

  private schedulePageChecks(): void {
    clearTimeout(this.checkTimer);
    clearTimeout(this.loadTimer);
    if (this.hiddenAt !== 0) {
      return;
    }
    const sequence = this.pageSequence;
    this.checkTimer = setTimeout(() => { this.checkWebPage(sequence); }, 1500);
    this.loadTimer = setTimeout(() => {
      if (this.isLoading(sequence)) {
        this.finishPageLoad('网页启动超时，点重载重试');
        this.showWebDiagnostic(this.webDiagnostic || '未检测到 Oopz 页面启动完成');
      }
    }, PAGE_LOAD_TIMEOUT);
  }

  private isLoading(sequence: number): boolean {
    return this.loadingPage && this.pageSequence === sequence && this.hiddenAt === 0;
  }

  private finishPageLoad(notice: string): void {
    this.loadingPage = false;
    this.webNotice = notice;
    clearTimeout(this.checkTimer);
    clearTimeout(this.loadTimer);
  }

  private async checkWebPage(sequence: number): Promise<void> {
    if (!this.isLoading(sequence) || !this.webReady || this.checkingSequence === sequence) {
      return;
    }
    this.checkingSequence = sequence;
    try {
      const result = await this.controller.runJavaScript(WEB_STATUS);
      if (!this.isLoading(sequence)) {
        return;
      }
      const report = result.match(/^"?(true|false)\|(true|false)\|(true|false)\|(true|false)"?$/);
      if (!report) {
        return;
      }

      if (report[1] === 'false' && this.mainFrameLoaded && !this.networkRetryAttempted && !this.voiceTest.isRunning()) {
        this.networkRetryAttempted = true;
        await this.recoverWebConnectivity(sequence);
        return;
      }
      if (report[2] === 'true' && report[3] === 'false' && this.mainFrameLoaded) {
        this.pageReady = true;
        this.finishPageLoad('');
        hilog.info(0x0, LOG_TAG, 'Oopz page ready, renderer=%{public}s, online=%{public}s',
          report[4] === 'true' ? 'CanvasKit' : 'default', report[1]);
        if (this.correctedNetworkState && report[1] === 'true') {
          this.showWebDiagnostic('ArkWeb 已恢复在线');
        }
        if (this.mobileWindow) {
          this.resizeWeb(this.webScale);
        }
      } else if (report[1] === 'true' && report[4] === 'false' && this.wasmStartupFailed &&
        !this.rendererRetryAttempted && !this.voiceTest.isRunning()) {
        this.rendererRetryAttempted = true;
        await this.tryCanvasKit(sequence);
      }
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Web page check failed, code=%{public}d', (error as BusinessError).code);
    } finally {
      if (this.checkingSequence === sequence) {
        this.checkingSequence = -1;
      }
      if (this.isLoading(sequence)) {
        clearTimeout(this.checkTimer);
        this.checkTimer = setTimeout(() => { this.checkWebPage(sequence); }, 1500);
      }
    }
  }

  private async tryCanvasKit(sequence: number): Promise<void> {
    const available = await this.controller.runJavaScript(REQUEST_CANVAS_KIT);
    if (available === 'true' && this.isLoading(sequence) && !this.voiceTest.isRunning()) {
      this.showWebDiagnostic('启动资源加载失败，正在尝试 CanvasKit');
      this.refreshFromNetwork();
    }
  }

  private async recoverWebConnectivity(sequence: number): Promise<void> {
    this.showWebDiagnostic('网页报告离线，正在检查官网连接');
    const probe = http.createHttp();
    try {
      const response = await probe.request(OOPZ_HOME, {
        method: http.RequestMethod.HEAD,
        usingCache: false,
        connectTimeout: 5000,
        readTimeout: 5000
      });
      if (!this.isLoading(sequence) || this.voiceTest.isRunning()) {
        return;
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        this.showWebDiagnostic(`应用访问官网返回 HTTP ${response.responseCode}`);
        return;
      }

      this.controller.setNetworkAvailable(true);
      this.correctedNetworkState = true;
      this.showWebDiagnostic('官网可达，已同步在线状态，正在重载');
      this.refreshFromNetwork();
    } catch (error) {
      if (sequence === this.pageSequence) {
        this.showWebDiagnostic(`应用网络检查失败（${(error as BusinessError).code}）`);
      }
    } finally {
      probe.destroy();
    }
  }

  private reportWebResourceError(request: WebResourceRequest, error: string): void {
    const address = request.getRequestUrl();
    const label = resourceLabel(address);
    if (request.isMainFrame()) {
      this.pageReady = false;
      this.finishPageLoad(`网页加载失败（${error}），可重载`);
    } else if (this.loadingPage && isOopzPage(address) && /\/(main\.dart\.(wasm|mjs)|skwasm[^/]*\.(wasm|js))$/.test(label)) {
      this.wasmStartupFailed = true;
    }
    this.showWebDiagnostic(`${label} 加载失败（${error}）`);
  }

  private reportWebConsole(message: ConsoleMessage): void {
    const text = message.getMessage();
    if (this.isLocalLab() && text.startsWith('OOPZ_WEB_LAB ')) {
      hilog.info(0x0, LOG_TAG, '%{public}s', text);
    }
    if (message.getMessageLevel() !== MessageLevel.Error) {
      return;
    }
    const networkError = text.match(/\bERR_[A-Z_]+\b/);
    if (networkError) {
      this.showWebDiagnostic(`网页网络错误（${networkError[0]}）`);
    } else if (text.includes('WebSocket') && (text.includes('failed') || text.includes('closed'))) {
      this.showWebDiagnostic('网页实时连接失败（WebSocket）');
    } else if (text.includes('Failed to fetch')) {
      this.showWebDiagnostic('网页请求失败（Fetch）');
    } else if (text.includes('WebAssembly') || text.includes('Wasm')) {
      this.showWebDiagnostic('网页引擎启动遇到 WebAssembly 错误');
    }
  }

  private async requestWebMicrophone(request: PermissionRequest): Promise<void> {
    const resource = ProtectedResourceType.AUDIO_CAPTURE;
    if (!this.isVoicePage(request.getOrigin()) || !request.getAccessibleResource().includes(resource) ||
      this.requestingMic || this.bridgeEnabled) {
      request.deny();
      return;
    }

    const context = this.getAbilityContext();
    if (context === undefined) {
      request.deny();
      return;
    }

    this.requestingMic = true;
    let granted = false;
    try {
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MICROPHONE]);
      granted = permission.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Microphone permission request failed, code=%{public}d', (error as BusinessError).code);
    } finally {
      this.requestingMic = false;
    }

    try {
      if (granted) {
        request.grant([resource]);
        this.micNotice = '网页麦克风已授权';
      } else {
        request.deny();
        this.micNotice = '麦克风未授权，可在系统设置里开启后重载';
      }
      hilog.info(0x0, LOG_TAG, 'Web microphone grant=%{public}d', granted ? 1 : 0);
    } catch (error) {
      this.micNotice = '网页麦克风申请已失效，请在频道里重试';
      hilog.warn(0x0, LOG_TAG, 'Web permission response failed, code=%{public}d', (error as BusinessError).code);
    }
  }

  private async toggleTest(): Promise<void> {
    const context = this.getAbilityContext();
    if (this.taskBusy || context === undefined) {
      return;
    }

    this.taskBusy = true;
    try {
      if (this.bridgeEnabled) {
        if (this.isVoicePage(this.controller.getUrl())) {
          await this.controller.runJavaScript('window.oopzNativeMicrophone?.disconnect()').catch(() => '');
        }
        await this.closeVoiceBridge();
        this.reportTask('后台通话已关闭，网页下一次开麦会使用网页麦克风。');
        return;
      }
      if (!this.pageReady || !this.isVoicePage(this.controller.getUrl())) {
        return;
      }
      if (this.webMicrophoneState === MicrophoneCaptureState.ACTIVE) {
        this.reportTask('网页正在用麦克风，请先退出语音频道，再开启后台通话。');
        return;
      }
      const bridge = new NativeWebMicrophone({
        diagnostics: this.isLocalLab(),
        onStarted: async () => {
          try {
            await this.voiceTest.start(context);
            this.taskOn = true;
            this.micNotice = '原生麦克风正在采集';
            this.reportTask('原生麦克风和通话任务已启动');
          } catch (error) {
            this.reportTask(`系统通话任务启动失败（${(error as BusinessError).code}）`);
            throw error as Error;
          }
        },
        onStopped: async () => {
          await this.releaseVoiceTask(context);
          if (this.bridgeEnabled) {
            this.micNotice = '原生麦克风已释放';
            this.reportTask('后台通话已开启，等待网页开麦');
          }
        }
      });
      this.voiceBridge = bridge;
      bridge.attach(this.controller, this.voiceOrigin(), context);
      const ready = await this.controller.runJavaScript('window.oopzNativeMicrophone?.ready === true');
      if (ready !== 'true' || this.voiceBridge !== bridge) {
        throw new Error('Native microphone channel was not attached');
      }
      this.bridgeEnabled = true;
      this.reportTask('后台通话已开启，等待网页开麦');
    } catch (error) {
      await this.closeVoiceBridge();
      this.reportTask('后台通话设置失败，请重载网页后重试。');
      hilog.warn(0x0, LOG_TAG, 'Voice bridge configuration failed, code=%{public}d', (error as BusinessError).code ?? -1);
    } finally {
      this.taskBusy = false;
    }
  }

  private async closeVoiceBridge(): Promise<void> {
    clearTimeout(this.webActivationTimer);
    const bridge = this.voiceBridge;
    this.voiceBridge = undefined;
    this.bridgeEnabled = false;
    await bridge?.close();
    const context = this.getAbilityContext();
    if (context && this.voiceTest.isRunning()) {
      await this.releaseVoiceTask(context);
    }
  }

  private async releaseVoiceTask(context: common.UIAbilityContext): Promise<void> {
    try {
      await this.voiceTest.stop(context);
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Unable to stop the native Web call task, code=%{public}d', (error as BusinessError).code);
      await this.voiceTest.taskEnded();
    } finally {
      this.taskOn = false;
    }
  }

  private async checkTask(): Promise<void> {
    const context = this.getAbilityContext();
    if (!this.voiceTest.isRunning() || this.taskBusy || context === undefined) {
      return;
    }

    this.taskBusy = true;
    try {
      const state = await this.voiceTest.inspect(context);
      if (!this.voiceTest.isRunning()) {
        return;
      }
      if (state === VoiceTaskState.ABSENT) {
        await this.voiceTest.taskEnded();
        await this.closeVoiceBridge();
        this.reportTask('返回前台时，系统后台任务已结束。');
      } else if (state === VoiceTaskState.SUSPENDED) {
        this.reportTask('系统后台任务已暂停。');
      } else if (state === VoiceTaskState.RUNNING) {
        this.reportTask('后台任务仍在运行，通话结果以双方听到的声音为准。');
      }
    } catch (error) {
      this.reportTask(`无法查询系统后台任务（${(error as BusinessError).code}）。`);
    } finally {
      this.taskOn = this.voiceTest.isRunning();
      this.taskBusy = false;
    }
  }

  private goBackInWeb(): boolean {
    try {
      if (this.webReady && this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Web navigation failed, code=%{public}d', (error as BusinessError).code);
    }
    return false;
  }

  private async reloadWeb(): Promise<void> {
    if (!this.webReady || this.taskBusy) {
      return;
    }
    await this.closeVoiceBridge();
    this.networkRetryAttempted = false;
    this.correctedNetworkState = false;
    this.rendererRetryAttempted = false;
    this.webDiagnostic = '';
    this.refreshFromNetwork();
  }

  private refreshFromNetwork(): void {
    this.beginPageLoad();
    try {
      if (!this.isVoicePage(this.controller.getUrl())) {
        this.controller.loadUrl(this.isLocalLab() ? LOCAL_VOICE_ORIGIN + '/' : OOPZ_HOME);
      } else if (deviceInfo.apiAvailable(24)) {
        this.controller.refresh(true);
      } else {
        this.controller.removeCache(true);
        this.controller.refresh();
      }
    } catch (error) {
      this.finishPageLoad(`网页重载失败（${(error as BusinessError).code}）`);
    }
  }

  private async changeOrientation(orientation: window.Orientation): Promise<void> {
    const context = this.getAbilityContext();
    if (context === undefined) {
      return;
    }
    try {
      const mainWindow = await window.getLastWindow(context);
      await mainWindow.setPreferredOrientation(orientation);
      hilog.info(0x0, LOG_TAG, 'Window orientation requested=%{public}d', orientation);
    } catch (error) {
      this.showWebDiagnostic(`切换屏幕方向失败（${(error as BusinessError).code}）`);
    }
  }

  private async resizeWeb(percent: number): Promise<void> {
    const sequence = this.pageSequence;
    try {
      const result = await this.controller.runJavaScript(setViewportScale(percent));
      if (result === 'true' && this.pageReady && sequence === this.pageSequence) {
        this.webScale = percent;
        hilog.info(0x0, LOG_TAG, 'Web viewport requested percent=%{public}d', percent);
      }
    } catch (error) {
      this.showWebDiagnostic(`调整缩放失败（${(error as BusinessError).code}）`);
    }
  }

  private changeZoom(increase: boolean): void {
    if (this.mobileWindow) {
      const percent = Math.max(50, Math.min(150, this.webScale + (increase ? 10 : -10)));
      this.resizeWeb(percent);
      return;
    }
    try {
      if (increase) {
        this.controller.zoomIn();
      } else {
        this.controller.zoomOut();
      }
    } catch (error) {
      this.showWebDiagnostic(`调整缩放失败（${(error as BusinessError).code}）`);
    }
  }

  private displayMenu(): MenuElement[] {
    const items: MenuElement[] = [
      { value: '缩小网页', enabled: this.pageReady && (!this.mobileWindow || this.webScale > 50),
        action: () => { this.changeZoom(false); } },
      { value: '放大网页', enabled: this.pageReady && (!this.mobileWindow || this.webScale < 150),
        action: () => { this.changeZoom(true); } }
    ];
    if (this.mobileWindow) {
      items.push(
        { value: '还原网页大小', enabled: this.pageReady, action: () => { this.resizeWeb(100); } },
        { value: '横屏', action: () => { this.changeOrientation(window.Orientation.LANDSCAPE); } },
        { value: '竖屏', action: () => { this.changeOrientation(window.Orientation.PORTRAIT); } },
        { value: '自动旋转', action: () => { this.changeOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED); } }
      );
    }
    return items;
  }

  private showStatus(): void {
    const lines = [this.webNotice, this.webDiagnostic, this.taskNotice, this.micNotice].filter((line: string) => line.length > 0);
    this.getUIContext().showAlertDialog({ title: '测试状态', message: lines.join('\n') });
  }

  build() {
    Column() {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Button(this.bridgeEnabled ? '关闭后台通话' : '开启后台通话')
            .height(36)
            .fontSize(13)
            .fontColor('#10272B')
            .backgroundColor('#A5E6D8')
            .enabled((this.pageReady || this.bridgeEnabled) && !this.taskBusy)
            .onClick(() => { this.toggleTest(); })
          Button('重载')
            .height(36)
            .fontSize(13)
            .backgroundColor('#304658')
            .enabled(this.webReady && !this.taskBusy)
            .onClick(() => { this.reloadWeb(); })
          Button('显示')
            .height(36)
            .fontSize(13)
            .backgroundColor('#304658')
            .bindMenu(this.displayMenu())
          Button('原生语音')
            .height(30)
            .fontSize(13)
            .backgroundColor('#304658')
            .onClick(() => {
              const router = this.getUIContext().getRouter();
              if (router.getStateByUrl('pages/NativeVoice').length > 0) {
                router.back({ url: 'pages/NativeVoice' });
                return;
              }
              router.pushUrl({ url: 'pages/NativeVoice' }).catch(() => {
                this.webNotice = '无法打开原生语音';
              });
            })
        }
        .width('100%')

        Text(this.webNotice || this.taskNotice)
          .fontSize(12)
          .fontColor('#B7CAD8')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ top: 3, bottom: 3 })
          .onClick(() => { this.showStatus(); })
      }
      .padding({ top: 4, bottom: 2, left: 8, right: 8 })
      .backgroundColor('#142331')
      .width('100%')

      Web({ src: this.isLocalLab() ? LOCAL_VOICE_ORIGIN + '/' : OOPZ_HOME, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .mixedMode(MixedMode.None)
        .zoomAccess(true)
        .metaViewport(true)
        .runJavaScriptOnDocumentStart(this.isLocalLab() ? LOCAL_VOICE_SCRIPTS : OOPZ_SCRIPTS)
        .onControllerAttached(() => { this.webReady = true; })
        .onLoadIntercept((event) => {
          if (!event.data.isMainFrame() || this.isVoicePage(event.data.getRequestUrl())) {
            return false;
          }
          this.webNotice = '已拦截离开 web.oopz.cn 的页面，请用站内登录。';
          return true;
        })
        .onPageBegin(() => { this.beginPageLoad(); })
        .onPageEnd((event) => {
          if (this.isLocalLab() && this.isVoicePage(event.url)) {
            this.pageReady = true;
            this.finishPageLoad('');
          } else if (isOopzPage(event.url)) {
            this.mainFrameLoaded = true;
            this.checkWebPage(this.pageSequence);
          }
        })
        .onErrorReceive((event) => {
          const code = event.error.getErrorCode();
          if (code !== -3) {
            const name = event.error.getErrorInfo().match(/\bERR_[A-Z_]+\b/);
            this.reportWebResourceError(event.request, name ? `${name[0]} ${code}` : `${code}`);
          }
        })
        .onHttpErrorReceive((event) => {
          this.reportWebResourceError(event.request, `HTTP ${event.response.getResponseCode()}`);
        })
        .onConsole((event) => {
          this.reportWebConsole(event.message);
          return false;
        })
        .onAudioStateChanged((event) => {
          this.webPlaying = event.playing;
          hilog.info(0x0, LOG_TAG, 'ArkWeb playback=%{public}d', event.playing ? 1 : 0);
        })
        .onScaleChange((event) => {
          hilog.info(0x0, LOG_TAG, 'ArkWeb reported scale=%{public}f', event.newScale);
        })
        .attributeModifier(this.microphoneObserver)
        .onPermissionRequest((event) => { this.requestWebMicrophone(event.request); })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#142331')
  }
}
