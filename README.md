# Centtrix OS

> **Centtrix OS 3.5** — небольшая 64-bit операционная система на NASM для x86-64, собранная в один загрузочный образ.

![CenttrixOS](https://i.postimg.cc/DyJyH8NS/jijiwfdwf.jpg)

[![Build](https://github.com/kochvalds/centtrix/actions/workflows/build.yml/badge.svg)](https://github.com/kochvalds/centtrix/actions/workflows/build.yml)

Centtrix — экспериментальная ОС с собственным графическим интерфейсом, файловой системой, терминалом, редактором, языком XPL и простым браузером/сетевым стеком.

## ✨ Возможности

- **x86-64 long mode** с собственным bootloader и переходом real → protected → long mode.
- **VBE framebuffer** с настраиваемым разрешением и графическим desktop.
- **Window manager** с окнами, alpha-compositing, текстовым рендерингом и dock.
- **CNTX filesystem** с `/base`, `/dump` и `/home`.
- **Терминал** и базовые файловые команды.
- **Vim-like editor** для `.txt` и `.xep`.
- **XPL 1.0** — встроенный скриптовый язык для небольших программ.
- **Browser** для локальных HTML-страниц и сетевых HTTP/HTTPS запросов.
- **Intel e1000** networking, DHCP, DNS и ping.
- **PS/2 keyboard + mouse**.
- Английская, русская и испанская раскладки.

## 🧱 Архитектура

Весь основной код находится в одном NASM-файле:

```text
src/centtrix.asm
```

Внутри исходника последовательно расположены:

```text
Boot sector
    ↓
Stage 2 / BIOS / VBE
    ↓
Protected mode
    ↓
Paging + PAE
    ↓
x86-64 long mode
    ↓
Kernel
    ├── graphics / compositor
    ├── window manager
    ├── input
    ├── filesystem
    ├── shell
    ├── editor
    ├── XPL runtime
    ├── browser
    └── networking
```

## 🔨 Сборка

### Требования

- Linux/macOS/WSL или другая среда с NASM
- QEMU — если хотите запускать образ

Проверить инструменты:

```bash
nasm -v
qemu-system-x86_64 --version
```

Сборка:

```bash
make
```

Готовый образ:

```text
build/centtrix.img
```

Без Make:

```bash
mkdir -p build
nasm -f bin src/centtrix.asm -o build/centtrix.img
```

## ▶️ Запуск

```bash
make run
```

Или напрямую:

```bash
qemu-system-x86_64 \
  -drive format=raw,file=build/centtrix.img \
  -m 256 \
  -rtc base=localtime
```

Для нормальной работы выделяйте QEMU не меньше **96 MB RAM**; пример выше использует 256 MB.

## 🖥️ Внутри Centtrix

После загрузки доступны desktop, terminal, Files, Editor, Browser, Monitor, Settings и About.

Примеры терминала:

```text
help
ls
cd /home
cat notes.txt
edit notes.txt
run hello.xep
mkdir projects
cp hello.xep /home/projects/hello.xep
```

## 🧪 XPL

XPL-программы используют расширение `.xep`.

Минимальный пример:

```text
color 4
say "Hello from XPL!"
let n 1
repeat 5
  print n
  add n 1
next
```

Поддерживаются, среди прочего, `say`, `print`, `let`, `add`, `sub`, `mul`, `at`, `color`, `clear`, `box`, `wait` и циклы `repeat/next`.

## ⌨️ Редактор

Редактор вдохновлён Vim:

| Клавиша | Действие |
|---|---|
| `i` | insert mode |
| `Esc` | normal mode |
| `:w` | сохранить |
| `:q` | выйти |
| `:wq` | сохранить и выйти |
| `:r` | запустить `.xep` |

## 🌐 Сеть

Centtrix содержит драйвер Intel e1000 и поддержку DHCP/DNS/ping и web-запросов.

> **Важно:** HTTPS в текущей реализации не проверяет сертификат сервера. Не вводите реальные пароли или другую чувствительную информацию при тестировании сетевых функций.

## 📁 Структура репозитория

```text
centtrix/
├── .github/
│   └── workflows/
│       └── build.yml
├── src/
│   └── centtrix.asm
├── Makefile
├── README.md
└── .gitignore
```

## 🎯 Проект

Centtrix — учебно-экспериментальная ОС и одновременно playground для низкоуровневого программирования: BIOS, VBE, paging, x86-64, файловых систем, GUI, драйверов и собственного языка.

Если проект оказался полезен или интересен — ⭐ репозиторию приветствуется.

**Author:** [kochvalds](https://github.com/kochvalds)
