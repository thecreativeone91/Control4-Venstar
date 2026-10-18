--[[
  Venstar Thermostat (Local API) for Control4
  Proxy: thermostatV2 (binding 5001)

  Talks directly to the thermostat's Local API (HTTP or HTTPS, optional
  Digest authentication and screen-lock PIN). No cloud dependency.

  Venstar API rules this driver follows (from developer.venstar.com and the
  venstarcolortouch library used by Home Assistant):
    * /control is form-encoded. Legal combinations are:
        fan only | heattemp + cooltemp | mode + heattemp + cooltemp
      Setpoint-only POSTs and mode POSTs are therefore always separate.
    * cooltemp must be >= heattemp + setpointdelta.
    * Away cannot be set while the schedule is running, and the schedule
      cannot be enabled while Away is on.
    * The thermostat cannot handle concurrent requests: every request is
      serialized through one queue with a small gap between requests.
    * T2xxx/T3xxx firmware older than 5.28 report temperatures in Celsius
      regardless of the display units.
]]

DRIVER_VERSION = "1.1.0"

local PROXY_BINDING = 5001
local TEMP_OUT_BINDING = 5010
local HUM_OUT_BINDING = 5011
local OUTDOOR_OUT_BINDING = 5012

local REQUEST_GAP_MS = 400        -- pause between serialized requests
local REQUEST_TIMEOUT_S = 8
local SETPOINT_DEBOUNCE_MS = 700  -- coalesces rapid +/- taps into one POST
local REFRESH_AFTER_CMD_MS = 1500
local FAILS_BEFORE_OFFLINE = 3
local ALERT_POLL_EVERY = 4        -- alerts polled every Nth cycle
local API_POLL_EVERY = 120        -- re-read model/firmware every Nth cycle
local DEBUG_AUTO_OFF_MS = 6 * 60 * 60 * 1000

-------------------------------------------------------------------------------
-- Logging
-------------------------------------------------------------------------------

local LOG_LEVEL = 3
local LOG_PRINT = false
local LOG_FILE = false
local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG", "TRACE" }

local function log(level, fmt, ...)
  if level > LOG_LEVEL and level > 1 then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  msg = "[Venstar " .. (LEVEL_NAMES[level] or "?") .. "] " .. msg
  if level == 1 then
    if C4.ErrorLog then pcall(C4.ErrorLog, C4, msg) end
  end
  if level <= LOG_LEVEL then
    if LOG_PRINT then print(msg) end
    if LOG_FILE and C4.DebugLog then pcall(C4.DebugLog, C4, msg) end
  end
end

local function logError(...) log(1, ...) end
local function logWarn(...) log(2, ...) end
local function logInfo(...) log(3, ...) end
local function logDebug(...) log(4, ...) end
local function logTrace(...) log(5, ...) end

-------------------------------------------------------------------------------
-- Minimal JSON decoder (self-contained, Lua 5.1)
-------------------------------------------------------------------------------

local Json = {}

