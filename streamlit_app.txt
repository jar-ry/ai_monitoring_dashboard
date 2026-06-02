"""Cortex Tracker — Streamlit in Snowflake. Multi-module, Altair charts, 13 tabs."""
import streamlit as st
import pandas as pd
import altair as alt
from datetime import datetime, timedelta
import logging
from snowflake.snowpark.context import get_active_session
from utils import (COMMON_TIMEZONES, DEFAULT_TIMEZONE, DATE_PRESETS, CREDIT_TYPE_COLORS, CREDIT_TYPE_ORDER,
    CREDIT_TYPE_COLOR_MAP, format_credits, format_number, calculate_delta, get_previous_period,
    get_date_range, add_credit_type_column, local_today)
from queries_summary import (get_ai_services_summary, get_credits_by_day_and_type, get_feature_usage, get_top_users,
    get_model_usage, get_top_users_by_feature, get_period_comparison, get_category_breakdown,
    get_daily_trend_by_category, get_user_growth, get_efficiency_metrics, get_new_users, get_wow_comparison,
    get_agents_overview, get_agents_token_breakdown, get_agent_health_scorecard, get_high_token_users,
    get_snowflake_native_budgets, get_cortex_search_credits, get_wh_cost_by_user,
    get_refresh_log, get_task_history, get_data_completeness, get_data_reconciliation,
    get_user_anomalies, get_health_status, get_last_refresh_time,
    get_users_by_feature_summary, get_models_by_feature, SUMMARY_SCHEMA)
from queries_raw import (get_cortex_analyst_usage, get_cortex_search_usage, get_cortex_search_batch_usage,
    get_document_ai_usage, get_cortex_code_usage, get_provisioned_throughput_usage, get_fine_tuning_usage,
    get_cortex_agent_usage, get_snowflake_intelligence_usage, get_rest_api_usage, get_cortex_ai_functions_usage)
from queries_observability import (discover_agents, get_obs_usage_summary, get_obs_performance, get_obs_quality,
    get_obs_feedback, get_obs_tools, get_obs_thread_list, get_obs_thread_conversation)

logging.basicConfig(level=logging.WARNING)
st.set_page_config(page_title="Cortex Tracker", page_icon="🤖", layout="wide", initial_sidebar_state="expanded")
st.markdown("""<style>html,body,[class*="css"]{font-size:14px}h1{font-size:1.5rem!important}h2{font-size:1.25rem!important}
[data-testid="stMetricValue"]{font-size:1.4rem!important}[data-testid="stMetricLabel"]{font-size:0.8rem!important}
[data-testid="stSidebar"] [data-testid="stMarkdownContainer"]{font-size:0.8rem!important}
[data-testid="stSidebar"] .stSelectbox label, [data-testid="stSidebar"] .stRadio label{font-size:0.8rem!important}
.block-container{padding-top:1rem!important}
.home-card{background:#f8f9fa;border-radius:8px;padding:1rem;border-left:4px solid #29B5E8;margin-bottom:0.5rem}
.home-card b{font-size:0.95rem}.home-card p{font-size:0.82rem;margin:0.3rem 0 0 0;color:#555}
.home-card .prereq{font-size:0.75rem;color:#888;font-style:italic;margin-top:0.3rem}
</style>""", unsafe_allow_html=True)


@st.cache_resource
def get_session():
    return get_active_session()


def hbar(df, x, y, color_col=None, height=300):
    if df.empty: return None
    enc = {'x': alt.X(f'{x}:Q'), 'y': alt.Y(f'{y}:N', sort='-x', title='')}
    if color_col and color_col in df.columns:
        enc['color'] = alt.Color(f'{color_col}:N', scale=alt.Scale(domain=CREDIT_TYPE_ORDER, range=CREDIT_TYPE_COLORS), legend=alt.Legend(title="Credit Type"))
    return alt.Chart(df).mark_bar().encode(**enc).properties(height=height).configure_view(strokeWidth=0)


