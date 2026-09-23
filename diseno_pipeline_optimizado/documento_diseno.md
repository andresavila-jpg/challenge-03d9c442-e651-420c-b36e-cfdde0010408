# Fase 2 — Diseño de Pipelines Optimizados

**Reto:** Optimización de Pipelines de Procesamiento de Datos
**Insumo:** Hallazgos H1–H9 documentados en `analisis_sistema_actual/documento_analisis.md`.
**Objetivo:** Diseñar un pipeline más eficiente, escalable y automatizado que resuelva las limitaciones detectadas, definiendo su arquitectura antes de implementarlo en la Fase 3.

---

## 1. Principios de diseño

El rediseño se apoya en cinco principios derivados directamente del análisis:

1. **Un solo pase por dato** — leer cada archivo una única vez (ataca H2).
2. **Paralelismo por archivo** — repartir el trabajo entre todos los núcleos (ataca H1).
3. **Mínimo número de procesos** — colapsar cadenas `cat|grep|awk|sed` en un único `awk` (ataca H3).
4. **Sin estado intermedio en disco** — agregación en memoria/stream, sin `.montos` (ataca H4).
5. **Robusto y observable** — modo estricto, validación, logging y agregación segura (ataca H5, H6, H7, H9).

---

## 2. Trazabilidad hallazgo → decisión de diseño

| Hallazgo (Fase 1) | Decisión de diseño | Técnica |
|-------------------|--------------------|---------|
| H1 Secuencial | Procesamiento paralelo por archivo | `xargs -P "$(nproc)"` sobre una función worker |
| H2 Múltiples lecturas | Un único pase por archivo que cuenta y suma a la vez | `awk` con acumuladores en el bloque principal |
| H3 UUOC / cadenas largas | Pasar el archivo directo a `awk`; eliminar `cat`, `grep`, `sed` | `awk -F',' '...' "$archivo"` |
| H4 Intermedios en disco | Cada worker emite un resultado parcial por stdout; el orquestador reduce | Map → Reduce por stdout, sin ficheros temporales |
| H5 Bug en suma con `bc` | Acumulación numérica dentro de `awk`; reducción final tolerante a vacío | `END { print count, sum }` + reduce en `awk` |
| H6 Sin logging | Función `log()` con timestamp y nivel a stderr + archivo de log | `printf '%s [%s] %s'` |
| H7 Sin manejo de errores | Modo estricto y validación de entradas | `set -euo pipefail`, checks previos |
| H8 Parsing CSV frágil | Parser explícito de columna y limpieza de `$` dentro de `awk` | `gsub(/\$/,"",$4)` |
| H9 Permisos manuales | Verificación de permisos y `chmod` controlado; datos legibles | test `-r`, `-x` |

---

## 3. Arquitectura del nuevo sistema

Patrón **Map–Reduce ligero en shell**, orquestado en tres capas:

```
                +-------------------------------------------+
                |            orquestador (main)             |
                |  set -euo pipefail + logging + validación |
                +-------------------------------------------+
                                   |
                 descubre archivos *.csv (una vez)
                                   |
                                   v
        +---------- xargs -P N (un worker por núcleo) ----------+
        |                        |                        |      |
        v                        v                        v      v
   worker(csv_1)           worker(csv_2)            worker(csv_3) ...
   1 pase con awk:         1 pase con awk:          ...
   filtra APROBADA         filtra APROBADA
   cuenta + suma monto     cuenta + suma monto
   emite: "count sum"      emite: "count sum"   ->  todo por stdout
        \                        |                        /
         \                       |                       /
          v                      v                      v
                +-------------------------------------------+
                |         REDUCE (awk agregador final)      |
                |  suma counts y sums de todos los workers  |
                |  tolerante a líneas vacías (H5)           |
                +-------------------------------------------+
                                   |
                                   v
                    resultado final + log con métricas
```

### Capas

- **Orquestador (`main`)**: activa modo estricto, inicializa logging, valida que exista el directorio de datos y archivos legibles, descubre la lista de CSV **una sola vez** y lanza el `map`.
- **Map (worker por archivo)**: función que recibe la ruta de UN archivo y hace **un único pase** con `awk`, filtrando `APROBADA`, contando y sumando el monto (limpiando el `$`) en el mismo recorrido. Emite una sola línea `count sum` a stdout. Se ejecuta en paralelo vía `xargs -P`.
- **Reduce (agregador)**: un `awk` final que consume todas las líneas parciales y produce el `count` y `sum` globales, ignorando líneas vacías o malformadas para evitar el bug H5.

---

## 4. Diseño de los componentes

