import { getTheme, ImmersiveChrome } from '../common/Theme';

// Floating spatial-glass bottom navigation dock + optional global mini call capsule.
@Component
export struct BottomBar {
  @Prop active: string = 'voice';
  @Prop showMiniBar: boolean = true;
  onReturnRoom?: () => void;

  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzImmersiveLight') private immersiveLight: boolean = true;
  @StorageProp('oopzInCall') private inCall: boolean = false;
  @StorageProp('oopzCallChannelName') private callChannelName: string = '';
  @StorageProp('oopzCallMuted') private callMuted: boolean = false;
  @StorageProp('oopzHandGrip') @Watch('updateGrip') private handGrip: string = 'center';
  @State private dockGrip: string = 'center';
  private touchingDock: boolean = false;

  aboutToAppear(): void {
    this.updateGrip();
  }

  private updateGrip(): void {
    if (!this.touchingDock) this.dockGrip = this.handGrip;
  }

  private go(key: string): void {
    if (key === this.active) {
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
    if (this.dockGrip === 'left') {
      return HorizontalAlign.Start;
    }
    if (this.dockGrip === 'right') {
      return HorizontalAlign.End;
    }
    return HorizontalAlign.Center;
  }

  @Builder
  private tabItem(label: string, badge: string, key: string) {
    Column({ space: 2 }) {
      Text(badge)
        .fontSize(13)
        .fontColor(this.active === key ? getTheme(this.isDark).accent : getTheme(this.isDark).textMuted)
      Text(label)
        .fontSize(11)
        .fontColor(this.active === key ? getTheme(this.isDark).accent : getTheme(this.isDark).textMuted)
        .fontWeight(this.active === key ? FontWeight.Medium : FontWeight.Normal)
    }
    .width(76)
    .height(42)
    .borderRadius(21)
    .backgroundColor(this.active === key ? getTheme(this.isDark).accentSoft : Color.Transparent)
    .justifyContent(FlexAlign.Center)
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
            .borderRadius(10)
            .backgroundColor(this.callMuted ? getTheme(this.isDark).warnSoft : getTheme(this.isDark).speakingSoft)
        }
        .height(40)
        .padding({ left: 14, right: 10 })
        .borderRadius(20)
        .backgroundColor(getTheme(this.isDark).surfaceSolid)
        .attributeModifier(new ImmersiveChrome(this.immersiveLight, this.isDark, 1, true))
        .border({ width: 1, color: getTheme(this.isDark).specularBorder })
        .shadow({ radius: 18, color: getTheme(this.isDark).shadowColor, offsetY: 6 })
        .onClick(() => { this.openActiveRoom(); })
      }

      Row({ space: 4 }) {
        this.tabItem('频道', '◎', 'voice')
        this.tabItem('我的', '●', 'account')
      }
      .padding(4)
      .borderRadius(26)
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
      .attributeModifier(new ImmersiveChrome(this.immersiveLight, this.isDark, 1, true))
      .border({ width: 1, color: getTheme(this.isDark).specularBorder })
      .shadow({ radius: 22, color: getTheme(this.isDark).shadowColor, offsetY: 8 })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) this.touchingDock = true;
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.touchingDock = false;
          this.updateGrip();
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(this.alignOfGrip())
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
