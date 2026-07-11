# AI 接手说明

> 更新时间：2026-07-12
>
> 当前分支：`agent/project-handoff-cleanup`
>
> Draft PR：<https://github.com/hugxu0/couplechat-ios/pull/1>

## 1. 先读结论

这不是一次已经完成的全量重构。目前只完成了重构护栏和第一项功能修复的代码；下一位 AI 不应声称整个 `REFACTOR_PLAN.md` 已完成，也不应跳到视觉美化或大文件拆分。

当前可靠交接点：

- R0.1 已验收：建立聊天行为基线和时间线刷新决策测试。
- R0.2 已验收：GitHub Actions 同时验证服务端、iPhone 单元测试、iPad 构建、Archive，并上传 IPA 和诊断包。
- R0.3 已验收：最低系统版本改为 iOS 26，CI 固定 Xcode 26.3，并按最新可用 iOS runtime 选择 iPhone 17/iPad Simulator。
- R1.1 已通过 `CoupleChat-unsigned-205` 的全部真机生命周期验收，状态为“已验收”。
- R1.2 进行中：失败消息重试与删除代码和本地测试已实现，仍需 GitHub Actions 和真机断网场景验收。

## 2. 已提交改动

按时间顺序检查以下提交：

| commit | 内容 |
|---|---|
| `a6edfb9` | 新增完整重构计划、项目基线文档、时间线 reload 决策及测试；iOS 测试由 49 增至 60 |
| `dd30a5d` | 强化 CI；新增 `HistorySyncCoordinator`；存储页改为观察 App 级同步任务；新增 4 个协调器测试 |
| `d84c37e` | 修复 CI 选择到旧 iOS runtime 的问题，改为脚本选择最新兼容的 iPhone 17/iPad Simulator |

关键实现文件：

- `Sources/Core/HistorySyncCoordinator.swift`
- `Sources/Core/ChatStore.swift`
- `Sources/App/CoupleChatApp.swift`
- `Sources/Features/Profile/StorageView.swift`
- `Sources/Features/Chat/UIKit/ChatTimelineModels.swift`
- `Sources/Features/Chat/UIKit/ChatViewController.swift`
- `CoupleChatTests/HistorySyncCoordinatorTests.swift`
- `CoupleChatTests/ChatTimelineReloadDecisionTests.swift`
- `.github/workflows/build-ios.yml`
- `.github/scripts/select-ios-simulator.py`
- `.swiftlint-structure.yml`
- `project.yml`

## 3. 自动验证记录

本地 Windows 已通过：

```powershell
cd server
npm test
npm run build
```

还通过了 `actionlint`、`git diff --check` 和 Simulator 选择脚本样例测试。Windows 没有 Xcode，不能把本地检查写成 iOS 编译已通过。

已完成的上一条 GitHub Actions 基线：

- run：<https://github.com/hugxu0/couplechat-ios/actions/runs/29162003072>
- 结果：服务端检查、60 个 iOS 单元测试、Archive、IPA 打包全部成功
- IPA artifact：`CoupleChat-unsigned-203`

当前交接批次流水线：

- run：<https://github.com/hugxu0/couplechat-ios/actions/runs/29162418346>
- 结果：全部成功
- 已通过：服务端 test/build、SwiftLint、新 Swift 文件结构护栏、64 个 iOS 单元测试、iPad Simulator 构建、unsigned Archive 和 IPA 打包
- IPA artifact：`CoupleChat-unsigned-205`（2,610,061 bytes）
- 诊断 artifact：`CoupleChat-diagnostics-205`

检查命令：

```powershell
gh run view 29162418346 --json status,conclusion,url,jobs
gh api repos/hugxu0/couplechat-ios/actions/runs/29162418346/artifacts
```

如果失败，先读失败 job 日志，只修复观测到的根因：

```powershell
gh run view 29162418346 --log-failed
```

## 4. R1.1 真机验收步骤

安装本次成功构建产生的 IPA 后，用一个有较多历史消息和图片的账号验证：

1. 打开“我的 → 存储空间”，开始同步全部聊天记录。
2. 记录当前已同步数量，立即返回其他页面并等待 20～30 秒。
3. 重新进入存储页，确认仍是同一个任务且数量继续增长，没有从零开始。
4. 点击暂停，确认进度停止；离开再进入，暂停结果仍可见。
5. 分别执行“同步全部聊天记录”和“缓存全部图片”，确认 couple/AI 两个频道的合计进度正确。
6. 同步进行时退出登录，确认任务被取消且状态清空，不会把旧账号进度带给新账号。
7. 将 App 切到后台再返回。iOS 可能挂起进程，所以这里只要求返回后状态一致、可继续；不要求系统在被挂起期间持续执行网络任务。

全部通过后才把 R1.1 改为“已验收”。若只通过 CI，仍保持“进行中”。

## 5. 下一位 AI 的第一项工作

先完成 R1.2 的 CI 和真机验收。R1.1 已验收，不要重复回退其状态。

R1.2 的范围已经写在 `REFACTOR_PLAN.md` 的“失败消息重试与删除”章节。实现前必须先读取现有 outbox、消息菜单、本地媒体清理和 `clientId` 幂等代码，并先补测试。

## 6. 不可破坏的边界

- 不改已经顺手的键盘弹起/收起和输入栏 inset 链路。
- 不删除或降级 AI 私聊、公聊 `@大橘`、Memory、确认卡、记录、提醒、纪念日和互动特效。
- 宠物页本轮跳过。
- 不修改已执行的 PostgreSQL migration；只能追加。
- 不把失败气泡的“本地删除”和服务端已发送消息的“撤回”混成一个 API。
- 消息可靠性操作优先用 `clientId`；必须保持服务端幂等，不能让一次重试产生两条正式消息。
- 不把页面生命周期重新变成长同步任务所有者。
- 不提交 `.env`、数据库、uploads、构建目录、IPA 或诊断 artifact。
- 不因工作树中存在其他改动而覆盖或回滚用户内容。

## 7. 可直接发给下一位 AI 的提示词

```text
请接手这个仓库当前的重构工作。先完整阅读：
1. Docs/AI_HANDOFF.md
2. Docs/REFACTOR_PLAN.md
3. Docs/ARCHITECTURE.md
4. Docs/DEVELOPMENT.md

先运行 git status --short --branch 和 git log --oneline -6，确认位于
agent/project-handoff-cleanup，保留已有改动。GitHub Actions run 29162418346
已经全绿，IPA artifact 是 CoupleChat-unsigned-205；先确认我是否完成了 R1.1
真机验收。

不要宣称全量重构完成。R1.1 在真机验收前保持“进行中”；如果我已提供真机
验收通过结果，再将它标记“已验收”并只执行 R1.2。严格遵守 R1.2 的范围、
测试和验收标准，不顺手开始 R2.x，不改键盘/输入栏链路，不删除任何 AI、
记录、提醒或纪念日功能。完成后报告测试、CI run、artifact 和仍需人工验证项。
```
