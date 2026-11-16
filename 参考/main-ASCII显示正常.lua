local sys = require("sys")
local jgus = require("jgus")
-- 加载 uart 模块
local uart = require("uart")
local uart_no = uart.get_default_index()
-- 初始化 UART 0 波特率115200，8N1
local ok = uart.init(uart_no, 115200, 8, 1, 0)
if ok ~= 1 then
    print("Failed to initialize UART")
end
print("UART init result:", ok)


if not unpack then
    unpack = table.unpack
end

-- function print(str)
--     uart.send(uart_no, str)
-- end

function printk(str)
    print("Type of a:", type(a))
    uart.send(uart_no, str)
end


jgus.disable_serial_receive()  -- 关闭AGUS协议通讯


-- 定义常量
local FRAMER_HEADH = 0xA5
local FRAMER_HEADL = 0x5A

-- 定义TREATMENT_T结构体的Lua等价物
local TREATMENT_T = {}
TREATMENT_T.__index = TREATMENT_T

-- 构造函数
function TREATMENT_T:new()
    local instance = {
        Order = 0,          -- 读写指令
        Voice = 0,          -- 语音开关
        Language = 0,       -- 语言选择
        Screen = 0,         -- 页面号ID
        FunctionKey = 0,    -- 控件号ID
        FunctionValue = 0,  -- 控件号ID配置的值
        When = 0,           -- 时
        Minutes = 0,        -- 分
        Seconds = 0,        -- 秒
        time = 0,           -- 时间戳
        time1 = 0           -- 时间戳1
    }
    setmetatable(instance, TREATMENT_T)
    return instance
end

-- 创建TreatmentTable实例
local TreatmentTable = TREATMENT_T:new()

-- 定义全局变量
local RunFlage = 0              -- 1启动、2停止状态
local ModeValue = 0             -- A模式值
local MpaValueA = 0             -- A强度值
local MpaValueC = 0             -- C强度值
local WeidModeValue = 0         -- B微电模式值
local FareMpaValue = 0          -- B发热强度值
local WeidMpaValue = 0          -- B微电强度值
local PageID = 0
local falg = 1
local NFC_ZhuanT = 0

--开启1、2、3页面的开始触控按键
local  Page1_KS = "\xA5\x5A\x01\x00\x05\x01\x01\x00"
local  Page2_KS = "\xA5\x5A\x02\x00\x05\x01\x01\x00"
local  Page2_KS = "\xA5\x5A\x03\x00\x05\x01\x01\x00"
--禁止1、2、3页面的开始触控按键
local  Page1_TZ = "\xA5\x5A\x01\x00\x05\x01\x00\x00"
local  Page2_TZ = "\xA5\x5A\x02\x00\x05\x01\x00\x00"
local  Page3_TZ = "\xA5\x5A\x03\x00\x05\x01\x00\x00"

-- CRC16校验函数
local function Calculate_CRC16(data, len)
    local Reg_CRC = 0xFFFF
    for i = 1, len do
        Reg_CRC = Reg_CRC ~ data[i]  -- 使用 ~ 替代 bit32.bxor
        for j = 1, 8 do
            if (Reg_CRC & 0x0001) ~= 0 then  -- 使用 & 替代 bit32.band
                Reg_CRC = (Reg_CRC >> 1) ~ 0xA001  -- 使用 >> 替代 bit32.rshift
            else
                Reg_CRC = Reg_CRC >> 1  -- 使用 >> 替代 bit32.rshift
            end
        end
    end
    return Reg_CRC
end

-- 读数据传送函数
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
    buffer[12] = value >> 8  -- 修改为使用返回值value
    buffer[13] = value & 0xFF -- 修改为使用返回值value
    
    -- 发送数据
    local str = string.char(unpack(buffer))
    uart.send(uart_no, str)
end

-- 写数据传送函数
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
    buffer[12] = value >> 8  -- 修改为使用返回值value
    buffer[13] = value & 0xFF -- 修改为使用返回值value
    
    -- 发送数据
    local str = string.char(unpack(buffer))
    uart.send(uart_no, str)
end

-- 倒计时时间显示
local function time_display()
    local value = TreatmentTable.Minutes * 100 + TreatmentTable.Seconds
    jgus.vp_write(0x1110, value)  -- 倒计时显示
end

