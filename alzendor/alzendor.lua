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

local function fill(template, actor, target)
  local s = string.gsub(template, '{actor}', function() return actor end)
  s = string.gsub(s, '{target}', function() return target or '' end)
  return s
end

-- Entities --------------------------------------------------------------------
-- Players and NPCs share one card shape, shown in a room's "Here" list.
-- Their ids are 'pc:<player>' and 'npc:<npc>'.

local function player_card(pid)
  local account = hgetall('ACCOUNT:' .. pid)
  return {
    id = 'pc:' .. pid, kind = 'pc', name = account.name or pid, label = 'Adventurer',
    description = account.description or 'An ordinary traveller.',
    hp = tonumber(account.hp) or 100, max_hp = tonumber(account.max_hp) or 100,
  }
end

local function npc_card(nid)
  local npc = hgetall('NPC:' .. nid)
  local max_hp = tonumber(npc.max_hp) or 10
  return {
    id = 'npc:' .. nid, kind = 'npc', name = npc.name or nid, label = npc.label or '',
    description = npc.description or '', hp = tonumber(npc.hp) or max_hp, max_hp = max_hp,
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
    entities[#entities + 1] = npc_card(nid)
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
      self = player_card(pid),
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
-- Every action in a fight belongs to a rhythm (melee, spells, potions), and
-- each rhythm keeps its own beat. The first use of a rhythm lands at once and
-- starts it. After that its timing ball crosses the centre of its bar every
-- `period` ms (a "beat"), and an action only lands if it arrives within the
-- rhythm's grace window around a beat. Every attempt uses up a beat, hit or
-- miss, and an attempt before the next unused beat counts against that beat:
-- mashing only burns beats. Good play keeps all the rhythms on their beats.
-- A rhythm is the player's, not the fight's: it carries on across targets,
-- kills, leaving the room and reconnecting, and only ends after a timeout
-- without use. Otherwise stepping out and back in (or switching to a fresh
-- target) would give a free, instant opening action.
-- PLAYER:<id>:rhythm:<name> holds start (ms), period (ms), beat (the last one
-- used) and last (ms of the last use). Players can have their own period for a
-- rhythm in their account (period:<name>).

local RHYTHM_ORDER = {'melee', 'spell', 'potion'}
local RHYTHMS = {
  melee = {label = 'Melee', hint = 'k to kick', period = 2000, grace = 300, perfect = 100},
  spell = {label = 'Spells', hint = 'mm for magic missile', period = 8000, grace = 400, perfect = 130},
  potion = {label = 'Potions', hint = 'hp for a health potion', period = 5000, grace = 350, perfect = 120},
}
local MIN_TIMEOUT_MS = 10000 -- a rhythm ends after this long unused, or two beats if longer

-- Amounts by how well the action was timed. Templates fill in {actor} and {target}.
local ABILITIES = {
  kick = {
    rhythm = 'melee', opener = 4, good = 5, perfect = 8,
    hit = '{actor} kicks {target}.', perfect_hit = '{actor} lands a perfect kick on {target}!',
    miss = '{actor} kicks at {target} and misses.', whiff = 'your kick goes wide.',
  },
  missile = {
    rhythm = 'spell', opener = 10, good = 12, perfect = 20,
    hit = '{actor} hurls a magic missile at {target}.', perfect_hit = "{actor}'s magic missile strikes {target} dead centre!",
    miss = "{actor}'s magic missile streaks past {target}.", whiff = 'your magic missile fizzles.',
  },
  potion = {
    rhythm = 'potion', opener = 10, good = 15, perfect = 25,
    hit = '{actor} drinks a health potion.', perfect_hit = '{actor} downs a health potion in one perfect gulp!',
    miss = '{actor} fumbles a health potion and spills it.', whiff = 'you fumble the potion and spill it.',
  },
}

local function capitalize(text)
  return (string.gsub(text, '^%l', string.upper))
end

local function timeout_for(period)
  return math.max(MIN_TIMEOUT_MS, 2 * period)
end

-- Sends the player the state of one rhythm (inactive if `state` is nil).
local function timing_event(pid, name, state)
  local rhythm = RHYTHMS[name]
  local event = {type = 'timing', rhythm = name, label = rhythm.label, hint = rhythm.hint, active = false}
  if state then
    local period = tonumber(state.period)
    event.active = true
    event.start_ms, event.period_ms = tonumber(state.start), period
    event.grace_ms, event.perfect_ms = rhythm.grace, rhythm.perfect
    event.last_beat, event.last_ms, event.timeout_ms = tonumber(state.beat), tonumber(state.last), timeout_for(period)
  end
  return emit('PLAYER:' .. pid, event)
end

-- Uses up one beat of a player's rhythm. Returns how well it was timed
-- ('opener', 'perfect', 'good', 'early' or 'late'), the offset from the beat
-- in ms, and the rhythm's new state.
local function take_beat(pid, name)
  local rhythm = RHYTHMS[name]
  local key = 'PLAYER:' .. pid .. ':rhythm:' .. name
  local now = now_ms()
  local state = hgetall(key)
  local quality, offset
  if not state.start or now - tonumber(state.last) > timeout_for(tonumber(state.period)) then
    local period = tonumber(redis.call('HGET', 'ACCOUNT:' .. pid, 'period:' .. name)) or rhythm.period
    state = {start = now, period = period, beat = 0}
    quality = 'opener'
  else
    local start, period = tonumber(state.start), tonumber(state.period)
    local beat = math.max(math.floor((now - start) / period + 0.5), tonumber(state.beat) + 1)
    offset = now - (start + beat * period)
    state.beat = beat
    if math.abs(offset) <= rhythm.perfect then
      quality = 'perfect'
    elseif math.abs(offset) <= rhythm.grace then
      quality = 'good'
    else
      quality = offset < 0 and 'early' or 'late'
    end
  end
  state.last = now
  redis.call('HSET', key, 'start', state.start, 'period', state.period, 'beat', state.beat, 'last', state.last)
  redis.call('PEXPIRE', key, timeout_for(tonumber(state.period)) * 3)
  return quality, offset, state
end

-- Reports a mistimed action: privately how, and to the room that it missed.
local function whiff(pid, rid, ability_name, quality, offset, target_id, target_display)
  local ability = ABILITIES[ability_name]
  emit('PLAYER:' .. pid, {type = 'combat', rhythm = ability.rhythm, result = quality, offset_ms = offset,
    text = (quality == 'early' and 'Too early' or 'Too late') .. ': ' .. ability.whiff})
  emit('ROOM:' .. rid, {type = 'combat', actor = pid, verb = ability_name, rhythm = ability.rhythm, target = target_id,
    result = 'miss', text = fill(ability.miss, name_of(pid), target_display)})
end

-- Tells a (re)connecting player about each of their rhythms.
local function resend_timing(pid)
  for _, name in ipairs(RHYTHM_ORDER) do
    local state = hgetall('PLAYER:' .. pid .. ':rhythm:' .. name)
    local live = state.last and now_ms() - tonumber(state.last) <= timeout_for(tonumber(state.period))
    timing_event(pid, name, live and state or nil)
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

-- The movement steps from todo.md, in order.
redis.register_function('move', action(function(pid, rid, args)
  local dir = args[2]
  local dest = redis.call('HGET', 'ROOM:' .. rid .. ':exits', dir)
  if not dest then return notice(pid, "You can't go that way.") end
  local me = name_of(pid)

  emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = 'move', target = dir, entity_id = 'pc:' .. pid, text = me .. ' heads ' .. dir .. '.'})
  redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
  redis.call('SET', 'PLAYER:' .. pid .. ':room', dest)
  redis.call('SADD', 'ROOM:' .. dest .. ':players', pid)

  local from = ARRIVE_FROM[dir]
  emit('ROOM:' .. dest, {
    type = 'arrive', actor = pid, verb = 'move', target = dir, entity = player_card(pid),
    text = me .. (from and (' arrives from ' .. from .. '.') or ' arrives.'),
  })

  local old, new = place_channels(pid, rid), place_channels(pid, dest)
  resubscribe(pid, minus(new, old), minus(old, new))
  if explore(pid, dest) then map_event(pid, {dest}, false) end
  room_event(pid, dest, 'move')
end))

