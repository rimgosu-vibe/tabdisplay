package kr.rimgosu.tabdisplay

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.RectF
import android.os.HandlerThread
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Receives the H.264 stream from the Mac-side TabDisplay over `adb reverse tcp:8801`
 * (WebSocket, each binary message = [1 byte keyframe flag] + Annex-B access unit)
 * and renders it full screen with MediaCodec.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {

    private class Frame(val data: ByteArray, val key: Boolean)

    private val tag = "TabDisplay"
    private val wsUrl = "ws://127.0.0.1:8801"
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(5, TimeUnit.SECONDS)
        .build()

    private lateinit var status: TextView
    private lateinit var root: FrameLayout
    // Cursor is drawn on its own translucent surface stacked above the video surface.
    // (A normal View moved over a SurfaceView via translation isn't recomposited reliably.)
    private lateinit var cursorView: SurfaceView
    private val cursorThread = HandlerThread("cursor").apply { start() }
    private val cursorHandler = Handler(cursorThread.looper)
    private val cursorPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    @Volatile private var cursorReady = false
    @Volatile private var cursorDirty = false
    @Volatile private var cursorBmp: Bitmap? = null
    @Volatile private var curX = -1f
    @Volatile private var curY = -1f
    @Volatile private var curW = 0f
    @Volatile private var curH = 0f
    @Volatile private var hotX = 0f
    @Volatile private var hotY = 0f
    private val frames = LinkedBlockingQueue<Frame>()

    @Volatile private var ws: WebSocket? = null
    @Volatile private var surface: Surface? = null
    @Volatile private var running = false
    @Volatile private var needKey = true
    @Volatile private var videoW = 1920
    @Volatile private var videoH = 1200
    private var decoder: Thread? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 28) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val sv = SurfaceView(this)
        sv.holder.addCallback(this)
        root.addView(sv, FrameLayout.LayoutParams(-1, -1))
        status = TextView(this).apply {
            setTextColor(0xFFAAAAAA.toInt())
            textSize = 16f
            setPadding(32, 20, 32, 20)
            setBackgroundColor(0x88000000.toInt())
        }
        root.addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.START or Gravity.BOTTOM).apply {
            setMargins(40, 40, 40, 40)
        })
        cursorView = SurfaceView(this).apply {
            setZOrderMediaOverlay(true)
            holder.setFormat(PixelFormat.TRANSLUCENT)
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) { cursorReady = true; scheduleCursor() }
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) = scheduleCursor()
                override fun surfaceDestroyed(h: SurfaceHolder) {
                    cursorReady = false
                    val l = java.util.concurrent.CountDownLatch(1)          // wait for an in-flight draw to finish
                    cursorHandler.post { l.countDown() }
                    l.await(500, TimeUnit.MILLISECONDS)
                }
            })
        }
        root.addView(cursorView, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        hideSystemUi()
        preferHighRefreshRate()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    /** Pick the highest refresh-rate mode at the current resolution (120/144Hz) to cut vsync wait. */
    @Suppress("DEPRECATION")
    private fun preferHighRefreshRate() {
        val d = windowManager.defaultDisplay ?: return
        val cur = d.mode
        val best = d.supportedModes
            .filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = best.modeId
            preferredRefreshRate = best.refreshRate
        }
        Log.i(tag, "display mode ${best.refreshRate}Hz")
    }

    // ---- cursor overlay (types 2/3) ----

    private fun onCursor(b: ByteArray) {
        val bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
        if (b[0].toInt() == 2 && b.size >= 9) {
            curX = bb.getFloat(1); curY = bb.getFloat(5)
        } else if (b[0].toInt() == 3 && b.size > 17) {
            val bmp = BitmapFactory.decodeByteArray(b, 17, b.size - 17) ?: return
            hotX = bb.getFloat(1); hotY = bb.getFloat(5); curW = bb.getFloat(9); curH = bb.getFloat(13)
            cursorBmp = bmp
        } else return
        scheduleCursor()
    }

    /** Coalesces cursor updates; each draw blocks until the next vsync buffer is free. */
    private fun scheduleCursor() {
        if (cursorDirty) return
        cursorDirty = true
        cursorHandler.post { cursorDirty = false; drawCursor() }
    }

    private fun drawCursor() {
        if (!cursorReady) return
        val holder = cursorView.holder
        val c = try {
            if (Build.VERSION.SDK_INT >= 26) holder.lockHardwareCanvas() else holder.lockCanvas()
        } catch (e: Exception) { null } ?: return
        try {
            c.drawColor(0, PorterDuff.Mode.CLEAR)
            val bmp = cursorBmp
            if (bmp != null && curX >= 0f && curW > 0f) {
                // video fills the view (same 16:10 aspect), so normalized coords map directly
                val vw = c.width.toFloat(); val vh = c.height.toFloat()
                val w = curW * vw; val h = curH * vh
                val l = curX * vw - hotX * w; val t = curY * vh - hotY * h
                c.drawBitmap(bmp, null, RectF(l, t, l + w, t + h), cursorPaint)
            }
        } finally {
            holder.unlockCanvasAndPost(c)
        }
    }

    // ---- touch -> Mac mouse (types 10..14, see mac/Sources/main.swift TouchInput) ----
    //  tap = click (double tap = double click), 1-finger drag = mouse drag,
    //  2-finger drag = scroll, long press = right click

    private enum class TMode { IDLE, PENDING, DRAG, SCROLL, DONE }
    private var tMode = TMode.IDLE
    private var downX = 0f
    private var downY = 0f
    private var lastFx = 0f
    private var lastFy = 0f
    private val touchSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop.toFloat() }
    private val longPress = Runnable {
        if (tMode == TMode.PENDING) { tMode = TMode.DONE; sendTouch(14, downX, downY) }
    }

    private fun sendTouch(type: Int, x: Float, y: Float, normalized: Boolean = false) {
        val w = root.width.toFloat(); val h = root.height.toFloat()
        if (w <= 0f || h <= 0f) return
        val bb = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(type.toByte())
        bb.putFloat(if (normalized) x else x / w)
        bb.putFloat(if (normalized) y else y / h)
        ws?.send(bb.array().toByteString())
    }

    private fun focus(e: MotionEvent): Pair<Float, Float> {
        var sx = 0f; var sy = 0f
        val skip = if (e.actionMasked == MotionEvent.ACTION_POINTER_UP) e.actionIndex else -1
        var n = 0
        for (i in 0 until e.pointerCount) if (i != skip) { sx += e.getX(i); sy += e.getY(i); n++ }
        return if (n == 0) e.x to e.y else (sx / n) to (sy / n)
    }

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                tMode = TMode.PENDING
                downX = e.x; downY = e.y
                sendTouch(11, downX, downY)               // move the pointer there (hover)
                main.postDelayed(longPress, 600)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (tMode == TMode.PENDING) {
                    main.removeCallbacks(longPress)
                    tMode = TMode.SCROLL
                }
                if (tMode == TMode.SCROLL) { val (fx, fy) = focus(e); lastFx = fx; lastFy = fy }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (tMode == TMode.SCROLL) { val (fx, fy) = focus(e); lastFx = fx; lastFy = fy }
            }
            MotionEvent.ACTION_MOVE -> when (tMode) {
                TMode.PENDING -> if (Math.hypot((e.x - downX).toDouble(), (e.y - downY).toDouble()) > touchSlop) {
                    main.removeCallbacks(longPress)
                    tMode = TMode.DRAG
                    sendTouch(10, downX, downY)
                    sendTouch(11, e.x, e.y)
                }
                TMode.DRAG -> sendTouch(11, e.x, e.y)
                TMode.SCROLL -> {
                    val (fx, fy) = focus(e)
                    val w = root.width.toFloat(); val h = root.height.toFloat()
                    if (w > 0f && h > 0f) sendTouch(13, (fx - lastFx) / w, (fy - lastFy) / h, normalized = true)
                    lastFx = fx; lastFy = fy
                }
                else -> {}
            }
            MotionEvent.ACTION_UP -> {
                main.removeCallbacks(longPress)
                when (tMode) {
                    TMode.PENDING -> { sendTouch(10, downX, downY); sendTouch(12, downX, downY) }
                    TMode.DRAG -> sendTouch(12, e.x, e.y)
                    else -> {}
                }
                tMode = TMode.IDLE
            }
            MotionEvent.ACTION_CANCEL -> {
                main.removeCallbacks(longPress)
                if (tMode == TMode.DRAG) sendTouch(12, e.x, e.y)
                tMode = TMode.IDLE
            }
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
        }
    }

    override fun onResume() {
        super.onResume()
        running = true
        connect()
    }

    override fun onPause() {
        super.onPause()
        running = false
        ws?.close(1000, null)
        ws = null
    }

    // ---- status overlay ----

    private fun setStatus(text: String?) = main.post {
        if (text == null) status.visibility = View.GONE
        else { status.text = text; status.visibility = View.VISIBLE }
    }

    // ---- WebSocket ----

    private fun connect() {
        if (!running || ws != null) return
        setStatus("Mac 연결 대기 중…\nUSB 연결과 Mac의 TabDisplay 실행을 확인하세요")
        ws = http.newWebSocket(Request.Builder().url(wsUrl).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                frames.clear()
                needKey = true
                setStatus("화면 대기 중…")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                runCatching {
                    val j = JSONObject(text)
                    val w = j.optInt("w", videoW)
                    val h = j.optInt("h", videoH)
                    if (w != videoW || h != videoH) {
                        videoW = w; videoH = h
                        main.post { restartDecoder() }
                    }
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val b = bytes.toByteArray()
                if (b.size < 2) return
                if (b[0].toInt() >= 2) { onCursor(b); return }
                val key = b[0].toInt() == 1
                if (needKey && !key) return
                if (frames.size > 6) {           // decoder fell behind: drop and resync on next keyframe
                    frames.clear()
                    requestKey()
                    return
                }
                needKey = false
                frames.offer(Frame(b, key))
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = retry(webSocket)
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = retry(webSocket)
        })
    }

    private fun retry(socket: WebSocket) {
        main.post {
            if (ws === socket) ws = null
            if (running) main.postDelayed({ connect() }, 1000)
        }
    }

    private fun requestKey() {
        needKey = true
        ws?.send("key")
    }

    // ---- decoder ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        surface = holder.surface
        if (Build.VERSION.SDK_INT >= 30) runCatching {
            holder.surface.setFrameRate(120f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        }
        restartDecoder()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopDecoder()
        surface = null
    }

    private var outThread: Thread? = null

    private fun restartDecoder() {
        stopDecoder()
        val s = surface ?: return
        frames.clear()
        requestKey()
        decoder = thread(name = "decoder-in") { decodeLoop(s) }
    }

    private fun stopDecoder() {
        decoder?.let { it.interrupt(); it.join(1000) }
        decoder = null
    }

    /** Output side runs on its own thread so each frame is rendered the moment it is decoded. */
    private fun outputLoop(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (!Thread.currentThread().isInterrupted) {
                val o = codec.dequeueOutputBuffer(info, 5_000)
                if (o >= 0) {
                    codec.releaseOutputBuffer(o, true)
                    if (status.visibility == View.VISIBLE) setStatus(null)
                }
            }
        } catch (_: IllegalStateException) {   // codec stopped
        }
    }

    private fun decodeLoop(s: Surface) {
        var codec: MediaCodec? = null
        var pts = 0L
        var failed = false
        try {
            while (!Thread.currentThread().isInterrupted) {
                val f = frames.take()
                if (codec == null) {
                    if (!f.key) continue
                    val (sps, pps) = parameterSets(f.data) ?: continue
                    val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, videoW, videoH).apply {
                        setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                        setByteBuffer("csd-1", ByteBuffer.wrap(pps))
                        if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                        setInteger(MediaFormat.KEY_PRIORITY, 0)
                        setInteger("vdec-lowlatency", 1)          // MediaTek vendor hint (ignored elsewhere)
                    }
                    val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                    c.configure(fmt, s, null, 0)
                    c.start()
                    codec = c
                    outThread = thread(name = "decoder-out") { outputLoop(c) }
                    Log.i(tag, "decoder ${c.name} started ${videoW}x$videoH")
                }
                val idx = codec.dequeueInputBuffer(20_000)
                if (idx >= 0) {
                    val buf = codec.getInputBuffer(idx)!!
                    buf.clear()
                    buf.put(f.data, 1, f.data.size - 1)
                    codec.queueInputBuffer(idx, 0, f.data.size - 1, pts,
                        if (f.key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    pts += 16_667
                } else {
                    requestKey()
                }
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.e(tag, "decoder error", e)
            setStatus("디코더 오류: ${e.message}")
            failed = true
        } finally {
            outThread?.let { it.interrupt() }
            runCatching { codec?.stop() }
            outThread?.let { runCatching { it.join(500) } }
            outThread = null
            runCatching { codec?.release() }
        }
        if (failed) main.postDelayed({ if (surface === s) restartDecoder() }, 500)
    }

    /** Extracts SPS (type 7) and PPS (type 8) NAL units, each with a 4-byte start code. */
    private fun parameterSets(d: ByteArray): Pair<ByteArray, ByteArray>? {
        val starts = ArrayList<Int>()          // index of first byte after a start code
        var i = 1
        while (i + 3 < d.size) {
            if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 && d[i + 2].toInt() == 1) {
                starts.add(i + 3); i += 3
            } else i++
        }
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        for ((n, st) in starts.withIndex()) {
            var end = if (n + 1 < starts.size) starts[n + 1] - 3 else d.size
            if (end > st && d[end - 1].toInt() == 0) end--   // 4-byte start code of next NAL
            val type = d[st].toInt() and 0x1f
            val nal = byteArrayOf(0, 0, 0, 1) + d.copyOfRange(st, end)
            if (type == 7) sps = nal else if (type == 8) pps = nal
        }
        return if (sps != null && pps != null) sps to pps else null
    }
}
