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
--
-- Conventions (the README's "Developing" has more):
-- * KEYS[1] is always the calling server's id: an encounter a call starts is
--   owned by that server.
-- * What a function returns: a player action (wrapped in `action`) emits its
--   own replies and returns 1, or 0 when the player isn't in the world (the
--   command layer tells them); `create_character` returns '' or why not;
--   `encounter_*` return JSON; the rest return 0 or 1. `notice` returns the
--   notice's sequence number, so a helper that refuses with
--   `return notice(...)` mustn't have its result read as "found".
-- * Arrays for clients are wrapped in `list()`.

-- Events kept per stream. A player's own stream needs only what a dropped
-- connection might resume from; a shared one is read by many.
local MAXLEN = {shared = 1000, player = 200}

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
  local cap = string.sub(channel, 1, 7) == 'PLAYER:' and MAXLEN.player or MAXLEN.shared
  redis.call('XADD', channel, 'MAXLEN', '~', cap, seq .. '-0', 'e', encode(event))
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

-- Hooks: functions defined further down (travel events, quests, talk, worn
-- gear...) for code earlier in the file (moving, dying) to call. Lua allows
-- 200 locals in the main chunk, and this file is near that, so sections
-- export what others need through this table, or a table of their own.
local hooks = {}

-- The server running this call (KEYS[1]): an encounter a call starts is owned by it.
local CALLER = {server = ''}

-- Replies given in more than one place, so they can't drift apart.
local TEXT = {
  in_a_fight = "You're in a fight. Get steady and press your flee key (F by default) to run back the way you came.",
}

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
-- What a point of each does. The balance ones (poise_core, focus_perfect,
-- resilience_debuff) are applied by balance.py's Rules.for_player and pinned
-- to these by tests/test_balance.py; the text below is built from them.
local STAT_FACTORS = {vigor_hp = 8, poise_core = 0.04, focus_perfect = 0.05, presence_rep = 0.15,
  resilience_weather = 0.1, resilience_weather_cap = 0.5, resilience_debuff = 0.05, resilience_debuff_cap = 0.5}
local STAT_INFO
do
  local F = STAT_FACTORS
  -- (No `math` while the library loads: rounded by hand.)
  local function pct(x) local n = x * 100 + 0.5 return (n - n % 1) .. '%' end
  STAT_INFO = {
    vigor = 'Vigor: ' .. F.vigor_hp .. ' more max health per point.',
    poise = 'Poise: the core of your balance ' .. pct(F.poise_core) .. ' wider per point, and a better chance of '
      .. 'going unnoticed and of spotting traps.',
    focus = 'Focus: the perfect centre of your balance ' .. pct(F.focus_perfect) .. ' wider per point.',
    presence = 'Presence: your deeds move reputation ' .. pct(F.presence_rep) .. ' further per point.',
    resilience = 'Resilience: softens what bad weather does to you by ' .. pct(F.resilience_weather) .. ' per point (up to '
      .. pct(F.resilience_weather_cap) .. '), and keeps the good; and debuffs wear off ' .. pct(F.resilience_debuff)
      .. ' sooner per point (up to ' .. pct(F.resilience_debuff_cap) .. ').',
  }
end
local BASE_HP, VIGOR_HP = 100, STAT_FACTORS.vigor_hp

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
  -- Trained points, an ancestry's bonus, worn gear (PLAYER:<id>:worn_stats),
  -- short-lived buffs (PLAYER:<id>:buff:<stat>), and boons.
  local value = trained(pid, name) + (tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':bonus', name)) or 0)
    + (tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':worn_stats', name)) or 0)
    + (tonumber(redis.call('GET', 'PLAYER:' .. pid .. ':buff:' .. name)) or 0)
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
    id = 'pc:' .. pid, kind = 'pc', name = account.name or pid, label = (account.label or '') ~= '' and account.label or 'Adventurer',
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
    attacks[#attacks + 1] = {name = a.name, period_ms = a.period, damage = a.damage, defend = a.defend or 'both', kick = a.kick,
      stagger = a.stagger or nil}
  end
  local faction = (npc.faction or '') ~= '' and redis.call('HGET', 'FACTION:' .. npc.faction, 'name')
  return {
    id = 'npc:' .. nid, kind = 'npc', name = npc.name or nid, label = npc.label or '',
    description = npc.description or '', hp = tonumber(npc.hp) or max_hp, max_hp = max_hp,
    icon = (npc.icon or '') ~= '' and npc.icon or nil, base_disposition = npc.disposition or 'neutral',
    faction = faction or nil, attacks = attacks, immortal = npc.immortal == '1', wary = (npc.notice or '') ~= '' or nil,
  }
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
  -- Dark rooms (caves, shuttered lofts) are always dark; lit ones (towns, with
  -- their lamps) never are, even at night.
  local dark, lit = info.dark == '1', info.lit == '1' or area.lit == '1'
  if climate then return {rid = rid, name = info.name, region = area.region, realm = realm, climate = climate, dark = dark, lit = lit} end
  local place = realm_place(realm)
  place.rid, place.name, place.region, place.dark, place.lit = rid, info.name, area.region, dark, lit
  place.nudge = decode(redis.call('HGET', 'alz:terrain_weather', (info.terrain or '') ~= '' and info.terrain or '-'))
  return place
end

-- The clock: one game day every day_minutes of real time (alz:clock_override
-- pins the hour, for admins and tests). A realm can have its own sky:
-- 'always_day' or 'always_night'.
-- `day` is how far through the day it is (0 to 1, midnight to midnight), and
-- day_ms how long a day takes when the clock is running, for the client's wheel.
local function clock(realm)
  local sky = realm and redis.call('HGET', 'REALM:' .. realm .. ':info', 'sky') or ''
  local day, day_ms
  if sky == 'always_day' then
    day = 0.5
  elseif sky == 'always_night' then
    day = 0
  elseif sky == 'always_dusk' then
    day = 19 / 24
  else
    local pinned = tonumber(redis.call('GET', 'alz:clock_override') or '')
    if pinned then
      day = pinned / 24
    else
      day_ms = rule('day_minutes', 60) * 60000
      day = now_ms() % day_ms / day_ms
    end
  end
  local hour = math.floor(day * 24 + 1e-9)
  local phase = (hour >= 5 and hour < 7 and 'dawn') or (hour >= 7 and hour < 18 and 'day')
    or (hour >= 18 and hour < 20 and 'dusk') or 'night'
  return {hour = hour, phase = phase, day = day, day_ms = day_ms, sky = sky ~= '' and sky or nil}
end

-- Perks are what a character has that isn't gear: ancestry passives, and the
-- old level perks.
local function has_perk(pid, perk)
  return pid ~= nil and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':perks', perk) == 1
end

-- Worn gear (alz:wearables) is what a character wears and carries: head, chest,
-- legs and a hand. PLAYER:<id>:worn maps each place onto what's in it. A torch
-- or lantern in hand is a light; a shield there lets you block.
hooks.worn = function(pid, place)
  local wid = pid and redis.call('HGET', 'PLAYER:' .. pid .. ':worn', place)
  if not wid then return nil end
  local w = decode(redis.call('HGET', 'alz:wearables', wid))
  if not w.name then return nil end
  w.id = wid
  return w
end

hooks.has_light = function(pid)
  local hand = hooks.worn(pid, 'hand')
  return hand ~= nil and hand.light == true
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
  w.region, w.realm, w.dark, w.lit = place.region, place.realm, place.dark, place.lit
  if not w.indoor and clock(place.realm).phase == 'night' then w.night = true end
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

-- In heavy rain or snow, in a dark room, or in the wilds at night (outdoors,
-- away from a town's lamps), you can't see far: no new exits, glimpses or
-- regions. A light in hand shows the way in the dark, but not through rain;
-- Starsight sees by starlight, but not underground.
local function can_see(w, pid)
  if not w.indoor and intensity(w) >= 0.5 then return false end
  if w.dark then return hooks.has_light(pid) end
  if w.indoor or w.lit or not w.night then return true end
  return hooks.has_light(pid) or has_perk(pid, 'starsight')
end

-- What's stopping you seeing: the rain, the snow, or the dark.
local function obscured_by(w)
  return not w.indoor and intensity(w) >= 0.5 and falling(w) or 'darkness'
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
  local r = math.min(STAT_FACTORS.resilience_weather_cap, STAT_FACTORS.resilience_weather * stat(pid, 'resilience'))
  if has_perk(pid, 'thick_hide') then r = 1 - (1 - r) * 0.5 end -- weather penalties halved again
  return r
end

local function soften(factor, r)
  if factor >= 1 then return factor end
  return 1 - (1 - factor) * (1 - r)
end

-- Walking pace: how long it takes to cross a room, by its ground: roads, towns
-- and indoors are quick, open country slower, rough ground slowest
-- (alz:terrain_ground maps terrains onto 'open' or 'rough'). The rule `pace`
-- scales them all (0 turns it off, for tests). Feather Step makes rough ground
-- no worse than open.
local STEP_MS = {road = 600, open = 900, rough = 1500}

local function ground_kind(rid)
  local info = hgetall('ROOM:' .. rid .. ':info')
  if info.indoor == '1' or (info.terrain or '') == '' then return 'road' end
  return redis.call('HGET', 'alz:terrain_ground', info.terrain) or 'open'
end

local function step_ms(pid, rid)
  local ground = ground_kind(rid)
  if ground == 'rough' and has_perk(pid, 'feather_step') then ground = 'open' end
  local slowed = redis.call('EXISTS', 'PLAYER:' .. pid .. ':slowed') == 1 and 2 or 1
  return math.floor(rule('step_' .. ground .. '_ms', STEP_MS[ground] or 900) * rule('pace', 1) * slowed)
end

-- A random number in [0, 1). Tests can queue the rolls they want in
-- alz:test_rolls.
local function roll()
  local queued = redis.call('LPOP', 'alz:test_rolls')
  if queued then return tonumber(queued) end
  return math.random()
end

-- Checks: one rule for traps, travel events and anything else that tests a
-- stat (docs/journeys.md, "Checks"). The chance is the difficulty's base plus
-- 12% a point in the stat, plus any bonus (a background that suits it, going
-- carefully), between 5% and 95%. Players see which stat, never the odds.
local DIFFICULTY = {easy = 0.5, fair = 0.3, hard = 0.1}

local function check_chance(pid, stat_name, difficulty, bonus)
  local chance = (DIFFICULTY[difficulty or 'fair'] or 0.3) + 0.12 * stat(pid, stat_name) + (bonus or 0)
  return clamp(chance, 0.05, 0.95)
end

local function passes(pid, stat_name, difficulty, bonus)
  return roll() < check_chance(pid, stat_name, difficulty, bonus)
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

-- The tier is the gear's weather sensitivity, 1 (grey: barely) to 5 (orange:
-- only works at its spot). Rarity is separate: how unusual a piece is. Very
-- sensitive gear is usually rare, so rarity defaults to the tier's.
local TIERS = {
  -- (The ring where a tier neither helps nor hurts, radius x peak / (peak + far),
  -- shrinks from 0.6 to 0.2 across the grid's 2 x 2: even plain gear cares.)
  grey = {peak = 0.20, far = 0.20, radius = 1.2, wet = 0.10, sensitivity = 1, rarity = 'common'},
  green = {peak = 0.30, far = 0.25, radius = 0.92, wet = 0.15, sensitivity = 2, rarity = 'uncommon'},
  blue = {peak = 0.45, far = 0.35, radius = 0.71, wet = 0.20, sensitivity = 3, rarity = 'rare'},
  purple = {peak = 0.65, far = 0.50, radius = 0.53, wet = 0.25, sensitivity = 4, rarity = 'epic'},
  orange = {peak = 1.00, far = 1.00, radius = 0.4, wet = 0.30, sensitivity = 5, rarity = 'legendary'},
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

-- What weather w does to a player's gear: the factor on its amounts, and one
-- line per modifier for the tooltip.
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
  if r > 0 and raw < 1 then
    mods[#mods + 1] = {label = 'Resilience ' .. stat(pid, 'resilience') .. ': penalties softened', pct = round(r * 100), on = 'resilience'}
  end
  local amounts = list()
  -- (The nudge keeps 10 x 1.15 from rounding down: in binary it's 11.4999...)
  for i, key in ipairs({'edge', 'clean', 'perfect'}) do amounts[i] = math.max(0, round(tonumber(gear[key]) * factor + 1e-9)) end
  return {factor = factor, amounts = amounts, mods = mods, profile = profile}
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
    intensity = intensity(w), summary = describe_weather(w), visibility = can_see(w, pid) and 'clear' or 'poor', clock = clock(w.realm),
    place = w.indoor and place.name or (w.region and redis.call('HGET', 'REGION:' .. w.region .. ':info', 'name')) or place.name,
    realm = w.realm and redis.call('HGET', 'REALM:' .. w.realm .. ':info', 'name') or nil}
  for _, axis in ipairs(AXES) do event[axis] = exact and w[axis] or round_to(w[axis], 0.5) end
  if not w.indoor then event.ground = ground_of(w.realm) end
  event.footing = ground_kind(rid)
  if units then
    local now, forecast = weather_time(), list()
    for i = 1, units * 4 do
      local f = weather_in(place, now + i / 4)
      forecast[i] = {minutes = i * rule('weather_unit_minutes', 30) / 4, temperature = f.temperature, energy = f.energy,
        precipitation = f.precipitation, summary = describe_weather(f)}
    end
    event.forecast = forecast
  elseif not w.indoor and has_perk(pid, 'skyreading') then
    -- Skyreading: no forecast, just which way it's heading in the next 10 minutes.
    local later = weather_in(place, weather_time() + 10 / rule('weather_unit_minutes', 30))
    local function way(d, up, down) return d > 0.05 and up or (d < -0.05 and down or nil) end
    local words = {}
    words[#words + 1] = way(later.temperature - w.temperature, 'warmer', 'colder')
    words[#words + 1] = way(later.energy - w.energy, 'wilder', 'stiller')
    words[#words + 1] = way(later.precipitation - w.precipitation, 'wetter', 'drier')
    event.heading = {temperature = later.temperature - w.temperature, energy = later.energy - w.energy,
      precipitation = later.precipitation - w.precipitation,
      text = #words > 0 and ('Turning ' .. table.concat(words, ', ') .. '.') or 'Holding steady.'}
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
  if (route.quest or '') ~= '' then
    -- Only for a player at that step of the quest: a way out they're shown when it's time.
    return redis.call('HGET', 'PLAYER:' .. pid .. ':quests', route.quest) == 'active'
      and redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. route.quest, 'step') == route.step
  end
  if route.hidden == '1' then return false end -- only a quest can put you on it
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
      exits = exits, explored = true, trap = redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':traps', rid) == 1 or nil}
    for _, dest in pairs(exits) do
      if not seen[dest] and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 0
        and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':glimpsed', dest) == 1 and region_state(pid, region_of(dest)) then
        seen[dest] = true
        local other = hgetall('ROOM:' .. dest .. ':info')
        rooms[#rooms + 1] = {id = dest, area = other.area, realm = area_realm(other.area), pos = room_pos(other), explored = false,
          trap = redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':traps', dest) == 1 or nil}
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
  -- And the ones they've only heard of.
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':rumours'))) do
    if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':realms', id) == 0 then
      realms[#realms + 1] = {id = id, name = redis.call('HGET', 'REALM:' .. id .. ':info', 'name') or id, rumour = true}
    end
  end
  -- Routes leaving rooms they've explored, drawn as dashed lines when both ends are known.
  local routes = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'alz:routes'))) do
    local route = hgetall('ROUTE:' .. id)
    if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', route.from) == 1 and route_offered(pid, route) then
      local path = list()
      for i, wp in ipairs(decode(route.path)) do path[i] = room_pos(hgetall('ROOM:' .. wp .. ':info')) end
      routes[#routes + 1] = {id = id, name = route.name, from = route.from, to = route.to, path = path, kind = route.kind,
        fare = tonumber(route.fare) or 0, command = route_command(route)}
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
-- Waypoints are the rooms a route passes through (see docs/journeys.md). You
-- can't walk into one, and a ride is private: riders aren't in the room's
-- player set or on its channel, so nobody sees anyone else on the road.
local function is_waypoint(rid)
  return rid ~= nil and redis.call('HGET', 'ROOM:' .. rid .. ':info', 'waypoint') == '1'
end

-- Where something a player says or does in a room is heard: the room, or,
-- for a rider alone on the road, only themselves.
local function here_channel(pid, rid)
  if is_waypoint(rid) and redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', pid) == 0 then return 'PLAYER:' .. pid end
  return 'ROOM:' .. rid
end

