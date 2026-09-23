# Fase 1 — Análisis del Sistema Actual

**Reto:** Optimización de Pipelines de Procesamiento de Datos
**Contexto:** Fintech que procesa archivos de transacciones (`.csv`) mediante scripts de terminal ejecutados de forma secuencial.
**Objetivo de la fase:** Entender las operaciones actuales, evaluar su eficiencia y documentar limitaciones y recomendaciones.

---

## 1. Sistema analizado

Para analizar sobre algo concreto y medible, se materializó el "sistema actual" descrito en el briefing en:

- `sistema_actual/procesar_datos.sh` — pipeline actual (secuencial, encadenando `cat`/`grep`/`awk`/`sed`).
- `sistema_actual/generar_datos.sh` — generador de datos de muestra para poder medir.
- `sistema_actual/data/` — 8 archivos CSV de 50.000 filas cada uno (~13 MB en total).

Estructura de cada CSV: `id,fecha,estado,monto` con estados `APROBADA / RECHAZADA / PENDIENTE` y monto en formato `$1234.56`.

### Qué hace el pipeline actual

1. **Bloque 1 – Conteo:** por cada archivo, cuenta transacciones `APROBADA` con `cat | grep | wc -l`.
2. **Bloque 2 – Extracción de montos:** vuelve a recorrer cada archivo con `cat | grep | awk -F',' '{print $4}' | sed 's/\$//g'` y escribe un intermedio `.montos` en disco.
3. **Bloque 3 – Suma:** vuelve a leer cada `.montos` con `cat | awk` y acumula con `bc`.

---

## 2. Metodología de evaluación

- Dataset: 8 CSV × 50.000 filas (~400.000 registros, ~13 MB).
- Medición de tiempo: `/usr/bin/time` con 3 corridas.
- Conteo manual de procesos por bloque y de pases de lectura sobre los datos.

**Tiempo observado del sistema actual:** ~0.52–0.56 s reales de forma consistente sobre 13 MB. El tiempo crece linealmente con el volumen, y el diseño impide aprovechar los múltiples núcleos de CPU disponibles.

---

## 3. Hallazgos

### 🔴 H1 — Ejecución 100% secuencial (no aprovecha múltiples núcleos)
El bucle `for archivo in ...` procesa un archivo a la vez. En una máquina con N núcleos, N-1 quedan ociosos. Con más archivos o archivos más grandes, el tiempo escala de forma lineal en lugar de paralelizarse.

### 🔴 H2 — Múltiples pases de lectura sobre los mismos datos
- El Bloque 1 y el Bloque 2 **leen el dataset completo dos veces** (una para contar, otra para extraer montos), cuando ambos filtran por el mismo patrón `APROBADA`.
- El Bloque 3 introduce **una tercera lectura** al releer los archivos `.montos`.
- Resultado: se lee ~3× el volumen de datos que sería necesario.

### 🟡 H3 — "Useless Use of Cat" (UUOC) y encadenamiento ineficiente
Patrones como `cat "$archivo" | grep ...` lanzan un proceso `cat` innecesario. `grep`, `awk` y `sed` pueden leer el archivo directamente. Además, `grep | awk | sed` puede colapsarse en una sola invocación de `awk`.

**Procesos hijos que lanza el pipeline actual:**
| Bloque | Comandos | Procesos/archivo |
|--------|----------|------------------|
| 1 Conteo | `cat` + `grep` + `wc` | 3 |
| 2 Montos | `cat` + `grep` + `awk` + `sed` | 4 |
| 3 Suma | `cat` + `awk` | 2 |
| **Total** | | **9 por archivo → 72 con 8 archivos** |

Gran parte de ese overhead de creación de procesos es evitable.

### 🔴 H4 — Archivos intermedios innecesarios en disco
El Bloque 2 escribe 8 archivos `.montos` en disco solo para que el Bloque 3 los vuelva a leer. Esto añade I/O de escritura + lectura evitable, ensucia el directorio de datos y puede dejar residuos entre corridas.

