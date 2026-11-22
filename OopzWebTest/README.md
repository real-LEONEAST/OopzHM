# Oopz 语音测试

这是一个个人调试用的鸿蒙应用，启动后直接进入原生 Oopz 选房。Node 负责 Oopz 会话和频道操作，鸿蒙用声网原生 SDK 收发语音。需要使用官方网页时，点 **Oopz 网页登录与通话**。

## 从 Git 新检出后准备构建

在 `OopzWebTest` 目录用 PowerShell 准备本机配置，再用 DevEco Studio 同步依赖，或运行 `ohpm install --all`。

```powershell
if (-not (Test-Path -LiteralPath 'build-profile.json5')) {
    Copy-Item -LiteralPath 'build-profile.template.json5' -Destination 'build-profile.json5'
}
if (-not (Test-Path -LiteralPath 'entry/src/main/ets/oopz/OopzKeyMaterial.ets')) {
    Copy-Item -LiteralPath 'entry/src/main/ets/oopz/OopzKeyMaterial.ets.example' -Destination 'entry/src/main/ets/oopz/OopzKeyMaterial.ets'
}
```

模板包含 `default` 和 `mate90Emulator` 产品。安装到设备前按下节配置调试签名。占位材料可用于编译检查，原生登录和语音联调需要获授权的本机配置。两个本机配置文件均由 Git 忽略。

## 安装到真机

1. 用 DevEco Studio 打开 `OopzWebTest` 目录。工程使用 HarmonyOS SDK 26.0.0 构建，声明支持鸿蒙电脑、手机和平板，目标设备须支持 API 13 或更高版本。
2. 在目标设备上启用开发者模式，通过无线调试或 USB 调试连到运行 DevEco Studio 的电脑。在 DevEco Studio 的设备列表中选中要测试的设备。
3. 在 **File → Project Structure → Project → Signing Configs** 勾选自动签名，选择 HarmonyOS 支持。按 DevEco Studio 提示登录华为开发者账号并生成设备调试签名。
4. 选择 `entry` 后点 **Run**。安装后的应用名为「Oopz 语音测试」。

构建产物在 `entry/build/default/outputs/default/`。真机安装需要适用于该设备的调试签名。

[华为真机运行指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/ide-run-device-V13/) · [华为自动签名指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/ide-signing-V13/)

手机和平板上，点 **显示** 可以切换横屏、竖屏或自动旋转，也可以缩放整张网页。点状态文字可以查看网页和后台任务的详情。网页启动超时后可以点 **重载** 重试。

## 原生语音测试

原生页使用声网鸿蒙音频 SDK 4.4.2。填写已授权房间的 App ID、频道名、UID 和临时 Token，点 **进入测试房间** 并授予麦克风权限。加入后请先让双方各说一句。麦克风开始采集后，应用会申请 `voip` 长时任务。Oopz 原频道的原生接入需要 Oopz 提供第三方授权。

回归后台或锁屏时，在同一次通话内先确认双方有声，等待后台任务开启，再切到前次出现中断的场景对讲。HiLog 的 `OopzNativeVoice` 标签显示前后台切换、麦克风采集、收发码率和后台任务状态。双向通话以双方实际听到的声音为准。

