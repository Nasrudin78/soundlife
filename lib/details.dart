import 'dart:io';
import 'package:flutter/material.dart';
import 'files.dart';
import 'models.dart';
import 'playback.dart';
import 'product_details.dart';
import 'widgets.dart';

/// Ficha de un sonido: titular de para qué sirve y la Descripción, Aplicaciones y Posología
/// completas, tal como aparecen en soundandlife.com. Se lee de la copia guardada en el móvil.
class SoundDetailScreen extends StatefulWidget {
  final SoundItem sound;
  final PlaybackController playback;
  final VoidCallback onPlay;
  final VoidCallback onPreset;
  final Future<void> Function() onDownload;

  const SoundDetailScreen({
    super.key,
    required this.sound,
    required this.playback,
    required this.onPlay,
    required this.onPreset,
    required this.onDownload,
  });

  @override
  State<SoundDetailScreen> createState() => _SoundDetailScreenState();
}

class _SoundDetailScreenState extends State<SoundDetailScreen> {
  ProductDetails? _details;
  bool _loading = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final path = widget.sound.detailsPath;
    final details = path == null ? null : await AppFiles.loadDetails(path);
    if (mounted) {
      setState(() {
        _details = details;
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    await widget.onDownload();
    await _load();
    if (!mounted) return;
    setState(() => _downloading = false);
    if (_details == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo descargar la ficha. Comprueba la conexión.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sound = widget.sound;
    return Scaffold(
      bottomNavigationBar: PlayerBar(playback: widget.playback),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 280,
            backgroundColor: const Color(0xFF1E1E1E),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage.of(sound, iconSize: 80),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xDD121212)],
                        stops: [0.5, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            sliver: SliverList.list(
              children: [
                Text(
                  sound.displayName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                if (_details?.headline != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _details!.headline!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, color: kAccent, fontWeight: FontWeight.w600, height: 1.3),
                  ),
                ],
                const SizedBox(height: 16),
                ListenableBuilder(
                  listenable: widget.playback,
                  builder: (context, _) {
                    final isCurrent = widget.playback.isCurrent(sound);
                    final playing = isCurrent && !widget.playback.isPaused;
                    return Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                            icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                            label: Text(playing ? 'Parar' : (isCurrent ? 'Reanudar' : 'Reproducir')),
                            onPressed: widget.onPlay,
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.tune),
                          label: Text('Preset · ${(sound.volumePreset * 100).round()}%'),
                          onPressed: widget.onPreset,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                ..._body(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body() {
    if (_loading) return const [];
    final details = _details;
    if (details == null || details.sections.isEmpty) {
      return [
        const SizedBox(height: 32),
        const Icon(Icons.description_outlined, size: 48, color: Colors.white24),
        const SizedBox(height: 12),
        Text(
          widget.sound.identifier.isEmpty
              ? 'Este audio no tiene código BAxx en el nombre, así que no se puede buscar su ficha.'
              : 'Ficha no descargada.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
        if (widget.sound.identifier.isNotEmpty) ...[
          const SizedBox(height: 12),
          Center(
            child: _downloading
                ? const CircularProgressIndicator()
                : OutlinedButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Descargar ahora'),
                    onPressed: _download,
                  ),
          ),
        ],
      ];
    }
    return [for (final section in details.sections) ..._section(section)];
  }

  List<Widget> _section(DetailSection section) => [
        const SizedBox(height: 24),
        Text(
          section.title.toUpperCase(),
          style: const TextStyle(fontSize: 13, letterSpacing: 1.2, fontWeight: FontWeight.bold, color: kAccent),
        ),
        const Divider(height: 16, color: Colors.white24),
        for (final block in section.blocks) _block(block),
      ];

  Widget _block(DetailBlock block) {
    const base = TextStyle(fontSize: 15, height: 1.45, color: Colors.white);
    switch (block.type) {
      case BlockType.heading:
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            block.text,
            textAlign: block.center ? TextAlign.center : TextAlign.start,
            style: base.copyWith(fontWeight: FontWeight.bold),
          ),
        );
      case BlockType.bullet:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('•  ', style: base),
              Expanded(child: SelectableText(block.text, style: base)),
            ],
          ),
        );
      case BlockType.image:
        final path = block.path;
        final image = path != null && File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.contain)
            : Image.network(block.text, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink());
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: image),
        );
      case BlockType.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(
            block.text,
            textAlign: block.center ? TextAlign.center : TextAlign.start,
            style: base.copyWith(
              fontWeight: block.bold ? FontWeight.bold : null,
              fontStyle: block.italic ? FontStyle.italic : null,
            ),
          ),
        );
    }
  }
}
