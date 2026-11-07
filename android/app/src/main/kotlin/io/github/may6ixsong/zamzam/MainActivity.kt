package io.github.may6ixsong.zamzam

import android.net.Uri
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
    private var engine: MediaEngine? = null

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
        engine = MediaEngine(applicationContext, channel, ::startPick, ::startFilePick) { id ->
            @Suppress("DEPRECATION")
            WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
        }
    }

    override fun onDestroy() {
        engine?.shutdown()
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
