#!/bin/bash
set -euo pipefail

#=============================================================================
# arbox-signup.sh v2.2.0 — Arbox Auto-Signup Script
#
# Automatically signs up for CrossFit classes via Arbox API, up to N days
# in advance. Sends notifications via Telegram.
#
# Usage:
#   ./arbox-signup.sh                    # Uses .env file for config
#   ./arbox-signup.sh -e EMAIL -p PASS -h 08:00
#   ./arbox-signup.sh --dry-run          # Preview without signing up
#   ./arbox-signup.sh --cleanup          # Remove old CSV entries (>30 days)
#   ./arbox-signup.sh --list-friends     # List friends from your profile
#   ./arbox-signup.sh --invite-friend "NAME"  # Invite a friend (POST userToUser/schedule/invite)
#   ./arbox-signup.sh --check-invite "NAME"   # Check invite status (POST friendConnection/schedule)
#   ./arbox-signup.sh --invite-all            # Full run: signup 12 days + invite all friends to my classes
#   ./arbox-signup.sh --invite-fridays        # Daily run: signup 12 days + invite friends to FRIDAY classes only
#
# Config priority: CLI args > .env file > defaults
#=============================================================================

readonly VERSION="2.3.2"
readonly LOCK_TIMEOUT=300
readonly MAX_LOG_SIZE=$((5 * 1024 * 1024))
readonly CSV_RETENTION_DAYS=30
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly API_BASE="https://apiappv2.arboxapp.com/api/v2"

# All dates/logs in Israel time (GitHub runners default to UTC).
export TZ="Asia/Jerusalem"

# Browser-impersonation headers (v2.2.0): Arbox/Cloudflare sometimes blocks
# bare cloud IPs. Send what the real web app sends. The Safari UA below is
# Safari 26 (macOS Tahoe) — bump it when Safari moves on. The 'version' /
# 'referername' headers are what the app's own client sends (see the
# saar120/arbox-automation-v2 client).
readonly USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_26_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
readonly ARBOX_ORIGIN="https://app.arboxapp.com"
readonly ARBOX_REFERER="https://app.arboxapp.com/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="$SCRIPT_DIR/signups.csv"
INVITES_FILE="$SCRIPT_DIR/invites.csv"
LOG_FILE="$SCRIPT_DIR/sign.log"
LOCK_FILE="$SCRIPT_DIR/.arbox-signup.lock"
# curl_with_retry runs inside $(...) subshells, so the last HTTP status is
# passed back to callers via this file (variables cannot escape a subshell).
HTTP_STATUS_FILE="$SCRIPT_DIR/.last_http_status"
ENV_FILE="$SCRIPT_DIR/.env"
CACHE_FILE="$SCRIPT_DIR/.arbox_cache"

DRY_RUN=false
CLEANUP_ONLY=false
LIST_FRIENDS=false
INVITE_FRIEND=""
CHECK_INVITE=""
INVITE_ALL=false
INVITE_FRIDAYS=false  # daily-run mode: invite friends to Friday classes only
# Classes Aviel is signed up for (JSON array of {schedule_id, day, date,
# class, time}) — collected by do_signup for the invite-all phase.
SIGNED_UP_CLASSES_JSON="[]"
email=""
password=""
signup_hour=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
BOX_ID=""
DAYS_AHEAD=12
CLASS_FRIDAY="Fuck You Friday"
CLASS_DEFAULT="CrossFit"
SKIP_DAYS="Saturday"

# ── Load .env ─────────────────────────────────────────────────────────────
load_env() {
  if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      value="${value%\"}"
      value="${value#\"}"
      case "$key" in
        ARBOX_EMAIL)        [ -z "$email" ] && email="$value" ;;
        ARBOX_PASSWORD)     [ -z "$password" ] && password="$value" ;;
        SIGNUP_HOUR)        [ -z "$signup_hour" ] && signup_hour="$value" ;;
        TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="$value" ;;
        TELEGRAM_CHAT_ID)   TELEGRAM_CHAT_ID="$value" ;;
        BOX_ID)             BOX_ID="$value" ;;
        DAYS_AHEAD)         DAYS_AHEAD="$value" ;;
        CLASS_FRIDAY)       CLASS_FRIDAY="$value" ;;
        CLASS_DEFAULT)      CLASS_DEFAULT="$value" ;;
        SKIP_DAYS)          SKIP_DAYS="$value" ;;
      esac
    done < "$ENV_FILE"
    log_message "Loaded config from .env"
  fi
}

# ── Cache management ──────────────────────────────────────────────────────
load_cache() {
  if [ -f "$CACHE_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      case "$key" in
        BOX_ID)              [ -z "$BOX_ID" ] && BOX_ID="$value" ;;
        LOCATION_BOX_FK)     CACHED_LOCATION_BOX_FK="$value" ;;
        MEMBERSHIP_USER_ID)  CACHED_MEMBERSHIP_USER_ID="$value" ;;
      esac
    done < "$CACHE_FILE"
    log_message "Loaded cached membership data from .arbox_cache"
    return 0
  fi
  return 1
}

save_cache() {
  local box_id="$1" location_box_fk="$2" membership_user_id="$3" user_fk="${4:-}"
  cat > "$CACHE_FILE" <<EOF
# Arbox membership cache (auto-generated, do not edit)
# Fetched: $(date '+%Y-%m-%d %H:%M:%S')
BOX_ID=$box_id
LOCATION_BOX_FK=$location_box_fk
MEMBERSHIP_USER_ID=$membership_user_id
USER_FK=$user_fk
EOF
  log_message "Saved membership cache: box=$box_id location=$location_box_fk user=$membership_user_id"
}

# ── Dependency check ──────────────────────────────────────────────────────
check_dependencies() {
  local missing=()
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: Missing required dependencies: ${missing[*]}"
    echo "Install: sudo yum install -y ${missing[*]}  (Amazon Linux)"
    echo "    or:  brew install ${missing[*]}          (macOS)"
    exit 1
  fi
}

