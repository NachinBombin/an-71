AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_trailsystem.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PASS_SOUND_A = "jet/luxor/medium.wav"
local PASS_SOUND_B = "jet/luxor/external.wav"

-- MODEL_YAW_OFFSET: always added on top of flightYaw. Never touch this.
local MODEL_YAW_OFFSET = 180

-- ============================================================
-- ROLL CONSTANTS
-- ============================================================
local ROLL_SUSTAINED_GAIN = 2.2
local ROLL_TRANSIENT_GAIN = 55.0
local ROLL_MAX            = 25.0
local ROLL_LERP_IN        = 0.08
local ROLL_LERP_OUT       = 0.012

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
-- WORLD BOUNDARY PROBE
-- ============================================================
local PROBE_DIRS = {}
for i = 0, 7 do
    local a = math.rad(i * 45)
    PROBE_DIRS[i+1] = Vector(math.cos(a), math.sin(a), 0)
end
local PROBE_DIST   = 8192
local PROBE_MARGIN = 300

local function ProbeOrbitRadius(centerPos, skyZ, requestedRadius)
    local origin  = Vector(centerPos.x, centerPos.y, skyZ)
    local minDist = PROBE_DIST
    for _, dir in ipairs(PROBE_DIRS) do
        local tr = util.TraceLine({
            start  = origin,
            endpos = origin + dir * PROBE_DIST,
            mask   = MASK_SOLID_BRUSHONLY,
        })
        if tr.Hit then
            local d = (tr.HitPos - origin):Length2D()
            if d < minDist then minDist = d end
        end
    end
    local safe = math.max(200, minDist - PROBE_MARGIN)
    if safe < requestedRadius then
        print(string.format("[AN-71] OrbitRadius capped %d -> %d (nearest wall %.0f HU)",
            requestedRadius, safe, minDist))
    end
    return math.min(requestedRadius, safe)
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
    self.MaxHP        = self.MaxHP or 8000

    if self.CallDir:LengthSqr() <= 1 then self.CallDir = Vector(1,0,0) end
    self.CallDir.z = 0
    self.CallDir:Normalize()

    local ground = self:FindGround(self.CenterPos)
    if ground == -1 then self:Debug("FindGround failed") self:Remove() return end

    self.sky           = ground + self.SkyHeightAdd
    self.DieTime       = CurTime() + self.Lifetime
    self.SpawnTime     = CurTime()
    self.NextAlertTime = CurTime()
    self.IsDestroyed   = false
    self.DamageTier    = 0

    self.OrbitRadius = ProbeOrbitRadius(self.CenterPos, self.sky, self.OrbitRadius)

    -- Tumble
    self.IsTumbling        = false
    self.TumbleStartTime   = 0
    self.TumbleGroundZ     = ground
    self.TumbleCrashed     = false
    self.TumbleVelocity    = Vector(0,0,0)
    self.TumbleAngVelocity = Vector(0,0,0)

    -- Orbit
    self.OrbitDirection = (math.random(2) == 1) and 1 or -1
    self.RadialGain     = 0.5
    self.MaxTurnRate    = 28

    -- Roll state
    self.PrevTurnRate = 0

    -- Initial heading
    local right   = Vector(-self.CallDir.y, self.CallDir.x, 0)
    local tangent = Vector(right.x * self.OrbitDirection,
                           right.y * self.OrbitDirection, 0)
    tangent:Normalize()

    local spawnOffset = tangent * (-self.OrbitRadius * math.Rand(0.55, 0.95))
    local spawnPos    = Vector(
        self.CenterPos.x + spawnOffset.x,
        self.CenterPos.y + spawnOffset.y,
        self.sky
    )

    if not util.IsInWorld(spawnPos) then
        spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
    end
    if not util.IsInWorld(spawnPos) then
        self:Debug("Spawn position out of world after fallback") self:Remove() return
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

    self.flightYaw     = tangent:Angle().y
    self.PrevFlightYaw = self.flightYaw
    self.ang           = Angle(0, self.flightYaw + MODEL_YAW_OFFSET, 0)

    self.AltDriftCurrent  = self.sky
    self.AltDriftTarget   = self.sky
    self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    self.AltDriftRange    = self.AltDriftRange  or 300
    self.AltDriftLerp     = self.AltDriftLerp   or 0.001
    self.JitterPhase      = math.Rand(0, math.pi * 2)
    self.JitterAmplitude  = self.JitterAmplitude or 5
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

    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC() then SeedRelationship(ent) end
    end
    hook.Add("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex(), function(ent)
        if IsValid(ent) and ent:IsNPC() then
            timer.Simple(0, function() if IsValid(ent) then SeedRelationship(ent) end end)
        end
    end)

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

    self:Debug(string.format("Spawned at %s | OrbitRadius=%.0f", tostring(spawnPos), self.OrbitRadius))
