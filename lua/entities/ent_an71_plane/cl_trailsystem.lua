-- ============================================================
-- TRAIL SYSTEM  –  an-71 framework
-- White vapor trails (always on) + dark smoke on damage tiers
-- Adapted from LVS base cl_trailsystem.lua
-- ============================================================

local VAPOR_MATERIAL = Material( "trails/smoke" )
local SMOKE_MATERIAL = Material( "particle/particle_smokegrenade" )

local SAMPLE_RATE = 0.025  -- seconds between position samples

-- ============================================================
-- CONFIGURATION
-- Model-local offsets (X = right/left, Y = fwd/back, Z = up)
-- Tune these to match the AN-71 model mesh.
-- ============================================================
local VAPOR_POSITIONS = {
    Vector( 240,   0, 3 ),   -- right wingtip
    Vector( -240,  0, 3 ),   -- left wingtip
}

local SMOKE_TIERS = {
    [1] = {
        color     = Color( 70,  70,  70,  160 ),
        startSize = 12,
        endSize   = 4,
        lifetime  = 5,
        positions = {
            Vector(  60, -90, -5 ),   -- right engine exhaust
            Vector( -60, -90, -5 ),   -- left engine exhaust
        },
    },
    [2] = {
        color     = Color( 35,  35,  35,  200 ),
        startSize = 22,
        endSize   = 8,
        lifetime  = 6,
        positions = {
            Vector(  60, -90, -5 ),
            Vector( -60, -90, -5 ),
            Vector(   0,   0, 15 ),   -- top fuselage
        },
    },
    [3] = {
        color     = Color( 10,  10,  10,  230 ),
        startSize = 32,
        endSize   = 12,
        lifetime  = 8,
        positions = {
            Vector(  60, -90, -5 ),
            Vector( -60, -90, -5 ),
            Vector(   0,   0, 15 ),
            Vector(  80,   0,  5 ),   -- right fuselage
            Vector( -80,   0,  5 ),   -- left fuselage
        },
    },
}

-- State table: [entIndex] = { tier, nextSample, vaporTrails={...}, smokeTrails={...} }
local PlaneTrails = {}

-- ============================================================
-- PUBLIC: called from net.Receive in cl_init.lua
-- ============================================================
function TrailSystem_SetTier( entIndex, tier )
    local state = PlaneTrails[entIndex]
    if not state or state.tier == tier then return end
    state.tier = tier

    -- Rebuild smoke trail slots for the new tier
    state.smokeTrails = {}
    if tier > 0 then
        local cfg = SMOKE_TIERS[tier]
        if cfg then
            for i = 1, #cfg.positions do
                state.smokeTrails[i] = { positions = {} }
            end
        end
    end
end

-- ============================================================
-- INTERNALS
-- ============================================================
local function EnsureRegistered( entIndex )
    if PlaneTrails[entIndex] then return end
    local state = {
        tier        = 0,
        nextSample  = 0,
        vaporTrails = {},
        smokeTrails = {},
    }
    for i = 1, #VAPOR_POSITIONS do
        state.vaporTrails[i] = { positions = {} }
    end
    PlaneTrails[entIndex] = state
end

local function DrawBeam( positions, lifetime, startSize, endSize, col, mat )
    local n = #positions
    if n < 2 then return end

    local Time = CurTime()

    -- Prune expired positions
    for i = n, 1, -1 do
        if Time - positions[i].time > lifetime then
            table.remove( positions, i )
        end
    end

    n = #positions
    if n < 2 then return end

    render.SetMaterial( mat )
    render.StartBeam( n )
    for _, pd in ipairs( positions ) do
        local Scale = math.Clamp( (pd.time + lifetime - Time) / lifetime, 0, 1 )
        local size  = startSize * Scale + endSize * (1 - Scale)
        render.AddBeam( pd.pos, size, pd.time * 50,
            Color( col.r, col.g, col.b, col.a * Scale * Scale ) )
    end
    render.EndBeam()
end

-- ============================================================
-- THINK: sample world positions every SAMPLE_RATE seconds
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

        -- Sample vapor trails (always active)
        for i, trail in ipairs( state.vaporTrails ) do
            table.insert( trail.positions, { time = Time, pos = LocalToWorld( VAPOR_POSITIONS[i], Angle(0,0,0), pos, ang ) } )
            table.sort( trail.positions, function( a, b ) return a.time > b.time end )
        end

        -- Sample smoke trails (only when damaged)
        if state.tier > 0 then
            local cfg = SMOKE_TIERS[state.tier]
            if cfg then
                for i, trail in ipairs( state.smokeTrails ) do
                    if cfg.positions[i] then
                        table.insert( trail.positions, { time = Time, pos = LocalToWorld( cfg.positions[i], Angle(0,0,0), pos, ang ) } )
                        table.sort( trail.positions, function( a, b ) return a.time > b.time end )
                    end
                end
            end
        end
    end
end )

-- ============================================================
-- DRAW: render all active beams
-- ============================================================
hook.Add( "PostDrawTranslucentRenderables", "bombin_an71_trails_draw", function( bDepth, bSkybox )
    if bSkybox then return end

    for _, state in pairs( PlaneTrails ) do
        -- Vapor trails: always white, thin, short lifetime
        for _, trail in ipairs( state.vaporTrails ) do
            DrawBeam( trail.positions, 3, 6, 0,
                Color( 255, 255, 255, 100 ), VAPOR_MATERIAL )
        end

        -- Damage smoke trails
        if state.tier > 0 then
            local cfg = SMOKE_TIERS[state.tier]
            if cfg then
                for _, trail in ipairs( state.smokeTrails ) do
                    DrawBeam( trail.positions, cfg.lifetime, cfg.startSize, cfg.endSize,
                        cfg.color, SMOKE_MATERIAL )
                end
            end
        end
    end
end )
