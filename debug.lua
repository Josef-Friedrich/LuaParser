package.path = package.path .. ';/home/jf/Downloads/LuaParser/src/?.lua'
                            .. ';/home/jf/Downloads/LuaParser/src/?/init.lua'

local parser = require("parser")

local inspect = require('inspect')

print(inspect(parser.compile('---@meta\nlocal result = 1+2', 'Lua'))
)
