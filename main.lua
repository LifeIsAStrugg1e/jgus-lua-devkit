sys = require("sys")
jgus = require("jgus")
-- 加载 uart 模块
uart = require("uart")
-- 获取默认串口（8pin通信口的串口号）
uart_no = uart.get_default_index()

-- 初始化默认串口：115200 8N1
local init_ok, init_err = uart.init(uart_no, 115200, 8, 1, 0)
if init_ok == nil then
    print("uart init 失败:", init_err)
end

-- 加载非内核封装模块
require("json")

-- 关闭JGUS协议通讯
--jgus.disable_serial_receive()


-- 变量定义
-- 面膜功能
local facial_mask_level = 12;
local facial_mask_mode = 1;
local facial_mask_time = 30;
local facial_mask_state = 0;
local facial_mask_time_logo = 0;

-- 面部手具
local faicialTool_microcurrent_mode = 1;
local faicialTool_faver_level = 1;
local faicialTool_microcurrent_level = 0;
local faicialTool_time = 25;
local faicialTool_state = 0;

-- 负离子功能
local negative_ion_level = 1;
local negative_ion_time = 25;
local negative_ion_state = 0;

-- 运行状态
RuningState = 0

-- 三个功能输出控制占位（未来实现），on/off 时串口上报
local function mask_power(on)
    uart.send(uart_no, on and "mask_power_on\n" or "mask_power_off\n")
end
local function tool_power(on)
    uart.send(uart_no, on and "tool_power_on\n" or "tool_power_off\n")
end
local function ion_power(on)
    uart.send(uart_no, on and "ion_power_on\n" or "ion_power_off\n")
end

-- 三功能共用倒计时配置：key=按键VP, time=时长VP, run_page=运行页, base_page=基础页
local funcs = {
    { key = 0x1105, time = 0x1102, run_page = 4, base_page = 1, power = mask_power },  -- A 面膜
    { key = 0x1204, time = 0x1203, run_page = 5, base_page = 2, power = tool_power },  -- B 面部手具
    { key = 0x1302, time = 0x1301, run_page = 6, base_page = 3, power = ion_power },   -- C 负离子
}
local run_func = 0      -- 当前运行的功能下标（0=无）
local run_state = 0     -- 0=停止 1=运行
local mask_follow = false   -- 面膜是否因 A5 跟随运行中
-- 倒计时（分钟-秒十位-秒个位，不超过1小时）
local minute = 0
local second = 0
local send_tick = 0

-- 设置某功能的状态变量（1=A面膜 2=B面部 3=C负离子）
local function set_func_state(idx, v)
    if idx == 1 then facial_mask_state = v
    elseif idx == 2 then faicialTool_state = v
    elseif idx == 3 then negative_ion_state = v end
end

-- 统一结束当前功能（按键结束/时间到/切页停止共用）
local function stop_current_func()
    if run_func == 0 then return end
    set_func_state(run_func, 0)
    funcs[run_func].power(false)           -- 本功能结束调用
    if mask_follow then                    -- A5 跟随的面膜一并关闭
        mask_power(false)
        mask_follow = false
    end
    run_func = 0
end

-- 按键扫描：轮询三套按键VP（1=开始，2=结束）
sys.taskInit(function()
    while true do
        for i = 1, 3 do
            local f = funcs[i]
            local key = jgus.vp_read(f.key)
            if key == 1 then
                if run_state == 0 then                 -- 只有停止态才允许开始
                    f.power(true)                      -- 本功能启动调用
                    if i ~= 1 and jgus.vp_read(0x4400) == 0xA5 then
                        mask_power(true)               -- A5：面膜跟随启动
                        mask_follow = true
                    end
                    -- 清冗余：三个功能状态全归0，再置当前
                    facial_mask_state = 0
                    faicialTool_state = 0
                    negative_ion_state = 0
                    set_func_state(i, 1)
                    minute = jgus.vp_read(f.time)
                    second = 0
                    send_tick = 0
                    jgus.vp_write(0x3101, minute)
                    jgus.vp_write(0x3102, 0)
                    jgus.vp_write(0x3103, 0)
                    run_func = i
                    run_state = 1
                    jgus.screen_set_page(f.run_page)
                end
                jgus.vp_write(f.key, 0)                -- 清零等下次按键
            elseif key == 2 then
                if run_func == i then                 -- 只认当前运行功能的结束键
                    run_state = 0
                    stop_current_func()
                    jgus.screen_set_page(f.base_page)
                end
                jgus.vp_write(f.key, 0)
            end
        end
        sys.wait(30)
    end
end)

-- 倒计时：每秒递减+刷新0x3101~0x3103（分/秒十位/秒个位），每5秒串口上报剩余时间
sys.taskInit(function()
    while true do
        if run_state == 1 then
            -- 切页检测：当前页不是本功能运行页 → 直接结束（不代切页）
            if run_func == 0 or jgus.vp_read(0x0014) ~= funcs[run_func].run_page then
                run_state = 0
                stop_current_func()
            else
                if second > 0 then
                    second = second - 1
                elseif minute > 0 then
                    minute = minute - 1
                    second = 59
                else
                    local base_page = funcs[run_func].base_page
                    run_state = 0                           -- 时间到，停
                    stop_current_func()
                    jgus.screen_set_page(base_page)         -- 回本功能基础页
                end
                jgus.vp_write(0x3101, minute)
                jgus.vp_write(0x3102, math.floor(second / 10))   -- 秒十位
                jgus.vp_write(0x3103, second % 10)               -- 秒个位

                send_tick = send_tick + 1
                if send_tick >= 5 then
                    send_tick = 0
                    uart.send(uart_no, string.format("%02d:%02d\n", minute, second))
                end
            end
        end
        sys.wait(1000)
    end
end)

-- 0.5秒周期：刷新0x2000状态（0x4400==A5 → 2；主页1/4 → 1；其他 → 0）
sys.taskInit(function()
    while true do
        local reg = jgus.vp_read(0x4400)
        if reg == 0xA5 then
            jgus.vp_write(0x2000, 2)
        else
            -- A5 消失：跟随启动的面膜自动关闭
            if mask_follow then
                mask_power(false)
                mask_follow = false
            end
            local page = jgus.vp_read(0x0014)
            if page == 1 or page == 4 then
                jgus.vp_write(0x2000, 1)
            else
                jgus.vp_write(0x2000, 0)
            end
        end
        sys.wait(100)
    end
end)

-- 开屏等待3秒后，跳转到主界面
sys.taskInit(function()
    sys.wait(3000)
    jgus.screen_set_page(1)
end)

-- 启动调度器（开始运行任务）
sys.scheduler()
