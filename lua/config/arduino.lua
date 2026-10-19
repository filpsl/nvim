-- Integração Arduino via arduino-cli.
-- O sketch.yaml de cada sketch é a fonte da verdade (placa e porta): o LSP,
-- a compilação e o upload leem dele. É o mesmo arquivo que o
-- `arduino-cli board attach` escreve.

local M = {}

-- Placa usada pelo LSP enquanto o sketch não tem sketch.yaml: a primeira destas
-- cujo core está instalado (cada máquina pode ter cores diferentes)
M.default_fqbn = vim.g.arduino_default_fqbn
if not M.default_fqbn then
  for _, fqbn in ipairs({ "esp32:esp32:esp32", "arduino:avr:uno" }) do
    local vendor, arch = fqbn:match("^([^:]+):([^:]+)")
    if vim.fn.isdirectory(vim.fn.expand(("~/.arduino15/packages/%s/hardware/%s"):format(vendor, arch))) == 1 then
      M.default_fqbn = fqbn
      break
    end
  end
  M.default_fqbn = M.default_fqbn or "arduino:avr:uno"
end
M.default_baud = 115200

-- arduino-language-server 0.7.7 com dois patches: textDocument/references (o `gr`),
-- que o upstream não implementa, e posições em UTF-16 ao aplicar edições (sem isso,
-- editar depois de um acento dessincroniza o LS e o clangd passa a responder
-- "trying to get AST for non-added document"). Os patches estão em arduino/patches/
-- e arduino/setup.sh baixa, aplica, compila e instala (junto com o arduino-cli).
M.ls_bin = vim.fn.expand("~/.local/bin/arduino-language-server")
M.setup_script = vim.fn.stdpath("config") .. "/arduino/setup.sh"

local build_term, monitor_term, last_dir
local warned = {} ---@type table<string, boolean> sketches já avisados de que estão sem placa
local setup_warned = false

---@param buf? integer
---@return string? dir pasta do sketch (a que contém o .ino)
function M.sketch_dir(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].filetype ~= "arduino" or name == "" then
    return last_dir -- comando chamado do terminal de saída, de um .h/.cpp etc.
  end
  return vim.fs.dirname(name)
end

---@param dir string
---@return { fqbn?: string, port?: string }
function M.read_sketch_yaml(dir)
  local ok, lines = pcall(vim.fn.readfile, dir .. "/sketch.yaml")
  local res = {}
  if not ok then
    return res
  end
  for _, line in ipairs(lines) do
    local key, val = line:match("^(default_%w+):%s*(.-)%s*$")
    if val then
      val = val:gsub("^[\"'](.*)[\"']$", "%1")
      if key == "default_fqbn" and val ~= "" then
        res.fqbn = val
      elseif key == "default_port" and val ~= "" then
        res.port = val
      end
    end
  end
  return res
end

-- cmd do arduino_language_server: avaliado a cada start do servidor, então
-- trocar de placa e reiniciar o LSP já pega o sketch.yaml novo.
function M.lsp_cmd(dispatchers, config)
  local fqbn = config.root_dir and M.read_sketch_yaml(config.root_dir).fqbn or M.default_fqbn
  local cmd = { M.ls_bin, "-fqbn", fqbn }
  return vim.lsp.rpc.start(cmd, dispatchers, { cwd = config.cmd_cwd or config.root_dir, env = config.cmd_env })
end

---@param args string[]
---@param cb fun(data: table)
local function cli_json(args, cb)
  vim.system(vim.list_extend({ "arduino-cli" }, vim.list_extend(args, { "--format", "json" })), { text = true }, function(r)
    vim.schedule(function()
      local ok, data = pcall(vim.json.decode, r.stdout or "")
      if r.code ~= 0 or not ok then
        vim.notify("arduino-cli " .. table.concat(args, " ") .. " falhou:\n" .. (r.stderr or ""), vim.log.levels.ERROR)
        return
      end
      cb(data)
    end)
  end)
end

local function restart_lsp()
  if #vim.lsp.get_clients({ name = "arduino_language_server" }) > 0 then
    vim.cmd("LspRestart arduino_language_server")
  end
