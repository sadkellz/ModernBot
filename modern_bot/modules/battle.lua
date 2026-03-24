local module = {}

module.data = {
    fbattle       = nil,
    in_match      = false,
    frame         = 0,
    detected_side = nil,
}

---------------------------------------------------------------------------
-- Player behaviors (scene walk for PlayerBehavior components)
---------------------------------------------------------------------------
local player_behaviors = {nil, nil}

local function refresh_player_behaviors()
    player_behaviors = {nil, nil}
    local scene_mgr = sdk.get_native_singleton("via.SceneManager")
    if not scene_mgr then return end
    local scene = sdk.call_native_func(scene_mgr,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    local transform = scene:call("get_FirstTransform")
    local count = 0
    while transform and count < 500 do
        count = count + 1
        local go = transform:call("get_GameObject")
        if go then
            local pb = go:call("getComponent(System.Type)", sdk.typeof("app.PlayerBehavior"))
            if pb then
                if not player_behaviors[1] then
                    player_behaviors[1] = pb
                elseif not player_behaviors[2] then
                    player_behaviors[2] = pb
                    break
                end
            end
        end
        transform = transform:call("get_Next")
    end
end

---------------------------------------------------------------------------
-- Side detection
---------------------------------------------------------------------------
local function try_detect_side(player_side_cfg)
    if player_side_cfg ~= 0 then
        module.data.detected_side = player_side_cfg
        refresh_player_behaviors()
        return
    end

    local bf_singleton = sdk.get_managed_singleton("app.battle.bBattleFlow")
    if bf_singleton then
        local ok, idx = pcall(bf_singleton.call, bf_singleton, "getOnlineCpuBattleSelfSideIndex", false)
        if ok and idx then
            module.data.detected_side = idx + 1  -- 0-indexed -> 1-indexed
            refresh_player_behaviors()
            log.debug("[battle] Detected side via bBattleFlow: P" .. module.data.detected_side)
            return
        end
    end
end

---------------------------------------------------------------------------
-- Match state
---------------------------------------------------------------------------
local function reset()
    module.data.detected_side = nil
    player_behaviors = {nil, nil}
end

local function check_match()
    local fb = module.data.fbattle
    if not fb then
        if module.data.in_match then
            module.data.in_match = false
            reset()
        end
        return false
    end
    local ok, p = pcall(fb.call, fb, "GetPlayer", 0)
    local now = ok and p ~= nil
    if now ~= module.data.in_match then
        module.data.in_match = now
        module.data.frame = 0
        reset()
    end
    return module.data.in_match
end

---------------------------------------------------------------------------
-- Per-frame update
---------------------------------------------------------------------------
function module.on_frame(player_side_cfg)
    if not check_match() then return end
    module.data.frame = module.data.frame + 1
    if not module.data.detected_side then
        try_detect_side(player_side_cfg)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function module.get_my_index(player_side_cfg)
    return module.data.detected_side or player_side_cfg or 1
end

function module.get_facing(player_side_cfg)
    local idx = module.get_my_index(player_side_cfg)
    local pb = player_behaviors[idx]
    if not pb then
        refresh_player_behaviors()
        pb = player_behaviors[idx]
        if not pb then return nil end
    end
    local ok, facing_right = pcall(pb.call, pb, "get_IsMirror")
    if not ok then
        refresh_player_behaviors()
        pb = player_behaviors[idx]
        if not pb then return nil end
        ok, facing_right = pcall(pb.call, pb, "get_IsMirror")
        if not ok then return nil end
    end
    return facing_right
end

return module
