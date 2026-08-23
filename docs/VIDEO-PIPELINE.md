# Accelerated Video Pipeline — Design

Status: **phases 1-3 shipped** — end-to-end encoded video verified live: dbus capture → ffmpeg h264_vaapi on the host GPU → /ws/video → WebCodecs decode → overlay canvas painting the guest boot screen. Phase 4 (polish) partial: frame pacing + bitrate setting + e2e shipped; cursor channel, multi-client fan-out, AV1, and virgl/dmabuf capture remain.
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

### Daemon-side encoder
> Shipped differently than sketched here: there is no `videoenc.zig` — capture,
> session lifecycle, and the encoder all live in `dbusdisplay.zig`, and encoding
> is an **ffmpeg child**, not in-process EGL/VAAPI (see phase 2 below). The
> original in-process design is kept for reference.
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

## Spike results (verified on the reference host, QEMU 11.0)

- `-display dbus,p2p=yes` boots; clients attach by passing one end of a
  socketpair via QMP `add_client` (the daemon already speaks QMP — no bus
  broker needed).
- **GL exclusivity**: `dbus,gl=on` cannot coexist with `-vnc` ("Display vnc is
  incompatible with the GL context"). So with virgl + video streaming, the
  dbus display owns the console: input goes through the
  `org.qemu.Display1.Keyboard/Mouse` D-Bus interfaces and there is no live VNC
  fallback (fallback = power-cycle back to the VNC arg set).
- Non-GL `dbus,p2p=yes` **does** coexist with `-vnc` (scanouts arrive as
  memfd/shared-memory instead of dmabuf): phase 1 can ship capture + encode
  for non-3D VMs with the VNC console untouched as fallback, deferring the
  D-Bus input work to the virgl phase.

## Phases
1. **Capture** — shipped (`dbusdisplay.zig`): per-VM `video_stream` flag adds
   `-display dbus,p2p=yes` (non-virgl embedded VMs; coexists with the VNC
   console — verified live side-by-side), the daemon attaches via QMP
   `getfd`+`add_client` SCM_RIGHTS, hand-rolled D-Bus auth + marshal/parse,
   registers a Listener and serves it (METHOD_RETURN replies, passed fds
   closed), logging frame cadence. Live: 37–67 fps of Scanout/Update traffic
   during firmware boot. Auth-role gotcha for phase 2: on the listener
   connection QEMU is the AUTH **server** — the daemon must speak
   `\0AUTH EXTERNAL` first even though QEMU is the method-caller afterwards.
2. **Encoder** — shipped. Implementation note: instead of in-process libva
   (hundreds of lines of hand-declared VAAPI structs + bitstream packing), the
   encoder is an **ffmpeg child** (`h264_vaapi` when /dev/dri/renderD128 is
   openable, `libx264 -tune zerolatency` otherwise) fed raw BGRX frames on
   stdin — the same subprocess pattern as qemu-img, via qemu.forkExecPiped.
   The session assembles Scanout/Update bodies into a heap framebuffer and
   pushes full frames; an Annex-B access-unit splitter (unit+fuzz tested)
   chunks the output, `-bsf:v dump_extra=freq=keyframe` repeats SPS/PPS so any
   key frame is a valid decoder entry point. Native libva remains a future
   optimization, not a requirement.
3. **Client** — shipped: /ws/video frames (0x01 config w/h/codec, 0x02 delta,
   0x03 key) feed a VideoDecoder (`avc1.42E01F`, optimizeForLatency); decoded
   frames draw onto a pointer-events:none overlay canvas above the noVNC layer
   (input keeps flowing to VNC), badge `H264 · WEBCODECS`. Silently absent
   without VideoDecoder or video_stream. Verified live: overlay painting the
   guest's iPXE boot screen via hardware encode at 70 fps capture cadence.
4. **Polish** (partial): frame pacing shipped — pushes coalesce to ~30 fps
   with trailing-frame flush (unpaced damage bursts shoved ~80MB/s of redundant
   full frames into ffmpeg). `video_bitrate_kbps` shipped (persisted; Settings
   field; -b:v/-maxrate; 0 = auto 4000k). Hardening from live debugging:
   Sessions are refcounted (power-off mid-stream destroyed the Session under
   the video client's feet — observed use-after-free panic), the attach thread
   retries the handshake up to 6× (QMP/display not up at +900ms under load),
   serveVideoClient waits up to 8s for the session (a client connecting right
   at the running flip beat the attach), and the browser retries an
   early-closed stream while the VM runs. e2e: video test asserts decoded
   pixel content on the overlay. Remaining: cursor channel, multi-client
   fan-out, AV1, virgl/dmabuf zero-copy capture.

## Risks
- D-Bus protocol hand-rolling is the long pole; sd-bus extern fallback noted.
- VAAPI device permissions: daemon must reach `/dev/dri/renderD*` (reference
  host: world-rw; document the `render` group requirement).
- WebCodecs H.264 absent on some Linux Chromium builds without proprietary
  codecs → capability gate above covers it; AV1 fallback helps long-term.
- Multi-client: phase 2 serves the encoded stream to N clients (one encoder,
  fan-out writes); per-client bitrate adaptation is out of scope.
