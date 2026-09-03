# ZPause

**Synced co-op pause for Black Ops II Zombies (Plutonium T6)**

by Xep

Any player can pause. Any player can unpause. The state lives on `level`, so it's
identical for everyone — there's no per-client state that can desync.

- Zombies stop where they are, and stop spawning
- Players are locked and can't be hurt
- The match clock, powerup timers, effect countdowns and bleedout all hold
- Resumes on a 3‑2‑1 countdown with a short grace period

---

## Requirements

Plutonium T6 (Black Ops II), zombies. No other mods or dependencies.

---

## Install

Two packagings of the **same** file are included. Plutonium only lets you enable one mod
at a time, so the script version is usually the better choice — it coexists with whatever
mod you're running.

### Script version (recommended)

Drop `zpause.gsc` into your T6 storage scripts folder:

```
%localappdata%\Plutonium\storage\t6\scripts\zm\zpause.gsc
```

On newer Plutonium builds the path is under `raw`:

```
%localappdata%\Plutonium\storage\t6\raw\scripts\zm\zpause.gsc
```

If you aren't sure which your build uses, put it in both — only the one that exists will
be read.

### Mod version

Copy the `zm_pause` folder into your mods folder:

```
%localappdata%\Plutonium\storage\t6\mods\zm_pause\scripts\zm\zpause.gsc
```

Then pick **zm_pause** from the in-game Mods menu. The folder name must keep its `zm_`
prefix or it won't show up in the zombies mod list.

You don't need to restart the game to reload a script — just end the current game and
start a new one.

---

## Usage

| Action | Input |
|---|---|
| Pause / unpause | type `!pause` or `!p` in chat |
| Unpause only | type `!unpause`, `!resume` or `!u` |
| Pause / unpause | hold **crouch + melee** together for ~0.3s |

The button combo keeps working while you're frozen — `freezecontrols()` blocks movement
and weapon use, but button state still reaches the server. That's what lets a frozen
player resume without opening chat.

Resuming runs a 3‑2‑1 countdown with **everything still frozen**, then releases the whole
game at once and gives players 2 seconds of invulnerability so nobody eats a hit from a
zombie that was mid‑swing.

---

## Configuration

Every setting is at the top of the file under `zp_load_config()`, and each one is also a
dvar of the same name. The script creates each dvar with its default on load, so you can
set them straight from the console:

```bash
zp_countdown 5
```

The config is re-read at the start of every pause, so a change takes effect on the **next
pause** — no map restart needed. Anything already set in your `config.cfg` before the map
loads is left alone.

| Dvar | Default | What it does |
|---|---|---|
| `zp_allow_short_words` | `0` | Also accept bare `p` / `u` / `pause` in chat. Off by default so normal conversation can't pause the game. |
| `zp_button_combo` | `1` | Enable the crouch + melee combo. |
| `zp_button_hold_time` | `0.3` | How long the combo must be held. |
| `zp_countdown` | `3` | Seconds of 3‑2‑1 before play resumes. |
| `zp_grace` | `2` | Seconds of invulnerability after resuming. |
| `zp_cooldown` | `2` | Minimum seconds between toggles. |
| `zp_max_pause_time` | `0` | Auto-resume after N seconds. `0` = unlimited. |
| `zp_engine_freeze` | `1` | Use `disablezombies()` / `enablezombies()`. |
| `zp_drift_guard` | `1` | Snap back any AI that still manages to move. |
| `zp_freeze_anims` | `1` | Put zombies in a standing idle pose instead of looping their last animation. |
| `zp_godmode` | `1` | Make players invulnerable while paused. |
| `zp_control_guard` | `1` | Re-apply the player freeze every tick, so a map script can't hand controls back mid-pause. |
| `zp_freeze_clock` | `1` | Hold the match timer. |
| `zp_freeze_powerups` | `1` | Stop ground powerups timing out. |
| `zp_freeze_effects` | `1` | Hold insta-kill / double-points countdowns. |
| `zp_freeze_bleedout` | `1` | Stop downed players bleeding out. |
| `zp_blackout` | `0` | Black out everyone's screen while paused (anti-scouting). |
| `zp_blur` | `1` | Blur everyone's screen while paused. Clears when play resumes. |
| `zp_blur_amount` | `1.5` | Blur strength. `4` is the blur the game runs when you buy a perk. |
| `zp_show_hint` | `1` | Tell players how to pause when they spawn. |
| `zp_pause_sound` | `zmb_zombie_go_inert` | Played when the game is paused. `""` = silent. |
| `zp_countdown_sound` | `zmb_tombstone_timer_count` | Played on each countdown tick. `""` = silent. |
| `zp_resume_sound` | `zmb_zombie_end_inert` | Played when play resumes. `""` = silent. |

