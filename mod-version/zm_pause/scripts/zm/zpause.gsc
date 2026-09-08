/*
======================================================================
    ZPAUSE v1.2  --  Synced co-op pause for Black Ops II Zombies
    Plutonium T6

    by Xep

======================================================================

    Any player can pause. Any player can unpause. The state lives on
    "level", so it is identical for everybody -- there is no per-client
    state to desync.

        Chat     !pause or !p to toggle, !unpause / !resume / !u
        Buttons  hold crouch + melee
        Voting   zp_vote 1 puts a pause to the room. The pause combo and
                 !yes vote for it, jump + melee and !no vote against.

    Everything runs on the host. Nobody else needs this file or any mod:
    the freeze, the HUD, the sounds and the vote all execute server-side
    and replicate to stock clients.

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
    level.zp_hud_sub_override = undefined;
    level.zp_hud_meta = undefined;
    level.zp_hud_clock = undefined;
    level.zp_vote_clock = undefined;
    level.zp_panel = undefined;

    level.zp_vote_active = 0;
    level.zp_vote_serial = 0;
    level.zp_vote_kind = "pause";
    level.zp_vote_end_time = 0;
    level.zp_vote_last_fail = 0;
    level.zp_vote_provisional = 0;
    level.zp_vote_initiator = undefined;
    level.zp_vote_name = "someone";
    level.zp_vote_hud = undefined;
    level.zp_vote_rows = [];

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
    /*
        Reuse the struct rather than making a new one. spawnstruct() takes
        a parent script variable, and this runs on every pause request --
        including ones that bail on the cooldown -- so allocating each time
        walks a long session into "exceeded maximum number of parent server
        script variables" and drops it. The fields below are all overwritten
        on every pass, so there is nothing stale to clear.
    */
    if ( !isdefined( level.zp ) )
        level.zp = spawnstruct();

    // --- input -----------------------------------------------------
    // Chat words that toggle the pause. "!p" is the short form.
    level.zp.allow_short_words = zp_cfg_int( "zp_allow_short_words", 0 );

    // Hold crouch/prone + melee together to toggle the pause.
    level.zp.button_combo      = zp_cfg_int( "zp_button_combo", 1 );
    level.zp.button_hold_time  = zp_cfg_float( "zp_button_hold_time", 0.3 );

    /*
        Down on the floor or bled out and spectating, the stance and melee
        buttons stop reaching the server, so the normal combo goes dead.
        Use, aim and fire all keep coming through -- _killcam.gsc sets
        sessionstate to "spectator" and then reads usebuttonpressed() to
        skip the killcam, and last stand code reads the same.

        These are the combos used in that state instead. use_frag and
        frag_only are also available if a build turns out to deliver a
        different set; zp_input_debug prints exactly which buttons arrive
        in which state. Set either to "" to leave it on chat alone.
    */
    level.zp.button_combo_dead  = zp_cfg_str( "zp_button_combo_dead", "use_ads" );
    level.zp.vote_no_combo_dead = zp_cfg_str( "zp_vote_no_combo_dead", "use_attack" );
    level.zp.input_debug        = zp_cfg_int( "zp_input_debug", 0 );

    // --- voting ----------------------------------------------------
    /*
        Off by default: without it any player pauses on their own, which
        is what ZPause has always done. Turn it on and a pause has to
        carry the room first.

        The bar is whichever is higher, zp_vote_min or zp_vote_percent of
        the players in the game, and it is then clamped to the number of
        players -- so a lobby can never set a bar nobody present can
        clear. When that works out to a single vote, as it does solo, the
        vote is skipped and the pause just happens.
    */
    level.zp.vote               = zp_cfg_int( "zp_vote", 0 );
    level.zp.vote_min           = zp_cfg_int( "zp_vote_min", 2 );
    level.zp.vote_percent       = zp_cfg_int( "zp_vote_percent", 51 );
    level.zp.vote_time          = zp_cfg_float( "zp_vote_time", 30 );
    level.zp.vote_unpause       = zp_cfg_int( "zp_vote_unpause", 0 );

    /*
        Freeze the game for the duration of the vote and put it back if
        the vote fails, so nobody dies while the room decides. Off by
        default: it lets one player stop play on their own, which is the
        thing voting is there to prevent.
    */
    level.zp.vote_hold          = zp_cfg_int( "zp_vote_hold", 0 );
    level.zp.vote_initiator_yes = zp_cfg_int( "zp_vote_initiator_yes", 1 );
    level.zp.vote_lockout       = zp_cfg_float( "zp_vote_lockout", 10 );
    level.zp.vote_hud           = zp_cfg_int( "zp_vote_hud", 1 );
    level.zp.vote_show_voters   = zp_cfg_int( "zp_vote_show_voters", 1 );
    level.zp.vote_hud_position  = zp_cfg_str( "zp_vote_hud_position", "top" );

    /*
        Leave the dead out of the maths. On by default because counting
        them makes votes unwinnable exactly when you most want one: two
        players, one bled out, a threshold of two and only one person left
        who can answer. Players in last stand still count -- they are
        alive, and they still care whether the game stops.
    */
    level.zp.vote_alive_only    = zp_cfg_int( "zp_vote_alive_only", 1 );

    // How long the result stands on the tally once a vote resolves.
    level.zp.vote_result_time   = zp_cfg_float( "zp_vote_result_time", 2 );

    /*
        Which combo votes no. Only watched while a vote is open, so the
        only clash that matters is one you might hit during those few
        seconds. jump + melee is not something you hold in normal play;
        the crouch_* alternatives are easier to reach but all collide
        with something (use = buy/revive, ads = crouch-aiming).

        jump_melee | crouch_use | crouch_frag | crouch_ads | crouch_melee
    */
    level.zp.vote_no_combo      = zp_cfg_str( "zp_vote_no_combo", "jump_melee" );

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

    /*
        Shut the zombies up while the game is held. A frozen horde stood
        next to you keeps growling, which is loud and misleading when
        nothing is happening.

        _zm_audio.gsc::do_zombies_playvocals() returns early for anything
        flagged is_inert, so setting that flag stops new vocals at the
        source; stopsounds() cuts whatever was already in the air. Only the
        flag is borrowed, never start_inert() -- its inert_wakeup() watcher
        would un-freeze any zombie a player walked near, the same reason
        zp_freeze_anims takes only the pose.

        The game's own zm_novocals switch is no use here -- it sits inside
        a developer-only block and is compiled out of a release build.
    */
    level.zp.silence_zombies   = zp_cfg_int( "zp_silence_zombies", 1 );
    level.zp.godmode           = zp_cfg_int( "zp_godmode", 1 );

    /*
        Re-assert the player freeze while the game is held. Map scripts
        that carry a player somewhere lock the controls for the ride and
        call freezecontrols( 0 ) when it ends -- Ascension's lander is the
        one that bites -- which hands control back mid-pause and lets that
        player walk around a frozen game. Nothing can read the freeze state
        back, so the guard simply re-applies it; it re-pins godmode and
        ignoreme at the same time.
    */
    level.zp.control_guard     = zp_cfg_int( "zp_control_guard", 1 );
    level.zp.freeze_clock      = zp_cfg_int( "zp_freeze_clock", 1 );
    level.zp.freeze_powerups   = zp_cfg_int( "zp_freeze_powerups", 1 );
    level.zp.freeze_effects    = zp_cfg_int( "zp_freeze_effects", 1 );     // insta-kill / double points
    level.zp.freeze_bleedout   = zp_cfg_int( "zp_freeze_bleedout", 1 );

    // --- presentation ----------------------------------------------
    level.zp.blackout          = zp_cfg_int( "zp_blackout", 0 );  // black out screens while paused
    level.zp.show_hint         = zp_cfg_int( "zp_show_hint", 1 ); // tell players how to pause on spawn

    /*
        Where each block of HUD text sits: top, center, middle, bottom,
        left or right. The left and right slots align their text to that
        edge rather than staying centred.

        "center" is the classic banner spot -- horizontally centred and
        high enough to stay out of the fight, which is where the pause
        banner has sat since v1.0. "middle" is the actual centre of the
        screen, over the crosshair.
    */
    level.zp.hud_position      = zp_cfg_str( "zp_hud_position", "center" );

    /*
        Draw the combos as the buttons each player actually has bound
        rather than as words. [{+bind}] is substituted by the client at
        draw time, so the same string renders as a key on a keyboard and
        as a pad glyph on a controller, per player, with no detection
        needed -- and it follows rebound keys. Stock code does the same
        in _ai_tank.gsc and _rcbomb.gsc.

        Turn it off for plain words if a glyph does not render on your
        build. Chat is always words, since only the HUD substitutes.
    */
    level.zp.hud_binds         = zp_cfg_int( "zp_hud_binds", 1 );

    // Black glow behind the text, the same thing the stock notify
    // messages use. Zombies skyboxes are bright and the HUD sits on top
    // of them; this is what keeps it readable.
    level.zp.hud_glow          = zp_cfg_int( "zp_hud_glow", 1 );

    /*
        Heavier alternative to the glow: a black slab behind the whole
        block. Off by default -- it is a lot of screen for a co-op pause,
        and the glow already carries the text on most maps.

        The width is a dvar because nothing here can measure a rendered
        string. Widen it if a long line overhangs the slab.
    */
    level.zp.hud_panel         = zp_cfg_int( "zp_hud_panel", 0 );
    level.zp.hud_panel_alpha   = zp_cfg_float( "zp_hud_panel_alpha", 0.45 );
    level.zp.hud_panel_width   = zp_cfg_int( "zp_hud_panel_width", 340 );

    // "paused by Xep -- 2:14" under the banner, counting up. Counts down
    // to the auto-resume instead when zp_max_pause_time is set.
    level.zp.hud_timer         = zp_cfg_int( "zp_hud_timer", 1 );

    /*
        Softer alternative to the blackout: setblur() is the same
        post-process the game runs when you buy a perk, which uses 4.
        1.5 reads as "the game has stepped back" without hiding it.
    */
    level.zp.blur              = zp_cfg_int( "zp_blur", 1 );
    level.zp.blur_amount       = zp_cfg_float( "zp_blur_amount", 1.5 );

    /*
        Stock aliases, so both packagings stay one drop-in file -- a
        custom sound would have to be installed by every player rather
        than just the host. go_inert and end_inert are what a zombie
        plays going dormant and waking up; tombstone_timer_count is the
        game's own once-a-second countdown tick. Set any to "" for
        silence.
    */
    level.zp.pause_sound       = zp_cfg_str( "zp_pause_sound", "zmb_zombie_go_inert" );
    level.zp.countdown_sound   = zp_cfg_str( "zp_countdown_sound", "zmb_tombstone_timer_count" );
    level.zp.resume_sound      = zp_cfg_str( "zp_resume_sound", "zmb_zombie_end_inert" );

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

        if ( is_true( level.zp_vote_active ) && zp_is_no_word( msg ) )
            zp_cast_vote( player, 0 );
        else if ( is_true( level.zp_vote_active ) && zp_is_yes_word( msg ) )
            zp_cast_vote( player, 1 );
        else if ( zp_is_pause_word( msg ) )
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


