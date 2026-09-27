# Mapa de módulos de la PoC

Qué módulos existen, dónde está su código, qué hace cada uno, en qué
lenguaje y versión están, qué tan acoplados están y en qué máquina corren
hoy. Datos medidos el **2026-09-27** en las máquinas (versiones de Node,
nginx, Tesseract y llama.cpp sacadas de los contenedores en ejecución).

Complementa a [`arquitectura-poc.md`](arquitectura-poc.md) (cómo fluye un
mensaje) y [`estado-poc.md`](estado-poc.md) (qué versión está desplegada).

![Mapa de módulos](diagramas/mapa-modulos.svg)

## Máquinas (red soberana `192.168.1.0/24`, router OpenWrt `192.168.1.1`)

| Máquina | IP | Arquitectura · SO | Runtime | Módulos |
|---|---|---|---|---|
| Bastion (Mac mini 6,2) | `192.168.1.139` | x86_64 · Debian 13 | podman 5.4.2 rootless | Atlas, Navigator, Star, llama-server |
| Raspi4B | `192.168.1.167` | aarch64 · Debian 13 | podman 5.4.2 root | Satellite OCR |
| Raspi3B «portal-pi» | `192.168.1.181` | aarch64 · Debian 13 | podman 5.4.2 root | KB provider, RAG provider |
| ThinkPad | `192.168.1.239` | x86_64 · Debian forky | podman 5.8.6 rootless | Portal Chat |
| Mac | `192.168.1.102` | arm64 · macOS 27 | — | navegador (cliente) y desarrollo |

## Módulos desplegados

Todos los nodos FHS corren en **Node.js 24** (imágenes `node:24-alpine`,
salvo OCR en `node:24-bookworm`) y **TypeScript 5.9** (galaxIA-Core) o
**5.5+** (galaxIA-satellite-star), con **js-libp2p 3.3.8**.

| Módulo | Repo · ruta | Lenguaje · versión | Responsabilidad | Máquina | Puertos |
|---|---|---|---|---|---|
| **Atlas** (`fhs-atlas`) | `galaxIA-Core` · `apps/atlas` | TS · `@rafex/galaxia-atlas` 0.1.12 · Node 24.21 | Bootstrap de la red libp2p: punto de entrada, DHT (servidor) y malla GossipSub. No enruta misiones. | Bastion `.139` | P2P `4001` · API `8081` |
| **Navigator** (`fhs-navigator`) | `galaxIA-Core` · `apps/navigator` | TS · `@rafex/galaxia-navigator` 0.1.17 · Node 24.21 | Orquestador: sesión del Portal, elección de LLM, subasta de misiones (offer/bid/assign), OCR determinista, RAG por red, recomendación y consulta de KB, prompt, tool calling y procedencia. | Bastion `.139` | P2P `4010` · API `8090` |
| **Portal Chat** (`fhs-portal-chat`) | `galaxIA-Core` · `apps/portal-chat` | TS (Vite) servido por nginx 1.31 · `@rafex/galaxia-portal-chat` 0.1.21 | Interfaz web. El navegador es un nodo js-libp2p: se conecta a Atlas y a Navigator. RAG local en el navegador (MiniLM + sqlite-wasm), panel de diagnóstico, Markdown. | ThinkPad `.239` | HTTPS `8443` |
| **Star** (`fhs-star`) | `galaxIA-satellite-star` · `examples/star-example` | TS · `@galaxia/star-example` 0.2.0 · Node 24.21 | Provider LLM: puja por misiones `chat`, recibe el stream directo y reenvía la respuesta de llama-server en vivo. | Bastion `.139` | P2P `4002` |
| **llama-server** | `PoC-Llama.cpp` (compila `ggml-org/llama.cpp` `7fe450e`) | C++ · binario en `/opt/llama.cpp` · perfil `apple/macmini6.2` (AVX+F16C) | Inferencia local del modelo (qwen2.5-3b-instruct Q4_K_M) con API OpenAI-compatible. | Bastion `.139` (`systemd --user`) | HTTP `43110` (solo local) |
| **Satellite OCR** (`fhs-satellite-ocr`) | `galaxIA-satellite-star` · `examples/satellite-ocr-example` | TS · `@galaxia/satellite-ocr-example` 0.2.0 · Node 24.20 · Tesseract 5.3 | Extrae texto de PDF/imagen (`document.ocr`). | Raspi4B `.167` | P2P `4003` |
| **KB provider** (`fhs-kb-provider`) | `galaxIA-satellite-star` · `examples/kb-provider` | TS · `@galaxia/kb-provider-example` 0.2.0 · Node 24.20 | Base de conocimiento estática (`knowledge.query`; hoy, texto de ejemplo de la Constitución). | Raspi3B `.181` | P2P `4006` |
| **RAG provider** (`fhs-rag-provider`) | `galaxIA-satellite-star` · `examples/rag-provider` | TS · `@galaxia/rag-provider-example` 0.2.0 · Node 24.20 | Indexa y recupera fragmentos por conversación (`document.index`, `document.query`); también fusiona resultados de KB. | Raspi3B `.181` | P2P `4005` |

## Librerías compartidas (acoplamiento en compilación, no en ejecución)

