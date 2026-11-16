local m_modbus = {}

-- Modbus 接收状态机
m_modbus.recv_state = {
    idle = 0,
    receiving = 1,
}

-- 缓冲区初始化
m_modbus.buffer = ""
m_modbus.state = m_modbus.recv_state.idle
m_modbus.slave_id = nil
m_modbus.func_code = nil
m_modbus.expected_length = 0



-- 处理 Modbus 命令（可扩展）
-- local function m_modbus.handle_command(frame)
--     local func_code = string.byte(frame, 2)

--     if func_code == 0x03 or func_code == 0x04 then
--         -- 读保持寄存器或输入寄存器
--         local reg_hi = string.byte(frame, 3)
--         local reg_lo = string.byte(frame, 4)
--         local reg_start = reg_hi * 256 + reg_lo
--         local count_hi = string.byte(frame, 5)
--         local count_lo = string.byte(frame, 6)
--         local count = count_hi * 256 + count_lo

--         print(string.format("读取寄存器: 起始地址=0x%04X, 数量=%d", reg_start, count))

--         -- 构造响应帧
--         local response = string.char(
--             string.byte(frame, 1),   -- Slave ID
--             func_code,               -- Function code (使用实际功能码)
--             count * 2                -- Byte count
--         )
--         for i = 1, count do
--             local value = jgus.vp_read(reg_start + i - 1)
--             response = response .. string.char(crc16.rshift(value, 8), crc16.band(value, 0xFF))
--         end
--         response = response .. crc16.check_crc16(response)
--         uart.send(uart_no, response)

--     elseif func_code == 0x06 then
--         -- 写单个寄存器
--         local reg_hi = string.byte(frame, 3)
--         local reg_lo = string.byte(frame, 4)
--         local reg_addr = reg_hi * 256 + reg_lo
--         local val_hi = string.byte(frame, 5)
--         local val_lo = string.byte(frame, 6)
--         local value = val_hi * 256 + val_lo

--         print(string.format("写入寄存器: 地址=0x%04X, 值=0x%04X", reg_addr, value))
--         jgus.vp_write(reg_addr, value)

--         -- 返回原命令确认
--         uart.send(uart_no, string.sub(frame, 1, 6) .. crc16.check_crc16(string.sub(frame, 1, 6)))

--     elseif func_code == 0x10 then
--         -- 写多个寄存器
--         local reg_hi = string.byte(frame, 3)
--         local reg_lo = string.byte(frame, 4)
--         local reg_start = reg_hi * 256 + reg_lo
--         local count_hi = string.byte(frame, 5)
--         local count_lo = string.byte(frame, 6)
--         local count = count_hi * 256 + count_lo
--         local byte_count = string.byte(frame, 7)
--         local values = {}

