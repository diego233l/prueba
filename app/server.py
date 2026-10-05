#!/usr/bin/env python3
"""Mantenimiento coches - servidor web (solo biblioteca estándar de Python 3.8+)."""
import base64
import hmac
import json
import logging
import mimetypes
import os
import re
import signal
import sqlite3
import sys
import threading
from datetime import date, datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")
HOST = os.environ.get("MC_HOST", "0.0.0.0")
PORT = int(os.environ.get("MC_PORT", "8080"))
DATA_DIR = os.environ.get("MC_DATA_DIR", os.path.join(BASE_DIR, "data"))
PASSWORD = os.environ.get("MC_PASSWORD", "")
DB_PATH = os.path.join(DATA_DIR, "coches.db")
MAX_JSON = 256 * 1024
MAX_PHOTO = 3 * 1024 * 1024
ALERT_DAYS = 30
ALERT_KM = 1000

log = logging.getLogger("mantenimiento")

# ---------------------------------------------------------------- esquema
SCHEMA = """
CREATE TABLE IF NOT EXISTS cars (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  alias TEXT, marca TEXT NOT NULL, modelo TEXT NOT NULL, version TEXT,
  anio INTEGER, matricula TEXT, vin TEXT, color TEXT, carroceria TEXT,
  combustible TEXT, transmision TEXT, cilindrada_cc INTEGER, potencia_cv INTEGER,
  puertas INTEGER, plazas INTEGER, km_actuales INTEGER DEFAULT 0,
  fecha_compra TEXT, precio_compra REAL, neumaticos TEXT,
  tipo_aceite TEXT, capacidad_aceite TEXT,
  itv_vencimiento TEXT, seguro_compania TEXT, seguro_poliza TEXT,
  seguro_vencimiento TEXT, impuesto_vencimiento TEXT, notas TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS car_photos (
  car_id INTEGER PRIMARY KEY REFERENCES cars(id) ON DELETE CASCADE,
  mime TEXT NOT NULL, data BLOB NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS maintenance (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  car_id INTEGER NOT NULL REFERENCES cars(id) ON DELETE CASCADE,
  tipo TEXT NOT NULL,
  estado TEXT NOT NULL CHECK (estado IN ('programado','realizado')),
  fecha TEXT, km INTEGER, coste REAL, taller TEXT, notas TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_maint_car ON maintenance(car_id);
"""

# nombre: (tipo, obligatorio, máx. longitud o (min, max))
CAR_FIELDS = {
    "alias": ("text", False, 60), "marca": ("text", True, 60),
    "modelo": ("text", True, 60), "version": ("text", False, 80),
    "anio": ("int", False, (1886, 2100)), "matricula": ("text", False, 20),
    "vin": ("text", False, 30), "color": ("text", False, 40),
    "carroceria": ("text", False, 40), "combustible": ("text", False, 40),
    "transmision": ("text", False, 40),
    "cilindrada_cc": ("int", False, (0, 20000)),
    "potencia_cv": ("int", False, (0, 5000)),
    "puertas": ("int", False, (0, 10)), "plazas": ("int", False, (0, 100)),
    "km_actuales": ("int", False, (0, 10_000_000)),
    "fecha_compra": ("date", False, None),
    "precio_compra": ("float", False, (0, 100_000_000)),
    "neumaticos": ("text", False, 60), "tipo_aceite": ("text", False, 60),
    "capacidad_aceite": ("text", False, 30),
    "itv_vencimiento": ("date", False, None),
    "seguro_compania": ("text", False, 80), "seguro_poliza": ("text", False, 60),
    "seguro_vencimiento": ("date", False, None),
    "impuesto_vencimiento": ("date", False, None),
    "notas": ("text", False, 4000),
}
MAINT_FIELDS = {
    "car_id": ("int", True, (1, 2**62)), "tipo": ("text", True, 80),
    "estado": ("enum", True, ("programado", "realizado")),
    "fecha": ("date", False, None), "km": ("int", False, (0, 10_000_000)),
    "coste": ("float", False, (0, 100_000_000)),
    "taller": ("text", False, 80), "notas": ("text", False, 4000),
}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def now():
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def clean(payload, spec, partial=False):
    """Valida y normaliza un diccionario según la especificación."""
    if not isinstance(payload, dict):
        raise ApiError(400, "Se esperaba un objeto JSON")
    out = {}
    for name, (kind, required, rule) in spec.items():
        if name not in payload:
            if required and not partial:
                raise ApiError(422, "Falta el campo obligatorio: %s" % name)
            continue
        value = payload[name]
        if isinstance(value, str):
            value = value.strip()
        if value is None or value == "":
            if required:
                raise ApiError(422, "El campo %s es obligatorio" % name)
            out[name] = None
            continue
        try:
            if kind == "text":
                if not isinstance(value, str):
                    value = str(value)
                if len(value) > rule:
                    raise ValueError("máximo %d caracteres" % rule)
            elif kind == "int":
                if isinstance(value, bool) or (isinstance(value, float) and value != int(value)):
                    raise ValueError("debe ser un número entero")
                try:
                    value = int(value)
                except ValueError:
                    raise ValueError("debe ser un número entero")
                if not rule[0] <= value <= rule[1]:
                    raise ValueError("fuera de rango (%s a %s)" % rule)
            elif kind == "float":
                if isinstance(value, bool):
                    raise ValueError("debe ser un número")
                try:
                    value = float(str(value).replace(",", "."))
                except ValueError:
                    raise ValueError("debe ser un número")
                if value != value or not rule[0] <= value <= rule[1]:
                    raise ValueError("fuera de rango")
            elif kind == "date":
                if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                    raise ValueError("fecha no válida (AAAA-MM-DD)")
                datetime.strptime(value, "%Y-%m-%d")
            elif kind == "enum":
                if value not in rule:
                    raise ValueError("valor no permitido")
        except (ValueError, OverflowError, TypeError) as exc:
            raise ApiError(422, "Campo %s: %s" % (name, exc))
        out[name] = value
    return out


