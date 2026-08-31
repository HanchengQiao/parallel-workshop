# 平行工作台 — Edge/Chrome 扩展（MV3）

与 macOS 应用共享同一套适配器/注入核心（`Sources/WorkbenchCore/Resources/`），单一事实来源。

## 构建

```sh
bash scripts/build-edge-extension.sh   # 复制共享核心 → edge-extension/lib/
```

## 安装（开发者模式）

1. Edge 打开 `edge://extensions`（Chrome 打开 `chrome://extensions`）
2. 开启「开发人员模式」
3. 「加载解压缩的扩展」→ 选择 `edge-extension/` 目录
4. 点击工具栏图标 → 打开工作台页面

## 架构

- `workbench.html/js/css`：工作台页面（iframe pane + 统一输入框 + 状态角标 + 发送反馈）
- `content.js`：注入所有 frame；`postMessage` 协议（`WB_INJECT`/`WB_PROBE` → `WB_RESULT`）
- `rules.json`：declarativeNetRequest 剥离 XFO/CSP 响应头，允许 iframe 嵌入平台官网
- `lib/`：构建脚本从共享核心复制的 adapter JSON + inject/probe JS
- 固定扩展 ID（manifest key）：`eeppnjgcjioaohaaoaknkkafhodccmmf`

## 验证状态

- ✅ JS 语法 + manifest/rules JSON 校验
- ✅ content.js 胶水层 Node+jsdom 冒烟测试（模板拉取 → `__CFG__` 替换 → 注入 → 结果回传；顺带修复了 `String.replace` 只替换注释里首个 `__CFG__` 的真 bug）
- ⏳ 真机加载测试：本机 Chrome 151 官方版已移除 `--load-extension` 命令行能力，无法自动化加载；需在 Edge/Chrome 开发者模式手动加载后实测（iframe 嵌入、登录态继承、注入发送）

## 已知注意

- 国际平台（chatgpt）走浏览器既有代理环境，扩展不做任何代理
- 登录态继承自浏览器日常使用（未登录的平台在 pane 里登录一次即可）
