# Faceter

Integration with the Faceter project. The stack is split into lightweight daemons that can be deployed independently on OpenIPC cameras.

## faceter-agent

faceter-agent is a service for IP cameras that connects devices to the Faceter platform.

## Main Functions
- Registers the camera on the platform.
- Exchanges telemetry.
- Sends events:
  - motion detection,
  - person detection.
- Configures video streams (RTSP/MJPEG), snapshots, and detector parameters.
- Runs on OpenIPC firmware.
- Communicates with the Faceter Cloud over secure channels.

## Configuration and Resources
- Main configuration file:
  `/etc/faceter-agent.conf`
- Device resources:
  `/usr/share/faceter`
- The firmware includes certificates and feature flags required for operation.
- Starts the main service by default; `-v` prints the current version.
- Distributed with an overlay package containing production-ready configs and assets.

## Runtime Dependencies (on the camera)
- OpenIPC firmware with Majestic service and `cli` utility.
- `fw_printenv` and `ipcinfo` tools.
- Init scripts `/etc/init.d/S95majestic`.
- BusyBox utilities (`pidof`, `reboot`, `sync`, glob support).
- Access to `/etc/faceter-agent.conf`, `/usr/share/faceter`, temporary and storage paths.
- Network access to Faceter Cloud (MQTT/HTTPS/RTSP).
- Valid NTP time sync.

**Mobile app screenshots**

