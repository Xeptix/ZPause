/*
======================================================================
    ZPAUSE  --  Synced co-op pause for Black Ops II Zombies
    Plutonium T6

    by Xep

======================================================================

    Any player can pause. Any player can unpause. The state lives on
    "level", so it is identical for everybody -- there is no per-client
    state to desync.

        Chat     !pause or !p to toggle, !unpause / !resume / !u
        Buttons  hold crouch + melee

    Settings live in zp_load_config() below. Each one is also a dvar of
    the same name, and the config is re-read at the start of every pause,
    so changes apply without a map restart.

----------------------------------------------------------------------
    HOW IT WORKS

    Treyarch already shipped a working full-game pause in T6 zombies --
    it is what runs during a host migration. See the stock script
    maps\mp\gametypes_zm\_hostmigration.gsc:

        disablezombies( 1 )             engine-level AI freeze
        flag_clear( "spawn_zombies" )   the spawner's own gate
        player freezecontrols( 1 )      lock players
        player enableinvulnerability()  nobody can be hurt
        locktimer()                     hold level.discardtime so the
                                        match clock does not advance

    ...and the exact inverse to resume. ZPause uses that recipe rather
    than inventing one, then adds what host migration never has to care
    about because it only lasts a few seconds: ground powerups that
    would time out, insta-kill and double-points countdowns, bleedout
    timers, the stuck-zombie watchdog, and AI that spawns or drifts
    while the game is held.

----------------------------------------------------------------------
    CREDITS

        Xep           author
        Treyarch      _hostmigration.gsc, the pause recipe above
        plutoniummod  t6-scripts, the stock script reference
        hima_simple   earliest BO2 zombies pause script
        DED2SIN       Plutonium pause script building on it
        MufaDOOM      BO2 co-op pause mod
        Resxt         Plutonium T6 chat command conventions

======================================================================
*/

#include common_scripts\utility;
#include maps\mp\_utility;
#include maps\mp\gametypes_zm\_hud_util;


/* ==================================================================
    ENTRY POINT
   ================================================================== */

init()
{
    // Plutonium may call init() and/or main() depending on how this file
    // is loaded (scripts folder vs mods folder). Only ever set up once.
    if ( is_true( level.zp_loaded ) )
        return;

    level.zp_loaded = 1;

    zp_load_config();

    level.zp_paused = 0;
    level.zp_busy = 0;
    level.zp_last_toggle = 0;
    level.zp_pause_start = 0;
    level.zp_spawn_flag_was_set = 0;
    level.zp_held_vars = [];
    level.zp_pauser_name = "someone";
    level.zp_hud = undefined;
    level.zp_hud_sub = undefined;

    // Unconditional: precaching has to happen during init, so gating this on
    // the config would mean turning zp_blackout on later silently did nothing.
    precacheshader( "black" );

    level thread zp_connect_watcher();
    level thread zp_chat_listener();
    level thread zp_endgame_safety();
}

main()
{
    init();
}


/* ==================================================================
    CONFIG

    Every value below can also be overridden with a dvar of the same
    name (set it in your config before the map loads), so server hosts
    do not have to edit this file.
   ================================================================== */

