# SimHub WebHook

Simple scripts to pull SimHub property data and send Discord status updates.

## Installation





## Files
- `Get-SimHub-Data.ps1` — Collects telemetry data from SimHub Property Server, processes and persists session/lap data to CSV files. Supports debug output and event flags.
- `Format-Csv-Data.ps1` — Reads session and lap CSVs, formats the data into Discord-friendly markdown tables. Supports options for including lap summaries, custom headers, and suppressing fuel/lap fields.
- `Send-Discord-Status.ps1` — Sends formatted session/lap status to Discord via webhook. Accepts optional header text and uses Format-Csv-Data.ps1 for output formatting.
- `Send-Discord-Data.ps1` — Sends SimHub session/lap data to Discord with event-driven options (SessionStart, SessionEnd, PitIn, PitOut, Status). Handles formatting and event-specific output.
- `Install-To-SimHub.ps1` — Installs dashboard, overlay, and other files to SimHub directories based on Manifest.json configuration. Supports batch, JSON, PowerShell, VBScript, and shortcut files.
- `Discord.json` — webhook config file.
- `Events.json` — configurable event trigger rules used to write `events.csv`.
- `Properties.json` — SimHub properties to monitor.
- `Simhub.json` — SimHub host/port config.

## Usage
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
   .\Send-Discord-Status.ps1
   ```
5. Optional extra header text:
   ```powershell
   .\Send-Discord-Status.ps1 -Extra "My custom status header"
   ```

## Discord config (`Discord.json`)
```json
{
  "hookUrl": "https://discord.com/api/webhooks/...",
  "embedTitle": "SimHub Status",
  "embedDescription": "SimHub status update",
  "embedColor": 16711680
}
```

`Send-Discord-Data.ps1` now sends Discord embeds by default.

- Use `-UseTextMode` to force legacy plain-text content output.
- `embedTitle`, `embedDescription`, and `embedColor` are optional overrides for embed styling.

Examples:

```powershell
.\Send-Discord-Data.ps1 -DataDir samples
.\Send-Discord-Data.ps1 -DataDir samples -UseTextMode
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
- If using embeddings, this script converts JSON fields to embed fields.

## Quick sanity check
Run all steps in one pipeline:
```powershell
.\Format-Csv-Data.ps1 -Extra "Live" | Out-Host
.\Send-Discord-Status.ps1 -Extra "Live"
```
Set up in Task Scheduler/CRON by calling `Send-Discord-Status.ps1` on interval.
