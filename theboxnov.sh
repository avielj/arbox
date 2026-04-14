#!/bin/bash

# Check if email, password, and hour arguments are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Error: Email, password, and hour arguments are required."
  echo "Usage: $0 -e <email> -p <password> -h <hour>"
  exit 1
fi

# Parse command-line arguments
while getopts ":e:p:h:" opt; do
  case $opt in
    e) email="$OPTARG" ;;
    p) password="$OPTARG" ;;
    h) signup_hour="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Validate signup_hour format (e.g., HH:MM)
if ! [[ "$signup_hour" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
  echo "Error: Invalid hour format. Use HH:MM (e.g., 08:00)."
  exit 1
fi

# Get script directory for file paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="$SCRIPT_DIR/signups.csv"
LOG_FILE="$SCRIPT_DIR/sign.log"

# Initialize CSV file if it doesn't exist
if [ ! -f "$CSV_FILE" ]; then
  echo "date,time,class_name,status,timestamp" > "$CSV_FILE"
fi

# Function to send a message to the Telegram bot
send_telegram_message() {
  local message=$1
  curl -s -X POST "https://api.telegram.org/bot6002653819:AAFEvFKl_egoi925K5FLMoHGn_SDfplnvPU/sendMessage" \
    -d chat_id="439481965" \
    -d text="$message"
}

# Function to log messages
log_message() {
  local message=$1
  echo "$(date): $message" >> "$LOG_FILE"
}

# Function to check if already signed up in CSV
is_in_csv() {
  local check_date=$1
  local check_time=$2
  grep -q "^$check_date,$check_time," "$CSV_FILE"
  return $?
}

# Function to add signup to CSV
add_to_csv() {
  local signup_date=$1
  local signup_time=$2
  local class=$3
  local status=$4
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$signup_date,$signup_time,$class,$status,$timestamp" >> "$CSV_FILE"
}

# Function to format date (cross-platform compatible)
format_date() {
  local days_offset=$1
  local format=$2
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    date -v+${days_offset}d +"$format"
  else
    # Linux
    date -d "+$days_offset days" +"$format"
  fi
}

# Login request (retrieve access token only)
login_response=$(curl 'https://apiappv2.arboxapp.com/api/v2/user/login' \
  -s -X POST \
  -H 'Content-Type: application/json' \
  --data-raw "{\"email\":\"$email\",\"password\":\"$password\"}")

# Extract access token using jq (cross-platform compatible)
access_token=$(echo "$login_response" | jq -r '.data.token // empty')

# Check if access token was retrieved
if [ -z "$access_token" ]; then
  log_message "Error: Failed to retrieve access token. Response: $login_response"
  send_telegram_message "Error: Failed to retrieve access token."
  exit 1
fi

# Fetch membership details (using only access token)
membership_response=$(curl 'https://apiappv2.arboxapp.com/api/v2/boxes/70/memberships/1' \
  -s -H "accesstoken: $access_token")

location_box_fk=$(echo "$membership_response" | jq -r '.data[0].membership_types.location_box_fk')
box_fk=$(echo "$membership_response" | jq -r '.data[0].box_fk')
membership_user_id=$(echo "$membership_response" | jq -r '.data[0].id')

# Check if membership details were retrieved
if [ -z "$location_box_fk" ] || [ -z "$box_fk" ] || [ -z "$membership_user_id" ]; then
  log_message "Error: Failed to retrieve membership details."
  send_telegram_message "Error: Failed to retrieve membership details."
  exit 1
fi

# Process signups for the next 12 days (1-12 days from today)
signup_status=""
signup_summary=""
new_signups=0
errors=""
log_message "Processing signup for the next 12 days at $signup_hour"

for days_ahead in {1..12}; do
  # Calculate target date in DD-MM-YYYY format for API
  check_date=$(format_date $days_ahead "%d-%m-%Y")
  day=$(format_date $days_ahead "%A")
  
  # Set class name based on the day
  if [ "$day" == "Friday" ]; then
    check_class_name="Fuck You Friday"
  else
    check_class_name="CrossFit"
  fi
  
  # Check if already in CSV
  if is_in_csv "$check_date" "$signup_hour"; then
    signup_status="${signup_status}⏭️ $day $check_date - Already processed (in CSV)\n"
    log_message "Day $days_ahead: $check_date - Already in CSV, skipping"
    continue
  fi
  
  # Fetch schedule for this day
  check_schedule=$(curl 'https://apiappv2.arboxapp.com/api/v2/schedule/betweenDates' \
    -s -X POST \
    -H 'Content-Type: application/json' \
    -H "accesstoken: $access_token" \
    --data-raw '{"from":"'"$check_date"'","to":"'"$check_date"'","locations_box_id":'"$location_box_fk"',"boxes_id":'"$box_fk"'}')
  
  # Find the class for the specified hour
  check_class=$(echo "$check_schedule" | jq -r '.data[] | select(.time=="'"$signup_hour"'" and .box_categories.name=="'"$check_class_name"'")')
  
  if [ -z "$check_class" ] || [ "$check_class" == "null" ]; then
    signup_status="${signup_status}⚠️  $day $check_date - No class found\n"
    log_message "Day $days_ahead: $check_date - No class found"
    continue
  fi
  
  # Check if already signed up via API
  is_signed_up=$(echo "$check_class" | jq -r '.isSignedUp')
  if [ "$is_signed_up" == "true" ]; then
    signup_status="${signup_status}✅ $day $check_date - Already signed up (API)\n"
    add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
    log_message "Day $days_ahead: $check_date - Already signed up via API, added to CSV"
    continue
  fi
  
  # Try to sign up
  class_id=$(echo "$check_class" | jq -r '.id')
  signup_response=$(curl 'https://apiappv2.arboxapp.com/api/v2/scheduleUser/insert' \
    -s -X POST \
    -H 'Content-Type: application/json' \
    -H "accesstoken: $access_token" \
    --data-raw '{"schedule_id":'"$class_id"',"membership_user_id":'"$membership_user_id"'}')
  
  status_code=$(echo "$signup_response" | jq -r '.statusCode')
  
  if [ "$status_code" = "514" ]; then
    signup_status="${signup_status}✅ $day $check_date - Already signed up (signup attempt)\n"
    add_to_csv "$check_date" "$signup_hour" "$check_class_name" "already_signed_up"
    signup_summary="${signup_summary}Already signed up: $day $check_date"$'\n'
    log_message "Day $days_ahead: $check_date - Already signed up (status 514)"
  elif echo "$signup_response" | jq -e '.data' >/dev/null 2>&1; then
    signup_status="${signup_status}✨ $day $check_date - NEWLY signed up!\n"
    add_to_csv "$check_date" "$signup_hour" "$check_class_name" "signed_up"
    signup_summary="${signup_summary}✨ NEWLY SIGNED UP: $day $check_date"$'\n'
    new_signups=$((new_signups + 1))
    log_message "Day $days_ahead: $check_date - Successfully signed up"
  else
    # Signup failed
    error_msg=$(echo "$signup_response" | jq -r '.message // "Unknown error"')
    signup_status="${signup_status}❌ $day $check_date - FAILED: $error_msg\n"
    errors="${errors}❌ Failed to sign up for $day $check_date: $error_msg"$'\n'
    log_message "Day $days_ahead: $check_date - Signup failed: $error_msg"
  fi
  
  # Small delay to avoid rate limiting
  sleep 0.5
done

log_message "Signup processing complete for next 12 days. New signups: $new_signups"

# Get today's workout from user feed
user_feed=$(curl 'https://apiappv2.arboxapp.com/api/v2/user/feed' \
  -s \
  -H "accesstoken: $access_token")

# Extract all workout sections
workout_sections=""
crossfit_workout=""

# Process each workout category
for category_index in 0 1; do
  category_data=$(echo "$user_feed" | jq -r ".todayWorkout[$category_index] // empty")
  if [ -n "$category_data" ] && [ "$category_data" != "null" ]; then
    # Get category name from first section
    category_name=$(echo "$category_data" | jq -r '.[0][0].box_categories.name // empty')
    
    if [ "$category_name" == "CrossFit" ]; then
      crossfit_workout="📋 $category_name Workout:"$'\n'
      
      # Process each section in this category
      section_count=$(echo "$category_data" | jq 'length')
      for ((i=0; i<section_count; i++)); do
        section_name=$(echo "$category_data" | jq -r ".[$i][0].box_sections.name // empty")
        section_comment=$(echo "$category_data" | jq -r ".[$i][0].comment // empty")
        
        if [ -n "$section_comment" ] && [ "$section_comment" != "null" ]; then
          crossfit_workout="$crossfit_workout"$'\n'"🔹 $section_name:"$'\n'"$section_comment"$'\n'
        fi
      done
    fi
  fi
done

log_message "Retrieved CrossFit workout sections"

# Send Telegram notification if there are new signups or errors
if [ $new_signups -gt 0 ] || [ -n "$errors" ]; then
  # Build Telegram message
  message="🏋️ Signup Report for $signup_hour"
  
  if [ $new_signups -gt 0 ]; then
    message="$message

✨ New Signups ($new_signups):
$signup_summary"
  fi
  
  if [ -n "$errors" ]; then
    message="$message

⚠️ Errors:
$errors"
  fi
  
  # Add workout if available
  if [ -n "$crossfit_workout" ]; then
    message="$message

$crossfit_workout"
  fi
  
  send_telegram_message "$message"
  log_message "Telegram notification sent: $new_signups new signups, errors: $([ -n "$errors" ] && echo "yes" || echo "no")"
else
  # No new signups or errors - send just the workout if available
  if [ -n "$crossfit_workout" ]; then
    send_telegram_message "$crossfit_workout"
    log_message "Sent daily workout only (no new signups or errors)"
  else
    log_message "No new signups, no errors, and no workout available - no notification sent"
  fi
fi
