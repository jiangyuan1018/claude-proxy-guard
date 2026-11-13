import AppKit
import Network
import UserNotifications

enum FailureKind: String, Codable {
    case configuration, country, leak, transient
}

struct CheckResult: Decodable {
    let ok: Bool
    let message: String
    let ip: String?
    let country: String?
    let expectedCountry: String?
    let kind: FailureKind?
    let code: String?

    init(ok: Bool, message: String, ip: String? = nil, country: String? = nil, expectedCountry: String? = nil, kind: FailureKind? = nil, code: String? = nil) {
        self.ok = ok
        self.message = message
        self.ip = ip
        self.country = country
        self.expectedCountry = expectedCountry
        self.kind = kind
        self.code = code
    }
}

enum MonitorDecision { case allow, retry, warn, block }

struct RuntimePolicy {
    static let transientWarnThreshold = 3
    private(set) var failures = 0

    mutating func evaluate(_ result: CheckResult, running: Bool, pendingLaunch: Bool, userInitiated: Bool = false) -> MonitorDecision {
        if result.ok { failures = 0; return .allow }
        failures += 1
        // Network loss is handled by NWPathMonitor; failed probes alone never quit a running session.
        if result.kind == .country || result.kind == .leak { return .block }
        if !running && pendingLaunch { return .block }
        if result.kind == .transient && !userInitiated && failures < Self.transientWarnThreshold { return .retry }
        return .warn
    }
}

struct NetworkGate {
    static let settleDelay: TimeInterval = 2.0
    private(set) var online: Bool?
    private(set) var readyAt: Date = .distantPast

    mutating func updateOnline(_ available: Bool, now: Date = Date()) -> (changed: Bool, delay: TimeInterval?) {
        let wasOnline = online
        online = available
        guard wasOnline != available else { return (false, nil) }
        guard available else {
            readyAt = .distantPast
            return (true, nil)
        }
        if wasOnline == false {
            readyAt = now.addingTimeInterval(Self.settleDelay)
            return (true, Self.settleDelay)
        }
        return (true, 0)
    }

    mutating func markWake(now: Date = Date()) -> TimeInterval {
        readyAt = max(readyAt, now.addingTimeInterval(Self.settleDelay))
        return max(0, readyAt.timeIntervalSince(now))
    }

    func canPoll(now: Date = Date()) -> Bool {
        online == true && now >= readyAt
    }
}