-- 时间加减按键配置
local function Countdown_Key_Config(min, max)
    if 0 ~= jgus.vp_read(0x101A)then  -- 检测时间旁的加减按钮是否按下
        if 2 == jgus.vp_read(0x101A) then  -- 加1分
            TreatmentTable.Minutes = TreatmentTable.Minutes + 1
            if TreatmentTable.Minutes > max then
                TreatmentTable.Minutes = max
            end
        end
        
        if 1 == jgus.vp_read(0x101A) then  -- 减1分
            TreatmentTable.Minutes = TreatmentTable.Minutes - 1
            if TreatmentTable.Minutes <= min then
                TreatmentTable.Minutes = min
            end
        end
        
        time_display()
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x101A, 0)
    end
end

-- 开启、停止按键配置
local function Switch_Key_Config()
    if 0 ~= jgus.vp_read(0x1010) then
        if 1 == jgus.vp_read(0x1010) then  -- 开启
            RunFlage = 1
            TreatmentTable.FunctionKey = 1     -- 所在页面功能控件号
            TreatmentTable.FunctionValue = RunFlage  -- 所在页面功能控件号的值
        end
        
        if 2 == jgus.vp_read(0x1010) then  -- 暂停
            RunFlage = 2
            TreatmentTable.FunctionKey = 1     -- 所在页面功能控件号
            TreatmentTable.FunctionValue = RunFlage  -- 所在页面功能控件号的值
        end
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1010, 0)
    end
end

-- 模式按键加减配置
local function ModeValue_Key_Config()
    --print("ModeValue_Key_Config")
    if 0 ~= jgus.vp_read(0x1020) then
        if 2 == jgus.vp_read(0x1020) then -- 加
            if ModeValue >= 5 then
                ModeValue = 5
            else
                ModeValue = ModeValue + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1020) then  -- 减
            if ModeValue <= 1 then
                ModeValue = 1
            else
                ModeValue = ModeValue - 1
            end
        end
        
        TreatmentTable.FunctionKey = 2
        TreatmentTable.FunctionValue = ModeValue
        jgus.vp_write(0x1120, TreatmentTable.FunctionValue)
        --print(string.format("0x1020:%d",jgus.vp_read(0x1020)))
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1020, 0)
    end
end

-- 微电模式按键加减配置
local function WeidModeValue_Key_Config()
    if 0 ~= jgus.vp_read(0x1030) then
        if 2 == jgus.vp_read(0x1030) then  -- 加
            if WeidModeValue >= 5 then
                WeidModeValue = 5
            else
                WeidModeValue = WeidModeValue + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1030)  then  -- 减
            if WeidModeValue <= 1 then
                WeidModeValue = 1
            else
                WeidModeValue = WeidModeValue - 1
            end
        end
        
        TreatmentTable.FunctionKey = 3
        TreatmentTable.FunctionValue = WeidModeValue
        jgus.vp_write(0x1130, TreatmentTable.FunctionValue)
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1030, 0)
    end
end

-- A强度按键加减配置
local function MpaValueA_Key_Config()
    if 0 ~= jgus.vp_read(0x1040) then
        if 2 == jgus.vp_read(0x1040) then  -- 加
            if MpaValueA >= 12 then
                MpaValueA = 12
            else
                MpaValueA = MpaValueA + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1040) then  -- 减
            if MpaValueA <= 1 then
                MpaValueA = 1
            else
                MpaValueA = MpaValueA - 1
            end
        end
        
        TreatmentTable.FunctionKey = 4
        TreatmentTable.FunctionValue = MpaValueA
        jgus.vp_write(0x1140, TreatmentTable.FunctionValue)
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1040, 0)
    end
end

-- C强度按键加减配置
local function MpaValueC_Key_Config()
    if 0 ~= jgus.vp_read(0x1070) then
        if 2 == jgus.vp_read(0x1070) then  -- 加
            if MpaValueC >= 5 then
                MpaValueC = 5
            else
                MpaValueC = MpaValueC + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1070) then  -- 减
            if MpaValueC <= 1 then
                MpaValueC = 1
            else
                MpaValueC = MpaValueC - 1
            end
        end
        
        TreatmentTable.FunctionKey = 4
        TreatmentTable.FunctionValue = MpaValueC
        jgus.vp_write(0x1170, TreatmentTable.FunctionValue)
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1070, 0)
    end
end

