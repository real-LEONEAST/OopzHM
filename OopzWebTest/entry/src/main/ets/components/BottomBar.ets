import { AppSpacing, getTheme } from '../common/Theme';
import { AppStore } from '../store/AppStore';

// Floating spatial-glass bottom navigation dock + optional global mini call capsule.
@Component
export struct BottomBar {
  @Prop active: string = 'voice';
  @Prop showMiniBar: boolean = true;
  onNavigate?: (key: string) => void;
  onReturnRoom?: () => void;

  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzInCall') private inCall: boolean = false;
  @StorageProp('oopzCallChannelName') private callChannelName: string = '';
  @StorageProp('oopzCallMuted') private callMuted: boolean = false;
  @StorageProp('oopzHandGrip') private handGrip: string = 'center';
  private gripLockSource?: string;

  aboutToDisappear(): void {
    this.releaseDockGrip();
  }

  private handleDockTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down && this.gripLockSource === undefined) {
      const source = `bottom-dock-${this.active}`;
      this.gripLockSource = source;
      AppStore.get().setGripInteractionActive(source, true);
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.releaseDockGrip();
    }
  }

  private releaseDockGrip(): void {
    const source = this.gripLockSource;
    if (source !== undefined) {
      this.gripLockSource = undefined;
      AppStore.get().setGripInteractionActive(source, false);
    }
  }

  private go(key: string): void {
    if (key === this.active) {
      return;
    }
    if (this.onNavigate !== undefined) {
      this.onNavigate(key);
      return;
    }
    const router = this.getUIContext().getRouter();
    if (key === 'account') {
      router.pushUrl({ url: 'pages/Account' }).catch(() => {});
    } else {
      if (router.getStateByUrl('pages/NativeVoice').length > 0) {
        router.back();
      } else {
        router.replaceUrl({ url: 'pages/NativeVoice' }).catch(() => {});
      }
    }
  }

  private openActiveRoom(): void {
    if (this.onReturnRoom !== undefined) {
      this.onReturnRoom();
      return;
    }
    AppStorage.setOrCreate<boolean>('oopzRequestReturnRoom', true);
    const router = this.getUIContext().getRouter();
    if (router.getStateByUrl('pages/NativeVoice').length > 0) {
      router.back();
    } else {
      router.replaceUrl({ url: 'pages/NativeVoice' }).catch(() => {});
    }
  }

  private alignOfGrip(): HorizontalAlign {
    if (this.handGrip === 'left') {
      return HorizontalAlign.Start;
    }
    if (this.handGrip === 'right') {
      return HorizontalAlign.End;
    }
    return HorizontalAlign.Center;
  }

  @Builder
  private tabItem(label: string, key: string) {
    Column({ space: 2 }) {
      SymbolGlyph(key === 'voice' ? $r('sys.symbol.waveform') : $r('sys.symbol.person'))
        .fontSize(15)
        .fontColor([this.active === key ? getTheme(this.isDark).accent : getTheme(this.isDark).textMuted])
      Text(label)
        .fontSize(11)
        .fontColor(this.active === key ? getTheme(this.isDark).accent : getTheme(this.isDark).textMuted)
        .fontWeight(this.active === key ? FontWeight.Medium : FontWeight.Normal)
    }
    .width(76)
    .height(42)
    .borderRadius(AppSpacing.radiusLg)
    .backgroundColor(this.active === key ? getTheme(this.isDark).accentSoft : Color.Transparent)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(label)
    .onClick(() => { this.go(key); })
  }

  build() {
    Column({ space: 8 }) {
      if (this.inCall && this.showMiniBar) {
        Row({ space: 8 }) {
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(getTheme(this.isDark).speaking)
          Text(`${this.callChannelName.length > 0 ? this.callChannelName : '语音频道'} · 通话中`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 200 })
          Text(this.callMuted ? '已闭麦' : '开麦')
            .fontSize(11)
            .fontColor(this.callMuted ? getTheme(this.isDark).warn : getTheme(this.isDark).speaking)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(AppSpacing.radiusSm)
            .backgroundColor(this.callMuted ? getTheme(this.isDark).warnSoft : getTheme(this.isDark).speakingSoft)
        }
        .height(40)
        .padding({ left: 14, right: 10 })
        .borderRadius(AppSpacing.radiusLg)
        .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
        .shadow({ radius: 18, color: getTheme(this.isDark).shadowColor, offsetY: 6 })
        .backgroundColor(getTheme(this.isDark).surfaceSolid)
        .onTouch((event: TouchEvent) => { this.handleDockTouch(event); })
        .onClick(() => { this.openActiveRoom(); })
      }

      Row({ space: 4 }) {
        this.tabItem('频道', 'voice')
        this.tabItem('我的', 'account')
      }
      .padding(4)
      .borderRadius(AppSpacing.radiusLg)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
      .shadow({ radius: 22, color: getTheme(this.isDark).shadowColor, offsetY: 8 })
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
      .onTouch((event: TouchEvent) => { this.handleDockTouch(event); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(this.alignOfGrip())
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
