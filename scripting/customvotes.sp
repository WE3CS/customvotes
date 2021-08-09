#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <regex>
#include <customvotes>

#pragma semicolon 1
#pragma newdecls required

#define VOTE_TEAMID_EVERYONE -1

enum struct VoteInfo
{
	// Source plugin handle.
	Handle plugin;
	
	// Vote result call functions.
	Function pass_function;
	Function fail_function;
	
	// Enum struct that contains all the required data.
	CustomVoteSetup setup;
	
	// Vote timeout timer handle.
	Handle VoteTimeoutTimer;
	
	// Resets back everything to default values.
	void Reset()
	{
		this.plugin = null;
		
		this.pass_function = INVALID_FUNCTION;
		this.fail_function = INVALID_FUNCTION;
		
		this.setup.Reset();
		
		delete this.VoteTimeoutTimer;
	}
	
	void CallResult(Function func, int results[MAXPLAYERS + 1])
	{
		Call_StartFunction(this.plugin, func);
		Call_PushArray(results, sizeof(results));
		Call_Finish();
	}
}

VoteInfo g_VoteInfoData;

// ConVar Handles.
ConVar g_PositiveVoteSound;
ConVar g_NegativeVoteSound;

// Global Forward Handles.
GlobalForward g_fwdOnVoteReceive;

// User Message Id Handles.
UserMsg g_VoteStartMsgId;
UserMsg g_VotePassMsgId;
UserMsg g_VoteFailedMsgId;

bool g_IsVoteInProgress;

int g_ClientVoteDecision[MAXPLAYERS + 1] = { VOTE_DECISION_NONE, ... };

int g_VoteControllerEnt = -1;

public Plugin myinfo = 
{
	name = "[CS:GO] Custom Votes", 
	author = "KoNLiG", 
	description = "Replicates the internal CS:GO panel votes from official Valve servers.", 
	version = "1.0.0", 
	url = "https://steamcommunity.com/id/KoNLiGrL/ || KoNLiG#0001"
};

public void OnPluginStart()
{
	// ConVars Configuration.
	g_PositiveVoteSound = CreateConVar("custom_votes_positive_vote_sound", "sound/ui/menu_accept.wav", "Sound file path that will be played once a client has voted yes.");
	g_NegativeVoteSound = CreateConVar("custom_votes_negative_vote_sound", "sound/ui/menu_invalid.wav", "Sound file path that will be played once a client has voted no.");
	
	AutoExecConfig();
	
	// Initialize user messages ids.
	if ((g_VoteStartMsgId = GetUserMessageId("VoteStart")) == INVALID_MESSAGE_ID)
	{
		SetFailState("Couldn't get 'VoteStart' user message id.");
	}
	
	if ((g_VotePassMsgId = GetUserMessageId("VotePass")) == INVALID_MESSAGE_ID)
	{
		SetFailState("Couldn't get 'VotePass' user message id.");
	}
	
	if ((g_VoteFailedMsgId = GetUserMessageId("VoteFailed")) == INVALID_MESSAGE_ID)
	{
		SetFailState("Couldn't get 'VoteFailed' user message id.");
	}
	
	// Hook 'vote' command which will be a votes receive listener.
	AddCommandListener(Listener_OnVoteReceive, "vote");
}

//================================[ Events ]================================//

public void OnMapStart()
{
	// Initialize the vote controller entity
	if (!InitVoteController())
	{
		SetFailState("Couldn't get and create 'vote_controller' entity.");
	}
	
	char sound_path[PLATFORM_MAX_PATH];
	
	g_PositiveVoteSound.GetString(sound_path, sizeof(sound_path));
	AddFileToDownloadsTable(sound_path);
	PrecacheSound(sound_path[6]);
	
	g_NegativeVoteSound.GetString(sound_path, sizeof(sound_path));
	AddFileToDownloadsTable(sound_path);
	PrecacheSound(sound_path[6]);
}

public void OnClientDisconnect_Post(int client)
{
	// If there is no a custom vote currently in progress, don't continue.
	if (!g_IsVoteInProgress)
	{
		return;
	}
	
	// If the disconnected client is the last client in the sevrer, abort the vote.
	if (!GetClientCount())
	{
		DisplayCustomVoteResults();
	}
	
	// Update the potential votes count in the vote controller entity.
	else
	{
		if (g_ClientVoteDecision[client] != VOTE_DECISION_NONE)
		{
			SetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, g_ClientVoteDecision[client]) - 1, _, g_ClientVoteDecision[client]);
			
			g_ClientVoteDecision[client] = VOTE_DECISION_NONE;
		}
		
		UpdatePotentialVotes();
	}
}

