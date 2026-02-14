#!/usr/bin/env python3
"""
fraud_detection_and_risk_modeling.py

Enhanced, realistic synthetic multi-table dataset generator for Fraud Detection & Risk Modeling.

Features:
- Supports output formats: CSV or Parquet (--format csv|parquet)
- Realistic tactics: fraud rings (shared devices/IPs), merchant risk concentration,
  velocity bursts, account takeover patterns, label delay (chargebacks), temporal drift.
- All datetimes stored/parsed as tz-aware UTC (avoids tz-naive/aware comparison bugs).
- Deterministic via seed; defensive parsing and writes with fallbacks.

Usage:
  python3 src/synthesize_data/fraud_detection_and_risk_modeling.py --output-dir synthetic_datasets/fraud_detection_and_risk_modeling \
     --size small --format csv

  python3 src/synthesize_data/fraud_detection_and_risk_modeling.py --output-dir synthetic_datasets/fraud_detection_and_risk_modeling \
     --size medium --format parquet
     
Dependencies:
  pip3 install Faker==40.4.0 pandas==2.3.3 numpy==2.2.6 pyarrow==23.0.0 fastparquet==2025.12.0
"""
from __future__ import annotations
import argparse
import json
import logging
import os
import random
import uuid
from datetime import datetime, timedelta
from typing import Dict, List, Optional

import numpy as np
import pandas as pd
from faker import Faker

# ---------- Config ----------
PINNED_FAKER_VERSION = "40.4.0"
DEFAULT_SEED = 42

SIZE_MAP = {"small": 500, "medium": 5000, "large": 50000}
AVG_TX_PER_USER = {"small": 10, "medium": 10, "large": 10}
AVG_LOGIN_PER_USER = {"small": 8, "medium": 10, "large": 12}
AVG_DEV_PER_USER = {"small": 1.2, "medium": 1.3, "large": 1.5}

# corruption & behavior params
MALFORMED_DATE_PCT = 0.04
MISSING_INCOME_PCT = 0.12
NEAR_DUPLICATE_PCT = 0.01
RARE_COUNTRY_PCT = 0.02
INVALID_IP_PCT = 0.02
NEGATIVE_AMOUNT_PCT = 0.005

# realistic fraud params
BASE_FRAUD_RATE = 0.02             # baseline population fraud rate (can be increased by drift)
FRAUD_RING_FRACTION = 0.005        # fraction of users participating in fraud rings
RING_DEVICE_SHARE = (2, 8)         # devices are shared across this many users in a ring
HIGH_RISK_MERCHANT_PCT = 0.05      # fraction of merchants considered high-risk
MERCHANT_COUNT = 200               # total merchants to simulate (small -> scale down later)
BURST_USER_PCT = 0.02              # small fraction of users perform velocity bursts
BURST_TXN_COUNT = (10, 40)         # transactions in a burst
LABEL_DELAY_DAYS = (30, 90)        # chargeback / label delay window
TEMPORAL_DRIFT_MAG = 0.8           # controls growth of fraud propensity in recent time (1=no drift, >1 increases)

# logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("synth-fraud-enhanced")

# ---------- Helpers ----------
def mkdir_p(path: str):
    os.makedirs(path, exist_ok=True)

def seed_everything(seed: int = DEFAULT_SEED):
    random.seed(seed)
    np.random.seed(seed)
    Faker.seed(seed)

def iso_or_unambiguous_malformed(dt: pd.Timestamp, malformed_pct: float = MALFORMED_DATE_PCT) -> str:
    """
    Return either ISO-8601 (preferred) or an intentionally unambiguous malformed format.
    Avoid ambiguous day-first formats.
    """
    if random.random() < malformed_pct:
        fmt = random.choice([
            "%Y.%m.%d %H:%M:%S",
            "%Y/%m/%d %H:%M:%S",
            "%b %d %Y %H:%M:%S",
            "%Y-%m-%dT%H:%M:%SZ"
        ])
        return pd.Timestamp(dt).strftime(fmt)
    return pd.Timestamp(dt).replace(microsecond=0).isoformat()

def maybe_none(val, pct: float):
    return None if random.random() < pct else val

