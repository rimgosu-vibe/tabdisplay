// tabdisplay — macOS virtual display streamed to an Android tablet browser over USB (adb reverse).
//
//  CGVirtualDisplay (private API) -> ScreenCaptureKit -> VideoToolbox H.264 -> WebSocket
//  -> tablet browser (WebCodecs VideoDecoder -> <canvas>)

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox
import Network
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

// MARK: - Config

struct Config {
    var panelW = 2944, panelH = 1840        // Xiaoxin Pad Pro 12.7 native panel
    var hiDPI = true                         // looks like 1472x920 (Retina)
    var streamW = 1920, streamH = 1200       // encoded stream size
    var fps = 60
    var bitrate = 16_000_000
    var httpPort: UInt16 = 8800
    var wsPort: UInt16 = 8801
    var name = "Lenovo Tab"
    var adb = true                           // watch adb: plug in -> display on
    var serial: String? = nil
}

func parseSize(_ s: String) -> (Int, Int)? {
    let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
    return p.count == 2 ? (p[0], p[1]) : nil
}

var cfg = Config()
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--panel": if let v = args.next(), let s = parseSize(v) { (cfg.panelW, cfg.panelH) = s }
        case "--stream": if let v = args.next(), let s = parseSize(v) { (cfg.streamW, cfg.streamH) = s }
        case "--fps": if let v = args.next(), let n = Int(v) { cfg.fps = n }
        case "--mbps": if let v = args.next(), let n = Double(v) { cfg.bitrate = Int(n * 1_000_000) }
        case "--no-hidpi": cfg.hiDPI = false
        case "--no-adb": cfg.adb = false
        case "--serial": cfg.serial = args.next()
        case "--port": if let v = args.next(), let n = UInt16(v) { cfg.httpPort = n; cfg.wsPort = n + 1 }
        case "-h", "--help":
            print("""
            usage: tabdisplay [--panel 2944x1840] [--stream 1920x1200] [--fps 60] [--mbps 16] [--no-hidpi] [--port 8800] [--no-adb] [--serial X]
            """)
            exit(0)
        default: print("unknown arg \(a)"); exit(2)
        }
    }
}

// MARK: - Virtual display

final class VirtualDisplay {
    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    init(_ c: Config) {
        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = c.name
        d.maxPixelsWide = UInt32(c.panelW)
        d.maxPixelsHigh = UInt32(c.panelH)
        d.sizeInMillimeters = CGSize(width: 274, height: 171)   // 12.7" 16:10
        d.vendorID = 0x17ef
        d.productID = 0x201c
        d.serialNum = 0x7AB1                                     // fixed -> macOS remembers arrangement
        d.terminationHandler = { _, _ in log("virtual display terminated") }
        display = CGVirtualDisplay(descriptor: d)

        let s = CGVirtualDisplaySettings()
        s.hiDPI = c.hiDPI ? 1 : 0
        if c.hiDPI {
            // HiDPI: modes are in points; backing store is 2x.
            s.modes = [
                CGVirtualDisplayMode(width: UInt32(c.panelW / 2), height: UInt32(c.panelH / 2), refreshRate: 60),
                CGVirtualDisplayMode(width: UInt32(c.panelW * 2 / 3), height: UInt32(c.panelH * 2 / 3), refreshRate: 60),
            ]
        } else {
            s.modes = [CGVirtualDisplayMode(width: UInt32(c.panelW), height: UInt32(c.panelH), refreshRate: 60)]
        }
        if !display.apply(s) { log("applySettings failed") }
    }
}

// MARK: - Encoder

final class Encoder {
    private var session: VTCompressionSession?
    private let q = DispatchQueue(label: "encoder")
    private var forceKey = true
    private var lastPB: CVPixelBuffer?
    var onFrame: ((Data, Bool) -> Void)?

