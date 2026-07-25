# 服务端开发提示

- 使用 Node.js 22 和 `npm ci`。
- 路由、service、repository 和 Socket handler 沿用现有目录分工。
- migration 按新版本追加；修改 Sync 事件顺序时先看 `Docs/ARCHITECTURE.md`。
- REST、Socket 或 Sync 字段变化时同步更新 iOS 和 `Docs/API.md`。
- 本地调试使用开发数据库，不输出 `.env`、token 或 key。
- 改完运行：

```powershell
npm run check
```
