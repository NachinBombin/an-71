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

ENT.FadeDuration = 2.0
ENT.ModelPath    = "models/an71/an71.mdl"
ENT.EngineSound  = "vehicles/apc/apc_idle1.wav"
ENT.AlertInterval = 0.3

-- Seeds hatred relationship on a single NPC toward all current players
local function SeedRelationship(npc)
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            npc:AddEntityRelationship(ply, D_HT, 99)
        end
    end
end

function ENT:Initialize()
    self.CenterPos    = self:GetVar("CenterPos",    self:GetPos())
    self.CallDir      = self:GetVar("CallDir",      Vector(1, 0, 0))
    self.Lifetime     = self:GetVar("Lifetime",     40)
    self.Speed        = self:GetVar("Speed",        300)
    self.OrbitRadius  = self:GetVar("OrbitRadius",  3000)
    self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 6000)

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

    self.sky       = ground + self.SkyHeightAdd
    self.DieTime   = CurTime() + self.Lifetime
    self.SpawnTime = CurTime()
    self.NextPassSound = CurTime() + math.Rand(3, 6)
    self.NextAlertTime = CurTime()

    -- One-time relationship seed for all NPCs currently on the map
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC() then
            SeedRelationship(ent)
        end
    end

    -- Hook to catch NPCs that spawn after the plane arrives
    hook.Add("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex(), function(ent)
        if IsValid(ent) and ent:IsNPC() then
            -- Delay one tick so the NPC is fully initialized
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
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    self:SetPos(spawnPos)

    self:SetRenderMode(RENDERMODE_TRANSALPHA)
    self:SetColor(Color(255, 255, 255, 0))

    local ang = self.CallDir:Angle()
    self:SetAngles(Angle(0, ang.y + 90, 0))
    self.ang = self:GetAngles()

    self.PhysObj = self:GetPhysicsObject()
    if IsValid(self.PhysObj) then
        self.PhysObj:Wake()
        self.PhysObj:EnableGravity(false)
    end

    self.EngineLoop = CreateSound(game.GetWorld(), self.EngineSound)
    if self.EngineLoop then
        self.EngineLoop:SetSoundLevel(80)
        self.EngineLoop:Play()
    end

    sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, 100, 0.7)
    self:Debug("Spawned at " .. tostring(spawnPos))
end

function ENT:Think()
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

    -- NPC alert broadcast: unconditional, no per-NPC branching
    if ct >= self.NextAlertTime then
        local npcs = ents.FindByClass("npc_*")
        local plys = player.GetAll()
        for _, npc in ipairs(npcs) do
            for _, ply in ipairs(plys) do
                npc:UpdateEnemyMemory(ply, ply:GetPos())
            end
        end
        self.NextAlertTime = ct + ENT.AlertInterval
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

function ENT:PhysicsUpdate(phys)
    if CurTime() >= self.DieTime then
        self:Remove()
        return
    end

    local pos = self:GetPos()
    self:SetPos(Vector(pos.x, pos.y, self.sky))
    self:SetAngles(self.ang)

    if IsValid(phys) then
        phys:SetVelocity(self:GetForward() * self.Speed)
    end

    local flatPos    = Vector(self:GetPos().x, self:GetPos().y, 0)
    local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
    local dist       = flatPos:Distance(flatCenter)

    if dist > self.OrbitRadius and (self.TurnDelay or 0) < CurTime() then
        self.ang       = self.ang + Angle(0, 0.1, 0)
        self.TurnDelay = CurTime() + 0.02
    end

    local tr = util.QuickTrace(self:GetPos(), self:GetForward() * 3000, self)
    if tr.HitSky then
        self.ang = self.ang + Angle(0, 0.3, 0)
    end

    if not self:IsInWorld() then
        self:Debug("Plane moved out of world")
        self:Remove()
    end
end

function ENT:OnRemove()
    if self.EngineLoop then self.EngineLoop:Stop() end
    hook.Remove("OnEntityCreated", "an71_relationship_hook_" .. self:EntIndex())
end

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
