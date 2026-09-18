#!/usr/bin/env python3
"""Actualiza el tag de imagen de cada servicio dentro de un values-*.yaml del
chart sa-platform, sin reescribir el resto del archivo (a diferencia de un
round-trip con yq, que reformatea el YAML completo y borra líneas en blanco,
generando diffs de PR ruidosos que esconden el cambio real).

Uso: bump-image-tag.py <ruta/values-azure.yaml> <nuevo-tag>
"""

import re
import sys

TOP_LEVEL_SERVICES = ["api-gateway", "auth", "catalog", "orders", "notifications"]
CRONJOBS = ["cron1", "cron2"]

TAG_PATTERN = re.compile(r'tag:\s*"[^"]*"')


def replace_top_level_block(text: str, key: str, tag: str) -> str:
    pattern = re.compile(rf'(?ms)^{re.escape(key)}:\n(.*?)(?=^\S|\Z)')
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"No se encontró el bloque de nivel superior '{key}:'")
    block = match.group(0)
    new_block, count = TAG_PATTERN.subn(f'tag: "{tag}"', block, count=1)
    if count != 1:
        raise SystemExit(f"No se encontró 'tag:' dentro de '{key}:'")
    return text[: match.start()] + new_block + text[match.end() :]


def replace_cronjob_block(text: str, child: str, tag: str) -> str:
    parent_pattern = re.compile(r'(?ms)^cronjobs:\n(.*?)(?=^\S|\Z)')
    parent_match = parent_pattern.search(text)
    if not parent_match:
        raise SystemExit("No se encontró el bloque de nivel superior 'cronjobs:'")
    parent_block = parent_match.group(0)

    child_pattern = re.compile(rf'(?ms)^  {re.escape(child)}:\n(.*?)(?=^  \S|\Z)')
    child_match = child_pattern.search(parent_block)
    if not child_match:
        raise SystemExit(f"No se encontró 'cronjobs.{child}:'")
    child_block = child_match.group(0)
    new_child_block, count = TAG_PATTERN.subn(f'tag: "{tag}"', child_block, count=1)
    if count != 1:
        raise SystemExit(f"No se encontró 'tag:' dentro de 'cronjobs.{child}:'")

    new_parent_block = (
        parent_block[: child_match.start()] + new_child_block + parent_block[child_match.end() :]
    )
    return text[: parent_match.start()] + new_parent_block + text[parent_match.end() :]


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Uso: bump-image-tag.py <values.yaml> <tag>")
    path, tag = sys.argv[1], sys.argv[2]

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    for key in TOP_LEVEL_SERVICES:
        text = replace_top_level_block(text, key, tag)
    for child in CRONJOBS:
        text = replace_cronjob_block(text, child, tag)

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


if __name__ == "__main__":
    main()