/*
    Only consulted while a vote is open, so the bare forms cannot cast
    anything during normal conversation.
*/
zp_is_yes_word( msg )
{
    if ( zp_word_is( msg, "!yes" ) )
        return 1;

    if ( zp_word_is( msg, "!y" ) )
        return 1;

    if ( zp_word_is( msg, "yes" ) )
        return 1;

    if ( zp_word_is( msg, "y" ) )
        return 1;

    return 0;
}

zp_is_no_word( msg )
{
    if ( zp_word_is( msg, "!no" ) )
        return 1;

    if ( zp_word_is( msg, "!n" ) )
        return 1;

    if ( zp_word_is( msg, "no" ) )
        return 1;

    if ( zp_word_is( msg, "n" ) )
        return 1;

    return 0;
}


/* ==================================================================
    INPUT -- BUTTON COMBO (crouch/prone + melee)

    freezecontrols() blocks movement and weapon use but the button state
    still reaches the server, so this keeps working while paused. That is
    what lets a frozen player unpause without touching chat.
   ================================================================== */

/*
    Every combo the script can watch for, in one place. stancebuttonpressed()
    is crouch and prone both, which is why the yes combo covers either.
*/
zp_combo_pressed( combo )
{
    if ( combo == "crouch_use" )
        return self stancebuttonpressed() && self usebuttonpressed();

    if ( combo == "crouch_frag" )
        return self stancebuttonpressed() && self fragbuttonpressed();

    if ( combo == "crouch_ads" )
        return self stancebuttonpressed() && self adsbuttonpressed();

    if ( combo == "crouch_melee" )
        return self stancebuttonpressed() && self meleebuttonpressed();

    // The two buttons that survive last stand and spectating.
    if ( combo == "use_frag" )
        return self usebuttonpressed() && self fragbuttonpressed();

    // Deliberately excludes use, so it cannot fire while use_frag is held.
    if ( combo == "frag_only" )
        return self fragbuttonpressed() && !( self usebuttonpressed() );

    if ( combo == "use_ads" )
        return self usebuttonpressed() && self adsbuttonpressed();

    if ( combo == "use_attack" )
        return self usebuttonpressed() && self attackbuttonpressed();

    if ( combo == "attack_ads" )
        return self attackbuttonpressed() && self adsbuttonpressed();

    return self jumpbuttonpressed() && self meleebuttonpressed();
}

