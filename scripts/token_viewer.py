#!/usr/bin/env python3
"""
Simple on-chain token viewer for the Degenerus NFT on Sepolia.

Usage:
    python3 scripts/token_viewer.py

Requires:
    - SEPOLIA_RPC_URL (or equivalent) in .env / env/.env
    - env/wallets.json (or wallets.json) with contracts.nft populated
"""

import base64
import io
import json
import os
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk, scrolledtext, messagebox

from dotenv import load_dotenv
from web3 import Web3
from web3.middleware.proof_of_authority import ExtraDataToPOAMiddleware

try:
    import cairosvg
except ImportError:
    cairosvg = None

try:
    from svglib.svglib import svg2rlg
    from reportlab.graphics import renderPM
except ImportError:
    svg2rlg = None
    renderPM = None

try:
    from PIL import Image, ImageTk
except ImportError:
    Image = None
    ImageTk = None

ROOT = Path(__file__).resolve().parent.parent

def load_env():
    for candidate in (ROOT / ".env", ROOT / "env" / ".env"):
        if candidate.exists():
            load_dotenv(candidate, override=False)

def require_env(name: str) -> str:
    value = (
        os.environ.get(name)
        or os.environ.get(name.lower())
        or os.environ.get(name.replace("BURNIE_", ""))
        or os.environ.get(name.replace("DEGEN_", ""))
        or ""
    )
    if not value:
        raise RuntimeError(f"Missing environment variable {name}")
    return value


def resolve_rpc_url() -> str:
    for key in ("BURNIE_RPC_URL", "DEGEN_RPC_URL", "SEPOLIA_RPC_URL", "RPC_URL", "ALCHEMY_SEPOLIA_URL"):
        value = os.environ.get(key) or os.environ.get(key.lower())
        if value:
            return value
    return require_env("SEPOLIA_RPC_URL")

def load_wallets() -> dict:
    for candidate in (ROOT / "wallets.json", ROOT / "env" / "wallets.json"):
        if candidate.exists():
            with candidate.open() as fh:
                return json.load(fh)
    raise RuntimeError("wallets.json not found (checked repo root and env/)")