do
  local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

  local function skip(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
  end

  local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
      return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end

  local parseValue

  local function parseString(s, i)
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == "" then error("unterminated string") end
      if c == '"' then return table.concat(out), j + 1 end
      if c == "\\" then
        local n = s:sub(j + 1, j + 1)
        if n == "u" then
          local hex = s:sub(j + 2, j + 5)
          out[#out + 1] = utf8char(tonumber(hex, 16) or 63)
          j = j + 6
        else
          out[#out + 1] = escapes[n] or n
          j = j + 2
        end
      else
        out[#out + 1] = c
        j = j + 1
      end
    end
  end

  local function parseNumber(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("bad number at " .. i) end
    return tonumber(num), i + #num
  end

  local function parseArray(s, i)
    local arr = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = parseValue(s, i)
      arr[#arr + 1] = v
      i = skip(s, i)
      local c = s:sub(i, i)
      if c == "]" then return arr, i + 1 end
      if c ~= "," then error("expected , or ] at " .. i) end
      i = skip(s, i + 1)
    end
  end

  local function parseObject(s, i)
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then error("expected key at " .. i) end
      local k
      k, i = parseString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
      local v
      v, i = parseValue(s, skip(s, i + 1))
      obj[k] = v
      i = skip(s, i)
      local c = s:sub(i, i)
      if c == "}" then return obj, i + 1 end
      if c ~= "," then error("expected , or } at " .. i) end
      i = skip(s, i + 1)
    end
  end

  parseValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then return parseObject(s, i) end
    if c == "[" then return parseArray(s, i) end
    if c == '"' then return parseString(s, i) end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    return parseNumber(s, i)
  end

  function Json.decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    local ok, v = pcall(parseValue, s, 1)
    if not ok then return nil, v end
    return v
  end

  local function encodeValue(v, out)
    local t = type(v)
    if t == "table" then
      if #v > 0 or next(v) == nil then
        out[#out + 1] = "["
        for i, x in ipairs(v) do
          if i > 1 then out[#out + 1] = "," end
          encodeValue(x, out)
        end
        out[#out + 1] = "]"
      else
        out[#out + 1] = "{"
        local first = true
        for k, x in pairs(v) do
          if not first then out[#out + 1] = "," end
          first = false
          encodeValue(tostring(k), out)
          out[#out + 1] = ":"
          encodeValue(x, out)
        end
        out[#out + 1] = "}"
      end
    elseif t == "string" then
      out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
        return string.format("\\u%04x", c:byte())
      end) .. '"'
    elseif t == "number" or t == "boolean" then
      out[#out + 1] = tostring(v)
    else
      out[#out + 1] = "null"
    end
  end

  function Json.encode(v)
    local out = {}
    encodeValue(v, out)
    return table.concat(out)
  end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function round(v, places)
  local m = 10 ^ (places or 0)
  return math.floor(v * m + 0.5) / m
end

local function roundHalf(v)
  return math.floor(v * 2 + 0.5) / 2
end

local function f2c(f) return (f - 32) * 5 / 9 end
local function c2f(c) return c * 9 / 5 + 32 end

local function fmtNum(v)
  if v == nil then return "" end
  if v == math.floor(v) then return string.format("%d", v) end
  return string.format("%.1f", v)
end

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function formEncode(t, order)
  local parts = {}
  for _, k in ipairs(order) do
    if t[k] ~= nil then
      local v = t[k]
      if type(v) == "number" then v = fmtNum(v) end
      parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v)
    end
  end
  return table.concat(parts, "&")
end

local function num(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  if type(v) == "boolean" then return v and 1 or 0 end
  return nil
end

local function headerValue(headers, name)
  if type(headers) ~= "table" then return nil end
  local want = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == want then
      if type(v) == "table" then return v[1] end
      return v
    end
  end
  return nil
end

local function persistGet(key)
  if C4.PersistGetValue then
    local ok, v = pcall(C4.PersistGetValue, C4, key)
    if ok then return v end
  end
  PersistData = PersistData or {}
  return PersistData[key]
end

local function persistSet(key, value)
  if C4.PersistSetValue then
    if pcall(C4.PersistSetValue, C4, key, value) then return end
  end
  PersistData = PersistData or {}
  PersistData[key] = value
end

local function setTimer(ms, fn, rep)
  return C4:SetTimer(ms, function(timer, skips)
    local ok, err = pcall(fn, timer, skips)
    if not ok then logError("Timer callback error: %s", tostring(err)) end
  end, rep and true or false)
end

local function cancelTimer(t)
  if t and t.Cancel then pcall(t.Cancel, t) end
  return nil
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local S = {
  api = nil,            -- response of GET /
  info = nil,           -- response of GET /query/info
  sensors = nil,        -- array from /query/sensors
  alerts = nil,         -- map name -> bool
  units = "F",          -- units the API uses for temperatures ("F" or "C")
  displayScale = nil,   -- scale Navigator shows ("F" or "C")
  connected = nil,      -- nil until the first result
  failCount = 0,
  pollCount = 0,
  cmdSeq = 0,           -- bumped whenever a command is queued
  sent = {},            -- last notify per key, to avoid flooding the proxy
  propCache = {},
  capsSignature = nil,
  indoorTemp = nil,
  humidity = nil,
  outdoorTemp = nil,
  pollTimer = nil,
  debugTimer = nil,
}

local function isResidential()
  return not (S.api and tostring(S.api.type or ""):lower() == "commercial")
end

local function apiVer()
  return S.api and num(S.api.api_ver) or nil
end

local function setProp(name, value)
  value = tostring(value == nil and "" or value)
  if S.propCache[name] == value then return end
  S.propCache[name] = value
  C4:UpdateProperty(name, value)
end

local function notify(cmd, params, key)
  key = key or cmd
  local sig = cmd .. "|" .. Json.encode(params or {})
  if S.sent[key] == sig then return end
  S.sent[key] = sig
  logTrace("NOTIFY %s %s", cmd, sig)
  C4:SendToProxy(PROXY_BINDING, cmd, params or {}, "NOTIFY")
end

local function forgetNotifications()
  S.sent = {}
  S.capsSignature = nil
  S.extrasSetupSig, S.extrasStateSig = nil, nil
end

local VARS = {}
local function setVar(name, value, varType)
  value = tostring(value == nil and "" or value)
  if VARS[name] == nil then
    pcall(C4.AddVariable, C4, name, value, varType or "STRING", true, false)
    VARS[name] = value
    return
  end
  if VARS[name] ~= value then
    VARS[name] = value
    pcall(C4.SetVariable, C4, name, value)
  end
end

local function fireEvent(name)
  logInfo("Event: %s", name)
  pcall(C4.FireEvent, C4, name)
end

-------------------------------------------------------------------------------
-- HTTP layer: one request at a time, digest auth, PIN
-------------------------------------------------------------------------------

local Http = { queue = {}, busy = false, auth = nil, nc = 0 }

local function md5hex(s)
  local raw = C4:Hash("MD5", s, { return_encoding = "NONE", data_encoding = "NONE" })
  raw = tostring(raw or "")
  if #raw == 32 and raw:match("^%x+$") then return raw:lower() end
  return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function parseChallenge(h)
  if type(h) ~= "string" then return nil end
  local scheme, rest = h:match("^%s*(%a+)%s+(.*)$")
  if not scheme then return nil end
  local c = { scheme = scheme:lower() }
  for k, v in rest:gmatch('([%w_%-]+)%s*=%s*"([^"]*)"') do c[k:lower()] = v end
  for k, v in rest:gmatch('([%w_%-]+)%s*=%s*([^",%s]+)') do
    if c[k:lower()] == nil then c[k:lower()] = v end
  end
  return c
end

local function randomHex(n)
  local t = {}
  for i = 1, n do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end

local function authHeader(method, uri)
  local a = Http.auth
  local user = trim(Properties["Username"])
  local pass = Properties["Password"] or ""
  if not a or user == "" then return nil end
  if a.scheme == "basic" then
    return "Basic " .. C4:Base64Encode(user .. ":" .. pass)
  end
  if a.scheme ~= "digest" then return nil end
  Http.nc = Http.nc + 1
  local nc = string.format("%08x", Http.nc)
  local cnonce = randomHex(16)
  local ha1 = md5hex(user .. ":" .. (a.realm or "") .. ":" .. pass)
  if (a.algorithm or ""):upper() == "MD5-SESS" then
    ha1 = md5hex(ha1 .. ":" .. (a.nonce or "") .. ":" .. cnonce)
  end
  local ha2 = md5hex(method .. ":" .. uri)
  local qop = nil
  if a.qop then
    for q in a.qop:gmatch("[^,%s]+") do
      if q == "auth" then qop = "auth" end
    end
  end
  local response
  if qop then
    response = md5hex(ha1 .. ":" .. a.nonce .. ":" .. nc .. ":" .. cnonce .. ":" .. qop .. ":" .. ha2)
  else
    response = md5hex(ha1 .. ":" .. (a.nonce or "") .. ":" .. ha2)
  end
  local parts = {
    string.format('username="%s"', user),
    string.format('realm="%s"', a.realm or ""),
    string.format('nonce="%s"', a.nonce or ""),
    string.format('uri="%s"', uri),
    string.format('response="%s"', response),
  }
  if a.algorithm then parts[#parts + 1] = "algorithm=" .. a.algorithm end
  if a.opaque then parts[#parts + 1] = string.format('opaque="%s"', a.opaque) end
  if qop then
    parts[#parts + 1] = "qop=" .. qop
    parts[#parts + 1] = "nc=" .. nc
    parts[#parts + 1] = string.format('cnonce="%s"', cnonce)
  end
  return "Digest " .. table.concat(parts, ", ")
end

local function isConfigured()
  return trim(Properties["IP Address"]) ~= ""
end

local onRequestSuccess, onRequestFailure -- forward declarations

--- Priority requests (commands, post-command refreshes) jump ahead of queued
--- polls but stay in FIFO order among themselves, so a setpoint POST queued
--- before a mode POST is still sent first.
function Http.enqueue(req, priority)
  req.method = req.method or "GET"
  req.priority = priority and true or false
  if priority then
    local pos = 1
    for i, r in ipairs(Http.queue) do
      if r.priority then pos = i + 1 end
    end
    table.insert(Http.queue, pos, req)
  else
    table.insert(Http.queue, req)
  end
  Http.pump()
end

function Http.hasQueued(kind)
  for _, r in ipairs(Http.queue) do
    if r.kind == kind then return true end
  end
  return false
end

function Http.clear()
  Http.queue = {}
end

function Http.pump()
  if Http.busy or #Http.queue == 0 then return end
  if not isConfigured() then
    Http.queue = {}
    return
  end
  Http.busy = true
  local req = table.remove(Http.queue, 1)
  req.seqAtSend = S.cmdSeq
  local ok, err = pcall(Http.send, req, false)
  if not ok then
    logError("Request error: %s", tostring(err))
    Http.finish(req, nil, tostring(err))
  end
end

function Http.finish(req, data, err)
  Http.busy = false
  if err then
    onRequestFailure(req, err)
  else
    onRequestSuccess(req)
  end
  if req.cb then
    local ok, cbErr = pcall(req.cb, data, err, req)
    if not ok then logError("Handler error for %s: %s", req.path, tostring(cbErr)) end
  end
  setTimer(REQUEST_GAP_MS, function() Http.pump() end)
end

function Http.send(req, isRetry)
  local host = trim(Properties["IP Address"])
  local https = Properties["Use HTTPS"] == "Yes"
  local scheme = https and "https" or "http"
  local uri = req.path
  local pin = trim(Properties["Screen Lock PIN"])
  if pin ~= "" then
    if #pin < 4 and pin:match("^%d+$") then pin = string.rep("0", 4 - #pin) .. pin end
    uri = uri .. (uri:find("?", 1, true) and "&" or "?") .. "pin=" .. urlEncode(pin)
  end
  local url = scheme .. "://" .. host .. uri
  local headers = { ["Accept"] = "application/json" }
  if req.method == "POST" then
    headers["Content-Type"] = "application/x-www-form-urlencoded"
  end
  local auth = authHeader(req.method, uri)
  if auth then headers["Authorization"] = auth end

  logDebug("%s %s %s", req.method, scheme .. "://" .. host .. req.path, req.body or "")

  local t = C4:url()
  t:SetOptions({
    fail_on_error = false,
    timeout = REQUEST_TIMEOUT_S,
    connect_timeout = 5,
    ssl_verify_host = false,
    ssl_verify_peer = false,
  })
  t:OnDone(function(transfer, responses, errCode, errMsg)
    if errCode ~= 0 or type(responses) ~= "table" or #responses == 0 then
      Http.finish(req, nil, errMsg or ("transfer error " .. tostring(errCode)))
      return
    end
    local r = responses[#responses]
    local code = tonumber(r.code) or 0
    if code == 401 then
      local challenge = parseChallenge(headerValue(r.headers, "WWW-Authenticate"))
      if trim(Properties["Username"]) == "" then
        Http.finish(req, nil, "HTTP 401: thermostat requires a username and password")
        return
      end
      if not isRetry and challenge then
        Http.auth = challenge
        Http.nc = 0
        local ok, err = pcall(Http.send, req, true)
        if not ok then Http.finish(req, nil, tostring(err)) end
        return
      end
      Http.finish(req, nil, "HTTP 401: authentication rejected (check username/password)")
      return
    end
    if code < 200 or code >= 300 then
      Http.finish(req, nil, "HTTP " .. code)
      return
    end
    local data, jerr = Json.decode(r.body or "")
    if data == nil then
      Http.finish(req, nil, "invalid JSON: " .. tostring(jerr) .. " body=" .. tostring(r.body):sub(1, 120))
      return
    end
    logTrace("Response %s: %s", req.path, tostring(r.body))
    if req.method == "POST" and type(data) == "table" and data.error then
      -- The thermostat answered; the command itself was refused.
      Http.busy = false
      onRequestSuccess(req)
      logWarn("Thermostat rejected %s %s: %s", req.path, req.body or "", tostring(data.reason or "unknown reason"))
      if req.cb then pcall(req.cb, nil, "rejected: " .. tostring(data.reason or "unknown"), req) end
      setTimer(REQUEST_GAP_MS, function() Http.pump() end)
      return
    end
    Http.finish(req, data, nil)
  end)
  if req.method == "POST" then
    t:Post(url, req.body or "", headers)
  else
    t:Get(url, headers)
  end
end

-------------------------------------------------------------------------------
-- Connection status
-------------------------------------------------------------------------------

local publishAll -- forward

local function setConnected(connected, reason)
  if S.connected == connected then return end
  local previous = S.connected
  S.connected = connected
  C4:SendToProxy(PROXY_BINDING, "CONNECTION", { CONNECTED = connected and "true" or "false" }, "NOTIFY")
  setVar("CONNECTED", connected and "1" or "0", "BOOL")
  if connected then
    setProp("Driver Status", "Online")
    forgetNotifications()
    if previous == false then fireEvent("Communication Restored") end
  else
    setProp("Driver Status", "Offline: " .. tostring(reason or "no response"))
    if previous ~= nil then fireEvent("Communication Lost") end
  end
end

onRequestSuccess = function(req)
  S.failCount = 0
  if S.connected ~= true then setConnected(true) end
end

onRequestFailure = function(req, err)
  S.failCount = S.failCount + 1
  logWarn("%s %s failed (%d): %s", req.method, req.path, S.failCount, tostring(err))
  if S.failCount >= FAILS_BEFORE_OFFLINE then setConnected(false, err) end
  if tostring(err):find("401") then
    setProp("Driver Status", "Authentication failed: check Username/Password")
  end
end

-------------------------------------------------------------------------------
-- Units, display scale, conversions
-------------------------------------------------------------------------------

local KNOWN_DISPLAY_UNIT_MODELS = {
  ["VYG-4900-VEN"] = true, ["VYG-4800-VEN"] = true, ["VYG-3800"] = true,
  ["VYG-3900"] = true, ["COLORTOUCH"] = true, ["TOUCHSCREEN"] = true,
}

local function firmwareTuple()
  local fw = S.api and tostring(S.api.firmware or "") or ""
  local a, b = fw:match("^(%d+)%.(%d+)")
  return tonumber(a) or 0, tonumber(b) or 0
end

local function computeApiUnits(info)
  local display = num(info.tempunits) == 1 and "C" or "F"
  local model = tostring((S.api and S.api.model) or "COLORTOUCH"):upper()
  local isT23 = model:sub(1, 2) == "T2" or model:sub(1, 2) == "T3"
  if isT23 then
    local major, minor = firmwareTuple()
    if major < 5 or (major == 5 and minor < 28) then return "C" end
    return display
  end
  if KNOWN_DISPLAY_UNIT_MODELS[model] or model:find("COLORTOUCH", 1, true) then
    return display
  end
  local heatMax = num(info.heattempmax)
  if heatMax then return heatMax >= 40 and "F" or "C" end
  return display
end

local function roundToUnits(v)
  if S.units == "F" then return math.floor(v + 0.5) end
  return roundHalf(v)
end

local function toC(v) return S.units == "C" and v or f2c(v) end
local function toF(v) return S.units == "F" and v or c2f(v) end

--- Read a proxy temperature parameter set into API units.
local function proxyTempToApi(tParams)
  tParams = tParams or {}
  local c = tonumber(tParams.CELSIUS)
  local f = tonumber(tParams.FAHRENHEIT)
  local v
  if S.units == "F" then
    v = f or (c and c2f(c))
  else
    v = c or (f and f2c(f))
  end
  if v == nil then
    local raw = tonumber(tParams.SETPOINT or tParams.VALUE or tParams.TEMPERATURE)
    if raw then
      local scale = tostring(tParams.SCALE or ""):upper():sub(1, 1)
      if scale == "" then scale = S.displayScale or S.units end
      if scale == "C" then
        v = S.units == "C" and raw or c2f(raw)
      else
        v = S.units == "F" and raw or f2c(raw)
      end
    end
  end
  if v == nil then return nil end
  return roundToUnits(v)
end

local function resolveDisplayScale()
  local stored = persistGet("DisplayScale")
  if stored == "C" or stored == "F" then return stored end
  if S.info then return num(S.info.tempunits) == 1 and "C" or "F" end
  local ok, scale = pcall(C4.GetTemperatureScale, C4)
  if ok and type(scale) == "string" and scale:upper():sub(1, 1) == "C" then return "C" end
  return "F"
end

local function publishDisplayScale(force)
  local scale = resolveDisplayScale()
  if force or scale ~= S.displayScale then
    S.displayScale = scale
    S.sent["SCALE_CHANGED"] = nil
    notify("SCALE_CHANGED", { SCALE = scale })
  end
end

local function tempSensorParams(v)
  local c, f = toC(v), toF(v)
  return {
    VALUE = v,
    SCALE = S.units == "C" and "CELSIUS" or "FAHRENHEIT",
    CELSIUS = round(c, 1),
    FAHRENHEIT = round(f, 1),
    TIMESTAMP = os.time(),
  }
end

local function sendSensorOutputs()
  if S.indoorTemp then
    C4:SendToProxy(TEMP_OUT_BINDING, "VALUE_CHANGED", tempSensorParams(S.indoorTemp))
  end
  if S.humidity then
    C4:SendToProxy(HUM_OUT_BINDING, "VALUE_CHANGED", { VALUE = S.humidity, SCALE = "PERCENT", TIMESTAMP = os.time() })
  end
  if S.outdoorTemp then
    C4:SendToProxy(OUTDOOR_OUT_BINDING, "VALUE_CHANGED", tempSensorParams(S.outdoorTemp))
  end
end

-------------------------------------------------------------------------------
-- Capability publishing
-------------------------------------------------------------------------------

local function humidityControl()
  local v = Properties["Humidity Control"] or "Off"
  return v == "Humidify" or v == "Humidify and Dehumidify", v == "Dehumidify" or v == "Humidify and Dehumidify"
end

local function hvacModeList(info)
  local am = num(info.availablemodes) or 0
  if am == 1 then return { "Off", "Heat", "Cool" }, true, true, false end
  if am == 2 then return { "Off", "Heat" }, true, false, false end
  if am == 3 then return { "Off", "Cool" }, false, true, false end
  return { "Off", "Heat", "Cool", "Auto" }, true, true, true
end

local function holdModeList()
  if isResidential() then return "Off,Permanent,Away" end
  return "Off,Permanent"
end

local function outdoorSensor()
  if Properties["Outdoor Temperature"] == "Disabled" or type(S.sensors) ~= "table" then return nil end
  for _, s in ipairs(S.sensors) do
    if type(s) == "table" and (s.type == "Outdoor" or (s.type == nil and s.name == "Outdoor")) then
      return s
    end
  end
  return nil
end

local publishExtras -- defined after the state publishers

local function publishCapabilities(force)
  local info = S.info
  if not info then return end
  local modes, canHeat, canCool, canAuto = hvacModeList(info)
  local canHum, canDehum = humidityControl()
  local hasOutdoor = outdoorSensor() ~= nil
  local hasHumidity = S.humidity ~= nil

  local hMin, hMax = num(info.heattempmin), num(info.heattempmax)
  local cMin, cMax = num(info.cooltempmin), num(info.cooltempmax)
  local sig = table.concat({
    table.concat(modes, ","), tostring(canHum), tostring(canDehum), tostring(hasOutdoor),
    tostring(hasHumidity), S.units, tostring(hMin), tostring(hMax), tostring(cMin), tostring(cMax),
    holdModeList(),
  }, "|")
  if not force and sig == S.capsSignature then return end
  S.capsSignature = sig
  logInfo("Publishing capabilities: modes=%s units=%s humidity=%s outdoor=%s", table.concat(modes, ","), S.units,
    tostring(hasHumidity), tostring(hasOutdoor))

  S.sent["ALLOWED_HVAC_MODES_CHANGED"] = nil
  S.sent["ALLOWED_FAN_MODES_CHANGED"] = nil
  S.sent["ALLOWED_HOLD_MODES_CHANGED"] = nil
  notify("ALLOWED_HVAC_MODES_CHANGED", { MODES = table.concat(modes, ",") })
  notify("ALLOWED_FAN_MODES_CHANGED", { MODES = "Auto,On" })
  notify("ALLOWED_HOLD_MODES_CHANGED", { MODES = holdModeList() })

  C4:SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    HAS_SINGLE_SETPOINT = false,
    CAN_HEAT = canHeat,
    CAN_COOL = canCool,
    CAN_AUTO = canAuto,
    CAN_PRESET = false,
    CAN_PRESET_SCHEDULE = false,
    HAS_HUMIDITY = hasHumidity,
    CAN_HUMIDIFY = canHum,
    CAN_DEHUMIDIFY = canDehum,
    HAS_OUTDOOR_TEMPERATURE = hasOutdoor,
    HAS_EXTRAS = true,
  }, "NOTIFY")
  -- A capability refresh can reset the proxy's Extras, so resend them.
  S.extrasSetupSig, S.extrasStateSig = nil, nil

  local res = {
    HEAT_SETPOINT_RESOLUTION_C = 0.5, HEAT_SETPOINT_RESOLUTION_F = 1,
    COOL_SETPOINT_RESOLUTION_C = 0.5, COOL_SETPOINT_RESOLUTION_F = 1,
    CURRENT_TEMPERATURE_RESOLUTION_C = 0.5, CURRENT_TEMPERATURE_RESOLUTION_F = 1,
  }
  C4:SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", res, "NOTIFY")

  if hMin and hMax and cMin and cMax then
    C4:SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
      HEAT_SETPOINT_MIN_C = round(toC(hMin)), HEAT_SETPOINT_MAX_C = round(toC(hMax)),
      HEAT_SETPOINT_MIN_F = round(toF(hMin)), HEAT_SETPOINT_MAX_F = round(toF(hMax)),
      COOL_SETPOINT_MIN_C = round(toC(cMin)), COOL_SETPOINT_MAX_C = round(toC(cMax)),
      COOL_SETPOINT_MIN_F = round(toF(cMin)), COOL_SETPOINT_MAX_F = round(toF(cMax)),
    }, "NOTIFY")
  end
  publishDisplayScale(true)
end

-------------------------------------------------------------------------------
-- State publishing
-------------------------------------------------------------------------------

local MODE_NAMES = { [0] = "Off", [1] = "Heat", [2] = "Cool", [3] = "Auto" }
local MODE_VALUES = { Off = 0, Heat = 1, Cool = 2, Auto = 3 }
local SCHEDULE_PARTS = { [0] = "Morning", [1] = "Day", [2] = "Evening", [3] = "Night", [255] = "Inactive" }
local COMMERCIAL_PARTS = { [0] = "Occupied 1", [1] = "Unoccupied 1", [2] = "Occupied 2", [3] = "Unoccupied 2",
  [255] = "Inactive" }

local function currentHoldMode(info)
  if isResidential() and num(info.away) == 1 then return "Away" end
  if num(info.schedule) == 0 then return "Permanent" end
  return "Off"
end

local function hvacStateName(info)
  local mode = num(info.mode) or 0
  local state = num(info.state) or 0
  if state == 1 then return "Heating" end
  if state == 2 then return "Cooling" end
  if num(info.fanstate) == 1 then return "Fan Only" end
  if mode == 0 then return "Off" end
  return "Idle"
end

local function activityText(info)
  local state = num(info.state) or 0
  local stage = num(info.activestage)
  if state == 1 or state == 2 then
    local t = state == 1 and "Heating" or "Cooling"
    if stage and stage > 0 then t = t .. " (Stage " .. stage .. ")" end
    return t
  end
  if state == 3 then return "Lockout" end
  if state == 4 then return "Error" end
  return "Idle"
end

--- Humidity setpoints, honouring the API v5 (T5900 fw 4.08) field swap.
local function humiditySetpoints(info)
  if apiVer() == 5 then
    return num(info.dehum_setpoint), num(info.hum_active)
  end
  return num(info.hum_setpoint), num(info.dehum_setpoint)
end

local function publishSetpoints(info)
  local heat, cool = num(info.heattemp), num(info.cooltemp)
  if heat then notify("HEAT_SETPOINT_CHANGED", { SETPOINT = fmtNum(heat), SCALE = S.units }) end
  if cool then notify("COOL_SETPOINT_CHANGED", { SETPOINT = fmtNum(cool), SCALE = S.units }) end
  setVar("HEAT_SETPOINT", heat and fmtNum(heat) or "", "STRING")
  setVar("COOL_SETPOINT", cool and fmtNum(cool) or "", "STRING")
end

local function publishInfo()
  local info = S.info
  if not info then return end
  S.units = computeApiUnits(info)
  setProp("API Temperature Units", S.units == "F" and "Fahrenheit" or "Celsius")
  if S.displayScale == nil then publishDisplayScale(true) end
  publishCapabilities(false)

  local temp = num(info.spacetemp)
  if temp then
    S.indoorTemp = temp
    notify("TEMPERATURE_CHANGED", { TEMPERATURE = fmtNum(temp), SCALE = S.units })
    C4:SendToProxy(TEMP_OUT_BINDING, "VALUE_CHANGED", tempSensorParams(temp))
  end

  publishSetpoints(info)

  local mode = MODE_NAMES[num(info.mode) or 0] or "Off"
  notify("HVAC_MODE_CHANGED", { MODE = mode })
  notify("FAN_MODE_CHANGED", { MODE = num(info.fan) == 1 and "On" or "Auto" })
  local hvacState = hvacStateName(info)
  notify("HVAC_STATE_CHANGED", { STATE = hvacState })

  local hold = currentHoldMode(info)
  notify("HOLD_MODE_CHANGED", { MODE = hold })

  local canHum, canDehum = humidityControl()
  local humSp, dehumSp = humiditySetpoints(info)
  if canHum and humSp then notify("HUMIDIFY_SETPOINT_CHANGED", { SETPOINT = fmtNum(humSp) }) end
  if canDehum and dehumSp then notify("DEHUMIDIFY_SETPOINT_CHANGED", { SETPOINT = fmtNum(dehumSp) }) end

  -- Properties and variables
  local away = isResidential() and num(info.away) == 1
  if S.lastAway ~= nil and S.lastAway ~= away then
    fireEvent(away and "Away Mode On" or "Away Mode Off")
  end
  S.lastAway = away
  setProp("Thermostat Name", info.name or "")
  setProp("Current Activity", activityText(info))
  setProp("Fan Running", num(info.fanstate) == 1 and "Yes" or "No")
  setProp("Schedule", num(info.schedule) == 1 and "Running" or "Hold")
  local parts = isResidential() and SCHEDULE_PARTS or COMMERCIAL_PARTS
  setProp("Schedule Period", parts[num(info.schedulepart) or 255] or tostring(info.schedulepart or ""))
  if isResidential() then
    setProp("Away", away and "Yes" or "No")
    setProp("Occupancy", "")
  else
    setProp("Away", "N/A (commercial)")
    local occ = "Occupied"
    if num(info.holiday) == 1 then occ = "Holiday"
    elseif num(info.forceunocc) == 1 then occ = "Forced Unoccupied"
    elseif num(info.override) == 1 then occ = "Override (" .. tostring(info.overridetime or 0) .. " min)" end
    setProp("Occupancy", occ)
  end
  setProp("Last Update", os.date("%Y-%m-%d %H:%M:%S"))

  setVar("HVAC_STATE", hvacState, "STRING")
  setVar("HVAC_ACTIVITY", activityText(info), "STRING")
  setVar("SCHEDULE_RUNNING", num(info.schedule) == 1 and "1" or "0", "BOOL")
  setVar("AWAY", away and "1" or "0", "BOOL")
  publishExtras()
end

local function publishSensors()
  if type(S.sensors) ~= "table" then return end
  local humidity, list = nil, {}
  for _, s in ipairs(S.sensors) do
    if type(s) == "table" then
      local name = tostring(s.name or "?")
      local entry = name
      if s.temp ~= nil then entry = entry .. " " .. fmtNum(num(s.temp) or 0) .. "°" .. S.units end
      if s.hum ~= nil then entry = entry .. " " .. tostring(s.hum) .. "%" end
      if s.co2 ~= nil then entry = entry .. " CO2 " .. tostring(round(num(s.co2) or 0)) .. "ppm" end
      if s.iaq ~= nil then entry = entry .. " IAQ " .. tostring(round(num(s.iaq) or 0)) end
      if s.battery ~= nil then entry = entry .. " batt " .. tostring(s.battery) .. "%" end
      list[#list + 1] = entry
      local isLocal = s.type == "Local" or (s.type == nil and name == "Thermostat")
      if isLocal and humidity == nil and num(s.hum) then humidity = num(s.hum) end
    end
  end
  if humidity == nil and S.info and num(S.info.hum) and num(S.info.hum) > 0 then
    humidity = num(S.info.hum)
  end
  setProp("Sensors", table.concat(list, "; "))

  if humidity then
    S.humidity = math.floor(humidity + 0.5)
    notify("HUMIDITY_CHANGED", { HUMIDITY = tostring(S.humidity) })
    C4:SendToProxy(HUM_OUT_BINDING, "VALUE_CHANGED", { VALUE = S.humidity, SCALE = "PERCENT", TIMESTAMP = os.time() })
    setProp("Indoor Humidity", tostring(S.humidity) .. "%")
    setVar("HUMIDITY", tostring(S.humidity), "NUMBER")
  end

  local outdoor = outdoorSensor()
  if outdoor and num(outdoor.temp) then
    S.outdoorTemp = num(outdoor.temp)
    notify("OUTDOOR_TEMPERATURE_CHANGED", { TEMPERATURE = fmtNum(S.outdoorTemp), SCALE = S.units })
    C4:SendToProxy(OUTDOOR_OUT_BINDING, "VALUE_CHANGED", tempSensorParams(S.outdoorTemp))
    setProp("Outdoor Temp Reading", fmtNum(S.outdoorTemp) .. "°" .. S.units)
    setVar("OUTDOOR_TEMPERATURE", fmtNum(S.outdoorTemp), "STRING")
  else
    S.outdoorTemp = nil
    setProp("Outdoor Temp Reading", "None")
  end
  publishCapabilities(false)
  publishExtras()
end

local ALERT_EVENTS = {
  ["Air Filter"] = { prop = "Air Filter Alert", event = "Air Filter Alert", var = "FILTER_ALERT" },
  ["UV Lamp"] = { prop = "UV Lamp Alert", event = "UV Lamp Alert", var = "UV_LAMP_ALERT" },
  ["Service"] = { prop = "Service Alert", event = "Service Alert", var = "SERVICE_ALERT" },
}

local function publishAlerts(list)
  if type(list) ~= "table" then return end
  local first = S.alerts == nil
  local prev = S.alerts or {}
  local now, anyActive, anyWasActive = {}, false, false
  for _, a in ipairs(list) do
    if type(a) == "table" and a.name then
      local active = a.active == true or num(a.active) == 1
      now[a.name] = active
      anyActive = anyActive or active
      local map = ALERT_EVENTS[a.name]
      if map then
        setProp(map.prop, active and "ACTIVE" or "OK")
        setVar(map.var, active and "1" or "0", "BOOL")
        if active and not first and not prev[a.name] then fireEvent(map.event) end
      end
    end
  end
  for _, v in pairs(prev) do anyWasActive = anyWasActive or v end
  if not first and anyWasActive and not anyActive then fireEvent("All Alerts Cleared") end
  S.alerts = now
  S.alertList = list
  publishExtras()
end

-------------------------------------------------------------------------------
-- Navigator Extras tab: read-only sensor, status and alert listing
-------------------------------------------------------------------------------

-- Object type used for each read-only row. Kept in one place so it can be
-- swapped if a Navigator version renders read-only rows differently.
local EXTRAS_OBJECT_TYPE = "text"

local function xmlEsc(s)
  s = tostring(s == nil and "" or s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  return s
end

local function extrasId(prefix, name)
  local clean = tostring(name or ""):gsub("[^%w]", "")
  return prefix .. clean
end

local function tempText(v)
  if v == nil then return nil end
  return fmtNum(roundToUnits(v)) .. "°" .. S.units
end

--- Ordered rows {section, id, label, value} for the Extras tab.
local function collectExtras()
  local rows = {}
  local function add(section, id, label, value)
    if value ~= nil and value ~= "" then
      rows[#rows + 1] = { section = section, id = id, label = label, value = tostring(value) }
    end
  end

  -- Sensors: the controlling readings first, then every sensor the thermostat reports.
  add("Sensors", "indoorTemp", "Indoor Temperature", tempText(S.indoorTemp))
  if S.humidity then add("Sensors", "indoorHum", "Indoor Humidity", S.humidity .. "%") end
  add("Sensors", "outdoorTemp", "Outdoor Temperature", tempText(S.outdoorTemp))
  if type(S.sensors) == "table" then
    for _, s in ipairs(S.sensors) do
      -- The outdoor sensor and the thermostat's own humidity already lead the list.
      if type(s) == "table" and s.name and s ~= outdoorSensor() then
        local name = tostring(s.name)
        local kind = (s.type and s.type ~= name) and (" (" .. tostring(s.type) .. ")") or ""
        local isLocal = s.type == "Local" or (s.type == nil and name == "Thermostat")
        local base = extrasId("s", name)
        if num(s.temp) then add("Sensors", base .. "Temp", name .. kind .. " Temperature", tempText(num(s.temp))) end
        if num(s.hum) and not isLocal then add("Sensors", base .. "Hum", name .. " Humidity", fmtNum(num(s.hum)) .. "%") end
        if num(s.co2) then add("Sensors", base .. "Co2", name .. " CO2", round(num(s.co2)) .. " ppm") end
        if num(s.iaq) then add("Sensors", base .. "Iaq", name .. " Air Quality (IAQ)", round(num(s.iaq))) end
        if num(s.intensity) then add("Sensors", base .. "Light", name .. " Light Intensity", fmtNum(num(s.intensity))) end
        if num(s.battery) then add("Sensors", base .. "Batt", name .. " Battery", fmtNum(num(s.battery)) .. "%") end
      end
    end
  end

  -- Status
  local info = S.info
  if info then
    add("Status", "activity", "Current Activity", activityText(info))
    add("Status", "fanRunning", "Fan Running", num(info.fanstate) == 1 and "Yes" or "No")
    add("Status", "schedule", "Schedule", num(info.schedule) == 1 and "Running" or "Hold")
    local parts = isResidential() and SCHEDULE_PARTS or COMMERCIAL_PARTS
    add("Status", "schedulePart", "Schedule Period", parts[num(info.schedulepart) or 255] or tostring(info.schedulepart or ""))
    if isResidential() then
      add("Status", "away", "Away", num(info.away) == 1 and "Yes" or "No")
    else
      add("Status", "occupancy", "Occupancy", S.propCache["Occupancy"])
    end
    local canHum, canDehum = humidityControl()
    local humSp, dehumSp = humiditySetpoints(info)
    if canHum and humSp then add("Status", "humSp", "Humidify Setpoint", fmtNum(humSp) .. "%") end
    if canDehum and dehumSp then add("Status", "dehumSp", "Dehumidify Setpoint", fmtNum(dehumSp) .. "%") end
    add("Status", "lastUpdate", "Last Update", os.date("%I:%M %p"))
  end

  -- Alerts
  if type(S.alertList) == "table" then
    for _, a in ipairs(S.alertList) do
      if type(a) == "table" and a.name then
        local active = a.active == true or num(a.active) == 1
        add("Alerts", extrasId("alert", a.name), tostring(a.name), active and "ACTIVE" or "OK")
      end
    end
  end
  return rows
end

publishExtras = function()
  local rows = collectExtras()
  if #rows == 0 then return end

  -- Structure (sections, ids, labels) decides whether the setup must be resent.
  local structure, values = {}, {}
  for _, r in ipairs(rows) do
    structure[#structure + 1] = r.section .. "/" .. r.id .. "/" .. r.label
    values[#values + 1] = r.id .. "=" .. r.value
  end
  local setupSig = table.concat(structure, "|")
  local stateSig = table.concat(values, "|")

  if setupSig ~= S.extrasSetupSig then
    local xml = { "<extras_setup><extra>" }
    local current = nil
    for _, r in ipairs(rows) do
      if r.section ~= current then
        if current then xml[#xml + 1] = "</section>" end
        current = r.section
        xml[#xml + 1] = '<section label="' .. xmlEsc(r.section) .. '">'
      end
      xml[#xml + 1] = string.format('<object type="%s" id="%s" label="%s" value="%s"/>',
        EXTRAS_OBJECT_TYPE, xmlEsc(r.id), xmlEsc(r.label), xmlEsc(r.value))
    end
    xml[#xml + 1] = "</section></extra></extras_setup>"
    S.extrasSetupSig, S.extrasStateSig = setupSig, stateSig
    logDebug("Extras setup: %d rows", #rows)
    C4:SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = table.concat(xml) }, "NOTIFY")
    return
  end

  if stateSig ~= S.extrasStateSig then
    S.extrasStateSig = stateSig
    local xml = { "<extras_state><extra>" }
    for _, r in ipairs(rows) do
      xml[#xml + 1] = string.format('<object id="%s" value="%s"/>', xmlEsc(r.id), xmlEsc(r.value))
    end
    xml[#xml + 1] = "</extra></extras_state>"
    C4:SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = table.concat(xml) }, "NOTIFY")
  end
end

publishAll = function()
  forgetNotifications()
  publishInfo()
  publishSensors()
  sendSensorOutputs()
end

-------------------------------------------------------------------------------
-- Polling
-------------------------------------------------------------------------------

local Poll = {}

local function onApiResponse(data)
  if type(data) ~= "table" then return end
  S.api = data
  setProp("Model", data.model or "")
  setProp("Firmware", data.firmware or "")
  setProp("API Version", data.api_ver or "")
  setProp("Thermostat Type", data.type or "")
  if num(data.api_ver) and num(data.api_ver) < 3 then
    logWarn("API version %s is older than the supported minimum (3)", tostring(data.api_ver))
  end
end

local function onInfoResponse(data, err, req)
  if type(data) ~= "table" then return end
  if req.seqAtSend < S.cmdSeq then
    logDebug("Discarding info read that started before a newer command")
    return
  end
  S.info = data
  publishInfo()
end

local function onSensorsResponse(data)
  if type(data) ~= "table" then return end
  S.sensors = data.sensors or {}
  publishSensors()
end

local function onAlertsResponse(data)
  if type(data) ~= "table" then return end
  publishAlerts(data.alerts)
end

function Poll.refreshInfo(front)
  if Http.hasQueued("info") then return end
  Http.enqueue({ path = "/query/info", kind = "info", cb = onInfoResponse }, front)
end

function Poll.tick()
  if not isConfigured() then return end
  if Http.hasQueued("info") or Http.hasQueued("sensors") then
    logTrace("Previous poll still queued; skipping")
    return
  end
  if S.api == nil or S.pollCount % API_POLL_EVERY == 0 then
    Http.enqueue({ path = "/", kind = "api", cb = onApiResponse })
  end
  Poll.refreshInfo(false)
  Http.enqueue({ path = "/query/sensors", kind = "sensors", cb = onSensorsResponse })
  if S.pollCount % ALERT_POLL_EVERY == 0 then
    Http.enqueue({ path = "/query/alerts", kind = "alerts", cb = onAlertsResponse })
  end
  S.pollCount = S.pollCount + 1
end

function Poll.start()
  S.pollTimer = cancelTimer(S.pollTimer)
  if not isConfigured() then
    setProp("Driver Status", "Not configured: enter the IP Address")
    return
  end
  local interval = tonumber(Properties["Poll Interval (seconds)"]) or 30
  if interval < 10 then interval = 10 end
  S.pollCount = 0
  S.pollTimer = setTimer(interval * 1000, function() Poll.tick() end, true)
  Poll.tick()
end

local function scheduleRefresh()
  setTimer(REFRESH_AFTER_CMD_MS, function() Poll.refreshInfo(true) end)
end

-------------------------------------------------------------------------------
-- Control
-------------------------------------------------------------------------------

local Ctl = { pendingHeat = nil, pendingCool = nil, timer = nil }

local function requireInfo(what)
  if S.info then return true end
  logWarn("Ignoring %s: no data from the thermostat yet", what)
  return false
end

local function bumpCmd()
  S.cmdSeq = S.cmdSeq + 1
end

local function postControl(fields, order, label)
  bumpCmd()
  Http.enqueue({
    method = "POST", path = "/control", kind = "control",
    body = formEncode(fields, order),
    cb = function(data, err)
      if err then logWarn("%s failed: %s", label, tostring(err)) else logInfo("%s OK", label) end
      scheduleRefresh()
    end,
  }, true)
end

local function postSettings(fields, order, label, front)
  bumpCmd()
  Http.enqueue({
    method = "POST", path = "/settings", kind = "settings",
    body = formEncode(fields, order),
    cb = function(data, err)
      if err then logWarn("%s failed: %s", label, tostring(err)) else logInfo("%s OK", label) end
      scheduleRefresh()
    end,
  }, true)
end

--- Clamp and enforce setpointdelta. `changed` is "heat", "cool" or nil.
local function normalizeSetpoints(heat, cool, changed)
  local info = S.info
  local delta = num(info.setpointdelta) or 0
  local hMin, hMax = num(info.heattempmin), num(info.heattempmax)
  local cMin, cMax = num(info.cooltempmin), num(info.cooltempmax)
  if hMin and heat < hMin then heat = hMin end
  if hMax and heat > hMax then heat = hMax end
  if cMin and cool < cMin then cool = cMin end
  if cMax and cool > cMax then cool = cMax end
  if heat + delta > cool then
    if changed == "cool" then
      heat = cool - delta
      if hMin and heat < hMin then heat = hMin; cool = heat + delta end
    else
      cool = heat + delta
      if cMax and cool > cMax then cool = cMax; heat = cool - delta end
    end
  end
  return roundToUnits(heat), roundToUnits(cool)
end

function Ctl.flushSetpoints()
  Ctl.timer = cancelTimer(Ctl.timer)
  if not S.info or (Ctl.pendingHeat == nil and Ctl.pendingCool == nil) then return end
  local changed = nil
  if Ctl.pendingHeat and not Ctl.pendingCool then changed = "heat" end
  if Ctl.pendingCool and not Ctl.pendingHeat then changed = "cool" end
  local heat = Ctl.pendingHeat or num(S.info.heattemp)
  local cool = Ctl.pendingCool or num(S.info.cooltemp)
  Ctl.pendingHeat, Ctl.pendingCool = nil, nil
  if not heat or not cool then return end
  heat, cool = normalizeSetpoints(heat, cool, changed)
  S.info.heattemp, S.info.cooltemp = heat, cool
  publishSetpoints(S.info)
  postControl({ heattemp = heat, cooltemp = cool }, { "heattemp", "cooltemp" },
    string.format("Set setpoints heat=%s cool=%s", fmtNum(heat), fmtNum(cool)))
end

function Ctl.queueSetpoint(which, value)
  if not requireInfo("setpoint change") or value == nil then return end
  if which == "heat" then Ctl.pendingHeat = value else Ctl.pendingCool = value end
  -- Optimistic echo so Navigator settles while taps are coalesced.
  if which == "heat" then
    notify("HEAT_SETPOINT_CHANGED", { SETPOINT = fmtNum(value), SCALE = S.units })
  else
    notify("COOL_SETPOINT_CHANGED", { SETPOINT = fmtNum(value), SCALE = S.units })
  end
  bumpCmd()
  Ctl.timer = cancelTimer(Ctl.timer)
  Ctl.timer = setTimer(SETPOINT_DEBOUNCE_MS, function() Ctl.flushSetpoints() end)
end

function Ctl.stepSetpoint(which, dir)
  if not requireInfo("setpoint step") then return end
  local step = S.units == "F" and 1 or 0.5
  local current
  if which == "heat" then
    current = Ctl.pendingHeat or num(S.info.heattemp)
  else
    current = Ctl.pendingCool or num(S.info.cooltemp)
  end
  if current then Ctl.queueSetpoint(which, current + dir * step) end
end

function Ctl.setMode(modeName)
  if not requireInfo("mode change") then return end
  local mode = MODE_VALUES[modeName]
  if mode == nil then
    logWarn("Unsupported HVAC mode '%s'", tostring(modeName))
    return
  end
  -- Flush pending setpoints first so the two POSTs stay separate.
  if Ctl.pendingHeat or Ctl.pendingCool then Ctl.flushSetpoints() end
  local heat, cool = normalizeSetpoints(num(S.info.heattemp) or 68, num(S.info.cooltemp) or 75, nil)
  S.info.mode = mode
  S.info.heattemp, S.info.cooltemp = heat, cool
  notify("HVAC_MODE_CHANGED", { MODE = modeName })
  postControl({ mode = mode, heattemp = heat, cooltemp = cool }, { "mode", "heattemp", "cooltemp" },
    "Set mode " .. modeName)
end

function Ctl.setFan(fanName)
  if not requireInfo("fan change") then return end
  local fan = (fanName == "On" or fanName == "Circulate") and 1 or 0
  S.info.fan = fan
  notify("FAN_MODE_CHANGED", { MODE = fan == 1 and "On" or "Auto" })
  postControl({ fan = fan }, { "fan" }, "Set fan " .. (fan == 1 and "On" or "Auto"))
end

function Ctl.setHold(holdName)
  if not requireInfo("hold change") then return end
  local info = S.info
  local schedule = num(info.schedule)
  local away = num(info.away)
  local residential = isResidential()
  if holdName ~= "Off" and holdName ~= "Away" then holdName = "Permanent" end
  if holdName == "Away" and not residential then
    logWarn("Away is not supported on commercial thermostats")
    return
  end
  notify("HOLD_MODE_CHANGED", { MODE = holdName })
  -- Order matters: away needs the schedule off; the schedule needs away off.
  if holdName == "Away" then
    if schedule == 1 then postSettings({ schedule = 0 }, { "schedule" }, "Schedule off") end
    if away ~= 1 then postSettings({ away = 1 }, { "away" }, "Away on") end
    info.schedule, info.away = 0, 1
  elseif holdName == "Permanent" then
    if residential and away == 1 then postSettings({ away = 0 }, { "away" }, "Away off") end
    if schedule ~= 0 then postSettings({ schedule = 0 }, { "schedule" }, "Schedule off") end
    info.schedule = 0
    if residential then info.away = 0 end
  else
    if residential and away == 1 then postSettings({ away = 0 }, { "away" }, "Away off") end
    if schedule ~= 1 then postSettings({ schedule = 1 }, { "schedule" }, "Schedule on") end
    info.schedule = 1
    if residential then info.away = 0 end
  end
end

function Ctl.setAway(on)
  if on then Ctl.setHold("Away") else Ctl.setHold("Off") end
end

function Ctl.setHumidity(which, value)
  if not requireInfo("humidity change") then return end
  value = tonumber(value)
  if value == nil then return end
  if apiVer() == 5 then
    logWarn("Humidity setpoints are read-only on API v5 (T5900 firmware 4.08)")
    return
  end
  local hum, dehum = humiditySetpoints(S.info)
  if which == "hum" then
    value = math.max(0, math.min(60, math.floor(value + 0.5)))
    hum = value
    S.info.hum_setpoint = value
    notify("HUMIDIFY_SETPOINT_CHANGED", { SETPOINT = fmtNum(value) })
  else
    value = math.max(25, math.min(99, math.floor(value + 0.5)))
    dehum = value
    S.info.dehum_setpoint = value
    notify("DEHUMIDIFY_SETPOINT_CHANGED", { SETPOINT = fmtNum(value) })
  end
  postSettings({
    tempunits = num(S.info.tempunits) or 0,
    hum_setpoint = hum,
    dehum_setpoint = dehum,
  }, { "tempunits", "hum_setpoint", "dehum_setpoint" },
    string.format("Set humidity setpoints hum=%s dehum=%s", tostring(hum), tostring(dehum)), true)
end

-------------------------------------------------------------------------------
-- Proxy commands
-------------------------------------------------------------------------------

local RFP = {}

function RFP.SET_SETPOINT_HEAT(tParams) Ctl.queueSetpoint("heat", proxyTempToApi(tParams)) end
function RFP.SET_SETPOINT_COOL(tParams) Ctl.queueSetpoint("cool", proxyTempToApi(tParams)) end
function RFP.INC_SETPOINT_HEAT() Ctl.stepSetpoint("heat", 1) end
function RFP.DEC_SETPOINT_HEAT() Ctl.stepSetpoint("heat", -1) end
function RFP.INC_SETPOINT_COOL() Ctl.stepSetpoint("cool", 1) end
function RFP.DEC_SETPOINT_COOL() Ctl.stepSetpoint("cool", -1) end

local function singleTarget()
  local mode = S.info and num(S.info.mode) or 0
  return mode == 2 and "cool" or "heat"
end

function RFP.SET_SETPOINT_SINGLE(tParams) Ctl.queueSetpoint(singleTarget(), proxyTempToApi(tParams)) end
function RFP.INC_SETPOINT_SINGLE() Ctl.stepSetpoint(singleTarget(), 1) end
function RFP.DEC_SETPOINT_SINGLE() Ctl.stepSetpoint(singleTarget(), -1) end

function RFP.SET_MODE_HVAC(tParams) Ctl.setMode(tParams.MODE) end
function RFP.SET_MODE_OFF() Ctl.setMode("Off") end
function RFP.SET_MODE_HEAT() Ctl.setMode("Heat") end
function RFP.SET_MODE_COOL() Ctl.setMode("Cool") end
function RFP.SET_MODE_AUTO() Ctl.setMode("Auto") end
function RFP.SET_MODE_FAN(tParams) Ctl.setFan(tParams.MODE) end
function RFP.SET_MODE_HOLD(tParams) Ctl.setHold(tParams.MODE or "Off") end

function RFP.SET_SETPOINT_HUMIDIFY(tParams) Ctl.setHumidity("hum", tParams.SETPOINT or tParams.VALUE) end
function RFP.SET_SETPOINT_DEHUMIDIFY(tParams) Ctl.setHumidity("dehum", tParams.SETPOINT or tParams.VALUE) end

function RFP.SET_SCALE(tParams)
  local scale = tostring(tParams.SCALE or ""):upper():sub(1, 1)
  if scale ~= "C" and scale ~= "F" then return end
  persistSet("DisplayScale", scale)
  publishDisplayScale(true)
end

-- Sent by the proxy for features this driver does not implement.
local IGNORED = {
  SET_PRESETS = true, SET_EVENTS = true, SET_EVENT = true, SET_PRESET = true,
  SET_REMOTE_SENSOR = true, SET_MODE_HUMIDITY = true, SET_VACATION_MODE = true,
  SET_VACATION_SETPOINTS = true,
}

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  logDebug("RFP %s %s %s", tostring(idBinding), tostring(strCommand), Json.encode(tParams))
  if idBinding == TEMP_OUT_BINDING or idBinding == HUM_OUT_BINDING or idBinding == OUTDOOR_OUT_BINDING then
    sendSensorOutputs()
    return
  end
  if idBinding ~= PROXY_BINDING then return end
  local fn = RFP[strCommand]
  if fn then
    local ok, err = pcall(fn, tParams)
    if not ok then logError("Error handling %s: %s", strCommand, tostring(err)) end
  elseif not IGNORED[strCommand] then
    logDebug("Unhandled proxy command %s", tostring(strCommand))
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if bIsBound and (idBinding == TEMP_OUT_BINDING or idBinding == HUM_OUT_BINDING or idBinding == OUTDOOR_OUT_BINDING) then
    sendSensorOutputs()
  end
end

-------------------------------------------------------------------------------
-- Programming commands and actions
-------------------------------------------------------------------------------

local function printData()
  print("---- Venstar data ----")
  print("api:     " .. Json.encode(S.api or {}))
  print("info:    " .. Json.encode(S.info or {}))
  print("sensors: " .. Json.encode(S.sensors or {}))
  print("alerts:  " .. Json.encode(S.alerts or {}))
  print("units: " .. S.units .. "  display: " .. tostring(S.displayScale) .. "  connected: " .. tostring(S.connected))
end

local COMMANDS = {}

COMMANDS["REFRESH_NOW"] = function()
  S.pollCount = 0
  Poll.tick()
end
COMMANDS["Refresh Now"] = COMMANDS["REFRESH_NOW"]

COMMANDS["TEST_CONNECTION"] = function()
  if not isConfigured() then
    print("Venstar: IP Address is not set")
    return
  end
  Http.enqueue({ path = "/", kind = "test", cb = function(data, err)
    if err then
      print("Venstar connection test FAILED: " .. tostring(err))
    else
      print("Venstar connection test OK: " .. Json.encode(data))
      onApiResponse(data)
    end
  end }, true)
end

COMMANDS["PRINT_DATA"] = printData

COMMANDS["Set Away Mode"] = function(p)
  local state = p.State or "On"
  if state == "Toggle" then
    Ctl.setAway(not (S.info and num(S.info.away) == 1))
  else
    Ctl.setAway(state == "On")
  end
end

COMMANDS["Set Schedule"] = function(p)
  Ctl.setHold(p.Schedule == "Permanent Hold" and "Permanent" or "Off")
end

COMMANDS["Set Humidify Setpoint"] = function(p) Ctl.setHumidity("hum", p.Percent) end
COMMANDS["Set Dehumidify Setpoint"] = function(p) Ctl.setHumidity("dehum", p.Percent) end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" then strCommand = tParams.ACTION end
  logDebug("ExecuteCommand %s %s", tostring(strCommand), Json.encode(tParams))
  local fn = COMMANDS[strCommand]
  if fn then
    local ok, err = pcall(fn, tParams)
    if not ok then logError("Error in command %s: %s", tostring(strCommand), tostring(err)) end
  else
    logDebug("Unknown command %s", tostring(strCommand))
  end
end

-------------------------------------------------------------------------------
-- Properties
-------------------------------------------------------------------------------

local function applyDebug()
  local mode = Properties["Debug Mode"] or "Off"
  LOG_PRINT = mode == "Print" or mode == "Print and Log"
  LOG_FILE = mode == "Log" or mode == "Print and Log"
  LOG_LEVEL = tonumber((Properties["Debug Level"] or "3"):match("^(%d)")) or 3
  if mode == "Off" then LOG_LEVEL = 1 end
  S.debugTimer = cancelTimer(S.debugTimer)
  if mode ~= "Off" then
    S.debugTimer = setTimer(DEBUG_AUTO_OFF_MS, function()
      C4:UpdateProperty("Debug Mode", "Off")
      OnPropertyChanged("Debug Mode")
    end)
  end
end

local function resetConnection()
  Http.clear()
  Http.auth = nil
  Http.nc = 0
  S.api, S.info, S.sensors, S.alerts = nil, nil, nil, nil
  S.failCount = 0
  forgetNotifications()
  Poll.start()
end

local PROPERTY_HANDLERS = {
  ["IP Address"] = resetConnection,
  ["Use HTTPS"] = resetConnection,
  ["Username"] = function() Http.auth = nil end,
  ["Password"] = function() Http.auth = nil end,
  ["Poll Interval (seconds)"] = function() Poll.start() end,
  ["Humidity Control"] = function() publishCapabilities(true); if S.info then publishAll() end end,
  ["Outdoor Temperature"] = function() if S.info then publishAll(); publishCapabilities(true) end end,
  ["Debug Mode"] = applyDebug,
  ["Debug Level"] = applyDebug,
}

local INITIALIZED = false

function OnPropertyChanged(strProperty)
  if not INITIALIZED then return end
  local fn = PROPERTY_HANDLERS[strProperty]
  if fn then
    local ok, err = pcall(fn)
    if not ok then logError("Property %s handler error: %s", strProperty, tostring(err)) end
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function OnDriverInit()
  math.randomseed(os.time())
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
end

function OnDriverLateInit()
  INITIALIZED = true
  applyDebug()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  setVar("CONNECTED", "0", "BOOL")
  setVar("HVAC_STATE", "", "STRING")
  setVar("HVAC_ACTIVITY", "", "STRING")
  setVar("HEAT_SETPOINT", "", "STRING")
  setVar("COOL_SETPOINT", "", "STRING")
  setVar("HUMIDITY", "0", "NUMBER")
  setVar("OUTDOOR_TEMPERATURE", "", "STRING")
  setVar("AWAY", "0", "BOOL")
  setVar("SCHEDULE_RUNNING", "0", "BOOL")
  setVar("FILTER_ALERT", "0", "BOOL")
  setVar("UV_LAMP_ALERT", "0", "BOOL")
  setVar("SERVICE_ALERT", "0", "BOOL")
  publishDisplayScale(true)
  logInfo("Venstar driver %s starting", DRIVER_VERSION)
  Poll.start()
end

function OnDriverDestroyed()
  S.pollTimer = cancelTimer(S.pollTimer)
  S.debugTimer = cancelTimer(S.debugTimer)
  Ctl.timer = cancelTimer(Ctl.timer)
  Http.clear()
end

-- Exposed for the offline test harness only.
_VENSTAR_TEST = { S = S, Http = Http, Ctl = Ctl, Poll = Poll, Json = Json, md5hex = md5hex,
  parseChallenge = parseChallenge, authHeader = authHeader, normalizeSetpoints = normalizeSetpoints,
  computeApiUnits = computeApiUnits, proxyTempToApi = proxyTempToApi }