-- 发热强度按键加减配置
local function FareMpaValue_Key_Config()
    if 0 ~= jgus.vp_read(0x1050) then
        if 2 == jgus.vp_read(0x1050) then  -- 加
            if FareMpaValue >= 5 then
                FareMpaValue = 5
            else
                FareMpaValue = FareMpaValue + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1050) then  -- 减
            if FareMpaValue <= 0 then
                FareMpaValue = 0
            else
                FareMpaValue = FareMpaValue - 1
            end
        end
        
        TreatmentTable.FunctionKey = 5
        TreatmentTable.FunctionValue = FareMpaValue
        jgus.vp_write(0x1150, TreatmentTable.FunctionValue)
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1050, 0)
    end
end

-- 微电强度按键加减配置
local function WeidMpaValue_Key_Config()
    if 0 ~= jgus.vp_read(0x1060) then
        if 2 == jgus.vp_read(0x1060) then  -- 加
            if WeidMpaValue >= 5 then  -- 注意：这里原代码可能是笔误，应该检查WeidMpaValue
                WeidMpaValue = 5
            else
                WeidMpaValue = WeidMpaValue + 1
            end
        end
        
        if 1 == jgus.vp_read(0x1060) then  -- 减
            if WeidMpaValue <= 0 then  -- 注意：这里原代码可能是笔误，应该检查WeidMpaValue
                WeidMpaValue = 0
            else
                WeidMpaValue = WeidMpaValue - 1
            end
        end
        
        TreatmentTable.FunctionKey = 6
        TreatmentTable.FunctionValue = WeidMpaValue
        jgus.vp_write(0x1160, TreatmentTable.FunctionValue)
        
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1060, 0)
    end
end

-- 手具页面初始值设置
local function ZhuangT_init()
    if 1 == PageID then  -- A面膜界面
        ModeValue = 1
        jgus.vp_write(0x1120, ModeValue)  -- 模式值默认1
        MpaValueA = 1
        jgus.vp_write(0x1140, MpaValueA)   -- 强度值默认1
        
        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        else
            NFC_ZhuanT = 1
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        end

        jgus.vp_write(0x1101, 0)          -- B界面状态显示
        jgus.vp_write(0x1102, 0)          -- C界面状态显示

        TreatmentTable.Minutes = 30       -- 分
        jgus.screen_set_page(1)           -- 显示A界面   
    
    elseif 2 == PageID then  -- B面部手具
        WeidModeValue = 1
        jgus.vp_write(0x1130, WeidModeValue)  -- 微电模式值默认1
        FareMpaValue = 1
        jgus.vp_write(0x1150, FareMpaValue)   -- 发热强度值默认1
        WeidMpaValue = 1
        jgus.vp_write(0x1160, WeidMpaValue)  -- 微电强度值默认1

        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        else
            NFC_ZhuanT = 0
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        end
        jgus.vp_write(0x1101, 1)          -- B界面状态显示
        jgus.vp_write(0x1102, 0)          -- C界面状态显示

        TreatmentTable.Minutes = 25       -- 分
        jgus.screen_set_page(2)           -- 显示B界面

    elseif 3 == PageID then  -- C负离子手具
        MpaValueC = 1
        jgus.vp_write(0x1170, MpaValueC)   -- 强度值默认1

        if NFC_ZhuanT == 2 then
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        else
            NFC_ZhuanT = 0
            jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        end
        jgus.vp_write(0x1101, 0)          -- B界面状态显示
        jgus.vp_write(0x1102, 1)          -- C界面状态显示

        TreatmentTable.Minutes = 25       -- 分
        jgus.screen_set_page(3)           -- 显示C界面
    end
end

-- 页面状态按键配置
local function ZhuangT_Key_Config()
    if 0 ~= jgus.vp_read(0x1015) then
        TreatmentTable.Screen = jgus.vp_read(0x1015)  -- 所在的页面号ID值
        PageID = TreatmentTable.Screen
        
        ZhuangT_init()  -- 手具页面初始值设置
        
        TreatmentTable.When = 0      -- 时
        TreatmentTable.Seconds = 0   -- 秒
        time_display()               -- 倒计时时间显示
        
        RunFlage = 0
        TreatmentTable.FunctionKey = 0xFF
        TreatmentTable.FunctionValue = 0xFF
        write_send_code()  -- 写数据传送
        jgus.vp_write(0x1015, 0)
    end

    if 1 == TreatmentTable.Screen then  -- A模式按键
        Countdown_Key_Config(1, 30)  -- 倒计时时间加减按键配置*
    elseif 2 == TreatmentTable.Screen then  -- B模式按键
        Countdown_Key_Config(1, 25)  -- 倒计时时间加减按键配置*
    elseif 3 == TreatmentTable.Screen then  -- C模式按键
        Countdown_Key_Config(1, 25)  -- 倒计时时间加减按键配置*
    end
