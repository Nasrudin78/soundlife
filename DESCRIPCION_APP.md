# SoundLife: qué hace la app

SoundLife es una app Flutter (pensada sobre todo para Android) que reproduce los audios de **Sound and Life** (soundandlife.com) guardados en el móvil. Los audios aparecen en una rejilla con su carátula y cada uno tiene su propio volumen y su modo de repetición. La idea es usarla de noche o en sesiones de relajación sin tener que tocar el volumen cada vez.

## Uso

1. **Añadir audios**: con el botón de carpeta (o "Seleccionar Archivos" si la lista está vacía) se eligen uno o varios ficheros `mp3`, `wav`, `m4a`, `flac` o `aac`.
   Los ficheros se mueven a una carpeta propia de la app (`sounds/`), porque Android puede vaciar la caché. Mientras se importan, arriba pone "Importando archivos…" y se ven tarjetas grises que parpadean mientras cargan.
2. **Detectar el código**: la app busca en el nombre del fichero un código `BA` seguido de un número (`BA-07 rescate`, `BA 50`, `ba_9`…) y lo normaliza a `BA07`, `BA50` o `BA09`.
3. **Nombre y carátula**: con ese código busca el producto en soundandlife.com. Guarda su **nombre**, que se muestra en minúsculas salvo el código (por ejemplo "BA07 rescate – ansiedad") en toda la app y en la notificación, y **descarga la imagen al móvil** (`covers/`), así que en modo avión también se ve. Si no lo encuentra en la web, muestra el nombre del fichero. Busca 4 sonidos a la vez y cada tarjeta se actualiza en cuanto llega su información. Arriba se ve "Cargando carátulas y nombres x/y". El botón ⟳ vuelve a descargarlo todo.
4. **Tocar una tarjeta**: reproduce el audio. Si se toca otra vez, se para, o se reanuda si estaba en pausa. Solo suena un audio a la vez. La barra de abajo tiene **Pausa/Reanudar** y **Stop**, que funcionan para todo.
5. **Mantener pulsada una tarjeta**: abre el *preset* de ese sonido.
   - **Volumen** (0–100 %, en pasos del 5 %): fija el **volumen multimedia del dispositivo**, igual que los botones físicos. 0 % es silencio y 100 % es el máximo del móvil. Los sonidos nuevos empiezan al **10 %**. Si el audio está sonando, el cambio se oye al mover el deslizador.
   - **Loop mode**: al terminar, el audio vuelve a empezar.
6. **Colas** (botón ☰♪): encadenan sonidos, por ejemplo *BA07 ×1 → BA09 ×2 → BA07 ×N → BA50 ∞*.
   - Cada paso tiene su número de repeticiones. Solo el **último** puede quedarse en bucle infinito (∞).
   - Los pasos se reordenan arrastrándolos. Deslizando una cola hacia la izquierda se borra, y se puede deshacer.
   - Al empezar cada paso se aplica el volumen del preset de su sonido. Dentro de un mismo paso (sus repeticiones) no se vuelve a aplicar, por si has cambiado el volumen a mano. El *Loop mode* del preset no se usa en las colas: lo que manda son las repeticiones de cada paso.
   - Mientras suena, la barra de abajo muestra, por ejemplo, "Paso 2/4 · 1/2" y tiene un botón para saltar al paso siguiente.

7. **Enviar a otro dispositivo** (botón cast): ver la sección de abajo.
8. **Menú ⋮**: "Actualizar carátulas y nombres" y la versión instalada, que se lee de `pubspec.yaml`. La barra de arriba muestra solo "SoundLife".

## Pantalla apagada y modo avión

- La reproducción corre como **servicio de Android en primer plano** (`just_audio` + `just_audio_background`), con su notificación y controles en la pantalla de bloqueo. Sigue sonando con la pantalla apagada.
- El reproductor recibe la cola entera de golpe: el paso de un audio al siguiente lo hace él mismo, sin cortes y sin depender de que la interfaz esté abierta.
- No necesita internet: los audios y las carátulas están guardados en el móvil.

## Enviar a otros dispositivos (Sonos, Smart TV, GGMM…)

Con el móvil conectado al **WiFi de casa** (no hace falta internet), el botón cast busca durante unos segundos los reproductores **DLNA/UPnP** de la red. Sonos, la mayoría de Smart TV y altavoces LinkPlay como el GGMM E2 lo son.
- **Sonos, TV y demás DLNA**: se controlan por DLNA (SOAP: `SetAVTransportURI`, `Play`, `SetVolume`…).
- **Altavoces WiiMu/LinkPlay** (como el GGMM E2): se reconocen por el fabricante que anuncian y se controlan con **su API HTTP propia** (`/httpapi.asp?command=setPlayerCmd:…`). Es la misma que usan sus apps oficiales. Su DLNA se cuelga al recibir `Play` en firmwares antiguos: comprobado en el GGMM, firmware 4.2.7124 de 2019.
- Al elegir uno, lo que suena pasa a ese dispositivo desde el principio del audio actual, con su título y su carátula. Con "Este móvil" vuelve al teléfono.
- **Volumen**: el preset (0–100 %) fija el volumen del altavoz, que es el equivalente a su botón físico. En las colas se aplica al empezar cada paso, igual que en el móvil.
- **Cómo funciona**: el móvil hace de servidor. Un servidor HTTP interno sirve solo los audios y carátulas que se envían, con rutas de token aleatorio. El altavoz los descarga desde ahí.
  - Mientras tanto, una notificación "Enviando a <dispositivo>" (con botón Detener) mantiene la app, el WiFi y el servidor activos con la pantalla apagada.
  - Por eso el móvil tiene que seguir encendido y en el WiFi.
