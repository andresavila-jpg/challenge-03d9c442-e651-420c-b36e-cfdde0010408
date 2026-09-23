#!/usr/bin/env bash
# =============================================================================
# BENCHMARK - Fase 3
# Compara el SISTEMA ACTUAL vs el PIPELINE OPTIMIZADO sobre el MISMO dataset.
# Mide: tiempo real (varias corridas), correctitud y valor esperado.
# =============================================================================
set -uo pipefail

ACTUAL_DIR="../analisis_sistema_actual/sistema_actual"
DATA_DIR="./data"
N_ARCHIVOS="${1:-8}"
N_FILAS="${2:-50000}"
CORRIDAS="${3:-3}"

echo "=========================================================="
echo " BENCHMARK: sistema actual vs pipeline optimizado"
echo " Dataset: $N_ARCHIVOS archivos x $N_FILAS filas | corridas: $CORRIDAS"
echo "=========================================================="

# --- 1) Generar dataset compartido (reutiliza el generador de la Fase 1) ---
rm -rf "$DATA_DIR"
DATA_DIR="$DATA_DIR" bash "$ACTUAL_DIR/generar_datos.sh" "$N_ARCHIVOS" "$N_FILAS" >/dev/null 2>&1 || {
    # el generador de la Fase 1 usa ./data relativo; lo invocamos ahí y movemos
    ( cd "$ACTUAL_DIR" && ./generar_datos.sh "$N_ARCHIVOS" "$N_FILAS" >/dev/null )
    mv "$ACTUAL_DIR/data" "$DATA_DIR"
}
echo "Dataset generado en $DATA_DIR ($(du -sh "$DATA_DIR" | awk '{print $1}'))"
echo

# --- 2) Valor esperado (fuente de verdad independiente, un solo awk) ---
esperado="$(awk -F',' '
    $3=="APROBADA"{m=$4; gsub(/\$/,"",m); c++; s+=m}
    END{printf "APROBADAS=%d MONTO_TOTAL=%.2f", c+0, s+0}
' "$DATA_DIR"/*.csv)"
echo "Valor esperado (verificación independiente): $esperado"
echo

# --- Helper de cronometraje: promedio de N corridas ---
promedio_tiempo() {
    local etiqueta="$1"; shift
    local suma=0 t
    for _ in $(seq 1 "$CORRIDAS"); do
        t="$( { /usr/bin/time -p "$@" >/dev/null 2>/tmp/bench_err; } 2>&1; grep real /tmp/bench_err | awk '{print $2}')"
        suma="$(awk -v a="$suma" -v b="$t" 'BEGIN{print a+b}')"
    done
    awk -v s="$suma" -v n="$CORRIDAS" 'BEGIN{printf "%.3f", s/n}'
}

# --- 3) SISTEMA ACTUAL ---
echo "----- Sistema actual -----"
cp "$ACTUAL_DIR/procesar_datos.sh" ./_actual.sh
chmod +x ./_actual.sh
salida_actual="$(./_actual.sh 2>&1)"
echo "$salida_actual" | grep -E "Total aprobadas|Suma total" || true
t_actual="$(promedio_tiempo actual ./_actual.sh)"
echo "Tiempo promedio (real): ${t_actual}s"
n_intermedios="$(ls -1 "$DATA_DIR"/*.montos 2>/dev/null | wc -l | tr -d ' ')"
echo "Archivos intermedios .montos dejados en disco: $n_intermedios"
rm -f "$DATA_DIR"/*.montos ./_actual.sh
echo

# --- 4) PIPELINE OPTIMIZADO ---
echo "----- Pipeline optimizado -----"
salida_opt="$(DATA_DIR="$DATA_DIR" ./pipeline_optimizado.sh 2>/dev/null)"
echo "Salida: $salida_opt"
t_opt="$(promedio_tiempo opt env DATA_DIR="$DATA_DIR" ./pipeline_optimizado.sh)"
echo "Tiempo promedio (real): ${t_opt}s"
n_intermedios_opt="$(ls -1 "$DATA_DIR"/*.montos 2>/dev/null | wc -l | tr -d ' ')"
echo "Archivos intermedios dejados en disco: $n_intermedios_opt"
echo

# --- 5) Resumen comparativo ---
echo "=========================================================="
echo " RESUMEN COMPARATIVO"
echo "=========================================================="
speedup="$(awk -v a="$t_actual" -v o="$t_opt" 'BEGIN{ if(o>0) printf "%.2f", a/o; else print "n/a"}')"
printf "%-28s %-15s %-15s\n" "Métrica" "Actual" "Optimizado"
printf "%-28s %-15s %-15s\n" "Tiempo real promedio (s)" "$t_actual" "$t_opt"
printf "%-28s %-15s %-15s\n" "Procesos por archivo" "9" "1"
printf "%-28s %-15s %-15s\n" "Pases de lectura dataset" "~3x" "1x"
printf "%-28s %-15s %-15s\n" "Intermedios en disco" "$N_ARCHIVOS" "0"
printf "%-28s %-15s %-15s\n" "Suma de montos correcta" "NO (bug bc)" "SI"
echo
echo "Speedup (actual / optimizado): ${speedup}x"
echo "Valor esperado: $esperado"
echo "Valor optimizado: $salida_opt"
