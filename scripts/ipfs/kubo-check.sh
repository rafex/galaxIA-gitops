#!/usr/bin/env bash
# Compuerta del nodo Kubo local (DEC-0095). Se corre EN el host, después de
# kubo-setup.sh en ambos nodos.
#
#   kubo-check.sh --role navigator|ocr --peer-id <PeerID del otro nodo>
#
# Comprueba:
#   - sin token, la API rechaza todo (403);
#   - el token del cliente llega a sus rutas y NO a config, key, shutdown,
#     pin/add ni a las rutas del otro rol;
#   - el otro nodo está conectado (peering por la LAN) y hay peers públicos.
# Sale con ≠ 0 si algo falla.
set -uo pipefail

SECRETS_DIR="${SECRETS_DIR:-$HOME/secrets/ipfs}"
API="${API:-http://127.0.0.1:5001/api/v0}"

role=""
peer_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="${2:-}"; shift 2 ;;
    --peer-id) peer_id="${2:-}"; shift 2 ;;
    *) echo "argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$role" ] && [ -n "$peer_id" ] || { echo "uso: $0 --role navigator|ocr --peer-id <PeerID>" >&2; exit 2; }

fails=0
ok() { echo "✅ $*"; }
ko() { echo "❌ $*"; fails=$((fails + 1)); }

# El token se pasa a curl por un archivo de cabeceras temporal, no por argv.
header="$(mktemp)"
trap 'rm -f "$header"' EXIT
chmod 600 "$header"
printf 'Authorization: Bearer %s\n' "$(cat "$SECRETS_DIR/$role.token")" > "$header"

status() { # status <ruta> [con-token]
  if [ "${2:-}" = token ]; then
    curl -s -o /dev/null -w '%{http_code}' -X POST -H @"$header" "$API/$1"
  else
    curl -s -o /dev/null -w '%{http_code}' -X POST "$API/$1"
  fi
}
expect_denied() {
  local code
  code="$(status "$1" "${2:-}")"
  if [ "$code" = 403 ]; then ok "denegado: $1${2:+ (token $role)}"; else ko "$1${2:+ (token $role)} respondió $code, se esperaba 403"; fi
}
expect_allowed() {
  local code
  code="$(status "$1" token)"
  if [ "$code" != 403 ] && [ "$code" != 401 ]; then ok "permitido: $1 ($code)"; else ko "$1 con el token de $role respondió $code"; fi
}

expect_denied "config?arg=Identity.PeerID"
expect_denied "id"
expect_allowed "id"
for path in "config?arg=Identity.PeerID" "key/list" "shutdown" "pin/add" "repo/gc"; do
  expect_denied "$path" token
done
case "$role" in
  navigator) expect_denied "cat" token ;;
  ocr) expect_denied "add" token; expect_denied "pin/rm" token; expect_denied "pin/ls" token ;;
esac

peers="$(curl -s -X POST -H @"$SECRETS_DIR/operator.header" "$API/swarm/peers")"
if printf '%s' "$peers" | grep -q "\"Peer\":\"$peer_id\""; then
  addr="$(printf '%s' "$peers" | tr '{' '\n' | grep "\"Peer\":\"$peer_id\"" | sed -n 's/.*"Addr":"\([^"]*\)".*/\1/p')"
  ok "peering conectado con $peer_id ($addr)"
else
  ko "el otro nodo ($peer_id) no está conectado"
fi
total="$(printf '%s' "$peers" | grep -o '"Peer":"' | wc -l | tr -d ' ')"
if [ "$total" -gt 1 ]; then ok "$total peers conectados (red pública)"; else ko "solo $total peers: ¿sin salida a la red pública?"; fi

[ "$fails" -eq 0 ] && echo "compuerta Kubo ($role): OK" || echo "compuerta Kubo ($role): $fails fallas"
exit "$fails"
