import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'models.dart';

/// Reproductor DLNA/UPnP de la red local (Sonos, Smart TV, altavoces LinkPlay como GGMM…).
class CastDevice {
  final String id; // UDN
  final String name;
  final String? model;
  final String? manufacturer;
  final Uri avTransport;
  final Uri? renderingControl;

  CastDevice({
    required this.id,
    required this.name,
    this.model,
    this.manufacturer,
    required this.avTransport,
    this.renderingControl,
  });

  /// Altavoces WiiMu/LinkPlay (GGMM, Arylic, Audio Pro…): su DLNA se cuelga con Play en firmwares
  /// antiguos, así que se controlan con su API HTTP propia.
  bool get isLinkPlay {
    final text = '${manufacturer ?? ''} ${model ?? ''}'.toLowerCase();
    return text.contains('wiimu') || text.contains('linkplay');
  }
}

/// Canal nativo: multicast lock (sin él Android descarta el SSDP) y servicio en primer plano
/// que mantiene viva la app, el WiFi y el servidor mientras se envía audio.
class CastNative {
  static const MethodChannel _channel = MethodChannel('soundlife/cast');
  static VoidCallback? onStopRequested;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') onStopRequested?.call();
    });
  }

  static Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // No Android
    } catch (e) {
      // Un fallo del canal nativo no debe impedir buscar ni reproducir
      debugPrint('cast $method: $e');
    }
  }

  static Future<void> multicastLock(bool acquire) => _invoke('multicastLock', {'acquire': acquire});
  static Future<void> startService(String deviceName) => _invoke('startService', {'name': deviceName});
  static Future<void> stopService() => _invoke('stopService');
  static Future<void> requestNotificationPermission() => _invoke('requestNotificationPermission');
}

