local module = {}

module.data = {
    is_training   = false,
    frame         = 0,
    detected_side = nil,
    game_mode     = nil,
    fight_st      = nil,
    round_wins    = 0,
    round_losses  = 0,
    match_wins    = 0,
    match_losses  = 0,
    set_round_wins  = 0,  -- rounds won in current match
    set_round_losses = 0, -- rounds lost in current match
}

---------------------------------------------------------------------------
-- gBattle access
---------------------------------------------------------------------------
local gBattle = sdk.find_type_definition("gBattle")

local function get_gBattle_field(name)
    if not gBattle then return nil end
    local field = gBattle:get_field(name)
    if not field then return nil end
    return field:get_data()
end

local function get_player(id)
    local sPlayer = get_gBattle_field("Player")
    if not sPlayer then return nil end
    local ok, p = pcall(sPlayer.call, sPlayer, "getPlayer", id)
    return ok and p or nil
end

---------------------------------------------------------------------------
-- bBattleFlow capture (for online side detection)
---------------------------------------------------------------------------
local bBattleFlow_instance = nil

local bf_type = sdk.find_type_definition("app.battle.bBattleFlow")
if bf_type then
    local update_method = bf_type:get_method("updateFrame")
    if update_method then
        sdk.hook(update_method,
            function(args)
                bBattleFlow_instance = sdk.to_managed_object(args[2])
            end,
            function(retval) return retval end
        )
    end
end

---------------------------------------------------------------------------
-- Side detection
---------------------------------------------------------------------------
local function read_game_mode()
    local setting = get_gBattle_field("Setting")
    if not setting then return nil, false end
    local ok_m, mode = pcall(setting.get_field, setting, "GameMode")
    local ok_o, online = pcall(setting.get_field, setting, "IsOnline")
    if ok_m then module.data.game_mode = mode end
    return (ok_m and mode or nil), (ok_o and online or false)
end

-- EGameMode enum values (from il2cpp dump)
local EGAMEMODE = {
    TRAINING         = 2,
    ONLINE_TRAINING  = 18,
    STORY_TRAINING   = 10,
}

local TRAINING_MODES = {
    [EGAMEMODE.TRAINING]        = true,
    [EGAMEMODE.ONLINE_TRAINING] = true,
    [EGAMEMODE.STORY_TRAINING]  = true,
}

local function is_training_mode()
    return TRAINING_MODES[module.data.game_mode] or false
end

local function try_detect_side_online()
    if not bBattleFlow_instance then return nil end

    local ok_s, session = pcall(bBattleFlow_instance.get_field, bBattleFlow_instance, "m_session")
    if not ok_s or not session then return nil end

    local ok_m, member_info = pcall(session.call, session, "get_SelfBattleMemberInfo")
    if not ok_m or not member_info then return nil end

    local ok_i, idx = pcall(member_info.get_field, member_info, "MemberIndex")
    if not ok_i then return nil end

    return idx  -- 0 = P1 side, 1 = P2 side
end

local function try_detect_side(player_side_cfg)
    -- Manual override: 0=Auto, 1=P1, 2=P2
    if player_side_cfg and player_side_cfg > 0 then
        module.data.detected_side = player_side_cfg
        log.debug("[battle] Side set manually: P" .. module.data.detected_side)
        return
    end

    local mode, online = read_game_mode()
    module.data.game_mode = mode

    -- Training/local modes: always P1
    if not online then
        module.data.detected_side = 1
        module.data.is_training = is_training_mode()
        log.debug(string.format("[battle] Side=P1 (local, mode=%s, training=%s)",
            tostring(mode), tostring(module.data.is_training)))
        return
    end

    -- Online: use bBattleFlow session data
    local side = try_detect_side_online()
    if side ~= nil then
        module.data.detected_side = side + 1  -- 0-indexed -> 1-indexed
        log.debug("[battle] Side=P" .. module.data.detected_side .. " (online)")
    end
end

---------------------------------------------------------------------------
-- Reset (called by state machine on new match)
---------------------------------------------------------------------------
function module.reset()
    module.data.detected_side = nil
    module.data.is_training = false
    module.data.game_mode = nil
    module.data.fight_st = nil
    module.data.frame = 0
    bBattleFlow_instance = nil
    log.debug("[battle] Reset")
end

--- Called when a new match starts (not between rounds).
--- Resets the per-match set counters.
function module.reset_set()
    module.data.set_round_wins = 0
    module.data.set_round_losses = 0
end

---------------------------------------------------------------------------
-- Per-frame update (called from main hook)
---------------------------------------------------------------------------
function module.on_frame(cfg)
    module.data.frame = module.data.frame + 1
    if not module.data.detected_side then
        try_detect_side(cfg.player_side)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function module.get_my_index()
    return module.data.detected_side or 1
end

--- Returns true if our character is facing right, false if facing left, nil if unknown.
function module.get_facing()
    local idx = module.get_my_index()
    local p = get_player(idx - 1)  -- getPlayer is 0-indexed
    if not p then return nil end
    local ok, rl_dir = pcall(p.get_field, p, "rl_dir")
    if not ok then return nil end
    return rl_dir
end

