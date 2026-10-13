-- 多租户额度限流插件 for OpenNJet
-- 参赛作品：「端侧智算网关」——基于开放原子开源项目的团队级大模型服务解决方案
-- 第四届开放原子大赛·2026 开源行业解决方案创新赛
--
-- 功能：基于租户ID的多维度限流（QPS + 并发 + Token配额）
-- 场景：团队共享一台强机算力时，按租户/用户分配额度，防止单个租户占满资源
--
-- 使用方法（njet.conf）：
--   http {
--     lua_shared_dict tenant_quota 10m;
--     server {
--       location /v1/ {
--         access_by_lua_file conf/tenant_limit.lua;
--         proxy_pass http://llm_backend;
--       }
--     }
--   }
--
-- 请求头要求：
--   X-Tenant-ID: 租户唯一标识（必需）
--   X-Tenant-Tier: 租户等级（free/pro/enterprise，影响配额）

local cjson = require "cjson.safe"

local _M = {}

-- 租户等级配额配置
-- free: 免费试用；pro: 付费专业版；enterprise: 企业版
local TIER_QUOTA = {
    free       = { qps = 2,  concurrent = 2,  daily_tokens = 100000 },
    pro        = { qps = 10, concurrent = 10, daily_tokens = 1000000 },
    enterprise = { qps = 50, concurrent = 50, daily_tokens = 10000000 },
}

local DEFAULT_TIER = "free"

-- 获取租户标识（优先级：请求头 > API Key > IP）
local function get_tenant_id()
    local headers = ngx.req.get_headers()
    return headers["X-Tenant-ID"]
        or headers["X-API-Key"]
        or ngx.var.remote_addr
end

-- 获取租户等级
local function get_tenant_tier()
    local headers = ngx.req.get_headers()
    local tier = headers["X-Tenant-Tier"] or DEFAULT_TIER
    if not TIER_QUOTA[tier] then
        tier = DEFAULT_TIER
    end
    return tier
end

-- 滑动窗口 QPS 检查
local function check_qps(dict, tenant_id, qps_limit)
    local now = ngx.now()
    local window_key = "qps:" .. tenant_id .. ":" .. math.floor(now)
    local count, err = dict:incr(window_key, 1, 0, 2)
    if not count then
        ngx.log(ngx.ERR, "failed to incr qps counter: ", err)
        return true  -- 计数器故障时放行，避免误杀
    end
    return count <= qps_limit
end

-- 并发数检查
local function check_concurrent(dict, tenant_id, concurrent_limit)
    local key = "conc:" .. tenant_id
    local count, err = dict:incr(key, 1, 0, 60)
    if not count then
        ngx.log(ngx.ERR, "failed to incr concurrent counter: ", err)
        return true, nil
    end
    if count > concurrent_limit then
        dict:incr(key, -1)  -- 回滚
        return false, nil
    end
    -- 注册请求结束时释放并发槽
    -- 注意：实际部署时应在 log_by_lua 阶段调用 release_concurrent
    return true, key
end

-- 释放并发槽（在 log_by_lua 阶段调用）
function _M.release_concurrent()
    local dict = ngx.shared.tenant_quota
    if not dict then return end
    local tenant_id = get_tenant_id()
    local key = "conc:" .. tenant_id
    dict:incr(key, -1, 0)
end

-- 每日 Token 配额检查（需上游在响应头返回 X-Tokens-Used）
function _M.check_token_quota(tenant_id, tier)
    local dict = ngx.shared.tenant_quota
    if not dict then return true end
    local quota = TIER_QUOTA[tier]
    local today = os.date("%Y-%m-%d")
    local key = "tokens:" .. tenant_id .. ":" .. today
    local used = dict:get(key) or 0
    return used < quota.daily_tokens, quota.daily_tokens - used
end

-- 累加 Token 使用量（在 log_by_lua 阶段调用，需上游返回用量）
function _M.record_token_usage()
    local dict = ngx.shared.tenant_quota
    if not dict then return end
    -- 从上游响应头或请求体解析 token 用量
    -- 简化版：按响应体大小估算（实际应由 LLM 后端返回精确值）
    local tenant_id = get_tenant_id()
    local today = os.date("%Y-%m-%d")
    local key = "tokens:" .. tenant_id .. ":" .. today
    -- 这里预留接口，实际用量由 header_filter 阶段注入
    local used = tonumber(ngx.var.upstream_tokens_used) or 0
    if used > 0 then
        dict:incr(key, used, 0, 86400)
    end
end

-- 主入口：在 access_by_lua 阶段调用
function _M.access()
    local dict = ngx.shared.tenant_quota
    if not dict then
        ngx.log(ngx.ERR, "lua_shared_dict 'tenant_quota' not configured")
        return  -- 未配置时放行，不阻断业务
    end

    local tenant_id = get_tenant_id()
    local tier = get_tenant_tier()
    local quota = TIER_QUOTA[tier]

    -- 1. QPS 检查
    if not check_qps(dict, tenant_id, quota.qps) then
        ngx.log(ngx.WARN, "tenant ", tenant_id, " exceeded QPS limit: ", quota.qps)
        ngx.status = 429
        ngx.header["X-RateLimit-Limit"] = quota.qps
        ngx.header["X-RateLimit-Tier"] = tier
        ngx.header["Retry-After"] = "1"
        ngx.say(cjson.encode({
            error = {
                code = 429,
                message = "QPS exceeded for tier '" .. tier .. "' (limit: " .. quota.qps .. "/s)",
                type = "tenant_qps_exceeded",
            }
        }))
        return ngx.exit(429)
    end

    -- 2. 并发检查
    local ok, conc_key = check_concurrent(dict, tenant_id, quota.concurrent)
    if not ok then
        ngx.log(ngx.WARN, "tenant ", tenant_id, " exceeded concurrent limit: ", quota.concurrent)
        ngx.status = 429
        ngx.header["X-RateLimit-Tier"] = tier
        ngx.header["Retry-After"] = "5"
        ngx.say(cjson.encode({
            error = {
                code = 429,
                message = "concurrent requests exceeded for tier '" .. tier .. "' (limit: " .. quota.concurrent .. ")",
                type = "tenant_concurrent_exceeded",
            }
        }))
        return ngx.exit(429)
    end

    -- 3. Token 配额检查
    local has_quota, remaining = _M.check_token_quota(tenant_id, tier)
    if not has_quota then
        -- 回滚并发计数
        if conc_key then dict:incr(conc_key, -1) end
        ngx.log(ngx.WARN, "tenant ", tenant_id, " exceeded daily token quota")
        ngx.status = 429
        ngx.header["X-RateLimit-Tier"] = tier
        ngx.say(cjson.encode({
            error = {
                code = 429,
                message = "daily token quota exceeded for tier '" .. tier .. "'",
                type = "tenant_quota_exceeded",
            }
        }))
        return ngx.exit(429)
    end

    -- 全部通过，注入租户信息到上游请求头
    ngx.req.set_header("X-Tenant-ID", tenant_id)
    ngx.req.set_header("X-Tenant-Tier", tier)
    ngx.req.set_header("X-Quota-Remaining", tostring(remaining))
end

return _M
