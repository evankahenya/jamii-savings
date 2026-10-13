# ---------------------------------------------------------------------
# Jamii MI *runtime* image = official WSO2 MI 4.6 + the drivers it needs.
#
# What goes IN the image (rarely changes):   JDBC/JMS driver jars, log config
# What does NOT (deployed by build/Jenkins):  the .car file with your APIs
# ---------------------------------------------------------------------
ARG MI_BASE_IMAGE=wso2/wso2mi:4.6.0
ARG ACTIVEMQ_IMAGE=apache/activemq-classic:5.18.7

# Stage 1: take the ActiveMQ client jars straight from the broker image, so the
# client version always matches the broker version (jar list per WSO2 MI docs).
FROM ${ACTIVEMQ_IMAGE} AS activemq

# Stage 2: download the SQLite JDBC driver from Maven Central (same version as pom.xml)
FROM maven:3.9.9-eclipse-temurin-21 AS drivers
ARG SQLITE_JDBC_VERSION=3.46.1.3
RUN mvn -B -q dependency:copy \
      -Dartifact=org.xerial:sqlite-jdbc:${SQLITE_JDBC_VERSION} \
      -DoutputDirectory=/drivers

# Stage 3: the actual MI image
FROM ${MI_BASE_IMAGE}
ARG AMQ_LIB=/opt/apache-activemq/lib

COPY --from=drivers  --chown=wso2carbon:wso2 /drivers/*.jar ${WSO2_SERVER_HOME}/lib/
COPY --from=activemq --chown=wso2carbon:wso2 \
     ${AMQ_LIB}/activemq-broker-*.jar \
     ${AMQ_LIB}/activemq-client-*.jar \
     ${AMQ_LIB}/activemq-kahadb-store-*.jar \
     ${AMQ_LIB}/hawtbuf-1*.jar \
     ${AMQ_LIB}/optional/activeio-core-*.jar \
     ${WSO2_SERVER_HOME}/lib/

# Folder the SQLite volume gets mounted on
RUN mkdir -p /home/wso2carbon/jamii-data
