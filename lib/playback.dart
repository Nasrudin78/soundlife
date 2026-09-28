import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'cast.dart';
import 'files.dart';
import 'models.dart';
import 'volume.dart';

/// Una entrada de la lista de reproducción: un sonido dentro de un paso.
class _Entry {
  final SoundItem sound;
  final int stepIndex;
  final int repetition; // 1-based
  final int repeats; // 0 = infinito
  _Entry(this.sound, this.stepIndex, this.repetition, this.repeats);
}

/// Reproductor único de la app (sonido suelto o cola), en el móvil o en un dispositivo DLNA.
///
/// En el móvil, las colas se entregan enteras a just_audio: el paso de un audio al siguiente lo hace
/// el reproductor nativo sin cortes, con servicio en primer plano para la pantalla apagada.
/// Un paso con N repeticiones son N entradas seguidas; el último paso infinito es una entrada
/// que se pone en LoopMode.one al llegar a ella.
///
/// En un dispositivo DLNA solo se puede enviar un fichero cada vez: se consulta su estado cada
/// segundo y, al terminar, se lanza la entrada siguiente con la misma regla.
class PlaybackController extends ChangeNotifier {
  static const Duration _pollInterval = Duration(seconds: 1);

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  List<_Entry> _entries = [];
  SoundQueue? _queue;
  int? _index;
  bool _paused = false;

  // Destino remoto (null = este móvil)
  CastDevice? _target;
  CastRenderer? _renderer;
  Timer? _poll;
  bool _polling = false;
  bool _remoteStarted = false; // el dispositivo ya reprodujo la entrada actual
  // Dispositivos con quietPolling: momento previsto de la próxima consulta (fin del audio)
  DateTime? _checkAt;
  Duration? _checkRemaining; // tiempo hasta la consulta, guardado al pausar
  int _pollFailures = 0;

  /// Se llama cuando falla el dispositivo remoto y se vuelve al móvil.
  void Function(String message)? onCastError;

