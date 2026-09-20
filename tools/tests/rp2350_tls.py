import argparse
import re
import subprocess
import tempfile
from pathlib import Path


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ldc', default='ldc2')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='urt-rp2350-tls-') as directory:
        temp = Path(directory)
        start = temp / 'start.o'
        run('arm-none-eabi-gcc', '-mcpu=cortex-m33', '-mthumb', '-mfloat-abi=hard',
            '-mfpu=fpv5-sp-d16', '-c', str(root / 'src/urt/driver/rp2350/start.S'), '-o', str(start))
        for initialized in (False, True):
            for alignment in (4, 16, 64):
                source = temp / 'probe.d'
                source.write_text(f'''module probe;
extern(C):
__gshared int padding = 11;
align({alignment}) int zero_tls;
{'int initialized_tls = 7;' if initialized else ''}
void sys_init() {{}}
void fault_report() {{}}
void _nvic_dispatch() {{}}
int main() {{ zero_tls = padding; return zero_tls {'+ initialized_tls' if initialized else ''}; }}
''')
                obj = temp / 'probe.o'
                elf = temp / 'probe.elf'
                run(args.ldc, '-betterC', '-mtriple=thumbv8m.main-none-eabihf', '-mcpu=cortex-m33',
                    '-O2', '-c', str(source), f'-of={obj}')
                run(args.ldc, '-mtriple=thumbv8m.main-none-eabihf', '-defaultlib=', '--link-internally',
                    '-L-z', '-Lnorelro', f'-L-T{root / "platforms/rp2350/rp2350.ld"}',
                    f'-of={elf}', str(start), str(obj))
                headers = run('arm-none-eabi-readelf', '-lW', str(elf))
                tls = next(line.split() for line in headers.splitlines() if line.split()[:1] == ['TLS'])
                base, tls_align = int(tls[2], 16), int(tls[-1], 16)
                symbols = run('arm-none-eabi-nm', '-n', str(elf))
                tp = int(re.search(r'^([0-9a-f]+) \w _tls_base$', symbols, re.MULTILINE)[1], 16)
                if tp + max(8, tls_align) != base:
                    raise AssertionError(f'initialized={initialized}, alignment={alignment}: '
                                         f'TP {tp:#x} + TCB {max(8, tls_align):#x} != TLS {base:#x}')
                print(f'PASS initialized={initialized}, alignment={alignment}')


if __name__ == '__main__':
    main()
