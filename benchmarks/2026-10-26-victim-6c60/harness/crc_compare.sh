#!/usr/bin/env bash
# Join prefill and decode [victim-crc] lines of a run on pair 2 (v7 prefill, w8 decode).
RUN=${1:?run}; ME=alisachen_google_com
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no"
L=/home/$ME/pd_disagg/results/runs/$RUN
$SSH sa_101411256518727260534@10.128.15.239 "sudo grep -ho 'role=prefill ns=[^ ]* seq=[0-9]* comp=[a-z]* rank=[0-9]* pages=[0-9]* bytes=[0-9]* crc=[0-9a-f]*' $L/prefill/server.log" > /tmp/crc_p.$$
$SSH sa_101411256518727260534@10.128.0.20 "sudo grep -ho 'role=decode ns=[^ ]* seq=[0-9]* comp=[a-z]* rank=[0-9]* pages=[0-9]* bytes=[0-9]* crc=[0-9a-f]*' $L/decode/server.log" > /tmp/crc_d.$$
python3 - /tmp/crc_p.$$ /tmp/crc_d.$$ <<'PY'
import re,sys
def load(f):
    d={}
    for l in open(f):
        m=dict(kv.split("=",1) for kv in l.split()[1:])
        d[(m["ns"],m["seq"],m["comp"],m["rank"])]=(m["pages"],m["bytes"],m["crc"])
    return d
p,d=load(sys.argv[1]),load(sys.argv[2])
both=sorted(set(p)&set(d)); bad=[k for k in both if p[k]!=d[k]]
print(f"prefill victim CRCs: {len(p)}  decode landed CRCs: {len(d)}  matched keys: {len(both)}  MISMATCHES: {len(bad)}")
print(f"  pushed but not inserted on decode (declined/failed/not yet): {len(set(p)-set(d))}; decode without prefill line: {len(set(d)-set(p))}")
print(f"  bytes verified: {sum(int(p[k][1]) for k in both)/2**30:.2f} GiB over {len({k[:3] for k in both})} victim components")
for k in bad[:10]: print("  MISMATCH", k, "prefill", p[k], "decode", d[k])
PY
rm -f /tmp/crc_p.$$ /tmp/crc_d.$$
