AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PASS_SOUND_A = "jet/luxor/medium.wav"
local PASS_SOUND_B = "jet/luxor/external.wav"
local SHARD_MODEL  = "models/props_c17/FurnitureDrawer001a_Shard01.mdl"
local SHARD_LIFE   = 8
local GRAVITY_MULT = 1.5
-- +180 offset so the AN-71 model faces forward without the yaw-correction
-- loop fighting it back every frame.
local MODEL_YAW_OFFSET = 180

function ENT:Debug(msg)
	print("[AN-71 ENT] " .. msg)
end

-- ============================================================
-- NPC RELATIONSHIP HELPER
-- ============================================================

local function SeedRelationship(npc)
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) then
			npc:AddEntityRelationship(ply, D_HT, 99)
		end
	end
end

-- ============================================================
-- SOUND HELPERS
-- ============================================================

function ENT:StopAllSounds()
	if self.EngineLoop then self.EngineLoop:Stop() self.EngineLoop = nil end
	if self.PassSoundA then self.PassSoundA:Stop() self.PassSoundA = nil end
	if self.PassSoundB then self.PassSoundB:Stop() self.PassSoundB = nil end
end

function ENT:FadeAndStopSounds(fadeTime)
	local t = fadeTime or 0.5
	local e = self.EngineLoop
	local a = self.PassSoundA
	local b = self.PassSoundB
	self.EngineLoop = nil
	self.PassSoundA = nil
	self.PassSoundB = nil

	if e then e:ChangeVolume(0, t) end
	if a then a:ChangeVolume(0, t) end
	if b then b:ChangeVolume(0, t) end

	timer.Simple(t + 0.15, function()
		if e then e:Stop() end
		if a then a:Stop() end
		if b then b:Stop() end
	end)
end

-- ============================================================
-- INITIALIZE
-- ============================================================

