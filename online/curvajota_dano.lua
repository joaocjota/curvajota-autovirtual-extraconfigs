-- Curva Jota: dano online (CSP). Carros amassam onde batem, e TODO MUNDO no servidor vê o mesmo amassado.
--
-- Por que um script online: um app Lua comum (como os de dano "soft body") só funciona offline. Online o CSP não deixa app
-- mexer na física, os carros dos outros não têm física no seu PC (a batida deles chega pela rede, só a posição) e o
-- amassado só existiria no PC de quem instalou o app. Este script vem do servidor ([SCRIPT_...] nas opções extras do
-- CSP), roda em todo PC sem instalar nada e sincroniza as batidas:
--   1) cada PC mede só a batida do PRÓPRIO carro (o único que tem física real ali): enquanto há contato soma a mudança de
--      velocidade e o ponto de contato; quando o contato acaba vira uma "batida" (ponto, sentido e força, no espaço do carro);
--   2) a batida vai para todos numa mensagem curta (ac.OnlineEvent, 15 bytes); cada PC amassa aquele carro do mesmo jeito
--      (o sorteio das dobras sai da própria batida, então é igual em todo PC);
--   3) a cada mudança o carro manda também um RESUMO (as batidas mais fortes) que o servidor repete para quem entrar depois;
--   4) voltar aos boxes, reiniciar ou teleportar devolve a forma original, em todos os PCs;
--   5) faíscas na batida e fumaça quando o carro está muito batido (só efeito visual, de cada PC).
-- Offline (treino com IA) o script mede a batida de todos os carros direto, sem mensagens.
--
-- Só visual: o collider e a física do AC não mudam (o dano mecânico continua sendo o do AC/servidor). Opcional: quebrar
-- a suspensão do próprio carro numa batida forte perto da roda, se o CSP deixar (physics.allowed(); vai no log).
-- Carros com dano próprio (ex.: CJT-500 Adsumus, que tem p500_dano.lua) ficam de fora pelo nome da pasta (ajuste 'pular').
-- Escrito do zero pela Curva Jota; o método de amassado é o do p500_dano.lua do Adsumus (aprovado v0.9.33).
-- Ajustes na seção [SCRIPT_...] do servidor (valores abaixo são o padrão).

local cfg = ac.configValues({
  minKmh = 7,               -- perda de velocidade mínima numa batida para amassar (km/h)
  profundidade = 0.0024,    -- afundamento (m) por km/h acima do mínimo
  maxAmassado = 0.12,       -- afundamento máximo de uma batida (m)
  maxTotal = 0.18,          -- deslocamento máximo acumulado de um ponto (m)
  raioMin = 0.22,           -- raio do amassado (m), cresce com a força até raioMax
  raioMax = 0.55,
  raioKmh = 80,
  ondulacao = 0.35,         -- dobras da lata (fração do afundamento)
  distancia = 300,          -- só lê/amassa malhas de carros até esta distância da câmera (o resto fica guardado)
  pular = 'cj_kwid_p500',   -- trechos do nome da pasta de carros que NÃO entram (separados por vírgula; vazio = todos)
  faiscas = 1,
  fumaca = 1,
  fumacaKmh = 140,          -- soma das batidas (km/h) a partir da qual o carro solta fumaça
  suspensao = 0,            -- 1 = batida forte perto da roda quebra a suspensão do próprio carro (se o CSP deixar)
  suspensaoKmh = 50,
  log = 1,
})

local function log(...)
  if cfg.log ~= 1 then return end
  local t = {}
  for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
  pcall(ac.log, '[CJ_DANO] ' .. table.concat(t, ' '))
end
local errCount = 0
local traceback = (debug and debug.traceback) or function(e) return e end
local function safe(where, fn, ...)
  local args, n = { ... }, select('#', ...)
  local ok, err = xpcall(function() return fn((table.unpack or unpack)(args, 1, n)) end, traceback)
  if not ok then
    errCount = errCount + 1
    if errCount <= 15 then log('ERRO em ' .. where .. ':', (tostring(err):gsub('\n%s*', ' | '):sub(1, 600))) end
  end
  return ok, err
end

local MAX_RESUMO = 10       -- batidas guardadas no resumo para quem entra depois
local CONTACT_SLICE = 0.12  -- contato longo (raspando) vira uma batida a cada 0,12 s
local SEND_GAP = 0.25       -- servidor AC comum: no mínimo 200 ms entre mensagens
local RESUMO_GAP = 2.0

