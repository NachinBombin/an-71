AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_trailsystem.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PASS_SOUND_A = "jet/luxor/medium.wav"
local PASS_SOUND_B = "jet/luxor/external.wav"

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
-- NET STRING
-- ============================================================
util.AddNetworkString("bombin_plane_damage_tier")

-- ============================================================
-- INITIALIZE
-- ============================================================

function ENT:Initialize()
    self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
    self.CallDir      = self:GetVar("CallDir",      Vector(1, 0, 0))
    self.Lifetime     = self:GetVar("Lifetime",     40)
    self.Speed        = self:GetVar("Speed",        300)
    self.OrbitRadius  = self:GetVar("OrbitRadius",  3000)
    self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 6000)

    self.MaxHP = self.MaxHP or 8000

    if self.CallDir:LengthSqr() <= 1 then
        self.CallDir = Vector(1, 0, 0)
    end
    self.CallDir.z = 0
    self.CallDir:Normalize()

    local ground = self:FindGround(self.CenterPos)
    if ground == -1 then
        self:Debug("FindGround failed")
        self:Remove()
        return
    end

    self.sky           = ground + self.SkyHeightAdd
    self.DieTime       = CurTime() + self.Lifetime
    self.SpawnTime     = CurTime()
    self.NextAlertTime = CurTime()
    self.IsDestroyed   = false
    self.DamageTier    = 0

    -- Tumble state
    self.IsTumbling       = false
    self.TumbleStartTime  = 0
    self.TumbleGroundZ    = ground
    self.TumbleCrashed    = false
    self.TumbleVelocity   = Vector(0, 0, 0)   -- linear  HU/s, manually integrated
    self.TumbleAngVelocity = Vector(0, 0, 0)  -- deg/s  (pitch, yaw, roll)

    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC() then
            SeedRelationship(ent)
        end
    end

    hook.Add("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex(), function(ent)
        if IsValid(ent) and ent:IsNPC() then
            timer.Simple(0, function()
                if IsValid(ent) then SeedRelationship(ent) end
            end)
        end
    end)

    local spawnPos = self.CenterPos - self.CallDir * 2000
    spawnPos = Vector(spawnPos.x, spawnPos.y, self.sky)

    if not util.IsInWorld(spawnPos) then
        self:Debug("Primary spawnPos out of world, trying center fallback")
        spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
    end
    if not util.IsInWorld(spawnPos) then
        self:Debug("Fallback spawnPos out of world too")
        self:Remove()
        return
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

    local angYaw   = self.CallDir:Angle().y
    self.ang       = Angle(0, angYaw + 180, 0)
    self.flightYaw = angYaw
    self.PrevYaw   = self.flightYaw

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    self.JitterPhase      = math.Rand(0, math.pi * 2)
    self.SmoothedRoll     = 0
    self.SmoothedPitch    = 0

    self:SetNWInt("HP",    self.MaxHP)
    self:SetNWInt("MaxHP", self.MaxHP)

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:Wake()
        self.PhysObj:EnableGravity(false)
        self.PhysObj:SetAngles(self.ang)
    end

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

    self:Debug("Spawned at " .. tostring(spawnPos))
end

-- ============================================================
-- DAMAGE TIER HELPER
-- ============================================================

local function CalcTier(hp, maxHP)
    local frac = hp / maxHP
    if frac > 0.66 then return 0
    elseif frac > 0.33 then return 1
    elseif frac > 0 then return 2
    else return 3
    end
end

local function BroadcastTier(ent, tier)
    net.Start("bombin_plane_damage_tier")
        net.WriteUInt(ent:EntIndex(), 16)
        net.WriteUInt(tier, 2)
    net.Broadcast()
end

-- ============================================================
-- DAMAGE / HP SYSTEM
-- ============================================================

function ENT:OnTakeDamage(dmginfo)
    if self.IsDestroyed then return end
    if dmginfo:IsDamageType(DMG_CRUSH) then return end

    local hp = self:GetNWInt("HP", self.MaxHP or 8000)
    hp = hp - dmginfo:GetDamage()
    self:SetNWInt("HP", hp)
    self:Debug("Hit! HP remaining: " .. tostring(hp))

    local tier = CalcTier(hp, self.MaxHP or 8000)
    if tier ~= self.DamageTier then
        self.DamageTier = tier
        BroadcastTier(self, tier)
    end

    if hp <= 0 then
        self:Debug("Shot down!")
        self:DestroyPlane()
    end