zp_combo_label( combo, binds )
{
    if ( is_true( binds ) )
        return zp_combo_binds( combo );

    if ( combo == "crouch_use" )
        return "crouch + use";

    if ( combo == "crouch_frag" )
        return "crouch + grenade";

    if ( combo == "crouch_ads" )
        return "crouch + aim";

    if ( combo == "crouch_melee" )
        return "crouch + melee";

    if ( combo == "use_frag" )
        return "use + grenade";

    if ( combo == "frag_only" )
        return "grenade";

    if ( combo == "use_ads" )
        return "use + aim";

    if ( combo == "use_attack" )
        return "use + fire";

    if ( combo == "attack_ads" )
        return "fire + aim";

    return "jump + melee";
}

/*
    The same table as button glyphs. Anything unbound draws as the macro's
    own fallback rather than breaking the line, so a wrong guess here is
    cosmetic -- zp_hud_binds 0 goes back to words.
*/
zp_combo_binds( combo )
{
    if ( combo == "crouch_use" )
        return "[{+stance}] + [{+activate}]";

    if ( combo == "crouch_frag" )
        return "[{+stance}] + [{+frag}]";

    if ( combo == "crouch_ads" )
        return "[{+stance}] + [{+speed_throw}]";

    if ( combo == "crouch_melee" )
        return "[{+stance}] + [{+melee}]";

    if ( combo == "use_frag" )
        return "[{+activate}] + [{+frag}]";

    if ( combo == "frag_only" )
        return "[{+frag}]";

    if ( combo == "use_ads" )
        return "[{+activate}] + [{+speed_throw}]";

    if ( combo == "use_attack" )
        return "[{+activate}] + [{+attack}]";

    if ( combo == "attack_ads" )
        return "[{+attack}] + [{+speed_throw}]";

    return "[{+gostand}] + [{+melee}]";
}

/*
    Bled out and spectating. This is the electorate question -- who the vote
    maths runs over -- and it is deliberately not the same as the input
    question below: a downed player is still alive and still voting.
*/
zp_player_is_spectating( player )
{
    if ( !isdefined( player ) )
        return 0;

    if ( isdefined( player.sessionstate ) && player.sessionstate == "spectator" )
        return 1;

    return !isalive( player );
}

/*
    Whether the normal combo can still reach the server. You cannot crouch
    or melee from the floor, and once you are spectating the engine stops
    delivering those buttons at all -- stock last stand code reads
    usebuttonpressed() and nothing else, which is the tell for both states.
*/
zp_player_input_limited( player )
{
    if ( !isdefined( player ) )
        return 0;

    if ( is_true( player.laststand ) )
        return 1;

    return zp_player_is_spectating( player );
}

zp_active_combo( up_combo, dead_combo )
{
    if ( !isdefined( dead_combo ) || dead_combo == "" )
        return up_combo;

    if ( !zp_player_input_limited( self ) )
        return up_combo;

    return dead_combo;
}

zp_button_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( !level.zp.button_combo )
            continue;

        combo = self zp_active_combo( "crouch_melee", level.zp.button_combo_dead );

        if ( !( self zp_combo_pressed( combo ) ) )
            continue;

        // Require a short hold so a crouch-melee in normal play does
        // not pause the game by accident.
        held = 0;
        while ( ( self zp_combo_pressed( combo ) ) && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time )
            continue;

        level thread zp_request_toggle( self );

        // Debounce: wait for release, then a beat.
        while ( self zp_combo_pressed( combo ) )
            wait 0.05;

        wait 0.5;
    }
}


/*
    Troubleshooting aid. zp_input_debug 1 gives every player a readout of
    which buttons the server is actually receiving from them and what state
    they are in, printed only when the set changes.

    Which buttons survive last stand and spectating is the whole difficulty
    behind zp_button_combo_dead, and it varies by build -- this answers it
    in one game rather than by inference.
*/
zp_input_debug_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    last = "";

    for (;;)
    {
        wait 0.25;

        if ( !level.zp.input_debug )
            continue;

        txt = "";

        if ( self usebuttonpressed() )
            txt = txt + "use ";

        if ( self attackbuttonpressed() )
            txt = txt + "fire ";

        if ( self adsbuttonpressed() )
            txt = txt + "aim ";

        if ( self meleebuttonpressed() )
            txt = txt + "melee ";

        if ( self stancebuttonpressed() )
            txt = txt + "stance ";

        if ( self jumpbuttonpressed() )
            txt = txt + "jump ";

        if ( self fragbuttonpressed() )
            txt = txt + "frag ";

        if ( self secondaryoffhandbuttonpressed() )
            txt = txt + "offhand ";

        if ( txt == last )
            continue;

        last = txt;

        if ( txt == "" )
            continue;

        state = "up";

        if ( is_true( self.laststand ) )
            state = "^3laststand";
        else if ( zp_player_is_spectating( self ) )
            state = "^3spectating";

        self iprintln( "^5[input]^7 " + state + "^7: " + txt );
    }
}

/*
    The no half of the button voting. Idle unless a vote is actually open,
    so the combo is inert during normal play -- which is what lets it be a
    combo you could otherwise hit by accident.
*/
zp_vote_no_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( !is_true( level.zp_vote_active ) || !level.zp.button_combo )
            continue;

        combo = self zp_active_combo( level.zp.vote_no_combo, level.zp.vote_no_combo_dead );

        if ( !( self zp_combo_pressed( combo ) ) )
            continue;

        held = 0;
        while ( is_true( level.zp_vote_active ) && ( self zp_combo_pressed( combo ) ) && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time )
            continue;

        zp_cast_vote( self, 0 );

        while ( self zp_combo_pressed( combo ) )
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

    // A vote already running turns any further pause input into a yes.
    if ( is_true( level.zp_vote_active ) )
    {
        zp_cast_vote( player, 1 );
        return;
    }

    if ( !zp_game_ready() )
    {
        if ( isdefined( player ) )
            player iprintln( "^1[Pause]^7 not available yet" );

        return;
    }

    if ( zp_on_cooldown() )
        return;

    // Read the dvars here rather than in zp_do_pause() alone, so a host
    // turning zp_vote on mid-game does not have to pause once first.
    zp_load_config();

    if ( level.zp.vote && !zp_vote_is_moot( player ) )
    {
        if ( zp_vote_locked_out() )
        {
            if ( isdefined( player ) )
                player iprintln( "^1[Pause]^7 a vote just failed -- wait a moment" );

            return;
        }

        level.zp_last_toggle = gettime();
        level thread zp_vote_start( player, "pause" );
        return;
    }

    level.zp_last_toggle = gettime();
    level thread zp_do_pause( player );
}

