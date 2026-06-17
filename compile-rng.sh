#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODD_FILE="${SCRIPT_DIR}/schema/krp.odd"
RNG_FILE="${SCRIPT_DIR}/schema/krp.rng"

CONTAINER_NAME="teigarage"
IMAGE="ghcr.io/teic/teigarage:dev"
PORT=8080
ENDPOINT="http://localhost:${PORT}/ege-webservice/Conversions/ODD%3Atext%3Axml/ODDC%3Atext%3Axml/relaxng%3Aapplication%3Axml-relaxng/"

if [[ ! -f "$ODD_FILE" ]]; then
  echo "Error: $ODD_FILE not found." >&2
  exit 1
fi

if ! command -v docker >/dev/null; then
  echo "Error: docker is not installed or not on PATH." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon is not running." >&2
  exit 1
fi

container_started_by_us=0
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "TEIGarage container already running."
else
  # Clean up a stopped container that survived a previous unclean exit
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  echo "Starting TEIGarage container..."
  docker run --rm -d --name "$CONTAINER_NAME" -p "${PORT}:8080" "$IMAGE" > /dev/null
  container_started_by_us=1

  printf "Waiting for service to be ready"
  for i in $(seq 1 60); do
    if curl -s --max-time 1 -o /dev/null "http://localhost:${PORT}/ege-webservice/" 2>/dev/null; then
      echo " ready."
      break
    fi
    printf "."
    sleep 1
    if [[ $i -eq 60 ]]; then
      echo
      echo "Error: service did not become ready within 60 seconds." >&2
      exit 1
    fi
  done
fi

# Download to temp file, validate, then move atomically into place.
TMP_RNG="$(mktemp)"
trap 'rm -f "$TMP_RNG"' EXIT

echo "Compiling $ODD_FILE -> $RNG_FILE..."
if ! curl -sS -f -o "$TMP_RNG" -F "upload=@${ODD_FILE}" "$ENDPOINT"; then
  echo "Error: conversion request failed." >&2
  exit 1
fi

if [[ ! -s "$TMP_RNG" ]]; then
  echo "Error: conversion produced an empty file." >&2
  exit 1
fi

if ! head -c 200 "$TMP_RNG" | grep -q '<?xml'; then
  echo "Error: output does not appear to be XML." >&2
  exit 1
fi

mv "$TMP_RNG" "$RNG_FILE"
trap - EXIT

echo "Done. $(wc -c < "$RNG_FILE") bytes written to $RNG_FILE."

if [[ $container_started_by_us -eq 1 ]]; then
  echo "Container is still running. To stop: docker stop $CONTAINER_NAME"
fi
