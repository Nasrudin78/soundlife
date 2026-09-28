package com.example.soundlife

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Servicio en primer plano mientras se envía audio a un dispositivo DLNA.
 * Mantiene viva la app (servidor HTTP y avance de la cola) y el WiFi con la pantalla apagada,
 * porque en ese momento el reproductor local no suena y su propio servicio se detiene.
 */
class CastService : Service() {
    companion object {
        const val ACTION_STOP = "com.example.soundlife.cast.STOP"
        const val EXTRA_NAME = "name"
        private const val CHANNEL_ID = "com.example.soundlife.channel.cast"
        private const val NOTIFICATION_ID = 4711

        /** Pulsado "Detener" en la notificación. */
        var onStopRequested: (() -> Unit)? = null
    }

    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            onStopRequested?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }

        val name = intent?.getStringExtra(EXTRA_NAME) ?: "otro dispositivo"
        val notification = buildNotification(name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "soundlife:cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "soundlife:cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun buildNotification(name: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Enviar a otros dispositivos", NotificationManager.IMPORTANCE_LOW)
            )
        }

        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, CastService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle("Enviando a $name")
            .setContentText("SoundLife")
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Detener", stop).build())
            .build()
    }
}
