# 多租户额度限流插件

参赛作品「端侧智算网关」的 OpenNJet 深度优化组件。

## 背景

团队共享一台强机算力时（如 AMD Strix Halo 跑 llama.cpp），最怕单个租户/用户用脚本刷爆 QPS 或占满并发，导致其他人卡死。OpenNJet 自带的 `limit_req`/`limit_conn` 是全局的，不区分租户。本插件实现**按租户 ID 的多维度限流**。

## 三维限流

| 维度 | 说明 | 超限返回 |
|---|---|---|
| QPS | 每秒请求数（滑动窗口） | 429 + `Retry-After: 1` |
| 并发 | 同时进行的请求数 | 429 + `Retry-After: 5` |
| Token 配额 | 每日累计 Token 用量 | 429 |

## 租户等级

| 等级 | QPS | 并发 | 日 Token |
|---|---|---|---|
| free | 2 | 2 | 100,000 |
| pro | 10 | 10 | 1,000,000 |
| enterprise | 50 | 50 | 10,000,000 |

通过请求头 `X-Tenant-Tier` 指定，未指定默认为 `free`。

## 配置示例

```nginx
http {
    lua_shared_dict tenant_quota 10m;

    server {
        listen 8443 ssl;
        location /v1/ {
            access_by_lua_file conf/tenant_limit.lua;
            # 注意：需要在 lua 文件末尾调用 _M.access()
            # 或使用 content_by_lua_block 包装

            proxy_pass http://llm_backend;

            # 请求结束时释放并发槽、记录 Token 用量
            log_by_lua_block {
                local limiter = require "tenant_limit"
                limiter.release_concurrent()
                limiter.record_token_usage()
            }
        }
    }
}
```

## 租户标识优先级

1. `X-Tenant-ID` 请求头（推荐）
2. `X-API-Key` 请求头
3. 客户端 IP（兜底）

## 设计要点

- **故障开放**：共享字典未配置或计数器故障时放行，不阻断业务
- **计数器回滚**：QPS/并发超限时回滚已增加的计数，避免计数泄漏
- **响应头透传**：`X-RateLimit-Limit`、`X-RateLimit-Tier`、`X-Quota-Remaining` 方便客户端做退避
- **标准错误格式**：429 响应体为 JSON，`type` 字段区分超限类型，便于客户端程序化处理

## 测试

```bash
# 正常请求（free 等级，2 QPS）
curl -H "X-Tenant-ID: team-a" -H "X-Tenant-Tier: free" https://localhost:8443/v1/models

# 压测触发限流
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "X-Tenant-ID: team-a" https://localhost:8443/v1/models &
done
# 预期：前 2 个返回 200，其余返回 429
```

## 与「端侧智算网关」的关系

本插件是网关多租户能力的核心组件，与以下部分配合：

- **端侧基准数据**：限流阈值基于 AMD Strix Halo + llama.cpp 实测性能调优（qwen3.8-27b 平均 4.27 tok/s），确保多租户共享时单租户不拖垮整体吞吐
- **JoySafety 集成**：限流通过后，请求内容经安全检查再转发给 LLM
- **desktop-model-gateway**：Node.js 网关调用 OpenNJet 的限流接口，统一额度管理

## License

MulanPSL-2.0（跟随 OpenNJet 主仓库）
