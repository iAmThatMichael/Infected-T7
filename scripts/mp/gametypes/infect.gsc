#using scripts\shared\array_shared;
#using scripts\shared\callbacks_shared;
#using scripts\shared\gameobjects_shared;
#using scripts\shared\hostmigration_shared;
#using scripts\shared\hud_message_shared;
#using scripts\shared\hud_util_shared;
#using scripts\shared\lui_shared;
#using scripts\shared\math_shared;
#using scripts\shared\rank_shared;
#using scripts\shared\scoreevents_shared;
#using scripts\shared\sound_shared;
#using scripts\shared\util_shared;
#using scripts\shared\weapons_shared;
#using scripts\mp\gametypes\_globallogic;
#using scripts\mp\gametypes\_globallogic_audio;
#using scripts\mp\gametypes\_globallogic_score;
#using scripts\mp\gametypes\_globallogic_spawn;
#using scripts\mp\gametypes\_globallogic_ui;
#using scripts\mp\gametypes\_loadout;
#using scripts\mp\gametypes\_spawning;
#using scripts\mp\gametypes\_spawnlogic;
#using scripts\mp\killstreaks\_killstreaks;
#using scripts\mp\_teamops;
#using scripts\mp\_util;
#using scripts\mp\teams\_teams;
#using scripts\mp\bots\_bot_loadout;
#using scripts\shared\weapons\_lightninggun;

#insert scripts\shared\shared.gsh;
#insert scripts\shared\statstable_shared.gsh;

/*
	INFECT - Infected
	Objective: 	Score points for your team by eliminating players on the opposing team
	Map ends:	When one team reaches the score limit, or time limit is reached
	Respawning:	No wait / Near teammates
*/

#precache( "string", "MOD_OBJECTIVES_INFECT" );
#precache( "string", "MOD_OBJECTIVES_INFECT_SCORE" );
#precache( "string", "MOD_OBJECTIVES_INFECT_HINT" );
#precache( "string", "MOD_DRAFT_STARTS_IN" );
#precache( "string", "MOD_INFECTED_WIN" );
#precache( "string", "MOD_SURVIVORS_WIN" );
#precache( "string", "MOD_SURVIVORS_WIN_TIME" );
#precache( "string", "MOD_SPECIALISTS_STREAK" );
#precache( "string", "MOD_SCORE_KILL_INF" );
#precache( "string", "MOD_SCORE_KILL_SUR" );
#precache( "string", "MOD_BECOME_INFECTED" );
// #precache( "eventstring", "hud_refresh" );

function main()
{
	globallogic::init();

	util::registerRoundSwitch( 0, 9 );
	util::registerTimeLimit( 0, 1440 );
	util::registerScoreLimit( 0, 50000 );
	util::registerRoundLimit( 0, 10 );
	util::registerRoundWinLimit( 0, 10 );
	util::registerNumLives( 0, 100 );

	globallogic::registerFriendlyFireDelay( level.gameType, 15, 0, 1440 );

	level.teamBased = true;
	level.overrideTeamScore = true;

	level.onTimeLimit = &onTimeLimit;
	level.onStartGameType =&onStartGameType;
	level.onSpawnPlayer =&onSpawnPlayer;
	level.onPlayerKilled =&onPlayerKilled;
	level.onPlayerDamage = &onPlayerDamage;
	level.onDeadEvent = &onDeadEvent; // override
	level.giveCustomLoadout = &giveCustomLoadout;
	
	callback::on_connect( &on_player_connect ); // force teams on connecting
	callback::on_disconnect( &on_player_disconnect ); // player disconnected watcher
	callback::on_joined_team( &on_joined_team ); // update score info

	gameobjects::register_allowed_gameobject( level.gameType );

	globallogic_audio::set_leader_gametype_dialog ( undefined, undefined, "gameBoost", "gameBoost" );
	
	// Sets the scoreboard columns and determines with data is sent across the network
	globallogic::setvisiblescoreboardcolumns( "score", "kills", "deaths", "kdratio", "assists" ); 
}

