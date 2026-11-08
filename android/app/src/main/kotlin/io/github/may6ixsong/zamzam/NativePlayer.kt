package io.github.may6ixsong.zamzam

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * 안드로이드 기본 재생기(MediaPlayer)로 하는 미리보기.
 *
 * 앱의 미리보기 재생기(video_player = ExoPlayer)가 어떤 파일(브라우저로 받은 일부 영상)을
 * 끝내 열지 못해, 그럴 때 이걸로 다시 연다. MediaPlayer 는 자르기에 쓰는 MediaExtractor 와
 * 같은 계열이라 그 파일을 읽을 수 있다. 화면은 Flutter 텍스처로 보낸다.
 *
 * Dart 쪽은 video_player 의 플랫폼 인터페이스 뒤에 붙어 있어(NativePlayerPlatform)
 * 자르기 화면은 같은 VideoPlayerController 로 쓴다.
 */
class NativePlayer(
    private val ctx: Context,
    private val textures: TextureRegistry,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private class Entry(val player: MediaPlayer, val producer: TextureRegistry.SurfaceProducer)

    private val main = Handler(Looper.getMainLooper())
    private val players = HashMap<Int, Entry>()
    private var nextId = 1

    init {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        channel.setMethodCallHandler(null)
        players.values.forEach { release(it) }
        players.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> result.success(create(call.argument<String>("uri")!!))
                "play" -> entry(call)?.player?.start().also { result.success(null) }
                "pause" -> entry(call)?.player?.let { if (it.isPlaying) it.pause() }.also { result.success(null) }
                "seekTo" -> {
                    val ms = (call.argument<Number>("ms") ?: 0).toLong()
                    entry(call)?.player?.seekTo(ms, MediaPlayer.SEEK_CLOSEST)
                    result.success(null)
                }
                "setVolume" -> {
                    val v = (call.argument<Number>("volume") ?: 1.0).toFloat()
                    entry(call)?.player?.setVolume(v, v)
                    result.success(null)
                }
                "setLooping" -> {
                    entry(call)?.player?.isLooping = call.argument<Boolean>("looping") == true
                    result.success(null)
                }
                "position" -> result.success(entry(call)?.player?.let { runCatching { it.currentPosition }.getOrNull() } ?: 0)
                "dispose" -> {
                    players.remove(call.argument<Int>("id"))?.let { release(it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun entry(call: MethodCall): Entry? = players[call.argument<Int>("id")]

    /** 재생기를 만들고 준비를 시작한다. 준비되면 'initialized' 이벤트를 보낸다. */
    private fun create(uri: String): Map<String, Any> {
        val id = nextId++
        val parsed = Uri.parse(uri)
        // 화면에 보이는 크기와 회전은 파일 정보에서 직접 읽는다.
        var width = 0
        var height = 0
        var rotation = 0
        runCatching {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(ctx, parsed)
                width = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                height = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            } finally {
                r.release()
            }
        }
        val producer = textures.createSurfaceProducer()
        if (width > 0 && height > 0) producer.setSize(width, height)
        val player = MediaPlayer()
        val entry = Entry(player, producer)
        players[id] = entry
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                runCatching { player.setSurface(producer.surface) }
            }

            override fun onSurfaceCleanup() {
                runCatching { player.setSurface(null) }
            }
        })
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
        )
        player.setDataSource(ctx, parsed)
        player.setSurface(producer.surface)
        player.setOnPreparedListener { mp ->
            // 텍스처가 회전을 처리하지 못하면 Dart 쪽에서 돌린다.
            val correction = if (producer.handlesCropAndRotation()) 0 else rotation
            val quarter = rotation % 180 != 0
            val w = if (width > 0) width else mp.videoWidth
            val h = if (height > 0) height else mp.videoHeight
            send(
                id, "initialized",
                mapOf(
                    "durationMs" to mp.duration.toLong(),
                    // 화면에 보이는 방향의 크기.
                    "width" to if (quarter) h else w,
                    "height" to if (quarter) w else h,
                    "rotation" to correction,
                ),
            )
            // 첫 화면이 바로 보이도록 처음 프레임으로 맞춰 둔다.
            runCatching { mp.seekTo(0, MediaPlayer.SEEK_CLOSEST) }
        }
        player.setOnCompletionListener { send(id, "completed", emptyMap()) }
        player.setOnErrorListener { _, what, extra ->
            send(id, "error", mapOf("message" to "MediaPlayer 오류 $what/$extra"))
            true
        }
        player.setOnInfoListener { _, what, _ ->
            when (what) {
                MediaPlayer.MEDIA_INFO_BUFFERING_START -> send(id, "bufferingStart", emptyMap())
                MediaPlayer.MEDIA_INFO_BUFFERING_END -> send(id, "bufferingEnd", emptyMap())
            }
            false
        }
        player.prepareAsync()
        return mapOf("id" to id, "textureId" to producer.id())
    }

    private fun send(id: Int, type: String, data: Map<String, Any>) {
        main.post { channel.invokeMethod("event", data + mapOf("id" to id, "type" to type)) }
    }

    private fun release(e: Entry) {
        runCatching { e.player.reset() }
        runCatching { e.player.release() }
        runCatching { e.producer.release() }
    }
}
