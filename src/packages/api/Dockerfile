# Build stage — pinned to the build host's platform so multi-arch builds
# cross-compile (fast) instead of running the Go toolchain under QEMU.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

WORKDIR /app

# Module download as a REAL layer, not a cache mount: CI's gha cache exports
# layers but never cache-mount contents, so this layer (keyed on go.mod/go.sum)
# is what carries dependency downloads across CI runs. All modules are public
# and come from proxy.golang.org — git is not needed; if a VCS-only module
# ever appears this fails loudly right here (re-add `apk add --no-cache git`).
COPY go.mod go.sum ./
RUN go mod download

# Source (see .dockerignore: tests, fixtures, query/, .env, and stale local
# binaries are excluded, so test-only edits don't invalidate this layer).
COPY . .

# Compile cache as a BuildKit cache mount: invisible to the gha cache (CI
# compiles once per run — same as before), but persistent locally, so
# iterative builds recompile only changed packages instead of the world.
#   -trimpath: no builder paths baked into the binary; Sentry frames show
#     module-relative paths.
#   -ldflags "-s -w": drop symbol table + DWARF (~30% smaller binary). Panic
#     traces and Sentry stacks are unaffected — both resolve frames through
#     pclntab via runtime.Callers, which the linker always keeps.
ARG TARGETOS TARGETARCH
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o main .

# Final stage — minor-version pin: patch/CVE releases flow in on rebuild,
# major bumps are an explicit, reviewable edit (vs :latest surprises).
FROM alpine:3.24

# Release identifier for Sentry (main.go reads SENTRY_RELEASE). CI passes the
# git SHA via --build-arg; local builds leave it empty (Sentry omits release).
ARG SENTRY_RELEASE=
ENV SENTRY_RELEASE=${SENTRY_RELEASE}

# ca-certificates for HTTPS egress (Anthropic, Google, Sentry, ...).
RUN apk --no-cache add ca-certificates

RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

# /app, not /root: /root is 0700 root:root on alpine, so appuser could not
# even traverse into it without a recursive chown — which rewrote the whole
# binary as a second image layer. A root-owned 0755 /app is readable and
# executable by appuser, and a binary the runtime user cannot write to is
# the correct ownership anyway.
WORKDIR /app

COPY --from=builder /app/main .

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

CMD ["./main"]
