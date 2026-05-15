#!/usr/bin/env bash
set -euo pipefail

echo "== AI PR Review Action =="
echo "Model: ${INPUT_MODEL}"
echo "Diff file: ${INPUT_DIFF_FILE}"
echo "Output file: ${INPUT_OUTPUT_FILE}"
echo "Run tests: ${INPUT_RUN_TESTS}"
echo "Post comment: ${INPUT_POST_COMMENT}"

if [ ! -f "${INPUT_DIFF_FILE}" ]; then
  echo "Diff file not found: ${INPUT_DIFF_FILE}" >&2
  exit 1
fi

mkdir -p "$(dirname "${INPUT_OUTPUT_FILE}")"

TEST_RESULT_FILE="test-result.txt"
PROMPT_FILE="ai-review-prompt.txt"

if [ "${INPUT_RUN_TESTS}" = "true" ]; then
  echo "== Running tests =="
  set +e
  go test ./... > "${TEST_RESULT_FILE}" 2>&1
  TEST_EXIT_CODE=$?
  set -e

  echo "Tests exit code: ${TEST_EXIT_CODE}"
else
  echo "Tests disabled"
  TEST_EXIT_CODE=0
  echo "Tests were not executed." > "${TEST_RESULT_FILE}"
fi

DEFAULT_PROMPT='Ты AI code review agent.

Проанализируй diff pull request.
Найди только реальные проблемы:
- баги;
- race condition;
- security issues;
- сломанную обратную совместимость;
- ошибки обработки ошибок;
- проблемы с тестами;
- очевидные архитектурные риски.

Не придумывай проблемы.
Если критичных замечаний нет — напиши кратко, что серьезных проблем не найдено.

Формат ответа:
## AI Review

### Summary

### Findings

Для каждого замечания:
- severity: critical/high/medium/low
- file
- line если понятно
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

echo "== Prompt prepared =="
wc -c "${PROMPT_FILE}" || true

case "${INPUT_MODEL}" in
  qwen)
    echo "== Running qwen =="
    qwen < "${PROMPT_FILE}" > "${INPUT_OUTPUT_FILE}"
    ;;

  opencode)
    echo "== Running opencode =="
    opencode run --model "${OPENCODE_MODEL:-}" "$(cat "${PROMPT_FILE}")" > "${INPUT_OUTPUT_FILE}"
    ;;

  *)
    echo "Unsupported model: ${INPUT_MODEL}" >&2
    echo "Supported models: qwen, opencode" >&2
    exit 1
    ;;
esac

echo "== Review generated =="
cat "${INPUT_OUTPUT_FILE}"

REVIEW_SUMMARY="$(head -n 20 "${INPUT_OUTPUT_FILE}" | tr '\n' ' ' | cut -c1-500)"

{
  echo "review_file=${INPUT_OUTPUT_FILE}"
  echo "review_summary=${REVIEW_SUMMARY}"
} >> "${GITHUB_OUTPUT}"

if [ "${INPUT_POST_COMMENT}" = "true" ]; then
  echo "== Posting comment =="

  if [ -z "${INPUT_API_BASE_URL}" ]; then
    echo "api_base_url is required when post_comment=true" >&2
    exit 1
  fi

  if [ -z "${INPUT_REPOSITORY}" ]; then
    echo "repository is required when post_comment=true" >&2
    exit 1
  fi

  if [ -z "${INPUT_PR_NUMBER}" ]; then
    echo "pr_number is required when post_comment=true" >&2
    exit 1
  fi

  TOKEN="${GITVERSE_TOKEN:-${GITEA_TOKEN:-}}"

  if [ -z "${TOKEN}" ]; then
    echo "GITVERSE_TOKEN or GITEA_TOKEN is required when post_comment=true" >&2
    exit 1
  fi

  COMMENT_BODY="$(jq -Rs . < "${INPUT_OUTPUT_FILE}")"

  curl -sS -X POST \
    "${INPUT_API_BASE_URL}/repos/${INPUT_REPOSITORY}/issues/${INPUT_PR_NUMBER}/comments" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.gitverse.object+json;version=1" \
    -d "{\"body\": ${COMMENT_BODY}}"
fi
