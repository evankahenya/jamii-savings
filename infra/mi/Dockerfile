# MI 4.6 + SQLite JDBC and ActiveMQ client jars. The .car is deployed separately.
ARG MI_BASE_IMAGE=wso2/wso2mi:4.6.0
ARG ACTIVEMQ_IMAGE=apache/activemq-classic:5.18.7

# client jars come from the broker image so the versions always match
FROM ${ACTIVEMQ_IMAGE} AS activemq

FROM maven:3.9.9-eclipse-temurin-21 AS drivers
ARG SQLITE_JDBC_VERSION=3.46.1.3
RUN mvn -B -q dependency:copy \
      -Dartifact=org.xerial:sqlite-jdbc:${SQLITE_JDBC_VERSION} \
      -DoutputDirectory=/drivers

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

RUN mkdir -p /home/wso2carbon/jamii-data
