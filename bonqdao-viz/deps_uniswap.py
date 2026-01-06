from collections import defaultdict, deque
from slither.slither import Slither

# sl = Slither(".", compile_force_framework="solc")
sl = Slither(
    [
        "contracts/UniswapV2Pair.sol",
        "contracts/UniswapV2Factory.sol",
        "contracts/UniswapV2ERC20.sol"
    ],
    compile_force_framework="solc",
)



def fn_id(f):
    return f"{f.contract.name}.{f.name}"

# 1) Build maps: function -> reads/writes
fn_reads = defaultdict(set)
fn_writes = defaultdict(set)
fn_calls = defaultdict(set)
entrypoints = set()

for c in sl.contracts:
    for f in c.functions:
        fid = fn_id(f)
        if f.visibility in ("public", "external") and not f.is_constructor:
            entrypoints.add(fid)

        for v in getattr(f, "state_variables_read", []):
            fn_reads[fid].add(f"{v.contract.name}.{v.name}")
        for v in getattr(f, "state_variables_written", []):
            fn_writes[fid].add(f"{v.contract.name}.{v.name}")
        for g in getattr(f, "internal_calls", []):
            if g:
                fn_calls[fid].add(fn_id(g))

# 2) Derive “influence”: entrypoint -> reachable -> writes
def reachable(start):
    seen = set([start])
    q = deque([start])
    while q:
        cur = q.popleft()
        for nxt in fn_calls.get(cur, []):
            if nxt not in seen:
                seen.add(nxt)
                q.append(nxt)
    return seen

# 3) Print top attack-surface-ish entrypoints by write footprint
ranked = []
for e in sorted(entrypoints):
    reach = reachable(e)
    writes = set().union(*(fn_writes[r] for r in reach))
    reads  = set().union(*(fn_reads[r] for r in reach))
    ranked.append((len(writes), len(reads), e, writes, reads, reach))

ranked.sort(reverse=True)

for wcnt, rcnt, e, writes, reads, reach in ranked[:30]:
    print("=" * 80)
    print(f"ENTRYPOINT: {e}")
    print(f"  reachable_fns: {len(reach)-1}")
    print(f"  writes({wcnt}):")
    for v in sorted(writes):
        print(f"    - {v}")
    print(f"  reads({rcnt}):")
    for v in sorted(reads):
        print(f"    - {v}")

