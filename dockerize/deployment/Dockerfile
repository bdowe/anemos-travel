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

# Bootstrap the Dart SDK (`--version` is the cheapest trigger and logs the
# toolchain), disable analytics, then fetch ONLY web artifacts: the previous
# `flutter doctor -v` precached every platform's engine (~900 MB this stage
# never used). The --no-enable-* config stops later commands (pub get, build
# web) from lazily pulling other platforms back in. Guard rail: assert the
# web SDK actually landed, so a Flutter upgrade that changes precache layout
# fails the build loudly instead of silently re-downloading at build time.
RUN flutter --version \
    && flutter --disable-analytics \
    && flutter config --enable-web \
        --no-enable-android --no-enable-ios \
        --no-enable-linux-desktop --no-enable-macos-desktop --no-enable-windows-desktop \
    && flutter precache --web \
    && [ -d /flutter/bin/cache/flutter_web_sdk ]

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

# One-time content-cache eviction for clients poisoned while nginx still served
# /app/assets/ as `immutable` (see app-locations.conf). activate() only drops a
# cached entry when its RESOURCES md5 differs between the OLD and NEW manifest,
# so once a client stored stale bytes under the CURRENT hash, nothing will ever
# evict them: the hash is already "right". Renaming the manifest cache makes
# activate() take its no-prior-manifest branch, which opens with
# `caches.delete(CACHE_NAME)` — Flutter's own first-install path — nuking the
# poisoned content cache exactly once per bump. Renaming CACHE_NAME instead
# would orphan that whole multi-MB cache in storage forever; this leaks only
# the ~4 KB old manifest cache. Idempotent on later deploys: the manifest
# exists under the new name, so the normal diff path resumes.
#
# A BUMP IS ONLY VALID ONCE THE EDGE IS VERIFIED CLEAN. It fires exactly once
# per client and cannot be re-fired, so it spends its single shot refilling the
# cache from whatever the CDN is serving at that moment. v2 shipped with #426
# while Cloudflare still held the pre-#419 icon font under a one-year TTL —
# correcting the header here did not evict it, because a stored object keeps
# the freshness lifetime it was stored with. So v2 wiped every client's content
# cache and refilled it from the stale edge: users who had been fine were healed
# into breakage, and the one-shot lever was spent. v3 is the replacement shot,
# fired after the purge. Before ever bumping again: purge the CDN, run
# scripts/verify-edge-parity.sh until it passes, and only then raise the suffix.
RUN sed -i "s/'flutter-app-manifest'/'flutter-app-manifest-v3'/" build/web/flutter_service_worker.js \
    && grep -q "const MANIFEST = 'flutter-app-manifest-v3';" build/web/flutter_service_worker.js \
    && ! grep -q "'flutter-app-manifest'" build/web/flutter_service_worker.js

# Send every service-worker cache MISS to the network instead of to the
# browser's HTTP cache. The stock fetch handler falls back to a default-mode
# `fetch(event.request)`, which the HTTP cache answers — and a client that
# stored an asset while the header still said `max-age=31536000, immutable`
# keeps that copy for a YEAR whatever the origin sends afterwards, because a
# stored response's freshness lifetime is fixed at store time and the client
# never revalidates, so it never learns the new header. `reload` bypasses that
# entry AND overwrites it with the network response, healing the poisoned
# HTTP-cache entry on the same request; `no-cache` mode would not, since a
# stale ETag can still earn a 304.
#
# Only the cache-miss site is patched, NOT onlineFirst()'s twin: that one
# serves the navigation request, and passing any init coerces a navigate-mode
# Request to same-origin, changing redirect handling for no benefit
# (index.html is uncached at the edge and already revalidates). downloadOffline()
# is deliberately left alone too — nothing posts it that message, so it is dead
# code in this app.
#
# This does NOT bypass Cloudflare, which ignores client Cache-Control/Pragma
# request headers — which is why the fix shipped alongside an edge purge.
RUN sed -i 's/return response || fetch(event\.request)/return response || fetch(event.request, {cache: "reload"})/' build/web/flutter_service_worker.js \
    && grep -q 'fetch(event.request, {cache: "reload"})' build/web/flutter_service_worker.js \
    && ! grep -q 'return response || fetch(event\.request)\.' build/web/flutter_service_worker.js

# Serve static files and proxy API via nginx. alpine-slim is the base the
# stock nginx:alpine image is built FROM by adding a ~50 MB dynamic-module
# layer (xslt, geoip, image-filter, njs, acme) that no config here loads —
# verified zero load_module/xslt/njs/geoip/image_filter references across
# dockerize/*/nginx/. busybox wget (healthchecks) and the envsubst
# entrypoint are both retained in -slim. Minor-version pinned: 1.31.x is
# what production already runs; bumps are explicit, reviewable edits.
FROM nginx:1.31-alpine-slim

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
