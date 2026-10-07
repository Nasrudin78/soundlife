class SoundItem {
  String filePath;
  final String fileName;
  final String identifier; // e.g. "BA01"
  String? title; // nombre del producto en soundandlife.com
  String? coverUrl;
  String? coverPath; // copia local de la carátula (para modo avión)
  String? productUrl; // ficha en soundandlife.com
  String? detailsPath; // copia local de la ficha (descripción, aplicaciones, posología)
  double? loudness; // sonoridad integrada en LUFS (EBU R128), para normalizar colas
  double volumePreset;
  bool loopMode;

  SoundItem({
    required this.filePath,
    required this.fileName,
    required this.identifier,
    this.title,
    this.coverUrl,
    this.coverPath,
    this.productUrl,
    this.detailsPath,
    this.loudness,
    this.volumePreset = 0.1,
    this.loopMode = false,
  });

  /// Nombre de la web si se encontró; si no, el nombre del fichero sin extensión.
  String get displayName => title != null ? _lowercaseTitle(title!) : fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

  /// "BA07 Rescate – Ansiedad" → "BA07 rescate – ansiedad": todo en minúsculas salvo el código BAxx.
  static String _lowercaseTitle(String title) => title
      .toLowerCase()
      .replaceAllMapped(RegExp(r'\bba(\d+)'), (m) => 'BA${m.group(1)}');

  Map<String, dynamic> toJson() {
    return {
      'filePath': filePath,
      'fileName': fileName,
      'identifier': identifier,
      'title': title,
      'coverUrl': coverUrl,
      'coverPath': coverPath,
      'productUrl': productUrl,
      'detailsPath': detailsPath,
      'loudness': loudness == null ? null : (loudness!.isNaN ? 'nan' : loudness),
      'volumePreset': volumePreset,
      'loopMode': loopMode,
    };
  }

  factory SoundItem.fromJson(Map<String, dynamic> json) {
    return SoundItem(
      filePath: json['filePath'],
      fileName: json['fileName'],
      identifier: json['identifier'],
      title: json['title'],
      coverUrl: json['coverUrl'],
      coverPath: json['coverPath'],
      productUrl: json['productUrl'],
      detailsPath: json['detailsPath'],
      loudness: json['loudness'] == 'nan' ? double.nan : (json['loudness'] as num?)?.toDouble(),
      volumePreset: json['volumePreset']?.toDouble() ?? 0.1,
      loopMode: json['loopMode'] ?? false,
    );
  }
}

/// Un paso de una cola: un sonido repetido [repeats] veces (0 = en bucle para siempre).
class QueueStep {
  final String fileName; // referencia estable al SoundItem
  int repeats;

  QueueStep({required this.fileName, this.repeats = 1});

  bool get isInfinite => repeats == 0;

  Map<String, dynamic> toJson() => {'fileName': fileName, 'repeats': repeats};

  factory QueueStep.fromJson(Map<String, dynamic> json) =>
      QueueStep(fileName: json['fileName'], repeats: json['repeats'] ?? 1);
}

class SoundQueue {
  final String id;
  String name;
  List<QueueStep> steps;
  // Normalizar: todos los pasos igual de fuertes a un volumen único de cola (sin usar los presets)
  bool normalize;
  double? volume;

  SoundQueue({required this.id, required this.name, List<QueueStep>? steps, this.normalize = false, this.volume})
      : steps = steps ?? [];

  /// Diferencia máxima que se corrige, en dB.
  static const double maxOffsetDb = 20;

  /// Ajuste en dB de [sound] respecto a la referencia (el primer paso), o null si falta medir alguno.
  double? offsetDb(SoundItem sound, double? referenceLufs) {
    final l = sound.loudness;
    if (l == null || referenceLufs == null || l.isNaN || referenceLufs.isNaN) return null;
    return (referenceLufs - l).clamp(-maxOffsetDb, maxOffsetDb).toDouble();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'normalize': normalize,
        if (volume != null) 'volume': volume,
      };

  factory SoundQueue.fromJson(Map<String, dynamic> json) => SoundQueue(
        id: json['id'],
        name: json['name'],
        steps: (json['steps'] as List? ?? [])
            .map((s) => QueueStep.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
        normalize: json['normalize'] ?? false,
        volume: (json['volume'] as num?)?.toDouble(),
      );
}
