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
    -- Check fight_st directly from gBattle.Game every frame
    local game = battle.get_game()
    if game then
        local ok, st = pcall(game.call, game, "get_FightST")
        if ok and st then
            battle.data.fight_st = st
            battle.data.is_fighting = (st == 4)
            -- FINISH(5), WIN_WAIT(6), WIN(7), NUM(8) = match ending
            if st >= 5 then
                battle.data.in_match = false
                input.release_all()
                return
            end
        end
    else
        -- No game object = not in a match at all
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