### 4.1 Worker (map) — un solo pase, un solo proceso

```bash
# procesa_un_archivo <ruta_csv>
# Emite: "<aprobadas> <suma_montos>"
procesa_un_archivo() {
    local archivo="$1"
    [[ -r "$archivo" ]] || { log ERROR "No legible: $archivo"; return 0; }
    awk -F',' '
        $3 == "APROBADA" {
            monto = $4; gsub(/\$/, "", monto);   # H8: limpia el símbolo $
            count++; sum += monto;               # H2: cuenta y suma en el mismo pase
        }
        END { printf "%d %.2f\n", count+0, sum+0 }  # H5: +0 fuerza numérico aunque esté vacío
    ' "$archivo"                                  # H3: sin cat/grep/sed
}
```

Un solo proceso `awk` por archivo, frente a los 9 procesos/archivo del sistema actual.

### 4.2 Orquestador + paralelismo (map)

```bash
export -f procesa_un_archivo log
NUCLEOS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

find "$DATA_DIR" -maxdepth 1 -name '*.csv' -print0 \
  | xargs -0 -P "$NUCLEOS" -I{} bash -c 'procesa_un_archivo "$@"' _ {} \
  | reduce_resultados
```

- `find ... -print0` + `xargs -0`: seguro ante nombres con espacios.
- `-P "$NUCLEOS"`: tantos workers como núcleos (H1).
- La salida de todos los workers fluye por stdout directo al reduce (H4: sin intermedios).

### 4.3 Reduce — agregación tolerante

```bash
reduce_resultados() {
    awk '
        NF == 2 { total_count += $1; total_sum += $2 }   # H5: ignora líneas vacías/malformadas
        END { printf "APROBADAS=%d  MONTO_TOTAL=%.2f\n", total_count+0, total_sum+0 }
    '
}
```

### 4.4 Robustez y observabilidad

```bash
set -euo pipefail                    # H7: aborta ante error, variable no definida o fallo en pipe

log() {                              # H6: logging con timestamp y nivel
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE"
}

# H9: validación de entorno antes de procesar
[[ -d "$DATA_DIR" ]] || { log ERROR "No existe $DATA_DIR"; exit 1; }
shopt -s nullglob
archivos=("$DATA_DIR"/*.csv)
(( ${#archivos[@]} > 0 )) || { log ERROR "Sin CSV que procesar"; exit 1; }
```

---

## 5. Automatización

- **Script único parametrizable** (`pipeline_optimizado.sh`) con variables `DATA_DIR`, `PATRON`, `LOG_FILE` y grado de paralelismo autodetectado.
- **Idempotente**: no deja residuos en disco, se puede relanzar sin limpieza previa (resuelve H4).
- **Integrable en cron / CI**: código de salida distinto de cero ante fallos (gracias a `set -e`), apto para orquestadores.
- **Log persistente** con métricas de cada corrida para auditoría en producción (contexto fintech).

---

## 6. Escalabilidad

| Eje | Sistema actual | Diseño optimizado |
|-----|----------------|-------------------|
| Núcleos | 1 (secuencial) | N (xargs -P) |
| Pases de lectura | ~3× dataset | 1× dataset |
| Procesos por archivo | 9 | 1 |
| Estado en disco | 8 intermedios `.montos` | 0 |
| Crecimiento de datos | Lineal, un core | Lineal repartido entre N cores |
| Muchos archivos pequeños | Se degrada por overhead de procesos | Paralelismo absorbe la carga |

**Límite y evolución:** para volúmenes que superen la memoria/CPU de una sola máquina, el mismo patrón map–reduce se puede portar a `GNU parallel` multi-host o a un motor distribuido (Spark). El diseño en shell es la base conceptual y suficiente para el alcance del reto.

---

## 7. Métricas para validar en la Fase 3

Se compararán sistema actual vs. optimizado sobre el **mismo dataset** (8 CSV × 50.000 filas):

1. **Tiempo real** (`/usr/bin/time -p`) — esperado: menor y con mejor escalado al subir el volumen.
2. **Número de procesos lanzados** — esperado: de ~72 a ~(8 workers + reduce).
3. **I/O intermedio** — esperado: de 8 archivos `.montos` a 0.
4. **Correctitud** — el total de montos debe calcularse sin el `Parse error` de H5.

---

## 8. Resultado esperado

Un pipeline que produce **el mismo resultado de negocio** (conteo de aprobadas y suma de montos) con:
- un único pase por archivo,
- ejecución en paralelo,
- sin archivos intermedios,
- con logging, validación y agregación robusta.

La implementación concreta y la medición comparativa se realizan en la **Fase 3**.
