"""Pack the fb-spa-guard extension as a signed CRX3 (Chromium) and an XPI.

No browser needed at install time: the CRX3 container is a protobuf header
plus the zip, signed with RSA-SHA256 through the openssl CLI.

Usage: crx3_pack.py SRC_DIR KEY_PEM OUT_DIR VERSION ALLOWED_PATHS_JSON
Prints the Chromium extension id on stdout. Writes OUT_DIR/{guard.crx,
guard.xpi,update.xml,unpacked/}; update.xml points at the crx by absolute file:// URL.
"""

from __future__ import annotations

import hashlib
import io
import json
import shutil
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

PLACEHOLDER = "__ALLOWED_PATHS__"
FIXED_ZIP_TIME = (2020, 1, 1, 0, 0, 0)  # byte-stable output for equal input


def varint(value: int) -> bytes:
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def field(number: int, payload: bytes) -> bytes:
    """Protobuf length-delimited field."""
    return varint(number << 3 | 2) + varint(len(payload)) + payload


def public_key_der(key_pem: Path) -> bytes:
    return subprocess.run(
        ["openssl", "rsa", "-in", str(key_pem), "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout


def extension_id(pub_der: bytes) -> str:
    digest = hashlib.sha256(pub_der).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def build_zip(src: Path, version: str, allowed_json: str) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(src.iterdir()):
            text = path.read_text()
            if path.name == "manifest.json":
                manifest = json.loads(text)
                manifest["version"] = version
                text = json.dumps(manifest, indent=1)
            text = text.replace(PLACEHOLDER, allowed_json)
            info = zipfile.ZipInfo(path.name, FIXED_ZIP_TIME)
            info.external_attr = 0o644 << 16
            archive.writestr(info, text)
    return buffer.getvalue()


def sign(key_pem: Path, data: bytes) -> bytes:
    return subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_pem)],
        check=True,
        input=data,
        capture_output=True,
    ).stdout


def build_crx(key_pem: Path, archive: bytes) -> tuple[bytes, str]:
    pub = public_key_der(key_pem)
    crx_id_raw = hashlib.sha256(pub).digest()[:16]
    signed_header = field(1, crx_id_raw)
    signed = (
        b"CRX3 SignedData\x00"
        + struct.pack("<I", len(signed_header))
        + signed_header
        + archive
    )
    proof = field(1, pub) + field(2, sign(key_pem, signed))
    header = field(2, proof) + field(10000, signed_header)
    crx = b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive
    return crx, extension_id(pub)


def main(argv: list[str]) -> int:
    src, key, out = Path(argv[1]), Path(argv[2]), Path(argv[3])
    version, allowed_json = argv[4], argv[5]
    json.loads(allowed_json)  # fail early on malformed input
    archive = build_zip(src, version, allowed_json)
    crx, ext_id = build_crx(key, archive)
    out.mkdir(parents=True, exist_ok=True)
    (out / "guard.crx").write_bytes(crx)
    (out / "guard.xpi").write_bytes(archive)
    # Unpacked copy for browsers that ignore forced installs (ungoogled-
    # chromium): they get it through --load-extension instead.
    unpacked = out / "unpacked"
    shutil.rmtree(unpacked, ignore_errors=True)
    zipfile.ZipFile(io.BytesIO(archive)).extractall(unpacked)
    (out / "update.xml").write_text(
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<gupdate xmlns='http://www.google.com/update2/response' "
        "protocol='2.0'>"
        f"<app appid='{ext_id}'><updatecheck "
        f"codebase='file://{(out / 'guard.crx').resolve()}' "
        f"version='{version}'/></app></gupdate>\n"
    )
    print(ext_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