zp_request_unpause( player )
{
    if ( is_true( level.zp_busy ) || !is_true( level.zp_paused ) )
        return;

    // Same as the pause side: with a vote open, the combo is a ballot.
    if ( is_true( level.zp_vote_active ) )
    {
        zp_cast_vote( player, 1 );
        return;
    }

    /*
        "thread" starts running immediately in GSC, so two toggles landing in
        the same frame -- two players at once, or one player who typed !pause
        while also holding the button combo -- would otherwise pause and then
        instantly unpause again.
    */
    if ( zp_on_cooldown() )
        return;

    zp_load_config();

    if ( level.zp.vote && level.zp.vote_unpause && !zp_vote_is_moot( player ) )
    {
        if ( zp_vote_locked_out() )
        {
            if ( isdefined( player ) )
                player iprintln( "^1[Pause]^7 a vote just failed -- wait a moment" );

            return;
        }

        level.zp_last_toggle = gettime();
        level thread zp_vote_start( player, "unpause" );
        return;
    }

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

    // 4. Lock the players, and keep them locked.
    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] zp_freeze_player();

    if ( level.zp.control_guard )
        level thread zp_player_enforcer();

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
    level thread zp_sound_all( level.zp.pause_sound );

    if ( level.zp.max_pause_time > 0 )
        level thread zp_auto_unpause();

    level.zp_busy = 0;
}


/* ==================================================================
    UNPAUSE
   ================================================================== */

zp_do_unpause( player, label )
{
    level endon( "end_game" );

    level.zp_busy = 1;

    name = "someone";
    if ( isdefined( player ) && isdefined( player.name ) )
        name = player.name;
    else if ( isdefined( label ) )
        name = label;
    else if ( !isdefined( player ) )
        name = "auto-resume";

    zp_msg_all( "^2[Pause]^7 resuming -- requested by ^2" + name );

    // Countdown. Everything stays frozen for the whole countdown, so
    // nobody gets to reposition against held zombies.
    cd = level.zp.countdown;

    // One line for everybody for the duration of the countdown -- the
    // per-player combo hint has nothing to say while nobody may move.
    level.zp_hud_sub_override = "hold still";
    zp_hud_sub_refresh();

    while ( cd > 0 )
    {
        if ( isdefined( level.zp_hud ) )
            level.zp_hud settext( "RESUMING IN " + cd );

        level thread zp_sound_all( level.zp.countdown_sound );
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

    level thread zp_sound_all( level.zp.resume_sound );

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

                if ( level.zp.silence_zombies )
                {
                    z.zp_had_inert = is_true( z.is_inert );
                    z.is_inert = 1;
                    z stopsounds();
                    z stoploopsound();
                }

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

        // Same rule for the inert flag: a zombie that was genuinely inert
        // before the pause -- Tranzit spawns them that way -- keeps it.
        if ( isdefined( z.zp_had_inert ) )
        {
            if ( !is_true( z.zp_had_inert ) )
                z.is_inert = undefined;

            z.zp_had_inert = undefined;
        }
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
    self thread zp_vote_no_watcher();
    self thread zp_input_debug_watcher();

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

    if ( level.zp.vote )
        self iprintln( "^3[Pause]^7 pauses go to a vote -- ^2!yes^7 / ^1!no^7 when one opens" );
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

    if ( level.zp.blur )
        self zp_blur_on();
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
    self zp_blur_off();

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

/*
    The players' half of zp_ai_enforcer(): everything the pause did to a
    player, re-applied on a tick. freezecontrols() has no getter, so this
    cannot check first -- but re-applying a flag that is already set is
    free, and it is the only way to win against a map script that releases
    a player mid-pause (see zp_control_guard in the config).

    Keyed on zp_frozen, which zp_unfreeze_player() clears before it lets
    go, so a tick landing during the thaw cannot re-freeze anybody.
*/
zp_player_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        players = get_players();

        for ( i = 0; i < players.size; i++ )
        {
            p = players[i];

            if ( !isdefined( p ) || !is_true( p.zp_frozen ) )
                continue;

            p freezecontrols( 1 );
            p.ignoreme = 1;

            if ( level.zp.godmode )
                p enableinvulnerability();
        }

        wait 0.1;
    }
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

    zp_hud_free( self.zp_black );
    self.zp_black = undefined;
}

/*
    setblur() is a post-process on the client, not a HUD element, so
    there is nothing to destroy -- it has to be zeroed on the way out.
    Anything else driving the blur (the low-health pain blur) is zeroed
    with it, and re-applies itself afterwards.
*/
zp_blur_on()
{
    if ( is_true( self.zp_blurred ) || level.zp.blur_amount <= 0 )
        return;

    self.zp_blurred = 1;
    self setblur( level.zp.blur_amount, 0.4 );
}

