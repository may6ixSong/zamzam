package io.github.may6ixsong.zamzam

/**
 * H.264/HEVC 프레임 데이터를 직접 읽어 키프레임(여기서부터 디코딩을 시작할 수 있는 프레임)인지 판단한다.
 *
 * 스트리밍(TS) 영상을 MP4 로 옮길 때 MediaExtractor 가 주는 키프레임 표시가 빠지거나 모든 프레임에 붙는 일이 있어,
 * 그대로 쓰면 재생은 되지만 자르기(키프레임에서 시작)가 안 되는 파일이 된다.
 * 데이터는 Annex-B(00 00 01 시작 코드)와 길이 접두(4바이트) 형식을 모두 받는다.
 */
object NalKeyframes {
    /** 키프레임 아님. */
    const val NONE = 0

    /** I 슬라이스지만 IDR 은 아님(앞 프레임을 참조할 수 있어 IDR 이 없을 때만 쓴다). */
    const val INTRA = 1

    /** IDR(H.264) 또는 IRAP(HEVC), 또는 복구 지점 표시가 있는 I 프레임. */
    const val KEY = 2

    fun isSupported(mime: String) = mime == "video/avc" || mime == "video/hevc"

    fun classify(mime: String, data: ByteArray, len: Int = data.size): Int {
        val hevc = mime == "video/hevc"
        var level = NONE
        var intra = false
        var recovery = false
        forEachNal(data, len) { start, end ->
            if (start >= end) return@forEachNal
            val b = data[start].toInt() and 0xff
            if (hevc) {
                val type = (b shr 1) and 0x3f
                if (type in 16..23) level = KEY
            } else {
                when (b and 0x1f) {
                    5 -> level = KEY
                    1 -> if (sliceIsIntra(data, start + 1, end)) intra = true
                    6 -> if (seiHasRecoveryPoint(data, start + 1, end)) recovery = true
                }
            }
        }
        if (level == KEY) return KEY
        if (intra) return if (recovery) KEY else INTRA
        return NONE
    }

    /** 데이터 안의 NAL 단위마다 [visit](시작, 끝)을 부른다(시작은 NAL 헤더 바이트). */
    fun forEachNal(d: ByteArray, len: Int, visit: (Int, Int) -> Unit) {
        if (len >= 3 && d[0].toInt() == 0 && d[1].toInt() == 0 &&
            (d[2].toInt() == 1 || (len >= 4 && d[2].toInt() == 0 && d[3].toInt() == 1))
        ) {
            annexB(d, len, visit)
            return
        }
        // 길이 접두 형식인지 확인하고, 맞지 않으면 Annex-B 로 다시 본다.
        var p = 0
        val nals = ArrayList<Pair<Int, Int>>()
        while (p + 4 <= len) {
            val n = ((d[p].toInt() and 0xff) shl 24) or ((d[p + 1].toInt() and 0xff) shl 16) or
                ((d[p + 2].toInt() and 0xff) shl 8) or (d[p + 3].toInt() and 0xff)
            if (n <= 0 || p + 4 + n > len) {
                annexB(d, len, visit)
                return
            }
            nals += (p + 4) to (p + 4 + n)
            p += 4 + n
        }
        nals.forEach { (s, e) -> visit(s, e) }
    }

    private fun annexB(d: ByteArray, len: Int, visit: (Int, Int) -> Unit) {
        var i = 0
        var start = -1
        while (i + 2 < len) {
            if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 && d[i + 2].toInt() == 1) {
                if (start >= 0) {
                    var end = i
                    while (end > start && d[end - 1].toInt() == 0) end--
                    visit(start, end)
                }
                start = i + 3
                i += 3
            } else {
                i++
            }
        }
        if (start in 0 until len) visit(start, len)
    }

    /** 에뮬레이션 방지 바이트(00 00 03)를 걷어 낸 앞부분(최대 [max]바이트). */
    private fun rbsp(d: ByteArray, from: Int, to: Int, max: Int = 64): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var zeros = 0
        var i = from
        while (i < to && out.size() < max) {
            val b = d[i].toInt() and 0xff
            if (zeros >= 2 && b == 3) {
                zeros = 0
                i++
                continue
            }
            out.write(b)
            zeros = if (b == 0) zeros + 1 else 0
            i++
        }
        return out.toByteArray()
    }

    private class Bits(val b: ByteArray) {
        var pos = 0
        fun bit(): Int {
            if (pos >= b.size * 8) throw IndexOutOfBoundsException()
            val v = (b[pos / 8].toInt() shr (7 - pos % 8)) and 1
            pos++
            return v
        }

        fun ue(): Int {
            var zeros = 0
            while (bit() == 0) if (++zeros > 31) throw IllegalStateException()
            var v = 0
            repeat(zeros) { v = (v shl 1) or bit() }
            return (1 shl zeros) - 1 + v
        }
    }

    /** 슬라이스 헤더의 slice_type 이 I(2, 7) 또는 SI(4, 9)인지. */
    private fun sliceIsIntra(d: ByteArray, from: Int, to: Int): Boolean = runCatching {
        val bits = Bits(rbsp(d, from, to, 16))
        bits.ue() // first_mb_in_slice
        val t = bits.ue() % 5
        t == 2 || t == 4
    }.getOrDefault(false)

    /** SEI 안에 recovery_point(payloadType 6)가 있는지. */
    private fun seiHasRecoveryPoint(d: ByteArray, from: Int, to: Int): Boolean {
        val r = rbsp(d, from, to, 4096)
        var p = 0
        while (p < r.size) {
            var type = 0
            while (p < r.size && (r[p].toInt() and 0xff) == 0xff) {
                type += 255
                p++
            }
            if (p >= r.size) return false
            type += r[p++].toInt() and 0xff
            var size = 0
            while (p < r.size && (r[p].toInt() and 0xff) == 0xff) {
                size += 255
                p++
            }
            if (p >= r.size) return false
            size += r[p++].toInt() and 0xff
            if (type == 6) return true
            p += size
            // rbsp_trailing_bits(0x80) 에 닿으면 끝.
            if (p < r.size && (r[p].toInt() and 0xff) == 0x80) return false
        }
        return false
    }
}