end

---@param dir string
---@param args string[] argumentos extras do `arduino-cli board attach`
---@param cb? fun()
local function attach(dir, args, cb)
  local cmd = vim.list_extend({ "arduino-cli", "board", "attach" }, args)
  table.insert(cmd, dir)
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        vim.notify("Falha ao salvar sketch.yaml:\n" .. (r.stderr or ""), vim.log.levels.ERROR)
        return
      end
      if cb then
        cb()
      end
    end)
  end)
end

---@param cb? fun(fqbn: string)
function M.choose_board(cb)
  local dir = M.sketch_dir()
  if not dir then
    return
  end
  local current = M.read_sketch_yaml(dir).fqbn
  cli_json({ "board", "listall" }, function(data)
    local boards = data.boards or {}
    table.sort(boards, function(a, b)
      return a.fqbn < b.fqbn
    end)
    vim.ui.select(boards, {
      prompt = "Placa" .. (current and (" (atual: " .. current .. ")") or ""),
      format_item = function(b)
        return ("%s  [%s]"):format(b.name, b.fqbn)
      end,
    }, function(board)
      if not board then
        return
      end
      attach(dir, { "-b", board.fqbn }, function()
        vim.notify("Placa: " .. board.name .. " [" .. board.fqbn .. "]\nsalva em sketch.yaml")
        restart_lsp()
        if cb then
          cb(board.fqbn)
        end
      end)
    end)
  end)
end

-- Opções da placa (Partition Scheme, Upload Speed, PSRAM...), gravadas no FQBN
function M.choose_board_option()
  local dir = M.sketch_dir()
  if not dir then
    return
  end
  local fqbn = M.read_sketch_yaml(dir).fqbn
  if not fqbn then
    return M.choose_board()
  end
  local base, opts_str = fqbn:match("^([^:]+:[^:]+:[^:]+):?(.*)$")
  local chosen = {} ---@type table<string, string>
  for kv in opts_str:gmatch("[^,]+") do
    local k, v = kv:match("^(.-)=(.*)$")
    if k then
      chosen[k] = v
    end
  end
  cli_json({ "board", "details", "-b", fqbn }, function(data)
    local options = data.config_options or {}
    if #options == 0 then
      return vim.notify("Essa placa não tem opções configuráveis")
    end
    local function selected(opt)
      for _, v in ipairs(opt.values) do
        if (chosen[opt.option] or (v.selected and v.value)) == v.value then
          return v
        end
      end
      return opt.values[1]
    end
    vim.ui.select(options, {
      prompt = "Opção da placa",
      format_item = function(opt)
        return ("%s: %s"):format(opt.option_label, selected(opt).value_label)
      end,
    }, function(opt)
      if not opt then
        return
      end
      vim.ui.select(opt.values, {
        prompt = opt.option_label,
        format_item = function(v)
          return v.value_label
        end,
      }, function(v)
        if not v then
          return
        end
        chosen[opt.option] = v.value
        local parts = {}
        for _, o in ipairs(options) do
          if chosen[o.option] then
            table.insert(parts, o.option .. "=" .. chosen[o.option])
          end
        end
        local new = base .. ":" .. table.concat(parts, ",")
        attach(dir, { "-b", new }, function()
          vim.notify(opt.option_label .. ": " .. v.value_label .. "\n" .. new)
          restart_lsp()
        end)
      end)
    end)
  end)
end

---@param cb fun(ports: table[])
local function detected_ports(cb)
  cli_json({ "board", "list" }, function(data)
    cb(data.detected_ports or {})
  end)
end

local function port_label(p)
  local label = p.port.address
  local boards = vim.tbl_map(function(b)
    return b.name
  end, p.matching_boards or {})
  local desc = #boards > 0 and table.concat(boards, ", ") or p.port.protocol_label or ""
  return desc ~= "" and (label .. "  (" .. desc .. ")") or label
end

