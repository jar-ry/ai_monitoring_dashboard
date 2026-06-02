SUMMARY_SCHEMA = "SAMPLES_DB.PUBLIC"

COMMON_TIMEZONES = [
    ("Pacific (PT)", "America/Los_Angeles"),
    ("Mountain (MT)", "America/Denver"),
    ("Central (CT)", "America/Chicago"),
    ("Eastern (ET)", "America/New_York"),
    ("UTC", "UTC"),
    ("London (GMT/BST)", "Europe/London"),
    ("Paris (CET/CEST)", "Europe/Paris"),
    ("Tokyo (JST)", "Asia/Tokyo"),
    ("Sydney (AEST)", "Australia/Sydney"),
]

DEFAULT_TIMEZONE = "America/Los_Angeles"

DATE_PRESETS = {"1 Day": 1, "7 Days": 7, "Month": 30, "Quarter": 90, "Year": 365}

CREDIT_TYPE_MAP = {
    'Cortex Agents': 'AI Credits',
    'Cortex Code': 'AI Credits',
    'Snowflake Intelligence': 'AI Credits',
    'Cortex Functions': 'Regular Credits',
    'Cortex Analyst': 'Regular Credits',
    'Cortex Search': 'Regular Credits',
    'Cortex Search Batch': 'Regular Credits',
    'Cortex Fine-tuning': 'Regular Credits',
    'Document AI': 'Regular Credits',
    'Provisioned Throughput': 'Regular Credits',
    'Cortex REST API': 'Dollars',
}

CREDIT_TYPE_COLORS = ['#22C55E', '#2563EB', '#DC2626']
CREDIT_TYPE_ORDER = ['AI Credits', 'Regular Credits', 'Dollars']
CREDIT_TYPE_COLOR_MAP = {'AI Credits': '#22C55E', 'Regular Credits': '#2563EB', 'Dollars': '#DC2626'}
