import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Controla el volumen multimedia del dispositivo (el mismo que los botones físicos).
class DeviceVolume {
  static const MethodChannel _channel = MethodChannel('soundlife/volume');

  /// [volume] de 0.0 (silencio) a 1.0 (máximo del dispositivo).
  static Future<void> set(double volume) async {
    try {
      await _channel.invokeMethod('setVolume', {'volume': volume.clamp(0.0, 1.0)});
    } on MissingPluginException {
      // Plataforma sin canal nativo (no Android)
    } on PlatformException catch (e) {
      debugPrint('Error al fijar volumen: $e');
    }
  }

  static Future<double?> get() async {
    try {
      return await _channel.invokeMethod<double>('getVolume');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
