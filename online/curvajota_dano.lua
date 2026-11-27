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
--   5) faíscas na batida e fumaça quando o carro está muito batido (só efeito visual, de cada PC);
--   6) v2: peças soltam e caem (portas abrem e ficam penduradas, capô, para-choques e asa inclinam e caem), ver "peças";
--   7) v3: a peça caída vira objeto com física (bate, rola, é empurrada); quem bate nela leva dano e amassado, e passar
--      por cima pode dar FURO LENTO no pneu (perde aderência aos poucos; troca de pneus no box conserta).
-- Offline (treino com IA) o script mede a batida de todos os carros direto, sem mensagens.
--
-- O amassado é visual (o collider do carro não muda). Física: peças caídas são corpos físicos, batida em peça soma dano
-- do AC e pode furar pneu (só no carro com física em cada PC). Opcional: quebrar a suspensão do próprio carro numa batida
-- forte perto da roda (cfg suspensao). Tudo que mexe na física exige physics.allowed() (vai no log).
-- Carros com dano próprio (ex.: CJT-500 Adsumus, que tem p500_dano.lua) ficam de fora pelo nome da pasta (ajuste 'pular').
-- Escrito do zero pela Curva Jota; o método de amassado é o do p500_dano.lua do Adsumus (aprovado v0.9.33).
-- Ajustes na seção [SCRIPT_...] do servidor (valores abaixo são o padrão).

