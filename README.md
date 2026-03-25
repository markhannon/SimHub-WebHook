# SimHub WebHook

Simple scripts to pull SimHub property data and send Discord status updates.

## Installation

Run `Install-To-SimHub.ps1` from the repository root to install files to your SimHub installation directory.

```powershell
.\Install-To-SimHub.ps1
```

### Installation Destinations

Files are installed to separate locations within your SimHub directory:

| File Type | Destination | Purpose |
|-----------|-------------|---------|
| PowerShell scripts (`.ps1`) | `SimHub\Webhooks` | Data collection and Discord notification sender |
| JSON config files | `SimHub\Webhooks` | Configuration for properties, events, Discord webhook |
| VBScript launchers (`.vbs`) | `SimHub\ShellMacros` | SimHub macro entry points for event-driven execution |

### Data Directory Structure

All scripts store telemetry CSV data and state in a shared data directory:

```
SimHub\Webhooks\data\
├── session.csv          # Session state (one row)
├── laps.csv            # Lap details (multiple rows)
├── events.csv          # Event log
├── summary.csv         # Session summary (if -Stop is used)
├── _lapstate.json      # Internal lap tracking state
├── _eventstate.json    # Internal event tracking state
└── _daemon_state.json  # Daemon process state
```

All PowerShell scripts use `-DataDir` parameter (default: `data` relative to script location). VBScript launchers automatically resolve the shared `SimHub\Webhooks\data` directory, so you do not need to configure data paths manually.

### Post-Installation

1. **Restart SimHub**  
   ⚠️ SimHub must be restarted after running `Install-To-SimHub.ps1` for VBScript files installed to `ShellMacros` to be recognized.

2. **Configure Event Mappings**  
   In SimHub, go to **Controls and Events → Events** and create two new event mappings:
   
   | Event | Action |
   |-------|--------|
   | `Game Started` | Run macro: `Get-SimHub-Data-Start.vbs` |
   | `Game Stopped` | Run macro: `Get-SimHub-Data-Stop.vbs` |
   
   - **Game Started**: Triggers daemon to start collecting telemetry  
   - **Game Stopped**: Triggers daemon to stop and finalize session data

3. **Verify Setup**  
   Launch a race session. You should see:
   - Data collection daemon starts on game start
   - CSV files appear in `SimHub\Webhooks\data\` during the session
   - Daemon stops cleanly on game stop with summary CSV generated

## Files
- `Get-SimHub-Data.ps1` — Collects telemetry data from SimHub Property Server, processes and persists session/lap data to CSV files. Supports debug output and event flags.
- `Format-Csv-Data.ps1` — Reads session and lap CSVs, formats the data into Discord-friendly markdown tables. Supports options for including lap summaries, custom headers, and suppressing fuel/lap fields.
- `Send-Discord-Data.ps1` — Sends SimHub session/lap data to Discord with event-driven options (SessionStart, SessionEnd, PitIn, PitOut, Status). Handles formatting and event-specific output.
- `Install-To-SimHub.ps1` — Installs dashboard, overlay, and other files to SimHub directories based on Manifest.json configuration. Supports batch, JSON, PowerShell, VBScript, and shortcut files.
- `Discord.json` — webhook config file.
- `Events.json` — configurable event trigger rules used to write `events.csv`.
- `Properties.json` — SimHub properties to monitor.
- `Simhub.json` — SimHub host/port config.

## Usage

### Quick Start
1. Configure `Simhub.json`, `Properties.json`, `Discord.json`, and `Events.json`.
2. Test extraction:
   ```powershell
   .\Get-SimHub-Data.ps1
   ```
3. Test formatting:
   ```powershell
   .\Format-Csv-Data.ps1
   ```
4. Send to Discord:
   ```powershell
   .\Send-Discord-Data.ps1
   ```

### Command Line Options

#### Get-SimHub-Data.ps1
Collects telemetry data from SimHub Property Server and persists it to CSV files.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Start` | switch | — | Initialize collection session and start daemon |
| `-Stop` | switch | — | Stop collection and finalize session data |
| `-Reset` | switch | — | Force stop all daemons and reset state (destructive) |
| `-UpdateInterval` | int | 1 | Seconds between daemon state checks |
| `-DataDir` | string | `data` | Directory for CSV and state files (relative or absolute) |

**Examples:**
```powershell
# Start continuous collection
.\Get-SimHub-Data.ps1 -Start

# Stop and finalize session
.\Get-SimHub-Data.ps1 -Stop

# Reset state (clears all state files)
.\Get-SimHub-Data.ps1 -Reset

# Use custom data directory
.\Get-SimHub-Data.ps1 -Start -DataDir C:\SimHub\Webhooks\data

# Check collection every 2 seconds
.\Get-SimHub-Data.ps1 -Start -UpdateInterval 2
```

#### Format-Csv-Data.ps1
Formats SimHub CSV data into Discord-friendly markdown tables.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Extra` | string | — | Custom header text to include in output |
| `-IncludeLaps` | switch | — | Include lap-by-lap summary in output |
| `-Minimal` | switch | — | Exclude fuel and lap fields from output |
| `-DataDir` | string | `data` | Directory containing CSV files (relative or absolute) |

**Examples:**
```powershell
# Format with custom header
.\Format-Csv-Data.ps1 -Extra "Live Session Update"

# Include lap details
.\Format-Csv-Data.ps1 -IncludeLaps

# Minimal output (no fuel/laps)
.\/Format-Csv-Data.ps1 -Minimal