zp_load_config()
{
    level.zp = spawnstruct();

    // --- input -----------------------------------------------------
    // Chat words that toggle the pause. "!p" is the short form.
    level.zp.allow_short_words = zp_cfg_int( "zp_allow_short_words", 0 );

    // Hold crouch/prone + melee together to toggle the pause.
    level.zp.button_combo      = zp_cfg_int( "zp_button_combo", 1 );
    level.zp.button_hold_time  = zp_cfg_float( "zp_button_hold_time", 0.3 );

    // --- timing ----------------------------------------------------
    level.zp.countdown         = zp_cfg_int( "zp_countdown", 3 );   // 3..2..1 before play resumes
    level.zp.grace             = zp_cfg_float( "zp_grace", 2 );     // seconds of invuln after resuming
    level.zp.cooldown          = zp_cfg_float( "zp_cooldown", 2 );  // min seconds between toggles
    level.zp.max_pause_time    = zp_cfg_int( "zp_max_pause_time", 0 ); // 0 = unlimited

    // --- what gets frozen ------------------------------------------
    level.zp.engine_freeze     = zp_cfg_int( "zp_engine_freeze", 1 );      // disablezombies()/enablezombies()
    level.zp.drift_guard       = zp_cfg_int( "zp_drift_guard", 1 );        // snap back any AI that still moves

    /*
        Cosmetic. Without this a paused zombie holds whatever animation it
        was in and loops it, because disablezombies() stops the animscript
        updating the state while the engine carries on playing it. This
        switches them into "zm_inert", the standing pose the game uses for
        dormant zombies.

        Only the pose is borrowed, not start_inert() -- its inert_wakeup()
        watcher would un-freeze any zombie a player walked near or sprinted
        past. Standard zombies only; dogs and boss AI use their own animsets.
    */
    level.zp.freeze_anims      = zp_cfg_int( "zp_freeze_anims", 1 );
    level.zp.godmode           = zp_cfg_int( "zp_godmode", 1 );
    level.zp.freeze_clock      = zp_cfg_int( "zp_freeze_clock", 1 );
    level.zp.freeze_powerups   = zp_cfg_int( "zp_freeze_powerups", 1 );
    level.zp.freeze_effects    = zp_cfg_int( "zp_freeze_effects", 1 );     // insta-kill / double points
    level.zp.freeze_bleedout   = zp_cfg_int( "zp_freeze_bleedout", 1 );

    // --- presentation ----------------------------------------------
    level.zp.blackout          = zp_cfg_int( "zp_blackout", 0 );  // black out screens while paused
    level.zp.show_hint         = zp_cfg_int( "zp_show_hint", 1 ); // tell players how to pause on spawn
    level.zp.countdown_sound   = zp_cfg_str( "zp_countdown_sound", "" );

    // Drift guard tolerance, in units squared. 64 = 8 units.
    level.zp.drift_tolerance   = 64;
}

/*
    set_dvar_if_unset() (maps\mp\_utility) creates the dvar with our default
    the first time the config is read, and leaves alone anything already set
    in config.cfg. Creating it is the point: the console can only assign to a
    dvar that already exists, so a read-only getdvar would leave every setting
    unreachable from in game.
*/
zp_cfg_int( dvar, def )
{
    return int( set_dvar_if_unset( dvar, "" + def ) );
}

zp_cfg_float( dvar, def )
{
    return float( set_dvar_if_unset( dvar, "" + def ) );
}

zp_cfg_str( dvar, def )
{
    return set_dvar_if_unset( dvar, def );
}


/* ==================================================================
    INPUT -- CHAT
   ================================================================== */

zp_chat_listener()
{
    level endon( "end_game" );

    for (;;)
    {
        level waittill( "say", message, player );

        if ( !isdefined( message ) || !isdefined( player ) )
            continue;

        msg = tolower( message );

        if ( zp_is_pause_word( msg ) )
            level thread zp_request_toggle( player );
        else if ( zp_is_unpause_word( msg ) )
            level thread zp_request_unpause( player );
    }
}

/*
    Plutonium's "say" notify hands us the message with a stray control
    character at index 0 on T6. It is not reliably testable, so every
    comparison is done twice: once on the raw string and once on the
    string with its first character removed.
*/
zp_word_is( msg, token )
{
    if ( msg == token )
        return 1;

    if ( msg.size > 1 && getsubstr( msg, 1 ) == token )
        return 1;

    return 0;
}

zp_is_pause_word( msg )
{
    if ( zp_word_is( msg, "!pause" ) )
        return 1;

    if ( zp_word_is( msg, "!p" ) )
        return 1;

    if ( level.zp.allow_short_words )
    {
        if ( zp_word_is( msg, "pause" ) )
            return 1;

        if ( zp_word_is( msg, "p" ) )
            return 1;
    }

    return 0;
}

