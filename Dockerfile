# Build stage
FROM alpine:3.19 AS builder

RUN apk add --no-cache clang llvm16 curl-dev musl-dev tar

RUN wget -O /tmp/odin.tar.gz https://github.com/odin-lang/Odin/releases/download/dev-2026-02/odin-linux-amd64-dev-2026-02.tar.gz \
    && tar xzf /tmp/odin.tar.gz -C /opt \
    && rm /tmp/odin.tar.gz \
    && ln -s /opt/odin-linux-amd64-nightly+2026-02-04 /opt/odin

ENV PATH="/opt/odin:${PATH}"
ENV ODIN_ROOT="/opt/odin"

WORKDIR /build
COPY src/ src/
RUN cc -c src/curl_helpers.c -o src/curl_helpers.o
RUN odin build src -out:odin-claw -o:speed

# Runtime stage
FROM alpine:3.19
RUN apk add --no-cache libcurl ca-certificates
RUN mkdir -p /var/lib/nullclaw /tmp/nullclaw
WORKDIR /app
COPY --from=builder /build/odin-claw .
EXPOSE 8080
CMD ["./odin-claw", "gateway", "--host", "0.0.0.0", "--port", "8080"]