local function place_channels(pid, rid)
  local channels = {'PLAYER:' .. pid}
  if not is_waypoint(rid) or redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', pid) == 1 then
    channels[#channels + 1] = 'ROOM:' .. rid
  end
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
-- With them, what each will discuss with the player and how well they know
-- them (talk: card id -> {topics, rapport}), since that's theirs alone too.
local function dispositions_event(pid, rid)
  local map, talk = {}, {}
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
    map['npc:' .. nid] = disposition_for(pid, nid)
    if hooks.talk_card then talk['npc:' .. nid] = hooks.talk_card(pid, nid) end
  end
  return emit('PLAYER:' .. pid, {type = 'dispositions', dispositions = map, talk = talk})
end

-- Safe places: inns, shrines, camps. Leaving the world there is instant;
-- anywhere else you lie down to sleep and your body stays a while. Perks can
-- make a kind of terrain (forest, coast) safe for you.
local function is_safe(pid, rid)
  local info = hgetall('ROOM:' .. rid .. ':info')
  if info.safe == '1' or info.waypoint == '1' then return true end
  if (info.terrain or '') == '' then return false end
  for _, perk in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks')) do
    if redis.call('HGET', 'PERK:' .. perk, 'safe_terrain') == info.terrain then return true end
  end
  return false
end

-- World views -----------------------------------------------------------------

-- cause: 'look', 'move', 'enter' or 'resume' (a reconnecting client's refresh).
-- Quest items are personal: each player sees and takes their own copy
-- (ROOM:<rid>:qitems lists them; PLAYER:<id>:taken the ones a player has had).
local function quest_items_here(pid, rid)
  local out = {}
  for _, iid in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':qitems'))) do
    if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':taken', iid) == 0 then out[#out + 1] = iid end
  end
  return out
end

-- Seeing danger (docs/combat.md): the enemies in a room (NPCs with
-- attacks, hostile to this player; an ambusher only to its rider), and the
-- rooms past this one's exits that have any. Darkness and heavy rain or snow
-- hide them (here or there), unless the player has Hunter's Nose, which
-- smells them anyway. Worked out on arrival and on LOOK, never pushed live.
local function enemies_in(pid, rid)
  local out = {}
  for _, nid in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs'))) do
    local owner = redis.call('HGET', 'NPC:' .. nid, 'owner')
    if #npc_attacks(nid) > 0 and disposition_for(pid, nid) == 'hostile' and (not owner or owner == pid) then out[#out + 1] = nid end
  end
  return out
end

-- The rooms next door with enemies in them ({room ids}, and the directions
-- smelled rather than seen), as far as the player can tell.
local function danger_near(pid, rid)
  local rooms, smelled = list(), list()
  local here_seen = can_see(weather_at(rid), pid)
  local nose = has_perk(pid, 'hunters_nose')
  if not here_seen and not nose then return rooms, smelled end
  for _, dir in ipairs(sorted(redis.call('HKEYS', 'ROOM:' .. rid .. ':exits'))) do
    local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
    local seen = here_seen and can_see(weather_at(dest), pid)
    if (seen or nose) and #enemies_in(pid, dest) > 0 then
      rooms[#rooms + 1] = dest
      if not seen then smelled[#smelled + 1] = dir end
    end
  end
  return rooms, smelled
end

local function room_event(pid, rid, cause)
  local info = hgetall('ROOM:' .. rid .. ':info')
  -- In heavy rain or snow, only the ways you already know show.
  local w = weather_at(rid)
  local exits, hidden = list(), false
  for _, dir in ipairs(sorted(redis.call('HKEYS', 'ROOM:' .. rid .. ':exits'))) do
    local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
    if can_see(w, pid) or redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 1 then
      exits[#exits + 1] = dir
    else
      hidden = true
    end
  end
  local items, item_names = list(), {}
  for _, iid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':items')) do
    items[#items + 1] = {id = iid, name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid}
  end
  for _, iid in ipairs(quest_items_here(pid, rid)) do
    items[#items + 1] = {id = iid, name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid, quest = true}
  end
  table.sort(items, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
  for i, item in ipairs(items) do item_names[i] = item.name end
  local features = sorted(list(redis.call('HKEYS', 'ROOM:' .. rid .. ':features')))
  local entities, entity_names = list(), {}
  for _, p in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':players')) do
    if p ~= pid and info.waypoint ~= '1' then entities[#entities + 1] = player_card(p) end -- rides are private
  end
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
    local owner = redis.call('HGET', 'NPC:' .. nid, 'owner')
    if not owner or owner == pid then
      local card = npc_card(nid)
      card.disposition, card.fighting = disposition_for(pid, nid), redis.call('EXISTS', 'NPC:' .. nid .. ':encounter') == 1 or nil
      local talk = hooks.talk_card(pid, nid) or {}
      card.topics, card.rapport = talk.topics, talk.rapport
      entities[#entities + 1] = card
    end
  end
  table.sort(entities, by_card_order)
  for i, card in ipairs(entities) do entity_names[i] = card.name end
  local area = info.area and redis.call('HGET', 'AREA:' .. info.area .. ':info', 'name')

  local dark = not can_see(w, pid) and obscured_by(w) == 'darkness'
  -- Pitch dark: nothing on the floor or round the walls shows either.
  if dark and w.dark then items, item_names, features = list(), {}, list() end
  local lines = {info.name or rid, info.description or ''}
  if dark and w.dark then lines[2] = "It's pitch dark. You can't see a thing." end
  lines[#lines + 1] = 'Exits: ' .. (#exits > 0 and table.concat(exits, ', ') or 'none')
    .. (hidden and (' (the ' .. obscured_by(w) .. ' hides any other ways on)') or '')
  if dark then lines[#lines + 1] = 'You need a light to find your way: EQUIP TORCH.' end
  if w.night then lines[#lines + 1] = 'It is night.' end
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
  -- Danger next door, as a ring on the map; with Hunter's Nose, what you can't see you smell.
  local danger, scents = danger_near(pid, rid)
  if #scents > 0 then lines[#lines + 1] = 'You smell something to the ' .. table.concat(scents, ', ') .. '.' end

  return emit('PLAYER:' .. pid, {
    type = 'room',
    cause = cause,
    room = {
      id = rid, name = info.name, description = lines[2], area = area or nil,
      exits = exits, exits_hidden = hidden, routes = routes, items = items, features = features, entities = entities,
      dark = dark or nil, self = player_card(pid), safe = is_safe(pid, rid), indoor = w.indoor or false, step_ms = step_ms(pid, rid),
      waypoint = info.waypoint == '1' or nil, pos = info.waypoint == '1' and room_pos(info) or nil,
      scents = #scents > 0 and scents or nil, danger = danger,
    },
    text = table.concat(lines, '\n'),
  })
end

local function match_ids(ids, word)
  for _, iid in ipairs(ids) do
    local item = hgetall('ITEM:' .. iid)
    local words = ' ' .. (item.keywords or '') .. ' ' .. string.lower(item.name or '') .. ' '
    if iid == word or string.find(words, ' ' .. word .. ' ', 1, true) then return iid, item end
  end
end

local function match_item(set_key, word)
  return match_ids(redis.call('SMEMBERS', set_key), word)
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
  if not iid then iid, item = match_ids(quest_items_here(pid, rid), word) end
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
    CALLER.server = keys and keys[1] or ''
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
-- spell, a potion. The game treats them all alike. In a fight (an encounter,
-- below) a slot strikes while the player keeps their balance: its gear's
-- `cooldown` before it can again, its `kick` knocking them off centre, and its
-- amounts by how centred they were (edge, clean, perfect). The simulation is
-- alzendor/balance.py; docs/combat.md is the whole design.
-- PLAYER:<id>:slots maps slot numbers onto gear ids.

local SLOTS = 3

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

local passive = {}

-- Passives attuned to a slot (PLAYER:<id>:attuned maps passive -> slot) and
-- their state: PLAYER:<id>:charge:<n> holds a slot's stacked bonus (Moonlit
-- Edge, Bloodrhythm), PLAYER:<id>:sealed the slots sealed for the rest of a
-- fight (Berserk Seal). Leaving a fight clears the seals.

function passive.attuned(pid, n)
  local out = {}
  for perk, slot in pairs(hgetall('PLAYER:' .. pid .. ':attuned')) do
    if tonumber(slot) == n and has_perk(pid, perk) then out[perk] = true end
  end
  return out
end

function passive.slot_sealed(pid, n)
  return redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':sealed', n) == 1
end

function passive.add_charge(pid, n, by)
  local key = 'PLAYER:' .. pid .. ':charge:' .. n
  redis.call('SET', key, math.min(3, (tonumber(redis.call('GET', key)) or 0) + by), 'EX', 60)
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

-- Refuses to change gear in a fight: loadouts are chosen before one.
-- Returns true if it refused.
local function mid_fight(pid)
  if not redis.call('GET', 'PLAYER:' .. pid .. ':encounter') then return false end
  notice(pid, "You can't change your gear mid-fight.")
  return true
end

-- Encounters -------------------------------------------------------------------
-- Every fight is an encounter (docs/combat.md). A player and an enemy
-- hostile to them in the same room fight, or you strike first. One server, the
-- encounter's owner (alzendor/encounter.py), simulates every dot in it and the
-- NPCs' attack clock; it calls encounter_strike and encounter_blow here for
-- what each strike and blow does. Everything that happens to the world happens
-- here, in the global event order.
--
-- ENC:<id>: room, kind (pve or duel), seed, start_ms, owner (server id).
-- ENC:<id>:players, ENC:<id>:npcs: who's in it, by when they joined (ms).
-- ENC:<id>:lease: the owner's server id, which it refreshes; when it lapses,
--   any server ends the encounter (and the one rule starts a fresh one).
-- ENC:<id>:ambush: 'pid|nid' pairs whose first strike is an ambush.
-- ENC:<id>:opening: pid -> 'slot|target', the strike that started it.
-- alz:encounters: live ids. alz:new_encounters: a stream every server reads to
--   find the encounters it owns.
-- PLAYER:<id>:encounter, NPC:<id>:encounter: the encounter each is in.
-- ROOM:<id>:encounter: the room's fight, which arrivals join. (An ambush on
--   the road is its rider's alone, and isn't the room's.)
-- The owner hears about changes on enc:<id>:in ({"op": "sync"} and {"op": "end"}).
local enc = {}

function enc.of_player(pid) return redis.call('GET', 'PLAYER:' .. pid .. ':encounter') or nil end
function enc.of_npc(nid) return redis.call('GET', 'NPC:' .. nid .. ':encounter') or nil end

local function enc_key(id, part) return 'ENC:' .. id .. (part and (':' .. part) or '') end

-- What a player brings to an encounter: their slots' gear, shield and stats.
function enc.player_info(pid)
  local slots = {}
  for n = 1, SLOTS do
    local g = slot_gear(pid, n)
    if g then
      slots[tostring(n)] = {gear = g.id, name = g.name, effect = g.effect, targets = g.targets, cooldown = tonumber(g.cooldown) or 0,
        kick = tonumber(g.kick) or 0, pattern = (g.pattern or '') ~= '' and g.pattern or 'bump', hits = tonumber(g.hits) or 1,
        gap = tonumber(g.gap) or 0, debuff = (g.debuff or '') ~= '' and decode(g.debuff) or nil}
    end
  end
  local hand = hooks.worn(pid, 'hand')
  -- Passives that work on the dot; and the slot Berserk Seal seals at the first stagger.
  local perks = list()
  for _, perk in ipairs({'second_wind', 'steady_hands', 'long_breath'}) do
    if has_perk(pid, perk) then perks[#perks + 1] = perk end
  end
  local berserk = has_perk(pid, 'berserk_seal') and tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':attuned', 'berserk_seal')) or nil
  return {pid = pid, name = name_of(pid), slots = slots, shield = hand and hand.type == 'shield' and (tonumber(hand.block) or 1) or 0,
    stats = {poise = stat(pid, 'poise'), focus = stat(pid, 'focus'), resilience = stat(pid, 'resilience')},
    perks = perks, berserk = berserk}
end

function enc.npc_info(nid)
  local npc = hgetall('NPC:' .. nid)
  local attacks = list()
  for i, a in ipairs(decode(npc.attacks)) do
    attacks[i] = {name = a.name, period = a.period, damage = a.damage, kick = a.kick or 0, warn = a.warn,
      defend = a.defend or 'both', stagger = a.stagger or false, debuff = a.debuff}
  end
  return {nid = nid, id = 'npc:' .. nid, name = npc.name or nid, display = npc_display(nid), keywords = npc.keywords or '',
    max_hp = tonumber(npc.max_hp) or 10, poise = tonumber(npc.poise) or 0, attacks = attacks}
end

-- The rules an encounter plays by, as the client and the owner get them.
function enc.rules()
  local out = {}
  local all = redis.call('HGETALL', 'alz:rules')
  for i = 1, #all, 2 do
    local name = all[i]
    if string.sub(name, 1, 8) == 'balance_' or string.sub(name, 1, 10) == 'encounter_' or name == 'defend_perfect_ms' then
      out[name] = all[i + 1]
    end
  end
  return out
end

-- Everything about an encounter: for the owner, and for a player as it starts.
function enc.info(id)
  local e = hgetall(enc_key(id))
  if not e.room then return nil end
  local players, npcs = list(), list()
  local zp = redis.call('ZRANGE', enc_key(id, 'players'), 0, -1, 'WITHSCORES')
  for i = 1, #zp, 2 do
    local p = enc.player_info(zp[i])
    p.join_ms = tonumber(zp[i + 1])
    players[#players + 1] = p
  end
  local zn = redis.call('ZRANGE', enc_key(id, 'npcs'), 0, -1, 'WITHSCORES')
  for i = 1, #zn, 2 do
    local n = enc.npc_info(zn[i])
    n.join_ms = tonumber(zn[i + 1])
    npcs[#npcs + 1] = n
  end
  local opening = {}
  for pid, v in pairs(hgetall(enc_key(id, 'opening'))) do
    local slot, target = string.match(v, '^(%d+)|(.*)$')
    opening[pid] = {slot = tonumber(slot), target = target}
  end
  return {id = id, room = e.room, kind = e.kind, seed = e.seed, start_ms = tonumber(e.start_ms), owner = e.owner,
    lead_ms = rule('encounter_lead_ms', 1000), hz = rule('encounter_hz', 30), rules = enc.rules(),
    players = players, npcs = npcs, opening = opening}
end

-- Tells the owner the encounter has changed.
function enc.sync(id, op)
  redis.call('PUBLISH', 'enc:' .. id .. ':in', cjson.encode({op = op or 'sync'}))
end

-- Tells every player in it something (an encounter event), but `except`.
function enc.tell(id, event, except)
  event.type, event.id = 'encounter', id
  for _, pid in ipairs(redis.call('ZRANGE', enc_key(id, 'players'), 0, -1)) do
    if pid ~= except then emit('PLAYER:' .. pid, event) end
  end
end

-- A new encounter in a room, owned by the server that caused it.
function enc.create(rid, kind, room_fight)
  local id = 'e' .. redis.call('INCR', 'alz:encounter_seq')
  local now = now_ms()
  local owner = CALLER.server
  redis.call('HSET', enc_key(id), 'room', rid, 'kind', kind or 'pve', 'seed', id .. ':' .. now, 'start_ms', now, 'owner', owner)
  redis.call('SET', enc_key(id, 'lease'), owner, 'PX', 3000)
  redis.call('SADD', 'alz:encounters', id)
  if room_fight then redis.call('SET', 'ROOM:' .. rid .. ':encounter', id) end
  redis.call('XADD', 'alz:new_encounters', 'MAXLEN', '~', 1000, '*', 'id', id, 'owner', owner)
  return id
end

function enc.add_player(id, pid)
  if enc.of_player(pid) == id then return end
  redis.call('ZADD', enc_key(id, 'players'), 'NX', now_ms(), pid)
  redis.call('SET', 'PLAYER:' .. pid .. ':encounter', id)
  redis.call('DEL', 'PLAYER:' .. pid .. ':sealed')
  enc.tell(id, {op = 'join', who = 'pc:' .. pid, name = name_of(pid)}, pid)
  emit('PLAYER:' .. pid, {type = 'encounter', op = 'start', id = id, encounter = enc.info(id)})
  enc.sync(id)
end

function enc.add_npc(id, nid)
  if enc.of_npc(nid) == id then return end
  redis.call('ZADD', enc_key(id, 'npcs'), 'NX', now_ms(), nid)
  redis.call('SET', 'NPC:' .. nid .. ':encounter', id)
  enc.tell(id, {op = 'join', who = 'npc:' .. nid, name = npc_display(nid), npc = enc.npc_info(nid)})
  enc.sync(id)
end

-- An NPC out of its fight: bleeding stops, and if it's hurt, upkeep heals it.
function enc.release_npc(nid)
  redis.call('DEL', 'NPC:' .. nid .. ':encounter', 'NPC:' .. nid .. ':bleed')
  local npc = hgetall('NPC:' .. nid)
  if (tonumber(npc.hp) or 0) > 0 and (tonumber(npc.hp) or 0) < (tonumber(npc.max_hp) or 0) then
    redis.call('SADD', 'alz:wounded_npcs', nid)
  end
end

-- Ends an encounter for everyone: why is won (no NPCs left), empty (no players
-- left), lost (its owner went away) or anything else worth saying.
function enc.finish(id, why)
  local rid = redis.call('HGET', enc_key(id), 'room')
  for _, pid in ipairs(redis.call('ZRANGE', enc_key(id, 'players'), 0, -1)) do
    redis.call('DEL', 'PLAYER:' .. pid .. ':encounter', 'PLAYER:' .. pid .. ':sealed')
    emit('PLAYER:' .. pid, {type = 'encounter', op = 'end', id = id, why = why})
  end
  for _, nid in ipairs(redis.call('ZRANGE', enc_key(id, 'npcs'), 0, -1)) do enc.release_npc(nid) end
  if rid and redis.call('GET', 'ROOM:' .. rid .. ':encounter') == id then redis.call('DEL', 'ROOM:' .. rid .. ':encounter') end
  redis.call('DEL', enc_key(id), enc_key(id, 'players'), enc_key(id, 'npcs'), enc_key(id, 'lease'), enc_key(id, 'ambush'), enc_key(id, 'opening'))
  redis.call('SREM', 'alz:encounters', id)
  enc.sync(id, 'end')
end

-- A player leaves their encounter (fled, died, left, gone). The last one out ends it.
function enc.drop_player(pid, why)
  local id = enc.of_player(pid)
  if not id then return end
  redis.call('ZREM', enc_key(id, 'players'), pid)
  redis.call('HDEL', enc_key(id, 'opening'), pid)
  redis.call('DEL', 'PLAYER:' .. pid .. ':encounter', 'PLAYER:' .. pid .. ':sealed')
  emit('PLAYER:' .. pid, {type = 'encounter', op = 'end', id = id, why = why})
  if redis.call('ZCARD', enc_key(id, 'players')) == 0 then return enc.finish(id, 'empty') end
  enc.tell(id, {op = 'leave', who = 'pc:' .. pid, why = why})
  enc.sync(id)
end

-- An NPC leaves its encounter (died, gone). When none are left, it's won.
function enc.drop_npc(nid, why)
  local id = enc.of_npc(nid)
  if not id then return end
  redis.call('ZREM', enc_key(id, 'npcs'), nid)
  enc.release_npc(nid)
  if redis.call('ZCARD', enc_key(id, 'npcs')) == 0 then return enc.finish(id, 'won') end
  enc.tell(id, {op = 'leave', who = 'npc:' .. nid, why = why})
  enc.sync(id)
end

-- The encounter a player would join in this room: their own, or the room's.
function enc.here(pid, rid)
  local id = enc.of_player(pid) or redis.call('GET', 'ROOM:' .. rid .. ':encounter')
  if id and redis.call('HGET', enc_key(id), 'room') == rid then return id end
end

-- Tells a (re)connecting player about the fight they're in.
function enc.resend(pid)
  local id = enc.of_player(pid)
  if id then emit('PLAYER:' .. pid, {type = 'encounter', op = 'start', id = id, encounter = enc.info(id), resumed = true}) end
end

-- An enemy: an NPC with attacks, hostile to this player (an ambusher only to
-- its rider).
local function enemy_of(pid, nid)
  local owner = redis.call('HGET', 'NPC:' .. nid, 'owner')
  return #npc_attacks(nid) > 0 and disposition_for(pid, nid) == 'hostile' and (not owner or owner == pid)
end

-- Hostile NPCs in the room turn on a player (who is awake and in it). A wary
-- one (`notice`: how hard it is to slip past) only does if it notices them:
-- a Poise check, easier when creeping (`careful`). Unnoticed, the player has a
-- while (PLAYER:<id>:unseen:<nid>) before it's checked again; attacking it
-- starts a fight all the same.
local function noticed(pid, nid, careful)
  local how = redis.call('HGET', 'NPC:' .. nid, 'notice')
  if not how or how == '' then return true end
  local key = 'PLAYER:' .. pid .. ':unseen:' .. nid
  if redis.call('EXISTS', key) == 1 then return false end
  if passes(pid, 'poise', how, careful and 0.25 or 0) then
    redis.call('SET', key, '1', 'PX', rule('unseen_ms', 60000))
    notice(pid, capitalize(npc_display(nid)) .. " hasn't noticed you. Don't touch it, and don't linger. (Poise check; CREEP helps)")
    return false
  end
  return true
end

-- The one rule: a player and an enemy hostile to them, in the same room, fight.
-- Enemies here that aren't in a fight and notice the player join the room's
-- fight, or the player's own, or start one; and a player walking in on a fight
-- whose NPCs are hostile to them joins it. Called wherever a player or an
-- enemy arrives, and when reputation turns an NPC hostile.
local function aggro(pid, rid, careful)
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 0 or redis.call('GET', 'PLAYER:' .. pid .. ':room') ~= rid then return end
  if redis.call('HGET', 'ACCOUNT:' .. pid, 'asleep') == '1' then return end
  local id = enc.here(pid, rid)
  local mine = id and enc.of_player(pid) == id
  local fresh, ambushers = {}, false
  for _, nid in ipairs(sorted(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs'))) do
    if not enc.of_npc(nid) and enemy_of(pid, nid) and noticed(pid, nid, careful) then
      fresh[#fresh + 1] = nid
      if redis.call('HGET', 'NPC:' .. nid, 'owner') then ambushers = true end
    end
  end
  -- Walking in on a fight: join it if its NPCs are hostile to you.
  local join = mine
  if id and not mine then
    for _, nid in ipairs(redis.call('ZRANGE', enc_key(id, 'npcs'), 0, -1)) do
      if enemy_of(pid, nid) then join = true end
    end
    if #fresh > 0 then join = true end
  end
  if not join and #fresh == 0 then return end
  if not join then id = enc.create(rid, 'pve', not ambushers) end
  for _, nid in ipairs(fresh) do
    enc.add_npc(id, nid)
    emit('ROOM:' .. rid, {type = 'emote', verb = 'aggro', entity_id = 'npc:' .. nid, target = 'pc:' .. pid,
      text = capitalize(npc_display(nid)) .. ' turns on ' .. name_of(pid) .. '!'})
  end
  enc.add_player(id, pid)
end

-- Character -----------------------------------------------------------------------
-- Experience comes from defeating NPCs. Each level gives a stat point to spend
-- ('train <stat>') and whatever the seed's level table grants: gear, or perks.

-- A piece of gear for the client: what it is, its weather profile, and (with
-- the player and the weather) what it does right now and why.
local function gear_summary(g, pid, w)
  local summary = {id = g.id, name = g.name, kind = g.kind, effect = g.effect, targets = g.targets ~= '' and g.targets or 'self',
    description = g.description or '',
    amounts = list({tonumber(g.edge), tonumber(g.clean), tonumber(g.perfect)}),
    cooldown_ms = tonumber(g.cooldown) or 0, kick = tonumber(g.kick) or 0, pattern = (g.pattern or '') ~= '' and g.pattern or 'bump',
    hits = tonumber(g.hits) or 1, gap_ms = tonumber(g.gap) or 0, debuff = (g.debuff or '') ~= '' and decode(g.debuff) or nil}
  local tier = TIERS[gear_profile(g).tier]
  summary.sensitivity, summary.rarity = tier.sensitivity, (g.rarity or '') ~= '' and g.rarity or tier.rarity
  if (tonumber(g.stagger_ms) or 0) > 0 then summary.stagger_ms = tonumber(g.stagger_ms) end
  if (g.bleed or '') ~= '' then summary.bleed = decode(g.bleed) end
  if pid then
    local wx = weathered(pid, g, w)
    summary.weather = wx.profile
    -- The client draws and words the gear's spot with these (it keeps no copy of TIERS or zone).
    local t = TIERS[wx.profile.tier] or TIERS.grey
    summary.weather.ring = {peak = t.peak, far = t.far, radius = t.radius}
    summary.weather.zone = zone(wx.profile)
    summary.now = {factor = wx.factor, amounts = wx.amounts, mods = wx.mods}
  end
  return summary
end

-- Items carried: what counts against pack_size. Gear doesn't: it can't be
-- dropped or sold, and the game hands out only so much of it, so counting it
-- would fill the pack until quest items couldn't be picked up.
local function pack_count(pid)
  return redis.call('SCARD', 'PLAYER:' .. pid .. ':inv')
end
hooks.pack_full = function(pid) return pack_count(pid) >= rule('pack_size', 12) end

-- The gear a player owns, quickest first.
local function owned_gear(pid)
  local all = list()
  for _, gid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':gear')) do
    local g = gear_info(gid)
    if g then all[#all + 1] = g end
  end
  table.sort(all, function(a, b)
    local pa, pb = tonumber(a.cooldown) or 0, tonumber(b.cooldown) or 0
    if pa ~= pb then return pa < pb end
    return a.name < b.name
  end)
  return all
end

-- The player's inventory and slots, for the client's panels.
-- `if_changed`: only if it differs from the last kit sent (the weather tick
-- would otherwise send every online player an unchanged kit every 30 s).
local function kit_event(pid, if_changed)
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
  local event = {type = 'kit', gear = gear, slots = slots, items = items,
    pack = pack_count(pid), pack_size = rule('pack_size', 12), coins = tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'coins')) or 0}
  local sum = redis.sha1hex(encode(event))
  if if_changed and redis.call('GET', 'PLAYER:' .. pid .. ':kit_sum') == sum then return end
  redis.call('SET', 'PLAYER:' .. pid .. ':kit_sum', sum)
  return emit('PLAYER:' .. pid, event)
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
    perks[#perks + 1] = {id = id, name = perk.name or id, description = perk.description or '', slot = perk.slot == '1',
      attuned = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':attuned', id))}
  end
  local card = player_card(pid)
  local event = {type = 'character', level = level, xp = tonumber(account.xp) or 0,
    xp_next = xp_needed(level), points = tonumber(account.points) or 0, stats = stats, trained = trained_stats, boons = boons,
    stat_order = list(STATS), stat_info = STAT_INFO, perks = perks,
    factions = factions_of(pid), hp = card.hp, max_hp = card.max_hp, level_cap = rule('level_cap', 20)}
  hooks.choices(pid, account, event)
  local hand = hooks.worn(pid, 'hand')
  event.defence = {mode = hand and hand.type == 'shield' and 'block' or 'dodge', block = hand and hand.type == 'shield' and (tonumber(hand.block) or 1) or nil}
  return emit('PLAYER:' .. pid, event)
end

-- Adds gear to a player's inventory; true if they didn't have it.
local function grant_gear(pid, gid)
  return gear_info(gid) ~= nil and redis.call('SADD', 'PLAYER:' .. pid .. ':gear', gid) == 1
end

local function gain_xp(pid, amount)
  if amount <= 0 then return end
  local key = 'ACCOUNT:' .. pid
  local cap = rule('level_cap', 20)
  if level_of(pid) >= cap then return end
  if has_perk(pid, 'quick_study') then amount = math.ceil(amount * 1.1) end
  local xp, level = redis.call('HINCRBY', key, 'xp', amount), level_of(pid)
  notice(pid, 'You gain ' .. amount .. ' experience.')
  local leveled = false
  while xp >= xp_needed(level) and level < cap do
    xp, level, leveled = xp - xp_needed(level), level + 1, true
    redis.call('HSET', key, 'xp', xp, 'level', level)
    redis.call('HINCRBY', key, 'points', 1)
    local also = {}
    if level % 3 == 0 then also[#also + 1] = 'a talent to learn' end
    if level % 5 == 0 then also[#also + 1] = 'an ancestry passive to choose' end
    notice(pid, 'You reach level ' .. level .. '! You have a stat point to spend (TRAIN <stat>)'
      .. (#also > 0 and (', and ' .. table.concat(also, ' and ') .. ' (LEARN <name>, or the Character panel)') or '') .. '.')
  end
  if level >= cap then redis.call('HSET', key, 'xp', 0) end
  if leveled then
    emit('ROOM:' .. redis.call('GET', 'PLAYER:' .. pid .. ':room'), {type = 'entity', entity = player_card(pid)})
    kit_event(pid)
    hooks.quest(pid, 'check', {})
  end
  character_event(pid)
end

-- Something a player did involving an NPC. Every faction's culture judges it.
-- Deeds: kill, clean_kill (a perfect killing blow), ambush (striking an NPC
-- that wasn't fighting you), flee (leaving a fight), defeated (falling to
-- one), heal (healing one), greet and taunt (bow, wave… / laugh, poke…).
-- Moves a faction's opinion of a player (scaled by Presence unless `flat`),
-- and tells them why. Returns true if it moved.
local function shift_rep(pid, fid, da, dr, notes, flat)
  local faction = hgetall('FACTION:' .. fid)
  if not faction.name then return false end
  local scale = flat and 1 or (1 + STAT_FACTORS.presence_rep * stat(pid, 'presence'))
  local a, r = rep_of(pid, fid)
  local na = math.max(-100, math.min(100, a + round(da * scale)))
  local nr = math.max(-100, math.min(100, r + round(dr * scale)))
  if na == a and nr == r then return false end
  redis.call('HSET', 'PLAYER:' .. pid .. ':rep:' .. fid, 'affinity', na, 'respect', nr)
  local moved = {}
  if na ~= a then moved[#moved + 1] = 'affinity ' .. signed(na - a) end
  if nr ~= r then moved[#moved + 1] = 'respect ' .. signed(nr - r) end
  emit('PLAYER:' .. pid, {type = 'reputation', faction = fid, faction_name = faction.name, affinity = na, respect = nr,
    text = faction.name .. ': ' .. (#notes > 0 and (table.concat(notes, ' ') .. ' ') or '') .. '(' .. table.concat(moved, ', ') .. ')'})
  return true
end

-- What follows any change in reputation: the character sheet, regions it
-- reveals, and how the NPCs here now treat the player.
local function after_rep(pid)
  character_event(pid)
  reveal_by_reputation(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
    dispositions_event(pid, rid)
    aggro(pid, rid)
  end
end

local function deed(pid, name, nid)
  local subject = hgetall('NPC:' .. nid)
  local of, role = subject.faction or '', subject.role or ''
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
    if shift_rep(pid, fid, da, dr, notes) then changed = true end
  end
  if changed then after_rep(pid) end
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
  local old = place_channels(pid, rid)
  if redis.call('SREM', 'ROOM:' .. rid .. ':players', pid) == 1 then
    emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = verb, target = target, entity_id = 'pc:' .. pid, text = leave})
  end
  redis.call('SET', 'PLAYER:' .. pid .. ':room', dest)
  redis.call('DEL', 'PLAYER:' .. pid .. ':came') -- finish_move sets it again for a walk
  if not is_waypoint(dest) then
    redis.call('SADD', 'ROOM:' .. dest .. ':players', pid)
    emit('ROOM:' .. dest, {type = 'arrive', actor = pid, verb = verb, target = target, entity = player_card(pid), text = arrive})
  end
  local new = place_channels(pid, dest)
  resubscribe(pid, minus(new, old), minus(old, new))
  if is_waypoint(dest) then return end
  local visible = can_see(weather_at(dest), pid)
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
  -- Beaten on the road: thrown off it, not killed.
  if redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'ambush') then
    return hooks.strand(pid, 'You go down under the blows, and the world goes dark. You come to far below the road, battered and alone. The ride, and your fare, are long gone.')
  end
  local key, me = 'ACCOUNT:' .. pid, name_of(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  hooks.check_priority(pid, rid, true)
  -- Death ends any journey (a marooning included): you wake at home.
  redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
  redis.call('ZREM', 'alz:journeys', pid)
  enc.drop_player(pid, 'died')
  local lost = math.min(tonumber(redis.call('HGET', key, 'xp')) or 0, math.floor(xp_needed(level_of(pid)) / 10))
  redis.call('HSET', key, 'hp', math.floor(max_hp_of(pid) / 2), 'xp', (tonumber(redis.call('HGET', key, 'xp')) or 0) - lost)
  -- Home to the shrine; a realm can have its own (a starting realm's is where you began).
  local shrine = redis.call('HGET', 'REALM:' .. (realm_of(rid) or '') .. ':info', 'shrine')
  if (shrine or '') == '' then shrine = redis.call('HGET', 'alz:rules', 'shrine_room') or redis.call('GET', 'alz:start_room') end
  emit('ROOM:' .. rid, {type = 'death', entity_id = 'pc:' .. pid, text = me .. ' collapses.'})
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
    relocate(pid, rid, shrine, 'defeat', nil, me .. "'s body fades away.", me .. ' stumbles out of the shrine, pale and shaken.')
    room_event(pid, shrine, 'move')
    weather_event(pid)
    notice(pid, 'You were defeated, and wake at the shrine' .. (lost > 0 and (', ' .. lost .. ' experience poorer') or '') .. '.')
    if nid then deed(pid, 'defeated', nid) end
    character_event(pid)
  else
    redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
    redis.call('ZREM', 'alz:sleepers', pid)
    redis.call('HDEL', key, 'asleep')
    redis.call('SET', 'PLAYER:' .. pid .. ':room', shrine)
    emit('ROOM:' .. rid, {type = 'leave', verb = 'defeat', entity_id = 'pc:' .. pid, text = me .. "'s body fades away."})
    if nid then deed(pid, 'defeated', nid) end
  end
end

-- A sleeping body left out in the open fades from the world.
local function fade_out(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  redis.call('HDEL', 'ACCOUNT:' .. pid, 'asleep')
  enc.drop_player(pid, 'gone')
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
  local trapped = kind == 'feature' and redis.call('HGET', 'ROOM:' .. rid .. ':signs', id)
  if trapped then hooks.read_sign(pid, rid, trapped) end
  if kind ~= 'self' and kind ~= 'carried' then
    emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'inspect', target = id, text = name_of(pid) .. ' examines ' .. display .. '.'})
  end
end

-- LOOK <direction>: what's that way. The room's name and the enemies in it,
-- as cards, or why you can't see; with Hunter's Nose, what you smell there.
-- It refreshes the danger rings too.
local function look_toward(pid, rid, dir, dest)
  local here_w, there_w = weather_at(rid), weather_at(dest)
  local seen = can_see(here_w, pid) and can_see(there_w, pid)
  local enemies = enemies_in(pid, dest)
  local danger = danger_near(pid, rid)
  local name = redis.call('HGET', 'ROOM:' .. dest .. ':info', 'name') or dest
  local event = {type = 'look', dir = dir, room = dest, danger = danger}
  if seen then
    local cards, names = list(), {}
    for i, nid in ipairs(enemies) do
      local card = npc_card(nid)
      card.disposition = 'hostile'
      cards[i], names[i] = card, npc_display(nid)
    end
    event.name, event.entities = name, cards
    event.text = capitalize(dir) .. ': ' .. name .. '. '
      .. (#names > 0 and (capitalize(table.concat(names, ', ')) .. (#names > 1 and ' wait there.' or ' waits there.'))
        or 'Nothing hostile that you can see.')
  else
    local hidden = can_see(here_w, pid) and obscured_by(there_w) or obscured_by(here_w)
    event.text = hidden == 'darkness' and ("It's too dark to make out what's " .. dir .. '.')
      or ('The ' .. hidden .. " hides what's " .. dir .. '.')
    if has_perk(pid, 'hunters_nose') then
      local names = {}
      for i, nid in ipairs(enemies) do
        local what = redis.call('HGET', 'NPC:' .. nid, 'name') or nid
        names[i] = (string.find(string.lower(what), '^[aeiou]') and 'an ' or 'a ') .. what
      end
      event.smelled = #names > 0
      if #names > 0 then event.text = event.text .. ' You smell ' .. table.concat(names, ', ') .. ' to the ' .. dir .. '.' end
    end
  end
  emit('PLAYER:' .. pid, event)
end

redis.register_function('look', action(function(pid, rid, args)
  local word = args[2] or ''
  if word == '' then
    if can_see(weather_at(rid), pid) and glimpse(pid, rid) then map_event(pid, {rid}, false) end
    return room_event(pid, rid, 'look')
  end
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', word)
  if dest then return look_toward(pid, rid, word, dest) end
  inspect(pid, rid, word)
end))

redis.register_function('inspect', action(function(pid, rid, args)
  inspect(pid, rid, args[2])
end))

local traps = {}

-- Traps -------------------------------------------------------------------------
-- A room can hold a trap (ROOM:<rid>:trap): walking in springs it unless you
-- pass a check. Every trap has a sign in a neighbouring room for those who
-- look, and Trapsense marks traps next door on the map. PLAYER:<id>:traps
-- remembers the traps a player has found, for their map. A sprung trap is
-- disarmed for everyone until it rearms (ROOM:<rid>:trap_sprung expires).

function traps.know_trap(pid, rid)
  if redis.call('SADD', 'PLAYER:' .. pid .. ':traps', rid) == 1 then
    map_event(pid, {rid}, false)
  end
end

-- Hurts a player outside a fight (a trap, a fall, a travel event). Returns
-- true if it was the end of them.
local function hurt(pid, amount)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  local hp = math.max(player_card(pid).hp - amount, 0)
  redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', hp)
  redis.call('SADD', 'alz:wounded', pid)
  if hp <= 0 then
    defeat(pid, nil)
    return true
  end
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
  if is_waypoint(rid) then emit('PLAYER:' .. pid, {type = 'entity', entity = player_card(pid)}) end
  return false
end

-- Walking in, it's the trap's check. Creeping, a big bonus; creeping in when
-- you know it's there, you always get past, and it's still set behind you.
-- `force` (a botched disarming) springs it with no check.
function traps.spring_trap(pid, rid, careful, force)
  local trap = decode(redis.call('GET', 'ROOM:' .. rid .. ':trap'))
  if not trap.name or redis.call('EXISTS', 'ROOM:' .. rid .. ':trap_sprung') == 1 then return end
  local known = redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':traps', rid) == 1
  if careful and known and not force then
    return notice(pid, 'You creep past ' .. trap.name .. ', testing every step. It is still set behind you.')
  end
  traps.know_trap(pid, rid)
  if not force and passes(pid, trap.stat or 'poise', trap.difficulty, careful and 0.5 or 0) then
    return notice(pid, (trap.avoid or ('You spot ' .. trap.name .. ' just in time, and step around it.')) .. ' (' .. capitalize(trap.stat or 'poise') .. ' check)')
  end
  redis.call('SET', 'ROOM:' .. rid .. ':trap_sprung', '1', 'PX', math.floor((trap.rearm or 120) * 1000))
  emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'trap', text = fill(trap.sprung or '{actor} springs ' .. trap.name .. '!', name_of(pid))})
  local damage = tonumber(trap.damage) or 5
  notice(pid, (trap.hit or ('You spring ' .. trap.name .. '.')) .. ' (' .. damage .. ')')
  if trap.slows then
    redis.call('SET', 'PLAYER:' .. pid .. ':slowed', '1', 'PX', math.floor(trap.slows * 1000))
    notice(pid, 'You limp on, slowed.')
  end
  hurt(pid, damage)
end

-- Trapsense: a prickle at the back of your neck about the room next door.
function traps.sense_traps(pid, rid)
  if not has_perk(pid, 'trapsense') then return end
  for dir, dest in pairs(hgetall('ROOM:' .. rid .. ':exits')) do
    if redis.call('EXISTS', 'ROOM:' .. dest .. ':trap') == 1 and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':traps', dest) == 0 then
      traps.know_trap(pid, dest)
      notice(pid, 'Your trapsense prickles: something is set to the ' .. dir .. '.')
    end
  end
end

-- Exposure (docs/zones.md): some areas wear you down a step at a time: the
-- cold of the high passes, the foul air of the deep mines, the heat of the
-- ash wastes, the spores of a blighted wood, the dread of a cursed ruin. An
-- area's `exposure` names the kind, how many steps you can take (`max`) and
-- what each step past that costs (`damage`); some weather (`worse_when`)
-- doubles a step. Worn gear that `protects` against the kind stops it, and
-- Resilience sometimes shrugs a step off. A shelter (or a safe room) clears
-- it, and so does leaving the area. PLAYER:<id>:exposure holds kind and level.
do

local function in_ranges(w, ranges)
  if not next(ranges or {}) then return false end
  for axis, range in pairs(ranges) do
    if axis == 'time' then
      local phase, ok = clock(w.realm).phase, false
      for _, p in ipairs(range) do if p == phase then ok = true end end
      if not ok then return false end
    elseif w[axis] == nil or w[axis] < range[1] or w[axis] > range[2] then
      return false
    end
  end
  return true
end

-- The exposure where a room is, or nil.
local function exposure_of(info)
  local area = info.area and redis.call('HGET', 'AREA:' .. info.area .. ':info', 'exposure')
  if area and area ~= '' then return decode(area) end
end

-- Whether something the player wears protects them from this kind.
hooks.protected = function(pid, kind)
  for _, place in ipairs({'head', 'chest', 'legs', 'hand'}) do
    local w = hooks.worn(pid, place)
    for _, k in ipairs(w and w.protects or {}) do
      if k == kind then return w end
    end
  end
end

local function exposure_event(pid, e, level, guard)
  local event = {type = 'exposure'}
  if e then
    event.kind, event.name, event.level, event.max = e.kind, e.name or e.kind, level, e.max or 6
    event.protected = guard and guard.name or nil
  end
  emit('PLAYER:' .. pid, event)
end

hooks.expose = function(pid, rid)
  local key = 'PLAYER:' .. pid .. ':exposure'
  local info = hgetall('ROOM:' .. rid .. ':info')
  local e = exposure_of(info)
  local before = hgetall(key)
  if not e or info.shelter == '1' or info.safe == '1' then
    if redis.call('DEL', key) == 1 then
      if e then notice(pid, e.relief or 'You find shelter here, and recover.') end
      exposure_event(pid, e and info.shelter == '1' and e or nil, 0)
    end
    return
  end
  local guard = hooks.protected(pid, e.kind)
  local level = tonumber(before.level) or 0
  if before.kind ~= e.kind then level = 0 end
  if guard then
    level = math.max(0, level - 1) -- protected, you slowly recover
  else
    local step = in_ranges(weather_at(rid), e.worse_when) and 2 or 1
    if roll() < resilience(pid) then step = step - 1 end
    level = level + step
  end
  redis.call('HSET', key, 'kind', e.kind, 'level', level)
  local max = e.max or 6
  exposure_event(pid, e, level, guard)
  if level > max and not guard then
    local damage = e.damage or 10
    notice(pid, (e.hurt or ('The ' .. (e.name or e.kind) .. ' is wearing you down.')) .. ' (' .. damage .. ')')
    hurt(pid, damage)
  elseif level >= max - 1 and level > 0 then
    notice(pid, e.warn or ('The ' .. (e.name or e.kind) .. ' is getting to you. Find shelter.'))
  end
end

end

-- The movement steps from todo.md, in order. (A player in a fight leaves it
-- by FLEE, which comes here after the parting blow.)
local function finish_move(pid, rid, dir, dest, careful)
  local me, from = name_of(pid), ARRIVE_FROM[dir]
  relocate(pid, rid, dest, 'move', dir, me .. (careful and ' creeps ' or ' heads ') .. dir .. '.', me .. (from and (' arrives from ' .. from .. '.') or ' arrives.'))
  redis.call('SET', 'PLAYER:' .. pid .. ':came', rid) -- the way back, for the flee key
  room_event(pid, dest, 'move')
  if weather_changes(rid, dest) then
    weather_event(pid)
    kit_event(pid)
  end
  if redis.call('EXISTS', 'ROOM:' .. dest .. ':trap') == 1 then traps.spring_trap(pid, dest, careful) end
  if redis.call('GET', 'PLAYER:' .. pid .. ':room') ~= dest then return end -- the trap was the end of them
  traps.sense_traps(pid, dest)
  hooks.expose(pid, dest)
  if redis.call('GET', 'PLAYER:' .. pid .. ':room') ~= dest then return end -- the cold (or worse) was the end of them
  aggro(pid, dest, careful)
  hooks.quest(pid, 'enter', {room = dest})
  hooks.maybe_lure(pid, dest)
end

local WADING = {
  snow = {'You take high steps, trying to clear the snow that impedes you.', ' starts wading %s through the snow.'},
  mud = {'Your boots sink into the mud with every step.', ' squelches off %s through the mud.'},
  creep = {'You creep forward, testing every step.', ' starts creeping %s, testing every step.'},
}

-- Each step takes the time to cross the room you step into (step_ms), so a
-- client can't send a whole journey at once. Deep snow or mud holds a move up: the
-- player is told why at once, and `tick` finishes the move when it's due
-- (PLAYER:<id>:pending holds it, alz:pending_moves schedules it).
redis.register_function('move', action(function(pid, rid, args)
  local dir = args[2]
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
  if not dest then return notice(pid, "You can't go that way.") end
  if enc.of_player(pid) then return notice(pid, TEXT.in_a_fight) end
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':pending') == 1 then return notice(pid, "You're still making your way.") end
  -- In the dark you can only feel your way back along ways you know.
  local here = weather_at(rid)
  if not can_see(here, pid) and obscured_by(here) == 'darkness' and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 0 then
    return notice(pid, "It's too dark to find a way " .. dir .. '. You need a light in your hand: EQUIP TORCH.')
  end
  local careful = args[3] == 'careful'
  local cooldown = step_ms(pid, dest)
  if cooldown > 0 and not redis.call('SET', 'PLAYER:' .. pid .. ':moved', '1', 'NX', 'PX', cooldown) then
    return notice(pid, 'You need a moment to find your footing.')
  end
  local delay, cause = travel_delay(pid, rid, dest)
  -- Creeping, each step takes three times as long (as well as any snow or mud).
  if careful and step_ms(pid, dest) > 0 then delay, cause = (delay or 0) + 3 * step_ms(pid, dest), 'creep' end
  if delay == 0 then return finish_move(pid, rid, dir, dest, careful) end
  redis.call('HSET', 'PLAYER:' .. pid .. ':pending', 'dir', dir, 'from', rid, 'careful', careful and '1' or '')
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
  enc.drop_player(pid, 'left')
  redis.call('DEL', 'PLAYER:' .. pid .. ':pending')
  redis.call('ZREM', 'alz:pending_moves', pid)
  local me = name_of(pid)
  if hooks.check_priority and not is_waypoint(dest) then hooks.check_priority(pid, dest) end
  relocate(pid, rid, dest, 'teleport', nil, fill(leave, me), fill(arrive, me))
  room_event(pid, dest, 'move')
  full_map_event(pid)
  weather_event(pid)
  kit_event(pid)
  if hooks.expose and not is_waypoint(dest) then hooks.expose(pid, dest) end
  if redis.call('GET', 'PLAYER:' .. pid .. ':room') ~= dest then return end
  aggro(pid, dest)
  if hooks.quest and not is_waypoint(dest) then hooks.quest(pid, 'enter', {room = dest}) end
end

-- Routes ----------------------------------------------------------------------
-- A route is every jump from one room to another: a ferry, a coach, a portal
-- mage, a rift (ROUTE:<id>; ROOM:<rid>:routes lists those leaving a room). It
-- can need its operator (`by`, an NPC here and friendly to you), a fare in
-- coins, weather (`when`) and a clear room (`clear`). A route with a `path`
-- is a journey through its waypoint rooms, one every stage_seconds, playing
-- itself; one without is instant. PLAYER:<id>:journey holds the route and the
-- stage (the waypoint you're at), and alz:journeys schedules the next stage
-- for `tick`. A journey only moves on while the player is online: log out on
-- the road and you're still aboard when you come back. Travel events
-- (below) can pause it for a choice, delay it, or end it early.

local function coins_of(pid)
  return tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'coins')) or 0
end

-- A route's fare for this player (a Haggler pays 15% less).
local function fare_for(pid, route)
  local fare = tonumber(route.fare) or 0
  if fare > 0 and has_perk(pid, 'haggler') then fare = math.max(1, math.floor(fare * 0.85)) end
  return fare
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
  local fare, coins = fare_for(pid, route), coins_of(pid)
  if coins < fare then return 'It costs ' .. fare .. ' coins, and you have ' .. coins .. '.' end
end

local function stage_ms()
  return math.floor(rule('stage_seconds', 4) * 1000)
end

-- A journey whose route is gone (a new seed removed or renamed it) ends in
-- the start room: a waypoint has no exits, so a rider left there is stuck.
-- Set below, once end_journey exists.
local lose_journey

-- Shows the waypoint a player's journey has reached, and maybe starts a
-- travel event there.
local function journey_stage(pid)
  local key = 'PLAYER:' .. pid .. ':journey'
  local journey = hgetall(key)
  local route = hgetall('ROUTE:' .. (journey.route or ''))
  local path, n = decode(route.path), tonumber(journey.stage) or 1
  local here = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not route.to or path[n] ~= here then
    if is_waypoint(here) then return lose_journey(pid) end
    return redis.call('DEL', key)
  end
  local info = hgetall('ROOM:' .. here .. ':info')
  emit('PLAYER:' .. pid, {type = 'journey', route = journey.route, kind = route.kind, stage = n, stages = #path,
    at = here, pos = room_pos(info), name = info.name, text = info.description})
  hooks.maybe_event(pid, route, journey, n)
end

-- Moves a rider from one waypoint (or the room they set off from) to another.
local function ride_to(pid, dest, leave)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  local changes = weather_changes(rid, dest)
  relocate(pid, rid, dest, 'travel', nil, fill(leave or '{actor} is gone.', name_of(pid)), nil)
  room_event(pid, dest, 'travel')
  if changes then
    weather_event(pid)
    kit_event(pid)
  end
end

-- Ends a journey at its destination, or (stranded) somewhere else.
local function end_journey(pid, dest, arrive)
  redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
  redis.call('ZREM', 'alz:journeys', pid)
  emit('PLAYER:' .. pid, {type = 'journey', done = true})
  teleport(pid, dest, '{actor} is gone.', arrive)
end

lose_journey = function(pid)
  notice(pid, 'The way you were travelling is gone from the world. You find yourself somewhere you know.')
  end_journey(pid, redis.call('GET', 'alz:start_room'), '{actor} arrives, looking lost.')
end

-- Schedules the next stage after stage_seconds (or `ms`).
local function journey_next(pid, ms)
  redis.call('ZADD', 'alz:journeys', now_ms() + (ms or stage_ms()), pid)
end

-- Moves a journey on to its next waypoint, or to its end.
local function journey_advance(pid)
  local key = 'PLAYER:' .. pid .. ':journey'
  local journey = hgetall(key)
  local route = hgetall('ROUTE:' .. (journey.route or ''))
  if not route.to then return lose_journey(pid) end
  local path = decode(route.path)
  -- Delays hold the journey at a waypoint for a stage or more.
  if (tonumber(journey.delay) or 0) > 0 then
    redis.call('HINCRBY', key, 'delay', -1)
    notice(pid, 'The delay drags on.')
    return journey_next(pid)
  end
  local n = (tonumber(journey.stage) or 1) + 1 + (tonumber(journey.skip) or 0)
  redis.call('HDEL', key, 'skip')
  if n > #path then return end_journey(pid, route.to, route.arrive) end
  redis.call('HSET', key, 'stage', n)
  ride_to(pid, path[n])
  journey_stage(pid)
  if redis.call('EXISTS', key) == 1 and not redis.call('HGET', key, 'event') then journey_next(pid) end
end

-- Both ways onto a route (TRAVEL, and DISCUSS PASSAGE with its operator) come
-- through here, so both follow the same rules.
local function take_route(pid, rid, id)
  if enc.of_player(pid) then return notice(pid, TEXT.in_a_fight) end
  local route = hgetall('ROUTE:' .. id)
  local refusal = route_refusal(pid, rid, route)
  if refusal then return notice(pid, refusal) end
  local fare = fare_for(pid, route)
  if fare > 0 then redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', -fare) end
  if route.depart ~= '' then notice(pid, route.depart) end
  -- The way out of a starting realm: it's gone from the player's map for good.
  if route.leaves_start == '1' then redis.call('SREM', 'PLAYER:' .. pid .. ':realms', realm_of(route.from) or '') end
  hooks.quest(pid, 'travel', {route = id})
  return hooks.begin(pid, id)
end

-- Sets a player off on a route they've paid for (or been given).
hooks.begin = function(pid, id)
  local route = hgetall('ROUTE:' .. id)
  local path = decode(route.path)
  if #path == 0 then return teleport(pid, route.to, route.leave, route.arrive) end
  enc.drop_player(pid, 'left')
  redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
  redis.call('HSET', 'PLAYER:' .. pid .. ':journey', 'route', id, 'stage', 1)
  ride_to(pid, path[1], route.leave)
  journey_stage(pid)
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':journey') == 1 and not redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'event') then
    journey_next(pid)
  end
end

-- The end of a starting realm: the journey out, for free, and the realm is
-- gone from the player's map for good.
hooks.leave_start = function(pid, id)
  local route = hgetall('ROUTE:' .. id)
  redis.call('SREM', 'PLAYER:' .. pid .. ':realms', realm_of(route.from) or '')
  if (route.depart or '') ~= '' then notice(pid, route.depart) end
  hooks.begin(pid, id)
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

-- Moves due journeys on, or resolves events left waiting too long. Called by
-- `tick`. Journeys of players who've gone offline wait for them to come back.
local function journeys_due(now)
  for _, pid in ipairs(redis.call('ZRANGEBYSCORE', 'alz:journeys', '-inf', now)) do
    redis.call('ZREM', 'alz:journeys', pid)
    local key = 'PLAYER:' .. pid .. ':journey'
    if redis.call('EXISTS', key) == 1 and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
      if redis.call('HGET', key, 'marooned') then
        -- Held at its waypoint until the quest ashore is done.
      elseif redis.call('HGET', key, 'event') then
        hooks.event_due(pid, now)
      elseif redis.call('HGET', key, 'ambush') then
        hooks.ambush_due(pid)
      else
        journey_advance(pid)
      end
    end
  end
end

do -- travel events and quests, in a block of their own (Lua allows 200 top-level locals)

-- Travel events ------------------------------------------------------------------
-- Rare things that happen on a journey (docs/journeys.md). At each waypoint
-- there's an event_chance (plus the route's `risk`) of one, at most one a
-- journey. Bad weather doesn't make them likelier; it decides which can
-- happen, and the severe ones are worse. An event is a situation and two to
-- four choices, which can test a stat, cost coins, belong to a background, or
-- answer a question; each has outcomes (a list of effects) for success and
-- failure. The journey waits for a choice, or takes the last one after
-- event_seconds. alz:travel_events holds the events; PLAYER:<id>:events the
-- ones that only happen once and have.

-- How rough the going is, 0..1: wind, what's coming down, snow on the ground.
local function severity(w)
  if w.indoor then return 0 end
  local ground = w.realm and ground_of(w.realm) or {}
  return math.max(0, w.energy, intensity(w), tonumber(ground.snow) or 0)
end

local function background_of(pid)
  return redis.call('HGET', 'ACCOUNT:' .. pid, 'background') or ''
end

-- Whether an event can happen to this player here, now.
local function event_fits(pid, event, route, w, phase)
  if event.once and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':events', event.id) == 1 then return false end
  local pools, fits = event.pools or {'any'}, false
  for _, pool in ipairs(pools) do
    if pool == 'any' or pool == route.id or pool == route.kind or pool == w.realm then fits = true end
  end
  if not fits then return false end
  for axis, range in pairs(event.when or {}) do
    if axis == 'time' then
      local ok = false
      for _, p in ipairs(range) do if p == phase then ok = true end end
      if not ok then return false end
    else
      local v = axis == 'severity' and severity(w) or w[axis]
      if v == nil or v < range[1] or v > range[2] then return false end
    end
  end
  return true
end

-- The choices this player sees: background choices only for that background.
local function visible_choices(pid, event)
  local out, bg = {}, background_of(pid)
  for i, choice in ipairs(event.choices or {}) do
    if not choice.background or choice.background == bg then
      out[#out + 1] = {n = #out + 1, index = i, choice = choice}
    end
  end
  return out
end

local function current_event(pid)
  local id = redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'event')
  return id and decode(redis.call('HGET', 'alz:travel_events', id)) or nil, id
end

hooks.show_event = function(pid)
  local event, id = current_event(pid)
  if not event then return end
  local choices = list()
  for _, c in ipairs(visible_choices(pid, event)) do
    local choice = c.choice
    local tags = list()
    if choice.background then tags[#tags + 1] = capitalize(choice.background:gsub('_', ' ')) end
    if choice.check then tags[#tags + 1] = capitalize(choice.check.stat) .. ' check' end
    if choice.cost then tags[#tags + 1] = choice.cost .. ' coins' end
    choices[#choices + 1] = {n = c.n, label = choice.label, check = choice.check and choice.check.stat or nil,
      background = choice.background or (choice.bonus == background_of(pid) and choice.bonus) or nil,
      cost = choice.cost, tags = tags}
  end
  local lines = {event.text}
  for _, c in ipairs(choices) do
    lines[#lines + 1] = '  CHOOSE ' .. c.n .. ': ' .. c.label .. (#c.tags > 0 and (' (' .. table.concat(c.tags, ', ') .. ')') or '')
  end
  emit('PLAYER:' .. pid, {type = 'travel_event', id = id, choices = choices,
    until_ms = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'event_until')), text = table.concat(lines, '\n')})
end

hooks.maybe_event = function(pid, route, journey, n)
  if journey.evented == '1' then return end
  if roll() >= rule('event_chance', 0.05) + (tonumber(route.risk) or 0) then return end
  local here = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  local w, phase = weather_at(here), clock(realm_of(here)).phase
  route.id = journey.route
  local fitting, total, only = {}, 0, {}
  for _, id in ipairs(decode(route.events)) do only[id] = true end
  for _, id in ipairs(sorted(redis.call('HKEYS', 'alz:travel_events'))) do
    local event = decode(redis.call('HGET', 'alz:travel_events', id))
    event.id = id
    if (next(only) == nil or only[id]) and event_fits(pid, event, route, w, phase) then
      fitting[#fitting + 1] = event
      total = total + (event.weight or 1)
    end
  end
  if total == 0 then return end
  local pick, event = roll() * total, nil
  for _, e in ipairs(fitting) do
    pick = pick - (e.weight or 1)
    if pick < 0 then event = e break end
  end
  event = event or fitting[#fitting]
  local key = 'PLAYER:' .. pid .. ':journey'
  redis.call('HSET', key, 'event', event.id, 'evented', '1', 'event_until', now_ms() + rule('event_seconds', 60) * 1000)
  if event.once then redis.call('SADD', 'PLAYER:' .. pid .. ':events', event.id) end
  redis.call('ZADD', 'alz:journeys', tonumber(redis.call('HGET', key, 'event_until')), pid)
  hooks.show_event(pid)
end

-- Ambushes: attackers appear at the waypoint, the rider's alone. They're
-- copies of template NPCs owned by the rider (NPC:<template>~<pid>~<n>),
-- which nobody else sees and which never come back.
local function spawn_ambushers(pid, rid, templates)
  local key = 'PLAYER:' .. pid .. ':journey'
  redis.call('HSET', key, 'ambush', '1')
  redis.call('SADD', 'ROOM:' .. rid .. ':players', pid)
  resubscribe(pid, {'ROOM:' .. rid}, {})
  for i, template in ipairs(templates) do
    local nid = template .. '~' .. pid .. '~' .. i
    local npc = hgetall('NPC:' .. template)
    redis.call('DEL', 'NPC:' .. nid, 'NPC:' .. nid .. ':encounter')
    for field, value in pairs(npc) do redis.call('HSET', 'NPC:' .. nid, field, value) end
    redis.call('HSET', 'NPC:' .. nid, 'room', rid, 'hp', npc.max_hp or 10, 'owner', pid, 'respawn', 0)
    redis.call('SADD', 'ROOM:' .. rid .. ':npcs', nid)
    redis.call('SADD', 'PLAYER:' .. pid .. ':ambushers', nid)
  end
  room_event(pid, rid, 'ambush')
  aggro(pid, rid)
  redis.call('ZADD', 'alz:journeys', now_ms() + 1000, pid)
end

-- Clears a rider's ambushers away and takes them off the waypoint's floor.
local function clear_ambush(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  for _, nid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':ambushers')) do
    enc.drop_npc(nid, 'gone')
    redis.call('SREM', 'ROOM:' .. rid .. ':npcs', nid)
    redis.call('ZREM', 'alz:respawns', nid)
    redis.call('DEL', 'NPC:' .. nid, 'NPC:' .. nid .. ':bleed')
  end
  enc.drop_player(pid, 'left')
  redis.call('DEL', 'PLAYER:' .. pid .. ':ambushers')
  redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
  resubscribe(pid, {}, {'ROOM:' .. rid})
  redis.call('HDEL', 'PLAYER:' .. pid .. ':journey', 'ambush')
end

-- Thrown off the route: you wake in the wilds, battered, the fare gone.
local function strand(pid, text)
  local journey = hgetall('PLAYER:' .. pid .. ':journey')
  local route = hgetall('ROUTE:' .. (journey.route or ''))
  if journey.ambush then clear_ambush(pid) end
  -- Roughed up: a third of your health (less if you had less, unless you were beaten senseless).
  local card, third = player_card(pid), math.max(1, math.floor(player_card(pid).max_hp / 3))
  redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', card.hp > 0 and math.min(card.hp, third) or third)
  redis.call('SADD', 'alz:wounded', pid)
  notice(pid, text or "You're left behind in the wilds, battered and alone. The ride is gone, and your fare with it.")
  end_journey(pid, (route.strand or '') ~= '' and route.strand or route.from, '{actor} staggers in, battered and filthy.')
end
hooks.strand = strand

hooks.ambush_due = function(pid)
  for _, nid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':ambushers')) do
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', nid) == 1 then
      return redis.call('ZADD', 'alz:journeys', now_ms() + 1000, pid)
    end
  end
  clear_ambush(pid)
  notice(pid, 'The last of them is down. You climb back aboard, and the journey goes on.')
  room_event(pid, redis.call('GET', 'PLAYER:' .. pid .. ':room'), 'travel')
  journey_next(pid)
end

-- Applies an outcome: a list of effects, each {name = value}.
local function apply_effects(pid, effects)
  local key = 'PLAYER:' .. pid .. ':journey'
  local rep_changed, map_changed = false, false
  for _, effect in ipairs(effects or {}) do
    if effect.text then notice(pid, effect.text) end
    if effect.delay then
      redis.call('HINCRBY', key, 'delay', effect.delay)
      notice(pid, 'It costs you time.')
    end
    if effect.hasten then redis.call('HINCRBY', key, 'skip', effect.hasten) end
    if effect.coins then
      local coins = math.max(0, coins_of(pid) + effect.coins)
      redis.call('HSET', 'ACCOUNT:' .. pid, 'coins', coins)
      notice(pid, effect.coins > 0 and ('You gain ' .. effect.coins .. ' coins.') or ('You lose ' .. -effect.coins .. ' coins.'))
      kit_event(pid)
    end
    if effect.xp then gain_xp(pid, effect.xp) end
    if effect.reputation then
      local r = effect.reputation
      if shift_rep(pid, r.faction, r.affinity or 0, r.respect or 0, {r.note}) then rep_changed = true end
    end
    if effect.discover then
      local names = discover_regions(pid, {effect.discover})
      if #names > 0 then
        notice(pid, 'You hear of ' .. names[1] .. '. It is marked on your map.')
        map_changed = true
      end
    end
    if effect.rumour then
      if redis.call('SADD', 'PLAYER:' .. pid .. ':rumours', effect.rumour) == 1 then
        notice(pid, 'You hear talk of ' .. (redis.call('HGET', 'REALM:' .. effect.rumour .. ':info', 'name') or effect.rumour) .. ', another world entirely.')
        map_changed = true
      end
    end
    if effect.boon then
      local b = effect.boon
      redis.call('SET', 'PLAYER:' .. pid .. ':buff:' .. b.stat, b.amount or 1, 'PX', math.floor((b.minutes or 20) * 60000))
      notice(pid, (b.name or 'Heartened') .. ': ' .. signed(b.amount or 1) .. ' ' .. capitalize(b.stat) .. ' for ' .. (b.minutes or 20) .. ' minutes.')
      character_event(pid)
    end
    if effect.hp then
      if effect.hp > 0 then
        local card = player_card(pid)
        redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', math.min(card.max_hp, card.hp + effect.hp))
        emit('PLAYER:' .. pid, {type = 'entity', entity = player_card(pid)})
      elseif hurt(pid, -effect.hp) then
        return 'over'
      end
    end
    if effect.death then
      -- Drowned, or worse: a real death, home to the shrine.
      notice(pid, effect.death)
      redis.call('DEL', key)
      redis.call('ZREM', 'alz:journeys', pid)
      redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', 0)
      defeat(pid, nil)
      return 'over'
    end
    if effect.strand then
      strand(pid, type(effect.strand) == 'string' and effect.strand or nil)
      return 'over'
    end
    if effect.ambush then
      spawn_ambushers(pid, redis.call('GET', 'PLAYER:' .. pid .. ':room'), effect.ambush)
      return 'ambush'
    end
    if effect.maroon then
      hooks.maroon(pid, effect.maroon)
      return 'over'
    end
  end
  if rep_changed then after_rep(pid) end
  if map_changed then full_map_event(pid) end
end

-- Resolves the player's choice (n among the choices they see), or the last
-- one if `n` is nil (they let the moment pass).
local function resolve_event(pid, n)
  local event, id = current_event(pid)
  if not event then return notice(pid, "There's nothing to choose right now.") end
  local choices = visible_choices(pid, event)
  local picked = n and choices[n] or (not n and choices[#choices]) or nil
  if not picked then return notice(pid, 'Choose one of 1 to ' .. #choices .. '.') end
  local choice = picked.choice
  if choice.cost and coins_of(pid) < choice.cost then
    return notice(pid, 'It costs ' .. choice.cost .. ' coins, and you have ' .. coins_of(pid) .. '.')
  end
  redis.call('HDEL', 'PLAYER:' .. pid .. ':journey', 'event', 'event_until')
  emit('PLAYER:' .. pid, {type = 'travel_event', id = id, done = true, text = '> ' .. choice.label})
  if choice.cost then
    redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', -choice.cost)
    kit_event(pid)
  end
  local ok = true
  if choice.check then
    local bonus = (choice.bonus and choice.bonus == background_of(pid)) and 0.35 or 0
    ok = passes(pid, choice.check.stat, choice.check.difficulty, bonus)
  end
  local outcome = ok and choice.success or (choice.failure or choice.success)
  if apply_effects(pid, outcome) then return end
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':journey') == 1 then journey_next(pid) end
end

hooks.event_due = function(pid, now)
  local until_ms = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'event_until')) or 0
  if now < until_ms then return redis.call('ZADD', 'alz:journeys', until_ms, pid) end
  notice(pid, 'The moment passes.')
  resolve_event(pid, nil)
end

redis.register_function('choose', action(function(pid, rid, args)
  resolve_event(pid, tonumber(args[2]))
end))

redis.register_function('flee', action(function(pid, rid, args)
  if redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'ambush') then
    return strand(pid, 'You run, and keep running, and the road is lost behind you. You come to your senses somewhere in the wilds, bruised and alone.')
  end
  if enc.of_player(pid) then return notice(pid, TEXT.in_a_fight) end
  notice(pid, 'There is nothing here to flee from.')
end))

-- Quests ---------------------------------------------------------------------------
-- Small state machines (docs/quests.md). A quest has steps; each step has a
-- `goal` (what the quest panel shows), `on` (what moves it on), `effects`
-- when it's done, and `then` (the next step, or none to finish). Triggers:
-- ask (an NPC about a topic), get (an item), enter (a room), kill (an NPC, or
-- one of a faction or role, counted while the step is active), use (an item
-- on a feature or NPC), have (all of some items), level; any of them can add
-- `when` (weather ranges and time phases where the player is). A `priority`
-- quest (being marooned) belongs to its `area`: leaving it any other way
-- than finishing, or dying, fails it. PLAYER:<id>:quests maps quests onto
-- active / done / failed; PLAYER:<id>:quest:<qid> holds the step and count.

local function quest_def(qid)
  return decode(redis.call('HGET', 'alz:quests', qid))
end

local function quest_status(pid, qid)
  return redis.call('HGET', 'PLAYER:' .. pid .. ':quests', qid)
end

-- The id of the step a player is on. If the seed has since dropped that step,
-- they go back to the quest's start rather than being stuck.
local function step_of(pid, qid, def)
  local key = 'PLAYER:' .. pid .. ':quest:' .. qid
  local step = redis.call('HGET', key, 'step')
  if step and not (def.steps or {})[step] and def.start and quest_status(pid, qid) == 'active' then
    step = def.start
    redis.call('HSET', key, 'step', step, 'count', 0)
  end
  return step
end

-- The quest panel: active quests (priority first) with their goals, then the rest.
local function quests_event(pid)
  local out = list()
  for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
    local def = quest_def(qid)
    local step = step_of(pid, qid, def)
    local s = (def.steps or {})[step or ''] or {}
    local on = s.on or {}
    local state = hgetall('PLAYER:' .. pid .. ':quest:' .. qid)
    out[#out + 1] = {id = qid, name = def.name or qid, status = status, priority = def.priority or false,
      goal = status == 'active' and s.goal or nil, count = tonumber(state.count) or 0,
      need = on.count, since = tonumber(state.since) or 0}
  end
  table.sort(out, function(a, b)
    if (a.status == 'active') ~= (b.status == 'active') then return a.status == 'active' end
    if a.priority ~= b.priority then return a.priority end
    if a.since ~= b.since then return a.since > b.since end -- the latest first: the one you're on
    return a.name < b.name
  end)
  emit('PLAYER:' .. pid, {type = 'quests', quests = out})
end

local function has_items(pid, items)
  for _, iid in ipairs(items or {}) do
    if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':inv', iid) == 0 then return false end
  end
  return true
end

-- Whether weather and time where the player is suit a trigger's `when`.
local function quest_when(pid, when)
  if not when then return true end
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  local w = weather_at(rid)
  for axis, range in pairs(when) do
    if axis == 'time' then
      local phase, ok = clock(realm_of(rid)).phase, false
      for _, p in ipairs(range) do if p == phase then ok = true end end
      if not ok then return false end
    elseif w[axis] == nil or w[axis] < range[1] or w[axis] > range[2] then
      return false
    end
  end
  return true
end

-- Whether something that just happened (kind, data) moves a step on.
local function trigger_matches(pid, on, kind, data)
  -- States: checked whenever anything happens that might have changed them.
  if on.have then return has_items(pid, on.have) and quest_when(pid, on.when) end
  if on.level then return level_of(pid) >= on.level end
  if on['in'] then return redis.call('GET', 'PLAYER:' .. pid .. ':room') == on['in'] and quest_when(pid, on.when) end
  if kind == 'enter' and on.enter then return on.enter == data.room and quest_when(pid, on.when) end
  if kind == 'ask' and on.ask then return on.ask == data.npc and (not on.about or on.about == data.topic) and quest_when(pid, on.when) end
  if kind == 'get' and on.get then return on.get == data.item and quest_when(pid, on.when) end
  if kind == 'travel' and on.travel then return on.travel == data.route end
  if kind == 'give' and on.give then return on.give == data.item and (not on.to or on.to == data.npc) and quest_when(pid, on.when) end
  if kind == 'use' and on.use then return on.use == data.item and (not on.on or on.on == data.target) and quest_when(pid, on.when) end
  if kind == 'kill' and on.kill then
    local base = string.match(data.npc, '^([^~]+)') or data.npc
    return (on.kill == data.npc or on.kill == base or on.kill == data.faction or on.kill == data.role) and quest_when(pid, on.when)
  end
  return false
end

local quest_effects -- below: effects can start quests, which can finish at once

local function finish_quest(pid, qid, status)
  local giver = redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. qid, 'giver')
  if giver and status == 'done' then hooks.add_rapport(pid, giver, 2) end
  redis.call('HSET', 'PLAYER:' .. pid .. ':quests', qid, status)
  redis.call('DEL', 'PLAYER:' .. pid .. ':quest:' .. qid)
  local def = quest_def(qid)
  if status == 'done' then
    notice(pid, 'Quest complete: ' .. (def.name or qid) .. '.')
  else
    notice(pid, 'Quest failed: ' .. (def.name or qid) .. '.')
  end
end

-- Checks every active quest against something that happened.
local function quest_progress(pid, kind, data)
  local moved = false
  for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
    if status == 'active' then
      local key = 'PLAYER:' .. pid .. ':quest:' .. qid
      local def = quest_def(qid)
      local step = (def.steps or {})[step_of(pid, qid, def) or '']
      if step and trigger_matches(pid, step.on or {}, kind, data) then
        local count = redis.call('HINCRBY', key, 'count', 1)
        moved = true
        if count >= ((step.on or {}).count or 1) then
          if step['then'] then
            redis.call('HSET', key, 'step', step['then'], 'count', 0, 'since', now_ms())
            local next_step = def.steps[step['then']] or {}
            if next_step.goal then emit('PLAYER:' .. pid, {type = 'quest_update', quest = qid, text = (def.name or qid) .. ': ' .. next_step.goal}) end
          else
            finish_quest(pid, qid, 'done')
          end
          if quest_effects(pid, step.effects) == 'over' then break end
        elseif step.on.count then
          emit('PLAYER:' .. pid, {type = 'quest_update', quest = qid, text = (def.name or qid) .. ': ' .. count .. ' / ' .. step.on.count})
        end
      end
    end
  end
  if moved then
    quests_event(pid)
    -- A step finished can make the next one already true (you hold the items).
    if kind ~= 'check' then quest_progress(pid, 'check', {}) end
  end
end
hooks.quest = quest_progress

local function start_quest(pid, qid)
  if quest_status(pid, qid) == 'active' or quest_status(pid, qid) == 'done' then return false end
  local def = quest_def(qid)
  if not def.steps then return false end
  redis.call('HSET', 'PLAYER:' .. pid .. ':quests', qid, 'active')
  redis.call('DEL', 'PLAYER:' .. pid .. ':quest:' .. qid)
  redis.call('HSET', 'PLAYER:' .. pid .. ':quest:' .. qid, 'step', def.start, 'count', 0, 'since', now_ms())
  emit('PLAYER:' .. pid, {type = 'quest_update', quest = qid, new = true,
    text = 'New quest: ' .. (def.name or qid) .. '. ' .. ((def.steps[def.start] or {}).goal or '')})
  quests_event(pid)
  quest_progress(pid, 'check', {})
  return true
end

-- The priority quest a player is in the middle of, if any.
local function priority_quest(pid)
  for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
    if status == 'active' and quest_def(qid).priority then return qid end
  end
end

-- Leaving a priority quest's area (except by finishing it) fails it, and
-- with it any journey it was holding.
local function check_priority(pid, dest, dying)
  local qid = priority_quest(pid)
  if not qid then return end
  local area = redis.call('HGET', 'ROOM:' .. dest .. ':info', 'area')
  if dying or area ~= quest_def(qid).area then
    finish_quest(pid, qid, 'failed')
    if redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'marooned') then
      redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
      redis.call('ZREM', 'alz:journeys', pid)
    end
    quests_event(pid)
  end
end
hooks.check_priority = check_priority

-- Marooned: the journey waits at its waypoint while the player is stuck in a
-- pocket area with a priority quest.
hooks.maroon = function(pid, spec)
  redis.call('HSET', 'PLAYER:' .. pid .. ':journey', 'marooned', '1')
  redis.call('ZREM', 'alz:journeys', pid)
  teleport(pid, spec.room, '{actor} is gone.', '{actor} staggers ashore, soaked.')
  redis.call('HDEL', 'PLAYER:' .. pid .. ':quests', spec.quest)
  start_quest(pid, spec.quest)
end

do
  -- An NPC speaks to a player: out loud if they're in the room together,
  -- otherwise only the player hears it.
  hooks.npc_says = function(pid, nid, text)
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room') or ''
    local event = {type = 'say', entity_id = 'npc:' .. nid, target = 'pc:' .. pid,
      text = capitalize(npc_display(nid)) .. ' says, "' .. text .. '"'}
    emit(redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', nid) == 1 and ('ROOM:' .. rid) or ('PLAYER:' .. pid), event)
  end

  -- A quest that follows on from another is offered by its giver, out loud, a
  -- beat after the last one is handed in (alz:quest_offers, due times), and
  -- waits for the player to ACCEPT it (hooks.pend). One with no giver starts
  -- at once.
  hooks.offer = function(pid, qid)
    local def = quest_def(qid)
    if not (def.giver and def.offer) then return start_quest(pid, qid) end
    local beat = rule('offer_beat_ms', 2500)
    if beat <= 0 then
      hooks.npc_says(pid, def.giver, def.offer)
      return hooks.pend(pid, qid, def.giver)
    end
    redis.call('ZADD', 'alz:quest_offers', now_ms() + beat, pid .. '|' .. qid)
  end

  -- Called by `tick`.
  hooks.offers_due = function(now)
    for _, member in ipairs(redis.call('ZRANGEBYSCORE', 'alz:quest_offers', '-inf', now, 'LIMIT', 0, 50)) do
      redis.call('ZREM', 'alz:quest_offers', member)
      local pid, qid = string.match(member, '^(.+)|([^|]+)$')
      local def = quest_def(qid)
      if redis.call('HGET', 'ACCOUNT:' .. pid, 'created') == '1' and def.offer then
        hooks.npc_says(pid, def.giver, def.offer)
        hooks.pend(pid, qid, def.giver)
      end
    end
  end
end

quest_effects = function(pid, effects)
  for _, effect in ipairs(effects or {}) do
    if effect.give and redis.call('HEXISTS', 'alz:wearables', effect.give) == 1 then
      hooks.give_wearable(pid, effect.give)
      character_event(pid)
    elseif effect.give and redis.call('SISMEMBER', 'alz:gear', effect.give) == 1 then
      if grant_gear(pid, effect.give) then
        local name = gear_info(effect.give).name
        notice(pid, 'You receive ' .. name .. ' (slot gear: EQUIP ' .. string.upper(name) .. ' <slot>, or the Inventory).')
      end
      kit_event(pid)
    elseif effect.give then
      redis.call('SADD', 'PLAYER:' .. pid .. ':inv', effect.give)
      notice(pid, 'You receive the ' .. (redis.call('HGET', 'ITEM:' .. effect.give, 'name') or effect.give) .. '.')
      kit_event(pid)
    elseif effect.take then
      redis.call('SREM', 'PLAYER:' .. pid .. ':inv', effect.take)
      kit_event(pid)
    elseif effect.start then
      hooks.offer(pid, effect.start)
    elseif effect.say then
      hooks.npc_says(pid, effect.by, effect.say)
    elseif effect.guide then
      emit('PLAYER:' .. pid, {type = 'guide', text = effect.guide})
    elseif effect.teleport then
      teleport(pid, effect.teleport, '{actor} is gone.', '{actor} arrives.')
    elseif effect.resume_journey then
      -- Back to the waypoint the journey was held at, and on.
      local key = 'PLAYER:' .. pid .. ':journey'
      local journey = hgetall(key)
      local path = decode(redis.call('HGET', 'ROUTE:' .. (journey.route or ''), 'path'))
      local at = path[tonumber(journey.stage) or 1]
      if at then
        redis.call('HDEL', key, 'marooned')
        teleport(pid, at, '{actor} sets off.', '{actor} climbs aboard.')
        journey_next(pid)
      end
    elseif effect.leave_start then
      hooks.leave_start(pid, effect.leave_start)
      return 'over'
    else
      local result = apply_effects(pid, {effect})
      if result then return result end
    end
  end
end

-- Uses a carried item on something here (args: item word, target word).
redis.register_function('use_item', action(function(pid, rid, args)
  local iid, item = match_item('PLAYER:' .. pid .. ':inv', args[2])
  if not iid then return notice(pid, "You aren't carrying that.") end
  local target = args[3] or ''
  local kind, id, display = nil, nil, nil
  if target ~= '' then
    kind, id, display = resolve(pid, rid, target)
    if not kind then return notice(pid, "You don't see that here.") end
  end
  -- Using something on someone is giving it to them.
  if kind == 'npc' then return hooks.give_to(pid, rid, iid, id, display) end
  local touched = false
  for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
    if status == 'active' then
      local def = quest_def(qid)
      local step = (def.steps or {})[step_of(pid, qid, def) or '']
      if step and trigger_matches(pid, step.on or {}, 'use', {item = iid, target = id}) then touched = true end
    end
  end
  if not touched then
    return notice(pid, 'You try the ' .. item.name .. (display and (' on ' .. display) or '') .. '. Nothing happens.')
  end
  emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'use', target = id,
    text = name_of(pid) .. ' uses the ' .. item.name .. (display and (' on ' .. display) or '') .. '.'})
  quest_progress(pid, 'use', {item = iid, target = id})
end))

redis.register_function('quests', action(function(pid, rid, args)
  quests_event(pid)
  local lines = {}
  for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
    local def = quest_def(qid)
    local step = step_of(pid, qid, def)
    lines[#lines + 1] = (def.name or qid) .. ' (' .. status .. ')' .. (status == 'active' and step and def.steps[step] and (': ' .. def.steps[step].goal) or '')
  end
  table.sort(lines)
  notice(pid, #lines > 0 and ('Quests:\n  ' .. table.concat(lines, '\n  ')) or 'You have no quests yet. Talk to people: GREET them, or DISCUSS QUESTS. Stuck? WHAT NOW.')
end))

hooks.start_quest = start_quest
hooks.quest_def, hooks.quest_status, hooks.trigger_matches = quest_def, quest_status, trigger_matches
hooks.quests_event = quests_event
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
      if enc.of_player(pid) then
        notice(pid, 'The fight holds you here. ' .. TEXT.in_a_fight)
      else
        finish_move(pid, rid, pending.dir, dest, pending.careful == '1')
      end
    end
  end
end

-- What strikes and blows do -------------------------------------------------------
-- The owner of an encounter judges each strike (its tier: edge, clean or
-- perfect) and each blow (hit, dodged, blocked, landing on a staggered player,
-- or a parting blow); these work out what happens. They're also how slots work
-- out of a fight, for heals and guards.

local TIER_NAMES = {[0] = 'edge', [1] = 'clean', [2] = 'perfect'}

-- Passives that change what a strike lands (docs/combat.md,
-- Passives): charges stacked by Moonlit Edge and Bloodrhythm on their attuned
-- slot, Berserk Seal, Last Stand, Iron Gut.
local function empower(pid, rid, n, gear, tier, amount)
  local att, mult = passive.attuned(pid, n), 1
  local key = 'PLAYER:' .. pid .. ':charge:' .. n
  local charge = tonumber(redis.call('GET', key)) or 0
  if charge > 0 then
    mult = mult + 0.1 * charge
    redis.call('DEL', key)
  end
  if att.moonlit_edge and tier >= 1 and clock(realm_of(rid)).phase == 'night' then passive.add_charge(pid, n, 1) end
  if att.bloodrhythm and tier == 0 then passive.add_charge(pid, n, 1) end
  if att.berserk_seal then mult = mult + 0.5 end
  local card = player_card(pid)
  if has_perk(pid, 'last_stand') and card.hp < card.max_hp / 4 then mult = mult + 0.2 end
  if has_perk(pid, 'iron_gut') and gear.kind == 'Potion' then mult = mult + 0.25 end
  return amount * mult
end

-- What a slot lands at a tier, after the weather, the damage scale and passives.
local function strike_amount(pid, rid, n, gear, tier)
  local wx = weathered(pid, gear, weather_at(rid))
  local amount = (wx.amounts[tier + 1] or 0) * rule('balance_damage_scale', 1)
  return empower(pid, rid, n, gear, tier, amount)
end

-- Heals (the player, or with gear that targets allies, another player in the
-- room or a friendly NPC) or guards. `whom` is an entity id or ''.
local function mend(pid, rid, n, gear, tier, amount, whom, hit, hits)
  local text_of = function(display) return fill(tier == 2 and gear.perfect_hit or gear.hit, name_of(pid), display) end
  if gear.effect == 'guard' then
    -- A guard soaks up the next blows that land on you (PLAYER:<id>:guard).
    local guard = math.min(40, (tonumber(redis.call('GET', 'PLAYER:' .. pid .. ':guard')) or 0) + amount)
    redis.call('SET', 'PLAYER:' .. pid .. ':guard', guard, 'EX', 30)
    emit('ROOM:' .. rid, {type = 'heal', actor = pid, verb = gear.id, slot = n, tier = TIER_NAMES[tier], guard = guard, hit = hit, hits = hits,
      text = text_of('themself') .. ' (guard ' .. guard .. ')'})
    return {guard = guard}
  end
  local kind, id = string.match(whom or '', '^(%a+):(.+)$')
  local display
  if gear.targets == 'ally' and kind == 'pc' and id ~= pid and redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', id) == 1 then
    display = name_of(id)
  elseif gear.targets == 'ally' and kind == 'npc' and redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', id) == 1
    and disposition_for(pid, id) == 'friendly' then
    display = npc_display(id)
  else
    kind, id = 'pc', pid
  end
  local card = kind == 'npc' and npc_card(id) or player_card(id)
  local healed = math.max(0, math.min(amount, card.max_hp - card.hp))
  redis.call('HSET', (kind == 'npc' and 'NPC:' or 'ACCOUNT:') .. id, 'hp', card.hp + healed)
  emit('ROOM:' .. rid, {type = 'heal', actor = pid, verb = gear.id, slot = n, target = kind .. ':' .. id, tier = TIER_NAMES[tier],
    amount = healed, hit = hit, hits = hits,
    text = text_of(display or 'themself') .. (healed > 0 and (' (+' .. healed .. ')') or ' (already at full health)')})
  emit('ROOM:' .. rid, {type = 'entity', entity = kind == 'npc' and npc_card(id) or player_card(id)})
  if kind == 'npc' and healed > 0 then deed(pid, 'heal', id) end
  return {healed = healed}
end

-- An NPC is down: out of the room until it respawns, and the spoils to its killer.
local function npc_down(pid, rid, nid, tier)
  local npc, display = hgetall('NPC:' .. nid), npc_display(nid)
  enc.drop_npc(nid, 'died')
  redis.call('HSET', 'NPC:' .. nid, 'hp', 0)
  redis.call('DEL', 'NPC:' .. nid .. ':bleed')
  redis.call('SREM', 'ROOM:' .. rid .. ':npcs', nid)
  redis.call('ZADD', 'alz:respawns', now_ms() + (tonumber(npc.respawn) or 300) * 1000, nid)
  emit('ROOM:' .. rid, {type = 'death', entity_id = 'npc:' .. nid, text = capitalize(display) .. ' collapses.'})
  deed(pid, 'kill', nid)
  if tier == 2 then deed(pid, 'clean_kill', nid) end
  hooks.quest(pid, 'kill', {npc = nid, faction = npc.faction, role = npc.role})
  -- Loot: claws, pelts, wings, each with a chance, into the killer's pack if there's room.
  for _, loot in ipairs(decode(npc.loot)) do
    if math.random() < (loot.chance or 1) then
      local name = redis.call('HGET', 'ITEM:' .. loot.item, 'name') or loot.item
      if hooks.pack_full(pid) then
        notice(pid, 'There was ' .. name .. ' to take, but your pack is full.')
      else
        redis.call('SADD', 'PLAYER:' .. pid .. ':inv', loot.item)
        notice(pid, 'You take ' .. name .. '.')
        kit_event(pid)
      end
    end
  end
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
    notice(pid, 'You take ' .. display .. "'s " .. table.concat(taken, ', ') .. (gear_taken and ". (EQUIP <gear> <slot>, or the Inventory panel.)" or '.'))
    kit_event(pid)
  end
  gain_xp(pid, tonumber(npc.xp) or 0)
end

-- Whether a player can attack this NPC here: returns a refusal, or nil.
local function attack_refusal(pid, rid, nid)
  if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', nid) == 0 then return "You don't see that here." end
  local owner = redis.call('HGET', 'NPC:' .. nid, 'owner')
  if owner and owner ~= pid then return "You don't see that here." end
  if disposition_for(pid, nid) == 'friendly' then return "You won't attack " .. npc_display(nid) .. '.' end
  local other = enc.of_npc(nid)
  if other and other ~= enc.here(pid, rid) then return capitalize(npc_display(nid)) .. ' is in a fight of its own.' end
end

-- A strike lands. args as encounter_strike. Returns what happened.
function enc.strike(id, pid, target, n, tier, hit, hits, mult)
  local rid = redis.call('HGET', enc_key(id), 'room')
  if not rid or redis.call('ZSCORE', enc_key(id, 'players'), pid) == false then return {gone = true} end
  local gear = slot_gear(pid, n)
  if not gear then return {gone = true} end
  if passive.slot_sealed(pid, n) then
    notice(pid, 'Slot ' .. n .. ' is sealed until the fight ends.')
    return {sealed = true}
  end
  local raw = strike_amount(pid, rid, n, gear, tier) * (mult or 1)
  local amount = math.max(1, math.ceil(raw / math.max(1, hits) - 1e-9))
  if gear.effect == 'heal' or gear.effect == 'guard' then return mend(pid, rid, n, gear, tier, amount, target, hit, hits) end
  local nid = string.match(target or '', '^npc:(.+)$')
  if not nid then return {gone = true} end
  if enc.of_npc(nid) ~= id then
    -- Striking an NPC that isn't in this fight brings it in.
    local refusal = attack_refusal(pid, rid, nid)
    if refusal then
      notice(pid, refusal)
      return {gone = true}
    end
    redis.call('SADD', enc_key(id, 'ambush'), pid .. '|' .. nid)
    enc.add_npc(id, nid)
  end
  local npc, display = hgetall('NPC:' .. nid), npc_display(nid)
  local hp = redis.call('HINCRBY', 'NPC:' .. nid, 'hp', -amount)
  local text = fill(tier == 2 and gear.perfect_hit or gear.hit, name_of(pid), display)
  emit('ROOM:' .. rid, {type = 'combat', actor = pid, verb = gear.id, slot = n, target = 'npc:' .. nid, result = 'hit',
    tier = TIER_NAMES[tier], damage = amount, hit = hit, hits = hits, text = text .. ' (' .. amount .. ')'})
  local ambush = redis.call('SREM', enc_key(id, 'ambush'), pid .. '|' .. nid) == 1
  if hp > 0 or npc.immortal == '1' then
    if hp <= 0 then
      -- Practice targets never fall.
      hp = tonumber(npc.max_hp) or 10
      redis.call('HSET', 'NPC:' .. nid, 'hp', hp)
      emit('ROOM:' .. rid, {type = 'emote', entity_id = 'npc:' .. nid, text = capitalize(display) .. ' wobbles back upright.'})
    end
    emit('ROOM:' .. rid, {type = 'entity', entity = npc_card(nid)})
    -- Bleed and burn hurt it as its next blows come.
    local bleed = decode(gear.bleed)
    if bleed.damage then redis.call('HSET', 'NPC:' .. nid .. ':bleed', 'damage', bleed.damage, 'beats', bleed.beats or 3) end
    if ambush then deed(pid, 'ambush', nid) end
    return {damage = amount, hp = hp, stagger_ms = tonumber(gear.stagger_ms) or 0}
  end
  if ambush then deed(pid, 'ambush', nid) end
  npc_down(pid, rid, nid, tier)
  return {damage = amount, hp = 0, killed = true}
end

-- An NPC's attack n lands on a player, as the owner judged it (`how`: hit,
-- dodge, block, perfect_block, staggered or parting). Returns what happened.
function enc.blow(id, nid, n, pid, how)
  local rid = redis.call('HGET', enc_key(id), 'room')
  if not rid or redis.call('ZSCORE', enc_key(id, 'players'), pid) == false
    or redis.call('ZSCORE', enc_key(id, 'npcs'), nid) == false then return {gone = true} end
  local npc = hgetall('NPC:' .. nid)
  local attack = decode(npc.attacks)[tonumber(n)]
  if not attack then return {gone = true} end
  local who, me = capitalize(npc_display(nid)), name_of(pid)
  local bleed = hgetall('NPC:' .. nid .. ':bleed')
  if bleed.damage and how ~= 'parting' then
    -- Bleeding wears it down, but never quite kills it: someone has to finish it.
    local left = math.max(1, (tonumber(npc.hp) or 1) - tonumber(bleed.damage))
    redis.call('HSET', 'NPC:' .. nid, 'hp', left)
    emit('ROOM:' .. rid, {type = 'entity', entity = npc_card(nid), text = who .. ' bleeds. (' .. bleed.damage .. ')'})
    if redis.call('HINCRBY', 'NPC:' .. nid .. ':bleed', 'beats', -1) <= 0 then redis.call('DEL', 'NPC:' .. nid .. ':bleed') end
  end
  local damage, notes = tonumber(attack.damage) or 0, {}
  local text = fill(attack.hit, who, me)
  if how == 'dodge' then
    damage, text = 0, me .. ' dodges ' .. npc_display(nid) .. "'s " .. attack.name .. '.'
  elseif how == 'perfect_block' then
    damage, text = 0, me .. ' blocks ' .. npc_display(nid) .. "'s " .. attack.name .. ' perfectly!'
  elseif how == 'block' then
    local hand = hooks.worn(pid, 'hand')
    local cut = math.min(1, rule('balance_block_cut', 0.7) * (hand and tonumber(hand.block) or 1))
    local saved = math.min(damage, round(damage * cut))
    damage = damage - saved
    if saved > 0 then notes[#notes + 1] = saved .. ' blocked' end
    text = me .. ' blocks ' .. npc_display(nid) .. "'s " .. attack.name .. '.'
  elseif how == 'parting' then
    text = who .. ' lands a parting blow as ' .. me .. ' breaks away.'
  end
  if damage > 0 then
    local guard = tonumber(redis.call('GET', 'PLAYER:' .. pid .. ':guard')) or 0
    if guard > 0 then
      local soaked = math.min(guard, damage)
      damage = damage - soaked
      if guard - soaked > 0 then
        redis.call('SET', 'PLAYER:' .. pid .. ':guard', guard - soaked, 'KEEPTTL')
      else
        redis.call('DEL', 'PLAYER:' .. pid .. ':guard')
      end
      if soaked > 0 then notes[#notes + 1] = soaked .. ' guarded' end
    end
    local armored = math.min(damage, round(damage * hooks.armor_share(pid)))
    if armored > 0 then
      damage = damage - armored
      notes[#notes + 1] = armored .. ' armour'
    end
    if how == 'staggered' and damage > 0 then
      local more = round(damage * rule('balance_stagger_dmg', 1.5)) - damage
      damage = damage + more
      if more > 0 then notes[#notes + 1] = '+' .. more .. ' staggered' end
    end
  end
  local hp = player_card(pid).hp - damage
  redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', math.max(hp, 0))
  if damage > 0 then redis.call('SADD', 'alz:wounded', pid) end
  emit('ROOM:' .. rid, {type = 'combat', entity_id = 'npc:' .. nid, verb = attack.name, target = 'pc:' .. pid, result = how,
    damage = damage, text = text .. ' (' .. damage .. (#notes > 0 and (', ' .. table.concat(notes, ', ')) or '') .. ')'})
  if hp <= 0 then
    defeat(pid, nid)
    return {damage = damage, hp = 0, dead = true}
  end
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
  return {damage = damage, hp = hp}
end

-- Striking first, out of an encounter: starts one with the NPC, or joins the
-- one it's in (or the room's). The strike itself is the encounter's opening:
-- the owner lands it as soon as the lead-in is over.
function enc.attack(pid, rid, nid, n)
  local refusal = attack_refusal(pid, rid, nid)
  if refusal then return notice(pid, refusal) end
  local id = enc.of_npc(nid) or enc.here(pid, rid)
  local fighting_me = id and enc.of_npc(nid) == id and enc.of_player(pid) == id
  if not id then id = enc.create(rid, 'pve', redis.call('HGET', 'NPC:' .. nid, 'owner') == false) end
  if not fighting_me then redis.call('SADD', enc_key(id, 'ambush'), pid .. '|' .. nid) end
  redis.call('HSET', enc_key(id, 'opening'), pid, n .. '|npc:' .. nid)
  enc.add_npc(id, nid)
  enc.add_player(id, pid)
end

-- The flee key ('back': the way the player walked in; on a journey ambush,
-- off into the wilds): the owner has checked the player is steady. The toughest
-- enemy in the fight (most health; ties to the harder hitter) lands its
-- hardest attack as a parting blow, then the player is out and away, at a run.
-- The NPCs don't follow.
function enc.flee(id, pid, dir)
  local rid = redis.call('HGET', enc_key(id), 'room')
  if not rid or redis.call('ZSCORE', enc_key(id, 'players'), pid) == false then return {gone = true} end
  if dir == 'back' then
    if redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'ambush') then
      hooks.strand(pid, 'You run, and keep running, and the road is lost behind you. You come to your senses somewhere in the wilds, bruised and alone.')
      return {fled = true}
    end
    local came = redis.call('GET', 'PLAYER:' .. pid .. ':came')
    dir = nil
    for d, to in pairs(hgetall('ROOM:' .. rid .. ':exits')) do
      if to == came then dir = d end
    end
    if not dir then
      notice(pid, "There's no way back the way you came: you'll have to fight.")
      return {refused = 'no_way_back'}
    end
  end
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir or '')
  if not dest then
    notice(pid, "You can't go that way.")
    return {refused = 'no_exit'}
  end
  local here = weather_at(rid)
  if not can_see(here, pid) and obscured_by(here) == 'darkness' and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 0 then
    notice(pid, "It's too dark to find a way " .. dir .. '. You need a light in your hand: EQUIP TORCH.')
    return {refused = 'dark'}
  end
  local fled = redis.call('ZRANGE', enc_key(id, 'npcs'), 0, -1)
  local best, best_n, best_hp, best_dmg
  for _, nid in ipairs(fled) do
    local hp = tonumber(redis.call('HGET', 'NPC:' .. nid, 'max_hp')) or 0
    for i, a in ipairs(npc_attacks(nid)) do
      local dmg = tonumber(a.damage) or 0
      if not best or hp > best_hp or (hp == best_hp and dmg > best_dmg) then best, best_n, best_hp, best_dmg = nid, i, hp, dmg end
    end
  end
  if best then
    local result = enc.blow(id, best, best_n, pid, 'parting')
    if result.dead then return {dead = true, damage = result.damage} end
  end
  enc.drop_player(pid, 'fled')
  finish_move(pid, rid, dir, dest, false)
  for _, nid in ipairs(fled) do deed(pid, 'flee', nid) end
  return {fled = true}
end

-- The encounter functions, for the owner (alzendor/encounter.py) and tests.
-- KEYS[1] is the calling server's id: an encounter a function starts is owned
-- by that server.
local function caller(keys) CALLER.server = keys and keys[1] or '' end

-- args: room, kind, seed ('' for one of its own), pid, npc ids… Returns the id.
redis.register_function('encounter_start', function(keys, args)
  caller(keys)
  local rid, kind, pid = args[1], args[2], args[4]
  local id = enc.create(rid, kind ~= '' and kind or 'pve', true)
  if (args[3] or '') ~= '' then redis.call('HSET', enc_key(id), 'seed', args[3]) end
  for i = 5, #args do enc.add_npc(id, args[i]) end
  if (pid or '') ~= '' then enc.add_player(id, pid) end
  return id
end)

-- args: id, 'pc:<id>' or 'npc:<id>'.
redis.register_function('encounter_join', function(keys, args)
  caller(keys)
  if redis.call('EXISTS', enc_key(args[1])) == 0 then return 0 end
  local kind, who = string.match(args[2], '^(%a+):(.+)$')
  if kind == 'pc' then enc.add_player(args[1], who) elseif kind == 'npc' then enc.add_npc(args[1], who) end
  return 1
end)

-- args: id, 'pc:<id>' or 'npc:<id>', why.
redis.register_function('encounter_leave', function(keys, args)
  caller(keys)
  local kind, who = string.match(args[2], '^(%a+):(.+)$')
  if kind == 'pc' and enc.of_player(who) == args[1] then enc.drop_player(who, args[3] or 'left') end
  if kind == 'npc' and enc.of_npc(who) == args[1] then enc.drop_npc(who, args[3] or 'gone') end
  return 1
end)

-- args: id, why. An encounter that's lost its owner ends with everyone as
-- they are, and the one rule runs again for the players still there (a fresh
-- encounter, owned by the server that found it).
redis.register_function('encounter_end', function(keys, args)
  caller(keys)
  local id, why = args[1], args[2] or 'ended'
  local rid = redis.call('HGET', enc_key(id), 'room')
  if not rid then return 0 end
  local players = redis.call('ZRANGE', enc_key(id, 'players'), 0, -1)
  enc.finish(id, why)
  if why == 'lost' then
    for _, pid in ipairs(players) do aggro(pid, rid) end
  end
  return 1
end)

-- args: id, pid, target ('npc:<id>', 'pc:<id>' or ''), slot, tier (0-2), hit, hits, multiplier.
redis.register_function('encounter_strike', function(keys, args)
  caller(keys)
  return cjson.encode(enc.strike(args[1], args[2], args[3], tonumber(args[4]), tonumber(args[5]) or 0,
    tonumber(args[6]) or 1, tonumber(args[7]) or 1, tonumber(args[8]) or 1))
end)

-- args: id, npc id, attack number, pid, how.
redis.register_function('encounter_blow', function(keys, args)
  caller(keys)
  return cjson.encode(enc.blow(args[1], args[2], tonumber(args[3]), args[4], args[5]))
end)

-- args: id, pid, direction.
redis.register_function('encounter_flee', function(keys, args)
  caller(keys)
  return cjson.encode(enc.flee(args[1], args[2], args[3]))
end)

-- args: id, npc id, what. Something the room sees of an NPC in the fight:
-- `reels` (a boss's stagger meter filled), `steadies` (it's over).
redis.register_function('encounter_note', function(keys, args)
  local rid = redis.call('HGET', enc_key(args[1]), 'room')
  if not rid then return 0 end
  local who = capitalize(npc_display(args[2]))
  local text = args[3] == 'reels' and (who .. ' reels!') or (who .. ' steadies itself.')
  emit('ROOM:' .. rid, {type = 'emote', verb = args[3], entity_id = 'npc:' .. args[2], text = text})
  return 1
end)

-- args: id, pid, what. A passive at work on the dot: `second_wind` (back in
-- the core after a knock: 1 health) or `seal` (Berserk Seal: the first
-- stagger seals its slot for the rest of the fight).
redis.register_function('encounter_passive', function(keys, args)
  local id, pid, what = args[1], args[2], args[3]
  local rid = redis.call('HGET', enc_key(id), 'room')
  if not rid or redis.call('ZSCORE', enc_key(id, 'players'), pid) == false then return 0 end
  if what == 'second_wind' and has_perk(pid, 'second_wind') then
    local card = player_card(pid)
    if card.hp >= card.max_hp then return 0 end
    redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', card.hp + 1)
    emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
    return 1
  elseif what == 'seal' and has_perk(pid, 'berserk_seal') then
    local n = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':attuned', 'berserk_seal'))
    if not n or redis.call('EXISTS', 'PLAYER:' .. pid .. ':sealed') == 1 then return 0 end
    redis.call('SADD', 'PLAYER:' .. pid .. ':sealed', n)
    notice(pid, 'Berserk Seal: you stagger, and slot ' .. n .. ' is sealed until the fight ends.')
    return 1
  end
  return 0
end)

-- args: id. Everything about it, as JSON ('' if it's over).
redis.register_function{function_name = 'encounter_info', flags = {'no-writes'}, callback = function(keys, args)
  local info = enc.info(args[1])
  return info and cjson.encode(info) or ''
end}

-- Uses whatever is in a slot, out of a fight (in one, the session sends the
-- slot to the encounter as an input instead). args: pid, slot number, target
-- word ('' for none). A heal or guard just works, at its clean amount, and
-- then waits out its cooldown; damage gear on an NPC strikes first, which
-- starts a fight with it.
redis.register_function('use', action(function(pid, rid, args)
  local n = slot_number(args[2])
  if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  local gear = slot_gear(pid, n)
  if not gear then return notice(pid, 'Slot ' .. n .. " is empty. Try EQUIP <gear> " .. n .. ", or GEAR to see what you have.") end
  local word = args[3] or ''
  if gear.effect == 'heal' or gear.effect == 'guard' then
    -- Out of a fight, gear waits longer (out_of_fight_cooldown_scale) than it does in one.
    local cooldown = math.floor((tonumber(gear.cooldown) or 0) * rule('out_of_fight_cooldown_scale', 3))
    if cooldown > 0 and not redis.call('SET', 'PLAYER:' .. pid .. ':cd:' .. n, '1', 'NX', 'PX', cooldown) then
      return notice(pid, gear.name .. " isn't ready yet.")
    end
    local whom = ''
    if gear.targets == 'ally' and word ~= '' then
      local kind, id = resolve(pid, rid, word)
      if kind == 'player' then whom = 'pc:' .. id elseif kind == 'npc' then whom = 'npc:' .. id end
    end
    local amount = math.max(1, math.ceil(strike_amount(pid, rid, n, gear, 1) - 1e-9))
    return mend(pid, rid, n, gear, 1, amount, whom, 1, 1)
  end
  if word == '' then return notice(pid, gear.name .. ' what? Name a target, or press Tab to pick one.') end
  local kind, id, display = resolve(pid, rid, word)
  if not kind then return notice(pid, "You don't see that here.") end
  if kind == 'self' then return notice(pid, 'You think better of it.') end
  if kind == 'player' then return notice(pid, "You can't attack other players.") end
  if kind ~= 'npc' then return notice(pid, "You can't fight that.") end
  if enc.of_player(pid) then return notice(pid, 'You strike from your balance in a fight: press the slot key.') end
  enc.attack(pid, rid, id, n)
end))

-- Puts gear in a slot. args: pid, gear word, slot number ('' for the first
-- empty one).
redis.register_function('equip', action(function(pid, rid, args)
  local gid = match_gear(args[2])
  -- Not slot gear: worn gear (a hat, a torch) goes where it goes.
  if (not gid or redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':gear', gid) == 0) and hooks.owns_wearable(pid, args[2]) then
    return hooks.put_on(pid, rid, args[2], 'equip')
  end
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
  local class = decode(redis.call('HGET', 'alz:classes', redis.call('HGET', 'ACCOUNT:' .. pid, 'class') or '-'))
  if class.kinds then
    local allowed = false
    for _, kind in ipairs(class.kinds) do if kind == gear.kind then allowed = true end end
    if not allowed then return notice(pid, 'A ' .. class.name .. " can't use " .. string.lower(gear.kind) .. ' gear like ' .. gear.name .. '.') end
  end
  if redis.call('HGET', slots, n) == gid then return notice(pid, 'Slot ' .. n .. ' already holds ' .. gear.name .. '.') end
  if mid_fight(pid) then return end
  redis.call('HSET', slots, n, gid)
  notice(pid, 'Slot ' .. n .. ': ' .. gear.name .. ', ready every ' .. string.format('%.1f', (tonumber(gear.cooldown) or 0) / 1000) .. 's.')
  kit_event(pid)
end))

-- Empties a slot. args: pid, slot number.
redis.register_function('unequip', action(function(pid, rid, args)
  local n = slot_number(args[2])
  if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  local gear = slot_gear(pid, n)
  if not gear then return notice(pid, 'Slot ' .. n .. ' is already empty.') end
  if mid_fight(pid) then return end
  redis.call('HDEL', 'PLAYER:' .. pid .. ':slots', n)
  notice(pid, 'Slot ' .. n .. ' is empty now.')
  kit_event(pid)
end))

-- Lists the gear the player has, fastest first, and what's in their slots.
redis.register_function('gear', action(function(pid, rid, args)
  local gear, lines = list(), {'Your gear in this weather (edge / clean / perfect):'}
  local w = weather_at(rid)
  for _, g in ipairs(owned_gear(pid)) do
    local summary = gear_summary(g, pid, w)
    local now = summary.now
    gear[#gear + 1] = summary
    local change = pct(now.factor)
    lines[#lines + 1] = '  ' .. g.name .. ' (' .. string.lower(g.kind or '') .. ', ' .. summary.weather.tier .. '): every '
      .. string.format('%.1f', summary.cooldown_ms / 1000) .. 's, ' .. (g.effect == 'heal' and 'heals ' or '') .. now.amounts[1] .. ' / '
      .. now.amounts[2] .. ' / ' .. now.amounts[3] .. (g.effect == 'heal' and '' or ' damage')
      .. (summary.hits > 1 and (' in ' .. summary.hits .. ' hits') or '') .. (summary.targets == 'ally' and ', on you or an ally' or '')
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
    return emit(here_channel(pid, rid), {type = 'say', actor = pid, verb = 'say', target = (kind == 'npc' and 'npc:' or 'pc:') .. id,
      message = message, text = me .. ' says to ' .. display .. ', "' .. message .. '"'})
  end
  emit(here_channel(pid, rid), {type = 'say', actor = pid, verb = 'say', message = message, text = me .. ' says, "' .. message .. '"'})
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
    return emit(here_channel(pid, rid), {type = 'emote', actor = pid, verb = 'emote', text = me .. ' ' .. plain})
  end
  if word == '' then
    return emit(here_channel(pid, rid), {type = 'emote', actor = pid, verb = verb, text = fill(plain, me)})
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
  emit(here_channel(pid, rid), {type = 'emote', actor = pid, verb = verb, target = id, text = text})
  local social = kind == 'npc' and SOCIAL[verb]
  if social and redis.call('SET', 'PLAYER:' .. pid .. ':social:' .. id, '1', 'NX', 'EX', rule('social_cooldown', 600)) then
    deed(pid, social, id)
    if social == 'taunt' then hooks.add_rapport(pid, id, -1) end
  end
end))

redis.register_function('describe', action(function(pid, rid, args)
  redis.call('HSET', 'ACCOUNT:' .. pid, 'description', args[2])
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
  notice(pid, 'Others now see you as: ' .. args[2])
end))

redis.register_function('get', action(function(pid, rid, args)
  local iid, item = match_item('ROOM:' .. rid .. ':items', args[2])
  local personal = false
  if not iid then
    iid, item = match_ids(quest_items_here(pid, rid), args[2])
    personal = iid ~= nil
  end
  if not iid then return notice(pid, "You don't see that here.") end
  local size = rule('pack_size', 12)
  if pack_count(pid) >= size then
    return notice(pid, 'Your pack is full (' .. pack_count(pid) .. '/' .. size .. '). Drop something first.')
  end
  if personal then
    redis.call('SADD', 'PLAYER:' .. pid .. ':taken', iid)
    redis.call('SADD', 'PLAYER:' .. pid .. ':inv', iid)
  else
    redis.call('SMOVE', 'ROOM:' .. rid .. ':items', 'PLAYER:' .. pid .. ':inv', iid)
  end
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
  hooks.quest(pid, 'get', {item = iid})
end))

redis.register_function('drop', action(function(pid, rid, args)
  local iid, item = match_item('PLAYER:' .. pid .. ':inv', args[2])
  if not iid then return notice(pid, "You aren't carrying that.") end
  if item.quest == '1' then return notice(pid, "You'd better hold on to the " .. item.name .. '.') end
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

-- Characters ------------------------------------------------------------------------
-- Class, ancestry and background (docs/characters.md), chosen once when a
-- character is created; talents (gear learned from your class's pool) at
-- levels 3, 6 … 18, opening rank 2 after 2 and rank 3 after 4; ancestry
-- passives (perks from your ancestry's pool) at creation and at levels 5, 10,
-- 15 and 20. PLAYER:<id>:talents and PLAYER:<id>:passives remember which gear
-- and perks were learned that way, for respec. Worn gear is here too.
do

local function catalog(kind, id)
  return decode(redis.call('HGET', 'alz:' .. kind, id or '-'))
end

-- Worn gear: PLAYER:<id>:wardrobe holds what a player owns, PLAYER:<id>:worn
-- what's on (place -> id), and PLAYER:<id>:worn_stats what it all adds up to
-- (stats, and armour, which takes armor / (armor + armor_k) off every blow).
local PLACES = {'head', 'chest', 'legs', 'hand'}
local TYPE_NAMES = {cloth = 'cloth', leather = 'leather', mail = 'mail', shield = 'a shield', light = 'a light', orb = 'an orb'}

local function wearable(wid)
  local w = decode(redis.call('HGET', 'alz:wearables', wid or '-'))
  if w.name then w.id = wid return w end
end

local function refresh_worn(pid)
  local key = 'PLAYER:' .. pid .. ':worn_stats'
  redis.call('DEL', key)
  for _, place in ipairs(PLACES) do
    local w = hooks.worn(pid, place)
    if w then
      if (tonumber(w.armor) or 0) > 0 then redis.call('HINCRBY', key, 'armor', w.armor) end
      for s, n in pairs(w.stats or {}) do redis.call('HINCRBY', key, s, n) end
    end
  end
end

-- How much of each blow a player's armour takes, 0..1.
hooks.armor_share = function(pid)
  local armor = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':worn_stats', 'armor')) or 0
  return armor / (armor + rule('armor_k', 30))
end

local function can_wear(class, w)
  if not class.wears then return true end
  for _, t in ipairs(class.wears) do if t == w.type then return true end end
  return false
end

-- What the client shows of a piece of worn gear.
local function wearable_card(w, on)
  return {id = w.id, name = w.name, place = w.place, type = w.type, armor = tonumber(w.armor) or 0, stats = w.stats,
    light = w.light or nil, block = w.block, rarity = w.rarity or 'common', description = w.description or '', worn = on or nil}
end

-- The worn gear a player owns, found by id, name or a word of either.
local function owned_wearable(pid, word)
  word = string.lower(word or '')
  if word == '' then return nil end
  for _, wid in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':wardrobe'))) do
    local w = wearable(wid)
    if w and (wid == word or string.lower(w.name) == word
      or (' ' .. string.lower(w.name .. ' ' .. (w.keywords or '')) .. ' '):find(' ' .. word .. ' ', 1, true)) then
      return w
    end
  end
end

hooks.owns_wearable = function(pid, word) return owned_wearable(pid, word) ~= nil end

-- Gives a player a piece of worn gear (quest rewards). Puts it on if that place is free.
hooks.give_wearable = function(pid, wid)
  local w = wearable(wid)
  if not w or redis.call('SADD', 'PLAYER:' .. pid .. ':wardrobe', wid) == 0 then return end
  local class = decode(redis.call('HGET', 'alz:classes', redis.call('HGET', 'ACCOUNT:' .. pid, 'class') or '-'))
  notice(pid, 'You receive the ' .. w.name .. '. (' .. (w.place == 'hand' and 'HOLD ' or 'WEAR ') .. string.upper(w.name) .. ' to '
    .. (w.place == 'hand' and 'hold' or 'wear') .. ' it, or see the Character panel.)')
  if can_wear(class, w) and not redis.call('HGET', 'PLAYER:' .. pid .. ':worn', w.place) and w.place ~= 'hand' then
    redis.call('HSET', 'PLAYER:' .. pid .. ':worn', w.place, wid)
    refresh_worn(pid)
  end
end

-- Wears or holds worn gear. how: 'wear' (head, chest, legs; a hand item is
-- held, with a word about HOLD), 'hold' (hand items only) or 'equip' (either).
hooks.put_on = function(pid, rid, word, how)
  local w = owned_wearable(pid, word)
  if not w then return notice(pid, "You don't have anything called '" .. (word or '') .. "' to " .. how .. '.') end
  if how == 'hold' and w.place ~= 'hand' then
    return notice(pid, 'The ' .. w.name .. " isn't something to hold: WEAR " .. string.upper(w.name) .. '.')
  end
  local class = catalog('classes', redis.call('HGET', 'ACCOUNT:' .. pid, 'class'))
  if not can_wear(class, w) then
    return notice(pid, 'A ' .. class.name .. " can't use " .. (TYPE_NAMES[w.type] or w.type) .. ' like the ' .. w.name .. '.')
  end
  local key = 'PLAYER:' .. pid .. ':worn'
  if redis.call('HGET', key, w.place) == w.id then return notice(pid, "You've already got the " .. w.name .. ' on.') end
  -- A hand can change mid-fight (a torch for a shield); armour can't.
  if w.place ~= 'hand' and mid_fight(pid) then return end
  local old = hooks.worn(pid, w.place)
  redis.call('HSET', key, w.place, w.id)
  refresh_worn(pid)
  notice(pid, (w.place == 'hand' and 'You hold the ' or 'You put on the ') .. w.name
    .. (old and (', and put away the ' .. old.name) or '') .. '.' .. (w.light and ' It lights the way.' or '')
    .. (how == 'wear' and w.place == 'hand' and ' (HOLD is for things in your hand.)' or ''))
  room_event(pid, rid, 'look') -- a light shows the ways on
  weather_event(pid)
  kit_event(pid)
  character_event(pid)
end

redis.register_function('wear', action(function(pid, rid, args)
  hooks.put_on(pid, rid, args[2], 'wear')
end))

redis.register_function('hold', action(function(pid, rid, args)
  hooks.put_on(pid, rid, args[2], 'hold')
end))

-- Takes off worn gear. args: pid, its name or its place (head, chest, legs, hand).
redis.register_function('remove', action(function(pid, rid, args)
  local word, place = string.lower(args[2] or ''), nil
  for _, p in ipairs(PLACES) do if p == word then place = p end end
  if not place then
    local w = owned_wearable(pid, word)
    if w and redis.call('HGET', 'PLAYER:' .. pid .. ':worn', w.place) == w.id then place = w.place end
  end
  local old = place and hooks.worn(pid, place)
  if not old then return notice(pid, "You aren't wearing anything like that.") end
  if place ~= 'hand' and mid_fight(pid) then return end
  redis.call('HDEL', 'PLAYER:' .. pid .. ':worn', place)
  refresh_worn(pid)
  notice(pid, (place == 'hand' and 'You put away the ' or 'You take off the ') .. old.name .. '.')
  room_event(pid, rid, 'look')
  weather_event(pid)
  kit_event(pid)
  character_event(pid)
end))

local function talent_picks(pid)
  return math.floor(level_of(pid) / 3) - redis.call('SCARD', 'PLAYER:' .. pid .. ':talents')
end

local function passive_picks(pid)
  return 1 + math.floor(level_of(pid) / 5) - redis.call('SCARD', 'PLAYER:' .. pid .. ':passives')
end

-- Why a talent can't be learned yet, or nil.
local function talent_locked(pid, gid)
  local gear = gear_info(gid)
  local learned = redis.call('SCARD', 'PLAYER:' .. pid .. ':talents')
  local rank = tonumber(gear.rank) or 1
  if rank == 2 and learned < 2 then return 'opens after 2 talents' end
  if rank == 3 and learned < 4 then return 'opens after 4 talents' end
  if (gear.requires or '') ~= '' and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':talents', gear.requires) == 0 then
    return 'needs ' .. (gear_info(gear.requires) or {name = gear.requires}).name
  end
end

-- Adds the class, ancestry and background, and what can be learned, to the character sheet.
hooks.choices = function(pid, account, event)
  local class, ancestry = catalog('classes', account.class), catalog('ancestries', account.ancestry)
  local background = catalog('backgrounds', account.background)
  if not class.name then return end
  event.class, event.ancestry, event.background = class.name, ancestry.name, background.name
  event.talent_picks, event.passive_picks = talent_picks(pid), passive_picks(pid)
  event.talents = list()
  local w = weather_at(redis.call('GET', 'PLAYER:' .. pid .. ':room'))
  for _, gid in ipairs(class.talents or {}) do
    local gear = gear_info(gid)
    if gear then
      -- The whole gear summary, so the client can show what a talent does before you learn it.
      local talent = gear_summary(gear, pid, w)
      talent.rank, talent.learned, talent.locked = tonumber(gear.rank) or 1,
        redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':talents', gid) == 1, talent_locked(pid, gid)
      event.talents[#event.talents + 1] = talent
    end
  end
  event.worn, event.wardrobe = {}, list()
  for _, place in ipairs(PLACES) do
    local on = hooks.worn(pid, place)
    if on then event.worn[place] = wearable_card(on, true) end
  end
  for _, wid in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':wardrobe'))) do
    local item = wearable(wid)
    if item then
      local card = wearable_card(item, redis.call('HGET', 'PLAYER:' .. pid .. ':worn', item.place) == wid)
      card.usable = can_wear(class, item)
      event.wardrobe[#event.wardrobe + 1] = card
    end
  end
  event.places = list(PLACES)
  event.armor = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':worn_stats', 'armor')) or 0
  event.armor_pct = round(hooks.armor_share(pid) * 100)
  event.passives = list()
  for _, perk in ipairs(ancestry.passives or {}) do
    local info = hgetall('PERK:' .. perk)
    event.passives[#event.passives + 1] = {id = perk, name = info.name or perk, description = info.description or '',
      slot = info.slot == '1', learned = has_perk(pid, perk)}
  end