def random_ip_maybe_invalid(fake: Faker) -> str:
    if random.random() < INVALID_IP_PCT:
        return random.choice(["not_an_ip", "999.999.999", "256.256.256.256", ""])
    return fake.ipv4_public()

def make_currency() -> str:
    return random.choice(["USD", "EUR", "GBP", "JPY", "CAD", "AUD"])

def logistic(x):
    return 1.0 / (1.0 + np.exp(-x))

def robust_parse_datetime_series(series: pd.Series) -> pd.Series:
    """Parse to tz-aware UTC datetimes (datetime64[ns, UTC])"""
    s = pd.to_datetime(series, errors="coerce", utc=True)
    return s

def write_df(df: pd.DataFrame, path_base: str, fmt: str):
    """Write DataFrame to csv or parquet. If parquet fails, fall back to csv."""
    if fmt == "csv":
        df.to_csv(path_base + ".csv", index=False, encoding="utf-8")
    else:
        # try parquet with pyarrow or fastparquet
        try:
            df.to_parquet(path_base + ".parquet", index=False)
        except Exception as e:
            log.warning("Parquet write failed (%s); falling back to CSV. Error: %s", path_base, e)
            df.to_csv(path_base + ".csv", index=False, encoding="utf-8")

# ---------- Generation components ----------
def gen_merchants(n_merchants: int, fake: Faker, high_risk_pct: float) -> pd.DataFrame:
    merchants = []
    for i in range(n_merchants):
        mid = f"m_{i:06d}"
        name = fake.company()
        category = random.choice(["grocery","travel","electronics","entertainment","gaming","subscription","luxury","atm","utility","insurance"])
        risk_score = float(np.clip(np.random.beta(1 + (1 if random.random() < high_risk_pct else 0), 3) * 1.5, 0.0, 1.0))
        merchants.append({"merchant_id": mid, "merchant_name": name, "merchant_category": category, "merchant_risk": risk_score})
    return pd.DataFrame(merchants)

def gen_users(fake: Faker, n_users: int) -> pd.DataFrame:
    rows = []
    common_countries = ["US","GB","CA","AU","DE","FR","IN","BR"]
    rare_countries = ["NG","PK","IR","SY","KP"]
    for _ in range(n_users):
        uid = str(uuid.uuid4())
        signup_dt = fake.date_time_between(start_date="-3y", end_date="now")
        country = random.choice(common_countries if random.random() > RARE_COUNTRY_PCT else rare_countries)
        age = int(np.clip(np.random.normal(38,12),18,90))
        income = maybe_none(round(max(0.0, float(np.random.normal(60000,30000))),2), MISSING_INCOME_PCT)
        account_type = random.choices(["basic","silver","gold","platinum"], weights=[0.5,0.3,0.15,0.05])[0]
        kyc_level = random.choices([0,1,2,3], weights=[0.1,0.4,0.4,0.1])[0]
        email = fake.email()
        email_domain = email.split("@")[-1] if "@" in email else None
        rows.append({
            "user_id": uid,
            "signup_date": iso_or_unambiguous_malformed(signup_dt),
            "country": country,
            "age": age,
            "income": income,
            "account_type": account_type,
            "kyc_level": kyc_level,
            "email_domain": email_domain
        })
    df = pd.DataFrame(rows)
    # near duplicates: copy attributes but assign new unique user_ids
    if NEAR_DUPLICATE_PCT > 0:
        ndup = max(1, int(len(df) * NEAR_DUPLICATE_PCT))
        sample = df.sample(ndup, random_state=DEFAULT_SEED).copy()
        sample = sample.drop(columns=["user_id"])
        sample["user_id"] = [str(uuid.uuid4()) for _ in range(len(sample))]
        df = pd.concat([df, sample], ignore_index=True)
    df = df.drop_duplicates(subset=["user_id"]).reset_index(drop=True)
    return df

