-- ============================================================================
-- JGUS 串口屏 + Lua 模组 工程模板(完整可跑骨架 = 上一项目具体实例)
-- ----------------------------------------------------------------------------
-- 来源 : 参考/main-ASCII显示正常.lua(等离子治疗仪项目,协议网关架构,已验证)
-- 用法 : 新建工程时整体复制本文件为 main.lua,再按文件末尾"新工程适配清单"改 VP
-- 分块 : 通用套路(占位符版)见 doc/代码块库.md;本文件是填好具体值的项目实例
-- 修正 : 带【修正】标注处为原参考码 bug 的修复,详见 代码块库.md 第八部分
--
-- 【本实例 VP 地址映射表】(上一项目等离子治疗仪,改造参考)
--   按键回读类(屏幕写 1/2,处理完清 0):
--     0x1010 启停        0x1015 页面切换     0x101A 时间加减
--     0x1020 A模式加减   0x1030 B微电模式    0x1040 A强度
--     0x1050 B发热强度   0x1060 B微电强度    0x1070 C强度
--   显示/状态类:
--     0x1100~1102 A/B/C 状态灯(互斥)          0x1110 倒计时显示
--     0x1120 A模式值       0x1130 B微电模式值   0x1140 A强度值
--     0x1150 B发热强度值   0x1160 B微电强度值   0x1170 C强度值
--   控制类:
--     0x00A0 结束提示      0x00B0 触控使能写入口  0x00E8/0x00E9 ASCII弹窗
--     0x2000+ ASCII 文本区
-- ============================================================================

-- ============================================================================
-- 一、模块加载与初始化(必选)
-- ============================================================================
local sys = require("sys")
local jgus = require("jgus")
local uart = require("uart")
local uart_no = uart.get_default_index()

-- 初始化 UART,波特率 115200,8N1
local ok = uart.init(uart_no, 115200, 8, 1, 0)
if ok ~= 1 then
    print("Failed to initialize UART")
end
print("UART init result:", ok)

-- 【兼容】Lua 5.4 无全局 unpack,必须加垫片
if not unpack then
    unpack = table.unpack
end

-- 【调试】把字符串直接发到串口(真机上 print 不可见,用这个)
function printk(str)
    uart.send(uart_no, str)
end

-- 【关键】关闭屏幕内置 AGUS 协议通讯,改用自定义协议(必须调用)
jgus.disable_serial_receive()

-- ============================================================================
-- 二、常量与数据模型
-- ============================================================================

-- 帧头
local FRAMER_HEADH = 0xA5
local FRAMER_HEADL = 0x5A

-- 允许/禁止某页开始触控按键的帧生成函数(不要手抄常量,页号易错)
-- 帧格式:A5 5A <页号> 0005 01 <1使能/0禁止> 00,配 vp_write_data(帧, 0x00B0, 4) 使用
local function touch_ctrl_frame(page, enable)
    return string.char(0xA5, 0x5A, page, 0x00, 0x05, 0x01,
                       enable and 1 or 0, 0x00)
end

-- 【本实例专属结构体】TREATMENT_T:上一项目 13 字节串口帧业务字段的内存镜像
-- 字段(Voice/Language/FunctionKey/Minutes/Seconds 等)由该项目的协议决定,
-- 新工程请按自己的帧约定重新定义,不要直接沿用;通用做法见 代码块库.md 块 3-1
local TREATMENT_T = {}
TREATMENT_T.__index = TREATMENT_T

function TREATMENT_T:new()
    local instance = {
        Order = 0,          -- 读写指令
        Voice = 0,          -- 语音开关
        Language = 0,       -- 语言选择
        Screen = 0,         -- 页面号 ID
        FunctionKey = 0,    -- 控件号 ID
        FunctionValue = 0,  -- 控件号配置的值
        When = 0,           -- 时
        Minutes = 0,        -- 分
        Seconds = 0,        -- 秒
        time = 0,           -- 时间戳
        time1 = 0           -- 时间戳1
    }
    setmetatable(instance, TREATMENT_T)
    return instance
end

local TreatmentTable = TREATMENT_T:new()

