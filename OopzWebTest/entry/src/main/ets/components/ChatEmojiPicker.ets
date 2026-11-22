import { getTheme, nativePopupMaterial, supportsImmersiveLight } from '../common/Theme';
import { OOPZ_EMOJI_FONT_FAMILY } from '../oopz/OopzEmojiFont';

interface ChatEmoji {
  value: string;
  label: string;
}

const CHAT_EMOJIS: ChatEmoji[] = [
  { value: '\u{103200}', label: '无语' },
  { value: '\u{103201}', label: '皱眉看手机' },
  { value: '\u{103202}', label: '问号脸' },
  { value: '\u{103203}', label: '爱心脸' },
  { value: '\u{103204}', label: '捂嘴哭' },
  { value: '\u{103205}', label: '捂脸哭' },
  { value: '\u{103206}', label: '苦笑' },
  { value: '\u{103207}', label: '笑喷' },
  { value: '\u{103208}', label: '捂嘴笑' },
  { value: '\u{10320A}', label: '叹气' },
  { value: '\u{10320B}', label: '无语流汗' },
  { value: '\u{10320C}', label: '疑问' },
  { value: '\u{10320D}', label: '暗中观察' },
  { value: '\u{10320E}', label: '捂脸' },
  { value: '\u{10320F}', label: '狗头' }
];

@Component
export struct ChatEmojiPicker {
  @Prop isDark: boolean = true;
  @Prop fontReady: boolean = false;
  @Prop fontLoading: boolean = false;
  @Link @Watch('notifyOpenChange') isOpen: boolean;
  @StorageProp('oopzImmersiveLight') private immersiveLight: boolean = true;
  onPick: (emoji: string) => void = () => {};
  onOpenChange: (open: boolean) => void = () => {};

  private notifyOpenChange(): void {
    this.onOpenChange(this.isOpen);
  }

  aboutToDisappear(): void {
    if (this.isOpen) this.onOpenChange(false);
  }

  @Builder
  private emojiPalette() {
    Column() {
      if (this.fontReady) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(CHAT_EMOJIS, (item: ChatEmoji) => {
            Button({ type: ButtonType.Normal }) {
              Text(item.value)
                .fontFamily(OOPZ_EMOJI_FONT_FAMILY)
                .fontSize(24)
            }
            .width(44)
            .height(44)
            .padding(0)
            .borderRadius(12)
            .backgroundColor(Color.Transparent)
            .accessibilityText(item.label)
            .onClick(() => {
              this.onPick(item.value);
              this.isOpen = false;
            })
          }, (item: ChatEmoji) => item.value)
        }
        .width('100%')
      } else {
        Text(this.fontLoading ? '正在加载表情…' : '暂时无法加载 Oopz 表情')
          .fontSize(13)
          .fontColor(getTheme(this.isDark).textSecondary)
          .padding({ left: 10, right: 10, top: 12, bottom: 12 })
      }
    }
    .width(236)
    .padding(7)
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph(this.isOpen ? $r('sys.symbol.face_smiling_fill') : $r('sys.symbol.face_smiling'))
        .fontSize(22)
        .fontColor([this.isOpen ? getTheme(this.isDark).accent : getTheme(this.isDark).text])
    }
    .width(44)
    .height(42)
    .padding(0)
    .borderRadius(14)
    .backgroundColor(this.isOpen ? getTheme(this.isDark).accentSoft : getTheme(this.isDark).surfaceAlt)
    .accessibilityText('Oopz 表情')
    .onClick(() => { this.isOpen = !this.isOpen; })
    .bindPopup(this.isOpen, {
      builder: () => { this.emojiPalette(); },
      placement: Placement.Top,
      enableArrow: false,
      systemMaterial: nativePopupMaterial(this.immersiveLight),
      popupColor: this.immersiveLight && supportsImmersiveLight() ? undefined : getTheme(this.isDark).surfaceSolid,
      onStateChange: (event) => {
        if (!event.isVisible) this.isOpen = false;
      }
    })
  }
}
