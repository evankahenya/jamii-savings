# ---------------------------------------------------------------------
# Jenkins for the Jamii pipeline = Jenkins LTS + the tools the Jenkinsfile uses:
#   mvn      - build the MI .car
#   apictl   - bundle/import/export APIs in API Manager
#   curl/jq  - MI Management API calls + smoke tests
#   xmllint  - validate the Synapse XML before building
#   zip      - package the APIM operation policies
# Plugins and the job itself are set up from code (plugins.txt + casc.yaml),
# so there is no setup wizard and nothing to click.
# ---------------------------------------------------------------------
FROM jenkins/jenkins:2.541.3-lts-jdk21

ARG APICTL_VERSION=4.7.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends maven jq zip unzip libxml2-utils curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/apictl.tar.gz \
      "https://github.com/wso2/product-apim-tooling/releases/download/v${APICTL_VERSION}/apictl-${APICTL_VERSION}-linux-amd64.tar.gz" \
 && tar -xzf /tmp/apictl.tar.gz -C /opt \
 && ln -s /opt/apictl/apictl /usr/local/bin/apictl \
 && rm /tmp/apictl.tar.gz

USER jenkins
# the repo is mounted from the host (different owner) - let git use it
RUN git config --global --add safe.directory '*'
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
# Jenkins configuration as code: admin user, credentials, and the pipeline job
COPY --chown=jenkins:jenkins casc.yaml /usr/share/jenkins/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc.yaml
