#!/bin/bash
# =============================================================================
# SISTEMA ACTUAL - Pipeline de procesamiento de datos (versión sin optimizar)
# =============================================================================
# Este script representa el "sistema actual" que la fintech usa hoy.
# Procesa archivos de transacciones (.csv) de forma SECUENCIAL.
#
# Objetivo pedagógico: mostrar las limitaciones de eficiencia que se
# analizan en la Fase 1 (ejecución secuencial, relecturas, sin logging,
# sin manejo de errores, uso encadenado e ineficiente de cat/grep/awk/sed).
# =============================================================================

DATA_DIR="./data"
PATRON="APROBADA"

echo "Iniciando procesamiento..."

# --- 1) Conteo de transacciones aprobadas, archivo por archivo (secuencial) ---
total=0
for archivo in "$DATA_DIR"/*.csv; do
    # Uso de cat innecesario (Useless Use of Cat) + relectura del archivo
    aprobadas=$(cat "$archivo" | grep "$PATRON" | wc -l)
    echo "Archivo $archivo -> $aprobadas aprobadas"
    total=$((total + aprobadas))
done
echo "Total aprobadas: $total"

# --- 2) Extraer el monto (columna 4) de cada transacción, archivo por archivo ---
for archivo in "$DATA_DIR"/*.csv; do
    # Se vuelve a leer el mismo archivo desde cero (segundo pase completo)
    cat "$archivo" | grep "$PATRON" | awk -F',' '{print $4}' | sed 's/\$//g' > "$archivo.montos"
done

# --- 3) Sumar todos los montos, releyendo de nuevo los resultados intermedios ---
suma=0
for archivo in "$DATA_DIR"/*.montos; do
    parcial=$(cat "$archivo" | awk '{s+=$1} END {print s}')
    suma=$(echo "$suma + $parcial" | bc)
done
echo "Suma total de montos aprobados: $suma"

echo "Procesamiento finalizado."
