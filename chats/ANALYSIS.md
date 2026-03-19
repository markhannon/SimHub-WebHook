# Issue Analysis: Continuous Socket Connection to SimHub Property Server

## Issue Summary
**Title:** Open a continuous connection to SimHub property server to subscribe to changes

**Goal:** Replace the current event-driven polling approach with a persistent socket connection that streams property updates in real-time, reducing the number of required SimHub scripts from multiple event handlers to just two (start/stop).

---

## Current Architecture

### Current Flow
1. SimHub triggers macro events (GameStart, GameStop, NewLap, PitEnter, PitOut, SessionStatusChange)
2. Each event fires a VBScript shortcut (6 different .lnk files)
3. Each VBScript calls `Get-SimHub-Data.ps1` to:
   - Create a new TCP connection to SimHub Property Server (127.0.0.1:18082)
   - Send multiple `subscribe` commands for properties
   - Read single response
   - Close connection immediately
4. Data is parsed and saved to CSV files
5. CSV data is formatted and sent to Discord

### Current Issues
- **Inefficiency:** Opens/closes connection for each event (6+ connections per session)
- **Latency:** Properties are queried after events, not streamed real-time
- **Duplication:** Connection logic embedded in single-use Get-SimHub-Data.ps1
- **Complexity:** Requires 6 separate VBScript files in SimHub configuration
- **Not True Streaming:** Polls properties instead of subscribing to changes

---

## Proposed Solution Architecture

### New Flow
1. SimHub GameStart event triggers `Start-Connection.vbs`
   - Launches background PowerShell daemon: `SimHub-PropertyServer-Daemon.ps1`
   - Daemon opens persistent TCP socket to SimHub Property Server
   - Daemon subscribes to all properties and listens continuously
   - Daemon writes live updates to a queue/file as they arrive

2. Properties stream in real-time while game is running

3. SimHub GameStop event triggers `Stop-Connection.vbs`
   - Signals daemon to gracefully close connection
   - Cleans up resources

4. Existing Discord notification logic remains unchanged
   - Reads from daemon's output/state
   - Formats and sends to Discord as needed

---

## Implementation Plan

### Phase 1: Create Continuous Connection Daemon
**Files to create:**
- `SimHub-PropertyServer-Daemon.ps1` - Main background service

**Responsibilities:**
- Maintains persistent TCP connection to SimHub Property Server
- Subscribes to all properties from Properties.json
- Reads streaming updates continuously
- Tracks property state in real-time
- Handles graceful shutdown via control signal

**Key Features:**
- Singleton pattern - only one instance should run
- Writes current property state to `_daemon_state.json`
- Logs connection status and errors to `_daemon.log`
- Responds to stop signals from control scripts
- Handles network errors and reconnection logic

### Phase 2: Simplify SimHub Integration
**Files to modify/create:**
- `Start-PropertyDaemon.vbs` - Replace 3 start-related scripts
- `Stop-PropertyDaemon.vbs` - Replace 3 stop-related scripts

**Responsibilities:**
- Start-PropertyDaemon.vbs: Launch daemon at game start
- Stop-PropertyDaemon.vbs: Signal daemon to stop at game end
- Both scripts are minimalist - just trigger the daemon control

### Phase 3: Refactor Data Processing
**Files to modify:**
- `Get-SimHub-Data.ps1` - Update to read from daemon state instead of querying
- `Send-Discord-Data.ps1` - Integrate with daemon state

**Changes:**
- Remove direct socket connection logic
- Read property values from daemon's `_daemon_state.json`
- Preserve all existing CSV logging and Discord integration

---

## Technical Details

### SimHub Property Server Protocol
The existing code shows the protocol:
```
send: "subscribe <property_name>"
recv: "Property <name> <type> <value>"
send: "disconnect"
```

The daemon will:
1. Open socket
2. Send all subscribe commands
3. Enter read loop that processes incoming property updates
4. Never disconnect unless told to stop

### Daemon State File Format
```json
{
  "connected": true,
  "lastUpdate": "2026-03-19T04:05:00Z",
  "properties": {
    "dcp.GameRunning": true,
    "dcp.gd.PlayerName": "Player",
    "dcp.gd.CurrentLap": 5,
    ...
  },
  "processId": 12345
}
```

### Lifecycle Control
- **Start:** Create named pipe or signal file that daemon watches
- **Stop:** Write stop signal to control file
- **Health Check:** Read `_daemon_state.json` to verify connection

---

## Estimation

| Phase | Task | Complexity | Time |
|-------|------|-----------|------|
| 1 | Create daemon with persistent connection | High | 2-3 hours |
| 1 | Implement property subscription loop | Medium | 1-2 hours |
| 1 | Add error handling and reconnection | High | 1-2 hours |
| 2 | Create start/stop VBScripts | Low | 30 mins |
| 3 | Refactor Get-SimHub-Data.ps1 | Medium | 1 hour |
| 3 | Update Send-Discord-Data.ps1 | Low | 30 mins |
| Testing | Integration testing and debugging | Medium | 1-2 hours |
| **Total** | | | **7-11 hours** |

---

## Benefits

✅ **Performance:** Single persistent connection vs. multiple connect/disconnect cycles  
✅ **Real-time:** True streaming of property changes vs. delayed polling  
✅ **Simplicity:** 2 SimHub scripts vs. 6+  
✅ **Maintainability:** Daemon encapsulates network logic  
✅ **Compatibility:** Existing Discord/CSV logic remains unchanged  
✅ **Reliability:** Connection management and error handling in one place  

---

## Constraints & Considerations

- Daemon must handle network interruptions gracefully
- Subscription commands must complete with proper formatting
- State file operations must be atomic to avoid corruption
- Daemon must not consume excessive system resources during idle
- Must work with Windows Task Scheduler if needed for persistence

---

## Next Steps

1. ✏️ Create `SimHub-PropertyServer-Daemon.ps1` with persistent socket logic
2. ✏️ Implement property subscription streaming and state persistence
3. ✏️ Create `Start-PropertyDaemon.vbs` and `Stop-PropertyDaemon.vbs`
4. ✏️ Refactor existing data processing scripts
5. 🧪 Test daemon lifecycle and property streaming
6. 📋 Update Manifest.json to reference new scripts
