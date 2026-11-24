// Menu bar item + setup/status window that walks the user through every permission.

import AppKit
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let watcher: AdbWatcher
    private let session: Session
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var window: NSWindow?
    private var rows: [String: SetupRow] = [:]
    private var footer: NSTextField!
    private var timer: Timer?
    private let screenGrantedAtLaunch = CGPreflightScreenCaptureAccess()

    init(watcher: AdbWatcher, session: Session) {
        self.watcher = watcher; self.session = session
        super.init()
        watcher.onChange = { [weak self] in self?.refresh() }
        session.onChange = { [weak self] in self?.refresh() }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "TabDisplay")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "TabDisplay", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정 및 상태…", action: #selector(showSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "로그 보기", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "TabDisplay 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // First launch: turn on "open at login" by default (user can turn it off in System Settings).
        if !UserDefaults.standard.bool(forKey: "loginItemAutoRegistered") {
            UserDefaults.standard.set(true, forKey: "loginItemAutoRegistered")
            if isInApplications { try? SMAppService.mainApp.register() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if !requiredDone { showSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup(); return true
    }

    // MARK: checks

    private var screenOK: Bool { CGPreflightScreenCaptureAccess() }
    private var axOK: Bool { AXIsProcessTrusted() }
    private var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    private var bundlePath: String { Bundle.main.bundlePath }
    private var isInApplications: Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    private var requiredDone: Bool {
        screenOK && axOK && isInApplications && loginStatus == .enabled && watcher.state != .noAdb
            && (watcher.appInstalled ?? true) && { if case .connected = watcher.state { return true }; return false }()
    }

    // MARK: window

    @objc func showSetup() {
        if window == nil { buildWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TabDisplay 설정"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let title = NSTextField(labelWithString: "Android 태블릿을 Mac 확장 모니터로")
        title.font = .boldSystemFont(ofSize: 17)
        let sub = NSTextField(wrappingLabelWithString: "아래 항목을 위에서부터 차례로 완료하세요. 상태는 자동으로 갱신됩니다.")
        sub.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(18, after: sub)

        for key in ["move", "screen", "ax", "login", "device", "app"] {
            let r = SetupRow()
            rows[key] = r
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        rows["move"]!.button.action = #selector(moveToApplications)
        rows["screen"]!.button.action = #selector(askScreen)
        rows["ax"]!.button.action = #selector(askAX)
        rows["login"]!.button.action = #selector(askLogin)
        rows["device"]!.button.action = #selector(deviceHelp)
        rows["app"]!.button.action = #selector(installApp)
        rows.values.forEach { $0.button.target = self }

        footer = NSTextField(wrappingLabelWithString: "")
        footer.textColor = .secondaryLabelColor
        stack.setCustomSpacing(18, after: rows["app"]!)
        stack.addArrangedSubview(footer)

        w.contentView = stack
        w.center()
        window = w
    }

    func refresh() {
        // Screen-recording grants only take effect after a relaunch.
        if !screenGrantedAtLaunch && screenOK { relaunch(); return }

        let deviceConnected: Bool
        let deviceText: String
        switch watcher.state {
        case .noAdb: deviceConnected = false; deviceText = "adb를 찾을 수 없습니다 (앱이 손상됐을 수 있음 — 다시 받아주세요)"
        case .none: deviceConnected = false; deviceText = "태블릿을 USB로 연결하세요. 처음이라면 태블릿에서 USB 디버깅을 켜야 합니다 → [방법 보기]"
        case .unauthorized: deviceConnected = false; deviceText = "태블릿 화면의 'USB 디버깅을 허용하시겠습니까?'에서 '이 컴퓨터에서 항상 허용'을 체크하고 [허용]을 누르세요."
        case .connected(let m): deviceConnected = true; deviceText = "\(m) 연결됨"
        }

        let status: String
        if session.active, let d = session.device {
            status = "확장 디스플레이 켜짐 — \(d.model) (\(d.width)×\(d.height))"
        } else if let e = session.lastError, deviceConnected {
            status = e
        } else if deviceConnected {
            status = "확장 디스플레이 준비 중…"
        } else {
            status = "태블릿 연결 대기 중"
        }
        statusLine?.title = status

        guard let _ = window else { return }

        rows["move"]!.isHidden = isInApplications
        rows["move"]!.set(ok: isInApplications, title: "응용 프로그램 폴더로 이동",
                          detail: "로그인 시 자동 실행을 위해 TabDisplay를 응용 프로그램 폴더에서 실행해야 합니다.",
                          button: "이동 후 다시 열기")
        rows["screen"]!.set(ok: screenOK, title: "화면 녹화 권한",
                            detail: screenOK ? "허용됨" : "Mac 화면을 태블릿으로 보내려면 필요합니다. [허용…]을 누르고 시스템 설정에서 TabDisplay를 켜세요. 켜면 앱이 자동으로 다시 시작됩니다.",
                            button: "허용…")
        rows["ax"]!.set(ok: axOK, title: "손쉬운 사용 권한 (터치 입력)",
                        detail: axOK ? "허용됨" : "태블릿 터치로 Mac 마우스를 조작하려면 필요합니다. [허용…]을 누르고 목록에서 TabDisplay를 켜세요.",
                        button: "허용…")
        let ls = loginStatus
        rows["login"]!.set(ok: ls == .enabled, title: "로그인 시 자동 실행",
                           detail: ls == .enabled ? "켜짐 — Mac을 켜면 TabDisplay가 백그라운드에서 대기합니다."
                               : ls == .requiresApproval ? "시스템 설정 > 일반 > 로그인 항목에서 TabDisplay를 허용하세요."
                               : "태블릿만 꽂으면 바로 연결되도록 로그인 시 자동으로 실행합니다.",
                           button: ls == .requiresApproval ? "설정 열기" : "켜기", enabled: isInApplications)
        rows["device"]!.set(ok: deviceConnected, title: "태블릿 연결 (USB 디버깅)", detail: deviceText,
                            button: "방법 보기", showButton: !deviceConnected)
        let inst = watcher.appInstalled
        rows["app"]!.set(ok: inst == true, pending: inst == nil, title: "태블릿 앱",
                         detail: inst == nil ? "태블릿을 연결하면 확인합니다."
                             : inst! ? "설치됨"
                             : watcher.installing ? "설치 중…"
                             : bundledAPK != nil ? "태블릿에 TabDisplay 앱이 없습니다. [설치]를 누르면 USB로 바로 설치합니다."
                             : "태블릿에 TabDisplay 앱이 없습니다. 릴리즈 페이지에서 APK를 받아 설치하세요.",
                         button: bundledAPK != nil ? "설치" : "다운로드", enabled: inst == false && !watcher.installing)
        footer.stringValue = "상태: \(status)\n\n화면 배치는 시스템 설정 > 디스플레이 > 정렬에서 바꿀 수 있고, 기기별로 기억됩니다. "
            + "메뉴 막대의 ▭ 아이콘에서 이 창을 다시 열 수 있습니다."
    }

    // MARK: actions

    @objc private func askScreen() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    @objc private func askAX() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    @objc private func askLogin() {
        if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        do { try SMAppService.mainApp.register() } catch {
            log("login item register failed: \(error)")
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    @objc private func deviceHelp() {
        let a = NSAlert()
        a.messageText = "태블릿에서 USB 디버깅 켜기"
        a.informativeText = """
        1. 태블릿 설정 > 태블릿 정보(휴대폰 정보)에서 '빌드 번호'(또는 '버전 번호')를 7번 연속 탭 → 개발자 옵션이 켜집니다.
        2. 설정 > 시스템(또는 추가 설정) > 개발자 옵션 > 'USB 디버깅'을 켭니다.
        3. USB 케이블로 Mac에 연결하고, 태블릿에 뜨는 'USB 디버깅 허용' 창에서 '이 컴퓨터에서 항상 허용'을 체크한 뒤 [허용]을 누릅니다.

        케이블이 충전 전용이면 인식되지 않습니다. 데이터 전송이 되는 케이블을 쓰세요.
        """
        a.runModal()
    }

    @objc private func installApp() {
        if bundledAPK != nil { watcher.installBundledApp() } else { NSWorkspace.shared.open(releasesURL) }
    }

    @objc private func moveToApplications() {
        let dest = "/Applications/TabDisplay.app"
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest) { try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil) }
            try fm.copyItem(atPath: bundlePath, toPath: dest)
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest])
            relaunch(at: dest)
        } catch {
            let a = NSAlert(error: error)
            a.informativeText = "Finder에서 TabDisplay.app을 응용 프로그램 폴더로 직접 옮긴 뒤 다시 열어주세요."
            a.runModal()
        }
    }

    private func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private func relaunch(at path: String? = nil) {
        let p = path ?? bundlePath
        log("relaunching \(p)")
        // wait for this instance to exit (ports are freed), then open again
        run("/bin/sh", ["-c", "sleep 1; /usr/bin/open \"$0\"", p])
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
        if exe != "/bin/sh" { p.waitUntilExit() }
        return p
    }
}

// MARK: - Row view

final class SetupRow: NSStackView {
    private let icon = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 10
        icon.font = .systemFont(ofSize: 18)
        title.font = .boldSystemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.preferredMaxLayoutWidth = 400
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        button.bezelStyle = .rounded
        icon.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(icon)
        addArrangedSubview(text)
        addArrangedSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(ok: Bool, pending: Bool = false, title t: String, detail d: String, button b: String,
             enabled: Bool = true, showButton: Bool? = nil) {
        icon.stringValue = ok ? "✅" : pending ? "⏳" : "⚠️"
        title.stringValue = t
        detail.stringValue = d
        button.title = b
        button.isHidden = !(showButton ?? !ok)
        button.isEnabled = enabled
    }
}