    init(width: Int, height: Int, fps: Int, bitrate: Int) {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let s = session else { log("VTCompressionSessionCreate failed \(st)"); exit(1) }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 5,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 5,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if r != noErr { log("warn: VTSessionSetProperty \(k) -> \(r)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pb: CVPixelBuffer) {
        q.async { self.lastPB = pb; self.encodeLocked(pb) }
    }

    /// Force a keyframe; re-encode the last frame so a newly connected client gets a picture
    /// even when the screen is static (ScreenCaptureKit only emits frames on change).
    func requestKeyframe() {
        q.async {
            self.forceKey = true
            if let pb = self.lastPB { self.encodeLocked(pb) }
        }
    }

    private func encodeLocked(_ pb: CVPixelBuffer) {
        guard let s = session else { return }
        var fp: CFDictionary?
        if forceKey { fp = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; forceKey = false }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: fp, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb)
        }
    }

    private func emit(_ sb: CMSampleBuffer) {
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data([isKey ? 1 : 0])

        if isKey, let fd = sb.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?; var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                   parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let p { out.append(contentsOf: startCode); out.append(p, count: n) }
            }
        }

        guard let bb = sb.dataBuffer else { return }
        let len = CMBlockBufferGetDataLength(bb)
        var avcc = Data(count: len)
        avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        // AVCC (4-byte length prefix) -> Annex B
        var i = 0
        while i + 4 <= len {
            let n = Int(avcc[i]) << 24 | Int(avcc[i+1]) << 16 | Int(avcc[i+2]) << 8 | Int(avcc[i+3])
            i += 4
            guard n > 0, i + n <= len else { break }
            out.append(contentsOf: startCode)
            out.append(avcc[i..<i+n])
            i += n
        }
        onFrame?(out, isKey)
    }
}

// MARK: - Capture

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let q = DispatchQueue(label: "capture")
    var onFrame: ((CVPixelBuffer) -> Void)?

    func start(displayID: CGDirectDisplayID, c: Config) async throws {
        var target: SCDisplay?
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw NSError(domain: "tabdisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not found in SCShareableContent"]) }
        log("capturing display \(displayID) (\(target.width)x\(target.height) pt) -> \(c.streamW)x\(c.streamH) @\(c.fps)fps")

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let sc = SCStreamConfiguration()
        sc.width = c.streamW
        sc.height = c.streamH
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.fps))
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        sc.showsCursor = false                // cursor is sent separately (type 2/3) and drawn on the tablet
        sc.queueDepth = 6
        sc.capturesAudio = false
        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        onFrame?(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
    }
}

// MARK: - Server (HTTP page + WebSocket video)

final class Client {
    let conn: NWConnection
    var pending = 0
    var needKey = true
    init(_ c: NWConnection) { conn = c }
}

final class Server {
    private let q = DispatchQueue(label: "server")
    private var clients: [ObjectIdentifier: Client] = [:]
    var clientCount: Int { q.sync { clients.count } }
    private var http: NWListener?
    private var ws: NWListener?
    private let c: Config
    var onKeyRequest: (() -> Void)?
    var onClientReady: (() -> Void)?

    init(_ c: Config) { self.c = c }

    func start() throws {
        let hp = NWParameters.tcp
        hp.allowLocalEndpointReuse = true
        let h = try NWListener(using: hp, on: NWEndpoint.Port(rawValue: c.httpPort)!)
        h.newConnectionHandler = { [weak self] conn in self?.serveHTTP(conn) }
        h.start(queue: q)
        http = h

        let wp = NWParameters.tcp
        wp.allowLocalEndpointReuse = true
        let wso = NWProtocolWebSocket.Options()
        wso.autoReplyPing = true
        wp.defaultProtocolStack.applicationProtocols.insert(wso, at: 0)
        let w = try NWListener(using: wp, on: NWEndpoint.Port(rawValue: c.wsPort)!)
        w.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        w.start(queue: q)
        ws = w
        log("http://localhost:\(c.httpPort)/  (ws :\(c.wsPort))")
    }

