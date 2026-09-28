class SoundItem {
  String filePath;
  final String fileName;
  final String identifier; // e.g. "BA01"
  String? title; // nombre del producto en soundandlife.com
  String? coverUrl;
  String? coverPath; // copia local de la carátula (para modo avión)
  double volumePreset;
  bool loopMode;

  SoundItem({
    required this.filePath,
    required this.fileName,
    required this.identifier,
    this.title,
    this.coverUrl,
    this.coverPath,
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

  SoundQueue({required this.id, required this.name, List<QueueStep>? steps}) : steps = steps ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory SoundQueue.fromJson(Map<String, dynamic> json) => SoundQueue(
        id: json['id'],
        name: json['name'],
        steps: (json['steps'] as List? ?? [])
            .map((s) => QueueStep.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
      );
}
