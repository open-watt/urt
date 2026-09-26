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
                names = ['zero_tls'] + (['initialized_tls'] if initialized else [])
                # lld's own TP-relative offset for each thread-local, as the code would load it.
                probe = temp / 'tpoff.s'
                probe.write_text('\t.section .rodata.tpoff,"a"\n\t.p2align 2\n\t.global tpoff_words\ntpoff_words:\n'
                                 + ''.join(f'\t.word {name}(tpoff)\n' for name in names))
                probe_obj = temp / 'tpoff.o'
                run('arm-none-eabi-gcc', '-mcpu=cortex-m33', '-mthumb', '-c', str(probe), '-o', str(probe_obj))
                source = temp / 'probe.d'
                source.write_text(f'''module probe;
extern(C):
__gshared int padding = 11;
align({alignment}) int zero_tls;
{'int initialized_tls = 7;' if initialized else ''}
extern __gshared immutable uint[{len(names)}] tpoff_words;
void sys_init() {{}}
void fault_report() {{}}
void _nvic_dispatch() {{}}
int main() {{ zero_tls = padding; return zero_tls + tpoff_words[0] {'+ initialized_tls' if initialized else ''}; }}
''')
                obj = temp / 'probe.o'
                elf = temp / 'probe.elf'
                run(args.ldc, '-betterC', '-mtriple=thumbv8m.main-none-eabihf', '-mcpu=cortex-m33',
                    '-O2', '-c', str(source), f'-of={obj}')
                run(args.ldc, '-mtriple=thumbv8m.main-none-eabihf', '-defaultlib=', '--link-internally',
                    '-L-z', '-Lnorelro', f'-L-T{root / "platforms/rp2350/rp2350.ld"}',
                    f'-of={elf}', str(start), str(obj), str(probe_obj))
                headers = run('arm-none-eabi-readelf', '-lW', str(elf))
                tls = next(line.split() for line in headers.splitlines() if line.split()[:1] == ['TLS'])
                base = int(tls[2], 16)
                symbols = run('arm-none-eabi-nm', '-n', str(elf))

                def symbol(name):
                    return int(re.search(rf'^([0-9a-f]+) \w {name}$', symbols, re.MULTILINE)[1], 16)

                tp = symbol('_tls_base')
                words = symbol('tpoff_words')
                dump = run('arm-none-eabi-objdump', '-s', f'--start-address={words:#x}',
                           f'--stop-address={words + 4 * len(names):#x}', str(elf))
                data = bytes.fromhex(''.join(''.join(line.split('  ')[0].split()[1:]) for line in dump.splitlines()
                                             if re.match(r'^ [0-9a-f]+ ', line)))[:4 * len(names)]
                for index, name in enumerate(names):
                    tpoff = int.from_bytes(data[4 * index:4 * index + 4], 'little')
                    # A TLS symbol's value is its offset in the TLS segment.
                    if tp + tpoff != base + symbol(name):
                        raise AssertionError(f'initialized={initialized}, alignment={alignment}: {name} resolves to '
                                             f'TP {tp:#x} + {tpoff:#x} but lives at {base + symbol(name):#x}')
                print(f'PASS initialized={initialized}, alignment={alignment}')


if __name__ == '__main__':
    main()
