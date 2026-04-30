-- ============================================================
-- TRAIL SYSTEM  --  an-71 framework
-- One unified system: always active from spawn.
-- All emission points run at all times.
-- Tier drives color + size: white vapor -> dark smoke.
-- ============================================================

local TRAIL_MATERIAL = Material( "trails/smoke" )

local SAMPLE_RATE = 0.025  -- seconds between position samples

-- ============================================================
-- EMISSION POINTS
-- All 4 are active for the entire lifetime of the plane.
-- Model-local offsets (X = right/left, Y = fwd/back, Z = up)
-- Tune these to match the AN-71 model mesh.
-- ============================================================
local TRAIL_POSITIONS = {
    Vector(  240,    0,   3 ),   -- right wingtip
    Vector( -240,    0,   3 ),   -- left wingtip
    Vector(   60,  -90,  -5 ),   -- right engine exhaust
    Vector(  -60,  -90,  -5 ),   -- left engine exhaust
}

-- ============================================================
-- TIER CONFIG
-- Applied to ALL emission points simultaneously.
-- Tier 0 = full health (white vapor, always visible).
-- Each tier: darker color, bigger beams, longer trail.
-- ============================================================
local TIER_CONFIG = {
    [0] = { r = 255, g = 255, b = 255, a = 110, startSize = 22, endSize =  4, lifetime = 4 },
    [1] = { r = 170, g = 170, b = 170, a = 150, startSize = 34, endSize =  8, lifetime = 5 },
    [2] = { r =  55, g =  55, b =  55, a = 195, startSize = 50, endSize = 14, lifetime = 6 },
    [3] = { r =  12, g =  12, b =  12, a = 225, startSize = 70, endSize = 22, lifetime = 8 },
}

-- State table: [entIndex] = { tier, nextSample, trails = { [i] = { positions={} } } }
local PlaneTrails = {}

-- ============================================================
-- PUBLIC: called from net.Receive in cl_init.lua
-- Just flips the tier -- no trail slots need rebuilding.
-- ============================================================
function TrailSystem_SetTier( entIndex, tier )
    local state = PlaneTrails[entIndex]
    if not state then return end
    state.tier = tier
end

-- ============================================================
-- INTERNALS
-- ============================================================
local function EnsureRegistered( entIndex )
    if PlaneTrails[entIndex] then return end
    local trails = {}
    for i = 1, #TRAIL_POSITIONS do
        trails[i] = { positions = {} }
    end
    PlaneTrails[entIndex] = {
        tier       = 0,
        nextSample = 0,
        trails     = trails,
    }
end

local function DrawBeam( positions, cfg )
    local n = #positions
    if n < 2 then return end

    local Time = CurTime()
    local lt   = cfg.lifetime

    -- Prune expired positions
    for i = n, 1, -1 do
        if Time - positions[i].time > lt then
            table.remove( positions, i )
        end
    end

    n = #positions
    if n < 2 then return end

    render.SetMaterial( TRAIL_MATERIAL )
    render.StartBeam( n )
    for _, pd in ipairs( positions ) do
        local Scale = math.Clamp( (pd.time + lt - Time) / lt, 0, 1 )
        local size  = cfg.startSize * Scale + cfg.endSize * (1 - Scale)
        render.AddBeam( pd.pos, size, pd.time * 50,
            Color( cfg.r, cfg.g, cfg.b, cfg.a * Scale * Scale ) )
    end
    render.EndBeam()
end

-- ============================================================
-- THINK: sample world positions for all emission points
-- ============================================================
hook.Add( "Think", "bombin_an71_trails_update", function()
    local Time = CurTime()

    -- Auto-discover any new an-71 entities
    for _, ent in ipairs( ents.FindByClass( "ent_an71_plane" ) ) do
        EnsureRegistered( ent:EntIndex() )
    end

    for entIndex, state in pairs( PlaneTrails ) do
        local ent = Entity( entIndex )
        if not IsValid( ent ) then
            PlaneTrails[entIndex] = nil
            continue
        end

        if Time < state.nextSample then continue end
        state.nextSample = Time + SAMPLE_RATE

        local pos = ent:GetPos()
        local ang = ent:GetAngles()

        for i, trail in ipairs( state.trails ) do
            local wpos = LocalToWorld( TRAIL_POSITIONS[i], Angle(0,0,0), pos, ang )
            table.insert( trail.positions, { time = Time, pos = wpos } )
            table.sort( trail.positions, function( a, b ) return a.time > b.time end )
        end
    end
end )

-- ============================================================
-- DRAW: render beams using the current tier's config
-- ============================================================
hook.Add( "PostDrawTranslucentRenderables", "bombin_an71_trails_draw", function( bDepth, bSkybox )
    if bSkybox then return end

    for _, state in pairs( PlaneTrails ) do
        local cfg = TIER_CONFIG[ state.tier ] or TIER_CONFIG[0]
        for _, trail in ipairs( state.trails ) do
            DrawBeam( trail.positions, cfg )
        end
    end
end )
