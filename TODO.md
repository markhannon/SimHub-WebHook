# FIXES
- [x] Test Claude instead of Git Hub Co-Pilot
- [ ] Fix PowerShell paths (ref RussG and Discord)

# IMPROVEMENTS

- [x] Add one-line message summary that works on phone
    - [x] Re-architecture
- [ ] Implement multiple 'message' VBS with Control Mapper
    - [x] Add name to 'messages'
- [ ] Differentiate between Pit-In and Pit-Out events in summary
- [ ] Add stint-level lap time and fuel usage summary
- [ ] Suppress fuel warning if in-pit
- [ ] Add iRacing incident details
- [ ] Add iRacing penalty events (e.g. slow-down, DT, DQ)
- [ ] Merge architecture-review branch
- [ ] Cleanup tasks.json to remove irrelevant tasks
- [ ] Add flag to only send updates in race session (not in practice or qualify)

# INFRASTRUCTURE
- [ ] Add task and script to build an installable version

## DEPLOY
- [x] Run VBS in hidden window
- [x] Create new #simhub channel and webhook.   Store details on Discord.
- [x] Update Discord.json to remove webhook - add logic to detect no webhook for Send-Discord-Data.ps1
- [x] Ensure ISS installer doesn’t ask twice for SimHub
- [x] Version the ISS installer
- [x] Update ISS installer to write to defined folder
- [x] Prompt for overwrites of Event.json in ISS installer

## TEST
- [ ] Build SimHub capture and replay infrastructure
    - [x] Check Assetto Corsa in-game time and replay looping
    - [x] Cleanup Capture text messages (compact)
    - [ ] Cleanup Non capture text messages
- [ ] Build Discord fake infrastructure