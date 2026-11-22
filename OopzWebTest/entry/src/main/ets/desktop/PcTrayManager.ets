// HarmonyOS PC status-bar tray integration + minimize-to-tray lifecycle helper.

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo, emitter } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import statusBarManager from '@hms.pcService.statusBarManager';

const TAG: string = 'PcTray';

export type TrayCallAction = 'toggle_mute' | 'leave_call' | 'quit_app';
export type TrayActionHandler = (action: TrayCallAction) => void;

interface TrayMenuEventData {
  menuCode?: string;
}

function fillPixel(buf: Uint8Array, size: number, x: number, y: number, r: number, g: number, b: number, a: number): void {
  const idx = (y * size + x) * 4;
  buf[idx] = r;
  buf[idx + 1] = g;
  buf[idx + 2] = b;
  buf[idx + 3] = a;
}

async function createRingIcon(r: number, g: number, b: number, showLiveDot: boolean): Promise<image.PixelMap> {
  const size = 48;
  const cx = (size - 1) / 2;
  const cy = (size - 1) / 2;
  const buf = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = x - cx;
      const dy = y - cy;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if ((dist >= 11.5 && dist <= 17.5) || dist <= 6.2) {
        fillPixel(buf, size, x, y, r, g, b, 255);
      }
      if (showLiveDot) {
        const dotDx = x - 35;
        const dotDy = y - 13;
        const dotDist = Math.sqrt(dotDx * dotDx + dotDy * dotDy);
        if (dotDist <= 6.5) {
          fillPixel(buf, size, x, y, 52, 211, 153, 255);
        }
      }
    }
  }
  return await image.createPixelMap(buf.buffer, {
    size: { width: size, height: size },
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false
  });
}

export class PcTrayManager {
  private static instance: PcTrayManager | undefined = undefined;

  static get(): PcTrayManager {
    if (PcTrayManager.instance === undefined) {
      PcTrayManager.instance = new PcTrayManager();
    }
    return PcTrayManager.instance;
  }

  private context?: common.UIAbilityContext;
  private windowStage?: window.WindowStage;
  private mainWindow?: window.Window;
  private registered: boolean = false;
  private allowTerminate: boolean = false;
  private lastTip: string = '';
  private lastUpdateAt: number = 0;
  private lastLiveDot: boolean = false;
  private iconNormalWhite?: image.PixelMap;
  private iconNormalBlack?: image.PixelMap;
  private iconLiveWhite?: image.PixelMap;
  private iconLiveBlack?: image.PixelMap;
  private actionHandler?: TrayActionHandler;
  private clickRegistered: boolean = false;

  private readonly onIconClick = (_data: emitter.EventData): void => {
    hilog.info(0x0, TAG, 'Tray left click -> show window');
    this.showMainWindow().catch(() => {});
  };

  private readonly onRightMenuClick = (eventData: emitter.EventData): void => {
    const data = eventData.data as TrayMenuEventData | undefined;
    const code = data?.menuCode ?? '';
    hilog.info(0x0, TAG, 'Tray menu click code=%{public}s', code);
    if (code === 'open_window') {
      this.showMainWindow().catch(() => {});
    } else if (code === 'toggle_mute' || code === 'leave_call') {
      this.actionHandler?.(code as TrayCallAction);
    } else if (code === 'quit_app') {
      if (this.actionHandler !== undefined) {
        this.actionHandler('quit_app');
      } else {
        this.quitApp().catch(() => {});
      }
    }
  };

  isDesktopPc(): boolean {
    return deviceInfo.deviceType === '2in1';
  }

  setCallActionHandler(handler?: TrayActionHandler): void {
    this.actionHandler = handler;
  }

  async init(context: common.UIAbilityContext, windowStage: window.WindowStage): Promise<void> {
    this.context = context;
    this.windowStage = windowStage;
    const isPc = this.isDesktopPc();
    AppStorage.setOrCreate<boolean>('oopzIsPc', isPc);
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch {
      this.mainWindow = undefined;
    }

    if (isPc && deviceInfo.apiAvailable(14)) {
      try {
        windowStage.on('windowStageClose', (): boolean => {
          const trayOnClose = AppStorage.get<boolean>('oopzTrayOnClose') !== false;
          if (trayOnClose && !this.allowTerminate) {
            hilog.info(0x0, TAG, 'windowStageClose intercepted -> minimize to tray');
            this.minimizeToTray().catch(() => {});
            return true;
          }
          return false;
        });
      } catch (err) {
        hilog.warn(0x0, TAG, 'windowStageClose hook unavailable: %{public}s', (err as Error).message);
      }
    }

    if (isPc) {
      await this.setupTrayIcon();
    }
  }

