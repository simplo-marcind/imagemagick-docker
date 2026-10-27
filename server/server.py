#!/usr/bin/env python3
"""HTTP server converting uploaded images of any format supported by ImageMagick to JPEG.

Endpoints:
  GET  /         - simple upload form
  POST /convert  - multipart field "file" (or raw request body) -> image/jpeg
                   optional query/form parameter: quality (1-100, default 90)
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from email.parser import BytesParser
from email.policy import HTTP as HTTP_POLICY
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = int(os.environ.get("PORT", "80"))
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "100"))
CONVERT_TIMEOUT = int(os.environ.get("CONVERT_TIMEOUT", "120"))
MAGICK = os.environ.get("MAGICK_BIN", "magick")
DEFAULT_QUALITY = 90

INDEX_HTML = b"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Convert to JPG</title></head>
<body>
  <h1>Convert any image to JPG</h1>
  <form action="/convert" method="post" enctype="multipart/form-data">
    <input type="file" name="file" required>
    <label>Quality <input type="number" name="quality" min="1" max="100" value="90"></label>
    <button type="submit">Convert</button>
  </form>
</body>
</html>
"""


class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def parse_multipart(content_type, body):
    """Returns ({field: str}, [(field, filename, bytes)]) for a multipart/form-data body."""
    message = BytesParser(policy=HTTP_POLICY).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    )
    fields, files = {}, []
    if not message.is_multipart():
        return fields, files
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename is None:
            fields[name] = payload.decode("utf-8", "replace")
        else:
            files.append((name, filename, payload))
    return fields, files


def parse_quality(value):
    if value is None or value == "":
        return DEFAULT_QUALITY
    try:
        quality = int(value)
    except ValueError:
        raise HttpError(400, "quality must be an integer between 1 and 100")
    if not 1 <= quality <= 100:
        raise HttpError(400, "quality must be an integer between 1 and 100")
    return quality


def safe_stem(filename):
    stem = os.path.splitext(os.path.basename(filename or ""))[0]
    stem = re.sub(r"[^A-Za-z0-9._-]", "_", stem).strip("._")
    return stem or "image"


def extension_hint(filename):
    """Extension helps ImageMagick with formats that have no magic bytes (e.g. TGA)."""
    ext = os.path.splitext(filename or "")[1].lstrip(".").lower()
    return ext if re.fullmatch(r"[a-z0-9]{1,8}", ext) else ""


def convert_to_jpg(data, filename, quality):
    """Converts image bytes of any supported format to JPEG bytes."""
    ext = extension_hint(filename)
    with tempfile.TemporaryDirectory(prefix="conv") as tmp:
        src = os.path.join(tmp, "input" + ("." + ext if ext else ""))
        dst = os.path.join(tmp, "output.jpg")
        with open(src, "wb") as f:
            f.write(data)

        cmd = [
            MAGICK,
            src + "[0]",  # first frame/page/image only (GIF, PDF, TIFF, multi-image HEIC)
            "-auto-orient",
            "-background", "white", "-alpha", "remove", "-alpha", "off",
            "-colorspace", "sRGB",
            "-quality", str(quality),
            "jpg:" + dst,
        ]
        try:
            proc = subprocess.run(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=CONVERT_TIMEOUT
            )
        except subprocess.TimeoutExpired:
            raise HttpError(504, "Conversion timed out")
        except OSError as exc:
            sys.stderr.write(f"Cannot run {MAGICK}: {exc}\n")
            raise HttpError(500, "Cannot run ImageMagick")

        if proc.returncode != 0 or not os.path.isfile(dst):
            sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
            sys.stderr.flush()
            raise HttpError(415, "Unsupported or invalid image")
        with open(dst, "rb") as f:
            return f.read()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ImagickJpgServer/1.0"

    def respond(self, status, body, content_type, extra_headers=()):
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def respond_error(self, status, message):

        self.respond(status, json.dumps({"error": message}).encode(), "application/json")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if urlsplit(self.path).path in ("/", "/index.html"):
            self.respond(200, INDEX_HTML, "text/html; charset=utf-8")
        else:
            self.respond_error(404, "Not found")

    def do_POST(self):
        parts = urlsplit(self.path)
        if parts.path.rstrip("/") != "/convert":
            self.respond_error(404, "Not found")
            return
        try:
            self.handle_convert(parse_qs(parts.query))
        except HttpError as exc:
            self.respond_error(exc.status, exc.message)
        except Exception as exc:  # noqa: BLE001 - never leave the client hanging
            sys.stderr.write(f"Unexpected error: {exc!r}\n")
            self.respond_error(500, "Internal error")

    def read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            raise HttpError(411, "Chunked uploads are not supported, send Content-Length")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise HttpError(400, "Invalid Content-Length")
        if length < 0:
            raise HttpError(400, "Invalid Content-Length")
        if length > MAX_UPLOAD_MB * 1024 * 1024:
            raise HttpError(413, f"Request body too large (limit {MAX_UPLOAD_MB} MB)")
        return self.rfile.read(length) if length else b""

    def handle_convert(self, query):
        body = self.read_body()
        content_type = self.headers.get("Content-Type", "")
        form = {k: v[-1] for k, v in query.items()}

        if content_type.lower().startswith("multipart/form-data"):
            fields, files = parse_multipart(content_type, body)
            form.update(fields)
            upload = next((f for f in files if f[0] == "file"), None) or (files[0] if files else None)
            if upload is None:
                raise HttpError(400, 'No file uploaded, send it in the multipart field "file"')
            _, filename, data = upload
        else:
            filename, data = self.headers.get("X-Filename", ""), body

        if not data:
            raise HttpError(400, "Empty file")

        jpg = convert_to_jpg(data, filename, parse_quality(form.get("quality")))
        self.respond(
            200,
            jpg,
            "image/jpeg",
            [("Content-Disposition", f'inline; filename="{safe_stem(filename)}.jpg"')],
        )


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Listening on port {PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
