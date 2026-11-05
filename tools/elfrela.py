#!/usr/bin/env python3
"""最小 ELF64 RELA 解析器：在 .o 里按 .rodata 偏移反查引用它的代码位置。"""
import struct, sys

class ELF:
    def __init__(self, path):
        self.d = open(path,'rb').read()
        d = self.d
        assert d[:4] == b'\x7fELF'
        e_shoff, = struct.unpack_from('<Q', d, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', d, 0x3a)
        self.sh = []
        for i in range(e_shnum):
            off = e_shoff + i*e_shentsize
            name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', d, off)
            self.sh.append(dict(name=name, type=typ, addr=addr, offset=offset, size=size,
                                link=link, info=info, entsize=entsize))
        strtab = self.sh[e_shstrndx]
        for s in self.sh:
            s['sname'] = self.getstr(strtab['offset']+s['name'])
        # symbol table
        self.symtab = None
        for s in self.sh:
            if s['sname'] == '.symtab':
                self.symtab = s
                break
        self.syms = []
        if self.symtab:
            strt = self.sh[self.symtab['link']]
            n = self.symtab['size'] // 24
            for i in range(n):
                o = self.symtab['offset'] + i*24
                nameoff, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', d, o)
                self.syms.append(dict(name=self.getstr(strt['offset']+nameoff), info=info,
                                      shndx=shndx, value=value, size=size))
        self.sect_names = [s['sname'] for s in self.sh]

    def getstr(self, off):
        end = self.d.index(b'\0', off)
        return self.d[off:end].decode('utf-8','replace')

    def relas(self, secname):
        for s in self.sh:
            if s['sname'] == secname:
                n = s['size']//24
                for i in range(n):
                    o = s['offset'] + i*24
                    r_offset, r_info, r_addend = struct.unpack_from('<QQq', self.d, o)
                    sym = r_info >> 32
                    typ = r_info & 0xffffffff
                    yield r_offset, typ, sym, r_addend

def secidx_by_name(elf, name):
    return elf.sect_names.index(name)

def main():
    path = sys.argv[1]
    target = int(sys.argv[2], 0)   # 目标 vaddr
    elf = ELF(path)
    rodata = elf.sh[secidx_by_name(elf,'.rodata')]
    ro_off = target - rodata['addr']
    print(f"# .rodata vaddr=0x{rodata['addr']:x}  target 0x{target:x} -> rodata+0x{ro_off:x}")
    # 符号表里 .rodata 的 section symbol
    ro_sym = None
    for i,s in enumerate(elf.syms):
        if s['shndx'] == secidx_by_name(elf,'.rodata') and s['name'] == '':
            ro_sym = i
    for sec in ('.rela.text','.rela.data','.rela.rodata'):
        if sec not in elf.sect_names: continue
        for r_offset, typ, sym, addend in elf.relas(sec):
            s = elf.syms[sym]
            hit = False
            if s['name'] == '.rodata':
                # section symbol + addend
                if addend == ro_off: hit = True
                # addend 可能是最终 vaddr
                if addend == target: hit = True
            elif s['shndx'] == secidx_by_name(elf,'.rodata') and s['value'] + addend == target:
                hit = True
            if hit:
                print(f"{sec} off=0x{r_offset:x} type={typ} sym={s['name']} addend=0x{addend:x}")

if __name__ == '__main__':
    main()
