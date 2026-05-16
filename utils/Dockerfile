ARG GO_IMAGE=docker.io/golang:1.23-alpine
ARG BASE_IMAGE=docker.io/alpine:3.23.4

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
      -X github.com/this-is-tobi/homelab/homelab-utils/cmd.version=${VERSION} \
      -X github.com/this-is-tobi/homelab/homelab-utils/cmd.commit=${COMMIT} \
      -X github.com/this-is-tobi/homelab/homelab-utils/cmd.date=${BUILD_DATE}" \
    -o /ohmlab .

# =============================================================================
# Stage 2: Final image (toolbox)
# =============================================================================
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG USERNAME=ohmlab
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG VAULT_VERSION=1.21.0

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

# Install Vault CLI (still useful for manual operations)
RUN curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip" -o vault.zip \
    && unzip vault.zip -d /usr/bin/ \
    && chmod +x /usr/bin/vault \
    && rm vault.zip

# Install kubectl
RUN KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Install helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

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

USER ${USERNAME}

ENTRYPOINT ["ohmlab"]
CMD ["--help"]