end

-- 倒计时
local function Countdown()
    local ticks = 0
    
    if RunFlage == 1 then

        local seconds = ticks % 60 
        
        if 0 == TreatmentTable.Seconds then
            if 0 ~= TreatmentTable.Minutes then
                TreatmentTable.Seconds = 59
                TreatmentTable.Minutes = TreatmentTable.Minutes - 1
            else
                RunFlage = 2
                TreatmentTable.FunctionKey = 1     -- 所在页面功能控件号
                TreatmentTable.FunctionValue = RunFlage  -- 所在页面功能控件号的值
                if 4 == jgus.screen_get_page() then
                    jgus.screen_set_page(1)  -- 跳转到A界面
                    PageID = 1
                elseif 5 == jgus.screen_get_page() then
                    jgus.screen_set_page(2)  -- 跳转到B界面
                    PageID = 2
                elseif 6 == jgus.screen_get_page() then
                    jgus.screen_set_page(3)  -- 跳转到C界面
                    PageID = 3
                end
                ZhuangT_init()  -- 手具所在页面默认值配置
                write_send_code()    -- 写数据传送
                jgus.vp_write(0x00A0, 10)
            end
        else
            TreatmentTable.Seconds = TreatmentTable.Seconds - 1
        end

        time_display()

        --print(string.format("分:%d",TreatmentTable.Minutes))
        --print(string.format("秒:%d",TreatmentTable.Seconds))

        ticks = ticks + 1 
        -- sys.wait(1000)
        
    else
        if 0 ~= ticks then
            ticks = 0
        end
    end
end

-- 读配置信息
local function read_config(buf)
    TreatmentTable.Voice = buf[4]      -- 语音开关 (Lua索引从1开始)
    TreatmentTable.Language = buf[5]   -- 语言选择
    
    -- 读取当前页面的数据
    if buf[6] == 0 then
        TreatmentTable.FunctionKey = 0xFF    -- 所在页面功能控件号
        TreatmentTable.FunctionValue = 0xFF  -- 所在页面功能控件号的值
        TreatmentTable.When = 0     -- 时
        TreatmentTable.Minutes = 0  -- 分
        TreatmentTable.Seconds = 0  -- 秒
    elseif buf[6] > 0 or buf[6] < 4 then
        TreatmentTable.FunctionKey = buf[7]
        if TreatmentTable.FunctionKey == 1 then  -- 开始、停止
            TreatmentTable.FunctionValue = RunFlage  -- 控件号的值
        elseif TreatmentTable.FunctionKey == 2 then  -- 模式
            TreatmentTable.FunctionValue = ModeValue
        elseif TreatmentTable.FunctionKey == 3 then  -- 微电模式
            TreatmentTable.FunctionValue = WeidModeValue
        elseif TreatmentTable.FunctionKey == 4 then  -- 强度
            TreatmentTable.FunctionValue = MpaValue
        elseif TreatmentTable.FunctionKey == 5 then  -- 发热强度
            TreatmentTable.FunctionValue = FareMpaValue
        elseif TreatmentTable.FunctionKey == 6 then  -- 微电强度
            TreatmentTable.FunctionValue = WeidMpaValue
        elseif TreatmentTable.FunctionKey == 7 then  -- NFC刷卡状态
            TreatmentTable.FunctionValue = NFC_ZhuanT  
        else
            TreatmentTable.FunctionKey = 0
        end
    end
    read_send_code()  -- 读数据传送
end

