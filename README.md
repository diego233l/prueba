# Mantenimiento coches

Aplicación web para guardar los datos de tus coches y llevar su mantenimiento: miniatura de cada vehículo,
ficha técnica completa (mecánica, compra, ITV, seguro, impuesto), historial de mantenimientos y mantenimientos
futuros con avisos de vencimiento (por fecha o por kilómetros).

- **Sin dependencias**: solo Python 3.8+ (biblioteca estándar) y SQLite. Interfaz moderna con modo claro/oscuro, adaptada a móvil.
- **Datos** en un único archivo SQLite (`coches.db`), con copia de seguridad diaria automática y exportación JSON desde la interfaz.

## Instalación en Ubuntu (20.04 o superior)

```bash
git clone <url-del-repositorio> && cd <carpeta>
sudo ./install.sh                       # puerto 8080, contraseña generada automáticamente
sudo ./install.sh --port 80 --password MiClave123
sudo ./install.sh --no-password         # sin autenticación (solo redes de confianza)
```

Opciones: `--port N`, `--password CLAVE`, `--no-password`, `--host IP`, `--data-dir RUTA`, `--no-firewall`.

El instalador comprueba root, systemd, puerto libre, espacio y versión de Python; instala lo que falte, crea un
usuario de sistema sin privilegios, un servicio systemd endurecido y un temporizador de copias de seguridad; abre el
puerto en `ufw` si está activo, verifica que la aplicación responde y, si algo falla al actualizar, restaura la versión anterior.
Volver a ejecutarlo **actualiza** conservando los datos (y hace una copia antes).

| Qué | Dónde |
| --- | --- |
| Aplicación | `/opt/mantenimiento-coches` |
| Configuración (puerto, contraseña) | `/etc/mantenimiento-coches.env` |
| Datos y copias (`backups/`) | `/var/lib/mantenimiento-coches` |

Gestión: `systemctl status|restart mantenimiento-coches`, `journalctl -u mantenimiento-coches -f`.
Desinstalar: `sudo ./uninstall.sh` (conserva los datos) o `sudo ./uninstall.sh --purge` (los borra).

> La aplicación sirve HTTP sin cifrar. Para acceso desde Internet ponla detrás de un proxy inverso con HTTPS (nginx, Caddy).

## Desarrollo local

```bash
MC_PORT=8080 python3 app/server.py     # datos en app/data/
```

Variables: `MC_HOST`, `MC_PORT`, `MC_DATA_DIR`, `MC_PASSWORD` (si se define, se pide por HTTP Basic; el usuario es indiferente).
