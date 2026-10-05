import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'details.dart';
import 'files.dart';
import 'models.dart';
import 'playback.dart';
import 'queues.dart';
import 'storage.dart';
import 'scraper.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Servicio en primer plano: sigue sonando con la pantalla apagada y muestra controles en la notificación
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.soundlife.channel.audio',
    androidNotificationChannelName: 'Reproducción',
    androidNotificationIcon: 'mipmap/launcher_icon',
  );
  runApp(const SoundLifeApp());
}

class SoundLifeApp extends StatelessWidget {
  const SoundLifeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundLife',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _coverWorkers = 4;
  static const List<String> _audioExtensions = ['mp3', 'wav', 'm4a', 'flac', 'aac'];

  final StorageService _storageService = StorageService();
  final PlaybackController _playback = PlaybackController();

  List<SoundItem> _sounds = [];
  bool _isLoading = true;
  // Android copia los ficheros elegidos a caché antes de devolverlos: mostramos esqueletos mientras tanto
  bool _importing = false;
  // Rutas de los sonidos cuya carátula se está buscando ahora mismo
  final Set<String> _searchingCovers = {};
  int _coversTotal = 0;
  int _coversDone = 0;
  // Sonidos cuyo fichero ya no existe
  final Set<String> _missing = {};
  String _version = '';