-- 全局状态变量(新工程按自己控件增删)
local RunFlage = 0              -- 1 启动 / 2 停止
local ModeValue = 0             -- A 模式值
local MpaValueA = 0             -- A 强度值
local MpaValueC = 0             -- C 强度值
local WeidModeValue = 0         -- B 微电模式值
local FareMpaValue = 0          -- B 发热强度值
local WeidMpaValue = 0          -- B 微电强度值
local PageID = 0                -- 当前页面号
local falg = 1                  -- 杂项标志(原码保留)
local NFC_ZhuanT = 0            -- NFC 刷卡状态(1 正常 / 2 已激活)

-- ============================================================================
-- 三、CRC16 与帧收发(必选)
-- ============================================================================

-- CRC16,Modbus 标准多项式 0xA001
local function Calculate_CRC16(data, len)
    local Reg_CRC = 0xFFFF
    for i = 1, len do
        Reg_CRC = Reg_CRC ~ data[i]
        for j = 1, 8 do
            if (Reg_CRC & 0x0001) ~= 0 then
                Reg_CRC = (Reg_CRC >> 1) ~ 0xA001
            else
                Reg_CRC = Reg_CRC >> 1
            end
        end
    end
    return Reg_CRC
end

-- 读帧发送(0xAF):把当前状态上报给外设
local function read_send_code()
    local buffer = {}
    buffer[1] = FRAMER_HEADH
    buffer[2] = FRAMER_HEADL
    buffer[3] = 0xAF
    buffer[4] = TreatmentTable.Voice
    buffer[5] = TreatmentTable.Language
    buffer[6] = TreatmentTable.Screen
    buffer[7] = TreatmentTable.FunctionKey
    buffer[8] = TreatmentTable.FunctionValue
    buffer[9] = TreatmentTable.When
    buffer[10] = TreatmentTable.Minutes
    buffer[11] = TreatmentTable.Seconds
    local value = Calculate_CRC16(buffer, 11)
    buffer[12] = value >> 8    -- CRC 高字节在前
    buffer[13] = value & 0xFF
    local str = string.char(unpack(buffer))
    uart.send(uart_no, str)
end

-- 写帧发送(0xFA):把配置变更推送给外设
local function write_send_code()
    local buffer = {}
    buffer[1] = FRAMER_HEADH
    buffer[2] = FRAMER_HEADL
    buffer[3] = 0xFA
    buffer[4] = TreatmentTable.Voice
    buffer[5] = TreatmentTable.Language
    buffer[6] = TreatmentTable.Screen
    buffer[7] = TreatmentTable.FunctionKey
    buffer[8] = TreatmentTable.FunctionValue
    buffer[9] = TreatmentTable.When
    buffer[10] = TreatmentTable.Minutes
    buffer[11] = TreatmentTable.Seconds
    local value = Calculate_CRC16(buffer, 11)
    buffer[12] = value >> 8
    buffer[13] = value & 0xFF
    local str = string.char(unpack(buffer))
    uart.send(uart_no, str)
end

-- 倒计时时间显示:分秒合成一个数(如 30:05 → 3005)
local function time_display()
    local value = TreatmentTable.Minutes * 100 + TreatmentTable.Seconds
    jgus.vp_write(0x1110, value)
end

-- ============================================================================
-- 四、按键处理(按需增删)
-- ============================================================================

-- 启停按键(读 0x1010)
local function Switch_Key_Config()
    if 0 ~= jgus.vp_read(0x1010) then
        if 1 == jgus.vp_read(0x1010) then       -- 开启
            RunFlage = 1
            TreatmentTable.FunctionKey = 1
            TreatmentTable.FunctionValue = RunFlage
        end
        if 2 == jgus.vp_read(0x1010) then       -- 暂停
            RunFlage = 2
            TreatmentTable.FunctionKey = 1
            TreatmentTable.FunctionValue = RunFlage
        end
        write_send_code()
        jgus.vp_write(0x1010, 0)
    end
end

