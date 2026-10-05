#!/usr/bin/env bash
# Instalador de "Mantenimiento coches" para Ubuntu (20.04 o superior) con systemd.
# Uso: sudo ./install.sh [--port N] [--password CLAVE | --no-password] [--host IP]
#                        [--data-dir RUTA] [--no-firewall]
# Es idempotente: volver a ejecutarlo actualiza la aplicación conservando los datos.
set -Eeuo pipefail
umask 022

APP_NAME="mantenimiento-coches"
SERVICE_USER="mantenimiento"
APP_DIR="/opt/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}.env"
UNIT_DIR="/etc/systemd/system"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app"

PORT="" PASSWORD="" HOST="" DATA_DIR="" NO_PASSWORD=0 NO_FIREWALL=0
UPGRADE=0 PREVIOUS_DIR=""

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

rollback() {
  if [[ -n "$PREVIOUS_DIR" && -d "$PREVIOUS_DIR" ]]; then
    warn "Restaurando la versión anterior de la aplicación..."
    systemctl stop "${APP_NAME}.service" 2>/dev/null || true
    rm -rf "$APP_DIR"
    mv "$PREVIOUS_DIR" "$APP_DIR"
    systemctl start "${APP_NAME}.service" 2>/dev/null || true
  fi
}
on_error() {
  local code=$? line=$1
  trap - ERR
  printf '\033[1;31mLa instalación falló (línea %s, código %s).\033[0m\n' "$line" "$code" >&2
  rollback
  exit "$code"
}
trap 'on_error $LINENO' ERR

