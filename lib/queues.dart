import 'package:flutter/material.dart';
import 'models.dart';
import 'playback.dart';
import 'storage.dart';
import 'widgets.dart';

String _title(SoundItem? sound, String fallback) =>
    sound?.displayName ?? fallback.replaceAll(RegExp(r'\.[^.]+$'), '');

String _repeatsLabel(QueueStep step, bool isLast) =>
    step.isInfinite && isLast ? '∞' : '×${step.isInfinite ? 1 : step.repeats}';

/// Lista de colas guardadas.
class QueuesScreen extends StatefulWidget {
  final PlaybackController playback;
  final List<SoundItem> sounds;

  const QueuesScreen({super.key, required this.playback, required this.sounds});

  @override
  State<QueuesScreen> createState() => _QueuesScreenState();
}

class _QueuesScreenState extends State<QueuesScreen> {
  final StorageService _storage = StorageService();
  List<SoundQueue>? _queues;

  Map<String, SoundItem> get _byName => {for (final s in widget.sounds) s.fileName: s};

  @override
  void initState() {
    super.initState();
    _storage.loadQueues().then((q) {
      if (mounted) setState(() => _queues = q);
    });
  }

  Future<void> _save() => _storage.saveQueues(_queues!);

  Future<void> _edit([SoundQueue? queue]) async {
    final original = queue ?? SoundQueue(id: DateTime.now().microsecondsSinceEpoch.toString(), name: 'Nueva cola');
    // Se edita una copia; solo se aplica al guardar
    final draft = SoundQueue.fromJson(original.toJson());
    final saved = await Navigator.of(context).push<SoundQueue>(
      MaterialPageRoute(
        builder: (_) => QueueEditorScreen(queue: draft, sounds: widget.sounds, playback: widget.playback),
      ),
    );
    if (saved == null) return;
    setState(() {
      final i = _queues!.indexWhere((q) => q.id == saved.id);
      i == -1 ? _queues!.add(saved) : _queues![i] = saved;
    });
    await _save();
  }

