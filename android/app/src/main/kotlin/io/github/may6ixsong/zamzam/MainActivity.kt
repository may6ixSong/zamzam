package io.github.may6ixsong.zamzam

import android.app.Activity
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.result.IntentSenderRequest
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

class MainActivity : FlutterFragmentActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingFiles: MethodChannel.Result? = null
    private var pendingTrash: MethodChannel.Result? = null

    // 휴지통으로 옮기기: 안드로이드가 확인 창을 띄우고, 허락하면 옮긴다(30일 뒤 완전히 지워짐).
    private val trashLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        val result = pendingTrash ?: return@registerForActivityResult
        pendingTrash = null
        result.success(r.resultCode == Activity.RESULT_OK)
    }
    private var engine: MediaEngine? = null
    private var nativePlayer: NativePlayer? = null

    // 시스템 사진 선택기(권한 불필요). 실행 전에 등록해야 해서 필드로 둔다.
    private val pickOne = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        finishPick(listOfNotNull(uri))
    }
    private val pickMany = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_PICK)) { uris ->
        finishPick(uris)
    }

    // 웹 페이지의 <input type="file">
    private val openOne = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        finishFiles(listOfNotNull(uri))
    }
    private val openMany = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        finishFiles(uris)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zamzam/media")
        engine = MediaEngine(applicationContext, channel, ::startPick, ::startFilePick, ::startTrash) { id ->
            @Suppress("DEPRECATION")
            WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
        }
        nativePlayer = NativePlayer(
            applicationContext,
            flutterEngine.renderer,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zamzam/player"),
        )
    }

    override fun onDestroy() {
        engine?.shutdown()
        nativePlayer?.shutdown()
        super.onDestroy()
    }

    private fun startPick(multiple: Boolean, result: MethodChannel.Result) {
        pendingPick?.success(emptyList<String>())
        pendingPick = result
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
        if (multiple) pickMany.launch(request) else pickOne.launch(request)
    }

    private fun finishPick(uris: List<Uri>) {
        val r = pendingPick ?: return
        pendingPick = null
        r.success(uris.map { it.toString() })
    }

    private fun startTrash(uris: List<Uri>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("UNSUPPORTED", "안드로이드 11 이상에서만 휴지통으로 옮길 수 있어요", null)
            return
        }
        try {
            val request = MediaStore.createTrashRequest(contentResolver, uris, true)
            pendingTrash?.success(false)
            pendingTrash = result
            trashLauncher.launch(IntentSenderRequest.Builder(request.intentSender).build())
        } catch (e: Exception) {
            pendingTrash = null
            result.error("FAILED", e.message ?: "휴지통으로 옮기지 못했어요", null)
        }
    }

    private fun startFilePick(accept: List<String>, multiple: Boolean, result: MethodChannel.Result) {
        pendingFiles?.success(emptyList<String>())
        pendingFiles = result
        val types = accept.flatMap { it.split(',') }.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.map { t ->
            if (t.startsWith(".")) MimeTypeMap.getSingleton().getMimeTypeFromExtension(t.substring(1)) ?: "*/*" else t
        }.distinct().ifEmpty { listOf("*/*") }.toTypedArray()
        try {
            if (multiple) openMany.launch(types) else openOne.launch(types)
        } catch (e: Exception) {
            finishFiles(emptyList())
        }
    }

    private fun finishFiles(uris: List<Uri>) {
        val r = pendingFiles ?: return
        pendingFiles = null
        r.success(uris.map { it.toString() })
    }

    companion object {
        private const val MAX_PICK = 30
    }
}
