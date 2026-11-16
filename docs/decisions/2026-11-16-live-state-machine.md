---
id: 2026-11-16-live-state-machine
status: implemented
topic: live
prs: []
---
# The live session is a state machine, apart from the screen

- **Decision:** the phases (`Phase`) and the allowed moves between them (`TRANSITIONS`) live in `live_state.py`; `live_flow.py` is the only code that moves the state; `live_ui.py` only draws and forwards keys and buttons. An illegal move raises only with `STENO_STRICT=1` (the tests set it); otherwise it is logged as a warning and ignored, so a bug never crashes the app someone is dictating with.
- **Why:** phase strings were compared in the screen and the flow alike, and a check that dropped an update ("last line twice") was easy to write and hard to see. A finished line now also takes the partial it replaced with it, so no line can show twice between the two updates the loop sends.
- **Rejected:** always raising in real use (a crash loses the user's words); keeping the flow in the screen class (the file stays over 300 lines).