  private async ensureIcons(): Promise<boolean> {
    if (this.iconNormalWhite !== undefined && this.iconNormalBlack !== undefined) {
      return true;
    }
    try {
      this.iconNormalWhite = await createRingIcon(255, 255, 255, false);
      this.iconNormalBlack = await createRingIcon(20, 24, 34, false);
      this.iconLiveWhite = await createRingIcon(255, 255, 255, true);
      this.iconLiveBlack = await createRingIcon(20, 24, 34, true);
      return true;
    } catch (err) {
      hilog.warn(0x0, TAG, 'create icon pixelMap failed: %{public}s', (err as Error).message);
      return false;
    }
  }

  private makeMenuAction(code: string): statusBarManager.StatusBarMenuAction {
    const action: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      moduleName: 'entry'
    };
    if (deviceInfo.apiAvailable(14)) {
      action.notifyOnly = true;
      action.menuCode = code;
    }
    return action;
  }

  private makeMenuItem(title: string, code: string): statusBarManager.StatusBarMenuItem {
    const item: statusBarManager.StatusBarMenuItem = {
      title: title,
      menuAction: this.makeMenuAction(code)
    };
    if (deviceInfo.apiAvailable(24)) {
      item.menuCode = code;
    }
    return item;
  }

  private buildMenuGroups(inCall: boolean, channelName: string, muted: boolean): statusBarManager.StatusBarGroupMenu[] {
    const firstGroup: statusBarManager.StatusBarMenuItem[] = [
      this.makeMenuItem('打开 OopzHM 主窗口', 'open_window')
    ];
    if (inCall) {
      firstGroup.push(this.makeMenuItem(muted ? '打开麦克风' : '关闭麦克风', 'toggle_mute'));
      const label = channelName.length > 0 ? `退出语音（${channelName}）` : '退出当前语音';
      firstGroup.push(this.makeMenuItem(label, 'leave_call'));
    }
    const secondGroup: statusBarManager.StatusBarMenuItem[] = [
      this.makeMenuItem('完全退出 OopzHM', 'quit_app')
    ];
    return [firstGroup, secondGroup];
  }

  async setupTrayIcon(): Promise<void> {
    const ctx = this.context;
    if (ctx === undefined || this.registered) {
      return;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      try {
        const supported = await statusBarManager.isStatusBarCapabilitySupported(ctx);
        if (!supported) {
          hilog.info(0x0, TAG, 'Status bar tray not supported on this device');
          return;
        }
      } catch {
        // continue with addToStatusBar attempt on PC
      }
    }
    const ready = await this.ensureIcons();
    if (!ready || this.iconNormalWhite === undefined || this.iconNormalBlack === undefined) {
      return;
    }
    try {
      if (!this.clickRegistered && deviceInfo.apiAvailable(14)) {
        statusBarManager.on('statusBarIconClick', this.onIconClick);
        statusBarManager.on('rightMenuClick', this.onRightMenuClick);
        this.clickRegistered = true;
      }
      const item: statusBarManager.StatusBarItem = {
        icons: {
          white: this.iconNormalWhite,
          black: this.iconNormalBlack
        },
        quickOperation: {
          abilityName: '',
          moduleName: 'entry',
          title: 'OopzHM',
          height: 120
        },
        statusBarGroupMenu: this.buildMenuGroups(false, '', false)
      };
      if (deviceInfo.apiAvailable(22)) {
        item.hoverTips = 'OopzHM · 在线';
      }
      statusBarManager.addToStatusBar(ctx, item);
      this.registered = true;
      this.lastTip = 'OopzHM · 在线';
      this.lastUpdateAt = Date.now();
      hilog.info(0x0, TAG, 'Status bar tray icon registered');
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0, TAG, 'addToStatusBar failed code=%{public}d msg=%{public}s', be.code ?? -1, be.message ?? '');
    }
  }

  updateTrayState(inCall: boolean, channelName: string, muted: boolean): void {
    const ctx = this.context;
    if (!this.registered || ctx === undefined) {
      return;
    }
    const tip = inCall
      ? `OopzHM · 通话中：${channelName.length > 0 ? channelName : '语音频道'}（${muted ? '已闭麦' : '开麦'}）`
      : 'OopzHM · 在线';
    const now = Date.now();
    if (tip === this.lastTip && inCall === this.lastLiveDot) {
      return;
    }
    if (now - this.lastUpdateAt < 1500) {
      return;
    }
    this.lastTip = tip;
    this.lastLiveDot = inCall;
    this.lastUpdateAt = now;

    try {
      if (deviceInfo.apiAvailable(22)) {
        statusBarManager.updateStatusBarHoverTips(ctx, tip).catch(() => {});
      }
      if (this.iconLiveWhite !== undefined && this.iconLiveBlack !== undefined &&
        this.iconNormalWhite !== undefined && this.iconNormalBlack !== undefined) {
        statusBarManager.updateStatusBarIcon(ctx, {
          white: inCall ? this.iconLiveWhite : this.iconNormalWhite,
          black: inCall ? this.iconLiveBlack : this.iconNormalBlack
        });
      }
      statusBarManager.updateStatusBarMenu(ctx, this.buildMenuGroups(inCall, channelName, muted));
    } catch (err) {
      hilog.warn(0x0, TAG, 'updateTrayState failed: %{public}s', (err as Error).message);
    }
  }

  async minimizeToTray(): Promise<boolean> {
    const ctx = this.context;
    if (ctx === undefined) {
      return false;
    }
    await this.setupTrayIcon();
    try {
      await ctx.hideAbility();
      AppStorage.setOrCreate<boolean>('oopzInTray', true);
      hilog.info(0x0, TAG, 'minimized to tray via hideAbility');
      return true;
    } catch (err) {
      hilog.warn(0x0, TAG, 'hideAbility failed: %{public}s', (err as Error).message);
    }
    if (this.mainWindow !== undefined) {
      try {
        await this.mainWindow.minimize();
        AppStorage.setOrCreate<boolean>('oopzInTray', true);
        hilog.info(0x0, TAG, 'minimized via mainWindow.minimize');
        return true;
      } catch (err) {
        hilog.warn(0x0, TAG, 'mainWindow.minimize failed: %{public}s', (err as Error).message);
      }
    }
    return false;
  }

  async showMainWindow(): Promise<void> {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    try {
      await ctx.showAbility();
    } catch (err) {
      hilog.warn(0x0, TAG, 'showAbility failed: %{public}s', (err as Error).message);
    }
    if (this.mainWindow !== undefined) {
      if (deviceInfo.apiAvailable(14)) {
        try {
          await this.mainWindow.restore();
        } catch {
          // ignore if window wasn't minimized
        }
      }
      try {
        await this.mainWindow.showWindow();
      } catch {
        // ignore if already visible
      }
    }
    AppStorage.setOrCreate<boolean>('oopzInTray', false);
    hilog.info(0x0, TAG, 'restored main window from tray');
  }

  async quitApp(): Promise<void> {
    this.allowTerminate = true;
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    if (this.registered) {
      try {
        statusBarManager.removeFromStatusBar(ctx);
      } catch {
        // ignore removal failure on exit
      }
      this.registered = false;
    }
    try {
      await ctx.terminateSelf();
    } catch {
      // ignore termination errors
    }
  }

  cleanup(): void {
    if (this.clickRegistered && deviceInfo.apiAvailable(14)) {
      try {
        statusBarManager.off('statusBarIconClick', this.onIconClick);
        statusBarManager.off('rightMenuClick', this.onRightMenuClick);
      } catch {
        // ignore
      }
      this.clickRegistered = false;
    }
    const ctx = this.context;
    if (this.registered && ctx !== undefined) {
      try {
        statusBarManager.removeFromStatusBar(ctx);
      } catch {
        // ignore when no foreground window
      }
      this.registered = false;
    }
  }
}
