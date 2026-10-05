# Mantenimiento coches

Aplicación web para guardar los datos de tus coches y llevar su mantenimiento: miniatura de cada vehículo,
ficha técnica completa (mecánica, compra, ITV, seguro, impuesto), historial de mantenimientos y mantenimientos
futuros con avisos de vencimiento (por fecha o por kilómetros).

- **Alojada en nginx**: nginx sirve la interfaz (`app/static`) y ejecuta la API (`app/api.cgi`, Python estándar + SQLite) a través de fcgiwrap.
  No hay servicio propio, ni instalador, ni nada que reiniciar.
- **Datos en el servidor** (`/var/lib/mantenimiento-coches/coches.db`), fuera del repositorio, visibles desde cualquier dispositivo.
- Interfaz moderna con modo claro/oscuro, adaptada a móvil.

## Actualizar (un solo comando)

```bash
git -C /opt/apps/mantenimiento-coches pull
```

Como el código se lee del repositorio en cada petición, el cambio está en producción al instante. Los cambios de esquema
de la base de datos se aplican solos (`MIGRATIONS` en `app/server.py`). Si cambia el archivo de nginx
(`nginx/mantenimiento-coches.conf`) hay que recargar nginx: `sudo nginx -t && sudo systemctl reload nginx`.

¿Quieres que ni siquiera haga falta ese comando? Una línea en cron actualiza el servidor cada 5 minutos:

```bash
(crontab -l 2>/dev/null; echo '*/5 * * * * git -C /opt/apps/mantenimiento-coches pull -q --ff-only') | crontab -
```

## Configuración inicial en la VM Ubuntu (una sola vez)

```bash
# 1. Paquetes
sudo apt-get update && sudo apt-get install -y nginx fcgiwrap git openssl
sudo systemctl enable --now fcgiwrap.socket

# 2. Código (en su propia carpeta; el repositorio es tuyo, así que "git pull" no necesita sudo)
sudo mkdir -p /opt/apps && sudo chown "$USER": /opt/apps
git clone --branch claude/awesome-goldberg-kchtxi https://github.com/diego233l/prueba.git /opt/apps/mantenimiento-coches

# 3. Carpeta de datos (la escribe nginx/fcgiwrap, que corre como www-data)
sudo install -d -o www-data -g www-data -m 750 /var/lib/mantenimiento-coches

# 4. Contraseña de acceso (usuario: admin)
printf 'admin:%s\n' "$(openssl passwd -apr1 'CAMBIA_ESTA_CLAVE')" | sudo tee /etc/nginx/mantenimiento-coches.htpasswd >/dev/null
sudo chgrp www-data /etc/nginx/mantenimiento-coches.htpasswd && sudo chmod 640 /etc/nginx/mantenimiento-coches.htpasswd

# 5. Sitio nginx (puerto 8080, no toca tus otros sitios) y copia de seguridad diaria
sudo ln -sf /opt/apps/mantenimiento-coches/nginx/mantenimiento-coches.conf /etc/nginx/sites-enabled/mantenimiento-coches
echo '0 3 * * * www-data python3 /opt/apps/mantenimiento-coches/app/backup.py /var/lib/mantenimiento-coches 14' | sudo tee /etc/cron.d/mantenimiento-coches >/dev/null
sudo nginx -t && sudo systemctl reload nginx

# 6. Solo si usas el cortafuegos ufw
sudo ufw allow 8080/tcp
```

Abre `http://IP-DE-LA-VM:8080/` (usuario `admin`). Para cambiar el puerto o el dominio edita `listen` / `server_name` en
`nginx/mantenimiento-coches.conf` y recarga nginx. Para HTTPS pon certificados en ese mismo bloque (p. ej. con certbot).

## Si algo no funciona

| Síntoma | Qué mirar |
| --- | --- |
| `502 Bad Gateway` en `/api/...` | `systemctl status fcgiwrap.socket`; comprueba que existe `/run/fcgiwrap.socket` (si en tu Ubuntu está en otra ruta, cámbiala en `fastcgi_pass`) |
| Error "No se pudo abrir la base de datos" | La carpeta `/var/lib/mantenimiento-coches` debe ser de `www-data` (paso 3) |
| `403`/`404` en la web | Permisos de lectura de `/opt/apps` para www-data (`chmod o+rX`) y que el enlace de `sites-enabled` apunta bien |
| Error tras un `git pull` | La API responde con un mensaje claro; mira `sudo tail /var/log/nginx/error.log` y haz `git revert`/`git checkout` del commit problemático |
| `nginx -t` falla por `listen 8080` | Puerto ocupado por otro sitio: cambia el puerto en el archivo de nginx |

Datos y copias: `/var/lib/mantenimiento-coches` (`backups/` guarda las 14 últimas). Desde la web también puedes **Exportar copia** (JSON).

## Desarrollo local

```bash
MC_PORT=8080 python3 app/server.py     # servidor propio de desarrollo, datos en app/data/
```

Variables: `MC_HOST`, `MC_PORT`, `MC_DATA_DIR`, `MC_PASSWORD` (solo para este modo de desarrollo; en producción lo hace nginx).
