# SimHub WebHook

Simple scripts to pull SimHub property data and send Discord status updates.

## Files
- `Get-SimHub-Data.ps1` — reads SimHub Property Server values and outputs JSON.
- `Format-Discord-Status.ps1` — pipeline filter that formats SimHub JSON into Discord-friendly text (code block table).
- `Send-Discord-Status.ps1` — sends formatted status to Discord webhook; can fallback to Discord embed format.
- `Discord.json` — webhook config file.
- `Properties.json` — SimHub properties to monitor.
- `Simhub.json` — SimHub host/port config.

## Usage
1. Configure `Simhub.json`, `Properties.json`, and `Discord.json`.
2. Test extraction:
   ```powershell
   .\Get-SimHub-Data.ps1
   ```
3. Test formatting:
   ```powershell
   .\Get-SimHub-Data.ps1 | .\Format-Discord-Status.ps1
   ```
4. Send to Discord:
   ```powershell
   .\Send-Discord-Status.ps1
   ```

## Discord config (`Discord.json`)
```json
{
  "hookUrl": "https://discord.com/api/webhooks/...",
  "useEmbeds": false,
  "embedTitle": "SimHub Status",
  "embedDescription": "SimHub status update",
  "embedColor": 16711680
}
```

Set `useEmbeds` to `true` to send structured embed fields instead of plain message content.

## Notes
- Discord does not natively render markdown pipe tables like GitHub; we emit code-block aligned columns for best readability.
- If using embeddings, this script converts JSON fields to embed fields.
