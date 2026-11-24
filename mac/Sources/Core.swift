// TabDisplay core — virtual display, capture, H.264 encode, WebSocket server, cursor, touch.
//
//  CGVirtualDisplay (private API) -> ScreenCaptureKit -> VideoToolbox H.264 -> WebSocket (adb reverse)
//  -> Android app (MediaCodec) or browser fallback (WebCodecs)

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox
import Network
import AppKit

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

// MARK: - Config

struct Config {
    var panel: (Int, Int)? = nil             // default: the connected device's screen (landscape)
    var hiDPI = true                         // Retina: looks like panel/2
    var stream: (Int, Int)? = nil            // default: panel scaled to fit 1920 on the long side
    var maxStreamEdge = 1920
    var fps = 60
    var bitrate = 16_000_000
    var httpPort: UInt16 = 8800
    var wsPort: UInt16 = 8801
    var serial: String? = nil
}

// MARK: - Virtual display

final class VirtualDisplay {
    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    /// - serial: stable per device so macOS remembers the arrangement for each tablet.
    init(name: String, width: Int, height: Int, hiDPI: Bool, dpi: Int, serial: UInt32) {
        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = name
        d.maxPixelsWide = UInt32(width)
        d.maxPixelsHigh = UInt32(height)
        let inch = Double(max(dpi, 100))
        d.sizeInMillimeters = CGSize(width: Double(width) / inch * 25.4, height: Double(height) / inch * 25.4)
        d.vendorID = 0x7AB1                                       // "TABl"
        d.productID = 0x0001
        d.serialNum = serial
        d.terminationHandler = { _, _ in log("virtual display terminated") }
        display = CGVirtualDisplay(descriptor: d)

        let s = CGVirtualDisplaySettings()
        s.hiDPI = hiDPI ? 1 : 0
        if hiDPI {
            // HiDPI: modes are in points; backing store is 2x.
            s.modes = [
                CGVirtualDisplayMode(width: UInt32(width / 2), height: UInt32(height / 2), refreshRate: 60),
                CGVirtualDisplayMode(width: UInt32(width * 2 / 3), height: UInt32(height * 2 / 3), refreshRate: 60),
            ]
        } else {
            s.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
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
        guard st == noErr, let s = session else { log("VTCompressionSessionCreate failed \(st)"); return }
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

    deinit { if let s = session { VTCompressionSessionInvalidate(s) } }

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

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var target: SCDisplay?
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw NSError(domain: "tabdisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not found in SCShareableContent"]) }
        log("capturing display \(displayID) (\(target.width)x\(target.height) pt) -> \(width)x\(height) @\(fps)fps")

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
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
    var onInput: ((Data) -> Void)?
    var hello: (() -> String)?

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
                let hello = self.hello?() ?? "{}"
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
            if let data, data.count > 0 {
                if data.first! >= 10 { self.onInput?(data) }               // touch input (binary)
                else if String(data: data, encoding: .utf8) == "key" {
                    cl.needKey = true
                    self.onKeyRequest?()
                }
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

// MARK: - Touch input from the tablet -> Mac mouse events
//
//  [10][f32 x][f32 y]  down     (x,y normalized to the virtual display)
//  [11][f32 x][f32 y]  move/drag
//  [12][f32 x][f32 y]  up
//  [13][f32 dx][f32 dy] scroll   (normalized deltas, finger direction)
//  [14][f32 x][f32 y]  right click

final class TouchInput {
    private let displayID: CGDirectDisplayID
    private var down = false
    private var lastUp = Date.distantPast
    private var lastUpPt = CGPoint.zero
    private var clickState: Int64 = 1
    private var warned = false

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    private func f32(_ d: Data, _ o: Int) -> CGFloat {
        CGFloat(Float(bitPattern: d.subdata(in: o..<o+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian))
    }

    private func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !warned { warned = true; log("터치 입력: 손쉬운 사용 권한이 없어 무시합니다") }
        return false
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }

    func handle(_ d: Data) {
        guard d.count >= 9, trusted() else { return }
        let b = CGDisplayBounds(displayID)
        guard b.width > 0 else { return }
        let a = f32(d, 1), c = f32(d, 5)
        let p = CGPoint(x: b.minX + min(max(a, 0), 1) * (b.width - 1), y: b.minY + min(max(c, 0), 1) * (b.height - 1))
        switch d[0] {
        case 10:
            // double-click detection (needed for e.g. YouTube fullscreen)
            if Date().timeIntervalSince(lastUp) < 0.4 && hypot(p.x - lastUpPt.x, p.y - lastUpPt.y) < 12 { clickState += 1 } else { clickState = 1 }
            down = true
            post(.leftMouseDown, p, clicks: clickState)
        case 11:
            post(down ? .leftMouseDragged : .mouseMoved, p, clicks: clickState)
        case 12:
            if down { post(.leftMouseUp, p, clicks: clickState) }
            down = false
            lastUp = Date(); lastUpPt = p
        case 13:
            let dx = Int32((a * b.width).rounded()), dy = Int32((c * b.height).rounded())
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }
        case 14:
            post(.rightMouseDown, p, button: .right)
            post(.rightMouseUp, p, button: .right)
        default: break
        }
    }
}
