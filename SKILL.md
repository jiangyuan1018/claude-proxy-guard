---
name: claude-proxy-guard
description: Install, configure, verify, or troubleshoot Claude Proxy Guard (Claude 代理守卫) on macOS with Clash Verge / Mihomo. Use when the user asks an AI coding agent to install or set up Claude Proxy Guard, detect their Clash Verge proxy group and US node automatically, write ~/.config/claude-proxy-guard/config.json, build/install the menubar app, or run --check diagnostics.
---

# Claude Proxy Guard — AI 自动安装与配置指南

本文件供 Claude Code、Cursor、Codex 等 AI Agent 读取执行，自动为用户完成 **Clash 分组/节点探测 → 免改源码配置生成 → 原生编译自检 → 安装启动**。

## 安全红线（必须遵守）

1. **严禁读取或回显凭据**：读取 Clash 配置时，**只允许**查询代理组名称（`proxy-groups[].name`）、当前选中节点名（`now`）和分流规则类型/域名，**禁止**输出 `proxies` 中的服务器地址、端口、密码、UUID、订阅链接或 `secret`。
2. **严禁自动篡改 Clash 配置**：除非用户明确要求你帮他补齐 Clash 规则，否则不要修改 `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/` 下的任何文件。
3. **真实 IP 脱敏**：运行 `--check` 后向用户汇报结果时，将出口 IP 最后两段打码（如 `198.51.*.*`），不要在对话中明文回显完整公网 IP。

## 标准安装流程（4 步）

### Step 1：检查前置环境

并行检查以下条件，缺哪项先提示用户处理：
- 系统为 macOS 13+，且 `/usr/bin/xcrun --find swiftc` 可用（未安装则提示运行 `xcode-select --install`）。
- `/Applications/Claude.app` 已安装。
- Clash Verge 正在运行，且本地控制 Unix Socket 存在：
  ```sh
  ls -la "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
  ```

### Step 2：自动探测用户的 Clash 分组与锁定节点（免改源码）

通过 Mihomo 本地 Unix Socket 只读查询当前代理组与规则指向（不打印任何节点凭据）：

```sh
/usr/bin/ruby -ryaml -rjson -ropen3 -e '
  root = File.expand_path("~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
  base = YAML.safe_load(File.read(File.join(root, "config.yaml")), [], [], true) || {}
  rt   = YAML.safe_load(File.read(File.join(root, "clash-verge.yaml")), [], [], true) || {}
  sock = rt["external-controller-unix"] || base["external-controller-unix"]
  abort("Clash Verge socket not running") unless sock && File.socket?(sock)
  sec  = (rt["secret"] || base["secret"]).to_s
  hdr  = sec.empty? ? "" : "header = #{JSON.generate("Authorization: Bearer " + sec)}\n"
  api  = ->(p) { o, _, s = Open3.capture3("/usr/bin/curl", "-q", "-sf", "--noproxy", "*", "--unix-socket", sock, "--config", "-", "http://localhost#{p}", stdin_data: hdr); s.success? ? JSON.parse(o) : {} }
  rules = api.call("/rules").fetch("rules", []).select { |r| r["payload"].to_s.include?("claude") || r["payload"].to_s.include?("anthropic") }
  groups = api.call("/proxies").fetch("proxies", {}).select { |_, v| v["type"] == "Selector" }.transform_values { |v| v["now"] }
  puts JSON.pretty_generate({ claude_rules: rules, selector_groups_now: groups })
'
```

- 如果发现用户已有指向特定分组（如 `Claude专用`、`AI`、`Claude`）的分流规则，提取该分组名 `group` 及其当前选中的节点名 `node`。
- 若用户尚未配置 Claude 专用置顶规则，参考仓库内 `examples/clash.example.yaml` 告知用户需要在 Clash Verge 中添加置顶的 7 个官方 `DOMAIN-SUFFIX` 规则。
- 写入本地配置文件 `~/.config/claude-proxy-guard/config.json`（无需修改任何 `.rb` 或 `.swift` 源码）：
  ```json
  {
    "group": "<探测或确认的分组名>",
    "node": "<探测或确认的固定节点名>",
    "country": "US"
  }
  ```

### Step 3：构建并运行离线门禁自检

```sh
./scripts/build.sh
```

确认命令退出码为 0，输出包含 `IP 历史持久化与变更检测自检通过` 以及 `Built: .../.build/Claude Proxy Guard.app`。

### Step 4：安装并执行首次出口核验

若之前装过旧版（包括旧名 `Claude Egress Guard`），先退出 Claude 并执行 `./scripts/uninstall.sh`，然后安装：

```sh
./scripts/install.sh
"$HOME/Applications/Claude Proxy Guard.app/Contents/MacOS/ClaudeProxyGuard" --check
```

读取返回的 JSON：
- `"ok": true`：告知用户安装与开机自启已就绪（出口国家与打码后的 IP），以后直接从菜单栏或 `~/Applications/Claude Proxy Guard.app` 启动 Claude 即可。
- `"ok": false`：直接根据返回的中文 `message` 字段定位原因（例如系统代理未开、不是 Rule 模式、规则未置顶或出口非 US）并引导用户修复。
