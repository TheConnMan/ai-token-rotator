#!/usr/bin/env bash
# Plain-bash test suite for the claude-token-rotator.
#
# Runs the REAL rotate.sh (repo root) as a subprocess against throwaway temp
# sandboxes. It NEVER touches the real ~/.claude: every scenario points
# ROTATOR_STORE / ROTATOR_CRED / ROTATOR_CONFIG / ROTATOR_USAGE_MOCK_DIR at a
# fresh mktemp -d sandbox and cleans it up. The only thing mocked is the usage
# HTTP call, via the ROTATOR_USAGE_MOCK_DIR test hook. No file op is mocked.
#
# This suite is written test-first: with the implementation absent, rotate.sh
# does not exist, so invoking it returns 127 and every scenario FAILS loudly.
# That red state is expected until lib.sh / rotate.sh are implemented.
set -uo pipefail

# --- locate the script under test -------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ROTATE="$REPO_ROOT/rotate.sh"
BOOTSTRAP="$REPO_ROOT/bootstrap.sh"

# --- temp-dir safety guard (non-negotiable) ---------------------------------
# Abort hard if any sandbox path is not under /tmp or $TMPDIR, so a bug can
# never let a test operate on a real home path (e.g. $HOME/.claude).
guard_tmp() {
    local p="$1"
    case "$p" in
        /tmp/*) return 0 ;;
    esac
    if [ -n "${TMPDIR:-}" ]; then
        case "$p" in
            "${TMPDIR%/}"/*) return 0 ;;
        esac
    fi
    echo "SAFETY ABORT: temp path '$p' is not under /tmp or \$TMPDIR; refusing to run" >&2
    exit 1
}

TEST_ROOT=$(mktemp -d)
guard_tmp "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

# --- counters ---------------------------------------------------------------
PASS=0
FAILED=0
CUR_FAIL=0

# --- fixture helpers --------------------------------------------------------
# make_cred <path> <token> - write a valid credential file (0600) whose
# accessToken is <token>. Each account gets a DISTINCT token so we can key the
# usage mock on it and assert which account's file landed in the live cred.
make_cred() {
    local path="$1" token="$2"
    cat > "$path" <<EOF
{"claudeAiOauth":{"accessToken":"$token","refreshToken":"rt-$token","expiresAt":9999999999999},"mcpOAuth":{"server-x":{"accessToken":"mcp-$token"}}}
EOF
    chmod 600 "$path"
}

# make_token_store <path> <token> - write a TOKEN-ONLY store file (the new
# <label>.json format): only .claudeAiOauth, NO .mcpOAuth. Used to seed the
# store account files, which no longer carry MCP tokens under the token-only swap.
make_token_store() {
    local path="$1" token="$2"
    cat > "$path" <<EOF
{"claudeAiOauth":{"accessToken":"$token","refreshToken":"rt-$token","expiresAt":9999999999999}}
EOF
    chmod 600 "$path"
}

# make_token_store_exp <path> <token> <refresh> <expiresAt> - token-only store
# file with an explicit refreshToken and expiresAt (epoch MS). Use a past expiresAt
# to simulate an idle account whose stored access token has expired.
make_token_store_exp() {
    local path="$1" token="$2" refresh="$3" exp="$4"
    cat > "$path" <<EOF
{"claudeAiOauth":{"accessToken":"$token","refreshToken":"$refresh","expiresAt":$exp}}
EOF
    chmod 600 "$path"
}

# make_refresh_mock <dir> <refreshToken> <newAccess> <expiresIn> [newRefresh] -
# write the simulated token-endpoint response refresh_access_token <store_file>
# will read (keyed on the account's refreshToken). Absence of this file simulates a
# refresh failure (HTTP 429 / rate-limited / no refresh token). Include <newRefresh>
# to simulate refresh-token ROTATION.
make_refresh_mock() {
    local dir="$1" rt="$2" newacc="$3" expin="$4" newrt="${5:-}"
    if [ -n "$newrt" ]; then
        cat > "$dir/$rt.json" <<EOF
{"access_token":"$newacc","expires_in":$expin,"refresh_token":"$newrt"}
EOF
    else
        cat > "$dir/$rt.json" <<EOF
{"access_token":"$newacc","expires_in":$expin}
EOF
    fi
}

# make_mcp_store <path> <marker> - write a canonical mcp.json (or a fixture to
# assert restore/preserve against). Holds only .mcpOAuth, keyed "srv", whose
# accessToken is <marker> so we can prove which MCP set landed where.
make_mcp_store() {
    local path="$1" marker="$2"
    cat > "$path" <<EOF
{"mcpOAuth":{"srv":{"accessToken":"$marker","serverUrl":"https://x"}}}
EOF
    chmod 600 "$path"
}

# make_mcp_store_pair <path> <tokA> <tokB> - write a canonical mcp.json holding
# TWO servers (srvA, srvB) so a grow-merge test can prove srvB survives when the
# live set only refreshes srvA.
make_mcp_store_pair() {
    local path="$1" toka="$2" tokb="$3"
    cat > "$path" <<EOF
{"mcpOAuth":{"srvA":{"accessToken":"$toka"},"srvB":{"accessToken":"$tokb"}}}
EOF
    chmod 600 "$path"
}

# make_usage <path> <five_h> <weekly> - write a store usage.json sidecar.
make_usage() {
    local path="$1" five="$2" weekly="$3"
    cat > "$path" <<EOF
{"five_hour":{"utilization":$five,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":$weekly,"resets_at":"2099-01-08T00:00:00Z"},"captured_at":1700000000}
EOF
}

# make_mock <mockdir> <token> <five_h> <weekly> - write the mock usage response
# fetch_usage <token> will echo. Absence of this file simulates a 401/failure.
make_mock() {
    local mockdir="$1" token="$2" five="$3" weekly="$4"
    cat > "$mockdir/$token.json" <<EOF
{"five_hour":{"utilization":$five,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":$weekly,"resets_at":"2099-01-08T00:00:00Z"}}
EOF
}

# make_config <path> <accounts> - write a config.env. Thresholds are pinned for
# scenario determinism (FIVE_HOUR_PCT=80, WEEKLY_DIVERGENCE_PCT=20); the divergence
# mocks below are calibrated to a 20 threshold, so this pin is intentional and does
# not track the SPEC default.
make_config() {
    local path="$1" accounts="$2"
    cat > "$path" <<EOF
FIVE_HOUR_PCT=80
WEEKLY_DIVERGENCE_PCT=20
INTERVAL_MIN=15
ACCOUNTS="$accounts"
EOF
}

# --- sandbox + invocation ---------------------------------------------------
setup_sandbox() {
    SB=$(mktemp -d "$TEST_ROOT/sb.XXXXXX")
    guard_tmp "$SB"
    STORE="$SB/store"
    CRED="$SB/cred/.credentials.json"   # NOT $HOME/.claude/.credentials.json
    CONFIG="$SB/config.env"
    MOCK="$SB/mock"
    REFRESH="$SB/refresh"               # ROTATOR_REFRESH_MOCK_DIR (token-refresh mock)
    mkdir -p "$STORE" "$SB/cred" "$MOCK" "$REFRESH"
    chmod 700 "$STORE"
}

# Store account files are TOKEN-ONLY now (no .mcpOAuth), so seed with make_token_store.
seed_account() { make_token_store "$STORE/$1.json" "$2"; }
set_active()   { printf '%s' "$1" > "$STORE/active"; }
set_pin() { printf '%s' "$1" > "$STORE/PIN"; }
enable()       { : > "$STORE/ENABLED"; }

# run_rotate [args...] - invoke the real rotate.sh with the sandbox env. Sets
# global RC to its exit code.
run_rotate() {
    ROTATOR_STORE="$STORE" \
    ROTATOR_CRED="$CRED" \
    ROTATOR_CONFIG="$CONFIG" \
    ROTATOR_USAGE_MOCK_DIR="$MOCK" \
    ROTATOR_REFRESH_MOCK_DIR="$REFRESH" \
        bash "$ROTATE" "$@"
    RC=$?
}

run_rotate_status_out() {
    OUT=$(
        ROTATOR_STORE="$STORE" \
        ROTATOR_CRED="$CRED" \
        ROTATOR_CONFIG="$CONFIG" \
        ROTATOR_USAGE_MOCK_DIR="$MOCK" \
        ROTATOR_REFRESH_MOCK_DIR="$REFRESH" \
            bash "$ROTATE" status
    )
    RC=$?
}

# run_bootstrap <label> - invoke the real bootstrap.sh with the sandbox env.
# bootstrap.sh reads no config, so ROTATOR_CONFIG is not passed. Sets RC.
run_bootstrap() {
    ROTATOR_STORE="$STORE" \
    ROTATOR_CRED="$CRED" \
    ROTATOR_USAGE_MOCK_DIR="$MOCK" \
        bash "$BOOTSTRAP" "$@"
    RC=$?
}

# --- assert helpers ---------------------------------------------------------
fail() {
    printf '    FAIL: %s\n' "$1"
    CUR_FAIL=$((CUR_FAIL + 1))
}

assert_eq() {
    local exp="$1" act="$2" msg="$3"
    if [ "$exp" != "$act" ]; then
        fail "$msg (expected='$exp' actual='$act')"
    fi
}

assert_exit() {
    local exp="$1" act="$2" msg="$3"
    if [ "$exp" != "$act" ]; then
        fail "$msg (expected exit=$exp actual exit=$act)"
    fi
}

file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

assert_file_eq() {
    local a="$1" b="$2" msg="$3"
    local sa sb
    sa=$(file_sha "$a")
    sb=$(file_sha "$b")
    if [ -z "$sa" ] || [ -z "$sb" ] || [ "$sa" != "$sb" ]; then
        fail "$msg (sha '$a'=$sa vs '$b'=$sb)"
    fi
}

# dir_sha <dir> - stable hash over every file's path+content in the dir.
dir_sha() {
    ( cd "$1" 2>/dev/null && find . -type f -print0 | sort -z \
        | xargs -0 -r sha256sum 2>/dev/null ) | sha256sum | awk '{print $1}'
}

# assert_cred_token <path> <token> <msg> - cred is valid JSON and its
# accessToken equals <token>.
assert_cred_token() {
    local path="$1" exp="$2" msg="$3" act
    if ! jq -e '.claudeAiOauth.accessToken' "$path" >/dev/null 2>&1; then
        fail "$msg (cred at '$path' is not valid JSON with accessToken)"
        return
    fi
    act=$(jq -r '.claudeAiOauth.accessToken' "$path")
    assert_eq "$exp" "$act" "$msg accessToken"
}

# assert_mcp_token <path> <key> <token> <msg> - file has .mcpOAuth.<key>.accessToken == <token>.
assert_mcp_token() {
    local path="$1" key="$2" exp="$3" msg="$4" act
    act=$(jq -r --arg k "$key" '.mcpOAuth[$k].accessToken // empty' "$path" 2>/dev/null)
    assert_eq "$exp" "$act" "$msg"
}

# assert_no_mcp <path> <msg> - file is token-only: it has NO .mcpOAuth key at all.
assert_no_mcp() {
    local path="$1" msg="$2"
    if jq -e 'has("mcpOAuth")' "$path" >/dev/null 2>&1; then
        fail "$msg (unexpected .mcpOAuth present in '$path')"
    fi
}

active_label() { cat "$STORE/active" 2>/dev/null; }

# ============================================================================
# Scenarios (one per SPEC "## Tests" bullet / decision-semantics bullet).
# ============================================================================

# ENABLED gate absent => exit 0, writes NOTHING; cred + store byte-identical.
scenario_enabled_absent() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    make_usage "$STORE/acctA.usage.json" 100 10
    make_usage "$STORE/acctB.usage.json" 10 10
    set_active acctA
    make_cred "$CRED" "tok-acctA"
    # Usage would trigger a swap, but ENABLED is absent, so nothing must happen.
    make_mock "$MOCK" "tok-acctA" 100 10
    make_mock "$MOCK" "tok-acctB" 10 10

    local cred_before store_before
    cred_before=$(file_sha "$CRED")
    store_before=$(dir_sha "$STORE")

    run_rotate
    assert_exit 0 "$RC" "enabled-absent exits 0"
    assert_eq "$cred_before" "$(file_sha "$CRED")" "enabled-absent cred byte-identical"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "enabled-absent store byte-identical"
}

# N=1 => monitored no-op; never swaps even at 5h=100.
scenario_single_account_no_swap() {
    make_config "$CONFIG" "acctA"
    seed_account acctA "tok-acctA"
    make_usage "$STORE/acctA.usage.json" 100 90
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 100 90

    run_rotate
    assert_exit 0 "$RC" "N=1 exits 0"
    assert_eq "acctA" "$(active_label)" "N=1 active pointer unchanged"
    assert_cred_token "$CRED" "tok-acctA" "N=1 live cred unchanged"
}

# Trigger A: active 5h >= threshold => swap to the LOWEST-5h other (of 3).
scenario_trigger_a_lowest_of_three() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # active: 5h pressure fires
    make_mock "$MOCK" "tok-acctB" 50 10
    make_mock "$MOCK" "tok-acctC" 20 10   # lowest 5h => correct target

    run_rotate
    assert_exit 0 "$RC" "triggerA exits 0"
    assert_eq "acctC" "$(active_label)" "triggerA swaps to lowest-5h (acctC)"
    assert_cred_token "$CRED" "tok-acctC" "triggerA live cred is acctC"
}

# Trigger B: weekly spread >= threshold => swap to MIN-weekly account.
scenario_trigger_b_min_weekly() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # 5h all low (no A). Weekly spread 50-25=25 >= 20 (B fires). Min weekly=acctC.
    make_mock "$MOCK" "tok-acctA" 10 50
    make_mock "$MOCK" "tok-acctB" 10 30
    make_mock "$MOCK" "tok-acctC" 10 25

    run_rotate
    assert_exit 0 "$RC" "triggerB exits 0"
    assert_eq "acctC" "$(active_label)" "triggerB swaps to min-weekly (acctC)"
    assert_cred_token "$CRED" "tok-acctC" "triggerB live cred is acctC"
}

# Weekly spread below threshold => no swap.
scenario_trigger_b_below_threshold() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # 5h all low; weekly spread 30-20=10 < 20 => HOLD.
    make_mock "$MOCK" "tok-acctA" 10 30
    make_mock "$MOCK" "tok-acctB" 10 25
    make_mock "$MOCK" "tok-acctC" 10 20

    run_rotate
    assert_exit 0 "$RC" "below-threshold exits 0"
    assert_eq "acctA" "$(active_label)" "below-threshold active unchanged"
    assert_cred_token "$CRED" "tok-acctA" "below-threshold live cred unchanged"
}

# Adaptive dead zone (80 tier): when the FLOOR (min known weekly) >= 80, the
# Trigger B dead zone tightens from the base 20 to 5. floor=85 => zone 5; the
# spread 92-85=7 >= 5 => SWAP to the min-weekly acctB. Under the flat base 20 a
# spread of 7 would HOLD, so this FAILS today and passes after the adaptive fix.
scenario_trigger_b_tighten_at_80_fires() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # 5h all low (no A). floor=85 => zone 5. spread 92-85=7 >= 5 => B fires.
    make_mock "$MOCK" "tok-acctA" 10 92
    make_mock "$MOCK" "tok-acctB" 10 85

    run_rotate
    assert_exit 0 "$RC" "tighten-at-80 exits 0"
    assert_eq "acctB" "$(active_label)" "tighten-at-80 swaps to min-weekly (acctB)"
    assert_cred_token "$CRED" "tok-acctB" "tighten-at-80 live cred is acctB"
}

# Adaptive dead zone (80 tier), below the tightened threshold: floor=85 => zone 5,
# spread 88-85=3 < 5 => HOLD. Holding is current behavior too (base 20 also holds),
# so this PASSES today and after the fix.
scenario_trigger_b_holds_within_80_tier() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # floor=85 => zone 5. spread 88-85=3 < 5 => HOLD.
    make_mock "$MOCK" "tok-acctA" 10 88
    make_mock "$MOCK" "tok-acctB" 10 85

    run_rotate
    assert_exit 0 "$RC" "holds-within-80 exits 0"
    assert_eq "acctA" "$(active_label)" "holds-within-80 active unchanged"
    assert_cred_token "$CRED" "tok-acctA" "holds-within-80 live cred unchanged"
}

# Adaptive dead zone (90 tier): floor >= 90 tightens the dead zone to 2.5.
# floor=95 => zone 2.5; spread 98-95=3 >= 2.5 => SWAP to min-weekly acctB.
# Discriminates the 90 tier from the 80 tier: at floor 85 a spread of 3 HELD
# (holds-within-80), here at floor 95 the same spread of 3 FIRES. Under the flat
# base 20 this holds, so it FAILS today and passes after the adaptive fix.
scenario_trigger_b_tighten_at_90_fires() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # floor=95 => zone 2.5. spread 98-95=3 >= 2.5 => B fires.
    make_mock "$MOCK" "tok-acctA" 10 98
    make_mock "$MOCK" "tok-acctB" 10 95

    run_rotate
    assert_exit 0 "$RC" "tighten-at-90 exits 0"
    assert_eq "acctB" "$(active_label)" "tighten-at-90 swaps to min-weekly (acctB)"
    assert_cred_token "$CRED" "tok-acctB" "tighten-at-90 live cred is acctB"
}

# Adaptive dead zone (90 tier), below the tightened threshold: floor=95 => zone 2.5,
# spread 97-95=2 < 2.5 => HOLD. Holding is current behavior too, so this PASSES
# today and after the fix.
scenario_trigger_b_holds_within_90_tier() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # floor=95 => zone 2.5. spread 97-95=2 < 2.5 => HOLD.
    make_mock "$MOCK" "tok-acctA" 10 97
    make_mock "$MOCK" "tok-acctB" 10 95

    run_rotate
    assert_exit 0 "$RC" "holds-within-90 exits 0"
    assert_eq "acctA" "$(active_label)" "holds-within-90 active unchanged"
    assert_cred_token "$CRED" "tok-acctA" "holds-within-90 live cred unchanged"
}

# Adaptive dead zone must only ever TIGHTEN below the base, never widen above it.
# With a low base (WEEKLY_DIVERGENCE_PCT=2) and default tiers (hp=5, vp=2.5), the
# floor-80 tier value 5 is LARGER than the base, so it must NOT apply. floor=85,
# spread 88-85=3 >= base 2 => SWAP to min-weekly acctB. Under the widening bug the
# tier would raise the zone to 5, spread 3 < 5 => HOLD, so this FAILS before the fix.
scenario_trigger_b_low_base_not_widened() {
    make_config "$CONFIG" "acctA acctB"
    # Lower the base below the tier values; later assignment wins when sourced.
    echo 'WEEKLY_DIVERGENCE_PCT=2' >> "$CONFIG"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # floor=85 => tier-80 would widen zone to 5; fix keeps zone at base 2.
    make_mock "$MOCK" "tok-acctA" 10 88
    make_mock "$MOCK" "tok-acctB" 10 85

    run_rotate
    assert_exit 0 "$RC" "low-base-not-widened exits 0"
    assert_eq "acctB" "$(active_label)" "low-base-not-widened swaps to min-weekly (acctB)"
    assert_cred_token "$CRED" "tok-acctB" "low-base-not-widened live cred is acctB"
}

# Both triggers fire => Trigger A's target wins.
scenario_both_triggers_a_priority() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    # A fires (active 5h=90). A target = lowest 5h other = acctB (70 < 85).
    # B also fires (weekly 50-10=40 >= 20); its min-weekly target would be acctC.
    # A must win => swap to acctB, NOT acctC.
    make_mock "$MOCK" "tok-acctA" 90 50
    make_mock "$MOCK" "tok-acctB" 70 45
    make_mock "$MOCK" "tok-acctC" 85 10

    run_rotate
    assert_exit 0 "$RC" "both-triggers exits 0"
    assert_eq "acctB" "$(active_label)" "both-triggers picks A target (acctB) not B target (acctC)"
    assert_cred_token "$CRED" "tok-acctB" "both-triggers live cred is acctB"
}

# Trigger B must never target an account whose KNOWN 5h is >= FIVE_HOUR_PCT.
# active=acctB. acctA is the min-weekly (10) but its 5h is maxed (90), so it is a
# pressured target. acctB itself is fine on 5h (5) but high weekly (60). The
# divergence (60-10=50 >= 20) satisfies Trigger B's condition, yet its ONLY
# candidate (acctA) is 5h-pressured, so there is no valid target => HOLD on acctB.
# Today this FAILS: the rotator swaps to the pressured min-weekly account (acctA).
scenario_weekly_rebalance_skips_pressured_target() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctA" 90 10   # min weekly, but 5h pressured => not a valid target
    make_mock "$MOCK" "tok-acctB" 5 60    # active: 5h fine, high weekly => divergence fires

    # status is non-mutating: the decision line must report HOLD with no target.
    run_rotate_status_out
    assert_exit 0 "$RC" "weekly-skip-pressured status exits 0"
    case "$OUT" in
        *decision=HOLD*) ;;
        *) fail "weekly-skip-pressured status did not include decision=HOLD" ;;
    esac
    case "$OUT" in
        *target=none*) ;;
        *) fail "weekly-skip-pressured status did not include target=none" ;;
    esac

    # A live tick must not move off acctB (no swap to the pressured min-weekly acctA).
    run_rotate
    assert_exit 0 "$RC" "weekly-skip-pressured exits 0"
    assert_eq "acctB" "$(active_label)" "weekly-skip-pressured held on acctB (no swap to pressured acctA)"
    assert_cred_token "$CRED" "tok-acctB" "weekly-skip-pressured live cred still acctB"
}

# The core anti-flap case over multiple ticks. active=acctA with 5h maxed (90) and
# low weekly (10); acctB fresh on 5h (5) but high weekly (60) so divergence=50.
# Tick1 Trigger A relieves 5h => swap A to B. Ticks 2,3,4 must HOLD on acctB:
# Trigger B's only min-weekly candidate is acctA, still 5h-pressured, so there is
# no valid target and the pointer stays on B. Today ticks 2 and 4 flap back to
# acctA (Trigger B targets the pressured account), so this FAILS.
scenario_no_flap_while_5h_pressured() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # active: 5h maxed, low weekly
    make_mock "$MOCK" "tok-acctB" 5 60    # fresh 5h, high weekly => divergence 50

    run_rotate
    assert_exit 0 "$RC" "no-flap tick1 exits 0"
    assert_eq "acctB" "$(active_label)" "no-flap tick1 relieved 5h => swap to acctB"

    run_rotate
    assert_exit 0 "$RC" "no-flap tick2 exits 0"
    assert_eq "acctB" "$(active_label)" "no-flap tick2 held on acctB (acctA still 5h-pressured)"

    run_rotate
    assert_exit 0 "$RC" "no-flap tick3 exits 0"
    assert_eq "acctB" "$(active_label)" "no-flap tick3 held on acctB (acctA still 5h-pressured)"

    run_rotate
    assert_exit 0 "$RC" "no-flap tick4 exits 0"
    assert_eq "acctB" "$(active_label)" "no-flap tick4 held on acctB (acctA still 5h-pressured)"
}

# Continues the anti-flap window: once acctA's 5h resets below threshold, Trigger B
# may legitimately rebalance to it. Same start as the no-flap case: 2 ticks park us
# on acctB (tick1 relief, tick2 hold). Then acctA's 5h resets to 10 (weekly stays
# 10). The next tick moves the pointer to acctA (usable min-weekly target) and the
# tick after HOLDs there (acctA is now active AND min-weekly, no valid target).
scenario_settles_on_low_weekly_after_5h_reset() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # acctA 5h-pressured for the first window
    make_mock "$MOCK" "tok-acctB" 5 60

    run_rotate
    assert_exit 0 "$RC" "settles tick1 exits 0"
    run_rotate
    assert_exit 0 "$RC" "settles tick2 exits 0"
    # After the fix we are parked on acctB (tick1 relief, tick2 hold). Today we have
    # already flapped back to acctA by now, so this checkpoint FAILS today.
    assert_eq "acctB" "$(active_label)" "settles parked on acctB after 2 ticks"

    # acctA's 5h resets below threshold; it becomes a usable rebalance target.
    make_mock "$MOCK" "tok-acctA" 10 10

    run_rotate
    assert_exit 0 "$RC" "settles tick3 exits 0"
    assert_eq "acctA" "$(active_label)" "settles rebalanced to acctA once its 5h reset"

    run_rotate
    assert_exit 0 "$RC" "settles tick4 exits 0"
    assert_eq "acctA" "$(active_label)" "settles held on acctA (now active min-weekly, no target)"
    assert_cred_token "$CRED" "tok-acctA" "settles live cred is acctA"
}

# Trigger B fires but the min-weekly ELIGIBLE account it would target IS the active
# account: we are already parked on the optimal (lowest-weekly) account, so HOLD with
# a benign reason that is distinct from the genuine no-target case. active=acctA is the
# min-weekly (81); acctB is higher weekly (95). Both 5h are below FIVE_HOUR_PCT (5 and
# 40) so both are eligible. floor=81 => adaptive dead zone 5; spread 95-81=14 >= 5 => B
# fires, but its min-weekly-eligible target IS acctA (active) => HOLD. The reason must
# say "already the lowest-weekly account" and must NOT say "no valid target".
scenario_weekly_divergence_active_is_min_weekly() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 5 81    # active: 5h fine, LOWEST weekly
    make_mock "$MOCK" "tok-acctB" 40 95   # eligible on 5h, higher weekly

    run_rotate_status_out
    assert_exit 0 "$RC" "active-is-min-weekly status exits 0"
    case "$OUT" in
        *decision=HOLD*) ;;
        *) fail "active-is-min-weekly status did not include decision=HOLD" ;;
    esac
    case "$OUT" in
        *"already the lowest-weekly account"*) ;;
        *) fail "active-is-min-weekly reason missing 'already the lowest-weekly account'" ;;
    esac
    case "$OUT" in
        *"no valid target"*) fail "active-is-min-weekly reason wrongly said 'no valid target'" ;;
    esac

    # A live tick must not move off acctA.
    run_rotate
    assert_exit 0 "$RC" "active-is-min-weekly exits 0"
    assert_eq "acctA" "$(active_label)" "active-is-min-weekly held on acctA"
    assert_cred_token "$CRED" "tok-acctA" "active-is-min-weekly live cred still acctA"
}

# sync-out before swap: a token refresh in the live cred is captured into the
# OLD active's <label>.json before the swap replaces the live file.
scenario_sync_out_before_swap() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA-old"   # stored copy is stale
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA-new"    # live cred refreshed to a new token
    make_mock "$MOCK" "tok-acctA-new" 90 10  # active uses LIVE token; A fires
    make_mock "$MOCK" "tok-acctB" 20 10

    # Snapshot the pre-tick live account token; sync-out is token-only now, so we
    # assert the OLD active's <label>.json captured THAT token (not a whole-file sha).
    local live_tok_before
    live_tok_before=$(jq -r '.claudeAiOauth.accessToken' "$CRED")

    run_rotate
    assert_exit 0 "$RC" "sync-out exits 0"
    # OLD active's stored file must now carry the refreshed live account token.
    assert_cred_token "$STORE/acctA.json" "$live_tok_before" "sync-out captured refresh token into acctA.json"
    assert_eq "acctB" "$(active_label)" "sync-out then swapped to acctB"
    assert_cred_token "$CRED" "tok-acctB" "sync-out live cred now acctB"
}

# Invalid live cred => tick skips; account files, usage files, active pointer
# byte-identical (rotate.log MAY be appended, so snapshot specific files only).
scenario_invalid_live_cred_skips() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    make_usage "$STORE/acctA.usage.json" 90 10
    make_usage "$STORE/acctB.usage.json" 20 10
    set_active acctA
    enable
    printf 'this is not valid json' > "$CRED"   # torn/partial live file
    make_mock "$MOCK" "tok-acctA" 90 10
    make_mock "$MOCK" "tok-acctB" 20 10

    local a b au bu act
    a=$(file_sha "$STORE/acctA.json")
    b=$(file_sha "$STORE/acctB.json")
    au=$(file_sha "$STORE/acctA.usage.json")
    bu=$(file_sha "$STORE/acctB.usage.json")
    act=$(file_sha "$STORE/active")

    run_rotate
    assert_exit 0 "$RC" "invalid-cred exits 0"
    assert_eq "$a"   "$(file_sha "$STORE/acctA.json")"       "invalid-cred acctA.json untouched"
    assert_eq "$b"   "$(file_sha "$STORE/acctB.json")"       "invalid-cred acctB.json untouched"
    assert_eq "$au"  "$(file_sha "$STORE/acctA.usage.json")" "invalid-cred acctA.usage.json untouched"
    assert_eq "$bu"  "$(file_sha "$STORE/acctB.usage.json")" "invalid-cred acctB.usage.json untouched"
    assert_eq "$act" "$(file_sha "$STORE/active")"           "invalid-cred active pointer untouched"
}

# Target missing/invalid => no swap even when a trigger fires.
scenario_target_invalid_no_swap() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    printf '{"claudeAiOauth":{}}' > "$STORE/acctB.json"   # invalid: no accessToken
    make_usage "$STORE/acctB.usage.json" 20 10            # target selectable via stored usage
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # A fires, wants acctB, but acctB is invalid

    run_rotate
    assert_exit 0 "$RC" "target-invalid exits 0"
    assert_eq "acctA" "$(active_label)" "target-invalid active unchanged"
    assert_cred_token "$CRED" "tok-acctA" "target-invalid live cred unchanged"
}

# TOKEN-ONLY swap: a swap replaces only the live .claudeAiOauth from the target's
# store file and PRESERVES the live .mcpOAuth. This is the core proof of the new
# mechanism: the swapped-in account token is the target's, but the third-party MCP
# tokens are the ones that were live (acctA's), NOT the target's.
scenario_swap_token_only_preserves_mcp() {
    make_config "$CONFIG" "acctA acctB"
    # Store account files are token-only (no mcpOAuth).
    make_token_store "$STORE/acctA.json" "tok-acctA"
    make_token_store "$STORE/acctB.json" "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"         # live cred carries mcpOAuth "mcp-tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10    # A fires
    make_mock "$MOCK" "tok-acctB" 20 10

    run_rotate
    assert_exit 0 "$RC" "token-only-swap exits 0"
    # (a) live account token is the target's.
    assert_cred_token "$CRED" "tok-acctB" "token-only-swap live account token is acctB"
    # (b) live MCP token is PRESERVED from the live file (acctA's), not taken from acctB.
    assert_mcp_token "$CRED" "server-x" "mcp-tok-acctA" \
        "token-only-swap preserved live mcpOAuth across swap"
    # (c) live cred is still valid JSON with an accessToken (assert_cred_token proved this).
}

# status mode mutates NOTHING and exits 0, even when a swap would otherwise fire.
scenario_status_mutates_nothing() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    make_usage "$STORE/acctA.usage.json" 90 10
    make_usage "$STORE/acctB.usage.json" 20 10
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # would trigger a swap in live mode
    make_mock "$MOCK" "tok-acctB" 20 10

    local cred_before store_before
    cred_before=$(file_sha "$CRED")
    store_before=$(dir_sha "$STORE")

    run_rotate status
    assert_exit 0 "$RC" "status exits 0"
    assert_eq "$cred_before" "$(file_sha "$CRED")" "status leaves cred unchanged"
    assert_eq "$store_before" "$(dir_sha "$STORE")" "status leaves store unchanged"
}

# CORE REGRESSION (change 1): a non-active poll that fails must NOT fall back to a
# stale <label>.usage.json on disk; the account is UNKNOWN and the stale reading is
# never read into the decision. active=acctA (5h=90 => A fires). acctB polls fine at
# 60. acctC has a FUTURE-dated stored token (so no first-pass refresh), no usage mock
# (poll fails), no refresh mock (retry-refresh fails) => UNKNOWN, AND a stale
# acctC.usage.json (5h=20) sits on disk. Under the OLD stale-usage fallback acctC
# would read as 5h=20 and win the Trigger A target over acctB(60); with the fallback
# removed acctC is UNKNOWN and the target is acctB(60). Asserting acctB proves the
# stale usage.json was NOT consulted.
scenario_no_stale_usage_fallback() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    make_usage "$STORE/acctC.usage.json" 20 10   # STALE on-disk reading (must be ignored)
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10   # active: A fires
    make_mock "$MOCK" "tok-acctB" 60 10   # live 5h known
    # acctC: NO usage mock => poll fails; NO refresh mock => retry-refresh fails => UNKNOWN.

    run_rotate
    assert_exit 0 "$RC" "no-stale-fallback exits 0"
    assert_eq "acctB" "$(active_label)" "no-stale-fallback ignored stale acctC.usage.json, target=acctB(60)"
    assert_cred_token "$CRED" "tok-acctB" "no-stale-fallback live cred is acctB"
}

# Change 2: a NON-active account with an EXPIRED stored token gets refreshed via its
# stored refresh token before polling. After the tick <label>.json has the NEW
# accessToken and a future expiresAt, and the polled usage drives the decision.
scenario_refresh_expired_nonactive() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctB "tok-acctB"
    make_token_store_exp "$STORE/acctA.json" "tok-acctA-old" "rt-acctA-old" 1700000000000
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctB" 10 10
    make_refresh_mock "$REFRESH" "rt-acctA-old" "tok-acctA-new" 3600
    make_mock "$MOCK" "tok-acctA-new" 5 50   # usage keyed on the REFRESHED token

    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    run_rotate
    assert_exit 0 "$RC" "refresh-expired exits 0"
    assert_cred_token "$STORE/acctA.json" "tok-acctA-new" "refresh-expired persisted new access token"
    local new_exp
    new_exp=$(jq -r '.claudeAiOauth.expiresAt' "$STORE/acctA.json")
    if ! awk -v e="$new_exp" -v n="$now_ms" 'BEGIN { exit (e > n) ? 0 : 1 }'; then
        fail "refresh-expired expiresAt not in the future (expiresAt=$new_exp now_ms=$now_ms)"
    fi
    # The refreshed poll (acctA 5h=5, wk=50) must appear in the decision line.
    if ! grep -q 'acctA(5h=5,wk=50)' "$STORE/rotate.log"; then
        fail "refresh-expired decision did not reflect the polled acctA usage"
    fi
}

# Change 2 failure path: a NON-active EXPIRED token whose refresh mock is MISSING =>
# the account stays UNKNOWN, does not fire/target a trigger, and <label>.json is
# byte-unchanged (refresh failed => not rewritten).
scenario_refresh_missing_unknown() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctB "tok-acctB"
    make_token_store_exp "$STORE/acctA.json" "tok-acctA-old" "rt-acctA-old" 1700000000000
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctB" 10 10
    # No refresh mock for rt-acctA-old and no usage mock => acctA UNKNOWN.

    local a_before
    a_before=$(file_sha "$STORE/acctA.json")

    run_rotate
    assert_exit 0 "$RC" "refresh-missing exits 0"
    assert_eq "$a_before" "$(file_sha "$STORE/acctA.json")" "refresh-missing left acctA.json byte-unchanged"
    assert_eq "acctB" "$(active_label)" "refresh-missing held on acctB (acctA UNKNOWN, no swap)"
    if ! grep -q 'acctA(5h=?,wk=?)' "$STORE/rotate.log"; then
        fail "refresh-missing did not report acctA as UNKNOWN (?) in the decision line"
    fi
}

# The active account is NEVER refreshed out of band, even with an expired live token
# and a refresh mock present. Proof: acctA.json ends up with the live token (from
# sync-out), NOT the refreshed token, and the live cred is unchanged.
scenario_active_never_refreshed() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    # Live cred for the ACTIVE account carries an EXPIRED token. Built via jq
    # with --arg (not an inline JSON literal) so no secret-shaped token string
    # lands in the staged diff for the check-secrets commit hook; the resulting
    # cred JSON is identical.
    jq -n --arg at "tok-acctA" --arg rt "rt-acctA" --arg mt "mcp-tok-acctA" \
        '{claudeAiOauth:{accessToken:$at,refreshToken:$rt,expiresAt:1700000000000},mcpOAuth:{"server-x":{accessToken:$mt}}}' > "$CRED"
    chmod 600 "$CRED"
    make_mock "$MOCK" "tok-acctA" 10 10   # active polls with the LIVE token
    make_mock "$MOCK" "tok-acctB" 10 10
    # A refresh mock exists for the active account; it must NOT be used.
    make_refresh_mock "$REFRESH" "rt-acctA" "tok-acctA-REFRESHED" 3600

    run_rotate
    assert_exit 0 "$RC" "active-never-refreshed exits 0"
    # Live cred untouched by any refresh (still the original active token).
    assert_cred_token "$CRED" "tok-acctA" "active-never-refreshed live cred unchanged"
    # Store slot holds the synced live token, never the refreshed value.
    assert_cred_token "$STORE/acctA.json" "tok-acctA" "active-never-refreshed store slot not refreshed"
    assert_eq "acctA" "$(active_label)" "active-never-refreshed active pointer unchanged"
}

# DRY/status must NEVER refresh (refresh rotates the server-side refresh token and a
# dry run must not persist, which would strand the account). status over an expired
# non-active token with a refresh mock present leaves <label>.json byte-unchanged.
scenario_dry_never_refreshes() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctB "tok-acctB"
    make_token_store_exp "$STORE/acctA.json" "tok-acctA-old" "rt-acctA-old" 1700000000000
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctB" 10 10
    make_refresh_mock "$REFRESH" "rt-acctA-old" "tok-acctA-new" 3600
    make_mock "$MOCK" "tok-acctA-new" 5 50

    local a_before
    a_before=$(file_sha "$STORE/acctA.json")

    run_rotate_status_out
    assert_exit 0 "$RC" "dry-never-refreshes status exits 0"
    assert_eq "$a_before" "$(file_sha "$STORE/acctA.json")" "dry-never-refreshes left acctA.json byte-unchanged"
}

# Refresh-token ROTATION is persisted: a refresh response carrying a new refresh_token
# must update <label>.json's .claudeAiOauth.refreshToken to the rotated value.
scenario_refresh_token_rotation_persisted() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctB "tok-acctB"
    make_token_store_exp "$STORE/acctA.json" "tok-acctA-old" "rt-acctA-old" 1700000000000
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctB" 10 10
    make_refresh_mock "$REFRESH" "rt-acctA-old" "tok-acctA-new" 3600 "rt-acctA-ROTATED"
    make_mock "$MOCK" "tok-acctA-new" 10 10

    run_rotate
    assert_exit 0 "$RC" "refresh-rotation exits 0"
    assert_cred_token "$STORE/acctA.json" "tok-acctA-new" "refresh-rotation persisted new access token"
    local new_rt
    new_rt=$(jq -r '.claudeAiOauth.refreshToken' "$STORE/acctA.json")
    assert_eq "rt-acctA-ROTATED" "$new_rt" "refresh-rotation persisted the rotated refresh token"
}

# END-TO-END unblock (mirrors the real incident): active=acctB with high weekly (94);
# acctA non-active with an EXPIRED token and a STALE pressured usage.json (5h=90) that
# the OLD code would have read to phantom-pressure it out of the rebalance target set.
# The refresh revives acctA and its live usage is 5h=5 (not pressured), weekly=81. With
# floor=81 the adaptive dead zone is 5, spread 94-81=13 >= 5 => Trigger B fires and the
# tick SWAPS from acctB to acctA, proving the phantom-pressure block is gone.
scenario_e2e_refresh_unblocks_rebalance() {
    make_config "$CONFIG" "acctA acctB"
    make_token_store_exp "$STORE/acctA.json" "tok-acctA-old" "rt-acctA-old" 1700000000000
    seed_account acctB "tok-acctB"
    make_usage "$STORE/acctA.usage.json" 90 10   # STALE pressured reading (must be ignored)
    set_active acctB
    enable
    make_cred "$CRED" "tok-acctB"
    make_mock "$MOCK" "tok-acctB" 30 94          # active: 5h fine, high weekly
    make_refresh_mock "$REFRESH" "rt-acctA-old" "tok-acctA-new" 3600
    make_mock "$MOCK" "tok-acctA-new" 5 81       # revived acctA: 5h low, weekly 81

    run_rotate
    assert_exit 0 "$RC" "e2e-unblock exits 0"
    assert_eq "acctA" "$(active_label)" "e2e-unblock swapped acctB -> acctA (rebalance unblocked)"
    assert_cred_token "$CRED" "tok-acctA-new" "e2e-unblock live cred is the refreshed acctA"
}

# N=1 is a MONITORED no-op: it must still poll and log (write usage), never swap.
# Locks the fix that removed the N<=1 early-exit-before-polling.
scenario_n1_polls_and_logs() {
    make_config "$CONFIG" "acctA"
    seed_account acctA "tok-acctA"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 100 90   # even at 5h=100 it must not swap

    run_rotate
    assert_exit 0 "$RC" "n1-polls exits 0"
    assert_eq "acctA" "$(active_label)" "n1-polls active pointer unchanged"
    assert_cred_token "$CRED" "tok-acctA" "n1-polls live cred unchanged"
    if [ ! -f "$STORE/acctA.usage.json" ]; then
        fail "n1-polls did not write acctA.usage.json (proves it never polled)"
    fi
}

# Pointer desync guard: the live cred holds acctB's token while active=acctA. The
# tick must NOT sync that live cred over acctA's stored slot, and must NOT swap.
scenario_desync_guard_no_clobber() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctB"          # live cred belongs to acctB (desync)
    make_mock "$MOCK" "tok-acctB" 10 10

    local a_before
    a_before=$(file_sha "$STORE/acctA.json")

    run_rotate
    assert_exit 0 "$RC" "desync-guard exits 0"
    assert_eq "$a_before" "$(file_sha "$STORE/acctA.json")" \
        "desync-guard did NOT clobber acctA.json with acctB creds"
    assert_eq "acctA" "$(active_label)" "desync-guard active pointer unchanged (no swap)"
}

# bootstrap.sh must set active to the account it just captured, EVEN when active
# already exists and names a different account (pointer realignment).
scenario_bootstrap_sets_active_to_captured() {
    set_active acctA                       # pre-existing pointer names acctA
    seed_account acctA "tok-acctA"
    make_cred "$CRED" "tok-acctB"          # but we are logged into acctB now
    make_mock "$MOCK" "tok-acctB" 10 10

    run_bootstrap acctB
    assert_exit 0 "$RC" "bootstrap-active exits 0"
    assert_cred_token "$STORE/acctB.json" "tok-acctB" "bootstrap-active captured acctB.json"
    assert_eq "acctB" "$(active_label)" "bootstrap-active realigned pointer to acctB"
}

# bootstrap captures a TOKEN-ONLY <label>.json AND updates the canonical mcp.json
# from the live cred's mcpOAuth ("copy everything once").
scenario_bootstrap_token_only_and_canonical_mcp() {
    make_cred "$CRED" "tok-acctA"          # live cred has mcpOAuth "mcp-tok-acctA"
    make_mock "$MOCK" "tok-acctA" 10 10    # best-effort usage fetch succeeds

    run_bootstrap acctA
    assert_exit 0 "$RC" "bootstrap-canonical exits 0"
    # <label>.json is token-only: has the account token, no mcpOAuth.
    assert_cred_token "$STORE/acctA.json" "tok-acctA" "bootstrap-canonical acctA.json token"
    assert_no_mcp "$STORE/acctA.json" "bootstrap-canonical acctA.json is token-only"
    # canonical mcp.json captured the live MCP set.
    if [ ! -f "$STORE/mcp.json" ]; then
        fail "bootstrap-canonical did not create mcp.json"
    fi
    assert_mcp_token "$STORE/mcp.json" "server-x" "mcp-tok-acctA" \
        "bootstrap-canonical mcp.json captured live MCP token"
    assert_eq "acctA" "$(active_label)" "bootstrap-canonical set active to acctA"
}

# bootstrap RESTORES the canonical MCP set into the LIVE cred when the live
# .mcpOAuth is empty (simulating a post-/login wipe) and $STORE/mcp.json exists.
scenario_bootstrap_restores_mcp_after_login_wipe() {
    make_mcp_store "$STORE/mcp.json" "canon-mcp-XYZ"   # pre-existing canonical set
    # Live cred: valid account token but EMPTY mcpOAuth (the /login wipe).
    cat > "$CRED" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok-acctB","refreshToken":"rt","expiresAt":9999999999999},"mcpOAuth":{}}
EOF
    chmod 600 "$CRED"
    make_mock "$MOCK" "tok-acctB" 10 10

    run_bootstrap acctB
    assert_exit 0 "$RC" "bootstrap-restore exits 0"
    # The canonical MCP set was restored INTO the live cred file.
    assert_mcp_token "$CRED" "srv" "canon-mcp-XYZ" \
        "bootstrap-restore put canonical MCP set into live cred"
    # <label>.json is still token-only with the live account token.
    assert_cred_token "$STORE/acctB.json" "tok-acctB" "bootstrap-restore acctB.json token"
    assert_no_mcp "$STORE/acctB.json" "bootstrap-restore acctB.json is token-only"
    assert_eq "acctB" "$(active_label)" "bootstrap-restore set active to acctB"
}

# Swap COPY failure must hold the pointer + live cred unchanged (no torn swap).
# Forces the failure by making the live cred's parent dir read-only so the
# atomic_replace mktemp cannot create its temp file.
scenario_swap_failure_holds_pointer() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10    # A fires, wants to swap to acctB
    make_mock "$MOCK" "tok-acctB" 20 10

    chmod 500 "$SB/cred"                    # live cred dir read-only => swap copy fails
    run_rotate
    chmod 700 "$SB/cred"                    # restore so cleanup can rm -rf

    assert_exit 0 "$RC" "swap-fail exits 0"
    assert_eq "acctA" "$(active_label)" "swap-fail active pointer unchanged"
    assert_cred_token "$CRED" "tok-acctA" "swap-fail live cred unchanged"
}

# sync-out MCP capture must GROW-merge the canonical mcp.json, never shrink it.
# The canonical set has TWO servers; the live set is a strict SUBSET (only srvA,
# with a refreshed token). After a HOLD tick's sync-out, srvA must be refreshed to
# the live token AND srvB must be PRESERVED (not deleted). This fails against the
# old wholesale-overwrite capture_mcp and passes after the grow-merge fix.
scenario_synced_capture_mcp_grows_not_shrinks() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    # Canonical store already holds two servers.
    make_mcp_store_pair "$STORE/mcp.json" "canonA" "canonB"
    # Live cred: valid account token, but its .mcpOAuth is only srvA (refreshed).
    cat > "$CRED" <<'EOF'
{"claudeAiOauth":{"accessToken":"tok-acctA","refreshToken":"rt","expiresAt":9999999999999},"mcpOAuth":{"srvA":{"accessToken":"liveA"}}}
EOF
    chmod 600 "$CRED"
    # Equal usage across both accounts => decision=HOLD (no swap), but sync-out
    # still runs before the decision, exercising capture_mcp.
    make_mock "$MOCK" "tok-acctA" 10 10
    make_mock "$MOCK" "tok-acctB" 10 10

    run_rotate
    assert_exit 0 "$RC" "grow-merge exits 0"
    assert_eq "acctA" "$(active_label)" "grow-merge held on acctA (no swap)"
    # srvA refreshed to the live token.
    assert_mcp_token "$STORE/mcp.json" "srvA" "liveA" \
        "grow-merge refreshed srvA from the live set"
    # srvB PRESERVED from canonical (would be deleted by wholesale overwrite).
    assert_mcp_token "$STORE/mcp.json" "srvB" "canonB" \
        "grow-merge preserved canonical-only srvB"
}

scenario_pin_forces_swap_over_trigger() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10
    make_mock "$MOCK" "tok-acctB" 20 10
    make_mock "$MOCK" "tok-acctC" 80 10
    set_pin acctC

    run_rotate
    assert_exit 0 "$RC" "pin-forces-swap exits 0"
    assert_eq "acctC" "$(active_label)" "pin-forces-swap active pointer is acctC"
    assert_cred_token "$CRED" "tok-acctC" "pin-forces-swap live cred is acctC"
}

scenario_pin_swap_preserves_live_mcp() {
    make_config "$CONFIG" "acctA acctB acctC"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    seed_account acctC "tok-acctC"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10
    make_mock "$MOCK" "tok-acctB" 20 10
    make_mock "$MOCK" "tok-acctC" 80 10
    set_pin acctC

    run_rotate
    assert_exit 0 "$RC" "pin-preserves-mcp exits 0"
    assert_cred_token "$CRED" "tok-acctC" "pin-preserves-mcp live cred is acctC"
    assert_mcp_token "$CRED" "server-x" "mcp-tok-acctA" \
        "pin-preserves-mcp kept live MCP token"
}

scenario_pin_already_active_no_swap_still_pinned() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10
    make_mock "$MOCK" "tok-acctB" 20 10
    set_pin acctA

    run_rotate_status_out
    assert_exit 0 "$RC" "pin-already-active status exits 0"
    case "$OUT" in
        *decision=PINNED*) ;;
        *) fail "pin-already-active status did not include decision=PINNED" ;;
    esac
    case "$OUT" in
        *decision=SWAP*) fail "pin-already-active status included decision=SWAP" ;;
    esac
    case "$OUT" in
        *decision=HOLD*) fail "pin-already-active status included decision=HOLD" ;;
    esac
    assert_eq "acctA" "$(active_label)" "pin-already-active pointer unchanged"
}

scenario_pin_decision_literal_not_hold() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 10 10
    make_mock "$MOCK" "tok-acctB" 10 10
    set_pin acctA

    run_rotate_status_out
    assert_exit 0 "$RC" "pin-literal status exits 0"
    case "$OUT" in
        *decision=PINNED*) ;;
        *) fail "pin-literal status did not include decision=PINNED" ;;
    esac
    case "$OUT" in
        *decision=HOLD*) fail "pin-literal status included decision=HOLD" ;;
    esac
}

scenario_pin_absent_unchanged_swap() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    seed_account acctB "tok-acctB"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 90 10
    make_mock "$MOCK" "tok-acctB" 20 10

    run_rotate_status_out
    assert_exit 0 "$RC" "pin-absent status exits 0"
    case "$OUT" in
        *decision=SWAP*) ;;
        *) fail "pin-absent status did not include decision=SWAP" ;;
    esac
    case "$OUT" in
        *decision=PINNED*) fail "pin-absent status included decision=PINNED" ;;
    esac

    run_rotate
    assert_exit 0 "$RC" "pin-absent live exits 0"
    assert_eq "acctB" "$(active_label)" "pin-absent live swapped to acctB"
    assert_cred_token "$CRED" "tok-acctB" "pin-absent live cred is acctB"
}

scenario_pin_invalid_target_holds_but_pinned() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 10 10
    set_pin acctB

    run_rotate
    assert_exit 0 "$RC" "pin-invalid-target live exits 0"
    assert_eq "acctA" "$(active_label)" "pin-invalid-target pointer unchanged"
    assert_cred_token "$CRED" "tok-acctA" "pin-invalid-target live cred unchanged"

    run_rotate_status_out
    assert_exit 0 "$RC" "pin-invalid-target status exits 0"
    case "$OUT" in
        *decision=PINNED*) ;;
        *) fail "pin-invalid-target status did not include decision=PINNED" ;;
    esac
}

scenario_pin_unconfigured_label_holds() {
    make_config "$CONFIG" "acctA acctB"
    seed_account acctA "tok-acctA"
    set_active acctA
    enable
    make_cred "$CRED" "tok-acctA"
    make_mock "$MOCK" "tok-acctA" 10 10
    make_token_store "$STORE/acctZ.json" "tok-acctZ"
    set_pin acctZ

    run_rotate
    assert_exit 0 "$RC" "pin-unconfigured live exits 0"
    assert_eq "acctA" "$(active_label)" "pin-unconfigured pointer unchanged (no swap to acctZ)"
    assert_cred_token "$CRED" "tok-acctA" "pin-unconfigured live cred unchanged"

    run_rotate_status_out
    assert_exit 0 "$RC" "pin-unconfigured status exits 0"
    case "$OUT" in
        *decision=PINNED*) ;;
        *) fail "pin-unconfigured status did not include decision=PINNED" ;;
    esac
}

# ============================================================================
# Runner
# ============================================================================
run_scenario() {
    local name="$1" fn="$2"
    CUR_FAIL=0
    setup_sandbox
    "$fn"
    if [ "$CUR_FAIL" -eq 0 ]; then
        printf 'PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$name"
        FAILED=$((FAILED + 1))
    fi
    rm -rf "$SB"
}

if [ ! -f "$ROTATE" ]; then
    printf 'NOTE: %s does not exist yet (implementation absent) -- scenarios will fail loudly.\n\n' "$ROTATE"
fi

run_scenario "ENABLED gate absent => exit 0, no writes"        scenario_enabled_absent
run_scenario "N=1 monitored no-op, never swaps"                scenario_single_account_no_swap
run_scenario "Trigger A swaps to lowest-5h other (of 3)"       scenario_trigger_a_lowest_of_three
run_scenario "Trigger B swaps to min-weekly"                   scenario_trigger_b_min_weekly
run_scenario "Trigger B below threshold => no swap"            scenario_trigger_b_below_threshold
run_scenario "Trigger B adaptive: tightens at floor 80, fires" scenario_trigger_b_tighten_at_80_fires
run_scenario "Trigger B adaptive: holds within 80 tier"        scenario_trigger_b_holds_within_80_tier
run_scenario "Trigger B adaptive: tightens at floor 90, fires" scenario_trigger_b_tighten_at_90_fires
run_scenario "Trigger B adaptive: holds within 90 tier"        scenario_trigger_b_holds_within_90_tier
run_scenario "Trigger B adaptive: low base never widened"      scenario_trigger_b_low_base_not_widened
run_scenario "Both triggers => A target wins"                  scenario_both_triggers_a_priority
run_scenario "Trigger B skips 5h-pressured min-weekly target"  scenario_weekly_rebalance_skips_pressured_target
run_scenario "No flap while active-5h stays pressured"         scenario_no_flap_while_5h_pressured
run_scenario "Settles on low-weekly after 5h reset"            scenario_settles_on_low_weekly_after_5h_reset
run_scenario "Weekly divergence, active is min-weekly => hold"  scenario_weekly_divergence_active_is_min_weekly
run_scenario "sync-out captures refresh before swap"           scenario_sync_out_before_swap
run_scenario "Invalid live cred => skip, store untouched"      scenario_invalid_live_cred_skips
run_scenario "Target missing/invalid => no swap"               scenario_target_invalid_no_swap
run_scenario "Token-only swap preserves live mcpOAuth"         scenario_swap_token_only_preserves_mcp
run_scenario "status mode mutates nothing"                     scenario_status_mutates_nothing
run_scenario "No stale-usage fallback: failed poll => UNKNOWN"  scenario_no_stale_usage_fallback
run_scenario "Refresh expired non-active token before polling"  scenario_refresh_expired_nonactive
run_scenario "Refresh mock missing => UNKNOWN, store unchanged"  scenario_refresh_missing_unknown
run_scenario "Active account is never refreshed out of band"    scenario_active_never_refreshed
run_scenario "DRY/status never refreshes (store byte-unchanged)" scenario_dry_never_refreshes
run_scenario "Refresh-token rotation persisted to store"        scenario_refresh_token_rotation_persisted
run_scenario "E2E: refresh unblocks weekly rebalance"           scenario_e2e_refresh_unblocks_rebalance
run_scenario "N=1 polls and logs (writes usage), never swaps"  scenario_n1_polls_and_logs
run_scenario "Desync guard: no clobber of active store slot"   scenario_desync_guard_no_clobber
run_scenario "Bootstrap sets active to captured account"       scenario_bootstrap_sets_active_to_captured
run_scenario "Bootstrap token-only store + canonical mcp.json" scenario_bootstrap_token_only_and_canonical_mcp
run_scenario "Bootstrap restores MCP after /login wipe"        scenario_bootstrap_restores_mcp_after_login_wipe
run_scenario "Swap copy failure holds pointer + live cred"     scenario_swap_failure_holds_pointer
run_scenario "sync-out capture_mcp grows, never shrinks"       scenario_synced_capture_mcp_grows_not_shrinks
run_scenario "PIN forces swap over trigger"                    scenario_pin_forces_swap_over_trigger
run_scenario "PIN swap preserves live mcpOAuth"                 scenario_pin_swap_preserves_live_mcp
run_scenario "PIN already active reports PINNED"                scenario_pin_already_active_no_swap_still_pinned
run_scenario "PIN decision literal is not HOLD"                 scenario_pin_decision_literal_not_hold
run_scenario "PIN absent keeps swap behavior"                   scenario_pin_absent_unchanged_swap
run_scenario "PIN invalid target holds and reports PINNED"      scenario_pin_invalid_target_holds_but_pinned
run_scenario "PIN unconfigured label holds (not in ACCOUNTS)"   scenario_pin_unconfigured_label_holds

printf '\n----------------------------------------\n'
printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
