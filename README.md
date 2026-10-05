# Mantenimiento coches

Aplicación web para guardar los datos de tus coches y llevar su mantenimiento: miniatura de cada vehículo,
ficha técnica completa (mecánica, compra, ITV, seguro, impuesto), historial de mantenimientos y mantenimientos
futuros con avisos de vencimiento (por fecha o por kilómetros).

- **Sin dependencias**: solo Python 3.8+ (biblioteca estándar) y SQLite. Interfaz moderna con modo claro/oscuro, adaptada a móvil.
- **Datos** en un único archivo SQLite fuera del repositorio, con copia diaria automática y exportación JSON desde la interfaz.

## Instalación en la VM Ubuntu (se hace una sola vez)

```bash
sudo apt-get update && sudo apt-get install -y git
sudo mkdir -p /opt/apps
sudo git clone --branch <rama> <url-del-repositorio> /opt/apps/mantenimiento-coches
cd /opt/apps/mantenimiento-coches
sudo ./install.sh                       # puerto 8080, contraseña generada
# variantes: sudo ./install.sh --port 80 --password MiClave123
```

Todo lo de esta aplicación vive en su propia carpeta (`/opt/apps/mantenimiento-coches`) y en sus propias
unidades systemd (`mantenimiento-coches*`), así que otras aplicaciones en la misma VM no se ven afectadas.
Opciones de `install.sh`: `--port N`, `--password CLAVE`, `--no-password`, `--host IP`, `--data-dir RUTA`,
`--branch RAMA`, `--interval MIN`, `--no-auto-pull`, `--no-firewall`.

## Cómo se actualiza (sin volver a ejecutar nada)

1. Se suben cambios a la rama que sigue el servidor (la que estaba activa al instalar; se guarda en `MC_BRANCH`).
2. **Automático:** cada 5 minutos (configurable) el servidor hace `git fetch` + fast-forward de esa rama.
3. **Inmediato:** si haces `sudo git pull` en la carpeta, systemd detecta el cambio y despliega al instante.
4. Cada despliegue: toma el contenido **commiteado**, comprueba la sintaxis, hace una copia de seguridad de los datos,
   crea una *release* en `.deploy/releases/<commit>`, reinicia el servicio y comprueba que responde.
   Si no arranca, **vuelve solo a la versión anterior** y no reintenta ese commit hasta que haya otro nuevo.
5. Los cambios de esquema de base de datos se aplican solos al arrancar (`MIGRATIONS` en `app/server.py`).

Nunca se pisa trabajo local: solo se avanza por *fast-forward*. Los cambios sin commit en la carpeta del servidor no se despliegan.

Historial de despliegues: `journalctl -u mantenimiento-coches-deploy -u mantenimiento-coches-pull`.
Forzar un despliegue ahora: `sudo systemctl start mantenimiento-coches-pull` (o `sudo ./scripts/deploy.sh --pull`).

### Repositorio privado
El `git fetch` automático lo ejecuta root. Para que pueda autenticarse, guarda unas credenciales de solo lectura una vez:

```bash
sudo git config --global credential.helper store
sudo git -C /opt/apps/mantenimiento-coches fetch origin     # pedirá usuario y token (permiso de solo lectura) y lo recordará
```
(o configura una *deploy key* SSH y cambia el remoto a `git@github.com:...`).

### Cambiar de rama (p. ej. cuando se fusione a `main`)
```bash
cd /opt/apps/mantenimiento-coches
sudo git fetch origin && sudo git checkout main
sudo ./install.sh --branch main         # conserva puerto, contraseña y datos
```

## Dónde está cada cosa

| Qué | Dónde |
| --- | --- |
| Código y releases | `/opt/apps/mantenimiento-coches` (`.deploy/` = releases generadas, ignorada por git) |
| Configuración (puerto, contraseña, rama) | `/etc/mantenimiento-coches.env` (tras editarla: `sudo systemctl restart mantenimiento-coches`) |
| Datos y copias (`backups/`) | `/var/lib/mantenimiento-coches` |

Gestión: `systemctl status mantenimiento-coches`, `journalctl -u mantenimiento-coches -f`.
Desinstalar: `sudo ./uninstall.sh` (conserva los datos) o `sudo ./uninstall.sh --purge` (los borra). No borra la carpeta del repositorio.

> La aplicación sirve HTTP sin cifrar. Para acceso desde Internet ponla detrás de un proxy inverso con HTTPS (nginx, Caddy).

## Desarrollo local

```bash
MC_PORT=8080 python3 app/server.py     # datos en app/data/
```

Variables: `MC_HOST`, `MC_PORT`, `MC_DATA_DIR`, `MC_PASSWORD` (si se define, se pide por HTTP Basic; el usuario es indiferente).
