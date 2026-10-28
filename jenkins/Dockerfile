# Jenkins with the tools the ShipLog pipeline calls: Python, Docker CLI, az CLI, Trivy.
# jdk21, not jdk17: the lts-jdk17 tag stopped receiving updates in March 2026.
FROM jenkins/jenkins:lts-jdk21

USER root

ARG AZURE_CLI_VERSION=2.91.0
ARG TRIVY_VERSION=0.76.1

# Python and venv for the Test stage; curl for downloads and the health check
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI and buildx only, no Docker engine: builds run on the host's engine
# through the socket mounted in docker-compose.yml
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Azure CLI: Microsoft has no apt packages for Debian 13 yet, so pip into its own venv
RUN python3 -m venv /opt/az \
 && /opt/az/bin/pip install --no-cache-dir azure-cli==${AZURE_CLI_VERSION} \
 && ln -s /opt/az/bin/az /usr/local/bin/az

# Trivy: a pinned release, installed only if its checksum matches
RUN cd /tmp \
 && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.deb \
 && curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt \
 && grep " trivy_${TRIVY_VERSION}_Linux-64bit.deb\$" trivy_${TRIVY_VERSION}_checksums.txt | sha256sum -c - \
 && dpkg -i trivy_${TRIVY_VERSION}_Linux-64bit.deb \
 && rm trivy_*

USER jenkins
