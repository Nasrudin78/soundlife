import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'cast.dart';
import 'models.dart';
import 'playback.dart';

const Color kAccent = Colors.tealAccent;
const Color kCardColor = Color(0xFF2C2C2C);

/// Bloque gris que "respira" mientras algo carga (skeleton loading).
class PulsePlaceholder extends StatefulWidget {
  final Widget? child;
  const PulsePlaceholder({super.key, this.child});

  @override
  State<PulsePlaceholder> createState() => _PulsePlaceholderState();
}

class _PulsePlaceholderState extends State<PulsePlaceholder> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        color: Color.lerp(const Color(0xFF333333), const Color(0xFF444444), _controller.value),
        alignment: Alignment.center,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Carátula con placeholder animado mientras se busca/descarga y fundido al aparecer.
class CoverImage extends StatelessWidget {
  final String? url;
  final String? path;
  final bool searching;
  final double iconSize;

  const CoverImage({super.key, required this.url, this.path, this.searching = false, this.iconSize = 50});

  factory CoverImage.of(SoundItem sound, {bool searching = false, double iconSize = 50}) =>
      CoverImage(url: sound.coverUrl, path: sound.coverPath, searching: searching, iconSize: iconSize);

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: const Color(0xFF262626),
      alignment: Alignment.center,
      child: Icon(Icons.graphic_eq, size: iconSize, color: Colors.white24),
    );

    // Copia local primero: funciona en modo avión
    if (path != null) {
      return Image.file(
        File(path!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => url != null ? CoverImage(url: url, iconSize: iconSize) : fallback,
      );
    }
    if (url == null) return searching ? const PulsePlaceholder() : fallback;

    return Image.network(
      url!,
      fit: BoxFit.cover,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        if (frame == null) return const PulsePlaceholder();
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 350),
          builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
          child: child,
        );
      },
      errorBuilder: (context, error, stack) => fallback,
    );
  }
}

class SoundCard extends StatelessWidget {
  final SoundItem sound;
  final bool isCurrent;
  final bool isPaused;
  final bool searchingCover;
  final bool missing;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const SoundCard({
    super.key,
    required this.sound,
    required this.isCurrent,
    required this.isPaused,
    required this.searchingCover,
    this.missing = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: isCurrent ? 8 : 2,
      color: isCurrent ? Colors.blueGrey[900] : kCardColor,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: isCurrent ? kAccent : Colors.transparent, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage.of(sound, searching: searchingCover),
                  if (missing)
                    Container(
                      color: Colors.black54,
                      alignment: Alignment.center,
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline, size: 36, color: Colors.orangeAccent),
                          SizedBox(height: 4),
                          Text('Fichero no encontrado', style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                        ],
                      ),
                    ),
                  if (isCurrent)
                    Container(
                      color: Colors.black38,
                      alignment: Alignment.center,
                      child: Icon(
                        isPaused ? Icons.pause_circle_filled : Icons.graphic_eq,
                        size: 48,
                        color: kAccent,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sound.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        'Vol: ${(sound.volumePreset * 100).round()}%',
                        style: const TextStyle(fontSize: 12, color: kAccent),
                      ),
                      if (sound.loopMode) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.repeat, size: 14, color: kAccent),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Esqueleto de tarjeta mientras se importan los ficheros.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: kCardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: PulsePlaceholder()),
          Padding(
            padding: EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 14, width: 110, child: PulsePlaceholder()),
                SizedBox(height: 6),
                SizedBox(height: 12, width: 50, child: PulsePlaceholder()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra inferior con el sonido actual y controles globales de pausa/stop.
class NowPlayingBar extends StatelessWidget {
  final SoundItem sound;
  final bool isPaused;
  final String? queueName;
  final String? progressLabel;
  final String? targetName;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final VoidCallback? onNext;

  const NowPlayingBar({
    super.key,
    required this.sound,
    required this.isPaused,
    this.queueName,
    this.progressLabel,
    this.targetName,
    required this.onPlayPause,
    required this.onStop,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1E1E1E),
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: 48,
                  child: CoverImage.of(sound, iconSize: 24),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sound.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      (queueName != null
                              ? '${isPaused ? 'En pausa' : queueName} · $progressLabel'
                              : '${isPaused ? 'En pausa' : 'Reproduciendo'} · '
                                  'Vol ${(sound.volumePreset * 100).round()}%${sound.loopMode ? ' · Loop' : ''}') +
                          (targetName != null ? ' · en $targetName' : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 36,
                color: kAccent,
                tooltip: isPaused ? 'Reanudar' : 'Pausa',
                icon: Icon(isPaused ? Icons.play_circle_filled : Icons.pause_circle_filled),
                onPressed: onPlayPause,
              ),
              if (queueName != null)
                IconButton(
                  iconSize: 28,
                  tooltip: 'Siguiente paso',
                  icon: const Icon(Icons.skip_next),
                  onPressed: onNext,
                ),
              IconButton(
                iconSize: 30,
                tooltip: 'Stop',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: onStop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Barra de reproducción conectada al [PlaybackController]; se oculta si no suena nada.
class PlayerBar extends StatelessWidget {
  final PlaybackController playback;
  const PlayerBar({super.key, required this.playback});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final sound = playback.currentSound;
        return AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: sound == null
              ? const SizedBox(width: double.infinity)
              : NowPlayingBar(
                  sound: sound,
                  isPaused: playback.isPaused,
                  queueName: playback.queue?.name,
                  progressLabel: playback.progressLabel,
                  targetName: playback.target?.name,
                  onPlayPause: playback.isPaused ? playback.resume : playback.pause,
                  onStop: playback.stop,
                  onNext: playback.hasNext ? playback.nextStep : null,
                ),
        );
      },
    );
  }
}

