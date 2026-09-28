package com.example.soundlife

import android.content.Context
import android.media.AudioManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

// AudioServiceActivity comparte el motor de Flutter con el servicio de audio en segundo plano
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val audioManager = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soundlife/volume")
            .setMethodCallHandler { call, result ->
                val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                when (call.method) {
                    // Igual que el botón físico: 0.0 = silencio, 1.0 = máximo del dispositivo
                    "setVolume" -> {
                        val percent = (call.argument<Double>("volume") ?: 0.0).coerceIn(0.0, 1.0)
                        var index = (percent * max).roundToInt()
                        if (percent > 0.0 && index == 0) index = 1
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
                        result.success(null)
                    }
                    "getVolume" -> {
                        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        result.success(if (max > 0) current.toDouble() / max else 0.0)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