-- An attack on an NPC. args: pid, ability, target word.
redis.register_function('attack', action(function(pid, rid, args)
  local name = args[2]
  local ability = ABILITIES[name]
  local kind, id, display = resolve(pid, rid, args[3])
  if not kind then return notice(pid, "You don't see that here.") end
  if kind == 'self' then return notice(pid, 'You think better of it.') end
  if kind == 'player' then return notice(pid, "You can't attack other players.") end
  if kind ~= 'npc' then return notice(pid, "You can't fight that.") end

  local quality, offset, state = take_beat(pid, ability.rhythm)
  local damage = ability[quality]
  if not damage then
    whiff(pid, rid, name, quality, offset, 'npc:' .. id, display)
    return timing_event(pid, ability.rhythm, state)
  end

  local hp = redis.call('HINCRBY', 'NPC:' .. id, 'hp', -damage)
  local text = fill(quality == 'perfect' and ability.perfect_hit or ability.hit, name_of(pid), display)
  emit('ROOM:' .. rid, {type = 'combat', actor = pid, verb = name, rhythm = ability.rhythm, target = 'npc:' .. id,
    result = quality, damage = damage, offset_ms = offset, text = text .. ' (' .. damage .. ')'})
  if hp > 0 then
    emit('ROOM:' .. rid, {type = 'entity', entity = npc_card(id)})
  else
    -- Down: out of the room until it respawns.
    redis.call('HSET', 'NPC:' .. id, 'hp', 0)
    redis.call('SREM', 'ROOM:' .. rid .. ':npcs', id)
    local delay = (tonumber(redis.call('HGET', 'NPC:' .. id, 'respawn')) or 60) * 1000
    redis.call('ZADD', 'alz:respawns', tonumber(state.last) + delay, id)
    emit('ROOM:' .. rid, {type = 'death', entity_id = 'npc:' .. id, text = capitalize(display) .. ' collapses.'})
  end
  timing_event(pid, ability.rhythm, state)
end))

