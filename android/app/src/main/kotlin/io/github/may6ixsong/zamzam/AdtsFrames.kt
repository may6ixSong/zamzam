package io.github.may6ixsong.zamzam

/**
 * ADTS(AAC 프레임마다 붙는 7·9바이트 머리표) 묶음을 MP4 용 AAC 프레임으로 나눈다.
 *
 * 스트리밍(TS) 영상의 음성은 'ADTS 머리표 + AAC 프레임'이 여러 개(보통 5~10개) 한 덩어리로 온다.
 * 이걸 MP4 에 한 샘플로 그대로 넣으면 재생기가 첫 머리표를 소리 데이터로 읽어 소리가 나지 않는다.
 * MP4 의 AAC 샘플은 머리표 없는 프레임 하나씩이어야 한다.
 */
object AdtsFrames {
    private val RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)

    /** 머리표에서 읽은 정보. */
    class Header(val profile: Int, val rateIndex: Int, val channels: Int, val headerSize: Int, val frameLength: Int) {
        val sampleRate get() = RATES.getOrElse(rateIndex) { 0 }
    }

    fun isAdts(d: ByteArray, off: Int = 0, len: Int = d.size): Boolean =
        len - off >= 7 && (d[off].toInt() and 0xff) == 0xff && (d[off + 1].toInt() and 0xf6) == 0xf0

    fun header(d: ByteArray, off: Int): Header? {
        if (!isAdts(d, off, d.size)) return null
        val b1 = d[off + 1].toInt() and 0xff
        val b2 = d[off + 2].toInt() and 0xff
        val b3 = d[off + 3].toInt() and 0xff
        val b4 = d[off + 4].toInt() and 0xff
        val b5 = d[off + 5].toInt() and 0xff
        val protectionAbsent = b1 and 1
        val profile = (b2 shr 6) and 3
        val rateIndex = (b2 shr 2) and 0xf
        val channels = ((b2 and 1) shl 2) or ((b3 shr 6) and 3)
        val frameLength = ((b3 and 3) shl 11) or (b4 shl 3) or (b5 shr 5)
        val headerSize = if (protectionAbsent == 1) 7 else 9
        if (rateIndex >= RATES.size || frameLength < headerSize) return null
        return Header(profile, rateIndex, channels, headerSize, frameLength)
    }

    /**
     * [d]의 앞 [len]바이트가 ADTS 프레임들로 꼭 맞게 이어져 있으면, 머리표를 뺀 각 프레임의 (시작, 길이) 목록.
     * ADTS 가 아니거나 중간에 어긋나면 null(그대로 쓴다).
     */
    fun split(d: ByteArray, len: Int): List<Pair<Int, Int>>? {
        if (!isAdts(d, 0, len)) return null
        val out = ArrayList<Pair<Int, Int>>()
        var p = 0
        while (p < len) {
            val h = header(d, p) ?: return null
            if (p + h.frameLength > len) return null
            out += (p + h.headerSize) to (h.frameLength - h.headerSize)
            p += h.frameLength
        }
        return out
    }

    /** MP4 의 esds 에 들어가는 AudioSpecificConfig(2바이트) — 머리표에서 만든다. */
    fun audioSpecificConfig(h: Header): ByteArray {
        val objectType = h.profile + 1
        return byteArrayOf(
            ((objectType shl 3) or (h.rateIndex shr 1)).toByte(),
            (((h.rateIndex and 1) shl 7) or (h.channels shl 3)).toByte(),
        )
    }
}
