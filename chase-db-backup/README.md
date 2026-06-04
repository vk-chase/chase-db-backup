
# Chase DB Backup

Dependency-free FiveM database backup resource for `oxmysql` servers.

This version does **not** use npm, Node packages, `mysqldump`, `package.json`, or `node_modules`. It builds a `.sql` backup through the same `oxmysql` database connection your server already uses, then uploads the SQL file to a Discord webhook when the file is within the configured upload size limit.

## Current Version

```txt
1.1.2
```

## Version Updates

### v1.1.2

Documentation pass.

- Added this README.
- Added full setup steps.
- Added convar reference.
- Added command reference.
- Added version history, fixes, additions, and safety notes.

### v1.1.1

Rotation, Discord size precheck, and startup delay pass.

- Added local backup rotation using `chase_db_max_local_backups`.
- Added `backup-index.json` runtime tracking inside the `sql` folder.
- Added Discord upload size precheck using `chase_db_max_discord_bytes`.
- Added Discord warning embed when a backup is too large to upload.
- Added startup delay using `chase_db_startup_delay` so `oxmysql` has time to settle before the first backup.
- Kept oversized backups locally instead of deleting them.

### v1.1.0

No-npm conversion.

- Removed npm requirement.
- Removed `index.js`.
- Removed `package.json`.
- Removed `discord-webhook-node` dependency.
- Removed `mysqldump` dependency.
- Rebuilt resource as Lua-only server code.
- Added `oxmysql`-based SQL dump generation.
- Added console-only manual backup command.
- Added webhook convar support.

### v1.0.0

Original concept.

- Automated MySQL backup resource.
- Discord webhook upload support.
- Scheduled backup support.

## Fixes Included

- Webhook is no longer hardcoded in the script.
- Secrets are pulled from server convars.
- No npm install step is required.
- No `node_modules` folder is required.
- Backup command is console-only.
- Scheduled backups are protected by a running-state lock.
- Startup backup can be delayed to avoid early database readiness issues.
- Local backups can be rotated automatically.
- Discord upload is skipped before upload if the SQL file is larger than the configured limit.
- Oversized backups are kept locally and reported to Discord with a warning embed.
- `fx_version 'cerulean'` is preserved exactly.

## Additions Included

- `server/main.lua`
- Runtime `sql/` backup folder
- Runtime `sql/backup-index.json` rotation index
- Discord webhook convar
- Database name convar with auto-detection fallback
- Backup schedule convars
- Local retention convars
- Discord upload size convar
- Startup delay convar
- Manual console command: `chasebackup`

## Folder Structure

```txt
chase-db-backup/
├── fxmanifest.lua
├── README.md
├── server/
│   └── main.lua
└── sql/
```

The `sql` folder is where local `.sql` backups are stored when local retention is enabled, Discord upload fails, or the backup is too large for Discord.

## Required Dependency

```cfg
ensure oxmysql
```

This resource depends on `oxmysql` because it uses the active database connection to read tables and build SQL backups.

## Setup Steps

1. Drop the `chase-db-backup` folder into your server resources.
2. Make sure `oxmysql` starts before this resource.
3. Add the convars below to `server.cfg`.
4. Add `ensure chase-db-backup` after `ensure oxmysql`.
5. Restart the server or start the resource from console.
6. Watch server console for the startup backup message.
7. Confirm the Discord webhook receives either the SQL file or a local-save warning.

## Recommended `server.cfg`

```cfg
ensure oxmysql

set chase_db_webhook "https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"

# Leave blank to auto-detect the active oxmysql database.
set chase_db_name ""

# Backup schedule.
# days: all, *, or comma list of month days like 1,15,30
# hours: all, *, or comma list of 24-hour values like 0,6,12,18
# minutes: comma list like 0,30
set chase_db_minutes "0,30"
set chase_db_hours "all"
set chase_db_days "all"

# Startup behavior.
set chase_db_run_on_start "1"
set chase_db_startup_delay "60"

# Local backup behavior.
set chase_db_keep_local "0"
set chase_db_keep_local_on_fail "1"
set chase_db_max_local_backups "10"

# Discord upload size limit in bytes.
# 25000000 = about 25 MB.
set chase_db_max_discord_bytes "25000000"

ensure chase-db-backup
```

## Convar Reference

### `chase_db_webhook`

Discord webhook URL.

```cfg
set chase_db_webhook "https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"
```

If this is blank, backups are saved locally only.

### `chase_db_name`

Database name to back up.

```cfg
set chase_db_name ""
```

Leave blank to auto-detect the active database with `SELECT DATABASE()`.

Alternative supported name:

```cfg
set chase_db_database "DATABASE_NAME_HERE"   # might look like QBCore_81390F  etc..
```

`chase_db_database` is checked first. If it is blank, the script checks `chase_db_name`.

### `chase_db_minutes`

Minute values when the backup should run.

```cfg
set chase_db_minutes "0,30"
```

This runs at minute `00` and `30` of every matching hour.

### `chase_db_hours`