//================================[ Commands ]================================//

Action Listener_OnVoteReceive(int client, const char[] command, int argc)
{
	// If any custom vote isn't currently in a progress, don't continue
	if (!g_IsVoteInProgress)
	{
		return Plugin_Continue;
	}
	
	// Initialize the client vote decision
	char vote_choice[16];
	GetCmdArg(1, vote_choice, sizeof(vote_choice));
	
	// Convert the client vote decision into a integer (0 = Yes, 1 = No)
	int vote_decision = StringToInt(vote_choice[6]) - 1;
	
	// Execute the vote receive forward.
	Action fwd_return;
	Call_StartForward(g_fwdOnVoteReceive);
	Call_PushCell(client); // int client
	Call_PushCellRef(vote_decision); // int &voteDecision
	
	int error = Call_Finish(fwd_return);
	if (error != SP_ERROR_NONE)
	{
		ThrowNativeError(error, "Vote receive forward failure - Error: %d", error);
		return Plugin_Stop;
	}
	
	// Stop the further actions if needs to.
	if (fwd_return >= Plugin_Handled)
	{
		int clients[1];
		clients[0] = client;
		
		int clients_count = 1;
		
		DisplayCustomVotePanel(clients, clients_count);
		
		return fwd_return;
	}
	
	int modified_votes = GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, vote_decision) + 1;
	SetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", modified_votes, _, vote_decision);
	
	// Initialize the selection sound effect file path.
	char sound_effect[PLATFORM_MAX_PATH];
	GetConVarString(vote_decision == VOTE_DECISION_YES ? g_PositiveVoteSound : g_NegativeVoteSound, sound_effect, sizeof(sound_effect));
	
	// Play the selection sound effect. (:
	EmitSoundToClient(client, sound_effect[6]);
	
	g_ClientVoteDecision[client] = vote_decision;
	
	// If the current voter is the last potential voter, immediately end the custom vote.
	if (GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nPotentialVotes") <= modified_votes + GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, vote_decision ^ 1))
	{
		DisplayCustomVoteResults();
	}
	
	return Plugin_Handled;
}

//================================[ API ]================================//

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// Lock the use of this plugin for CS:GO only.
	if (GetEngineVersion() != Engine_CSGO)
	{
		strcopy(error, err_max, "This plugin was made for use with CS:GO only.");
		return APLRes_Failure;
	}
	
	CreateNative("CustomVotes_Execute", Native_Execute);
	CreateNative("CustomVotes_IsVoteInProgress", Native_IsVoteInProgress);
	CreateNative("CustomVotes_GetSetup", Native_GetSetup);
	CreateNative("CustomVotes_Cancel", Native_Cancel);
	
	g_fwdOnVoteReceive = new GlobalForward("CustomVotes_OnVoteReceive", ET_Hook, Param_Cell, Param_CellByRef);
	
	RegPluginLibrary("customvotes");
	
	return APLRes_Success;
}

any Native_Execute(Handle plugin, int numParams)
{
	// If a another custom vote is already is progress, throw a native error and don't continue
	if (g_IsVoteInProgress)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Unable to execute a new custom vote, there is already one in progress.");
	}
	
	GetNativeArray(1, g_VoteInfoData.setup, sizeof(CustomVoteSetup));
	
	if (g_VoteInfoData.setup.team == CS_TEAM_NONE)
	{
		g_VoteInfoData.setup.team = VOTE_TEAMID_EVERYONE;
	}
	
	if (!g_VoteInfoData.setup.pass_percentage)
	{
		g_VoteInfoData.setup.pass_percentage = DEFAULT_PASS_PERCENTAGE;
	}
	
	g_VoteInfoData.plugin = plugin;
	g_VoteInfoData.pass_function = GetNativeFunction(3);
	g_VoteInfoData.fail_function = GetNativeFunction(4);
	
	SetEntProp(g_VoteControllerEnt, Prop_Send, "m_iOnlyTeamToVote", g_VoteInfoData.setup.team);
	
	for (int current_option = 0; current_option < 5; current_option++)
	{
		SetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", 0, _, current_option);
	}
	
	SetEntProp(g_VoteControllerEnt, Prop_Send, "m_nPotentialVotes", GetClientCount());
	
	g_IsVoteInProgress = true;
	
	char url[PLATFORM_MAX_PATH];
	GetImageFromText(g_VoteInfoData.setup.dispstr, url, sizeof(url));
	
	if (!PrecacheImage(g_VoteInfoData.setup.dispstr, Timer_RepeatVoteDisplay))
	{
		int clients[MAXPLAYERS];
		int clients_count;
		
		for (int current_client = 1; current_client <= MaxClients; current_client++)
		{
			if (IsClientInGame(current_client) && !IsFakeClient(current_client) && (g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE || GetClientTeam(current_client) == g_VoteInfoData.setup.team))
			{
				clients[clients_count++] = current_client;
			}
		}
		
		DisplayCustomVotePanel(clients, clients_count);
	}
	
	delete g_VoteInfoData.VoteTimeoutTimer;
	g_VoteInfoData.VoteTimeoutTimer = CreateTimer(float(GetNativeCell(2)), Timer_DisplayCustomVoteResults);
	
	for (int current_client = 0; current_client <= MaxClients; current_client++)
	{
		g_ClientVoteDecision[current_client] = VOTE_DECISION_NONE;
	}
	
	return 0;
}

