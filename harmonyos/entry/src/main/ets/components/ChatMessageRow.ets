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
  reference?: ChatReferenceView;
}

export interface ChatReferenceView {
  author: string;
  excerpt: string;
}

export interface ChatTextRun {
  text: string;
  oopzEmoji: boolean;
}

function isChatImage(att: OopzChatAttachment): boolean {
  const kind = att.attachmentType.toUpperCase();
  return att.url.trim().length > 0 && (kind === 'IMAGE' || kind === 'RAWIMAGE' || kind.startsWith('IMAGE/'));
}

export function chatMessageExcerpt(text: string, attachments: OopzChatAttachment[]): string {
  if (text.trim()) return text;
  if (attachments.length === 0) return '消息';
  return attachments.some((attachment: OopzChatAttachment): boolean => isChatImage(attachment)) ? '[图片]' : '[附件]';
}

@Component
export struct ChatReferenceStrip {
  @Prop reference: ChatReferenceView;
  @Prop isDark: boolean = true;
  @Prop inComposer: boolean = false;
  @Prop canRemove: boolean = false;
  onRemove: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column()
        .width(3).height(26).borderRadius(2).backgroundColor(getTheme(this.isDark).accent)
      Column({ space: 2 }) {
        if (this.reference.author) {
          Text(this.reference.author).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(getTheme(this.isDark).text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.reference.excerpt).fontSize(12).fontColor(getTheme(this.isDark).textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.inComposer) {
        Button('×').width(34).height(34).fontSize(18).backgroundColor(Color.Transparent)
          .fontColor(getTheme(this.isDark).textSecondary).accessibilityText('取消引用')
          .enabled(this.canRemove).onClick(() => { this.onRemove(); })
      }
    }.width('100%').constraintSize(this.inComposer ? {} : { maxWidth: 260 })
      .padding({ left: 9, right: 8, top: 4, bottom: 4 })
      .borderRadius(8).backgroundColor(getTheme(this.isDark).surfaceAlt)
  }
}

@Component
export struct ChatMessageRow {
  @Prop item: ChatMessageItem;
  @Prop isDark: boolean = true;
  @Prop oopzEmojiFontReady: boolean = false;
  @Prop isDesktop: boolean = false;
  onMessageMenu: (item: ChatMessageItem, windowX: number, windowY: number) => void = () => {};
  onPreview: (att: OopzChatAttachment) => void = () => {};
  private readonly textController: TextController = new TextController();
  private selectionMenuTimer: number = -1;

  aboutToDisappear(): void { clearTimeout(this.selectionMenuTimer); }

  private hasActions(): boolean {
    return this.item.messageId.length > 0;
  }

  private readonly textMenu: EditMenuOptions = {
    onCreateMenu: (items: TextMenuItem[]): TextMenuItem[] => {
      if (!this.isDesktop || !this.hasActions()) return items;
      // ArkUI creates a dismissible selection overlay even for an empty item list.
      // Release it after creation so the first click reaches the message action.
      clearTimeout(this.selectionMenuTimer);
      this.selectionMenuTimer = setTimeout(() => { this.textController.closeSelectionMenu(); }, 0);
      return [];
    },
    onMenuItemClick: (_item: TextMenuItem, _range: TextRange): boolean => false
  };

  private handleMouse(event: MouseEvent): void {
    if (this.isDesktop && this.hasActions() && event.button === MouseButton.Right && event.action === MouseAction.Press) {
      event.stopPropagation();
      this.onMessageMenu(this.item, event.windowX, event.windowY);
    }
  }

