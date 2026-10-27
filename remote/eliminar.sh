#!/bin/bash
# Borra este pod por completo (disco incluido). Si no puede, al menos lo detiene.
echo "[$(date +%T)] Eliminando el pod ${RUNPOD_POD_ID:-?}: $1"
echo "Eliminando la instancia: $1" > /opt/estado.txt
sync
runpodctl remove pod "$RUNPOD_POD_ID" && exit 0
curl -sf -X DELETE "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" -H "Authorization: Bearer $RUNPOD_API_KEY" && exit 0
runpodctl stop pod "$RUNPOD_POD_ID"
