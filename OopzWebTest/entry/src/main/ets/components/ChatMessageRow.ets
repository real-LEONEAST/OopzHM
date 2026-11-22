import { KeyCode } from '@kit.InputKit';
import { AppSpacing, getTheme } from '../common/Theme';
import { OOPZ_EMOJI_FONT_FAMILY } from '../oopz/OopzEmojiFont';
import { OopzChatAttachment } from '../oopz/OopzSession';

export interface ChatMessageItem {
  key: string;
  messageId: string;
  senderUid: string;
  senderName: string;
  senderAvatar: string;
  isSelf: boolean;
  timeText: string;
  cleanText: string;
  textRuns: ChatTextRun[];
  attachments: OopzChatAttachment[];
}

export interface ChatTextRun {
  text: string;
  oopzEmoji: boolean;
}

function isChatImage(att: OopzChatAttachment): boolean {
  const kind = att.attachmentType.toUpperCase();
  return att.url.trim().length > 0 && (kind === 'IMAGE' || kind.startsWith('IMAGE/'));
}

@Component
export struct ChatMessageRow {
  @Prop item: ChatMessageItem;
  @Prop isDark: boolean = true;
  @Prop oopzEmojiFontReady: boolean = false;
  @Prop isDesktop: boolean = false;
  @Prop canRecall: boolean = false;
  onRecallMenu: (item: ChatMessageItem, windowX: number, windowY: number) => void = () => {};
  onPreview: (att: OopzChatAttachment) => void = () => {};

  private handleMouse(event: MouseEvent): void {
    if (this.isDesktop && this.canRecall && event.button === MouseButton.Right && event.action === MouseAction.Press) {
      event.stopPropagation();
      this.onRecallMenu(this.item, event.windowX, event.windowY);
    }
  }

  @Builder
  private textBubble() {
    Text() {
      if (this.item.textRuns.length === 0) {
        Span(this.item.cleanText)
      } else {
        ForEach(this.item.textRuns, (run: ChatTextRun) => {
          if (run.oopzEmoji && this.oopzEmojiFontReady) {
            Span(run.text).fontFamily(OOPZ_EMOJI_FONT_FAMILY).fontSize(21)
          } else {
            Span(run.oopzEmoji ? '[表情]' : run.text).fontSize(14)
          }
        }, (run: ChatTextRun, index: number) => `${index}-${run.text}-${this.oopzEmojiFontReady}`)
      }
    }
      .fontSize(14)
      .fontColor(getTheme(this.isDark).text)
      .lineHeight(this.item.textRuns.length > 0 ? 27 : 20)
      .copyOption(!this.isDesktop && this.canRecall ? CopyOptions.None : CopyOptions.InApp)
      .onMouse((event: MouseEvent) => { this.handleMouse(event); })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(AppSpacing.radiusSm)
      .backgroundColor(this.item.isSelf ? getTheme(this.isDark).tint : getTheme(this.isDark).surface)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
  }

  @Builder
  private thumbnail(att: OopzChatAttachment) {
    Image(att.url)
      .constraintSize({ maxWidth: 260, maxHeight: 200 })
      .borderRadius(12)
      .objectFit(ImageFit.Cover)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
      .draggable(false)
      .accessibilityText(att.displayName || '图片附件')
  }

  @Builder
  private attachment(att: OopzChatAttachment) {
    if (!this.isDesktop && this.canRecall) {
      Stack() { this.thumbnail(att) }
        .gesture(GestureGroup(GestureMode.Exclusive,
          LongPressGesture({ duration: 470 }).onAction(() => { this.onRecallMenu(this.item, 0, 0); }),
          TapGesture().onAction(() => { if (isChatImage(att)) this.onPreview(att); })
        ))
    } else if (isChatImage(att)) {
      Stack() { this.thumbnail(att) }
        .focusable(true).borderRadius(12)
        .accessibilityText('查看大图：' + (att.displayName || '图片附件'))
        .onMouse((event: MouseEvent) => { this.handleMouse(event); })
        .onClick(() => { this.onPreview(att); })
    } else {
      this.thumbnail(att)
    }
  }

