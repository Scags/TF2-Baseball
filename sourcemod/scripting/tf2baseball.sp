#include <sourcemod>
#include <sdktools>
#include <dhooks>

public Plugin myinfo =  {
	name = "[TF2] Baseball", 
	author = "Scag", 
	description = "Gone forever", 
	version = "1.0.0", 
	url = "https://github.com/Scags/TF2-Baseball"
};

Handle hSmack;
Handle hWorldSpaceCenter;
Handle hGetVelocity;

ConVar cvScalar;
ConVar cvFOV;
ConVar cvRange;

public void OnPluginStart()
{
	Handle conf = LoadGameConfigFile("tf2.baseball");
	if (!conf)
		SetFailState("Could not find gamedata for tf2.baseball");

	hSmack = DHookCreate(0, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	if (!DHookSetFromConf(hSmack, conf, SDKConf_Virtual, "CTFBat::Smack"))
		SetFailState("Could not initialize call to CTFBat::Smack");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CBaseEntity::GetVelocity");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Plain, 0, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_Plain, 0, VENCODE_FLAG_COPYBACK);
	if (!(hGetVelocity = EndPrepSDKCall()))
		SetFailState("Could not initialize call to CBaseEntity::GetVelocity");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CBaseEntity::WorldSpaceCenter");
	PrepSDKCall_SetReturnInfo(SDKType_Vector, SDKPass_ByRef);
	if (!(hWorldSpaceCenter = EndPrepSDKCall()))
		LogError("Could not initialize call to CBaseEntity::WorldSpaceCenter. Falling back to m_vecOrigin.");

	cvScalar = CreateConVar("sm_tfbaseball_velmult", "1.15", "Speed multiplier for a bat'd projectile.", FCVAR_NOTIFY, true, 0.00001);
	cvFOV = CreateConVar("sm_tfbaseball_fov", "70.0", "FOV range for bat swinging to register as a valid hit.", FCVAR_NOTIFY, true, 0.0, true, 180.0);
	cvRange = CreateConVar("sm_tfbaseball_range", "150.0", "Max range a projectile can be before it is bat'd", FCVAR_NOTIFY, true, 0.0);

	delete conf;
}

public void OnMapStart()
{
	PrecacheSound("mvm/melee_impacts/bat_baseball_hit_robo01.wav", true);
}

public void OnEntityCreated(int ent, const char[] classname)
{
	if (!StrContains(classname, "tf_weapon_bat", false))
		DHookEntity(hSmack, false, ent, _, Smack);
}

public MRESReturn Smack(int pThis)
{
	int owner = GetEntPropEnt(pThis, Prop_Send, "m_hOwnerEntity");
	if (!(0 < owner <= MaxClients))
		return MRES_Ignored;

	float vecEye[3]; GetClientEyeAngles(owner, vecEye);
	float vecFwd[3]; GetAngleVectors(vecEye, vecFwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(vecFwd, vecFwd);

	int ent = FindBall(owner, vecFwd);

	if (ent == -1)
		return MRES_Ignored;

	float vecVel[3]; vecVel = GetVelocity(ent);
	float speed = GetVectorLength(vecVel);

	ScaleVector(vecFwd, speed);
	ScaleVector(vecFwd, cvScalar.FloatValue);	// To be fair you are SWINGING a bat, so velocity should go up, right?
												// Or down if you want that

	TeleportEntity(ent, NULL_VECTOR, vecEye, vecFwd);

	EmitSoundToAll("mvm/melee_impacts/bat_baseball_hit_robo01.wav", owner);
	SetEntProp(ent, Prop_Send, "m_iDeflected", GetEntProp(ent, Prop_Send, "m_iDeflected")+1);

	char classname[64]; GetEntityClassname(ent, classname, sizeof(classname));
	if (!StrEqual(classname, "tf_projectile_pipe_remote", false))	// Shouldn't own sticky bombs
	{
		int team = GetClientTeam(owner);
		if (HasEntProp(ent, Prop_Send, "m_hDeflectOwner"))
			SetEntPropEnt(ent, Prop_Send, "m_hDeflectOwner", owner);
		if (HasEntProp(ent, Prop_Send, "m_hLauncher"))
			SetEntPropEnt(ent, Prop_Send, "m_hLauncher", owner);
		if (HasEntProp(ent, Prop_Send, "m_hThrower"))
			SetEntPropEnt(ent, Prop_Send, "m_hThrower", owner);		// ONE of these HAS to work

		SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", owner);
		SetEntProp(ent, Prop_Send, "m_iTeamNum", team);
		SetEntProp(ent, Prop_Send, "m_nSkin", team-2);
	}

	return MRES_Ignored;
}

public int FindBall(int client, const float vecFwd[3])
{
	float max = 1.0 - cvFOV.FloatValue/180.0;
	int ent = -1;
	float vecPos[3]; GetClientEyePosition(client, vecPos);
	float vecOtherPos[3];
	float vecSub[3];

	while ((ent = FindEntityByClassname(ent, "tf_projectile*")) != -1)
	{
		vecOtherPos = WorldSpaceCenter(ent);
		if (GetVectorDistance(vecPos, vecOtherPos) > cvRange.FloatValue)
			continue;
		
		if (GetEntProp(ent, Prop_Send, "m_iTeamNum") == GetClientTeam(client))
			continue;

		SubtractVectors(vecOtherPos, vecPos, vecSub);
		NormalizeVector(vecSub, vecSub);
		if (GetVectorDotProduct(vecFwd, vecSub) < max)	// It's within fov and within a reasonable melee range 
			continue;									// Now, can you actually see it?
		
		TR_TraceRayFilter(vecPos, vecOtherPos, MASK_SOLID, RayType_EndPoint, TheTrace, client);
		if (!TR_DidHit() || TR_GetEntityIndex() == ent)
			return ent;		// Yes, now reflect it!
	}
	return -1;
}

float[] WorldSpaceCenter(int entity)
{
	float pos[3];
	if (hWorldSpaceCenter)
		SDKCall(hWorldSpaceCenter, entity, pos);
	else GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);	// If it doesn't exist then fall back to vecOrigin

	return pos;
}

float[] GetVelocity(int entity)
{
	float vel[3], dummy[3];
	SDKCall(hGetVelocity, entity, vel, dummy);
	return vel;
}

public bool TheTrace(int ent, int mask, any data)
{
	if (ent <= MaxClients)
		return false;
	
	char classname[64]; GetEntityClassname(ent, classname, sizeof(classname));
	if (StrContains(classname, "tf_projectile", false))
		return false;

	if (!strcmp(classname, "tf_projectile_syringe", false))
		return false;	// Has no m_iDeflected

	return true;
}