zp_blur_off()
{
    if ( !is_true( self.zp_blurred ) )
        return;

    self.zp_blurred = undefined;
    self setblur( 0, 0.25 );
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

/*
    Place one line of a stacked block. yoff is the line's offset inside the
    block, so a caller lays its lines out once and the slot decides where
    the whole thing lands.

    setpoint()'s first argument is the element's own anchor, and that is
    what sets the text alignment -- "LEFT" hangs the string off its left
    edge so it grows rightward. The left and right slots use that to sit
    flush against their edge instead of staying centred.
*/
/*
    Applied to every element the script makes. The glow is what carries
    the text over a bright skybox, and the fade stops each line snapping
    into place the instant it is created.
*/
/*
    _hud_util's setparent() files every element it creates into
    level.uiparent.children, and destroy() does not take it back out --
    only removechild() does, and nothing calls that for you. Destroying an
    element without detaching it first leaves its slot behind for good, so
    a script that builds and tears down a HUD on every pause and every vote
    walks the server into "exceeded maximum number of parent server script
    variables" and drops it.

    Everything this script makes goes out through here.
*/
zp_hud_free( elem )
{
    if ( !isdefined( elem ) )
        return;

    if ( isdefined( elem.parent ) )
        elem.parent removechild( elem );

    elem destroy();
}

zp_hud_style( elem, alpha )
{
    if ( !isdefined( elem ) )
        return;

    elem.sort = 1000;
    elem.foreground = 1;

    if ( level.zp.hud_glow )
    {
        elem.glowcolor = ( 0, 0, 0 );
        elem.glowalpha = 0.55;
    }

    elem.alpha = 0;
    elem fadeovertime( 0.25 );
    elem.alpha = alpha;
}

/*
    The backing panel anchors its own top edge, unlike the text lines,
    which anchor differently per slot. Doing it separately keeps the slab
    lined up with the block instead of straddling it.
*/
zp_panel_place( elem, position, pad )
{
    if ( position == "top" )
    {
        elem setpoint( "TOP", "TOP", 0, 12 - pad );
        return;
    }

    if ( position == "bottom" )
    {
        elem setpoint( "TOP", "BOTTOM", 0, -124 - pad );
        return;
    }

    if ( position == "middle" )
    {
        elem setpoint( "TOP", "CENTER", 0, -40 - pad );
        return;
    }

    if ( position == "left" )
    {
        elem setpoint( "TOPLEFT", "LEFT", 24 - pad, -46 - pad );
        return;
    }

    if ( position == "right" )
    {
        elem setpoint( "TOPRIGHT", "RIGHT", -24 + pad, -46 - pad );
        return;
    }

    elem setpoint( "TOP", "TOP", 0, 56 - pad );
}

zp_panel_show( position, height )
{
    if ( !level.zp.hud_panel || height <= 0 )
    {
        zp_panel_destroy();
        return;
    }

    // A shader element is sized when it is made, so a block that grew or
    // shrank -- a voter joining, the down line appearing -- rebuilds it
    // rather than resizing.
    if ( isdefined( level.zp_panel ) && level.zp_panel.zp_h == height )
        return;

    zp_panel_destroy();

    /*
        A line's offset is to its middle, not its top, so the slab needs
        more clearance above the block than below it or it clips the top
        of the title.
    */
    pad_top = 20;
    pad_bottom = 10;

    level.zp_panel = createservericon( "black", level.zp.hud_panel_width, int( height + pad_top + pad_bottom ) );
    zp_panel_place( level.zp_panel, position, pad_top );

    // Under the text, which sorts at 1000.
    level.zp_panel.sort = 999;
    level.zp_panel.foreground = 1;
    level.zp_panel.zp_h = height;
    level.zp_panel.alpha = 0;
    level.zp_panel fadeovertime( 0.25 );
    level.zp_panel.alpha = level.zp.hud_panel_alpha;
}

zp_panel_destroy()
{
    if ( isdefined( level.zp_panel ) )
    {
        zp_hud_free( level.zp_panel );
        level.zp_panel = undefined;
    }
}

zp_hud_place( elem, position, yoff )
{
    if ( !isdefined( elem ) )
        return;

    if ( position == "top" )
    {
        elem setpoint( "CENTER", "TOP", 0, 12 + yoff );
        return;
    }

    if ( position == "bottom" )
    {
        elem setpoint( "CENTER", "BOTTOM", 0, -124 + yoff );
        return;
    }

    if ( position == "middle" )
    {
        elem setpoint( "CENTER", "CENTER", 0, -40 + yoff );
        return;
    }

    if ( position == "left" )
    {
        elem setpoint( "LEFT", "LEFT", 24, -46 + yoff );
        return;
    }

    if ( position == "right" )
    {
        elem setpoint( "RIGHT", "RIGHT", -24, -46 + yoff );
        return;
    }

    // center -- the classic banner spot, where the pause HUD has always sat.
    elem setpoint( "CENTER", "TOP", 0, 56 + yoff );
}

/*
    Where each line of the pause banner sits. Every line is centred in its
    own right -- nothing in GSC can measure a rendered string, so two
    elements sharing a line can only be centred on their join, and that
    throws the pair off centre as soon as one side is wider than the other.
    Stacking is the only arrangement that holds in all six slots and for
    any length of name.

    The lines under the clock shift up when zp_hud_timer is off, rather
    than leaving a hole where it would have been.
*/
zp_pause_yoff( line )
{
    if ( line == "clock" )
        return 34;

    if ( line == "name" )
        return 58;

    if ( line == "hint" )
    {
        if ( level.zp.hud_timer )
            return 80;

        return 34;
    }

    // "down"
    if ( level.zp.hud_timer )
        return 104;

    return 58;
}

zp_hud_show()
{
    zp_hud_destroy();

    level.zp_hud = createserverfontstring( "objective", 1.9 );
    zp_hud_place( level.zp_hud, level.zp.hud_position, 0 );
    level.zp_hud.color = ( 1, 0.82, 0.15 );
    zp_hud_style( level.zp_hud, 1 );
    level.zp_hud settext( "GAME PAUSED" );

    if ( level.zp.hud_timer )
    {
        /*
            The clock is a timer element, not text. settext() registers
            every distinct string as a configstring, and a clock rewritten
            once a second exhausts the pool and drops the whole server with
            "G_FindConfigstringIndex: overflow". A timer element is handed
            its value once and counts on the client for free.
        */
        elapsed = int( ( gettime() - level.zp_pause_start ) / 1000 );

        level.zp_hud_clock = createservertimer( "objective", 1.3 );
        zp_hud_place( level.zp_hud_clock, level.zp.hud_position, zp_pause_yoff( "clock" ) );
        level.zp_hud_clock.color = ( 0.85, 0.85, 0.85 );
        zp_hud_style( level.zp_hud_clock, 0.85 );

        if ( level.zp.max_pause_time > 0 )
            level.zp_hud_clock settimer( level.zp.max_pause_time - elapsed );
        else
            level.zp_hud_clock settenthstimerup( elapsed * 10 + 0.1 );

        level.zp_hud_meta = createserverfontstring( "default", 1.0 );
        zp_hud_place( level.zp_hud_meta, level.zp.hud_position, zp_pause_yoff( "name" ) );
        level.zp_hud_meta.color = ( 0.7, 0.7, 0.7 );
        zp_hud_style( level.zp_hud_meta, 0.7 );

        // One string per person who has ever paused, rather than one a second.
        level.zp_hud_meta settext( "paused by " + level.zp_pauser_name );
    }

    // The result of a vote stands in its own slot; only pull it early if
    // this banner is about to land on top of it.
    if ( level.zp.hud_position == level.zp.vote_hud_position )
        zp_vote_outcome_clear();

    level thread zp_hud_sub_updater();
}



/*
    The hint line is the one thing on screen that is not the same for
    everybody: a player who is down is on a different combo, so their line
    has to say so. createfontstring() on a player makes a client element
    rather than a server one, which is what lets each of them read
    differently.
*/
zp_subline_create( position, yoff, scale, alpha )
{
    e = self createfontstring( "default", scale );
    zp_hud_place( e, position, yoff );
    e.color = ( 0.85, 0.85, 0.85 );
    zp_hud_style( e, alpha );

    return e;
}

zp_pause_hint_text( player )
{
    if ( isdefined( level.zp_hud_sub_override ) )
        return level.zp_hud_sub_override;

    if ( !level.zp.button_combo )
        return "type !unpause to resume";

    combo = "crouch_melee";

    if ( isdefined( player ) && zp_player_input_limited( player ) )
        combo = level.zp.button_combo_dead;

    if ( combo == "" )
        return "type !unpause to resume";

    return "!unpause  or  " + zp_combo_label( combo, level.zp.hud_binds );
}

zp_hud_sub_show( player )
{
    if ( !isdefined( player ) )
        return;

    if ( !isdefined( player.zp_hud_sub ) )
        player.zp_hud_sub = player zp_subline_create( level.zp.hud_position, zp_pause_yoff( "hint" ), 1.25, 1 );

    zp_hud_text( player.zp_hud_sub, zp_pause_hint_text( player ) );
}

/*
    Picks up players who joined into a paused game, and anyone whose state
    changed under them. zp_hud_text() only touches an element when the
    string actually differs, so the idle cost is a string compare.
*/
zp_hud_sub_updater()
{
    level endon( "zp_hud_sub_stop" );
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        players = get_players();

        for ( i = 0; i < players.size; i++ )
            zp_hud_sub_show( players[i] );

        zp_down_line_show( level.zp.hud_position, zp_pause_yoff( "down" ), "pause" );

        h = zp_pause_yoff( "hint" ) + 12;

        if ( isdefined( level.zp_down_line ) )
            h = zp_pause_yoff( "down" ) + 10;

        zp_panel_show( level.zp.hud_position, h );

        wait 0.25;
    }
}

