import { AccountPanel } from '../components/AccountPanel';
import { BottomBar, BOTTOM_BAR_INSET, BOTTOM_BAR_INSET_WITH_CALL } from '../components/BottomBar';
import { getTheme } from '../common/Theme';

@Entry
@Component
struct Account {
  @StorageProp('oopzIsDark') private isDark: boolean = true;
  @StorageProp('oopzInCall') private inCall: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(getTheme(this.isDark).bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.None)
      AccountPanel({ bottomInset: this.inCall ? BOTTOM_BAR_INSET_WITH_CALL : BOTTOM_BAR_INSET })
      BottomBar({ active: 'account', showMiniBar: true })
    }
    .width('100%')
    .height('100%')
  }
}
