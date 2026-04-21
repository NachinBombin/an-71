if SERVER then return end

local ADDON_CATEGORY = "Bombin Addons"

hook.Add("PopulateToolMenu", "AN71_PopulateMenu", function()
    spawnmenu.AddToolMenuOption(
        "Options",
        ADDON_CATEGORY,
        "npc_an71_plane_settings",
        "AN-71 Flyover",
        "", "",
        function(panel)
            panel:ClearControls()
            panel:AddControl("Header", { Description = "AN-71 Flyover Settings", Height = "40" })

            panel:CheckBox("Enable AN-71 Calls", "npc_an71_enabled")
            panel:CheckBox("Debug Announce in Console", "npc_an71_announce")

            panel:AddControl("Label", { Text = "" })
            panel:AddControl("Header", { Description = "Probability & Timing", Height = "30" })

            panel:NumSlider("Call Chance", "npc_an71_chance", 0, 1, 2)
            panel:NumSlider("Check Interval (seconds)", "npc_an71_interval", 1, 60, 0)
            panel:NumSlider("Call Cooldown (seconds)", "npc_an71_cooldown", 10, 180, 0)
            panel:NumSlider("Delay After Flare", "npc_an71_delay", 1, 15, 0)
            panel:NumSlider("Plane Lifetime", "npc_an71_lifetime", 5, 120, 0)

            panel:AddControl("Label", { Text = "" })
            panel:AddControl("Header", { Description = "Flight Behavior", Height = "30" })

            panel:NumSlider("Plane Speed", "npc_an71_speed", 100, 1200, 0)
            panel:NumSlider("Orbit Radius", "npc_an71_radius", 500, 8000, 0)
            panel:NumSlider("Preferred Height Above Ground", "npc_an71_height", 500, 6000, 0)

            panel:AddControl("Label", { Text = "" })
            panel:AddControl("Header", { Description = "Engagement Range", Height = "30" })

            panel:NumSlider("Max Distance", "npc_an71_max_dist", 500, 8000, 0)
            panel:NumSlider("Min Distance", "npc_an71_min_dist", 0, 1000, 0)
        end
    )
end)