local cfg = ac.configValues({
  minKmh = 7,               -- perda de velocidade mínima numa batida para amassar (km/h)
  profundidade = 0.0040,    -- afundamento (m) por km/h acima do mínimo
  maxAmassado = 0.18,       -- afundamento máximo de uma batida (m)
  maxTotal = 0.28,          -- deslocamento máximo acumulado de um ponto (m)
  raioMin = 0.22,           -- raio do amassado (m), cresce com a força até raioMax
  raioMax = 0.65,
  raioKmh = 80,
  ondulacao = 0.35,         -- dobras da lata (fração do afundamento)
  distancia = 300,          -- só lê/amassa malhas de carros até esta distância da câmera (o resto fica guardado)
  pular = 'cj_kwid_p500',   -- trechos do nome da pasta de carros que NÃO entram (separados por vírgula; vazio = todos)
  faiscas = 1,
  fumaca = 1,
  fumacaKmh = 140,          -- soma das batidas (km/h) a partir da qual o carro solta fumaça
  suspensao = 0,            -- 1 = batida forte perto da roda quebra a suspensão do próprio carro (se o CSP deixar)
  suspensaoKmh = 50,
  pecas = 1,                -- 1 = peças soltam e caem (portas, capô, para-choques, asa)
  portaSolta = 25, portaCai = 70,          -- dano somado perto da peça (km/h) para soltar e para cair
  capoSolta = 35, capoCai = 90,
  parachoqueSolta = 25, parachoqueCai = 60,
  asaSolta = 30, asaCai = 70,
  maxPecas = 30,            -- peças no chão ao mesmo tempo (as mais velhas somem)
  fisicaPecas = 1,          -- v3: 1 = peça caída vira objeto com física (bate, é empurrada, dá dano e pode furar pneu)
  pecaMinKmh = 12,          -- velocidade (relativa) mínima de quem bate na peça para levar dano
  pecaDano = 0.35,          -- dano na lataria (km/h do AC) por km/h de batida na peça (×massa da peça / 8 kg)
  furoChance = 0.30,        -- chance de furo lento quando a roda passa por cima de uma peça (×velocidade / 100 km/h)
  furoKmh = 25,             -- velocidade mínima para furar
  furoGrip = 0.45,          -- perda de aderência no fim do esvaziamento (0 = nada, 1 = sem aderência)
  furoTmin = 30, furoTmax = 90,            -- segundos para esvaziar
  depurar = 0,              -- 1 = mostra a caixa de colisão das peças
  espessura = 0.06,         -- espessura máxima da caixa de colisão de uma peça (m): chapa fina, não vira rampa
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
  local list = s.root:findMeshes('{ renderable:yes & lod:A & driverPiece:no & insideInterior:no & insideSteeringWheel:no }')
  if list:size() == 0 then list = s.root:findMeshes('{ lod:A & renderable:yes }') end
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

-- ------------------------------------------------------------------ peças que soltam (v2)
-- Dois tipos de peça:
--   * nó próprio no modelo (portas DOOR_L/DOOR_R, e capô/para-choque/asa quando o mod tem nó com esse nome): a porta abre e
--     fica pendurada na dobradiça, depois cai; as outras inclinam e caem;
--   * região da carroceria (quando o capô, os para-choques ou a asa estão colados na mesma malha da lataria, como no
--     BMW M4 GT3): os triângulos da região viram uma malha separada (a peça) e a lataria é trocada por uma cópia sem eles
--     (fica o buraco). Primeiro a peça fica solta/inclinada, depois cai.
-- O dano de cada peça é a soma das batidas perto dela; como todo PC recebe as mesmas batidas na mesma ordem, a peça solta e
-- cai igual em todos. A queda (trajetória) é calculada em cada PC. A peça caída fica no chão até o carro ser reparado.
-- Regiões em fração do tamanho da carroceria (comprimento L, altura H, meia-largura W), medidas no BMW M4 GT3.

local GONE_PIECES = {}
local pieceBox, dropBody, followBody, trySolid   -- v3, definidas mais abaixo     -- peças no chão (todas os carros), em ordem; as mais velhas somem acima de cfg.maxPecas

local function m4(t) return t and t:clone() end

local function lowerName(list, i) return tostring(list:name(i) or ''):lower() end

-- extensão da carroceria no espaço do carro, pela maior malha de fora
local function bodyExtents(s, car)
  local best = nil
  for _, m in ipairs(s.meshes) do
    if (best == nil or m.sr > best.sr) and not m.name:lower():find('glass', 1, true) then best = m end
  end
  if best == nil or not load(best) then return nil end
  local T = meshWorld(best.ref):clone():mul(car.bodyTransform:inverse())
  local E = { zF = -99, zR = 99, yT = -99, W = 0 }
  local p0, d = best.p0, best.d
  for i = 0, best.n - 1, 3 do      -- 1 em cada 3 vértices basta para os limites
    local j = 3 * i
    local q = T:transformPoint(vec3(p0[j] + d[j], p0[j + 1] + d[j + 1], p0[j + 2] + d[j + 2]))
    if q.z > E.zF then E.zF = q.z end
    if q.z < E.zR then E.zR = q.z end
    if q.y > E.yT then E.yT = q.y end
    if math.abs(q.x) > E.W then E.W = math.abs(q.x) end
  end
  E.L = E.zF - E.zR
  return E
end

-- sentido do giro: o ponto tv (a partir da dobradiça) tem de ir para o lado que want() aceita
local function signFor(axis, tv, want)
  local r = mat4x4.rotation(0.5, axis):transformVector(tv)
  return want(r) and 1 or -1
end

-- regiões: fn(p, n) no espaço do carro; centro e raio para somar o dano; dobradiça (ponto e eixo) para inclinar
local function regionDefs(E)
  local L, H, W, zF, zR = E.L, E.yT, E.W, E.zF, E.zR
  local defs = {
    { id = 'capo', solta = cfg.capoSolta, cai = cfg.capoCai,
      fn = function(p, n) return p.z > zF - 0.31 * L and p.z < zF - 0.05 * L and p.y > 0.49 * H and math.abs(p.x) < 0.73 * W and n.y > 0.35 end,
      c = vec3(0, 0.6 * H, zF - 0.18 * L), r = 0.75, hinge = vec3(0, 0.62 * H, zF - 0.31 * L), axis = vec3(1, 0, 0), ang = 0.35,
      tv = vec3(0, 0, 1), want = function(r) return r.y > 0 end },
    { id = 'parachoque_d', solta = cfg.parachoqueSolta, cai = cfg.parachoqueCai,
      fn = function(p) return p.z > zF - 0.10 * L and p.y < 0.50 * H end,
      c = vec3(0, 0.3 * H, zF - 0.04 * L), r = 0.8, hinge = vec3(W * 0.9, 0.35 * H, zF - 0.05 * L), axis = vec3(0, 1, 0), ang = 0.25,
      tv = vec3(-1, 0, 0), want = function(r) return r.z > 0 end },
    { id = 'parachoque_t', solta = cfg.parachoqueSolta, cai = cfg.parachoqueCai,
      fn = function(p) return p.z < zR + 0.09 * L and p.y < 0.68 * H end,
      c = vec3(0, 0.4 * H, zR + 0.04 * L), r = 0.8, hinge = vec3(-W * 0.9, 0.45 * H, zR + 0.05 * L), axis = vec3(0, 1, 0), ang = 0.25,
      tv = vec3(1, 0, 0), want = function(r) return r.z < 0 end },
    { id = 'asa', solta = cfg.asaSolta, cai = cfg.asaCai,
      fn = function(p) return p.z < zR + 0.15 * L and p.y > 0.755 * H end,
      c = vec3(0, 0.88 * H, zR + 0.07 * L), r = 0.7, hinge = vec3(0, 0.80 * H, zR + 0.10 * L), axis = vec3(1, 0, 0), ang = 0.30,
      tv = vec3(0, 0, -1), want = function(r) return r.y < 0 end,
      check = function(minY, spanX) return minY > 0.70 * H and spanX > 1.0 * W end },
  }
  for _, R in ipairs(defs) do R.ang = R.ang * signFor(R.axis, R.tv, R.want) end
  return defs
end

-- nós com nome conhecido. Portas: padrão do AC. Os outros por palavra no nome (o nó mais alto que casar).
local NODE_WORDS = {
  capo = { 'bonnet', 'hood', 'cofano', 'capot', 'motorhood' },
  asa = { 'wing', 'spoiler', 'alettone', 'aileron' },
  parachoque = { 'bumper', 'paraurti', 'parachoque' },
}

local function nodeCenter(s, car, node)
  local ms = node:findMeshes('?')
  local inv = car.bodyTransform:inverse()
  local sum, n, rmax = vec3(), 0, 0.2
  local cs = {}
  for i = 1, ms:size() do
    local ref = ms:at(i, true)
    local c, r = ref:boundingSphere(1)
    local w = meshWorld(ref)
    if c and w then
      local q = w:transformPoint(c)
      q = inv:transformPoint(q)
      cs[#cs + 1] = { q, r }
      sum = sum + q
      n = n + 1
    end
  end
  if n == 0 then return nil end
  local c = sum / n
  for _, e in ipairs(cs) do rmax = math.max(rmax, (e[1] - c):length() + e[2]) end
  return c, rmax
end

local function setupParts(s, car)
  s.parts = {}
  local E = bodyExtents(s, car)
  if E == nil then log('carro', s.index, 'sem carroceria para pecas') return end
  s.E = E
  local haveNode = {}
  -- portas
  for _, nm in ipairs({ 'DOOR_L', 'DOOR_R', 'DOOR_FL', 'DOOR_FR', 'DOOR_LF', 'DOOR_RF' }) do
    local nodes = s.root:findNodes(nm)
    if nodes:size() > 0 then
      local node = nodes:at(1)
      local c, r = nodeCenter(s, car, node)
      if c and r < 1.6 then
        local side = c.x >= 0 and 1 or -1
        s.parts[#s.parts + 1] = { id = 'porta_' .. (side > 0 and 'e' or 'd'), kind = 'node', node = node, c = c, r = math.min(r, 1.0),
          solta = cfg.portaSolta, cai = cfg.portaCai, hinge = vec3(c.x, c.y, c.z + 0.8 * math.min(r, 1.0)), axis = vec3(0, 1, 0),
          ang = 1.0 * signFor(vec3(0, 1, 0), vec3(0, 0, -1), function(r) return r.x * side > 0 end), dmg = 0, state = 0 }
      end
    end
  end
  -- outros nós por nome
  local all = s.root:findNodes('?')
  for i = 1, all:size() do
    local nm = lowerName(all, i)
    for kind, words in pairs(NODE_WORDS) do
      for _, w in ipairs(words) do
        if nm:find(w, 1, true) and not nm:find('glass', 1, true) and not nm:find('light', 1, true) then
          local node = all:at(i)
          local c, r = nodeCenter(s, car, node)
          if c and r < 1.4 then
            local id = kind
            if kind == 'parachoque' then id = c.z > 0 and 'parachoque_d' or 'parachoque_t' end
            if not haveNode[id] then
              haveNode[id] = true
              log('carro', s.index, 'no', tostring(all:name(i)), 'vira peca', id)
              for _, R in ipairs(regionDefs(E)) do
                if R.id == id then
                  s.parts[#s.parts + 1] = { id = id, kind = 'node', node = node, c = c, r = r, solta = R.solta, cai = R.cai,
                    hinge = R.hinge, axis = R.axis, ang = R.ang, dmg = 0, state = 0 }
                end
              end
            end
          end
        end
      end
    end
  end
  for _, R in ipairs(regionDefs(E)) do
    if not haveNode[R.id] then
      s.parts[#s.parts + 1] = { id = R.id, kind = 'region', fn = R.fn, check = R.check, c = R.c, r = R.r, solta = R.solta,
        cai = R.cai, hinge = R.hinge, axis = R.axis, ang = R.ang, dmg = 0, state = 0 }
    end
  end
  local ids = {}
  for _, P in ipairs(s.parts) do ids[#ids + 1] = P.id .. '(' .. P.kind .. ')' end
  log(string.format('carro %d pecas: %s; carroceria z %.2f..%.2f, altura %.2f, meia-largura %.2f', s.index,
    table.concat(ids, ' '), E.zR, E.zF, E.yT, E.W))
end

-- nó suporte da peça: filho do MESMO nó pai da peça no modelo (v2.1 punha no carRoot e a peça sumia na tela);
-- anda junto com o carro até cair, depois a posição no mundo é compensada a cada quadro
local holderParents = setmetatable({}, { __mode = 'k' })
local diagHolder = 0

local function setWorld(h, W)
  local par = holderParents[h]
  local pw = par and par:getWorldTransformationRaw()
  if pw == nil then return end
  h:getTransformationRaw():set(W:clone():mul(pw:inverse()))
  if diagHolder < 4 then
    diagHolder = diagHolder + 1
    local got = h:getWorldTransformationRaw()
    if got then
      local e = (got:transformPoint(vec3()) - W:transformPoint(vec3())):length()
      log(string.format('suporte: erro de posicao %.3f m', e))
    end
  end
end

local function makeHolder(s, parent, name, worldW)
  parent = parent or s.root
  local ok, h = pcall(parent.createNode, parent, name, false)
  if not ok or h == nil then log('carro', s.index, 'createNode falhou:', tostring(h):sub(1, 200)) return nil end
  holderParents[h] = parent
  setWorld(h, worldW)
  return h
end

local function bufSize(b) if b.size then return b:size() end return #b end
local function bufGet(b, k)   -- k a partir de 0
  if b.raw ~= nil then return b.raw[k] end
  return b:get(k + 1)
end

-- cada passo com nome: um erro do C++ no CSP vem sem linha, então o log diz em que passo foi
local function step(P, name, fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then
    log('carro peca', P.id, 'falhou em', name .. ':', tostring(a):sub(1, 300))
    return false
  end
  return true, a, b
end

local function newPieceMesh(P, holder, m, verts, inds)
  local nv, ni = #verts, #inds
  local okV, vb = step(P, 'VertexBuffer', ac.VertexBuffer, nv)
  if not okV or vb == nil then return nil end
  local okF = step(P, 'copiar vertices', function()
    local raw = vb.raw
    for k = 0, nv - 1 do
      local src = verts[k + 1]
      local dst = raw ~= nil and raw[k] or vb:get(k + 1)
      dst.pos.x, dst.pos.y, dst.pos.z = src.pos.x, src.pos.y, src.pos.z
      dst.normal.x, dst.normal.y, dst.normal.z = src.normal.x, src.normal.y, src.normal.z
      dst.uv.x, dst.uv.y = src.uv.x, src.uv.y
      if raw == nil then vb:set(k + 1, dst) end
    end
  end)
  if not okF then return nil end
  local okI, ib = step(P, 'IndicesBuffer', ac.IndicesBuffer, ni)
  if not okI or ib == nil then return nil end
  local okG = step(P, 'copiar indices', function()
    local raw = ib.raw
    for k = 0, ni - 1 do if raw ~= nil then raw[k] = inds[k + 1] else ib:set(k + 1, inds[k + 1]) end end
  end)
  if not okG then return nil end
  local matName = nil
  if m.orig and m.orig.materialName then local okM, nm = pcall(m.orig.materialName, m.orig) if okM then matName = nm end
  elseif m.ref.materialName then local okM, nm = pcall(m.ref.materialName, m.ref) if okM then matName = nm end end
  local okC, mesh = step(P, 'createMesh', holder.createMesh, holder, 'CJ_DANO_' .. P.id .. '_' .. m.name, matName, vb, ib, false, false)
  if not okC or mesh == nil or (mesh.empty and mesh:empty()) then return nil end
  step(P, 'assignMaterialFrom', mesh.assignMaterialFrom, mesh, m.orig or m.ref)
  return mesh
end

-- recorta a região das malhas da carroceria: devolve lista de { mesh (nova, no suporte), holder, W0 }
local function cutRegion(s, car, P)
  local T0 = car.bodyTransform:inverse()
  local pieces = {}
  local minY, maxX, minX = 99, -99, 99
  local plan = {}
  for _, m in ipairs(s.meshes) do
    if m.sr > 0.25 and load(m) then
      local src = m.orig or m.ref
      local okI, ib = step(P, 'getIndices ' .. m.name, src.getIndices, src)
      if okI and ib ~= nil and bufSize(ib) >= 3 then
        local W = meshWorld(m.ref)
        local T = W:clone():mul(T0)
        local inside = {}
        local p0, d, n0 = m.p0, m.d, m.n0
        for i = 0, m.n - 1 do
          local j = 3 * i
          local q = T:transformPoint(vec3(p0[j] + d[j], p0[j + 1] + d[j + 1], p0[j + 2] + d[j + 2]))
          local nn = T:transformVector(vec3(n0[j], n0[j + 1], n0[j + 2]))
          if P.fn(q, nn) then
            inside[i] = true
            if q.y < minY then minY = q.y end
            if q.x > maxX then maxX = q.x end
            if q.x < minX then minX = q.x end
          end
        end
        -- índices como números Lua; m.keep guarda o que sobrou de recortes anteriores
        local all = m.keep
        if all == nil then
          all = {}
          for k = 0, bufSize(ib) - 1 do all[k + 1] = tonumber(bufGet(ib, k)) end
        end
        local cutI, keepI = {}, {}
        for t = 1, #all, 3 do
          local a, b, c = all[t], all[t + 1], all[t + 2]
          local dst = (inside[a] and inside[b] and inside[c]) and cutI or keepI
          dst[#dst + 1] = a dst[#dst + 1] = b dst[#dst + 1] = c
        end
        if #cutI >= 12 then plan[#plan + 1] = { m = m, cutI = cutI, keepI = keepI, W = W } end
      end
    end
  end
  if #plan == 0 then log('carro', s.index, P.id, 'sem triangulos na regiao') return nil end
  if P.check and not P.check(minY, maxX - minX) then
    log('carro', s.index, P.id, 'nao parece peca separada (ignorada)')
    return nil
  end
  for _, pl in ipairs(plan) do
    local m = pl.m
    -- peça: vértices usados pelos triângulos recortados (posição atual, já amassada)
    local map, verts, inds = {}, {}, {}
    for _, vi in ipairs(pl.cutI) do
      if map[vi] == nil then
        local j = 3 * vi
        verts[#verts + 1] = { pos = vec3(m.p0[j] + m.d[j], m.p0[j + 1] + m.d[j + 1], m.p0[j + 2] + m.d[j + 2]),
          normal = vec3(m.n0[j], m.n0[j + 1], m.n0[j + 2]), uv = m.vb:get(vi + 1).uv }
        map[vi] = #verts - 1
      end
      inds[#inds + 1] = map[vi]
    end
    local holder = makeHolder(s, (m.orig or m.ref):getParent(), 'CJ_DANO_' .. P.id, pl.W)
    if holder then
      local piece = newPieceMesh(P, holder, m, verts, inds)
      local lmin, lmax = vec3(1e9, 1e9, 1e9), vec3(-1e9, -1e9, -1e9)
      for _, v in ipairs(verts) do
        local q = v.pos
        if q.x < lmin.x then lmin.x = q.x end if q.y < lmin.y then lmin.y = q.y end if q.z < lmin.z then lmin.z = q.z end
        if q.x > lmax.x then lmax.x = q.x end if q.y > lmax.y then lmax.y = q.y end if q.z > lmax.z then lmax.z = q.z end
      end
      if piece then pieces[#pieces + 1] = { mesh = piece, holder = holder, W0 = pl.W:clone(), lmin = lmin, lmax = lmax }
      else pcall(holder.dispose, holder) end
    end
    -- lataria sem a região: cópia com todos os vértices e só os triângulos que ficam; a original some
    local parent = (m.orig or m.ref):getParent()
    if parent and #pieces > 0 then
      local all = {}
      for k = 1, m.n do all[k] = m.vb:get(k) end
      local nm = newPieceMesh({ id = 'resto' }, parent, m, all, pl.keepI)
      if nm then
        m.orig = m.orig or m.ref
        if m.created then pcall(m.created.dispose, m.created) end
        pcall(m.orig.setVisible, m.orig, false)
        m.ref, m.created, m.keep = nm, nm, pl.keepI
      end
    end
  end
  log(string.format('carro %d recortou %s: %d pecas', s.index, P.id, #pieces))
  if #pieces == 0 then return nil end
  return pieces
end

-- inclinação (peça solta): gira o suporte em volta da dobradiça (espaço do carro)
local function tiltPieces(s, car, P, a)
  -- rel0 = posição da malha em relação ao carro no recorte; gira na dobradiça (espaço do carro) e volta para o mundo
  local B = car.bodyTransform
  for _, pc in ipairs(P.pieces or {}) do
    local W = pc.rel0:clone():mul(mat4x4.translation(-P.hinge)):mul(mat4x4.rotation(a, P.axis)):mul(mat4x4.translation(P.hinge))
    setWorld(pc.holder, W:mul(B))
  end
end

local function nodeTilt(s, P, a)
  if P.L0 == nil then
    P.L0 = P.node:getTransformationRaw():clone()
  end
  local par = P.node:getParent()
  -- dobradiça e eixo no espaço do pai do nó (o pai anda junto com o carro)
  local car = ac.getCar(s.index)
  local inv = par and par:getWorldTransformationRaw() and par:getWorldTransformationRaw():inverse()
  if inv == nil then return end
  local h = inv:transformPoint(car.bodyTransform:transformPoint(P.hinge))
  local ax = inv:transformVector(car.bodyTransform:transformVector(P.axis)):normalize()
  local L = P.L0:clone():mul(mat4x4.translation(-h)):mul(mat4x4.rotation(a, ax)):mul(mat4x4.translation(h))
  P.node:getTransformationRaw():set(L)
end

local function groundY(pos)
  local ok, dist = pcall(physics.raycastTrack, pos + vec3(0, 2, 0), vec3(0, -1, 0), 8)
  if ok and type(dist) == 'number' and dist >= 0 then return pos.y + 2 - dist end
  return nil
end

-- ------------------------------------------------------------------ v3: peças com física, dano e furo
-- A peça caída vira um corpo físico (physics.RigidBody, caixa do tamanho dela) assim que sai de perto dos carros: bate no
-- chão, rola, é empurrada por quem passa. Quem bate nela (o carro com física neste PC: online, o seu) leva dano na lataria
-- do AC, um amassado (que vai para todos como uma batida comum) e, se a roda passar por cima, pode ter um FURO LENTO
-- (o pneu perde aderência aos poucos em 30–90 s; a troca de pneus no box ou o reparo devolvem). Cada PC simula as peças
-- dele: uma peça chutada pode parar em lugar um pouco diferente em cada PC.
local MASSA = { porta_e = 12, porta_d = 12, capo = 7, parachoque_d = 5, parachoque_t = 5, asa = 5 }
local SOLIDS = {}          -- peças com corpo físico: { s, P, F }
local FURO = {}            -- índice do carro -> { [roda 0..3] = { t, T, g, motivo } , km = {...} }
local pushHit = nil        -- definida mais abaixo (registra uma batida do próprio carro e manda pela rede)
local RODA_NOME = { [0] = 'dianteiro esquerdo', 'dianteiro direito', 'traseiro esquerdo', 'traseiro direito' }

local function fisicaOk()
  return physics ~= nil and physics.allowed ~= nil and physics.allowed()
end

local function carHasPhysicsHere(i)
  if i == 0 then return true end
  local car = ac.getCar(i)
  return car ~= nil and not ac.getSim().isOnlineRace and car.physicsAvailable
end

-- caixa da peça no espaço do carro no momento da queda (B0inv)
function pieceBox(s, P, B0inv)
  local mn, mx = vec3(1e9, 1e9, 1e9), vec3(-1e9, -1e9, -1e9)
  local function add(q)
    if q.x < mn.x then mn.x = q.x end if q.y < mn.y then mn.y = q.y end if q.z < mn.z then mn.z = q.z end
    if q.x > mx.x then mx.x = q.x end if q.y > mx.y then mx.y = q.y end if q.z > mx.z then mx.z = q.z end
  end
  if P.kind == 'node' then
    local ms = P.node:findMeshes('?')
    for i = 1, ms:size() do
      local ref = ms:at(i, true)
      local Wm = meshWorld(ref)
      if Wm then
        local T = Wm:clone():mul(B0inv)
        local ok, vb = pcall(ref.getVertices, ref)
        if ok and vb ~= nil and #vb > 0 then
          local n = #vb
          local stp = math.max(1, math.floor(n / 3000))
          for k = 1, n, stp do add(T:transformPoint(vb:get(k).pos)) end
        else
          local c, r = ref:boundingSphere(1)
          if c then
            local q = T:transformPoint(c)
            add(q - vec3(r, r, r)) add(q + vec3(r, r, r))
          end
        end
      end
    end
  else
    for _, pc in ipairs(P.pieces or {}) do
      if pc.lmin then
        local T = pc.holder:getWorldTransformationRaw():clone():mul(B0inv)
        for _, x in ipairs({ pc.lmin.x, pc.lmax.x }) do for _, y in ipairs({ pc.lmin.y, pc.lmax.y }) do
          for _, z in ipairs({ pc.lmin.z, pc.lmax.z }) do add(T:transformPoint(vec3(x, y, z))) end
        end end
      end
    end
  end
  if mn.x > mx.x then return nil end
  -- peças finas (porta, capô): no mínimo 4 cm em cada eixo
  for _, ax in ipairs({ 'x', 'y', 'z' }) do
    if mx[ax] - mn[ax] < 0.04 then local c = (mx[ax] + mn[ax]) * 0.5 mn[ax], mx[ax] = c - 0.02, c + 0.02 end
  end
  return mn, mx
end

function dropBody(F)
  if F and F.body then
    pcall(F.body.dispose, F.body)
    F.body = nil
    for k = #SOLIDS, 1, -1 do if SOLIDS[k].F == F then table.remove(SOLIDS, k) end end
  end
end

-- malhas seguem o corpo físico (parada: atualiza só de vez em quando)
function followBody(F, dt)
  local b = F.body
  local D = F.diag
  if D and D.n < 4 then
    D.t = D.t + dt
    if D.t >= ({ 0.3, 1, 3, 8 })[D.n + 1] then
      D.n = D.n + 1
      local T = b:getTransformation()
      local cy = T and T.position.y or -999
      local inW, en = true, true
      pcall(function() inW, en = b:isInWorld(), b:isEnabled() end)
      log(string.format('peca solida %.1f s: centro y %.2f (comecou %.2f, chao %.2f), %.1f km/h, no mundo %s, ativo %s',
        D.t, cy, D.y0, D.g or -999, b:getSpeedKmh(), tostring(inW), tostring(en)))
    end
  end
  -- v3.5: atualiza TODO quadro, mesmo com a peça parada. O suporte é filho de um nó do carro: se ficar um quadro sem
  -- compensar, a peça anda junto com o carro (v3.4 pulava 0,5 s com a peça parada e ela "arrastava" atrás do carro).
  local T = b:getTransformation()
  if T == nil then return end
  for _, it in ipairs(F.items) do setWorld(it.holder, it.rel:clone():mul(T)) end
end

local function boxLowY(Fw, mn, mx)
  local low = 1e9
  for _, x in ipairs({ mn.x, mx.x }) do for _, y in ipairs({ mn.y, mx.y }) do for _, z in ipairs({ mn.z, mx.z }) do
    local q = Fw:transformPoint(vec3(x, y, z))
    if q.y < low then low = q.y end
  end end end
  return low
end

local function wheelBit(w) return math.floor(2 ^ (2 + w) + 0.5) end

local function furoTry(i, w, chance, motivo)
  if not fisicaOk() or not carHasPhysicsHere(i) then return end
  local f = FURO[i]
  if f == nil then f = { km = {} } FURO[i] = f end
  if f[w] or chance <= 0 or math.random() > chance then return end
  f[w] = { t = 0, T = cfg.furoTmin + math.random() * math.max(0, cfg.furoTmax - cfg.furoTmin), g = -1, motivo = motivo }
  log(string.format('carro %d FURO no pneu %s (%s), esvazia em %.0f s', i, RODA_NOME[w], motivo, f[w].T))
  if i == 0 then pcall(ac.setMessage, 'Pneu furado', 'Pneu ' .. RODA_NOME[w] .. ' perdendo ar (' .. motivo .. ')') end
end

local function furoClear(i, why)
  local f = FURO[i]
  if f == nil then return end
  local any = false
  for w = 0, 3 do
    if f[w] then any = true f[w] = nil pcall(physics.setGripDecrease, i, wheelBit(w), 0) end
  end
  f.km = {}
  if any then log('carro', i, 'furos consertados (' .. why .. ')') end
end

local function furoUpdate(i, car, dt)
  local f = FURO[i]
  if f == nil then return end
  for w = 0, 3 do
    local wh = car.wheels[w]
    -- troca de pneus: a quilometragem virtual do pneu volta para trás
    local km = wh and wh.tyreVirtualKM or 0
    if f.km[w] ~= nil and km < f.km[w] - 0.01 and f[w] then
      f[w] = nil
      pcall(physics.setGripDecrease, i, wheelBit(w), 0)
      log('carro', i, 'pneu', RODA_NOME[w], 'trocado: furo consertado')
    end
    f.km[w] = km
    local fw = f[w]
    if fw then
      fw.t = math.min(fw.T, fw.t + dt)
      local x = fw.t / fw.T
      local g = cfg.furoGrip * x * x * (3 - 2 * x)     -- começa devagar, acelera, assenta no fim
      if math.abs(g - fw.g) > 0.005 then
        fw.g = g
        pcall(physics.setGripDecrease, i, wheelBit(w), g)
      end
    end
  end
end

-- quem bateu na peça (só o carro com física neste PC): dano na lataria, amassado e talvez furo
local function pieceHit(ci, s, P, F)
  if ci == nil or not carHasPhysicsHere(ci) or F.body == nil then return end
  local now = os.clock()
  F.lastHit = F.lastHit or {}
  if F.lastHit[ci] and now - F.lastHit[ci] < 0.4 then return end
  F.lastHit[ci] = now
  local car = ac.getCar(ci)
  if car == nil then return end
  local kmh = #(car.velocity - F.body:getVelocity()) * 3.6
  if kmh < cfg.pecaMinKmh then return end
  local hp = F.body:getLastHitPos()
  if hp == nil or #hp < 1e-3 then hp = F.body:getTransformation():transformPoint((F.bmin + F.bmax) * 0.5) end
  local lc = car.worldToLocal:transformPoint(hp)
  local half = car.aabbSize and car.aabbSize * 0.5 or vec3(1, 0.7, 2.2)
  local massK = clamp((F.kg or 8) / 8, 0.4, 1.5)
  -- 1) dano do AC (zonas: 0 frente, 1 trás, 2 esquerda, 3 direita; X do carro aponta para a esquerda)
  if fisicaOk() then
    local zone
    if math.abs(lc.z) / half.z > 0.55 then zone = lc.z > 0 and 0 or 1 else zone = lc.x > 0 and 2 or 3 end
    local add = kmh * cfg.pecaDano * massK
    local d = car.damage
    local v = { d[0] or 0, d[1] or 0, d[2] or 0, d[3] or 0 }
    v[zone + 1] = v[zone + 1] + add
    pcall(physics.setCarBodyDamage, ci, vec4(v[1], v[2], v[3], v[4]))
    log(string.format('carro %d bateu na peca %s a %.0f km/h: dano +%.0f na zona %d', ci, P.id, kmh, add, zone))
  end
  -- 2) amassado no ponto (todo mundo vê)
  local dentKmh = kmh * 0.6 * massK
  if pushHit and dentKmh >= cfg.minKmh then
    local inward = vec3(-lc.x, (0.6 - lc.y) * 0.3, -lc.z)
    if #inward < 1e-3 then inward = vec3(0, 0, -1) end
    pushHit(ci, lc, inward:normalize(), dentKmh)
  end
  -- 3) furo: contato baixo, perto de uma roda
  if kmh >= cfg.furoKmh and lc.y < 0.55 then
    local best, bd = nil, 0.9
    for w = 0, 3 do
      local wh = car.wheels[w]
      if wh then
        local q = car.worldToLocal:transformPoint(wh.position)
        local dd = math.sqrt((q.x - lc.x) ^ 2 + (q.z - lc.z) ^ 2)
        if dd < bd then best, bd = w, dd end
      end
    end
    if best then furoTry(ci, best, cfg.furoChance * clamp(kmh / 100, 0.5, 1.5), 'bateu na peca ' .. P.id) end
  end
end

-- roda passando por cima de uma peça (o pneu do AC não "bate" no corpo físico; olha o ponto de contato)
local function furoOver(i, car)
  if #SOLIDS == 0 or car.speedKmh < cfg.furoKmh then return end
  for _, e in ipairs(SOLIDS) do
    local F = e.F
    local b = F.body
    if b and F.bmin then
      local T = b:getTransformation()
      local c = T:transformPoint((F.bmin + F.bmax) * 0.5)
      if (c - car.position):length() < 6 then
        local inv = T:inverse()
        F.over = F.over or {}
        for w = 0, 3 do
          local wh = car.wheels[w]
          if wh then
            local q = inv:transformPoint(wh.contactPoint)
            local inside = q.x > F.bmin.x - 0.08 and q.x < F.bmax.x + 0.08 and q.z > F.bmin.z - 0.08 and q.z < F.bmax.z + 0.08
              and q.y > F.bmin.y - 0.25 and q.y < F.bmax.y + 0.25
            local key = i * 4 + w
            if inside and not F.over[key] then
              F.over[key] = true
              log(string.format('carro %d roda %s passou por cima da peca %s a %.0f km/h', i, RODA_NOME[w], e.P.id, car.speedKmh))
              furoTry(i, w, cfg.furoChance * clamp(car.speedKmh / 100, 0.5, 1.5), 'passou por cima de ' .. e.P.id)
            elseif not inside then
              F.over[key] = nil
            end
          end
        end
      end
    end
  end
end

-- tenta virar corpo físico: só longe de todos os carros (senão o corpo nasceria dentro de um carro e daria um tranco)
function trySolid(s, P, F)
  if F.body or F.hidden then return end
  if not fisicaOk() then
    F.noPhys = true
    log('sem permissao de fisica: pecas ficam so visuais')
    return
  end
  local Fw = F.B0:clone():mul(F.M)
  local center = (F.bmin + F.bmax) * 0.5
  local size = F.bmax - F.bmin
  local cw = Fw:transformPoint(center)
  local reach = 0.25 + 0.5 * math.max(size.x, size.y, size.z)
  local sim = ac.getSim()
  for i = 0, sim.carsCount - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      local hs = car.aabbSize and car.aabbSize * 0.5 or vec3(1, 0.7, 2.3)
      local d = car.worldToLocal:transformPoint(cw) - (car.aabbCenter or vec3())
      if math.abs(d.x) < hs.x + reach and math.abs(d.z) < hs.z + reach and math.abs(d.y) < hs.y + reach then
        F.waitT = (F.waitT or 0) + 0.1
        return
      end
    end
  end
  -- não nasce enterrado: sobe até o canto mais baixo ficar 1 cm acima do chão
  local g = groundY(cw)
  if g then
    local low = boxLowY(Fw, F.bmin, F.bmax)
    if low < g + 0.01 then Fw = Fw:clone():mul(mat4x4.translation(vec3(0, g + 0.01 - low, 0))) end
  end
  F.kg = (MASSA[P.id] or 8) * 1
  local okB, body = pcall(physics.RigidBody, { physics.Collider.Box(size, center, nil, nil, cfg.depurar == 1) }, F.kg)
  if not okB or body == nil then
    F.noPhys = true
    log('carro', s.index, P.id, 'corpo fisico falhou:', tostring(body):sub(1, 200))
    return
  end
  pcall(body.setDamping, body, 0.1, 0.1, true)
  body:setTransformation(Fw)
  if F.landed then body:setVelocity(vec3(F.vel.x * 0.6, 0, F.vel.z * 0.6))
  else
    body:setVelocity(F.vel)
    pcall(body.setAngularVelocity, body, F.axis * F.spin)
  end
  body:onCollision(function(ci) safe('peca bateu', pieceHit, ci, s, P, F) end)
  F.body = body
  F.diag = { t = 0, y0 = Fw.position.y, g = g, n = 0 }
  SOLIDS[#SOLIDS + 1] = { s = s, P = P, F = F }
  log(string.format('carro %d %s virou peca solida (%.0f kg, %s, esperou %.1f s)', s.index, P.id, F.kg,
    F.landed and 'no chao' or 'no ar', F.waitT or 0))
end

local function startFall(s, car, P, fresh)
  local B = car.bodyTransform
  local items = {}
  if P.kind == 'node' then
    local W0 = P.node:getWorldTransformationRaw():clone()
    local h = makeHolder(s, P.node:getParent(), 'CJ_DANO_' .. P.id, W0)
    if h == nil then return end
    P.oldParent = P.node:getParent()
    -- o nó vai para o suporte mantendo a própria posição relativa: suporte começa onde o nó estava
    P.node:getTransformationRaw():set(mat4x4())
    P.node:setParent(h)
    items[1] = { holder = h, W0 = W0 }
    P.holderNode = h
  else
    for _, pc in ipairs(P.pieces or {}) do
      local Wn = pc.holder:getWorldTransformationRaw():clone()
      items[#items + 1] = { holder = pc.holder, W0 = Wn }
    end
  end
  -- v3: quadro da peça = a 1ª malha/nó dela no momento da queda (B0; porta aberta = quadro da porta, caixa justa); cada
  -- malha guarda a posição relativa a ele (rel) e a caixa de colisão sai das malhas nesse quadro (bmin/bmax). Depois o
  -- corpo físico move o quadro e as malhas vão junto.
  if #items == 0 then return end
  -- v3.1: quadro SEMPRE ortonormal (só rotação + posição; malhas do kn5 podem ter escala ou espelho, e o corpo físico
  -- não aceita isso): eixos da 1ª malha normalizados se tiverem a mesma "mão" do carro, senão os eixos do carro.
  local function frame(sd, u, l, p)
    return mat4x4(vec4(sd.x, sd.y, sd.z, 0), vec4(u.x, u.y, u.z, 0), vec4(l.x, l.y, l.z, 0), vec4(p.x, p.y, p.z, 1))
  end
  local P0 = items[1].W0:transformPoint(vec3())
  local carFrame = function() return frame(B.side:clone():normalize(), B.up:clone():normalize(), B.look:clone():normalize(), P0) end
  local B0 = carFrame()
  pcall(function()
    -- eixos da 1ª malha, ortonormalizados à mão (mat4x4.look deu matriz degenerada no jogo, v3.1)
    local W = items[1].W0
    local l = W.look:clone():normalize()
    local u = W.up:clone()
    u = (u - l * u:dot(l)):normalize()
    local sd = u:cross(l):normalize()
    local hand = B.side:dot(B.up:cross(B.look))
    if hand < 0 then sd = sd * -1 end
    local M = frame(sd, u, l, P0)
    -- confere: rotação pura (sem escala), mesma "mão" do carro, e leva a origem para P0
    local ok = math.abs(#M.side - 1) < 0.01 and math.abs(#M.up - 1) < 0.01 and math.abs(#M.look - 1) < 0.01
      and M.side:dot(M.up:cross(M.look)) * hand > 0 and (M:transformPoint(vec3()) - P0):length() < 0.01
    if ok then B0 = M end
  end)
  local B0inv = B0:inverse()
  local okBox, bmin, bmax = pcall(pieceBox, s, P, B0inv)
  if not okBox then log('carro', s.index, P.id, 'caixa falhou:', tostring(bmin):sub(1, 200)) bmin, bmax = nil, nil end
  if bmin and (bmax - bmin):length() > 8 then
    log('carro', s.index, P.id, string.format('caixa absurda (%.1f m): usando os eixos do carro', (bmax - bmin):length()))
    B0 = carFrame() B0inv = B0:inverse()
    okBox, bmin, bmax = pcall(pieceBox, s, P, B0inv)
    if not okBox or bmin == nil or (bmax - bmin):length() > 8 then bmin, bmax = nil, nil end
  end
  if bmin then
    -- v3.4: peça é chapa (capô, porta, para-choque, asa). A caixa das malhas fica gorda por causa da curva da chapa e
    -- vira uma rampa: o carro passava por cima e subia (teste de 27/11, carro subiu no muro). O eixo mais fino da caixa
    -- fica com no máximo cfg.espessura.
    local d = bmax - bmin
    local ax = 'x'
    if d.y < d[ax] then ax = 'y' end
    if d.z < d[ax] then ax = 'z' end
    if d[ax] > cfg.espessura then
      local c = (bmax[ax] + bmin[ax]) * 0.5
      bmin[ax], bmax[ax] = c - cfg.espessura * 0.5, c + cfg.espessura * 0.5
    end
  end
  if bmin then
    -- origem do quadro no centro da caixa: o corpo gira em volta do próprio centro (sem cog separado)
    local ctr = (bmin + bmax) * 0.5
    B0 = mat4x4.translation(ctr):mul(B0)
    bmin, bmax = bmin - ctr, bmax - ctr
    B0inv = B0:inverse()
  end
  for _, it in ipairs(items) do it.rel = it.W0:clone():mul(B0inv) end
  local c0 = B:transformPoint(P.c)
  local away = B:transformVector(vec3(P.c.x, 0, P.c.z)):normalize()
  local seed = rng(s.index * 131 + #s.hits * 977 + (#P.id) * 7)
  local F = { items = items, c0 = c0, pos = c0:clone(), ang = 0,
    vel = car.velocity * 0.55 + vec3(0, 1.8, 0) + away * 1.5,
    axis = B:transformVector(vec3(1, 0, 0)):normalize(), spin = (seed() - 0.5) * 9,
    ground = groundY(c0) or (car.position.y), landed = false, rest = math.min(0.25, P.r * 0.25),
    B0 = B0, bmin = bmin, bmax = bmax, chk = 0 }
  if bmin then log(string.format('carro %d %s caixa %.2f x %.2f x %.2f m', s.index, P.id, bmax.x - bmin.x, bmax.y - bmin.y, bmax.z - bmin.z)) end
  if not fresh then              -- veio do resumo (quem entrou depois): a peça já estava no chão longe daqui
    for _, it in ipairs(items) do pcall(it.holder.setVisible, it.holder, false) end
    F.hidden = true
  end
  P.fall = F
  GONE_PIECES[#GONE_PIECES + 1] = { s = s, P = P }
  while #GONE_PIECES > cfg.maxPecas do
    local old = table.remove(GONE_PIECES, 1)
    if old.P.fall then
      for _, it in ipairs(old.P.fall.items) do pcall(it.holder.setVisible, it.holder, false) end
      old.P.fall.hidden = true
      dropBody(old.P.fall)
    end
  end
  log('carro', s.index, P.id, 'caiu')
end

local function fallUpdate(s, P, dt)
  local F = P.fall
  if F == nil or F.hidden then return end
  if F.body then followBody(F, dt) return end
  local M
  if not F.landed then
    F.vel = F.vel + vec3(0, -9.81 * dt, 0)
    local k = math.exp(-0.8 * dt)
    F.vel = vec3(F.vel.x * k, F.vel.y, F.vel.z * k)
    F.pos = F.pos + F.vel * dt
    F.ang = F.ang + F.spin * dt
    if F.bmin then
      -- com caixa: pousa quando o canto mais baixo da peça toca o chão (não enterra)
      M = mat4x4.translation(-F.c0):mul(mat4x4.rotation(F.ang, F.axis)):mul(mat4x4.translation(F.pos))
      local low = boxLowY(F.B0:clone():mul(M), F.bmin, F.bmax)
      if low <= F.ground + 0.01 and F.vel.y < 0 then
        F.pos = vec3(F.pos.x, F.pos.y + (F.ground + 0.01 - low), F.pos.z)
        F.landed = true
        M = nil
      end
    elseif F.pos.y <= F.ground + F.rest and F.vel.y < 0 then
      F.ang = math.floor(F.ang / math.pi + 0.5) * math.pi
      F.pos = vec3(F.pos.x, F.ground + F.rest, F.pos.z)
      F.landed = true
    end
  end
  M = M or mat4x4.translation(-F.c0):mul(mat4x4.rotation(F.ang, F.axis)):mul(mat4x4.translation(F.pos))
  F.M = M
  for _, it in ipairs(F.items) do
    setWorld(it.holder, it.W0:clone():mul(M))
  end
  -- v3: assim que a peça sai de perto de todos os carros (no ar ou no chão), vira corpo físico
  if cfg.fisicaPecas == 1 and F.bmin and not F.noPhys then
    F.chk = F.chk + dt
    if F.chk >= 0.1 then
      F.chk = 0
      safe('fisica ' .. P.id, trySolid, s, P, F)
    end
  end
end

-- soma o dano de uma batida nas peças e muda o estado (0 inteira, 1 solta, 2 caiu, 3 não existe)
local function partsHit(s, car, hit, fresh)
  if cfg.pecas ~= 1 then return end
  if s.parts == nil then setupParts(s, car) end
  for _, P in ipairs(s.parts) do
    if P.state < 2 then
      local dist = (hit.p - P.c):length()
      local f = 1 - dist / (P.r + 0.6)
      if f > 0 then
        P.dmg = P.dmg + hit.kmh * f
        if P.state == 0 and P.dmg >= P.solta then
          P.state = 1
          if P.kind == 'region' then
            local okC, res = pcall(cutRegion, s, car, P)
            if not okC then log('carro', s.index, P.id, 'erro no recorte:', tostring(res):sub(1, 300)) res = nil end
            P.pieces = res
            if P.pieces then
              for _, pc in ipairs(P.pieces) do pc.rel0 = pc.W0:clone():mul(car.bodyTransform:inverse()) end
            else P.state = 3 end
          end
          if P.state == 1 then log('carro', s.index, P.id, 'solta', string.format('%.0f', P.dmg)) end
        end
        if P.state == 1 then
          local k = clamp((P.dmg - P.solta) / math.max(1, P.cai - P.solta), 0, 1)
          P.tilt = P.ang * (0.35 + 0.65 * k)
          if P.kind == 'node' then nodeTilt(s, P, P.tilt) else tiltPieces(s, car, P, P.tilt) end
          if P.dmg >= P.cai then
            P.state = 2
            startFall(s, car, P, fresh)
          end
        end
      end
    end
  end
end

local function partsUpdate(s, car, dt)
  if s.parts == nil then return end
  for _, P in ipairs(s.parts) do
    if P.state == 1 and P.kind == 'region' and P.pieces then tiltPieces(s, car, P, P.tilt or 0) end
    if P.state == 2 then safe('queda ' .. P.id, fallUpdate, s, P, dt) end
  end
end

local function partsRestore(s)
  if s.parts == nil then return end
  for _, P in ipairs(s.parts) do
    if P.fall then dropBody(P.fall) end
    if P.kind == 'node' then
      if P.oldParent then pcall(P.node.setParent, P.node, P.oldParent) end
      if P.L0 then pcall(function() P.node:getTransformationRaw():set(P.L0) end) end
      if P.holderNode then pcall(P.holderNode.dispose, P.holderNode) end
    else
      for _, pc in ipairs(P.pieces or {}) do pcall(pc.holder.dispose, pc.holder) end
    end
  end
  for k = #GONE_PIECES, 1, -1 do if GONE_PIECES[k].s == s then table.remove(GONE_PIECES, k) end end
  for _, m in ipairs(s.meshes or {}) do
    if m.orig then
      pcall(m.orig.setVisible, m.orig, true)
      if m.created then pcall(m.created.dispose, m.created) end
      m.ref, m.orig, m.created = m.orig, nil, nil
    end
    m.keep = nil
  end
  s.parts = nil
end

local function restore(s, why)
  safe('reparo das pecas', partsRestore, s)
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
  hit.fresh = fresh
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
    safe('pecas', partsHit, s, car, s.hits[k], s.hits[k].fresh)
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

local netN = 0
local function netLog(...)
  netN = netN + 1
  if netN <= 40 then log('[rede]', ...) end
end
if online then
  local okE, err = pcall(function()
    sendHit = ac.OnlineEvent({
      ac.StructItem.key('cjDanoBatida1'),
      px = ac.StructItem.int16(), py = ac.StructItem.int16(), pz = ac.StructItem.int16(),
      ux = ac.StructItem.int8(), uy = ac.StructItem.int8(), uz = ac.StructItem.int8(),
      kmh = ac.StructItem.uint8(),
    }, function(sender, m)
      netLog('recebi batida de', sender and sender.index or 'nil', m.kmh and (m.kmh .. ' km/h') or '')
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
      netLog('recebi resumo de', sender and sender.index or 'nil', m.n, 'batidas, reset', m.reset)
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
    netLog('enviei batida', q[7], 'km/h:', tostring(ok))
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
    local okR = sendResumo(msg, true)
    netLog('enviei resumo', msg.n, 'batidas:', tostring(okR))
    if okR then resumoDirty, resumoT, sendT = false, 0, 0 end
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
  pushHit(i, c, u, kmh)
end

-- registra uma batida do carro com física neste PC (aplica aqui, manda para os outros); também usada pela batida em peça
pushHit = function(i, c, u, kmh)
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
  if why and FURO[i] and s.resetCounter ~= nil then furoClear(i, why) end
  if why and #s.hits > 0 then
    restore(s, why)
    if ACC[i] then ACC[i].lastVel = nil ACC[i].on = false ACC[i].w = 0 end
    if i == 0 and online then outbox = {} resumoDirty = 'reset' end
  end
end

local sessao = sim.currentSessionIndex
log('v3.5 carregado; online:', online, 'mensagens:', sendHit ~= nil, 'physics.allowed:', tostring(physicsAllowed()))
pcall(function()
  local q = mat4x4.translation(vec3(1, 0, 0)):mul(mat4x4.rotation(math.pi / 2, vec3(0, 1, 0))):transformPoint(vec3())
  log(string.format('convencao mul: T*R leva a origem para (%.2f, %.2f, %.2f)', q.x, q.y, q.z))
end)

local function update(dt)
  sim = ac.getSim()
  if sim.isReplayActive then return end
  if sim.currentSessionIndex ~= sessao then
    sessao = sim.currentSessionIndex
    for _, s in pairs(C) do restore(s, 'sessao nova') end
    for i in pairs(FURO) do furoClear(i, 'sessao nova') end
  end
  for i = 0, sim.carsCount - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected then
      local s = carState(i)
      if not s.skip then
        checkReset(i, s, car, dt)
        local mine = (i == 0) or (not online and car.physicsAvailable)
        if mine then
          measure(i, s, car, dt)
          safe('furo', furoOver, i, car)
          safe('furo', furoUpdate, i, car, dt)
        end
        applyPending(s, car)
        partsUpdate(s, car, dt)
        if (#s.hits > 0) and car.distanceToCamera < 200 then pcall(ac.forceDetailedCarLOD, i) end
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
