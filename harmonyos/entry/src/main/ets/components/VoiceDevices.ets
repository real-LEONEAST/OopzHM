import { AVCastPicker, AVCastPickerState, AVCastPickerStyle } from '@kit.AVSessionKit';
import { AppSpacing, getTheme } from '../common/Theme';

@Component
export struct VoiceOutputPicker {
  @Prop label: string = '';
  @Prop isDark: boolean = true;
  @Prop compact: boolean = false;
  @Prop split: boolean = false;
  @Prop heightVp: number = 42;
  @Prop sessionType: string = '';
  onOpenChange: (open: boolean) => void = () => {};
  onRefresh: () => void = () => {};

  @Builder
  private pickerGlyph() {
    Row({ space: 5 }) {
      SymbolGlyph(this.split ? $r('sys.symbol.chevron_down') : $r('sys.symbol.speaker'))
        .fontSize(this.split ? 12 : 18).fontColor([getTheme(this.isDark).textSecondary])
      if (!this.split && !this.compact) {
        Text(this.label || '声音输出').fontSize(12).fontColor(getTheme(this.isDark).text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 90 })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Row() {
      if (this.sessionType.length > 0) {
        AVCastPicker({
          sessionType: this.sessionType,
          pickerStyle: AVCastPickerStyle.STYLE_MENU,
          customPicker: () => this.pickerGlyph(),
          onStateChange: (state: AVCastPickerState) => {
            this.onOpenChange(state === AVCastPickerState.STATE_APPEARING);
            if (state === AVCastPickerState.STATE_DISAPPEARING) this.onRefresh();
          }
        })
          .width(this.split ? 39 : (this.compact ? 44 : 126))
          .height('100%')
          .accessibilityText(this.label ? `选择声音输出，当前${this.label}` : '选择声音输出')
      } else {
        this.pickerGlyph()
      }
    }
    .width(this.split ? 39 : (this.compact ? 44 : 126))
    .height(this.heightVp)
    .justifyContent(FlexAlign.Center)
    .borderRadius(AppSpacing.radius)
    .backgroundColor(this.split ? Color.Transparent : getTheme(this.isDark).surfaceAlt)
    .opacity(this.sessionType.length > 0 ? 1 : 0.42)
  }
}

@Component
export struct VoiceMicStatus {
  @Prop muted: boolean = false;
  @Prop capturing: boolean = false;
  @Prop input: string = '';
  @Prop output: string = '';
  @Prop playbackMuted: boolean = false;
  @Prop volumeType: string = '';
  @Prop rates: string = '';
  @Prop task: string = '';
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
      Text(`输出 · ${this.playbackMuted ? '已静音' : (this.output || '由系统选择')}${this.volumeType ? ' · ' + this.volumeType : ''}`)
        .width('100%')
        .fontSize(12)
        .fontColor(getTheme(this.isDark).textMuted)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.rates.length > 0) {
        Text(this.rates).width('100%').fontSize(11).fontColor(getTheme(this.isDark).textMuted)
      }
      if (this.task.length > 0) {
        Text(this.task).width('100%').fontSize(11).fontColor(getTheme(this.isDark).textMuted)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(AppSpacing.radius)
    .backgroundColor(getTheme(this.isDark).surface)
    .border({ width: 1, color: getTheme(this.isDark).borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }
}
