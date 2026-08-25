#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build}"
JOBS="${JOBS:-$(nproc)}"

SUNSHINE_TAG="v2026.516.143833"
SUNSHINE_COMMIT="14ffa6fdaa53f7b51512be2b3d24f3939695403c"
BUILD_DEPS_COMMIT="fce763bb09c73b5952ccdcbc90efb8ba8f53a7de"
FFMPEG_COMMIT="fb216b5facde2c97cb0ce2e75fb3228aa5ac21fa"
NVMPI_TAG="v3.10.0"
NVMPI_COMMIT="8d70c17efeee57f4d956df500fec78a73f8c27d4"
NODE_VERSION="22.12.0"

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "This build supports ARM64 Jetson systems only." >&2; exit 1 ;;
esac

if [[ ! -e /dev/v4l2-nvenc ]]; then
  echo "Missing /dev/v4l2-nvenc; this system does not expose the Jetson encoder." >&2
  exit 1
fi

if [[ ! -d /usr/src/jetson_multimedia_api ]]; then
  echo "Missing /usr/src/jetson_multimedia_api; install the Jetson Multimedia API." >&2
  exit 1
fi

mkdir -p "${WORK_DIR}"

node_major=0
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
fi
if (( node_major < 20 )); then
  node_root="${WORK_DIR}/node-v${NODE_VERSION}-linux-arm64"
  archive="${WORK_DIR}/node-v${NODE_VERSION}-linux-arm64.tar.xz"
  if [[ ! -x "${node_root}/bin/node" ]]; then
    curl -fL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz" -o "${archive}"
    tar -xf "${archive}" -C "${WORK_DIR}"
  fi
  export PATH="${node_root}/bin:${PATH}"
fi

nvmpi_src="${WORK_DIR}/jetson-ffmpeg"
sunshine_src="${WORK_DIR}/sunshine"

if [[ ! -d "${nvmpi_src}/.git" ]]; then
  git clone --filter=blob:none --branch "${NVMPI_TAG}" https://github.com/gjrtimmer/jetson-ffmpeg.git "${nvmpi_src}"
fi
git -C "${nvmpi_src}" checkout --detach "${NVMPI_COMMIT}"
git -C "${nvmpi_src}" reset --hard "${NVMPI_COMMIT}"
git -C "${nvmpi_src}" clean -fdx
git -C "${nvmpi_src}" apply "${ROOT_DIR}/patches/nvmpi-jetpack7-encoder-only.patch"

cmake -S "${nvmpi_src}" -B "${WORK_DIR}/nvmpi-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build "${WORK_DIR}/nvmpi-build" --parallel "${JOBS}"

if [[ ! -d "${sunshine_src}/.git" ]]; then
  git clone --filter=blob:none --branch "${SUNSHINE_TAG}" --recursive https://github.com/LizardByte/Sunshine.git "${sunshine_src}"
fi
git -C "${sunshine_src}" checkout --detach "${SUNSHINE_COMMIT}"
git -C "${sunshine_src}" reset --hard "${SUNSHINE_COMMIT}"
git -C "${sunshine_src}" clean -fdx
git -C "${sunshine_src}" submodule update --init --recursive --force

actual_build_deps="$(git -C "${sunshine_src}/third-party/build-deps" rev-parse HEAD)"
actual_ffmpeg="$(git -C "${sunshine_src}/third-party/build-deps/third-party/FFmpeg/FFmpeg" rev-parse HEAD)"
if [[ "${actual_build_deps}" != "${BUILD_DEPS_COMMIT}" || "${actual_ffmpeg}" != "${FFMPEG_COMMIT}" ]]; then
  echo "Sunshine dependency revisions differ from the tested release." >&2
  exit 1
fi

git -C "${sunshine_src}" apply "${ROOT_DIR}/patches/sunshine-jetson-encoder.patch"
git -C "${sunshine_src}/third-party/build-deps" apply "${ROOT_DIR}/patches/sunshine-build-deps-nvmpi.patch"
ffmpeg_src="${sunshine_src}/third-party/build-deps/third-party/FFmpeg/FFmpeg"
git -C "${ffmpeg_src}" apply "${nvmpi_src}/ffmpeg/patches/ffmpeg8.1_nvmpi.patch"
git -C "${ffmpeg_src}" apply "${ROOT_DIR}/patches/ffmpeg-encoder-only.patch"

deps_build="${WORK_DIR}/build-deps"
cmake -S "${sunshine_src}/third-party/build-deps" -B "${deps_build}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${deps_build}/dist" \
  -DPARALLEL_BUILDS="${JOBS}" \
  -DBUILD_ALL=OFF \
  -DBUILD_ALL_LIBDISPLAYDEVICE=OFF \
  -DBUILD_ALL_SUNSHINE=OFF \
  -DBUILD_BOOST=OFF \
  -DBUILD_FFMPEG=ON \
  -DBUILD_FFMPEG_AMF=OFF \
  -DBUILD_FFMPEG_MF=OFF \
  -DBUILD_FFMPEG_NV_CODEC_HEADERS=OFF \
  -DBUILD_FFMPEG_SVT_AV1=OFF \
  -DBUILD_FFMPEG_LIBVA=OFF \
  -DBUILD_FFMPEG_VULKAN=OFF \
  -DBUILD_FFMPEG_X264=OFF \
  -DBUILD_FFMPEG_X265=OFF
cmake --build "${deps_build}" --target build-deps --parallel "${JOBS}"
cmake --install "${deps_build}"

sunshine_build="${WORK_DIR}/sunshine-build"
cmake -S "${sunshine_src}" -B "${sunshine_build}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DFFMPEG_PREPARED_BINARIES="${deps_build}/dist/ffmpeg" \
  -DSUNSHINE_ASSETS_DIR=share/sunshine \
  -DSUNSHINE_EXECUTABLE_PATH=/usr/bin/sunshine \
  -DBUILD_DOCS=OFF \
  -DBUILD_TESTS=OFF \
  -DSUNSHINE_ENABLE_CUDA=OFF \
  -DSUNSHINE_ENABLE_DRM=ON \
  -DSUNSHINE_ENABLE_KWIN=OFF \
  -DSUNSHINE_ENABLE_PORTAL=OFF \
  -DSUNSHINE_ENABLE_TRAY=OFF \
  -DSUNSHINE_ENABLE_VAAPI=OFF \
  -DSUNSHINE_ENABLE_VULKAN=OFF \
  -DSUNSHINE_ENABLE_WAYLAND=OFF \
  -DSUNSHINE_ENABLE_X11=ON
cmake --build "${sunshine_build}" --parallel "${JOBS}"

echo "Build complete: ${sunshine_build}/sunshine"
echo "Run scripts/probe.sh before installing."
