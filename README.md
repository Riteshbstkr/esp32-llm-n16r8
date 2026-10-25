# TinyStories LLM on an ESP32-S3 (N16R8)

Run a real language model - a 260K-parameter Llama-2-style model trained on the
[TinyStories](https://huggingface.co/datasets/roneneldan/TinyStories) dataset - entirely on an
ESP32-S3 microcontroller. No cloud, no phone, no companion computer: the board generates
short children's stories and streams them over serial.

This is a port of [DaveBben/esp32-llm](https://github.com/DaveBben/esp32-llm) (itself built on
[karpathy/llama2.c](https://github.com/karpathy/llama2.c)), adapted and documented for the
**ESP32-S3-DevKitC-1 N16R8** (16 MB flash, 8 MB octal PSRAM), with a one-command Windows setup script.

```
Once upon a time, there was a little girl named Lily. She loved to play outside ...
achieved tok/s: ...
```

## Hardware

| Part | Requirement |
|---|---|
| Board | ESP32-S3 with **8 MB octal PSRAM** and 16 MB flash, e.g. ESP32-S3-DevKitC-1 **N16R8** |
| Cable | USB **data** cable (not charge-only) |
| Port | Use the port labelled **UART** (CP2102 chip) for flashing |
| Optional | SSD1306 128x64 I2C OLED on GPIO8 (SDA) / GPIO9 (SCL) - see [docs/customizing.md](docs/customizing.md) |

> Other boards: the model needs about 1 MB of RAM, so any ESP32-S3 with PSRAM can work, but
> `sdkconfig.defaults` must match your PSRAM type. N16R8 = octal. N8R2 / N16R2 = quad
> (change `CONFIG_SPIRAM_MODE_OCT=y` to `CONFIG_SPIRAM_MODE_QUAD=y`) and set flash size to match.

## Quick start (Windows)
1. Extract zip file "data.zip" in the same folder as flash.ps1
2. Install Git and Python 3.12 (PowerShell), then open a **new** PowerShell window:
   ```powershell
   winget install --id Git.Git -e
   winget install --id Python.Python.3.12 -e
   ```
3. Clone this repo to a **short path** (Windows path-length limits break the build otherwise):
   ```powershell
   git clone https://github.com/<your-username>/esp32s3-tinystories-llm C:\esp\esp32s3-tinystories-llm
   cd C:\esp\esp32s3-tinystories-llm
   ```
4. Plug the board into the **UART** port and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\flash.ps1
   ```

The first run downloads ESP-IDF v5.3.6 (~1 GB) and the ESP32-S3 toolchain, so allow 15-30 minutes.
Later runs just rebuild and reflash. The script finishes by opening the serial monitor
(**Ctrl+]** to quit). Press the board's **RST/EN** button for another story.

Options: `-Port COM5`, `-Baud 115200`, `-Reconfigure` (clean rebuild), `-NoMonitor`.

## Quick start (Linux / macOS)

Not tested by the author of this fork, but this is the standard ESP-IDF flow:

```bash
# one time: install ESP-IDF 5.3.x  (https://docs.espressif.com/projects/esp-idf/en/v5.3/esp32s3/get-started/)
. $HOME/esp/esp-idf/export.sh
idf.py set-target esp32s3
idf.py -p /dev/ttyUSB0 build flash monitor     # /dev/cu.usbserial-* on macOS
```

## What you should see

```
esp_psram: Found 8MB PSRAM device
esp_psram: Speed: 80MHz
MAIN: Partition size: total: ..., used: ...
LLM: Successfully read LLM into memory
<a short story streams out, token by token>
achieved tok/s: <number>
```

Record your own tokens/sec here after your first run:

| Board | Flash / PSRAM | tok/s |
|---|---|---|
| ESP32-S3-DevKitC-1 N16R8 | 16 MB / 8 MB octal | _fill in_ |

(The upstream author reported about 19 tok/s on an ESP32-S3FH4R2, a different board with quad PSRAM.)

## Give it your own prompt

Edit one line in `main/main.c` (`app_main`) and re-run `flash.ps1`:

```c
char *prompt = "Once upon a time, there was a little dragon named Max.";
```

Temperature, top-p and length are right below it. Details and tips: [docs/customizing.md](docs/customizing.md).

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) - architecture, memory layout, what makes it fast
- [docs/customizing.md](docs/customizing.md) - prompts, sampling, OLED, other boards, other models
- [docs/troubleshooting.md](docs/troubleshooting.md) - common errors and fixes

## What differs from upstream

- `sdkconfig.defaults` replaces the committed `sdkconfig`: 16 MB flash, **octal** PSRAM at 80 MHz, 240 MHz CPU, upstream's cache tuning.
- `partitions.csv` resized for 16 MB flash (2 MB app, 2 MB model filesystem).
- OLED support (u8g2 libraries) is **off by default** (`USE_OLED 0`), so no display is needed and one fragile git-based dependency is gone.
- `flash.ps1`: one-command Windows setup, build, flash and monitor.
- `.gitattributes` pins LF line endings (Windows CRLF conversion otherwise breaks hash-checked components).

## Credits and licensing

- Inference code: [karpathy/llama2.c](https://github.com/karpathy/llama2.c) (MIT, copy in `docs/LICENSE-llama2.c.txt`).
- ESP32 port, dual-core and SIMD optimizations: [DaveBben/esp32-llm](https://github.com/DaveBben/esp32-llm).
- Model and tokenizer: `stories260K` from [karpathy/tinyllamas](https://huggingface.co/karpathy/tinyllamas).
- Dataset: [TinyStories](https://huggingface.co/datasets/roneneldan/TinyStories) (Eldan & Li).

**License note:** the upstream ESP32 port does not include a license file, so this repository
does not add one for the derived code. If you publish this fork publicly, consider opening an issue
upstream asking the author to add a license. Your own new files (`flash.ps1`, `docs/`, config changes)
are yours to license as you wish. Also confirm the license of the model files on the
karpathy/tinyllamas Hugging Face page.