--         for i = 1, byte_count, 2 do
--             local hi = string.byte(frame, 8 + i - 1)
--             local lo = string.byte(frame, 8 + i)
--             values[(i + 1) // 2] = hi * 256 + lo
--         end

--         print(string.format("写入多个寄存器: 起始地址=0x%04X, 数量=%d", reg_start, count))
--         for i = 1, count do
--             jgus.vp_write(reg_start + i - 1, values[i])
--         end

--         -- 返回原命令确认
--         local ack = string.char(
--             string.byte(frame, 1),
--             0x10,
--             reg_hi,
--             reg_lo,
--             count_hi,
--             count_lo
--         ) .. crc16.check_crc16(string.sub(frame, 1, 6))
--         uart.send(uart_no, ack)
--     end
-- end


-- Modbus从机响应数据解析函数
function m_modbus.parse_response(frame)
    if not frame or #frame < 3 then
        print("响应帧长度不足")
        return nil
    end
    
    local result = {}
    result.slave_id = string.byte(frame, 1)
    result.function_code = string.byte(frame, 2)
    
    -- 检查是否有异常响应
    if result.function_code > 0x80 then
        result.error = true
        result.exception_code = string.byte(frame, 3)
        print(string.format("Modbus异常响应: 从机ID=%d, 异常码=%d", result.slave_id, result.exception_code))
        return result
    end
    
    result.error = false
    
    if result.function_code == 0x01 or result.function_code == 0x02 then
        -- 读线圈状态/读离散输入状态
        local byte_count = string.byte(frame, 3)
        result.data = {}
        result.data_bytes = byte_count
        
        for i = 1, byte_count do
            local byte_val = string.byte(frame, 3 + i)
            -- 将每个字节的位转换为布尔值数组
            for j = 0, 7 do
                if #result.data < byte_count * 8 then
                    result.data[#result.data + 1] = crc16.band(crc16.rshift(byte_val, j), 1) == 1
                end
            end
        end
        
    elseif result.function_code == 0x03 or result.function_code == 0x04 then
        -- 读保持寄存器/读输入寄存器
        local byte_count = string.byte(frame, 3)
        result.data = {}
        result.data_bytes = byte_count
        result.register_count = byte_count / 2
        
        -- 解析寄存器值
        for i = 1, result.register_count do
            local hi_byte = string.byte(frame, 3 + (i - 1) * 2 + 1)
            local lo_byte = string.byte(frame, 3 + (i - 1) * 2 + 2)
            local register_value = hi_byte * 256 + lo_byte
            result.data[i] = register_value
        end
        
    elseif result.function_code == 0x05 then
        -- 写单个线圈
        local output_address_hi = string.byte(frame, 3)
        local output_address_lo = string.byte(frame, 4)
        local output_value_hi = string.byte(frame, 5)
        local output_value_lo = string.byte(frame, 6)
        
        result.output_address = output_address_hi * 256 + output_address_lo
        result.output_value = output_value_hi * 256 + output_value_lo
        result.coil_status = (result.output_value == 0xFF00)
        
    elseif result.function_code == 0x06 then
        -- 写单个寄存器
        local register_address_hi = string.byte(frame, 3)
        local register_address_lo = string.byte(frame, 4)
        local register_value_hi = string.byte(frame, 5)
        local register_value_lo = string.byte(frame, 6)
        
        result.register_address = register_address_hi * 256 + register_address_lo
        result.register_value = register_value_hi * 256 + register_value_lo
        
    elseif result.function_code == 0x0F then
        -- 写多个线圈
        local start_address_hi = string.byte(frame, 3)
        local start_address_lo = string.byte(frame, 4)
        local quantity_hi = string.byte(frame, 5)
        local quantity_lo = string.byte(frame, 6)
        
        result.start_address = start_address_hi * 256 + start_address_lo
        result.quantity = quantity_hi * 256 + quantity_lo
        
    elseif result.function_code == 0x10 then
        -- 写多个寄存器
        local start_address_hi = string.byte(frame, 3)
        local start_address_lo = string.byte(frame, 4)
        local quantity_hi = string.byte(frame, 5)
        local quantity_lo = string.byte(frame, 6)
        
        result.start_address = start_address_hi * 256 + start_address_lo
        result.quantity = quantity_hi * 256 + quantity_lo
        
    else
        print("不支持的响应功能码:", result.function_code)
        return nil
    end
    
    return result
end

-- 验证Modbus响应帧CRC的辅助函数
function m_modbus.verify_response_crc(frame)
    if not frame or #frame < 3 then
        return false
    end
    
    local received_crc = string.sub(frame, #frame - 1, #frame)
    local payload = string.sub(frame, 1, #frame - 2)
    local calc_crc = crc16.check_crc16(payload)
    
    return received_crc == calc_crc
end

-- 解析并处理响应的示例函数
function m_modbus.process_response(response_frame)
    -- 首先验证CRC
    -- if not m_modbus.verify_response_crc(response_frame) then
    --     print("响应CRC校验失败")
    --     return nil
    -- end
    
    -- 解析响应数据
    local parsed_data = m_modbus.parse_response(response_frame)
    if not parsed_data then
        print("响应解析失败")
        return nil
    end
    
    if parsed_data.error then
        print("从机返回异常:", parsed_data.exception_code)
        return parsed_data
    end
    
    -- 根据功能码处理数据
    -- if parsed_data.function_code == 0x03 or parsed_data.function_code == 0x04 then
    --     print(string.format("读取到%d个寄存器数据:", parsed_data.register_count))
    --     for i, value in ipairs(parsed_data.data) do
    --         print(string.format("  寄存器%d: 0x%04X (%d)", i-1, value, value))
    --     end
    -- elseif parsed_data.function_code == 0x01 or parsed_data.function_code == 0x02 then
    --     print(string.format("读取到%d个线圈/输入状态:", #parsed_data.data))
    --     for i, status in ipairs(parsed_data.data) do
    --         print(string.format("  位置%d: %s", i-1, status and "ON" or "OFF"))
    --     end
    -- else
    --     print("处理功能码", parsed_data.function_code, "的响应")
    -- end

    if parsed_data.function_code == 0x04 then  -- 判断输入寄存器状态
        -- 获取parsed_data.data第一个值
        local value = parsed_data.data[1]
        -- print("读取到的数据为:", value)
        if crc16.band(value, 0x07) > 0 then
            modbus.sendModbusCommand(1, 0x05, 0x0004, 0xFF00, {0})  -- 打开输出5
            if crc16.band(value, 0x01) == 1 then        -- 急停
                jgus.screen_set_page(11)
            elseif crc16.band(value, 0x02) == 2 and RuningState ~= 0 then    -- 枪头风扇异常
                jgus.screen_set_page(10)
            elseif crc16.band(value, 0x04) == 4 and RuningState ~= 0 then    -- 控制风量异常
                jgus.screen_set_page(12)
            end
            RuningState = 0
        else
            modbus.sendModbusCommand(1, 0x05, 0x0004, 0x0000, {0})  -- 关闭输出5
        end
    end
    
    return parsed_data
end

-- Modbus 协议解析主函数
function m_modbus.parse_modbus()
    local res, data = uart.receive(uart_no, 10)

    if res > 0 then
        m_modbus.buffer = m_modbus.buffer .. data

        while #m_modbus.buffer > 0 do
            if m_modbus.state == m_modbus.recv_state.idle then
                -- 等待第一个字节作为 slave ID
                if #m_modbus.buffer >= 1 then
                    m_modbus.slave_id = string.byte(m_modbus.buffer, 1)
                    m_modbus.state = m_modbus.recv_state.receiving
                    m_modbus.func_code = nil
                    m_modbus.expected_length = 0
                else
                    break
                end
            elseif m_modbus.state == m_modbus.recv_state.receiving then
                local len = #m_modbus.buffer

                -- 检查是否已经有功能码，如果没有则尝试获取
                if not m_modbus.func_code and len >= 2 then
                    m_modbus.func_code = string.byte(m_modbus.buffer, 2)
                    -- 判断功能码决定期望长度
                    if m_modbus.func_code == 0x03 or m_modbus.func_code == 0x04 then
                        -- 对于读寄存器功能码，先设置最小长度，后续根据实际数据字节数调整
                        m_modbus.expected_length = 5  -- 1byte(slave)+1(func)+1(data_bytes)+2(crc)
                    elseif m_modbus.func_code == 0x05 or m_modbus.func_code == 0x06 then
                        m_modbus.expected_length = 8  -- 写单个寄存器/线圈
                    end
                end

                -- 特殊处理0x10功能码，需要足够的数据才能确定帧长度
                if m_modbus.func_code == 0x10 and m_modbus.expected_length == 0 then
                    if len >= 7 then
                        local byte_count = string.byte(m_modbus.buffer, 7)
                        m_modbus.expected_length = 9 + byte_count  -- 写多个寄存器
                    else
                        -- 如果数据还不完整，等待更多数据
                        break
                    end
                end

                -- 对于0x03和0x04功能码，需要根据数据字节数重新计算期望长度
                if (m_modbus.func_code == 0x03 or m_modbus.func_code == 0x04) and 
                   m_modbus.expected_length == 5 and len >= 3 then
                    local data_bytes = string.byte(m_modbus.buffer, 3)
                    m_modbus.expected_length = 5 + data_bytes  -- 1(slave)+1(func)+1(count)+data_bytes+2(crc)
                end

                -- 检查是否收到完整帧
                if m_modbus.expected_length > 0 and len >= m_modbus.expected_length then
                    local frame = string.sub(m_modbus.buffer, 1, m_modbus.expected_length)
                    local received_crc = string.sub(frame, #frame - 1, #frame)
                    local payload = string.sub(frame, 1, #frame - 2)
                    local calc_crc = crc16.check_crc16(payload)

                    -- 以十六进制格式打印响应报文(测试用)
                    local hex_str = ""
                    for i = 1, #frame do
                        hex_str = hex_str .. string.format("%02X ", string.byte(frame, i))
                    end
                    -- print("接收到响应报文(HEX):", hex_str)
                    
                    if received_crc == calc_crc then
                        -- 校验成功，开始处理 Modbus 命令
                        m_modbus.process_response(frame)
                    else
                        print("CRC校验失败")
                        -- CRC校验失败时，尝试寻找下一个可能的帧头
                        local found_next_frame = false
                        for i = 2, len do
                            local potential_slave_id = string.byte(m_modbus.buffer, i)
                            if potential_slave_id >= 1 and potential_slave_id <= 247 then
                                if i + 1 <= len then
                                    local potential_func_code = string.byte(m_modbus.buffer, i + 1)
                                    if potential_func_code == 0x03 or potential_func_code == 0x04 or 
                                       potential_func_code == 0x05 or potential_func_code == 0x06 or 
                                       potential_func_code == 0x10 then
                                        m_modbus.buffer = string.sub(m_modbus.buffer, i)
                                        m_modbus.state = m_modbus.recv_state.idle
                                        m_modbus.func_code = nil
                                        m_modbus.expected_length = 0
                                        found_next_frame = true
                                        break
                                    end
                                end
                            end
                        end
                        
                        if not found_next_frame then
                            m_modbus.buffer = ""
                            m_modbus.state = m_modbus.recv_state.idle
                            m_modbus.func_code = nil
                            m_modbus.expected_length = 0
                        end
                        break
                    end

                    -- 从缓冲区中移除已处理的帧数据
                    m_modbus.buffer = string.sub(m_modbus.buffer, m_modbus.expected_length + 1)
                    
                    -- 重置状态以处理下一帧
                    m_modbus.state = m_modbus.recv_state.idle
                    m_modbus.func_code = nil
                    m_modbus.expected_length = 0
                else
                    break
                end
            end
        end
    end
end

-- 发送 Modbus 指令函数
function m_modbus.sendModbusCommand(slaveId, functionCode, startAddr, quantity, values)
    -- print("发送 Modbus 命令:", slaveId, functionCode, startAddr, quantity, values)
    local pdu = string.char(functionCode)
    if functionCode == 0x01 or functionCode == 0x02 or functionCode == 0x03 or 
       functionCode == 0x04 or functionCode == 0x05 or functionCode == 0x06 then
        -- 读取线圈、输入状态、保持寄存器、输入寄存器 或 写单个继电器、寄存器
        pdu = pdu .. string.char(crc16.rshift(startAddr, 8), crc16.band(startAddr, 0xFF))
        pdu = pdu .. string.char(crc16.rshift(quantity, 8), crc16.band(quantity, 0xFF))
    elseif functionCode == 0x0F or functionCode == 0x10 then
        -- 写多个继电器或寄存器
        pdu = pdu .. string.char(crc16.rshift(startAddr, 8), crc16.band(startAddr, 0xFF))
        pdu = pdu .. string.char(crc16.rshift(quantity, 8), crc16.band(quantity, 0xFF))

        if functionCode == 0x0F then
            -- 写多个线圈（按位）
            local byteCount = math.floor((#values + 7) / 8)
            pdu = pdu .. string.char(byteCount)

            for i = 1, byteCount do
                local byteVal = 0
                for j = 0, 7 do
                    if values[(i - 1)*8 + j + 1] then
                        byteVal = crc16.bor(byteVal, crc16.lshift(1, j))
                    end
                end
                pdu = pdu .. string.char(byteVal)
            end

        elseif functionCode == 0x10 then
            -- 写多个寄存器（每个寄存器 2 字节）
            local byteCount = #values * 2
            pdu = pdu .. string.char(byteCount)

            for i = 1, #values do
                local val = values[i]
                pdu = pdu .. string.char(
                    crc16.rshift(val, 8),  -- 高字节
                    crc16.band(val, 0xFF)   -- 低字节
                )
            end
        end
    end
    
    local adu = string.char(slaveId) .. pdu .. crc16.check_crc16(string.char(slaveId) .. pdu)
    uart.send(uart_no, adu)
end

-- 启动 Modbus 接收任务
function m_modbus.start_modbus_task()
    sys.taskInit(function()
        while true do
            m_modbus.parse_modbus()
            sys.wait(10)
        end
    end)
end

return m_modbus