-- 通用"加减按键"配置(原工程 6 个 Key_Config 的抽象,推荐新工程用它)
-- vp_key: 按键回读 VP;vp_disp: 显示 VP;get/set: 变量读写闭包
-- min/max: 范围;fkey: 上报帧控件号
local function AddSub_Key_Config(vp_key, vp_disp, get, set, min, max, fkey)
    if 0 ~= jgus.vp_read(vp_key) then
        local v = get()
        if 2 == jgus.vp_read(vp_key) then       -- 加
            v = (v >= max) and max or (v + 1)
        end
        if 1 == jgus.vp_read(vp_key) then       -- 减
            v = (v <= min) and min or (v - 1)
        end
        set(v)
        TreatmentTable.FunctionKey = fkey
        TreatmentTable.FunctionValue = v
        jgus.vp_write(vp_disp, v)
        write_send_code()
        jgus.vp_write(vp_key, 0)
    end
end

-- 倒计时时间加减(min/max 由当前页面决定)
local function Countdown_Key_Config(min, max)
    if 0 ~= jgus.vp_read(0x101A) then
        if 2 == jgus.vp_read(0x101A) then       -- 加 1 分
            TreatmentTable.Minutes = TreatmentTable.Minutes + 1
            if TreatmentTable.Minutes > max then
                TreatmentTable.Minutes = max
            end
        end
        if 1 == jgus.vp_read(0x101A) then       -- 减 1 分
            TreatmentTable.Minutes = TreatmentTable.Minutes - 1
            if TreatmentTable.Minutes <= min then
                TreatmentTable.Minutes = min
            end
        end
        time_display()
        write_send_code()
        jgus.vp_write(0x101A, 0)
    end
end

-- 页面切换按键(读 0x1015):切页 → 恢复默认值 → 上报
local function ZhuangT_Key_Config()
    if 0 ~= jgus.vp_read(0x1015) then
        TreatmentTable.Screen = jgus.vp_read(0x1015)
        PageID = TreatmentTable.Screen
        ZhuangT_init()
        TreatmentTable.When = 0
        TreatmentTable.Seconds = 0
        time_display()
        RunFlage = 0
        TreatmentTable.FunctionKey = 0xFF
        TreatmentTable.FunctionValue = 0xFF
        write_send_code()
        jgus.vp_write(0x1015, 0)
    end

    -- 各页时间上限不同,按页分发
    if 1 == TreatmentTable.Screen then
        Countdown_Key_Config(1, 30)
    elseif 2 == TreatmentTable.Screen then
        Countdown_Key_Config(1, 25)
    elseif 3 == TreatmentTable.Screen then
        Countdown_Key_Config(1, 25)
    end
end

-- ============================================================================
-- 五、页面与初始化
-- ============================================================================

-- 页面初始值设置:切到某页后恢复该页默认参数 + 状态灯互斥
local function ZhuangT_init()
    if 1 == PageID then  -- A 界面
        ModeValue = 1
        jgus.vp_write(0x1120, ModeValue)
        MpaValueA = 1
        jgus.vp_write(0x1140, MpaValueA)
        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)
        else
            NFC_ZhuanT = 1
            jgus.vp_write(0x1100, NFC_ZhuanT)
        end
        jgus.vp_write(0x1101, 0)
        jgus.vp_write(0x1102, 0)
        TreatmentTable.Minutes = 30
        jgus.screen_set_page(1)
    elseif 2 == PageID then  -- B 界面
        WeidModeValue = 1
        jgus.vp_write(0x1130, WeidModeValue)
        FareMpaValue = 1
        jgus.vp_write(0x1150, FareMpaValue)
        WeidMpaValue = 1
        jgus.vp_write(0x1160, WeidMpaValue)
        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)
        else
            NFC_ZhuanT = 0
            jgus.vp_write(0x1100, NFC_ZhuanT)
        end
        jgus.vp_write(0x1101, 1)
        jgus.vp_write(0x1102, 0)
        TreatmentTable.Minutes = 25
        jgus.screen_set_page(2)
    elseif 3 == PageID then  -- C 界面
        MpaValueC = 1
        jgus.vp_write(0x1170, MpaValueC)
        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)
        else
            NFC_ZhuanT = 0
            jgus.vp_write(0x1100, NFC_ZhuanT)
        end
        jgus.vp_write(0x1101, 0)
        jgus.vp_write(0x1102, 1)
        TreatmentTable.Minutes = 25
        jgus.screen_set_page(3)
    end