# Use custom data directory
.\Format-Csv-Data.ps1 -DataDir samples
```

#### Send-Discord-Data.ps1
Sends SimHub session/lap data to Discord webhook with event-specific formatting.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SessionStart` | switch | — | Format as session start event (compact, no laps) |
| `-SessionEnd` | switch | — | Format as session end event (full details) |
| `-PitIn` | switch | — | Format as pit entry event |
| `-PitOut` | switch | — | Format as pit exit event |
| `-Status` | switch | — | Format as status update (default if no event specified) |
| `-EventName` | string | — | Custom event name for output header |
| `-EventScope` | string | — | Event scope identifier (not currently used in output) |
| `-EventDetails` | string | — | Additional event details (not currently used in output) |
| `-PrintOnly` | switch | — | Print payload and attachment preview to console without sending to Discord |
| `-DataDir` | string | `data` | Directory containing CSV files (relative or absolute) |

**Examples:**
```powershell
# Send session start notification
.\Send-Discord-Data.ps1 -SessionStart

# Send session end with full details
.\Send-Discord-Data.ps1 -SessionEnd

# Send pit stop notification
.\Send-Discord-Data.ps1 -PitIn

# General status update (default event)
.\Send-Discord-Data.ps1 -Status

# Custom event with header text
.\Send-Discord-Data.ps1 -EventName "Fastest Lap" -EventScope "Personal"

# Print payload without sending
.\Send-Discord-Data.ps1 -Status -PrintOnly

# Use sample data directory
.\Send-Discord-Data.ps1 -Status -DataDir samples
```

#### Install-To-SimHub.ps1
Installs all scripts and configuration files to SimHub directories based on Manifest.json.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-dashboards` | switch | $false | Include dashboard files (if applicable) |
| `-overlays` | switch | $false | Include overlay files (if applicable) |

**Examples:**
```powershell
# Install to SimHub (standard installation)
.\Install-To-SimHub.ps1

# Install with dashboards
.\Install-To-SimHub.ps1 -dashboards

# Install with overlays
.\Install-To-SimHub.ps1 -overlays

# Install with both
.\Install-To-SimHub.ps1 -dashboards -overlays
```

#### SimHub-PropertyServer-Daemon.ps1
Manages the persistent daemon connection to SimHub Property Server.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Start` | switch | true (if no other flag) | Start the daemon (continuous connection) |
| `-Stop` | switch | — | Stop the daemon |
| `-Status` | switch | — | Check daemon status |
| `-Capture` | switch | — | Connect to Property Server and capture change-only updates at 1 Hz to a capture JSON file |
| `-Replay` | switch | — | Replay a capture JSON file by writing synthetic daemon state updates at 1 Hz |
| `-CaptureFile` | string | auto-generated under `data/captures` | Optional output file path for capture mode |
| `-ReplayFile` | string | latest file in `data/captures` | Optional capture file path to replay |
| `-ReplaySpeed` | double | `1.0` | Replay speed multiplier (only valid with `-Replay`) |
| `-DataDir` | string | `data` | Directory for daemon state and logs (relative or absolute) |

**Examples:**
```powershell
# Start the daemon (continuous connection)
.\SimHub-PropertyServer-Daemon.ps1 -Start

# Check daemon status
.\SimHub-PropertyServer-Daemon.ps1 -Status

# Stop the daemon
.\SimHub-PropertyServer-Daemon.ps1 -Stop

# Capture live property changes (change-only, 1 Hz)
.\SimHub-PropertyServer-Daemon.ps1 -Capture

# Replay latest capture for collector testing
.\SimHub-PropertyServer-Daemon.ps1 -Replay

# Replay specific capture at 2x speed
.\SimHub-PropertyServer-Daemon.ps1 -Replay -ReplayFile .\data\captures\session-capture-20260325-143022.json -ReplaySpeed 2

# Use custom data directory
.\SimHub-PropertyServer-Daemon.ps1 -Start -DataDir samples
```

#### Sample-SimHub-Data.ps1
Interactive test script that runs a complete data collection cycle with sample data directory.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| (none) | — | — | No parameters; runs automatic start/stop cycle |

**Usage:**
```powershell
# Run interactive sample collection
.\Sample-SimHub-Data.ps1

# (Press Ctrl+C to stop; script auto-finalizes with -Stop)
```

## Discord config (`Discord.json`)
```json
{
  "hookUrl": "https://discord.com/api/webhooks/..."
}
```

`Send-Discord-Data.ps1` sends TXT-only output.

- The script posts one Discord message with a single attachment: `simhub-table.txt`.
- Embed, PNG, and CSV output paths have been removed from this script.

Examples:

```powershell
.\Send-Discord-Data.ps1 -DataDir samples
```

## Event config (`Events.json`)
`Get-SimHub-Data.ps1` evaluates enabled events on each telemetry sample and writes matches to `data/events.csv`.

Each event definition includes:
- `EventName`
- `Enabled`
- `Rule`
- `RuleSettings`

Default events:
- Session Started
- Session Stopped
- Position Changed
- Fastest Lap
- Entering Pits
- Exiting Pits
- Bad lap

## Notes
- Discord does not natively render markdown pipe tables like GitHub; we emit code-block aligned columns for best readability.
- Discord sender output is txt-only for this script path.

## Quick sanity check
Run all steps in one pipeline:
```powershell
.\Format-Csv-Data.ps1 -Extra "Live" | Out-Host
.\Send-Discord-Data.ps1 -Extra "Live"
```
Set up in Task Scheduler/CRON by calling `Send-Discord-Data.ps1` on interval.

