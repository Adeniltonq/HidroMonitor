package br.app.hidromonitor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Expõe o Web Client ID gerado pelo google-services.json
        // (recurso default_web_client_id) para o login nativo do Google.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hidromonitor/config"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getWebClientId") {
                val resId = resources.getIdentifier(
                    "default_web_client_id", "string", packageName
                )
                result.success(if (resId != 0) getString(resId) else null)
            } else {
                result.notImplemented()
            }
        }
    }
}
