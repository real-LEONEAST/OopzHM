import { deviceInfo } from '@kit.BasicServicesKit';
import { getTheme } from '../common/Theme';

const IS_PHONE = deviceInfo.deviceType === 'phone';
const ICON_SIZE = IS_PHONE ? '288px' : '256px';
const MARK_RATIO = IS_PHONE ? 272 / 288 : 208 / 256;
// The original ring is centered at (506, 517) with a radius of 339 in the 1024px icon.
const RING_CENTER_X = 0.5 - (6 / 1024) * MARK_RATIO;
const RING_CENTER_Y = 0.5 + (5 / 1024) * MARK_RATIO;
const RING_RADIUS = (339 / 1024) * MARK_RATIO;
const SWEEP_DELAY_MS = 160;
const FADE_MS = 140;

class StartupLayout implements AttributeModifier<StackAttribute> {
  applyNormalAttribute(instance: StackAttribute): void {
    if (deviceInfo.apiAvailable(20)) {
      instance.ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [
        LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM, LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END
      ]);
    }
  }
}

@Component
export struct StartupCover {
  @Prop @Watch('fadeWhenReady') ready: boolean = false;
  @State private visible: boolean = true;
  @State private coverOpacity: number = 1;
  @State private sweepVisible: boolean = false;
  @State private sweepAngle: number = 0;
  @State private sweepOpacity: number = 0;

  // The system window uses the OS theme. Keep that palette until the app surface is revealed.
  private readonly dark: boolean = AppStorage.get<boolean>('oopzSystemIsDark') ?? true;
  private readonly layout: StartupLayout = new StartupLayout();
  private mounted: boolean = false;
  private sweepTimer: number = -1;
  private sweepContext?: CanvasRenderingContext2D;
  private sweepStarted: boolean = false;

  aboutToDisappear(): void {
    this.mounted = false;
    this.clearSweepTimer();
    this.sweepContext = undefined;
  }

  private clearSweepTimer(): void {
    if (this.sweepTimer < 0) return;
    clearTimeout(this.sweepTimer);
    this.sweepTimer = -1;
  }

  private begin(): void {
    this.mounted = true;
    if (this.ready) {
      this.fadeWhenReady();
      return;
    }
    this.sweepTimer = setTimeout(() => {
      this.sweepTimer = -1;
      if (this.mounted && !this.ready) {
        this.sweepContext = new CanvasRenderingContext2D(new RenderingContextSettings(true));
        this.sweepVisible = true;
      }
    }, SWEEP_DELAY_MS);
  }

  private fadeWhenReady(): void {
    if (!this.ready || !this.mounted || this.coverOpacity === 0) return;
    this.clearSweepTimer();
    this.getUIContext().animateTo({
      duration: FADE_MS,
      curve: Curve.EaseOut,
      onFinish: () => {
        if (this.mounted) this.visible = false;
        this.sweepContext = undefined;
      }
    }, () => { this.coverOpacity = 0; });
  }

  private drawSweep(context: CanvasRenderingContext2D): void {
    if (!this.mounted || this.ready) return;
    const size = Math.min(context.width, context.height);
    if (size <= 0) return;
    const x = context.width / 2 + (RING_CENTER_X - 0.5) * size;
    const y = context.height / 2 + (RING_CENTER_Y - 0.5) * size;
    const radius = size * RING_RADIUS;
    const start = -117 * Math.PI / 180;
    const end = -26 * Math.PI / 180;
    const light = context.createLinearGradient(x + radius * Math.cos(start), y + radius * Math.sin(start),
      x + radius * Math.cos(end), y + radius * Math.sin(end));
    light.addColorStop(0, 'rgba(118,255,222,0)');
    light.addColorStop(0.58, this.dark ? 'rgba(113,255,222,0.62)' : 'rgba(17,116,88,0.56)');
    light.addColorStop(1, this.dark ? 'rgba(231,255,249,0.98)' : 'rgba(237,255,245,0.98)');
    context.strokeStyle = light;
    context.lineWidth = size * 0.037;
    context.lineCap = 'round';
    context.beginPath();
    context.arc(x, y, radius, start, end);
    context.stroke();
    if (!this.sweepStarted) {
      this.sweepStarted = true;
      this.animateSweep();
    }
  }

  private animateSweep(): void {
    this.getUIContext().keyframeAnimateTo({
      iterations: 1,
      onFinish: () => {
        if (this.mounted) this.sweepVisible = false;
        this.sweepContext = undefined;
      }
    }, [
      { duration: 65, curve: Curve.EaseIn, event: () => { this.sweepAngle = 40; this.sweepOpacity = 1; } },
      { duration: 230, curve: Curve.Linear, event: () => { this.sweepAngle = 307; } },
      { duration: 60, curve: Curve.EaseOut, event: () => { this.sweepAngle = 360; this.sweepOpacity = 0; } }
    ]);
  }

  @Builder
  private sweep(context: CanvasRenderingContext2D) {
    Canvas(context)
      .width(ICON_SIZE)
      .height(ICON_SIZE)
      .rotate({ angle: this.sweepAngle, centerX: `${RING_CENTER_X * 100}%`, centerY: `${RING_CENTER_Y * 100}%` })
      .opacity(this.sweepOpacity)
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => { this.drawSweep(context); })
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Center }) {
        // HarmonyOS draws the simple starting-window bitmap at its intrinsic pixel size.
        Image($r('app.media.start_window_icon'))
          .width(ICON_SIZE)
          .height(ICON_SIZE)
          .objectFit(ImageFit.Contain)
          .syncLoad(true)
          .draggable(false)
          .hitTestBehavior(HitTestMode.None)
        if (this.sweepVisible && this.sweepContext !== undefined) {
          this.sweep(this.sweepContext)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(getTheme(this.dark).bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .attributeModifier(this.layout)
      .opacity(this.coverOpacity)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityText('正在准备 Oopz')
      .accessibilityLevel(this.ready ? 'no-hide-descendants' : 'yes')
      .onAppear(() => { this.begin(); })
    }
  }
}
