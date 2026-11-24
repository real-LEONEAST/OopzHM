# OopzHM 开发协作规范

本文件是 Codex、DeepSeek Harness、Antigravity 和人工开发共用的项目规则。在 `OopzHM` 根目录或分配给任务的工作树中开启开发会话。DevEco Studio 打开对应工作树内的 `harmonyos`。继续已有任务时，先查看该任务的分支、PR 和验证记录。

## 分支与工作树

- `main` 是共同的集成和打包基线。每项改动从最新的 `origin/main` 建一个 `feat/<主题>` 分支，通过 PR 合并回 `main`。直接提交到 `main` 会跳过集成检查，应通过 PR 提交。
- 工作树是同一 Git 仓库的一份独立检出。一个任务使用一个分支和一个工作树或独立克隆。多个工具并行工作时，各自打开分配的目录，分别运行构建。接手同一个任务时继续原分支和原 PR，由当前开发工具交接写入。
- 改动前查看 `git status --short --branch` 和已有差异。保留其他任务和用户的改动，只暂存本任务涉及的文件。避免在他人的工作树上切分支、暂存或运行清理操作。文本在入库时通过 `.gitattributes` 统一换行，减少工具之间的整文件差异。

仓库和远端就绪后，在项目根目录创建一个任务工作树。下例的分支从刚同步的 `origin/main` 开始。

```powershell
git fetch origin
git worktree add -b feat/voice-room .worktrees/voice-room origin/main
```

开发过程中，在自己的工作树同步 `origin/main`，用 `git merge origin/main` 吸收已经合并的改动。PR 依赖另一项尚未合并的任务时，在 PR 中写明依赖，先合并前置改动，再同步和验证后续分支。已共享的分支保留历史，避免强制推送或覆盖他人提交。

## 并行改动与交接

- 以功能或缺陷划分任务，尽量让每个 PR 能独立审查和验证。开工前在任务记录或已有 PR 中写清负责范围。导航入口、`AppStore`、Oopz 会话与 RTC 生命周期、`module.json5` 和构建配置属于共享改动点。如有重叠，先约定接口和合并顺序。
- 优先在已合并的功能上继续开发，复用现有实现。公共接口优先采用兼容的增量改动。确需重命名、移除或更改行为时，把调用方迁移和受影响的验证纳入同一 PR，或先提交可兼容的过渡改动。
- 合并冲突时，查看双方提交的行为和调用方，再逐段整合。对已经通过验证的登录、读域、进房和通话行为，按改动涉及的范围做回归。避免用一方的整文件覆盖另一方的有效改动。
- 交接直接更新原任务或草稿 PR，留下分支名、基线提交、工作范围、已经完成的改动、验证结果、待办和依赖。接手方从这些提交和当前差异继续。

## 界面与交互

- 新增或修改按钮时，优先用含义明确的图标，尽量避免直接用文字作为按钮内容。优先复用项目已有图标或鸿蒙系统图标，并保留无障碍标签。需要明确操作后果的确认按钮，或图标含义不够清楚的操作，可以使用短文字。

## PR 提交与合并

所有任务统一用 `feat/` 分支前缀。PR 标题按实际改动标明类型，例如 `feat(voice): 拆分频道预览与通话页`、`fix(audio): 修复退房后的麦克风释放` 或 `docs: 更新打包说明`。

PR 说明写明以下内容。

- 目标、改动范围和用户可见的变化。
- 共享接口、构建配置或依赖的变化，以及需要先合的 PR。
- 验证命令、产品、结果和剩余待验证项。涉及界面的改动可附关键页面截图。

合并前执行 `git diff --check origin/main...HEAD` 并检查 PR 差异范围。影响应用代码、资源、依赖或打包配置的 PR，须通过 `default` 产品构建和受影响流程的回归。仅改文档或协作规则的 PR 检查差异即可。验证以包含最新 `main` 的合并候选为准。主分支更新后，涉及合并结果的检查重新运行。远端支持分支保护时，为 `main` 开启 PR 合并和构建检查。

## 鸿蒙构建与产物

按 [工程构建说明](harmonyos/README.md#构建与安装命令行) 准备环境和本机调试签名。当前工程使用 HarmonyOS SDK 26.0.0。每个工作树使用自身的构建输出和缓存，软件依赖按已提交的清单和锁文件恢复。

在自己的工作树根目录运行以下命令。`DEVECO_SDK_HOME` 按工程说明指向 DevEco Studio 的 `sdk` 目录。

```powershell
$oopzDevEco = Split-Path -Parent $env:DEVECO_SDK_HOME
$oopzHvigor = Join-Path $oopzDevEco 'tools\hvigor\bin\hvigorw.bat'
Push-Location -LiteralPath 'harmonyos'
try {
    & $oopzHvigor --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw 'default HAP 构建失败' }
} finally {
    Pop-Location
}
```

- 在 `harmonyos/entry/build/default/outputs/default/` 检查本次生成的 HAP。完成调试签名时，真机安装包为 `entry-default-signed.hap`。已存在的 HAP 只能证明之前的构建曾产出文件。
- 语音相关改动按影响范围验证登录、选域选频道、加入、多端对讲和退出。涉及后台或锁屏时，用支持该场景的真机验证。授权、签名或设备缺失时，在 PR 记录实际通过的检查和阻塞项。
- 集成包从合并后的 `main` 提交构建，记录提交 SHA、产品和验证结果。HAP、安装包和本机缓存由构建或产物渠道管理。

## 首次建仓

1. 先盘点现有未版本化的并行成果，确定共同基线。同意纳入基线的改动一起进入初始提交，待完成的任务记录范围后分别进入 `feat/` 分支。
2. 纳入源码、资源、依赖锁文件和协作规范，检查暂存列表。本机 `harmonyos/build-profile.json5` 和 `OopzKeyMaterial.ets` 由 Git 忽略。各工作树按[首次检出说明](harmonyos/README.md#从-git-新检出后准备构建)使用 `build-profile.template.json5` 准备本机配置，独立配置调试签名，并通过获授权的渠道补齐语音测试材料。变更共享构建配置时同步更新模板，随 PR 一起评审。
3. 在新工作树验证依赖恢复和 `default` 构建，随后把该基线接到共享远端的 `main`。各工具从同一个基线开始后续任务。仓库、远端及所需权限就绪后开始使用上述 PR 流程。
