import pandas as pd

df = pd.read_parquet("src/test_runs/ray_datasets/features/run_20260213T032318Z_20260213T032358Z/parquet/79_03af6596e0ad4175a192234f62044d5a_000000_000000-0.parquet")
print(df.head())
print(df.shape)
print(df.dtypes)
