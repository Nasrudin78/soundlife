import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class StorageService {
  static const String _key = 'sound_items_v1';
  static const String _queuesKey = 'sound_queues_v1';

  Future<void> saveSounds(List<SoundItem> sounds) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> jsonList = sounds.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_key, jsonList);
  }

  Future<List<SoundItem>> loadSounds() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? jsonList = prefs.getStringList(_key);

    if (jsonList == null) return [];

    return jsonList.map((str) => SoundItem.fromJson(jsonDecode(str))).toList();
  }

  Future<void> saveQueues(List<SoundQueue> queues) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queuesKey, queues.map((q) => jsonEncode(q.toJson())).toList());
  }

  Future<List<SoundQueue>> loadQueues() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_queuesKey) ?? [];
    return jsonList.map((str) => SoundQueue.fromJson(jsonDecode(str))).toList();
  }

  Future<void> saveSelectedDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_directory', path);
  }

  Future<String?> loadSelectedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('selected_directory');
  }
}
