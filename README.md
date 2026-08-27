# Ahead Assist

Local web demo: camera → YOLO object detection → voice alerts in the browser.

**Assistive learning project — not a replacement for a cane, guide dog, or human help.**

## Stack (all free)

- [Ultralytics YOLOv8n](https://github.com/ultralytics/ultralytics) (pretrained COCO)
- [FastAPI](https://fastapi.tiangolo.com/) backend
- Browser camera (`getUserMedia`)
- [Web Speech API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API) for voice (no API keys)

## Quick start

```bash
cd ahead-assist
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python app.py
```

Open **http://127.0.0.1:8000** in Chrome (recommended).

On your phone (same Wi‑Fi): **http://\<your-laptop-ip\>:8000**

## Usage

1. Click **Start scanning**
2. Allow camera access
3. Point camera forward — alerts speak when objects appear in the center view
4. Use headphones in public

## How it works

- Browser captures a frame every ~0.6s
- Sends image to `POST /detect`
- YOLO finds objects; server filters to the center region and assigns left / center / right
- Browser speaks debounced alerts (e.g. “Bicycle ahead, center”)

## Colab notebook

Experiment with YOLO detection, thresholds, and alert phrasing before changing the web app:

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/adhikariastha5/ahead-assist/blob/main/notebooks/01_yolo_explorer.ipynb)

Or open `notebooks/01_yolo_explorer.ipynb` locally in Jupyter.

## License

MIT