--- ACT_ST.ID enum (from il2cpp dump, backing type SByte)
local ACT_ST_NAMES = {
    [0]   = "FOOTWORK",
    [1]   = "SIT",
    [2]   = "WIN",
    [3]   = "SITD",
    [4]   = "STAND",
    [5]   = "STAND_TURN",
    [6]   = "SIT_TURN",
    [7]   = "NIJI",
    [8]   = "WALK",
    [9]   = "DUCK_WALK",
    [10]  = "DASH",
    [11]  = "NOKI",
    [12]  = "KDASH",
    [13]  = "ATCK_LAND",
    [14]  = "JUMP",
    [15]  = "JUMP_NORM",
    [16]  = "JUMP_LAND",
    [17]  = "JUMP_RET",
    [18]  = "SJUMP",
    [19]  = "SJUMP_NORM",
    [20]  = "SJUMP_DMG",
    [21]  = "SJUMP_RET",
    [22]  = "FLYING",
    [23]  = "WJUMP",
    [24]  = "WSJUMP",
    [25]  = "TJUMP",
    [26]  = "FALL",
    [27]  = "DEF",
    [28]  = "JDEF",
    [29]  = "ATCK",
    [30]  = "SPECIAL",
    [31]  = "SUPER",
    [32]  = "DAMAGE",
    [33]  = "_33",
    [34]  = "SLEEP",
    [35]  = "GETUP",
    [36]  = "UKEMI",
    [37]  = "CATCH",
    [38]  = "HOLD",
    [39]  = "PARRY",
    [40]  = "TOUCH",
    [41]  = "WITHDRAW",
    [42]  = "NUM",
    [255] = "NONE",
}

--- Returns the act_st value for our player, or nil.
function module.get_act_st()
    local idx = module.get_my_index()
    local p = get_player(idx - 1)
    if not p then return nil end
    local ok, st = pcall(p.get_field, p, "act_st")
    return ok and st or nil
end

--- Returns the act_st name string, or "?" if unknown.
function module.get_act_st_name()
    local st = module.get_act_st()
    if st == nil then return "?" end
    return ACT_ST_NAMES[st] or tostring(st)
end

--- Check round result and update win/loss counters.
--- Call once when fight_st transitions to FINISH.
function module.check_round_result()
    local judge = get_gBattle_field("Judge")
    if not judge then return end

    local ok, winner = pcall(judge.call, judge, "get_WinTeam")
    if not ok or winner == nil then return end

    local my_team = (module.data.detected_side or 1) - 1  -- 0-indexed
    if winner == my_team then
        module.data.round_wins = module.data.round_wins + 1
        module.data.set_round_wins = module.data.set_round_wins + 1
        log.debug(string.format("[battle] Round won! (R: %dW/%dL | Set: %d-%d)",
            module.data.round_wins, module.data.round_losses,
            module.data.set_round_wins, module.data.set_round_losses))
    elseif winner >= 0 then
        module.data.round_losses = module.data.round_losses + 1
        module.data.set_round_losses = module.data.set_round_losses + 1
        log.debug(string.format("[battle] Round lost. (R: %dW/%dL | Set: %d-%d)",
            module.data.round_wins, module.data.round_losses,
            module.data.set_round_wins, module.data.set_round_losses))
    end

    -- Check for match win/loss (Bo3: first to 2 rounds)
    if module.data.set_round_wins >= 2 then
        module.data.match_wins = module.data.match_wins + 1
        log.debug(string.format("[battle] Match won! (M: %dW/%dL)",
            module.data.match_wins, module.data.match_losses))
        module.data.set_round_wins = 0
        module.data.set_round_losses = 0
    elseif module.data.set_round_losses >= 2 then
        module.data.match_losses = module.data.match_losses + 1
        log.debug(string.format("[battle] Match lost. (M: %dW/%dL)",
            module.data.match_wins, module.data.match_losses))
        module.data.set_round_wins = 0
        module.data.set_round_losses = 0
    end
end

--- Returns the gBattle.Flow object, or nil if not in battle.
function module.get_flow()
    return get_gBattle_field("Flow")
end

--- Returns the gBattle.Game object, or nil.
function module.get_game()
    return get_gBattle_field("Game")
end

--- Returns true if the current player has a completed charge.
--- Reads ChargeInfo.complete from Command.UserEngine's charge dictionary.
function module.is_charge_complete()
    local cmd = get_gBattle_field("Command")
    if not cmd then return false end
    local pl_id = (module.data.detected_side or 1) - 1

    local ok_e, engine = pcall(cmd.call, cmd, "Engine", pl_id)
    if not ok_e or not engine then return false end

    local ok_c, charge_infos = pcall(engine.get_field, engine, "m_charge_infos")
    if not ok_c or not charge_infos then return false end

    local ok_count, count = pcall(charge_infos.call, charge_infos, "get_Count")
    if not ok_count or not count or count == 0 then return false end

    local ok_vals, vals = pcall(charge_infos.call, charge_infos, "get_Values")
    if not ok_vals or not vals then return false end

    local ok_enum, enumerator = pcall(vals.call, vals, "GetEnumerator")
    if not ok_enum or not enumerator then return false end

    for i = 0, count - 1 do
        local ok_n, hn = pcall(enumerator.call, enumerator, "MoveNext")
        if not ok_n or not hn then break end
        local ok_cur, info = pcall(enumerator.call, enumerator, "get_Current")
        if ok_cur and info then
            local ok_co, co = pcall(info.get_field, info, "complete")
            if ok_co and co and co ~= 0 then return true end
        end
    end

    return false
end

return module
