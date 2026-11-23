-- Curva Jota: peças que caem dos carros viram objetos sólidos na pista (script online do CSP).
--
-- Como funciona: o script de dano do carro (extension/p500_dano.lua dos carros "detritos") solta a peça, faz ela cair
-- e deitar no chão num nó P500_SOLTA_<carro>_<peça> (ou P500_WING_FALL_<carro> para o aerofólio). Este script acha
-- esse nó, espera a peça parar, esconde o nó e põe no mesmo lugar uma cópia da peça (p500_destroco_<peça>.kn5 da
-- pasta do carro) presa a um corpo físico (physics.RigidBody) do tamanho dela. Aí a peça bate, é empurrada e rola.
-- O nó CJ_DETRITOS_SERVIDOR em carsRoot avisa o script do carro que o servidor cuida das peças (ele não deixa
-- outra cópia no reparo).
--
-- Cada PC simula as próprias peças: a posição de uma peça chutada pode ficar diferente de um PC para outro.
-- Ajustes na seção [SCRIPT_...] do servidor (valores abaixo são o padrão).

local cfg = ac.configValues({
  carros = '_detritos',   -- trecho do nome da pasta dos carros que soltam peças
  maxPecas = 40,          -- peças sólidas ao mesmo tempo na pista (as mais velhas somem)
  massa = 1.0,            -- multiplica a massa de todas as peças
  amortecimento = 0.15,   -- amortecimento linear/angular dos corpos
  depurar = 0,            -- 1 = mostra a caixa de colisão de cada peça
  log = 1,
})

local function log(...)
  if cfg.log ~= 1 then return end
  local t = {}
  for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
  ac.log('[CJ_DETRITOS] ' .. table.concat(t, ' '))
end