---@param save boolean grava a porta como default_port no sketch.yaml
---@param cb? fun(port: string)
function M.choose_port(save, cb)
  local dir = M.sketch_dir()
  detected_ports(function(ports)
    if #ports == 0 then
      return vim.notify("Nenhuma porta encontrada. A placa está conectada?", vim.log.levels.WARN)
    end
    local function done(p)
      local addr = p.port.address
      if save and dir then
        attach(dir, { "-p", addr }, function()
          vim.notify("Porta " .. addr .. " salva em sketch.yaml")
        end)
      end
      if cb then
        cb(addr)
      end
    end
    if #ports == 1 and not save then
      return done(ports[1])
    end
    vim.ui.select(ports, { prompt = "Porta", format_item = port_label }, function(p)
      if p then
        done(p)
      end
    end)
  end)
end

-- Porta para upload/monitor: a do sketch.yaml se ainda existir; senão a única
-- detectada; senão pergunta.
---@param cb fun(port: string)
local function resolve_port(cb)
  local dir = M.sketch_dir()
  local port = dir and M.read_sketch_yaml(dir).port
  if port and (not port:match("^/dev/") or vim.uv.fs_stat(port)) then
    return cb(port)
  end
  M.choose_port(false, cb)
end

---@param cb fun(dir: string, fqbn: string)
local function with_board(cb)
  local dir = M.sketch_dir()
  if not dir then
    return
  end
  -- salva as abas do sketch antes de compilar, como o IDE faz
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].modified and vim.fs.dirname(vim.api.nvim_buf_get_name(b)) == dir then
      vim.api.nvim_buf_call(b, function()
        vim.cmd("silent update")
      end)
    end
  end
  local fqbn = M.read_sketch_yaml(dir).fqbn
  if fqbn then
    return cb(dir, fqbn)
  end
  vim.notify("Escolha a placa deste sketch (fica salva no sketch.yaml)")
  M.choose_board(function(new)
    cb(dir, new)
  end)
end

local function stop_monitor()
  if monitor_term and monitor_term:buf_valid() then
    pcall(vim.fn.jobstop, vim.b[monitor_term.buf].terminal_job_id)
    monitor_term:close()
  end
  monitor_term = nil
end

-- Os painéis abrem sem foco (o cursor fica no código), e terminal sem foco não
-- rola sozinho: mantém o cursor dele na última linha enquanto chega saída.
local function follow(term)
  local pending = false
  vim.api.nvim_buf_attach(term.buf, false, {
    on_lines = function()
      if pending then
        return
      end
      pending = true
      vim.schedule(function()
        pending = false
        if term:win_valid() and vim.api.nvim_get_current_win() ~= term.win then
          vim.api.nvim_win_set_cursor(term.win, { vim.api.nvim_buf_line_count(term.buf), 0 })
        end
      end)
    end,
  })
end

