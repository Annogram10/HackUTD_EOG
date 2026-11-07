"""
Glasses camera check: one frame in, "possible leak / smoke / damage / nothing" out.
Uses the Nemotron omni model (vision + reasoning) on build.nvidia.com. It only flags; a human confirms or dismisses.
"""

import json
import os
import re
import urllib.request

URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1") + "/chat/completions"
VISION_MODEL = os.environ.get("NEMOTRON_VISION_MODEL", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning")

PROMPT = (
    "You are checking one frame from an oil and gas operator's glasses camera at night. "
    "Is there a visible possible leak (liquid on the ground or dripping), possible smoke or vapor, or possible damage "
    "(cracks, corrosion, broken parts)? Do not diagnose or give operating instructions. "
    'Answer with JSON only: {"finding": "leak"|"smoke"|"damage"|"none", "confidence": 0-1, "description": "one short sentence of what is visible"}'
)


def check_image(image_url: str) -> dict:
    key = os.environ.get("NVIDIA_API_KEY")
    if not key:
        return {"available": False, "error": "NVIDIA_API_KEY is not set"}
    body = json.dumps({
        "model": VISION_MODEL,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": PROMPT}, {"type": "image_url", "image_url": {"url": image_url}}]}],
        "max_tokens": 2048, "temperature": 0.6, "top_p": 0.95, "stream": False,
    }).encode()
    req = urllib.request.Request(URL, body, {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = json.loads(r.read())["choices"][0]["message"].get("content") or ""
        m = re.search(r"\{.*\}", text, re.S)
        out = json.loads(m.group(0)) if m else {}
        finding = out.get("finding", "none")
        return {"available": True, "model": VISION_MODEL, "finding": finding if finding in ("leak", "smoke", "damage", "none") else "none",
                "confidence": out.get("confidence"), "description": out.get("description", ""), "needs_human_confirmation": True}
    except Exception as e:
        return {"available": False, "error": str(e)[:120]}