zp_is_unpause_word( msg )
{
    if ( zp_word_is( msg, "!unpause" ) )
        return 1;

    if ( zp_word_is( msg, "!resume" ) )
        return 1;

    if ( zp_word_is( msg, "!u" ) )
        return 1;

    if ( level.zp.allow_short_words )
    {
        if ( zp_word_is( msg, "unpause" ) )
            return 1;

        if ( zp_word_is( msg, "resume" ) )
            return 1;

        if ( zp_word_is( msg, "u" ) )
            return 1;
    }

    return 0;
}


/* ==================================================================
    INPUT -- BUTTON COMBO (crouch/prone + melee)

    freezecontrols() blocks movement and weapon use but the button state
    still reaches the server, so this keeps working while paused. That is
    what lets a frozen player unpause without touching chat.
   ================================================================== */

zp_button_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( !level.zp.button_combo )
            continue;

        if ( !( self stancebuttonpressed() && self meleebuttonpressed() ) )
            continue;

        // Require a short hold so a crouch-melee in normal play does
        // not pause the game by accident.
        held = 0;
        while ( self stancebuttonpressed() && self meleebuttonpressed() && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time )
            continue;

        level thread zp_request_toggle( self );

        // Debounce: wait for release, then a beat.
        while ( self stancebuttonpressed() || self meleebuttonpressed() )
            wait 0.05;

        wait 0.5;
    }
}


/* ==================================================================
    REQUEST GATES
   ================================================================== */

zp_game_ready()
{
    if ( is_true( level.gameended ) )
        return 0;

    if ( !isdefined( level.flag ) )
        return 0;

    if ( !isdefined( level.flag["initial_blackscreen_passed"] ) )
        return 0;

    if ( !flag( "initial_blackscreen_passed" ) )
        return 0;

    return 1;
}

zp_on_cooldown()
{
    return gettime() - level.zp_last_toggle < level.zp.cooldown * 1000;
}

zp_request_toggle( player )
{
    if ( is_true( level.zp_paused ) )
        zp_request_unpause( player );
    else
        zp_request_pause( player );
}

zp_request_pause( player )
{
    if ( is_true( level.zp_busy ) || is_true( level.zp_paused ) )
        return;

    if ( !zp_game_ready() )
    {
        if ( isdefined( player ) )
            player iprintln( "^1[Pause]^7 not available yet" );

        return;
    }

    if ( zp_on_cooldown() )
        return;

    level.zp_last_toggle = gettime();
    level thread zp_do_pause( player );
}

zp_request_unpause( player )
{
    if ( is_true( level.zp_busy ) || !is_true( level.zp_paused ) )
        return;

    /*
        "thread" starts running immediately in GSC, so two toggles landing in
        the same frame -- two players at once, or one player who typed !pause
        while also holding the button combo -- would otherwise pause and then
        instantly unpause again.
    */
    if ( zp_on_cooldown() )
        return;

    level.zp_last_toggle = gettime();
    level thread zp_do_unpause( player );
}


/* ==================================================================
    PAUSE
   ================================================================== */

