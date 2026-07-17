# 文档入口

`Docs/` 只保留当前有效的 8 份权威文档，全部平铺在本目录。历史状态、阶段报告和已废弃方案由 Git 记录，不再建立日期文件、ADR 目录或第二份接口说明。

## 阅读顺序

1. [PROJECT.md](PROJECT.md)：先确认产品边界、版本、当前状态和已知问题。
2. [ARCHITECTURE.md](ARCHITECTURE.md)：理解客户端、服务端和数据同步边界。
3. 按任务阅读契约、开发、服务器或 iOS 文档。

## 权威位置

| 文档 | 唯一负责的事实 |
|---|---|
| [PROJECT.md](PROJECT.md) | 产品基础、功能、限制、已知问题、最后验证和生产状态 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | iOS、服务端、数据库、Socket、outbox 和 Sync 的结构与不变量 |
| [API.md](API.md) | REST、Socket.IO、Sync 字段、返回值、错误和兼容规则 |
| [AI.md](AI.md) | 大橘 Agent、Memory、MCP、转写、推荐和数据隔离 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 仓库目录、关键文件、开发环境、构建验证和代码约定 |
| [SERVER.md](SERVER.md) | 生产拓扑、私有 VPS 资料定位、SSH 连接、服务器内容、部署、备份、恢复和交接 |
| [IOS.md](IOS.md) | XcodeGen、CI、unsigned IPA、免费签名、侧载和设备刷新 |
| [README.md](README.md) | 文档导航、证据等级和维护规则 |

## 证据等级

- **代码事实**：能从当前 commit 的配置或实现直接看到。
- **本地验证**：本机实际运行过的命令及结果。
- **CI 验证**：某个精确 commit 的 GitHub Actions 结果。
- **构建产物**：某个精确 commit 的 artifact、metadata 与 SHA-256。
- **生产事实**：在目标主机或公开入口实际核验的 `RELEASE`、schema 和健康状态。
- **目标设计**：尚未实现，不能写成当前能力。

本地验证、CI、构建产物、签名和生产部署是不同层级，不能互相推断。

## 维护规则

- 同一事实只在一份文档详细说明，其他地方只链接。
- API、Socket、数据库、端口、构建或部署流程变化时，同一提交更新对应文档。
- 只介绍重要目录和关键入口，不维护逐文件清单。
- 当前状态只写入 `PROJECT.md`；部署与恢复方法只写入 `SERVER.md`。
- 未实现内容必须标记“目标设计”或列入当前限制。
- 生产 IP、密码、token、数据库连接串、dump、代理参数、Apple 凭据和 UDID 永远不进入仓库。
