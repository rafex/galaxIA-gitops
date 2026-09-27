# Estado de la PoC

> **Snapshot: 2026-09-26 23:47 (CST).** Se actualiza a mano. Cada dato sale
> de un comando corrido en ese momento (`podman ps/inspect`, `/status`,
> `/health`, `llama-bench`, `doctor.sh`); no se copia de la memoria.
> Arquitectura y porqués: [`arquitectura-poc.md`](arquitectura-poc.md).

## En una línea

Todo arriba y al día: Atlas ve los 5 nodos (más el navegador del Mac),
Navigator conoce a los 4 providers y **ya alcanza el OCR de la Raspi4B**,
`doctor.sh` sale sin problemas bloqueantes. El LLM es **qwen2.5-3b** (se
descartó Qwen3.5-0.8B por inventar datos) y el texto llega al navegador
mientras se genera. El portal muestra Markdown y tiene botón de copiar.

![Estado actual](diagramas/estado-actual.svg)

## Por equipo

| Equipo | Contenedores | Código desplegado | Nota |
|---|---|---|---|
| Bastion `.139` | `fhs-atlas` | Core `c1df4f5` | Mismo PeerID (identidad en volumen) |
| | `fhs-navigator` | Core `c74ef5d` | Marca a cada provider por todas sus multiaddrs (E2E-027) y recomienda KB por cobertura de la pregunta |
| | `fhs-star` | satellite-star `7d7c0bf` | Streaming real hacia el navegador; `MODEL_ID=qwen2.5-3b-instruct-q4_k_m` |
| | `llama-server` (`systemd --user`) | llama.cpp `7fe450e` compilado con PoC-Llama.cpp `8051c41` | **qwen2.5-3b-instruct** Q4_K_M, 4 hilos, 10.6 tok/s |
| Raspi4B `.167` | `fhs-satellite-ocr` | satellite-star `ebf0299` | Reconecta solo al bootstrap |
| Raspi3B `.181` | `fhs-kb-provider`, `fhs-rag-provider` | satellite-star `7d7c0bf` (sin cambios de kb/rag desde `ebf0299`) | Reconectan solos. La KB se anuncia con `KB_DESCRIPTION` ampliada (temas y artículos del texto de ejemplo) |
| ThinkPad `.239` | `fhs-portal-chat` | Core `c74ef5d` | Markdown en las respuestas, botón "Copiar", DIDs que se parten en el panel |

`mbpfan` controla el ventilador de Bastion: bajo carga sube a 5,500 RPM y
la CPU se mantiene en 90–93 °C sin perder velocidad (antes el ventilador se
quedaba en el mínimo con la CPU a 95 °C).

### `doctor.sh` desde el Mac

```
EXPECTED_PEERS=5 scripts/doctor.sh https://192.168.1.239:8443
```

Todo ✅: portal, reloj (desfase 0 s), `p2p-config.json`, Atlas `:4001`,
**6 peers en Atlas** (los 5 nodos + el navegador), Navigator `:4010` en sus
tres IPs, 1 star + 3 satellites anunciados, malla GossipSub activa. Las 5
advertencias son las excepciones de certificado autofirmado, esperadas en la
LAN.

## Qué cambió hoy y por qué

