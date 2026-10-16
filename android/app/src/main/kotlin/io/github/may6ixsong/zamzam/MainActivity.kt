package io.github.may6ixsong.zamzam

import android.net.Uri
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var engine: MediaEngine? = null

    // 시스템 사진 선택기(권한 불필요). 실행 전에 등록해야 해서 필드로 둔다.
    private val pickOne = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        finishPick(listOfNotNull(uri))
    }
    private val pickMany = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_PICK)) { uris ->
        finishPick(uris)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zamzam/media")
        engine = MediaEngine(applicationContext, channel, ::startPick)
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

    companion object {
        private const val MAX_PICK = 30
    }
}