end

-- 上电初始化
local function use_init()
    TreatmentTable.Voice = 0
    TreatmentTable.Language = 0
    TreatmentTable.Screen = 1
    TreatmentTable.When = 0
    TreatmentTable.Minutes = 30
    TreatmentTable.Seconds = 0
    TreatmentTable.FunctionKey = 0xFF
    TreatmentTable.FunctionValue = 0xFF
    time_display()
    ModeValue = 1
    jgus.vp_write(0x1120, ModeValue)
    MpaValueA = 1                          -- 【修正】原码写 MpaValue(未声明)
    jgus.vp_write(0x1140, MpaValueA)
    NFC_ZhuanT = 1
    jgus.vp_write(0x1100, NFC_ZhuanT)
    jgus.vp_write_data(touch_ctrl_frame(1, false), 0x00B0, 4)  -- 禁止开始按键触控
    write_send_code()
end

-- ============================================================================
-- 六、串口业务处理
-- ============================================================================

-- 读配置(外设来 0xAF 帧 → 按控件号回填当前值 → 回读帧)
local function read_config(buf)
    TreatmentTable.Voice = buf[4]
    TreatmentTable.Language = buf[5]

    if buf[6] == 0 then
        TreatmentTable.FunctionKey = 0xFF
        TreatmentTable.FunctionValue = 0xFF
        TreatmentTable.When = 0
        TreatmentTable.Minutes = 0
        TreatmentTable.Seconds = 0
    elseif buf[6] >= 1 and buf[6] <= 3 then   -- 【修正】原码 or 恒真
        TreatmentTable.FunctionKey = buf[7]
        if TreatmentTable.FunctionKey == 1 then
            TreatmentTable.FunctionValue = RunFlage
        elseif TreatmentTable.FunctionKey == 2 then
            TreatmentTable.FunctionValue = ModeValue
        elseif TreatmentTable.FunctionKey == 3 then
            TreatmentTable.FunctionValue = WeidModeValue
        elseif TreatmentTable.FunctionKey == 4 then
            -- 【修正】原码取未声明的 MpaValue,改为按页面取值
            if TreatmentTable.Screen == 1 then
                TreatmentTable.FunctionValue = MpaValueA
            else
                TreatmentTable.FunctionValue = MpaValueC
            end
        elseif TreatmentTable.FunctionKey == 5 then
            TreatmentTable.FunctionValue = FareMpaValue
        elseif TreatmentTable.FunctionKey == 6 then
            TreatmentTable.FunctionValue = WeidMpaValue
        elseif TreatmentTable.FunctionKey == 7 then
            TreatmentTable.FunctionValue = NFC_ZhuanT
        else
            TreatmentTable.FunctionKey = 0
        end
    end
    read_send_code()
end

