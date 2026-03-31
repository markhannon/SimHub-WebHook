# FIXES

# IMPROVEMENTS

- [ ] Replace .txt attachment with .png attachment
- [ ] Add basic stint info to pit-in message text
- [ ] Suppress events if no name is present
- [ ] Calculate stint lengths, average and best laps, fuel usage and include in pit-in event
- [ ] Create new event 'Driver Change' when a driver changes
- [ ] Create new events for 'Incidents'
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
- [ ] Fix ISS installer script
    - [ ] Fix version with pre-commit hook
    - [ ] Fix SimHub directory prompt with blank field
    - [ ] Fix repeated JSON overwrite prompts

## TEST
- [ ] Build SimHub capture and replay infrastructure
    - [x] Check Assetto Corsa in-game time and replay looping
    - [x] Cleanup Capture text messages (compact)
    - [ ] Cleanup Non capture text messages
- [ ] Build Discord fake infrastructure