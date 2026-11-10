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
import android.webkit.CookieManager
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
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
    private val filePicker: (accept: List<String>, multiple: Boolean, result: MethodChannel.Result) -> Unit,
    private val trasher: (uris: List<Uri>, result: MethodChannel.Result) -> Unit,
    private val webViewOf: (id: Long) -> android.webkit.WebView?,
) : MethodChannel.MethodCallHandler {

    // 브라우저 동영상 내려받기. 여러 개를 동시에 받을 수 있다.
    private val downloadExecutor: ExecutorService = Executors.newFixedThreadPool(3)
    private val downloadCancels = ConcurrentHashMap<String, AtomicBoolean>()

    private val exportExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val probeExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    // 다운로드 목록의 길이·썸네일. 자르기·합치기의 영상 열기를 막지 않도록 따로 둔다.
    private val listExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    // 미리보기 화면 한 장. 손가락을 따라 빠르게 불리므로 별도 스레드에서 리트리버를 열어 둔 채 쓴다.
    private val frameExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var frameRetriever: MediaMetadataRetriever? = null
    private var frameUri: Uri? = null
    private val main = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        channel.setMethodCallHandler(null)
        cancelled.set(true)
        exportExecutor.shutdownNow()
        downloadCancels.values.forEach { it.set(true) }
        downloadExecutor.shutdownNow()
        probeExecutor.shutdownNow()
        listExecutor.shutdownNow()
        frameExecutor.execute { frameRetriever?.release(); frameRetriever = null }
        frameExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickVideos" -> picker(call.argument<Boolean>("multiple") == true, result)
            "probe" -> background(probeExecutor, result) { probe(call.uri("uri")) }
            "diagnose" -> {
                cancelled.set(false)
                background(exportExecutor, result) { diagnoseFile(call.uri("uri")) }
            }
            "listInfo" -> background(listExecutor, result) { listInfo(call.uri("uri"), call.long("height").toInt()) }
            "thumbnails" -> background(probeExecutor, result) {
                thumbnails(call.uri("uri"), call.long("count").toInt(), call.long("height").toInt())
            }
            "frameAt" -> background(frameExecutor, result) {
                frameAt(call.uri("uri"), call.long("us"), call.long("height").toInt(), call.argument<Boolean>("exact") == true)
            }
            "trim" -> {
                cancelled.set(false)
                val rotateCcw = call.argument<Number>("rotateCcw")?.toInt() ?: 0
                background(exportExecutor, result) {
                    trim(call.uri("uri"), call.long("startUs"), call.long("endUs"), rotateCcw)
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
            "download" -> {
                val id = call.argument<String>("id")!!
                val flag = AtomicBoolean(false)
                downloadCancels[id] = flag
                val url = call.argument<String>("url")!!
                val name = call.argument<String>("name") ?: "video"
                val auth = webAuth(call, url)
                val variantUrl = call.argument<String>("variantUrl")
                val maxShortSide = call.argument<Number>("maxShortSide")?.toInt()
                background(downloadExecutor, result) {
                    try {
                        download(id, url, name, auth, variantUrl, maxShortSide, flag)
                    } finally {
                        downloadCancels.remove(id)
                        lastProgressAt.remove(id)
                    }
                }
            }
            "inspectVideo" -> {
                val url = call.argument<String>("url")!!
                val auth = webAuth(call, url)
                background(probeExecutor, result) { inspectVideo(url, auth) }
            }
            "repair" -> {
                cancelled.set(false)
                val uri = call.uri("uri")
                val toGallery = call.argument<Boolean>("toGallery") == true
                background(exportExecutor, result) {
                    val fixed = repair(uri)
                    if (!toGallery) fixed else saveRepaired(uri, Uri.parse(fixed))
                }
            }
            "compress" -> {
                cancelled.set(false)
                val uri = call.uri("uri")
                val shortSide = call.long("shortSide").toInt()
                background(exportExecutor, result) { compress(uri, shortSide) }
            }
            "cancelDownload" -> {
                downloadCancels[call.argument<String>("id")]?.set(true)
                result.success(null)
            }
            "pickFiles" -> filePicker(
                call.argument<List<String>>("accept") ?: emptyList(),
                call.argument<Boolean>("multiple") == true,
                result,
            )
            "openExternal" -> result.success(openExternal(call.argument<String>("url")!!))
            "trash" -> {
                // 갤러리 선택기 주소 등을 미디어 저장소 주소로 바꾼 뒤 휴지통 요청을 띄운다.
                val requested = call.argument<List<String>>("uris")!!.map(Uri::parse)
                val media = requested.mapNotNull { mediaStoreUri(it) }.distinct()
                val skipped = requested.size - media.size
                if (media.isEmpty()) {
                    result.success(mapOf("moved" to false, "count" to 0, "skipped" to skipped))
                } else {
                    trasher(media, object : MethodChannel.Result {
                        override fun success(value: Any?) =
                            result.success(mapOf("moved" to (value == true), "count" to media.size, "skipped" to skipped))

                        override fun error(code: String, message: String?, details: Any?) = result.error(code, message, details)

                        override fun notImplemented() = result.notImplemented()
                    })
                }
            }
            "installPageScript" -> result.success(installPageScript(call.long("webView"), call.argument<String>("script")!!))
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

            // 영상 샘플을 훑어 키프레임 위치, 프레임 수, 키프레임마다 쌓인 데이터량을 센다(데이터는 읽지 않는다).
            ex.selectTrack(t.video)
            val keyframes = ArrayList<Pair<Long, Long>>()
            var frames = 0
            var minPts = Long.MAX_VALUE
            var maxPts = Long.MIN_VALUE
            var videoBytes = 0L
            while (true) {
                if (ex.sampleTrackIndex < 0) break
                val pts = ex.sampleTime
                if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) keyframes.add(pts to videoBytes)
                videoBytes += ex.sampleSize.coerceAtLeast(0L)
                frames++
                if (pts < minPts) minPts = pts
                if (pts > maxPts) maxPts = pts
                if (!ex.advance()) break
            }
            keyframes.sortBy { it.first }

            var audioBytes: Long? = null
            if (t.audio >= 0) {
                ex.unselectTrack(t.video)
                ex.selectTrack(t.audio)
                ex.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                var sum = 0L
                while (ex.sampleTrackIndex >= 0) {
                    sum += ex.sampleSize.coerceAtLeast(0L)
                    if (!ex.advance()) break
                }
                audioBytes = sum
            }

            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            val durationUs = durationMs?.times(1000)
                ?: if (vf.containsKey(MediaFormat.KEY_DURATION)) vf.getLong(MediaFormat.KEY_DURATION) else maxPts
            val span = if (frames > 1) maxPts - minPts else 0L
            val fps = when {
                span > 0 -> (frames - 1) * 1_000_000.0 / span
                vf.containsKey(MediaFormat.KEY_FRAME_RATE) -> vf.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble() ?: 30.0
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
                "keyframesUs" to keyframes.map { it.first },
                "keyframeBytes" to keyframes.map { it.second },
                "videoBytes" to videoBytes,
                "audioBytes" to audioBytes,
                "exactCut" to false,
                // 음성 샘플이 ADTS 덩어리(스트리밍을 옮긴 파일)면 소리가 안 난다 → 고쳐서 써야 한다.
                "audioAdts" to audioIsAdts(uri, t),
            )
        } finally {
            ex.release()
            retriever.release()
        }
    }

    /**
     * 휴지통 요청에 쓸 미디어 저장소 주소(content://media/external/video/media/ID).
     * 갤러리 선택기 주소는 끝의 번호가 같은 항목을 찾아 이름·크기가 맞는지 확인한다.
     * 앱 임시 폴더의 사본(file://)이나 찾지 못한 항목은 null(건너뛴다).
     */
    private fun mediaStoreUri(uri: Uri): Uri? = runCatching {
        if (uri.scheme != "content") return null
        val path = uri.path ?: ""
        if (uri.authority == MediaStore.AUTHORITY && !path.contains("/picker")) return uri
        // 문서 선택기 주소(content://com.android.providers.media.documents/...)
        if (uri.authority == "com.android.providers.media.documents") return MediaStore.getMediaUri(ctx, uri)
        val id = uri.lastPathSegment?.toLongOrNull() ?: return null
        val candidate = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL, id)
        val (name, size) = nameAndSize(uri)
        val match = ctx.contentResolver.query(
            candidate, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE), null, null, null,
        )?.use { c -> c.moveToFirst() && (c.getLong(1) == size || c.getString(0) == name) } ?: false
        if (match) candidate else null
    }.getOrNull()

    /** 첫 음성 샘플이 ADTS 머리표로 시작하는지(MP4 안에 있으면 소리가 나지 않는 형태). */
    private fun audioIsAdts(uri: Uri, t: Tracks): Boolean = runCatching {
        if (t.audio < 0) return false
        if (t.audioFormat?.getString(MediaFormat.KEY_MIME) != MediaFormat.MIMETYPE_AUDIO_AAC) return false
        val ex = openExtractor(uri)
        try {
            ex.selectTrack(t.audio)
            val buf = ByteBuffer.allocateDirect(1 shl 20)
            val size = ex.readSampleData(buf, 0)
            if (size < 7) return false
            val head = ByteArray(minOf(size, 16))
            buf.position(0)
            buf.get(head)
            AdtsFrames.isAdts(head, 0, head.size)
        } finally {
            ex.release()
        }
    }.getOrDefault(false)

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

    /** 목록용: 길이와 앞부분 화면 한 장. 파일을 훑지 않아 빠르다. */
    private fun listInfo(uri: Uri, height: Int): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(ctx, uri)
            val durationUs = (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            val t = (durationUs / 10).coerceAtMost(3_000_000L)
            val bmp = r.getScaledFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, height * 3, height)
            val thumb = bmp?.let {
                val bytes = ByteArrayOutputStream()
                it.compress(Bitmap.CompressFormat.JPEG, 75, bytes)
                it.recycle()
                bytes.toByteArray()
            }
            return mapOf("durationUs" to durationUs, "thumb" to thumb)
        } finally {
            r.release()
        }
    }

    /** [us] 시점 화면 한 장(JPEG). [exact]가 아니면 가까운 키프레임이라 빠르다. */
    private fun frameAt(uri: Uri, us: Long, height: Int, exact: Boolean): ByteArray? {
        if (frameUri != uri) {
            frameRetriever?.release()
            frameRetriever = MediaMetadataRetriever().also { it.setDataSource(ctx, uri) }
            frameUri = uri
        }
        val r = frameRetriever ?: return null
        val option = if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        val bmp = r.getScaledFrameAtTime(us.coerceAtLeast(0L), option, height * 3, height) ?: return null
        val bytes = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, bytes)
        bmp.recycle()
        return bytes.toByteArray()
    }

    // ------------------------------------------------------------------ export

    /**
     * [rotateCcw]: 화면에서 왼쪽(반시계)으로 더 돌릴 각도(90 의 배수).
     * 영상 데이터는 그대로 두고 MP4 의 회전 정보만 바꾸므로 무손실이다.
     */
    private fun trim(uri: Uri, startUs: Long, endUs: Long, rotateCcw: Int): Map<String, Any?> {
        val probeEx = openExtractor(uri)
        val tracks = try { tracksOf(probeEx) } finally { probeEx.release() }
        val meta = sourceMeta(uri)
        val rotated = SourceMeta(Math.floorMod(meta.rotation - rotateCcw, 360), meta.latitude, meta.longitude)
        return export(listOf(Segment(uri, startUs, endUs)), tracks, rotated)
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
            for ((i, seg) in segments.withIndex()) {
                if (copySegment(muxer, videoOut, audioOut, seg, state) == 0) {
                    val where = if (segments.size > 1) "${i + 1}번 영상에서" else "선택한 구간에서"
                    throw IOException("$where 영상 프레임을 읽지 못했어요 (${diagnose(seg)})")
                }
            }

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
    /** 쓴 영상 프레임 수를 돌려준다. */
    private fun copySegment(muxer: MediaMuxer, videoOut: Int, audioOut: Int, seg: Segment, st: CopyState): Int {
        val vEx = openExtractor(seg.uri)
        var aEx: MediaExtractor? = null
        try {
            val t = tracksOf(vEx)
            vEx.selectTrack(t.video)
            // 처음부터면 탐색하지 않는다(첫 프레임 시각이 0 보다 뒤인 파일에서 '이전 키프레임' 탐색이 실패한다).
            if (seg.fromUs > 0) seekSafely(vEx, seg.fromUs)
            // 끝 판정은 시각이 아니라 트랙 번호로 한다. 편집 목록(edit list)이 있는 파일은 첫 프레임 시각이
            // 음수로 읽힐 수 있는데, 이를 '끝'으로 오인하면 프레임을 하나도 못 쓴다.
            if (vEx.sampleTrackIndex < 0) return 0
            val start = vEx.sampleTime
            val end = seg.toUs
            // 음성은 영상 트랙 길이까지만(합치기에서 다음 영상과 겹치지 않게). 길이 정보가 이상하면 무시한다.
            val trackDuration = if (t.videoFormat.containsKey(MediaFormat.KEY_DURATION)) {
                t.videoFormat.getLong(MediaFormat.KEY_DURATION).takeIf { it > 0 } ?: Long.MAX_VALUE
            } else {
                Long.MAX_VALUE
            }
            val audioEnd = minOf(end, trackDuration)

            if (audioOut >= 0 && t.audio >= 0) {
                aEx = openExtractor(seg.uri).also {
                    it.selectTrack(t.audio)
                    if (start > 0) seekSafely(it, start)
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
                if (!videoDone && vEx.sampleTrackIndex < 0) { videoDone = true; continue }
                if (!audioDone && aEx!!.sampleTrackIndex < 0) { audioDone = true; continue }
                val vt = if (videoDone) Long.MAX_VALUE else vEx.sampleTime
                val at = if (audioDone) Long.MAX_VALUE else aEx!!.sampleTime

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
                    if (at >= audioEnd) { audioDone = true; continue }
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
                val length = minOf(lastPts + frame, end) - start
                st.offsetUs += length
                st.doneUs += length
            }
            return written
        } finally {
            vEx.release()
            aEx?.release()
        }
    }

    /** 오류 보고용: 영상 트랙 형식과 처음 몇 샘플의 상태. */
    private fun diagnose(seg: Segment): String = runCatching {
        val ex = openExtractor(seg.uri)
        try {
            val t = tracksOf(ex)
            ex.selectTrack(t.video)
            val samples = (0 until 3).map {
                val s = "${ex.sampleTrackIndex}/${ex.sampleTime}/${ex.sampleSize}/${ex.sampleFlags}"
                ex.advance()
                s
            }
            "${t.videoFormat.getString(MediaFormat.KEY_MIME)}, 트랙 ${ex.trackCount}개, 샘플 ${samples.joinToString(" ")}"
        } finally {
            ex.release()
        }
    }.getOrElse { "진단 실패: ${it.message}" }

    /** [t] 직전 키프레임으로. 실패하면(첫 샘플보다 앞 등) 가장 가까운 키프레임, 그래도 안 되면 처음으로. */
    private fun seekSafely(ex: MediaExtractor, t: Long) {
        ex.seekTo(t, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        if (ex.sampleTrackIndex >= 0) return
        ex.seekTo(t, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        if (ex.sampleTrackIndex >= 0) return
        ex.seekTo(0, MediaExtractor.SEEK_TO_NEXT_SYNC)
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
    private fun createOutput(
        name: String = "ZamZam_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".mp4",
        mime: String = "video/mp4",
    ): Output {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
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

    // ------------------------------------------------------------------ browser

    /** 브라우저와 같은 쿠키·User-Agent·Referer 를 붙인 요청. 로그인이 필요한 사이트도 받을 수 있게 한다. */
    private class WebAuth(val referer: String?, val userAgent: String?, val firstUrl: String, val firstCookies: String?)

    private fun connect(url: String, auth: WebAuth, range: LongRange? = null, follow: Boolean = true): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = follow
            connectTimeout = 20_000
            readTimeout = 30_000
            setRequestProperty("Accept", "video/*,*/*;q=0.8")
            setRequestProperty("Accept-Encoding", "identity")
            if (!auth.userAgent.isNullOrEmpty()) setRequestProperty("User-Agent", auth.userAgent)
            if (!auth.referer.isNullOrEmpty()) setRequestProperty("Referer", auth.referer)
            val cookie = if (url == auth.firstUrl) auth.firstCookies
            else runCatching { CookieManager.getInstance().getCookie(url) }.getOrNull()
            if (!cookie.isNullOrEmpty()) setRequestProperty("Cookie", cookie)
            if (range != null) setRequestProperty("Range", "bytes=${range.first}-${range.last}")
        }

    /** 주소를 따라가(최대 8번) 응답을 연다. 2xx 가 아니면 예외. */
    private fun openFollowing(url: String, auth: WebAuth, range: LongRange? = null): Pair<HttpURLConnection, String> {
        var current = url
        var redirects = 0
        while (true) {
            val c = connect(current, auth, range, follow = false)
            val code = c.responseCode
            if (code in 300..399) {
                val location = c.getHeaderField("Location")
                c.disconnect()
                if (location == null || ++redirects > 8) throw IOException("주소가 너무 여러 번 바뀌어요")
                current = URL(URL(current), location).toString()
                continue
            }
            if (code !in 200..299) {
                c.disconnect()
                throw IOException("서버가 거부했어요 (HTTP $code)")
            }
            return c to current
        }
    }

    private fun contentTypeOf(c: HttpURLConnection) =
        c.contentType?.substringBefore(';')?.trim()?.lowercase(Locale.US) ?: ""

    /**
     * 받기 전에 화질 목록과 용량을 알아본다.
     * HLS 면 화질별 해상도·대역폭과 길이, 파일이면 전체 크기.
     */
    private fun inspectVideo(url: String, auth: WebAuth): Map<String, Any?> {
        if (isPlaylistUrl(url)) return inspectHls(url, auth)
        val (c, finalUrl) = openFollowing(url, auth, 0L..0L)
        try {
            val type = contentTypeOf(c)
            if (type.contains("mpegurl")) return inspectHls(finalUrl, auth)
            // "bytes 0-0/12345" 의 전체 크기, 범위를 무시하면 Content-Length.
            val total = c.getHeaderField("Content-Range")?.substringAfter('/')?.toLongOrNull()
                ?: c.contentLengthLong.takeIf { c.responseCode == 200 && it > 0 }
            return mapOf("kind" to "file", "sizeBytes" to total, "mime" to type)
        } finally {
            c.disconnect()
        }
    }

    private fun inspectHls(url: String, auth: WebAuth): Map<String, Any?> {
        val info = HlsDownloader({ u, r -> connect(u, auth, r) }, AtomicBoolean(false)) { _, _ -> }.inspect(url)
        return mapOf(
            "kind" to "hls",
            "durationSec" to info.durationSec,
            "variants" to info.variants.map {
                mapOf("url" to it.url, "width" to it.width, "height" to it.height, "bandwidth" to it.bandwidth)
            },
        )
    }

    /**
     * 웹 동영상을 받아 갤러리(Movies/ZamZam)에 저장한다.
     * - HLS 면 [variantUrl] 화질(없으면 최고 화질)을 받아 MP4 로 합친다.
     * - [maxShortSide]를 주면 받은 뒤 그 해상도로 낮춰 다시 압축한다(원본은 남기지 않는다).
     */
    private fun download(
        id: String,
        url: String,
        baseName: String,
        auth: WebAuth,
        variantUrl: String?,
        maxShortSide: Int?,
        cancel: AtomicBoolean,
    ): Map<String, Any?> {
        val work = java.io.File(ctx.cacheDir, "dl/$id").apply { mkdirs() }
        try {
            if (maxShortSide == null) {
                // 바로 갤러리 파일에 쓴다(임시 파일 없이).
                return if (isPlaylistUrl(url)) {
                    toGallery("$baseName.mp4", "video/mp4") { fd -> fetchHls(id, url, auth, variantUrl, work, fd, cancel) }
                } else {
                    val (c, finalUrl) = openFollowing(url, auth)
                    if (contentTypeOf(c).contains("mpegurl")) {
                        c.disconnect()
                        toGallery("$baseName.mp4", "video/mp4") { fd -> fetchHls(id, finalUrl, auth, variantUrl, work, fd, cancel) }
                    } else {
                        val (ext, mime) = fileTypeOf(c, finalUrl)
                        toGallery("$baseName.$ext", mime) { fd -> copyBody(id, c, FileOutputStream(fd), cancel) }
                    }
                }
            }
            // 화질 낮추기: 임시 파일로 받은 뒤 변환해서 갤러리로.
            val src = java.io.File(work, "source")
            if (isPlaylistUrl(url)) {
                FileOutputStream(src).use { fetchHls(id, url, auth, variantUrl, java.io.File(work, "hls"), it.fd, cancel) }
            } else {
                val (c, finalUrl) = openFollowing(url, auth)
                if (contentTypeOf(c).contains("mpegurl")) {
                    c.disconnect()
                    FileOutputStream(src).use { fetchHls(id, finalUrl, auth, variantUrl, java.io.File(work, "hls"), it.fd, cancel) }
                } else {
                    fileTypeOf(c, finalUrl)
                    FileOutputStream(src).use { copyBody(id, c, it, cancel) }
                }
            }
            val converted = java.io.File(work, "converted.mp4")
            val plan = Transcoder.planFor(src, maxShortSide)
            val final = if (plan == null) src else {
                Transcoder(ctx, main).run(Uri.fromFile(src), converted, plan, cancel) { pct ->
                    reportDownload(id, pct.toLong(), 100L, phase = "convert")
                }
                converted
            }
            return toGallery("$baseName.mp4", "video/mp4") { fd ->
                java.io.FileInputStream(final).use { input -> FileOutputStream(fd).use { input.copyTo(it, 256 * 1024) } }
            }
        } catch (e: HlsDownloader.CancelledByUser) {
            throw CancelledException()
        } catch (e: Transcoder.Cancelled) {
            throw CancelledException()
        } catch (e: Remuxer.Cancelled) {
            throw CancelledException()
        } finally {
            work.deleteRecursively()
        }
    }

    /** 영상 파일이 맞는지 보고 (확장자, MIME)을 정한다. 웹 페이지 등이면 예외. */
    private fun fileTypeOf(c: HttpURLConnection, url: String): Pair<String, String> {
        val type = contentTypeOf(c)
        if (type.startsWith("text/") || type.contains("dash+xml") || type.contains("json")) {
            c.disconnect()
            throw IOException("동영상 파일이 아니에요 ($type)")
        }
        val ext = extensionFor(type, url)
        return ext to (VIDEO_MIME[ext] ?: "video/mp4")
    }

    private fun copyBody(id: String, c: HttpURLConnection, output: java.io.OutputStream, cancel: AtomicBoolean) {
        val total = c.contentLengthLong
        var received = 0L
        try {
            c.inputStream.use { input ->
                output.use { os ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        if (cancel.get()) throw CancelledException()
                        val n = input.read(buf)
                        if (n < 0) break
                        os.write(buf, 0, n)
                        received += n
                        reportProgressThrottled(id, received, total)
                    }
                    os.flush()
                }
            }
        } finally {
            c.disconnect()
        }
        if (received == 0L) throw IOException("받은 내용이 없어요")
    }

    private fun fetchHls(
        id: String,
        url: String,
        auth: WebAuth,
        variantUrl: String?,
        work: java.io.File,
        fd: java.io.FileDescriptor,
        cancel: AtomicBoolean,
    ) {
        val hls = HlsDownloader({ u, r -> connect(u, auth, r) }, cancel) { received, total ->
            reportProgressThrottled(id, received, total)
        }
        hls.download(url, work, fd, variantUrl)
    }

    /** 갤러리에 '작성 중' 파일을 만들어 [write]로 채우고 공개한다. 실패하면 지운다. */
    private fun toGallery(name: String, mime: String, write: (java.io.FileDescriptor) -> Unit): Map<String, Any?> {
        val out = createOutput(name, mime)
        try {
            write(out.pfd.fileDescriptor)
            runCatching { out.pfd.close() }
            // 쓰는 쪽이 스트림을 닫으며 파일 핸들도 닫으므로 다시 열어 크기를 잰다.
            val size = ctx.contentResolver.openFileDescriptor(out.uri, "r")?.use { it.statSize } ?: 0L
            if (size <= 0L) throw IOException("받은 내용이 없어요")
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            ctx.contentResolver.update(out.uri, done, null, null)
            return mapOf(
                "uri" to out.uri.toString(),
                "name" to (displayName(out.uri) ?: out.name),
                "size" to size,
                "mime" to mime,
            )
        } catch (e: Throwable) {
            discard(out)
            throw e
        }
    }

    /**
     * 문제 진단: 파일 정보, 트랙 형식, 앞쪽 샘플, 영상 정보 읽기, 그리고 실제 자르기(앞 3초)를 시험해
     * 결과를 글로 돌려준다. 시험으로 만든 파일은 바로 지운다. 각 단계는 실패해도 다음 단계를 계속한다.
     */
    private fun diagnoseFile(uri: Uri): String {
        val sb = StringBuilder()
        fun line(s: String) = sb.append(s).append('\n')
        fun step(name: String, block: () -> Unit) {
            try {
                block()
            } catch (e: Throwable) {
                line("[$name] 실패: ${e.javaClass.simpleName}: ${e.message}")
                e.stackTrace.take(4).forEach { line("    at $it") }
            }
        }
        line("ZamZam 진단 · Android ${android.os.Build.VERSION.SDK_INT} · ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        line("uri: $uri")
        step("파일") {
            val (name, size) = nameAndSize(uri)
            line("이름: $name, 크기: $size")
            ctx.contentResolver.query(
                uri, arrayOf(MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.OWNER_PACKAGE_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) line("MIME: ${c.getString(0)}, 소유: ${c.getString(1)}") }
        }
        step("메타데이터") {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(ctx, uri)
                val keys = mapOf(
                    "길이ms" to MediaMetadataRetriever.METADATA_KEY_DURATION,
                    "MIME" to MediaMetadataRetriever.METADATA_KEY_MIMETYPE,
                    "가로" to MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                    "세로" to MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                    "회전" to MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                    "비트레이트" to MediaMetadataRetriever.METADATA_KEY_BITRATE,
                    "프레임수" to MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT,
                )
                line(keys.entries.joinToString(", ") { "${it.key}=${r.extractMetadata(it.value)}" })
            } finally {
                r.release()
            }
        }
        step("트랙") {
            val ex = openExtractor(uri)
            try {
                for (i in 0 until ex.trackCount) line("트랙$i: ${ex.getTrackFormat(i)}")
                val t = tracksOf(ex)
                ex.selectTrack(t.video)
                var n = 0
                var sync = 0
                val first = ArrayList<String>()
                val deadline = System.currentTimeMillis() + 5000
                while (ex.sampleTrackIndex >= 0 && System.currentTimeMillis() < deadline) {
                    val isSync = (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                    if (isSync) sync++
                    if (n < 8) first += "${ex.sampleTime}/${ex.sampleSize}/${if (isSync) "K" else "-"}"
                    n++
                    if (!ex.advance()) break
                }
                line("영상 샘플(5초 동안 센 것): $n, 키프레임 $sync")
                if (t.audio >= 0) {
                    val a = openExtractor(uri)
                    try {
                        a.selectTrack(t.audio)
                        val buf = ByteBuffer.allocateDirect(1 shl 20)
                        val sizes = ArrayList<Int>()
                        var head = ""
                        while (a.sampleTrackIndex >= 0 && sizes.size < 50) {
                            val sz = a.readSampleData(buf, 0)
                            if (sizes.isEmpty() && sz > 0) {
                                val b = ByteArray(minOf(sz, 8))
                                buf.position(0)
                                buf.get(b)
                                head = b.joinToString(" ") { "%02x".format(it) }
                            }
                            sizes += sz
                            if (!a.advance()) break
                        }
                        line("음성 첫 샘플: [$head] ADTS=${head.startsWith("ff f")}, 평균 크기 ${sizes.average().toInt()}바이트")
                    } finally {
                        a.release()
                    }
                }
                line("앞 샘플(시각/크기/키): ${first.joinToString(" ")}")
            } finally {
                ex.release()
            }
        }
        var durationUs = 0L
        step("정보 읽기(probe)") {
            val p = probe(uri)
            durationUs = (p["durationUs"] as Number).toLong()
            val keys = p["keyframesUs"] as List<*>
            line("probe 성공: 길이 ${durationUs}us, fps ${p["fps"]}, 키프레임 ${keys.size}개 (앞: ${keys.take(5)})")
        }
        step("자르기 시험(앞 3초)") {
            val end = if (durationUs > 0) minOf(durationUs, 3_000_000L) else 3_000_000L
            val r = trim(uri, 0L, end, 0)
            line("자르기 성공: ${r["name"]}, ${r["size"]}바이트, ${r["durationUs"]}us")
            runCatching { ctx.contentResolver.delete(Uri.parse(r["uri"] as String), null, null) }
        }
        step("자르기 시험(가운데 3초)") {
            if (durationUs > 8_000_000L) {
                val mid = durationUs / 2
                val r = trim(uri, mid, mid + 3_000_000L, 0)
                line("가운데 자르기 성공: ${r["size"]}바이트, ${r["durationUs"]}us")
                runCatching { ctx.contentResolver.delete(Uri.parse(r["uri"] as String), null, null) }
            }
        }
        return sb.toString()
    }

    /**
     * 자르기가 안 되는 영상(키프레임 정보가 깨진 파일 등)을 앱 임시 폴더에 고친 사본으로 만든다.
     * 갤러리의 원본은 건드리지 않는다. 진행률은 자르기·합치기와 같은 채널로 보낸다.
     */
    private fun repair(uri: Uri): String {
        val dir = java.io.File(ctx.cacheDir, "repaired").apply { mkdirs() }
        // 몇 시간 지난 사본은 지운다(용량 절약). 합치기에서 여러 개를 함께 쓰므로 방금 것은 남긴다.
        val old = System.currentTimeMillis() - 6 * 3600_000L
        dir.listFiles()?.filter { it.lastModified() < old }?.forEach { it.delete() }
        val base = (displayName(uri)?.substringBeforeLast('.') ?: "video").replace(Regex("""[\\/:*?"<>|]"""), "_")
        val out = java.io.File(dir, "${base}_${System.currentTimeMillis()}.mp4")
        try {
            FileOutputStream(out).use { fos ->
                Remuxer(cancelled) { f -> main.post { channel.invokeMethod("progress", f.coerceIn(0.0, 1.0)) } }
                    .remux(listOf { openExtractor(uri) }, fos.fd)
            }
        } catch (e: Remuxer.Cancelled) {
            out.delete()
            throw CancelledException()
        } catch (e: Throwable) {
            out.delete()
            throw e
        }
        return Uri.fromFile(out).toString()
    }

    /** 고친 사본을 갤러리에 새 파일로 저장한다(원본 이름 + '_소리복구'). 사본은 지운다. */
    private fun saveRepaired(original: Uri, fixed: Uri): Map<String, Any?> {
        val file = java.io.File(fixed.path!!)
        try {
            val base = (displayName(original)?.substringBeforeLast('.') ?: "ZamZam") + "_소리복구"
            val r = toGallery("$base.mp4", "video/mp4") { fd ->
                java.io.FileInputStream(file).use { input -> FileOutputStream(fd).use { input.copyTo(it, 256 * 1024) } }
            }
            return r + ("durationUs" to durationOf(Uri.parse(r["uri"] as String)))
        } finally {
            file.delete()
        }
    }

    /** 갤러리의 영상을 [shortSide] 해상도로 낮춰 새 파일로 저장한다(자르기·합치기처럼 진행률을 보낸다). */
    private fun compress(uri: Uri, shortSide: Int): Map<String, Any?> {
        val work = java.io.File(ctx.cacheDir, "compress").apply { deleteRecursively(); mkdirs() }
        try {
            val plan = Transcoder.planFor(ctx, uri, shortSide)
                ?: throw IOException("이미 그 해상도보다 작은 영상이에요")
            val out = java.io.File(work, "out.mp4")
            try {
                Transcoder(ctx, main).run(uri, out, plan, cancelled) { pct ->
                    main.post { channel.invokeMethod("progress", pct / 100.0) }
                }
            } catch (e: Transcoder.Cancelled) {
                throw CancelledException()
            }
            val base = (displayName(uri)?.substringBeforeLast('.') ?: "ZamZam") + "_${shortSide}p"
            val r = toGallery("$base.mp4", "video/mp4") { fd ->
                java.io.FileInputStream(out).use { input -> FileOutputStream(fd).use { input.copyTo(it, 256 * 1024) } }
            }
            return r + ("durationUs" to durationOf(Uri.parse(r["uri"] as String)))
        } finally {
            work.deleteRecursively()
        }
    }

    private fun isPlaylistUrl(url: String): Boolean {
        val lower = url.lowercase(Locale.US)
        val path = runCatching { URL(url).path.lowercase(Locale.US) }.getOrDefault("")
        return path.endsWith(".m3u8") || lower.contains(".m3u8?") || lower.contains("format=m3u8")
    }

    private val lastProgressAt = ConcurrentHashMap<String, Long>()

    private fun reportProgressThrottled(id: String, received: Long, total: Long) {
        val now = System.currentTimeMillis()
        if (now - (lastProgressAt[id] ?: 0L) < 200) return
        lastProgressAt[id] = now
        reportDownload(id, received, total)
    }

    private fun reportDownload(id: String, received: Long, total: Long, phase: String = "download") {
        main.post {
            channel.invokeMethod(
                "downloadProgress",
                mapOf("id" to id, "received" to received, "total" to total, "phase" to phase),
            )
        }
    }

    private fun extensionFor(type: String, url: String): String {
        MIME_EXT[type]?.let { return it }
        val path = runCatching { URL(url).path.lowercase(Locale.US) }.getOrDefault("")
        return VIDEO_MIME.keys.firstOrNull { path.endsWith(".$it") } ?: "mp4"
    }

    /**
     * 모든 프레임(다른 사이트의 iframe 포함)에 페이지가 시작될 때 스크립트를 넣는다.
     * 일반 사이트의 동영상 플레이어는 대부분 iframe 안에 있어서 바깥 페이지에만 넣으면 길게 누르기를 못 잡는다.
     */
    private fun installPageScript(id: Long, script: String): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return false
        val webView = webViewOf(id) ?: return false
        return runCatching {
            WebViewCompat.addDocumentStartJavaScript(webView, script, setOf("*"))
            true
        }.getOrDefault(false)
    }

    /** tel:, mailto:, intent:, 앱 전용 주소를 해당 앱으로 연다. */
    private fun openExternal(url: String): Boolean {
        val intent = try {
            if (url.startsWith("intent:", ignoreCase = true)) {
                Intent.parseUri(url, Intent.URI_INTENT_SCHEME).apply {
                    // 웹 페이지가 앱 내부 화면을 직접 지정하지 못하게 한다.
                    addCategory(Intent.CATEGORY_BROWSABLE)
                    component = null
                    selector = null
                }
            } else {
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
            }
        } catch (e: Exception) {
            return false
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (e: Exception) {
            // 앱이 없으면 플레이 스토어로 안내한다.
            val pkg = intent.`package` ?: return false
            runCatching {
                ctx.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                true
            }.getOrDefault(false)
        }
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

    /** 쿠키는 웹뷰 스레드(메인)에서 읽어 둔다. */
    private fun webAuth(call: MethodCall, url: String) = WebAuth(
        call.argument<String>("referer"),
        call.argument<String>("userAgent"),
        url,
        runCatching { CookieManager.getInstance().getCookie(url) }.getOrNull(),
    )

    private fun MethodCall.uri(key: String): Uri = Uri.parse(argument<String>(key)!!)

    private fun MethodCall.long(key: String): Long = argument<Number>(key)!!.toLong()

    private class CancelledException : Exception()

    companion object {
        private const val FOLDER = "ZamZam"
        private val VIDEO_MIME = mapOf(
            "mp4" to "video/mp4",
            "m4v" to "video/x-m4v",
            "mov" to "video/quicktime",
            "webm" to "video/webm",
            "mkv" to "video/x-matroska",
            "3gp" to "video/3gpp",
        )
        private val MIME_EXT = mapOf(
            "video/mp4" to "mp4",
            "video/x-m4v" to "m4v",
            "video/quicktime" to "mov",
            "video/webm" to "webm",
            "video/x-matroska" to "mkv",
            "video/3gpp" to "3gp",
        )
    }
}
