---------------------------------------------------------------------------
-- Menu module: auto-rematch & return to previous mode
--
-- Hooks ResultController to detect result screens.
-- Injects UI confirm via InputLayer.GetFlags when menu is ready.
--
-- States:
--   idle       → nothing happening
--   waiting    → result screen active, waiting for menu to become interactable
--   confirming → injecting UIDecide to press the selected option
--   rematch_sent → rematch confirmed, waiting for opponent or match to load
---------------------------------------------------------------------------
local module = {}
module.data = { state = "idle" }

---------------------------------------------------------------------------
-- UI input injection via InputLayer.GetFlags
--
-- Input chain: UIAgentManager.UpdateInput → UIAgent.UpdateInput →
--   UIInputBindings.UpdateDigital → UIInputDigitalBindings.UpdateInput →
--   InputLayer.GetFlags(digitalId, playerIndex)
--
-- We intercept GetFlags on the base InputLayer class and return
-- Down|Trigger flags when we want to simulate a button press.
---------------------------------------------------------------------------
local UI_DECIDE = nil
local injected_ui = {}
local prev_injected_ui = {}

local FLAG_DOWN         = 1
local FLAG_TRIGGER      = 2
local FLAG_DOWN_TRIGGER = 3

local function inject_ui(id)  injected_ui[id] = true end
local function release_ui()
    prev_injected_ui = injected_ui
    injected_ui = {}
end

do
    local dt = sdk.find_type_definition("app.InputAssign.Digital.Id")
    if dt then
        local f = dt:get_field("UIDecide")
        if f then UI_DECIDE = f:get_data() end
    end

    local il_type = sdk.find_type_definition("app.InputLayer")
    if il_type then
        local m = il_type:get_method("GetFlags")
        if m then
            local cur_id = nil
            sdk.hook(m,
                function(args)
                    cur_id = args[3] and (sdk.to_int64(args[3]) & 0xFFFFFFFF) or nil
                end,
                function(retval)
                    if module.data.state ~= "confirming" then return retval end
                    if cur_id and injected_ui[cur_id] then
                        if prev_injected_ui[cur_id] then
                            return sdk.to_ptr(FLAG_DOWN)
                        end
                        return sdk.to_ptr(FLAG_DOWN_TRIGGER)
                    end
                    return retval
                end
            )
        end
    end
end

---------------------------------------------------------------------------
-- ResultMenuType values where rematch IS available
---------------------------------------------------------------------------
local MENU_HAS_REMATCH = {
    [0] = true,  -- Versus
    [2] = true,  -- Versus_RankDiffer
    [3] = true,  -- Matching_Continue
    [4] = true,  -- Matching
}

