# Sunshine for NVIDIA Jetson

This project adds NVIDIA Jetson hardware H.264 and HEVC encoding to Sunshine.
It uses `libnvmpi` to bridge FFmpeg to Jetson's Multimedia API and adds a
Jetson-specific encoder descriptor to Sunshine.

Desktop NVIDIA NVENC is not the same API. Jetson exposes its encoder through
`/dev/v4l2-nvenc`, while unmodified Sunshine tries `h264_nvenc` and requires a
desktop driver implementing the NVENC SDK.

## Tested Platform

- Seeed Studio NVIDIA Jetson AGX Orin 32GB H01
- JetPack 7.2.1-b49
- Jetson Linux 39.2.1
- Ubuntu 24.04 ARM64
- Kernel 6.8.12-1021-tegra
- Sunshine v2026.516.143833 (`14ffa6fdaa53f7b51512be2b3d24f3939695403c`)
- jetson-ffmpeg/libnvmpi v3.10.0 (`8d70c17efeee57f4d956df500fec78a73f8c27d4`)
- FFmpeg dependency commit `fb216b5facde2c97cb0ce2e75fb3228aa5ac21fa`

Other JetPack releases may require different Multimedia API compatibility
changes. The build script intentionally refuses non-ARM64 systems and systems
without `/dev/v4l2-nvenc`.

## Supported Codecs

| Codec | Status |
| --- | --- |
| H.264 High, 8-bit | Working |
| HEVC Main, 8-bit | Working |
| HEVC Main10, 10-bit | Not supported |
| AV1 | Not supported by nvmpi |

The HEVC Main10 capability is deliberately not advertised. Sunshine's encoder
probe will attempt 10-bit HEVC and log an error, then retain working 8-bit HEVC.
Errors between Sunshine's "Testing for available encoders" markers are expected.

## Prerequisites

The Jetson Multimedia API must exist at `/usr/src/jetson_multimedia_api`.
Sunshine also needs working display capture and input permissions. For JetPack
7's missing stock `uinput` module, see
[jetson-uinput-module](https://github.com/ThatOneGuyGreggers/jetson-uinput-module).

Install build dependencies:

```bash
sudo apt update
sudo apt install -y \
  build-essential cmake curl git make ninja-build pkg-config xz-utils \
  python3 python3-jinja2 python3-setuptools \
  libcap-dev libcurl4-openssl-dev libdrm-dev libevdev-dev \
  libglib2.0-dev libicu-dev libminiupnpc-dev libnuma-dev libopus-dev \
  libpulse-dev libssl-dev libsystemd-dev libudev-dev libva-dev \
  libx11-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
  libxfixes-dev libxrandr-dev libxtst-dev systemd udev
```

Node.js 20 or newer is required for Sunshine's web UI. If the system Node.js is
older, the build script downloads an isolated Node.js 22 ARM64 archive into the
build directory.

## Build

```bash
git clone https://github.com/ThatOneGuyGreggers/sunshine-jetson.git
cd sunshine-jetson
./scripts/build.sh
./scripts/probe.sh
```

`build.sh` pins and verifies every upstream revision. It builds:

1. An encoder-only `libnvmpi` compatible with JetPack 7.
2. Sunshine's static FFmpeg dependency with `h264_nvmpi` and `hevc_nvmpi`.
3. The exact tested Sunshine release with the `jetson` encoder backend.

The build explicitly embeds the upstream release version and commit. Without
that metadata, upstream's CMake version detection can pick up this wrapper
repository's revision and report the wrong version in Sunshine's admin page.
Sunshine's admin page checks GitHub for newer releases independently; this
repository is pinned to `v2026.516.143833`, not automatically updated to the
newest upstream release.

The default workspace is `./build`. Set `WORK_DIR` and `JOBS` to override it:

```bash
WORK_DIR=/var/tmp/sunshine-jetson JOBS=8 ./scripts/build.sh
```

## Install

Run the hardware probe before replacing the packaged Sunshine binary:

```bash
./scripts/probe.sh
./scripts/install.sh
```

The installer places `libnvmpi` under `/usr/local`, installs Sunshine under
`/usr`, applies its capture capabilities, reloads udev, and restarts the user
service. If `/usr/bin/sunshine.pre-jetson` does not exist, it preserves the
current Sunshine binary there first.

Select `jetson` in Sunshine's encoder setting, or leave the encoder on automatic
selection. On ARM64, the patch tests `jetson` before desktop NVENC.

## Verify

Successful startup contains:

```text
Trying encoder [jetson]
Creating encoder [h264_nvmpi]
Creating encoder [hevc_nvmpi]
Found H.264 encoder: h264_nvmpi [jetson]
Found HEVC encoder: hevc_nvmpi [jetson]
```

The hardware driver also prints `NvVideo: NVENC` while opening each encoder.

## H.264 instead of HEVC (H.265)

The stock Sunshine package reports the same `2026.516.143833` version but does
not include the Jetson encoder patch. A version number alone does not confirm
that Jetson HEVC is available. Run `./scripts/probe.sh` and check for both
`Found HEVC encoder: hevc_nvmpi [jetson]` and the expected release version.
After installation, restart the user service and check its startup log for the
same encoder lines. HEVC Main is 8-bit only; do not request HEVC Main10/HDR.

In Sunshine's Configuration > Audio/Video, leave HEVC Support enabled (the
default) and use `jetson` or automatic for the encoder. In Moonlight, enable
HEVC/H.265 or set the video codec to HEVC, then start a new stream. The client
must support HEVC decoding; Moonlight's statistics overlay shows the codec
*actually negotiated*. An H.264-only client or a client configured to prefer
H.264 will continue to use H.264 even when the host has HEVC available.

