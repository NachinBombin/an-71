-- ============================================================
--  AN-71 Control Panel
--  lua/autorun/client/cl_npc_an71_plane_menu.lua
-- ============================================================

if not CLIENT then return end

-- ----------------------------------------
--  Color Palette
-- ----------------------------------------
local col_bg_panel      = Color(0,   0,   0,   255)
local col_section_title = Color(210, 210, 210, 255)
local col_accent        = Color(0,   180, 255, 255)

-- ----------------------------------------
--  Colored Section Banners
-- ----------------------------------------
local SECTION_COLORS = {
    ["NPC Call Settings"]    = Color(60,  120, 200, 120),
    ["Probability & Timing"] = Color(80,  160, 100, 120),
    ["Flight Behaviour"]     = Color(80,  180, 120, 120),
    ["Debug"]                = Color(100, 100, 110, 120),
    ["Manual Spawn"]         = Color(140, 80,  200, 120),
}

local function AddColoredCategory(panel, text)
    local bgColor = SECTION_COLORS[text]
    if not bgColor then
        panel:Help(text)
        return
    end

    local cat = vgui.Create("DPanel", panel)
    cat:SetTall(24)
    cat:Dock(TOP)
    cat:DockMargin(0, 8, 0, 4)
    cat.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, bgColor)
        surface.SetDrawColor(0, 0, 0, 35)
        surface.DrawOutlinedRect(0, 0, w, h)
        local textColor = (bgColor.r + bgColor.g + bgColor.b < 200)
            and Color(255, 255, 255, 255)
            or  Color(0,   0,   0,   255)
        draw.SimpleText(
            text, "DermaDefaultBold",
            8, h / 2,
            textColor,
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER
        )
    end
    panel:AddItem(cat)
end

-- ----------------------------------------
--  Console Command — manual test spawn
-- ----------------------------------------
concommand.Add("an71_spawnplane", function()
    if not IsValid(LocalPlayer()) then return end
    net.Start("AN71_ManualSpawn")
    net.SendToServer()
end)

-- ----------------------------------------
--  Tab & Category Registration
-- ----------------------------------------
hook.Add("AddToolMenuTabs", "AN71_Tab", function()
    spawnmenu.AddToolTab("Bombin Support", "Bombin Support", "icon16/bomb.png")
end)

hook.Add("AddToolMenuCategories", "AN71_Categories", function()
    spawnmenu.AddToolCategory("Bombin Support", "AN-71", "AN-71")
end)

-- ----------------------------------------
--  Tool Menu Population
-- ----------------------------------------
hook.Add("PopulateToolMenu", "AN71_ToolMenu", function()
    spawnmenu.AddToolMenuOption(
        "Bombin Support",
        "AN-71",
        "npc_an71_plane_settings",
        "AN-71 Settings",
        "", "",
        function(panel)
            panel:ClearControls()

            -- Header banner
            local header = vgui.Create("DPanel", panel)
            header:SetTall(32)
            header:Dock(TOP)
            header:DockMargin(0, 0, 0, 8)
            header.Paint = function(self, w, h)
                draw.RoundedBox(4, 0, 0, w, h, col_bg_panel)
                surface.SetDrawColor(col_accent)
                surface.DrawRect(0, h - 2, w, 2)
                draw.SimpleText(
                    "AN-71 Flyover Controller",
                    "DermaLarge",
                    8, h / 2,
                    col_section_title,
                    TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER
                )
            end
            panel:AddItem(header)

            -- ─── NPC Call Settings ─────────────────────────────────
            AddColoredCategory(panel, "NPC Call Settings")
            panel:CheckBox("Enable AN-71 calls", "npc_an71_enabled")

            -- ─── Probability & Timing ──────────────────────────────
            AddColoredCategory(panel, "Probability & Timing")
            panel:NumSlider("Call chance (per check)",   "npc_an71_chance",    0,  1,   2)
            panel:NumSlider("Check interval (seconds)",  "npc_an71_interval",  1,  60,  0)
            panel:NumSlider("Call cooldown (seconds)",   "npc_an71_cooldown",  10, 180, 0)
            panel:NumSlider("Delay after flare (s)",     "npc_an71_delay",     1,  15,  0)
            panel:NumSlider("AN-71 lifetime (seconds)",  "npc_an71_lifetime",  5,  120, 0)

            -- ─── Flight Behaviour ──────────────────────────────────
            AddColoredCategory(panel, "Flight Behaviour")
            panel:NumSlider("AN-71 speed (HU/s)",                "npc_an71_speed",  100, 1200, 0)
            panel:NumSlider("Orbit radius (HU)",                 "npc_an71_radius", 500, 8000, 0)
            panel:NumSlider("Preferred height above ground (HU)", "npc_an71_height", 500, 6000, 0)

            -- ─── Debug ─────────────────────────────────────────────
            AddColoredCategory(panel, "Debug")
            panel:CheckBox("Enable debug prints", "npc_an71_announce")

            -- ─── Manual Spawn ──────────────────────────────────────
            AddColoredCategory(panel, "Manual Spawn")
            panel:Button("Spawn AN-71 now", "an71_spawnplane")
        end
    )
end)
