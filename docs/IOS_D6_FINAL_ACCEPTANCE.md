# iOS D6 Final Acceptance

Status: **IN PROGRESS — implementation/test gates complete; real-device and process-boundary acceptance pending — 25 September 2026**

This acceptance record closes the implementation portion of **D6 — Native Media & Background Downloads** and defines the remaining D6-G evidence required before D6 can be marked complete and architecture-frozen.

## Current closure state

D6-0 through D6-F are implemented and testvalidated.

The canonical native iOS test gate is green after the final D6-F Media Settings work. D6-G is now the only open D6 package.

No further product implementation is currently required for D6-G unless a real-device/process-boundary check exposes a concrete regression.

## Automated evidence already accepted

The current automated suite covers the deterministic parts of the D6 contract:

- Core rebuild preserves protected media/playback/download/Listening List state;
- app-scoped media runtime follows Core replacement, rebuild and detach lifecycle;
- playback restores an InProgress position;
- pause, seek/lifecycle and periodic playback checkpoints use the Core path;
- natural completion reports Core completion;
- AVAudioSession interruption and route-loss orchestration are covered with deterministic fakes;
- app backgrounding checkpoints without pausing the native player;
- playback speed, sleep timer, duration observation and local artwork access are covered;
- persistent background-transfer session identity is stable and launch-event enabled;
- transfer task identity and deterministic per-account media file layout are covered;
- account execution identity is stable for the same account and rolls for another account;
- D5 media-transfer reconciliation buffering/coalescing and executor attachment are covered;
- News/Search article audio actions use batched Core projection rather than per-row Core queries;
- multiple-enclosure download selection/presentation semantics are covered;
- Listening List runtime progress, download summary and adaptive Player layout policy are covered;
- global media CoreSettings and per-feed automatic-download preference access are covered;
- the frozen UIKit Timeline, D4.5 manual-sync path and D5 background-sync suite remain inside the canonical iOS test gate.

These tests prove native orchestration and ownership. They do not substitute for OS scheduling, suspension, audio-route or physical-device presentation evidence.

## D6-G real-device / process-boundary matrix

| ID | Acceptance case | Automated evidence | Remaining physical-device evidence |
| --- | --- | --- | --- |
| G1 | Remote streaming | URL/preparation/runtime paths covered | Start an undownloaded audio enclosure and confirm sustained playback and seek |
| G2 | Downloaded-media playback | deterministic media file layout + local-source preference implemented | Download media, disable network access, play the local file successfully |
| G3 | Resume/checkpoint/restart/completion | resume/checkpoint/completion covered | Pause/leave app/reopen, verify resume; exercise Restart and natural completion |
| G4 | Chapters + Show Notes + artwork | Core/presentation paths covered | Verify real chapter seek, Reader Show Notes and artwork/fallback presentation |
| G5 | Interruption + route change | deterministic AVAudioSession fake coverage | Exercise a real interruption and a real output-route loss/change |
| G6 | Background audio | scene lifecycle test proves no intentional pause | Lock/background app and verify playback continues |
| G7 | Background download while suspended | background URLSession configuration covered | Start a sufficiently large download, suspend/background app and verify completion |
| G8 | Process termination/relaunch during transfer | task identity/account namespace/recovery design covered | Terminate/relaunch under the normal OS/process-recovery case and verify transfer state is reconciled |
| G9 | Completion with foreground UI absent | delegate/Core completion path implemented | Let a background transfer finish while app UI is absent, then reopen and verify Downloaded/local playback |
| G10 | Cancel / Retry / Delete | Core/action presentation paths covered | Exercise each against a real transfer/file and verify final durable state |
| G11 | Network-policy waiting/recovery | CoreSettings + request expensive/constrained-network policy implemented | With Unmetered Networks Only, verify transfer waits on an ineligible network and resumes when an eligible network returns |
| G12 | Account replacement/removal with outstanding transfer | Core/session/account identity lifecycle covered | Exercise account replacement/removal with an active/pending transfer and verify no old-account file/task is adopted |
| G13 | Rebuild with media state | Core rebuild regressions + iOS runtime rebuild lifecycle covered | Rebuild with Listening List/playback/download state and verify protected state remains coherent |
| G14 | Multiple audio enclosures | Core/presentation/action semantics covered | Exercise chooser, independent progress/download state and playback switching on a real multi-enclosure article |
| G15 | Compact iPhone + regular iPad | size-class layout policy covered | Accept Listening List and Player UI on physical compact iPhone and regular iPad |
| G16 | D5 background Sync -> D6 transfer executor | D5 success fanout and reconciliation handoff covered | Allow a real background Sync to create auto-download work and verify D6 executes it without foreground app interaction |
| G17 | Frozen-Timeline / D4.5 / D5 regression smoke | canonical test gate green | Smoke normal News scrolling/actions, Manual Sync and existing background/widget behavior |

## Process-termination boundary

G8 is a **normal process-recovery** acceptance check, not a promise to override explicit user force-quit behavior. The acceptance objective is that persisted Core intent, background-session tasks, deterministic task metadata and filesystem state reconcile correctly when iOS later gives the app a normal opportunity to resume/relaunch.

Do not add a second Swift durable completion queue solely to manufacture a force-quit guarantee.

## Suggested physical-device order

Run the real-device checks in this order so earlier failures isolate the smallest subsystem:

1. G1-G5 — foreground Player behavior.
2. G6 — background audio.
3. G2, G10, G14 — foreground transfer/file semantics.
4. G11 — network-policy waiting/recovery.
5. G7, G9 — suspended background transfer/completion.
6. G8 — process-recovery transfer reconciliation.
7. G12-G13 — account/rebuild destructive lifecycle.
8. G15 — compact/regular presentation acceptance.
9. G16-G17 — D5/D6 integration and final regression smoke.

## D6 closure gate

D6 may be marked **COMPLETE / architecture-frozen** when:

- the canonical iOS test gate remains green;
- the matrix above has no unresolved D6 regression;
- physical-device evidence confirms background audio and background URLSession behavior;
- process recovery does not adopt stale/foreign account work;
- compact iPhone and regular iPad media presentation are accepted;
- D5 background-sync transfer handoff is observed end-to-end at least once.

D7 Now Playing/remote commands/CarPlay and D8 ActivityKit/Dynamic Island are intentionally outside this acceptance record.