-- partes que não amassam: rodas, suspensão, volante, piloto, cockpit, câmbio, cintos
local EXCLUIR = { 'WHEEL_?', 'SUSP_?', 'HUB_?', 'DISC_?', 'STEER_?', 'DRIVER?', 'COCKPIT_?', 'CINTURE_?', 'SHIFT?', 'RIM_?',
  'TYRE_?', 'BRAKE_?' }

local pularLista = {}
for p in tostring(cfg.pular or ''):gmatch('[^,%s]+') do pularLista[#pularLista + 1] = p:lower() end

local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

-- ------------------------------------------------------------------ estado por carro
local C = {}   -- índice do carro -> estado

local function carState(i)
  local s = C[i]
  if s then return s end
  local id = (ac.getCarID(i) or ''):lower()
  s = { index = i, id = id, skip = false, meshes = nil, hits = {}, applied = 0, total = 0, front = 0, rear = 0,
    lastPos = nil, resetCounter = nil, smokeT = 0 }
  for _, p in ipairs(pularLista) do if id:find(p, 1, true) then s.skip = true end end
  if not s.skip then
    local ok, root = pcall(ac.findNodes, 'carRoot:' .. i)
    if ok and root ~= nil and root:size() > 0 then s.root = root else s.skip = true end
  end
  C[i] = s
  if s.skip then log('carro', i, id, 'fica de fora') end
  return s
end

-- ------------------------------------------------------------------ malhas
local function meshWorld(ref)
  local w = ref:getWorldTransformationRaw()
  if w == nil then
    local p = ref:getParent()
    w = p and p:getWorldTransformationRaw()
  end
  return w
end

local function meshKey(list, i)
  local ref = list:at(i, true)
  local c, r = ref:boundingSphere(1)
  if c == nil then return nil end
  return tostring(list:name(i)) .. '@' .. string.format('%.3f,%.3f,%.3f', c.x, c.y, c.z), ref, c, r
end

local function collectMeshes(s)
  s.meshes = {}
  local fora = {}
  for _, pat in ipairs(EXCLUIR) do
    local nodes = s.root:findNodes(pat)
    for k = 1, nodes:size() do
      local l = nodes:at(k):findMeshes('?')
      for i = 1, l:size() do local key = meshKey(l, i) if key then fora[key] = true end end
    end
  end
  local list = s.root:findMeshes('{ lod:A & renderable:yes }')
  if list:size() == 0 then list = s.root:findMeshes('?') end
  local seen = {}
  for i = 1, list:size() do
    safe('coleta', function()
      local key, ref, c, r = meshKey(list, i)
      if key == nil or fora[key] or seen[key] then return end
      seen[key] = true
      s.meshes[#s.meshes + 1] = { ref = ref, name = tostring(list:name(i)), sc = c:clone(), sr = r }
    end)
  end
  log('carro', s.index, s.id, 'malhas:', #s.meshes, 'fora:', (function() local n = 0 for _ in pairs(fora) do n = n + 1 end return n end)())
end

local function load(m)
  if m.vb ~= nil then return m.vb ~= false end
  local ok, vb = pcall(m.ref.getVertices, m.ref)
  if not ok or vb == nil or #vb == 0 then m.vb = false return false end
  local n = #vb
  local p0, n0, d, cn, dirty = {}, {}, {}, {}, {}
  for i = 0, n - 1 do
    local v = vb:get(i + 1)
    local j = 3 * i
    p0[j], p0[j + 1], p0[j + 2] = v.pos.x, v.pos.y, v.pos.z
    n0[j], n0[j + 1], n0[j + 2] = v.normal.x, v.normal.y, v.normal.z
    d[j], d[j + 1], d[j + 2] = 0, 0, 0
    cn[j], cn[j + 1], cn[j + 2] = 0, 0, 0
    dirty[i] = 0
  end
  m.vb, m.n, m.p0, m.n0, m.d, m.cn, m.dirty = vb, n, p0, n0, d, cn, dirty
  return true
end

local function upload(m)
  local p0, n0, d, cn, dirty, vb = m.p0, m.n0, m.d, m.cn, m.dirty, m.vb
  for i = 0, m.n - 1 do
    if dirty[i] ~= 0 then
      dirty[i] = 0
      local j = 3 * i
      local v = vb:get(i + 1)
      v.pos.x, v.pos.y, v.pos.z = p0[j] + d[j], p0[j + 1] + d[j + 1], p0[j + 2] + d[j + 2]
      local nx, ny, nz = n0[j] + cn[j], n0[j + 1] + cn[j + 1], n0[j + 2] + cn[j + 2]
      local L = math.sqrt(nx * nx + ny * ny + nz * nz)
      if L > 1e-6 then v.normal.x, v.normal.y, v.normal.z = nx / L, ny / L, nz / L end
      vb:set(i + 1, v)
    end
  end
  m.ref:alterVertices(vb)
end

-- ------------------------------------------------------------------ amassado
-- sorteio determinístico: a mesma batida dá as mesmas dobras em todo PC
local function rng(h)
  local seed = h % 2147483648
  return function()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  end
end

local function perp(u, rnd)
  local a = vec3(rnd() - 0.5, rnd() - 0.5, rnd() - 0.5)
  a = a - u * a:dot(u)
  if #a < 1e-3 then a = vec3(0, 1, 0) end
  return a:normalize()
end

-- campo: g = prof * w * (1 + k * onda), w = (1 - r²/R²)², r esticado ao longo de t numa batida de quina;
-- desloca u * g e arrasta para o lado (t); normais corrigidas pelo gradiente do campo
local function dentMesh(m, c, u, t, lat, depth, R, a2, ph1, ph2)
  local R2 = R * R
  local S = 1 + 0.8 * lat
  local k1 = 1 - 1 / (S * S)
  local p0, n0, d, cn, dirty = m.p0, m.n0, m.d, m.cn, m.dirty
  local f, K = 26, cfg.ondulacao
  local sl = depth * 0.45 * lat
  local maxT = cfg.maxTotal
  local moved = 0
  for i = 0, m.n - 1 do
    local j = 3 * i
    local px, py, pz = p0[j] + d[j], p0[j + 1] + d[j + 1], p0[j + 2] + d[j + 2]
    local rx, ry, rz = px - c.x, py - c.y, pz - c.z
    local rt = rx * t.x + ry * t.y + rz * t.z
    local s2 = (rx * rx + ry * ry + rz * rz - k1 * rt * rt) / R2
    if s2 < 1 then
      moved = moved + 1
      local q = 1 - s2
      local w = q * q
      local A = f * rt + ph1
      local B = f * (px * a2.x + py * a2.y + pz * a2.z) + ph2
      local sA, cA, sB, cB = math.sin(A), math.cos(A), math.sin(B), math.cos(B)
      local wave = 1 + K * sA * sB
      local g = depth * w * wave
      local h = sl * w
      local kw = -4 * q / R2
      local gwx, gwy, gwz = kw * (rx - k1 * rt * t.x), kw * (ry - k1 * rt * t.y), kw * (rz - k1 * rt * t.z)
      local kc = depth * w * K * f
      local ggx = depth * wave * gwx + kc * (cA * sB * t.x + sA * cB * a2.x)
      local ggy = depth * wave * gwy + kc * (cA * sB * t.y + sA * cB * a2.y)
      local ggz = depth * wave * gwz + kc * (cA * sB * t.z + sA * cB * a2.z)
      local nx, ny, nz = n0[j] + cn[j], n0[j + 1] + cn[j + 1], n0[j + 2] + cn[j + 2]
      local un, tn = u.x * nx + u.y * ny + u.z * nz, t.x * nx + t.y * ny + t.z * nz
      cn[j] = cn[j] - un * ggx - tn * sl * gwx
      cn[j + 1] = cn[j + 1] - un * ggy - tn * sl * gwy
      cn[j + 2] = cn[j + 2] - un * ggz - tn * sl * gwz
      d[j] = d[j] + u.x * g + t.x * h
      d[j + 1] = d[j + 1] + u.y * g + t.y * h
      d[j + 2] = d[j + 2] + u.z * g + t.z * h
      local L = math.sqrt(d[j] * d[j] + d[j + 1] * d[j + 1] + d[j + 2] * d[j + 2])
      if L > maxT then
        local k = maxT / L
        d[j], d[j + 1], d[j + 2] = d[j] * k, d[j + 1] * k, d[j + 2] * k
      end
      dirty[i] = 1
    end
  end
  return moved
end

-- aplica uma batida (ponto c e sentido u no espaço do carro, força em km/h) às malhas do carro
local function applyHit(s, car, hit)
  local kmh = hit.kmh
  if kmh < cfg.minKmh then return end
  local rnd = rng(hit.h)
  local cModel, uModel = hit.p, hit.u
  local depth = math.min(cfg.maxAmassado, (kmh - cfg.minKmh) * cfg.profundidade)
  local R = cfg.raioMin + (cfg.raioMax - cfg.raioMin) * math.min(1, kmh / cfg.raioKmh)
  -- quanto a batida é de quina: parte do empurrão que corre pela superfície
  local inward = vec3(-cModel.x, (0.6 - cModel.y) * 0.3, -cModel.z)
  if #inward < 1e-3 then inward = uModel:clone() end
  inward:normalize()
  local tan = uModel - inward * uModel:dot(inward)
  local lat = math.min(1, #tan)
  local tModel
  if lat > 0.08 then tModel = tan:clone():normalize() else tModel = perp(uModel, rnd) lat = 0 end
  local a2 = perp(uModel, rnd)
  local ph1, ph2 = rnd() * 6.283, rnd() * 6.283
  if s.meshes == nil then collectMeshes(s) end
  local body = car.bodyTransform
  local cW, uW, tW, a2W = body:transformPoint(cModel), body:transformVector(uModel), body:transformVector(tModel), body:transformVector(a2)
  local reach = R * (1 + 0.8 * lat)
  local nMesh, nVert = 0, 0
  for _, m in ipairs(s.meshes) do
    safe('amassado', function()
      local mw = meshWorld(m.ref)
      if mw == nil then return end
      local inv = mw:inverse()
      local c = inv:transformPoint(cW)
      if (c - m.sc):length() < m.sr + reach and load(m) then
        local u, t = inv:transformVector(uW):normalize(), inv:transformVector(tW):normalize()
        local b2 = inv:transformVector(a2W):normalize()
        local mv = dentMesh(m, c, u, t, lat, depth, R, b2, ph1, ph2)
        if mv > 0 then m.touched = true nMesh = nMesh + 1 nVert = nVert + mv end
      end
    end)
  end
  for _, m in ipairs(s.meshes) do
    if m.touched then m.touched = false safe('gravar', upload, m) end
  end
  log(string.format('carro %d amassou %.0f km/h em (%.2f, %.2f, %.2f): %d malhas, %d vertices', s.index, kmh,
    cModel.x, cModel.y, cModel.z, nMesh, nVert))
end

local function restore(s, why)
  if s.meshes ~= nil then
    for _, m in ipairs(s.meshes) do
      if m.vb then safe('reparo', function()
        local p0, n0, vb = m.p0, m.n0, m.vb
        for i = 0, m.n - 1 do
          local j = 3 * i
          local v = vb:get(i + 1)
          v.pos.x, v.pos.y, v.pos.z = p0[j], p0[j + 1], p0[j + 2]
          v.normal.x, v.normal.y, v.normal.z = n0[j], n0[j + 1], n0[j + 2]
          vb:set(i + 1, v)
        end
        m.ref:alterVertices(vb)
      end) end
      m.vb, m.p0, m.n0, m.d, m.cn, m.dirty = nil
    end
  end
  if #s.hits > 0 then log('carro', s.index, 'reparado (' .. why .. ')') end
  s.hits, s.applied, s.total, s.front, s.rear = {}, 0, 0, 0, 0
end

-- ------------------------------------------------------------------ efeitos
local sparks = cfg.faiscas == 1 and ac.Particles.Sparks({ color = rgbm(1, 0.75, 0.4, 1), life = 1.2, size = 0.15,
  directionSpread = 0.9, positionSpread = 0.15 }) or nil
local smoke = cfg.fumaca == 1 and ac.Particles.Smoke({ color = rgbm(0.35, 0.35, 0.35, 0.5), colorConsistency = 0.5,
  thickness = 0.4, life = 3, size = 0.25, spreadK = 0.6, growK = 1.2, targetYVelocity = 1.2 }) or nil

local function hitEffects(s, car, hit)
  if sparks and car.distanceToCamera < 120 and hit.kmh >= 15 then
    local pW = car.bodyTransform:transformPoint(hit.p)
    local vW = car.velocity * 0.5 - car.bodyTransform:transformVector(hit.u) * 2 + vec3(0, 1.5, 0)
    pcall(sparks.emit, sparks, pW, vW, math.min(60, hit.kmh * 0.6))
  end
end

-- ------------------------------------------------------------------ batidas (registro, aplicação)
local function hitHash(px, py, pz, kmh)
  return ((px + 40000) * 1931 + (py + 40000) * 7919 + (pz + 40000) * 104729 + kmh * 15485863) % 2147483647
end

-- batida quantizada (é o que vai pela rede; todo PC usa os mesmos números)
local function makeHit(pcm, uq, kmh)
  return { p = vec3(pcm[1] / 100, pcm[2] / 100, pcm[3] / 100), u = vec3(uq[1], uq[2], uq[3]):normalize(), kmh = kmh,
    q = { pcm[1], pcm[2], pcm[3], uq[1], uq[2], uq[3], kmh }, h = hitHash(pcm[1], pcm[2], pcm[3], kmh) }
end

local function quantize(p, u, kmh)
  local pcm = { clamp(math.floor(p.x * 100 + 0.5), -32000, 32000), clamp(math.floor(p.y * 100 + 0.5), -32000, 32000),
    clamp(math.floor(p.z * 100 + 0.5), -32000, 32000) }
  local uq = { clamp(math.floor(u.x * 127 + 0.5), -127, 127), clamp(math.floor(u.y * 127 + 0.5), -127, 127),
    clamp(math.floor(u.z * 127 + 0.5), -127, 127) }
  if uq[1] == 0 and uq[2] == 0 and uq[3] == 0 then uq[3] = -127 end
  return makeHit(pcm, uq, clamp(math.floor(kmh + 0.5), 0, 255))
end

local function addHit(i, hit, fresh)
  local s = carState(i)
  if s.skip then return end
  s.hits[#s.hits + 1] = hit
  s.total = s.total + hit.kmh
  if hit.p.z > 0.3 then s.front = s.front + hit.kmh elseif hit.p.z < -0.3 then s.rear = s.rear + hit.kmh end
  local car = ac.getCar(i)
  if fresh and car then hitEffects(s, car, hit) end
end

local function applyPending(s, car)
  if s.applied >= #s.hits or car.distanceToCamera > cfg.distancia then return end
  for k = s.applied + 1, #s.hits do
    s.applied = k
    safe('batida', applyHit, s, car, s.hits[k])
  end
end

-- ------------------------------------------------------------------ rede
local sim = ac.getSim()
local online = sim.isOnlineRace
local sendHit, sendResumo = nil, nil
local outbox = {}
local sendT, resumoT, resumoDirty = 0, 0, false

local function resumoMsg(reset)
  local s = carState(0)
  -- as batidas mais fortes, em ordem de chegada
  local idx = {}
  for k = 1, #s.hits do idx[#idx + 1] = k end
  table.sort(idx, function(a, b) return s.hits[a].kmh > s.hits[b].kmh end)
  local keep = {}
  for k = 1, math.min(MAX_RESUMO, #idx) do keep[#keep + 1] = idx[k] end
  table.sort(keep)
  local msg = { n = #keep, reset = reset and 1 or 0 }
  return msg, keep, s
end

if online then
  local okE, err = pcall(function()
    sendHit = ac.OnlineEvent({
      ac.StructItem.key('cjDanoBatida1'),
      px = ac.StructItem.int16(), py = ac.StructItem.int16(), pz = ac.StructItem.int16(),
      ux = ac.StructItem.int8(), uy = ac.StructItem.int8(), uz = ac.StructItem.int8(),
      kmh = ac.StructItem.uint8(),
    }, function(sender, m)
      if sender == nil or sender.index == 0 then return end      -- a própria já foi aplicada
      addHit(sender.index, makeHit({ m.px, m.py, m.pz }, { m.ux, m.uy, m.uz }, m.kmh), true)
    end)
    sendResumo = ac.OnlineEvent({
      ac.StructItem.key('cjDanoResumo1'),
      n = ac.StructItem.uint8(), reset = ac.StructItem.uint8(),
      px = ac.StructItem.array(ac.StructItem.int16(), MAX_RESUMO),
      py = ac.StructItem.array(ac.StructItem.int16(), MAX_RESUMO),
      pz = ac.StructItem.array(ac.StructItem.int16(), MAX_RESUMO),
      ux = ac.StructItem.array(ac.StructItem.int8(), MAX_RESUMO),
      uy = ac.StructItem.array(ac.StructItem.int8(), MAX_RESUMO),
      uz = ac.StructItem.array(ac.StructItem.int8(), MAX_RESUMO),
      kmh = ac.StructItem.array(ac.StructItem.uint8(), MAX_RESUMO),
    }, function(sender, m)
      if sender == nil or sender.index == 0 then return end
      local s = carState(sender.index)
      if s.skip then return end
      -- reset = 1: o dono reparou o carro; o resumo traz as batidas de depois do reparo (substitui tudo)
      if m.reset == 1 then restore(s, 'aviso do dono')
      elseif #s.hits > 0 then return end                     -- já acompanha este carro: o resumo é para quem entrou depois
      for k = 0, math.min(m.n, MAX_RESUMO) - 1 do
        addHit(sender.index, makeHit({ m.px[k], m.py[k], m.pz[k] }, { m.ux[k], m.uy[k], m.uz[k] }, m.kmh[k]), false)
      end
      if m.n > 0 then log('carro', sender.index, 'resumo recebido:', m.n, 'batidas') end
    end)
  end)
  if not okE then log('ERRO ao criar mensagens online:', err) sendHit, sendResumo = nil, nil end
end

local function flushNet(dt)
  if not online then return end
  sendT, resumoT = sendT + dt, resumoT + dt
  if sendHit and #outbox > 0 and sendT >= SEND_GAP then
    local q = outbox[1].q
    local ok = sendHit({ px = q[1], py = q[2], pz = q[3], ux = q[4], uy = q[5], uz = q[6], kmh = q[7] })
    if ok then table.remove(outbox, 1) sendT = 0 end
  end
  if sendResumo and resumoDirty and resumoT >= RESUMO_GAP and sendT >= SEND_GAP and #outbox == 0 then
    local msg, keep, s = resumoMsg(resumoDirty == 'reset')
    do
      msg.px, msg.py, msg.pz, msg.ux, msg.uy, msg.uz, msg.kmh = {}, {}, {}, {}, {}, {}, {}
      for k, hk in ipairs(keep) do
        local q = s.hits[hk].q
        msg.px[k - 1], msg.py[k - 1], msg.pz[k - 1], msg.ux[k - 1], msg.uy[k - 1], msg.uz[k - 1], msg.kmh[k - 1] =
          q[1], q[2], q[3], q[4], q[5], q[6], q[7]
      end
    end
    if sendResumo(msg, true) then resumoDirty, resumoT, sendT = false, 0, 0 end
  end
end

-- ------------------------------------------------------------------ medição da batida (carros com física neste PC)
local function physicsAllowed()
  return physics ~= nil and physics.allowed ~= nil and physics.allowed()
end

local function breakSuspension(hit)
  if cfg.suspensao ~= 1 or hit.kmh < cfg.suspensaoKmh or not physicsAllowed() then return end
  -- roda mais perto (espaço do carro: X esquerda, Z frente); FL=4, FR=8, RL=16, RR=32
  local w = (hit.p.z >= 0 and 0 or 2) + (hit.p.x >= 0 and 0 or 1)
  if math.abs(hit.p.x) < 0.45 then return end
  pcall(physics.setSuspensionDamage, 0, 2 ^ (2 + w), hit.kmh)
  log('suspensao da roda', w, 'quebrada', hit.kmh, 'km/h')
end

local function localHit(i, s, car, acc)
  if acc.w <= 0 then return end
  local kmh = #acc.dv * 3.6
  local c = acc.pos / acc.w
  local inward = vec3(-c.x, (0.6 - c.y) * 0.3, -c.z)
  if #inward < 1e-3 then inward = vec3(0, 0, -1) end
  inward:normalize()
  local u = acc.dv:clone()
  if #u > 1e-4 then u:normalize() else u = inward:clone() end
  if u:dot(inward) < 0 then u = u * -1 end
  u = (u * 0.9 + inward * 0.1):normalize()
  -- empurrão de frente/trás com contato no meio: o amassado vai para a ponta do carro
  local half = car.aabbSize and car.aabbSize.z * 0.5 or 2
  if u.z < -0.6 and c.z < half * 0.8 and c.z > -half * 0.3 then c = vec3(clamp(c.x, -0.8, 0.8), c.y, half * 0.88)
  elseif u.z > 0.6 and c.z > -half * 0.8 and c.z < half * 0.3 then c = vec3(clamp(c.x, -0.8, 0.8), c.y, -half * 0.88) end
  if kmh < cfg.minKmh then return end
  local hit = quantize(c, u, kmh)
  addHit(i, hit, true)
  if i == 0 then
    breakSuspension(hit)
    if online then
      if #outbox >= 6 then        -- fila cheia (muitas batidas seguidas): descarta a mais fraca
        local wk = 1
        for k = 2, #outbox do if outbox[k].kmh < outbox[wk].kmh then wk = k end end
        table.remove(outbox, wk)
      end
      outbox[#outbox + 1] = hit
      if resumoDirty ~= 'reset' then resumoDirty = true end
    end
  end
end

local ACC = {}
local function measure(i, s, car, dt)
  local a = ACC[i]
  if a == nil then a = { dv = vec3(), pos = vec3(), w = 0, t = 0, on = false, lastVel = nil } ACC[i] = a end
  local v = car.velocity
  if a.lastVel ~= nil and dt > 0 then
    if car.collisionDepth > 0 then
      local dvM = car.worldToLocal:transformVector(v - a.lastVel)
      local w = #dvM
      a.dv = a.dv + dvM
      -- collisionPosition vem no espaço da física; passa pelo mundo para o espaço do modelo
      a.pos = a.pos + car.worldToLocal:transformPoint(car.transform:transformPoint(car.collisionPosition)) * w
      a.w, a.t, a.on = a.w + w, a.t + dt, true
      if a.t > CONTACT_SLICE then localHit(i, s, car, a) a.dv:set(0, 0, 0) a.pos:set(0, 0, 0) a.w, a.t = 0, 0 end
    elseif a.on then
      localHit(i, s, car, a)
      a.dv:set(0, 0, 0) a.pos:set(0, 0, 0) a.w, a.t, a.on = 0, 0, false
    end
  end
  a.lastVel = v:clone()
end

-- ------------------------------------------------------------------ reset (boxes, reinício, teleporte)
local function checkReset(i, s, car, dt)
  local why = nil
  if s.resetCounter ~= nil and car.resetCounter ~= s.resetCounter then why = 'reset' end
  s.resetCounter = car.resetCounter
  local pos = car.position
  if s.lastPos ~= nil then
    local jump = (pos - s.lastPos):length()
    if jump > 6 + #car.velocity * math.max(dt, 0.02) * 3 then why = why or string.format('teleporte %.0f m', jump) end
  end
  s.lastPos = pos:clone()
  if why and #s.hits > 0 then
    restore(s, why)
    if ACC[i] then ACC[i].lastVel = nil ACC[i].on = false ACC[i].w = 0 end
    if i == 0 and online then outbox = {} resumoDirty = 'reset' end
  end
end

local sessao = sim.currentSessionIndex
log('carregado; online:', online, 'mensagens:', sendHit ~= nil, 'physics.allowed:', tostring(physicsAllowed()))

local function update(dt)
  sim = ac.getSim()
  if sim.isReplayActive then return end
  if sim.currentSessionIndex ~= sessao then
    sessao = sim.currentSessionIndex
    for _, s in pairs(C) do restore(s, 'sessao nova') end
  end
  for i = 0, sim.carsCount - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      local s = carState(i)
      if not s.skip then
        checkReset(i, s, car, dt)
        local mine = (i == 0) or (not online and car.physicsAvailable)
        if mine then measure(i, s, car, dt) end
        applyPending(s, car)
        if smoke and s.total >= cfg.fumacaKmh and car.distanceToCamera < 150 then
          s.smokeT = s.smokeT + dt
          if s.smokeT > 0.08 then
            s.smokeT = 0
            local z = (s.front >= s.rear) and 1.4 or -1.5
            local amount = clamp((s.total - cfg.fumacaKmh) / cfg.fumacaKmh, 0.15, 1)
            pcall(smoke.emit, smoke, car.bodyTransform:transformPoint(vec3(0, 0.75, z)), car.velocity * 0.8 + vec3(0, 0.6, 0), amount)
          end
        end
      end
    elseif C[i] and #C[i].hits > 0 then
      restore(C[i], 'desconectou')
      C[i] = nil
    end
  end
  flushNet(dt)
end

function script.update(dt)
  safe('update', update, dt)
end
