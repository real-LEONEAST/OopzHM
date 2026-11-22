import { getTheme } from '../common/Theme';

const MAX_ZOOM = 4;
const CLOSE_BUTTON = 'chat-image-preview-close';

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

@Component
export struct ChatImagePreview {
  @Prop @Watch('resetImage') imageUrl: string = '';
  @Prop imageName: string = '';
  @Prop isDesktop: boolean = false;
  onClose: () => void = () => {};

  @State private zoom: number = 1;
  @State private panX: number = 0;
  @State private panY: number = 0;
  @State private loaded: boolean = false;
  @State private failed: boolean = false;
  @State private compactWindow: boolean = false;

  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private sourceWidth: number = 0;
  private sourceHeight: number = 0;
  private startZoom: number = 1;
  private pinchAnchorX: number = 0;
  private pinchAnchorY: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private pinching: boolean = false;
  private canDrag: boolean = false;
  private focusRequested: boolean = false;
  private lastWheelTime: number = -1;

  private resetImage(): void {
    this.zoom = 1;
    this.panX = 0;
    this.panY = 0;
    this.sourceWidth = 0;
    this.sourceHeight = 0;
    this.loaded = false;
    this.failed = false;
    this.pinching = false;
    this.canDrag = false;
    this.lastWheelTime = -1;
  }

  private moveTo(x: number, y: number): void {
    if (this.sourceWidth <= 0 || this.sourceHeight <= 0) return;
    const fit = Math.min(this.surfaceWidth / this.sourceWidth, this.surfaceHeight / this.sourceHeight);
    const limitX = Math.max(0, (this.sourceWidth * fit * this.zoom - this.surfaceWidth) / 2);
    const limitY = Math.max(0, (this.sourceHeight * fit * this.zoom - this.surfaceHeight) / 2);
    this.panX = clamp(x, -limitX, limitX);
    this.panY = clamp(y, -limitY, limitY);
  }

  private zoomAt(next: number, x: number = 0, y: number = 0): void {
    if (!this.loaded) return;
    const zoom = clamp(next, 1, MAX_ZOOM);
    const ratio = zoom / this.zoom;
    this.zoom = zoom;
    this.moveTo(x - (x - this.panX) * ratio, y - (y - this.panY) * ratio);
  }

  private startPinch(event: GestureEvent): void {
    this.pinching = this.loaded;
    this.canDrag = false;
    this.startZoom = this.zoom;
    this.pinchAnchorX = (event.pinchCenterX - this.surfaceWidth / 2 - this.panX) / this.zoom;
    this.pinchAnchorY = (event.pinchCenterY - this.surfaceHeight / 2 - this.panY) / this.zoom;
  }

  private updatePinch(event: GestureEvent): void {
    if (!this.pinching || !Number.isFinite(event.scale) || event.scale <= 0) return;
    this.zoom = clamp(this.startZoom * event.scale, 1, MAX_ZOOM);
    this.moveTo(event.pinchCenterX - this.surfaceWidth / 2 - this.pinchAnchorX * this.zoom,
      event.pinchCenterY - this.surfaceHeight / 2 - this.pinchAnchorY * this.zoom);
  }

  private handlePan(event: GestureEvent, beginning: boolean): void {
    if (!this.loaded || this.pinching) return;
    const wheel = event.axisVertical ?? 0;
    if (this.isDesktop && wheel !== 0) {
      this.canDrag = false;
      if (event.timestamp !== this.lastWheelTime) {
        this.lastWheelTime = event.timestamp;
        const finger = event.fingerList[0];
        const x = finger ? finger.localX - this.surfaceWidth / 2 : 0;
        const y = finger ? finger.localY - this.surfaceHeight / 2 : 0;
        this.zoomAt(this.zoom + (wheel < 0 ? 0.25 : -0.25), x, y);
      }
    } else if (beginning) {
      this.canDrag = this.zoom > 1;
      this.dragStartX = this.panX;
      this.dragStartY = this.panY;
    } else if (this.canDrag) {
      this.moveTo(this.dragStartX + event.offsetX, this.dragStartY + event.offsetY);
    }
  }

  @Builder
  private closeButton() {
    Button(this.isDesktop ? '关闭 ×' : '‹ 返回聊天')
      .id(CLOSE_BUTTON).defaultFocus(true).fontSize(15).fontColor(getTheme(true).text)
      .backgroundColor(getTheme(true).surfaceAlt).accessibilityText('关闭图片预览，返回聊天')
      .onAreaChange(() => {
        if (!this.focusRequested) {
          try {
            this.getUIContext().getFocusController().requestFocus(CLOSE_BUTTON);
            this.focusRequested = true;
          } catch {
            // The window may have lost focus before this layout callback ran.
          }
        }
      })
      .onClick(() => { this.onClose(); })
  }

