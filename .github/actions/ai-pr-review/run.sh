#!/usr/bin/env bash
set -euo pipefail

echo "== Qwen PR Review Action =="

echo "Repository: ${INPUT_REPOSITORY}"
echo "PR number: ${INPUT_PR_NUMBER}"
echo "Base ref: ${INPUT_BASE_REF}"
echo "Head ref: ${INPUT_HEAD_REF}"
echo "Diff file: ${INPUT_DIFF_FILE}"
echo "Changed files file: ${INPUT_CHANGED_FILES_FILE}"
echo "Output file: ${INPUT_OUTPUT_FILE}"
echo "Run Go checks: ${INPUT_RUN_GO_CHECKS}"
echo "Post comment: ${INPUT_POST_COMMENT}"

if [ -z "${YANDEX_API_KEY:-}" ]; then
  echo "YANDEX_API_KEY is required. Add it to GitHub Secrets and pass it via env." >&2
  exit 1
fi

if [ ! -f "${INPUT_DIFF_FILE}" ]; then
  echo "Diff file not found: ${INPUT_DIFF_FILE}" >&2
  exit 1
fi

mkdir -p "$(dirname "${INPUT_OUTPUT_FILE}")"
mkdir -p .qwen

echo "== Create Qwen settings =="

python3 - <<'PY'
import json
import os
from pathlib import Path

model_id = os.environ["INPUT_MODEL_ID"]
base_url = os.environ["INPUT_BASE_URL"]

settings = {
    "modelProviders": {
        "openai": [
            {
                "id": model_id,
                "name": "Qwen3 235B (Yandex AI Studio)",
                "envKey": "YANDEX_API_KEY",
                "baseUrl": base_url,
                "generationConfig": {
                    "timeout": 120000,
                    "maxRetries": 2,
                    "contextWindowSize": 128000,
                    "samplingParams": {
                        "temperature": 0.3,
                        "max_tokens": 8192,
                    },
                },
            }
        ]
    },
    "$version": 3,
    "model": {
        "name": model_id,
    },
    "security": {
        "auth": {
            "selectedType": "openai",
        },
    },
}

Path(".qwen/settings.json").write_text(
    json.dumps(settings, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

echo "== Build Qwen prompt =="

python3 - <<'PY'
import os
from pathlib import Path

repository = os.environ.get("INPUT_REPOSITORY", "")
pr_number = os.environ.get("INPUT_PR_NUMBER", "")
base_ref = os.environ.get("INPUT_BASE_REF", "")
head_ref = os.environ.get("INPUT_HEAD_REF", "")
diff_file = os.environ["INPUT_DIFF_FILE"]
changed_files_file = os.environ.get("INPUT_CHANGED_FILES_FILE", "")
run_go_checks = os.environ.get("INPUT_RUN_GO_CHECKS", "true")
extra_prompt = os.environ.get("INPUT_EXTRA_PROMPT", "").strip()

diff = Path(diff_file).read_text(encoding="utf-8", errors="replace")

if changed_files_file and Path(changed_files_file).exists():
    changed_files = Path(changed_files_file).read_text(encoding="utf-8", errors="replace")
else:
    changed_files = "changed-files.txt not found."

go_checks_text = """
6. Запусти проверки:
   - go test ./...
   - go vet ./...
   Если команда не может быть выполнена, объясни почему.
7. Сравни вывод CLI-команд с анализом diff.
""" if run_go_checks == "true" else """
6. Go-проверки не запускай, если явно не нужно для анализа.
"""

prompt = f"""Ты — строгий, но прагматичный Go code reviewer.

Проверь Pull Request.

Repository: {repository}
PR: #{pr_number}
Base branch: {base_ref}
Head branch: {head_ref}

Ниже дан diff текущей ветки PR относительно целевой ветки PR.
Но НЕ ограничивайся только diff.

Обязательно используй доступные CLI tools, чтобы проверить изменения в контексте репозитория:

1. Посмотри структуру проекта.
2. Прочитай go.mod, если это Go-проект.
3. Прочитай изменённые файлы из diff.
4. Прочитай связанные файлы, которые импортируются или используются изменённым кодом.
5. Найди определения вызываемых функций и типов.
{go_checks_text}

Важно:
- Не изменяй файлы.
- Не делай commit.
- Не делай push.
- Не исправляй код автоматически.
- Твоя задача — только review.
- Не выдумывай проблемы, которых нет.
- Если проблема подтверждается компиляцией или CLI-командой, явно напиши это.
- Если PR не компилируется, итоговый риск должен быть high.
- Если есть несколько compile errors, объедини их в одну группу "Код не компилируется".
- В разделе "Что проверил через CLI" не перечисляй внутренние tool names вроде read_file, grep_search, list_directory.
- Пиши человечески: "прочитал go.mod", "запустил go test ./...", "проверил import path".

{extra_prompt}

Ответь по-русски в формате:

## Краткое резюме

## Что проверил через CLI

## Найденные проблемы

Для каждой проблемы укажи:
- severity: low / medium / high
- file: путь к файлу
- line: примерная строка, если понятно
- issue: что не так
- evidence: чем подтверждается
- recommendation: что исправить

## Что проверить тестами

## Итоговый риск

low / medium / high

Changed files:

```text
{changed_files}
