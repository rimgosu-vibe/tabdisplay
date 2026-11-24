// TabDisplay — use an Android tablet as an extended macOS display over USB.

import AppKit

let logPath = NSHomeDirectory() + "/Library/Logs/tabdisplay.log"
if isatty(STDOUT_FILENO) == 0 {            // launched from Finder / login item: log to file
    freopen(logPath, "a", stdout)
    freopen(logPath, "a", stderr)
}
setvbuf(stdout, nil, _IOLBF, 0)

func parseSize(_ s: String) -> (Int, Int)? {
    let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
    return p.count == 2 ? (p[0], p[1]) : nil
}

var cfg = Config()
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--panel": if let v = args.next(), let s = parseSize(v) { cfg.panel = s }
        case "--stream": if let v = args.next(), let s = parseSize(v) { cfg.stream = s }
        case "--fps": if let v = args.next(), let n = Int(v) { cfg.fps = n }
        case "--mbps": if let v = args.next(), let n = Double(v) { cfg.bitrate = Int(n * 1_000_000) }
        case "--no-hidpi": cfg.hiDPI = false
        case "--serial": cfg.serial = args.next()
        case "--port": if let v = args.next(), let n = UInt16(v) { cfg.httpPort = n; cfg.wsPort = n + 1 }
        case "-h", "--help":
            print("usage: tabdisplay [--panel WxH] [--stream WxH] [--fps 60] [--mbps 16] [--no-hidpi] [--port 8800] [--serial X]")
            exit(0)
        case _ where a.hasPrefix("-psn_"): break   // Finder process serial number
        default: print("unknown arg \(a)"); exit(2)
        }
    }
}

log("TabDisplay \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") starting")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let server = Server(cfg)
do { try server.start() } catch {
    log("server start failed: \(error)")
    let a = NSAlert()
    a.messageText = "TabDisplay를 시작할 수 없습니다"
    a.informativeText = "포트 \(cfg.httpPort)/\(cfg.wsPort)를 사용할 수 없습니다. TabDisplay가 이미 실행 중인지 확인하세요.\n\n\(error)"
    a.runModal()
    exit(1)
}

let session = Session(cfg, server: server)
let watcher = AdbWatcher(cfg, session: session, server: server)
let controller = AppController(watcher: watcher, session: session)
app.delegate = controller
watcher.start()

var _signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { log("bye"); exit(0) }
    src.resume()
    _signalSources.append(src)
}

app.run()
