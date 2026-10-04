#!/usr/bin/env python3
# Prints the STM32 U(S)ART pin route tables in src/urt/driver/stm32/uart.d from ST's STM32_open_pin_data.
# Usage: python3 tools/stm32_uart_routes.py [directory holding the GPIO-*_Modes.xml files]
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

SOURCE = 'https://raw.githubusercontent.com/STMicroelectronics/STM32_open_pin_data/master/mcu/IP/'

# family version, GPIO IP of the part urt builds for it, ports in urt's order (port n is the n+1th U(S)ART)
FAMILIES = [
    ('STM32H7', 'GPIO-STM32H747_gpio_v1_0_Modes.xml',
     ['USART1', 'USART2', 'USART3', 'UART4', 'UART5', 'USART6', 'UART7', 'UART8', 'LPUART1']),
    ('STM32F7', 'GPIO-STM32F746_gpio_v1_0_Modes.xml',
     ['USART1', 'USART2', 'USART3', 'UART4', 'UART5', 'USART6', 'UART7', 'UART8']),
    ('STM32F4', 'GPIO-STM32F417_gpio_v1_0_Modes.xml',
     ['USART1', 'USART2', 'USART3', 'UART4', 'UART5', 'USART6']),
]

# DE rides the RTS pin
SIGNALS = {'TX': 'tx', 'RX': 'rx', 'RTS': 'rts', 'DE': 'rts', 'CTS': 'cts'}


def load(name):
    if len(sys.argv) > 1:
        with open(f'{sys.argv[1]}/{name}', 'rb') as f:
            return f.read()
    with urllib.request.urlopen(SOURCE + name) as r:
        return r.read()


def routes(xml, ports):
    root = ET.fromstring(xml)
    ns = root.tag[:root.tag.index('}') + 1] if root.tag.startswith('{') else ''
    found = set()
    for pin in root.iter(ns + 'GPIO_Pin'):
        m = re.match(r'P([A-K])(\d+)(\S*)', pin.get('Name'))
        if not m or m.group(3).startswith('_C'):
            continue
        number = (ord(m.group(1)) - ord('A')) * 16 + int(m.group(2))
        for sig in pin.iter(ns + 'PinSignal'):
            s = re.fullmatch(r'((?:LP)?U(?:S)?ART\d)_(TX|RX|RTS|DE|CTS)', sig.get('Name'))
            if not s or s.group(1) not in ports:
                continue
            for value in sig.iter(ns + 'PossibleValue'):
                af = re.match(r'GPIO_AF(\d+)_', value.text)
                if af:
                    found.add((number, ports.index(s.group(1)), SIGNALS[s.group(2)], int(af.group(1))))
    return sorted(found, key=lambda r: (r[1], ['tx', 'rx', 'rts', 'cts'].index(r[2]), r[0]))


def pin_name(number):
    return 'p' + chr(ord('a') + number // 16) + (f' + {number % 16}' if number % 16 else '')


for i, (version, ip, ports) in enumerate(FAMILIES):
    table = routes(load(ip), ports)
    print(f'{"else " if i else ""}version ({version})' if i < len(FAMILIES) - 1 else 'else')
    print('{')
    print(f'    static immutable UartRoute[{len(table)}] uart_routes = [')
    for key in sorted({(r[1], r[2]) for r in table}, key=lambda k: (k[0], ['tx', 'rx', 'rts', 'cts'].index(k[1]))):
        group = [r for r in table if (r[1], r[2]) == key]
        line = '       '
        for n, port, signal, af in group:
            entry = f' UartRoute({pin_name(n)}, {port}, Signal.{signal}, {af}),'
            if len(line) + len(entry) > 116:
                print(line)
                line = '       '
            line += entry
        print(line)
    print('    ];')
    print('}')
