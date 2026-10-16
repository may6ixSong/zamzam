package io.github.may6ixsong.zamzam

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 재인코딩 없는 자르기·합치기.
 *
 * MediaExtractor 로 원본의 압축된 영상/음성 샘플을 읽어 MediaMuxer 로 새 MP4 에 그대로 쓴다.
 * 디코딩·인코딩을 하지 않으므로 화질이 그대로이고 용량은 구간 길이에 비례한다.
 */
class MediaEngine(
    private val ctx: Context,
    private val channel: MethodChannel,
    private val picker: (multiple: Boolean, result: MethodChannel.Result) -> Unit,
) : MethodChannel.MethodCallHandler {

    private val exportExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val probeExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        channel.setMethodCallHandler(null)
        cancelled.set(true)
        exportExecutor.shutdownNow()
        probeExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickVideos" -> picker(call.argument<Boolean>("multiple") == true, result)
            "probe" -> background(probeExecutor, result) { probe(call.uri("uri")) }
            "thumbnails" -> background(probeExecutor, result) {
                thumbnails(call.uri("uri"), call.long("count").toInt(), call.long("height").toInt())
            }
            "trim" -> {
                cancelled.set(false)
                background(exportExecutor, result) {
                    trim(call.uri("uri"), call.long("startUs"), call.long("endUs"))
                }
            }
            "merge" -> {
                cancelled.set(false)
                val uris = call.argument<List<String>>("uris")!!.map(Uri::parse)
                background(exportExecutor, result) { merge(uris) }
            }
            "cancel" -> {
                cancelled.set(true)
                result.success(null)
            }
            "open" -> {
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(call.uri("uri"), "video/mp4")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    ctx.startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("FAILED", "열 수 있는 앱이 없어요", null)
                }
            }
            "saveLocation" -> result.success("${Environment.DIRECTORY_MOVIES}/$FOLDER")
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ probe

    private class Tracks(val video: Int, val audio: Int, val videoFormat: MediaFormat, val audioFormat: MediaFormat?)

    private fun tracksOf(ex: MediaExtractor): Tracks {
        var v = -1
        var a = -1
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (v < 0 && mime.startsWith("video/")) v = i
            if (a < 0 && mime.startsWith("audio/")) a = i
        }
        if (v < 0) throw IOException("영상 트랙이 없는 파일이에요")
        return Tracks(v, a, ex.getTrackFormat(v), if (a >= 0) ex.getTrackFormat(a) else null)
    }

    private fun probe(uri: Uri): Map<String, Any?> {
        val ex = openExtractor(uri)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(ctx, uri)
            val t = tracksOf(ex)
            val vf = t.videoFormat

            // 영상 샘플을 훑어 키프레임 위치와 프레임 수를 센다(데이터는 읽지 않는다).
            ex.selectTrack(t.video)
            val keyframes = ArrayList<Long>()
            var frames = 0
            var minPts = Long.MAX_VALUE
            var maxPts = Long.MIN_VALUE
            while (true) {
                val pts = ex.sampleTime
                if (pts < 0) break
                if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) keyframes.add(pts)
                frames++
                if (pts < minPts) minPts = pts
                if (pts > maxPts) maxPts = pts
                if (!ex.advance()) break
            }
            keyframes.sort()

            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            val durationUs = durationMs?.times(1000)
                ?: if (vf.containsKey(MediaFormat.KEY_DURATION)) vf.getLong(MediaFormat.KEY_DURATION) else maxPts
            val span = if (frames > 1) maxPts - minPts else 0L
            val fps = when {
                span > 0 -> (frames - 1) * 1_000_000.0 / span
                vf.containsKey(MediaFormat.KEY_FRAME_RATE) -> vf.getNumber(MediaFormat.KEY_FRAME_RATE).toDouble()
                else -> 30.0
            }
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val (name, size) = nameAndSize(uri)
            val af = t.audioFormat
            return mapOf(
                "uri" to uri.toString(),
                "name" to name,
                "size" to size,
                "durationUs" to durationUs,
                "width" to vf.getInteger(MediaFormat.KEY_WIDTH),
                "height" to vf.getInteger(MediaFormat.KEY_HEIGHT),
                "rotation" to rotation,
                "videoMime" to vf.getString(MediaFormat.KEY_MIME),
                "videoSig" to csdSignature(vf),
                "fps" to fps,
                "audioMime" to af?.getString(MediaFormat.KEY_MIME),
                "sampleRate" to af?.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                "channels" to af?.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                "keyframesUs" to keyframes,
                "exactCut" to false,
            )
        } finally {
            ex.release()
            retriever.release()
        }
    }

    /** 코덱 설정 데이터(SPS/PPS 등)의 지문. 같아야 한 트랙으로 이어 붙여도 재생된다. */
    private fun csdSignature(f: MediaFormat): String? {
        val md = MessageDigest.getInstance("SHA-1")
        var any = false
        for (key in arrayOf("csd-0", "csd-1", "csd-2")) {
            if (!f.containsKey(key)) continue
            val buf = f.getByteBuffer(key)?.duplicate() ?: continue
            buf.rewind()
            val bytes = ByteArray(buf.remaining())
            buf.get(bytes)
            md.update(bytes)
            any = true
        }
        if (!any) return null
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun nameAndSize(uri: Uri): Pair<String, Long> {
        var name = "video.mp4"
        var size = -1L
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { c ->
                if (c.moveToFirst()) {
                    if (!c.isNull(0)) name = c.getString(0)
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        if (size < 0) {
            size = ctx.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
        }
        return name to size
    }

    private fun thumbnails(uri: Uri, count: Int, height: Int): List<ByteArray> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(ctx, uri)
            val durationUs = (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            val out = ArrayList<ByteArray>(count)
            for (i in 0 until count) {
                val t = (durationUs * (i + 0.5) / count).toLong()
                val bmp = r.getScaledFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, height * 3, height)
                    ?: continue
                val bytes = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 75, bytes)
                bmp.recycle()
                out.add(bytes.toByteArray())
            }
            return out
        } finally {
            r.release()
        }
    }

    // ------------------------------------------------------------------ export

    private fun trim(uri: Uri, startUs: Long, endUs: Long): Map<String, Any?> {
        val probeEx = openExtractor(uri)
        val tracks = try { tracksOf(probeEx) } finally { probeEx.release() }
        return export(listOf(Segment(uri, startUs, endUs)), tracks, sourceMeta(uri))
    }

    private fun merge(uris: List<Uri>): Map<String, Any?> {
        if (uris.size < 2) throw IOException("두 개 이상 골라주세요")
        val first = openExtractor(uris.first())
        val tracks = try { tracksOf(first) } finally { first.release() }
        return export(uris.map { Segment(it, 0L, Long.MAX_VALUE) }, tracks, sourceMeta(uris.first()))
    }

    private class Segment(val uri: Uri, val fromUs: Long, val toUs: Long)

    private class SourceMeta(val rotation: Int, val latitude: Float?, val longitude: Float?)

    private fun sourceMeta(uri: Uri): SourceMeta {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(ctx, uri)
            val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            // ISO-6709 예: "+37.5665+126.9780/"
            val loc = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)
            val m = loc?.let { Regex("""([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)""").find(it) }
            return SourceMeta(rotation, m?.groupValues?.get(1)?.toFloatOrNull(), m?.groupValues?.get(2)?.toFloatOrNull())
        } finally {
            r.release()
        }
    }

    /** 모든 구간에 공통인 진행 상태. */
    private class CopyState(val totalUs: Long) {
        var offsetUs = 0L
        var doneUs = 0L
        var lastAudioPts = -1L
        var videoSamples = 0
        var lastReported = -1
    }

    private fun export(segments: List<Segment>, tracks: Tracks, meta: SourceMeta): Map<String, Any?> {
        val total = segments.sumOf { seg ->
            if (seg.toUs != Long.MAX_VALUE) seg.toUs - seg.fromUs else durationOf(seg.uri)
        }.coerceAtLeast(1L)
        val out = createOutput()
        val muxer = try {
            MediaMuxer(out.pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (e: Throwable) {
            discard(out)
            throw e
        }
        var started = false
        var released = false
        try {
            muxer.setOrientationHint(meta.rotation)
            val lat = meta.latitude
            val lon = meta.longitude
            if (lat != null && lon != null) runCatching { muxer.setLocation(lat, lon) }
            val videoOut = muxer.addTrack(tracks.videoFormat)
            val audioFormat = tracks.audioFormat
            val audioOut = if (audioFormat != null) muxer.addTrack(audioFormat) else -1
            muxer.start()
            started = true

            val state = CopyState(total)
            for (seg in segments) copySegment(muxer, videoOut, audioOut, seg, state)
            if (state.videoSamples == 0) throw IOException("선택한 구간에 영상 프레임이 없어요")

            started = false
            muxer.stop()
            released = true
            muxer.release()
            val size = out.pfd.statSize
            out.pfd.close()
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            ctx.contentResolver.update(out.uri, done, null, null)
            report(state, 1.0)
            return mapOf(
                "uri" to out.uri.toString(),
                "name" to (displayName(out.uri) ?: out.name),
                "size" to size,
                "durationUs" to state.offsetUs,
            )
        } catch (e: Throwable) {
            if (started) runCatching { muxer.stop() }
            if (!released) runCatching { muxer.release() }
            discard(out)
            throw e
        }
    }

    private fun discard(out: Output) {
        runCatching { out.pfd.close() }
        runCatching { ctx.contentResolver.delete(out.uri, null, null) }
    }

    /**
     * 한 원본의 [Segment.fromUs, Segment.toUs) 구간을 복사한다.
     *
     * 시작은 [Segment.fromUs] 바로 앞 키프레임부터(그래야 디코딩이 가능하다), 끝은 [Segment.toUs] 직전 프레임까지.
     * 영상·음성 샘플을 원본 시간 순으로 번갈아 써서 재생기가 읽기 좋게 섞어 둔다.
     */
    private fun copySegment(muxer: MediaMuxer, videoOut: Int, audioOut: Int, seg: Segment, st: CopyState) {
        val vEx = openExtractor(seg.uri)
        var aEx: MediaExtractor? = null
        try {
            val t = tracksOf(vEx)
            vEx.selectTrack(t.video)
            vEx.seekTo(seg.fromUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val start = vEx.sampleTime
            if (start < 0) return
            // 합치기: 영상 트랙 길이까지만(음성이 조금 더 길어도 다음 영상과 겹치지 않게).
            val videoTrackEnd = if (t.videoFormat.containsKey(MediaFormat.KEY_DURATION)) {
                t.videoFormat.getLong(MediaFormat.KEY_DURATION)
            } else {
                Long.MAX_VALUE
            }
            val end = minOf(seg.toUs, videoTrackEnd)

            if (audioOut >= 0 && t.audio >= 0) {
                aEx = openExtractor(seg.uri).also {
                    it.selectTrack(t.audio)
                    it.seekTo(start, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                }
            }

            var buffer = ByteBuffer.allocateDirect(initialBufferSize(t))
            val info = MediaCodec.BufferInfo()
            var videoDone = false
            var audioDone = aEx == null
            var firstPts = Long.MAX_VALUE
            var lastPts = Long.MIN_VALUE
            var written = 0

            fun read(ex: MediaExtractor): Int {
                while (true) {
                    try {
                        return ex.readSampleData(buffer, 0)
                    } catch (e: IllegalArgumentException) {
                        // 버퍼가 작으면 키워서 다시 읽는다.
                        buffer = ByteBuffer.allocateDirect(buffer.capacity() * 2)
                    }
                }
            }

            while (!videoDone || !audioDone) {
                if (cancelled.get()) throw CancelledException()
                val vt = if (videoDone) Long.MAX_VALUE else vEx.sampleTime
                if (!videoDone && vt < 0) { videoDone = true; continue }
                val at = if (audioDone) Long.MAX_VALUE else aEx!!.sampleTime
                if (!audioDone && at < 0) { audioDone = true; continue }

                if (!videoDone && vt <= at) {
                    val sync = (vEx.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                    if (vt >= end) {
                        // 끝 이후 첫 키프레임(또는 충분히 지난 지점)에서 멈춘다.
                        // 그 사이 프레임은 순서가 섞인 B-프레임일 수 있어 더 읽어 본다.
                        if (sync || vt > end + 3_000_000L) { videoDone = true; continue }
                        vEx.advance()
                        continue
                    }
                    if (vt >= start) {
                        val size = read(vEx)
                        if (size > 0) {
                            info.set(0, size, vt - start + st.offsetUs, if (sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                            muxer.writeSampleData(videoOut, buffer, info)
                            st.videoSamples++
                            written++
                            if (vt < firstPts) firstPts = vt
                            if (vt > lastPts) lastPts = vt
                        }
                        report(st, (st.doneUs + (vt - start)).toDouble() / st.totalUs)
                    }
                    vEx.advance()
                } else {
                    val ex = aEx!!
                    if (at >= end) { audioDone = true; continue }
                    if (at >= start) {
                        val pts = at - start + st.offsetUs
                        if (pts > st.lastAudioPts) {
                            val size = read(ex)
                            if (size > 0) {
                                info.set(0, size, pts, 0)
                                muxer.writeSampleData(audioOut, buffer, info)
                                st.lastAudioPts = pts
                            }
                        }
                    }
                    ex.advance()
                }
            }

            if (written > 0) {
                val frame = if (written > 1) (lastPts - firstPts) / (written - 1) else 33_333L
                val length = if (seg.toUs != Long.MAX_VALUE) minOf(lastPts + frame, end) - start else lastPts + frame - start
                st.offsetUs += length
                st.doneUs += length
            }
        } finally {
            vEx.release()
            aEx?.release()
        }
    }

    private fun initialBufferSize(t: Tracks): Int {
        var size = 2 * 1024 * 1024
        for (f in listOfNotNull(t.videoFormat, t.audioFormat)) {
            if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) size = maxOf(size, f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
        }
        return size
    }

    private fun durationOf(uri: Uri): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(ctx, uri)
            (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 1L) * 1000
        } finally {
            r.release()
        }
    }

    private fun report(st: CopyState, fraction: Double) {
        val pct = (fraction.coerceIn(0.0, 1.0) * 100).toInt()
        if (pct == st.lastReported) return
        st.lastReported = pct
        main.post { channel.invokeMethod("progress", pct / 100.0) }
    }

    // ------------------------------------------------------------------ output

    private class Output(val uri: Uri, val pfd: ParcelFileDescriptor, val name: String)

    /** 갤러리(Movies/ZamZam)에 '작성 중' 상태로 새 파일을 만든다. 완료 전에는 갤러리에 보이지 않는다. */
    private fun createOutput(): Output {
        val name = "ZamZam_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".mp4"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/$FOLDER")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = ctx.contentResolver
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IOException("저장할 파일을 만들지 못했어요")
        val pfd = try {
            resolver.openFileDescriptor(uri, "rw")
        } catch (e: Exception) {
            null
        }
        if (pfd == null) {
            resolver.delete(uri, null, null)
            throw IOException("저장할 파일을 열지 못했어요")
        }
        return Output(uri, pfd, name)
    }

    private fun displayName(uri: Uri): String? =
        ctx.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    // ------------------------------------------------------------------ helpers

    private fun openExtractor(uri: Uri): MediaExtractor = MediaExtractor().also { it.setDataSource(ctx, uri, null) }

    private fun background(executor: ExecutorService, result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: CancelledException) {
                main.post { result.error("CANCELLED", "취소했어요", null) }
            } catch (e: Throwable) {
                main.post { result.error("FAILED", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun MethodCall.uri(key: String): Uri = Uri.parse(argument<String>(key)!!)

    private fun MethodCall.long(key: String): Long = argument<Number>(key)!!.toLong()

    private class CancelledException : Exception()

    companion object {
        private const val FOLDER = "ZamZam"
    }
}
