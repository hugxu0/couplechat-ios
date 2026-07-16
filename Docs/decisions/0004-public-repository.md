# ADR-0004：仓库保持公开但禁止公开运维秘密

- 状态：Accepted
- 日期：2026-07-16

## 决策

GitHub 仓库保持公开。客户端、服务端、测试、公开安全的拓扑说明和 unsigned IPA workflow 可以公开；标准 GitHub-hosted runner 对公开仓库按 GitHub 当前政策免费，因此不为节省 Actions 费用改成私有仓库。政策若变化，以 [GitHub-hosted runners 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 和 [GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 为准。

公开不代表可以提交运维资料。以下内容不得进入当前文件、Git 历史、Actions log、artifact、Issue 或 AI 对话：真实服务器 IP 清单、SSH 配置和私钥、数据库连接串或 dump、`.env`、代理/token/AI/Bark 密钥、Apple 凭据和 2FA session、签名证书与 provisioning profile、设备 UDID、生产日志和私聊内容。

## 执行规则

- `.gitignore` 只减少误提交，不能替代提交前敏感信息扫描和人工审查。
- workflow 只使用无需私密签名材料的 unsigned IPA 路径；免费 Apple Personal Team 凭据只留在用户自己的受信电脑。
- 服务端发布包只来自精确 commit/tag 的 `server/` 子树；生产 `.env`、VPS runbook 和备份继续放在仓库外。
- 删除当前文件不会删除 Git 历史。发现历史敏感痕迹时，必须先评估密钥轮换、历史重写、强制推送、fork/clone 和缓存影响；没有仓库所有者明确授权不得重写历史。
- 自动化与文档只能声明当前 commit/CI 能证明的事实，不能把 public Actions 成功写成已部署或已签名。

## 影响

- 优点：公开仓库的标准 GitHub-hosted Actions 可用于 iOS/macOS 构建，外部 AI 或开发者也能从同一事实源接手。
- 代价：任何一次提交和日志泄漏都可能长期公开，提交前审查必须比私有仓库更严格。
- 边界：GitHub 账户安全、仓库可见性和计费政策仍需由仓库所有者定期现场核对。