/*
    A spectating player's client draws the HUD of whoever it is watching,
    not its own -- so the per-client hint line above never reaches them.
    They read the live player's line instead, which correctly says crouch
    + melee, because that player is alive.

    This line is a server element, which everybody sees including
    spectators, and it only appears while somebody is actually down. That
    makes it redundant for a player in last stand, who can already read
    their own line; reaching the spectators is worth the repetition.
*/
zp_anyone_down()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) && zp_player_input_limited( players[i] ) )
            return 1;
    }

    return 0;
}

zp_down_hint_text( kind )
{
    yes_combo = level.zp.button_combo_dead;
    no_combo = level.zp.vote_no_combo_dead;

    if ( kind == "vote" )
    {
        if ( yes_combo == "" && no_combo == "" )
            return "while down:  ^2!yes^7  /  ^1!no";

        if ( yes_combo == "" )
            return "while down:  ^2!yes^7  /  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";

        if ( no_combo == "" )
            return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes  /  ^1!no";

        return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes  /  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";
    }

    if ( yes_combo == "" )
        return "while down:  type !unpause";

    return "while down:  !unpause  or  " + zp_combo_label( yes_combo, level.zp.hud_binds );
}

zp_down_line_show( position, yoff, kind )
{
    if ( !level.zp.button_combo || isdefined( level.zp_hud_sub_override ) || !zp_anyone_down() )
    {
        zp_down_line_destroy();
        return;
    }

    if ( !isdefined( level.zp_down_line ) )
    {
        level.zp_down_line = createserverfontstring( "default", 1.0 );
        zp_hud_place( level.zp_down_line, position, yoff );
        level.zp_down_line.color = ( 0.85, 0.85, 0.85 );
        zp_hud_style( level.zp_down_line, 0.7 );
    }

    zp_hud_text( level.zp_down_line, zp_down_hint_text( kind ) );
}

zp_down_line_destroy()
{
    if ( isdefined( level.zp_down_line ) )
    {
        zp_hud_free( level.zp_down_line );
        level.zp_down_line = undefined;
    }
}

zp_hud_sub_refresh()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
        zp_hud_sub_show( players[i] );
}

zp_hud_sub_destroy()
{
    level notify( "zp_hud_sub_stop" );
    level.zp_hud_sub_override = undefined;
    zp_down_line_destroy();
    zp_panel_destroy();

    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( isdefined( p ) && isdefined( p.zp_hud_sub ) )
        {
            zp_hud_free( p.zp_hud_sub );
            p.zp_hud_sub = undefined;
        }
    }
}

zp_hud_destroy()
{
    if ( isdefined( level.zp_hud ) )
    {
        zp_hud_free( level.zp_hud );
        level.zp_hud = undefined;
    }

    if ( isdefined( level.zp_hud_meta ) )
    {
        zp_hud_free( level.zp_hud_meta );
        level.zp_hud_meta = undefined;
    }

    if ( isdefined( level.zp_hud_clock ) )
    {
        zp_hud_free( level.zp_hud_clock );
        level.zp_hud_clock = undefined;
    }

    zp_hud_sub_destroy();
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
    VOTING

    Ballots live on the players as .zp_vote -- 1 yes, 0 no, undefined for
    not voted yet -- so a disconnect takes its vote with it and every
    tally is recomputed from whoever is actually in the game.

    The watcher owns the lifecycle. It is keyed on a serial rather than an
    endon, because zp_vote_finish() runs inside it and ending the vote
    from in there would kill the thread halfway through its own cleanup.
   ================================================================== */

/*
    Who the maths is done over. Last stand still counts -- a downed player
    is alive and can still vote from chat; only someone bled out and
    spectating drops out of the electorate, and only with vote_alive_only.
*/
zp_vote_eligible( player )
{
    if ( !isdefined( player ) )
        return 0;

    if ( !level.zp.vote_alive_only )
        return 1;

    return !zp_player_is_spectating( player );
}

zp_vote_electorate()
{
    players = get_players();
    n = 0;

    for ( i = 0; i < players.size; i++ )
    {
        if ( zp_vote_eligible( players[i] ) )
            n++;
    }

    return n;
}

zp_vote_needed()
{
    n = zp_vote_electorate();

    if ( n < 1 )
        return 1;

    needed = level.zp.vote_min;
    pct = int( ceil( n * level.zp.vote_percent / 100 ) );

    if ( pct > needed )
        needed = pct;

    // Never ask for more votes than there are people to cast them.
    if ( needed > n )
        needed = n;

    if ( needed < 1 )
        needed = 1;

    return needed;
}

/*
    A vote the initiator alone already carries is a pause with extra steps
    -- solo play, or any lobby whose threshold lands on one.
*/
zp_vote_is_moot( player )
{
    if ( !level.zp.vote_initiator_yes )
        return 0;

    // A spectator's automatic yes does not count, so it cannot carry a
    // vote on its own however small the room is.
    if ( !zp_vote_eligible( player ) )
        return 0;

    return zp_vote_needed() <= 1;
}

zp_vote_locked_out()
{
    if ( level.zp.vote_lockout <= 0 )
        return 0;

    if ( level.zp_vote_last_fail == 0 )
        return 0;

    return gettime() - level.zp_vote_last_fail < level.zp.vote_lockout * 1000;
}

zp_vote_count( want )
{
    players = get_players();
    c = 0;

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( isdefined( p ) && isdefined( p.zp_vote ) && p.zp_vote == want && zp_vote_eligible( p ) )
            c++;
    }

    return c;
}

zp_vote_clear_ballots()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i].zp_vote = undefined;
    }
}

