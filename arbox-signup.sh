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
#   ./arbox-signup.sh --invite-friend "NAME"  # Invite probe (UNVERIFIED endpoint)
#
# Config priority: CLI args > .env file > defaults
#=============================================================================

readonly VERSION="2.2.2"
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
    body_snippet=$(printf '%s' "$raw_response" | tr '\n' ' ' | head -c 300)

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
                 the next upcoming class. UNVERIFIED endpoint probe — see
                 do_invite_friend. Manual use only, never in the daily run.
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
  # Null-tolerant (v2.2.1): some connections come back with .user == null
  # (deleted/deactivated account) or a null full_name — either used to kill
  # the whole listing with `jq: null has no keys`. Name falls back to
  # first+last, then to "unknown"; boxes fall back to an empty list.
  echo "$1" | jq -r '
    def display_name:
      ((.user.full_name // (((.user.first_name // "") + " " + (.user.last_name // "")) | sub("^ +$"; "") | sub("^ +"; "") | sub(" +$"; ""))) // "unknown")
      | if . == "" then "unknown" else . end;
    def boxes:
      ((.user.users_boxes_active // []) | if type == "array" then . else to_entries | map(.value) end);
    (.data.friend_connection // [])[] |
    "• \(display_name) | friend_users_id=\(.friend_users_id) | status=\(.status) | connection_id=\(.id)",
    "  boxes: \([boxes[] | "id=\(.id) box_fk=\(.box_fk) user_fk=\(.user_fk)"] | join(", "))"'
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
  # Debug (v2.2.2): the live API returns .user == null for every friend, so
  # no names print. Dump the real keys of the first entry so the mapping
  # can be fixed to whatever the API actually returns. Remove once mapped.
  echo "DEBUG first entry keys: $(echo "$profile_json" | jq -c '.data.friend_connection[0] | keys')"
  echo "DEBUG first entry: $(echo "$profile_json" | jq -c '.data.friend_connection[0]')"
  if [ "$count" = "0" ]; then
    echo "No friends found on your Arbox profile."
  else
    print_friends "$profile_json"
  fi
  log_message "Listed $count friends"
}

# ── Invite a friend (UNVERIFIED PROBE) ───────────────────────────────────
# There is NO public friend-invite endpoint. This mode tries one hypothesis:
# POST /api/v2/scheduleUser/insert with the FRIEND's membership_user_id
# (taken from their users_boxes_active entry for our box). The server very
# likely rejects this (the membership must belong to the token owner), so
# expect a failure — and treat any "success" with suspicion until the
# booking is confirmed in the Arbox app. Manual use only, never scheduled.
# Only the NEXT upcoming 08:00 class is attempted, never the whole 12 days.
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
    (.data.friend_connection // []) | map(select(((.user.full_name // "") | ascii_downcase | contains($q))))')

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
    echo "$match_json" | jq -r '.[] | (.user.full_name // "unknown")'
    exit 1
  fi

  local friend_name friend_users_id friend_membership_id
  friend_name=$(echo "$match_json" | jq -r '.[0].user.full_name // "unknown"')
  friend_users_id=$(echo "$match_json" | jq -r '.[0].friend_users_id')
  # Prefer the membership row for OUR box (same business); fall back to the
  # first users_boxes_active entry. The id used is UsersBoxActive.id.
  friend_membership_id=$(echo "$match_json" | jq -r --argjson box "$BOX_FK" '
    ((.[0].user.users_boxes_active // []) | if type == "array" then . else to_entries | map(.value) end) as $boxes
    | (($boxes | map(select(.box_fk == $box)) | .[0]) // $boxes[0]) | .id // empty')

  if [ -z "$friend_membership_id" ] || [ "$friend_membership_id" = "null" ]; then
    echo "Found $friend_name but no usable membership id (users_boxes_active is empty)."
    log_message "Invite probe: $friend_name has no membership id"
    exit 1
  fi
  echo "Invite probe (UNVERIFIED endpoint): $friend_name (friend_users_id=$friend_users_id) via membership_user_id=$friend_membership_id"
  log_message "Invite probe: $friend_name (friend_users_id=$friend_users_id, membership_user_id=$friend_membership_id)"

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
      "$ACCESS_TOKEN") || continue
    local check_class
    check_class=$(echo "$check_schedule" | jq -r '.data[] | select(.time=="'"$signup_hour"'" and .box_categories.name=="'"$check_class_name"'")')
    [ -z "$check_class" ] || [ "$check_class" = "null" ] && continue
    local booking_option
    booking_option=$(echo "$check_class" | jq -r '.booking_option // empty')
    if [ -n "$booking_option" ] && [ "$booking_option" != "registerToSchedule" ]; then
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

  echo "Invite probe: attempting $class_day $class_date $class_name (schedule_id=$class_id) for $friend_name..."
  local invite_response
  invite_response=$(curl_with_retry POST "$API_BASE/scheduleUser/insert" \
    '{"schedule_id":'"$class_id"',"membership_user_id":'"$friend_membership_id"'}' \
    "$ACCESS_TOKEN") || true

  local status_code probe_msg
  status_code=$(echo "$invite_response" | jq -r '.statusCode // empty' 2>/dev/null || echo "")
  probe_msg=$(echo "$invite_response" | jq -r '.message // .error.message // empty' 2>/dev/null || echo "")
  if [ -n "$invite_response" ] && echo "$invite_response" | jq -e '.data' >/dev/null 2>&1; then
    echo "Invite probe: Arbox returned .data for $friend_name on $class_day $class_date — VERIFY IN THE APP that the friend is actually booked (this endpoint use is unverified)."
    log_message "Invite probe: .data returned for $friend_name on $class_date (UNVERIFIED — verify in app)"
    send_telegram_message "🧪 Invite probe (UNVERIFIED endpoint): $friend_name → $class_day $class_date $class_name — Arbox returned .data. Verify in the Arbox app that the friend is actually booked."
    return 0
  fi
  if [ "$status_code" = "514" ]; then
    echo "Invite probe: $friend_name is already signed up for $class_day $class_date (status 514)."
    log_message "Invite probe: $friend_name already signed up (514) for $class_date"
    send_telegram_message "🧪 Invite probe (UNVERIFIED endpoint): $friend_name already signed up for $class_day $class_date (514)."
    return 0
  fi
  echo "Invite probe: FAILED for $friend_name on $class_day $class_date (HTTP $(last_http_status), message: ${probe_msg:-none})."
  log_message "Invite probe: FAILED for $friend_name on $class_date (HTTP $(last_http_status), message: ${probe_msg:-none})"
  send_telegram_message "🧪 Invite probe (UNVERIFIED endpoint): FAILED for $friend_name on $class_day $class_date (HTTP $(last_http_status))."
  return 1
}

# ── Main signup logic ─────────────────────────────────────────────────────
do_signup() {
  arbox_login
  ensure_membership

  local signup_summary="" errors=""
  local new_signups=0 skipped=0 already=0 failed=0
  local new_signups_json="[]"  # JSON array for the Telegram card
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

    local is_signed_up
    is_signed_up=$(echo "$check_class" | jq -r '.isSignedUp')
    if [ "$is_signed_up" = "true" ]; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
      already=$((already + 1))
      log_message "Day $days_ahead: $check_date - Already signed up"
      continue
    fi

    # Booking window (v2.2.0): Arbox marks each class with booking_option;
    # 'registerToSchedule' means the window is open right now. Anything else
    # means it is not open yet (or already closed) — skip WITHOUT counting
    # it as failed. If the field is absent, proceed as before.
    local booking_option
    booking_option=$(echo "$check_class" | jq -r '.booking_option // empty')
    if [ -n "$booking_option" ] && [ "$booking_option" != "registerToSchedule" ]; then
      log_message "Day $days_ahead: $check_date - Window closed (booking_option=$booking_option), skipping"
      continue
    fi

    if $DRY_RUN; then
      signup_summary="${signup_summary}🔍 $day $check_date $check_class_name${capacity_info}\n"
      new_signups=$((new_signups + 1))
      new_signups_json=$(echo "$new_signups_json" | jq -c --arg day "$day" --arg date "$check_date" --arg cls "$check_class_name" --arg time "$signup_hour" '. + [{day:$day, date:$date, class:$cls, time:$time}]')
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
      already=$((already + 1))
      log_message "Day $days_ahead: $check_date - Already signed (514)"
    elif echo "$signup_response" | jq -e '.data' >/dev/null 2>&1; then
      add_to_csv "$check_date" "$signup_hour" "$check_class_name" "signed_up"
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

  # Manual modes (never part of the scheduled run): no lock, no CSV.
  if $LIST_FRIENDS; then
    do_list_friends
    exit 0
  fi

  if [ -n "$INVITE_FRIEND" ]; then
    do_invite_friend "$INVITE_FRIEND"
    exit $?
  fi

  # Load cached membership data (BOX_ID, location, user)
  CACHED_LOCATION_BOX_FK=""
  CACHED_MEMBERSHIP_USER_ID=""
  load_cache || true

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
  log_message "=== arbox-signup.sh v$VERSION finished ==="
}

main "$@"

