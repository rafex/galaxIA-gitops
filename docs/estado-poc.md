# Estado de la PoC

> **Snapshot: 2026-09-27 23:56 (CST).** Se actualiza a mano. Cada dato sale
> de un comando corrido en ese momento (`podman ps/inspect`, `/status`,
> `/health`, `llama-bench`, `doctor.sh`); no se copia de la memoria.
> Arquitectura y porqués: [`arquitectura-poc.md`](arquitectura-poc.md).

## En una línea

**Todo el backend corre en Rust** desde el 2026-09-27 (Atlas, Navigator, Star,
OCR, KB y RAG sobre `galaxia-fhs`), con los mismos DID y PeerId; el Portal
sigue en TypeScript. Atlas ve los 5 nodos, Navigator conoce a los 4
providers, `doctor.sh` sale sin problemas bloqueantes y la prueba
`tests/e2e` del Portal pasa 6/6. Los contenedores TS quedaron detenidos
como reversa (`*-ts-rollback`, `fhs-navigator-pre-*`).

**Adjuntos por IPFS nativo en la red pública** (DEC-0095, desde el
2026-09-27): Kubo en Bastion y Raspi4B, Navigator y OCR con IPFS, Portal con
la opción "Vía IPFS" y el aviso de privacidad. Detalle en
[`ipfs.md`](ipfs.md).

![Estado actual](diagramas/estado-actual.svg)

## Por equipo

| Equipo | Contenedores | Código desplegado | Nota |
|---|---|---|---|
| Bastion `.139` | `fhs-atlas` | Core `c5f8ec3` (`rust/atlas`) | Mismo PeerId; reenvía los anuncios vigentes a cada suscriptor nuevo (descubrimiento del Navigator en ~1 s, E2E-035) |
| | `fhs-navigator` | galaxIA-agent `478e3f3` | Rust + Rig. Republica su beacon DHT al recuperar Atlas (E2E-034). IPFS: sube al Kubo local y lleva el libro de pines (`/data/ipfs-pins.json`); API de admin en `127.0.0.1:8099`. Reversa: `fhs-navigator-pre-478e3f3` |
| | `fhs-ipfs` | Kubo `v0.43.1` | Red pública, swarm `4101`, API en loopback con tokens; 75–90 MB |
| | `fhs-star` | satellite-star `eeb295a` (`rust/star`) | 3.2 MB de memoria (TS: 57 MB); `MODEL_ID=Qwen3.5-2B-Q4_K_M` |
| | `llama-server` (`systemd --user`) | llama.cpp `7fe450e` compilado con PoC-Llama.cpp `8051c41` | **Qwen3.5-2B** Q4_K_M (oficial desde 2026-09-27), `--reasoning off`, 4 hilos: ~27 tok/s leyendo el prompt y ~14 tok/s generando (3 misiones de la prueba e2e). Escucha en `0.0.0.0:43110` |
| Raspi4B `.167` | `fhs-satellite-ocr` | satellite-star `267f899` (`rust/ocr`) | Tesseract 5.3 `spa`; imagen de 227 MB (TS: 1.29 GB); 2.5 MB de RAM. uid 10001, `--read-only`, 1 GB / 2 CPU / 256 procesos. Lee IPFS por su Kubo y anuncia `ipfs.native.public` mientras está sano. Reversa: `fhs-satellite-ocr-pre-267f899` |
| | `fhs-ipfs` | Kubo `v0.43.1` | Igual que el de Bastion, con peering a él por la LAN |
| Raspi3B `.181` | `fhs-kb-provider`, `fhs-rag-provider` | satellite-star `6fcf07e` (`rust/kb`, `rust/rag`) | 10.4 MB cada uno; la máquina pasó de 188 a 97 MiB usados. Imágenes construidas en la Raspi4B. `KB_DESCRIPTION` ampliada se conserva |
| ThinkPad `.239` | `fhs-portal-chat` | Core `acd6e7d` | Lee el beacon del DHT (E2E-032). Construido con `VITE_FHS_IPFS_GATEWAY_URL=https://ipfs.io/ipfs`. Reversa: `fhs-portal-chat-pre-acd6e7d` |

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
| qwen2.5-3b-instruct | 10.6 | **4** |
| **Qwen3.5-2B** (oficial desde 2026-09-27, decisión del dueño) | ~14 | 2 ("Sídney"; el artículo 3 lo confunde con el 39). Con la KB sí responde bien el artículo 3: pasa la prueba e2e (KB, OCR, RAG) |

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

- IPFS (DEC-0095): dejar `4101` tcp/udp permitido en la LAN en el UFW de
  Bastion y de la Raspi4B (hoy el peering conecta, pero la regla de la
  Raspi4B cubre `4000:4100`) y comprobar que `5001` y `8099` sigan cerrados
  hacia fuera (verificado desde el Mac el 2026-09-27).
- Relojes: verificar NTP (`systemd-timesyncd` o chrony) en Bastion, Raspi4B,
  Raspi3B y ThinkPad antes de la Entrega 2 (reputación, ventana de ±5 min).

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
