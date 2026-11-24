# OopzHM

OopzHM 是个人开发的 Oopz 鸿蒙原生客户端，面向鸿蒙手机、平板和电脑。应用使用 ArkTS 和 ArkUI 构建界面，并通过声网鸿蒙 SDK 收发语音。项目目前用于开发和测试。

## 主要功能

- **域与频道**。原生登录后浏览已加入的域、频道分组和语音频道成员。
- **文字聊天**。发送文字、表情和图片，引用回复消息，查看频道未读提醒。
- **实时语音**。加入语音频道、开关麦克风、调节发送增益与成员播放音量。在支持的设备上可切换音频线路，并在后台或锁屏时保持通话。
- **域管理**。按账号在域内的权限管理成员、频道和频道分组。

## 构建与运行

1. 用 DevEco Studio 打开 `OopzWebTest`，安装 HarmonyOS SDK 26.0.0。支持 API 13 或更高版本的目标设备。
2. 按[首次检出说明](OopzWebTest/README.md#从-git-新检出后准备构建)准备本机构建配置和占位材料，再同步依赖或运行 `ohpm install --all`。
3. 选择 `default` 产品运行到 arm64 真机。调试签名和安装步骤见[真机安装说明](OopzWebTest/README.md#安装到真机)。

签名后的调试包位于 `OopzWebTest/entry/build/default/outputs/default/entry-default-signed.hap`。占位材料可用于编译检查。真实账号登录和通话联调需要获授权的本机配置。

## 工程入口

| 路径 | 内容 |
| --- | --- |
| [OopzWebTest](OopzWebTest/) | HarmonyOS 应用工程 |
| [entry/src/main/ets](OopzWebTest/entry/src/main/ets/) | ArkUI 页面、Oopz 会话和语音逻辑 |
| [tools](OopzWebTest/tools/) | Node 联调与语音测试工具 |

开发分支、PR 和回归要求见[开发协作说明](AGENTS.md)。