# ── Lock file ─────────────────────────────────────────────────────────────
acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      local lock_age
      if [[ "$OSTYPE" == "darwin"* ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
      else
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
      fi
      if [ "$lock_age" -gt "$LOCK_TIMEOUT" ]; then
        log_message "WARNING: Stale lock (age: ${lock_age}s), removing"
        rm -f "$LOCK_FILE"
      else
        log_message "ERROR: Another instance running (PID: $lock_pid)"
        send_telegram_message "⚠️ Arbox script blocked by another instance (PID $lock_pid)"
        exit 1
      fi
    else
      log_message "Removing stale lock (PID $lock_pid not running)"
      rm -f "$LOCK_FILE"
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap release_lock EXIT INT TERM
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ── Logging ───────────────────────────────────────────────────────────────
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

rotate_log() {
  if [ -f "$LOG_FILE" ]; then
    local log_size
    if [[ "$OSTYPE" == "darwin"* ]]; then
      log_size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    else
      log_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    fi
    if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
      local ts
      ts=$(date '+%Y%m%d_%H%M%S')
      mv "$LOG_FILE" "${LOG_FILE}.${ts}.bak"
      ls -t "${LOG_FILE}".*.bak 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      log_message "Log rotated (previous: $log_size bytes)"
    fi
  fi
}

# ── CSV ───────────────────────────────────────────────────────────────────
init_csv() {
  if [ ! -f "$CSV_FILE" ]; then
    echo "date,time,class_name,status,timestamp" > "$CSV_FILE"
  fi
}

cleanup_csv() {
  if [ ! -f "$CSV_FILE" ]; then
    echo "No CSV file to clean up."
    return
  fi
  local cutoff_date temp_file line_count_before line_count_after
  if [[ "$OSTYPE" == "darwin"* ]]; then
    cutoff_date=$(date -v-${CSV_RETENTION_DAYS}d "+%d-%m-%Y")
  else
    cutoff_date=$(date -d "-${CSV_RETENTION_DAYS} days" "+%d-%m-%Y")
  fi
  temp_file=$(mktemp)
  line_count_before=$(wc -l < "$CSV_FILE" | tr -d ' ')
  head -1 "$CSV_FILE" > "$temp_file"
  tail -n +2 "$CSV_FILE" | while IFS=',' read -r entry_date rest; do
    local day month year
    IFS='-' read -r day month year <<< "$entry_date"
    local entry_epoch cutoff_epoch
    if [[ "$OSTYPE" == "darwin"* ]]; then
      entry_epoch=$(date -j -f "%d-%m-%Y" "$entry_date" "+%s" 2>/dev/null || echo 0)
      cutoff_epoch=$(date -j -f "%d-%m-%Y" "$cutoff_date" "+%s" 2>/dev/null || echo 0)
    else
      entry_epoch=$(date -d "$year-$month-$day" "+%s" 2>/dev/null || echo 0)
      local cd cm cy
      IFS='-' read -r cd cm cy <<< "$cutoff_date"
      cutoff_epoch=$(date -d "$cy-$cm-$cd" "+%s" 2>/dev/null || echo 0)
    fi
    if [ "$entry_epoch" -ge "$cutoff_epoch" ] 2>/dev/null; then
      echo "$entry_date,$rest" >> "$temp_file"
    fi
  done
  mv "$temp_file" "$CSV_FILE"
  line_count_after=$(wc -l < "$CSV_FILE" | tr -d ' ')
  local removed=$(( line_count_before - line_count_after ))
  log_message "CSV cleanup: removed $removed entries older than $CSV_RETENTION_DAYS days"
  echo "CSV cleanup: removed $removed entries older than $CSV_RETENTION_DAYS days"
}

is_in_csv() {
  grep -q "^$1,$2," "$CSV_FILE"
}

add_to_csv() {
  echo "$1,$2,$3,$4,$(date '+%Y-%m-%d %H:%M:%S')" >> "$CSV_FILE"
}

# ── Invites ledger (dedupe) ──────────────────────────────────────────────
# invites.csv columns: schedule_id,friend_users_id,date,friend_name,status,timestamp
# A (schedule_id, friend) pair with status=invited is NEVER invited again —
# if we invited today, tomorrow's run skips that class for that friend
# ("no need to pester"). Failed rows are retried on the next run.
# NOTE: for the dedupe to survive on ephemeral GitHub runners, invites.csv
# must be in the workflow cache (same as signups.csv).
is_invited() {
  [ -f "$INVITES_FILE" ] && awk -F, -v s="$1" -v f="$2" '$1==s && $2==f && $5=="invited" {found=1} END{exit !found}' "$INVITES_FILE"
}

add_to_invites() {
  echo "$1,$2,$3,$4,$5,$(date '+%Y-%m-%d %H:%M:%S')" >> "$INVITES_FILE"
}

# Record a class Aviel is signed up for (for the invite-all phase).
# schedule_id is numeric — passed with --argjson. Never aborts the run:
# on any jq failure it logs a warning and returns 0.
note_signed_up_class() {
  local updated
  updated=$(echo "$SIGNED_UP_CLASSES_JSON" | jq -c --argjson sid "$1" --arg day "$2" --arg date "$3" --arg cls "$4" --arg time "$5" '. + [{schedule_id:$sid, day:$day, date:$date, class:$cls, time:$time}]' 2>/dev/null) || {
    log_message "WARNING: note_signed_up_class failed (schedule $1)"
    return 0
  }
  SIGNED_UP_CLASSES_JSON="$updated"
}

# ── Date (cross-platform) ────────────────────────────────────────────────
format_date() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date -v+${1}d +"$2"
  else
    date -d "+$1 days" +"$2"
  fi
}

# Last HTTP status seen by curl_with_retry (0 = no response at all).
# Read via the file because curl_with_retry runs inside $(...) subshells.
last_http_status() {
  local s=""
  s=$(cat "$HTTP_STATUS_FILE" 2>/dev/null || echo "")
  if [ -n "$s" ]; then echo "$s"; else echo "0"; fi
}

# ── HTTP with retry ──────────────────────────────────────────────────────
# On success prints the JSON body to stdout and returns 0. On failure logs
# every attempt with its HTTP status + a truncated body snippet, and returns 1.
# Contract: ANY valid-JSON body is returned (even non-2xx) — Arbox encodes
# business errors in the body (.statusCode 512/514) and callers parse them.
# Only empty / non-JSON responses are retried (transport failure).
# NOTE: the body snippet is logged on failures only, truncated to 300 chars.
curl_with_retry() {
  local method="$1" url="$2" data="${3:-}" token="${4:-}"
  local attempt=0
  local http_code="0" body_snippet=""

  printf '0' > "$HTTP_STATUS_FILE" 2>/dev/null || true

  while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    local tmp_body
    tmp_body=$(mktemp)
    local curl_args=(-s --max-time 30 --connect-timeout 10
      -H 'Content-Type: application/json'
      -H 'Accept: application/json'
      -H "User-Agent: $USER_AGENT"
      -H "Origin: $ARBOX_ORIGIN"
      -H "Referer: $ARBOX_REFERER"
      -H 'version: 11'
      -H 'referername: app')
    [ -n "$token" ] && curl_args+=(-H "accesstoken: $token")
    if [ "$method" = "POST" ]; then
      curl_args+=(-X POST)
      [ -n "$data" ] && curl_args+=(--data-raw "$data")
    fi

    # -o file + -w code keeps stdout clean (only the body is echoed on
    # success) and gives us the real HTTP status even for empty bodies.
    http_code=$(curl "${curl_args[@]}" -o "$tmp_body" -w '%{http_code}' "$url" 2>/dev/null) || http_code="0"
    case "$http_code" in ''|*[!0-9]*) http_code="0" ;; esac
    local raw_response
    raw_response=$(cat "$tmp_body" 2>/dev/null || true)
    rm -f "$tmp_body"
    printf '%s' "$http_code" > "$HTTP_STATUS_FILE" 2>/dev/null || true
    body_snippet=$(printf '%s' "$raw_response" | tr '\n' ' ' 2>/dev/null | head -c 300 || true)

    # Plain-text "OK" with 2xx is also a success: the invite endpoint
    # (userToUser/schedule/invite) answers HTTP 200 with body "OK", not
    # JSON (live run #229, Nov 16 2026 — the script retried it 3 times
    # before this was fixed). The app's own wrapper treats a response of
    # true or "OK" as success.
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && [ "$(printf '%s' "$raw_response" | tr -d '[:space:]')" = "OK" ]; then
      echo "$raw_response"
      return 0
    fi

    if [ -n "$raw_response" ] && echo "$raw_response" | jq empty 2>/dev/null; then
      if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "$raw_response"
        return 0
      fi
      # Arbox returns business errors as non-2xx HTTP WITH a JSON body
      # (e.g. HTTP 512 "Incorrect Login Details", HTTP 514 already signed).
      # The body is what callers parse (.statusCode / .message / .data), so
      # return it without retrying — retrying a definitive rejection only
      # wastes time and hides the real reason.
      log_message "API returned HTTP $http_code with JSON body: $method $url (body: ${body_snippet:-<empty>})"
      echo "$raw_response"
      return 0
    fi

    log_message "API attempt $attempt/$MAX_RETRIES failed: $method $url (HTTP $http_code, body: ${body_snippet:-<empty>})"
    if [ $attempt -lt $MAX_RETRIES ]; then
      local wait=$((RETRY_DELAY * attempt))
      log_message "API retry $attempt/$MAX_RETRIES for $url (${wait}s)"
      sleep "$wait"
    fi
  done

  log_message "ERROR: API failed after $MAX_RETRIES attempts: $method $url (last HTTP $http_code, body: ${body_snippet:-<empty>})"
  return 1
}