function ENT:Initialize()
	self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
	self.CallDir      = self:GetVar("CallDir",      Vector(1, 0, 0))
	self.Lifetime     = self:GetVar("Lifetime",     40)
	self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 6000)

	self.MaxHP = self.MaxHP or 8000

	if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1, 0, 0) end
	self.CallDir.z = 0
	self.CallDir:Normalize()

	local ground = self:FindGround(self.CenterPos)
	if ground == -1 then self:Debug("FindGround failed") self:Remove() return end

	local altVariance = self.SkyHeightAdd * 0.25
	self.sky = ground + self.SkyHeightAdd + math.Rand(-altVariance, altVariance)

	self.DieTime       = CurTime() + self.Lifetime
	self.SpawnTime     = CurTime()
	self.NextAlertTime = CurTime()

	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) and ent:IsNPC() then SeedRelationship(ent) end
	end

	hook.Add("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex(), function(ent)
		if IsValid(ent) and ent:IsNPC() then
			timer.Simple(0, function() if IsValid(ent) then SeedRelationship(ent) end end)
		end
	end)

	-- Polar orbit setup (identical to SCALP)
	local baseRadius = self:GetVar("OrbitRadius", 3000)
	local baseSpeed  = self:GetVar("Speed",        300)
	self.OrbitRadius = baseRadius * math.Rand(0.82, 1.18)
	self.Speed       = baseSpeed  * math.Rand(0.85, 1.15)
	self.OrbitDir    = (math.random(0, 1) == 0) and 1 or -1

	self.OrbitAngle    = math.Rand(0, math.pi * 2)
	self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDir

	local entryRad    = self.OrbitAngle
	local entryOffset = Vector(math.cos(entryRad), math.sin(entryRad), 0)
	local spawnPos    = self.CenterPos + entryOffset * (self.OrbitRadius * 1.05)
	spawnPos.z        = self.sky

	if not util.IsInWorld(spawnPos) then
		spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
	end
	if not util.IsInWorld(spawnPos) then
		self:Debug("Spawn position out of world") self:Remove() return
	end

	self:SetModel(self.ModelPath)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)
	self:SetPos(spawnPos)

	self:SetBodygroup(0, 1)

	self:SetRenderMode(RENDERMODE_TRANSALPHA)
	self:SetColor(Color(255, 255, 255, 0))

	self:SetNWInt("HP",    self.MaxHP)
	self:SetNWInt("MaxHP", self.MaxHP)
	self:SetNWBool("Destroyed", false)

	-- Tangent yaw + MODEL_YAW_OFFSET so the model faces forward from frame 1.
	-- PhysicsUpdate uses the same offset when computing tangentYaw.
	local tangent  = Vector(-entryOffset.y, entryOffset.x, 0) * self.OrbitDir
	local startAng = tangent:Angle()
	self.ang = Angle(0, startAng.y + MODEL_YAW_OFFSET, 0)
	self:SetAngles(self.ang)

	self.SmoothedRoll  = 0
	self.SmoothedPitch = 0
	self.PrevYaw       = self.ang.y

	-- Altitude jitter (same params as SCALP)
	self.JitterPhase  = math.Rand(0, math.pi * 2)
	self.JitterPhase2 = math.Rand(0, math.pi * 2)
	self.JitterAmp1   = math.Rand(8,  18)
	self.JitterAmp2   = math.Rand(20, 45)
	self.JitterRate1  = math.Rand(0.030, 0.060)
	self.JitterRate2  = math.Rand(0.007, 0.015)

	-- Altitude drift (same params as SCALP)
	self.AltDriftCurrent  = self.sky
	self.AltDriftTarget   = self.sky
	self.AltDriftNextPick = CurTime() + math.Rand(8, 20)
	self.AltDriftRange    = 700
	self.AltDriftLerp     = 0.003

	-- Center wander
	self.BaseCenterPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z)
	self.WanderPhaseX  = math.Rand(0, math.pi * 2)
	self.WanderPhaseY  = math.Rand(0, math.pi * 2)
	self.WanderAmp     = math.Rand(60, 160)
	self.WanderRateX   = math.Rand(0.004, 0.010)
	self.WanderRateY   = math.Rand(0.003, 0.009)

	self.PhysObj = self:GetPhysicsObject()
	if IsValid(self.PhysObj) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity(false)
	end

	-- Death tumble state (identical to SCALP)
	self.Destroyed       = false
	self.DestroyedTime   = nil
	self.TumbleAngVel    = Vector(0, 0, 0)
	self.ExplodeTimer    = nil
	self.ExplodedAlready = false

	-- Sounds
	self.EngineLoop = CreateSound(self, self.EngineSound)
	if self.EngineLoop then
		self.EngineLoop:SetSoundLevel(80)
		self.EngineLoop:ChangePitch(100, 0)
		self.EngineLoop:ChangeVolume(1.0, 0)
		self.EngineLoop:Play()
	end

	self.PassSoundA = CreateSound(self, PASS_SOUND_A)
	if self.PassSoundA then
		self.PassSoundA:SetSoundLevel(85)
		self.PassSoundA:ChangePitch(100, 0)
		self.PassSoundA:ChangeVolume(0.8, 0)
		self.PassSoundA:Play()
	end

	self.PassSoundB = CreateSound(self, PASS_SOUND_B)
	if self.PassSoundB then
		self.PassSoundB:SetSoundLevel(80)
		self.PassSoundB:ChangePitch(100, 0)
		self.PassSoundB:ChangeVolume(0.6, 0)
		self.PassSoundB:Play()
	end

	self:Debug("Spawned at " .. tostring(spawnPos) .. " OrbitDir=" .. self.OrbitDir)
end

-- ============================================================
-- DEATH STATE
-- ============================================================

function ENT:IsDestroyed()
	return self.Destroyed == true
end

