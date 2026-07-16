# 服务端部署、备份与恢复

本文只负责服务端。iOS unsigned IPA、免费账号签名与侧载见
[IOS_SIDELOAD.md](IOS_SIDELOAD.md)，网络拓扑见
[PRODUCTION_TOPOLOGY.md](PRODUCTION_TOPOLOGY.md)。

## 固定边界

- 日本 RFCHost 继续作为 `hoo66.top` 公网入口和冷灾备。
- 美国 RackNerd 继续是唯一可写应用、PostgreSQL 和 uploads 所在主机。
- CoupleChat Node 继续监听美国主机的 `127.0.0.1:3000`。
- 日本不运行第二套可写后端或数据库。
- 生产操作、migration、Nginx reload、备份删除和恢复都必须先得到明确授权。
- 公开仓库不记录真实主机、凭据、数据库 URL 或备份内容。

## 唯一日常发布路径

每次发布都使用同一条短路径，不再维护多套 release 门禁或重复证明：

1. 在仓库中确认工作树干净，记录完整 commit SHA。
2. 在本机执行一次服务端检查：

   ```powershell
   cd server
   npm ci
   npm run check
   ```

3. 只归档 `server/` 子树，生成固定 SHA 的 server-only 包和 SHA-256。
4. 在美国源站做只读 preflight，确认当前 `RELEASE`、schema、`.env` 权限、磁盘空间、容器和三层入口状态。
5. 发布前创建一份当前数据库与 uploads 备份，并完成文件哈希和可读性检查。
6. 将候选包放入新的候选目录，构建候选镜像；Web 进程保持
   `RUN_MIGRATIONS=false`，数据库变更继续由显式 migrator 执行。
7. 切换候选版本，依次检查：

   ```text
   美国本机 /live、/health、/ready
   私有 origin /health
   公开 hoo66.top /live、/health、/ready
   Socket.IO transport 和媒体上传
   ```

8. 健康检查通过后写入新的 `RELEASE`，删除旧候选目录、旧镜像、旧 tar 和旧备份，只保留当前版本、当前回滚镜像和刚生成的基线备份。

发布包不能包含 `.env`、数据库、uploads、`.data`、iOS 源码或 Apple 签名资料。禁止从 moving `main`、`latest` 或来源不明的远程脚本发布。

## 备份规则

备份脚本仍负责 PostgreSQL dump、uploads 归档、metadata 和 SHA-256。日常发布只创建并检查当前备份，不在每次代码发布时重复完整临时库恢复演练。

恢复演练、失败注入和离机副本确认属于私有运维维护，不把它们拆成每次发布都必须人工重复的步骤。若当前备份无法读取、哈希不匹配或 uploads 不完整，发布立即停止。

旧版本备份不作为长期回滚链保存。清理前必须先确认当前基线备份和当前回滚镜像存在；清理对象包括过期数据库备份、旧 uploads 归档、旧 release 包、旧展开目录和临时文件，不包括正在使用的数据库、uploads 或当前运行配置。

## 回滚

- 如果当前 schema 与上一镜像兼容，切回当前保留的回滚镜像并重新做三层健康检查。
- 如果 schema 已变化或数据迁移失败，停止写入，使用同一批次的当前基线备份恢复数据库与 uploads，再启动兼容镜像。
- 不保留多代旧备份，也不把重新部署旧 SHA 当作自动数据库回滚。

## 首次安装

首次安装不是日常发布路径的一部分，仍按仓库外私有运维资料准备 Ubuntu、Docker/Compose、PostgreSQL、Nginx、证书、`.env`、uploads 和备份目录。首次安装完成后，回到上面的唯一日常发布路径。

## 生产前后检查

生产前必须确认：

- 目标是美国唯一可写源站；
- 发布 SHA 是完整且不可变的；
- 当前备份已生成并可读；
- 没有第二个可写 CoupleChat 实例；
- 回滚镜像和当前基线备份的位置已知。

生产后必须记录：

- 新的 `RELEASE` SHA 和 schema；
- 本机、origin、公开入口、Socket.IO 和上传检查结果；
- 是否执行了 migration；
- 是否删除了旧备份和旧发布物；
- 是否修改数据库、Nginx、证书、密钥或设备状态。

无法证明的项目标记为“未验证”，不要用“应该正常”替代。