# ── Telegram ──────────────────────────────────────────────────────────────
send_telegram_message() {
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log_message "WARNING: Telegram not configured"
    return 0
  fi
  if $DRY_RUN; then
    log_message "[DRY RUN] Telegram: $1"
    echo "[DRY RUN] Telegram: $1"
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$1" \
    --max-time 10 >/dev/null 2>&1 || log_message "WARNING: Telegram send failed"
}

# ── Telegram photo ───────────────────────────────────────────────────────
# Sends a rendered card image with a caption. Returns 0 on success.
send_telegram_photo() {
  local photo_path="$1" caption="$2"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log_message "WARNING: Telegram not configured (photo not sent)"
    return 1
  fi
  if [ ! -f "$photo_path" ]; then
    log_message "WARNING: Card image missing: $photo_path"
    return 1
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
    -F chat_id="$TELEGRAM_CHAT_ID" \
    -F photo=@"$photo_path" \
    -F caption="$caption" \
    --max-time 30 >/dev/null 2>&1
}

# ── Validators ────────────────────────────────────────────────────────────
validate_hour() {
  if ! [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Error: Invalid hour format. Use HH:MM (00:00-23:59)."
    exit 1
  fi
}

should_skip_day() {
  IFS=',' read -ra skip_arr <<< "$SKIP_DAYS"
  for s in "${skip_arr[@]}"; do
    s=$(echo "$s" | xargs)
    [ "$1" = "$s" ] && return 0
  done
  return 1
}

get_class_name() {
  if [ "$1" = "Friday" ]; then
    echo "$CLASS_FRIDAY"
  else
    echo "$CLASS_DEFAULT"
  fi
}

# ── CLI args ──────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e) email="$2"; shift 2 ;;
      -p) password="$2"; shift 2 ;;
      -h) signup_hour="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --cleanup) CLEANUP_ONLY=true; shift ;;
      --list-friends) LIST_FRIENDS=true; shift ;;
      --invite-friend)
        if [ -z "${2:-}" ]; then echo "Error: --invite-friend needs a friend name."; exit 1; fi
        INVITE_FRIEND="$2"; shift 2 ;;
      --check-invite)
        if [ -z "${2:-}" ]; then echo "Error: --check-invite needs a friend name."; exit 1; fi
        CHECK_INVITE="$2"; shift 2 ;;
      --invite-all) INVITE_ALL=true; shift ;;
      --invite-fridays) INVITE_FRIDAYS=true; shift ;;
      --version) echo "arbox-signup.sh v$VERSION"; exit 0 ;;
      --help)    show_help; exit 0 ;;
      *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done
}

show_help() {
  cat <<EOF
arbox-signup.sh v$VERSION - Arbox Auto-Signup

Usage: $0 [options]

Options:
  -e EMAIL       Arbox account email
  -p PASSWORD    Arbox account password
  -h HOUR        Class time HH:MM (e.g., 08:00)
  --dry-run      Preview without signing up
  --cleanup      Remove old CSV entries and exit
  --list-friends List friends from your Arbox profile (no signups)
  --invite-friend NAME
                 Invite a friend (by name, case-insensitive substring) to
                 the next upcoming class: POST userToUser/schedule/invite
                 (endpoint from the Arbox web-app bundle). The friend must
                 approve in the app to join. Manual use only, never in the
                 daily run.
  --check-invite NAME
                 Ask the server for a friend's invite status:
                 POST friendConnection/schedule. Sends nothing, invites
                 nobody. Manual use only, never in the daily run.
  --invite-all   Full run: sign up for the next 12 days, then invite ALL
                 friends to every class you are signed up for. Sent invites
                 are recorded in invites.csv and never re-sent to the same
                 class. One combined Telegram card at the end. Manual use
                 only, never in the daily run.
  --invite-fridays
                 Daily run: sign up for the next 12 days, then invite ALL
                 friends to FRIDAY classes only (the rest of the week is
                 not invited). Same invites.csv dedupe. Sends a short
                 Telegram note only on days a new Friday invite went out;
                 the normal daily signup report is unchanged. Used by the
                 scheduled workflow run (github.event_name == schedule).
  --version      Show version
  --help         Show this help

Config: Create .env file (see .env.example) to avoid CLI credentials.
        CLI args override .env values.
EOF
}

# ── Shared login + membership (used by all modes) ────────────────────────
# Sets globals ACCESS_TOKEN, LOCATION_BOX_FK, BOX_FK, MEMBERSHIP_USER_ID.
arbox_login() {
  log_message "Logging in as $email"
  local login_payload
  login_payload=$(jq -n --arg email "$email" --arg password "$password" \
    '{email: $email, password: $password}')
  local login_response
  login_response=$(curl_with_retry POST "$API_BASE/user/login" \
    "$login_payload") || {
    log_message "ERROR: Login request failed (HTTP $(last_http_status))"
    echo "Login request failed (HTTP $(last_http_status))" >&2
    send_telegram_message "❌ Login request failed (network error, HTTP $(last_http_status))"
    exit 1
  }

  ACCESS_TOKEN=$(echo "$login_response" | jq -r '.data.token // empty')
  if [ -z "$ACCESS_TOKEN" ]; then
    local err
    # Arbox nests the reason under .error.message, not top-level .message.
    err=$(echo "$login_response" | jq -r '.message // .error.message // "Unknown error"')
    log_message "ERROR: Login failed (HTTP $(last_http_status)): $err"
    echo "Login failed (HTTP $(last_http_status)): $err" >&2
    send_telegram_message "❌ Login failed (HTTP $(last_http_status)): $err"
    exit 1
  fi
  log_message "Login successful"
}

ensure_membership() {
  # A cache older than 7 days is ignored and re-fetched (v2.2.0): a stale
  # membership id silently books against the wrong membership.
  if [ -f "$CACHE_FILE" ]; then
    local cache_mtime=0
    if [[ "$OSTYPE" == "darwin"* ]]; then
      cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
    else
      cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    fi
    if [ $(( $(date +%s) - cache_mtime )) -gt $((7 * 86400)) ]; then
      log_message "Membership cache is older than 7 days, ignoring it"
      CACHED_LOCATION_BOX_FK=""
      CACHED_MEMBERSHIP_USER_ID=""
    fi
  fi

  if [ -n "$CACHED_LOCATION_BOX_FK" ] && [ -n "$CACHED_MEMBERSHIP_USER_ID" ] && [ -n "$BOX_ID" ]; then
    LOCATION_BOX_FK="$CACHED_LOCATION_BOX_FK"
    BOX_FK="$BOX_ID"
    MEMBERSHIP_USER_ID="$CACHED_MEMBERSHIP_USER_ID"
    log_message "Using cached membership: box=$BOX_FK location=$LOCATION_BOX_FK user=$MEMBERSHIP_USER_ID"
    return 0
  fi

  # First run, cache missing or stale — discover from API
  log_message "No cache found, fetching membership from API..."

  # If BOX_ID not set, try to discover it
  local discover_box_id="${BOX_ID:-70}"
  local membership_response
  membership_response=$(curl_with_retry GET "$API_BASE/boxes/$discover_box_id/memberships/1" "" "$ACCESS_TOKEN") || {
    log_message "ERROR: Membership request failed (HTTP $(last_http_status))"
    send_telegram_message "❌ Failed to fetch membership details (HTTP $(last_http_status))"
    exit 1
  }

  LOCATION_BOX_FK=$(echo "$membership_response" | jq -r '.data[0].membership_types.location_box_fk')
  BOX_FK=$(echo "$membership_response" | jq -r '.data[0].box_fk')
  MEMBERSHIP_USER_ID=$(echo "$membership_response" | jq -r '.data[0].id')
  local user_fk
  user_fk=$(echo "$membership_response" | jq -r '.data[0].user_fk // empty')

  if [ -z "$LOCATION_BOX_FK" ] || [ "$LOCATION_BOX_FK" = "null" ] || \
     [ -z "$BOX_FK" ] || [ "$BOX_FK" = "null" ] || \
     [ -z "$MEMBERSHIP_USER_ID" ] || [ "$MEMBERSHIP_USER_ID" = "null" ]; then
    log_message "ERROR: Failed to retrieve membership details"
    send_telegram_message "❌ Failed to retrieve membership details"
    exit 1
  fi

  # Save to cache for next run
  save_cache "$BOX_FK" "$LOCATION_BOX_FK" "$MEMBERSHIP_USER_ID" "$user_fk"
  BOX_ID="$BOX_FK"
  log_message "Membership fetched & cached: box=$BOX_FK location=$LOCATION_BOX_FK user=$MEMBERSHIP_USER_ID"
}