zp_cast_vote( player, want )
{
    if ( !is_true( level.zp_vote_active ) || !isdefined( player ) )
        return;

    if ( isdefined( player.zp_vote ) && player.zp_vote == want )
        return;

    player.zp_vote = want;

    if ( want )
        player iprintln( "^2[Pause]^7 your vote: ^2yes" );
    else
        player iprintln( "^1[Pause]^7 your vote: ^1no" );
}

zp_vote_start( player, kind )
{
    level.zp_vote_serial = level.zp_vote_serial + 1;
    level.zp_vote_active = 1;
    level.zp_vote_kind = kind;
    level.zp_vote_end_time = gettime() + int( level.zp.vote_time * 1000 );
    level.zp_vote_initiator = player;
    level.zp_vote_provisional = 0;

    level.zp_vote_name = "someone";
    if ( isdefined( player ) && isdefined( player.name ) )
        level.zp_vote_name = player.name;

    zp_vote_clear_ballots();

    /*
        The vote HUD stands in for the pause HUD while it is open. They
        would otherwise overlap in any shared slot, and the pause HUD's
        "crouch + melee to resume" contradicts the vote, where that same
        combo is a yes.
    */
    zp_vote_outcome_clear();
    zp_hud_destroy();

    if ( level.zp.vote_initiator_yes && isdefined( player ) )
        player.zp_vote = 1;

    verb = "pause";
    if ( kind == "unpause" )
        verb = "resume";

    zp_msg_all( "^3[Pause]^7 ^3" + level.zp_vote_name + "^7 called a vote to " + verb );

    // The HUD spells out how to vote; only repeat it in chat without one.
    if ( !level.zp.vote_hud )
    {
        voters = get_players();

        for ( i = 0; i < voters.size; i++ )
        {
            if ( isdefined( voters[i] ) )
                voters[i] iprintln( "^3[Pause]^7 " + zp_vote_hint_text( voters[i] ) );
        }
    }

    if ( level.zp.vote_hold && kind == "pause" && !is_true( level.zp_paused ) )
    {
        level.zp_vote_provisional = 1;
        level thread zp_do_pause( player );
    }

    level thread zp_vote_watcher( level.zp_vote_serial );
}

zp_vote_watcher( serial )
{
    level endon( "end_game" );

    for (;;)
    {
        if ( !is_true( level.zp_vote_active ) || level.zp_vote_serial != serial )
            return;

        needed = zp_vote_needed();
        yes = zp_vote_count( 1 );
        no = zp_vote_count( 0 );
        n = zp_vote_electorate();

        left = level.zp_vote_end_time - gettime();
        secs = int( left / 1000 );

        if ( secs < 0 )
            secs = 0;

        zp_vote_hud_update( yes, needed, secs );

        if ( yes >= needed )
        {
            zp_vote_finish( 1, yes, needed );
            return;
        }

        // Enough noes that everyone left saying yes still would not carry it.
        if ( n - no < needed )
        {
            zp_vote_finish( 0, yes, needed );
            return;
        }

        if ( left <= 0 )
        {
            zp_vote_finish( 0, yes, needed );
            return;
        }

        wait 0.1;
    }
}

zp_vote_finish( passed, yes, needed )
{
    kind = level.zp_vote_kind;
    initiator = level.zp_vote_initiator;
    provisional = is_true( level.zp_vote_provisional );

    zp_vote_stop( 1 );

    if ( passed )
    {
        zp_msg_all( "^2[Pause]^7 vote passed ^2" + yes + "^7/" + needed );
        zp_vote_outcome( "^2VOTE PASSED   " + yes + "^7 / " + needed );

        if ( kind == "unpause" )
        {
            level.zp_last_toggle = gettime();
            level thread zp_do_unpause( initiator );
        }
        else if ( !is_true( level.zp_paused ) )
        {
            level.zp_last_toggle = gettime();
            level thread zp_do_pause( initiator );
        }
        else
        {
            // zp_vote_hold already paused us on the way in; all that is
            // left is to give the pause HUD back.
            level thread zp_hud_show();
        }

        return;
    }

    level.zp_vote_last_fail = gettime();
    zp_msg_all( "^1[Pause]^7 vote failed ^1" + yes + "^7/" + needed );
    zp_vote_outcome( "^1VOTE FAILED   " + yes + "^7 / " + needed );

    // zp_vote_hold pauses on the way in, so a failed vote has to hand the
    // game back.
    if ( provisional && is_true( level.zp_paused ) )
    {
        level.zp_last_toggle = gettime();
        level thread zp_do_unpause( undefined, "vote failed" );
        return;
    }

    // A resume vote that failed leaves the game paused, so the pause HUD
    // comes back.
    if ( is_true( level.zp_paused ) )
        level thread zp_hud_show();
}

zp_vote_stop( keep_title )
{
    level.zp_vote_serial = level.zp_vote_serial + 1;
    level.zp_vote_active = 0;
    level.zp_vote_provisional = 0;
    level.zp_vote_initiator = undefined;

    zp_vote_clear_ballots();

    // Keeping the title is what lets zp_vote_finish() leave the result
    // standing on it for a moment. Everything under it goes either way.
    if ( is_true( keep_title ) )
    {
        zp_vote_sub_destroy();
        zp_down_line_destroy();
        zp_vote_rows_destroy();
        return;
    }

    zp_vote_hud_destroy();
}

/*
    A vote that just vanishes leaves the result in the chat feed, which is
    the one place nobody is looking during a round. This holds it on the
    tally instead, where their eyes already are.
*/
zp_vote_outcome( txt )
{
    if ( !isdefined( level.zp_vote_hud ) || level.zp.vote_result_time <= 0 )
    {
        zp_vote_hud_destroy();
        return;
    }

    // The clock has nothing left to count.
    if ( isdefined( level.zp_vote_clock ) )
    {
        zp_hud_free( level.zp_vote_clock );
        level.zp_vote_clock = undefined;
    }

    zp_hud_text( level.zp_vote_hud, txt );
    level thread zp_vote_outcome_hold();
}

zp_vote_outcome_hold()
{
    level endon( "end_game" );
    level endon( "zp_vote_outcome_clear" );

    wait( level.zp.vote_result_time );

    zp_vote_hud_destroy();
}

zp_vote_outcome_clear()
{
    level notify( "zp_vote_outcome_clear" );
    zp_vote_hud_destroy();
}


/* ==================================================================
    VOTE HUD

    Server hud elements, the same as the pause HUD: created host-side and
    replicated, so a player running no scripts at all still sees the tally
    and which buttons to hold.
   ================================================================== */

zp_hud_text( elem, txt )
{
    if ( !isdefined( elem ) )
        return;

    // settext every tick would be pointless network traffic.
    if ( isdefined( elem.zp_txt ) && elem.zp_txt == txt )
        return;

    elem.zp_txt = txt;
    elem settext( txt );
}

