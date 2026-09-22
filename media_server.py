#!/usr/bin/env python3
"""urali media service: lets a designer replace the site's images.

Runs on 127.0.0.1 only. Nginx sits in front with a login and forwards the
logged-in username as X-Remote-User. Every upload is decoded and re-encoded
with Pillow, so only pixels are ever written to the public folder.
"""
import io, json, os, shutil, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageOps

PUBLIC = os.environ.get("URALI_MEDIA_PUBLIC", "/var/www/urali/images")
PRIVATE = os.environ.get("URALI_MEDIA_PRIVATE", "/var/lib/urali-media")
PORT = int(os.environ.get("URALI_MEDIA_PORT", "3102"))
MAX_BYTES = 8 * 1024 * 1024
HISTORY_KEEP = 20

SLOTS = {
    "hero": {
        "label": "Top of the page",
        "where": "The big picture under the headline, the first thing people see.",
        "size": "At least 1600 × 1000 px, landscape",
        "kind": "photo", "max": 1600,
        "alt": "Banana chips frying in a bell-metal urali",
    },
    "box-classic": {
        "label": "Kaya Varuthathu box",
        "where": "Front of the first product box.",
        "size": "1200 × 1200 px, square",
        "kind": "photo", "max": 1200,
        "alt": "Kaya Varuthathu, salted nendran banana chips",
    },
    "box-duo": {
        "label": "Madhuram Duo box",
        "where": "Front of the second product box.",
        "size": "1200 × 1200 px, square",
        "kind": "photo", "max": 1200,
        "alt": "Madhuram Duo, banana chips and sharkara varatti",
    },
    "box-tin": {
        "label": "Palaharam Tin (coming soon)",
        "where": "Third product box. Shown faded, with a Coming soon ribbon.",
        "size": "1200 × 1200 px, square",
        "kind": "photo", "max": 1200,
        "alt": "Palaharam Tin of Kerala snacks",
    },
    "box-chakka": {
        "label": "Chakka Varuthathu (coming soon)",
        "where": "Fourth product box. Shown faded, with a Coming soon ribbon.",
        "size": "1200 × 1200 px, square",
        "kind": "photo", "max": 1200,
        "alt": "Chakka Varuthathu, jackfruit chips",
    },
    "favicon": {
        "label": "Browser tab icon",
        "where": "Browser tabs and the phone home-screen icon. Keep it bold and simple.",
        "size": "512 × 512 px, square",
        "kind": "favicon",
        "alt": "urali",
    },
    "og": {
        "label": "Link preview",
        "where": "The picture shown when uralichips.com is shared on WhatsApp, Facebook or Instagram.",
        "size": "1200 × 630 px",
        "kind": "og",
        "alt": "urali — Kerala banana chips fried in Thrissur after you order",
    },
}
FIXED = {"favicon": ["favicon.png", "favicon-180.png", "favicon-32.png"], "og": ["og-image.jpg"]}

LOCK = threading.Lock()
STATE_FILE = os.path.join(PRIVATE, "state.json")
AUDIT_FILE = os.path.join(PRIVATE, "audit.log")
ORIGINALS = os.path.join(PRIVATE, "originals")
DEFAULTS = os.path.join(PRIVATE, "defaults")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def atomic_write(path, data, mode="w"):
    tmp = path + ".tmp"
    with open(tmp, mode) as f:
        f.write(data)
    os.replace(tmp, path)


def load_state():
    try:
        with open(STATE_FILE) as f:
            st = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        st = {"slots": {}}
    for k, s in SLOTS.items():
        st["slots"].setdefault(k, {"current": None, "alt": s["alt"], "history": []})
    return st


def save_state(st):
    atomic_write(STATE_FILE, json.dumps(st, indent=1))
    manifest = {"updated": now_iso(), "slots": {}}
    for k, v in st["slots"].items():
        cur = v.get("current")
        if not cur:
            continue
        entry = next((h for h in v["history"] if h["file"] == cur), {})
        manifest["slots"][k] = {"src": f"/images/{cur}", "alt": v.get("alt") or SLOTS[k]["alt"],
                                "w": entry.get("w"), "h": entry.get("h")}
    atomic_write(os.path.join(PUBLIC, "manifest.json"), json.dumps(manifest, indent=1))


def audit(user, action, slot, detail=""):
    with open(AUDIT_FILE, "a") as f:
        f.write(json.dumps({"at": now_iso(), "user": user, "action": action,
                            "slot": slot, "detail": detail}) + "\n")


def publish_fixed(slot, source_file):
    """Favicon and link preview live at fixed addresses that the page's <head> points to."""
    src = os.path.join(PUBLIC, source_file)
    if slot == "favicon":
        img = Image.open(src).convert("RGBA")
        for name, size in (("favicon.png", 512), ("favicon-180.png", 180), ("favicon-32.png", 32)):
            img.resize((size, size), Image.LANCZOS).save(os.path.join(PUBLIC, name + ".tmp"), "PNG", optimize=True)
            os.replace(os.path.join(PUBLIC, name + ".tmp"), os.path.join(PUBLIC, name))
    elif slot == "og":
        shutil.copyfile(src, os.path.join(PUBLIC, "og-image.jpg.tmp"))
        os.replace(os.path.join(PUBLIC, "og-image.jpg.tmp"), os.path.join(PUBLIC, "og-image.jpg"))


def restore_default_fixed(slot):
    for name in FIXED.get(slot, []):
        d = os.path.join(DEFAULTS, name)
        if os.path.exists(d):
            shutil.copyfile(d, os.path.join(PUBLIC, name + ".tmp"))
            os.replace(os.path.join(PUBLIC, name + ".tmp"), os.path.join(PUBLIC, name))


