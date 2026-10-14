#!/bin/sh
# Builds the .car into MI's carbonapps volume. Skipped if one is already there
# unless FORCE_CAR_BUILD=true.
set -eu

OUT=/carbonapps
if ls "$OUT"/*.car >/dev/null 2>&1 && [ "${FORCE_CAR_BUILD:-false}" != "true" ]; then
  echo "[car-build] CAR already deployed ($(ls "$OUT"/*.car | xargs -n1 basename)) - skipping build"
  exit 0
fi

# build in a copy so nothing is written into the checkout
rm -rf /tmp/project && mkdir -p /tmp/project
tar -C /src --exclude=./target --exclude=./.wso2mi -cf - . | tar -C /tmp/project -xf -
cd /tmp/project

# the maven image sets MAVEN_CONFIG, which breaks the CAR plugin's nested mvn call
unset MAVEN_CONFIG

echo "[car-build] building CAR (first run downloads Maven dependencies - can take ~10 min)"
mvn -B -q clean package -Dmaven.test.skip=true

CAR=$(ls target/*.car)
cp "$CAR" "$OUT/"
chown 10802:10802 "$OUT/$(basename "$CAR")"
echo "[car-build] deployed $(basename "$CAR") to MI"
