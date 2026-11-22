import { getTheme } from '../common/Theme';

interface ChatEmoji {
  value: string;
  label: string;
}

const CHAT_EMOJIS: ChatEmoji[] = [
  { value: '😀', label: '笑脸' },
  { value: '😂', label: '笑哭' },
  { value: '😊', label: '微笑' },
  { value: '🤔', label: '思考' },
  { value: '😭', label: '大哭' },
  { value: '👍', label: '点赞' },
  { value: '🙌', label: '举手庆祝' },
  { value: '🙏', label: '合十' },
  { value: '🎉', label: '礼花' },
  { value: '🔥', label: '火焰' },
  { value: '❤️', label: '红心' },
  { value: '👀', label: '眼睛' },
  { value: '🫶', label: '比心' },
  { value: '🤝', label: '握手' },
  { value: '👩🏽‍💻', label: '用电脑的女性' }
];

@Component
export struct ChatEmojiPicker {
  @Prop isDark: boolean = true;
  @Link @Watch('notifyOpenChange') isOpen: boolean;
  onPick: (emoji: string) => void = () => {};
  onOpenChange: (open: boolean) => void = () => {};

  private notifyOpenChange(): void {
    this.onOpenChange(this.isOpen);
  }

  aboutToDisappear(): void {
    if (this.isOpen) {
      this.onOpenChange(false);
    }
  }

  @Builder
  private emojiPalette() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(CHAT_EMOJIS, (item: ChatEmoji) => {
        Button(item.value, { type: ButtonType.Normal })
          .width(44)
          .height(44)
          .padding(0)
          .borderRadius(12)
          .fontSize(22)
          .fontColor(getTheme(this.isDark).text)
          .backgroundColor(Color.Transparent)
          .accessibilityText(item.label)
          .onClick(() => {
            this.onPick(item.value);
            this.isOpen = false;
          })
      }, (item: ChatEmoji) => item.value)
    }
    .width(236)
    .padding(7)
    .borderRadius(16)
    .backgroundColor(getTheme(this.isDark).surfaceSolid)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Path({ width: 22, height: 22,
        commands: 'M11 2.5 A8.5 8.5 0 1 1 11 19.5 A8.5 8.5 0 1 1 11 2.5 Z M7.5 8.5 H8 M14 8.5 H14.5 M7.5 12.5 Q11 16.5 14.5 12.5' })
        .fill(Color.Transparent)
        .stroke(this.isOpen ? getTheme(this.isDark).accent : getTheme(this.isDark).text)
        .strokeWidth(1.6)
        .strokeLineCap(LineCapStyle.Round)
    }
    .width(44)
    .height(42)
    .padding(0)
    .borderRadius(14)
    .backgroundColor(this.isOpen ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceAlt)
    .accessibilityText('选择表情')
    .onClick(() => { this.isOpen = !this.isOpen; })
    .bindPopup(this.isOpen, {
      builder: () => { this.emojiPalette(); },
      placement: Placement.Top,
      enableArrow: false,
      backgroundBlurStyle: BlurStyle.NONE,
      popupColor: Color.Transparent,
      onStateChange: (event) => {
        if (!event.isVisible) {
          this.isOpen = false;
        }
      }
    })
  }
}
