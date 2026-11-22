import { AccountPanel } from '../components/AccountPanel';
import { BottomBar } from '../components/BottomBar';

@Entry
@Component
struct Account {
  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      AccountPanel()
      BottomBar({ active: 'account', showMiniBar: true })
    }
    .width('100%')
    .height('100%')
  }
}
