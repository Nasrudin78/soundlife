package com.example.soundlife

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
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

        configureCastChannel(flutterEngine)
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    private fun configureCastChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "soundlife/cast")
        val mainHandler = Handler(Looper.getMainLooper())
        CastService.onStopRequested = {
            mainHandler.post { channel.invokeMethod("stopRequested", null) }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Sin este lock Android descarta los paquetes multicast (búsqueda SSDP)
                "multicastLock" -> {
                    if (call.argument<Boolean>("acquire") == true) {
                        if (multicastLock == null) {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("soundlife:ssdp").apply {
                                setReferenceCounted(false)
                            }
                        }
                        multicastLock?.acquire()
                    } else {
                        multicastLock?.takeIf { it.isHeld }?.release()
                    }
                    result.success(null)
                }
                "startService" -> {
                    val intent = Intent(this, CastService::class.java)
                        .putExtra(CastService.EXTRA_NAME, call.argument<String>("name"))
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(null)
                }
                "stopService" -> {
                    stopService(Intent(this, CastService::class.java))
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