### 🔴 H5 — Bug de robustez en la acumulación de montos
La suma inicializa `suma=0` y luego hace `echo "$suma + $parcial" | bc`. Si `$parcial` viene vacío (archivo sin coincidencias o error previo), `bc` recibe una expresión inválida (`0 + `) y produce **`Parse error: bad token`**, dejando la **suma total vacía**. Reproducido en la ejecución real. No hay validación de entradas vacías ni manejo de errores.

### 🟡 H6 — Ausencia total de logging y trazabilidad
No hay marcas de tiempo, niveles de log, ni registro de qué archivo se procesó ni cuánto tardó. Ante un fallo en producción es imposible saber dónde y por qué ocurrió.

### 🔴 H7 — Sin manejo de errores ni `set` defensivo
No usa `set -euo pipefail`. Si un archivo no existe, si el glob `*.csv` no encuentra nada, o si un comando falla a mitad del pipeline, el script continúa silenciosamente y produce resultados incorrectos sin señalarlo.

### 🟡 H8 — Parsing frágil de CSV
Se asume que el monto es la columna 4 y que no hay comas dentro de los campos ni comillas. Con CSV reales (campos entrecomillados, separadores en el dato) `awk -F','` daría resultados erróneos.

### 🟡 H9 — Gestión de permisos manual
Los scripts requieren `chmod +x` manual y no declaran/verifican permisos de lectura sobre los datos ni de escritura sobre la salida. En un entorno automatizado esto es una fuente común de fallos silenciosos.

---

## 4. Resumen de limitaciones

| # | Limitación | Impacto | Severidad |
|---|------------|---------|-----------|
| H1 | Ejecución secuencial | No escala con núcleos; tiempo lineal | Alta |
| H2 | Múltiples pases de lectura | ~3× I/O de lectura innecesario | Alta |
| H3 | UUOC / cadenas largas | Overhead de ~72 procesos | Media |
| H4 | Intermedios en disco | I/O evitable + residuos | Alta |
| H5 | Bug en suma con `bc` | Resultado incorrecto/vacío | Alta |
| H6 | Sin logging | Nula trazabilidad | Media |
| H7 | Sin manejo de errores | Fallos silenciosos | Alta |
| H8 | Parsing CSV frágil | Datos erróneos con CSV reales | Media |
| H9 | Permisos manuales | Fallos en automatización | Baja |

---

## 5. Recomendaciones (insumo para la Fase 2)

1. **Paralelizar** el procesamiento por archivo con `xargs -P`, `parallel` o jobs de shell, aprovechando todos los núcleos (aborda H1).
2. **Un solo pase por archivo:** un único `awk` que a la vez filtre `APROBADA`, cuente y acumule montos, eliminando lecturas repetidas y los intermedios `.montos` (aborda H2, H3, H4).
3. **Eliminar UUOC:** pasar el archivo directo a `awk`/`grep` en vez de `cat |` (aborda H3).
4. **Acumular en `awk`** en lugar de `bc` por iteración, evitando el bug de expresión vacía y el coste de invocar `bc` repetidamente (aborda H5).
5. **Añadir logging** con timestamps, y **`set -euo pipefail`** más validación de que existen archivos y son legibles (aborda H6, H7, H9).
6. **Parsing CSV robusto** o, si el volumen lo justifica, mover la lógica a una herramienta que entienda CSV correctamente (aborda H8).
7. **Definir una métrica de comparación** (tiempo real, procesos lanzados, I/O) para validar la mejora en la Fase 3.

---

## 6. Cómo reproducir este análisis

```bash
cd analisis_sistema_actual/sistema_actual
chmod +x generar_datos.sh procesar_datos.sh
./generar_datos.sh 8 50000        # genera el dataset de muestra
/usr/bin/time -p ./procesar_datos.sh   # mide el sistema actual
```
