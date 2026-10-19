# Ficha de la Mac App Store (español de España)

## Nombre
FluFlu

## Subtítulo (máx. 30)
Dicta y pega en cualquier app

## Texto promocional (máx. 170)
Mantén pulsada una tecla, habla y suelta: FluFlu escribe por ti en cualquier app, con el texto ya limpio de muletillas y bien puntuado.

## Descripción
FluFlu es dictado para el Mac pensado para escribir rápido en cualquier sitio: correo, chat, documentos, el navegador o el editor de código.

Cómo funciona:
• Mantén pulsada la tecla de dictado (Opción derecha por defecto), habla y suéltala. El texto aparece donde estés escribiendo.
• Un toque para dictar con las manos libres; otro toque lo termina.
• Tu voz se reconoce en el propio Mac con el motor de Apple. El audio nunca sale del equipo.
• Si quieres, FluFlu pule el texto con un modelo de lenguaje en Ollama Cloud, con tu propia cuenta: quita muletillas («eh», «o sea»), corrige la puntuación, respeta tus rectificaciones («a Juan, no, perdón, a Marta») y escribe bien los nombres de tu vocabulario.

Privacidad primero:
• Nada sale del Mac sin tu consentimiento explícito. Sin él, FluFlu pega el texto tal como lo reconoce el Mac.
• Sin cuentas de FluFlu, sin analítica, sin publicidad.
• Tu clave de Ollama se guarda en el llavero de macOS.

Requisitos:
• macOS 26 o posterior.
• Para la limpieza del texto, una cuenta de Ollama con clave de API (ollama.com). El dictado funciona también sin ella.
• Idiomas de dictado: español, inglés, francés, alemán, italiano y portugués.

Nota: en la versión de la Mac App Store la tecla de dictado también llega a la app activa; elige en Ajustes una que no use otra app.

## Palabras clave (máx. 100)
dictado,voz a texto,transcripción,dictar,teclado,productividad,escribir,voz,notas,micrófono

## URL de soporte
https://github.com/infantesromeroadrian/fluflu/issues

## URL de marketing
https://github.com/infantesromeroadrian/fluflu

## URL de la política de privacidad
https://github.com/infantesromeroadrian/fluflu/blob/main/PRIVACY.md

## Categoría
Productividad (secundaria: Utilidades)

## Copyright
© 2026 Adrián Infantes

## Notas para el revisor (App Review Information)
FluFlu is a push-to-talk dictation utility that lives in the menu bar (no Dock icon).

How to test:
1. On first launch a welcome window asks for Microphone, Input Monitoring and the post-events permission (shown by macOS under Accessibility), an Ollama Cloud API key and explicit consent to send text to Ollama Cloud.
2. Grant the permissions in System Settings when prompted. Paste the demo Ollama API key below in the "Clave de Ollama Cloud" field and tick the consent checkbox. Click "Empezar a dictar".
3. Open TextEdit, press and HOLD the RIGHT Option key, say a sentence (Spanish or English; the language is chosen in Settings → Dictado → Idioma), then release the key. The cleaned text is pasted at the cursor.
   Without a key or without consent, FluFlu still works: it pastes the raw transcription.

Why these permissions (sandboxed, no Accessibility API):
• Microphone: to capture the dictation while the key is held.
• Input Monitoring (CGRequestListenEventAccess): a listen-only CGEventTap detects the dictation key from any app. Events are never modified or consumed.
• Post events (CGRequestPostEventAccess; macOS lists this permission in the Accessibility pane): to paste the transcribed text into the frontmost app by posting Command-V, which is the core feature of a dictation tool. FluFlu does not use the Accessibility API (AXUIElement / AXIsProcessTrusted) and does not read or control other apps' UI.
• Network (client): only to call the Ollama Cloud API with the user's own key, after explicit consent (guideline 5.1.2(i)). Speech recognition runs on device with Apple's SpeechAnalyzer; audio never leaves the Mac.

Demo Ollama API key (valid during review only): [ADRIÁN LA PEGA AQUÍ]