zp_do_pause( player )
{
    // Pick up any dvar the host changed since the last pause, so config
    // edits do not need a map restart.
    zp_load_config();

    level.zp_busy = 1;
    level.zp_paused = 1;
    level.zp_pause_start = gettime();
    level.zp_held_vars = [];

    level.zp_pauser_name = "someone";
    if ( isdefined( player ) && isdefined( player.name ) )
        level.zp_pauser_name = player.name;

    level notify( "zp_paused" );

    // 1. Close the spawner gate. This is the flag _zm.gsc's spawn loop
    //    blocks on, and the same one host migration clears.
    level.zp_spawn_flag_was_set = 0;
    if ( isdefined( level.flag ) && isdefined( level.flag["spawn_zombies"] ) && flag( "spawn_zombies" ) )
    {
        level.zp_spawn_flag_was_set = 1;
        flag_clear( "spawn_zombies" );
    }

    // 2. Engine-level AI freeze. Threaded on its own so that even an
    //    unexpected failure here cannot wedge the state machine.
    if ( level.zp.engine_freeze )
        level thread zp_engine_zombies( 0 );

    // 3. Hold every AI in place, including anything that appears later.
    level thread zp_ai_enforcer();

    //    Cosmetic pose swap, after the engine freeze so nothing overwrites it.
    if ( level.zp.freeze_anims )
        level thread zp_anim_freeze_pass();

    // 4. Lock the players.
    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] zp_freeze_player();

    // 5. Hold the clocks.
    if ( level.zp.freeze_clock )
        level thread zp_clock_locker();

    if ( level.zp.freeze_powerups || level.zp.freeze_effects )
        level thread zp_powerup_enforcer();

    if ( level.zp.freeze_bleedout )
        level thread zp_bleedout_enforcer();

    // 6. Tell everybody.
    level thread zp_hud_show();
    zp_msg_all( "^3[Pause]^7 game paused by ^3" + level.zp_pauser_name );

    if ( level.zp.max_pause_time > 0 )
        level thread zp_auto_unpause();

    level.zp_busy = 0;
}


/* ==================================================================
    UNPAUSE
   ================================================================== */

zp_do_unpause( player )
{
    level endon( "end_game" );

    level.zp_busy = 1;

    name = "someone";
    if ( isdefined( player ) && isdefined( player.name ) )
        name = player.name;
    else if ( !isdefined( player ) )
        name = "auto-resume";

    zp_msg_all( "^2[Pause]^7 resuming -- requested by ^2" + name );

    // Countdown. Everything stays frozen for the whole countdown, so
    // nobody gets to reposition against held zombies.
    cd = level.zp.countdown;
    while ( cd > 0 )
    {
        if ( isdefined( level.zp_hud ) )
            level.zp_hud settext( "RESUMING IN " + cd );

        if ( isdefined( level.zp_hud_sub ) )
            level.zp_hud_sub settext( "hold still" );

        zp_sound_all( level.zp.countdown_sound );
        wait 1;
        cd = cd - 1;
    }

    // Stop every enforcer thread at once, then reverse the pause.
    level notify( "zp_thaw" );

    if ( level.zp.engine_freeze )
        level thread zp_engine_zombies( 1 );

    zp_ai_thaw();

    // Unconditional, keyed on each zombie's own flag, so turning
    // zp_freeze_anims off mid-pause can never strand one in the pose.
    level thread zp_anim_thaw_pass();

    zp_powerups_thaw();
    zp_effects_thaw();
    zp_bleedout_thaw();

    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] zp_unfreeze_player();

    if ( is_true( level.zp_spawn_flag_was_set ) )
    {
        if ( isdefined( level.flag ) && isdefined( level.flag["spawn_zombies"] ) )
            flag_set( "spawn_zombies" );
    }
    level.zp_spawn_flag_was_set = 0;

    zp_hud_destroy();

    level.zp_paused = 0;
    level.zp_last_toggle = gettime();
    level.zp_busy = 0;

    level notify( "zp_unpaused" );
}

zp_auto_unpause()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    wait( level.zp.max_pause_time );

    level thread zp_do_unpause( undefined );
}


/* ==================================================================
    AI

    disablezombies()/enablezombies() are engine builtins -- they are what
    maps\mp\gametypes_zm\_hostmigration.gsc calls to hold and release the
    AI. The enforcer below is a safety net around them: it stops AI from
    re-acquiring a target, catches anything that spawns mid-pause, and
    snaps back anything that still manages to move.
   ================================================================== */

zp_engine_zombies( benable )
{
    if ( benable )
        enablezombies( 1 );
    else
        disablezombies( 1 );
}

zp_get_ai()
{
    return getaiarray();
}

