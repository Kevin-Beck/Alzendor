#!lua name=alzendor
-- Alzendor's game rules, run atomically inside Redis.
--
-- Each registered function is one thing that can happen in the world. It checks
-- the world state, changes it, and appends the resulting events to channel
-- streams in a single step, so no other action can interleave with it.
--
-- Every event's stream ID is the next value of one global counter (alz:seq).
-- Events across all channels therefore share a single total order, and every
-- server and client sees them in exactly that order.
--
-- Subscriptions are state too: PLAYER:<id>:subs maps each channel a player is
-- subscribed to onto the sequence number they joined it at. Whenever a function
-- changes subscriptions it also appends a `control` event to the player's own
-- stream, and the server reading that stream applies the change at precisely
-- that point in the sequence (see alzendor/feed.py).

local MAXLEN = 1000

-- JSON ------------------------------------------------------------------------
-- Redis' cjson encodes an empty table as {}, so lists are marked explicitly.

local ARRAY = {}
local function list(t) return setmetatable(t or {}, ARRAY) end

local function encode(v)
  if type(v) ~= 'table' then return cjson.encode(v) end
  local parts = {}
  if getmetatable(v) == ARRAY then
    for i = 1, #v do parts[i] = encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  for k, x in pairs(v) do
    parts[#parts + 1] = cjson.encode(tostring(k)) .. ':' .. encode(x)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- Helpers ---------------------------------------------------------------------

local function hgetall(key)
  local flat, t = redis.call('HGETALL', key), {}
  for i = 1, #flat, 2 do t[flat[i]] = flat[i + 1] end
  return t
end

local function sorted(t)
  table.sort(t)
  return t
end

local function now_ms()
  local t = redis.call('TIME')
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function name_of(pid)
  return redis.call('HGET', 'ACCOUNT:' .. pid, 'name') or pid
end

local function current_seq()
  return tonumber(redis.call('GET', 'alz:seq')) or 0
end

-- Appends an event to a channel's stream and returns its sequence number.
local function emit(channel, event)
  local seq = redis.call('INCR', 'alz:seq')
  event.channel = channel
  if event.actor and not event.name then event.name = name_of(event.actor) end
  event.ts = math.floor(now_ms() / 1000)
  redis.call('XADD', channel, 'MAXLEN', '~', MAXLEN, seq .. '-0', 'e', encode(event))
  return seq
end

local function notice(pid, text)
  return emit('PLAYER:' .. pid, {type = 'system', text = text})
end

local function capitalize(text)
  return (string.gsub(text, '^%l', string.upper))
end

local function round(x)
  if x >= 0 then return math.floor(x + 0.5) end
  return -math.floor(-x + 0.5)
end

local function signed(n)
  return (n > 0 and '+' or '') .. n
end

local function decode(json)
  if not json or json == '' then return {} end
  return cjson.decode(json)
end

-- A tunable number from the seed's "rules" (alz:rules), or the default.
local function rule(name, default)
  return tonumber(redis.call('HGET', 'alz:rules', name)) or default
end

local function fill(template, actor, target)
  local s = string.gsub(template, '{actor}', function() return actor end)
  s = string.gsub(s, '{target}', function() return target or '' end)
  return s
end

-- Entities --------------------------------------------------------------------
-- Players and NPCs share one card shape, shown in a room's "Here" list.
-- Their ids are 'pc:<player>' and 'npc:<npc>'.

-- Stats are deliberately plain: everyone wants them, and you choose where your
-- points go. Gear and abilities are what make characters different.
local STATS = {'vigor', 'poise', 'focus', 'presence', 'resilience'}
local STAT_INFO = {
  vigor = 'Vigor: 8 more max health per point.',
  poise = 'Poise: timing windows 15 ms wider per point.',
  focus = 'Focus: perfect windows 10 ms wider per point.',
  presence = 'Presence: your deeds move reputation 15% further per point.',
  resilience = 'Resilience: softens what bad weather does to you by 10% per point (up to 50%), and keeps the good.',
}
local BASE_HP, VIGOR_HP = 100, 8

local function trained(pid, name)
  return tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'stat:' .. name)) or 0
end

-- Faction boons: stat bonuses while a player's standing with a faction is at
-- or above a threshold. alz:boons maps each stat onto its boons (JSON).
local function boons_for(pid, name)
  local out = list()
  for _, b in ipairs(decode(redis.call('HGET', 'alz:boons', name))) do
    local rep = hgetall('PLAYER:' .. pid .. ':rep:' .. b.faction)
    b.active = (tonumber(rep.affinity) or 0) >= (b.affinity or -100) and (tonumber(rep.respect) or 0) >= (b.respect or -100)
    b.stat = name
    out[#out + 1] = b
  end
  return out
end

-- A stat as it counts everywhere: trained points plus active boons.
local function stat(pid, name)
  local value = trained(pid, name)
  for _, b in ipairs(boons_for(pid, name)) do
    if b.active then value = value + (b.amount or 1) end
  end
  return value
end

local function max_hp_of(pid)
  return BASE_HP + VIGOR_HP * stat(pid, 'vigor')
end

local function level_of(pid)
  return tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'level')) or 1
end

local function xp_needed(level)
  return 100 * level
end

local function player_card(pid)
  local account = hgetall('ACCOUNT:' .. pid)
  local max_hp = max_hp_of(pid)
  return {
    id = 'pc:' .. pid, kind = 'pc', name = account.name or pid, label = 'Adventurer',
    description = account.description or 'An ordinary traveller.',
    hp = math.min(tonumber(account.hp) or max_hp, max_hp), max_hp = max_hp,
    level = tonumber(account.level) or 1, asleep = account.asleep == '1',
  }
end

local function npc_attacks(nid)
  return decode(redis.call('HGET', 'NPC:' .. nid, 'attacks'))
end