# Try the "smart" standby endpoint: it books if a spot is free, otherwise
# waitlists. The old endpoint /scheduleUser/insertStandby was renamed by
# Arbox on 2026-04-20 to /scheduleStandBy/insert (per the arbox-bot and
# arbox-scheduler projects) — the old path is presumed dead; if this one
# 404s the log will show the HTTP status.
# Returns 0 when the user ends up booked or waitlisted, 1 otherwise.
# Updates the do_signup counters (new_signups / new_signups_json /
# signup_summary) through bash dynamic scope — call only from do_signup.
try_standby() {
  local class_id="$1" day="$2" check_date="$3" check_class_name="$4"
  local wl_response
  wl_response=$(curl_with_retry POST "$API_BASE/scheduleStandBy/insert" \
    '{"schedule_id":'"$class_id"',"membership_user_id":'"$MEMBERSHIP_USER_ID"'}' \
    "$ACCESS_TOKEN") || true

  if [ -z "$wl_response" ] || ! echo "$wl_response" | jq -e '.data' >/dev/null 2>&1; then
    log_message "Day $check_date - Standby endpoint failed (HTTP $(last_http_status))"
    return 1
  fi

  local wl_booked wl_standby
  wl_booked=$(echo "$wl_response" | jq -r '.data.user_booked // false')
  wl_standby=$(echo "$wl_response" | jq -r '.data.user_in_standby // false')
  if [ "$wl_booked" = "true" ]; then
    add_to_csv "$check_date" "$signup_hour" "$check_class_name" "signed_up"
    note_signed_up_class "$class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
    signup_summary="${signup_summary}✅ $day $check_date $check_class_name${capacity_info}\n"
    new_signups=$((new_signups + 1))
    new_signups_json=$(echo "$new_signups_json" | jq -c --arg day "$day" --arg date "$check_date" --arg cls "$check_class_name" --arg time "$signup_hour" '. + [{day:$day, date:$date, class:$cls, time:$time}]')
    log_message "Day $check_date - Booked via standby endpoint!"
    return 0
  fi
  # .data present but neither flag: legacy response shape — treat as waitlisted.
  add_to_csv "$check_date" "$signup_hour" "$check_class_name" "waitlist"
  signup_summary="${signup_summary}📋 $day $check_date (waitlist)${capacity_info}\n"
  log_message "Day $check_date - Waitlisted (booked=$wl_booked standby=$wl_standby)"
  return 0
}

# ── Friends ──────────────────────────────────────────────────────────────
# Field names are real, from saar120/arbox-automation-v2
# (src/types/userInfo.ts + src/arboxAPI.ts getProfile):
#   GET /api/v2/user/profile -> .data.friend_connection[]
#   FriendConnection { id, users_id, friend_users_id, status, user }
#   FriendUser { id, first_name, last_name, full_name,
#                 users_boxes_active: UsersBoxActive[] | Record }
#   UsersBoxActive { id, box_fk, user_fk, full_name, ... }
# users_boxes_active may be an ARRAY or an OBJECT — jq handles both below.
fetch_profile() {
  curl_with_retry GET "$API_BASE/user/profile" "" "$ACCESS_TOKEN"
}

