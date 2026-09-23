# Fase 3 — Implementación y Pruebas

**Reto:** Optimización de Pipelines de Procesamiento de Datos
**Insumo:** Hallazgos de la Fase 1 (`documento_analisis.md`) y diseño de la Fase 2 (`documento_diseno.md`).
**Objetivo:** Implementar el pipeline optimizado, probar su eficiencia y comparar resultados con el sistema actual.

---

## 1. Entregables de esta fase

| Archivo | Descripción |
|---------|-------------|
| `pipeline_optimizado.sh` | Implementación del diseño de la Fase 2 (map–reduce en shell). |
| `benchmark.sh` | Ejecuta ambos sistemas sobre el mismo dataset y compara tiempo, correctitud e I/O. |
| `documento_resultados.md` | Este documento. |

> Los datos de muestra (`data/`) y los intermedios (`*.montos`) son regenerables y quedan fuera de control de versiones.

---

## 2. Qué se implementó

El `pipeline_optimizado.sh` materializa las decisiones de diseño, cada una trazada a un hallazgo:

- **Map en un solo pase (H2, H3):** un único `awk` por archivo filtra `APROBADA`, cuenta y suma el monto en el mismo recorrido, leyendo el archivo directamente (sin `cat`/`grep`/`sed`).
- **Paralelismo (H1):** `find -print0 | xargs -0 -P $(nucleos)` lanza un worker por núcleo.
- **Reduce por stdout (H4):** los parciales fluyen por stdout hacia un `awk` agregador; **no se escribe ningún intermedio en disco**.
- **Agregación robusta (H5):** la suma se hace dentro de `awk` con `+0` y filtrando líneas con `NF==2`, eliminando el `Parse error` de `bc`.
- **Observabilidad y robustez (H6, H7, H9):** `set -euo pipefail`, función `log()` con timestamp a stderr y a archivo, y validación de directorio/archivos antes de procesar.
- **Parsing explícito (H8):** limpieza del símbolo `$` con `gsub` dentro de `awk`.

---

## 3. Metodología de prueba

- **Dataset compartido:** ambos sistemas procesan exactamente los mismos CSV, generados con el `generar_datos.sh` de la Fase 1.
- **Tiempo:** promedio de 3 corridas con `/usr/bin/time -p` (valor `real`).
- **Correctitud:** se calcula un **valor esperado independiente** con un `awk` de verificación y se compara contra la salida de cada sistema.
- **Dos tamaños** para observar escalabilidad: 8×50.000 (~13 MB) y 16×100.000 (~53 MB).

Reproducible con:
```bash
cd implementacion_pruebas
./benchmark.sh 8 50000 3      # dataset pequeño
./benchmark.sh 16 100000 3    # dataset grande
```

---

## 4. Resultados

### 4.1 Dataset 8 archivos × 50.000 filas (~13 MB)

| Métrica | Sistema actual | Pipeline optimizado |
|---------|----------------|---------------------|
| Tiempo real promedio | **0.487 s** | **0.160 s** |
| Procesos por archivo | 9 | 1 |
| Pases de lectura del dataset | ~3× | 1× |
| Intermedios en disco | 8 | 0 |
| Conteo de aprobadas | 134476 ✅ | 134476 ✅ |
| Suma de montos | *(vacío — bug `bc`)* ❌ | 67138891.34 ✅ |

**Speedup: 3.04×**

Valor esperado (verificación independiente): `APROBADAS=134476  MONTO_TOTAL=67138891.34` → coincide exactamente con el optimizado.

### 4.2 Dataset 16 archivos × 100.000 filas (~53 MB)

| Métrica | Sistema actual | Pipeline optimizado |
|---------|----------------|---------------------|
| Tiempo real promedio | **1.660 s** | **0.400 s** |
| Intermedios en disco | 16 | 0 |
| Suma de montos | *(vacío — bug `bc`)* ❌ | 267270012.10 ✅ |

**Speedup: 4.15×**

Valor esperado: `APROBADAS=533542  MONTO_TOTAL=267270012.10` → coincide exactamente con el optimizado.

---

## 5. Análisis de los resultados

- **Eficiencia:** el pipeline optimizado es ~3× más rápido en el dataset pequeño. La mejora combina paralelismo (H1), un solo pase (H2), menos procesos (H3) y cero I/O intermedio (H4).
- **Escalabilidad demostrada:** al pasar de ~13 MB a ~53 MB, el speedup **sube de 3.04× a 4.15×**. La ventaja **crece con el volumen**, porque el sistema actual escala linealmente en un solo núcleo mientras que el optimizado reparte la carga entre todos los núcleos y no paga el sobrecosto de relecturas ni de intermedios.
- **Correctitud recuperada:** el sistema actual dejaba la suma de montos **vacía** por el bug de `bc` documentado en H5. El pipeline optimizado produce el valor correcto, validado contra una fuente de verdad independiente en ambos tamaños.
- **Menos huella en disco:** de 8/16 archivos `.montos` a **0**. El pipeline es idempotente y no deja residuos.

---

## 6. Verificación de que se resolvieron las limitaciones (H1–H9)

| Hallazgo | Estado | Evidencia |
|----------|--------|-----------|
| H1 Secuencial | ✅ Resuelto | `xargs -P`; speedup crece con el volumen |
| H2 Múltiples lecturas | ✅ Resuelto | 1 pase (antes ~3) |
| H3 UUOC / procesos | ✅ Resuelto | 1 proceso/archivo (antes 9) |
| H4 Intermedios en disco | ✅ Resuelto | 0 archivos `.montos` (antes 8/16) |
| H5 Bug de suma | ✅ Resuelto | Suma correcta vs. vacía en el actual |
| H6 Sin logging | ✅ Resuelto | `pipeline_optimizado.log` con timestamps |
| H7 Sin manejo de errores | ✅ Resuelto | `set -euo pipefail` + validación |
| H8 Parsing frágil | ✅ Resuelto | `gsub` y columnas explícitas en `awk` |
| H9 Permisos manuales | ✅ Mitigado | check de directorio/archivos legibles |

---

## 7. Conclusión

El nuevo pipeline cumple los tres objetivos del reto: es **más eficiente** (3–4× más rápido), **más escalable** (la ventaja aumenta con el volumen al aprovechar todos los núcleos) y **más robusto/automatizable** (logging, modo estricto, sin intermedios, resultado correcto y verificado). Todas las limitaciones H1–H9 identificadas en la Fase 1 quedaron abordadas y verificadas con mediciones reales sobre el mismo dataset.

### Evolución futura
Para volúmenes que excedan una sola máquina, el mismo patrón map–reduce se puede llevar a `GNU parallel` multi-host o a un motor distribuido (Spark), manteniendo la lógica de negocio ya validada aquí.
