#!/bin/bash
set -euo pipefail

#=============================================================================
# theboxnov.sh v2.0.0 — Arbox Auto-Signup Script (Improved)
#
# Automatically signs up for CrossFit classes via Arbox API, up to N days
# in advance. Sends notifications via Telegram.
#
# Usage:
#   ./theboxnov.sh                    # Uses .env file for config
#   ./theboxnov.sh -e EMAIL -p PASS -h 08:00
#   ./theboxnov.sh --dry-run          # Preview without signing up
#   ./theboxnov.sh --cleanup          # Remove old CSV entries (>30 days)
#
# Config priority: CLI args > .env file > defaults
#=============================================================================

readonly VERSION="2.0.0"
readonly LOCK_TIMEOUT=300
readonly MAX_LOG_SIZE=$((5 * 1024 * 1024))
readonly CSV_RETENTION_DAYS=30
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly API_BASE="https://apiappv2.arboxapp.com/api/v2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="$SCRIPT_DIR/signups.csv"
LOG_FILE="$SCRIPT_DIR/sign.log"
LOCK_FILE="$SCRIPT_DIR/.theboxnov.lock"
ENV_FILE="$SCRIPT_DIR/.env"

DRY_RUN=false
CLEANUP_ONLY=false
email=""
password=""
signup_hour=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
BOX_ID=70
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
        send_telegram_message "Warning: Arbox script blocked by PID $lock_pid"
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

# ── HTTP with retry ──────────────────────────────────────────────────────
curl_with_retry() {
  local method="$1" url="$2" data="${3:-}" token="${4:-}"
  local attempt=0

  while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    local curl_args=(-s --max-time 30 --connect-timeout 10 -H 'Content-Type: application/json')
    [ -n "$token" ] && curl_args+=(-H "accesstoken: $token")
    if [ "$method" = "POST" ]; then
      curl_args+=(-X POST)
      [ -n "$data" ] && curl_args+=(--data-raw "$data")
    fi

    local raw_response
    raw_response=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || true

    if [ -n "$raw_response" ] && echo "$raw_response" | jq empty 2>/dev/null; then
      echo "$raw_response"
      return 0
    fi

    if [ $attempt -lt $MAX_RETRIES ]; then
      local wait=$((RETRY_DELAY * attempt))
      log_message "API retry $attempt/$MAX_RETRIES for $url (${wait}s)"
      sleep "$wait"
    fi
  done

  log_message "ERROR: API failed after $MAX_RETRIES attempts: $method $url"
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
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$1" \
    --max-time 10 >/dev/null 2>&1 || log_message "WARNING: Telegram send failed"
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
      --version) echo "theboxnov.sh v$VERSION"; exit 0 ;;
      --help)    show_help; exit 0 ;;
      *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done
}

show_help() {
  cat <<EOF
theboxnov.sh v$VERSION - Arbox Auto-Signup

Usage: $0 [options]

Options:
  -e EMAIL       Arbox account email
  -p PASSWORD    Arbox account password
  -h HOUR        Class time HH:MM (e.g., 08:00)
  --dry-run      Preview without signing up
  --cleanup      Remove old CSV entries and exit
  --version      Show version
  --help         Show this help

Config: Create .env file (see .env.example) to avoid CLI credentials.
        CLI args override .env values.
EOF
}

