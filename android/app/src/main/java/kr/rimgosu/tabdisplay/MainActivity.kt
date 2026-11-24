package kr.rimgosu.tabdisplay

import android.app.Activity
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
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
import org.json.JSONObject
import java.nio.ByteBuffer
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

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
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
        setContentView(root)
        hideSystemUi()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
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
        restartDecoder()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopDecoder()
        surface = null
    }

    private fun restartDecoder() {
        stopDecoder()
        val s = surface ?: return
        frames.clear()
        requestKey()
        decoder = thread(name = "decoder") { decodeLoop(s) }
    }

    private fun stopDecoder() {
        decoder?.let { it.interrupt(); it.join(1000) }
        decoder = null
    }

    private fun decodeLoop(s: Surface) {
        var codec: MediaCodec? = null
        val info = MediaCodec.BufferInfo()
        var pts = 0L
        var failed = false
        try {
            while (!Thread.currentThread().isInterrupted) {
                val f = frames.poll(20, TimeUnit.MILLISECONDS)
                if (f != null) {
                    if (codec == null) {
                        if (!f.key) continue
                        val (sps, pps) = parameterSets(f.data) ?: continue
                        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, videoW, videoH).apply {
                            setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                            setByteBuffer("csd-1", ByteBuffer.wrap(pps))
                            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                            setInteger(MediaFormat.KEY_PRIORITY, 0)
                        }
                        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                            it.configure(fmt, s, null, 0)
                            it.start()
                        }
                        Log.i(tag, "decoder started ${videoW}x$videoH")
                    }
                    val idx = codec.dequeueInputBuffer(10_000)
                    if (idx >= 0) {
                        val buf = codec.getInputBuffer(idx)!!
                        buf.clear()
                        buf.put(f.data, 1, f.data.size - 1)
                        codec.queueInputBuffer(idx, 0, f.data.size - 1, pts,
                            if (f.key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                        pts += 16_667
                    } else {
                        requestKey()                 // no input buffer: skipped a frame, need a clean restart point
                    }
                }
                if (codec != null) {
                    while (true) {
                        val o = codec.dequeueOutputBuffer(info, 0)
                        if (o >= 0) {
                            codec.releaseOutputBuffer(o, true)
                            if (status.visibility == View.VISIBLE) setStatus(null)
                        } else if (o != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED &&
                                   o != MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) break
                    }
                }
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.e(tag, "decoder error", e)
            setStatus("디코더 오류: ${e.message}")
            failed = true
        } finally {
            runCatching { codec?.stop() }
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
