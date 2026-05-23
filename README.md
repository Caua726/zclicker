# zclicker

Autoclicker de mouse: **segure o botão 4 ou 5** (os laterais) e ele clica com o
**botão esquerdo** a cada 50ms, soltou parou. CLI, sem GUI.

Funciona no **Wayland** porque lê os botões direto da camada de input do kernel
(`/dev/input/eventX`), abaixo do compositor, e clica via `ydotool`.

## Status

- **v1 (agora):** Linux/Wayland via `ydotool`, modo **passivo** — os botões 4/5
  continuam fazendo voltar/avançar normalmente enquanto disparam o autoclick.

## Requisitos

- Zig `0.17.0-dev.305+bdfbf432d` (essa build usa a nova interface `Io` da std;
  versões diferentes do master podem não compilar).
- `ydotoold` rodando (o socket fica em `/run/user/<uid>/.ydotool_socket`).
  No Arch: `systemctl --user enable --now ydotool`.
- Seu usuário no grupo `input` (pra ler `/dev/input/eventX`).

## Build

```sh
zig build              # binário em zig-out/bin/zclicker
zig build test         # roda os testes
```

## Uso

```sh
zclicker                       # autodetecta o mouse, intervalo 50ms, botões 4 e 5
zclicker -i 30                 # 30ms entre cliques
zclicker -b 4                  # só o botão 4 dispara
zclicker -d /dev/input/event6  # força o dispositivo
zclicker --list                # lista mouses com botões laterais
zclicker --verbose             # loga cada gatilho e clique
```

`Ctrl+C` pra sair.

## Arquitetura

Pensada pra crescer cross-platform sem refatorar o núcleo. Cada peça tem um papel
e conversa por uma interface:

```
src/
  main.zig              CLI: parse args -> monta backends -> roda o loop
  cli.zig               parsing de argumentos
  core.zig              máquina de estado (botão segurado -> clica a cada Nms)
  input/
    input.zig           interface InputBackend + tipos de evento
    linux_evdev.zig     lê /dev/input via syscalls (poll/read/ioctl)
  output/
    output.zig          interface OutputBackend
    ydotool.zig         clica via `ydotool click 0xC0`
```

O loop é **single-thread**: o tempo entre cliques vem do timeout do `poll()`, sem
threads nem locks.

## Roadmap

1. **Supressão de navegação** — capturar o mouse (`EVIOCGRAB`) e re-injetar tudo
   via `uinput` menos os botões 4/5, pra eles não dispararem voltar/avançar.
2. **X11** — backend de saída via XTest.
3. **Windows** — input via Raw Input, saída via `SendInput`.
