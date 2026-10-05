#!/usr/bin/env bash
# Instalación (una sola vez) de "Mantenimiento coches" en Ubuntu con systemd.
# Se ejecuta desde la copia del repositorio; a partir de ahí, cada actualización del repositorio
# (git pull manual o automático) se despliega sola.
# Uso: sudo ./install.sh [--port N] [--password CLAVE | --no-password] [--host IP] [--data-dir RUTA]
#                        [--branch RAMA] [--interval MIN | --no-auto-pull] [--no-firewall]
set -Eeuo pipefail
umask 022

APP_NAME="mantenimiento-coches"
SERVICE_USER="mantenimiento"
ENV_FILE="/etc/${APP_NAME}.env"
UNIT_DIR="/etc/systemd/system"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_LINK="${REPO}/.deploy/current"

PORT="" PASSWORD="" HOST="" DATA_DIR="" BRANCH="" INTERVAL="" NO_PASSWORD=0 NO_FIREWALL=0 NO_AUTOPULL=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[1;31mLa instalación falló (línea %s). Corrige el problema y vuelve a ejecutar sudo ./install.sh (es repetible).\033[0m\n" "$LINENO" >&2' ERR

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)         [[ $# -ge 2 ]] || die "--port necesita un valor"; PORT="$2"; shift 2 ;;
    --password)     [[ $# -ge 2 ]] || die "--password necesita un valor"; PASSWORD="$2"; shift 2 ;;
    --no-password)  NO_PASSWORD=1; shift ;;
    --host)         [[ $# -ge 2 ]] || die "--host necesita un valor"; HOST="$2"; shift 2 ;;
    --data-dir)     [[ $# -ge 2 ]] || die "--data-dir necesita un valor"; DATA_DIR="$2"; shift 2 ;;
    --branch)       [[ $# -ge 2 ]] || die "--branch necesita un valor"; BRANCH="$2"; shift 2 ;;
    --interval)     [[ $# -ge 2 ]] || die "--interval necesita un valor"; INTERVAL="$2"; shift 2 ;;
    --no-auto-pull) NO_AUTOPULL=1; shift ;;
    --no-firewall)  NO_FIREWALL=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) usage; die "Opción desconocida: $1" ;;
  esac
done
[[ -z "$PASSWORD" || "$NO_PASSWORD" -eq 0 ]] || die "--password y --no-password son incompatibles."

# ------------------------------------------------------------------ comprobaciones previas
[[ "$(id -u)" -eq 0 ]] || die "Ejecútalo como root: sudo ./install.sh"
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] \
  || die "Se necesita systemd en funcionamiento (¿contenedor o WSL sin systemd?)."
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
    warn "Este sistema no parece Ubuntu/Debian (${PRETTY_NAME:-desconocido}). Se continúa bajo tu responsabilidad."
  fi
fi

[[ -f "$REPO/app/server.py" && -f "$REPO/scripts/deploy.sh" ]] || die "Ejecuta install.sh desde la raíz del repositorio clonado."
[[ -d "$REPO/.git" ]] || die "$REPO no es un clon de git (se necesita para actualizar). Usa: git clone <url> <carpeta>"
case "$REPO" in
  /home/*|/root/*|/tmp/*|/var/tmp/*|/run/*)
    die "El repositorio está en $REPO, donde el servicio (sin privilegios) no puede leerlo. Clónalo en otra ruta, p. ej.:
       sudo git clone <url> /opt/apps/${APP_NAME} && cd /opt/apps/${APP_NAME}" ;;
esac
case "$REPO" in *[!A-Za-z0-9_./-]*) die "La ruta del repositorio no puede contener espacios ni caracteres especiales: $REPO" ;; esac

# El script de despliegue lo ejecuta root desde el repositorio: nadie más debe poder modificarlo.
bad_owner="$(find "$REPO" -path "$REPO/.deploy" -prune -o \( ! -user root -o -perm -0002 \) -print -quit)"
if [[ -n "$bad_owner" ]]; then
  die "Hay archivos del repositorio que no son de root o son escribibles por todos (p. ej. $bad_owner).
       El despliegue se ejecuta como root, así que arréglalo con:  sudo chown -R root:root $REPO && sudo chmod -R go-w $REPO
       (y usa 'sudo git pull' para actualizar a mano)."
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -c safe.directory="$REPO" -C "$REPO" rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" != "HEAD" ]] || die "El repositorio está en 'detached HEAD'; usa --branch RAMA o haz checkout de una rama."
fi
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Nombre de rama no válido: $BRANCH"

# Instalación previa: se conservan sus valores salvo que se indiquen opciones.
if [[ -f "$ENV_FILE" ]]; then
  get_old() { sed -n "s/^$1=\"\{0,1\}\(.*[^\"]\)\"\{0,1\}\$/\1/p" "$ENV_FILE" | head -n1; }
  [[ -n "$PORT" ]]     || PORT="$(get_old MC_PORT)"
  [[ -n "$HOST" ]]     || HOST="$(get_old MC_HOST)"
  [[ -n "$DATA_DIR" ]] || DATA_DIR="$(get_old MC_DATA_DIR)"
  [[ -n "$INTERVAL" ]] || INTERVAL="$(get_old MC_AUTOPULL_MIN)"
  if [[ -z "$PASSWORD" && "$NO_PASSWORD" -eq 0 ]]; then PASSWORD="$(get_old MC_PASSWORD)"; fi
fi
PORT="${PORT:-8080}"; HOST="${HOST:-0.0.0.0}"; DATA_DIR="${DATA_DIR:-/var/lib/${APP_NAME}}"; INTERVAL="${INTERVAL:-5}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die "Puerto no válido: $PORT"
PORT=$((10#$PORT))
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && (( 10#$INTERVAL >= 1 && 10#$INTERVAL <= 1440 )) || die "--interval debe estar entre 1 y 1440 minutos."
INTERVAL=$((10#$INTERVAL))
[[ "$HOST" =~ ^[0-9A-Fa-f:.]+$ ]] || die "Dirección de escucha no válida: $HOST"
[[ "$DATA_DIR" =~ ^/[A-Za-z0-9_./-]*$ ]] || die "Ruta de datos no válida (absoluta, sin espacios ni caracteres especiales): $DATA_DIR"
case "$DATA_DIR" in
  /|/etc|/etc/*|/usr|/usr/*|/bin|/sbin|/lib*|/boot|/boot/*|/dev|/dev/*|/proc/*|/sys/*|"$REPO"|"$REPO"/*)
    die "Ruta de datos no permitida: $DATA_DIR (los datos deben ir fuera del repositorio)" ;;
esac
if [[ -n "$PASSWORD" ]]; then
  [[ "$PASSWORD" =~ ^[[:print:]]+$ && "$PASSWORD" != *\"* && "$PASSWORD" != *\'* && "$PASSWORD" != *\\* && "$PASSWORD" != *'%'* ]] \
    || die "La contraseña solo puede tener caracteres imprimibles, sin comillas, barras invertidas ni '%'."
  (( ${#PASSWORD} >= 6 )) || die "La contraseña debe tener al menos 6 caracteres."
fi

# ------------------------------------------------------------------ dependencias
need=()
for c in python3 git curl; do command -v "$c" >/dev/null || need+=("$c"); done
command -v flock >/dev/null || die "Falta 'flock' (paquete util-linux, normalmente ya instalado)."
if (( ${#need[@]} )); then
  pk=("${need[@]}")
  info "Instalando dependencias: ${pk[*]}..."
  command -v apt-get >/dev/null || die "No hay apt-get; instala manualmente: ${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update falló; se intenta instalar igualmente."
  apt-get install -y -qq "${pk[@]}" || die "No se pudieron instalar: ${pk[*]} (¿hay conexión a Internet?)"
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
avail_kb=$(df -Pk "$REPO" 2>/dev/null | awk 'NR==2{print $4}')
[[ -z "${avail_kb:-}" || "$avail_kb" -gt 102400 ]] || die "Poco espacio libre (menos de 100 MB)."

# ------------------------------------------------------------------ usuario, datos y configuración
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  info "Creando el usuario de sistema '$SERVICE_USER'..."
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$DATA_DIR"

# El usuario del servicio debe poder entrar en todas las carpetas hasta el repositorio.
runuser -u "$SERVICE_USER" -- test -x "$REPO" \
  || die "El usuario '$SERVICE_USER' no puede acceder a $REPO (permisos de alguna carpeta superior). Usa una ruta como /opt/apps/${APP_NAME}."

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
  echo "# Rama del repositorio que se despliega y cada cuántos minutos se consulta el remoto"
  echo "MC_BRANCH=\"${BRANCH}\""
  echo "MC_AUTOPULL_MIN=\"${INTERVAL}\""
} > "${ENV_FILE}.tmp"
chown root:"$SERVICE_USER" "${ENV_FILE}.tmp"
chmod 640 "${ENV_FILE}.tmp"
mv "${ENV_FILE}.tmp" "$ENV_FILE"

# ------------------------------------------------------------------ unidades systemd
info "Configurando systemd..."
cat > "${UNIT_DIR}/${APP_NAME}.service" <<UNIT
[Unit]
Description=Mantenimiento coches
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/env python3 ${CURRENT_LINK}/server.py
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
ExecStart=/usr/bin/env python3 ${CURRENT_LINK}/backup.py ${DATA_DIR} 14
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

# Despliegue: se dispara cuando git actualiza el repositorio (FETCH_HEAD cambia en cada git pull/fetch)...
cat > "${UNIT_DIR}/${APP_NAME}-deploy.service" <<UNIT
[Unit]
Description=Desplegar Mantenimiento coches desde el repositorio

[Service]
Type=oneshot
ExecStart=${REPO}/scripts/deploy.sh
TimeoutStartSec=900
UNIT

cat > "${UNIT_DIR}/${APP_NAME}-deploy.path" <<UNIT
[Unit]
Description=Vigilar actualizaciones del repositorio de Mantenimiento coches

[Path]
PathChanged=${REPO}/.git/FETCH_HEAD
PathChanged=${REPO}/.git/ORIG_HEAD
Unit=${APP_NAME}-deploy.service

[Install]
WantedBy=multi-user.target
UNIT

# ...y un temporizador que hace git pull periódico (sin comandos manuales).
cat > "${UNIT_DIR}/${APP_NAME}-pull.service" <<UNIT
[Unit]
Description=Actualizar Mantenimiento coches desde el remoto
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${REPO}/scripts/deploy.sh --pull
TimeoutStartSec=900
UNIT

cat > "${UNIT_DIR}/${APP_NAME}-pull.timer" <<UNIT
[Unit]
Description=Buscar actualizaciones de Mantenimiento coches cada ${INTERVAL} min

[Timer]
OnBootSec=2min
OnUnitInactiveSec=${INTERVAL}min
RandomizedDelaySec=20

[Install]
WantedBy=timers.target
UNIT
touch "${REPO}/.git/FETCH_HEAD" "${REPO}/.git/ORIG_HEAD"

# ------------------------------------------------------------------ primer despliegue
systemctl daemon-reload
systemctl enable "${APP_NAME}.service" "${APP_NAME}-backup.timer" >/dev/null 2>&1
info "Desplegando la versión actual del repositorio..."
"$REPO/scripts/deploy.sh" --force || die "El primer despliegue falló (revisa el mensaje anterior)."
systemctl start "${APP_NAME}-backup.timer"

systemctl enable --now "${APP_NAME}-deploy.path" >/dev/null 2>&1
if [[ "$NO_AUTOPULL" -eq 1 ]]; then
  systemctl disable --now "${APP_NAME}-pull.timer" >/dev/null 2>&1 || true
else
  systemctl enable --now "${APP_NAME}-pull.timer" >/dev/null 2>&1
fi

if [[ "$NO_FIREWALL" -eq 0 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  info "ufw está activo: abriendo el puerto ${PORT}/tcp..."
  ufw allow "${PORT}/tcp" >/dev/null || warn "No se pudo abrir el puerto en ufw; hazlo manualmente."
fi
trap - ERR

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
echo
echo "  ACTUALIZACIONES: cuando se suban cambios a la rama '${BRANCH}', el servidor los aplicará solo"
if [[ "$NO_AUTOPULL" -eq 1 ]]; then
  echo "  en cuanto hagas 'sudo git pull' en ${REPO} (el pull automático está desactivado)."
else
  echo "  (consulta el remoto cada ${INTERVAL} min), o al momento si haces 'sudo git pull' en ${REPO}."
  echo "  Si el repositorio es privado, root necesita credenciales para git (ver README)."
fi
echo "  Datos y copias de seguridad: ${DATA_DIR} (copia diaria y otra antes de cada actualización)"
echo "  Estado: systemctl status ${APP_NAME}    Registros: journalctl -u ${APP_NAME} -f"
echo "          journalctl -u ${APP_NAME}-deploy -u ${APP_NAME}-pull   (historial de despliegues)"
echo "  Para HTTPS, pon un proxy inverso (nginx/Caddy) delante: esta app sirve HTTP sin cifrar."