-- Drinking a health potion (unlimited, for now). args: pid.
redis.register_function('drink', action(function(pid, rid, args)
  local ability = ABILITIES.potion
  local quality, offset, state = take_beat(pid, ability.rhythm)
  local amount = ability[quality]
  if not amount then
    whiff(pid, rid, 'potion', quality, offset, nil, nil)
    return timing_event(pid, ability.rhythm, state)
  end
  local card = player_card(pid)
  local healed = math.min(amount, card.max_hp - card.hp)
  redis.call('HSET', 'ACCOUNT:' .. pid, 'hp', card.hp + healed, 'max_hp', card.max_hp)
  local text = fill(quality == 'perfect' and ability.perfect_hit or ability.hit, name_of(pid))
  emit('ROOM:' .. rid, {type = 'heal', actor = pid, verb = 'potion', rhythm = ability.rhythm, result = quality,
    amount = healed, offset_ms = offset, text = text .. (healed > 0 and (' (+' .. healed .. ')') or ' (already at full health)')})
  emit('ROOM:' .. rid, {type = 'entity', entity = player_card(pid)})
  timing_event(pid, ability.rhythm, state)
end))

redis.register_function('say', action(function(pid, rid, args)
  emit('ROOM:' .. rid, {type = 'say', actor = pid, verb = 'say', message = args[2], text = name_of(pid) .. ' says, "' .. args[2] .. '"'})
end))

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
end))

redis.register_function('drop', action(function(pid, rid, args)
  local iid, item = match_item('PLAYER:' .. pid .. ':inv', args[2])
  if not iid then return notice(pid, "You aren't carrying that.") end
  redis.call('SMOVE', 'PLAYER:' .. pid .. ':inv', 'ROOM:' .. rid .. ':items', iid)
  emit('ROOM:' .. rid, {type = 'item', actor = pid, verb = 'drop', target = iid, item = {id = iid, name = item.name}, text = name_of(pid) .. ' drops the ' .. item.name .. '.'})
end))

redis.register_function('inventory', action(function(pid, rid, args)
  local names = list()
  for _, iid in ipairs(redis.call('SMEMBERS', 'PLAYER:' .. pid .. ':inv')) do
    names[#names + 1] = redis.call('HGET', 'ITEM:' .. iid, 'name') or iid
  end
  sorted(names)
  emit('PLAYER:' .. pid, {
    type = 'inventory', items = names,
    text = #names > 0 and ('You are carrying: ' .. table.concat(names, ', ')) or 'You are carrying nothing.',
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
    resend_timing(pid)
    room_event(pid, rid, 'resume')
    return cursor
  end

  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if not rid or redis.call('EXISTS', 'ROOM:' .. rid .. ':info') == 0 then
    rid = redis.call('GET', 'alz:start_room')
  end
  redis.call('SET', 'PLAYER:' .. pid .. ':room', rid)
  redis.call('SADD', 'ROOM:' .. rid .. ':players', pid)
  emit('ROOM:' .. rid, {type = 'arrive', actor = pid, verb = 'login', entity = player_card(pid), text = name_of(pid) .. ' appears.'})

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
  resend_timing(pid)
  room_event(pid, rid, 'enter')
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

  local rid = redis.call('GET', 'PLAYER:' .. pid .. ':room')
  if rid then
    redis.call('SREM', 'ROOM:' .. rid .. ':players', pid)
    emit('ROOM:' .. rid, {type = 'leave', actor = pid, verb = 'logout', entity_id = 'pc:' .. pid, text = name_of(pid) .. ' fades from view.'})
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
    redis.call('HSET', base .. ':info', 'name', room.name, 'description', room.description, 'area', room.area, 'x', x, 'y', y)
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
      'proper', npc.proper and '1' or '0', 'respawn', npc.respawn or 60)
    if new then
      redis.call('HSET', key, 'hp', npc.max_hp or 10, 'room', npc.room)
      redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid)
    end
  end
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

-- Ambient world events (bells, weather) published by the server's ticker.
-- Brings back NPCs whose respawn time has come. Any server may call this.
redis.register_function('respawn', function(keys, args)
  local due = redis.call('ZRANGEBYSCORE', 'alz:respawns', '-inf', now_ms())
  for _, nid in ipairs(due) do
    redis.call('ZREM', 'alz:respawns', nid)
    local npc = hgetall('NPC:' .. nid)
    if npc.room then
      redis.call('HSET', 'NPC:' .. nid, 'hp', npc.max_hp or 10)
      redis.call('SADD', 'ROOM:' .. npc.room .. ':npcs', nid)
      emit('ROOM:' .. npc.room, {type = 'arrive', entity = npc_card(nid), text = capitalize(npc_display(nid)) .. ' appears.'})
    end
  end
  return #due
end)

redis.register_function('ambient', function(keys, args)
  local channel, text = args[1], args[2]
  if redis.call('EXISTS', channel .. ':info') == 0 then return 0 end
  emit(channel, {type = 'ambient', text = text})
  return 1
end)
