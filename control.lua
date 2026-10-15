local WINDOW = "platform_groups_window"
local BUTTON = "platform_groups_button"
local INTERRUPTS = "platform_groups_interrupts"
local UNGROUPED = "<ungrouped>"

local function init_storage()
  storage.collapsed = storage.collapsed or {}
  storage.locations = storage.locations or {}
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

local function saved_location(player, name)
  local by_player = storage.locations and storage.locations[player.index]
  return by_player and by_player[name]
end

-- Words of a name, numbers dropped. A rich-text tag like [item=utility-science-pack] is one word.
local function name_words(name)
  local words = {}
  local pos = 1
  while pos <= #name do
    local char = name:sub(pos, pos)
    local word
    if char == "[" then
      word = name:match("^%b[]", pos) or char
    elseif not char:match("[%s%-_]") then
      word = name:match("^[^%s%-_%[]+", pos)
    end
    if word then
      if not word:match("^#?%d+$") then
        words[#words + 1] = word
      end
      pos = pos + #word
    else
      pos = pos + 1
    end
  end
  return words
end

local function by_name(a, b)
  return a.platform.name < b.platform.name
end

local function bucket(members, key_of)
  local by_key, order = {}, {}
  for _, member in ipairs(members) do
    local key = key_of(member)
    if not by_key[key] then
      by_key[key] = {}
      order[#order + 1] = key
    end
    table.insert(by_key[key], member)
  end
  table.sort(order)
  return by_key, order
end

local build_node

-- A group whose only content is one subgroup is merged into it ("Legen" > "sci" becomes "Legen sci").
local function labelled(node, label)
  while #node.subgroups == 1 and #node.loose == 0 do
    local child = node.subgroups[1]
    label = label .. " " .. child.label
    node = child
  end
  node.label = label
  return node
end

-- Any number of levels, one per leading word. Buckets of one platform are not groups.
function build_node(members, depth, path)
  local node = { key = path, count = #members, subgroups = {}, loose = {} }
  local sub, sub_order = bucket(members, function(m) return m.words[depth] or "" end)
  for _, word in ipairs(sub_order) do
    local sub_members = sub[word]
    if #sub_members > 1 and word ~= "" then
      node.subgroups[#node.subgroups + 1] = labelled(build_node(sub_members, depth + 1, path .. "/" .. word), word)
    else
      for _, m in ipairs(sub_members) do
        node.loose[#node.loose + 1] = m
      end
    end
  end
  table.sort(node.loose, by_name)
  return node
end

local function build_groups(force)
  local all = {}
  for _, platform in pairs(force.platforms) do
    if platform.valid then
      all[#all + 1] = { platform = platform, words = name_words(platform.name) }
    end
  end

  local groups, singles = {}, {}
  local top, top_order = bucket(all, function(m) return m.words[1] or m.platform.name end)
  for _, word in ipairs(top_order) do
    local members = top[word]
    if #members == 1 then
      singles[#singles + 1] = members[1]
    else
      groups[#groups + 1] = labelled(build_node(members, 2, word), word)
    end
  end
  if #singles > 0 then
    table.sort(singles, by_name)
    groups[#groups + 1] = { key = UNGROUPED, count = #singles, subgroups = {}, loose = singles }
  end
  return groups
end

local STUCK_TICKS = 10 * 60 * 60

-- Idle platforms: paused or without a schedule/path, or parked at a stop for longer than STUCK_TICKS.
-- Returns a short text and whether it is an idle state, or nil for a working platform.
local function idle_status(platform)
  local state = platform.state
  local states = defines.space_platform_state
  if state == states.paused then
    return "⏸ paused"
  elseif state == states.no_schedule then
    return "⚠ no schedule"
  elseif state == states.no_path then
    return "⚠ no path"
  elseif state == states.waiting_at_station then
    local schedule = platform.get_schedule()
    local waited = schedule and schedule.ticks_in_station or 0
    if waited >= STUCK_TICKS then
      return "⚠ stuck " .. math.floor(waited / 3600) .. " min"
    end
  end
  return nil
end

local function location_text(platform)
  local loc = platform.space_location
  if loc then
    return "[space-location=" .. loc.name .. "]"
  end
  local conn = platform.space_connection
  if conn then
    -- conn.from/to is the prototype's fixed ordering, not the travel direction. Prefer the current
    -- schedule target; last_visited_space_location alone proved unreliable.
    local from, to = conn.from.name, conn.to.name
    local schedule = platform.get_schedule()
    local record = schedule and schedule.current and schedule.get_record({ schedule_index = schedule.current })
    local target = record and record.station
    local origin = platform.last_visited_space_location
    if target == from or (target ~= to and origin and origin.name == to) then
      from, to = to, from
    end
    return "[space-location=" .. from .. "] → [space-location=" .. to .. "]"
  end
  return ""
end

local function collect_platforms(group, out)
  for _, member in ipairs(group.loose) do
    out[#out + 1] = member.platform
  end
  for _, sub in ipairs(group.subgroups) do
    collect_platforms(sub, out)
  end
  return out
end

local function find_group(groups, key)
  for _, group in ipairs(groups) do
    if group.key == key then
      return group
    end
    local found = find_group(group.subgroups, key)
    if found then
      return found
    end
  end
end

-- Adds a temporary stop right after the current record and heads there; it leaves after the wait and resumes its schedule.
local SEND_STOP_TICKS = 30 * 60

local function send_to_location(platform, location)
  local schedule = platform.get_schedule()
  if not schedule then
    return false
  end
  local current = schedule.current or 0
  local index = schedule.add_record({
    station = location,
    temporary = true,
    wait_conditions = { { type = "time", ticks = SEND_STOP_TICKS } },
    index = { schedule_index = current + 1 },
  })
  if not index then
    return false
  end
  schedule.go_to_station(index)
  return true
end

local LOADED_BUILD_TTL = 60 * 60

local function drop_loaded_build(player)
  if storage.loaded_build then
    storage.loaded_build[player.index] = nil
  end
end

local function signature(player)
  local parts = {}
  for _, platform in pairs(player.force.platforms) do
    parts[#parts + 1] = platform.index .. platform.name .. location_text(platform) .. (idle_status(platform) or "")
  end
  table.sort(parts)
  parts[#parts + 1] = helpers.table_to_json(storage.collapsed[player.index] or {})
  local loaded = storage.loaded_build and storage.loaded_build[player.index]
  parts[#parts + 1] = loaded and loaded.key or ""
  return table.concat(parts, "\n")
end

-- Empty choose-elem buttons render blank; draw a click-through icon over the slot instead.
local function add_picker_icon(row, sprite)
  local icon = row.add({ type = "sprite", sprite = sprite, ignored_by_interaction = true })
  icon.style.size = 24
  icon.style.left_margin = -32
  icon.style.top_margin = 8
  icon.style.right_margin = 8
end

-- Rebuilding closes an open location picker, so unchanged content is left alone unless forced.
local function populate(player, force_rebuild)
  local window = player.gui.screen[WINDOW]
  if not window then
    return
  end
  local sig = signature(player)
  storage.signatures = storage.signatures or {}
  if not force_rebuild and storage.signatures[player.index] == sig then
    return
  end
  storage.signatures[player.index] = sig

  local list = window.content.list
  list.clear()

  local groups = build_groups(player.force)
  if #groups == 0 then
    list.add({ type = "label", caption = { "platform-groups.no-platforms" } })
    return
  end

  local collapsed = storage.collapsed[player.index] or {}

  local add_group

  local loaded_group = storage.loaded_build and storage.loaded_build[player.index]
  loaded_group = loaded_group and loaded_group.key

  local function add_header(parent, group, title, count, indent)
    local idle_count = 0
    for _, platform in ipairs(collect_platforms(group, {})) do
      if idle_status(platform) then
        idle_count = idle_count + 1
      end
    end
    local is_collapsed = collapsed[group.key]
    local row = parent.add({ type = "flow", direction = "horizontal" })
    row.style.left_margin = indent
    row.style.vertical_align = "center"
    row.add({
      type = "button",
      style = "list_box_item",
      caption = { "", is_collapsed and "▸ " or "▾ ", title, " (", count, ")", idle_count > 0 and (" ⚠ " .. idle_count) or "" },
      tags = { pg_action = "toggle", group = group.key },
    })
    if loaded_group == group.key then
      row.add({
        type = "sprite-button",
        style = "green_button",
        sprite = "item/blueprint",
        tooltip = { "platform-groups.copy-apply-tooltip" },
        tags = { pg_action = "copy_build", group = group.key },
      })
    else
      row.add({
        type = "button",
        style = "tool_button",
        caption = "⧉",
        tooltip = { "platform-groups.copy-tooltip" },
        tags = { pg_action = "copy_build", group = group.key },
      })
    end
    row.add({
      type = "button",
      style = "tool_button",
      caption = "»",
      tooltip = { "platform-groups.interrupt-tooltip" },
      tags = { pg_action = "interrupts", group = group.key },
    })
    row.add({
      type = "choose-elem-button",
      style = "slot_button",
      elem_type = "space-location",
      tooltip = { "platform-groups.send-tooltip" },
      tags = { pg_action = "send", group = group.key },
    })
    add_picker_icon(row, "utility/go_to_arrow")
    row.add({
      type = "choose-elem-button",
      style = "slot_button",
      elem_type = "space-location",
      tooltip = { "platform-groups.launch-tooltip" },
      tags = { pg_action = "launch", group = group.key },
    })
    add_picker_icon(row, "utility/add")
    return not is_collapsed
  end

  local function add_rows(members, indent)
    local rows = list.add({ type = "table", column_count = 3 })
    rows.style.left_margin = indent
    rows.style.horizontal_spacing = 12
    for _, member in ipairs(members) do
      local platform = member.platform
      rows.add({
        type = "button",
        style = "list_box_item",
        caption = platform.name,
        tags = { pg_action = "open", platform_index = platform.index },
      })
      rows.add({ type = "label", caption = location_text(platform) })
      local idle = idle_status(platform)
      local status = rows.add({ type = "label", caption = idle or "" })
      status.style.font_color = { 1, 0.6, 0.2 }
    end
  end

  function add_group(group, indent)
    local title = group.key == UNGROUPED and { "platform-groups.ungrouped" } or group.label
    if not add_header(list, group, title, group.count, indent) then
      return
    end
    for _, sub in ipairs(group.subgroups) do
      add_group(sub, indent + 16)
    end
    if #group.loose > 0 then
      add_rows(group.loose, indent + 16)
    end
  end

  for _, group in ipairs(groups) do
    add_group(group, 0)
  end
end

local function group_platforms(player, key)
  local group = find_group(build_groups(player.force), key)
  return group and collect_platforms(group, {}) or {}
end

local function tile_key(x, y)
  return x * 65536 + y
end

-- Foundation tiles that no entity covers. Blueprint tile positions are tile corners.
local function empty_spots(entities, tiles)
  local covered = {}
  for _, entity in pairs(entities) do
    local prototype = prototypes.entity[entity.name]
    local box = prototype and prototype.collision_box
    if box then
      local left, top, right, bottom = box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y
      if entity.direction == 4 or entity.direction == 12 then
        left, top, right, bottom = top, left, bottom, right
      end
      local position = entity.position
      for x = math.floor(position.x + left + 0.01), math.floor(position.x + right - 0.01) do
        for y = math.floor(position.y + top + 0.01), math.floor(position.y + bottom - 0.01) do
          covered[tile_key(x, y)] = true
        end
      end
    end
  end

  local spots = {}
  for _, tile in pairs(tiles) do
    local x, y = tile.position.x, tile.position.y
    if not covered[tile_key(x, y)] then
      spots[#spots + 1] = { x = x + 0.5, y = y + 0.5 }
    end
  end
  return spots
end

-- Merges the empty spots into as few rectangles as possible: runs along x, then identical runs stacked along y.
local function spot_rects(spots)
  local rows = {}
  for _, spot in ipairs(spots) do
    local y = math.floor(spot.y)
    rows[y] = rows[y] or {}
    table.insert(rows[y], math.floor(spot.x))
  end

  local ys = {}
  for y in pairs(rows) do
    ys[#ys + 1] = y
  end
  table.sort(ys)

  local rects, open = {}, {}
  for _, y in ipairs(ys) do
    local xs = rows[y]
    table.sort(xs)
    local runs, start, prev = {}, xs[1], xs[1]
    for i = 2, #xs + 1 do
      if xs[i] ~= prev + 1 then
        runs[#runs + 1] = { start, prev + 1 }
        start = xs[i]
      end
      prev = xs[i]
    end

    local next_open = {}
    for _, run in ipairs(runs) do
      local id = run[1] .. ":" .. run[2]
      local rect = open[id]
      if rect and rect.y2 == y then
        rect.y2 = y + 1
      else
        rect = { x1 = run[1], y1 = y, x2 = run[2], y2 = y + 1 }
        rects[#rects + 1] = rect
      end
      next_open[id] = rect
    end
    open = next_open
  end
  return rects
end

local CAPTURE_RADIUS = 128

-- The runtime API has no getter for a platform's used bounds, so builds reaching further than this
-- from the hub are clipped.
local function capture_build(platform)
  local hub = platform.hub
  if not (hub and hub.valid) then
    return nil
  end
  local scratch = game.create_inventory(1)
  local stack = scratch[1]
  stack.set_stack({ name = "blueprint" })
  local center = hub.position
  stack.create_blueprint({
    surface = platform.surface,
    force = platform.force,
    area = {
      { center.x - CAPTURE_RADIUS, center.y - CAPTURE_RADIUS },
      { center.x + CAPTURE_RADIUS, center.y + CAPTURE_RADIUS },
    },
    always_include_tiles = true,
  })

  -- The hub stays in the blueprint: placed over the follower's own hub it carries the hub's settings across.
  local entities, hub_offset = stack.get_blueprint_entities() or {}, nil
  for _, entity in pairs(entities) do
    if entity.name == "space-platform-hub" then
      hub_offset = entity.position
    end
  end
  local tiles = stack.get_blueprint_tiles() or {}
  scratch.destroy()

  if not hub_offset then
    return nil
  end

  local spots = empty_spots(entities, tiles)
  local spot_set = {}
  for _, spot in ipairs(spots) do
    spot_set[tile_key(math.floor(spot.x), math.floor(spot.y))] = true
  end

  return { entities = entities, tiles = tiles, hub_offset = hub_offset, spot_set = spot_set, clear_rects = spot_rects(spots) }
end

local function apply_build(platform, build)
  local hub = platform.hub
  if not (hub and hub.valid) then
    return 0
  end
  local scratch = game.create_inventory(1)
  local stack = scratch[1]
  stack.set_stack({ name = "blueprint" })
  stack.set_blueprint_entities(build.entities)
  stack.set_blueprint_tiles(build.tiles)
  local built = stack.build_blueprint({
    surface = platform.surface,
    force = platform.force,
    position = { x = hub.position.x - build.hub_offset.x, y = hub.position.y - build.hub_offset.y },
    build_mode = defines.build_mode.superforced,
  })
  scratch.destroy()

  -- Deconstruction doesn't apply to ghosts, so ghosts the follower has on the template's empty spots are
  -- cancelled directly.
  local origin_x, origin_y = hub.position.x - build.hub_offset.x, hub.position.y - build.hub_offset.y
  local center = hub.position
  local existing = platform.surface.find_entities_filtered({
    type = "entity-ghost",
    area = {
      { center.x - CAPTURE_RADIUS, center.y - CAPTURE_RADIUS },
      { center.x + CAPTURE_RADIUS, center.y + CAPTURE_RADIUS },
    },
  })
  for _, ghost in pairs(existing) do
    local key = tile_key(math.floor(ghost.position.x - origin_x), math.floor(ghost.position.y - origin_y))
    if build.spot_set[key] then
      ghost.destroy()
    end
  end

  -- Mark built entities on the template's empty spots for deconstruction. Shrunk inwards so neighbours
  -- that only touch the edge aren't selected; tiles are never selected.
  local planner_inventory = game.create_inventory(1)
  local planner = planner_inventory[1]
  planner.set_stack({ name = "deconstruction-planner" })
  planner.tile_selection_mode = defines.deconstruction_item.tile_selection_mode.never
  for _, rect in ipairs(build.clear_rects) do
    platform.surface.deconstruct_area({
      area = {
        { origin_x + rect.x1 + 0.1, origin_y + rect.y1 + 0.1 },
        { origin_x + rect.x2 - 0.1, origin_y + rect.y2 - 0.1 },
      },
      force = platform.force,
      item = planner,
      super_forced = true,
    })
  end
  planner_inventory.destroy()

  return #built
end

local HUB_REQUESTER = defines.logistic_member_index.space_platform_hub_requester

local function hub_point(platform)
  local hub = platform.hub
  return hub and hub.valid and hub.get_logistic_point(HUB_REQUESTER) or nil
end

local function capture_hub_requests(platform)
  local point = hub_point(platform)
  if not point then
    return nil
  end
  local sections = {}
  for i = 1, point.sections_count do
    local section = point.get_section(i)
    if section then
      sections[#sections + 1] = {
        group = section.group,
        active = section.active,
        multiplier = section.multiplier,
        filters = section.filters,
      }
    end
  end
  return sections
end

-- Replaces the target's request sections with the leader's.
local function apply_hub_requests(platform, sections)
  local point = hub_point(platform)
  if not point then
    return
  end
  for i = point.sections_count, 1, -1 do
    point.remove_section(i)
  end
  for _, data in ipairs(sections) do
    local section = point.add_section(data.group)
    if section then
      section.active = data.active
      section.multiplier = data.multiplier
      section.filters = data.filters
    end
  end
end

local function enable_request_sections(platform)
  local hub = platform.hub
  local point = hub and hub.valid and hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester)
  if not point then
    return 0
  end
  local enabled = 0
  for i = 1, point.sections_count do
    local section = point.get_section(i)
    if section and not section.active then
      section.active = true
      enabled = enabled + 1
    end
  end
  return enabled
end

local function capture_schedule(platform)
  local schedule = platform.get_schedule()
  if not schedule then
    return nil
  end
  return { records = schedule.get_records() or {}, interrupts = schedule.get_interrupts() or {} }
end

-- Records first, then interrupts one by one: set_interrupts did not stick on followers. Returns the
-- follower's interrupt count afterwards so a mismatch can be reported.
local function apply_schedule(platform, data)
  local schedule = platform.get_schedule()
  if not schedule then
    return 0
  end
  schedule.set_records(data.records)
  schedule.clear_interrupts()
  for _, interrupt in ipairs(data.interrupts) do
    schedule.add_interrupt(interrupt)
  end
  return schedule.interrupt_count
end

local function number_of(name)
  local last
  for digits in name:gsub("%b[]", ""):gmatch("%d+") do
    last = tonumber(digits)
  end
  return last or math.huge
end

local function first_platform(platforms)
  local first
  for _, platform in ipairs(platforms) do
    if not first then
      first = platform
    else
      local a, b = number_of(platform.name), number_of(first.name)
      if a < b or (a == b and platform.name < first.name) then
        first = platform
      end
    end
  end
  return first
end

local function capture_snapshot(leader)
  local build = capture_build(leader)
  if not build then
    return nil
  end
  return { build = build, requests = capture_hub_requests(leader), schedule = capture_schedule(leader) }
end

-- Applies a snapshot to one platform; returns the number of ghosts placed.
local function apply_snapshot(platform, snapshot, player)
  local ghosts = apply_build(platform, snapshot.build)
  if snapshot.requests then
    apply_hub_requests(platform, snapshot.requests)
  end
  if snapshot.schedule then
    local count = apply_schedule(platform, snapshot.schedule)
    if player and count ~= #snapshot.schedule.interrupts then
      player.print({ "platform-groups.interrupts-mismatch", platform.name })
    end
  end
  enable_request_sections(platform)
  return ghosts
end

-- Next name in the group: the first platform's name with its number replaced by the highest number + 1.
local function next_platform_name(leader_name, platforms)
  local highest = 0
  for _, platform in ipairs(platforms) do
    local number = number_of(platform.name)
    if number ~= math.huge and number > highest then
      highest = number
    end
  end

  local masked = leader_name:gsub("%b[]", function(tag)
    return string.rep("_", #tag)
  end)
  local from, to
  for first, last in masked:gmatch("()%d+()") do
    from, to = first, last
  end
  if not from then
    return leader_name .. " " .. (highest + 1)
  end
  return leader_name:sub(1, from - 1) .. (highest + 1) .. leader_name:sub(to)
end

local STARTER_PACK = "space-platform-starter-pack"

-- Creates a platform in the group at the chosen planet. Its build, requests and schedule are copied from the
-- group's first platform once the starter pack has been delivered and the hub exists (see the tick handler).
local function launch_platform(player, key, planet)
  local platforms = group_platforms(player, key)
  local leader = first_platform(platforms)
  if not leader then
    return
  end
  if not prototypes.item[STARTER_PACK] then
    player.print({ "platform-groups.launch-failed" })
    return
  end
  local platform = player.force.create_space_platform({
    name = next_platform_name(leader.name, platforms),
    planet = planet,
    starter_pack = STARTER_PACK,
  })
  if not platform then
    player.print({ "platform-groups.launch-failed" })
    return
  end
  storage.pending_launches = storage.pending_launches or {}
  storage.pending_launches[platform.index] = { force_index = player.force.index, leader_index = leader.index }
  player.print({ "platform-groups.launched", platform.name, "[space-location=" .. planet .. "]" })
end

local function finish_pending_launches()
  for index, pending in pairs(storage.pending_launches or {}) do
    local force = game.forces[pending.force_index]
    local platform = force and force.platforms[index]
    if not (platform and platform.valid) then
      storage.pending_launches[index] = nil
    elseif platform.hub and platform.hub.valid then
      local leader = force.platforms[pending.leader_index]
      local snapshot = leader and leader.valid and capture_snapshot(leader)
      if snapshot then
        apply_snapshot(platform, snapshot)
      end
      storage.pending_launches[index] = nil
    end
  end
end

local function loaded_key(player)
  local loaded = storage.loaded_build and storage.loaded_build[player.index]
  return loaded and loaded.key
end

-- Two steps on one button: the first click snapshots the group's first platform (build, requests, schedule)
-- into storage, the second applies it to the rest as ghosts and clears what the snapshot has empty.
-- The snapshot is kept until it is applied, cancelled with a right click, or replaced by another group's.
local function copy_build(player, key, cancel)
  storage.loaded_build = storage.loaded_build or {}
  local loaded = storage.loaded_build[player.index]

  if cancel then
    if loaded and loaded.key == key then
      storage.loaded_build[player.index] = nil
      player.print({ "platform-groups.copy-cancelled", loaded.leader_name })
      populate(player, true)
    end
    return
  end

  local platforms = group_platforms(player, key)

  if not (loaded and loaded.key == key) then
    local leader = first_platform(platforms)
    if not leader or #platforms < 2 then
      return
    end
    local snapshot = capture_snapshot(leader)
    if not snapshot then
      player.print({ "platform-groups.copy-failed", leader.name })
      return
    end
    snapshot.key = key
    snapshot.leader_index = leader.index
    snapshot.leader_name = leader.name
    snapshot.tick = game.tick
    storage.loaded_build[player.index] = snapshot
    player.print({ "platform-groups.copy-loaded", leader.name, #platforms - 1 })
    populate(player, true)
    return
  end

  storage.loaded_build[player.index] = nil
  local copied, ghosts = 0, 0
  for _, platform in ipairs(platforms) do
    if platform.index ~= loaded.leader_index and platform.valid then
      ghosts = ghosts + apply_snapshot(platform, loaded, player)
      copied = copied + 1
    end
  end
  player.print({ "platform-groups.copied", loaded.leader_name, copied, ghosts })
  populate(player, true)
end

local function open_interrupts(player, key)
  local old = player.gui.screen[INTERRUPTS]
  if old then
    old.destroy()
  end

  local platforms = group_platforms(player, key)
  local counts, order = {}, {}
  for _, platform in ipairs(platforms) do
    local schedule = platform.get_schedule()
    if schedule then
      local seen = {}
      for i = 1, schedule.interrupt_count do
        local name = schedule.get_interrupt(i).name
        if not seen[name] then
          seen[name] = true
          if not counts[name] then
            counts[name] = 0
            order[#order + 1] = name
          end
          counts[name] = counts[name] + 1
        end
      end
    end
  end
  table.sort(order)

  local window = player.gui.screen.add({ type = "frame", name = INTERRUPTS, direction = "vertical" })
  local main = player.gui.screen[WINDOW]
  local location = saved_location(player, INTERRUPTS)
  if location then
    window.location = location
  elseif main and main.location then
    window.location = { main.location.x + math.floor(400 * player.display_scale), main.location.y }
  else
    window.auto_center = true
  end

  local bar = window.add({ type = "flow", direction = "horizontal" })
  bar.drag_target = window
  bar.add({ type = "label", style = "frame_title", caption = { "platform-groups.interrupts-title" }, ignored_by_interaction = true })
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  bar.add({ type = "sprite-button", style = "frame_action_button", sprite = "utility/close", tags = { pg_action = "close_interrupts" } })

  local content = window.add({ type = "frame", style = "inside_shallow_frame", direction = "vertical" })
  local scroll = content.add({ type = "scroll-pane", direction = "vertical" })
  scroll.style.minimal_width = 260
  scroll.style.maximal_height = math.floor(player.display_resolution.height / player.display_scale * 0.6)
  scroll.add({
    type = "button",
    caption = { "platform-groups.cancel-stops" },
    tooltip = { "platform-groups.cancel-stops-tooltip" },
    tags = { pg_action = "cancel_stops", group = key },
  })
  if #order == 0 then
    scroll.add({ type = "label", caption = { "platform-groups.no-interrupts" } })
  end
  for _, name in ipairs(order) do
    scroll.add({
      type = "button",
      style = "list_box_item",
      caption = { "", name, " (", counts[name], "/", #platforms, ")" },
      tags = { pg_action = "activate_interrupt", group = key, interrupt = name },
    })
  end
end

-- Removes the temporary stops (added by activated interrupts or by the planet picker) from each platform's list.
local function cancel_temporary_stops(player, key)
  local removed = 0
  for _, platform in ipairs(group_platforms(player, key)) do
    local schedule = platform.valid and platform.get_schedule()
    local records = schedule and schedule.get_records()
    if records then
      for i = #records, 1, -1 do
        if records[i].temporary or records[i].created_by_interrupt then
          schedule.remove_record({ schedule_index = i })
          removed = removed + 1
        end
      end
    end
  end
  player.print({ "platform-groups.cancelled-stops", removed })
end

local function activate_interrupt(player, key, name)
  local activated = 0
  for _, platform in ipairs(group_platforms(player, key)) do
    local schedule = platform.valid and platform.get_schedule()
    if schedule then
      for i = 1, schedule.interrupt_count do
        if schedule.get_interrupt(i).name == name then
          schedule.activate_interrupt(i)
          activated = activated + 1
          break
        end
      end
    end
  end
  player.print({ "platform-groups.activated", name, activated })
end

local function toggle(player)
  local existing = player.gui.screen[WINDOW]
  if existing then
    existing.destroy()
    drop_loaded_build(player)
    if player.gui.screen[INTERRUPTS] then
      player.gui.screen[INTERRUPTS].destroy()
    end
    return
  end

  local window = player.gui.screen.add({ type = "frame", name = WINDOW, direction = "vertical" })
  local location = saved_location(player, WINDOW)
  if location then
    window.location = location
  else
    window.auto_center = true
  end

  local bar = window.add({ type = "flow", direction = "horizontal" })
  bar.drag_target = window
  bar.add({ type = "label", style = "frame_title", caption = { "platform-groups.title" }, ignored_by_interaction = true })
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  bar.add({ type = "sprite-button", style = "frame_action_button", sprite = "utility/close", tags = { pg_action = "close" } })

  local content = window.add({ type = "frame", name = "content", style = "inside_shallow_frame", direction = "vertical" })
  local scroll = content.add({ type = "scroll-pane", name = "list", direction = "vertical" })
  scroll.style.minimal_width = 320
  scroll.style.maximal_height = math.floor(player.display_resolution.height / player.display_scale * 0.6)

  populate(player, true)
  player.opened = window
end

local function ensure_button(player)
  if not player.gui.top[BUTTON] then
    player.gui.top.add({
      type = "sprite-button",
      name = BUTTON,
      style = "slot_button",
      sprite = "item/space-platform-hub",
      tooltip = { "platform-groups.title" },
    })
  end
end

script.on_event(defines.events.on_gui_location_changed, function(event)
  local name = event.element.name
  if name ~= WINDOW and name ~= INTERRUPTS then
    return
  end
  storage.locations = storage.locations or {}
  storage.locations[event.player_index] = storage.locations[event.player_index] or {}
  storage.locations[event.player_index][name] = event.element.location
end)

script.on_event(defines.events.on_player_created, function(event)
  ensure_button(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  ensure_button(game.get_player(event.player_index))
end)

script.on_event("platform-groups-toggle", function(event)
  toggle(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if event.element and event.element.name == WINDOW then
    event.element.destroy()
    drop_loaded_build(game.get_player(event.player_index))
    local interrupts = game.get_player(event.player_index).gui.screen[INTERRUPTS]
    if interrupts then
      interrupts.destroy()
    end
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local element = event.element
  local tags = element.tags
  local action = tags and tags.pg_action
  if (action ~= "send" and action ~= "launch") or not element.elem_value then
    return
  end
  local player = game.get_player(event.player_index)
  local location = element.elem_value
  element.elem_value = nil

  if action == "launch" then
    launch_platform(player, tags.group, location)
    return
  end

  local group = find_group(build_groups(player.force), tags.group)
  if not group then
    return
  end
  local sent = 0
  for _, platform in ipairs(collect_platforms(group, {})) do
    if platform.valid and send_to_location(platform, location) then
      sent = sent + 1
    end
  end
  player.print({ "platform-groups.sent", sent, "[space-location=" .. location .. "]" })
end)

script.on_event(defines.events.on_gui_click, function(event)
  local player = game.get_player(event.player_index)
  local element = event.element
  if element.name == BUTTON then
    toggle(player)
    return
  end

  local tags = element.tags
  local action = tags and tags.pg_action
  if action == "copy_build" then
    copy_build(player, tags.group, event.button == defines.mouse_button_type.right)
  elseif action == "interrupts" then
    open_interrupts(player, tags.group)
  elseif action == "close_interrupts" then
    player.gui.screen[INTERRUPTS].destroy()
  elseif action == "cancel_stops" then
    cancel_temporary_stops(player, tags.group)
  elseif action == "activate_interrupt" then
    activate_interrupt(player, tags.group, tags.interrupt)
  elseif action == "close" then
    toggle(player)
  elseif action == "toggle" then
    local collapsed = storage.collapsed[player.index] or {}
    collapsed[tags.group] = not collapsed[tags.group] or nil
    storage.collapsed[player.index] = collapsed
    populate(player, true)
  elseif action == "open" then
    local platform = player.force.platforms[tags.platform_index]
    if platform and platform.valid then
      local hub = platform.hub
      player.set_controller({
        type = defines.controllers.remote,
        surface = platform.surface,
        position = hub and hub.valid and hub.position or { 0, 0 },
      })
    end
  end
end)

-- set_surface_hidden had no visible effect on platforms; undo what earlier versions set.
local function unhide_platform_surfaces()
  for _, force in pairs(game.forces) do
    for _, platform in pairs(force.platforms) do
      if platform.valid and platform.surface.valid then
        force.set_surface_hidden(platform.surface, false)
      end
    end
  end
end

script.on_nth_tick(60, function()
  finish_pending_launches()
  for player_index, loaded in pairs(storage.loaded_build or {}) do
    if game.tick - loaded.tick >= LOADED_BUILD_TTL then
      storage.loaded_build[player_index] = nil
    end
  end
  if not storage.surfaces_unhidden then
    unhide_platform_surfaces()
    storage.surfaces_unhidden = true
  end
  for _, player in pairs(game.connected_players) do
    if player.gui.screen[WINDOW] then
      populate(player)
    end
  end
end)
