-- Curva Jota: script online dos servidores (CSP).
-- 1) Câmera: fora da câmera do cockpit (F1), a tela fica preta com aviso.
-- 2) Retrovisor virtual: a faixa do topo central onde ele aparece fica coberta.
-- Replay e espectador ficam livres. Valores ajustáveis na seção [SCRIPT_...] do servidor.

local cfg = ac.configValues({
  bloquearCamera = 1,      -- 1 = só cockpit
  cobrirRetrovisor = 1,    -- 1 = cobre a faixa do retrovisor virtual
  retroLargura = 0.30,     -- fração da largura da tela
  retroAltura = 0.11,      -- fração da altura da tela
  retroTopo = 0.0,         -- distância do topo, fração da altura
  tolerancia = 0.6,        -- segundos antes de apagar (troca rápida de câmera)
})

local foraHa = 0

ac.log('[CURVAJOTA] script do servidor carregado')

local function pilotando(sim)
  if sim.isReplayActive then return false end
  if sim.focusedCar ~= 0 then return false end
  return true
end

function script.update(dt)
  local sim = ac.getSim()
  if cfg.bloquearCamera == 1 and pilotando(sim) and sim.cameraMode ~= ac.CameraMode.Cockpit then
    foraHa = foraHa + dt
  else
    foraHa = 0
  end
end

function script.drawUI()
  local sim = ac.getSim()
  if not pilotando(sim) then return end
  local tela = ui.windowSize()

  if cfg.cobrirRetrovisor == 1 then
    local w, h = tela.x * cfg.retroLargura, tela.y * cfg.retroAltura
    local x0, y0 = (tela.x - w) / 2, tela.y * cfg.retroTopo
    ui.drawRectFilled(vec2(x0, y0), vec2(x0 + w, y0 + h), rgbm(0, 0, 0, 1))
  end

  if foraHa > cfg.tolerancia then
    ui.drawRectFilled(vec2(0, 0), tela, rgbm(0, 0, 0, 1))
    ui.dwriteDrawText('CURVA JOTA: use a câmera do cockpit (F1)', 30,
      vec2(tela.x / 2 - 330, tela.y / 2 - 20), rgbm(1, 1, 1, 1))
  end
end
