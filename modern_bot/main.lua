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

        if not cfg.master then input.release_all() return retval end
        if not battle.data.is_fighting or not battle.data.detected_side then
            return retval
        end

        input.on_frame(cfg, battle)

        return retval
    end
)

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
