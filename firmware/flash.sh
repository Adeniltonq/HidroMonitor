#!/usr/bin/env bash
# =============================================================================
#  Grava o HidroMonitor no ESP32-S3 apagando TODO o flash antes.
#  Remove firmware antigo, NVS (credenciais/config), OTA e a partição FAT.
#
#  Uso: ./flash.sh [porta]     (padrão: /dev/ttyACM0)
# =============================================================================
set -euo pipefail

PORTA="${1:-/dev/ttyACM0}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FQBN="esp32:esp32:esp32s3:FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB,EraseFlash=all"

echo "[1/2] Compilando..."
arduino-cli compile --fqbn "$FQBN" "$RAIZ/hidromonitor"

echo "[2/2] Gravando em $PORTA (apagando todo o flash antes)..."
arduino-cli upload -p "$PORTA" --fqbn "$FQBN" "$RAIZ/hidromonitor"

echo "Pronto. O device inicia no modo PROVISIONAMENTO (HIDRO) para um novo pareamento."
