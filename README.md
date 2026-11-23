# Curva Jota: configurações extras dos servidores

Scripts online do CSP usados pelos servidores Curva Jota no Assetto Corsa.

- `online/curvajota_servidor.lua`: impõe a câmera do cockpit (fora dela a tela fica preta com aviso) e cobre a faixa do retrovisor virtual. Ligado nas opções extras do CSP do servidor:

```ini
[SCRIPT_CURVAJOTA]
SCRIPT = 'https://raw.githubusercontent.com/joaocjota/curvajota-autovirtual-extraconfigs/main/online/curvajota_servidor.lua'
REQUIRED = 1
```

- `online/curvajota_detritos.lua`: peças que caem dos carros "detritos" (aerofólio, splitter, difusor, retrovisores, carenagens, saias, para-choques) viram objetos sólidos na pista. O script do carro faz a peça cair; quando ela para no chão, este script troca por uma cópia com corpo físico (`physics.RigidBody`), que bate, é empurrada e rola. Só age em carros cuja pasta tem `_detritos` no nome.

```ini
[SCRIPT_...]
SCRIPT = "https://raw.githubusercontent.com/joaocjota/curvajota-autovirtual-extraconfigs/main/online/curvajota_detritos.lua"
REQUIRED = 0
MAX_PECAS = 40
```

Ajustes (todos opcionais): `CARROS` (trecho do nome da pasta, padrão `_detritos`), `MAX_PECAS`, `MASSA` (multiplicador), `AMORTECIMENTO`, `DEPURAR` (1 mostra a caixa de colisão), `LOG`. No log do CSP as linhas começam com `[CJ_DETRITOS]`.
