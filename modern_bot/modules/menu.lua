---------------------------------------------------------------------------
-- Menu module: auto-rematch & return to previous mode
-- Injects UI confirm via InputLayer.GetFlags hook
---------------------------------------------------------------------------
local module = {}
module.data = { state = "idle" }  -- idle | waiting | confirming | rematch_sent | returning

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
local REMATCH_DELAY       = 120  -- frames before confirming rematch
local RETURN_DELAY        = 60   -- frames before confirming return
local RETURN_INTERVAL     = 30   -- frames between return retries
local MAX_RETURN_ATTEMPTS = 20   -- ~10 seconds

---------------------------------------------------------------------------
-- UI input injection via InputLayer.GetFlags
-- This is the single choke point for all UI digital input checks.
-- The chain: UIAgentManager.UpdateInput -> UIAgent.UpdateInput ->
--   UIInputBindings.UpdateDigital -> UIInputDigitalBindings.UpdateInput ->
--   InputLayer.GetFlags(digitalId, playerIndex)
-- We intercept GetFlags and return Down|Trigger when we want to "press" a button.
---------------------------------------------------------------------------
local UI_DECIDE = nil  -- resolved at init
local injected_ui = {}       -- digitalId -> true
local prev_injected_ui = {}  -- for trigger detection

local function inject_ui(id)  injected_ui[id] = true end
local function release_ui()
    prev_injected_ui = injected_ui
    injected_ui = {}
end

-- InputDigitalFlag values
local FLAG_DOWN    = 1
local FLAG_TRIGGER = 2
local FLAG_DOWN_TRIGGER = 3  -- Down | Trigger

do
    -- Resolve UIDecide enum value
    local dt = sdk.find_type_definition("app.InputAssign.Digital.Id")
    if dt then
        local f = dt:get_field("UIDecide")
        if f then UI_DECIDE = f:get_data() end
    end
    log.debug("[menu] UI_DECIDE=" .. tostring(UI_DECIDE))

    -- Hook InputLayer.GetFlags (base class) — UIDecide flows through here
    local il_type = sdk.find_type_definition("app.InputLayer")
    if il_type then
        local m = il_type:get_method("GetFlags")
        if m then
            local cur_digital_id = nil
            sdk.hook(m,
                function(args)
                    if args[3] then
                        cur_digital_id = sdk.to_int64(args[3]) & 0xFFFFFFFF
                    else
                        cur_digital_id = nil
                    end
                end,
                function(retval)
                    if module.data.state ~= "confirming" then
                        return retval
                    end
                    if cur_digital_id and injected_ui[cur_digital_id] then
                        if prev_injected_ui[cur_digital_id] then
                            return sdk.to_ptr(FLAG_DOWN)
                        end
                        return sdk.to_ptr(FLAG_DOWN_TRIGGER)
                    end
                    return retval
                end
            )
            log.debug("[menu] Hooked InputLayer.GetFlags")
        end
    end
end

---------------------------------------------------------------------------
-- Scene utilities
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
local return_attempts = 0
local intent = nil  -- "rematch" or "return"

local function reset()
    module.data.state = "idle"
    return_attempts = 0
    result_controller = nil
    intent = nil
    release_ui()
end

---------------------------------------------------------------------------
-- Detect result screen on script load (for script reload support)
---------------------------------------------------------------------------
function module.detect_on_load()
    local rc = find_component_in_scene("app.ResultController")
    if not rc then return false, nil end

    local ok, st = pcall(rc.get_field, rc, "mStateCurrent")
    if not ok then return false, nil end

    if st and st >= 2 then
        log.debug("[menu] Detected result screen on load (state=" .. tostring(st) .. ")")
        return true, rc
    end
    return false, nil
end