# ---------------------------------------------------------------- base de datos
_local = threading.local()


def db():
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, timeout=15)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        _local.conn = conn
    return conn


# Migraciones de esquema: añadir al FINAL de la lista scripts SQL (nunca editar los anteriores).
# Se aplican automáticamente al arrancar tras una actualización; PRAGMA user_version guarda el progreso.
MIGRATIONS = [
]


def migrate(conn):
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    for i in range(version, len(MIGRATIONS)):
        conn.executescript("BEGIN;\n%s\nPRAGMA user_version = %d;\nCOMMIT;" % (MIGRATIONS[i], i + 1))
        log.info("Migración de base de datos %d aplicada", i + 1)


def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=15)
    try:
        try:
            conn.execute("PRAGMA journal_mode = WAL")
        except sqlite3.DatabaseError:
            pass
        conn.executescript(SCHEMA)
        migrate(conn)
        conn.commit()
    finally:
        conn.close()


def rows(cursor):
    return [dict(r) for r in cursor.fetchall()]


def car_or_404(car_id):
    row = db().execute("SELECT * FROM cars WHERE id=?", (car_id,)).fetchone()
    if not row:
        raise ApiError(404, "Coche no encontrado")
    return dict(row)


def list_cars():
    cars = rows(db().execute(
        "SELECT c.*, (p.car_id IS NOT NULL) AS has_photo, p.updated_at AS photo_v "
        "FROM cars c LEFT JOIN car_photos p ON p.car_id=c.id "
        "ORDER BY lower(coalesce(nullif(c.alias,''), c.marca || ' ' || c.modelo))"))
    stats = {r["car_id"]: r for r in db().execute(
        "SELECT car_id, COUNT(*) AS n, SUM(CASE WHEN estado='programado' THEN 1 ELSE 0 END) AS pend, "
        "SUM(CASE WHEN estado='realizado' THEN coalesce(coste,0) ELSE 0 END) AS gasto "
        "FROM maintenance GROUP BY car_id")}
    for c in cars:
        s = stats.get(c["id"])
        c["has_photo"] = bool(c["has_photo"])
        c["mant_total"] = s["n"] if s else 0
        c["mant_pendientes"] = s["pend"] if s else 0
        c["gasto_mantenimiento"] = round(s["gasto"], 2) if s else 0
    return cars


