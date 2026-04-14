# 🏋️ Arbox Auto-Signup

> Automatically sign up for CrossFit classes via the [Arbox](https://arboxapp.com) API — up to 12 days in advance, with Telegram notifications, waitlist support, and zero manual effort.

![Version](https://img.shields.io/badge/version-2.1.0-blue)
![Shell](https://img.shields.io/badge/shell-bash-green)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey)

---

## Features

| Feature | Description |
|---------|-------------|
| 🔐 **Secure config** | Credentials in `.env` file, never in git or crontab |
| 🔄 **Auto-retry** | 3 attempts with exponential backoff on API failures |
| 🔒 **Lock file** | Prevents overlapping cron runs |
| 📋 **Waitlist** | Automatically joins waitlist when class is full |
| 🏃 **Dry run** | Preview signups without actually registering |
| 📊 **Capacity info** | Shows registered/max slots in notifications |
| 🗑️ **Auto-cleanup** | CSV entries older than 30 days removed automatically |
| 📝 **Log rotation** | Rotates at 5 MB, keeps 3 backups |
| 🚫 **Skip days** | Configurable (default: Saturday) |
| 💾 **Membership cache** | Fetches box/membership IDs once, caches for future runs |
| 📱 **Telegram** | Signup reports + daily workout notifications |

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/avielj/arbox.git
cd arbox

# 2. Configure
cp .env.example .env
nano .env  # Add your Arbox & Telegram credentials

# 3. Run
chmod +x arbox-signup.sh
./arbox-signup.sh

# 4. (Optional) Schedule via cron
crontab -e
# Add: 1 6 * * * /path/to/arbox-signup.sh >/dev/null 2>&1
```

---

## Configuration

### `.env` variables

| Variable | Description | Required | Default |
|----------|-------------|:--------:|---------|
| `ARBOX_EMAIL` | Arbox account email | ✅ | — |
| `ARBOX_PASSWORD` | Arbox account password | ✅ | — |
| `SIGNUP_HOUR` | Class time (HH:MM) | ✅ | — |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token | 📱 | — |
| `TELEGRAM_CHAT_ID` | Telegram chat ID | 📱 | — |
| `DAYS_AHEAD` | Days to look ahead | | `12` |
| `CLASS_FRIDAY` | Friday class name | | `Fuck You Friday` |
| `CLASS_DEFAULT` | Default class name | | `CrossFit` |
| `SKIP_DAYS` | Days to skip (comma-separated) | | `Saturday` |

> **Note:** `BOX_ID` and membership details are auto-discovered on first run and cached in `.arbox_cache`.

---

## Usage

```bash
./arbox-signup.sh                # Use .env config (recommended)
./arbox-signup.sh --dry-run      # Preview without signing up
./arbox-signup.sh --cleanup      # Remove old CSV entries
./arbox-signup.sh --version      # Show version
./arbox-signup.sh --help         # Show all options
```

<details>
<summary>CLI flags (click to expand)</summary>

| Flag | Description |
|------|-------------|
| `-e EMAIL` | Arbox account email |
| `-p PASSWORD` | Arbox account password |
| `-h HOUR` | Class time HH:MM (e.g., `08:00`) |
| `--dry-run` | Preview without signing up |
| `--cleanup` | Remove CSV entries >30 days old |
| `--version` | Show version number |
| `--help` | Show usage help |

CLI args override `.env` values.

</details>

---

## Crontab

```cron
# Run daily at 06:01 UTC
1 6 * * * /path/to/arbox-signup.sh >/dev/null 2>&1
```

---

## How It Works

```
┌─────────────┐    ┌──────────┐    ┌───────────────┐    ┌──────────┐
│  Load .env  │───▶│  Login   │───▶│  Get/Cache    │───▶│  Loop    │
│  + Cache    │    │  (retry) │    │  Membership   │    │  12 days │
└─────────────┘    └──────────┘    └───────────────┘    └────┬─────┘
                                                             │
                    ┌──────────┐    ┌───────────────┐        │
                    │ Telegram │◀───│  Sign up /    │◀───────┘
                    │ Notify   │    │  Waitlist     │
                    └──────────┘    └───────────────┘
```

1. **Startup** — Checks `curl`/`jq`, loads `.env`, validates config, acquires lock
2. **Auth** — Logs into Arbox API (3 retries with backoff)
3. **Membership** — Uses cached IDs or fetches from API (first run only)
4. **Signup loop** — For each of the next N days:
   - Skip configured days (e.g., Saturday)
   - Skip dates already in CSV
   - Find matching class by time + name
   - Register or join waitlist if full
5. **Notify** — Sends Telegram report + daily workout

---

## Files

| File | Git | Description |
|------|:---:|-------------|
| `arbox-signup.sh` | ✅ | Main script |
| `.env.example` | ✅ | Config template (no secrets) |
| `.github/workflows/signup.yml` | ✅ | GitHub Actions workflow |
| `README.md` | ✅ | This file |
| `.env` | 🚫 | Your actual credentials |
| `.arbox_cache` | 🚫 | Cached membership IDs (auto-generated) |
| `signups.csv` | 🚫 | Signup log (auto-cleaned after 30 days) |
| `sign.log` | 🚫 | Detailed log (auto-rotated at 5 MB) |
| `.arbox-signup.lock` | 🚫 | Lock file (auto-managed) |

---

## Dependencies

- **`curl`** — HTTP requests
- **`jq`** — JSON parsing
- **`bash`** — Cross-platform (macOS + Linux)

All checked automatically at startup.

---

<details>
<summary>API Endpoints Used (click to expand)</summary>

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v2/user/login` | POST | Authentication |
| `/api/v2/boxes/{id}/memberships/1` | GET | Membership details |
| `/api/v2/schedule/betweenDates` | POST | Fetch class schedule |
| `/api/v2/scheduleUser/insert` | POST | Sign up for a class |
| `/api/v2/scheduleUser/insertStandby` | POST | Join waitlist |
| `/api/v2/user/feed` | GET | Today's workout |

</details>

---

## GitHub Actions (serverless option)

Run the script automatically via GitHub Actions — no server needed.

### Setup

1. Go to your repo → **Settings** → **Secrets and variables** → **Actions**

2. Add these **Secrets** (required):

   | Secret | Value |
   |--------|-------|
   | `ARBOX_EMAIL` | Your Arbox email |
   | `ARBOX_PASSWORD` | Your Arbox password |
   | `SIGNUP_HOUR` | e.g., `08:00` |
   | `TELEGRAM_BOT_TOKEN` | Your Telegram bot token |
   | `TELEGRAM_CHAT_ID` | Your Telegram chat ID |

3. (Optional) Add **Variables** for non-secret config:

   | Variable | Default |
   |----------|---------|
   | `DAYS_AHEAD` | `12` |
   | `CLASS_FRIDAY` | `Fuck You Friday` |
   | `CLASS_DEFAULT` | `CrossFit` |
   | `SKIP_DAYS` | `Saturday` |

### How it runs

- **Scheduled:** Daily at 06:01 UTC (same as crontab)
- **Manual:** Go to Actions tab → "Arbox Auto-Signup" → "Run workflow"
- **Dry run:** Check the "Dry run" box when triggering manually
- **Cache:** Membership IDs are cached between runs via GitHub Actions cache

> 💡 You can use GitHub Actions **instead of** or **alongside** a cron server. Both work independently.

---

## License

MIT