    private func serveHTTP(_ conn: NWConnection) {
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
            let body = Data(pageHTML.replacingOccurrences(of: "__WSPORT__", with: String(self.c.wsPort)).utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            head += "Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func accept(_ conn: NWConnection) {
        let cl = Client(conn)
        let key = ObjectIdentifier(cl)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.clients[key] = cl
                log("client connected (\(self.clients.count))")
                let hello = "{\"w\":\(self.c.streamW),\"h\":\(self.c.streamH),\"fps\":\(self.c.fps)}"
                let tm = NWProtocolWebSocket.Metadata(opcode: .text)
                conn.send(content: Data(hello.utf8), contentContext: NWConnection.ContentContext(identifier: "hello", metadata: [tm]),
                          isComplete: true, completion: .idempotent)
                self.onKeyRequest?()
                self.onClientReady?()
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: key) != nil { log("client disconnected (\(self.clients.count))") }
            default: break
            }
        }
        conn.start(queue: q)
        receiveLoop(cl)
    }

    private func receiveLoop(_ cl: Client) {
        cl.conn.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if err != nil { cl.conn.cancel(); return }
            if let data, String(data: data, encoding: .utf8) == "key" {
                cl.needKey = true
                self.onKeyRequest?()
            }
            self.receiveLoop(cl)
        }
    }

    /// Small out-of-band messages (cursor). Skipped for clients that are backed up.
    func sendControl(_ data: Data) {
        q.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let ctx = NWConnection.ContentContext(identifier: "ctl", metadata: [meta])
            for cl in self.clients.values where cl.pending < 8 {
                cl.pending += 1
                cl.conn.send(content: data, contentContext: ctx, isComplete: true,
                             completion: .contentProcessed { _ in self.q.async { cl.pending -= 1 } })
            }
        }
    }

    func broadcast(_ data: Data, isKey: Bool) {
        q.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
            for cl in self.clients.values {
                if cl.needKey && !isKey { continue }
                if cl.pending > 4 && !isKey {        // client/USB can't keep up: drop until next keyframe
                    cl.needKey = true
                    self.onKeyRequest?()
                    continue
                }
                if isKey { cl.needKey = false }
                cl.pending += 1
                cl.conn.send(content: data, contentContext: ctx, isComplete: true,
                             completion: .contentProcessed { _ in self.q.async { cl.pending -= 1 } })
            }
        }
    }
}

// MARK: - Tablet page

let pageHTML = #"""
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no,viewport-fit=cover">
<title>tabdisplay</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;touch-action:none}
canvas{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain}
#msg{position:fixed;left:16px;bottom:16px;color:#aaa;font:15px system-ui,sans-serif;background:#0008;padding:6px 10px;border-radius:6px}
</style></head>
<body><canvas id="c"></canvas><img id="cur" style="position:fixed;left:0;top:0;display:none;pointer-events:none;will-change:transform"><div id="msg">connecting…</div>
<script>
const WSPORT=__WSPORT__;
const cv=document.getElementById('c'), g=cv.getContext('2d',{alpha:false,desynchronized:true}), msg=document.getElementById('msg');
const show=t=>{msg.textContent=t;msg.style.display=t?'block':'none'};
let dec=null, codec=null, needKey=true, ts=0, ws=null;