  PlaybackController() {
    CastNative.init();
    CastNative.onStopRequested = () => disconnect(resumeLocally: false);
    _subs.add(_player.currentIndexStream.listen((i) {
      if (_renderer == null) _onIndexChanged(i);
    }));
    _subs.add(_player.playerStateStream.listen((state) {
      if (_renderer != null) return;
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
  CastDevice? get target => _target;
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

  MediaItem _mediaItem(_Entry e) => MediaItem(
        id: '${_queue?.id ?? 'single'}/${e.stepIndex}/${e.repetition}/${e.sound.filePath}',
        title: e.sound.displayName,
        album: _queue?.name ?? 'SoundLife',
        artUri: e.sound.coverPath != null && File(e.sound.coverPath!).existsSync()
            ? Uri.file(e.sound.coverPath!)
            : (e.sound.coverUrl != null ? Uri.parse(e.sound.coverUrl!) : null),
      );

  Future<void> playSound(SoundItem sound) async {
    await _load([_Entry(sound, 0, 1, sound.loopMode ? 0 : 1)], queue: null);
  }

  /// [sounds] resuelve cada paso por nombre de fichero; los pasos sin sonido se saltan.
  Future<void> playQueue(SoundQueue queue, Map<String, SoundItem> sounds) async {
    final entries = <_Entry>[];
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
      }
    }
    if (entries.isEmpty) return;
    await _load(entries, queue: queue);
  }

  Future<void> _load(List<_Entry> entries, {required SoundQueue? queue}) async {
    _entries = entries;
    _queue = queue;
    _index = null;
    _paused = false;
    if (_renderer != null) {
      await _playRemote(0);
    } else {
      await _loadLocal(0);
    }
  }

  Future<void> _loadLocal(int initialIndex) async {
    await _player.stop();
    _index = null;
    _paused = false;
    await _player.setLoopMode(LoopMode.off);
    await _player.setAudioSources(
      [for (final e in _entries) AudioSource.file(e.sound.filePath, tag: _mediaItem(e))],
      initialIndex: initialIndex,
    );
    await _onIndexChanged(initialIndex);
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
    if (_renderer != null) {
      await _playRemote(next);
    } else {
      await _player.seek(Duration.zero, index: next);
    }
  }

  Future<void> pause() async {
    if (_renderer != null) {
      await _remote(() => _renderer!.pause());
      if (_checkAt != null) {
        _checkRemaining = _checkAt!.difference(DateTime.now());
        _checkAt = null;
      }
      _paused = true;
      notifyListeners();
    } else {
      await _player.pause();
    }
  }

  Future<void> resume() async {
    final sound = currentSound;
    if (_renderer != null) {
      await _remote(() async {
        if (sound != null) await _renderer!.setVolume(sound.volumePreset);
        await _renderer!.play();
      });
      if (_renderer?.quietPolling == true) {
        _remoteStarted = true;
        _checkAt = DateTime.now().add(_checkRemaining ?? const Duration(seconds: 3));
        _checkRemaining = null;
      }
      _paused = false;
      notifyListeners();
    } else {
      if (sound != null) await DeviceVolume.set(sound.volumePreset);
      unawaited(_player.play());
    }
  }

  Future<void> stop() async {
    if (_renderer != null) {
      await _remote(() => _renderer!.stop());
    } else {
      await _player.stop();
    }
    _clear();
  }

  /// Volumen en vivo mientras se mueve el deslizador del preset.
  Future<void> previewVolume(double volume) async {
    if (_renderer != null) {
      await _remote(() => _renderer!.setVolume(volume));
    } else {
      await DeviceVolume.set(volume);
    }
  }

  /// Aplica en vivo un cambio de preset del sonido actual.
  Future<void> applyPreset(SoundItem sound) async {
    if (!isCurrent(sound)) return;
    await previewVolume(sound.volumePreset);
    if (_queue == null) {
      _entries = [_Entry(sound, 0, 1, sound.loopMode ? 0 : 1)];
      _index = 0;
      if (_renderer == null) await _player.setLoopMode(sound.loopMode ? LoopMode.one : LoopMode.off);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- Casting

  /// Envía la reproducción a [device]. Si algo suena, sigue allí desde el principio de la entrada actual.
  /// Lanza una excepción si no hay WiFi.
  Future<void> connect(CastDevice device) async {
    if (_target?.id == device.id) return;
    if (_renderer != null) await disconnect(resumeLocally: false, keepQueue: true);

    await MediaServer.instance.start();
    final wasPlaying = _entries.isNotEmpty && !_paused;
    final resumeAt = _index ?? 0;
    await _player.stop();

    _target = device;
    _renderer = CastRenderer.forDevice(device);
    _pollFailures = 0;
    await CastNative.requestNotificationPermission();
    await CastNative.startService(device.name);
    _poll = Timer.periodic(_pollInterval, (_) => _pollRemote());
    notifyListeners();

    if (_entries.isNotEmpty) await _playRemote(resumeAt, forceVolume: true, autoplay: wasPlaying);
  }

  /// Vuelve al móvil. Con [resumeLocally], lo que sonaba sigue aquí.
  Future<void> disconnect({bool resumeLocally = true, bool keepQueue = false}) async {
    final renderer = _renderer;
    if (renderer == null) return;
    final wasPlaying = _entries.isNotEmpty && !_paused;
    final resumeAt = _index ?? 0;

    _poll?.cancel();
    _poll = null;
    _renderer = null;
    _target = null;
    try {
      await renderer.stop();
    } catch (_) {}
    await CastNative.stopService();
    await MediaServer.instance.stop();

    if (resumeLocally && wasPlaying) {
      await _loadLocal(resumeAt);
    } else if (!keepQueue) {
      _clear();
    }
    notifyListeners();
  }

  Future<void> _playRemote(int index, {bool forceVolume = false, bool autoplay = true}) async {
    if (_renderer == null || index >= _entries.length) return;
    final previous = _index != null && _index! < _entries.length ? _entries[_index!] : null;
    final entry = _entries[index];
    _index = index;
    _paused = !autoplay;
    _remoteStarted = false;
    _checkAt = null;
    notifyListeners();
    await _remote(() async {
      await _renderer!.load(entry.sound);
      if (forceVolume || previous == null || previous.stepIndex != entry.stepIndex) {
        await _renderer!.setVolume(entry.sound.volumePreset);
      }
      if (autoplay) await _renderer!.play();
    });
    if (_renderer?.quietPolling == true) {
      // WAV: fin exacto por su cabecera. Otros formatos: una consulta a los 3 s para saber la duración.
      final duration = AppFiles.wavDuration(entry.sound.filePath);
      final wait = duration != null ? duration + const Duration(milliseconds: 1500) : const Duration(seconds: 3);
      if (autoplay) {
        _remoteStarted = true;
        _checkAt = DateTime.now().add(wait);
      } else {
        _checkRemaining = wait;
      }
    }
  }

  /// Sondeo de dispositivos con quietPolling: nada mientras suena, solo al final previsto.
  Future<void> _pollQuiet(CastRenderer renderer) async {
    final checkAt = _checkAt;
    if (checkAt == null || DateTime.now().isBefore(checkAt)) return;
    final state = await renderer.transportState();
    _pollFailures = 0;
    if (renderer != _renderer) return;
    final now = DateTime.now();
    switch (state) {
      case 'PLAYING':
        if (_paused) {
          _paused = false; // reanudado desde el propio altavoz
          notifyListeners();
        }
        // Aún no ha terminado (o no conocíamos la duración): siguiente consulta al final
        final p = await renderer.progress();
        final left = p == null ? const Duration(seconds: 5) : p.total - p.position + const Duration(seconds: 1);
        _checkAt = now.add(left < const Duration(seconds: 2) ? const Duration(seconds: 2) : left);
      case 'PAUSED_PLAYBACK':
        if (!_paused) {
          _paused = true; // pausado desde el propio altavoz: sin audio, se puede consultar a menudo
          notifyListeners();
        }
        _checkAt = now.add(const Duration(seconds: 10));
      case 'STOPPED':
      case 'NO_MEDIA_PRESENT':
        if (_remoteStarted) await _advanceRemote();
      default:
        _checkAt = now.add(const Duration(seconds: 2)); // cargando
    }
  }

  Future<void> _pollRemote() async {
    final renderer = _renderer;
    if (renderer == null || _polling || _entries.isEmpty || _index == null) return;
    _polling = true;
    try {
      if (renderer.quietPolling) {
        await _pollQuiet(renderer);
        return;
      }
      final state = await renderer.transportState();
      _pollFailures = 0;
      if (renderer != _renderer) return;
      switch (state) {
        case 'PLAYING':
          _remoteStarted = true;
          if (_paused) {
            _paused = false;
            notifyListeners();
          }
        case 'PAUSED_PLAYBACK':
          if (!_paused) {
            _paused = true;
            notifyListeners();
          }
        case 'STOPPED':
        case 'NO_MEDIA_PRESENT':
          // Fin del fichero: siguiente entrada (o la misma si es infinita)
          if (_remoteStarted && !_paused) await _advanceRemote();
      }
    } catch (e) {
      // Un fallo puntual se tolera; varios seguidos = dispositivo perdido (o cambió de puerto)
      if (++_pollFailures >= 5) {
        _pollFailures = 0;
        if (!await _recover()) await _castFailed(e);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _advanceRemote() async {
    final i = _index!;
    if (_entries[i].repeats == 0) {
      await _playRemote(i);
    } else if (i + 1 < _entries.length) {
      await _playRemote(i + 1);
    } else {
      _clear();
    }
  }

  Future<void> _remote(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('Cast: $e');
      // Reintento único tras volver a localizar el dispositivo
      if (await _recover()) {
        try {
          await action();
          return;
        } catch (e2) {
          await _castFailed(e2);
          return;
        }
      }
      await _castFailed(e);
    }
  }

  /// Algunos altavoces (LinkPlay/GGMM) reinician su servidor UPnP en otro puerto:
  /// se busca de nuevo el mismo dispositivo y, si aparece, se sigue con sus nuevas direcciones.
  Future<bool> _recover() async {
    final target = _target;
    if (target == null) return false;
    final fresh = await CastDiscovery.find(target.id);
    if (fresh == null || _target?.id != target.id) return false;
    debugPrint('Cast: ${fresh.name} localizado de nuevo en ${fresh.avTransport}');
    _target = fresh;
    _renderer = CastRenderer.forDevice(fresh);
    return true;
  }

  Future<void> _castFailed(Object error) async {
    final name = _target?.name ?? 'el dispositivo';
    debugPrint('Cast error: $error');
    await disconnect(resumeLocally: false);
    onCastError?.call('Se perdió la conexión con $name. La reproducción se ha detenido.');
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
    _poll?.cancel();
    _player.dispose();
    MediaServer.instance.stop();
    CastNative.stopService();
    super.dispose();
  }
}