| Librería | Repo · ruta | Lenguaje · versión | La usan | Qué aporta |
|---|---|---|---|---|
| IDL FHS | `galaxIA` · `idl/fhs-protocol.proto` | Protobuf 3 | todos (vía SDK) y `galaxIA-agent` (copia verificada por sha256) | Contrato del wire: Envelope, mensajes GossipSub, misiones |
| `@rafex/galaxia-fhs-protocol` | `galaxIA-SDK` · `packages/fhs-protocol` | TS 5.9 · 0.1.36 en npmjs (`@rafex_labs/…`) | Atlas, Navigator, Portal, todos los providers | Tipos generados, codificación Protobuf, cadenas de firma |
| `@rafex/galaxia-fhs-node` | `galaxIA-Core` · `packages/fhs-node` | TS 5.9 · 0.1.0 (workspace) | Atlas, Navigator | Nodo libp2p, reconexión al bootstrap, diagnóstico, `/status` |
| `@galaxia/fhs-wire` | `galaxIA-satellite-star` · `examples/fhs-wire` | TS · 0.1.0 (workspace) | Star, OCR, KB, RAG, Nova | Firmas, beacon, `DynamicValue`, streams; copia deliberada del diagnóstico de `fhs-node` |
| Perfiles de parseo | `galaxia-parser-catalog` | TS + JSON + SQLite · 0.1.0 | Star (copia local en `parser-profiles.ts`) | Parseo tolerante de tool calls escritas como texto |

## No desplegados

| Módulo | Repo · ruta | Lenguaje · versión | Estado |
|---|---|---|---|
| **galaxIA-agent** | `galaxIA-agent` (raíz) | Rust 1.97 (edición 2021) · Rig 0.42 · rust-libp2p 0.57 | En desarrollo para reemplazar a Navigator. Hoy: política, firmas compatibles con el TS (fixtures dorados) y la capa P2P en construcción. Plan en `galaxIA-agent/docs/migracion-desde-ts.md`. |
| **Nova** | `galaxIA-satellite-star` · `examples/nova-example` | TS · 0.2.0 | Nodo de razonamiento con loop propio (SPEC-NOVA-0001). Sin contenedor en la PoC. |
| **Portal TUI** | `galaxIA-Core` · `apps/portal-tui` | TS · 0.1.0 | Esqueleto de cliente de terminal; sin implementar. |
| **log-agent** | `galaxIA-Core` · `apps/log-agent` | TS · 0.1.0 | Colector central de logs vía NATS (DEC-0083). Fuera del protocolo; no hay NATS en la PoC. |
| **satellite-web** | `galaxIA-SDK` · `apps/satellite-web` | TS + Rust→WASM (`satellite-capabilities-wasm` 0.1.4, edición 2021) | Demo de Ephemeral Satellite (aritmética y CURP en un Web Worker). |
| Túnel para demos | `galaxIA-gitops` · `rathole/`, `certbot/` | TOML + Bash | Diseñado, no desplegado (faltan subdominio y VPS). |
| Laboratorio E2E | `galaxIA-E2E` (privado) | Bash | Orquestación de la prueba de punta a punta. |

## Acoplamiento: ¿se pueden instalar en máquinas distintas?

**Sí, todos los nodos FHS son independientes.** Hablan solo por libp2p
(GossipSub + streams directos), así que Atlas, Navigator, Star, OCR, KB y
RAG pueden correr cada uno en otra máquina sin tocar código. Lo que sí los
ata:

| Acoplamiento | Tipo | Qué implica al moverlos |
|---|---|---|
| Todos → **Atlas** | Configuración (`FHS_BOOTSTRAP_ADDRS` con IP y PeerID) | Atlas es el único bootstrap: si cambia de máquina o IP hay que actualizar la variable en cada nodo y en el `p2p-config.json` del Portal. Su PeerID se conserva con el volumen `atlas-data`. |
| **Star → llama-server** | HTTP (`LLAMA_CPP_URL`, hoy `127.0.0.1:43110`) | Único acoplamiento fuera de libp2p. Pueden ir en máquinas distintas cambiando la URL, pero conviene juntarlos: el prompt y cada token viajarían por la red. |
| **Navegador → Navigator** | libp2p directo (`wss://…:4010`) | El navegador marca a Navigator por sí mismo: Navigator debe ser alcanzable desde la red del usuario y con un certificado que el navegador acepte. |
| **Portal → Atlas** | Configuración (`p2p-config.json`) | El Portal solo sirve archivos estáticos: puede ir en cualquier máquina (hoy la ThinkPad). |
| **Certificado TLS** | Despliegue (SAN con las IPs) | El certificado unificado lista `.139`, `.167` y `.181` (y las IPs Netup de Bastion). Mover un nodo P2P a una IP nueva exige regenerarlo; de ahí las reservas DHCP fijas. |
| **Identidades** | Volúmenes (`atlas-data`, `navigator-data`, `star-data`, `ocr-data`, `kb-data`, `rag-data`) | Mover un nodo sin su volumen le cambia DID/PeerID; el volumen debe viajar con el contenedor. |
| **Navigator → IPFS** | Opcional (`IPFS_API_URL`) | Solo para adjuntos por IPFS; sin configurar, los adjuntos van inline. |
| Librerías compartidas | Compilación | Actualizar `fhs-protocol` obliga a recompilar las imágenes; no crea dependencia entre máquinas. |

Recomendaciones de ubicación con el hardware actual:

- **Juntos:** Star y llama-server (latencia del streaming).
- **Donde haya RAM:** Star + llama-server (el modelo 3B usa ~2 GB).
- **Donde sea:** OCR, KB y RAG (poca RAM; Raspis).
- **Alcanzable desde los usuarios:** Atlas (`4001`) y Navigator (`4010`),
  que el navegador marca directo; es lo que expone el túnel de la demo
  remota.
- **Punto único de falla hoy:** Bastion (Atlas + Navigator + Star + LLM).
  Separar Atlas en otra máquina es el primer paso si se quiere tolerancia.