usage() { sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        [[ $# -ge 2 ]] || die "--port necesita un valor"; PORT="$2"; shift 2 ;;
    --password)    [[ $# -ge 2 ]] || die "--password necesita un valor"; PASSWORD="$2"; shift 2 ;;
    --no-password) NO_PASSWORD=1; shift ;;
    --host)        [[ $# -ge 2 ]] || die "--host necesita un valor"; HOST="$2"; shift 2 ;;
    --data-dir)    [[ $# -ge 2 ]] || die "--data-dir necesita un valor"; DATA_DIR="$2"; shift 2 ;;
    --no-firewall) NO_FIREWALL=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "Opción desconocida: $1" ;;
  esac
done
[[ -z "$PASSWORD" || "$NO_PASSWORD" -eq 0 ]] || die "--password y --no-password son incompatibles."

# ------------------------------------------------------------------ comprobaciones previas
[[ "$(id -u)" -eq 0 ]] || die "Ejecútalo como root: sudo ./install.sh"
[[ -f "$SRC_DIR/server.py" && -d "$SRC_DIR/static" ]] || die "No encuentro los archivos de la aplicación en $SRC_DIR"
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] \
  || die "Se necesita systemd en funcionamiento (¿contenedor o WSL sin systemd?)."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
    warn "Este sistema no parece Ubuntu/Debian (${PRETTY_NAME:-desconocido}). Se continúa bajo tu responsabilidad."
  fi
fi

# Instalación previa: se conservan sus valores salvo que se indiquen opciones.
if [[ -f "$ENV_FILE" ]]; then
  UPGRADE=1
  get_old() { sed -n "s/^$1=\"\{0,1\}\(.*[^\"]\)\"\{0,1\}\$/\1/p" "$ENV_FILE" | head -n1; }
  [[ -n "$PORT" ]]     || PORT="$(get_old MC_PORT)"
  [[ -n "$HOST" ]]     || HOST="$(get_old MC_HOST)"
  [[ -n "$DATA_DIR" ]] || DATA_DIR="$(get_old MC_DATA_DIR)"
  if [[ -z "$PASSWORD" && "$NO_PASSWORD" -eq 0 ]]; then PASSWORD="$(get_old MC_PASSWORD)"; fi
fi
PORT="${PORT:-8080}"; HOST="${HOST:-0.0.0.0}"; DATA_DIR="${DATA_DIR:-/var/lib/${APP_NAME}}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die "Puerto no válido: $PORT"
PORT=$((10#$PORT))
[[ "$HOST" =~ ^[0-9A-Fa-f:.]+$ ]] || die "Dirección de escucha no válida: $HOST"
[[ "$DATA_DIR" =~ ^/[A-Za-z0-9_./-]*$ ]] || die "Ruta de datos no válida (absoluta, sin espacios ni caracteres especiales): $DATA_DIR"
case "$DATA_DIR" in
  /|/etc|/etc/*|/usr|/usr/*|/bin|/sbin|/lib*|/boot|/boot/*|/dev|/dev/*|/proc/*|/sys/*|"$APP_DIR"|"$APP_DIR"/*)
    die "Ruta de datos no permitida: $DATA_DIR" ;;
esac
if [[ -n "$PASSWORD" ]]; then
  [[ "$PASSWORD" =~ ^[[:print:]]+$ && "$PASSWORD" != *\"* && "$PASSWORD" != *\'* && "$PASSWORD" != *\\* && "$PASSWORD" != *'%'* ]] \
    || die "La contraseña solo puede tener caracteres imprimibles, sin comillas, barras invertidas ni '%'."
  (( ${#PASSWORD} >= 6 )) || die "La contraseña debe tener al menos 6 caracteres."
fi

# ------------------------------------------------------------------ dependencias
need=()
command -v python3 >/dev/null || need+=(python3)
command -v curl >/dev/null || need+=(curl)
if (( ${#need[@]} )); then
  info "Instalando dependencias: ${need[*]}..."
  command -v apt-get >/dev/null || die "No hay apt-get; instala manualmente: ${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update falló; se intenta instalar igualmente."
  apt-get install -y -qq "${need[@]}" || die "No se pudieron instalar: ${need[*]} (¿hay conexión a Internet?)"
fi
python3 -c 'import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "Se necesita Python 3.8 o superior con sqlite3."

# Puerto libre (salvo que lo esté usando nuestro propio servicio, que se va a reiniciar)
if ! systemctl is-active --quiet "${APP_NAME}.service" 2>/dev/null; then
  python3 - "$PORT" <<'PY' 2>/dev/null || die "El puerto $PORT ya está en uso. Elige otro con --port."
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.close()
PY
fi

avail_kb=$(df -Pk /opt 2>/dev/null | awk 'NR==2{print $4}')
[[ -z "${avail_kb:-}" || "$avail_kb" -gt 102400 ]] || die "Poco espacio libre en /opt (menos de 100 MB)."

# ------------------------------------------------------------------ usuario y directorios
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  info "Creando el usuario de sistema '$SERVICE_USER'..."
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$DATA_DIR"

# Copia de seguridad previa a actualizar
if [[ -f "$DATA_DIR/coches.db" && -f "$APP_DIR/backup.py" ]]; then
  info "Haciendo copia de seguridad de los datos existentes..."
  systemctl stop "${APP_NAME}.service" 2>/dev/null || true
  runuser -u "$SERVICE_USER" -- python3 "$APP_DIR/backup.py" "$DATA_DIR" 14 \
    || die "No se pudo hacer la copia de seguridad previa; se cancela para no arriesgar tus datos."
fi

# ------------------------------------------------------------------ aplicación
info "Instalando la aplicación en $APP_DIR..."
systemctl stop "${APP_NAME}.service" 2>/dev/null || true
if [[ -d "$APP_DIR" ]]; then
  PREVIOUS_DIR="${APP_DIR}.previous"
  rm -rf "$PREVIOUS_DIR"
  mv "$APP_DIR" "$PREVIOUS_DIR"
fi
install -d -m 755 "$APP_DIR"
install -m 644 "$SRC_DIR/server.py" "$SRC_DIR/backup.py" "$APP_DIR/"
cp -r "$SRC_DIR/static" "$APP_DIR/static"
find "$APP_DIR" -type d -exec chmod 755 {} +
find "$APP_DIR" -type f -exec chmod 644 {} +
chown -R root:root "$APP_DIR"
python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" "$APP_DIR/server.py" "$APP_DIR/backup.py"

# ------------------------------------------------------------------ configuración
GENERATED=0
if [[ -z "$PASSWORD" && "$NO_PASSWORD" -eq 0 ]]; then
  PASSWORD="$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(16)))')"
  GENERATED=1
fi
{
  echo "# Configuración de ${APP_NAME}. Tras editar: systemctl restart ${APP_NAME}"
  echo "MC_HOST=\"${HOST}\""
  echo "MC_PORT=\"${PORT}\""
  echo "MC_DATA_DIR=\"${DATA_DIR}\""
  echo "MC_PASSWORD=\"${PASSWORD}\""
} > "${ENV_FILE}.tmp"
chown root:"$SERVICE_USER" "${ENV_FILE}.tmp"
chmod 640 "${ENV_FILE}.tmp"
mv "${ENV_FILE}.tmp" "$ENV_FILE"

cat > "${UNIT_DIR}/${APP_NAME}.service" <<UNIT
[Unit]
Description=Mantenimiento coches
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env python3 ${APP_DIR}/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=${DATA_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

cat > "${UNIT_DIR}/${APP_NAME}-backup.service" <<UNIT
[Unit]
Description=Copia de seguridad de Mantenimiento coches

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=/usr/bin/env python3 ${APP_DIR}/backup.py ${DATA_DIR} 14
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${DATA_DIR}
UNIT

cat > "${UNIT_DIR}/${APP_NAME}-backup.timer" <<UNIT
[Unit]
Description=Copia de seguridad diaria de Mantenimiento coches

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ------------------------------------------------------------------ arranque
info "Arrancando el servicio..."
systemctl daemon-reload
systemctl enable "${APP_NAME}.service" "${APP_NAME}-backup.timer" >/dev/null 2>&1
systemctl restart "${APP_NAME}.service"
systemctl start "${APP_NAME}-backup.timer"

ok=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then ok=1; break; fi
  systemctl is-active --quiet "${APP_NAME}.service" || break
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  journalctl -u "${APP_NAME}.service" -n 25 --no-pager >&2 || true
  die "El servicio no responde en el puerto ${PORT}."
fi

if [[ "$NO_FIREWALL" -eq 0 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  info "ufw está activo: abriendo el puerto ${PORT}/tcp..."
  ufw allow "${PORT}/tcp" >/dev/null || warn "No se pudo abrir el puerto en ufw; hazlo manualmente."
fi

# Todo correcto: ya no hace falta la versión anterior ni el rollback.
trap - ERR
[[ -n "$PREVIOUS_DIR" ]] && rm -rf "$PREVIOUS_DIR"

# ------------------------------------------------------------------ resumen
echo
info "¡Instalación completada!"
echo "  Abre en el navegador:"
for ip in $(hostname -I 2>/dev/null); do echo "    http://${ip}:${PORT}/"; done
echo "    http://localhost:${PORT}/ (desde esta máquina)"
if [[ -n "$PASSWORD" ]]; then
  echo "  Usuario: cualquiera (p. ej. admin)    Contraseña: ${PASSWORD}"
  [[ "$GENERATED" -eq 1 ]] && echo "  (contraseña generada; guárdala. Se puede cambiar en ${ENV_FILE})"
else
  warn "Sin contraseña: cualquiera en tu red podrá ver y modificar los datos."
fi
echo "  Datos y copias de seguridad: ${DATA_DIR} (copia diaria automática, 14 conservadas)"
echo "  Estado: systemctl status ${APP_NAME}    Registros: journalctl -u ${APP_NAME} -f"
echo "  Para HTTPS, pon un proxy inverso (nginx/Caddy) delante: esta app sirve HTTP sin cifrar."