- **Colas y loop**: estos dispositivos reciben un fichero cada vez. Al terminar un audio, la app envía el siguiente (o el mismo, si está en bucle). Entre repeticiones hay **un pequeño silencio** (~1–2 s) que no existe en el móvil.
  - **Sonos y DLNA**: la app consulta su estado cada segundo.
  - **LinkPlay/GGMM**: la app **no consulta nada mientras suena**, porque cada consulta le provoca cortes de sonido. Se comprobó de oído con un WAV de 24 bits: sin consultas sonó limpio y con consultas cada segundo, con trompicones. La app calcula cuándo termina el audio (en los WAV lo lee exactamente de su cabecera; en otros formatos hace una sola consulta al principio) y solo pregunta en ese momento. Si el audio se pausa desde el propio altavoz, la app no se entera hasta ese momento.
- Si el altavoz deja de responder, la app lo **vuelve a buscar** y reintenta: los altavoces LinkPlay como el GGMM cambian a veces de puerto. Si no aparece (está apagado o se ha perdido el WiFi), la reproducción se para, vuelve a "Este móvil" y la app lo avisa.
- La búsqueda reintenta el envío cuando el WiFi va cargado, por ejemplo mientras un altavoz descarga un audio grande. El dispositivo al que estás conectado aparece siempre en la lista.
- **Uso pensado**: de día. De noche, en modo avión, suena en el móvil o en un altavoz **Bluetooth** emparejado. El Bluetooth no necesita nada especial: Android le envía el audio y el preset controla su volumen.
- **AirPlay y Chromecast** no están soportados.

## Arquitectura

| Archivo | Qué hace |
|---|---|
| `lib/main.dart` | Pantalla principal (rejilla, importación, diálogo de preset) y descarga de carátulas |
| `lib/playback.dart` | `PlaybackController`: único reproductor, en el móvil (`just_audio`) o en un dispositivo DLNA. Sonidos sueltos y colas, pausa y stop |
| `lib/queues.dart` | Lista de colas y editor de pasos |
| `lib/widgets.dart` | Tarjetas, carátulas con carga animada, esqueletos y barra de reproducción |
| `lib/files.dart` | Guarda audios y carátulas en el almacenamiento de la app |
| `lib/models.dart` | `SoundItem` (ruta, código BA, nombre de la web, carátula, volumen, loop), `SoundQueue` y `QueueStep` |
| `lib/storage.dart` | Guarda sonidos (`sound_items_v1`) y colas (`sound_queues_v1`) en `SharedPreferences` como JSON |
| `lib/scraper.dart` | Detecta el código BA y saca de soundandlife.com el nombre y la carátula del producto (de los resultados de búsqueda o de la ficha) |
| `lib/volume.dart` | `DeviceVolume`: canal `soundlife/volume` hacia el código nativo |
| `lib/cast.dart` | Búsqueda SSDP de reproductores, servidor HTTP local (`MediaServer`) y control remoto (`CastRenderer`): `DlnaRenderer` (SOAP) y `LinkPlayRenderer` (API HTTP de LinkPlay) |
| `android/.../CastService.kt` | Servicio en primer plano (`connectedDevice`) mientras se envía audio, con los bloqueos de WiFi y de CPU |
| `android/.../MainActivity.kt` | Hereda de `AudioServiceActivity`. Canal de volumen (`AudioManager.setStreamVolume(STREAM_MUSIC, …)`) y canal `soundlife/cast` (bloqueo multicast, servicio y permiso de notificaciones) |

## Permisos de Android

- `INTERNET`: carátulas, y el servidor y el control DLNA.
- `READ_EXTERNAL_STORAGE` y `READ_MEDIA_AUDIO`: audios locales.
- `WAKE_LOCK`, `FOREGROUND_SERVICE` y `FOREGROUND_SERVICE_MEDIA_PLAYBACK`: reproducción con la pantalla apagada.
- `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE`, `CHANGE_WIFI_MULTICAST_STATE` y `FOREGROUND_SERVICE_CONNECTED_DEVICE`: enviar a dispositivos DLNA.
- `POST_NOTIFICATIONS`: la notificación "Enviando a…". Se pide al conectar por primera vez.
- `usesCleartextTraffic`: el móvil y el altavoz hablan por HTTP dentro de la red local.

## Limitaciones conocidas

- El control del volumen del dispositivo solo existe en Android. En las demás plataformas el preset no cambia el volumen.
- La carátula depende del HTML de soundandlife.com. Si la web cambia de estructura, habrá que ajustar `scraper.dart`.
- Las colas guardan cada sonido por su nombre de fichero. Si un sonido desaparece, ese paso se salta.
- Todavía no se pueden borrar sonidos desde la app, y no hay temporizador de apagado.
- Al enviar a DLNA hay un pequeño silencio entre repeticiones y pasos. Cambiar de dispositivo reinicia el audio actual desde el principio.
