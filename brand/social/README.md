# Peças de divulgação

Geradas a partir do ícone do app e da paleta Aurora (`client/lib/theme.dart`),
para a identidade ser a mesma nos dois lugares. Nada aqui é decorativo por
conta própria: se o tema do app mudar, estas mudam junto.

| Arquivo | Medida | Onde |
|---|---|---|
| `remoteone-perfil.png` | 1080×1080 | Foto de perfil |
| `remoteone-post.png` | 1080×1350 | Post (4:5, o formato que ocupa mais tela no feed) |

## Como refazer

As imagens saem de HTML renderizado pelo Chromium, e não de um editor. O
motivo é o de sempre neste projeto: o que dá para versionar e repetir vale
mais do que o que depende de alguém lembrar o que fez.

```bash
CHROME=/opt/pw-browsers/chromium-1194/chrome-linux/chrome   # ou o Chrome local
$CHROME --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1080,1260 --screenshot=_perfil.png file://$PWD/perfil.html
$CHROME --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1080,1530 --screenshot=_post.png file://$PWD/post.html
```

Renderize **maior** que o alvo e corte depois: o viewport do Chromium é menor
que a `--window-size`, e sem o corte sobra uma faixa clara no rodapé.

```python
from PIL import Image
Image.open('_perfil.png').convert('RGB').crop((0,0,1080,1080)).save('remoteone-perfil.png')
Image.open('_post.png').convert('RGB').crop((0,0,1080,1350)).save('remoteone-post.png')
```

## Decisões

- **A foto de perfil não tem texto.** O Instagram a recorta num círculo de
  ~40px na maioria das telas; qualquer palavra ali vira borrão. O desenho fica
  dentro de um círculo seguro, e as quinas são só fundo.
- **O post é 4:5**, não quadrado: ocupa mais altura no feed pelo mesmo scroll.
- **O gradiente da palavra em destaque começa claro.** Ele atravessa uma
  palavra curta; começando no violeta escuro da paleta, as primeiras letras
  somem no fundo. É a mesma cor da marca, deslocada para o claro.
- **A ilustração não tem seta nem ondas.** O celular mostra o mesmo monitor que
  está atrás dele - o espelhamento já diz que um comanda o outro, e as versões
  com arcos de sinal pareciam adorno solto.
