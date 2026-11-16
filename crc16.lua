local m_crc = {}

-- 异或 ^
local function bxor(a, b)
    local r = 0
    for i = 0, 31 do
        local x = ((a >> i) & 1) ~= ((b >> i) & 1)
        if x then r = r + (1 << i) end
    end
    return r
end

-- 按位或 |
function m_crc.bor(a, b)
    local result = 0
    local power_of_two = 1
    for i = 0, 31 do
        local bit_a = math.floor(a / power_of_two) % 2
        local bit_b = math.floor(b / power_of_two) % 2
        if bit_a == 1 or bit_b == 1 then
            result = result + power_of_two
        end
        power_of_two = power_of_two * 2
    end
    return result
end


-- 按位与 &
function m_crc.band(a, b)
    local result = 0
    local bit_mask = 1
    for i = 1, 16 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bit_mask
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit_mask = bit_mask * 2
    end
    return result
end

-- 右移 >>
function m_crc.rshift(a, n)
    return math.floor(a / (2 ^ n))
end

-- 左移 << 
function m_crc.lshift(a, n)
    return math.floor(a * (2 ^ n))
end

-- CRC16 校验算法
-- 入参传入字符串类型
function m_crc.check_crc16(data)
    local crc = 0xFFFF
    for i = 1, #data do
        local byte = string.byte(data, i)
        crc = bxor(crc, byte)

        for j = 1, 8 do
            if crc16.band(crc, 0x0001) ~= 0 then
                crc = crc16.rshift(crc, 1)
                crc = bxor(crc, 0xA001)
            else
                crc = crc16.rshift(crc, 1)
            end
        end
    end

    -- 返回低字节在前（Modbus 标准）
    return string.char(crc16.band(crc, 0xFF), crc16.rshift(crc, 8))
end


return m_crc