end

-- Wipes a character back to nothing, keeping the account (name, password).
local CHARACTER_FIELDS = {'class', 'ancestry', 'background', 'label', 'created', 'intro', 'level', 'xp', 'points', 'hp', 'coins',
  'loadout_set', 'kit_set', 'stat:vigor', 'stat:poise', 'stat:focus', 'stat:presence', 'stat:resilience', 'description', 'asleep'}

local function reset_character(pid)
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid then redis.call('SREM', 'ROOM:' .. rid .. ':players', pid) end
  enc.drop_player(pid, 'gone')
  redis.call('HDEL', 'ACCOUNT:' .. pid, unpack(CHARACTER_FIELDS))
  -- Per-quest and per-faction state, by the ids it can have (not KEYS: that
  -- scans every key in Redis). Short-lived keys (social:, unseen:, greeted:,
  -- gift:, sold:, lured:, buff:, slowed, moved) are left to expire.
  for _, qid in ipairs(redis.call('HKEYS', 'PLAYER:' .. pid .. ':quests')) do
    redis.call('DEL', 'PLAYER:' .. pid .. ':quest:' .. qid)
  end
  for _, fid in ipairs(redis.call('SMEMBERS', 'alz:factions')) do redis.call('DEL', 'PLAYER:' .. pid .. ':rep:' .. fid) end
  -- Every lasting PLAYER:<id>:<name> key a character has (tests/test_characters.py checks this list).
  for _, suffix in ipairs({'room', 'gear', 'slots', 'inv', 'perks', 'passives', 'talents', 'attuned', 'bonus', 'explored',
    'glimpsed', 'regions', 'realms', 'rumours', 'lore', 'traps', 'events', 'taken', 'quests', 'journey', 'pending',
    'guard', 'sealed', 'ambushers', 'wardrobe', 'worn', 'worn_stats', 'exposure', 'came',
    'rapport', 'met', 'discussed', 'offer', 'declined', 'kit_sum'}) do
    redis.call('DEL', 'PLAYER:' .. pid .. ':' .. suffix)
  end
  for n = 1, SLOTS do redis.call('DEL', 'PLAYER:' .. pid .. ':cd:' .. n, 'PLAYER:' .. pid .. ':charge:' .. n) end
  redis.call('ZREM', 'alz:journeys', pid)
  redis.call('ZREM', 'alz:pending_moves', pid)
  redis.call('ZREM', 'alz:sleepers', pid)
  redis.call('SREM', 'alz:wounded', pid)