[声网鸿蒙语音接入文档](https://doc.shengwang.cn/doc/rtc/harmonyos/basic-features/audio-quick-start) · [Oopz 用户服务协议](https://help.oopz.cn/agreement/service)

## Oopz 原频道联调

应用首页是原生选房。原生联调使用电脑端 Node 的会话，设备填写 Node 显示的配对码。**Oopz 网页登录与通话** 提供官方网页入口，网页会话由 ArkWeb 管理。

### 原生授权登录评估

Oopz 评估人员可在运行 Node 的电脑上接入本次接入获准使用的授权登录 SDK。授权模块导出异步函数 `exchangeAuthorizationCode(code, signal)`，使用 Oopz 的评估接口兑换一次性授权码。函数返回该接入获准使用的 `device_id`、`person_uid`、`jwt_token`、`private_key`，可选 `app_version`。第二个参数是用于设置接口超时的 `AbortSignal`。真实兑换逻辑和签名身份由评估环境提供。

```powershell
npm ci --prefix tools --ignore-scripts
node tools/oopz-room-bridge.mjs --auth-adapter 'D:\Test\oopz-evaluation-auth.mjs'
```

建立下面的 HDC 转发后，在鸿蒙原生页输入配对码并点 **读取我的域**。首次连接显示 **Oopz 授权码**。输入评估人员签发的一次性授权码并点 **授权登录**。Node 校验授权会话后，应用自动列出该账号已加入的域。Node 运行期间可继续使用该会话。签名凭据和账号会话均由 Node 持有。

### 使用已有授权会话

用获准接入 Oopz 的测试账号和该账号已加入的语音频道。Node 读取本地会话 JSON，字段为 `device_id`、`person_uid`、`jwt_token`、`private_key`，可选 `app_version`。上游 dsh-oopz-voice 的「语音房」登录流程在 `<DSH_HOME>/oopz-voice/cred.json` 生成这个格式的缓存，`DSH_HOME` 默认是用户目录下的 `.dsh`。会话文件放在工程外，启动时传路径。另一位测试者使用自己的账号从官方客户端进同一个频道对讲。 [上游登录实现](https://github.com/Kingyibin/dsh-oopz-voice/blob/5a77cf383793417309c62bf4e536deca1a0e0a97/tools/login.mjs#L215-L237)

在 `OopzWebTest` 目录用 Node 20 或更新版本启动服务，把示例路径换成实际凭据文件的路径。

```powershell
npm ci --prefix tools --ignore-scripts
node tools/oopz-room-bridge.mjs 'D:\Test\oopz-test.credentials.json'
```

Node 监听电脑的 `127.0.0.1:28692`，并在终端显示本次配对码。保持服务运行。`mate90Emulator` 产品可在本地 Mate90 x86 镜像验证选房。原生通话需要 `default` 产品和 arm64 真机。设备连接后在另一个终端执行 `hdc rport tcp:28692 tcp:28692`。同时连接多台设备时，用 `hdc -t` 指定当前测试设备。 [HDC 反向端口转发](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/hdc/) · [声网鸿蒙 SDK 支持架构](https://doc.shengwang.cn/doc/rtc/harmonyos/overview/product-overview)

在原生首页输入配对码，点 **读取我的域**，再选择域和语音频道。Node 按 ID 登记入房，每约 20 秒续期一次。看到 **已连接原生语音** 后，两端分别说话并确认能听见对方，同时从官方客户端确认测试账号显示在所选频道。等至少两轮保活后再对讲一次。最后在鸿蒙点 **退出语音房间**，确认官方客户端的成员列表移除了测试账号。`OopzNativeVoice` 日志记录收发码率，Node 终端记录入房、保活和退房。

## ArkWeb 后台通话验收

v0.3.0 在网页进频道前点 **开启后台通话**。网页请求麦克风时，应用开始原生采集并申请 `voip` 长时任务。采集的音频通过 ArkWeb 消息端口送入网页使用的音轨，下行继续由网页播放。退出频道释放音频资源，关闭后台通话后，网页下一次开麦恢复使用原网页采集方式。

HiLog 的 `OopzVoiceTest` 和 `OopzNativeWebMic` 标签记录通话任务与采集状态。原频道双向通话需要在站内登录后联测，以双方实际听感为准。

[鸿蒙长时任务](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/continuous-task) · [ArkWeb 麦克风授权](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-basic-components-web-permissionrequest/)

## Mate 90 镜像回归

构建 `mate90Emulator` 产品，签名包位于 `entry/build/mate90Emulator/outputs/default/entry-default-signed.hap`。本地测试入口仅在该产品启用。HDC 命令使用 `-t` 指定已核对的本机镜像。

- 原生基线使用 `node tools/local-voice-peer.mjs`，在该镜像上反向映射 `tcp:28690` 到电脑同一端口，再以 `--ps oopzAudioLab native` 启动 `EntryAbility`。加上 `--quiet` 时，对端先发 15 秒测试音，随后持续发静默帧。可以用播放峰值核对滑杆增益，切后台后再检查采集和播放计数。
- 外壳回归使用 `node tools/web-voice-lab.mjs`，反向映射 `tcp:28691`，以 `--ps oopzAudioLab index-local` 启动同一个外壳。先点 **开启后台通话**，再点 **进入测试语音频道**。加上 `--ps oopzWebQuiet yes` 可在切到后台时给对端安排 75 秒静音间隔。
- 分别切到系统设置和锁屏 125 秒。检查第 61 秒前后的采集、两路 RTP 数据、对端解码信号和播放状态，退出频道后核对采集、播放和任务是否释放。

## 原生语音设备验收

- 在测试频道打开系统声音输出面板，选设备后核对通话页或设置中的实际输入、输出与系统音量类型。支持独立输入路由的设备可另外选择麦克风。HarmonyOS 根据实际播放流决定通话音量或媒体音量。
- 成员播放音量为 0–200%，本机麦克风发送音量为 0–150%，步长均为 5%。在成员已屏蔽时调节滑杆，确认屏蔽状态保持。调整本机发送音量后重新开麦或覆盖升级，确认发送增益恢复。
- 使用可测试的语音频道，打开麦克风，静默并分别验证切后台、锁屏和回前台。蓝牙双连、听筒、星闪、跨设备音频和智感握姿需要相应实体设备。用系统设备面板确认测试设备实际提供的线路。

[鸿蒙通话设备选择](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/using-switch-call-devices) · [鸿蒙音量类型](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/using-right-streamusage-and-sourcetype-V14/) · [鸿蒙握持手感知](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/motion-guidelines/)

## 后续画布操作记录

关闭进站活动弹窗后，点左下角加号上方的头像进入域，显示频道列表后双击语音频道。后续优先在目标区域截取图标并匹配。仅在唯一匹配时点击，并截取同一区域确认状态变化。频道名用局部文字识别。

## 原生账号直登（v0.4.0）

原生首页现在由鸿蒙应用自己完成 Oopz 登录，不再需要电脑上的 Node 联调服务。手机号 + 密码由鸿蒙原生加密后直接提交给 Oopz，登录成功后自动列出该账号已加入的域和语音频道，进房参数交给声网原生 SDK 收发语音。

- 登录加密：`@kit.CryptoArchitectureKit`。密码用 RSA-OAEP(SHA256) 加密；请求头 `Oopz-Sign = RSA-SHA256(MD5(path+body)+时间)`，与原插件 `tools/login.mjs` 一致。相关实现见 `entry/src/main/ets/oopz/`（`OopzCrypto`、`Md5`、`OopzSession`、`OopzToken`、`Inflate`）。
- 会话保存：优先用 `@kit.AssetStoreKit`（Asset Store，加密存储）保存会话，回退到 `@kit.ArkData` preferences；设备 ID 存 preferences。UI 可「退出 Oopz 账号」清除。
- 自检：`hdc shell aa start -a EntryAbility -b dev.oopzwebtest.voice --ps oopzSelfTest yes` 会打印一次签名/加密长度、设备端 AppId 解析、加密存储往返，并向 Oopz 发一次探测登录，用于确认加密、令牌解析、安全存储与网络链路。
- 入房与保活：原生调用 `userSubscribeArea/v1/list`、`area/v1/detail/v1/channels`、`person/v1/selfDetail`、`area/v2/channel/enter`（每 20 秒续期）、`member/v1/removeFromChannel`。声网 App ID 从进房返回的 `supplierSign`（Agora AccessToken2）里解出。
- 自检：`hdc shell aa start -a EntryAbility -b dev.oopzwebtest.voice --ps oopzSelfTest yes` 会打印一次签名/加密长度并向 Oopz 发一次探测登录，用于确认加密与网络链路。

### 构建与安装（命令行）

```powershell
$env:NODE_HOME='C:\Program Files\nodejs'
$env:JAVA_HOME='D:\Program Files\HuaWei\DevEco Studio\jbr'
$env:DEVECO_SDK_HOME='D:\Program Files\HuaWei\DevEco Studio\sdk'
$env:PATH="$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"
# arm64 真机 / 鸿蒙 PC
& 'D:\Program Files\HuaWei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
# Mate90 x86 镜像
& 'D:\Program Files\HuaWei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p product=mate90Emulator -p buildMode=debug assembleHap --no-daemon
hdc -t <设备> install -r entry/build/default/outputs/default/entry-default-signed.hap
```
