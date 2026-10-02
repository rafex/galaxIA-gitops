#!/usr/bin/env bash
# Recrea fhs-navigator en Bastion con /calc (FHS_CALC_NODES) y deja la reversa.
#
#   deploy-navigator.sh <commit> [DID_celular[,DID_celular...]]
#
# - La imagen localhost/galaxia-agent:<commit> ya debe existir en Bastion.
# - El contenedor anterior se conserva detenido como fhs-navigator-pre-<commit>
#   (sin reinicio automático) para volver con:
#     podman rm -f fhs-navigator && podman rename fhs-navigator-pre-<commit> fhs-navigator \
#       && podman update --restart always fhs-navigator && podman start fhs-navigator
# - Sin DID, /calc responde que no hay nodos de cálculo configurados.
set -euo pipefail

commit=${1:?uso: deploy-navigator.sh <commit> [DID,...]}
calc_nodes=${2:-*}   # "*" = cualquier nodo que se anuncie con la capacidad (autodescubrimiento)
image="localhost/galaxia-agent:${commit}"
# SPEC-AUTH-0001: DIDs verificados por el operador (se muestran como "verificado" en la
# tarjeta de autorización); vacío = ninguno. FHS_AUTH_POLICY solo para pruebas sin cabeza.
trusted_nodes=${FHS_TRUSTED_NODES:-}
atlas="/ip4/192.168.1.139/tcp/4001/tls/ws/p2p/12D3KooWL2kvLw4MgPbTTpgKBMsHfVjnpp26AVL54VwWkantYHoL"

podman image exists "$image" || { echo "falta la imagen $image" >&2; exit 1; }

if podman container exists fhs-navigator; then
  podman stop -t 15 fhs-navigator >/dev/null
  if podman container exists "fhs-navigator-pre-${commit}"; then
    podman rm -f fhs-navigator >/dev/null   # ya hay reversa de este commit (reintento)
  else
    podman rename fhs-navigator "fhs-navigator-pre-${commit}"
    podman update --restart no "fhs-navigator-pre-${commit}" >/dev/null
  fi
fi

podman run -d --name fhs-navigator --network host --user 0 --restart always \
  -v navigator-data:/data \
  -v "$HOME/certs:/certs:ro" \
  -v "$HOME/secrets/ipfs/navigator.token:/secrets/ipfs.token:ro" \
  -e FHS_BOOTSTRAP_ADDRS="$atlas" \
  -e FHS_LISTEN_ADDRS=/ip4/0.0.0.0/tcp/4010/tls/ws \
  -e FHS_ANNOUNCE_ADDRS=/ip4/192.168.1.139/tcp/4010/tls/ws \
  -e FHS_ADVERTISE_AS_NAVIGATOR=true \
  -e FHS_CALC_NODES="$calc_nodes" \
  -e FHS_TRUSTED_NODES="$trusted_nodes" \
  -e AUTH_AUDIT_PATH=/data/authorization-audit.log \
  -e IDENTITY_KEY_PATH=/data/.fhs-identity-navigator.json \
  -e TLS_CERT_PATH=/certs/dev.crt -e TLS_KEY_PATH=/certs/dev.key \
  -e NODE_EXTRA_CA_CERTS=/certs/dev.crt \
  -e HOST=0.0.0.0 -e PORT=8090 \
  -e IPFS_API_URL=http://127.0.0.1:5001 -e IPFS_API_TOKEN_FILE=/secrets/ipfs.token \
  -e IPFS_NETWORK=public \
  -e COMMIT_HASH="$commit" -e BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$image"

sleep 4
podman ps --filter name=fhs-navigator --format '{{.Names}} {{.Image}} {{.Status}}'
podman logs --tail 6 fhs-navigator
