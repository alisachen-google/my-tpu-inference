#!/usr/bin/env bash
# Evidence that the offload ran on a live pair: push, landing and recall counters, warnings and errors.
RUN=${1:?run}; PIP=${PIP:-10.128.15.217}; DIP=${DIP:-10.128.15.239}
S="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no"
P=/home/alisachen_google_com/pd_disagg/results/runs/$RUN/prefill/server.log
D=/home/alisachen_google_com/pd_disagg/results/runs/$RUN/decode/server.log
echo "== prefill ($PIP)"
$S sa_101411256518727260534@$PIP "sudo bash -c '
grep -h \"\\[dram-offload\\] push\\|\\[victim-push\\] role=prefill\" $P | grep \"TP0 \" | tail -1 | cut -c1-200
echo \"recall commits (TP0): \$(grep -h \"\\[prefix-pull\\] room=\" $P | grep -c \"TP0 \")  inserted=True on all ranks: \$(grep -h \"\\[prefix-pull\\] room=\" $P | grep -c \"inserted=True\")\"
grep -h \"\\[dram-offload\\] recall\\|\\[prefix-pull\\] room=\" $P | grep \"TP0 \" | tail -1 | cut -c1-330
echo \"ranks logging pushes: \$(grep -h \"\\[victim-push\\] role=prefill.*stored=\" $P | grep -o \"TP[0-9]\" | sort -u | tr \"\\n\" \" \")\"
echo \"warnings: \$(grep -ch \"Cannot register host read\\|Cannot start host read\\|did not settle\\|Cannot poll host read\\|to .* failed (errno\" $P)\"
echo \"errors: \$(grep -ch \"Traceback\\|Scheduler hit an exception\\|RuntimeError\\|AssertionError\\|KeyError\" $P)\"
grep -h \"Traceback\\|Scheduler hit an exception\\|Error:\" $P | cut -c1-200 | sort | uniq -c | sort -rn | head -5
'"
echo "== decode ($DIP)"
$S sa_101411256518727260534@$DIP "sudo bash -c '
grep -h \"\\[dram-offload\\] landing\\|\\[victim-push\\] role=decode\" $D | grep \"TP0 \" | tail -1 | cut -c1-240
echo \"ranks logging landings: \$(grep -h \"\\[victim-push\\] role=decode.*landed=\" $D | grep -o \"TP[0-9]\" | sort -u | tr \"\\n\" \" \")\"
echo \"refused pulls: \$(grep -ch \"cannot be served, refusing\" $D)  warnings: \$(grep -ch \"Cannot register host read\\|Cannot start host read\\|Cannot poll host read\\|to .* failed (errno\" $D)\"
echo \"errors: \$(grep -ch \"Traceback\\|Scheduler hit an exception\\|RuntimeError\\|AssertionError\\|KeyError\" $D)\"
grep -h \"Traceback\\|Scheduler hit an exception\\|Error:\" $D | cut -c1-200 | sort | uniq -c | sort -rn | head -5
'"
