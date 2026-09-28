# IPFS en la PoC (red pública para la demo)

Decisión: DEC-0095 en `galaxIA/spec-native/DECISIONS.md`. Spec:
SPEC-IPFS-0001.

## Qué es y para qué

Los adjuntos del Portal (PDF o imagen para OCR) pueden viajar **por IPFS** en
lugar de ir dentro del mensaje. El Navigator sube el archivo a su nodo IPFS y
manda al OCR solo el identificador del contenido (CID); el OCR lo pide a su
propio nodo IPFS, que lo trae del otro por la LAN y verifica cada bloque
contra su hash.

El nodo IPFS es **Kubo** (implementación de referencia de IPFS, en Go),
en un contenedor `fhs-ipfs` por host:

| Host | Quién lo usa | Para qué | PeerID |
|---|---|---|---|
| Bastion `192.168.1.139` | Navigator | `add`, `pin rm`, `pin ls`, `repo stat`, `diag sys` | `12D3KooWEnnhuPwtjF9KnTLqnnaqHbtYmCfmotSKLJVT2DyaoMcG` |
| Raspi4B `192.168.1.167` | OCR | `cat` y chequeo de salud | `12D3KooWFqSUYJgHDAbykuLuYmqMjoWfj3HABnvAniN4U2eLrWCr` |

Consumo medido al arrancar: 75–90 MB de RAM por nodo (tope del contenedor:
1 GB, `GOMEMLIMIT=768MiB`).

## Qué implica "red pública"

- Los dos nodos están en la red IPFS pública (DHT en modo cliente). Kubo
  anuncia en el DHT que tiene cada CID: **cualquiera que conozca el CID puede
  descargar el archivo** mientras esté en algún nodo.
- El unpin y el GC lo borran de **nuestros** nodos, no de cachés ajenos. Lo
  publicado no se puede retirar.
- Por eso, en la demo solo se usan **documentos no sensibles**, y el Portal lo
  avisa.
- La recuperación está garantizada solo dentro de la LAN (peering estático
  Bastion↔Raspi4B). Abrir el CID desde `https://ipfs.io/ipfs/<cid>` fuera de
  la red es opcional: detrás del NAT puede tardar o fallar.

## Configuración (la aplica `kubo-setup.sh`)

| Ajuste | Valor | Por qué |
|---|---|---|
| Imagen | `docker.io/ipfs/kubo:v0.43.1` | versión fijada; la compuerta se probó con ella |
| Swarm | `tcp/4101` y `udp/4101/quic-v1` | 4001 es de Atlas en Bastion |
| API | `127.0.0.1:5001` con `API.Authorizations` | sin token responde 403 a todo |
| Gateway HTTP | ninguno | nadie lo usa (DEC-0092: lectura nativa) |
| `Routing.Type` | `autoclient` | no carga el hardware con el DHT de otros |
| `AutoNAT.ServiceMode`, `Swarm.RelayService` | apagados | no dar servicio a terceros |
| `Addresses.NoAnnounce` | rangos privados | no publicar la topología de la LAN |
| mDNS, AutoTLS | apagados | peering estático; sin certificados `libp2p.direct` |
| `Peering.Peers` | el otro nodo por su IP de LAN | la ruta interna no depende del DHT público |
| `Datastore.StorageMax` / `GCPeriod` | 5 GB / 1 h | el GC borra lo que ya no está fijado |

Tokens por host en `~/secrets/ipfs/` (0600, fuera del repo):

| Archivo | Rutas permitidas |
|---|---|
| `navigator.token` (Bastion) | `add`, `pin/rm`, `pin/ls`, `repo/stat`, `diag/sys`, `id` |
| `ocr.token` (Raspi4B) | `cat`, `id`, `swarm/peers` |
| `operator.token` + `operator.header` | todo `/api/v0` (operación manual) |

Kubo compara `AllowedPaths` **por prefijo**: siempre rutas completas (nunca
`/api/v0/pin`, que incluiría `pin/add`).

## Instalación

En cada host (el script está en `scripts/ipfs/`):

```bash
# 1. Bastion y Raspi4B, sin peer: imprime el PeerID de cada uno
bash kubo-setup.sh --role navigator                       # Bastion
bash kubo-setup.sh --role ocr                             # Raspi4B
# 2. Otra vez, cada uno con el peer del otro
bash kubo-setup.sh --role navigator --peer /ip4/192.168.1.167/tcp/4101/p2p/<PeerID Raspi4B>
bash kubo-setup.sh --role ocr --peer /ip4/192.168.1.139/tcp/4101/p2p/<PeerID Bastion>
```

Es idempotente: detiene `fhs-ipfs`, reescribe la configuración sin daemon y lo
vuelve a crear con `--network host --restart always`. Falla si la API quedaría
fuera de loopback o respondiera sin token.

Firewall (acción del dueño): `4101` tcp/udp abierto en la LAN; `5001` nunca
alcanzable desde fuera del host.

