local parser = require 'parser'

local EXISTS = {}

local function eq(a, b)
    if a == EXISTS and b ~= nil then
        return true
    end
    local tp1, tp2 = type(a), type(b)
    if tp1 ~= tp2 then
        return false
    end
    if tp1 == 'table' then
        local mark = {}
        for k in pairs(a) do
            if not eq(a[k], b[k]) then
                return false
            end
            mark[k] = true
        end
        for k in pairs(b) do
            if not mark[k] then
                return false
            end
        end
        return true
    end
    return a == b
end

local function catchTarget(script, sep)
    local list = {}
    local cur = 1
    local cut = 0
    while true do
        local start, finish  = script:find(('<%%%s.-%%%s>'):format(sep, sep), cur)
        if not start then
            break
        end
        list[#list+1] = { start - cut, finish - 4 - cut }
        cur = finish + 1
        cut = cut + 4
    end
    local new_script = script:gsub(('<%%%s(.-)%%%s>'):format(sep, sep), '%1')
    return new_script, list
end

local function TEST(script)
    return function (expect)
        local newScript, list = catchTarget(script, '!')
        local ast, err = parser:ast(newScript)
        assert(ast)
        assert(err)
        local first = err[1]
        local target = list[1]
        assert(first)
        assert(first.type == expect.type)
        assert(first.start == target[1])
        assert(first.finish == target[2])
        assert(eq(first.info, expect.info))
    end
end

TEST[[
local<! !>
]]
{
    type = 'MISS_NAME',
}

TEST[[
<!？？？!>
]]
{
    type = 'UNKNOWN_SYMBOL',
    info = {
        symbol = '？？？',
    }
}
