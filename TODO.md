# FIXES

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

# INFRASTRUCTURE
- [ ] Add task and script to build an installable version

## DEPLOY
- [x] Run VBS in hidden window
- [ ] Create new #simhub channel and webhook.   Store details on Discord.
- [ ] Update Discord.json to remove webhook - add logic to detect no webhook for Send-Discord-Data.ps1

## TEST
- [ ] Build SimHub capture and replay infrastructure
    - [x] Check Assetto Corsa in-game time and replay looping
    - [x] Cleanup Capture text messages (compact)
    - [ ] Cleanup Non capture text messages
- [ ] Build Discord fake infrastructure