function codecOf(u8){
  for(let i=0;i+6<u8.length;i++){
    if(u8[i]===0&&u8[i+1]===0&&u8[i+2]===1&&(u8[i+3]&0x1f)===7)
      return 'avc1.'+[u8[i+4],u8[i+5],u8[i+6]].map(b=>b.toString(16).padStart(2,'0')).join('');
  }
  return null;
}
function resetDecoder(){
  if(dec&&dec.state!=='closed'){try{dec.close()}catch(e){}}
  codec=null; needKey=true;
  dec=new VideoDecoder({
    output:f=>{
      if(cv.width!==f.displayWidth||cv.height!==f.displayHeight){cv.width=f.displayWidth;cv.height=f.displayHeight}
      g.drawImage(f,0,0); f.close();
      if(msg.style.display!=='none') show('');
    },
    error:e=>{console.error(e); show('decoder error: '+e.message); resetDecoder(); reqKey();}
  });
}
const cur=document.getElementById('cur'); let cw=0,ch=0,hx=0,hy=0,cx=-1,cy=-1,curURL=null;
function rect(){const r=cv.getBoundingClientRect(),vw=cv.width||16,vh=cv.height||10,s=Math.min(r.width/vw,r.height/vh);return{x:r.left+(r.width-vw*s)/2,y:r.top+(r.height-vh*s)/2,w:vw*s,h:vh*s}}
function placeCursor(){if(cx<0){cur.style.display='none';return}const r=rect();cur.style.width=(cw*r.w)+'px';cur.style.height=(ch*r.h)+'px';cur.style.transform='translate('+(r.x+cx*r.w-hx*cw*r.w)+'px,'+(r.y+cy*r.h-hy*ch*r.h)+'px)';cur.style.display='block'}
function cursorMsg(u8){const dv=new DataView(u8.buffer,u8.byteOffset,u8.byteLength);
  if(u8[0]===2){cx=dv.getFloat32(1,true);cy=dv.getFloat32(5,true);requestAnimationFrame(placeCursor);}
  else if(u8[0]===3){hx=dv.getFloat32(1,true);hy=dv.getFloat32(5,true);cw=dv.getFloat32(9,true);ch=dv.getFloat32(13,true);
    if(curURL)URL.revokeObjectURL(curURL);curURL=URL.createObjectURL(new Blob([u8.subarray(17)],{type:'image/png'}));cur.src=curURL;placeCursor();}}