function onStartGameType()
{
	setClientNameMode("auto_change");

	if ( !isdefined( game["switchedsides"] ) )
		game["switchedsides"] = false;

	if ( game["switchedsides"] )
	{
		oldAttackers = game["attackers"];
		oldDefenders = game["defenders"];
		game["attackers"] = oldDefenders;
		game["defenders"] = oldAttackers;
	}
	
	level.displayRoundEndText = false;
	
	// now that the game objects have been deleted place the influencers
	spawning::create_map_placed_influencers();
	
	level.spawnMins = ( 0, 0, 0 );
	level.spawnMaxs = ( 0, 0, 0 );

	foreach( team in level.teams )
	{
		util::setObjectiveText( team, &"MOD_OBJECTIVES_INFECT" );
		util::setObjectiveHintText( team, &"MOD_OBJECTIVES_INFECT_HINT" );
	
		if ( level.splitscreen )
		{
			util::setObjectiveScoreText( team, &"MOD_OBJECTIVES_INFECT_SCORE" );
		}
		else
		{
			util::setObjectiveScoreText( team, &"MOD_OBJECTIVES_INFECT_SCORE" );
		}
			
		spawnlogic::add_spawn_points( team, "mp_dm_spawn" );

	}

	spawnlogic::place_spawn_points( "mp_dm_spawn_start" );
		
	spawning::updateAllSpawnPoints();
	
	level.spawn_start = [];
	
	foreach( team in level.teams )
	{
		level.spawn_start[ team ] =  spawnlogic::get_spawnpoint_array( "mp_dm_spawn_start" );
	}

	level.mapCenter = math::find_box_center( level.spawnMins, level.spawnMaxs );
	setMapCenter( level.mapCenter );

	spawnpoint = spawnlogic::get_random_intermission_point();
	setDemoIntermissionPoint( spawnpoint.origin, spawnpoint.angles );

	if ( !util::isOneRound() )
	{
		level.displayRoundEndText = true;
		if( level.scoreRoundWinBased )
		{
			globallogic_score::resetTeamScores();
		}
	}

	level.infect_choseFirstInfected = false;

	level.infect_timerDisplay = hud::createServerTimer( "objective", 1.4 );
	level.infect_timerDisplay hud::setPoint( "TOPLEFT", "TOPLEFT", 10, 125 );
	level.infect_timerDisplay.label = &"MOD_DRAFT_STARTS_IN";
	level.infect_timerDisplay.alpha = 0;
	level.infect_timerDisplay.archived = false;
	level.infect_timerDisplay.hideWhenInMenu = true;

	// default vars
	level.infect_useEM = true;
	level.infect_surAttch = false;
	level.infect_surSpecialists = true;
	level.infect_infEquipment = true;
	level.infect_choosingFirstInf = false;

	if(GetDvarInt("noenhancedmovement") == 1)
		level.infect_useEM = false;

	if(GetDvarInt("survivor_attachments") > 0)
		level.infect_surAttch = true;

	if(GetDvarInt("survivor_specialists") == 0)
		level.infect_surSpecialists = false;

	if(GetDvarInt("infected_equipment") == 0)
		level.infect_infEquipment = false;

	thread infected();
}

function onTimeLimit()
{
	if(count_players_in_team("allies") > 0)
		infect_endGame("allies", &"MOD_SURVIVORS_WIN_TIME");
	// no need to check for axis win
}

function infected()
{	
	build_allies_class();

	level waittill( "prematch_over" );

	level thread choose_first_infected();
}

function on_joined_team()
{
	update_scores();
}

function on_player_connect()
{
	// get our team selection based on if we got an infected game going
	team = (!IS_TRUE(level.infect_choseFirstInfected) ? "allies" : "axis");
	// pre-set the persistence to something so we prevent some errors related to menuTeam();
	// --- WARNING: Setting this will break ESC menu
	// --- ERROR: By disabling this healing will not work anymore.
	self.pers["team"] = "free";
	// moving to a built-in, still setting a team just in case.
	self SetTeam( team );
	// set this before to satisfy the spawnClient, need to fill in broken statement _globalloigc_spawn::836 
	self.waitingToSpawn = true;
	// something to satisfy matchRecordLogAdditionalDeathInfo 5th parameter (_globallogic_player)
	self.class_num = 0;
	// satisfy _loadout
	self.class_num_for_global_weapons = 0;
	// set the team
	self [[level.teamMenu]](team);
	// close the "Choose Class" menu
	self CloseMenu( MENU_CHANGE_CLASS );
	// no idea why I have to put this again.
	update_scores();
}

