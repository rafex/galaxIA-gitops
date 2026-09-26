#!/usr/bin/env bash
# doctor.sh — diagnóstico de red de galaxIA desde la máquina que va a usar el
# portal (p. ej. la laptop de una demo), ANTES de abrir el navegador.
#
# Verifica lo que el navegador va a necesitar alcanzar y por qué podría fallar
# en silencio:
#   - el portal responde y sirve p2p-config.json
#   - cada bootstrap (Atlas) y cada dirección de Navigator: TCP, TLS,
#     certificado (el SAN cubre la IP/host marcado, vencimiento, autofirmado)
#   - el reloj de esta máquina vs. el del servidor (los anuncios firmados se
#     rechazan con más de 5 s de desfase)
#   - la red P2P vista por Atlas y Navigator (/status): peers, malla
#     GossipSub y providers conocidos
#
# Solo usa bash, curl y openssl (sin jq).
#
# Uso:
#   scripts/doctor.sh https://192.168.1.239:8443
#   PORTAL_URL=... ATLAS_API=https://192.168.1.139:8081 NAVIGATOR_API=https://192.168.1.139:8090 scripts/doctor.sh
#   EXPECTED_PEERS=5 scripts/doctor.sh https://192.168.1.239:8443
#
# ATLAS_API/NAVIGATOR_API son opcionales: si faltan se derivan del host del
# primer bootstrap (puertos 8081/8090). Exit code 1 si hay algún ❌.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  # No pisa variables ya definidas en el entorno.
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < "$SCRIPT_DIR/../.env"
fi

PORTAL_URL="${1:-${PORTAL_URL:-}}"
if [[ -z "$PORTAL_URL" ]]; then
  echo "Uso: $0 <PORTAL_URL>   (p. ej. https://192.168.1.239:8443)" >&2
  exit 2
fi
PORTAL_URL="${PORTAL_URL%/}"
TIMEOUT="${DOCTOR_TIMEOUT:-4}"
MAX_SKEW_SECONDS=5
FAILURES=0
WARNINGS=0

if [[ -t 1 ]]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; else BOLD=""; DIM=""; RESET=""; fi

row() { # estado, qué, destino, detalle, [pista]
  local mark
  case "$1" in
    ok) mark="✅" ;;
    warn) mark="⚠️ "; WARNINGS=$((WARNINGS + 1)) ;;
    fail) mark="❌"; FAILURES=$((FAILURES + 1)) ;;
    *) mark="  " ;;
  esac
  printf '%s %-22s %-44s %s\n' "$mark" "$2" "$3" "$4"
  [[ -n "${5:-}" ]] && printf '   %s↳ %s%s\n' "$DIM" "$5" "$RESET"
  return 0
}

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

# host y puerto de una multiaddr /ip4|ip6|dns4|dns6|dns/<host>/tcp/<puerto>/...
ma_host() { echo "$1" | cut -d/ -f3; }
ma_port() { echo "$1" | cut -d/ -f5; }
ma_proto() { echo "$1" | cut -d/ -f2; }
url_for() { # host puerto proto
  if [[ "$3" == "ip6" ]]; then echo "https://[$1]:$2/"; else echo "https://$1:$2/"; fi
}
is_loopback() { [[ "$1" == "localhost" || "$1" == "::1" || "$1" =~ ^127\. ]]; }

# Clasifica la conexión TCP+TLS con los códigos de salida de curl.
probe() { # url → deja PROBE_STATE (ok|fail) y PROBE_DETAIL
  local url="$1" code http
  http=$(curl -sk --connect-timeout "$TIMEOUT" --max-time $((TIMEOUT + 2)) -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  code=$?
  case $code in
    0|52|56) PROBE_STATE=ok; PROBE_DETAIL="TCP+TLS OK (HTTP $http)" ;;
    6) PROBE_STATE=fail; PROBE_DETAIL="no se resuelve el nombre" ;;
    7) PROBE_STATE=fail; PROBE_DETAIL="conexión rechazada o host inalcanzable" ;;
    28) PROBE_STATE=fail; PROBE_DETAIL="tiempo agotado (${TIMEOUT}s): host inalcanzable o firewall" ;;
    35) PROBE_STATE=fail; PROBE_DETAIL="falló el handshake TLS" ;;
    *) PROBE_STATE=fail; PROBE_DETAIL="curl terminó con código $code" ;;
  esac
}