  Future<void> _delete(SoundQueue queue) async {
    final index = _queues!.indexOf(queue);
    setState(() => _queues!.removeAt(index));
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Cola "${queue.name}" eliminada'),
      action: SnackBarAction(
        label: 'Deshacer',
        onPressed: () {
          setState(() => _queues!.insert(index, queue));
          _save();
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final queues = _queues;
    return Scaffold(
      appBar: AppBar(title: const Text('Colas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Nueva cola'),
      ),
      bottomNavigationBar: PlayerBar(playback: widget.playback),
      body: queues == null
          ? const SizedBox.shrink()
          : queues.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Crea una cola para encadenar sonidos:\n'
                      'por ejemplo BA07 ×1 → BA09 ×2 → BA50 ∞',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: queues.length,
                  itemBuilder: (context, i) {
                    final queue = queues[i];
                    final byName = _byName;
                    final summary = [
                      for (var s = 0; s < queue.steps.length; s++)
                        '${byName[queue.steps[s].fileName]?.identifier.isNotEmpty == true ? byName[queue.steps[s].fileName]!.identifier : _title(byName[queue.steps[s].fileName], queue.steps[s].fileName)} '
                            '${_repeatsLabel(queue.steps[s], s == queue.steps.length - 1)}',
                    ].join(' → ');
                    return Dismissible(
                      key: ValueKey(queue.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        color: Colors.red[900],
                        child: const Icon(Icons.delete),
                      ),
                      onDismissed: (_) => _delete(queue),
                      child: Card(
                        color: kCardColor,
                        child: ListTile(
                          leading: const Icon(Icons.queue_music, color: kAccent),
                          title: Text(queue.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            queue.steps.isEmpty ? 'Sin pasos' : summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _edit(queue),
                          trailing: IconButton(
                            iconSize: 36,
                            color: kAccent,
                            tooltip: 'Reproducir cola',
                            icon: const Icon(Icons.play_circle_filled),
                            onPressed: queue.steps.isEmpty ? null : () => widget.playback.playQueue(queue, byName),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Editor de una cola: pasos reordenables, repeticiones y bucle final.
class QueueEditorScreen extends StatefulWidget {
  final SoundQueue queue;
  final List<SoundItem> sounds;
  final PlaybackController playback;

  const QueueEditorScreen({super.key, required this.queue, required this.sounds, required this.playback});

  @override
  State<QueueEditorScreen> createState() => _QueueEditorScreenState();
}

class _QueueEditorScreenState extends State<QueueEditorScreen> {
  late final TextEditingController _name = TextEditingController(text: widget.queue.name);

  List<QueueStep> get _steps => widget.queue.steps;
  Map<String, SoundItem> get _byName => {for (final s in widget.sounds) s.fileName: s};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  SoundQueue _result() {
    final queue = widget.queue..name = _name.text.trim().isEmpty ? 'Cola sin nombre' : _name.text.trim();
    // Solo el último paso puede quedarse en bucle infinito
    for (var i = 0; i < queue.steps.length - 1; i++) {
      if (queue.steps[i].isInfinite) queue.steps[i].repeats = 1;
    }
    return queue;
  }

  Future<void> _addStep() async {
    final sound = await showModalBottomSheet<SoundItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Añadir sonido', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: GridView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: widget.sounds.length,
                itemBuilder: (context, i) {
                  final s = widget.sounds[i];
                  return InkWell(
                    onTap: () => Navigator.pop(context, s),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox.expand(child: CoverImage.of(s, iconSize: 32)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(_title(s, ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (sound != null) setState(() => _steps.add(QueueStep(fileName: sound.fileName)));
  }

  Widget _stepTile(int index) {
    final step = _steps[index];
    final sound = _byName[step.fileName];
    final isLast = index == _steps.length - 1;
    final infinite = step.isInfinite && isLast;

    return Card(
      key: ObjectKey(step),
      color: kCardColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.drag_handle, color: Colors.white38),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.square(
                dimension: 44,
                child: sound == null
                    ? const Icon(Icons.error_outline, color: Colors.orangeAccent)
                    : CoverImage.of(sound, iconSize: 22),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${index + 1}. ${_title(sound, step.fileName)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    sound == null
                        ? 'Sonido no disponible (se saltará)'
                        : infinite
                            ? 'En bucle hasta que pares'
                            : '${step.repeats == 1 ? '1 vez' : '${step.repeats} veces'} · Vol ${(sound.volumePreset * 100).round()}%',
                    style: TextStyle(fontSize: 12, color: sound == null ? Colors.orangeAccent : Colors.white54),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: infinite || step.repeats <= 1 ? null : () => setState(() => step.repeats--),
            ),
            SizedBox(
              width: 32,
              child: Text(
                _repeatsLabel(step, isLast),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, color: kAccent),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: infinite ? null : () => setState(() => step.repeats = (step.isInfinite ? 1 : step.repeats) + 1),
            ),
            if (isLast)
              IconButton(
                tooltip: 'Bucle infinito al final',
                color: infinite ? kAccent : null,
                icon: const Icon(Icons.all_inclusive),
                onPressed: () => setState(() => step.repeats = infinite ? 1 : 0),
              ),
            PopupMenuButton<String>(
              onSelected: (_) => setState(() => _steps.removeAt(index)),
              itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Quitar paso'))],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar cola'),
        actions: [
          IconButton(
            tooltip: 'Reproducir',
            icon: const Icon(Icons.play_arrow),
            onPressed: _steps.isEmpty ? null : () => widget.playback.playQueue(_result(), _byName),
          ),
          IconButton(
            tooltip: 'Guardar',
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.pop(context, _result()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: widget.sounds.isEmpty ? null : _addStep,
        icon: const Icon(Icons.add),
        label: const Text('Añadir sonido'),
      ),
      bottomNavigationBar: PlayerBar(playback: widget.playback),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nombre de la cola', border: OutlineInputBorder()),
            ),
          ),
          if (_steps.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Arrastra para reordenar. El último paso puede quedarse en bucle (∞).',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              itemCount: _steps.length,
              onReorder: (from, to) => setState(() {
                if (to > from) to--;
                _steps.insert(to, _steps.removeAt(from));
              }),
              itemBuilder: (context, i) => _stepTile(i),
            ),
          ),
        ],
      ),
    );
  }
}