end

-- Admin and deploy: wipes a character so its player creates a new one. It
-- also takes them out of the world, connected or linkdead, so their next login
-- is a fresh start (the intro and first quest) and not a reconnect.
redis.register_function('reset_character', function(keys, args)
  local pid = args[1]
  local session = redis.call('GET', 'PLAYER:' .. pid .. ':session')
  if session then
    emit('PLAYER:' .. pid, {type = 'control', op = 'kick', session = session, reason = 'Your character was reset. Log in again to make a new one.'})
  end
  reset_character(pid)
  redis.call('DEL', 'PLAYER:' .. pid .. ':session', 'PLAYER:' .. pid .. ':subs')
  redis.call('ZREM', 'alz:online', pid)
  return 1
end)

-- The two background items a class can use (of the background's four).
local function background_items(class, background)
  local out, usable = {}, {}
  for _, kind in ipairs(class.kinds or {}) do usable[kind] = true end
  for _, gid in ipairs(background.items or {}) do
    local gear = gear_info(gid)
    if gear and usable[gear.kind] and #out < 2 then out[#out + 1] = gid end
  end
  return out
end

-- Creates a character. args: pid, class, ancestry, first passive, background.
-- Returns '' on success, or why not. Called before the player enters the world.
redis.register_function('create_character', function(keys, args)
  local pid, cid, aid, perk, bid = args[1], args[2], args[3], args[4], args[5]
  local class, ancestry, background = catalog('classes', cid), catalog('ancestries', aid), catalog('backgrounds', bid)
  if not class.name then return 'Choose a class.' end
  if not ancestry.name then return 'Choose an ancestry.' end
  if not background.name then return 'Choose a background.' end
  local fits = false
  for _, p in ipairs(ancestry.passives or {}) do if p == perk then fits = true end end
  if not fits then return 'Choose a passive from your ancestry.' end
  -- Two tabs on a new account can both be on the creation screen: the second
  -- mustn't wipe the character the first just took into the world.
  if redis.call('HGET', 'ACCOUNT:' .. pid, 'created') == '1' then return 'Your character already exists.' end
  reset_character(pid)
  local key = 'ACCOUNT:' .. pid
  redis.call('HSET', key, 'class', cid, 'ancestry', aid, 'background', bid, 'label', ancestry.name .. ' ' .. class.name,
    'created', '1', 'level', 1, 'xp', 0, 'points', 0, 'coins', background.coins or 0, 'loadout_set', '1', 'kit_set', '1', 'intro', '1')
  redis.call('HSET', 'PLAYER:' .. pid .. ':bonus', ancestry.stat, 1)
  redis.call('HSET', key, 'hp', max_hp_of(pid))
  redis.call('SADD', 'PLAYER:' .. pid .. ':perks', perk)
  redis.call('SADD', 'PLAYER:' .. pid .. ':passives', perk)
  local loadout = {class.ability}
  for _, gid in ipairs(background_items(class, background)) do loadout[#loadout + 1] = gid end
  for n, gid in ipairs(loadout) do
    redis.call('SADD', 'PLAYER:' .. pid .. ':gear', gid)
    redis.call('HSET', 'PLAYER:' .. pid .. ':slots', n, gid)
  end
  -- Starting clothes: the class's and the background's, on where they fit.
  for _, list_ in ipairs({class.outfit or {}, background.outfit or {}}) do
    for _, wid in ipairs(list_) do
      local w = wearable(wid)
      if w and can_wear(class, w) then
        redis.call('SADD', 'PLAYER:' .. pid .. ':wardrobe', wid)
        redis.call('HSETNX', 'PLAYER:' .. pid .. ':worn', w.place, wid)
      end
    end
  end
  refresh_worn(pid)
  redis.call('HSET', key, 'hp', max_hp_of(pid))
  for _, o in ipairs(background.opinions or {}) do
    if redis.call('EXISTS', 'FACTION:' .. o.faction) == 1 then
      redis.call('HSET', 'PLAYER:' .. pid .. ':rep:' .. o.faction, 'affinity', o.affinity or 0, 'respect', o.respect or 0)
    end
  end
  redis.call('SET', 'PLAYER:' .. pid .. ':room', background.start)
  return ''
end)

-- Learns a talent or an ancestry passive. args: pid, a word naming it.
redis.register_function('learn', action(function(pid, rid, args)
  local account = hgetall('ACCOUNT:' .. pid)
  local class, ancestry = catalog('classes', account.class), catalog('ancestries', account.ancestry)
  if not class.name then return notice(pid, 'You have no class to learn from.') end
  local word = string.lower(args[2] or '')
  for _, gid in ipairs(class.talents or {}) do
    local gear = gear_info(gid)
    if gear and (gid == word or string.lower(gear.name) == word) then
      if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':talents', gid) == 1 then return notice(pid, 'You already know ' .. gear.name .. '.') end
      if talent_picks(pid) <= 0 then return notice(pid, 'You have no talent to learn yet: one comes every third level (3, 6, 9 … 18).') end
      local locked = talent_locked(pid, gid)
      if locked then return notice(pid, gear.name .. ' ' .. locked .. '.') end
      redis.call('SADD', 'PLAYER:' .. pid .. ':talents', gid)
      redis.call('SADD', 'PLAYER:' .. pid .. ':gear', gid)
      notice(pid, 'You learn ' .. gear.name .. '. EQUIP ' .. string.upper(gear.name) .. ' <slot> to use it.')
      kit_event(pid)
      return character_event(pid)
    end
  end
  for _, perk in ipairs(ancestry.passives or {}) do
    local info = hgetall('PERK:' .. perk)
    if perk == word or string.lower(info.name or '') == word then
      if has_perk(pid, perk) then return notice(pid, 'You already have ' .. info.name .. '.') end
      if passive_picks(pid) <= 0 then return notice(pid, 'You have no passive to choose yet: one comes at levels 5, 10, 15 and 20.') end
      redis.call('SADD', 'PLAYER:' .. pid .. ':perks', perk)
      redis.call('SADD', 'PLAYER:' .. pid .. ':passives', perk)
      notice(pid, 'You gain ' .. info.name .. ': ' .. info.description
        .. (info.slot == '1' and ' ATTUNE ' .. string.upper(info.name) .. ' <slot> to choose its slot.' or ''))
      room_event(pid, rid, 'look')
      return character_event(pid)
    end
  end
  notice(pid, "There's nothing called '" .. (args[2] or '') .. "' for you to learn. The Character panel lists what you can.")
end))

-- Attunes a slot passive to a slot. args: pid, passive word, slot.
redis.register_function('attune', action(function(pid, rid, args)
  local word, n = string.lower(args[2] or ''), slot_number(args[3])
  if not n then return notice(pid, 'Your slots are 1, 2 and 3.') end
  for _, perk in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks')) do
    local info = hgetall('PERK:' .. perk)
    if perk == word or string.lower(info.name or '') == word then
      if info.slot ~= '1' then return notice(pid, info.name .. " doesn't belong to a slot.") end
      if mid_fight(pid) then return end
      redis.call('HSET', 'PLAYER:' .. pid .. ':attuned', perk, n)
      notice(pid, info.name .. ' is attuned to slot ' .. n .. '.')
      kit_event(pid)
      return character_event(pid)
    end
  end
  notice(pid, "You don't have a passive called '" .. (args[2] or '') .. "'.")
end))

-- Forgets every talent and ancestry passive, at a trainer, for coins.
redis.register_function('respec', action(function(pid, rid, args)
  local trainer
  for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
    if redis.call('HGET', 'NPC:' .. nid, 'trainer') == '1' then trainer = nid end
  end
  if not trainer then return notice(pid, 'You need a trainer for that. Sergeant Holt, in the Harrowgate training yard, will do it.') end
  if mid_fight(pid) then return end
  local cost = rule('respec_coins_per_level', 10) * level_of(pid)
  if coins_of(pid) < cost then return notice(pid, 'It costs ' .. cost .. ' coins, and you have ' .. coins_of(pid) .. '.') end
  redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', -cost)
  for _, gid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':talents')) do
    redis.call('SREM', 'PLAYER:' .. pid .. ':gear', gid)
    for n, slotted in pairs(hgetall('PLAYER:' .. pid .. ':slots')) do
      if slotted == gid then redis.call('HDEL', 'PLAYER:' .. pid .. ':slots', n) end
    end
  end
  for _, perk in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':passives')) do
    redis.call('SREM', 'PLAYER:' .. pid .. ':perks', perk)
  end
  redis.call('DEL', 'PLAYER:' .. pid .. ':talents', 'PLAYER:' .. pid .. ':passives', 'PLAYER:' .. pid .. ':attuned')
  notice(pid, capitalize(npc_display(trainer)) .. ' takes ' .. cost .. ' coins. "Right. From the beginning." Your talents and passives are yours to choose again.')
  kit_event(pid)
  character_event(pid)
