# theboxnov.sh v2.0.0 — Arbox Auto-Signup Script

## Overview
Automated CrossFit class signup script that interacts with the **Arbox API** to register for classes up to N days in advance. Sends notifications via **Telegram** and logs all activity.

## What's New in v2.0.0
- **Security:** Credentials moved to `.env` file (no more plaintext in crontab/CLI)
- **Reliability:** Automatic retry with backoff on API failures (3 attempts)
- **Lock file:** Prevents overlapping cron runs from corrupting data
- **Dependency check:** Validates `curl` and `jq` are installed before running
- **Bug fix:** Hour validation now correctly rejects invalid hours (24:00-29:59)
- **Saturday skip:** Configurable skip days (default: Saturday)
- **Log rotation:** Auto-rotates when log exceeds 5 MB, keeps 3 backups
- **CSV cleanup:** Auto-removes entries older than 30 days; `--cleanup` flag
- **Dry run mode:** `--dry-run` to preview signups without registering
- **Waitlist support:** Auto-joins waitlist when class is full
- **Configurable:** Class names, box ID, days ahead all via `.env`

## Setup

### 1. Create `.env` file
```bash
cp .env.example .env
# Edit .env with your credentials
```

### 2. `.env` variables
| Variable | Description | Default |
|----------|-------------|---------|
| `ARBOX_EMAIL` | Arbox account email | (required) |
| `ARBOX_PASSWORD` | Arbox account password | (required) |
| `SIGNUP_HOUR` | Class time HH:MM | (required) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token | (required for notifications) |
| `TELEGRAM_CHAT_ID` | Telegram chat ID | (required for notifications) |
| `BOX_ID` | Arbox box ID | `70` |
| `DAYS_AHEAD` | Days to look ahead | `12` |
| `CLASS_FRIDAY` | Friday class name | `Fuck You Friday` |
| `CLASS_DEFAULT` | Default class name | `CrossFit` |
| `SKIP_DAYS` | Comma-separated skip days | `Saturday` |

## Usage
```bash
# Using .env file (recommended):
./theboxnov.sh

# CLI args (override .env):
./theboxnov.sh -e <email> -p <password> -h <hour>

# Preview mode:
./theboxnov.sh --dry-run

# Clean old CSV entries:
./theboxnov.sh --cleanup

# Show version:
./theboxnov.sh --version
```

| Flag | Description |
|------|-------------|
| `-e` | Arbox account email |
| `-p` | Arbox account password |
| `-h` | Class time HH:MM (e.g., `08:00`) |
| `--dry-run` | Preview without signing up |
| `--cleanup` | Remove CSV entries >30 days old |
| `--version` | Show version number |
| `--help` | Show usage help |

## Crontab (recommended)
```cron
# v2.0 — credentials in .env, no longer in crontab
1 6 * * * /path/to/theboxnov.sh >/dev/null 2>&1
```

## How It Works

### 1. Startup
- Checks dependencies (`curl`, `jq`)
- Loads `.env` config (CLI args take priority)
- Validates hour format (00:00-23:59)
- Rotates log if >5 MB
- Auto-cleans CSV if >500 lines
- Acquires lock file (prevents concurrent runs)

### 2. Authentication
- Logs into Arbox API with email/password
- Retrieves access token
- Retries up to 3 times with exponential backoff on failure

### 3. Membership Lookup
- Fetches membership details from `/api/v2/boxes/{BOX_ID}/memberships/1`
- Extracts `location_box_fk`, `box_fk`, and `membership_user_id`

### 4. Signup Loop (N days ahead)
For each of the next N days:
1. **Skip check:** Skips configured days (e.g., Saturday)
2. **CSV check:** Skips already-processed dates
3. **Schedule fetch:** Gets classes from Arbox API (with retry)
4. **Class match:** Finds class by time and name
5. **Capacity check:** Shows registered/max in notifications
6. **API check:** Checks `isSignedUp` flag
7. **Signup attempt:** Registers for class
8. **Waitlist fallback:** If class is full, tries to join waitlist
9. **CSV record:** Logs result

### 5. Workout Retrieval
- Fetches today's workout from `/api/v2/user/feed`
- Parses CrossFit workout sections

### 6. Telegram Notification
- Sends signup report with stats (new/already/skipped/failed)
- Includes errors and workout if available

## Generated Files
| File | Description |
|------|-------------|
| `signups.csv` | Signup tracking (auto-cleaned after 30 days) |
| `sign.log` | Detailed log (auto-rotated at 5 MB, 3 backups kept) |
| `.theboxnov.lock` | Lock file (auto-managed) |
| `.env` | Credentials and config (git-ignored) |

### CSV Format
```csv
date,time,class_name,status,timestamp
15-04-2026,08:00,CrossFit,signed_up,2026-04-14 06:01:05
18-04-2026,08:00,Fuck You Friday,waitlist,2026-04-14 06:01:12
```

### Possible statuses
| Status | Meaning |
|--------|---------|
| `signed_up` | Successfully registered |
| `already_signed_up` | Was already registered |
| `waitlist` | Added to waitlist (class full) |

## Dependencies
- `curl` — HTTP requests (checked at startup)
- `jq` — JSON parsing (checked at startup)
- `bash` — Shell (cross-platform macOS/Linux date handling)

## API Endpoints
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v2/user/login` | POST | Authentication |
| `/api/v2/boxes/{id}/memberships/1` | GET | Membership details |
| `/api/v2/schedule/betweenDates` | POST | Fetch class schedule |
| `/api/v2/scheduleUser/insert` | POST | Sign up for a class |
| `/api/v2/scheduleUser/insertStandby` | POST | Join waitlist |
| `/api/v2/user/feed` | GET | Today's workout |

## Security Notes
- Never commit `.env` to git (it's in `.gitignore`)
- Telegram bot token and credentials are only in `.env`
- Lock file prevents race conditions from overlapping cron runs
