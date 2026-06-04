# syntax=docker/dockerfile:1.4

# OpenShell in-cluster sandbox launcher.
#
# A minimal image containing the Go launcher and openshell CLI.
# Runs as a Kubernetes Job triggered by `kubectl apply -f sandbox.yaml`.
# Reads sandbox configuration from a ConfigMap and credentials from
# mounted Secrets — no credentials transit the kubectl client.
#
# Build:
#   # Cross-compile the Go launcher first:
#   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o launcher .
#   docker build --platform linux/amd64 -t quay.io/rcochran/openshell:launcher .
#
# Push:  docker push quay.io/rcochran/openshell:launcher

FROM scratch

COPY launcher /usr/local/bin/launcher
COPY openshell /usr/local/bin/openshell

USER 1000

ENTRYPOINT ["/usr/local/bin/launcher"]
