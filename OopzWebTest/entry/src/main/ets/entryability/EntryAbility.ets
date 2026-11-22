import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PRODUCT_NAME } from 'BuildProfile';
import { getTheme, resolveIsDark } from '../common/Theme';
import { PcTrayManager } from '../desktop/PcTrayManager';
import { AppStore } from '../store/AppStore';

const LOG_TAG = 'OopzVoiceTest';

export default class EntryAbility extends UIAbility {
  private page = 'pages/NativeVoice';
  private mainWindow?: window.Window;

  private syncThemeColors(systemColorMode?: ConfigurationConstant.ColorMode): void {
    const sysDark = systemColorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    AppStorage.setOrCreate<boolean>('oopzSystemIsDark', sysDark);
    const mode = AppStorage.get<string>('oopzThemeMode') ?? 'system';
    const isDark = resolveIsDark(mode, sysDark);
    AppStorage.setOrCreate<boolean>('oopzIsDark', isDark);
    if (this.mainWindow !== undefined) {
      try {
        this.mainWindow.setWindowBackgroundColor(getTheme(isDark).bg);
      } catch {
        // ignore background update errors
      }
    }
  }

  onCreate(want: Want): void {
    this.syncThemeColors(this.context.config.colorMode);
    AppStorage.setOrCreate<boolean>('oopzNativeSelfTest', want.parameters?.['oopzSelfTest'] === 'yes');
    const params = want.parameters;
    if (params?.['oopzPhone'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoPhone', String(params['oopzPhone']));
    }
    if (params?.['oopzPass'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoPass', String(params['oopzPass']));
    }
    if (params?.['oopzJwt'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoJwt', String(params['oopzJwt']));
    }
    if (params?.['oopzPerson'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoPerson', String(params['oopzPerson']));
    }
    if (params?.['oopzDevice'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoDevice', String(params['oopzDevice']));
    }
    if (params?.['oopzArea'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoArea', String(params['oopzArea']));
    }
    if (params?.['oopzChannel'] !== undefined) {
      AppStorage.setOrCreate<string>('oopzAutoChannel', String(params['oopzChannel']));
    }
    if (String(PRODUCT_NAME) !== 'mate90Emulator') {
      return;
    }
    const lab = want.parameters?.['oopzAudioLab'] as string | undefined;
    AppStorage.setOrCreate<boolean>('oopzIndexLab', lab === 'index-local');
    AppStorage.setOrCreate<boolean>('oopzWebLabQuiet', want.parameters?.['oopzWebQuiet'] === 'yes');
    if (lab === 'index-local') {
      this.page = 'pages/Index';
    } else if (lab === 'native') {
      this.page = 'pages/AudioLab';
    } else if (lab === 'web-standard' || lab === 'web-active' || lab === 'web-voip' || lab === 'web-native-mic') {
      this.page = 'pages/WebAudioLab';
      AppStorage.setOrCreate<string>('oopzWebLabMode', lab);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncThemeColors(newConfig.colorMode);
  }

  onForeground(): void {
    AppStore.get().setForeground(true);
  }

  onBackground(): void {
    AppStore.get().setForeground(false);
  }

  onNewWant(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    PcTrayManager.get().showMainWindow().catch(() => {});
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch {
      this.mainWindow = undefined;
    }
    try {
      windowStage.on('windowStageEvent', (event: window.WindowStageEventType) => {
        hilog.info(0x0, LOG_TAG, 'Window stage event: %{public}d', event);
        if (deviceInfo.deviceType === '2in1') {
          if (event === window.WindowStageEventType.SHOWN) AppStore.get().setForeground(true);
          if (event === window.WindowStageEventType.HIDDEN) AppStore.get().setForeground(false);
        }
      });
    } catch (error) {
      hilog.warn(0x0, LOG_TAG, 'Unable to observe the window stage, code=%{public}d', (error as BusinessError).code);
    }
    PcTrayManager.get().init(this.context, windowStage).catch(() => {});
    windowStage.loadContent(this.page).then(() => {
      const isDark = AppStorage.get<boolean>('oopzIsDark') ?? true;
      try {
        this.mainWindow?.setWindowBackgroundColor(getTheme(isDark).bg);
      } catch {
        // ignore
      }
    }).catch((error: BusinessError) => {
      hilog.error(0x0, LOG_TAG, 'Unable to load the test page, code=%{public}d', error.code);
    });
  }

  onDestroy(): void {
    AppStore.get().setForeground(false);
    PcTrayManager.get().cleanup();
  }
}