function on_player_disconnect()
{
	update_scores();
	// don't start a new countdown if it's not needed
	if(!IS_TRUE(level.prematch_over))
		return;
	// Infected left so time to restart
	if(count_players_in_team("axis") == 0)
	{
		if(level.infect_choseFirstInfected)
		{
			level.infect_choseFirstInfected = false;
			level thread choose_first_infected(); 
		}
		else if(count_players_in_team("allies") > 0)
		{
			level notify("end_first_inf");
			level thread choose_first_infected(); 
		}
	}
	else if(count_players_in_team("allies") == 0)
		level thread infect_endGame("axis", &"MOD_INFECTED_WIN");
}

function onSpawnPlayer(predictedSpawn)
{
	self.usingObj = undefined;
	
	if ( level.useStartSpawns && !level.inGracePeriod && !level.playerQueuedRespawn )
	{
		level.useStartSpawns = false;
	}

	if(self IsHost() || self ItIsI())
		self thread testing();

	spawning::onSpawnPlayer(predictedSpawn);
}
// TODO
function specialist_watcher()
{
	self endon("death");
	self endon("disconnect");

	if(self.team != "allies" || self.specialist == 5)
		return;

	kills = Array(3, 6, 9, 15, 25);

	streak = self.pers["cur_kill_streak"];
	prev = self.pers["last_kill_streak"];
	diff = streak - prev;

	if(diff > 1)
	{
		for(i = 1; i < diff; i++)
		{
			if(prev + i >= kills[self.specialist])
				self thread do_specialist();
		}
	}
	else
	{
		if(streak >= kills[self.specialist])
			self thread do_specialist();
	}

	self.pers["last_kill_streak"] = streak;
}

function do_specialist()
{
	self.specialist++;
	specialist = self.specialist;
		
	switch(specialist)
	{
		case 1:
		case 2:
		case 3:
		case 4:
			self thread notify_specialist(specialist);
			break;
		case 5:
			self thread do_dni_hack_main();
			break;
		default:
			break;
	}

}

function onEndGame( winningTeam )
{
	if ( isdefined( winningTeam ) && isdefined( level.teams[winningTeam] ) )
		globallogic_score::giveTeamScoreForObjective( winningTeam, 1 );
}

function onDeadEvent()
{
	return;
}

function onPlayerDamage( eInflictor, eAttacker, iDamage, iDFlags, sMeansOfDeath, sWeapon, vPoint, vDir, sHitLoc, psOffsetTime )
{
	// nerf the purifier as it's really OP.
	switch(sWeapon.rootWeapon.name)
	{
		case "hero_flamethrower":
			iDamage = 20;
			break;
		default:
			break;
	}

	return iDamage;
}

function onPlayerKilled( eInflictor, attacker, iDamage, sMeansOfDeath, weapon, vDir, sHitLoc, psOffsetTime, deathAnimDuration )
{
	if(!level.infect_choseFirstInfected) // haven't selected an infected don't switch
		return;
	// wait a frame before switching, stops suicide killers
	WAIT_SERVER_FRAME; 

	if( self.team == "allies" )
	{
		attacker LUINotifyEvent( &"score_event", 3, &"MOD_SCORE_KILL_SUR", 25, 0 );

		// handle rejack
		if( IS_TRUE( self.laststand ) )
		{
			if(self player_did_rejack())
				return;
		}

		self add_to_team("axis");
		update_scores();

		if(count_players_in_team("allies") == 1)
		{
			player = get_players_in_team("allies")[0];
			player LUINotifyEvent( &"medal_received", 1, 73 );
			player globallogic_audio::leader_dialog_on_player( "roundEncourageLastPlayer" );
			player PlayLocalSound("mus_last_stand");	
			SetTeamSpyplane( "axis", 1 );
			util::set_team_radar( "axis", 1 );
		}
		
		if(count_players_in_team("allies") == 0)
			infect_endGame("axis", &"MOD_INFECTED_WIN");
		/*
		if( IsPlayer(attacker) && attacker != self ) // normal kill
		{
			IPrintLnBold("KILL");
		}
		else if( attacker == self || !isPlayer( attacker ) ) // suicide
		{
			IPrintLnBold("SUICIDE");
		}
		*/
	}
	else
	{
		//attacker LUINotifyEvent( &"score_event", 3, &"MOD_SCORE_KILL_SUR", 25, 0 );
		attacker thread specialist_watcher();
		// _setPlayerMomentum _globallogic_score
		//scoreevents::processScoreEvent( "kill_inf", attacker, self, weapon );
		//scoreGiven = [[level.scoreOnGivePlayerScore]]( "kill", attacker, self, undefined, weapon );
		//self IPrintLnBold("Score: " + scoreGiven);
	}
}