print_friends() {
  # v2.2.3: the live API nests the friend under .friend_user, NOT .user
  # (saar120's types said .user — wrong for this API version). Null-tolerant
  # as before: name falls back to first+last, then to "unknown"; boxes fall
  # back to an empty list.
  echo "$1" | jq -r '
    def display_name:
      ((.friend_user.full_name // (((.friend_user.first_name // "") + " " + (.friend_user.last_name // "")) | sub("^ +$"; "") | sub("^ +"; "") | sub(" +$"; ""))) // "unknown")
      | if . == "" then "unknown" else . end;
    def boxes:
      ((.friend_user.users_boxes_active // []) | if type == "array" then . else to_entries | map(.value) end);
    (.data.friend_connection // [])[] |
    "• \(display_name) | friend_users_id=\(.friend_users_id) | status=\(.status) | connection_id=\(.id)",
    "  boxes: \([boxes[] | "id=\(.id) box_fk=\(.box_fk) user_fk=\(.user_fk)\(.box.name // "" | if . == "" then "" else " name=" + . end)"] | join(", "))"'
}

do_list_friends() {
  arbox_login
  local profile_json
  profile_json=$(fetch_profile) || {
    log_message "ERROR: Failed to fetch profile (HTTP $(last_http_status))"
    echo "Failed to fetch profile (HTTP $(last_http_status)). See sign.log."
    exit 1
  }
  local count
  count=$(echo "$profile_json" | jq -r '.data.friend_connection // [] | length')
  echo "Friends ($count):"
  if [ "$count" = "0" ]; then
    echo "No friends found on your Arbox profile."
  else
    print_friends "$profile_json"
  fi
  log_message "Listed $count friends"
}

# ── Invite a friend ──────────────────────────────────────────────────────
# Real endpoint, found Nov 16 2026 in Arbox's own web-app code
# (site.arboxapp.com SPA bundle, app chunk): POST /api/v2/userToUser/schedule/invite
# with body {schedule_id, friend_users_id}; success iff response .data is
# true or "OK". The friend then gets an invitation card (ACTION_SCHEDULE_INVITATION)
# and joins by booking the class themselves — the app never books on
# another user's behalf, and there is no accept endpoint in the bundle.
# Manual use only, never scheduled. Only the NEXT upcoming 08:00 class is
# attempted, never the whole 12 days. Live-proven Nov 16 2026 (run #229):
# the server answers HTTP 200 with body "OK" — verify in the app that the
# friend shows as invited (the first live run sent the POST 3 times before
# the plain-text-OK fix, so check for duplicates too).
do_invite_friend() {
  local query="$1"
  arbox_login
  ensure_membership
  local profile_json
  profile_json=$(fetch_profile) || {
    log_message "ERROR: Invite probe: failed to fetch profile (HTTP $(last_http_status))"
    echo "Failed to fetch profile (HTTP $(last_http_status)). See sign.log."
    exit 1
  }

  local q_lower
  q_lower=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')
  local match_json
  match_json=$(echo "$profile_json" | jq -c --arg q "$q_lower" '
    (.data.friend_connection // []) | map(select(((.friend_user.full_name // "") | ascii_downcase | contains($q))))')

  local match_count
  match_count=$(echo "$match_json" | jq 'length')
  if [ "$match_count" = "0" ]; then
    echo "No friend matching \"$query\" found. Your friends:"
    print_friends "$profile_json"
    log_message "Invite probe: no friend matches '$query'"
    exit 1
  fi
  if [ "$match_count" != "1" ]; then
    echo "Multiple friends match \"$query\" — be more specific:"
    echo "$match_json" | jq -r '.[] | (.friend_user.full_name // "unknown")'
    exit 1
  fi

  local friend_name friend_users_id
  friend_name=$(echo "$match_json" | jq -r '.[0].friend_user.full_name // "unknown"')
  friend_users_id=$(echo "$match_json" | jq -r '.[0].friend_users_id')
  echo "Invite: $friend_name (friend_users_id=$friend_users_id) via POST userToUser/schedule/invite"
  log_message "Invite: $friend_name (friend_users_id=$friend_users_id) via userToUser/schedule/invite"

  # Find the next upcoming 08:00 class (skips Saturdays, respects the
  # booking-window flag when present).
  local class_id="" class_day="" class_date="" class_name=""
  for days_ahead in $(seq 1 "$DAYS_AHEAD"); do
    local check_date day check_class_name
    check_date=$(format_date "$days_ahead" "%d-%m-%Y")
    day=$(format_date "$days_ahead" "%A")
    check_class_name=$(get_class_name "$day")
    should_skip_day "$day" && continue
    local check_schedule
    check_schedule=$(curl_with_retry POST "$API_BASE/schedule/betweenDates" \
      '{"from":"'"$check_date"'","to":"'"$check_date"'","locations_box_id":'"$LOCATION_BOX_FK"',"boxes_id":'"$BOX_FK"'}' \
      "$ACCESS_TOKEN") || { log_message "Invite probe: $check_date fetch failed (HTTP $(last_http_status))"; continue; }
    local n_classes
    n_classes=$(echo "$check_schedule" | jq -r '.data | length')
    local check_class
    check_class=$(echo "$check_schedule" | jq -r '.data[] | select(.time=="'"$signup_hour"'" and .box_categories.name=="'"$check_class_name"'")')
    if [ -z "$check_class" ] || [ "$check_class" = "null" ]; then
      log_message "Invite probe: $check_date ($day) - no $check_class_name at $signup_hour (classes in day: ${n_classes:-?})"
      continue
    fi
    local booking_option
    booking_option=$(echo "$check_class" | jq -r '.booking_option // empty')
    log_message "Invite probe: $check_date ($day) - found $check_class_name, booking_option=${booking_option:-absent}"
    # cancelScheduleUser = Aviel is already signed up here: this IS the
    # workout to invite the friend to. Prefer it over merely-open classes.
    if [ "$booking_option" = "cancelScheduleUser" ]; then
      log_message "Invite probe: $check_date ($day) - Aviel is signed up here, invite target"
      class_id=$(echo "$check_class" | jq -r '.id')
      class_day="$day"; class_date="$check_date"; class_name="$check_class_name"
      break
    fi
    # Full class — inviting a friend there is pointless (they couldn't
    # book). Skip it and try the next day.
    if [ "$booking_option" = "insertStandby" ] || [ "$booking_option" = "cancelWaitList" ]; then
      log_message "Invite probe: $check_date class is full (booking_option=$booking_option), trying next day"
      continue
    fi
    if [ -n "$booking_option" ] && [ "$booking_option" != "insertScheduleUser" ] && [ "$booking_option" != "registerToSchedule" ]; then
      log_message "Invite probe: $check_date window closed (booking_option=$booking_option), trying next day"
      continue
    fi
    class_id=$(echo "$check_class" | jq -r '.id')
    class_day="$day"; class_date="$check_date"; class_name="$check_class_name"
    break
  done

  if [ -z "$class_id" ] || [ "$class_id" = "null" ]; then
    echo "Invite probe: no upcoming 08:00 class found in the next $DAYS_AHEAD days."
    log_message "Invite probe: no upcoming class found"
    exit 1
  fi

  echo "Invite: sending $friend_name an invite to $class_day $class_date $class_name (schedule_id=$class_id)..."
  local invite_response
  invite_response=$(curl_with_retry POST "$API_BASE/userToUser/schedule/invite" \
    '{"schedule_id":'"$class_id"',"friend_users_id":'"$friend_users_id"'}' \
    "$ACCESS_TOKEN") || true

  local invite_data status_code probe_msg
  invite_data=$(echo "$invite_response" | jq -r '.data // empty' 2>/dev/null || echo "")
  status_code=$(echo "$invite_response" | jq -r '.statusCode // empty' 2>/dev/null || echo "")
  probe_msg=$(echo "$invite_response" | jq -r '.message // .error.message // empty' 2>/dev/null || echo "")
  # Per the app bundle: success iff the response is true or "OK" — the
  # server answers HTTP 200 with a plain-text "OK" body (not JSON), so
  # accept the raw body too. The friend then sees an invitation card and
  # joins by booking the class themselves.
  if [ "$invite_data" = "true" ] || [ "$invite_data" = "OK" ] || [ "$(printf '%s' "$invite_response" | tr -d '[:space:]')" = "OK" ]; then
    echo "Invite: $friend_name invited to $class_day $class_date — they must approve in the Arbox app to join."
    log_message "Invite: $friend_name invited to $class_date (data=$invite_data)"
    send_telegram_message "📨 Invite sent: $friend_name → $class_day $class_date $class_name. They need to approve in the Arbox app."
    return 0
  fi
  echo "Invite: FAILED for $friend_name on $class_day $class_date (HTTP $(last_http_status), statusCode=${status_code:-none}, message: ${probe_msg:-none})."
  log_message "Invite: FAILED for $friend_name on $class_date (HTTP $(last_http_status), statusCode=${status_code:-none}, message: ${probe_msg:-none})"
  send_telegram_message "📨 Invite FAILED: $friend_name → $class_day $class_date (HTTP $(last_http_status))."
  return 1
}

# ── Check invite status ──────────────────────────────────────────────────
# The app UI shows NO indication that an invite was sent: the BookClass
# modal recomputes every friend's invite_status from the class's booked
# users ("booked" or "invite") every time it opens, discarding any stored
# "invited" value — and "invited" only exists in memory right after you
# tap invite in that same session (app bundle, Nov 16 2026). So this mode
# asks the server directly: POST friendConnection/schedule {users_ids:[...]}
# returns the friend connections, which MAY carry the stored invite_status.
# Prints the full raw response so the real shape is visible either way.
# Manual use only, never in the daily run. Sends nothing, invites nobody.
do_check_invite() {
  local query="$1"
  arbox_login
  local profile_json
  profile_json=$(fetch_profile) || {
    log_message "ERROR: Check invite: failed to fetch profile (HTTP $(last_http_status))"
    echo "Failed to fetch profile (HTTP $(last_http_status)). See sign.log."
    exit 1
  }

  local q_lower
  q_lower=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')
  local match_json
  match_json=$(echo "$profile_json" | jq -c --arg q "$q_lower" '
    (.data.friend_connection // []) | map(select(((.friend_user.full_name // "") | ascii_downcase | contains($q))))')

  local match_count
  match_count=$(echo "$match_json" | jq 'length')
  if [ "$match_count" = "0" ]; then
    echo "No friend matching \"$query\" found. Your friends:"
    print_friends "$profile_json"
    log_message "Check invite: no friend matches '$query'"
    exit 1
  fi
  if [ "$match_count" != "1" ]; then
    echo "Multiple friends match \"$query\" — be more specific:"
    echo "$match_json" | jq -r '.[] | (.friend_user.full_name // "unknown")'
    exit 1
  fi

  local friend_name friend_users_id
  friend_name=$(echo "$match_json" | jq -r '.[0].friend_user.full_name // "unknown"')
  friend_users_id=$(echo "$match_json" | jq -r '.[0].friend_users_id')
  echo "Check invite: $friend_name (friend_users_id=$friend_users_id) via POST friendConnection/schedule"
  log_message "Check invite: $friend_name (friend_users_id=$friend_users_id)"

  local check_response
  check_response=$(curl_with_retry POST "$API_BASE/friendConnection/schedule" \
    '{"users_ids":['"$friend_users_id"']}' \
    "$ACCESS_TOKEN") || {
    log_message "Check invite: friendConnection/schedule failed (HTTP $(last_http_status))"
    echo "Request failed (HTTP $(last_http_status)). See sign.log."
    exit 1
  }

  echo "--- raw friendConnection/schedule response ---"
  echo "$check_response" | jq . 2>/dev/null || echo "$check_response"
  log_message "Check invite: raw response: $(printf '%s' "$check_response" | tr '\n' ' ' 2>/dev/null | head -c 1000 || true)"

  local invite_status
  invite_status=$(echo "$check_response" | jq -r --argjson fid "$friend_users_id" '
    ((.data // []) | if type == "array" then map(select(.friend_users_id == $fid or .users_id == $fid)) | .[0].invite_status // empty else .invite_status // empty end)' 2>/dev/null || echo "")
  if [ -n "$invite_status" ]; then
    echo "Check invite: $friend_name invite_status = $invite_status"
    log_message "Check invite: $friend_name invite_status=$invite_status"
  else
    echo "Check invite: no invite_status in the response for $friend_name (see raw response above)."
    log_message "Check invite: no invite_status for $friend_name"
  fi
  return 0
}

# ── Invite all friends to all my classes ─────────────────────────────────
# One invite POST. Returns 0 iff the server accepted it (HTTP 2xx with a
# plain-text "OK" body, or JSON .data true/"OK" — the app's own success
# check). Prints nothing.
send_invite() {
  local sid="$1" fid="$2"
  local resp data
  resp=$(curl_with_retry POST "$API_BASE/userToUser/schedule/invite" \
    '{"schedule_id":'"$sid"',"friend_users_id":'"$fid"'}' \
    "$ACCESS_TOKEN") || return 1
  data=$(echo "$resp" | jq -r '.data // empty' 2>/dev/null || echo "")
  if [ "$data" = "true" ] || [ "$data" = "OK" ] || [ "$(printf '%s' "$resp" | tr -d '[:space:]')" = "OK" ]; then
    return 0
  fi
  return 1
}

# Invite mode (manual --invite-all or daily --invite-fridays): after
# do_signup, invite EVERY friend to every class in SIGNED_UP_CLASSES_JSON —
# or to FRIDAY classes only when INVITE_FRIDAYS is set. Dedupe via
# invites.csv: a friend invited to a class once is never invited to that
# class again. Sets the INVITES_* globals + INVITE_SUMMARY for the report.
invite_friends_to_classes() {
  INVITES_NEW=0; INVITES_SKIPPED=0; INVITES_FAILED=0
  INVITE_SUMMARY=""; INVITE_EXCEPTIONS=""; INVITE_FRIENDS_COUNT=0
  arbox_login
  local profile_json
  profile_json=$(fetch_profile) || {
    log_message "ERROR: Invite-all: failed to fetch profile (HTTP $(last_http_status))"
    echo "Failed to fetch profile (HTTP $(last_http_status)). See sign.log."
    return 1
  }
  local friends_json
  friends_json=$(echo "$profile_json" | jq -c '[.data.friend_connection // [] | .[] | {name: (.friend_user.full_name // "unknown"), id: .friend_users_id}]')
  local n_friends
  n_friends=$(echo "$friends_json" | jq 'length')
  # Friday-only mode (daily run): only Friday classes are invited to.
  local classes_json="$SIGNED_UP_CLASSES_JSON"
  if $INVITE_FRIDAYS; then
    classes_json=$(echo "$SIGNED_UP_CLASSES_JSON" | jq -c '[.[] | select(.day == "Friday")]')
  fi
  local n_classes
  n_classes=$(echo "$classes_json" | jq 'length')
  if [ "$n_classes" = "0" ]; then
    log_message "Invite-all: no signed-up classes in the next $DAYS_AHEAD days, nothing to invite to"
    echo "No signed-up classes found — nothing to invite to."
    return 0
  fi
  if [ "$n_friends" = "0" ]; then
    log_message "Invite-all: no friends on the profile"
    echo "No friends found on your Arbox profile."
    return 0
  fi
  INVITE_FRIENDS_COUNT=$n_friends
  log_message "Invite-all: $n_friends friends x $n_classes classes (fridays_only=$INVITE_FRIDAYS)"
  local i j
  for ((i=0; i<n_classes; i++)); do
    local cls sid cday cdate cname
    cls=$(echo "$classes_json" | jq -c ".[$i]")
    sid=$(echo "$cls" | jq -r '.schedule_id')
    cday=$(echo "$cls" | jq -r '.day')
    cdate=$(echo "$cls" | jq -r '.date')
    cname=$(echo "$cls" | jq -r '.class')
    local class_new=0 class_skipped=0 class_failed=0
    for ((j=0; j<n_friends; j++)); do
      local fr fname fid
      fr=$(echo "$friends_json" | jq -c ".[$j]")
      fname=$(echo "$fr" | jq -r '.name')
      fid=$(echo "$fr" | jq -r '.id')
      if is_invited "$sid" "$fid"; then
        class_skipped=$((class_skipped + 1))
        continue
      fi
      if $DRY_RUN; then
        log_message "[DRY RUN] Invite-all: would invite $fname to $cdate"
        class_new=$((class_new + 1))
        continue
      fi
      if send_invite "$sid" "$fid"; then
        add_to_invites "$sid" "$fid" "$cdate" "$fname" "invited"
        class_new=$((class_new + 1))
        log_message "Invite-all: invited $fname to $cdate (schedule $sid)"
      else
        add_to_invites "$sid" "$fid" "$cdate" "$fname" "failed"
        class_failed=$((class_failed + 1))
        log_message "Invite-all: FAILED to invite $fname to $cdate (HTTP $(last_http_status))"
      fi
      sleep 0.3
    done
    INVITES_NEW=$((INVITES_NEW + class_new))
    INVITES_SKIPPED=$((INVITES_SKIPPED + class_skipped))
    INVITES_FAILED=$((INVITES_FAILED + class_failed))
    INVITE_SUMMARY="${INVITE_SUMMARY}📅 $cday $cdate $cname: $class_new invited, $class_skipped already, $class_failed failed\n"
    # The Telegram caption stays short: per-class lines only for classes
    # where something was skipped or failed (v2.3.1 — the full per-class
    # list made the message too long when every class was identical).
    if [ "$class_skipped" -gt 0 ] || [ "$class_failed" -gt 0 ]; then
      INVITE_EXCEPTIONS="${INVITE_EXCEPTIONS}📅 $cday $cdate $cname: $class_new invited, $class_skipped already, $class_failed failed\n"
    fi
  done
  log_message "Invite-all done: new=$INVITES_NEW already=$INVITES_SKIPPED failed=$INVITES_FAILED"
}

# One combined Telegram report for the invite-all run: the card shows the
# signed-up classes, the caption carries signup + invite counts.
send_invite_all_report() {
  local prefix=""
  $DRY_RUN && prefix="[DRY RUN] "
  local n_classes
  n_classes=$(echo "$SIGNED_UP_CLASSES_JSON" | jq 'length')
  local msg="${prefix}🏋️ Arbox Full Run — $signup_hour"
  msg="$msg"$'\n'"📊 Signup: New $INVITE_ALL_NEW | ✅ Already $INVITE_ALL_ALREADY | ❌ Failed $INVITE_ALL_FAILED"
  msg="$msg"$'\n'"📨 Invites: $INVITES_NEW new | ⏭️ $INVITES_SKIPPED already sent | ❌ $INVITES_FAILED failed"
  if [ "$n_classes" -gt 0 ]; then
    # Compact one-line date list (v2.3.1 — the full per-class list made the
    # caption too long); the photo card shows the classes in full.
    local class_dates
    class_dates=$(echo "$SIGNED_UP_CLASSES_JSON" | jq -r '[.[] | (.date | split("-") | .[0] + "." + .[1])] | join(", ")')
    msg="$msg"$'\n'"📅 Classes: $class_dates"
  fi
  [ -n "$INVITE_EXCEPTIONS" ] && msg="$msg"$'\n\n'"⚠️ Invite exceptions:"$'\n'"$(echo -e "$INVITE_EXCEPTIONS")"
  [ -n "$INVITE_ALL_ERRORS" ] && msg="$msg"$'\n\n'"⚠️ Errors:"$'\n'"$(echo -e "$INVITE_ALL_ERRORS")"
  [ -n "$INVITE_ALL_WORKOUT" ] && msg="$msg"$'\n\n'"$INVITE_ALL_WORKOUT"

  local photo_sent=false
  if [ "$n_classes" -gt 0 ] && ! $DRY_RUN; then
    local card_path="$SCRIPT_DIR/card.png"
    local caption="$msg"
    # Telegram captions cap at 1024 chars — truncate, never fail the send.
    if [ ${#caption} -gt 1000 ]; then caption="${caption:0:997}…"; fi
    if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/arbox_card.py" ] \
       && echo "$SIGNED_UP_CLASSES_JSON" | python3 "$SCRIPT_DIR/arbox_card.py" --out "$card_path" --run-date "$(date '+%d.%m.%Y %H:%M')" --count-text "$n_classes שיעורים" --invites-line "הוזמנו $INVITE_FRIENDS_COUNT חברים · $INVITES_NEW הזמנות חדשות" 2>/dev/null; then
      if send_telegram_photo "$card_path" "$caption"; then
        photo_sent=true
        log_message "Invite-all card photo sent"
      else
        log_message "WARNING: sendPhoto failed, falling back to text"
      fi
    else
      log_message "WARNING: Card render failed, falling back to text"
    fi
  fi
  if ! $photo_sent; then
    send_telegram_message "$msg"
    log_message "Invite-all text notification sent"
  fi
}

# Daily-run Friday note: one short Telegram text line, sent ONLY when the
# Friday invite phase actually sent new invites (INVITES_NEW > 0). On days
# with nothing new (dedupe: already invited) nothing extra is sent — the
# normal daily signup report from do_signup is the only message.
send_friday_invite_note() {
  local friday_dates
  friday_dates=$(echo "$SIGNED_UP_CLASSES_JSON" | jq -r '[.[] | select(.day == "Friday") | (.date | split("-") | .[0] + "." + .[1])] | join(", ")')
  local msg="📨 הזמנתי את החברים לשישי ($friday_dates): $INVITES_NEW הזמנות חדשות"
  [ "$INVITES_FAILED" -gt 0 ] && msg="$msg (❌ $INVITES_FAILED נכשלו)"
  send_telegram_message "$msg"
  log_message "Friday invite note sent: new=$INVITES_NEW failed=$INVITES_FAILED"
}

# ── Main signup logic ─────────────────────────────────────────────────────
do_signup() {
  arbox_login
  ensure_membership

  local signup_summary="" errors=""
  local new_signups=0 skipped=0 already=0 failed=0
  local new_signups_json="[]"  # JSON array for the Telegram card
  SIGNED_UP_CLASSES_JSON="[]"  # reset: classes Aviel is signed up for
  log_message "Processing next $DAYS_AHEAD days at $signup_hour (dry_run=$DRY_RUN)"

  for days_ahead in $(seq 1 "$DAYS_AHEAD"); do
    local check_date day check_class_name
    check_date=$(format_date "$days_ahead" "%d-%m-%Y")
    day=$(format_date "$days_ahead" "%A")
    check_class_name=$(get_class_name "$day")

    if should_skip_day "$day"; then
      log_message "Day $days_ahead: $check_date ($day) - Skipped"
      skipped=$((skipped + 1))
      continue
    fi

    if is_in_csv "$check_date" "$signup_hour"; then
      log_message "Day $days_ahead: $check_date - In CSV"
      skipped=$((skipped + 1))
      continue
    fi

    local check_schedule
    check_schedule=$(curl_with_retry POST "$API_BASE/schedule/betweenDates" \
      '{"from":"'"$check_date"'","to":"'"$check_date"'","locations_box_id":'"$LOCATION_BOX_FK"',"boxes_id":'"$BOX_FK"'}' \
      "$ACCESS_TOKEN") || {
      errors="${errors}❌ $day $check_date: schedule fetch failed (HTTP $(last_http_status))\n"
      failed=$((failed + 1))
      continue
    }

    local check_class
    check_class=$(echo "$check_schedule" | jq -r '.data[] | select(.time=="'"$signup_hour"'" and .box_categories.name=="'"$check_class_name"'")')

    if [ -z "$check_class" ] || [ "$check_class" = "null" ]; then
      log_message "Day $days_ahead: $check_date - No class found"
      continue
    fi

    local registered max_users capacity_info=""
    registered=$(echo "$check_class" | jq -r '.registeredUsers // 0')
    max_users=$(echo "$check_class" | jq -r '.maxUsers // 0')
    [ "$max_users" != "0" ] && [ "$max_users" != "null" ] && capacity_info=" ($registered/$max_users)"
    local loop_class_id
    loop_class_id=$(echo "$check_class" | jq -r '.id')

    local is_signed_up
    is_signed_up=$(echo "$check_class" | jq -r '.isSignedUp')
    if [ "$is_signed_up" = "true" ]; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
      note_signed_up_class "$loop_class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
      already=$((already + 1))
      log_message "Day $days_ahead: $check_date - Already signed up"
      continue
    fi

    # Booking window (live run #228 + the app's own SPA bundle, Nov 16 2026):
    # booking_option is the action available for THIS user, and only these
    # four values exist in the bundle — 'registerToSchedule' appears 0 times
    # (arbox-bot's claim is stale; kept below defensively):
    #   cancelScheduleUser = already signed up
    #   insertScheduleUser = open, book directly
    #   insertStandby      = full, go straight to the waitlist endpoint
    #   cancelWaitList     = already on the waitlist
    # Anything else = window not open — skip without counting as failed.
    local booking_option
    booking_option=$(echo "$check_class" | jq -r '.booking_option // empty')
    if [ "$booking_option" = "cancelScheduleUser" ]; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
      note_signed_up_class "$loop_class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
      already=$((already + 1))
      log_message "Day $days_ahead: $check_date - Already signed up (booking_option=cancelScheduleUser)"
      continue
    fi
    if [ "$booking_option" = "cancelWaitList" ]; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "waitlist"
      log_message "Day $days_ahead: $check_date - Already on the waitlist (booking_option=cancelWaitList)"
      continue
    fi
    if [ "$booking_option" = "insertStandby" ]; then
      local standby_class_id
      standby_class_id=$(echo "$check_class" | jq -r '.id')
      log_message "Day $days_ahead: $check_date - Full (booking_option=insertStandby), trying waitlist"
      if try_standby "$standby_class_id" "$day" "$check_date" "$check_class_name"; then
        :
      else
        errors="${errors}❌ $day $check_date: full + waitlist failed (HTTP $(last_http_status))\n"
        failed=$((failed + 1))
        log_message "Day $days_ahead: $check_date - Full, waitlist failed"
      fi
      continue
    fi
    if [ -n "$booking_option" ] && [ "$booking_option" != "insertScheduleUser" ] && [ "$booking_option" != "registerToSchedule" ]; then
      log_message "Day $days_ahead: $check_date - Window closed (booking_option=$booking_option), skipping"
      continue
    fi

    if $DRY_RUN; then
      signup_summary="${signup_summary}🔍 $day $check_date $check_class_name${capacity_info}\n"
      new_signups=$((new_signups + 1))
      new_signups_json=$(echo "$new_signups_json" | jq -c --arg day "$day" --arg date "$check_date" --arg cls "$check_class_name" --arg time "$signup_hour" '. + [{day:$day, date:$date, class:$cls, time:$time}]')
      note_signed_up_class "$loop_class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
      log_message "[DRY RUN] $check_date - Would sign up"
      continue
    fi

    local class_id signup_response status_code
    class_id=$(echo "$check_class" | jq -r '.id')
    signup_response=$(curl_with_retry POST "$API_BASE/scheduleUser/insert" \
      '{"schedule_id":'"$class_id"',"membership_user_id":'"$MEMBERSHIP_USER_ID"'}' \
      "$ACCESS_TOKEN") || {
      # Insert failed at the HTTP level (no JSON at all) — this used to be a
      # dead end. The standby endpoint books if a spot is free, otherwise
      # waitlists, so try it before giving up on the day.
      log_message "Day $days_ahead: $check_date - Insert failed (HTTP $(last_http_status)), trying standby endpoint"
      if try_standby "$class_id" "$day" "$check_date" "$check_class_name"; then
        continue
      fi
      errors="${errors}❌ $day $check_date: signup request failed (HTTP $(last_http_status))\n"
      failed=$((failed + 1))
      continue
    }

    status_code=$(echo "$signup_response" | jq -r '.statusCode // empty')

    if [ "$status_code" = "514" ]; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
      note_signed_up_class "$class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
      already=$((already + 1))
      log_message "Day $days_ahead: $check_date - Already signed (514)"
    elif echo "$signup_response" | jq -e '.data' >/dev/null 2>&1; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "signed_up"
      note_signed_up_class "$class_id" "$day" "$check_date" "$check_class_name" "$signup_hour"
      signup_summary="${signup_summary}✅ $day $check_date $check_class_name${capacity_info}\n"
      new_signups=$((new_signups + 1))
      new_signups_json=$(echo "$new_signups_json" | jq -c --arg day "$day" --arg date "$check_date" --arg cls "$check_class_name" --arg time "$signup_hour" '. + [{day:$day, date:$date, class:$cls, time:$time}]')
      log_message "Day $days_ahead: $check_date - Signed up!"
    else
      local error_msg
      error_msg=$(echo "$signup_response" | jq -r '.message // .error.message // "Unknown error"')

      if echo "$error_msg" | grep -qi "full\|capacity"; then
        log_message "Day $days_ahead: $check_date - Full, trying waitlist"
        if try_standby "$class_id" "$day" "$check_date" "$check_class_name"; then
          :
        else
          errors="${errors}❌ $day $check_date: full + waitlist failed (HTTP $(last_http_status))\n"
          failed=$((failed + 1))
          log_message "Day $days_ahead: $check_date - Full, waitlist failed"
        fi
      else
        errors="${errors}❌ $day $check_date: $error_msg (HTTP $(last_http_status))\n"
        failed=$((failed + 1))
        log_message "Day $days_ahead: $check_date - Failed: $error_msg (HTTP $(last_http_status))"
      fi
    fi

    sleep 0.5
  done

  log_message "Done: new=$new_signups already=$already skipped=$skipped failed=$failed"

  # Get workout
  local crossfit_workout=""
  local user_feed
  user_feed=$(curl_with_retry GET "$API_BASE/user/feed" "" "$ACCESS_TOKEN") || true

  if [ -n "$user_feed" ]; then
    for ci in 0 1; do
      local cat_data
      cat_data=$(echo "$user_feed" | jq -r ".todayWorkout[$ci] // empty")
      if [ -n "$cat_data" ] && [ "$cat_data" != "null" ]; then
        local cat_name
        cat_name=$(echo "$cat_data" | jq -r '.[0][0].box_categories.name // empty')
        if [ "$cat_name" = "CrossFit" ]; then
          crossfit_workout="💪 Today's Workout:"$'\n'
          local sc
          sc=$(echo "$cat_data" | jq 'length')
          for ((i=0; i<sc; i++)); do
            local sn scm
            sn=$(echo "$cat_data" | jq -r ".[$i][0].box_sections.name // empty")
            scm=$(echo "$cat_data" | jq -r ".[$i][0].comment // empty")
            if [ -n "$scm" ] && [ "$scm" != "null" ]; then
              crossfit_workout="$crossfit_workout"$'\n'"🔹 $sn:"$'\n'"$scm"$'\n'
            fi
          done
        fi
      fi
    done
  fi

  # Notification
  # Invite-all mode: the combined report (signup + invites) is sent by the
  # caller, so export the summary and skip this notification.
  if $INVITE_ALL; then
    INVITE_ALL_NEW=$new_signups
    INVITE_ALL_ALREADY=$already
    INVITE_ALL_SKIPPED=$skipped
    INVITE_ALL_FAILED=$failed
    INVITE_ALL_ERRORS="$errors"
    INVITE_ALL_WORKOUT="$crossfit_workout"
    log_message "Invite-all mode: signup done (new=$new_signups already=$already failed=$failed), report deferred"
    return 0
  fi

  local prefix=""
  $DRY_RUN && prefix="[DRY RUN] "

  if [ $new_signups -gt 0 ] || [ -n "$errors" ]; then
    local msg="${prefix}🏋️ Arbox Signup Report — $signup_hour"
    msg="$msg"$'\n'"📊 New: $new_signups | ✅ Already: $already | ⏭️ Skipped: $skipped | ❌ Failed: $failed"

    [ $new_signups -gt 0 ] && msg="$msg"$'\n\n'"✨ New Signups:"$'\n'"$(echo -e "$signup_summary")"
    [ -n "$errors" ] && msg="$msg"$'\n\n'"⚠️ Errors:"$'\n'"$(echo -e "$errors")"
    [ -n "$crossfit_workout" ] && msg="$msg"$'\n\n'"$crossfit_workout"

    # Telegram photo card (v2.2.0): when there are new signups, render the
    # card and send it as a photo with the text report as caption. Any
    # failure falls back to the plain text message below.
    local photo_sent=false
    if [ $new_signups -gt 0 ] && ! $DRY_RUN; then
      local card_path="$SCRIPT_DIR/card.png"
      local caption="$msg"
      # Telegram captions cap at 1024 chars — truncate, never fail the send.
      if [ ${#caption} -gt 1000 ]; then caption="${caption:0:997}…"; fi
      if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/arbox_card.py" ] \
         && echo "$new_signups_json" | python3 "$SCRIPT_DIR/arbox_card.py" --out "$card_path" --run-date "$(date '+%d.%m.%Y %H:%M')" 2>/dev/null; then
        if send_telegram_photo "$card_path" "$caption"; then
          photo_sent=true
          log_message "Card photo sent"
        else
          log_message "WARNING: sendPhoto failed, falling back to text"
        fi
      else
        log_message "WARNING: Card render failed, falling back to text"
      fi
    fi
    if ! $photo_sent; then
      send_telegram_message "$msg"
      log_message "Notification sent"
    fi
  else
    if [ -n "$crossfit_workout" ]; then
      send_telegram_message "${prefix}${crossfit_workout}"
      log_message "Sent workout only"
    else
      log_message "Nothing to report"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  check_dependencies
  parse_args "$@"
  load_env

  if $CLEANUP_ONLY; then
    cleanup_csv
    exit 0
  fi

  if [ -z "$email" ] || [ -z "$password" ] || [ -z "$signup_hour" ]; then
    echo "Error: Email, password, and hour are required."
    echo "Provide via CLI args or .env file. Run --help for details."
    exit 1
  fi

  validate_hour "$signup_hour"

  # Load cached membership data (BOX_ID, location, user) BEFORE the manual
  # modes: do_invite_friend calls ensure_membership, which reads
  # CACHED_LOCATION_BOX_FK under `set -u` — v2.2.3 initialised these only
  # on the signup path, so --invite-friend crashed with "unbound variable"
  # (run #226) before reaching the server.
  CACHED_LOCATION_BOX_FK=""
  CACHED_MEMBERSHIP_USER_ID=""
  load_cache || true

  # Manual modes (never part of the scheduled run): no lock, no CSV.
  if $LIST_FRIENDS; then
    do_list_friends
    exit 0
  fi

  if [ -n "$INVITE_FRIEND" ]; then
    do_invite_friend "$INVITE_FRIEND"
    exit $?
  fi

  if [ -n "$CHECK_INVITE" ]; then
    do_check_invite "$CHECK_INVITE"
    exit $?
  fi

  rotate_log

  if [ -f "$CSV_FILE" ]; then
    local csv_lines
    csv_lines=$(wc -l < "$CSV_FILE" | tr -d ' ')
    [ "$csv_lines" -gt 500 ] && cleanup_csv
  fi

  init_csv
  acquire_lock
  log_message "=== arbox-signup.sh v$VERSION started ==="
  do_signup
  if $INVITE_ALL; then
    invite_friends_to_classes
    send_invite_all_report
  elif $INVITE_FRIDAYS; then
    invite_friends_to_classes
    # Short note only when new Friday invites actually went out.
    if [ "$INVITES_NEW" -gt 0 ]; then
      send_friday_invite_note
    fi
  fi
  log_message "=== arbox-signup.sh v$VERSION finished ==="
}

main "$@"