## Intermittent “slow connection” warnings

Moonlight raises this warning based on stream delivery (latency, jitter or
lost packets), not solely on the codec. If the host's uplink is also Wi-Fi,
find its interface with `iw dev` and check its power saving mode with
`iw dev <interface> get power_save`. Good signal or a high negotiated Wi-Fi link
rate does not rule out short bursts of contention or retransmissions. For a
useful comparison, connect the Jetson by Ethernet and stream from the same
client, or test with the client close to the access point. If Wi-Fi must be
used, try disabling host Wi-Fi power saving temporarily with
`sudo iw dev <interface> set power_save off` and compare sessions. To retain
that setting for a NetworkManager connection, use
`sudo nmcli connection modify '<connection name>' 802-11-wireless.powersave 2`
followed by a reconnection (which interrupts active streams). Check
`iw dev <interface> link` for signal and transmit rate.

Enable Moonlight's statistics overlay and compare *network dropped frames*,
average/maximum network latency and host processing time when the warning
occurs. If network drops rise, test a lower Moonlight bitrate and resolution,
and ensure Moonlight is connecting to the Jetson's LAN address rather than a
VPN/relay. If host processing time rises without network drops, inspect
Sunshine's log and encoder load instead. Changing to HEVC may lower bandwidth
at the same quality, but does not fix Wi-Fi loss or jitter.

If Moonlight requests an unusually high bitrate (for example, 120 Mbps on
1080p over Wi-Fi), reduce the bitrate in Moonlight or set
`max_bitrate = 30000` in Sunshine's config to cap video encoding at 30 Mbps.
Restart Sunshine and start a new stream to apply the setting.

## HEVC stuck near 2 FPS

Older revisions of this patch set blocked up to 500 ms waiting for an extra
HEVC packet after *each* frame. The FFmpeg patch now returns promptly when no
packet is ready, allowing Sunshine's capture loop to maintain its target FPS.
Rebuild and reinstall from this repository, then start a new Moonlight stream
and verify its incoming FPS. An encoder availability probe alone cannot detect
this runtime throughput issue.

## Rollback

Restore the preserved binary and restart Sunshine:

```bash
systemctl --user stop app-dev.lizardbyte.app.Sunshine.service
sudo cp /usr/bin/sunshine.pre-jetson /usr/bin/sunshine
systemctl --user start app-dev.lizardbyte.app.Sunshine.service
```

For a complete package-owned restoration, reinstall the Sunshine package that
was used before this patch. The installer does not delete user configuration or
pairing state.

## Upstream Projects

- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
- [gjrtimmer/jetson-ffmpeg](https://github.com/gjrtimmer/jetson-ffmpeg)
- [FFmpeg](https://ffmpeg.org/)

Their source and redistributed components remain under their respective
licenses. This repository's original scripts and documentation are MIT
licensed; patches derived from upstream source remain under the corresponding
upstream project's license. See [AI_DISCLOSURE.md](AI_DISCLOSURE.md) for the
development disclosure.
