# Jenkins LTS + maven, apictl, jq, xmllint and zip for the pipeline
FROM jenkins/jenkins:2.541.3-lts-jdk21

ARG APICTL_VERSION=4.7.2
# set by Docker: amd64 or arm64 (Apple Silicon)
ARG TARGETARCH

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends maven jq zip unzip libxml2-utils curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/apictl.tar.gz \
      "https://github.com/wso2/product-apim-tooling/releases/download/v${APICTL_VERSION}/apictl-${APICTL_VERSION}-linux-${TARGETARCH:-amd64}.tar.gz" \
 && tar -xzf /tmp/apictl.tar.gz -C /opt \
 && ln -s /opt/apictl/apictl /usr/local/bin/apictl \
 && rm /tmp/apictl.tar.gz

USER jenkins
# the repo is mounted from the host with a different owner
RUN git config --global --add safe.directory '*'
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
COPY --chown=jenkins:jenkins casc.yaml /usr/share/jenkins/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc.yaml
COPY --chown=jenkins:jenkins jamii-first-build.groovy /usr/share/jenkins/ref/init.groovy.d/jamii-first-build.groovy.override
