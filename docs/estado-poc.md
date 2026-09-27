# Estado de la PoC

> **Snapshot: 2026-09-26 22:13 (CST).** Se actualiza a mano. Cada dato sale
> de un comando corrido en ese momento (`podman ps/inspect`, `/status`,
> `/health`, `llama-bench`, `doctor.sh`); no se copia de la memoria.
> Arquitectura y porqués: [`arquitectura-poc.md`](arquitectura-poc.md).

## En una línea

Todo arriba, al día y **respondiendo rápido**: Atlas ve los 5 nodos (más el
navegador del Mac), Navigator conoce a los 4 providers, `doctor.sh` sale sin
problemas bloqueantes y el LLM contesta una pregunta corta en **~3 s** (eran
**~45 s** al empezar el día).

![Estado actual](diagramas/estado-actual.svg)

## Por equipo

| Equipo | Contenedores | Código desplegado | Nota |
|---|---|---|---|
| Bastion `.139` | `fhs-atlas`, `fhs-navigator` | Core `c1df4f5` | Mismo PeerID de Atlas y mismo DID de Navigator (identidades en volumen) |
| | `fhs-star` | satellite-star `7d7c0bf` | Streaming real hacia el navegador; `MODEL_ID=qwen3.5-0.8b-q4_k_m` |
| | `llama-server` (`systemd --user`) | llama.cpp `7fe450e` compilado con PoC-Llama.cpp `8051c41` | **Qwen3.5-0.8B** Q4_K_M, `--reasoning off`, 4 hilos |
| Raspi4B `.167` | `fhs-satellite-ocr` | satellite-star `ebf0299` | Reconecta solo al bootstrap |
| Raspi3B `.181` | `fhs-kb-provider`, `fhs-rag-provider` | satellite-star `7d7c0bf` (sin cambios de kb/rag desde `ebf0299`) | Reconectan solos; 703 MB disponibles |
| ThinkPad `.239` | `fhs-portal-chat` | Core `464a178` | Corrige E2E-026 (cerraba su propia conexión con Navigator) |

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
| Modelo lento para una demo en CPU | 3B en un i7 de 3ª gen | Qwen3.5-0.8B: 62 tok/s leyendo prompt y 27.6 generando (el 3B: 16 y 10.4) |
| OCR fuera de la red (4/5) | Imagen vieja sin reconexión al bootstrap | Recreado con `ebf0299` |

### Qwen3.5-0.8B: lo que hay que saber

- **Piensa antes de contestar por defecto.** Con `max_tokens=1024` se gastaba
  todo en razonar (4,477 caracteres) y la respuesta salía **vacía** tras
  40 s. Por eso `llama-server` corre con `--reasoning off` (pasado al
  wrapper tras `--`, que descarta flags desconocidos).
- **Calidad:** responde rápido y en español, pero inventa datos con
  facilidad (a "qué hora es en España" contestó una hora arbitraria). Es la
  contrapartida del tamaño; el 3B sigue en `/srv/models/gguf` si la demo
  necesita más calidad y se acepta ~3× menos velocidad.

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
- **El wrapper no lee el contexto de Qwen3.5** ("máx modelo: 4096"): usa el
  valor por defecto. Suficiente hoy (Star pide 1024 tokens de salida).
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

1. Prueba de punta a punta desde el navegador con el stack actual (chat y
   OCR) y marcar `TASK-MVPH-0005` como hecha en
   `galaxIA/spec-native/tasks/mvp-hardening/TASKS.md`.
2. **Demo remota** (ver
   [`arquitectura-poc.md`](arquitectura-poc.md#demo-remota-cómo-se-espera-que-funcione)):
   faltan el subdominio y el acceso al VPS.
