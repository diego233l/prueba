#!/usr/bin/env python3
"""Copia de seguridad consistente de la base de datos (usa la API de backup de SQLite).

Uso: backup.py <directorio_de_datos> [copias_a_conservar]
"""
import glob
import os
import sqlite3
import sys
from datetime import datetime


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    data_dir = sys.argv[1]
    keep = int(sys.argv[2]) if len(sys.argv) > 2 else 14
    src_path = os.path.join(data_dir, "coches.db")
    if not os.path.isfile(src_path):
        print("No hay base de datos que copiar en", src_path)
        return 0
    out_dir = os.path.join(data_dir, "backups")
    os.makedirs(out_dir, exist_ok=True)
    dest = os.path.join(out_dir, "coches-%s.db" % datetime.now().strftime("%Y%m%d-%H%M%S"))
    src = sqlite3.connect(src_path, timeout=30)
    dst = sqlite3.connect(dest)
    try:
        src.backup(dst)
        if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise sqlite3.DatabaseError("la copia no pasó la comprobación de integridad")
    except Exception as exc:
        dst.close()
        src.close()
        if os.path.exists(dest):
            os.remove(dest)
        print("Error en la copia de seguridad:", exc, file=sys.stderr)
        return 1
    dst.close()
    src.close()
    os.chmod(dest, 0o640)
    for old in sorted(glob.glob(os.path.join(out_dir, "coches-*.db")))[:-keep]:
        os.remove(old)
    print("Copia creada:", dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