-- 写配置信息
local function write_config(buf)
    TreatmentTable.Voice = buf[4]       -- 语音开关
    TreatmentTable.Language = buf[5]    -- 语言选择
    TreatmentTable.Screen = buf[6]      -- 所在功能页面号
    TreatmentTable.FunctionKey = buf[7]     -- 控件号
    TreatmentTable.FunctionValue = buf[8]   -- 控件号的值
    TreatmentTable.When = buf[9]        -- 时
    TreatmentTable.Minutes = buf[10]    -- 分
    TreatmentTable.Seconds = buf[11]    -- 秒

    if TreatmentTable.Screen == 1 then  -- A
        jgus.screen_set_page(1)

        if NFC_ZhuanT ~= 2 then
            NFC_ZhuanT = 1          -- A界面状态显示
        end
        
        jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        jgus.vp_write(0x1101, 0)          -- B界面状态显示
        jgus.vp_write(0x1102, 0)          -- C界面状态显示
    elseif TreatmentTable.Screen == 2 then  -- B
        jgus.screen_set_page(2)

        if NFC_ZhuanT ~= 2 then
            NFC_ZhuanT = 0          -- A界面状态显示
        end

        jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        jgus.vp_write(0x1101, 1)          -- B界面状态显示
        jgus.vp_write(0x1102, 0)          -- C界面状态显示
    elseif TreatmentTable.Screen == 3 then  -- C
        jgus.screen_set_page(3)
        
        if NFC_ZhuanT ~= 2 then
            NFC_ZhuanT = 0          -- A界面状态显示
        end

        jgus.vp_write(0x1100, NFC_ZhuanT)          -- A界面状态显示
        jgus.vp_write(0x1101, 0)          -- B界面状态显示
        jgus.vp_write(0x1102, 1)          -- C界面状态显示
    end
    --print(string.format("page_NFC:%d",NFC_ZhuanT))
    if TreatmentTable.FunctionKey == 1 then  -- 启停设置
        if TreatmentTable.FunctionValue == 1 then
            RunFlage = 1  -- 开始倒计时
            if TreatmentTable.Screen == 1 then  -- A
                jgus.screen_set_page(4)
            end
            if TreatmentTable.Screen == 2 then  -- B
                jgus.screen_set_page(5)
            end
            if TreatmentTable.Screen == 3 then  -- C
                jgus.screen_set_page(6)
            end
            
        elseif TreatmentTable.FunctionValue == 2 then
            RunFlage = 2  -- 停止倒计时
        end
    elseif TreatmentTable.FunctionKey == 2 then  -- 模式值设置
        ModeValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1120, ModeValue)
    elseif TreatmentTable.FunctionKey == 3 then  -- 微电模式值设置
        WeidModeValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1130, WeidModeValue)
    elseif TreatmentTable.FunctionKey == 4 then  -- 强度值设置
        if TreatmentTable.Screen == 1 then  -- A
            MpaValueA = TreatmentTable.FunctionValue
            jgus.vp_write(0x1140, MpaValueA)
        elseif TreatmentTable.Screen == 3 then  -- C
            MpaValueC = TreatmentTable.FunctionValue
            jgus.vp_write(0x1170, MpaValueC)
        end

    elseif TreatmentTable.FunctionKey == 5 then  -- 发热强度值设置
        FareMpaValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1150, FareMpaValue)
    elseif TreatmentTable.FunctionKey == 6 then  -- 微电强度值设置
        WeidMpaValue = TreatmentTable.FunctionValue
        jgus.vp_write(0x1160, WeidMpaValue)
    elseif TreatmentTable.FunctionKey == 7 then  -- A界面刷卡设置
        NFC_ZhuanT = TreatmentTable.FunctionValue
        if NFC_ZhuanT == 2 then            
            jgus.vp_write_data(Page1_KS,0x00B0, 4)     --允许开始按键触控     
        else
            jgus.vp_write_data(Page1_TZ,0x00B0, 4)      --禁止开始按键触控
        end
        jgus.vp_write(0x1100, NFC_ZhuanT)          -- 刷卡状态显示
    elseif TreatmentTable.FunctionKey == 8 then  -- ASCII码弹窗
        if TreatmentTable.FunctionValue == 1 then
            jgus.vp_write(0x00E8,0x5A01)
            jgus.vp_write(0x00E9,0x0007)
        else
            jgus.vp_write(0x00E8,0x0000)
        end
    end
    time_display()   -- 时间显示
end

--ASCII码显示处理
local function txt_command(buf)
    local DataBuf = {0}
    local i = 0
    local DatLen = 0

    print(string.format("buf[4]:%d buf[5]:%d", buf[4], buf[5]))
    DatLen = (buf[4] << 8) | buf[5]     -- 数据长度
    for i = 0, (DatLen/2)-1 do
        jgus.vp_write(0x2000 + i,((buf[6 + i*2] << 8) | buf[7 + i*2]))
        --jgus.vp_write_high_byte(0x2000 + i, buf[6 + i*2])
        --jgus.vp_write_low_byte(0x2000 + i,  buf[7 + i*2])
        DataBuf[i] = buf[6 + i]
        
        print(string.format("DatLen-i:%d", i))
        print(string.format("DatLen-i6:%02X", DataBuf[i]))
    end
    --jgus.vp_write_string(DataBuf, 0x2000, DatLen/2)
    --print(string.format("DatLen:%d", DatLen))
