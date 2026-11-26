FROM --platform=linux/arm64 swift:6.4.3-noble@sha256:4ed5e0210b244aab174450e0b79014c17db60c63c6daf0709347fe50c767293a

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config ca-certificates curl git python3 time \
    libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev \
    libsecret-1-dev zlib1g-dev weston dbus dbus-daemon \
    fonts-dejavu-core libgl1-mesa-dri \
 && rm -rf /var/lib/apt/lists/*

ARG PDFIUM_TAG=chromium/8179
ARG PDFIUM_SHA256=18bb6d568257b28d14f6c3b8bfb48caf73d4615b319ca4d43b424c2a03431d9f
RUN set -eu; \
    curl -fL --retry 3 \
      "https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_TAG}/pdfium-linux-arm64.tgz" \
      -o /tmp/pdfium.tgz; \
    echo "${PDFIUM_SHA256}  /tmp/pdfium.tgz" | sha256sum -c -; \
    mkdir -p /opt/pdfium /usr/local/lib/pkgconfig; \
    tar -xzf /tmp/pdfium.tgz -C /opt/pdfium; \
    rm /tmp/pdfium.tgz; \
    test -r /opt/pdfium/include/fpdfview.h; \
    test -r /opt/pdfium/lib/libpdfium.so; \
    printf '%s\n' 'prefix=/opt/pdfium' 'libdir=${prefix}/lib' \
      'includedir=${prefix}/include' 'Name: pdfium' \
      'Description: pinned PDFium C API' 'Version: 8179' \
      'Libs: -L${libdir} -lpdfium' 'Cflags: -I${includedir}' \
      > /usr/local/lib/pkgconfig/pdfium.pc; \
    echo /opt/pdfium/lib > /etc/ld.so.conf.d/pdfium.conf; \
    ldconfig; \
    pkg-config --exists gtk4 libadwaita-1 webkitgtk-6.0 libsecret-1 zlib pdfium

RUN useradd -m -u 20001 -s /bin/bash reader \
 && install -d -o reader -g reader /work /build
USER reader
WORKDIR /work
CMD ["/bin/bash"]