-- NPCs also carry their nature (base_disposition: hostile, neutral or
-- friendly); how one treats a particular player is sent to that player alone.
local function npc_card(nid)
  local npc = hgetall('NPC:' .. nid)
  local max_hp = tonumber(npc.max_hp) or 10
  local attacks = list()
  for _, a in ipairs(decode(npc.attacks)) do
    attacks[#attacks + 1] = {name = a.name, period_ms = a.period, damage = a.damage}
  end
  local faction = (npc.faction or '') ~= '' and redis.call('HGET', 'FACTION:' .. npc.faction, 'name')
  return {
    id = 'npc:' .. nid, kind = 'npc', name = npc.name or nid, label = npc.label or '',
    description = npc.description or '', hp = tonumber(npc.hp) or max_hp, max_hp = max_hp,
    icon = (npc.icon or '') ~= '' and npc.icon or nil, base_disposition = npc.disposition or 'neutral',
    faction = faction or nil, attacks = attacks, immortal = npc.immortal == '1',
  }
end

-- A fighting NPC's attacks and when each lands next, or nil if it isn't fighting.
local function npc_fight(nid)
  local due = hgetall('NPC:' .. nid .. ':next')
  if not next(due) then return nil end
  local attacks = list()
  for i, a in ipairs(npc_attacks(nid)) do
    attacks[i] = {name = a.name, period_ms = a.period, damage = a.damage, next_ms = tonumber(due[tostring(i)])}
  end
  local target = redis.call('ZRANGE', 'NPC:' .. nid .. ':foes', 0, 0)[1]
  return {attacks = attacks, target = target and ('pc:' .. target) or nil}
end

-- How an NPC is named mid-sentence: "Brannoc", or "the Orc Warrior".
local function npc_display(nid)
  local npc = hgetall('NPC:' .. nid)
  return npc.proper == '1' and npc.name or ('the ' .. (npc.name or nid))
end

local function by_card_order(a, b)
  if a.kind ~= b.kind then return a.kind == 'npc' end
  if a.name ~= b.name then return a.name < b.name end
  return a.id < b.id
end

-- Weather -----------------------------------------------------------------------
-- Three numbers from -1 to 1: temperature (cold to hot), energy (dead still to
-- chaos) and precipitation (dry below 0, wetter above). See docs/weather.md.
--
-- Each realm has one sky, a pure function of time: each axis sums five sine
-- waves (drawn from the seed by alzendor/weather.py and stored as JSON in
-- REALM:<id>:info.waves), evens the sum out to -1..1 with its measured
-- quantiles, and (temperature and energy) stretches it so a third of the time
-- is temperate. Indoor rooms are always dead neutral and dry; a room or area
-- with a `climate` (a lair, a forge of the gods) is fixed at that instead.
-- Other rooms take their realm's sky nudged by their terrain. An admin
-- override (alz:weather_override:<realm>) pins a realm's sky.

local AXES = {'temperature', 'energy', 'precipitation'}
local CENTER = 0.5773502691896258 -- sqrt(1/3): math is off limits while the library loads

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- Weather time: real time in units of weather_unit_minutes.
local function weather_time(ms)
  return (ms or now_ms()) / (rule('weather_unit_minutes', 30) * 60000)
end

-- The sum of an axis's waves at t, spread evenly over -1..1.
local function evened(axis, t)
  local r = 0
  for k = 1, #axis.a do r = r + axis.a[k] * math.sin(axis.w[k] * t + axis.phase[k]) end
  local q = axis.q
  if r <= q[1] then return -1 end
  if r >= q[#q] then return 1 end
  local lo, hi = 1, #q
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if q[mid] <= r then lo = mid else hi = mid end
  end
  local span = q[lo + 1] - q[lo]
  local f = (lo - 1 + (span > 0 and (r - q[lo]) / span or 0)) / (#q - 1)
  return 2 * f - 1
end

-- Sends the middle 57.7% of -1..1 to -0.5..0.5, and the rest to the outer bands.
local function stretch(u)
  local m = math.abs(u)
  local x = m < CENTER and m / (2 * CENTER) or 0.5 + (m - CENTER) / (2 * (1 - CENTER))
  return u < 0 and -x or x
end

local INDOORS = {temperature = 0, energy = 0, precipitation = -1}

-- A realm's sky, before terrain. The realm also moves and narrows it: each
-- axis becomes centre + spread x value (REALM:<id>:info.weather, {axis: [c, s]}).
local function realm_place(realm)
  return {realm = realm, params = realm and decode(redis.call('HGET', 'REALM:' .. realm .. ':info', 'waves')) or {},
    pinned = realm and hgetall('alz:weather_override:' .. realm) or {}, nudge = {},
    bias = realm and decode(redis.call('HGET', 'REALM:' .. realm .. ':info', 'weather')) or {}}
end

-- What decides a room's weather, read once so forecasts can reuse it.
local function place_of(rid)
  local info = hgetall('ROOM:' .. rid .. ':info')
  local area = info.area and hgetall('AREA:' .. info.area .. ':info') or {}
  local realm = area.region and redis.call('HGET', 'REGION:' .. area.region .. ':info', 'realm')
  local climate = (info.climate or '') ~= '' and decode(info.climate) or ((area.climate or '') ~= '' and decode(area.climate) or nil)
  if not climate and info.indoor == '1' then climate = INDOORS end
  if climate then return {rid = rid, name = info.name, region = area.region, realm = realm, climate = climate} end
  local place = realm_place(realm)
  place.rid, place.name, place.region = rid, info.name, area.region
  place.nudge = decode(redis.call('HGET', 'alz:terrain_weather', (info.terrain or '') ~= '' and info.terrain or '-'))
  return place
end

-- The weather in a place at weather time t (default now).
local function weather_in(place, t)
  local w
  if place.climate then
    w = {indoor = true}
    for _, axis in ipairs(AXES) do w[axis] = tonumber(place.climate[axis]) or 0 end
  elseif place.pinned.temperature then
    w = {}
    for _, axis in ipairs(AXES) do w[axis] = tonumber(place.pinned[axis]) or 0 end
  elseif place.params.temperature then
    t = t or weather_time()
    w = {temperature = stretch(evened(place.params.temperature, t)), energy = stretch(evened(place.params.energy, t)),
      precipitation = evened(place.params.precipitation, t)}
    for axis, bias in pairs(place.bias or {}) do
      if w[axis] then w[axis] = clamp(bias[1] + bias[2] * w[axis], -1, 1) end
    end
  else
    w = {temperature = 0, energy = 0, precipitation = -1}
  end
  if not w.indoor then
    for _, axis in ipairs(AXES) do w[axis] = clamp(w[axis] + (tonumber(place.nudge[axis]) or 0), -1, 1) end
  end
  w.region, w.realm = place.region, place.realm
  return w
end

local function weather_at(rid, t)
  return weather_in(place_of(rid), t)
end

-- How hard it's coming down: p squared while wet, so a deluge is rare.
local function intensity(w)
  return w.precipitation > 0 and w.precipitation * w.precipitation or 0
end

-- What's falling: 'rain', 'snow', 'hail', or nil when dry.
local function falling(w)
  if w.precipitation <= 0 then return nil end
  if w.temperature < -0.15 then return w.energy > 0.5 and 'hail' or 'snow' end
  return 'rain'
end

-- In heavy rain or snow you can't see far: no new exits, glimpses or regions.
local function can_see(w)
  return w.indoor or intensity(w) < 0.5
end

-- The named corner of the temperature/energy grid, or 'Temperate', or nil.
local function zone(w)
  local x, y = w.temperature, w.energy
  if math.abs(x) < 0.5 and math.abs(y) < 0.5 then return 'Temperate' end
  if x > 0.5 and y < -0.5 then return 'Scorch' end
  if x > 0.5 and y > 0.5 then return 'Tempest' end
  if x < -0.5 and y > 0.5 then return 'Gale' end
  if x < -0.5 and y < -0.5 then return 'Rime' end
end

-- Words for an axis. The cuts line up with the zones: only past ±0.5 (outside
-- Temperate) is it hot, cold, still or stormy.
local function band(v, words)
  local cuts = {-0.75, -0.5, -0.2, 0.2, 0.5, 0.75}
  for i, cut in ipairs(cuts) do
    if v < cut then return words[i] end
  end
  return words[7]
end

local function heat_word(w)
  return band(w.temperature, {'freezing', 'cold', 'cool', 'mild', 'warm', 'hot', 'scorching'})
end

local function wind_word(w)
  return band(w.energy, {'dead still', 'still', 'quiet', 'breezy', 'gusty', 'stormy', 'howling'})
end

local function sky_words(w)
  local kind, amount = falling(w), intensity(w)
  if not kind then return w.precipitation < -0.6 and 'bone dry' or 'dry' end
  if amount < 0.15 then return 'light ' .. kind end
  if amount < 0.5 then return kind end
  if amount < 0.8 then return 'heavy ' .. kind end
  return 'driving ' .. kind
end

-- "hot and gusty, light rain"
local function describe_weather(w)
  return heat_word(w) .. ' and ' .. wind_word(w) .. ', ' .. sky_words(w)
end

-- Snow and mud: what weather leaves on the ground, per realm, 0..1. Brought
-- up to date by weather_tick from however long it's been (at most 4 units).
local function ground_of(realm)
  local g = realm and hgetall('REALM:' .. realm .. ':ground') or {}
  return {snow = tonumber(g.snow) or 0, mud = tonumber(g.mud) or 0}
end

local function update_ground(realm, now)
  local key = 'REALM:' .. realm .. ':ground'
  local g = hgetall(key)
  local snow, mud, at = tonumber(g.snow) or 0, tonumber(g.mud) or 0, tonumber(g.at)
  if at then
    local dt = math.min(weather_time(now) - weather_time(at), 4)
    if dt > 0 then
      local w = weather_in(realm_place(realm), weather_time(now))
      local kind, amount = falling(w), intensity(w)
      if kind == 'rain' then mud = mud + 0.5 * amount * dt elseif kind then snow = snow + 0.6 * amount * dt end
      if w.temperature > 0 then
        local melt = math.min(snow, 0.5 * w.temperature * dt)
        snow, mud = snow - melt, mud + 0.5 * melt
      end
      if w.precipitation <= 0 then mud = mud - (0.15 + 0.25 * math.max(0, w.temperature)) * dt end
    end
  end
  redis.call('HSET', key, 'snow', clamp(snow, 0, 1), 'mud', clamp(mud, 0, 1), 'at', now)
end

-- Resilience softens weather penalties: 10% a point, up to half.
local function resilience(pid)
  return math.min(0.5, 0.1 * stat(pid, 'resilience'))
end

local function soften(factor, r)
  if factor >= 1 then return factor end
  return 1 - (1 - factor) * (1 - r)
end

-- How long deep ground holds up a move between two rooms, and what's doing it.
local function travel_delay(pid, from, to)
  local worst, cause = 0, nil
  for _, rid in ipairs({from, to}) do
    local place = place_of(rid)
    if not place.climate then
      local g = ground_of(place.realm)
      if g.snow * 3000 > worst then worst, cause = g.snow * 3000, 'snow' end
      if g.mud * 1500 > worst then worst, cause = g.mud * 1500, 'mud' end
    end
  end
  worst = math.floor(worst * (1 - resilience(pid)))
  if worst < 250 then return 0 end
  return worst, cause
end

-- Gear weather profiles ---------------------------------------------------------
-- Each piece of gear has a spot on the temperature/energy grid where it works
-- best, wants wet, dry or any weather, and has a tier saying how much it
-- depends on all that. Gear without a profile uses its kind's (alz:kinds).

local TIERS = {
  grey = {peak = 0.15, far = 0.15, radius = 2.0, wet = 0.10},
  green = {peak = 0.25, far = 0.20, radius = 1.5, wet = 0.15},
  blue = {peak = 0.40, far = 0.30, radius = 1.1, wet = 0.20},
  purple = {peak = 0.60, far = 0.45, radius = 0.8, wet = 0.25},
  orange = {peak = 1.00, far = 1.00, radius = 0.5, wet = 0.30},
}

local function gear_profile(gear)
  local p = decode(gear.weather)
  if not p.tier then p = decode(redis.call('HGET', 'alz:kinds', gear.kind or '-')) end
  return {temperature = tonumber(p.temperature) or 0, energy = tonumber(p.energy) or 0,
    precipitation = p.precipitation or 'any', tier = TIERS[p.tier] and p.tier or 'grey'}
end

local function pct(factor)
  return round((factor - 1) * 100)
end

-- What weather w does to a player's gear: the factor on its amounts, its
-- adjusted timings, and one line per modifier for the tooltip.
local function weathered(pid, gear, w)
  local profile = gear_profile(gear)
  local tier, r = TIERS[profile.tier], resilience(pid)
  local mods = list()
  local d = math.sqrt((w.temperature - profile.temperature) ^ 2 + (w.energy - profile.energy) ^ 2)
  local c = math.max(0, 1 - d / tier.radius)
  local place = (1 - tier.far) + (tier.peak + tier.far) * c
  local where = c > 0.66 and 'at its best' or c > 0.33 and 'near its spot' or c > 0 and 'far from its spot' or 'out of its element'
  mods[#mods + 1] = {label = 'Weather: ' .. where, pct = pct(place)}
  local s = w.precipitation > 0 and intensity(w) or w.precipitation
  local wet = 1
  if profile.precipitation == 'wet' then wet = 1 + tier.wet * s elseif profile.precipitation == 'dry' then wet = 1 - tier.wet * s end
  if profile.precipitation ~= 'any' then
    mods[#mods + 1] = {label = capitalize(falling(w) or 'dry air') .. ' (it wants ' .. profile.precipitation .. ')', pct = pct(wet)}
  end
  local raw = place * wet
  local factor = soften(raw, r)
  local period, window, perfect = tonumber(gear.period), tonumber(gear.window), tonumber(gear.perfect_window)
  local heat = math.max(0, (w.temperature - 0.5) / 0.5) * (1 - r)
  local chaos = math.max(0, (w.energy - 0.5) / 0.5) * (1 - r)
  local still = math.max(0, (-w.energy - 0.5) / 0.5) * (1 - r)
  if heat > 0 then
    period = round(period * (1 + 0.3 * heat))
    mods[#mods + 1] = {label = 'Heat: beats slower', pct = round(30 * heat), on = 'period'}
  end
  if chaos > 0 then
    window = round(window * (1 - 0.3 * chaos))
    mods[#mods + 1] = {label = 'Wind: timing windows narrower', pct = -round(30 * chaos), on = 'window'}
  end
  if still > 0 then
    perfect = round(perfect * (1 - 0.3 * still))
    mods[#mods + 1] = {label = 'Stillness: perfect windows narrower', pct = -round(30 * still), on = 'perfect'}
  end
  if r > 0 and (raw < 1 or heat + chaos + still > 0) then
    mods[#mods + 1] = {label = 'Resilience ' .. stat(pid, 'resilience') .. ': penalties softened', pct = round(r * 100), on = 'resilience'}
  end
  local amounts = list()
  -- (The nudge keeps 10 x 1.15 from rounding down: in binary it's 11.4999...)
  for i, key in ipairs({'opener', 'good', 'perfect'}) do amounts[i] = math.max(0, round(tonumber(gear[key]) * factor + 1e-9)) end
  return {factor = factor, amounts = amounts, period = period, window = math.max(1, window), perfect = math.max(1, math.min(perfect, window)),
    mods = mods, profile = profile}
end

-- Weather lore: PLAYER:<id>:lore maps the realms whose skies a player can
-- read onto the faction of whoever taught them ('' for an item). Their
-- affinity with that faction sets how far ahead they see: 2 units (an hour),
-- +1 (30 min) per 10, up to 6.
local function forecast_units(pid, realm)
  local fid = realm and redis.call('HGET', 'PLAYER:' .. pid .. ':lore', realm)
  if not fid then return nil end
  local affinity = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':rep:' .. fid, 'affinity')) or 0
  return clamp(2 + math.floor(math.max(0, affinity) / 10), 2, 6)
end

local function round_to(v, step)
  return math.floor(v / step + 0.5) * step
end

-- Tells a player the weather where they are: exactly indoors or with lore,
-- roughly (to the nearest half) without, plus the forecast if they have one.
local function weather_event(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not rid then return end
  local place = place_of(rid)
  local w = weather_in(place)
  local units = not w.indoor and forecast_units(pid, w.realm) or nil
  local exact = w.indoor or units ~= nil
  local event = {type = 'weather', indoor = w.indoor or false, exact = exact, zone = zone(w), falling = falling(w),
    intensity = intensity(w), summary = describe_weather(w), visibility = can_see(w) and 'clear' or 'poor',
    place = w.indoor and place.name or (w.region and redis.call('HGET', 'REGION:' .. w.region .. ':info', 'name')) or place.name,
    realm = w.realm and redis.call('HGET', 'REALM:' .. w.realm .. ':info', 'name') or nil}
  for _, axis in ipairs(AXES) do event[axis] = exact and w[axis] or round_to(w[axis], 0.5) end
  if not w.indoor then event.ground = ground_of(w.realm) end
  if units then
    local now, forecast = weather_time(), list()
    for i = 1, units * 4 do
      local f = weather_in(place, now + i / 4)
      forecast[i] = {minutes = i * rule('weather_unit_minutes', 30) / 4, temperature = f.temperature, energy = f.energy,
        precipitation = f.precipitation, summary = describe_weather(f)}
    end
    event.forecast = forecast
  end
  return emit('PLAYER:' .. pid, event)
end

-- Map ---------------------------------------------------------------------------
-- Players see the rooms they have explored, faint outlines of the rooms those
-- lead to, the boxes of the areas they've been in, and the regions they know.
--
-- PLAYER:<id>:regions maps each region a player knows onto 'explored' (they
-- have set foot in it) or 'discovered' (they know it's there: it borders one
-- they've explored, or a map or their reputation told them). Regions missing
-- from it are unknown and never sent. Hidden regions are never discovered by
-- bordering; only maps and reputation reveal them.

-- Records a visit; true if the room is new to the player.
local function explore(pid, rid)
  return redis.call('SADD', 'PLAYER:' .. pid .. ':explored', rid) == 1
end

local function region_of(rid)
  local area = redis.call('HGET', 'ROOM:' .. rid .. ':info', 'area')
  return area and redis.call('HGET', 'AREA:' .. area .. ':info', 'region')
end

local function realm_of(rid)
  local region = region_of(rid)
  return region and redis.call('HGET', 'REGION:' .. region .. ':info', 'realm')
end

-- PLAYER:<id>:realms holds the realms a player has been to, for the map.
local function visit_realm(pid, rid)
  local realm = realm_of(rid)
  if realm then redis.call('SADD', 'PLAYER:' .. pid .. ':realms', realm) end
end

local function region_state(pid, gid)
  return gid and redis.call('HGET', 'PLAYER:' .. pid .. ':regions', gid)
end

-- What to type to take a route: TRAVEL and the name of where it goes. Commands
-- are shown in capitals and accepted in any case.
local function route_destination(route)
  return redis.call('HGET', 'ROOM:' .. route.to .. ':info', 'name') or route.to
end

local function route_command(route)
  return 'TRAVEL ' .. string.upper(route_destination(route))
end

-- Whether a typed phrase names a route: its destination, its id, its name, or
-- one of its keywords.
local function route_matches(route, phrase)
  local dest = string.lower(route_destination(route))
  if phrase == dest or phrase == string.gsub(dest, '^the ', '') or phrase == route.id then return true end
  local words = ' ' .. (route.keywords or '') .. ' ' .. string.lower(route.name or '') .. ' ' .. dest .. ' '
  return string.find(words, ' ' .. phrase .. ' ', 1, true) ~= nil
end

-- Routes (ferries, coaches, portals, gates) to a hidden region are only
-- offered once the player knows the region is there.
local function route_offered(pid, route)
  local area = redis.call('HGET', 'ROOM:' .. (route.to or '') .. ':info', 'area')
  local region = area and redis.call('HGET', 'AREA:' .. area .. ':info', 'region')
  if not region or redis.call('HGET', 'REGION:' .. region .. ':info', 'hidden') ~= '1' then return true end
  return region_state(pid, region) and true or false -- a missing field is false, not nil
end

-- Marks a region explored and, if the player can see, discovers the regions
-- bordering it (unless they're hidden). True if they learned anything new.
-- Called on every move, so borders missed in a storm are found once it clears.
local function explore_region(pid, gid, visible)
  local key = 'PLAYER:' .. pid .. ':regions'
  if not gid then return false end
  local changed = redis.call('HGET', key, gid) ~= 'explored'
  if changed then redis.call('HSET', key, gid, 'explored') end
  if visible then
    for _, other in ipairs(redis.call('SMEMBERS', 'REGION:' .. gid .. ':borders')) do
      if redis.call('HGET', 'REGION:' .. other .. ':info', 'hidden') ~= '1'
        and redis.call('HSETNX', key, other, 'discovered') == 1 then
        changed = true
      end
    end
  end
  return changed
end

-- Glimpses: PLAYER:<id>:glimpsed holds the unexplored rooms a player has seen
-- an exit lead to. You only see them when you can see (not in heavy rain or
-- snow), and you remember them after. True if any are new.
local function glimpse(pid, rid)
  local added = 0
  for _, dest in pairs(hgetall('ROOM:' .. rid .. ':exits')) do
    added = added + redis.call('SADD', 'PLAYER:' .. pid .. ':glimpsed', dest)
  end
  return added > 0
end

-- Makes unknown or hidden regions discovered; returns the names of the ones
-- that were new to the player.
local function discover_regions(pid, gids)
  local names = {}
  for _, gid in ipairs(gids) do
    if redis.call('EXISTS', 'REGION:' .. gid .. ':info') == 1
      and redis.call('HSETNX', 'PLAYER:' .. pid .. ':regions', gid, 'discovered') == 1 then
      names[#names + 1] = redis.call('HGET', 'REGION:' .. gid .. ':info', 'name') or gid
    end
  end
  return names
end

-- Players who explored before regions and glimpses were remembered learn them
-- from where they've been.
local function backfill_regions(pid)
  local rooms = redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':explored')
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':regions') == 0 then
    for _, rid in ipairs(rooms) do explore_region(pid, region_of(rid), true) end
  end
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':glimpsed') == 0 then
    for _, rid in ipairs(rooms) do glimpse(pid, rid) end
  end
end

local function room_pos(info)
  return list({tonumber(info.x) or 0, tonumber(info.y) or 0})
end

local function box(info)
  return list({tonumber(info.x1) or 0, tonumber(info.y1) or 0, tonumber(info.x2) or 0, tonumber(info.y2) or 0})
end

-- Sends the player map data for the given explored rooms, plus every region
-- they know (which always replaces the client's list). `full` replaces the
-- rooms and areas the client knows; otherwise they're merged in. Glimpses of
-- rooms in regions the player doesn't know are left out.
local function map_event(pid, rids, full)
  local rooms, areas, regions = list(), list(), list()
  local seen, seen_area, realm_of_area = {}, {}, {}
  -- Every room carries its realm, so the map can show one realm at a time.
  local function area_realm(aid)
    if aid and realm_of_area[aid] == nil then
      local region = redis.call('HGET', 'AREA:' .. aid .. ':info', 'region')
      realm_of_area[aid] = region and redis.call('HGET', 'REGION:' .. region .. ':info', 'realm') or false
    end
    return aid and realm_of_area[aid] or nil
  end
  for _, rid in ipairs(rids) do seen[rid] = true end
  for _, rid in ipairs(rids) do
    local info = hgetall('ROOM:' .. rid .. ':info')
    local exits = hgetall('ROOM:' .. rid .. ':exits')
    rooms[#rooms + 1] = {id = rid, name = info.name, area = info.area, realm = area_realm(info.area), pos = room_pos(info),
      exits = exits, explored = true}
    for _, dest in pairs(exits) do
      if not seen[dest] and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 0
        and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':glimpsed', dest) == 1 and region_state(pid, region_of(dest)) then
        seen[dest] = true
        local other = hgetall('ROOM:' .. dest .. ':info')
        rooms[#rooms + 1] = {id = dest, area = other.area, realm = area_realm(other.area), pos = room_pos(other), explored = false}
      end
    end
    if info.area and not seen_area[info.area] then
      seen_area[info.area] = true
      local area = hgetall('AREA:' .. info.area .. ':info')
      areas[#areas + 1] = {id = info.area, name = area.name, region = area.region, color = tonumber(area.color) or 1, bounds = box(area)}
    end
  end
  local known = hgetall('PLAYER:' .. pid .. ':regions')
  for _, gid in ipairs(sorted(redis.call('HKEYS', 'PLAYER:' .. pid .. ':regions'))) do
    local region = hgetall('REGION:' .. gid .. ':info')
    if region.name then
      regions[#regions + 1] = {id = gid, name = region.name, state = known[gid], bounds = box(region), realm = region.realm}
    end
  end
  -- The realms they've been to, so the map can switch between them.
  local realms = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':realms'))) do
    realms[#realms + 1] = {id = id, name = redis.call('HGET', 'REALM:' .. id .. ':info', 'name') or id}
  end
  -- Routes leaving rooms they've explored, drawn as dashed lines when both ends are known.
  local routes = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'alz:routes'))) do
    local route = hgetall('ROUTE:' .. id)
    if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', route.from) == 1 and route_offered(pid, route) then
      routes[#routes + 1] = {id = id, name = route.name, from = route.from, to = route.to}
    end
  end
  local here = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  return emit('PLAYER:' .. pid, {type = 'map', full = full, rooms = rooms, areas = areas, regions = regions,
    realms = realms, realm = here and realm_of(here) or nil, routes = routes})
end

local function full_map_event(pid)
  return map_event(pid, redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':explored'), true)
end

-- Tells a player about regions a map or their reputation revealed.
local function learn_regions(pid, gids, text)
  local names = discover_regions(pid, gids)
  if #names == 0 then return end
  notice(pid, (text or 'You learn of') .. ' ' .. table.concat(names, ', ') .. '. It is marked on your map.')
  full_map_event(pid)
end

-- Reveals regions gated on reputation once the player's standing is enough.
local function reveal_by_reputation(pid)
  for _, gid in ipairs(sorted(redis.call('SMEMBERS', 'alz:gated_regions'))) do
    if not region_state(pid, gid) then
      local gate = decode(redis.call('HGET', 'REGION:' .. gid .. ':info', 'reveal'))
      local rep = hgetall('PLAYER:' .. pid .. ':rep:' .. (gate.faction or ''))
      if (tonumber(rep.affinity) or 0) >= (gate.affinity or -100) and (tonumber(rep.respect) or 0) >= (gate.respect or -100) then
        discover_regions(pid, {gid})
        notice(pid, (gate.text or ('You hear talk of ' .. redis.call('HGET', 'REGION:' .. gid .. ':info', 'name') .. '.'))
          .. ' It is marked on your map.')
        full_map_event(pid)
      end
    end
  end
end

-- Subscriptions ---------------------------------------------------------------

-- The channels a player in this room is subscribed to, besides chat channels.
local function place_channels(pid, rid)
  local channels = {'PLAYER:' .. pid, 'ROOM:' .. rid}
  local area = redis.call('HGET', 'ROOM:' .. rid .. ':info', 'area')
  if area then
    channels[#channels + 1] = 'AREA:' .. area
    local region = redis.call('HGET', 'AREA:' .. area .. ':info', 'region')
    if region then
      channels[#channels + 1] = 'REGION:' .. region
      local realm = redis.call('HGET', 'REGION:' .. region .. ':info', 'realm')
      if realm then channels[#channels + 1] = 'REALM:' .. realm end
    end
  end
  return channels
end

local function minus(a, b)
  local skip, out = {}, {}
  for _, x in ipairs(b) do skip[x] = true end
  for _, x in ipairs(a) do
    if not skip[x] then out[#out + 1] = x end
  end
  return out
end

local function resubscribe(pid, add, remove)
  local subs = 'PLAYER:' .. pid .. ':subs'
  for _, c in ipairs(remove) do redis.call('HDEL', subs, c) end
  local seq = emit('PLAYER:' .. pid, {type = 'control', op = 'subs', add = list(add), remove = list(remove)})
  for _, c in ipairs(add) do redis.call('HSET', subs, c, seq) end
  return seq
end

-- Factions and reputation ------------------------------------------------------
-- An NPC can belong to a faction, and every faction keeps two separate opinions
-- of each player: affinity (do they like you?) and respect (do they rate you?).
-- Each faction's culture decides which deeds move which. Orcs may hate you for
-- hunting them yet respect a fair fight with their warriors; spiders respect
-- an ambush. A faction's rules (from the seed) each match a deed, optionally
-- only when the NPC involved belongs to a given faction (`of`) or has a given
-- `role`. PLAYER:<id>:rep:<faction> holds affinity and respect, -100 to 100.

local function rep_of(pid, fid)
  local rep = hgetall('PLAYER:' .. pid .. ':rep:' .. fid)
  return tonumber(rep.affinity) or 0, tonumber(rep.respect) or 0
end

local function affinity_label(a)
  if a <= -50 then return 'hated' elseif a <= -15 then return 'disliked'
  elseif a < 15 then return 'indifferent' elseif a < 50 then return 'liked' end
  return 'beloved'
end

local function respect_label(r)
  if r <= -50 then return 'contempt' elseif r <= -15 then return 'scorned'
  elseif r < 15 then return 'unproven' elseif r < 50 then return 'respected' end
  return 'honoured'
end

-- How an NPC treats this player: its own nature, shifted by its faction's
-- opinion. Respect alone can stay a hostile NPC's hand.
local function disposition_for(pid, nid)
  local npc = hgetall('NPC:' .. nid)
  local base = npc.disposition or 'neutral'
  if (npc.faction or '') == '' then return base end
  local a, r = rep_of(pid, npc.faction)
  if base == 'friendly' then return a <= -50 and 'hostile' or 'friendly' end
  if base == 'neutral' then
    if a <= -25 then return 'hostile' end
    return a >= 25 and 'friendly' or 'neutral'
  end
  if a >= 50 then return 'friendly' end
  if a >= 25 or r >= 30 then return 'neutral' end
  return 'hostile'
end

local function factions_of(pid)
  local out = list()
  for _, fid in ipairs(sorted(redis.call('SMEMBERS', 'alz:factions'))) do
    if redis.call('EXISTS', 'PLAYER:' .. pid .. ':rep:' .. fid) == 1 then
      local a, r = rep_of(pid, fid)
      local faction = hgetall('FACTION:' .. fid)
      out[#out + 1] = {id = fid, name = faction.name or fid, description = faction.description or '',
        realm = faction.realm, realm_name = faction.realm and redis.call('HGET', 'REALM:' .. faction.realm .. ':info', 'name'),
        affinity = a, respect = r, affinity_label = affinity_label(a), respect_label = respect_label(r)}
    end
  end
  -- Grouped by realm, the home realm first.
  local home = redis.call('GET', 'alz:home_realm')
  table.sort(out, function(x, y)
    if (x.realm == home) ~= (y.realm == home) then return x.realm == home end
    if (x.realm_name or '') ~= (y.realm_name or '') then return (x.realm_name or '') < (y.realm_name or '') end
    return x.name < y.name
  end)
  return out
end

-- Tells a player how each NPC in the room treats them.
local function dispositions_event(pid, rid)
  local map = {}
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do map['npc:' .. nid] = disposition_for(pid, nid) end
  return emit('PLAYER:' .. pid, {type = 'dispositions', dispositions = map})
end

-- Safe places: inns, shrines, camps. Leaving the world there is instant;
-- anywhere else you lie down to sleep and your body stays a while. Perks can
-- make a kind of terrain (forest, coast) safe for you.
local function is_safe(pid, rid)
  local info = hgetall('ROOM:' .. rid .. ':info')
  if info.safe == '1' then return true end
  if (info.terrain or '') == '' then return false end
  for _, perk in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks')) do
    if redis.call('HGET', 'PERK:' .. perk, 'safe_terrain') == info.terrain then return true end
  end
  return false
end

-- World views -----------------------------------------------------------------

-- cause: 'look', 'move', 'enter' or 'resume' (a reconnecting client's refresh).
local function room_event(pid, rid, cause)
  local info = hgetall('ROOM:' .. rid .. ':info')
  -- In heavy rain or snow, only the ways you already know show.
  local w = weather_at(rid)
  local exits, hidden = list(), false
  for _, dir in ipairs(sorted(redis.call('HKEYS', 'ROOM:' .. rid .. ':exits'))) do
    local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
    if can_see(w) or redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 1 then
      exits[#exits + 1] = dir
    else
      hidden = true
    end
  end
  local items, item_names = list(), {}
  for _, iid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':items')) do
    items[#items + 1] = {id = iid, name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid}
  end
  table.sort(items, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
  for i, item in ipairs(items) do item_names[i] = item.name end
  local features = sorted(list(redis.call('HKEYS', 'ROOM:' .. rid .. ':features')))
  local entities, entity_names = list(), {}
  for _, p in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':players')) do
    if p ~= pid then entities[#entities + 1] = player_card(p) end
  end
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
    local card = npc_card(nid)
    card.disposition, card.fight = disposition_for(pid, nid), npc_fight(nid)
    entities[#entities + 1] = card
  end
  table.sort(entities, by_card_order)
  for i, card in ipairs(entities) do entity_names[i] = card.name end
  local area = info.area and redis.call('HGET', 'AREA:' .. info.area .. ':info', 'name')

  local lines = {info.name or rid, info.description or ''}
  lines[#lines + 1] = 'Exits: ' .. (#exits > 0 and table.concat(exits, ', ') or 'none')
    .. (hidden and (' (the ' .. falling(w) .. ' hides any other ways on)') or '')
  local routes = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':routes'))) do
    local route = hgetall('ROUTE:' .. id)
    if route_offered(pid, route) then
      routes[#routes + 1] = {id = id, name = route.name, fare = tonumber(route.fare) or 0,
        to = route_destination(route), command = route_command(route)}
    end
  end
  if #routes > 0 then
    local names = {}
    for i, r in ipairs(routes) do names[i] = r.command .. ' (' .. r.name .. ')' end
    lines[#lines + 1] = 'Routes: ' .. table.concat(names, ', ') .. '. Type TRAVEL for details.'
  end
  if #items > 0 then lines[#lines + 1] = 'You see: ' .. table.concat(item_names, ', ') end
  if #entities > 0 then lines[#lines + 1] = 'Also here: ' .. table.concat(entity_names, ', ') end

  return emit('PLAYER:' .. pid, {
    type = 'room',
    cause = cause,
    room = {
      id = rid, name = info.name, description = info.description, area = area or nil,
      exits = exits, exits_hidden = hidden, routes = routes, items = items, features = features, entities = entities,
      self = player_card(pid), safe = is_safe(pid, rid), indoor = w.indoor or false,
    },
    text = table.concat(lines, '\n'),
  })
end

local function match_item(set_key, word)
  for _, iid in ipairs(redis.call('SMEMBERS', set_key)) do
    local item = hgetall('ITEM:' .. iid)
    local words = ' ' .. (item.keywords or '') .. ' ' .. string.lower(item.name or '') .. ' '
    if iid == word or string.find(words, ' ' .. word .. ' ', 1, true) then return iid, item end
  end
end

local function describe_player(pid)
  local card = player_card(pid)
  return card.name .. ', ' .. card.label .. '. ' .. card.description
end

local function describe_npc(nid)
  local npc = hgetall('NPC:' .. nid)
  if npc.details and npc.details ~= '' then return npc.details end
  return npc.name .. ', ' .. (npc.label or '') .. '. ' .. (npc.description or '')
end

-- Finds something the player can refer to from where they stand.
-- Returns kind, id, display name and description, or nothing.
local function resolve(pid, rid, word)
  -- An exact entity id, as sent by a client's selected target.
  local kind, id = string.match(word, '^(%a+):(.+)$')
  if kind == 'pc' and id == pid then
    return 'self', pid, name_of(pid), describe_player(pid)
  elseif kind == 'pc' then
    if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', id) == 1 then
      return 'player', id, name_of(id), describe_player(id)
    end
    return
  elseif kind == 'npc' then
    if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', id) == 1 then
      return 'npc', id, npc_display(id), describe_npc(id)
    end
    return
  end

  if word == 'me' or word == 'self' or word == pid then
    return 'self', pid, name_of(pid), describe_player(pid)
  end
  local feature = redis.call('HGET', 'ROOM:' .. rid .. ':features', word)
  if feature then return 'feature', word, 'the ' .. word, feature end
  local iid, item = match_item('ROOM:' .. rid .. ':items', word)
  if iid then return 'item', iid, 'the ' .. item.name, item.description end
  iid, item = match_item('PLAYER:' .. pid .. ':inv', word)
  if iid then return 'carried', iid, 'the ' .. item.name, item.description end
  for _, p in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':players')) do
    if p == word or string.lower(name_of(p)) == word then
      return 'player', p, name_of(p), describe_player(p)
    end
  end
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
    local npc = hgetall('NPC:' .. nid)
    local words = ' ' .. (npc.keywords or '') .. ' ' .. string.lower(npc.name or '') .. ' '
    if nid == word or string.find(words, ' ' .. word .. ' ', 1, true) then
      return 'npc', nid, npc_display(nid), describe_npc(nid)
    end
  end
end

-- Actions ---------------------------------------------------------------------

-- Wraps a player action: args[1] is always the player id, and the action only
-- runs while that player is in the world.
local function action(fn)
  return function(keys, args)
    local pid = args[1]
    if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 0 then return 0 end
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    if not rid then return 0 end
    fn(pid, rid, args)
    return 1
  end
end

-- Combat ----------------------------------------------------------------------
-- A player has three slots, and each holds one piece of gear: a weapon, a
-- spell, a potion. The game treats them all alike. Each piece of gear has its
-- own beat (`period` ms), timing window and amounts, and each slot keeps its
-- own rhythm. The first use of a slot lands at once and starts its rhythm.
-- After that its timing ball crosses the centre of its bar every period (a
-- "beat"), and a use only lands if it arrives within the gear's window around a
-- beat. Every attempt uses up a beat, hit or miss, and an attempt before the
-- next unused beat counts against that beat: mashing only burns beats. There
-- is no roll to hit: timing is the skill. Fitting three rhythms together is up
-- to the player.
-- A rhythm is the player's, not the fight's: it carries on across targets,
-- kills, leaving the room and reconnecting, and only ends after a timeout
-- without use. Otherwise stepping out and back in (or switching to a fresh
-- target) would give a free, instant opening action. For the same reason a
-- slot's gear can't be changed while its rhythm is running.
-- PLAYER:<id>:slots maps slot numbers onto gear ids. PLAYER:<id>:slot:<n>
-- holds the running rhythm: the gear's timings when it started, start (ms),
-- beat (the last one used) and last (ms of the last use).

local SLOTS = 3
local MIN_TIMEOUT_MS = 10000 -- a rhythm ends after this long unused, or two beats if longer

local function timeout_for(period)
  return math.max(MIN_TIMEOUT_MS, 2 * period)
end

local function gear_info(gid)
  if not gid then return nil end
  local gear = hgetall('GEAR:' .. gid)
  if not gear.name then return nil end
  gear.id = gid
  return gear
end

local function slot_gear(pid, n)
  return gear_info(redis.call('HGET', 'PLAYER:' .. pid .. ':slots', n))
end

local function slot_key(pid, n)
  return 'PLAYER:' .. pid .. ':slot:' .. n
end

-- A slot's rhythm if it's still running, else nil.
local function live_slot(pid, n, now)
  local state = hgetall(slot_key(pid, n))
  if state.last and now - tonumber(state.last) <= timeout_for(tonumber(state.period)) then return state end
end

-- "every 2.5s"
local function every(period)
  return 'every ' .. string.format('%.1f', period / 1000) .. 's'
end

-- Sends the player the state of one slot (inactive if `state` is nil).
local function timing_event(pid, n, state)
  local gear = slot_gear(pid, n)
  local event = {type = 'timing', slot = n, active = false, label = gear and gear.name or 'Empty'}
  if gear then
    event.gear, event.kind, event.period_ms = gear.id, gear.kind, tonumber(gear.period)
  end
  if state then
    local period = tonumber(state.period)
    event.active = true
    event.start_ms, event.period_ms = tonumber(state.start), period
    event.grace_ms, event.perfect_ms = tonumber(state.window), tonumber(state.perfect_window)
    event.last_beat, event.last_ms, event.timeout_ms = tonumber(state.beat), tonumber(state.last), timeout_for(period)
  end
  return emit('PLAYER:' .. pid, event)
end

-- Uses up one beat of a slot. Returns how well it was timed ('opener',
-- 'perfect', 'good', 'early' or 'late'), the offset from the beat in ms, and
-- the slot's new state. A rhythm takes the weather's timings (wx, from
-- weathered()) when it opens and keeps them. Poise and focus widen the
-- windows, but a window never reaches halfway to the next beat.
local function take_beat(pid, n, gear, wx)
  local now = now_ms()
  local state = live_slot(pid, n, now)
  local quality, offset
  if not state then
    local period = wx.period
    local window = math.min(wx.window + 15 * stat(pid, 'poise'), math.ceil(period / 2) - 1)
    local perfect = math.min(wx.perfect + 10 * stat(pid, 'focus'), window)
    state = {gear = gear.id, start = now, period = period, window = window, perfect_window = perfect, beat = 0}
    quality = 'opener'
  else
    local start, period = tonumber(state.start), tonumber(state.period)
    local beat = math.max(math.floor((now - start) / period + 0.5), tonumber(state.beat) + 1)
    offset = now - (start + beat * period)
    state.beat = beat
    if math.abs(offset) <= tonumber(state.perfect_window) then
      quality = 'perfect'
    elseif math.abs(offset) <= tonumber(state.window) then
      quality = 'good'
    else
      quality = offset < 0 and 'early' or 'late'
    end
  end
  state.last = now
  local key = slot_key(pid, n)
  redis.call('HSET', key, 'gear', state.gear, 'start', state.start, 'period', state.period, 'window', state.window,
    'perfect_window', state.perfect_window, 'beat', state.beat, 'last', state.last)
  redis.call('PEXPIRE', key, timeout_for(tonumber(state.period)) * 3)
  return quality, offset, state
end

-- What a use lands, after the weather: nil for a mistimed one.
local function amount_for(wx, quality)
  local i = ({opener = 1, good = 2, perfect = 3})[quality]
  return i and wx.amounts[i]
end

-- Reports a mistimed use: privately how, and to the room that it missed.
local function whiff(pid, rid, n, gear, quality, offset, target_id, target_display)
  emit('PLAYER:' .. pid, {type = 'combat', slot = n, gear = gear.id, result = quality, offset_ms = offset,
    text = (quality == 'early' and 'Too early' or 'Too late') .. ': ' .. gear.whiff})
  emit('ROOM:' .. rid, {type = 'combat', actor = pid, verb = gear.id, slot = n, target = target_id,
    result = 'miss', text = fill(gear.miss, name_of(pid), target_display)})
end

-- Tells a (re)connecting player about each of their slots.
local function resend_timing(pid)
  local now = now_ms()
  for n = 1, SLOTS do timing_event(pid, n, live_slot(pid, n, now)) end
end

-- Gives a player their starting gear and loadout the first time they enter
-- the world. PLAYER:<id>:gear is the gear they own: their inventory of things
-- that go in slots.
local function ensure_kit(pid)
  local gear = 'PLAYER:' .. pid .. ':gear'
  redis.call('HSETNX', 'ACCOUNT:' .. pid, 'coins', rule('starting_coins', 20))
  if redis.call('HSETNX', 'ACCOUNT:' .. pid, 'loadout_set', '1') == 1 then
    for n, gid in ipairs(redis.call('LRANGE', 'alz:default_loadout', 0, SLOTS - 1)) do
      redis.call('HSET', 'PLAYER:' .. pid .. ':slots', n, gid)
    end
  end
  if redis.call('HSETNX', 'ACCOUNT:' .. pid, 'kit_set', '1') == 1 then
    for _, gid in ipairs(redis.call('LRANGE', 'alz:starting_gear', 0, -1)) do redis.call('SADD', gear, gid) end
    for _, gid in ipairs(redis.call('HVALS', 'PLAYER:' .. pid .. ':slots')) do redis.call('SADD', gear, gid) end
  end
end

local function match_gear(word)
  for _, gid in ipairs(redis.call('SMEMBERS', 'alz:gear')) do
    local gear = hgetall('GEAR:' .. gid)
    local name = string.lower(gear.name or '')
    local words = ' ' .. (gear.keywords or '') .. ' ' .. name .. ' '
    if gid == word or name == word or string.find(words, ' ' .. word .. ' ', 1, true) then return gid end
  end
end

-- A slot number from args, or nil.
local function slot_number(value)
  local n = tonumber(value)
  if n and n >= 1 and n <= SLOTS and n % 1 == 0 then return n end
end

-- Refuses to change gear while anything is fighting the player: loadouts are
-- chosen before a fight. Returns true if it refused.
local function mid_fight(pid)
  if redis.call('SCARD', 'PLAYER:' .. pid .. ':foes') == 0 then return false end
  notice(pid, "You can't change your gear mid-fight.")
  return true
end

-- Refuses to change a slot mid-rhythm. Returns true if it refused.
local function slot_busy(pid, n)
  local now = now_ms()
  local state = live_slot(pid, n, now)
  if not state then return false end
  local left = timeout_for(tonumber(state.period)) - (now - tonumber(state.last))
  notice(pid, 'Slot ' .. n .. ' is still in rhythm. It settles ' .. math.ceil(left / 1000) .. 's after its last use.')
  return true
end

-- NPCs fighting back -----------------------------------------------------------
-- NPC attacks are simple and slow next to a player's. Each attack has its own
-- period, and NPCs never miss, so there is nothing to judge: the server just
-- lands each one on time. Hostile NPCs attack players on sight; neutral ones
-- fight back when attacked; friendly ones can't be attacked at all.
-- NPC:<id>:foes (a sorted set, by when they joined the fight) holds who an NPC
-- is fighting, and it attacks the first of them still in its room;
-- PLAYER:<id>:foes is the reverse. NPC:<id>:next holds when each attack lands
-- next, and alz:npc_attacks schedules them all ('<nid>#<n>' by time) for the
-- `tick` function, which every server calls several times a second.

local function npc_timing_event(nid)
  local fight = npc_fight(nid)
  local event = {type = 'npc_timing', entity_id = 'npc:' .. nid, active = fight ~= nil}
  if fight then event.attacks, event.target = fight.attacks, fight.target end
  return emit('ROOM:' .. redis.call('HGET', 'NPC:' .. nid, 'room'), event)
end

local function stop_fighting(nid)
  for _, pid in ipairs(redis.call('ZRANGE', 'NPC:' .. nid .. ':foes', 0, -1)) do
    redis.call('SREM', 'PLAYER:' .. pid .. ':foes', nid)
  end
  for _, n in ipairs(redis.call('HKEYS', 'NPC:' .. nid .. ':next')) do
    redis.call('ZREM', 'alz:npc_attacks', nid .. '#' .. n)
  end
  if redis.call('DEL', 'NPC:' .. nid .. ':foes', 'NPC:' .. nid .. ':next') > 0 then npc_timing_event(nid) end
end

-- Starts (or joins) a fight. An NPC's first attacks come a full period in.
local function engage(nid, pid)
  local attacks = npc_attacks(nid)
  if #attacks == 0 then return end
  local now = now_ms()
  redis.call('ZADD', 'NPC:' .. nid .. ':foes', 'NX', now, pid)
  redis.call('SADD', 'PLAYER:' .. pid .. ':foes', nid)
  if redis.call('EXISTS', 'NPC:' .. nid .. ':next') == 1 then return end
  for n, attack in ipairs(attacks) do
    redis.call('HSET', 'NPC:' .. nid .. ':next', n, now + attack.period)
    redis.call('ZADD', 'alz:npc_attacks', now + attack.period, nid .. '#' .. n)
  end
  npc_timing_event(nid)
end

local function drop_foe(nid, pid)
  redis.call('ZREM', 'NPC:' .. nid .. ':foes', pid)
  redis.call('SREM', 'PLAYER:' .. pid .. ':foes', nid)
  if redis.call('ZCARD', 'NPC:' .. nid .. ':foes') == 0 then stop_fighting(nid) end
end

local function fighting(nid, pid)
  return redis.call('ZSCORE', 'NPC:' .. nid .. ':foes', pid) ~= false
end

-- Hostile NPCs in the room turn on a player (who is awake and in it).
local function aggro(pid, rid)
  for _, nid in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs'))) do
    if #npc_attacks(nid) > 0 and not fighting(nid, pid) and disposition_for(pid, nid) == 'hostile' then
      engage(nid, pid)
      emit('ROOM:' .. rid, {type = 'emote', verb = 'aggro', entity_id = 'npc:' .. nid, target = 'pc:' .. pid,
        text = capitalize(npc_display(nid)) .. ' turns on ' .. name_of(pid) .. '!'})
    end
  end
end

-- Character -----------------------------------------------------------------------
-- Experience comes from defeating NPCs. Each level gives a stat point to spend
-- ('train <stat>') and whatever the seed's level table grants: gear, or perks.

-- A piece of gear for the client: what it is, its weather profile, and (with
-- the player and the weather) what it does right now and why.
local function gear_summary(g, pid, w)
  local summary = {id = g.id, name = g.name, kind = g.kind, effect = g.effect, targets = g.targets ~= '' and g.targets or 'self',
    description = g.description or '', period_ms = tonumber(g.period), grace_ms = tonumber(g.window), perfect_ms = tonumber(g.perfect_window),
    amounts = list({tonumber(g.opener), tonumber(g.good), tonumber(g.perfect)})}
  if pid then
    local wx = weathered(pid, g, w)
    summary.weather = wx.profile
    summary.now = {factor = wx.factor, amounts = wx.amounts, period_ms = wx.period, grace_ms = wx.window,
      perfect_ms = wx.perfect, mods = wx.mods}
  end
  return summary
end

-- Items carried plus gear not in a slot: what counts against pack_size.
local function pack_count(pid)
  local slotted = {}
  for _, gid in ipairs(redis.call('HVALS', 'PLAYER:' .. pid .. ':slots')) do slotted[gid] = true end
  local loose = 0
  for _, gid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':gear')) do
    if not slotted[gid] then loose = loose + 1 end
  end
  return redis.call('SCARD', 'PLAYER:' .. pid .. ':inv') + loose
end

-- The gear a player owns, fastest first.
local function owned_gear(pid)
  local all = list()
  for _, gid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':gear')) do
    local g = gear_info(gid)
    if g then all[#all + 1] = g end
  end
  table.sort(all, function(a, b)
    local pa, pb = tonumber(a.period), tonumber(b.period)
    if pa ~= pb then return pa < pb end
    return a.name < b.name
  end)
  return all
end

-- The player's inventory and slots, for the client's panels.
local function kit_event(pid)
  local gear, slots, items = list(), list(), list()
  local w = weather_at(redis.call('GET', 'PLAYER:' .. pid .. ':room'))
  for _, g in ipairs(owned_gear(pid)) do gear[#gear + 1] = gear_summary(g, pid, w) end
  for n = 1, SLOTS do
    local g = slot_gear(pid, n)
    slots[n] = g and g.id or ''
  end
  for _, iid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':inv')) do
    items[#items + 1] = {id = iid, name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid}
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  return emit('PLAYER:' .. pid, {type = 'kit', gear = gear, slots = slots, items = items,
    pack = pack_count(pid), pack_size = rule('pack_size', 12), coins = tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'coins')) or 0})
end

local function character_event(pid)
  local account = hgetall('ACCOUNT:' .. pid)
  local level = tonumber(account.level) or 1
  local stats, trained_stats, boons = {}, {}, list()
  for _, s in ipairs(STATS) do
    stats[s], trained_stats[s] = stat(pid, s), trained(pid, s)
    for _, b in ipairs(boons_for(pid, s)) do
      boons[#boons + 1] = {stat = s, amount = b.amount or 1, active = b.active, note = b.note or '',
        faction = redis.call('HGET', 'FACTION:' .. b.faction, 'name') or b.faction, affinity = b.affinity, respect = b.respect}
    end
  end
  local perks = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks'))) do
    local perk = hgetall('PERK:' .. id)
    perks[#perks + 1] = {id = id, name = perk.name or id, description = perk.description or ''}
  end
  local card = player_card(pid)
  return emit('PLAYER:' .. pid, {type = 'character', level = level, xp = tonumber(account.xp) or 0,
    xp_next = xp_needed(level), points = tonumber(account.points) or 0, stats = stats, trained = trained_stats, boons = boons,
    stat_order = list(STATS), stat_info = STAT_INFO, perks = perks,
    factions = factions_of(pid), hp = card.hp, max_hp = card.max_hp})
end

-- Adds gear to a player's inventory; true if they didn't have it.
local function grant_gear(pid, gid)
  return gear_info(gid) ~= nil and redis.call('SADD', 'PLAYER:' .. pid .. ':gear', gid) == 1
end

local function gain_xp(pid, amount)
  if amount <= 0 then return end
  local key = 'ACCOUNT:' .. pid
  local xp, level = redis.call('HINCRBY', key, 'xp', amount), level_of(pid)
  notice(pid, 'You gain ' .. amount .. ' experience.')
  local leveled = false
  while xp >= xp_needed(level) do
    xp, level, leveled = xp - xp_needed(level), level + 1, true
    redis.call('HSET', key, 'xp', xp, 'level', level)
    redis.call('HINCRBY', key, 'points', 1)
    local reward, new = hgetall('LEVEL:' .. level), {}
    for _, gid in ipairs(decode(reward.gear)) do
      if grant_gear(pid, gid) then new[#new + 1] = gear_info(gid).name end
    end
    for _, perk in ipairs(decode(reward.perks)) do
      if redis.call('SADD', 'PLAYER:' .. pid .. ':perks', perk) == 1 then
        new[#new + 1] = redis.call('HGET', 'PERK:' .. perk, 'name') or perk
      end
    end
    notice(pid, 'You reach level ' .. level .. "! You have a stat point to spend: TRAIN <stat>."
      .. (#new > 0 and (' You gain: ' .. table.concat(new, ', ') .. '.') or ''))
  end
  if leveled then
    emit('ROOM:' .. redis.call('GET', 'PLAYER:' .. pid .. ':room'), {type = 'entity', entity = player_card(pid)})
    kit_event(pid)
  end
  character_event(pid)
end

-- Something a player did involving an NPC. Every faction's culture judges it.
-- Deeds: kill, clean_kill (a perfect killing blow), ambush (striking an NPC
-- that wasn't fighting you), flee (leaving a fight), defeated (falling to
-- one), heal (healing one), greet and taunt (bow, wave… / laugh, poke…).
local function deed(pid, name, nid)
  local subject = hgetall('NPC:' .. nid)
  local of, role = subject.faction or '', subject.role or ''
  local scale = 1 + 0.15 * stat(pid, 'presence')
  local changed = false
  for _, fid in ipairs(sorted(redis.call('SMEMBERS', 'alz:factions'))) do
    local faction = hgetall('FACTION:' .. fid)
    local da, dr, notes = 0, 0, {}
    for _, r in ipairs(decode(faction.rules)) do
      if r.deed == name and (not r.of or r.of == of) and (not r.role or r.role == role) then
        da, dr = da + (r.affinity or 0), dr + (r.respect or 0)
        if r.note then notes[#notes + 1] = r.note end
      end
    end
    local a, r = rep_of(pid, fid)
    local na = math.max(-100, math.min(100, a + round(da * scale)))
    local nr = math.max(-100, math.min(100, r + round(dr * scale)))
    if na ~= a or nr ~= r then
      redis.call('HSET', 'PLAYER:' .. pid .. ':rep:' .. fid, 'affinity', na, 'respect', nr)
      local moved = {}
      if na ~= a then moved[#moved + 1] = 'affinity ' .. signed(na - a) end
      if nr ~= r then moved[#moved + 1] = 'respect ' .. signed(nr - r) end
      emit('PLAYER:' .. pid, {type = 'reputation', faction = fid, faction_name = faction.name, affinity = na, respect = nr,
        text = faction.name .. ': ' .. (#notes > 0 and (table.concat(notes, ' ') .. ' ') or '') .. '(' .. table.concat(moved, ', ') .. ')'})
      changed = true
    end
  end
  if not changed then return end
  character_event(pid)
  reveal_by_reputation(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
    dispositions_event(pid, rid)
    aggro(pid, rid)
  end
end

-- Whether moving between two rooms changes the weather a player is in (a new
-- region, or in or out of a fixed climate).
local function weather_changes(rid, dest)
  local a, b = place_of(rid), place_of(dest)
  return a.realm ~= b.realm or a.region ~= b.region or a.climate ~= nil or b.climate ~= nil
end

-- Moves an awake player between rooms: leave and arrive events, subscriptions
-- and the map. The caller sends the new room's view, then the weather.
local function relocate(pid, rid, dest, verb, target, leave, arrive)
  emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = verb, target = target, entity_id = 'pc:' .. pid, text = leave})
  redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
  redis.call('SET', 'PLAYER:' .. pid .. ':room', dest)
  redis.call('SADD', 'ROOM:' .. dest .. ':players', pid)
  emit('ROOM:' .. dest, {type = 'arrive', actor = pid, verb = verb, target = target, entity = player_card(pid), text = arrive})
  local old, new = place_channels(pid, rid), place_channels(pid, dest)
  resubscribe(pid, minus(new, old), minus(old, new))
  local visible = can_see(weather_at(dest))
  visit_realm(pid, dest)
  local new_room = explore(pid, dest)
  local glimpsed = visible and glimpse(pid, dest)
  if explore_region(pid, region_of(dest), visible) then
    full_map_event(pid)
  elseif new_room or glimpsed then
    map_event(pid, {dest}, false)
  end
end

-- A player at 0 HP wakes at the shrine with half their health, a little
-- experience poorer (never a level). A sleeping body is struck from the field
-- and wakes there next time.
local function defeat(pid, nid)
  local key, me = 'ACCOUNT:' .. pid, name_of(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  for _, other in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')) do drop_foe(other, pid) end
  local lost = math.min(tonumber(redis.call('HGET', key, 'xp')) or 0, math.floor(xp_needed(level_of(pid)) / 10))
  redis.call('HSET', key, 'hp', math.floor(max_hp_of(pid) / 2), 'xp', (tonumber(redis.call('HGET', key, 'xp')) or 0) - lost)
  local shrine = redis.call('HGET', 'alz:rules', 'shrine_room') or redis.call('GET', 'alz:start_room')
  emit('ROOM:' .. rid, {type = 'death', entity_id = 'pc:' .. pid, text = me .. ' collapses.'})
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
    relocate(pid, rid, shrine, 'defeat', nil, me .. "'s body fades away.", me .. ' stumbles out of the shrine, pale and shaken.')
    room_event(pid, shrine, 'move')
    weather_event(pid)
    notice(pid, 'You were defeated, and wake at the shrine' .. (lost > 0 and (', ' .. lost .. ' experience poorer') or '') .. '.')
    deed(pid, 'defeated', nid)
    character_event(pid)
  else
    redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
    redis.call('ZREM', 'alz:sleepers', pid)
    redis.call('HDEL', key, 'asleep')
    redis.call('SET', 'PLAYER:' .. pid .. ':room', shrine)
    emit('ROOM:' .. rid, {type = 'leave', verb = 'defeat', entity_id = 'pc:' .. pid, text = me .. "'s body fades away."})
    deed(pid, 'defeated', nid)
  end
end

-- A sleeping body left out in the open fades from the world.
local function fade_out(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  redis.call('HDEL', 'ACCOUNT:' .. pid, 'asleep')
  for _, nid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')) do drop_foe(nid, pid) end
  if rid and redis.call('SREM', 'ROOM:' .. rid .. ':players', pid) == 1 then
    emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = 'fade', entity_id = 'pc:' .. pid, text = name_of(pid) .. "'s sleeping form fades away."})
  end
end

local ARRIVE_FROM = {
  north = 'the south', south = 'the north', east = 'the west', west = 'the east',
  northeast = 'the southwest', northwest = 'the southeast',
  southeast = 'the northwest', southwest = 'the northeast',
  up = 'below', down = 'above',
}

local function inspect(pid, rid, word)
  local kind, id, display, description = resolve(pid, rid, word)
  if not kind then return notice(pid, "You don't see that here.") end
  emit('PLAYER:' .. pid, {type = 'inspect', target = id, text = description or ('You see nothing special about ' .. display .. '.')})
  if kind ~= 'self' and kind ~= 'carried' then
    emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'inspect', target = id, text = name_of(pid) .. ' examines ' .. display .. '.'})
  end
end

redis.register_function('look', action(function(pid, rid, args)
  if (args[2] or '') == '' then
    if can_see(weather_at(rid)) and glimpse(pid, rid) then map_event(pid, {rid}, false) end
    return room_event(pid, rid, 'look')
  end
  inspect(pid, rid, args[2])
end))

redis.register_function('inspect', action(function(pid, rid, args)
  inspect(pid, rid, args[2])
end))

-- The movement steps from todo.md, in order. Leaving a fight is fleeing it,
-- and some cultures judge that.
local function finish_move(pid, rid, dir, dest)
  local fled = redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')
  for _, nid in ipairs(fled) do drop_foe(nid, pid) end
  local me, from = name_of(pid), ARRIVE_FROM[dir]
  relocate(pid, rid, dest, 'move', dir, me .. ' heads ' .. dir .. '.', me .. (from and (' arrives from ' .. from .. '.') or ' arrives.'))
  room_event(pid, dest, 'move')
  if weather_changes(rid, dest) then
    weather_event(pid)
    kit_event(pid)
  end
  for _, nid in ipairs(fled) do deed(pid, 'flee', nid) end
  aggro(pid, dest)
end

local WADING = {
  snow = {'You take high steps, trying to clear the snow that impedes you.', ' starts wading %s through the snow.'},
  mud = {'Your boots sink into the mud with every step.', ' squelches off %s through the mud.'},
}

-- A short cooldown between moves (move_cooldown_ms) stops a client from
-- sending a whole journey at once. Deep snow or mud holds a move up: the
-- player is told why at once, and `tick` finishes the move when it's due
-- (PLAYER:<id>:pending holds it, alz:pending_moves schedules it).
redis.register_function('move', action(function(pid, rid, args)
  local dir = args[2]
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
  if not dest then return notice(pid, "You can't go that way.") end
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':pending') == 1 then return notice(pid, "You're still making your way.") end
  local cooldown = rule('move_cooldown_ms', 250)
  if cooldown > 0 and not redis.call('SET', 'PLAYER:' .. pid .. ':moved', '1', 'NX', 'PX', cooldown) then
    return notice(pid, 'You need a moment to find your footing.')
  end
  local delay, cause = travel_delay(pid, rid, dest)
  if delay == 0 then return finish_move(pid, rid, dir, dest) end
  redis.call('HSET', 'PLAYER:' .. pid .. ':pending', 'dir', dir, 'from', rid)
  redis.call('PEXPIRE', 'PLAYER:' .. pid .. ':pending', delay + 10000)
  redis.call('ZADD', 'alz:pending_moves', now_ms() + delay, pid)
  emit('PLAYER:' .. pid, {type = 'travel', delay_ms = delay, cause = cause, target = dir, text = WADING[cause][1]})
  emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'wade', target = dir, text = name_of(pid) .. string.format(WADING[cause][2], dir)})
end))

-- The jump: sends a player to any room, in this realm or another, with a
-- line for the room they leave and the room they arrive in ({actor} is their
-- name). Passage NPCs and gates use it; abilities and events can too. A jump
-- out of a fight is no escape from what you were fighting: they just lose you.
local function teleport(pid, dest, leave, arrive)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  for _, nid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')) do drop_foe(nid, pid) end
  redis.call('DEL', 'PLAYER:' .. pid .. ':pending')
  redis.call('ZREM', 'alz:pending_moves', pid)
  local me = name_of(pid)
  relocate(pid, rid, dest, 'teleport', nil, fill(leave, me), fill(arrive, me))
  room_event(pid, dest, 'move')
  full_map_event(pid)
  weather_event(pid)
  kit_event(pid)
  aggro(pid, dest)
end

-- Routes ----------------------------------------------------------------------
-- A route is every jump from one room to another: a ferry, a coach, a portal
-- mage, a rift (ROUTE:<id>; ROOM:<rid>:routes lists those leaving a room). It
-- can need its operator (`by`, an NPC here and friendly to you), a fare in
-- coins, weather (`when`) and a clear room (`clear`). A route with `stages`
-- is a journey: the player travels in its `via` room, each stage shows its
-- line and waits for them to `continue`, then stage_seconds pass before the
-- next (alz:journeys schedules it for `tick`), and after the last they
-- arrive. PLAYER:<id>:journey holds the route, the stage (0 = setting off)
-- and whether it's moving. A journey only moves on while the player is here
-- to continue it: log out on the road and you're still aboard when you
-- come back.

local function coins_of(pid)
  return tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'coins')) or 0
end

-- Why a route won't take a player right now, or nil if it will.
local function route_refusal(pid, rid, route)
  if route.by ~= '' then
    if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', route.by) == 0 then
      return capitalize(npc_display(route.by)) .. " isn't here to take you."
    end
    if disposition_for(pid, route.by) ~= 'friendly' then return capitalize(npc_display(route.by)) .. ' refuses to take you.' end
  end
  local w = weather_at(rid)
  for axis, range in pairs(decode(route.when)) do
    if w[axis] and (w[axis] < range[1] or w[axis] > range[2]) then
      return route.closed ~= '' and route.closed or (capitalize(route.name) .. " isn't running in this weather.")
    end
  end
  if route.clear == '1' then
    for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
      if disposition_for(pid, nid) == 'hostile' then
        return route.closed ~= '' and route.closed or 'Something hostile stands in the way.'
      end
    end
  end
  local fare, coins = tonumber(route.fare) or 0, coins_of(pid)
  if coins < fare then return 'It costs ' .. fare .. ' coins, and you have ' .. coins .. '.' end
end

-- The space for travel events: challenges, choices, skill checks, ambushes,
-- tolls and delays, still to be designed. It's called as each stage begins,
-- with the route, the stage number and the stage's `event` name from the seed
-- (or nil), and does nothing yet. Whatever it becomes, it can hurt the player,
-- take coins, add stages or end the journey early, and it should say so with
-- events on the player's channel like everything else.
local function journey_event(pid, route, stage, event)
end

-- Shows the current stage of a player's journey and waits for them to
-- continue, or, past the last stage, brings them to its end.
local function journey_stage(pid)
  local key = 'PLAYER:' .. pid .. ':journey'
  local journey = hgetall(key)
  local route = hgetall('ROUTE:' .. (journey.route or ''))
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not route.to or rid ~= route.via then return redis.call('DEL', key) end
  local stages, n = decode(route.stages), tonumber(journey.stage)
  if n > #stages then
    redis.call('DEL', key)
    return teleport(pid, route.to, '{actor} gets off.', route.arrive)
  end
  local stage = stages[n]
  local text = type(stage) == 'table' and stage.text or stage
  journey_event(pid, route, n, type(stage) == 'table' and stage.event or nil)
  emit('PLAYER:' .. pid, {type = 'journey', route = journey.route, stage = n, stages = #stages, waiting = true,
    text = text .. (n == #stages and ' (Enter to arrive)' or ' (Enter to go on)')})
end

local function take_route(pid, rid, id)
  local route = hgetall('ROUTE:' .. id)
  local refusal = route_refusal(pid, rid, route)
  if refusal then return notice(pid, refusal) end
  local fare = tonumber(route.fare) or 0
  if fare > 0 then redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', -fare) end
  if route.depart ~= '' then notice(pid, route.depart) end
  if #decode(route.stages) == 0 then return teleport(pid, route.to, route.leave, route.arrive) end
  teleport(pid, route.via, route.leave, '{actor} climbs aboard.')
  redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
  redis.call('HSET', 'PLAYER:' .. pid .. ':journey', 'route', id, 'stage', 1, 'moving', '0')
  journey_stage(pid)
end

-- The routes leaving a room that a player can see (and maybe take), by id.
local function routes_here(pid, rid)
  local out = {}
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':routes'))) do
    local route = hgetall('ROUTE:' .. id)
    if route_offered(pid, route) then
      route.id = id
      out[#out + 1] = route
    end
  end
  return out
end

-- Asked about passage, an NPC takes the player on its one route from here, or
-- lists them if it runs several.
local function ask_routes(pid, rid, nid, who)
  local mine = {}
  for _, route in ipairs(routes_here(pid, rid)) do
    if route.by == nid then mine[#mine + 1] = route end
  end
  if #mine == 0 then return notice(pid, who .. " can't take you anywhere.") end
  if #mine == 1 then return take_route(pid, rid, mine[1].id) end
  local names = {}
  for i, route in ipairs(mine) do names[i] = route_command(route) .. ' (' .. route.name .. ')' end
  notice(pid, who .. ' can take you several ways: ' .. table.concat(names, ' or ') .. '.')
end

-- Moves due journeys on a stage, or to their end. Called by `tick`.
local function journeys_due(now)
  for _, pid in ipairs(redis.call('ZRANGEBYSCORE', 'alz:journeys', '-inf', now)) do
    redis.call('ZREM', 'alz:journeys', pid)
    local key = 'PLAYER:' .. pid .. ':journey'
    if redis.call('EXISTS', key) == 1 then
      redis.call('HINCRBY', key, 'stage', 1)
      redis.call('HSET', key, 'moving', '0')
      journey_stage(pid)
    end
  end
end

-- Finishes held-up moves that are due. Called by `tick`.
local function pending_moves_due(now)
  for _, pid in ipairs(redis.call('ZRANGEBYSCORE', 'alz:pending_moves', '-inf', now)) do
    redis.call('ZREM', 'alz:pending_moves', pid)
    local pending = hgetall('PLAYER:' .. pid .. ':pending')
    redis.call('DEL', 'PLAYER:' .. pid .. ':pending')
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    local dest = rid and pending.dir and redis.call('HGET', 'ROOM:' .. rid .. ':exits', pending.dir)
    -- Only if they're still in the world, awake, and where they set off from.
    if dest and rid == pending.from and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
      finish_move(pid, rid, pending.dir, dest)
    end
  end
end

-- Heals the player, or with gear that targets allies, another player or a
-- friendly NPC. Returns the healed entity id and display name (nil for self).
local function heal(pid, rid, n, gear, word)
  local whom, display
  if gear.targets == 'ally' and word ~= '' then
    local kind, id, shown = resolve(pid, rid, word)
    if kind == 'player' then
      whom, display = 'pc:' .. id, shown
    elseif kind == 'npc' and disposition_for(pid, id) == 'friendly' then
      whom, display = 'npc:' .. id, shown
    end
  end
  local wx = weathered(pid, gear, weather_at(rid))
  local quality, offset, state = take_beat(pid, n, gear, wx)
  local amount = amount_for(wx, quality)
  if not amount then
    whiff(pid, rid, n, gear, quality, offset, whom, display)
    return timing_event(pid, n, state)
  end
  local kind, id = string.match(whom or ('pc:' .. pid), '^(%a+):(.+)$')
  local card = kind == 'npc' and npc_card(id) or player_card(id)
  local healed = math.min(amount, card.max_hp - card.hp)
  if kind == 'npc' then
    redis.call('HSET', 'NPC:' .. id, 'hp', card.hp + healed)
  else
    redis.call('HSET', 'ACCOUNT:' .. id, 'hp', card.hp + healed)
  end
  local text = fill(quality == 'perfect' and gear.perfect_hit or gear.hit, name_of(pid), display or 'themself')
  emit('ROOM:' .. rid, {type = 'heal', actor = pid, verb = gear.id, slot = n, target = whom, result = quality,
    amount = healed, offset_ms = offset, text = text .. (healed > 0 and (' (+' .. healed .. ')') or ' (already at full health)')})
  emit('ROOM:' .. rid, {type = 'entity', entity = kind == 'npc' and npc_card(id) or player_card(id)})
  if kind == 'npc' and healed > 0 then deed(pid, 'heal', id) end
  timing_event(pid, n, state)
end

-- Uses whatever is in a slot. args: pid, slot number, target word ('' for
-- none). Healing gear heals you, or an ally if it can and one is targeted.
redis.register_function('use', action(function(pid, rid, args)
  local n = slot_number(args[2])
  if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  local gear = slot_gear(pid, n)
  if not gear then return notice(pid, 'Slot ' .. n .. " is empty. Try EQUIP <gear> " .. n .. ", or GEAR to see what you have.") end
  local word = args[3] or ''
  if gear.effect == 'heal' then return heal(pid, rid, n, gear, word) end

  if word == '' then return notice(pid, gear.name .. ' what? Name a target, or press Tab to pick one.') end
  local kind, id, display = resolve(pid, rid, word)
  if not kind then return notice(pid, "You don't see that here.") end
  if kind == 'self' then return notice(pid, 'You think better of it.') end
  if kind == 'player' then return notice(pid, "You can't attack other players.") end
  if kind ~= 'npc' then return notice(pid, "You can't fight that.") end
  if disposition_for(pid, id) == 'friendly' then return notice(pid, "You won't attack " .. display .. '.') end

  local first = not fighting(id, pid)
  local wx = weathered(pid, gear, weather_at(rid))
  local quality, offset, state = take_beat(pid, n, gear, wx)
  local damage = amount_for(wx, quality)
  if not damage then
    whiff(pid, rid, n, gear, quality, offset, 'npc:' .. id, display)
    engage(id, pid)
    return timing_event(pid, n, state)
  end

  local npc = hgetall('NPC:' .. id)
  local hp = redis.call('HINCRBY', 'NPC:' .. id, 'hp', -damage)
  local text = fill(quality == 'perfect' and gear.perfect_hit or gear.hit, name_of(pid), display)
  emit('ROOM:' .. rid, {type = 'combat', actor = pid, verb = gear.id, slot = n, target = 'npc:' .. id,
    result = quality, damage = damage, offset_ms = offset, text = text .. ' (' .. damage .. ')'})
  if hp > 0 or npc.immortal == '1' then
    if hp <= 0 then
      -- Practice targets never fall.
      redis.call('HSET', 'NPC:' .. id, 'hp', npc.max_hp)
      emit('ROOM:' .. rid, {type = 'emote', entity_id = 'npc:' .. id, text = capitalize(display) .. ' wobbles back upright.'})
    end
    emit('ROOM:' .. rid, {type = 'entity', entity = npc_card(id)})
    engage(id, pid)
    timing_event(pid, n, state)
    if first then deed(pid, 'ambush', id) end
    return
  end

  -- Down: out of the room until it respawns.
  stop_fighting(id)
  redis.call('HSET', 'NPC:' .. id, 'hp', 0)
  redis.call('SREM', 'ROOM:' .. rid .. ':npcs', id)
  local delay = (tonumber(npc.respawn) or 60) * 1000
  redis.call('ZADD', 'alz:respawns', tonumber(state.last) + delay, id)
  emit('ROOM:' .. rid, {type = 'death', entity_id = 'npc:' .. id, text = capitalize(display) .. ' collapses.'})
  timing_event(pid, n, state)
  if first then deed(pid, 'ambush', id) end
  deed(pid, 'kill', id)
  if quality == 'perfect' then deed(pid, 'clean_kill', id) end
  local taken = {}
  for _, gid in ipairs(decode(npc.drops)) do
    if grant_gear(pid, gid) then taken[#taken + 1] = gear_info(gid).name end
  end
  local gear_taken, coins = #taken > 0, tonumber(npc.coins) or 0
  if coins > 0 then
    redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', coins)
    taken[#taken + 1] = coins .. ' coin' .. (coins == 1 and '' or 's')
  end
  if #taken > 0 then
    notice(pid, 'You take ' .. display .. "'s " .. table.concat(taken, ', ') .. (gear_taken and ". (INVENTORY to equip it.)" or '.'))
    kit_event(pid)
  end
  gain_xp(pid, tonumber(npc.xp) or 0)
end))

-- Puts gear in a slot. args: pid, gear word, slot number ('' for the first
-- empty one).
redis.register_function('equip', action(function(pid, rid, args)
  local gid = match_gear(args[2])
  if not gid then return notice(pid, "There's no gear called '" .. args[2] .. "'. Type GEAR to see what you have.") end
  if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':gear', gid) == 0 then
    return notice(pid, "You don't have " .. gear_info(gid).name .. '.')
  end
  local slots = 'PLAYER:' .. pid .. ':slots'
  local n
  if (args[3] or '') == '' then
    for i = 1, SLOTS do
      if not slot_gear(pid, i) then n = i break end
    end
    if not n then return notice(pid, "Your slots are full. Say which one to replace: 'equip " .. args[2] .. " 1', 2 or 3.") end
  else
    n = slot_number(args[3])
    if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  end
  local gear = gear_info(gid)
  if redis.call('HGET', slots, n) == gid then return notice(pid, 'Slot ' .. n .. ' already holds ' .. gear.name .. '.') end
  if mid_fight(pid) or slot_busy(pid, n) then return end
  redis.call('HSET', slots, n, gid)
  redis.call('DEL', slot_key(pid, n))
  notice(pid, 'Slot ' .. n .. ': ' .. gear.name .. ', ' .. every(tonumber(gear.period)) .. '.')
  timing_event(pid, n, nil)
  kit_event(pid)
end))

-- Empties a slot. args: pid, slot number.
redis.register_function('unequip', action(function(pid, rid, args)
  local n = slot_number(args[2])
  if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  local gear = slot_gear(pid, n)
  if not gear then return notice(pid, 'Slot ' .. n .. ' is already empty.') end
  if mid_fight(pid) or slot_busy(pid, n) then return end
  redis.call('HDEL', 'PLAYER:' .. pid .. ':slots', n)
  redis.call('DEL', slot_key(pid, n))
  notice(pid, 'Slot ' .. n .. ' is empty now.')
  timing_event(pid, n, nil)
  kit_event(pid)
end))

-- Lists the gear the player has, fastest first, and what's in their slots.
redis.register_function('gear', action(function(pid, rid, args)
  local gear, lines = list(), {'Your gear in this weather (good timing / perfect, after the opener):'}
  local w = weather_at(rid)
  for _, g in ipairs(owned_gear(pid)) do
    local summary = gear_summary(g, pid, w)
    local now = summary.now
    gear[#gear + 1] = summary
    local change = pct(now.factor)
    lines[#lines + 1] = '  ' .. g.name .. ' (' .. string.lower(g.kind or '') .. ', ' .. summary.weather.tier .. '): ' .. every(now.period_ms)
      .. ', ±' .. now.grace_ms .. 'ms, ' .. (g.effect == 'heal' and 'heals ' or '') .. now.amounts[2] .. ' / '
      .. now.amounts[3] .. (g.effect == 'heal' and '' or ' damage') .. (summary.targets == 'ally' and ', on you or an ally' or '')
      .. (change ~= 0 and (' [weather ' .. signed(change) .. '%]') or '')
  end
  local slots, labels = list(), {}
  for n = 1, SLOTS do
    local g = slot_gear(pid, n)
    slots[n] = g and g.id or ''
    labels[n] = n .. ' ' .. (g and g.name or '(empty)')
  end
  lines[#lines + 1] = 'Your slots: ' .. table.concat(labels, ' · ') .. ". Change one with EQUIP <gear> <slot>."
  emit('PLAYER:' .. pid, {type = 'gear', gear = gear, slots = slots, text = table.concat(lines, '\n')})
end))

-- Spends a stat point. args: pid, stat.
redis.register_function('train', action(function(pid, rid, args)
  local name = args[2]
  if not STAT_INFO[name] then return notice(pid, 'Your stats are vigor, poise, focus, presence and resilience.') end
  local key = 'ACCOUNT:' .. pid
  if (tonumber(redis.call('HGET', key, 'points')) or 0) < 1 then
    return notice(pid, "You have no stat points to spend. You'll get one each level.")
  end
  local hp = player_card(pid).hp
  redis.call('HINCRBY', key, 'points', -1)
  redis.call('HINCRBY', key, 'stat:' .. name, 1)
  if name == 'vigor' then redis.call('HSET', key, 'hp', hp + VIGOR_HP) end
  notice(pid, capitalize(name) .. ' is now ' .. stat(pid, name) .. '. ' .. STAT_INFO[name])
  character_event(pid)
  if name == 'resilience' then kit_event(pid) end
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
end))

-- The character sheet, as text: level, stats, perks and reputation.
redis.register_function('stats', action(function(pid, rid, args)
  local account, card = hgetall('ACCOUNT:' .. pid), player_card(pid)
  local level = tonumber(account.level) or 1
  local lines = {name_of(pid) .. ', level ' .. level .. ' (' .. (tonumber(account.xp) or 0) .. ' / ' .. xp_needed(level)
    .. ' experience). Health ' .. card.hp .. ' / ' .. card.max_hp .. '.'}
  for _, s in ipairs(STATS) do lines[#lines + 1] = '  ' .. (tonumber(account['stat:' .. s]) or 0) .. '  ' .. STAT_INFO[s] end
  local points = tonumber(account.points) or 0
  if points > 0 then lines[#lines + 1] = 'Stat points to spend: ' .. points .. ". TRAIN <stat>" end
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks'))) do
    local perk = hgetall('PERK:' .. id)
    lines[#lines + 1] = 'Perk: ' .. (perk.name or id) .. '. ' .. (perk.description or '')
  end
  for _, f in ipairs(factions_of(pid)) do
    lines[#lines + 1] = f.name .. ': ' .. f.affinity_label .. ' (' .. f.affinity .. '), ' .. f.respect_label .. ' (' .. f.respect .. ')'
  end
  emit('PLAYER:' .. pid, {type = 'stats', text = table.concat(lines, '\n')})
end))

-- args: pid, message, target word ('' for none). A target in the room gets
-- addressed by name.
redis.register_function('say', action(function(pid, rid, args)
  local me, message, word = name_of(pid), args[2], args[3] or ''
  local kind, id, display
  if word ~= '' then kind, id, display = resolve(pid, rid, word) end
  if kind == 'player' or kind == 'npc' then
    return emit('ROOM:' .. rid, {type = 'say', actor = pid, verb = 'say', target = (kind == 'npc' and 'npc:' or 'pc:') .. id,
      message = message, text = me .. ' says to ' .. display .. ', "' .. message .. '"'})
  end
  emit('ROOM:' .. rid, {type = 'say', actor = pid, verb = 'say', message = message, text = me .. ' says, "' .. message .. '"'})
end))

-- Emotes aimed at NPCs are deeds their cultures may care about, at most once
-- per NPC per social_cooldown seconds (so bowing on repeat earns nothing).
local SOCIAL = {bow = 'greet', wave = 'greet', nod = 'greet', smile = 'greet', cheer = 'greet', laugh = 'taunt', poke = 'taunt', point = 'taunt'}

-- args: pid, verb, target word, text without a target, text with a target.
-- A free-form emote passes an empty verb and the finished text.
redis.register_function('emote', action(function(pid, rid, args)
  local verb, word, plain, targeted = args[2], args[3], args[4], args[5]
  local me = name_of(pid)
  if verb == '' then
    return emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'emote', text = me .. ' ' .. plain})
  end
  if word == '' then
    return emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = verb, text = fill(plain, me)})
  end
  local kind, id, display = resolve(pid, rid, word)
  if not kind then return notice(pid, "You don't see that here.") end
  local text
  local flavor = kind == 'feature' and redis.call('HGET', 'ROOM:' .. rid .. ':flavor', verb .. ':' .. id)
  if flavor then
    text = me .. ' ' .. flavor
  else
    text = fill(targeted, me, kind == 'self' and 'themself' or display)
  end
  emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = verb, target = id, text = text})
  local social = kind == 'npc' and SOCIAL[verb]
  if social and redis.call('SET', 'PLAYER:' .. pid .. ':social:' .. id, '1', 'NX', 'EX', rule('social_cooldown', 600)) then
    deed(pid, social, id)
  end
end))

redis.register_function('describe', action(function(pid, rid, args)
  redis.call('HSET', 'ACCOUNT:' .. pid, 'description', args[2])
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
  notice(pid, 'Others now see you as: ' .. args[2])
end))

redis.register_function('get', action(function(pid, rid, args)
  local iid, item = match_item('ROOM:' .. rid .. ':items', args[2])
  if not iid then return notice(pid, "You don't see that here.") end
  local size = rule('pack_size', 12)
  if pack_count(pid) >= size then
    return notice(pid, 'Your pack is full (' .. pack_count(pid) .. '/' .. size .. '). Drop something first.')
  end
  redis.call('SMOVE', 'ROOM:' .. rid .. ':items', 'PLAYER:' .. pid .. ':inv', iid)
  emit('ROOM:' .. rid, {type = 'item', actor = pid, verb = 'get', target = iid, item = {id = iid, name = item.name}, text = name_of(pid) .. ' picks up the ' .. item.name .. '.'})
  kit_event(pid)
  learn_regions(pid, decode(item.reveals), 'You study the ' .. item.name .. ' and learn of')
  -- Some items teach a realm's skies, like an NPC with `forecasts` would.
  local taught = {}
  for _, realm in ipairs(decode(item.forecasts)) do
    if redis.call('HSETNX', 'PLAYER:' .. pid .. ':lore', realm, '') == 1 then
      taught[#taught + 1] = redis.call('HGET', 'REALM:' .. realm .. ':info', 'name') or realm
    end
  end
  if #taught > 0 then
    notice(pid, 'With the ' .. item.name .. ' you can read the skies over ' .. table.concat(taught, ' and ') .. " now (WEATHER).")
    weather_event(pid)
  end
end))

redis.register_function('drop', action(function(pid, rid, args)
  local iid, item = match_item('PLAYER:' .. pid .. ':inv', args[2])
  if not iid then return notice(pid, "You aren't carrying that.") end
  redis.call('SMOVE', 'PLAYER:' .. pid .. ':inv', 'ROOM:' .. rid .. ':items', iid)
  emit('ROOM:' .. rid, {type = 'item', actor = pid, verb = 'drop', target = iid, item = {id = iid, name = item.name}, text = name_of(pid) .. ' drops the ' .. item.name .. '.'})
  kit_event(pid)
end))

redis.register_function('inventory', action(function(pid, rid, args)
  local names = list()
  for _, iid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':inv')) do
    names[#names + 1] = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid
  end
  sorted(names)
  local slotted = {}
  for n, gid in pairs(hgetall('PLAYER:' .. pid .. ':slots')) do slotted[gid] = (slotted[gid] and (slotted[gid] .. ',') or '') .. n end
  local gear = {}
  for _, g in ipairs(owned_gear(pid)) do gear[#gear + 1] = g.name .. (slotted[g.id] and (' [' .. slotted[g.id] .. ']') or '') end
  emit('PLAYER:' .. pid, {
    type = 'inventory', items = names,
    text = (#names > 0 and ('You are carrying: ' .. table.concat(names, ', ')) or 'You are carrying nothing.')
      .. '\nGear: ' .. (#gear > 0 and table.concat(gear, ', ') or 'none') .. ". EQUIP <gear> <slot> to use it.",
  })
end))

redis.register_function('tell', action(function(pid, rid, args)
  local target, message = args[2], args[3]
  if target == pid then return notice(pid, 'You mutter to yourself.') end
  if redis.call('EXISTS', 'PLAYER:' .. target .. ':session') == 0 then
    return notice(pid, 'No one called ' .. target .. ' is online.')
  end
  local me, them = name_of(pid), name_of(target)
  emit('PLAYER:' .. target, {type = 'tell', actor = pid, target = target, message = message, text = me .. ' tells you, "' .. message .. '"'})
  emit('PLAYER:' .. pid, {type = 'tell', actor = pid, target = target, message = message, text = 'You tell ' .. them .. ', "' .. message .. '"'})
end))

-- Weather ------------------------------------------------------------------------

local function duration(minutes)
  local h, m = math.floor(minutes / 60), minutes % 60
  if h == 0 then return m .. ' min' end
  return h .. ' h' .. (m > 0 and (' ' .. m .. ' min') or '')
end

local function depth_word(v)
  return v < 0.25 and 'a little' or v < 0.5 and 'some' or v < 0.75 and 'deep' or 'very deep'
end

-- The weather where you are, as text, with the forecast if you can read
-- these skies.
redis.register_function('weather', action(function(pid, rid, args)
  local place = place_of(rid)
  local w = weather_in(place)
  local lines = {}
  if w.indoor then
    lines[1] = place.name .. ' (indoors): ' .. describe_weather(w) .. '. It never changes in here.'
  else
    local realm = redis.call('HGET', 'REALM:' .. (w.realm or '') .. ':info', 'name') or place.name
    local z = zone(w)
    lines[1] = capitalize(realm) .. ': ' .. describe_weather(w) .. (z and z ~= 'Temperate' and (' (' .. z .. ')') or '') .. '.'
    local g = ground_of(w.realm)
    if g.snow >= 0.05 then lines[#lines + 1] = 'There is ' .. depth_word(g.snow) .. ' snow on the ground.' end
    if g.mud >= 0.05 then lines[#lines + 1] = 'The ground is ' .. (g.mud < 0.5 and 'muddy' or 'thick with mud') .. '.' end
    if not can_see(w) then lines[#lines + 1] = 'You can barely see past the ' .. falling(w) .. '.' end
    local units = forecast_units(pid, w.realm)
    if units then
      local now, unit = weather_time(), rule('weather_unit_minutes', 30)
      for i = 1, units do
        lines[#lines + 1] = '  In ' .. duration(i * unit) .. ': ' .. describe_weather(weather_in(place, now + i)) .. '.'
      end
    else
      lines[#lines + 1] = "You can feel the weather, but you can't read these skies. Someone who knows them could teach you: ASK <name> ABOUT WEATHER."
    end
  end
  emit('PLAYER:' .. pid, {type = 'weather_report', text = table.concat(lines, '\n')})
  weather_event(pid)
  kit_event(pid)
end))

local PASSAGE_WORDS = {passage = true, portal = true, travel = true, way = true, crossing = true, ferry = true, coach = true}

-- Asks an NPC about something. About the weather, an NPC who knows some skies
-- (its `forecasts`) teaches a player it's friendly with to read them. About
-- passage, it lists the routes it runs from here (see `travel`).
redis.register_function('ask', action(function(pid, rid, args)
  local kind, nid, display = resolve(pid, rid, args[2])
  if not kind then return notice(pid, "You don't see them here.") end
  if kind ~= 'npc' then return notice(pid, 'Only the locals can tell you that.') end
  local who = capitalize(display)
  emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'ask', target = 'npc:' .. nid,
    text = name_of(pid) .. ' asks ' .. display .. ' about ' .. ((args[3] or '') ~= '' and ('the ' .. args[3]) or 'something') .. '.'})
  if PASSAGE_WORDS[args[3]] then return ask_routes(pid, rid, nid, who) end
  if args[3] ~= 'weather' then
    return notice(pid, who .. " doesn't have much to say about that. (Try asking about the weather, or passage.)")
  end
  local realms = decode(redis.call('HGET', 'NPC:' .. nid, 'forecasts'))
  if #realms == 0 then return notice(pid, who .. " shrugs. They don't read the sky.") end
  if disposition_for(pid, nid) ~= 'friendly' then return notice(pid, who .. " won't share what they know with you.") end
  local fid, names = redis.call('HGET', 'NPC:' .. nid, 'faction') or '', {}
  for _, realm in ipairs(realms) do
    if redis.call('HSETNX', 'PLAYER:' .. pid .. ':lore', realm, fid) == 1 then
      names[#names + 1] = redis.call('HGET', 'REALM:' .. realm .. ':info', 'name') or realm
    end
  end
  if #names > 0 then
    notice(pid, who .. ' shows you how to read the skies over ' .. table.concat(names, ' and ')
      .. ". You'll see the weather there exactly now, and what's coming (WEATHER). The better their people like you, the further ahead you'll see.")
  else
    notice(pid, who .. ' goes over the signs with you again. You already know these skies.')
  end
  weather_event(pid)
end))

-- Moves a journey on: after stage_seconds, the next stage (or the end).
redis.register_function('continue', action(function(pid, rid, args)
  local key = 'PLAYER:' .. pid .. ':journey'
  if redis.call('EXISTS', key) == 0 then return notice(pid, "You aren't on a journey.") end
  if redis.call('HGET', key, 'moving') == '1' then return end
  redis.call('HSET', key, 'moving', '1')
  redis.call('ZADD', 'alz:journeys', now_ms() + rule('stage_seconds', 2) * 1000, pid)
end))

-- Lists the routes leaving this room (ferries, coaches, portals, gates), or
-- takes one (args: a word naming it).
redis.register_function('travel', action(function(pid, rid, args)
  local word = args[2] or ''
  local routes = routes_here(pid, rid)
  if word == '' then
    if #routes == 0 then return notice(pid, 'No routes leave from here.') end
    local lines, listed = {'Routes from here. Type one of these to go (you have ' .. coins_of(pid) .. ' coins):'}, list()
    local here = realm_of(rid)
    for _, route in ipairs(routes) do
      local fare, stages = tonumber(route.fare) or 0, #decode(route.stages)
      local refusal = route_refusal(pid, rid, route)
      -- Where it goes: the region (and realm, if it's another), unless you've never heard of it.
      local gid = region_of(route.to)
      local whither = 'somewhere you know nothing about'
      if region_state(pid, gid) then
        whither = redis.call('HGET', 'REGION:' .. gid .. ':info', 'name') or gid
        local realm = realm_of(route.to)
        if realm ~= here then whither = whither .. ', in ' .. (redis.call('HGET', 'REALM:' .. realm .. ':info', 'name') or realm) end
      end
      local cost = (fare > 0 and (fare .. ' coins') or 'free') .. ', ' .. (stages > 0 and (stages .. ' stages') or 'instant')
      lines[#lines + 1] = '  ' .. route_command(route) .. ': ' .. route.name .. ' to ' .. whither .. '. ' .. capitalize(cost) .. '.'
        .. (refusal and (' Not now: ' .. refusal) or '')
      listed[#listed + 1] = {id = route.id, name = route.name, to = route_destination(route), command = route_command(route),
        fare = fare, stages = stages, refusal = refusal}
    end
    return emit('PLAYER:' .. pid, {type = 'routes', routes = listed, text = table.concat(lines, '\n')})
  end
  local phrase = string.lower(word)
  for _, route in ipairs(routes) do
    if route_matches(route, phrase) then return take_route(pid, rid, route.id) end
  end
  notice(pid, "No route from here goes to '" .. word .. "'. Type TRAVEL to see where you can go.")
end))

-- Admin: pins the weather in the player's realm (args: temperature, energy,
-- precipitation), or with 'clear' lets it run free again.
redis.register_function('set_weather', action(function(pid, rid, args)
  local realm = realm_of(rid)
  if not realm then return notice(pid, 'There is no realm here.') end
  local key = 'alz:weather_override:' .. realm
  if args[2] == 'clear' then
    redis.call('DEL', key)
  else
    local t, e, p = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not (t and e and p) then return notice(pid, "Usage: SETWEATHER <temperature> <energy> <precipitation>, each -1 to 1, or SETWEATHER CLEAR.") end
    redis.call('HSET', key, 'temperature', clamp(t, -1, 1), 'energy', clamp(e, -1, 1), 'precipitation', clamp(p, -1, 1))
  end
  local w = weather_at(rid)
  notice(pid, (args[2] == 'clear' and 'The weather runs free again: ' or 'The weather here is pinned: ') .. describe_weather(w) .. '.')
  weather_event(pid)
  kit_event(pid)
end))

redis.register_function('who', action(function(pid, rid, args)
  local names = list()
  for _, p in ipairs(redis.call('ZRANGE', 'alz:online', 0, -1)) do names[#names + 1] = name_of(p) end
  sorted(names)
  emit('PLAYER:' .. pid, {type = 'who', players = names, text = 'Online (' .. #names .. '): ' .. table.concat(names, ', ')})
end))

redis.register_function('notify', action(function(pid, rid, args)
  notice(pid, args[2])
end))

-- An admin announcement to the player's current area, region or realm.
redis.register_function('announce', action(function(pid, rid, args)
  local scope, text = args[2], args[3]
  local area = redis.call('HGET', 'ROOM:' .. rid .. ':info', 'area')
  local channel
  if scope == 'area' and area then
    channel = 'AREA:' .. area
  elseif scope == 'region' and area then
    local region = redis.call('HGET', 'AREA:' .. area .. ':info', 'region')
    if region then channel = 'REGION:' .. region end
  elseif scope == 'realm' then
    local realm = realm_of(rid)
    if realm then channel = 'REALM:' .. realm end
  end
  if not channel then return notice(pid, 'There is no ' .. scope .. ' here to announce to.') end
  emit(channel, {type = 'system', actor = pid, verb = 'announce', text = text})
end))

-- Chat channels ---------------------------------------------------------------

local function joined(pid, ch)
  return redis.call('HEXISTS', 'PLAYER:' .. pid .. ':subs', 'CHANNEL:' .. ch) == 1
end

local function join(pid, ch)
  resubscribe(pid, {'CHANNEL:' .. ch}, {})
  emit('CHANNEL:' .. ch, {type = 'system', actor = pid, verb = 'join', target = ch, text = name_of(pid) .. ' joined #' .. ch .. '.'})
end

redis.register_function('chat', action(function(pid, rid, args)
  local ch, message = args[2], args[3]
  if not joined(pid, ch) then return notice(pid, "You aren't in #" .. ch .. ". Try 'join " .. ch .. "'.") end
  emit('CHANNEL:' .. ch, {type = 'chat', actor = pid, target = ch, message = message, text = '[' .. ch .. '] ' .. name_of(pid) .. ': ' .. message})
end))

redis.register_function('create_channel', action(function(pid, rid, args)
  local ch = args[2]
  if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 1 then
    return notice(pid, '#' .. ch .. " already exists. Try 'join " .. ch .. "'.")
  end
  redis.call('HSET', 'CHANNEL:' .. ch .. ':info', 'owner', pid, 'created', math.floor(now_ms() / 1000))
  redis.call('SADD', 'alz:channels', ch)
  join(pid, ch)
end))

redis.register_function('join', action(function(pid, rid, args)
  local ch = args[2]
  if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 0 then
    return notice(pid, 'There is no #' .. ch .. ". You can make it with 'create " .. ch .. "'.")
  end
  if joined(pid, ch) then return notice(pid, "You're already in #" .. ch .. '.') end
  join(pid, ch)
end))

redis.register_function('leave', action(function(pid, rid, args)
  local ch = args[2]
  if not joined(pid, ch) then return notice(pid, "You aren't in #" .. ch .. '.') end
  emit('CHANNEL:' .. ch, {type = 'system', actor = pid, verb = 'leave', target = ch, text = name_of(pid) .. ' left #' .. ch .. '.'})
  resubscribe(pid, {}, {'CHANNEL:' .. ch})
end))

redis.register_function('channels', action(function(pid, rid, args)
  local channels, labels = list(), {}
  for _, ch in ipairs(sorted(redis.call('SMEMBERS', 'alz:channels'))) do
    local member = joined(pid, ch)
    channels[#channels + 1] = {name = ch, joined = member}
    labels[#labels + 1] = '#' .. ch .. (member and ' (joined)' or '')
  end
  emit('PLAYER:' .. pid, {type = 'channels', channels = channels, text = 'Channels: ' .. table.concat(labels, ', ')})
end))

-- Connections -----------------------------------------------------------------

-- Puts a player into the world, or hands an existing presence over to a new
-- connection. args: pid, session id, last sequence number the client saw (0 if
-- none). Returns the sequence number the new connection should read from.
redis.register_function('connect', function(keys, args)
  local pid, session, since = args[1], args[2], tonumber(args[3]) or 0
  local session_key = 'PLAYER:' .. pid .. ':session'
  local previous = redis.call('GET', session_key)
  redis.call('SET', session_key, session)
  redis.call('ZADD', 'alz:online', now_ms(), pid)

  if previous then
    -- Already in the world (another tab, or reconnecting after a dropped
    -- connection): end the old connection and carry on where it left off.
    emit('PLAYER:' .. pid, {type = 'control', op = 'kick', session = previous, reason = 'You connected from somewhere else.'})
    local current = current_seq()
    local cursor = (since > 0 and since < current) and since or current
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    explore(pid, rid)
    backfill_regions(pid)
    visit_realm(pid, rid)
    local visible = can_see(weather_at(rid))
    if visible then glimpse(pid, rid) end
    explore_region(pid, region_of(rid), visible)
    reveal_by_reputation(pid)
    full_map_event(pid)
    weather_event(pid)
    ensure_kit(pid)
    resend_timing(pid)
    kit_event(pid)
    character_event(pid)
    room_event(pid, rid, 'resume')
    if redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'moving') == '0' then journey_stage(pid) end
    return cursor
  end

  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not rid or redis.call('EXISTS', 'ROOM:' .. rid .. ':info') == 0 then
    rid = redis.call('GET', 'alz:start_room')
  end
  redis.call('SET', 'PLAYER:' .. pid .. ':room', rid)
  local slept_here = redis.call('ZREM', 'alz:sleepers', pid) == 1 and redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', pid) == 1
  redis.call('HDEL', 'ACCOUNT:' .. pid, 'asleep')
  if slept_here then
    -- Their body is still lying here: they wake up.
    emit('ROOM:' .. rid, {type = 'entity', actor = pid, verb = 'wake', entity = player_card(pid), text = name_of(pid) .. ' wakes and gets up.'})
  else
    redis.call('SADD', 'ROOM:' .. rid .. ':players', pid)
    emit('ROOM:' .. rid, {type = 'arrive', actor = pid, verb = 'login', entity = player_card(pid), text = name_of(pid) .. ' arrives, well rested.'})
  end

  local cursor = current_seq()
  local subs = 'PLAYER:' .. pid .. ':subs'
  for _, c in ipairs(redis.call('HKEYS', subs)) do
    if string.sub(c, 1, 8) ~= 'CHANNEL:' then redis.call('HDEL', subs, c) end
  end
  local add = place_channels(pid, rid)
  if redis.call('HSETNX', 'ACCOUNT:' .. pid, 'joined_defaults', '1') == 1 then
    for _, ch in ipairs(redis.call('SMEMBERS', 'alz:default_channels')) do add[#add + 1] = 'CHANNEL:' .. ch end
  end
  resubscribe(pid, add, {})
  explore(pid, rid)
  backfill_regions(pid)
  visit_realm(pid, rid)
  local visible = can_see(weather_at(rid))
  if visible then glimpse(pid, rid) end
  explore_region(pid, region_of(rid), visible)
  reveal_by_reputation(pid)
  full_map_event(pid)
  weather_event(pid)
  ensure_kit(pid)
  resend_timing(pid)
  kit_event(pid)
  character_event(pid)
  room_event(pid, rid, 'enter')
  -- Back aboard: the journey waits where it was.
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':journey') == 1 then
    redis.call('HSET', 'PLAYER:' .. pid .. ':journey', 'moving', '0')
    redis.call('ZREM', 'alz:journeys', pid)
    journey_stage(pid)
  end
  aggro(pid, rid)
  return cursor
end)

-- Takes a player out of the world. args: pid, session id (or '' for any),
-- heartbeat cutoff in ms (or '' for none), reason. With a cutoff, the player is
-- only removed if their last heartbeat is older than it, which is how stale
-- connections from crashed servers are cleaned up.
redis.register_function('disconnect', function(keys, args)
  local pid, session, cutoff, reason = args[1], args[2], args[3], args[4]
  local session_key = 'PLAYER:' .. pid .. ':session'
  local current = redis.call('GET', session_key)
  if not current then
    redis.call('ZREM', 'alz:online', pid)
    return 0
  end
  if session ~= '' and session ~= current then return 0 end
  if cutoff ~= '' then
    local beat = redis.call('ZSCORE', 'alz:online', pid)
    if beat and tonumber(beat) > tonumber(cutoff) then return 0 end
  end

  -- Somewhere safe, a player settles in to rest and is gone at once. Out in the
  -- open they lie down to sleep, and their body stays for sleep_seconds; NPCs
  -- already fighting them keep at it, so leaving is no escape.
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid and is_safe(pid, rid) then
    redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
    for _, nid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')) do drop_foe(nid, pid) end
    emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = 'logout', entity_id = 'pc:' .. pid, text = name_of(pid) .. ' settles in to rest, and is gone.'})
  elseif rid then
    redis.call('HSET', 'ACCOUNT:' .. pid, 'asleep', '1')
    redis.call('ZADD', 'alz:sleepers', now_ms() + rule('sleep_seconds', 120) * 1000, pid)
    emit('ROOM:' .. rid, {type = 'entity', actor = pid, verb = 'sleep', entity = player_card(pid), text = name_of(pid) .. ' lies down to rest.'})
  end
  emit('PLAYER:' .. pid, {type = 'control', op = 'kick', session = current, reason = reason})
  local subs = 'PLAYER:' .. pid .. ':subs'
  for _, c in ipairs(redis.call('HKEYS', subs)) do
    if string.sub(c, 1, 8) ~= 'CHANNEL:' then redis.call('HDEL', subs, c) end
  end
  redis.call('DEL', session_key) -- combat state is left to expire, so relogging can't reset it
  redis.call('ZREM', 'alz:online', pid)
  return 1
end)

-- World -----------------------------------------------------------------------

-- Loads the world definition. Static data (rooms, areas, regions, item text) is
-- rewritten every time; live state (where items are, who is where) is only set
-- for things that don't exist yet.
redis.register_function('seed', function(keys, args)
  local world = cjson.decode(args[1])
  redis.call('DEL', 'alz:gated_regions', 'alz:regions', 'alz:realms')
  for id, realm in pairs(world.realms or {}) do
    redis.call('DEL', 'REALM:' .. id .. ':info')
    redis.call('HSET', 'REALM:' .. id .. ':info', 'name', realm.name, 'description', realm.description or '',
      'home', realm.home and '1' or '0', 'weather', cjson.encode(realm.weather or {}),
      'waves', cjson.encode((world.weather_params or {})[id] or {}))
    redis.call('SADD', 'alz:realms', id)
    if realm.home then redis.call('SET', 'alz:home_realm', id) end
  end
  for gid, region in pairs(world.regions) do
    redis.call('DEL', 'REGION:' .. gid .. ':info', 'REGION:' .. gid .. ':borders')
    redis.call('HSET', 'REGION:' .. gid .. ':info', 'name', region.name, 'hidden', region.hidden and '1' or '0',
      'realm', region.realm or '')
    redis.call('SADD', 'alz:regions', gid)
    if region.reveal then
      redis.call('HSET', 'REGION:' .. gid .. ':info', 'reveal', cjson.encode(region.reveal))
      redis.call('SADD', 'alz:gated_regions', gid)
    end
  end
  -- Regions border each other where an exit crosses between them, and wherever
  -- the seed says so.
  local function border(a, b)
    if a == b then return end
    redis.call('SADD', 'REGION:' .. a .. ':borders', b)
    redis.call('SADD', 'REGION:' .. b .. ':borders', a)
  end
  for gid, region in pairs(world.regions) do
    for _, other in ipairs(region.borders or {}) do border(gid, other) end
  end
  for _, room in pairs(world.rooms) do
    for _, dest in pairs(room.exits or {}) do
      border(world.areas[room.area].region, world.areas[world.rooms[dest].area].region)
    end
  end
  -- Areas get distinct map colours (1-6) in id order within their realm (the
  -- map shows one realm at a time), unless the seed picks one.
  local area_ids, counted = {}, {}
  for aid in pairs(world.areas) do area_ids[#area_ids + 1] = aid end
  table.sort(area_ids)
  for _, aid in ipairs(area_ids) do
    local area = world.areas[aid]
    local realm = world.regions[area.region].realm or ''
    counted[realm] = (counted[realm] or 0) + 1
    redis.call('DEL', 'AREA:' .. aid .. ':info')
    redis.call('HSET', 'AREA:' .. aid .. ':info', 'name', area.name, 'region', area.region, 'color', area.color or ((counted[realm] - 1) % 6 + 1),
      'climate', area.climate and cjson.encode(area.climate) or '')
  end
  local area_box = {}
  for rid, room in pairs(world.rooms) do
    local base = 'ROOM:' .. rid
    local x, y = room.pos[1], room.pos[2]
    redis.call('DEL', base .. ':info', base .. ':exits', base .. ':features', base .. ':flavor', base .. ':routes')
    redis.call('HSET', base .. ':info', 'name', room.name, 'description', room.description, 'area', room.area, 'x', x, 'y', y,
      'safe', room.safe and '1' or '0', 'terrain', room.terrain or '', 'climate', room.climate and cjson.encode(room.climate) or '',
      'indoor', room.indoor and '1' or '0')
    local b = area_box[room.area]
    if b then
      b[1], b[2], b[3], b[4] = math.min(b[1], x), math.min(b[2], y), math.max(b[3], x), math.max(b[4], y)
    else
      area_box[room.area] = {x, y, x, y}
    end
    for dir, dest in pairs(room.exits or {}) do redis.call('HSET', base .. ':exits', dir, dest) end
    for name, text in pairs(room.features or {}) do redis.call('HSET', base .. ':features', name, text) end
    for key, text in pairs(room.flavor or {}) do redis.call('HSET', base .. ':flavor', key, text) end
  end
  -- Each area's box covers its rooms; each region's box covers its areas.
  local region_box = {}
  for aid, b in pairs(area_box) do
    redis.call('HSET', 'AREA:' .. aid .. ':info', 'x1', b[1], 'y1', b[2], 'x2', b[3], 'y2', b[4])
    local gid = world.areas[aid].region
    local c = region_box[gid]
    if c then
      c[1], c[2], c[3], c[4] = math.min(c[1], b[1]), math.min(c[2], b[2]), math.max(c[3], b[3]), math.max(c[4], b[4])
    else
      region_box[gid] = {b[1], b[2], b[3], b[4]}
    end
  end
  for gid, c in pairs(region_box) do
    redis.call('HSET', 'REGION:' .. gid .. ':info', 'x1', c[1], 'y1', c[2], 'x2', c[3], 'y2', c[4])
  end
  for nid, npc in pairs(world.npcs or {}) do
    local key = 'NPC:' .. nid
    local new = redis.call('EXISTS', key) == 0
    redis.call('HSET', key, 'name', npc.name, 'label', npc.label or '', 'description', npc.description or '',
      'details', npc.details or '', 'keywords', npc.keywords or '', 'max_hp', npc.max_hp or 10,
      'proper', npc.proper and '1' or '0', 'respawn', npc.respawn or 60, 'icon', npc.icon or '',
      'disposition', npc.disposition or 'neutral', 'faction', npc.faction or '', 'role', npc.role or '',
      'attacks', cjson.encode(npc.attacks or {}), 'drops', cjson.encode(npc.drops or {}),
      'xp', npc.xp or math.floor((npc.max_hp or 10) / 2), 'immortal', npc.immortal and '1' or '0',
      'forecasts', cjson.encode(npc.forecasts or {}), 'active_when', npc.active_when and cjson.encode(npc.active_when) or '',
      'hide', npc.hide or '', 'emerge', npc.emerge or '', 'coins', npc.coins or 0)
    if npc.active_when then redis.call('SADD', 'alz:weather_npcs', nid) else redis.call('SREM', 'alz:weather_npcs', nid) end
    if new then
      redis.call('HSET', key, 'hp', npc.max_hp or 10, 'room', npc.room)
      redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid)
    end
  end
  -- Gear is static: the catalog is rewritten every time. Players' slots keep
  -- what they hold; gear that's gone from the seed acts like an empty slot.
  for _, gid in ipairs(redis.call('SMEMBERS', 'alz:gear')) do redis.call('DEL', 'GEAR:' .. gid) end
  redis.call('DEL', 'alz:gear', 'alz:default_loadout')
  for gid, gear in pairs(world.gear or {}) do
    redis.call('HSET', 'GEAR:' .. gid, 'name', gear.name, 'kind', gear.kind or '', 'keywords', gear.keywords or '',
      'effect', gear.effect, 'targets', gear.targets or 'self', 'period', gear.period, 'window', gear.window, 'perfect_window', gear.perfect_window,
      'opener', gear.amounts[1], 'good', gear.amounts[2], 'perfect', gear.amounts[3],
      'hit', gear.hit, 'perfect_hit', gear.perfect_hit, 'miss', gear.miss, 'whiff', gear.whiff,
      'description', gear.description or '', 'weather', gear.weather and cjson.encode(gear.weather) or '')
    redis.call('SADD', 'alz:gear', gid)
  end
  for _, gid in ipairs(world.loadout or {}) do redis.call('RPUSH', 'alz:default_loadout', gid) end
  redis.call('DEL', 'alz:starting_gear')
  for _, gid in ipairs(world.starting_gear or {}) do redis.call('RPUSH', 'alz:starting_gear', gid) end
  -- Factions, perks and the level table are static too.
  for _, fid in ipairs(redis.call('SMEMBERS', 'alz:factions')) do redis.call('DEL', 'FACTION:' .. fid) end
  redis.call('DEL', 'alz:factions')
  redis.call('DEL', 'alz:boons')
  local boons = {}
  for fid, faction in pairs(world.factions or {}) do
    redis.call('HSET', 'FACTION:' .. fid, 'name', faction.name, 'description', faction.description or '',
      'rules', cjson.encode(faction.rules or {}), 'realm', faction.realm or redis.call('GET', 'alz:home_realm') or '')
    redis.call('SADD', 'alz:factions', fid)
    for _, b in ipairs(faction.boons or {}) do
      b.faction = fid
      boons[b.stat] = boons[b.stat] or {}
      table.insert(boons[b.stat], b)
    end
  end
  for name, list_ in pairs(boons) do redis.call('HSET', 'alz:boons', name, cjson.encode(list_)) end
  -- Weather: default gear profiles by kind, and how terrain nudges the sky.
  redis.call('DEL', 'alz:kinds', 'alz:terrain_weather')
  for kind, profile in pairs(world.kinds or {}) do redis.call('HSET', 'alz:kinds', kind, cjson.encode(profile)) end
  for terrain, nudge in pairs(world.terrain_weather or {}) do redis.call('HSET', 'alz:terrain_weather', terrain, cjson.encode(nudge)) end
  for pid, perk in pairs(world.perks or {}) do
    redis.call('DEL', 'PERK:' .. pid)
    redis.call('HSET', 'PERK:' .. pid, 'name', perk.name, 'description', perk.description or '', 'safe_terrain', perk.safe_terrain or '')
  end
  for _, level in ipairs(redis.call('SMEMBERS', 'alz:levels')) do redis.call('DEL', 'LEVEL:' .. level) end
  redis.call('DEL', 'alz:levels')
  for level, reward in pairs(world.levels or {}) do
    redis.call('HSET', 'LEVEL:' .. level, 'gear', cjson.encode(reward.gear or {}), 'perks', cjson.encode(reward.perks or {}))
    redis.call('SADD', 'alz:levels', level)
  end
  redis.call('DEL', 'alz:rules')
  for name, value in pairs(world.rules or {}) do redis.call('HSET', 'alz:rules', name, value) end
  for iid, item in pairs(world.items or {}) do
    local key = 'ITEM:' .. iid
    local new = redis.call('EXISTS', key) == 0
    redis.call('HSET', key, 'name', item.name, 'keywords', item.keywords or '', 'description', item.description or '',
      'reveals', cjson.encode(item.reveals or {}), 'forecasts', cjson.encode(item.forecasts or {}))
    if new then redis.call('SADD', 'ROOM:' .. item.room .. ':items', iid) end
  end
  for _, ch in ipairs(world.channels or {}) do
    if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 0 then
      redis.call('HSET', 'CHANNEL:' .. ch .. ':info', 'owner', 'system', 'created', math.floor(now_ms() / 1000))
    end
    redis.call('SADD', 'alz:channels', ch)
    redis.call('SADD', 'alz:default_channels', ch)
  end
  -- Routes: every jump from one room to another (see docs/places.md).
  for _, id in ipairs(redis.call('SMEMBERS', 'alz:routes')) do redis.call('DEL', 'ROUTE:' .. id) end
  redis.call('DEL', 'alz:routes')
  for id, route in pairs(world.routes or {}) do
    redis.call('HSET', 'ROUTE:' .. id, 'name', route.name, 'keywords', route.keywords or '', 'from', route.from, 'to', route.to,
      'by', route.by or '', 'fare', route.fare or 0, 'via', route.via or '', 'stages', cjson.encode(route.stages or {}),
      'when', cjson.encode(route.when or {}), 'clear', route.clear and '1' or '0', 'closed', route.closed or '',
      'depart', route.depart or '', 'leave', route.leave or '{actor} is gone.', 'arrive', route.arrive or '{actor} arrives.')
    redis.call('SADD', 'ROOM:' .. route.from .. ':routes', id)
    redis.call('SADD', 'alz:routes', id)
  end
  redis.call('SET', 'alz:start_room', world.start_room)
  return 1
end)

-- Upkeep -----------------------------------------------------------------------

-- Brings back NPCs whose respawn time has come. Hostile ones turn on whoever
-- is there.
-- Whether the weather in an NPC's room suits it (its active_when ranges).
local function npc_active(nid)
  local npc = hgetall('NPC:' .. nid)
  if (npc.active_when or '') == '' or not npc.room then return true end
  local w = weather_at(npc.room)
  for axis, range in pairs(decode(npc.active_when)) do
    if w[axis] and (w[axis] < range[1] or w[axis] > range[2]) then return false end
  end
  return true
end

-- Puts an NPC (back) in its room. Hostile ones turn on whoever is there.
local function appear(nid, text)
  local room = redis.call('HGET', 'NPC:' .. nid, 'room')
  redis.call('SADD', 'ROOM:' .. room .. ':npcs', nid)
  emit('ROOM:' .. room, {type = 'arrive', entity = npc_card(nid), text = text})
  for _, pid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. room .. ':players')) do
    if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
      dispositions_event(pid, room)
      aggro(pid, room)
    end
  end
end

-- Brings back NPCs whose respawn time has come, unless the weather keeps
-- them hidden (then weather_tick brings them out when it turns).
local function respawn_due(now)
  local due = redis.call('ZRANGEBYSCORE', 'alz:respawns', '-inf', now)
  for _, nid in ipairs(due) do
    redis.call('ZREM', 'alz:respawns', nid)
    local npc = hgetall('NPC:' .. nid)
    if npc.room then
      redis.call('HSET', 'NPC:' .. nid, 'hp', npc.max_hp or 10)
      if npc_active(nid) then
        appear(nid, capitalize(npc_display(nid)) .. ' appears.')
      else
        redis.call('HSET', 'NPC:' .. nid, 'hidden', '1')
      end
    end
  end
  return #due
end

-- Weather NPCs hide when the weather turns against them (never mid-fight),
-- and come back when it suits them again.
local function weather_npcs()
  for _, nid in ipairs(sorted(redis.call('SMEMBERS', 'alz:weather_npcs'))) do
    local npc = hgetall('NPC:' .. nid)
    local active = npc_active(nid)
    local here = npc.room and redis.call('SISMEMBER', 'ROOM:' .. npc.room .. ':npcs', nid) == 1
    local who = capitalize(npc_display(nid))
    if npc.hidden == '1' and active then
      redis.call('HDEL', 'NPC:' .. nid, 'hidden')
      appear(nid, (npc.emerge or '') ~= '' and fill(npc.emerge, who) or who .. ' appears.')
    elseif here and not active and redis.call('EXISTS', 'NPC:' .. nid .. ':foes') == 0 then
      redis.call('SREM', 'ROOM:' .. npc.room .. ':npcs', nid)
      redis.call('HSET', 'NPC:' .. nid, 'hidden', '1')
      emit('ROOM:' .. npc.room, {type = 'leave', entity_id = 'npc:' .. nid,
        text = (npc.hide or '') ~= '' and fill(npc.hide, who) or who .. ' slips away.'})
    end
  end
end

-- The weather's slow beat, run every 30 s by one server: ground builds up,
-- each realm hears when its weather turns, weather NPCs hide or come out,
-- and every online player gets their weather and what it does to their gear.
-- REALM:<id>:ground.label remembers the last condition announced.
redis.register_function('weather_tick', function(keys, args)
  local now = now_ms()
  for _, realm in ipairs(sorted(redis.call('SMEMBERS', 'alz:realms'))) do
    update_ground(realm, now)
    local w = weather_in(realm_place(realm))
    local label = (zone(w) or 'mixed') .. '|' .. (falling(w) or 'dry') .. '|' .. (intensity(w) >= 0.5 and 'heavy' or 'light')
    local before = redis.call('HGET', 'REALM:' .. realm .. ':ground', 'label')
    redis.call('HSET', 'REALM:' .. realm .. ':ground', 'label', label)
    if before and before ~= label then
      emit('REALM:' .. realm, {type = 'weather_change', text = 'The weather over ' .. redis.call('HGET', 'REALM:' .. realm .. ':info', 'name')
        .. ' turns: ' .. describe_weather(w) .. (zone(w) and zone(w) ~= 'Temperate' and (' (' .. zone(w) .. ')') or '') .. '.'})
    end
  end
  weather_npcs()
  for _, pid in ipairs(redis.call('ZRANGE', 'alz:online', 0, -1)) do
    if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
      weather_event(pid)
      kit_event(pid)
    end
  end
  return 1
end)

redis.register_function('respawn', function(keys, args)
  return respawn_due(now_ms())
end)

-- The slow upkeep every server runs every few seconds: respawns, sleeping
-- bodies fading, and wounds healing out of a fight (faster somewhere safe).
redis.register_function('upkeep', function(keys, args)
  local now = now_ms()
  respawn_due(now)
  for _, pid in ipairs(redis.call('ZRANGEBYSCORE', 'alz:sleepers', '-inf', now)) do
    redis.call('ZREM', 'alz:sleepers', pid)
    fade_out(pid)
  end
  for _, pid in ipairs(redis.call('SMEMBERS', 'alz:wounded')) do
    local card = player_card(pid)
    if card.hp >= card.max_hp then
      redis.call('SREM', 'alz:wounded', pid)
    elseif redis.call('SCARD', 'PLAYER:' .. pid .. ':foes') == 0 and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
      local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
      local amount = is_safe(pid, rid) and rule('safe_regen', 10) or rule('regen', 2)
      -- Bitter cold outdoors slows healing, by up to half.
      local w = weather_at(rid)
      local cold = math.max(0, (-w.temperature - 0.5) / 0.5) * (1 - resilience(pid))
      if not w.indoor and cold > 0 then amount = math.max(1, round(amount * (1 - 0.5 * cold))) end
      redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', math.min(card.max_hp, card.hp + amount))
      emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
    end
  end
  return 1
end)

-- Lands every NPC attack that's due. Any server may call this, as often as it
-- likes: each attack is taken off the schedule as it lands.
redis.register_function('tick', function(keys, args)
  local now = now_ms()
  pending_moves_due(now)
  journeys_due(now)
  local due = redis.call('ZRANGEBYSCORE', 'alz:npc_attacks', '-inf', now, 'WITHSCORES', 'LIMIT', 0, 200)
  local touched, order = {}, {}
  for i = 1, #due, 2 do
    local member, at = due[i], tonumber(due[i + 1])
    redis.call('ZREM', 'alz:npc_attacks', member)
    local nid, n = string.match(member, '^(.+)#(%d+)$')
    local npc = hgetall('NPC:' .. nid)
    local attack = decode(npc.attacks)[tonumber(n)]
    if not attack or (tonumber(npc.hp) or 0) <= 0 or redis.call('SISMEMBER', 'ROOM:' .. (npc.room or '') .. ':npcs', nid) == 0 then
      stop_fighting(nid)
    else
      -- It attacks the first foe still here, and forgets anyone who has left.
      local target
      for _, pid in ipairs(redis.call('ZRANGE', 'NPC:' .. nid .. ':foes', 0, -1)) do
        if redis.call('SISMEMBER', 'ROOM:' .. npc.room .. ':players', pid) == 1 then
          target = pid
          break
        end
        drop_foe(nid, pid)
      end
      if not target then
        stop_fighting(nid)
      else
        local hp = player_card(target).hp - attack.damage
        redis.call('HSET', 'ACCOUNT:' .. target, 'hp', math.max(hp, 0))
        redis.call('SADD', 'alz:wounded', target)
        emit('ROOM:' .. npc.room, {type = 'combat', entity_id = 'npc:' .. nid, verb = attack.name, target = 'pc:' .. target,
          result = 'hit', damage = attack.damage,
          text = fill(attack.hit, capitalize(npc_display(nid)), name_of(target)) .. ' (' .. attack.damage .. ')'})
        if hp <= 0 then
          defeat(target, nid)
        else
          emit('ROOM:' .. npc.room, {type = 'entity', entity = player_card(target)})
        end
        if redis.call('HEXISTS', 'NPC:' .. nid .. ':next', n) == 1 then
          local later = at + attack.period
          if later <= now then later = now + attack.period end
          redis.call('HSET', 'NPC:' .. nid .. ':next', n, later)
          redis.call('ZADD', 'alz:npc_attacks', later, member)
          if not touched[nid] then
            touched[nid] = true
            order[#order + 1] = nid
          end
        end
      end
    end
  end
  for _, nid in ipairs(order) do npc_timing_event(nid) end
  return #due / 2
end)

-- The weather in a room at weather time t (default now), as JSON. Read-only;
-- tests compare it with alzendor/weather.py.
redis.register_function{function_name = 'weather_probe', flags = {'no-writes'}, callback = function(keys, args)
  local w = weather_at(args[1], tonumber(args[2]))
  w.zone, w.falling, w.intensity, w.summary = zone(w), falling(w), intensity(w), describe_weather(w)
  return cjson.encode(w)
end}

-- Ambient world events (bells, weather) published by the server's ticker.
redis.register_function('ambient', function(keys, args)
  local channel, text = args[1], args[2]
  if redis.call('EXISTS', channel .. ':info') == 0 then return 0 end
  emit(channel, {type = 'ambient', text = text})
  return 1
end)
