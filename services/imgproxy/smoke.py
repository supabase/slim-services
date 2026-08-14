#!/usr/bin/env python3
"""Standalone imgproxy codec checker using only Python stdlib."""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import socketserver
import struct
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import zlib


# 10x10 solid-color fixtures generated once and committed as bytes. The
# checker never imports a host image library: PNG output is decoded below with
# the stdlib zlib implementation and a small PNG filter implementation.
FIXTURES = {
    "jpeg": ("source.jpg", "image/jpeg", "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAKAAoDAREAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAL/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAQI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AtEzYAAA//9k="),
    "png": ("source.png", "image/png", "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKAQMAAAC3/F3+AAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURTOqd////+tI9cwAAAABYktHRAH/Ai3eAAAAB3RJTUUH6ggOCRI7bYoMzgAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wOC0xNFQwOToxODo1OSswMDowMKzveFgAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDg tMT RUMDk6MTg6NTkrMDA6MDDdssDkAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA4LTE0VDA5OjE4OjU5KzAwOjAwiqfhOwAAAAtJREFUCNdjYMAHAAAeAAFuhUcyAAAAAElFTkSuQmCC".replace(" ", "")),
    "webp": ("source.webp", "image/webp", "UklGRjAAAABXRUJQVlA4ICQAAABwAQCdASoKAAoAAgA0JaACdAGgAACaIwyH/87B/96P/THqIAA="),
    "gif": ("source.gif", "image/gif", "R0lGODlhCgAKAPABADOqd////yH5BAAAAAAALAAAAAAKAAoAAAIIhI+py+0PYysAOw=="),
    "avif": ("source.avif", "image/avif", "AAAAHGZ0eXBhdmlmAAAAAG1pZjFhdmlmbWlhZgAAANZtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAACJpbG9jAAAAAERAAAEAAQAAAAAA+gABAAAAAAAAACQAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABhdjAxAAAAAA5waXRtAAAAAAABAAAAVmlwcnAAAAA4aXBjbwAAAAxhdjFDgQAMAAAAABRpc3BlAAAAAAAAAAoAAAAKAAAAEHBpeGkAAAAAAwgICAAAABZpcG1hAAAAAAAAAAEAAQOBAgMAAAAsbWRhdBIACgkYDOZaICGg0IAyFRlHh4Yhh5555oAAAHWGTbPBOVtU/A=="),
}


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        name = self.path.rsplit("/", 1)[-1]
        for _kind, (filename, content_type, encoded) in FIXTURES.items():
            if name == filename:
                body = base64.b64decode(encoded)
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        self.send_error(404)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def png_pixels(body: bytes) -> tuple[int, int, bytes]:
    if body[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("response is not PNG")
    pos = 8
    width = height = None
    bit_depth = color_type = None
    palette = b""
    compressed = bytearray()
    while pos + 12 <= len(body):
        size = struct.unpack(">I", body[pos : pos + 4])[0]
        kind = body[pos + 4 : pos + 8]
        payload = body[pos + 8 : pos + 8 + size]
        pos += 12 + size
        if kind == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", payload[:10])
        elif kind == b"PLTE":
            palette = payload
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    if width is None or height is None:
        raise AssertionError(f"PNG lacks an IHDR (len={len(body)} prefix={body[:32]!r})")
    decoded = zlib.decompress(bytes(compressed))
    if bit_depth != 8:
        # Palette/1-bit output is valid for the tiny solid fixtures. The
        # decompressed scanlines still prove non-empty decoded pixel data.
        if not decoded or (not any(decoded) and not any(palette)):
            raise AssertionError("decoded low-bit-depth PNG pixels are empty")
        return width, height, decoded
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise AssertionError(f"unsupported PNG color type {color_type}")
    stride = width * channels
    rows: list[bytes] = []
    cursor = 0
    previous = bytearray(stride)
    for _ in range(height):
        filter_kind = decoded[cursor]
        cursor += 1
        row = bytearray(decoded[cursor : cursor + stride])
        cursor += stride
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            above = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if filter_kind == 1:
                row[i] = (row[i] + left) & 255
            elif filter_kind == 2:
                row[i] = (row[i] + above) & 255
            elif filter_kind == 3:
                row[i] = (row[i] + ((left + above) // 2)) & 255
            elif filter_kind == 4:
                p = left + above - upper_left
                pa, pb, pc = abs(p - left), abs(p - above), abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else above if pb <= pc else upper_left
                row[i] = (row[i] + predictor) & 255
            elif filter_kind != 0:
                raise AssertionError(f"unsupported PNG filter {filter_kind}")
        rows.append(bytes(row))
        previous = row
    pixels = b"".join(rows)
    if not pixels or not any(pixels):
        raise AssertionError("decoded PNG pixels are empty")
    return width, height, pixels


def request(url: str, timeout: float = 10) -> tuple[int, dict[str, str], bytes]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read()
    except urllib.error.HTTPError as error:
        body = error.read()
        raise AssertionError(f"HTTP {error.code} for {url}: {body[:200]!r}") from error


def vips_support(rootfs: str) -> tuple[bool, str]:
    env = os.environ.copy()
    env.update(
        VIPSHOME=rootfs,
        VIPS_MODULE_PATH=os.path.join(rootfs, "lib/vips-modules-8.16"),
        GIO_MODULE_DIR=os.path.join(rootfs, "share/gio-modules"),
    )
    if sys.platform == "darwin":
        env["DYLD_PRINT_LIBRARIES"] = "1"
    result = subprocess.run([os.path.join(rootfs, "bin/vips"), "-l"], env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"vips -l failed: {result.stderr[-500:]}")
    output = result.stdout + result.stderr
    loaded_trace = result.stderr
    if "/nix/store/" in loaded_trace:
        raise AssertionError(f"relocated vips loaded a Nix-store path: {loaded_trace[-1000:]}")
    required = ("jpegload", "pngload", "webpload", "gifload")
    missing = [name for name in required if name not in output]
    if missing:
        raise AssertionError(f"vips loader report missing {missing}")
    return "heifload" in output or "avifload" in output, output


def run_smoke(mode: str, rootfs: str | None, image: str | None) -> None:
    if mode == "rootfs":
        assert rootfs
        supports_avif, vips_report = vips_support(rootfs)
    else:
        assert image
        supports_avif, vips_report = True, "upstream image codec set"

    fixture_server = socketserver.ThreadingTCPServer(("0.0.0.0", 0), FixtureHandler)
    fixture_thread = threading.Thread(target=fixture_server.serve_forever, daemon=True)
    fixture_thread.start()
    fixture_port = fixture_server.server_address[1]
    source_host = "127.0.0.1" if mode == "rootfs" else "host.docker.internal"
    source_base = f"http://{source_host}:{fixture_port}"
    existing_endpoint = os.environ.get("IMGPROXY_SMOKE_ENDPOINT", "").rstrip("/")
    if not existing_endpoint:
        raise AssertionError("IMGPROXY_SMOKE_ENDPOINT is required; smoke.sh owns lifecycle")

    try:
        base_url = existing_endpoint

        tested = ["jpeg", "png", "webp", "gif"] + (["avif"] if supports_avif else [])
        for kind in tested:
            filename, _source_type, _encoded = FIXTURES[kind]
            source_url = f"{source_base}/{filename}"
            encoded_url = base64.urlsafe_b64encode(source_url.encode()).decode().rstrip("=")
            # A non-plain path is imgproxy's URL-safe-base64 form; /plain/
            # would treat the encoded text itself as the source URL.
            transform = f"{base_url}/insecure/rs:fill:19:13:1/{encoded_url}.png"
            status, headers, body = request(transform)
            if status != 200 or headers.get("content-type", "").split(";", 1)[0] != "image/png":
                raise AssertionError(f"{kind} transform returned {status} {headers.get('content-type')}")
            width, height, pixels = png_pixels(body)
            if (width, height) != (19, 13) or not pixels:
                raise AssertionError(f"{kind} output dimensions/pixels invalid: {width}x{height}")
            print(f"codec={kind} status={status} content_type=image/png dimensions={width}x{height} bytes={len(body)}")

        print("endpoint-check=ok")
    finally:
        fixture_server.shutdown()
        fixture_server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rootfs")
    parser.add_argument("--image")
    args = parser.parse_args()
    if bool(args.rootfs) == bool(args.image):
        parser.error("provide exactly one of --rootfs or --image")
    run_smoke("rootfs" if args.rootfs else "image", args.rootfs, args.image)
    print("imgproxy codec checker passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
