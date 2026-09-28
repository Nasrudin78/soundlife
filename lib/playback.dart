import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'models.dart';
import 'volume.dart';

/// Una entrada de la lista que se entrega al reproductor nativo.
class _Entry {
  final SoundItem sound;
  final int stepIndex;
  final int repetition; // 1-based
  final int repeats; // 0 = infinito
  _Entry(this.sound, this.stepIndex, this.repetition, this.repeats);
}

/// Reproductor único de la app (sonido suelto o cola), con servicio en primer plano
/// para seguir sonando con la pantalla apagada.
///
/// Las colas se entregan enteras a just_audio: el paso de un audio al siguiente lo hace
/// el reproductor nativo sin cortes. Un paso con N repeticiones son N entradas seguidas;
/// el último paso infinito es una entrada que se pone en LoopMode.one al llegar a ella.
class PlaybackController extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  List<_Entry> _entries = [];
  SoundQueue? _queue;
  int? _index;
  bool _paused = false;

  PlaybackController() {
    _subs.add(_player.currentIndexStream.listen(_onIndexChanged));
    _subs.add(_player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _clear();
        return;
      }
      final paused = !state.playing && _entries.isNotEmpty;
      if (paused != _paused) {
        _paused = paused;
        notifyListeners();
      }
    }));
  }

  SoundItem? get currentSound => _index != null && _index! < _entries.length ? _entries[_index!].sound : null;
  bool get isActive => currentSound != null;
  bool get isPaused => _paused;
  SoundQueue? get queue => _queue;
  bool get hasNext => _queue != null && _index != null && _nextStepStart(_index!) != null;

  /// "Paso 2/4 · 1/2" para colas, null para sonidos sueltos.
  String? get progressLabel {
    final q = _queue;
    final i = _index;
    if (q == null || i == null || i >= _entries.length) return null;
    final e = _entries[i];
    final rep = e.repeats == 0 ? '∞' : '${e.repetition}/${e.repeats}';
    return 'Paso ${e.stepIndex + 1}/${q.steps.length} · $rep';
  }

  bool isCurrent(SoundItem sound) => currentSound?.filePath == sound.filePath;

  MediaItem _mediaItem(SoundItem sound, String id, {String? album}) => MediaItem(
        id: id,
        title: sound.displayName,
        album: album ?? 'SoundLife',
        artUri: sound.coverPath != null && File(sound.coverPath!).existsSync()
            ? Uri.file(sound.coverPath!)
            : (sound.coverUrl != null ? Uri.parse(sound.coverUrl!) : null),
      );

  Future<void> playSound(SoundItem sound) async {
    await _load(
      [_Entry(sound, 0, 1, sound.loopMode ? 0 : 1)],
      [AudioSource.file(sound.filePath, tag: _mediaItem(sound, sound.filePath))],
      queue: null,
    );
  }

  /// [sounds] resuelve cada paso por nombre de fichero; los pasos sin sonido se saltan.
  Future<void> playQueue(SoundQueue queue, Map<String, SoundItem> sounds) async {
    final entries = <_Entry>[];
    final sources = <AudioSource>[];
    for (var s = 0; s < queue.steps.length; s++) {
      final step = queue.steps[s];
      final sound = sounds[step.fileName];
      if (sound == null || !File(sound.filePath).existsSync()) continue;
      // Solo el último paso puede ser infinito; en otro sitio cuenta como 1
      final isLast = s == queue.steps.length - 1;
      final repeats = step.isInfinite && !isLast ? 1 : step.repeats;
      final copies = repeats == 0 ? 1 : repeats;
      for (var r = 1; r <= copies; r++) {
        entries.add(_Entry(sound, s, r, repeats));
        sources.add(AudioSource.file(
          sound.filePath,
          tag: _mediaItem(sound, '${queue.id}/$s/$r', album: queue.name),
        ));
      }
    }
    if (entries.isEmpty) return;
    await _load(entries, sources, queue: queue);
  }

  Future<void> _load(List<_Entry> entries, List<AudioSource> sources, {required SoundQueue? queue}) async {
    await _player.stop();
    _entries = entries;
    _queue = queue;
    _index = null;
    _paused = false;
    await _player.setLoopMode(LoopMode.off);
    await _player.setAudioSources(sources, initialIndex: 0);
    await _onIndexChanged(0);
    notifyListeners();
    // play() no termina hasta que se pausa, así que no se espera
    unawaited(_player.play());
  }

  Future<void> _onIndexChanged(int? index) async {
    if (index == null || index >= _entries.length || index == _index) return;
    final previous = _index != null && _index! < _entries.length ? _entries[_index!] : null;
    _index = index;
    final entry = _entries[index];
    if (entry.repeats == 0) await _player.setLoopMode(LoopMode.one);
    // Cada paso nuevo suena con el volumen del preset de su sonido (aunque se repita el mismo sonido)
    if (previous == null || previous.stepIndex != entry.stepIndex) {
      await DeviceVolume.set(entry.sound.volumePreset);
    }
    notifyListeners();
  }

  int? _nextStepStart(int index) {
    final step = _entries[index].stepIndex;
    for (var i = index + 1; i < _entries.length; i++) {
      if (_entries[i].stepIndex != step) return i;
    }
    return null;
  }

  Future<void> nextStep() async {
    final next = _index == null ? null : _nextStepStart(_index!);
    if (next == null) return;
    await _player.seek(Duration.zero, index: next);
  }

  Future<void> pause() => _player.pause();

  Future<void> resume() async {
    final sound = currentSound;
    if (sound != null) await DeviceVolume.set(sound.volumePreset);
    unawaited(_player.play());
  }

  Future<void> stop() async {
    await _player.stop();
    _clear();
  }

  /// Aplica en vivo un cambio de preset del sonido actual.
  Future<void> applyPreset(SoundItem sound) async {
    if (!isCurrent(sound)) return;
    await DeviceVolume.set(sound.volumePreset);
    if (_queue == null) {
      _entries = [_Entry(sound, 0, 1, sound.loopMode ? 0 : 1)];
      await _player.setLoopMode(sound.loopMode ? LoopMode.one : LoopMode.off);
    }
    notifyListeners();
  }

  void _clear() {
    if (_entries.isEmpty) return;
    _entries = [];
    _queue = null;
    _index = null;
    _paused = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
