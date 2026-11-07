package io.github.may6ixsong.zamzam

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * MP4/MOV 의 목차(moov 상자)만 읽어 키프레임 위치·프레임 수·데이터량을 구한다.
 *
 * MediaExtractor 로 샘플을 하나씩 넘기면 파일 전체를 읽게 되어 큰 영상에서 수십 초가 걸린다.
 * 목차에는 샘플마다 시각(stts/ctts)·크기(stsz)·키프레임 여부(stss)가 적혀 있으므로
 * 이것만 읽으면 영상 길이와 상관없이 빠르다. 조각난 MP4(moof)나 다른 형식이면 null.
 *
 * 시각은 상자에 적힌 그대로의 표시 시각(PTS)이다. MediaExtractor 는 편집 목록(edts)에 따라
 * 전체를 일정량 옮겨 보여 주므로, 부르는 쪽에서 첫 샘플로 맞춰 쓴다([Track.firstPtsUs]).
 */
object Mp4Index {

    class Track(
        val handler: String,
        val timescale: Long,
        /** 디코딩 순서의 샘플별 표시 시각(µs). */
        val ptsUs: LongArray,
        /** 디코딩 순서의 샘플별 크기(바이트). */
        val sizes: IntArray,
        /** 키프레임인 샘플 번호(0부터, 디코딩 순서). null 이면 모든 샘플이 키프레임. */
        val sync: IntArray?,
    ) {
        val sampleCount get() = ptsUs.size
        val firstPtsUs get() = ptsUs.firstOrNull() ?: 0L
        val totalBytes: Long get() = sizes.fold(0L) { a, b -> a + b }

        /** (키프레임 시각, 그 앞까지 쌓인 데이터량) — 시각 순. */
        fun keyframes(): List<Pair<Long, Long>> {
            val out = ArrayList<Pair<Long, Long>>()
            var bytes = 0L
            var k = 0
            val s = sync
            for (i in 0 until sampleCount) {
                if (s != null) while (k < s.size && s[k] < i) k++
                val isKey = if (s == null) true else (k < s.size && s[k] == i).also { if (it) k++ }
                if (isKey) out.add(ptsUs[i] to bytes)
                bytes += sizes[i]
            }
            out.sortBy { it.first }
            return out
        }
    }

    class Index(val tracks: List<Track>) {
        val video get() = tracks.firstOrNull { it.handler == "vide" }
        val audio get() = tracks.firstOrNull { it.handler == "soun" }
    }

    private const val MAX_MOOV = 128L * 1024 * 1024

    fun read(ch: FileChannel): Index? = runCatching { readOrThrow(ch) }.getOrNull()

    private fun readOrThrow(ch: FileChannel): Index? {
        val size = ch.size()
        var pos = 0L
        val head = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
        while (pos + 8 <= size) {
            head.clear()
            head.limit(16.coerceAtMost((size - pos).toInt().coerceAtLeast(8)))
            readFully(ch, head, pos)
            head.flip()
            var boxSize = head.int.toLong() and 0xffffffffL
            val type = fourCC(head.int)
            var headerLen = 8
            if (boxSize == 1L) {
                if (head.remaining() < 8) return null
                boxSize = head.long
                headerLen = 16
            } else if (boxSize == 0L) {
                boxSize = size - pos
            }
            if (boxSize < headerLen) return null
            if (type == "moov") {
                val len = boxSize - headerLen
                if (len > MAX_MOOV) return null
                val moov = ByteBuffer.allocate(len.toInt()).order(ByteOrder.BIG_ENDIAN)
                readFully(ch, moov, pos + headerLen)
                moov.flip()
                val tracks = ArrayList<Track>()
                children(moov) { t, b -> if (t == "trak") parseTrak(b)?.let(tracks::add) }
                // 샘플이 목차에 없으면(조각난 MP4) 이 방식으로는 알 수 없다.
                if (tracks.none { it.handler == "vide" && it.sampleCount > 0 }) return null
                return Index(tracks)
            }
            pos += boxSize
        }
        return null
    }

    private fun readFully(ch: FileChannel, buf: ByteBuffer, at: Long) {
        var p = at
        while (buf.hasRemaining()) {
            val n = ch.read(buf, p)
            if (n < 0) throw java.io.EOFException()
            p += n
        }
    }