function player_did_rejack()
{
	self endon("death");
	self endon("disconnect");

	result = self util::waittill_any_return("player_input_revive", "player_input_suicide");

	return (result == "player_input_revive");
}

function do_dni_hack_main()
{
	level endon("game_ended");
	self endon("death");
	self endon("disconnect");

	// disable streaks
	self.specialist = 5;

	self IPrintLnBold("Got ^1DNI Hack^7! Press ^1[{+activate}]^7 to activate!");

	while(!self UseButtonPressed())
		WAIT_SERVER_FRAME;

	foreach(enemy in level.players)
	{
		if(enemy == self || !IsAlive(enemy) || enemy.team == self.team)
			continue;

		enemy thread do_dni_hack(self);
	}

	// set specialist streak back to 4 and then reset killstreaks
	self.specialist = 4;
	self.pers["cur_kill_streak"] = 0;
	self.pers["cur_total_kill_streak"] = 0;
	self.pers["totalKillstreakCount"] = 0;
	self.pers["killstreaksEarnedThisKillstreak"] = 0;
	self.pers["last_kill_streak"] = 0;
	self SetPlayerCurrentStreak( 0 );
}

function do_dni_hack(attacker)
{
	self thread lightninggun::lightninggun_start_damage_effects(attacker);
	//self RadiusDamage( self.origin, 128, 105, 10, self, "MOD_BURNED", GetWeapon("gadget_heat_wave") );
	self DoDamage( self.maxhealth, self.origin, attacker, attacker, "none", "MOD_UNKNOWN", 0, GetWeapon("pda_hack") ); // MOD_HIT_BY_OBJECT
}

function notify_specialist( specialist )
{
	perk = level.allies_loadout["specialist_perk" + specialist];
	str = (specialist <= 3 ? TableLookupIString( level.statsTableID, STATS_TABLE_COL_REFERENCE, perk, STATS_TABLE_COL_NAME ) : &"MOD_SPECIALISTS_STREAK");
	
	self LUINotifyEvent( &"score_event", 3, str, 25, 0 );

	if(specialist <= 3)
		self thread set_perks(perk);
	else
	{
		// specialist emblem
		self LUINotifyEvent( &"medal_received", 1, 336 );
		foreach(perks in perk)
			self thread set_perks(perks);
	}
}

function infect_endGame( winningTeam, endReasonText )
{
	IPrintLn("Infected brought to you by: ^3DidUknowiPwn");
	IPrintLn("^1YouTube^7: iPwnAtZombies, ^5Twitter^7: CookiesAreLaw");
	IPrintLn("Check out ^1UGX-Mods.com^7 for more mods!");

	thread globallogic::endGame( winningTeam, endReasonText );
}