-- 写配置(外设来 0xFA 帧 → 落变量 + 刷屏幕;新工程主要改这块分支)
local function write_config(buf)
    TreatmentTable.Voice = buf[4]
    TreatmentTable.Language = buf[5]
    TreatmentTable.Screen = buf[6]
    TreatmentTable.FunctionKey = buf[7]
    TreatmentTable.FunctionValue = buf[8]
    TreatmentTable.When = buf[9]
    TreatmentTable.Minutes = buf[10]
    TreatmentTable.Seconds = buf[11]

    -- 页面跳转 + 状态灯互斥
    if TreatmentTable.Screen == 1 then
        jgus.screen_set_page(1)
        if NFC_ZhuanT ~= 2 then NFC_ZhuanT = 1 end
        jgus.vp_write(0x1100, NFC_ZhuanT)
        jgus.vp_write(0x1101, 0)
        jgus.vp_write(0x1102, 0)
    elseif TreatmentTable.Screen == 2 then
        jgus.screen_set_page(2)
        if NFC_ZhuanT ~= 2 then NFC_ZhuanT = 0 end
        jgus.vp_write(0x1100, NFC_ZhuanT)
        jgus.vp_write(0x1101, 1)
        jgus.vp_write(0x1102, 0)
    elseif TreatmentTable.Screen == 3 then
        jgus.screen_set_page(3)
        if NFC_ZhuanT ~= 2 then NFC_ZhuanT = 0 end
        jgus.vp_write(0x1100, NFC_ZhuanT)
        jgus.vp_write(0x1101, 0)
        jgus.vp_write(0x1102, 1)
    end

    -- 控件号分发
    if TreatmentTable.FunctionKey == 1 then  -- 启停
        if TreatmentTable.FunctionValue == 1 then
            RunFlage = 1
            if TreatmentTable.Screen == 1 then jgus.screen_set_page(4) end
            if TreatmentTable.Screen == 2 then jgus.screen_set_page(5) end
            if TreatmentTable.Screen == 3 then jgus.screen_set_page(6) end
        elseif TreatmentTable.FunctionValue == 2 then
            RunFlage = 2
        end
    elseif TreatmentTable.FunctionKey == 2 then
        ModeValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1120, ModeValue)
    elseif TreatmentTable.FunctionKey == 3 then
        WeidModeValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1130, WeidModeValue)
    elseif TreatmentTable.FunctionKey == 4 then
        if TreatmentTable.Screen == 1 then
            MpaValueA = TreatmentTable.FunctionValue
            jgus.vp_write(0x1140, MpaValueA)
        elseif TreatmentTable.Screen == 3 then
            MpaValueC = TreatmentTable.FunctionValue
            jgus.vp_write(0x1170, MpaValueC)
        end
    elseif TreatmentTable.FunctionKey == 5 then
        FareMpaValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1150, FareMpaValue)
    elseif TreatmentTable.FunctionKey == 6 then
        WeidMpaValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1160, WeidMpaValue)
    elseif TreatmentTable.FunctionKey == 7 then  -- NFC 刷卡联动开始键使能
        NFC_ZhuanT = TreatmentTable.FunctionValue
        if NFC_ZhuanT == 2 then
            jgus.vp_write_data(touch_ctrl_frame(1, true), 0x00B0, 4)   -- 允许开始按键触控
        else
            jgus.vp_write_data(touch_ctrl_frame(1, false), 0x00B0, 4)  -- 禁止开始按键触控
        end
        jgus.vp_write(0x1100, NFC_ZhuanT)
    elseif TreatmentTable.FunctionKey == 8 then  -- ASCII 弹窗
        if TreatmentTable.FunctionValue == 1 then
            jgus.vp_write(0x00E8, 0x5A01)
            jgus.vp_write(0x00E9, 0x0007)
        else
            jgus.vp_write(0x00E8, 0x0000)
        end
    end
    time_display()
end

-- ASCII 文本显示(0x55 帧 → 0x2000 起文本区,两两拼 16 位)
local function txt_command(buf)
    local DatLen = (buf[4] << 8) | buf[5]
    for i = 0, (DatLen / 2) - 1 do
        jgus.vp_write(0x2000 + i, ((buf[6 + i * 2] << 8) | buf[7 + i * 2]))
    end
end

-- 接收状态机:逐字节收帧 + CRC 验证 + 分发(必选)
local cmdbuf = {}
local cmdcount = 0
local cmdflags = 0

