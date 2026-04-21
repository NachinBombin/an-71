if SERVER then
    AddCSLuaFile()

    util.AddNetworkString("AN71_FlareSpawned")
    util.AddNetworkString("AN71_ManualSpawn")

    local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

    local cv_enabled    = CreateConVar("npc_an71_enabled",    "1",    SHARED_FLAGS, "Enable/disable AN-71 flyovers.")
    local cv_chance     = CreateConVar("npc_an71_chance",     "0.12", SHARED_FLAGS, "Probability per check.")
    local cv_interval   = CreateConVar("npc_an71_interval",   "12",   SHARED_FLAGS, "Check interval (s).")
    local cv_cooldown   = CreateConVar("npc_an71_cooldown",   "50",   SHARED_FLAGS, "Cooldown (s).")
    local cv_max_dist   = CreateConVar("npc_an71_max_dist",   "3000", SHARED_FLAGS, "Max NPC-target distance.")
    local cv_min_dist   = CreateConVar("npc_an71_min_dist",   "400",  SHARED_FLAGS, "Min NPC-target distance.")
    local cv_delay      = CreateConVar("npc_an71_delay",      "5",    SHARED_FLAGS, "Delay after flare (s).")
    local cv_life       = CreateConVar("npc_an71_lifetime",   "40",   SHARED_FLAGS, "Plane lifetime (s).")
    local cv_speed      = CreateConVar("npc_an71_speed",      "300",  SHARED_FLAGS, "Plane speed (HU/s).")
    local cv_radius     = CreateConVar("npc_an71_radius",     "3000", SHARED_FLAGS, "Orbit radius (HU).")
    local cv_height     = CreateConVar("npc_an71_height",     "6000", SHARED_FLAGS, "Height above ground (HU).")
    local cv_announce   = CreateConVar("npc_an71_announce",   "0",    SHARED_FLAGS, "Debug prints.")
    -- Model yaw offset toggle: 0 = ang.y - 90 (same as AC-130), 1 = ang.y + 90
    CreateConVar("npc_an71_model_flip", "0", SHARED_FLAGS, "Flip model yaw offset: 0=same as AC-130 (-90), 1=flipped (+90).")

    local CALLERS = {
        ["npc_combine_s"]     = true,
        ["npc_metropolice"]   = true,
        ["npc_combine_elite"] = true,
    }

    local function AN71_Debug(msg)
        if not cv_announce:GetBool() then return end
        local full = "[AN-71] " .. msg
        print(full)
        for _, ply in ipairs(player.GetHumans()) do
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, full) end
        end
    end

    local function CheckSkyAbove(pos)
        local tr = util.TraceLine({
            start  = pos + Vector(0, 0, 50),
            endpos = pos + Vector(0, 0, 1050),
        })
        if tr.Hit and not tr.HitSky then
            tr = util.TraceLine({
                start  = tr.HitPos + Vector(0, 0, 50),
                endpos = tr.HitPos + Vector(0, 0, 1000),
            })
        end
        return not (tr.Hit and not tr.HitSky)
    end

    local function ThrowSupportFlare(npc, targetPos)
        local npcEyePos = npc:EyePos()
        local toTarget  = (targetPos - npcEyePos):GetNormalized()

        local flare = ents.Create("ent_bombin_flare_blue")
        if not IsValid(flare) then
            AN71_Debug("Flare spawn failed: ent_bombin_flare_blue invalid")
            return nil
        end

        flare:SetPos(npcEyePos + toTarget * 52)
        flare:SetAngles(npc:GetAngles())
        flare:Spawn()
        flare:Activate()

        local dir  = targetPos - flare:GetPos()
        local dist = dir:Length()
        dir:Normalize()

        timer.Simple(0, function()
            if not IsValid(flare) then return end
            local phys = flare:GetPhysicsObject()
            if not IsValid(phys) then
                AN71_Debug("Flare physics invalid after spawn")
                return
            end
            phys:SetVelocity(dir * 700 + Vector(0, 0, dist * 0.25))
            phys:Wake()
        end)

        net.Start("AN71_FlareSpawned")
        net.WriteEntity(flare)
        net.Broadcast()

        AN71_Debug("Flare thrown successfully")
        return flare
    end

    local function SpawnAN71AtPos(centerPos, callDir)
        if not scripted_ents.GetStored("ent_an71_plane") then
            AN71_Debug("Plane spawn failed: ent_an71_plane is not registered")
            return false
        end

        local plane = ents.Create("ent_an71_plane")
        if not IsValid(plane) then
            AN71_Debug("Plane spawn failed: ents.Create returned invalid entity")
            return false
        end

        plane:SetPos(centerPos)
        plane:SetAngles(callDir:Angle())
        plane:SetVar("CenterPos",    centerPos)
        plane:SetVar("CallDir",      callDir)
        plane:SetVar("Lifetime",     cv_life:GetFloat())
        plane:SetVar("Speed",        cv_speed:GetFloat())
        plane:SetVar("OrbitRadius",  cv_radius:GetFloat())
        plane:SetVar("SkyHeightAdd", cv_height:GetFloat())
        plane:Spawn()
        plane:Activate()

        if not IsValid(plane) then
            AN71_Debug("Plane invalid after Spawn()")
            return false
        end

        AN71_Debug("Plane entity created")
        return true
    end

    local function FireAN71(npc, target)
        if not IsValid(npc) then
            AN71_Debug("Call rejected: npc invalid") return false
        end
        if not IsValid(target) or not target:IsPlayer() or not target:Alive() then
            AN71_Debug("Call rejected: target invalid") return false
        end

        local targetPos = target:GetPos() + Vector(0, 0, 36)
        if not CheckSkyAbove(targetPos) then
            AN71_Debug("Call rejected: no open sky above target") return false
        end

        local callDir = targetPos - npc:GetPos()
        callDir.z = 0
        if callDir:LengthSqr() <= 1 then callDir = npc:GetForward() callDir.z = 0 end
        if callDir:LengthSqr() <= 1 then callDir = Vector(1, 0, 0) end
        callDir:Normalize()

        local flare = ThrowSupportFlare(npc, targetPos)
        if not IsValid(flare) then
            AN71_Debug("Call rejected: flare could not be created") return false
        end

        local fallbackPos = Vector(targetPos.x, targetPos.y, targetPos.z)
        local storedDir   = Vector(callDir.x, callDir.y, callDir.z)

        AN71_Debug("Flare deployed, waiting " .. cv_delay:GetFloat() .. "s")

        timer.Simple(cv_delay:GetFloat(), function()
            local centerPos = IsValid(flare) and flare:GetPos() or fallbackPos
            AN71_Debug("Attempting plane spawn at " .. tostring(centerPos))
            SpawnAN71AtPos(centerPos, storedDir)
        end)

        return true
    end

    -- Manual spawn via Q-menu button
    net.Receive("AN71_ManualSpawn", function(len, ply)
        if not IsValid(ply) then return end
        local eyePos  = ply:EyePos()
        local callDir = ply:EyeAngles():Forward()
        callDir.z = 0
        if callDir:LengthSqr() <= 1 then callDir = Vector(1, 0, 0) end
        callDir:Normalize()
        SpawnAN71AtPos(eyePos, callDir)
        AN71_Debug("Manual spawn by " .. ply:Nick())
    end)

    -- NPC trigger loop
    timer.Create("AN71_Think", 0.5, 0, function()
        if not cv_enabled:GetBool() then return end

        local now      = CurTime()
        local interval = math.max(1, cv_interval:GetFloat())

        for _, npc in ipairs(ents.GetAll()) do
            if not IsValid(npc) or not CALLERS[npc:GetClass()] then continue end

            if not npc.__an71_hooked then
                npc.__an71_hooked    = true
                npc.__an71_nextCheck = now + math.Rand(1, interval)
                npc.__an71_lastCall  = 0
            end

            if now < npc.__an71_nextCheck then continue end

            local jitter = math.min(2, interval * 0.5)
            npc.__an71_nextCheck = now + interval + math.Rand(-jitter, jitter)

            if now - npc.__an71_lastCall < cv_cooldown:GetFloat() then continue end
            if npc:Health() <= 0 then continue end

            local enemy = npc:GetEnemy()
            if not IsValid(enemy) or not enemy:IsPlayer() or not enemy:Alive() then continue end

            local dist = npc:GetPos():Distance(enemy:GetPos())
            if dist > cv_max_dist:GetFloat() or dist < cv_min_dist:GetFloat() then continue end
            if math.random() > cv_chance:GetFloat() then continue end

            if FireAN71(npc, enemy) then
                npc.__an71_lastCall = now
                AN71_Debug("Flyover accepted for " .. tostring(enemy))
            end
        end
    end)
end

if CLIENT then
    local activeFlares = {}

    net.Receive("AN71_FlareSpawned", function()
        local flare = net.ReadEntity()
        if IsValid(flare) then
            activeFlares[flare:EntIndex()] = flare
        end
    end)

    hook.Add("Think", "AN71_FlareLight", function()
        for idx, flare in pairs(activeFlares) do
            if not IsValid(flare) then
                activeFlares[idx] = nil
                continue
            end
            local dlight = DynamicLight(flare:EntIndex())
            if dlight then
                dlight.Pos        = flare:GetPos()
                dlight.r          = 0
                dlight.g          = 80
                dlight.b          = 255
                dlight.Brightness = (math.random() > 0.4) and math.Rand(4.0, 6.0) or math.Rand(0.0, 0.2)
                dlight.Size       = 55
                dlight.Decay      = 3000
                dlight.DieTime    = CurTime() + 0.05
            end
        end
    end)
end