# ── Main signup logic ─────────────────────────────────────────────────────
do_signup() {
  log_message "Logging in as $email"
  local login_response
  login_response=$(curl_with_retry POST "$API_BASE/user/login" \
    "{\"email\":\"$email\",\"password\":\"$password\"}") || {
    log_message "ERROR: Login request failed"
    send_telegram_message "Login request failed (network error)"
    exit 1
  }

  local access_token
  access_token=$(echo "$login_response" | jq -r '.data.token // empty')
  if [ -z "$access_token" ]; then
    local err
    err=$(echo "$login_response" | jq -r '.message // "Unknown error"')
    log_message "ERROR: Login failed: $err"
    send_telegram_message "Login failed: $err"
    exit 1
  fi
  log_message "Login successful"

  local membership_response
  membership_response=$(curl_with_retry GET "$API_BASE/boxes/$BOX_ID/memberships/1" "" "$access_token") || {
    log_message "ERROR: Membership request failed"
    send_telegram_message "Failed to fetch membership details"
    exit 1
  }

  local location_box_fk box_fk membership_user_id
  location_box_fk=$(echo "$membership_response" | jq -r '.data[0].membership_types.location_box_fk')
  box_fk=$(echo "$membership_response" | jq -r '.data[0].box_fk')
  membership_user_id=$(echo "$membership_response" | jq -r '.data[0].id')

  if [ -z "$location_box_fk" ] || [ "$location_box_fk" = "null" ] || \
     [ -z "$box_fk" ] || [ "$box_fk" = "null" ] || \
     [ -z "$membership_user_id" ] || [ "$membership_user_id" = "null" ]; then
    log_message "ERROR: Failed to retrieve membership details"
    send_telegram_message "Failed to retrieve membership details"
    exit 1
  fi
  log_message "Membership: box=$box_fk location=$location_box_fk user=$membership_user_id"

  local signup_summary="" errors=""
  local new_signups=0 skipped=0 already=0 failed=0
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
      '{"from":"'"$check_date"'","to":"'"$check_date"'","locations_box_id":'"$location_box_fk"',"boxes_id":'"$box_fk"'}' \
      "$access_token") || {
      errors="${errors}$day $check_date: schedule fetch failed\n"
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

    if $DRY_RUN; then
      signup_summary="${signup_summary}[DRY] $day $check_date $check_class_name${capacity_info}\n"
      new_signups=$((new_signups + 1))
      log_message "[DRY RUN] $check_date - Would sign up"
      continue
    fi

    local class_id signup_response status_code
    class_id=$(echo "$check_class" | jq -r '.id')
    signup_response=$(curl_with_retry POST "$API_BASE/scheduleUser/insert" \
      '{"schedule_id":'"$class_id"',"membership_user_id":'"$membership_user_id"'}' \
      "$access_token") || {
      errors="${errors}$day $check_date: signup request failed\n"
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
      signup_summary="${signup_summary}$day $check_date $check_class_name${capacity_info}\n"
      new_signups=$((new_signups + 1))
      log_message "Day $days_ahead: $check_date - Signed up!"
    else
      local error_msg
      error_msg=$(echo "$signup_response" | jq -r '.message // "Unknown error"')

      if echo "$error_msg" | grep -qi "full\|capacity"; then
        log_message "Day $days_ahead: $check_date - Full, trying waitlist"
        local wl_response
        wl_response=$(curl_with_retry POST "$API_BASE/scheduleUser/insertStandby" \
          '{"schedule_id":'"$class_id"',"membership_user_id":'"$membership_user_id"'}' \
          "$access_token") || true

        if [ -n "$wl_response" ] && echo "$wl_response" | jq -e '.data' >/dev/null 2>&1; then
          add_to_csv "$check_date" "$signup_hour" "$check_class_name" "waitlist"
          signup_summary="${signup_summary}[WL] $day $check_date${capacity_info}\n"
          log_message "Day $days_ahead: $check_date - Waitlisted"
        else
          errors="${errors}$day $check_date: full + waitlist failed\n"
          failed=$((failed + 1))
          log_message "Day $days_ahead: $check_date - Full, waitlist failed"
        fi
      else
        errors="${errors}$day $check_date: $error_msg\n"
        failed=$((failed + 1))
        log_message "Day $days_ahead: $check_date - Failed: $error_msg"
      fi
    fi

    sleep 0.5
  done

  log_message "Done: new=$new_signups already=$already skipped=$skipped failed=$failed"

  # Get workout
  local crossfit_workout=""
  local user_feed
  user_feed=$(curl_with_retry GET "$API_BASE/user/feed" "" "$access_token") || true

  if [ -n "$user_feed" ]; then
    for ci in 0 1; do
      local cat_data
      cat_data=$(echo "$user_feed" | jq -r ".todayWorkout[$ci] // empty")
      if [ -n "$cat_data" ] && [ "$cat_data" != "null" ]; then
        local cat_name
        cat_name=$(echo "$cat_data" | jq -r '.[0][0].box_categories.name // empty')
        if [ "$cat_name" = "CrossFit" ]; then
          crossfit_workout="Workout:"$'\n'
          local sc
          sc=$(echo "$cat_data" | jq 'length')
          for ((i=0; i<sc; i++)); do
            local sn scm
            sn=$(echo "$cat_data" | jq -r ".[$i][0].box_sections.name // empty")
            scm=$(echo "$cat_data" | jq -r ".[$i][0].comment // empty")
            if [ -n "$scm" ] && [ "$scm" != "null" ]; then
              crossfit_workout="$crossfit_workout"$'\n'"$sn:"$'\n'"$scm"$'\n'
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
    local msg="${prefix}Signup Report for $signup_hour"
    msg="$msg"$'\n'"New: $new_signups | Already: $already | Skipped: $skipped | Failed: $failed"

    [ $new_signups -gt 0 ] && msg="$msg"$'\n\n'"New Signups:"$'\n'"$(echo -e "$signup_summary")"
    [ -n "$errors" ] && msg="$msg"$'\n\n'"Errors:"$'\n'"$(echo -e "$errors")"
    [ -n "$crossfit_workout" ] && msg="$msg"$'\n\n'"$crossfit_workout"

    send_telegram_message "$msg"
    log_message "Notification sent"
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
  rotate_log

  if [ -f "$CSV_FILE" ]; then
    local csv_lines
    csv_lines=$(wc -l < "$CSV_FILE" | tr -d ' ')
    [ "$csv_lines" -gt 500 ] && cleanup_csv
  fi

  init_csv
  acquire_lock
  log_message "=== theboxnov.sh v$VERSION started ==="
  do_signup
  log_message "=== theboxnov.sh v$VERSION finished ==="
}

main "$@"

