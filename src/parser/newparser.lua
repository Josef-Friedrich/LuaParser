local sbyte     = string.byte
local sfind     = string.find
local smatch    = string.match
local sgsub     = string.gsub
local ssub      = string.sub
local schar     = string.char
local tconcat   = table.concat
local tointeger = math.tointeger

---@alias parser.position integer

---@param str string
---@return table<integer, boolean>
local function stringToByteMap(str)
    local map = {}
    local pos = 1
    while pos <= #str do
        local byte = sbyte(str, pos, pos)
        map[byte] = true
        pos = pos + 1
        if ssub(str, pos, pos) == '-' then
            pos = pos + 1
            local byte2 = sbyte(str, pos, pos)
            assert(byte < byte2)
            for b = byte + 1, byte2 do
                map[b] = true
            end
            pos = pos + 1
        end
    end
    return map
end

---@param str string
---@return table<integer, boolean>
local function stringToCharMap(str)
    local map = {}
    local pos = 1
    while pos <= #str do
        local byte = sbyte(str, pos, pos)
        map[schar(byte)] = true
        pos = pos + 1
        if ssub(str, pos, pos) == '-' then
            pos = pos + 1
            local byte2 = sbyte(str, pos, pos)
            assert(byte < byte2)
            for b = byte + 1, byte2 do
                map[schar(b)] = true
            end
            pos = pos + 1
        end
    end
    return map
end

local ByteMapSP      = stringToByteMap ' \t'
local ByteMapNL      = stringToByteMap '\r\n'
local ByteMapWordH   = stringToByteMap 'a-zA-Z\x80-\xff_'
local ByteMapWordT   = stringToByteMap 'a-zA-Z0-9\x80-\xff_'
local ByteMapStrSH   = stringToByteMap '\'"'
local ByteMapStrLH   = stringToByteMap '['
local ByteBLR        = sbyte '\r'
local ByteBLN        = sbyte '\n'

local CharMapNumber  = stringToCharMap '0-9'

local EscMap = {
    ['a'] = '\a',
    ['b'] = '\b',
    ['f'] = '\f',
    ['n'] = '\n',
    ['r'] = '\r',
    ['t'] = '\t',
    ['v'] = '\v',
}

local LineMulti      = 10000

local State, Lua, LuaOffset, Line, LineOffset

local CachedByte, CachedByteOffset
local function getByte(offset)
    if not offset then
        offset = LuaOffset
    end
    if CachedByteOffset ~= offset then
        CachedByteOffset = offset
        CachedByte = sbyte(Lua, offset, offset)
    end
    return CachedByte
end

local CachedChar, CachedCharOffset
local function getChar(offset)
    if not offset then
        offset = LuaOffset
    end
    if CachedCharOffset ~= offset then
        CachedCharOffset = offset
        CachedChar = ssub(Lua, offset, offset)
    end
    return CachedChar
end

---@param offset integer
---@param leftOrRight '"left"'|'"right"'
local function getPosition(offset, leftOrRight)
    if leftOrRight == 'left' then
        return LineMulti * Line + offset - LineOffset
    else
        return LineMulti * Line + offset - LineOffset + 1
    end
end

---@return string          word
---@return parser.position startPosition
---@return parser.position finishPosition
---@return integer         newOffset
local function peekWord()
    local start, finish, word = sfind(Lua
        , '^([%a_\x80-\xff][%w_\x80-\xff]*)'
        , LuaOffset
    )
    if not finish then
        return nil
    end
    local startPos  = getPosition(start , 'left')
    local finishPos = getPosition(finish, 'right')
    return word, startPos, finishPos, finish + 1
end

local function skipNL()
    local b = getByte()
    if not ByteMapNL[b] then
        return false
    end
    LuaOffset = LuaOffset + 1
    -- \r\n ?
    if b == ByteBLR then
        local nb = getByte()
        if nb == ByteBLN then
            LuaOffset = LuaOffset + 1
        end
    end
    Line       = Line + 1
    LineOffset = LuaOffset
    return true
end

local function skipSpace()
    ::AGAIN::
    if skipNL() then
        goto AGAIN
    end
    local offset = sfind(Lua, '[^ \t]', LuaOffset)
    if not offset then
        return
    end
    if offset > LuaOffset then
        LuaOffset = offset
        goto AGAIN
    end
end

local function parseNil(parent)
    skipSpace()
    local word, start, finish, newOffset = peekWord()
    if word ~= 'nil' then
        return nil
    end
    LuaOffset = newOffset
    return {
        type   = 'nil',
        start  = start,
        finish = finish,
        parent = parent,
    }
end

local function parseBoolean(parent)
    skipSpace()
    local word, start, finish, newOffset = peekWord()
    if  word ~= 'true'
    and word ~= 'false' then
        return nil
    end
    LuaOffset = newOffset
    return {
        type   = 'boolean',
        start  = start,
        finish = finish,
        parent = parent,
        [1]    = word == 'true' and true or false,
    }
end

