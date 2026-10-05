#!/usr/bin/python3
"""Punto de entrada CGI de la API: nginx -> fcgiwrap -> este script (un proceso por petición).

Al ejecutarse el código fresco en cada petición, un `git pull` actualiza la aplicación al instante
(sin servicios que reiniciar). Los cambios de esquema de la base de datos se aplican solos.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
os.environ.setdefault("MC_DATA_DIR", "/var/lib/mantenimiento-coches")


def emit(status, body, ctype="application/json; charset=utf-8", extra=None, head=False):
    lines = ["Status: %d" % status, "Content-Type: " + ctype, "Content-Length: %d" % len(body)]
    lines += ["%s: %s" % kv for kv in (extra or {}).items()]
    out = sys.stdout.buffer
    out.write(("\r\n".join(lines) + "\r\n\r\n").encode("utf-8"))
    if not head:
        out.write(body)
    out.flush()


def fail(status, message):
    import json
    emit(status, json.dumps({"error": message}, ensure_ascii=False).encode("utf-8"))


try:
    import server
except Exception as exc:  # código roto tras un pull: respuesta clara en vez de un 502 mudo
    sys.stderr.write("No se pudo cargar server.py: %r\n" % (exc,))
    fail(500, "La aplicación no se pudo cargar (revisa el último cambio subido): %s" % exc)
    sys.exit(0)


class Headers:
    """Acceso a las cabeceras HTTP tal y como las entrega CGI (variables de entorno)."""

    def get(self, name, default=None):
        key = name.upper().replace("-", "_")
        if key not in ("CONTENT_LENGTH", "CONTENT_TYPE"):
            key = "HTTP_" + key
        return os.environ.get(key, default)


class CgiRequest(server.JsonMixin):
    def __init__(self):
        self.command = os.environ.get("REQUEST_METHOD", "GET").upper()
        self.headers = Headers()

    def send_bytes(self, status, body, ctype, extra=None):
        merged = dict(server.SECURITY_HEADERS)
        merged.update(extra or {})
        emit(status, body, ctype, merged, head=self.command == "HEAD")

    def read_body(self, limit):
        try:
            length = int(os.environ.get("CONTENT_LENGTH") or 0)
        except ValueError:
            raise server.ApiError(400, "Content-Length no válido")
        if length > limit:
            raise server.ApiError(413, "Contenido demasiado grande (máximo %d KB)" % (limit // 1024))
        return sys.stdin.buffer.read(length) if length else b""


def main():
    path = os.environ.get("REQUEST_URI", "/").split("?", 1)[0]
    try:
        server.init_db()
    except Exception as exc:
        sys.stderr.write("Error abriendo la base de datos: %r\n" % (exc,))
        return fail(503, "No se pudo abrir la base de datos en %s (¿permisos de la carpeta de datos?): %s"
                    % (server.DATA_DIR, exc))
    server.handle_api(CgiRequest(), path)


main()