zp_ai_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        ai = zp_get_ai();

        for ( i = 0; i < ai.size; i++ )
        {
            z = ai[i];

            if ( !isdefined( z ) || !isalive( z ) )
                continue;

            /*
                Stop the game culling zombies for standing still.

                _zm.gsc::round_spawn_failsafe() kills any zombie that has not
                moved 24 units in 30 seconds, assuming it is stuck outside the
                playspace; Origins and Mob of the Dead ship variants on a 15
                second timer. A paused zombie trips it every time, and the
                "put it back in the spawn queue" compensation is skipped for
                anything with ignoreall set -- which is what freezes them. So
                they are gone for good, counted as killed, and the round
                advances by itself while everyone is away.

                All three variants skip the kill for a zombie that tore a
                barrier chunk in the last 8 seconds. Keeping that stamp fresh
                makes the watchdog loop around harmlessly instead of firing.
                Nothing else reads lastchunk_destroy_time outside a dev block.

                Deliberately NOT ignore_round_spawn_failsafe: that makes the
                watchdog thread return for good, so a zombie that got
                genuinely stuck later would hang the round forever.
            */
            z.lastchunk_destroy_time = gettime();

            if ( !isdefined( z.zp_anchor ) )
            {
                // First time we have seen this one -- could be an AI
                // that was already alive, or one that slipped through
                // a spawn that was already in flight.
                z.zp_anchor = z.origin;
                z.zp_had_ignoreall = is_true( z.ignoreall );
                z.ignoreall = 1;
                z setgoalpos( z.origin );
                continue;
            }

            if ( !is_true( z.ignoreall ) )
                z.ignoreall = 1;

            if ( level.zp.drift_guard && distancesquared( z.origin, z.zp_anchor ) > level.zp.drift_tolerance )
            {
                z setorigin( z.zp_anchor );
                z setgoalpos( z.zp_anchor );
            }
        }

        wait 0.1;
    }
}

zp_ai_thaw()
{
    ai = zp_get_ai();

    for ( i = 0; i < ai.size; i++ )
    {
        z = ai[i];

        if ( !isdefined( z ) || !isdefined( z.zp_anchor ) )
            continue;

        z.zp_anchor = undefined;

        // Only clear ignoreall if we were the ones who set it. Nuked,
        // marked-for-death and screecher zombies set it themselves.
        if ( !is_true( z.zp_had_ignoreall ) )
            z.ignoreall = 0;

        z.zp_had_ignoreall = undefined;
    }
}

/*
    Called AFTER disablezombies(). The ordering matters: while the AI think is
    live, zm_run::moverun() re-derives the animation state from movement speed
    every update and would immediately overwrite the pose.

    Zombies do not spawn while paused, so a single pass is enough. Runs in its
    own thread, so a map whose animset has no zm_inert state cannot affect the
    pause itself.
*/
zp_anim_freeze_pass()
{
    ai = zp_get_ai();

    for ( i = 0; i < ai.size; i++ )
    {
        z = ai[i];

        if ( !isdefined( z ) || !isalive( z ) || is_true( z.zp_anim_frozen ) )
            continue;

        // Standard zombies only. zombie_spawn_init() stamps these two.
        if ( !is_true( z.is_zombie ) || !isdefined( z.animname ) || z.animname != "zombie" )
            continue;

        z.zp_anim_frozen = 1;

        if ( is_true( z.has_legs ) )
            z setanimstatefromasd( "zm_inert", "inert1" );
        else
            z setanimstatefromasd( "zm_inert_crawl", "inert1" );
    }
}

zp_anim_thaw_pass()
{
    ai = zp_get_ai();

    for ( i = 0; i < ai.size; i++ )
    {
        z = ai[i];

        if ( !isdefined( z ) || !is_true( z.zp_anim_frozen ) )
            continue;

        z.zp_anim_frozen = undefined;

        // Kick the run animscript so it re-derives the movement state, the
        // same call inert_think() makes when a dormant zombie wakes up.
        z maps\mp\animscripts\zm_run::needsupdate();
    }
}


/* ==================================================================
    PLAYERS
   ================================================================== */

zp_connect_watcher()
{
    level endon( "end_game" );

    // Catch anybody who was already in before this script initialised.
    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] thread zp_player_think();

    for (;;)
    {
        level waittill( "connected", player );
        player thread zp_player_think();
    }
}

