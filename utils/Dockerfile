ARG GO_IMAGE=docker.io/golang:1.27-alpine
ARG BASE_IMAGE=docker.io/alpine:3.24.1

# =============================================================================
# Stage 1: Build Go binary
# =============================================================================
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder

ARG TARGETOS=linux
ARG TARGETARCH
ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown

WORKDIR /build

# Cache dependencies
COPY go.mod go.sum ./
RUN go mod download

# Build
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -ldflags="-s -w \
      -X github.com/this-is-tobi/homelab/utils/cmd.version=${VERSION} \
      -X github.com/this-is-tobi/homelab/utils/cmd.commit=${COMMIT} \
      -X github.com/this-is-tobi/homelab/utils/cmd.date=${BUILD_DATE}" \
    -o /ohmlab .

# =============================================================================
# Stage 2: Final image (toolbox)
# =============================================================================
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG USERNAME=ohmlab
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
# Third-party tool versions — pinned, checksum-verified below. Bump
# deliberately (kubectl tracks the cluster's k3s minor).
ARG VAULT_VERSION=1.21.4
ARG KUBECTL_VERSION=v1.35.3
ARG HELM_VERSION=v4.2.4

ENV HOME=/home/${USERNAME}

WORKDIR ${HOME}

# Install toolbox packages (kept for ad-hoc use; Go binary handles automated tasks)
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    gzip \
    jq \
    openssl \
    tar \
    yq \
    && rm -rf /var/cache/apk/*

# Install Vault CLI (still useful for manual operations) — verified against
# the published SHA256SUMS so the build is reproducible and tamper-evident.
RUN curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" -o "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" \
    && curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" -o vault_SHA256SUMS \
    && grep "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" vault_SHA256SUMS | sha256sum -c - \
    && unzip -o "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" vault -d /usr/bin/ \
    && chmod +x /usr/bin/vault \
    && rm "vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" vault_SHA256SUMS

# Install kubectl — pinned (tracks the cluster's k3s minor) + checksum-verified.
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" -o kubectl.sha256 \
    && echo "$(cat kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl \
    && rm kubectl.sha256

# Install helm — pinned release tarball + checksum, instead of piping an
# unpinned script from the `main` branch into a shell.
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" -o "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" -o helm.sha256sum \
    && sha256sum -c helm.sha256sum \
    && tar -xzf "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
    && chmod +x /usr/local/bin/helm \
    && rm "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" helm.sha256sum

# Create non-root user
RUN addgroup -g ${USER_GID} ${USERNAME} \
    && adduser -D -h ${HOME} -s /bin/bash -G ${USERNAME} -u ${USER_UID} ${USERNAME} \
    && chown -R ${USERNAME}:root ${HOME} \
    && chgrp -R 0 ${HOME} \
    && chmod -R g=u ${HOME}

# Copy Go binary
COPY --from=builder --chown=${USER_UID}:${USER_GID} /ohmlab /usr/local/bin/ohmlab

# Ensure binary is executable
RUN chmod +x /usr/local/bin/ohmlab

# Numeric UID, not the account name: Kubernetes cannot resolve a named user
# at admission, so `runAsNonRoot: true` without an explicit runAsUser rejects
# pods running this image ("container has runAsNonRoot and image has
# non-numeric user"). The require-non-root policy in this repo enforces that.
USER ${USER_UID}

ENTRYPOINT ["ohmlab"]
CMD ["--help"]
