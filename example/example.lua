local pid = 121233
local address = 0x7ffcd98025e8

local value = mem.read_u32(pid, address)
print("value: " .. value)

mem.write_u32(pid, address, 33)
print("Value at address after write: " .. mem.read_u32(pid, address))