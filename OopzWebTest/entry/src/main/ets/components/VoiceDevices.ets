import { AVCastPicker, AVCastPickerState } from '@kit.AVSessionKit';
import { getTheme } from '../common/Theme';

@Component
export struct VoiceOutputPicker {
  @Prop label: string = '';
  @Prop isDark: boolean = true;
  @Prop compact: boolean = false;
  @Prop sessionType: string = '';
  onRefresh: () => void = () => {};

  @Builder
  private iconAndLabel() {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.speaker')).fontSize(18).fontColor([getTheme(this.isDark).text])
      if (!this.compact) {
        Text(this.label || '声音输出')
          .fontSize(12)
          .fontColor(getTheme(this.isDark).text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 92 })
      }
    }
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Row() {
      if (this.sessionType.length > 0) {
        AVCastPicker({
          sessionType: this.sessionType,
          customPicker: () => this.iconAndLabel(),
          onStateChange: (state: AVCastPickerState) => {
            if (state === AVCastPickerState.STATE_DISAPPEARING) this.onRefresh();
          }
        })
          .width(this.compact ? 44 : 126)
          .height('100%')
          .accessibilityText(this.label ? `声音输出，${this.label}` : '选择声音输出')
      } else {
        this.iconAndLabel()
      }
    }
    .width(this.compact ? 44 : 126)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(getTheme(this.isDark).surfaceAlt)
    .opacity(this.sessionType.length > 0 ? 1 : 0.62)
  }
}

@Component
export struct VoiceMicStatus {
  @Prop muted: boolean = false;
  @Prop capturing: boolean = false;
  @Prop input: string = '';
  @Prop output: string = '';
  @Prop isDark: boolean = true;

  build() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Circle()
          .width(7)
          .height(7)
          .fill(this.capturing && !this.muted ? getTheme(this.isDark).speaking : getTheme(this.isDark).textMuted)
        Text(this.muted ? '麦克风已关闭' : (this.capturing ? '麦克风采集中' : '麦克风待命'))
          .fontSize(13)
          .fontColor(getTheme(this.isDark).text)
          .layoutWeight(1)
      }
      .width('100%')
      Text(`输入 · ${this.muted ? '已关闭' : (this.input || '由系统选择')}`)
        .width('100%')
        .fontSize(12)
        .fontColor(getTheme(this.isDark).textMuted)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`输出 · ${this.output || '由系统选择'}`)
        .width('100%')
        .fontSize(12)
        .fontColor(getTheme(this.isDark).textMuted)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor(getTheme(this.isDark).surface)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }
}