class CastDiscovery {
  static final InternetAddress _ssdpGroup = InternetAddress('239.255.255.250');
  static const List<String> _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
  ];

  /// Busca reproductores durante [timeout]; emite cada uno en cuanto responde.
  static Stream<CastDevice> discover({Duration timeout = const Duration(seconds: 5)}) {
    final controller = StreamController<CastDevice>();
    final seenLocations = <String>{};
    final seenIds = <String>{};
    RawDatagramSocket? socket;
    Timer? timer;
    final pending = <Future>[];

    Future<void> close() async {
      timer?.cancel();
      socket?.close();
      await Future.wait(pending);
      await CastNative.multicastLock(false);
      if (!controller.isClosed) await controller.close();
    }

    Future<void> start() async {
      await CastNative.multicastLock(true);
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (e) {
        controller.addError(e);
        await close();
        return;
      }
      var received = 0;
      socket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        received++;
        final location = _header(utf8.decode(datagram.data, allowMalformed: true), 'location');
        if (location == null || !seenLocations.add(location)) return;
        pending.add(_describe(Uri.parse(location)).then((device) {
          if (device != null && seenIds.add(device.id) && !controller.isClosed) controller.add(device);
        }));
      });
      // Varios envíos: el UDP se pierde con facilidad
      var sent = 0;
      for (var i = 0; i < 3; i++) {
        for (final st in _searchTargets) {
          final msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: $st\r\n\r\n';
          if (await _send(socket, utf8.encode(msg))) sent++;
        }
        await Future.delayed(const Duration(milliseconds: 400));
      }
      debugPrint('SSDP: $sent/${3 * _searchTargets.length} búsquedas enviadas');
      timer = Timer(timeout, () {
        debugPrint('SSDP: $received respuestas, ${seenIds.length} reproductores');
        close();
      });
    }

    controller.onCancel = close;
    start();
    return controller.stream;
  }

  /// send() es no bloqueante y devuelve 0 si el búfer está lleno, por ejemplo cuando el WiFi va
  /// cargado porque un altavoz está descargando un audio del móvil: se reintenta hasta que sale.
  static Future<bool> _send(RawDatagramSocket? socket, List<int> data) async {
    for (var attempt = 0; attempt < 40 && socket != null; attempt++) {
      try {
        if (socket.send(data, _ssdpGroup, 1900) > 0) return true;
      } on SocketException catch (e) {
        debugPrint('SSDP send: $e');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// Vuelve a localizar un dispositivo conocido (su puerto puede haber cambiado: pasa en LinkPlay/GGMM).
  static Future<CastDevice?> find(String id, {Duration timeout = const Duration(seconds: 4)}) async {
    await for (final device in discover(timeout: timeout)) {
      if (device.id == id) return device;
    }
    return null;
  }

  static String? _header(String response, String name) {
    for (final line in response.split('\r\n')) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim().toLowerCase() == name) return line.substring(i + 1).trim();
    }
    return null;
  }

  /// Lee la descripción del dispositivo y localiza sus servicios AVTransport y RenderingControl.
  static Future<CastDevice?> _describe(Uri location) async {
    try {
      final response = await http.get(location).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      final doc = XmlDocument.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
      final base = _text(doc.rootElement, 'URLBase');
      final baseUri = base != null && base.isNotEmpty ? Uri.parse(base) : location;

      // El reproductor puede estar anidado (Sonos: ZonePlayer → MediaRenderer)
      for (final device in doc.findAllElements('device')) {
        Uri? av;
        Uri? rc;
        for (final service in device.getElement('serviceList')?.findElements('service') ?? <XmlElement>[]) {
          final type = _text(service, 'serviceType') ?? '';
          final url = _text(service, 'controlURL');
          if (url == null) continue;
          if (type.contains(':AVTransport:')) av = baseUri.resolve(url);
          if (type.contains(':RenderingControl:')) rc = baseUri.resolve(url);
        }
        if (av == null) continue;

        final root = doc.rootElement.getElement('device');
        final name = _text(root ?? device, 'roomName') ?? // Sonos
            _text(root ?? device, 'friendlyName') ??
            _text(device, 'friendlyName') ??
            location.host;
        return CastDevice(
          id: _text(device, 'UDN') ?? location.toString(),
          name: name,
          model: _text(root ?? device, 'modelName'),
          manufacturer: _text(root ?? device, 'manufacturer'),
          avTransport: av,
          renderingControl: rc,
        );
      }
    } catch (e) {
      debugPrint('DLNA describe $location: $e');
    }
    return null;
  }

  static String? _text(XmlElement parent, String name) => parent.getElement(name)?.innerText.trim();
}

/// Servidor HTTP en el móvil para que los reproductores descarguen audios y carátulas.
/// Solo sirve los ficheros registrados, con rutas de token aleatorio.
class MediaServer {
  MediaServer._();
  static final MediaServer instance = MediaServer._();

  HttpServer? _server;
  String? _host;
  final Map<String, File> _files = {};
  final Map<String, String> _names = {}; // ruta → nombre publicado
  final Random _random = Random.secure();

  static const Map<String, String> _mime = {
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'flac': 'audio/flac',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
  };

  static String mimeOf(String path) => _mime[path.split('.').last.toLowerCase()] ?? 'application/octet-stream';

