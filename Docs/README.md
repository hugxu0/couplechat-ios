# 文档入口

不用从头读完所有文档，按任务选择即可。

| 文档 | 什么时候看 |
|---|---|
| [PROJECT.md](PROJECT.md) | 想了解当前版本、功能和还没做的事 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 开始改代码或找入口 |
| [SERVER.md](SERVER.md) | 检查或发布服务器 |
| [IOS.md](IOS.md) | 构建、签名或安装 IPA |
| [API.md](API.md) | 修改 REST、Socket 或 Sync 字段 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 修改消息可靠性、数据库或同步机制 |
| [AI.md](AI.md) | 修改大橘、Memory、MCP 或模型调用 |
| [CARD_GAME.md](CARD_GAME.md) | 修改情侣卡牌玩法 |

日常小改动通常只需要看 `PROJECT.md` 和对应模块文档。技术细节留在 API/架构文档中，临时排障过程不用沉淀成长期报告。

维护时遵循几个简单原则：

- 当前已经上线的状态写在 `PROJECT.md`，计划中的内容明确写成未完成。
- 接口或数据结构真的变了，再更新对应文档。
- 密码、token、生产数据和签名凭据不写入仓库。
- Git 历史负责追踪过程，不额外维护审计式文档。
