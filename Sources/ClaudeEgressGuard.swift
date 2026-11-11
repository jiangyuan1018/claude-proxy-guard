import AppKit
import Network

struct CheckResult: Decodable {
    let ok: Bool
    let message: String
    let ip: String?
    let country: String?

    init(ok: Bool, message: String, ip: String? = nil, country: String? = nil) {
        self.ok = ok
        self.message = message
        self.ip = ip
        self.country = country
    }
}

func mayOpenClaude(_ result: CheckResult, online: Bool?) -> Bool {
    result.ok && result.country == "US" && !(result.ip ?? "").isEmpty && online == true
}

func checkProxy(quick: Bool = false, selfTest: Bool = false) -> CheckResult {
    guard let script = Bundle.main.url(forResource: "proxy_check", withExtension: "rb") else {
        return CheckResult(ok: false, message: "检测文件缺失，请重新安装 Claude 出口守卫。")
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
    process.arguments = [script.path] + (quick ? ["--quick"] : []) + (selfTest ? ["--self-test"] : [])
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        return try JSONDecoder().decode(CheckResult.self, from: data)
    } catch {
        return CheckResult(ok: false, message: "无法运行出口检测，暂不允许启动 Claude。请确认 Clash Verge 已运行。")
    }
}


private func pixelColor(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

private enum PixelTheme {
    static let background = pixelColor(0x191326)
    static let panel = pixelColor(0x2A203C)
    static let grid = pixelColor(0x241C35)
    static let border = pixelColor(0x7A6098)
    static let ink = pixelColor(0xF7F0FF)
    static let muted = pixelColor(0xBCAECB)
    static let dim = pixelColor(0x887696)
    static let mint = pixelColor(0xB7ECCF)
    static let accent = pixelColor(0xCFAAFF)
    static let warning = pixelColor(0xF3A3BA)
    static let pressed = pixelColor(0xB58CDE)
    static let shadow = pixelColor(0x0D0915)
}

private final class PixelCanvas: NSView {
    override func draw(_ dirtyRect: NSRect) {
        PixelTheme.background.setFill()
        NSBezierPath(rect: bounds).fill()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for x in stride(from: 0, through: Int(bounds.width), by: 20) {
            grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: CGFloat(x), y: bounds.height))
        }
        for y in stride(from: 0, through: Int(bounds.height), by: 20) {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: CGFloat(y)))
        }
        PixelTheme.grid.setStroke()
        grid.stroke()
    }
}

private final class PixelSpriteView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private final class PixelButton: NSButton {
    var filled = true
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(120, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 28), height: filled ? 42 : 32)
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        PixelTheme.shadow.setFill()
        NSBezierPath(rect: bounds).fill()
        let rect = NSRect(x: 1, y: isHighlighted ? 1 : 4, width: bounds.width - 2, height: bounds.height - 5)
        let color = filled ? (isHighlighted ? PixelTheme.pressed : PixelTheme.accent) : PixelTheme.panel
        color.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(rect: rect).fill()
        (filled ? PixelTheme.accent : PixelTheme.border).withAlphaComponent(isEnabled ? 1 : 0.45).setStroke()
        let edge = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); edge.lineWidth = 1; edge.stroke()
        let textColor = filled ? PixelTheme.shadow : PixelTheme.ink
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: textColor.withAlphaComponent(isEnabled ? 1 : 0.65)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(rect: focusRingMaskBounds).fill() }
}

let claudeBundleID = "com.anthropic.claudefordesktop"
let claudeURL = URL(fileURLWithPath: "/Applications/Claude.app")