---------------------------------------------------------------------------
-- Scene utility
---------------------------------------------------------------------------
local function find_component_in_scene(type_name)
    local scene_mgr = sdk.get_native_singleton("via.SceneManager")
    local scene = scene_mgr and sdk.call_native_func(scene_mgr,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return nil end

    local transform = scene:call("get_FirstTransform")
    local count = 0
    while transform and count < 500 do
        count = count + 1
        local go = transform:call("get_GameObject")
        if go then
            local comp = go:call("getComponent(System.Type)", sdk.typeof(type_name))
            if comp then return comp end
        end
        transform = transform:call("get_Next")
    end
    return nil
end

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local result_controller = nil
local intent = nil            -- "rematch" | "return"
local confirm_frames = 0      -- frame counter for confirming state

local function reset()
    module.data.state = "idle"
    result_controller = nil
    intent = nil
    confirm_frames = 0
    release_ui()
end

--- Read mStateCurrent from the result controller, or nil.
local function get_rc_state()
    if not result_controller then return nil end
    local ok, st = pcall(result_controller.get_field, result_controller, "mStateCurrent")
    return ok and st or nil
end

--- Read the MenuType for our side from the result controller, or nil.
local function get_menu_type(battle)
    if not result_controller then return nil end
    local side_idx = (battle.data.detected_side or 1) - 1
    local ok, list = pcall(result_controller.call, result_controller,
        "GetResultMenuListData", side_idx)
    if not ok or not list then return nil end
    local ok2, mt = pcall(list.get_field, list, "MenuType")
    return ok2 and mt or nil
end

---------------------------------------------------------------------------
-- Detect result screen on script load (for reload support)
---------------------------------------------------------------------------
function module.detect_on_load()
    local rc = find_component_in_scene("app.ResultController")
    if not rc then return false, nil end

    local ok, st = pcall(rc.get_field, rc, "mStateCurrent")
    if ok and st and st >= 2 then
        return true, rc
    end
    return false, nil
end

---------------------------------------------------------------------------
-- Init: hooks + per-frame logic
---------------------------------------------------------------------------
function module.init(deps)
    local cfg       = deps.cfg
    local battle    = deps.battle
    local input     = deps.input
    local set_state = deps.set_state
    local bot_state = deps.state

    local rc_type = sdk.find_type_definition("app.ResultController")
    if not rc_type then
        log.debug("[menu] WARNING: app.ResultController not found")
        return
    end

    -- Detect result screen on script reload
    local on_result, rc = module.detect_on_load()
    if on_result and rc then
        result_controller = rc
        set_state("result")
        input.release_all()
        if cfg.master and (cfg.auto_rematch or cfg.auto_return) then
            module.data.state = "waiting"
            log.debug("[menu] Resuming on result screen")
        end
    end

    -- Result screen appears
    local m = rc_type:get_method("Activate")
    if m then
        sdk.hook(m,
            function(args)
                result_controller = sdk.to_managed_object(args[2])
                set_state("result")
                input.release_all()
                release_ui()

                if not (cfg.master and (cfg.auto_rematch or cfg.auto_return)) then return end

                module.data.state = "waiting"
                intent = nil
                log.debug("[menu] Result screen, waiting for menu")
            end,
            function(retval) return retval end
        )
    end

    -- Result screen closes
    m = rc_type:get_method("Deactivate")
    if m then
        sdk.hook(m,
            function(args)
                if module.data.state == "rematch_sent" then
                    log.debug("[menu] Rematch accepted")
                    reset()
                elseif module.data.state ~= "idle" then
                    reset()
                    set_state("idle")
                end
            end,
            function(retval) return retval end
        )
    end

    -- Opponent declined rematch (menu reappears with new options)
    m = rc_type:get_method("ReactivateMenu")
    if m then
        sdk.hook(m,
            function(args)
                if module.data.state == "rematch_sent" and cfg.auto_return and cfg.master then
                    module.data.state = "waiting"
                    intent = "return"
                    log.debug("[menu] Opponent declined, will return when menu ready")
                end
            end,
            function(retval) return retval end
        )
    end

    -- Per-frame logic
    re.on_frame(function()
        -- Reset if main state machine left the result screen
        if bot_state.current ~= "result" and module.data.state ~= "idle" then
            reset()
            return
        end

        if module.data.state == "idle" then
            release_ui()
            return
        end

        ---------------------------------------------------------------
        -- WAITING: poll mStateCurrent until menu is interactable
        ---------------------------------------------------------------
        if module.data.state == "waiting" then
            if not result_controller then reset() return end

            local st = get_rc_state()
            if not st then release_ui() return end

            -- Skip pre-menu animations with ESC
            if st < 7 then
                if cfg.auto_skip and (st == 0 or st == 3) then
                    input.inject_key(input.VK.ESCAPE)
                end
                release_ui()
                return
            end

            -- Menu is ready (state >= 7) — decide what to do
            if not intent then
                local mt = get_menu_type(battle)
                if mt and MENU_HAS_REMATCH[mt] and cfg.auto_rematch then
                    intent = "rematch"
                elseif cfg.auto_return then
                    intent = "return"
                else
                    log.debug("[menu] No action configured (MenuType=" .. tostring(mt) .. ")")
                    reset()
                    return
                end
                log.debug("[menu] Menu ready (state=" .. st .. " MenuType=" .. tostring(mt) .. ") intent=" .. intent)
            end

            -- Begin confirming
            if UI_DECIDE then
                module.data.state = "confirming"
                confirm_frames = 0
            else
                reset()
            end

        ---------------------------------------------------------------
        -- CONFIRMING: inject UIDecide with trigger cycling
        ---------------------------------------------------------------
        elseif module.data.state == "confirming" then
            confirm_frames = confirm_frames + 1

            -- Cycle: press → hold → release (3-frame pattern for trigger detection)
            local phase = confirm_frames % 3
            if phase == 1 then
                release_ui()
                inject_ui(UI_DECIDE)
            elseif phase == 2 then
                -- held (Down only)
            else
                release_ui()
            end

            -- After enough frames, check result
            if confirm_frames >= 30 then
                release_ui()
                if intent == "rematch" then
                    module.data.state = "rematch_sent"
                    log.debug("[menu] Rematch confirmed, waiting for opponent")
                else
                    -- Retry return if menu is still there
                    module.data.state = "waiting"
                    confirm_frames = 0
                    log.debug("[menu] Return attempt done, rechecking")
                end
            end

        ---------------------------------------------------------------
        -- REMATCH_SENT: just release UI inputs and wait
        ---------------------------------------------------------------
        elseif module.data.state == "rematch_sent" then
            release_ui()
        end
    end)
end

return module