### Sounds

All three are stock aliases, so both packagings stay a single drop-in file. A custom
sound would have to ship as a fastfile and be installed by **every player** rather than
just the host, so ZPause uses the game's own audio instead.

The defaults are what the game itself uses them for: a zombie plays `go_inert` and
`end_inert` when it drops dormant and wakes back up, and `zmb_tombstone_timer_count` is
the game's own once-a-second countdown tick. Other aliases worth trying, all of them
played by core zombies scripts and so present on every map:

| Alias | What it is |
|---|---|
| `mpl_ui_timer_countdown` | The plain UI beep from the end-of-match clock. |
| `zmb_tombstone_timer_out` | The sting when that timer runs out. |
| `zmb_perks_power_on` | Power switch coming on. |
| `zmb_cha_ching` | Points. |
| `zmb_box_poof` | The magic box vanishing. |
| `zmb_whoosh` | Short whoosh. |
| `evt_perk_deny` | Buzzer. |

Swap one in from the console:

```bash
zp_resume_sound zmb_perks_power_on
```

---

## How it works

**Treyarch already shipped a working full-game pause in T6 zombies.** It's what runs
during a host migration. The stock script `maps\mp\gametypes_zm\_hostmigration.gsc` does
exactly this:

```gsc
disablezombies( 1 );            // engine-level AI freeze
flag_clear( "spawn_zombies" );  // the spawner's own gate
player freezecontrols( 1 );     // lock players
player enableinvulnerability(); // nobody can be hurt
locktimer();                    // hold level.discardtime so the clock stops
```

…and the exact inverse to resume. ZPause uses that recipe rather than inventing one, so
the spawner, the round counter and the match clock are all stopped the way the game
expects:

- **`disablezombies()` / `enablezombies()`** are engine builtins — the same calls host
  migration uses.
- **`flag_clear("spawn_zombies")`** is the flag `_zm.gsc`'s spawn loop actually blocks on,
  so spawning stops at the source instead of being fought.
- **`level.discardtime`** is subtracted from the match clock, so pushing it forward by the
  elapsed time holds the timer still.

On top of that, ZPause covers what host migration never has to because it only lasts a few
seconds:

- **An AI enforcer** that re-freezes anything appearing mid-pause, keeps `ignoreall`
  pinned, and snaps back any AI that drifts. It's a safety net — if the engine freeze does
  its job it never fires, so there's no jitter.
- **A player enforcer.** Map scripts that carry a player somewhere lock the controls for
  the ride and call `freezecontrols( 0 )` when it ends — Ascension's lander is the one
  that bites. That release lands mid-pause and hands one player free movement around a
  frozen game. `freezecontrols()` has no getter, so the guard re-asserts the freeze on a
  tick rather than testing it, and re-pins godmode and `ignoreme` while it's there.
- **The stuck-zombie watchdog.** `round_spawn_failsafe()` kills any zombie that hasn't
  moved 24 units in 30 seconds (15 on Origins and Mob of the Dead), assuming it's stuck
  outside the playspace. A paused zombie trips it every time, and the "put it back in the
  spawn queue" compensation is skipped for anything with `ignoreall` set — so those
  zombies are gone for good, counted as killed, and the round advances while everyone's
  away. ZPause keeps the barrier-chunk timestamp fresh, which all three variants honour,
  so the watchdog loops harmlessly instead of firing and still works normally afterwards.