def gen_devices_and_rings(fake: Faker, users_df: pd.DataFrame, avg_per_user: float, ring_fraction: float, ring_device_share: tuple):
    devices = []
    user_ids = list(users_df["user_id"])
    total_users = len(user_ids)
    # create normal device per user
    for uid in user_ids:
        n_dev = max(1, int(np.random.poisson(avg_per_user)))
        for _ in range(n_dev):
            did = str(uuid.uuid4())
            fp = fake.sha1()
            first_seen = fake.date_time_between(start_date="-3y", end_date="now")
            trust = maybe_none(round(float(np.clip(np.random.beta(2,5) * 100,0,100)),2), 0.05)
            devices.append({"device_id": did, "user_id": uid, "device_fingerprint": fp, "first_seen": iso_or_unambiguous_malformed(first_seen), "device_trust_score": trust})
    # fraud rings: create some shared devices and assign to groups of users
    n_ring_users = max(1, int(total_users * ring_fraction))
    if n_ring_users >= 2:
        # determine number of rings (small)
        n_rings = max(1, int(max(1, n_ring_users) / max(3, ring_device_share[1])))
        ring_users = random.sample(user_ids, n_ring_users)
        start = 0
        for r in range(n_rings):
            group_size = random.randint(ring_device_share[0], ring_device_share[1])
            group = ring_users[start:start+group_size]
            if not group:
                break
            # create a shared device used by this ring
            shared_device_id = str(uuid.uuid4())
            fp = fake.sha1()
            first_seen = fake.date_time_between(start_date="-3y", end_date="now")
            devices.append({"device_id": shared_device_id, "user_id": group[0], "device_fingerprint": fp, "first_seen": iso_or_unambiguous_malformed(first_seen), "device_trust_score": 5.0})
            # attach the shared device to other users in ring by adding device rows linking same device_id to them (simulates shared device across accounts)
            for other_uid in group[1:]:
                devices.append({"device_id": shared_device_id, "user_id": other_uid, "device_fingerprint": fp, "first_seen": iso_or_unambiguous_malformed(first_seen), "device_trust_score": 5.0})
            start += group_size
    devices_df = pd.DataFrame(devices).drop_duplicates(subset=["device_id","user_id"]).reset_index(drop=True)
    return devices_df

def gen_transactions(fake: Faker, users_df: pd.DataFrame, merchants_df: pd.DataFrame, avg_per_user: float, burst_user_pct: float):
    tx = []
    merchant_ids = merchants_df["merchant_id"].tolist()
    # choose burst users
    n_burst_users = max(1, int(len(users_df) * burst_user_pct))
    burst_users = set(random.sample(list(users_df["user_id"]), n_burst_users))

    for uid, signup in zip(users_df["user_id"], users_df["signup_date"]):
        n = max(0, int(np.random.poisson(avg_per_user)))
        sdt = pd.to_datetime(signup, errors="coerce", utc=True)
        if pd.isna(sdt):
            sdt = pd.Timestamp.now(tz="UTC") - pd.Timedelta(days=365*2)
        # normal transactions
        for _ in range(n):
            tid = str(uuid.uuid4())
            txn_time = fake.date_time_between(start_date=sdt.to_pydatetime(), end_date="now")
            amount = round(float(np.random.exponential(100.0)),2)
            if random.random() < NEGATIVE_AMOUNT_PCT:
                amount = -abs(amount)
            merchant_id = random.choice(merchant_ids)
            merchant_row = merchants_df.loc[merchants_df["merchant_id"] == merchant_id].iloc[0]
            # merchant risk influences some category choice
            currency = make_currency()
            tx.append({"transaction_id": tid, "user_id": uid, "transaction_time": iso_or_unambiguous_malformed(txn_time), "amount": amount, "currency": currency, "merchant_id": merchant_id, "merchant_risk": float(merchant_row["merchant_risk"]), "device_id": None, "is_chargeback": 0})
        # bursts for some users (simulate fraud bursts)
        if uid in burst_users:
            burst_count = random.randint(BURST_TXN_COUNT[0], BURST_TXN_COUNT[1])
            burst_start = fake.date_time_between(start_date=sdt.to_pydatetime(), end_date="now")
            for i in range(burst_count):
                tid = str(uuid.uuid4())
                # spread within a small interval (minutes)
                txn_time = burst_start + timedelta(seconds=random.randint(0, 60*30))
                merchant_id = random.choice(merchant_ids)
                merchant_row = merchants_df.loc[merchants_df["merchant_id"] == merchant_id].iloc[0]
                amount = round(float(np.random.exponential(200.0)),2)  # heavier tail in bursts
                currency = make_currency()
                tx.append({"transaction_id": tid, "user_id": uid, "transaction_time": iso_or_unambiguous_malformed(txn_time), "amount": amount, "currency": currency, "merchant_id": merchant_id, "merchant_risk": float(merchant_row["merchant_risk"]), "device_id": None, "is_chargeback": 0})
    tx_df = pd.DataFrame(tx)
    tx_df = tx_df.drop_duplicates(subset=["transaction_id"]).reset_index(drop=True)
    return tx_df

