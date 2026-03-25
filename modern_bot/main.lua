---------------------------------------------------------------------------
-- Module loader
---------------------------------------------------------------------------
local function safe_require(path)
    local ok, mod_or_err = pcall(require, path)
    if not ok then
        log.debug(string.format("[bot] require('%s') failed: %s", path, tostring(mod_or_err)))
        return nil
    end
    if type(mod_or_err) ~= "table" then
        log.debug(string.format("[bot] module '%s' did not return a table (got %s)", path, type(mod_or_err)))
        return nil
    end
    return mod_or_err
end

local config = safe_require("modules/config")
local battle = safe_require("modules/battle")
local input  = safe_require("modules/input")
local ui     = safe_require("modules/ui")

local cfg = config and config.cfg

---------------------------------------------------------------------------
-- Main hook
---------------------------------------------------------------------------
sdk.hook(
    sdk.find_type_definition("app.FBattleInput"):get_method("confirmBattleInput"),
    function(args) end,
    function(retval)
        battle.on_frame(cfg)

        if not cfg.master
            or (battle.data.is_training and not cfg.allow_training)
            or not battle.data.in_match
            or not battle.data.detected_side
        then
            input.release_all()
            return retval
        end

        input.on_frame(cfg, battle)

        return retval
    end
)

---------------------------------------------------------------------------
-- Safety: check gBattle.Flow directly to detect match end
-- (confirmBattleInput hook stops firing after match, so battle.data goes stale)
---------------------------------------------------------------------------
re.on_frame(function()
    local game = battle.get_game()
    if game then
        local ok, st = pcall(game.call, game, "get_FightST")
        if ok and st then
            battle.data.fight_st = st
            battle.data.is_fighting = (st == 4)
            if st >= 5 then
                battle.data.in_match = false
                input.release_all()
                return
            end
        end
    else
        if battle.data.in_match then
            battle.data.in_match = false
            battle.data.is_fighting = false
            battle.data.fight_st = nil
        end
    end

    if not battle.data.in_match or not battle.data.detected_side then
        input.release_all()
    end
end)

---------------------------------------------------------------------------
-- Auto-rematch / auto-return: capture ResultController
---------------------------------------------------------------------------
local result_controller = nil
local result_state = "idle"  -- idle | waiting | rematch_sent | returning
local result_timer = 0
local REMATCH_DELAY = 120       -- frames before pressing rematch
local RETURN_DELAY = 60         -- frames before pressing return

-- ResultMenuType enum
local MENU_MATCHING     = 4
local MENU_MATCHING_END = 5

local result_menu_type = nil

do
    local rc_type = sdk.find_type_definition("app.ResultController")
    if rc_type then
        local m_activate = rc_type:get_method("Activate")
        if m_activate then
            sdk.hook(m_activate,
                function(args)
                    result_controller = sdk.to_managed_object(args[2])
                    if cfg.auto_rematch and cfg.master then
                        result_state = "waiting"
                        result_timer = REMATCH_DELAY
                        result_menu_type = nil
                        log.debug("[bot] Result screen detected, waiting to act")
                    end
                end,
                function(retval) return retval end
            )
            log.debug("[bot] Hooked ResultController.Activate")
        end

        -- Track which menu type is shown (Matching vs Matching_End etc)
        local m_set_menu = rc_type:get_method("SetMenuType")
        if m_set_menu then
            sdk.hook(m_set_menu,
                function(args)
                    local menu_val = sdk.to_int64(args[3]) & 0xFFFFFFFF
                    local prev_type = result_menu_type
                    result_menu_type = menu_val
                    log.debug("[bot] ResultController.SetMenuType: " .. tostring(menu_val))

                    -- Menu changed while waiting for opponent = they left
                    if result_state == "rematch_sent" and menu_val ~= prev_type then
                        log.debug("[bot] Menu changed (opponent left), returning now")
                        result_state = "returning"
                        result_timer = 0
                    end
                end,
                function(retval) return retval end
            )
        end
    else
        log.debug("[bot] WARNING: Could not find app.ResultController")
    end
end

re.on_frame(function()
    -- Reset when a new match starts loading (fight_st exists = battle scene active)
    if battle.data.in_match and result_state ~= "idle" then
        log.debug("[bot] New match started, resetting result state")
        result_state = "idle"
        result_timer = 0
        result_controller = nil
        result_menu_type = nil
        return
    end

    if result_state == "idle" or not result_controller then return end

    result_timer = result_timer - 1
    if result_timer > 0 then return end

    if result_state == "waiting" then
        -- Match set is over (Matching_End) -> go straight to return
        if result_menu_type == MENU_MATCHING_END then
            log.debug("[bot] Match set over, will return to previous mode")
            result_state = "returning"
            result_timer = RETURN_DELAY
            return
        end

        -- Normal result screen -> try rematch
        log.debug("[bot] Requesting rematch (SetDecide(0))")
        local ok, err = pcall(result_controller.call, result_controller, "SetDecide", (battle.data.detected_side or 1) - 1)
        if ok then
            result_state = "rematch_sent"
            log.debug("[bot] Rematch requested, waiting for game timer / opponent")
        else
            log.debug("[bot] SetDecide failed: " .. tostring(err))
            result_state = "idle"
        end

    elseif result_state == "returning" then
        -- Select last menu item (Return to Previous Mode) and confirm
        local ok1, err1 = pcall(result_controller.call, result_controller, "SetMenuIndex", (battle.data.detected_side or 1) - 1, 1)
        if not ok1 then
            log.debug("[bot] SetMenuIndex failed: " .. tostring(err1))
        end
        local ok2, err2 = pcall(result_controller.call, result_controller, "SetDecide", (battle.data.detected_side or 1) - 1)
        if ok2 then
            log.debug("[bot] Return to previous mode confirmed")
        else
            log.debug("[bot] Return SetDecide failed: " .. tostring(err2))
        end
        result_state = "idle"
    end
end)

---------------------------------------------------------------------------
-- Init UI
---------------------------------------------------------------------------
if ui then
    ui.init({
        cfg = cfg,
        config = config,
        battle = battle,
        button_names = input.BUTTON_NAMES,
    })
end

log.debug("Modern Bot Ready")
