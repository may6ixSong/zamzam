package io.github.may6ixsong.zamzam

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.FileDescriptor
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 영상(과 음성)을 재인코딩 없이 새 MP4 로 옮겨 담는다. 자르기가 되는 '깨끗한' 파일을 만드는 게 목적이다.
 *
 * 1번째 훑기: 영상 프레임 데이터를 직접 읽어 진짜 키프레임을 찾는다([NalKeyframes]).
 *   스트리밍(TS) 원본은 MediaExtractor 의 키프레임 표시가 빠지거나 모든 프레임에 붙기도 해서 믿지 않는다.
 * 2번째 훑기: 첫 키프레임부터 시각 0 으로 맞춰 쓴다. 그 앞의 프레임·음성은 버린다
 *   (첫 키프레임 앞 프레임은 디코딩할 수 없어 자르기·재생에서 문제를 일으킨다).
 *
 * [open]은 원본마다 새 MediaExtractor 를 만들어 주는 함수(영상·음성이 따로 있는 스트리밍은 두 개).
 */
class Remuxer(
    private val cancel: AtomicBoolean,
    private val onProgress: (Double) -> Unit = {},
) {
    class Cancelled : IOException("취소했어요")

    private class Pick(val source: Int, val track: Int, val format: MediaFormat)

    fun remux(open: List<() -> MediaExtractor>, out: FileDescriptor) {
        val (video, audio) = pickTracks(open)
        val keys = findKeyframes(open[video.source](), video)
        val first = keys.indexOfFirst { it }
        if (first < 0) throw IOException("영상에서 키프레임을 찾지 못했어요")
        write(open, video, audio, keys, first, out)
    }

    private fun pickTracks(open: List<() -> MediaExtractor>): Pair<Pick, Pick?> {
        var video: Pick? = null
        var audio: Pick? = null
        for ((s, make) in open.withIndex()) {
            val ex = make()
            try {
                for (i in 0 until ex.trackCount) {
                    val f = ex.getTrackFormat(i)
                    val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                    if (video == null && mime.startsWith("video/")) video = Pick(s, i, f)
                    if (audio == null && mime.startsWith("audio/")) audio = Pick(s, i, f)
                }
            } finally {
                ex.release()
            }
        }
        return (video ?: throw IOException("영상 트랙을 찾지 못했어요")) to audio
    }

    /** 디코딩 순서의 영상 샘플마다 키프레임인지. */
    private fun findKeyframes(ex: MediaExtractor, video: Pick): BooleanArray {
        val mime = video.format.getString(MediaFormat.KEY_MIME) ?: ""
        val parse = NalKeyframes.isSupported(mime)
        val levels = ArrayList<Int>()
        val flagged = ArrayList<Boolean>()
        try {
            ex.selectTrack(video.track)
            var buffer = ByteBuffer.allocateDirect(maxInput(video.format))
            var bytes = ByteArray(0)
            while (ex.sampleTrackIndex >= 0) {
                if (cancel.get()) throw Cancelled()
                flagged += (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                if (parse) {
                    val size = try {
                        ex.readSampleData(buffer, 0)
                    } catch (e: IllegalArgumentException) {
                        buffer = ByteBuffer.allocateDirect(buffer.capacity() * 2)
                        flagged.removeAt(flagged.lastIndex)
                        continue
                    }
                    if (size > bytes.size) bytes = ByteArray(size)
                    buffer.position(0)
                    buffer.get(bytes, 0, maxOf(size, 0))
                    levels += if (size > 0) NalKeyframes.classify(mime, bytes, size) else NalKeyframes.NONE
                }
                if (levels.size % 200 == 0) onProgress(0.0)
                if (!ex.advance()) break
            }
        } finally {
            ex.release()
        }
        val n = flagged.size
        if (n == 0) throw IOException("영상 프레임이 없어요")
        // 정한 순서: IDR/복구 지점 → (없으면) I 프레임 → (없으면) 원본 표시 → (그래도 없으면) 첫 프레임.
        val byKey = BooleanArray(n) { parse && levels.getOrNull(it) == NalKeyframes.KEY }
        if (byKey.any { it }) return byKey
        val byIntra = BooleanArray(n) { parse && (levels.getOrNull(it) ?: 0) >= NalKeyframes.INTRA }
        if (byIntra.any { it }) return byIntra
        val byFlag = BooleanArray(n) { flagged[it] }
        if (byFlag.any { it }) return byFlag
        return BooleanArray(n) { it == 0 }
    }

    private fun write(
        open: List<() -> MediaExtractor>,
        video: Pick,
        audio: Pick?,
        keys: BooleanArray,
        first: Int,
        out: FileDescriptor,
    ) {
        val muxer = MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val extractors = HashMap<Int, MediaExtractor>()
        var started = false
        try {
            fun ex(source: Int) = extractors.getOrPut(source) { open[source]() }
            val vOut = muxer.addTrack(video.format)
            // 음성 형식을 MP4 에 못 담으면(예: MP3 일부) 영상만이라도 저장한다.
            val aOut = audio?.let { runCatching { muxer.addTrack(it.format) }.getOrNull() } ?: -1
            ex(video.source).selectTrack(video.track)
            if (aOut >= 0) ex(audio!!.source).selectTrack(audio.track)
            muxer.start()
            started = true

            var buffer = ByteBuffer.allocateDirect(maxOf(maxInput(video.format), audio?.let { maxInput(it.format) } ?: 0))
            val info = MediaCodec.BufferInfo()
            var videoIndex = 0
            var base = -1L
            var written = 0
            val all = extractors.values.toList()
            while (true) {
                if (cancel.get()) throw Cancelled()
                val e = all.filter { it.sampleTrackIndex >= 0 }.minByOrNull { it.sampleTime } ?: break
                val trackIdx = e.sampleTrackIndex
                val source = extractors.entries.first { it.value === e }.key
                val isVideo = source == video.source && trackIdx == video.track
                val isAudio = aOut >= 0 && source == audio!!.source && trackIdx == audio.track
                val t = e.sampleTime
                var write = false
                var key = false
                if (isVideo) {
                    val i = videoIndex++
                    if (i == first) base = t
                    // 첫 키프레임 앞, 그리고 그보다 이른 시각의 프레임(열린 GOP 의 앞쪽 B 프레임)은 디코딩할 수 없다.
                    write = i >= first && t >= base
                    key = i < keys.size && keys[i]
                    if (i % 100 == 0) onProgress(i.toDouble() / keys.size)
                } else if (isAudio) {
                    write = base >= 0 && t >= base
                }
                if (write) {
                    val size = try {
                        e.readSampleData(buffer, 0)
                    } catch (x: IllegalArgumentException) {
                        buffer = ByteBuffer.allocateDirect(buffer.capacity() * 2)
                        if (isVideo) videoIndex--
                        continue
                    }
                    if (size > 0) {
                        info.set(0, size, t - base, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                        muxer.writeSampleData(if (isVideo) vOut else aOut, buffer, info)
                        written++
                    }
                }
                e.advance()
            }
            if (written == 0) throw IOException("영상 프레임을 쓰지 못했어요")
            started = false
            muxer.stop()
            onProgress(1.0)
        } finally {
            if (started) runCatching { muxer.stop() }
            runCatching { muxer.release() }
            extractors.values.forEach { runCatching { it.release() } }
        }
    }

    private fun maxInput(f: MediaFormat): Int =
        if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) maxOf(f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE), 1 shl 20)
        else 2 shl 20
}
