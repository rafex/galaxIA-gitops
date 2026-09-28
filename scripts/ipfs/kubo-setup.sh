#!/usr/bin/env bash
# Instala o reconfigura el nodo Kubo (IPFS) de un host de la PoC: contenedor
# `fhs-ipfs`, volumen `ipfs-data`. Se corre EN el host (Bastion o Raspi4B).
#
#   kubo-setup.sh --role navigator|ocr [--peer <multiaddr>/p2p/<PeerID>]
#
# Red pública para la demo (DEC-0095): DHT en modo cliente, swarm en 4101
# (4001 es de Atlas), sin mDNS, sin anunciar direcciones privadas y peering
# estático con el otro nodo por la LAN. La API queda en 127.0.0.1:5001 con
# API.Authorizations: sin token no responde nada.
#
# Tokens: se generan una vez en $SECRETS_DIR (0600, fuera del repo):
#   <rol>.token          token del cliente (Navigator u OCR), rutas acotadas
#   operator.token       token de operador (todo /api/v0)
#   operator.header      "Authorization: Bearer …" para `curl -H @archivo`
# Los tokens quedan también dentro de la config de Kubo (volumen ipfs-data).
#
# Idempotente: se puede volver a correr para cambiar el peer. Detiene el
# contenedor, reescribe la config sin daemon y lo vuelve a crear.
set -euo pipefail

KUBO_IMAGE="${KUBO_IMAGE:-docker.io/ipfs/kubo:v0.43.1}"
SECRETS_DIR="${SECRETS_DIR:-$HOME/secrets/ipfs}"
CONTAINER="${CONTAINER:-fhs-ipfs}"
VOLUME="${VOLUME:-ipfs-data}"
SWARM_PORT="${SWARM_PORT:-4101}"
API_PORT="${API_PORT:-5001}"
# Límites de memoria (guía de Kubo para equipos modestos):
# GOMEMLIMIT < memoria del contenedor.
GOMEMLIMIT="${GOMEMLIMIT:-768MiB}"
MEMORY="${MEMORY:-1g}"
STORAGE_MAX="${STORAGE_MAX:-5GB}"

role=""
peer=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="${2:-}"; shift 2 ;;
    --peer) peer="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

case "$role" in
  navigator)
    # add + pin rm/ls para el libro de pines; repo/stat y diag/sys para cuotas.
    client_paths='["/api/v0/add","/api/v0/pin/rm","/api/v0/pin/ls","/api/v0/repo/stat","/api/v0/diag/sys","/api/v0/id"]' ;;
  ocr)
    # Solo leer y comprobar su salud (API viva y peer de Bastion conectado).
    client_paths='["/api/v0/cat","/api/v0/id","/api/v0/swarm/peers"]' ;;
  *) echo "uso: $0 --role navigator|ocr [--peer <multiaddr>/p2p/<PeerID>]" >&2; exit 2 ;;
esac

peering='[]'
if [ -n "$peer" ]; then
  peer_id="${peer##*/p2p/}"
  peer_addr="${peer%/p2p/*}"
  if [ "$peer_id" = "$peer" ] || [ -z "$peer_addr" ] || ! [[ "$peer_id" =~ ^[1-9A-HJ-NP-Za-km-z]{46,}$ ]]; then
    echo "--peer debe ser <multiaddr>/p2p/<PeerID>: $peer" >&2
    exit 2
  fi
  peering="[{\"ID\":\"$peer_id\",\"Addrs\":[\"$peer_addr\"]}]"
fi

command -v podman >/dev/null || { echo "falta podman" >&2; exit 1; }

# --- Tokens (nunca en variables de entorno de un proceso largo ni en logs) ---
umask 077
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
new_token() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
for name in "$role" operator; do
  if [ ! -s "$SECRETS_DIR/$name.token" ]; then
    new_token > "$SECRETS_DIR/$name.token"
    echo "token nuevo: $SECRETS_DIR/$name.token"
  fi
  chmod 600 "$SECRETS_DIR/$name.token"
done
printf 'Authorization: Bearer %s\n' "$(cat "$SECRETS_DIR/operator.token")" > "$SECRETS_DIR/operator.header"
chmod 600 "$SECRETS_DIR/operator.header"

# --- Puertos: nada ajeno debe ocupar 4101 ni 5001 ---
if podman container exists "$CONTAINER"; then
  podman stop -t 30 "$CONTAINER" >/dev/null
  podman rm "$CONTAINER" >/dev/null
fi
for port in "$SWARM_PORT" "$API_PORT"; do
  if ss -Hltn "sport = :$port" | grep -q .; then
    echo "el puerto $port ya está en uso por otro proceso" >&2
    exit 1
  fi
done

podman volume exists "$VOLUME" || podman volume create "$VOLUME" >/dev/null