end

-- ============================================================
-- DAMAGE TIER HELPER
-- ============================================================
local function CalcTier(hp, maxHP)
    local frac = hp / maxHP
    if frac > 0.66 then return 0
    elseif frac > 0.33 then return 1
    elseif frac > 0 then return 2
    else return 3 end
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
    if hp <= 0 then self:Debug("Shot down!") self:DestroyPlane() end
end

-- ============================================================
-- TUMBLE SYSTEM
-- ============================================================
function ENT:StartTumble()
    self.IsTumbling      = true
    self.TumbleStartTime = CurTime()
    self.TumbleCrashed   = false
    local gnd = self:FindGround(self:GetPos())
    if gnd ~= -1 then self.TumbleGroundZ = gnd end
    local travelFwd = Angle(0, self.flightYaw, 0):Forward()
    local speed     = self.Speed or 300
    self.TumbleVelocity = Vector(travelFwd.x * speed, travelFwd.y * speed, -200)
    local sign = function() return (math.random(2) == 1) and 1 or -1 end
    self.TumbleAngVelocity = Vector(
        math.Rand(80,  200) * sign(),
        math.Rand(20,  80)  * sign(),
        math.Rand(150, 400) * sign()
    )
    local pos = self:GetPos()
    local ed  = EffectData()
    ed:SetOrigin(pos) ed:SetScale(4) ed:SetMagnitude(4) ed:SetRadius(400)
    util.Effect("500lb_air", ed, true, true)
    sound.Play("ambient/explosions/explode_4.wav", pos, 135, 95, 1.0)
end

-- ============================================================
-- SAFE CRASH ORIGIN
-- ============================================================
local function FindSafeCrashOrigin(rawPos, centerPos)
    if util.IsInWorld(rawPos) then return rawPos end

    local target = Vector(centerPos.x, centerPos.y, rawPos.z)
    local dir    = target - rawPos
    local dist   = dir:Length()
    if dist < 1 then
        local raised = Vector(centerPos.x, centerPos.y, rawPos.z)
        if util.IsInWorld(raised) then return raised end
        return centerPos
    end
    dir = dir / dist

    local steps = math.ceil(dist / 200)
    for i = 1, steps do
        local candidate = rawPos + dir * (i * 200)
        if util.IsInWorld(candidate) then
            return candidate
        end
    end

    local atCenter = Vector(centerPos.x, centerPos.y, rawPos.z)
    if util.IsInWorld(atCenter) then return atCenter end
    return centerPos
end

-- ============================================================
-- GIB SPAWNER
-- ============================================================
local GIB_MODELS = {
    { mdl = "models/xqm/jetbody2tailpiecelarge.mdl",  count = 1 },
    { mdl = "models/xqm/jetbody2fuselagehuge.mdl",    count = 1 },
    { mdl = "models/xqm/jetbody2fuselagelarge.mdl",   count = 1 },
    { mdl = "models/xqm/jetwing2sizable.mdl",         count = 1 },
    { mdl = "models/xqm/jetbody2wingrootblarge.mdl",  count = 2 },
    { mdl = "models/xqm/jetenginehuge.mdl",           count = 2 },
}

local GIB_DESPAWN_TIME          = 40
local GIB_MASS                  = 2000
local GIB_NO_COLLIDE_TIME       = 1.0
local GIB_COLLISION_GROUP_START = COLLISION_GROUP_DEBRIS_TRIGGER
local GIB_COLLISION_GROUP_END   = COLLISION_GROUP_DEBRIS

local function SpawnGibs(safeOrigin)
    for _, entry in ipairs(GIB_MODELS) do
        for i = 1, entry.count do
            local gib = ents.Create("prop_physics")
            if not IsValid(gib) then continue end

            local scatter = Vector(
                math.Rand(-200, 200),
                math.Rand(-200, 200),
                math.Rand(  30, 120)
            )
            local spawnPos = safeOrigin + scatter
            if not util.IsInWorld(spawnPos) then
                spawnPos = safeOrigin + Vector(0, 0, 50)
            end

            local spawnAng = Angle(
                math.Rand(0, 360),
                math.Rand(0, 360),
                math.Rand(0, 360)
            )

            gib:SetModel(entry.mdl)
            gib:SetPos(spawnPos)
            gib:SetAngles(spawnAng)
            gib:SetCollisionGroup(GIB_COLLISION_GROUP_START)
            gib:Spawn()
            gib:Activate()
            gib:SetCollisionGroup(GIB_COLLISION_GROUP_START)

            local phys = gib:GetPhysicsObject()
            if IsValid(phys) then
                phys:SetDragCoefficient(0)
                phys:SetAngleDragCoefficient(0)
                phys:SetMass(GIB_MASS)
                phys:EnableCollisions(false)
                phys:EnableGravity(true)
                phys:Wake()
                phys:ApplyForceCenter(Vector(
                    math.Rand(-600, 600),
                    math.Rand(-600, 600),
                    math.Rand( 500, 1400)
                ) * GIB_MASS)
                phys:ApplyTorqueCenter(Vector(
                    math.Rand(-3000, 3000),
                    math.Rand(-3000, 3000),
                    math.Rand(-3000, 3000)
                ))
            end

            local gibRef = gib
            timer.Simple(0, function()
                if IsValid(gibRef) then
                    gibRef:Ignite(GIB_DESPAWN_TIME, 0)
                end
            end)

            timer.Simple(GIB_NO_COLLIDE_TIME, function()
                if not IsValid(gibRef) then return end
                gibRef:SetCollisionGroup(GIB_COLLISION_GROUP_END)
                local gibPhys = gibRef:GetPhysicsObject()
                if IsValid(gibPhys) then
                    gibPhys:EnableCollisions(true)
                    gibPhys:Wake()
                end
            end)

            timer.Simple(GIB_DESPAWN_TIME, function()
                if IsValid(gibRef) then
                    gibRef:Remove()
                end
            end)
        end
    end
