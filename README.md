# ZPause

**Synced co-op pause for Black Ops II Zombies (Plutonium T6)**

by Xep

[![Support the mod on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/F6L1285ROA)
[![Support the mod on Patreon](https://img.shields.io/badge/Patreon-Xeptix-F96854?logo=patreon&logoColor=white)](https://www.patreon.com/Xeptix)
[![Join the Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/RE85HRwYZZ)

[**Download the latest release**](https://github.com/Xeptix/ZPause/releases/latest)

Any player can pause. Any player can unpause. The state lives on `level`, so it's
identical for everyone - there's no per-client state that can desync.

- Zombies stop where they are, and stop spawning
- Players are locked and can't be hurt
- The match clock, powerup timers, effect countdowns and bleedout all hold
- Resumes on a 3-2-1 countdown with a short grace period

---

## Requirements

Plutonium T6 (Black Ops II), zombies. No other mods or dependencies.

**Only the host needs this file.** Every part of ZPause runs on the host and reaches
everyone else as ordinary server-to-client traffic - the freeze, the invulnerability,
the pause HUD, the vote tally, the countdown sounds, the screen blur. Players joining
your game install nothing. They can pause, resume and vote from chat or the button
combo exactly like you can, on a stock client with no scripts and no mods.

---

## Install

Copy the **`Plutonium`** folder from the download into:

```
%localappdata%
```

It mirrors your existing `%localappdata%\Plutonium` exactly, so Windows will ask whether
to merge - say yes. The only thing it replaces is an older `zpause.gsc`.

That puts the file here:

```
%localappdata%\Plutonium\storage\t6\raw\scripts\zm\zpause.gsc
%localappdata%\Plutonium\storage\t6\scripts\zm\zpause.gsc
```

Two copies, because Plutonium moved the script folder under `raw` at some point and which
one your build reads depends on how old it is. Only the one your build looks at is ever
read, so there's nothing to choose.

It also installs the mod packaging of the same file, and the lobby menu that comes with it:

```
%localappdata%\Plutonium\storage\t6\mods\zm_pause\scripts\zm\zpause.gsc
%localappdata%\Plutonium\storage\t6\mods\zm_pause\zpause.iwd
```

That copy does nothing unless you pick **zm_pause** from the in-game Mods menu, so having
it there costs nothing. Use it *or* the script above, not both. The script is usually the
better pick, since Plutonium only enables one mod at a time, so it coexists with whatever
else you're running while the mod version takes the slot; the mod version is the one with
the settings in the lobby and on the game's own pause menu as well - see
[In the lobby](#in-the-lobby) and [In the pause menu](#in-the-pause-menu).

### Or run the installer

The download has an **`installer`** folder, one for each system:

```
installer\windows\install.bat
installer/linux/install.sh
```

That is the ZPause Manager, and it is the same one in every ZPause download: it knows all
five games, finds whichever you have - Plutonium under `%localappdata%`, Steam's folder
and every drive; Black Ops III and Black Ops 4 wherever Steam or you put them - and asks
you to point at a folder only if it can't. Pick a game it has no files for and it offers
to fetch that game's release from GitHub, so a copy kept on your PC can install a game you
buy later.

Run it and it offers to install straight away - pressing Enter is the whole job. Press
`m` instead and you get the menu, which can:

- **install or update** ZPause - it lists what it is about to write, shows the changelog
  for the version you are about to get, and asks once
- show **what's installed**, and which version each copy is
- **configure ZPause** - every setting, grouped the way the script groups them, each with
  its default and a one-line description of what it does. See below.
- **remove** ZPause again
- **check GitHub** for a newer release and download it, with a progress bar
- **install a different version** - every download it makes is kept, so going back to an
  older build is the same two keystrokes as going forward. It can list what GitHub has and
  fetch any of those too.
- **put back a file it replaced** - it copies out whatever it is about to overwrite, so an
  install can be undone even over a script you had edited yourself
- **check my setup** - one key that looks for the handful of things that actually go
  wrong: copies at different versions, a script path your build does not read, files
  something has edited since they were installed, settings that never reached the game
- **keep itself** on your PC with a Desktop or Start-menu shortcut, so you never have to
  go looking for the download again

Nothing in that keep-list is ever deleted behind your back. After a download it shows what
it is holding and offers to clear the older ones out - answering no keeps them all. It
also writes a plain-text log of everything it installs or removes.

### Configuring it from the installer

Every setting is a dvar, and the config editor is a way to set them without touching a
console. It reads the settings out of the script itself, so the list is always right for
the version you have, with the description of each one from the table below.

Saving writes a **`zpause.cfg`** - plain `set zp_vote "1"` lines, which is exactly what a
dedicated server execs, so it is also the file to send someone or reuse on another PC -
and puts the values into the installed script, so they take effect with no console step.
You can pick either or both. Your settings are re-applied automatically after an update, so
a new version never quietly resets them.

Settings that take a fixed set of values offer that list rather than a blank prompt, so a
typo cannot leave you with a combo the game silently ignores. Type a setting's name at any
config screen to jump straight to it. You can keep several **profiles** - a solo one and a
server one, say - and switch between them; each is its own shareable cfg. And when an
update changes a default you had been getting implicitly, it says so before installing.

### Checksums

Every download from v1.4 on carries a **`SHA256SUMS`**, and the installer checks the whole
download against it before touching anything. It is a plain coreutils manifest, so you can
check it yourself in the extracted folder:

```bash
sha256sum -c SHA256SUMS
```

### Without the menu

```
install.bat -Install -Yes        install, asking nothing
install.bat -Uninstall -Yes      remove every copy it can find
install.bat -Find                show what it detects, change nothing
```

`install.sh` takes the same things as `--install --yes`, `--uninstall --yes` and `--find`.

It asks before it touches the network, every run - answer no and it makes no connection
at all. It only ever writes or removes `zpause.gsc`, at paths it found itself: no deletes,
no folders removed, nothing else touched.

Extract the zip first and run it from the extracted folder; running it from inside
Windows' zip viewer won't work.

It's optional. Dragging the `Plutonium` folder across yourself is identical.

**On Linux**, `installer/linux/install.sh` does all of the same things, and knows where
Plutonium ends up when it is running under Wine or Proton - DeckOps' compatdata prefix
on a Steam Deck, Heroic's shared prefix, Lutris, Bottles, plain `~/.wine`, and the Flatpak
version of each. SteamOS SD cards are searched too. Tested against SteamOS, CachyOS and
Bazzite layouts.

```bash
./install.sh          # or  bash install.sh
./install.sh --find   # show what it detects, change nothing
```

### On a Steam Deck

Switch to Desktop Mode and use **`installer/linux/Install ZPause.desktop`** -
double-clicking it runs the installer in a terminal window, which is how most Deck tools
are launched.

KDE will not run a desktop entry until you allow it, once:

1. Right-click `Install ZPause.desktop` → **Properties**
2. **Permissions** → tick **Is executable** → **OK**
3. Double-click it

It finds Plutonium wherever DeckOps put it - the game's own Proton prefix under
`compatdata`, or Heroic's shared prefix on an LCD Deck - including on an SD card. The
manager can put a shortcut in your application menu too, so next time it is one click.



You don't need to restart the game to reload a script - just end the current game and
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

The button combo keeps working while you're frozen - `freezecontrols()` blocks movement
and weapon use, but button state still reaches the server. That's what lets a frozen
player resume without opening chat.

Resuming runs a 3-2-1 countdown with **everything still frozen**, then releases the whole
game at once and gives players 2 seconds of invulnerability so nobody eats a hit from a
zombie that was mid-swing.

### The settings menu

While the game is paused, the host can change ZPause's settings without the console. Hold
**fire + melee** to open the menu:

| Button | Does |
|---|---|
| aim / fire | move up and down the list |
| grenade | change the setting |
| melee | close |

A switch flips, a list moves on to its next choice, and a number steps up through a few
common values and back round to the lowest - exact values are still the console's. A
change lands when play resumes, the same as one typed into the console, and is saved as the
menu closes - see [Where settings are saved](#where-settings-are-saved). The menu closes
itself when a vote opens, since the host needs the buttons back to vote. `zp_menu 0` turns
it off.

#### In the lobby

The mod version has the same settings on a screen of their own. Pick **zm_pause** in the
Mods menu, and the zombies lobby gets a **ZPAUSE SETTINGS** button for the host.

Across the top is a strip of categories - INPUT, VOTING, TIMING, FREEZING, PRESENTATION -
with the shoulder buttons, **Q** and **E**, the arrows either side, or a click on a tab to
move between them. Underneath is the category you are in, the settings themselves in a list
that scrolls, and a panel on the right saying what the setting under the cursor does, what
its dvar is called, what it defaults to, when a change takes, and whose setting it is. Left
and right change a setting. The scrollbar can be dragged with the mouse, and the wheel, the
keyboard and the controller work the way they do everywhere else.

**DEFAULT** leaves a setting to the script's own default - or to the one the installer
wrote, if you configured it there. Along the bottom are **RESET TAB**, which puts the
category you are in back to DEFAULT, **RANDOMIZE**, which picks that category at random and
can land on DEFAULT, and **RESET ALL**, which puts every ZPause setting back. Each of the
three asks first, with **No** already under the cursor.

A change made there is kept in your player config, so it is still set the next time the
game starts, and a match picks it up as it loads. The loose script has no lobby button:
Plutonium loads menus from a mod and nowhere else.

The screen is the one every Z mod draws, so a bundle that carries more than one of them
shows a single **ZBUNDLE SETTINGS** screen with each mod's categories in it, each mod still
keeping its own settings in its own place - and the title over each category names the mod
that owns it. A bundle also gets a **MODS** category, first, which switches each of those
mods on and off; ZPause's row there is `zp_enabled`, and like everything on that page it
lands on the next match. Last, in every build, is **CHANGED**, which lists everything moved
off its default in one place, whichever mod owns it; it is greyed out while there is
nothing to list.

#### In the pause menu

The mod version puts the same screen on Black Ops II's own pause menu, so the settings are
reachable in the middle of a match without pausing first. Open the pause menu and you get a
**ZPAUSE SETTINGS** row above OPTIONS, which opens exactly what the lobby button opens. It
opens over the pause menu, so back returns to the pause menu, not to the lobby.

Every player has the row. ZPause's own settings are the host's - each is one of the host's
dvars - so on anybody else's screen they are locked, and a player who is not the host uses
the screen for whatever is theirs on it, such as another Z mod's personal settings. A change
lands on the next pause - ZPause re-reads its settings whenever a pause is asked for - and is
kept in your player config the same way the lobby's is.

Above that row is **PAUSE GAME** - **UNPAUSE GAME** while the game is paused - which
presses pause exactly as the combo does, so a vote, the host's approval, the cooldown and
`zp_max_pauses` all still have their say. Every player has it, the same as every player has
the combo, and `zp_host_only` takes it off the menu of anybody it would turn away. A player
sees it when their own game is running the mod copy, the one copy with a menu. With
`zp_pause_menu` on it is not there at all: opening the menu has already pressed pause, so
the menu is the button.

Solo is a special case, and the row handles it. Black Ops II stops the game by itself while
the pause menu is open, and a ZPause pause underneath that would be one nothing could lift
- the script is not running to be asked. So the press leaves the game's own pause first:
the menu closes, the game runs, and what lands a moment later is ZPause's pause, with the
countdown, the HUD and the resume. **UNPAUSE GAME** does the same in reverse - the menu
closes and the game carries on.

With `zp_pause_menu` on, opening the pause menu is the pause input; stepping from it into
the settings is not leaving it, so the game stays paused while you're in them.

### Languages

The lobby page and the settings screen in the game's own pause menu follow the language the
game is set to: French, German, Italian, Spanish, Russian, Polish, Brazilian Portuguese,
Japanese, Korean, Czech, and Simplified and Traditional Chinese, with English for any other.
They are the mod copy's, since it is the one with a menu. Dvar names and the values a console or
the chat takes stay as they are in every language.

**The translations are made by AI and may contain mistakes.** If you find one, please report
it to Xep on the [Discord](https://discord.gg/RE85HRwYZZ), with the language and the line as it
reads in the game.

### Pausing just yourself

Set **`zp_personal_pause 1`** and the pause input pauses only you. You're frozen, you can't
be hurt, and the zombies ignore you while everybody else plays on. The same input brings
you back, with the countdown the whole game would get.

The whole game pauses by itself once **nobody is left playing** - everybody else paused
as well, or everybody still in it down. A team that goes down around somebody who stepped
away is held for them rather than lost, bleedout and all. It comes back as soon as one of
the players who paused does; anybody else pressing resume is told it's waiting for them.

- **Not from the floor.** You can't pause yourself while you're down, or it would hold your
  bleedout while the team fought on.
- **Always frozen in place**, even with `zp_freeze_players 0` - walking around a running
  game where nothing can touch you would be a way through a round, not a pause.
- **It's yours alone,** so it never goes to a vote, the host's approval or the ready check,
  and `zp_host_only` doesn't stop it.
- **The limits still apply.** Each personal pause uses one of the match's `zp_max_pauses`,
  and `zp_max_pause_time` brings you back when it runs out.

Off by default.

### The game's own pause menu

Set **`zp_pause_menu own`** and opening Black Ops II's in-game menu pauses the game; closing
it resumes. Nothing to learn and nothing to press - pausing is what that menu looks like it
should do.

Opening it is the pause input and closing it is the resume input, so everything else here
still decides: `zp_host_only`, a vote, the host's approval, the ready check, the cooldown
and `zp_max_pauses`. With **`zp_personal_pause`** on as well, opening the menu takes you out
of the game on your own and closing it brings you back - which is the combination worth
having, since everybody else keeps playing while you're in there.

Closing the menu only resumes a pause your own menu started. A pause somebody else called
is not yours to end by walking out of a menu, and if you leave while it's open the game is
handed back for you.

- **The mod version only.** Plutonium loads menu files from a mod and nowhere else, so the
  loose script cannot see a menu open at all. Pick **zm_pause** in the Mods menu.
- **Each player's own game reports their own menu**, so a player without the mod opening
  theirs pauses nothing.
- **Solo is left alone.** A solo game already pauses itself when that menu opens, so ZPause
  stays out of it and you get no countdown on the way back.

#### The whole room's menus - `zp_pause_menu room`

With `own`, closing your menu only resumes a pause your own menu started, which is why
somebody else's open menu does nothing while the game is already held. **`zp_pause_menu room`**
makes the game follow the room instead: it is paused while *anybody's* pause menu is open,
and it comes back the moment the last one closes. The vanilla pause, working in a co-op game
the way it already works in solo.

For the game to mirror what the clients are doing, everything that can refuse or defer a
press has to stand down, and with `room` it does - no vote, no cooldown, no `zp_max_pauses`, no
`zp_round_pause`, and no countdown on the way back. `zp_personal_pause` stands down too,
since the whole point is that one player's menu pauses for everybody. **`zp_host_only` still
applies**: with it on, only the host's menu moves the game and anybody else opens theirs
without the room noticing.

The pause HUD names everyone who is in a menu rather than whoever got there first, and the
line changes as people come and go.

- **Leaving with your menu open** takes you off the list, and the game comes back if you
  were the last one on it.
- **A close that never arrives cannot strand the game.** An open menu says so twice a second,
  and one that has gone quiet for a few seconds is dropped from the list.
- **Solo is still left alone**, for the same reason as `own`: Black Ops II pauses itself when that
  menu opens, so ZPause stays out of it.
- **The mod version only**, the same as `own`. A player without the mod opening their menu is
  not on the list.

Off by default.

---

## Voting

Off by default. `zp_vote 1` turns it on and a pause then has to carry the room.

Calling a vote is the same action as pausing - `!pause`, or the crouch + melee combo.
The vote opens for 30 seconds and everyone gets a compact tally at the top of the
screen showing the count, the seconds left, and each player with how they voted.

| Action | Input |
|---|---|
| Call a vote | `!pause` / `!p`, or hold **crouch + melee** |
| Vote yes | the same input again, or `!yes` / `!y` / `yes` / `y` |
| Vote no | hold **jump + melee**, or `!no` / `!n` / `no` / `n` |

The bare `yes` and `no` chat words are only read while a vote is open, so they can't
cast anything in normal conversation. The jump + melee combo is inert the rest of the
time for the same reason - it's watched for those few seconds only, which is what lets
it be a combo you might otherwise brush against in play. Change it with
`zp_vote_no_combo` if it clashes with how you play.

### The threshold

Whichever is higher, `zp_vote_min` or `zp_vote_percent` of the players in the game,
then clamped to the number of players actually present - so a lobby can never set a
bar nobody there can clear. With the defaults (`2` and `51`):

| Players | Yes votes needed |
|---|---|
| 1 | 1 - the vote is skipped, the pause just happens |
| 2 | 2 |
| 3 | 2 |
| 4 | 3 |

`zp_vote_alive_only` - on by default - leaves players who have bled out and are
spectating out of the maths entirely. They show as `spectating` in the tally, and
neither raise the threshold nor cast a counted vote. Without it, two players with one
of them dead means a threshold of two and only one person alive to answer it: a vote
nobody can win. Players in last stand still count - they're alive, and they still care
whether the game stops.

Whoever called the vote counts as a yes (`zp_vote_initiator_yes`). A vote ends the
moment it's decided either way: enough yeses to pass, or enough noes that everyone
remaining couldn't carry it. A failed vote locks out the next one for
`zp_vote_lockout` seconds so it can't be spammed, and a player who disconnects takes
their vote with them - the count is recomputed from whoever is actually in the game.

### Voting while down

Once you're on the floor or spectating, the stance and melee buttons stop reaching the
server, so crouch + melee goes dead the moment you go down. Use, aim and fire keep
coming through - `_killcam.gsc` puts the player in `sessionstate "spectator"` and then
reads `usebuttonpressed()` to skip the killcam, and last stand code reads the same.

Players in either state switch to `zp_button_combo_dead` (**use + aim**) and
`zp_vote_no_combo_dead` (**use + fire**).

**The tally shows each player their own combo.** The hint line is a per-client element
rather than a shared one, so a player in last stand reads `use + aim = yes` while
everyone still on their feet reads `crouch + melee = yes`. The same applies to the pause
banner's `!unpause or ...` line, which updates within a quarter second of a player going
down or being revived.

Spectators are the exception, for an engine reason: a spectating client draws the HUD of
the player it's watching rather than its own, so it reads that player's line - which
correctly says `crouch + melee`, because they're alive. A shared **`while down:`** line
appears under the tally whenever anybody is down to cover it. That one is a server
element, so everyone sees it, spectators included.

Chat works throughout regardless. If your build delivers a different set of buttons,
`zp_input_debug 1` prints each player a live readout of which buttons the server is
receiving from them and which state they're in, so you can pick a pair that works -
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

### Who decides

Five settings answer the same question - who may pause, and who has to agree. They can all
be on at once, so this is the order the script applies them in.

**Asking to pause:**

| | Setting | What happens |
|---|---|---|
| 1 | `zp_host_only` | Anybody but the host is turned away here. Nothing below runs for them. |
| 2 | - | Refused while the game is still starting. |
| 3 | `zp_round_pause` | If a pause is already waiting for the round to end, asking again calls it off. |
| 4 | `zp_max_pauses` | Refused once the match has spent its budget. |
| 5 | `zp_cooldown` | Refused if the last pause was too recent. |
| 6 | `zp_host_approve` | A non-host's ask goes to the host to answer. **Takes precedence over `zp_vote`.** |
| 7 | `zp_vote` | Otherwise, with voting on, it goes to a vote. |
| 8 | `zp_round_pause` | Once it is agreed - outright, approved or voted - it waits for the round to end instead of happening now. |

**Asking to resume:**

| | Setting | What happens |
|---|---|---|
| 1 | `zp_host_only` | Anybody but the host is turned away. |
| 2 | - | With a vote already open, the input is a yes instead. |
| 3 | `zp_cooldown` | Refused if the last toggle was too recent. |
| 4 | `zp_ready_check` | The input marks you ready rather than resuming. **Takes precedence over `zp_vote_unpause`.** |
| 5 | `zp_vote_unpause` | Otherwise, with `zp_vote` on as well, it goes to a vote. |

Three things sit outside all of that:

- **`zp_max_pause_time` ends a pause whatever else is set.** It is the way out of a ready
  check nobody answers, or a request the host never sees. Leave it at `0` and there is no
  way out but somebody pressing something.
- **A pause nobody asked for skips the lot.** `zp_pause_on_disconnect` pauses immediately:
  it does not wait for the round, does not spend the budget, and asks nobody.
- **`zp_host_only` with `zp_host_approve` is just `zp_host_only`.** The first turns the
  request away before there is anything left to approve.

## Configuration

Every setting is at the top of the file under `zp_load_config()`, and each one is also a
dvar of the same name. The script creates each dvar with its default on load, so you can
set them straight from the console:

```bash
zp_countdown 5
```

The config is re-read every five seconds while the game is running, and again at the
start of every pause, so a change takes effect **almost straight away** - no map restart
needed. Anything already set in your `config.cfg` before the map loads is left alone.

The periodic re-read is skipped while the game is paused: the HUD is built from these
settings when the pause starts and nothing rebuilds it in place, so moving them underneath
would leave elements where the old values put them. A change made mid-pause lands the
moment play resumes. It also means `zp_combo` can be changed by hand - before, that needed
a pause to take effect, and the combo is what asks for one.

`set zp_config_print 1` in the console prints every setting below with the value it is
currently holding, then puts the switch back so it can be used again.

### Where settings are saved

Whatever you change in the pause menu is written to a file as you close the menu, and read
back the next time a match loads:

```
Plutonium\storage\t6\raw\scriptdata\zpause.cfg
```

The installer's config editor writes that same file, in the same format, so it does not
matter where you set something - the menu, the installer, a text editor, or `exec` on a
dedicated server. Both installed copies of the script read the one file, so the loose
script and the mod copy cannot drift apart. Only settings that differ from their default
are listed, which is what keeps a default that changes in a later version applying to
everything you never touched.

The file supplies the **default** for each setting, so anything already set outranks it:
the console for as long as the game is running, and the lobby menu for good, since what it
saves is a `seta` that Plutonium restores at launch. Set the same thing in both places and
the lobby wins.

| Dvar | Default | What it does |
|---|---|---|
| `zp_enabled` | `1` | ZPause itself. Off, the script loads and does nothing at all - no pause, no HUD, no chat commands, no combos, nothing precached. **Read when the match loads**, so end the game and start a new one for a change to take. |
| `zp_host_only` | `0` | Only the host can pause or resume. Everyone else's chat command and combo are ignored, and a pause never goes to a vote. On a dedicated server there is no host, so it falls to whoever holds the first player slot. |
| `zp_personal_pause` | `0` | The pause input pauses only you, and the game carries on for everyone else; it pauses in full once nobody is left playing. See [Pausing just yourself](#pausing-just-yourself). |
| `zp_pause_menu` | `off` | Opening the game's own pause menu pauses, and closing it resumes. `own` follows your own menu, `room` the whole room's, `off` neither. **Mod version only.** See [The game's own pause menu](#the-games-own-pause-menu). |
| `zp_menu` | `1` | Let the host change settings from a menu while the game is paused: hold fire and melee to open it. |
| `zp_only_script` | `0` | Debug. With both the loose script and the mod-folder copy installed, run only the loose one. |
| `zp_only_mod` | `0` | Debug. The same, the other way round. Both off - the default - is whichever loads first. Both on leaves nothing running. **Read when the script loads**, so end the game and start a new one for a change to take. |
| `zp_allow_short_words` | `0` | Also accept bare `p` / `u` / `pause` in chat. Off by default so normal conversation can't pause the game. |
| `zp_button_combo` | `1` | Enable the button combos. |
| `zp_combo` | `crouch_melee` | Which combo pauses: `crouch_melee`, `crouch_use`, `crouch_frag`, `crouch_ads`, `jump_melee`, `use_frag`, `frag_only`, `use_ads`, `use_attack`, `attack_ads`. |
| `zp_button_hold_time` | `0.3` | How long the combo must be held. |
| `zp_button_combo_dead` | `use_ads` | Combo used while downed or spectating, when stance and melee stop registering. Also takes `use_attack`, `attack_ads`, `use_frag`, `frag_only`. `none` = chat only. |
| `zp_vote_no_combo_dead` | `use_attack` | The same, for a no vote. |
| `zp_input_debug` | `0` | Print each player which buttons the server receives from them, for picking the two above. |
| `zp_host_approve` | `0` | The host pauses at once; anyone else has to ask and the host answers yes or no. It runs as a vote only the host can cast, so the yes/no input, the HUD and the timeout are a vote's. Pausing only - resuming still follows `zp_vote`. `zp_host_only` wins where both are set. |
| `zp_ready_check` | `0` | Resuming waits for the players to say they're back. Not a vote - nobody says no and it can't fail, so it needs no `zp_vote`, and it wins over `zp_vote_unpause` where both are set. |
| `zp_ready_percent` | `100` | How much of the room has to be ready. `100` is everybody. |
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
| `zp_ease` | `1` | Ease time down into the pause and back out, instead of cutting to a stop. |
| `zp_ease_time` | `0.35` | Seconds of ramp at each end. |
| `zp_countdown` | `3` | Seconds of 3-2-1 before play resumes. |
| `zp_grace` | `2` | Seconds of invulnerability after resuming. |
| `zp_max_pauses` | `0` | How many times one match can be paused. `0` is no cap. Only a pause somebody asked for spends one - an automatic pause does not. |
| `zp_pause_on_disconnect` | `0` | Pause when somebody drops, so whoever is left isn't overrun while they rejoin. Nothing un-pauses on its own, so `zp_max_pause_time` is the way out if they don't come back. |
| `zp_round_pause` | `0` | Hold a pause until the round is over instead of freezing the game mid-horde. Asking again calls it off. |
| `zp_cooldown` | `2` | Minimum seconds between toggles. |
| `zp_max_pause_time` | `0` | Auto-resume after N seconds. `0` = unlimited. |
| `zp_engine_freeze` | `1` | Use `disablezombies()` / `enablezombies()`. |
| `zp_drift_guard` | `1` | Snap back any AI that still manages to move. |
| `zp_freeze_anims` | `1` | Put zombies in a standing idle pose instead of looping their last animation. |
| `zp_silence_zombies` | `1` | Stop zombies growling while paused. |
| `zp_godmode` | `1` | Make players invulnerable while paused. |
| `zp_freeze_players` | `1` | Lock players in place while paused. `0` lets them walk around with their weapons down, locked again for the countdown - not recommended, because doors, the box, perks, traps and pickups can all still be used while the zombies are held. |
| `zp_control_guard` | `1` | Re-apply the player freeze every tick, so a map script can't hand controls back mid-pause. |
| `zp_freeze_clock` | `1` | Hold the match timer. |
| `zp_freeze_powerups` | `1` | Stop ground powerups timing out. |
| `zp_freeze_effects` | `1` | Hold insta-kill / double-points countdowns. |
| `zp_freeze_bleedout` | `1` | Stop downed players bleeding out. |
| `zp_blackout` | `1` | Dim everyone's screen while paused, which keeps the pause text readable over a bright skybox. Raise `zp_blackout_alpha` for the anti-scouting blackout this used to be. |
| `zp_blackout_alpha` | `0.2` | How far it dims. `0.2` is a light darkening; `1` is fully black. |
| `zp_blur` | `1` | Blur everyone's screen while paused. Clears when play resumes. |
| `zp_blur_amount` | `2` | Blur strength. `4` is the blur the game runs when you buy a perk. |
| `zp_show_hint` | `1` | Tell players how to pause when they spawn. |
| `zp_hud` | `1` | Draw the pause block at all. The vote HUD is separate and still draws. |
| `zp_hud_position` | `center` | Where the pause banner sits. See [Where the HUD sits](#where-the-hud-sits). |
| `zp_hud_binds` | `1` | Draw combos as each player's bound buttons instead of words. |
| `zp_hud_glow` | `1` | Black glow behind the HUD text, to carry it over a bright skybox. |
| `zp_hud_panel` | `0` | Black slab behind the whole block. Heavier than the glow. |
| `zp_hud_panel_alpha` | `0.45` | How opaque that slab is. `1` is solid black. |
| `zp_hud_panel_width` | `340` | How wide it is, in HUD units. |
| `zp_hud_timer` | `1` | Show who paused and how long it's been under the banner. |
| `zp_pause_sound` | `zmb_zombie_go_inert` | Played when the game is paused. Also takes `evt_nuked`, `zmb_box_poof`, `zmb_perks_power_on` and `evt_electrical_surge`. `none` = silent. |
| `zp_countdown_sound` | `fly_equipment_pickup_plr` | Played on each countdown tick. Also takes `zmb_points_loop_off` and `zmb_cha_ching`. `none` = silent. |
| `zp_resume_sound` | `zmb_zombie_end_inert` | Played when play resumes. Also takes `zmb_powerup_grabbed`, `zmb_perks_packa_ready`, `zmb_cha_ching` and `evt_player_upgrade`. `none` = silent. |

### Where the HUD sits

`zp_hud_position` places the pause banner, `zp_vote_hud_position` places the vote
tally. Both take the same six slots:

| Value | Where |
|---|---|
| `top` | Flush with the top edge, centred. |
| `center` | Centred horizontally, high enough to stay clear of the action - the classic pause banner spot, where the banner has sat since v1.0. |
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
screen - the vote tally stands in for the pause banner while a vote is open - so you
can put both in the same slot without them colliding.

### Button prompts

`zp_hud_binds`, on by default, draws the combos as the buttons each player actually has
bound rather than as words. The strings carry `[{+bind}]` markers that the client
substitutes when it draws them, so one string renders as a key on a keyboard and as a pad
glyph on a controller - per player, with no detection involved - and it follows rebound
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
shrinks - a voter joining, the `while down:` line appearing - and it's off by default
because it's a lot of screen for a co-op pause when the glow already does the job on most
maps. Nothing in GSC can measure a rendered string, so if a long line overhangs the slab,
widen it with `zp_hud_panel_width` rather than expecting it to fit itself.

### Sounds

All three are stock aliases, so both packagings stay a single drop-in file. A custom
sound would have to ship as a fastfile and be installed by **every player** rather than
just the host, so ZPause uses the game's own audio instead.

The defaults are what the game itself uses them for: a zombie plays `go_inert` and
`end_inert` when it drops dormant and wakes back up, and the countdown tick is the sound
of picking equipment up. Other aliases worth trying, each one in the sound files of every
map - TranZit and the maps that share its sounds, Nuketown, Die Rise, Mob of the Dead,
Buried, Origins and the Diner:

| Alias | What it is |
|---|---|
| `zmb_cha_ching` | Points. |
| `zmb_box_poof` | The magic box vanishing. |
| `zmb_whoosh` | Short whoosh. |
| `zmb_powerup_grabbed` | Picking up a power-up. |
| `zmb_points_loop_off` | Double Points running out. |
| `evt_nuked` | The Nuke going off. |

A map only plays a sound its own files carry, and one they don't carry plays nothing at
all. `zmb_perks_power_on` (the power switch) and `evt_perk_deny` (a buzzer) are in every
map's files but the Diner's.

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

- **`disablezombies()` / `enablezombies()`** are engine builtins - the same calls host
  migration uses.
- **`flag_clear("spawn_zombies")`** is the flag `_zm.gsc`'s spawn loop actually blocks on,
  so spawning stops at the source instead of being fought.
- **`level.discardtime`** is subtracted from the match clock, so pushing it forward by the
  elapsed time holds the timer still.

On top of that, ZPause covers what host migration never has to because it only lasts a few
seconds:

- **An AI enforcer** that re-freezes anything appearing mid-pause, keeps `ignoreall`
  pinned, and snaps back any AI that drifts. It's a safety net - if the engine freeze does
  its job it never fires, so there's no jitter. It pins each zombie's goal where it stands,
  except a zombie still on its way in through a window: that walk waits to arrive at its
  own goal, and a goal at its feet would read as arrival.
- **A player enforcer.** Map scripts that carry a player somewhere lock the controls for
  the ride and call `freezecontrols( 0 )` when it ends - Ascension's lander is the one
  that bites. That release lands mid-pause and hands one player free movement around a
  frozen game. `freezecontrols()` has no getter, so the guard re-asserts the freeze on a
  tick rather than testing it, and re-pins godmode and `ignoreme` while it's there.
- **The stuck-zombie watchdog.** `round_spawn_failsafe()` kills any zombie that hasn't
  moved 24 units in 30 seconds (15 on Origins and Mob of the Dead), assuming it's stuck
  outside the playspace. A paused zombie trips it every time, and the "put it back in the
  spawn queue" compensation is skipped for anything with `ignoreall` set - so those
  zombies are gone for good, counted as killed, and the round advances while everyone's
  away. ZPause keeps the barrier-chunk timestamp fresh, which all three variants honour,
  so the watchdog loops harmlessly instead of firing and still works normally afterwards.
- **Ground powerups.** `powerup_timeout()` is a plain `wait()` and can't be paused, so the
  thread is cut and restarted on resume.
- **Insta-kill / double points.** Their HUD countdowns are held still. The 30s `wait()`
  driving the real effect keeps running underneath, so on resume a bounded thread holds
  the effect on until the frozen countdown genuinely runs out, then forces it off -
  without that, the effect would stick on for the rest of the game.
- **Bleedout** is pinned so a downed player doesn't bleed out.
- **Late joiners and respawns** are frozen on spawn, and everything is torn down on
  `end_game` so nobody is left frozen at the scoreboard.

### Why not `timescale`?

`timescale 0` looks like the perfect pause - it would freeze everything, timers included.
But GSC `wait` runs on server time, so the unpause loop freezes with it and the game can
never be resumed. The server also only runs a frame once enough scaled time accumulates,
so snapshots stop going out and clients drop with *Connection Interrupted*. Slow motion
(`timescale 0.05`) avoids the disconnects but isn't a pause.

---

## Notes

- **Round transitions.** Pausing between rounds doesn't stop the next round from
  *beginning* - its delay is a plain `wait()`. No zombies spawn until you resume.
- **Ground powerups get a fresh timer on resume** rather than their exact remaining time,
  so you'll never lose a Max Ammo to a pause.
- **Zombies go quiet while paused.** A frozen horde standing next to you otherwise
  keeps growling, which is loud and misleading when nothing is happening.
  `do_zombies_playvocals()` returns early for anything flagged `is_inert`, so ZPause sets
  that flag to stop new vocals at the source and calls `stopsounds()` to cut whatever was
  already playing. Only the flag is borrowed, never `start_inert()` - its
  `inert_wakeup()` watcher would un-freeze any zombie a player walked near, the same
  reason `zp_freeze_anims` takes only the pose. A zombie that was genuinely inert before
  the pause keeps the flag on resume. `zp_silence_zombies`.
- **Zombies stand idle rather than freeze solid.** `zp_freeze_anims` puts them in the
  game's dormant-zombie pose so they don't run on the spot, but it's an idle animation
  rather than a hard freeze. A true animation freeze isn't reachable from server-side GSC,
  and the same applies to player animations.
- **Scripted rides keep running.** Pause inside Ascension's lander and it still lands
  and opens underneath the pause - the guard only stops it releasing your controls
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

## Ports

| Game | Repo |
|---|---|
| Black Ops 4 (T8) | [ZPauseT8](https://github.com/Xeptix/ZPauseT8) |
| Black Ops III (T7) | [ZPauseT7](https://github.com/Xeptix/ZPauseT7) |
| Black Ops II (T6) | ZPause - you are here |
| Black Ops (T5) | [ZPauseT5](https://github.com/Xeptix/ZPauseT5) |
| World at War (T4) | [ZPauseT4](https://github.com/Xeptix/ZPauseT4) |

Versions are kept in step: the same version number means the same feature set, allowing
for what each engine can actually do. Both older ports do the AI freeze entirely in
script, since `disablezombies()` is a Black Ops II builtin.

**All five in one download.** The
[Treyarch Bundle](https://github.com/Xeptix/ZPause/releases/latest) carries every game
ZPause runs on, laid out as each drops in - the `Plutonium` tree for this game and the
other two, Black Ops III's loader folders, Black Ops 4's mod folder - with one installer
that knows all five. By hand, drop its `Plutonium` folder into `%localappdata%\Plutonium`,
say yes to the merge, and delete the game folders you don't have.

---

## Changelog

### v1.8

- **No change on this port.** 1.8 fixes the Black Ops III settings screen's category strip; Black
  Ops II's already stays in place. The version moves with the others so the same number means the
  same release everywhere.

### v1.7

- **PAUSE GAME is every player's.** The row in the game's own pause menu was the host's
  alone; every player has it now, and a press from anybody goes through exactly what the combo
  does - `zp_host_only`, the vote, the host's approval and a personal pause all still decide.
  With `zp_host_only` on, the row is not on the menu of a player it would turn away. An action
  another Z mod adds for each player's own game, such as ZStats' HUD toggle, is on every
  player's menu as well; one that acts on the whole match stays the host's.

- **The settings menu speaks twelve languages.** The lobby page and the settings screen in the
  game's own pause menu follow the language the game is set to: French, German, Italian, Spanish, Russian, Polish, Brazilian Portuguese, Japanese, Korean, Czech, and Simplified and Traditional Chinese, with
  English for any other. Every setting's name, its choices, its description and the reason a
  greyed-out row gives are translated, and so is the page around them - the tabs, the buttons,
  the confirmations and the details panel. What you type stays as it is: dvar names, and the
  values a console or the chat takes. The translations are made by AI and may contain
  mistakes; please report any to Xep on the Discord. The mod copy only, since it is the one
  with a menu.

- **In a bundle, every mod's settings read in that mod's own words.** ZBundle draws all of its
  mods' categories on one screen, and each row is now translated by the mod it belongs to, so a
  ZShare setting reads in ZShare's translation on ZPause's screen. **CHANGED** reads in the
  same language too, with each row's mod still named in front of it.

- **The settings screen keeps your place.** After you change a setting the cursor stays on
  that row, and the list stays where it was scrolled, instead of jumping back to the top of the
  category.

- **A choice that happens to be the default stays picked.** Stepping onto a value that is also
  the setting's default - another mod's RANDOM, say - no longer snaps back to DEFAULT the moment
  you land on it. Reopening the screen or resetting shows DEFAULT again.

- **Confirmations fit.** The text of RESET TAB, RANDOMIZE and RESET ALL wraps inside its box,
  which the longer translations needed.

- **A pause asked for from the pause menu is asked for once.** The host's PAUSE GAME row
  reaches the game two ways, and both used to be served: with `zp_round_pause` on, the second
  called off the round-end pause the first had just set up, and with `zp_personal_pause` on it
  brought the host straight back. With `zp_host_only` and `zp_personal_pause` both on, a
  player's PAUSE GAME row now shows exactly when their combo would pause them.

### v1.6

- **`zp_enabled` - the mod's own switch, and two new categories with it.** On by default.
  Off, ZPause loads and installs nothing at all: no pause, no HUD, no chat commands, no
  combos, nothing precached. It is read as a match loads, so a change lands on the next one
  rather than the one being played. The settings screen gained the two categories that go
  with it: **MODS**, which switches each mod on the screen on and off and is only there when
  there is more than one of them, and **CHANGED**, which lists everything anybody has moved
  off its default. The game's own pause menu gained a **PAUSE GAME** row for the host -
  **UNPAUSE GAME** while the game is paused - and the title above each category now names
  the mod that owns it.

- **Xep's other mods can ask ZPause to pause.** ZPause puts itself on `level.zmods` as the
  match starts, with its version and the few things another mod may ask it to do: reload the
  settings, pause, resume, toggle, and say whether the game is paused. A pause asked for that
  way goes in at the same door a chat command or a combo does, so voting, the host's
  approval, the cooldown and `zp_max_pauses` all still have their say.

- **The settings screen is the shared Z-mods one now.** One screen instead of a page per
  section: a strip of categories across the top with the shoulder buttons, Q/E, arrows and
  the mouse to move between them, the settings in a list that scrolls and a scrollbar the
  mouse can drag, and a panel on the right saying what the setting under the cursor does,
  what it defaults to, when a change takes and whose setting it is. Along the bottom are
  RESET TAB, RANDOMIZE and RESET ALL, each asking first. The lobby button and the pause-menu
  row open the same screen, and a bundle carrying another Z mod shows that mod's categories
  in it too. See [In the lobby](#in-the-lobby).

- **The settings are on the game's own pause menu now, in the mod version.** The host gets
  a **ZPAUSE SETTINGS** row above OPTIONS, opening the same screen the lobby button opens -
  so a setting can be changed in the middle of a match without dropping to the console, and
  it lands on the next pause. See [In the pause menu](#in-the-pause-menu).

- **`zp_personal_pause` - pause just yourself.** Off by default. With it on, the pause
  input takes only you out of the game: frozen, protected and ignored by the zombies while
  everybody else plays on. The whole game pauses once nobody is left playing, and comes back
  with the first player who paused. See [Pausing just yourself](#pausing-just-yourself).

- **`zp_pause_menu` - the game's own pause menu pauses the game.** Off by default, and the
  mod version only, since Plutonium loads menu files from a mod and nowhere else. Opening
  it is the pause input and closing it is the resume input, so votes, approval and the rest
  still apply; with `zp_personal_pause` on it takes you out on your own. See
  [The game's own pause menu](#the-games-own-pause-menu).

- **Numbers and switches you change in the pause menu now stick.** Only the nine text
  settings - the combos, the two HUD slots and the three sounds - were being read from
  `scriptdata\zpause.cfg` and written back to it. Everything else went straight to its
  dvar, so a number set in the menu was gone by the next match, a number in the file did
  nothing, and closing the menu rewrote the file without it. All sixty-four go through
  the file now, as they already did on the other ports.

- **The ready check can no longer strand a paused game.** With `zp_ready_check` on, the
  tally was only ever recounted when somebody pressed ready, so if the last player who
  had not pressed dropped out, the pause could not be ended by anyone left - they had all
  pressed it already. A player leaving now recounts.

- **A pause that has already ended is not ended twice.** With `zp_max_pause_time` set, the
  automatic resume could fire while a resume vote was open; the vote then passed into a
  running game and played the whole resume again - the chat line, the countdown with
  everybody held still, and the slow-motion ramp back. The resume now leaves a running
  game alone, and closes an open vote on its way out.

- **A vote nobody carried no longer costs a pause.** With `zp_vote_hold`, the game is held
  while the vote runs, and that hold was counted against `zp_max_pauses` even when the
  vote failed. Three votes voted down used up a match's three pauses.

- **The pause banner no longer sits on top of the vote.** With `zp_vote_hold`, the banner
  came back the moment the held pause began, over the vote tally, telling everybody to
  press the combo that was actually a yes vote.

- **`zp_round_pause` is respected by a vote.** With `zp_vote_hold` on as well, a passing
  vote froze the game where it stood instead of waiting for the round to end.

- **A pause waiting for the round to end can only be called off by whoever asked for it,
  or the host.** It sits ahead of the vote and approval checks, so any player could
  quietly cancel what the room had just voted for.

- **Two-letter words no longer vote.** Chat is also read with its first character dropped,
  because some clients put one in front; that turned "my" and "by" into a yes and "on",
  "in", "an" and "un" into a no while a vote was open. The character is only dropped now
  when it is not a letter or a digit.

- **A power-up picked up just after a resume keeps its full time.** The pause hands back
  the insta-kill or double points time it froze, and when that ran out it switched the
  effect off - including one the player had picked up in the meantime.

- **`zp_vote_hud_position` can be set to `center`**, in the lobby, the pause menu and the
  installer's editor. The README always said it took the same six slots as
  `zp_hud_position`; only the console could set that one.

- **The lobby menu offers every value again.** A setting's own default was left out of its
  list, so once the installer's config editor had changed a default, the value it used to
  be could not be picked there any more - configure `zp_vote` on and the lobby could no
  longer turn it off.

### v1.5

- **Settings you change in the pause menu now stick.** They go into
  `scriptdata\zpause.cfg` as the menu closes and are read back as the next match loads -
  the same file the installer's config editor writes, so the menu, the installer, the
  console and the file are all one set of settings. See
  [Where settings are saved](#where-settings-are-saved).

- **A zombie on its way in through a window carries on from where it was when the pause
  ends.** The pause holds zombies with the engine freeze and, behind it, pins each one's
  goal to where it stands. A zombie walking to a window is waiting to arrive at a goal of
  its own, and the board tear that follows is played against the window itself - so a
  goal at its feet reads as arrival, and one on its last steps in was put onto the window.
  While the engine freeze holds it, a zombie that isn't through its window yet keeps the
  goal the game gave it, which is how the game's own host-migration freeze holds it.

- **`zp_freeze_players`** - set it to `0` and players can walk around a paused game with
  their weapons down, and are locked again for the countdown back in. Players are still
  locked by default, and roaming isn't recommended: doors, the box, perks, traps and
  pickups can all still be used while the zombies are held.

- **A settings menu for the host.** While the game is paused, hold **fire + melee** to
  change ZPause's settings without the console: aim and fire move through the list,
  grenade changes the setting, melee closes it. See
  [The settings menu](#the-settings-menu); `zp_menu` turns it off.

- **`none` empties a setting from the console.** `set zp_pause_sound ""` was put back to
  its default the next time the config was read, so a silent sound or a downed combo left
  on chat alone only ever worked from the installer. `none` does it from the console, a
  config file or the settings menu.

- **Changing `zp_engine_freeze` or `zp_godmode` during a pause** no longer leaves the
  zombies frozen or the players invulnerable once it ends. Resuming undoes what the pause
  did, rather than what the setting says by then.

- **A settings menu in the lobby, in the mod version.** Pick **zm_pause** in the Mods menu
  and the host gets a **ZPAUSE SETTINGS** button in the zombies lobby: every setting, a
  page for each part, with what it does and its default beside it, and a reset. A change
  there is kept in your player config, so it lasts until you change it back. See
  [In the lobby](#in-the-lobby).

- **More sounds to pick from.** `zp_pause_sound`, `zp_countdown_sound` and
  `zp_resume_sound` each offer a few of the game's own zombies sounds as well as their
  default and `none` - in the lobby, the pause menu and the installer alike.

- **The countdown ticks on every map.** Its sound was `zmb_tombstone_timer_count`, which
  only TranZit's and Nuketown's sound files carry, so the countdown was silent on Die
  Rise, Mob of the Dead, Buried, Origins and in the Diner. It is now
  `fly_equipment_pickup_plr`, the equipment pick-up sound, which every map has.

- **The installer puts the right copy in each place.** Installing from a download put the
  mod-folder copy in the two script paths as well, so the loose script called itself the
  mod one and `zp_only_script` and `zp_only_mod` could not tell the copies apart.

- **The installer's `-To` works when it already remembers a folder.** It was only read when
  the installer had to ask where the game is, so once it remembered one, `-To` was ignored.
  It comes first now, for that run, and a `-To` that is not the game's folder says so. On
  Linux, the question itself now shows when more than one Plutonium folder is found, or none.

### v1.4

- **`zp_combo`** - which combo pauses. There are ten, and the script already understood
  every one of them; only `crouch_melee` could be reached. The rest are `crouch_use`,
  `crouch_frag`, `crouch_ads`, `jump_melee`, `use_frag`, `frag_only`, `use_ads`,
  `use_attack` and `attack_ads`. Still `crouch_melee` by default, so nothing moves unless
  you move it.

- **`zp_hud`** - draw the pause block at all. Off leaves the pause itself working with
  nothing on screen, which is what a recording or a server drawing its own overlay wants.
  The vote HUD is separate and still draws. On by default.

- **`zp_blackout` is on by default now**, at the new **`zp_blackout_alpha`** of `0.2`. It
  was off in v1.3, so this is the one change you will notice without going looking: while
  paused, the screen dims slightly. That is deliberate - it carries the pause text over a
  bright skybox, which matters more now that every port shares one readability setting.
  `zp_blackout 0` puts it back, and `zp_blackout_alpha 1` gives the full anti-scouting
  blackout it used to be at when it was switched on by hand.

- **`zp_blur_amount` moved from `1.5` to `2`** for the same reason. Both defaults are
  reported by the installer when you update, if you had been leaving them alone.

- **`zp_only_script`** and **`zp_only_mod`** - with both the loose script and the
  mod-folder copy installed, both load and the first one there wins. These pick the winner,
  for testing one against the other. Read when the script loads, so a change takes on the
  next game rather than the current one. Off by default.

- **`zp_round_pause`** - hold a pause until the round is over rather than freezing the game
  mid-horde. Asking again calls it off. Off by default.
- **`zp_ready_check`** and **`zp_ready_percent`** - resuming waits for the players to say
  they are back, all of them by default. Not a vote: nobody says no, and it cannot fail.
  Off by default.

- **`zp_max_pauses`** - a cap on how many times one match can be paused, for a server where
  that would otherwise become an argument. Off by default.
- **`zp_pause_on_disconnect`** - pause when somebody drops, so whoever is left isn't overrun
  while they rejoin. Off by default.

- **`zp_host_approve`** - the host pauses at once; anyone else has to ask, and the host
  answers yes or no. It runs as a vote with an electorate of one, so it uses the same
  yes/no input and the same clock, and works where there is no chat. Pausing only, so
  nobody is stranded if the host walks away. Off by default.

- **`zp_config_print`** - `set zp_config_print 1` in the console prints every setting and
  the value it currently holds.

- **`zp_host_only`** - only the host can pause or resume. Everyone else's chat command and
  combo are ignored, and a pause never goes to a vote, since there is nobody left to ask.
  Off by default.

- **`zp_ease`** - time ramps down as the pause takes hold and back up as it lifts, instead
  of cutting to a stop. `zp_ease_time` sets the ramp; `zp_ease 0` restores the hard cut.
  It is not the timescale trap described below: the scale never reaches zero, and time is
  put back to normal the moment the world is held, so the server only runs slowed for the
  length of the ramp.
- **A Black Ops III port** - [ZPauseT7](https://github.com/Xeptix/ZPauseT7) - and a
  **Black Ops 4 port**, [ZPauseT8](https://github.com/Xeptix/ZPauseT8). Both are new in
  1.4, which makes this the first release to cover all five Treyarch zombies games.

- **The config editor.** Every setting is a dvar, and the installer now sets them without
  a console - it reads the list out of the installed script, so it is always right for the
  version you have, with each setting's description from the README table. Settings that
  take a fixed set of values offer that list rather than a blank prompt. You can keep
  several **profiles** and switch between them, and each one exports as a portable
  `zpause.cfg` of `set` lines, which is what a dedicated server execs and what you send
  somebody. Your settings are re-applied after an update, so a new version never quietly
  resets them.

- **Settings take effect without a map restart.** The config is re-read every five seconds
  while the game runs, and again whenever a pause is requested. The periodic re-read is
  skipped while paused, since the HUD is built when the pause starts and nothing rebuilds
  it in place - a change made mid-pause lands the moment play resumes.

- **The installer is now a manager.** It shows what is installed and which version each
  copy is, removes them again, checks GitHub for a newer release and downloads it with a
  progress bar, and can keep itself on your PC behind a Desktop or Start-menu shortcut. It
  asks before it touches the network, every run. The installers moved into
  `installer\windows\` and `installer/linux/` in the download.

### v1.3

- **Drop-in install.** The download is now laid out as a `Plutonium` folder that mirrors
  `%localappdata%\Plutonium`, so the whole thing goes in and merges rather than being
  placed file by file. Both script paths are included, so there is no longer a build
  version to work out first.
- **MIT license** added, and it ships with the mod.
- README updates, including cross-links to the Black Ops, World at War and Black Ops III
  ports.
- **A build stamp** that draws the version and build time on screen - in development
  builds only. A released build carries an empty stamp and draws nothing.

Nothing else in the script changed: v1.2 and v1.3 play identically.

### v1.2

**Vote to pause**

- `zp_vote 1` puts a pause to the room instead of letting any one player stop the game.
  The threshold is whichever is higher, `zp_vote_min` or `zp_vote_percent` of the players
  present, clamped to how many are actually there. Votes are cast from chat or the button
  combos, and the tally shows the count, the clock and every player with how they voted.
  Off by default, so existing installs behave exactly as they did. See [Voting](#voting).
- `zp_vote_hold` freezes the game while the vote runs and puts it back if the vote fails.
  `zp_vote_unpause` extends voting to resuming.
- `zp_vote_alive_only`, on by default, leaves bled-out spectators out of the threshold -
  counting them makes a vote unwinnable exactly when you want one.
- A resolved vote holds `VOTE PASSED 2/2` on the tally for `zp_vote_result_time` rather
  than vanishing into the chat feed, and the countdown turns red in its last five seconds.

**HUD**

- `zp_hud_position` and `zp_vote_hud_position` - `top`, `center`, `middle`, `bottom`,
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
  combo that works for them rather than everybody else's - plus a shared `while down:`
  line, since a spectating client draws the HUD of the player it's watching and never
  sees its own.

**Zombies**

- `zp_silence_zombies`, on by default: a frozen horde no longer growls at you for the
  length of the pause.

**Fixed**

- Players who were downed or had bled out couldn't use the button combos at all - you
  can't crouch or melee from the floor, and the engine stops delivering those buttons
  once you're spectating. Those states now fall back to `zp_button_combo_dead` and
  `zp_vote_no_combo_dead`, built from buttons that still register.
- A long session could end in `exceeded maximum number of parent server script
  variables`. `_hud_util`'s `setparent()` files every element it creates into
  `level.uiparent.children` and `destroy()` doesn't take it back out - only
  `removechild()` does - so every HUD element ever built left a slot behind. The config
  struct was leaking the same pool by allocating a fresh `spawnstruct()` each pause.

**Changed**

- `zp_vote_time` defaults to 30 seconds.
- The config is re-read when a pause is *requested* rather than only when one starts, so
  turning `zp_vote` on mid-game takes effect without pausing first.
- `zp_input_debug` prints which buttons the server is actually receiving from each player
  and in what state, for picking the fallback combos on a build that differs.

### v1.1

- **Fixed:** a map script releasing a player's controls mid-pause - Ascension's lander
  landing and opening - let that player roam around a paused game. New
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

- **Xep** - author
- **Treyarch** - `_hostmigration.gsc`, the pause recipe this is built on
- **[plutoniummod/t6-scripts](https://github.com/plutoniummod/t6-scripts)** - stock T6 script reference
- **hima_simple** - earliest BO2 zombies pause script
- **[DED2SIN](https://forum.plutonium.pw/topic/46084/i-improved-a-zombies-custom-games-pause-mod)** - Plutonium pause script building on it
- **[MufaDOOM](https://github.com/MufaDOOM/Call-Of-Duty-Black-Ops-2-Zombie-COOP-PAUSE-by-MufaDOOM)** - BO2 co-op pause mod
- **[Resxt](https://github.com/Resxt/Plutonium-T6-Scripts)** - Plutonium T6 chat command conventions

---

## License

MIT - see [LICENSE](LICENSE). Use it, fork it, ship it in a server pack. Keep the
copyright notice and the header block at the top of `zpause.gsc`.

That covers ZPause's own code. Treyarch's stock scripts are referenced here, not
included, and are not mine to license.