Hour values when the backup should run.

```cfg
set chase_db_hours "all"
```

Examples:

```cfg
set chase_db_hours "0,6,12,18"
set chase_db_hours "all"
```

### `chase_db_days`

Day-of-month values when the backup should run.

```cfg
set chase_db_days "all"
```

Examples:

```cfg
set chase_db_days "1,15,30"
set chase_db_days "all"
```

### `chase_db_run_on_start`

Runs a backup shortly after the resource starts.

```cfg
set chase_db_run_on_start "1"
```

Use `0` to disable startup backups.

### `chase_db_startup_delay`

Delay in seconds before the startup backup runs.

```cfg
set chase_db_startup_delay "60"
```

Recommended: `60`.

This helps avoid backup failures during server boot when `oxmysql` or database connections are still settling.

### `chase_db_keep_local`

Keeps a local copy even after successful Discord upload.

```cfg
set chase_db_keep_local "0"
```

Use `1` if you want a local archive as well as Discord uploads.

### `chase_db_keep_local_on_fail`

Keeps the local SQL backup if Discord upload fails.

```cfg
set chase_db_keep_local_on_fail "1"
```

Recommended: `1`.

### `chase_db_max_local_backups`

Maximum number of local backups to keep.

```cfg
set chase_db_max_local_backups "10"
```

Use `0` to disable rotation pruning.

### `chase_db_max_discord_bytes`

Maximum file size allowed before attempting Discord upload.

```cfg
set chase_db_max_discord_bytes "25000000"
```

If the SQL file is larger than this value, the script does not attempt the file upload. It sends a Discord warning embed and keeps the SQL file locally.

### `chase_db_check_interval_ms`

How often the scheduler checks the clock.

```cfg
set chase_db_check_interval_ms "15000"
```

Default: `15000`.

Do not set this too low. A 15-second check interval is enough for minute-based schedules.

### `chase_db_chunk_size`

How many rows are fetched per query while dumping table data.

```cfg
set chase_db_chunk_size "500"
```

Default: `500`.

Higher values can make backups faster but may increase memory pressure on large tables.

### `chase_db_drop_table`

Adds `DROP TABLE IF EXISTS` before each table create statement.

```cfg
set chase_db_drop_table "1"
```

Default: `1`.

### `chase_db_include_data`

Controls whether table rows are included.

```cfg
set chase_db_include_data "1"
```

Use `0` to back up table structure only.

### `chase_db_color`

Discord embed color.

```cfg
set chase_db_color "#000000"
```

### `chase_db_footer`

Discord embed footer text.

```cfg
set chase_db_footer "Chase DB Backup"
```

## Commands

### Manual backup

Run from server console only:

```cfg
chasebackup
```

In-game execution is blocked on purpose.

## Discord Upload Notes

Discord has file upload limits. This resource checks the SQL file size before trying to upload.

If the backup is too large:

- The SQL file is kept in `chase-db-backup/sql/`.
- A Discord warning embed is sent.
- The backup is not deleted.
- Local rotation still applies if `chase_db_max_local_backups` is greater than `0`.

## Local Backup Rotation

When a local backup is kept, the script records it in:

```txt
chase-db-backup/sql/backup-index.json
```

The oldest tracked backups are deleted once the amount of local backups goes above:

```cfg
set chase_db_max_local_backups "10"
```

Only tracked local backups are rotated. If you manually copy unrelated `.sql` files into the folder, the script will not manage them unless they were created and indexed by this resource.

## Restore Notes

This resource creates SQL backup files only. It does not currently run restore commands.

Recommended restore flow:

1. Stop the server.
2. Copy the selected `.sql` backup from `chase-db-backup/sql/`.
3. Restore it through your database tool, such as HeidiSQL, phpMyAdmin, MySQL CLI, or your host panel.
4. Start the server again.

Do not restore while players are online.

## Safety Notes

- Keep the webhook in `server.cfg`, not inside the Lua file.
- Do not commit your real webhook to GitHub.
- Keep `ensure oxmysql` above `ensure chase-db-backup`.
- Large databases may be better handled locally instead of through Discord.
- For very large servers, use a host-level database backup system as the main backup and this resource as a lightweight extra safety layer.

## Troubleshooting

### Backup saved locally only

Check:

```cfg
set chase_db_webhook "https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"
```

If the webhook is blank, invalid, or Discord rejects the request, the backup can still be kept locally depending on your config.

### Backup too large for Discord

Increase the limit only if your Discord server actually supports larger uploads:

```cfg
set chase_db_max_discord_bytes "25000000"
```

Otherwise, leave it as-is and pull the SQL file from the server manually.

### Could not detect database

Set the database manually:

```cfg
set chase_db_name "your_database_name"
```

or:

```cfg
set chase_db_database "your_database_name"
```

### Backups are not running on schedule

Check the schedule values:

```cfg
set chase_db_minutes "0,30"
set chase_db_hours "all"
set chase_db_days "all"
```

The scheduler checks the current server time. Make sure your host time is correct.
