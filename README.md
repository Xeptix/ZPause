# ZPause

**Synced co-op pause for Black Ops II Zombies (Plutonium T6)**

by Xep

[**Download the latest release**](https://github.com/Xeptix/ZPause/releases/latest)

Any player can pause. Any player can unpause. The state lives on `level`, so it's
identical for everyone — there's no per-client state that can desync.

- Zombies stop where they are, and stop spawning
- Players are locked and can't be hurt
- The match clock, powerup timers, effect countdowns and bleedout all hold
- Resumes on a 3‑2‑1 countdown with a short grace period

---

## Requirements

Plutonium T6 (Black Ops II), zombies. No other mods or dependencies.

**Only the host needs this file.** Every part of ZPause runs on the host and reaches
everyone else as ordinary server-to-client traffic — the freeze, the invulnerability,
the pause HUD, the vote tally, the countdown sounds, the screen blur. Players joining
your game install nothing. They can pause, resume and vote from chat or the button
combo exactly like you can, on a stock client with no scripts and no mods.

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
| Vote yes, while a vote is open | any of the above, or `!yes` / `!y` |
| Vote no, while a vote is open | hold **jump + melee**, or `!no` / `!n` |

The button combo keeps working while you're frozen — `freezecontrols()` blocks movement
and weapon use, but button state still reaches the server. That's what lets a frozen
player resume without opening chat.

Resuming runs a 3‑2‑1 countdown with **everything still frozen**, then releases the whole
game at once and gives players 2 seconds of invulnerability so nobody eats a hit from a
zombie that was mid‑swing.

---

## Voting

Off by default. `zp_vote 1` turns it on and a pause then has to carry the room.

Calling a vote is the same action as pausing — `!pause`, or the crouch + melee combo.
The vote opens for 30 seconds and everyone gets a compact tally at the top of the
screen showing the count, the seconds left, and each player with how they voted.

| Action | Input |
|---|---|
| Call a vote | `!pause` / `!p`, or hold **crouch + melee** |
| Vote yes | the same input again, or `!yes` / `!y` / `yes` / `y` |
| Vote no | hold **jump + melee**, or `!no` / `!n` / `no` / `n` |

The bare `yes` and `no` chat words are only read while a vote is open, so they can't
cast anything in normal conversation. The jump + melee combo is inert the rest of the
time for the same reason — it's watched for those few seconds only, which is what lets
it be a combo you might otherwise brush against in play. Change it with
`zp_vote_no_combo` if it clashes with how you play.

### The threshold

Whichever is higher, `zp_vote_min` or `zp_vote_percent` of the players in the game,
then clamped to the number of players actually present — so a lobby can never set a
bar nobody there can clear. With the defaults (`2` and `51`):

| Players | Yes votes needed |
|---|---|
| 1 | 1 — the vote is skipped, the pause just happens |
| 2 | 2 |
| 3 | 2 |
| 4 | 3 |

`zp_vote_alive_only` — on by default — leaves players who have bled out and are
spectating out of the maths entirely. They show as `spectating` in the tally, and
neither raise the threshold nor cast a counted vote. Without it, two players with one
of them dead means a threshold of two and only one person alive to answer it: a vote
nobody can win. Players in last stand still count — they're alive, and they still care
whether the game stops.

Whoever called the vote counts as a yes (`zp_vote_initiator_yes`). A vote ends the
moment it's decided either way: enough yeses to pass, or enough noes that everyone
remaining couldn't carry it. A failed vote locks out the next one for
`zp_vote_lockout` seconds so it can't be spammed, and a player who disconnects takes
their vote with them — the count is recomputed from whoever is actually in the game.

### Voting while down

Once you're on the floor or spectating, the stance and melee buttons stop reaching the
server, so crouch + melee goes dead the moment you go down. Use, aim and fire keep
coming through — `_killcam.gsc` puts the player in `sessionstate "spectator"` and then
reads `usebuttonpressed()` to skip the killcam, and last stand code reads the same.

Players in either state switch to `zp_button_combo_dead` (**use + aim**) and
`zp_vote_no_combo_dead` (**use + fire**).

**The tally shows each player their own combo.** The hint line is a per-client element
rather than a shared one, so a player in last stand reads `use + aim = yes` while
everyone still on their feet reads `crouch + melee = yes`. The same applies to the pause
banner's `!unpause or ...` line, which updates within a quarter second of a player going
down or being revived.

Spectators are the exception, for an engine reason: a spectating client draws the HUD of
the player it's watching rather than its own, so it reads that player's line — which
correctly says `crouch + melee`, because they're alive. A shared **`while down:`** line
appears under the tally whenever anybody is down to cover it. That one is a server
element, so everyone sees it, spectators included.

Chat works throughout regardless. If your build delivers a different set of buttons,
`zp_input_debug 1` prints each player a live readout of which buttons the server is
receiving from them and which state they're in, so you can pick a pair that works —
`use_frag` and `frag_only` are also available.

Note this is a different question from who counts in the vote: a downed player gets the
fallback combo but stays in the electorate, because they're alive. Only bled-out
spectators drop out, and only with `zp_vote_alive_only`.

### Resuming

Resuming doesn't need a vote by default, so one player going AFK can't strand everyone
in a paused game. Set `zp_vote_unpause 1` if you want both directions voted.

### Freezing during the vote

`zp_vote_hold 1` pauses the game for the duration of the vote and puts it back if the
vote fails, so nobody takes a hit while the room decides. It's off by default because
it lets a single player stop play on their own, which is the thing voting is there to
prevent.

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
| `zp_button_combo_dead` | `use_ads` | Combo used while downed or spectating, when stance and melee stop registering. Also takes `use_attack`, `attack_ads`, `use_frag`, `frag_only`. `""` = chat only. |
| `zp_vote_no_combo_dead` | `use_attack` | The same, for a no vote. |
| `zp_input_debug` | `0` | Print each player which buttons the server receives from them, for picking the two above. |
| `zp_vote` | `0` | Put pauses to a vote. See [Voting](#voting). |
| `zp_vote_min` | `2` | Minimum yes votes, whatever the player count. |
| `zp_vote_percent` | `51` | Percent of players who must vote yes. |
| `zp_vote_time` | `30` | Seconds a vote stays open. |
| `zp_vote_unpause` | `0` | Resuming needs a vote too. |
| `zp_vote_hold` | `0` | Freeze the game while the vote runs, and resume it if the vote fails. |
| `zp_vote_initiator_yes` | `1` | Whoever called the vote counts as a yes. |
| `zp_vote_lockout` | `10` | Seconds before another vote can be called after one fails. |
| `zp_vote_hud` | `1` | Show the vote tally on screen. |
| `zp_vote_show_voters` | `1` | List each player and how they voted. |
| `zp_vote_hud_position` | `top` | Where the vote tally sits. See [Where the HUD sits](#where-the-hud-sits). |
| `zp_vote_alive_only` | `1` | Leave bled-out spectators out of the threshold and the count. |
| `zp_vote_result_time` | `2` | Seconds the result stands on the tally after a vote resolves. `0` = clear at once. |
| `zp_vote_no_combo` | `jump_melee` | Combo for a no vote: `jump_melee`, `crouch_use`, `crouch_frag`, `crouch_ads`, `crouch_melee`. |
| `zp_countdown` | `3` | Seconds of 3‑2‑1 before play resumes. |
| `zp_grace` | `2` | Seconds of invulnerability after resuming. |
| `zp_cooldown` | `2` | Minimum seconds between toggles. |
| `zp_max_pause_time` | `0` | Auto-resume after N seconds. `0` = unlimited. |
| `zp_engine_freeze` | `1` | Use `disablezombies()` / `enablezombies()`. |
| `zp_drift_guard` | `1` | Snap back any AI that still manages to move. |
| `zp_freeze_anims` | `1` | Put zombies in a standing idle pose instead of looping their last animation. |
| `zp_silence_zombies` | `1` | Stop zombies growling while paused. |
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
| `zp_hud_position` | `center` | Where the pause banner sits. See [Where the HUD sits](#where-the-hud-sits). |
| `zp_hud_binds` | `1` | Draw combos as each player's bound buttons instead of words. |
| `zp_hud_glow` | `1` | Black glow behind the HUD text, to carry it over a bright skybox. |
| `zp_hud_panel` | `0` | Black slab behind the whole block. Heavier than the glow. |
| `zp_hud_panel_alpha` | `0.45` | How opaque that slab is. `1` is solid black. |
| `zp_hud_panel_width` | `340` | How wide it is, in HUD units. |
| `zp_hud_timer` | `1` | Show who paused and how long it's been under the banner. |
| `zp_pause_sound` | `zmb_zombie_go_inert` | Played when the game is paused. `""` = silent. |
| `zp_countdown_sound` | `zmb_tombstone_timer_count` | Played on each countdown tick. `""` = silent. |
| `zp_resume_sound` | `zmb_zombie_end_inert` | Played when play resumes. `""` = silent. |

### Where the HUD sits

`zp_hud_position` places the pause banner, `zp_vote_hud_position` places the vote
tally. Both take the same six slots:

| Value | Where |
|---|---|
| `top` | Flush with the top edge, centred. |
| `center` | Centred horizontally, high enough to stay clear of the action — the classic pause banner spot, where the banner has sat since v1.0. |
| `middle` | The actual centre of the screen, over the crosshair. |
| `bottom` | Above the bottom edge, centred. |
| `left` | Against the left edge, text left-aligned. |
| `right` | Against the right edge, text right-aligned. |

The left and right slots align their text to that edge instead of centring it, so a
list of voters reads as a clean column rather than a ragged stack.

Both blocks stack their lines and centre each one in its own right. The pause banner
reads `GAME PAUSED`, the clock, `paused by Xep`, then how to resume; the vote tally reads
the count, the clock, then how to vote. When `zp_max_pause_time` is set the pause clock
counts down to the auto-resume rather than up, which is otherwise the one thing that
happens with no warning. With `zp_hud_timer 0` the clock and the name drop out and the
lines below close up.

The pause banner defaults to `center`, the vote tally to `top`. The two never share the
screen — the vote tally stands in for the pause banner while a vote is open — so you
can put both in the same slot without them colliding.

### Button prompts

`zp_hud_binds`, on by default, draws the combos as the buttons each player actually has
bound rather than as words. The strings carry `[{+bind}]` markers that the client
substitutes when it draws them, so one string renders as a key on a keyboard and as a pad
glyph on a controller — per player, with no detection involved — and it follows rebound
keys for free. Stock T6 does the same thing in `_ai_tank.gsc` and `_rcbomb.gsc`.

Turn it off for plain words like `crouch + melee`. Chat messages are always words; only
the HUD substitutes.

### Readability

`zp_hud_glow` puts a black glow behind every line the script draws, the same treatment
stock notify messages use. Zombies skyboxes are bright and the HUD sits straight on top
of them; without it the grey lines wash out against cloud. Elements also fade in over a
quarter second rather than snapping into place.

`zp_hud_panel 1` is the heavier option: a black slab behind the whole block, sorted under
the text, at `zp_hud_panel_alpha` opacity. It resizes itself as the block grows and
shrinks — a voter joining, the `while down:` line appearing — and it's off by default
because it's a lot of screen for a co-op pause when the glow already does the job on most
maps. Nothing in GSC can measure a rendered string, so if a long line overhangs the slab,
widen it with `zp_hud_panel_width` rather than expecting it to fit itself.

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
- **Zombies go quiet while paused.** A frozen horde standing next to you otherwise
  keeps growling, which is loud and misleading when nothing is happening.
  `do_zombies_playvocals()` returns early for anything flagged `is_inert`, so ZPause sets
  that flag to stop new vocals at the source and calls `stopsounds()` to cut whatever was
  already playing. Only the flag is borrowed, never `start_inert()` — its
  `inert_wakeup()` watcher would un-freeze any zombie a player walked near, the same
  reason `zp_freeze_anims` takes only the pose. A zombie that was genuinely inert before
  the pause keeps the flag on resume. `zp_silence_zombies`.
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

### v1.2

**Vote to pause**

- `zp_vote 1` puts a pause to the room instead of letting any one player stop the game.
  The threshold is whichever is higher, `zp_vote_min` or `zp_vote_percent` of the players
  present, clamped to how many are actually there. Votes are cast from chat or the button
  combos, and the tally shows the count, the clock and every player with how they voted.
  Off by default, so existing installs behave exactly as they did. See [Voting](#voting).
- `zp_vote_hold` freezes the game while the vote runs and puts it back if the vote fails.
  `zp_vote_unpause` extends voting to resuming.
- `zp_vote_alive_only`, on by default, leaves bled-out spectators out of the threshold —
  counting them makes a vote unwinnable exactly when you want one.
- A resolved vote holds `VOTE PASSED 2/2` on the tally for `zp_vote_result_time` rather
  than vanishing into the chat feed, and the countdown turns red in its last five seconds.

**HUD**

- `zp_hud_position` and `zp_vote_hud_position` — `top`, `center`, `middle`, `bottom`,
  `left` or `right`, with the left and right slots aligning their text to that edge. The
  pause banner keeps its old spot; the vote tally defaults to the top.
- `zp_hud_binds`, on by default: combos are drawn as the buttons each player actually has
  bound, so controller players get pad glyphs and rebound keys show correctly.
- `zp_hud_glow` puts a black glow behind the text so it holds up against a bright skybox,
  and elements fade in rather than snapping. `zp_hud_panel` is the heavier slab version,
  off by default, with `zp_hud_panel_alpha` and `zp_hud_panel_width`.
- `zp_hud_timer` shows who paused and how long it's been, counting down to the
  auto-resume instead when `zp_max_pause_time` is set.
- The hint line under both blocks is per-client, so a player who is down is shown the
  combo that works for them rather than everybody else's — plus a shared `while down:`
  line, since a spectating client draws the HUD of the player it's watching and never
  sees its own.

**Zombies**

- `zp_silence_zombies`, on by default: a frozen horde no longer growls at you for the
  length of the pause.

**Fixed**

- Players who were downed or had bled out couldn't use the button combos at all — you
  can't crouch or melee from the floor, and the engine stops delivering those buttons
  once you're spectating. Those states now fall back to `zp_button_combo_dead` and
  `zp_vote_no_combo_dead`, built from buttons that still register.
- A long session could end in `exceeded maximum number of parent server script
  variables`. `_hud_util`'s `setparent()` files every element it creates into
  `level.uiparent.children` and `destroy()` doesn't take it back out — only
  `removechild()` does — so every HUD element ever built left a slot behind. The config
  struct was leaking the same pool by allocating a fresh `spawnstruct()` each pause.

**Changed**

- `zp_vote_time` defaults to 30 seconds.
- The config is re-read when a pause is *requested* rather than only when one starts, so
  turning `zp_vote` on mid-game takes effect without pausing first.
- `zp_input_debug` prints which buttons the server is actually receiving from each player
  and in what state, for picking the fallback combos on a build that differs.

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
