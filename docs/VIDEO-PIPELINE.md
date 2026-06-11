# Accelerated Video Pipeline — Design

Status: **proposed** (foundation shipped; encoder subsystem not started).
Goal: stream the guest's GPU-rendered display to the browser as **encoded
video** (H.264/AV1) decoded by **WebCodecs** and presented on the **WebGPU**
canvas — Moonlight/Parsec-class console latency and quality, replacing
framebuffer tiles for high-motion content.

## Where we are today (shipped, verified)

```
guest 3D → virtio-vga-gl → virgl → host EGL render (egl-headless)
        → QEMU VNC/SPICE server scrapes scanout → raw/zlib tiles
        → /ws/vnc | /ws/spice relay → noVNC / spice-html5 decode (CPU)
        → WebGPU presenter (WebGL2 fallback) blits to canvas
```

Both ends are GPU-accelerated (host virgl render, browser composite); the
transport is unencoded pixels. Fine for consoles/installs; caps out well below
30 fps at 1080p for video-like content and burns relay + browser CPU.

## Target architecture

```
guest 3D → virtio-vga-gl → virgl
        → QEMU -display dbus,gl=on  ──(P2P D-Bus, dmabuf fd per frame)──▶
   hangar-web encoder thread:
        EGL import dmabuf → VAAPI (radeonsi) H.264 low-latency encode
        → fragmented bitstream chunks
        → /ws/video/<id> (binary WS: one config frame, then chunk frames)
   browser:
        WebSocket → WebCodecs VideoDecoder (hardware)
        → VideoFrame → existing WebGPU presenter (copyExternalImageToTexture)
   input: unchanged (noVNC/QMP path keeps keyboard/mouse; video WS is one-way)
```

### Why `-display dbus`
QEMU's dbus display exists precisely for external UIs (GNOME Boxes uses it):
QEMU exports `org.qemu.Display1` on a private P2P D-Bus socket and pushes
**dmabuf file descriptors per scanout update** plus damage rectangles, cursor
state, and input interfaces. No scraping, no copies until the encoder, and it
coexists with `-vnc`/`-spice` (fallback console stays).

Alternatives rejected:
- QMP `screendump` loop — PNG round-trip per frame; slow, disk-touching.
- spice `gl=on` remote — requires GStreamer-enabled spice-server (distro
  builds lack it; fatal "invalid video codec"), and spice-html5 can't do its
  video channels anyway.
- KMS/DRM lease of the virtual scanout — host-config heavy, root-only.

### Daemon-side encoder (new module `videoenc.zig` + `dbusdisplay.zig`)
- P2P D-Bus client (hand-rolled like our QMP client — the wire protocol is
  simple framing; **no** libdbus/glib per project constraints, or `sd-bus` via
  explicit extern decls if hand-rolling proves unreasonable).
- EGL: import dmabuf as `EGLImage` (extern decls against libEGL, mirroring the
  `spice_client.zig` no-@cImport pattern).
- VAAPI low-latency H.264: `CBR/CQP`, GOP = ∞ with forced IDR on (a) client
  join, (b) damage after idle, (c) resolution change; zero B-frames;
  `radeonsi_drv_video.so` verified present on the reference host.
- One encoder per VM with attached video clients; torn down on last detach.
  Threading mirrors the WS relay pattern (thread per session, SpinMutex on
  writes). Budget: 1080p60 H.264 on RDNA3 VCN ≈ negligible GPU, ~0 CPU.

### Wire protocol (`/ws/video/<idx>`, binary frames)
| frame | layout |
| --- | --- |
| `0x01` config | u16 width, u16 height, u8 codec (0=h264,1=av1), codec extradata |
| `0x02` chunk | u8 flags (bit0 = key), u64 pts_us, payload (Annex-B AU) |
| `0x03` cursor | x,y,hot_x,hot_y,w,h + RGBA (optional phase 2) |
Auth/handshake identical to the other WS routes (subprotocol echoed).

### Browser side (app.js, no framework needed)
- `VideoDecoder` with `{codec:'avc1.42E01E', optimizeForLatency:true,
  hardwareAcceleration:'prefer-hardware'}`; feed `EncodedVideoChunk`s.
- Decoded `VideoFrame` → existing presenter: WebGPU
  `copyExternalImageToTexture(frame)` (zero-copy where the platform allows),
  WebGL2 `texImage2D(frame)` fallback; `frame.close()` after upload.
- Renderer badge becomes `H264 · WEBGPU`.
- Capability gate: `'VideoDecoder' in window` AND the daemon advertises the
  encoder in `/api/capabilities` — otherwise the console silently stays on the
  current noVNC/spice path. The video path is an *upgrade*, never a
  requirement.

## Phases
1. **Spike**: `-display dbus` alongside `-vnc`; daemon connects, logs frame
   cadence + dmabuf metadata. Proves the capture half with zero UI change.
2. **Encoder**: EGL import + VAAPI H.264 + `/ws/video` route; gate behind a
   per-VM `video_stream` bool (persisted like other VmConfig fields).
3. **Client**: WebCodecs decode + presenter integration + badge + capability
   gating; e2e asserts decoder receives a key frame and the canvas sizes.
4. **Polish**: damage-aware encode skip on idle, cursor channel, AV1 on hosts
   that expose it, bitrate preference in Settings → Display & Video.

## Risks
- D-Bus protocol hand-rolling is the long pole; sd-bus extern fallback noted.
- VAAPI device permissions: daemon must reach `/dev/dri/renderD*` (reference
  host: world-rw; document the `render` group requirement).
- WebCodecs H.264 absent on some Linux Chromium builds without proprietary
  codecs → capability gate above covers it; AV1 fallback helps long-term.
- Multi-client: phase 2 serves the encoded stream to N clients (one encoder,
  fan-out writes); per-client bitrate adaptation is out of scope.
