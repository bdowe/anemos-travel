FROM debian:stable-slim

RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG FLUTTER_VERSION=3.35.4
RUN git clone https://github.com/flutter/flutter.git /flutter --depth 1 --branch ${FLUTTER_VERSION}
ENV PATH="/flutter/bin:/flutter/bin/cache/dart-sdk/bin:${PATH}"

# Keep in lockstep with dockerize/deployment/Dockerfile's flutter-build
# stage: web-only precache instead of `flutter doctor -v`, which pulled
# every platform's engine artifacts (~900 MB this image never uses).
RUN flutter --version \
    && flutter --disable-analytics \
    && flutter config --enable-web \
        --no-enable-android --no-enable-ios \
        --no-enable-linux-desktop --no-enable-macos-desktop --no-enable-windows-desktop \
    && flutter precache --web \
    && [ -d /flutter/bin/cache/flutter_web_sdk ]

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
