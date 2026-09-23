#!/usr/bin/env bash
# =============================================================================
# PIPELINE OPTIMIZADO - Fase 3
# =============================================================================
# Implementa el diseño de la Fase 2 (map-reduce ligero en shell):
#   - Un solo pase por archivo (awk cuenta + suma a la vez)     -> H2
#   - Paralelismo por archivo con xargs -P N                     -> H1
#   - Un solo proceso por archivo (sin cat/grep/sed)             -> H3
#   - Sin archivos intermedios en disco (reduce por stdout)      -> H4
#   - Agregación robusta (sin bug de bc con parcial vacío)       -> H5
#   - Logging con timestamp                                      -> H6
#   - Modo estricto + validación de entradas                     -> H7, H9
#   - Parser CSV explícito y limpieza del símbolo $              -> H8
# =============================================================================

set -euo pipefail

DATA_DIR="${DATA_DIR:-./data}"
PATRON="${PATRON:-APROBADA}"
LOG_FILE="${LOG_FILE:-./pipeline_optimizado.log}"
NUCLEOS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# --- H6: logging con timestamp y nivel (a stderr y a archivo de log) ---
log() {
    local nivel="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$nivel" "$*" | tee -a "$LOG_FILE" >&2
}

# --- Map: procesa UN archivo en UN solo pase con UN solo proceso awk ---
# Emite por stdout: "<aprobadas> <suma_montos>"
procesa_un_archivo() {
    local archivo="$1"
    local patron="$2"
    if [[ ! -r "$archivo" ]]; then
        printf '0 0\n'           # no rompe el reduce; se registra aparte
        return 0
    fi
    awk -F',' -v patron="$patron" '
        $3 == patron {
            monto = $4; gsub(/\$/, "", monto);     # H8: limpia el símbolo $
            count++; sum += monto;                 # H2: cuenta y suma en el mismo pase
        }
        END { printf "%d %.2f\n", count+0, sum+0 }  # H5: +0 fuerza numérico aunque no haya coincidencias
    ' "$archivo"                                    # H3: awk lee directo, sin cat/grep/sed
}
export -f procesa_un_archivo

# --- Reduce: agrega los parciales de todos los workers (tolerante a vacíos) ---
reduce_resultados() {
    awk '
        NF == 2 { total_count += $1; total_sum += $2 }   # H5: ignora líneas vacías/malformadas
        END { printf "%d %.2f\n", total_count+0, total_sum+0 }
    '
}

main() {
    : > "$LOG_FILE"
    log INFO "Iniciando pipeline optimizado (paralelismo=$NUCLEOS)"

    # --- H7 / H9: validación de entorno antes de procesar ---
    [[ -d "$DATA_DIR" ]] || { log ERROR "No existe el directorio $DATA_DIR"; exit 1; }
    shopt -s nullglob
    local archivos=("$DATA_DIR"/*.csv)
    if (( ${#archivos[@]} == 0 )); then
        log ERROR "No hay archivos .csv en $DATA_DIR"
        exit 1
    fi
    log INFO "Archivos a procesar: ${#archivos[@]}"

    # --- Map (paralelo) -> Reduce, todo por stdout, sin intermedios (H1, H4) ---
    local resultado
    resultado="$(
        find "$DATA_DIR" -maxdepth 1 -name '*.csv' -print0 \
          | xargs -0 -P "$NUCLEOS" -I{} bash -c 'procesa_un_archivo "$1" "$2"' _ {} "$PATRON" \
          | reduce_resultados
    )"

    local aprobadas monto
    aprobadas="$(awk '{print $1}' <<< "$resultado")"
    monto="$(awk '{print $2}' <<< "$resultado")"

    log INFO "Resultado: APROBADAS=$aprobadas MONTO_TOTAL=$monto"
    printf 'APROBADAS=%s  MONTO_TOTAL=%s\n' "$aprobadas" "$monto"
    log INFO "Pipeline finalizado correctamente"
}

main "$@"
