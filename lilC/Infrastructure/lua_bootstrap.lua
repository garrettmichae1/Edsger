local write, read, path, load_file = _lilc_write, _lilc_read, _lilc_path, _lilc_load
local open, lines = io.open, io.lines
function print(...)
    local values = {}
    for i = 1, select('#', ...) do values[i] = tostring(select(i, ...)) end
    write(table.concat(values, '\t') .. '\n')
end
function io.write(...)
    for i = 1, select('#', ...) do write(tostring(select(i, ...))) end
    return io.stdout
end
local pending, eof = '', false
local function read_format(format)
    format = format or '*l'
    if format == '*a' or format == 'a' then
        local result = pending; pending = ''
        while not eof do local line = read(); if line then result = result .. line else eof = true end end
        return result
    end
    if type(format) == 'number' then
        assert(format >= 0, 'read size must be non-negative')
        while #pending < format and not eof do local line=read(); if line then pending=pending..line else eof=true end end
        if pending == '' and eof and format > 0 then return nil end
        local result=pending:sub(1,format); pending=pending:sub(format+1); return result
    end
    if pending == '' and not eof then pending=read(); if not pending then eof=true; pending='' end end
    if pending == '' and eof then return nil end
    if format == '*n' or format == 'n' then
        while pending:match('^%s*$') and not eof do pending=read(); if not pending then eof=true; pending='' end end
        local token, rest = pending:match('^%s*([%+%-]?[%d%.]+[eE]?[%+%-]?%d*)(.*)$')
        if not token then return nil end
        pending=rest; return tonumber(token)
    end
    assert(format == '*l' or format == 'l' or format == '*L' or format == 'L', 'unsupported read format')
    local value=pending; pending=''
    if format == '*l' or format == 'l' then value=value:gsub('\n$',''):gsub('\r$','') end
    return value
end
function io.read(...)
    if select('#',...) == 0 then return read_format() end
    local result={}; local count=0
    for i=1,select('#',...) do count=i; result[i]=read_format(select(i,...)); if result[i]==nil then break end end
    return table.unpack(result,1,count)
end
function io.open(name, mode) return open(path(name), mode or 'r') end
function io.lines(name, ...)
    if name then return lines(path(name), ...) end
    return function() return io.read() end
end
function io.flush() return true end
io.stdin = {read=function(_,...) return io.read(...) end, lines=function() return io.lines() end}
io.stdout = {write=function(_,...) return io.write(...) end, flush=io.flush}
io.stderr = io.stdout
local close=io.close
function io.close(file) if file == nil or file == io.stdout or file == io.stderr or file == io.stdin then return true end; return close(file) end
for _,name in ipairs({"execute","exit","getenv","setlocale","remove","rename","tmpname"}) do os[name]=nil end
io.popen=nil; io.tmpfile=nil; io.input=nil; io.output=nil
function loadfile(name) return load_file(name) end
function dofile(name) return load_file(name)() end
local original_load=load
function load(source,name,mode,env) return original_load(source,name,'t',env or _G) end
local loaded = {os=os,io=io,math=math,string=string,table=table,utf8=utf8,coroutine=coroutine,_G=_G}
local loading = {}
function require(name)
    if loaded[name] ~= nil then return loaded[name] end
    assert(type(name)=='string' and name:match('^[%w_%.%-]+$') and not name:find('..',1,true), 'Use a local Lua module name')
    assert(not loading[name], 'circular module import: '..name)
    local filename=name:gsub('%.','/')..'.lua'
    local ok, chunk=pcall(load_file,filename)
    if not ok then chunk=load_file(name:gsub('%.','/')..'/init.lua') end
    loading[name]=true
    local ok,result=pcall(chunk,name,filename); loading[name]=nil
    if not ok then error(result,2) end
    if result==nil then result=true end
    loaded[name]=result; return result
end
_lilc_write=nil; _lilc_read=nil; _lilc_path=nil; _lilc_load=nil
