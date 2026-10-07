import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Resultado de traducir un porcentaje de preset al volumen del móvil.
typedef VolumeLevel = ({int index, double gain, int max});

/// Traduce un porcentaje de preset (0–1) a un paso del volumen multimedia y una ganancia del reproductor.
///
/// El móvil solo tiene `max` pasos (25 en el Pixel). Para afinar al 1 %, el volumen se sitúa entre dos
/// pasos: se fija el paso superior y el reproductor baja la ganancia hasta la amplitud intermedia.
/// Los valores de la cuadrícula antigua (múltiplos de 5 %) dan exactamente el paso de siempre y ganancia 1,
/// así que los presets guardados suenan igual que antes.
class VolumeCurve {
  /// Paso que usaban las versiones anteriores: round(v·max), con mínimo 1 si v > 0.
  static int legacyIndex(int permille, int max) {
    if (permille <= 0) return 0;
    final index = (permille * max * 2 + 1000) ~/ 2000; // redondeo hacia arriba en .5, sin errores de coma flotante
    return index < 1 ? 1 : (index > max ? max : index);
  }

  /// [amps]: amplitud relativa de cada paso (0..max) en la salida actual, o null si el móvil no la da.
  static VolumeLevel resolve(double volume, int max, [List<double>? amps]) {
    final permille = (volume.clamp(0.0, 1.0) * 1000).round();
    // Índice fraccionario: interpolación entre los puntos de la cuadrícula del 5 %
    final k = permille >= 1000 ? 19 : permille ~/ 50;
    final rem = permille - k * 50;
    final y0 = legacyIndex(k * 50, max);
    final y1 = legacyIndex((k + 1) * 50, max);
    final fi = y0 + (y1 - y0) * rem / 50;

    final hi = fi.ceil();
    if (hi == fi || hi <= 0) return (index: hi, gain: 1.0, max: max);
    final lo = hi - 1;
    final t = fi - lo;

    final valid = amps != null && amps.length > hi && amps[hi] > 0 && amps[hi] > amps[lo];
    final aLo = valid ? amps[lo] : lo / max;
    final aHi = valid ? amps[hi] : hi / max;
    final gain = (aLo + (aHi - aLo) * t) / aHi;
    return (index: hi, gain: gain.clamp(0.0, 1.0), max: max);
  }

  /// Amplitud de salida relativa (0–1) de un porcentaje: amplitud del paso × ganancia.
  static double amplitude(double volume, int max, [List<double>? amps]) {
    final level = resolve(volume, max, amps);
    return _stepAmp(level.index, max, amps) * level.gain;
  }

  /// Paso y ganancia que dan la amplitud [target] (el menor porcentaje, con precisión de 0,1 %, que la alcanza).
  /// Limitado al 100 % del móvil.
  static VolumeLevel forAmplitude(double target, int max, [List<double>? amps]) {
    for (var p = 0; p <= 1000; p++) {
      if (amplitude(p / 1000, max, amps) >= target - 1e-9) return resolve(p / 1000, max, amps);
    }
    return resolve(1.0, max, amps);
  }

  /// [volume] con un ajuste de [offsetDb] dB, como paso del sistema + ganancia.
  static VolumeLevel withOffset(double volume, double offsetDb, int max, [List<double>? amps]) {
    if (offsetDb == 0) return resolve(volume, max, amps);
    final target = amplitude(volume, max, amps) * math.pow(10, offsetDb / 20);
    return forAmplitude(target.toDouble(), max, amps);
  }

  static double _stepAmp(int index, int max, List<double>? amps) {
    if (index <= 0) return 0;
    final valid = amps != null && amps.length > max && amps[max] > 0;
    return valid ? amps[index] : index / max;
  }
}

/// Controla el volumen multimedia del dispositivo (el mismo que los botones físicos).
class DeviceVolume {
  static const MethodChannel _channel = MethodChannel('soundlife/volume');

  /// Paso del sistema y ganancia para [volume] en la salida de audio actual.
  static Future<VolumeLevel> resolve(double volume) async {
    try {
      final levels = await _channel.invokeMapMethod<String, dynamic>('getLevels');
      final max = levels?['max'] as int? ?? 25;
      final amps = (levels?['amps'] as List?)?.map((e) => (e as num).toDouble()).toList();
      return VolumeCurve.resolve(volume, max, amps);
    } on MissingPluginException {
      return VolumeCurve.resolve(volume, 25);
    } on PlatformException catch (e) {
      debugPrint('Error al leer niveles de volumen: $e');
      return VolumeCurve.resolve(volume, 25);
    }
  }

  /// Fija el volumen para [volume] (0.0 silencio, 1.0 máximo), con un ajuste opcional de [offsetDb] dB
  /// (normalización de colas), y devuelve la ganancia que debe aplicar el reproductor.
  static Future<double> set(double volume, {double offsetDb = 0}) async {
    final level = offsetDb == 0 ? await resolve(volume) : await _withOffset(volume, offsetDb);
    try {
      await _channel.invokeMethod('setIndex', {'index': level.index});
    } on MissingPluginException {
      // Plataforma sin canal nativo (no Android)
    } on PlatformException catch (e) {
      debugPrint('Error al fijar volumen: $e');
    }
    return level.gain;
  }

  static Future<VolumeLevel> _withOffset(double volume, double offsetDb) async {
    try {
      final levels = await _channel.invokeMapMethod<String, dynamic>('getLevels');
      final max = levels?['max'] as int? ?? 25;
      final amps = (levels?['amps'] as List?)?.map((e) => (e as num).toDouble()).toList();
      return VolumeCurve.withOffset(volume, offsetDb, max, amps);
    } catch (_) {
      return VolumeCurve.withOffset(volume, offsetDb, 25);
    }
  }

  /// Sonoridad integrada (LUFS, EBU R128) de un audio, o null si no se puede medir.
  static Future<double?> measureLoudness(String path) async {
    try {
      return await _channel.invokeMethod<double>('measureLoudness', {'path': path});
    } catch (e) {
      debugPrint('Error al medir sonoridad: $e');
      return null;
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
