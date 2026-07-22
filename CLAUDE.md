# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

QGroundControl is a ground control station for drones (PX4/ArduPilot), built with **C++20 + Qt 6.11** and **QML** for UI. It communicates with vehicles via MAVLink over serial, UDP, TCP, and Bluetooth.

The canonical AI-agent guide is [AGENTS.md](AGENTS.md) — read it first. It covers golden rules, critical files, code structure, build/test commands, the definition of done, and commit conventions. This file adds Claude Code-specific context and does not duplicate that content.

## How to Work in This Repo

Activate the project venv before running `just` — the system `just` (1.21) is too old:

```bash
source .venv/bin/activate
just build              # incremental build
just test               # run unit+integration tests
just lint               # pre-commit gate
just check              # lint + test — run before declaring done
```

Run a single test:

```bash
./build/Debug/QGroundControl --unittest:FactSystemTest
ctest -R FactSystemTest --output-on-failure
```

## Code Search

Prefer **Lexis MCP** tools (`mcp__lexis__*`) over Grep/Read for code exploration — they're ~10× more token-efficient. Default workflow: `notes` → `search_code` → `get_symbol` → `read_file` (with offset/limit). Use `call_chain` for tracing execution paths and `impact_analysis` before refactoring.

## Local Environment Notes

- Qt 6.11.1 is at `~/Qt/6.11.1/gcc_64/`; CMake `CMAKE_PREFIX_PATH` is set in `.vscode/settings.json`
- Git is configured to use SSH for GitHub (`git@github.com:` instead of `https://github.com/`) due to WSL2 HTTPS instability
- VS Code config is in `.vscode/` (settings.json, launch.json, tasks.json); install the recommended extensions
- The build uses **ccache** + **mold** linker for fast incremental builds
- **MAVLink Extensions** — custom messages 51000-51003 for VTOL safety management live in `src/MAVLink/Extensions/`; protocol doc at `docs/mavlink_extension_protocol.md`.`QML` singleton `VTOLExtensions` exposes static send helpers; enums via `VTOLExtensionsEnums` namespace.