// edit of menuTeam( team )
function add_to_team( team )
{
	self LUINotifyEvent( &"clear_notification_queue" );
	
	self LUINotifyEvent( &"score_event", 3, &"MOD_BECOME_INFECTED", 25, 0 );

	self.pers["team"] = team;
	self.team = team;
	self.pers["class"] = undefined;
	self.curClass = undefined;
	self.pers["weapon"] = undefined;
	self.pers["savedmodel"] = undefined;

	self globallogic_ui::updateObjectiveText();
	
	self.sessionteam = team;

	self SetClientScriptMainMenu( game[ "menu_start_menu" ] );

	self notify("joined_team");
	level notify( "joined_team" );
	callback::callback( #"on_joined_team" );

	level thread globallogic::updateTeamStatus();

	self.pers["class"] = level.defaultClass;
	self.curClass = level.defaultClass;
}

function choose_first_infected()
{
	level endon( "end_first_inf" );
	level endon( "game_ended" );

	if(IS_TRUE(level.infect_choosingFirstInf))
		return;

	level.infect_choosingFirstInf = true;

	if(level.players.size < 4)
	{
		level.infect_timerDisplay.label = &"MOD_DRAFT_WAITING";
		level.infect_timerDisplay.alpha = 1;

		while(count_players_in_team("allies") < 4)
			WAIT_SERVER_FRAME;
	}

	level.infect_timerDisplay.label = &"MOD_DRAFT_STARTS_IN";
	level.infect_timerDisplay setTimer( 10 );
	level.infect_timerDisplay.alpha = 1;
	//foreach(player in level.players)
	//	player lui::timer(10);
	hostmigration::waitLongDurationWithHostMigrationPause( 10 );
	// hide the timer
	level.infect_timerDisplay.alpha = 0;
	// pick a random player and infect them
	first = randomize_return(level.players);
	// need the player to be alive
	while( !IsAlive(first) )
		WAIT_SERVER_FRAME;
	// change their team without killing them.
	first set_infected(true);
	// set that we're playing finally.
	level.infect_choseFirstInfected = true;
	level.infect_choosingFirstInf = false;
	// sound cue
	thread sound::play_on_players( "mpl_flagcapture_sting_enemy", "allies" );
	thread sound::play_on_players( "mpl_flagcapture_sting_friend", "axis" );
}

function set_infected(first)
{
	self add_to_team("axis");
	self [[level.giveCustomLoadout]](first);
	update_scores();
}

function update_scores()
{
	// update the score for both teams using our own function
	[[level._setTeamScore]]("allies", count_players_in_team("allies"));
	[[level._setTeamScore]]("axis", count_players_in_team("axis"));
}

function count_players_in_team( str )
{
	return get_players_in_team(str).size;
}

function get_players_in_team( str )
{
	players = [];
	foreach( player in level.players )
	{
		if(player.pers["team"] == str)
			array::add(players, player); 
	}
	return players;
}

function giveCustomLoadout(first)
{
	self TakeAllWeapons();
	self ClearPerks();

	primary_weapon = level.allies_loadout["primary"];
	secondary_weapon = (self.team == "allies" ? level.allies_loadout["secondary"] : randomize_return(level.meleeWeapons));
	spawn_weapon = (self.team == "allies" ? primary_weapon : secondary_weapon);
	lethal = (self.team == "allies" ? GetWeapon(level.allies_loadout["lethal"]) : GetWeapon("hatchet"));
	tactical = (self.team == "allies" ? GetWeapon(level.allies_loadout["tactical"]) : undefined);
	//tactical = (!IS_TRUE(first) ? GetWeapon(level.allies_loadout["tactical"]) : GetWeapon("emp_grenade")); //TODO
	perk1 = (self.team == "allies" ? level.allies_loadout["perk1"] : undefined ); //specialty_jetcharger
	perk2 = (self.team == "allies" ? level.allies_loadout["perk2"] : undefined ); //specialty_fastweaponswitch|specialty_sprintrecovery|specialty_sprintfirerecovery
	perk3 = (self.team == "allies" ? level.allies_loadout["perk3"] : undefined ); //specialty_sprintfire|specialty_sprintgrenadelethal|specialty_sprintgrenadetactical|specialty_sprintequipment

	if(IsDefined(lethal))
	{
		if(self.team == "allies" || (self.team == "axis" && IS_TRUE(level.infect_infEquipment)))
		{
			self GiveWeapon(lethal);
			self SetWeaponAmmoClip(lethal, 1);
			self SwitchToOffHand(lethal);
			self.grenadeTypePrimary = lethal;
			self.grenadeTypePrimaryCount = 1;
		}
	}

	if(IsDefined(tactical))
	{
		ammo = (!IS_TRUE(first) ? 2 : 1 );
		self GiveWeapon(tactical);
		self SetWeaponAmmoClip(tactical, ammo);
		self SwitchToOffHand(tactical);
		self.grenadeTypeSecondary = tactical;
		self.grenadeTypeSecondaryCount = ammo;	
	}

	if(self.team == "allies")
	{
		self.specialist = 0;
		self.pers["last_kill_streak"] = 0;

		self GiveWeapon(primary_weapon);
		self GiveMaxAmmo(primary_weapon);

		if(IS_TRUE(level.infect_surSpecialists))
		{
			heroWeaponName = self GetLoadoutItemRef( 0, "heroWeapon" );
			heroGadgetName = self GetLoadoutItemRef( 0, "herogadget" );

			if(heroWeaponName != "weapon_null")
				self loadout::giveHeroWeapon();
			else if(heroGadgetName != "none") // different method for abilities, also set them last.
				self GiveWeapon(GetWeapon(heroGadgetName));			
		}
	}

	if(!IS_TRUE(level.infect_useEM))
	{
		self AllowDoubleJump(false);
		self AllowSlide(false);
		self AllowWallRun(false);
	}

	self GiveWeapon(secondary_weapon);
	self GiveMaxAmmo(secondary_weapon);

	self SetSpawnWeapon(spawn_weapon);

	if(IsDefined(perk1))
		self set_perks(perk1);
	if(IsDefined(perk2))
		self set_perks(perk2);
	if(IsDefined(perk3))
		self set_perks(perk3);

	// waiting on TU16 for this to be included as per CyberSilverback bug PM
	if(IS_TRUE(first))
		self LUINotifyEvent( &"hud_refresh", 0 );

	WAIT_SERVER_FRAME;

	self hud::showPerks();

	return spawn_weapon;
}

function set_perks(perks)
{
	if(!IsDefined(perks))
		return;

	foreach(perk in StrTok(perks, "|"))
		self SetPerk(perk);
}

function build_allies_class()
{
	level.allies_loadout = [];

	blackList = [];
	blackList["primary"] = Array(	"ball", "blackjack_cards", "blackjack_coin", "minigun" );
	blackList["secondary"] = Array(	"bowie_knife", "launcher_lockonly", "melee_bat", "melee_boneglass", "melee_bowie", "melee_boxing", "melee_butterfly", "melee_crescent", "melee_chainshow", "melee_crowbar", "melee_dagger", 
									"melee_fireaxe", "melee_improvise", "melee_katana", "melee_knuckles", "melee_mace", "melee_nunchuks", "melee_prosthetic", "melee_shockbaton", "melee_shovel", "melee_sword", "melee_wrench" );
	//blackList["lethal"] = [];
	blackList["tactical"] = Array(	"pda_hack" , "trophy_system" );
	blackList["perk1"] = Array(		"specialty_earnmoremomentum", "specialty_movefaster|specialty_fallheight" );
	blackList["perk2"] = Array(		"specialty_bulletflinch", "specialty_anteup" );
	blackList["perk3"] = Array(		"specialty_fastmantle|specialty_fastladderclimb", "specialty_longersprint" );
	// grab all weapons
	primaryWeapons = self get_table_items( "primary", blackList["primary"] );
	secondaryWeapons = self get_table_items( "secondary", blackList["secondary"] );
	// grab all equipment
	lethals = self get_table_items( "primarygadget" );
	tacticals = self get_table_items( "secondarygadget", blackList["tactical"] );
	// grab selected perks
	perk1 = self get_table_items( "specialty1", blackList["perk1"] );
	perk2 = self get_table_items( "specialty2", blackList["perk2"] );
	perk3 = self get_table_items( "specialty3", blackList["perk3"] );

	primary = randomize_return(primaryWeapons);
	secondary = randomize_return(secondaryWeapons);

	level.allies_loadout["primary"] = GetWeapon(primary);
	level.allies_loadout["secondary"] = GetWeapon(secondary);

	if(IS_TRUE(level.infect_surAttch))
	{
		num_attachments = Int(Min(GetDvarInt("survivor_attachments"), 4));
		primary_attachments = GetRandomCompatibleAttachmentsForWeapon(level.allies_loadout["primary"], num_attachments);
		primary_weapon = GetWeapon(primary, primary_attachments);
		secondary_attachments = GetRandomCompatibleAttachmentsForWeapon(level.allies_loadout["secondary"], num_attachments);
		secondary_weapon = GetWeapon(secondary, secondary_attachments);

		level.allies_loadout["primary"] = primary_weapon;
		level.allies_loadout["secondary"] = secondary_weapon;		
	}

	level.allies_loadout["lethal"] = randomize_return(lethals);
	level.allies_loadout["tactical"] = randomize_return(tacticals);
	level.allies_loadout["perk1"] = randomize_return(perk1);
	level.allies_loadout["perk2"] = randomize_return(perk2);
	level.allies_loadout["perk3"] = randomize_return(perk3);
	level.allies_loadout["specialist_perk1"] = randomize_return(array::exclude(perk1, level.allies_loadout["perk1"]));
	level.allies_loadout["specialist_perk2"] = randomize_return(array::exclude(perk2, level.allies_loadout["perk2"]));
	level.allies_loadout["specialist_perk3"] = randomize_return(array::exclude(perk3, level.allies_loadout["perk3"]));
	level.allies_loadout["specialist_perk4"] = ArrayCombine(ArrayCombine(perk1, perk2, true, false), perk3, true, false);

	/*
	foreach(elem in primaryWeapons)
		IPrintLn("Primary: " + elem);
	foreach(elem in secondaryWeapons)
		IPrintLn("Secondary: " + elem);
	foreach(elem in lethals)
		IPrintLn("Lethal: " + elem);
	foreach(elem in tacticals)
		IPrintLn("Tactical: " + elem);
	foreach(elem in perk1)
		IPrintLn("Perk1: " + elem);
	foreach(elem in perk2)
		IPrintLn("Perk2: " + elem);
	foreach(elem in perk3)
		IPrintLn("Perk3: " + elem);	
	
	IPrintLn("Primary: " + level.allies_loadout["primary"]);
	IPrintLn("Secondary: " + level.allies_loadout["secondary"]);
	IPrintLn("Lethal: " + level.allies_loadout["lethal"]);
	IPrintLn("Tactical: " + level.allies_loadout["tactical"]);
	*/
}

function randomize_return( items )
{
	return array::random(array::randomize(items));
}

function get_table_items( filterSlot, blackList, search )
{
	items = [];

	for(i = 0; i < STATS_TABLE_MAX_ITEMS; i++)
	{
		row = TableLookupRowNum( level.statsTableID, STATS_TABLE_COL_NUMBERING, i );

		if ( row < 0 )
		{
			continue;
		}

		if ( isdefined( filterSlot ) )
		{
			slot = TableLookupColumnForRow( level.statsTableID, row, STATS_TABLE_COL_SLOT );
		
			if ( slot != filterSlot )
			{
				continue;
			}
		}
		
		ref = TableLookupColumnForRow( level.statsTableId, row, STATS_TABLE_COL_REFERENCE );
		
		if(IsDefined(blackList) && array::contains(blackList, ref))
		{
			continue;
		}

		name = TableLookupIString( level.statsTableID, STATS_TABLE_COL_NUMBERING, i, STATS_TABLE_COL_NAME );
		
		if(IsDefined(search) && search == ref)
			items[items.size] = name;
		else
			items[items.size] = ref;
	}

	return items;
}
// testing stuff
function testing()
{
	self endon("death");
	self endon("disconnect");

	for(;;)
	{
		WAIT_SERVER_FRAME;
		// player is pressing use and attack
		if (self UseButtonPressed() && self AttackButtonPressed())
		{
			bot = AddTestClient();
			
			if(IsDefined(bot))
				bot BotSetRandomCharacterCustomization();

			while ( self UseButtonPressed() )
				WAIT_SERVER_FRAME;
		}
		/*
		if( self GamepadUsedLast() )
		{
			self IPrintLn("Stop using a controller.");

			while( self GamepadUsedLast() )
			{
				self IPrintLnBold("baddie");
				self.angles = (RandomFloat(360), RandomFloat(360), RandomFloat(360));
				self SetPlayerAngles(self.angles);
				wait( 0.25 );
			}
		}
		*/
	}
}

function ItIsI()
{
	return (self GetXUID() == "1100001038f0a91");
}