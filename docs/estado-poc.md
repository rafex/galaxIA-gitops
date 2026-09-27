# Estado de la PoC

> **Snapshot: 2026-09-26 20:20 (CST).** Se actualiza a mano. Cada dato sale
> de un comando corrido en ese momento (`podman ps/inspect`, `/status`,
> `/health`, `doctor.sh`); no se copia de la memoria. Arquitectura y
> porqués: [`arquitectura-poc.md`](arquitectura-poc.md).

## En una línea

El stack **está arriba**: el portal, Atlas, Navigator, Star, KB, RAG y el LLM responden. Bastion y la Raspi3B reiniciaron y
**volvieron solos**, y es la primera vez que eso se ve en un reinicio real.
Pero **OCR quedó fuera de la red** (Atlas ve 4 de 5 peers), y casi todos los
contenedores corren una imagen anterior a los últimos fixes.

![Estado actual](diagramas/estado-actual.svg)

## Por equipo

| Equipo | Arriba | Contenedores | Código desplegado | `main` | Nota |
|---|---|---|---|---|---|
| Bastion `.139` | 12 min (reinició) | `fhs-atlas`, `fhs-navigator`, `fhs-star`: Up, `restart=always` | Core `fcdd532` · satellite-star `be0ac3c` | Core `47a1f65` · satellite-star `ebf0299` | `llama-server` activo (`systemd --user`), qwen2.5-3b cargado. 14 GB libres |
| Raspi4B `.167` | 7 h 55 min (**no** reinició) | `fhs-satellite-ocr`: Up, pero **aislado** | imagen del 2026-08-30 | `ebf0299` ya construida, **sin recrear** | Log: `NoPeersSubscribedToTopic` en bucle |
| Raspi3B `.181` | 11 min (reinició) | `fhs-kb-provider`, `fhs-rag-provider`: Up, conectados | imagen del 2026-08-30 | repo en `ebf0299`, **sin reconstruir** | 776 MB disponibles con ambos arriba |
| ThinkPad `.239` | 1 d 6 h | `fhs-portal-chat`: Up | `77a0919` | `77a0919` (sin cambios de portal después) | Ya trae el panel 🩺 |
| Router `.1` | — | OpenWrt 25.12.5 | — | — | 6 reservas DHCP: bastion, raspi4b, portal-pi, thinkpad, macos, alqrab |

### Red P2P vista desde adentro

- **Atlas** (`/status`): `peerCount: 4` de 5 → conectados Navigator, Star,
  KB y RAG. **Falta OCR.**
- **Navigator** (`/status`): conectado a Atlas. Conoce a `star` (`chat`),
  `rag` (`document.index`, `document.query`) y `kb` (`knowledge.query`).
  OCR no aparece.
- **Malla GossipSub:** `nodes/advertise` 1, `missions/offer` 3,
  `missions/assign` 3, `missions/bid` 1, `reputation/update` 0.

### `doctor.sh` desde el Mac

```
EXPECTED_PEERS=5 scripts/doctor.sh https://192.168.1.239:8443
```

| Chequeo | Resultado |
|---|---|
| Portal `.239:8443` | ✅ TCP+TLS, HTTP 200 · ⚠️ autofirmado (SAN OK) |
| Reloj Mac vs portal | ✅ desfase 0 s |
| `p2p-config.json` | ✅ 1 bootstrap |
| Atlas `.139:4001` | ✅ TCP+TLS · ⚠️ autofirmado (SAN OK) |
| Peers en Atlas | ❌ **4 de 5** |
| Navigator `.139:4010` (y las IPs Netup `.3.143` y `.3.175`) | ✅ TCP+TLS · ⚠️ autofirmado (SAN OK) |
| Providers en Navigator | ✅ 1 star, 2 satellite |
| Malla `nodes/advertise` | ✅ 1 peer |

Resultado: **1 problema, 5 advertencias.** Las advertencias son las
excepciones de certificado autofirmado; son de esperar en la LAN.

## Por qué OCR quedó fuera

Es exactamente la falla que corrigen `fcdd532` y `be0ac3c`. Cuando Bastion
reinició, el OCR de la Raspi4B (que no reinició) perdió la conexión con
Atlas. Su imagen del 30 de agosto marca al bootstrap **una sola vez al
arrancar**, así que nunca volvió a entrar. La Raspi3B no tuvo el problema
por suerte: reinició junto con Bastion y sus providers arrancaron cuando
Atlas ya estaba arriba.