  build() {
    Row({ space: 10 }) {
      Stack() {
        Column() {
          Text(this.item.senderName.length > 0 ? this.item.senderName.slice(0, 1).toUpperCase() : 'U')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(getTheme(this.isDark).accent)
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(getTheme(this.isDark).surfaceAlt)
        .justifyContent(FlexAlign.Center)

        if (this.item.senderAvatar.length > 0) {
          Image(this.item.senderAvatar)
            .width(34)
            .height(34)
            .borderRadius(17)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(34)
      .height(34)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.item.senderName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.item.isSelf ? getTheme(this.isDark).accent : getTheme(this.isDark).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.item.timeText)
            .fontSize(11)
            .fontColor(getTheme(this.isDark).textMuted)
        }

        if (this.item.cleanText.length > 0) {
          if (!this.isDesktop && this.canRecall) {
            Stack() { this.textBubble() }
              .gesture(LongPressGesture({ duration: 470 }).onAction(() => { this.onRecallMenu(this.item, 0, 0); }))
          } else {
            this.textBubble()
          }
        }

        if (this.item.attachments.length > 0) {
          Column({ space: 6 }) {
            ForEach(this.item.attachments, (att: OopzChatAttachment, idx: number) => {
              this.attachment(att)
            }, (att: OopzChatAttachment, idx: number) => `${att.fileKey}_${idx}_${att.url}`)
          }
          .alignItems(HorizontalAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 4, bottom: 4 })
    .id('chat-message-' + this.item.key).focusable(true)
    .onMouse((event: MouseEvent) => { this.handleMouse(event); })
  }
}

const MENU_WIDTH: number = 178;
const MENU_HEIGHT: number = 100;
const MENU_EDGE: number = 6;

@Component
export struct ChatRecallOverlay {
  @Prop item: ChatMessageItem;
  @Prop isDark: boolean = true;
  @Prop isDesktop: boolean = false;
  @Prop windowX: number = 0;
  @Prop windowY: number = 0;
  @Prop @Watch('focusOverlay') confirming: boolean = false;
  @Prop @Watch('focusOverlay') busy: boolean = false;
  onDismiss: () => void = () => {};
  onChooseRecall: () => void = () => {};
  onSubmit: () => void = () => {};

  @State private viewportWidth: number = MENU_WIDTH + MENU_EDGE * 2;
  @State private viewportHeight: number = MENU_HEIGHT + MENU_EDGE * 2;
  @State private originX: number = 0;
  @State private originY: number = 0;
  private focusTimer: number = -1;
  private firstFocused: boolean = true;

  aboutToAppear(): void { this.focusOverlay(); }

  aboutToDisappear(): void { clearTimeout(this.focusTimer); }

  private focusOverlay(): void {
    clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout(() => {
      this.getUIContext().getFocusController().requestFocus(this.busy ? 'chat-recall-overlay' : 'chat-recall-first');
    }, 0);
  }

  private onOverlayKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) return false;
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      if (!this.busy) this.onDismiss();
    } else if (event.keyCode === KeyCode.KEYCODE_TAB) {
      if (!this.busy) this.getUIContext().getFocusController().requestFocus(this.firstFocused ? 'chat-recall-second' : 'chat-recall-first');
    } else {
      return false;
    }
    event.stopPropagation();
    return true;
  }

  private excerpt(): string {
    if (this.item.cleanText.trim().length > 0) return this.item.cleanText;
    const att = this.item.attachments[0];
    if (att === undefined) return this.item.senderName + '的消息';
    return (isChatImage(att) ? '[图片]' : '[附件]') + (att.displayName ? ' ' + att.displayName : '');
  }

  @Builder
  private menu() {
    Column({ space: 4 }) {
      Button('撤回消息…', { type: ButtonType.Normal }).id('chat-recall-first')
        .width('100%').height(42).borderRadius(8).backgroundColor(Color.Transparent)
        .fontColor(this.isDark ? '#FFB4AF' : getTheme(this.isDark).dangerFill)
        .onFocus(() => { this.firstFocused = true; }).onClick(() => { this.onChooseRecall(); })
      Button('取消', { type: ButtonType.Normal }).id('chat-recall-second')
        .width('100%').height(42).borderRadius(8).backgroundColor(Color.Transparent)
        .fontColor(getTheme(this.isDark).text)
        .onFocus(() => { this.firstFocused = false; }).onClick(() => { this.onDismiss(); })
    }.width('100%').padding(6).borderRadius(AppSpacing.radiusSm)
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
      .border({ width: 1, color: getTheme(this.isDark).border })
  }

  @Builder
  private confirmation() {
    Column({ space: 12 }) {
      Text('撤回这条消息？').fontSize(18).fontWeight(FontWeight.Medium).fontColor(getTheme(this.isDark).text)
      Text(this.excerpt()).width('100%').fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
        .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Button('取消').id('chat-recall-first').height(36).fontSize(14).enabled(!this.busy)
          .backgroundColor(getTheme(this.isDark).surfaceAlt).fontColor(getTheme(this.isDark).text)
          .onFocus(() => { this.firstFocused = true; }).onClick(() => { this.onDismiss(); })
        Button(this.busy ? '正在撤回…' : '确认撤回').id('chat-recall-second').height(36).fontSize(14).enabled(!this.busy)
          .backgroundColor(getTheme(this.isDark).dangerFill).fontColor(getTheme(this.isDark).dangerText)
          .onFocus(() => { this.firstFocused = false; }).onClick(() => { if (!this.busy) this.onSubmit(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }.width('90%').constraintSize({ maxWidth: 340 }).padding(AppSpacing.card).borderRadius(AppSpacing.radius)
      .backgroundColor(getTheme(this.isDark).surfaceSolid).alignItems(HorizontalAlign.Start)
      .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
  }

  build() {
    Stack({ alignContent: this.confirming ? Alignment.Center : (this.isDesktop ? Alignment.TopStart : Alignment.Bottom) }) {
      Column().width('100%').height('100%').backgroundColor('#64000000')
        .onClick(() => { if (!this.confirming && !this.busy) this.onDismiss(); })
      if (this.confirming) {
        this.confirmation()
      } else if (this.isDesktop) {
        Column() { this.menu() }
          .width(Math.min(MENU_WIDTH, Math.max(1, this.viewportWidth - MENU_EDGE * 2)))
          .position({
            x: Math.max(MENU_EDGE, Math.min(this.windowX - this.originX, this.viewportWidth - MENU_WIDTH - MENU_EDGE)),
            y: Math.max(MENU_EDGE, Math.min(this.windowY - this.originY, this.viewportHeight - MENU_HEIGHT - MENU_EDGE))
          })
      } else {
        Column() { this.menu() }.width('100%').padding({ left: 10, right: 10, bottom: 10 })
      }
    }.width('100%').height('100%').id('chat-recall-overlay').focusable(true)
      .onAreaChange((_previous: Area, area: Area) => {
        this.viewportWidth = Number(area.width);
        this.viewportHeight = Number(area.height);
        this.originX = Number(area.globalPosition.x ?? 0);
        this.originY = Number(area.globalPosition.y ?? 0);
      })
      .onKeyEvent((event: KeyEvent): boolean => this.onOverlayKey(event))
  }
}
