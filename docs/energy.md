# Energy

Measured on 2026-09-02 on an Apple M5 Pro running macOS 26.6.2 on battery power: `build/Notchmeter.app` launched as `Notchmeter --no-prompt`, the panel compact and untouched, the Claude session ring urgent (85 % and behind pace), and a heavy Claude Code job in the background: an orchestrator and three subagents appending to transcripts of 10 MB and more inside the current 5-hour block (3,811 transcripts under `~/.claude/projects`), the Claude endpoint read on the saved login, Codex on a free plan, Cursor on a free plan, Copilot not signed in. The first 45 seconds after launch (the initial reads and the first cost scan) were left out.

| Window | Method | Result |
|---|---|---|
| 60 s | `ps -o cputime=` before and after, divided by wall time | 0.84 CPU-seconds / 61 s = **1.4 %** of one core |
| 180 s including at least one cost scan | same | 2.99 CPU-seconds / 182 s = **1.6 %** of one core |
| the same 180 s in 30 s samples | `top -l 7 -s 30 -stats pid,cpu,mem -pid <pid>` | 0.0, 1.5, 6.5, 0.0, 0.8, 0.0, 0.8 % of one core |

The samples at 0.0 are the app between scans: the minute tick (power source and a few directory listings), the 30-second report file and the pill's drawing do not register. The 6.5 % sample is a cost scan, and the scan is the whole figure: an unchanged file is folded from its cached quarter-hour totals, but a file that changed inside the current 5-hour block is re-read at entry level for the last-hour and block figures, so the cost of a scan is the size of the transcripts being written right now, which in this measurement was several files of 10 MB and more. On a quiet day (one session writing a few hundred kilobytes) the same procedure in September 2026 read 0.02 % over 60 s and 0.47 % over 180 s. The measurement also found and removed a cost that had nothing to do with scans: the urgent ring's opacity pulse was a SwiftUI animation that never ended, which re-rendered the readout on every frame for as long as a window stayed behind pace, 5 to 9 % of a core; it now pulses three times on becoming urgent and then holds. Its cadence follows the polling policy: every minute on mains power while a Claude session is active, every two minutes on battery or in Low Power Mode, every four minutes once no agent has been active for 30 minutes, and never while the screen is locked, the displays are asleep or the Mac is asleep. The same measurement before this version read 1.62 % over 60 s, because the 17 MB transcript cache was rewritten on every scan while a session was appending to a transcript; it is now written at most once every ten minutes.

**Translucent materials.** The figures above are for the solid black panel, which is what every install draws until Glassy or Smoked is chosen under Settings › Appearance › Theme (added 2026-09-24). A translucent material adds a behind-window blur (`NSVisualEffectView`), and WindowServer composites such a blur on every frame the desktop under it changes whether or not something opaque is drawn over it, so a blur left in the window under the compact strip would have been paid for on every menu-bar redraw and every window dragged under the notch, for nothing anyone sees. The blur is therefore in the window only while the panel is open, and comes out again once the close fade has covered it (`NotchView.backdropMounted`); the compact strip, which is where the panel spends nearly all its time, costs what the solid panel costs. What the blur costs WindowServer while the panel is held open was not measured; the method is `top -l 7 -s 30 -stats pid,cpu -pid $(pgrep -x WindowServer)` with the panel held open, Glassy against Solid, and the number belongs here when someone runs it.

**Resident size.** Measured on 2026-09-02 on the same Mac, `/Applications/Notchmeter.app` launched and left alone beside the notch, with 3,868 transcripts under `~/.claude/projects`, a 2.3 MB cost cache and a Claude Code session appending to a transcript in the current 5-hour block throughout, sampled with `ps -o rss=` every 20 seconds for thirteen minutes from launch: **101 MB** at launch, **99 to 105 MB** for the rest of it, and **99 MB** at the end — flat, not climbing. Two samples stand out, 110 MB at two minutes and 125 MB at twelve, and both are the samples where the process's CPU time steps by a third of a second while the others step by a hundredth: they are cost scans, held for less than one 20-second sample each.

**That figure is `ps`, and `ps` counts pages the app shares with every other app on the Mac.** At 13 minutes, with `ps -o rss=` reading 107 MB, `vmmap -summary` put the same process's physical footprint — what macOS charges it, and what Activity Monitor shows — at **63 MB, with a peak of 77 MB**. Of that, 42 MB is dirty, and the malloc zones hold 19.5 MB of live allocations inside 34 MB of dirty heap; the rest of the resident size is framework text shared with every other SwiftUI app running. An earlier run of the same method on this Mac read 36 to 88 MB over nine minutes and did not reproduce, which is the point of publishing both numbers with the commands rather than a band to hold the app to: what a sampler sees depends on how much transcript the scan has to re-read at entry level while it runs, and on how much of the frameworks the app has touched by then.

The resident size climbing and *staying* is the fault worth watching, and one was found this way: an earlier version of this section quoted 63 to 70 MB from a `top` run, which was never the resting size on a busy Mac. The cost scanner held the parsed entries of every transcript touched in the last thirty days for as long as the app ran, though entries are only ever read for the current 5-hour block, and resident size climbed past 190 MB and stayed there. Entries are now dropped once a file ages out of that block, which took the cache file from 13.4 MB to 2.1 MB here, and the cache files earlier versions left behind (33 MB of them on this Mac) are removed the first time the scanner loads.

To reproduce (a second copy of the app appears beside the notch while it runs):

```bash
build/Notchmeter.app/Contents/MacOS/Notchmeter --no-prompt & PID=$!
sleep 45; ps -o cputime= -p $PID
top -l 7 -s 30 -stats pid,cpu,mem -pid $PID | grep "^ *$PID"     # 180 s of samples
for i in $(seq 1 39); do ps -o rss= -p $PID; sleep 20; done      # resident size, in KB
vmmap -summary $PID | grep "Physical footprint"                  # what macOS charges the app
ps -o cputime= -p $PID; kill $PID
```

The authoritative number is Energy Impact from `powermetrics`, which on Apple silicon accounts for idle wake-ups as well as CPU time. It needs `sudo` and was **not** run for the figures above; to get it:

```bash
sudo powermetrics --samplers tasks --show-process-energy -i 60000 -n 5 | grep -E '^Name|Notchmeter'
```