end

-- ============================================================
-- TUMBLE SYSTEM
-- ============================================================

-- Seeds the manual-simulation state and fires the hit burst.
-- Everything after this is driven inside PhysicsUpdate.
function ENT:StartTumble()
    self.IsTumbling      = true
    self.TumbleStartTime = CurTime()
    self.TumbleCrashed   = false

    -- Refresh ground reference from current position
    local gnd = self:FindGround(self:GetPos())
    if gnd ~= -1 then self.TumbleGroundZ = gnd end

    -- Seed linear velocity: full forward speed + strong initial nose-down
    -- (the "dive" component -- wreck arcs forward and down, not straight down)
    local fwd   = self:GetForward()
    local speed = self.Speed or 300
    self.TumbleVelocity = Vector(
        fwd.x * speed,
        fwd.y * speed,
        fwd.z * speed - 200   -- initial downward kick
    )

    -- Seed angular velocity (degrees / second)
    local sign = function() return (math.random(2) == 1) and 1 or -1 end
    self.TumbleAngVelocity = Vector(
        math.Rand(80,  200) * sign(),   -- pitch rate
        math.Rand(20,  80)  * sign(),   -- yaw rate
        math.Rand(150, 400) * sign()    -- roll rate (dominant)
    )

    -- Initial hit burst
    local pos = self:GetPos()
    local ed = EffectData()
    ed:SetOrigin(pos)
    ed:SetScale(4) ed:SetMagnitude(4) ed:SetRadius(400)
    util.Effect("500lb_air", ed, true, true)
    sound.Play("ambient/explosions/explode_4.wav", pos, 135, 95, 1.0)
end

-- Detonates the wreck on ground contact.
function ENT:CrashExplode()
    if self.TumbleCrashed then return end
    self.TumbleCrashed = true

    local pos = self:GetPos()

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

function ENT:DestroyPlane()
    if self.IsDestroyed then return end
    self.IsDestroyed = true

    self:FadeAndStopSounds(0.3)
    self:StartTumble()

    -- Safety: force-remove if crash detector never fires
    timer.Simple(12, function()
        if IsValid(self) then self:CrashExplode() end
    end)
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

    -- Tumble altitude monitor at 20 Hz
    if self.IsTumbling and not self.TumbleCrashed then
        local pos     = self:GetPos()
        local groundZ = self.TumbleGroundZ or -16384

        if pos.z <= groundZ + 150 then
            self:CrashExplode()
            return
        end

        local tr = util.TraceLine({
            start  = pos,
            endpos = pos + Vector(0, 0, -200),
            filter = self,
        })
        if tr.HitWorld then
            self:CrashExplode()
            return
        end

        self:NextThink(ct + 0.05)
        return true
    end

    if ct >= self.DieTime then
        self:Remove()
        return
    end

    if not IsValid(self.PhysObj) then
        self.PhysObj = self:GetPhysicsObject()
    end
    if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then
        self.PhysObj:Wake()
    end

    if ct >= self.NextAlertTime then
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

    local alpha = 255
    local age   = ct - self.SpawnTime
    local left  = self.DieTime - ct

    if age < self.FadeDuration then
        alpha = math.Clamp(255 * (age  / self.FadeDuration), 0, 255)
    elseif left < self.FadeDuration then
        alpha = math.Clamp(255 * (left / self.FadeDuration), 0, 255)
    end
    self:SetColor(Color(255, 255, 255, math.Round(alpha)))

    self:NextThink(ct)
    return true
end

-- ============================================================
-- PHYSICS UPDATE  (flight steering + manual tumble simulation)
-- ============================================================

-- Source's Havok object is effectively kinematic after being manually
-- driven every tick during flight -- handing it back to the engine
-- produces no movement.  The tumble is therefore simulated manually
-- here, exactly like the flight loop, so both are under full control.

