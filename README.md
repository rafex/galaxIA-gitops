# galaxIA-gitops

Despliegue y operación de infraestructura para galaxIA — separado
deliberadamente del código de aplicación (`galaxIA-Core`,
`galaxIA-satellite-star`, `galaxIA-SDK`). Este repo no compila nada: son
configuraciones, scripts y documentación para exponer el stack P2P fuera de
la red local (demos remotas, laboratorios que no viajan con el hardware).

## Qué resuelve

Los nodos FHS (`atlas`, `navigator`, `star`, `satellite-ocr`, `kb-provider`,
`rag-provider`, `portal-chat`) corren en hardware físico (Bastion, Raspis)
detrás de un NAT doméstico. Para una demo en otra red — sin llevar el
laboratorio — se necesita:

1. Un punto de entrada público y estable (VPS propio).
2. Túnel inverso desde ese hardware hacia el VPS, sin abrir puertos en el
   router de casa.
3. Certificados TLS **reales** (no autofirmados) para que el navegador de
   quien ve la demo no muestre advertencias de seguridad.

## Arquitectura

```
Asistente a la demo (cualquier red)
        │  https://<subdominio>/
        │  wss://<subdominio>:4001/  (Atlas)
        │  wss://<subdominio>:4010/  (Navigator)
        ▼
   VPS propio (IP pública)
   ┌─────────────────────────────┐
   │ rathole server               │  reenvía bytes crudos, no
   │ certbot (Let's Encrypt)      │  interpreta el protocolo
   └──────────────┬────────────────┘
                   │ túnel rathole (cifrado con Noise)
                   ▼
   Bastion (red doméstica, detrás de NAT)
   ┌─────────────────────────────┐
   │ rathole client                │
   │ fhs-atlas :4001                │
   │ fhs-navigator :4010            │
   │ fhs-portal-chat :8443          │
   └─────────────────────────────┘
```

**Por qué rathole:** de las alternativas evaluadas (rathole, krot, Tunly) es
la única con adopción real y mantenimiento activo (14k+ estrellas, commits
recientes) — las otras dos son proyectos personales sin tracción. Reenvía
TCP crudo sin tocar el protocolo, así que Atlas/Navigator/portal-chat siguen
terminando su propio TLS exactamente como hoy en LAN — el túnel es
invisible a esa capa.

**Por qué certificados reales en vez de autofirmados:** ya se probó en LAN
que un certificado autofirmado obliga a cada persona a aceptar una
excepción de seguridad manualmente (fricción real, documentada en
`galaxIA-Core/docs/historial-incidencias-e2e.md`). Con un dominio propio
(`rafex.io`/`rafex.app`) y Let's Encrypt, el navegador no muestra ninguna
advertencia.

## Contenido del repo

| Ruta | Qué es |
|---|---|
| `rathole/server.toml.example` | Config del túnel en el VPS (plantilla) |
| `rathole/client.toml.example` | Config del túnel en Bastion (plantilla) |
| `rathole/*.service` | Unidades systemd para correr ambos como servicio |
| `certbot/issue-cert.sh` | Emisión inicial del certificado (HTTP-01, standalone) |
| `certbot/renewal-hooks/deploy/sync-to-bastion.sh` | Hook que corre en cada renovación: copia el cert nuevo a Bastion y reinicia los contenedores |
| `docs/acceso-remoto-demo.md` | Diseño completo, decisiones y guía paso a paso |
| `.env.example` | Variables a completar (dominio, IP del VPS, token) — **nunca commitear `.env`** |

## Uso rápido

```bash
cp .env.example .env
# completar DEMO_DOMAIN, VPS_HOST, RATHOLE_TOKEN, etc.

# En el VPS:
bash certbot/issue-cert.sh
#  copiar rathole/server.toml.example a server.toml sustituyendo placeholders
#  correr rathole server (ver rathole/rathole-server.service)

# En Bastion:
#  copiar rathole/client.toml.example a client.toml sustituyendo placeholders
#  correr rathole client (ver rathole/rathole-client.service)
```

Guía completa con cada paso: [`docs/acceso-remoto-demo.md`](docs/acceso-remoto-demo.md).

## Qué NO va en este repo

- Certificados privados, tokens reales, IPs de producción del VPS — todo
  eso vive en `.env` (gitignorado) o directamente en el host, nunca en git.
- Código de aplicación — eso vive en `galaxIA-Core` / `galaxIA-satellite-star`.
- Nada de esto se ejecuta automáticamente en CI; es infraestructura operada
  a mano por el operador del laboratorio.
