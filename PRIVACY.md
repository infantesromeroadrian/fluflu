# Privacidad de FluFlu

Última actualización: 19 de octubre de 2026. Se aplica a FluFlu para macOS, tanto a la versión de la
Mac App Store como a la descarga directa desde GitHub.

FluFlu convierte tu voz en texto y lo pega en la app que estés usando. Esta página explica qué datos
toca, adónde van y cómo controlarlo.

## Lo que se queda en tu Mac

- **El audio.** Lo reconoce el motor de voz de Apple en el propio Mac y no se guarda.
- **Tus ajustes**: idioma, micrófono, tecla de dictado y vocabulario.
- **La clave de Ollama**, en el llavero de macOS. Nunca va a las preferencias ni al registro.
- **El registro de diagnóstico.** Solo guarda fases, tiempos y número de caracteres, nunca el texto dictado.

## Lo que sale de tu Mac, y solo si lo aceptas

Para pulir el texto (muletillas, puntuación, nombres propios), FluFlu puede enviarlo a
**Ollama Cloud** (ollama.com) con **tu propia cuenta y tu propia clave**. Se envían, cifrados por HTTPS:

- el texto reconocido;
- tu vocabulario;
- las instrucciones de limpieza.

Nunca se envía el audio. Ollama trata esos datos según su política: https://ollama.com/privacy.

FluFlu no envía nada sin tu **consentimiento explícito**. Lo das en la bienvenida o en *Ajustes → Limpieza
del texto*. Sin él no sale ninguna petición y se pega el texto tal como lo reconoce el Mac. Si en Ajustes apuntas
a otro servidor de Ollama, también se pide el consentimiento; solo un servidor en este mismo Mac (`localhost`)
no lo necesita.

## Lo que no hacemos

- No hay servidor propio ni cuentas de FluFlu: el autor no recibe ni ve tu texto, tu audio ni tu clave.
- No hay analítica, telemetría, publicidad ni rastreo.
- No se venden ni se comparten datos con nadie.

## El portapapeles

Para pegar, FluFlu pone el texto un instante en el portapapeles, **solo en este Mac** (no pasa a tus otros
dispositivos por el Portapapeles Universal) y marcado para que los gestores de historial no lo guarden. Si
antes había texto plano, se restaura; el formato y otro contenido (imágenes, ficheros) no se conservan.

## Permisos que pide

- **Micrófono**, para escucharte mientras dictas.
- **Teclado**, para detectar la tecla de dictado y pegar el texto:
  - en la versión de GitHub, *Accesibilidad*;
  - en la de la Mac App Store, *Monitorización de entrada* (detectar la tecla) y, en el panel *Accesibilidad*,
    el permiso para pegar. Esta versión no usa las funciones de accesibilidad ni lee otras apps.

Los puedes retirar cuando quieras en *Ajustes del Sistema → Privacidad y seguridad*.

## Cómo retirar el consentimiento o borrar tus datos

- Desmarca *Enviar el texto dictado a Ollama Cloud* en Ajustes.
- Borra la clave en Ajustes (deja el campo vacío y guarda) y revócala en https://ollama.com/settings/keys.
- Desinstalar la app no borra sus datos. Para no dejar rastro:
  - en *Acceso a Llaveros*, borra la entrada `com.adrianinfantes.FluFlu` (versión de GitHub) o
    `com.adrianinfantes.FluFlu.AppStore` (versión de la tienda);
  - en la versión de GitHub, ejecuta `defaults delete com.adrianinfantes.FluFlu` y borra `~/Library/Logs/FluFlu`;
  - en la versión de la tienda, borra la carpeta `~/Library/Containers/com.adrianinfantes.FluFlu.AppStore`,
    donde viven sus ajustes y su registro.

## Contacto

Dudas o peticiones sobre privacidad: abre un issue en https://github.com/infantesromeroadrian/fluflu/issues.