function reqKey(){needKey=true; if(ws&&ws.readyState===1) ws.send('key');}
function connect(){
  ws=new WebSocket('ws://'+location.hostname+':'+WSPORT);
  ws.binaryType='arraybuffer';
  ws.onopen=()=>{show('waiting for video…'); resetDecoder();};
  ws.onmessage=e=>{
    if(typeof e.data==='string') return;
    const u8=new Uint8Array(e.data), key=u8[0]===1, data=u8.subarray(1);
    if(u8[0]>=2){cursorMsg(u8);return;}
    if(needKey&&!key) return;
    if(key){
      const c=codecOf(data);
      if(c&&c!==codec){dec.configure({codec:c,optimizeForLatency:true,hardwareAcceleration:'prefer-hardware'}); codec=c;}
      if(!codec) return;
    }
    if(dec.decodeQueueSize>8){reqKey(); return;}
    needKey=false;
    dec.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:(ts+=16667),data}));
  };
  ws.onclose=()=>{show('disconnected — retrying…'); setTimeout(connect,1000);};
  ws.onerror=()=>{};
}
let wl=null;
async function wake(){try{if(!wl||wl.released) wl=await navigator.wakeLock.request('screen')}catch(e){}}
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')wake()});
document.addEventListener('click',()=>{const d=document.documentElement; (d.requestFullscreen||d.webkitRequestFullscreen||(()=>{})).call(d); wake();});
if(!('VideoDecoder' in window)){
  show('WebCodecs 미지원 브라우저입니다. Chrome에서 http://localhost:'+location.port+' 로 열어주세요. (secure='+window.isSecureContext+')');
}else{ wake(); connect(); setTimeout(()=>{if(msg.style.display!=='none'&&msg.textContent.startsWith('waiting'))show('화면을 탭하면 전체화면')},4000); }
</script>
</body></html>
"""#

// MARK: - Cursor (sent out-of-band so it doesn't wait for capture/encode/decode)
//
//  type 2: [2][f32 x][f32 y]                       normalized to the virtual display (x<0 => hidden)
//  type 3: [3][f32 hotX][f32 hotY][f32 w][f32 h][PNG]  hot spot in 0..1 of the image, w/h relative to display size

final class CursorTracker {
    private let displayID: CGDirectDisplayID
    private let send: (Data) -> Void
    private var timer: DispatchSourceTimer?
    private var lastPos: (Float, Float) = (-2, -2)
    private var lastImageKey = 0
    private var lastImageMsg: Data?
    private var tick = 0

    init(displayID: CGDirectDisplayID, send: @escaping (Data) -> Void) {
        self.displayID = displayID; self.send = send
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))   // ~120Hz
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Re-send current cursor (new client).
    func resend() {
        DispatchQueue.main.async {
            if let m = self.lastImageMsg { self.send(m) }
            self.lastPos = (-2, -2)
        }
    }

    private static func f32(_ v: Float, into d: inout Data) {
        var x = v.bitPattern.littleEndian
        withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }

    private func poll() {
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, let loc = CGEvent(source: nil)?.location else { return }
        tick += 1
        if tick % 12 == 1 { updateImage(bounds: b) }    // ~10Hz shape check
        var x = Float((loc.x - b.minX) / b.width), y = Float((loc.y - b.minY) / b.height)
        if x < 0 || x > 1 || y < 0 || y > 1 { x = -1; y = -1 }
        if (x, y) == lastPos { return }
        lastPos = (x, y)
        var d = Data([2]); Self.f32(x, into: &d); Self.f32(y, into: &d)
        send(d)
    }

    private func updateImage(bounds b: CGRect) {
        guard let cur = NSCursor.currentSystem else { return }
        let img = cur.image
        let key = img.hashValue ^ Int(img.size.width * 1000 + img.size.height) ^ Int(cur.hotSpot.x * 7 + cur.hotSpot.y * 13) ^ Int(b.width)
        if key == lastImageKey { return }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        // NSImage identity can change for the same cursor; skip if bytes identical
        var d = Data([3])
        Self.f32(Float(cur.hotSpot.x / img.size.width), into: &d)
        Self.f32(Float(cur.hotSpot.y / img.size.height), into: &d)
        Self.f32(Float(img.size.width / b.width), into: &d)
        Self.f32(Float(img.size.height / b.height), into: &d)
        d.append(png)
        lastImageKey = key
        if d == lastImageMsg { return }
        lastImageMsg = d
        send(d)
    }
}

// MARK: - Session (virtual display + capture lifetime)

final class Session {
    private var vd: VirtualDisplay?
    private var cap: Capturer?
    private let c: Config
    private let encoder: Encoder
    private var busy = false
    private var cursor: CursorTracker?
    var sendControl: ((Data) -> Void)?
    func resendCursor() { cursor?.resend() }
    var active: Bool { vd != nil }

    init(_ c: Config, encoder: Encoder) { self.c = c; self.encoder = encoder }

    @MainActor func start() async {
        guard vd == nil, !busy else { return }
        busy = true; defer { busy = false }
        let v = VirtualDisplay(c)
        vd = v
        log("virtual display on (id=\(v.id))")
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let m = CGDisplayCopyDisplayMode(v.id) {
            log("display mode: \(m.width)x\(m.height) pt, \(m.pixelWidth)x\(m.pixelHeight) px")
        }
        let cp = Capturer()
        cp.onFrame = { [encoder] pb in encoder.encode(pb) }
        do {
            try await cp.start(displayID: v.id, c: c)
            cap = cp
            let ct = CursorTracker(displayID: v.id) { [weak self] d in self?.sendControl?(d) }
            ct.start()
            cursor = ct
        } catch {
            log("capture failed: \(error.localizedDescription)")
            log("→ 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹화 에서 TabDisplay를 허용하세요.")
            vd = nil
            // TCC grants often need a relaunch; launchd (KeepAlive) restarts us.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(1) }
        }
    }

    @MainActor func stop() async {
        guard vd != nil, !busy else { return }
        busy = true; defer { busy = false }
        await cap?.stop()
        cap = nil
        cursor?.stop()
        cursor = nil
        vd = nil          // releasing CGVirtualDisplay removes the display
        log("virtual display off")
    }
}

// MARK: - adb watcher (tablet plugged in -> display on, unplugged -> off)

let adbPath = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "adb"

@discardableResult
func adb(_ args: [String], timeout: TimeInterval = 10) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adbPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning { p.terminate() }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

final class AdbWatcher {
    private let c: Config
    private let session: Session
    private var current: String?
    private var warnedUnauthorized = false
    private let q = DispatchQueue(label: "adb")

    init(_ c: Config, session: Session) { self.c = c; self.session = session }

    func start() { q.async { self.tick() } }

    private func tick() {
        let lines = adb(["devices"]).split(separator: "\n").dropFirst()
        var ready: String?
        for l in lines {
            let f = l.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2 else { continue }
            let serial = String(f[0]), state = String(f[1])
            if let want = c.serial, want != serial { continue }
            if state == "device" { ready = serial; break }
            if state == "unauthorized" && !warnedUnauthorized {
                warnedUnauthorized = true
                log("tablet \(serial) is unauthorized — 태블릿에서 'USB 디버깅 허용'을 눌러주세요")
            }
        }
        if let s = ready, current != s {
            current = s
            warnedUnauthorized = false
            log("tablet connected: \(s)")
            setup(s)
            DispatchQueue.main.async { Task { await self.session.start() } }
        } else if ready == nil, current != nil {
            log("tablet disconnected: \(current!)")
            current = nil
            DispatchQueue.main.async { Task { await self.session.stop() } }
        } else if let s = ready, !adbReverseOK(s) {
            setup(s)   // adb server restarted etc.
        }
        q.asyncAfter(deadline: .now() + 2) { self.tick() }
    }

    private func adbReverseOK(_ s: String) -> Bool {
        adb(["-s", s, "reverse", "--list"]).contains("tcp:\(c.wsPort)")
    }

    private func setup(_ s: String) {
        adb(["-s", s, "reverse", "tcp:\(c.httpPort)", "tcp:\(c.httpPort)"])
        adb(["-s", s, "reverse", "tcp:\(c.wsPort)", "tcp:\(c.wsPort)"])
        adb(["-s", s, "shell", "svc", "power", "stayon", "usb"])        // keep screen on while plugged in
        adb(["-s", s, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        // Prefer the native Android app (rimgosu-vibe/tabdisplay releases); fall back to Chrome.
        let appPkg = "kr.rimgosu.tabdisplay"
        if adb(["-s", s, "shell", "pm", "path", appPkg]).contains("package:") {
            log("launch \(appPkg) on tablet")
            adb(["-s", s, "shell", "am", "start", "-n", "\(appPkg)/.MainActivity"])
            return
        }
        let url = "http://localhost:\(c.httpPort)/"
        let hasChrome = adb(["-s", s, "shell", "pm", "path", "com.android.chrome"]).contains("package:")
        var a = ["-s", s, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url]
        if hasChrome { a += ["-p", "com.android.chrome"] }
        // An already-open tab reconnects by itself (retries every 1s) — don't pile up new tabs.
        for _ in 0..<5 where server.clientCount == 0 { usleep(500_000) }
        if server.clientCount > 0 { log("tablet page already connected"); return }
        log("open \(url) on tablet\(hasChrome ? " (Chrome)" : "")")
        adb(a)
    }
}

// MARK: - Main

let server = Server(cfg)
let encoder = Encoder(width: cfg.streamW, height: cfg.streamH, fps: cfg.fps, bitrate: cfg.bitrate)
encoder.onFrame = { data, key in server.broadcast(data, isKey: key) }
server.onKeyRequest = { encoder.requestKeyframe() }
do { try server.start() } catch { log("server start failed: \(error)"); exit(1) }

let session = Session(cfg, encoder: encoder)
session.sendControl = { d in server.sendControl(d) }
server.onClientReady = { session.resendCursor() }
var watcher: AdbWatcher?
if cfg.adb {
    log("watching adb (\(adbPath)) for tablet…")
    watcher = AdbWatcher(cfg, session: session)
    watcher!.start()
} else {
    Task { @MainActor in await session.start() }
}

var _signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { log("bye"); exit(0) }
    src.resume()
    _signalSources.append(src)
}
dispatchMain()