/// Hoja para elegir dónde suena: este móvil o un dispositivo DLNA de la red.
class CastSheet extends StatefulWidget {
  final PlaybackController playback;
  const CastSheet({super.key, required this.playback});

  static Future<void> show(BuildContext context, PlaybackController playback) => showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E1E1E),
        showDragHandle: true,
        builder: (_) => CastSheet(playback: playback),
      );

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  final List<CastDevice> _devices = [];
  StreamSubscription<CastDevice>? _sub;
  bool _scanning = false;
  bool _noWifi = false;
  String? _connecting;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    await _sub?.cancel();
    final ip = await MediaServer.wifiAddress();
    if (!mounted) return;
    if (ip == null) {
      setState(() => _noWifi = true);
      return;
    }
    setState(() {
      _noWifi = false;
      _scanning = true;
      _devices.clear();
    });
    _sub = CastDiscovery.discover().listen(
      (d) => setState(() => _devices.add(d)),
      onError: (_) {},
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _select(CastDevice? device) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _connecting = device?.id ?? 'phone');
    try {
      device == null ? await widget.playback.disconnect() : await widget.playback.connect(device);
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = null);
      messenger.showSnackBar(SnackBar(content: Text('No se pudo conectar: $e')));
    }
  }

  Widget _tile({required IconData icon, required String title, String? subtitle, required bool selected, required String id, required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon, color: selected ? kAccent : null),
      title: Text(title, style: TextStyle(color: selected ? kAccent : null, fontWeight: selected ? FontWeight.bold : null)),
      subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
      trailing: _connecting == id
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : selected
              ? const Icon(Icons.check, color: kAccent)
              : null,
      onTap: _connecting != null ? null : onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.playback.target;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Reproducir en', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                if (_scanning)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(tooltip: 'Buscar de nuevo', icon: const Icon(Icons.refresh), onPressed: _scan),
              ],
            ),
          ),
          _tile(
            icon: Icons.phone_android,
            title: 'Este móvil',
            subtitle: 'También altavoces Bluetooth emparejados',
            selected: target == null,
            id: 'phone',
            onTap: () => _select(null),
          ),
          for (final d in [
            // El dispositivo actual siempre aparece, aunque no responda a esta búsqueda
            if (target != null && !_devices.any((d) => d.id == target.id)) target,
            ..._devices,
          ])
            _tile(
              icon: Icons.speaker,
              title: d.name,
              subtitle: d.model,
              selected: target?.id == d.id,
              id: d.id,
              onTap: () => _select(d),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              _noWifi
                  ? 'Conéctate al WiFi de casa para enviar a otros dispositivos.'
                  : _scanning
                      ? 'Buscando dispositivos en la red…'
                      : _devices.isEmpty
                          ? 'No se ha encontrado ningún dispositivo DLNA. Comprueba que están encendidos y en el mismo WiFi.'
                          : 'El móvil tiene que seguir en el WiFi mientras suena en otro dispositivo.',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}
