## Overview

We interact with Majestic in two ways:

- As a service: we check whether the process is running and, if needed, start it or fully restart it via the OpenIPC init script.
- As configuration: we do not edit `/etc/majestic.yaml` directly. Instead, we read/write parameters via the `cli` utility (keys like `.video0.*`, `.jpeg.*`, `.audio.*`, `.image.*`). In other words, we operate on Majestic’s configuration tree through its standard interface.

Separately: we use Majestic as the source of local endpoints (HTTP snapshot `/image.jpg`, MJPEG `/mjpeg`, RTSP), but that is consumption of streams rather than “intervention”.

## Majestic lifecycle management (start/restart)

### Start when the agent launches

At application start we check whether Majestic is alive (via `pidof majestic`). If it is not running, we start it using `/etc/init.d/S95majestic start` and wait briefly for the service to come up.

### Majestic restart

Restart is done only as a “full” restart via `/etc/init.d/S95majestic restart` (the code assumes “HUP is not supported”). After restarting we pause and check again that the process is running; if it is not, we try starting it.

## When and how we change Majestic settings

### Automatic settings application at startup (main mechanism)

Right after reading our main config (`/etc/faceter-agent.conf`), we take the `cameraConfig` section and its three sub-sections:

- `cameraConfig.mainStream` → Majestic `.video0.*`
  - stream enabled flag
  - codec
  - frame size (width/height)
  - fps
  - bitrate
  - plus several mandatory static defaults (rcMode/profile/gop, etc.)
  - if Majestic has crop configured, it is forcibly reset to an empty value

- `cameraConfig.jpeg` → Majestic `.jpeg.*`
  - enabled
  - size
  - qfactor
  - fps
  - and RTSP for JPEG is forcibly disabled (required value)

- `cameraConfig.audio` → Majestic `.audio.*`
  - volume
  - srate
  - codec

Application logic:

- read the current value via `cli -g`
- compare with the desired value
- if different, write via `cli -s` (or `cli -d` to delete/clear a value)
- if at least one parameter changed, mark “restart required”

After all three groups are applied, if “restart required” is set, we restart Majestic.

Key point: we do not restart Majestic “just in case” — only if we detected differences and wrote new values.

## Runtime intervention (during operation, via external commands)

There are two control commands that modify Majestic “on the fly” and always lead to a restart:

### Microphone

- read `.audio.enabled`, `.audio.volume`
- when setting: write `.audio.enabled` and `.audio.volume`
- then restart Majestic to ensure changes are applied

### Mirror/Flip (image orientation)

- read `.image.mirror` and `.image.flip`
- when setting: write these keys
- then restart Majestic

## Special case: Mirror/Flip only on first boot (without an explicit restart)

There is “first boot” logic: if the agent sees that its config/state has not been created yet, it treats this as first boot and then:

- reads env variables `faceter_image_flip` and `faceter_image_mirror`
- writes them into Majestic (`.image.flip/.image.mirror`)

There is no explicit Majestic restart afterward, so the moment when the change takes effect depends on Majestic behavior.

## What we do NOT do (boundaries)

- We do not edit `/etc/majestic.yaml` directly in the agent code.
- We do not send signals to the Majestic process (like HUP) — only init-script start/restart.
- Night mode is switched via a separate service (`dn-monitor`) (related to the image pipeline, but not Majestic itself).

## “Passive” usage of Majestic as a video/image source

- Snapshots are fetched over HTTP from local `/image.jpg`.
- The detector may consume MJPEG from local `/mjpeg`.
- RTSP/MJPEG URLs are configured in `faceter-agent.conf` — that is not a Majestic change, but configuration of where we connect.