local stringPool = {}
local function parseShotString(parent)
    local mark = getChar()
    local start = LuaOffset
    local pattern
    if mark == '"' then
        pattern = '(["\r\n\\])'
    else
        pattern = "(['\r\n\\])"
    end
    LuaOffset = LuaOffset + 1
    local offset, _, char = sfind(Lua, pattern, LuaOffset)
    -- simple string
    if char == mark then
        return {
            type   = 'string',
            start  = getPosition(start , 'left'),
            finish = getPosition(offset, 'right'),
            parent = parent,
            [1]    = ssub(Lua, start + 1, offset - 1),
            [2]    = mark,
        }
    end
    local startPos = getPosition(start , 'left')
    local stringResult
    local stringIndex = 1
    while true do
        stringPool[stringIndex] = ssub(Lua, LuaOffset, offset - 1)
        stringIndex = stringIndex + 1
        if     char == '\\' then
            local nextChar = getChar(offset + 1)
            if EscMap[nextChar] then
                LuaOffset = offset + 2
                stringPool[stringIndex] = EscMap[nextChar]
                stringIndex = stringIndex + 1
            elseif nextChar == mark then
                LuaOffset = offset + 2
                stringPool[stringIndex] = nextChar
                stringIndex = stringIndex + 1
            elseif nextChar == 'z' then
                LuaOffset = offset + 2
                skipSpace()
            elseif CharMapNumber[nextChar] then
                local numbers = smatch(Lua, '%d+', offset + 1)
                if #numbers > 3 then
                    numbers = ssub(numbers, 1, 3)
                end
                LuaOffset = offset + #numbers + 1
                local byte = tointeger(numbers)
                stringPool[stringIndex] = schar(byte)
                stringIndex = stringIndex + 1
            else
                LuaOffset = offset + 2
            end
        elseif char == mark then
            stringResult = tconcat(stringPool, '', 1, stringIndex - 1)
            LuaOffset = offset + 1
            break
        end
        offset, _, char = sfind(Lua, pattern, LuaOffset)
        if not char then
            stringPool[stringIndex] = ssub(Lua, LuaOffset)
            stringResult = tconcat(stringPool, '', 1, stringIndex)
            LuaOffset = offset + 1
            break
        end
    end
    return {
        type   = 'string',
        start  = startPos,
        finish = getPosition(LuaOffset - 1, 'right'),
        parent = parent,
        [1]    = stringResult,
        [2]    = mark,
    }
end

local function parseLongString(parent)
    local start, finish, mark = sfind(Lua, '(%[%=*%[)', LuaOffset)
    if not mark then
        return nil
    end
    local startPos = getPosition(start, 'left')
    LuaOffset = finish + 1
    skipNL()
    local finishMark = sgsub(mark, '%[', ']')
    local stringResult
    local stringIndex = 1
    while true do
        local offset, _, char = sfind(Lua, '([\r\n%]])', LuaOffset)
        if not char then
            stringPool[stringIndex] = ssub(Lua, LuaOffset)
            stringResult = tconcat(stringPool, '', 1, stringIndex)
            LuaOffset = #Lua + 1
            break
        end
        stringPool[stringIndex] = ssub(Lua, LuaOffset, offset - 1)
        stringIndex = stringIndex + 1
        if char == '\r'
        or char == '\n' then
            LuaOffset = offset
            skipNL()
            stringPool[stringIndex] = '\n'
            stringIndex = stringIndex + 1
        else
            local markFinishOffset = offset + #finishMark - 1
            if ssub(Lua, offset, markFinishOffset) == finishMark then
                stringResult = tconcat(stringPool, '', 1, stringIndex - 1)
                LuaOffset = markFinishOffset + 1
                break
            else
                stringPool[stringIndex] = ']'
                stringIndex = stringIndex + 1
                LuaOffset   = offset + 1
            end
        end
    end
    return {
        type   = 'string',
        start  = startPos,
        finish = getPosition(LuaOffset - 1, 'right'),
        parent = parent,
        [1]    = stringResult,
        [2]    = mark,
    }
end

local function parseString(parent)
    skipSpace()
    local b = getByte()
    if ByteMapStrSH[b] then
        return parseShotString(parent)
    end
    if ByteMapStrLH[b] then
        return parseLongString(parent)
    end
    return nil
end

local function initState(lua, version, options)
    Lua        = lua
    LuaOffset  = 1
    Line       = 0
    LineOffset = 1
    CachedByteOffset = nil
    CachedCharOffset = nil
    State = {
        version = version,
        lua     = lua,
        ast     = {},
        errs    = {},
        diags   = {},
        comms   = {},
        options = options or {},
    }
    if version == 'Lua 5.1' or version == 'LuaJIT' then
        State.ENVMode = '@fenv'
    else
        State.ENVMode = '_ENV'
    end
end

return function (lua, mode, version, options)
    initState(lua, version, options)
    if     mode == 'Lua' then
    elseif mode == 'Nil' then
        State.ast = parseNil()
    elseif mode == 'Boolean' then
        State.ast = parseBoolean()
    elseif mode == 'String' then
        State.ast = parseString()
    end
    return State
end
