AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PASS_SOUNDS = {
    "npc/combine_gunship/gunship_ping_search.wav",
    "vehicles/airboat/fan_blade_fullthrottle_loop1.wav",
}

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
    self.NextPassSound = CurTime() + math.Rand(3, 6)
    self.NextAlertTime = CurTime()
    self.IsDestroyed   = false

    -- Seed hatred on every NPC already on the map
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC() then
            SeedRelationship(ent)
        end
    end

    -- Seed hatred on any NPC that spawns while the plane is alive
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

    self:SetRenderMode(RENDERMODE_TRANSALPHA)
    self:SetColor(Color(255, 255, 255, 0))

    -- Build self.ang directly — never read back via GetAngles() on a VPHYSICS entity
    -- because the physics object owns the true rotation and GetAngles() may return stale data.
    -- PhysicsUpdate applies self.ang to both entity and physobj every tick.
    local angYaw = self.CallDir:Angle().y
    self.ang = Angle(0, angYaw + 180, 0)
    self.PrevYaw = self.ang.y  -- seed from self.ang, not GetAngles()

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(12, 30)

    self.JitterPhase   = math.Rand(0, math.pi * 2)
    self.SmoothedRoll  = 0
    self.SmoothedPitch = 0

    self:SetNWInt("HP",    self.MaxHP)
    self:SetNWInt("MaxHP", self.MaxHP)

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:Wake()
        self.PhysObj:EnableGravity(false)
        -- Apply the correct angle to the physobj directly at spawn
        self.PhysObj:SetAngles(self.ang)
    end

    self.EngineLoop = CreateSound(self, self.EngineSound)
    if self.EngineLoop then
        self.EngineLoop:SetSoundLevel(80)
        self.EngineLoop:Play()
    end

    sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, 100, 0.7)
    self:Debug("Spawned at " .. tostring(spawnPos) .. " yaw=" .. tostring(self.ang.y))
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

    if hp <= 0 then
        self:Debug("Shot down!")
        self:DestroyPlane()
    end
end

function ENT:DestroyPlane()
    if self.IsDestroyed then return end
    self.IsDestroyed = true

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

    sound.Play("ambient/explosions/explode_8.wav", pos, 140, 90,  1.0)
    sound.Play("weapon_AWP.Single",               pos, 145, 60,  1.0)

    util.BlastDamage(self, self, pos, 400, 200)

    self:Remove()
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

    if ct >= self.NextPassSound then
        sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, math.random(96, 104), 0.7)
        self.NextPassSound = ct + math.Rand(4, 7)
    end

    -- NPC alert pulse: feed live player positions to every NPC on the map
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

    -- Fade in / out
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
-- FLIGHT / ORBIT
-- ============================================================

function ENT:PhysicsUpdate(phys)
    if not self.DieTime or not self.sky then return end

    if CurTime() >= self.DieTime then
        self:Remove()
        return
    end

    local pos = self:GetPos()

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

    local trSky  = util.QuickTrace(self:GetPos(), self:GetForward() * 3000, self)
    local skyYaw = trSky.HitSky and 0.3 or 0

    self.ang = self.ang + Angle(0, orbitYaw + skyYaw, 0)

    local currentYaw  = self.ang.y
    local rawYawDelta = math.NormalizeAngle(currentYaw - (self.PrevYaw or currentYaw))
    self.PrevYaw      = currentYaw

    local targetRoll  = math.Clamp(rawYawDelta * -18, -15, 15)
    local rollLerp    = rawYawDelta ~= 0 and 0.08 or 0.03
    self.SmoothedRoll = Lerp(rollLerp, self.SmoothedRoll, targetRoll)

    local vel          = IsValid(phys) and phys:GetVelocity() or Vector(0, 0, 0)
    local forwardSpeed = vel:Dot(self:GetForward())
    local speedRatio   = math.Clamp(forwardSpeed / self.Speed, 0, 1)
    local targetPitch  = math.Clamp(speedRatio * 6, -8, 8)
    self.SmoothedPitch = Lerp(0.02, self.SmoothedPitch, targetPitch)

    self.ang.p = self.SmoothedPitch
    self.ang.r = self.SmoothedRoll

    self:SetPos(Vector(pos.x, pos.y, liveAlt))
    self:SetAngles(self.ang)

    if IsValid(phys) then
        phys:SetVelocity(self:GetForward() * self.Speed)
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
    if self.EngineLoop then self.EngineLoop:Stop() end
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
