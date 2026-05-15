#!/usr/bin/env bash
set -euo pipefail

echo "== AI PR Review Action =="
echo "Diff file: ${INPUT_DIFF_FILE}"
echo "Output file: ${INPUT_OUTPUT_FILE}"
echo "Run tests: ${INPUT_RUN_TESTS}"
echo "Post comment: ${INPUT_POST_COMMENT}"

if [ ! -f "${INPUT_DIFF_FILE}" ]; then
  echo "Diff file not found: ${INPUT_DIFF_FILE}" >&2
  exit 1
fi

echo "== Install dependencies =="
sudo apt-get update -y
sudo apt-get install -y jq

echo "== Install Qwen Code CLI =="
npm install --silent --no-audit --global "@qwen-code/qwen-code@${INPUT_QWEN_CLI_VERSION}"

echo "== Qwen version =="
qwen --version || true

mkdir -p "$(dirname "${INPUT_OUTPUT_FILE}")"

TEST_RESULT_FILE="test-result.txt"
PROMPT_FILE="ai-review-prompt.txt"
QWEN_JSON_FILE="qwen-output.json"
QWEN_ERR_FILE="qwen-error.log"

if [ "${INPUT_RUN_TESTS}" = "true" ]; then
  echo "== Running tests =="
  set +e
  go test ./... > "${TEST_RESULT_FILE}" 2>&1
  TEST_EXIT_CODE=$?
  set -e

  echo "Tests exit code: ${TEST_EXIT_CODE}"
else
  TEST_EXIT_CODE=0
  echo "Tests were not executed." > "${TEST_RESULT_FILE}"
fi

DEFAULT_PROMPT='Ты AI code review agent.

Проанализируй PR diff.
Найди только реальные проблемы:
- баги;
- проблемы безопасности;
- ошибки обработки ошибок;
- race condition;
- проблемы совместимости API;
- проблемы с тестами;
- плохую обработку edge cases.

Не придумывай замечания.
Если серьёзных проблем нет, так и напиши.

Ответ дай в Markdown:

## AI Review

### Summary

### Findings

Для каждого замечания:
- severity: critical/high/medium/low
- file
- line, если понятно
- problem
- suggestion
'

if [ -n "${INPUT_PROMPT}" ]; then
  REVIEW_PROMPT="${INPUT_PROMPT}"
else
  REVIEW_PROMPT="${DEFAULT_PROMPT}"
fi

cat > "${PROMPT_FILE}" <<EOF
${REVIEW_PROMPT}

---

PR diff:

\`\`\`diff
$(cat "${INPUT_DIFF_FILE}")
\`\`\`

---

Test result:

\`\`\`
$(cat "${TEST_RESULT_FILE}")
\`\`\`
EOF

echo "== Prompt size =="
wc -c "${PROMPT_FILE}" || true

echo "== Run Qwen Code =="

export OPENAI_API_KEY="${INPUT_OPENAI_API_KEY}"
export OPENAI_BASE_URL="${INPUT_OPENAI_BASE_URL}"
export OPENAI_MODEL="${INPUT_OPENAI_MODEL}"
export QWEN_CODE_UNATTENDED_RETRY=1
export SURFACE="GitHub"

set +e
qwen \
  --yolo \
  --prompt "$(cat "${PROMPT_FILE}")" \
  --channel=CI \
  --output-format json \
  > "${QWEN_JSON_FILE}" \
  2> "${QWEN_ERR_FILE}"

QWEN_EXIT_CODE=$?
set -e

if [ "${QWEN_EXIT_CODE}" -ne 0 ]; then
  echo "Qwen failed with exit code ${QWEN_EXIT_CODE}" >&2
  echo "== stderr =="
  cat "${QWEN_ERR_FILE}" || true
  exit "${QWEN_EXIT_CODE}"
fi

echo "== Parse Qwen output =="

if jq -e . "${QWEN_JSON_FILE}" >/dev/null 2>&1; then
  jq -r '
    [.[] | select(.type == "assistant")]
    | last
    | .message.content[]?
    | select(.type == "text")
    | .text
  ' "${QWEN_JSON_FILE}" > "${INPUT_OUTPUT_FILE}"
else
  echo "Qwen output is not valid JSON, saving raw output"
  cp "${QWEN_JSON_FILE}" "${INPUT_OUTPUT_FILE}"
fi

if [ ! -s "${INPUT_OUTPUT_FILE}" ]; then
  echo "Empty parsed review, saving raw output"
  cp "${QWEN_JSON_FILE}" "${INPUT_OUTPUT_FILE}"
fi

echo "== Review generated =="
cat "${INPUT_OUTPUT_FILE}"

REVIEW_SUMMARY="$(head -n 20 "${INPUT_OUTPUT_FILE}" | tr '\n' ' ' | cut -c1-500)"

{
  echo "review_file=${INPUT_OUTPUT_FILE}"
  echo "review_summary=${REVIEW_SUMMARY}"
} >> "${GITHUB_OUTPUT}"

if [ "${INPUT_POST_COMMENT}" = "true" ]; then
  echo "== Posting PR comment =="

  if [ -z "${INPUT_PR_NUMBER}" ]; then
    echo "pr_number is required when post_comment=true" >&2
    exit 1
  fi

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN is required when post_comment=true" >&2
    exit 1
  fi

  jq -n --arg body "$(cat "${INPUT_OUTPUT_FILE}")" '{body: $body}' > comment.json

  curl -fsS -X POST \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${INPUT_PR_NUMBER}/comments" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data @comment.json
fi