func testRuntimePolicy() throws {
    var policy = RuntimePolicy()
    let timeout = CheckResult(ok: false, message: "测试超时", kind: .transient, code: "timeout")
    for attempt in 1...2 {
        guard policy.evaluate(timeout, running: true, pendingLaunch: false) == .retry else {
            throw NSError(domain: "GuardRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "第 \(attempt) 次瞬时超时未防抖静默重试。"])
        }
    }
    for attempt in 3...20 {
        guard policy.evaluate(timeout, running: true, pendingLaunch: false) == .warn else {
            throw NSError(domain: "GuardRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "连续第 \(attempt) 次测速超时误触发退出，应当仅告警。"])
        }
    }
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: true, pendingLaunch: false) == .allow)
    precondition(policy.failures == 0)
    precondition(policy.evaluate(timeout, running: false, pendingLaunch: false) == .retry)
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: false, pendingLaunch: false) == .allow)
    precondition(policy.evaluate(timeout, running: false, pendingLaunch: false, userInitiated: true) == .warn)
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: false, pendingLaunch: false) == .allow)
    precondition(policy.evaluate(timeout, running: true, pendingLaunch: true, userInitiated: true) == .warn)
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: true, pendingLaunch: false) == .allow)
    precondition(policy.evaluate(timeout, running: false, pendingLaunch: true, userInitiated: true) == .block)
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: true, pendingLaunch: false) == .allow)
    precondition(policy.evaluate(CheckResult(ok: false, message: "configuration", kind: .configuration), running: true, pendingLaunch: false) == .warn)
    precondition(policy.evaluate(CheckResult(ok: true, message: "ok"), running: true, pendingLaunch: false) == .allow)
    precondition(policy.evaluate(CheckResult(ok: false, message: "country unknown", ip: "192.0.2.10", kind: .transient), running: true, pendingLaunch: false) == .retry)
    precondition(policy.evaluate(CheckResult(ok: false, message: "non-US", ip: "192.0.2.20", country: "CN", kind: .country), running: true, pendingLaunch: false) == .block)
    precondition(policy.evaluate(CheckResult(ok: false, message: "direct leak", kind: .leak, code: "route_leak"), running: true, pendingLaunch: false) == .block)

    var gate = NetworkGate()
    let t0 = Date(timeIntervalSince1970: 1_000)
    precondition(!gate.canPoll(now: t0))
    let cold = gate.updateOnline(true, now: t0)
    precondition(cold.changed && cold.delay == 0 && gate.canPoll(now: t0))
    precondition(!gate.updateOnline(true, now: t0).changed)
    let off = gate.updateOnline(false, now: t0.addingTimeInterval(10))
    precondition(off.changed && off.delay == nil && !gate.canPoll(now: t0.addingTimeInterval(15)))
    let reconn = gate.updateOnline(true, now: t0.addingTimeInterval(20))
    precondition(reconn.changed && reconn.delay == 2.0)
    precondition(!gate.canPoll(now: t0.addingTimeInterval(21.5)))
    precondition(gate.canPoll(now: t0.addingTimeInterval(22.0)))
    let wakeDelay = gate.markWake(now: t0.addingTimeInterval(50))
    precondition(wakeDelay == 2.0 && !gate.canPoll(now: t0.addingTimeInterval(51.0)) && gate.canPoll(now: t0.addingTimeInterval(52.0)))
}

struct IPRecord: Codable {
    var firstSeen: Date
    var lastSeen: Date
    let ip: String
    let country: String?
    var checks: Int
}

struct GuardEvent: Codable {
    let date: Date
    let kind: String
    let code: String
    let message: String
}

struct IPChange {
    let previous: IPRecord
    let current: IPRecord
    var message: String { "\(previous.ip)（\(previous.country ?? "未知")） → \(current.ip)（\(current.country ?? "未知")）" }
}

final class IPHistory {
    struct Snapshot: Codable {
        var records: [IPRecord] = []
        var events: [GuardEvent] = []
    }
    let url: URL
    private(set) var snapshot = Snapshot()
    private var loadError: Error?

    init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: url))
            } catch { loadError = error }
        }
    }

    func observe(_ result: CheckResult, at date: Date = Date()) -> IPChange? {
        guard let ip = result.ip, IPv4Address(ip) != nil || IPv6Address(ip) != nil else { return nil }
        let previous = snapshot.records.last
        if let previous = previous, previous.ip == ip, previous.country == result.country {
            snapshot.records[snapshot.records.count - 1].lastSeen = date
            snapshot.records[snapshot.records.count - 1].checks += 1
            return nil
        }
        let current = IPRecord(firstSeen: date, lastSeen: date, ip: ip, country: result.country, checks: 1)
        snapshot.records.append(current)
        snapshot.records = Array(snapshot.records.suffix(500))
        guard let previous = previous, previous.ip != ip else { return nil }
        let change = IPChange(previous: previous, current: current)
        record("ip_changed", code: "ip_changed", message: change.message, at: date)
        return change
    }

    func record(_ kind: String, code: String, message: String, at date: Date = Date()) {
        snapshot.events.append(GuardEvent(date: date, kind: kind, code: code, message: message))
        snapshot.events = Array(snapshot.events.suffix(1000))
    }

    func save() throws {
        // Preserve an unreadable history file rather than silently replacing it.
        if let error = loadError { throw error }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var recentChanges: Int {
        zip(snapshot.records, snapshot.records.dropFirst()).filter { $0.ip != $1.ip && $1.firstSeen > Date().addingTimeInterval(-86400) }.count
    }
}

func testIPHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeGuardTest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ip-history.json")
    let history = IPHistory(url: url)
    let first = CheckResult(ok: true, message: "ok", ip: "192.0.2.10", country: "US")
    precondition(history.observe(first) == nil)
    precondition(history.observe(first) == nil)
    precondition(history.snapshot.records.count == 1 && history.snapshot.records[0].checks == 2)
    precondition(history.observe(CheckResult(ok: false, message: "timeout", kind: .transient)) == nil)
    precondition(history.observe(CheckResult(ok: false, message: "invalid", ip: "invalid")) == nil)
    try history.save()
    let reloaded = IPHistory(url: url)
    precondition(reloaded.observe(first) == nil)
    let change = reloaded.observe(CheckResult(ok: true, message: "ok", ip: "192.0.2.20", country: "US"))
    precondition(change?.previous.ip == first.ip && change?.current.ip == "192.0.2.20")
    precondition(reloaded.observe(CheckResult(ok: false, message: "non-US", ip: "192.0.2.30", country: "CN", kind: .country)) != nil)
    precondition(reloaded.snapshot.events.filter { $0.kind == "ip_changed" }.count == 2)
    reloaded.record("quit_requested", code: "country", message: "test")
    try reloaded.save()
    precondition(IPHistory(url: url).snapshot.events.last?.kind == "quit_requested")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let original = Data("invalid history".utf8)
    try original.write(to: url)
    let invalid = IPHistory(url: url)
    do { try invalid.save(); preconditionFailure("Unreadable history was overwritten") }
    catch { let preserved = try Data(contentsOf: url); precondition(preserved == original) }
}

func mayOpenClaude(_ result: CheckResult, online: Bool?) -> Bool {
    let target = (result.expectedCountry ?? "US").uppercased()
    return result.ok && result.country == target && !(result.ip ?? "").isEmpty && online == true
}