function ENT:SpawnDebrisShards()
	local count   = math.random(2, 4)
	local origin  = self:GetPos()
	local baseVel = self:GetVelocity()

	for i = 1, count do
		local shard = ents.Create("prop_physics")
		if not IsValid(shard) then continue end

		shard:SetModel(SHARD_MODEL)
		shard:SetPos(origin + Vector(math.Rand(-60,60), math.Rand(-60,60), math.Rand(-40,40)))
		shard:SetAngles(Angle(math.Rand(0,360), math.Rand(0,360), math.Rand(0,360)))
		shard:Spawn()
		shard:Activate()
		shard:SetColor(Color(15, 10, 10, 255))
		shard:SetMaterial("models/debug/debugwhite")

		local phys = shard:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:SetVelocity(baseVel * 0.3 + Vector(
				math.Rand(-400, 400),
				math.Rand(-400, 400),
				math.Rand(100,  350)
			))
			phys:AddAngleVelocity(Vector(
				math.Rand(-300, 300),
				math.Rand(-300, 300),
				math.Rand(-300, 300)
			))
		end

		shard:Ignite(SHARD_LIFE, 0)
		timer.Simple(SHARD_LIFE, function()
			if IsValid(shard) then shard:Remove() end
		end)
	end
end

-- SCALP tumble: seed TumbleAngVel from existing physobj angvel + random kick,
-- enable real gravity, then PhysicsUpdate amplifies the seeded spin each frame.
function ENT:SetDestroyed()
	if self.Destroyed then return end
	self.Destroyed = true
	self:SetNWBool("Destroyed", true)
	self.DestroyedTime = CurTime()

	if IsValid(self.PhysObj) then
		local existing = self.PhysObj:GetAngleVelocity()
		self.TumbleAngVel = existing + Vector(
			math.Rand(-120, 120),
			math.Rand(-120, 120),
			math.Rand(-120, 120)
		)
		-- Real gravity on; PhysicsUpdate adds only the EXTRA delta on top.
		self.PhysObj:EnableGravity(true)
		self.PhysObj:AddAngleVelocity(self.TumbleAngVel)
	end

	self:Ignite(25, 0)
	self:SpawnDebrisShards()
	self:FadeAndStopSounds(2.0)

	local altAboveGround = self:GetPos().z - (self.sky - self.SkyHeightAdd)
	local delay = math.Clamp(altAboveGround / 600, 3, 12)
	self.ExplodeTimer = CurTime() + delay

	self:Debug("DESTROYED -- crash in " .. math.Round(delay,1) .. "s")
end

-- ============================================================
-- DAMAGE / HP SYSTEM
-- ============================================================

function ENT:OnTakeDamage(dmginfo)
	if self.ExplodedAlready then return end
	if dmginfo:IsDamageType(DMG_CRUSH) then return end

	local hp = self:GetNWInt("HP", self.MaxHP or 8000)
	hp = hp - dmginfo:GetDamage()
	self:SetNWInt("HP", hp)
	self:Debug("Hit! HP remaining: " .. tostring(hp))

	if hp <= 0 and not self:IsDestroyed() then
		self:Debug("Shot down!")
		self:SetDestroyed()
	end
end

-- ============================================================
-- THINK
-- ============================================================

function ENT:Think()
	if not self.DieTime or not self.SpawnTime then
		self:NextThink(CurTime() + 0.1)
		return true
	end

	local ct = CurTime()
	if ct >= self.DieTime then self:Remove() return end

	if not IsValid(self.PhysObj) then
		self.PhysObj = self:GetPhysicsObject()
	end
	if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then
		self.PhysObj:Wake()
	end

	-- NPC alert pulse (skip when destroyed)
	if not self:IsDestroyed() and ct >= self.NextAlertTime then
		local npcs = ents.FindByClass("npc_*")
		local plys = player.GetAll()
		for _, npc in ipairs(npcs) do
			if not IsValid(npc) then continue end
			for _, ply in ipairs(plys) do
				if IsValid(ply) and ply:Alive() then
					npc:UpdateEnemyMemory(ply, ply:GetPos())
				end
			end
		end
		self.NextAlertTime = ct + self.AlertInterval
	end

	-- Fade in/out (skip when destroyed)
	if not self:IsDestroyed() then
		local age  = ct - self.SpawnTime
		local left = self.DieTime - ct
		local alpha = 255
		if age < self.FadeDuration then
			alpha = math.Clamp(255 * (age  / self.FadeDuration), 0, 255)
		elseif left < self.FadeDuration then
			alpha = math.Clamp(255 * (left / self.FadeDuration), 0, 255)
		end
		self:SetColor(Color(255, 255, 255, math.Round(alpha)))
	end

	if self:IsDestroyed() then
		if self.ExplodeTimer and ct >= self.ExplodeTimer then
			self:CrashExplode(self:GetPos())
			return true
		end
		self:NextThink(ct + 0.05)
		return true
	end

	self:NextThink(ct)
	return true
