-- Offline harness: mock Control4 runtime + fake Venstar thermostat.
local DRIVER = arg[1]

local NOW = 0
local timers = {}
local notifies, events, props, vars, requests = {}, {}, {}, {}, {}
local failNetwork = false

-- Fake thermostat --------------------------------------------------------
local T = {}
local function resetThermostat(opts)
  opts = opts or {}
  T = {
    api = { api_ver = 7, type = opts.type or "residential", model = opts.model or "COLORTOUCH", firmware = opts.firmware or "6.93" },
    info = {
      name = "Living Room", mode = 1, state = 0, activestage = 0, fan = 0, fanstate = 0,
      tempunits = opts.tempunits or 0, schedule = 1, schedulepart = 1, away = 0, holiday = 0,
      override = 0, overridetime = 0, forceunocc = 0, spacetemp = opts.spacetemp or 71,
      heattemp = opts.heattemp or 68, cooltemp = opts.cooltemp or 75,
      cooltempmin = opts.cmin or 35, cooltempmax = opts.cmax or 99,
      heattempmin = opts.hmin or 35, heattempmax = opts.hmax or 99, setpointdelta = opts.delta or 2,
      hum = 45, hum_setpoint = 35, dehum_setpoint = 55, hum_active = 0, availablemodes = opts.availablemodes or 0,
    },
    sensors = { sensors = {
      { name = "Thermostat", temp = 71, hum = 45 },
      { name = "Outdoor", temp = 52, type = "Outdoor" },
      { name = "SENSOR0729", temp = 64, battery = 100, type = "Remote" },
    } },
    alerts = { alerts = { { name = "Air Filter", active = false }, { name = "UV Lamp", active = false }, { name = "Service", active = false } } },
    digest = opts.digest, user = "admin", pass = "secret", realm = "venstar", nonce = "abc123nonce",
    pin = opts.pin,
    posts = {},
  }
end

local function parseForm(body)
  local t = {}
  for k, v in (body or ""):gmatch("([^&=]+)=([^&]*)") do t[k] = tonumber(v) or v end
  return t
end

local function enc(v)
  local J = _VENSTAR_TEST and _VENSTAR_TEST.Json
  return J.encode(v)
end

local function checkDigest(method, uri, header)
  if not header or not header:match("^Digest ") then return false end
  local f = {}
  for k, v in header:gmatch('(%w+)="([^"]*)"') do f[k] = v end
  for k, v in header:gmatch('(%w+)=([^",%s]+)') do if not f[k] then f[k] = v end end
  if f.uri ~= uri or f.username ~= T.user or f.nonce ~= T.nonce then return false end
  local ha1 = md5.sumhexa(T.user .. ":" .. T.realm .. ":" .. T.pass)
  local ha2 = md5.sumhexa(method .. ":" .. uri)
  local expect = md5.sumhexa(ha1 .. ":" .. T.nonce .. ":" .. f.nc .. ":" .. f.cnonce .. ":" .. f.qop .. ":" .. ha2)
  return expect == f.response
end