![screen #1](docs/agent-gallery/android-app.jpg)


## faceter-detector

### Purpose

`faceter-detector` is a standalone utility for OpenIPC cameras. It pulls the local MJPEG preview stream, decodes frames to estimate motion volume, crops motion-driven ROIs, and runs them through a TVM AOT–compiled person model. The utility emits PERSON/MOTION events in ISO-8601 format and can optionally persist the evidence images.

Any HTTP MJPEG streamer is supported—just point `--stream-url` to the feed you want to analyze, whether it is served by the camera firmware or an external encoder. For best results, use a 16:9 aspect ratio stream at 512×288 resolution and 5 fps. Both width and height should be multiples of 16 for optimal processing efficiency. Higher resolutions or frame rates may overload the CPU.

### Key capabilities

- Two-stage pipeline: motion heuristics followed by a 96×96 TVM AOT inference.
- Adjustable thresholds, ROI export, and resolution-adaptive processing.
- Snapshot annotation (`--snapshot-rect`) and per-event labeling to aid triage.
- Motion-only mode (`--disable-person-detector`) for slow devices.
- Snapshot and ROI folders are purged on startup to guarantee fresh data.
- Debug ROI dumps for dataset accumulation and `--debug-roi-logic` for blob traceability.

### Runtime dependencies
- Local MJPEG stream endpoint (default `http://127.0.0.1/mjpeg`).

### Quick start

```bash
ssh root@camera '/usr/bin/faceter-detector \
  --stream-url http://root:12345@127.0.0.1/mjpeg \
  --snapshot-path /tmp/faceter-detector/snapshot'
```

### Automation example

A common integration scenario is to supervise the detector with a shell script:

1. Start `faceter-detector` in the background with `--snapshot-path /tmp/faceter-detector/snapshot`.
2. Tail stdout, wait for a `PERSON` line, and parse the `snapshot=...jpg` field.
3. Once a snapshot appears, copy it and push a notification to a messenger bot along with the probability and timestamp.

Because the detector writes each snapshot before printing the PERSON line, the script can safely download the referenced JPEG immediately, then relay both the image and event metadata to the user chat.

### Launch parameters

```
  -h, --help                     Show help and exit.
  --stream-url URL               MJPEG stream URL (default http://root:12345@127.0.0.1/mjpeg).
  --person-thr FLOAT             PERSON probability threshold. Defaults: indoor 0.55, outdoor 0.40.
  --motion-thr FLOAT             MOTION confidence threshold after exp-filter (default 0.5).
  --motion-fps-decode FLOAT      Decode cadence for motion detection, clamped to 0.2–15 fps (default 5).
  --snapshot-path DIR            Snapshot directory (default /tmp/faceter-detector/snapshot).
  --snapshot-count INT           Number of snapshots to keep (default 10, min 1, newest retained).
  --snapshot-rect BOOL           Draw PERSON rectangles on saved snapshots (default true).
  --snapshot-rect-probe BOOL     Draw probability labels near the bounding box (default false).
  --snapshot-motion BOOL         Persist MOTION snapshots (default false).
  --debug-save-img [DIR]         Dump 96×96 ROIs (default /tmp/faceter-detector).
  --disable-person-detector      Skip inference; watch motion only.
  --scene indoor|outdoor         Scene preset affecting filters and defaults (default indoor).
  --debug                        Verbose logging to stderr.
  --debug-roi-logic              Print blob selection diagnostics.
  --motion-debug                 Extra motion heatmap logging.
```

Boolean flags accept `true/false`, `yes/no`, or `1/0`.

All PERSON/MOTION rectangles (`rect=x,y,w,h`) are normalized to a notional 100×100 frame, so downstream systems can treat them as percentage-style coordinates regardless of the camera resolution.

### Output format

Events are printed to stdout, one per line:

```
2025-11-24T08:02:39+00:00 PERSON prob=0.73 rect=42,35,18,40 snapshot=/tmp/faceter-detector/snapshot/...
2025-11-24T08:02:45+00:00 MOTION 0.58 rect=40,30,22,24
```

The `rect` coordinates are reported in normalized 0..100 space (width = height = 100). When snapshots are enabled, the path is appended to PERSON events so `faceter-agent` can forward it.
For MOTION rows the reported confidence is the exponentially-compressed value, while internal ROI gating continues to use the linear metric from `person_roi`.

### Storage & housekeeping

- `--snapshot-path` stores annotated frames; `--debug-save-img` stores ROI crops.
- Both folders are created automatically and wiped during startup (`remove_all_snapshot_files`) to prevent stale evidence from being mixed with new detections.
- `cleanup_old_snapshots` keeps only the most recent `--snapshot-count` JPEGs, ensuring bounded flash usage.

### Sample detections

**Day scenes**

![Day detection #1](docs/detector-gallery/2025-11-22_09-27-11.353_roi96x96_290_0_prob0.991_rect.jpg)
![Day detection #2](docs/detector-gallery/2025-11-22_11-58-31.142_roi96x96_369_46_prob0.989_rect.jpg)
![Day detection #3](docs/detector-gallery/2025-11-24_08-02-39.565_roi96x96_396_35_prob0.969_rect.jpg)

**Night scenes**

![Night detection #1](docs/detector-gallery/2025-11-27_05-38-54.040_roi96x96_291_0_prob0.993_rect.jpg)
![Night detection #2](docs/detector-gallery/2025-11-27_05-17-24.881_roi115x148_350_12_prob0.987_rect.jpg)
![Night detection #3](docs/detector-gallery/2025-11-26_19-21-27.858_roi96x96_416_34_prob0.988_rect.jpg)

### Computer vision pipeline

The detector uses a multi-stage ROI builder before inference:

#### Motion detection

- **Frame-to-frame difference:** consecutive gray frames are compared with a 5-level threshold. The image is processed block-wise (16×16) and flood-filled to form motion bounding boxes.
- **Event filter:** the raw motion share (after the 2 % noise cutoff) is converted via `motion = 1 - exp(-12 * (volume_raw - 0.02))` before comparing against `--motion-thr`, so weak movement is boosted without touching the rest of the ROI logic.
- **Adaptive background subtraction:** the background buffer lives in Q8 fixed-point form and is updated via exponential moving average (α = 1/16 outdoor, 1/8 indoor). Difference thresholds of 18/26 (outdoor/indoor) allow lighting adaptation.
- **Glare detection:** dominant brightness jumps that affect >70 % of pixels trigger a 12-frame cooldown to ignore rolling shutter flare.

#### Morphological operations

- **3×3 closing:** dilation followed by erosion smooths the binary mask. The implementation is NEON-optimized and handles 16 pixels per pass.

#### Blob detection

- **Connected components:** a stack-based flood-fill finds blobs that satisfy geometric constraints: min height 5 % of the frame, aspect ratio 0.08–1.25 (outdoor) / 0.10–1.10 (indoor), and area 0.15 %–65 % of the frame.
- **Geometry filtering:** blobs are sorted by height and expanded to match human proportions (aspect ratio ≈0.35). Indoor/outdoor presets adjust the horizontal/vertical expansion (×1.10–1.20 / ×1.05–1.12) and bias (0.45–0.65) to keep the head inside the ROI.

#### ROI processing

- **Bilinear interpolation:** ROIs are resized to 96×96. Weight tables for popular ROI sizes are cached (LRU, 32 entries) to avoid recomputation.
- **Sobel edge detection:** Gx/Gy gradients feed the edge energy score and the vertical-ratio heuristic, helping suppress ROI textures that are not human silhouettes.
- **RGB→grayscale:** conversion follows ITU-R BT.601 and is vectorized with NEON (`vmull_u8` + `vshrn_n_u16`), processing eight pixels per instruction.

#### False-positive filtering

- **Fast-move detector:** tracks ROI center movement; shifts ≥0.6× diagonal force an inference to avoid missing fast subjects.
- **Static ROI filter:** ROIs with <4 px displacement, <0.25 probability, and <2 % motion volume are considered static background and ignored.
- **Motion mask intersection:** indoor mode intersects the binary motion mask with the background-subtraction mask to filter shadows and flicker.

At this point every candidate ROI is normalized and pushed into the on-device person classifier. The model is a lightweight 96×96 RGB CNN distilled from the Visual Wake Words family and kept in float32 form. The detector now uses a TVM AOT–compiled model: the generated C module is statically linked, requires no interpreter, and exposes a single entrypoint function that the detector invokes directly for each ROI.

### Optimizations
- TVM AOT replaces TensorFlow Lite Micro, removing the interpreter and reducing RAM usage.
- NEON SIMD paths cover RGB conversion, frame differencing, morphological closing, and model input normalization. The detector auto-detects NEON and falls back to scalar code otherwise.

### Debugging & operational tips

- Use `--debug` to log each pipeline stage to stderr.
- `--motion-debug` dumps per-frame motion volume, bounding boxes, and cooldown state.
- `--debug-roi-logic` prints why blobs were accepted or rejected.
- `--debug-save-img` is ideal for collecting ROI datasets for further model training.