  @Builder
  private textBubble() {
    Text(undefined, { controller: this.textController }) {
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
      .copyOption(!this.isDesktop && this.hasActions() ? CopyOptions.None : CopyOptions.InApp)
      .editMenuOptions(this.textMenu)
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
    if (!this.isDesktop && this.hasActions()) {
      Stack() { this.thumbnail(att) }
        .gesture(GestureGroup(GestureMode.Exclusive,
          LongPressGesture({ duration: 470 }).onAction(() => { this.onMessageMenu(this.item, 0, 0); }),
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

        if (this.item.reference !== undefined) {
          ChatReferenceStrip({ reference: this.item.reference, isDark: this.isDark })
        }

        if (this.item.cleanText.length > 0) {
          if (!this.isDesktop && this.hasActions()) {
            Stack() { this.textBubble() }
              .gesture(LongPressGesture({ duration: 470 }).onAction(() => { this.onMessageMenu(this.item, 0, 0); }))
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
const MENU_ROW_HEIGHT: number = 42;
const MENU_SPACING: number = 4;
const MENU_PADDING: number = 6;
const MENU_EDGE: number = 6;
const MENU_REPLY = 'chat-action-reply';
const MENU_COPY = 'chat-action-copy';
const MENU_RECALL = 'chat-action-recall';
const MENU_CANCEL = 'chat-action-cancel';
const MENU_CONFIRM = 'chat-action-confirm';
const MENU_OVERLAY = 'chat-action-overlay';

@Component
export struct ChatMessageActions {
  @Prop item: ChatMessageItem;
  @Prop isDark: boolean = true;
  @Prop isDesktop: boolean = false;
  @Prop windowX: number = 0;
  @Prop windowY: number = 0;
  @Prop @Watch('focusOverlay') confirming: boolean = false;
  @Prop @Watch('focusOverlay') busy: boolean = false;
  onDismiss: () => void = () => {};
  onReply: () => void = () => {};
  onCopy: () => void = () => {};
  onChooseRecall: () => void = () => {};
  onSubmit: () => void = () => {};

  @State private viewportWidth: number = MENU_WIDTH + MENU_EDGE * 2;
  @State private viewportHeight: number = 200;
  @State private originX: number = 0;
  @State private originY: number = 0;
  private focusTimer: number = -1;
  private focusedItem: string = '';

  aboutToAppear(): void { this.focusOverlay(); }

  aboutToDisappear(): void { clearTimeout(this.focusTimer); }

  private focusOverlay(): void {
    clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout(() => {
      const first = this.busy ? MENU_OVERLAY : this.menuItems()[0];
      this.getUIContext().getFocusController().requestFocus(first);
    }, 0);
  }

  private menuItems(): string[] {
    if (this.confirming) return [MENU_CANCEL, MENU_CONFIRM];
    const items = [MENU_REPLY];
    if (this.item.cleanText.trim()) items.push(MENU_COPY);
    if (this.item.isSelf) items.push(MENU_RECALL);
    items.push(MENU_CANCEL);
    return items;
  }

  private menuHeight(): number {
    const count = this.menuItems().length;
    return count * MENU_ROW_HEIGHT + (count - 1) * MENU_SPACING + MENU_PADDING * 2;
  }

  private onOverlayKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) return false;
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      if (!this.busy) this.onDismiss();
    } else if (event.keyCode === KeyCode.KEYCODE_TAB) {
      if (!this.busy) {
        const items = this.menuItems();
        const index = items.indexOf(this.focusedItem);
        const direction = event.getModifierKeyState?.(['Shift']) ? -1 : 1;
        const next = index < 0 ? 0 : (index + direction + items.length) % items.length;
        this.getUIContext().getFocusController().requestFocus(items[next]);
      }
    } else {
      return false;
    }
    event.stopPropagation();
    return true;
  }

  @Builder
  private menuButton(label: string, key: string, action: () => void) {
    Button(label, { type: ButtonType.Normal }).id(key)
      .width('100%').height(MENU_ROW_HEIGHT).borderRadius(8).backgroundColor(Color.Transparent)
      .fontColor(key === MENU_RECALL ? (this.isDark ? '#FFB4AF' : getTheme(this.isDark).dangerFill) :
        getTheme(this.isDark).text)
      .onFocus(() => { this.focusedItem = key; }).onClick(action)
  }

  @Builder
  private menu() {
    Column({ space: MENU_SPACING }) {
      this.menuButton('引用回复', MENU_REPLY, () => { this.onReply(); })
      if (this.item.cleanText.trim()) {
        this.menuButton('复制文字', MENU_COPY, () => { this.onCopy(); })
      }
      if (this.item.isSelf) {
        this.menuButton('撤回消息…', MENU_RECALL, () => { this.onChooseRecall(); })
      }
      this.menuButton('取消', MENU_CANCEL, () => { this.onDismiss(); })
    }.width('100%').padding(MENU_PADDING).borderRadius(AppSpacing.radiusSm)
      .backgroundColor(getTheme(this.isDark).surfaceSolid)
      .border({ width: 1, color: getTheme(this.isDark).border })
  }

  @Builder
  private confirmation() {
    Column({ space: 12 }) {
      Text('撤回这条消息？').fontSize(18).fontWeight(FontWeight.Medium).fontColor(getTheme(this.isDark).text)
      Text(chatMessageExcerpt(this.item.cleanText, this.item.attachments)).width('100%')
        .fontSize(14).fontColor(getTheme(this.isDark).textSecondary)
        .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Button('取消').id(MENU_CANCEL).height(36).fontSize(14).enabled(!this.busy)
          .backgroundColor(getTheme(this.isDark).surfaceAlt).fontColor(getTheme(this.isDark).text)
          .onFocus(() => { this.focusedItem = MENU_CANCEL; }).onClick(() => { this.onDismiss(); })
        Button(this.busy ? '正在撤回…' : '确认撤回').id(MENU_CONFIRM).height(36).fontSize(14).enabled(!this.busy)
          .backgroundColor(getTheme(this.isDark).dangerFill).fontColor(getTheme(this.isDark).dangerText)
          .onFocus(() => { this.focusedItem = MENU_CONFIRM; }).onClick(() => { if (!this.busy) this.onSubmit(); })
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
            y: Math.max(MENU_EDGE, Math.min(this.windowY - this.originY, this.viewportHeight - this.menuHeight() - MENU_EDGE))
          })
      } else {
        Column() { this.menu() }.width('100%').padding({ left: 10, right: 10, bottom: 10 })
      }
    }.width('100%').height('100%').id(MENU_OVERLAY).focusable(true)
      .onAreaChange((_previous: Area, area: Area) => {
        this.viewportWidth = Number(area.width);
        this.viewportHeight = Number(area.height);
        this.originX = Number(area.globalPosition.x ?? 0);
        this.originY = Number(area.globalPosition.y ?? 0);
      })
      .onKeyEvent((event: KeyEvent): boolean => this.onOverlayKey(event))
  }
}