end))

end

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
    if not can_see(w, pid) then lines[#lines + 1] = 'You can barely see past the ' .. obscured_by(w) .. '.' end
    local units = forecast_units(pid, w.realm)
    if units then
      local now, unit = weather_time(), rule('weather_unit_minutes', 30)
      for i = 1, units do
        lines[#lines + 1] = '  In ' .. duration(i * unit) .. ': ' .. describe_weather(weather_in(place, now + i)) .. '.'
      end
    else
      lines[#lines + 1] = "You can feel the weather, but you can't read these skies. Someone who knows them could teach you: DISCUSS WEATHER."
    end
  end
  emit('PLAYER:' .. pid, {type = 'weather_report', text = table.concat(lines, '\n')})
  weather_event(pid)
  kit_event(pid)
end))

-- Talk (docs/talk-and-layout.md) -----------------------------------------------
-- DISCUSS <topic> talks with your target. An NPC's topics are listed (on its
-- card, and by DISCUSS alone) only when they'd discuss them with you: a
-- topic's `requires` (rapport, level, faction reputation, a quest), `while`
-- (only during a quest, or one step of it) and `heard_from` (only once you've
-- discussed it with one of those people). Every NPC who talks also has the
-- standard topics: quests, wants (if they buy anything) and rumours.
--
-- PLAYER:<id>:rapport (NPC id -> number) is how well each NPC knows you;
-- PLAYER:<id>:met the NPCs you've spoken with; PLAYER:<id>:discussed each
-- "npc|topic" you've talked over; PLAYER:<id>:offer the quest someone is
-- waiting for an answer on; PLAYER:<id>:declined (quest -> NPC) offers turned
-- down, to be had again by DISCUSS QUESTS. (A function, not a do-block: it
-- needs more locals than the main chunk has left.)
;(function()
  -- From the quests block.
  local quest_def, quest_status, trigger_matches = hooks.quest_def, hooks.quest_status, hooks.trigger_matches
  local STANDARD = {work = 'quests', jobs = 'quests', job = 'quests', help = 'quests', quest = 'quests',
    buy = 'wants', want = 'wants', selling = 'wants', yourself = 'background', family = 'background', life = 'background',
    news = 'rumours', gossip = 'rumours', rumour = 'rumours', rumor = 'rumours', rumors = 'rumours',
    history = 'place', here = 'place', area = 'place'}
  local PASSAGE_WORDS = {passage = true, portal = true, travel = true, way = true, crossing = true, ferry = true, coach = true}
  local RAPPORT = {{7, 'trusted'}, {3, 'friendly'}, {1, 'known'}, {0, 'stranger'}}
  local DIRS8 = {'east', 'northeast', 'north', 'northwest', 'west', 'southwest', 'south', 'southeast'}

  local function say(pid, nid, text) hooks.npc_says(pid, nid, text) end
  local function guide(pid, text) emit('PLAYER:' .. pid, {type = 'guide', text = text}) end

  local function rapport(pid, nid)
    return tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':rapport', nid)) or 0
  end

  local function rapport_word(pid, nid)
    local n = rapport(pid, nid)
    for _, r in ipairs(RAPPORT) do if n >= r[1] then return r[2] end end
    return 'stranger'
  end

  -- Whether an NPC talks at all: people do; wolves and rats don't.
  local function speaks(npc)
    return next(decode(npc.topics)) ~= nil or npc.proper == '1' or npc.disposition == 'friendly'
  end

  -- Changes how well an NPC knows a player (never below 0); the card and its
  -- topics follow.
  hooks.add_rapport = function(pid, nid, n)
    local before = rapport_word(pid, nid)
    redis.call('HSET', 'PLAYER:' .. pid .. ':rapport', nid, math.max(0, rapport(pid, nid) + n))
    local now = rapport_word(pid, nid)
    if now ~= before and now ~= 'known' then -- meeting someone isn't news; being liked is
      guide(pid, capitalize(npc_display(nid)) .. (n > 0 and ' knows you better now: ' or ' thinks less of you now: ') .. now .. '.')
    end
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    if rid and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then dispositions_event(pid, rid) end
  end

  -- Whether a player meets a `requires`: rapport, level, faction reputation
  -- (the NPC's faction unless it names one), and a quest (done, unless `status` says).
  local function meets(pid, nid, req)
    if type(req) ~= 'table' then return true end
    if req.rapport and rapport(pid, nid) < req.rapport then return false end
    if req.level and level_of(pid) < req.level then return false end
    if req.affinity or req.respect then
      local rep = hgetall('PLAYER:' .. pid .. ':rep:' .. (req.faction or redis.call('HGET', 'NPC:' .. nid, 'faction') or ''))
      if req.affinity and (tonumber(rep.affinity) or 0) < req.affinity then return false end
      if req.respect and (tonumber(rep.respect) or 0) < req.respect then return false end
    end
    if req.quest and quest_status(pid, req.quest) ~= (req.status or 'done') then return false end
    for _, q in ipairs(req.quests or {}) do
      if quest_status(pid, q) ~= 'done' then return false end
    end
    return true
  end

  -- Whether an NPC would discuss a topic with this player now.
  local function open(pid, nid, name, topic)
    if type(topic) ~= 'table' then return true end
    if not meets(pid, nid, topic.requires) then return false end
    local w = topic['while']
    if w then
      if quest_status(pid, w.quest) ~= 'active' then return false end
      if w.step and redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. w.quest, 'step') ~= w.step then return false end
    end
    if topic.heard_from then
      for _, h in ipairs(topic.heard_from) do
        if redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':discussed', h .. '|' .. name) == 1 then return true end
      end
      return false
    end
    return true
  end

  -- A quest an NPC could offer a player now, and how: one they're waiting on
  -- an answer to, one the player turned down, or a topic that starts one.
  local function work_for(pid, nid)
    local offer = hgetall('PLAYER:' .. pid .. ':offer')
    if offer.npc == nid then return offer.quest end
    for qid, from in pairs(hgetall('PLAYER:' .. pid .. ':declined')) do
      if from == nid then return qid end
    end
    for name, topic in pairs(decode(redis.call('HGET', 'NPC:' .. nid, 'topics'))) do
      if type(topic) == 'table' and topic.starts and not quest_status(pid, topic.starts) and open(pid, nid, name, topic) then
        return topic.starts
      end
    end
  end

  local function wants_of(pid, nid)
    local raw = redis.call('HGET', 'NPC:' .. nid, 'wants') or ''
    if raw == '' then return nil end
    local wants = decode(raw)
    if not meets(pid, nid, wants.requires) then return nil end
    return wants
  end

  -- What an NPC will discuss with a player, sorted, or nil if they won't talk.
  hooks.topics_for = function(pid, nid)
    local npc = hgetall('NPC:' .. nid)
    if not speaks(npc) or disposition_for(pid, nid) == 'hostile' then return nil end
    local out, has = {}, {}
    for name, topic in pairs(decode(npc.topics)) do
      if open(pid, nid, name, topic) then out[#out + 1], has[name] = name, true end
    end
    for _, name in ipairs({'quests', 'rumours'}) do
      if not has[name] then out[#out + 1] = name end
    end
    if not has.wants and wants_of(pid, nid) then out[#out + 1] = 'wants' end
    if not has.weather and #decode(npc.forecasts) > 0 then out[#out + 1] = 'weather' end
    return list(sorted(out))
  end

  hooks.talk_card = function(pid, nid)
    local topics = hooks.topics_for(pid, nid)
    return {topics = topics, rapport = topics and rapport_word(pid, nid) or nil}
  end

  -- Waits for the player's answer to an offered quest.
  hooks.pend = function(pid, qid, nid)
    redis.call('DEL', 'PLAYER:' .. pid .. ':offer')
    redis.call('HSET', 'PLAYER:' .. pid .. ':offer', 'quest', qid, 'npc', nid)
    redis.call('HDEL', 'PLAYER:' .. pid .. ':declined', qid)
    guide(pid, quest_def(qid).must and 'Type ACCEPT to take this on.' or 'Type ACCEPT to take this on, or DECLINE.')
  end

  local function offer_text(qid, nid)
    local def = quest_def(qid)
    if def.offer then return def.offer end
    for _, topic in pairs(decode(redis.call('HGET', 'NPC:' .. nid, 'topics'))) do
      if type(topic) == 'table' and topic.starts == qid then return topic.text end
    end
    return 'I have work for you, if you want it.'
  end

  local function current_goal(pid, qid)
    local def = quest_def(qid)
    local step = (def.steps or {})[redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. qid, 'step') or ''] or {}
    return (def.name or qid) .. ': ' .. (step.goal or '')
  end

  local function discuss_quests(pid, nid)
    local qid = work_for(pid, nid)
    if qid then
      say(pid, nid, offer_text(qid, nid))
      return hooks.pend(pid, qid, nid)
    end
    -- Already on a job of theirs: a reminder.
    for q, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
      if status == 'active' and redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. q, 'giver') == nid then
        say(pid, nid, "You know what I need. Get on with it.")
        return guide(pid, current_goal(pid, q))
      end
    end
    say(pid, nid, disposition_for(pid, nid) == 'friendly' and 'Nothing for you right now.' or 'Nothing for you.')
  end

  -- Which way, and how far: a compass point from the map, and a word from the walk.
  local function whereabouts(from, to, steps)
    local a, b = hgetall('ROOM:' .. from .. ':info'), hgetall('ROOM:' .. to .. ':info')
    local dx, dy = (tonumber(b.x) or 0) - (tonumber(a.x) or 0), (tonumber(b.y) or 0) - (tonumber(a.y) or 0)
    if dx == 0 and dy == 0 then return steps <= 3 and 'close by' or 'somewhere near' end -- straight up or down
    local angle = math.atan2(-dy, dx) -- the map's y runs south
    local dir = 'to the ' .. DIRS8[math.floor(angle / (2 * math.pi) * 8 + 0.5) % 8 + 1]
    if steps <= 3 then return 'close by, ' .. dir end
    if steps <= 8 then return 'off ' .. dir end
    return 'far off ' .. dir
  end

  -- Quest givers with a lure (`sense` and `rumour` forms) within `max` steps,
  -- with work for this player: {nid, room, steps}.
  local function givers_near(pid, from, max, form)
    local found, seen, frontier = {}, {[from] = true}, {from}
    for steps = 0, max do
      local next_ = {}
      for _, rid in ipairs(frontier) do
        for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
          local lure = decode(redis.call('HGET', 'NPC:' .. nid, 'lure'))
          if lure[form] and work_for(pid, nid) then found[#found + 1] = {nid = nid, room = rid, steps = steps} end
        end
        for _, dest in pairs(hgetall('ROOM:' .. rid .. ':exits')) do
          if not seen[dest] then seen[dest] = true; next_[#next_ + 1] = dest end
        end
      end
      frontier = next_
    end
    return found
  end

  -- A lure, felt: "Far off to the west you see the light of what may be an inn."
  local function lure_text(pid, here, giver)
    local where = whereabouts(here, giver.room, giver.steps)
    local text = decode(redis.call('HGET', 'NPC:' .. giver.nid, 'lure')).sense
    text = string.gsub(text, '{Where}', function() return capitalize(where) end)
    return (string.gsub(text, '{where}', function() return where end))
  end

  local function pick(list_)
    return list_[math.random(#list_)]
  end

  -- Now and then on a step, a nearby quest giver's lure, felt unbidden (each
  -- at most once a day).
  hooks.maybe_lure = function(pid, rid)
    if math.random() >= rule('lure_chance', 0.03) then return end
    local fresh = {}
    for _, g in ipairs(givers_near(pid, rid, rule('whatnow_steps', 15), 'sense')) do
      if g.steps > 0 and redis.call('EXISTS', 'PLAYER:' .. pid .. ':lured:' .. g.nid) == 0 then fresh[#fresh + 1] = g end
    end
    if #fresh == 0 then return end
    local g = pick(fresh)
    redis.call('SET', 'PLAYER:' .. pid .. ':lured:' .. g.nid, '1', 'EX', 86400)
    emit('PLAYER:' .. pid, {type = 'lure', text = lure_text(pid, rid, g)})
  end

  -- What am I meant to be doing? An answer owed, the quest you're on, or the
  -- pull of the nearest quest giver.
  redis.register_function('whatnow', action(function(pid, rid, args)
    local offer = hgetall('PLAYER:' .. pid .. ':offer')
    if offer.quest then
      return guide(pid, capitalize(npc_display(offer.npc)) .. ' is waiting for your answer: '
        .. (quest_def(offer.quest).must and 'go back and ACCEPT.' or 'go back and ACCEPT or DECLINE.'))
    end
    local best, since
    for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
      local at = tonumber(redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. qid, 'since')) or 0
      if status == 'active' and (quest_def(qid).priority and 1e15 or at) > (since or -1) then
        best, since = qid, quest_def(qid).priority and 1e15 or at
      end
    end
    if best then return guide(pid, current_goal(pid, best)) end
    local givers = givers_near(pid, rid, rule('whatnow_steps', 15), 'sense')
    if #givers == 0 then return emit('PLAYER:' .. pid, {type = 'lure', text = 'Nothing calls to you here. Towns are where work is found.'}) end
    local nearest = givers[1].steps
    local near = {}
    for _, g in ipairs(givers) do if g.steps <= nearest + 1 then near[#near + 1] = g end end
    local g = pick(near)
    if g.steps == 0 then return guide(pid, capitalize(npc_display(g.nid)) .. ' is right here, and might have work for you: GREET them.') end
    emit('PLAYER:' .. pid, {type = 'lure', text = lure_text(pid, rid, g)})
  end))

  -- Rumours: their own, or word of a quest giver nearby.
  local function rumour(pid, rid, nid)
    local heard = {}
    for _, g in ipairs(givers_near(pid, rid, rule('whatnow_steps', 15), 'rumour')) do
      if g.nid ~= nid then heard[#heard + 1] = g end
    end
    if #heard == 0 then return say(pid, nid, "Heard nothing worth repeating.") end
    say(pid, nid, decode(redis.call('HGET', 'NPC:' .. pick(heard).nid, 'lure')).rumour)
  end

  local function deflect(pid, nid)
    return disposition_for(pid, nid) == 'friendly' and "Can't help you with that, I'm afraid." or "Couldn't say."
  end

  -- The weather: an NPC who reads the sky teaches you to.
  local function teach_skies(pid, nid, who, said)
    local realms = decode(redis.call('HGET', 'NPC:' .. nid, 'forecasts'))
    if #realms == 0 then
      if not said then say(pid, nid, "Can't say I read the sky.") end
      return
    end
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
  end

  -- With no one named or targeted: the only person here who talks.
  local function only_speaker(pid, rid)
    local only
    for _, nid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. rid .. ':npcs')) do
      if hooks.topics_for(pid, nid) then
        if only then return nil end
        only = nid
      end
    end
    return only
  end

  -- The NPC a player means, and its name; or nil, having told them why not.
  -- (Not `return notice(...)`: that returns the notice's number, which a
  -- caller would take for an NPC.)
  local function whom(pid, rid, word)
    local refusal
    if (word or '') == '' then
      local nid = only_speaker(pid, rid)
      if nid then return nid, npc_display(nid) end
      refusal = 'With whom? Press Tab, or click someone.'
    else
      local kind, nid, display = resolve(pid, rid, word)
      if kind == 'npc' then return nid, display end
      refusal = kind and 'Only the locals can help you with that.' or "You don't see them here."
    end
    notice(pid, refusal)
    return nil
  end

  -- args: pid, who ('' for the only person here), topic ('' to list them).
  local function discuss(pid, rid, args)
    local nid, display = whom(pid, rid, args[2])
    if not nid then return end
    local who = capitalize(display)
    local topics = hooks.topics_for(pid, nid)
    if not topics then return notice(pid, who .. ' has nothing to say to you.') end
    local word = string.gsub(string.lower(args[3] or ''), '^the ', '')
    if word == '' then
      return emit('PLAYER:' .. pid, {type = 'topics', npc = 'npc:' .. nid, topics = topics,
        text = who .. ' will discuss: ' .. table.concat(topics, ', ') .. '. (DISCUSS <topic>)'})
    end
    local all = decode(redis.call('HGET', 'NPC:' .. nid, 'topics'))
    local name = all[word] and word or STANDARD[word] or word
    emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'ask', target = 'npc:' .. nid,
      text = name_of(pid) .. ' talks with ' .. display .. ' about ' .. (name == 'quests' and 'work' or word) .. '.'})
    redis.call('SADD', 'PLAYER:' .. pid .. ':met', nid)
    local topic = all[name]
    if topic and not open(pid, nid, name, topic) then topic = nil end
    if not topic and PASSAGE_WORDS[word] then return ask_routes(pid, rid, nid, who) end
    if topic then
      local again = redis.call('SADD', 'PLAYER:' .. pid .. ':discussed', nid .. '|' .. name) == 0
      local t = type(topic) == 'table' and topic or {text = topic}
      say(pid, nid, again and t.again or t.text)
      if t.explains then guide(pid, t.explains) end
      if t.rapport and not again then hooks.add_rapport(pid, nid, t.rapport) end
      if t.starts and not quest_status(pid, t.starts) then hooks.pend(pid, t.starts, nid) end
    elseif name == 'quests' then
      discuss_quests(pid, nid)
    elseif name == 'wants' and wants_of(pid, nid) then
      say(pid, nid, wants_of(pid, nid).says or "I'm buying, if you've the right things.")
    elseif name == 'rumours' then
      rumour(pid, rid, nid)
    elseif name ~= 'weather' then
      return say(pid, nid, deflect(pid, nid))
    end
    if name == 'weather' then teach_skies(pid, nid, who, topic ~= nil) end
    hooks.quest(pid, 'ask', {npc = nid, topic = name})
  end
  redis.register_function('discuss', action(function(pid, rid, args) discuss(pid, rid, args) end))

  -- GREET: they answer as someone who's met you or hasn't, and say if they've
  -- work for you. Daily, a little rapport.
  redis.register_function('greet', action(function(pid, rid, args)
    local nid, display = whom(pid, rid, args[2])
    if not nid then return end
    local who = capitalize(display)
    emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'greet', target = 'npc:' .. nid, text = name_of(pid) .. ' greets ' .. display .. '.'})
    if redis.call('SET', 'PLAYER:' .. pid .. ':social:' .. nid, '1', 'NX', 'EX', rule('social_cooldown', 600)) then deed(pid, 'greet', nid) end
    local npc = hgetall('NPC:' .. nid)
    if not speaks(npc) then return end
    local friendly = disposition_for(pid, nid) == 'friendly'
    if disposition_for(pid, nid) == 'hostile' then return notice(pid, who .. ' only glares at you.') end
    local first = redis.call('SADD', 'PLAYER:' .. pid .. ':met', nid) == 1
    local g, word = decode(npc.greet), rapport_word(pid, nid)
    local line
    if first then
      line = g.first or (npc.proper == '1' and (npc.name .. '. ' .. (friendly and 'Good to meet you.' or 'What do you want?'))
        or (friendly and 'Hello, stranger.' or 'What do you want?'))
    else
      line = (word == 'trusted' and g.trusted) or ((word == 'trusted' or word == 'friendly') and g.friendly) or g.again
        or (friendly and 'Good to see you again.' or 'You again.')
    end
    say(pid, nid, line)
    if redis.call('SET', 'PLAYER:' .. pid .. ':greeted:' .. nid, '1', 'NX', 'EX', 86400) then hooks.add_rapport(pid, nid, 1) end
    if work_for(pid, nid) then
      say(pid, nid, g.work or 'I might have work for you, if you want it.')
      guide(pid, 'DISCUSS QUESTS to hear it.')
    elseif wants_of(pid, nid) then
      say(pid, nid, g.wants or "I'm buying, if you've anything worth selling.")
      guide(pid, 'DISCUSS WANTS to hear what.')
    end
  end))

  redis.register_function('accept', action(function(pid, rid, args)
    local offer = hgetall('PLAYER:' .. pid .. ':offer')
    if not offer.quest then return notice(pid, "Nobody's waiting on an answer from you.") end
    if redis.call('SISMEMBER', 'ROOM:' .. rid .. ':npcs', offer.npc) == 0 then
      return notice(pid, capitalize(npc_display(offer.npc)) .. ' is waiting for your answer. Go back to them to ACCEPT.')
    end
    redis.call('DEL', 'PLAYER:' .. pid .. ':offer')
    local def = quest_def(offer.quest)
    say(pid, offer.npc, def.accepted or 'Good.')
    if hooks.start_quest(pid, offer.quest) then
      redis.call('HSET', 'PLAYER:' .. pid .. ':quest:' .. offer.quest, 'giver', offer.npc)
    end
  end))

  redis.register_function('decline', action(function(pid, rid, args)
    local offer = hgetall('PLAYER:' .. pid .. ':offer')
    if not offer.quest then return notice(pid, "Nobody's waiting on an answer from you.") end
    local def = quest_def(offer.quest)
    if def.must then return notice(pid, "This one isn't one to turn down: type ACCEPT.") end
    redis.call('DEL', 'PLAYER:' .. pid .. ':offer')
    redis.call('HSET', 'PLAYER:' .. pid .. ':declined', offer.quest, offer.npc)
    say(pid, offer.npc, def.declined or 'Suit yourself. You know where to find me.')
  end))

  -- Giving: to a quest that wants it handed over, to someone buying it, or as
  -- a gift someone likes (one a day each). Anything else, they won't take.
  local function tagged(iid, tag)
    for _, t in ipairs(decode(redis.call('HGET', 'ITEM:' .. iid, 'tags'))) do if t == tag then return true end end
    return false
  end

  local function matches(entry, iid)
    if type(entry) == 'string' then return entry == iid or tagged(iid, entry) end
    return entry.item == iid or (entry.tag ~= nil and tagged(iid, entry.tag))
  end

  hooks.give_to = function(pid, rid, iid, nid, display)
    local item_name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid
    local who = capitalize(display)
    local function handed(verb)
      redis.call('SREM', 'PLAYER:' .. pid .. ':inv', iid)
      emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'give', target = 'npc:' .. nid,
        text = name_of(pid) .. ' ' .. verb .. ' the ' .. item_name .. ' to ' .. display .. '.'})
      kit_event(pid)
    end
    -- A quest that wants it handed over (the quest's effects take it).
    for qid, status in pairs(hgetall('PLAYER:' .. pid .. ':quests')) do
      local def = quest_def(qid)
      local step = status == 'active' and (def.steps or {})[redis.call('HGET', 'PLAYER:' .. pid .. ':quest:' .. qid, 'step') or '']
      if step and trigger_matches(pid, step.on or {}, 'give', {item = iid, npc = nid}) then
        emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'give', target = 'npc:' .. nid,
          text = name_of(pid) .. ' gives the ' .. item_name .. ' to ' .. display .. '.'})
        return hooks.quest(pid, 'give', {item = iid, npc = nid})
      end
    end
    redis.call('SADD', 'PLAYER:' .. pid .. ':met', nid)
    -- Someone buying it.
    local wants = wants_of(pid, nid)
    for i, want in ipairs(wants and wants.items or {}) do
      if matches(want, iid) then
        local sold = 'PLAYER:' .. pid .. ':sold:' .. nid .. ':' .. i
        if want.cap and (tonumber(redis.call('GET', sold)) or 0) >= want.cap then
          return say(pid, nid, "That's all of those I need today.")
        end
        redis.call('INCR', sold)
        if redis.call('TTL', sold) < 0 then redis.call('EXPIRE', sold, 86400) end
        -- Haggling: a little more for every point of Presence, and for a Haggler.
        local price = math.floor((want.price or 1) * (1 + 0.05 * stat(pid, 'presence') + (has_perk(pid, 'haggler') and 0.1 or 0)) + 0.5)
        handed('sells')
        redis.call('HINCRBY', 'ACCOUNT:' .. pid, 'coins', price)
        say(pid, nid, want.thanks or 'Done.')
        notice(pid, 'You sell the ' .. item_name .. ' for ' .. price .. (price == 1 and ' coin.' or ' coins.'))
        kit_event(pid)
        if redis.call('SET', 'PLAYER:' .. pid .. ':sold_rapport:' .. nid, '1', 'NX', 'EX', 86400) then hooks.add_rapport(pid, nid, 1) end
        return
      end
    end
    -- A gift they'd like.
    for _, like in ipairs(decode(redis.call('HGET', 'NPC:' .. nid, 'likes'))) do
      if matches(like, iid) then
        if not redis.call('SET', 'PLAYER:' .. pid .. ':gift:' .. nid, '1', 'NX', 'EX', rule('gift_cooldown', 86400)) then
          return say(pid, nid, "You've given me plenty already. Keep it.")
        end
        handed('gives')
        local thanks = redis.call('HGET', 'NPC:' .. nid, 'thanks') or ''
        say(pid, nid, thanks ~= '' and thanks or 'For me? Thank you.')
        return hooks.add_rapport(pid, nid, 2)
      end
    end
    local refuse = redis.call('HGET', 'NPC:' .. nid, 'refuse') or ''
    if refuse ~= '' then say(pid, nid, refuse) end
    notice(pid, 'You offer the ' .. item_name .. ' to ' .. display .. ", but they won't take it.")
  end

  -- args: pid, item word, who ('' for your target, given by the command, or the only person here).
  redis.register_function('give', action(function(pid, rid, args)
    local iid = match_item('PLAYER:' .. pid .. ':inv', args[2] or '')
    if not iid then return notice(pid, "You aren't carrying that.") end
    local nid, display = whom(pid, rid, args[3])
    if not nid then return end
    hooks.give_to(pid, rid, iid, nid, display)
  end))

  -- Reading a trap's sign: you know it's there, and how to get past.
  hooks.read_sign = function(pid, rid, trapped)
    traps.know_trap(pid, trapped)
    local dir
    for d, dest in pairs(hgetall('ROOM:' .. rid .. ':exits')) do if dest == trapped then dir = string.upper(d) end end
    if not dir then return end
    local trap = decode(redis.call('GET', 'ROOM:' .. trapped .. ':trap'))
    guide(pid, 'Something is set ' .. string.lower(dir) .. ': ' .. (trap.name or 'a trap') .. '. CREEP ' .. dir
      .. ' to get past it safely: slow, but sure, and it stays set behind you. Or DISARM ' .. dir .. ': a '
      .. capitalize(trap.disarm or trap.stat or 'poise') .. ' check, and failing springs it on you.')
  end

  -- args: pid, direction.
  redis.register_function('disarm', action(function(pid, rid, args)
    local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', args[2] or '')
    local trap = dest and decode(redis.call('GET', 'ROOM:' .. dest .. ':trap')) or {}
    if not trap.name or redis.call('EXISTS', 'ROOM:' .. dest .. ':trap_sprung') == 1
      or redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':traps', dest) == 0 then
      return notice(pid, "You don't know of anything to disarm that way. LOOK around first.")
    end
    emit('ROOM:' .. rid, {type = 'emote', actor = pid, verb = 'disarm', text = name_of(pid) .. ' crouches and works at something to the ' .. args[2] .. '.'})
    if passes(pid, trap.disarm or trap.stat or 'poise', trap.difficulty, has_perk(pid, 'trapsense') and 0.25 or 0) then
      redis.call('SET', 'ROOM:' .. dest .. ':trap_sprung', '1', 'PX', math.floor((trap.rearm or 120) * 1000))
      return notice(pid, 'You disarm ' .. trap.name .. '. It will be a while before anyone sets it again. ('
        .. capitalize(trap.disarm or trap.stat or 'poise') .. ' check)')
    end
    notice(pid, 'Your hand slips. (' .. capitalize(trap.disarm or trap.stat or 'poise') .. ' check)')
    traps.spring_trap(pid, dest, false, true)
  end))
