# FIXES

# IMPROVEMENTS

- [ ] Add one-line message summary that works on phone
- [ ] Implement multiple 'message' VBS with Control Mapper
- [ ] Differentiate between Pit-In and Pit-Out events in summary
- [ ] Add stint-level lap time and fuel usage summary
- [ ] Suppress fuel warning if in-pit
- [ ] Add iRacing incident details
- [ ] Add iRacing penalty events (e.g. slow-down, DT, DQ)
- [ ] Merge architecture-review branch

# INFRASTRUCTURE

## DEPLOY
- [x] Run VBS in hidden window
- [ ] Create new #simhub channel and webhook.   Store details on Discord.
- [ ] Update Discord.json to remove webhook - add logic to detect no webhook for Send-Discord-Data.ps1

## TEST
- [ ] Build SimHub capture and replay infrastructure
    - [ ] Check Assetto Corsa in-game time and replay looping
- [ ] Build Discord fake infrastructure