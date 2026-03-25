local module = {}

---------------------------------------------------------------------------
-- Colors (ABGR format for imgui)
---------------------------------------------------------------------------
local COL_HEADER    = 0xFF44AAFF  -- orange
local COL_STATUS_OK = 0xFF44FF44  -- green
local COL_STATUS_NO = 0xFF4444FF  -- red
local COL_MUTED     = 0xFFAAAAAA  -- grey

local function section_header(label)
    imgui.spacing()
    imgui.push_style_color(0, COL_HEADER)  -- 0 = ImGuiCol_Text
    imgui.text(label)
    imgui.pop_style_color(1)
    imgui.separator()
end

---------------------------------------------------------------------------
-- Init (registers the draw callback)
---------------------------------------------------------------------------
function module.init(deps)
    local cfg = deps.cfg
    local config = deps.config
    local battle = deps.battle
    local BUTTON_NAMES = deps.button_names

    re.on_draw_ui(function()
        if imgui.tree_node("Modern Bot") then
            local changed

            -- Master
            changed, cfg.master = imgui.checkbox("Master Enable", cfg.master)
            changed, cfg.allow_training = imgui.checkbox("Allow in Training", cfg.allow_training)

            ---------------------------------------------------------------
            section_header("Player")
            ---------------------------------------------------------------
            -- combo is 1-based, player_side is 0-based (0=Auto, 1=P1, 2=P2)
            local side_combo = cfg.player_side + 1
            changed, side_combo = imgui.combo("Side", side_combo, {"Auto", "P1", "P2"})
            if changed then cfg.player_side = side_combo - 1 end

            ---------------------------------------------------------------
            section_header("Pulse Input")
            ---------------------------------------------------------------
            changed, cfg.enabled = imgui.checkbox("Enable##pulse", cfg.enabled)
            changed, cfg.pulse_btn_idx = imgui.combo("Button##pulse", cfg.pulse_btn_idx, BUTTON_NAMES)
            changed, cfg.interval_min = imgui.slider_int("Interval Min (f)", cfg.interval_min, 1, 300)
            changed, cfg.interval_max = imgui.slider_int("Interval Max (f)", cfg.interval_max, 1, 300)
            if cfg.interval_max < cfg.interval_min then cfg.interval_max = cfg.interval_min end
            changed, cfg.hold_min = imgui.slider_int("Hold Min (f)", cfg.hold_min, 1, 30)
            changed, cfg.hold_max = imgui.slider_int("Hold Max (f)", cfg.hold_max, 1, 30)
            if cfg.hold_max < cfg.hold_min then cfg.hold_max = cfg.hold_min end

            ---------------------------------------------------------------
            section_header("Hold Input")
            ---------------------------------------------------------------
            changed, cfg.hold_enabled = imgui.checkbox("Enable##hold", cfg.hold_enabled)
            changed, cfg.hold_btn_idx = imgui.combo("Button##hold", cfg.hold_btn_idx, BUTTON_NAMES)
            changed, cfg.hold_forward = imgui.checkbox("Forward", cfg.hold_forward)
            imgui.same_line()
            changed, cfg.hold_back = imgui.checkbox("Back", cfg.hold_back)

            ---------------------------------------------------------------
            section_header("Charge Input")
            ---------------------------------------------------------------
            changed, cfg.move_enabled = imgui.checkbox("Enable##move", cfg.move_enabled)
            imgui.text("Charge down, then random: L / M / H / M+H")
            changed, cfg.move_charge_min = imgui.slider_int("Min Charge (f)", cfg.move_charge_min, 1, 120)
            changed, cfg.move_delay_min = imgui.slider_int("Delay Min (f)", cfg.move_delay_min, 1, 120)
            changed, cfg.move_delay_max = imgui.slider_int("Delay Max (f)", cfg.move_delay_max, 1, 120)
            if cfg.move_delay_max < cfg.move_delay_min then cfg.move_delay_max = cfg.move_delay_min end
            changed, cfg.move_jump_min = imgui.slider_int("Hold Min (f)##move", cfg.move_jump_min, 1, 30)
            changed, cfg.move_jump_max = imgui.slider_int("Hold Max (f)##move", cfg.move_jump_max, 1, 30)
            if cfg.move_jump_max < cfg.move_jump_min then cfg.move_jump_max = cfg.move_jump_min end

            ---------------------------------------------------------------
            section_header("Auto Rematch")
            ---------------------------------------------------------------
            changed, cfg.auto_rematch = imgui.checkbox("Enable##rematch", cfg.auto_rematch)

            ---------------------------------------------------------------
            section_header("Settings")
            ---------------------------------------------------------------
            changed, cfg.debug_log = imgui.checkbox("Debug Log", cfg.debug_log)
            if imgui.button("Save") then config.save() end
            imgui.same_line()
            if imgui.button("Load") then
                local loaded = config.load()
                for k, v in pairs(loaded) do cfg[k] = v end
            end

            ---------------------------------------------------------------
            -- Status bar
            ---------------------------------------------------------------
            imgui.spacing()
            imgui.separator()
            local bd = battle.data
            local in_match = bd.in_match

            if in_match then
                imgui.push_style_color(0, COL_STATUS_OK)
                imgui.text("IN MATCH")
            else
                imgui.push_style_color(0, COL_STATUS_NO)
                imgui.text("NO MATCH")
            end
            imgui.pop_style_color(1)

            imgui.same_line()
            imgui.push_style_color(0, COL_MUTED)
            local side_str = bd.detected_side and ("P" .. bd.detected_side) or
                             cfg.player_side > 0 and ("P" .. cfg.player_side .. " (manual)") or "..."
            imgui.text("| " .. side_str)
            imgui.pop_style_color(1)

            imgui.tree_pop()
        end
    end)
end

return module
