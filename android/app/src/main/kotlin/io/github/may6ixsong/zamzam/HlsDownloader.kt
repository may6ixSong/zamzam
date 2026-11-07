package io.github.may6ixsong.zamzam

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * HLS(.m3u8) 스트리밍 영상을 내려받아 MP4 하나로 만든다.
 *
 * 1. 재생 목록에서 가장 화질이 좋은 영상(과 따로 있으면 음성) 목록을 고른다.
 * 2. 조각(TS 또는 fMP4)을 순서대로 받아 임시 파일 하나에 이어 쓴다. AES-128 은 풀어서 쓴다.
 * 3. MediaExtractor 로 읽어 MediaMuxer 로 MP4 에 옮겨 담는다(재인코딩 없음).
 */
class HlsDownloader(
    private val open: (url: String, range: LongRange?) -> HttpURLConnection,
    private val cancel: AtomicBoolean,
    private val progress: (received: Long, total: Long) -> Unit,
) {
    class Unsupported(message: String) : IOException(message)

    private class Key(val url: String, val iv: ByteArray?)

    private class Seg(val url: String, val range: LongRange?, val key: Key?, val seq: Long)

    private class Media(val init: Seg?, val segs: List<Seg>)

    private val keys = HashMap<String, ByteArray>()

    /** 대표 재생 목록의 화질 하나. */
    class Variant(val url: String, val width: Int, val height: Int, val bandwidth: Long, val audioGroup: String?)

    /** 화질 목록(높은 화질 먼저)과 영상 길이(초). 화질이 하나뿐인 목록이면 빈 목록. */
    class Info(val variants: List<Variant>, val durationSec: Double)

    fun inspect(playlistUrl: String): Info {
        val body = text(playlistUrl)
        if (!body.trimStart().startsWith("#EXTM3U")) throw IOException("재생 목록(m3u8)이 아니에요")
        val variants = if (body.contains("#EXT-X-STREAM-INF")) parseVariants(playlistUrl, body).variants else emptyList()
        val mediaUrl = variants.firstOrNull()?.url ?: playlistUrl
        val media = if (mediaUrl == playlistUrl) body else text(mediaUrl)
        val duration = media.lines().filter { it.startsWith("#EXTINF:") }
            .sumOf { it.substringAfter(':').substringBefore(',').trim().toDoubleOrNull() ?: 0.0 }
        return Info(variants, duration)
    }

    /**
     * [playlistUrl]을 받아 [out]에 MP4 로 쓴다. 임시 파일은 [workDir]에 만들고 지운다.
     * [variantUrl]을 주면 그 화질을, 아니면 가장 좋은 화질을 받는다.
     */
    fun download(playlistUrl: String, workDir: File, out: FileDescriptor, variantUrl: String? = null) {
        workDir.mkdirs()
        try {
            val (videoUrl, audioUrl) = pickStreams(playlistUrl, variantUrl)
            val video = parseMedia(videoUrl)
            val audio = audioUrl?.let { parseMedia(it) }
            val totalSegs = video.segs.size + (audio?.segs?.size ?: 0)
            val counter = Counter(totalSegs)
            val files = mutableListOf(File(workDir, "video.bin").also { fetchAll(video, it, counter) })
            if (audio != null) files += File(workDir, "audio.bin").also { fetchAll(audio, it, counter) }
            remux(files, out)
        } finally {
            workDir.deleteRecursively()
        }
    }

    // ------------------------------------------------------------------ playlists

    private fun text(url: String): String {
        val c = open(url, null)
        try {
            val code = c.responseCode
            if (code !in 200..299) throw IOException("재생 목록을 받지 못했어요 (HTTP $code)")
            return c.inputStream.bufferedReader().readText()
        } finally {
            c.disconnect()
        }
    }

    private class Master(val variants: List<Variant>, val audios: List<Map<String, String>>)

    private fun parseVariants(url: String, body: String): Master {
        val lines = body.lines().map { it.trim() }
        val variants = mutableListOf<Variant>()
        val audios = mutableListOf<Map<String, String>>()
        for ((i, line) in lines.withIndex()) {
            if (line.startsWith("#EXT-X-MEDIA:")) {
                val a = attrs(line.substringAfter(':'))
                if (a["TYPE"] == "AUDIO" && a["URI"] != null) audios += a
            }
            if (!line.startsWith("#EXT-X-STREAM-INF:")) continue
            val a = attrs(line.substringAfter(':'))
            val uri = lines.drop(i + 1).firstOrNull { it.isNotEmpty() && !it.startsWith("#") } ?: continue
            val res = a["RESOLUTION"]?.split('x')?.mapNotNull { it.toIntOrNull() }
            // 평균 대역폭이 있으면 그걸로(용량 예상이 더 정확하다).
            val bw = a["AVERAGE-BANDWIDTH"]?.toLongOrNull() ?: a["BANDWIDTH"]?.toLongOrNull() ?: 0L
            variants += Variant(
                resolve(url, uri),
                res?.getOrNull(0) ?: 0,
                res?.getOrNull(1) ?: 0,
                bw,
                a["AUDIO"],
            )
        }
        // 같은 화질이 여러 번(예: 코덱별) 있으면 하나만 남기고, 높은 화질 먼저.
        val sorted = variants
            .sortedWith(compareByDescending<Variant> { it.width.toLong() * it.height }.thenByDescending { it.bandwidth })
            .distinctBy { if (it.height > 0) "${it.width}x${it.height}" else it.url }
        return Master(sorted, audios)
    }

    /** 고른 화질(없으면 가장 좋은 화질)과 그에 맞는 음성 목록. */
    private fun pickStreams(url: String, variantUrl: String? = null): Pair<String, String?> {
        val body = text(url)
        if (!body.trimStart().startsWith("#EXTM3U")) throw IOException("재생 목록(m3u8)이 아니에요")
        if (!body.contains("#EXT-X-STREAM-INF")) return url to null
        val master = parseVariants(url, body)
        val chosen = master.variants.firstOrNull { it.url == variantUrl } ?: master.variants.firstOrNull()
            ?: throw IOException("재생할 수 있는 화질을 찾지 못했어요")
        val audio = chosen.audioGroup?.let { group ->
            val inGroup = master.audios.filter { it["GROUP-ID"] == group }
            (inGroup.firstOrNull { it["DEFAULT"] == "YES" } ?: inGroup.firstOrNull())?.get("URI")?.let { resolve(url, it) }
        }
        // 대표 목록 안에 또 대표 목록이 있는 경우.
        val nested = text(chosen.url)
        return if (nested.contains("#EXT-X-STREAM-INF")) pickStreams(chosen.url).first to audio else chosen.url to audio
    }

    private fun parseMedia(url: String): Media {
        val body = text(url)
        if (!body.contains("#EXT-X-ENDLIST")) throw Unsupported("실시간 방송이라 받을 수 없어요")
        var seq = 0L
        var key: Key? = null
        var init: Seg? = null
        var pendingRange: LongRange? = null
        val lastEnd = HashMap<String, Long>()
        val segs = mutableListOf<Seg>()
        for (raw in body.lines()) {
            val line = raw.trim()
            when {
                line.isEmpty() -> {}
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> seq = line.substringAfter(':').trim().toLongOrNull() ?: 0L
                line.startsWith("#EXT-X-KEY:") -> {
                    val a = attrs(line.substringAfter(':'))
                    key = when (a["METHOD"]) {
                        null, "NONE" -> null
                        "AES-128" -> Key(resolve(url, a["URI"] ?: throw IOException("암호 키 주소가 없어요")), a["IV"]?.let(::hex))
                        else -> throw Unsupported("DRM 으로 보호된 영상이라 받을 수 없어요")
                    }
                }
                line.startsWith("#EXT-X-MAP:") -> if (init == null) {
                    val a = attrs(line.substringAfter(':'))
                    val u = resolve(url, a["URI"] ?: continue)
                    init = Seg(u, a["BYTERANGE"]?.let { byteRange(it, 0L) }, key, -1)
                }
                line.startsWith("#EXT-X-BYTERANGE:") -> pendingRange = line.substringAfter(':')
                    .let { byteRange(it, -1L) }
                line.startsWith("#") -> {}
                else -> {
                    val u = resolve(url, line)
                    var r = pendingRange
                    // '@시작'이 없으면 같은 파일의 앞 조각 바로 뒤부터.
                    if (r != null && r.first < 0) {
                        val start = lastEnd[u] ?: 0L
                        r = start until start + (r.last - r.first + 1)
                    }
                    if (r != null) lastEnd[u] = r.last + 1
                    segs += Seg(u, r, key, seq++)
                    pendingRange = null
                }
            }
        }
        if (segs.isEmpty()) throw IOException("영상 조각이 없어요")
        return Media(init, segs)
    }

    // ------------------------------------------------------------------ fetching

    private class Counter(val totalSegs: Int) {
        var doneSegs = 0
        var bytes = 0L
    }

    /** 조각을 4개씩 동시에 받되, 파일에는 순서대로 쓴다. */
    private fun fetchAll(media: Media, file: File, counter: Counter) {
        val pool = Executors.newFixedThreadPool(4)
        try {
            FileOutputStream(file).use { os ->
                media.init?.let { os.write(fetch(it)) }
                val window = ArrayDeque<Future<ByteArray>>()
                var next = 0
                while (next < media.segs.size || window.isNotEmpty()) {
                    while (next < media.segs.size && window.size < 8) {
                        val seg = media.segs[next++]
                        window.addLast(pool.submit<ByteArray> { fetch(seg) })
                    }
                    if (cancel.get()) throw CancelledByUser()
                    val data = try {
                        window.removeFirst().get()
                    } catch (e: java.util.concurrent.ExecutionException) {
                        throw e.cause ?: e
                    }
                    os.write(data)
                    counter.doneSegs++
                    counter.bytes += data.size
                    val estimate = counter.bytes * counter.totalSegs / counter.doneSegs
                    progress(counter.bytes, estimate)
                }
            }
        } finally {
            pool.shutdownNow()
        }
    }

    class CancelledByUser : IOException("취소했어요")

    private fun fetch(seg: Seg): ByteArray {
        var last: Exception? = null
        repeat(3) { attempt ->
            if (cancel.get()) throw CancelledByUser()
            try {
                val c = open(seg.url, seg.range)
                val bytes = try {
                    val code = c.responseCode
                    if (code !in 200..299) throw IOException("조각을 받지 못했어요 (HTTP $code)")
                    c.inputStream.use { it.readBytes() }
                } finally {
                    c.disconnect()
                }
                // 서버가 범위 요청을 무시하고 전체를 주면 직접 자른다.
                val ranged = if (seg.range != null && bytes.size.toLong() > seg.range.last - seg.range.first + 1 &&
                    bytes.size.toLong() > seg.range.last
                ) {
                    bytes.copyOfRange(seg.range.first.toInt(), (seg.range.last + 1).toInt())
                } else {
                    bytes
                }
                return decrypt(seg, ranged)
            } catch (e: CancelledByUser) {
                throw e
            } catch (e: Unsupported) {
                throw e
            } catch (e: Exception) {
                last = e
                Thread.sleep(500L * (attempt + 1))
            }
        }
        throw last ?: IOException("조각을 받지 못했어요")
    }

    private fun decrypt(seg: Seg, data: ByteArray): ByteArray {
        val key = seg.key ?: return data
        val keyBytes = synchronized(keys) { keys[key.url] } ?: run {
            val c = open(key.url, null)
            val k = try {
                c.inputStream.use { it.readBytes() }
            } finally {
                c.disconnect()
            }
            if (k.size != 16) throw Unsupported("암호 키를 읽지 못했어요")
            synchronized(keys) { keys[key.url] = k }
            k
        }
        val iv = key.iv ?: ByteArray(16).also { b ->
            var s = seg.seq
            for (i in 15 downTo 8) {
                b[i] = (s and 0xff).toByte()
                s = s shr 8
            }
        }
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(data)
    }

    // ------------------------------------------------------------------ remux

    private class Source(val ex: MediaExtractor, val map: Map<Int, Int>)

    private fun remux(files: List<File>, out: FileDescriptor) {
        val muxer = MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val sources = mutableListOf<Source>()
        var started = false
        try {
            var haveVideo = false
            var haveAudio = false
            var bufferSize = 2 * 1024 * 1024
            for (f in files) {
                val ex = MediaExtractor()
                ex.setDataSource(f.path)
                val map = HashMap<Int, Int>()
                for (i in 0 until ex.trackCount) {
                    val fmt = ex.getTrackFormat(i)
                    val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                    val isVideo = mime.startsWith("video/")
                    val isAudio = mime.startsWith("audio/")
                    if ((isVideo && haveVideo) || (isAudio && haveAudio) || (!isVideo && !isAudio)) continue
                    // 음성 형식을 MP4 에 못 담으면(예: MP3 일부) 영상만이라도 저장한다.
                    val idx = try {
                        muxer.addTrack(fmt)
                    } catch (e: Exception) {
                        if (isVideo) throw IOException("이 영상 형식은 MP4 로 바꿀 수 없어요 ($mime)")
                        continue
                    }
                    if (fmt.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                        bufferSize = maxOf(bufferSize, fmt.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                    }
                    ex.selectTrack(i)
                    map[i] = idx
                    if (isVideo) haveVideo = true else haveAudio = true
                }
                if (map.isEmpty()) ex.release() else sources += Source(ex, map)
            }
            if (!haveVideo) throw IOException("영상 트랙을 찾지 못했어요")
            muxer.start()
            started = true

            // 방송용 조각은 시각이 0 이 아닌 곳에서 시작하므로 가장 이른 시각을 0 으로 맞춘다.
            val base = sources.mapNotNull { s -> s.ex.sampleTime.takeIf { it >= 0 } }.minOrNull() ?: 0L
            var buffer = ByteBuffer.allocateDirect(bufferSize)
            val info = MediaCodec.BufferInfo()
            var written = 0
            while (true) {
                if (cancel.get()) throw CancelledByUser()
                val src = sources.filter { it.ex.sampleTrackIndex >= 0 }.minByOrNull { it.ex.sampleTime } ?: break
                val ex = src.ex
                val track = src.map[ex.sampleTrackIndex]
                val t = ex.sampleTime
                if (track != null && t >= base) {
                    val size = try {
                        ex.readSampleData(buffer, 0)
                    } catch (e: IllegalArgumentException) {
                        buffer = ByteBuffer.allocateDirect(buffer.capacity() * 2)
                        continue
                    }
                    if (size > 0) {
                        val sync = (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                        info.set(0, size, t - base, if (sync) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                        muxer.writeSampleData(track, buffer, info)
                        written++
                    }
                }
                ex.advance()
            }
            if (written == 0) throw IOException("영상 프레임을 읽지 못했어요")
            started = false
            muxer.stop()
        } finally {
            if (started) runCatching { muxer.stop() }
            runCatching { muxer.release() }
            sources.forEach { runCatching { it.ex.release() } }
        }
    }

    // ------------------------------------------------------------------ helpers

    companion object {
        private val ATTR = Regex("""([A-Z0-9-]+)=("[^"]*"|[^,]*)""")

        fun attrs(s: String): Map<String, String> =
            ATTR.findAll(s).associate { it.groupValues[1] to it.groupValues[2].trim('"') }

        fun resolve(base: String, ref: String): String = URL(URL(base), ref).toString()

        /** "길이@시작" → 범위. 시작이 없으면 [defaultStart](음수면 '앞 조각 뒤'라는 표시). */
        fun byteRange(s: String, defaultStart: Long): LongRange? {
            val parts = s.trim().trim('"').split('@')
            val len = parts[0].toLongOrNull() ?: return null
            val start = parts.getOrNull(1)?.toLongOrNull() ?: defaultStart
            return if (start < 0) -len until 0L else start until start + len
        }

        private fun hex(s: String): ByteArray {
            val h = s.removePrefix("0x").removePrefix("0X").padStart(32, '0')
            return ByteArray(16) { i -> h.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
        }
    }
}
