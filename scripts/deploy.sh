#!/usr/bin/env bash
# Despliega en el servidor el commit actual del repositorio (lo ejecuta systemd como root).
#   deploy.sh          despliega el HEAD actual si es nuevo (lo lanza systemd al detectar un git pull)
#   deploy.sh --pull   antes hace git fetch + fast-forward de la rama seguida (lo lanza el temporizador)
#   deploy.sh --force  vuelve a desplegar aunque el commit ya esté desplegado
# Cada despliegue es una "release" inmutable en .deploy/releases/<commit>; .deploy/current apunta a la activa.
# Si la nueva versión no arranca, se vuelve automáticamente a la anterior y se marca el commit como malo.
set -Eeuo pipefail

APP_NAME="mantenimiento-coches"
ENV_FILE="${MC_ENV_FILE:-/etc/${APP_NAME}.env}"
SYSTEMCTL="${MC_SYSTEMCTL:-systemctl}"
RUN_AS="${MC_RUN_AS-runuser -u mantenimiento --}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SELF")"
DEPLOY="$REPO/.deploy"
PULL=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --pull) PULL=1 ;;
    --force) FORCE=1 ;;
    *) echo "Opción desconocida: $a" >&2; exit 2 ;;
  esac
done

log() { echo "[deploy] $*"; }
get() { sed -n "s/^$1=\"\{0,1\}\(.*[^\"]\)\"\{0,1\}\$/\1/p" "$ENV_FILE" | head -n1; }
g() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

[[ -f "$ENV_FILE" ]] || { echo "No existe $ENV_FILE; ejecuta primero install.sh" >&2; exit 1; }
PORT="$(get MC_PORT)"; DATA_DIR="$(get MC_DATA_DIR)"; BRANCH="$(get MC_BRANCH)"
[[ -n "$PORT" && -n "$DATA_DIR" ]] || { echo "Configuración incompleta en $ENV_FILE" >&2; exit 1; }

mkdir -p "$DEPLOY/releases"
exec 9>"$DEPLOY/lock"
flock -w 600 9 || { echo "Otro despliegue lleva demasiado tiempo en curso" >&2; exit 1; }

# --- 1. Traer cambios del remoto (solo avance rápido: nunca pisa trabajo local)
if [[ "$PULL" -eq 1 ]]; then
  if [[ -n "$BRANCH" && "$(g rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
    log "El repositorio no está en la rama '$BRANCH'; no se actualiza automáticamente."
  elif ! timeout 90 git -c safe.directory="$REPO" -C "$REPO" fetch --quiet origin ${BRANCH:+"$BRANCH"}; then
    log "No se pudo contactar con el remoto (¿sin red o sin credenciales?). Se mantiene la versión actual."
  elif ! g merge --ff-only --quiet FETCH_HEAD; then
    log "No se pudo avanzar por fast-forward (cambios locales o historia divergente). Se mantiene la versión actual."
  fi
fi

COMMIT="$(g rev-parse HEAD)"
SHORT="${COMMIT:0:10}"
CURRENT=""; [[ -L "$DEPLOY/current" ]] && CURRENT="$(basename "$(readlink "$DEPLOY/current")")"
BAD="$(cat "$DEPLOY/bad" 2>/dev/null || true)"

healthy() {
  local _
  for _ in $(seq 1 20); do
    if python3 - "$PORT" <<'PY' 2>/dev/null
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/api/health" % sys.argv[1], timeout=3).read()
PY
    then return 0; fi
    "$SYSTEMCTL" is-active --quiet "${APP_NAME}.service" || return 1
    sleep 1
  done
  return 1
}

if [[ "$COMMIT" == "$CURRENT" && "$FORCE" -eq 0 ]] && "$SYSTEMCTL" is-active --quiet "${APP_NAME}.service"; then
  exit 0
fi
if [[ "$COMMIT" == "$BAD" && "$FORCE" -eq 0 ]]; then
  log "El commit $SHORT ya falló al desplegarse; se espera a que haya un commit nuevo."
  exit 1
fi

# --- 2. Preparar la release a partir del contenido COMMITEADO (ignora cambios sin commit)
REL="$DEPLOY/releases/$COMMIT"
log "Preparando release $SHORT..."
rm -rf "$REL.tmp"
mkdir -p "$REL.tmp"
g archive "$COMMIT" app | tar -x -C "$REL.tmp" --strip-components=1
if [[ ! -f "$REL.tmp/server.py" || ! -d "$REL.tmp/static" ]]; then
  log "El commit no contiene la aplicación esperada."
  echo "$COMMIT" > "$DEPLOY/bad"; rm -rf "$REL.tmp"; exit 1
fi
if ! python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" "$REL.tmp/server.py" "$REL.tmp/backup.py"; then
  log "El código del commit $SHORT tiene errores de sintaxis; no se despliega."
  echo "$COMMIT" > "$DEPLOY/bad"; rm -rf "$REL.tmp"; exit 1
fi
chown -R root:root "$REL.tmp"
find "$REL.tmp" -type d -exec chmod 755 {} +
find "$REL.tmp" -type f -exec chmod 644 {} +
rm -rf "$REL"
mv "$REL.tmp" "$REL"

# --- 3. Copia de seguridad de los datos antes de tocar nada
if [[ -f "$DATA_DIR/coches.db" ]]; then
  $RUN_AS python3 "$REL/backup.py" "$DATA_DIR" 14 || { log "Falló la copia de seguridad previa; se cancela el despliegue."; exit 1; }
fi

# --- 4. Activar la release y reiniciar; si no arranca, volver atrás
PREV="$(readlink "$DEPLOY/current" 2>/dev/null || true)"
ln -sfn "$REL" "$DEPLOY/current.new"
mv -T "$DEPLOY/current.new" "$DEPLOY/current"
log "Reiniciando el servicio..."
"$SYSTEMCTL" restart "${APP_NAME}.service" || true
if healthy; then
  echo "$COMMIT" > "$DEPLOY/deployed"
  rm -f "$DEPLOY/bad"
  log "Release $SHORT activa."
else
  log "La release $SHORT no arranca. Últimos registros:"
  journalctl -u "${APP_NAME}.service" -n 15 --no-pager 2>/dev/null || true
  echo "$COMMIT" > "$DEPLOY/bad"
  if [[ -n "$PREV" && -d "$PREV" ]]; then
    log "Volviendo a la versión anterior ($(basename "$PREV" | cut -c1-10))."
    ln -sfn "$PREV" "$DEPLOY/current.new"
    mv -T "$DEPLOY/current.new" "$DEPLOY/current"
    "$SYSTEMCTL" restart "${APP_NAME}.service" || true
    healthy || log "ATENCIÓN: tampoco responde la versión anterior; revisa: journalctl -u ${APP_NAME} -n 50"
  fi
  rm -rf "$REL"
  exit 1
fi

# --- 5. Limpieza: conservar las 3 releases más recientes
ls -1dt "$DEPLOY"/releases/*/ 2>/dev/null | tail -n +4 | while read -r old; do
  [[ "$(basename "$old")" != "$COMMIT" ]] && rm -rf "$old"
done || true
exit 0
