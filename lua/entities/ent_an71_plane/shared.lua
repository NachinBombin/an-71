ENT.Type   = "anim"
ENT.Base   = "base_anim"

ENT.PrintName      = "AN-71 Plane"
ENT.Author         = "Bombin Addons"
ENT.Spawnable      = false
ENT.AdminSpawnable = false
ENT.RenderGroup    = RENDERGROUP_OPAQUE

-- Tuning constants (must live here so ENT is valid on both client and server)
ENT.FadeDuration    = 2.0
ENT.ModelPath       = "models/an71/an71.mdl"
ENT.EngineSound     = "vehicles/apc/apc_idle1.wav"
ENT.MaxHP           = 8000
ENT.AltDriftRange   = 300
ENT.AltDriftLerp    = 0.001
ENT.JitterAmplitude = 5
ENT.AlertInterval   = 0.3
