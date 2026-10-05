#!/usr/bin/env bash
# Desinstala "Mantenimiento coches". Los datos se conservan salvo que uses --purge.
# Uso: sudo ./uninstall.sh [--purge] [--yes]
set -Eeuo pipefail
APP_NAME="mantenimiento-coches"
SERVICE_USER="mantenimiento"
APP_DIR="/opt/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}.env"
PURGE=0 YES=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opción desconocida: $a" >&2; exit 1 ;;
  esac
done
[[ "$(id -u)" -eq 0 ]] || { echo "Ejecútalo como root: sudo ./uninstall.sh" >&2; exit 1; }

DATA_DIR="/var/lib/${APP_NAME}"
PORT=""
if [[ -f "$ENV_FILE" ]]; then
  d="$(sed -n 's/^MC_DATA_DIR="\{0,1\}\(.*[^"]\)"\{0,1\}$/\1/p' "$ENV_FILE" | head -n1)"
  [[ -n "$d" ]] && DATA_DIR="$d"
  PORT="$(sed -n 's/^MC_PORT="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$ENV_FILE" | head -n1)"
fi

if [[ "$YES" -eq 0 ]]; then
  msg="Se eliminará la aplicación"
  [[ "$PURGE" -eq 1 ]] && msg="$msg Y TODOS LOS DATOS de $DATA_DIR"
  read -r -p "$msg. ¿Continuar? [s/N] " r
  [[ "$r" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

REPO="$(sed -n 's|^ExecStart=\(.*\)/scripts/deploy.sh.*|\1|p' "/etc/systemd/system/${APP_NAME}-deploy.service" 2>/dev/null | head -n1)"

systemctl disable --now "${APP_NAME}-deploy.path" "${APP_NAME}-pull.timer" "${APP_NAME}-backup.timer" "${APP_NAME}.service" 2>/dev/null || true
for u in "" -backup -deploy -pull; do rm -f "/etc/systemd/system/${APP_NAME}${u}.service"; done
rm -f "/etc/systemd/system/${APP_NAME}-backup.timer" "/etc/systemd/system/${APP_NAME}-pull.timer" \
      "/etc/systemd/system/${APP_NAME}-deploy.path" "$ENV_FILE"
systemctl daemon-reload 2>/dev/null || true
# Se borra solo la carpeta de releases generada; el repositorio clonado no se toca.
[[ -n "$REPO" && -d "$REPO/.deploy" ]] && rm -rf "$REPO/.deploy"
rm -rf "$APP_DIR" "${APP_DIR}.previous"
if command -v ufw >/dev/null && [[ -n "$PORT" ]] && ufw status 2>/dev/null | grep -q "^Status: active"; then
  ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
fi
if [[ "$PURGE" -eq 1 ]]; then
  # Solo se borra si realmente es un directorio de datos de esta aplicación.
  if [[ "$DATA_DIR" == /* && "$DATA_DIR" != "/" && -f "$DATA_DIR/coches.db" ]]; then rm -rf "$DATA_DIR"; fi
  userdel "$SERVICE_USER" 2>/dev/null || true
  echo "Aplicación y datos eliminados."
else
  echo "Servicio eliminado (el repositorio clonado no se ha tocado). Los datos siguen en $DATA_DIR (usa --purge para borrarlos)."
fi
