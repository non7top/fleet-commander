local WINDOW = "platform_groups_window"
local BUTTON = "platform_groups_button"
local INTERRUPTS = "platform_groups_interrupts"
local UNGROUPED = "<ungrouped>"

local function init_storage()
  storage.collapsed = storage.collapsed or {}
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

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

local function location_text(platform)
  local loc = platform.space_location
  if loc then
    return "[space-location=" .. loc.name .. "]"
  end
  local conn = platform.space_connection
  if conn then
    -- conn.from/to is the prototype's fixed ordering, not the travel direction.
    local origin = platform.last_visited_space_location
    local from, to = conn.from.name, conn.to.name
    if origin and origin.name == to then
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

-- Adds a temporary stop right after the current record and heads there; the platform then resumes its schedule.
local function send_to_location(platform, location)
  local schedule = platform.get_schedule()
  if not schedule then
    return false
  end
  local current = schedule.current or 0
  local index = schedule.add_record({
    station = location,
    temporary = true,
    index = { schedule_index = current + 1 },
  })
  if not index then
    return false
  end
  schedule.go_to_station(index)
  return true
end

local function signature(player)
  local parts = {}
  for _, platform in pairs(player.force.platforms) do
    parts[#parts + 1] = platform.index .. platform.name .. location_text(platform)
  end
  table.sort(parts)
  parts[#parts + 1] = helpers.table_to_json(storage.collapsed[player.index] or {})
  return table.concat(parts, "\n")
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

  local function add_header(parent, group, title, count, indent)
    local is_collapsed = collapsed[group.key]
    local row = parent.add({ type = "flow", direction = "horizontal" })
    row.style.left_margin = indent
    row.style.vertical_align = "center"
    row.add({
      type = "button",
      style = "list_box_item",
      caption = { "", is_collapsed and "▸ " or "▾ ", title, " (", count, ")" },
      tags = { pg_action = "toggle", group = group.key },
    })
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
    return not is_collapsed
  end

  local function add_rows(members, indent)
    local rows = list.add({ type = "table", column_count = 2 })
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
  if main and main.location then
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
    if player.gui.screen[INTERRUPTS] then
      player.gui.screen[INTERRUPTS].destroy()
    end
    return
  end

  local window = player.gui.screen.add({ type = "frame", name = WINDOW, direction = "vertical" })
  window.auto_center = true

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
    local interrupts = game.get_player(event.player_index).gui.screen[INTERRUPTS]
    if interrupts then
      interrupts.destroy()
    end
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local element = event.element
  local tags = element.tags
  if not (tags and tags.pg_action == "send") or not element.elem_value then
    return
  end
  local player = game.get_player(event.player_index)
  local location = element.elem_value
  element.elem_value = nil

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
  if action == "interrupts" then
    open_interrupts(player, tags.group)
  elseif action == "close_interrupts" then
    player.gui.screen[INTERRUPTS].destroy()
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