local function cus_command()
    local ret, data = uart.receive(uart_no, 1)
    while ret > 0 do
        cmdbuf[cmdcount + 1] = string.byte(data)  -- Lua 索引从 1 开始
        cmdcount = cmdcount + 1

        -- 缓冲区溢出保护
        if cmdcount >= 256 then
            cmdcount = 0
            cmdflags = 0
            break
        end

        if 0x01 == cmdflags then  -- 已同步帧头
            if cmdcount == 13 then
                local value = Calculate_CRC16(cmdbuf, 11)
                -- 高低字节序都接受,兼容对端差异
                if ((cmdbuf[12] == (value & 0xFF) and cmdbuf[13] == (value >> 8)) or
                    (cmdbuf[12] == (value >> 8) and cmdbuf[13] == (value & 0xFF))) then
                    if cmdbuf[3] == 0xAF then       -- 读操作
                        read_config(cmdbuf)
                    elseif cmdbuf[3] == 0xFA then   -- 写操作
                        write_config(cmdbuf)
                        jgus.reg_write(0x02, 10)    -- 应答屏幕,不能删
                    end
                    cmdcount = 0
                    cmdflags = 0
                end
            elseif cmdcount >= 206 then
                if cmdbuf[3] == 0x55 then           -- ASCII 码显示帧
                    txt_command(cmdbuf)
                    jgus.reg_write(0x02, 10)
                    cmdcount = 0
                    cmdflags = 0
                end
            end
        else  -- 尚未同步,找帧头 A5 5A
            if (cmdcount == 2) and (cmdbuf[1] == 0xA5) and (cmdbuf[2] == 0x5A) then
                cmdflags = 0x01
            elseif (cmdcount == 1) and (cmdbuf[1] == 0xA5) then
                -- 等下一个字节
            else
                cmdcount = 0
            end
        end

        ret, data = uart.receive(uart_no, 1)
    end
end

-- ============================================================================
-- 七、倒计时引擎(1s 任务驱动)
-- ============================================================================
local function Countdown()
    if RunFlage == 1 then
        -- 【修正】原码的 local ticks 每次调用归零,相关分支是死代码,已删
        -- 计时节拍由外层 sys.taskInit 的 sys.wait(1000) 提供
        if 0 == TreatmentTable.Seconds then
            if 0 ~= TreatmentTable.Minutes then
                TreatmentTable.Seconds = 59
                TreatmentTable.Minutes = TreatmentTable.Minutes - 1
            else
                -- 倒计时结束:跳回主界面 + 初始化 + 上报 + 提示
                RunFlage = 2
                TreatmentTable.FunctionKey = 1
                TreatmentTable.FunctionValue = RunFlage
                if 4 == jgus.screen_get_page() then
                    jgus.screen_set_page(1); PageID = 1
                elseif 5 == jgus.screen_get_page() then
                    jgus.screen_set_page(2); PageID = 2
                elseif 6 == jgus.screen_get_page() then
                    jgus.screen_set_page(3); PageID = 3
                end
                ZhuangT_init()
                write_send_code()
                jgus.vp_write(0x00A0, 10)   -- 结束提示,按工程改
            end
        else
            TreatmentTable.Seconds = TreatmentTable.Seconds - 1
        end
        time_display()
    end
end

-- ============================================================================
-- 八、任务启动(顺序别动:scheduler 必须最后)
-- ============================================================================

use_init()

-- 主任务:10ms 轮询按键 + 串口收帧
sys.taskInit(function()
    while true do
        Switch_Key_Config()          -- 启停按键
        ZhuangT_Key_Config()         -- 页面切换 + 时间加减(内含按页分发)
        -- 加减类按键:用通用模板注册,示例如下(按新工程 VP 改)
        -- AddSub_Key_Config(0x1020, 0x1120,
        --     function() return ModeValue end,
        --     function(v) ModeValue = v end, 1, 5, 2)
        cus_command()                -- 串口收帧
        sys.wait(10)
    end
end)

-- 倒计时任务:1s 一跳
sys.taskInit(function()
    while true do
        Countdown()
        sys.wait(1000)
    end
end)

sys.scheduler()

-- ============================================================================
-- 新工程适配清单(改完打勾):
--   [ ] 1. VP 地址:对照 project.json 全局搜索替换(本模板 VP 见 代码块库.md 第七部分表)
--   [ ] 2. 页面号:ZhuangT_init / write_config / Countdown 里的 screen_set_page(N)
--   [ ] 3. 帧格式:13 字节帧字段顺序、指令码 0xAF/0xFA/0x55、帧长 206(如不同)
--   [ ] 4. 按键块:加减类用 AddSub_Key_Config 一行注册;特殊逻辑改对应函数
--   [ ] 5. 业务分支:write_config 的 FunctionKey 分发按新控件重写
--   [ ] 6. 默认值:use_init / ZhuangT_init 的默认参数、各页时间上限
-- ============================================================================
