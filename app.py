#!/usr/bin/env python3
"""
Ahead Assist — local web demo
Camera → YOLO → voice alerts (browser Web Speech API)

Run: python app.py
Open: http://127.0.0.1:8000
"""

from __future__ import annotations

import io
import logging
from typing import Any

import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from PIL import Image
from ultralytics import YOLO

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MODEL_NAME = "yolov8n.pt"  # nano — fast, downloads automatically on first run
CONFIDENCE = 0.45
IOU = 0.5

# COCO classes we care about for "what's ahead" (index → name handled by model)
PRIORITY = {
    "car": 10,
    "truck": 10,
    "bus": 10,
    "motorcycle": 9,
    "bicycle": 8,
    "person": 7,
    "dog": 6,
    "cat": 6,
    "train": 9,
    "traffic light": 5,
    "stop sign": 5,
    "bench": 3,
    "chair": 2,
    "potted plant": 2,
    "fire hydrant": 2,
    "pole": 2,
    "parking meter": 2,
}

# Only announce detections whose box center falls in this horizontal band (0–1)
CENTER_BAND = (0.2, 0.8)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ahead-assist")

app = FastAPI(title="Ahead Assist", version="0.1.0")
model: YOLO | None = None


def load_model() -> YOLO:
    log.info("Loading YOLO model %s (first run may download weights)...", MODEL_NAME)
    return YOLO(MODEL_NAME)


def zone_from_x(cx: float) -> str:
    if cx < 0.33:
        return "left"
    if cx > 0.66:
        return "right"
    return "center"


def distance_hint(box_area_ratio: float) -> str:
    """Rough proximity from bbox area relative to frame (heuristic only)."""
    if box_area_ratio > 0.25:
        return "very close"
    if box_area_ratio > 0.12:
        return "close"
    if box_area_ratio > 0.05:
        return "ahead"
    return "in the distance"


def detect_objects(image_bytes: bytes) -> list[dict[str, Any]]:
    if model is None:
        raise RuntimeError("Model not loaded")

    pil = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    frame = cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)
    h, w = frame.shape[:2]
    frame_area = float(h * w)

    results = model.predict(
        source=frame,
        conf=CONFIDENCE,
        iou=IOU,
        verbose=False,
    )

    detections: list[dict[str, Any]] = []

    for result in results:
        boxes = result.boxes
        if boxes is None:
            continue
        for box in boxes:
            cls_id = int(box.cls[0])
            name = result.names[cls_id]
            conf = float(box.conf[0])
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            cx = ((x1 + x2) / 2) / w
            cy = ((y1 + y2) / 2) / h

            if not (CENTER_BAND[0] <= cx <= CENTER_BAND[1]):
                continue

            area_ratio = ((x2 - x1) * (y2 - y1)) / frame_area
            zone = zone_from_x(cx)
            priority = PRIORITY.get(name, 1)

            detections.append(
                {
                    "class": name,
                    "confidence": round(conf, 2),
                    "zone": zone,
                    "distance": distance_hint(area_ratio),
                    "priority": priority,
                    "bbox": {
                        "x1": round(x1 / w, 3),
                        "y1": round(y1 / h, 3),
                        "x2": round(x2 / w, 3),
                        "y2": round(y2 / h, 3),
                    },
                }
            )

    detections.sort(key=lambda d: (-d["priority"], -d["confidence"]))
    return detections


def phrase_for(d: dict[str, Any]) -> str:
    label = d["class"]
    zone = d["zone"]
    dist = d["distance"]

    if zone == "center":
        if dist == "very close":
            return f"{label} very close ahead"
        return f"{label} ahead, {dist}"
    return f"{label} on your {zone}, {dist}"


@app.on_event("startup")
def startup() -> None:
    global model
    model = load_model()
    log.info("Ready at http://127.0.0.1:8000")


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return INDEX_HTML


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/detect")
async def detect(file: UploadFile = File(...)) -> JSONResponse:
    try:
        data = await file.read()
        if not data:
            return JSONResponse({"error": "empty image"}, status_code=400)
        detections = detect_objects(data)
        alerts = [phrase_for(d) for d in detections[:5]]
        return JSONResponse(
            {
                "detections": detections,
                "alerts": alerts,
                "primary": alerts[0] if alerts else None,
            }
        )
    except Exception as exc:
        log.exception("Detection failed")
        return JSONResponse({"error": str(exc)}, status_code=500)


INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
  <title>Ahead Assist</title>
  <style>
    :root {
      --bg: #0a0a0f;
      --surface: #14141f;
      --text: #e8e6f0;
      --dim: #8b89a0;
      --accent: #f0a500;
      --mint: #72f1b8;
      --coral: #ff6b6b;
      --border: #2d2b42;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: system-ui, -apple-system, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      padding: 1rem;
      max-width: 520px;
      margin: 0 auto;
    }
    h1 { font-size: 1.4rem; margin-bottom: 0.25rem; }
    .sub { color: var(--dim); font-size: 0.85rem; margin-bottom: 1rem; line-height: 1.4; }
    .warn {
      background: rgba(255, 107, 107, 0.1);
      border: 1px solid rgba(255, 107, 107, 0.3);
      border-radius: 8px;
      padding: 0.75rem;
      font-size: 0.8rem;
      color: #ffb4b4;
      margin-bottom: 1rem;
    }
    .video-wrap {
      position: relative;
      border-radius: 12px;
      overflow: hidden;
      background: #000;
      border: 1px solid var(--border);
      aspect-ratio: 4/3;
      margin-bottom: 1rem;
    }
    video, canvas { width: 100%; height: 100%; object-fit: cover; display: block; }
    canvas { position: absolute; inset: 0; pointer-events: none; }
    .band {
      position: absolute;
      top: 0; bottom: 0;
      left: 20%; right: 20%;
      border-left: 1px dashed rgba(240, 165, 0, 0.35);
      border-right: 1px dashed rgba(240, 165, 0, 0.35);
      pointer-events: none;
    }
    .controls { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    button {
      flex: 1;
      padding: 0.85rem;
      border: none;
      border-radius: 8px;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
    }
    #startBtn { background: var(--accent); color: #111; }
    #stopBtn { background: var(--surface); color: var(--text); border: 1px solid var(--border); }
    button:disabled { opacity: 0.45; cursor: not-allowed; }
    .status {
      font-size: 0.85rem;
      color: var(--dim);
      margin-bottom: 0.75rem;
      min-height: 1.2em;
    }
    .status.active { color: var(--mint); }
    .last-alert {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 1rem;
      margin-bottom: 1rem;
      font-size: 1.1rem;
      min-height: 3rem;
    }
    .last-alert strong { color: var(--accent); display: block; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 0.35rem; }
    ul { list-style: none; font-size: 0.85rem; }
    li {
      padding: 0.5rem 0;
      border-bottom: 1px solid var(--border);
      color: var(--dim);
    }
    li span { color: var(--text); }
  </style>
</head>
<body>
  <h1>Ahead Assist</h1>
  <p class="sub">Local demo — detects objects ahead and speaks alerts. Use headphones. Learning project only.</p>
  <p class="warn">Not a navigation aid. Always use a cane, guide, or your own judgment. Test with a sighted person nearby.</p>

  <div class="video-wrap">
    <video id="video" playsinline autoplay muted></video>
    <canvas id="overlay"></canvas>
    <div class="band" aria-hidden="true"></div>
  </div>

  <div class="controls">
    <button id="startBtn">Start scanning</button>
    <button id="stopBtn" disabled>Stop</button>
  </div>
  <p class="status" id="status">Camera off</p>

  <div class="last-alert">
    <strong>Last alert</strong>
    <span id="lastAlert">—</span>
  </div>

  <ul id="list"></ul>

  <script>
    const video = document.getElementById('video');
    const canvas = document.getElementById('overlay');
    const ctx = canvas.getContext('2d');
    const capture = document.createElement('canvas');
    const startBtn = document.getElementById('startBtn');
    const stopBtn = document.getElementById('stopBtn');
    const statusEl = document.getElementById('status');
    const lastAlertEl = document.getElementById('lastAlert');
    const listEl = document.getElementById('list');

    let stream = null;
    let intervalId = null;
    let busy = false;
    const spoken = new Map(); // key → timestamp
    const DEBOUNCE_MS = 5000;
    const SCAN_MS = 600;

    function speak(text) {
      if (!window.speechSynthesis || !text) return;
      const u = new SpeechSynthesisUtterance(text);
      u.rate = 1.05;
      u.pitch = 1;
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(u);
    }

    function shouldSpeak(key) {
      const now = Date.now();
      const last = spoken.get(key) || 0;
      if (now - last < DEBOUNCE_MS) return false;
      spoken.set(key, now);
      return true;
    }

    function drawBoxes(detections) {
      if (!video.videoWidth) return;
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      detections.forEach(d => {
        const { x1, y1, x2, y2 } = d.bbox;
        const left = x1 * canvas.width;
        const top = y1 * canvas.height;
        const w = (x2 - x1) * canvas.width;
        const h = (y2 - y1) * canvas.height;
        ctx.strokeStyle = d.zone === 'center' ? '#f0a500' : '#72f1b8';
        ctx.lineWidth = 2;
        ctx.strokeRect(left, top, w, h);
        ctx.fillStyle = 'rgba(0,0,0,0.55)';
        ctx.fillRect(left, top - 20, Math.min(w, 140), 20);
        ctx.fillStyle = '#fff';
        ctx.font = '12px sans-serif';
        ctx.fillText(`${d.class} ${Math.round(d.confidence * 100)}%`, left + 4, top - 6);
      });
    }

    async function scanFrame() {
      if (busy || !stream || video.readyState < 2) return;
      busy = true;
      try {
        capture.width = video.videoWidth;
        capture.height = video.videoHeight;
        capture.getContext('2d').drawImage(video, 0, 0);
        const blob = await new Promise(r => capture.toBlob(r, 'image/jpeg', 0.75));
        const form = new FormData();
        form.append('file', blob, 'frame.jpg');

        const res = await fetch('/detect', { method: 'POST', body: form });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'detect failed');

        drawBoxes(data.detections || []);
        listEl.innerHTML = (data.detections || []).slice(0, 6).map(d =>
          `<li><span>${d.class}</span> · ${d.zone} · ${d.distance} · ${Math.round(d.confidence * 100)}%</li>`
        ).join('') || '<li>No objects in view</li>';

        if (data.primary) {
          const top = data.detections[0];
          const key = `${top.class}-${top.zone}`;
          if (shouldSpeak(key)) {
            lastAlertEl.textContent = data.primary;
            speak(data.primary);
            statusEl.textContent = 'Scanning · spoke alert';
          } else {
            statusEl.textContent = 'Scanning';
          }
        } else {
          statusEl.textContent = 'Scanning · path clear';
        }
        statusEl.classList.add('active');
      } catch (e) {
        statusEl.textContent = 'Error: ' + e.message;
        statusEl.classList.remove('active');
      } finally {
        busy = false;
      }
    }

    startBtn.onclick = async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: { ideal: 'environment' }, width: { ideal: 640 }, height: { ideal: 480 } },
          audio: false
        });
        video.srcObject = stream;
        await video.play();
        startBtn.disabled = true;
        stopBtn.disabled = false;
        statusEl.textContent = 'Scanning…';
        statusEl.classList.add('active');
        intervalId = setInterval(scanFrame, SCAN_MS);
        scanFrame();
      } catch (e) {
        statusEl.textContent = 'Camera denied: ' + e.message;
      }
    };

    stopBtn.onclick = () => {
      if (intervalId) clearInterval(intervalId);
      if (stream) stream.getTracks().forEach(t => t.stop());
      stream = null;
      startBtn.disabled = false;
      stopBtn.disabled = true;
      statusEl.textContent = 'Camera off';
      statusEl.classList.remove('active');
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      window.speechSynthesis?.cancel();
    };
  </script>
</body>
</html>
"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
    )
