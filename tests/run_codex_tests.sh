#!/usr/bin/env bash
# Plain Bash acceptance suite for Codex account rotation.
#
# Every scenario uses throwaway auth and store paths. File operations remain real.
# WHAM responses and systemctl side effects use focused fake executables.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ROTATE="$REPO_ROOT/codex-rotate.sh"
INFLIGHT="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/codex-inflight.sh"
FAKE_APPSERVER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fake-appserver.py"
BOOTSTRAP="$REPO_ROOT/codex-bootstrap.sh"
CODEX_LIB="$REPO_ROOT/codex-lib.sh"
INSTALL="$REPO_ROOT/install.sh"

guard_tmp() {
    local path="$1"
    case "$path" in
        /tmp/*) return 0 ;;
    esac
    if [ -n "${TMPDIR:-}" ]; then
        case "$path" in
            "${TMPDIR%/}"/*) return 0 ;;
        esac
    fi
    printf 'SAFETY ABORT: %s is outside the temporary directory\n' "$path" >&2
    exit 1
}

TEST_ROOT=$(mktemp -d)
guard_tmp "$TEST_ROOT"
cleanup_root() {
    guard_tmp "$TEST_ROOT"
    rm -rf "$TEST_ROOT"
}
trap cleanup_root EXIT

PASS=0
FAILED=0
CUR_FAIL=0

make_auth() {
    local path="$1" access="$2" account="$3" marker="$4"
    jq -n \
        --arg access "$access" \
        --arg account "$account" \
        --arg marker "$marker" \
        '{
            OPENAI_API_KEY: ("fixture api key " + $marker),
            auth_mode: "chatgpt",
            last_refresh: ("last refresh " + $marker),
            tokens: {
                access_token: $access,
                refresh_token: ("refresh " + $marker),
                id_token: ("identity " + $marker),
                account_id: $account,
                expires_at: 4102444800000,
                profile: {tier: "pro", marker: $marker}
            },
            extra: {nested: {marker: $marker, flags: [true, false]}},
            client_meta: {channel: "stable", revision: 7}
        }' > "$path"
    chmod 600 "$path"
}

make_token_store() {
    local path="$1" access="$2" account="$3" marker="$4"
    jq -n \
        --arg access "$access" \
        --arg account "$account" \
        --arg marker "$marker" \
        '{
            access_token: $access,
            refresh_token: ("refresh " + $marker),
            id_token: ("identity " + $marker),
            account_id: $account,
            expires_at: 4102444800000,
            profile: {tier: "pro", marker: $marker}
        }' > "$path"
    chmod 600 "$path"
}

make_usage_mock() {
    local access="$1" account="$2" five="$3" weekly="$4"
    local five_reset="${5:-4102444800}" weekly_reset="${6:-4102444800}"
    local credits="${7:-true}"
    jq -n \
        --argjson five "$five" \
        --argjson weekly "$weekly" \
        --argjson five_reset "$five_reset" \
        --argjson weekly_reset "$weekly_reset" \
        --argjson credits "$credits" \
        '{
            rate_limit: {
                primary_window: {
                    used_percent: $five,
                    reset_at: $five_reset,
                    limit_window_seconds: 18000
                },
                secondary_window: {
                    used_percent: $weekly,
                    reset_at: $weekly_reset,
                    limit_window_seconds: 604800
                }
            },
            credits: {has_credits: $credits}
        }' > "$MOCK/$access.$account.json"
}

# The real ChatGPT Plus/Pro payload: ONE weekly window, no 5h window at all, arriving in
# the primary slot. `has_credits:false` is the norm on these plans (no pay-as-you-go
# top-up) and must NOT be read as exhausted while a real window is present.
make_usage_mock_weekly_only() {
    local access="$1" account="$2" weekly="$3"
    local weekly_reset="${4:-4102444800}" credits="${5:-false}"
    jq -n \
        --argjson weekly "$weekly" \
        --argjson weekly_reset "$weekly_reset" \
        --argjson credits "$credits" \
        '{
            rate_limit: {
                primary_window: {
                    used_percent: $weekly,
                    reset_at: $weekly_reset,
                    limit_window_seconds: 604800
                },
                secondary_window: null
            },
            credits: {has_credits: $credits}
        }' > "$MOCK/$access.$account.json"
}

# The windowless `premium` shape a fully spent account emits: no window anywhere, so the
# credits object is the only signal left and IS authoritative here.
make_usage_mock_windowless() {
    local access="$1" account="$2" credits="${3:-false}"
    jq -n --argjson credits "$credits" \
        '{
            rate_limit: {primary_window: null, secondary_window: null},
            credits: {has_credits: $credits, balance: "0"}
        }' > "$MOCK/$access.$account.json"
}

make_refresh_mock() {
    local refresh="$1" access="$2" rotated_refresh="$3" id_token="${4:-}"
    jq -n \
        --arg access "$access" \
        --arg refresh "$rotated_refresh" \
        --arg id_token "$id_token" \
        '{
            access_token: $access,
            refresh_token: $refresh,
            expires_in: 3600,
            token_type: "Bearer"
        } + if $id_token == "" then {} else {id_token: $id_token} end' \
        > "$REFRESH/$refresh.json"
}

make_config() {
    local accounts="$1"
    cat > "$CONFIG" <<EOF
FIVE_HOUR_PCT=80
WEEKLY_DIVERGENCE_PCT=20
WEEKLY_DIVERGENCE_HI_FLOOR=80
WEEKLY_DIVERGENCE_HI_PCT=5
WEEKLY_DIVERGENCE_VHI_FLOOR=90
WEEKLY_DIVERGENCE_VHI_PCT=2.5
WEEKLY_CEIL_DEFAULT=98
CODEX_ACCOUNTS="$accounts"
EOF
}

setup_sandbox() {
    SB=$(mktemp -d "$TEST_ROOT/sb.XXXXXX")
    guard_tmp "$SB"
    STORE="$SB/store"
    AUTH="$SB/codex/auth.json"
    CONFIG="$SB/config.env"
    MOCK="$SB/wham"
    REFRESH="$SB/refresh"
    APPSERVER="$SB/appserver"
    mkdir -p "$STORE" "$(dirname "$AUTH")" "$MOCK" "$REFRESH" "$APPSERVER"
    chmod 700 "$STORE"
    unset CODEX_INFLIGHT_CMD CODEX_APPSERVER_RESTART
}

# The app-server is a process boundary, mocked the same way the WHAM endpoint and
# OAuth refresh are. "$APPSERVER/pid" is the pid the rotator should find; when it is
# absent no app-server is running. Every kill the rotator performs appends to
# "$APPSERVER/killed" instead of signalling a real process.
set_appserver_pid() { printf '%s' "$1" > "$APPSERVER/pid"; }
killed_pids() { cat "$APPSERVER/killed" 2>/dev/null; }

# Writes an executable stub and points CODEX_INFLIGHT_CMD at it. The stub prints
# "$1" (empty means no work in flight) and exits with "$2".
set_inflight_cmd() {
    local out="$1" rc="${2:-0}"
    cat > "$SB/inflight.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "$out"
exit $rc
EOF
    chmod 700 "$SB/inflight.sh"
    CODEX_INFLIGHT_CMD="$SB/inflight.sh"
}

seed_account() { make_token_store "$STORE/$1.tokens" "$2" "$3" "$1"; }
set_active() { printf '%s' "$1" > "$STORE/active"; chmod 600 "$STORE/active"; }
set_pin() { printf '%s' "$1" > "$STORE/PIN"; chmod 600 "$STORE/PIN"; }
enable_codex() { : > "$STORE/ENABLED"; chmod 600 "$STORE/ENABLED"; }

run_rotate() {
    OUT=$(
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        ROTATOR_CONFIG="$CONFIG" \
        CODEX_USAGE_MOCK_DIR="$MOCK" \
        CODEX_REFRESH_MOCK_DIR="$REFRESH" \
        CODEX_APPSERVER_MOCK_DIR="$APPSERVER" \
        CODEX_INFLIGHT_CMD="${CODEX_INFLIGHT_CMD:-}" \
        CODEX_APPSERVER_RESTART="${CODEX_APPSERVER_RESTART:-1}" \
            bash "$ROTATE" "$@" 2>&1
    )
    RC=$?
}

run_bootstrap() {
    OUT=$(
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        ROTATOR_CONFIG="$CONFIG" \
        CODEX_USAGE_MOCK_DIR="$MOCK" \
        CODEX_REFRESH_MOCK_DIR="$REFRESH" \
            bash "$BOOTSTRAP" "$@" 2>&1
    )
    RC=$?
}

fail() {
    printf '    FAIL: %s\n' "$1"
    CUR_FAIL=$((CUR_FAIL + 1))
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [ "$expected" != "$actual" ]; then
        fail "$message expected '$expected' actual '$actual'"
    fi
}

assert_exit() { assert_eq "$1" "$2" "$3"; }

assert_contains() {
    local value="$1" fragment="$2" message="$3"
    case "$value" in
        *"$fragment"*) ;;
        *) fail "$message missing '$fragment'" ;;
    esac
}

assert_not_contains() {
    local value="$1" fragment="$2" message="$3"
    case "$value" in
        *"$fragment"*) fail "$message unexpectedly contained '$fragment'" ;;
    esac
}

file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

dir_sha() {
    ( cd "$1" 2>/dev/null && find . -type f -print0 | sort -z \
        | xargs -0 -r sha256sum 2>/dev/null ) | sha256sum | awk '{print $1}'
}

json_value() { jq -S -c "$1" "$2" 2>/dev/null; }

assert_json_files_equal() {
    local expected="$1" actual="$2" message="$3"
    assert_eq "$(json_value . "$expected")" "$(json_value . "$actual")" "$message"
}

assert_active() { assert_eq "$1" "$(cat "$STORE/active" 2>/dev/null)" "$2"; }

scenario_fetch_usage_builds_secure_headers() {
    make_config "acctA"
    mkdir -p "$SB/bin" "$SB/home" "$SB/claude/store"
    local argv_file="$SB/curl.argv" stdin_file="$SB/curl.stdin"
    local access_secret="fixture bearer secret" account_id="account header value"
    cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$@" > "$FAKE_CURL_ARGV"
cat > "$FAKE_CURL_STDIN"
printf '%s\n' '{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":4102444800,"limit_window_seconds":18000},"secondary_window":{"used_percent":34,"reset_at":4102444800,"limit_window_seconds":604800}},"credits":{"has_credits":true}}'
EOF
    chmod 700 "$SB/bin/curl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude/credentials.json" \
        ROTATOR_STORE="$SB/claude/store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_USAGE_MOCK_DIR="" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        FETCH_ACCESS="$access_secret" \
        FETCH_ACCOUNT="$account_id" \
        FAKE_CURL_ARGV="$argv_file" \
        FAKE_CURL_STDIN="$stdin_file" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_fetch_usage "$FETCH_ACCESS" "$FETCH_ACCOUNT"'
    )
    RC=$?

    assert_exit 0 "$RC" "real fetch exit"
    local curl_argv curl_stdin
    curl_argv=$(cat "$argv_file" 2>/dev/null)
    curl_stdin=$(cat "$stdin_file" 2>/dev/null)
    assert_contains "$curl_stdin" "Authorization: Bearer $access_secret" "authorization header"
    assert_contains "$curl_stdin" "chatgpt-account-id: $account_id" "account header"
    assert_contains "$curl_stdin" "Content-Type: application/json" "content type header"
    assert_contains "$curl_argv" "https://chatgpt.com/backend-api/wham/usage" "WHAM endpoint"
    assert_contains "$curl_argv" "@-" "headers supplied through standard input"
    assert_not_contains "$curl_argv" "$access_secret" "bearer secret absent from curl arguments"
    assert_not_contains "$curl_argv" "$account_id" "account id absent from curl arguments"
    assert_eq "18000" "$(printf '%s' "$OUT" | jq -r '.rate_limit.primary_window.limit_window_seconds' 2>/dev/null)" \
        "real fetch returned the WHAM response"
}

scenario_fetch_usage_rejects_unauthorized_response() {
    make_config "acctA"
    mkdir -p "$SB/bin" "$SB/home" "$SB/claude/store"
    cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

fail_http=0
for arg in "$@"; do
    case "$arg" in
        -f|--fail|--fail-with-body) fail_http=1 ;;
    esac
done

cat > /dev/null
printf '%s\n' '{"error":{"message":"Unauthorized","type":"authentication_error"}}'
[ "$fail_http" -eq 0 ] || exit 22
EOF
    chmod 700 "$SB/bin/curl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude/credentials.json" \
        ROTATOR_STORE="$SB/claude/store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_USAGE_MOCK_DIR="" \
        CODEX_LIB_PATH="$CODEX_LIB" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_fetch_usage accessA accountA' 2>&1
    )
    RC=$?

    assert_exit 1 "$RC" "unauthorized WHAM response rejects usage fetch"
}

scenario_refresh_rejects_http_error_response() {
    make_config "acctA"
    seed_account acctA "accessA" "accountA"
    mkdir -p "$SB/bin" "$SB/home"
    local tokens_before
    tokens_before=$(file_sha "$STORE/acctA.tokens")
    cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

fail_http=0
for arg in "$@"; do
    case "$arg" in
        -f|--fail|--fail-with-body) fail_http=1 ;;
    esac
done

cat > /dev/null
if [ "$fail_http" -eq 1 ]; then
    exit 22
fi
printf '%s\n' '{"access_token":"attacker access","refresh_token":"attacker refresh","id_token":"attacker identity"}'
EOF
    chmod 700 "$SB/bin/curl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_REFRESH_MOCK_DIR="" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        TOKENS_FILE="$STORE/acctA.tokens" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_refresh_access_token "$TOKENS_FILE"' 2>&1
    )
    RC=$?

    assert_exit 1 "$RC" "HTTP error rejects token refresh"
    assert_eq "$tokens_before" "$(file_sha "$STORE/acctA.tokens")" \
        "HTTP error preserves stored tokens"
}

scenario_bootstrap_captures_only_tokens() {
    make_config "acctA"
    make_auth "$AUTH" "accessA" "accountA" "A"
    cp "$AUTH" "$SB/auth.before.json"
    make_usage_mock "accessA" "accountA" 12 34

    run_bootstrap acctA

    assert_exit 0 "$RC" "bootstrap exit"
    if [ ! -f "$STORE/acctA.tokens" ]; then
        fail "bootstrap did not create acctA.tokens"
    else
        assert_eq "$(json_value '.tokens' "$AUTH")" "$(json_value . "$STORE/acctA.tokens")" \
            "bootstrap captured the tokens object"
        assert_eq "false" "$(jq -r 'has("OPENAI_API_KEY") or has("auth_mode") or has("extra")' "$STORE/acctA.tokens" 2>/dev/null)" \
            "bootstrap store contains tokens only"
        assert_eq "600" "$(stat -c %a "$STORE/acctA.tokens" 2>/dev/null)" "bootstrap token file mode"
    fi
    assert_eq "700" "$(stat -c %a "$STORE" 2>/dev/null)" "bootstrap store mode"
    assert_json_files_equal "$SB/auth.before.json" "$AUTH" "bootstrap preserved live auth"
    assert_active acctA "bootstrap set active"
}

scenario_swap_replaces_only_tokens() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    cp "$AUTH" "$SB/auth.before.json"
    make_usage_mock "accessA" "accountA" 90 25
    make_usage_mock "accessB" "accountB" 10 25

    run_rotate

    assert_exit 0 "$RC" "token swap exit"
    assert_active acctB "token swap moved active pointer"
    assert_eq "$(json_value . "$STORE/acctB.tokens")" "$(json_value '.tokens' "$AUTH")" \
        "token swap installed the target tokens"
    assert_eq "$(json_value 'del(.tokens)' "$SB/auth.before.json")" "$(json_value 'del(.tokens)' "$AUTH")" \
        "token swap preserved every field outside tokens"
    assert_eq "600" "$(stat -c %a "$AUTH" 2>/dev/null)" "token swap auth mode"
    assert_contains "$OUT" "decision=SWAP" "token swap decision"
}

scenario_pointer_write_failure_restores_live_auth() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 90 20
    make_usage_mock "accessB" "accountB" 10 20
    local pointer_before
    pointer_before=$(file_sha "$STORE/active")
    mkdir "$STORE/active.tmp"

    run_rotate

    assert_exit 0 "$RC" "pointer write failure exit"
    assert_eq "$pointer_before" "$(file_sha "$STORE/active")" \
        "pointer write failure preserved active pointer"
    assert_active acctA "pointer write failure kept original active account"
    assert_eq "accessA" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "pointer write failure restored original live tokens"
    assert_contains "$OUT" "SWAP FAILED" "pointer write failure logged swap failure"
}

scenario_invalid_target_aborts_forced_swap() {
    make_config "acctA acctB"
    set_active acctA
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_token_store "$SB/expected-current.tokens" "accessA" "accountA" "A"
    printf '%s\n' '{"access_token":"accessB"}' > "$STORE/acctB.tokens"
    chmod 600 "$STORE/acctB.tokens"
    local auth_before pointer_before
    auth_before=$(file_sha "$AUTH")
    pointer_before=$(file_sha "$STORE/active")

    OUT=$(
        HOME="$SB" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        TARGET_TOKENS="$STORE/acctB.tokens" \
        EXPECTED_CURRENT_TOKENS="$SB/expected-current.tokens" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_swap_in_tokens "$TARGET_TOKENS" "$CODEX_ROTATOR_AUTH" "$EXPECTED_CURRENT_TOKENS"' 2>&1
    )
    RC=$?

    assert_eq "1" "$RC" "invalid target forced swap exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "invalid target preserved live auth bytes"
    assert_eq "$pointer_before" "$(file_sha "$STORE/active")" "invalid target preserved pointer bytes"
}

scenario_incomplete_target_aborts_forced_swap() {
    make_config "acctA acctB"
    set_active acctA
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_token_store "$SB/expected-current.tokens" "accessA" "accountA" "A"
    printf '%s\n' '{"access_token":"accessB","account_id":"accountB"}' > "$STORE/acctB.tokens"
    chmod 600 "$STORE/acctB.tokens"
    local auth_before pointer_before
    auth_before=$(file_sha "$AUTH")
    pointer_before=$(file_sha "$STORE/active")

    OUT=$(
        HOME="$SB" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        TARGET_TOKENS="$STORE/acctB.tokens" \
        EXPECTED_CURRENT_TOKENS="$SB/expected-current.tokens" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_swap_in_tokens "$TARGET_TOKENS" "$CODEX_ROTATOR_AUTH" "$EXPECTED_CURRENT_TOKENS"' 2>&1
    )
    RC=$?

    assert_eq "1" "$RC" "incomplete target forced swap exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "incomplete target preserved live auth bytes"
    assert_eq "$pointer_before" "$(file_sha "$STORE/active")" "incomplete target preserved pointer bytes"
}

scenario_multiple_target_objects_abort_forced_swap() {
    make_config "acctA acctB"
    set_active acctA
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_token_store "$SB/expected-current.tokens" "accessA" "accountA" "A"
    make_token_store "$STORE/acctB.tokens" "accessB" "accountB" "B"
    make_token_store "$SB/acctC.tokens" "accessC" "accountC" "C"
    cat "$SB/acctC.tokens" >> "$STORE/acctB.tokens"
    local auth_before pointer_before
    auth_before=$(file_sha "$AUTH")
    pointer_before=$(file_sha "$STORE/active")

    OUT=$(
        HOME="$SB" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        TARGET_TOKENS="$STORE/acctB.tokens" \
        EXPECTED_CURRENT_TOKENS="$SB/expected-current.tokens" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_swap_in_tokens "$TARGET_TOKENS" "$CODEX_ROTATOR_AUTH" "$EXPECTED_CURRENT_TOKENS"' 2>&1
    )
    RC=$?

    assert_eq "1" "$RC" "multiple target objects forced swap exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "multiple target objects preserved live auth bytes"
    assert_eq "$pointer_before" "$(file_sha "$STORE/active")" "multiple target objects preserved pointer bytes"
}

scenario_pin_forces_configured_label() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    set_pin acctB
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 10
    make_usage_mock "accessB" "accountB" 10 10

    run_rotate

    assert_exit 0 "$RC" "configured pin exit"
    assert_active acctB "configured pin forced its label"
    assert_eq "accessB" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "configured pin installed target tokens"
    assert_contains "$OUT" "decision=PINNED" "configured pin decision"
}

scenario_empty_pin_holds_active() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    set_pin ""
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0
    local auth_before
    auth_before=$(file_sha "$AUTH")

    run_rotate

    assert_exit 0 "$RC" "empty pin exit"
    assert_active acctA "empty pin held active"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "empty pin preserved auth"
    assert_contains "$OUT" "decision=PINNED" "empty pin decision"
}

scenario_unconfigured_pin_holds_active() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    seed_account acctZ "accessZ" "accountZ"
    set_active acctA
    set_pin acctZ
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0

    run_rotate

    assert_exit 0 "$RC" "unconfigured pin exit"
    assert_active acctA "unconfigured pin held active"
    assert_eq "accessA" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "unconfigured pin preserved live tokens"
    assert_contains "$OUT" "decision=PINNED" "unconfigured pin decision"
}

scenario_single_account_polls_without_swap() {
    make_config "acctA"
    seed_account acctA "accessA" "accountA"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90

    run_rotate

    assert_exit 0 "$RC" "single account exit"
    assert_active acctA "single account held active"
    assert_eq "accessA" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "single account never swapped"
    assert_contains "$OUT" "acctA(5h=100,wk=90/98)" "single account reported polled usage"
    assert_contains "$OUT" "decision=HOLD" "single account decision"
}

scenario_idle_token_refresh_recovers_target() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB-old" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 90 20
    make_refresh_mock "refresh acctB" "accessB-new" "refreshB-rotated" "identityB-new"
    make_refresh_mock "refresh A" "accessA-new" "refreshA-rotated" "identityA-new"
    make_usage_mock "accessB-new" "accountB" 10 20

    run_rotate

    assert_exit 0 "$RC" "idle refresh exit"
    assert_active acctB "idle refresh made the recovered account selectable"
    assert_contains "$OUT" "acctB(5h=10,wk=20/98)" "idle refresh retried WHAM with the new access token"
    assert_contains "$OUT" "decision=SWAP" "idle refresh selected the recovered target"
    assert_eq "accessB-new" "$(jq -r '.access_token // empty' "$STORE/acctB.tokens" 2>/dev/null)" \
        "idle refresh persisted the new access token"
    assert_eq "refreshB-rotated" "$(jq -r '.refresh_token // empty' "$STORE/acctB.tokens" 2>/dev/null)" \
        "idle refresh persisted the rotated refresh token"
    assert_eq "identityB-new" "$(jq -r '.id_token // empty' "$STORE/acctB.tokens" 2>/dev/null)" \
        "idle refresh persisted the returned identity token"
    assert_eq "accountB" "$(jq -r '.account_id // empty' "$STORE/acctB.tokens" 2>/dev/null)" \
        "idle refresh preserved the account id"
    assert_eq "accessA" "$(jq -r '.access_token // empty' "$STORE/acctA.tokens" 2>/dev/null)" \
        "active account access token was never refreshed"
    assert_eq "refresh A" "$(jq -r '.refresh_token // empty' "$STORE/acctA.tokens" 2>/dev/null)" \
        "active account refresh token was never rotated"
}

scenario_weekly_divergence_selects_lowest_weekly_account() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10

    run_rotate

    assert_exit 0 "$RC" "weekly divergence exit"
    assert_active acctB "weekly divergence selected lowest weekly account"
    assert_eq "accessB" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "weekly divergence installed lowest weekly tokens"
    assert_contains "$OUT" "trigA=0 trigB=1 trigC=0 target=acctB decision=SWAP" \
        "weekly divergence reported only trigger B"
}

scenario_trigger_a_wins_when_all_triggers_fire() {
    make_config "acctA acctB acctC acctD"
    printf '%s\n' 'WEEKLY_CEIL_acctC=1' >> "$CONFIG"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    seed_account acctC "accessC" "accountC"
    seed_account acctD "accessD" "accountD"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 90 98
    make_usage_mock "accessB" "accountB" 1 95
    make_usage_mock "accessC" "accountC" 10 0
    make_usage_mock "accessD" "accountD" 20 10

    run_rotate

    assert_exit 0 "$RC" "all triggers exit"
    assert_active acctB "trigger A target won precedence"
    assert_eq "accessB" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "trigger A installed its distinct target tokens"
    assert_contains "$OUT" "trigA=1 trigB=1 trigC=1 target=acctB decision=SWAP" \
        "all triggers reported trigger A target"
}

scenario_trigger_c_wins_over_weekly_divergence() {
    make_config "acctA acctB acctC"
    printf '%s\n' 'WEEKLY_CEIL_acctB=11' >> "$CONFIG"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    seed_account acctC "accessC" "accountC"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 98
    make_usage_mock "accessB" "accountB" 10 10
    make_usage_mock "accessC" "accountC" 10 20

    run_rotate

    assert_exit 0 "$RC" "ceiling and divergence exit"
    assert_active acctC "weekly ceiling target won precedence"
    assert_eq "accessC" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "weekly ceiling installed its target tokens"
    assert_contains "$OUT" "trigA=0 trigB=1 trigC=1 target=acctC decision=SWAP" \
        "weekly ceiling target won over weekly divergence"
}

scenario_pin_releases_at_label_ceiling() {
    make_config "acctA acctB"
    printf '%s\n' 'WEEKLY_CEIL_DEFAULT=99' 'WEEKLY_CEIL_acctA=95' >> "$CONFIG"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    set_pin acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 95
    make_usage_mock "accessB" "accountB" 10 60

    run_rotate

    assert_exit 0 "$RC" "pin ceiling release exit"
    assert_active acctB "pin ceiling release selected valid target"
    assert_contains "$OUT" "decision=SWAP" "pin ceiling release decision"
    assert_not_contains "$OUT" "decision=PINNED" "pin ceiling release state"
    if [ ! -f "$STORE/PIN" ]; then
        fail "pin ceiling release deleted the writer owned PIN"
    fi
}

scenario_expired_weekly_reset_becomes_zero() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 90
    make_usage_mock "accessB" "accountB" 10 100 4102444800 1 true

    run_rotate

    assert_exit 0 "$RC" "expired weekly reset exit"
    assert_active acctB "expired weekly reset made account eligible"
    assert_contains "$OUT" "acctB(5h=10,wk=0/98)" "expired weekly reset normalized stale usage"
    assert_contains "$OUT" "decision=SWAP" "expired weekly reset decision"
}

scenario_windowless_no_credits_stays_exhausted() {
    # Credits are authoritative ONLY in the windowless shape, where nothing else can be read.
    make_config "acctA acctB acctC"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    seed_account acctC "accessC" "accountC"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 90 20
    make_usage_mock_windowless "accessB" "accountB" false
    make_usage_mock "accessC" "accountC" 20 20

    run_rotate

    assert_exit 0 "$RC" "windowless no credits exit"
    assert_active acctC "windowless no credits excluded exhausted account"
    assert_contains "$OUT" "acctB(5h=?,wk=100/98)" "windowless no credits read as spent"
    assert_eq "accessC" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "windowless no credits selected usable target"
    assert_contains "$OUT" "decision=SWAP" "windowless no credits decision"
}

scenario_real_window_beats_false_credits() {
    # The live shape of a healthy ChatGPT plan: a real weekly window at 1% alongside
    # has_credits:false. Reading credits first reported this fresh account as 100% spent,
    # so the rotator refused to ever swap onto it. The window must win.
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock_weekly_only "accessA" "accountA" 100 4102444800 false
    make_usage_mock_weekly_only "accessB" "accountB" 1 4102444800 false

    run_rotate

    assert_exit 0 "$RC" "real window beats credits exit"
    assert_contains "$OUT" "acctB(5h=?,wk=1/98)" "real window won over false credits"
    assert_active acctB "real window beats credits selected the healthy account"
    assert_eq "accessB" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "real window beats credits swapped tokens in"
    assert_contains "$OUT" "decision=SWAP" "real window beats credits decision"
}

scenario_absent_five_hour_window_is_unknown() {
    # These plans ship no 5h window. A missing window must read unknown, never 0: a zero
    # would be maximum headroom and win every comparison, and it would let Trigger A fire
    # against a budget that does not exist.
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock_weekly_only "accessA" "accountA" 40 4102444800 false
    make_usage_mock_weekly_only "accessB" "accountB" 42 4102444800 false

    run_rotate

    assert_exit 0 "$RC" "absent 5h window exit"
    assert_contains "$OUT" "acctA(5h=?,wk=40/98)" "absent 5h window read as unknown"
    assert_contains "$OUT" "trigA=0" "absent 5h window cannot fire Trigger A"
    assert_active acctA "absent 5h window held inside the dead zone"
}

scenario_unreadable_usage_is_unknown() {
    make_config "acctA acctB acctC"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    seed_account acctC "accessC" "accountC"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 90 20
    printf '%s' 'not json' > "$MOCK/accessB.accountB.json"
    make_usage_mock "accessC" "accountC" 25 20

    run_rotate

    assert_exit 0 "$RC" "unreadable usage exit"
    assert_active acctC "unreadable usage was not selected"
    assert_contains "$OUT" "acctB(5h=?,wk=?/98)" "unreadable usage reported unknown"
}

scenario_enabled_absent_mutates_nothing() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0
    local auth_before store_before
    auth_before=$(file_sha "$AUTH")
    store_before=$(dir_sha "$STORE")

    run_rotate

    assert_exit 0 "$RC" "disabled exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "disabled auth unchanged"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "disabled store unchanged"
}

scenario_status_mutates_nothing() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0
    local auth_before store_before
    auth_before=$(file_sha "$AUTH")
    store_before=$(dir_sha "$STORE")

    run_rotate status

    assert_exit 0 "$RC" "status exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "status auth unchanged"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "status store unchanged"
    assert_contains "$OUT" "decision=SWAP" "status reported pending swap"
}

scenario_pointer_desync_skips_before_sync() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessB" "accountB" "acctB"
    local account_a_before auth_before
    account_a_before=$(file_sha "$STORE/acctA.tokens")
    auth_before=$(file_sha "$AUTH")

    run_rotate

    assert_exit 0 "$RC" "pointer desync exit"
    assert_eq "$account_a_before" "$(file_sha "$STORE/acctA.tokens")" \
        "pointer desync did not sync live tokens over active slot"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "pointer desync did not swap auth"
    assert_active acctA "pointer desync held active pointer"
    assert_contains "$OUT" "pointer desync" "pointer desync was visible"
}

scenario_live_auth_change_during_poll_skips_swap() {
    make_config "acctA acctB"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_token_store "$STORE/acctA.tokens" "accessA" "accountA" "A"
    make_auth "$SB/auth.external.json" "accessUnexpected" "accountUnexpected" "external"
    mkdir -p "$SB/bin" "$SB/home"
    local auth_replaced account_a_before
    auth_replaced=$(file_sha "$SB/auth.external.json")
    account_a_before=$(file_sha "$STORE/acctA.tokens")
    cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

headers=$(cat)
case "$headers" in
    *"Authorization: Bearer accessA"*)
        cp "$RACE_REPLACEMENT" "$RACE_AUTH"
        printf '%s\n' '{"rate_limit":{"primary_window":{"used_percent":90,"reset_at":4102444800,"limit_window_seconds":18000},"secondary_window":{"used_percent":20,"reset_at":4102444800,"limit_window_seconds":604800}},"credits":{"has_credits":true}}'
        ;;
    *)
        printf '%s\n' '{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":4102444800,"limit_window_seconds":18000},"secondary_window":{"used_percent":20,"reset_at":4102444800,"limit_window_seconds":604800}},"credits":{"has_credits":true}}'
        ;;
esac
EOF
    chmod 700 "$SB/bin/curl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        ROTATOR_CONFIG="$CONFIG" \
        CODEX_USAGE_MOCK_DIR="" \
        CODEX_REFRESH_MOCK_DIR="$REFRESH" \
        RACE_AUTH="$AUTH" \
        RACE_REPLACEMENT="$SB/auth.external.json" \
            bash "$ROTATE" 2>&1
    )
    RC=$?

    assert_exit 0 "$RC" "live auth change tick exit"
    assert_active acctA "live auth change preserves active pointer"
    assert_eq "$auth_replaced" "$(file_sha "$AUTH")" \
        "live auth change preserves external auth bytes"
    assert_eq "$account_a_before" "$(file_sha "$STORE/acctA.tokens")" \
        "live auth change does not store external tokens for active account"
}

scenario_overlapping_live_tick_holds_rotate_lock() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0
    exec 8>"$STORE/rotate.lock"
    flock -n 8
    local auth_before store_before
    auth_before=$(file_sha "$AUTH")
    store_before=$(dir_sha "$STORE")

    run_rotate

    flock -u 8
    exec 8>&-
    assert_exit 0 "$RC" "overlapping live tick exit"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "overlapping tick auth unchanged"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "overlapping tick store unchanged"
}

scenario_install_creates_parallel_codex_timer() {
    make_config "acctA"
    mkdir -p "$SB/bin" "$SB/home"
    local calls="$SB/systemctl.calls"
    cat > "$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_CALLS"
EOF
    chmod 700 "$SB/bin/systemctl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_STORE="$STORE" \
        FAKE_SYSTEMCTL_CALLS="$calls" \
            bash "$INSTALL" 2>&1
    )
    RC=$?

    assert_exit 0 "$RC" "install exit"
    local unit_dir="$SB/home/.config/systemd/user"
    local service="$unit_dir/cc-codex-token-rotator.service"
    local timer="$unit_dir/cc-codex-token-rotator.timer"
    if [ ! -f "$unit_dir/cc-token-rotator.service" ] || [ ! -f "$unit_dir/cc-token-rotator.timer" ]; then
        fail "install did not retain the Claude unit pair"
    fi
    if [ ! -f "$service" ]; then
        fail "install did not create the Codex service"
    else
        assert_contains "$(cat "$service")" "Description=Codex token rotator tick" "Codex service description"
        assert_contains "$(cat "$service")" "Type=oneshot" "Codex service type"
        assert_contains "$(cat "$service")" "ExecStart=$REPO_ROOT/codex-rotate.sh" "Codex service command"
    fi
    if [ ! -f "$timer" ]; then
        fail "install did not create the Codex timer"
    else
        local timer_content
        timer_content=$(cat "$timer")
        assert_contains "$timer_content" "OnBootSec=5min" "Codex timer boot delay"
        assert_contains "$timer_content" "OnActiveSec=1min" "Codex timer initial run"
        assert_contains "$timer_content" "OnUnitActiveSec=15min" "Codex timer interval"
        assert_contains "$timer_content" "Persistent=true" "Codex timer persistence"
        assert_contains "$timer_content" "WantedBy=timers.target" "Codex timer install target"
    fi
    local systemctl_calls
    systemctl_calls=$(cat "$calls" 2>/dev/null)
    assert_contains "$systemctl_calls" "--user daemon-reload" "systemd reload call"
    assert_contains "$systemctl_calls" \
        "--user enable --now cc-token-rotator.timer cc-codex-token-rotator.timer" \
        "both timers enabled together"
}

scenario_install_fails_when_systemctl_fails() {
    make_config "acctA"
    mkdir -p "$SB/bin" "$SB/home"
    local calls="$SB/systemctl.calls"
    cat > "$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_CALLS"
exit 1
EOF
    chmod 700 "$SB/bin/systemctl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_STORE="$STORE" \
        FAKE_SYSTEMCTL_CALLS="$calls" \
            bash "$INSTALL" 2>&1
    )
    RC=$?

    if [ "$RC" -eq 0 ]; then
        fail "install succeeds when systemctl fails"
    fi
    assert_not_contains "$OUT" "installed and started both token rotator timers" \
        "failed install success message"
    assert_contains "$(cat "$calls" 2>/dev/null)" "--user daemon-reload" \
        "failed install reload call"
}

scenario_install_fails_when_timer_enable_fails() {
    make_config "acctA"
    mkdir -p "$SB/bin" "$SB/home"
    local calls="$SB/systemctl.calls"
    cat > "$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_CALLS"
if [ "$2" = "daemon-reload" ]; then
    exit 0
fi
exit 1
EOF
    chmod 700 "$SB/bin/systemctl"

    OUT=$(
        HOME="$SB/home" \
        PATH="$SB/bin:$PATH" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_STORE="$STORE" \
        FAKE_SYSTEMCTL_CALLS="$calls" \
            bash "$INSTALL" 2>&1
    )
    RC=$?

    assert_exit 1 "$RC" "timer enable failure exits nonzero"
    assert_contains "$(cat "$calls" 2>/dev/null)" "--user daemon-reload" \
        "timer enable failure completed reload"
    assert_contains "$(cat "$calls" 2>/dev/null)" \
        "--user enable --now cc-token-rotator.timer cc-codex-token-rotator.timer" \
        "timer enable failure reached enable"
    assert_contains "$OUT" "Could not enable token rotator timers." \
        "timer enable failure was reported"
    assert_not_contains "$OUT" "installed and started both token rotator timers" \
        "timer enable failure did not report success"
}

scenario_swap_rejects_changed_live_tokens() {
    make_config "acctA acctB"
    make_token_store "$STORE/acctB.tokens" "accessB" "accountB" "B"
    make_token_store "$SB/expected-current.tokens" "accessA1" "accountA" "A1"
    make_auth "$AUTH" "accessA2" "accountA" "A2"
    local auth_before
    auth_before=$(file_sha "$AUTH")

    OUT=$(
        HOME="$SB" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_CRED="$SB/claude.credentials.json" \
        ROTATOR_STORE="$SB/claude.store" \
        CODEX_ROTATOR_AUTH="$AUTH" \
        CODEX_ROTATOR_STORE="$STORE" \
        CODEX_LIB_PATH="$CODEX_LIB" \
        TARGET_TOKENS="$STORE/acctB.tokens" \
        EXPECTED_CURRENT_TOKENS="$SB/expected-current.tokens" \
            bash -c 'source "$CODEX_LIB_PATH"; codex_swap_in_tokens "$TARGET_TOKENS" "$CODEX_ROTATOR_AUTH" "$EXPECTED_CURRENT_TOKENS"' 2>&1
    )
    RC=$?

    assert_exit 1 "$RC" "changed live tokens reject swap"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "changed live tokens preserve auth bytes"
}

scenario_bootstrap_rejects_when_enabled() {
    make_config "acctA"
    make_auth "$AUTH" "accessA" "accountA" "A"
    enable_codex
    local auth_before store_before
    auth_before=$(file_sha "$AUTH")
    store_before=$(dir_sha "$STORE")

    run_bootstrap acctA

    assert_exit 1 "$RC" "enabled bootstrap rejects account capture"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "enabled bootstrap preserved auth bytes"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "enabled bootstrap preserved store bytes"
}

scenario_symlinked_rotate_lock_preserves_target() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 100 90
    make_usage_mock "accessB" "accountB" 0 0
    local lock_target="$SB/rotate.lock.target"
    printf '%s' 'known lock target bytes' > "$lock_target"
    chmod 600 "$lock_target"
    ln -s "$lock_target" "$STORE/rotate.lock"
    local target_before auth_before pointer_before
    target_before=$(file_sha "$lock_target")
    auth_before=$(file_sha "$AUTH")
    pointer_before=$(file_sha "$STORE/active")

    run_rotate

    assert_exit 0 "$RC" "symlinked rotate lock holds safely"
    assert_eq "$target_before" "$(file_sha "$lock_target")" "symlinked lock preserved target bytes"
    assert_eq "$auth_before" "$(file_sha "$AUTH")" "symlinked lock preserved live auth"
    assert_eq "$pointer_before" "$(file_sha "$STORE/active")" "symlinked lock preserved active pointer"
}

run_scenario() {
    local name="$1" function_name="$2"
    CUR_FAIL=0
    setup_sandbox
    "$function_name"
    if [ "$CUR_FAIL" -eq 0 ]; then
        printf 'PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$name"
        FAILED=$((FAILED + 1))
    fi
    guard_tmp "$SB"
    rm -rf "$SB"
}

if [ ! -f "$ROTATE" ] || [ ! -f "$BOOTSTRAP" ]; then
    printf 'NOTE: Codex production scripts do not exist yet. Scenarios should fail.\n\n'
fi

# --- app-server restart on swap -------------------------------------------------
# A swap only changes auth.json. The running app-server caches its account at
# startup and never re-reads the file, so the swap does not reach any Codex work
# until the app-server is replaced. Killing it is destructive to in-flight turns,
# hence the in-flight gate below.

scenario_swap_restarts_appserver() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242

    run_rotate

    assert_exit 0 "$RC" "restart-on-swap exit"
    assert_active acctB "restart-on-swap still performed the swap"
    assert_eq "4242" "$(killed_pids)" "swap killed the running app-server exactly once"
    assert_contains "$OUT" "app-server" "swap logged the app-server restart"
}

scenario_no_appserver_running_is_not_an_error() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10

    run_rotate

    assert_exit 0 "$RC" "absent app-server exit"
    assert_active acctB "absent app-server still performed the swap"
    assert_eq "" "$(killed_pids)" "absent app-server killed nothing"
}

scenario_rolled_back_swap_leaves_appserver_alone() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    # Block the pointer write so the swap is attempted, fails, and rolls back.
    # The live auth ends up back on acctA, so killing the app-server would
    # restart it onto the account it was already serving and interrupt work
    # for nothing.
    mkdir "$STORE/active.tmp"

    run_rotate

    assert_exit 0 "$RC" "rolled back swap exit"
    assert_active acctA "rolled back swap left the pointer alone"
    assert_eq "accessA" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "rolled back swap restored the original live tokens"
    assert_contains "$OUT" "SWAP FAILED" "rolled back swap logged the failure"
    assert_eq "" "$(killed_pids)" "rolled back swap must not kill the app-server"
}

scenario_appserver_restart_can_be_disabled() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    CODEX_APPSERVER_RESTART=0

    run_rotate

    assert_exit 0 "$RC" "restart disabled exit"
    assert_active acctB "restart disabled still performed the swap"
    assert_eq "" "$(killed_pids)" "restart disabled killed nothing"
}

scenario_status_never_kills_appserver() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242

    run_rotate status

    assert_exit 0 "$RC" "status exit"
    assert_active acctA "status did not swap"
    assert_eq "" "$(killed_pids)" "status must never kill the app-server"
}

# --- in-flight gate -------------------------------------------------------------
# Killing the app-server interrupts every running turn, so a swap must never fire
# while Codex work is in flight.

scenario_inflight_work_blocks_swap() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    set_inflight_cmd "thread-01a01adc"

    run_rotate

    assert_exit 0 "$RC" "in-flight gate exit"
    assert_active acctA "in-flight work blocked the swap"
    assert_eq "accessA" "$(jq -r '.tokens.access_token // empty' "$AUTH" 2>/dev/null)" \
        "in-flight work left the live auth untouched"
    assert_eq "" "$(killed_pids)" "in-flight work must not kill the app-server"
    assert_contains "$OUT" "decision=HOLD" "in-flight work reported a hold"
    assert_contains "$OUT" "in flight" "in-flight hold explained itself"
}

scenario_inflight_probe_failure_holds() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    # A probe that cannot answer is unknown, and unknown must never authorise a kill.
    set_inflight_cmd "" 1

    run_rotate

    assert_exit 0 "$RC" "in-flight probe failure exit"
    assert_active acctA "unknown in-flight state blocked the swap"
    assert_eq "" "$(killed_pids)" "unknown in-flight state must not kill the app-server"
}

scenario_quiet_inflight_probe_allows_swap() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 70
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    set_inflight_cmd "" 0

    run_rotate

    assert_exit 0 "$RC" "quiet in-flight probe exit"
    assert_active acctB "quiet in-flight probe allowed the swap"
    assert_eq "4242" "$(killed_pids)" "quiet in-flight probe allowed the restart"
}

scenario_inflight_work_blocks_pinned_swap() {
    make_config "acctA acctB"
    seed_account acctA "accessA" "accountA"
    seed_account acctB "accessB" "accountB"
    set_active acctA
    set_pin acctB
    enable_codex
    make_auth "$AUTH" "accessA" "accountA" "A"
    make_usage_mock "accessA" "accountA" 10 10
    make_usage_mock "accessB" "accountB" 10 10
    set_appserver_pid 4242
    set_inflight_cmd "thread-01a01adc"

    run_rotate

    assert_exit 0 "$RC" "pinned in-flight gate exit"
    assert_active acctA "in-flight work blocked the pinned swap"
    assert_eq "" "$(killed_pids)" "pinned in-flight work must not kill the app-server"
}

# --- app-server in-flight probe --------------------------------------------------
# codex-inflight.sh is what makes the gate cover dispatchers that record their work
# nowhere the rotator can see. It asks the app-server directly, so these
# scenarios stand up a fake app-server rather than mocking the probe itself.

start_fake_appserver() {
    FAKE_SOCK="$SB/fake-app-server.sock"
    python3 "$FAKE_APPSERVER" "$FAKE_SOCK" "$@" > "$SB/fake.out" 2>"$SB/fake.err" &
    FAKE_PID=$!
    local waited=0
    while [ ! -s "$SB/fake.out" ] && [ "$waited" -lt 100 ]; do
        waited=$((waited + 1))
        read -r -t 0.1 < /dev/zero 2>/dev/null || true
    done
    [ -s "$SB/fake.out" ] || fail "fake app-server never became ready"
}

stop_fake_appserver() {
    [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
    wait "${FAKE_PID:-}" 2>/dev/null
    FAKE_PID=""
}

run_inflight() {
    OUT=$(CODEX_APPSERVER_SOCKET="${1:-$FAKE_SOCK}" ROTATOR_CONFIG="$CONFIG" \
        bash "$INFLIGHT" 2>&1)
    RC=$?
}

scenario_inflight_probe_reports_active_thread() {
    make_config "acctA acctB"
    start_fake_appserver active
    run_inflight
    stop_fake_appserver
    assert_exit 0 "$RC" "active probe exit"
    assert_contains "$OUT" "thread-0" "an active thread is reported as in flight"
}

scenario_inflight_probe_is_quiet_when_nothing_runs() {
    make_config "acctA acctB"
    # A completed turn leaves the thread loaded and idle, not evicted. Reporting that
    # as in flight would wedge rotation permanently.
    start_fake_appserver idle notLoaded
    run_inflight
    stop_fake_appserver
    assert_exit 0 "$RC" "quiet probe exit"
    assert_eq "" "$OUT" "idle and notLoaded threads are not in flight"
}

scenario_inflight_probe_holds_on_unknown_status() {
    make_config "acctA acctB"
    start_fake_appserver somethingNew
    run_inflight
    stop_fake_appserver
    assert_exit 0 "$RC" "unknown status probe exit"
    assert_contains "$OUT" "thread-0" "an unrecognised status is treated as in flight"
}

scenario_inflight_probe_reports_only_the_active_thread() {
    make_config "acctA acctB"
    start_fake_appserver notLoaded active idle
    run_inflight
    stop_fake_appserver
    assert_exit 0 "$RC" "mixed probe exit"
    assert_eq "thread-1" "$OUT" "only the active thread is reported"
}

scenario_inflight_probe_fails_loudly_on_rpc_error() {
    make_config "acctA acctB"
    start_fake_appserver --rpc-error
    run_inflight
    stop_fake_appserver
    # Non-zero is the rotator's "unknown", which it treats as in flight.
    if [ "$RC" -eq 0 ]; then
        fail "an app-server RPC error must not report the coast is clear"
    fi
}

scenario_inflight_probe_is_clear_without_an_appserver() {
    make_config "acctA acctB"
    run_inflight "$SB/definitely-not-a-socket"
    assert_exit 0 "$RC" "absent socket exit"
    assert_eq "" "$OUT" "no app-server means nothing can be in flight"
}

run_scenario "Bootstrap captures only auth tokens"              scenario_bootstrap_captures_only_tokens
run_scenario "Real fetch builds secure WHAM headers"            scenario_fetch_usage_builds_secure_headers
run_scenario "Unauthorized WHAM response fails usage fetch"     scenario_fetch_usage_rejects_unauthorized_response
run_scenario "HTTP error rejects token refresh"                  scenario_refresh_rejects_http_error_response
run_scenario "Atomic swap preserves every non token auth field" scenario_swap_replaces_only_tokens
run_scenario "Pointer write failure restores live auth"        scenario_pointer_write_failure_restores_live_auth
run_scenario "Invalid target aborts forced swap"                scenario_invalid_target_aborts_forced_swap
run_scenario "Incomplete target aborts forced swap"             scenario_incomplete_target_aborts_forced_swap
run_scenario "Multiple token objects abort forced swap"         scenario_multiple_target_objects_abort_forced_swap
run_scenario "Changed live tokens reject swap"                  scenario_swap_rejects_changed_live_tokens
run_scenario "Enabled bootstrap rejects account capture"        scenario_bootstrap_rejects_when_enabled
run_scenario "Symlinked rotate lock preserves target"           scenario_symlinked_rotate_lock_preserves_target
run_scenario "Configured PIN forces its label"                  scenario_pin_forces_configured_label
run_scenario "Empty PIN holds active"                            scenario_empty_pin_holds_active
run_scenario "Unconfigured PIN holds active"                     scenario_unconfigured_pin_holds_active
run_scenario "One account polls without swapping"                scenario_single_account_polls_without_swap
run_scenario "Idle token refresh recovers a valid target"         scenario_idle_token_refresh_recovers_target
run_scenario "Weekly divergence selects lowest weekly account"    scenario_weekly_divergence_selects_lowest_weekly_account
run_scenario "Trigger A wins when all triggers fire"              scenario_trigger_a_wins_when_all_triggers_fire
run_scenario "Trigger C wins over weekly divergence"              scenario_trigger_c_wins_over_weekly_divergence
run_scenario "PIN releases at its account ceiling"               scenario_pin_releases_at_label_ceiling
run_scenario "Expired weekly reset becomes zero"                 scenario_expired_weekly_reset_becomes_zero
run_scenario "Windowless no credits stays exhausted"             scenario_windowless_no_credits_stays_exhausted
run_scenario "Real window beats false credits"                   scenario_real_window_beats_false_credits
run_scenario "Absent 5h window is unknown"                       scenario_absent_five_hour_window_is_unknown
run_scenario "Unreadable usage is unknown"                       scenario_unreadable_usage_is_unknown
run_scenario "Missing ENABLED mutates nothing"                   scenario_enabled_absent_mutates_nothing
run_scenario "Status mutates nothing"                            scenario_status_mutates_nothing
run_scenario "Pointer desync skips before sync"                  scenario_pointer_desync_skips_before_sync
run_scenario "Live auth change during poll skips swap"           scenario_live_auth_change_during_poll_skips_swap
run_scenario "Overlapping live tick holds rotate lock"            scenario_overlapping_live_tick_holds_rotate_lock
run_scenario "Install creates a parallel Codex timer"            scenario_install_creates_parallel_codex_timer
run_scenario "Install fails when systemctl fails"                scenario_install_fails_when_systemctl_fails
run_scenario "Install fails when timer enable fails"             scenario_install_fails_when_timer_enable_fails

run_scenario "Swap restarts the app-server"                      scenario_swap_restarts_appserver
run_scenario "Absent app-server is not an error"                 scenario_no_appserver_running_is_not_an_error
run_scenario "Rolled back swap leaves the app-server alone"      scenario_rolled_back_swap_leaves_appserver_alone
run_scenario "App-server restart can be disabled"                scenario_appserver_restart_can_be_disabled
run_scenario "Status never kills the app-server"                 scenario_status_never_kills_appserver
run_scenario "In-flight work blocks the swap"                    scenario_inflight_work_blocks_swap
run_scenario "Unknown in-flight state blocks the swap"           scenario_inflight_probe_failure_holds
run_scenario "Quiet in-flight probe allows the swap"             scenario_quiet_inflight_probe_allows_swap
run_scenario "In-flight work blocks a pinned swap"               scenario_inflight_work_blocks_pinned_swap

run_scenario "Probe reports an active thread"                     scenario_inflight_probe_reports_active_thread
run_scenario "Probe is quiet when nothing runs"                  scenario_inflight_probe_is_quiet_when_nothing_runs
run_scenario "Probe holds on an unknown status"                  scenario_inflight_probe_holds_on_unknown_status
run_scenario "Probe reports only the active thread"              scenario_inflight_probe_reports_only_the_active_thread
run_scenario "Probe fails loudly on an RPC error"                scenario_inflight_probe_fails_loudly_on_rpc_error
run_scenario "Probe is clear without an app-server"              scenario_inflight_probe_is_clear_without_an_appserver

printf '\nCodex summary: %d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