function ENT:PhysicsUpdate(phys)
    if not self.DieTime or not self.sky then return end

    if self.IsTumbling then
        if self.TumbleCrashed then return end

        local dt      = engine.TickInterval()
        local gravity = physenv.GetGravity().z  -- typically -600 HU/s^2

        -- Accumulate gravity into the vertical velocity component
        self.TumbleVelocity.z = self.TumbleVelocity.z + gravity * dt

        -- Integrate position
        local pos    = self:GetPos()
        local newPos = pos + self.TumbleVelocity * dt

        -- Integrate angles from stored angular rates (deg/s)
        local av  = self.TumbleAngVelocity
        self.ang  = Angle(
            self.ang.p + av.x * dt,
            self.ang.y + av.y * dt,
            self.ang.r + av.z * dt
        )

        self:SetPos(newPos)
        self:SetAngles(self.ang)
        if IsValid(phys) then
            phys:SetPos(newPos)
            phys:SetAngles(self.ang)
        end
        return
    end

    -- ---- normal flight steering below ----

    if CurTime() >= self.DieTime then self:Remove() return end

    local pos = self:GetPos()
    local dt  = engine.TickInterval()

    if CurTime() >= self.AltDriftNextPick then
        self.AltDriftTarget   = self.sky + math.Rand(-self.AltDriftRange, self.AltDriftRange)
        self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)

    self.JitterPhase = self.JitterPhase + 0.02
    local jitter     = math.sin(self.JitterPhase) * self.JitterAmplitude
    local liveAlt    = self.AltDriftCurrent + jitter

    local flatPos    = Vector(pos.x, pos.y, 0)
    local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
    local dist       = flatPos:Distance(flatCenter)

    local orbitYaw = 0
    if dist > self.OrbitRadius and (self.TurnDelay or 0) < CurTime() then
        orbitYaw       = 0.1
        self.TurnDelay = CurTime() + 0.02
    end

    local flightFwd = Angle(0, self.flightYaw, 0):Forward()
    local trSky     = util.QuickTrace(pos, flightFwd * 3000, self)
    local skyYaw    = trSky.HitSky and 0.3 or 0

    local yawDelta = orbitYaw + skyYaw
    self.flightYaw = self.flightYaw + yawDelta
    self.ang.y     = self.ang.y     + yawDelta

    local rawYawDelta  = math.NormalizeAngle(self.flightYaw - (self.PrevYaw or self.flightYaw))
    self.PrevYaw       = self.flightYaw

    local targetRoll   = math.Clamp(rawYawDelta * -18, -15, 15)
    local rollLerp     = rawYawDelta ~= 0 and 0.08 or 0.03
    self.SmoothedRoll  = Lerp(rollLerp, self.SmoothedRoll, targetRoll)

    local fwdSpeed     = IsValid(phys) and phys:GetVelocity():Dot(flightFwd) or self.Speed
    local speedRatio   = math.Clamp(fwdSpeed / self.Speed, 0, 1)
    local targetPitch  = math.Clamp(speedRatio * 6, -8, 8)
    self.SmoothedPitch = Lerp(0.02, self.SmoothedPitch, targetPitch)

    self.ang.p = self.SmoothedPitch
    self.ang.r = self.SmoothedRoll

    local fwdDir = Angle(0, self.flightYaw, 0):Forward()
    local newPos = Vector(pos.x, pos.y, liveAlt) + fwdDir * self.Speed * dt

    self:SetPos(newPos)
    self:SetAngles(self.ang)

    if IsValid(phys) then
        phys:SetPos(newPos)
        phys:SetVelocity(fwdDir * self.Speed)
    end

    if not self:IsInWorld() then
        self:Debug("Plane moved out of world")
        self:Remove()
    end
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
    local trace      = { start = startPos, endpos = endPos, filter = filterList }
    local maxNumber  = 0

    while maxNumber < 100 do
        local tr = util.TraceLine(trace)
        if tr.HitWorld then return tr.HitPos.z end
        if IsValid(tr.Entity) then
            table.insert(filterList, tr.Entity)
        else
            break
        end
        maxNumber = maxNumber + 1
    end

    return -1
end