---------------------------------------------------------------------------
-- Init
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
            log.debug("[menu] Resuming on result screen, waiting for menu")
        end
    end

    -- Hook: result screen appears
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
                -- Intent decided when menu is ready (we check MenuType then)
                intent = nil
                log.debug("[menu] Result screen, waiting for menu")
            end,
            function(retval) return retval end
        )
        log.debug("[menu] Hooked ResultController.Activate")
    end

    -- Hook: result screen closes
    m = rc_type:get_method("Deactivate")
    if m then
        sdk.hook(m,
            function(args)
                if module.data.state == "rematch_sent" then
                    log.debug("[menu] Rematch accepted, match loading")
                    reset()
                elseif module.data.state ~= "idle" then
                    log.debug("[menu] Result screen closed")
                    reset()
                    set_state("idle")
                end
            end,
            function(retval) return retval end
        )
    end

    -- Hook: opponent declined rematch (menu reappears)
    m = rc_type:get_method("ReactivateMenu")
    if m then
        sdk.hook(m,
            function(args)
                if module.data.state == "rematch_sent" and cfg.auto_return and cfg.master then
                    module.data.state = "waiting"
                    intent = "return"
                    return_attempts = 0
                    log.debug("[menu] Opponent declined, will return when menu ready")
                end
            end,
            function(retval) return retval end
        )
    end

    -- Per-frame logic
    re.on_frame(function()
        -- Reset if we left the result state
        if bot_state.current ~= "result" and module.data.state ~= "idle" then
            reset()
            return
        end

        if module.data.state == "idle" then
            release_ui()
            return
        end

        -- Check if result menu is ready for input by reading mStateCurrent
        -- Result (4) = menu visible and interactable
        if module.data.state == "waiting" then
            if not result_controller then
                reset()
                return
            end
            local ok, st = pcall(result_controller.get_field, result_controller, "mStateCurrent")
            if not ok or not st then
                release_ui()
                return
            end

            -- Debug: log state transitions while waiting
            return_attempts = (return_attempts or 0) + 1
            if return_attempts % 60 == 1 then
                log.debug("[menu] Waiting: state=" .. tostring(st))
            end

            -- Skip pre-menu animations (KO replay, win pose) with ESC
            if st < 7 then
                if cfg.auto_skip and (st == 0 or st == 3) then
                    input.inject_key(input.VK.ESCAPE)
                end
                release_ui()
                return
            end

            -- Menu is ready — decide intent based on MenuType
            if not intent then
                local MENU_HAS_REMATCH = { [0] = true, [2] = true, [3] = true, [4] = true }
                local side_idx = (battle.data.detected_side or 1) - 1
                local ok_list, list = pcall(result_controller.call, result_controller,
                    "GetResultMenuListData", side_idx)
                local menu_type = nil
                if ok_list and list then
                    local ok_mt, mt = pcall(list.get_field, list, "MenuType")
                    if ok_mt then menu_type = mt end
                end
                log.debug("[menu] Menu ready (state=" .. tostring(st) .. ", MenuType=" .. tostring(menu_type) .. ")")

                if menu_type and MENU_HAS_REMATCH[menu_type] and cfg.auto_rematch then
                    intent = "rematch"
                elseif cfg.auto_return then
                    intent = "return"
                else
                    log.debug("[menu] No matching action configured")
                    reset()
                    return
                end
                log.debug("[menu] Intent: " .. intent)
            end

            if UI_DECIDE then
                module.data.state = "confirming"
                return_attempts = 0
            else
                log.debug("[menu] No UI_DECIDE resolved")
                reset()
            end

        -- Confirming: inject UIDecide for several frames with trigger cycling
        elseif module.data.state == "confirming" then
            return_attempts = return_attempts + 1
            if return_attempts % 3 == 1 then
                release_ui()
                inject_ui(UI_DECIDE)
            elseif return_attempts % 3 == 2 then
                -- keep held (Down only, no fresh Trigger)
            else
                release_ui()
            end
            if return_attempts >= 30 then
                release_ui()
                if intent == "rematch" then
                    module.data.state = "rematch_sent"
                    log.debug("[menu] Rematch confirmed, waiting for opponent")
                else
                    -- Return: go back to waiting and retry if menu is still there
                    module.data.state = "waiting"
                    return_attempts = 0
                    log.debug("[menu] Return attempt done, rechecking menu")
                end
            end

        elseif module.data.state == "rematch_sent" then
            release_ui()

        -- returning is now handled via waiting -> confirming flow
        end
    end)
end

return module
