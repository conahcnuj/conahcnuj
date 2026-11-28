#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and hands the same opencode session to the next
# model when the current model cannot complete the work. A failed round sets
# OPENCODE_ROUND_ENVIRONMENT, so the driver can tell "this provider is down"
# apart from "this model is not good enough". A round cut short by a provider
# rate limit sets OPENCODE_ROUND_RATE_LIMITED: opencode sits out its own
# retry backoff ("Rate limit exceeded. Please try again later.") with nothing
# on stdout, so the driver stops the process and moves on without waiting
# (#155).
#
# opencode's own output is a stream of JSON events; lib/opencode-render.sh
# turns it into the driver's run log, one context header per block. The stream
# is filtered as it arrives instead of being dumped at the end, so the SHA /
# branch / diff in every header describe the moment that block was produced.

set -euo pipefail

# Not HERE: bin/conahcnuj.sh owns that name and resolves ../gh-app with it, so
# overwriting it here would break the driver's api-commit.sh / setup-git.sh
# paths. Sourcing a lib must not clobber the caller's variables.
# Normalize the offline-test flag (CONAHCNUJ_TEST_MODE canonical, TEST_MODE
# legacy alias).
: "${CONAHCNUJ_TEST_MODE:=${TEST_MODE:-0}}"
export CONAHCNUJ_TEST_MODE

OPENCODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_RENDER_SH="${OPENCODE_LIB_DIR}/opencode-render.sh"

# Whether the round that just finished died on an environment error: the
# provider is unreachable, its credentials were rejected, or the transport
# broke. Anything else (a model that cannot do the work) leaves this "false".
# opencode_run sets it for every round so the driver can tell "this provider
# is down" apart from "this model is not good enough" -- only the former says
# anything about the provider's other models (#149).
OPENCODE_ROUND_ENVIRONMENT="false"

# Whether the round that just finished died because the model itself is gone:
# the provider reports it as deprecated, removed, unavailable or otherwise
# unknown. Unlike an environment error this is specific to one model, so the
# driver remembers only that model as dead (never the whole provider) and skips
# it in later rounds (#209). opencode_run sets it for every round.
OPENCODE_ROUND_MODEL_GONE="false"

# Whether the round that just finished died because the provider's
# account-level quota or billing is exhausted ("spending-limit", out of
# credits, ...). Every model of the same provider bills the same account, so
# unlike a transient rate limit no other model of that provider can succeed:
# the driver gives up on the whole provider (#276). opencode_run sets it for
# every round.
OPENCODE_ROUND_QUOTA_EXHAUSTED="false"

# Whether the round that just finished was cut short by a provider rate limit.
# opencode retries "Rate limit exceeded. Please try again later." with its own
# exponential backoff, emitting nothing usable on stdout for minutes, so the
# driver kills the process and tries the next model at once. Not an environment
# error: the provider works, its quota is simply exhausted for now, so its
# other models stay in the pool.
OPENCODE_ROUND_RATE_LIMITED="false"

# Whether the round that just finished died because opencode exceeded the
# remaining driver time budget and was stopped (status 124): "opencode exceeded
# the remaining driver time budget; stopping this model." Not an environment
# error and not a model that is gone: the run is out of time, so no further
# model can make progress and the driver must stop instead of handing off.
# opencode_run sets it for every round.
OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED="false"

# Whether the round that just finished died because the model asked for input
# this non-interactive run cannot provide (e.g. a "Web Search" confirmation
# form opencode cancels in --auto mode): "Cancelled a request for input this
# run cannot answer: ...". Not an environment error and not a model that is
# gone: the provider works and the model may be fine, but it reached for an
# interactive tool that is unavailable here, so its other models stay in the
# pool and the next model is tried. opencode_run sets it for every round.
OPENCODE_ROUND_INPUT_CANCELLED="false"

# Whether the round that just finished died because opencode itself was
# terminated by a signal (SIGTERM/SIGINT from an external pkill, a CI
# timeout, ...). Not an environment error and not a model that is gone.
OPENCODE_ROUND_SIGNAL_KILLED="false"

# Probe whether a candidate opencode binary actually runs. Under WSL with
# interop unavailable a Windows binary is "found" (it sits on a /mnt path and
# command -v / -f succeed) but executing it fails with "Exec format error", so
# existence alone is not enough.
opencode_runs() {
  local c="${1}"
  "${c}" --version >/dev/null 2>&1
}

