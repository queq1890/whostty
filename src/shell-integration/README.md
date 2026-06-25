# whostty shell integration

These scripts make a shell emit the [FinalTerm **OSC 133**][osc133] prompt marks
(`A`/`B`/`C`/`D`) that whostty's engine records as prompt/command boundaries
(`src/engine/semantic.zig`, #136). whomux reads those boundaries to tell, per
pane, whether the shell is *waiting at a prompt*, *running a command*, or *done*
(with the command's exit code), and to power command-boundary navigation.

| Sequence            | Meaning                                            |
| ------------------- | -------------------------------------------------- |
| `ESC ] 133 ; A BEL` | prompt start                                       |
| `ESC ] 133 ; B BEL` | prompt end / command input start                   |
| `ESC ] 133 ; C BEL` | command output start (the command is now running)  |
| `ESC ] 133 ; D ; n BEL` | command end, with exit status `n`              |

## Activation

The **environment is the contract.** On pane spawn whostty injects
`GHOSTTY_SHELL_INTEGRATION=1` (and `GHOSTTY_SHELL_FEATURES`) — see
`src/engine/env.zig`. A shell activates integration by sourcing the matching
script when that variable is present:

```bash
# ~/.bashrc
[ -n "$GHOSTTY_SHELL_INTEGRATION" ] && . "$WHOSTTY/shell-integration/bash"
```

```zsh
# ~/.zshrc
[[ -n "$GHOSTTY_SHELL_INTEGRATION" ]] && source "$WHOSTTY/shell-integration/zsh"
```

```fish
# config.fish
test -n "$GHOSTTY_SHELL_INTEGRATION"; and source "$WHOSTTY/shell-integration/fish"
```

These scripts ship next to the exe at `<whostty>/shell-integration/` (installed
by `build.zig`). Automatic injection of the script into the shell's startup
(without the user editing their rc) is per-shell and tracked as follow-up;
today activation is the one-line source above.

Windows' default `cmd.exe` cannot emit OSC 133; use bash/zsh/fish (e.g. via WSL
or Git Bash) for semantic prompt marks.

[osc133]: https://iterm2.com/documentation-escape-codes.html
