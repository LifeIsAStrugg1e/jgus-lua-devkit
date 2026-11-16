local sys = {}
local jgus = require("jgus")

-- 任务表
local tasks = {}
local timers = {}
local events = {}
local running = true

-- 获取当前时间（毫秒）
local function get_tick_ms()
    return jgus.tick_get()
end

-- 启动任务
function sys.taskInit(func)
    local co = coroutine.create(func)
    table.insert(tasks, co)
end

-- 定时器管理
function sys.add_timer(ms, callback)
    local start_time = get_tick_ms()
    table.insert(timers, {
        end_time = start_time + ms,
        callback = callback
    })
end

-- 事件订阅
function sys.subscribe(event_name, callback)
    events[event_name] = events[event_name] or {}
    table.insert(events[event_name], callback)
end

-- 事件发布
function sys.publish(event_name, ...)
    local callbacks = events[event_name]
    if callbacks then
        for _, cb in ipairs(callbacks) do
            cb(...)
        end
    end
end

-- 延时（非阻塞式）
function sys.wait(ms)
    local deadline = get_tick_ms() + ms
    while true do
        if get_tick_ms() >= deadline then break end
        coroutine.yield()  -- 让出控制权
    end
end

-- 主调度器（需在另一个线程/进程中运行）
function sys.scheduler()
    while running do
        -- 执行所有任务
        for i = #tasks, 1, -1 do
            local co = tasks[i]
            local status = coroutine.status(co)
            if status == "dead" then
                table.remove(tasks, i)
            elseif status == "suspended" then
                local ok, err = coroutine.resume(co)
                if not ok then
                    print("Error in task:", err)
                end
            end
        end
        
        -- 检查并触发定时器
        local now = get_tick_ms()
        for i = #timers, 1, -1 do
            if now >= timers[i].end_time then
                timers[i].callback()
                table.remove(timers, i)
            end
        end

        -- 避免CPU占用过高
        msleep(2)
    end
end

return sys