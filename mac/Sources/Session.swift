// Device detection (bundled adb), per-device virtual display session.

import Foundation
import CoreGraphics
import AppKit

// MARK: - adb

/// Prefer an adb the user already has (avoids adb-server version fights), else the one bundled in the app.
let adbPath: String? = {
    for p in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return Bundle.main.url(forAuxiliaryExecutable: "adb")?.path
}()

let bundledAPK: URL? = Bundle.main.url(forResource: "TabDisplay", withExtension: "apk")
let appPackage = "kr.rimgosu.tabdisplay"
let releasesURL = URL(string: "https://github.com/rimgosu-vibe/tabdisplay/releases/latest")!

@discardableResult
func adb(_ args: [String], timeout: TimeInterval = 10) -> String {
    guard let adbPath else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adbPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let deadline = Date().addingTimeInterval(timeout)      // outputs we read are small (< pipe buffer)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning { p.terminate() }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// MARK: - Device

struct DeviceInfo {
    let serial: String
    let model: String
    let width: Int      // landscape pixels
    let height: Int
    let dpi: Int

    static func query(_ s: String) -> DeviceInfo {
        func prop(_ k: String) -> String { adb(["-s", s, "shell", "getprop", k]).trimmingCharacters(in: .whitespacesAndNewlines) }
        func pick(_ out: String, _ key: String) -> String? {
            // "Override size: WxH" wins over "Physical size: WxH"
            let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return (lines.first { $0.hasPrefix("Override \(key):") } ?? lines.first { $0.hasPrefix("Physical \(key):") })?
                .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let maker = prop("ro.product.manufacturer"), model = prop("ro.product.model")
        var w = 1920, h = 1200
        if let sz = pick(adb(["-s", s, "shell", "wm", "size"]), "size") {
            let p = sz.split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { w = max(p[0], p[1]); h = min(p[0], p[1]) }
        }
        let dpi = pick(adb(["-s", s, "shell", "wm", "density"]), "density").flatMap { Int($0) } ?? 320
        let name = model.isEmpty ? s : (model.lowercased().hasPrefix(maker.lowercased()) || maker.isEmpty ? model : "\(maker.capitalized) \(model)")
        return DeviceInfo(serial: s, model: name, width: w & ~1, height: h & ~1, dpi: dpi)
    }

    /// Stable non-zero 32-bit id from the adb serial (FNV-1a).
    var displaySerial: UInt32 {
        var h: UInt32 = 2166136261
        for b in serial.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h == 0 ? 1 : h
    }
}

// MARK: - Session (virtual display + capture lifetime)

final class Session {
    private let c: Config
    private let server: Server
    private var vd: VirtualDisplay?
    private var cap: Capturer?
    private var encoder: Encoder?
    private var cursor: CursorTracker?
    private var touch: TouchInput?
    private(set) var busy = false
    private(set) var device: DeviceInfo?
    private(set) var stream = (w: 1920, h: 1200)
    private(set) var lastError: String?
    var active: Bool { cap != nil }
    var onChange: (() -> Void)?

    init(_ c: Config, server: Server) {
        self.c = c
        self.server = server
        server.onKeyRequest = { [weak self] in self?.encoder?.requestKeyframe() }
        server.onClientReady = { [weak self] in self?.cursor?.resend() }
        server.onInput = { [weak self] d in DispatchQueue.main.async { self?.touch?.handle(d) } }
        server.hello = { [weak self] in
            let s = self?.stream ?? (1920, 1200)
            return "{\"w\":\(s.0),\"h\":\(s.1),\"fps\":\(c.fps)}"
        }
    }

    @MainActor func start(_ dev: DeviceInfo) async {
        guard vd == nil, !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "화면 녹화 권한이 필요합니다"; onChange?(); return
        }
        busy = true; defer { busy = false; onChange?() }
        device = dev

        let (pw, ph) = c.panel ?? (dev.width, dev.height)
        if let s = c.stream { stream = (s.0, s.1) } else {
            let k = min(1.0, Double(c.maxStreamEdge) / Double(max(pw, ph)))
            stream = (Int(Double(pw) * k) & ~1, Int(Double(ph) * k) & ~1)
        }
        let v = VirtualDisplay(name: "TabDisplay · \(dev.model)", width: pw, height: ph,
                               hiDPI: c.hiDPI, dpi: dev.dpi, serial: dev.displaySerial)
        vd = v
        log("virtual display on: \(dev.model) \(pw)x\(ph) (id=\(v.id)), stream \(stream.w)x\(stream.h)")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let enc = Encoder(width: stream.w, height: stream.h, fps: c.fps, bitrate: c.bitrate)
        enc.onFrame = { [server] data, key in server.broadcast(data, isKey: key) }
        encoder = enc
        let cp = Capturer()
        cp.onFrame = { [weak enc] pb in enc?.encode(pb) }
        do {
            try await cp.start(displayID: v.id, width: stream.w, height: stream.h, fps: c.fps)
            cap = cp
            let ct = CursorTracker(displayID: v.id) { [server] d in server.sendControl(d) }
            ct.start()
            cursor = ct
            touch = TouchInput(displayID: v.id)
            lastError = nil
            enc.requestKeyframe()
        } catch {
            log("capture failed: \(error.localizedDescription)")
            lastError = "화면 캡처 실패: \(error.localizedDescription)"
            encoder = nil
            vd = nil
        }
    }

    @MainActor func stop() async {
        guard vd != nil, !busy else { return }
        busy = true; defer { busy = false; onChange?() }
        await cap?.stop()
        cap = nil
        cursor?.stop(); cursor = nil
        touch = nil
        encoder = nil
        vd = nil          // releasing CGVirtualDisplay removes the display
        device = nil
        log("virtual display off")
    }
}

// MARK: - adb watcher (plugged in -> display on, unplugged -> off)

enum DeviceState: Equatable {
    case noAdb
    case none
    case unauthorized(String)
    case connected(String)      // model
}

final class AdbWatcher {
    private let c: Config
    private let session: Session
    private let server: Server
    private let q = DispatchQueue(label: "adb")
    private var current: String?
    private var info: DeviceInfo?
    private var lastStartAttempt = Date.distantPast

    // UI state (main thread)
    private(set) var state: DeviceState = .none
    private(set) var appInstalled: Bool?
    private(set) var installing = false
    var onChange: (() -> Void)?

    init(_ c: Config, session: Session, server: Server) { self.c = c; self.session = session; self.server = server }

    func start() {
        if adbPath == nil { state = .noAdb; log("adb not found"); return }
        log("adb: \(adbPath!)")
        q.async { self.tick() }
    }

    private func publish(_ s: DeviceState, installed: Bool?) {
        DispatchQueue.main.async {
            if self.state != s || self.appInstalled != installed {
                self.state = s; self.appInstalled = installed; self.onChange?()
            }
        }
    }

    private func tick() {
        defer { q.asyncAfter(deadline: .now() + 2) { self.tick() } }
        var ready: String?, unauthorized: String?
        for l in adb(["devices"]).split(separator: "\n").dropFirst() {
            let f = l.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2 else { continue }
            let serial = String(f[0]), st = String(f[1])
            if let want = c.serial, want != serial { continue }
            if st == "device" { ready = serial; break }
            if st == "unauthorized" { unauthorized = serial }
        }

        if let s = ready {
            if current != s {
                current = s
                let d = DeviceInfo.query(s)
                info = d
                log("device connected: \(s) \(d.model) \(d.width)x\(d.height) @\(d.dpi)dpi")
                let installed = isInstalled(s)
                publish(.connected(d.model), installed: installed)
                setup(s, installed: installed)
                startSession(d)
            } else {
                if !adb(["-s", s, "reverse", "--list"]).contains("tcp:\(c.wsPort)") { setup(s, installed: appInstalled ?? false) }
                // retry e.g. after the screen-recording permission was granted
                if let d = info { DispatchQueue.main.async {
                    if !self.session.active && !self.session.busy && Date().timeIntervalSince(self.lastStartAttempt) > 10 {
                        self.startSession(d)
                    }
                } }
            }
        } else {
            if current != nil {
                log("device disconnected: \(current!)")
                current = nil; info = nil
                DispatchQueue.main.async { Task { await self.session.stop() } }
            }
            publish(unauthorized.map { .unauthorized($0) } ?? .none, installed: nil)
        }
    }

    private func startSession(_ d: DeviceInfo) {
        DispatchQueue.main.async {
            self.lastStartAttempt = Date()
            Task { await self.session.start(d) }
        }
    }

    private func isInstalled(_ s: String) -> Bool {
        adb(["-s", s, "shell", "pm", "path", appPackage]).contains("package:")
    }

    private func setup(_ s: String, installed: Bool) {
        adb(["-s", s, "reverse", "tcp:\(c.httpPort)", "tcp:\(c.httpPort)"])
        adb(["-s", s, "reverse", "tcp:\(c.wsPort)", "tcp:\(c.wsPort)"])
        adb(["-s", s, "shell", "svc", "power", "stayon", "usb"])        // keep screen on while plugged in
        adb(["-s", s, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        if installed { launchApp(s); return }
        // No app: browser fallback (Chrome + WebCodecs). An open tab reconnects by itself.
        for _ in 0..<5 where server.clientCount == 0 { usleep(500_000) }
        if server.clientCount > 0 { return }
        let url = "http://localhost:\(c.httpPort)/"
        var a = ["-s", s, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url]
        if adb(["-s", s, "shell", "pm", "path", "com.android.chrome"]).contains("package:") { a += ["-p", "com.android.chrome"] }
        log("app not installed; opening \(url) in browser")
        adb(a)
    }

    private func launchApp(_ s: String) {
        log("launch \(appPackage)")
        adb(["-s", s, "shell", "am", "start", "-n", "\(appPackage)/.MainActivity"])
    }

    /// Install the APK bundled in TabDisplay.app onto the connected device.
    func installBundledApp() {
        guard let apk = bundledAPK, let s = current, !installing else { return }
        installing = true; onChange?()
        q.async {
            log("installing \(apk.lastPathComponent) on \(s)")
            let out = adb(["-s", s, "install", "-r", apk.path], timeout: 120)
            log("install: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            let ok = self.isInstalled(s)
            if ok { self.launchApp(s) }
            DispatchQueue.main.async {
                self.installing = false
                self.appInstalled = ok
                self.onChange?()
            }
        }
    }
}