any Native_IsVoteInProgress(Handle plugin, int numParams)
{
	return g_IsVoteInProgress;
}

any Native_GetSetup(Handle plugin, int numParams)
{
	// If no custom vote is currently is progress, throw a native error and don't continue
	if (!g_IsVoteInProgress)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "No custom vote is currently in progress.");
	}
	
	SetNativeArray(1, g_VoteInfoData.setup, sizeof(g_VoteInfoData.setup));
	
	return 0;
}

any Native_Cancel(Handle plugin, int numParams)
{
	// If no custom vote is currently is progress, throw a native error and don't continue
	if (!g_IsVoteInProgress)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "No custom vote is currently in progress.");
	}
	
	if (!GetNativeCell(1) && g_VoteInfoData.plugin != plugin)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Can't cancel a custom vote from a different execute plugin.");
	}
	
	int clients[MAXPLAYERS];
	int clients_count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && !IsFakeClient(current_client) && (g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE || GetClientTeam(current_client) == g_VoteInfoData.setup.team))
		{
			clients[clients_count++] = current_client;
		}
	}
	
	Protobuf msg = view_as<Protobuf>(StartMessageEx(g_VoteFailedMsgId, clients, clients_count, USERMSG_RELIABLE));
	
	msg.SetInt("team", g_VoteInfoData.setup.team);
	msg.SetInt("reason", VOTE_FAILED_DISABLED);
	
	EndMessage();
	
	g_VoteInfoData.Reset();
	g_IsVoteInProgress = false;
	
	return 0;
}

//================================[ Timers ]================================//

Action Timer_DisplayCustomVoteResults(Handle timer)
{
	DisplayCustomVoteResults();
	
	g_VoteInfoData.VoteTimeoutTimer = INVALID_HANDLE;
}

Action Timer_RepeatVoteDisplay(Handle timer)
{
	int clients[MAXPLAYERS];
	int clients_count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && !IsFakeClient(current_client) && (g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE || GetClientTeam(current_client) == g_VoteInfoData.setup.team))
		{
			clients[clients_count++] = current_client;
		}
	}
	
	DisplayCustomVotePanel(clients, clients_count);
}

Action Timer_RepeatVotePass(Handle timer)
{
	#pragma unused timer
	
	int clients[MAXPLAYERS];
	int clients_count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && !IsFakeClient(current_client) && (g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE || GetClientTeam(current_client) == g_VoteInfoData.setup.team))
		{
			clients[clients_count++] = current_client;
		}
	}
	
	Protobuf msg = view_as<Protobuf>(StartMessageEx(g_VotePassMsgId, clients, clients_count, USERMSG_RELIABLE));
	
	msg.SetInt("team", g_VoteInfoData.setup.team);
	msg.SetInt("vote_type", g_VoteInfoData.setup.issue_id);
	msg.SetString("disp_str", g_VoteInfoData.setup.disppass);
	
	EndMessage();
}

//================================[ Functions ]================================//

