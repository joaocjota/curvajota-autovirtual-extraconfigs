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
  maxPecas = 120,         -- peças sólidas ao mesmo tempo na pista (as mais velhas somem); 28/11: 120 por causa dos pedaços da v0.9.39
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
  -- v0.9.39 detritos 10 (28/11): cada peça em 10 pedaços (retrovisores em 3), um kn5 por pedaço; gerado por gerar_tabela10.py
  parachoque_d_0 = { arq = 'p500_destroco_parachoque_d_0.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.316, 0.228, 1.720), h = vec3(0.156, 0.144, 0.142), kg = 0.80 },
  parachoque_d_1 = { arq = 'p500_destroco_parachoque_d_1.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(-0.551, 0.486, 1.729), h = vec3(0.253, 0.134, 0.129), kg = 0.80 },
  parachoque_d_2 = { arq = 'p500_destroco_parachoque_d_2.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.003, 0.231, 1.721), h = vec3(0.162, 0.147, 0.143), kg = 0.80 },
  parachoque_d_3 = { arq = 'p500_destroco_parachoque_d_3.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(-0.667, 0.228, 1.709), h = vec3(0.135, 0.144, 0.131), kg = 0.80 },
  parachoque_d_4 = { arq = 'p500_destroco_parachoque_d_4.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.671, 0.396, 1.727), h = vec3(0.133, 0.224, 0.127), kg = 0.80 },
  parachoque_d_5 = { arq = 'p500_destroco_parachoque_d_5.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.575, 0.236, 1.716), h = vec3(0.197, 0.152, 0.138), kg = 0.80 },
  parachoque_d_6 = { arq = 'p500_destroco_parachoque_d_6.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(-0.223, 0.352, 1.721), h = vec3(0.148, 0.268, 0.143), kg = 0.80 },
  parachoque_d_7 = { arq = 'p500_destroco_parachoque_d_7.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(-0.430, 0.289, 1.716), h = vec3(0.143, 0.205, 0.138), kg = 0.80 },
  parachoque_d_8 = { arq = 'p500_destroco_parachoque_d_8.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.000, 0.458, 1.727), h = vec3(0.250, 0.162, 0.149), kg = 0.80 },
  parachoque_d_9 = { arq = 'p500_destroco_parachoque_d_9.kn5', piv = vec3(0.0000, 0.4000, 1.8000), c = vec3(0.379, 0.492, 1.798), h = vec3(0.196, 0.128, 0.063), kg = 0.80 },
  parachoque_t_0 = { arq = 'p500_destroco_parachoque_t_0.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.685, 0.508, -1.780), h = vec3(0.125, 0.162, 0.080), kg = 0.80 },
  parachoque_t_1 = { arq = 'p500_destroco_parachoque_t_1.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(-0.624, 0.570, -1.792), h = vec3(0.185, 0.100, 0.092), kg = 0.80 },
  parachoque_t_2 = { arq = 'p500_destroco_parachoque_t_2.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.139, 0.522, -1.818), h = vec3(0.194, 0.148, 0.080), kg = 0.80 },
  parachoque_t_3 = { arq = 'p500_destroco_parachoque_t_3.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(-0.623, 0.331, -1.792), h = vec3(0.183, 0.166, 0.092), kg = 0.80 },
  parachoque_t_4 = { arq = 'p500_destroco_parachoque_t_4.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.213, 0.308, -1.797), h = vec3(0.208, 0.143, 0.097), kg = 0.80 },
  parachoque_t_5 = { arq = 'p500_destroco_parachoque_t_5.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(-0.079, 0.319, -1.792), h = vec3(0.391, 0.153, 0.092), kg = 0.80 },
  parachoque_t_6 = { arq = 'p500_destroco_parachoque_t_6.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.464, 0.522, -1.825), h = vec3(0.158, 0.148, 0.071), kg = 0.80 },
  parachoque_t_7 = { arq = 'p500_destroco_parachoque_t_7.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.602, 0.258, -1.784), h = vec3(0.201, 0.093, 0.084), kg = 0.80 },
  parachoque_t_8 = { arq = 'p500_destroco_parachoque_t_8.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(0.599, 0.422, -1.834), h = vec3(0.189, 0.133, 0.081), kg = 0.80 },
  parachoque_t_9 = { arq = 'p500_destroco_parachoque_t_9.kn5', piv = vec3(0.0000, 0.4500, -1.8000), c = vec3(-0.248, 0.511, -1.822), h = vec3(0.229, 0.159, 0.076), kg = 0.80 },
  splitter_0 = { arq = 'p500_destroco_splitter_0.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(-0.120, 0.078, 1.790), h = vec3(0.191, 0.010, 0.155), kg = 0.60 },
  splitter_1 = { arq = 'p500_destroco_splitter_1.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(0.660, 0.078, 1.797), h = vec3(0.187, 0.010, 0.144), kg = 0.60 },
  splitter_2 = { arq = 'p500_destroco_splitter_2.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(0.108, 0.078, 1.677), h = vec3(0.216, 0.010, 0.192), kg = 0.60 },
  splitter_3 = { arq = 'p500_destroco_splitter_3.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(0.790, 0.266, 1.662), h = vec3(0.110, 0.194, 0.177), kg = 0.60 },
  splitter_4 = { arq = 'p500_destroco_splitter_4.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(-0.802, 0.266, 1.637), h = vec3(0.098, 0.194, 0.152), kg = 0.60 },
  splitter_5 = { arq = 'p500_destroco_splitter_5.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(0.506, 0.078, 1.626), h = vec3(0.185, 0.010, 0.141), kg = 0.60 },
  splitter_6 = { arq = 'p500_destroco_splitter_6.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(-0.481, 0.078, 1.803), h = vec3(0.173, 0.010, 0.141), kg = 0.60 },
  splitter_7 = { arq = 'p500_destroco_splitter_7.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(0.277, 0.078, 1.787), h = vec3(0.208, 0.010, 0.158), kg = 0.60 },
  splitter_8 = { arq = 'p500_destroco_splitter_8.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(-0.331, 0.078, 1.621), h = vec3(0.225, 0.010, 0.136), kg = 0.60 },
  splitter_9 = { arq = 'p500_destroco_splitter_9.kn5', piv = vec3(0.0000, 0.0850, 1.5000), c = vec3(-0.707, 0.078, 1.705), h = vec3(0.187, 0.010, 0.220), kg = 0.60 },
  difusor_0 = { arq = 'p500_destroco_difusor_0.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(-0.580, 0.270, -1.844), h = vec3(0.071, 0.185, 0.116), kg = 0.60 },
  difusor_1 = { arq = 'p500_destroco_difusor_1.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(0.500, 0.138, -1.567), h = vec3(0.150, 0.038, 0.150), kg = 0.60 },
  difusor_2 = { arq = 'p500_destroco_difusor_2.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(-0.500, 0.151, -1.603), h = vec3(0.150, 0.051, 0.186), kg = 0.60 },
  difusor_3 = { arq = 'p500_destroco_difusor_3.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(0.222, 0.359, -1.824), h = vec3(0.149, 0.111, 0.109), kg = 0.60 },
  difusor_4 = { arq = 'p500_destroco_difusor_4.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(-0.430, 0.175, -1.813), h = vec3(0.101, 0.090, 0.147), kg = 0.60 },
  difusor_5 = { arq = 'p500_destroco_difusor_5.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(0.580, 0.173, -1.813), h = vec3(0.071, 0.088, 0.147), kg = 0.60 },
  difusor_6 = { arq = 'p500_destroco_difusor_6.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(0.297, 0.263, -1.824), h = vec3(0.074, 0.178, 0.136), kg = 0.60 },
  difusor_7 = { arq = 'p500_destroco_difusor_7.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(-0.044, 0.359, -1.790), h = vec3(0.134, 0.111, 0.075), kg = 0.60 },
  difusor_8 = { arq = 'p500_destroco_difusor_8.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(0.580, 0.338, -1.880), h = vec3(0.071, 0.117, 0.080), kg = 0.60 },
  difusor_9 = { arq = 'p500_destroco_difusor_9.kn5', piv = vec3(0.0000, 0.2600, -1.7150), c = vec3(-0.259, 0.353, -1.838), h = vec3(0.112, 0.117, 0.123), kg = 0.60 },
  carenagem_de_0 = { arq = 'p500_destroco_carenagem_de_0.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.573, 0.601, 1.007), h = vec3(0.143, 0.081, 0.148), kg = 0.40 },
  carenagem_de_1 = { arq = 'p500_destroco_carenagem_de_1.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.584, 0.372, 1.488), h = vec3(0.154, 0.177, 0.038), kg = 0.40 },
  carenagem_de_2 = { arq = 'p500_destroco_carenagem_de_2.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.816, 0.327, 0.810), h = vec3(0.109, 0.149, 0.029), kg = 0.40 },
  carenagem_de_3 = { arq = 'p500_destroco_carenagem_de_3.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.802, 0.591, 0.851), h = vec3(0.123, 0.130, 0.068), kg = 0.40 },
  carenagem_de_4 = { arq = 'p500_destroco_carenagem_de_4.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.797, 0.651, 1.030), h = vec3(0.128, 0.086, 0.156), kg = 0.40 },
  carenagem_de_5 = { arq = 'p500_destroco_carenagem_de_5.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.567, 0.610, 1.299), h = vec3(0.137, 0.072, 0.160), kg = 0.40 },
  carenagem_de_6 = { arq = 'p500_destroco_carenagem_de_6.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.573, 0.366, 0.834), h = vec3(0.143, 0.158, 0.030), kg = 0.40 },
  carenagem_de_7 = { arq = 'p500_destroco_carenagem_de_7.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.799, 0.313, 1.567), h = vec3(0.126, 0.151, 0.070), kg = 0.40 },
  carenagem_de_8 = { arq = 'p500_destroco_carenagem_de_8.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.782, 0.580, 1.508), h = vec3(0.143, 0.143, 0.125), kg = 0.40 },
  carenagem_de_9 = { arq = 'p500_destroco_carenagem_de_9.kn5', piv = vec3(0.8000, 0.7200, 1.1650), c = vec3(0.813, 0.671, 1.301), h = vec3(0.112, 0.065, 0.144), kg = 0.40 },
  carenagem_te_0 = { arq = 'p500_destroco_carenagem_te_0.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.752, 0.706, -1.043), h = vec3(0.173, 0.150, 0.162), kg = 0.50 },
  carenagem_te_1 = { arq = 'p500_destroco_carenagem_te_1.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.590, 0.431, -1.562), h = vec3(0.160, 0.212, 0.075), kg = 0.50 },
  carenagem_te_2 = { arq = 'p500_destroco_carenagem_te_2.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.581, 0.433, -0.967), h = vec3(0.151, 0.226, 0.088), kg = 0.50 },
  carenagem_te_3 = { arq = 'p500_destroco_carenagem_te_3.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.804, 0.656, -1.571), h = vec3(0.121, 0.157, 0.125), kg = 0.50 },
  carenagem_te_4 = { arq = 'p500_destroco_carenagem_te_4.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.781, 0.317, -0.740), h = vec3(0.144, 0.149, 0.170), kg = 0.50 },
  carenagem_te_5 = { arq = 'p500_destroco_carenagem_te_5.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.822, 0.749, -1.327), h = vec3(0.103, 0.089, 0.173), kg = 0.50 },
  carenagem_te_6 = { arq = 'p500_destroco_carenagem_te_6.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.577, 0.674, -1.272), h = vec3(0.147, 0.039, 0.224), kg = 0.50 },
  carenagem_te_7 = { arq = 'p500_destroco_carenagem_te_7.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.855, 0.706, -0.756), h = vec3(0.063, 0.159, 0.159), kg = 0.50 },
  carenagem_te_8 = { arq = 'p500_destroco_carenagem_te_8.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.790, 0.356, -1.643), h = vec3(0.135, 0.170, 0.055), kg = 0.50 },
  carenagem_te_9 = { arq = 'p500_destroco_carenagem_te_9.kn5', piv = vec3(0.8000, 0.7200, -1.2580), c = vec3(0.824, 0.528, -0.778), h = vec3(0.101, 0.147, 0.193), kg = 0.50 },
  carenagem_dd_0 = { arq = 'p500_destroco_carenagem_dd_0.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.795, 0.307, 1.567), h = vec3(0.130, 0.145, 0.070), kg = 0.40 },
  carenagem_dd_1 = { arq = 'p500_destroco_carenagem_dd_1.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.807, 0.313, 0.805), h = vec3(0.118, 0.135, 0.024), kg = 0.40 },
  carenagem_dd_2 = { arq = 'p500_destroco_carenagem_dd_2.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.576, 0.376, 1.485), h = vec3(0.146, 0.180, 0.041), kg = 0.40 },
  carenagem_dd_3 = { arq = 'p500_destroco_carenagem_dd_3.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.577, 0.353, 0.826), h = vec3(0.147, 0.145, 0.022), kg = 0.40 },
  carenagem_dd_4 = { arq = 'p500_destroco_carenagem_dd_4.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.575, 0.584, 0.984), h = vec3(0.145, 0.096, 0.143), kg = 0.40 },
  carenagem_dd_5 = { arq = 'p500_destroco_carenagem_dd_5.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.798, 0.569, 0.879), h = vec3(0.127, 0.147, 0.096), kg = 0.40 },
  carenagem_dd_6 = { arq = 'p500_destroco_carenagem_dd_6.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.798, 0.658, 1.319), h = vec3(0.127, 0.078, 0.158), kg = 0.40 },
  carenagem_dd_7 = { arq = 'p500_destroco_carenagem_dd_7.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.557, 0.616, 1.279), h = vec3(0.127, 0.066, 0.170), kg = 0.40 },
  carenagem_dd_8 = { arq = 'p500_destroco_carenagem_dd_8.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.782, 0.672, 1.010), h = vec3(0.143, 0.064, 0.157), kg = 0.40 },
  carenagem_dd_9 = { arq = 'p500_destroco_carenagem_dd_9.kn5', piv = vec3(-0.8000, 0.7200, 1.1650), c = vec3(-0.792, 0.567, 1.518), h = vec3(0.133, 0.149, 0.116), kg = 0.40 },
  carenagem_td_0 = { arq = 'p500_destroco_carenagem_td_0.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.769, 0.328, -1.654), h = vec3(0.156, 0.142, 0.043), kg = 0.50 },
  carenagem_td_1 = { arq = 'p500_destroco_carenagem_td_1.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.721, 0.306, -0.740), h = vec3(0.204, 0.138, 0.170), kg = 0.50 },
  carenagem_td_2 = { arq = 'p500_destroco_carenagem_td_2.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.855, 0.739, -0.749), h = vec3(0.063, 0.126, 0.142), kg = 0.50 },
  carenagem_td_3 = { arq = 'p500_destroco_carenagem_td_3.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.584, 0.673, -1.278), h = vec3(0.154, 0.040, 0.220), kg = 0.50 },
  carenagem_td_4 = { arq = 'p500_destroco_carenagem_td_4.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.588, 0.429, -1.565), h = vec3(0.158, 0.210, 0.072), kg = 0.50 },
  carenagem_td_5 = { arq = 'p500_destroco_carenagem_td_5.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.794, 0.633, -1.585), h = vec3(0.131, 0.176, 0.112), kg = 0.50 },
  carenagem_td_6 = { arq = 'p500_destroco_carenagem_td_6.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.832, 0.564, -0.772), h = vec3(0.093, 0.144, 0.190), kg = 0.50 },
  carenagem_td_7 = { arq = 'p500_destroco_carenagem_td_7.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.595, 0.439, -0.978), h = vec3(0.165, 0.232, 0.098), kg = 0.50 },
  carenagem_td_8 = { arq = 'p500_destroco_carenagem_td_8.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.778, 0.715, -1.031), h = vec3(0.147, 0.142, 0.175), kg = 0.50 },
  carenagem_td_9 = { arq = 'p500_destroco_carenagem_td_9.kn5', piv = vec3(-0.8000, 0.7200, -1.2580), c = vec3(-0.806, 0.739, -1.375), h = vec3(0.119, 0.097, 0.191), kg = 0.50 },
  saia_e_0 = { arq = 'p500_destroco_saia_e_0.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, 0.347), h = vec3(0.061, 0.079, 0.101), kg = 0.30 },
  saia_e_1 = { arq = 'p500_destroco_saia_e_1.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, -0.472), h = vec3(0.061, 0.079, 0.092), kg = 0.30 },
  saia_e_2 = { arq = 'p500_destroco_saia_e_2.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, 0.023), h = vec3(0.061, 0.079, 0.069), kg = 0.30 },
  saia_e_3 = { arq = 'p500_destroco_saia_e_3.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, 0.723), h = vec3(0.061, 0.079, 0.072), kg = 0.30 },
  saia_e_4 = { arq = 'p500_destroco_saia_e_4.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.155, -0.750), h = vec3(0.061, 0.080, 0.068), kg = 0.30 },
  saia_e_5 = { arq = 'p500_destroco_saia_e_5.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, -0.298), h = vec3(0.061, 0.079, 0.083), kg = 0.30 },
  saia_e_6 = { arq = 'p500_destroco_saia_e_6.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, -0.130), h = vec3(0.061, 0.079, 0.085), kg = 0.30 },
  saia_e_7 = { arq = 'p500_destroco_saia_e_7.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, 0.550), h = vec3(0.061, 0.079, 0.102), kg = 0.30 },
  saia_e_8 = { arq = 'p500_destroco_saia_e_8.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, 0.169), h = vec3(0.061, 0.079, 0.077), kg = 0.30 },
  saia_e_9 = { arq = 'p500_destroco_saia_e_9.kn5', piv = vec3(0.8000, 0.2000, 0.0000), c = vec3(0.851, 0.154, -0.623), h = vec3(0.061, 0.079, 0.059), kg = 0.30 },
  saia_d_0 = { arq = 'p500_destroco_saia_d_0.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.452), h = vec3(0.061, 0.079, 0.080), kg = 0.30 },
  saia_d_1 = { arq = 'p500_destroco_saia_d_1.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.155, -0.722), h = vec3(0.061, 0.080, 0.096), kg = 0.30 },
  saia_d_2 = { arq = 'p500_destroco_saia_d_2.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, -0.150), h = vec3(0.061, 0.079, 0.111), kg = 0.30 },
  saia_d_3 = { arq = 'p500_destroco_saia_d_3.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.599), h = vec3(0.061, 0.079, 0.067), kg = 0.30 },
  saia_d_4 = { arq = 'p500_destroco_saia_d_4.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.127), h = vec3(0.061, 0.079, 0.057), kg = 0.30 },
  saia_d_5 = { arq = 'p500_destroco_saia_d_5.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, -0.543), h = vec3(0.061, 0.079, 0.082), kg = 0.30 },
  saia_d_6 = { arq = 'p500_destroco_saia_d_6.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.731), h = vec3(0.061, 0.079, 0.064), kg = 0.30 },
  saia_d_7 = { arq = 'p500_destroco_saia_d_7.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.015), h = vec3(0.061, 0.079, 0.055), kg = 0.30 },
  saia_d_8 = { arq = 'p500_destroco_saia_d_8.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, 0.278), h = vec3(0.061, 0.079, 0.094), kg = 0.30 },
  saia_d_9 = { arq = 'p500_destroco_saia_d_9.kn5', piv = vec3(-0.8000, 0.2000, 0.0000), c = vec3(-0.851, 0.154, -0.361), h = vec3(0.061, 0.079, 0.100), kg = 0.30 },
  capo_0 = { arq = 'p500_destroco_capo_0.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(0.229, 0.835, 1.464), h = vec3(0.257, 0.058, 0.205), kg = 1.00 },
  capo_1 = { arq = 'p500_destroco_capo_1.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(0.484, 0.841, 1.372), h = vec3(0.198, 0.059, 0.169), kg = 1.00 },
  capo_2 = { arq = 'p500_destroco_capo_2.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(-0.445, 0.779, 1.589), h = vec3(0.236, 0.086, 0.232), kg = 1.00 },
  capo_3 = { arq = 'p500_destroco_capo_3.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(0.224, 0.873, 1.117), h = vec3(0.265, 0.064, 0.177), kg = 1.00 },
  capo_4 = { arq = 'p500_destroco_capo_4.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(-0.255, 0.840, 1.432), h = vec3(0.231, 0.063, 0.189), kg = 1.00 },
  capo_5 = { arq = 'p500_destroco_capo_5.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(-0.239, 0.875, 1.107), h = vec3(0.250, 0.062, 0.167), kg = 1.00 },
  capo_6 = { arq = 'p500_destroco_capo_6.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(0.515, 0.876, 1.133), h = vec3(0.170, 0.060, 0.197), kg = 1.00 },
  capo_7 = { arq = 'p500_destroco_capo_7.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(-0.075, 0.742, 1.704), h = vec3(0.281, 0.059, 0.134), kg = 1.00 },
  capo_8 = { arq = 'p500_destroco_capo_8.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(-0.496, 0.868, 1.190), h = vec3(0.188, 0.069, 0.253), kg = 1.00 },
  capo_9 = { arq = 'p500_destroco_capo_9.kn5', piv = vec3(0.0000, 0.8987, 0.9350), c = vec3(0.420, 0.758, 1.667), h = vec3(0.261, 0.071, 0.166), kg = 1.00 },
  tampa_0 = { arq = 'p500_destroco_tampa_0.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(-0.348, 0.794, -1.796), h = vec3(0.219, 0.124, 0.042), kg = 1.20 },
  tampa_1 = { arq = 'p500_destroco_tampa_1.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(0.343, 0.847, -1.760), h = vec3(0.223, 0.177, 0.079), kg = 1.20 },
  tampa_2 = { arq = 'p500_destroco_tampa_2.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(0.280, 1.125, -1.579), h = vec3(0.116, 0.127, 0.128), kg = 1.20 },
  tampa_3 = { arq = 'p500_destroco_tampa_3.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(-0.436, 1.147, -1.544), h = vec3(0.129, 0.104, 0.114), kg = 1.20 },
  tampa_4 = { arq = 'p500_destroco_tampa_4.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(0.040, 0.810, -1.789), h = vec3(0.179, 0.140, 0.050), kg = 1.20 },
  tampa_5 = { arq = 'p500_destroco_tampa_5.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(-0.037, 0.987, -1.690), h = vec3(0.176, 0.145, 0.105), kg = 1.20 },
  tampa_6 = { arq = 'p500_destroco_tampa_6.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(-0.382, 0.980, -1.699), h = vec3(0.183, 0.115, 0.084), kg = 1.20 },
  tampa_7 = { arq = 'p500_destroco_tampa_7.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(-0.193, 1.159, -1.548), h = vec3(0.132, 0.094, 0.097), kg = 1.20 },
  tampa_8 = { arq = 'p500_destroco_tampa_8.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(0.459, 1.112, -1.577), h = vec3(0.106, 0.139, 0.147), kg = 1.20 },
  tampa_9 = { arq = 'p500_destroco_tampa_9.kn5', piv = vec3(0.0000, 1.2550, -1.5000), c = vec3(0.000, 1.120, -1.584), h = vec3(0.240, 0.133, 0.133), kg = 1.20 },
  espelho_e_0 = { arq = 'p500_destroco_espelho_e_0.kn5', piv = vec3(0.7490, 0.9300, 0.6650), c = vec3(0.840, 0.957, 0.572), h = vec3(0.080, 0.040, 0.044), kg = 0.40 },
  espelho_e_1 = { arq = 'p500_destroco_espelho_e_1.kn5', piv = vec3(0.7490, 0.9300, 0.6650), c = vec3(0.761, 0.920, 0.626), h = vec3(0.049, 0.029, 0.057), kg = 0.40 },
  espelho_e_2 = { arq = 'p500_destroco_espelho_e_2.kn5', piv = vec3(0.7490, 0.9300, 0.6650), c = vec3(0.840, 0.957, 0.534), h = vec3(0.070, 0.034, 0.010), kg = 0.40 },
  espelho_d_0 = { arq = 'p500_destroco_espelho_d_0.kn5', piv = vec3(-0.7490, 0.9300, 0.6650), c = vec3(-0.840, 0.957, 0.572), h = vec3(0.080, 0.040, 0.044), kg = 0.40 },
  espelho_d_1 = { arq = 'p500_destroco_espelho_d_1.kn5', piv = vec3(-0.7490, 0.9300, 0.6650), c = vec3(-0.761, 0.920, 0.626), h = vec3(0.049, 0.029, 0.057), kg = 0.40 },
  espelho_d_2 = { arq = 'p500_destroco_espelho_d_2.kn5', piv = vec3(-0.7490, 0.9300, 0.6650), c = vec3(-0.840, 0.957, 0.534), h = vec3(0.070, 0.034, 0.010), kg = 0.40 },
  asa_0 = { arq = 'p500_destroco_asa_0.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(-0.110, 1.272, -1.674), h = vec3(0.178, 0.026, 0.109), kg = 0.70 },
  asa_1 = { arq = 'p500_destroco_asa_1.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(0.158, 1.301, -1.833), h = vec3(0.164, 0.055, 0.146), kg = 0.70 },
  asa_2 = { arq = 'p500_destroco_asa_2.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(-0.424, 1.274, -1.693), h = vec3(0.146, 0.028, 0.128), kg = 0.70 },
  asa_3 = { arq = 'p500_destroco_asa_3.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(-0.435, 1.305, -1.873), h = vec3(0.135, 0.050, 0.107), kg = 0.70 },
  asa_4 = { arq = 'p500_destroco_asa_4.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(0.436, 1.278, -1.722), h = vec3(0.134, 0.031, 0.157), kg = 0.70 },
  asa_5 = { arq = 'p500_destroco_asa_5.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(0.442, 1.305, -1.873), h = vec3(0.128, 0.050, 0.107), kg = 0.70 },
  asa_6 = { arq = 'p500_destroco_asa_6.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(-0.148, 1.306, -1.878), h = vec3(0.155, 0.049, 0.102), kg = 0.70 },
  asa_7 = { arq = 'p500_destroco_asa_7.kn5', piv = vec3(0.0000, 1.2873, -1.7724), c = vec3(0.224, 1.275, -1.703), h = vec3(0.158, 0.029, 0.138), kg = 0.70 },
  asa_8 = { arq = 'p500_destroco_asa_8.kn5', piv = vec3(0.0000, 1.2940, -1.4000), c = vec3(0.575, 1.267, -1.781), h = vec3(0.010, 0.096, 0.295), kg = 0.70 },
  asa_9 = { arq = 'p500_destroco_asa_9.kn5', piv = vec3(0.0000, 1.2940, -1.4000), c = vec3(-0.575, 1.267, -1.781), h = vec3(0.010, 0.096, 0.295), kg = 0.70 },
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
local semArquivo = {}          -- caminhos de kn5 que o CSP não carregou

log('carregado; physics.allowed =', physics ~= nil and physics.allowed ~= nil and tostring(physics.allowed()) or 'sem physics')

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
  -- script de pista só lê arquivos da pasta da pista: a cópia fica em <pista>/extension/cj_detritos/<carro>/ (ou
  -- cj_detritos/ direto); a pasta do carro fica por último (script online pode conseguir ler)
  local cid = ac.getCarID(carIndex) or ''
  local dir = (__dirname or '.')
  local pistaExt = ac.getFolder(ac.FolderID.ContentTracks) .. '/' .. (ac.getTrackID() or '') .. '/extension/cj_detritos/'
  local tentativas = { dir .. '/cj_detritos/' .. cid .. '/' .. P.arq, dir .. '/cj_detritos/' .. P.arq, pistaExt .. P.arq, pasta .. P.arq }
  local model, usado = nil, nil
  for _, arq in ipairs(tentativas) do
    if not semArquivo[arq] then
      local okM, m = pcall(cena.loadKN5, cena, arq)
      if okM and m ~= nil then model, usado = m, arq break end
      semArquivo[arq] = true
      log('nao consegui carregar', arq, m)
    end
  end
  if model == nil then
    pcall(body.dispose, body)
    return nil      -- nil = desiste desta peça (não tenta de novo a cada 0,3 s)
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
  log('peca solida:', id, 'do carro', carIndex, 'em', W.position, 'kn5', usado)
  return true
end

-- procura nós de peças soltas dos carros detritos (4 vezes por segundo)
local function tratarNo(no, nome, i, id, P, chave, dt)
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
      vistos[chave] = { pos = pos, parado = 0, feito = false }
    elseif (pos - v.pos):length() < 0.01 then
      v.parado = v.parado + dt
      if v.parado > 0.3 then
        local r = solidificar(no, i, id, P)
        v.feito = (r ~= false) or (fisicaOk == false)     -- true = sólida; nil = sem cópia, desiste
      end
    else
      v.parado, v.pos = 0, pos
    end
  elseif v ~= nil and not v.feito then
    vistos[chave] = nil
  end
end

-- procura nós de peças soltas (4 vezes por segundo). Os nós ficam DIRETO em carsRoot (esferas criadas pelo script do
-- carro), então basta olhar os filhos diretos: buscar por nome na árvore inteira (findNodes) custava ~400 ms com 18
-- carros no servidor (teste de 23/11).
local carroOk = {}
local function procurar(dt)
  local filhos = carsRoot:getChildren()
  local n = filhos:size()
  local cont = {}
  for k = 1, n do
    local nome = filhos:name(k)
    if nome ~= nil and nome:sub(1, 5) == 'P500_' then
      local i, id = nome:match('^P500_SOLTA_(%d+)_(.+)$')
      if i == nil then
        i = nome:match('^P500_WING_FALL_(%d+)$')
        if i ~= nil then id = 'asa' end
      end
      if i ~= nil and PECAS[id] ~= nil then
        i = tonumber(i)
        if carroOk[i] == nil then
          local cid = ac.getCarID(i)
          carroOk[i] = cid ~= nil and cid:find(cfg.carros, 1, true) ~= nil
        end
        if carroOk[i] then
          cont[nome] = (cont[nome] or 0) + 1
          tratarNo(filhos:at(k), nome, i, id, PECAS[id], nome .. '#' .. cont[nome], dt)
        end
      end
    end
  end
end

local espera = 3   -- s depois de carregar antes de mexer na cena dos carros
-- sem permissão de física (ex.: script de PISTA online, onde o CSP não libera) o script não faz nada: as peças ficam só
-- visuais, como no script do carro. Online quem faz as peças sólidas é a cópia deste arquivo carregada pelo servidor.
local desligado = physics == nil or physics.allowed == nil or not physics.allowed()
if desligado then log('sem permissao de fisica aqui: script parado (pecas ficam so visuais)') end
function script.update(dt)
  if desligado then return end
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
