FROM docker:cli AS docker

FROM jenkins/ssh-agent:latest-jdk21

# Docker CLI and compose plugin; Docker itself runs in jenkins-docker
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

RUN apt-get update \
    && apt-get install -y --no-install-recommends make curl jq openssl \
    && rm -rf /var/lib/apt/lists/*

# sshd needs root, jobs run as the jenkins user
USER root