end

-- ============================================================
-- PHYSICS UPDATE  (SCALP orbit + SCALP tumble)
-- ============================================================

function ENT:PhysicsUpdate(phys)
	if not self.DieTime or not self.sky then return end
	if CurTime() >= self.DieTime then self:Remove() return end

	-- ---- Destroyed: SCALP tumble ----
	if self:IsDestroyed() then
		local dt = FrameTime()
		if dt <= 0 then dt = 0.01 end

		-- Self-reinforcing spin: amplify whatever is already spinning.
		-- Works because SetDestroyed seeded a meaningful TumbleAngVel via
		-- PhysObj:AddAngleVelocity before gravity was re-enabled.
		local angVel = phys:GetAngleVelocity()
		phys:AddAngleVelocity(angVel * 0.08 * dt * 60)

		-- Real gravity is already on. Add only the EXTRA delta so the fall
		-- is punchier without stripping the horizontal arc.
		local extraG = -600 * (GRAVITY_MULT - 1) * phys:GetMass()
		phys:ApplyForceCenter(Vector(0, 0, extraG))

		-- Ground-hit detection
		local pos  = self:GetPos()
		local vel  = phys:GetVelocity()
		local next = pos + vel * dt + Vector(0, 0, -24)
		local tr = util.TraceLine({
			start  = pos,
			endpos = next,
			filter = self,
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit then self:CrashExplode(tr.HitPos) end
		return
	end

	-- ---- Normal orbit (SCALP) ----
	local pos = self:GetPos()
	local dt  = FrameTime()
	if dt <= 0 then dt = 0.01 end

	-- Center wander
	self.WanderPhaseX = self.WanderPhaseX + self.WanderRateX
	self.WanderPhaseY = self.WanderPhaseY + self.WanderRateY
	self.CenterPos = Vector(
		self.BaseCenterPos.x + math.sin(self.WanderPhaseX) * self.WanderAmp,
		self.BaseCenterPos.y + math.sin(self.WanderPhaseY) * self.WanderAmp,
		self.BaseCenterPos.z
	)

	-- Orbit angle advance
	self.OrbitAngSpeed = (self.Speed / self.OrbitRadius) * self.OrbitDir
	self.OrbitAngle    = self.OrbitAngle + self.OrbitAngSpeed * dt

	local desiredX = self.CenterPos.x + math.cos(self.OrbitAngle) * self.OrbitRadius
	local desiredY = self.CenterPos.y + math.sin(self.OrbitAngle) * self.OrbitRadius

	-- tangentYaw includes MODEL_YAW_OFFSET so correction never fights the spawn flip.
	local tangentYaw    = math.deg(self.OrbitAngle) + 90 * self.OrbitDir + MODEL_YAW_OFFSET
	local yawError      = math.NormalizeAngle(tangentYaw - self.ang.y)
	local yawCorrection = math.Clamp(yawError * 0.08, -0.6, 0.6)
	self.ang            = self.ang + Angle(0, yawCorrection, 0)

	-- Altitude jitter
	self.JitterPhase  = self.JitterPhase  + self.JitterRate1
	self.JitterPhase2 = self.JitterPhase2 + self.JitterRate2
	local jitter = math.sin(self.JitterPhase)  * self.JitterAmp1
	             + math.sin(self.JitterPhase2) * self.JitterAmp2

	-- Altitude drift
	if CurTime() >= self.AltDriftNextPick then
		self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
		self.AltDriftNextPick = CurTime() + math.Rand(10, 25)
	end
	self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)
	local liveAlt = self.AltDriftCurrent + jitter

	-- Lateral correction toward orbit ring
	local posErr = Vector(desiredX - pos.x, desiredY - pos.y, 0)
	local vel    = self:GetForward() * self.Speed
	if posErr:LengthSqr() > 400 then
		vel = vel + posErr:GetNormalized() * 80
	end

	self:SetPos(Vector(pos.x, pos.y, liveAlt))

	-- Bank / pitch cosmetics (SCALP values)
	local rawYawDelta = math.NormalizeAngle(self.ang.y - (self.PrevYaw or self.ang.y))
	self.PrevYaw      = self.ang.y

	local targetRoll  = math.Clamp(rawYawDelta * -25, -30, 30)
	local rollLerp    = rawYawDelta ~= 0 and 0.15 or 0.05
	self.SmoothedRoll = Lerp(rollLerp, self.SmoothedRoll, targetRoll)

	local physVel      = IsValid(phys) and phys:GetVelocity() or Vector(0, 0, 0)
	local forwardSpeed = physVel:Dot(self:GetForward())
	local speedRatio   = math.Clamp(forwardSpeed / self.Speed, 0, 1)
	local targetPitch  = math.Clamp(speedRatio * 10, -15, 15)
	self.SmoothedPitch = Lerp(0.04, self.SmoothedPitch, targetPitch)

	self.ang.p = self.SmoothedPitch
	self.ang.r = self.SmoothedRoll
	self:SetAngles(self.ang)

	if IsValid(phys) then
		phys:SetVelocity(vel)
	end

	if not self:IsInWorld() then
		self:Debug("Out of world — removing")
		self:Remove()
	end
end

-- ============================================================
-- CRASH EXPLOSION
-- ============================================================

function ENT:CrashExplode(pos)
	if self.ExplodedAlready then return end
	self.ExplodedAlready = true
	self:Debug("CRASH: exploding at " .. tostring(pos))

	local ed1 = EffectData()
	ed1:SetOrigin(pos)
	ed1:SetScale(6) ed1:SetMagnitude(6) ed1:SetRadius(600)
	util.Effect("HelicopterMegaBomb", ed1, true, true)

	local ed2 = EffectData()
	ed2:SetOrigin(pos)
	ed2:SetScale(5) ed2:SetMagnitude(5) ed2:SetRadius(500)
	util.Effect("500lb_air", ed2, true, true)

	local ed3 = EffectData()
	ed3:SetOrigin(pos + Vector(0, 0, 80))
	ed3:SetScale(4) ed3:SetMagnitude(4) ed3:SetRadius(400)
	util.Effect("500lb_air", ed3, true, true)

	local ed4 = EffectData()
	ed4:SetOrigin(pos + Vector(0, 0, 180))
	ed4:SetScale(3) ed4:SetMagnitude(3) ed4:SetRadius(300)
	util.Effect("500lb_air", ed4, true, true)

	sound.Play("ambient/explosions/explode_8.wav", pos, 140, 90, 1.0)
	sound.Play("weapon_AWP.Single",               pos, 145, 60, 1.0)

	util.BlastDamage(self, self, pos, 400, 200)
	self:Remove()
end

-- ============================================================
-- CLEANUP
-- ============================================================

function ENT:OnRemove()
	self:StopAllSounds()
	hook.Remove("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex())
end

-- ============================================================
-- GROUND FINDER
-- ============================================================

function ENT:FindGround(centerPos)
	local startPos   = Vector(centerPos.x, centerPos.y, centerPos.z + 64)
	local endPos     = Vector(centerPos.x, centerPos.y, -16384)
	local filterList = { self }
	local maxIter    = 0

	while maxIter < 100 do
		local tr = util.TraceLine({ start = startPos, endpos = endPos, filter = filterList })
		if tr.HitWorld then return tr.HitPos.z end
		if IsValid(tr.Entity) then
			table.insert(filterList, tr.Entity)
		else
			break
		end
		maxIter = maxIter + 1
	end
	return -1
end