    private fun fourCC(v: Int): String =
        String(byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte()), Charsets.ISO_8859_1)

    /** [buf]의 남은 부분을 상자 목록으로 보고 하나씩 넘긴다(각 상자의 내용만 담은 조각). */
    private fun children(buf: ByteBuffer, visit: (String, ByteBuffer) -> Unit) {
        while (buf.remaining() >= 8) {
            val start = buf.position()
            var boxSize = buf.int.toLong() and 0xffffffffL
            val type = fourCC(buf.int)
            var headerLen = 8
            if (boxSize == 1L) {
                if (buf.remaining() < 8) return
                boxSize = buf.long
                headerLen = 16
            } else if (boxSize == 0L) {
                boxSize = (buf.limit() - start).toLong()
            }
            if (boxSize < headerLen || start + boxSize > buf.limit()) return
            val body = buf.duplicate().order(ByteOrder.BIG_ENDIAN)
            body.position(start + headerLen)
            body.limit((start + boxSize).toInt())
            visit(type, body.slice().order(ByteOrder.BIG_ENDIAN))
            buf.position((start + boxSize).toInt())
        }
    }

    private class Tables {
        var handler = ""
        var timescale = 0L
        var stts: ByteBuffer? = null
        var ctts: ByteBuffer? = null
        var stss: ByteBuffer? = null
        var stsz: ByteBuffer? = null
        var stz2: ByteBuffer? = null
    }

    private fun parseTrak(trak: ByteBuffer): Track? {
        val t = Tables()
        fun walk(b: ByteBuffer) {
            children(b) { type, body ->
                when (type) {
                    "mdia", "minf", "stbl" -> walk(body)
                    "mdhd" -> {
                        val version = body.get().toInt()
                        body.position(4)
                        body.position(body.position() + if (version == 1) 16 else 8)
                        t.timescale = body.int.toLong() and 0xffffffffL
                    }
                    // MOV 는 minf 안에도 자료 참조용 hdlr('alis' 등)이 있어 mdia 의 첫 hdlr 만 쓴다.
                    "hdlr" -> if (t.handler.isEmpty()) {
                        body.position(8)
                        t.handler = fourCC(body.int)
                    }
                    "stts" -> t.stts = body
                    "ctts" -> t.ctts = body
                    "stss" -> t.stss = body
                    "stsz" -> t.stsz = body
                    "stz2" -> t.stz2 = body
                }
            }
        }
        walk(trak)
        if (t.timescale <= 0 || (t.handler != "vide" && t.handler != "soun")) return null
        val sizes = t.stsz?.let(::sampleSizes) ?: t.stz2?.let(::compactSizes) ?: return null
        val n = sizes.size
        val stts = t.stts ?: return null

        // 디코딩 시각(stts) + 표시 오프셋(ctts) = 표시 시각.
        val pts = LongArray(n)
        stts.position(4)
        var i = 0
        var dts = 0L
        repeat(stts.int) {
            val count = stts.int.toLong() and 0xffffffffL
            val delta = stts.int.toLong() and 0xffffffffL
            var c = 0L
            while (c < count && i < n) {
                pts[i++] = dts
                dts += delta
                c++
            }
        }
        while (i < n) pts[i++] = dts
        t.ctts?.let { c ->
            val signed = c.get(0).toInt() == 1
            c.position(4)
            var j = 0
            repeat(c.int) {
                val count = c.int.toLong() and 0xffffffffL
                val raw = c.int
                val off = if (signed) raw.toLong() else raw.toLong() and 0xffffffffL
                var k = 0L
                while (k < count && j < n) {
                    pts[j++] += off
                    k++
                }
            }
        }
        val scale = t.timescale
        val ptsUs = LongArray(n) { pts[it] * 1_000_000L / scale }

        val sync = t.stss?.let { s ->
            s.position(4)
            val count = s.int
            IntArray(count) { s.int - 1 }.also { it.sort() }
        }
        return Track(t.handler, scale, ptsUs, sizes, sync)
    }

    private fun sampleSizes(b: ByteBuffer): IntArray {
        b.position(4)
        val fixed = b.int
        val count = b.int
        return if (fixed != 0) IntArray(count) { fixed } else IntArray(count) { b.int }
    }

    private fun compactSizes(b: ByteBuffer): IntArray {
        b.position(7)
        val field = b.get().toInt() and 0xff
        val count = b.int
        return when (field) {
            16 -> IntArray(count) { b.short.toInt() and 0xffff }
            8 -> IntArray(count) { b.get().toInt() and 0xff }
            4 -> IntArray(count) { k ->
                val byte = b.get(b.position() + k / 2).toInt() and 0xff
                if (k % 2 == 0) byte shr 4 else byte and 0x0f
            }
            else -> IntArray(0)
        }
    }
}
