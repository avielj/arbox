# theboxnov.sh — Arbox Auto-Signup Script

## Overview
Automated CrossFit class signup script that interacts with the **Arbox API** to register for classes up to 12 days in advance. Sends notifications via **Telegram** and logs all activity.

## Location (Remote Server)
- **Server:** `ec2-user@52.89.15.92`
- **Path:** `/home/ec2-user/theboxnov.sh`
- **SSH Key:** `~/.ssh/occm_qa.pem`
- **Last Modified:** Nov 9, 2025

## Usage
```bash
./theboxnov.sh -e <email> -p <password> -h <hour>
```

| Flag | Description | Example |
|------|-------------|---------|
| `-e` | Arbox account email | `avielj@gmail.com` |
| `-p` | Arbox account password | `aj5588` |
| `-h` | Class time to sign up for (HH:MM) | `08:00` |

## Crontab (on server)
```cron
# Old/disabled entries:
#*/5 * * * * /home/ec2-user/sign.sh
#1 5 * * * /home/ec2-user/signs.sh > /dev/null 2>&1
#1 6 * * * /home/ec2-user/thebox-aug.sh > /dev/null 2>&1
#1 7 * * * /home/ec2-user/thebox-sep.sh > /dev/null 2>&1

# Active:
1 6 * * * /home/ec2-user/theboxnov.sh -e avielj@gmail.com -p aj5588 -h 08:00 >/dev/null 2>&1
```
Runs **daily at 06:01 UTC**.

## How It Works

### 1. Authentication
- Logs into Arbox API (`/api/v2/user/login`) with email/password
- Retrieves an access token

### 2. Membership Lookup
- Fetches membership details from `/api/v2/boxes/70/memberships/1`
- Extracts `location_box_fk`, `box_fk`, and `membership_user_id`

### 3. Signup Loop (12 days ahead)
For each of the next 12 days:
1. Determines class name: **"Fuck You Friday"** on Fridays, **"CrossFit"** otherwise
2. Checks local CSV (`signups.csv`) to skip already-processed dates
3. Fetches schedule from `/api/v2/schedule/betweenDates`
4. Checks if already signed up via API (`isSignedUp` flag)
5. Attempts signup via `/api/v2/scheduleUser/insert`
6. Records result in CSV and log

### 4. Workout Retrieval
- Fetches today's workout from `/api/v2/user/feed`
- Parses the CrossFit workout sections

### 5. Telegram Notification
- Sends signup report (new signups, errors) and/or daily workout
- **Bot Token:** `6002653819:AAFEvFKl_egoi925K5FLMoHGn_SDfplnvPU`
- **Chat ID:** `439481965`

## Generated Files (on server)
| File | Description |
|------|-------------|
| `signups.csv` | Tracks all signup attempts (date, time, class, status, timestamp) |
| `sign.log` | Detailed log with timestamps (~5.4 MB as of Apr 2026) |

### CSV Format
```csv
date,time,class_name,status,timestamp
07-11-2025,08:00,Fuck You Friday,already_signed_up,2025-11-06 14:52:38
09-11-2025,08:00,CrossFit,already_signed_up,2025-11-06 14:52:41
```

## Status Icons (in Telegram messages)
| Icon | Meaning |
|------|---------|
| ⏭️ | Skipped — already in CSV |
| ✅ | Already signed up (confirmed via API) |
| ✨ | Newly signed up |
| ❌ | Signup failed |
| ⚠️ | No class found for that day |

## Dependencies
- `curl` — HTTP requests
- `jq` — JSON parsing
- `bash` — Shell (cross-platform date handling for macOS/Linux)

## API Endpoints Used
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v2/user/login` | POST | Authentication |
| `/api/v2/boxes/70/memberships/1` | GET | Membership details |
| `/api/v2/schedule/betweenDates` | POST | Fetch class schedule |
| `/api/v2/scheduleUser/insert` | POST | Sign up for a class |
| `/api/v2/user/feed` | GET | Today's workout |
