import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cast.dart';
import 'models.dart';
import 'playback.dart';
import 'volume.dart';
import 'widgets.dart';

/// Alarma configurada por el usuario: despierta con un sonido de la biblioteca.
class AlarmEntry {
  final int id;
  int hour;
  int minute;
  Set<int> weekdays; // DateTime.monday..sunday; vacío = una sola vez
  bool enabled;
  String fileName; // sonido, por nombre de fichero (como las colas)
  double volume; // misma escala que los presets
  int fadeMinutes; // subida gradual
  int snoozeMinutes;

  AlarmEntry({
    required this.id,
    this.hour = 7,
    this.minute = 30,
    Set<int>? weekdays,
    this.enabled = true,
    required this.fileName,
    this.volume = 0.15,
    this.fadeMinutes = 3,
    this.snoozeMinutes = 10,
  }) : weekdays = weekdays ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'weekdays': weekdays.toList()..sort(),
        'enabled': enabled,
        'fileName': fileName,
        'volume': volume,
        'fadeMinutes': fadeMinutes,
        'snoozeMinutes': snoozeMinutes,
      };

  factory AlarmEntry.fromJson(Map<String, dynamic> json) => AlarmEntry(
        id: json['id'],
        hour: json['hour'] ?? 7,
        minute: json['minute'] ?? 30,
        weekdays: {for (final d in (json['weekdays'] as List? ?? [])) d as int},
        enabled: json['enabled'] ?? true,
        fileName: json['fileName'],
        volume: (json['volume'] as num?)?.toDouble() ?? 0.15,
        fadeMinutes: json['fadeMinutes'] ?? 3,
        snoozeMinutes: json['snoozeMinutes'] ?? 10,
      );

  AlarmEntry copy() => AlarmEntry.fromJson(toJson());

  String get timeLabel => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  static const _dayLetters = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];

  String get daysLabel {
    if (weekdays.isEmpty) return 'Una vez';
    if (weekdays.length == 7) return 'Todos los días';
    if (weekdays.length == 5 && !weekdays.contains(6) && !weekdays.contains(7)) return 'De lunes a viernes';
    if (weekdays.length == 2 && weekdays.containsAll({6, 7})) return 'Fines de semana';
    return [for (var d = 1; d <= 7; d++) if (weekdays.contains(d)) _dayLetters[d - 1]].join(' ');
  }

  /// Próxima vez que debe sonar a partir de [from].
  DateTime nextOccurrence([DateTime? from]) {
    final now = from ?? DateTime.now();
    for (var add = 0; add <= 7; add++) {
      final day = DateTime(now.year, now.month, now.day + add, hour, minute);
      if (!day.isAfter(now)) continue;
      if (weekdays.isEmpty || weekdays.contains(day.weekday)) return day;
    }
    return DateTime(now.year, now.month, now.day + 1, hour, minute);
  }
}

/// Guarda las alarmas y las programa en el sistema con el plugin `alarm` (nativo: suena aunque la
/// app esté cerrada y sobrevive a reinicios). Cada alarma programa solo su próxima ocurrencia;
/// las semanales se reprograman al sonar, al detenerlas y al abrir la app.
class AlarmScheduler {
  AlarmScheduler._();
  static final AlarmScheduler instance = AlarmScheduler._();

  static const _key = 'alarms_v1';
  static const _snoozeOffset = 100000; // id de la alarma pospuesta = id + offset

  /// Cambia cada vez que la lista guardada se modifica fuera de la pantalla de alarmas.
  final ValueNotifier<int> revision = ValueNotifier(0);

  List<SoundItem> _sounds = [];
  void updateSounds(List<SoundItem> sounds) => _sounds = sounds;

  SoundItem? soundFor(AlarmEntry entry) {
    for (final s in _sounds) {
      if (s.fileName == entry.fileName) return s;
    }
    return null;
  }