def gen_logins(fake: Faker, users_df: pd.DataFrame, avg_per_user: float, account_takeover_pct: float):
    logins = []
    device_types = ["mobile","desktop","tablet","iot","smart_tv"]
    n_ato = max(1, int(len(users_df) * account_takeover_pct))
    ato_users = set(random.sample(list(users_df["user_id"]), n_ato))
    for uid in users_df["user_id"]:
        n = max(0, int(np.random.poisson(avg_per_user)))
        # if account takeover user, inject failed login bursts and later successful login
        is_ato = uid in ato_users
        for _ in range(n):
            lid = str(uuid.uuid4())
            ltime = fake.date_time_between(start_date="-3y", end_date="now")
            ip = random_ip_maybe_invalid(fake)
            device_type = random.choice(device_types) if random.random() > 0.05 else None
            success = 1 if random.random() > 0.08 else 0
            logins.append({"login_id": lid, "user_id": uid, "login_time": iso_or_unambiguous_malformed(ltime), "ip_address": ip, "device_type": device_type, "success": success})
        if is_ato:
            # add a failed login burst then a success shortly before fraud (simulated)
            burst_len = random.randint(3, 8)
            burst_start = fake.date_time_between(start_date="-30d", end_date="now")
            for i in range(burst_len):
                lid = str(uuid.uuid4())
                ltime = burst_start + timedelta(seconds=random.randint(0, 300))
                ip = random_ip_maybe_invalid(fake)
                logins.append({"login_id": lid, "user_id": uid, "login_time": iso_or_unambiguous_malformed(ltime), "ip_address": ip, "device_type": random.choice(device_types), "success": 0})
            # trailing successful login
            lid = str(uuid.uuid4())
            ltime = burst_start + timedelta(seconds=300 + random.randint(1,60))
            logins.append({"login_id": lid, "user_id": uid, "login_time": iso_or_unambiguous_malformed(ltime), "ip_address": random_ip_maybe_invalid(fake), "device_type": random.choice(device_types), "success": 1})
    logins_df = pd.DataFrame(logins)
    logins_df = logins_df.drop_duplicates(subset=["login_id"]).reset_index(drop=True)
    return logins_df

def gen_chargebacks(fake: Faker, tx_df: pd.DataFrame, delay_window: tuple):
    if tx_df.empty:
        return pd.DataFrame(columns=["chargeback_id","transaction_id","reason_code","reported_date"])
    cbs = []
    # pick candidates with some bias toward high merchant_risk and high amount
    weights = (tx_df["merchant_risk"].fillna(0.0) * (tx_df["amount"].abs().fillna(0.0) + 1.0)).values
    weights = weights / weights.sum() if weights.sum() > 0 else None
    n_samples = max(1, int(len(tx_df) * 0.02))
    candidates = tx_df.sample(n=n_samples, weights=None, random_state=DEFAULT_SEED)  # simpler uniform sampling; complexity optional
    for _, row in candidates.iterrows():
        if random.random() < 0.02:
            cb_id = str(uuid.uuid4())
            reason = random.choice(["fraudulent","duplicate","product_not_received","unauthorized","other"])
            ttime = pd.to_datetime(row.get("transaction_time"), errors="coerce", utc=True)
            if pd.isna(ttime):
                ttime = pd.Timestamp.now(tz="UTC")
            reported = ttime + pd.Timedelta(days=random.randint(delay_window[0], delay_window[1]))
            cbs.append({"chargeback_id": cb_id, "transaction_id": row["transaction_id"], "reason_code": reason, "reported_date": iso_or_unambiguous_malformed(reported)})
    chargebacks_df = pd.DataFrame(cbs)
    chargebacks_df = chargebacks_df.drop_duplicates(subset=["chargeback_id"]).reset_index(drop=True)
    return chargebacks_df