class TokenViewer(tk.Tk):
    def __init__(self, w3: Web3, nft_contract):
        super().__init__()
        self.w3 = w3
        self.nft = nft_contract
        self.current_photo = None
        self.current_svg_bytes: bytes | None = None
        self.preview_size = 512

        self.title("Degenerus Testnet Token Viewer")
        self.geometry("780x600")

        top = ttk.Frame(self, padding=8)
        top.pack(fill="x")

        ttk.Label(top, text="Token ID:").pack(side="left")
        self.token_var = tk.StringVar(value="1")
        token_entry = ttk.Entry(top, textvariable=self.token_var, width=12)
        token_entry.pack(side="left", padx=4)
        token_entry.bind("<Return>", lambda _event: self.fetch())

        ttk.Button(top, text="Fetch", command=self.fetch).pack(side="left", padx=4)
        ttk.Button(top, text="Save SVG", command=self.save_svg).pack(side="left", padx=4)

        self.status_var = tk.StringVar(value="Ready")
        ttk.Label(top, textvariable=self.status_var).pack(side="left", padx=12)

        body = ttk.Frame(self, padding=(8, 0, 8, 8))
        body.pack(fill="both", expand=True)

        preview_frame = ttk.LabelFrame(body, text="Preview", padding=8)
        preview_frame.pack(fill="both", expand=True)

        self.image_canvas = tk.Canvas(
            preview_frame,
            width=self.preview_size,
            height=self.preview_size,
            highlightthickness=0,
        )
        self.image_canvas.pack(fill="both", expand=True)
        self.image_canvas.bind("<Configure>", self._on_canvas_resize)
        self._show_placeholder("No image")

        meta_frame = ttk.LabelFrame(body, text="Metadata", padding=8)
        meta_frame.pack(fill="x", expand=False, pady=(8, 0))

        self.output = scrolledtext.ScrolledText(
            meta_frame,
            wrap="word",
            font=("Courier New", 10),
            height=12,
            width=80,
        )
        self.output.pack(fill="both", expand=False)

    def fetch(self):
        token_text = self.token_var.get().strip()
        if not token_text:
            messagebox.showwarning("Token Viewer", "Please enter a token ID.")
            return

        try:
            token_id = int(token_text, 0)
        except ValueError:
            messagebox.showerror("Token Viewer", f"Invalid token id: {token_text}")
            return

        self.status_var.set(f"Fetching token {token_id}…")
        self.update_idletasks()

        try:
            uri = self.nft.functions.tokenURI(token_id).call()
        except Exception as exc:
            messagebox.showerror("Token Viewer", f"tokenURI reverted: {exc}")
            self.status_var.set("Error")
            return
        metadata_text, metadata_obj = self._decode_metadata(uri)
        display_text = self._format_metadata(metadata_obj, metadata_text)
        output_lines = [
            f"Token {token_id}",
            "Decoded metadata:",
            display_text,
        ]
        self.output.delete("1.0", "end")
        self.output.insert("1.0", "\n".join(output_lines))
        self._display_image(metadata_obj, metadata_text)
        self.status_var.set("Done")

    def save_svg(self):
        if not self.current_svg_bytes:
            messagebox.showinfo("Token Viewer", "No SVG has been rendered yet.")
            return
        default_name = f"token_{self.token_var.get().strip() or 'metadata'}.svg"
        target = filedialog.asksaveasfilename(
            title="Save token SVG",
            defaultextension=".svg",
            filetypes=[("SVG image", "*.svg"), ("All files", "*.*")],
            initialfile=default_name,
        )
        if not target:
            return
        try:
            Path(target).write_bytes(self.current_svg_bytes)
        except Exception as exc:
            messagebox.showerror("Token Viewer", f"Failed to save SVG: {exc}")
            return
        self.status_var.set(f"Saved SVG → {target}")

    @staticmethod
    def _decode_metadata(uri: str):
        parsed_obj = None
        pretty_text = ""

        if not uri:
            return "<empty tokenURI>", None
        if uri.startswith("data:"):
            if ";base64," in uri:
                _, b64 = uri.split(";base64,", 1)
                try:
                    decoded = base64.b64decode(b64).decode("utf-8")
                    try:
                        parsed_obj = json.loads(decoded)
                        pretty_text = json.dumps(parsed_obj, indent=2, sort_keys=True)
                    except Exception:
                        pretty_text = decoded
                except Exception as exc:
                    pretty_text = f"<failed to decode base64: {exc}>"
            else:
                pretty_text = uri.split(",", 1)[-1]
        if uri.startswith("http://") or uri.startswith("https://"):
            try:
                import requests

                resp = requests.get(uri, timeout=10)
                resp.raise_for_status()
                try:
                    parsed_obj = json.loads(resp.text)
                    pretty_text = json.dumps(parsed_obj, indent=2, sort_keys=True)
                except Exception:
                    pretty_text = resp.text
            except Exception as exc:
                return f"<failed HTTP fetch: {exc}>", None
        if not pretty_text:
            pretty_text = uri
        if parsed_obj is None:
            try:
                parsed_obj = json.loads(pretty_text)
            except Exception:
                parsed_obj = None
        if isinstance(parsed_obj, dict):
            try:
                filtered = TokenViewer._clean_metadata_dict(parsed_obj)
                pretty_text = json.dumps(filtered, indent=2, sort_keys=True)
            except Exception:
                pass
        return pretty_text, parsed_obj

    @staticmethod
    def _clean_metadata_dict(metadata_obj: dict) -> dict:
        keys_of_interest = ["name", "description", "attributes", "traits"]
        filtered = {}
        for key in keys_of_interest:
            value = metadata_obj.get(key)
            if value:
                if key == "traits" and "attributes" in filtered:
                    continue
                filtered[key] = value
        if not filtered:
            filtered = {
                k: v
                for k, v in metadata_obj.items()
                if k not in {"image", "image_data", "animation_url", "imageUrl"}
            }
        return filtered

    @staticmethod
    def _format_metadata(metadata_obj, fallback_text: str) -> str:
        if isinstance(metadata_obj, dict):
            filtered = TokenViewer._clean_metadata_dict(metadata_obj)
            return json.dumps(filtered, indent=2, sort_keys=True)
        if fallback_text:
            try:
                parsed = json.loads(fallback_text)
                if isinstance(parsed, dict):
                    filtered = TokenViewer._clean_metadata_dict(parsed)
                    return json.dumps(filtered, indent=2, sort_keys=True)
            except Exception:
                pass
            return fallback_text
        return "<no metadata>"

    def _display_image(self, metadata: dict | None, metadata_text: str | None) -> None:
        self.current_photo = None
        self.current_svg_bytes = None
        self._show_placeholder("No image")

        md = metadata
        if md is None and metadata_text:
            try:
                md = json.loads(metadata_text)
            except Exception:
                md = None
        if not isinstance(md, dict):
            self._show_placeholder("No metadata JSON")
            return

        image_field = (
            md.get("image")
            or md.get("image_data")
            or md.get("animation_url")
            or md.get("imageUrl")
        )
        if not image_field or not isinstance(image_field, str):
            self._show_placeholder("No image field")
            return

        svg_bytes = self._extract_svg_bytes(image_field)
        if not svg_bytes:
            self._show_placeholder("Image not SVG or unsupported format")
            return

        if cairosvg is None and svg2rlg is None:
            self._show_placeholder("Install cairosvg or svglib+reportlab to render SVG preview")
            return

        self.current_svg_bytes = svg_bytes
        self._render_svg()

    @staticmethod
    def _extract_svg_bytes(data: str) -> bytes | None:
        data = data.strip()
        if not data:
            return None
        if data.startswith("data:"):
            try:
                header, payload = data.split(",", 1)
            except ValueError:
                return None
            if "svg" not in header.lower():
                return None
            if ";base64" in header.lower():
                try:
                    return base64.b64decode(payload)
                except Exception:
                    return None
            try:
                return payload.encode("utf-8")
            except Exception:
                return None
        if data.startswith("<svg"):
            return data.encode("utf-8")
        # sometimes provided as base64 without header
        try:
            decoded = base64.b64decode(data)
            if decoded.strip().startswith(b"<svg"):
                return decoded
        except Exception:
            pass
        if data.startswith("http://") or data.startswith("https://"):
            try:
                import requests

                resp = requests.get(data, timeout=10)
                resp.raise_for_status()
                content_type = resp.headers.get("content-type", "")
                raw = resp.content
                if "svg" in content_type.lower():
                    return raw
                if raw.strip().startswith(b"<svg"):
                    return raw
                try:
                    decoded = base64.b64decode(raw)
                    if decoded.strip().startswith(b"<svg"):
                        return decoded
                except Exception:
                    pass
            except Exception:
                return None
        return None

    def _render_svg(self):
        if not self.current_svg_bytes:
            return
        width = max(self.image_canvas.winfo_width(), 32)
        height = max(self.image_canvas.winfo_height(), 32)
        try:
            png_bytes = None
            if cairosvg is not None:
                png_bytes = cairosvg.svg2png(
                    bytestring=self.current_svg_bytes,
                    output_width=width,
                    output_height=height,
                )
            elif svg2rlg is not None and renderPM is not None:
                drawing = svg2rlg(io.BytesIO(self.current_svg_bytes))
                if drawing is None:
                    raise ValueError("Invalid SVG data")
                min_width_fn = getattr(drawing, "minWidth", lambda: None)
                dw_val = min_width_fn()
                if not dw_val:
                    dw_val = getattr(drawing, "width", width)
                dw = float(dw_val or width)
                dh_val = getattr(drawing, "height", None) or height
                dh = float(dh_val or height)
                dw = dw if dw > 0 else width
                dh = dh if dh > 0 else height
                scale = min(width / dw, height / dh)
                drawing.scale(scale, scale)
                png_bytes = renderPM.drawToString(drawing, fmt="PNG")
            else:
                self._show_placeholder("Install cairosvg or svglib+reportlab to render SVG preview")
                return
            if Image is not None and ImageTk is not None:
                image = Image.open(io.BytesIO(png_bytes))
                if image.width != width or image.height != height:
                    image = image.resize((width, height), Image.LANCZOS)
                self.current_photo = ImageTk.PhotoImage(image=image)
            else:
                b64_png = base64.b64encode(png_bytes).decode("ascii")
                self.current_photo = tk.PhotoImage(data=b64_png, format="png")
            self.image_canvas.delete("all")
            self.image_canvas.create_image(
                width // 2,
                height // 2,
                image=self.current_photo,
            )
        except Exception as exc:
            self._show_placeholder(f"Failed to render SVG: {exc}")

    def _show_placeholder(self, message: str) -> None:
        self.image_canvas.delete("all")
        bg = self.image_canvas.cget("background")
        self.image_canvas.create_rectangle(
            0,
            0,
            self.image_canvas.winfo_width(),
            self.image_canvas.winfo_height(),
            fill=bg,
            outline="",
        )
        self.image_canvas.create_text(
            self.image_canvas.winfo_width() // 2,
            self.image_canvas.winfo_height() // 2,
            text=message,
            fill="gray40",
            font=("TkDefaultFont", 12, "italic"),
        )

    def _on_canvas_resize(self, _event) -> None:
        if not self.current_svg_bytes:
            self._show_placeholder("No image")
            return
        self._render_svg()

def main():
    load_env()
    provider_url = resolve_rpc_url()
    wallets = load_wallets()
    contracts = wallets.get("contracts") or {}
    nft_addr = contracts.get("nft")
    if not nft_addr:
        raise RuntimeError("wallets.json missing contracts.nft entry")

    w3 = Web3(Web3.HTTPProvider(provider_url))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

    artifact_path = ROOT / "artifacts" / "contracts" / "DegenerusGamepieces.sol" / "DegenerusGamepieces.json"
    if not artifact_path.exists():
        raise RuntimeError(f"Missing artifact: {artifact_path}")
    with artifact_path.open() as fh:
        abi = json.load(fh)["abi"]

    nft_contract = w3.eth.contract(address=Web3.to_checksum_address(nft_addr), abi=abi)

    app = TokenViewer(w3, nft_contract)
    app.mainloop()

if __name__ == "__main__":
    main()
