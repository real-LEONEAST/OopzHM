import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LoginForm } from '../components/LoginForm';
import { AppStore } from '../store/AppStore';

const TAG = 'OopzLogin';

@Entry
@Component
struct Login {
  private readonly store: AppStore = AppStore.get();

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) return;
    this.store.bind(ctx);
    this.store.loadUiPrefs(ctx);
    this.tryRestore();
  }

  private goVoice(): void {
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/NativeVoice' }).catch(() => {});
  }

  private async tryRestore(): Promise<void> {
    try {
      const cred = await this.store.restore();
      if (cred !== undefined) this.goVoice();
    } catch {
      hilog.warn(0x0, TAG, 'restore failed');
    }
  }

  build() {
    Stack() {
      LoginForm({ onSignedIn: () => { this.goVoice(); } })
    }
    .width('100%')
    .height('100%')
  }
}
