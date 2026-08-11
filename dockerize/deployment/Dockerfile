# Build Flutter web app. The output (js/wasm/assets) is target-independent,
# so pin this stage to the build host's platform: multi-arch builds run the
# Flutter toolchain once, natively, instead of again under QEMU emulation.
FROM --platform=$BUILDPLATFORM debian:stable-slim AS flutter-build

RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Keep in lockstep with dockerize/development/flutter/Dockerfile.
ARG FLUTTER_VERSION=3.35.4
RUN git clone https://github.com/flutter/flutter.git /flutter --depth 1 --branch ${FLUTTER_VERSION}
ENV PATH="/flutter/bin:/flutter/bin/cache/dart-sdk/bin:${PATH}"

RUN flutter doctor -v
RUN flutter config --enable-web

WORKDIR /app

COPY src/packages/flutter-app/pubspec.yaml src/packages/flutter-app/pubspec.lock ./
RUN flutter pub get

COPY src/packages/flutter-app/lib/ lib/
COPY src/packages/flutter-app/web/ web/
COPY src/packages/flutter-app/assets/ assets/
COPY src/packages/flutter-app/tool/ tool/
COPY src/packages/flutter-app/analysis_options.yaml ./

RUN mkdir -p web/icons
RUN dart run build_runner build --delete-conflicting-outputs

# --web-renderer was removed in Flutter 3.32+ (canvaskit is the default).
RUN flutter build web --release \
    --base-href /app/ \
    --dart-define=API_BASE_URL=/api/v1 \
    --dart-define=APP_BASE_PATH=/app/

# Strip flutter_math_fork's 16 KaTeX font families (~597 KB, downloaded
# before first frame) from the shipped bundle: the app excludes gpt_markdown's
# LaTeX components (chat_panel.dart), so the fonts are unreachable. Guard
# rails are deliberate — fail the build loudly rather than ship silent bloat:
# the grep asserts the entries exist BEFORE stripping (if gpt_markdown's
# layout changes, this goes red instead of quietly doing nothing), the tool
# itself exits non-zero on any surprise, and the final greps assert the
# post-state (no KaTeX left in manifest or on disk).
RUN grep -q 'packages/flutter_math_fork/' build/web/assets/FontManifest.json \
    && dart run tool/strip_katex_fonts.dart build/web \
    && ! grep -q 'flutter_math_fork' build/web/assets/FontManifest.json \
    && [ ! -d build/web/assets/packages/flutter_math_fork ]

# Release identifier for the web build, mirroring the api image's
# SENTRY_RELEASE: CI passes the git SHA so /app/version.json answers
# "which commit is this frontend?" (the deploy job verifies it). Flutter
# already emits version.json (app_name/version/build_number) and nginx
# already serves it no-cache — inject a release field into it rather than
# clobbering, and fail the build if the injection missed.
ARG GIT_SHA=
RUN sed -i 's/}[[:space:]]*$/,"release":"'"${GIT_SHA}"'"}/' build/web/version.json \
    && grep -q '"release"' build/web/version.json

# Flutter's stock service worker computes cache keys as
# `url.substring(origin.length + 1)` — but with `--base-href /app/` the
# cached request URLs are `<origin>/app/main.dart.js` while RESOURCES keys
# are bare (`main.dart.js`), so `RESOURCES[key]` never matches: the cache
# is populated on install but never READ, and every load re-fetches from
# the network. Strip the 4-char `app/` prefix too (+1 -> +5) at all three
# key-computation sites. Guarded to fail the build loudly if Flutter ever
# changes the service-worker layout: at least one replacement must have
# happened and none of the old pattern may remain.
RUN sed -i 's/origin\.length + 1/origin.length + 5/g' build/web/flutter_service_worker.js \
    && grep -q 'origin.length + 5' build/web/flutter_service_worker.js \
    && ! grep -q 'origin\.length + 1' build/web/flutter_service_worker.js

# Serve static files and proxy API via nginx
FROM nginx:alpine

# default.conf is the local :80 server shell; the production stack
# volume-mounts dockerize/production/nginx/prod.conf over it. The shared
# location snippet and the http-scope $share_prerender map are baked in
# separately so both shells can include/rely on them.
COPY dockerize/deployment/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY dockerize/deployment/nginx/share-prerender-map.conf /etc/nginx/conf.d/share-prerender-map.conf
COPY dockerize/deployment/nginx/perf.conf /etc/nginx/conf.d/perf.conf
COPY dockerize/deployment/nginx/snippets/ /etc/nginx/snippets/
COPY dockerize/static /usr/share/nginx/html/static
COPY --from=flutter-build /app/build/web /usr/share/nginx/html/app

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