end


-- 用户开机初始化值
local function use_init()   
    TreatmentTable.Voice = 0      -- 语音
    TreatmentTable.Language = 0   -- 语言
    TreatmentTable.Screen = 1     -- 开机画面
    TreatmentTable.When = 0       -- 时
    TreatmentTable.Minutes = 30   -- 分
    TreatmentTable.Seconds = 0    -- 秒
    TreatmentTable.FunctionKey = 0xFF
    TreatmentTable.FunctionValue = 0xFF
    time_display()  -- 时间显示
    ModeValue = 1
    jgus.vp_write(0x1120, ModeValue)  -- 模式值默认1
    MpaValue = 1
    jgus.vp_write(0x1140, MpaValue)   -- 强度值默认1
    
    NFC_ZhuanT = 1
    jgus.vp_write(0x1100, NFC_ZhuanT)          -- 状态显示

    jgus.vp_write_data(Page1_TZ,0x00B0, 4)      --禁止开始按键触控

    write_send_code()  -- 写数据传送
    --print("用户初始化完成")
end

-- 处理串口数据的相关代码
local cmdbuf = {}
local cmdcount = 0
local cmdflags = 0

local function cus_command()
    local ret, data = uart.receive(uart_no, 1)  -- 修正为直接使用uart模块
    while ret > 0 do
        cmdbuf[cmdcount + 1] = string.byte(data)  -- Lua索引从1开始
        cmdcount = cmdcount + 1
        
        -- 简化的缓冲区溢出检查
        if cmdcount >= 256 then
            cmdcount = 0
            cmdflags = 0
            break
        end
        
        if 0x01 == cmdflags then
            if cmdcount == 13 then
                local value = Calculate_CRC16(cmdbuf, 11)
                -- 使用位运算操作符替代bit32模块
                if ((cmdbuf[12] == (value & 0xFF) and cmdbuf[13] == (value >> 8)) or
                    (cmdbuf[12] == (value >> 8) and cmdbuf[13] == (value & 0xFF))) then
                    
                    if cmdbuf[3] == 0xAF then  -- 读操作
                        read_config(cmdbuf)
                    elseif cmdbuf[3] == 0xFA then  -- 写操作
                        write_config(cmdbuf)
                        jgus.reg_write(0x02, 10)
                    end
                    
                    cmdcount = 0
                    cmdflags = 0
                end
            elseif cmdcount >= 206 then
                if cmdbuf[3] == 0x55 then   -- ASCII码显示
                    --print(string.format("cmdbuf[4]:%d cmdbuf[5]:%d", cmdbuf[4], cmdbuf[5]))

                    txt_command(cmdbuf)
                    jgus.reg_write(0x02, 10)

                    cmdcount = 0
                    cmdflags = 0
                end
            end
            --print(string.format("cmdcount:%d", cmdcount))
        else
            if (cmdcount == 2) and (cmdbuf[1] == 0xA5) and (cmdbuf[2] == 0x5A) then
                cmdflags = 0x01
            elseif (cmdcount == 1) and (cmdbuf[1] == 0xA5) then
                -- 继续等待
            else
                cmdcount = 0
            end
        end
        
        ret, data = uart.receive(uart_no, 1)  -- 保持一致使用uart模块
    end
end

use_init()

-- 任务
sys.taskInit(function()
    while true do

        --[[if NFC_ZhuanT == 2 then
            ZhuangT_Key_Config()         -- ⑦手具界面按键配置*
        end]]

        Switch_Key_Config()          -- ①开启、停止按键配置*
        ZhuangT_Key_Config()         -- ⑦手具界面按键配置*
        ModeValue_Key_Config()       -- ②模式按键加减配置*
        WeidModeValue_Key_Config()   -- ③微电模式按键加减配置*
        MpaValueA_Key_Config()       -- ④强度按键加减配置*
        MpaValueC_Key_Config()       -- ④强度按键加减配置*
        FareMpaValue_Key_Config()    -- ⑤发热强度按键加减配置*
        WeidMpaValue_Key_Config()    -- ⑥微电强度按键加减配置*
        
        cus_command()  -- 处理串口命令
		--print("Task")
        sys.wait(10)
    end
end)

sys.taskInit(function()
    while true do
        Countdown()                  -- 倒计时
        sys.wait(1000)
    end
end)


-- 启动调度器（需在另一个线程运行）
-- 这里简化为直接调用（实际应用需用 coroutine 或多线程）
sys.scheduler()