- **Ground powerups.** `powerup_timeout()` is a plain `wait()` and can't be paused, so the
  thread is cut and restarted on resume.
- **Insta-kill / double points.** Their HUD countdowns are held still. The 30s `wait()`
  driving the real effect keeps running underneath, so on resume a bounded thread holds
  the effect on until the frozen countdown genuinely runs out, then forces it off —
  without that, the effect would stick on for the rest of the game.
- **Bleedout** is pinned so a downed player doesn't bleed out.
- **Late joiners and respawns** are frozen on spawn, and everything is torn down on
  `end_game` so nobody is left frozen at the scoreboard.

### Why not `timescale`?

`timescale 0` looks like the perfect pause — it would freeze everything, timers included.
But GSC `wait` runs on server time, so the unpause loop freezes with it and the game can
never be resumed. The server also only runs a frame once enough scaled time accumulates,
so snapshots stop going out and clients drop with *Connection Interrupted*. Slow motion
(`timescale 0.05`) avoids the disconnects but isn't a pause.

---

## Notes

- **Round transitions.** Pausing between rounds doesn't stop the next round from
  *beginning* — its delay is a plain `wait()`. No zombies spawn until you resume.
- **Ground powerups get a fresh timer on resume** rather than their exact remaining time,
  so you'll never lose a Max Ammo to a pause.
- **Zombies stand idle rather than freeze solid.** `zp_freeze_anims` puts them in the
  game's dormant-zombie pose so they don't run on the spot, but it's an idle animation
  rather than a hard freeze. A true animation freeze isn't reachable from server-side GSC,
  and the same applies to player animations.
- **Scripted rides keep running.** Pause inside Ascension's lander and it still lands
  and opens underneath the pause — the guard only stops it releasing your controls
  early. Resuming hands them back normally.
- **Scripted boss sequences** (Brutus spawn-ins, Panzers, ghosts, the Avogadro) are held
  in place, but a scripted move already underway can still finish.
- **Not held:** magic box close timer, teleporter cooldowns, trap durations, and Easter
  egg step timers.

---

## Testing

Tested in live co-op games, including on custom map ports.

It's also compile-checked with **gsc-tool 1.4.10** targeting `t6`/`pc` against the stock
script tree, and round-tripped through compile → decompile. Every external function it
calls exists in the stock T6 script corpus.

---

## Changelog

### v1.1

- **Fixed:** a map script releasing a player's controls mid-pause — Ascension's lander
  landing and opening — let that player roam around a paused game. New
  `zp_control_guard`, on by default, re-applies the freeze every tick.
- **Added:** `zp_blur`, a light screen blur while paused, on by default and adjustable
  with `zp_blur_amount`. Softer than the existing blackout.
- **Added:** separate `zp_pause_sound` and `zp_resume_sound` alongside the countdown
  tick, all three defaulting to fitting stock aliases. `zp_countdown_sound` was silent
  by default before.

### v1.0

- Initial release.

---

## Credits

- **Xep** — author
- **Treyarch** — `_hostmigration.gsc`, the pause recipe this is built on
- **[plutoniummod/t6-scripts](https://github.com/plutoniummod/t6-scripts)** — stock T6 script reference
- **hima_simple** — earliest BO2 zombies pause script
- **[DED2SIN](https://forum.plutonium.pw/topic/46084/i-improved-a-zombies-custom-games-pause-mod)** — Plutonium pause script building on it
- **[MufaDOOM](https://github.com/MufaDOOM/Call-Of-Duty-Black-Ops-2-Zombie-COOP-PAUSE-by-MufaDOOM)** — BO2 co-op pause mod
- **[Resxt](https://github.com/Resxt/Plutonium-T6-Scripts)** — Plutonium T6 chat command conventions
