#!/usr/bin/env bash
# certbot/renewal-hooks/deploy/sync-to-bastion.sh
#
# Deploy-hook de certbot: corre automáticamente después de CADA renovación
# exitosa (certbot chequea dos veces al día, solo actúa ~30 días antes del
# vencimiento). Copia el certificado nuevo a Bastion y reinicia los
# contenedores FHS para que lo tomen.
#
# Instalar UNA vez:
#   sudo cp sync-to-bastion.sh /etc/letsencrypt/renewal-hooks/deploy/
#   sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/sync-to-bastion.sh
#
# Certbot invoca este script con RENEWED_LINEAGE y RENEWED_DOMAINS ya
# seteados — para la primera corrida manual (o para pruebas), definir
# DEMO_DOMAIN/BASTION_HOST/BASTION_SSH_USER a mano (ver .env.example).
#
# Requiere: el usuario que corre certbot (típicamente root) puede hacer
# `ssh $BASTION_SSH_USER@$BASTION_HOST` sin password (clave ya autorizada
# en Bastion — mismo patrón que el acceso SSH ya usado para administrar
# el laboratorio).

set -euo pipefail

DEMO_DOMAIN="${RENEWED_DOMAINS:-${DEMO_DOMAIN:?Definí DEMO_DOMAIN}}"
LINEAGE="${RENEWED_LINEAGE:-/etc/letsencrypt/live/${DEMO_DOMAIN}}"
: "${BASTION_HOST:?Definí BASTION_HOST}"
: "${BASTION_SSH_USER:?Definí BASTION_SSH_USER}"

FULLCHAIN="${LINEAGE}/fullchain.pem"
PRIVKEY="${LINEAGE}/privkey.pem"

if [[ ! -s "$FULLCHAIN" || ! -s "$PRIVKEY" ]]; then
  echo "✗ No se encontró el certificado en ${LINEAGE}" >&2
  exit 1
fi

ssh_target="${BASTION_SSH_USER}@${BASTION_HOST}"

echo "→ Sincronizando certificado (${DEMO_DOMAIN}) a Bastion (${ssh_target})"

# Un solo par de archivos, copiado con los 3 nombres que ya usan los
# Containerfiles de galaxIA-Core/galaxIA-satellite-star (dev.*, e2e.*) más
# el de portal-chat — mismo patrón que el certificado autofirmado unificado
# que se usaba en LAN (ver galaxIA-Core/helpers/scripts/shell/generate-dev-cert.sh).
ssh "$ssh_target" "mkdir -p ~/certs ~/certs/portal-chat"

scp -q "$FULLCHAIN" "${ssh_target}:~/certs/dev.crt"
scp -q "$PRIVKEY"   "${ssh_target}:~/certs/dev.key"
scp -q "$FULLCHAIN" "${ssh_target}:~/certs/e2e.crt"
scp -q "$PRIVKEY"   "${ssh_target}:~/certs/e2e.key"
scp -q "$FULLCHAIN" "${ssh_target}:~/certs/portal-chat/portal.crt"
scp -q "$PRIVKEY"   "${ssh_target}:~/certs/portal-chat/portal.key"

ssh "$ssh_target" "chmod 600 ~/certs/*.key ~/certs/portal-chat/*.key"

echo "→ Reiniciando contenedores en Bastion para que tomen el certificado nuevo"
ssh "$ssh_target" "podman restart fhs-atlas fhs-navigator fhs-star fhs-portal-chat"

echo "✓ Certificado sincronizado y contenedores reiniciados"
