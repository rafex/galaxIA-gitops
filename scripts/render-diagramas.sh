#!/usr/bin/env bash
# Renderiza cada docs/diagramas/*.d2 a .svg (se versionan ambos: GitHub no
# renderiza D2 dentro de Markdown, así que los .md embeben el SVG).
#
# Requisito: d2 >= 0.9 (https://d2lang.com/) — macOS: brew install d2
# Uso: scripts/render-diagramas.sh [archivo.d2 ...]
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v d2 >/dev/null 2>&1; then
  echo "d2 no está instalado: https://d2lang.com/ (macOS: brew install d2)" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(docs/diagramas/*.d2)
fi

for src in "${files[@]}"; do
  out="${src%.d2}.svg"
  # ELK ordena mejor los contenedores anidados que dagre; tema 0 = claro,
  # pad chico para que el SVG no traiga márgenes enormes en GitHub.
  d2 --layout elk --theme 0 --pad 24 "$src" "$out"
  echo "✅ $out"
done
