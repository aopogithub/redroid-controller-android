package com.redroidcontroller.redroid_controller

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val ADB_CHANNEL = "com.redroidcontroller/adb"
    private val H264_CHANNEL = "com.redroidcontroller/h264"
    var lastNativeError: String = ""
    var lastNativeLog: String = ""
    private val logBuffer = StringBuilder()

    private fun h264Log(msg: String) {
        Log.i("H264", msg)
        logBuffer.appendLine("${System.currentTimeMillis() % 100000} $msg")
        if (logBuffer.length > 5000) logBuffer.delete(0, logBuffer.length - 5000)
    }
    private fun h264Err(msg: String) {
        Log.e("H264", msg)
        logBuffer.appendLine("${System.currentTimeMillis() % 100000} ERR: $msg")
        if (logBuffer.length > 5000) logBuffer.delete(0, logBuffer.length - 5000)
    }

    private var codec: android.media.MediaCodec? = null
    private var surfaceTexture: android.graphics.SurfaceTexture? = null
    private var surface: android.view.Surface? = null
    private var textureEntry: io.flutter.view.TextureRegistry.SurfaceTextureEntry? = null
    private var abstractSocket: android.net.LocalSocket? = null
    private var abstractInput: java.io.InputStream? = null

    companion object {
        init {
            try { System.loadLibrary("adbpush") } catch (_: Throwable) {}
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ADB_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pushFile" -> {
                    val host = call.argument<String>("host") ?: ""
                    val port = call.argument<Int>("port") ?: 5555
                    val localPath = call.argument<String>("localPath") ?: ""
                    val remotePath = call.argument<String>("remotePath") ?: ""
                    lastNativeError = ""; lastNativeLog = ""
                    Thread {
                        try {
                            val ret = nativePush(host, port.toString(), localPath, remotePath)
                            if (ret == 0) result.success(mapOf("ok" to true, "log" to lastNativeLog))
                            else result.error("PUSH_FAILED", lastNativeError.ifEmpty { "ret=$ret" }, lastNativeLog)
                        } catch (e: Throwable) { result.error("PUSH_FAILED", e.message, lastNativeLog) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, H264_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    try {
                        val width = call.argument<Int>("width") ?: 720
                        val height = call.argument<Int>("height") ?: 1280
                        result.success(initDecoder(width, height, flutterEngine))
                    } catch (e: Throwable) { result.error("INIT_FAILED", e.message, null) }
                }
                "decode" -> {
                    try {
                        val data = call.argument<ByteArray>("data")
                        val w = call.argument<Int>("width") ?: 720
                        val h = call.argument<Int>("height") ?: 1280
                        if (data != null) {
                            val rendered = feedDecoder(data, w, h)
                            result.success(mapOf(
                                "rendered" to rendered,
                                "codec" to (codec != null),
                                "fc" to frameCount,
                                "decW" to w,
                                "decH" to h
                            ))
                        } else {
                            result.success(mapOf("rendered" to 0, "codec" to false, "csdSet" to false, "fc" to 0))
                        }
                    } catch (e: Throwable) { result.error("DECODE_FAILED", e.message, null) }
                }
                "updateSize" -> {
                    try {
                        val w = call.argument<Int>("width") ?: 720
                        val h = call.argument<Int>("height") ?: 1280
                        surfaceTexture?.setDefaultBufferSize(w, h)
                        h264Log("SurfaceTexture size updated to ${w}x${h}")
                        result.success(true)
                    } catch (e: Throwable) { result.error("UPDATE_FAILED", e.message, null) }
                }
                "getLog" -> { result.success(logBuffer.toString()) }
                "release" -> { releaseDecoder(); result.success(null) }
                "connectAbstract" -> {
                    val socketName = call.argument<String>("socketName") ?: "scrcpy"
                    Thread {
                        try {
                            val s = android.net.LocalSocket()
                            s.connect(android.net.LocalSocketAddress(socketName, android.net.LocalSocketAddress.Namespace.ABSTRACT))
                            abstractSocket = s; abstractInput = s.inputStream
                            result.success(true)
                        } catch (e: Throwable) { result.error("CONNECT_FAILED", e.message, null) }
                    }.start()
                }
                "readAbstract" -> {
                    val input = abstractInput
                    if (input == null) { result.error("NOT_CONNECTED", null, null); return@setMethodCallHandler }
                    try {
                        val buf = ByteArray(call.argument<Int>("maxLen") ?: 65536)
                        val n = input.read(buf)
                        result.success(if (n > 0) java.util.Arrays.copyOf(buf, n) else null)
                    } catch (e: Throwable) { result.error("READ_FAILED", e.message, null) }
                }
                "closeAbstract" -> {
                    try { abstractInput?.close(); abstractSocket?.close() } catch (_: Throwable) {}
                    abstractInput = null; abstractSocket = null; result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun initDecoder(width: Int, height: Int, engine: FlutterEngine): Int {
        textureEntry = engine.renderer.createSurfaceTexture()
        surfaceTexture = textureEntry!!.surfaceTexture()
        surfaceTexture!!.setDefaultBufferSize(width, height)
        surface = android.view.Surface(surfaceTexture!!)
        h264Log("Surface ready: ${width}x${height}, id=${textureEntry!!.id()}")
        return textureEntry!!.id().toInt()
    }

    private var frameCount = 0
    private var renderedTotal = 0
    private var csdSet = false

    // Find NAL units in H.264 bitstream and extract SPS/PPS for codec init
    private fun extractSpsPps(data: ByteArray): Pair<ByteArray?, ByteArray?> {
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        var i = 0
        while (i < data.size - 4) {
            // Find start code: 0x00000001 or 0x000001
            val startCodeLen: Int
            if (data[i] == 0.toByte() && data[i+1] == 0.toByte()) {
                if (i + 3 < data.size && data[i+2] == 0.toByte() && data[i+3] == 1.toByte()) {
                    startCodeLen = 4
                } else if (data[i+2] == 1.toByte()) {
                    startCodeLen = 3
                } else { i++; continue }
            } else { i++; continue }

            val nalType = data[i + startCodeLen].toInt() and 0x1F
            // Find next start code to get NAL end
            var j = i + startCodeLen + 1
            while (j < data.size - 3) {
                if (data[j] == 0.toByte() && data[j+1] == 0.toByte()) {
                    if ((j+3 < data.size && data[j+2] == 0.toByte() && data[j+3] == 1.toByte()) ||
                        data[j+2] == 1.toByte()) break
                }
                j++
            }
            if (j >= data.size - 3) j = data.size

            val nal = data.copyOfRange(i, j)
            when (nalType) {
                7 -> { sps = nal; h264Log("Found SPS: ${nal.size}B") }
                8 -> { pps = nal; h264Log("Found PPS: ${nal.size}B") }
            }
            if (sps != null && pps != null) break
            i = j
        }
        return Pair(sps, pps)
    }

    // Parse SPS to get video resolution
    private fun parseSpsResolution(sps: ByteArray): Pair<Int, Int>? {
        try {
            // Skip NAL header (1 byte) and start code if present
            var i = 0
            if (sps.size > 3 && sps[0] == 0.toByte() && sps[1] == 0.toByte() && sps[2] == 0.toByte() && sps[3] == 1.toByte()) i = 4
            else if (sps.size > 2 && sps[0] == 0.toByte() && sps[1] == 0.toByte() && sps[2] == 1.toByte()) i = 3
            if (i >= sps.size) return null

            // Skip NAL type byte
            i++
            if (i >= sps.size) return null

            // Exp-Golomb decoder
            var pos = i * 8 // bit position
            val data = sps

            fun readUe(): Int {
                var zeros = 0
                while (pos < data.size * 8) {
                    if ((data[pos / 8].toInt() and (0x80 shr (pos % 8))) != 0) break
                    zeros++
                    pos++
                }
                pos++
                var value = (1 shl zeros) - 1
                for (j in 0 until zeros) {
                    value = (value shl 1) or if (pos < data.size * 8 && (data[pos / 8].toInt() and (0x80 shr (pos % 8))) != 0) 1 else 0
                    pos++
                }
                return value
            }

            val profileIdc = data[i].toInt() and 0xFF
            // Skip: profile(8) + constraint_set(8) + level(8) + seq_parameter_set_id(ue)
            pos = (i + 3) * 8
            readUe() // seq_parameter_set_id

            // High profile has extra fields
            if (profileIdc == 100 || profileIdc == 110 || profileIdc == 122 ||
                profileIdc == 244 || profileIdc == 44 || profileIdc == 83 ||
                profileIdc == 86 || profileIdc == 118 || profileIdc == 128) {
                val chromaFormatIdc = readUe()
                if (chromaFormatIdc == 3) pos++ // separate_colour_plane_flag
                readUe() // bit_depth_luma_minus8
                readUe() // bit_depth_chroma_minus8
                pos++ // qpprime_y_zero_transform_bypass_flag
                val seqScalingMatrixPresent = (data[pos / 8].toInt() and (0x80 shr (pos % 8))) != 0
                pos++
                if (seqScalingMatrixPresent) {
                    val cnt = if (chromaFormatIdc != 3) 8 else 12
                    for (j in 0 until cnt) {
                        val seqScalingListPresent = (data[pos / 8].toInt() and (0x80 shr (pos % 8))) != 0
                        pos++
                        if (seqScalingListPresent) {
                            // Skip scaling list
                            var lastScale = 8
                            var nextScale = 8
                            val size = if (j < 6) 16 else 64
                            for (k in 0 until size) {
                                if (nextScale != 0) {
                                    val delta = readUe()
                                    nextScale = (lastScale + delta + 256) % 256
                                }
                                lastScale = if (nextScale == 0) lastScale else nextScale
                            }
                        }
                    }
                }
            }

            readUe() // log2_max_frame_num_minus4
            val picOrderCntType = readUe()
            if (picOrderCntType == 0) {
                readUe() // log2_max_pic_order_cnt_lsb_minus4
            } else if (picOrderCntType == 1) {
                pos++ // delta_pic_order_always_zero_flag
                readUe() // offset_for_non_ref_pic
                readUe() // offset_for_top_to_bottom_field
                val numRefFrames = readUe()
                for (j in 0 until numRefFrames) readUe()
            }
            readUe() // max_num_ref_frames
            pos++ // gaps_in_frame_num_value_allowed_flag

            val picWidthInMbs = readUe() + 1
            val picHeightInMapUnits = readUe() + 1
            val frameMbsOnly = (data[pos / 8].toInt() and (0x80 shr (pos % 8))) != 0
            pos++

            val width = picWidthInMbs * 16
            val height = if (frameMbsOnly) picHeightInMapUnits * 16 else picHeightInMapUnits * 32

            h264Log("SPS resolution: ${width}x$height (mbs=$picWidthInMbs x $picHeightInMapUnits frameMbsOnly=$frameMbsOnly)")
            return Pair(width, height)
        } catch (e: Throwable) {
            h264Err("SPS parse error: ${e.message}")
            return null
        }
    }

    private fun feedDecoder(data: ByteArray, width: Int = 720, height: Int = 1280): Int {
        // Lazy-init codec on first frame
        if (codec == null) {
            try {
                surfaceTexture?.setDefaultBufferSize(width, height)
                codec = android.media.MediaCodec.createDecoderByType("video/avc")
                val fmt = android.media.MediaFormat.createVideoFormat("video/avc", width, height)
                fmt.setInteger(android.media.MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024)
                codec!!.configure(fmt, surface, null, 0)
                codec!!.start()
                h264Log("Decoder ${width}x${height}")
            } catch (e: Throwable) {
                h264Err("Init: ${e.javaClass.simpleName}: ${e.message}")
                try {
                    codec?.release()
                    codec = android.media.MediaCodec.createDecoderByType("video/avc")
                    val fmt = android.media.MediaFormat.createVideoFormat("video/avc", width, height)
                    fmt.setInteger(android.media.MediaFormat.KEY_MAX_INPUT_SIZE, 256 * 1024) // 256KB for lower latency
                    if (android.os.Build.VERSION.SDK_INT >= 30) {
                        fmt.setInteger(android.media.MediaFormat.KEY_LOW_LATENCY, 1)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= 29) {
                        fmt.setInteger("priority", 0) // 0=realtime, 1=non-realtime
                    }
                    codec!!.configure(fmt, null, null, 0)
                    codec!!.start()
                    h264Log("Decoder ${width}x${height} (no surface)")
                } catch (e2: Throwable) {
                    h264Err("Init2: ${e2.javaClass.simpleName}: ${e2.message}")
                    codec = null
                    return 0
                }
            }
        }
        val c = codec ?: return 0
        try {
            // Feed input — don't wait, just try
            val idx = c.dequeueInputBuffer(0)
            if (idx >= 0) {
                val buf = c.getInputBuffer(idx)
                buf?.clear(); buf?.put(data)
                c.queueInputBuffer(idx, 0, data.size, 0, 0)
            }
            // Drain output — don't wait, just drain what's available
            var rendered = 0
            val info = android.media.MediaCodec.BufferInfo()
            var out = c.dequeueOutputBuffer(info, 0)
            while (out >= 0) {
                c.releaseOutputBuffer(out, true)
                rendered++
                out = c.dequeueOutputBuffer(info, 0)
            }
            renderedTotal += rendered
            frameCount++
            if (frameCount <= 10 || rendered > 0 || frameCount % 100 == 0) {
                val first4 = if (data.size >= 4) String.format("%02x %02x %02x %02x", data[0].toInt() and 0xFF, data[1].toInt() and 0xFF, data[2].toInt() and 0xFF, data[3].toInt() and 0xFF) else "??"
                h264Log("F#$frameCount: in=${data.size} rnd=$rendered first4=$first4 csd=$csdSet tot=$renderedTotal")
            }
            return rendered
        } catch (e: Throwable) {
            h264Err("feed: ${e.message}")
            return 0
        }
    }

    private fun releaseDecoder() {
        try { codec?.stop(); codec?.release() } catch (_: Throwable) {}
        codec = null
        try { surface?.release() } catch (_: Throwable) {}
        surface = null
        try { textureEntry?.release() } catch (_: Throwable) {}
        textureEntry = null; surfaceTexture = null
    }

    external fun nativePush(host: String, port: String, localPath: String, remotePath: String): Int
}