def compute_alerts():
    today = date.today()
    limit = today + timedelta(days=ALERT_DAYS)
    alerts = []
    cars = {c["id"]: c for c in rows(db().execute("SELECT * FROM cars"))}

    def name(c):
        return c["alias"] or ("%s %s" % (c["marca"], c["modelo"]))

    for c in cars.values():
        for field, label in (("itv_vencimiento", "ITV"), ("seguro_vencimiento", "Seguro"),
                             ("impuesto_vencimiento", "Impuesto de circulación")):
            d = c.get(field)
            if d:
                dd = datetime.strptime(d, "%Y-%m-%d").date()
                if dd <= limit:
                    alerts.append({"car_id": c["id"], "car": name(c), "titulo": label,
                                   "fecha": d, "vencido": dd < today, "origen": "coche"})
    for m in rows(db().execute("SELECT * FROM maintenance WHERE estado='programado'")):
        c = cars.get(m["car_id"])
        if not c:
            continue
        overdue = soon = False
        if m["fecha"]:
            dd = datetime.strptime(m["fecha"], "%Y-%m-%d").date()
            overdue = dd < today
            soon = dd <= limit
        if m["km"] is not None and c["km_actuales"] is not None:
            overdue = overdue or c["km_actuales"] >= m["km"]
            soon = soon or c["km_actuales"] >= m["km"] - ALERT_KM
        if soon or overdue:
            alerts.append({"car_id": c["id"], "car": name(c), "titulo": m["tipo"],
                           "fecha": m["fecha"], "km": m["km"], "vencido": overdue,
                           "origen": "mantenimiento", "mantenimiento_id": m["id"]})
    alerts.sort(key=lambda a: (not a["vencido"], a["fecha"] or "9999"))
    return alerts


def write_car(car_id, data):
    cols = list(data)
    ts = now()
    conn = db()
    with conn:
        if car_id is None:
            cur = conn.execute(
                "INSERT INTO cars (%s, created_at, updated_at) VALUES (%s, ?, ?)"
                % (",".join(cols), ",".join("?" * len(cols))),
                [data[c] for c in cols] + [ts, ts])
            return cur.lastrowid
        if cols:
            conn.execute("UPDATE cars SET %s, updated_at=? WHERE id=?"
                         % ",".join("%s=?" % c for c in cols),
                         [data[c] for c in cols] + [ts, car_id])
        return car_id


def sync_odometer(conn, car_id, km, estado):
    if estado == "realizado" and km is not None:
        conn.execute("UPDATE cars SET km_actuales=?, updated_at=? "
                     "WHERE id=? AND coalesce(km_actuales,0) < ?", (km, now(), car_id, km))


def sniff_image(data):
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def export_all():
    conn = db()
    photos = {r["car_id"]: r for r in conn.execute("SELECT * FROM car_photos")}
    cars = rows(conn.execute("SELECT * FROM cars ORDER BY id"))
    for c in cars:
        p = photos.get(c["id"])
        c["foto"] = ("data:%s;base64,%s" % (p["mime"], base64.b64encode(p["data"]).decode())) if p else None
        c["mantenimientos"] = rows(conn.execute(
            "SELECT * FROM maintenance WHERE car_id=? ORDER BY id", (c["id"],)))
    return {"app": "mantenimiento-coches", "exportado": now(), "coches": cars}


# ---------------------------------------------------------------- HTTP
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; "
                              "script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
}
ROUTES = []


def route(method, pattern):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), fn))
        return fn
    return deco