## Verificación

```bash
bash kubo-check.sh --role navigator --peer-id <PeerID Raspi4B>   # Bastion
bash kubo-check.sh --role ocr --peer-id <PeerID Bastion>         # Raspi4B
```

Resultado del 2026-09-27: ambos en verde. Sin token → 403; cada token llega a
sus rutas y no a `config`, `key/list`, `shutdown`, `pin/add`, `repo/gc` ni a
las del otro rol; peering conectado por la LAN; 214–261 peers públicos. Un
archivo aleatorio de 300 KB agregado en Bastion se leyó en la Raspi4B con el
mismo SHA-256 en 0.35 s.

## Clientes: Navigator, OCR y Portal

| Componente | Commit | Variables IPFS | Notas |
|---|---|---|---|
| Navigator (Bastion, `fhs-navigator`) | galaxIA-agent `478e3f3` | `IPFS_API_URL=http://127.0.0.1:5001`, `IPFS_API_TOKEN_FILE=/secrets/ipfs.token` (← `~/secrets/ipfs/navigator.token:ro`), `IPFS_NETWORK=public` | Libro de pines y token de admin en el volumen `navigator-data`. Reversa: `fhs-navigator-pre-478e3f3` |
| OCR (Raspi4B, `fhs-satellite-ocr`) | galaxIA-satellite-star `267f899` | lo mismo con `ocr.token`, más `IPFS_EXPECTED_PEER=<PeerID Kubo Bastion>` | Corre como uid 10001: certificados copiados a `/root/certs/ocr` y `ocr.token` e identidad del uid 10001. Límites `--memory 1g --cpus 2 --pids-limit 256 --read-only --tmpfs /tmp:rw,size=512m` |
| Portal (ThinkPad, `fhs-portal-chat`) | galaxIA-Core `acd6e7d` | build arg `VITE_FHS_IPFS_GATEWAY_URL=https://ipfs.io/ipfs` | Reversa: `fhs-portal-chat-pre-acd6e7d` |

El OCR anuncia `ipfs.native.public` solo mientras su Kubo responde y el de
Bastion está conectado. Si no, el Navigator responde "Ningún OCR con acceso a
IPFS" y no sube nada.

## Compuerta E1.6 (2026-09-27/28)

| Prueba | Resultado |
|---|---|
| e2e del Portal (`tests/e2e`, 6 casos, incluido "adjunto vía IPFS público") | 6/6 |
| Ciclo `ephemeral`: fijado 05:50:17 → OCR lee por su Kubo → liberado 05:51:10 (30 s de gracia + barrido) | ✅ |
| `repo gc` forzado en ambos nodos → `block stat --offline <cid>` falla en los dos | ✅ |
| `reuse`: sigue fijado tras la gracia y tras reiniciar el Navigator; API de admin 401 sin token, 404 CID desconocido, 200 `cleanup_scheduled: true`, 409 al repetir; la API no despinea, el barrido sí (55 s después) | ✅ |
| Reinicio del Navigator 6 s después del OCR (`ephemeral`): fijado a los 100 s, liberado 06:00:16, 5 min exactos tras el reinicio | ✅ |
| Kubo de la Raspi4B detenido → el OCR deja de anunciar `ipfs.native.public` en 5 s; al volver, lo recupera en 15 s | ✅ |
| Perímetro desde el Mac: `5001` y `8099` cerrados en ambas IPs; `http://…:8090` sin respuesta, `https://…:8090` sí | ✅ |
| Kubo: 403 sin token; cada token solo llega a sus rutas | ✅ |

Pendiente, no bloqueante: abrir el CID desde `https://ipfs.io/ipfs/<cid>`
fuera de la LAN (depende del NAT).

## Operación

```bash
# Llamadas manuales con el token de operador (el token no va en argv)
curl -s -X POST -H @$HOME/secrets/ipfs/operator.header http://127.0.0.1:5001/api/v0/swarm/peers
curl -s -X POST -H @$HOME/secrets/ipfs/operator.header "http://127.0.0.1:5001/api/v0/pin/ls?type=recursive"
podman logs --tail 50 fhs-ipfs
```

El Kubo de Bastion es **exclusivo del Navigator**: no fijar archivos a mano
(el Navigator reporta como error un pin que no está en su libro y un pin
manual sobre un CID suyo se perdería al liberarlo).

## Paso a red privada (después de la demo)

Solo configuración, con procedimiento de corte (DEC-0095): manifiesto del
estado, detener los Kubo públicos, volúmenes e identidades **nuevos**,
`swarm.key` (0600, fuera del repo) con `LIBP2P_FORCE_PNET=1`, `Bootstrap=[]`,
`Routing.Type=none`, peering regenerado con los PeerID nuevos,
`IPFS_NETWORK=private` en Navigator y OCR, y repetir la compuerta. Lo que se
publicó en la fase pública sigue siendo público.