| Problema | Causa | Arreglo |
|---|---|---|
| Chat "reintentando" con red 5/5 y certificados aceptados | El portal cerraba la conexión con Navigator que acababa de elegir (libp2p reutiliza la conexión existente) — E2E-026 | Portal `464a178` |
| Un prompt tardaba >5 min | El `start-server.sh` instalado pasaba el batch como `-tb 512`: 512 hilos en 8 núcleos | Wrappers regenerados (`make post-install`) |
| Generación a 1.8 tok/s con el 3B | Perfil Ivy Bridge compilado sin AVX/F16C (SSE4.2 puro) | PoC-Llama.cpp `8051c41` (ADR-007): 10.4 tok/s con el mismo 3B |
| Respuesta completa antes de ver texto | Star bufferizaba la salida de `curl` | Star `7d7c0bf`: `fetch` con streaming, plazos por fase, mensajes OpenAI sin `$typeName` |
| OCR fuera de la red (4/5) | Imagen vieja sin reconexión al bootstrap | Recreado con `ebf0299` |
| Adjuntar un PDF fallaba: `[object ErrorEvent]` | Navigator marcaba solo la primera multiaddr del provider (`127.0.0.1`, que desde Bastion es Bastion) — E2E-027 | Navigator `c63fc3d`: prueba todas, loopback al final; errores legibles |
| La KB no se consultaba ("artículo 3 sobre la educación") | Recomendación por Jaccard sobre palabras crudas: puntaje 0 contra "Constitución Política…" | Navigator `54fb599` (cobertura sin acentos ni palabras vacías) + descripción de la KB ampliada |
| Respuestas en texto plano, sin copiar | El portal ponía la respuesta con `textContent` | Portal `c74ef5d`: Markdown armado nodo por nodo (sin `innerHTML`), botón "Copiar" |
| Se probó Qwen3.5-0.8B por velocidad | 62 tok/s leyendo prompt y 27.6 generando, pero inventa datos básicos | Vuelta a qwen2.5-3b (ver "Elección del modelo") |

### Elección del modelo

Misma batería de preguntas en español (hora, autor, capital, año de la Luna,
artículo 3), binario con AVX, 4 hilos:

| Modelo | tok/s | Datos correctos (de 4) |
|---|---|---|
| Qwen3-0.6B | 42 | 1 ("Rogerswell", "Sydney") |
| Qwen3.5-0.8B | 27 | 1 ("Sydney", "2012") |
| qwen2.5-1.5b-instruct | 20 | 3 (falla el artículo 3) |
| **qwen2.5-3b-instruct** | 10.6 | **4** |

- **Ninguno sabe la hora**: todos la inventan (no hay herramienta que la dé).
- Qwen3.x **piensa por defecto**: sin `--reasoning off` gastaba todo
  `max_tokens` razonando y respondía vacío. El servicio mantiene la opción
  por si se vuelve a un Qwen3.x.

## Problemas conocidos (sin resolver)

- **El beacon en la DHT nunca se publica a tiempo** (Navigator, Star y los
  providers terminan en timeout). No bloquea: el descubrimiento por GossipSub
  funciona.
- **Navigator ignora SIGTERM**: `podman stop` espera 10 s y lo mata (visto
  otra vez al recrearlo hoy).
- **La compilación de `galaxia-portal-chat` en Bastion se colgó** ~20 min en
  `npm install` sin consumir CPU. No hacía falta ahí (el portal corre en la
  ThinkPad) y se canceló; `containers/build-images.sh` de Core no tiene
  `--only` para construir una sola imagen.
- **El wrapper de llama.cpp no lee el contexto del modelo** ("máx modelo:
  4096"): usa el valor por defecto. Suficiente hoy (Star pide 1024 tokens de
  salida).
- **La descripción ampliada de la KB vive solo en el contenedor** de la
  Raspi3B (`KB_DESCRIPTION`); si se recrea sin esa variable vuelve la
  descripción corta y la recomendación deja de funcionar para preguntas por
  tema.
- **Certificados autofirmados:** cada navegador nuevo acepta la excepción en
  el portal, `:4001` y `:4010` (el panel 🩺 da los enlaces). Solución
  definitiva: Let's Encrypt en la demo remota.
- **Bastion es punto único de falla** (bootstrap, orquestador, LLM y acceso
  a la Raspi3B).

## Pendiente del operador

- En el Mac, dejar la dirección Wi-Fi privada en **"Fija"** para la red
  galaxIA (la reserva DHCP del Mac depende de esa MAC).
- Opcional: limpiar llaves viejas del Mac con `ssh-keygen -R 192.168.1.1` y
  `ssh-keygen -R 192.168.1.181`.

## Siguiente hito

1. Probar desde el navegador la recomendación de la KB ("¿Qué dice el
   artículo 3 sobre la educación?") y marcar `TASK-MVPH-0005` como hecha en
   `galaxIA/spec-native/tasks/mvp-hardening/TASKS.md` (chat y OCR ya
   funcionan de punta a punta).
2. **Demo remota** (ver
   [`arquitectura-poc.md`](arquitectura-poc.md#demo-remota-cómo-se-espera-que-funcione)):
   faltan el subdominio y el acceso al VPS.
