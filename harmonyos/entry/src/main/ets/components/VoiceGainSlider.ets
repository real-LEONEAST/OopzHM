import { getTheme } from '../common/Theme';
import { DEFAULT_MIC_GAIN, VOICE_GAIN_STEP } from '../store/AppStore';

@Component
export struct VoiceGainSlider {
  @Prop label: string = '';
  @Prop @Watch('syncValue') value: number = DEFAULT_MIC_GAIN;
  @Prop max: number = 150;
  @Prop isDark: boolean = true;
  @State private displayedValue: number = DEFAULT_MIC_GAIN;
  onGainChange: (value: number, commit: boolean) => void = () => {};
  private lastPreviewAt: number = 0;

  aboutToAppear(): void {
    this.syncValue();
  }

  private syncValue(): void {
    this.displayedValue = this.value;
  }

  private change(value: number, mode: SliderChangeMode): void {
    this.displayedValue = value;
    const now = Date.now();
    const commit = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
    if (commit || (mode === SliderChangeMode.Moving && now - this.lastPreviewAt >= 75)) {
      this.lastPreviewAt = now;
      this.onGainChange(value, commit);
    }
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(13)
          .fontColor(getTheme(this.isDark).text)
          .layoutWeight(1)
        Text(`${this.displayedValue}%`).fontSize(13).fontColor(getTheme(this.isDark).accent)
      }
      .width('100%')
      Slider({ value: this.displayedValue, min: 0, max: this.max, step: VOICE_GAIN_STEP })
        .width('100%')
        .height(36)
        .selectedColor(getTheme(this.isDark).accent)
        .trackColor(getTheme(this.isDark).borderSubtle)
        .accessibilityText(this.label)
        .onChange((value: number, mode: SliderChangeMode) => { this.change(value, mode); })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