def area_typed(df, x, y, color_col, height=250):
    if df.empty: return None
    return alt.Chart(df).mark_area(opacity=0.7).encode(
        x=alt.X(f'{x}:T', title=''), y=alt.Y(f'{y}:Q', title='Credits', stack='zero'),
        color=alt.Color(f'{color_col}:N', scale=alt.Scale(domain=CREDIT_TYPE_ORDER, range=CREDIT_TYPE_COLORS), legend=alt.Legend(title="Credit Type"))
    ).properties(height=height).configure_view(strokeWidth=0)


def render_home_card(icon, title, desc, prereq=None):
    prereq_html = f'<div class="prereq">Pre-req: {prereq}</div>' if prereq else ''
    return f'<div class="home-card"><b>{icon} {title}</b><p>{desc}</p>{prereq_html}</div>'


def main():
    session = get_session()
    with st.sidebar:
        st.markdown("### Cortex Tracker")
        st.divider()
        tz_labels = [t[0] for t in COMMON_TIMEZONES]; tz_values = [t[1] for t in COMMON_TIMEZONES]
        tz_idx = st.selectbox("🌍 Timezone", range(len(tz_labels)), format_func=lambda i: tz_labels[i], help="All queries use this timezone.")
        user_tz = tz_values[tz_idx]
        date_preset = st.radio("📅 Period", list(DATE_PRESETS.keys())+["Custom"], index=1, horizontal=True, help="Time window for all queries.")
        if date_preset == "Custom":
            cs = st.date_input("Start", value=local_today(user_tz)-timedelta(days=7), help="Start date.")
            ce = st.date_input("End", value=local_today(user_tz), help="End date.")
            start_date, end_date = str(cs), str(ce)
        else:
            start_date, end_date = get_date_range(date_preset, user_tz)
        st.info(f"**{start_date}** → **{end_date}**")
        st.divider()
        if st.button("🔄 Refresh", use_container_width=True, help="Clear cache and reload."): st.cache_data.clear(); st.rerun()
        st.divider()
        st.markdown('<div style="font-size:0.8rem;line-height:1.6;"><b>💳 Credit Types</b><br><span style="color:#22C55E;">■</span> AI Credits — Agents, Code, Intelligence<br><span style="color:#2563EB;">■</span> Regular Credits — Functions, Analyst, Search, etc.<br><span style="color:#DC2626;">■</span> Dollars — REST API (USD)</div>', unsafe_allow_html=True)
        st.divider()
        st.caption(f"Refresh: {get_last_refresh_time(session)}")
        st.caption(f"Schema: {SUMMARY_SCHEMA}")

    # === ESSENTIAL DATA (needed for KPIs + Summary) ===
    prev_start, prev_end = get_previous_period(start_date, end_date)
    summary = get_ai_services_summary(session, start_date, end_date)
    feature_usage = add_credit_type_column(get_feature_usage(session, start_date, end_date))
    top_users = get_top_users(session, start_date, end_date)
    daily_by_type = get_credits_by_day_and_type(session, start_date, end_date)
    period_comp = get_period_comparison(session, start_date, end_date, prev_start, prev_end)
    category_breakdown = add_credit_type_column(get_category_breakdown(session, start_date, end_date))
    new_users_df = get_new_users(session, start_date, end_date, prev_start, prev_end)
    period_days = (datetime.strptime(end_date,'%Y-%m-%d')-datetime.strptime(start_date,'%Y-%m-%d')).days+1

    st.markdown('<h1 style="font-size:2rem;margin-bottom:0.5rem;">Cortex Tracker</h1>', unsafe_allow_html=True)
    health = get_health_status(summary.get('total_credits',0), period_comp.get('prev_credits',0), top_users, period_days)
    if health[0]['severity'] != '✅':
        (st.error if health[0]['severity']=='🔴' else st.warning)(f"{health[0]['severity']} {health[0]['message']}")

    # === KPI ROWS ===
    st.subheader("📊 Key Metrics")
    st.caption(f"**{start_date} → {end_date}** vs prior **{prev_start} → {prev_end}**")
    cd,cc = calculate_delta(period_comp.get('current_credits',0), period_comp.get('prev_credits',0))
    cld,clc = calculate_delta(period_comp.get('current_calls',0), period_comp.get('prev_calls',0))
    ud,uc = calculate_delta(period_comp.get('current_users',0), period_comp.get('prev_users',0))
    c1,c2,c3,c4 = st.columns(4)
    c1.metric("Credits", format_credits(period_comp.get('current_credits',0)), delta=cd, delta_color=cc, help="Total AI credits in period.")
    c2.metric("Calls", format_number(period_comp.get('current_calls',0)), delta=cld, delta_color=clc, help="Total API invocations.")
    c3.metric("Users", str(int(period_comp.get('current_users',0))), delta=ud, delta_color=uc, help="Distinct AI users.")
    c4.metric("New Users", str(len(new_users_df)), help="First-time users this period.")
    if not feature_usage.empty and 'CREDIT_TYPE' in feature_usage.columns:
        tt = feature_usage.groupby('CREDIT_TYPE')['CREDITS'].sum()
        t1,t2,t3 = st.columns(3)
        t1.metric("🟢 AI Credits", format_credits(tt.get('AI Credits',0)), help="Agents, Code, Intelligence.")
        t2.metric("🔵 Regular Credits", format_credits(tt.get('Regular Credits',0)), help="Functions, Analyst, Search, etc.")
        t3.metric("🔴 Dollars", format_credits(tt.get('Dollars',0)), help="REST API (USD).")
    st.divider()

    # === TABS (13) ===
    tabs = st.tabs(["🏠 Home","📈 Summary","🔧 Features","👥 Users","🤖 Models","📊 Trends",
        "🕵️ Agents","🏥 Health","📡 Observability","🔨 Tools","💰 Budgets","🚨 Alerts","⚙️ Operations","📋 Raw Data"])

    # --- HOME ---
    with tabs[0]:
        st.markdown("### Welcome to the AI Monitoring Dashboard")
        st.markdown("Monitor, analyze, and govern all Snowflake Cortex AI feature consumption from a single pane.")
        col1, col2 = st.columns(2)
        with col1:
            st.markdown(render_home_card("📈", "Summary", "Credit distribution by category and daily trend by credit type (AI/Regular/Dollars)."), unsafe_allow_html=True)
            st.markdown(render_home_card("🔧", "Features", "Per-feature credit breakdown with credit type classification. Drill into top users per feature."), unsafe_allow_html=True)
            st.markdown(render_home_card("👥", "Users", "Top 20 users by credit consumption. Adoption trends and new user tracking."), unsafe_allow_html=True)
            st.markdown(render_home_card("🤖", "Models", "LLM model usage comparison — credits, tokens, efficiency (tokens/credit)."), unsafe_allow_html=True)
            st.markdown(render_home_card("📊", "Trends", "Daily credit trends by credit type. Week-over-week comparison."), unsafe_allow_html=True)
            st.markdown(render_home_card("🕵️", "Agents", "Per-agent credit/token breakdown with TOKENS_GRANULAR detail (input/output/cache).",
                "Requires Cortex Agents to be deployed and invoked in your account."), unsafe_allow_html=True)
        with col2:
            st.markdown(render_home_card("🏥", "Agent Health", "Anti-pattern detection: high-token requests (>128K), risk levels, top consumers.",
                "Requires Cortex Agent usage in selected period."), unsafe_allow_html=True)
            st.markdown(render_home_card("📡", "Observability", "Live agent telemetry: latency (P50/P90/P99), success rates, feedback, tool invocations.",
                "GRANT APPLICATION ROLE SNOWFLAKE.AI_OBSERVABILITY_READER TO ROLE &lt;role&gt;"), unsafe_allow_html=True)
            st.markdown(render_home_card("🔨", "Tools", "Cortex Search service credit breakdown by service and consumption type."), unsafe_allow_html=True)
            st.markdown(render_home_card("💰", "Budgets", "Discover Snowflake native budgets configured for AI features.",
                "Budgets must be created via Admin > Cost Management > Budgets."), unsafe_allow_html=True)
            st.markdown(render_home_card("🚨", "Alerts", "Health status, spend anomaly detection (3x+ vs historical average)."), unsafe_allow_html=True)
            st.markdown(render_home_card("⚙️", "Operations", "Refresh log, task history, data completeness checks, summary-vs-raw reconciliation.",
                "Stored procedure REFRESH_AI_USAGE_SUMMARIES must exist in schema."), unsafe_allow_html=True)
            st.markdown(render_home_card("📋", "Raw Data", "Export raw records from any of the 14 AI usage views. CSV download."), unsafe_allow_html=True)

    # --- SUMMARY ---
    with tabs[1]:
        st.markdown("**Daily Trend by Category**")
        cat_trend = get_daily_trend_by_category(session, start_date, end_date)
        if not cat_trend.empty:
            pivot = cat_trend.pivot(index='DATE', columns='CATEGORY', values='CREDITS').fillna(0)
            st.area_chart(pivot, height=200)
        st.markdown("**Daily Credit Trend by Credit Type**")
        if not daily_by_type.empty:
            c = area_typed(daily_by_type,'DATE','CREDITS','CREDIT_TYPE',height=280)
            if c: st.altair_chart(c, use_container_width=True)
        st.divider()
        col1,col2 = st.columns([2,1])
        with col1:
            st.markdown("**Credits by Category**")
            if not category_breakdown.empty:
                c = hbar(category_breakdown,'CREDITS','CATEGORY','CREDIT_TYPE',height=280)
                if c: st.altair_chart(c, use_container_width=True)
        with col2:
            if not category_breakdown.empty:
                total_cat = category_breakdown['CREDITS'].sum()
                if total_cat > 0:
                    sorted_cats = category_breakdown.sort_values('CREDITS', ascending=False)
                    lines_html = []
                    for _, row in sorted_cats.iterrows():
                        pct = (row['CREDITS'] / total_cat * 100)
                        clr = CREDIT_TYPE_COLOR_MAP.get(row['CREDIT_TYPE'], '#666')
                        lines_html.append(f'<span style="color:{clr};font-weight:600;">●</span> {row["CATEGORY"]}: <b>{pct:.1f}%</b>')
                    st.markdown('<div style="font-size:0.82rem;line-height:1.8;">' + '<br>'.join(lines_html) + '</div>', unsafe_allow_html=True)

    # --- FEATURES ---
    with tabs[2]:
        if not feature_usage.empty:
            c = hbar(feature_usage.head(15),'CREDITS','FEATURE','CREDIT_TYPE',height=400)
            if c: st.altair_chart(c, use_container_width=True)
            st.dataframe(feature_usage[['FEATURE','CATEGORY','CREDIT_TYPE','CREDITS','TOKENS','CALLS','UNIQUE_USERS']], use_container_width=True, hide_index=True)
            st.divider()
            sel_feat = st.selectbox("Drill into feature:", feature_usage['FEATURE'].tolist())
            if sel_feat:
                fu = get_top_users_by_feature(session, start_date, end_date, sel_feat)
                if not fu.empty: st.dataframe(fu, use_container_width=True, hide_index=True)

    # --- USERS ---
    with tabs[3]:
        if not top_users.empty:
            c = hbar(top_users.head(20),'TOTAL_CREDITS','USER_NAME',height=450)
            if c: st.altair_chart(c, use_container_width=True)
            st.dataframe(top_users, use_container_width=True, hide_index=True)
        ug = get_user_growth(session, start_date, end_date)
        if not ug.empty:
            st.markdown("**Daily Adoption**")
            st.line_chart(ug.set_index('DATE')['UNIQUE_USERS'], height=150)
        st.divider()
        st.markdown("**Top Users by Feature**")
        if not feature_usage.empty:
            sel_uf = st.selectbox("Feature:", feature_usage['FEATURE'].tolist(), key="user_feat", help="Top 15 users for this feature.")
            if sel_uf:
                uf = get_users_by_feature_summary(session, start_date, end_date, sel_uf)
                if not uf.empty:
                    c = hbar(uf, 'CREDITS', 'USER_NAME', height=300)
                    if c: st.altair_chart(c, use_container_width=True)

    # --- MODELS ---
    with tabs[4]:
        model_usage = get_model_usage(session, start_date, end_date)
        if not model_usage.empty:
            c = hbar(model_usage,'CREDITS','MODEL_NAME',height=350)
            if c: st.altair_chart(c, use_container_width=True)
            st.dataframe(model_usage, use_container_width=True, hide_index=True)
            eff = get_efficiency_metrics(session, start_date, end_date)
            if not eff.empty:
                st.markdown("**Efficiency (Tokens per Credit)**")
                st.dataframe(eff[['MODEL_NAME','TOKENS_PER_CREDIT','CREDITS','CALLS']], use_container_width=True, hide_index=True)
        st.divider()
        st.markdown("**Models by Category**")
        mbf = get_models_by_feature(session, start_date, end_date)
        if not mbf.empty:
            st.dataframe(mbf, use_container_width=True, hide_index=True,
                column_config={"CATEGORY": st.column_config.TextColumn("Category", help="AI service category"),
                    "MODEL_NAME": st.column_config.TextColumn("Model", help="LLM model used"),
                    "CREDITS": st.column_config.NumberColumn("Credits", help="Credits by this model in category", format="%.4f"),
                    "TOKENS": st.column_config.NumberColumn("Tokens", help="Tokens processed"),
                    "CALLS": st.column_config.NumberColumn("Calls", help="Invocations")})

    # --- TRENDS ---
    with tabs[5]:
        st.markdown("**Daily Trend by Feature**")
        cat_trend = get_daily_trend_by_category(session, start_date, end_date)
        if not cat_trend.empty:
            pivot = cat_trend.pivot(index='DATE', columns='CATEGORY', values='CREDITS').fillna(0)
            st.area_chart(pivot, height=250)
        st.divider()
        if not daily_by_type.empty:
            st.markdown("**Daily Credit Trend by Credit Type**")
            c = area_typed(daily_by_type,'DATE','CREDITS','CREDIT_TYPE',height=300)
            if c: st.altair_chart(c, use_container_width=True)
        st.divider()
        st.markdown("**Per-Feature Daily Trend**")
        if not feature_usage.empty:
            sel_ft = st.selectbox('Feature:', feature_usage['FEATURE'].tolist(), key='trend_feat', help='Daily credits for this feature.')
            if sel_ft:
                from queries_summary import get_daily_trend_by_feature
                ft = get_daily_trend_by_feature(session, start_date, end_date, sel_ft)
                if not ft.empty:
                    ch = alt.Chart(ft).mark_line(point=True).encode(x=alt.X('DATE:T',title=''),y=alt.Y('CREDITS:Q',title='Credits')).properties(height=200).configure_view(strokeWidth=0)
                    st.altair_chart(ch, use_container_width=True)
        st.divider()
        wow = get_wow_comparison(session, start_date, end_date)
        if not wow.empty and len(wow)>1:
            st.markdown("**Week-over-Week**")
            st.dataframe(wow, use_container_width=True, hide_index=True)

    # --- AGENTS ---
    with tabs[6]:
        st.caption("Shows per-agent credit/token breakdown from CORTEX_AGENT_USAGE_HISTORY.")
        agents = get_agents_overview(session, start_date, end_date, user_tz)
        if not agents.empty:
            st.dataframe(agents, use_container_width=True, hide_index=True)
            sel = st.selectbox("Token breakdown:", agents['AGENT_NAME'].tolist(), key="agent_sel")
            if sel:
                tb = get_agents_token_breakdown(session, sel, start_date, end_date, user_tz)
                if not tb.empty: st.dataframe(tb, use_container_width=True, hide_index=True)
        else:
            st.info("No Cortex Agent usage found in this period. Agents must be deployed and invoked (via SQL, Snowflake Intelligence, or Teams) to appear here.")

    # --- HEALTH ---
    with tabs[7]:
        st.caption("Detects anti-patterns: agents with high token usage (>128K per request), risk levels.")
        if not st.session_state.get('load_health'):
            st.info("Click below to query agent health data.")
            if st.button("🔄 Load Health Data", key="btn_health", help="Queries pre-aggregated agent health scorecard."): st.session_state['load_health']=True; st.rerun()
        else:
            sc = get_agent_health_scorecard(session, start_date, end_date, user_tz)
            if not sc.empty:
                st.dataframe(sc, use_container_width=True, hide_index=True)
                ht = get_high_token_users(session, start_date, end_date, user_tz)
                if not ht.empty:
                    st.markdown("**High Token Users (avg >50K tokens/request)**")
                    st.dataframe(ht, use_container_width=True, hide_index=True)
            else:
                st.info("No agent usage data available.")

    # --- OBSERVABILITY ---
    with tabs[8]:
        st.caption("Live agent telemetry from SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS.")
        st.markdown("**Pre-requisite:** `GRANT APPLICATION ROLE SNOWFLAKE.AI_OBSERVABILITY_READER TO ROLE <your_role>;`")
        if not st.session_state.get('load_obs'):
            st.info("Click below to query observability events.")
            if st.button("🔄 Load Observability", key="btn_obs", help="Queries live AI_OBSERVABILITY_EVENTS."): st.session_state['load_obs']=True; st.rerun()
        else:
            with st.spinner("Discovering agents..."):
                agents_list = discover_agents(session)
            if not agents_list.empty:
                opts = [f"{r['AGENT_DATABASE_NAME']}.{r['AGENT_SCHEMA_NAME']}.{r['AGENT_NAME']}" for _,r in agents_list.iterrows()]
                sel = st.selectbox("Agent", opts, key="obs_agent"); lookback = st.slider("Lookback (days)", 1, 30, 7, key="obs_days")
                if sel:
                    parts = sel.split("."); adb,asc_n,aname = parts[0],parts[1],parts[2]
                    usage = get_obs_usage_summary(session, adb, asc_n, aname, lookback)
                    if usage:
                        m1,m2,m3,m4 = st.columns(4)
                        m1.metric("Requests", usage.get('total_requests',0))
                        m2.metric("Users", usage.get('unique_users',0))
                        m3.metric("Conversations", usage.get('conversations',0))
                        m4.metric("Req/User", usage.get('requests_per_user',0))
                    perf = get_obs_performance(session, adb, asc_n, aname, lookback)
                    if perf:
                        st.markdown("**Latency**")
                        pc1,pc2,pc3,pc4 = st.columns(4)
                        pc1.metric("Avg", f"{perf.get('avg_ms',0):.0f}ms")
                        pc2.metric("P50", f"{perf.get('p50_ms',0):.0f}ms")
                        pc3.metric("P90", f"{perf.get('p90_ms',0):.0f}ms")
                        pc4.metric("P99", f"{perf.get('p99_ms',0):.0f}ms")
                    qual = get_obs_quality(session, adb, asc_n, aname, lookback)
                    if qual:
                        qc1,qc2 = st.columns(2)
                        qc1.metric("Success Rate", f"{qual.get('success_pct',0):.1f}%")
                        qc2.metric("Error Rate", f"{qual.get('error_pct',0):.1f}%")
                    fb = get_obs_feedback(session, adb, asc_n, aname, lookback)
                    if fb and fb.get('total',0)>0:
                        st.markdown(f"**Feedback:** 👍 {fb.get('thumbs_up',0)} / 👎 {fb.get('thumbs_down',0)}")
                    tools = get_obs_tools(session, adb, asc_n, aname, lookback)
                    if not tools.empty:
                        st.markdown("**Tool Invocations**")
                        st.dataframe(tools, use_container_width=True, hide_index=True)
            else:
                st.warning("No agents discovered. Grant AI_OBSERVABILITY_READER role.")

    # --- TOOLS ---
    with tabs[9]:
        st.caption("Cortex Search service credit breakdown.")
        if not st.session_state.get('load_tools'):
            st.info("Click below to query Cortex Search usage.")
            if st.button("🔄 Load Tools Data", key="btn_tools", help="Queries Cortex Search usage."): st.session_state['load_tools']=True; st.rerun()
        else:
            with st.spinner("Loading..."):
                sc2 = get_cortex_search_credits(session, start_date, end_date)
            if not sc2.empty: st.dataframe(sc2, use_container_width=True, hide_index=True)
            else: st.info("No Cortex Search usage in this period.")

    # --- BUDGETS ---
    with tabs[10]:
        st.info("\u26a0\ufe0f Snowflake does not currently support AI-specific budgets. Account-level budgets (Admin > Cost Management) cannot filter by AI service type.")
        st.caption("Reserved for future AI budget capabilities or custom threshold implementation.")

    # --- ALERTS ---
    with tabs[11]:
        for h in health:
            fn = st.error if h['severity']=='🔴' else st.warning if h['severity']=='⚠️' else st.info if h['severity']=='💡' else st.success
            fn(f"{h['severity']} {h['message']}")
        st.divider()
        st.markdown("**User Anomaly Detection**")
        st.caption("Users spending 3x+ their historical average.")
        an = get_user_anomalies(session, start_date, end_date)
        if not an.empty:
            st.warning(f"{len(an)} user(s) with unusual activity")
            st.dataframe(an, use_container_width=True, hide_index=True)
        else: st.success("No anomalies detected.")

    # --- OPERATIONS ---
    with tabs[12]:
        st.caption("Summary table refresh status, task history, and data integrity checks.")
        col1, col2 = st.columns(2)
        with col1:
            st.markdown("**Recent Refreshes**")
            rl = get_refresh_log(session)
            if not rl.empty:
                st.dataframe(rl, use_container_width=True, hide_index=True)
            else:
                st.info("No refresh log entries. Run CALL REFRESH_AI_USAGE_SUMMARIES(30);")
            st.markdown("**Task History**")
            th = get_task_history(session)
            if not th.empty:
                st.dataframe(th, use_container_width=True, hide_index=True)
            else:
                st.info("Task REFRESH_AI_USAGE_TASK not found or no runs yet.")
        with col2:
            st.markdown("**Data Completeness**")
            dc = get_data_completeness(session, start_date, end_date)
            if not dc.empty:
                st.dataframe(dc, use_container_width=True, hide_index=True)
            else:
                st.info("No completeness data.")
            st.markdown("**Reconciliation (Summary vs Raw)**")
            dr = get_data_reconciliation(session, start_date, end_date)
            if not dr.empty:
                st.dataframe(dr, use_container_width=True, hide_index=True)
            else:
                st.info("No reconciliation data.")

    # --- RAW DATA ---
    with tabs[13]:
        sources = ["Feature Summary","Top Users","Model Usage","Cortex Analyst","Cortex Search","Search Batch",
                   "Document AI","Cortex Code","PTU","Fine-tuning","Cortex Agents","Intelligence","REST API","AI Functions"]
        ds = st.selectbox("Source", sources)
        src_map = {"Feature Summary":lambda:feature_usage,"Top Users":lambda:top_users,"Model Usage":lambda:get_model_usage(session,start_date,end_date),
            "Cortex Analyst":lambda:get_cortex_analyst_usage(session,start_date,end_date,user_tz),
            "Cortex Search":lambda:get_cortex_search_usage(session,start_date,end_date,user_tz),
            "Search Batch":lambda:get_cortex_search_batch_usage(session,start_date,end_date,user_tz),
            "Document AI":lambda:get_document_ai_usage(session,start_date,end_date,user_tz),
            "Cortex Code":lambda:get_cortex_code_usage(session,start_date,end_date,user_tz),
            "PTU":lambda:get_provisioned_throughput_usage(session,start_date,end_date,user_tz),
            "Fine-tuning":lambda:get_fine_tuning_usage(session,start_date,end_date,user_tz),
            "Cortex Agents":lambda:get_cortex_agent_usage(session,start_date,end_date,user_tz),
            "Intelligence":lambda:get_snowflake_intelligence_usage(session,start_date,end_date,user_tz),
            "REST API":lambda:get_rest_api_usage(session,start_date,end_date,user_tz),
            "AI Functions":lambda:get_cortex_ai_functions_usage(session,start_date,end_date,user_tz)}
        data = add_credit_type_column(src_map.get(ds, lambda:pd.DataFrame())())
        if not data.empty:
            st.caption(f"{len(data):,} rows"); st.dataframe(data, use_container_width=True, hide_index=True)
            st.download_button(f"📥 {ds}", data.to_csv(index=False), file_name=f"ai_{ds.lower().replace(' ','_')}_{end_date}.csv", mime="text/csv")
        else: st.info(f"No data for {ds}")

    st.divider()
    st.caption(f"Cortex Tracker | {SUMMARY_SCHEMA} | {user_tz}")


if __name__ == "__main__":
    main()