  /// IP del WiFi, o null si no hay red local.
  static Future<String?> wifiAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    InternetAddress? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.isLoopback || addr.isLinkLocal) continue;
        if (iface.name.startsWith('wlan')) return addr.address;
        fallback ??= addr;
      }
    }
    return fallback?.address;
  }

  Future<void> start() async {
    _host = await wifiAddress();
    if (_host == null) throw const SocketException('Sin WiFi');
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handle, onError: (e) => debugPrint('MediaServer: $e'));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _files.clear();
    _names.clear();
  }

  /// Registra un fichero y devuelve su URL en la red local.
  Uri publish(String path) {
    final name = _names.putIfAbsent(path, () {
      final token = List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();
      return '$token.${path.split('.').last.toLowerCase()}';
    });
    _files[name] = File(path);
    return Uri(scheme: 'http', host: _host, port: _server!.port, path: '/m/$name');
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    try {
      final segments = request.uri.pathSegments;
      final file = segments.length == 2 && segments[0] == 'm' ? _files[segments[1]] : null;
      if (file == null || !await file.exists() || (request.method != 'GET' && request.method != 'HEAD')) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }

      final length = await file.length();
      res.headers
        ..contentType = ContentType.parse(mimeOf(file.path))
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        // Cabeceras DLNA que exigen algunas TV (Samsung, LG)
        ..set('transferMode.dlna.org', 'Streaming')
        ..set('contentFeatures.dlna.org', 'DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000');

      var start = 0;
      var end = length - 1;
      final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (range != null) {
        if (range.group(1)!.isNotEmpty) start = int.parse(range.group(1)!);
        if (range.group(2)!.isNotEmpty) end = min(int.parse(range.group(2)!), length - 1);
        if (range.group(1)!.isEmpty && range.group(2)!.isNotEmpty) {
          start = max(0, length - int.parse(range.group(2)!));
          end = length - 1;
        }
        if (start > end || start >= length) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      res.contentLength = end - start + 1;

      if (request.method == 'HEAD') {
        await res.close();
      } else {
        await res.addStream(file.openRead(start, end + 1));
        await res.close();
      }
    } catch (e) {
      // El reproductor suele cortar la conexión al buscar o parar: no es un error
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// Control de un reproductor remoto. Estados de [transportState] con la nomenclatura UPnP:
/// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING, NO_MEDIA_PRESENT…
abstract class CastRenderer {
  CastDevice get device;

  factory CastRenderer.forDevice(CastDevice device) =>
      device.isLinkPlay ? LinkPlayRenderer(device) : DlnaRenderer(device);

  /// Prepara el audio sin reproducirlo.
  Future<void> load(SoundItem sound);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// [volume] 0.0–1.0 → volumen del altavoz 0–100 (como su botón físico).
  Future<void> setVolume(double volume);
  Future<String> transportState();

  /// Si es true, consultar el estado durante la reproducción provoca cortes de sonido
  /// (probado de oído en el GGMM E2 con WAV): solo se consulta al final previsto del audio.
  bool get quietPolling;

  /// Posición y duración del audio actual, si el dispositivo las da.
  Future<({Duration position, Duration total})?> progress();
}

/// Control SOAP de un reproductor DLNA.
class DlnaRenderer implements CastRenderer {
  @override
  final CastDevice device;
  DlnaRenderer(this.device);

  static const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _rc = 'urn:schemas-upnp-org:service:RenderingControl:1';

  Future<XmlDocument> _soap(Uri url, String service, String action, Map<String, String> args) async {
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>')
      ..write('<u:$action xmlns:u="$service">');
    args.forEach((k, v) => body.write('<$k>${_escape(v)}</$k>'));
    body.write('</u:$action></s:Body></s:Envelope>');

    final response = await http
        .post(url,
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPACTION': '"$service#$action"',
            },
            body: utf8.encode(body.toString()))
        .timeout(const Duration(seconds: 6));
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) {
      throw HttpException('$action ${response.statusCode}: ${_faultOf(text)}');
    }
    return XmlDocument.parse(text);
  }

  static String _faultOf(String text) {
    final m = RegExp(r'<errorDescription>(.*?)</errorDescription>').firstMatch(text) ??
        RegExp(r'<errorCode>(.*?)</errorCode>').firstMatch(text);
    return m?.group(1) ?? 'error';
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String _didl(SoundItem sound, Uri audio, Uri? cover) {
    final mime = MediaServer.mimeOf(sound.filePath);
    final art = cover == null ? '' : '<upnp:albumArtURI>${_escape(cover.toString())}</upnp:albumArtURI>';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>${_escape(sound.displayName)}</dc:title>'
        '<dc:creator>Sound and Life</dc:creator>'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '$art'
        '<res protocolInfo="http-get:*:$mime:*">${_escape(audio.toString())}</res>'
        '</item></DIDL-Lite>';
  }

  @override
  Future<void> load(SoundItem sound) async {
    final server = MediaServer.instance;
    final audio = server.publish(sound.filePath);
    final coverPath = sound.coverPath;
    final cover = coverPath != null && File(coverPath).existsSync() ? server.publish(coverPath) : null;
    await _soap(device.avTransport, _avt, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': audio.toString(),
      'CurrentURIMetaData': _didl(sound, audio, cover),
    });
  }

  @override
  bool get quietPolling => false;

  @override
  Future<({Duration position, Duration total})?> progress() async => null;

  @override
  Future<void> play() => _soap(device.avTransport, _avt, 'Play', {'InstanceID': '0', 'Speed': '1'});
  @override
  Future<void> pause() => _soap(device.avTransport, _avt, 'Pause', {'InstanceID': '0'});
  @override
  Future<void> stop() => _soap(device.avTransport, _avt, 'Stop', {'InstanceID': '0'});

  @override
  Future<void> setVolume(double volume) async {
    final rc = device.renderingControl;
    if (rc == null) return;
    await _soap(rc, _rc, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': (volume.clamp(0.0, 1.0) * 100).round().toString(),
    });
  }

  @override
  Future<String> transportState() async {
    final doc = await _soap(device.avTransport, _avt, 'GetTransportInfo', {'InstanceID': '0'});
    return doc.findAllElements('CurrentTransportState').firstOrNull?.innerText.trim() ?? 'UNKNOWN';
  }
}