final class GuardApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSWindow!
    private let statusLine = NSMenuItem(title: "尚未核验美国出口", action: nil, keyEquivalent: "")
    private let ipMenuLine = NSMenuItem(title: "Claude 出口 IP：待核验", action: nil, keyEquivalent: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "先确认美国出口，再启动 Claude。")
    private let heroTitle = NSTextField(labelWithString: "核验后再出发")
    private let badgeLabel = NSTextField(labelWithString: "待核验")
    private let stateBadge = NSView()
    private let ipCaption = NSTextField(labelWithString: "出口 IP · 尚未核验")
    private let ipCard = NSView()
    private let ipLabel = NSTextField(labelWithString: "—")
    private let countryLabel = NSTextField(labelWithString: "国家待确认")
    private let checkedLabel = NSTextField(labelWithString: "尚无核验记录")
    private var launchButton: NSButton!
    private var refreshButton: NSButton!
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var checking = false
    private var online: Bool?
    private var pendingLaunch = false
    private var openingClaude = false
    private var permittedPID: pid_t?
    private var closingPIDs = Set<pid_t>()
    private var generation = 0
    private var lastFullCheck = Date.distantPast

    private var claudeApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).filter { !$0.isTerminated }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildMenu()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] event in
            guard let self = self,
                  let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == claudeBundleID else { return }
            if self.permittedPID == app.processIdentifier || (self.openingClaude && self.online == true) {
                self.permittedPID = app.processIdentifier
            } else {
                self.block("检测到通过原入口启动 Claude，已请求退出。请通过此面板先检查出口、再启动。")
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] event in
            guard let self = self,
                  let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == claudeBundleID else { return }
            self.closingPIDs.remove(app.processIdentifier)
            if self.permittedPID == app.processIdentifier { self.permittedPID = nil }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(available: path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ClaudeExitGuard.Network"))
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, !self.claudeApps.isEmpty, self.closingPIDs.isEmpty else { return }
            self.startCheck(full: Date().timeIntervalSince(self.lastFullCheck) >= 60)
        }
        RunLoop.main.add(timer!, forMode: .common)
        if !CommandLine.arguments.contains("--background") { requestLaunch() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestLaunch()
        return true
    }

    private func buildPanel() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 536), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Claude 出口守卫"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = PixelTheme.background
        panel.contentView = PixelCanvas()
        panel.center()
        if let url = Bundle.main.url(forResource: "Mascot", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let title = NSTextField(labelWithString: "Claude · 出口守卫")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = PixelTheme.ink
        let subtitle = NSTextField(labelWithString: "CLAUDE // EGRESS GUARD")
        subtitle.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        subtitle.textColor = PixelTheme.muted
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 4
        let local = NSTextField(labelWithString: "本地保护")
        local.font = .systemFont(ofSize: 10, weight: .medium); local.textColor = PixelTheme.muted
        let header = NSStackView(views: [heading, NSView(), local])
        header.orientation = .horizontal; header.alignment = .centerY

        stateBadge.wantsLayer = true
        stateBadge.layer?.backgroundColor = PixelTheme.accent.withAlphaComponent(0.08).cgColor
        stateBadge.layer?.borderColor = PixelTheme.accent.cgColor
        stateBadge.layer?.borderWidth = 1
        badgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = PixelTheme.accent
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        stateBadge.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            stateBadge.widthAnchor.constraint(equalToConstant: 72), stateBadge.heightAnchor.constraint(equalToConstant: 22),
            badgeLabel.centerXAnchor.constraint(equalTo: stateBadge.centerXAnchor), badgeLabel.centerYAnchor.constraint(equalTo: stateBadge.centerYAnchor)
        ])
        heroTitle.font = .systemFont(ofSize: 21, weight: .bold); heroTitle.textColor = PixelTheme.ink
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = PixelTheme.muted
        statusLabel.maximumNumberOfLines = 3
        let statusStack = NSStackView(views: [stateBadge, heroTitle, statusLabel])
        statusStack.orientation = .vertical; statusStack.alignment = .leading; statusStack.spacing = 8
        let sprite = PixelSpriteView()
        sprite.image = Bundle.main.url(forResource: "Mascot", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        sprite.setAccessibilityLabel("网络守卫图标")
        let hero = NSStackView(views: [statusStack, sprite])
        hero.orientation = .horizontal; hero.alignment = .centerY; hero.spacing = 12
        NSLayoutConstraint.activate([
            sprite.widthAnchor.constraint(equalToConstant: 128), sprite.heightAnchor.constraint(equalToConstant: 128),
            hero.heightAnchor.constraint(equalToConstant: 128), statusLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor)
        ])

        ipCard.wantsLayer = true
        ipCard.layer?.backgroundColor = PixelTheme.panel.cgColor
        ipCard.layer?.borderColor = PixelTheme.border.cgColor
        ipCard.layer?.borderWidth = 1.5
        ipCaption.font = .systemFont(ofSize: 11, weight: .medium); ipCaption.textColor = PixelTheme.muted
        ipLabel.font = .monospacedDigitSystemFont(ofSize: 27, weight: .semibold)
        ipLabel.textColor = PixelTheme.ink; ipLabel.isSelectable = true
        countryLabel.font = .systemFont(ofSize: 11, weight: .medium); countryLabel.textColor = PixelTheme.muted
        checkedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); checkedLabel.textColor = PixelTheme.muted
        let metadata = NSStackView(views: [countryLabel, NSView(), checkedLabel])
        metadata.orientation = .horizontal; metadata.alignment = .centerY
        let record = NSStackView(views: [ipCaption, ipLabel, metadata])
        record.orientation = .vertical; record.alignment = .leading; record.spacing = 8
        record.translatesAutoresizingMaskIntoConstraints = false
        ipCard.addSubview(record)
        NSLayoutConstraint.activate([
            ipCard.heightAnchor.constraint(equalToConstant: 112),
            record.leadingAnchor.constraint(equalTo: ipCard.leadingAnchor, constant: 16), record.trailingAnchor.constraint(equalTo: ipCard.trailingAnchor, constant: -16),
            record.topAnchor.constraint(equalTo: ipCard.topAnchor, constant: 14), record.bottomAnchor.constraint(lessThanOrEqualTo: ipCard.bottomAnchor, constant: -12),
            metadata.widthAnchor.constraint(equalTo: record.widthAnchor)
        ])

        launchButton = PixelButton(title: "核验并启动 Claude", target: self, action: #selector(requestLaunch))
        launchButton.keyEquivalent = "\r"; launchButton.isBordered = false; launchButton.focusRingType = .exterior
        let refresh = PixelButton(title: "刷新出口 IP", target: self, action: #selector(refresh))
        refresh.filled = false; refresh.isBordered = false
        refreshButton = refresh
        let clash = PixelButton(title: "打开代理面板", target: self, action: #selector(openClash))
        clash.filled = false; clash.isBordered = false
        let links = NSStackView(views: [refresh, clash])
        links.orientation = .horizontal; links.spacing = 12; links.distribution = .fillEqually
        let hint = NSTextField(wrappingLabelWithString: "连接每 5 秒检查 · 国家每 60 秒复核\n断网时请求正常退出；如有保存提示，请先保存。")
        hint.font = .systemFont(ofSize: 10); hint.textColor = PixelTheme.muted
        hint.alignment = .center
        let stack = NSStackView(views: [header, hero, ipCard, launchButton, links, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.setCustomSpacing(10, after: launchButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), hero.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ipCard.widthAnchor.constraint(equalTo: stack.widthAnchor), launchButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            launchButton.heightAnchor.constraint(equalToConstant: 44), links.widthAnchor.constraint(equalTo: stack.widthAnchor),
            links.heightAnchor.constraint(equalToConstant: 32), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func showChecking(_ text: String) {
        heroTitle.stringValue = "正在核验出口…"
        statusLabel.stringValue = text
        statusLabel.textColor = PixelTheme.muted
        badgeLabel.stringValue = "核验中"
        badgeLabel.textColor = PixelTheme.accent
        stateBadge.layer?.borderColor = PixelTheme.accent.cgColor
        stateBadge.layer?.backgroundColor = PixelTheme.accent.withAlphaComponent(0.08).cgColor
        if ipLabel.stringValue != "—" { ipCaption.stringValue = "上次核验出口 IP" }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(named: "MascotMenu") {
            image.size = NSSize(width: 20, height: 20)
            image.isTemplate = false
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Claude 出口守卫：先检查美国出口，再启动"
        statusLine.isEnabled = false
        ipMenuLine.isEnabled = false
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(ipMenuLine)
        menu.addItem(.separator())
        for (title, action) in [("打开保护面板", #selector(showPanel)), ("检查并打开 Claude", #selector(requestLaunch)), ("打开 Clash Verge", #selector(openClash))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出守卫（停止保护）", action: #selector(quitGuard), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setStatus(_ text: String, good: Bool) {
        heroTitle.stringValue = good ? "美国出口已就绪" : "本次检查未通过"
        statusLabel.stringValue = text
        statusLabel.textColor = PixelTheme.muted
        badgeLabel.stringValue = good ? "已就绪" : "需处理"
        let color = good ? PixelTheme.mint : PixelTheme.warning
        badgeLabel.textColor = color
        stateBadge.layer?.borderColor = color.cgColor
        stateBadge.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        ipCard.layer?.borderColor = (good ? PixelTheme.mint.withAlphaComponent(0.5) : PixelTheme.border).cgColor
        ipLabel.textColor = good ? PixelTheme.mint : PixelTheme.muted
        countryLabel.textColor = good ? PixelTheme.mint : PixelTheme.muted
        ipCaption.stringValue = good ? "Claude 专用出口 IP" : (ipLabel.stringValue == "—" ? "出口 IP · 尚未核验" : "上次核验出口 IP")
        statusLine.title = good ? "美国出口检查通过" : "尚未允许启动 / 已请求退出"
        statusItem.button?.title = good ? "" : "!"
        statusItem.button?.toolTip = text
    }

    private func networkChanged(available: Bool) {
        let changed = online != available
        online = available
        guard changed else { return }
        if !available {
            block("网络已断开：禁止启动，并已请求正在运行的 Claude 正常退出。")
        } else if pendingLaunch {
            startCheck(full: true)
        } else if !claudeApps.isEmpty && closingPIDs.isEmpty {
            startCheck(full: true)
        } else if panel.isVisible {
            setStatus("网络已连接，请重新核验美国出口后启动。", good: false)
        }
    }

    private func requestClaudeQuit() {
        for app in claudeApps where !closingPIDs.contains(app.processIdentifier) {
            closingPIDs.insert(app.processIdentifier)
            if !app.terminate() {
                setStatus("Claude 未接受自动退出请求。请保存未完成内容并手动退出。", good: false)
            }
        }
        permittedPID = nil
    }

    private func block(_ message: String) {
        let shouldShow = pendingLaunch || !claudeApps.isEmpty || panel.isVisible
        generation += 1
        pendingLaunch = false
        openingClaude = false
        setStatus(message, good: false)
        requestClaudeQuit()
        if shouldShow { showPanel() }
    }

    private func startCheck(full: Bool) {
        guard !checking, closingPIDs.isEmpty else { return }
        guard online == true else {
            if online == false { block("网络未连接，禁止启动 Claude。") }
            return
        }
        checking = true
        launchButton.isEnabled = false
        refreshButton.isEnabled = false
        let ticket = generation
        if full { showChecking("正在检查代理连接和美国出口，请稍候。") }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = checkProxy(quick: !full)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                self.launchButton.isEnabled = true
                self.refreshButton.isEnabled = true
                guard ticket == self.generation else { return }
                if let ip = result.ip {
                    self.ipLabel.stringValue = ip
                    self.ipLabel.font = .monospacedDigitSystemFont(ofSize: ip.count > 22 ? 17 : 27, weight: .semibold)
                    self.ipMenuLine.title = "Claude 出口 IP：" + ip
                    self.countryLabel.stringValue = result.country == "US" ? "美国 · US" : (result.country ?? "国家无法确认")
                    self.checkedLabel.stringValue = "核验于 " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                }
                guard result.ok, !full || mayOpenClaude(result, online: self.online) else {
                    self.block(result.ok ? "未取得有效的美国出口核验结果，禁止启动 Claude。" : result.message)
                    return
                }
                if full { self.lastFullCheck = Date() }
                self.setStatus("美国出口已核验，代理连通正常。运行中将持续监测。", good: true)
                if self.pendingLaunch {
                    if full { self.launchClaude(ticket: ticket) }
                    else { self.startCheck(full: true) }
                } else if let app = self.claudeApps.first {
                    self.permittedPID = app.processIdentifier
                }
            }
        }
    }

    private func launchClaude(ticket: Int) {
        pendingLaunch = false
        guard online == true, generation == ticket else { return }
        if let app = claudeApps.first {
            permittedPID = app.processIdentifier
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        openingClaude = true
        NSWorkspace.shared.openApplication(at: claudeURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.openingClaude = false
                guard error == nil, let app = app else {
                    self.setStatus("美国出口检查通过，但 Claude 未能启动。请确认 App 已安装。", good: false)
                    return
                }
                guard self.online == true, self.generation == ticket else {
                    self.requestClaudeQuit()
                    return
                }
                self.permittedPID = app.processIdentifier
            }
        }
    }

    @objc private func requestLaunch() {
        showPanel()
        guard closingPIDs.isEmpty else {
            setStatus("Claude 正在退出或等待保存。请先完成退出，再点击此入口。", good: false)
            return
        }
        pendingLaunch = true
        if online == nil { showChecking("正在确认网络连接…") }
        startCheck(full: true)
    }

    @objc private func refresh() { startCheck(full: true) }
    @objc private func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openClash() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Clash Verge.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func quitGuard() {
        let alert = NSAlert()
        alert.messageText = "退出 Claude 出口保护？"
        alert.informativeText = "退出后将停止启动检查和断网退出监测；下次登录电脑会恢复运行。"
        alert.addButton(withTitle: "继续保护")
        alert.addButton(withTitle: "退出守卫")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    let valid = CheckResult(ok: true, message: "ok", ip: "192.0.2.10", country: "US")
    precondition(mayOpenClaude(valid, online: true))
    precondition(!mayOpenClaude(valid, online: false))
    precondition(!mayOpenClaude(valid, online: nil))
    precondition(!mayOpenClaude(CheckResult(ok: true, message: "bad", ip: "192.0.2.20", country: "CN"), online: true))
    precondition(!mayOpenClaude(CheckResult(ok: false, message: "failed", ip: "192.0.2.10", country: "US"), online: true))
    precondition(!mayOpenClaude(CheckResult(ok: true, message: "missing IP", country: "US"), online: true))
    let decoded = try JSONDecoder().decode(CheckResult.self, from: Data("{\"ok\":false,\"message\":\"blocked\",\"ip\":\"192.0.2.20\",\"country\":\"CN\"}".utf8))
    precondition(decoded.ip == "192.0.2.20" && !mayOpenClaude(decoded, online: true))
    let result = checkProxy(selfTest: true)
    precondition(result.ok, result.message)
    print("启动门禁及离线拒绝自检通过；" + result.message)
} else if CommandLine.arguments.contains("--check") {
    let result = checkProxy(quick: CommandLine.arguments.contains("--quick"))
    var output: [String: Any] = ["ok": result.ok, "message": result.message]
    if let ip = result.ip { output["ip"] = ip }
    if let country = result.country { output["country"] = country }
    let data = try JSONSerialization.data(withJSONObject: output)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    let application = NSApplication.shared
    let delegate = GuardApp()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}
