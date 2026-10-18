# Bygg en statisk binär med webbappen inbäddad och kör den i en tom image.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY web ./web
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pianotunah . \
 && mkdir -p /out/data

FROM scratch
COPY --from=build /out/pianotunah /pianotunah
COPY --from=build --chown=1000:1000 /out/data /data
USER 1000:1000
ENV ADDR=:8080 DATA_DIR=/data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s CMD ["/pianotunah", "healthcheck"]
ENTRYPOINT ["/pianotunah"]
