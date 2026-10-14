# usbliter8-a14

**Исследование применимости эксплойта usbliter8 к Apple A14 (T8101) SecureROM**

---

## Итог

Эксплойт `usbliter8` **не применим к A14 (T8101)**. Примитив записи через поток USB SETUP-пакетов на A14 является **setup-header race**, а не memory-write primitive. Запись в SRAM SecureROM невозможна. Публичное утверждение команды Paradigm Shift («A14+ настраивает DART корректно и не подвержен эксплуатации») подтверждено экспериментально.

---

## Что доказано

| Утверждение | Подтверждение |
|---|---|
| Примитив `crazy_transfer` на A14 — setup-header race | v273: payload влияет на следующий control-transfer |
| Запись в SRAM SecureROM A14 невозможна | v269, v270, v272: serial не меняется |
| `0x1FC0242B0` — callback-валидатор, не подделывается | v266, v267: hook ломает DEV18 без исполнения |
| A14 имеет защиту от подделки указателей | v267: fail-safe без вызова callback |
| `PWND:[...]` в A14 SecureROM отсутствует | grep по дампу |

---

## Что не работает

- Запись shellcode в SRAM
- Подмена callback-указателей в `0x1FC0242B0`, `0x1FC0242B8`, `0x1FC0242C0`, `0x1FC0242C8`, `0x1FC0242D0`
- Патч serial buffer `0x1FC0242E0`
- Установка verified flag `0x1FC0242A8`

---

## Найденные структуры SecureROM A14 (t8101si)

Источник: `SecureROM for t8101si, iBoot-5281.0.0.100.45` (securerom.fun)

### DFU state (SRAM)

| Адрес | Назначение |
|---|---|
| `0x1FC0242A8` | Verified flag (байт) |
| `0x1FC0242B0` | IMG4 callback-валидатор: `(*cb)(component_id)` |
| `0x1FC0242B8` | DFU dispatcher callback, `arg2[2]==1` |
| `0x1FC0242C0` | DFU dispatcher callback, `arg2[2]==2` |
| `0x1FC0242C8` | DFU dispatcher callback, `arg2[2]==4` |
| `0x1FC0242D0` | Status callback: `(*cb)(0|1)` |
| `0x1FC0242D8` | Serial state (0/1/2) |
| `0x1FC0242DC` | NONC state (0/1/2) |
| `0x1FC0242E0` | Serial string buffer |
| `0x1FC02435F` | NONC/SNON string buffer |

### Функции

| Адрес | Имя | Назначение |
|---|---|---|
| `0x1000057D0` | DFU dispatcher | Вызов callbacks после verified |
| `0x100006058` | `verify_decrypt_decompress_image` | Главный DFU handler |
| `0x100006A54` | Magic check | Проверка IMG4/MZ |
| `0x100006CC4` | Component compare | Сравнение компонента |
| `0x100006F20` | idProduct | `0x1226 + (bits & 3)` |
| `0x100006F44` | Product name | `"Apple Mobile Device (DFU Mode)"` |
| `0x100006F50` | Serial generator | `"CPID:%04X CPRV:%02X..."` |
| `0x100007198` | NONC generator | `" NONC:"` / `" SNON:"` |

### Механизм verified flag (из `sub_100006058`)

```c
x8_16 = *0x1FC0242B0;                    /* callback */
if (x8_16 == 0) goto label_100006344;
if (x8_16(component_id) == 0) {          /* return 0 */
    x8_16 = 0;
    goto label_100006344;
} else {                                  /* return != 0 */
    x8_17 = *0x1FC0242D0;
    if (x8_17 != 0) {
        x8_17(0);
        x8_16 = 1;
        goto label_100006344;
    }
}
label_100006344:
*0x1FC0242A8 = (x8_16 & 0xff);
```

Для `verified = 1` нужно: callback вернул `!= 0` **И** `*0x1FC0242D0 != 0`.

### Ранний обход IMG4 (не помогает)

```c
if ((*(arg1 + 0xd) & 1) != 0) {          /* arg1 = DFU дескриптор */
    if (arg7) *arg7 = x27_1;
    goto label_10000628c;                 /* пропуск IMG4, но НЕ ставит verified */
}
```

### DFU команды (`arg1.d` в `sub_1000057d0`)

