# zclicker

Autoclicker de mouse: **segure o botão 4 ou 5** (os laterais) e ele clica com o
**botão esquerdo** a cada 50ms, soltou parou. CLI, sem GUI.

Funciona no **Wayland** porque lê os botões direto da camada de input do kernel
(`/dev/input/eventX`), abaixo do compositor, e injeta cliques via `uinput`
(sem daemon) ou `ydotool` como fallback.

## Status

- **v2 (agora):** sistema de backends plugável. Saída padrão via **uinput** nativo
  (sem daemon), **ydotool** como fallback. Supressão de navegação disponível com
  `--suppress` (os botões 4/5 param de disparar voltar/avançar enquanto o
  autoclick está ativo). Input via evdev.

## Backends

| Tipo   | ID       | Descrição                                               |
|--------|----------|---------------------------------------------------------|
| Input  | `evdev`  | Universal, lê `/dev/input/eventX` direto do kernel      |
| Output | `uinput` | **Padrão.** Sem daemon; precisa de acesso a `/dev/uinput` |
| Output | `ydotool`| Fallback; precisa do `ydotoold` rodando                 |
| Output | `wlr`    | wlroots virtual pointer (Hyprland/Sway, no daemon)      |
| Output | `x11`    | X11 XTest extension (`XTestFakeButtonEvent`)             |

**Seleção automática:** prefere `wlr` em sessões Wayland, `x11` em sessões X11,
depois `uinput`, depois `ydotool`. Use `--input` / `--output` para forçar um
backend, ou `--list-backends` para ver os disponíveis.

## Requisitos

- Zig `0.17.0-dev.305+bdfbf432d` (essa build usa a nova interface `Io` da std;
  versões diferentes do master podem não compilar).
- **Dependências de build:** `wayland-client` + `wayland-scanner` (o backend `wlr`
  é sempre compilado no engine, então até um `zig build` simples precisa delas).
  `libX11` + `libXtst` (o backend `x11` também é sempre compilado; instale
  `libx11-dev` / `xorg-x11-libXtst-devel` ou equivalente na sua distro).
- Seu usuário no grupo `input` (pra ler `/dev/input/eventX`).
- **Backend uinput (padrão):** acesso de escrita a `/dev/uinput`. Instale a
  regra udev (veja [Permissões](#permissões)) ou rode com `sudo`.
- **Backend ydotool (opcional/fallback):** `ydotoold` rodando. No Arch:
  `systemctl --user enable --now ydotool`.

## Build

```sh
zig build              # binário em zig-out/bin/zclicker
zig build test         # roda os testes
```

## GUI

Janela nativa **GTK4** embutida no próprio binário `zclicker`. Quando compilado
com `-Dgui`, rodar `zclicker` sem argumentos abre a janela; rodar com flags
executa o engine normalmente.

```sh
zig build -Dgui                  # compila com GUI (precisa das libs de dev do GTK4)
./zig-out/bin/zclicker           # sem argumentos → abre a janela GTK4
./zig-out/bin/zclicker -i 30     # com flags → executa o engine diretamente
```

Um `zig build` simples (sem `-Dgui`) gera um binário GTK-free; `zclicker` sem
argumentos nesse caso executa o engine com os padrões.

A GUI **spawna o mesmo binário** com as flags do engine (lê `/proc/self/exe`
pra encontrar o próprio executável). As permissões de `/dev/uinput` continuam
valendo (veja [Permissões](#permissões)), e a captura de gatilho na GUI lê
`/dev/input`, então o grupo `input` também é necessário.

## Uso

```sh
zclicker                        # autodetecta o mouse, intervalo 50ms, botões 4 e 5
zclicker -i 30                  # 30ms entre cliques
zclicker -b 4                   # só o botão 4 dispara
zclicker -d /dev/input/event6   # força o dispositivo
zclicker --list                 # lista mouses com botões laterais
zclicker --verbose              # loga cada gatilho e clique
zclicker --suppress             # suprime voltar/avançar nos botões 4/5
zclicker --output ydotool       # força backend de saída ydotool
zclicker --output uinput        # força backend de saída uinput (padrão)
zclicker --input evdev          # força backend de entrada evdev (único disponível)
zclicker --list-backends        # lista backends disponíveis
```

`Ctrl+C` pra sair.

Opções completas:

```
  -i, --interval <ms>    intervalo entre cliques (padrão 50)
  -b, --buttons <lista>  botões-gatilho, ex: 4,5 (padrão 4,5)
  -d, --device <path>    /dev/input/eventX (padrão: autodetecta)
  -l, --list             lista dispositivos com botões laterais
  -v, --verbose          loga cada gatilho e clique
      --suppress         suprime voltar/avançar nos botões 4/5 (via EVIOCGRAB)
      --input <backend>  entrada: evdev
      --output <backend> saída: uinput (padrão) ou ydotool
      --list-backends    lista backends disponíveis
  -h, --help             esta ajuda
```

## Permissões

Para usar o backend `uinput` (padrão) sem `sudo`, instale a regra udev:

```sh
sudo cp packaging/99-zclicker-uinput.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
sudo modprobe uinput
```

Como você já está no grupo `input` (requisito para ler o evdev), não é preciso
`sudo` para rodar o zclicker após isso.

Alternativas:
- Rodar com `sudo` (sem instalar a regra).
- Usar `--output ydotool`, que não precisa de `/dev/uinput` (só do `ydotoold`).

## Arquitetura

Pensada pra crescer cross-platform sem refatorar o núcleo. Cada peça tem um papel
e conversa por uma interface:

```
src/
  main.zig              CLI: parse args -> seleciona/monta backends -> roda o loop
  cli.zig               parsing de argumentos
  core.zig              máquina de estado (botão segurado -> clica a cada Nms)
  backend.zig           interfaces InputBackend/OutputBackend + Capabilities + BackendId
  select.zig            seleção automática de backend + fallback (pura, testada)
  platform/
    linux.zig           helpers de syscall/ioctl, criação de uinput, clock monotônico
  input/
    evdev.zig           lê /dev/input (poll/read/ioctl) + supressão (grab + re-inject)
  output/
    uinput.zig          clica via /dev/uinput (sem daemon)
    ydotool.zig         clica via `ydotool click 0xC0`
```

O loop é **single-thread**: o tempo entre cliques vem do timeout do `poll()`, sem
threads nem locks.

## Roadmap

1. ~~**Supressão de navegação** — capturar o mouse (`EVIOCGRAB`) e re-injetar tudo
   via `uinput` menos os botões 4/5, pra eles não dispararem voltar/avançar.~~ ✅ feito
2. ~~**X11** — backend de saída via XTest.~~ ✅ feito
3. **Windows** — input via Raw Input, saída via `SendInput`.