# Resolve the opencode executable, even when it is installed in a location that
# is not on PATH (e.g. ~/.opencode/bin under WSL, or Windows scoop under a
# WSL mount). Prints the path and returns 0 on success, 1 when opencode cannot
# be found.
opencode_command() {
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf 'opencode\n'
    return 0
  fi
  local c candidate
  for c in opencode opencode.exe opencode.cmd; do
    if command -v "${c}" >/dev/null 2>&1 && opencode_runs "${c}"; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  # Linux / opencode installer locations.
  for candidate in \
    "${HOME}/.opencode/bin/opencode" \
    /root/.opencode/bin/opencode \
    /home/*/.opencode/bin/opencode \
    "${HOME}/.local/bin/opencode" \
    /usr/local/bin/opencode \
    /usr/bin/opencode ; do
    for c in ${candidate}; do
      if [[ -n "${c}" && -f "${c}" ]] && opencode_runs "${c}"; then
        printf '%s\n' "${c}"
        return 0
      fi
    done
  done
  # Windows installs reached from WSL (/mnt/<drive>) and from Git Bash (/<drive>).
  for candidate in \
    /mnt/[a-zA-Z]/Users/*/.opencode/bin/opencode \
    /[a-zA-Z]/Users/*/.opencode/bin/opencode \
    /mnt/[a-zA-Z]/Users/*/scoop/shims/opencode.exe \
    /[a-zA-Z]/Users/*/scoop/shims/opencode.exe \
    /mnt/[a-zA-Z]/Users/*/scoop/apps/opencode/*/opencode.exe \
    /[a-zA-Z]/Users/*/scoop/apps/opencode/*/opencode.exe \
    /mnt/[a-zA-Z]/Users/*/AppData/Local/Programs/opencode/opencode.exe \
    /[a-zA-Z]/Users/*/AppData/Local/Programs/opencode/opencode.exe ; do
    for c in ${candidate}; do
      if [[ -n "${c}" && -f "${c}" ]] && opencode_runs "${c}"; then
        printf '%s\n' "${c}"
        return 0
      fi
    done
  done
  echo "opencode: no runnable opencode found (under WSL this usually means interop is unavailable; run the driver under Git Bash instead)" >&2
  return 1
}

# opencode major version: "v1" (0.x.x) or "v2" (1.x.x and 2.x). Best-effort:
# when --version cannot be parsed or opencode cannot be located, assume v2,
# so a machine that only has v2 keeps working.
# Cached in OPENCODE_VERSION_CACHE so opencode --version is only run once.
# Probes the same executable opencode_run() will use, including installs that
# are reachable only through opencode_command()'s fallback paths.
OPENCODE_VERSION_CACHE=""
# The yargs-style CLI shipped in opencode 0.x/1.x (including 1.19.x) expects
# UPPERCASE --log-level values ("DEBUG"/"INFO"/"WARN"/"ERROR"), while the 2.x
# CLI expects lowercase ("debug"/"info"/"warn"/...). Sending a lowercase value
# to 1.x makes yargs reject the flag and print opencode's help instead of
# running, so opencode_version() records which case to use and
# opencode_run_args() builds a value the backend actually accepts (#1043).
OPENCODE_LOG_LEVEL_UPPER=""
opencode_version() {
  local label="" ver="" major="" oc="" probe_done="false"
  if [[ -n "${OPENCODE_VERSION:-}" ]]; then
    label="${OPENCODE_VERSION}"
  elif [[ -n "${OPENCODE_VERSION_CACHE:-}" ]]; then
    label="${OPENCODE_VERSION_CACHE}"
  fi

  # A version env override gives the v1/v2 label but not the --log-level
  # case: both 1.x (uppercase) and 2.x (lowercase) are labelled v2, and an
  # invalid value makes yargs print opencode's help and exit (#1043). Probe
  # the actual backend once and remember which case it accepts. The installed
  # backend may be a Windows .cmd shim, so check that name too.
  if [[ -z "${OPENCODE_LOG_LEVEL_UPPER:-}" && "${OPENCODE_TEST_MODE:-0}" != "1" ]]; then
    # Use the same resolution as opencode_run(): a Windows .cmd shim or an
    # install outside PATH must be probed too, otherwise the driver would
    # send lowercase levels to a 1.x CLI and get its help text (#1043).
    oc="$(command -v opencode 2>/dev/null || command -v opencode.exe 2>/dev/null || command -v opencode.cmd 2>/dev/null || true)"
    if [[ -z "${oc}" ]]; then
      oc="$(opencode_command 2>/dev/null || true)"
    fi
    if [[ -n "${oc}" ]]; then
      ver="$("${oc}" --version 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
      if [[ -n "${ver}" ]]; then
        major="${ver%%.*}"
        if [[ "${major}" -eq 0 || "${major}" -eq 1 ]]; then
          OPENCODE_LOG_LEVEL_UPPER="true"
        else
          OPENCODE_LOG_LEVEL_UPPER="false"
        fi
        probe_done="true"
      fi
    fi
    if [[ "${probe_done}" != "true" ]]; then
      OPENCODE_LOG_LEVEL_UPPER="false"
    fi
  fi
  # Do not default to false here: a test-mode call (which skips the probe)
  # must not leave a cached lowercase decision behind for a later real run.
  # opencode_run_args() treats an unset value as lowercase.

  if [[ -n "${label}" ]]; then
    OPENCODE_VERSION_CACHE="${label}"
    printf '%s\n' "${label}"
    return 0
  fi

  # No env override and no cache: derive the label from the probe above.
  if [[ -z "${ver:-}" ]]; then
    label="v2"
  elif [[ "${major}" -eq 0 ]]; then
    label="v1"
  else
    label="v2"
  fi
  OPENCODE_VERSION_CACHE="${label}"
  printf '%s\n' "${label}"
}

# Build the `opencode run` argument list for the detected opencode major
# version. Results are left in the global array OPENCODE_RUN_ARGS.
#
# v2 (1.x/2.x): --auto --print-logs --thinking --format json --model ...[#variant] --session|--title --log-level -
# v1 (0.x.x): --model ... [--session|--title]  (v2-only flags omitted)
#
# v1 flag support is best-effort: confirm against a real v1 opencode before
# relying on it, since CI usually has only a 1.x/2.x backend.
opencode_run_args() {
  local model="${1}" session_id="${2:-}" effort_variant="${3:-}" version="${4:-}"
  # v2-only flags (--auto --format json --print-logs --thinking --log-level)
  # are added only for v2. v1 gets just --model and --session|--title.
  # --model stays contiguous with --auto --format json on v2 so mock-test
  # string matches still work.
  # The effort variant is not a separate flag in current opencode: it rides on
  # the model id as `provider/model#variant` (the CLI rejects --variant). See
  # issue #1037.
  if [[ "${version}" == "v2" ]]; then
    local cli_model="${model}"
    if [[ -n "${effort_variant}" ]]; then
      cli_model="${model}#${effort_variant}"
    fi
    OPENCODE_RUN_ARGS=(run --auto --format json --model "${cli_model}" --print-logs --thinking)
    # --print-logs defaults to INFO (~30 lines of boot chatter per model).
    # WARN keeps the diagnostics that matter; override to DEBUG when hunting a model.
    # opencode 1.x accepts only uppercase log levels; 2.x only lowercase.
    # Match the value to the detected CLI or yargs prints help and exits.
    local log_level="${CONAHCNUJ_OPENCODE_LOG_LEVEL:-warn}"
    if [[ "${OPENCODE_LOG_LEVEL_UPPER:-false}" == "true" ]]; then
      log_level="$(printf '%s' "${log_level}" | tr '[:lower:]' '[:upper:]')"
    fi
    OPENCODE_RUN_ARGS+=(--log-level "${log_level}")
  else
    OPENCODE_RUN_ARGS=(run --model "${model}")
  fi
  if [[ -n "${session_id}" ]]; then
    OPENCODE_RUN_ARGS+=(--session "${session_id}")
  else
    OPENCODE_RUN_ARGS+=(--title conahcnuj)
  fi
  # Newer opencode requires a message positional; "-" makes it read the
  # prompt from stdin (preserving the E2BIG-safe delivery). See issue #1035.
  # Only v2 needs the explicit "-" positional; v1 reads stdin by default and
  # an explicit "-" is not accepted (it surfaces the help text). See #1037.
  if [[ "${version}" == "v2" ]]; then
    OPENCODE_RUN_ARGS+=("-")
  fi
}

# List available models, one per line. Test mode: $MOCK_OPENCODE_MODELS.
opencode_get_models() {
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "${MOCK_OPENCODE_MODELS:-}"
    return 0
  fi
  local oc
  oc="$(opencode_command)" || return 1
  "${oc}" models 2>/dev/null | tr -d '\r' | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}


# Resolve the effort variant to pass to opencode (--variant) in this run, if any.
# Max effort mode only: CONAHCNUJ_MAX_EFFORT being non-empty (any value, i.e.
# the --max-effort flag or a truthy env) or CONAHCNUJ_EFFORT=max enables
# `--variant max`. Empty output means "use the model's default". Arbitrary
# effort levels are intentionally not supported, so CONAHCNUJ_EFFORT accepts
# only "max" (case-insensitive).
opencode_effort_variant() {
  local max_effort="${CONAHCNUJ_MAX_EFFORT:-}"
  max_effort="${max_effort#"${max_effort%%[![:space:]]*}"}"
  max_effort="${max_effort%"${max_effort##*[![:space:]]}"}"
  if [[ -n "${max_effort}" ]]; then
    printf 'max'
    return 0
  fi
  local effort="${CONAHCNUJ_EFFORT:-}"
  effort="${effort#"${effort%%[![:space:]]*}"}"
  effort="${effort%"${effort##*[![:space:]]}"}"
  case "${effort}" in
    [Mm][Aa][Xx]) printf 'max' ;;
  esac
}

# What every round shares, whatever the model or the stage: the point of the run
# and who does what. This is deliberately one short paragraph. A model once read
# a long list of instructions (banned commands, warnings that a message is not a
# deliverable) as the task itself and answered with a commit message and a pull
# request title instead of writing code, so the paragraph states the division of
# labour and stops there: telling the coding agent how to work gets in its way.
opencode_agent_contract() {
  cat <<'EOF'
This run takes the issue (or the pull request being resumed) to the owner's approval. Your part is the change in the working tree and the commit: implement it, run the repository's own validation, and commit with `git vc`. The driver names the branch, creates the pull request and the review request once you are done.
EOF
}

# Build the implementation prompt for a single model run.
# Args: issue_title issue_body [extra_context] [collected_context]
# A fresh implementation round (no extra_context) also lets the agent choose
# the feature branch via .branch-name; follow-up rounds (fix constraints,
# review feedback) keep the existing branch, so the instruction is omitted.
# collected_context is what the driver gathered deterministically before this
# run (unresolved review threads of a resumed PR, README.md / AGENTS.md, ...)
# and is appended as plain data: the contract below stays the only place that
# says anything about how to work, so adding material must not read as another
# instruction.
opencode_build_prompt() {
  local issue_title="${1}" issue_body="${2}" extra_context="${3:-}" collected_context="${4:-}"
  local prompt
  prompt="Issue: ${issue_title}

${issue_body}"
  if [[ -n "${collected_context}" ]]; then
    prompt="${prompt}

Collected context:
${collected_context}"
  fi
  if [[ -n "${extra_context}" ]]; then
    prompt="${prompt}

Additional context:
${extra_context}"
  fi
  prompt="${prompt}

$(opencode_agent_contract)

Commit your changes with \`git vc\` (do not use \`git commit\`); the driver creates the pull request and the review request once you are done.

If you leave any changes uncommitted, write their commit message (one line, no more than 72 characters) to .commit-msg in the repository root so the driver can commit them; once everything is committed there is no .commit-msg to write."
  if [[ -z "${extra_context}" ]]; then
    prompt="${prompt}

If you want to choose the feature branch name, write your preferred branch name (one line, e.g. feature/my-work) to the file .branch-name in the repository root; if you leave the file absent, the driver picks a name for you."
  fi
  printf '%s\n' "${prompt}"
}

opencode_build_handoff_prompt() {
  local previous_model="${1}"
  # The literal backticks are prompt text, not command substitutions.
  # shellcheck disable=SC2016
  printf 'You are taking over unfinished work from model %s because it could not complete the task. Continue this same session and preserve all work already present in the working tree. Inspect the current progress, finish every remaining requirement, run the relevant validation, and commit with `git vc`. Do not restart from scratch or discard existing work. Hidden (resolved) conversations are already settled; hidden conversations are resolved (treat hidden conversations as resolved); do not re-read them. If you leave any changes uncommitted, write their commit message (one line, no more than 72 characters) to .commit-msg in the repository root so the driver can commit them; once everything is committed there is no .commit-msg to write.\n\n%s\n' "${previous_model}" "$(opencode_agent_contract)"
}

# True when the round's JSON event stream carries an environment error
# (provider unreachable, credentials rejected, transport broken).
# Args: output_file [err_file]. Matched against the raw error-event lines,
# message and error name together, so no JSON value extraction is needed:
# those messages embed quoted JSON of their own ("xAI token refresh failed
# (400): {\"error\":...}"), which a value extractor would cut at the first
# escaped quote. Text events are ignored on purpose -- a model that merely
# writes the words in its answer is not an environment failure.
# opencode's own log (err_file, --print-logs) names the failure the same way
# the JSON error event does ("Upstream request failed: Endpoint is
# unavailable."). A round the watchdog cuts short mid-retry never emits the
# final JSON error event, so without the log the outage would read as a quota
# rate limit and the dead provider would stay in the pool (#276). Only the
# log's own error lines count, for the same reason text events do not.
# A model-level condition ("Model is unavailable", a model that has been
# deprecated or does not exist) is NOT an environment error: it says nothing
# about the provider's other models, so it must not drop the whole provider.
# Such lines are filtered out before the environment patterns are matched, so
# even a generic wrapper message ("Upstream request failed: Model is
# unavailable.") that embeds both reads as the model being the problem. The
# same goes for quota/billing exhaustion, which has its own classifier below.
opencode_round_is_environment() {
  local file="${1}" err_file="${2:-}"
  [[ -f "${file}" ]] || return 1
  local signals
  signals="$(grep -F '"type":"error"' "${file}" 2>/dev/null || true)"
  if [[ -n "${err_file}" && -f "${err_file}" ]]; then
    signals+=$'\n'"$(grep -E 'level=ERROR' "${err_file}" 2>/dev/null || true)"
  fi
  printf '%s\n' "${signals}" |
    grep -Evi 'model .*is unavailable|has been deprecated|model not found|no such model|unknown model|does not exist|not (available|supported)|requires authentication|no endpoints|trailing whitespace|whitespace|Model unavailable|provider\.no-route|provider no route|no route to (this )?model' |
    grep -Evi 'rate limit|rate_limit|too many requests|please try again later|quota exceeded|usage limit|resource_exhausted|(^|[^0-9])429([^0-9]|$)' |
    grep -Evi 'spending.limit|out of credits|exceeded your current quota|insufficient (credits|quota|funds)|payment required|billing|delinquent' |
    grep -Eiq 'token refresh failed|invalid_grant|cannot connect to api|unable to connect|was there a typo in the url|transport error|fetch failed|endpoint is unavailable|upstream request failed|upstream error|service temporarily overloaded|socket connection|providerautherror|authenticationerror|unauthorized|enotfound|econnrefused|econnreset|etimedout|getaddrinfo|copilot[._-]?integration|integration[._-]?id|does not match (the )?github app'
}

# True when the round carries provider account-level quota/billing
# exhaustion ("spending-limit", out of credits, ...): the account cannot pay
# for any model of that provider, so no other model of the same provider can
# succeed and the driver gives up on the whole provider (#276). Unlike the
# transient quota wording a rate limit retries through ("quota exceeded",
# "usage limit", HTTP 429), these errors do not clear by switching models or
# waiting out a backoff. Args: output_file [err_file]. Like
# opencode_round_is_environment, text events are ignored on purpose: a model
# that merely writes the words is not quota-exhausted.
opencode_round_is_quota_exhausted() {
  local output_file="${1}" err_file="${2:-}"
  local pattern='spending.limit|out of credits|exceeded your current quota|insufficient (credits|quota|funds)|payment required|billing|delinquent|insufficient_quota|quota_exceeded|hard_limit|credit_balance'
  if [[ -f "${output_file}" ]] && grep -F '"type":"error"' "${output_file}" 2>/dev/null | grep -Eiq "${pattern}"; then
    return 0
  fi
  if [[ -n "${err_file}" && -f "${err_file}" ]] && grep -Eiq "${pattern}" "${err_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# True when the round was stopped because it exceeded the remaining driver time
# budget: opencode is launched under `timeout` and killed when the budget runs
# out, printing "opencode exceeded the remaining driver time budget; stopping
# this model." (status 124). Args: output_file [err_file].
opencode_round_is_time_budget_exhausted() {
  local output_file="${1}" err_file="${2:-}"
  if [[ -f "${output_file}" ]] && grep -F "opencode exceeded the remaining driver time budget" "${output_file}" 2>/dev/null | grep -vF '"type":"text"' | grep -q .; then
    return 0
  fi
  if [[ -n "${err_file}" && -f "${err_file}" ]] && grep -Fq "opencode exceeded the remaining driver time budget" "${err_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# True when the round's error stream says the model itself is permanently gone:
# the provider reports it as deprecated, removed, unavailable or otherwise
# unknown. These are exactly the model-level lines opencode_round_is_environment
# filters out, so a gone model never drops its whole provider. The driver uses
# this to remember just that model as dead and skip it in later rounds (#209).
opencode_round_is_model_gone() {
  local file="${1}"
  [[ -f "${file}" ]] || return 1
  grep -F '"type":"error"' "${file}" 2>/dev/null |
    grep -Eiq 'model .*is unavailable|has been deprecated|is deprecated|no longer supported|model not found|no such model|unknown model|does not exist|Model unavailable|provider\.no-route|provider no route|no route to (this )?model'
}

# True when the round carries a provider rate limit: the exact message opencode
# retries for minutes ("Rate limit exceeded. Please try again later."), its
# providers' HTTP 429 wording, or the error-event lines on stdout. opencode
# swallows the rate limit into its own retry loop while --format json prints
# nothing, but the retry/error diagnostics go to opencode's own stderr, and
# --print-logs (always passed) streams that stderr into this process. Checking
# both keeps the early-abort working even when the error event only appears on
# stdout as the round finally gives up. Like opencode_round_is_environment,
# text events are ignored on purpose: a model that merely writes the words is
# not rate limited (#155).
opencode_round_is_rate_limited() {
  local output_file="${1}" err_file="${2:-}"
  local pattern='rate limit|rate_limit|too many requests|too_many_requests|please try again later|retry-after|retry after|quota exceeded|usage limit|resource_exhausted|rate_limit_exceeded|\b429\b'
  if [[ -f "${output_file}" ]] && grep -F '"type":"error"' "${output_file}" 2>/dev/null | grep -Eiq "${pattern}"; then
    return 0
  fi
  if [[ -n "${err_file}" && -f "${err_file}" ]] && grep -Eiq "${pattern}" "${err_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# True when the round died because the model asked for input this
# non-interactive run cannot provide: opencode cancels the form and fails the
# round with "Cancelled a request for input this run cannot answer: <title>"
# (a Web Search confirmation is the usual trigger). Args: output_file [err_file].
# Like the other detectors, text events are ignored on purpose: a model that
# merely writes the words is not a failure (#155).
opencode_round_is_input_cancelled() {
  local output_file="${1}" err_file="${2:-}"
  local pattern='Cancelled a request for input this run cannot answer|cannot answer: .* (Web Search|web search)'
  if [[ -f "${output_file}" ]] && grep -F '"type":"error"' "${output_file}" 2>/dev/null | grep -Eiq "${pattern}"; then
    return 0
  fi
  if [[ -n "${err_file}" && -f "${err_file}" ]] && grep -Eiq "${pattern}" "${err_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}



# Aliases: different wordings the driver / tests may use for the same condition.
opencode_round_is_cancelled_input() { opencode_round_is_input_cancelled "$@"; }
opencode_round_is_input_request_cancelled() { opencode_round_is_input_cancelled "$@"; }
opencode_round_is_request_for_input_cancelled() { opencode_round_is_input_cancelled "$@"; }

# Run opencode with a specific model and publish its session ID in
# OPENCODE_SESSION_ID so a later model can continue the same conversation.
# Args: title body workdir model [extra_context] [session_id] [previous_model] [collected_context]
# A session handoff reuses the conversation the first prompt already carried
# the collected context in, so only the fresh-prompt branch below gets it.
opencode_run() {
  local issue_title="${1}" issue_body="${2}" workdir="${3}" model="${4}" extra_context="${5:-}" session_id="${6:-}" previous_model="${7:-}" collected_context="${8:-}" prompt_override="${9:-}"
  local prompt
  OPENCODE_ROUND_ENVIRONMENT="false"
  OPENCODE_ROUND_MODEL_GONE="false"
  OPENCODE_ROUND_QUOTA_EXHAUSTED="false"
  OPENCODE_ROUND_RATE_LIMITED="false"
  OPENCODE_ROUND_INPUT_CANCELLED="false"
  OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED="false"
  OPENCODE_ROUND_SIGNAL_KILLED="false"
  # A caller may supply the whole prompt (the feedback reply round does): it
  # then takes precedence over both the hand-off and the implementation prompt
  # so the reply instructions and thread ids actually reach the model.
  if [[ -n "${prompt_override}" ]]; then
    prompt="${prompt_override}"
  elif [[ -n "${session_id}" ]]; then
    prompt="$(opencode_build_handoff_prompt "${previous_model:-unknown}")"
  else
    prompt="$(opencode_build_prompt "${issue_title}" "${issue_body}" "${extra_context}" "${collected_context}")"
    if [[ -n "${previous_model}" ]]; then
      prompt="${prompt}"$'\n\n'"Model ${previous_model} did not finish this work through its session. Continue from the current working tree without discarding existing changes."
    fi
  fi

  echo "opencode: trying model ${model}" >&2

  # Make the App installation token available to the coding agent's shells. The
  # plugin injects GH_TOKEN through its shell.env hook when installed, but a
  # driver run (CI or a machine without the plugin) has no such injection, so
  # replies to review threads (which the agent posts itself) and any other
  # GitHub API call the agent makes would see an empty token. Export it here
  # from the same source the driver uses, so it is inherited by opencode's
  # child shells regardless of the plugin's state (#1311).
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" || "${CONAHCNUJ_TEST_MODE}" == "1" ]]; then
    # Override any ambient/stale value (mirrors the plugin, which always issues
    # the App token instead of trusting a pre-existing GH_TOKEN).
    GH_TOKEN="test-token"
    GITHUB_TOKEN="test-token"
  else
    # Always issue the App installation token, ignoring an ambient GH_TOKEN:
    # a stale/invalid ambient token must not survive into the agent's shells
    # (that is exactly what made `gh auth status` report an invalid token).
    local fetched_token
    fetched_token="$(bash "${OPENCODE_LIB_DIR}/../gh-app/get-token.sh" 2>/dev/null || true)"
    if [[ -n "${fetched_token}" ]]; then
      GH_TOKEN="${fetched_token}"
      GITHUB_TOKEN="${fetched_token}"
    else
      # No App token available: drop any ambient GH_TOKEN/GITHUB_TOKEN so a
      # stale/invalid token cannot survive into the agent's shells and make
      # `gh auth status` report an invalid token (issue #964).
      unset GH_TOKEN GITHUB_TOKEN
    fi
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN
  else
    unset GH_TOKEN
  fi
  # Keep GITHUB_TOKEN in sync so tools reading either name see the same token.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    if [[ -z "${GITHUB_TOKEN:-}" || "${GITHUB_TOKEN:-}" != "${GH_TOKEN}" ]]; then
      GITHUB_TOKEN="${GH_TOKEN}"
    fi
    export GITHUB_TOKEN
  else
    unset GITHUB_TOKEN
  fi

  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    local _mv
    _mv="$(opencode_effort_variant 2>/dev/null || true)"
    # Mock mode: print what `opencode run` would look like, using the same
    # version-aware arg construction as the real path. The fake opencode in
    # tests captures these args via OPENCODE_ARGS_FILE. Call opencode_version
    # directly so its log-level-case result is visible to opencode_run_args.
    opencode_version >/dev/null || true
    opencode_run_args "${model}" "${session_id:-}" "${_mv}" "${OPENCODE_VERSION_CACHE:-v2}"
    printf 'opencode %s %s\n' "${OPENCODE_RUN_ARGS[*]}" "${prompt}"
    OPENCODE_SESSION_ID="${MOCK_OPENCODE_SESSION_ID:-ses_mock}"
    export OPENCODE_SESSION_ID
    # MOCK_OPENCODE_ENV_ERROR lists the models whose round dies on an
    # environment error (it implies MOCK_OPENCODE_ERROR for those models).
    if [[ " ${MOCK_OPENCODE_ENV_ERROR:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_ENVIRONMENT="true"
    fi
    # MOCK_OPENCODE_DEPRECATED lists the models whose round dies because the
    # model itself is gone (deprecated / removed / unavailable). It implies
    # MOCK_OPENCODE_ERROR for those models, but is a model-level, not an
    # environment, failure: only that model is remembered as dead.
    if [[ " ${MOCK_OPENCODE_DEPRECATED:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_MODEL_GONE="true"
    fi
    # MOCK_OPENCODE_QUOTA lists the models whose round dies on provider
    # quota/billing exhaustion (it implies MOCK_OPENCODE_ERROR for those
    # models). Like an environment error it drops the whole provider (#276).
    if [[ " ${MOCK_OPENCODE_QUOTA:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_QUOTA_EXHAUSTED="true"
    fi
    # MOCK_OPENCODE_RATE_LIMIT lists the models whose round is cut short by a
    # provider rate limit, as the watchdog does in real mode.
    if [[ " ${MOCK_OPENCODE_RATE_LIMIT:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_RATE_LIMITED="true"
    fi
    # OpenCode's free-tier usage limit behaves like a rate limit: try the
    # next model immediately without dropping the provider (#653).
    for _free_var in MOCK_OPENCODE_FREE_USAGE_LIMIT MOCK_OPENCODE_FREE_LIMIT MOCK_OPENCODE_FREE_USAGE; do
      if [[ " ${!_free_var:-} " == *" ${model} "* ]]; then
        OPENCODE_ROUND_RATE_LIMITED="true"
      fi
    done
    unset _free_var
    # MOCK_OPENCODE_INPUT_CANCELLED lists the models whose round dies because
    # the model asked for input this non-interactive run cannot provide.
    # Accept the alternate spelling too, so a test can use either name.
    _mock_input_cancelled_committed="false"
    for _ic_var in MOCK_OPENCODE_INPUT_CANCELLED MOCK_OPENCODE_CANCELLED_INPUT MOCK_OPENCODE_CANCELLED_REQUEST_FOR_INPUT MOCK_OPENCODE_REQUEST_FOR_INPUT_CANCELLED; do
      if [[ " ${!_ic_var:-} " == *" ${model} "* ]]; then
        OPENCODE_ROUND_INPUT_CANCELLED="true"
      fi
    done
    unset _ic_var
    for _icc_var in MOCK_OPENCODE_INPUT_CANCELLED_COMMITTED MOCK_OPENCODE_COMMITTED_INPUT_CANCELLED MOCK_OPENCODE_INPUT_CANCELLED_AFTER_COMMIT MOCK_OPENCODE_CANCELLED_AFTER_COMMIT MOCK_OPENCODE_COMMIT_THEN_CANCEL MOCK_OPENCODE_CANCEL_THEN_COMMIT MOCK_OPENCODE_INPUT_CANCELLED_WITH_COMMIT MOCK_OPENCODE_CANCELLED_INPUT_WITH_COMMIT; do
      if [[ " ${!_icc_var:-} " == *" ${model} "* ]]; then
        OPENCODE_ROUND_INPUT_CANCELLED="true"
        _mock_input_cancelled_committed="true"
      fi
    done
    unset _icc_var
    # MOCK_OPENCODE_*BUDGET* / *TIMEOUT* / *TIME_LIMIT* / *TIME* / *EXCEEDED* (any spelling) marks models
    # whose round is stopped because the driver time budget ran out.
    for _tb_var in $(compgen -v 2>/dev/null | grep '^MOCK_OPENCODE_' || true); do
      case "${_tb_var}" in
        *BUDGET*|*TIMEOUT*|*TIME_LIMIT*|*TIME*|*EXCEEDED*)
          if [[ " ${!_tb_var:-} " == *" ${model} "* ]]; then
            OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED="true"
          fi
          ;;
      esac
    done
    unset _tb_var
    for _sk_var in $(compgen -v 2>/dev/null | grep '^MOCK_OPENCODE_' || true); do
      case "${_sk_var}" in
        *SIGNAL*|*KILLED*|*TERM*|*KILL*)
          if [[ " ${!_sk_var:-} " == *" ${model} "* ]]; then
            OPENCODE_ROUND_SIGNAL_KILLED="true"
          fi
          ;;
      esac
    done
    unset _sk_var
    if [[ "${MOCK_OPENCODE_ERROR:-}" == "${model}" || "${OPENCODE_ROUND_SIGNAL_KILLED}" == "true" || "${OPENCODE_ROUND_ENVIRONMENT}" == "true" || "${OPENCODE_ROUND_MODEL_GONE}" == "true" || "${OPENCODE_ROUND_QUOTA_EXHAUSTED}" == "true" || "${OPENCODE_ROUND_RATE_LIMITED}" == "true" || "${OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED}" == "true" || ( "${OPENCODE_ROUND_INPUT_CANCELLED}" == "true" && "${_mock_input_cancelled_committed}" != "true" ) ]]; then
      if [[ -d "${workdir}" && -w "${workdir}" ]]; then
        printf 'partial change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
      fi
      if [[ " ${MOCK_OPENCODE_FREE_USAGE_LIMIT:-} ${MOCK_OPENCODE_FREE_LIMIT:-} ${MOCK_OPENCODE_FREE_USAGE:-} " == *" ${model} "* ]]; then
        echo "opencode: mock free usage limit for ${model} (rate limit; round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_INPUT_CANCELLED}" == "true" ]]; then
        echo "opencode: mock cancelled input for ${model} (round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_RATE_LIMITED}" == "true" ]]; then
        echo "opencode: mock rate limit for ${model} (round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED}" == "true" ]]; then
        echo "opencode: mock time budget exceeded for ${model} (round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_SIGNAL_KILLED}" == "true" ]]; then
        echo "opencode: mock signal killed for ${model} (round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_QUOTA_EXHAUSTED}" == "true" ]]; then
        echo "opencode: mock quota/billing exhaustion for ${model} (leaves an incomplete change)" >&2
      elif [[ "${OPENCODE_ROUND_ENVIRONMENT}" == "true" ]]; then
        echo "opencode: mock environment error for ${model} (leaves an incomplete change)" >&2
      else
        echo "opencode: mock error for ${model} (leaves an incomplete change)" >&2
      fi
      if [[ "${OPENCODE_ROUND_SIGNAL_KILLED}" == "true" ]]; then
        return 143
      fi
      return 1
    fi
    local mock_message=""
    if [[ -z "${MOCK_OPENCODE_NOOP:-}" || "${MOCK_OPENCODE_NOOP}" != "${model}" ]]; then
      if [[ -z "${MOCK_OPENCODE_MESSAGE_ONLY:-}" || "${MOCK_OPENCODE_MESSAGE_ONLY}" != "${model}" ]]; then
        if [[ -d "${workdir}" && -w "${workdir}" ]]; then
          printf 'mock change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
          mock_message="mock commit from ${model}"
        fi
      else
        # A model that answered with a message instead of doing the work.
        if [[ -d "${workdir}" && -w "${workdir}" ]]; then
          printf 'mock commit from %s\n' "${model}" > "${workdir}/.commit-msg"
        fi
        echo "opencode: mock message-only round for ${model} (message, no code change)" >&2
      fi
    else
      echo "opencode: mock no-op for ${model} (produces no changes)" >&2
    fi
    # MOCK_OPENCODE_TODO (or MOCK_OPENCODE_TODO_JSONL) lists the models that
    # simulate the per-issue progress file. The first round of such a model
    # creates TODO.jsonl with an outstanding task (and remembers it in
    # MOCK_OPENCODE_STATE_DIR); the next round empties it, standing in for an
    # agent that starts the issue, then finishes. The driver must treat the
    # empty file as done AND remove it before hand-off so it never reaches
    # main. The state file lives outside the work tree so it is never committed.
    if { [[ " ${MOCK_OPENCODE_TODO:-} " == *" ${model} "* ]] || [[ " ${MOCK_OPENCODE_TODO_JSONL:-} " == *" ${model} "* ]]; } && [[ -d "${workdir}" && -w "${workdir}" ]]; then
      local todo_state
      todo_state="${MOCK_OPENCODE_STATE_DIR:-${TMPDIR:-/tmp}}/conahcnuj-todo-${model//\//-}"
      mkdir -p "$(dirname "${todo_state}")" 2>/dev/null || true
      if [[ -f "${todo_state}" ]]; then
        : > "${workdir}/TODO.jsonl"
      else
        printf '{"task":"mock task from %s"}\n' "${model}" > "${workdir}/TODO.jsonl"
        : > "${todo_state}"
      fi
    fi
    # The mock agent commits through `git vc` like the real one, instead of
    # leaving only a .commit-msg for the driver. Tests run offline, so the
    # alias is overridden for this one invocation to make the same local
    # commit api-commit.sh would create in a real run. Outside a git work
    # tree (the unit tests call opencode_run in a bare temp dir) there is
    # nothing to commit; the message is left for the driver safety net.
    if [[ -n "${mock_message}" && -d "${workdir}" && -w "${workdir}" ]]; then
      local mock_trailer=""
      if git -C "${workdir}" rev-parse --git-dir >/dev/null 2>&1; then
        mock_trailer="${CONAHCNUJ_COMMIT_MODEL:-}"
        if [[ -z "${mock_trailer}" ]]; then
          local mock_provider="${model%%/*}" mock_rest="${model#*/}"
          if [[ -n "${mock_rest}" && "${mock_rest}" != "${model}" ]]; then
            mock_trailer="${mock_provider} (${mock_rest})"
          else
            mock_trailer="${model}"
          fi
        fi
        local mock_msgfile
        mock_msgfile="$(mktemp "${TMPDIR:-/tmp}/conahcnuj-mock-msg.XXXXXX")"
        printf '%s\n\nCo-Authored-By: %s\n' "${mock_message}" "${mock_trailer}" > "${mock_msgfile}"
        (
          cd "${workdir}" || exit 1
          # The wrapping opencode session injects its own `git vc` alias via
          # GIT_CONFIG_*; clear those so this test alias (a local commit in the
          # offline repo) is the one that runs. The message lives outside the
          # work tree so metadata never gets committed.
          unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
          local cfg
          for cfg in $(compgen -v GIT_CONFIG_KEY_); do unset "${cfg}"; done
          for cfg in $(compgen -v GIT_CONFIG_VALUE_); do unset "${cfg}"; done
          export MOCK_COMMIT_MSG_FILE="${mock_msgfile}"
          # The alias body expands at git-alias execution time, not here.
          # shellcheck disable=SC2016
          git add -A && git -c commit.gpgsign=false -c 'alias.vc=!git commit -q -F "$MOCK_COMMIT_MSG_FILE"' vc
        ) >/dev/null 2>&1 || true
        rm -f "${mock_msgfile}" "${workdir}/.commit-msg"
      else
        printf '%s\n' "${mock_message}" > "${workdir}/.commit-msg"
      fi
    fi
    return 0
  fi

  # Private temp file (mkdtemp). The plugin writes the trailer value only
  # when the path stays inside Node's temp directory. A side model is
  # ignored when CONAHCNUJ_SESSION_MODEL is the model this run selected.
  local label_file
  label_file="$(node -e 'const fs=require("fs");const os=require("os");const path=require("path");const dir=fs.mkdtempSync(path.join(os.tmpdir(),"conahcnuj-"));const file=path.join(dir,"label.txt");fs.writeFileSync(file,"");process.stdout.write(file);' 2>/dev/null || true)"
  if [[ -n "${label_file}" ]]; then
    CONAHCNUJ_MODEL_LABEL_FILE="${label_file}"
    export CONAHCNUJ_MODEL_LABEL_FILE
  fi
  CONAHCNUJ_SESSION_MODEL="${model}"
  export CONAHCNUJ_SESSION_MODEL

  local output_file prompt_file status
  local -a args executable
  output_file="$(mktemp)"
  # The prompt carries the issue body plus every collected file (README.md /
  # AGENTS.md), so it can outgrow the OS argument-list limit (E2BIG:
  # "Argument list too long" from exec). Newer opencode requires a message
  # positional, so pass "-" to make it read the prompt from stdin and keep
  # argv small. The redirect below is on the executable, not the whole
  # pipeline, so $PIPESTATUS stays aligned with opencode.
  prompt_file="$(mktemp)"
  printf '%s\n' "${prompt}" > "${prompt_file}"
  local oc_bin
  oc_bin="$(opencode_command)" || oc_bin="opencode"
  executable=("${oc_bin}")
  if [[ -n "${CONAHCNUJ_RUN_TIMEOUT_SECONDS:-}" ]]; then
    executable=(timeout --signal=TERM --kill-after=30s "${CONAHCNUJ_RUN_TIMEOUT_SECONDS}s" "${oc_bin}")
  fi
  # --thinking makes opencode emit its reasoning parts as JSON events; without
  # it the log shows only tool calls and final answers.
  local version
  # Call opencode_version directly (not in a command substitution): it also
  # records OPENCODE_LOG_LEVEL_UPPER for this backend, and a subshell would
  # lose that global before opencode_run_args() reads it (#1043).
  opencode_version >/dev/null || true
  version="${OPENCODE_VERSION_CACHE:-v2}"
  local _effort_variant
  _effort_variant="$(opencode_effort_variant 2>/dev/null || true)"
  opencode_run_args "${model}" "${session_id:-}" "${_effort_variant}" "${version}"
  args=("${OPENCODE_RUN_ARGS[@]}")
  status=0
  # tee keeps the raw stream for the session id, the renderer prints the log to
  # stderr as the run proceeds (the header's SHA / diff only mean anything
  # live, and stderr is what the driver captures into its bug-report log).
  # The renderer's own exit status is deliberately ignored: a log filter must
  # never change the outcome of a run.
  local -a render
  render=(--model "${model}" --dir "${workdir}")
  if [[ -n "${CONAHCNUJ_REPO:-}" ]]; then
    render+=(--repo "${CONAHCNUJ_REPO}")
  fi
  if [[ -f "${OPENCODE_RENDER_SH}" ]]; then
    render=(bash "${OPENCODE_RENDER_SH}" "${render[@]}")
  else
    echo "WARNING: ${OPENCODE_RENDER_SH} is missing; printing the raw opencode output." >&2
    render=(cat)
  fi

  # opencode sits out a rate limit for minutes (its own retry backoff, nothing
  # useful on stdout) before the --format json error event finally appears.
  # To cut a round short the moment the limit shows up, opencode runs against
  # two FIFOs: a consumer tees stdout for the renderer and the session id, a
  # second keeps opencode's own log (--print-logs -> stderr, where the retry
  # diagnostics actually land) in a file, and a tiny watchdog kills the process
  # as soon as either shows the rate-limit tell (#155). The consumers read a
  # FIFO, so they exit on EOF the moment opencode closes it -- no orphans, no
  # extra pids to chase. When FIFOs are unavailable the plain tee pipeline is
  # kept and the rate limit is only detected at the end of the round.
  local out_fifo err_fifo err_file consumer_pid err_pid rate_aborted
  out_fifo="${output_file}.out"
  err_fifo="${output_file}.errfifo"
  err_file="${output_file}.err"
  rate_aborted="false"
  if mkfifo "${out_fifo}" "${err_fifo}" 2>/dev/null; then
    "${executable[@]}" "${args[@]}" < "${prompt_file}" >"${out_fifo}" 2>"${err_fifo}" &
    local opencode_pid=$!
    ( tee "${output_file}" <"${out_fifo}" | "${render[@]}" >&2 ) &
    consumer_pid=$!
    ( cat <"${err_fifo}" | tee "${err_file}" >&2 ) &
    err_pid=$!
    while kill -0 "${opencode_pid}" 2>/dev/null; do
      if opencode_round_is_rate_limited "${output_file}" "${err_file}"; then
        rate_aborted="true"
        echo "opencode: ${model} hit a rate limit; stopping its retry loop." >&2
        kill -TERM "${opencode_pid}" 2>/dev/null || true
        break
      fi
      # Wait for either opencode to exit or the watch interval to elapse,
      # whichever comes first: a fixed sleep would keep the round (and the
      # offline tests that drive it with a fast-exiting fake opencode) blocked
      # for the whole interval even after the process is gone.
      ( sleep "${CONAHCNUJ_RATE_LIMIT_WATCH_SECONDS:-1}" ) & local _watch_sleeper=$!
      wait -n "${opencode_pid}" "${_watch_sleeper}" 2>/dev/null || true
      kill "${_watch_sleeper}" 2>/dev/null || true
      wait "${_watch_sleeper}" 2>/dev/null || true
    done
    wait "${opencode_pid}" 2>/dev/null || status=$?
    # The FIFO consumers exit once opencode's write ends close; reap them so
    # the session-id extraction below sees the whole stream.
    wait "${consumer_pid}" "${err_pid}" 2>/dev/null || true
    rm -f "${out_fifo}" "${err_fifo}"
  else
    "${executable[@]}" "${args[@]}" < "${prompt_file}" | tee "${output_file}" | "${render[@]}" >&2 || status="${PIPESTATUS[0]}"
  fi

  # Only a failed round is classified: a round that ended fine may still carry
  # a retried-and-recovered error event, which says nothing about the provider.
  # A model that is gone is classified first; it is a model-level condition, so
  # it must not be read as the provider being down.
  if [[ "${status}" != "0" ]] && opencode_round_is_model_gone "${output_file}"; then
    OPENCODE_ROUND_MODEL_GONE="true"
  fi
  # Quota/billing exhaustion is provider-level like an environment error, and
  # is read before it so the specific diagnosis wins over the generic one.
  if [[ "${status}" != "0" ]] && opencode_round_is_quota_exhausted "${output_file}" "${err_file}"; then
    OPENCODE_ROUND_QUOTA_EXHAUSTED="true"
  fi
  if [[ "${status}" != "0" ]] && opencode_round_is_environment "${output_file}" "${err_file}"; then
    OPENCODE_ROUND_ENVIRONMENT="true"
  fi
  if [[ "${status}" != "0" ]] && { [[ "${rate_aborted}" == "true" ]] || opencode_round_is_rate_limited "${output_file}" "${err_file}"; }; then
    OPENCODE_ROUND_RATE_LIMITED="true"
  fi
  if [[ "${status}" != "0" ]] && opencode_round_is_time_budget_exhausted "${output_file}" "${err_file}"; then
    OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED="true"
  fi
  # A cancelled input request is a terminal failure of the round even when the
  # backend happens to exit zero, so classify it independent of the exit status
  # and force a non-zero result; otherwise the round could be reported as
  # completed ("false completion").
  if opencode_round_is_input_cancelled "${output_file}" "${err_file}"; then
    OPENCODE_ROUND_INPUT_CANCELLED="true"
  fi
  local detected_session
  detected_session="$(sed -n 's/.*"sessionID":"\([^"]*\)".*/\1/p' "${output_file}" | sed -n '1p')"
  if [[ "${detected_session}" =~ ^ses_[A-Za-z0-9_-]+$ ]]; then
    OPENCODE_SESSION_ID="${detected_session}"
    export OPENCODE_SESSION_ID
  fi
  rm -f "${output_file}" "${prompt_file}" "${err_file}"
  if [[ "${OPENCODE_ROUND_INPUT_CANCELLED}" == "true" || "${OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED}" == "true" ]]; then
    status=1
  fi
  if [[ "${status}" == "124" ]]; then
    OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED="true"
    echo "opencode exceeded the remaining driver time budget; stopping this model." >&2
  fi
  # A round that died because opencode itself was killed by a signal (SIGTERM
  # from an external pkill, a CI timeout, ...) is a terminal condition, not a
  # driver defect: stop the run cleanly instead of filing a bug report (#1025).
  if [[ "${status}" -ge 128 ]] 2>/dev/null; then
    if [[ "${OPENCODE_ROUND_TIME_BUDGET_EXHAUSTED}" != "true" && "${OPENCODE_ROUND_RATE_LIMITED}" != "true" && "${OPENCODE_ROUND_INPUT_CANCELLED}" != "true" && "${OPENCODE_ROUND_ENVIRONMENT}" != "true" && "${OPENCODE_ROUND_QUOTA_EXHAUSTED}" != "true" && "${OPENCODE_ROUND_MODEL_GONE}" != "true" ]]; then
      OPENCODE_ROUND_SIGNAL_KILLED="true"
      echo "opencode was terminated by a signal; stopping this model." >&2
    fi
  fi
  return "${status}"
}

opencode_environment_ok() {
  local oc models
  if ! oc="$(opencode_command 2>/dev/null)"; then
    echo "ERROR: opencode backend environment check failed: no runnable opencode found (is opencode installed and on PATH?)." >&2
    return 1
  fi
  models="$(opencode_get_models 2>/dev/null || true)"
  if [[ -z "${models//[[:space:]]/}" ]]; then
    echo "ERROR: opencode backend environment check failed: no models available from \`opencode models\` (is opencode installed and on PATH?)." >&2
    return 1
  fi
  return 0
}
