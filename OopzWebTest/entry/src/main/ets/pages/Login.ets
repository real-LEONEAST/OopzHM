import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStore } from '../store/AppStore';
import { AppSpacing, getTheme } from '../common/Theme';

const TAG = 'OopzLogin';

@Entry
@Component
struct Login {
  @State private phone: string = '';
  @State private password: string = '';
  @State private busy: boolean = false;
  @State private notice: string = '';
  @StorageProp('oopzIsDark') private isDark: boolean = true;
  private readonly store: AppStore = AppStore.get();

  aboutToAppear(): void {
    const ctx = this.context();
    if (ctx !== undefined) {
      this.store.bind(ctx);
      this.store.loadUiPrefs(ctx);
    }
    this.tryRestore();
  }

  private context(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private goVoice(): void {
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/NativeVoice' }).catch(() => {});
  }

  private async tryRestore(): Promise<void> {
    const ctx = this.context();
    if (ctx === undefined) return;
    this.store.bind(ctx);
    try {
      const cred = await this.store.restore();
      if (cred !== undefined) {
        this.goVoice();
      }
    } catch {
      hilog.warn(0x0, TAG, 'restore failed');
    }
  }

  private async doLogin(): Promise<void> {
    if (this.busy || this.phone.trim().length === 0 || this.password.length === 0) {
      return;
    }
    const ctx = this.context();
    if (ctx === undefined) {
      this.notice = '无法获取应用上下文';
      return;
    }
    this.store.bind(ctx);
    this.busy = true;
    this.notice = '正在登录 Oopz';
    try {
      const deviceId = await this.store.loadDeviceId();
      const cred = await this.store.login(this.phone.trim(), this.password, deviceId);
      this.password = '';
      hilog.info(0x0, TAG, 'login ok uid=%{public}s', cred.personUid);
      await this.store.loadSelfProfile();
      this.goVoice();
    } catch (error) {
      this.notice = (error as Error).message;
      hilog.error(0x0, TAG, 'login failed: %{public}s', (error as Error).message);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private field(label: string, value: string, changed: (v: string) => void, type: InputType) {
    Column({ space: 6 }) {
      Text(label).fontSize(13).fontColor(getTheme(this.isDark).textSecondary)
      TextInput({ text: value })
        .type(type)
        .fontColor(getTheme(this.isDark).text)
        .placeholderColor(getTheme(this.isDark).textMuted)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .height(46)
        .borderRadius(12)
        .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
        .onChange(changed)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      Column() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Image($r('app.media.app_icon')).width(52).height(52)

            Column({ space: 2 }) {
              Text($r('app.string.app_name')).fontSize(24).fontWeight(FontWeight.Bold).fontColor(getTheme(this.isDark).text)
              Text('鸿蒙语音与域社区').fontSize(12).fontColor(getTheme(this.isDark).textMuted)
            }
            .alignItems(HorizontalAlign.Start)
          }

          Text('登录 Oopz 账号，同步你的域、文字频道与实时语音通话')
            .fontSize(13)
            .fontColor(getTheme(this.isDark).textSecondary)

          this.field('手机号', this.phone, (v: string) => { this.phone = v; }, InputType.PhoneNumber)
          this.field('密码', this.password, (v: string) => { this.password = v; }, InputType.Password)

          Button(this.busy ? '登录中…' : '登录')
            .width('100%')
            .height(46)
            .borderRadius(12)
            .backgroundColor(getTheme(this.isDark).accent)
            .fontColor(getTheme(this.isDark).accentText)
            .fontWeight(FontWeight.Medium)
            .shadow({ radius: 16, color: getTheme(this.isDark).accentSoft, offsetY: 4 })
            .enabled(!this.busy && this.phone.trim().length > 0 && this.password.length > 0)
            .onClick(() => { this.doLogin(); })

          if (this.notice.length > 0) {
            Text(this.notice).fontSize(13).fontColor(getTheme(this.isDark).warn)
          }

          Text('会话凭据采用系统 Asset Store 加密保存于本机。')
            .fontSize(11)
            .fontColor(getTheme(this.isDark).textMuted)
        }
        .width('100%')
        .constraintSize({ maxWidth: 410 })
        .padding(AppSpacing.page)
        .backgroundColor(getTheme(this.isDark).surface)
        .borderRadius(22)
        .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
        .shadow({ radius: 28, color: getTheme(this.isDark).shadowColor, offsetY: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .padding(16)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(getTheme(this.isDark).bg)
  }
}