# --- Configuración sin daemon ---
# Corre como root del contenedor para leer los tokens montados y al final
# devuelve el repositorio al usuario `ipfs` (uid 1000) de la imagen.
podman run --rm -i --network none \
  --entrypoint /bin/sh \
  -v "$VOLUME:/data/ipfs" \
  -v "$SECRETS_DIR:/secrets:ro" \
  -e ROLE="$role" -e CLIENT_PATHS="$client_paths" -e PEERING="$peering" \
  -e SWARM_PORT="$SWARM_PORT" -e API_PORT="$API_PORT" -e STORAGE_MAX="$STORAGE_MAX" \
  "$KUBO_IMAGE" -s <<'EOF'
set -eu
[ -f "$IPFS_PATH/config" ] || ipfs init --empty-repo >/dev/null
# `init` fija el directorio vacío; el libro de pines del Navigator lo
# reportaría como pin ajeno. No se toca ningún otro pin.
ipfs pin rm QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn >/dev/null 2>&1 || true
c() { ipfs config "$@"; }
c Addresses.API "/ip4/127.0.0.1/tcp/$API_PORT"
c --json Addresses.Gateway '[]'
c --json Addresses.Swarm "[\"/ip4/0.0.0.0/tcp/$SWARM_PORT\",\"/ip4/0.0.0.0/udp/$SWARM_PORT/quic-v1\"]"
c --json Addresses.NoAnnounce '["/ip4/10.0.0.0/ipcidr/8","/ip4/172.16.0.0/ipcidr/12","/ip4/192.168.0.0/ipcidr/16","/ip4/127.0.0.0/ipcidr/8","/ip4/169.254.0.0/ipcidr/16","/ip6/fc00::/ipcidr/7","/ip6/fe80::/ipcidr/10","/ip6/::1/ipcidr/128"]'
c --json Discovery.MDNS.Enabled false
c --json AutoTLS.Enabled false
c Routing.Type autoclient
c AutoNAT.ServiceMode disabled
c --json Swarm.RelayService.Enabled false
c --json Swarm.ConnMgr '{"Type":"basic","LowWater":50,"HighWater":100,"GracePeriod":"20s"}'
c --json Provide.DHT.MaxWorkers 4
c Datastore.StorageMax "$STORAGE_MAX"
c Datastore.GCPeriod 1h
c --json Peering.Peers "$PEERING"
client="$(cat "/secrets/$ROLE.token")"
operator="$(cat /secrets/operator.token)"
c --json API.Authorizations "{\"$ROLE\":{\"AuthSecret\":\"bearer:$client\",\"AllowedPaths\":$CLIENT_PATHS},\"operator\":{\"AuthSecret\":\"bearer:$operator\",\"AllowedPaths\":[\"/api/v0\"]}}"
chown -R 1000:100 "$IPFS_PATH"
echo "PeerID: $(ipfs config Identity.PeerID)"
EOF

# --- Daemon ---
# Sin healthcheck de la imagen: llama a la API sin token y siempre daría 403.
podman run -d --name "$CONTAINER" \
  --network host --restart always \
  --memory "$MEMORY" -e GOMEMLIMIT="$GOMEMLIMIT" \
  --health-cmd none \
  -v "$VOLUME:/data/ipfs" \
  "$KUBO_IMAGE" daemon --migrate=true --agent-version-suffix=docker --enable-gc >/dev/null

# --- Verificación ---
api="http://127.0.0.1:$API_PORT/api/v0"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H @"$SECRETS_DIR/operator.header" "$api/id" || true)"
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ] || { echo "la API no respondió con el token de operador" >&2; podman logs --tail 30 "$CONTAINER" >&2; exit 1; }

anon="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$api/config?arg=Identity.PeerID")"
if [ "$anon" != 403 ] && [ "$anon" != 401 ]; then
  echo "ERROR: la API respondió $anon sin token; la autorización no está activa" >&2
  podman stop "$CONTAINER" >/dev/null
  exit 1
fi
if ss -Hltn "sport = :$API_PORT" | awk '{print $4}' | grep -vqE '^(127\.0\.0\.1|\[::1\]):'; then
  echo "ERROR: la API escucha fuera de loopback" >&2
  podman stop "$CONTAINER" >/dev/null
  exit 1
fi

id_json="$(curl -s -X POST -H @"$SECRETS_DIR/operator.header" "$api/id")"
peer_id="$(printf '%s' "$id_json" | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p')"
echo "fhs-ipfs listo (rol $role, $KUBO_IMAGE)"
echo "PeerID: $peer_id"
echo "Sin token: $anon. API solo en loopback."
echo "Para el peering del otro nodo: /ip4/<IP LAN de este host>/tcp/$SWARM_PORT/p2p/$peer_id"
