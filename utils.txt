import re
import logging
import pandas as pd
from datetime import datetime, date, timedelta
from typing import Tuple
from zoneinfo import ZoneInfo
from config import (COMMON_TIMEZONES, DEFAULT_TIMEZONE, DATE_PRESETS,
    CREDIT_TYPE_MAP, CREDIT_TYPE_COLORS, CREDIT_TYPE_ORDER, CREDIT_TYPE_COLOR_MAP)

logger = logging.getLogger(__name__)


def local_today(tz_name: str = DEFAULT_TIMEZONE) -> date:
    return datetime.now(tz=ZoneInfo(tz_name)).date()


def local_dates_to_utc_range(start_date: str, end_date: str, tz_name: str = DEFAULT_TIMEZONE) -> Tuple[str, str]:
    tz = ZoneInfo(tz_name)
    utc = ZoneInfo("UTC")
    s = date.fromisoformat(start_date)
    e = date.fromisoformat(end_date)
    start_local = datetime(s.year, s.month, s.day, 0, 0, 0, tzinfo=tz)
    end_local = datetime(e.year, e.month, e.day, 23, 59, 59, tzinfo=tz)
    return start_local.astimezone(utc).strftime("%Y-%m-%dT%H:%M:%S"), end_local.astimezone(utc).strftime("%Y-%m-%dT%H:%M:%S")


def sanitize_identifier(identifier: str) -> str:
    if not identifier or not re.match(r'^[A-Za-z][A-Za-z0-9_$]*$', identifier) or len(identifier) > 255:
        raise ValueError(f"Invalid identifier: {identifier}")
    return identifier.upper()


def escape_sql_literal(value: str) -> str:
    if value is None:
        return "NULL"
    return str(value).replace("'", "''")


def format_date_param(d) -> str:
    if isinstance(d, (date, datetime)):
        return d.strftime('%Y-%m-%d')
    elif isinstance(d, str) and re.match(r'^\d{4}-\d{2}-\d{2}$', d):
        return d
    raise ValueError(f"Invalid date: {d}")


def _safe_float(val, default=0.0) -> float:
    if val is None:
        return default
    try:
        result = float(val)
        return default if pd.isna(result) else result
    except (ValueError, TypeError):
        return default


def _safe_int(val, default=0) -> int:
    if val is None:
        return default
    try:
        result = float(val)
        return default if pd.isna(result) else int(result)
    except (ValueError, TypeError):
        return default


def format_credits(value) -> str:
    if value is None or pd.isna(value):
        return "0.00"
    value = float(value)
    if value == 0:
        return "0.00"
    elif abs(value) < 0.01:
        return f"{value:.6f}"
    elif abs(value) < 1:
        return f"{value:.4f}"
    elif abs(value) < 1000:
        return f"{value:,.2f}"
    return f"{value:,.0f}"


def format_number(value) -> str:
    if value is None or pd.isna(value):
        return "0"
    value = float(value)
    if value == 0:
        return "0"
    elif abs(value) < 1000:
        return f"{value:,.0f}"
    elif abs(value) < 1_000_000:
        return f"{value/1000:.1f}K"
    elif abs(value) < 1_000_000_000:
        return f"{value/1_000_000:.1f}M"
    return f"{value/1_000_000_000:.1f}B"


def calculate_delta(current: float, previous: float) -> Tuple[str, str]:
    current = 0 if pd.isna(current) else current
    previous = 0 if pd.isna(previous) else previous
    if previous == 0:
        return ("+100%", "normal") if current > 0 else ("0%", "off")
    change = ((current - previous) / previous) * 100
    if change > 0:
        return f"+{change:.1f}%", "normal"
    elif change < 0:
        return f"{change:.1f}%", "inverse"
    return "0%", "off"


def get_previous_period(start_date: str, end_date: str) -> Tuple[str, str]:
    start = datetime.strptime(start_date, '%Y-%m-%d')
    end = datetime.strptime(end_date, '%Y-%m-%d')
    period_days = (end - start).days + 1
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=period_days - 1)
    return str(prev_start.date()), str(prev_end.date())


def get_date_range(preset: str, tz_name: str = DEFAULT_TIMEZONE, custom_start=None, custom_end=None) -> Tuple[str, str]:
    end_date = local_today(tz_name)
    if preset == "Custom" and custom_start and custom_end:
        return str(custom_start), str(custom_end)
    days = DATE_PRESETS.get(preset, 7)
    return str(end_date - timedelta(days=days)), str(end_date)


def get_credit_type(category: str) -> str:
    return CREDIT_TYPE_MAP.get(category, 'Regular Credits')


def add_credit_type_column(df: pd.DataFrame, category_col: str = 'CATEGORY') -> pd.DataFrame:
    if df.empty or category_col not in df.columns:
        return df
    df = df.copy()
    df['CREDIT_TYPE'] = df[category_col].map(CREDIT_TYPE_MAP).fillna('Regular Credits')
    return df
