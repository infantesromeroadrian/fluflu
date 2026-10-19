# FluFlu

Dictado push-to-talk nativo para macOS, pensado como sustituto de Wispr Flow sin suscripción.
Mantienes pulsada una tecla, hablas, la sueltas y el texto limpio aparece en la app activa.

Licencia [MIT](LICENSE). Versión para Linux (Hyprland): [fluflu-linux](https://github.com/infantesromeroadrian/fluflu-linux).

## Instalar

Requisitos: macOS 26 o superior en un Mac con Apple Silicon, y una cuenta de [Ollama](https://ollama.com)
con clave de API para pulir el texto (planes y precios en https://ollama.com/pricing).

1. Descarga `FluFlu-<versión>.dmg` de la [última versión](https://github.com/infantesromeroadrian/fluflu/releases/latest).
   Opcional: comprueba que `shasum -a 256 FluFlu-<versión>.dmg` coincide con el `.sha256` publicado al lado.
2. Abre el `.dmg` y arrastra **FluFlu** a **Aplicaciones**.
3. Abre FluFlu desde Aplicaciones. La app está firmada con Developer ID y notarizada por Apple; macOS solo
   pide confirmar que quieres abrir una app descargada de internet.
4. La ventana de bienvenida te guía por los permisos de **Micrófono** y **Accesibilidad**, la **clave de
   Ollama Cloud** (enlace para crearla en https://ollama.com/settings/keys) y el **consentimiento** para enviar
   el texto a Ollama Cloud. Puedes volver a abrirla desde el menú: *Bienvenida y permisos…*.
5. En cualquier app: mantén pulsada **Opción derecha**, habla y suéltala. Doble pulsación para dictar sin
   sujetar la tecla; otra pulsación lo termina. Idioma, micrófono, tecla y vocabulario se cambian en *Ajustes…*.

## Privacidad

- **El audio no sale del Mac.** Lo reconoce el motor de voz de Apple en el propio equipo y no se guarda.
- **El texto sale solo si lo aceptas.** Con la limpieza activada y tu consentimiento, FluFlu envía por HTTPS
  a ollama.com el texto reconocido, tu vocabulario y las instrucciones de limpieza, con tu propia clave. Ollama
  lo trata según su política de privacidad: https://ollama.com/privacy. Sin consentimiento no sale ninguna
  petición y se pega el texto tal como lo reconoce el Mac. Lo mismo si en Ajustes apuntas a otro servidor de
  Ollama: solo uno en este mismo Mac (`localhost`) no pide consentimiento.
- **El autor de FluFlu no recibe nada**: no hay servidor propio, analítica ni telemetría.
- **La clave** se guarda en el llavero de macOS, nunca en las preferencias ni en el registro.
- **El portapapeles** se usa un instante para pegar, solo en este Mac (no pasa a tus otros dispositivos por el
  Portapapeles Universal) y marcado para que los gestores de historial no lo guarden. Si contenía texto plano,
  se restaura; el formato y otro contenido (una imagen, un fichero) no se conservan.
- **El registro de diagnóstico** (`~/Library/Logs/FluFlu/FluFlu.log`) guarda fases, tiempos y número de
  caracteres, no el texto dictado.
- **Retirar el permiso**: desmarca *Enviar el texto dictado a Ollama Cloud* en Ajustes, borra la clave
  (deja el campo vacío y guarda) y revócala en https://ollama.com/settings/keys.

## Desinstalar

1. Sal de FluFlu desde su menú y arrastra la app de Aplicaciones a la Papelera.
2. Opcional, para no dejar rastro: borra la entrada `com.adrianinfantes.FluFlu` en *Acceso a Llaveros*,
   ejecuta `defaults delete com.adrianinfantes.FluFlu`, elimina `~/Library/Logs/FluFlu` y quita FluFlu de
   *Ajustes del Sistema → Privacidad y seguridad → Micrófono / Accesibilidad*.

---

# Desarrollo

## Cómo funciona

1. **Tecla de dictado** (Opción derecha por defecto, cambiable en Ajustes) con tres gestos: mantener pulsada dicta hasta soltar; doble pulsación deja el dictado fijo con las manos libres; una pulsación durante el dictado fijo lo termina. Un tap de CGEvent consume el atajo para que la app activa no lo reciba.
2. **Captura** del micrófono con `AVCaptureSession`, que respeta el micrófono elegido en Ajustes (`AVAudioEngine` sigue siempre la entrada por defecto del sistema, y un auricular Bluetooth que se vuelve predeterminado deja los dictados vacíos).
3. **Transcripción on-device** con `SpeechAnalyzer` + `SpeechTranscriber` de Apple (macOS 26+). El audio no sale del Mac.
4. **Limpieza opcional** del texto con un modelo de Ollama (Cloud o local): muletillas, puntuación, nombres propios del vocabulario.
5. **Inserción** en la app activa vía portapapeles y ⌘V simulado; el portapapeles anterior se restaura.

Un fallo en la limpieza nunca pierde el dictado: se pega el texto bruto y la HUD lo avisa.

## Requisitos

- macOS 26 o superior (el proyecto se ha creado en macOS 27.2 con Xcode 27).
- Apple Silicon recomendado.
- Para la limpieza en la nube: cuenta de Ollama con clave de API (`ollama signin` o https://ollama.com/settings/keys).

## Compilar e instalar desde el código

```sh
cd FluFlu
xcodebuild -project FluFlu.xcodeproj -scheme FluFlu -configuration Release -destination 'platform=macOS' build
ditto ~/Library/Developer/Xcode/DerivedData/FluFlu-*/Build/Products/Release/FluFlu.app /Applications/FluFlu.app
open /Applications/FluFlu.app --args --enable-launch-at-login
```

El argumento `--enable-launch-at-login` registra la app como elemento de inicio de sesión (`SMAppService`) solo
cuando vive en `/Applications`; después se gestiona con el interruptor *Abrir FluFlu al iniciar sesión* de Ajustes
o desde Ajustes del Sistema > General > Ítems de inicio. La firma es la misma que en desarrollo, así que los
permisos de Accesibilidad y Micrófono y la clave del llavero se conservan.

## Primer arranque desde Xcode

Al ejecutar el esquema `FluFlu` sin preferencias guardadas se abre la misma bienvenida que ve un usuario.
El modelo de voz del idioma se descarga en segundo plano al arrancar; el primer dictado puede tardar unos
segundos más mientras termina. Los atajos se cambian en *Ajustes → Atajos*: pulsa el campo y teclea otra
combinación (⎋ cancela); una tecla sola necesita modificador salvo F1–F19, y las modificadoras solas también valen.

## Publicar una versión

```sh
cd FluFlu
scripts/release.sh --dry-run   # ensayo: firma de desarrollo, sin notarizar
scripts/release.sh             # release: Developer ID + notarización de la app y del .dmg
```

La release necesita en el llavero el certificado *Developer ID Application* del equipo `G2W8J5Z5HS` y un
perfil de notarización (`xcrun notarytool store-credentials FluFlu-notary --apple-id … --team-id G2W8J5Z5HS`).
El script pasa los tests, hace archive y export, notariza y grapa la app, crea y firma el `.dmg`, lo notariza,
lo grapa, lo comprueba con Gatekeeper (`spctl`) y deja el `.dmg` y su `.sha256` en `build/release-<build>/`
junto a `release.log`. El número de build es la fecha y hora, así que siempre crece.
El icono se genera con `swift scripts/render-icon.swift <salida.png>` y se escala con `sips` a los tamaños de
`AppIcon.appiconset`.

## Estructura

```
FluFlu/FluFlu/
  App/         FluFluApp (MenuBarExtra + Settings)
  Dictation/   DictationPhase + DictationReducer (fases), DictationGesture (mantener / doble pulsación / terminar), DictationController
  Hotkey/      KeyShortcut + KeyLabels (modelo), ShortcutEngine (puro), GlobalShortcutTap (CGEvent tap)
  Audio/       AudioIngress (cola acotada), MicrophoneRecorder
  Speech/      SpeechEngine (contrato), AppleSpeechEngine, AnalyzerInputConverter
  Cleanup/     CleanupPrompt (prompt versionado), OllamaClient, TranscriptCleaner, CleanupGuard, AppleTranscriptCleaner (no se ofrece)
  Insertion/   TextInserter
  Settings/    AppSettings, CleanupEngine, KeychainStore, OllamaEndpoint, LaunchAtLogin
  Diagnostics/ AppLog (Consola + fichero con rotación)
  UI/          MenuBarView, SettingsView, OnboardingView, ShortcutRecorderField, DictationHUD
FluFlu/FluFluTests/   Swift Testing: reducer, gestos de la tecla, atajos (modelo y motor), prompt, parser de respuesta, request, ajustes, bienvenida y consentimiento
FluFlu/scripts/       release.sh (Developer ID + notarización), render-icon.swift
```

## Diagnóstico

Cada paso del dictado queda en `~/Library/Logs/FluFlu/FluFlu.log` (rotación a 2 MB, copia anterior en
`FluFlu.log.1`); el menú de la barra tiene *Abrir registro de diagnóstico*. Los mismos mensajes van al log
unificado, pero los de nivel `info` se pierden al cerrar la app, por eso existe el fichero.

```sh
tail -f ~/Library/Logs/FluFlu/FluFlu.log
/usr/bin/log stream --info --predicate 'subsystem == "com.adrianinfantes.FluFlu"'   # en zsh, `log` a secas es un builtin
```

## Pruebas

```sh
cd FluFlu
xcodebuild -project FluFlu.xcodeproj -scheme FluFlu -destination 'platform=macOS' test -only-testing:FluFluTests
```

## Decisiones

- **El gesto se mide con la hora del evento**: `CGEvent.timestamp` viaja hasta `DictationController`, que la convierte al reloj del gesto. Si el hilo principal está ocupado preparando el primer dictado, la suelta se procesa tarde pero sigue contando como toque, no como "mantener". El arranque de `AVCaptureSession` va a su propia cola por el mismo motivo.

- **Sin Python**: todo el pipeline es Swift; evita empaquetado, firma y latencia extra.
- **ASR local, LLM remoto**: Ollama Cloud no ofrece modelos de transcripción; el motor de Apple
  iguala o supera a Whisper en habla limpia y es gratis. Ollama solo ve texto.
- **Fuera de la Mac App Store, con Developer ID**: el permiso de Accesibilidad (tap que consume la tecla y ⌘V simulado) está prohibido dentro del App Sandbox; el soporte técnico de Apple indica Developer ID como única vía. Wispr Flow y Superwhisper se distribuyen igual en Mac. Hardened Runtime activo con un único entitlement: `com.apple.security.device.audio-input`.
- **Consentimiento antes de enviar texto**: la limpieza en Ollama Cloud no hace ninguna petición sin el consentimiento guardado (`cloudConsent`).
- **CGEvent tap en vez de `NSEvent.addGlobalMonitor`**: el monitor solo observa; el tap puede consumir el atajo. Una modificadora sola como tecla de dictado solo se consume con *Reservar la tecla para FluFlu* activado (lo está por defecto), para que su doble toque no dispare también atajos de otras apps.
- **Prompt versionado** (`cleanup-v1`): un cambio de prompt exige subir la versión para poder atribuir regresiones.

## Pendiente

- WhisperKit o Parakeet como motor alternativo detrás del protocolo `SpeechEngine`.
- Inserción por Accessibility (`AXUIElement`) para no tocar el portapapeles.
- Historial de dictados y atajo para repetir el último.
- Actualizaciones automáticas (Sparkle) e interfaz en inglés.
- Conservar en el portapapeles también contenido que no sea texto.
