# 文档索引

本目录只维护当前有效的设计、契约和操作说明。仓库采用单仓库结构；同一事实只能有一个权威位置，其他文档只链接，不复制长命令。

## 必读顺序

1. [当前项目](current/PROJECT.md)：产品边界、版本、源码与生产状态。
2. [已知问题](current/KNOWN_ISSUES.md)：已确认缺陷、优先级和验收条件。
3. [系统架构](architecture/SYSTEM_ARCHITECTURE.md)：端到端模块和所有权边界。
4. 按任务继续阅读下表中的权威文档。

## 事实的权威位置

| 事实 | 权威文档 |
|---|---|
| 当前功能、版本、限制、最后验证证据 | [current/PROJECT.md](current/PROJECT.md) |
| 活跃缺陷与修复顺序 | [current/KNOWN_ISSUES.md](current/KNOWN_ISSUES.md) |
| 端到端系统与模块所有权 | [architecture/SYSTEM_ARCHITECTURE.md](architecture/SYSTEM_ARCHITECTURE.md) |
| 消息、outbox、Socket、Sync V2、游标 | [architecture/DATA_SYNC.md](architecture/DATA_SYNC.md) |
| REST 与 Socket.IO 契约 | [architecture/API.md](architecture/API.md) |
| AI、Memory、MCP | [architecture/AI.md](architecture/AI.md) |
| 本地开发、测试和 CI | [development/DEVELOPMENT.md](development/DEVELOPMENT.md) |
| 日本入口与美国源站拓扑 | [operations/PRODUCTION_TOPOLOGY.md](operations/PRODUCTION_TOPOLOGY.md) |
| 服务端首次安装、发布、备份和回滚 | [operations/DEPLOYMENT.md](operations/DEPLOYMENT.md) |
| unsigned IPA、免费签名与三台设备侧载 | [operations/IOS_SIDELOAD.md](operations/IOS_SIDELOAD.md) |
| 已接受的长期取舍 | [decisions/](decisions/) |

## 证据等级

文档必须明确区分：

- **代码事实**：能从当前 commit 的配置或实现直接看到；
- **本地验证**：本机实际运行过的测试与命令；
- **CI 验证**：某个精确 commit 的 GitHub Actions 结果；
- **构建产物**：某个精确 commit 的 artifact、metadata 与 SHA-256；
- **生产事实**：在目标主机或公开入口实际核验的 `RELEASE`、schema、健康状态；
- **目标设计**：尚未实现，不能写成当前能力。

测试通过不能证明 IPA 属于同一 commit，IPA 存在不能证明已经签名，签名成功也不能证明线上服务端已经升级。

## 维护规则

- API、Socket、数据库、端口、命令或部署流程变化时，在同一提交更新对应权威文档。
- README、故障说明和 AI 交付只链接权威步骤，不复制另一套命令。
- 未实现内容必须标记“目标设计”或“待实现”；修复完成后更新已知问题状态。
- 不创建日期报告、阶段交接文档、发布快照或第二份 API 文档；需要追溯时使用 Git 历史和 CI。
- 代码与文档冲突时，先以实现和可复现证据定位事实，再在同一改动中修正文档。
- 生产 IP、密码、token、数据库 dump、代理参数、Apple 凭据和 UDID 永远不进入仓库。