  @Builder
  private title() {
    Text(this.imageName || '图片预览').layoutWeight(1).fontSize(16).fontColor(getTheme(true).text)
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(this.isDesktop ? TextAlign.Start : TextAlign.End)
  }

  @Builder
  private photo(url: string) {
    Stack() {
      Image(url)
        .width('100%').height('100%').objectFit(ImageFit.Contain).draggable(false)
        .accessibilityText(this.imageName || '聊天图片')
        .scale({ x: this.zoom, y: this.zoom })
        .onComplete(event => {
          if (!event || url !== this.imageUrl || event.width <= 0 || event.height <= 0) return;
          this.sourceWidth = event.width;
          this.sourceHeight = event.height;
          this.loaded = true;
          this.moveTo(this.panX, this.panY);
        })
        .onError(() => {
          if (url !== this.imageUrl) return;
          this.loaded = false;
          this.failed = true;
        })
    }.width('100%').height('100%').translate({ x: this.panX, y: this.panY })
  }

  @Builder
  private imageSurface() {
    Stack() {
      if (this.failed || !this.imageUrl) {
        Column({ space: 12 }) {
          Text('图片加载失败').fontColor(getTheme(true).text)
          if (this.imageUrl) {
            Button('重新加载').fontColor(getTheme(true).text).backgroundColor(getTheme(true).surfaceAlt)
              .onClick(() => { this.resetImage(); })
          }
        }
      } else {
        ForEach([this.imageUrl], (url: string) => { this.photo(url) }, (url: string) => url)
        if (!this.loaded) {
          LoadingProgress().width(32).height(32).color(getTheme(true).accent).accessibilityText('正在加载图片')
        }
      }
    }.width('100%').layoutWeight(1).clip(true)
      .onAreaChange((_old: Area, area: Area) => {
        this.surfaceWidth = Number(area.width);
        this.surfaceHeight = Number(area.height);
        this.moveTo(this.panX, this.panY);
      })
      .gesture(GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2 }).onActionStart((e: GestureEvent) => { this.startPinch(e); })
          .onActionUpdate((e: GestureEvent) => { this.updatePinch(e); })
          .onActionEnd(() => { this.pinching = false; }).onActionCancel(() => { this.pinching = false; }),
        PanGesture({ fingers: 1, direction: PanDirection.All })
          .onActionStart((e: GestureEvent) => { this.handlePan(e, true); })
          .onActionUpdate((e: GestureEvent) => { this.handlePan(e, false); })
      ))
  }

  @Builder
  private zoomButton(increase: boolean) {
    Button(increase ? '＋' : '−').width(44).height(40).fontSize(20)
      .backgroundColor(getTheme(true).surfaceAlt).fontColor(getTheme(true).text)
      .accessibilityText(increase ? '放大图片' : '缩小图片')
      .enabled(this.loaded && (increase ? this.zoom < MAX_ZOOM : this.zoom > 1))
      .onClick(() => { this.zoomAt(this.zoom + (increase ? 0.5 : -0.5)); })
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 12 }) {
          if (this.isDesktop) {
            this.title()
            this.closeButton()
          } else {
            this.closeButton()
            this.title()
          }
        }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })

        this.imageSurface()

        Row({ space: 12 }) {
          if (this.isDesktop) { this.zoomButton(false) }
          Text(Math.round(this.zoom * 100) + '%').fontSize(14).fontColor(getTheme(true).text)
            .accessibilityText('缩放比例 ' + Math.round(this.zoom * 100) + '%')
          if (this.isDesktop) { this.zoomButton(true) }
        }.width('100%').height(54).justifyContent(FlexAlign.Center)
      }
      .width(this.isDesktop ? (this.compactWindow ? '94%' : '84%') : '100%')
      .height(this.isDesktop ? (this.compactWindow ? '90%' : '86%') : '100%')
      .backgroundColor('#18221F').borderRadius(this.isDesktop ? 12 : 0)
      .border({ width: this.isDesktop ? 1 : 0, color: getTheme(true).border }).clip(true)
    }.width('100%').height('100%').backgroundColor('#9918221F')
      .onAreaChange((_old: Area, area: Area) => { this.compactWindow = Number(area.width) <= 600; })
  }
}
