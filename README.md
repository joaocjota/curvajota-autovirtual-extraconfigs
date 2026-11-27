# Curva Jota: configurações extras dos servidores

Scripts online do CSP usados pelos servidores Curva Jota no Assetto Corsa.

- `online/curvajota_servidor.lua`: impõe a câmera do cockpit (fora dela a tela fica preta com aviso) e cobre a faixa do retrovisor virtual. Ligado nas opções extras do CSP do servidor:

```ini
[SCRIPT_CURVAJOTA]
SCRIPT = 'https://raw.githubusercontent.com/joaocjota/curvajota-autovirtual-extraconfigs/main/online/curvajota_servidor.lua'
REQUIRED = 1
```

- `online/curvajota_dano.lua`: dano online. Os carros amassam onde batem e todo mundo no servidor vê o mesmo amassado (a batida é medida pelo PC de quem bateu e vai para os outros numa mensagem curta; quem entra depois recebe um resumo). Voltar aos boxes, reiniciar ou teleportar repara. Faíscas na batida e fumaça quando o carro está muito batido. Peças (portas, capô, para-choques, asa) soltam, caem e viram objetos com física: quem bate nelas leva dano e amassado, e passar por cima pode dar furo lento (troca de pneus conserta). Carros com dano próprio (pasta com `cj_kwid_p500`) ficam de fora. Ligado com uma segunda seção:

```ini
[SCRIPT_CURVAJOTA_DANO]
SCRIPT = 'https://raw.githubusercontent.com/joaocjota/curvajota-autovirtual-extraconfigs/main/online/curvajota_dano.lua'
REQUIRED = 1
```