# ---------- Aggregation & labeling ----------
def compute_user_labels(users_df: pd.DataFrame, tx_df: pd.DataFrame, logins_df: pd.DataFrame, devices_df: pd.DataFrame, merchants_df: pd.DataFrame, base_rate: float, temporal_drift_mag: float):
    u = users_df.copy()
    tx = tx_df.copy()
    logins = logins_df.copy()
    devices = devices_df.copy()
    merchants = merchants_df.copy()

    # numeric and parsed datetimes (tz-aware)
    tx["amount"] = pd.to_numeric(tx["amount"], errors="coerce").fillna(0.0)
    tx["transaction_time_parsed"] = robust_parse_datetime_series(tx["transaction_time"])
    logins["login_time_parsed"] = robust_parse_datetime_series(logins["login_time"])
    users_parsed = robust_parse_datetime_series(u["signup_date"])
    # merchant_risk already available in tx

    # aggregates
    tx_agg = tx.groupby("user_id").agg(total_txns=("transaction_id","count"), sum_amount=("amount","sum"), avg_amount=("amount","mean"), txn_std=("amount","std")).fillna(0.0)
    failed_logins = logins[logins["success"]==0].groupby("user_id").size().rename("failed_logins")
    num_devices = devices.groupby("user_id").size().rename("num_devices")

    u = u.merge(tx_agg.reset_index(), how="left", on="user_id")
    u = u.merge(failed_logins.reset_index(), how="left", on="user_id")
    u = u.merge(num_devices.reset_index(), how="left", on="user_id")
    u[["total_txns","sum_amount","avg_amount","txn_std","failed_logins","num_devices"]] = u[["total_txns","sum_amount","avg_amount","txn_std","failed_logins","num_devices"]].fillna(0.0)

    # recent_txns: last 7 days (ensure tz-aware now)
    now = pd.Timestamp.now(tz="UTC")
    recent_mask = tx["transaction_time_parsed"] >= (now - pd.Timedelta(days=7))
    if recent_mask.any():
        recent_counts = tx.loc[recent_mask].groupby("user_id").size().rename("recent_txns").reset_index()
        u = u.merge(recent_counts, how="left", on="user_id")
    u["recent_txns"] = u.get("recent_txns", 0).fillna(0).astype(int)

    # account_age_days vectorized
    signup_parsed = robust_parse_datetime_series(u["signup_date"])
    account_age_days = (now - signup_parsed).dt.days.fillna(365)
    u["account_age_days"] = account_age_days.astype(float)

    # merchant exposure: avg merchant_risk for user's transactions
    if not tx.empty and "merchant_risk" in tx.columns:
        mr = tx.groupby("user_id")["merchant_risk"].mean().rename("avg_merchant_risk").reset_index()
        u = u.merge(mr, how="left", on="user_id")
    u["avg_merchant_risk"] = u.get("avg_merchant_risk", 0.0).fillna(0.0)

    # compute score using weighted signals; include temporal drift: newer accounts slightly more targeted
    w = {"total_txns":0.35,"avg_amount":0.5,"txn_std":0.25,"failed_logins":0.7,"num_devices":0.4,"recent_txns":0.8,"avg_merchant_risk":0.9,"account_age_days":-0.001}
    def safe_norm(series):
        s = pd.to_numeric(series, errors="coerce").fillna(0.0)
        mx = s.max()
        return s / (mx + 1e-9) if mx and mx > 0 else s * 0.0
    u["avg_amount_norm"] = safe_norm(u["avg_amount"])
    u["txn_std_norm"] = safe_norm(u["txn_std"])
    u["total_txns_norm"] = safe_norm(u["total_txns"])
    u["failed_logins_norm"] = safe_norm(u["failed_logins"])
    u["num_devices_norm"] = safe_norm(u["num_devices"])
    u["recent_txns_norm"] = safe_norm(u["recent_txns"])
    u["merchant_risk_norm"] = safe_norm(u["avg_merchant_risk"])
    u["acct_age_norm"] = safe_norm(u["account_age_days"])

    # temporal drift: compute recency factor (accounts with many recent txns or recent signup get slight multiplier)
    recency_factor = 1.0 + temporal_drift_mag * (u["recent_txns_norm"] * 0.5 + (1 - u["acct_age_norm"]) * 0.5)

    score = (
        w["total_txns"]*u["total_txns_norm"] +
        w["avg_amount"]*u["avg_amount_norm"] +
        w["txn_std"]*u["txn_std_norm"] +
        w["failed_logins"]*u["failed_logins_norm"] +
        w["num_devices"]*u["num_devices_norm"] +
        w["recent_txns"]*u["recent_txns_norm"] +
        w["avg_merchant_risk"]*u["merchant_risk_norm"] +
        w["account_age_days"]*u["acct_age_norm"]
    ) * recency_factor

    prob = logistic((score - score.mean()) * 3.0)
    # calibrate threshold to base_rate (global)
    try:
        threshold = float(np.quantile(prob, 1.0 - base_rate_adjusted(base_rate=base_rate, drift=temporal_drift_mag)))
    except Exception:
        threshold = np.quantile(prob, 0.98)
    u["is_fraud"] = (prob >= threshold).astype(int)

    # clean helpers
    drop_cols = [c for c in u.columns if c.endswith("_norm") or c in ["avg_amount","txn_std","merchant_risk_norm"]]
    u = u.drop(columns=[c for c in drop_cols if c in u.columns], errors="ignore")
    u["is_fraud"] = u["is_fraud"].astype(int)
    u["total_txns"] = u["total_txns"].astype(int)
    u["failed_logins"] = u["failed_logins"].astype(int)
    u["num_devices"] = u["num_devices"].astype(int)
    u["recent_txns"] = u["recent_txns"].astype(int)
    return u

