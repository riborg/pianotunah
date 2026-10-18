# Build a static binary with the web app embedded and run it in an empty image.
# Go cross-compiles on the build machine's platform, so multiple architectures
# need no emulation.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/pianotunah . \
 && mkdir -p /out/data

FROM scratch
COPY --from=build /out/pianotunah /pianotunah
COPY --from=build --chown=1000:1000 /out/data /data
USER 1000:1000
ENV ADDR=:8080 DATA_DIR=/data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s CMD ["/pianotunah", "healthcheck"]
ENTRYPOINT ["/pianotunah"]