func checkProxy(quick: Bool = false, selfTest: Bool = false) -> CheckResult {
    guard let script = Bundle.main.url(forResource: "proxy_check", withExtension: "rb") else {
        return CheckResult(ok: false, message: "检测文件缺失，请重新安装 Claude 代理守卫。", kind: .configuration, code: "checker_missing")
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
        return CheckResult(ok: false, message: "无法运行出口检测，暂不允许启动 Claude。请确认 Clash Verge 已运行。", kind: .transient, code: "checker_error")
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

final class GuardApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSWindow!
    private let statusLine = NSMenuItem(title: "尚未核验代理出口", action: nil, keyEquivalent: "")
    private let ipMenuLine = NSMenuItem(title: "Claude 出口 IP：待核验", action: nil, keyEquivalent: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "先确认代理出口，再启动 Claude。")
    private let heroTitle = NSTextField(labelWithString: "核验后再出发")
    private let badgeLabel = NSTextField(labelWithString: "待核验")
    private let stateBadge = NSView()
    private let ipCaption = NSTextField(labelWithString: "出口 IP · 尚未核验")
    private let ipCard = NSView()
    private let ipLabel = NSTextField(labelWithString: "—")
    private let countryLabel = NSTextField(labelWithString: "国家待确认")
    private let checkedLabel = NSTextField(labelWithString: "尚无核验记录")
    private let historyNote = NSTextField(wrappingLabelWithString: "IP 历史仅保存在本机")
    private let history = IPHistory(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClaudeEgressGuard")
        .appendingPathComponent("ip-history.json"))
    private var historyWindow: NSWindow?
    private var historyText: NSTextView?
    private var historyError: String?
    private var changeAlert: NSAlert?
    private var launchButton: NSButton!
    private var refreshButton: NSButton!
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var settleWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var checking = false
    private var networkGate = NetworkGate()
    private var online: Bool? { networkGate.online }
    private var pendingLaunch = false
    private var openingClaude = false
    private var permittedPID: pid_t?
    private var closingPIDs = Set<pid_t>()
    private var generation = 0
    private var lastFullAttempt = Date.distantPast
    private var lastMonitoringAlert = Date.distantPast
    private var exitWarning: String?
    private var runtimePolicy = RuntimePolicy()

    private var claudeApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).filter { !$0.isTerminated }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildMenu()
        if let last = history.snapshot.records.last {
            displayExit(ip: last.ip, country: last.country, at: last.lastSeen)
            ipCaption.stringValue = "上次记录出口 IP"
        }
        recordEvent("guard_started", code: "startup", message: "守卫已启动；IP 每 60 秒核验，连续 3 次探测超时才告警，断网、出口国家不符或连接直连防漏时请求退出。")
        configureNotifications()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] event in
            guard let self = self,
                  let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == claudeBundleID else { return }
            if self.permittedPID == app.processIdentifier || (self.openingClaude && self.online == true) {
                self.permittedPID = app.processIdentifier
            } else {
                self.block("检测到通过原入口启动 Claude，已请求退出。请通过此面板先检查出口、再启动。", reason: "original_launcher")
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] event in
            guard let self = self,
                  let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == claudeBundleID else { return }
            let requested = self.closingPIDs.remove(app.processIdentifier) != nil
            self.recordEvent("claude_exited", code: requested ? "guard_requested" : "external_exit", message: requested ? "已观察到 Claude 在守卫请求后退出。" : "已观察到 Claude 退出；本次没有守卫的退出请求。")
            if self.permittedPID == app.processIdentifier { self.permittedPID = nil }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let delay = self.networkGate.markWake()
            self.recordEvent("system_wake", code: "wake", message: "系统从休眠唤醒，等待 \(Int(delay)) 秒链路稳定后复核出口。")
            self.scheduleSettledCheck(after: delay)
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(available: path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ClaudeExitGuard.Network"))
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, self.closingPIDs.isEmpty, self.networkGate.canPoll() else { return }
            let active = !self.claudeApps.isEmpty || self.pendingLaunch
            let retryInterval: TimeInterval = (self.runtimePolicy.failures > 0 || self.exitWarning != nil) ? 15 : 60
            let full = Date().timeIntervalSince(self.lastFullAttempt) >= retryInterval
            if active || full { self.startCheck(full: full) }
        }
        RunLoop.main.add(timer!, forMode: .common)
        if !CommandLine.arguments.contains("--background") { requestLaunch() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestLaunch()
        return true
    }

    private func buildPanel() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Claude 代理守卫"
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
        let title = NSTextField(labelWithString: "Claude · 代理守卫")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = PixelTheme.ink
        let subtitle = NSTextField(labelWithString: "CLAUDE // PROXY GUARD")
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
        let historyButton = PixelButton(title: "IP 历史与退出原因", target: self, action: #selector(showHistory))
        historyButton.filled = false; historyButton.isBordered = false
        let links = NSStackView(views: [refresh, clash, historyButton])
        links.orientation = .horizontal; links.spacing = 12; links.distribution = .fillEqually
        historyNote.font = .systemFont(ofSize: 10); historyNote.textColor = PixelTheme.muted
        let hint = NSTextField(wrappingLabelWithString: "连接与防漏每 5 秒检查 · IP 每 60 秒记录 · 变化时提醒\n连续 3 次探测超时才提醒；断网、确认非目标出口或连接直连防漏时请求退出。")
        hint.font = .systemFont(ofSize: 10); hint.textColor = PixelTheme.muted
        hint.alignment = .center
        let stack = NSStackView(views: [header, hero, ipCard, launchButton, links, historyNote, hint])
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
            links.heightAnchor.constraint(equalToConstant: 32), hint.widthAnchor.constraint(equalTo: stack.widthAnchor), historyNote.widthAnchor.constraint(equalTo: stack.widthAnchor)
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
        statusItem.button?.toolTip = "Claude 代理守卫：先检查代理出口，再启动"
        statusLine.isEnabled = false
        ipMenuLine.isEnabled = false
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(ipMenuLine)
        menu.addItem(.separator())
        for (title, action) in [("打开保护面板", #selector(showPanel)), ("检查并打开 Claude", #selector(requestLaunch)), ("IP 历史与退出原因", #selector(showHistory)), ("打开 Clash Verge", #selector(openClash))] {
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
        heroTitle.stringValue = good ? "代理出口已就绪" : "本次检查未通过"
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
        statusLine.title = good ? "代理出口检查通过" : "检查未通过，详情见历史"
        statusItem.button?.title = good ? "" : "!"
        statusItem.button?.toolTip = text
    }

    private func persistHistory() {
        do { try history.save(); historyError = nil }
        catch { historyError = "历史记录无法保存；原文件不会被覆盖。请检查记录文件或目录权限。" }
        historyNote.stringValue = historyError ?? "近 24 小时 IP 变化 \(history.recentChanges) 次 · 历史与退出原因仅保存在本机"
        updateHistoryText()
    }

    private func displayExit(ip: String, country: String?, at date: Date) {
        ipLabel.stringValue = ip
        ipLabel.font = .monospacedDigitSystemFont(ofSize: ip.count > 22 ? 17 : 27, weight: .semibold)
        ipMenuLine.title = "Claude 出口 IP：" + ip
        countryLabel.stringValue = country == "US" ? "美国 · US" : (country ?? "国家无法确认")
        checkedLabel.stringValue = "核验于 " + DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    private func recordEvent(_ kind: String, code: String, message: String) {
        history.record(kind, code: code, message: message)
        persistHistory()
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if !granted {
                        DispatchQueue.main.async { self?.recordEvent("notification_unavailable", code: "notification_disabled", message: "系统通知未启用；IP 变化仍会弹出守卫提示。") }
                    }
                }
            }
        }
    }

    private func notifyMonitorWarning(_ result: CheckResult) {
        guard Date().timeIntervalSince(lastMonitoringAlert) >= 600 else { return }
        lastMonitoringAlert = Date()
        recordEvent("monitor_warning", code: result.code ?? "check_warning", message: "仅提醒，未请求 Claude 退出。" + result.message)
        let content = UNMutableNotificationContent()
        content.title = "Claude 网络检测告警"
        content.body = result.message + "\nClaude 保持运行，守卫将继续复核出口。"
        content.sound = .default
        content.threadIdentifier = "ClaudeGuard.MonitorWarnings"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async { self?.recordEvent("notification_unavailable", code: "warning_notification_unavailable", message: "系统通知未能发送；检测告警已显示在守卫面板。") }
            }
        }
        panel.orderFrontRegardless()
    }

    private func notifyIPChange(_ change: IPChange, expectedCountry: String) {
        let explanation = change.current.country == expectedCountry ? "新出口仍符合目标国家（\(expectedCountry)）；IP 变化本身不会触发退出。" : "新出口尚未通过目标国家核验，请查看保护状态。"
        let content = UNMutableNotificationContent()
        content.title = "Claude 出口 IP 已变化"
        content.body = change.message + "\n" + explanation
        content.sound = .default
        content.threadIdentifier = "ClaudeGuard.IPChanges"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async { self?.recordEvent("notification_unavailable", code: "notification_not_delivered", message: "系统通知未能发送；已使用守卫弹窗提醒 IP 变化。") }
            }
        }
        showPanel()
        if let alert = changeAlert {
            alert.informativeText = change.message + "\n\n" + explanation
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude 出口 IP 发生变化"
        alert.informativeText = change.message + "\n\n" + explanation
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "查看历史")
        changeAlert = alert
        alert.beginSheetModal(for: panel) { [weak self] response in
            self?.changeAlert = nil
            if response == .alertSecondButtonReturn { self?.showHistory() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showHistory() }
        completionHandler()
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "IP 历史与退出原因"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 500, height: 360)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = PixelTheme.background
            window.center()
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 460))
            text.isEditable = false; text.isSelectable = true
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textColor = PixelTheme.ink; text.backgroundColor = PixelTheme.panel
            text.textContainerInset = NSSize(width: 12, height: 12)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            historyText = text
            let reveal = NSButton(title: "在 Finder 中显示记录文件", target: self, action: #selector(revealHistory))
            reveal.bezelStyle = .rounded; reveal.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(scroll); window.contentView!.addSubview(reveal)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
                scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
                scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
                scroll.bottomAnchor.constraint(equalTo: reveal.topAnchor, constant: -12),
                reveal.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
                reveal.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12)
            ])
            historyWindow = window
        }
        updateHistoryText()
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateHistoryText() {
        guard let text = historyText else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        let labels = ["guard_started": "守卫启动", "ip_changed": "IP 变化", "check_failed": "检测失败", "check_recovered": "检测恢复", "monitor_warning": "仅提醒，未退出", "network_offline": "网络断开", "network_online": "网络连接", "system_wake": "系统唤醒", "blocked": "保护拦截", "quit_requested": "请求退出", "quit_rejected": "退出未接受", "claude_exited": "Claude 已退出", "notification_unavailable": "通知状态"]
        var lines = ["出口 IP 历史", "同一 IP 的连续核验会合并；时间为本机时间。仅保留最近 500 段记录和 1000 条事件。", ""]
        if let error = historyError { lines += [error, ""] }
        if history.snapshot.records.isEmpty { lines += ["尚无出口核验记录。", ""] }
        for record in history.snapshot.records.reversed() {
            lines += [formatter.string(from: record.firstSeen) + " → " + formatter.string(from: record.lastSeen), "\(record.ip)  ·  \(record.country ?? "国家未知")  ·  核验 \(record.checks) 次", ""]
        }
        lines += ["检测与退出事件（最新在前）", ""]
        for event in history.snapshot.events.reversed() {
            lines += [formatter.string(from: event.date) + "  [" + (labels[event.kind] ?? event.kind) + "]", event.message, ""]
        }
        text.string = lines.joined(separator: "\n")
    }

    @objc private func revealHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([history.url])
    }

    private func scheduleSettledCheck(after delay: TimeInterval) {
        settleWorkItem?.cancel()
        guard delay > 0 else {
            startCheck(full: true, userInitiated: pendingLaunch)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.online == true else { return }
            self.startCheck(full: true, userInitiated: self.pendingLaunch)
        }
        settleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func networkChanged(available: Bool) {
        let transition = networkGate.updateOnline(available)
        guard transition.changed, let onlineNow = online else { return }
        if !onlineNow {
            settleWorkItem?.cancel()
            recordEvent("network_offline", code: "network_offline", message: "macOS 网络状态变为断开。")
            block("网络已断开：禁止启动，并已请求正在运行的 Claude 正常退出。", reason: "network_offline")
        } else if let delay = transition.delay, delay > 0 {
            recordEvent("network_online", code: "network_online", message: "macOS 网络已恢复，等待 \(Int(delay)) 秒链路稳定后重新核验出口。")
            if panel.isVisible || pendingLaunch {
                showChecking("网络刚恢复，等待链路稳定后核验出口…")
            }
            scheduleSettledCheck(after: delay)
        } else {
            recordEvent("network_online", code: "network_online", message: "macOS 网络已连接，开始重新核验出口。")
            startCheck(full: true, userInitiated: pendingLaunch)
        }
    }

    private func requestClaudeQuit(reason: String, message: String) {
        for app in claudeApps where !closingPIDs.contains(app.processIdentifier) {
            closingPIDs.insert(app.processIdentifier)
            recordEvent("quit_requested", code: reason, message: "已请求 Claude 桌面 App（含 Code 页面）正常退出。原因：" + message)
            if !app.terminate() {
                recordEvent("quit_rejected", code: reason, message: "Claude 未接受退出请求，可能正在等待保存或用户处理。")
                setStatus("Claude 未接受自动退出请求。请保存未完成内容并手动退出。", good: false)
            }
        }
        permittedPID = nil
    }

    private func block(_ message: String, reason: String = "protection_blocked") {
        let shouldShow = pendingLaunch || !claudeApps.isEmpty || panel.isVisible
        generation += 1
        pendingLaunch = false
        openingClaude = false
        recordEvent("blocked", code: reason, message: message)
        setStatus(message, good: false)
        requestClaudeQuit(reason: reason, message: message)
        if shouldShow { showPanel() }
    }

    private func startCheck(full: Bool, userInitiated: Bool = false) {
        guard !checking, closingPIDs.isEmpty else { return }
        guard online == true else {
            if online == false && (userInitiated || !claudeApps.isEmpty) {
                block("网络未连接，禁止启动 Claude。")
            }
            return
        }
        if !networkGate.canPoll() {
            if userInitiated {
                showChecking("网络刚恢复，等待链路稳定后核验出口…")
                scheduleSettledCheck(after: max(0.1, networkGate.readyAt.timeIntervalSinceNow))
            }
            return
        }
        checking = true
        if full { lastFullAttempt = Date() }
        launchButton.isEnabled = false
        refreshButton.isEnabled = false
        let ticket = generation
        if full && (userInitiated || ipLabel.stringValue == "—") {
            showChecking("正在检查代理连接和目标出口，请稍候。")
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = checkProxy(quick: !full)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                self.launchButton.isEnabled = true
                self.refreshButton.isEnabled = true
                guard ticket == self.generation else { return }
                if let ip = result.ip {
                    self.displayExit(ip: ip, country: result.country, at: Date())
                    let change = self.history.observe(result)
                    self.persistHistory()
                    if let change = change { self.notifyIPChange(change, expectedCountry: result.expectedCountry ?? "US") }
                }
                let previousFailures = self.runtimePolicy.failures
                let previousExitWarning = self.exitWarning
                let running = !self.claudeApps.isEmpty
                let decision = self.runtimePolicy.evaluate(result, running: running, pendingLaunch: self.pendingLaunch, userInitiated: userInitiated)
                if !result.ok {
                    let suffix = decision == .retry ? "（瞬时波动防抖，静默待重试 \(self.runtimePolicy.failures)/\(RuntimePolicy.transientWarnThreshold)）" : ""
                    self.recordEvent("check_failed", code: result.code ?? "unclassified_failure", message: "\(full ? "出口完整核验" : "连通性检查")失败，第 \(self.runtimePolicy.failures) 次\(suffix)：" + result.message)
                }
                if decision == .retry { return }
                if full { self.exitWarning = result.ip == nil || result.country == nil ? result.message : nil }
                if decision == .warn {
                    self.pendingLaunch = false
                    self.setStatus((running ? "仅提醒，Claude 保持运行。" : "本次检测未通过，启动前需重新核验。") + result.message, good: false)
                    self.heroTitle.stringValue = "检测告警，继续监测"
                    self.badgeLabel.stringValue = "告警"
                    self.statusLine.title = running ? "检测告警，Claude 继续运行" : "出口尚待核验"
                    if running { self.notifyMonitorWarning(result) }
                    return
                }
                guard decision == .allow, !full || mayOpenClaude(result, online: self.online) else {
                    let message = result.ok ? "未取得有效的目标出口核验结果，禁止启动 Claude。" : result.message
                    self.block(message, reason: result.code ?? "invalid_exit")
                    return
                }
                if (previousFailures > 0 || (full && previousExitWarning != nil)) && self.exitWarning == nil {
                    self.recordEvent("check_recovered", code: "recovered", message: "检测恢复正常，失败计数已清零。")
                }
                if let warning = self.exitWarning {
                    self.setStatus("连通性检查通过，出口信息仍待复核。" + warning, good: false)
                    self.heroTitle.stringValue = "出口信息待复核"
                    self.statusLine.title = "出口信息待复核，Claude 继续运行"
                } else {
                    self.setStatus(result.message, good: true)
                }
                if self.pendingLaunch {
                    if full { self.launchClaude(ticket: ticket) }
                    else { self.startCheck(full: true, userInitiated: userInitiated) }
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
                    self.setStatus("代理出口检查通过，但 Claude 未能启动。请确认 App 已安装。", good: false)
                    return
                }
                guard self.online == true, self.generation == ticket else {
                    self.requestClaudeQuit(reason: "launch_cancelled", message: "启动过程中网络或保护状态发生变化。")
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
        startCheck(full: true, userInitiated: true)
    }

    @objc private func refresh() { startCheck(full: true, userInitiated: true) }
    @objc private func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openClash() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Clash Verge.app"), configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func quitGuard() {
        let alert = NSAlert()
        alert.messageText = "退出 Claude 代理守卫？"
        alert.informativeText = "退出后将停止启动检查和断网退出监测；下次登录电脑会恢复运行。"
        alert.addButton(withTitle: "继续保护")
        alert.addButton(withTitle: "退出守卫")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try testRuntimePolicy(); try testIPHistory() }
    catch { fputs("回归测试失败：\(error.localizedDescription)\n", stderr); exit(1) }
    let valid = CheckResult(ok: true, message: "ok", ip: "192.0.2.10", country: "US")
    precondition(mayOpenClaude(valid, online: true))
    precondition(!mayOpenClaude(valid, online: false))
    precondition(!mayOpenClaude(valid, online: nil))
    precondition(!mayOpenClaude(CheckResult(ok: true, message: "bad", ip: "192.0.2.20", country: "CN"), online: true))
    precondition(mayOpenClaude(CheckResult(ok: true, message: "jp", ip: "192.0.2.30", country: "JP", expectedCountry: "JP"), online: true))
    precondition(!mayOpenClaude(CheckResult(ok: true, message: "mismatch", ip: "192.0.2.10", country: "US", expectedCountry: "JP"), online: true))
    precondition(!mayOpenClaude(CheckResult(ok: false, message: "failed", ip: "192.0.2.10", country: "US"), online: true))
    precondition(!mayOpenClaude(CheckResult(ok: true, message: "missing IP", country: "US"), online: true))
    let decoded = try JSONDecoder().decode(CheckResult.self, from: Data("{\"ok\":false,\"message\":\"blocked\",\"ip\":\"192.0.2.20\",\"country\":\"CN\",\"expectedCountry\":\"US\"}".utf8))
    precondition(decoded.ip == "192.0.2.20" && decoded.expectedCountry == "US" && !mayOpenClaude(decoded, online: true))
    let result = checkProxy(selfTest: true)
    precondition(result.ok, result.message)
    print("启动门禁、检测失败重试、IP 历史持久化与变更检测自检通过；" + result.message)
} else if CommandLine.arguments.contains("--check") {
    let result = checkProxy(quick: CommandLine.arguments.contains("--quick"))
    var output: [String: Any] = ["ok": result.ok, "message": result.message]
    if let ip = result.ip { output["ip"] = ip }
    if let country = result.country { output["country"] = country }
    if let expectedCountry = result.expectedCountry { output["expectedCountry"] = expectedCountry }
    if let kind = result.kind { output["kind"] = kind.rawValue }
    if let code = result.code { output["code"] = code }
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