-- Peças: pivô (nó *_DMG no modelo), centro e meias medidas da peça (m, eixos do modelo: x esquerda, y cima, z frente)
-- e massa (kg). Medidas da tabela PECAS dos carros detritos v3 (gerar_tabela.py) e pivôs do kn5 da v0.9.36.
local PECAS = {
  asa          = { no = 'WING_FALL', arq = 'p500_asa_destrocos.kn5',     piv = vec3(0, 1.294, -1.4),       c = vec3(0, 1.30, -1.77),         h = vec3(0.57, 0.10, 0.21), kg = 7 },
  splitter     = { arq = 'p500_destroco_splitter.kn5',     piv = vec3(0, 0.085, 1.5),        c = vec3(0, 0.266, 1.715),        h = vec3(0.900, 0.194, 0.230), kg = 6 },
  difusor      = { arq = 'p500_destroco_difusor.kn5',      piv = vec3(0, 0.26, -1.715),      c = vec3(0, 0.277, -1.688),       h = vec3(0.651, 0.192, 0.273), kg = 6 },
  espelho_e    = { arq = 'p500_destroco_espelho_e.kn5',    piv = vec3(0.749, 0.93, 0.665),   c = vec3(0.816, 0.944, 0.606),    h = vec3(0.104, 0.053, 0.078), kg = 1.2 },
  espelho_d    = { arq = 'p500_destroco_espelho_d.kn5',    piv = vec3(-0.749, 0.93, 0.665),  c = vec3(-0.816, 0.944, 0.606),   h = vec3(0.104, 0.053, 0.078), kg = 1.2 },
  carenagem_de = { arq = 'p500_destroco_carenagem_de.kn5', piv = vec3(0.8, 0.72, 1.165),     c = vec3(0.678, 0.449, 1.210),    h = vec3(0.248, 0.287, 0.427), kg = 4 },
  carenagem_dd = { arq = 'p500_destroco_carenagem_dd.kn5', piv = vec3(-0.8, 0.72, 1.165),    c = vec3(-0.678, 0.449, 1.210),   h = vec3(0.248, 0.287, 0.427), kg = 4 },
  carenagem_te = { arq = 'p500_destroco_carenagem_te.kn5', piv = vec3(0.8, 0.72, -1.258),    c = vec3(0.678, 0.517, -1.134),   h = vec3(0.248, 0.348, 0.564), kg = 5 },
  carenagem_td = { arq = 'p500_destroco_carenagem_td.kn5', piv = vec3(-0.8, 0.72, -1.258),   c = vec3(-0.678, 0.517, -1.134),  h = vec3(0.248, 0.348, 0.564), kg = 5 },
  saia_e       = { arq = 'p500_destroco_saia_e.kn5',       piv = vec3(0.8, 0.2, 0),          c = vec3(0.851, 0.155, -0.012),   h = vec3(0.061, 0.080, 0.807), kg = 3 },
  saia_d       = { arq = 'p500_destroco_saia_d.kn5',       piv = vec3(-0.8, 0.2, 0),         c = vec3(-0.851, 0.155, -0.012),  h = vec3(0.061, 0.080, 0.807), kg = 3 },
  parachoque_d = { arq = 'p500_destroco_parachoque_d.kn5', piv = vec3(0, 0.4, 1.8),          c = vec3(0, 0.352, 1.727),        h = vec3(0.804, 0.268, 0.149), kg = 8 },
  parachoque_t = { arq = 'p500_destroco_parachoque_t.kn5', piv = vec3(0, 0.45, -1.8),        c = vec3(0, 0.418, -1.799),       h = vec3(0.809, 0.252, 0.099), kg = 8 },
}
local IDS = {}
for id in pairs(PECAS) do IDS[#IDS + 1] = id end
table.sort(IDS)

local carsRoot = ac.findNodes('carsRoot:yes')
local cena = ac.findNodes('dynamicRoot:yes')
local marca = nil                 -- nó CJ_DETRITOS_SERVIDOR (aviso para o script do carro)
local vistos = {}                 -- nome do nó -> { pos, parado, feito }
local solidas = {}                -- peças sólidas na pista, em ordem de chegada
local fisicaOk = nil              -- nil = ainda não testado
local sessao = -1
local procura = 0

log('carregado; physics.allowed =', physics.allowed and physics.allowed() or 'sem physics')

local function criarMarca()
  if marca ~= nil or carsRoot == nil or carsRoot:size() == 0 then return end
  -- carsRoot só aceita nós de esfera (um nó comum ali derrubou o jogo no teste de 23/11)
  if carsRoot.createBoundingSphereNode == nil then marca = false return end
  local ok, n = pcall(carsRoot.createBoundingSphereNode, carsRoot, 'CJ_DETRITOS_SERVIDOR', 0.01)
  if ok and n ~= nil then marca = n else marca = false end
end

local function limparTudo(porque)
  for _, s in ipairs(solidas) do
    if s.body then pcall(s.body.dispose, s.body) end
    if s.model then pcall(s.model.dispose, s.model) end
  end
  if #solidas > 0 then log('pista limpa (' .. porque .. '):', #solidas, 'pecas') end
  solidas, vistos = {}, {}
end

local function descartarMaisVelha()
  local s = table.remove(solidas, 1)
  if s == nil then return end
  if s.body then pcall(s.body.dispose, s.body) end
  if s.model then pcall(s.model.dispose, s.model) end
end

-- troca o nó do carro (peça parada no chão) por cópia + corpo físico
local function solidificar(no, carIndex, id, P)
  if fisicaOk == false then return false end
  local W = no:getWorldTransformationRaw():clone()
  local pasta = ac.getFolder(ac.FolderID.ContentCars) .. '/' .. (ac.getCarID(carIndex) or '') .. '/extension/'
  local okB, body = pcall(physics.RigidBody,
    { physics.Collider.Box(P.h * 2, P.c - P.piv, nil, nil, cfg.depurar == 1) }, P.kg * cfg.massa)
  if not okB or body == nil then
    if fisicaOk == nil then log('CSP nao deixou criar corpo fisico:', body, '- as pecas ficam so visuais') end
    fisicaOk = false
    return false
  end
  fisicaOk = true
  local okM, model = pcall(cena.loadKN5, cena, pasta .. P.arq)
  if not okM or model == nil then
    log('nao achei a copia da peca', pasta .. P.arq, model)
    pcall(body.dispose, body)
    return false
  end
  pcall(body.setDamping, body, cfg.amortecimento, cfg.amortecimento, true)
  body:setTransformation(W)
  body:setVelocity(vec3())
  model:setTransformationFrom(body)
  no:setVisible(false)
  if #solidas >= cfg.maxPecas then descartarMaisVelha() end
  solidas[#solidas + 1] = { body = body, model = model, id = id, carro = carIndex }
  body:onCollision(function(ci)
    if ci ~= nil then log('carro', ci, 'acertou', id, string.format('%.0f km/h', body:getSpeedKmh())) end
  end)
  log('peca solida:', id, 'do carro', carIndex, 'em', W.position)
  return true
end

-- procura nós de peças soltas dos carros detritos (4 vezes por segundo)
local function procurar(dt)
  local sim = ac.getSim()
  for i = 0, sim.carsCount - 1 do
    local cid = ac.getCarID(i)
    if cid ~= nil and cid:find(cfg.carros, 1, true) then
      for _, id in ipairs(IDS) do
        local P = PECAS[id]
        local nome = P.no and ('P500_' .. P.no .. '_' .. i) or ('P500_SOLTA_' .. i .. '_' .. id)
        local nos = carsRoot:findNodes(nome)
        for k = 1, nos:size() do
          local no = nos:at(k)
          local chave = nome .. '#' .. k
          local v = vistos[chave]
          -- isVisible() só vale para malhas (em nó sempre dá false); para nó o certo é isActive()
          local ativo = true
          if no.isActive ~= nil then ativo = no:isActive() end
          if ativo then
            local pos = no:getWorldTransformationRaw().position:clone()
            if v == nil then log('achei peca solta:', nome, 'em', pos) end
            if v ~= nil and v.feito then
              -- já virou sólida: só conta de novo se o nó saiu do lugar (peça nova caindo depois de um reparo)
              if (pos - v.pos):length() > 0.3 then vistos[chave] = { pos = pos, parado = 0, feito = false } end
            elseif v == nil then
              v = { pos = pos, parado = 0, feito = false }
              vistos[chave] = v
            elseif (pos - v.pos):length() < 0.01 then
              v.parado = v.parado + dt
              if v.parado > 0.3 then v.feito = solidificar(no, i, id, P) or (fisicaOk == false) end
            else
              v.parado, v.pos = 0, pos
            end
          elseif v ~= nil and not v.feito then
            vistos[chave] = nil
          end
        end
      end
    end
  end
end

local espera = 3   -- s depois de carregar antes de mexer na cena dos carros
function script.update(dt)
  if espera > 0 then espera = espera - dt return end
  local sim = ac.getSim()
  if sim.currentSessionIndex ~= sessao then
    if sessao >= 0 then limparTudo('sessao nova') end
    sessao = sim.currentSessionIndex
  end
  criarMarca()
  procura = procura + dt
  if procura >= 0.25 then
    local passo = procura
    procura = 0
    local ok, err = pcall(procurar, passo)
    if not ok then log('erro:', err) end
  end
  for _, s in ipairs(solidas) do
    if s.model and s.body then s.model:setTransformationFrom(s.body) end
  end
end