class Handler(BaseHTTPRequestHandler):
    server_version = "MantenimientoCoches"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)

    # -- utilidades de respuesta
    def send_bytes(self, status, body, ctype, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status, obj, extra=None):
        self.send_bytes(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                        "application/json; charset=utf-8", dict({"Cache-Control": "no-store"}, **(extra or {})))

    def read_body(self, limit):
        self._body_read = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ApiError(400, "Content-Length no válido")
        if length > limit:
            self.close_connection = True
            raise ApiError(413, "Contenido demasiado grande (máximo %d KB)" % (limit // 1024))
        return self.rfile.read(length) if length else b""

    def json_body(self):
        raw = self.read_body(MAX_JSON)
        try:
            return json.loads(raw.decode("utf-8") or "null")
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "JSON no válido")

    def authorized(self):
        if not PASSWORD:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                _, _, pw = base64.b64decode(header[6:]).decode("utf-8").partition(":")
                return hmac.compare_digest(pw.encode(), PASSWORD.encode())
            except Exception:
                return False
        return False

    # -- despacho
    def dispatch(self):
        self._body_read = False
        try:
            self._dispatch()
        finally:
            # Si no se leyó el cuerpo, la conexión keep-alive quedaría desincronizada.
            if not self._body_read and int(self.headers.get("Content-Length") or 0) > 0:
                self.close_connection = True

    def _dispatch(self):
        try:
            path = urlsplit(self.path).path
            if path == "/api/health":
                db().execute("SELECT 1")
                return self.send_json(200, {"ok": True})
            if not self.authorized():
                return self.send_bytes(401, b"Autenticacion requerida", "text/plain; charset=utf-8",
                                       {"WWW-Authenticate": 'Basic realm="Mantenimiento coches", charset="UTF-8"'})
            if path.startswith("/api/"):
                if self.command in ("POST", "PUT", "DELETE") and self.headers.get("X-Requested-With") != "mc":
                    raise ApiError(403, "Cabecera X-Requested-With ausente")
                for method, rx, fn in ROUTES:
                    m = rx.match(path)
                    if m and method == ("GET" if self.command == "HEAD" else self.command):
                        return fn(self, *[int(g) for g in m.groups()])
                if any(rx.match(path) for _, rx, _ in ROUTES):
                    raise ApiError(405, "Método no permitido")
                raise ApiError(404, "Ruta no encontrada")
            if self.command not in ("GET", "HEAD"):
                raise ApiError(405, "Método no permitido")
            return self.serve_static(path)
        except ApiError as exc:
            self.send_json(exc.status, {"error": exc.message})
        except sqlite3.OperationalError as exc:
            log.exception("Error de base de datos")
            self.send_json(503, {"error": "Base de datos no disponible: %s" % exc})
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception:
            log.exception("Error interno")
            try:
                self.send_json(500, {"error": "Error interno del servidor"})
            except Exception:
                self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = dispatch

    def serve_static(self, path):
        if path == "/":
            path = "/index.html"
        full = os.path.realpath(os.path.join(STATIC_DIR, path.lstrip("/")))
        if os.path.commonpath([full, os.path.realpath(STATIC_DIR)]) != os.path.realpath(STATIC_DIR) \
                or not os.path.isfile(full):
            raise ApiError(404, "No encontrado")
        with open(full, "rb") as fh:
            body = fh.read()
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
            ctype += "; charset=utf-8"
        self.send_bytes(200, body, ctype, {"Cache-Control": "no-cache"})


# ---------------------------------------------------------------- rutas API
@route("GET", r"/api/cars")
def api_cars(h):
    h.send_json(200, list_cars())


@route("POST", r"/api/cars")
def api_car_create(h):
    car_id = write_car(None, clean(h.json_body(), CAR_FIELDS))
    h.send_json(201, car_or_404(car_id))


@route("GET", r"/api/cars/(\d+)")
def api_car_get(h, car_id):
    car = car_or_404(car_id)
    car["mantenimientos"] = rows(db().execute(
        "SELECT * FROM maintenance WHERE car_id=? ORDER BY coalesce(fecha,'9999') DESC, id DESC", (car_id,)))
    car["has_photo"] = bool(db().execute("SELECT 1 FROM car_photos WHERE car_id=?", (car_id,)).fetchone())
    h.send_json(200, car)


@route("PUT", r"/api/cars/(\d+)")
def api_car_update(h, car_id):
    car_or_404(car_id)
    write_car(car_id, clean(h.json_body(), CAR_FIELDS, partial=True))
    h.send_json(200, car_or_404(car_id))


@route("DELETE", r"/api/cars/(\d+)")
def api_car_delete(h, car_id):
    car_or_404(car_id)
    with db() as conn:
        conn.execute("DELETE FROM cars WHERE id=?", (car_id,))
    h.send_json(200, {"ok": True})


@route("GET", r"/api/cars/(\d+)/photo")
def api_photo_get(h, car_id):
    row = db().execute("SELECT mime, data, updated_at FROM car_photos WHERE car_id=?", (car_id,)).fetchone()
    if not row:
        raise ApiError(404, "Sin foto")
    etag = '"%s"' % row["updated_at"]
    if h.headers.get("If-None-Match") == etag:
        return h.send_bytes(304, b"", row["mime"], {"ETag": etag})
    h.send_bytes(200, bytes(row["data"]), row["mime"],
                 {"ETag": etag, "Cache-Control": "private, max-age=3600"})


@route("PUT", r"/api/cars/(\d+)/photo")
def api_photo_put(h, car_id):
    car_or_404(car_id)
    data = h.read_body(MAX_PHOTO)
    if not data:
        raise ApiError(422, "Imagen vacía")
    mime = sniff_image(data)
    if not mime:
        raise ApiError(415, "Formato de imagen no admitido (JPEG, PNG o WebP)")
    with db() as conn:
        conn.execute("INSERT INTO car_photos (car_id, mime, data, updated_at) VALUES (?,?,?,?) "
                     "ON CONFLICT(car_id) DO UPDATE SET mime=excluded.mime, data=excluded.data, "
                     "updated_at=excluded.updated_at", (car_id, mime, data, now()))
    h.send_json(200, {"ok": True})


@route("DELETE", r"/api/cars/(\d+)/photo")
def api_photo_delete(h, car_id):
    with db() as conn:
        conn.execute("DELETE FROM car_photos WHERE car_id=?", (car_id,))
    h.send_json(200, {"ok": True})


@route("POST", r"/api/maintenance")
def api_maint_create(h):
    data = clean(h.json_body(), MAINT_FIELDS)
    car_or_404(data["car_id"])
    ts = now()
    cols = list(data)
    with db() as conn:
        cur = conn.execute("INSERT INTO maintenance (%s, created_at, updated_at) VALUES (%s,?,?)"
                           % (",".join(cols), ",".join("?" * len(cols))),
                           [data[c] for c in cols] + [ts, ts])
        sync_odometer(conn, data["car_id"], data.get("km"), data["estado"])
    row = db().execute("SELECT * FROM maintenance WHERE id=?", (cur.lastrowid,)).fetchone()
    h.send_json(201, dict(row))


@route("PUT", r"/api/maintenance/(\d+)")
def api_maint_update(h, mid):
    row = db().execute("SELECT * FROM maintenance WHERE id=?", (mid,)).fetchone()
    if not row:
        raise ApiError(404, "Mantenimiento no encontrado")
    data = clean(h.json_body(), MAINT_FIELDS, partial=True)
    data.pop("car_id", None)
    if data:
        with db() as conn:
            conn.execute("UPDATE maintenance SET %s, updated_at=? WHERE id=?"
                         % ",".join("%s=?" % c for c in data),
                         list(data.values()) + [now(), mid])
            merged = dict(row, **data)
            sync_odometer(conn, merged["car_id"], merged["km"], merged["estado"])
    h.send_json(200, dict(db().execute("SELECT * FROM maintenance WHERE id=?", (mid,)).fetchone()))


@route("DELETE", r"/api/maintenance/(\d+)")
def api_maint_delete(h, mid):
    with db() as conn:
        conn.execute("DELETE FROM maintenance WHERE id=?", (mid,))
    h.send_json(200, {"ok": True})


@route("GET", r"/api/alerts")
def api_alerts(h):
    h.send_json(200, compute_alerts())


@route("GET", r"/api/export")
def api_export(h):
    h.send_json(200, export_all(), {
        "Content-Disposition": 'attachment; filename="mantenimiento-coches-%s.json"' % date.today().isoformat()})


# ---------------------------------------------------------------- arranque
def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    try:
        init_db()
    except (OSError, sqlite3.Error) as exc:
        log.error("No se pudo abrir la base de datos en %s: %s", DB_PATH, exc)
        sys.exit(2)
    try:
        httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        log.error("No se pudo escuchar en %s:%s (%s)", HOST, PORT, exc)
        sys.exit(3)
    httpd.daemon_threads = True
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=httpd.shutdown).start())
    log.info("Escuchando en http://%s:%s (datos en %s)%s", HOST, PORT, DATA_DIR,
             " [con contraseña]" if PASSWORD else " [SIN contraseña]")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