zp_player_think()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    if ( is_true( self.zp_thinking ) )
        return;

    self.zp_thinking = 1;
    self thread zp_button_watcher();

    for (;;)
    {
        self waittill( "spawned_player" );

        if ( is_true( level.zp_paused ) )
        {
            // Joined or respawned into a paused game -- freeze them too.
            self zp_freeze_player();
        }
        else if ( level.zp.show_hint && !is_true( self.zp_hinted ) )
        {
            self.zp_hinted = 1;
            self thread zp_hint();
        }
    }
}

zp_hint()
{
    self endon( "disconnect" );
    wait 8;

    if ( level.zp.button_combo )
        self iprintln( "^3[Pause]^7 type ^3!pause^7 or hold ^3crouch + melee" );
    else
        self iprintln( "^3[Pause]^7 type ^3!pause^7 to pause or resume" );
}

zp_freeze_player()
{
    if ( is_true( self.zp_frozen ) )
        return;

    self.zp_frozen = 1;
    self.zp_had_ignoreme = is_true( self.ignoreme );
    self.ignoreme = 1;
    self freezecontrols( 1 );

    if ( level.zp.godmode )
        self enableinvulnerability();

    if ( level.zp.blackout )
        self zp_blackout_on();
}

zp_unfreeze_player()
{
    if ( !is_true( self.zp_frozen ) )
        return;

    self.zp_frozen = undefined;
    self freezecontrols( 0 );

    if ( !is_true( self.zp_had_ignoreme ) )
        self.ignoreme = 0;

    self.zp_had_ignoreme = undefined;
    self zp_blackout_off();

    if ( level.zp.godmode )
        self thread zp_grace();
}

zp_grace()
{
    self endon( "disconnect" );

    if ( level.zp.grace > 0 )
        wait( level.zp.grace );

    // If the game was paused again while we were waiting out the grace
    // period, leave the player invulnerable -- the new pause owns them now.
    if ( is_true( level.zp_paused ) || is_true( self.zp_frozen ) )
        return;

    self disableinvulnerability();
}

zp_blackout_on()
{
    if ( isdefined( self.zp_black ) )
        return;

    self.zp_black = newclienthudelem( self );
    self.zp_black.horzalign = "fullscreen";
    self.zp_black.vertalign = "fullscreen";
    self.zp_black.sort = 50;
    self.zp_black.foreground = 0;
    self.zp_black setshader( "black", 640, 480 );
    self.zp_black.alpha = 0;
    self.zp_black fadeovertime( 0.4 );
    self.zp_black.alpha = 0.92;
}

zp_blackout_off()
{
    if ( !isdefined( self.zp_black ) )
        return;

    self.zp_black destroy();
    self.zp_black = undefined;
}


/* ==================================================================
    CLOCK

    Straight out of _hostmigration.gsc::locktimer(). level.discardtime is
    subtracted from the match clock, so pushing it forward by exactly the
    elapsed time holds the timer still.
   ================================================================== */

zp_clock_locker()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        currtime = gettime();
        wait 0.05;

        if ( isdefined( level.discardtime ) && !is_true( level.timerstopped ) )
            level.discardtime = level.discardtime + ( gettime() - currtime );
    }
}


/* ==================================================================
    POWERUPS

    Two separate problems:

    a) A powerup lying on the ground runs powerup_timeout(), which is a
       plain wait(). It cannot be paused, so we cut the thread instead
       ("powerup_reset" is its endon) and restart it on resume.

    b) Insta-kill and double points count down through level.zombie_vars,
       so we can simply hold those values still. The 30s wait() driving
       the actual effect keeps running underneath, so on resume we hold
       the effect on until the (frozen) HUD timer has really run out.
   ================================================================== */

zp_powerup_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        if ( level.zp.freeze_powerups )
            zp_powerups_hold();

        if ( level.zp.freeze_effects )
            zp_effects_hold();

        wait 0.05;
    }
}

