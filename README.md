# 悄悄话 · 原生版（SwiftUI）

双人私密聊天 App 的 iOS 原生重写，对应网页版 [hugxu0/chat](https://github.com/hugxu0/chat)。

## 现状

第一阶段：五个页面的 UI 骨架 + 统一设计系统，数据全部是假数据，还没接后端。

## 架构

```
Sources/
├── App/                  入口 + 底部标签栏（自绘，统一动画）
├── DesignSystem/DS.swift 设计令牌：圆角/颜色/透明度/间距/动画曲线 全部只在这里定义
└── Features/             五个页面，一个文件夹一个功能
    ├── Chat/             聊天首页 + 会话页（气泡分组、入场动画、输入栏）
    ├── Records/          记录页（天数、计数、聊天统计柱状图）
    ├── Pet/              大橘页（宠物状态 + 互动，3D 模型后续用 SceneKit 接）
    ├── Reminders/        提醒页
    └── Profile/          我的页
```

改全局风格（圆角大小、玻璃透明度、动画手感）只改 `DS.swift` 一个文件。

## 构建

没有 Mac，本地不构建。推到 main 或手动触发 GitHub Actions，产出未签名 ipa，
用 iloader/SideStore 签名安装。工程文件由 XcodeGen 从 `project.yml` 现场生成，不入库。

## 后续计划

1. 接后端（Socket.IO 实时消息、登录、历史记录）
2. 聊天细节：长按菜单、侧滑回复、已读回执、图片/表情
3. 大橘 3D 模型（SceneKit 加载 cute_cat.glb）
4. 液态玻璃材质（改 DS.swift 的 Surface 部分）