void DisplayCustomVoteResults()
{
	int positive_votes = GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, 0);
	int negative_votes = GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, 1);
	
	int clients[MAXPLAYERS];
	int clients_count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && !IsFakeClient(current_client) && (g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE || g_VoteInfoData.setup.team == GetClientTeam(current_client)))
		{
			clients[clients_count++] = current_client;
		}
	}
	
	Function result_callback;
	
	int total_voters = positive_votes + negative_votes;
	
	if (total_voters && (float(positive_votes) / float(total_voters)) * 100.0 >= g_VoteInfoData.setup.pass_percentage)
	{
		if (!PrecacheImage(g_VoteInfoData.setup.disppass, Timer_RepeatVotePass))
		{
			Protobuf msg = view_as<Protobuf>(StartMessageEx(g_VotePassMsgId, clients, clients_count, USERMSG_RELIABLE));
			
			msg.SetInt("team", g_VoteInfoData.setup.team);
			msg.SetInt("vote_type", g_VoteInfoData.setup.issue_id);
			msg.SetString("disp_str", g_VoteInfoData.setup.disppass);
			msg.SetString("details_str", "");
			
			EndMessage();
		}
		
		result_callback = g_VoteInfoData.pass_function;
	}
	else
	{
		Protobuf msg = view_as<Protobuf>(StartMessageEx(g_VoteFailedMsgId, clients, clients_count, USERMSG_RELIABLE));
		
		msg.SetInt("team", g_VoteInfoData.setup.team);
		msg.SetInt("reason", GetVoteFailReason());
		
		EndMessage();
		
		result_callback = g_VoteInfoData.fail_function;
	}
	
	if (result_callback != INVALID_FUNCTION)
	{
		g_VoteInfoData.CallResult(result_callback, g_ClientVoteDecision);
	}
	
	g_VoteInfoData.Reset();
	g_IsVoteInProgress = false;
}

bool InitVoteController()
{
	if ((g_VoteControllerEnt = FindEntityByClassname(-1, "vote_controller")) < 0 && (g_VoteControllerEnt = CreateEntityByName("vote_controller")) == -1)
	{
		return false;
	}
	
	SetEntProp(g_VoteControllerEnt, Prop_Send, "m_bIsYesNoVote", true);
	
	return true;
}

void UpdatePotentialVotes()
{
	// Update the potential votes only if a vote is in progress
	if (!g_IsVoteInProgress)
	{
		return;
	}
	
	// Change the vote controller potential votes value to the updated one
	SetEntProp(g_VoteControllerEnt, Prop_Send, "m_nPotentialVotes", g_VoteInfoData.setup.team == VOTE_TEAMID_EVERYONE ? GetClientCount() : GetTeamClientCount(g_VoteInfoData.setup.team));
}

bool PrecacheImage(const char[] text, Timer redirect_callback)
{
	char url[PLATFORM_MAX_PATH];
	GetImageFromText(text, url, sizeof(url));
	
	if (!url[0])
	{
		return false;
	}
	
	Event event = CreateEvent("show_survival_respawn_status");
	
	if (event)
	{
		Format(url, sizeof(url), "<font class='fontSize-l'>Loading UI Image...</font>\n%s", url);
		
		event.SetString("loc_token", url);
		event.SetInt("duration", 0);
		event.SetInt("userid", -1);
		event.Fire();
	}
	
	CreateTimer(1.0, redirect_callback);
	
	return true;
}

void GetImageFromText(const char[] text, char[] buffer, int length)
{
	// Static regex insted of a global one
	static Regex rgx;
	
	// Complie our regex only once
	if (!rgx)
	{
		rgx = new Regex("<img .*src=(?:\\'|\\\").+(?:\\'|\\\").*\\/?>");
	}
	
	// Perform the regex match
	rgx.Match(text);
	
	if (rgx.MatchCount())
	{
		rgx.GetSubString(0, buffer, length);
	}
}

void DisplayCustomVotePanel(int[] clients, int clients_count)
{
	Protobuf msg = view_as<Protobuf>(StartMessageEx(g_VoteStartMsgId, clients, clients_count, USERMSG_RELIABLE));
	
	msg.SetInt("team", g_VoteInfoData.setup.team);
	msg.SetInt("ent_idx", g_VoteInfoData.setup.initiator);
	msg.SetInt("vote_type", g_VoteInfoData.setup.issue_id);
	msg.SetString("disp_str", g_VoteInfoData.setup.dispstr);
	msg.SetString("details_str", "");
	msg.SetString("other_team_str", ""); // Not used in CS:GO, permanently disabled by Valve.
	msg.SetBool("is_yes_no_vote", true);
	msg.SetInt("entidx_target", 0);
	
	EndMessage();
}

int GetVoteFailReason()
{
	int positive_votes = GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, 0);
	int negative_votes = GetEntProp(g_VoteControllerEnt, Prop_Send, "m_nVoteOptionCount", _, 1);
	
	// No one voted.
	if (!(positive_votes + negative_votes))
	{
		return VOTE_FAILED_QUORUM_FAILURE;
	}
	
	// Not enough players voted positively.
	if (negative_votes > positive_votes && g_VoteInfoData.setup.pass_percentage == DEFAULT_PASS_PERCENTAGE)
	{
		return VOTE_FAILED_YES_MUST_EXCEED_NO;
	}
	
	// Generic failure.
	return VOTE_FAILED_GENERIC;
}

//================================================================//