local module = {}

---------------------------------------------------------------------------
-- Colors (ABGR format for imgui)
---------------------------------------------------------------------------
local COL_STATUS_OK = 0xFF44FF44  -- green
local COL_STATUS_NO = 0xFF4444FF  -- red
local COL_MUTED     = 0xFFAAAAAA  -- grey

-- Section colors (ABGR)
local SECTION_COLORS = {
    0xFF44AAFF,  -- orange
    0xFFFFAA44,  -- light blue
    0xFF44FFAA,  -- mint
    0xFFAA44FF,  -- purple
    0xFF44DDFF,  -- yellow-orange
    0xFFFF4488,  -- pink
}
local section_idx = 0

local function section(label)
    imgui.spacing()
    section_idx = section_idx + 1
    local col = SECTION_COLORS[((section_idx - 1) % #SECTION_COLORS) + 1]
    imgui.push_style_color(0, col)  -- 0 = ImGuiCol_Text
    local open = imgui.tree_node(label)
    imgui.pop_style_color(1)
    return open
end

---------------------------------------------------------------------------
-- Init (registers the draw callback)
---------------------------------------------------------------------------
function module.init(deps)
    local cfg = deps.cfg
    local config = deps.config
    local battle = deps.battle
    local bot_state = deps.state
    local BUTTON_NAMES = deps.button_names

    re.on_draw_ui(function()
        section_idx = 0
        if imgui.tree_node("Modern Bot") then
            local changed

            -- Master
            changed, cfg.master = imgui.checkbox("Power On", cfg.master)
            changed, cfg.allow_training = imgui.checkbox("In Training", cfg.allow_training)

            ---------------------------------------------------------------
            if section("Player") then
            ---------------------------------------------------------------
                local side_combo = cfg.player_side + 1
                changed, side_combo = imgui.combo("Side", side_combo, {"Auto", "P1", "P2"})
                if changed then cfg.player_side = side_combo - 1 end
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            if section("Pulse Input") then
            ---------------------------------------------------------------
                changed, cfg.enabled = imgui.checkbox("Enable##pulse", cfg.enabled)
                changed, cfg.pulse_btn_idx = imgui.combo("Button##pulse", cfg.pulse_btn_idx, BUTTON_NAMES)
                changed, cfg.interval_min = imgui.slider_int("Interval Min (f)", cfg.interval_min, 1, 300)
                changed, cfg.interval_max = imgui.slider_int("Interval Max (f)", cfg.interval_max, 1, 300)
                if cfg.interval_max < cfg.interval_min then cfg.interval_max = cfg.interval_min end
                changed, cfg.hold_min = imgui.slider_int("Hold Min (f)", cfg.hold_min, 1, 30)
                changed, cfg.hold_max = imgui.slider_int("Hold Max (f)", cfg.hold_max, 1, 30)
                if cfg.hold_max < cfg.hold_min then cfg.hold_max = cfg.hold_min end
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            if section("Hold Input") then
            ---------------------------------------------------------------
                changed, cfg.hold_enabled = imgui.checkbox("Enable##hold", cfg.hold_enabled)
                changed, cfg.hold_btn_idx = imgui.combo("Button##hold", cfg.hold_btn_idx, BUTTON_NAMES)
                changed, cfg.hold_forward = imgui.checkbox("Forward", cfg.hold_forward)
                imgui.same_line()
                changed, cfg.hold_back = imgui.checkbox("Back", cfg.hold_back)
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            if section("Charge Move") then
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
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            if section("Auto Rematch") then
            ---------------------------------------------------------------
                changed, cfg.auto_rematch = imgui.checkbox("Rematch##rematch", cfg.auto_rematch)
                changed, cfg.auto_return = imgui.checkbox("Return if Declined##return", cfg.auto_return)
                changed, cfg.auto_skip = imgui.checkbox("Skip Intros/Win Poses##skip", cfg.auto_skip)
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            if section("Settings") then
            ---------------------------------------------------------------
                changed, cfg.debug_log = imgui.checkbox("Debug Log", cfg.debug_log)
                if imgui.button("Reset Stats") then
                    battle.data.wins = 0
                    battle.data.losses = 0
                end
                imgui.same_line()
                if imgui.button("Save") then config.save() end
                imgui.same_line()
                if imgui.button("Load") then
                    local loaded = config.load()
                    for k, v in pairs(loaded) do cfg[k] = v end
                end
                imgui.tree_pop()
            end

            ---------------------------------------------------------------
            -- Status bar (always visible)
            ---------------------------------------------------------------
            imgui.spacing()
            imgui.separator()
            local bd = battle.data
            local bs = bot_state and bot_state.current or "?"

            local active = bs == "fighting" or bs == "ready" or bs == "loading"
            if active then
                imgui.push_style_color(0, COL_STATUS_OK)
            else
                imgui.push_style_color(0, COL_STATUS_NO)
            end
            imgui.text(string.upper(bs))
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

    -- Standalone stats overlay (always visible, doesn't need REFramework open)
    re.on_frame(function()
        local bd = battle.data
        if true then
            imgui.set_next_window_size({120, 0}, 4)  -- 4 = ImGuiCond_FirstUseEver
            imgui.begin_window("Bot Stats", true, 1 + 2 + 4 + 32)  -- +NoTitleBar
            local total = bd.wins + bd.losses
            local pct = total > 0 and math.floor(bd.wins / total * 100) or 0

            imgui.push_style_color(0, COL_STATUS_OK)
            imgui.text(bd.wins .. "W")
            imgui.pop_style_color(1)
            imgui.same_line()
            imgui.text("/")
            imgui.same_line()
            imgui.push_style_color(0, COL_STATUS_NO)
            imgui.text(bd.losses .. "L")
            imgui.pop_style_color(1)
            imgui.same_line()
            imgui.push_style_color(0, COL_MUTED)
            imgui.text("(" .. pct .. "%)")
            imgui.pop_style_color(1)

            imgui.end_window()
        end
    end)
end

return module
