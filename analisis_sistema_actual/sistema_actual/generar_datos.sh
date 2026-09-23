#!/bin/bash
# =============================================================================
# Generador de datos de muestra para simular el sistema actual de la fintech.
# Crea varios CSV de transacciones para poder medir el pipeline.
# =============================================================================
DATA_DIR="./data"
N_ARCHIVOS="${1:-8}"     # número de archivos
N_FILAS="${2:-50000}"    # filas por archivo

mkdir -p "$DATA_DIR"
estados=("APROBADA" "RECHAZADA" "PENDIENTE")

for i in $(seq 1 "$N_ARCHIVOS"); do
    archivo="$DATA_DIR/transacciones_$i.csv"
    echo "id,fecha,estado,monto" > "$archivo"
    awk -v filas="$N_FILAS" 'BEGIN {
        srand();
        estados[0]="APROBADA"; estados[1]="RECHAZADA"; estados[2]="PENDIENTE";
        for (r=1; r<=filas; r++) {
            e = estados[int(rand()*3)];
            monto = int(rand()*100000)/100;
            printf "%d,2026-09-%02d,%s,$%.2f\n", r, (r%28)+1, e, monto;
        }
    }' >> "$archivo"
done

echo "Generados $N_ARCHIVOS archivos de $N_FILAS filas en $DATA_DIR"