zp_powerups_hold()
{
    if ( !isdefined( level.active_powerups ) )
        return;

    for ( i = 0; i < level.active_powerups.size; i++ )
    {
        p = level.active_powerups[i];

        if ( !isdefined( p ) || is_true( p.zp_held ) )
            continue;

        p.zp_held = 1;
        p notify( "powerup_reset" );  // ends maps\mp\zombies\_zm_powerups::powerup_timeout
        p show();
    }
}

zp_powerups_thaw()
{
    if ( !isdefined( level.active_powerups ) )
        return;

    for ( i = 0; i < level.active_powerups.size; i++ )
    {
        p = level.active_powerups[i];

        if ( !isdefined( p ) || !is_true( p.zp_held ) )
            continue;

        p.zp_held = undefined;
        p thread maps\mp\zombies\_zm_powerups::powerup_timeout();
    }
}

zp_effects_hold()
{
    if ( !isdefined( level.zombie_vars ) || !isdefined( level.teams ) )
        return;

    foreach ( team in level.teams )
    {
        if ( !isdefined( level.zombie_vars[team] ) )
            continue;

        zp_hold_var( team, "zombie_powerup_insta_kill_time" );
        zp_hold_var( team, "zombie_powerup_point_doubler_time" );
        zp_hold_var( team, "zombie_insta_kill" );
        zp_hold_var( team, "zombie_point_scalar" );
    }
}

zp_hold_var( team, key )
{
    if ( !isdefined( level.zombie_vars[team][key] ) )
        return;

    id = team + "|" + key;

    if ( !isdefined( level.zp_held_vars[id] ) )
        level.zp_held_vars[id] = level.zombie_vars[team][key];
    else
        level.zombie_vars[team][key] = level.zp_held_vars[id];
}

/*
    Releasing the effect vars needs care. insta_kill_powerup() is a plain
    "wait 30" that we cannot pause, so on a long pause it has already run
    its cleanup line -- and our hold quietly put the value back. If we
    just stopped holding, insta-kill or double points would stay on for
    the rest of the game.

    So on resume we hand the effect over to a bounded thread that keeps it
    on only until the HUD countdown (which we did freeze correctly, and
    which is still ticking down in _zm_powerups) actually reaches zero,
    then forces it off. Net result: the player gets exactly the time they
    earned, and the effect always terminates.
*/
zp_effects_thaw()
{
    if ( !isdefined( level.zombie_vars ) || !isdefined( level.teams ) )
    {
        level.zp_held_vars = [];
        return;
    }

    foreach ( team in level.teams )
    {
        if ( !isdefined( level.zombie_vars[team] ) )
            continue;

        ik = level.zp_held_vars[team + "|zombie_insta_kill"];
        if ( isdefined( ik ) && ik == 1 )
        {
            level thread zp_effect_extender( team, "zombie_insta_kill", 1, 0,
                "zombie_powerup_insta_kill_time", "zombie_powerup_insta_kill_on" );
        }

        dp = level.zp_held_vars[team + "|zombie_point_scalar"];
        if ( isdefined( dp ) && dp > 1 )
        {
            level thread zp_effect_extender( team, "zombie_point_scalar", dp, 1,
                "zombie_powerup_point_doubler_time", "zombie_powerup_point_doubler_on" );
        }
    }

    level.zp_held_vars = [];
}

zp_effect_extender( team, effect_key, on_value, off_value, timer_key, on_key )
{
    level endon( "end_game" );
    level endon( "zp_paused" );  // a new pause takes the hold back over

    if ( !isdefined( level.zombie_vars[team] ) || !isdefined( level.zombie_vars[team][timer_key] ) )
        return;

    /*
        The effect can never need longer than whatever is still on its own
        HUD countdown -- which is the value we froze, so it is exactly the
        time the player has left to be given back. Bounding the thread by
        that (plus a small buffer) means it always terminates, and never
        terminates early.
    */
    remaining = level.zombie_vars[team][timer_key];
    if ( remaining > 35 )
        remaining = 35;

    deadline = gettime() + int( remaining * 1000 ) + 2000;

    for (;;)
    {
        if ( !isdefined( level.zombie_vars[team] ) || !isdefined( level.zombie_vars[team][timer_key] ) )
            return;

        if ( gettime() > deadline )
            break;

        // The HUD countdown reaching zero, or _zm_powerups clearing its
        // "powerup is running" flag, both mean the player's time is up.
        if ( level.zombie_vars[team][timer_key] <= 0 )
            break;

        if ( isdefined( level.zombie_vars[team][on_key] ) && !level.zombie_vars[team][on_key] )
            break;

        level.zombie_vars[team][effect_key] = on_value;
        wait 0.05;
    }

    level.zombie_vars[team][effect_key] = off_value;
}


