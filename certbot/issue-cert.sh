#!/usr/bin/env bash
# certbot/issue-cert.sh — emisión inicial del certificado Let's Encrypt.
# Corre EN EL VPS (es el punto público de entrada, responde el desafío
# HTTP-01 directamente — el DNS de rafex.io/rafex.app es autogestionado,
# sin plugin DNS-01 disponible, ver docs/acceso-remoto-demo.md).
#
# Requiere:
#   - Registro A de $DEMO_DOMAIN apuntando a la IP pública de este VPS
#   - Puerto 80 libre (rathole NO debe tunelear el 80 — solo 443/4001/4010)
#   - certbot instalado (apt install certbot / dnf install certbot)
#
# Uso:
#   set -a && source ../.env && set +a && bash issue-cert.sh

set -euo pipefail

: "${DEMO_DOMAIN:?Definí DEMO_DOMAIN en .env (ej. demo.rafex.io)}"

echo "→ Emitiendo certificado para ${DEMO_DOMAIN} (desafío HTTP-01, standalone)"

sudo certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  -d "${DEMO_DOMAIN}"

echo "✓ Certificado emitido en /etc/letsencrypt/live/${DEMO_DOMAIN}/"
echo ""
echo "Siguiente paso: instalar el hook de renovación"
echo "  sudo cp renewal-hooks/deploy/sync-to-bastion.sh /etc/letsencrypt/renewal-hooks/deploy/"
echo "  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/sync-to-bastion.sh"
echo ""
echo "Y correr una vez a mano para poblar el certificado inicial en Bastion:"
echo "  sudo DEMO_DOMAIN=${DEMO_DOMAIN} BASTION_HOST=\$BASTION_HOST BASTION_SSH_USER=\$BASTION_SSH_USER \\"
echo "    /etc/letsencrypt/renewal-hooks/deploy/sync-to-bastion.sh"