end)()

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
      local fare, stages = fare_for(pid, route), #decode(route.path)
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

-- Admin: jumps to any room that isn't a waypoint.
redis.register_function('goto', action(function(pid, rid, args)
  local dest = args[2]
  if redis.call('EXISTS', 'ROOM:' .. dest .. ':info') == 0 or is_waypoint(dest) then
    return notice(pid, 'There is no room ' .. dest .. '.')
  end
  redis.call('DEL', 'PLAYER:' .. pid .. ':journey')
  redis.call('ZREM', 'alz:journeys', pid)
  teleport(pid, dest, '{actor} vanishes.', '{actor} appears.')
end))

-- Admin: pins the clock at an hour (0-23), or with 'clear' lets it run.
redis.register_function('set_clock', action(function(pid, rid, args)
  if args[2] == 'clear' then
    redis.call('DEL', 'alz:clock_override')
  else
    local hour = tonumber(args[2])
    -- (hour ~= hour: NaN, which no comparison catches, and which JSON can't carry.)
    if not hour or hour ~= hour or hour < 0 or hour > 23 then return notice(pid, 'Usage: SETCLOCK <hour 0-23>, or SETCLOCK CLEAR.') end
    redis.call('SET', 'alz:clock_override', math.floor(hour))
  end
  local c = clock(realm_of(rid))
  notice(pid, (args[2] == 'clear' and 'The clock runs again: ' or 'The clock is pinned: ') .. c.hour .. ':00, ' .. c.phase .. '.')
  room_event(pid, rid, 'look')
  weather_event(pid)
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
  if not joined(pid, ch) then return notice(pid, "You aren't in #" .. ch .. '. Try JOIN ' .. string.upper(ch) .. '.') end
  emit('CHANNEL:' .. ch, {type = 'chat', actor = pid, target = ch, message = message, text = '[' .. ch .. '] ' .. name_of(pid) .. ': ' .. message})
end))

redis.register_function('create_channel', action(function(pid, rid, args)
  local ch = args[2]
  if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 1 then
    return notice(pid, '#' .. ch .. ' already exists. Try JOIN ' .. string.upper(ch) .. '.')
  end
  -- A few each, or one player could fill everyone's CHANNELS list.
  local owned = 'PLAYER:' .. pid .. ':channels'
  for _, mine in ipairs(redis.call('SMEMBERS', owned)) do
    if redis.call('EXISTS', 'CHANNEL:' .. mine .. ':info') == 0 then redis.call('SREM', owned, mine) end
  end
  local most = rule('channels_per_player', 3)
  if redis.call('SCARD', owned) >= most then
    return notice(pid, 'You can make at most ' .. most .. ' channels.')
  end
  redis.call('HSET', 'CHANNEL:' .. ch .. ':info', 'owner', pid, 'created', math.floor(now_ms() / 1000))
  redis.call('SADD', 'alz:channels', ch)
  redis.call('SADD', owned, ch)
  join(pid, ch)
end))

redis.register_function('join', action(function(pid, rid, args)
  local ch = args[2]
  if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 0 then
    return notice(pid, 'There is no #' .. ch .. '. You can make it with CREATE ' .. string.upper(ch) .. '.')
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
-- Shows a rider where their journey had got to, and sets it going again.
local function resume_journey(pid)
  local key = 'PLAYER:' .. pid .. ':journey'
  local journey = hgetall(key)
  if journey.marooned then return end -- held while they're stuck ashore
  local route = hgetall('ROUTE:' .. (journey.route or ''))
  if not route.to then return lose_journey(pid) end
  local path = decode(route.path)
  local n = tonumber(journey.stage) or 1
  local info = hgetall('ROOM:' .. (path[n] or '') .. ':info')
  emit('PLAYER:' .. pid, {type = 'journey', route = journey.route, kind = route.kind, stage = n, stages = #path,
    at = path[n], pos = info.x and room_pos(info) or nil, name = info.name, text = info.description, resumed = true})
  if journey.event then
    hooks.show_event(pid)
    redis.call('ZADD', 'alz:journeys', tonumber(journey.event_until) or now_ms(), pid)
  else
    journey_next(pid)
  end
end

redis.register_function('connect', function(keys, args)
  CALLER.server = keys and keys[1] or ''
  local pid, session, since = args[1], args[2], tonumber(args[3]) or 0
  local session_key = 'PLAYER:' .. pid .. ':session'
  local previous = redis.call('GET', session_key)
  redis.call('SET', session_key, session)
  redis.call('ZADD', 'alz:online', now_ms(), pid)
  redis.call('PERSIST', 'PLAYER:' .. pid) -- their stream: kept while they're in the world (see disconnect)
  local card = player_card(pid)
  if card.hp < card.max_hp then redis.call('SADD', 'alz:wounded', pid) end -- healing picks up again

  if previous then
    -- Already in the world (another tab, or reconnecting after a dropped
    -- connection): end the old connection and carry on where it left off.
    emit('PLAYER:' .. pid, {type = 'control', op = 'kick', session = previous, reason = 'You connected from somewhere else.'})
    local current = current_seq()
    local cursor = (since > 0 and since < current) and since or current
    -- A stream keeps only its last MAXLEN events: if one the player reads has
    -- been trimmed and what it still has starts after `since` (and after they
    -- joined it), the replay may have a hole in it. Start from now (the
    -- resume sends the state of everything anyway), and say so.
    local lost = false
    if cursor < current then
      local subs = hgetall('PLAYER:' .. pid .. ':subs')
      subs['PLAYER:' .. pid] = subs['PLAYER:' .. pid] or '0'
      for ch, joined in pairs(subs) do
        if not lost and redis.call('EXISTS', ch) == 1 then
          local info = {}
          local flat = redis.call('XINFO', 'STREAM', ch)
          for i = 1, #flat, 2 do info[flat[i]] = flat[i + 1] end
          local first = type(info['first-entry']) == 'table' and tonumber(string.match(info['first-entry'][1], '^(%d+)')) or 0
          if (tonumber(info['entries-added']) or 0) > (tonumber(info['length']) or 0)
            and first > math.max(cursor, tonumber(joined) or 0) + 1 then
            lost = true
          end
        end
      end
      if lost then cursor = current end
    end
    local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
    explore(pid, rid)
    backfill_regions(pid)
    visit_realm(pid, rid)
    local visible = can_see(weather_at(rid), pid)
    if visible then glimpse(pid, rid) end
    explore_region(pid, region_of(rid), visible)
    reveal_by_reputation(pid)
    full_map_event(pid)
    weather_event(pid)
    ensure_kit(pid)
    enc.resend(pid)
    kit_event(pid)
    character_event(pid)
    hooks.quests_event(pid)
    room_event(pid, rid, 'resume')
    if lost then notice(pid, 'Some of what happened while you were away is lost.') end
    if redis.call('EXISTS', 'PLAYER:' .. pid .. ':journey') == 1 then resume_journey(pid) end
    return cursor
  end

  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not rid or redis.call('EXISTS', 'ROOM:' .. rid .. ':info') == 0 then
    rid = redis.call('GET', 'alz:start_room')
  end
  redis.call('SET', 'PLAYER:' .. pid .. ':room', rid)
  local slept_here = redis.call('ZREM', 'alz:sleepers', pid) == 1 and redis.call('SISMEMBER', 'ROOM:' .. rid .. ':players', pid) == 1
  redis.call('HDEL', 'ACCOUNT:' .. pid, 'asleep')
  if is_waypoint(rid) and redis.call('HGET', 'PLAYER:' .. pid .. ':journey', 'ambush') == nil then
    -- Aboard: nobody else sees a rider.
  elseif slept_here then
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
  local visible = can_see(weather_at(rid), pid)
  if visible then glimpse(pid, rid) end
  explore_region(pid, region_of(rid), visible)
  reveal_by_reputation(pid)
  full_map_event(pid)
  weather_event(pid)
  ensure_kit(pid)
  kit_event(pid)
  character_event(pid)
  hooks.quests_event(pid)
  room_event(pid, rid, 'enter')
  enc.resend(pid) -- woken mid-fight: it went on without them
  -- A new character's first moments: the story so far, and their first quest.
  if redis.call('HGET', 'ACCOUNT:' .. pid, 'intro') == '1' then
    redis.call('HDEL', 'ACCOUNT:' .. pid, 'intro')
    local background = decode(redis.call('HGET', 'alz:backgrounds', redis.call('HGET', 'ACCOUNT:' .. pid, 'background') or '-'))
    if background.intro then emit('PLAYER:' .. pid, {type = 'intro', text = background.intro}) end
    if background.quest then hooks.start_quest(pid, background.quest) end
  end
  -- Back aboard: the journey carries on from where it was.
  if redis.call('EXISTS', 'PLAYER:' .. pid .. ':journey') == 1 then resume_journey(pid) end
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
  -- open they lie down to sleep, and their body stays for sleep_seconds.
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  -- Leaving mid-fight is no escape: the body lies down where it is, even
  -- somewhere safe, and stays in the fight, taking its blows, until it fades
  -- (or falls, and wakes at the shrine). Back in time, they wake in the fight.
  local fighting = enc.of_player(pid)
  if rid and is_safe(pid, rid) and not fighting then
    redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
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
  redis.call('SREM', 'alz:wounded', pid) -- no healing while away; connect puts them back
  -- Their own stream is only read while they're in the world (a new login
  -- starts from now), so it goes once the server has read the kick.
  redis.call('PEXPIRE', 'PLAYER:' .. pid, 600000)
  redis.call('DEL', 'PLAYER:' .. pid .. ':kit_sum')
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
      'home', realm.home and '1' or '0', 'weather', cjson.encode(realm.weather or {}), 'sky', realm.sky or '',
      'starting', realm.starting and '1' or '0', 'shrine', realm.shrine or '',
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
  -- A coach or ferry joins the regions at its ends as surely as a road does.
  for _, route in pairs(world.routes or {}) do
    if (route.kind == 'coach' or route.kind == 'ferry') and not route.hidden then
      border(world.areas[world.rooms[route.from].area].region, world.areas[world.rooms[route.to].area].region)
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
      'climate', area.climate and cjson.encode(area.climate) or '', 'lit', area.lit and '1' or '0',
      'exposure', area.exposure and cjson.encode(area.exposure) or '')
  end
  local area_box = {}
  for rid, room in pairs(world.rooms) do
    local base = 'ROOM:' .. rid
    local x, y = room.pos[1], room.pos[2]
    redis.call('DEL', base .. ':info', base .. ':exits', base .. ':features', base .. ':flavor', base .. ':routes')
    redis.call('HSET', base .. ':info', 'name', room.name, 'description', room.description, 'area', room.area, 'x', x, 'y', y,
      'safe', room.safe and '1' or '0', 'terrain', room.terrain or '', 'climate', room.climate and cjson.encode(room.climate) or '',
      'indoor', room.indoor and '1' or '0', 'waypoint', room.waypoint and '1' or '0',
      'dark', room.dark and '1' or '0', 'lit', room.lit and '1' or '0', 'shelter', room.shelter and '1' or '0')
    local b = area_box[room.area]
    if room.waypoint then
      -- Waypoints are drawn as part of their route, not inside area boxes.
    elseif b then
      b[1], b[2], b[3], b[4] = math.min(b[1], x), math.min(b[2], y), math.max(b[3], x), math.max(b[4], y)
    else
      area_box[room.area] = {x, y, x, y}
    end
    for dir, dest in pairs(room.exits or {}) do redis.call('HSET', base .. ':exits', dir, dest) end
    for name, text in pairs(room.features or {}) do redis.call('HSET', base .. ':features', name, text) end
    redis.call('DEL', base .. ':trap')
    if room.trap then redis.call('SET', base .. ':trap', cjson.encode(room.trap)) end
    for key, text in pairs(room.flavor or {}) do redis.call('HSET', base .. ':flavor', key, text) end
  end
  -- A trap's sign is a feature of the room next door (after every room's
  -- features are written).
  for _, room in pairs(world.rooms) do
    if room.trap then redis.call('HSET', 'ROOM:' .. room.trap.sign.room .. ':features', room.trap.sign.name, room.trap.sign.text) end
  end
  -- And which trap each sign warns of, so reading it tells you (ROOM:<rid>:signs).
  for rid, room in pairs(world.rooms) do
    if room.trap then redis.call('HSET', 'ROOM:' .. room.trap.sign.room .. ':signs', room.trap.sign.name, rid) end
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
    -- Its health changed in the seed: what it has left keeps its share of the new.
    local old_max = tonumber(redis.call('HGET', key, 'max_hp'))
    local max_hp = npc.max_hp or 10
    if old_max and old_max > 0 and old_max ~= max_hp then
      local hp = tonumber(redis.call('HGET', key, 'hp')) or old_max
      if hp > 0 then redis.call('HSET', key, 'hp', math.max(1, math.min(max_hp, math.floor(hp * max_hp / old_max + 0.5)))) end
    end
    redis.call('HSET', key, 'name', npc.name, 'label', npc.label or '', 'description', npc.description or '',
      'details', npc.details or '', 'keywords', npc.keywords or '', 'max_hp', npc.max_hp or 10,
      'proper', npc.proper and '1' or '0', 'respawn', npc.respawn or 300, 'icon', npc.icon or '',
      'disposition', npc.disposition or 'neutral', 'faction', npc.faction or '', 'role', npc.role or '',
      'attacks', cjson.encode(npc.attacks or {}), 'drops', cjson.encode(npc.drops or {}),
      'xp', npc.xp or math.floor((npc.max_hp or 10) / 2), 'immortal', npc.immortal and '1' or '0',
      'forecasts', cjson.encode(npc.forecasts or {}), 'active_when', npc.active_when and cjson.encode(npc.active_when) or '',
      'hide', npc.hide or '', 'emerge', npc.emerge or '', 'coins', npc.coins or 0,
      'topics', cjson.encode(npc.topics or {}), 'trainer', npc.trainer and '1' or '0', 'notice', npc.notice or '',
      'greet', cjson.encode(npc.greet or {}), 'lure', cjson.encode(npc.lure or {}), 'wants', npc.wants and cjson.encode(npc.wants) or '',
      'likes', cjson.encode(npc.likes or {}), 'loot', cjson.encode(npc.loot or {}), 'refuse', npc.refuse or '',
      'thanks', npc.thanks or '', 'poise', npc.poise or 0)
    if npc.active_when then redis.call('SADD', 'alz:weather_npcs', nid) else redis.call('SREM', 'alz:weather_npcs', nid) end
    if npc.template then
      -- A template for ambushers: copied when an ambush springs, never placed.
      redis.call('HSET', key, 'template', '1')
    elseif new then
      redis.call('HSET', key, 'hp', npc.max_hp or 10, 'room', npc.room, 'home', npc.room)
      redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid)
    else
      -- Moved in the seed: they move in the world too (or come back there, if down).
      local home = redis.call('HGET', key, 'home') or redis.call('HGET', key, 'room')
      if home ~= npc.room then
        local was = redis.call('HGET', key, 'room') or home
        if redis.call('SREM', 'ROOM:' .. was .. ':npcs', nid) == 1 then redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid) end
        redis.call('HSET', key, 'room', npc.room)
      end
      redis.call('HSET', key, 'home', npc.room)
    end
  end
  -- Gear is static: the catalog is rewritten every time. Players' slots keep
  -- what they hold; gear that's gone from the seed acts like an empty slot.
  for _, gid in ipairs(redis.call('SMEMBERS', 'alz:gear')) do redis.call('DEL', 'GEAR:' .. gid) end
  redis.call('DEL', 'alz:gear', 'alz:default_loadout')
  for gid, gear in pairs(world.gear or {}) do
    redis.call('HSET', 'GEAR:' .. gid, 'name', gear.name, 'kind', gear.kind or '', 'keywords', gear.keywords or '',
      'effect', gear.effect, 'targets', gear.targets or 'self',
      'edge', gear.amounts[1], 'clean', gear.amounts[2], 'perfect', gear.amounts[3],
      'hit', gear.hit, 'perfect_hit', gear.perfect_hit,
      'description', gear.description or '', 'weather', gear.weather and cjson.encode(gear.weather) or '',
      'rank', gear.rank or 0, 'requires', gear.requires or '', 'stagger_ms', gear.stagger_ms or 0, 'rarity', gear.rarity or '',
      'bleed', gear.bleed and cjson.encode(gear.bleed) or '',
      'cooldown', gear.cooldown or 0, 'kick', gear.kick or 0, 'pattern', gear.pattern or 'bump', 'hits', gear.hits or 1,
      'gap', gear.gap or 0, 'debuff', gear.debuff and cjson.encode(gear.debuff) or '')
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
  redis.call('DEL', 'alz:kinds', 'alz:terrain_weather', 'alz:terrain_ground')
  for terrain, ground in pairs(world.terrain_ground or {}) do redis.call('HSET', 'alz:terrain_ground', terrain, ground) end
  for kind, profile in pairs(world.kinds or {}) do redis.call('HSET', 'alz:kinds', kind, cjson.encode(profile)) end
  for terrain, nudge in pairs(world.terrain_weather or {}) do redis.call('HSET', 'alz:terrain_weather', terrain, cjson.encode(nudge)) end
  for pid, perk in pairs(world.perks or {}) do
    redis.call('DEL', 'PERK:' .. pid)
    redis.call('HSET', 'PERK:' .. pid, 'name', perk.name, 'description', perk.description or '', 'safe_terrain', perk.safe_terrain or '',
      'slot', perk.slot and '1' or '0')
  end
  -- Classes, ancestries and backgrounds (docs/characters.md).
  redis.call('DEL', 'alz:classes', 'alz:ancestries', 'alz:backgrounds', 'alz:wearables')
  for id, w in pairs(world.wearables or {}) do redis.call('HSET', 'alz:wearables', id, cjson.encode(w)) end
  for id, c in pairs(world.classes or {}) do redis.call('HSET', 'alz:classes', id, cjson.encode(c)) end
  for id, a in pairs(world.ancestries or {}) do redis.call('HSET', 'alz:ancestries', id, cjson.encode(a)) end
  for id, b in pairs(world.backgrounds or {}) do redis.call('HSET', 'alz:backgrounds', id, cjson.encode(b)) end
  redis.call('DEL', 'alz:rules')
  for name, value in pairs(world.rules or {}) do
    if type(value) == 'table' then value = table.concat(value, ',') end -- balance_well_radius: "0.5,0.85"
    if type(value) == 'number' then value = tostring(value) end -- 0.3, not 0.29999999999999999
    redis.call('HSET', 'alz:rules', name, value)
  end
  for iid, item in pairs(world.items or {}) do
    local key = 'ITEM:' .. iid
    local new = redis.call('EXISTS', key) == 0
    redis.call('HSET', key, 'name', item.name, 'keywords', item.keywords or '', 'description', item.description or '',
      'reveals', cjson.encode(item.reveals or {}), 'forecasts', cjson.encode(item.forecasts or {}), 'quest', item.quest and '1' or '0',
      'tags', cjson.encode(item.tags or {}), 'value', item.value or 0)
    if item.quest then
      if item.room then redis.call('SADD', 'ROOM:' .. item.room .. ':qitems', iid) end
    elseif new and item.room then
      redis.call('SADD', 'ROOM:' .. item.room .. ':items', iid)
    end
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
      'by', route.by or '', 'fare', route.fare or 0, 'path', cjson.encode(route.path or {}), 'kind', route.kind or '',
      'strand', route.strand or '', 'risk', route.risk or 0, 'hidden', route.hidden and '1' or '0',
      'quest', route.quest or '', 'step', route.step or '', 'leaves_start', route.leaves_start and '1' or '0',
      'events', cjson.encode(route.events or {}),
      'when', cjson.encode(route.when or {}), 'clear', route.clear and '1' or '0', 'closed', route.closed or '',
      'depart', route.depart or '', 'leave', route.leave or '{actor} is gone.', 'arrive', route.arrive or '{actor} arrives.')
    redis.call('SADD', 'ROOM:' .. route.from .. ':routes', id)
    redis.call('SADD', 'alz:routes', id)
  end
  redis.call('DEL', 'alz:quests')
  for id, quest in pairs(world.quests or {}) do redis.call('HSET', 'alz:quests', id, cjson.encode(quest)) end
  redis.call('DEL', 'alz:travel_events')
  for id, event in pairs(world.travel_events or {}) do redis.call('HSET', 'alz:travel_events', id, cjson.encode(event)) end
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
    if axis == 'time' then
      -- Phases of the day it's about in: {"time": ["dusk", "night"]}.
      local phase, ok = clock(realm_of(npc.room)).phase, false
      for _, p in ipairs(range) do if p == phase then ok = true end end
      if not ok then return false end
    elseif w[axis] and (w[axis] < range[1] or w[axis] > range[2]) then
      return false
    end
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
    if npc.owner then
      redis.call('DEL', 'NPC:' .. nid, 'NPC:' .. nid .. ':encounter') -- an ambusher: gone for good
    elseif npc.room then
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
    elseif here and not active and redis.call('EXISTS', 'NPC:' .. nid .. ':encounter') == 0 then
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
  CALLER.server = keys and keys[1] or ''
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
      kit_event(pid, true)
      hooks.quest(pid, 'check', {}) -- quests waiting on the weather
    end
  end
  return 1
