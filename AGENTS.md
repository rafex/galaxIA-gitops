# AGENTS.md

Contexto para cualquier agente (Claude Code, Codex, Cursor, u otro) que
trabaje en este repositorio.

## Qué es este repo

`galaxIA-gitops` contiene **solo** configuración e infraestructura de
despliegue: túnel inverso (rathole) y certificados TLS reales (Let's
Encrypt) para exponer el stack P2P de galaxIA fuera de la red local, sin
llevar el hardware físico a cada demo.

No hay código de aplicación aquí. El código vive en:
- `galaxIA-Core` — Atlas, Navigator, Portal Chat
- `galaxIA-satellite-star` — Star y los providers de referencia (OCR, RAG, KB)
- `galaxIA-SDK` — paquetes TS/WASM publicados (`fhs-protocol`, `satellite-capabilities`)
- `galaxIA` — el IDL/spec del protocolo

Este repo **no compila, no tiene tests, no tiene CI**. Es scripts + TOML +
docs, operados a mano contra hardware real. `scripts/doctor.sh` es el punto de
entrada para diagnosticar una red nueva: correrlo antes de tocar nada más.

## Regla de seguridad — este repo es público

**Nunca commitear secretos reales:** tokens de rathole, IPs de VPS de
producción, claves privadas, certificados emitidos. Todo eso va en `.env`
(gitignorado) o directamente en el host destino — nunca en un archivo
versionado. Los `.example`/`.toml.example` en este repo llevan placeholders
tipo `REPLACE_WITH_*`, nunca valores reales.

Si en algún momento aparece un valor real en un diff que estás por
commitear (una IP pública específica, un token, un `.pem`), deténte y
avisa al usuario en vez de commitearlo.

## Fuente de verdad

Antes de tocar hardware, lee [`docs/estado-poc.md`](docs/estado-poc.md) (qué
está desplegado y qué falla) y [`docs/arquitectura-poc.md`](docs/arquitectura-poc.md)
(qué corre dónde y por qué). Si cambias el despliegue, actualiza el snapshot
de `estado-poc.md` **con datos recién medidos** y su diagrama
`docs/diagramas/estado-actual.d2`; después corre `scripts/render-diagramas.sh`.
Los diagramas son [D2](https://d2lang.com/): se versionan el `.d2` y el `.svg`,
porque GitHub no renderiza D2 dentro de Markdown.

[`docs/acceso-remoto-demo.md`](docs/acceso-remoto-demo.md) tiene el diseño
completo: por qué rathole (vs. las otras 2 alternativas Rust evaluadas, vs.
ngrok, vs. WireGuard), por qué Atlas *y* Navigator necesitan ser alcanzables
públicamente (no solo Atlas — el navegador dialea a ambos directamente, ver
`apps/portal-chat/src/services/p2p-discovery.ts` en `galaxIA-Core`), y el
paso a paso de emisión/renovación de certificados. Léelo antes de modificar
cualquier script — explica el *por qué*, no solo el *qué*.

## Cómo se relaciona con los otros repos

Este repo **no modifica código** de `galaxIA-Core`/`galaxIA-satellite-star`.
Solo cambia variables de entorno de los contenedores ya existentes
(`FHS_ANNOUNCE_ADDRS`, `FHS_BOOTSTRAP_ADDRS`, `TLS_CERT_PATH`) y qué archivo
de certificado está montado en `~/certs` de cada host — los Containerfiles y
`compose.yaml` de esos repos no cambian por esto.

## Convenciones

- Todo script bash lee configuración de variables de entorno (`.env`,
  cargado explícitamente) — nunca hardcodear un dominio o IP dentro de un
  script versionado.
- Los `.toml.example` se copian a `.toml` (gitignorado) y se sustituyen los
  placeholders a mano o con `envsubst` — no se versiona el `.toml` final.
- Cambios en la arquitectura del túnel (nuevos servicios, puertos) se
  documentan primero en `docs/acceso-remoto-demo.md`, después se reflejan
  en los `.example`.
