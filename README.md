# SoundLife

App Flutter para Android que reproduce en el móvil los audios de [Sound and Life](https://soundandlife.com). Está pensada para usarla de noche, en modo avión y con la pantalla apagada.

- **Nombre y carátula de la web:** cada audio aparece con el nombre y la carátula de su producto (se reconoce por el código `BAxx` del fichero). Ambos se guardan en el móvil para usarlos sin conexión.
- **Volumen por sonido:** cada sonido tiene su preset de volumen, que fija el **volumen multimedia del dispositivo** (0 % es silencio y 100 % es el máximo). Por defecto es el 10 %.
- **Loop mode** por sonido, y **pausa y stop** para todo desde la barra de abajo.
- **Colas:** encadenan sonidos con repeticiones por paso y un bucle infinito opcional al final, por ejemplo `BA07 ×1 → BA09 ×2 → BA07 ×N → BA50 ∞`.
- **Pantalla apagada:** la reproducción corre como servicio en primer plano (`just_audio` + `just_audio_background`), con controles en la notificación y en la pantalla de bloqueo.

El funcionamiento y la arquitectura están explicados en [DESCRIPCION_APP.md](DESCRIPCION_APP.md).

## Compilar e instalar

```bash
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk   # -r conserva los sonidos y presets guardados
```

Evita `flutter install`: desinstala primero la versión anterior y **borra los datos de la app**.

## Versiones

La versión está en `pubspec.yaml` (`version: x.y.z+build`) y se ve en el menú ⋮ de la app. Se sube en cada cambio.
