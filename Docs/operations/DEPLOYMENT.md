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

## 普通代码发布（默认路径）

普通服务端代码、文案或无数据结构变化的配置发布，只走下面这条短路径。它不停止写入、不运行 migrator，也不在每次发布时重复完整数据库/上传恢复；定时备份和现有基线负责灾备。

1. 在仓库确认工作树干净，记录完整 commit SHA。
2. 在本机执行一次 `cd server; npm run check`。只有 `package-lock.json` 变化或依赖目录不存在时才先运行 `npm ci`；不要在服务器重新跑整套测试。
3. 只归档 `server/` 子树，生成固定 SHA 的 server-only 包和 SHA-256。
4. 在美国源站做只读 preflight，确认当前 `RELEASE`、schema、`.env` 权限、磁盘空间、容器和三层入口状态。
5. 上传包并校验 SHA-256；构建或复用该 SHA 对应的镜像，Web 进程保持 `RUN_MIGRATIONS=false`。
6. 仅重建美国源站的 CoupleChat 容器，不改数据库、uploads、Nginx 或日本入口。
7. 依次检查：

   ```text
   美国本机 /live、/health、/ready
   私有 origin /health
   公开 hoo66.top /live、/health、/ready
   Socket.IO transport 和媒体上传
   ```

8. 健康检查全部通过后写入新的 `RELEASE`，保留当前镜像和一个可兼容的回滚镜像，删除旧候选目录、旧镜像和旧 tar。不要因为普通代码发布删除唯一的现行基线备份。

当前仓库没有已实现的远程一键 `deploy-server` 命令；以上是人工执行的标准短路径，不能把目标脚本写成已经存在。

## 数据变更发布（仅在需要时）

只有数据库 migration、数据修复、媒体格式/目录变化、同步协议不兼容，或需要恢复/冷切换时，才在普通路径之外增加：

1. 停写或 quiesce；
2. 新建数据库与 uploads 一致备份，并记录 SHA-256；
3. 在隔离临时库完成真实恢复验证；
4. 按兼容顺序运行独立 migrator，再启动候选版本；
5. 完成三层健康检查后记录 `RELEASE`、schema 和恢复证据。

这条特殊路径不是普通代码发布的默认门槛。

发布包不能包含 `.env`、数据库、uploads、`.data`、iOS 源码或 Apple 签名资料。禁止从 moving `main`、`latest` 或来源不明的远程脚本发布。

## 备份规则

定时任务负责 PostgreSQL dump、uploads 归档、metadata、SHA-256 和离机副本；每周任务在随机临时库做恢复演练。普通代码发布只检查现行基线是否存在，不强制新建备份或等待恢复演练。

若备份不可读、哈希不匹配或 uploads 不完整，不能执行数据变更发布或恢复操作；普通代码发布仍可在已有基线和回滚镜像明确时继续。

旧版本备份不作为长期回滚链保存。清理前必须确认现行基线备份和当前回滚镜像存在；可清理过期数据库备份、旧 uploads 归档、旧 release 包、旧展开目录和临时文件，但不能删除正在使用的数据或唯一现行基线。

## 回滚

- 如果当前 schema 与上一镜像兼容，切回当前保留的回滚镜像并重新做三层健康检查。
- 如果 schema 已变化或数据迁移失败，停止写入，使用同一批次的当前基线备份恢复数据库与 uploads，再启动兼容镜像。
- 不保留多代旧备份，也不把重新部署旧 SHA 当作自动数据库回滚。

## 首次安装

首次安装不是日常发布路径的一部分，仍按仓库外私有运维资料准备 Ubuntu、Docker/Compose、PostgreSQL、Nginx、证书、`.env`、uploads 和备份目录。首次安装完成后，回到上面的普通代码发布路径。

## 生产前后检查

普通代码发布前必须确认：

- 目标是美国唯一可写源站；
- 发布 SHA 是完整且不可变的；
- 现行基线备份和一个可兼容回滚镜像的位置已知；
- 没有第二个可写 CoupleChat 实例；
- 不涉及 migration、数据修复、媒体结构或同步协议不兼容。

数据变更发布另需确认新建备份、恢复验证、停写方式和迁移回滚边界。

生产后必须记录：

- 新的 `RELEASE` SHA 和 schema；
- 本机、origin、公开入口、Socket.IO 和上传检查结果；
- 是否执行了 migration；
- 是否删除了旧发布物；只有执行数据变更路径时才记录备份/恢复批次和清理；
- 是否修改数据库、Nginx、证书、密钥或设备状态。

无法证明的项目标记为“未验证”，不要用“应该正常”替代。