end

function ENT:CrashExplode()
    if self.TumbleCrashed then return end
    self.TumbleCrashed = true
    local pos = self:GetPos()
    local ang = self:GetAngles()
    local safePos = FindSafeCrashOrigin(pos, self.CenterPos)

    local function boom(origin, sc)
        local ed = EffectData() ed:SetOrigin(origin)
        ed:SetScale(sc) ed:SetMagnitude(sc) ed:SetRadius(sc * 100)
        util.Effect("500lb_air", ed, true, true)
    end
    local ed1 = EffectData() ed1:SetOrigin(safePos)
    ed1:SetScale(6) ed1:SetMagnitude(6) ed1:SetRadius(600)
    util.Effect("HelicopterMegaBomb", ed1, true, true)
    boom(safePos, 5)
    boom(safePos + Vector(0,0,80),  4)
    boom(safePos + Vector(0,0,180), 3)
    sound.Play("ambient/explosions/explode_8.wav", safePos, 140, 90, 1.0)
    sound.Play("weapon_AWP.Single",                safePos, 145, 60, 1.0)
    util.BlastDamage(self, self, safePos, 400, 200)

    SpawnGibs(safePos)

    self:Remove()
end

function ENT:DestroyPlane()
    if self.IsDestroyed then return end
    self.IsDestroyed = true
    self:FadeAndStopSounds(0.3)
    self:StartTumble()
    timer.Simple(12, function() if IsValid(self) then self:CrashExplode() end end)
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
    if self.IsTumbling and not self.TumbleCrashed then
        local pos     = self:GetPos()
        local groundZ = self.TumbleGroundZ or -16384
        if pos.z <= groundZ + 150 then self:CrashExplode() return end
        local tr = util.TraceLine({ start = pos, endpos = pos + Vector(0,0,-200), filter = self })
        if tr.HitWorld then self:CrashExplode() return end
        self:NextThink(ct + 0.05)
        return true
    end
    if ct >= self.DieTime then self:Remove() return end
    if not IsValid(self.PhysObj) then self.PhysObj = self:GetPhysicsObject() end
    if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then self.PhysObj:Wake() end
    if ct >= self.NextAlertTime then
        local plys = player.GetAll()
        for _, ent in ipairs(ents.GetAll()) do
            -- ents.FindByClass("npc_*") does not support wildcards in GMod;
            -- iterate all and check IsNPC() + capability guard.
            if not IsValid(ent) then continue end
            if not ent:IsNPC() then continue end
            if not ent.UpdateEnemyMemory then continue end
            for _, ply in ipairs(plys) do
                if IsValid(ply) and ply:Alive() then
                    ent:UpdateEnemyMemory(ply, ply:GetPos())
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
-- PHYSICS UPDATE
-- ============================================================
function ENT:PhysicsUpdate(phys)
    if not self.DieTime or not self.sky then return end

    if self.IsTumbling then
        if self.TumbleCrashed then return end
        local dt      = engine.TickInterval()
        local gravity = physenv.GetGravity().z
        self.TumbleVelocity.z = self.TumbleVelocity.z + gravity * dt
        local pos    = self:GetPos()
        local newPos = pos + self.TumbleVelocity * dt
        local av     = self.TumbleAngVelocity
        self.ang = Angle(
            self.ang.p + av.x * dt,
            self.ang.y + av.y * dt,
            self.ang.r + av.z * dt
        )
        self:SetPos(newPos)
        self:SetAngles(self.ang)
        if IsValid(phys) then phys:SetPos(newPos) phys:SetAngles(self.ang) end
        return
    end

    if CurTime() >= self.DieTime then self:Remove() return end

    local pos = self:GetPos()
    local dt  = engine.TickInterval()

    if CurTime() >= self.AltDriftNextPick then
        self.AltDriftTarget   = self.sky - math.Rand(0, self.AltDriftRange)
        self.AltDriftNextPick = CurTime() + math.Rand(12, 30)
    end
    self.AltDriftCurrent = Lerp(self.AltDriftLerp, self.AltDriftCurrent, self.AltDriftTarget)
    self.JitterPhase     = self.JitterPhase + 0.02
    local liveAlt = math.Clamp(
        self.AltDriftCurrent + math.sin(self.JitterPhase) * self.JitterAmplitude,
        self.sky - self.AltDriftRange,
        self.sky
    )

    local flatPos    = Vector(pos.x, pos.y, 0)
    local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
    local toCenter   = flatCenter - flatPos
    local dist       = toCenter:Length()

    local radialDir = (dist > 1) and (toCenter / dist) or Vector(0,0,0)

    local tangentDir = Vector(
        -radialDir.y * self.OrbitDirection,
         radialDir.x * self.OrbitDirection,
        0
    )
    if tangentDir:LengthSqr() < 0.001 then
        local fwdFb = Angle(0, self.flightYaw, 0):Forward()
        tangentDir = Vector(fwdFb.x, fwdFb.y, 0)
    end
    tangentDir:Normalize()

    local radialError = 0
    if self.OrbitRadius > 0 then
        radialError = math.Clamp((dist - self.OrbitRadius) / self.OrbitRadius, -1, 1)
    end

    local desired2 = Vector(
        tangentDir.x + radialDir.x * radialError * self.RadialGain,
        tangentDir.y + radialDir.y * radialError * self.RadialGain,
        0
    )
    if desired2:LengthSqr() < 0.001 then desired2 = tangentDir end
    desired2:Normalize()

    local fwdAngle = Angle(0, self.flightYaw, 0)
    local fwd3     = fwdAngle:Forward()
    local fwd2     = Vector(fwd3.x, fwd3.y, 0)
    fwd2:Normalize()

    local cross    = fwd2.x * desired2.y - fwd2.y * desired2.x
    local dot      = fwd2.x * desired2.x + fwd2.y * desired2.y
    local urgency  = (1 - dot) * 0.5
    local turnRate = math.Clamp(cross * urgency * self.MaxTurnRate * 2,
                                -self.MaxTurnRate, self.MaxTurnRate)

    self.flightYaw = self.flightYaw + turnRate * dt

    local turnRateDelta = turnRate - self.PrevTurnRate
    self.PrevTurnRate   = turnRate

    local sustained  = math.Clamp(turnRate      * ROLL_SUSTAINED_GAIN, -20, 20)
    local transient  = math.Clamp(turnRateDelta * ROLL_TRANSIENT_GAIN, -12, 12)
    local rollTarget = math.Clamp(sustained + transient, -ROLL_MAX, ROLL_MAX)

    local building = (rollTarget * self.SmoothedRoll >= 0)
                     and (math.abs(rollTarget) > math.abs(self.SmoothedRoll))
    local lerpRate = building and ROLL_LERP_IN or ROLL_LERP_OUT

    self.SmoothedRoll = Lerp(lerpRate, self.SmoothedRoll, rollTarget)

    local climbDelta   = math.Clamp((liveAlt - pos.z) / 400, -1, 1)
    local targetPitch  = math.Clamp(climbDelta * 6, -8, 8)
    self.SmoothedPitch = Lerp(0.03, self.SmoothedPitch, targetPitch)

    self.ang = Angle(
        self.SmoothedPitch,
        self.flightYaw + MODEL_YAW_OFFSET,
        self.SmoothedRoll
    )

    local fwdDir = fwdAngle:Forward()
    local newPos = pos + fwdDir * self.Speed * dt
    newPos.z     = Lerp(0.07, pos.z, liveAlt)

    if not util.IsInWorld(newPos) then
        self:Debug("OOB guard fired -- steering to center")
        local toC = flatCenter - Vector(pos.x, pos.y, 0)
        toC.z = 0
        if toC:LengthSqr() < 0.001 then toC = Vector(-fwd2.x, -fwd2.y, 0) end
        toC:Normalize()
        local sCross = fwd2.x * toC.y - fwd2.y * toC.x
        self.flightYaw = self.flightYaw
            + math.Clamp(sCross * self.MaxTurnRate, -self.MaxTurnRate, self.MaxTurnRate) * dt
        self:SetPos(pos)
        self:SetAngles(Angle(self.SmoothedPitch, self.flightYaw + MODEL_YAW_OFFSET, self.SmoothedRoll))
        return
    end

    self:SetPos(newPos)
    self:SetAngles(self.ang)
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
