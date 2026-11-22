import { AccountPanel } from '../components/AccountPanel';
import { BottomBar } from '../components/BottomBar';
import { getTheme } from '../common/Theme';

@Entry
@Component
struct Account {
  @StorageProp('oopzIsDark') private isDark: boolean = true;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(getTheme(this.isDark).bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .systemBarEffect()
        .hitTestBehavior(HitTestMode.None)
      AccountPanel()
      BottomBar({ active: 'account', showMiniBar: true })
    }
    .width('100%')
    .height('100%')
  }
}
