package io.github.may6ixsong.zamzam

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/**
 * 해상도를 낮춰 다시 압축한다(용량 줄이기). 폰의 하드웨어 인코더(H.264)를 쓴다.
 * 음성은 바꾸지 않고 그대로 옮긴다.
 */
@OptIn(UnstableApi::class)
class Transcoder(private val ctx: Context, private val main: Handler) {

    class Plan(val width: Int, val height: Int, val bitrate: Int)

    class Cancelled : IOException("취소했어요")

    companion object {
        /** 짧은 변 기준 목표 영상 비트레이트(bps). */
        private val BITRATE = mapOf(1080 to 5_000_000, 720 to 2_500_000, 480 to 1_200_000, 360 to 700_000)

        fun targetBitrate(shortSide: Int): Int {
            val nearest = BITRATE.entries.minBy { kotlin.math.abs(it.key - shortSide) }
            return (nearest.value.toLong() * shortSide / nearest.key).toInt()
        }

        /**
         * 화면에 보이는 방향 기준으로 짧은 변을 [shortSide]로 줄인 크기와 비트레이트.
         * 이미 그보다 작으면 null(변환할 필요 없음).
         */
        fun plan(width: Int, height: Int, rotation: Int, sourceBitrate: Int?, shortSide: Int): Plan? {
            if (width <= 0 || height <= 0) return null
            val (dw, dh) = if (rotation % 180 != 0) height to width else width to height
            val short = minOf(dw, dh)
            if (shortSide >= short) return null
            val scale = shortSide.toDouble() / short
            fun even(v: Double) = ((v / 2).roundToInt() * 2).coerceAtLeast(2)
            val w = even(dw * scale)
            val h = even(dh * scale)
            var bitrate = targetBitrate(shortSide)
            // 원본이 이미 낮은 비트레이트면 그 비율만큼만(괜히 커지지 않게).
            if (sourceBitrate != null && sourceBitrate > 0) {
                val scaled = (sourceBitrate * scale * scale * 1.1).toInt()
                bitrate = minOf(bitrate, scaled.coerceAtLeast(300_000))
            }
            return Plan(w, h, bitrate)
        }

        fun planFor(file: File, shortSide: Int): Plan? = planFrom(shortSide) { it.setDataSource(file.path) }

        fun planFor(ctx: Context, uri: Uri, shortSide: Int): Plan? = planFrom(shortSide) { it.setDataSource(ctx, uri) }

        private fun planFrom(shortSide: Int, open: (MediaMetadataRetriever) -> Unit): Plan? {
            val r = MediaMetadataRetriever()
            try {
                open(r)
                fun meta(k: Int) = r.extractMetadata(k)?.toIntOrNull()
                val bitrate = meta(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.let { (it - 128_000).coerceAtLeast(it / 2) }
                return plan(
                    meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) ?: 0,
                    meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) ?: 0,
                    meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0,
                    bitrate,
                    shortSide,
                )
            } finally {
                r.release()
            }
        }
    }

    /**
     * [input]을 [plan] 크기로 변환해 [output]에 쓴다. 다 끝날 때까지 기다린다(메인 스레드에서 부르면 안 된다).
     * [onProgress]는 0~100.
     */
    fun run(input: Uri, output: File, plan: Plan, cancel: AtomicBoolean, onProgress: (Int) -> Unit) {
        val done = CountDownLatch(1)
        var error: Exception? = null
        var transformer: Transformer? = null
        val holder = ProgressHolder()
        var lastPct = -1

        lateinit var poll: Runnable
        poll = Runnable {
            val t = transformer ?: return@Runnable
            if (done.count == 0L) return@Runnable
            if (cancel.get()) {
                t.cancel()
                error = Cancelled()
                done.countDown()
                return@Runnable
            }
            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE && holder.progress != lastPct) {
                lastPct = holder.progress
                onProgress(holder.progress)
            }
            main.postDelayed(poll, 300)
        }

        // Transformer 는 만든 스레드(루퍼)에서만 다룰 수 있어 메인 스레드에서 돌린다.
        main.post {
            try {
                val encoder = DefaultEncoderFactory.Builder(ctx)
                    .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(plan.bitrate).build())
                    .build()
                val t = Transformer.Builder(ctx)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setEncoderFactory(encoder)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            done.countDown()
                        }

                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            error = IOException("변환하지 못했어요: ${exportException.errorCodeName}", exportException)
                            done.countDown()
                        }
                    })
                    .build()
                val item = EditedMediaItem.Builder(MediaItem.fromUri(input))
                    .setEffects(
                        Effects(
                            emptyList(),
                            listOf(Presentation.createForWidthAndHeight(plan.width, plan.height, Presentation.LAYOUT_SCALE_TO_FIT)),
                        )
                    )
                    .build()
                transformer = t
                t.start(item, output.path)
                main.postDelayed(poll, 300)
            } catch (e: Exception) {
                error = IOException("변환을 시작하지 못했어요: ${e.message}", e)
                done.countDown()
            }
        }
        done.await()
        error?.let {
            output.delete()
            throw it
        }
        onProgress(100)
    }
}
