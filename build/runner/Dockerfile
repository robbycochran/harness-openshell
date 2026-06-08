FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y openssh-clients tar gzip --nodocs && microdnf clean all

RUN curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh

COPY harness /usr/local/bin/harness

USER 1000

ENTRYPOINT ["harness", "launch"]