---@param cmd string[]
---@param dir string
---@param title string
---@param on_ok? fun()
local function run(cmd, dir, title, on_ok)
  if build_term and build_term:buf_valid() then
    build_term:close()
  end
  build_term = Snacks.terminal.open(cmd, {
    cwd = dir,
    interactive = false,
    auto_close = false,
    win = { position = "bottom", height = 0.3, enter = false, wo = { winbar = " " .. title } },
  })
  follow(build_term)
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = build_term.buf,
    once = true,
    callback = function()
      local code = vim.v.event.status
      vim.schedule(function()
        if code == 0 then
          vim.notify(title .. ": concluído")
          if on_ok then
            on_ok()
          end
        else
          vim.notify(title .. ": falhou (código " .. code .. ")", vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

function M.verify()
  with_board(function(dir, fqbn)
    run({ "arduino-cli", "compile", "-b", fqbn, dir }, dir, "Compilar " .. fqbn)
  end)
end

---@param then_monitor? boolean
function M.upload(then_monitor)
  with_board(function(dir, fqbn)
    resolve_port(function(port)
      stop_monitor() -- o monitor segura a porta serial
      run({ "arduino-cli", "compile", "-u", "-b", fqbn, "-p", port, dir }, dir, "Upload " .. fqbn .. " → " .. port, function()
        if then_monitor then
          M.monitor(port)
        end
      end)
    end)
  end)
end

local function sketch_baud(dir)
  for _, file in ipairs(vim.fn.glob(dir .. "/*.ino", false, true)) do
    for _, line in ipairs(vim.fn.readfile(file)) do
      local baud = line:match("Serial%.begin%s*%(%s*(%d+)")
      if baud then
        return tonumber(baud)
      end
    end
  end
  return M.default_baud
end

---@param port? string
function M.monitor(port)
  local dir = M.sketch_dir() or vim.fn.getcwd()
  local function open(p)
    stop_monitor()
    local baud = sketch_baud(dir)
    monitor_term = Snacks.terminal.open({ "arduino-cli", "monitor", "-p", p, "--config", "baudrate=" .. baud }, {
      cwd = dir,
      auto_close = false,
      win = { position = "bottom", height = 0.3, enter = false, wo = { winbar = (" Serial %s @ %d"):format(p, baud) } },
    })
    follow(monitor_term)
  end
  if port then
    open(port)
  else
    resolve_port(open)
  end
end

function M.info()
  local dir = M.sketch_dir()
  if not dir then
    return
  end
  local y = M.read_sketch_yaml(dir)
  vim.notify(table.concat({
    "Sketch: " .. dir,
    "Placa:  " .. (y.fqbn or ("(não definida — LSP usando " .. M.default_fqbn .. ")")),
    "Porta:  " .. (y.port or "(automática)"),
    "Baud:   " .. sketch_baud(dir),
  }, "\n"))
end

---@param buf integer
function M.on_buffer(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
  end
  map("<leader>av", M.verify, "Compilar (verify)")
  map("<leader>au", function() M.upload(false) end, "Upload")
  map("<leader>aU", function() M.upload(true) end, "Upload + monitor serial")
  map("<leader>am", function() M.monitor() end, "Monitor serial")
  map("<leader>ab", function() M.choose_board() end, "Escolher placa")
  map("<leader>ao", M.choose_board_option, "Opções da placa")
  map("<leader>ap", function() M.choose_port(true) end, "Escolher porta")
  map("<leader>ai", M.info, "Info do sketch")
  pcall(function()
    require("which-key").add({ { "<leader>a", group = "arduino", buffer = buf } })
  end)

  local dir = M.sketch_dir(buf)
  last_dir = dir
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("arduino_buf_" .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      last_dir = M.sketch_dir(buf)
    end,
  })
  if not dir then
    return
  end
  if not setup_warned and (vim.fn.executable(M.ls_bin) == 0 or vim.fn.executable("arduino-cli") == 0) then
    setup_warned = true
    vim.notify(
      "Arduino: falta o arduino-cli ou o arduino-language-server nesta máquina.\nRode " .. M.setup_script,
      vim.log.levels.WARN
    )
    return
  end
  if not warned[dir] and not M.read_sketch_yaml(dir).fqbn then
    warned[dir] = true
    vim.notify(
      ("Sketch sem placa definida: o LSP vai usar %s.\nUse <leader>ab para escolher a placa."):format(M.default_fqbn),
      vim.log.levels.WARN
    )
  end
  -- O LSP só mapeia as abas abertas no editor: carrega (sem listar) as outras
  -- abas .ino do sketch, como o IDE faz, para o `gr` achar referências nelas.
  -- Agendado porque aqui ainda estamos dentro do FileType.
  vim.schedule(function()
    for _, file in ipairs(vim.fn.glob(dir .. "/*.ino", false, true)) do
      local b = vim.fn.bufadd(file)
      if not vim.api.nvim_buf_is_loaded(b) then
        vim.fn.bufload(b)
      end
    end
  end)
end

for name, fn in pairs({
  ArduinoVerify = M.verify,
  ArduinoUpload = function() M.upload(false) end,
  ArduinoUploadMonitor = function() M.upload(true) end,
  ArduinoMonitor = function() M.monitor() end,
  ArduinoBoard = function() M.choose_board() end,
  ArduinoBoardOptions = M.choose_board_option,
  ArduinoPort = function() M.choose_port(true) end,
  ArduinoInfo = M.info,
}) do
  vim.api.nvim_create_user_command(name, fn, {})
end

return M
