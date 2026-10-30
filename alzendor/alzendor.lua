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
local STATS = {'vigor', 'poise', 'focus', 'presence'}
local STAT_INFO = {
  vigor = 'Vigor: 8 more max health per point.',
  poise = 'Poise: timing windows 15 ms wider per point.',
  focus = 'Focus: perfect windows 10 ms wider per point.',
  presence = 'Presence: your deeds move reputation 15% further per point.',
}
local BASE_HP, VIGOR_HP = 100, 8

local function stat(pid, name)
  return tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'stat:' .. name)) or 0
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

-- Map ---------------------------------------------------------------------------
-- Players see the rooms they have explored, faint outlines of the rooms those
-- lead to, and the boxes of the areas and cities they've been in.

-- Records a visit; true if the room is new to the player.
local function explore(pid, rid)
  return redis.call('SADD', 'PLAYER:' .. pid .. ':explored', rid) == 1
end

local function room_pos(info)
  return list({tonumber(info.x) or 0, tonumber(info.y) or 0})
end

local function box(info)
  return list({tonumber(info.x1) or 0, tonumber(info.y1) or 0, tonumber(info.x2) or 0, tonumber(info.y2) or 0})
end

-- Sends the player map data for the given explored rooms. `full` replaces what
-- the client knows; otherwise it's merged in.
local function map_event(pid, rids, full)
  local rooms, areas, cities = list(), list(), list()
  local seen, seen_area, seen_city = {}, {}, {}
  for _, rid in ipairs(rids) do seen[rid] = true end
  for _, rid in ipairs(rids) do
    local info = hgetall('ROOM:' .. rid .. ':info')
    local exits = hgetall('ROOM:' .. rid .. ':exits')
    rooms[#rooms + 1] = {id = rid, name = info.name, area = info.area, pos = room_pos(info), exits = exits, explored = true}
    for _, dest in pairs(exits) do
      if not seen[dest] and redis.call('SISMEMBER', 'PLAYER:' .. pid .. ':explored', dest) == 0 then
        seen[dest] = true
        local other = hgetall('ROOM:' .. dest .. ':info')
        rooms[#rooms + 1] = {id = dest, area = other.area, pos = room_pos(other), explored = false}
      end
    end
    if info.area and not seen_area[info.area] then
      seen_area[info.area] = true
      local area = hgetall('AREA:' .. info.area .. ':info')
      areas[#areas + 1] = {id = info.area, name = area.name, city = area.city, color = tonumber(area.color) or 1, bounds = box(area)}
      if area.city and not seen_city[area.city] then
        seen_city[area.city] = true
        local city = hgetall('CITY:' .. area.city .. ':info')
        cities[#cities + 1] = {id = area.city, name = city.name, bounds = box(city)}
      end
    end
  end
  return emit('PLAYER:' .. pid, {type = 'map', full = full, rooms = rooms, areas = areas, cities = cities})
end

-- Subscriptions ---------------------------------------------------------------

-- The channels a player in this room is subscribed to, besides chat channels.
local function place_channels(pid, rid)
  local channels = {'PLAYER:' .. pid, 'ROOM:' .. rid}
  local area = redis.call('HGET', 'ROOM:' .. rid .. ':info', 'area')
  if area then
    channels[#channels + 1] = 'AREA:' .. area
    local city = redis.call('HGET', 'AREA:' .. area .. ':info', 'city')
    if city then channels[#channels + 1] = 'CITY:' .. city end
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
      out[#out + 1] = {id = fid, name = redis.call('HGET', 'FACTION:' .. fid, 'name') or fid,
        affinity = a, respect = r, affinity_label = affinity_label(a), respect_label = respect_label(r)}
    end
  end
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
  local exits = sorted(list(redis.call('HKEYS', 'ROOM:' .. rid .. ':exits')))
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
  if #items > 0 then lines[#lines + 1] = 'You see: ' .. table.concat(item_names, ', ') end
  if #entities > 0 then lines[#lines + 1] = 'Also here: ' .. table.concat(entity_names, ', ') end

  return emit('PLAYER:' .. pid, {
    type = 'room',
    cause = cause,
    room = {
      id = rid, name = info.name, description = info.description, area = area or nil,
      exits = exits, items = items, features = features, entities = entities,
      self = player_card(pid), safe = is_safe(pid, rid),
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
-- the slot's new state. Poise and focus widen the gear's windows, but a window
-- never reaches halfway to the next beat.
local function take_beat(pid, n, gear)
  local now = now_ms()
  local state = live_slot(pid, n, now)
  local quality, offset
  if not state then
    local period = tonumber(gear.period)
    local window = math.min(tonumber(gear.window) + 15 * stat(pid, 'poise'), math.ceil(period / 2) - 1)
    local perfect = math.min(tonumber(gear.perfect_window) + 10 * stat(pid, 'focus'), window)
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

local function gear_summary(g)
  return {id = g.id, name = g.name, kind = g.kind, effect = g.effect, targets = g.targets ~= '' and g.targets or 'self',
    period_ms = tonumber(g.period), grace_ms = tonumber(g.window), perfect_ms = tonumber(g.perfect_window),
    amounts = list({tonumber(g.opener), tonumber(g.good), tonumber(g.perfect)})}
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
  for _, g in ipairs(owned_gear(pid)) do gear[#gear + 1] = gear_summary(g) end
  for n = 1, SLOTS do
    local g = slot_gear(pid, n)
    slots[n] = g and g.id or ''
  end
  for _, iid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':inv')) do
    items[#items + 1] = {id = iid, name = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid}
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  return emit('PLAYER:' .. pid, {type = 'kit', gear = gear, slots = slots, items = items})
end

local function character_event(pid)
  local account = hgetall('ACCOUNT:' .. pid)
  local level = tonumber(account.level) or 1
  local stats = {}
  for _, s in ipairs(STATS) do stats[s] = tonumber(account['stat:' .. s]) or 0 end
  local perks = list()
  for _, id in ipairs(sorted(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':perks'))) do
    local perk = hgetall('PERK:' .. id)
    perks[#perks + 1] = {id = id, name = perk.name or id, description = perk.description or ''}
  end
  local card = player_card(pid)
  return emit('PLAYER:' .. pid, {type = 'character', level = level, xp = tonumber(account.xp) or 0,
    xp_next = xp_needed(level), points = tonumber(account.points) or 0, stats = stats, perks = perks,
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
    notice(pid, 'You reach level ' .. level .. "! You have a stat point to spend: 'train <stat>'."
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
  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid and redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
    dispositions_event(pid, rid)
    aggro(pid, rid)
  end
end

-- Moves an awake player between rooms: leave and arrive events, subscriptions
-- and the map. The caller sends the new room's view.
local function relocate(pid, rid, dest, verb, target, leave, arrive)
  emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = verb, target = target, entity_id = 'pc:' .. pid, text = leave})
  redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
  redis.call('SET', 'PLAYER:' .. pid .. ':room', dest)
  redis.call('SADD', 'ROOM:' .. dest .. ':players', pid)
  emit('ROOM:' .. dest, {type = 'arrive', actor = pid, verb = verb, target = target, entity = player_card(pid), text = arrive})
  local old, new = place_channels(pid, rid), place_channels(pid, dest)
  resubscribe(pid, minus(new, old), minus(old, new))
  if explore(pid, dest) then map_event(pid, {dest}, false) end
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
  if (args[2] or '') == '' then return room_event(pid, rid, 'look') end
  inspect(pid, rid, args[2])
end))

redis.register_function('inspect', action(function(pid, rid, args)
  inspect(pid, rid, args[2])
end))

-- The movement steps from todo.md, in order. A short cooldown between moves
-- (move_cooldown_ms) stops a client from sending a whole journey at once.
-- Leaving a fight is fleeing it, and some cultures judge that.
redis.register_function('move', action(function(pid, rid, args)
  local dir = args[2]
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
  if not dest then return notice(pid, "You can't go that way.") end
  local cooldown = rule('move_cooldown_ms', 250)
  if cooldown > 0 and not redis.call('SET', 'PLAYER:' .. pid .. ':moved', '1', 'NX', 'PX', cooldown) then
    return notice(pid, 'You need a moment to find your footing.')
  end
  local fled = redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':foes')
  for _, nid in ipairs(fled) do drop_foe(nid, pid) end
  local me, from = name_of(pid), ARRIVE_FROM[dir]
  relocate(pid, rid, dest, 'move', dir, me .. ' heads ' .. dir .. '.', me .. (from and (' arrives from ' .. from .. '.') or ' arrives.'))
  room_event(pid, dest, 'move')
  for _, nid in ipairs(fled) do deed(pid, 'flee', nid) end
  aggro(pid, dest)
end))

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
  local quality, offset, state = take_beat(pid, n, gear)
  local amount = tonumber(gear[quality])
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
  if not gear then return notice(pid, 'Slot ' .. n .. " is empty. Try 'equip <gear> " .. n .. "', or 'gear' to see what you have.") end
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
  local quality, offset, state = take_beat(pid, n, gear)
  local damage = tonumber(gear[quality])
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
  if #taken > 0 then
    notice(pid, 'You take ' .. display .. "'s " .. table.concat(taken, ', ') .. ". ('inventory' to equip it.)")
    kit_event(pid)
  end
  gain_xp(pid, tonumber(npc.xp) or 0)
end))

-- Puts gear in a slot. args: pid, gear word, slot number ('' for the first
-- empty one).
redis.register_function('equip', action(function(pid, rid, args)
  local gid = match_gear(args[2])
  if not gid then return notice(pid, "There's no gear called '" .. args[2] .. "'. Type 'gear' to see what you have.") end
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
  if slot_busy(pid, n) then return end
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
  if slot_busy(pid, n) then return end
  redis.call('HDEL', 'PLAYER:' .. pid .. ':slots', n)
  redis.call('DEL', slot_key(pid, n))
  notice(pid, 'Slot ' .. n .. ' is empty now.')
  timing_event(pid, n, nil)
  kit_event(pid)
end))

-- Lists the gear the player has, fastest first, and what's in their slots.
redis.register_function('gear', action(function(pid, rid, args)
  local gear, lines = list(), {'Your gear (good timing / perfect, after the opener):'}
  for _, g in ipairs(owned_gear(pid)) do
    local summary = gear_summary(g)
    gear[#gear + 1] = summary
    lines[#lines + 1] = '  ' .. g.name .. ' (' .. string.lower(g.kind or '') .. '): ' .. every(summary.period_ms)
      .. ', ±' .. summary.grace_ms .. 'ms, ' .. (g.effect == 'heal' and 'heals ' or '') .. summary.amounts[2] .. ' / '
      .. summary.amounts[3] .. (g.effect == 'heal' and '' or ' damage') .. (summary.targets == 'ally' and ', on you or an ally' or '')
  end
  local slots, labels = list(), {}
  for n = 1, SLOTS do
    local g = slot_gear(pid, n)
    slots[n] = g and g.id or ''
    labels[n] = n .. ' ' .. (g and g.name or '(empty)')
  end
  lines[#lines + 1] = 'Your slots: ' .. table.concat(labels, ' · ') .. ". Change one with 'equip <gear> <slot>'."
  emit('PLAYER:' .. pid, {type = 'gear', gear = gear, slots = slots, text = table.concat(lines, '\n')})
end))

-- Spends a stat point. args: pid, stat.
redis.register_function('train', action(function(pid, rid, args)
  local name = args[2]
  if not STAT_INFO[name] then return notice(pid, 'Your stats are vigor, poise, focus and presence.') end
  local key = 'ACCOUNT:' .. pid
  if (tonumber(redis.call('HGET', key, 'points')) or 0) < 1 then
    return notice(pid, "You have no stat points to spend. You'll get one each level.")
  end
  local hp = player_card(pid).hp
  redis.call('HINCRBY', key, 'points', -1)
  local value = redis.call('HINCRBY', key, 'stat:' .. name, 1)
  if name == 'vigor' then redis.call('HSET', key, 'hp', hp + VIGOR_HP) end
  notice(pid, capitalize(name) .. ' is now ' .. value .. '. ' .. STAT_INFO[name])
  character_event(pid)
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
  if points > 0 then lines[#lines + 1] = 'Stat points to spend: ' .. points .. ". 'train <stat>'" end
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
  redis.call('SMOVE', 'ROOM:' .. rid .. ':items', 'PLAYER:' .. pid .. ':inv', iid)
  emit('ROOM:' .. rid, {type = 'item', actor = pid, verb = 'get', target = iid, item = {id = iid, name = item.name}, text = name_of(pid) .. ' picks up the ' .. item.name .. '.'})
  kit_event(pid)
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
      .. '\nGear: ' .. (#gear > 0 and table.concat(gear, ', ') or 'none') .. ". 'equip <gear> <slot>' to use it.",
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

redis.register_function('who', action(function(pid, rid, args)
  local names = list()
  for _, p in ipairs(redis.call('ZRANGE', 'alz:online', 0, -1)) do names[#names + 1] = name_of(p) end
  sorted(names)
  emit('PLAYER:' .. pid, {type = 'who', players = names, text = 'Online (' .. #names .. '): ' .. table.concat(names, ', ')})
end))

redis.register_function('notify', action(function(pid, rid, args)
  notice(pid, args[2])
end))

-- An admin announcement to the player's current area or city.
redis.register_function('announce', action(function(pid, rid, args)
  local scope, text = args[2], args[3]
  local area = redis.call('HGET', 'ROOM:' .. rid .. ':info', 'area')
  local channel
  if scope == 'area' and area then
    channel = 'AREA:' .. area
  elseif scope == 'city' and area then
    local city = redis.call('HGET', 'AREA:' .. area .. ':info', 'city')
    if city then channel = 'CITY:' .. city end
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
    map_event(pid, redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':explored'), true)
    ensure_kit(pid)
    resend_timing(pid)
    kit_event(pid)
    character_event(pid)
    room_event(pid, rid, 'resume')
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
  map_event(pid, redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':explored'), true)
  ensure_kit(pid)
  resend_timing(pid)
  kit_event(pid)
  character_event(pid)
  room_event(pid, rid, 'enter')
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

-- Loads the world definition. Static data (rooms, areas, cities, item text) is
-- rewritten every time; live state (where items are, who is where) is only set
-- for things that don't exist yet.
redis.register_function('seed', function(keys, args)
  local world = cjson.decode(args[1])
  for cid, city in pairs(world.cities) do
    redis.call('DEL', 'CITY:' .. cid .. ':info')
    redis.call('HSET', 'CITY:' .. cid .. ':info', 'name', city.name)
  end
  -- Areas get distinct map colours (1-6) in id order, unless the seed picks one.
  local area_ids = {}
  for aid in pairs(world.areas) do area_ids[#area_ids + 1] = aid end
  table.sort(area_ids)
  for i, aid in ipairs(area_ids) do
    local area = world.areas[aid]
    redis.call('DEL', 'AREA:' .. aid .. ':info')
    redis.call('HSET', 'AREA:' .. aid .. ':info', 'name', area.name, 'city', area.city, 'color', area.color or ((i - 1) % 6 + 1))
  end
  local area_box = {}
  for rid, room in pairs(world.rooms) do
    local base = 'ROOM:' .. rid
    local x, y = room.pos[1], room.pos[2]
    redis.call('DEL', base .. ':info', base .. ':exits', base .. ':features', base .. ':flavor')
    redis.call('HSET', base .. ':info', 'name', room.name, 'description', room.description, 'area', room.area, 'x', x, 'y', y,
      'safe', room.safe and '1' or '0', 'terrain', room.terrain or '')
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
  -- Each area's box covers its rooms; each city's box covers its areas.
  local city_box = {}
  for aid, b in pairs(area_box) do
    redis.call('HSET', 'AREA:' .. aid .. ':info', 'x1', b[1], 'y1', b[2], 'x2', b[3], 'y2', b[4])
    local cid = world.areas[aid].city
    local c = city_box[cid]
    if c then
      c[1], c[2], c[3], c[4] = math.min(c[1], b[1]), math.min(c[2], b[2]), math.max(c[3], b[3]), math.max(c[4], b[4])
    else
      city_box[cid] = {b[1], b[2], b[3], b[4]}
    end
  end
  for cid, c in pairs(city_box) do
    redis.call('HSET', 'CITY:' .. cid .. ':info', 'x1', c[1], 'y1', c[2], 'x2', c[3], 'y2', c[4])
  end
  for nid, npc in pairs(world.npcs or {}) do
    local key = 'NPC:' .. nid
    local new = redis.call('EXISTS', key) == 0
    redis.call('HSET', key, 'name', npc.name, 'label', npc.label or '', 'description', npc.description or '',
      'details', npc.details or '', 'keywords', npc.keywords or '', 'max_hp', npc.max_hp or 10,
      'proper', npc.proper and '1' or '0', 'respawn', npc.respawn or 60, 'icon', npc.icon or '',
      'disposition', npc.disposition or 'neutral', 'faction', npc.faction or '', 'role', npc.role or '',
      'attacks', cjson.encode(npc.attacks or {}), 'drops', cjson.encode(npc.drops or {}),
      'xp', npc.xp or math.floor((npc.max_hp or 10) / 2), 'immortal', npc.immortal and '1' or '0')
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
      'hit', gear.hit, 'perfect_hit', gear.perfect_hit, 'miss', gear.miss, 'whiff', gear.whiff)
    redis.call('SADD', 'alz:gear', gid)
  end
  for _, gid in ipairs(world.loadout or {}) do redis.call('RPUSH', 'alz:default_loadout', gid) end
  redis.call('DEL', 'alz:starting_gear')
  for _, gid in ipairs(world.starting_gear or {}) do redis.call('RPUSH', 'alz:starting_gear', gid) end
  -- Factions, perks and the level table are static too.
  for _, fid in ipairs(redis.call('SMEMBERS', 'alz:factions')) do redis.call('DEL', 'FACTION:' .. fid) end
  redis.call('DEL', 'alz:factions')
  for fid, faction in pairs(world.factions or {}) do
    redis.call('HSET', 'FACTION:' .. fid, 'name', faction.name, 'description', faction.description or '',
      'rules', cjson.encode(faction.rules or {}))
    redis.call('SADD', 'alz:factions', fid)
  end
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
    redis.call('HSET', key, 'name', item.name, 'keywords', item.keywords or '', 'description', item.description or '')
    if new then redis.call('SADD', 'ROOM:' .. item.room .. ':items', iid) end
  end
  for _, ch in ipairs(world.channels or {}) do
    if redis.call('EXISTS', 'CHANNEL:' .. ch .. ':info') == 0 then
      redis.call('HSET', 'CHANNEL:' .. ch .. ':info', 'owner', 'system', 'created', math.floor(now_ms() / 1000))
    end
    redis.call('SADD', 'alz:channels', ch)
    redis.call('SADD', 'alz:default_channels', ch)
  end
  redis.call('SET', 'alz:start_room', world.start_room)
  return 1
end)

-- Upkeep -----------------------------------------------------------------------

-- Brings back NPCs whose respawn time has come. Hostile ones turn on whoever
-- is there.
local function respawn_due(now)
  local due = redis.call('ZRANGEBYSCORE', 'alz:respawns', '-inf', now)
  for _, nid in ipairs(due) do
    redis.call('ZREM', 'alz:respawns', nid)
    local npc = hgetall('NPC:' .. nid)
    if npc.room then
      redis.call('HSET', 'NPC:' .. nid, 'hp', npc.max_hp or 10)
      redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid)
      emit('ROOM:' .. npc.room, {type = 'arrive', entity = npc_card(nid), text = capitalize(npc_display(nid)) .. ' appears.'})
      for _, pid in ipairs(redis.call('SMEMBERS', 'ROOM:' .. npc.room .. ':players')) do
        if redis.call('EXISTS', 'PLAYER:' .. pid .. ':session') == 1 then
          dispositions_event(pid, npc.room)
          aggro(pid, npc.room)
        end
      end
    end
  end
  return #due
end

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

-- Ambient world events (bells, weather) published by the server's ticker.
redis.register_function('ambient', function(keys, args)
  local channel, text = args[1], args[2]
  if redis.call('EXISTS', channel .. ':info') == 0 then return 0 end
  emit(channel, {type = 'ambient', text = text})
  return 1
end)