def process(slot, data):
    """Decode, check, clean and resize. Returns (filename, width, height, bytes)."""
    try:
        probe = Image.open(io.BytesIO(data))
        fmt = (probe.format or "").upper()
        probe.verify()
    except Exception:
        raise ValueError("That file isn't a readable image.")
    if fmt not in ("PNG", "JPEG", "WEBP"):
        raise ValueError(f"{fmt or 'This format'} isn't supported. Use PNG, JPG or WebP.")
    img = Image.open(io.BytesIO(data))
    img = ImageOps.exif_transpose(img)
    if img.width < 64 or img.height < 64:
        raise ValueError("That image is too small. Use at least 64 × 64 pixels.")
    if img.width * img.height > 40_000_000:
        raise ValueError("That image is too large. Keep it under 40 megapixels.")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    kind = SLOTS[slot]["kind"]
    if kind == "photo":
        img = img.convert("RGBA") if img.mode in ("RGBA", "LA", "P") else img.convert("RGB")
        img.thumbnail((SLOTS[slot]["max"], SLOTS[slot]["max"]), Image.LANCZOS)
        name = f"{slot}-{stamp}.webp"
        img.save(os.path.join(PUBLIC, name), "WEBP", quality=82, method=5)
    elif kind == "favicon":
        img = ImageOps.fit(img.convert("RGBA"), (512, 512), Image.LANCZOS)
        name = f"favicon-{stamp}.png"
        img.save(os.path.join(PUBLIC, name), "PNG", optimize=True)
    elif kind == "og":
        base = img.convert("RGBA")
        bg = Image.new("RGBA", base.size, (255, 254, 248, 255))
        bg.alpha_composite(base)
        img = ImageOps.fit(bg.convert("RGB"), (1200, 630), Image.LANCZOS)
        name = f"og-{stamp}.jpg"
        img.save(os.path.join(PUBLIC, name), "JPEG", quality=85, optimize=True, progressive=True)
    else:
        raise ValueError("Unknown slot type.")
    size = os.path.getsize(os.path.join(PUBLIC, name))
    return name, img.width, img.height, size


class Handler(BaseHTTPRequestHandler):
    server_version = "urali-media/1"

    def log_message(self, fmt, *args):
        pass

    def user(self):
        return (self.headers.get("X-Remote-User") or "unknown")[:40]

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def fail(self, code, msg):
        self.send_json(code, {"ok": False, "error": msg})

    def read_body(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            raise ValueError("The request was empty.")
        if n > limit:
            raise ValueError(f"That file is {n // 1024 // 1024} MB. Keep it under {limit // 1024 // 1024} MB.")
        return self.rfile.read(n)

    def state_view(self):
        st = load_state()
        out = []
        for k, meta in SLOTS.items():
            v = st["slots"][k]
            out.append({"slot": k, **{x: meta[x] for x in ("label", "where", "size", "kind")},
                        "current": v["current"], "alt": v["alt"],
                        "history": list(reversed(v["history"]))[:HISTORY_KEEP]})
        return {"ok": True, "slots": out}

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/state":
            return self.send_json(200, self.state_view())
        if path == "/health":
            return self.send_json(200, {"ok": True})
        self.fail(404, "Not found.")

    def do_POST(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        try:
            if u.path == "/upload":
                slot = (qs.get("slot") or [""])[0]
                if slot not in SLOTS:
                    return self.fail(400, "Unknown image slot.")
                data = self.read_body(MAX_BYTES)
                with LOCK:
                    name, w, h, size = process(slot, data)
                    os.makedirs(ORIGINALS, exist_ok=True)
                    with open(os.path.join(ORIGINALS, name + ".original"), "wb") as f:
                        f.write(data)
                    st = load_state()
                    st["slots"][slot]["history"].append(
                        {"file": name, "w": w, "h": h, "bytes": size, "at": now_iso(), "by": self.user()})
                    st["slots"][slot]["current"] = name
                    if slot in FIXED:
                        publish_fixed(slot, name)
                    save_state(st)
                    audit(self.user(), "upload", slot, name)
                return self.send_json(200, {"ok": True, "file": name, "w": w, "h": h, "bytes": size})

            body = json.loads(self.read_body(64 * 1024) or b"{}")
            slot = body.get("slot")
            if slot not in SLOTS:
                return self.fail(400, "Unknown image slot.")
            with LOCK:
                st = load_state()
                v = st["slots"][slot]
                if u.path == "/alt":
                    alt = " ".join(str(body.get("alt", "")).split())[:160]
                    if not alt:
                        return self.fail(400, "The description can't be empty.")
                    v["alt"] = alt
                    save_state(st)
                    audit(self.user(), "alt", slot, alt)
                elif u.path == "/use":
                    f = body.get("file")
                    if not any(h["file"] == f for h in v["history"]):
                        return self.fail(400, "That version doesn't exist.")
                    v["current"] = f
                    if slot in FIXED:
                        publish_fixed(slot, f)
                    save_state(st)
                    audit(self.user(), "use", slot, f)
                elif u.path == "/revert":
                    v["current"] = None
                    if slot in FIXED:
                        restore_default_fixed(slot)
                    save_state(st)
                    audit(self.user(), "revert", slot)
                else:
                    return self.fail(404, "Not found.")
            return self.send_json(200, {"ok": True})
        except ValueError as e:
            return self.fail(400, str(e))
        except Exception as e:
            audit(self.user(), "error", u.path, repr(e)[:200])
            return self.fail(500, "Something went wrong on the server.")


def main():
    os.makedirs(PUBLIC, exist_ok=True)
    os.makedirs(PRIVATE, exist_ok=True)
    with LOCK:
        save_state(load_state())
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