| FourCC | Значение |
|---|---|
| `0x44475354` | "DGST" — финальная валидация |
| `0x424E4348` | "BNCH" — bootchain validate |
| `0x45534543` | "ESEC" |
| `0x454B4559` | "EKEY" |
| `0x4550524F` | "EPRO" |
| `0x4450524F` | "DPRO" |
| `0x414D4E4D` | "AMNM" |
| `0x4350524F` | "CPRO" |
| `0x53444F4D` | "SDOM" |
| `0x45434944` | "DICE" |

---

## Природа примитива

`crazy_transfer` отправляет USB SETUP-пакеты с **4-байтовым payload** вместо штатных 8 байт. Target получает malformed SETUP, обрабатывает его как setup-header для следующего control-transfer.

**Экспериментальное подтверждение (v273):**

| Payload | hs | Serial после |
|---|---|---|
| `0x00000000` | TIMEOUT | OK |
| `0xFFFFFFFF` | ACK | STALL |
| `0x444E5750` ("PWND") | ACK | STALL |
| `0x0050030A` (valid string hdr) | ACK | STALL |

**Вывод:** payload становится частью setup-заголовка. Адрес назначения не контролируется.

---

## Требования

- Плата Waveshare RP2350-USB-A
- Pico SDK для RP2350
- ARM GNU Toolchain (aarch64)
- Target: iPhone 12 (A14) в режиме DFU

---

## Сборка

```bash
export PICO_SDK_PATH=/путь/к/pico-sdk
mkdir build && cd build
cmake -DPICO_BOARD=waveshare_rp2350_usb_a ..
make -j4
```

Прошивка: `usbliter8.uf2` через BOOTSEL.

---

## Использование

1. Прошить Pico через BOOTSEL
2. Подключить target в DFU к Pico через USB-A
3. Открыть терминал: `picocom -b 115200 /dev/tty.usbmodem*`
4. Эксплойт стартует автоматически

Питание target и Pico — **от разных источников**, общий только GND.

---

## Известные проблемы

### Pico отваливается от хоста

**Симптом:** `FATAL: read from port failed: Device not configured`

**Причина:** PIO USB на RP2350 использует `save_and_disable_interrupts()`, USB CDC не обслуживается.

**Решение:** использовать UART0 (GP0/GP1) для логов вместо USB CDC.

### Target деградирует после нескольких прогонов

**Симптом:** `probe=0x00`, отказ на GET_DESCRIPTOR

**Причина:** подделка setup-header ломает состояние USB-контроллера target.

**Решение:** hard reset (Power + Volume Down 10 сек) + заново в DFU.

---

## Рекомендации

Для получения работающего pwnd использовать **A5-A13 (t8020)** — iPhone 7/8/X. Эксплойт `usbliter8` работает на A12/A13 end-to-end с готовыми `resources/*.h`.

Для A14 необходима **другая уязвимость** — например, переполнение в ASN.1-парсере `sub_1000054B4` или DART-конфигурация ревизии A0.

---

## Что не опубликовано

- Дамп SecureROM A14 (`iBoot-5281.0.0.100.45`) — только справочно
- Ресурсы `resources/*.h` — отсутствуют, эксплойт для A14 не завершён
- Готовый pwnd — не достигнут

---

## Структура репозитория

```
usbliter8-main/
├── exploit.c              — основной код
├── exploit.h              — заголовки
├── main.c                 — точка входа
├── revers/
│   ├── SecureROM...       — дамп
│   ├── ..._hlil.txt       — дизасм
│   └── A14_...t8101.c     — декомпиляция
└── CMakeLists.txt
```

---

## Хронология

| Версия | Что тестировалось | Результат |
|---|---|---|
| v226 | Поток SETUP с t8020-адресами | Примитив подтверждён |
| v233 | Запись 0 в `0x1FC0242A8` | Восстановление за 500 мс |
| v241 | Прямая установка флага | Флаг не вызывает callback |
| v243 | Тест writable адресов | Все OK |
| **v255** | **Shellcode `B .` через `0x2B0`** | **Ошибочно принят за hang** |
| v258 | Двойной hook 0x2B0 + 0x2D0 | DEV18 сломан |
| v266 | Мульти-hook + чтение serial | STALL, восстановление |
| v270 | State bypass | STALL |
| v272 | Минимальный тест | Запись не персистентна |
| **v273** | **Race primitive test** | **Payload = setup-header** |

---

## Лицензия

MIT. Только для образовательных целей.

---

## Благодарности

- Paradigm Shift — публикация usbliter8
- ncxcy/A15-SECUREROM-VULNS — исследование SecureROM A15
- securerom.fun — публичные дампы SecureROM
- Binary Ninja — декомпилятор