  Future<List<AlarmEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final str in prefs.getStringList(_key) ?? <String>[]) AlarmEntry.fromJson(jsonDecode(str)),
    ];
  }

  Future<void> save(List<AlarmEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [for (final e in entries) jsonEncode(e.toJson())]);
  }

  int nextId(List<AlarmEntry> entries) =>
      entries.fold(0, (maxId, e) => e.id > maxId ? e.id : maxId) + 1;

  /// Pone al día el sistema con la lista guardada. Se llama al abrir la app y cuando una alarma
  /// deja de sonar (desde la app o desde el botón de la notificación). Una alarma activa que ya no
  /// está programada es que ya sonó: si era de una sola vez se desactiva y si es semanal se
  /// programa su siguiente día.
  Future<void> sync() async {
    final entries = await load();
    final scheduled = {for (final a in await Alarm.getAlarms()) a.id};
    final ringing = {for (final a in Alarm.ringing.value.alarms) a.id};
    var changed = false;
    for (final entry in entries) {
      if (!entry.enabled) {
        if (scheduled.contains(entry.id)) await Alarm.stop(entry.id);
        continue;
      }
      if (scheduled.contains(entry.id) || ringing.contains(entry.id)) continue;
      if (entry.weekdays.isEmpty) {
        entry.enabled = false;
        changed = true;
      } else {
        await schedule(entry);
      }
    }
    if (changed) {
      await save(entries);
      revision.value++;
    }
  }

  Future<void> schedule(AlarmEntry entry) async {
    final sound = soundFor(entry);
    if (!entry.enabled || sound == null || !File(sound.filePath).existsSync()) {
      await cancel(entry); // también la pospuesta, si la hay
      return;
    }
    await Alarm.set(alarmSettings: await _settings(entry, sound, entry.id, entry.nextOccurrence()));
  }

  Future<void> cancel(AlarmEntry entry) async {
    await Alarm.stop(entry.id);
    await Alarm.stop(entry.id + _snoozeOffset);
  }

  Future<void> snooze(AlarmEntry entry) async {
    final sound = soundFor(entry);
    if (sound == null) return;
    final at = DateTime.now().add(Duration(minutes: entry.snoozeMinutes));
    await Alarm.set(alarmSettings: await _settings(entry, sound, entry.id + _snoozeOffset, at));
  }

  /// Alarma de la lista a la que corresponde un id del sistema (incluidas las pospuestas).
  AlarmEntry? entryForAlarmId(List<AlarmEntry> entries, int alarmId) {
    final id = alarmId >= _snoozeOffset ? alarmId - _snoozeOffset : alarmId;
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<AlarmSettings> _settings(AlarmEntry entry, SoundItem sound, int id, DateTime at) async {
    // Mismo volumen fino que los presets: paso del sistema (STREAM_MUSIC) + ganancia del reproductor,
    // que además sube poco a poco durante la subida gradual
    final level = await DeviceVolume.resolve(entry.volume < 0.01 ? 0.01 : entry.volume);
    final steps = entry.fadeMinutes > 0
        ? [VolumeFadeStep(Duration.zero, 0.0), VolumeFadeStep(Duration(minutes: entry.fadeMinutes), level.gain)]
        : [VolumeFadeStep(Duration.zero, level.gain)];
    return AlarmSettings(
      id: id,
      dateTime: at,
      assetAudioPath: sound.filePath,
      loopAudio: true,
      vibrate: false,
      androidFullScreenIntent: true,
      androidStopAlarmOnTermination: false,
      warningNotificationOnKill: false,
      preferConnectedAudioDevice: true,
      payload: '${entry.id}',
      volumeSettings: VolumeSettings.staircaseFade(
        volume: level.index / level.max,
        fadeSteps: steps,
        showSystemUI: false,
      ),
      notificationSettings: NotificationSettings(
        title: 'SoundLife · ${entry.timeLabel}',
        body: sound.displayName,
        stopButton: 'Detener',
        icon: 'launcher_icon',
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------- UI

class AlarmsScreen extends StatefulWidget {
  final PlaybackController playback;
  final List<SoundItem> sounds;
  const AlarmsScreen({super.key, required this.playback, required this.sounds});

  @override
  State<AlarmsScreen> createState() => _AlarmsScreenState();
}

class _AlarmsScreenState extends State<AlarmsScreen> {
  final _scheduler = AlarmScheduler.instance;
  List<AlarmEntry>? _alarms;

  @override
  void initState() {
    super.initState();
    _scheduler.updateSounds(widget.sounds);
    _scheduler.revision.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _scheduler.revision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    _scheduler.load().then((a) {
      if (mounted) setState(() => _alarms = a);
    });
  }

  Future<void> _persist(AlarmEntry changed) async {
    await _scheduler.save(_alarms!);
    await _scheduler.schedule(changed);
  }

  Future<void> _edit([AlarmEntry? alarm]) async {
    if (widget.sounds.isEmpty) return;
    final draft = alarm?.copy() ??
        AlarmEntry(
          id: _scheduler.nextId(_alarms!),
          fileName: _defaultSound().fileName,
          volume: 0.15,
        );
    final saved = await Navigator.of(context).push<AlarmEntry>(MaterialPageRoute(
      builder: (_) => AlarmEditorScreen(alarm: draft, sounds: widget.sounds, playback: widget.playback),
    ));
    if (saved == null) return;
    await _ensurePermissions();
    setState(() {
      final i = _alarms!.indexWhere((a) => a.id == saved.id);
      i == -1 ? _alarms!.add(saved) : _alarms![i] = saved;
      _alarms!.sort((a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
    });
    await _persist(saved);
    if (mounted && saved.enabled) _showNext(saved);
  }

  /// BA16 (vitalidad mañanas) si está en la biblioteca: es el indicado para despertar.
  SoundItem _defaultSound() {
    for (final s in widget.sounds) {
      if (s.identifier == 'BA16') return s;
    }
    return widget.sounds.first;
  }

  Future<void> _ensurePermissions() async {
    await CastNative.requestNotificationPermission();
    if (await CastNative.canUseFullScreenIntent() || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permitir pantalla completa'),
        content: const Text(
          'Para que la alarma se muestre sobre la pantalla de bloqueo, Android necesita que permitas '
          'a SoundLife usar notificaciones a pantalla completa. Sin él la alarma suena igual, '
          'pero solo verás la notificación.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Ahora no')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              CastNative.openFullScreenIntentSettings();
            },
            child: const Text('Abrir ajustes'),
          ),
        ],
      ),
    );
  }

  void _showNext(AlarmEntry alarm) {
    final diff = alarm.nextOccurrence().difference(DateTime.now());
    final h = diff.inHours;
    final m = diff.inMinutes % 60 + (diff.inSeconds % 60 > 0 ? 1 : 0);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Sonará dentro de ${h > 0 ? '$h h ' : ''}$m min'),
    ));
  }

  Future<void> _delete(AlarmEntry alarm) async {
    setState(() => _alarms!.remove(alarm));
    await _scheduler.cancel(alarm);
    await _scheduler.save(_alarms!);
  }

  @override
  Widget build(BuildContext context) {
    final alarms = _alarms;
    return Scaffold(
      appBar: AppBar(title: const Text('Alarmas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: alarms == null || widget.sounds.isEmpty ? null : () => _edit(),
        icon: const Icon(Icons.add_alarm),
        label: const Text('Nueva alarma'),
      ),
      body: alarms == null
          ? const SizedBox.shrink()
          : alarms.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Despierta con un sonido de tu biblioteca.\n'
                      'Recomendado: BA16 vitalidad mañanas al 15 % con 3 min de subida gradual.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: alarms.length,
                  itemBuilder: (context, i) {
                    final alarm = alarms[i];
                    final sound = _scheduler.soundFor(alarm);
                    return Dismissible(
                      key: ValueKey(alarm.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        color: Colors.red[900],
                        child: const Icon(Icons.delete),
                      ),
                      onDismissed: (_) => _delete(alarm),
                      child: Card(
                        color: kCardColor,
                        child: ListTile(
                          onTap: () => _edit(alarm),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox.square(
                              dimension: 48,
                              child: sound == null
                                  ? const Icon(Icons.error_outline, color: Colors.orangeAccent)
                                  : CoverImage.of(sound, iconSize: 24),
                            ),
                          ),
                          title: Text(
                            alarm.timeLabel,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w300,
                              color: alarm.enabled ? null : Colors.white38,
                            ),
                          ),
                          subtitle: Text(
                            '${alarm.daysLabel} · ${sound?.displayName ?? 'sonido no disponible'}\n'
                            'Vol ${(alarm.volume * 100).round()} %'
                            '${alarm.fadeMinutes > 0 ? ' · subida ${alarm.fadeMinutes} min' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          trailing: Switch(
                            value: alarm.enabled,
                            onChanged: (v) async {
                              setState(() => alarm.enabled = v);
                              if (v) await _ensurePermissions();
                              await _persist(alarm);
                              if (v && mounted) _showNext(alarm);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class AlarmEditorScreen extends StatefulWidget {
  final AlarmEntry alarm;
  final List<SoundItem> sounds;
  final PlaybackController playback;
  const AlarmEditorScreen({super.key, required this.alarm, required this.sounds, required this.playback});

  @override
  State<AlarmEditorScreen> createState() => _AlarmEditorScreenState();
}

class _AlarmEditorScreenState extends State<AlarmEditorScreen> {
  AlarmEntry get _a => widget.alarm;

  SoundItem? get _sound {
    for (final s in widget.sounds) {
      if (s.fileName == _a.fileName) return s;
    }
    return null;
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: _a.hour, minute: _a.minute));
    if (t != null) {
      setState(() {
        _a.hour = t.hour;
        _a.minute = t.minute;
      });
    }
  }

  Future<void> _pickSound() async {
    final sound = await showModalBottomSheet<SoundItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => GridView.builder(
          controller: scroll,
          padding: const EdgeInsets.all(12),
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
                  Text(s.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (sound != null) setState(() => _a.fileName = sound.fileName);
  }

  @override
  Widget build(BuildContext context) {
    final sound = _sound;
    const label = TextStyle(fontSize: 13, letterSpacing: 1.1, fontWeight: FontWeight.bold, color: kAccent);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarma'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            icon: const Icon(Icons.check),
            onPressed: sound == null ? null : () => Navigator.pop(context, _a..enabled = true),
          ),
        ],
      ),
      bottomNavigationBar: PlayerBar(playback: widget.playback),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: TextButton(
              onPressed: _pickTime,
              child: Text(_a.timeLabel, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w300)),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(AlarmEntry._dayLetters[d - 1]),
                  selected: _a.weekdays.contains(d),
                  showCheckmark: false,
                  onSelected: (v) => setState(() => v ? _a.weekdays.add(d) : _a.weekdays.remove(d)),
                ),
            ],
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_a.daysLabel, style: const TextStyle(color: Colors.white54)),
            ),
          ),
          const SizedBox(height: 24),
          const Text('SONIDO', style: label),
          const SizedBox(height: 8),
          Card(
            color: kCardColor,
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: 48,
                  child: sound == null ? const Icon(Icons.music_note) : CoverImage.of(sound, iconSize: 24),
                ),
              ),
              title: Text(sound?.displayName ?? 'Elige un sonido'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickSound,
            ),
          ),
          const SizedBox(height: 24),
          const Text('VOLUMEN', style: label),
          FineVolumeSlider(
            value: _a.volume,
            onChanged: (v) {
              setState(() => _a.volume = v < 0.01 ? 0.01 : v);
              if (sound != null && widget.playback.isCurrent(sound)) widget.playback.previewVolume(_a.volume);
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (sound != null && (sound.volumePreset - _a.volume).abs() > 0.001)
                TextButton(
                  onPressed: () => setState(() => _a.volume = sound.volumePreset),
                  child: Text('Usar su preset (${(sound.volumePreset * 100).round()} %)'),
                ),
              const Spacer(),
              OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Probar 10 s'),
                onPressed: sound == null ? null : () => widget.playback.preview(sound, _a.volume),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('SUBIDA GRADUAL', style: label),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('No')),
              ButtonSegment(value: 1, label: Text('1 min')),
              ButtonSegment(value: 3, label: Text('3 min')),
              ButtonSegment(value: 5, label: Text('5 min')),
            ],
            selected: {_a.fadeMinutes},
            onSelectionChanged: (s) => setState(() => _a.fadeMinutes = s.first),
          ),
          const SizedBox(height: 24),
          const Text('POSPONER', style: label),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 5, label: Text('5 min')),
              ButtonSegment(value: 10, label: Text('10 min')),
              ButtonSegment(value: 15, label: Text('15 min')),
            ],
            selected: {_a.snoozeMinutes},
            onSelectionChanged: (s) => setState(() => _a.snoozeMinutes = s.first),
          ),
          const SizedBox(height: 24),
          const Text(
            'Suena por el volumen multimedia, con la misma escala que los presets (o por el altavoz '
            'Bluetooth si está conectado). Consejo de Sound and Life: siempre a volumen suave; mejor '
            'alargar la subida que subir el volumen.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// Pantalla que aparece cuando suena una alarma (también sobre la pantalla de bloqueo).
class AlarmRingingScreen extends StatefulWidget {
  final AlarmSettings alarm;
  const AlarmRingingScreen({super.key, required this.alarm});

  @override
  State<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends State<AlarmRingingScreen> {
  final _scheduler = AlarmScheduler.instance;
  AlarmEntry? _entry;
  late final Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => setState(() => _now = DateTime.now()));
    _scheduler.load().then((all) {
      if (!mounted) return;
      setState(() => _entry = _scheduler.entryForAlarmId(all, widget.alarm.id));
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  // Al dejar de sonar, main.dart llama a AlarmScheduler.sync(), que reprograma o desactiva la alarma
  // y cierra esta pantalla
  Future<void> _stop() => Alarm.stop(widget.alarm.id);

  Future<void> _snooze() async {
    final entry = _entry;
    if (entry != null) await _scheduler.snooze(entry);
    await Alarm.stop(widget.alarm.id);
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final sound = entry == null ? null : _scheduler.soundFor(entry);
    final time = '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (sound != null) Opacity(opacity: 0.35, child: CoverImage.of(sound, iconSize: 120)),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),
                    Text(time, style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w200)),
                    const SizedBox(height: 8),
                    Text(
                      sound?.displayName ?? widget.alarm.notificationSettings.body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20),
                    ),
                    const Spacer(flex: 2),
                    SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black),
                        icon: const Icon(Icons.alarm_off),
                        label: const Text('Detener', style: TextStyle(fontSize: 20)),
                        onPressed: _stop,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.snooze),
                        label: Text('Posponer ${entry?.snoozeMinutes ?? 10} min', style: const TextStyle(fontSize: 18)),
                        onPressed: _snooze,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
