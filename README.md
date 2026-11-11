# Claude Egress Guard · Claude 出口守卫

一个用 Swift + AppKit 编写的 macOS 菜单栏小工具：启动 Claude 桌面 App 前核验代理和美国出口，运行中监测连接，断网或检查失败时请求 Claude 正常退出。

A native macOS launcher and connection monitor for Claude Desktop, using an existing Clash Verge / Mihomo proxy setup.

## 功能

- 检查系统 HTTP/HTTPS 代理是否指向 Clash 的本地端口。
- 检查 Rule 模式、Claude 官方域名分流，以及选中的固定节点。
- 检查 Anthropic 连通性，并通过代理向 IPinfo 查询出口 IP 和国家；仅 US 检查通过时启动。
- 显示出口 IP、国家、核验时间和检测状态。
- Claude 运行期间每 5 秒检查连通性，每 60 秒复核出口国家。
- 监听本机网络状态；断网时取消待启动操作，并请求 Claude 正常退出。
- 支持菜单栏入口和登录自动启动。

实际流量转发由 Clash Verge / Mihomo 负责。守卫读取已有配置和本机控制接口，不提供代理节点，也不自动修改代理配置。

## 环境与配置

- macOS 13 或以上；当前在 Apple Silicon 的 macOS 27 上完成构建和自检。
- Xcode Command Line Tools：`xcode-select --install`。
- 系统 `/usr/bin/ruby`、`curl`；无需安装 Ruby gems 或 npm 包。
- Claude 安装在 `/Applications/Claude.app`。
- Clash Verge 安装并运行，开启系统代理、使用规则模式，保持其本机 Unix 控制接口可用。

当前版本有一个明确的配置约定：

| 项目 | 默认值 |
| --- | --- |
| Clash Verge 配置目录 | `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev` |
| Claude 专用分组 | `Claude专用` |
| 固定节点名称 | `供应商-HTTP` |
| 允许的出口国家 | `US` |

分组和节点只是名称，不包含节点凭据。使用自己的已有节点，并按需调整 `Resources/proxy_check.rb` 中的 `GROUP`、`NODE` 常量后重新构建。

[示例配置](examples/clash.example.yaml) 只有不可连接的占位节点，需自行填写。示例中的 Claude 官方域名及出口查询域名均走专用分组，其他流量 `DIRECT`。不要将真实节点、订阅链接、口令或本机配置提交到仓库。

检查器目前只接受专用分流配置：第一个 `MATCH` 前的规则均须为指向同一专用分组的 `DOMAIN-SUFFIX`，并覆盖源码列出的官方域名。复杂规则集需先调整检查器；请勿只删除检查来绕过失败。

## 构建与自检

```sh
git clone https://github.com/jiangyuan1018/claude-egress-guard.git
cd claude-egress-guard
./scripts/build.sh
```

生成 `.build/Claude Egress Guard.app`。构建脚本会编译原生应用、生成图标、检查 plist 和 Ruby 语法、执行 ad-hoc 签名及内置自检。

内置自检不访问网络，不启动或退出 Claude；覆盖美国出口启动门禁、离线拒绝、分流和系统代理异常，以及缺失、非法或非 US 的出口信息。

需要单独运行自检或真实网络检查时：

```sh
".build/Claude Egress Guard.app/Contents/MacOS/ClaudeEgressGuard" --self-test
".build/Claude Egress Guard.app/Contents/MacOS/ClaudeEgressGuard" --check
```

`--check` 输出 JSON，应读取 `ok` 字段判断结果。该输出会包含真实出口 IP；提交 issue 前请脱敏。应用为本机构建并进行 ad-hoc 签名，未进行 Apple 公证。

## 安装与使用

```sh
./scripts/install.sh
```

安装到 `~/Applications/Claude Egress Guard.app`，并注册当前用户的 LaunchAgent；登录 Mac 后在后台运行。打开应用即可先核验再启动 Claude，也可从菜单栏打开保护面板。

请只运行一个 Claude 守卫。安装脚本检测到早期个人版登录代理时会停止，避免两个守卫互相影响。早期个人版可继续使用，无需为了开源版本替换它。

退出或更新：先退出 Claude，运行下列脚本。更新时再构建和安装。

```sh
./scripts/uninstall.sh
```

卸载只删除此公开版应用及其 LaunchAgent，不删除 Claude、Clash 配置或用户数据。脚本没有自动更改 Dock 的行为。

## 图标

默认使用本项目绘制的紫色盾牌。可将自有或已获许可的正方形图片放在 `assets/Mascot.png` 后重新构建，详见 [assets/README.md](assets/README.md)。该文件默认被 Git 忽略。

个人版本中的角色图片未随开源代码分发；本仓库的 MIT 许可不授予任何第三方角色或图片的权利。

## 工作方式与边界

```text
Swift / AppKit 状态面板
    ├── Network.NWPathMonitor：监听网络状态
    ├── Ruby + curl：检查系统代理、Mihomo、Anthropic 和 IPinfo
    └── NSWorkspace：启动 Claude，或发送正常退出请求
```

- 守卫是启动检查和定期监控工具，不是系统防火墙。原图标启动拦截发生在应用启动通知之后，存在先发出请求的时间窗口；周期检查也存在间隔。
- 退出使用正常退出请求；Claude 的保存提示或退出拒绝可能需要手动处理，不会强制杀进程。
- 网络恢复后不会自动重新打开 Claude。
- IPinfo 的归属地结果、节点连通性和账号可用性是不同信号；检查通过不代表账号一定可用。
- 规则仅核验源码列出的官方域名；自定义 MCP、第三方连接器和其他外部服务不在出口保证范围内。
- 工具不读取浏览记录或聊天内容，不管理 Claude 的浏览器、MCP 或 macOS 设备权限，也不提供匿名身份或账号限制解除功能。

## 源码

| 文件 | 用途 |
| --- | --- |
| `Sources/ClaudeEgressGuard.swift` | 原生界面、启动门禁、网络监听和退出控制 |
| `Resources/proxy_check.rb` | 规则、系统代理、节点连通性及出口国家检查 |
| `tools/RenderIcons.swift` | 原创默认图标和自定义 PNG 的图标打包 |
| `scripts/` | 构建、安装、卸载 |

## License

[MIT](LICENSE)。本项目与 Anthropic、Clash Verge 及 Mihomo 无隶属关系。
