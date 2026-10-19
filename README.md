# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Arduino

Autocomplete, diagnósticos, `gd`/`gr` e compilar/enviar/monitor serial em arquivos
`.ino`, via `arduino-cli`. Em uma máquina nova, depois de clonar este repositório:

```sh
~/.config/nvim/arduino/setup.sh          # arduino-cli + language server (compila aqui)
arduino-cli core install arduino:avr      # só os cores que você usa; nenhum vem instalado
```

O language server é o `arduino-language-server` 0.7.7 com os patches de
`arduino/patches/` (referências para o `gr` e correção de posições com acentos).
Rodar o script de novo recompila e reinstala.

Atalhos (só em `.ino`): `<leader>ab` placa, `<leader>ao` opções da placa,
`<leader>av` compilar, `<leader>au` upload, `<leader>aU` upload + monitor,
`<leader>am` abre/fecha o monitor serial, `<leader>aq` fecha os painéis,
`<leader>ap` porta, `<leader>ai` info. A placa
escolhida fica no `sketch.yaml` do sketch.