**Arreglo:** recrear `fhs-satellite-ocr` con la imagen `ebf0299` que ya
está construida en la Raspi4B. Mientras tanto, `podman restart
fhs-satellite-ocr` debería bastar para que vuelva a entrar: el único
intento de conexión ocurre al arrancar.

## Qué funciona (verificado)

- Chat y OCR de punta a punta por P2P: verificados en rondas anteriores (con
  un cliente de prueba y desde el navegador en la red Netup). **En la red
  soberana todavía no:** el primer intento desde Firefox se quedó
  "reintentando" porque el navegador rechazó en silencio el certificado de
  `:4010` (`E2E-025`). De ahí salió el panel 🩺. Hay que repetir la prueba.
- Reserva DHCP de los 5 equipos. Las IPs no se movieron tras los reinicios.
- **Los contenedores vuelven solos tras reiniciar el host** (`restart
  always` + `podman-restart.service`), y `llama-server` también (`systemd
  --user`). Probado hoy en Bastion y la Raspi3B.
- Reconexión al bootstrap cuando se cae Atlas: probado en vivo con
  `fcdd532` y `be0ac3c` ("bootstrap reconectado … (intento 2)").
- Diagnóstico: panel 🩺 en el portal, `/status` en Atlas y Navigator,
  `doctor.sh`.
- La API de Atlas (`:8081`) **responde desde la LAN**: `doctor.sh` la leyó
  desde el Mac.

## Pendiente de despliegue

| Dónde | Qué | Por qué |
|---|---|---|
| Raspi4B | Recrear `fhs-satellite-ocr` con `ebf0299` (ya construida) | Vuelve a la red y de ahí en adelante reconecta solo |
| Raspi3B | Reconstruir kb y luego rag (**una por una**) con `ebf0299` y recrearlos | Hoy corren sin reconexión: el próximo reinicio de Bastion los deja aislados igual que a OCR |
| Bastion | Reconstruir con `47a1f65`/`ebf0299` y recrear Atlas, Navigator y Star | Los errores de WebSocket en los logs salen como `[object ErrorEvent]` en lugar del mensaje real |

Criterio de cierre: Atlas `peerCount: 5` y `doctor.sh` sin ❌.

## Problemas conocidos (sin resolver)

- **El beacon en la DHT no se publica nunca a tiempo** (Navigator y Star
  terminan en timeout). No bloquea nada porque el descubrimiento por
  GossipSub funciona, pero la DHT hoy no aporta.
- **Navigator ignora SIGTERM.** `podman stop` o un reinicio esperan 10 s y
  lo matan. No pierde datos, pero cada reinicio tarda más de lo necesario.
- **Certificados autofirmados:** cada navegador nuevo tiene que aceptar la
  excepción en el portal, en `:4001` y en `:4010`. El panel 🩺 da el enlace
  de cada uno. Solución definitiva: Let's Encrypt en la demo remota.
- **Bastion es un punto único de falla** para el bootstrap, el orquestador,
  el LLM y el acceso a la Raspi3B.

## Pendiente del operador

- Prueba en Firefox en **ventana privada** (sin excepciones guardadas). El
  panel 🩺 debe decir que encontró a Navigator pero falló
  `wss://192.168.1.139:4010`, y ofrecer el enlace para aceptar el
  certificado.
- En el Mac, dejar la dirección Wi-Fi privada en **"Fija"** para la red
  galaxIA. La reserva DHCP del Mac depende de esa MAC.
- Opcional: limpiar las llaves viejas del Mac con `ssh-keygen -R 192.168.1.1`
  y `ssh-keygen -R 192.168.1.181`.

## Siguiente hito

1. Cerrar el despliegue pendiente (peers 5/5) y marcar `TASK-MVPH-0005`
   como hecha en `galaxIA/spec-native/tasks/mvp-hardening/TASKS.md`.
2. **Demo remota** (ver
   [`arquitectura-poc.md#demo-remota-cómo-se-espera-que-funcione`](arquitectura-poc.md#demo-remota-cómo-se-espera-que-funcione)):
   faltan el subdominio y el acceso al VPS.
