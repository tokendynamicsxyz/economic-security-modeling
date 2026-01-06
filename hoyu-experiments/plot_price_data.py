import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path

WAD = 10**18
CSV_PATH = "data/price_impact.csv"
OUT_PATH = Path("data/price_impact.png")

df = pd.read_csv(CSV_PATH, dtype=str)

NUM_COLS = ["amountIn", "amountOut", "priceInPerOut", "reserve0", "reserve1"]
for c in NUM_COLS:
    df[c] = (
        df[c]
        .str.strip()
        .str.replace(",", "", regex=False)
    )
    df[c] = pd.to_numeric(df[c], errors="coerce")

df = df.dropna(subset=NUM_COLS)
df = df[df["amountOut"] > 0]

df["currency_in"] = df["amountIn"] / WAD
df["price"] = df["priceInPerOut"] / WAD

plt.figure(figsize=(6, 4))
plt.plot(df["currency_in"], df["price"])
plt.xlabel("Currency in (tokens)")
plt.ylabel("Effective price (CUR / ALT)")
plt.title("Hoyu: price impact curve (currency → altcoin)")
plt.grid(True)

# Save instead of show
OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
plt.tight_layout()
plt.savefig(OUT_PATH, dpi=150)
plt.close()

print(f"Saved plot to {OUT_PATH.resolve()}")