def base_rate_adjusted(base_rate: float, drift: float) -> float:
    """
    Return adjusted base rate considering temporal drift. Keep within (0.0001,0.5) safe bounds.
    """
    adj = base_rate * (1.0 + (drift - 1.0) * 0.5)
    return float(np.clip(adj, 0.0001, 0.5))

# ---------- Orchestrator ----------
def generate_all(output_dir: str, size_key: str, fmt: str, seed: int = DEFAULT_SEED):
    if size_key not in SIZE_MAP:
        raise ValueError(f"size must be one of {list(SIZE_MAP.keys())}")
    mkdir_p(output_dir)
    seed_everything(seed)
    fake = Faker()
    n_users = SIZE_MAP[size_key]

    log.info("Generating %d users (size=%s) in %s (format=%s)", n_users, size_key, output_dir, fmt)
    users_df = gen_users(fake, n_users)
    log.info("users -> %d rows", len(users_df))

    # merchants: scale merchant count with size (small->keep MERCHANT_COUNT small, large -> increase)
    n_merchants = max(20, int(MERCHANT_COUNT * max(0.5, len(users_df)/5000)))
    merchants_df = gen_merchants(n_merchants, fake, HIGH_RISK_MERCHANT_PCT)
    log.info("merchants -> %d rows (high-risk pct=%.2f)", len(merchants_df), HIGH_RISK_MERCHANT_PCT)

    devices_df = gen_devices_and_rings(fake, users_df, avg_per_user=AVG_DEV_PER_USER[size_key], ring_fraction=FRAUD_RING_FRACTION, ring_device_share=RING_DEVICE_SHARE)
    log.info("devices -> %d rows", len(devices_df))

    tx_df = gen_transactions(fake, users_df, merchants_df, avg_per_user=AVG_TX_PER_USER[size_key], burst_user_pct=BURST_USER_PCT)
    log.info("transactions -> %d rows", len(tx_df))

    logins_df = gen_logins(fake, users_df, avg_per_user=AVG_LOGIN_PER_USER[size_key], account_takeover_pct=0.01)
    log.info("logins -> %d rows", len(logins_df))

    # attach actual device_ids to transactions: pick device for user, prefer shared devices if exist to simulate rings
    if not devices_df.empty and not tx_df.empty:
        dev_map = devices_df.groupby("user_id")["device_id"].apply(list).to_dict()
        def pick_device(uid):
            devs = dev_map.get(uid, [])
            return random.choice(devs) if devs and random.random() > 0.3 else None
        tx_df["device_id"] = tx_df["user_id"].apply(pick_device)

    # compute labels
    users_labeled = compute_user_labels(users_df, tx_df, logins_df, devices_df, merchants_df, base_rate=BASE_FRAUD_RATE, temporal_drift_mag=TEMPORAL_DRIFT_MAG)
    log.info("labeled users -> %d rows; fraud_rate ~ %.4f", len(users_labeled), users_labeled["is_fraud"].mean())

    # chargebacks (label delay)
    chargebacks_df = gen_chargebacks(fake, tx_df, LABEL_DELAY_DAYS)
    log.info("chargebacks -> %d rows", len(chargebacks_df))

    # leak column and future flags to test leakage detection
    if not tx_df.empty:
        tx_df["future_tx_flag"] = tx_df.groupby("user_id").cumcount().apply(lambda x: 1 if x % 50 == 0 else 0)
        tx_df["leak_label_hint"] = pd.NA
        # select some transactions for which we leak label hint (rare)
        leak_frac = 0.003
        if leak_frac > 0:
            leak_sample = tx_df.sample(frac=leak_frac, random_state=seed)
            label_map = users_labeled.set_index("user_id")["is_fraud"].to_dict()
            for idx in leak_sample.index:
                uid = tx_df.at[idx, "user_id"]
                tx_df.at[idx, "leak_label_hint"] = int(label_map.get(uid, 0))

    # controlled corruption: missing trust scores and device types
    if not devices_df.empty:
        devices_df.loc[devices_df.sample(frac=0.01, random_state=seed).index, "device_trust_score"] = None
    if not logins_df.empty:
        logins_df.loc[logins_df.sample(frac=0.02, random_state=seed+1).index, "device_type"] = None

    # output dir per size
    size_dir = os.path.join(output_dir, size_key)
    mkdir_p(size_dir)

    # choose filenames base (without extension): we'll append .csv or .parquet
    files = {
        "users": (users_labeled, os.path.join(size_dir, "users")),
        "merchants": (merchants_df, os.path.join(size_dir, "merchants")),
        "devices": (devices_df, os.path.join(size_dir, "devices")),
        "transactions": (tx_df, os.path.join(size_dir, "transactions")),
        "logins": (logins_df, os.path.join(size_dir, "logins")),
        "chargebacks": (chargebacks_df, os.path.join(size_dir, "chargebacks"))
    }

    for name, (df, path_base) in files.items():
        # ensure DataFrame exists
        if df is None or (isinstance(df, pd.DataFrame) and df.empty):
            # create empty schema-preserving DataFrame to write
            df = pd.DataFrame()
        write_df(df, path_base, fmt)

    metadata = {
        "pinned_faker_version": PINNED_FAKER_VERSION,
        "seed": seed,
        "size_key": size_key,
        "n_users": int(len(users_labeled)),
        "n_merchants": int(len(merchants_df)),
        "n_transactions": int(len(tx_df)),
        "n_logins": int(len(logins_df)),
        "n_devices": int(len(devices_df)),
        "n_chargebacks": int(len(chargebacks_df)),
        "approx_fraud_rate": float(users_labeled["is_fraud"].mean())
    }
    meta_path = os.path.join(size_dir, "metadata.json")
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(metadata, fh, indent=2)

    log.info("Wrote outputs to %s", size_dir)
    log.info("Metadata: %s", json.dumps(metadata))

# ---------- CLI ----------
def parse_args():
    p = argparse.ArgumentParser(description="Generate realistic synthetic fraud detection datasets.")
    p.add_argument("--output-dir", "-o", required=True, help="Directory to write datasets")
    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--size", choices=["small","medium","large"], help="Dataset scale")
    grp.add_argument("--small", action="store_true", help="Shortcut for --size small")
    p.add_argument("--format", choices=["csv","parquet"], default="csv", help="Output format")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED, help="Random seed")
    return p.parse_args()

def main():
    args = parse_args()
    size_key = "small" if args.small else (args.size or "small")
    try:
        generate_all(args.output_dir, size_key=size_key, fmt=args.format, seed=args.seed)
    except Exception as e:
        log.exception("Generation failed: %s", e)
        raise

if __name__ == "__main__":
    main()