/// Altavoces WiiMu/LinkPlay mediante su API HTTP (`/httpapi.asp?command=…`), la misma que usan
/// sus apps oficiales. Responde en Latin-1 y su JSON puede traer bytes de control en el título,
/// así que los campos se leen con expresiones regulares.
class LinkPlayRenderer implements CastRenderer {
  @override
  final CastDevice device;
  LinkPlayRenderer(this.device);

  Uri? _pending; // audio cargado y aún no enviado

  @override
  bool get quietPolling => true;

  @override
  Future<({Duration position, Duration total})?> progress() async {
    final status = await _cmd('getPlayerStatus');
    final pos = int.tryParse(_field(status, 'curpos') ?? '');
    final total = int.tryParse(_field(status, 'totlen') ?? '');
    if (pos == null || total == null || total <= 0) return null;
    return (position: Duration(milliseconds: pos), total: Duration(milliseconds: total));
  }

  Future<String> _cmd(String command) async {
    final url = Uri.parse('http://${device.avTransport.host}/httpapi.asp?command=$command');
    final response = await http.get(url).timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) throw HttpException('LinkPlay $command: ${response.statusCode}');
    return latin1.decode(response.bodyBytes);
  }

  static String? _field(String json, String key) => RegExp('"$key"\\s*:\\s*"([^"]*)"').firstMatch(json)?.group(1);

  @override
  Future<void> load(SoundItem sound) async => _pending = MediaServer.instance.publish(sound.filePath);

  @override
  Future<void> play() async {
    final pending = _pending;
    _pending = null;
    await _cmd(pending != null
        ? 'setPlayerCmd:play:${Uri.encodeComponent(pending.toString())}'
        : 'setPlayerCmd:resume');
  }

  @override
  Future<void> pause() => _cmd('setPlayerCmd:pause');

  @override
  Future<void> stop() async {
    _pending = null;
    await _cmd('setPlayerCmd:stop');
  }

  @override
  Future<void> setVolume(double volume) => _cmd('setPlayerCmd:vol:${(volume.clamp(0.0, 1.0) * 100).round()}');

  @override
  Future<String> transportState() async {
    if (_pending != null) return 'STOPPED';
    switch (_field(await _cmd('getPlayerStatus'), 'status')) {
      case 'play':
        return 'PLAYING';
      case 'pause':
        return 'PAUSED_PLAYBACK';
      case 'load':
        return 'TRANSITIONING';
      case 'stop':
        return 'STOPPED';
      default:
        return 'UNKNOWN';
    }
  }
}