  @override
  void initState() {
    super.initState();
    _playback.addListener(_onPlaybackChanged);
    _playback.onCastError = (message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    };
    _loadData();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = '${info.version} (${info.buildNumber})');
    });
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    _playback.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final sounds = await _storageService.loadSounds();

    // Sacar de la caché los audios importados con versiones anteriores
    var migrated = false;
    for (final sound in sounds) {
      final path = await AppFiles.persistAudio(sound.filePath);
      if (path != sound.filePath) {
        sound.filePath = path;
        migrated = true;
      }
    }
    if (migrated) await _storageService.saveSounds(sounds);

    setState(() {
      _sounds = sounds;
      _isLoading = false;
      _missing
        ..clear()
        ..addAll(sounds.where((s) => !File(s.filePath).existsSync()).map((s) => s.filePath));
    });
    // Primera vez con esta versión: también se descargan las fichas de toda la biblioteca
    _fetchCovers(sounds.where((s) => s.coverPath == null || s.title == null || s.detailsPath == null).toList());
  }

  String _identifierOf(SoundItem sound) => ScraperService.extractIdentifier(
        sound.identifier.isNotEmpty ? sound.identifier : sound.fileName,
      );

  /// Busca en la web nombre y carátula (guardándola en local) en paralelo con límite,
  /// pintando cada tarjeta en cuanto llega su información.
  Future<void> _fetchCovers(List<SoundItem> items, {bool force = false}) async {
    final pending = items
        .where((s) => _identifierOf(s).isNotEmpty && !_searchingCovers.contains(s.filePath))
        .toList();
    if (pending.isEmpty) return;

    setState(() {
      _searchingCovers.addAll(pending.map((s) => s.filePath));
      _coversTotal += pending.length;
    });

    bool changed = false;
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final sound = pending.removeAt(0);
        final id = _identifierOf(sound);
        final needsInfo = force || sound.coverUrl == null || sound.title == null || sound.detailsPath == null;
        final info = needsInfo ? await ScraperService.fetchProduct(id) : null;
        final url = info?.imageUrl ?? sound.coverUrl;
        final needsDownload = url != null && (force || sound.coverPath == null || url != sound.coverUrl);
        final path = needsDownload ? await AppFiles.cacheCover(id, url) : null;
        final details = info?.details;
        final detailsPath = details == null || details.isEmpty ? null : await AppFiles.saveDetails(id, details);
        if (!mounted) return;
        setState(() {
          if (detailsPath != null) {
            sound.detailsPath = detailsPath;
            changed = true;
          }
          if (info?.productUrl != null && info!.productUrl != sound.productUrl) {
            sound.productUrl = info.productUrl;
            changed = true;
          }
          if (info?.title != null && info!.title != sound.title) {
            sound.title = info.title;
            changed = true;
          }
          if (url != null && url != sound.coverUrl) {
            sound.coverUrl = url;
            changed = true;
          }
          if (path != null) {
            // Nueva ruta de imagen: forzar recarga aunque el nombre del fichero coincida
            if (sound.coverPath != null) imageCache.evict(FileImage(File(path)));
            sound.coverPath = path;
            changed = true;
          }
          _searchingCovers.remove(sound.filePath);
          _coversDone++;
          if (_searchingCovers.isEmpty) _coversTotal = _coversDone = 0;
        });
      }
    }

    await Future.wait(List.generate(_coverWorkers, (_) => worker()));
    if (changed) await _storageService.saveSounds(_sounds);
  }

  Future<void> _selectFolderAndScan() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _audioExtensions,
      onFileLoading: (status) {
        if (mounted) setState(() => _importing = status == FilePickerStatus.picking);
      },
    );
    if (result == null) {
      if (mounted && _importing) setState(() => _importing = false);
      return;
    }
    if (mounted && !_importing) setState(() => _importing = true);

    final byName = {for (final s in _sounds) s.fileName: s};
    final added = <SoundItem>[];
    for (final picked in result.paths) {
      if (picked == null) continue;
      final fileName = picked.split(Platform.pathSeparator).last;
      final existing = byName[fileName];
      if (existing != null && !_missing.contains(existing.filePath)) {
        // Ya importado: descartar la copia temporal
        if (picked != existing.filePath) File(picked).delete().ignore();
        continue;
      }
      final path = await AppFiles.persistAudio(picked);
      if (existing != null) {
        // Volver a importar un sonido cuyo fichero se perdió conserva su preset
        _missing.remove(existing.filePath);
        existing.filePath = path;
        continue;
      }
      final sound = SoundItem(
        filePath: path,
        fileName: fileName,
        identifier: ScraperService.extractIdentifier(fileName),
      );
      added.add(sound);
      byName[fileName] = sound;
    }

    if (!mounted) return;
    // Las tarjetas aparecen al instante; las carátulas se van rellenando solas
    setState(() {
      _sounds = [..._sounds, ...added];
      _importing = false;
    });
    await _storageService.saveSounds(_sounds);
    _fetchCovers(added);
  }

  Future<void> _playSound(SoundItem sound) async {
    if (_missing.contains(sound.filePath)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('El fichero ya no existe. Vuelve a importarlo con el botón de carpeta.'),
      ));
      return;
    }
    if (_playback.isCurrent(sound) && _playback.queue == null) {
      // Tocar el sonido actual: si está en pausa se reanuda, si suena se para
      _playback.isPaused ? await _playback.resume() : await _playback.stop();
      return;
    }
    await _playback.playSound(sound);
  }

  void _openDetails(SoundItem sound, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SoundDetailScreen(
        sound: sound,
        playback: _playback,
        onPlay: () => _playSound(sound),
        onPreset: () => _showVolumeConfig(sound, index),
        onDownload: () => _fetchCovers([sound], force: true),
      ),
    ));
  }

  void _openQueues() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => QueuesScreen(playback: _playback, sounds: _sounds),
    ));
  }

  void _showVolumeConfig(SoundItem sound, int index) {
    double currentVolume = sound.volumePreset;
    bool currentLoop = sound.loopMode;
    bool isPlaying() => _playback.isCurrent(sound);

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Volumen: ${sound.displayName}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Configura el nivel de volumen por defecto para este sonido (Uso nocturno recomendado: bajo)'),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Icon(Icons.volume_mute),
                      Expanded(
                        child: Slider(
                          value: currentVolume,
                          min: 0.0,
                          max: 1.0,
                          divisions: 20,
                          label: '${(currentVolume * 100).round()}%',
                          onChanged: (val) {
                            setDialogState(() {
                              currentVolume = val;
                            });
                            // Si este sonido está sonando, se oye el cambio en vivo (móvil o dispositivo remoto)
                            if (isPlaying()) _playback.previewVolume(val);
                          },
                        ),
                      ),
                      const Icon(Icons.volume_up),
                    ],
                  ),
                  Text('${(currentVolume * 100).round()}%'),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.repeat),
                    title: const Text('Loop mode'),
                    subtitle: const Text('Volver a empezar al terminar'),
                    value: currentLoop,
                    onChanged: (val) => setDialogState(() => currentLoop = val),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (isPlaying()) _playback.previewVolume(sound.volumePreset);
                    Navigator.pop(context);
                  },
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    sound.volumePreset = currentVolume;
                    sound.loopMode = currentLoop;
                    _sounds[index] = sound;
                    await _playback.applyPreset(sound);
                    await _storageService.saveSounds(_sounds);
                    if (mounted) setState(() {});
                    navigator.pop();
                  },
                  child: const Text('Guardar Preset'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  PreferredSizeWidget? _progressBar() {
    if (_importing) {
      return const PreferredSize(
        preferredSize: Size.fromHeight(2),
        child: LinearProgressIndicator(minHeight: 2, color: kAccent),
      );
    }
    if (_coversTotal > 0) {
      return PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: LinearProgressIndicator(
          minHeight: 2,
          color: kAccent,
          backgroundColor: Colors.white10,
          value: _coversDone / _coversTotal,
        ),
      );
    }
    return null;
  }

  Widget _buildBody() {
    if (_isLoading) return const SizedBox.shrink();

    final skeletons = _importing ? 4 : 0;
    if (_sounds.isEmpty && skeletons == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.music_note, size: 80, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'No hay sonidos locales.',
              style: TextStyle(fontSize: 18, color: Colors.white54),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.audio_file),
              label: const Text('Seleccionar Archivos'),
              onPressed: _selectFolderAndScan,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.85,
      ),
      itemCount: _sounds.length + skeletons,
      itemBuilder: (context, index) {
        if (index >= _sounds.length) return const SkeletonCard();
        final sound = _sounds[index];
        final isCurrent = _playback.isCurrent(sound);
        return SoundCard(
          key: ValueKey(sound.fileName),
          sound: sound,
          isCurrent: isCurrent,
          isPaused: isCurrent && _playback.isPaused,
          searchingCover: _searchingCovers.contains(sound.filePath),
          missing: _missing.contains(sound.filePath),
          onTap: () => _playSound(sound),
          onLongPress: () => _showVolumeConfig(sound, index),
          onInfo: () => _openDetails(sound, index),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _importing || _searchingCovers.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: ClipOval(
            child: Image.asset('assets/icon.png', fit: BoxFit.cover),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SoundLife'),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _importing
                  ? const Text('Importando archivos…', key: ValueKey('imp'), style: TextStyle(fontSize: 12, color: Colors.white60))
                  : _coversTotal > 0
                      ? Text(
                          'Descargando fichas $_coversDone/$_coversTotal',
                          key: const ValueKey('cov'),
                          style: const TextStyle(fontSize: 12, color: Colors.white60),
                        )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
        bottom: _progressBar(),
        actions: [
          IconButton(
            icon: Icon(
              _playback.target == null ? Icons.cast : Icons.cast_connected,
              color: _playback.target == null ? null : kAccent,
            ),
            onPressed: () => CastSheet.show(context, _playback),
            tooltip: _playback.target == null ? 'Reproducir en otro dispositivo' : 'En ${_playback.target!.name}',
          ),
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: _sounds.isEmpty ? null : _openQueues,
            tooltip: 'Colas',
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _importing ? null : _selectFolderAndScan,
            tooltip: 'Seleccionar carpeta de audios',
          ),
          PopupMenuButton<void>(
            tooltip: 'Más opciones',
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: !busy && _sounds.isNotEmpty,
                onTap: () => _fetchCovers(_sounds, force: true),
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh),
                  title: Text('Actualizar fichas'),
                  subtitle: Text('Nombre, carátula y descripción'),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Versión'),
                  subtitle: Text(_version),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: PlayerBar(playback: _playback),
    );
  }
}
