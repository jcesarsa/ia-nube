#!/bin/bash
# Red de seguridad: elimina el pod si pasa el tiempo máximo o si nadie genera nada en un rato.
MAX_S=$(( ${MAX_HORAS:-4} * 3600 ))
INACT_S=$(( ${INACTIVIDAD_MIN:-60} * 60 ))
LIMITE=$(( $(date +%s) + MAX_S ))
echo $LIMITE > /opt/limite
echo $INACT_S > /opt/inactividad_s
while sleep 30; do
  AHORA=$(date +%s)
  if [ $AHORA -ge $LIMITE ]; then
    bash /opt/remote/eliminar.sh "tiempo máximo de ${MAX_HORAS:-4} h"; sleep 300
  fi
  # La inactividad solo cuenta cuando ya está lista (la preparación tiene su propio límite).
  if grep -q '^LISTO' /opt/estado.txt 2>/dev/null; then
    ULTIMA=$(stat -c %Y /opt/ultima_actividad)
    if [ $(( AHORA - ULTIMA )) -ge $INACT_S ]; then
      bash /opt/remote/eliminar.sh "${INACTIVIDAD_MIN:-60} min sin generar"; sleep 300
    fi
  elif grep -q '^ERROR' /opt/estado.txt 2>/dev/null; then
    # Si la preparación falla, se borra sola a los 20 min para no seguir pagando.
    [ -z "${T_ERROR:-}" ] && T_ERROR=$AHORA
    [ $(( AHORA - T_ERROR )) -ge 1200 ] && { bash /opt/remote/eliminar.sh "falló la preparación"; sleep 300; }
  fi
done
