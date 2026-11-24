# Oopz 鸿蒙端 · UI 与架构规划

## 一、总体架构（分层）

```
entry/src/main/ets/
├─ oopz/                协议与数据服务层（已完成）
│  ├─ OopzCrypto.ets       RSA-SHA256 签名 + RSA-OAEP 密码加密
│  ├─ Md5.ets              纯 ArkTS MD5
│  ├─ Inflate.ets          纯 ArkTS zlib（解 Agora AccessToken2）
│  ├─ OopzToken.ets        从 supplierSign 取 appId
│  ├─ OopzHttp.ets         @ohos.net.http 封装
│  ├─ OopzSession.ets      登录 / 域 / 频道 / 进房 / 保活 / 退房
│  ├─ OopzKeyMaterial.ets  由插件还原的签名私钥与密码公钥（生成物，勿手改）
│  └─ OopzCredStore.ets    Asset Store 加密存储 + preferences 回退
├─ voice/               音频与后台任务层
│  ├─ NativeRtcCall.ets    声网 RTC 封装
│  ├─ VoiceBackgroundTest.ets 长时任务 / AVSession
│  └─ NativeWebMicrophone.ets
├─ store/               状态与编排层（新增）
│  └─ AppStore.ets         会话、域/频道缓存、当前通话状态的单一来源
├─ common/              主题、常量、通用工具（新增）
│  └─ Theme.ets
├─ components/          可复用 UI 组件（新增）
│  └─ BottomBar.ets        底部「语音 / 我的」导航
└─ pages/               页面
   ├─ NativeVoice.ets      语音页（登录→选域→选频道→通话）
   ├─ Account.ets          「我的」页（账号 / 设备 / 清除登录 / 关于）
   └─ Index.ets            网页登录与通话（保留作为备选）
```

- **协议层** 只关心 Oopz 网关：签名、加解密、REST、令牌解析。
- **音频层** 只关心声网 RTC 与后台保活。
- **状态层** AppStore 统一持有 `OopzSession` / `OopzCredStore` / 域频道缓存 / 通话状态，页面只读状态+触发动作，避免每页各自 new 一套导致登出不同步。
- **表现层** 页面 + 组件 + 主题；登录态通过 AppStorage 与 AppStore 跨页共享。

## 二、路由与页面结构

| 页面 | 路由 | 内容 |
|---|---|---|
| 语音页 | pages/NativeVoice | 未登录=登录表单；已登录=域选择 + 语音频道列表 + 「进入语音频道」；通话中=房间名/成员/码率/静音/退出 + 后台任务状态 |
| 我的 | pages/Account | 头像占位、UID、设备 ID、版本、清除本机会话、关于/协议入口 |
| 网页备选 | pages/Index | 官方网页登录与通话（ArkWeb，保留） |

导航：语音页底部「我的」→ push `pages/Account`；Account 底部「语音」→ back 回语音页（语音页保持挂载，通话不中断）。
后续可扩展：登录页独立、域/频道列表页与通话页拆分（Room 独立页 + 全局迷你通话条）。

## 三、UI 设计规范

- 色板：背景 `#0F1720`、卡片 `#17242E`、输入/次级 `#1C303B`、主色 `#9CE1D6`（按钮文字深色 `#11272B`）、危险 `#733D48`、正文 `#F3FCFF`、次要文字 `#B5C7D3`、提示 `#E6CDA6`。
- 圆角 12，卡片内边距 16，页面左右 20，控件间距 12/14。
- 状态用文字条统一展示（notice/错误/后台任务），避免弹窗打断通话。
- 底部导航固定 56 高，两栏居中等分。

## 四、状态与关键流程

登录：手机号/密码 → `OopzSession.login()`（RSA-OAEP 加密 + 客户端签名）→ 得到 `device_id/person_uid/jwt_token/private_key` → `OopzCredStore.saveCred()`（Asset Store）→ 加载域。
选房：`areas()` → `channels(areaId)` → `enter(areaId, channelId)` 返回 `{appId, channel(roomId), uid(pid), token(supplierSign)}` → 声网 `NativeRtcCall.start()`。
保活：20s 周期 `refresh()`（重新 enter 续期）→ `renewToken()`。
退房：`leave()` → DELETE removeFromChannel；释放 RTC 与长时任务。
后台：`VoiceBackgroundTest` 用 `audioPlayback,audioRecording` 模式申请长时任务（手机端验证锁屏/切后台音频不断）。

## 五、测试策略（按设备分工）

- **鸿蒙 PC（arm64）**：只验证「登录 → 读域 → 选频道 → 进房 → 前台双向语音」。已验证通过（peers=1、tx/rx 均有码率）。
- **手机（arm64）**：验证「切后台 / 熄屏锁屏 / 最小化后音频不断」。电脑上锁屏语义不同，不作为判据。

## 六、实施阶段

1. 阶段一（本次）：主题、AppStore 骨架、底部导航、「我的」页；语音页接入底部导航保持现有通话逻辑。
2. 阶段二：登录页独立、域/频道列表组件化、通话页拆分 + 全局迷你通话条。
3. 阶段三：设置/权限引导、错误码文案、日志与诊断页、手机端后台回归脚本。