/* ==================================================================
    BLEEDOUT

    _zm_laststand.gsc::laststand_bleedout() decrements self.bleedout_time
    once a second. Pinning the value holds a downed player where they are
    instead of letting them bleed out during the pause.
   ================================================================== */

zp_bleedout_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        players = get_players();

        for ( i = 0; i < players.size; i++ )
        {
            p = players[i];

            if ( !isdefined( p ) || !isdefined( p.bleedout_time ) )
                continue;

            if ( !isdefined( p.revivetrigger ) && !is_true( p.laststand ) )
                continue;

            if ( !isdefined( p.zp_bleedout ) )
                p.zp_bleedout = p.bleedout_time;
            else
                p.bleedout_time = p.zp_bleedout;
        }

        wait 0.05;
    }
}

zp_bleedout_thaw()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i].zp_bleedout = undefined;
    }
}


/* ==================================================================
    HUD / FEEDBACK
   ================================================================== */

zp_hud_show()
{
    zp_hud_destroy();

    level.zp_hud = createserverfontstring( "objective", 1.9 );
    level.zp_hud setpoint( "CENTER", "TOP", 0, 56 );
    level.zp_hud.color = ( 1, 0.82, 0.15 );
    level.zp_hud.sort = 1000;
    level.zp_hud.foreground = 1;
    level.zp_hud settext( "GAME PAUSED" );

    level.zp_hud_sub = createserverfontstring( "default", 1.25 );
    level.zp_hud_sub setpoint( "CENTER", "TOP", 0, 86 );
    level.zp_hud_sub.color = ( 0.85, 0.85, 0.85 );
    level.zp_hud_sub.sort = 1000;
    level.zp_hud_sub.foreground = 1;

    if ( level.zp.button_combo )
        level.zp_hud_sub settext( "!unpause  or  crouch + melee" );
    else
        level.zp_hud_sub settext( "type !unpause to resume" );
}

zp_hud_destroy()
{
    if ( isdefined( level.zp_hud ) )
    {
        level.zp_hud destroy();
        level.zp_hud = undefined;
    }

    if ( isdefined( level.zp_hud_sub ) )
    {
        level.zp_hud_sub destroy();
        level.zp_hud_sub = undefined;
    }
}

zp_msg_all( txt )
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i] iprintln( txt );
    }
}

zp_sound_all( alias )
{
    if ( !isdefined( alias ) || alias == "" )
        return;

    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i] playlocalsound( alias );
    }
}


/* ==================================================================
    SAFETY

    If the game ends while paused, tear everything down so nobody is
    left frozen, blacked out, or staring at a stale HUD element.
   ================================================================== */

zp_endgame_safety()
{
    level waittill( "end_game" );

    level notify( "zp_thaw" );

    zp_hud_destroy();
    zp_ai_thaw();

    players = get_players();
    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( !isdefined( p ) )
            continue;

        p zp_blackout_off();

        if ( is_true( p.zp_frozen ) )
        {
            p.zp_frozen = undefined;
            p freezecontrols( 0 );

            if ( level.zp.godmode )
                p disableinvulnerability();
        }
    }

    if ( level.zp.engine_freeze && is_true( level.zp_paused ) )
        level thread zp_engine_zombies( 1 );

    level.zp_paused = 0;
    level.zp_busy = 0;
}