local function serve(method, url, body, headers)
  local uri = url:match("^https?://[^/]+(.*)$")
  local path, query = uri:match("^([^?]*)%??(.*)$")
  requests[#requests + 1] = { method = method, path = path, body = body, uri = uri }
  if T.digest and not checkDigest(method, uri, headers.Authorization) then
    return { code = 401, headers = { ["WWW-Authenticate"] = 'Digest realm="venstar", nonce="abc123nonce", qop="auth", algorithm=MD5' }, body = "" }
  end
  if T.pin and not query:find("pin=" .. T.pin, 1, true) then
    return { code = 200, body = '{"error":true,"reason":"PIN required"}', headers = {} }
  end
  local i = T.info
  if method == "GET" then
    if path == "/" then return { code = 200, body = enc(T.api), headers = {} } end
    if path == "/query/info" then return { code = 200, body = enc(i), headers = {} } end
    if path == "/query/sensors" then return { code = 200, body = enc(T.sensors), headers = {} } end
    if path == "/query/alerts" then return { code = 200, body = enc(T.alerts), headers = {} } end
    return { code = 404, body = "", headers = {} }
  end
  local f = parseForm(body)
  T.posts[#T.posts + 1] = path .. " " .. body
  local function err(r) return { code = 200, body = '{"error":true,"reason":"' .. r .. '"}', headers = {} } end
  if path == "/control" then
    if f.fan ~= nil then
      if f.mode or f.heattemp or f.cooltemp then return err("fan must be alone") end
      i.fan = f.fan
    elseif f.mode ~= nil then
      if f.heattemp == nil or f.cooltemp == nil then return err("Both Setpoints are required") end
      if f.cooltemp < f.heattemp + i.setpointdelta then return err("delta") end
      i.mode, i.heattemp, i.cooltemp = f.mode, f.heattemp, f.cooltemp
    else
      if f.heattemp == nil or f.cooltemp == nil then return err("Both Setpoints are required") end
      if f.cooltemp < f.heattemp + i.setpointdelta then return err("delta") end
      i.heattemp, i.cooltemp = f.heattemp, f.cooltemp
    end
    return { code = 200, body = '{"success":true}', headers = {} }
  elseif path == "/settings" then
    if f.away ~= nil then
      if i.schedule == 1 then return err("schedule active") end
      i.away = f.away
    end
    if f.schedule ~= nil then
      if f.schedule == 1 and i.away == 1 then return err("away active") end
      i.schedule = f.schedule
    end
    if f.hum_setpoint then i.hum_setpoint = f.hum_setpoint end
    if f.dehum_setpoint then i.dehum_setpoint = f.dehum_setpoint end
    return { code = 200, body = '{"success":true}', headers = {} }
  end
  return { code = 404, body = "", headers = {} }
end

-- Mock C4 ----------------------------------------------------------------
local function addTimer(ms, fn, rep)
  local t = { at = NOW + ms, ms = ms, fn = fn, rep = rep, live = true }
  function t:Cancel() self.live = false end
  timers[#timers + 1] = t
  return t
end

C4 = {}
function C4:SetTimer(ms, fn, rep) return addTimer(ms, fn, rep) end
function C4:UpdateProperty(k, v) Properties[k] = v; props[k] = v end
function C4:SendToProxy(id, cmd, params, kind)
  notifies[#notifies + 1] = { id = id, cmd = cmd, params = params }
end
function C4:FireEvent(n) events[#events + 1] = n end
function C4:AddVariable(n, v) vars[n] = v end
function C4:SetVariable(n, v) vars[n] = v end
function C4:Hash(alg, s) return md5.sumhexa(s) end
function C4:Base64Encode(s) return "b64(" .. s .. ")" end
function C4:ErrorLog(m) print("ERRORLOG " .. m) end
function C4:DebugLog(m) end
function C4:GetTemperatureScale() return "FAHRENHEIT" end
function C4:url()
  local o = { opts = {} }
  function o:SetOptions(x) self.opts = x; return self end
  function o:OnDone(fn) self.done = fn; return self end
  local function go(self, method, url, body, headers)
    addTimer(50, function()
      if failNetwork then self.done(self, {}, 7, "Couldn't connect"); return end
      local r = serve(method, url, body, headers)
      self.done(self, { r }, 0, nil)
    end)
    return self
  end
  function o:Get(url, h) return go(self, "GET", url, nil, h) end
  function o:Post(url, b, h) return go(self, "POST", url, b, h) end
  return o
end

Properties = {
  ["IP Address"] = "", ["Use HTTPS"] = "No", ["Username"] = "", ["Password"] = "", ["Screen Lock PIN"] = "",
  ["Poll Interval (seconds)"] = "30", ["Humidity Control"] = "Off", ["Outdoor Temperature"] = "Auto",
  ["Debug Mode"] = "Off", ["Debug Level"] = "3 - Info",
}

local function run(ms)
  local stop = NOW + ms
  while true do
    table.sort(timers, function(a, b) return a.at < b.at end)
    local nextT
    for _, t in ipairs(timers) do if t.live and t.at <= stop then nextT = t break end end
    if not nextT then break end
    NOW = nextT.at
    if nextT.rep then nextT.at = NOW + nextT.ms else nextT.live = false end
    nextT.fn(nextT, 0)
    local live = {}
    for _, t in ipairs(timers) do if t.live then live[#live + 1] = t end end
    timers = live
  end
  NOW = stop
end

local function lastNotify(cmd)
  for i = #notifies, 1, -1 do if notifies[i].cmd == cmd and notifies[i].id == 5001 then return notifies[i].params end end
end
local function countPosts() return #T.posts end

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1; print("PASS " .. name)
  else failed = failed + 1; print("FAIL " .. name .. (extra and (" :: " .. tostring(extra)) or "")) end
end

-- Load driver ------------------------------------------------------------
resetThermostat()
dofile(DRIVER)
local X = _VENSTAR_TEST
OnDriverInit()
OnDriverLateInit()
check("unconfigured status", (props["Driver Status"] or ""):find("Not configured"))

Properties["IP Address"] = "192.168.1.50"
OnPropertyChanged("IP Address")
run(5000)

check("connected notify", lastNotify("CONNECTION") and lastNotify("CONNECTION").CONNECTED == "true")
check("temperature", lastNotify("TEMPERATURE_CHANGED").TEMPERATURE == "71" and lastNotify("TEMPERATURE_CHANGED").SCALE == "F")
check("heat sp", lastNotify("HEAT_SETPOINT_CHANGED").SETPOINT == "68")
check("cool sp", lastNotify("COOL_SETPOINT_CHANGED").SETPOINT == "75")
check("hvac mode", lastNotify("HVAC_MODE_CHANGED").MODE == "Heat")
check("fan mode", lastNotify("FAN_MODE_CHANGED").MODE == "Auto")
check("hvac state", lastNotify("HVAC_STATE_CHANGED").STATE == "Idle")
check("hold", lastNotify("HOLD_MODE_CHANGED").MODE == "Off")
check("allowed modes", lastNotify("ALLOWED_HVAC_MODES_CHANGED").MODES == "Off,Heat,Cool,Auto")
check("allowed holds", lastNotify("ALLOWED_HOLD_MODES_CHANGED").MODES == "Off,Permanent,Away")
check("humidity", lastNotify("HUMIDITY_CHANGED").HUMIDITY == "45")
check("outdoor", lastNotify("OUTDOOR_TEMPERATURE_CHANGED") and lastNotify("OUTDOOR_TEMPERATURE_CHANGED").TEMPERATURE == "52")
check("scale F", lastNotify("SCALE_CHANGED").SCALE == "F")
check("model prop", props["Model"] == "COLORTOUCH")
check("sensors prop", (props["Sensors"] or ""):find("SENSOR0729"), props["Sensors"])
local capsSeen = false
for _, n in ipairs(notifies) do if n.cmd == "DYNAMIC_CAPABILITIES_CHANGED" and n.params.HEAT_SETPOINT_MAX_F == 99 then capsSeen = true end end
check("setpoint range caps", capsSeen)

-- Setpoint via proxy (Fahrenheit param) ----------------------------------
local p0 = countPosts()
ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = "21.1", FAHRENHEIT = "70", KELVIN = "294.2" })
run(3000)
check("one setpoint POST", countPosts() == p0 + 1, countPosts() - p0)
check("setpoint body", T.posts[#T.posts] == "/control heattemp=70&cooltemp=75", T.posts[#T.posts])
check("thermostat heat=70", T.info.heattemp == 70)

-- Rapid increments coalesce ----------------------------------------------
p0 = countPosts()
ReceivedFromProxy(5001, "INC_SETPOINT_COOL", {})
run(200)
ReceivedFromProxy(5001, "INC_SETPOINT_COOL", {})
run(200)
ReceivedFromProxy(5001, "INC_SETPOINT_COOL", {})
run(4000)
check("coalesced POST", countPosts() == p0 + 1, countPosts() - p0)
check("cool now 78", T.info.cooltemp == 78, T.info.cooltemp)

-- Delta enforcement: heat raised above cool - delta pushes cool --------
ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { FAHRENHEIT = "78" })
run(4000)
check("delta pushes cool", T.info.heattemp == 78 and T.info.cooltemp == 80, T.info.heattemp .. "/" .. T.info.cooltemp)

-- Pending setpoint then mode: two separate POSTs, setpoints first -------
p0 = countPosts()
ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { FAHRENHEIT = "77" })
run(100)
ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Auto" })
run(5000)
check("two POSTs", countPosts() == p0 + 2, countPosts() - p0)
check("setpoint POST first", (T.posts[p0 + 1] or ""):find("^/control heattemp="), T.posts[p0 + 1])
check("mode POST second", (T.posts[p0 + 2] or ""):find("^/control mode=3&heattemp="), T.posts[p0 + 2])
check("mode auto", T.info.mode == 3 and lastNotify("HVAC_MODE_CHANGED").MODE == "Auto")
check("cool pulled heat down", T.info.cooltemp == 77 and T.info.heattemp == 75, T.info.heattemp .. "/" .. T.info.cooltemp)

-- Fan -------------------------------------------------------------------
ReceivedFromProxy(5001, "SET_MODE_FAN", { MODE = "On" })
run(3000)
check("fan POST alone", T.posts[#T.posts] == "/control fan=1" and T.info.fan == 1, T.posts[#T.posts])

-- Hold: Away from running schedule, then back to Off --------------------
p0 = countPosts()
ReceivedFromProxy(5001, "SET_MODE_HOLD", { MODE = "Away" })
run(4000)
check("away sequence", T.posts[p0 + 1] == "/settings schedule=0" and T.posts[p0 + 2] == "/settings away=1",
  tostring(T.posts[p0 + 1]) .. " | " .. tostring(T.posts[p0 + 2]))
check("away state", T.info.away == 1 and lastNotify("HOLD_MODE_CHANGED").MODE == "Away")
local sawAwayEvent = false
for _, e in ipairs(events) do if e == "Away Mode On" then sawAwayEvent = true end end
check("away event", sawAwayEvent)
p0 = countPosts()
ReceivedFromProxy(5001, "SET_MODE_HOLD", { MODE = "Off" })
run(4000)
check("resume sequence", T.posts[p0 + 1] == "/settings away=0" and T.posts[p0 + 2] == "/settings schedule=1",
  tostring(T.posts[p0 + 1]) .. " | " .. tostring(T.posts[p0 + 2]))
check("hold off", T.info.schedule == 1 and T.info.away == 0 and lastNotify("HOLD_MODE_CHANGED").MODE == "Off")
ReceivedFromProxy(5001, "SET_MODE_HOLD", { MODE = "Permanent" })
run(4000)
check("permanent", T.info.schedule == 0 and lastNotify("HOLD_MODE_CHANGED").MODE == "Permanent")

-- Programming command toggle --------------------------------------------
ExecuteCommand("Set Away Mode", { State = "Toggle" })
run(4000)
check("toggle away on", T.info.away == 1)

-- Humidity --------------------------------------------------------------
Properties["Humidity Control"] = "Humidify and Dehumidify"
OnPropertyChanged("Humidity Control")
run(1000)
ReceivedFromProxy(5001, "SET_SETPOINT_HUMIDIFY", { SETPOINT = "40" })
run(3000)
check("humidify POST", T.posts[#T.posts] == "/settings tempunits=0&hum_setpoint=40&dehum_setpoint=55", T.posts[#T.posts])
check("humidify notify", lastNotify("HUMIDIFY_SETPOINT_CHANGED").SETPOINT == "40")

-- Alerts ----------------------------------------------------------------
T.alerts.alerts[1].active = true
ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_NOW" })
run(5000)
local sawFilter = false
for _, e in ipairs(events) do if e == "Air Filter Alert" then sawFilter = true end end
check("filter alert event", sawFilter)
check("filter prop", props["Air Filter Alert"] == "ACTIVE")


-- Extras ---------------------------------------------------------------
do
  local setup, state
  for _, n in ipairs(notifies) do
    if n.cmd == "EXTRAS_SETUP_CHANGED" then setup = n.params.XML end
    if n.cmd == "EXTRAS_STATE_CHANGED" then state = n.params.XML end
  end
  check("extras setup sent", setup ~= nil)
  local f = io.open("extras_setup.xml", "w"); f:write(setup or ""); f:close()
  check("extras has sensors section", setup and setup:find('<section label="Sensors">', 1, true))
  check("extras has alerts section", setup and setup:find('<section label="Alerts">', 1, true))
  check("extras remote sensor row", setup and setup:find('SENSOR0729 (Remote) Temperature', 1, true))
  local hasExtrasCap = false
  for _, n in ipairs(notifies) do if n.cmd == "DYNAMIC_CAPABILITIES_CHANGED" and n.params.HAS_EXTRAS == true then hasExtrasCap = true end end
  check("HAS_EXTRAS capability", hasExtrasCap)
  T.sensors.sensors[3].temp = 66
  local before = #notifies
  ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_NOW" })
  run(5000)
  local st
  for i = before + 1, #notifies do if notifies[i].cmd == "EXTRAS_STATE_CHANGED" then st = notifies[i].params.XML end end
  check("extras state update", st and st:find('id="sSENSOR0729Temp" value="66°F"', 1, true), st)
  local f2 = io.open("extras_state.xml", "w"); f2:write(st or ""); f2:close()
end

-- Offline / restore -----------------------------------------------------
failNetwork = true
run(120000)
check("offline", lastNotify("CONNECTION").CONNECTED == "false")
failNetwork = false
run(40000)
check("restored", lastNotify("CONNECTION").CONNECTED == "true")
local lost, restored = false, false
for _, e in ipairs(events) do
  if e == "Communication Lost" then lost = true end
  if e == "Communication Restored" then restored = true end
end
check("comm events", lost and restored)

-- Rejected command does not mark offline --------------------------------
ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Bogus" })
run(2000)
check("still online", lastNotify("CONNECTION").CONNECTED == "true")

-- Celsius thermostat, setpoints in C ------------------------------------
resetThermostat({ tempunits = 1, spacetemp = 21.5, heattemp = 20, cooltemp = 24, hmin = 2, hmax = 37, cmin = 2, cmax = 37, delta = 1 })
Properties["IP Address"] = "192.168.1.51"
OnPropertyChanged("IP Address")
run(5000)
check("C temperature", lastNotify("TEMPERATURE_CHANGED").TEMPERATURE == "21.5" and lastNotify("TEMPERATURE_CHANGED").SCALE == "C")
check("C scale", lastNotify("SCALE_CHANGED").SCALE == "C")
ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = "21.3", FAHRENHEIT = "70.3" })
run(3000)
check("C half-degree rounding", T.posts[#T.posts] == "/control heattemp=21.5&cooltemp=24", T.posts[#T.posts])

-- T3900 old firmware reports C regardless of display units --------------
resetThermostat({ model = "T3900", firmware = "5.10", tempunits = 0, spacetemp = 22, heattemp = 20, cooltemp = 24, hmin = 2, hmax = 37, cmin = 2, cmax = 37 })
Properties["IP Address"] = "192.168.1.52"
OnPropertyChanged("IP Address")
run(5000)
check("T3 old fw uses C", lastNotify("TEMPERATURE_CHANGED").SCALE == "C" and props["API Temperature Units"] == "Celsius")

-- Commercial: hold list without Away -----------------------------------
resetThermostat({ type = "commercial" })
Properties["IP Address"] = "192.168.1.53"
OnPropertyChanged("IP Address")
run(5000)
check("commercial holds", lastNotify("ALLOWED_HOLD_MODES_CHANGED").MODES == "Off,Permanent")

-- availablemodes heat only ---------------------------------------------
resetThermostat({ availablemodes = 2 })
Properties["IP Address"] = "192.168.1.54"
OnPropertyChanged("IP Address")
run(5000)
check("heat-only modes", lastNotify("ALLOWED_HVAC_MODES_CHANGED").MODES == "Off,Heat")

-- Digest auth -----------------------------------------------------------
resetThermostat({ digest = true })
Properties["Use HTTPS"] = "Yes"
Properties["Username"] = "admin"
Properties["Password"] = "secret"
OnPropertyChanged("Use HTTPS")
run(5000)
check("digest connected", lastNotify("CONNECTION").CONNECTED == "true" and lastNotify("TEMPERATURE_CHANGED").TEMPERATURE == "71")
ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { FAHRENHEIT = "66" })
run(3000)
check("digest POST", T.info.heattemp == 66)

-- PIN -------------------------------------------------------------------
resetThermostat({ pin = "0042" })
Properties["Use HTTPS"] = "No"; Properties["Username"] = ""; Properties["Password"] = ""
Properties["Screen Lock PIN"] = "42"
OnPropertyChanged("Use HTTPS")
run(5000)
ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Cool" })
run(3000)
check("PIN padded + accepted", T.info.mode == 2)

-- Bad password ---------------------------------------------------------
resetThermostat({ digest = true })
Properties["Screen Lock PIN"] = ""
Properties["Username"] = "admin"; Properties["Password"] = "wrong"
OnPropertyChanged("IP Address")
run(120000)
check("auth failure reported", (props["Driver Status"] or ""):find("Authentication") or (props["Driver Status"] or ""):find("401"), props["Driver Status"])

-- JSON decoder edge cases ---------------------------------------------
local J = X.Json
local d = J.decode('{"a":[1,2.5,-3e2],"b":"x\\"y\\u0041","c":true,"d":null,"e":{}}')
check("json", d.a[3] == -300 and d.b == 'x"yA' and d.c == true and d.e and next(d.e) == nil)

-- Notification budget: a steady poll must not resend unchanged values --
local before = #notifies
run(60000)
local resent = 0
for i = before + 1, #notifies do if notifies[i].cmd == "TEMPERATURE_CHANGED" then resent = resent + 1 end end
check("no duplicate notifies", resent == 0, resent)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
