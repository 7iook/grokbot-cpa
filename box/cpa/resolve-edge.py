#!/usr/bin/env python3
"""Resolve real Cloudflare tunnel edge IPs via an un-intercepted resolver (the box's port-53
DNS returns fake 198.18.x.x IPs). Prints comma-separated ip:7844 list for TUNNEL_EDGE."""
import socket, struct, random, sys, os
servers = [s.rsplit(':', 1) for s in os.environ.get('TUNNEL_DNS_RESOLVER_ADDRS', '208.67.222.222:5353').split(',') if s]
def a_records(name):
    for host, port in servers:
        tid = random.randint(0, 65535)
        pkt = struct.pack('>HHHHHH', tid, 0x100, 1, 0, 0, 0) + b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\0' + struct.pack('>HH', 1, 1)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
        try:
            s.sendto(pkt, (host, int(port))); r = s.recv(4096)
        except OSError:
            continue
        an = struct.unpack('>H', r[6:8])[0]; i = 12
        while r[i]: i += r[i] + 1
        i += 5; ips = []
        for _ in range(an):
            i += 2 if r[i] & 0xC0 == 0xC0 else 0
            t, c, ttl, l = struct.unpack('>HHIH', r[i:i+10]); i += 10
            if t == 1 and l == 4: ips.append(socket.inet_ntoa(r[i:i+4]))
            i += l
        ips = [ip for ip in ips if not ip.startswith('198.18.')]
        if ips: return ips
    return []
out = []
for reg in ('region1.v2.argotunnel.com', 'region2.v2.argotunnel.com'):
    out += [f'{ip}:7844' for ip in a_records(reg)[:4]]
print(','.join(out)); sys.exit(0 if out else 1)