end)

-- The slow upkeep every server runs every few seconds: respawns, sleeping
-- bodies fading, and wounds healing out of a fight (faster somewhere safe).
redis.register_function('upkeep', function(keys, args)
  CALLER.server = keys and keys[1] or ''
  local now = now_ms()
  respawn_due(now)
  for _, pid in ipairs(redis.call('ZRANGEBYSCORE', 'alz:sleepers', '-inf', now)) do
    redis.call('ZREM', 'alz:sleepers', pid)
    fade_out(pid)
  end
  -- NPCs out of a fight heal npc_regen_pct of their health each upkeep.
  for _, nid in ipairs(redis.call('SMEMBERS', 'alz:wounded_npcs')) do
    local npc = hgetall('NPC:' .. nid)
    local hp, max = tonumber(npc.hp) or 0, tonumber(npc.max_hp) or 0
    if hp <= 0 or hp >= max or (npc.room or '') == '' then
      redis.call('SREM', 'alz:wounded_npcs', nid)
    elseif redis.call('EXISTS', 'NPC:' .. nid .. ':encounter') == 0 then
      local healed = math.min(max, hp + math.max(1, math.floor(max * rule('npc_regen_pct', 0.05))))
      redis.call('HSET', 'NPC:' .. nid, 'hp', healed)
      emit('ROOM:' .. npc.room, {type = 'entity', entity = npc_card(nid)})
      if healed >= max then redis.call('SREM', 'alz:wounded_npcs', nid) end
    end
  end
  for _, pid in ipairs(redis.call('SMEMBERS', 'alz:wounded')) do
    -- Only those in the world heal (connect adds them back); the rest leave the set.
    local card = redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 and player_card(pid)
    if not card or card.hp >= card.max_hp then
      redis.call('SREM', 'alz:wounded', pid)
    elseif redis.call('EXISTS', 'PLAYER:' .. pid .. ':encounter') == 0 then
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

-- Moves the world on: held-up moves, journeys and quest offers that are due.
-- Any server may call this, as often as it likes.
redis.register_function('tick', function(keys, args)
  CALLER.server = keys and keys[1] or ''
  local now = now_ms()
  pending_moves_due(now)
  journeys_due(now)
  hooks.offers_due(now)
  return 1
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
