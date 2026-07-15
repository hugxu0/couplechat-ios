# 现行文档

`Docs/` 只描述当前代码、当前生产环境和当前维护方式。历史报告、交接记录、阶段计划、发布矩阵与过期产品蓝图均不保留；需要追溯时使用 Git 历史。

## 阅读顺序

1. [当前项目](current/PROJECT.md)：功能、限制、保护边界与验证基线。
2. [系统架构](architecture/SYSTEM_ARCHITECTURE.md)：前后端模块、数据库和实时数据流。
3. 按任务查看 [接口契约](architecture/API.md)、[AI 系统](architecture/AI.md)、[开发指南](development/DEVELOPMENT.md) 或 [生产部署](operations/DEPLOYMENT.md)。

## 维护规则

- 当前产品结论只写在 `current/PROJECT.md`，不要创建日期状态页或交接文档。
- API、Socket、数据库、命令或部署流程变化时，在同一提交更新对应现行文档。
- 未实现能力只在“当前限制”中简要记录，不创建长期路线图。
- 发布结果由 CI、Git 提交与生产健康检查证明，不另写发布报告。
- 代码与文档冲突时，以 `project.yml`、`server/package.json`、`server/src/app.ts` 与各领域 `routes.ts`、两端 Socket 契约、`server/src/db/migrate.ts`、CI workflow、生产 Compose/nginx 和运维脚本为准，并立即修正文档。

## 当前结构

```text
Docs/
  README.md
  current/PROJECT.md
  architecture/API.md
  architecture/AI.md
  architecture/SYSTEM_ARCHITECTURE.md
  development/DEVELOPMENT.md
  operations/DEPLOYMENT.md
```
