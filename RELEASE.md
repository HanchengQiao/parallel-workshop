# 发布手册：把「平行工作台」变成即插即用的产品

目标用户体验：

| 平台 | 即插即用形态 | 用户操作 |
|---|---|---|
| macOS | 签名公证的 DMG | 下载 → 拖入 Applications → 双击 |
| Windows | Edge 加载项商店 | 商店页点「获取」→ 工具栏点图标 |

## 路线 A：Edge 加载项商店（免费，建议先做）

**成本**：注册免费（Microsoft 官方确认"向 Microsoft Edge 计划提交扩展不收取注册费"）。

1. 注册微软账号 → [Microsoft Partner Center](https://partner.microsoft.com/) → 注册「Microsoft Edge 计划」（个人/公司，需身份验证，可能数天）
2. 本地准备：`bash scripts/build-edge-extension.sh`（已自动生成商店图标 + `build/edge-extension.zip`）
3. Partner Center 提交扩展包（zip）：
   - 名称：平行工作台（Parallel Workbench）
   - 简短说明：多模型平行问答：一次提问，DeepSeek/Kimi/通义/文心/ChatGPT 并排回答
   - 详细说明：见 `edge-extension/STORE_LISTING.md`
   - 隐私政策：本扩展不上传任何数据；所有登录态、对话数据都留在你自己的浏览器里
   - 权限说明：declarativeNetRequest（仅为在工作台页面内嵌入各平台官网）、storage
   - 注意：提交前按 Partner Center 提示处理 manifest 中的 `key` 字段（商店会分配正式 ID）
4. 审核通过后：用户在商店一键安装

## 路线 B：macOS DMG（$99/年 Apple Developer）

1. 注册 [Apple Developer Program](https://developer.apple.com/programs/)（$99/年）
2. Xcode → Settings → Accounts 登录，确保证书 `Developer ID Application` 已在钥匙串
3. 生成 App 专用密码：appleid.apple.com → 登录与安全 → App 专用密码
4. 一条命令签名公证：
   ```sh
   DEVELOPER_ID_APPLICATION="Developer ID Application: 你的名字 (TEAMID)" \
   APPLE_ID="you@example.com" APPLE_TEAM_ID="TEAMID" APP_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
   bash scripts/sign-release.sh
   ```
5. `bash scripts/package-dmg.sh` → `build/ParallelWorkbench-0.1.0.dmg`
6. 分发 DMG（网盘/网站/IM 均可），用户拖入即用，无任何警告

## 发布前检查清单

- [ ] `bash scripts/qa.sh` 全绿
- [ ] 五平台验收通过（`swift run WorkbenchTester`，注意先退出 GUI）
- [ ] 版本号更新（manifest.json / Info.plist / README）
- [ ] Edge 商店截图（工作台窗口 + 各平台并排回答效果）

## 说明

- 开发者注册与实名验证只能由你本人完成（平台政策），其余一切（打包、签名脚本、商店材料）已备齐
- 若暂不注册：本机/亲友小范围可用「开发者模式侧载扩展」和「未签名 .app」（Gatekeeper 右键打开），体验略打折扣