/*
    No clock in here. The seconds live on their own timer element -- every
    distinct string handed to settext() takes a configstring, and a line
    rewritten once a second burns the pool.
*/
zp_vote_hint_text( player, binds )
{
    if ( !level.zp.button_combo )
        return "^2!yes^7     ^1!no";

    yes_combo = "crouch_melee";
    no_combo = level.zp.vote_no_combo;

    // Down on the floor or spectating: show the combo that still works
    // for this player rather than the one everybody else is using.
    if ( isdefined( player ) && zp_player_input_limited( player ) )
    {
        yes_combo = level.zp.button_combo_dead;
        no_combo = level.zp.vote_no_combo_dead;
    }

    if ( yes_combo == "" && no_combo == "" )
        return "^2!yes^7     ^1!no";

    if ( yes_combo == "" )
        return "^2!yes^7     ^1" + zp_combo_label( no_combo, binds ) + "^7 = no";

    if ( no_combo == "" )
        return "^2" + zp_combo_label( yes_combo, binds ) + "^7 = yes     ^1!no";

    return "^2" + zp_combo_label( yes_combo, binds ) + "^7 = yes     ^1" + zp_combo_label( no_combo, binds ) + "^7 = no";
}

zp_vote_sub_show( player )
{
    if ( !isdefined( player ) )
        return;

    if ( !isdefined( player.zp_vote_sub ) )
        player.zp_vote_sub = player zp_subline_create( level.zp.vote_hud_position, 52, 1.1, 0.75 );

    zp_hud_text( player.zp_vote_sub, zp_vote_hint_text( player, level.zp.hud_binds ) );
}

zp_vote_sub_destroy()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( isdefined( p ) && isdefined( p.zp_vote_sub ) )
        {
            zp_hud_free( p.zp_vote_sub );
            p.zp_vote_sub = undefined;
        }
    }
}

zp_vote_hud_update( yes, needed, secs )
{
    if ( !level.zp.vote_hud )
        return;

    if ( !isdefined( level.zp_vote_hud ) )
    {
        // The pause HUD is taken down for the duration of a vote, so these
        // two blocks never share the screen and can both use any slot.
        level.zp_vote_hud = createserverfontstring( "objective", 1.5 );
        zp_hud_place( level.zp_vote_hud, level.zp.vote_hud_position, 0 );
        level.zp_vote_hud.color = ( 1, 0.82, 0.15 );
        zp_hud_style( level.zp_vote_hud, 0.9 );

        // Handed the remaining seconds once; it counts down on the client.
        level.zp_vote_clock = createservertimer( "objective", 1.2 );
        zp_hud_place( level.zp_vote_clock, level.zp.vote_hud_position, 28 );
        level.zp_vote_clock.color = ( 1, 0.82, 0.15 );
        zp_hud_style( level.zp_vote_clock, 0.9 );
        level.zp_vote_clock settimer( secs );
    }

    if ( level.zp_vote_kind == "unpause" )
        title = "RESUME VOTE   ^2" + yes + "^7 / " + needed;
    else
        title = "PAUSE VOTE   ^2" + yes + "^7 / " + needed;

    zp_hud_text( level.zp_vote_hud, title );

    // Recolouring an element costs nothing, unlike rewriting its text.
    if ( isdefined( level.zp_vote_clock ) )
    {
        if ( secs <= 5 )
            level.zp_vote_clock.color = ( 1, 0.3, 0.3 );
        else
            level.zp_vote_clock.color = ( 1, 0.82, 0.15 );
    }

    players = get_players();

    for ( i = 0; i < players.size; i++ )
        zp_vote_sub_show( players[i] );

    zp_down_line_show( level.zp.vote_hud_position, 74, "vote" );

    zp_vote_hud_rows();

    h = 64;

    if ( isdefined( level.zp_down_line ) )
        h = 84;

    if ( level.zp.vote_show_voters && players.size > 0 )
        h = 94 + players.size * 15;

    zp_panel_show( level.zp.vote_hud_position, h );
}

zp_vote_hud_rows()
{
    if ( !isdefined( level.zp_vote_rows ) )
        level.zp_vote_rows = [];

    if ( !level.zp.vote_show_voters )
    {
        zp_vote_rows_destroy();
        return;
    }

    players = get_players();

    // Somebody left: rebuild rather than leave a stale row on screen.
    if ( level.zp_vote_rows.size > players.size )
        zp_vote_rows_destroy();

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( !isdefined( p ) )
            continue;

        if ( !isdefined( level.zp_vote_rows[i] ) )
        {
            e = createserverfontstring( "default", 1.0 );
            zp_hud_place( e, level.zp.vote_hud_position, 94 + i * 15 );
            zp_hud_style( e, 0.7 );
            level.zp_vote_rows[i] = e;
        }

        name = "player";
        if ( isdefined( p.name ) )
            name = p.name;

        if ( !zp_vote_eligible( p ) )
            txt = "^7" + name + "   ^3spectating";
        else if ( !isdefined( p.zp_vote ) )
            txt = "^7" + name + "   ^3-";
        else if ( p.zp_vote == 1 )
            txt = "^7" + name + "   ^2yes";
        else
            txt = "^7" + name + "   ^1no";

        zp_hud_text( level.zp_vote_rows[i], txt );
    }
}

zp_vote_rows_destroy()
{
    if ( !isdefined( level.zp_vote_rows ) )
    {
        level.zp_vote_rows = [];
        return;
    }

    // Same reasoning as the config struct: an array is a parent variable,
    // and this is reached on a tick whenever the voter list is off.
    if ( level.zp_vote_rows.size == 0 )
        return;

    keys = getarraykeys( level.zp_vote_rows );

    for ( i = 0; i < keys.size; i++ )
    {
        if ( isdefined( level.zp_vote_rows[ keys[i] ] ) )
            zp_hud_free( level.zp_vote_rows[ keys[i] ] );
    }

    level.zp_vote_rows = [];
}

zp_vote_hud_destroy()
{
    if ( isdefined( level.zp_vote_hud ) )
    {
        zp_hud_free( level.zp_vote_hud );
        level.zp_vote_hud = undefined;
    }

    if ( isdefined( level.zp_vote_clock ) )
    {
        zp_hud_free( level.zp_vote_clock );
        level.zp_vote_clock = undefined;
    }

    zp_vote_sub_destroy();
    zp_down_line_destroy();
    zp_panel_destroy();
    zp_vote_rows_destroy();
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

    zp_vote_stop();
    zp_hud_destroy();
    zp_ai_thaw();

    players = get_players();
    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( !isdefined( p ) )
            continue;

        p zp_blackout_off();
        p zp_blur_off();

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
