import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Guarda audios y carátulas en el almacenamiento propio de la app para que
/// todo funcione sin conexión (modo avión) y no dependa de la caché.
class AppFiles {
  static Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// file_picker deja los audios en la caché, que Android puede vaciar.
  /// Si [path] está en la caché, lo mueve a la carpeta permanente y devuelve la nueva ruta.
  static Future<String> persistAudio(String path) async {
    final cache = await getTemporaryDirectory();
    if (!path.startsWith(cache.path)) return path;

    final source = File(path);
    if (!await source.exists()) return path;

    final dir = await _dir('sounds');
    final name = path.split(Platform.pathSeparator).last;
    var target = File('${dir.path}/$name');
    for (var i = 1; await target.exists(); i++) {
      target = File('${dir.path}/${i}_$name');
    }

    try {
      // Mismo sistema de ficheros: mover es instantáneo
      return (await source.rename(target.path)).path;
    } on FileSystemException {
      final copy = await source.copy(target.path);
      await source.delete();
      return copy.path;
    }
  }

  /// Descarga la carátula y devuelve la ruta local (o null si falla).
  static Future<String?> cacheCover(String identifier, String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      final dir = await _dir('covers');
      final ext = url.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final file = File('${dir.path}/$identifier.$ext');
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('Error al guardar carátula $identifier: $e');
      return null;
    }
  }
}
