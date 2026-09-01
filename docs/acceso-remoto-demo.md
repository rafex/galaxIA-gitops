# Acceso remoto para demo — diseño y guía paso a paso

## Contexto

Demo en otro estado de la república, sin poder llevar el laboratorio físico
(Bastion, Raspi4B, Raspi3B). Se necesita que alguien en otra red abra el
portal en su navegador y pruebe el chat P2P real, sin fricción de
certificados ni de "estar en la red correcta".

## Alternativas evaluadas

El usuario propuso 3 opciones en Rust para túnel inverso. Se verificó
actividad real con `gh api` (no solo lo que dice cada README):

| Proyecto | Estrellas | Último push | Veredicto |
|---|---|---|---|
| **rathole** | 14,093 | hace 8 días | Maduro, activo, 95 issues abiertos (uso real) |
| krot | 2 | hace 7 semanas | Proyecto personal, sin adopción |
| Tunly | 1 | hace 5 meses | Proyecto personal, estancado |

**Decisión: rathole**, autohospedado en un VPS propio del usuario.

Se descartaron además:
- **ngrok** — necesitamos 3 túneles simultáneos (portal-chat, Atlas,
  Navigator) con dominio propio; eso requiere plan pago (~$20/mes Pro).
- **WireGuard VPN propia** — más control, pero más superficie de
  configuración (routing, claves, firewall) de la que hace falta para
  simplemente exponer 3 puertos.

## Hallazgo de arquitectura clave

`apps/portal-chat/src/services/p2p-discovery.ts` (en `galaxIA-Core`)
confirma que el **navegador dialea dos peers directamente**, no solo Atlas:

1. Dialea los `bootstrapAddrs` de Atlas (puerto 4001) para unirse al swarm.
2. Descubre a Navigator vía GossipSub/DHT y dialea **directamente** su
   propio multiaddr anunciado (`node.dial(multiaddr(dialAddress))`, con la
   dirección tomada del beacon/advertise de Navigator, puerto 4010).

Esto significa que **Atlas y Navigator** necesitan ambos ser alcanzables
públicamente — no solo Atlas — y ambos necesitan anunciar la dirección
pública del túnel, no solo escuchar en ella.

`rathole` reenvía bytes crudos sin interpretar el protocolo (confirmado en
su documentación) — encaja perfecto porque Atlas/Navigator/portal-chat ya
terminan su propio TLS (multiaddr `/tls/ws`, `TLS_CERT_PATH`/`TLS_KEY_PATH`)
y no hace falta que el túnel entienda nada del protocolo FHS/libp2p.

## Certificados: por qué HTTP-01 y no DNS-01

El DNS de `rafex.io`/`rafex.app` vive en un clúster propio del usuario, sin
plugin ACME DNS-01 conocido. Se usa en cambio un desafío **HTTP-01**
respondido directamente por el VPS (que de todas formas es el punto público
de entrada) — el puerto 80 del VPS queda reservado exclusivamente para
`certbot`, nunca tunelado.

## Diseño completo

### 1. VPS: rathole server + certbot

- Instalar el binario de `rathole` ([releases](https://github.com/rapiz1/rathole/releases))
  y `certbot`.
- Copiar `rathole/server.toml.example` → `server.toml`, sustituyendo
  placeholders desde `.env` (ver `../rathole/server.toml.example`).
- Firewall del VPS: abrir `2333` (control rathole), `443`, `4001`, `4010`,
  y `80` (exclusivo para certbot).
- DNS: crear un registro A para el subdominio elegido → IP pública del VPS.
- Emisión inicial: `bash certbot/issue-cert.sh`.
- Instalar el hook de renovación:
  ```bash
  sudo cp certbot/renewal-hooks/deploy/sync-to-bastion.sh /etc/letsencrypt/renewal-hooks/deploy/
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/sync-to-bastion.sh
  ```
- Correrlo una vez a mano para poblar el certificado inicial en Bastion (ver
  salida de `issue-cert.sh` para el comando exacto).
- Instalar y arrancar `rathole/rathole-server.service`.

### 2. Bastion: rathole client

- Instalar el binario de `rathole` (client).
- Copiar `rathole/client.toml.example` → `client.toml`, mismo `.env`.
- Instalar y arrancar `rathole/rathole-client.service` — sobrevive
  reinicios, cero cambios en cómo corren los contenedores FHS hoy.

### 3. Certificado real — sin tocar código de la app

Mismos paths de siempre (`~/certs/dev.crt`, `~/certs/e2e.crt`,
`~/certs/portal-chat/portal.crt`) — solo cambia el origen del archivo
(Let's Encrypt real en vez de `openssl` autofirmado). Atlas/Navigator/
Star/portal-chat no requieren ningún cambio de código: ya leen lo que esté
montado en `TLS_CERT_PATH`/`TLS_KEY_PATH`.

`containers/portal-chat/generate-cert.sh` (en `galaxIA-Core`) ya sale
temprano si el cert existe y no está vacío — al colocar el cert real ahí
manualmente (vía `sync-to-bastion.sh`), el entrypoint nunca lo pisa con uno
autofirmado.

### 4. `FHS_ANNOUNCE_ADDRS` — Atlas y Navigator anuncian también la ruta pública

Agregar la dirección pública **además** de las privadas (ya soportado:
múltiples multiaddrs separadas por coma/salto de línea) — así el LAN local
sigue funcionando igual y la demo remota también:

```bash
# Atlas
FHS_ANNOUNCE_ADDRS=/ip4/192.168.1.139/tcp/4001/tls/ws,/dns4/<subdominio>/tcp/4001/tls/ws

# Navigator
FHS_ANNOUNCE_ADDRS=/ip4/192.168.1.139/tcp/4010/tls/ws,/dns4/<subdominio>/tcp/4010/tls/ws
```

Reiniciar Atlas y Navigator (`podman restart fhs-atlas fhs-navigator`) tras
el cambio.

### 5. `portal-chat` de la demo — bootstrap público

`FHS_BOOTSTRAP_ADDRS` para la instancia de portal-chat que se muestra en la
demo incluye el multiaddr público de Atlas (mismo PeerID real, no cambia
identidad):

```
/dns4/<subdominio>/tcp/4001/tls/ws/p2p/<ATLAS_PEER_ID>
```

El navegador de un asistente a la demo abre `https://<subdominio>/`
(VPS:443 → túnel → Bastion:8443), recibe ese bootstrap en `p2p-config.json`,
y dialea todo bajo el mismo dominio real con certificado válido — sin
ninguna advertencia de seguridad.

## Verificación

1. `rathole client` en Bastion conecta; los logs del VPS muestran los 3
   servicios registrados.
2. `curl -I https://<subdominio>/` desde una red externa (no LAN de
   Bastion) responde `200` con cadena de certificado válida (sin `-k`).
3. `openssl s_client -connect <subdominio>:4001 -servername <subdominio>`
   muestra la cadena de Let's Encrypt, no autofirmada.
4. Desde un dispositivo fuera de las redes del laboratorio (ej. datos
   móviles), abrir `https://<subdominio>/` sin advertencia del navegador y
   completar un chat E2E real.
5. `sudo certbot renew --dry-run` en el VPS confirma que el hook de
   sincronización a Bastion funciona antes de depender de él el día de la
   demo.
