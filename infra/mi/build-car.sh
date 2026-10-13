#!/bin/sh
# One-shot job used by the `car-build` compose service.
# Builds Jamii_WSO2_Project into a .car and puts it in MI's carbonapps volume,
# so a plain `docker compose up` gives you a working MI with all the APIs.
#
# Skips the build when a .car is already there (e.g. deployed by Jenkins).
# Set FORCE_CAR_BUILD=true to rebuild from the current source anyway.
set -eu

OUT=/carbonapps
if ls "$OUT"/*.car >/dev/null 2>&1 && [ "${FORCE_CAR_BUILD:-false}" != "true" ]; then
  echo "[car-build] CAR already deployed ($(ls "$OUT"/*.car | xargs -n1 basename)) - skipping build"
  exit 0
fi

# Build in a scratch copy so nothing (target/, deployment/libs/) is written into your checkout
rm -rf /tmp/project && mkdir -p /tmp/project
tar -C /src --exclude=./target --exclude=./.wso2mi -cf - . | tar -C /tmp/project -xf -
cd /tmp/project

# The maven image sets MAVEN_CONFIG=/root/.m2, which the WSO2 CAR plugin's nested
# mvn call would wrongly treat as a build phase - unset it.
unset MAVEN_CONFIG

echo "[car-build] building CAR (first run downloads Maven dependencies - can take ~10 min)"
mvn -B -q clean package -Dmaven.test.skip=true

CAR=$(ls target/*.car)
cp "$CAR" "$OUT/"
chown 10802:10802 "$OUT/$(basename "$CAR")"   # 10802 = wso2carbon user inside the MI image
echo "[car-build] deployed $(basename "$CAR") to MI"
