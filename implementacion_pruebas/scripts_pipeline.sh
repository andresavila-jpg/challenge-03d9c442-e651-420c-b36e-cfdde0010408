#!/bin/bash

# Script para ejecutar comandos en paralelo utilizando xargs
cat input.txt | xargs -P 4 -n 1 grep "pattern"

# Script para automatizar tareas repetitivas
for file in *.txt; do
  awk '{print $1}' "$file" > "$file.processed"
done