# Revisa el certificado que presenta host:puerto.
check_cert() { # nombre host puerto proto
  local name="$1" host="$2" port="$3" proto="$4" pem text san subject issuer target
  target="$host:$port"
  [[ "$proto" == "ip6" ]] && target="[$host]:$port"
  pem=$(openssl s_client -connect "$target" -servername "$host" </dev/null 2>/dev/null | openssl x509 2>/dev/null)
  if [[ -z "$pem" ]]; then
    row fail "$name (cert)" "$target" "no se pudo leer el certificado"
    return
  fi
  text=$(echo "$pem" | openssl x509 -noout -text 2>/dev/null)
  san=$(echo "$text" | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^ *//')
  subject=$(echo "$pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')
  issuer=$(echo "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')

  local covered=no
  if [[ "$proto" == "ip4" || "$proto" == "ip6" ]]; then
    echo "$san" | grep -qE "IP Address:${host}(,|$)" && covered=yes
  else
    echo "$san" | grep -qE "DNS:${host}(,|$)" && covered=yes
    echo "$san" | grep -qE "DNS:\*\.${host#*.}(,|$)" && covered=yes
  fi

  if ! echo "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    row fail "$name (cert)" "$target" "certificado VENCIDO" "Regenerar/renovar el certificado en el host."
  elif [[ "$covered" == no ]]; then
    row fail "$name (cert)" "$target" "el SAN no incluye $host" "SAN actual: ${san:-ninguno}. Regenerar el cert con $host en el SAN (los peers libp2p validan el SAN)."
  elif ! echo "$pem" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
    row warn "$name (cert)" "$target" "vence en menos de 30 días"
  elif [[ "$subject" == "$issuer" ]]; then
    row warn "$name (cert)" "$target" "autofirmado; SAN OK" "Cada navegador debe aceptar la excepción abriendo $(url_for "$host" "$port" "$proto") antes de usar el portal."
  else
    row ok "$name (cert)" "$target" "SAN OK, firmado por ${issuer##*CN=}"
  fi
}

check_endpoint() { # nombre multiaddr → 0 si TCP+TLS OK
  local name="$1" ma="$2" host port proto
  proto=$(ma_proto "$ma"); host=$(ma_host "$ma"); port=$(ma_port "$ma")
  if [[ -z "$host" || -z "$port" ]]; then
    row fail "$name" "$ma" "multiaddr sin host/puerto TCP"
    return 1
  fi
  probe "$(url_for "$host" "$port" "$proto")"
  if [[ "$PROBE_STATE" == ok ]]; then
    row ok "$name" "$host:$port" "$PROBE_DETAIL"
    check_cert "$name" "$host" "$port" "$proto"
    return 0
  fi
  row fail "$name" "$host:$port" "$PROBE_DETAIL" "Desde esta red no se llega a $host:$port. Revisa que el host esté en la misma red o en una ruta alcanzable, y el firewall del host."
  return 1
}

api_hint() { # url de una API de observabilidad (8081 Atlas / 8090 Navigator)
  local port="${1##*:}"; port="${port%%/*}"
  echo "API de observabilidad, solo LAN. En la misma red: el firewall del host probablemente bloquea el puerto (con UFW: sudo ufw allow ${port}/tcp). Detrás del túnel de la demo es esperado: ${port} no se tunela."
}

json_number() { echo "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | cut -d: -f2; }
json_multiaddrs() { echo "$1" | grep -oE '"/(ip4|ip6|dns4|dns6|dns)/[^"]+"' | tr -d '"'; }

epoch_from_http_date() { # "Sat, 26 Sep 2026 19:02:11 GMT"
  date -j -u -f "%a, %d %b %Y %H:%M:%S GMT" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

printf '%sgalaxIA doctor%s — %s — desde %s\n' "$BOLD" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)"

# ── Portal ────────────────────────────────────────────────────────────────
section "Portal"
portal_hostport="${PORTAL_URL#https://}"; portal_hostport="${portal_hostport%%/*}"
portal_host="${portal_hostport%:*}"; portal_port="${portal_hostport##*:}"
[[ "$portal_port" == "$portal_hostport" ]] && portal_port=443
probe "$PORTAL_URL/"
if [[ "$PROBE_STATE" == ok ]]; then
  row ok "portal" "$portal_hostport" "$PROBE_DETAIL"
  check_cert "portal" "$portal_host" "$portal_port" "$( [[ "$portal_host" =~ ^[0-9.]+$ ]] && echo ip4 || echo dns4 )"
else
  row fail "portal" "$portal_hostport" "$PROBE_DETAIL" "Sin portal no hay nada que probar: revisa que el contenedor fhs-portal-chat corra y el puerto esté abierto."
fi

# Reloj: el portal responde con Date; los anuncios P2P firmados toleran 5 s.
server_date=$(curl -skI --connect-timeout "$TIMEOUT" "$PORTAL_URL/" 2>/dev/null | grep -i '^date:' | cut -d' ' -f2- | tr -d '\r')
if [[ -n "$server_date" ]]; then
  server_epoch=$(epoch_from_http_date "$server_date")
  if [[ -n "$server_epoch" ]]; then
    skew=$(( $(date -u +%s) - server_epoch ))
    abs=${skew#-}
    if (( abs > MAX_SKEW_SECONDS )); then
      row fail "reloj" "esta máquina vs portal" "desfase de ${skew} s" "Con más de ${MAX_SKEW_SECONDS} s el navegador rechaza los anuncios firmados de Navigator (y no dice nada). Sincroniza la hora (NTP) de esta máquina o del servidor."
    else
      row ok "reloj" "esta máquina vs portal" "desfase de ${skew} s (tolerancia ${MAX_SKEW_SECONDS} s)"
    fi
  fi
fi

config=$(curl -sk --connect-timeout "$TIMEOUT" "$PORTAL_URL/p2p-config.json" 2>/dev/null)
bootstraps=$(json_multiaddrs "$config")
if [[ -z "$bootstraps" ]]; then
  row fail "p2p-config.json" "$PORTAL_URL/p2p-config.json" "sin bootstrapAddrs" "El contenedor del portal necesita FHS_BOOTSTRAP_ADDRS con la multiaddr TLS de Atlas."
else
  row ok "p2p-config.json" "$PORTAL_URL/p2p-config.json" "$(echo "$bootstraps" | wc -l | tr -d ' ') bootstrap(s)"
fi

# ── Bootstrap (Atlas) ─────────────────────────────────────────────────────
section "Bootstrap (Atlas) — el navegador se conecta aquí primero"
bootstrap_ok=0
first_bootstrap_host=""
for ma in $bootstraps; do
  [[ -z "$first_bootstrap_host" ]] && first_bootstrap_host=$(ma_host "$ma")
  check_endpoint "atlas" "$ma" && bootstrap_ok=$((bootstrap_ok + 1))
done
if [[ -n "$bootstraps" && $bootstrap_ok -eq 0 ]]; then
  row fail "bootstrap" "(ninguno)" "ningún bootstrap alcanzable" "El portal no podrá entrar a la red P2P."
fi

ATLAS_API="${ATLAS_API:-${first_bootstrap_host:+https://$first_bootstrap_host:8081}}"
NAVIGATOR_API="${NAVIGATOR_API:-${first_bootstrap_host:+https://$first_bootstrap_host:8090}}"

# ── Red P2P vista por Atlas ───────────────────────────────────────────────
if [[ -n "$ATLAS_API" ]]; then
  section "Red P2P vista por Atlas ($ATLAS_API)"
  status=$(curl -sk --connect-timeout "$TIMEOUT" "${ATLAS_API%/}/status" 2>/dev/null)
  peers=$(json_number "$status" peerCount)
  if [[ -z "$peers" ]]; then
    probe "${ATLAS_API%/}/health"
    row warn "atlas /status" "$ATLAS_API" "no responde: $PROBE_DETAIL" "$(api_hint "$ATLAS_API")"
  elif [[ -n "${EXPECTED_PEERS:-}" && "$peers" -lt "$EXPECTED_PEERS" ]]; then
    row fail "peers en Atlas" "$ATLAS_API" "$peers de $EXPECTED_PEERS esperados" "Falta algún nodo: revisa sus logs (bootstrap no disponible…) o que esté encendido."
  else
    row ok "peers en Atlas" "$ATLAS_API" "$peers conectados${EXPECTED_PEERS:+ (esperados $EXPECTED_PEERS)}"
  fi
fi

# ── Navigator ─────────────────────────────────────────────────────────────
if [[ -n "$NAVIGATOR_API" ]]; then
  section "Navigator — el navegador lo dialea directo tras descubrirlo"
  health=$(curl -sk --connect-timeout "$TIMEOUT" "${NAVIGATOR_API%/}/health" 2>/dev/null)
  nav_addrs=$(json_multiaddrs "$health")
  if [[ -z "$health" ]]; then
    probe "${NAVIGATOR_API%/}/health"
    row warn "navigator /health" "$NAVIGATOR_API" "no responde: $PROBE_DETAIL" "$(api_hint "$NAVIGATOR_API") Sin ella no puedo listar sus direcciones P2P."
  elif [[ -z "$nav_addrs" ]]; then
    row warn "navigator /health" "$NAVIGATOR_API" "sin multiaddrs (versión anterior de Navigator)"
  else
    nav_ok=0; nav_total=0
    for ma in $nav_addrs; do
      host=$(ma_host "$ma")
      if is_loopback "$host"; then
        row info "navigator" "$host:$(ma_port "$ma")" "loopback anunciado; no aplica desde otro equipo"
        continue
      fi
      nav_total=$((nav_total + 1))
      if check_endpoint "navigator" "$ma"; then nav_ok=$((nav_ok + 1)); fi
    done
    if (( nav_total > 0 && nav_ok == 0 )); then
      row fail "navigator" "(todas)" "ninguna dirección de Navigator alcanzable" "El portal descubrirá a Navigator pero no podrá conectarse: justo el fallo que antes era silencioso."
    elif (( nav_ok < nav_total )); then
      row warn "navigator" "($nav_ok de $nav_total)" "algunas direcciones no son alcanzables desde aquí" "Normal si Navigator tiene interfaces en otras redes; basta con que una funcione."
    fi
    status=$(curl -sk --connect-timeout "$TIMEOUT" "${NAVIGATOR_API%/}/status" 2>/dev/null)
    if [[ -n "$status" ]]; then
      for type in star satellite multi; do
        count=$(echo "$status" | grep -oE "\"peerType\":\"$type\"" | wc -l | tr -d ' ')
        (( count > 0 )) && row ok "providers ($type)" "$NAVIGATOR_API" "$count anunciado(s)"
      done
      mesh=$(echo "$status" | grep -oE '"fhs/v1/nodes/advertise":\{"subscribers":[0-9]+,"mesh":[0-9]+\}' | grep -oE '"mesh":[0-9]+' | cut -d: -f2)
      if [[ -n "$mesh" ]]; then
        if (( mesh == 0 )); then
          row fail "malla GossipSub" "fhs/v1/nodes/advertise" "0 peers en la malla" "Navigator no recibe ni envía anuncios: NoPeersSubscribedToTopic. Revisa la conexión al bootstrap."
        else
          row ok "malla GossipSub" "fhs/v1/nodes/advertise" "$mesh peer(s) en la malla"
        fi
      fi
    fi
  fi
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf '%s❌ %d problema(s), %d advertencia(s).%s\n' "$BOLD" "$FAILURES" "$WARNINGS" "$RESET"
  exit 1
fi
printf '%s✅ Sin problemas bloqueantes%s (%d advertencia(s)).\n' "$BOLD" "$RESET" "$WARNINGS"
